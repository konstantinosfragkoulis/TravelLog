//
//  WhereWasITemporaryHomeTests.swift
//  TravelLogTests
//
//  "Where was I" tells a day at a temporary home from a day at the real
//  Home. Both are home-category stays; the owner decides the sentence. A
//  failed read of the homes is unavailable, never "you were home".
//

import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

#if DEBUG
@MainActor
@Suite("Where Was I at a temporary home")
struct WhereWasITemporaryHomeTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// `owner` is the temporary home its home writer recorded, as the
    /// classifier stamps a stay it makes home inside a temporary home's dates.
    private func stay(
        _ context: ModelContext, on day: Date, _ category: StayCategory,
        latitude: Double, longitude: Double, metro: String, iso: String, by owner: TemporaryHome? = nil
    ) {
        let stay = Stay(
            startTime: day, endTime: day.addingTimeInterval(4 * 3_600),
            centroidLatitude: latitude, centroidLongitude: longitude,
            h3IndexRes6: H3Service.cellIndex(latitude: latitude, longitude: longitude)!,
            pingCount: 4, distanceFromHomeKm: 0, pingIDs: [])
        context.insert(stay)
        stay.category = category
        stay.temporaryHomeID = owner?.id
        stay.metroName = metro
        stay.isoCountryCode = iso
    }

    /// Athens is home since 2020. Brussels is a temporary home from
    /// 2 February 2028 to 3 July 2028 (when `withTemporaryHome`).
    /// Home stays: Brussels on 14 March, Athens on 27 May, Brussels
    /// again on 2 August after the end. A Beringen day trip on 22 March.
    private func seededContainer(withTemporaryHome: Bool = true) throws -> ModelContainer {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Home(label: "Home", latitude: 37.9838, longitude: 23.7275,
                            startedAt: date(2020, 6, 3)))
        var erasmus: TemporaryHome?
        if withTemporaryHome {
            let row = TemporaryHome(
                label: "Erasmus", latitude: 50.8146, longitude: 4.4221,
                startedAt: date(2028, 2, 2), endedAt: date(2028, 7, 3))
            context.insert(row)
            erasmus = row
        }
        stay(context, on: date(2028, 3, 14), .home,
             latitude: 50.8109, longitude: 4.4232, metro: "Brussels", iso: "BE", by: erasmus)
        stay(context, on: date(2028, 3, 22), .destination,
             latitude: 51.0538, longitude: 5.2268, metro: "Beringen", iso: "BE")
        stay(context, on: date(2028, 5, 27), .home,
             latitude: 37.9838, longitude: 23.7275, metro: "Athens", iso: "GR")
        stay(context, on: date(2028, 8, 2), .home,
             latitude: 50.8109, longitude: 4.4232, metro: "Brussels", iso: "BE")
        try context.save()
        return container
    }

    private func answer(on day: Date, in container: ModelContainer) throws -> [DayVisit] {
        try WhereWasIFetcher.answer(on: day, container: container, calendar: calendar)
    }

    // MARK: - Answers

    @Test("a day at the temporary home answers with the temporary-home sentence")
    func dayAtTemporaryHome() throws {
        let visits = try answer(on: date(2028, 3, 14), in: seededContainer())
        #expect(visits.map(\.place) == ["Brussels"])
        #expect(visits.map(\.isTemporaryHome) == [true])
        #expect(WhereWasIFetcher.dialogText(visits: visits, dayText: "March 14, 2028")
                == "On March 14, 2028, you were at your temporary home in Brussels.")
    }

    @Test("a day at the real Home during the temporary home's dates answers as before")
    func dayAtRealHomeDuringTemporaryHome() throws {
        let visits = try answer(on: date(2028, 5, 27), in: seededContainer())
        #expect(visits.map(\.place) == ["Athens"])
        #expect(visits.map(\.isTemporaryHome) == [false])
        #expect(WhereWasIFetcher.dialogText(visits: visits, dayText: "May 27, 2028")
                == "On May 27, 2028, you were home in Athens.")
    }

    @Test("a home stay at the same place after the temporary home ended answers as home")
    func homeStayAfterTheEnd() throws {
        let visits = try answer(on: date(2028, 8, 2), in: seededContainer())
        #expect(visits.map(\.isTemporaryHome) == [false])
        #expect(WhereWasIFetcher.dialogText(visits: visits, dayText: "August 2, 2028")
                == "On August 2, 2028, you were home in Brussels.")
    }

    @Test("with no temporary home a home day answers exactly as before")
    func noTemporaryHome() throws {
        let visits = try answer(
            on: date(2028, 3, 14), in: seededContainer(withTemporaryHome: false))
        #expect(visits == [DayVisit(
            place: "Brussels", countryName: visits.first?.countryName, flag: "🇧🇪",
            category: .home, tripID: nil, tripName: nil)])
        #expect(WhereWasIFetcher.dialogText(visits: visits, dayText: "March 14, 2028")
                == "On March 14, 2028, you were home in Brussels.")
    }

    @Test("a range holding a home stay at a former real Home and one at a temporary home in the same city lists both; with no temporary home the two stays are one answer, as before",
          arguments: [true, false])
    func rangeKeepsRealAndTemporaryHomeInOneCity(withTemporaryHome: Bool) throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // Athens is home throughout. Brussels was a real Home until
        // 1 February 2028 and is a temporary home from 2 February.
        context.insert(Home(label: "Home", latitude: 37.9838, longitude: 23.7275,
                            startedAt: date(2020, 6, 3)))
        let formerHome = Home(label: "Brussels", latitude: 50.8146, longitude: 4.4221,
                              startedAt: date(2026, 6, 4))
        formerHome.endedAt = date(2028, 2, 1, hour: 23)
        context.insert(formerHome)
        var erasmus: TemporaryHome?
        if withTemporaryHome {
            let row = TemporaryHome(
                label: "Erasmus", latitude: 50.8146, longitude: 4.4221,
                startedAt: date(2028, 2, 2, hour: 0))
            context.insert(row)
            erasmus = row
        }
        for day in [date(2028, 1, 31), date(2028, 2, 3)] {
            stay(context, on: day, .home,
                 latitude: 50.8109, longitude: 4.4232, metro: "Brussels", iso: "BE",
                 by: day < date(2028, 2, 2, hour: 0) ? nil : erasmus)
        }
        try context.save()

        let visits = try WhereWasIFetcher.answer(
            on: date(2028, 1, 31), through: date(2028, 2, 3),
            container: container, calendar: calendar)
        #expect(visits.map(\.place) == (withTemporaryHome ? ["Brussels", "Brussels"] : ["Brussels"]))
        #expect(visits.map(\.isTemporaryHome) == (withTemporaryHome ? [false, true] : [false]))
    }

    @Test("the temporary-home sentence has a form without a place, and routine places keep the home sentence")
    func sentenceVariants() {
        let unnamed = DayVisit(place: nil, countryName: nil, flag: nil,
                               category: .home, tripID: nil, tripName: nil, isTemporaryHome: true)
        let routine = DayVisit(place: "Gérakas", countryName: "Greece", flag: "🇬🇷",
                               category: .routine, tripID: nil, tripName: nil)
        #expect(WhereWasIFetcher.dialogText(visits: [unnamed], dayText: "March 14, 2028")
                == "On March 14, 2028, you were at your temporary home.")
        #expect(WhereWasIFetcher.dialogText(visits: [routine], dayText: "March 14, 2028")
                == "On March 14, 2028, you were home in Gérakas.")
    }

    // MARK: - Recorded owner

    /// Brussels inside the declared dates: the classifier recorded nothing
    /// (a real Home made it home), the stamp names a removed declaration,
    /// or one whose row has not synced.
    private func recordedContainer(
        _ record: String
    ) throws -> ModelContainer {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Home(label: "Home", latitude: 37.9838, longitude: 23.7275,
                            startedAt: date(2020, 6, 3)))
        let erasmus = TemporaryHome(
            label: "Erasmus", latitude: 50.8146, longitude: 4.4221,
            startedAt: date(2028, 2, 2), endedAt: date(2028, 7, 3))
        context.insert(erasmus)
        let removed = TemporaryHome(
            label: "Old", latitude: 50.8146, longitude: 4.4221,
            startedAt: date(2028, 2, 2), endedAt: date(2028, 7, 3))
        removed.removedAt = date(2028, 4, 3)
        context.insert(removed)
        let owner: TemporaryHome? = record == "removed" ? removed : nil
        stay(context, on: date(2028, 3, 14), .home,
             latitude: 50.8109, longitude: 4.4232, metro: "Brussels", iso: "BE", by: owner)
        try context.save()
        if record == "unsynced" {
            try context.fetch(FetchDescriptor<Stay>()).forEach { $0.temporaryHomeID = UUID() }
            try context.save()
        }
        return container
    }

    @Test("a home stay at the temporary home's centre is the one its writer recorded, never the nearest centre's",
          arguments: [("none", false), ("removed", true), ("unsynced", false)])
    func homeStayReadsTheRecordedOwner(record: String, expected: Bool) throws {
        let visits = try answer(on: date(2028, 3, 14), in: recordedContainer(record))
        #expect(visits.map(\.isTemporaryHome) == [expected])
        #expect(WhereWasIFetcher.dialogText(visits: visits, dayText: "March 14, 2028")
                == (expected ? "On March 14, 2028, you were at your temporary home in Brussels."
                             : "On March 14, 2028, you were home in Brussels."))
    }

    @Test("a home stay the temporary home recorded answers with its sentence wherever its centroid lies")
    func recordedStayFarFromTheCentre() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Home(label: "Home", latitude: 37.9838, longitude: 23.7275,
                            startedAt: date(2020, 6, 3)))
        let erasmus = TemporaryHome(
            label: "Erasmus", latitude: 50.8146, longitude: 4.4221, startedAt: date(2028, 2, 2))
        context.insert(erasmus)
        // Recorded inside the declared area; its centroid sits nearer Athens.
        stay(context, on: date(2028, 3, 14), .home,
             latitude: 37.9838, longitude: 23.7275, metro: "Brussels", iso: "BE", by: erasmus)
        try context.save()

        let visits = try answer(on: date(2028, 3, 14), in: container)
        #expect(visits.map(\.isTemporaryHome) == [true])
    }

    // MARK: - Reads

    /// Fails the `occurrence`-th `.dayStays` check (1-based). The first is
    /// the day's stays; the second, made only on a day with a recorded home
    /// stay, is the temporary homes.
    private func failingDayRead(
        onOccurrence occurrence: Int
    ) -> (hook: @Sendable (IntentRead) throws -> Void, log: OSAllocatedUnfairLock<[IntentRead]>) {
        let log = OSAllocatedUnfairLock(initialState: [IntentRead]())
        let hook: @Sendable (IntentRead) throws -> Void = { read in
            let seen = log.withLock { reads -> Int in
                reads.append(read)
                return reads.filter { $0 == .dayStays }.count
            }
            if read == .dayStays, seen == occurrence { throw CocoaError(.fileReadUnknown) }
        }
        return (hook, log)
    }

    @Test("a failed read of the homes on a home day is unavailable, not a home answer")
    func failedAnchorReadThrows() async throws {
        let container = try seededContainer()
        let injected = failingDayRead(onOccurrence: 2)
        await #expect(throws: IntentDataError.unavailable) {
            try await IntentRead.$failureForTesting.withValue(injected.hook) {
                try await WhereWasIFetcher.load(
                    on: date(2028, 3, 14), through: nil, container: container,
                    calendar: calendar, isPersistentStore: true)
            }
        }
        #expect(injected.log.withLock { $0 }.filter { $0 == .dayStays }.count == 2)
    }

    @Test("a day with no home stay never reads the homes")
    func dayWithoutHomeStaySkipsTheRead() async throws {
        let container = try seededContainer()
        let injected = failingDayRead(onOccurrence: 2)
        let loaded = try await IntentRead.$failureForTesting.withValue(injected.hook) {
            try await WhereWasIFetcher.load(
                on: date(2028, 3, 22), through: nil, container: container,
                calendar: calendar, isPersistentStore: true)
        }
        #expect(loaded.visits.map(\.place) == ["Beringen"])
        #expect(injected.log.withLock { $0 }.filter { $0 == .dayStays }.count == 1)
    }

    @Test("a home day at the real Home, which records nothing, never reads the temporary homes")
    func unrecordedHomeDaySkipsTheRead() async throws {
        let container = try seededContainer()
        let injected = failingDayRead(onOccurrence: 2)
        let loaded = try await IntentRead.$failureForTesting.withValue(injected.hook) {
            try await WhereWasIFetcher.load(
                on: date(2028, 5, 27), through: nil, container: container,
                calendar: calendar, isPersistentStore: true)
        }
        #expect(loaded.visits.map(\.isTemporaryHome) == [false])
        #expect(injected.log.withLock { $0 }.filter { $0 == .dayStays }.count == 1)
    }
}
#endif
