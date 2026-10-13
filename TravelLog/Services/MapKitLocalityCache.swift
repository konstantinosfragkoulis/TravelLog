//
//  MapKitLocalityCache.swift
//  TravelLog
//
//  MapKit locality fallback for unnamed offline coordinates, cached by H3 res-8 cell.
//  All fallback calls use this shared actor and a rolling 30-request/60-second budget.
//  Drop requests whose wait exceeds the cap; callers retain the offline result.
//  Cache nameless responses for seven days and explicit throttles for a short backoff.
//  Never cache generic network failures, which must remain retryable after connectivity returns.
//  Per-ping and per-hex callers must remain offline because their volume exceeds the network budget.
//

import Foundation
import CoreLocation
import MapKit
import SwiftH3
import os.log

actor MapKitLocalityCache {

    static let shared = MapKitLocalityCache()

    #if DEBUG
    nonisolated enum TestHook {
        @TaskLocal static var enrich: (@Sendable (GeocodeResolver.Result?, Double, Double, Bool) async -> GeocodeResolver.Result?)?
        @TaskLocal static var reverseGeocode: (@Sendable (CLLocation) async throws -> [MKMapItem])?
    }
    #endif

    private static let logger = Logger(subsystem: "com.travellog.app", category: "MapKitLocalityCache")

    // MARK: - Persistence schema

    /// Bumped only when the on-disk shape changes in a way that
    /// breaks decoding of existing entries.
    private static let cacheUserDefaultsKey = "MapKitLocalityCache_v1"

    /// One cache row, keyed by H3 res-8 hex string. Internal (not private)
    /// solely so the back-compat decode pin in tests can construct it.
    struct CachedEntry: Codable {
        let h3Index: String                 // res-8 hex string, e.g. "8841a907adfffff"
        let locality: String?               // Apple's best name, or nil for negative entry
        let timestamp: TimeInterval         // epoch seconds when cached
        let isNegative: Bool                // true → Apple returned no useful name
        /// true → a short-TTL throttle-backoff negative (see
        /// `throttleBackoffTTL`), not a real "Apple answered nothing".
        /// Optional so pre-existing v1 cache rows (which lack the key)
        /// decode cleanly as nil ⇒ treated as the long-TTL kind.
        let isBackoff: Bool?
    }

    private var entries: [String: CachedEntry] = [:]
    private var didLoad = false
    /// Privacy-wipe generation. A request already suspended in MapKit when
    /// Delete Everything clears the cache may return a useful display value,
    /// but it must never repersist the just-erased location cell/name.
    private var cacheGeneration: UInt64 = 0

    /// Nameless responses expire after a week; positive place-name entries do not expire.
    private static let negativeEntryTTL: TimeInterval = 7 * 24 * 60 * 60

    /// Explicit throttles receive short-lived backoff because Apple answered; generic network failures remain uncached.
    nonisolated static let throttleBackoffTTL: TimeInterval = 12 * 60 * 60

    /// Pure freshness rule for a negative entry (test seam): backoff
    /// negatives live `throttleBackoffTTL`, real Apple-said-nothing
    /// negatives live `negativeEntryTTL`. Legacy rows decode with
    /// `isBackoff == nil` ⇒ long TTL, matching their original meaning.
    nonisolated static func negativeEntryIsFresh(isBackoff: Bool?, ageSeconds: TimeInterval) -> Bool {
        ageSeconds < ((isBackoff ?? false) ? throttleBackoffTTL : negativeEntryTTL)
    }

    // MARK: - Rate limiting

    /// Keep 30/60 s below the empirical 50/60 s ceiling shared by every geocoder user in the process.
    /// Apple's published guidance is more conservative than this empirical ceiling.
    private static let maxRequestsPerMinute = 30
    private static let rateLimitWindow: TimeInterval = 60

    /// Bound quota waits so backfills cannot accumulate unbounded delays.
    private static let maxRateLimitWaitSeconds: TimeInterval = 5

    private var requestTimestamps: [TimeInterval] = []

    /// Backfill consumes the drop count: any quota drop, throttle, backoff hit, transient failure or revoked lookup must leave its completion latch unset for a later retry.
    private var droppedSinceLastQuery: Int = 0

    // MARK: - Geocoder

    /// Request English names to match the offline resolver’s locale-stable storage.
    private let preferredLocale = Locale(identifier: "en_US")

    private init() {}

    // MARK: - Public API

    /// The privacy-wipe generation, for a caller that checks its own wipe authority after
    /// reading it and then passes it to `enrich`.
    var generation: UInt64 { cacheGeneration }

    /// Enrich only offline results lacking a usable name; nil input remains nil.
    /// Return the offline result on failure and never throw; nameless and explicit-throttle results use separate TTLs.
    /// Callers holding PipelineGate MUST set allowRateLimitWait false so quota sleeps cannot starve SLC writes.
    /// A `generation` a clear has since advanced admits no lookup.
    func enrich(
        offline: GeocodeResolver.Result?,
        latitude: Double,
        longitude: Double,
        allowRateLimitWait: Bool = true,
        generation pinnedGeneration: UInt64? = nil
    ) async -> GeocodeResolver.Result? {
        #if DEBUG
        if let enrich = TestHook.enrich {
            return await enrich(offline, latitude, longitude, allowRateLimitWait)
        }
        #endif
        loadIfNeeded()
        let expectedGeneration = pinnedGeneration ?? cacheGeneration

        if let offline, offline.bestLocalityName != nil {
            return offline
        }
        // Nil offline results must not spend MapKit quota.
        guard let offline else { return nil }
        // A lookup a clear revoked is unresolved, like a quota drop.
        guard expectedGeneration == cacheGeneration else {
            droppedSinceLastQuery += 1
            return offline
        }

        let key = h3Res8Key(latitude: latitude, longitude: longitude)

        if let cached = entries[key] {
            if cached.isNegative {
                let age = Date().timeIntervalSince1970 - cached.timestamp
                if Self.negativeEntryIsFresh(isBackoff: cached.isBackoff, ageSeconds: age) {
                    if cached.isBackoff == true { droppedSinceLastQuery += 1 }
                    return offline   // recently confirmed: Apple can't help here
                }
                // Stale negative → re-query (fall through)
            } else if let name = cached.locality {
                return mergeLocality(offline: offline, name: name)
            }
        }

        guard await waitForRateLimitSlot(allowWait: allowRateLimitWait) else {
            droppedSinceLastQuery += 1
            return offline
        }
        // A clear during the quota wait revokes the lookup before anything is sent.
        guard expectedGeneration == cacheGeneration else {
            droppedSinceLastQuery += 1
            return offline
        }
        // Construct the request before reserving quota: invalid coordinates never make a network attempt.
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else {
            // Init returns nil only for invalid coords (NaN/Inf etc.).
            // Treat as a permanent negative — no point re-trying.
            save(entry: CachedEntry(
                h3Index: key,
                locality: nil,
                timestamp: Date().timeIntervalSince1970,
                isNegative: true,
                isBackoff: false
            ))
            return offline
        }
        request.preferredLocale = preferredLocale

        // Reserve quota BEFORE awaiting so in-flight requests count; success, throttle, and failure each spend one attempt.
        recordRequestTimestamp()

        do {
            let mapItems: [MKMapItem]
            #if DEBUG
            if let reverseGeocode = TestHook.reverseGeocode {
                mapItems = try await reverseGeocode(location)
            } else {
                mapItems = try await request.mapItems
            }
            #else
            mapItems = try await request.mapItems
            #endif
            guard expectedGeneration == cacheGeneration else {
                droppedSinceLastQuery += 1
                return offline
            }

            let mapItem = mapItems.first
            let name = bestLocalityName(from: mapItem, offlineCountry: offline.country)
            if let name {
                save(entry: CachedEntry(
                    h3Index: key,
                    locality: name,
                    timestamp: Date().timeIntervalSince1970,
                    isNegative: false,
                    isBackoff: false
                ))
                // H3 cell keys and locality names are location PII; redact both from persisted unified logs.
                Self.logger.info(
                    "MapKit fallback: \(key, privacy: .private) → \(name, privacy: .private)"
                )
                return mergeLocality(offline: offline, name: name)
            } else {
                save(entry: CachedEntry(
                    h3Index: key,
                    locality: nil,
                    timestamp: Date().timeIntervalSince1970,
                    isNegative: true,
                    isBackoff: false
                ))
                Self.logger.debug(
                    "MapKit fallback: \(key, privacy: .private) → no usable name; cached negative."
                )
                return offline
            }
        } catch let mkError as MKError where mkError.code == .loadingThrottled {
            droppedSinceLastQuery += 1
            guard expectedGeneration == cacheGeneration else {
                return offline
            }
            // Explicit throttles use short-TTL backoff; this attempt was already counted at reservation.
            save(entry: CachedEntry(
                h3Index: key,
                locality: nil,
                timestamp: Date().timeIntervalSince1970,
                isNegative: true,
                isBackoff: true
            ))
            Self.logger.warning("MapKit fallback throttled for \(key, privacy: .private); backing off this cell.")
            return offline
        } catch {
            // Do not cache network failures; offline cells must retry later. The attempt still counts against quota.
            // placemarkNotFound is Apple's answer, so it must not block the backfill latch forever.
            if (error as? MKError)?.code != .placemarkNotFound { droppedSinceLastQuery += 1 }
            let nsError = error as NSError
            Self.logger.error(
                """
                MapKit fallback failed for \(key, privacy: .private): \
                \(nsError.domain, privacy: .public) code \(nsError.code) \
                (\(nsError.localizedDescription, privacy: .private))
                """
            )
            return offline
        }
    }

    func clearCache() {
        cacheGeneration &+= 1
        entries.removeAll()
        requestTimestamps.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.cacheUserDefaultsKey)
        Self.logger.info("MapKit locality cache cleared.")
    }

    /// Consume unresolved attempts (quota drops, throttles, backoff hits, transient failures, revoked lookups); backfill must not latch completion if any occurred.
    func consumeDropCount() -> Int {
        let n = droppedSinceLastQuery
        droppedSinceLastQuery = 0
        return n
    }

    // MARK: - MKMapItem → name

    /// Pick the most-useful place name from an `MKMapItem`, filtering
    /// out the country name itself (Apple sometimes returns
    /// `cityName == regionName` for sparse coastal coords).
    private func bestLocalityName(from mapItem: MKMapItem?, offlineCountry: String?) -> String? {
        guard let reps = mapItem?.addressRepresentations else { return nil }
        let appleCountry = reps.regionName
        guard let city = reps.cityName, !city.isEmpty else { return nil }
        if let appleCountry, city == appleCountry { return nil }
        if let country = offlineCountry, city == country { return nil }
        return city.toLatinAscii
    }

    /// Preserve every offline field except localityName, which receives Apple’s answer.
    private func mergeLocality(offline: GeocodeResolver.Result, name: String) -> GeocodeResolver.Result {
        GeocodeResolver.Result(
            country: offline.country,
            isoCountryCode: offline.isoCountryCode,
            administrativeArea: offline.administrativeArea,
            metroName: offline.metroName,
            localityName: name,
            subLocalityName: offline.subLocalityName,
            islandName: offline.islandName,
            demotedIslandName: offline.demotedIslandName
        )
    }

    // MARK: - Rate limiting

    /// Wait until there's a slot in the rolling 60-sec budget. Returns
    /// false if the wait would exceed `maxRateLimitWaitSeconds` (drop
    /// the request and let the caller use the offline-only result).
    private func waitForRateLimitSlot(allowWait: Bool = true) async -> Bool {
        let start = Date().timeIntervalSince1970
        while true {
            guard !Task.isCancelled else { return false }
            pruneExpiredRequestTimestamps()
            if requestTimestamps.count < Self.maxRequestsPerMinute { return true }

            guard allowWait else {
                Self.logger.debug("Rate-limit budget saturated; dropping request (no-wait caller).")
                return false
            }

            let elapsed = Date().timeIntervalSince1970 - start
            if elapsed >= Self.maxRateLimitWaitSeconds {
                Self.logger.debug("Rate-limit budget saturated; dropping request.")
                return false
            }

            // Wait until the oldest timestamp falls out of the window.
            guard let oldest = requestTimestamps.first else { return true }
            let waitUntilExpiry = Self.rateLimitWindow - (Date().timeIntervalSince1970 - oldest) + 0.05
            let capped = min(waitUntilExpiry, Self.maxRateLimitWaitSeconds - elapsed)
            if capped > 0 {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(capped * 1_000_000_000))
                } catch {
                    return false
                }
            }
        }
    }

    private func pruneExpiredRequestTimestamps() {
        let cutoff = Date().timeIntervalSince1970 - Self.rateLimitWindow
        requestTimestamps.removeAll { $0 < cutoff }
    }

    private func recordRequestTimestamp() {
        requestTimestamps.append(Date().timeIntervalSince1970)
    }

    // MARK: - Cache persistence

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true

        guard let data = UserDefaults.standard.data(forKey: Self.cacheUserDefaultsKey) else {
            return
        }
        guard let decoded = try? JSONDecoder().decode([CachedEntry].self, from: data) else {
            Self.logger.error("Failed to decode persisted cache; starting fresh.")
            return
        }
        for entry in decoded {
            entries[entry.h3Index] = entry
        }
        Self.logger.info("Loaded \(self.entries.count) cached locality entries.")
    }

    /// Bound non-expiring positive entries; evict oldest first and re-query evicted cells when needed.
    private static let maxEntries = 2000

    private func save(entry: CachedEntry) {
        entries[entry.h3Index] = entry
        if entries.count > Self.maxEntries {
            let overflow = entries.count - Self.maxEntries
            let oldestKeys = entries.values
                .sorted { $0.timestamp < $1.timestamp }
                .prefix(overflow)
                .map(\.h3Index)
            for key in oldestKeys {
                entries.removeValue(forKey: key)
            }
        }
        persist()
    }

    private func persist() {
        let all = Array(entries.values)
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: Self.cacheUserDefaultsKey)
    }

    // MARK: - H3

    /// H3 res-8 hex string for the given coordinate. ~0.74 km² hexagons —
    /// fine-grained enough that a Stay's centroid drift doesn't usually
    /// hop cells, coarse enough that multiple nearby stays share a cell.
    private func h3Res8Key(latitude: Double, longitude: Double) -> String {
        Self.cellKey(latitude: latitude, longitude: longitude)
    }

    /// The res-8 cell a cached name answers for. Callers that resolve outside the gate and
    /// apply later witness the row's centroid with this key: a row that moved to another cell
    /// must not take a name answered for the old one.
    nonisolated static func cellKey(latitude: Double, longitude: Double) -> String {
        H3Index(
            coordinate: H3Coordinate(lat: latitude, lon: longitude),
            resolution: 8
        ).description
    }
}
