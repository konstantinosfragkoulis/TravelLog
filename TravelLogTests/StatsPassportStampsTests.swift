//
//  StatsPassportStampsTests.swift
//  TravelLogTests
//
//  The expanded Passport's derived data: stamp pages (a country's first
//  entry per label year, dated in the stay's zone, ongoing trips flagged),
//  their nine-a-page chunking and first-ever marks, the This Year month
//  bins, country days and cities, the countries' first year, the continent
//  count, and snapshot forward-compat for the new optional fields.
//
//  Invented private-use ISO codes (QM to QT) where geography does not
//  matter, on a UTC calendar so day boundaries cannot flake on the runner's
//  zone.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct StatsPassportStampsTests {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private var thisYear: Int { utc.component(.year, from: .now) }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func label(_ year: Int, _ month: Int, _ day: Int) -> Date {
        date(year, month, day, hour: 0)
    }

    private func visit(_ code: String, _ start: Date, zone: String? = "UTC", trip: UUID? = UUID(),
                       id: UUID = UUID()) -> StatsAggregator.StampVisit {
        .init(id: id, code: code, startTime: start, timeZoneIdentifier: zone, tripID: trip)
    }

    // MARK: - Stamp pages

    @Test("a stamp is a country's first entry in each label year, pages ascend and list stamps by entry")
    func stampsPerYear() {
        let ongoing = UUID()
        let visits = [
            visit("QN", date(2024, 5, 3)),
            visit("QN", date(2024, 2, 9)),
            visit("QP", date(2024, 2, 9, hour: 8)),
            visit("QN", date(2025, 1, 2)),
            visit("QQ", date(2025, 3, 1), trip: ongoing),
        ]
        let years = StatsAggregator.stampYears(visits: visits, ongoingTripIDs: [ongoing],
                                               fallbackZone: utc.timeZone, checkCancellation: {})
        #expect(years.map(\.year) == [2024, 2025])
        #expect(years[0].stamps.map(\.code) == ["QN", "QP"])
        #expect(years[0].stamps.map(\.day) == [label(2024, 2, 9), label(2024, 2, 9)])
        #expect(years[1].stamps.map(\.code) == ["QN", "QQ"])
        #expect(years[1].stamps[0].isOngoing == nil)
        #expect(years[1].stamps[1].isOngoing == true)
    }

    @Test("an entry is dated and filed by the stay's own zone, the fallback zone without one")
    func stampsUseStayZone() {
        // 23:30 UTC on 31 December is already 1 January in Athens.
        let instant = date(2024, 12, 31, hour: 23).addingTimeInterval(30 * 60)
        let athens = StatsAggregator.stampYears(
            visits: [visit("QM", instant, zone: "Europe/Athens")], ongoingTripIDs: [],
            fallbackZone: utc.timeZone, checkCancellation: {})
        #expect(athens.map(\.year) == [2025])
        #expect(athens.first?.stamps.first?.day == label(2025, 1, 1))

        let fallback = StatsAggregator.stampYears(
            visits: [visit("QM", instant, zone: nil)], ongoingTripIDs: [],
            fallbackZone: utc.timeZone, checkCancellation: {})
        #expect(fallback.map(\.year) == [2024])
    }

    @Test("pages hold nine stamps; first-ever marks the year's first-recorded countries, never remembered ones")
    func pagesChunkAndMarkFirstEver() {
        let stamps = (0..<11).map { index in
            StatsAggregator.StampEntry(code: String(format: "Q%@", String(UnicodeScalar(65 + index)!)),
                                       day: label(2025, 1, index + 1))
        }
        let pages = StampPage.pages(
            [.init(year: 2024, stamps: [.init(code: "QA", day: label(2024, 4, 1))]),
             .init(year: 2025, stamps: stamps)],
            firstRecorded: [2025: ["QA", "QB", "QZ"], 2024: ["QA"]],
            remembered: ["QB"])
        #expect(pages.map(\.id) == ["2024-0", "2025-0", "2025-1"])
        #expect(pages[1].stamps.count == 9)
        #expect(pages[2].stamps.count == 2)
        #expect(pages[2].yearStampCount == 11)
        // QZ has no stamp that year; QB is remembered from before TravelLog.
        #expect(pages[1].firstEver == ["QA"])
        #expect(pages[0].firstEver == ["QA"])
    }

    // MARK: - Aggregate

    @Test("the aggregate carries this year's months, country days, cities, stamps and each country's first year")
    func aggregateCarriesThisYear() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let past = Trip(startDate: date(thisYear - 1, 7, 1))
        past.isComplete = true
        past.endDate = date(thisYear - 1, 7, 3)
        past.countryCodes = "QN"
        context.insert(past)
        let current = Trip(startDate: date(thisYear, 3, 10))
        current.isComplete = true
        current.endDate = date(thisYear, 3, 12)
        current.countryCodes = "QN,QP"
        context.insert(current)
        for (iso, start, trip, longitude) in [
            ("QN", date(thisYear - 1, 7, 1), past, -30.0),
            ("QN", date(thisYear, 3, 10), current, -30.0),
            ("QP", date(thisYear, 3, 11), current, 40.0),
            ("QP", date(thisYear, 3, 12), current, 40.0),
        ] {
            let stay = Stay(startTime: start, endTime: start.addingTimeInterval(6 * 3_600),
                            centroidLatitude: 0.5, centroidLongitude: longitude,
                            h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 100, pingIDs: [],
                            timeZoneIdentifier: "UTC")
            stay.category = .destination
            stay.isoCountryCode = iso
            stay.country = iso
            context.insert(stay)
            stay.trip = trip
        }
        try context.save()

        let result = try StatsAggregator.compute(container: container, now: date(thisYear, 6, 15), calendar: utc)

        let months = try #require(result.monthTravelDaysThisYear)
        #expect(months[2] == 3)
        #expect(months.reduce(0, +) == result.travelDaysThisYear)
        #expect(result.countryDaysThisYear == [.init(code: "QP", days: 2), .init(code: "QN", days: 1)])
        #expect(result.citiesThisYear == 2)
        let stamps = try #require(result.stampYears)
        #expect(stamps.map(\.year) == [thisYear - 1, thisYear])
        #expect(stamps.last?.stamps.map(\.code) == ["QN", "QP"])
        #expect(result.countryStats.first { $0.code == "QN" }?.firstYear == thisYear - 1)
        #expect(result.countryStats.first { $0.code == "QP" }?.firstYear == thisYear)

        let overview = StatsOverview(result, now: date(thisYear, 6, 15), calendar: utc)
        #expect(overview.countriesThisYearCount == 2)
        #expect(overview.citiesThisYear == 2)
        #expect(overview.monthDaysThisYear?[2] == 3)
        #expect(overview.stampYears == stamps)
    }

    // MARK: - Continents

    @Test("continents split the Americas, keep Antarctica apart and put Cyprus in Europe")
    func continents() {
        #expect(PassportContinents.count(["FR", "DE", "CY"]) == 1)
        #expect(PassportContinents.count(["US", "MX", "JM"]) == 1)
        #expect(PassportContinents.count(["US", "BR"]) == 2)
        #expect(PassportContinents.count(["FR", "JP", "US", "BR", "AQ", "AU", "KE"]) == 7)
        #expect(PassportContinents.count([]) == 0)
    }

    // MARK: - Snapshot forward-compat

    @Test("a snapshot written before the Passport fields existed decodes with them nil")
    func snapshotWithoutPassportFieldsDecodes() throws {
        var aggregates = StatsAggregator.Aggregates()
        aggregates.monthTravelDaysThisYear = Array(repeating: 1, count: 12)
        aggregates.citiesThisYear = 3
        aggregates.countryDaysThisYear = [.init(code: "QN", days: 2)]
        aggregates.stampYears = [.init(year: thisYear, stamps: [.init(code: "QN", day: label(thisYear, 1, 1))])]
        aggregates.countryStats = [CountryStat(code: "QN", name: "QN", tripCount: 1, isHome: false, firstYear: 2020)]
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(aggregates)) as? [String: Any])
        for key in ["monthTravelDaysThisYear", "citiesThisYear", "countryDaysThisYear", "stampYears"] {
            #expect(object.removeValue(forKey: key) != nil)
        }
        var stats = try #require(object["countryStats"] as? [[String: Any]])
        #expect(stats[0].removeValue(forKey: "firstYear") != nil)
        object["countryStats"] = stats

        let decoded = try JSONDecoder().decode(
            StatsAggregator.Aggregates.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.monthTravelDaysThisYear == nil)
        #expect(decoded.citiesThisYear == nil)
        #expect(decoded.countryDaysThisYear == nil)
        #expect(decoded.stampYears == nil)
        #expect(decoded.countryStats.first?.firstYear == nil)
        let overview = StatsOverview(decoded, now: .now, calendar: utc)
        #expect(overview.stampYears.isEmpty)
        #expect(overview.monthDaysThisYear == nil)
    }
}
