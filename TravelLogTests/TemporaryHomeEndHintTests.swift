//
//  TemporaryHomeEndHintTests.swift
//  TravelLogTests
//
//  What a temporary home card offers once the user is back at a real Home
//  (the end hint and its Not Yet), once its end has passed while the user
//  still seems to be there (Extend), and when its state or hints next change
//  with no store write (`nextReloadAt`). Everything is in UTC unless a stay
//  names its own zone, and expected values are written out by hand.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Temporary home end and extend hints")
struct TemporaryHomeEndHintTests {

    private typealias Place = (lat: Double, lon: Double)

    private let athens: Place = (37.9838, 23.7275)
    private let brussels: Place = (50.8904, 4.3705)
    /// The airport, about 8 km from the Brussels pin.
    private let zaventem: Place = (50.9010, 4.4844)
    private let rome: Place = (41.9577, 12.5247)

    private let utc = TimeZone(secondsFromGMT: 0)!

    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    // MARK: - Seeding

    private func store() throws -> (container: ModelContainer, context: ModelContext) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let home = Home(label: "Home", latitude: athens.lat, longitude: athens.lon,
                        radiusKm: 25, startedAt: at(2020, 1, 1))
        home.locality = "Athens"
        context.insert(home)
        return (container, context)
    }

    @discardableResult
    private func temporaryHome(
        _ context: ModelContext, from start: Date, to end: Date? = nil, locality: String? = "Brussels"
    ) -> TemporaryHome {
        let row = TemporaryHome(
            label: "Erasmus", latitude: brussels.lat, longitude: brussels.lon, startedAt: start, endedAt: end)
        row.locality = locality
        row.isoCountryCode = "BE"
        row.timeZoneIdentifier = "UTC"
        context.insert(row)
        return row
    }

    @discardableResult
    private func stay(
        _ context: ModelContext, _ category: StayCategory, at place: Place,
        from start: Date, to end: Date, by owner: TemporaryHome? = nil, zone: String = "UTC"
    ) -> Stay {
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: place.lat, centroidLongitude: place.lon,
            h3IndexRes6: "", pingCount: 4, distanceFromHomeKm: 0, pingIDs: [],
            timeZoneIdentifier: zone)
        stay.category = category
        stay.temporaryHomeID = owner?.id
        context.insert(stay)
        return stay
    }

    private func card(
        _ container: ModelContainer, now: Date, defaults: UserDefaults? = nil
    ) throws -> TemporaryHomeCards.Card {
        let cards = try defaults.map {
            try TemporaryHomeCards.load(container: container, now: now, fallbackZone: utc, defaults: $0)
        } ?? TemporaryHomeCards.load(container: container, now: now, fallbackZone: utc)
        return try #require(cards.first)
    }

    private func isolatedDefaults() throws -> (defaults: UserDefaults, suite: String) {
        let suite = "TemporaryHomeEndHintTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    /// At the base from 22 October to 9 November, home in Athens from 10:00 on
    /// the 10th, the newest stay. The temporary home is open-ended unless `end`.
    private func leftForHome(end: Date? = nil) throws -> (container: ModelContainer, context: ModelContext, base: TemporaryHome) {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2024, 10, 21, 0), to: end)
        stay(context, .home, at: brussels, from: at(2024, 10, 22, 10), to: at(2024, 11, 9, 8), by: base)
        stay(context, .home, at: athens, from: at(2024, 11, 10, 10), to: at(2024, 11, 14, 10))
        try context.save()
        return (container, context, base)
    }

    // MARK: - Not Yet

    @Test("Not Yet hides this end hint on this device and keeps its date for the detail page; a later stretch at home asks again")
    func notYetIsKeyedByTheStretch() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (container, context, base) = try leftForHome()

        let asked = try card(container, now: at(2024, 11, 13, 0), defaults: defaults)
        let backHomeSince = try #require(asked.backHomeSince)
        #expect(!asked.endHintDismissed)
        TemporaryHomeCards.dismissEndHint(id: base.id, backHomeSince: backHomeSince, defaults: defaults)
        #expect(TemporaryHomeCards.isEndHintDismissed(id: base.id, backHomeSince: backHomeSince, defaults: defaults))

        let answered = try card(container, now: at(2024, 11, 15), defaults: defaults)
        #expect(answered.endHintDismissed)
        #expect(answered.suggestedEnd == at(2024, 11, 9, 8))

        // Back at the base, then home again from 29 November.
        stay(context, .home, at: brussels, from: at(2024, 11, 15, 20), to: at(2024, 11, 28, 8), by: base)
        stay(context, .home, at: athens, from: at(2024, 11, 29, 10), to: at(2024, 12, 3, 10))
        try context.save()
        let later = try card(container, now: at(2024, 12, 3), defaults: defaults)
        #expect(later.backHomeSince == at(2024, 11, 29, 10))
        #expect(later.suggestedEnd == at(2024, 11, 28, 8))
        #expect(!later.endHintDismissed)
    }

    @Test("Not Yet keeps the latest 200 answers on this device")
    func notYetIsPruned() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let days = (0..<201).map { at(2025, 1, 1).addingTimeInterval(Double($0) * 86_400) }
        for day in days { TemporaryHomeCards.dismissEndHint(id: id, backHomeSince: day, defaults: defaults) }
        #expect(!TemporaryHomeCards.isEndHintDismissed(id: id, backHomeSince: days[0], defaults: defaults))
        #expect(TemporaryHomeCards.isEndHintDismissed(id: id, backHomeSince: days[200], defaults: defaults))
        #expect(defaults.stringArray(forKey: TemporaryHomeCards.endHintDismissalsKey)?.count == 200)
        #expect(!TemporaryHomeCards.isEndHintDismissed(id: UUID(), backHomeSince: days[200], defaults: defaults))
    }

    @Test("the hint's End opens the end form preset to the suggested day, and Extend the extend form; neither ends anything by itself")
    func hintActionsOpenTheForm() throws {
        let (container, _, base) = try leftForHome()
        let asked = try card(container, now: at(2024, 11, 13, 0))
        let suggested = try #require(asked.suggestedEnd)

        guard case .end(let id, let day) = TemporaryHomeCardRow.endMode(for: asked) else {
            Issue.record("End must open the end form")
            return
        }
        #expect(id == base.id)
        #expect(day == suggested)
        guard case .extend(let editID) = TemporaryHomeCardRow.extendMode(for: asked) else {
            Issue.record("Extend must open the extend form")
            return
        }
        #expect(editID == base.id)

        // Opening the form wrote nothing: the temporary home is still open-ended.
        #expect(try card(container, now: at(2024, 11, 13, 0)).endedAt == nil)
    }

    // MARK: - Visits home

    @Test("the final return is an ongoing visit home while the temporary home is active, and a closed one once it has ended")
    func ongoingVisitHome() throws {
        let open = try leftForHome()
        let active = try card(open.container, now: at(2024, 11, 15))
        #expect(active.visitsHome == [DateInterval(start: at(2024, 11, 10, 10), end: at(2024, 11, 15))])
        #expect(active.visitHomeIsOngoing)
        let english = Locale(identifier: "en_US")
        #expect(TemporaryHomeDetailView.visitText(
            active.visitsHome[0], isOngoing: true, timeZoneIdentifier: "UTC", locale: english) == "Since Nov 10, 2024")
        #expect(TemporaryHomeDetailView.visitText(
            active.visitsHome[0], isOngoing: false, timeZoneIdentifier: "UTC", locale: english)
            == TemporaryHomeDetailView.dateRange(active.visitsHome[0], timeZoneIdentifier: "UTC", locale: english))

        let ended = try leftForHome(end: at(2024, 11, 11, 23))
        let closed = try card(ended.container, now: at(2024, 11, 15))
        #expect(closed.visitsHome == [DateInterval(start: at(2024, 11, 10, 10), end: at(2024, 11, 11, 23))])
        #expect(!closed.visitHomeIsOngoing)
    }

    // MARK: - Extend

    /// Brussels from 21 October to the end of 19 November, the last stay
    /// there on the 18th.
    private func endedSemester() throws -> (container: ModelContainer, context: ModelContext, base: TemporaryHome) {
        let (container, context) = try store()
        let base = temporaryHome(
            context, from: at(2024, 10, 21, 0), to: at(2024, 11, 19, 23).addingTimeInterval(59 * 60 + 59))
        stay(context, .home, at: brussels, from: at(2024, 10, 22, 10), to: at(2024, 11, 18, 20), by: base)
        try context.save()
        return (container, context, base)
    }

    @Test("a stay in its area after the end asks to extend it until the window closes 30 days after the end")
    func extendAfterTheEnd() throws {
        let (container, context, _) = try endedSemester()
        stay(context, .destination, at: brussels, from: at(2024, 11, 21, 10), to: at(2024, 11, 24, 8))
        try context.save()

        let asked = try card(container, now: at(2024, 11, 25))
        #expect(asked.state == .ended)
        #expect(asked.extendSuggested)
        let closes = at(2024, 11, 19, 23).addingTimeInterval(59 * 60 + 59 + 30 * 86_400)
        #expect(asked.nextReloadAt == closes.addingTimeInterval(1))
        #expect(try card(container, now: closes.addingTimeInterval(-1)).extendSuggested)
        #expect(!(try card(container, now: closes).extendSuggested))
        #expect(try card(container, now: closes.addingTimeInterval(1)).nextReloadAt == nil)
    }

    @Test("a stay it made home that runs past the end asks to extend it")
    func extendForAStayAcrossTheEnd() throws {
        let (container, context, base) = try endedSemester()
        stay(context, .home, at: brussels, from: at(2024, 11, 19, 21), to: at(2024, 11, 22, 8), by: base)
        try context.save()
        #expect(try card(container, now: at(2024, 11, 23)).extendSuggested)
    }

    @Test("no Extend once a qualifying stay at the real Home follows the end, nor for a stay elsewhere, at the airport or a lone fix")
    func noExtendWithoutPresence() throws {
        let home = try endedSemester()
        stay(home.context, .destination, at: brussels, from: at(2024, 11, 21, 10), to: at(2024, 11, 24, 8))
        stay(home.context, .home, at: athens, from: at(2024, 11, 25, 10), to: at(2024, 11, 27, 10))
        try home.context.save()
        #expect(!(try card(home.container, now: at(2024, 11, 28)).extendSuggested))

        let elsewhere = try endedSemester()
        stay(elsewhere.context, .destination, at: rome, from: at(2024, 11, 21, 10), to: at(2024, 11, 24, 8))
        try elsewhere.context.save()
        #expect(!(try card(elsewhere.container, now: at(2024, 11, 25)).extendSuggested))

        let airport = try endedSemester()
        stay(airport.context, .transit, at: zaventem, from: at(2024, 11, 20, 6), to: at(2024, 11, 20, 9))
        try airport.context.save()
        #expect(!(try card(airport.container, now: at(2024, 11, 21)).extendSuggested))

        let loneFix = try endedSemester()
        let fix = stay(loneFix.context, .destination, at: brussels, from: at(2024, 11, 21, 10), to: at(2024, 11, 21, 10))
        fix.pingCount = 1
        try loneFix.context.save()
        #expect(!(try card(loneFix.container, now: at(2024, 11, 22)).extendSuggested))
    }

    @Test("an active or upcoming temporary home never asks to extend")
    func extendOnlyWhenEnded() throws {
        let (container, context, _) = try endedSemester()
        stay(context, .destination, at: brussels, from: at(2024, 11, 21, 10), to: at(2024, 11, 24, 8))
        try context.save()
        #expect(!(try card(container, now: at(2024, 11, 19, 12)).extendSuggested))
    }

    @Test("the Extend question names the city when it is known")
    func extendCopy() {
        #expect(TemporaryHomeCardRow.extendHintText(locality: "Brussels") == "Still in Brussels?")
        #expect(TemporaryHomeCardRow.extendHintText(locality: nil) == "Still at this temporary home?")
        #expect(TemporaryHomeCardRow.extendHintText(locality: "") == "Still at this temporary home?")
    }

    // MARK: - Clock

    @Test("an upcoming card reloads at its start and an active one just after its end, with no store write")
    func reloadAtStartAndJustAfterTheEnd() throws {
        let (container, context) = try store()
        let start = at(2024, 12, 21, 0)
        let end = at(2025, 4, 19, 23).addingTimeInterval(59 * 60 + 59)
        temporaryHome(context, from: start, to: end)
        try context.save()

        let upcoming = try card(container, now: at(2024, 12, 20, 23))
        #expect(upcoming.state == .upcoming)
        #expect(upcoming.nextReloadAt == start)
        #expect(try card(container, now: start).state == .active)

        let active = try card(container, now: at(2025, 1, 20))
        #expect(active.nextReloadAt == end.addingTimeInterval(1))
        #expect(try card(container, now: end).state == .active)
        #expect(try card(container, now: end.addingTimeInterval(1)).state == .ended)
        // An open-ended one with nothing pending has nothing to wait for.
        let (openContainer, openContext) = try store()
        temporaryHome(openContext, from: start)
        try openContext.save()
        #expect(try card(openContainer, now: at(2025, 1, 20)).nextReloadAt == nil)
    }

    @Test("a stretch at home reloads at its third civil day, read in the stay's own zone, wherever the device is")
    func reloadAtTheThirdDayInTheStaysZone() throws {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2024, 10, 21, 0))
        stay(context, .home, at: brussels, from: at(2024, 10, 22, 10), to: at(2024, 11, 9, 8), by: base)
        // 10:00 UTC on the 10th is 12:00 in Athens: its third civil day there
        // begins at 00:00 on the 13th, 22:00 UTC on the 12th.
        stay(context, .home, at: athens, from: at(2024, 11, 10, 10), to: at(2024, 11, 11, 10), zone: "Europe/Athens")
        try context.save()
        let threshold = at(2024, 11, 12, 22)

        let waiting = try card(container, now: at(2024, 11, 11))
        #expect(waiting.backHomeSince == nil)
        // The detail's End presets the day already; only the card's prompt waits.
        #expect(waiting.suggestedEnd == at(2024, 11, 9, 8))
        #expect(waiting.nextReloadAt == threshold)
        #expect(try card(container, now: threshold.addingTimeInterval(-1)).backHomeSince == nil)
        let asked = try card(container, now: threshold)
        #expect(asked.suggestedEnd == at(2024, 11, 9, 8))
        #expect(asked.nextReloadAt == nil)

        // A device in Los Angeles reads the same instant.
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let elsewhere = try #require(try TemporaryHomeCards.load(
            container: container, now: threshold, fallbackZone: losAngeles).first)
        #expect(elsewhere.suggestedEnd == at(2024, 11, 9, 8))
    }

    @Test("a stretch at home that has already ended short of three days waits for nothing")
    func noReloadForAClosedShortStretch() throws {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2024, 10, 21, 0))
        stay(context, .home, at: brussels, from: at(2024, 10, 22, 10), to: at(2024, 11, 9, 8), by: base)
        stay(context, .home, at: athens, from: at(2024, 11, 10, 10), to: at(2024, 11, 11, 10))
        stay(context, .destination, at: rome, from: at(2024, 11, 11, 14), to: at(2024, 11, 15, 10))
        try context.save()
        let away = try card(container, now: at(2024, 11, 12))
        #expect(away.backHomeSince == nil)
        #expect(away.nextReloadAt == nil)
    }

    // MARK: - Detail preset and zones

    @Test("one day after the return the card asks nothing yet, but the detail's End presets the last day at the base; Not Yet does not hide the preset")
    func detailPresetBeforeTheCardPrompt() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (container, _, base) = try leftForHome()

        let nextDay = try card(container, now: at(2024, 11, 11, 12), defaults: defaults)
        #expect(nextDay.backHomeSince == nil)
        #expect(nextDay.suggestedEnd == at(2024, 11, 9, 8))
        guard case .end(let id, let day) = TemporaryHomeCardRow.endMode(for: nextDay) else {
            Issue.record("End must open the end form")
            return
        }
        #expect(id == base.id)
        #expect(day == at(2024, 11, 9, 8))

        // Answered Not Yet: the card hides its prompt, the detail keeps the day.
        TemporaryHomeCards.dismissEndHint(id: base.id, backHomeSince: at(2024, 11, 10, 10), defaults: defaults)
        let answered = try card(container, now: at(2024, 11, 15), defaults: defaults)
        #expect(answered.endHintDismissed)
        #expect(answered.suggestedEnd == at(2024, 11, 9, 8))
    }

    @Test("no preset while the newest stay is at the base, and none once the user is back there after a visit home")
    func noPresetWithoutAReturn() throws {
        let (container, context, base) = try leftForHome()
        stay(context, .home, at: brussels, from: at(2024, 11, 15, 20), to: at(2024, 11, 17, 8), by: base)
        try context.save()
        let back = try card(container, now: at(2024, 11, 17, 12))
        #expect(back.suggestedEnd == nil)
        #expect(back.backHomeSince == nil)
    }

    @Test("a return to Los Angeles at 23:30 on 31 October reads 31 October, and the end the Brussels day")
    func returnHomeReadsInTheHomesZone() throws {
        let (container, context) = try store()
        let base = temporaryHome(context, from: at(2024, 10, 21, 0))
        base.timeZoneIdentifier = "Europe/Brussels"
        // Last night in Brussels ends 07:00 on the 30th there (06:00 UTC).
        stay(context, .home, at: brussels, from: at(2024, 10, 22, 10), to: at(2024, 10, 30, 6), by: base,
             zone: "Europe/Brussels")
        // Home in Los Angeles at 23:30 PDT on 31 October: 06:30 UTC on 1 November, already 1 November in Brussels.
        let arrival = at(2024, 11, 1, 6).addingTimeInterval(30 * 60)
        stay(context, .home, at: athens, from: arrival, to: at(2024, 11, 9, 6), zone: "America/Los_Angeles")
        try context.save()

        let asked = try card(container, now: at(2024, 11, 7))
        #expect(asked.backHomeSince == arrival)
        #expect(asked.backHomeTimeZoneIdentifier == "America/Los_Angeles")
        let english = Locale(identifier: "en_US")
        #expect(TemporaryHomeCardRow.endHintText(
            backHomeSince: arrival, backHomeTimeZoneIdentifier: asked.backHomeTimeZoneIdentifier,
            suggestedEnd: try #require(asked.suggestedEnd), timeZoneIdentifier: asked.timeZoneIdentifier,
            locale: english) == "Back home since Oct 31. End it on Oct 30?")

        // The ongoing visit home reads its own zone too.
        #expect(asked.visitsHome.map(\.start) == [arrival])
        #expect(asked.visitHomeTimeZoneIdentifier(at: 0) == "America/Los_Angeles")
        #expect(TemporaryHomeDetailView.visitText(
            asked.visitsHome[0], isOngoing: asked.visitHomeIsOngoing,
            timeZoneIdentifier: asked.visitHomeTimeZoneIdentifier(at: 0), locale: english)
            == "Since Oct 31, 2024")
        // A visit with no zone of its own falls back to the temporary home's.
        #expect(asked.visitHomeTimeZoneIdentifier(at: 1) == "Europe/Brussels")
    }
}
