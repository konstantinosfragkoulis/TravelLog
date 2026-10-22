import Foundation
import Observation
import SwiftData

/// The flight flow keeps reading the same full Stats projection while its
/// parent page is offscreen. The list, review queue, summary and map consume
/// this one accepted collection value; a successful write never fabricates a
/// flight from the previously displayed candidate.
@MainActor
@Observable
final class FlightLogModel {
    typealias Acceptance = @MainActor (StatsAggregator.Aggregates, StatsRefreshIdentity, Int) -> Bool

    private(set) var collections = CollectionsAggregator.Collections()
    private(set) var clearGeneration = StatsSnapshotStore.clearGeneration
    private(set) var refreshRevision = 0
    private(set) var needsRetry = false
    private(set) var hasSnapshot = false
    private(set) var completedRefreshRevision = -1
    /// Shared with StatsView: an autosave while either reader waits for the
    /// gate still owes one publication, even if the context is clean later.
    var pendingEditPublicationOwed = false

    @ObservationIgnored private var ledger = StatsRefreshLedger()
    @ObservationIgnored private var refreshTask: Task<Bool, Never>?
    @ObservationIgnored private var runningKey: RefreshKey?
    @ObservationIgnored private var clearObserver: Task<Void, Never>?

    nonisolated struct RefreshKey: Equatable, Sendable {
        let identity: StatsRefreshIdentity
        let clearGeneration: Int
        let revision: Int
    }

    init() {
        // A weak capture avoids making this navigation-scoped owner process
        // global. Revocation remains observed while Review is pushed or the
        // Stats tab is temporarily hidden by Settings.
        clearObserver = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .statsSnapshotCleared) {
                guard !Task.isCancelled else { return }
                self?.adoptCurrentGeneration()
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        clearObserver?.cancel()
    }

    func key(now: Date) -> RefreshKey {
        RefreshKey(
            identity: StatsRefreshIdentity(
                storeToken: StoreChangeTracker.shared.token(for: StatsRefreshPacing.observedChanges), now: now),
            clearGeneration: clearGeneration,
            revision: refreshRevision)
    }

    /// Stats' existing hydration and refresh paths seed the same collection
    /// value. This does not mark a cold snapshot as a completed live read.
    func receive(_ collections: CollectionsAggregator.Collections, generation: Int) {
        guard generation == StatsSnapshotStore.clearGeneration else { return }
        if clearGeneration != generation { clear(generation: generation) }
        self.collections = collections
        hasSnapshot = true
    }

    func clear(generation: Int) {
        refreshTask?.cancel()
        refreshTask = nil
        runningKey = nil
        ledger = StatsRefreshLedger()
        collections = CollectionsAggregator.Collections()
        clearGeneration = generation
        needsRetry = false
        hasSnapshot = false
        completedRefreshRevision = -1
        refreshRevision &+= 1
    }

    func adoptCurrentGeneration() {
        let generation = StatsSnapshotStore.clearGeneration
        if generation != clearGeneration { clear(generation: generation) }
    }

    @discardableResult
    func requestRefresh() -> Int {
        adoptCurrentGeneration()
        refreshTask?.cancel()
        refreshTask = nil
        runningKey = nil
        ledger = StatsRefreshLedger()
        if hasSnapshot { ledger.acceptHydrated(generation: clearGeneration) }
        refreshRevision &+= 1
        return refreshRevision
    }

    /// Both Log and Review host this driver. A push/pop may cancel a view's
    /// waiting task, but not the shared bounded read; the new destination
    /// adopts it rather than creating a second competing source of truth.
    func refresh(key: RefreshKey, context: ModelContext, accept: @escaping Acceptance) async {
        var delay: Duration = .seconds(2)
        while !Task.isCancelled {
            let retry = await refreshSharedOnce(key: key, context: context, accept: accept)
            guard retry, !Task.isCancelled else { return }
            do { try await Task.sleep(for: delay) } catch { return }
            delay = min(delay * 2, .seconds(60))
        }
    }

    private func refreshSharedOnce(key: RefreshKey, context: ModelContext, accept: @escaping Acceptance) async -> Bool {
        adoptCurrentGeneration()
        guard key.clearGeneration == clearGeneration, key.revision == refreshRevision else { return false }
        if runningKey == key, let refreshTask {
            return await refreshTask.value
        }
        refreshTask?.cancel()
        runningKey = key
        let task = Task { [weak self] in
            guard let self else { return false }
            return await self.refreshOnce(key: key, context: context, accept: accept)
        }
        refreshTask = task
        let retry = await task.value
        if runningKey == key {
            refreshTask = nil
            runningKey = nil
        }
        return retry
    }

    private func refreshOnce(key: RefreshKey, context: ModelContext, accept: Acceptance) async -> Bool {
        adoptCurrentGeneration()
        guard !Task.isCancelled, key.clearGeneration == clearGeneration else { return false }
        let now = Date.now
        let identity = StatsRefreshIdentity(
            storeToken: StoreChangeTracker.shared.token(for: StatsRefreshPacing.observedChanges), now: now)
        // Manual retries share an identity, but intentionally retry an
        // unfinished read. A current accepted identity needs no repeat.
        switch ledger.begin(identity, currentGeneration: clearGeneration) {
        case .upToDate:
            needsRetry = false
            return false
        case .refresh(let revoked):
            if revoked { collections = CollectionsAggregator.Collections() }
        }

        if context.hasChanges { pendingEditPublicationOwed = true }
        if pendingEditPublicationOwed {
            let outcome = await PipelineGate.shared.runReturning(touching: []) {
                await Self.flushPendingEdits()
            }
            guard !Task.isCancelled, key.clearGeneration == StatsSnapshotStore.clearGeneration else { return false }
            switch outcome {
            case .saved:
                pendingEditPublicationOwed = false
                // The publication changes the identity; read that committed
                // version on the next pass even if the view task restarts.
                return true
            case .cancelled:
                return false
            case .failed:
                break
            }
        }

        let generation = StatsSnapshotStore.clearGeneration
        let languageTag = AppLanguagePreference.currentTag()
        let importRevision = StoreChangeTracker.shared.revision(for: StatsAggregator.importPingChanges)
        let result: StatsAggregator.Aggregates
        do {
            result = try await StatsAggregator.load(
                container: context.container, now: now, calendar: identity.calendar,
                importPingRevision: importRevision)
        } catch {
            guard !Task.isCancelled, generation == StatsSnapshotStore.clearGeneration else { return false }
            needsRetry = true
            return true
        }
        guard !Task.isCancelled else { return false }
        let conclusion = ledger.conclude(
            identity, computedAt: generation,
            currentToken: StatsRefreshIdentity(
                storeToken: StoreChangeTracker.shared.token(for: StatsRefreshPacing.observedChanges), now: .now),
            currentGeneration: StatsSnapshotStore.clearGeneration,
            computeDegraded: result.computeDegraded,
            pendingSaveOwed: pendingEditPublicationOwed)
        switch conclusion {
        case .superseded:
            return false
        case .clearedDuringCompute:
            adoptCurrentGeneration()
            return false
        case .decided(.rejectAndRetry):
            needsRetry = true
            return true
        case .decided(let decision):
            guard accept(result, identity, generation) else { return false }
            receive(result.collections, generation: generation)
            completedRefreshRevision = key.revision
            needsRetry = decision == .applyAndRetry
            guard decision == .applyAndMarkCurrent else { return true }
        }
        if let request = StatsSnapshotStore.reserveSave(generation: generation) {
            Task.detached(priority: .background) {
                StatsSnapshotStore.save(result, request: request, languageTag: languageTag)
            }
        }
        return false
    }

    private static func flushPendingEdits() -> StatsPendingEditFlush.Outcome {
        StatsPendingEditFlush.flush(AppDelegate.modelContainer.mainContext) {
            StoreChangeTracker.shared.bump($0)
        }
    }
}
