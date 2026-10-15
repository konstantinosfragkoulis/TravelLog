//
//  TemporaryHomeFormTests.swift
//  TravelLogTests
//
//  The temporary-home form's pure decisions: the What Changes lines for
//  split trips, what a save holds and asks, the arrival it offers for Since,
//  the review gate that keeps a failed or stale preview from committing, and
//  End mode's payload.
//

import Foundation
import Testing
@testable import TravelLog

struct TemporaryHomeFormTests {

    private typealias Preview = TripClassifier.TemporaryHomeChangePreview
    private typealias Sheet = TemporaryHomeFormSheet

    private func utc(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    private func zone(_ identifier: String) throws -> TimeZone {
        try #require(TimeZone(identifier: identifier))
    }

    private func line(
        _ name: String, _ reasons: [TripClassifier.TripInteraction] = []
    ) -> Preview.TripLine {
        Preview.TripLine(
            id: UUID(), name: name, start: Date(timeIntervalSince1970: 1_792_137_600), end: nil,
            reasons: reasons)
    }

    private func preview(
        joining: Int = 0, leaving: Int = 0, rebuilt: [Preview.TripLine] = [],
        kept: [Preview.TripLine] = [], merged: [Preview.TripLine] = [],
        split: [Preview.TripLine] = [], cityBoundary: Bool = true
    ) -> Preview {
        var preview = Preview(
            staysJoining: joining, staysLeaving: leaving, tripsRebuilt: rebuilt, tripsKept: kept,
            firstStayInArea: nil, lastStayInArea: nil, areaIsCityBoundary: cityBoundary,
            tripsMerged: merged)
        preview.tripsSplit = split
        return preview
    }

    // MARK: - Split lines

    // `Sheet.changeLines` is main-actor isolated (app default isolation).
    @Test("one split trip is named in quotes: its time here becomes time at the temporary home, its trips away become trips of their own, and a copy stays in Removed Trips")
    @MainActor
    func oneSplitTripLine() {
        #expect(Sheet.changeLines(for: preview(split: [line("Erasmus", [.customName])])) == [
            "“Erasmus” will be split into time here and trips away. A copy stays in Removed Trips on this device.",
        ])
    }

    @Test("several split trips are counted and named, at most three, with a copy of each in Removed Trips, and a favorite among them adds that favorites stay with the copies; the lines follow the stays and the rebuilt trips and precede the kept trips and the area note")
    @MainActor
    func severalSplitTripsLine() {
        let lines = Sheet.changeLines(for: preview(
            joining: 12, rebuilt: [line("Ieper")], kept: [line("Beringen", [.userEdited])],
            split: [line("Erasmus", [.customName]), line("Paris", [.pinned]),
                    line("Lille", [.hiddenPhoto]), line("Namur", [.stayOverridden])],
            cityBoundary: false))
        #expect(lines == [
            "12 stays become time at this temporary home.",
            "1 trip will change to separate time here from trips away: Ieper",
            "4 trips will be split into time here and trips away: Erasmus, Paris, Lille and 1 more. Copies stay in Removed Trips on this device.",
            "Favorites stay with the copies in Removed Trips.",
            "1 trip stays as it is: Beringen",
            "No city boundary here, so the area starts as 1 km around the pin. If everyday places nearby show up as trips, use This Wasn't a Trip on one of them.",
        ])
        #expect(Sheet.changeLines(for: preview(split: [line("Erasmus"), line("Paris")])) == [
            "2 trips will be split into time here and trips away: Erasmus, Paris. Copies stay in Removed Trips on this device.",
        ])
    }

    @Test("a kept trip says it stays as it is, and nothing more: a favourite kept by a removal gets no line about keeping its stays for good")
    @MainActor
    func keptTripLineHasNoLastingLine() {
        #expect(Sheet.changeLines(for: preview(leaving: 3, kept: [line("Beringen", [.pinned])]),
                                 areaNote: false) == [
            "3 stays stop counting as time here.",
            "1 trip stays as it is: Beringen",
        ])
        #expect(Sheet.changeLines(for: preview(kept: [line("Beringen"), line("Knokke-Heist")])) == [
            "2 trips stay as they are: Beringen, Knokke-Heist",
        ])
    }

    // MARK: - What a save holds and asks

    @Test("a save holds the trips the preview keeps and the ones it splits, and nothing without a preview")
    func heldTripsAreKeptAndSplit() {
        let kept = line("Beringen", [.pinned])
        let split = line("Erasmus", [.customName])
        let rebuilt = line("Ieper")
        #expect(Sheet.heldTripIDs(preview(rebuilt: [rebuilt], kept: [kept], split: [split]))
                == [kept.id, split.id])
        #expect(Sheet.heldTripIDs(preview(split: [split])) == [split.id])
        #expect(Sheet.heldTripIDs(nil).isEmpty)
    }

    @Test("a split trip alone asks before saving and owes a reconciliation, also for a trip the user already edited; an empty preview does neither")
    func splitTripAsksAndOwes() {
        for reasons in [[TripClassifier.TripInteraction.userEdited], [.pinned], [.customName]] {
            let only = preview(split: [line("Erasmus", reasons)])
            #expect(Sheet.asksBeforeSaving(only), "\(reasons)")
            #expect(Sheet.owesReconciliation(only), "\(reasons)")
        }
        #expect(!Sheet.asksBeforeSaving(preview()))
        #expect(!Sheet.owesReconciliation(preview()))
        // A trip the user edited is kept already: nothing new to ask about.
        #expect(!Sheet.asksBeforeSaving(preview(kept: [line("Beringen", [.userEdited])])))
        #expect(Sheet.asksBeforeSaving(preview(kept: [line("Beringen", [.pinned])])))
        #expect(Sheet.asksBeforeSaving(preview(rebuilt: [line("Ieper")])))
        #expect(Sheet.asksBeforeSaving(preview(merged: [line("Ieper")])))
        #expect(Sheet.asksBeforeSaving(preview(leaving: 1)))
        #expect(!Sheet.asksBeforeSaving(preview(joining: 4)))
    }

    // MARK: - Arrival

    @Test("the arrival is offered when it falls on another day than the picked Since, read in the form's zone, and never past the picked end")
    func arrivalIsOfferedOnAnotherDay() throws {
        let brussels = try zone("Europe/Brussels")
        let today = try utc("2025-07-06T10:00:00Z")
        let arrival = try utc("2025-06-15T12:00:00Z")
        #expect(Sheet.offeredArrival(arrival, since: today, until: nil, in: brussels) == arrival)
        // Since already on that day, at another hour: nothing to offer.
        #expect(Sheet.offeredArrival(
            arrival, since: try utc("2025-06-14T22:30:00Z"), until: nil, in: brussels) == nil)
        // No stay in the area, no arrival.
        #expect(Sheet.offeredArrival(nil, since: today, until: nil, in: brussels) == nil)
        // An arrival after the picked last day is not this stay's.
        let end = try utc("2025-06-01T10:00:00Z")
        #expect(Sheet.offeredArrival(
            arrival, since: try utc("2025-03-02T10:00:00Z"), until: end, in: brussels) == nil)
        // An arrival on the picked last day still is.
        #expect(Sheet.offeredArrival(
            arrival, since: try utc("2025-03-02T10:00:00Z"),
            until: try utc("2025-06-15T05:00:00Z"), in: brussels) == arrival)
    }

    @Test("days are compared in the form's zone: 23:30 UTC is the next day in Brussels and the same day in New York")
    func arrivalDayIsTheZonesDay() throws {
        let arrival = try utc("2025-06-14T23:30:00Z")
        let since = try utc("2025-06-14T12:00:00Z")
        #expect(Sheet.offeredArrival(
            arrival, since: since, until: nil, in: try zone("Europe/Brussels")) == arrival)
        #expect(Sheet.offeredArrival(
            arrival, since: since, until: nil, in: try zone("America/New_York")) == nil)
    }

    @Test("the arrival row names the day in the form's zone")
    func arrivalText() throws {
        let english = Locale(identifier: "en_US")
        let arrival = try utc("2025-06-14T23:30:00Z")
        #expect(Sheet.arrivalText(arrival, in: try zone("Europe/Brussels"), locale: english)
                == "Arrived Jun 15? Use That Date")
        #expect(Sheet.arrivalText(arrival, in: try zone("America/New_York"), locale: english)
                == "Arrived Jun 14? Use That Date")
    }

    @Test("the first recorded stay is shown only while it names another day than Since and the arrival")
    func firstRecordedOnlyWhenItSaysSomethingElse() throws {
        let brussels = try zone("Europe/Brussels")
        let holiday = try utc("2025-05-07T12:00:00Z")
        let arrival = try utc("2025-06-15T12:00:00Z")
        let today = try utc("2025-07-06T10:00:00Z")
        // An earlier holiday: another day than both.
        #expect(Sheet.shownFirstRecorded(holiday, arrival: arrival, since: today, in: brussels)
                == holiday)
        #expect(Sheet.shownFirstRecorded(holiday, arrival: arrival, since: arrival, in: brussels)
                == holiday)
        // The first stay is the arrival: the arrival row or Since says it already.
        #expect(Sheet.shownFirstRecorded(arrival, arrival: arrival, since: today, in: brussels) == nil)
        #expect(Sheet.shownFirstRecorded(arrival, arrival: arrival, since: arrival, in: brussels) == nil)
        // Since was picked on the holiday's day.
        #expect(Sheet.shownFirstRecorded(holiday, arrival: arrival, since: holiday, in: brussels) == nil)
        #expect(Sheet.shownFirstRecorded(nil, arrival: nil, since: today, in: brussels) == nil)
    }

    // MARK: - Review gate

    private func key(changes: Int = 7, endedAt: Date? = nil, favorites: Int = 0) -> Sheet.PreviewKey {
        Sheet.PreviewKey(
            latitude: 50.85, longitude: 4.35, startedAt: Date(timeIntervalSince1970: 1_792_137_600),
            endedAt: endedAt, changes: changes, favorites: favorites)
    }

    @Test("a nil preview for the inputs on screen is a failed review, not an empty one; an empty preview is ready")
    func failedIsNotEmpty() {
        let current = key()
        #expect(Sheet.review(current: current, previewed: current, preview: nil) == .failed)
        #expect(Sheet.review(current: current, previewed: current, preview: preview()) == .ready)
        #expect(Sheet.review(current: nil, previewed: nil, preview: nil) == Sheet.Review.none)
        // A retry clears what was reviewed: checking until it lands.
        #expect(Sheet.review(current: current, previewed: nil, preview: nil) == .checking)
    }

    @Test("a store write changes the key: the preview for the old token is still checking, and a confirmation raised for it cannot commit")
    func staleTokenIsChecking() {
        let old = key(changes: 7)
        let written = key(changes: 8)
        let ready = preview(rebuilt: [line("Ieper")])
        #expect(Sheet.review(current: written, previewed: old, preview: ready) == .checking)
        #expect(!Sheet.confirmationCommits(
            confirmed: old, current: written, previewed: old, preview: ready))
        // Re-run for the new token: still the old confirmation commits nothing.
        #expect(!Sheet.confirmationCommits(
            confirmed: old, current: written, previewed: written, preview: ready))
        #expect(Sheet.confirmationCommits(
            confirmed: written, current: written, previewed: written, preview: ready))
    }

    @Test("a favourite synced while the form is open changes the key: the old review is checking and its confirmation cannot commit")
    func syncedFavouriteIsChecking() {
        let erasmus = UUID()
        let beringen = UUID()
        let before = Sheet.favoritesFingerprint([beringen])
        let after = Sheet.favoritesFingerprint([beringen, erasmus])
        #expect(before != after)
        // A snapshot, not an order: the same set reads the same.
        #expect(Sheet.favoritesFingerprint([erasmus, beringen]) == after)
        #expect(Sheet.favoritesFingerprint(Set([beringen, erasmus])) == Sheet.favoritesFingerprint(Set([erasmus, beringen])))

        let reviewed = key(favorites: before)
        let synced = key(favorites: after)
        let ready = preview(rebuilt: [line("Ieper")])
        #expect(Sheet.review(current: synced, previewed: reviewed, preview: ready) == .checking)
        #expect(!Sheet.confirmationCommits(
            confirmed: reviewed, current: synced, previewed: reviewed, preview: ready))
        // The new review for the synced favourite (now a split) asks again.
        let split = preview(split: [line("Erasmus", [.pinned])])
        #expect(!Sheet.confirmationCommits(
            confirmed: reviewed, current: synced, previewed: synced, preview: split))
        #expect(Sheet.asksBeforeSaving(split))
    }

    @Test("a favourite synced while the Remove confirmation is open forces a fresh read, as a store write does; a failed read commits nothing")
    func removalFollowsFavourites() {
        let erasmus = UUID()
        let before = Sheet.favoritesFingerprint([])
        let after = Sheet.favoritesFingerprint([erasmus])
        let read = Sheet.RemovalKey(changes: 7, favorites: before)
        #expect(Sheet.removalCommits(reviewed: read, current: read))
        // Same store token, another favourite: read again before removing.
        #expect(!Sheet.removalCommits(
            reviewed: read, current: Sheet.RemovalKey(changes: 7, favorites: after)))
        #expect(!Sheet.removalCommits(
            reviewed: read, current: Sheet.RemovalKey(changes: 8, favorites: before)))
        #expect(!Sheet.removalCommits(reviewed: nil, current: read))
    }

    @Test("a confirmation commits only for the key it was raised for, while that key's review succeeded")
    func confirmationNeedsAReadyReview() {
        let current = key()
        let ready = preview(rebuilt: [line("Ieper")])
        #expect(Sheet.confirmationCommits(
            confirmed: current, current: current, previewed: current, preview: ready))
        #expect(!Sheet.confirmationCommits(
            confirmed: nil, current: current, previewed: current, preview: ready))
        #expect(!Sheet.confirmationCommits(
            confirmed: current, current: current, previewed: current, preview: nil))
        #expect(!Sheet.confirmationCommits(
            confirmed: current, current: key(endedAt: Date(timeIntervalSince1970: 1_892_137_600)),
            previewed: current, preview: ready))
    }

    // MARK: - End mode

    @Test("End mode's payload is the narrow end on the last second of the picked day in the stored zone, holding the trips its preview keeps and splits")
    func endingPayloadBoundsAndHolds() throws {
        let id = UUID()
        let kept = line("Beringen", [.pinned])
        let split = line("Erasmus", [.customName])
        // 00:30 on 12 Nov in Brussels, 23:30 on 11 Nov UTC.
        let picked = try utc("2027-11-11T23:30:00Z")
        let payload = Sheet.endingPayload(
            id, lastDay: picked, in: try zone("Europe/Brussels"),
            preview: preview(rebuilt: [line("Ieper")], kept: [kept], split: [split]),
            now: try utc("2027-11-13T09:00:00Z"))
        guard case .end(let ended, let day) = payload.target else {
            Issue.record("not an end: \(payload.target)")
            return
        }
        #expect(ended == id)
        #expect(day == (try utc("2027-11-12T22:59:59Z")))
        #expect(payload.keptTripIDs == [kept.id, split.id])
        #expect(payload.now == (try utc("2027-11-13T09:00:00Z")))
        // The worker reads the same day back in the stored zone.
        #expect(TemporaryHomeSaveWorker.civilDayBounds(of: day, in: try zone("Europe/Brussels")).end
                == day)
    }

    @Test("Extend is the edit form with the end turned off once seeded; Edit keeps the stored end and End always has one")
    func extendTurnsTheEndOff() {
        let id = UUID()
        let stored = Date(timeIntervalSince1970: 1_792_137_600)
        #expect(!Sheet.seededHasEnd(storedEnd: stored, mode: .extend(id: id)))
        #expect(!Sheet.seededHasEnd(storedEnd: nil, mode: .extend(id: id)))
        #expect(Sheet.seededHasEnd(storedEnd: stored, mode: .edit(id: id)))
        #expect(!Sheet.seededHasEnd(storedEnd: nil, mode: .edit(id: id)))
        #expect(Sheet.seededHasEnd(storedEnd: nil, mode: .end(id: id, suggested: nil)))
        // Its own sheet identity: opening Extend never reuses an open Edit or End.
        #expect(Sheet.Mode.extend(id: id).id != Sheet.Mode.edit(id: id).id)
        #expect(Sheet.Mode.extend(id: id).id != Sheet.Mode.end(id: id, suggested: nil).id)
    }

    @Test("End mode has its own sheet identity, apart from editing the same temporary home")
    func endModeIdentity() {
        let id = UUID()
        #expect(Sheet.Mode.end(id: id, suggested: nil).id != Sheet.Mode.edit(id: id).id)
        #expect(Sheet.Mode.end(id: id, suggested: .now).id == Sheet.Mode.end(id: id, suggested: nil).id)
    }
}
