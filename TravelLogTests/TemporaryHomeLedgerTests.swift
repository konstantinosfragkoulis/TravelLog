//
//  TemporaryHomeLedgerTests.swift
//  TravelLogTests
//
//  Pins the day ledger behind "Days Away" once a temporary home exists:
//  which dates count as staying at it, which as away, and that the trip
//  dates passed in are never changed. Expected date sets are written out by
//  hand. The pure tests need no store; the adapter tests seed one semester
//  (`SemesterFixture`) and compare the projected adapter with the reducer
//  over full rows.
//

import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

// MARK: - Shared fixture

/// One semester in Brussels with Athens as the real Home, all in UTC:
/// an earlier trip to Rome, a stay at the base, an Ieper weekend, a
/// visit-backed single-ping weekend home, and a final return.
/// The temporary home's dates cover the residence.
@MainActor
enum SemesterFixture {
    static let athens = (lat: 37.9838, lon: 23.7275)
    static let brussels = (lat: 50.8275, lon: 4.2886)
    static let ieper = (lat: 50.8515, lon: 2.8861)
    static let rome = (lat: 41.8934, lon: 12.4346)

    static let utc = TimeZone(secondsFromGMT: 0)!

    /// An instant on a UTC civil date.
    static func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        TravelDays.labelCalendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// The label keys of the given days of one month.
    static func days(_ year: Int, _ month: Int, _ range: ClosedRange<Int>) -> Set<Date> {
        Set(range.map { at(year, month, $0, 0) })
    }

    /// A moment after everything in the fixture, still inside 2025.
    static let now = at(2025, 12, 31, 18)

    /// Rome 18 to 21 January and Ieper 30 July to 1 August: 7 dates.
    static let travelling = days(2025, 1, 18...21).union(days(2025, 7, 30...31).union(days(2025, 8, 1...1)))
    /// 22 July to 22 August and 26 August to 3 November, minus the
    /// Ieper dates: 99 dates. The weekend in Athens and everything
    /// from the final return on are neither staying nor away.
    static let staying = days(2025, 7, 22...29).union(days(2025, 8, 2...19))
        .union(days(2025, 8, 20...22)).union(days(2025, 8, 26...31).union(days(2025, 9, 1...19)))
        .union(days(2025, 9, 20...30).union(days(2025, 10, 1...19))).union(days(2025, 10, 20...31).union(days(2025, 11, 1...3)))
    /// 106 dates.
    static let away = travelling.union(staying)

    /// `owner` is the temporary home its home writer recorded, as the
    /// classifier stamps a stay it makes home inside a temporary home's dates.
    @discardableResult
    static func stay(
        _ context: ModelContext, _ category: StayCategory,
        at place: (lat: Double, lon: Double), iso: String,
        from start: Date, to end: Date, pings: Int = 4, trip: Trip? = nil, by owner: UUID? = nil
    ) -> Stay {
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: place.lat, centroidLongitude: place.lon,
            h3IndexRes6: "", pingCount: pings, distanceFromHomeKm: 0, pingIDs: [],
            timeZoneIdentifier: "UTC")
        stay.category = category
        stay.isoCountryCode = iso
        stay.temporaryHomeID = owner
        context.insert(stay)
        if let trip { stay.trip = trip }
        return stay
    }

    static func trip(_ context: ModelContext, from start: Date, to end: Date, codes: String) -> Trip {
        let trip = Trip(startDate: start)
        trip.endDate = end
        trip.isComplete = true
        trip.countryCodes = codes
        context.insert(trip)
        return trip
    }

    /// Seeds the semester and returns the temporary home's id.
    @discardableResult
    static func seed(_ container: ModelContainer) throws -> UUID {
        let context = ModelContext(container)
        let home = Home(label: "Home", latitude: athens.lat, longitude: athens.lon,
                        radiusKm: 25, startedAt: at(2020, 1, 1))
        home.isoCountryCode = "GR"
        context.insert(home)
        let base = TemporaryHome(
            label: "Erasmus", latitude: brussels.lat, longitude: brussels.lon,
            startedAt: at(2025, 7, 21, 0), endedAt: at(2025, 11, 8, 23))
        base.isoCountryCode = "BE"
        context.insert(base)

        let romeTrip = trip(context, from: at(2025, 1, 18, 9), to: at(2025, 1, 21, 17), codes: "IT")
        stay(context, .destination, at: rome, iso: "IT",
             from: at(2025, 1, 18, 9), to: at(2025, 1, 21, 17), trip: romeTrip)

        stay(context, .home, at: athens, iso: "GR", from: at(2025, 7, 9, 10), to: at(2025, 7, 20, 20))
        stay(context, .home, at: brussels, iso: "BE", from: at(2025, 7, 22, 10), to: at(2025, 7, 29, 18), by: base.id)
        let ieperTrip = trip(context, from: at(2025, 7, 30, 9), to: at(2025, 8, 1, 17), codes: "BE")
        stay(context, .destination, at: ieper, iso: "BE",
             from: at(2025, 7, 30, 9), to: at(2025, 8, 1, 17), trip: ieperTrip)
        stay(context, .home, at: brussels, iso: "BE", from: at(2025, 8, 1, 21), to: at(2025, 8, 22, 8), by: base.id)
        // One live fix at home: a boundary only because a visit backs it.
        let weekendHome = stay(context, .home, at: athens, iso: "GR",
                               from: at(2025, 8, 23, 12), to: at(2025, 8, 25, 12), pings: 1)
        context.insert(Visit(
            arrivalDate: at(2025, 8, 23, 12), departureDate: at(2025, 8, 25, 12),
            latitude: athens.lat, longitude: athens.lon, stayID: weekendHome.id))
        stay(context, .home, at: brussels, iso: "BE", from: at(2025, 8, 26, 20), to: at(2025, 11, 3, 8), by: base.id)
        stay(context, .home, at: athens, iso: "GR", from: at(2025, 11, 4, 12), to: at(2025, 11, 19, 12))
        try context.save()
        return base.id
    }
}

// MARK: - Pure core

@MainActor
@Suite("Temporary home ledger")
struct TemporaryHomeLedgerTests {

    private typealias Fixture = SemesterFixture
    private let utc = SemesterFixture.utc
    private let athens = SemesterFixture.athens
    private let brussels = SemesterFixture.brussels
    private let ieper = SemesterFixture.ieper
    private let dendermonde = (lat: 51.0289, lon: 4.1006)
    private let losAngeles = (lat: 34.0522, lon: -118.2437)

    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        Fixture.at(year, month, day, hour)
    }

    private func days(_ year: Int, _ month: Int, _ range: ClosedRange<Int>) -> Set<Date> {
        Fixture.days(year, month, range)
    }

    private func realHome() -> HomeAnchor {
        HomeAnchor(
            id: UUID(), kind: .home, label: "", latitude: athens.lat, longitude: athens.lon,
            radiusKm: 25, locality: "Athens", isoCountryCode: "GR",
            startedAt: at(2020, 1, 1), endedAt: nil)
    }

    private func temporaryHome(
        at place: (lat: Double, lon: Double), from start: Date, to end: Date? = nil
    ) -> HomeAnchor {
        HomeAnchor(
            id: UUID(), kind: .temporary, label: "", latitude: place.lat, longitude: place.lon,
            radiusKm: 25, locality: nil, isoCountryCode: nil, startedAt: start, endedAt: end)
    }

    /// `owner` is the temporary home the stay records (`Stay.temporaryHomeID`).
    private func stay(
        _ category: StayCategory, at place: (lat: Double, lon: Double),
        from start: Date, to end: Date, pings: Int = 4, zone: String? = "UTC", owner: HomeAnchor? = nil
    ) -> TemporaryHomeLedger.StaySample {
        TemporaryHomeLedger.StaySample(
            id: UUID(), start: start, end: end, latitude: place.lat, longitude: place.lon,
            categoryRaw: category.rawValue, sourceRaw: DataSource.liveSLC.rawValue,
            pingCount: pings, timeZoneIdentifier: zone, temporaryHomeID: owner?.id)
    }

    private func ledger(
        travelling: Set<Date> = [], anchors: [HomeAnchor],
        stays: [TemporaryHomeLedger.StaySample], visitBacked: Set<UUID> = [], now: Date
    ) -> TemporaryHomeLedger.Result {
        TemporaryHomeLedger.result(
            travelling: travelling, anchors: anchors, stays: stays,
            visitBackedStayIDs: visitBacked, now: now, fallbackZone: utc)
    }

    /// What the ledger returns when no temporary home contributes.
    private func nothing(travelling: Set<Date> = []) -> TemporaryHomeLedger.Result {
        TemporaryHomeLedger.Result(
            travelling: travelling, staying: [], away: travelling,
            stayingByHome: [:], spansByHome: [:])
    }

    @Test("a side trip inside a run at the base: away is one continuous range, staying leaves the trip's dates out, travelling is unchanged")
    func sideTripInsideARun() {
        let base = temporaryHome(at: brussels, from: at(2025, 7, 21, 0), to: at(2025, 9, 19, 23))
        let stays = [
            stay(.home, at: brussels, from: at(2025, 7, 22, 10), to: at(2025, 7, 29, 18), owner: base),
            stay(.destination, at: ieper, from: at(2025, 7, 30, 9), to: at(2025, 8, 1, 17)),
            stay(.home, at: brussels, from: at(2025, 8, 1, 21), to: at(2025, 8, 9, 8), owner: base),
        ]
        let trip = days(2025, 7, 30...31).union(days(2025, 8, 1...1))
        // Input order must not matter.
        let result = ledger(travelling: trip, anchors: [realHome(), base],
                            stays: Array(stays.reversed()), now: at(2025, 10, 20))

        #expect(result.travelling == trip)
        #expect(result.away == days(2025, 7, 22...31).union(days(2025, 8, 1...9)))
        #expect(result.staying == days(2025, 7, 22...29).union(days(2025, 8, 2...9)))
        #expect(result.stayingByHome == [base.id: result.staying])
        #expect(result.spansByHome == [base.id: [TemporaryHomeLedger.Span(
            start: at(2025, 7, 22, 10), end: at(2025, 8, 9, 8), firstZone: "UTC", lastZone: "UTC")]])
    }

    @Test("a qualifying visit to the real home splits the run, and the days at home are neither staying nor away")
    func visitHomeSplitsTheRun() {
        let base = temporaryHome(at: brussels, from: at(2025, 7, 21, 0), to: at(2025, 9, 19, 23))
        let stays = [
            stay(.home, at: brussels, from: at(2025, 7, 22, 10), to: at(2025, 7, 29, 18), owner: base),
            stay(.home, at: athens, from: at(2025, 7, 31, 12), to: at(2025, 8, 2, 12)),
            stay(.home, at: brussels, from: at(2025, 8, 3, 20), to: at(2025, 8, 9, 8), owner: base),
        ]
        let result = ledger(anchors: [realHome(), base], stays: stays, now: at(2025, 10, 20))

        let expected = days(2025, 7, 22...29).union(days(2025, 8, 3...9))
        #expect(result.staying == expected)
        #expect(result.away == expected)
        #expect(result.away.isDisjoint(with: days(2025, 7, 30...31).union(days(2025, 8, 1...2))))
        #expect(result.spansByHome[base.id] == [
            TemporaryHomeLedger.Span(start: at(2025, 7, 22, 10), end: at(2025, 7, 29, 18),
                                     firstZone: "UTC", lastZone: "UTC"),
            TemporaryHomeLedger.Span(start: at(2025, 8, 3, 20), end: at(2025, 8, 9, 8),
                                     firstZone: "UTC", lastZone: "UTC"),
        ])
    }

    @Test("a single live fix at the real home does not split the run, and the same stay backed by a visit does")
    func singlePingHomeNeedsAVisitToSplit() {
        let base = temporaryHome(at: brussels, from: at(2025, 7, 21, 0), to: at(2025, 9, 19, 23))
        let weekendHome = stay(.home, at: athens, from: at(2025, 7, 31, 12), to: at(2025, 8, 2, 12), pings: 1)
        let stays = [
            stay(.home, at: brussels, from: at(2025, 7, 22, 10), to: at(2025, 7, 29, 18), owner: base),
            weekendHome,
            stay(.home, at: brussels, from: at(2025, 8, 3, 20), to: at(2025, 8, 9, 8), owner: base),
        ]
        let anchors = [realHome(), base]

        let unbacked = ledger(anchors: anchors, stays: stays, now: at(2025, 10, 20))
        #expect(unbacked.away == days(2025, 7, 22...31).union(days(2025, 8, 1...9)))
        #expect(unbacked.spansByHome[base.id]?.count == 1)

        let backed = ledger(anchors: anchors, stays: stays, visitBacked: [weekendHome.id],
                            now: at(2025, 10, 20))
        #expect(backed.away == days(2025, 7, 22...29).union(days(2025, 8, 3...9)))
        #expect(backed.spansByHome[base.id]?.count == 2)
    }

    @Test("after the final return home with no later stay at the base, the span ends at the last stay before it and does not grow as time passes")
    func finalReturnDoesNotGrowWithNow() {
        // Open-ended, so the temporary home is still active on both dates.
        let base = temporaryHome(at: brussels, from: at(2025, 7, 21, 0))
        let stays = [
            stay(.home, at: brussels, from: at(2025, 7, 22, 10), to: at(2025, 8, 9, 8), owner: base),
            stay(.home, at: athens, from: at(2025, 8, 10, 10), to: at(2025, 8, 14, 10)),
        ]
        let anchors = [realHome(), base]

        let soon = ledger(anchors: anchors, stays: stays, now: at(2025, 9, 3))
        let later = ledger(anchors: anchors, stays: stays, now: at(2025, 10, 4))
        #expect(soon.away == days(2025, 7, 22...31).union(days(2025, 8, 1...9)))
        #expect(later == soon)
        #expect(soon.spansByHome[base.id]?.last?.end == at(2025, 8, 9, 8))
    }

    @Test("with the latest stay at the base, an active temporary home counts through now, and one with an end in the past stops at that end")
    func openTailRunsToNowOrToTheEnd() {
        func latest(at owner: HomeAnchor) -> TemporaryHomeLedger.StaySample {
            stay(.home, at: brussels, from: at(2025, 7, 22, 10), to: at(2025, 8, 9, 18), owner: owner)
        }
        let now = at(2025, 8, 14)

        let active = temporaryHome(at: brussels, from: at(2025, 7, 21, 0))
        let open = ledger(anchors: [realHome(), active], stays: [latest(at: active)], now: now)
        #expect(open.away == days(2025, 7, 22...31).union(days(2025, 8, 1...14)))
        #expect(open.spansByHome[active.id]?.last?.end == now)

        // An end date still ahead keeps the temporary home active today.
        let endsLater = temporaryHome(at: brussels, from: at(2025, 7, 21, 0), to: at(2025, 8, 17, 23))
        #expect(ledger(anchors: [realHome(), endsLater], stays: [latest(at: endsLater)], now: now).away
                == days(2025, 7, 22...31).union(days(2025, 8, 1...14)))

        let ended = temporaryHome(at: brussels, from: at(2025, 7, 21, 0), to: at(2025, 8, 4, 23))
        let closed = ledger(anchors: [realHome(), ended], stays: [latest(at: ended)], now: now)
        #expect(closed.away == days(2025, 7, 22...31).union(days(2025, 8, 1...4)))
        #expect(closed.spansByHome[ended.id]?.last?.end == at(2025, 8, 4, 23))
    }

    @Test("a declaration with no stay at it counts no days, as after Delete All Data")
    func declarationWithoutEvidenceYieldsNothing() {
        let base = temporaryHome(at: brussels, from: at(2025, 7, 21, 0))
        let trip = days(2025, 7, 30...31).union(days(2025, 8, 1...1))
        let anchors = [realHome(), base]

        #expect(ledger(travelling: trip, anchors: anchors, stays: [], now: at(2025, 10, 20))
                == nothing(travelling: trip))
        // Stays inside the dates, none of them a home stay at the base.
        let elsewhere = [
            stay(.destination, at: ieper, from: at(2025, 7, 30, 9), to: at(2025, 8, 1, 17)),
            stay(.unclassified, at: brussels, from: at(2025, 8, 2, 9), to: at(2025, 8, 3, 9)),
        ]
        #expect(ledger(travelling: trip, anchors: anchors, stays: elsewhere, now: at(2025, 10, 20))
                == nothing(travelling: trip))
    }

    @Test("a start date in the future counts nothing, and after it nothing counts until a stay at the base exists inside the dates")
    func futureStartNeedsStaysInsideTheDates() {
        let base = temporaryHome(at: brussels, from: at(2025, 8, 20, 0))
        let anchors = [realHome(), base]
        // Already in Brussels before the declared start.
        let early = stay(.destination, at: brussels, from: at(2025, 8, 9, 10), to: at(2025, 8, 17, 18))

        #expect(ledger(anchors: anchors, stays: [early], now: at(2025, 8, 18)) == nothing())
        #expect(ledger(anchors: anchors, stays: [early], now: at(2025, 8, 22)) == nothing())

        let first = stay(.home, at: brussels, from: at(2025, 8, 23, 9), to: at(2025, 8, 24, 18), owner: base)
        #expect(ledger(anchors: anchors, stays: [early, first], now: at(2025, 8, 29)).away
                == days(2025, 8, 23...29))
    }

    @Test("two temporary homes with overlapping dates count every date once and give each date to one of them; the second one's stays end the first one's residence")
    func overlappingTemporaryHomes() {
        let first = temporaryHome(at: brussels, from: at(2025, 7, 21, 0), to: at(2025, 8, 19, 23))
        let second = temporaryHome(at: dendermonde, from: at(2025, 7, 30, 0), to: at(2025, 9, 8, 23))
        let stays = [
            stay(.home, at: brussels, from: at(2025, 7, 22, 10), to: at(2025, 8, 1, 18), owner: first),
            stay(.home, at: dendermonde, from: at(2025, 8, 2, 9), to: at(2025, 8, 14, 18), owner: second),
            stay(.home, at: dendermonde, from: at(2025, 8, 21, 9), to: at(2025, 8, 29, 18), owner: second),
        ]
        // The later-started home is listed first: assignment order comes from the dates.
        let result = ledger(anchors: [second, realHome(), first], stays: stays, now: at(2025, 10, 20))

        // Brussels' run ends where the first Dendermonde stay begins (a home
        // stay at another temporary home is a barrier, so Dendermonde's days are
        // no longer Brussels residence); Dendermonde's covers 2 to 29 August.
        let all = days(2025, 7, 22...31).union(days(2025, 8, 1...19)).union(days(2025, 8, 20...29))
        #expect(result.staying == all)
        #expect(result.away == all)
        #expect(result.spansByHome[first.id] == [TemporaryHomeLedger.Span(
            start: at(2025, 7, 22, 10), end: at(2025, 8, 1, 18), firstZone: "UTC", lastZone: "UTC")])
        #expect(result.stayingByHome == [
            first.id: days(2025, 7, 22...31).union(days(2025, 8, 1...1)),
            second.id: days(2025, 8, 2...19).union(days(2025, 8, 20...29)),
        ])
        #expect(result.stayingByHome.values.reduce(0) { $0 + $1.count } == result.staying.count)
    }

    @Test("a span across New Year puts each date in its own year")
    func newYearBucketsByLabelYear() {
        let base = temporaryHome(at: brussels, from: at(2025, 12, 20, 0), to: at(2026, 1, 31, 23))
        let result = ledger(
            anchors: [realHome(), base],
            stays: [stay(.home, at: brussels, from: at(2025, 12, 28, 10), to: at(2026, 1, 3, 18), owner: base)],
            now: at(2026, 3, 1))

        #expect(result.away == days(2025, 12, 28...31).union(days(2026, 1, 1...3)))
        #expect(TravelDays.count(result.away, inYear: 2025) == 4)
        #expect(TravelDays.count(result.away, inYear: 2026) == 3)
    }

    @Test("a boundary west of UTC is dated by the civil date of its own zone")
    func westOfUTCUsesTheStayZone() {
        let base = temporaryHome(at: losAngeles, from: at(2025, 1, 9, 0), to: at(2025, 2, 17, 23))
        // 06:00 UTC on 18 January is 22:00 on 17 January in Los Angeles;
        // 07:00 UTC on 19 January is 23:00 on 18 January.
        let result = ledger(
            anchors: [realHome(), base],
            stays: [stay(.home, at: losAngeles, from: at(2025, 1, 18, 6), to: at(2025, 1, 19, 7),
                         zone: "America/Los_Angeles", owner: base)],
            now: at(2025, 3, 4))

        #expect(result.away == days(2025, 1, 17...17).union(days(2025, 1, 18...18)))
    }

    @Test("the stay that ends last supplies the zone of the last day, not the stay that started last")
    func latestEndSuppliesTheLastZone() {
        let base = temporaryHome(at: brussels, from: at(2025, 4, 8, 0), to: at(2025, 5, 19, 23))
        let stays = [
            stay(.home, at: brussels, from: at(2025, 4, 20, 8), to: at(2025, 4, 20, 9), zone: "UTC", owner: base),
            // Ends last: 12:00 UTC on 24 April is already 25 April on Kiritimati.
            stay(.home, at: brussels, from: at(2025, 4, 20, 10), to: at(2025, 4, 24, 12),
                 zone: "Pacific/Kiritimati", owner: base),
            // Starts last, where that instant would still be 24 April.
            stay(.home, at: brussels, from: at(2025, 4, 21, 10), to: at(2025, 4, 22, 10),
                 zone: "Pacific/Pago_Pago", owner: base),
        ]
        let result = ledger(anchors: [realHome(), base], stays: stays, now: at(2025, 6, 20))

        #expect(result.away == days(2025, 4, 20...25))
        #expect(result.spansByHome[base.id] == [TemporaryHomeLedger.Span(
            start: at(2025, 4, 20, 8), end: at(2025, 4, 24, 12),
            firstZone: "UTC", lastZone: "Pacific/Kiritimati")])
    }

    @Test("two rows of one stay (same id, start and end) that carry different zones give the same days whichever comes first")
    func sameIDStayTwinsAreOrderIndependent() {
        let base = temporaryHome(at: losAngeles, from: at(2024, 12, 20, 0), to: at(2025, 1, 31, 23))
        let id = UUID()
        func twin(zone: String) -> TemporaryHomeLedger.StaySample {
            TemporaryHomeLedger.StaySample(
                id: id, start: at(2025, 1, 1, 6), end: at(2025, 1, 2, 7),
                latitude: losAngeles.lat, longitude: losAngeles.lon,
                categoryRaw: StayCategory.home.rawValue, sourceRaw: DataSource.liveSLC.rawValue,
                pingCount: 4, timeZoneIdentifier: zone, temporaryHomeID: base.id)
        }
        let twins = [twin(zone: "UTC"), twin(zone: "America/Los_Angeles")]
        let anchors = [realHome(), base]

        let forward = ledger(anchors: anchors, stays: twins, now: at(2025, 3, 1))
        let reversed = ledger(anchors: anchors, stays: Array(twins.reversed()), now: at(2025, 3, 1))
        #expect(forward == reversed)
        // The smaller zone identifier supplies both boundaries. 06:00 UTC on
        // 1 January is still 31 December in Los Angeles, and 07:00 UTC on
        // 2 January is 23:00 on 1 January there.
        #expect(forward.away == days(2024, 12, 31...31).union(days(2025, 1, 1...1)))
        #expect(forward.spansByHome[base.id] == [TemporaryHomeLedger.Span(
            start: at(2025, 1, 1, 6), end: at(2025, 1, 2, 7),
            firstZone: "America/Los_Angeles", lastZone: "America/Los_Angeles")])
    }

    @Test("with no temporary home, days away are exactly the trip dates")
    func noTemporaryHomeReturnsTravelling() {
        let trip = days(2025, 7, 30...31).union(days(2025, 8, 1...1))
        let stays = [
            stay(.home, at: athens, from: at(2025, 7, 22, 10), to: at(2025, 7, 29, 18)),
            stay(.destination, at: ieper, from: at(2025, 7, 30, 9), to: at(2025, 8, 1, 17)),
        ]
        #expect(ledger(travelling: trip, anchors: [realHome()], stays: stays, now: at(2025, 10, 20))
                == nothing(travelling: trip))
        #expect(ledger(travelling: trip, anchors: [], stays: stays, now: at(2025, 10, 20))
                == nothing(travelling: trip))
    }

    // MARK: - Adapters

    @Test("the projected adapter and the reducer over full rows return the same result on one seeded store")
    func projectedMatchesMaterialized() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let baseID = try Fixture.seed(container)
        let context = ModelContext(container)
        // Heavy columns the projection leaves out must not change a value.
        for row in try context.fetch(FetchDescriptor<Stay>()) {
            row.weatherData = Data(repeating: 7, count: 16_384)
            row.pingIDsString = String(repeating: "payload,", count: 200)
        }
        try context.save()

        let reader = ModelContext(container)
        let trips = try reader.fetch(FetchDescriptor<Trip>())
        let anchors = try HomeAnchors.fetch(in: reader)
        let stays = try reader.fetch(FetchDescriptor<Stay>())
        let visits = try reader.fetch(FetchDescriptor<Visit>())
        let materialized = TemporaryHomeLedger.result(
            travelling: TravelDays.labels(trips: trips, now: Fixture.now, fallbackZone: utc),
            anchors: anchors,
            stays: stays.map { TemporaryHomeLedger.StaySample($0) },
            visitBackedStayIDs: Set(visits.compactMap(\.stayID)),
            now: Fixture.now, fallbackZone: utc)
        let projectedTravelling = try TravelDays.labels(
            container: container, now: Fixture.now, fallbackZone: utc)
        let projected = try TemporaryHomeLedger.result(
            travelling: projectedTravelling, container: container, now: Fixture.now,
            fallbackZone: utc, checkCancellation: {})

        #expect(projected == materialized)
        #expect(projected.travelling == Fixture.travelling)
        #expect(projected.staying == Fixture.staying)
        #expect(projected.away == Fixture.away)
        #expect(projected.away.count == 106)
        #expect(projected.stayingByHome == [baseID: Fixture.staying])
        // The visit-backed weekend home and the final return each end a run.
        #expect(projected.spansByHome[baseID] == [
            TemporaryHomeLedger.Span(start: Fixture.at(2025, 7, 22, 10), end: Fixture.at(2025, 8, 22, 8),
                                     firstZone: "UTC", lastZone: "UTC"),
            TemporaryHomeLedger.Span(start: Fixture.at(2025, 8, 26, 20), end: Fixture.at(2025, 11, 3, 8),
                                     firstZone: "UTC", lastZone: "UTC"),
        ])
    }

    @Test("same-id twin rows of one temporary home count its days once")
    func twinRowsCountOnce() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let baseID = try Fixture.seed(container)
        let context = ModelContext(container)
        let twin = TemporaryHome(
            label: "Erasmus", latitude: brussels.lat, longitude: brussels.lon,
            startedAt: at(2025, 7, 21, 0), endedAt: at(2025, 11, 8, 23))
        twin.id = baseID
        context.insert(twin)
        try context.save()

        let result = try TemporaryHomeLedger.result(
            travelling: Fixture.travelling, container: container, now: Fixture.now,
            fallbackZone: utc, checkCancellation: {})
        #expect(result.away == Fixture.away)
        #expect(result.stayingByHome == [baseID: Fixture.staying])
    }

    #if DEBUG
    private func recordingReads() -> (
        log: OSAllocatedUnfairLock<[TemporaryHomeLedger.Read]>,
        hook: @Sendable (TemporaryHomeLedger.Read) throws -> Void
    ) {
        let log = OSAllocatedUnfairLock(initialState: [TemporaryHomeLedger.Read]())
        return (log, { read in log.withLock { $0.append(read) } })
    }

    @Test("with no temporary home the projected adapter reads the temporary-home rows and nothing else, and returns the trip dates")
    func noTemporaryHomeReadsOnlyTemporaryHomes() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let home = Home(label: "Home", latitude: athens.lat, longitude: athens.lon,
                        radiusKm: 25, startedAt: at(2020, 1, 1))
        context.insert(home)
        let homeStay = Fixture.stay(context, .home, at: athens, iso: "GR",
                                    from: at(2025, 7, 22, 10), to: at(2025, 7, 29, 18), pings: 1)
        context.insert(Visit(arrivalDate: homeStay.startTime, stayID: homeStay.id))
        try context.save()

        let trip = days(2025, 7, 30...31).union(days(2025, 8, 1...1))
        let (log, hook) = recordingReads()
        let result = try TemporaryHomeLedger.$readFailureForTesting.withValue(hook) {
            try TemporaryHomeLedger.result(
                travelling: trip, container: container, now: at(2025, 10, 20),
                fallbackZone: utc, checkCancellation: {})
        }
        #expect(log.withLock { $0 } == [.temporaryHomes])
        #expect(result == nothing(travelling: trip))
    }

    @Test("with a temporary home the projected adapter makes each of its reads once")
    func temporaryHomeReadsEachInputOnce() throws {
        let container = try TestSupport.makeInMemoryContainer()
        try Fixture.seed(container)
        let (log, hook) = recordingReads()
        _ = try TemporaryHomeLedger.$readFailureForTesting.withValue(hook) {
            try TemporaryHomeLedger.result(
                travelling: [], container: container, now: Fixture.now,
                fallbackZone: utc, checkCancellation: {})
        }
        #expect(log.withLock { $0 } == TemporaryHomeLedger.Read.allCases)
    }

    @Test("a failed read throws instead of returning trip days alone",
          arguments: TemporaryHomeLedger.Read.allCases)
    func failedReadThrows(read failing: TemporaryHomeLedger.Read) throws {
        let container = try TestSupport.makeInMemoryContainer()
        try Fixture.seed(container)
        let hook: @Sendable (TemporaryHomeLedger.Read) throws -> Void = { read in
            if read == failing { throw CocoaError(.fileReadUnknown) }
        }
        #expect(throws: CocoaError.self) {
            try TemporaryHomeLedger.$readFailureForTesting.withValue(hook) {
                try TemporaryHomeLedger.result(
                    travelling: Fixture.travelling, container: container, now: Fixture.now,
                    fallbackZone: utc, checkCancellation: {})
            }
        }
    }
    #endif

    @Test("cancellation interrupts the projected adapter")
    func projectedAdapterCancellation() throws {
        let container = try TestSupport.makeInMemoryContainer()
        try Fixture.seed(container)
        var calls = 0
        #expect(throws: CancellationError.self) {
            try TemporaryHomeLedger.result(
                travelling: [], container: container, now: Fixture.now, fallbackZone: utc
            ) {
                calls += 1
                if calls == 6 { throw CancellationError() }
            }
        }
        #expect(calls == 6)
    }
}

extension TemporaryHomeLedgerTests {
    @Test("two rows of one stay that differ in category, a home copy at the real home and a destination copy, give the same days whichever comes first")
    func mixedCategoryStayTwinsAreOrderIndependent() {
        let base = temporaryHome(at: brussels, from: at(2025, 7, 21, 0), to: at(2025, 9, 19, 23))
        let evidence = stay(.home, at: brussels, from: at(2025, 7, 22, 10), to: at(2025, 7, 29, 18), owner: base)
        let id = UUID()
        func twin(_ category: StayCategory) -> TemporaryHomeLedger.StaySample {
            TemporaryHomeLedger.StaySample(
                id: id, start: at(2025, 7, 31, 12), end: at(2025, 8, 2, 12),
                latitude: athens.lat, longitude: athens.lon,
                categoryRaw: category.rawValue, sourceRaw: DataSource.liveSLC.rawValue,
                pingCount: 4, timeZoneIdentifier: "UTC")
        }
        let anchors = [realHome(), base]
        let trip = days(2025, 7, 31...31).union(days(2025, 8, 1...2))
        let forward = ledger(travelling: trip, anchors: anchors,
                             stays: [evidence, twin(.destination), twin(.home)], now: at(2025, 10, 20))
        let reversed = ledger(travelling: trip, anchors: anchors,
                              stays: [evidence, twin(.home), twin(.destination)], now: at(2025, 10, 20))
        #expect(forward == reversed)
    }
}

// MARK: - Recorded ownership and where residence resumes

extension TemporaryHomeLedgerTests {

    private var vienna: (lat: Double, lon: Double) { (48.2021, 16.3263) }
    private var rome: (lat: Double, lon: Double) { (41.8934, 12.4346) }

    private func span(_ start: Date, _ end: Date) -> TemporaryHomeLedger.Span {
        TemporaryHomeLedger.Span(start: start, end: end, firstZone: "UTC", lastZone: "UTC")
    }

    @Test("Brussels, then Vienna, then a Rome trip, then Brussels again: the second Brussels run starts at the flight straight back there, not in Rome")
    func residenceResumesAtTheFirstOwnStayAfterABarrier() {
        let first = temporaryHome(at: brussels, from: at(2025, 7, 21, 0))
        let second = temporaryHome(at: vienna, from: at(2025, 9, 19, 0))
        let zaventem = (lat: 50.9010, lon: 4.4844)
        let stays = [
            stay(.home, at: brussels, from: at(2025, 7, 22, 10), to: at(2025, 9, 19, 8), owner: first),
            stay(.home, at: vienna, from: at(2025, 9, 19, 20), to: at(2025, 10, 9, 8), owner: second),
            stay(.destination, at: rome, from: at(2025, 10, 10, 9), to: at(2025, 10, 12, 17)),
            // Rome to Brussels a day later: the leg that leads straight to the base.
            stay(.transit, at: zaventem, from: at(2025, 10, 13, 15), to: at(2025, 10, 13, 17)),
            stay(.home, at: brussels, from: at(2025, 10, 13, 20), to: at(2025, 10, 29, 8), owner: first),
        ]
        let romeDays = days(2025, 10, 10...12)
        let now = at(2025, 10, 29, 18)
        let result = ledger(travelling: romeDays, anchors: [realHome(), first, second], stays: stays, now: now)

        #expect(result.spansByHome[first.id] == [
            span(at(2025, 7, 22, 10), at(2025, 9, 19, 8)),
            span(at(2025, 10, 13, 15), now),
        ])
        // Vienna's run ends at the stay back in Brussels; the Rome days stay trip days.
        #expect(result.spansByHome[second.id] == [span(at(2025, 9, 19, 20), at(2025, 10, 13, 17))])
        #expect(result.away == days(2025, 7, 22...31).union(days(2025, 8, 1...19)).union(days(2025, 8, 20...31).union(days(2025, 9, 1...19)))
                .union(days(2025, 9, 20...30).union(days(2025, 10, 1...19))).union(days(2025, 10, 20...29)))
        #expect(result.travelling == romeDays)
    }

    @Test("a home stay at the temporary home's centre that records no temporary home is the real Home's: it ends the run and is no evidence")
    func unrecordedHomeStayAtTheBaseIsTheRealHomes() {
        let base = temporaryHome(at: brussels, from: at(2025, 7, 21, 0), to: at(2025, 9, 19, 23))
        let realAtBase = stay(.home, at: brussels, from: at(2025, 7, 31, 12), to: at(2025, 8, 2, 12))
        let stays = [
            stay(.home, at: brussels, from: at(2025, 7, 22, 10), to: at(2025, 7, 29, 18), owner: base),
            realAtBase,
            stay(.home, at: brussels, from: at(2025, 8, 3, 20), to: at(2025, 8, 9, 8), owner: base),
        ]
        let result = ledger(anchors: [realHome(), base], stays: stays, now: at(2025, 10, 20))
        #expect(result.spansByHome[base.id] == [
            span(at(2025, 7, 22, 10), at(2025, 7, 29, 18)),
            span(at(2025, 8, 3, 20), at(2025, 8, 9, 8)),
        ])
        #expect(ledger(anchors: [realHome(), base], stays: [realAtBase], now: at(2025, 10, 20)) == nothing())
    }

    @Test("a stay that records a temporary home not in the store ends nothing and is no evidence; one that records a removed temporary home ends the run")
    func unsyncedAndRemovedOwners() {
        let base = temporaryHome(at: brussels, from: at(2025, 7, 21, 0), to: at(2025, 9, 19, 23))
        let removed = temporaryHome(at: brussels, from: at(2025, 7, 21, 0))
        func middle(owner: HomeAnchor) -> TemporaryHomeLedger.StaySample {
            stay(.home, at: brussels, from: at(2025, 7, 31, 12), to: at(2025, 8, 2, 12), owner: owner)
        }
        func stays(_ middle: TemporaryHomeLedger.StaySample) -> [TemporaryHomeLedger.StaySample] {
            [
                stay(.home, at: brussels, from: at(2025, 7, 22, 10), to: at(2025, 7, 29, 18), owner: base),
                middle,
                stay(.home, at: brussels, from: at(2025, 8, 3, 20), to: at(2025, 8, 9, 8), owner: base),
            ]
        }

        // Its row has not synced: the run goes on through it.
        let unsynced = middle(owner: temporaryHome(at: brussels, from: at(2025, 7, 21, 0)))
        let open = ledger(anchors: [realHome(), base], stays: stays(unsynced), now: at(2025, 10, 20))
        #expect(open.spansByHome[base.id] == [span(at(2025, 7, 22, 10), at(2025, 8, 9, 8))])
        #expect(ledger(anchors: [realHome(), base], stays: [unsynced], now: at(2025, 10, 20)) == nothing())

        // A removed temporary home's stamp still names it: another place's home stay.
        let split = TemporaryHomeLedger.result(
            travelling: [], anchors: [realHome(), base], stays: stays(middle(owner: removed)),
            visitBackedStayIDs: [], removedTemporaryHomeIDs: [removed.id], now: at(2025, 10, 20),
            fallbackZone: utc)
        #expect(split.spansByHome[base.id]?.count == 2)
        #expect(split.spansByHome[removed.id] == nil)
    }
}
