//
//  StoreChangeTrackerTests.swift
//  TravelLogTests
//
//  Phase 0 of the heat-architecture rework:
//  the per-entity-type change signal that replaces the single global DataEpoch.
//  These tests pin the two properties every downstream gate relies on:
//    1. token(for:) is PRECISE — a bump to type A never advances a token that
//       selects only type B (that precision is what makes gating non-stale).
//    2. bump(...) COALESCES a burst into one increment per affected type, while
//       accumulating the UNION of types touched in the window.
//
//  Isolation: like PipelineGate, StoreChangeTracker.shared is a process-global
//  singleton. Every test uses a FRESH instance via the DEBUG-only
//  init(forTesting:) so it never observes or mutates the shared generations.
//

import Testing
import Foundation
import UIKit
@testable import TravelLog

@MainActor
@Suite("StoreChangeTracker signal")
struct StoreChangeTrackerTests {

    // MARK: - token(for:) precision (synchronous apply path)

    @Test("A single-type change advances only tokens that select that type")
    func singleTypePrecision() {
        let t = StoreChangeTracker(forTesting: ())
        t.applyNowForTesting(.stay)

        #expect(t.token(for: .stay) == 1)
        #expect(t.token(for: [.stay, .trip]) == 1)   // selected set includes .stay
        #expect(t.token(for: .trip) == 0)            // .trip untouched
        #expect(t.token(for: .hexVisit) == 0)        // unrelated type untouched
    }

    @Test("An unrelated change never advances a disjoint token")
    func disjointIsolation() {
        let t = StoreChangeTracker(forTesting: ())
        let before = t.token(for: [.stay, .trip])
        t.applyNowForTesting(.hexVisit)

        #expect(t.token(for: [.stay, .trip]) == before)  // no false invalidation
        #expect(t.token(for: .hexVisit) == 1)
    }

    @Test("Repeated changes to one type are monotonic")
    func monotonic() {
        let t = StoreChangeTracker(forTesting: ())
        t.applyNowForTesting(.stay)
        t.applyNowForTesting(.stay)
        #expect(t.token(for: .stay) == 2)
    }

    @Test(".all advances every tracked generation once")
    func allAdvancesEverything() {
        let t = StoreChangeTracker(forTesting: ())
        t.applyNowForTesting(.all)
        // token(.all) sums all 14 per-type counters, each now 1.
        #expect(t.token(for: .all) == 14)
        // And every individual type advanced.
        for one: StoreChange in [.stay, .trip, .locationPing, .hexVisit, .plannedTrip,
                                 .home, .routinePlace, .photoImportState,
                                 .hiddenPhoto, .pinnedPhoto, .yearWrapped,
                                 .homeAreaOverride, .visit, .temporaryHome] {
            #expect(t.token(for: one) == 1)
        }
    }

    @Test("A multi-type change advances each selected type exactly once")
    func multiTypeApply() {
        let t = StoreChangeTracker(forTesting: ())
        t.applyNowForTesting([.stay, .trip, .locationPing])
        #expect(t.token(for: .stay) == 1)
        #expect(t.token(for: .trip) == 1)
        #expect(t.token(for: .locationPing) == 1)
        #expect(t.token(for: .hexVisit) == 0)
        #expect(t.token(for: [.stay, .trip, .locationPing]) == 3)
    }

    // MARK: - bump(...) debounce + union (deterministic flush seam)
    //
    // These drive the real bump() accumulation, then force the flush via the
    // DEBUG seam instead of a wall-clock wait. The methods are synchronous, so
    // the 500 ms scheduled Task cannot fire mid-test (the MainActor never
    // suspends), making assertions race-free; the stray timer later flushes an
    // already-empty pending set (a harmless no-op).

    @Test("Empty bump is a no-op and accumulates nothing")
    func emptyBumpNoOp() {
        let t = StoreChangeTracker(forTesting: ())
        t.bump([])
        t.flushPendingForTesting()
        #expect(t.token(for: .all) == 0)
    }

    @Test("A burst of same-type bumps collapses to ONE increment")
    func debounceCoalesces() {
        let t = StoreChangeTracker(forTesting: ())
        t.bump(.stay)
        t.bump(.stay)
        t.bump(.stay)
        t.flushPendingForTesting()
        #expect(t.token(for: .stay) == 1)   // three bumps, one flush
    }

    @Test("Bumps within one window accumulate the UNION of their types")
    func debounceUnionsTypes() {
        let t = StoreChangeTracker(forTesting: ())
        t.bump(.stay)
        t.bump(.trip)          // different type, same debounce window
        t.flushPendingForTesting()
        #expect(t.token(for: .stay) == 1)
        #expect(t.token(for: .trip) == 1)
        #expect(t.token(for: .hexVisit) == 0)
    }

    @Test("Separate windows each produce their own increment")
    func separateWindowsAdvanceAgain() {
        let t = StoreChangeTracker(forTesting: ())
        t.bump(.stay)
        t.flushPendingForTesting()
        t.bump(.stay)
        t.flushPendingForTesting()
        #expect(t.token(for: .stay) == 2)
    }

    /// Smoke test that the REAL 500 ms debounce timer eventually flushes.
    /// Polls (up to ~3 s) rather than asserting at a fixed deadline, so it is
    /// not flaky under parallel MainActor scheduling.
    @Test("bump() eventually flushes via its real timer")
    func realTimerEventuallyFlushes() async throws {
        let t = StoreChangeTracker(forTesting: ())
        t.bump(.stay)
        var waited = 0
        while t.token(for: .stay) == 0 && waited < 3000 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 50
        }
        #expect(t.token(for: .stay) == 1)
    }

    // MARK: - The Spotlight piggyback is foreground-only

    /// Red/green pin: `AppDelegate` defers its heavy
    /// launch backfills on a background SLC relaunch so a wake-ping save is
    /// never queued behind them — "a background SLC relaunch shouldn't pay for
    /// index work" — but the piggyback fired anyway, because the launch dedup
    /// chain bumps `.trip` from `PhotoImportPingDeduplicator`'s own gate unit
    /// and `PipelineGate.run` bumps unconditionally. Guarding the AppDelegate
    /// bump site does NOT close it; this rule is the choke point.
    ///
    /// Nothing is lost by skipping: the indexer's donated-content token is
    /// persisted, so the next foreground `.trip` flush donates what accrued.
    @Test("Spotlight donation needs BOTH a .trip flush and a non-background app")
    func spotlightDonationIsForegroundOnly() {
        #expect(!StoreChangeTracker.shouldDonateSpotlight(
            flushed: .trip, applicationState: .background))
        #expect(!StoreChangeTracker.shouldDonateSpotlight(
            flushed: .all, applicationState: .background))

        // Foreground still donates — deferral, not suppression.
        #expect(StoreChangeTracker.shouldDonateSpotlight(
            flushed: .trip, applicationState: .active))
        #expect(StoreChangeTracker.shouldDonateSpotlight(
            flushed: .all, applicationState: .active))
        // `.inactive` is a foreground state (launch transitions through it).
        #expect(StoreChangeTracker.shouldDonateSpotlight(
            flushed: .trip, applicationState: .inactive))

        // The pre-existing rule is unchanged: no .trip, no donation.
        #expect(!StoreChangeTracker.shouldDonateSpotlight(
            flushed: [.stay, .locationPing], applicationState: .active))
        #expect(!StoreChangeTracker.shouldDonateSpotlight(
            flushed: [], applicationState: .active))
    }

    @Test("Deferred Spotlight is repaid once by an unrelated foreground flush")
    func deferredSpotlightUnrelatedFlush() {
        let tracker = StoreChangeTracker(forTesting: ())
        var requests = 0
        for (changes, state): (StoreChange, UIApplication.State) in [
            (.trip, .background), (.all, .background), (.stay, .background),
            (.stay, .active), (.hexVisit, .active), ([], .active)
        ] {
            if tracker.consumeSpotlightRefresh(flushed: changes, applicationState: state) {
                requests += 1
            }
        }
        #expect(requests == 1)
        #expect(tracker.token(for: .all) == 0)
    }

    @Test("Foreground activation repays deferred Spotlight without store publication")
    func deferredSpotlightActivation() {
        let tracker = StoreChangeTracker(forTesting: ())
        #expect(!tracker.consumeSpotlightRefresh(flushed: .trip, applicationState: .background))
        #expect(!tracker.consumeSpotlightRefresh(flushed: [], applicationState: .background))
        #expect(tracker.consumeSpotlightRefresh(flushed: [], applicationState: .active))
        #expect(!tracker.consumeSpotlightRefresh(flushed: [], applicationState: .active))
        #expect(!tracker.consumeSpotlightRefresh(flushed: .stay, applicationState: .active))
        #expect(tracker.token(for: .all) == 0)
    }

    @Test("A recorded bump is pending only for its own types until the flush")
    func pendingBumpUntilFlush() {
        let tracker = StoreChangeTracker(forTesting: ())
        #expect(!tracker.hasPendingBump(.locationPing))
        tracker.bump(.locationPing)
        #expect(tracker.hasPendingBump(.locationPing))
        #expect(tracker.hasPendingBump([.stay, .locationPing]))
        #expect(!tracker.hasPendingBump(.stay))
        tracker.flushPendingForTesting()
        #expect(!tracker.hasPendingBump(.locationPing))
        #expect(tracker.token(for: .locationPing) == 1)
    }

}
