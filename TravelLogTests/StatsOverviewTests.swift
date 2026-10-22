//
//  StatsOverviewTests.swift
//  TravelLogTests
//
//  The Stats page redesign's reducers: the twelve month bins, the
//  trip-length buckets, Last Trip's length and end, the first-recorded
//  countries (Wrapped's new-country rule, checked against a generated
//  Wrapped), the zero-filled This Year / By Year overview, the Passport
//  Flights tile against the Flight Log, the Exploration years and country
//  coverage, and snapshot forward-compat for the new optional fields.
//
//  Invented private-use ISO codes (QM to QT), synthetic coordinates and
//  years relative to today, on a UTC calendar so day boundaries cannot
//  flake on the runner's zone.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct StatsOverviewTests {

    // MARK: - Fixtures

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private var thisYear: Int { utc.component(.year, from: .now) }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @discardableResult
    private func stay(
        _ context: ModelContext, _ category: StayCategory, iso: String?,
        start: Date, hours: Double = 6, trip: Trip? = nil,
        latitude: Double = 0.5, longitude: Double = -30, flightLeg: Bool = false
    ) -> Stay {
        let stay = Stay(startTime: start, endTime: start.addingTimeInterval(hours * 3_600),
                        centroidLatitude: latitude, centroidLongitude: longitude,
                        h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 100, pingIDs: [],
                        timeZoneIdentifier: "UTC")
        stay.category = category
        stay.isoCountryCode = iso
        stay.country = iso
        if flightLeg { stay.transitFromPreviousRaw = TransitMode.flight.rawValue }
        context.insert(stay)
        stay.trip = trip
        return stay
    }

    @discardableResult
    private func trip(_ context: ModelContext, _ start: Date, days: Int, codes: String, complete: Bool = true) -> Trip {
        let trip = Trip(startDate: start)
        trip.isComplete = complete
        if complete { trip.endDate = start.addingTimeInterval(Double(days - 1) * 86_400) }
        trip.countryCodes = codes
        context.insert(trip)
        return trip
    }

    // MARK: - Month bins

    @Test("month bins pool every year by Gregorian label month, and the favourite month ties to the earlier one")
    func monthBins() {
        let days: Set<Date> = [
            date(thisYear - 2, 1, 3, hour: 0), date(thisYear - 1, 1, 4, hour: 0),
            date(thisYear, 8, 1, hour: 0), date(thisYear, 8, 2, hour: 0),
        ]
        let bins = StatsAggregator.monthTravelDays(days: days, checkCancellation: {})
        #expect(bins.count == 12)
        #expect(bins[0] == 2)
        #expect(bins[7] == 2)
        #expect(bins.reduce(0, +) == 4)
        // Two months tie at 2: January wins.
        #expect(StatsAggregator.favoriteMonth(bins: bins)?.month == 1)
        #expect(StatsAggregator.favoriteMonth(bins: Array(repeating: 0, count: 12)) == nil)
        // The day-set entry point agrees with the bins.
        #expect(StatsAggregator.favoriteMonth(days: days, calendar: utc)?.month == 1)
        #expect(StatsAggregator.favoriteMonth(days: days, calendar: utc)?.days == 2)
    }

    // MARK: - Trip-length buckets

    @Test("trip lengths bucket 1 to 3, 4 to 7, 8 to 14 and 15+, twins once at their longer length, unknown left out")
    func tripLengthBuckets() {
        let twin = UUID()
        let ids = [UUID(), UUID(), UUID(), UUID(), UUID(), UUID(), UUID(), UUID(), twin, twin]
        let durations = [1, 3, 4, 7, 8, 14, 15, 0, 2, 9]
        #expect(StatsAggregator.tripLengthBuckets(tripIDs: ids, durations: durations) == [2, 2, 3, 1])
        #expect(StatsAggregator.tripLengthBuckets(tripIDs: [], durations: []) == [0, 0, 0, 0])
    }

    @Test("the aggregate carries the month bins, the buckets and Last Trip's length and end")
    func aggregateCarriesPatternsAndLastTrip() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let year = thisYear - 1
        let short = trip(context, date(year, 3, 10), days: 3, codes: "QN")
        stay(context, .destination, iso: "QN", start: date(year, 3, 10), trip: short)
        stay(context, .destination, iso: "QN", start: date(year, 3, 12), trip: short)
        let long = trip(context, date(year, 7, 1), days: 16, codes: "QP")
        stay(context, .destination, iso: "QP", start: date(year, 7, 1), trip: long)
        stay(context, .destination, iso: "QP", start: date(year, 7, 16), trip: long)
        try context.save()

        let result = try StatsAggregator.compute(container: container, now: date(thisYear, 1, 20), calendar: utc)

        let bins = try #require(result.monthTravelDays)
        #expect(bins[2] == 3)
        #expect(bins[6] == 16)
        #expect(bins.reduce(0, +) == result.travelDaysTotal)
        #expect(result.favoriteMonth == 7)
        #expect(result.tripLengthBuckets == [1, 0, 0, 1])
        let last = try #require(result.lastTrip)
        #expect(last.tripID == long.id)
        #expect(last.days == 16)
        #expect(last.endDate == long.endDate)
    }

    // MARK: - First recorded

    /// One store exercising every branch of Wrapped's rule for `year`:
    /// QM real home (never new), QN seen on a routine stay the year before,
    /// QP plainly new, QQ new although QM shares its trip, QR new because an
    /// earlier transit stop is no visit, QS a tripless destination (no
    /// geography), QT seen on an unclassified stay the year before.
    private func firstRecordedStore(year: Int) throws -> ModelContainer {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        stay(context, .home, iso: "QM", start: date(year, 1, 15))
        stay(context, .routine, iso: "QN", start: date(year - 1, 6, 1))
        stay(context, .transit, iso: "QR", start: date(year - 1, 6, 2))
        stay(context, .unclassified, iso: "QT", start: date(year - 1, 6, 3))
        stay(context, .destination, iso: "QS", start: date(year, 2, 1))

        let first = trip(context, date(year, 3, 1), days: 3, codes: "QN,QP")
        stay(context, .destination, iso: "QN", start: date(year, 3, 1), trip: first)
        stay(context, .destination, iso: "QP", start: date(year, 3, 2), trip: first)
        let second = trip(context, date(year, 5, 1), days: 3, codes: "QQ,QM")
        stay(context, .destination, iso: "QQ", start: date(year, 5, 1), trip: second)
        stay(context, .destination, iso: "QM", start: date(year, 5, 2), trip: second)
        let third = trip(context, date(year, 7, 1), days: 3, codes: "QR,QT")
        stay(context, .destination, iso: "QR", start: date(year, 7, 1), trip: third)
        stay(context, .destination, iso: "QT", start: date(year, 7, 2), trip: third)
        try context.save()
        return container
    }

    @Test("first-recorded countries follow Wrapped's new-country rule, year by year")
    func firstRecordedRule() throws {
        let year = thisYear - 2
        let container = try firstRecordedStore(year: year)
        let result = try StatsAggregator.compute(container: container, now: .now, calendar: utc)
        let byYear = Dictionary(uniqueKeysWithValues: (result.firstRecordedCountries ?? []).map { ($0.year, $0.codes) })
        #expect(byYear[year] == ["QP", "QQ", "QR"])
        #expect(byYear[year - 1] == nil)
    }

    @Test("first-recorded countries match a Wrapped generated for the same year")
    func firstRecordedMatchesWrapped() async throws {
        let year = thisYear - 2
        let container = try firstRecordedStore(year: year)
        let generator = YearWrappedGenerator(modelContainer: container)
        let outcome = await PipelineGate(forTesting: ()).runReturning(touching: [.yearWrapped]) {
            await generator.generateIfNeeded(forYear: year)
        }
        #expect(outcome == .created)
        let y = year
        let row = try #require(try ModelContext(container).fetch(
            FetchDescriptor<YearWrapped>(predicate: #Predicate { $0.year == y })).first)
        let wrapped = try #require(row.statsData.flatMap(WrappedStats.decoded(from:)))

        let result = try StatsAggregator.compute(container: container, now: .now, calendar: utc)
        let stats = result.firstRecordedCountries?.first { $0.year == year }?.codes ?? []
        #expect(stats == wrapped.newCountryCodes)
        #expect(stats == ["QP", "QQ", "QR"])
    }

    // MARK: - Overview

    @Test("By Year fills zero years up to this year, keeps the last eight, and This Year reads the same ledger")
    func overviewFillsZeroYears() {
        var aggregates = StatsAggregator.Aggregates()
        let now = date(thisYear, 6, 1)
        aggregates.yearStats = [
            .init(year: thisYear - 10, trips: 1, days: 2, countries: 1),
            .init(year: thisYear - 3, trips: 2, days: 9, countries: 2),
            .init(year: thisYear - 1, trips: 4, days: 20, countries: 3),
            .init(year: thisYear, trips: 1, days: 5, countries: 1),
        ]
        aggregates.firstRecordedCountries = [
            .init(year: thisYear - 1, codes: ["QN", "QP"]),
            .init(year: thisYear, codes: ["QQ", "QR"]),
        ]
        let overview = StatsOverview(aggregates, now: now, calendar: utc)

        #expect(overview.years.map(\.year) == Array((thisYear - 7)...thisYear))
        #expect(overview.currentMonth == 6)
        #expect(overview.years.first { $0.year == thisYear - 2 }?.days == 0)
        #expect(overview.years.last?.days == 5)
        #expect(overview.thisYear.travelDays == 5)
        #expect(overview.thisYear.trips == 1)
        #expect(overview.lastYear.travelDays == 20)
        #expect(overview.lastYear.countries == 3)
        #expect(overview.comparesWithLastYear)
        // Remembered countries carry no date: never first recorded.
        #expect(overview.thisYear.firstRecordedCount(excluding: []) == 2)
        #expect(overview.thisYear.firstRecordedCount(excluding: ["QQ"]) == 1)
        #expect(overview.lastYear.firstRecordedCount(excluding: ["QQ"]) == 2)
    }

    @Test("a first year of data has no comparison and a single bar; a quiet current year still gets its zero bar")
    func overviewLowData() {
        var aggregates = StatsAggregator.Aggregates()
        aggregates.yearStats = [.init(year: thisYear, trips: 1, days: 3, countries: 1)]
        let single = StatsOverview(aggregates, now: date(thisYear, 6, 1), calendar: utc)
        #expect(single.years.count == 1)
        #expect(!single.comparesWithLastYear)
        #expect(single.monthDays == nil)
        #expect(single.tripLengthBuckets == nil)

        aggregates.yearStats = [.init(year: thisYear - 1, trips: 1, days: 3, countries: 1)]
        aggregates.monthTravelDays = Array(repeating: 0, count: 12)
        aggregates.tripLengthBuckets = [0, 0, 0, 0]
        let quiet = StatsOverview(aggregates, now: date(thisYear, 6, 1), calendar: utc)
        #expect(quiet.years.map(\.year) == [thisYear - 1, thisYear])
        #expect(quiet.thisYear.travelDays == 0)
        #expect(quiet.comparesWithLastYear)
        // All-zero bins and buckets hide their sections.
        #expect(quiet.monthDays == nil)
        #expect(quiet.tripLengthBuckets == nil)

        #expect(!StatsOverview(StatsAggregator.Aggregates(), now: .now, calendar: utc).hasYearData)
    }

    // MARK: - Flights

    @Test("Passport Flights equals the Flight Log count; the stay-level count Siri reads may be larger")
    func passportFlightsMatchFlightLog() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let year = thisYear - 1
        let away = trip(context, date(year, 4, 1), days: 3, codes: "QP")
        stay(context, .home, iso: "QM", start: date(year, 3, 31), latitude: 0.5, longitude: -30)
        stay(context, .destination, iso: "QP", start: date(year, 4, 1), trip: away,
             latitude: 10.5, longitude: -20, flightLeg: true)
        // An unclassified arrival is no Flight Log entry yet; Siri counts it.
        stay(context, .unclassified, iso: "QP", start: date(year, 4, 5),
             latitude: 0.5, longitude: -30, flightLeg: true)
        try context.save()

        let result = try StatsAggregator.compute(container: container, now: .now, calendar: utc)
        let siri = try StatsAggregator.passportSummary(container: container, now: .now, calendar: utc)

        #expect(result.collections.flights.count == 1)
        #expect(result.passportData.flights == result.collections.flights.count)
        #expect(result.flightCount == 2)
        #expect(siri.flights == result.flightCount)
        #expect(StatsOverview(result, now: .now, calendar: utc).collections.flightCount == result.passportData.flights)
    }

    // MARK: - Exploration

    /// A valid res-6 cell at synthetic open-ocean coordinates.
    private func cell(_ index: Int) -> String {
        H3Service.cellIndex(latitude: 0.5 + Double(index) * 0.4, longitude: -30)!
    }

    private func hexVisit(_ h3Index: String, _ firstVisited: Date, iso: String? = nil) -> HexVisit {
        let visit = HexVisit(h3Index: h3Index, firstVisited: firstVisited, centerLatitude: 0, centerLongitude: 0)
        visit.isoCountryCode = iso
        return visit
    }

    @Test("new hexes per year count each visible cell once, in its earliest row's year")
    func newHexesByYear() {
        let flyover = Stay(startTime: .now, endTime: .now, centroidLatitude: 0, centroidLongitude: 0,
                           h3IndexRes6: cell(9), pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
        flyover.category = .transit
        flyover.transitFromPreviousRaw = TransitMode.flight.rawValue
        let hexVisits = [
            hexVisit(cell(0), date(thisYear - 3, 5, 1)),
            // The same cell again later: still first explored three years ago.
            hexVisit(cell(0), date(thisYear, 2, 1)),
            hexVisit(cell(1), date(thisYear - 1, 3, 1)),
            hexVisit(cell(2), date(thisYear - 1, 9, 1)),
            hexVisit(cell(3), date(thisYear, 1, 10)),
            // Hidden aerial-only cell: out of every count, like the total.
            hexVisit(cell(9), date(thisYear, 4, 1)),
        ]
        let result = StatsAggregator.aggregate(
            visitedStays: [], transitStays: [flyover], trips: [], hexVisits: hexVisits,
            totalPings: 0, totalStays: 1, flightCount: 1, trackingSince: nil,
            now: date(thisYear, 6, 1), calendar: utc)

        let years = result.newHexesByYear ?? []
        #expect(years == [.init(year: thisYear - 3, count: 1), .init(year: thisYear - 1, count: 2),
                          .init(year: thisYear, count: 1)])
        #expect(years.map(\.count).reduce(0, +) == result.totalHexes)
        #expect(years.last?.count == result.newHexesThisYear)
    }

    @Test("the year strip is zero-filled, ends at the current year, keeps eight years and needs two")
    func explorationYears() {
        var aggregates = StatsAggregator.Aggregates()
        aggregates.newHexesThisYear = 0
        aggregates.newHexesByYear = [.init(year: thisYear - 12, count: 40), .init(year: thisYear - 3, count: 12),
                                     .init(year: thisYear - 1, count: 30)]
        let overview = StatsOverview(aggregates, now: date(thisYear, 6, 1), calendar: utc)
        let years = overview.exploration.years
        #expect(years.map(\.year) == Array((thisYear - 7)...thisYear))
        #expect(years.first { $0.year == thisYear - 2 }?.count == 0)
        #expect(years.first { $0.year == thisYear - 1 }?.count == 30)
        #expect(years.last?.count == 0)
        #expect(overview.exploration.showsYears)

        aggregates.newHexesByYear = [.init(year: thisYear, count: 5)]
        aggregates.newHexesThisYear = 5
        let first = StatsOverview(aggregates, now: date(thisYear, 6, 1), calendar: utc).exploration
        #expect(first.years.map(\.year) == [thisYear])
        #expect(!first.showsYears)
        #expect(first.newThisYear == 5)

        aggregates.newHexesByYear = nil
        #expect(StatsOverview(aggregates, now: .now, calendar: utc).exploration.years.isEmpty)
    }

    @Test("coverage measures each country against its area; homes pin first and leave the others")
    func explorationCoverage() {
        var aggregates = StatsAggregator.Aggregates()
        aggregates.homeHexCountries = [.init(code: "QM", name: "Norvania", count: 250),
                                       .init(code: "QT", name: nil, count: 0)]
        aggregates.topHexCountries = [.init(code: "QM", name: "Norvania", count: 250),
                                      .init(code: "QN", name: "Ostrelia", count: 300),
                                      .init(code: "QP", name: "Calderra", count: 12)]
        // Invented areas: QM holds exactly 1000 mean hexes; QP has none on record.
        let areas: [String: Double] = ["QM": CountryCatalog.averageHexAreaKm2 * 1_000,
                                       "QN": CountryCatalog.averageHexAreaKm2 * 7_412.3,
                                       "QT": CountryCatalog.averageHexAreaKm2 * 0.2]
        let summary = StatsOverview(aggregates, now: .now, calendar: utc, countryArea: { areas[$0] }).exploration

        #expect(summary.homes.map(\.code) == ["QM", "QT"])
        #expect(summary.others.map(\.code) == ["QN", "QP"])
        let home = summary.homes[0]
        #expect(abs((home.percent ?? 0) - 25) < 0.0001)
        #expect(home.estimatedTotal == 1_000)
        // A zero-hex home still has its meter, at zero, against at least one hex.
        #expect(summary.homes[1].percent == 0)
        #expect(summary.homes[1].estimatedTotal == 1)
        #expect(summary.others[0].estimatedTotal == 7_400)
        #expect(summary.others[1].percent == nil)
        #expect(summary.others[1].estimatedTotal == nil)
        #expect(summary.maxListedCount == 300)

        #expect(CountryCatalog.estimatedHexCount(areaKm2: CountryCatalog.averageHexAreaKm2 * 47.4) == 47)
        #expect(CountryCatalog.estimatedHexCount(areaKm2: CountryCatalog.averageHexAreaKm2 * 473_353) == 470_000)
    }

    // MARK: - Snapshot forward-compat

    @Test("a snapshot written before the new fields existed decodes with them nil")
    func snapshotWithoutNewFieldsDecodes() throws {
        var aggregates = StatsAggregator.Aggregates()
        aggregates.monthTravelDays = Array(repeating: 1, count: 12)
        aggregates.tripLengthBuckets = [1, 2, 3, 4]
        aggregates.firstRecordedCountries = [.init(year: thisYear, codes: ["QP"])]
        aggregates.newHexesByYear = [.init(year: thisYear, count: 3)]
        aggregates.lastTrip = .init(name: "Velmora Loop", date: date(thisYear, 2, 1), tripID: UUID(),
                                    days: 4, endDate: date(thisYear, 2, 4))
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(aggregates)) as? [String: Any])
        for key in ["monthTravelDays", "tripLengthBuckets", "firstRecordedCountries", "newHexesByYear"] {
            #expect(object.removeValue(forKey: key) != nil)
        }
        var lastTrip = try #require(object["lastTrip"] as? [String: Any])
        lastTrip.removeValue(forKey: "days")
        lastTrip.removeValue(forKey: "endDate")
        object["lastTrip"] = lastTrip

        let decoded = try JSONDecoder().decode(
            StatsAggregator.Aggregates.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.monthTravelDays == nil)
        #expect(decoded.tripLengthBuckets == nil)
        #expect(decoded.firstRecordedCountries == nil)
        #expect(decoded.newHexesByYear == nil)
        #expect(StatsOverview(decoded, now: .now, calendar: utc).exploration.years.isEmpty)
        #expect(decoded.lastTrip?.name == "Velmora Loop")
        #expect(decoded.lastTrip?.days == nil)
        #expect(decoded.lastTrip?.endDate == nil)
    }
}
