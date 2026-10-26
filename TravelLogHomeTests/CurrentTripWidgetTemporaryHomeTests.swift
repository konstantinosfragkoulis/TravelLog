//
//  CurrentTripWidgetTemporaryHomeTests.swift
//  TravelLogTests
//
//  The Current Trip widget shows the newest ongoing trip, else an active
//  temporary home the user is at, else the newest finished trip. "At" means
//  the newest home stay in the store is one that temporary home owns; a
//  newer stay of another category changes nothing. The snapshot carries the
//  temporary home's stored zone and its start day is read in it.
//  Without a temporary home the widget reads and shows what it did before.
//  A failed read throws; it never falls through to the finished trip.
//

import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

#if DEBUG
@MainActor
@Suite("Current Trip widget at a temporary home")
struct CurrentTripWidgetTemporaryHomeTests {

    private typealias Place = (latitude: Double, longitude: Double, h3: String)

    private let athens: Place = (37.9838, 23.7275, "861eda747ffffff")
    private let brussels: Place = (50.7883, 4.3762, "861fa44f7ffffff")
    /// Inside Brussels, a few hundred metres from the declared centre.
    private let brusselsFlat: Place = (50.7846, 4.3773, "861fa44f7ffffff")
    private let beringen: Place = (51.0538, 5.2268, "861fa42a7ffffff")
    private let lisbon: Place = (38.7027, -9.1153, "863933677ffffff")
    private let paris: Place = (48.8145, 2.3648, "861fb4647ffffff")
    private let rome: Place = (41.9282, 12.4287, "861e80527ffffff")

    private let belgianFlag = "\u{1F1E7}\u{1F1EA}"
    private let frenchFlag = "\u{1F1EB}\u{1F1F7}"
    private let italianFlag = "\u{1F1EE}\u{1F1F9}"

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Noon UTC on 8 June 2027: day 42 of a stay that began on 28 April.
    private var now: Date { date(2027, 6, 8) }

    /// Records every checked read and fails `target` when one is given.
    private func reads(
        failing target: WidgetStoreRead? = nil
    ) -> (hook: @Sendable (WidgetStoreRead) throws -> Void, log: OSAllocatedUnfairLock<[WidgetStoreRead]>) {
        let log = OSAllocatedUnfairLock(initialState: [WidgetStoreRead]())
        let hook: @Sendable (WidgetStoreRead) throws -> Void = { read in
            log.withLock { $0.append(read) }
            if read == target { throw CocoaError(.fileReadUnknown) }
        }
        return (hook, log)
    }

    /// `owner` is the temporary home its home writer recorded, as the
    /// classifier stamps a stay it makes home inside a temporary home's dates.
    @discardableResult
    private func stay(
        _ context: ModelContext, _ category: StayCategory, at place: Place,
        start: Date, trip: Trip? = nil, by owner: TemporaryHome? = nil
    ) -> Stay {
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(4 * 3_600),
            centroidLatitude: place.latitude, centroidLongitude: place.longitude,
            h3IndexRes6: place.h3, pingCount: 4, distanceFromHomeKm: 0, pingIDs: [],
            timeZoneIdentifier: "UTC")
        context.insert(stay)
        stay.category = category
        stay.temporaryHomeID = owner?.id
        stay.trip = trip
        return stay
    }

    @discardableResult
    private func temporaryHome(
        _ context: ModelContext, at place: Place? = nil, from start: Date, to end: Date? = nil,
        label: String = "Erasmus", zone: String = "Europe/Brussels"
    ) -> TemporaryHome {
        let place = place ?? brussels
        let row = TemporaryHome(
            label: label, latitude: place.latitude, longitude: place.longitude,
            startedAt: start, endedAt: end)
        row.locality = "Brussels"
        row.isoCountryCode = "BE"
        row.timeZoneIdentifier = zone
        context.insert(row)
        return row
    }

    /// Athens is home since 2020, and a Paris trip ran from 28 to 31 March 2027.
    private func seededContext() throws -> ModelContext {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        context.insert(Home(
            label: "Home", latitude: athens.latitude, longitude: athens.longitude,
            startedAt: date(2020, 1, 1)))
        let finished = Trip(startDate: date(2027, 3, 28))
        finished.isComplete = true
        finished.endDate = date(2027, 3, 31)
        finished.customName = "Paris"
        finished.countryCodes = "FR"
        context.insert(finished)
        stay(context, .destination, at: paris, start: date(2027, 3, 28), trip: finished)
        return context
    }

    /// What the widget showed for the seeded Paris trip before temporary homes.
    private var finishedTrip: Trip.WidgetSnapshot {
        Trip.WidgetSnapshot(
            title: "Paris", countryFlags: frenchFlag, startDate: date(2027, 3, 28),
            endDate: date(2027, 3, 31), dayCount: 4, isOngoing: false,
            startDayTimeZoneIdentifier: "UTC", endDayTimeZoneIdentifier: "UTC")
    }

    /// Reads the saved store through a fresh context, as the widget does.
    private func snapshot(in context: ModelContext, now: Date) throws -> Trip.WidgetSnapshot? {
        try Trip.widgetSnapshot(in: ModelContext(context.container), now: now, languageTag: "en")
    }

    // MARK: - No temporary home

    @Test("with no temporary home an ongoing trip shows as before and no new read runs")
    func noTemporaryHomeOngoingTrip() throws {
        let context = try seededContext()
        let current = Trip(startDate: date(2027, 6, 6))
        current.customName = "Rome"
        current.countryCodes = "IT"
        context.insert(current)
        stay(context, .destination, at: rome, start: date(2027, 6, 6), trip: current)
        try context.save()

        let checked = reads()
        let found = try WidgetStoreRead.$failureForTesting.withValue(checked.hook) {
            try snapshot(in: context, now: now)
        }
        #expect(found == Trip.WidgetSnapshot(
            title: "Rome", countryFlags: italianFlag, startDate: date(2027, 6, 6),
            endDate: nil, dayCount: 3, isOngoing: true, dayCountTimeZoneIdentifier: "UTC",
            startDayTimeZoneIdentifier: "UTC"))
        #expect(checked.log.withLock { $0 } == [.ongoingTrip])
    }

    @Test("an ongoing trip with only transit stays shows their country, not an empty flag row")
    func ongoingAllTransitTripShowsTransitFlag() throws {
        let context = try seededContext()
        let current = Trip(startDate: date(2027, 6, 6))
        context.insert(current)
        stay(context, .transit, at: rome, start: date(2027, 6, 6), trip: current).isoCountryCode = "IT"
        try context.save()

        let found = try snapshot(in: context, now: now)
        #expect(found?.isOngoing == true)
        #expect(found?.countryFlags == italianFlag)
    }

    @Test("with no temporary home the finished trip shows as before, after one temporary-home read")
    func noTemporaryHomeFinishedTrip() throws {
        let context = try seededContext()
        // A home stay in Brussels is the latest stay; nothing declares Brussels.
        stay(context, .home, at: brusselsFlat, start: date(2027, 6, 6))
        try context.save()

        let checked = reads()
        let found = try WidgetStoreRead.$failureForTesting.withValue(checked.hook) {
            try snapshot(in: context, now: now)
        }
        #expect(found == finishedTrip)
        #expect(checked.log.withLock { $0 } == [.ongoingTrip, .temporaryHomes, .completedTrip])
    }

    @Test("an empty store still shows nothing")
    func emptyStore() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        #expect(try snapshot(in: context, now: now) == nil)
    }

    // MARK: - At the temporary home

    @Test("at an active temporary home with no open trip, its label, flag, day number and stored zone show",
          arguments: [nil, 150.0, 41.0] as [Double?])
    func activeTemporaryHome(endAfterDays: Double?) throws {
        let context = try seededContext()
        let start = date(2027, 4, 28)
        // 41 days after the start is `now`: the end date itself is still inside.
        let base = temporaryHome(context, from: start, to: endAfterDays.map { start.addingTimeInterval($0 * 86_400) })
        // Inserted out of order: the Brussels stay is the latest by start time.
        stay(context, .home, at: brusselsFlat, start: date(2027, 6, 6), by: base)
        stay(context, .home, at: athens, start: date(2027, 5, 17))
        try context.save()

        #expect(try snapshot(in: context, now: now) == Trip.WidgetSnapshot(
            title: "Erasmus", countryFlags: belgianFlag, startDate: start, endDate: nil,
            dayCount: 42, isOngoing: true, isTemporaryHome: true,
            timeZoneIdentifier: "Europe/Brussels"))
    }

    @Test("a temporary home without a label shows its place name")
    func unlabeledTemporaryHomeShowsPlaceName() throws {
        let context = try seededContext()
        let base = temporaryHome(context, from: date(2027, 4, 28), label: "")
        stay(context, .home, at: brusselsFlat, start: date(2027, 6, 6), by: base)
        try context.save()

        let found = try #require(try snapshot(in: context, now: now))
        #expect(found.title == "Brussels")
        #expect(found.isTemporaryHome)
    }

    @Test("the day number is counted in the temporary home's stored time zone",
          arguments: [("Europe/Brussels", 43), ("UTC", 42)])
    func dayNumberUsesStoredZone(zone: String, expected: Int) throws {
        let context = try seededContext()
        let base = temporaryHome(context, from: date(2027, 4, 28), zone: zone)
        stay(context, .home, at: brusselsFlat, start: date(2027, 6, 6), by: base)
        try context.save()

        // 22:30 UTC on 8 June is 00:30 on 9 June in Brussels.
        let lateEvening = date(2027, 6, 8, hour: 22, minute: 30)
        let found = try #require(try snapshot(in: context, now: lateEvening))
        #expect(found.isTemporaryHome)
        #expect(found.dayCount == expected)
        #expect(found.timeZoneIdentifier == zone)
    }

    // MARK: - Start day

    /// 23:30 UTC on 9 May 2027 is 10 May in Tokyo and 9 May in
    /// New York. No device zone reads both days, so the label follows the
    /// stored zone wherever the widget runs.
    @Test("the start day of a temporary home is read in its stored zone, east or west of the device's",
          arguments: [("Asia/Tokyo", "May 10"), ("America/New_York", "May 9")])
    func startDayUsesStoredZone(zone: String, expected: String) {
        let shown = Trip.WidgetSnapshot(
            title: "Erasmus", countryFlags: belgianFlag,
            startDate: date(2027, 5, 9, hour: 23, minute: 30), endDate: nil,
            dayCount: 1, isOngoing: true, isTemporaryHome: true, timeZoneIdentifier: zone)
        #expect(shown.startDayText(locale: Locale(identifier: "en_US")) == expected)
    }

    @Test("a temporary home that starts at midnight in its own zone shows that day, in the store's own snapshot")
    func storedStartDayReadsInStoredZone() throws {
        let context = try seededContext()
        // Midnight on 10 May in Tokyo is 15:00 UTC on 9 May.
        let base = temporaryHome(context, from: date(2027, 5, 9, hour: 15), zone: "Asia/Tokyo")
        stay(context, .home, at: brusselsFlat, start: date(2027, 6, 6), by: base)
        try context.save()

        let found = try #require(try snapshot(in: context, now: now))
        #expect(found.timeZoneIdentifier == "Asia/Tokyo")
        #expect(found.startDayText(locale: Locale(identifier: "en_US")) == "May 10")
    }

    @Test("an ongoing trip's snapshot carries no stored zone; its start day reads in its first stay's")
    func ongoingTripCarriesNoZone() throws {
        let context = try seededContext()
        let current = Trip(startDate: date(2027, 6, 6))
        current.customName = "Rome"
        context.insert(current)
        stay(context, .destination, at: rome, start: date(2027, 6, 6), trip: current)
        try context.save()

        let found = try #require(try snapshot(in: context, now: now))
        #expect(found.timeZoneIdentifier == nil)
        #expect(found.startDayTimeZoneIdentifier == "UTC")
        var style = Date.FormatStyle(locale: Locale(identifier: "en_US")).month().day()
        style.timeZone = TimeZone(identifier: "UTC")!
        #expect(found.startDayText(locale: Locale(identifier: "en_US")) == date(2027, 6, 6).formatted(style))
    }

    @Test("of two home stays that start at the same instant, the one with the larger id is the newest",
          arguments: [true, false])
    func latestStayTieBreaksByID(baseHasLargerID: Bool) throws {
        let context = try seededContext()
        let base = temporaryHome(context, from: date(2027, 4, 28))
        let atBase = stay(context, .home, at: brusselsFlat, start: date(2027, 6, 6), by: base)
        let elsewhere = stay(context, .home, at: athens, start: date(2027, 6, 6))
        let smaller = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let larger = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        atBase.id = baseHasLargerID ? larger : smaller
        elsewhere.id = baseHasLargerID ? smaller : larger
        try context.save()

        let found = try #require(try snapshot(in: context, now: now))
        #expect(found.isTemporaryHome == baseHasLargerID)
        #expect(found.title == (baseHasLargerID ? "Erasmus" : "Paris"))
    }

    // MARK: - Not at the temporary home

    @Test("an open trip wins over an active temporary home the latest stay is at")
    func openTripWins() throws {
        let context = try seededContext()
        let base = temporaryHome(context, from: date(2027, 4, 28))
        let current = Trip(startDate: date(2027, 6, 4))
        current.customName = "Beringen"
        current.countryCodes = "BE"
        context.insert(current)
        stay(context, .destination, at: beringen, start: date(2027, 6, 4), trip: current)
        stay(context, .home, at: brusselsFlat, start: date(2027, 6, 6), by: base)
        try context.save()

        #expect(try snapshot(in: context, now: now) == Trip.WidgetSnapshot(
            title: "Beringen", countryFlags: belgianFlag, startDate: date(2027, 6, 4),
            endDate: nil, dayCount: 5, isOngoing: true, dayCountTimeZoneIdentifier: "UTC",
            startDayTimeZoneIdentifier: "UTC"))
    }

    @Test("back at the real Home during an active temporary home, the finished trip shows")
    func latestStayAtRealHome() throws {
        let context = try seededContext()
        let base = temporaryHome(context, from: date(2027, 4, 28))
        stay(context, .home, at: brusselsFlat, start: date(2027, 6, 6), by: base)
        stay(context, .home, at: athens, start: date(2027, 6, 7))
        try context.save()

        #expect(try snapshot(in: context, now: now) == finishedTrip)
    }

    @Test("a newer stay that is not a home stay, with the newest home stay at the temporary home, still shows the temporary home",
          arguments: ["routine", "unclassified", "destination"])
    func latestStayNotHomeClass(categoryRaw: String) throws {
        let category = try #require(StayCategory(rawValue: categoryRaw))
        let context = try seededContext()
        let start = date(2027, 4, 28)
        let base = temporaryHome(context, from: start)
        stay(context, .home, at: brusselsFlat, start: date(2027, 6, 6), by: base)
        // The university, or an outing that made no trip: newer, near the base, not home.
        stay(context, category, at: beringen, start: date(2027, 6, 7))
        try context.save()

        #expect(try snapshot(in: context, now: now) == Trip.WidgetSnapshot(
            title: "Erasmus", countryFlags: belgianFlag, startDate: start, endDate: nil,
            dayCount: 42, isOngoing: true, isTemporaryHome: true,
            timeZoneIdentifier: "Europe/Brussels"))
    }

    @Test("with the newest home stay at the real Home, a newer routine stay near the temporary home still shows the finished trip")
    func newestHomeStayAtRealHomeWithNewerRoutineStay() throws {
        let context = try seededContext()
        let base = temporaryHome(context, from: date(2027, 4, 28))
        stay(context, .home, at: brusselsFlat, start: date(2027, 6, 5), by: base)
        stay(context, .home, at: athens, start: date(2027, 6, 6))
        stay(context, .routine, at: beringen, start: date(2027, 6, 7))
        try context.save()

        #expect(try snapshot(in: context, now: now) == finishedTrip)
    }

    /// Days relative to `now`: ended yesterday, or starting tomorrow.
    @Test("an ended or not yet started temporary home shows the finished trip",
          arguments: [(-60.0, -1.0), (1.0, 90.0)])
    func inactiveTemporaryHome(startOffsetDays: Double, endOffsetDays: Double) throws {
        let context = try seededContext()
        let base = temporaryHome(
            context, from: now.addingTimeInterval(startOffsetDays * 86_400),
            to: now.addingTimeInterval(endOffsetDays * 86_400))
        // Recorded only when the dates cover it: the one that ended yesterday.
        stay(context, .home, at: brusselsFlat, start: date(2027, 6, 6),
             by: base.isActive(at: date(2027, 6, 6)) ? base : nil)
        try context.save()

        #expect(try snapshot(in: context, now: now) == finishedTrip)
    }

    @Test("a latest stay owned by an ended temporary home does not show another active one")
    func latestStayOwnedByEndedTemporaryHome() throws {
        let context = try seededContext()
        let base = temporaryHome(context, from: date(2027, 4, 28), to: date(2027, 6, 7))
        let next = temporaryHome(context, at: lisbon, from: date(2027, 6, 7, hour: 13), label: "Lisbon")
        next.locality = "Lisbon"
        next.isoCountryCode = "PT"
        stay(context, .home, at: brusselsFlat, start: date(2027, 6, 6), by: base)
        try context.save()

        #expect(try snapshot(in: context, now: now) == finishedTrip)
    }

    // MARK: - Recorded owner

    @Test("at the temporary home the widget reads no Home rows, only the newest home stay's record")
    func atTemporaryHomeReadsNoHomes() throws {
        let context = try seededContext()
        let base = temporaryHome(context, from: date(2027, 4, 28))
        stay(context, .home, at: brusselsFlat, start: date(2027, 6, 6), by: base)
        try context.save()

        let checked = reads()
        let found = try WidgetStoreRead.$failureForTesting.withValue(checked.hook) {
            try snapshot(in: context, now: now)
        }
        #expect(found?.isTemporaryHome == true)
        #expect(checked.log.withLock { $0 } == [.ongoingTrip, .temporaryHomes, .latestHomeStay])
    }

    /// Nothing recorded means a real Home made the stay home, however near
    /// the declared centre it lies; the nearest centre would hand it to the
    /// temporary home.
    @Test("a newest home stay at the temporary home's centre that nothing recorded is the real Home's")
    func unrecordedStayAtTheCentreIsTheRealHomes() throws {
        let context = try seededContext()
        temporaryHome(context, from: date(2027, 4, 28))
        stay(context, .home, at: brusselsFlat, start: date(2027, 6, 6))
        try context.save()

        #expect(try snapshot(in: context, now: now) == finishedTrip)
    }

    @Test("a newest home stay the temporary home recorded is its own wherever its centroid lies")
    func recordedStayFarFromTheCentreIsTheTemporaryHomes() throws {
        let context = try seededContext()
        let start = date(2027, 4, 28)
        let base = temporaryHome(context, from: start)
        // Recorded inside the declared area; its centroid sits nearer Athens.
        stay(context, .home, at: athens, start: date(2027, 6, 6), by: base)
        try context.save()

        #expect(try snapshot(in: context, now: now) == Trip.WidgetSnapshot(
            title: "Erasmus", countryFlags: belgianFlag, startDate: start, endDate: nil,
            dayCount: 42, isOngoing: true, isTemporaryHome: true,
            timeZoneIdentifier: "Europe/Brussels"))
    }

    @Test("a newest home stay recorded by a removed or unsynced temporary home shows the finished trip, not another active one",
          arguments: [true, false])
    func removedOrUnsyncedOwnerShowsTheFinishedTrip(removed: Bool) throws {
        let context = try seededContext()
        temporaryHome(context, from: date(2027, 4, 28))
        let gone = temporaryHome(context, from: date(2027, 4, 28), label: "Gone")
        let stamp = stay(context, .home, at: brusselsFlat, start: date(2027, 6, 6), by: gone)
        if removed {
            gone.removedAt = date(2027, 6, 7)
        } else {
            context.delete(gone)
            stamp.temporaryHomeID = UUID()
        }
        try context.save()

        #expect(try snapshot(in: context, now: now) == finishedTrip)
    }

    // MARK: - Failed reads

    @Test("a failed temporary-home or newest-home-stay read throws and never shows the finished trip",
          arguments: [WidgetStoreRead.temporaryHomes, .latestHomeStay])
    func newReadFailureThrows(read: WidgetStoreRead) throws {
        let context = try seededContext()
        let base = temporaryHome(context, from: date(2027, 4, 28))
        stay(context, .home, at: brusselsFlat, start: date(2027, 6, 6), by: base)
        try context.save()

        let injected = reads(failing: read)
        #expect(throws: CocoaError.self) {
            try WidgetStoreRead.$failureForTesting.withValue(injected.hook) {
                try snapshot(in: context, now: now)
            }
        }
        let checked = injected.log.withLock { $0 }
        #expect(checked.last == read)
        #expect(!checked.contains(.completedTrip))
    }
}
#endif

extension CurrentTripWidgetTemporaryHomeTests {
    /// 21:30 UTC on 29 May 2027 is 00:30 on 30 May in Athens and 23:30 on
    /// 29 May in Brussels: the day number changes at 22:00 UTC, an hour away,
    /// while the device's next midnight is a day away.
    @Test("a temporary home's widget entry is rebuilt at the next midnight of its stored zone when that comes before the device's, and a trip's at the device's")
    func nextDayBoundaryFollowsTheStoredZone() throws {
        var athens = Calendar(identifier: .gregorian)
        athens.timeZone = try #require(TimeZone(identifier: "Europe/Athens"))
        let now = date(2027, 5, 29, hour: 21, minute: 30)
        func shown(zone: String?) -> Trip.WidgetSnapshot {
            Trip.WidgetSnapshot(
                title: "Erasmus", countryFlags: belgianFlag, startDate: date(2027, 4, 28),
                endDate: nil, dayCount: 32, isOngoing: true,
                isTemporaryHome: zone != nil, timeZoneIdentifier: zone)
        }
        #expect(shown(zone: "Europe/Brussels").nextDayBoundary(after: now, deviceCalendar: athens)
                == date(2027, 5, 29, hour: 22, minute: 1))
        #expect(shown(zone: nil).nextDayBoundary(after: now, deviceCalendar: athens)
                == date(2027, 5, 30, hour: 21, minute: 1))
    }

    /// An ongoing trip counts today in its last stay's zone, so its entry is
    /// rebuilt a minute after that zone's midnight when it comes before the
    /// device's. Tokyo's midnight on 9 June 2027 is 15:00 UTC, six hours
    /// before Athens'. Havana skipped midnight on 9 March 2025 (00:00 became
    /// 01:00 EDT, 05:00 UTC): `nextDate` with `.nextTime` returns 01:00, the
    /// first instant of that day, five hours before Honolulu's midnight.
    @Test("an ongoing trip's widget entry is rebuilt at the next midnight of its last stay's zone, where its day count changes",
          arguments: [
            ("Asia/Tokyo", "Europe/Athens", false),
            ("America/Havana", "Pacific/Honolulu", true),
          ])
    func ongoingTripBoundaryFollowsTheLastStaysZone(lastZone: String, deviceZone: String, skipsMidnight: Bool) throws {
        let start = skipsMidnight ? date(2025, 3, 7) : date(2027, 6, 6)
        let now = skipsMidnight ? date(2025, 3, 8, hour: 17) : date(2027, 6, 8)
        let midnight = skipsMidnight ? date(2025, 3, 9, hour: 5) : date(2027, 6, 8, hour: 15)
        let zone = try #require(TimeZone(identifier: lastZone))
        var device = Calendar(identifier: .gregorian)
        device.timeZone = try #require(TimeZone(identifier: deviceZone))
        // The platform behaviours relied on: the zone's day changes at
        // `midnight`, and the device's own midnight comes later.
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        #expect(local.startOfDay(for: midnight) == midnight)
        #expect(local.component(.hour, from: midnight) == (skipsMidnight ? 1 : 0))
        let deviceMidnight = try #require(device.nextDate(
            after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime))
        #expect(deviceMidnight > midnight)

        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let current = Trip(startDate: start)
        current.customName = "Away"
        context.insert(current)
        stay(context, .destination, at: rome, start: start, trip: current).timeZoneIdentifier = lastZone
        try context.save()

        let shown = try #require(try snapshot(in: context, now: now))
        #expect(shown.dayCountTimeZoneIdentifier == lastZone)
        // Its start day still reads in the device's zone.
        #expect(shown.timeZoneIdentifier == nil)
        #expect(shown.nextDayBoundary(after: now, deviceCalendar: device) == midnight.addingTimeInterval(60))
        let lastSecond = try #require(try snapshot(in: context, now: midnight.addingTimeInterval(-1)))
        let firstSecond = try #require(try snapshot(in: context, now: midnight))
        #expect(lastSecond.dayCount == shown.dayCount)
        #expect(firstSecond.dayCount == shown.dayCount + 1)
    }
}
