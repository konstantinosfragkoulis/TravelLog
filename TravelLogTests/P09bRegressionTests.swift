//
//  P09bRegressionTests.swift
//  TravelLogTests
//
//  Regression tests for the Stats, On This Day and Wrapped fixes of
//  package P09b. Invented private-use ISO codes (QA to QZ) and round
//  fictional coordinates throughout.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

// MARK: - TIME-001: On This Day across calendar eras

@Suite("On This Day keys years chronologically, eras included")
struct OnThisDayEraTests {

    private static let utcGregorian: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let japanese: Calendar = {
        var calendar = Calendar(identifier: .japanese)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        Self.utcGregorian.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func stay(_ start: Date, _ end: Date, trip: UUID = UUID()) -> OnThisDayStay {
        OnThisDayStay(stayID: UUID(), tripID: trip, place: "Qarth", startTime: start, endTime: end,
                      weatherConditionRaw: nil, avgTemperatureC: nil)
    }

    @Test("memories from earlier eras survive, newest first, counting elapsed years")
    func earlierErasSurvive() {
        let stays = [
            stay(date(1988, 6, 10), date(1988, 6, 11)),  // Showa 63
            stay(date(2018, 6, 10), date(2018, 6, 11)),  // Heisei 30
            stay(date(2023, 6, 10), date(2023, 6, 11)),  // Reiwa 5
        ]
        let groups = OnThisDayEngine.yearGroups(on: date(2026, 6, 10), stays: stays, calendar: Self.japanese)
        #expect(groups.map(\.year) == [5, 30, 63])
        #expect(groups.map(\.yearsAgo) == [3, 8, 38])
        #expect(groups.map { $0.namesEra == true } == [false, true, true])
        #expect(Set(groups.map(\.id)).count == 3)
    }

    @Test("the same year number in two eras stays two memories")
    func repeatedYearNumbersStayApart() {
        let stays = [
            stay(date(1955, 6, 10), date(1955, 6, 11)),  // Showa 30
            stay(date(2018, 6, 10), date(2018, 6, 11)),  // Heisei 30
        ]
        let groups = OnThisDayEngine.yearGroups(on: date(2026, 6, 10), stays: stays, calendar: Self.japanese)
        #expect(groups.map(\.year) == [30, 30])
        #expect(groups.map(\.yearsAgo) == [8, 71])
        #expect(Set(groups.map(\.id)).count == 2)
        #expect(groups.map { $0.trips.count } == [1, 1])
    }

    @Test("a stay across an era change matches on both sides of it")
    func eraSpanningStayMatchesBothSides() {
        let spanning = stay(date(2019, 4, 29), date(2019, 5, 3))
        let lastHeisei = OnThisDayEngine.yearGroups(on: date(2026, 4, 30), stays: [spanning], calendar: Self.japanese)
        #expect(lastHeisei.map(\.year) == [31])
        #expect(lastHeisei.map(\.yearsAgo) == [7])
        #expect(lastHeisei.first?.namesEra == true)
        #expect(lastHeisei.first?.day == date(2019, 4, 30, 0))

        let firstReiwa = OnThisDayEngine.yearGroups(on: date(2026, 5, 1), stays: [spanning], calendar: Self.japanese)
        #expect(firstReiwa.map(\.year) == [1])
        #expect(firstReiwa.map(\.yearsAgo) == [7])
        #expect(firstReiwa.first?.namesEra == nil)
        #expect(firstReiwa.first?.day == date(2019, 5, 1, 0))
    }

    @Test("a date an era-year does not contain matches nothing in it")
    func dayOutsideEraYearIsSkipped() {
        // Heisei 31 ended on 30 April; 20 October 2019 is Reiwa 1.
        let groups = OnThisDayEngine.yearGroups(
            on: date(2026, 10, 20), stays: [stay(date(2019, 10, 20), date(2019, 10, 21))],
            calendar: Self.japanese)
        #expect(groups.map(\.year) == [1])
        #expect(groups.map(\.yearsAgo) == [7])
    }

    @Test("Gregorian years keep their numbers, years ago and no era")
    func gregorianParity() {
        let stays = [
            stay(date(2023, 6, 10), date(2023, 6, 11)),
            stay(date(2024, 2, 29), date(2024, 2, 29, 20)),
            stay(date(2026, 6, 10, 1), date(2026, 6, 10, 3)),
        ]
        let june = OnThisDayEngine.yearGroups(on: date(2026, 6, 10), stays: stays, calendar: Self.utcGregorian)
        #expect(june.map(\.year) == [2023])
        #expect(june.map(\.yearsAgo) == [3])
        #expect(june.first?.namesEra == nil)
        let leap = OnThisDayEngine.yearGroups(on: date(2028, 2, 29), stays: stays, calendar: Self.utcGregorian)
        #expect(leap.map(\.year) == [2024])
        #expect(leap.map(\.yearsAgo) == [4])
    }
}

// MARK: - STATS-004: first-ever marks on the stamp page that holds them

@MainActor
@Suite("Passport first-ever marks follow the stamp's local year")
struct PassportFirstEverStampYearTests {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func visit(_ code: String, _ start: Date, zone: String?) -> StatsAggregator.StampVisit {
        .init(id: UUID(), code: code, startTime: start, timeZoneIdentifier: zone, tripID: UUID())
    }

    private func pages(_ visits: [StatsAggregator.StampVisit],
                       firstRecorded: [StatsAggregator.FirstRecordedYear]) -> [StampPage] {
        let years = StatsAggregator.stampYears(visits: visits, ongoingTripIDs: [], fallbackZone: utc.timeZone,
                                               checkCancellation: {})
        let marks = StatsAggregator.firstEverStampYears(
            firstRecorded: firstRecorded, visits: visits, fallbackZone: utc.timeZone, checkCancellation: {})
        return StampPage.pages(years, firstRecorded: Dictionary(marks.map { ($0.year, Set($0.codes)) },
                                                                uniquingKeysWith: { first, _ in first }),
                               remembered: [], perPage: nil)
    }

    @Test("a first visit after midnight east of UTC marks the new year's stamp")
    func eastOfUTCMarksNewYear() {
        let visits = [visit("QM", date(2024, 12, 31, hour: 23, minute: 30), zone: "Europe/Athens")]
        let result = pages(visits, firstRecorded: [.init(year: 2024, codes: ["QM"])])
        #expect(result.map(\.year) == [2025])
        #expect(result.first?.firstEver == ["QM"])
    }

    @Test("a first visit before midnight west of UTC marks the old year's stamp, not a later repeat")
    func westOfUTCMarksOldYear() {
        let visits = [
            visit("QL", date(2025, 1, 1, hour: 2), zone: "America/Los_Angeles"),
            visit("QL", date(2025, 7, 10), zone: "America/Los_Angeles"),
        ]
        let result = pages(visits, firstRecorded: [.init(year: 2025, codes: ["QL"])])
        #expect(result.map(\.year) == [2024, 2025])
        #expect(result[0].firstEver == ["QL"])
        #expect(result[1].firstEver.isEmpty)
    }

    @Test("UTC visits keep their year; a country with no stamp in its first year gets no mark")
    func controls() {
        let visits = [
            visit("QN", date(2025, 3, 1), zone: "UTC"),
            visit("QP", date(2026, 3, 1), zone: "UTC"),
        ]
        // QP was first recorded in 2025 at a temporary home, with no stamp
        // that year: its 2026 repeat is not a first.
        let result = pages(visits, firstRecorded: [.init(year: 2025, codes: ["QN", "QP"])])
        #expect(result.map(\.year) == [2025, 2026])
        #expect(result[0].firstEver == ["QN"])
        #expect(result[1].firstEver.isEmpty)
    }

    @Test("the aggregate keeps UTC first-recorded years and files the mark by the stamp")
    func aggregateCarriesStampYearMarks() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: date(2024, 12, 31, hour: 23, minute: 30))
        trip.isComplete = true
        trip.endDate = date(2025, 1, 2)
        trip.countryCodes = "QM"
        context.insert(trip)
        let stay = Stay(startTime: date(2024, 12, 31, hour: 23, minute: 30), endTime: date(2025, 1, 2),
                        centroidLatitude: 44.3, centroidLongitude: 12.9,
                        h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 100, pingIDs: [],
                        timeZoneIdentifier: "Europe/Athens")
        stay.category = .destination
        stay.isoCountryCode = "QM"
        context.insert(stay)
        stay.trip = trip
        try context.save()

        let now = date(2026, 6, 15)
        let result = try StatsAggregator.compute(container: container, now: now, calendar: utc)
        #expect(result.firstRecordedCountries == [.init(year: 2024, codes: ["QM"])])
        #expect(result.firstEverStampYears == [.init(year: 2025, codes: ["QM"])])
        let overview = StatsOverview(result, now: now, calendar: utc, countryArea: { _ in nil })
        #expect(overview.firstRecordedByYear == [2025: ["QM"]])

        // A snapshot from before the field keeps the old join.
        var legacy = result
        legacy.firstEverStampYears = nil
        #expect(StatsOverview(legacy, now: now, calendar: utc, countryArea: { _ in nil })
            .firstRecordedByYear == [2024: ["QM"]])
    }
}

// MARK: - Wrapped fixture

/// A throwaway store holding a 2025 travel year, generated into a recap.
@MainActor
private struct WrappedStore {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try TestSupport.makeInMemoryContainer()
        context = ModelContext(container)
    }

    nonisolated static func date(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2025, month: month, day: day, hour: hour))!
    }

    @discardableResult
    func trip(_ name: String, start: Date, days: Double = 2, id: UUID? = nil,
              complete: Bool = true, countries: String = "QA") -> Trip {
        let trip = Trip(startDate: start)
        if let id { trip.id = id }
        trip.customName = name
        trip.isComplete = complete
        trip.endDate = complete ? start.addingTimeInterval(days * 86_400) : nil
        trip.countryCodes = countries
        context.insert(trip)
        return trip
    }

    /// A trip-member destination stay. `rain` measures it (with a
    /// temperature); `condition` alone marks it, `.unavailable` included.
    @discardableResult
    func stay(_ trip: Trip, start: Date, hours: Double = 6, cell: String = "q1", rain: Double? = nil,
              condition: StayWeather.Condition? = nil, id: UUID? = nil, iso: String = "QA") -> Stay {
        let stay = Stay(startTime: start, endTime: start.addingTimeInterval(hours * 3_600),
                        centroidLatitude: 44.3, centroidLongitude: 12.9,
                        h3IndexRes6: cell, pingCount: 1, distanceFromHomeKm: 100, pingIDs: [],
                        timeZoneIdentifier: "UTC")
        if let id { stay.id = id }
        stay.category = .destination
        stay.isoCountryCode = iso
        if let rain {
            stay.precipitationMm = rain
            stay.avgTemperatureC = 15
            stay.weatherConditionRaw = (condition ?? .rain).rawValue
        } else {
            stay.weatherConditionRaw = condition?.rawValue
        }
        context.insert(stay)
        stay.trip = trip
        return stay
    }

    func generate() async throws -> (outcome: WrappedGenerationOutcome, stats: WrappedStats?) {
        try context.save()
        let outcome = await YearWrappedGenerator(modelContainer: container).generateIfNeeded(forYear: 2025)
        let row = try ModelContext(container).fetch(FetchDescriptor<YearWrapped>()).first
        return (outcome, row?.statsData.flatMap(WrappedStats.decoded(from:)))
    }
}

// MARK: - STATS-005: the wettest trip needs every trip's rain

@MainActor
@Suite("Wrapped names a wettest trip only when rain is fully measured")
struct WrappedRainCoverageTests {

    /// Three trips: A measured 20 mm; B measured 5 mm with a second stay
    /// in `missing` state; C measured 1 mm.
    private func store(missing: StayWeather.Condition?) throws -> WrappedStore {
        let store = try WrappedStore()
        let a = store.trip("Trip A", start: WrappedStore.date(3, 1))
        store.stay(a, start: WrappedStore.date(3, 1), cell: "qa", rain: 20)
        let b = store.trip("Trip B", start: WrappedStore.date(5, 1))
        store.stay(b, start: WrappedStore.date(5, 1), cell: "qb", rain: 5)
        store.stay(b, start: WrappedStore.date(5, 2), cell: "qc", condition: missing)
        let c = store.trip("Trip C", start: WrappedStore.date(7, 1))
        store.stay(c, start: WrappedStore.date(7, 1), cell: "qd", rain: 1)
        return store
    }

    @Test("a stay the enricher may still measure leaves the rain row out, keeping the temperatures")
    func unmeasuredStayWithholdsRain() async throws {
        let (outcome, stats) = try await store(missing: nil).generate()
        #expect(outcome == .created)
        let recap = try #require(stats)
        #expect(recap.rainiestTripName == nil)
        #expect(recap.rainiestPrecipitationMm == nil)
        #expect(recap.hottestTempC == 15)
        #expect(recap.coldestTempC == 15)
    }

    @Test("with every stay measured or terminal, the wettest trip stands")
    func completeRainNamesWinner() async throws {
        let (outcome, stats) = try await store(missing: .unavailable).generate()
        #expect(outcome == .created)
        let recap = try #require(stats)
        #expect(recap.rainiestTripName == "Trip A")
        #expect(recap.rainiestPrecipitationMm == 20)
    }
}

// MARK: - STATS-003: one rain reading counts once, ambiguous totals are withheld

@MainActor
@Suite("Wrapped rain adds readings, never copies of one")
struct WrappedRainReadingTests {

    private let yearEnd = WrappedStore.date(12, 31, 0).addingTimeInterval(86_400)

    private func payload(_ place: String, day: Int, span: Int = 1, mm: Double) -> YearWrappedGenerator.RainPayload {
        .init(place: place, firstDay: WrappedStore.date(6, day, 0), daySpan: span, mm: mm)
    }

    @Test("copies of one reading count once; different days and places add")
    func copiesCountOnce() {
        let copies = YearWrappedGenerator.rainfall(
            [payload("qa", day: 1, mm: 10), payload("qa", day: 1, mm: 10)], yearEnd: yearEnd)
        #expect(copies.mm == 10)
        #expect(copies.exact)
        let added = YearWrappedGenerator.rainfall(
            [payload("qa", day: 1, mm: 10), payload("qa", day: 2, mm: 5), payload("qb", day: 1, mm: 3)],
            yearEnd: yearEnd)
        #expect(added.mm == 18)
        #expect(added.exact)
    }

    @Test("overlapping windows, conflicting values and next-year rain are ambiguous")
    func ambiguousTotals() {
        let overlap = YearWrappedGenerator.rainfall(
            [payload("qa", day: 1, span: 2, mm: 10), payload("qa", day: 2, span: 2, mm: 10)], yearEnd: yearEnd)
        #expect(!overlap.exact)
        #expect(overlap.mm == 20)
        let conflict = YearWrappedGenerator.rainfall(
            [payload("qa", day: 1, mm: 10), payload("qa", day: 1, mm: 12)], yearEnd: yearEnd)
        #expect(!conflict.exact)
        let newYear = YearWrappedGenerator.rainfall(
            [.init(place: "qa", firstDay: WrappedStore.date(12, 31, 0), daySpan: 2, mm: 4)], yearEnd: yearEnd)
        #expect(!newYear.exact)
    }

    @Test("two stays sharing one cached reading no longer outrain a wetter trip")
    func sharedReadingDoesNotWin() async throws {
        let store = try WrappedStore()
        let a = store.trip("Trip A", start: WrappedStore.date(3, 1))
        store.stay(a, start: WrappedStore.date(3, 1, 8), hours: 3, cell: "qa", rain: 10)
        store.stay(a, start: WrappedStore.date(3, 1, 15), hours: 3, cell: "qa", rain: 10)
        let b = store.trip("Trip B", start: WrappedStore.date(5, 1))
        store.stay(b, start: WrappedStore.date(5, 1), cell: "qb", rain: 15)
        let c = store.trip("Trip C", start: WrappedStore.date(7, 1))
        store.stay(c, start: WrappedStore.date(7, 1), cell: "qc", rain: 1)
        let recap = try #require(try await store.generate().stats)
        #expect(recap.rainiestTripName == "Trip B")
        #expect(recap.rainiestPrecipitationMm == 15)
    }

    /// Trip A's two stays overlap on one UTC day in one cell: up to 20 mm.
    private func overlapStore(rivalRain: Double) throws -> WrappedStore {
        let store = try WrappedStore()
        let a = store.trip("Trip A", start: WrappedStore.date(3, 1, 18), days: 3)
        store.stay(a, start: WrappedStore.date(3, 1, 18), cell: "qa", rain: 10)
        store.stay(a, start: WrappedStore.date(3, 2, 18), cell: "qa", rain: 10)
        let b = store.trip("Trip B", start: WrappedStore.date(5, 1))
        store.stay(b, start: WrappedStore.date(5, 1), cell: "qb", rain: rivalRain)
        let c = store.trip("Trip C", start: WrappedStore.date(7, 1))
        store.stay(c, start: WrappedStore.date(7, 1), cell: "qc", rain: 1)
        return store
    }

    @Test("an ambiguous total that could still win withholds the row")
    func ambiguousRivalWithholds() async throws {
        let recap = try #require(try await overlapStore(rivalRain: 15).generate().stats)
        #expect(recap.rainiestTripName == nil)
        #expect(recap.rainiestPrecipitationMm == nil)
    }

    @Test("an ambiguous total below the winner even at its most leaves the winner")
    func ambiguousLoserKeepsWinner() async throws {
        let recap = try #require(try await overlapStore(rivalRain: 25).generate().stats)
        #expect(recap.rainiestTripName == "Trip B")
        #expect(recap.rainiestPrecipitationMm == 25)
    }
}

// MARK: - STATS-002: Wrapped counts a trip once, whatever its twins

@MainActor
@Suite("Wrapped counts same-UUID twins as one trip")
struct WrappedLogicalTripTests {

    @Test("three copies of one trip do not reach the three-trip minimum")
    func twinsDoNotMeetMinimum() async throws {
        let store = try WrappedStore()
        let id = UUID()
        for _ in 0..<3 {
            let copy = store.trip("Trip A", start: WrappedStore.date(3, 1), id: id)
            store.stay(copy, start: WrappedStore.date(3, 1))
        }
        let (outcome, stats) = try await store.generate()
        #expect(outcome == .insufficientData)
        #expect(stats == nil)
        // Every copy is still there: counting never touches a row.
        #expect(try store.context.fetch(FetchDescriptor<Trip>()).count == 3)
    }

    @Test("identical twins count once in trips, months and countries")
    func identicalTwinsCountOnce() async throws {
        let store = try WrappedStore()
        let id = UUID()
        for _ in 0..<2 {
            let copy = store.trip("Trip A", start: WrappedStore.date(3, 1), id: id, countries: "QA")
            store.stay(copy, start: WrappedStore.date(3, 1))
        }
        store.trip("Trip B", start: WrappedStore.date(5, 1), countries: "QB")
        store.trip("Trip C", start: WrappedStore.date(7, 1), countries: "QB")
        let recap = try #require(try await store.generate().stats)
        #expect(recap.tripsCompleted == 3)
        #expect(recap.tripStartMonthCounts?.reduce(0, +) == 3)
        #expect(recap.mostVisitedCountryCode == "QB")
        #expect(recap.mostVisitedCountryTripCount == 2)
        #expect(recap.narrativeInputs?.tripDisplayNames == ["Trip A", "Trip B", "Trip C"])
    }

    @Test("divergent twins pool their countries and name nothing they disagree on")
    func divergentTwinsWithholdNarrative() async throws {
        let store = try WrappedStore()
        let a = store.trip("Trip A", start: WrappedStore.date(3, 1), countries: "QA")
        store.stay(a, start: WrappedStore.date(3, 1))
        let id = UUID()
        store.trip("Trip X", start: WrappedStore.date(5, 1), days: 10, id: id, countries: "QA")
        store.trip("Trip Y", start: WrappedStore.date(5, 1), days: 10, id: id, countries: "QB")
        store.trip("Trip C", start: WrappedStore.date(7, 1), countries: "QA")
        store.trip("Trip D", start: WrappedStore.date(9, 1), days: 3, countries: "QC")
        let recap = try #require(try await store.generate().stats)
        #expect(recap.tripsCompleted == 4)
        #expect(recap.tripStartMonthCounts?.reduce(0, +) == 4)
        #expect(recap.mostVisitedCountryCode == "QA")
        #expect(recap.mostVisitedCountryTripCount == 3)
        // The disputed trip is the longest: no other trip is named for it.
        #expect(recap.longestTripName == nil)
        #expect(recap.narrativeInputs?.tripDisplayNames == ["Trip A", "Trip C", "Trip D"])
    }

    @Test("a disputed trip at either end of the year leaves the year's arc unnamed")
    func disputedEndWithholdsArc() async throws {
        let store = try WrappedStore()
        let id = UUID()
        let x = store.trip("Trip X", start: WrappedStore.date(2, 1), id: id)
        store.stay(x, start: WrappedStore.date(2, 1))
        store.trip("Trip Y", start: WrappedStore.date(2, 1), id: id)
        store.trip("Trip B", start: WrappedStore.date(5, 1))
        store.trip("Trip C", start: WrappedStore.date(7, 1))
        let recap = try #require(try await store.generate().stats)
        #expect(recap.tripsCompleted == 3)
        #expect(recap.narrativeInputs?.tripDisplayNames == [])
    }
}

// MARK: - COV-001: This Year's trip-only days are travel days

@MainActor
@Suite("This Year labels its trip-only days as travel days")
struct ThisYearTravelDaysLabelTests {

    @Test("the days figure carries the trip-only count under the Travel Days label")
    func daysFigureIsTravelDays() throws {
        var overview = StatsOverview()
        overview.thisYear.travelDays = 3
        let days = try #require(StatsYearCard.figureEntries(overview).last)
        #expect(days.label == StatsByYearCard.daysLabel)
        #expect(days.value == 3)
        #expect(days.label != "Days away")
    }
}

// MARK: - FU-5: the import-ping twin scan runs once per ping revision

@MainActor
@Suite("Stats reuses the import-ping twin count until pings change")
struct ImportPingSurplusCacheTests {

    private static let base = Date(timeIntervalSinceReferenceDate: 830_000_000)

    @discardableResult
    private func insertPing(_ context: ModelContext, minutes: Double, id: UUID? = nil) -> LocationPing {
        let ping = LocationPing(
            timestamp: Self.base.addingTimeInterval(minutes * 60),
            latitude: 44.3, longitude: 12.9, horizontalAccuracy: 10,
            h3IndexRes6: H3Service.cellIndex(latitude: 44.3, longitude: 12.9) ?? "",
            source: .photoImport)
        if let id { ping.id = id }
        context.insert(ping)
        return ping
    }

    @Test("a revision that has not moved reuses the count; a new one counts again")
    func countIsKeyedByRevision() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let twin = insertPing(context, minutes: 0)
        insertPing(context, minutes: 0, id: twin.id)
        try context.save()
        let revision = Int.random(in: 1_000_000...2_000_000)

        #expect(try StatsAggregator.compute(container: container, importPingRevision: revision).totalPings == 1)
        // A third copy lands without the revision moving: the scan is not
        // repeated, so the stale surplus shows that the count was reused.
        insertPing(context, minutes: 0, id: twin.id)
        try context.save()
        #expect(try StatsAggregator.compute(container: container, importPingRevision: revision).totalPings == 2)
        // Writers bump the revision after they save: a new revision counts again.
        #expect(try StatsAggregator.compute(container: container, importPingRevision: revision + 1).totalPings == 1)
        // No revision never caches.
        #expect(try StatsAggregator.compute(container: container).totalPings == 1)
    }

    @Test("the scan stops on cancellation")
    func scanHonoursCancellation() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        insertPing(context, minutes: 0)
        try context.save()
        #expect(throws: CancellationError.self) {
            try StatsAggregator.importPingTwinSurplus(in: ModelContext(container)) {
                throw CancellationError()
            }
        }
    }
}
