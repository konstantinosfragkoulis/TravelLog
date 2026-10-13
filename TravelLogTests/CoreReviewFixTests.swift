//
//  CoreReviewFixTests.swift
//  TravelLogTests
//
//  Regression tests for home matching, geocode progress, deduplication and deleted stays.
//
//  `matchesHome` pass 2 filtered to `endedAt == nil`, which made ending
//  a home RETROACTIVE: for a stay predating every home record, "is this home
//  still active?" is meaningless (every home window lies in that stay's
//  future), yet ending home A stopped A's ring from matching pre-history
//  stays. `applyHomeChangeCore`'s stale-home pass then unstamped every one of
//  them, dissolving the trip boundaries of the whole imported era.
//
//  `geocodeUngeocodedStays` measured progress by the stay's post-write
//  STATE (`locality != nil || country != nil`) while its fetch predicate
//  selects on `locality == nil`. A coordinate resolving to country-without-
//  locality therefore counted as progress on EVERY pass forever while never
//  leaving the selection set and never reaching the unresolvable-exclusion
//  arm - voiding the drain loop's `passGeocoded == 0` termination guard.
//
//  The home-matching and geocode-progress tests cover these regressions.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct CoreReviewFixTests {

    // MARK: - ending a home must not erase pre-history home stays

    private let year2016 = Date(timeIntervalSince1970: 1_451_606_400) // 2016-01-01
    private let year2024 = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01
    private let year2025 = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01

    /// Athens and Berlin - far enough apart that neither ring contains the other.
    private let athens = (lat: 37.9838, lon: 23.7275)
    private let berlin = (lat: 52.5739, lon: 13.4172)

    private func ring(
        _ coord: (lat: Double, lon: Double),
        startedAt: Date,
        endedAt: Date? = nil,
        radiusKm: Double = 3
    ) -> TripClassifier.HomeRing {
        TripClassifier.HomeRing(
            latitude: coord.lat,
            longitude: coord.lon,
            radiusKm: radiusKm,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    private func matches(_ coord: (lat: Double, lon: Double), at start: Date, homes: [TripClassifier.HomeRing]) -> Bool {
        TripClassifier.matchesHome(
            stayStart: start,
            latitude: coord.lat,
            longitude: coord.lon,
            homes: homes
        )
    }

    @Test("Pre-history stay matches its home ring even after that home is ended")
    func preHistoryStaySurvivesHomeReplacement() {
        // Before the move: one active Athens home registered in 2024. A 2016
        // Athens stay predates it and matches via pass 2 - this is what gives
        // the imported era its trip boundaries.
        let beforeMove = [ring(athens, startedAt: year2024)]
        #expect(matches(athens, at: year2016, homes: beforeMove))

        // "I Moved - Replace Existing": Athens gains an endedAt, Berlin is
        // added. The 2016 Athens stay STILL predates every home record, so it
        // must still classify as home. Pre-fix this returned false, and the
        // stale-home pass unstamped it (and every stay like it).
        let afterMove = [
            ring(athens, startedAt: year2024, endedAt: year2025),
            ring(berlin, startedAt: year2025),
        ]
        #expect(matches(athens, at: year2016, homes: afterMove))
    }

    @Test("Pass 1 window semantics are unchanged by the pass-2 fix")
    func endedHomeStillBoundsItsOwnWindow() {
        let homes = [
            ring(athens, startedAt: year2024, endedAt: year2025),
            ring(berlin, startedAt: year2025),
        ]
        // Inside Athens' active window -> home.
        #expect(matches(athens, at: year2024.addingTimeInterval(86_400), homes: homes))
        // AFTER Athens ended, an Athens stay is a trip, not home. Pass 2 must
        // not rescue it: the stay does not predate every home record.
        #expect(!matches(athens, at: year2025.addingTimeInterval(86_400), homes: homes))
        // Berlin during its own window is home.
        #expect(matches(berlin, at: year2025.addingTimeInterval(86_400), homes: homes))
    }

    // MARK: - geocode progress is a change, not a state

    private func outcome(
        current: PingRecorder.StayPlaceFields,
        locality: String? = nil,
        country: String? = nil,
        iso: String? = nil,
        admin: String? = nil,
        settled: Bool
    ) -> PingRecorder.StayGeocodeOutcome {
        PingRecorder.stayGeocodeOutcome(
            current: current,
            resolvedLocality: locality,
            resolvedCountry: country,
            resolvedISOCountryCode: iso,
            resolvedAdministrativeArea: admin,
            stayHasSettled: settled
        )
    }

    /// The phantom-progress shape, pinned at the DECISION rather than at the
    /// merge helper: the stay was country-stamped on an earlier pass, its
    /// locality is still nil (so the `locality == nil` fetch predicate keeps
    /// re-selecting it), and the resolver again answers country-without-
    /// locality. The pre-fix rule called this progress on every pass forever
    /// AND never reached the exclusion arm; both halves are pinned here.
    @Test("A country-only re-resolve of an already-stamped settled stay is exhausted, not progress")
    func countryOnlyReresolveIsExhausted() {
        let current = PingRecorder.StayPlaceFields(
            locality: nil,
            country: "Greece",
            isoCountryCode: "GR",
            administrativeArea: "North Aegean"
        )
        let result = outcome(
            current: current,
            country: "Greece",
            iso: "GR",
            admin: "North Aegean",
            settled: true
        )
        #expect(result == .exhausted)
        // Explicitly: it must NOT be a progress outcome, because that return
        // value is the drain loop's only termination oracle.
        if case .progressed = result {
            Issue.record("country-only re-resolve must never count as drain progress")
        }
    }

    @Test("An unsettled no-gain stay retries later but still reports no progress")
    func unsettledNoGainRetriesWithoutProgress() {
        let current = PingRecorder.StayPlaceFields(
            locality: nil, country: "Greece", isoCountryCode: "GR", administrativeArea: nil
        )
        // Recent stay: its running centroid may still drift into a city
        // polygon, so it must stay retryable - but it is not progress.
        let result = outcome(current: current, country: "Greece", iso: "GR", settled: false)
        #expect(result == .retryLater)
    }

    @Test("A genuine first country hit counts as progress")
    func firstCountryHitIsProgress() {
        let current = PingRecorder.StayPlaceFields(
            locality: nil, country: nil, isoCountryCode: nil, administrativeArea: nil
        )
        let result = outcome(current: current, country: "Greece", iso: "GR", settled: true)
        #expect(result == .progressed(PingRecorder.StayPlaceFields(
            locality: nil, country: "Greece", isoCountryCode: "GR", administrativeArea: nil
        )))
    }

    @Test("A later locality hit counts as progress")
    func lateLocalityHitIsProgress() {
        let current = PingRecorder.StayPlaceFields(
            locality: nil, country: "Greece", isoCountryCode: "GR", administrativeArea: nil
        )
        let result = outcome(
            current: current, locality: "Kontakaíika", country: "Greece", iso: "GR", settled: true
        )
        #expect(result == .progressed(PingRecorder.StayPlaceFields(
            locality: "Kontakaíika", country: "Greece", isoCountryCode: "GR", administrativeArea: nil
        )))
    }

    // MARK: - HexVisit dedup survivor must be immutable-keyed

    private func hex(_ h3: String, first: Date, country: String? = nil, iso: String? = nil) -> HexVisit {
        let row = HexVisit(
            h3Index: h3,
            firstVisited: first,
            centerLatitude: 37.98,
            centerLongitude: 23.72
        )
        row.lastVisited = first
        row.country = country
        row.isoCountryCode = iso
        return row
    }

    /// country and isoCountryCode must heal INDEPENDENTLY. Pre-fix they sat
    /// under one `survivor.country == nil` guard, so a survivor that already
    /// had a country name but no ISO discarded the donor's ISO - and the next
    /// line deleted that donor, losing it permanently.
    @Test("HexVisit dedup absorbs a donor's ISO even when the survivor already has a country")
    func hexDedupAbsorbsISOIndependently() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let t = Date(timeIntervalSince1970: 1_600_000_000)
        let a = hex("8a2a1072b5affff", first: t)
        let b = hex("8a2a1072b5affff", first: t)
        let lowID = a.id.uuidString < b.id.uuidString ? a : b
        let highID = a.id.uuidString < b.id.uuidString ? b : a
        // Survivor: country but NO ISO (the legacy/imported shape).
        lowID.country = "Greece"
        lowID.isoCountryCode = nil
        // Donor carries the ISO.
        highID.country = "Greece"
        highID.isoCountryCode = "GR"

        ctx.insert(a)
        ctx.insert(b)
        try ctx.save()

        await HexVisitDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try ModelContext(container).fetch(FetchDescriptor<HexVisit>())
        #expect(rows.count == 1)
        let survivor = try #require(rows.first)
        #expect(survivor.country == "Greece")
        #expect(survivor.isoCountryCode == "GR")
    }

    // MARK: - YearWrapped dedup survivor must be immutable-keyed

    /// Because the survivor is no longer "the newest row", the doomed row can
    /// be the one carrying the FM-healed narrative. It must be absorbed, not
    /// discarded - otherwise the fix would silently downgrade a healed recap.
    @Test("YearWrapped dedup absorbs the FM narrative from the row it deletes")
    func yearWrappedAbsorbsFMNarrative() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let a = YearWrapped(year: 2024)
        let b = YearWrapped(year: 2024)
        let survivor = a.id.uuidString > b.id.uuidString ? a : b
        let doomed = a.id.uuidString > b.id.uuidString ? b : a

        // The doomed row is the NEWER one (an FM heal re-stamps generatedAt),
        // so its content must be absorbed onto the id-chosen survivor.
        survivor.generatedAt = Date(timeIntervalSince1970: 1_600_000_000)
        survivor.yearNarrative = "A plain template recap."
        survivor.yearNarrativeSourceRaw = SummarySource.deterministic.rawValue
        doomed.generatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        doomed.yearNarrative = "A vivid on-device recap."
        doomed.yearNarrativeSourceRaw = SummarySource.foundationModels.rawValue
        doomed.viewedAt = Date(timeIntervalSince1970: 1_650_000_000)

        ctx.insert(a)
        ctx.insert(b)
        try ctx.save()

        await YearWrappedDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try ModelContext(container).fetch(FetchDescriptor<YearWrapped>())
        #expect(rows.count == 1)
        let kept = try #require(rows.first)
        #expect(kept.id == survivor.id)
        #expect(kept.yearNarrative == "A vivid on-device recap.")
        #expect(kept.yearNarrativeSourceRaw == SummarySource.foundationModels.rawValue)
        // The existing earliest-viewedAt absorption must still hold.
        #expect(kept.viewedAt == Date(timeIntervalSince1970: 1_650_000_000))
    }

    @Test("YearWrapped dedup never adopts STALER content from the row it deletes")
    func yearWrappedKeepsItsOwnFMNarrative() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let a = YearWrapped(year: 2023)
        let b = YearWrapped(year: 2023)
        let survivor = a.id.uuidString > b.id.uuidString ? a : b
        let doomed = a.id.uuidString > b.id.uuidString ? b : a

        // Here the id-chosen survivor is ALSO the newer row: its content must
        // be left alone.
        survivor.generatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        survivor.yearNarrative = "A vivid on-device recap."
        survivor.yearNarrativeSourceRaw = SummarySource.foundationModels.rawValue
        doomed.generatedAt = Date(timeIntervalSince1970: 1_600_000_000)
        doomed.yearNarrative = "A plain template recap."
        doomed.yearNarrativeSourceRaw = SummarySource.deterministic.rawValue

        ctx.insert(a)
        ctx.insert(b)
        try ctx.save()

        await YearWrappedDeduplicator.deduplicateAll(modelContainer: container)

        let kept = try #require(try ModelContext(container).fetch(FetchDescriptor<YearWrapped>()).first)
        #expect(kept.yearNarrative == "A vivid on-device recap.")
        #expect(kept.yearNarrativeSourceRaw == SummarySource.foundationModels.rawValue)
    }

    // MARK: - the admin1 "-1" placeholder is not a country code

    @Test("Natural-Earth's '-1' placeholder never becomes an ISO country code")
    func minusOnePlaceholderIsRejected() {
        // The 12 disputed/undetermined admin1 rows (Northern Cyprus, Akrotiri,
        // Dhekelia, Somaliland, Kashmir, Baikonur, Spratly, …) carry this.
        #expect(GeocodeResolver.sanitizedISOCountryCode("-1") == nil)
        // It also has no localized country name, which is how it produced a
        // country-less, flag-less stay.
        #expect(Locale(identifier: "en_US").localizedString(forRegionCode: "-1") == nil)
    }

    @Test("Real ISO codes pass through, normalised")
    func realISOCodesSurvive() {
        #expect(GeocodeResolver.sanitizedISOCountryCode("GR") == "GR")
        #expect(GeocodeResolver.sanitizedISOCountryCode("cy") == "CY")
        #expect(GeocodeResolver.sanitizedISOCountryCode(" us ") == "US")
        #expect(GeocodeResolver.sanitizedISOCountryCode(nil) == nil)
        #expect(GeocodeResolver.sanitizedISOCountryCode("") == nil)
        #expect(GeocodeResolver.sanitizedISOCountryCode("GRC") == nil)
        #expect(GeocodeResolver.sanitizedISOCountryCode("99") == nil)
    }

    // MARK: - weather cache spans must match

    @Test("weatherDaySpan counts inclusive UTC days, never zero")
    func weatherDaySpanIsInclusiveUTCDays() {
        func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
        }
        // A 90-minute stop is one day.
        #expect(WeatherEnricher.weatherDaySpan(
            start: utc(2026, 6, 1, 10), end: utc(2026, 6, 1, 11)) == 1)
        // A stay crossing one UTC midnight covers two days.
        #expect(WeatherEnricher.weatherDaySpan(
            start: utc(2026, 6, 1, 23), end: utc(2026, 6, 2, 1)) == 2)
        // A 20-day home stay - the one whose 20-day rain TOTAL used to be
        // copied onto a same-cell, same-start-day 90-minute stop.
        #expect(WeatherEnricher.weatherDaySpan(
            start: utc(2026, 6, 1, 0), end: utc(2026, 6, 20, 12)) == 20)
        // Degenerate/reversed input never yields 0 or a negative span.
        #expect(WeatherEnricher.weatherDaySpan(
            start: utc(2026, 6, 5, 12), end: utc(2026, 6, 1, 12)) == 1)
        #expect(WeatherEnricher.weatherDaySpan(
            start: utc(2026, 6, 5, 12), end: utc(2026, 6, 5, 12)) == 1)
    }

    // MARK: - stayShapeToken must tolerate a deleted stay

    /// `stayShapeToken` walks `trip.stays` and reads each stay's properties.
    /// A stay can be deleted independently of its trip during trip detach
    /// or photo-import discard. Reading an invalidated @Model traps.
    /// This path is reachable without PhotoKit access.
    @Test("stayShapeToken skips a deleted stay instead of trapping")
    func stayShapeTokenSkipsDeletedStay() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let base = Date(timeIntervalSince1970: 1_714_515_200)
        let trip = Trip(startDate: base)
        ctx.insert(trip)

        func makeStay(offsetHours: Double) -> Stay {
            let start = base.addingTimeInterval(offsetHours * 3600)
            let stay = Stay(
                startTime: start,
                endTime: start.addingTimeInterval(3600),
                centroidLatitude: 37.98, centroidLongitude: 23.72,
                h3IndexRes6: "8a2a1072b59ffff", pingCount: 1,
                distanceFromHomeKm: 0, pingIDs: []
            )
            stay.category = .destination
            ctx.insert(stay)
            stay.trip = trip
            return stay
        }
        let keep = makeStay(offsetHours: 0)
        let doomed = makeStay(offsetHours: 5)
        try ctx.save()

        // Token with both stays present.
        let before = PhotoService.stayShapeToken(for: trip)

        ctx.delete(doomed)
        try ctx.save()

        // Must not trap, and must reflect the surviving shape.
        let after = PhotoService.stayShapeToken(for: trip)
        #expect(after != before)
        _ = keep
    }

    // MARK: - same-named towns in one country must not merge

    private func placeStay(
        locality: String,
        admin: String?,
        iso: String,
        startDay: Double,
        trip: Trip,
        in ctx: ModelContext
    ) -> Stay {
        let start = Date(timeIntervalSince1970: 1_714_515_200 + startDay * 86_400)
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(6 * 3600),
            centroidLatitude: 35.19, centroidLongitude: 25.71,
            h3IndexRes6: "8a2a1072b59ffff", pingCount: 2,
            distanceFromHomeKm: 300, pingIDs: []
        )
        stay.category = .destination
        stay.locality = locality
        stay.administrativeArea = admin
        stay.isoCountryCode = iso
        stay.country = "Greece"
        ctx.insert(stay)
        stay.trip = trip
        return stay
    }

    /// Two different towns that share a name in one country must stay separate.
    @Test("same-named towns in different admin areas do not merge into one place")
    func homonymTownsDoNotMerge() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let tripA = Trip(startDate: Date(timeIntervalSince1970: 1_714_515_200))
        let tripB = Trip(startDate: Date(timeIntervalSince1970: 1_715_015_200))
        ctx.insert(tripA)
        ctx.insert(tripB)
        // Agios Nikolaos, Crete vs Agios Nikolaos, Epirus.
        _ = placeStay(locality: "Agios Nikolaos", admin: "Crete", iso: "GR", startDay: 0, trip: tripA, in: ctx)
        _ = placeStay(locality: "Agios Nikolaos", admin: "Epirus", iso: "GR", startDay: 10, trip: tripB, in: ctx)
        try ctx.save()

        let stays = try ctx.fetch(FetchDescriptor<Stay>())
        let places = CollectionsAggregator.placeEntriesForTesting(byStart: stays.sorted { $0.startTime < $1.startTime })
        let agios = places.filter { $0.name == "Agios Nikolaos" }
        #expect(agios.count == 2)
        #expect(agios.allSatisfy { $0.stayCount == 1 })
    }

    /// The counterpart guard: ONE real place whose admin area is consistent
    /// must still collapse to a single row - qualifying every key would have
    /// split real places apart.
    @Test("a single town visited twice stays one place")
    func consistentPlaceStaysMerged() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let tripA = Trip(startDate: Date(timeIntervalSince1970: 1_714_515_200))
        let tripB = Trip(startDate: Date(timeIntervalSince1970: 1_715_015_200))
        ctx.insert(tripA)
        ctx.insert(tripB)
        // Same town twice; the second visit resolved no admin area at all.
        _ = placeStay(locality: "Kontakaíika", admin: "North Aegean", iso: "GR", startDay: 0, trip: tripA, in: ctx)
        _ = placeStay(locality: "Kontakaíika", admin: nil, iso: "GR", startDay: 10, trip: tripB, in: ctx)
        try ctx.save()

        let stays = try ctx.fetch(FetchDescriptor<Stay>())
        let places = CollectionsAggregator.placeEntriesForTesting(byStart: stays.sorted { $0.startTime < $1.startTime })
        let kontakaiika = places.filter { $0.name == "Kontakaíika" }
        #expect(kontakaiika.count == 1)
        #expect(kontakaiika.first?.stayCount == 2)
    }

    @Test("An island-only hit that would wipe country is not progress")
    func islandOnlyHitDoesNotWipeOrProgress() {
        let current = PingRecorder.StayPlaceFields(
            locality: "Kontakaíika",
            country: "Greece",
            isoCountryCode: "GR",
            administrativeArea: "North Aegean"
        )
        // Resolver answers with nothing storable: coalesce must keep every
        // field, and "no gain" must not masquerade as progress.
        let result = outcome(current: current, settled: true)
        #expect(result == .exhausted)
    }

    @Test("Coalesce never wipes a non-nil field with nil")
    func coalesceNeverWipes() {
        let stay = PingRecorder.StayPlaceFields(
            locality: "Kontakaíika",
            country: "Greece",
            isoCountryCode: "GR",
            administrativeArea: "North Aegean"
        )
        // An island-only resolver hit carries nil country/ISO.
        let after = stay.coalescing(
            locality: nil, country: nil, isoCountryCode: nil, administrativeArea: nil
        )
        #expect(after == stay)
        #expect(after.country == "Greece")
        #expect(after.isoCountryCode == "GR")
        #expect(after.administrativeArea == "North Aegean")
    }
}
