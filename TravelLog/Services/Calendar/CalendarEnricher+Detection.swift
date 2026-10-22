//
//  CalendarEnricher+Detection.swift
//  TravelLog
//

@preconcurrency import EventKit
import Foundation
import CryptoKit
import SwiftData
import CoreLocation
import WeatherKit
import WidgetKit
import os.log

extension CalendarEnricher {

    /// EventKit query → text-signal detection → forward-geocoding resolution
    /// pass, then FM tie-breaker for the ambiguous band (foreground only).
    /// All outside the gate; only `applyScan` mutates.
    struct ScanAnalysis: Sendable {
        let detections: [PlannedTripDetection]
        /// Snapshots whose current location text produced a deterministic or
        /// scored rejection, including near-misses that no longer qualify as
        /// detections, and near-misses whose accepted place no longer makes
        /// them one. These are cleanup instructions for existing rows only.
        let rejectedGeocodes: [CalendarEventSnapshot]
        /// Unknown grounding never inserts a row; reconciliation may retain an
        /// unchanged, previously grounded FM card during a temporary outage.
        let deferredGroundingSnapshots: [CalendarEventSnapshot]
        /// False when a required read failed. Its empty lists are not scan
        /// evidence, so callers must not reconcile it.
        var isComplete = true
    }

    func collectDetections(
        now: Date, calendars: [EKCalendar]?, allowFMTieBreaker: Bool, allowNetworkResolution: Bool,
        expectedEpoch: UInt64
    ) async -> ScanAnalysis {
        guard Self.hasReadAccess else {
            return ScanAnalysis(detections: [], rejectedGeocodes: [], deferredGroundingSnapshots: [])
        }
        let snapshots = events(start: now, end: now.addingTimeInterval(Self.scanWindowSeconds), calendars: calendars)
        let detections = PlannedTripDetector.detect(in: snapshots)
        return await resolveAndAugment(
            detections: detections, allSnapshots: snapshots,
            allowFMTieBreaker: allowFMTieBreaker,
            allowNetworkResolution: allowNetworkResolution,
            expectedEpoch: expectedEpoch
        )
    }

    // MARK: - Forward-geocoding resolution pass

    /// Per-scan cap on forward-geocode attempts. Cache hits do not spend it;
    /// uncached unavailable outcomes remain eligible on subsequent scans.
    /// The geocoder's own 2 s throttle bounds Tier-2 traffic within the cap.
    private static let resolutionBudgetPerScan = 25

    /// Defaulted value-only dependencies let tests drive this actual orchestration
    /// without EventKit, network access or a real model.
    func resolveAndAugment(
        detections: [PlannedTripDetection],
        allSnapshots: [CalendarEventSnapshot],
        allowFMTieBreaker: Bool,
        allowNetworkResolution: Bool,
        expectedEpoch: UInt64,
        now: Date = .now,
        resolutionBudget: Int? = nil,
        judgmentBudget: Int? = nil,
        geocoder: ForwardGeocoder = .shared,
        cacheLookup: (@Sendable (String) async -> ForwardGeocoder.CachedResolution)? = nil,
        resolve: (@Sendable (String, Bool, Bool) async -> ForwardGeocoder.ResolutionOutcome)? = nil,
        judge: @Sendable (CalendarEventSnapshot) async -> PlannedTripJudgment? = {
            await PlannedTripTieBreaker.judge($0)
        }
    ) async -> ScanAnalysis {
        guard expectedEpoch == calendarDataEpoch else {
            return ScanAnalysis(detections: [], rejectedGeocodes: [], deferredGroundingSnapshots: [])
        }
        let authority = geocoderAuthority
        let cacheLookup = cacheLookup ?? { text in await geocoder.cachedResolution(for: text) }
        let resolve = resolve ?? { text, network, cacheRejections in
            await geocoder.resolveOutcome(text, allowNetwork: network,
                cacheRejections: cacheRejections, authority: authority)
        }
        // Home distance decides far-from-home evidence, and an accepted
        // near-miss without it withdraws a row's place and forecast. A failed
        // read is not "no Home".
        guard let homes = fetchHomeSnapshots() else {
            logger.error("Home fetch failed; skipping this scan's reconcile.")
            return ScanAnalysis(detections: [], rejectedGeocodes: [], deferredGroundingSnapshots: [],
                                isComplete: false)
        }
        let resolutionLimit = max(0, resolutionBudget ?? Self.resolutionBudgetPerScan)
        let judgmentLimit = allowFMTieBreaker ? max(0, judgmentBudget ?? PlannedTripTieBreaker.maxJudgmentsPerScan) : 0
        var budget = resolutionLimit
        var fmBudget = judgmentLimit
        var judgmentCacheDirty = false
        let detectedKeys = Set(detections.map { PlannedTripDetector.identityKey(for: $0.snapshot) })
        let nearMisses = allSnapshots.filter {
            !detectedKeys.contains(PlannedTripDetector.identityKey(for: $0))
                && $0.endDate.timeIntervalSince($0.startDate) > PlannedTripDetector.multiDayThresholdSeconds
        }
        let candidates = detections.map { (snapshot: $0.snapshot, detection: Optional($0)) }
            + nearMisses.map { (snapshot: $0, detection: Optional<PlannedTripDetection>.none) }
        // Rotate paid work, not the returned order used by reconciliation.
        var result = [PlannedTripDetection?](repeating: nil, count: candidates.count)
        var nextStartIndex: Int?
        var rejectedGeocodes: [String: CalendarEventSnapshot] = [:]
        var deferred: [String: CalendarEventSnapshot] = [:]
        let abandoned = ScanAnalysis(detections: [], rejectedGeocodes: [], deferredGroundingSnapshots: [])

        let startIndex = candidates.isEmpty ? 0 : scanWorkCursor % candidates.count
        for offset in candidates.indices {
            guard !Task.isCancelled, expectedEpoch == calendarDataEpoch else { return abandoned }
            let index = (startIndex + offset) % candidates.count
            let (snapshot, detection) = candidates[index]
            let key = PlannedTripDetector.identityKey(for: snapshot)
            if let detection {
                guard let text = resolutionText(for: snapshot) else {
                    result[index] = detection
                    continue
                }
                let cached = await cacheLookup(text)
                guard !Task.isCancelled, expectedEpoch == calendarDataEpoch else { return abandoned }
                let outcome: ForwardGeocoder.ResolutionOutcome
                switch cached {
                case .resolved(let place): outcome = .resolved(place)
                case .unresolved: outcome = .rejected
                case .miss:
                    guard budget > 0 else {
                        if resolutionLimit > 0, nextStartIndex == nil { nextStartIndex = index }
                        result[index] = detection
                        continue
                    }
                    budget -= 1
                    outcome = await resolve(text, allowNetworkResolution, true)
                    guard !Task.isCancelled, expectedEpoch == calendarDataEpoch else { return abandoned }
                }
                switch outcome {
                case .resolved(let place):
                    let distance = Self.distanceFromActiveHome(homes, at: snapshot.startDate,
                                                              latitude: place.latitude, longitude: place.longitude)
                    let scored = PlannedTripDetector.evaluate(snapshot, distanceFromHomeKm: distance) ?? detection
                    result[index] = PlannedTripDetection(snapshot: snapshot, confidence: scored.confidence,
                        signals: scored.signals, resolved: ResolvedPlannedPlace(place: place, distanceFromHomeKm: distance))
                case .rejected:
                    rejectedGeocodes[key] = snapshot
                    result[index] = PlannedTripDetection(snapshot: snapshot, confidence: detection.confidence,
                        signals: detection.signals, geocodeDisposition: .rejected)
                case .unavailable:
                    result[index] = detection
                }
                continue
            }

            // Do not stop at exhausted quotas: both caches may answer for later events.
            var resolved: ResolvedPlannedPlace?
            var disposition: PlannedTripGeocodeDisposition = .notAttempted
            if let text = resolutionText(for: snapshot) {
                let cached = await cacheLookup(text)
                guard !Task.isCancelled, expectedEpoch == calendarDataEpoch else { return abandoned }
                let outcome: ForwardGeocoder.ResolutionOutcome
                switch cached {
                case .resolved(let place): outcome = .resolved(place)
                case .unresolved: outcome = .rejected
                case .miss:
                    if budget > 0 {
                        budget -= 1
                        outcome = await resolve(text, allowNetworkResolution, true)
                        guard !Task.isCancelled, expectedEpoch == calendarDataEpoch else { return abandoned }
                    } else {
                        if resolutionLimit > 0, nextStartIndex == nil { nextStartIndex = index }
                        outcome = .unavailable
                    }
                }
                switch outcome {
                case .resolved(let place):
                    let distance = Self.distanceFromActiveHome(homes, at: snapshot.startDate,
                                                              latitude: place.latitude, longitude: place.longitude)
                    resolved = ResolvedPlannedPlace(place: place, distanceFromHomeKm: distance)
                    disposition = .accepted
                case .rejected:
                    disposition = .rejected
                    rejectedGeocodes[key] = snapshot
                case .unavailable: break
                }
            }

            let distance = resolved?.distanceFromHomeKm
            if let detection = PlannedTripDetector.evaluate(snapshot, distanceFromHomeKm: distance) {
                result[index] = PlannedTripDetection(snapshot: snapshot, confidence: detection.confidence,
                    signals: detection.signals, resolved: resolved, geocodeDisposition: disposition)
                continue
            }
            // An accepted place that no longer makes this event a detection
            // (a corrected geocode, a moved Home) withdraws an existing
            // row's stored geography and far-from-home evidence, as a
            // rejection does. A grounded tie-breaker below takes it back.
            if disposition == .accepted { rejectedGeocodes[key] = snapshot }
            guard let raw = PlannedTripDetector.rawScore(snapshot, distanceFromHomeKm: distance),
                  PlannedTripDetector.qualifiesForTieBreaker(score: raw.score, title: snapshot.title) else { continue }

            // The model extracts a literal phrase; offline-table membership is not
            // required ("Cephalonia wedding" must be allowed to use network resolution).
            let cacheKey = Self.judgmentCacheKey(for: snapshot)
            var verdict = cachedJudgment(for: cacheKey)
            if let retryAfter = verdict?.retryAfter {
                if now < retryAfter {
                    deferred[key] = snapshot
                    continue
                }
                judgmentCacheStorage?[cacheKey] = nil
                judgmentCacheDirty = true
                verdict = nil
            }
            if let cached = verdict, cached.isTrip,
               Self.groundingDestination(cached.destination, in: snapshot) == nil {
                judgmentCacheStorage?[cacheKey] = nil
                judgmentCacheDirty = true
                verdict = nil
            }
            // A quota disabled for this scan (notably BG's FM lane) must not
            // pin the shared cursor ahead of work that is allowed to run.
            if verdict == nil, fmBudget == 0, judgmentLimit > 0, nextStartIndex == nil {
                nextStartIndex = index
            }
            if verdict == nil, fmBudget > 0 {
                fmBudget -= 1
                let fresh = await judge(snapshot)
                guard !Task.isCancelled, expectedEpoch == calendarDataEpoch else { return abandoned }
                if let fresh {
                    let literal = Self.groundingDestination(fresh.destination, in: snapshot)
                    if !fresh.isTrip || literal != nil {
                        let cached = CachedJudgment(isTrip: fresh.isTrip, destination: literal ?? "",
                                                    eventEndDate: snapshot.endDate)
                        storeJudgment(cached, for: cacheKey)
                        judgmentCacheDirty = true
                        verdict = cached
                    } else {
                        // A decoded but nonliteral positive is not evidence of
                        // "not a trip". Avoid repeating it on every scan, while
                        // allowing a later extraction to recover without an edit.
                        storeJudgment(CachedJudgment(isTrip: true, destination: "",
                            eventEndDate: snapshot.endDate,
                            retryAfter: now.addingTimeInterval(Self.invalidJudgmentRetryInterval)), for: cacheKey)
                        judgmentCacheDirty = true
                    }
                }
            }
            guard let verdict else { deferred[key] = snapshot; continue }
            guard verdict.isTrip else { continue }
            guard let destination = Self.groundingDestination(verdict.destination, in: snapshot) else {
                deferred[key] = snapshot
                continue
            }

            // A broad location search may reject a perfectly real destination
            // inside the event title. Resolve that exact phrase independently,
            // keeping any country the event names ("London" at "London, ON,
            // Canada" is looked up as "London, Canada").
            let groundingQuery = ForwardGeocoder.contextualQuery(
                destination, context: [snapshot.title, snapshot.locationText ?? ""])
            let cachedPlace = await cacheLookup(groundingQuery)
            guard !Task.isCancelled, expectedEpoch == calendarDataEpoch else { return abandoned }
            let grounding: ForwardGeocoder.ResolutionOutcome
            if case .resolved(let place) = cachedPlace {
                grounding = .resolved(place)
            } else if budget > 0 {
                budget -= 1
                grounding = await resolve(groundingQuery, allowNetworkResolution, false)
                guard !Task.isCancelled, expectedEpoch == calendarDataEpoch else { return abandoned }
            } else {
                if resolutionLimit > 0, nextStartIndex == nil { nextStartIndex = index }
                grounding = .unavailable
            }
            switch grounding {
            case .resolved(let place):
                rejectedGeocodes[key] = nil
                let distance = Self.distanceFromActiveHome(homes, at: snapshot.startDate,
                                                          latitude: place.latitude, longitude: place.longitude)
                result[index] = PlannedTripDetection(snapshot: snapshot, confidence: .medium,
                    signals: raw.signals + [PlannedTripDetector.signalFMTieBreaker],
                    resolved: ResolvedPlannedPlace(place: place, distanceFromHomeKm: distance))
            case .rejected:
                rejectedGeocodes[key] = snapshot
            case .unavailable:
                deferred[key] = snapshot
            }
        }
        guard !Task.isCancelled, expectedEpoch == calendarDataEpoch else { return abandoned }
        if let nextStartIndex { scanWorkCursor = nextStartIndex }
        let hasExpired = hydratedJudgmentCache().contains { $0.value.eventEndDate <= now }
        if judgmentCacheDirty || hasExpired { persistJudgmentCache(now: now) }
        return ScanAnalysis(detections: result.compactMap { $0 },
            rejectedGeocodes: rejectedGeocodes.sorted { $0.key < $1.key }.map(\.value),
            deferredGroundingSnapshots: deferred.sorted { $0.key < $1.key }.map(\.value))
    }

    // MARK: - FM tie-breaker judgment cache

    /// Persisted verdicts from `PlannedTripTieBreaker.judge`, keyed on event
    /// identity plus every field the judgment prompt sees — editing an event
    /// in any prompt-visible way mints a new key and earns a fresh judgment.
    /// Without this, one event stuck in the ambiguous band re-burned a real
    /// FM call on every foreground scan for as long as it stayed in the scan
    /// window. Entries are pruned once their event has ended. Bump the
    /// suffix if the judgment prompt changes materially.
    nonisolated static let fmJudgmentCacheKey = "plannedTripFMJudgmentCache_v3"
    nonisolated static let legacyFMJudgmentCacheKey = "plannedTripFMJudgmentCache_v1"
    nonisolated static let plaintextFMJudgmentCacheKey = "plannedTripFMJudgmentCache_v2"
    nonisolated static let invalidJudgmentRetryInterval: TimeInterval = 15 * 60

    nonisolated struct CachedJudgment: Codable {
        let isTrip: Bool
        let destination: String
        let eventEndDate: Date
        var retryAfter: Date? = nil
    }

    /// Only a whole phrase literally present in the event can be sent to the
    /// resolver. Case/diacritic variants are harmless; invented exonyms are not.
    nonisolated static func groundingDestination(_ raw: String, in snapshot: CalendarEventSnapshot) -> String? {
        let phrase = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, phrase.count <= 80,
              !phrase.contains("\n"), !phrase.contains("\r") else { return nil }
        // Use word segmentation for unspaced scripts rather than accepting any
        // Han/Hangul substring (for example, 京 inside 東京 is not a match).
        let usesUnspacedScript = phrase.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value)
                || (0xAC00...0xD7AF).contains($0.value) || (0x20000...0x323AF).contains($0.value)
        }
        for text in [snapshot.title, snapshot.locationText ?? ""] {
            var wordStarts = Set<String.Index>()
            var wordEnds = Set<String.Index>()
            if usesUnspacedScript {
                text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                         options: [.byWords, .substringNotRequired]) { _, range, _, _ in
                    wordStarts.insert(range.lowerBound)
                    wordEnds.insert(range.upperBound)
                }
            }
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive],
                                         range: searchStart..<text.endIndex) {
                let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
                let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
                let matchesBoundary = usesUnspacedScript
                    ? wordStarts.contains(range.lowerBound) && wordEnds.contains(range.upperBound)
                    : (before.map({ !$0.isLetter && !$0.isNumber }) ?? true)
                        && (after.map({ !$0.isLetter && !$0.isNumber }) ?? true)
                if matchesBoundary { return String(text[range]) }
                searchStart = range.upperBound
            }
        }
        return nil
    }

    nonisolated static func judgmentCacheKey(for snapshot: CalendarEventSnapshot) -> String {
        // Hash unambiguous field boundaries: a title containing "|" must not
        // collide with the same text split between title and location. The
        // digest avoids persisting raw event text, but is not anonymization.
        let fields = [
            PlannedTripDetector.identityKey(for: snapshot),
            snapshot.title,
            snapshot.locationText ?? "",
            String(snapshot.startDate.timeIntervalSinceReferenceDate),
            String(snapshot.endDate.timeIntervalSinceReferenceDate),
            snapshot.isAllDay ? "1" : "0",
            snapshot.hasRecurrenceRules ? "1" : "0",
            snapshot.isDetached ? "1" : "0",
            Locale.current.identifier,
            TimeZone.current.identifier,
        ]
        let data = Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Empties the FM tie-breaker verdict cache — BOTH halves: the
    /// UserDefaults blob and the actor-state copy an in-flight scan would
    /// otherwise persist right back at its end. V3 hashes event identity/text,
    /// but still retains the extracted destination and event end date as
    /// derived calendar data. Every calendar/all-data wipe must clear it,
    /// including the older versions whose keys contain plaintext event text.
    func clearFMJudgmentCache() {
        Self.defaults.removeObject(forKey: Self.fmJudgmentCacheKey)
        Self.defaults.removeObject(forKey: Self.legacyFMJudgmentCacheKey)
        Self.defaults.removeObject(forKey: Self.plaintextFMJudgmentCacheKey)
        judgmentCacheStorage = [:]
        scanWorkCursor = 0
    }

    private func hydratedJudgmentCache() -> [String: CachedJudgment] {
        if let judgmentCacheStorage { return judgmentCacheStorage }
        // Discard both plaintext-key formats; the next scan recomputes them.
        Self.defaults.removeObject(forKey: Self.legacyFMJudgmentCacheKey)
        Self.defaults.removeObject(forKey: Self.plaintextFMJudgmentCacheKey)
        var loaded: [String: CachedJudgment] = [:]
        if let data = Self.defaults.data(forKey: Self.fmJudgmentCacheKey),
           let decoded = try? JSONDecoder().decode([String: CachedJudgment].self, from: data) {
            loaded = decoded
        }
        judgmentCacheStorage = loaded
        return loaded
    }

    private func cachedJudgment(for key: String) -> CachedJudgment? {
        hydratedJudgmentCache()[key]
    }

    private func storeJudgment(_ judgment: CachedJudgment, for key: String) {
        var cache = hydratedJudgmentCache()
        cache[key] = judgment
        judgmentCacheStorage = cache
    }

    private func persistJudgmentCache(now: Date = .now) {
        let pruned = hydratedJudgmentCache().filter { $0.value.eventEndDate > now }
        judgmentCacheStorage = pruned
        guard let data = try? JSONEncoder().encode(pruned) else { return }
        Self.defaults.set(data, forKey: Self.fmJudgmentCacheKey)
    }

    #if DEBUG
    /// Test seams: the in-memory half of the judgment cache is otherwise
    /// unobservable, so a wipe that cleared only UserDefaults would let the
    /// next scan's persist step write wiped judgments back.
    func seedJudgmentCacheForTesting(key: String, isTrip: Bool, eventEndDate: Date, destination: String = "") {
        storeJudgment(CachedJudgment(isTrip: isTrip, destination: destination, eventEndDate: eventEndDate), for: key)
    }

    func persistJudgmentCacheForTesting() {
        persistJudgmentCache()
    }
    #endif

    /// What to forward-geocode for an event: its location text when present,
    /// else the destination its title names ("Trip to Cephalonia" → "Cephalonia").
    private func resolutionText(for snapshot: CalendarEventSnapshot) -> String? {
        if let location = snapshot.locationText,
           !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return location
        }
        return PlannedTripChainer.extractRoute(title: snapshot.title).destination
    }

    struct HomeSnapshot: Sendable {
        let latitude: Double
        let longitude: Double
        let startedAt: Date
        let endedAt: Date?
    }

    /// Every Home and every temporary home as a value, or nil when either
    /// fetch fails. A temporary home is a place to measure from inside its
    /// own dates: an event at it then is not far from home.
    private func fetchHomeSnapshots() -> [HomeSnapshot]? {
        #if DEBUG
        if TestScope.failHomeFetch { return nil }
        #endif
        guard let homes = try? modelContext.fetch(FetchDescriptor<Home>()),
              let temporaryHomes = try? HomeAnchors.temporaryHomes(in: modelContext) else { return nil }
        var snapshots = homes.map {
            HomeSnapshot(latitude: $0.latitude, longitude: $0.longitude,
                         startedAt: $0.startedAt, endedAt: $0.endedAt)
        }
        snapshots.append(contentsOf: temporaryHomes.map {
            HomeSnapshot(latitude: $0.latitude, longitude: $0.longitude,
                         startedAt: $0.startedAt, endedAt: $0.endedAt)
        })
        return snapshots
    }

    /// Great-circle km from the nearest Home active at `date` (mirrors
    /// `Stay.distanceFromHomeKm` semantics); nil when no home covers it.
    nonisolated static func distanceFromActiveHome(
        _ homes: [HomeSnapshot], at date: Date, latitude: Double, longitude: Double
    ) -> Double? {
        let active = homes.filter { $0.startedAt <= date && ($0.endedAt == nil || $0.endedAt! > date) }
        guard !active.isEmpty else { return nil }
        let target = CLLocation(latitude: latitude, longitude: longitude)
        return active
            .map { CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: target) / 1000.0 }
            .min()
    }
}
