//
//  StoreChangeTracker.swift
//  TravelLog
//

import Foundation
import SwiftData
import UIKit

/// Per-entity-type "what changed in the store" signal, emitted from the
/// store-mutation chokepoint (`PipelineGate`) plus the CloudKit remote handler.
///
/// One monotonic generation per `@Model` type, so a consumer can recompute
/// only when the specific types it renders actually change — instead of on
/// every unrelated save.
///
/// # Trust model
/// - Local writes go through `PipelineGate.run(touching:)`, which declares the
///   types it mutated — a PRECISE signal (the writer knows what it wrote).
/// - Remote CloudKit pushes are contentless, so the remote handler bumps
///   `.all` — FAIL-OPEN (over-broad, but never stale).
/// - Callers over-declare when unsure: over-declaring costs one extra recompute,
///   under-declaring risks stale UI, so the bias is always toward more types.
/// - The live ping unit and the foreground fast path instead publish the set
///   derived from their context (`StoreChange.pending(in:)`) before each save.
///
/// Bumps are debounced (500 ms) and accumulate a UNION of pending types, so a
/// sync/import burst collapses into one downstream recompute per affected type.

/// The set of `@Model` types a store mutation touched. Pure value type shared
/// across `@Sendable` boundaries, hence `nonisolated` (matches the codebase
/// pattern for value types used off the MainActor).
nonisolated struct StoreChange: OptionSet, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let stay             = StoreChange(rawValue: 1 << 0)
    static let trip             = StoreChange(rawValue: 1 << 1)
    static let locationPing     = StoreChange(rawValue: 1 << 2)
    static let hexVisit         = StoreChange(rawValue: 1 << 3)
    static let plannedTrip      = StoreChange(rawValue: 1 << 4)
    static let home             = StoreChange(rawValue: 1 << 5)
    static let routinePlace     = StoreChange(rawValue: 1 << 6)
    static let photoImportState = StoreChange(rawValue: 1 << 7)
    static let hiddenPhoto      = StoreChange(rawValue: 1 << 8)
    static let pinnedPhoto      = StoreChange(rawValue: 1 << 9)
    static let yearWrapped      = StoreChange(rawValue: 1 << 10)
    static let homeAreaOverride = StoreChange(rawValue: 1 << 11)
    static let visit            = StoreChange(rawValue: 1 << 12)
    static let temporaryHome    = StoreChange(rawValue: 1 << 13)

    /// Every tracked type. The fail-open default for `PipelineGate.run` and the
    /// signal the CloudKit remote handler emits (contentless push).
    static let all: StoreChange = [
        .stay, .trip, .locationPing, .hexVisit, .plannedTrip, .home,
        .routinePlace, .photoImportState, .hiddenPhoto, .pinnedPhoto, .yearWrapped,
        .homeAreaOverride, .visit, .temporaryHome,
    ]

    /// The tracked types `context`'s unsaved inserts, updates and deletes touch.
    /// Take it immediately before each save (the arrays are empty after it). A
    /// title variant is part of its trip. A deleted stay, or an inserted or
    /// changed stay that has a trip, also changes that trip. Any other model type
    /// fails open to `.all`. Only for units whose every write goes through
    /// `context` and that never detach a stay from a trip without deleting it.
    static func pending(in context: ModelContext) -> StoreChange {
        var changes: StoreChange = []
        func note(_ model: any PersistentModel, deleted: Bool) {
            switch model {
            case let stay as Stay:
                changes.insert(.stay)
                // Never read a property of a deleted model.
                if deleted || stay.trip != nil { changes.insert(.trip) }
            case is Trip, is TripTitleVariant: changes.insert(.trip)
            case is LocationPing: changes.insert(.locationPing)
            case is HexVisit: changes.insert(.hexVisit)
            case is PlannedTrip: changes.insert(.plannedTrip)
            case is Home: changes.insert(.home)
            case is RoutinePlace: changes.insert(.routinePlace)
            case is PhotoImportState: changes.insert(.photoImportState)
            case is HiddenPhoto: changes.insert(.hiddenPhoto)
            case is PinnedPhoto: changes.insert(.pinnedPhoto)
            case is YearWrapped: changes.insert(.yearWrapped)
            case is HomeAreaOverride: changes.insert(.homeAreaOverride)
            case is Visit: changes.insert(.visit)
            case is TemporaryHome: changes.insert(.temporaryHome)
            default: changes.formUnion(.all)
            }
        }
        for model in context.insertedModelsArray { note(model, deleted: false) }
        for model in context.changedModelsArray { note(model, deleted: false) }
        for model in context.deletedModelsArray { note(model, deleted: true) }
        return changes
    }
}

@MainActor
@Observable
final class StoreChangeTracker {

    static let shared = StoreChangeTracker()
    private init() {}

    #if DEBUG
    /// Test-only: a fresh, isolated tracker so unit tests never mutate the
    /// process-global `shared` generations. Mirrors `PipelineGate(forTesting:)`.
    init(forTesting: Void) {}
    #endif

    // One observed generation per `@Model` type. These are SEPARATE stored
    // properties (not a dictionary) on purpose: SwiftUI's `@Observable` tracks
    // dependencies per stored property, so a consumer that reads only `stay`
    // via `token(for: [.stay])` is NOT invalidated by a `.hexVisit` bump. A
    // dictionary read would register a dependency on the whole map and defeat
    // the per-type granularity that makes this worth doing.
    private(set) var stay = 0
    private(set) var trip = 0
    private(set) var locationPing = 0
    private(set) var hexVisit = 0
    private(set) var plannedTrip = 0
    private(set) var home = 0
    private(set) var routinePlace = 0
    private(set) var photoImportState = 0
    private(set) var hiddenPhoto = 0
    private(set) var pinnedPhoto = 0
    private(set) var yearWrapped = 0
    private(set) var homeAreaOverride = 0
    private(set) var visit = 0
    private(set) var temporaryHome = 0

    /// Monotonic token that advances whenever ANY selected type bumps. Reads
    /// only the selected counters, so using it as a `.task(id:)` key restarts
    /// the task exactly when one of those types changes — and never otherwise.
    func token(for changes: StoreChange) -> Int {
        var t = 0
        if changes.contains(.stay) { t &+= stay }
        if changes.contains(.trip) { t &+= trip }
        if changes.contains(.locationPing) { t &+= locationPing }
        if changes.contains(.hexVisit) { t &+= hexVisit }
        if changes.contains(.plannedTrip) { t &+= plannedTrip }
        if changes.contains(.home) { t &+= home }
        if changes.contains(.routinePlace) { t &+= routinePlace }
        if changes.contains(.photoImportState) { t &+= photoImportState }
        if changes.contains(.hiddenPhoto) { t &+= hiddenPhoto }
        if changes.contains(.pinnedPhoto) { t &+= pinnedPhoto }
        if changes.contains(.yearWrapped) { t &+= yearWrapped }
        if changes.contains(.homeAreaOverride) { t &+= homeAreaOverride }
        if changes.contains(.visit) { t &+= visit }
        if changes.contains(.temporaryHome) { t &+= temporaryHome }
        return t
    }

    /// Whether a write to any of `changes` is recorded but not yet flushed.
    func hasPendingBump(_ changes: StoreChange) -> Bool {
        !pending.isDisjoint(with: changes)
    }

    @ObservationIgnored private var pending: StoreChange = []
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var spotlightRefreshPending = false

    /// Record that `changes` were written. Debounced 500 ms; pending types
    /// accumulate as a union and all advance once at flush, so a burst of gated
    /// units collapses to one recompute per affected type.
    func bump(_ changes: StoreChange) {
        guard !changes.isEmpty else { return }
        // The title pipeline's home-place index caches home stays, Home rows
        // and temporary homes per container; a write to any makes it stale.
        if !changes.isDisjoint(with: [.stay, .home, .temporaryHome]) {
            TripTitleStore.invalidateHomePlaceIndex()
        }
        pending.formUnion(changes)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            self.flushPending()
        }
    }

    /// Apply the accumulated pending union and reset the window.
    private func flushPending() {
        let flushed = pending
        pending = []
        flushScheduled = false
        apply(flushed)

        // Spotlight piggyback: the donated trip index's content (title,
        // destinationSummary, endDate, summary) is all `Trip`-stored, so it
        // needs refreshing exactly when the `.trip` generation advanced — not
        // on a wake-ping save or a calendar scan. The indexer has its own
        // debounce + a persisted content-token gate, so an unchanged trip set
        // still donates nothing.
        //
        // FOREGROUND ONLY. `AppDelegate` defers its
        // heavy launch backfills on a background SLC relaunch precisely so a
        // wake-ping save is never queued behind them — "a background SLC
        // relaunch shouldn't pay for index work" — but this piggyback fired
        // anyway, because the launch dedup chain bumps `.trip` from
        // `PhotoImportPingDeduplicator`'s own gate unit and `PipelineGate.run`
        // bumps unconditionally. Guarding at the AppDelegate bump site does
        // not close it; this is the choke point every path funnels through.
        //
        // Retain a background-skipped request in memory. The next foreground
        // flush of any type or RootView activation repays it without publishing
        // unrelated store changes. A foreground cold launch requests its own
        // refresh, covering process termination before repayment. The indexer's
        // persisted digest still suppresses unchanged-content re-donation.
        if consumeSpotlightRefresh(
            flushed: flushed, applicationState: UIApplication.shared.applicationState
        ) {
            Task { await SpotlightIndexer.shared.requestRefresh() }
        }
    }

    /// Called by RootView for both initial and subsequent active scenes.
    func applicationDidBecomeActive() {
        if consumeSpotlightRefresh(flushed: [], applicationState: .active) {
            Task { await SpotlightIndexer.shared.requestRefresh() }
        }
    }

    /// Consume the donation decision synchronously on MainActor, before the
    /// indexer hop, so overlapping foreground opportunities repay only once.
    func consumeSpotlightRefresh(flushed: StoreChange, applicationState: UIApplication.State) -> Bool {
        spotlightRefreshPending = spotlightRefreshPending || flushed.contains(.trip)
        guard Self.shouldDonateSpotlight(
            flushed: flushed, applicationState: applicationState,
            hasPendingDonation: spotlightRefreshPending
        ) else { return false }
        spotlightRefreshPending = false
        return true
    }

    /// The Spotlight-piggyback rule, as a pure function (test seam).
    ///
    /// Donate in the foreground when trips changed or a deferred request exists.
    nonisolated static func shouldDonateSpotlight(
        flushed: StoreChange,
        applicationState: UIApplication.State,
        hasPendingDonation: Bool = false
    ) -> Bool {
        (flushed.contains(.trip) || hasPendingDonation) && applicationState != .background
    }

    private func apply(_ changes: StoreChange) {
        if changes.contains(.stay) { stay &+= 1 }
        if changes.contains(.trip) { trip &+= 1 }
        if changes.contains(.locationPing) { locationPing &+= 1 }
        if changes.contains(.hexVisit) { hexVisit &+= 1 }
        if changes.contains(.plannedTrip) { plannedTrip &+= 1 }
        if changes.contains(.home) { home &+= 1 }
        if changes.contains(.routinePlace) { routinePlace &+= 1 }
        if changes.contains(.photoImportState) { photoImportState &+= 1 }
        if changes.contains(.hiddenPhoto) { hiddenPhoto &+= 1 }
        if changes.contains(.pinnedPhoto) { pinnedPhoto &+= 1 }
        if changes.contains(.yearWrapped) { yearWrapped &+= 1 }
        if changes.contains(.homeAreaOverride) { homeAreaOverride &+= 1 }
        if changes.contains(.visit) { visit &+= 1 }
        if changes.contains(.temporaryHome) { temporaryHome &+= 1 }
    }

    #if DEBUG
    /// Test-only synchronous apply (bypasses debounce entirely) so tests can
    /// assert per-type token math deterministically.
    func applyNowForTesting(_ changes: StoreChange) { apply(changes) }

    /// Test-only synchronous drain of the pending window (bypasses the 500 ms
    /// timer) so debounce/union semantics can be asserted without wall-clock
    /// waits, which race Swift Testing's parallel MainActor scheduling.
    func flushPendingForTesting() { flushPending() }
    #endif
}
