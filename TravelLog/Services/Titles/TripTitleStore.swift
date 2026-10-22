//
//  TripTitleStore.swift
//  TravelLog
//

import Foundation
import CryptoKit
import SwiftData
import os

/// The single persistence policy for localized trip titles.
///
/// `Trip.aiGeneratedTitle` remains the canonical English title so older app
/// versions continue to show a useful name. `TripTitleVariant` rows are
/// derivatives of that canonical value. A row is displayable only while its
/// `sourceTitle` and `sourceRevision` match the current canonical title. The
/// revision makes a late CloudKit delivery harmless even when a later title
/// happens to reuse identical English text.
nonisolated enum TripTitleStore {

    /// The active-home fields that can reach canonical titles. Keeping this
    /// shape shared with home mutations prevents a locality/country edit from
    /// leaving titles derived from the previous inputs eligible. The id only
    /// orders rows; title comparisons use the id-free content set.
    struct ActiveHomeTitleInput: Codable, Equatable, Sendable {
        let id: UUID
        let locality: String?
        let country: String?
        let isoCountryCode: String?
    }

    /// Value-only ordering payload shared by live rows and serialized mirrors.
    /// Keeping one comparator prevents export/import/restore array order from
    /// choosing different content for otherwise identical CloudKit twins.
    struct ContentValue: Sendable {
        let id: UUID
        let title: String
        let generationVersion: Int
        let updatedAt: Date
    }

    struct SemanticSnapshot: Codable, Equatable, Sendable {
        struct StayInput: Codable, Equatable, Sendable {
            let id: UUID
            let orderInTrip: Int?
            let startTime: Date
            let endTime: Date
            let durationMinutes: Int
            let categoryRaw: String
            let isAirport: Bool
            let metroName: String?
            let islandName: String?
            let locality: String?
            let administrativeArea: String?
            let country: String?
            let isoCountryCode: String?
        }

        let tripID: UUID
        let startDate: Date
        let endDate: Date?
        let isComplete: Bool
        let customName: String?
        let stays: [StayInput]
    }

    /// Same-context capture used by maintenance writers that mutate Stay
    /// fields in place. Object identity, rather than the app UUID, keeps
    /// physical CloudKit twins independent until their deduplicator runs.
    struct ParentSemanticSnapshot {
        let trip: Trip
        let semantic: SemanticSnapshot
    }

    /// Bump when the localization prompt or validation policy changes enough
    /// that an existing variant should be regenerated lazily.
    static let currentGenerationVersion = 1
    /// v3 hashes the id-free content set, so the first run after upgrade
    /// records a fresh baseline instead of comparing against an id-bearing hash.
    static let activeHomeTitleFingerprintKey =
        "activeHomeTitleFingerprint_v3"

    /// Exact, value-only title input owned by a Trip. It is intentionally not
    /// persisted: callers compare it after asynchronous model work, while its
    /// stable digest scopes local retry bookkeeping without storing place names.
    static func semanticSnapshot(for trip: Trip) -> SemanticSnapshot {
        SemanticSnapshot(
            tripID: trip.id,
            startDate: trip.startDate,
            endDate: trip.endDate,
            isComplete: trip.isComplete,
            customName: trip.customName,
            stays: trip.orderedStays.map { stay in
                SemanticSnapshot.StayInput(
                    id: stay.id,
                    orderInTrip: stay.orderInTrip,
                    startTime: stay.startTime,
                    endTime: stay.endTime,
                    durationMinutes: stay.durationMinutes,
                    categoryRaw: stay.categoryRaw,
                    isAirport: stay.isAirport,
                    metroName: stay.metroName,
                    islandName: stay.islandName,
                    locality: stay.locality,
                    administrativeArea: stay.administrativeArea,
                    country: stay.country,
                    isoCountryCode: stay.isoCountryCode)
            })
    }

    static func parentSemanticSnapshots(
        for stays: [Stay]
    ) -> [ParentSemanticSnapshot] {
        var seen = Set<ObjectIdentifier>()
        var result: [ParentSemanticSnapshot] = []
        for stay in stays {
            guard let trip = stay.trip else { continue }
            let identity = ObjectIdentifier(trip)
            guard seen.insert(identity).inserted else { continue }
            result.append(ParentSemanticSnapshot(
                trip: trip,
                semantic: semanticSnapshot(for: trip)))
        }
        return result
    }

    /// Recompute derived trip fields and invalidate canonical/localized title
    /// artifacts only when a writer actually changed a prompt input.
    /// Every changed parent is processed first; the call then throws
    /// `HomePlaceNamesUnreadable` when any summary was built without its
    /// home-place filter. Units that latch or commit once roll back on it;
    /// a writer that may keep a degraded summary uses `try?`.
    @discardableResult
    static func invalidateChangedParentTitles(
        from snapshots: [ParentSemanticSnapshot],
        in context: ModelContext
    ) throws -> Int {
        var changed = 0
        var homePlacesRead = true
        for snapshot in snapshots {
            let trip = snapshot.trip
            guard !trip.isDeleted,
                  snapshot.semantic != semanticSnapshot(for: trip) else {
                continue
            }
            if !trip.recomputeSummary() { homePlacesRead = false }
            invalidateGeneratedTitles(for: trip, in: context)
            changed += 1
        }
        guard homePlacesRead else { throw HomePlaceNamesUnreadable() }
        return changed
    }

    static func fetchActiveHomeTitleInputs(
        in context: ModelContext
    ) throws -> [ActiveHomeTitleInput] {
        let predicate = #Predicate<Home> { $0.endedAt == nil }
        let homes = try context.fetch(
            FetchDescriptor<Home>(predicate: predicate))
        return homes.map {
            ActiveHomeTitleInput(
                id: $0.id,
                locality: normalized($0.locality).map(normalizedPlaceName),
                country: $0.country,
                isoCountryCode: $0.isoCountryCode)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    static func activeHomeTitleFingerprint(
        for inputs: [ActiveHomeTitleInput]
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(activeHomePromptContent(inputs)))
            ?? Data()
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Whether a fingerprint persisted in a Removed Trips recovery record
    /// still describes today's active Homes. Records parked by builds before
    /// v3 carry the id-bearing hash; it matches only when the same rows still
    /// hold the same content, so their titles stay exactly as valid as then.
    static func activeHomeTitleFingerprintMatches(
        _ recorded: String?,
        currentInputs inputs: [ActiveHomeTitleInput]
    ) -> Bool {
        guard let recorded else { return false }
        return recorded == activeHomeTitleFingerprint(for: inputs)
            || recorded == legacyIDBearingActiveHomeTitleFingerprint(for: inputs)
    }

    /// Frozen v2 row shape. Never change it: it reproduces bytes that older
    /// builds hashed into recovery records that may still be parked.
    private struct LegacyIDBearingActiveHomeTitleInput: Encodable {
        let id: UUID
        let locality: String?
        let country: String?
        let isoCountryCode: String?
    }

    private static func legacyIDBearingActiveHomeTitleFingerprint(
        for inputs: [ActiveHomeTitleInput]
    ) -> String {
        let rows = inputs
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map {
                LegacyIDBearingActiveHomeTitleInput(
                    id: $0.id,
                    locality: $0.locality,
                    country: $0.country,
                    isoCountryCode: $0.isoCountryCode)
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(rows)) ?? Data()
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Whether two active-Home sets contribute the same semantic content to
    /// titles. Physical ids only provide deterministic ordering, and titles
    /// read Home localities as a set; replacing an onboarding twin with the
    /// backup's equivalent Home, or collapsing a same-content twin, must not
    /// invalidate otherwise faithful title artifacts.
    static func hasEquivalentActiveHomePromptContent(
        _ lhs: [ActiveHomeTitleInput],
        _ rhs: [ActiveHomeTitleInput]
    ) -> Bool {
        activeHomePromptContent(lhs) == activeHomePromptContent(rhs)
    }

    private static func activeHomePromptContent(
        _ inputs: [ActiveHomeTitleInput]
    ) -> [[String]] {
        Set(inputs.map { input in
            [
                input.locality ?? "",
                input.country ?? "",
                input.isoCountryCode ?? "",
            ]
        }).sorted { left, right in
            for index in left.indices where left[index] != right[index] {
                return left[index] < right[index]
            }
            return false
        }
    }

    static func recordActiveHomeTitleFingerprint(
        in context: ModelContext,
        defaults: UserDefaults = .standard
    ) throws {
        defaults.set(
            activeHomeTitleFingerprint(
                for: try fetchActiveHomeTitleInputs(in: context)),
            forKey: activeHomeTitleFingerprintKey)
    }

    /// Detects Home prompt changes that arrived outside a local writer (most
    /// importantly a completed CloudKit import). The hash stores no raw place
    /// text. A first run preserves existing generated artifacts while
    /// establishing a trustworthy baseline for future comparisons.
    @discardableResult
    static func reconcileActiveHomeTitleFingerprint(
        in context: ModelContext,
        defaults: UserDefaults = .standard,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> Int {
        let inputs = try fetchActiveHomeTitleInputs(in: context)
        let fingerprint = activeHomeTitleFingerprint(for: inputs)
        guard let previous = defaults.string(
            forKey: activeHomeTitleFingerprintKey) else {
            // Upgrade baseline: absence does not prove the Home prompt changed.
            // Preserve every durable title and begin detecting from this point.
            defaults.set(fingerprint, forKey: activeHomeTitleFingerprintKey)
            return 0
        }
        guard previous != fingerprint else { return 0 }

        let trips = try context.fetch(FetchDescriptor<Trip>())
        var invalidated = 0
        for trip in trips where !trip.isDeleted {
            guard normalized(trip.aiGeneratedTitle) != nil
                    || !(trip.localizedTitles ?? []).isEmpty else { continue }
            invalidateGeneratedTitles(for: trip, in: context)
            invalidated += 1
        }
        do {
            if invalidated > 0 { try save(context) }
            defaults.set(fingerprint, forKey: activeHomeTitleFingerprintKey)
            return invalidated
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Invalidate the library only when the active-home content set changed.
    /// Radius/coordinate-only edits remain on the classifier's targeted path;
    /// physical ids and same-content twins never invalidate, while a changed
    /// locality or country, or a new or ended distinct Home, does.
    @discardableResult
    static func invalidateAllGeneratedTitlesIfActiveHomesChanged(
        from before: [ActiveHomeTitleInput],
        in context: ModelContext,
        preserving preservedTrips: [Trip] = []
    ) throws -> Bool {
        guard !hasEquivalentActiveHomePromptContent(
            before, try fetchActiveHomeTitleInputs(in: context)) else {
            return false
        }
        let preservedIdentities = Set(preservedTrips.map(ObjectIdentifier.init))
        let trips = try context.fetch(FetchDescriptor<Trip>())
        for trip in trips where !trip.isDeleted
                && !preservedIdentities.contains(ObjectIdentifier(trip)) {
            invalidateGeneratedTitles(for: trip, in: context)
        }
        return true
    }

    /// Trip identity may change during an exact-membership rebuild, but title
    /// inputs may not. Compare every prompt-relevant field except the row UUID
    /// before carrying canonical/localized titles onto the rebuilt row.
    static func hasSameSemanticInputs(
        _ lhs: SemanticSnapshot,
        _ rhs: SemanticSnapshot
    ) -> Bool {
        lhs.startDate == rhs.startDate
            && lhs.endDate == rhs.endDate
            && lhs.isComplete == rhs.isComplete
            && lhs.customName == rhs.customName
            && lhs.stays == rhs.stays
    }

    static func semanticDigest(for snapshot: SemanticSnapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(snapshot) else {
            // All fields above are primitive Codable values, so this is a
            // defensive fallback rather than an expected runtime path.
            return snapshot.tripID.uuidString
        }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Choose the best CONTENT for one logical title. Physical-row cleanup uses
    /// immutable identity separately: allowing mutable content metadata to pick
    /// the survivor lets two devices delete each other's rows after concurrent
    /// writes. See `TripTitleVariantDeduplicator`.
    static func hasPreferredContent(
        _ candidate: TripTitleVariant,
        over incumbent: TripTitleVariant
    ) -> Bool {
        hasPreferredContent(
            ContentValue(
                id: candidate.id,
                title: candidate.title,
                generationVersion: candidate.generationVersion,
                updatedAt: candidate.updatedAt),
            over: ContentValue(
                id: incumbent.id,
                title: incumbent.title,
                generationVersion: incumbent.generationVersion,
                updatedAt: incumbent.updatedAt))
    }

    static func hasPreferredContent(
        _ candidate: ContentValue,
        over incumbent: ContentValue
    ) -> Bool {
        if candidate.generationVersion != incumbent.generationVersion {
            return candidate.generationVersion > incumbent.generationVersion
        }
        if candidate.updatedAt != incumbent.updatedAt {
            return candidate.updatedAt > incumbent.updatedAt
        }
        if candidate.id != incumbent.id {
            return candidate.id.uuidString < incumbent.id.uuidString
        }
        // Imported same-ID twins have no physical identity tiebreaker. Content
        // provides a final stable order for display/absorption without deleting
        // either indistinguishable row.
        let candidateTitle = normalized(candidate.title) ?? candidate.title
        let incumbentTitle = normalized(incumbent.title) ?? incumbent.title
        if candidateTitle != incumbentTitle { return candidateTitle < incumbentTitle }
        return candidate.title < incumbent.title
    }

    /// Choose a physical survivor using immutable application identity only.
    /// Rows with the same UUID are indistinguishable across CloudKit replicas;
    /// callers must retain those twins rather than risk reciprocal deletion.
    static func hasPreferredSurvivorIdentity(
        _ candidate: TripTitleVariant,
        over incumbent: TripTitleVariant
    ) -> Bool {
        candidate.id.uuidString < incumbent.id.uuidString
    }

    private static let listBoundaryPatterns: [String: NSRegularExpression] = {
        let conjunctions: [String: [String]] = [
            "en": ["and"], "da": ["og"], "nb": ["og"], "de": ["und"], "el": ["και"], "es": ["y", "e"],
            "fr": ["et"], "it": ["e"], "nl": ["en"], "sv": ["och"],
            "pl": ["i"], "tr": ["ve"], "vi": ["và"], "pt": ["e"], "": [],
        ]
        return conjunctions.mapValues { languageConjunctions in
            let connectors = ["and"] + languageConjunctions
            let escaped = connectors.map { NSRegularExpression.escapedPattern(for: $0) }
            let conjunction = "(?<![\\p{L}\\p{N}])(?:" + escaped.joined(separator: "|") + ")(?![\\p{L}\\p{N}])"
            // Match comma + one conjunction as a single boundary before matching
            // individual separators. Leading/trailing pairs still create an empty
            // member and are rejected below.
            let pattern = "(?i)[,，]\\s*" + conjunction + "|" + conjunction + "|[&,;/、，]"
            return try! NSRegularExpression(pattern: pattern)
        }
    }()

    static func hasCompleteListBoundaries(_ title: String, languageTag: String) -> Bool {
        let language = String(languageTag.prefix(2))
        let pattern = listBoundaryPatterns[language] ?? listBoundaryPatterns[""]!
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        let normalized = pattern.stringByReplacingMatches(in: title, range: range, withTemplate: "|")
        return normalized.components(separatedBy: "|").allSatisfy {
            $0.rangeOfCharacter(from: .letters) != nil
        }
    }

    /// Whether a localized title has display and storage authority: non-blank
    /// and a complete list for its language. Every site that ranks, carries,
    /// imports or exports variants filters with this BEFORE choosing content,
    /// so an invisible malformed row can never outrank a valid one.
    static func isUsableVariantTitle(_ title: String, languageTag: String) -> Bool {
        guard let title = normalized(title) else { return false }
        return hasCompleteListBoundaries(title, languageTag: languageTag)
    }

    /// The current, source-matching row for one language. Invalid, stale, and
    /// duplicate rows remain invisible while CloudKit convergence catches up.
    static func preferredVariant(
        for trip: Trip,
        languageTag: String,
        minimumGenerationVersion: Int = currentGenerationVersion
    ) -> TripTitleVariant? {
        guard let languageTag = AppLanguagePreference.normalizedSupportedTag(languageTag),
              languageTag != "en",
              let sourceTitle = normalized(trip.aiGeneratedTitle) else {
            return nil
        }

        var winner: TripTitleVariant?
        for variant in trip.localizedTitles ?? [] {
            guard AppLanguagePreference.normalizedSupportedTag(variant.languageTag) == languageTag,
                  variant.sourceTitle == sourceTitle,
                  variant.sourceRevision == trip.titleSourceRevision,
                  variant.generationVersion >= minimumGenerationVersion,
                  isUsableVariantTitle(
                    variant.title, languageTag: languageTag) else {
                continue
            }
            if let incumbent = winner {
                if hasPreferredContent(variant, over: incumbent) { winner = variant }
            } else {
                winner = variant
            }
        }
        return winner
    }

    static func localizedTitle(
        for trip: Trip,
        languageTag: String,
        minimumGenerationVersion: Int = currentGenerationVersion
    ) -> String? {
        preferredVariant(
            for: trip,
            languageTag: languageTag,
            minimumGenerationVersion: minimumGenerationVersion
        ).flatMap { normalized($0.title) }
    }

    /// Replace the canonical title and invalidate every derivative when its
    /// source text changed. Returns whether persistent state changed.
    @discardableResult
    static func replaceCanonicalTitle(
        _ rawTitle: String?,
        for trip: Trip,
        in context: ModelContext,
        invalidateVariantsEvenIfUnchanged: Bool = false
    ) -> Bool {
        let title = normalized(rawTitle)
        let oldTitle = normalized(trip.aiGeneratedTitle)
        let sourceChanged = oldTitle != title
        guard sourceChanged || invalidateVariantsEvenIfUnchanged else {
            return false
        }

        if sourceChanged { trip.aiGeneratedTitle = title }
        // Rotate for every non-nil canonical replacement, including equal-text
        // forced regeneration. Clearing the canonical also clears its revision;
        // any later replacement receives a distinct revision of its own.
        trip.titleSourceRevision = title == nil ? nil : UUID()
        deleteAllVariants(for: trip, in: context)
        return true
    }

    /// A semantic trip mutation invalidates the canonical title even if a
    /// future generator happens to produce the same string. Removing the
    /// variants here prevents an old translation from becoming eligible again
    /// solely because that new source text happens to compare equal.
    static func invalidateGeneratedTitles(for trip: Trip, in context: ModelContext) {
        _ = replaceCanonicalTitle(
            nil,
            for: trip,
            in: context,
            invalidateVariantsEvenIfUnchanged: true)
    }

    static func deleteAllVariants(for trip: Trip, in context: ModelContext) {
        let variants = Array(trip.localizedTitles ?? [])
        for variant in variants { context.delete(variant) }
        if !variants.isEmpty { trip.localizedTitles = [] }
    }

    /// Insert or update one source-matching variant and collapse any local
    /// duplicates. Stale-source rows are deliberately left alone: CloudKit
    /// can deliver a variant before the corresponding canonical Trip update,
    /// and eagerly deleting it would turn harmless record ordering into data
    /// loss. The resolver ignores such rows until their source becomes current.
    @discardableResult
    static func upsertVariant(
        languageTag: String,
        title rawTitle: String,
        sourceTitle rawSourceTitle: String,
        generationVersion: Int = currentGenerationVersion,
        updatedAt: Date = .now,
        for trip: Trip,
        in context: ModelContext
    ) -> Bool {
        guard let languageTag = AppLanguagePreference.normalizedSupportedTag(languageTag),
              languageTag != "en",
              let title = normalized(rawTitle),
              hasCompleteListBoundaries(title, languageTag: languageTag),
              let sourceTitle = normalized(rawSourceTitle),
              normalized(trip.aiGeneratedTitle) == sourceTitle else {
            return false
        }

        // Migrated V15 trips and legacy imports have no revision. Establish it
        // lazily at the first localized write; nil/nil legacy rows remain
        // readable until this point, then become safely stale.
        let sourceRevision = trip.titleSourceRevision ?? UUID()
        var initializedRevision = false
        if trip.titleSourceRevision == nil {
            trip.titleSourceRevision = sourceRevision
            initializedRevision = true
            // V15 migrations and v7 backups legitimately have nil revisions.
            // Adopt only rows for the currently visible canonical source; all
            // other rows stay stale and retain their original identity.
            for row in trip.localizedTitles ?? []
            where row.sourceRevision == nil
                && normalized(row.sourceTitle) == sourceTitle {
                row.sourceRevision = sourceRevision
            }
        }

        let matches = (trip.localizedTitles ?? []).filter {
            AppLanguagePreference.normalizedSupportedTag($0.languageTag) == languageTag
                && $0.sourceTitle == sourceTitle
                && $0.sourceRevision == sourceRevision
        }
        let validMatches = matches.filter {
            isUsableVariantTitle($0.title, languageTag: languageTag)
        }
        let contentWinner = validMatches.reduce(nil as TripTitleVariant?) { current, candidate in
            guard let current else { return candidate }
            return hasPreferredContent(candidate, over: current) ? candidate : current
        }

        if let survivor = matches.min(by: {
            hasPreferredSurvivorIdentity($0, over: $1)
        }) {
            var changed = false
            let incomingWins: Bool
            if let contentWinner {
                incomingWins = generationVersion > contentWinner.generationVersion
                    || (generationVersion == contentWinner.generationVersion
                        && (updatedAt > contentWinner.updatedAt
                            || (updatedAt == contentWinner.updatedAt
                                && title < (normalized(contentWinner.title)
                                    ?? contentWinner.title))))
            } else {
                // Malformed rows have no storage authority and cannot block a
                // valid generated/imported translation, regardless of metadata.
                incomingWins = true
            }

            let bestTitle = incomingWins
                ? title
                : (contentWinner.flatMap { normalized($0.title) } ?? title)
            let bestGeneration = incomingWins
                ? generationVersion
                : (contentWinner?.generationVersion ?? generationVersion)
            let bestUpdatedAt = incomingWins
                ? updatedAt
                : (contentWinner?.updatedAt ?? updatedAt)

            // Same-UUID twins cannot be uniquely identified on another device.
            // Make their content identical and keep them both. Distinct UUIDs
            // can be safely converged onto the immutable survivor UUID.
            for row in matches where row.id == survivor.id {
                if row.languageTag != languageTag {
                    row.languageTag = languageTag
                    changed = true
                }
                if row.title != bestTitle {
                    row.title = bestTitle
                    changed = true
                }
                if row.generationVersion != bestGeneration {
                    row.generationVersion = bestGeneration
                    changed = true
                }
                if row.updatedAt != bestUpdatedAt {
                    row.updatedAt = bestUpdatedAt
                    changed = true
                }
            }
            for duplicate in matches where duplicate.id != survivor.id {
                context.delete(duplicate)
                changed = true
            }
            return changed || initializedRevision
        }

        let variant = TripTitleVariant(
            languageTag: languageTag,
            title: title,
            sourceTitle: sourceTitle,
            sourceRevision: sourceRevision,
            generationVersion: generationVersion,
            updatedAt: updatedAt,
            trip: trip)
        context.insert(variant)
        for malformed in matches { context.delete(malformed) }
        return true
    }

    static func normalized(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Home place names

extension TripTitleStore {

    /// How far around a trip's dates home-category stays still count as
    /// "home at the time": wide enough to bridge a tracking gap or a long
    /// trip, narrow enough that a home the user left years earlier no
    /// longer claims its old city. `Home` rows use their own exact era.
    nonisolated static let homeEraPaddingDays = 180

    /// The place names that mean "home" around a trip's dates, in
    /// `normalizedPlaceName` form. Two sources, both era-aware:
    /// - home-category stays within `homeEraPaddingDays` of the trip, by
    ///   `metroName ?? islandName ?? locality` — the SAME display-name rule
    ///   destination grouping uses, so a suburb home whose own locality is
    ///   "Palaio Faliro" yields the metro token its trip stays carry ("Athens");
    /// - every `Home` row whose era (`startedAt`…`endedAt`) overlaps the
    ///   trip itself, by locality.
    ///
    /// A temporary home is exact, like a `Home` row: its locality and the
    /// names of the home stays it owns apply only to trips that overlap its
    /// own dates, and those stays stay out of the padded window. A semester
    /// in Brussels must not keep "Brussels" out of titles for 180 days on
    /// either side of it.
    ///
    /// `destinations` gives the trip's destination stays as (place name,
    /// minutes). A name only a temporary home contributes is not a home place
    /// for a trip that spends more than half of its destination minutes
    /// there: that trip is at the base (one the declaration kept whole), not
    /// passing a suburb of it. Real-home names ignore `destinations`, and it
    /// is called only when a temporary home's dates overlap the trip.
    /// `Trip.recomputeSummary` and the classifier's title paths both get
    /// their set here.
    ///
    /// A destination named like one of these is not a title candidate. The
    /// geocoder's metro is a commuting zone, so a wait at a nearby ferry port
    /// or a fuel stop in north Attica carries "Athens", and both the model
    /// and the deterministic fallback could title Aegina trips "Aegina & Athens"
    /// under their own rules. Empty when the store has no homes;
    /// throws `HomePlaceNamesUnreadable` when the rows could not be read,
    /// which is not absence.
    ///
    /// Reads go through `HomePlaceIndex`: one projection fetch of every
    /// home stay, every Home and every temporary home per container, reused
    /// for 30 seconds and dropped on any stay, home or temporary-home write,
    /// so a pass that recomputes hundreds of trips
    /// (`Trip.recomputeSummary` on each) costs one query.
    ///
    /// A name whose every source knows its country also comes with one
    /// `homePlaceCountryEntry` per country, so a foreign namesake (London,
    /// Canada for a London, UK home) stays a destination; compare through
    /// `isHomePlace(_:isoCountryCode:in:)`, never by name alone. A source
    /// without a country keeps its name a home place everywhere.
    nonisolated static func homePlaceNames(
        tripStart: Date,
        tripEnd: Date,
        destinations: () -> [(name: String, minutes: Int)] = { [] },
        in context: ModelContext
    ) throws -> Set<String> {
        let index = try HomePlaceIndex.current(for: context)
        var names = Set<String>()
        var countries: [String: Set<String>] = [:]
        var anywhere = Set<String>()
        func add(_ name: String, _ iso: String?) {
            names.insert(name)
            if let code = homeCountryCode(iso) {
                countries[name, default: []].insert(code)
            } else {
                anywhere.insert(name)
            }
        }
        let padding = TimeInterval(homeEraPaddingDays) * 86_400
        let lower = tripStart.addingTimeInterval(-padding)
        let upper = tripEnd.addingTimeInterval(padding)
        for stay in index.stays where stay.time >= lower && stay.time <= upper {
            add(stay.name, stay.iso)
        }
        for home in index.homes
        where home.start <= tripEnd && (home.end ?? .distantFuture) >= tripStart {
            add(home.name, home.iso)
        }
        let temporary = index.temporaryHomes.filter {
            $0.start <= tripEnd && ($0.end ?? .distantFuture) >= tripStart
                && !names.contains($0.name)
        }
        if !temporary.isEmpty {
            var minutes: [String: Int] = [:]
            var total = 0
            for destination in destinations() {
                minutes[normalizedPlaceName(destination.name), default: 0] += destination.minutes
                total += destination.minutes
            }
            for home in temporary where 2 * (minutes[home.name] ?? 0) <= total {
                add(home.name, home.iso)
            }
        }
        names.remove("")
        for (name, codes) in countries where !name.isEmpty && !anywhere.contains(name) {
            for code in codes { names.insert(homePlaceCountryEntry(name: name, isoCountryCode: code)) }
        }
        return names
    }

    /// Joins a home place name to a country it is home in; no place name
    /// holds this control character.
    nonisolated static let homePlaceCountrySeparator = "\u{1F}"

    /// The entry `homePlaceNames` adds for `name` (normalized) at home in `isoCountryCode`.
    nonisolated static func homePlaceCountryEntry(name: String, isoCountryCode: String) -> String {
        name + homePlaceCountrySeparator + isoCountryCode
    }

    /// Whether `entry` of `homePlaceNames` is a country entry, not a name.
    nonisolated static func isHomePlaceCountryEntry(_ entry: String) -> Bool {
        entry.contains(homePlaceCountrySeparator)
    }

    /// A known two-letter country code, uppercased; nil when missing or not one.
    nonisolated static func homeCountryCode(_ raw: String?) -> String? {
        guard let code = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              code.count == 2, code != "ZZ",
              code.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }) else { return nil }
        return code
    }

    /// Whether a place called `name` in `isoCountryCode` is one of
    /// `homePlaceNames`: the same normalized name, unless both sides know
    /// their countries and none of the home's is the place's. A missing or
    /// invalid country on either side keeps the name-only match.
    nonisolated static func isHomePlace(
        _ name: String, isoCountryCode: String?, in homePlaceNames: Set<String>
    ) -> Bool {
        let key = normalizedPlaceName(name)
        guard homePlaceNames.contains(key) else { return false }
        guard let code = homeCountryCode(isoCountryCode) else { return true }
        let prefix = key + homePlaceCountrySeparator
        let homeCountries = homePlaceNames.filter { $0.hasPrefix(prefix) }
        return homeCountries.isEmpty || homeCountries.contains(prefix + code)
    }

    /// A failed home-place read. Summaries and titles built on it would
    /// name the user's home, so required writers roll back instead.
    nonisolated struct HomePlaceNamesUnreadable: Error {}

    /// Drop every cached home-place index. Called on stay, home and
    /// temporary-home writes (`StoreChangeTracker.bump`) and safe to call
    /// any time; the next read refetches.
    nonisolated static func invalidateHomePlaceIndex() {
        HomePlaceIndex.invalidate()
    }

    /// Lowercased, diacritic-free Latin with collapsed whitespace — the
    /// comparison form for place names from any script ("Köniz " and
    /// "koniz" meet here). Both ICU transforms are the identity on ASCII,
    /// so ASCII names (most stored names) skip them; each transform call
    /// builds a new ICU transliterator, so other names are memoized.
    nonisolated static func normalizedPlaceName(_ name: String) -> String {
        func folded(_ value: String) -> String {
            value.lowercased()
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        }
        if name.utf8.allSatisfy({ $0 < 0x80 }) { return folded(name) }
        // Exact bytes, not String equality (canonical equivalence): two
        // equivalent spellings need not transliterate alike.
        let key = Array(name.utf8)
        if let memoized = nonASCIIPlaceNames.withLock({ $0[key] }) { return memoized }
        let latin = name.applyingTransform(.toLatin, reverse: false)
        let stripped = (latin ?? name).applyingTransform(.stripDiacritics, reverse: false)
        let normalized = folded(stripped ?? latin ?? name)
        // A failed transform is retried next call, as before the memo.
        if latin != nil, stripped != nil, key.count <= memoMaxBytes {
            nonASCIIPlaceNames.withLock { memo in
                if memo.count < memoCapacity { memo[key] = normalized }
            }
        }
        return normalized
    }

    /// Bounds for the process-lifetime transliteration memos: place names
    /// are short, and once full the memo keeps what it has.
    nonisolated static let memoCapacity = 2_048
    nonisolated static let memoMaxBytes = 256

    nonisolated private static let nonASCIIPlaceNames = OSAllocatedUnfairLock(
        initialState: [[UInt8]: String]())

    /// Per-container snapshot of every home-category stay's (time, name)
    /// and every Home's (name, era). A temporary home adds era entries of its
    /// own, one per name, and takes the stays it owns out of the stay list.
    /// Keyed by container so test containers never see each other's rows; a
    /// time-to-live bounds staleness where no tracker runs (the widget).
    nonisolated enum HomePlaceIndex {
        /// Each name with the country its source records, if any.
        struct Snapshot: Sendable {
            let fetchedAt: Date
            let stays: [(time: Date, name: String, iso: String?)]
            let homes: [(name: String, iso: String?, start: Date, end: Date?)]
            /// Kept apart from `homes`: `homePlaceNames` drops one for a trip at the base.
            let temporaryHomes: [(name: String, iso: String?, start: Date, end: Date?)]
        }

        /// One name a temporary home's stays carry, with its country.
        private struct HomePlace: Hashable {
            let name: String
            let iso: String?
        }

        static let timeToLive: TimeInterval = 30

        #if DEBUG
        /// Per-invocation read fault: the index is a static cache shared by
        /// parallel tests, so an instance or global flag would leak.
        @TaskLocal static var failFetchForTesting = false
        #endif

        /// Snapshots and the invalidation generation share one lock so a
        /// fetch that raced an invalidation is never installed: the fill
        /// compares the generation it started under before storing.
        private struct State {
            var generation = 0
            var snapshots: [ObjectIdentifier: Snapshot] = [:]
        }
        private static let state = OSAllocatedUnfairLock(initialState: State())

        /// A snapshot a write unit built from its own context, unsaved writes
        /// included. While it is set every read in that task uses it: another
        /// context cannot refill the shared cache with the rows from before
        /// those writes in between.
        @TaskLocal static var pinned: Snapshot?

        /// A fresh snapshot of `context`, its unsaved changes included,
        /// neither read from the cache nor stored in it.
        static func uncached(for context: ModelContext, now: Date = .now) throws -> Snapshot {
            #if DEBUG
            if failFetchForTesting { throw HomePlaceNamesUnreadable() }
            #endif
            return try fetch(in: context, now: now)
        }

        /// A failed fill throws and is never cached, so a later read retries.
        static func current(for context: ModelContext, now: Date = .now) throws -> Snapshot {
            if let pinned { return pinned }
            #if DEBUG
            if failFetchForTesting { throw HomePlaceNamesUnreadable() }
            #endif
            let key = ObjectIdentifier(context.container)
            let (cached, generation) = state.withLock { ($0.snapshots[key], $0.generation) }
            if let cached, now.timeIntervalSince(cached.fetchedAt) < timeToLive {
                return cached
            }
            let fresh = try fetch(in: context, now: now)
            state.withLock {
                if $0.generation == generation { $0.snapshots[key] = fresh }
            }
            return fresh
        }

        static func invalidate() {
            state.withLock {
                $0.generation += 1
                $0.snapshots.removeAll()
            }
        }

        private static func fetch(in context: ModelContext, now: Date) throws -> Snapshot {
            let homeRaw = StayCategory.home.rawValue
            // With no temporary home every stay records nothing, so the
            // snapshot is exactly what it was before temporary homes.
            let temporaryHomes = try HomeAnchors.temporaryHomes(in: context)
            var descriptor = FetchDescriptor<Stay>(predicate: #Predicate { $0.categoryRaw == homeRaw })
            descriptor.propertiesToFetch = [
                \.startTime, \.metroName, \.islandName, \.locality, \.isoCountryCode, \.temporaryHomeID,
            ]
            let homeStays = try context.fetch(descriptor)
            let homeRows = try context.fetch(FetchDescriptor<Home>())
            let homes = homeRows.compactMap { home -> (name: String, iso: String?, start: Date, end: Date?)? in
                guard let locality = home.locality else { return nil }
                return (normalizedPlaceName(locality), home.isoCountryCode, home.startedAt, home.endedAt)
            }
            // A stay a temporary home recorded is named for that home's dates
            // only; one recorded as the real Home's keeps the padded window
            // (`HomeAnchors.recordedOwner`, never the nearest centre). A
            // removed or unsynced owner is no live row here: nobody's.
            let temporaryHomeIDs = Set(temporaryHomes.map(\.id))
            var stays: [(time: Date, name: String, iso: String?)] = []
            var temporaryNames: [UUID: Set<HomePlace>] = [:]
            for stay in homeStays {
                guard let name = stay.placeGroupName else { continue }
                switch HomeAnchors.recordedOwner(
                    temporaryHomeID: stay.temporaryHomeID, knownTemporaryHomeIDs: temporaryHomeIDs) {
                case .realHome:
                    stays.append((stay.startTime, normalizedPlaceName(name), stay.isoCountryCode))
                case .temporary(let id):
                    temporaryNames[id, default: []].insert(
                        HomePlace(name: normalizedPlaceName(name), iso: stay.isoCountryCode))
                case .unresolved:
                    continue
                }
            }
            var temporaryEras: [(name: String, iso: String?, start: Date, end: Date?)] = []
            for home in temporaryHomes {
                var places = temporaryNames[home.id] ?? []
                if let locality = home.locality {
                    places.insert(HomePlace(name: normalizedPlaceName(locality), iso: home.isoCountryCode))
                }
                for place in places.sorted(by: { ($0.name, $0.iso ?? "") < ($1.name, $1.iso ?? "") }) {
                    temporaryEras.append((place.name, place.iso, home.startedAt, home.endedAt))
                }
            }
            return Snapshot(
                fetchedAt: now, stays: stays, homes: homes, temporaryHomes: temporaryEras)
        }
    }
}
