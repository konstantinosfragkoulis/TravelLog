//
//  TemporaryHomeAwayParityTests.swift
//  TravelLogTests
//
//  One seeded semester (`SemesterFixture`, in TemporaryHomeLedgerTests.swift)
//  read through every surface that reports days away: the Stats aggregates
//  behind Passport, the Siri lifetime and year summaries, the ledger itself
//  and a new Wrapped recap. They must agree, "Days Traveling" must stay
//  trip-only, and the base country must read as a temporary home, never as
//  home. A failed read behind any of them is never answered with trip days.
//

import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Days away with a temporary home")
struct TemporaryHomeAwayParityTests {

    private typealias Fixture = SemesterFixture
    private var utcCalendar: Calendar { TravelDays.labelCalendar }

    private func seededContainer() throws -> ModelContainer {
        let container = try TestSupport.makeInMemoryContainer()
        try Fixture.seed(container)
        return container
    }

    private func wrappedStats(_ container: ModelContainer, year: Int) throws -> WrappedStats {
        let row = try #require(ModelContext(container).fetch(FetchDescriptor<YearWrapped>())
            .first { $0.year == year })
        let blob = try #require(row.statsData)
        return try #require(WrappedStats.decoded(from: blob))
    }

    // MARK: - Passport, Stats and Siri

    @Test("Passport, Siri lifetime and the ledger report the same days away, and Days Traveling stays trip-only")
    func passportSiriAndLedgerAgree() throws {
        let container = try seededContainer()
        let stats = try StatsAggregator.compute(
            container: container, now: Fixture.now, calendar: utcCalendar)
        let siri = try StatsAggregator.passportSummary(
            container: container, now: Fixture.now, calendar: utcCalendar)
        let travelling = try TravelDays.labels(
            container: container, now: Fixture.now, fallbackZone: Fixture.utc)
        let ledger = try TemporaryHomeLedger.result(
            travelling: travelling, container: container, now: Fixture.now,
            fallbackZone: Fixture.utc, checkCancellation: {})

        #expect(ledger.away == Fixture.away)
        #expect(stats.passportData.daysAbroad == 106)
        #expect(siri.daysAbroad == 106)
        #expect(stats.awayDaysTotal == 106)
        #expect(stats.awayDaysThisYear == 106)
        #expect(stats.stayingDaysTotal == 99)
        #expect(stats.passportData.daysAtTemporaryHomes == 99)

        // Days Traveling, the year bar and the favourite month count trips only.
        #expect(stats.travelDaysTotal == 7)
        #expect(stats.travelDaysThisYear == 7)
        #expect(stats.yearStats == [.init(year: 2025, trips: 2, days: 7, countries: 2)])
        #expect(stats.favoriteMonth == 1)
        #expect(stats.favoriteMonthDays == 4)
        #expect(stats.computeDegraded == nil)
    }

    @Test("the projected Stats compute and the full-fetch lane agree on every temporary-home figure")
    func projectedAndFullComputeAgree() throws {
        let container = try seededContainer()
        let projected = try StatsAggregator.compute(
            container: container, now: Fixture.now, usingProjection: true, calendar: utcCalendar)
        let full = try StatsAggregator.compute(
            container: container, now: Fixture.now, usingProjection: false, calendar: utcCalendar)

        #expect(full.awayDaysTotal == 106)
        #expect(projected.awayDaysTotal == full.awayDaysTotal)
        #expect(projected.awayDaysThisYear == full.awayDaysThisYear)
        #expect(projected.stayingDaysTotal == full.stayingDaysTotal)
        #expect(projected.passportData == full.passportData)
        #expect(projected.countryStats == full.countryStats)
    }

    @Test("Siri's year summary buckets days away by the year of each date")
    func siriYearSummaryUsesAwayDays() throws {
        let container = try seededContainer()
        let year = try StatsAggregator.yearSummary(
            container: container, year: 2025, calendar: utcCalendar, now: Fixture.now)
        #expect(year.daysAbroad == 106)
        #expect(year.trips == 2)
        let before = try StatsAggregator.yearSummary(
            container: container, year: 2024, calendar: utcCalendar, now: Fixture.now)
        #expect(before.daysAbroad == 0)
    }

    @Test("a stay whose category this build does not know still joins the run at the temporary home, and Passport, Siri lifetime and Siri year report the same days",
          arguments: ["", "a-category-from-a-newer-build"])
    func unrecognisedCategoryCountsOnEverySurface(categoryRaw: String) throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let base = TemporaryHome(
            label: "", latitude: Fixture.brussels.lat, longitude: Fixture.brussels.lon,
            startedAt: Fixture.at(2025, 4, 7, 0), endedAt: Fixture.at(2025, 5, 6, 23))
        context.insert(base)
        Fixture.stay(context, .home, at: Fixture.brussels, iso: "BE",
                     from: Fixture.at(2025, 4, 8, 10), to: Fixture.at(2025, 4, 11, 18), by: base.id)
        let unknown = Fixture.stay(context, .unclassified, at: Fixture.ieper, iso: "BE",
                                   from: Fixture.at(2025, 4, 16, 9), to: Fixture.at(2025, 4, 26, 17))
        unknown.categoryRaw = categoryRaw
        try context.save()

        // The run spans 8 to 26 April: 19 dates. No trip, and the
        // temporary home ended before `now`.
        let now = Fixture.at(2025, 5, 7)
        let stats = try StatsAggregator.compute(container: container, now: now, calendar: utcCalendar)
        let siri = try StatsAggregator.passportSummary(container: container, now: now, calendar: utcCalendar)
        let year = try StatsAggregator.yearSummary(
            container: container, year: 2025, calendar: utcCalendar, now: now)
        #expect(stats.passportData.daysAbroad == 19)
        #expect(stats.passportData.daysAtTemporaryHomes == 19)
        #expect(siri.daysAbroad == 19)
        #expect(year.daysAbroad == 19)
        #expect(stats.travelDaysTotal == 0)
        #expect(stats.computeDegraded == nil)
    }

    @Test("with the base still active, Passport and Siri count through today together")
    func activeTemporaryHomeCountsThroughNow() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let base = TemporaryHome(
            label: "", latitude: Fixture.brussels.lat, longitude: Fixture.brussels.lon,
            startedAt: Fixture.at(2025, 4, 7, 0))
        context.insert(base)
        Fixture.stay(context, .home, at: Fixture.brussels, iso: "BE",
                     from: Fixture.at(2025, 4, 8, 10), to: Fixture.at(2025, 4, 11, 18), by: base.id)
        try context.save()

        // No trip at all: the projected trip read returns nothing and the
        // days still count.
        let now = Fixture.at(2025, 5, 1)
        let stats = try StatsAggregator.compute(container: container, now: now, calendar: utcCalendar)
        let siri = try StatsAggregator.passportSummary(container: container, now: now, calendar: utcCalendar)
        #expect(stats.passportData.daysAbroad == 24)
        #expect(siri.daysAbroad == 24)
        #expect(stats.travelDaysTotal == 0)
    }

    // MARK: - Country rows

    @Test("the base country is not a home country, is flagged as a temporary home, and the explored-home pin stays on the real home")
    func baseCountryIsATemporaryHomeCountry() throws {
        let container = try seededContainer()
        let stats = try StatsAggregator.compute(
            container: container, now: Fixture.now, calendar: utcCalendar)

        let belgium = try #require(stats.countryStats.first { $0.code == "BE" })
        #expect(belgium.isHome == false)
        #expect(belgium.isTemporaryHome == true)
        #expect(belgium.tripCount == 1)
        let greece = try #require(stats.countryStats.first { $0.code == "GR" })
        #expect(greece.isHome == true)
        #expect(greece.isTemporaryHome == nil)
        let italy = try #require(stats.countryStats.first { $0.code == "IT" })
        #expect(italy.isHome == false)
        #expect(italy.isTemporaryHome == nil)
        #expect(stats.homeHexCountries?.map(\.code) == ["GR"])
    }

    /// `owner` is the temporary home that recorded the stay, as the
    /// classifier stamps a home stay inside its dates and outside a real
    /// Home's area.
    private func homeStay(
        at place: (lat: Double, lon: Double), iso: String, day: Int, by owner: HomeAnchor? = nil
    ) -> Stay {
        let stay = Stay(
            startTime: Fixture.at(2025, 4, 7, 10).addingTimeInterval(Double(day - 1) * 86_400), endTime: Fixture.at(2025, 4, 7, 20).addingTimeInterval(Double(day - 1) * 86_400),
            centroidLatitude: place.lat, centroidLongitude: place.lon,
            h3IndexRes6: "", pingCount: 4, distanceFromHomeKm: 0, pingIDs: [],
            timeZoneIdentifier: "UTC")
        stay.category = .home
        stay.temporaryHomeID = owner?.id
        stay.isoCountryCode = iso
        return stay
    }

    private func anchor(
        _ kind: HomeAnchor.Kind, at place: (lat: Double, lon: Double), iso: String?, from start: Date
    ) -> HomeAnchor {
        HomeAnchor(
            id: UUID(), kind: kind, label: "", latitude: place.lat, longitude: place.lon,
            radiusKm: 25, locality: nil, isoCountryCode: iso, startedAt: start, endedAt: nil)
    }

    private func countryStats(_ stays: [Stay], anchors: [HomeAnchor]) -> [String: CountryStat] {
        let result = StatsAggregator.aggregate(
            visitedStays: stays, transitStays: [], trips: [], hexVisits: [],
            totalPings: 0, totalStays: stays.count, flightCount: 0, trackingSince: nil,
            anchors: anchors, now: Fixture.at(2025, 5, 6), calendar: utcCalendar)
        return Dictionary(uniqueKeysWithValues: result.countryStats.map { ($0.code, $0) })
    }

    @Test("home stays at a temporary home do not make its country home, even when no active home supplies a home country")
    func homeStaysAtTheBaseDoNotFlagHome() {
        let home = anchor(.home, at: Fixture.athens, iso: nil, from: Fixture.at(2020, 1, 1))
        // No stamped country: it comes from the home stays the base owns.
        let base = anchor(.temporary, at: Fixture.brussels, iso: nil, from: Fixture.at(2025, 4, 11))
        let stays = [
            homeStay(at: Fixture.athens, iso: "GR", day: 2),
            homeStay(at: Fixture.brussels, iso: "BE", day: 10, by: base),
        ]

        let rows = countryStats(stays, anchors: [home, base])
        #expect(rows["BE"]?.isHome == false)
        #expect(rows["BE"]?.isTemporaryHome == true)
        #expect(rows["GR"]?.isHome == true)
        #expect(rows["GR"]?.isTemporaryHome == nil)

        // The same rows with no temporary home, so nothing recorded:
        // Belgium reads as home, as before.
        let before = countryStats([
            homeStay(at: Fixture.athens, iso: "GR", day: 2),
            homeStay(at: Fixture.brussels, iso: "BE", day: 10),
        ], anchors: [])
        #expect(before["BE"]?.isHome == true)
        #expect(before["BE"]?.isTemporaryHome == nil)
    }

    /// A stay at the base is the real Home's when nothing recorded it
    /// and nobody's when its recorded owner has no row here.
    @Test("country rows read a home stay's record, never the nearest centre: unrecorded is the real Home's, an unsynced owner's is nobody's",
          arguments: [false, true])
    func countryRowsReadTheRecordedOwner(unsynced: Bool) {
        let home = anchor(.home, at: Fixture.athens, iso: nil, from: Fixture.at(2020, 1, 1))
        let base = anchor(.temporary, at: Fixture.brussels, iso: nil, from: Fixture.at(2025, 4, 11))
        let atBase = homeStay(at: Fixture.brussels, iso: "BE", day: 10)
        if unsynced { atBase.temporaryHomeID = UUID() }

        let rows = countryStats([homeStay(at: Fixture.athens, iso: "GR", day: 2), atBase],
                                anchors: [home, base])
        #expect(rows["BE"]?.isHome == !unsynced)
        #expect(rows["BE"]?.isTemporaryHome == nil)
        #expect(rows["GR"]?.isHome == true)
    }

    @Test("a temporary home in the real home's country leaves that country a home country")
    func temporaryHomeInTheHomeCountryStaysHome() {
        let ioannina = (lat: 39.6628, lon: 20.8612)
        let base = anchor(.temporary, at: ioannina, iso: "GR", from: Fixture.at(2025, 4, 11))
        let stays = [
            homeStay(at: Fixture.athens, iso: "GR", day: 2),
            homeStay(at: ioannina, iso: "GR", day: 10, by: base),
        ]
        let rows = countryStats(stays, anchors: [
            anchor(.home, at: Fixture.athens, iso: "GR", from: Fixture.at(2020, 1, 1)),
            base,
        ])
        #expect(rows["GR"]?.isHome == true)
        #expect(rows["GR"]?.isTemporaryHome == nil)
    }

    /// `record`: "none" declares no temporary home. "classifier" declares
    /// one in Bedburg and leaves the German stays as the classifier records
    /// them: inside the real Home's ring, so the real Home's (nil).
    /// "correction" stamps them for the temporary home, as a "This Was Home"
    /// correction does for the nearest covering centre.
    @Test("home stays a temporary home recorded never decide the country of a real Home that has none stamped; stays the real Home recorded, or with no temporary home, decide it as before",
          arguments: ["none", "classifier", "correction"])
    func temporaryHomeStaysDoNotResolveTheRealHomeCountry(record: String) throws {
        // Roermond and Bedburg are about 47 km apart, so Bedburg lies inside
        // the Roermond Home's 50 km fallback ring.
        let roermond = (lat: 51.1972, lon: 5.9896)
        let bedburg = (lat: 50.9912, lon: 6.5718)
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Home(label: "Home", latitude: roermond.lat, longitude: roermond.lon,
                            radiusKm: 50, startedAt: Fixture.at(2020, 1, 1)))
        var base: TemporaryHome?
        if record != "none" {
            let row = TemporaryHome(
                label: "", latitude: bedburg.lat, longitude: bedburg.lon,
                startedAt: Fixture.at(2025, 4, 7, 0))
            row.isoCountryCode = "DE"
            context.insert(row)
            base = row
        }
        // Only stays a temporary home recorded are its own.
        let withTemporaryHome = record == "correction"
        for day in [3, 6, 9] {
            Fixture.stay(context, .home, at: bedburg, iso: "DE",
                         from: Fixture.at(2025, 4, 7, 10).addingTimeInterval(Double(day - 1) * 86_400), to: Fixture.at(2025, 4, 7, 20).addingTimeInterval(Double(day - 1) * 86_400),
                         by: withTemporaryHome ? base?.id : nil)
        }
        for day in [12, 15] {
            Fixture.stay(context, .home, at: roermond, iso: "NL",
                         from: Fixture.at(2025, 4, 7, 10).addingTimeInterval(Double(day - 1) * 86_400), to: Fixture.at(2025, 4, 7, 20).addingTimeInterval(Double(day - 1) * 86_400))
        }
        try context.save()

        let stats = try StatsAggregator.compute(
            container: container, now: Fixture.at(2025, 5, 6), calendar: utcCalendar)
        let germany = try #require(stats.countryStats.first { $0.code == "DE" })
        let netherlands = try #require(stats.countryStats.first { $0.code == "NL" })
        if withTemporaryHome {
            // Only the two Dutch stays at the real Home count: the three German ones belong to the temporary home.
            #expect(stats.homeHexCountries?.map(\.code) == ["NL"])
            #expect(netherlands.isHome == true)
            #expect(germany.isHome == false)
            #expect(germany.isTemporaryHome == true)
        } else {
            // Three German home stays inside the ring outvote two Dutch ones.
            #expect(stats.homeHexCountries?.map(\.code) == ["DE"])
            #expect(germany.isHome == true)
            #expect(netherlands.isHome == false)
            #expect(germany.isTemporaryHome == nil)
        }
        #expect(stats.computeDegraded == nil)
    }

    // MARK: - Snapshot shape

    @Test("aggregates with no temporary home encode none of the new fields, and that older shape still decodes")
    func aggregatesWithoutTemporaryHomeKeepTheirShape() throws {
        var aggregates = StatsAggregator.Aggregates()
        aggregates.travelDaysTotal = 12
        aggregates.passportData.daysAbroad = 12
        aggregates.countryStats = [CountryStat(code: "GR", name: "Greece", tripCount: 0, isHome: true)]

        let data = try JSONEncoder().encode(aggregates)
        let text = String(decoding: data, as: UTF8.self)
        for key in ["awayDaysTotal", "awayDaysThisYear", "stayingDaysTotal",
                    "daysAtTemporaryHomes", "isTemporaryHome"] {
            #expect(!text.contains(key), "\(key) was written without a temporary home")
        }
        let decoded = try JSONDecoder().decode(StatsAggregator.Aggregates.self, from: data)
        #expect(decoded.awayDaysTotal == nil)
        #expect(decoded.awayDaysThisYear == nil)
        #expect(decoded.stayingDaysTotal == nil)
        #expect(decoded.passportData.daysAbroad == 12)
        #expect(decoded.passportData.daysAtTemporaryHomes == nil)
        #expect(decoded.countryStats.first?.isTemporaryHome == nil)
    }

    @Test("a temporary home with no stay at it leaves an empty passport empty")
    func declarationAloneKeepsThePassportEmpty() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(TemporaryHome(
            label: "", latitude: Fixture.brussels.lat, longitude: Fixture.brussels.lon,
            startedAt: Fixture.at(2025, 4, 7, 0)))
        try context.save()

        let stats = try StatsAggregator.compute(
            container: container, now: Fixture.at(2025, 7, 7), calendar: utcCalendar)
        #expect(stats.awayDaysTotal == 0)
        #expect(stats.stayingDaysTotal == 0)
        #expect(stats.passportData == PassportData())
        #expect(!stats.passportData.isShareable(aggregatesComplete: true))
    }

    // MARK: - Wrapped

    @Test("a new recap takes days away from the ledger, keeps away plus home equal to the year, records the staying days and lets the base country be a new stamp")
    func newRecapUsesTheAwayLedger() async throws {
        let container = try seededContainer()
        let generator = YearWrappedGenerator(modelContainer: container)
        #expect(await generator.forceRegenerate(forYear: 2025))
        let stats = try wrappedStats(container, year: 2025)

        #expect(stats.daysAbroad == 106)
        #expect(stats.totalDaysAbroad == 106)
        #expect(stats.daysStaying == 99)
        #expect(stats.daysAtHome == 259)
        #expect(stats.daysAbroad + stats.daysAtHome == TravelDays.daysInYear(2025))
        // Belgium holds home stays, all of them at the temporary home.
        #expect(stats.newCountryCodes == ["BE", "IT"])
    }

    @Test("a new recap counts the country and city of a temporary home lived at with no trip there, but not a real-Home stay or one whose temporary home the store does not hold")
    func recapCountsTheTemporaryHomeGeography() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let home = Home(label: "Home", latitude: Fixture.athens.lat, longitude: Fixture.athens.lon,
                        radiusKm: 25, startedAt: Fixture.at(2020, 1, 1))
        home.isoCountryCode = "GR"
        context.insert(home)
        let base = TemporaryHome(
            label: "", latitude: Fixture.brussels.lat, longitude: Fixture.brussels.lon,
            startedAt: Fixture.at(2025, 4, 7, 0), endedAt: Fixture.at(2025, 5, 6, 23))
        base.isoCountryCode = "BE"
        context.insert(base)
        let romeTrip = Fixture.trip(context, from: Fixture.at(2025, 1, 5, 9),
                                    to: Fixture.at(2025, 1, 7, 17), codes: "IT")
        Fixture.stay(context, .destination, at: Fixture.rome, iso: "IT",
                     from: Fixture.at(2025, 1, 5, 9), to: Fixture.at(2025, 1, 7, 17), trip: romeTrip)
        Fixture.stay(context, .home, at: Fixture.athens, iso: "GR",
                     from: Fixture.at(2025, 1, 1, 9), to: Fixture.at(2025, 1, 2, 9))
        Fixture.stay(context, .home, at: Fixture.brussels, iso: "BE",
                     from: Fixture.at(2025, 4, 8, 10), to: Fixture.at(2025, 4, 11, 18), by: base.id)
        // An owner this store does not hold (not synced yet) is nobody's.
        Fixture.stay(context, .home, at: (lat: 35.34, lon: 25.13), iso: "NL",
                     from: Fixture.at(2025, 4, 16, 9), to: Fixture.at(2025, 4, 26, 17), by: UUID())
        try context.save()

        let generator = YearWrappedGenerator(modelContainer: container)
        #expect(await generator.forceRegenerate(forYear: 2025))
        let stats = try wrappedStats(container, year: 2025)

        #expect(stats.newCountryCodes == ["BE", "IT"])
        #expect(stats.countriesVisited == 2)
        #expect(stats.citiesVisited == 2)
        #expect(stats.tripsCompleted == 1)
    }

    @Test("a home stay at the base that the real Home recorded keeps its country out of the new stamps, whatever the nearest centre")
    func recapReadsTheRecordedOwner() async throws {
        let container = try seededContainer()
        let context = ModelContext(container)
        Fixture.stay(context, .home, at: Fixture.brussels, iso: "BE",
                     from: Fixture.at(2025, 7, 21, 10), to: Fixture.at(2025, 7, 21, 20))
        try context.save()

        let generator = YearWrappedGenerator(modelContainer: container)
        #expect(await generator.forceRegenerate(forYear: 2025))
        #expect(try wrappedStats(container, year: 2025).newCountryCodes == ["IT"])
    }

    @Test("a recap generated with no temporary home stores no staying days and still keeps the home country out of the new stamps")
    func recapWithoutTemporaryHomeIsUnchanged() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Fixture.trip(context, from: Fixture.at(2025, 1, 5, 9),
                                to: Fixture.at(2025, 1, 7, 17), codes: "GR")
        Fixture.stay(context, .destination, at: (lat: 35.34, lon: 25.13), iso: "GR",
                     from: Fixture.at(2025, 1, 5, 9), to: Fixture.at(2025, 1, 7, 17), trip: trip)
        Fixture.stay(context, .home, at: Fixture.athens, iso: "GR",
                     from: Fixture.at(2025, 1, 1, 9), to: Fixture.at(2025, 1, 2, 9))
        try context.save()

        let generator = YearWrappedGenerator(modelContainer: container)
        #expect(await generator.forceRegenerate(forYear: 2025))
        let row = try #require(ModelContext(container).fetch(FetchDescriptor<YearWrapped>()).first)
        let blob = try #require(row.statsData)
        #expect(!String(decoding: blob, as: UTF8.self).contains("daysStaying"))
        let stats = try #require(WrappedStats.decoded(from: blob))
        #expect(stats.daysStaying == nil)
        #expect(stats.daysAbroad == 3)
        #expect(stats.daysAbroad + stats.daysAtHome == TravelDays.daysInYear(2025))
        #expect(stats.newCountryCodes.isEmpty)
    }

    // MARK: - Failed reads

    #if DEBUG
    private func recordedComputeReads(_ container: ModelContainer) throws -> [StatsAggregator.Read] {
        let log = OSAllocatedUnfairLock(initialState: [StatsAggregator.Read]())
        let recording: @Sendable (StatsAggregator.Read) throws -> Void = { read in
            log.withLock { $0.append(read) }
        }
        _ = try StatsAggregator.$readFailureForTesting.withValue(recording) {
            try StatsAggregator.compute(container: container, now: Fixture.now, calendar: utcCalendar)
        }
        return log.withLock { $0 }
    }

    @Test("with no temporary home the Stats compute adds one read of the temporary-home rows and nothing else")
    func noTemporaryHomeAddsOneRead() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        Fixture.stay(context, .home, at: Fixture.athens, iso: "GR",
                     from: Fixture.at(2025, 4, 8, 10), to: Fixture.at(2025, 4, 15, 18))
        try context.save()

        // Every compute read exactly once, the new one among them.
        let reads = try recordedComputeReads(container).map(\.rawValue).sorted()
        let expected = StatsAggregator.Read.computeReads.map(\.rawValue).sorted()
        #expect(reads == expected)
        #expect(reads.contains(StatsAggregator.Read.temporaryHomes.rawValue))
        #expect(!reads.contains(StatsAggregator.Read.awayLedger.rawValue))
    }

    @Test("with a temporary home the Stats compute also reads every Home and the days-away ledger, once each")
    func temporaryHomeAddsItsReads() throws {
        let reads = try recordedComputeReads(try seededContainer())
        #expect(reads.filter { $0 == .temporaryHomes }.count == 1)
        #expect(reads.filter { $0 == .homes }.count == 2)
        #expect(reads.filter { $0 == .awayLedger }.count == 1)
    }

    @Test("with a temporary home, a failed read behind its days degrades the Stats compute",
          arguments: [StatsAggregator.Read.temporaryHomes, .homes, .awayLedger])
    func failedTemporaryHomeReadDegradesCompute(read failing: StatsAggregator.Read) throws {
        let container = try seededContainer()
        let hook: @Sendable (StatsAggregator.Read) throws -> Void = { read in
            if read == failing { throw CocoaError(.fileReadUnknown) }
        }
        let result = try StatsAggregator.$readFailureForTesting.withValue(hook) {
            try StatsAggregator.compute(container: container, now: Fixture.now, calendar: utcCalendar)
        }
        #expect(result.computeDegraded == true)
    }

    @Test("a failed read inside the days-away ledger degrades the Stats compute instead of showing trip days alone",
          arguments: TemporaryHomeLedger.Read.allCases)
    func failedLedgerReadDegradesCompute(read failing: TemporaryHomeLedger.Read) throws {
        let container = try seededContainer()
        let hook: @Sendable (TemporaryHomeLedger.Read) throws -> Void = { read in
            if read == failing { throw CocoaError(.fileReadUnknown) }
        }
        let result = try TemporaryHomeLedger.$readFailureForTesting.withValue(hook) {
            try StatsAggregator.compute(container: container, now: Fixture.now, calendar: utcCalendar)
        }
        #expect(result.computeDegraded == true)
        // The same store, read cleanly, is healthy.
        let healthy = try StatsAggregator.compute(
            container: container, now: Fixture.now, calendar: utcCalendar)
        #expect(healthy.computeDegraded == nil)
        #expect(healthy.passportData.daysAbroad == 106)
    }

    @Test("a failed ledger read makes both Siri summaries throw instead of answering with trip days",
          arguments: TemporaryHomeLedger.Read.allCases)
    func failedLedgerReadFailsSiri(read failing: TemporaryHomeLedger.Read) throws {
        let container = try seededContainer()
        let hook: @Sendable (TemporaryHomeLedger.Read) throws -> Void = { read in
            if read == failing { throw CocoaError(.fileReadUnknown) }
        }
        #expect(throws: CocoaError.self) {
            try TemporaryHomeLedger.$readFailureForTesting.withValue(hook) {
                try StatsAggregator.passportSummary(container: container, now: Fixture.now)
            }
        }
        #expect(throws: CocoaError.self) {
            try TemporaryHomeLedger.$readFailureForTesting.withValue(hook) {
                try StatsAggregator.yearSummary(container: container, year: 2025, now: Fixture.now)
            }
        }
    }

    @Test("a failed ledger read fails the recap with nothing committed, and a clean retry commits",
          arguments: TemporaryHomeLedger.Read.allCases)
    func failedLedgerReadFailsTheRecap(read failing: TemporaryHomeLedger.Read) async throws {
        let container = try seededContainer()
        let generator = YearWrappedGenerator(modelContainer: container)
        let hook: @Sendable (TemporaryHomeLedger.Read) throws -> Void = { read in
            if read == failing { throw CocoaError(.fileReadUnknown) }
        }
        let produced = await TemporaryHomeLedger.$readFailureForTesting.withValue(hook) {
            await generator.forceRegenerate(forYear: 2025)
        }
        #expect(!produced)
        #expect(try ModelContext(container).fetch(FetchDescriptor<YearWrapped>()).isEmpty)

        #expect(await generator.forceRegenerate(forYear: 2025))
        #expect(try wrappedStats(container, year: 2025).daysAbroad == 106)
    }
    #endif
}
