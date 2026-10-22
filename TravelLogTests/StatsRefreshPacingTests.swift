//
//  StatsRefreshPacingTests.swift
//  TravelLogTests
//
//  Which store types restart the Stats refresh, and when a restarted
//  refresh waits out a burst: only a warm, on-screen restart that store
//  bumps alone caused is debounced. A cold page, a clear, a revocation, a
//  civil-day or zone change and an appearance compute at once.
//

import Foundation
import Testing
@testable import TravelLog

@MainActor
struct StatsRefreshPacingTests {

    private let utc = TimeZone(identifier: "UTC")!
    private let instant = Date(timeIntervalSince1970: 1_750_000_000)

    private func identity(_ storeToken: Int, now: Date? = nil, timeZone: TimeZone? = nil) -> StatsRefreshIdentity {
        StatsRefreshIdentity(storeToken: storeToken, now: now ?? instant, timeZone: timeZone ?? utc)
    }

    /// A ledger whose last complete compute is `completed` at `generation`.
    private func warmLedger(_ completed: StatsRefreshIdentity, generation: Int = 3) -> StatsRefreshLedger {
        var ledger = StatsRefreshLedger()
        _ = ledger.conclude(
            completed, computedAt: generation, currentToken: completed, currentGeneration: generation,
            computeDegraded: nil, pendingSaveOwed: false)
        return ledger
    }

    private func delay(
        _ current: StatsRefreshIdentity, ledger: StatsRefreshLedger,
        observed: Int = 3, currentGeneration: Int = 3, onScreen: Bool = true
    ) -> Duration? {
        StatsRefreshPacing.delayBeforeFirstPass(
            current: current, observedClearGeneration: observed,
            currentClearGeneration: currentGeneration, ledger: ledger,
            restartedOnScreen: onScreen)
    }

    @Test("live pings do not restart the refresh; every other rendered type and a remote push do")
    func triggerSet() {
        let observed = StatsRefreshPacing.observedChanges
        #expect(!observed.contains(.locationPing))
        #expect(observed.isSuperset(of: [.stay, .trip, .hexVisit, .home, .temporaryHome, .visit]))

        let tracker = StoreChangeTracker(forTesting: ())
        let start = tracker.token(for: observed)
        tracker.applyNowForTesting([.locationPing])
        #expect(tracker.token(for: observed) == start)
        // A live batch that enters a new cell still refreshes through `.hexVisit`.
        tracker.applyNowForTesting([.locationPing, .hexVisit])
        let afterCell = tracker.token(for: observed)
        #expect(afterCell != start)
        // Historical writers declare `.stay` with their pings; CloudKit and wipes declare `.all`.
        tracker.applyNowForTesting([.locationPing, .stay, .trip])
        let afterImport = tracker.token(for: observed)
        #expect(afterImport != afterCell)
        tracker.applyNowForTesting(.all)
        #expect(tracker.token(for: observed) != afterImport)
    }

    @Test("a Visit-only closure restarts flight bounds without enabling ping-only refreshes")
    func linkedVisitClosureRestartsRefresh() {
        let observed = StatsRefreshPacing.observedChanges
        let tracker = StoreChangeTracker(forTesting: ())
        let before = tracker.token(for: observed)
        let completed = identity(before)
        var ledger = warmLedger(completed)

        // The delayed CLVisit departure updates the linked Visit without
        // changing its stay; flight bounds must re-read that closed endpoint.
        tracker.applyNowForTesting([.visit])
        let afterClosure = tracker.token(for: observed)
        #expect(afterClosure != before)
        #expect(ledger.begin(identity(afterClosure), currentGeneration: 3) == .refresh(revoked: false))

        tracker.applyNowForTesting([.locationPing])
        #expect(tracker.token(for: observed) == afterClosure)
    }

    @Test("a warm on-screen restart caused only by store bumps waits out the burst")
    func warmStoreBumpIsDebounced() {
        let ledger = warmLedger(identity(7))
        #expect(delay(identity(8), ledger: ledger) == StatsRefreshPacing.warmDebounce)
        #expect(StatsRefreshPacing.warmDebounce >= .seconds(2))
        #expect(StatsRefreshPacing.warmDebounce <= .seconds(3))
    }

    @Test("the cold first compute, a hydrated-only page and an unfinished refresh start at once")
    func coldAndUnfinishedStartAtOnce() {
        #expect(delay(identity(8), ledger: StatsRefreshLedger()) == nil)

        var hydrated = StatsRefreshLedger()
        hydrated.acceptHydrated(generation: 3)
        #expect(delay(identity(8), ledger: hydrated) == nil)

        var owedSave = StatsRefreshLedger()
        _ = owedSave.conclude(
            identity(7), computedAt: 3, currentToken: identity(7), currentGeneration: 3,
            computeDegraded: nil, pendingSaveOwed: true)
        #expect(owedSave.hasCompleteAggregates(currentGeneration: 3))
        #expect(delay(identity(8), ledger: owedSave) == nil)
    }

    @Test("a clear, observed or not yet observed, and a revoked page start at once")
    func clearsStartAtOnce() {
        let ledger = warmLedger(identity(7))
        // Clear landed, the observer has not adopted it yet.
        #expect(delay(identity(8), ledger: ledger, observed: 3, currentGeneration: 4) == nil)
        // Clear adopted into the task key, ledger not yet revoked.
        #expect(delay(identity(8), ledger: ledger, observed: 4, currentGeneration: 4) == nil)
        // Clear adopted and revoked.
        var revoked = ledger
        let didRevoke = revoked.revokeIfCleared(currentGeneration: 4)
        #expect(didRevoke)
        #expect(delay(identity(8), ledger: revoked, observed: 4, currentGeneration: 4) == nil)
        // A clear-only restart with an unchanged store token.
        #expect(delay(identity(7), ledger: ledger, observed: 4, currentGeneration: 4) == nil)
    }

    @Test("a civil-day or zone change starts at once, even with a store bump")
    func dayChangeStartsAtOnce() {
        let ledger = warmLedger(identity(7))
        let nextDay = instant.addingTimeInterval(86_400)
        #expect(delay(identity(7, now: nextDay), ledger: ledger) == nil)
        #expect(delay(identity(8, now: nextDay), ledger: ledger) == nil)
        let east = TimeZone(secondsFromGMT: 14 * 3600)!
        #expect(delay(identity(8, timeZone: east), ledger: ledger) == nil)
    }

    @Test("an appearance and an up-to-date restart never wait")
    func appearanceAndUpToDateStartAtOnce() {
        let ledger = warmLedger(identity(7))
        #expect(delay(identity(8), ledger: ledger, onScreen: false) == nil)
        #expect(delay(identity(7), ledger: ledger) == nil)
    }
}
