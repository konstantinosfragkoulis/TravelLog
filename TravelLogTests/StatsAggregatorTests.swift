//
//  StatsAggregatorTests.swift
//  TravelLogTests
//
//  Covers `StatsAggregator` — the off-main fetch+reduce pass behind the
//  Stats page (moved out of `StatsView` 2026-07). Focus areas:
//
//  1. The "Hexes explored" count uses the Map's ROW-FILTER semantics
//     (visible `hexVisits` cells), NOT `rawCount - hidden.count` — the
//     subtraction undercounted whenever a transit-stay CENTROID hex had no
//     per-ping `HexVisit` row (phantom hidden hex).
//  2. The tracking-since gate: the unindexed first-ping scan re-runs only
//     when the ping count changed (or nothing is cached yet).
//  3. Deterministic tiebreaks for the superlatives (most-visited place,
//     longest trip, last trip) — `max` over hash-randomized Dictionary
//     iteration / unsorted fetches used to flip winners between launches.
//
//  `@MainActor` because the app target compiles with MainActor-by-default
//  isolation, making `@Model` types MainActor-isolated. `aggregate(...)` is
//  pure over already-materialized rows, so most tests skip the container;
//  the gate tests exercise `compute(container:)` end-to-end and `save()`
//  before calling it (the aggregator fetches on its OWN context, which
//  cannot see unsaved inserts).
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct StatsAggregatorTests {

    @Test("Stats refresh identity skips the same civil day and refreshes the next")
    func refreshIdentityTracksCivilDay() {
        let zone = TimeZone(secondsFromGMT: 0)!
        let beforeMidnight = Date(timeIntervalSince1970: 1_788_652_740) // 2026-09-05 23:59 UTC
        let first = StatsRefreshIdentity(storeToken: 7, now: beforeMidnight, timeZone: zone)
        let sameDay = StatsRefreshIdentity(storeToken: 7, now: beforeMidnight.addingTimeInterval(-60), timeZone: zone)
        let nextDay = StatsRefreshIdentity(storeToken: 7, now: beforeMidnight.addingTimeInterval(120), timeZone: zone)
        #expect(first == sameDay)
        #expect(!sameDay.needsRefresh(comparedTo: first))
        #expect(first != nextDay)
        #expect(nextDay.needsRefresh(comparedTo: first))
        #expect(first.needsRefresh(comparedTo: nil))
        #expect(StatsRefreshIdentity(storeToken: 8, now: beforeMidnight, timeZone: zone)
            .needsRefresh(comparedTo: first))
    }

    @Test("Stats refresh identity uses the local day and handles New Year and DST")
    func refreshIdentityCalendarBoundaries() {
        let utc = TimeZone(secondsFromGMT: 0)!
        let instant = Date(timeIntervalSince1970: 1_788_652_740)
        #expect(StatsRefreshIdentity(storeToken: 0, now: instant, timeZone: utc)
            != StatsRefreshIdentity(storeToken: 0, now: instant, timeZone: TimeZone(secondsFromGMT: 7200)!))
        // These zones share a midnight instant but have different civil dates.
        let dateLineInstant = Date(timeIntervalSince1970: 1_767_259_800) // 2026-01-01 09:30 UTC
        let east = StatsRefreshIdentity(storeToken: 0, now: dateLineInstant,
                                        timeZone: TimeZone(secondsFromGMT: 14 * 3600)!)
        let west = StatsRefreshIdentity(storeToken: 0, now: dateLineInstant,
                                        timeZone: TimeZone(secondsFromGMT: -10 * 3600)!)
        #expect(east != west)
        #expect(west.needsRefresh(comparedTo: east))
        // Historical memory matching depends on the zone even on the same civil date.
        #expect(east != StatsRefreshIdentity(storeToken: 0, now: dateLineInstant,
                                             timeZone: TimeZone(secondsFromGMT: 13 * 3600)!))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let next = calendar.date(byAdding: .day, value: 1, to: start)!
        #expect(next.timeIntervalSince(start) == 23 * 3600)
        let first = StatsRefreshIdentity(storeToken: 0, now: start, timeZone: calendar.timeZone)
        #expect(first == StatsRefreshIdentity(storeToken: 0, now: next.addingTimeInterval(-1), timeZone: calendar.timeZone))
        #expect(first != StatsRefreshIdentity(storeToken: 0, now: next, timeZone: calendar.timeZone))
        let newYear = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        #expect(StatsRefreshIdentity(storeToken: 0, now: newYear.addingTimeInterval(-1), timeZone: calendar.timeZone)
            != StatsRefreshIdentity(storeToken: 0, now: newYear, timeZone: calendar.timeZone))
    }

    @Test("Same-date time-zone changes refresh the actual memory computation")
    func sameDateZoneChangeRefreshesMemories() {
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-12-13T12:00:00Z")!
        let start = formatter.date(from: "2025-12-12T22:30:00Z")!
        let end = formatter.date(from: "2025-12-12T23:30:00Z")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var east = utc
        east.timeZone = TimeZone(secondsFromGMT: 7200)!
        let stay = makeStay(category: .destination, start: start, end: end, metroName: "Athens")
        let trip = makeTrip(start: start, end: end)
        stay.trip = trip
        func compute(_ calendar: Calendar) -> StatsAggregator.Aggregates {
            StatsAggregator.aggregate(visitedStays: [stay], transitStays: [], trips: [trip],
                hexVisits: [], totalPings: 1, totalStays: 1, flightCount: 0,
                trackingSince: start, now: now, calendar: calendar)
        }
        #expect(compute(utc).onThisDayGroups.isEmpty)
        #expect(compute(east).onThisDayGroups.count == 1)
        let previous = StatsRefreshIdentity(storeToken: 7, now: now, timeZone: utc.timeZone, calendar: utc)
        let changed = StatsRefreshIdentity(storeToken: 7, now: now, timeZone: east.timeZone, calendar: east)
        #expect(previous.day == changed.day)
        #expect(changed.needsRefresh(comparedTo: previous))
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = east.timeZone
        #expect(changed != StatsRefreshIdentity(storeToken: 7, now: now,
            timeZone: east.timeZone, calendar: buddhist))
    }

    @Test("Passport and exploration use Gregorian years under a Buddhist calendar")
    func gregorianPassportAndExploration() {
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-06-01T12:00:00Z")!
        let start = formatter.date(from: "2025-12-31T23:30:00Z")!
        let end = formatter.date(from: "2026-01-02T12:00:00Z")!
        let trip = makeTrip(start: start, end: end)
        let stay = makeStay(category: .destination, start: start, end: end)
        stay.timeZoneIdentifier = "Pacific/Kiritimati"
        trip.stays = [stay]
        stay.trip = trip
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(secondsFromGMT: 0)!
        let result = StatsAggregator.aggregate(visitedStays: [stay], transitStays: [], trips: [trip],
            hexVisits: [makeHexVisit(Self.hexA, firstVisited: end)], totalPings: 1, totalStays: 1,
            flightCount: 0, trackingSince: start, now: now, calendar: buddhist)
        #expect(result.passportData.sinceYear == 2025)
        #expect(result.passportData.tripsThisYear == 1)
        #expect(result.newHexesThisYear == 1)
    }

    // MARK: - Fixtures

    private func makeStay(
        category: StayCategory,
        hex: String = "",
        start: Date = .now,
        end: Date = .now,
        metroName: String? = nil,
        isoCountryCode: String? = nil,
        country: String? = nil
    ) -> Stay {
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: 0, centroidLongitude: 0,
            h3IndexRes6: hex, pingCount: 1,
            distanceFromHomeKm: 0, pingIDs: []
        )
        stay.category = category
        stay.metroName = metroName
        stay.isoCountryCode = isoCountryCode
        stay.country = country
        return stay
    }

    private func makeTransitStay(hex: String, mode: TransitMode?, isAirport: Bool = false) -> Stay {
        let stay = makeStay(category: .transit, hex: hex)
        stay.transitFromPreviousRaw = mode?.rawValue
        stay.isAirport = isAirport
        return stay
    }

    private func makeTrip(
        start: Date,
        end: Date?,
        name: String? = nil,
        codes: String = ""
    ) -> Trip {
        let trip = Trip(startDate: start)
        trip.endDate = end
        trip.isComplete = end != nil
        trip.customName = name
        trip.countryCodes = codes
        return trip
    }

    private func makeHexVisit(_ h3Index: String, firstVisited: Date = .now) -> HexVisit {
        HexVisit(h3Index: h3Index, firstVisited: firstVisited, centerLatitude: 0, centerLongitude: 0)
    }

    // Valid H3 cells: `totalHexes` applies the shared renderability check,
    // so counted fixture hexes must be real H3 indices.
    // A bare letter is dropped exactly like the map drops it.
    // Distinct coordinates produce distinct cells.
    private static let hexA = H3Service.cellIndex(latitude: 37.98, longitude: 23.72)!
    private static let hexB = H3Service.cellIndex(latitude: 48.85, longitude: 2.35)!
    private static let hexC = H3Service.cellIndex(latitude: 51.50, longitude: -0.12)!
    private static let hexD = H3Service.cellIndex(latitude: 40.71, longitude: -74.00)!

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    // MARK: - Hex count (row-filter rule)

    @Test("totalHexes counts visible ROWS — a hidden hex with no HexVisit row is not subtracted")
    func hexCountIgnoresPhantomHiddenHexes() {
        // Rows exist for A (real visit), B (aerial flyover), D (road trip).
        let hexVisits = [makeHexVisit(Self.hexA), makeHexVisit(Self.hexB), makeHexVisit(Self.hexD)]
        let visited = [makeStay(category: .destination, hex: Self.hexA)]
        let transit = [
            makeTransitStay(hex: Self.hexB, mode: .flight),    // hidden, row exists
            makeTransitStay(hex: Self.hexC, mode: .flight),    // hidden, NO row (phantom centroid hex)
            makeTransitStay(hex: Self.hexD, mode: .automotive) // surface → paints
        ]

        let result = StatsAggregator.aggregate(
            visitedStays: visited, transitStays: transit, trips: [],
            hexVisits: hexVisits, totalPings: 0, totalStays: 4,
            flightCount: 1, trackingSince: nil
        )

        // A (real) + D (surface transit) visible; B hidden. The phantom "C"
        // must NOT be subtracted — the old `rawCount - hidden.count` gave 1.
        #expect(result.totalHexes == 2)
    }

    @Test("airport waypoint hexes hide; a hex shared with a real visit never hides")
    func airportAndSharedHexRules() {
        let hexVisits = [makeHexVisit(Self.hexA), makeHexVisit(Self.hexB)]
        let visited = [makeStay(category: .destination, hex: Self.hexA)]
        let transit = [
            makeTransitStay(hex: Self.hexA, mode: .flight),              // shares real hex → A stays
            makeTransitStay(hex: Self.hexB, mode: nil, isAirport: true)  // airport waypoint → hides
        ]

        let result = StatsAggregator.aggregate(
            visitedStays: visited, transitStays: transit, trips: [],
            hexVisits: hexVisits, totalPings: 0, totalStays: 3,
            flightCount: 0, trackingSince: nil
        )

        #expect(result.totalHexes == 1)
    }

    @Test("hex counters count cells: a retained same-cell duplicate counts once")
    func duplicateCellRowsCountOnce() {
        func row(_ hex: String, _ firstVisited: Date, _ code: String) -> HexVisit {
            let visit = makeHexVisit(hex, firstVisited: firstVisited)
            visit.isoCountryCode = code
            return visit
        }
        func aggregate(_ hexVisits: [HexVisit]) -> StatsAggregator.Aggregates {
            StatsAggregator.aggregate(
                visitedStays: [], transitStays: [], trips: [], hexVisits: hexVisits,
                totalPings: 0, totalStays: 0, flightCount: 0, trackingSince: nil,
                now: date(2026, 6, 1))
        }
        let older = row(Self.hexA, date(2025, 3, 1), "GR")
        let other = row(Self.hexB, date(2026, 2, 1), "FR")
        let normal = aggregate([older, other])
        let duplicated = aggregate([older, row(Self.hexA, date(2026, 2, 1), "GR"), other])
        for result in [normal, duplicated] {
            #expect(result.totalHexes == 2)
            // Cell A was first visited in 2025, whichever row says so.
            #expect(result.newHexesThisYear == 1)
            #expect(result.topHexCountries.map { "\($0.code)\($0.count)" } == ["FR1", "GR1"])
        }
    }

    // MARK: - Tracking since (end-to-end through compute)

    @Test("first-ping date always comes from the store, including a same-count replacement")
    func trackingSinceReadsStore() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let t1 = date(2026, 1, 10)

        ctx.insert(LocationPing(timestamp: t1, latitude: 0, longitude: 0,
                                horizontalAccuracy: 10, h3IndexRes6: "H"))
        try ctx.save()

        let first = try StatsAggregator.compute(container: container)
        #expect(first.totalPings == 1)
        #expect(first.trackingSince == t1)

        // A photo import backfills an OLDER ping: the earlier date wins.
        let t0 = date(2025, 5, 5)
        let older = LocationPing(timestamp: t0, latitude: 0, longitude: 0,
                                 horizontalAccuracy: 10, h3IndexRes6: "H")
        ctx.insert(older)
        try ctx.save()

        let second = try StatsAggregator.compute(container: container)
        #expect(second.totalPings == 2)
        #expect(second.trackingSince == t0)

        // Deleting the first ping and recording a newer one keeps the count
        // unchanged; the date must still follow the store, not the old t0.
        ctx.delete(older)
        ctx.insert(LocationPing(timestamp: date(2026, 2, 1), latitude: 0, longitude: 0,
                                horizontalAccuracy: 10, h3IndexRes6: "H"))
        try ctx.save()

        let third = try StatsAggregator.compute(container: container)
        #expect(third.totalPings == 2)
        #expect(third.trackingSince == t1)
    }

    // MARK: - Deterministic tiebreaks

    @Test("most-visited place: equal trip counts resolve alphabetically, not by hash order")
    func mostVisitedTiebreak() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let trip1 = makeTrip(start: date(2026, 6, 7), end: date(2026, 6, 11))
        let trip2 = makeTrip(start: date(2026, 7, 8), end: date(2026, 7, 12))
        ctx.insert(trip1)
        ctx.insert(trip2)

        // Athens and Berlin each appear in BOTH trips → 2 visits apiece.
        var stays: [Stay] = []
        for trip in [trip1, trip2] {
            for place in ["Berlin", "Athens"] {
                let stay = makeStay(category: .destination, hex: "H-\(place)", metroName: place)
                ctx.insert(stay)
                stay.trip = trip
                stays.append(stay)
            }
        }

        let result = StatsAggregator.aggregate(
            visitedStays: stays, transitStays: [], trips: [trip1, trip2],
            hexVisits: [], totalPings: 0, totalStays: stays.count,
            flightCount: 0, trackingSince: nil
        )

        #expect(result.passportData.mostVisitedPlace == "Athens")
        #expect(result.passportData.mostVisitedTripCount == 2)
    }

    @Test("longest trip: equal durations resolve to the earlier start")
    func longestTripTiebreak() {
        // Both span 4 inclusive calendar days.
        let july = makeTrip(start: date(2026, 7, 17), end: date(2026, 7, 20), name: "July")
        let august = makeTrip(start: date(2026, 8, 26), end: date(2026, 8, 29), name: "August")

        let result = StatsAggregator.aggregate(
            visitedStays: [], transitStays: [], trips: [august, july],
            hexVisits: [], totalPings: 0, totalStays: 0,
            flightCount: 0, trackingSince: nil
        )

        #expect(result.passportData.longestTripName == "July")
        #expect(result.passportData.longestTripDays == 4)
        #expect(result.passportData.daysAbroad == 8)
        #expect(result.passportData.trips == 2)
    }

    @Test("last trip: identical start timestamps resolve by id, stably")
    func lastTripTiebreak() {
        let start = date(2026, 6, 1)
        let tripA = makeTrip(start: start, end: date(2026, 6, 3), name: "A")
        let tripB = makeTrip(start: start, end: date(2026, 6, 3), name: "B")
        tripA.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        tripB.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        // The larger uuidString wins the tie; input order must not matter.
        for trips in [[tripA, tripB], [tripB, tripA]] {
            let result = StatsAggregator.aggregate(
                visitedStays: [], transitStays: [], trips: trips,
                hexVisits: [], totalPings: 0, totalStays: 0,
                flightCount: 0, trackingSince: nil
            )
            #expect(result.lastTrip?.name == "B")
        }
    }

    // MARK: - Countries

    @Test("country stats: stay-seeded + trip-counted, home flagged, deterministic order")
    func countryStatsSeedingAndOrder() {
        let home = makeStay(category: .home, hex: "HG", isoCountryCode: "GR", country: "Greece")
        let dest = makeStay(category: .destination, hex: "HF", isoCountryCode: "FR", country: "France")
        let franceTrip = makeTrip(start: date(2026, 5, 10), end: date(2026, 5, 13), codes: "FR")
        // A trip whose destination stays lost their ISO code → name falls
        // back to the raw code.
        let italyTrip = makeTrip(start: date(2026, 6, 7), end: date(2026, 6, 10), codes: "IT")

        let result = StatsAggregator.aggregate(
            visitedStays: [home, dest], transitStays: [],
            trips: [franceTrip, italyTrip], hexVisits: [],
            totalPings: 0, totalStays: 2, flightCount: 0, trackingSince: nil
        )

        #expect(result.uniqueCountries == Set(["GR", "FR", "IT"]))
        let expected = [
            CountryStat(code: "FR", name: "France", tripCount: 1, isHome: false),
            CountryStat(code: "IT", name: "IT", tripCount: 1, isHome: false),
            CountryStat(code: "GR", name: "Greece", tripCount: 0, isHome: true)
        ]
        #expect(result.countryStats == expected)
    }

    @Test("country home-ness ORs across rows; destination-first order must not unflag home")
    func countryHomeFlagOrderIndependent() {
        // Pre-fix, `isHome` was stamped only on first insertion, so a
        // destination stay for GR arriving before the home stay (the fetch
        // is unsorted) left Greece flagged as not-home. Both orders must
        // now converge.
        let dest = makeStay(category: .destination, hex: "HG", isoCountryCode: "GR", country: "Greece")
        let home = makeStay(category: .home, hex: "HG2", isoCountryCode: "GR", country: "Greece")
        for stays in [[dest, home], [home, dest]] {
            let result = StatsAggregator.aggregate(
                visitedStays: stays, transitStays: [], trips: [], hexVisits: [],
                totalPings: 0, totalStays: 2, flightCount: 0, trackingSince: nil
            )
            #expect(result.countryStats.first(where: { $0.code == "GR" })?.isHome == true)
        }
    }

    // MARK: - On This Day

    @Test("a destination stay active on this date last year forms a one-year-ago group")
    func onThisDayGroupFromPastYear() {
        let now = date(2026, 7, 5)
        let stay = makeStay(
            category: .destination, hex: "H",
            start: date(2025, 7, 4), end: date(2025, 7, 6),
            metroName: "Lisbon"
        )

        let result = StatsAggregator.aggregate(
            visitedStays: [stay], transitStays: [], trips: [],
            hexVisits: [], totalPings: 0, totalStays: 1,
            flightCount: 0, trackingSince: nil, now: now
        )

        #expect(result.onThisDayGroups.count == 1)
        #expect(result.onThisDayGroups.first?.yearsAgo == 1)
        #expect(result.onThisDayGroups.first?.trips.first?.places == ["Lisbon"])
    }

    @Test("On This Day: equal start times order places by stay id, whatever the input order")
    func onThisDayEqualStartTieBreaksOnID() {
        let now = date(2026, 7, 5)
        let trip = makeTrip(start: date(2025, 7, 4), end: date(2025, 7, 6))
        // Names run against id order so an alphabetical sort would fail.
        let porto = makeStay(category: .destination, hex: "HP",
                             start: date(2025, 7, 4), end: date(2025, 7, 6), metroName: "Porto")
        porto.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let braga = makeStay(category: .destination, hex: "HB",
                             start: date(2025, 7, 4), end: date(2025, 7, 6), metroName: "Braga")
        braga.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        porto.trip = trip
        braga.trip = trip

        for stays in [[porto, braga], [braga, porto]] {
            let result = StatsAggregator.aggregate(
                visitedStays: stays, transitStays: [], trips: [trip],
                hexVisits: [], totalPings: 0, totalStays: 2,
                flightCount: 0, trackingSince: nil, now: now
            )
            #expect(result.onThisDayGroups.first?.trips.first?.places == ["Porto", "Braga"])
        }
    }

    // MARK: - Passport plumbing

    @Test("passport carries the visible hex count, flights, since-year and year metrics")
    func passportPlumbing() {
        let now = date(2026, 7, 5)
        let hexVisits = [
            makeHexVisit(Self.hexA, firstVisited: date(2026, 2, 2)),   // new this year
            makeHexVisit(Self.hexB, firstVisited: date(2025, 8, 1))
        ]
        let dest = makeStay(category: .destination, hex: Self.hexA, metroName: "Porto")
        dest.avgTemperatureC = 31
        let trip = makeTrip(start: date(2026, 1, 10), end: date(2026, 1, 12))

        let result = StatsAggregator.aggregate(
            visitedStays: [dest], transitStays: [], trips: [trip],
            hexVisits: hexVisits, totalPings: 42, totalStays: 1,
            flightCount: 3, trackingSince: date(2024, 9, 1), now: now
        )

        #expect(result.totalHexes == 2)
        #expect(result.newHexesThisYear == 1)
        #expect(result.passportData.hexes == 2)
        #expect(result.passportData.newHexesThisYear == 1)
        #expect(result.passportData.flights == 3)
        #expect(result.passportData.totalPings == 42)
        #expect(result.passportData.sinceYear == 2024)
        #expect(result.passportData.tripsThisYear == 1)
        #expect(result.passportData.cities == 1)
        #expect(result.passportData.hottestTempC == 31)
        #expect(result.passportData.hottestPlace == "Porto")
    }

    @Test("empty store aggregates to zeros without trapping")
    func emptyStore() {
        let result = StatsAggregator.aggregate(
            visitedStays: [], transitStays: [], trips: [],
            hexVisits: [], totalPings: 0, totalStays: 0,
            flightCount: 0, trackingSince: nil
        )

        #expect(result.totalHexes == 0)
        #expect(result.countryStats.isEmpty)
        #expect(result.lastTrip == nil)
        #expect(result.onThisDayGroups.isEmpty)
        #expect(result.passportData == PassportData())
    }

    // MARK: - Parity with the model-read reductions

    /// The year ledger as it was, walking each completed trip's stays.
    private func referenceYearStats(
        days: Set<Date>, completedTrips: [Trip], calendar: Calendar
    ) -> [StatsAggregator.YearStat] {
        var byYear: [Int: StatsAggregator.YearStat] = [:]
        for day in days {
            let year = TravelDays.labelCalendar.component(.year, from: day)
            byYear[year, default: StatsAggregator.YearStat(year: year)].days += 1
        }
        var codesByYear: [Int: Set<String>] = [:]
        for trip in completedTrips {
            let first = TravelDays.boundaryStays(of: trip.stays ?? []).first
            guard let label = TravelDays.label(for: trip.startDate, zone: StayTimeZone.resolve(
                first?.timeZoneIdentifier, fallback: calendar.timeZone)) else { continue }
            let year = TravelDays.labelCalendar.component(.year, from: label)
            byYear[year, default: StatsAggregator.YearStat(year: year)].trips += 1
            for code in trip.countryCodes.split(separator: ",") where !code.isEmpty {
                codesByYear[year, default: []].insert(String(code))
            }
        }
        for (year, codes) in codesByYear {
            byYear[year]?.countries = codes.count
        }
        return byYear.values.sorted { $0.year < $1.year }
    }

    @Test("value rows and shared spans reproduce the model-read Passport, year ledger, memories and countries")
    func valueRowsMatchModelReads() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let base = utc.date(from: DateComponents(year: 2025, month: 9, day: 16, hour: 9))!
        func at(_ days: Double) -> Date { base.addingTimeInterval(days * 86_400) }
        func trip(_ start: Double, _ end: Double?, codes: String, name: String) -> Trip {
            let row = makeTrip(start: at(start), end: end.map { at($0) }, name: name, codes: codes)
            context.insert(row)
            return row
        }
        @discardableResult
        func stay(
            _ category: StayCategory, _ start: Double, _ end: Double, at coordinate: (Double, Double),
            hex: String = "", metro: String? = nil, island: String? = nil, locality: String? = nil,
            iso: String? = nil, zone: String? = nil, temperature: Double? = nil,
            id: UUID? = nil, in parent: Trip? = nil
        ) -> Stay {
            let row = Stay(startTime: at(start), endTime: at(end),
                           centroidLatitude: coordinate.0, centroidLongitude: coordinate.1,
                           h3IndexRes6: hex, pingCount: 1, distanceFromHomeKm: coordinate.0 * 10,
                           pingIDs: [], timeZoneIdentifier: zone)
            row.category = category
            row.metroName = metro
            row.islandName = island
            row.locality = locality
            row.isoCountryCode = iso
            row.country = iso.map { "Country \($0)" }
            row.avgTemperatureC = temperature
            row.weatherConditionRaw = temperature.map { $0 > 20 ? "clear" : "rain" }
            if let id { row.id = id }
            context.insert(row)
            row.trip = parent
            return row
        }

        // A completed trip whose last boundary ties on the instant (the
        // smallest id wins), with a UUID twin and a transit member.
        let greece = trip(0, 4, codes: "GR,IT", name: "Greece and Italy")
        let athens = stay(.destination, 0, 1, at: (37.98, 23.72), hex: "a", metro: "Athens",
                          iso: "GR", zone: "Europe/Athens", temperature: 30, in: greece)
        stay(.destination, 0.5, 1, at: (37.99, 23.73), hex: "a", metro: "Athens",
             iso: "GR", zone: "Europe/Paris", temperature: 29, id: athens.id, in: greece)
        stay(.destination, 1.2, 2, at: (38.20133, 20.43706), hex: "n", island: "Cephalonia",
             iso: "GR", zone: "Europe/Athens", temperature: 18, in: greece)
        let flightLeg = stay(.transit, 2, 2.1, at: (41.80, 12.25), hex: "t", locality: "Fiumicino",
                             iso: "IT", in: greece)
        flightLeg.transitFromPreviousRaw = TransitMode.flight.rawValue
        stay(.destination, 2.2, 4, at: (41.90, 12.49), hex: "r", locality: "Rome",
             iso: "IT", zone: "Europe/Rome", temperature: 25, in: greece)
        stay(.destination, 3.5, 4, at: (41.80, 12.40), locality: "Ostia", iso: "IT", zone: "Asia/Tokyo",
             id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, in: greece)
        // Same hottest temperature as Athens: the id breaks the tie.
        let paris = trip(30, 33, codes: "FR", name: "Paris")
        stay(.destination, 30, 33, at: (48.85, 2.35), hex: "p", metro: "Paris",
             iso: "FR", zone: "Europe/Paris", temperature: 30, in: paris)
        let lisbon = trip(360, nil, codes: "PT", name: "Lisbon")
        stay(.destination, 360, 361, at: (38.72, -9.14), hex: "l", metro: "Lisbon",
             iso: "PT", zone: "Europe/Lisbon", temperature: 22, in: lisbon)
        let bare = trip(100, 101, codes: "", name: "No stays")
        // Tripless destination residue, home rows (one recorded by a
        // temporary home this store does not hold), a routine row and a
        // transit row outside every trip.
        stay(.destination, 200, 200.5, at: (37.97, 23.70), locality: "Athens", iso: "GR",
             zone: "Europe/Athens", temperature: 35)
        stay(.home, -5, -1, at: (37.98, 23.72), hex: "a", iso: "GR", temperature: 20)
        let leased = stay(.home, 50, 55, at: (38.72, -9.14), hex: "l", iso: "PT")
        leased.temporaryHomeID = UUID()
        stay(.routine, 40, 40.2, at: (38.00, 23.80), iso: "GR", temperature: 5)
        let groundLeg = stay(.transit, 60, 60.1, at: (40.0, 22.0), iso: "GR")
        try context.save()

        let stays = try context.fetch(FetchDescriptor<Stay>())
        let visited = stays.filter { $0.categoryRaw != StayCategory.transit.rawValue }
        let transit = [flightLeg, groundLeg]
        let trips = [greece, paris, lisbon, bare]
        let now = at(365)
        let result = StatsAggregator.aggregate(
            visitedStays: visited, transitStays: transit, trips: trips, hexVisits: [],
            totalPings: 0, totalStays: stays.count, flightCount: 1, trackingSince: at(-5),
            now: now, calendar: utc)

        // Passport: cities, durations, longest, farthest, most visited, temperatures.
        let completed = trips.filter(\.isComplete)
        let durations = completed.map { $0.durationDays ?? 0 }
        #expect(result.passportData.cities == Stay.deduplicatedCityCount(from: visited))
        #expect(result.passportData.averageTripDays
                == Double(durations.reduce(0, +)) / Double(completed.count))
        let longest = zip(completed, durations).max { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            if lhs.0.startDate != rhs.0.startDate { return lhs.0.startDate > rhs.0.startDate }
            return lhs.0.id.uuidString > rhs.0.id.uuidString
        }
        #expect(result.passportData.longestTripName == longest?.0.displayName)
        #expect(result.passportData.longestTripDays == longest?.1)
        let destinations = visited.filter { $0.categoryRaw == StayCategory.destination.rawValue }
        let farthest = YearWrappedGenerator.farthestFromHome(destinations: destinations.map {
            (YearWrappedGenerator.farthestCandidateKm(
                stamped: $0.distanceFromHomeKm, latitude: $0.centroidLatitude,
                longitude: $0.centroidLongitude, startTime: $0.startTime, realHomes: nil),
             $0.startTime, $0.id, $0.placeGroupName)
        })
        #expect(result.passportData.furthestKm == farthest?.distanceKm)
        #expect(result.passportData.furthestPlace == farthest?.name)
        var tripsByPlace: [String: Set<UUID>] = [:]
        for stay in destinations {
            guard let place = stay.placeGroupName, !place.isEmpty, let tripID = stay.trip?.id else { continue }
            tripsByPlace[place, default: []].insert(tripID)
        }
        let mostVisited = tripsByPlace.max { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count < rhs.value.count }
            return lhs.key > rhs.key
        }
        #expect(result.passportData.mostVisitedPlace == mostVisited?.key)
        #expect(result.passportData.mostVisitedTripCount == mostVisited?.value.count)
        let measured = visited.filter { $0.avgTemperatureC != nil }
        func cooler(_ lhs: Stay, _ rhs: Stay) -> Bool {
            let l = lhs.avgTemperatureC ?? 0, r = rhs.avgTemperatureC ?? 0
            if l != r { return l < r }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let hottest = measured.max(by: cooler)
        let coldest = measured.min(by: cooler)
        #expect(result.passportData.hottestTempC == hottest?.avgTemperatureC)
        #expect(result.passportData.hottestPlace == hottest?.placeGroupName)
        #expect(result.passportData.coldestTempC == coldest?.avgTemperatureC)
        #expect(result.passportData.coldestPlace == coldest?.placeGroupName)

        // Travel days and the year ledger from one span walk per trip.
        let days = StatsAggregator.travelDaySet(trips: trips, now: now, calendar: utc)
        let ledger = referenceYearStats(days: days, completedTrips: completed, calendar: utc)
        #expect(result.travelDaysTotal == days.count)
        #expect(result.yearStats == ledger)
        #expect(StatsAggregator.yearStats(days: days, completedTrips: completed, calendar: utc) == ledger)

        // On This Day from model reads, in the reducer's order.
        let snapshots = destinations.map {
            OnThisDayStay(stayID: $0.id, tripID: $0.trip?.id, place: $0.placeGroupName,
                          startTime: $0.startTime, endTime: $0.endTime,
                          weatherConditionRaw: $0.weatherConditionRaw,
                          avgTemperatureC: $0.avgTemperatureC, isoCountryCode: $0.isoCountryCode)
        }.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.stayID.uuidString < $1.stayID.uuidString
        }
        let memories = OnThisDayEngine.yearGroups(on: now, stays: snapshots, calendar: utc)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(!memories.isEmpty)
        #expect(try encoder.encode(result.onThisDayGroups) == encoder.encode(memories))

        // Countries: the two-source union and the per-country days.
        var countries = Set(visited.compactMap(\.isoCountryCode))
        for trip in completed {
            for code in trip.countryCodes.split(separator: ",") where !code.isEmpty {
                countries.insert(String(code))
            }
        }
        #expect(result.uniqueCountries == countries)
        // Home-ness reads each home row's recorder: the real Home's makes
        // Greece home; one the store does not hold is nobody's.
        #expect(result.countryStats.first { $0.code == "GR" }?.isHome == true)
        #expect(result.countryStats.first { $0.code == "PT" }?.isHome == false)
        // Civil days of trip members in each stay's own zone, counted by hand:
        // GR Sep 16-18 (Athens, its Paris-zoned twin, Cephalonia), IT Sep 18-20
        // (Rome; Ostia is Sep 20 in Tokyo), FR Oct 16-19, PT 2026 Sep 11-12.
        // The tripless Athens residue adds nothing.
        let expectedDays = ["GR": 3, "IT": 3, "FR": 4, "PT": 2]
        #expect(StatsAggregator.daysByCountry(destinationStays: destinations, calendar: utc) == expectedDays)
        #expect(Set(result.countryStats.map(\.code)) == Set(expectedDays.keys))
        for stat in result.countryStats {
            #expect(stat.days == expectedDays[stat.code])
        }
    }

    @Test("the reducer checks cancellation before copying each stay")
    func rowCopiesFollowCheckpoints() {
        let stays = (0..<3).map { _ in makeStay(category: .destination, isoCountryCode: "GR") }
        var calls = 0
        let result = StatsAggregator.aggregate(
            visitedStays: stays, transitStays: [], trips: [], hexVisits: [],
            totalPings: 0, totalStays: stays.count, flightCount: 0, trackingSince: nil
        ) {
            calls += 1
            // A stay copied right after its own checkpoint carries that
            // call's code; one copied before any checkpoint keeps "GR".
            for stay in stays { stay.isoCountryCode = "C\(calls)" }
        }
        #expect(result.uniqueCountries.count == stays.count)
        #expect(!result.uniqueCountries.contains("GR"))
    }

    @Test("the country-days seam reads trip and zone from any stay it is given")
    func countryDaysSeamReadsEveryCategory() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = utc.date(from: DateComponents(year: 2025, month: 5, day: 1, hour: 20))!
        let trip = makeTrip(start: start, end: start.addingTimeInterval(86_400))
        // Tokyo: May 2 05:00 to 19:00, one civil day; UTC would give two.
        let stay = makeStay(category: .home, start: start, end: start.addingTimeInterval(14 * 3_600),
                            isoCountryCode: "GR")
        stay.timeZoneIdentifier = "Asia/Tokyo"
        stay.trip = trip
        #expect(StatsAggregator.daysByCountry(destinationStays: [stay], calendar: utc) == ["GR": 1])
        stay.trip = nil
        #expect(StatsAggregator.daysByCountry(destinationStays: [stay], calendar: utc).isEmpty)
    }
}
