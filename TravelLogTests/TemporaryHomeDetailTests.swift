//
//  TemporaryHomeDetailTests.swift
//  TravelLogTests
//
//  The pure decisions behind a temporary home's card and detail page: what
//  Keep as One Trip tells the user for each outcome (shared with Removed
//  Trips), which split trips the detail lists, when "Updating trips…" shows,
//  and that the card's actions reach the list's own sheet through a closure.
//

import Foundation
import Testing
@testable import TravelLog

@MainActor
@Suite("Temporary home detail")
struct TemporaryHomeDetailTests {

    private let base = UUID()

    private func date(day: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: 800_000_000 + day * 86_400)
    }

    private func record(
        id: UUID = UUID(), dissolvedOn day: Double, name: String, splitBy: UUID?
    ) -> DissolvedTripRecord {
        var record = DissolvedTripRecord(
            id: id, dissolvedAt: date(day: day), displayName: name,
            startDate: date(day: day - 40), endDate: date(day: day - 1),
            isComplete: true,
            destinationSummary: name, countryCodes: "BE",
            classifiedByAI: false, aiGeneratedTitle: nil,
            aiGeneratedSummary: nil, summarySourceRaw: nil,
            sourceRaw: DataSource.liveSLC.rawValue,
            customName: name, userEdited: true,
            stays: [.init(id: UUID(), categoryRaw: "destination", orderInTrip: 0)])
        record.splitByTemporaryHomeID = splitBy
        return record
    }

    private func card(
        id: UUID, state: TemporaryHomeCards.Card.State = .active, suggestedEnd: Date? = nil
    ) -> TemporaryHomeCards.Card {
        TemporaryHomeCards.Card(
            id: id, title: "Erasmus", placeLine: "Brussels, Belgium", countryCode: "BE",
            startedAt: date(day: 0), endedAt: nil, timeZoneIdentifier: "UTC", state: state,
            dayNumber: 10, awayDays: 0, stayingDays: 0, tripIDs: [], tripCountryCodes: [],
            visitsHome: [], suggestedEnd: suggestedEnd,
            backHomeSince: suggestedEnd.map { $0.addingTimeInterval(86_400) })
    }

    // MARK: - Keep as One Trip wording

    @Test("a kept trip is confirmed by name")
    func keptIsConfirmed() {
        let alert = KeepAsOneTripAlert(outcome: .kept, tripName: "Erasmus")
        #expect(alert.title == "Kept as One Trip")
        #expect(alert.message == "“Erasmus” is one trip again.")
    }

    @Test("a blocked keep names everything that changed since the split")
    func blockedNamesTheReasons() {
        let alert = KeepAsOneTripAlert(
            outcome: .blocked(reasons: ["Weekend in Beringen", "Dendermonde"]), tripName: "Erasmus",
            locale: Locale(identifier: "en_US"))
        #expect(alert.title == "Can't Keep as One Trip")
        #expect(alert.message
            == "These trips or places changed since the split, so it can't be put back together: Weekend in Beringen and Dendermonde.")
    }

    @Test("missing stays may still be syncing; conflicting copies are said as such, with no promise that syncing fixes them")
    func missingAndAmbiguousStaysSayDifferentThings() {
        let missing = KeepAsOneTripAlert(outcome: .staysMissing, tripName: "Erasmus")
        let ambiguous = KeepAsOneTripAlert(outcome: .staysAmbiguous, tripName: "Erasmus")
        #expect(missing != ambiguous)
        #expect(missing.title == "Can't Keep as One Trip")
        #expect(ambiguous.title == "Can't Keep as One Trip")
        #expect(missing.message
            == "Some location history for “Erasmus” is missing on this device. If iCloud is syncing, try again later.")
        #expect(ambiguous.message
            == "The location history for “Erasmus” has conflicting copies, so it can't be put back together yet.")
        // The same outcome twice reads the same, so a second attempt raises the same alert.
        #expect(KeepAsOneTripAlert(outcome: .staysMissing, tripName: "Erasmus") == missing)
    }

    @Test("a failed save is the shared save alert, with no message")
    func saveFailureIsTheSharedAlert() {
        let alert = KeepAsOneTripAlert(outcome: .saveFailed, tripName: "Erasmus")
        #expect(alert.title == "Couldn't save. Try again")
        #expect(alert.message == nil)
    }

    @Test("only a failure is an error: a kept trip is not")
    func onlyFailuresAreErrors() {
        #expect(!KeepAsOneTripAlert(outcome: .kept, tripName: "A").isFailure)
        for outcome: TripClassifier.KeepSplitOutcome in [
            .blocked(reasons: ["B"]), .staysMissing, .staysAmbiguous, .saveFailed,
        ] {
            #expect(KeepAsOneTripAlert(outcome: outcome, tripName: "A").isFailure)
        }
    }

    // MARK: - Split Trips

    @Test("the detail lists only the trips this temporary home split, newest split first")
    func splitTripsAreThisHomesNewestFirst() {
        let other = UUID()
        let older = record(dissolvedOn: 10, name: "Semester", splitBy: base)
        let newer = record(dissolvedOn: 30, name: "Erasmus", splitBy: base)
        let elsewhere = record(dissolvedOn: 40, name: "Vienna", splitBy: other)
        let healed = record(dissolvedOn: 50, name: "Near home", splitBy: nil)

        let listed = TemporaryHomeDetailView.splitTrips(
            [older, healed, newer, elsewhere], temporaryHomeID: base)
        #expect(listed.map(\.id) == [newer.id, older.id])
        #expect(TemporaryHomeDetailView.splitTrips([healed, elsewhere], temporaryHomeID: base).isEmpty)
    }

    // MARK: - Updating trips

    @Test("Updating trips shows while this temporary home's reconciliation is owed, and goes once it drains")
    func updatingFollowsTheQueue() throws {
        let suite = "TemporaryHomeDetailTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(CoverageReconciliationQueue.temporaryHomeStatus(id: base, defaults: defaults) == nil)

        let owed = CoverageReconciliationQueue.enqueue(.temporaryHome, id: base, defaults: defaults)
        // Another temporary home's debt.
        CoverageReconciliationQueue.enqueue(.temporaryHome, id: UUID(), defaults: defaults)
        #expect(CoverageReconciliationQueue.temporaryHomeStatus(id: base, defaults: defaults) == .updating)
        #expect(CoverageReconciliationQueue.temporaryHomeStatus(id: UUID(), defaults: defaults) == nil)

        CoverageReconciliationQueue.complete(owed, defaults: defaults)
        #expect(CoverageReconciliationQueue.temporaryHomeStatus(id: base, defaults: defaults) == nil)
    }

    @Test("a Home or routine place owed under the same id is not this temporary home's work")
    func otherKindsAreNotUpdating() throws {
        let suite = "TemporaryHomeDetailTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        CoverageReconciliationQueue.enqueue(.home, id: base, defaults: defaults)
        CoverageReconciliationQueue.enqueue(.routinePlace, id: base, defaults: defaults)
        #expect(CoverageReconciliationQueue.temporaryHomeStatus(id: base, defaults: defaults) == nil)
    }

    @Test("updating spins, waiting and failure do not; only a failure offers Try Again")
    func statusLineWording() {
        #expect(TemporaryHomeUpdatingLine.text(for: .updating) == "Updating trips…")
        #expect(TemporaryHomeUpdatingLine.text(for: .waiting) == "Waiting to update trips.")
        #expect(TemporaryHomeUpdatingLine.text(for: .failed) == "Couldn't update trips.")
        #expect(TemporaryHomeUpdatingLine.retryTitle == "Try Again")
        #expect(!TemporaryHomeUpdatingLine.offersRetry(.updating))
        #expect(!TemporaryHomeUpdatingLine.offersRetry(.waiting))
        #expect(TemporaryHomeUpdatingLine.offersRetry(.failed))
    }

    // MARK: - Split Trips reads

    private struct ReadFailed: Error {}

    @Test("a failed read keeps the last list and says so; Try Again restores the current list")
    func failedSplitTripsReadKeepsTheList() {
        let first = record(dissolvedOn: 10, name: "Semester", splitBy: base)
        let second = record(dissolvedOn: 20, name: "Erasmus", splitBy: base)

        let loaded = TemporaryHomeDetailView.splitTripsAfterLoad(
            .success([first]), previous: [], temporaryHomeID: base)
        #expect(loaded.records.map(\.id) == [first.id])
        #expect(!loaded.failed)

        let failed = TemporaryHomeDetailView.splitTripsAfterLoad(
            .failure(ReadFailed()), previous: loaded.records, temporaryHomeID: base)
        #expect(failed.records.map(\.id) == [first.id])
        #expect(failed.failed)

        let retried = TemporaryHomeDetailView.splitTripsAfterLoad(
            .success([first, second]), previous: failed.records, temporaryHomeID: base)
        #expect(retried.records.map(\.id) == [second.id, first.id])
        #expect(!retried.failed)

        // A failure with nothing read yet still flags the section, to offer Try Again.
        #expect(TemporaryHomeDetailView.splitTripsAfterLoad(
            .failure(ReadFailed()), previous: [], temporaryHomeID: base).failed)
    }

    @Test("the throwing read throws on an unreadable file where the best-effort read says empty; a missing file is empty")
    func throwingReadTellsFailureFromEmpty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TemporaryHomeDetailTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try DissolvedTripQueue.loadThrowing(from: directory).isEmpty)

        let kept = record(dissolvedOn: 10, name: "Semester", splitBy: base)
        try DissolvedTripQueue.append([kept], in: directory)
        #expect(try DissolvedTripQueue.loadThrowing(from: directory).map(\.id) == [kept.id])

        let url = try #require(DissolvedTripQueue.fileURL(in: directory))
        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try DissolvedTripQueue.loadThrowing(from: directory) }
        #expect(DissolvedTripQueue.load(from: directory).isEmpty)
    }

    // MARK: - Card actions

    @Test("Extend opens the form's extend mode and End opens the end form with the suggested day")
    func actionModes() {
        let suggested = date(day: 20)
        let hinted = card(id: base, suggestedEnd: suggested)

        guard case .extend(let editID) = TemporaryHomeCardRow.extendMode(for: hinted) else {
            Issue.record("Extend must open the extend form")
            return
        }
        #expect(editID == base)

        guard case .end(let endID, let day) = TemporaryHomeCardRow.endMode(for: hinted) else {
            Issue.record("End must open the end form")
            return
        }
        #expect(endID == base)
        #expect(day == suggested)

        // With no hint, End opens the form with no day: it presets today.
        guard case .end(_, let none) = TemporaryHomeCardRow.endMode(for: card(id: base)) else {
            Issue.record("End must open the end form")
            return
        }
        #expect(none == nil)
    }

    @Test("the card row presents no sheet of its own; its actions go to the list through a closure")
    func rowRoutesThroughTheList() {
        var presented: [String] = []
        let row = TemporaryHomeCardRow(card: card(id: base, suggestedEnd: date(day: 20))) {
            presented.append($0.id)
        }
        // A row-owned sheet would be lost when a reload moves the row to another section.
        let stored = Mirror(reflecting: row).children.compactMap(\.label)
        #expect(!stored.contains { $0.localizedCaseInsensitiveContains("sheet") })

        row.presentForm(TemporaryHomeCardRow.extendMode(for: row.card))
        row.presentForm(TemporaryHomeCardRow.endMode(for: row.card))
        #expect(presented == [
            TemporaryHomeCardRow.extendMode(for: row.card).id, TemporaryHomeCardRow.endMode(for: row.card).id,
        ])
    }
}
