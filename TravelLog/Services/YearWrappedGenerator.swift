//
//  YearWrappedGenerator.swift
//  TravelLog
//

import Foundation
import SwiftData
import CoreLocation
import UserNotifications
import os.log

/// What one Wrapped generation request ended with. Only `.existing` and
/// `.created` mean a committed row for the year is in the store; every other
/// case wrote nothing, so the caller must not present the recap as ready.
nonisolated enum WrappedGenerationOutcome: Sendable, Equatable {
    /// A committed row for the year was already in the store.
    case existing
    /// A new row was built and committed by this call.
    case created
    /// The year has too little travel for a recap yet.
    case insufficientData
    /// Another generation for the same year was running on this actor.
    case busy
    /// A required read, the stats encoding or the save failed. Nothing was
    /// written and nothing is left pending, so a retry starts clean.
    case failed

    var producedRow: Bool { self == .existing || self == .created }
}

@ModelActor
actor YearWrappedGenerator {

    private let logger = Logger(subsystem: "com.travellog.app", category: "YearWrappedGenerator")

    /// The store touch points a generation can fail at. Named so tests can
    /// fail each one in turn through `setFaultForTesting`.
    nonisolated enum Step: Sendable, Equatable {
        case existingRead, thresholdRead, staysRead, tripsRead, travelDaysRead
        case awayDaysRead, homeAnchorsRead
        case priorCountriesRead, hexCountRead, encode, save
    }

    #if DEBUG
    private var faultForTesting: (@Sendable (Step) throws -> Void)?

    func setFaultForTesting(_ fault: (@Sendable (Step) throws -> Void)?) {
        faultForTesting = fault
    }
    #endif

    private func injectFault(_ step: Step) throws {
        #if DEBUG
        try faultForTesting?(step)
        #endif
    }

    private static let minimumTrips = 3
    private static let minimumDataMonthCutoff = 10

    /// Years currently being generated, used to coalesce concurrent
    /// `generateIfNeeded` calls (December auto-gen + launch maintenance +
    /// manual refresh can overlap). This avoids wasted duplicate work; the
    /// re-check inside `generate(forYear:)` is the store-level guard that
    /// actually prevents duplicate rows.
    private var inFlightYears: Set<Int> = []

    // MARK: - Public

    func generateIfNeeded(forYear year: Int) async -> WrappedGenerationOutcome {
        // An existing row is final: a Wrapped is a snapshot, and its
        // narrative is deterministic on every device, so there is nothing to
        // heal or upgrade in place. A failed lookup is not
        // "no row": it ends the request instead of risking a duplicate.
        do {
            if try existingWrapped(forYear: year) != nil { return .existing }
        } catch {
            logger.error("Failed to read Wrapped \(year): \(error.localizedDescription)")
            return .failed
        }

        guard !inFlightYears.contains(year) else {
            logger.debug("Wrapped \(year) generation already in flight; skipping concurrent call.")
            return .busy
        }

        do {
            guard try meetsMinimumDataThreshold(forYear: year) else {
                logger.info("Insufficient data for Wrapped \(year). Skipping.")
                return .insufficientData
            }
        } catch {
            logger.error("Failed to read Wrapped \(year) threshold data: \(error.localizedDescription)")
            return .failed
        }

        inFlightYears.insert(year)
        defer { inFlightYears.remove(year) }
        return await generate(forYear: year)
    }

    /// The chronological, duration-annotated trip lines behind the
    /// deterministic narrative (cap 8). Ongoing trips render their
    /// elapsed-so-far length; anything final keys off `durationDays`.
    nonisolated static let narrativeTripLineCap = 8

    nonisolated static func tripLines(from trips: [Trip]) -> [String] {
        narrativeTrips(from: trips).map { trip in
            trip.isComplete
                ? "\(trip.displayName) (\(trip.durationDays ?? 0) days)"
                : "\(trip.displayName) (\(effectiveDurationDays(trip)) days so far, still ongoing)"
        }
    }

    nonisolated private static func narrativeTrips(from trips: [Trip]) -> [Trip] {
        let ordered = trips
            // (startDate, id) tiebreak: equal start times (second-resolution
            // photo imports, synced rows) must not reorder the narrative
            // trip lines across devices.
            .sorted {
                if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
                return $0.id.uuidString < $1.id.uuidString
            }

        // The cap keeps the LAST trip of the year, not the Nth-earliest: a
        // plain `.prefix(8)` would make `deterministicNarrativeText`'s "The
        // year ran from X to Y" name the 8th-EARLIEST trip as the year's end
        // for anyone with more than 8 trips — a definite factual claim, wrong,
        // in the only Wrapped story the user ever reads.
        let capped: [Trip]
        if ordered.count > narrativeTripLineCap {
            capped = Array(ordered.prefix(narrativeTripLineCap - 1)) + [ordered[ordered.count - 1]]
        } else {
            capped = ordered
        }
        return capped
    }

    #if DEBUG
    /// DEBUG-only: delete any existing Wrapped for `year` and create a fresh
    /// one from current data. Bypasses the minimum-data threshold so you can
    /// iterate on the UI/copy without waiting for enough real trips.
    ///
    /// With iCloud sync on, the delete + insert propagates to other devices.
    /// The deduplicator keeps a deterministic survivor per year (largest
    /// immutable `id.uuidString`) and absorbs newer content onto it, so a
    /// freshly regenerated recap wins over a stale duplicate regardless of
    /// sync order.
    ///
    /// The replacement is built first and the delete and insert commit in one
    /// save, so a failed read, encoding or save keeps the original row.
    func forceRegenerate(forYear year: Int) async -> Bool {
        let existing: YearWrapped?
        do {
            existing = try existingWrapped(forYear: year)
        } catch {
            logger.error("[DEBUG] Failed to read existing Wrapped \(year): \(error.localizedDescription)")
            return false
        }
        return await generate(forYear: year, replacing: existing).producedRow
    }
    #endif

    // MARK: - Generation

    /// Builds and commits the year's recap. Every required read, the stats
    /// encoding and the save are checked: any failure returns `.failed` with
    /// nothing written and nothing left pending in this long-lived context.
    /// `replacing` (DEBUG force-regenerate only) is deleted in the same save.
    private func generate(forYear year: Int, replacing: YearWrapped? = nil) async -> WrappedGenerationOutcome {
        do {
            return try buildAndCommit(forYear: year, replacing: replacing)
        } catch {
            // Discard the unsaved insert (and a replaced row's pending
            // delete). The generator only reads everything else, so there are
            // no unrelated edits here to lose. Without this, the next call's
            // existence check found the pending row and reported a recap the
            // store never received.
            modelContext.rollback()
            logger.error("Failed to generate Wrapped \(year): \(error.localizedDescription)")
            return .failed
        }
    }

    private func buildAndCommit(forYear year: Int, replacing: YearWrapped?) throws -> WrappedGenerationOutcome {
        let yearStart = startOfYear(year)
        let yearEnd = startOfYear(year + 1)

        let stayPredicate = #Predicate<Stay> {
            $0.startTime >= yearStart && $0.startTime < yearEnd
        }
        try injectFault(.staysRead)
        let allStays = try modelContext.fetch(FetchDescriptor<Stay>(predicate: stayPredicate))

        // Trip-level cards include the ONGOING trip too: Wrapped generates
        // once per year — often in December, possibly mid-trip — and never
        // regenerates, so a completed-only fetch would permanently drop the
        // trip the user was literally on.
        // Ongoing trips compete with their elapsed-so-far duration
        // (`effectiveDurationDays`); anything needing a FINAL duration
        // (mystery shortest trip via `durationDays`, `tripsCompleted`)
        // still keys off completion.
        let tripPredicate = #Predicate<Trip> {
            $0.startDate >= yearStart && $0.startDate < yearEnd
                && ($0.isComplete == true || $0.endDate == nil)
        }
        try injectFault(.tripsRead)
        let trips = try modelContext.fetch(
            FetchDescriptor<Trip>(predicate: tripPredicate, sortBy: [SortDescriptor(\.startDate)])
        )

        // Day totals span carry-in and ongoing journeys independently of
        // the start-year scope used by trip counts and superlative cards.
        let now = Date.now
        try injectFault(.travelDaysRead)
        let travelling = try TravelDays.labels(container: modelContainer, now: now)
        // Days away add the days lived at a temporary home. With none
        // declared the ledger hands the trip labels back unchanged.
        try injectFault(.awayDaysRead)
        let ledger = try TemporaryHomeLedger.result(
            travelling: travelling, container: modelContainer, now: now,
            fallbackZone: .current, checkCancellation: {})
        let dayCount = TravelDays.count(ledger.away, inYear: year)
        // Home rows are read only when a temporary home exists or existed (a
        // removed one leaves trips stamped from it); the anchors measure the
        // farthest place from the real Home of each stay's start.
        try injectFault(.homeAnchorsRead)
        let temporaryHomeRows = try modelContext.fetch(FetchDescriptor<TemporaryHome>())
        let temporaryHomes = HomeAnchors.collapsingTwins(temporaryHomeRows).map { HomeAnchor($0) }
        var anchors: [HomeAnchor] = []
        var daysStaying: Int?
        if !temporaryHomeRows.isEmpty {
            let homes = try modelContext.fetch(FetchDescriptor<Home>())
            anchors = homes.map { HomeAnchor($0) } + temporaryHomes
        }
        if !temporaryHomes.isEmpty {
            daysStaying = TravelDays.count(ledger.staying, inYear: year)
        }

        // Trip membership required: the confidence gate keeps sub-θ errand groups
        // PERMANENTLY tripless as `.destination` residue (beach evenings,
        // corridor stops). Without this filter they count into daysAbroad /
        // daysAtHome, citiesVisited, countriesVisited and farthest — numbers
        // that all mean "while travelling".
        let destinations = allStays.filter { $0.category == .destination && $0.trip != nil }
        let homeStays = allStays.filter { $0.category == .home }

        let stats = try computeStats(
            allStays: allStays,
            destinations: destinations,
            homeStays: homeStays,
            trips: trips,
            dayCount: dayCount,
            daysStaying: daysStaying,
            anchors: anchors,
            year: year,
            now: now
        )

        // Count only stays with REAL weather, not terminal `.unavailable`
        // marks: those carry no renderable data, so counting them could
        // select a weather card that comes up completely blank.
        let unavailableRaw = StayWeather.Condition.unavailable.rawValue
        let weatherCoverage = Double(destinations.filter {
            $0.weatherConditionRaw != nil && $0.weatherConditionRaw != unavailableRaw
        }.count) / max(1, Double(destinations.count))
        let transitCoverage = Double(allStays.filter { $0.transitFromPreviousRaw != nil && $0.transitFromPreviousRaw != TransitMode.unknown.rawValue }.count) /
            max(1, Double(allStays.count))

        // The narrative is deterministic: every sentence is copied from
        // `stats` and the chronological trip lines, rendered in the viewer's
        // language at display time from `stats.narrativeInputs`. No model
        // writes it: one turned "two weeks" into "two decades" on a real
        // year, and no validator catches a word-number.
        let narrative = deterministicNarrative(
            stats: stats,
            year: year,
            tripLines: Self.tripLines(from: trips)
        )

        // Re-check right before insert: a concurrent call (or a
        // CloudKit-synced row from another device) may have produced a
        // YearWrapped for this year since the fetches above. CloudKit permits
        // no unique constraint to catch a duplicate, so guard here — there is
        // no `await` between this check and the save, so no other call can
        // interleave. The row being replaced does not count.
        if let found = try existingWrapped(forYear: year),
           found.persistentModelID != replacing?.persistentModelID {
            logger.info("Wrapped \(year) already exists (created concurrently); skipping duplicate insert.")
            return .existing
        }

        // An empty blob would be a recap with no cards, reported as created.
        try injectFault(.encode)
        let statsData = try JSONEncoder().encode(stats)

        let wrapped = YearWrapped(year: year)
        wrapped.statsData = statsData
        wrapped.yearNarrative = narrative.text
        wrapped.yearNarrativeSourceRaw = narrative.source.rawValue
        wrapped.weatherCoverage = weatherCoverage
        wrapped.transitCoverage = transitCoverage

        if let replacing {
            modelContext.delete(replacing)
        }
        modelContext.insert(wrapped)

        try injectFault(.save)
        try modelContext.save()
        logger.info("Generated Wrapped \(year) successfully.")
        return .created
    }

    // MARK: - Stats

    private func computeStats(
        allStays: [Stay],
        destinations: [Stay],
        homeStays: [Stay],
        trips: [Trip],
        dayCount: Int,
        daysStaying: Int?,
        anchors: [HomeAnchor],
        year: Int,
        now: Date
    ) throws -> WrappedStats {
        var stats = WrappedStats()

        let countryCodes = Set(destinations.compactMap(\.isoCountryCode))
        stats.countriesVisited = countryCodes.count
        stats.citiesVisited = Stay.deduplicatedCityCount(from: destinations)
        // `trips` may include the ongoing trip; this field means what its
        // name says.
        stats.tripsCompleted = trips.filter(\.isComplete).count

        stats.usesTripSpanDays = true
        let daysAbroad = dayCount
        stats.daysAbroad = daysAbroad
        stats.daysAtHome = computeDaysAtHome(daysAbroad: daysAbroad, year: year)
        stats.totalDaysAbroad = daysAbroad
        stats.daysStaying = daysStaying

        if let longest = Self.longestTrip(in: trips) {
            stats.longestTripName = longest.displayName
            stats.longestTripDays = Self.effectiveDurationDays(longest)
        }

        // Farthest from home — the stored per-stay `distanceFromHomeKm`
        // (home ACTIVE AT THE STAY'S DATE, the same basis as Passport's
        // furthestKm), so a later move never re-anchors a past year and two
        // active homes cannot make it device-dependent. With a temporary
        // home, the real Home of each
        // stay's start instead (`farthestRealHomes`); recaps already stored
        // keep the numbers they were generated with.
        let realHomes = Self.farthestRealHomes(anchors)
        if let farthest = Self.farthestFromHome(destinations: destinations.map {
            (distanceKm: Self.farthestCandidateKm(
                stamped: $0.distanceFromHomeKm, latitude: $0.centroidLatitude,
                longitude: $0.centroidLongitude, startTime: $0.startTime, realHomes: realHomes),
             startTime: $0.startTime,
             id: $0.id,
             name: $0.placeGroupName)
        }) {
            stats.farthestDistanceKm = farthest.distanceKm
            stats.farthestPlaceName = farthest.name
        }

        // Deterministic tie-breaks on equal temperatures: two stays measuring
        // the same extreme must pick the same locality on every device — ties
        // break to the smaller stay id.
        let weatherStays = allStays.filter { $0.avgTemperatureC != nil }
        if let hottest = weatherStays.max(by: {
            if ($0.avgTemperatureC ?? 0) != ($1.avgTemperatureC ?? 0) {
                return ($0.avgTemperatureC ?? 0) < ($1.avgTemperatureC ?? 0)
            }
            return $0.id.uuidString > $1.id.uuidString
        }) {
            stats.hottestTempC = hottest.avgTemperatureC
            // islandName included: an island or otherwise unnamed stay has no
            // metro and often no locality, and a nil record would drop a
            // superlative the Wrapped weather card had actually measured.
            stats.hottestLocality = hottest.placeGroupName
        }
        if let coldest = weatherStays.min(by: {
            if ($0.avgTemperatureC ?? 0) != ($1.avgTemperatureC ?? 0) {
                return ($0.avgTemperatureC ?? 0) < ($1.avgTemperatureC ?? 0)
            }
            return $0.id.uuidString < $1.id.uuidString
        }) {
            stats.coldestTempC = coldest.avgTemperatureC
            stats.coldestLocality = coldest.placeGroupName
        }
        stats.weatherExtremesSafe = Self.weatherExtremesSafe(allStays: allStays)

        // Rainiest trip: per-trip sum of stay precipitation; `max(by:)` keeps
        // the FIRST maximum on ties (trips arrive in fetch order, stable for a
        // given store). Year-bounded stays only, like hottest/coldest: a
        // December trip ending in January must not sum January rain into the
        // prior year's immutable snapshot.
        let rainYearStart = startOfYear(year)
        let rainYearEnd = startOfYear(year + 1)
        let tripPrecipitation = trips.map { trip -> (name: String, mm: Double) in
            let inYear = (trip.stays ?? []).filter {
                $0.startTime >= rainYearStart && $0.startTime < rainYearEnd
            }
            return (trip.displayName, inYear.compactMap(\.precipitationMm).reduce(0, +))
        }
        if let rainiest = tripPrecipitation.max(by: { $0.mm < $1.mm }), rainiest.mm > 0 {
            stats.rainiestTripName = rainiest.name
            stats.rainiestPrecipitationMm = rainiest.mm
        }

        // Per-mode splits read the stored inference attribution (current
        // inference stores only `.flight`; ground modes are legacy values)…
        let flightStays = allStays.filter { $0.transitFromPreviousRaw == TransitMode.flight.rawValue }
        stats.flightKm = flightStays.compactMap(\.distanceFromPreviousKm).reduce(0, +)
        let driveStays = allStays.filter { $0.transitFromPreviousRaw == TransitMode.automotive.rawValue }
        stats.driveKm = driveStays.compactMap(\.distanceFromPreviousKm).reduce(0, +)
        let walkStays = allStays.filter { $0.transitFromPreviousRaw == TransitMode.walking.rawValue }
        stats.walkKm = walkStays.compactMap(\.distanceFromPreviousKm).reduce(0, +)

        // …but the TOTAL is geometric: chronological great-circle legs
        // between consecutive stay centroids, skipping pure home/routine →
        // home/routine hops (commutes aren't travel). Summing
        // `distanceFromPreviousKm` would count only inference-attributed legs
        // — virtually nothing for imported or older data. Untracked segments
        // undercount — an honest floor, never a fabrication.
        stats.totalGreatCircleKm = Self.journeyDistanceKm(
            of: allStays
                // (startTime, id) tiebreak: equal-time stays
                // must not reorder legs and change the persisted km total
                // between devices.
                .sorted {
                    if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
                    return $0.id.uuidString < $1.id.uuidString
                }
                .map { (latitude: $0.centroidLatitude,
                        longitude: $0.centroidLongitude,
                        // Tripless residue is local life, not travel: legs
                        // to/from a suppressed errand cluster or airport
                        // drop-by must not join "distance travelled".
                        // Trip-member transit stays —
                        // incl. the airport legs of real trips — still count.
                        isLocal: $0.category == .home || $0.category == .routine
                            || $0.trip == nil) }
        )

        let priorCutoff = startOfYear(year)
        let priorPredicate = #Predicate<Stay> {
            $0.startTime < priorCutoff && $0.isoCountryCode != nil
        }
        var priorDescriptor = FetchDescriptor<Stay>(predicate: priorPredicate)
        priorDescriptor.propertiesToFetch = [\.isoCountryCode]
        // A failed read is not "no earlier countries": it would stamp every
        // country of the year as first-time in the immutable snapshot.
        try injectFault(.priorCountriesRead)
        let priorStays = try modelContext.fetch(priorDescriptor)
        let priorCodes = Set(priorStays.compactMap(\.isoCountryCode))
        // Same basis as countriesVisited (trip-member destinations only); a
        // home country is never a new stamp. A temporary home's country can
        // be one, so only home stays recorded as the real Home's count here
        // (`HomeAnchors.recordedOwner`, never the nearest centre).
        let temporaryHomeIDs = Set(anchors.filter(\.isTemporary).map(\.id))
        let homeCountryCodes = Set(homeStays.filter { stay in
            HomeAnchors.recordedOwner(
                temporaryHomeID: stay.temporaryHomeID,
                knownTemporaryHomeIDs: temporaryHomeIDs) == .realHome
        }.compactMap(\.isoCountryCode))
        // Sorted: Set iteration order would persist a different
        // first-time-country order per run/device into the immutable snapshot.
        stats.newCountryCodes = countryCodes.subtracting(priorCodes)
            .subtracting(homeCountryCodes).sorted()

        let countryTrips = Dictionary(grouping: trips, by: { trip -> String? in
            trip.countryCodes.split(separator: ",").first.map(String.init)
        })
        // Tie-break on equal trip counts: the count-only
        // comparator resolved ties by Dictionary hash order — ties now go
        // to the lexicographically smaller ISO code on every device.
        if let (code, tripList) = countryTrips.compactMap({ k, v -> (String, [Trip])? in
            guard let k else { return nil }; return (k, v)
        }).max(by: {
            if $0.1.count != $1.1.count { return $0.1.count < $1.1.count }
            return $0.0 > $1.0
        }) {
            stats.mostVisitedCountryCode = code
            stats.mostVisitedCountryTripCount = tripList.count
        }

        let mysteryFact = computeMysteryFactValue(
            stays: allStays, destinations: destinations, trips: trips, year: year
        )
        stats.mysteryFact = mysteryFact
        stats.mysteryFactText = mysteryFact?.render(locale: Locale(identifier: "en"))

        let narrativeTrips = Self.narrativeTrips(from: trips)
        stats.narrativeInputs = NarrativeInputs(
            year: year,
            tripDisplayNames: narrativeTrips.map(\.displayName),
            tripStartDates: narrativeTrips.map(\.startDate),
            longestTripName: stats.longestTripName,
            longestTripDays: stats.longestTripDays > 0 ? stats.longestTripDays : nil,
            farthestPlaceName: stats.farthestPlaceName,
            farthestDistanceKm: stats.farthestDistanceKm > 0 ? stats.farthestDistanceKm : nil,
            firstTimeCountryISOCodes: stats.newCountryCodes
        )

        // A failed count is not zero places: it would commit a wrong total
        // into the immutable snapshot.
        stats.totalHexesVisited = try countHexesForYear(year)

        return stats
    }

    // MARK: - Weather extremes-safe gate

    /// Whether Card 5 may display the measured hottest/coldest as the year's
    /// records: true iff a measurement
    /// exists AND no still-enrichable un-measured stay's seasonal band could
    /// plausibly beat either record (`WeatherEnrichmentPlanner.extremesAreSafe`).
    ///
    /// "Still-enrichable" mirrors `WeatherEnricher`'s opportunistic
    /// eligibility exactly — a stay the enricher will NEVER measure must not
    /// hold the gate open forever:
    ///   • terminal marks excluded (`weatherConditionRaw != nil` — includes
    ///     `.unavailable`);
    ///   • pre-WeatherKit-floor stays excluded (they become terminal);
    ///   • home/routine stays count only in extreme months (Jun–Aug,
    ///     Dec–Feb) — the same accepted blind spot enrichment has always
    ///     had (a freak October home heat wave is never measured, so it is
    ///     also never waited for).
    ///
    /// `nonisolated` + `[Stay]`-in, value-out for direct unit testing — the
    /// `computeDaysAbroad` precedent.
    nonisolated static func weatherExtremesSafe(allStays: [Stay]) -> Bool {
        let measuredTemps = allStays.compactMap(\.avgTemperatureC)
        let unmeasured = allStays
            .filter { stay in
                guard stay.weatherConditionRaw == nil else { return false }
                guard stay.endTime >= WeatherEnricher.weatherKitFloorDate else { return false }
                switch stay.category {
                case .destination, .transit:
                    // MIRRORS the enricher's eligibility (the standing
                    // invariant): tripless residue is not fetched there, so it
                    // must never be waited for
                    // either — an unmeasured suppressed errand stay would
                    // otherwise block the Wrapped weather card forever.
                    return stay.trip != nil
                case .home, .routine:
                    return WeatherEnrichmentPlanner.extremeHomeMonths
                        .contains(WeatherEnrichmentPlanner.monthUTC(of: stay.startTime))
                case .unclassified:
                    // Outside both opportunistic candidate windows — never
                    // measured, so never waited for.
                    return false
                }
            }
            .map { stay in
                WeatherEnrichmentPlanner.Candidate(
                    id: stay.id,
                    latitude: stay.centroidLatitude,
                    longitude: stay.centroidLongitude,
                    startTime: stay.startTime,
                    endTime: stay.endTime,
                    tripID: stay.trip?.id,
                    isTripStay: stay.category == .destination || stay.category == .transit
                )
            }
        return WeatherEnrichmentPlanner.extremesAreSafe(
            unmeasured: unmeasured,
            measuredMaxC: measuredTemps.max(),
            measuredMinC: measuredTemps.min()
        )
    }

    // MARK: - Trip superlatives

    /// A trip's day count for Wrapped comparisons: the final duration when
    /// closed, the elapsed-so-far count when ongoing (same `max(1, days+1)`
    /// shape as `Trip.durationDays`). An ongoing trip's number can only
    /// grow after the artifact is generated — an honest floor.
    nonisolated static func effectiveDurationDays(_ trip: Trip) -> Int {
        if let days = trip.durationDays { return days }
        let days = Calendar.current.dateComponents(
            [.day], from: trip.startDate, to: .now
        ).day ?? 0
        return max(1, days + 1)
    }

    /// The "longest trip" pick, with an EXPLICIT deterministic tie rule (never
    /// fetch order): most days wins; equal day counts → the year's EARLIER trip
    /// wins (it held the record first); identical start dates → smaller id.
    /// Ongoing trips compete with their elapsed-so-far length.
    nonisolated static func longestTrip(in trips: [Trip]) -> Trip? {
        trips.max { a, b in
            let aDays = effectiveDurationDays(a)
            let bDays = effectiveDurationDays(b)
            if aDays != bDays { return aDays < bDays }
            if a.startDate != b.startDate { return a.startDate > b.startDate }
            return a.id.uuidString > b.id.uuidString
        }
    }

    // MARK: - Mystery Fact

    nonisolated func computeMysteryFactValue(
        stays: [Stay],
        destinations: [Stay],
        trips: [Trip],
        year: Int
    ) -> MysteryFact? {
        var candidates: [(fact: MysteryFact, score: Double)] = []

        let namedDestinations = destinations.compactMap { stay -> (name: String, stay: Stay)? in
            guard let name = stay.placeGroupName, !name.isEmpty, Trip.isUsableDestinationName(name) else { return nil }
            return (name, stay)
        }
        let cityVisits = Dictionary(grouping: namedDestinations, by: \.name)
        for (city, visits) in cityVisits {
            let tripIDs = Set(visits.compactMap { $0.stay.trip?.id })
            if tripIDs.count >= 3 {
                candidates.append((.returnedCity(name: city, times: tripIDs.count), Double(tripIDs.count) * 2))
            }
        }

        let airportDays = stays.filter(\.isAirport).map(\.durationMinutes).reduce(0, +) / (60 * 24)
        if airportDays >= 1 {
            candidates.append((.airportDays(count: airportDays), Double(airportDays) * 3))
        }

        if let shortest = trips.min(by: { ($0.durationDays ?? Int.max) < ($1.durationDays ?? Int.max) }),
           let days = shortest.durationDays, days <= 2 {
            let name = shortest.displayName
            candidates.append((.shortestTrip(name: name, days: days), 4))
        }

        return candidates.max(by: { $0.score < $1.score })?.fact
    }

    // MARK: - Narrative

    private struct NarrativeOutput {
        let text: String
        let source: SummarySource
    }

    private func deterministicNarrative(stats: WrappedStats, year: Int, tripLines: [String] = []) -> NarrativeOutput {
        let text: String
        if let inputs = stats.narrativeInputs {
            text = Self.deterministicNarrative(
                from: inputs,
                stats: stats,
                locale: Locale(identifier: "en")
            )
        } else {
            text = Self.deterministicNarrativeText(
                stats: stats,
                year: year,
                tripLines: tripLines
            )
        }
        return NarrativeOutput(
            text: text,
            source: .deterministic
        )
    }

    /// Narrative builder for a stats blob without `narrativeInputs` (rows
    /// written before the structured inputs existed) — internal as a test
    /// seam. Every claim is copied verbatim from `stats`/`tripLines`, so it
    /// is grounded by construction: calendar arc, longest trip, farthest
    /// point, first-time countries.
    nonisolated static func deterministicNarrativeText(
        stats: WrappedStats,
        year: Int,
        tripLines: [String]
    ) -> String {
        let names = tripLines.map {
            $0.replacingOccurrences(of: #" \([^)]*\)$"#, with: "", options: .regularExpression)
        }
        let inputs = NarrativeInputs(
            year: year,
            tripDisplayNames: names,
            tripStartDates: [],
            longestTripName: stats.longestTripName,
            longestTripDays: stats.longestTripDays > 0 ? stats.longestTripDays : nil,
            farthestPlaceName: stats.farthestPlaceName,
            farthestDistanceKm: stats.farthestDistanceKm > 0 ? stats.farthestDistanceKm : nil,
            firstTimeCountryISOCodes: stats.newCountryCodes
        )
        return deterministicNarrative(
            from: inputs,
            stats: stats,
            locale: Locale(identifier: "en")
        )
    }

    nonisolated static func deterministicNarrative(
        from inputs: NarrativeInputs,
        stats: WrappedStats,
        locale: Locale,
        bundle: LocalizedStringResource.BundleDescription? = nil
    ) -> String {
        var parts: [String] = []

        if stats.citiesVisited > 0 {
            let opening: String
            switch (
                stats.countriesVisited == 1,
                stats.citiesVisited == 1,
                stats.tripsCompleted == 1
            ) {
            case (true, true, true):
                opening = localizedRendererString(
                    localized: "wrapped.narrative.opening.with-cities.one-one-one",
                    defaultValue: "In \(inputs.year, format: .number.grouping(.never)), you visited \(stats.countriesVisited, format: .number.grouping(.never)) country and \(stats.citiesVisited, format: .number.grouping(.never)) city across \(stats.tripsCompleted, format: .number.grouping(.never)) trip.",
                    bundle: bundle,
                    locale: locale
                )
            case (true, true, false):
                opening = localizedRendererString(
                    localized: "wrapped.narrative.opening.with-cities.one-one-other",
                    defaultValue: "In \(inputs.year, format: .number.grouping(.never)), you visited \(stats.countriesVisited, format: .number.grouping(.never)) country and \(stats.citiesVisited, format: .number.grouping(.never)) city across \(stats.tripsCompleted, format: .number.grouping(.never)) trips.",
                    bundle: bundle,
                    locale: locale
                )
            case (true, false, true):
                opening = localizedRendererString(
                    localized: "wrapped.narrative.opening.with-cities.one-other-one",
                    defaultValue: "In \(inputs.year, format: .number.grouping(.never)), you visited \(stats.countriesVisited, format: .number.grouping(.never)) country and \(stats.citiesVisited, format: .number.grouping(.never)) cities across \(stats.tripsCompleted, format: .number.grouping(.never)) trip.",
                    bundle: bundle,
                    locale: locale
                )
            case (true, false, false):
                opening = localizedRendererString(
                    localized: "wrapped.narrative.opening.with-cities.one-other-other",
                    defaultValue: "In \(inputs.year, format: .number.grouping(.never)), you visited \(stats.countriesVisited, format: .number.grouping(.never)) country and \(stats.citiesVisited, format: .number.grouping(.never)) cities across \(stats.tripsCompleted, format: .number.grouping(.never)) trips.",
                    bundle: bundle,
                    locale: locale
                )
            case (false, true, true):
                opening = localizedRendererString(
                    localized: "wrapped.narrative.opening.with-cities.other-one-one",
                    defaultValue: "In \(inputs.year, format: .number.grouping(.never)), you visited \(stats.countriesVisited, format: .number.grouping(.never)) countries and \(stats.citiesVisited, format: .number.grouping(.never)) city across \(stats.tripsCompleted, format: .number.grouping(.never)) trip.",
                    bundle: bundle,
                    locale: locale
                )
            case (false, true, false):
                opening = localizedRendererString(
                    localized: "wrapped.narrative.opening.with-cities.other-one-other",
                    defaultValue: "In \(inputs.year, format: .number.grouping(.never)), you visited \(stats.countriesVisited, format: .number.grouping(.never)) countries and \(stats.citiesVisited, format: .number.grouping(.never)) city across \(stats.tripsCompleted, format: .number.grouping(.never)) trips.",
                    bundle: bundle,
                    locale: locale
                )
            case (false, false, true):
                opening = localizedRendererString(
                    localized: "wrapped.narrative.opening.with-cities.other-other-one",
                    defaultValue: "In \(inputs.year, format: .number.grouping(.never)), you visited \(stats.countriesVisited, format: .number.grouping(.never)) countries and \(stats.citiesVisited, format: .number.grouping(.never)) cities across \(stats.tripsCompleted, format: .number.grouping(.never)) trip.",
                    bundle: bundle,
                    locale: locale
                )
            case (false, false, false):
                opening = localizedRendererString(
                    localized: "wrapped.narrative.opening.with-cities.other-other-other",
                    defaultValue: "In \(inputs.year, format: .number.grouping(.never)), you visited \(stats.countriesVisited, format: .number.grouping(.never)) countries and \(stats.citiesVisited, format: .number.grouping(.never)) cities across \(stats.tripsCompleted, format: .number.grouping(.never)) trips.",
                    bundle: bundle,
                    locale: locale
                )
            }
            parts.append(opening)
        } else {
            let opening: String
            switch (stats.countriesVisited == 1, stats.tripsCompleted == 1) {
            case (true, true):
                opening = localizedRendererString(
                    localized: "wrapped.narrative.opening.without-cities.one-one",
                    defaultValue: "In \(inputs.year, format: .number.grouping(.never)), you visited \(stats.countriesVisited, format: .number.grouping(.never)) country across \(stats.tripsCompleted, format: .number.grouping(.never)) trip.",
                    bundle: bundle,
                    locale: locale
                )
            case (true, false):
                opening = localizedRendererString(
                    localized: "wrapped.narrative.opening.without-cities.one-other",
                    defaultValue: "In \(inputs.year, format: .number.grouping(.never)), you visited \(stats.countriesVisited, format: .number.grouping(.never)) country across \(stats.tripsCompleted, format: .number.grouping(.never)) trips.",
                    bundle: bundle,
                    locale: locale
                )
            case (false, true):
                opening = localizedRendererString(
                    localized: "wrapped.narrative.opening.without-cities.other-one",
                    defaultValue: "In \(inputs.year, format: .number.grouping(.never)), you visited \(stats.countriesVisited, format: .number.grouping(.never)) countries across \(stats.tripsCompleted, format: .number.grouping(.never)) trip.",
                    bundle: bundle,
                    locale: locale
                )
            case (false, false):
                opening = localizedRendererString(
                    localized: "wrapped.narrative.opening.without-cities.other-other",
                    defaultValue: "In \(inputs.year, format: .number.grouping(.never)), you visited \(stats.countriesVisited, format: .number.grouping(.never)) countries across \(stats.tripsCompleted, format: .number.grouping(.never)) trips.",
                    bundle: bundle,
                    locale: locale
                )
            }
            parts.append(opening)
        }

        if let first = inputs.tripDisplayNames.first,
           let last = inputs.tripDisplayNames.last,
           inputs.tripDisplayNames.count >= 2,
           first != last {
            parts.append(localizedRendererString(
                localized: "wrapped.narrative.calendar-arc",
                defaultValue: "The year ran from \(first) to \(last).",
                bundle: bundle,
                locale: locale
            ))
        }

        if let longest = inputs.longestTripName,
           let longestDays = inputs.longestTripDays,
           longestDays > 0 {
            if longestDays == 1 {
                parts.append(localizedRendererString(
                    localized: "wrapped.narrative.longest-trip.one",
                    defaultValue: "Your longest trip, \(longest), lasted \(longestDays, format: .number.grouping(.never)) day.",
                    bundle: bundle,
                    locale: locale
                ))
            } else {
                parts.append(localizedRendererString(
                    localized: "wrapped.narrative.longest-trip.other",
                    defaultValue: "Your longest trip, \(longest), lasted \(longestDays, format: .number.grouping(.never)) days.",
                    bundle: bundle,
                    locale: locale
                ))
            }
        }

        if let farthest = inputs.farthestPlaceName,
           let farthestDistanceKm = inputs.farthestDistanceKm,
           farthestDistanceKm > 0 {
            parts.append(localizedRendererString(
                localized: "wrapped.narrative.farthest-place",
                defaultValue: "You made it as far as \(farthest), \(Int(farthestDistanceKm), format: .number.grouping(.never)) km from home.",
                bundle: bundle,
                locale: locale
            ))
        }

        if stats.totalGreatCircleKm > 100 {
            parts.append(localizedRendererString(
                localized: "wrapped.narrative.total-distance",
                defaultValue: "You covered \(Int(stats.totalGreatCircleKm), format: .number.grouping(.never)) km in total.",
                bundle: bundle,
                locale: locale
            ))
        }

        if !inputs.firstTimeCountryISOCodes.isEmpty {
            let language = locale.language.languageCode?.identifier
            let hasKnownNonEnglishLanguage = language.map {
                $0 != "en"
                    && $0 != "und"
                    && Locale(identifier: "en").localizedString(forLanguageCode: $0) != nil
            } ?? false
            let countryLocale = hasKnownNonEnglishLanguage ? locale : Locale(identifier: "en_US")
            let countryNames = inputs.firstTimeCountryISOCodes.map {
                localizedCountryName(iso: $0, fallback: $0, locale: countryLocale) ?? $0
            }
            if countryNames.count <= 3 {
                let joined = localizedList(countryNames, locale: locale)
                parts.append(localizedRendererString(
                    localized: "wrapped.narrative.first-time-countries.named",
                    defaultValue: "You set foot in \(joined) for the first time.",
                    bundle: bundle,
                    locale: locale
                ))
            } else {
                parts.append(localizedRendererString(
                    localized: "wrapped.narrative.first-time-countries.count",
                    defaultValue: "You set foot in \(countryNames.count, format: .number.grouping(.never)) countries for the first time.",
                    bundle: bundle,
                    locale: locale
                ))
            }
        }

        if stats.daysAbroad > 0 {
            if stats.usesTripSpanDays == true {
                if stats.daysAbroad == 1 {
                    parts.append(localizedRendererString(
                        localized: "wrapped.narrative.days-away.one",
                        defaultValue: "You spent \(stats.daysAbroad, format: .number.grouping(.never)) day away and \(stats.daysAtHome, format: .number.grouping(.never)) at home.",
                        bundle: bundle,
                        locale: locale
                    ))
                } else {
                    parts.append(localizedRendererString(
                        localized: "wrapped.narrative.days-away.other",
                        defaultValue: "You spent \(stats.daysAbroad, format: .number.grouping(.never)) days away and \(stats.daysAtHome, format: .number.grouping(.never)) at home.",
                        bundle: bundle,
                        locale: locale
                    ))
                }
            } else if stats.daysAbroad == 1 {
                parts.append(localizedRendererString(
                    localized: "wrapped.narrative.days-abroad.one",
                    defaultValue: "You spent \(stats.daysAbroad, format: .number.grouping(.never)) day abroad and \(stats.daysAtHome, format: .number.grouping(.never)) at home.",
                    bundle: bundle,
                    locale: locale
                ))
            } else {
                parts.append(localizedRendererString(
                    localized: "wrapped.narrative.days-abroad.other",
                    defaultValue: "You spent \(stats.daysAbroad, format: .number.grouping(.never)) days abroad and \(stats.daysAtHome, format: .number.grouping(.never)) at home.",
                    bundle: bundle,
                    locale: locale
                ))
            }
        }

        return parts.joined(separator: " ")
    }

    nonisolated private static func localizedList(_ items: [String], locale: Locale) -> String {
        let legacy: String
        switch items.count {
        case 0: legacy = ""
        case 1: legacy = items[0]
        default: legacy = "\(items.dropLast().joined(separator: ", ")) and \(items[items.count - 1])"
        }

        guard let language = locale.language.languageCode?.identifier,
              language != "en", language != "und",
              Locale(identifier: "en").localizedString(forLanguageCode: language) != nil else {
            return legacy
        }
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: items) ?? legacy
    }

    /// Great-circle sum over consecutive stay legs, excluding legs whose
    /// BOTH endpoints are home/routine (daily commutes). Pure and
    /// order-respecting — callers pass chronologically sorted rows.
    nonisolated static func journeyDistanceKm(
        of stays: [(latitude: Double, longitude: Double, isLocal: Bool)]
    ) -> Double {
        var totalKm: Double = 0
        for (previous, current) in zip(stays, stays.dropFirst()) {
            if previous.isLocal && current.isLocal { continue }
            let from = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
            let to = CLLocation(latitude: current.latitude, longitude: current.longitude)
            totalKm += from.distance(from: to) / 1000.0
        }
        return totalKm
    }

    // MARK: - Helpers

    /// Throws on a failed read: a failed lookup is not "no row" (a duplicate
    /// insert) and not "a row exists" (a recap reported ready that isn't).
    private func existingWrapped(forYear year: Int) throws -> YearWrapped? {
        let y = year
        let predicate = #Predicate<YearWrapped> { $0.year == y }
        try injectFault(.existingRead)
        return try modelContext.fetch(FetchDescriptor<YearWrapped>(predicate: predicate)).first
    }

    /// True when `year` holds a stay before the data cutoff month: the part
    /// of the threshold no later travel that year can supply. The Dec 1
    /// reminder is scheduled only then, so a launch after Delete All Data
    /// does not promise a recap of nothing. Throws on a failed count.
    func hasEarlyData(forYear year: Int) throws -> Bool {
        let yearStart = startOfYear(year)
        guard let cutoffDate = calendar.date(
            from: DateComponents(year: year, month: Self.minimumDataMonthCutoff, day: 1)) else {
            return false
        }
        let firstStayPredicate = #Predicate<Stay> {
            $0.startTime >= yearStart && $0.startTime < cutoffDate
        }
        try injectFault(.thresholdRead)
        return try modelContext.fetchCount(
            FetchDescriptor<Stay>(predicate: firstStayPredicate)
        ) > 0
    }

    /// Internal (not private) as a test seam: the gate's own boundaries are
    /// pinned directly (`WrappedGenerateIfNeededGateTests`). Throws on a
    /// failed count, which is not "too little travel".
    func meetsMinimumDataThreshold(forYear year: Int) throws -> Bool {
        let yearStart = startOfYear(year)
        let yearEnd = startOfYear(year + 1)
        let hasEarlyData = try hasEarlyData(forYear: year)

        // `< yearEnd` matters when generating a PAST year's recap (the
        // January path of the Nov/Dec sprint, Settings regenerate): unbound,
        // every later year's trips would count toward this year's minimum.
        let tripPredicate = #Predicate<Trip> {
            $0.startDate >= yearStart && $0.startDate < yearEnd && $0.isComplete == true
        }
        let tripCount = try modelContext.fetchCount(
            FetchDescriptor<Trip>(predicate: tripPredicate)
        )

        return hasEarlyData && tripCount >= Self.minimumTrips
    }

    /// Pure winner-pick for the Wrapped "farthest from home" stat over the
    /// stored per-stay distances. Sentinel-guarded: a stay recorded with no
    /// homes at all carries `Double.greatestFiniteMagnitude`, and nothing on
    /// Earth is farther than half its circumference — such rows are not
    /// measurements and never win. Deterministic ties:
    /// equal distance → earlier `startTime` → smaller id, so two devices
    /// (or two regenerations) always name the same place.
    nonisolated static func farthestFromHome(
        destinations: [(distanceKm: Double, startTime: Date, id: UUID, name: String?)]
    ) -> (distanceKm: Double, name: String?)? {
        let measured = destinations.filter { $0.distanceKm > 0 && $0.distanceKm < 25_000 }
        guard let winner = measured.max(by: { lhs, rhs in
            if lhs.distanceKm != rhs.distanceKm { return lhs.distanceKm < rhs.distanceKm }
            if lhs.startTime != rhs.startTime { return lhs.startTime > rhs.startTime }
            return lhs.id.uuidString > rhs.id.uuidString
        }) else { return nil }
        return (winner.distanceKm, winner.name)
    }

    /// The homes a "farthest from home" candidate is measured from: nil when
    /// `anchors` is empty, so each candidate keeps its stored distance;
    /// otherwise the real Homes alone. Callers read anchors only for a store
    /// that holds or held a temporary home: a trip that left one was stamped
    /// from it, removed or not, so stamps no longer share one origin. The
    /// stamps themselves are never rewritten.
    nonisolated static func farthestRealHomes(
        _ anchors: [HomeAnchor]
    ) -> [StayClusterer.HomeWindow]? {
        guard !anchors.isEmpty else { return nil }
        return anchors.filter { !$0.isTemporary }.map { StayClusterer.HomeWindow($0) }
    }

    /// One candidate's distance: `stamped` when `realHomes` is nil, else the
    /// distance from the real Home of the stay's start, with the real-only
    /// fallback of `closestHomeDistanceKm` for a stay before every Home.
    nonisolated static func farthestCandidateKm(
        stamped: Double, latitude: Double, longitude: Double, startTime: Date,
        realHomes: [StayClusterer.HomeWindow]?
    ) -> Double {
        guard let realHomes else { return stamped }
        return StayClusterer.closestHomeDistanceKm(
            latitude: latitude, longitude: longitude, atTime: startTime, homes: realHomes)
    }

    /// The same inclusive trip-span date union used by Stats and Passport.
    nonisolated func computeDaysAbroad(
        trips: [Trip], year: Int, now: Date = .now, fallbackZone: TimeZone = .current
    ) -> Int {
        TravelDays.count(TravelDays.labels(trips: trips, now: now, fallbackZone: fallbackZone), inYear: year)
    }

    /// Days at home for `year`: the year's total days minus `daysAbroad`, floored
    /// at 0. The `max(0, …)` guards against any future drift where `daysAbroad`
    /// could exceed `totalDays`. nonisolated/pure (uses only the
    /// nonisolated `calendar`/`startOfYear`), so it is unit-testable directly.
    nonisolated func computeDaysAtHome(daysAbroad: Int, year: Int) -> Int {
        let totalDays = TravelDays.daysInYear(year)
        return max(0, totalDays - daysAbroad)
    }

    private func countHexesForYear(_ year: Int) throws -> Int {
        let yearStart = startOfYear(year)
        let yearEnd = startOfYear(year + 1)
        let predicate = #Predicate<HexVisit> {
            $0.firstVisited >= yearStart && $0.firstVisited < yearEnd
        }
        try injectFault(.hexCountRead)
        return try modelContext.fetchCount(FetchDescriptor<HexVisit>(predicate: predicate))
    }

    /// UTC Gregorian frame for existing non-day statistic fetch scopes.
    /// Travel-day labels use their own boundary zones before year bucketing.
    /// (Notification scheduling intentionally keeps `Calendar.current` — a Dec-1
    /// 9am reminder is a device-local event.)
    nonisolated var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    nonisolated func startOfYear(_ year: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: 1, day: 1))!
    }

    // MARK: - Notification Scheduling

    /// Category identifier used to differentiate Wrapped notifications from
    /// other app notifications in the UNUserNotificationCenterDelegate.
    static let wrappedNotificationCategory = "WRAPPED_YEAR"

    /// The launch latch for `year`'s Dec 1 reminder.
    nonisolated static func scheduledNotificationKey(forYear year: Int) -> String {
        "\(scheduledNotificationKeyPrefix)\(year)"
    }

    private nonisolated static let scheduledNotificationKeyPrefix = "wrappedNotificationScheduled_"

    /// Delete All Data drops every year's latch with the reminders, so the
    /// next launch decides afresh (and schedules only for a year with data).
    nonisolated static func clearScheduledNotificationFlags(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(scheduledNotificationKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Schedules the Dec-1 "Wrapped is ready" notification for `year`.
    /// Returns `false` (and schedules nothing) when Dec 1 of `year` is already in
    /// the past: a non-repeating calendar trigger whose match has passed never
    /// fires, so the caller must NOT mark it scheduled — otherwise the reminder
    /// is silently dead forever for a user who onboards / enables notifications
    /// after Dec 1. On an async `add()` failure it clears the per-year scheduled
    /// flag so the next launch retries.
    @discardableResult
    nonisolated static func scheduleWrappedNotification(forYear year: Int) -> Bool {
        // `year` is Gregorian, like the recap windows: pin the calendar so a
        // Buddhist or Japanese device calendar does not read it as another era.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        var dateComponents = DateComponents()
        dateComponents.calendar = cal
        dateComponents.year = year
        dateComponents.month = 12
        dateComponents.day = 1
        dateComponents.hour = 9

        guard let fireDate = cal.date(from: dateComponents), fireDate > Date.now else {
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = NSString.localizedUserNotificationString(
            forKey: "wrapped.notification.ready.title",
            arguments: [year.formatted(.number.grouping(.never))]
        )
        content.body = NSString.localizedUserNotificationString(
            forKey: "wrapped.notification.ready.body",
            arguments: []
        )
        content.sound = .default
        content.categoryIdentifier = wrappedNotificationCategory
        content.userInfo = ["kind": "wrapped", "year": year]

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
        let request = UNNotificationRequest(
            identifier: "wrapped-\(year)",
            content: content,
            trigger: trigger
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Logger(subsystem: "com.travellog.app", category: "YearWrappedGenerator")
                    .error("Failed to schedule Wrapped notification: \(error.localizedDescription)")
                // Adding failed — clear the per-year flag so the next launch retries.
                UserDefaults.standard.removeObject(forKey: scheduledNotificationKey(forYear: year))
            }
        }
        return true
    }
}
