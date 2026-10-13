//
//  ForwardGeocoder.swift
//  TravelLog
//

import CryptoKit
import Foundation
import MapKit
import os.log
import os

/// A forward-geocoded place, in the shape `PlannedTrip.resolved*` persists.
nonisolated struct ForwardGeocodedPlace: Sendable, Equatable, Codable {
    let latitude: Double
    let longitude: Double
    let locality: String?
    let country: String?
    let isoCountryCode: String?
}

/// Free-form place text → coordinates, for calendar-event locations and
/// route destinations. Two tiers, mirroring
/// the reverse path's offline-first philosophy (`GeocodeResolver.resolve` →
/// `resolveWithFallback`):
///
/// - **Tier 1 — offline**: `GeocodeResolver.resolveCityName` — an indexed
///   equality probe against the bundled GeoNames city table. Free, instant,
///   no rate limit; exactly what Gmail's auto-generated "Flight to Rome"
///   titles need. Candidate strings are derived from the raw text (whole
///   line, comma components) since calendar locations range from a bare city
///   to a multi-line postal address.
/// - **Tier 2 — network**: `MKLocalSearch` (the codebase's consistent MapKit
///   choice — `MapLocationPicker` already uses it), throttled to one request
///   per 2 s and capped per scan by the caller. Handles street addresses and
///   venue names Tier 1 can't.
///
/// A persistent `(normalized text → place-or-negative)` cache in
/// `UserDefaults` makes repeat scans free: calendar-scale volume is dozens
/// of distinct strings, not thousands. Tier-2 *errors* (offline, throttled)
/// are NOT cached. Scored rejections and empty results expire after seven
/// days; accepted places remain stable until the cache is explicitly reset.
///
/// Never blocks anything: every failure path returns nil and the caller's
/// row simply stays unresolved (detection then runs on text signals alone).
actor ForwardGeocoder {

    private static let productionShared = ForwardGeocoder()
    nonisolated static var shared: ForwardGeocoder {
        #if DEBUG
        if let geocoder = TestScope.geocoder { return geocoder }
        #endif
        return productionShared
    }

    #if DEBUG
    nonisolated enum TestScope {
        @TaskLocal static var geocoder: ForwardGeocoder?
        @TaskLocal static var defaultsSuiteName: String?
    }
    #endif

    private let logger = Logger(subsystem: "com.travellog.app", category: "ForwardGeocoder")

    /// V2 intentionally does not migrate V1 positives: V1 trusted the first
    /// MapKit result without semantic validation, so carrying those values
    /// forward would let already-poisoned entries bypass the scorer forever.
    /// V3 drops V2 positives where a country-name component resolved to a
    /// same-named foreign town ("…, Greece" as Greece, NY).
    /// V4 drops V3 positives where a city component ignored an explicit
    /// country elsewhere in the text ("London, ON, Canada" as London, GB).
    private static let cacheKey = "forwardGeocodeCache_v4"
    private static let legacyCacheKeys = ["forwardGeocodeCache_v1", "forwardGeocodeCache_v2", "forwardGeocodeCache_v3"]
    private static let cacheCapacity = 800
    private static let negativeCacheTTL: TimeInterval = 7 * 24 * 60 * 60
    private static let networkThrottleSeconds: TimeInterval = 2
    private static let maximumScoredResults = 5

    /// Cache entry: an accepted hit, or a temporary scored rejection
    /// (`place == nil`).
    private struct CacheEntry: Codable {
        var place: ForwardGeocodedPlace?
        var cachedAt: Date
    }

    private var cache: [String: CacheEntry]?
    private var lastNetworkCallAt: Date?
    /// Invalidates suspended offline/network resolutions when a privacy wipe
    /// clears the cache. Results captured under an older generation are
    /// returned transiently unavailable and never persisted.
    private var cacheGeneration: UInt64 = 0

    /// Captured by the calendar scan before any actor hop. Unlike the cache's
    /// generation, this authority cannot be refreshed by entering after a wipe.
    nonisolated struct RequestAuthority: Sendable {
        private let active = OSAllocatedUnfairLock(initialState: true)
        var isValid: Bool { active.withLock { $0 } }
        func revoke() { active.withLock { $0 = false } }
    }

    private init() {}

    private var defaults: UserDefaults {
        #if DEBUG
        if let defaultsSuiteNameForTesting { return UserDefaults(suiteName: defaultsSuiteNameForTesting)! }
        #endif
        return .standard
    }

    #if DEBUG
    private var defaultsSuiteNameForTesting: String?
    private var beforeEntryForTesting: (@Sendable () async -> Void)?
    private var beforePublicationForTesting: (@Sendable () async -> Void)?

    init(defaultsSuiteNameForTesting: String) {
        self.defaultsSuiteNameForTesting = defaultsSuiteNameForTesting
    }

    func setBeforeEntryForTesting(_ hook: @escaping @Sendable () async -> Void) {
        beforeEntryForTesting = hook
    }

    func setBeforePublicationForTesting(_ hook: @escaping @Sendable () async -> Void) {
        beforePublicationForTesting = hook
    }
    #endif

    // MARK: - API

    enum CachedResolution: Sendable, Equatable {
        case miss
        case resolved(ForwardGeocodedPlace)
        case unresolved
    }

    enum ResolutionOutcome: Sendable, Equatable {
        case resolved(ForwardGeocodedPlace)
        /// A deterministic preflight rejection or a successful MapKit search
        /// whose candidates failed semantic validation.
        case rejected
        /// Network disabled, cancellation, or a transient MapKit failure.
        case unavailable
    }

    /// Cache-only lookup without offline or network work. The tri-state result
    /// matters to budgeted callers: a cached rejection is free just like a
    /// cached place and must not consume another per-scan attempt.
    ///
    /// Exists so budgeted callers can spend their quota on ACTUAL work.
    /// `resolve` answers from this same cache on its first lines, so a caller
    /// that decrements a budget before calling it charges full price for a
    /// free hit, silently starving the scans the budget promises are
    /// "nearly free".
    func cachedResolution(for rawText: String) -> CachedResolution {
        let key = Self.normalizedKey(rawText)
        guard !key.isEmpty else { return .unresolved }
        loadCacheIfNeeded()
        return cachedResolution(forKey: key, now: .now)
    }

    /// Resolve free-form place text. `allowNetwork: false` restricts to the
    /// offline tier + cache (callers use it to enforce per-scan network
    /// budgets).
    func resolve(_ rawText: String, allowNetwork: Bool = true) async -> ForwardGeocodedPlace? {
        guard case .resolved(let place) = await resolveOutcome(
            rawText,
            allowNetwork: allowNetwork
        ) else { return nil }
        return place
    }

    /// Detailed resolution result used by `CalendarEnricher` to distinguish a
    /// definitive semantic rejection from a transient miss. That distinction
    /// is what permits safe healing of legacy unscored geography without
    /// deleting a valid place merely because the device is offline.
    func resolveOutcome(
        _ rawText: String,
        allowNetwork: Bool = true,
        cacheRejections: Bool = true,
        authority: RequestAuthority? = nil
    ) async -> ResolutionOutcome {
        #if DEBUG
        if let hook = beforeEntryForTesting {
            beforeEntryForTesting = nil
            await hook()
        }
        #endif
        guard !Task.isCancelled, authority?.isValid != false else { return .unavailable }
        let expectedGeneration = cacheGeneration
        let key = Self.normalizedKey(rawText)
        guard !key.isEmpty else { return .rejected }

        loadCacheIfNeeded()
        switch cachedResolution(forKey: key, now: .now) {
        case .resolved(let place):
            return .resolved(place)
        case .unresolved:
            // Literal FM grounding retries misses; ordinary location lookups
            // retain the existing seven-day negative cache.
            if cacheRejections { return .rejected }
        case .miss:
            break
        }

        #if DEBUG
        if let hook = beforePublicationForTesting {
            beforePublicationForTesting = nil
            await hook()
        }
        #endif
        guard !Task.isCancelled, authority?.isValid != false,
              expectedGeneration == cacheGeneration else { return .unavailable }
        let queryCandidates = Self.candidateStrings(from: rawText)
        let viableCandidates = ForwardGeocodeMatchScorer.viableQueryCandidates(
            from: queryCandidates
        )
        guard !viableCandidates.isEmpty else {
            // Deterministic calendar boilerplate (`Zoom Room 4B`, `HQ`) is a
            // rejection, not a transient network miss.
            if cacheRejections { store(key: key, place: nil) }
            return .rejected
        }

        // Tier 1 — offline city-name probe over derived candidates. Every
        // explicit country the text names binds every probe: the city's
        // country must be each one, or, for a name that is also a
        // subdivision ("Atlanta, Georgia"), its admin-1 name. A candidate
        // naming a country is the destination only when the text names
        // nothing else, and then only as a same-named city inside it
        // (Luxembourg yes, Greece, NY no, and not Luxembourg for "Tokyo,
        // Luxembourg"). No qualifying homonym is a miss, never the globally
        // largest one.
        let parts = Self.textParts(from: rawText)
        let qualifiers = Self.countryQualifiers(in: parts)
        let destinations = Self.destinationCandidates(viableCandidates, parts: parts)
        guard !destinations.isEmpty else {
            // Only a country qualifier plus boilerplate ("Greece\nZoom"):
            // nothing names the destination, deterministically.
            if cacheRejections { store(key: key, place: nil) }
            return .rejected
        }
        for candidate in destinations {
            let ownCode = Self.countryCode(named: candidate)
            let folded = Self.foldedCountryName(candidate)
            let others = qualifiers.filter { $0.foldedText != folded }
            let hit: GeocodeResolver.ForwardCityHit?
            if others.isEmpty {
                hit = await GeocodeResolver.shared.resolveCityName(candidate, isoCountryCode: ownCode)
            } else {
                let homonyms = await GeocodeResolver.shared.cityHomonyms(named: candidate)
                hit = Self.firstHomonym(homonyms, isoCountryCode: ownCode, satisfying: others)
            }
            guard !Task.isCancelled, authority?.isValid != false, expectedGeneration == cacheGeneration else { return .unavailable }
            if let hit {
                let place = ForwardGeocodedPlace(
                    latitude: hit.latitude,
                    longitude: hit.longitude,
                    // Same single-script normalization as the Tier-2 path:
                    // the raw GeoNames name can carry native
                    // script, and this locality is persisted verbatim.
                    locality: hit.name.toLatinAscii,
                    country: Self.countryName(for: hit.isoCountryCode),
                    isoCountryCode: hit.isoCountryCode
                )
                store(key: key, place: place)
                return .resolved(place)
            }
        }

        // Miss NOT cached — a later foreground/online pass may still answer.
        guard allowNetwork else { return .unavailable }

        // Tier 2 — MKLocalSearch, throttled.
        //
        // RESERVE the slot before suspending. This actor suspends across both
        // the sleep and the search itself, so a concurrent `resolve()` that
        // entered during either would observe the same stale
        // `lastNetworkCallAt` and clear the window — two callers could wake
        // and fire back to back with no spacing at all. Stamping the
        // PROJECTED send time up front makes the reservation visible to
        // whoever enters next, so throttling composes instead of collapsing.
        let now = Date.now
        var sendAt = now
        if let last = lastNetworkCallAt {
            sendAt = max(now, last.addingTimeInterval(Self.networkThrottleSeconds))
        }
        lastNetworkCallAt = sendAt
        let wait = sendAt.timeIntervalSince(now)
        if wait > 0 {
            do {
                try await Task.sleep(for: .seconds(wait))
            } catch {
                return .unavailable
            }
        }
        guard !Task.isCancelled, authority?.isValid != false, expectedGeneration == cacheGeneration else { return .unavailable }

        let request = MKLocalSearch.Request()
        // The first destination alternative: the whole line for "Tokyo,
        // Luxembourg" (qualifiers kept), never a leading bare-country line.
        request.naturalLanguageQuery = destinations[0]
        request.resultTypes = [.address, .pointOfInterest, .physicalFeature]
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard !Task.isCancelled, authority?.isValid != false, expectedGeneration == cacheGeneration else {
                return .unavailable
            }
            let allScoredItems = await makeScoredItems(response.mapItems)
            guard !Task.isCancelled, authority?.isValid != false, expectedGeneration == cacheGeneration else {
                return .unavailable
            }
            // The same explicit countries and destination alternatives bind
            // the network tier (see `networkAssessment`). Ranks stay
            // MapKit's own, so the accepted rank names one item.
            let assessment = Self.networkAssessment(
                rawText: rawText,
                results: allScoredItems.map {
                    NetworkResult(candidate: $0.candidate,
                                  isoCountryCode: $0.reverse?.isoCountryCode,
                                  admin1Name: $0.reverse?.administrativeArea)
                }
            )
#if DEBUG
            let featureNames = assessment.features.map(\.rawValue).joined(separator: ",")
            logger.debug("Tier-2 assessment disposition=\(assessment.disposition.rawValue, privacy: .public) score=\(assessment.score, privacy: .public) rank=\(assessment.candidateRank ?? -1, privacy: .public) tokenCount=\(assessment.distinctiveTokenCount, privacy: .public) features=\(featureNames, privacy: .public)")
#endif
            guard assessment.isAccepted,
                  let rank = assessment.candidateRank,
                  let accepted = allScoredItems.first(where: { $0.candidate.rank == rank }) else {
                // A successful response with no trustworthy candidate is a
                // measured rejection. Cache it briefly so scans do not keep
                // repeating the same fuzzy search; the TTL lets future MapKit
                // data or scorer revisions self-heal.
                if cacheRejections { store(key: key, place: nil) }
                return .rejected
            }

            let coordinate = accepted.item.location.coordinate
            let reverse = accepted.reverse
            // `localityForStorage`: this locality is
            // persisted on `PlannedTrip.resolvedLocality`, so the shared
            // country-name guard applies like every other storage site.
            // The `item.name` fallback goes through the same `toLatinAscii`
            // normalization every other storage site applies — a Tier-2 hit
            // our offline resolver can't place must not persist a
            // mixed-script name.
            //
            // This item has passed `ForwardGeocodeMatchScorer` using name, address,
            // locality/reverse layers, POI category, and rank. A bare name
            // echo is never sufficient evidence.
            let place = ForwardGeocodedPlace(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                locality: reverse?.localityForStorage ?? accepted.item.name?.toLatinAscii,
                country: reverse?.country,
                isoCountryCode: reverse?.isoCountryCode
            )
            store(key: key, place: place)
            return .resolved(place)
        } catch {
            // Transient (offline, rate-limited) — do NOT cache.
            logger.debug("Tier-2 forward geocode failed for a location string: \(error.localizedDescription)")
            return .unavailable
        }
    }

    // MARK: - Candidate derivation (pure, testable)

    /// Strings worth probing the offline city table with, best-first, from
    /// free-form location text: every non-empty line whole, then its comma
    /// components ("Rome, Italy" → "Rome", "Italy"). Bounded and deduped.
    /// Keeping later lines lets `Room 4B\nHotel Grande Bretagne\nAthens`
    /// discard the boilerplate first line and retain the actual venue.
    nonisolated static func candidateStrings(from rawText: String) -> [String] {
        let lines = rawText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }

        var candidates: [String] = []
        for line in lines.prefix(6) {
            candidates.append(line)
            let commaParts = line
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if commaParts.count > 1 {
                candidates.append(contentsOf: commaParts)
            }
        }

        var seen = Set<String>()
        return Array(candidates
            .filter { $0.count <= 80 }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(12))
    }

    /// Every line's comma components (a line without commas is one part),
    /// over the same lines `candidateStrings` reads but before its cap, so a
    /// qualifier is never dropped with a truncated candidate.
    nonisolated static func textParts(from rawText: String) -> [String] {
        rawText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(6)
            .flatMap { line in
                line.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
    }

    /// An explicit country the text names as a whole part ("Canada",
    /// "USA", "Georgia"). `foldedText` also matches an admin-1 name, the
    /// other reading of a country-named part.
    nonisolated struct CountryQualifier: Sendable, Equatable {
        let text: String
        let foldedText: String
        let isoCountryCode: String
    }

    nonisolated static func countryQualifiers(in parts: [String]) -> [CountryQualifier] {
        var seen = Set<String>()
        return parts.compactMap { part in
            guard let code = countryCode(named: part) else { return nil }
            let folded = foldedCountryName(part)
            guard seen.insert(folded).inserted else { return nil }
            return CountryQualifier(text: part, foldedText: folded, isoCountryCode: code)
        }
    }

    /// Whether a place satisfies every qualifier, each by country, by
    /// admin-1 name, or by being the place that part names (`placeNames`:
    /// the Granada of "Granada, España", where Granada is also Grenada's
    /// Spanish name, or the Jordan of "Jordan, Hong Kong"). Contradictory
    /// qualifiers ("Tbilisi, Georgia, USA") therefore admit nothing.
    nonisolated static func satisfies(
        isoCountryCode: String?, admin1Name: String?, placeNames: [String] = [],
        qualifiers: [CountryQualifier]
    ) -> Bool {
        let admin1 = admin1Name.map(foldedCountryName)
        let names = Set(placeNames.map(foldedCountryName))
        return qualifiers.allSatisfy { qualifier in
            isoCountryCode == qualifier.isoCountryCode || admin1 == qualifier.foldedText
                || names.contains(qualifier.foldedText)
        }
    }

    /// The most populous homonym inside `isoCountryCode` (when the candidate
    /// itself names a country) that satisfies every qualifier.
    nonisolated static func firstHomonym(
        _ homonyms: [GeocodeResolver.ForwardCityHomonym], isoCountryCode: String?,
        satisfying qualifiers: [CountryQualifier]
    ) -> GeocodeResolver.ForwardCityHit? {
        homonyms.first { homonym in
            (isoCountryCode == nil || homonym.hit.isoCountryCode == isoCountryCode)
                && satisfies(isoCountryCode: homonym.hit.isoCountryCode,
                             admin1Name: homonym.admin1Name, qualifiers: qualifiers)
        }?.hit
    }

    /// The viable alternatives that may name the destination. A bare country
    /// part only qualifies it, unless the text names nothing but countries
    /// (standalone "Luxembourg" yes, the "Luxembourg" of "Tokyo, Luxembourg"
    /// no), so neither tier can accept the qualifier as the place.
    nonisolated static func destinationCandidates(_ viable: [String], parts: [String]) -> [String] {
        guard !parts.allSatisfy({ countryCode(named: $0) != nil }) else { return viable }
        return viable.filter { countryCode(named: $0) == nil }
    }

    /// One scored network result with the country and admin-1 name the
    /// offline reverse geocoder placed it in.
    nonisolated struct NetworkResult: Sendable, Equatable {
        let candidate: ForwardGeocodeMatchScorer.Candidate
        let isoCountryCode: String?
        let admin1Name: String?

        /// The names of the place itself: its localities and, unless it is
        /// a categorized point of interest (a restaurant called "Canada"),
        /// its own name.
        var placeNames: [String] {
            [candidate.pointOfInterestCategory == nil ? candidate.name : nil,
             candidate.mapLocality, candidate.reverseLocality, candidate.reverseSubLocality]
                .compactMap { $0 }
        }
    }

    /// The Tier-2 decision. Results outside the text's explicit countries
    /// are dropped (a bare-city match must not stand in for "London,
    /// Canada"), unless the result is the place a country-named part names
    /// ("Lebanon, NH", "Jordan, Hong Kong", "Granada" where Granada is also
    /// a country name). The rest are scored only against the destination
    /// alternatives, so "Tokyo, Luxembourg" cannot accept Luxembourg City.
    nonisolated static func networkAssessment(
        rawText: String,
        results: [NetworkResult]
    ) -> ForwardGeocodeMatchScorer.Assessment {
        let parts = textParts(from: rawText)
        let qualifiers = countryQualifiers(in: parts)
        let viable = ForwardGeocodeMatchScorer.viableQueryCandidates(from: candidateStrings(from: rawText))
        let admitted = results.filter {
            satisfies(isoCountryCode: $0.isoCountryCode, admin1Name: $0.admin1Name,
                      placeNames: $0.placeNames, qualifiers: qualifiers)
        }
        return ForwardGeocodeMatchScorer.evaluate(
            queryCandidates: destinationCandidates(viable, parts: parts),
            candidates: admitted.map(\.candidate)
        )
    }

    /// A literal destination phrase plus the countries its event names
    /// elsewhere ("London" from an event at "London, ON, Canada" becomes
    /// "London, Canada"), so the lookup and its cache entry keep that
    /// context. Unchanged when the context names no other country.
    nonisolated static func contextualQuery(_ destination: String, context: [String]) -> String {
        let own = Set(textParts(from: destination).map(foldedCountryName))
        let extra = countryQualifiers(in: context.flatMap { textParts(from: $0) })
            .filter { !own.contains($0.foldedText) }
        guard !extra.isEmpty else { return destination }
        return ([destination] + extra.map(\.text)).joined(separator: ", ")
    }

    nonisolated static func normalizedKey(_ rawText: String) -> String {
        let normalized = rawText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.count > 120 else { return normalized }
        // Long texts keep the readable prefix and add a digest of the whole
        // text, so two locations sharing 120 characters never share an answer.
        let digest = SHA256.hash(data: Data(normalized.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        return String(normalized.prefix(120)) + "#" + digest
    }

    nonisolated static func negativeCacheIsFresh(cachedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(cachedAt) <= negativeCacheTTL
    }

    /// Folded English and current-locale region names plus common aliases.
    private nonisolated static let countryCodesByName: [String: String] = {
        let english = Locale(identifier: "en_US")
        var map = ["uk": "GB", "u.k.": "GB", "usa": "US", "u.s.a.": "US", "us": "US", "u.s.": "US"]
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { continue }
            for name in [english.localizedString(forRegionCode: code), Locale.current.localizedString(forRegionCode: code)] {
                guard let name else { continue }
                map[foldedCountryName(name)] = code
            }
        }
        return map
    }()

    private nonisolated static func foldedCountryName(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func countryCode(named candidate: String) -> String? {
        countryCodesByName[foldedCountryName(candidate)]
    }

    private nonisolated static func countryName(for iso: String) -> String? {
        guard !iso.isEmpty else { return nil }
        return Locale(identifier: "en_US").localizedString(forRegionCode: iso)
    }

    // MARK: - Persistent cache

    /// Wipes both the persisted cache AND the in-memory copy. Without the
    /// latter, "Delete Calendar Data" would remove the UserDefaults key only
    /// for the next `store()` to write the whole old cache straight back.
    func clearCache() {
        cacheGeneration &+= 1
        cache = [:]
        defaults.removeObject(forKey: Self.cacheKey)
        for legacyKey in Self.legacyCacheKeys {
            defaults.removeObject(forKey: legacyKey)
        }
    }

    private func loadCacheIfNeeded() {
        guard cache == nil else { return }
        // V1 positives were never scored. Remove the legacy blob rather than
        // preserving unsafe geography or private calendar-derived cache keys.
        for legacyKey in Self.legacyCacheKeys {
            defaults.removeObject(forKey: legacyKey)
        }
        if let data = defaults.data(forKey: Self.cacheKey),
           let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    private func store(key: String, place: ForwardGeocodedPlace?) {
        loadCacheIfNeeded()
        cache?[key] = CacheEntry(place: place, cachedAt: .now)
        // Bounded: evict oldest entries past capacity (rare — capacity is
        // far above calendar-scale distinct strings).
        if let current = cache, current.count > Self.cacheCapacity {
            let sorted = current.sorted { $0.value.cachedAt < $1.value.cachedAt }
            for (evictKey, _) in sorted.prefix(current.count - Self.cacheCapacity) {
                cache?.removeValue(forKey: evictKey)
            }
        }
        persistCache()
    }

    private func cachedResolution(forKey key: String, now: Date) -> CachedResolution {
        guard let entry = cache?[key] else { return .miss }
        if let place = entry.place { return .resolved(place) }
        if Self.negativeCacheIsFresh(cachedAt: entry.cachedAt, now: now) {
            return .unresolved
        }
        cache?.removeValue(forKey: key)
        persistCache()
        return .miss
    }

    private func persistCache() {
        if let cache, let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: Self.cacheKey)
        }
    }

    private struct ScoredMapItem {
        let item: MKMapItem
        let reverse: GeocodeResolver.Result?
        let candidate: ForwardGeocodeMatchScorer.Candidate
    }

    private func makeScoredItems(_ items: [MKMapItem]) async -> [ScoredMapItem] {
        var result: [ScoredMapItem] = []
        result.reserveCapacity(min(items.count, Self.maximumScoredResults))
        for (rank, item) in items.prefix(Self.maximumScoredResults).enumerated() {
            guard !Task.isCancelled else { break }
            let coordinate = item.location.coordinate
            let reverse = await GeocodeResolver.shared.resolve(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
            result.append(ScoredMapItem(
                item: item,
                reverse: reverse,
                candidate: ForwardGeocodeMatchScorer.Candidate(
                    rank: rank,
                    name: item.name,
                    address: item.address?.fullAddress,
                    mapLocality: item.addressRepresentations?.cityName,
                    mapRegion: item.addressRepresentations?.regionName,
                    pointOfInterestCategory: item.pointOfInterestCategory?.rawValue,
                    reverseLocality: reverse?.localityName,
                    reverseSubLocality: reverse?.subLocalityName,
                    reverseAdministrativeArea: reverse?.administrativeArea,
                    reverseMetro: reverse?.metroName,
                    reverseIsland: reverse?.islandName,
                    reverseCountry: reverse?.country
                )
            ))
        }
        return result
    }

#if DEBUG
    /// Opt-in on-device replay seam. It performs one uncached, unthrottled
    /// search and returns only the privacy-safe assessment; it never writes
    /// cache state or exposes MapKit/calendar text to test diagnostics.
    func liveReplayAssessment(
        for rawText: String
    ) async -> ForwardGeocodeMatchScorer.Assessment {
        // Same search text and decision as `resolveOutcome`'s Tier 2.
        let destinations = Self.destinationCandidates(
            ForwardGeocodeMatchScorer.viableQueryCandidates(from: Self.candidateStrings(from: rawText)),
            parts: Self.textParts(from: rawText)
        )
        guard let searchText = destinations.first else {
            return Self.networkAssessment(rawText: rawText, results: [])
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
        request.resultTypes = [.address, .pointOfInterest, .physicalFeature]
        do {
            let response = try await MKLocalSearch(request: request).start()
            let items = await makeScoredItems(response.mapItems)
            return Self.networkAssessment(rawText: rawText, results: items.map {
                NetworkResult(candidate: $0.candidate,
                              isoCountryCode: $0.reverse?.isoCountryCode,
                              admin1Name: $0.reverse?.administrativeArea)
            })
        } catch {
            return Self.networkAssessment(rawText: rawText, results: [])
        }
    }
#endif
}
