//
//  SpotlightIndexer.swift
//  TravelLog
//
//  Keeps the CoreSpotlight entity index in step with the trip table.
//
//  `IndexedEntity` conformance alone does nothing — entities must be
//  donated explicitly, and TravelLog's trip set churns: trips are created,
//  merged and deleted as pipelines run (the ongoing trip keeps its row), and
//  "Reclassify All Trips" re-mints every non-user-edited trip.
//  A stale index would surface Spotlight results whose UUIDs resolve to
//  nothing. The full delete-and-redonate below is cheap (trips number in
//  the tens to hundreds) and self-healing by construction.
//
//  Trigger sites:
//  - `StoreChangeTracker` flush when the `.trip` generation advanced — i.e.
//    every gated unit that wrote a Trip plus the CloudKit remote handler
//    (fail-open `.all`). Background-skipped requests are retained by the
//    tracker and repaid on foreground activation or any foreground flush.
//    Unrelated writes alone do not request a refresh. Direct main-context
//    edits must publish their saved changes; a settled pipeline is silent.
//  - App launch (foreground only) — heals whatever a background
//    termination or missed debounce left behind.
//  - A failed trip fetch, retried after a bounded backoff.
//  - Delete All Data, which revokes every donation immediately (no debounce)
//    and invalidates any pass that captured a pre-wipe snapshot.
//
//  The donation token is a STABLE SHA256 over the entity content and is
//  PERSISTED across launches, so an unchanged trip set donates nothing on
//  launch (a plain `Hasher` is per-process seeded and could not persist).
//

import AppIntents
import CoreSpotlight
import CryptoKit
import Foundation
import os.log
import UIKit

actor SpotlightIndexer {

    nonisolated struct RefreshPassState {
        private(set) var isInFlight = false
        private(set) var hasPendingRerun = false

        mutating func claim() -> Bool {
            guard !isInFlight else {
                hasPendingRerun = true
                return false
            }
            isInFlight = true
            return true
        }

        /// Returns true when the owner should immediately perform one more
        /// pass. Any number of collisions coalesces into that single rerun.
        mutating func finishPass() -> Bool {
            guard hasPendingRerun else {
                isInFlight = false
                return false
            }
            hasPendingRerun = false
            return true
        }

        /// Asks the in-flight owner for one more pass, as a collision would.
        /// No effect when idle.
        mutating func queueRerun() {
            if isInFlight { hasPendingRerun = true }
        }
    }

    /// The store read and CoreSpotlight writes a pass performs. Internal
    /// test seam; `shared` uses the app container and the default index.
    nonisolated struct Operations: Sendable {
        var fetchEntities: @Sendable () throws -> [TripEntity]
        var deleteAllEntities: @Sendable () async throws -> Void
        var indexEntities: @Sendable ([TripEntity]) async throws -> Void

        static let live = Operations(
            fetchEntities: {
                try TripEntityFetcher.allEntities(container: AppDelegate.modelContainer)
            },
            deleteAllEntities: {
                try await CSSearchableIndex.default().deleteAppEntities(ofType: TripEntity.self)
            },
            indexEntities: { entities in
                try await CSSearchableIndex.default().indexAppEntities(entities)
            })
    }

    static let shared = SpotlightIndexer()

    private let operations: Operations
    private let defaults: UserDefaults

    init(operations: Operations = .live, defaults: UserDefaults = .standard) {
        self.operations = operations
        self.defaults = defaults
    }

    private let logger = Logger(subsystem: "com.travellog.app", category: "SpotlightIndexer")

    /// Donation authority. Token invalidation and Delete All Data advance it;
    /// a pass that sees a newer epoch after a CoreSpotlight await abandons its
    /// snapshot (no index call, no token) and queues a rerun.
    private var donationEpoch: UInt64 = 0

    /// Set by `revokeAllDonations` until a deletion that started after the
    /// revocation succeeds. A failed deletion keeps it for the bounded retry.
    private var revocationPending = false

    nonisolated private struct RevocationWaiter {
        let epoch: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var revocationWaiters: [RevocationWaiter] = []

    /// Coalesces bursts (an import fires dozens of gated units) into one
    /// donation — a longer window than the tracker's, because a donation is
    /// heavier than a counter bump.
    private var refreshScheduled = false

    /// In-flight guard. The 3-second
    /// debounce coalesces callers that arrive close together, but it resets
    /// `refreshScheduled` BEFORE awaiting `refresh()` — so a caller landing
    /// during a long donation starts a second overlapping pass. Two passes can
    /// then interleave their index writes and their token persistence, leaving
    /// a token that does not describe what was actually donated.
    private var refreshPassState = RefreshPassState()

    private static let tokenKey = "spotlightDonatedToken_v1"

    /// Stable, order-independent digest of the donated content. Internal as
    /// a pure test seam.
    nonisolated static func contentDigest(for entities: [TripEntity]) -> String {
        let languageTag = AppLanguagePreference.currentTag()
        return contentDigest(
            for: entities,
            languageTag: languageTag,
            locale: AppLanguagePreference.locale(for: languageTag)
        )
    }

    /// Locale-explicit seam for tests and donation. The language tag forces a
    /// re-donation even when localized bytes happen to match; the final
    /// description covers the inverse case where formatting changes while raw
    /// dates and trip fields remain stable.
    nonisolated static func contentDigest(
        for entities: [TripEntity],
        languageTag: String,
        locale: Locale
    ) -> String {
        let canonical = entities
            .map { e in
                [languageTag,
                 String(describing: e.id), String(describing: e.title),
                 e.titleAliases.joined(separator: ","),
                 String(describing: e.destinationSummary),
                 String(describing: e.startDate),
                 String(describing: e.endDate),
                 String(describing: e.isOngoing),
                 e.localities.joined(separator: ","),
                 e.countryNames.joined(separator: ","),
                 e.countryCodes.joined(separator: ","),
                 e.spotlightKeywords(locale: locale).joined(separator: ","),
                 e.dateRangeText(locale: locale),
                 e.spotlightContentDescription(locale: locale)].joined(separator: "|")
            }
            .sorted()
            .joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Stable SHA256 of the last successfully donated entity set, persisted
    /// across launches so an unchanged set skips the CoreSpotlight round-trip,
    /// including on launch. Seeded from `UserDefaults` at first access.
    private lazy var lastDonatedToken: String? =
        defaults.string(forKey: Self.tokenKey)

    /// The single token-drop path. Advancing the epoch stops an in-flight
    /// pass from republishing a token after this drop.
    private func dropDonationToken() {
        donationEpoch &+= 1
        lastDonatedToken = nil
        defaults.removeObject(forKey: Self.tokenKey)
    }

    /// A backup restore carries the persisted content token
    /// but NOT the OS-side Spotlight index, so the digest short-circuit
    /// would skip donation onto an empty index indefinitely. Dropping the
    /// token forces the next `refresh()` to re-donate everything.
    func invalidateDonationToken() {
        dropDonationToken()
        logger.info("Donation token invalidated (backup restore) — next refresh re-donates.")
    }

    /// Delete All Data: revoke every donation now. Call it after the wipe's
    /// gate unit returns, never inside one. Runs a pass without the debounce,
    /// queued behind any in-flight pass, and returns once a deletion that
    /// started after this call succeeded (true) or failed (false). A failure
    /// keeps the revocation pending for the bounded retry; a failed trip read
    /// afterwards does not undo a successful revocation.
    func revokeAllDonations() async -> Bool {
        dropDonationToken()
        revocationPending = true
        let epoch = donationEpoch
        return await withCheckedContinuation { continuation in
            revocationWaiters.append(
                RevocationWaiter(epoch: epoch, continuation: continuation))
            Task { await self.refresh() }
        }
    }

    #if DEBUG
    /// Whether a revocation still waits for a successful deletion.
    func hasPendingRevocation() -> Bool {
        revocationPending
    }
    #endif

    private func resolveRevocationWaiters(through epoch: UInt64, succeeded: Bool) {
        let resolved = revocationWaiters.filter { $0.epoch <= epoch }
        revocationWaiters.removeAll { $0.epoch <= epoch }
        for waiter in resolved {
            waiter.continuation.resume(returning: succeeded)
        }
    }

    /// Request a debounced re-donation. Safe to call from any mutation
    /// path; concurrent calls within the window coalesce.
    func requestRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { await self.refreshAfterDebounce() }
    }

    private func refreshAfterDebounce() async {
        try? await Task.sleep(for: .seconds(3))
        refreshScheduled = false
        await refresh()
    }

    /// One sleeping retry at most; the delay doubles per consecutive failed
    /// fetch or donation up to an hour and resets once the index is current.
    private static let initialFetchRetryDelay: Duration = .seconds(60)
    private static let maxFetchRetryDelay: Duration = .seconds(3600)
    private var fetchRetryDelay = SpotlightIndexer.initialFetchRetryDelay
    private var fetchRetryScheduled = false

    private func scheduleFetchRetry() {
        guard !fetchRetryScheduled else { return }
        fetchRetryScheduled = true
        let delay = fetchRetryDelay
        fetchRetryDelay = min(delay * 2, Self.maxFetchRetryDelay)
        Task { await self.retryAfterFetchFailure(delay) }
    }

    private func retryAfterFetchFailure(_ delay: Duration) async {
        try? await Task.sleep(for: delay)
        fetchRetryScheduled = false
        // Foreground only, like every other trigger: a retry that comes due in
        // the background becomes the pending donation the next activation repays.
        let donate = await MainActor.run {
            StoreChangeTracker.shared.consumeSpotlightRefresh(
                flushed: .trip, applicationState: UIApplication.shared.applicationState)
        }
        if donate { requestRefresh() }
    }

    /// One pass without the debounce, serialized with every other pass.
    /// Internal as a test seam.
    func refresh() async {
        guard refreshPassState.claim() else {
            logger.debug("Spotlight refresh already in flight; queued one follow-up pass.")
            return
        }
        repeat {
            await performRefresh()
        } while refreshPassState.finishPass()
    }

    private func performRefresh() async {
        let passEpoch = donationEpoch
        var deletedThisPass = false
        if revocationPending {
            // Revocation deletes before reading: a failed read is no
            // permission to keep wiped content searchable.
            do {
                try await operations.deleteAllEntities()
            } catch {
                resolveRevocationWaiters(through: passEpoch, succeeded: false)
                lastDonatedToken = nil
                scheduleFetchRetry()
                logger.warning("Spotlight revocation failed: \(error.localizedDescription, privacy: .private)")
                return
            }
            if donationEpoch == passEpoch { revocationPending = false }
            resolveRevocationWaiters(through: passEpoch, succeeded: true)
            deletedThisPass = true
            // Another revocation or token drop landed during the deletion:
            // its own corrective pass runs next.
            guard donationEpoch == passEpoch else {
                abandonPass()
                return
            }
        }

        // A failed read is not an empty library: keep the last donation and
        // its token, and retry on a bounded backoff.
        guard let entities = try? operations.fetchEntities() else {
            logger.warning("Spotlight refresh skipped: the trip fetch failed.")
            scheduleFetchRetry()
            return
        }

        // Stable, order-independent digest of the donated content. Sorting the
        // per-entity lines makes it robust to fetch-order variance; SHA256 is
        // deterministic across launches (unlike `Hasher`, which is per-process
        // seeded), so the persisted token below actually matches next launch.
        // Every donated field participates: keywords
        // (localities/countryNames/countryCodes) and startDate are part of
        // the CSSearchableItem attributes, and countryCodes in particular is
        // corrected by live geocode retries independently of the title/
        // summary fields — a digest that omits them never re-donates the
        // correction, leaving Spotlight keyword search stale.
        let languageTag = AppLanguagePreference.currentTag()
        let token = Self.contentDigest(
            for: entities,
            languageTag: languageTag,
            locale: AppLanguagePreference.locale(for: languageTag)
        )
        guard token != lastDonatedToken else {
            fetchRetryDelay = Self.initialFetchRetryDelay
            return
        }

        do {
            if !deletedThisPass {
                try await operations.deleteAllEntities()
                guard donationEpoch == passEpoch else {
                    abandonPass()
                    return
                }
            }
            if !entities.isEmpty {
                try await operations.indexEntities(entities)
                // A revocation that landed during indexing is serialized as
                // the corrective deletion of the queued rerun.
                guard donationEpoch == passEpoch else {
                    abandonPass()
                    return
                }
            }
            lastDonatedToken = token
            defaults.set(token, forKey: Self.tokenKey)
            fetchRetryDelay = Self.initialFetchRetryDelay
            logger.debug("Donated \(entities.count) trip(s) to Spotlight.")
        } catch {
            // Leave the token unset and retry on the bounded backoff. Do
            // NOT touch the persisted token, so a fresh launch reloads the last
            // good one and retries because the content still differs from it.
            lastDonatedToken = nil
            scheduleFetchRetry()
            logger.warning("Spotlight donation failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// The pass's snapshot predates a token drop or revocation: publish
    /// nothing and let the queued rerun read the store again.
    private func abandonPass() {
        refreshPassState.queueRerun()
        logger.debug("Spotlight pass superseded by a revocation or token drop; rerunning.")
    }
}
