//
//  PipelineGate.swift
//  TravelLog
//

import Foundation

/// Serializes the app's store-mutating pipeline operations so that no two
/// `@ModelActor` contexts (`PingRecorder`, `StayClusterer`, `TripClassifier`,
/// `TransitInferer`) ever write the shared SwiftData store concurrently.
///
/// # Why
///
/// `PingRecorder`, `StayClusterer`, and `TripClassifier` are separate
/// `@ModelActor` instances, each with its own `ModelContext` over the *same*
/// store. SwiftData exposes no merge-policy override, so when two contexts save
/// overlapping rows at the same time the conflict surfaces as a thrown save
/// that the call sites' `try?` swallow — silently dropping a batch of
/// geocoding / summary / classification writes. (They self-heal on the next
/// run because the pipeline is idempotent, but the data is briefly wrong and
/// can sync that way to other devices.)
///
/// # Scope
///
/// EVERY store-mutating path routes through the gate — including the
/// background-refresh handler (`AppDelegate.handleBackgroundRefresh`). It runs
/// its steps sequentially anyway, but a background `BGAppRefreshTask` can
/// overlap a background SLC wake-ping save (both run while the app is not
/// foreground-active), and the wake save IS gated; leaving the refresh
/// clustering/classification ungated would re-open the exact cross-context
/// save-conflict race the gate exists to close. `run` / `runReturning`
/// forward the awaiting caller's cancellation into the gate unit (see
/// below), so the handler's expiration still propagates.
///
/// # Deadlock safety
///
/// This is a serial queue: each submitted unit runs only after the previous one
/// finishes. A unit therefore MUST NOT call `run(_:)` again, directly or
/// transitively — it would enqueue behind itself and hang. Every current call
/// site submits only leaf `@ModelActor` operations, which never call back into
/// the gate. Keep it that way when adding call sites.
actor PipelineGate {

    static let shared = PipelineGate()

    private init() {}

    #if DEBUG
    /// Test-only: construct a fresh, isolated gate (its own tail chain) so the
    /// process-global `shared` singleton's ordering state is never disturbed by
    /// tests. Behavior is identical to the private designated initializer.
    init(forTesting: Void) {}
    #endif

    /// Tail of the serial chain. Each `run` appends after the current tail and
    /// becomes the new tail; the initial completed task seeds the chain.
    private var tail: Task<Void, Never> = Task {}

    /// Run `work` after every previously-submitted unit has completed, then
    /// return once `work` itself finishes. Units execute in submission order.
    ///
    /// `touching` declares which `@Model` types `work` mutates, so the precise
    /// per-type `StoreChangeTracker` signal advances only those generations.
    /// Defaults to `.all` (fail-open) — an un-annotated call site behaves
    /// exactly like the legacy global bump, so narrowing is opt-in and safe.
    func run(touching: StoreChange = .all, _ work: @escaping @Sendable () async -> Void) async {
        let previous = tail
        let unit = Task {
            await previous.value
            await work()
            // Every store-mutating foreground path runs through this gate, so
            // a completed unit is the one-line hook that lets cached view
            // aggregates (StatsView / HexMapView) re-derive without per-render
            // recomputes. Debounced on the MainActor side; a no-op unit's
            // spurious bump costs one cheap recompute. Post-`work`, so it never
            // delays the unit itself (prime directive: never starve a wake-ping
            // save). `touching` narrows which per-type generations advance.
            await StoreChangeTracker.shared.bump(touching)
        }
        tail = unit
        // Forward the awaiting caller's cancellation into the unit so gated
        // operations that check `Task.isCancelled` (the pipeline drains, the
        // BG-refresh cluster/classify steps) stop promptly on expiration. The
        // unit's body still runs to its natural end (the ops simply do less
        // work and the StoreChangeTracker bump still fires), so the serial tail
        // chain stays intact. A no-op for callers that are never cancelled.
        await withTaskCancellationHandler {
            await unit.value
        } onCancel: {
            unit.cancel()
        }
    }

    /// Value-returning variant of `run` — identical serialization semantics
    /// and StoreChangeTracker bump. Exists for chunked drivers (the geocode drain,
    /// the opportunistic weather pass) that hold the gate per bounded chunk
    /// and need each chunk's result back to decide whether to continue —
    /// without it they'd have to smuggle results through shared mutable
    /// state, which `@Sendable` closures rightly reject. Deliberately NOT
    /// an overload of `run` — a trailing closure whose last expression is
    /// non-Void would silently re-resolve existing `run { … }` call sites
    /// to the generic variant (observed as unused-result warnings).
    func runReturning<T: Sendable>(touching: StoreChange = .all, _ work: @escaping @Sendable () async -> T) async -> T {
        let previous = tail
        let unit = Task<T, Never> {
            await previous.value
            let result = await work()
            await StoreChangeTracker.shared.bump(touching)
            return result
        }
        tail = Task { _ = await unit.value }
        // See `run` — forward caller cancellation into the unit.
        return await withTaskCancellationHandler {
            await unit.value
        } onCancel: {
            unit.cancel()
        }
    }
}
