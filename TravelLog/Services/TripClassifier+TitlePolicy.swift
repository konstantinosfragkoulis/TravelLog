//
//  TripClassifier+TitlePolicy.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import CryptoKit
import SwiftData
import CoreLocation
import FoundationModels
import WidgetKit
import os.log

extension TripClassifier {

    // MARK: - Title Retry Budget

    /// Bound title failures so rejected output cannot repeatedly consume the title-generation slots.
    static let titleAttemptThreshold = 2
    /// Country-island locality inputs use v8 and places named with country words use v9; retain unrelated v7 exhaustions to avoid a global retry burst.
    private static let canonicalTitlePolicyVersion = 7

    struct CanonicalTitleShape: Codable, Equatable, Sendable {
        typealias HomeInput = TripTitleStore.ActiveHomeTitleInput

        let trip: TripTitleStore.SemanticSnapshot
        let activeHomes: [HomeInput]
        let homePlaceNames: [String]
    }

    struct CanonicalTitleSourceState: Equatable, Sendable {
        let title: String?
        let revision: UUID?
    }

    struct PreparedCanonicalTitleInput: Sendable {
        let shape: CanonicalTitleShape
        let sourceState: CanonicalTitleSourceState
        let prompt: String
        /// The names the prompt lists, in prompt order and spelling: the
        /// decode grammar (`TripTitleSchema`) is built from exactly these.
        let candidates: [String]
        /// `TitlePromptMaterial.titleSpellings`: the stored spelling of each candidate.
        let titleSpellings: [String]
        /// The trip era's home place names (`TripTitleStore.homePlaceNames`),
        /// frozen with the prompt so the validator drops the SAME home-named
        /// stays from grounding that the prompt dropped from the candidates.
        let homePlaceNames: Set<String>
    }

    enum CanonicalTitleGenerationOutcome: Sendable {
        case success(String)
        /// A deterministic model response or validator failure. This may
        /// consume the bounded quality retry budget.
        case failed
        /// System pressure/assets/locale availability changed. Retry on a
        /// later trigger without spending the quality budget.
        case unavailable
        case cancelled
        /// The trip/source changed while inference was suspended.
        case discarded
    }

    /// UserDefaults key for the persistent set of trip-input revisions whose
    /// AI title generation exhausted the retry budget. Per-device intentionally —
    /// `aiGeneratedTitle` itself syncs via CloudKit, so once one device
    /// writes the deterministic fallback every device sees it; the
    /// per-device "this device tried and failed" flag is only used to
    /// avoid duplicate work BEFORE that sync completes.
    private static let failedTitleInputKeysKey = "failedTitleInputKeys_v2"
    private static let legacyFailedTitleTripIDsKey = "failedTitleTripIDs_v1"

    #if DEBUG
    @TaskLocal nonisolated static var failureDefaultsSuiteNameForTesting: String?
    #endif

    nonisolated static var failureDefaults: UserDefaults {
        #if DEBUG
        if let suite = failureDefaultsSuiteNameForTesting { return UserDefaults(suiteName: suite)! }
        #endif
        return .standard
    }

    var persistentTitleFailures: Set<String> {
        if let existing = _persistentTitleFailures { return existing }
        let arr = Self.failureDefaults.array(
            forKey: Self.failedTitleInputKeysKey) as? [String] ?? []
        let loaded = Set(arr)
        _persistentTitleFailures = loaded
        return loaded
    }

    func canonicalTitleShape(
        for trip: Trip,
        activeHomes: [CanonicalTitleShape.HomeInput],
        homePlaceNames: Set<String>
    ) -> CanonicalTitleShape {
        CanonicalTitleShape(
            trip: TripTitleStore.semanticSnapshot(for: trip),
            activeHomes: activeHomes,
            homePlaceNames: homePlaceNames.sorted())
    }

    private enum CanonicalTitleInputReadError: Error {
        case injectedHomeFetchFailure
    }

    func fetchCanonicalActiveHomeInputs() throws
        -> [CanonicalTitleShape.HomeInput] {
        #if DEBUG
        if failCanonicalHomeInputFetchForTesting {
            throw CanonicalTitleInputReadError.injectedHomeFetchFailure
        }
        #endif
        return try TripTitleStore.fetchActiveHomeTitleInputs(in: modelContext)
    }

    func titleFailureKey(for shape: CanonicalTitleShape) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = (try? encoder.encode(shape)) ?? Data(shape.trip.tripID.uuidString.utf8)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        // Match title candidate eligibility: a transit/airport layover must
        // not reset a failure budget for otherwise unchanged destinations.
        let nonTransit = shape.trip.stays.filter { $0.categoryRaw != "transit" }
        let away = nonTransit.filter { stay in
            let name = TripTitlePolicy.titlePlaceName(metro: stay.metroName, island: stay.islandName,
                locality: stay.locality, country: stay.country, iso: stay.isoCountryCode) ?? ""
            return !shape.homePlaceNames.contains(TripTitleStore.normalizedPlaceName(name))
        }
        let filtered = away.contains { $0.categoryRaw == "destination" }
            ? away : (nonTransit.isEmpty ? shape.trip.stays : nonTransit)
        let destinations = filtered.filter {
            $0.categoryRaw == "destination" && !$0.isAirport
        }
        let candidates = destinations.isEmpty ? filtered : destinations
        let forbidden = TripTitlePolicy.forbiddenCountryWords(countryInputs: shape.trip.stays.map { ($0.country, $0.isoCountryCode) })
        let usesCountryIslandLocality = candidates.contains { stay in
            guard stay.metroName == nil,
                  let island = stay.islandName,
                  let locality = TripTitleStore.normalized(stay.locality),
                  !locality.isEmpty, locality != "Unknown",
                  !TripTitlePolicy.isBareCountryName(locality, forbidden: forbidden) else { return false }
            let normalizedIsland = TripTitleStore.normalizedPlaceName(island)
            return normalizedIsland == TripTitleStore.normalizedPlaceName(stay.country ?? "")
                || normalizedIsland == TripTitleStore.normalizedPlaceName(
                    Locale(identifier: "en_US").localizedString(forRegionCode: stay.isoCountryCode ?? "") ?? "")
        }
        let containsCountryWordPlace = candidates.contains { stay in
            guard let name = TripTitlePolicy.titlePlaceName(metro: stay.metroName, island: stay.islandName,
                      locality: stay.locality, country: stay.country, iso: stay.isoCountryCode),
                  !TripTitlePolicy.isBareCountryName(name, forbidden: forbidden) else { return false }
            return TripTitlePolicy.placeWords(name).contains(where: forbidden.contains)
        }
        // A name outside ASCII lost letters to the old prompt transform
        // (Tromsø became Troms) or failed the old raw-title fallback check,
        // so a budget exhausted under those rules gets one fresh attempt.
        let containsNonASCIIPlace = candidates.contains { stay in
            (TripTitlePolicy.titlePlaceName(metro: stay.metroName, island: stay.islandName,
                locality: stay.locality, country: stay.country, iso: stay.isoCountryCode) ?? "")
                .unicodeScalars.contains { !$0.isASCII }
        }
        let policy = containsNonASCIIPlace
            ? 10 : containsCountryWordPlace
            ? 9 : (usesCountryIslandLocality ? 8 : Self.canonicalTitlePolicyVersion)
        return "\(shape.trip.tripID.uuidString)|v\(policy)|\(digest)"
    }

    func canonicalTitleSourceState(
        for trip: Trip
    ) -> CanonicalTitleSourceState {
        CanonicalTitleSourceState(
            title: TripTitleStore.normalized(trip.aiGeneratedTitle),
            revision: trip.titleSourceRevision)
    }

    func sourceStillMatches(
        _ expected: CanonicalTitleSourceState,
        trip: Trip
    ) -> Bool {
        canonicalTitleSourceState(for: trip) == expected
    }

    func shapeStillMatches(
        _ expected: CanonicalTitleShape,
        trip: Trip
    ) -> Bool {
        matchingHomePlaceNames(expected, trip: trip) != nil
    }

    /// The home-place names the shape was just validated with, so a fallback
    /// written in the same unit uses exactly that set. Nil on a changed shape
    /// or an unreadable input: fail closed, spending no retry budget.
    func matchingHomePlaceNames(
        _ expected: CanonicalTitleShape,
        trip: Trip
    ) -> Set<String>? {
        guard let activeHomes = try? fetchCanonicalActiveHomeInputs(),
              let homeNames = try? homePlaceNames(for: trip),
              canonicalTitleShape(
                for: trip,
                activeHomes: activeHomes,
                homePlaceNames: homeNames) == expected else {
            return nil
        }
        return homeNames
    }

    /// Freeze the complete title input before Foundation Models suspends this
    /// actor. The apply half compares the same value after re-fetching the row,
    /// so a classification, membership, place-name, home, or date edit always
    /// wins over an obsolete model response.
    func prepareCanonicalTitleInput(
        for trip: Trip
    ) -> PreparedCanonicalTitleInput? {
        // Home rows are a first-class part of both the model prompt and the
        // retry/apply CAS identity. Fetch them once, fail closed, and reuse
        // the exact value for both; two independent best-effort reads could
        // otherwise validate a prompt that said "Home: not configured."
        // against a real active-Home set.
        guard let activeHomes = try? fetchCanonicalActiveHomeInputs() else {
            return nil
        }
        // Share one home-name snapshot between prompt exclusion and validator
        // grounding. An unreadable one is not "no home": retry later.
        guard let homeNames = try? homePlaceNames(for: trip),
              !trip.isDeleted else { return nil }
        let material = titlePromptMaterial(for: trip, homePlaceNames: homeNames)
        return PreparedCanonicalTitleInput(
            shape: canonicalTitleShape(
                for: trip,
                activeHomes: activeHomes,
                homePlaceNames: homeNames),
            sourceState: canonicalTitleSourceState(for: trip),
            prompt: material.prompt,
            candidates: material.candidates,
            titleSpellings: material.titleSpellings,
            homePlaceNames: homeNames)
    }

    /// The trip era's home place names, from the classifier's own context.
    /// Sync and cheap (a bounded projection fetch), so the prompt, the
    /// validator and both fallback sites read one consistent set. Throws when
    /// the rows are unreadable; title work then fails closed. The destinations
    /// carry the title-level name, the one `isHomePlace` compares.
    func homePlaceNames(for trip: Trip) throws -> Set<String> {
        try Self.homePlaceNames(for: trip, in: modelContext)
    }

    /// The same set on the caller's context, for title passes outside the classifier.
    nonisolated static func homePlaceNames(for trip: Trip, in context: ModelContext) throws -> Set<String> {
        try TripTitleStore.homePlaceNames(
            tripStart: trip.startDate,
            tripEnd: trip.endDate ?? .now,
            destinations: {
                trip.destinations.map {
                    (Self.titlePlaceName($0) ?? Trip.unknownDestinationSentinel, $0.durationMinutes)
                }
            },
            in: context)
    }

    /// `TripTitlePolicy.titlePlaceName` over a stay's own fields.
    nonisolated private static func titlePlaceName(_ stay: Stay) -> String? {
        TripTitlePolicy.titlePlaceName(metro: stay.metroName, island: stay.islandName,
            locality: stay.locality, country: stay.country, iso: stay.isoCountryCode)
    }

    /// Whether a stay's title-level name is one of the trip era's home places.
    /// Exact normalized-name match, never token overlap: a home in "New
    /// York" must not swallow a trip to York.
    nonisolated static func isHomePlace(_ stay: Stay, homePlaceNames: Set<String>) -> Bool {
        guard !homePlaceNames.isEmpty,
              let name = titlePlaceName(stay) else { return false }
        return homePlaceNames.contains(TripTitleStore.normalizedPlaceName(name))
    }

    func markPersistentTitleFailure(_ key: String) {
        var failures = persistentTitleFailures
        let inserted = failures.insert(key).inserted
        guard inserted else { return }
        _persistentTitleFailures = failures
        Self.failureDefaults.set(Array(failures), forKey: Self.failedTitleInputKeysKey)
    }

    func clearPersistentTitleFailure(_ id: UUID) {
        var failures = persistentTitleFailures
        let prefix = "\(id.uuidString)|"
        let oldCount = failures.count
        failures = failures.filter { !$0.hasPrefix(prefix) }
        guard failures.count != oldCount else { return }
        _persistentTitleFailures = failures
        Self.failureDefaults.set(Array(failures), forKey: Self.failedTitleInputKeysKey)
    }

    func clearSessionTitleFailures(_ id: UUID) {
        let prefix = "\(id.uuidString)|"
        sessionTitleAttemptCount = sessionTitleAttemptCount.filter {
            !$0.key.hasPrefix(prefix)
        }
    }

    /// Settings and StatusDashboard call this after geocoding so fresh place names can retry
    /// within the same bounded title-attempt budget.
    func clearAllPersistentTitleFailures() {
        _persistentTitleFailures = []
        sessionTitleAttemptCount.removeAll()
        Self.failureDefaults.removeObject(forKey: Self.failedTitleInputKeysKey)
        Self.failureDefaults.removeObject(forKey: Self.legacyFailedTitleTripIDsKey)
    }

    typealias TitleValidationFailure = TripTitlePolicy.ValidationFailure

    /// Full Stage-5 post-decode validation of a title already cleaned by
    /// `TripTitlePolicy.normalizeAITitle`. Returns the FIRST failure, or nil
    /// when the title passes. Unifies the belt-and-suspenders length /
    /// word-count / error-leak checks and the anti-hallucination grounding
    /// check into one seam so `generateOneTitle` can cite the ACTUAL
    /// violation in its same-session retry. Internal `nonisolated` seam for tests.
    nonisolated func titleValidationFailure(
        _ stripped: String,
        for trip: Trip,
        homePlaceNames: Set<String> = []
    ) -> TitleValidationFailure? {
        if stripped.isEmpty { return .empty }
        if stripped.count < 2 { return .tooShort }
        if stripped.count > 60 { return .tooLong }
        let lowered = stripped.lowercased()
        if lowered.contains("error") { return .containsErrorWord("error") }
        if lowered.contains("unknown") { return .containsErrorWord("unknown") }
        if stripped.contains("\n") { return .multiLine }
        let wordCount = stripped.split(separator: " ").count
        if wordCount > 8 { return .tooManyWords(wordCount) }
        if let ungrounded = ungroundedTitleFailure(
            stripped, for: trip, homePlaceNames: homePlaceNames) { return ungrounded }
        return missingTopPlaceFailure(
            stripped, for: trip, homePlaceNames: homePlaceNames)
    }

    /// A multi-place title must name a time-dominant place; any tie in minutes qualifies regardless of prompt tiebreaks.
    /// Match whole names contiguously or permitted abbreviations after grounding; skip single-group and transit-fallback trips.
    nonisolated func missingTopPlaceFailure(
        _ stripped: String,
        for trip: Trip,
        homePlaceNames: Set<String> = []
    ) -> TitleValidationFailure? {
        let ranked = rankedTitleCandidates(for: trip, homePlaceNames: homePlaceNames)
        guard !ranked.isTransitFallback, ranked.groups.count > 1,
              let top = ranked.groups.first else { return nil }
        let titleWords = TripTitlePolicy.placeWords(stripped)
        let topGroups = ranked.groups.filter { $0.totalMinutes == top.totalMinutes }
        for group in topGroups where Self.titleNamesPlace(titleWords, group.displayName) {
            return nil
        }
        return .missingTopPlace(top.displayName)
    }

    /// True when the title words contain the place's words as one
    /// contiguous run, or one of its permitted abbreviations
    /// (`TripTitleSchema.abbreviations`, plus NY for New York exactly as the
    /// grounding check allows). Abbreviations are checked first: a title
    /// that is only "NYC" or "LA" is shorter than the full name.
    nonisolated private static func titleNamesPlace(_ titleWords: [String], _ displayName: String) -> Bool {
        let words = TripTitlePolicy.placeWords(displayName)
        guard !words.isEmpty else { return true }
        for abbreviation in TripTitleSchema.abbreviations(for: displayName)
        where titleWords.contains(abbreviation.lowercased()) {
            return true
        }
        if words == ["new", "york"] && titleWords.contains("ny") { return true }
        guard titleWords.count >= words.count else { return false }
        for start in 0...(titleWords.count - words.count)
        where Array(titleWords[start ..< start + words.count]) == words {
            return true
        }
        return false
    }

    /// A stored title with a visited place in the retired prompt spelling,
    /// rewritten in stored spelling (`TripTitlePolicy.canonicalTitleSpelling`),
    /// or nil when it has none. That transform deleted letters with no ASCII
    /// decomposition ("Troms" for Tromsø, "Wrocaw" for Wrocław, "SaintJean"
    /// for Saint‑Jean), and such titles still arrive from backups and older
    /// devices. Grounding cannot catch them all: a region can own the
    /// shortened word (Tromsø lies in Troms). Only the trip's own place names
    /// are matched, as whole words, so a trip whose stays have not arrived
    /// has nothing to rewrite yet; a spelling that is also a run of words in
    /// one of those names is left alone. Spelling only: callers still apply
    /// the title policy to the result.
    nonisolated static func legacyTitleSpellingRepair(_ title: String, for trip: Trip) -> String? {
        // The retired transform only ever produced printable ASCII.
        guard !title.isEmpty, title.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        var names: [String] = []
        var seen = Set<String>()
        for stay in trip.orderedStays {
            for case let name? in [stay.metroName, stay.islandName, stay.locality]
            where seen.insert(name).inserted {
                names.append(name)
            }
        }
        var respellings: [(legacy: String, legacyWords: [String], stored: String)] = []
        for name in names where name.unicodeScalars.contains(where: { !$0.isASCII }) {
            let legacy = legacyPromptSpelling(name)
            guard !legacy.isEmpty, title.range(of: legacy, options: .caseInsensitive) != nil else { continue }
            let legacyWords = TripTitlePolicy.placeWords(legacy)
            guard !legacyWords.isEmpty, legacyWords != TripTitlePolicy.placeWords(name) else { continue }
            respellings.append((legacy, legacyWords, TripTitlePolicy.canonicalTitleSpelling(name)))
        }
        guard !respellings.isEmpty else { return nil }
        let currentNames = names.map { TripTitlePolicy.placeWords($0) }
        var repaired = title
        for respelling in respellings.sorted(by: { $0.legacy.count > $1.legacy.count }) {
            let isCurrentWordRun = currentNames.contains { containsRun(respelling.legacyWords, in: $0) }
            guard !isCurrentWordRun else { continue }
            repaired = replacingWholeWords(respelling.legacy, with: respelling.stored, in: repaired)
        }
        return repaired == title ? nil : repaired
    }

    nonisolated private static func containsRun(_ run: [String], in words: [String]) -> Bool {
        guard !run.isEmpty, words.count >= run.count else { return false }
        for start in 0...(words.count - run.count)
        where Array(words[start ..< start + run.count]) == run {
            return true
        }
        return false
    }

    /// The retired `toLatinAsciiStrict`, kept only to recognize titles
    /// written in it: `toLatinAscii` with whitespace runs as one space and
    /// every other scalar outside printable ASCII deleted.
    nonisolated private static func legacyPromptSpelling(_ name: String) -> String {
        var result = String.UnicodeScalarView()
        var previousWasWhitespace = false
        for scalar in name.toLatinAscii.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !previousWasWhitespace {
                    result.append(" ")
                    previousWasWhitespace = true
                }
                continue
            }
            guard scalar.value >= 0x21, scalar.value <= 0x7E else { continue }
            result.append(scalar)
            previousWasWhitespace = false
        }
        return String(result).trimmingCharacters(in: .whitespaces)
    }

    /// Every case-insensitive occurrence of `target` with no letter on
    /// either side, replaced.
    nonisolated private static func replacingWholeWords(
        _ target: String, with replacement: String, in text: String
    ) -> String {
        var result = ""
        var cursor = text.startIndex
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: target, options: .caseInsensitive,
                                     range: searchStart..<text.endIndex) {
            let letterBefore = range.lowerBound > text.startIndex
                && text[text.index(before: range.lowerBound)].isLetter
            let letterAfter = range.upperBound < text.endIndex && text[range.upperBound].isLetter
            if letterBefore || letterAfter {
                searchStart = text.index(after: range.lowerBound)
                continue
            }
            result += text[cursor..<range.lowerBound]
            result += replacement
            cursor = range.upperBound
            searchStart = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// `TripTitlePolicy.forbiddenCountryWords` over the trip's ordered stays.
    /// Keep this pure and nonisolated so tests need not send a non-Sendable Trip across actors.
    nonisolated func forbiddenCountryWords(for trip: Trip) -> Set<String> {
        TripTitlePolicy.forbiddenCountryWords(countryInputs: trip.orderedStays.map { ($0.country, $0.isoCountryCode) })
    }

    #if DEBUG
    /// Ground titles only in stay names and bounded connectors; calendar text grants no vocabulary exemption.
    nonisolated func titleWordsAreGrounded(
        _ title: String,
        for trip: Trip,
        homePlaceNames: Set<String> = []
    ) -> Bool {
        ungroundedTitleFailure(title, for: trip, homePlaceNames: homePlaceNames) == nil
    }
    #endif

    /// The grounding half of Stage-5 validation, surfacing WHICH word failed
    /// and WHY (`.forbiddenCountryWord` vs `.ungroundedWord`) so the retry can
    /// name it. nil ⇒ every title word is grounded. `titleWordsAreGrounded` is
    /// the Bool wrapper (unchanged contract for existing callers/tests).
    nonisolated func ungroundedTitleFailure(
        _ title: String,
        for trip: Trip,
        homePlaceNames: Set<String> = []
    ) -> TitleValidationFailure? {
        // Only destination stays ground normal titles; transit and other categories cannot supply omitted places.
        // With no destinations, fall back to every stay as buildTitlePrompt does.
        let destinationStays = trip.orderedStays.filter { $0.category == .destination }
        // Exclude home-named destinations from grounding whenever an away destination remains, matching prompt eligibility;
        // trips containing only home-named destinations still ground on them.
        let awayStays = destinationStays.filter { !Self.isHomePlace($0, homePlaceNames: homePlaceNames) }
        let groundingStays: [Stay]
        if !awayStays.isEmpty {
            groundingStays = awayStays
        } else {
            groundingStays = destinationStays.isEmpty ? trip.orderedStays : destinationStays
        }
        // The words those dropped stays would have grounded, so a title
        // that uses one gets its own rejection reason. Words the surviving
        // stays also carry stay grounded (a "York" trip from a New York
        // home) — subtracted below once `allowed` is complete.
        var homeWords = Set<String>()
        if !awayStays.isEmpty {
            for stay in destinationStays where Self.isHomePlace(stay, homePlaceNames: homePlaceNames) {
                for source in [stay.metroName, stay.islandName, stay.locality] {
                    guard let name = source else { continue }
                    for word in name.toLatinAsciiStrict.split(whereSeparator: { !$0.isLetter }) {
                        homeWords.insert(word.lowercased())
                    }
                }
            }
        }
        var allowed = Set<String>()
        for stay in groundingStays {
            for source in [stay.metroName, stay.islandName, stay.locality, stay.administrativeArea] {
                guard let name = source else { continue }
                for word in name.toLatinAsciiStrict.split(whereSeparator: { !$0.isLetter }) {
                    allowed.insert(word.lowercased())
                }
            }
            // Country code too — covers titles like "US Tour" if anyone
            // ever uses ISO codes. Unlikely but cheap.
            if let iso = stay.isoCountryCode, !iso.isEmpty {
                allowed.insert(iso.lowercased())
            }
        }
        // Country tokens must be subtracted and hard-rejected even if locality supplied them;
        // use the same forbiddenCountryWords helper in prompt and fallback construction.
        let forbiddenCountryWords = self.forbiddenCountryWords(for: trip)
        allowed.subtract(forbiddenCountryWords)
        // Allow abbreviations only when the corresponding city words are grounded.
        if allowed.contains("new") && allowed.contains("york") {
            allowed.formUnion(["nyc", "ny"])
        }
        if allowed.contains("los") && allowed.contains("angeles") {
            allowed.insert("la")
        }
        homeWords.subtract(allowed)
        // A grounding place whose own name contains country words ("Mexico
        // City", "San Salvador") is consumed whole before the forbidden check;
        // a bare country name or a leftover country word still rejects.
        let groundedNames: [[String]] = groundingStays.compactMap { stay in
            guard let name = Self.titlePlaceName(stay), name != "Unknown",
                  !TripTitlePolicy.isBareCountryName(name, forbidden: forbiddenCountryWords) else { return nil }
            let words = TripTitlePolicy.placeWords(name)
            return words.contains(where: forbiddenCountryWords.contains) ? words : nil
        }.sorted { $0.count > $1.count }

        // Tokenize the title exactly like the vocabulary above, so a title in
        // stored spelling ("Tromsø") meets its place's words ("tromso").
        let titleWords = title.toLatinAsciiStrict
            .split(whereSeparator: { !$0.isLetter && $0 != "&" })
            .map { String($0).lowercased() }
            .filter { !$0.isEmpty && $0 != "&" }

        var consumedGroundedName = false
        var index = 0
        while index < titleWords.count {
            if let name = groundedNames.first(where: {
                index + $0.count <= titleWords.count
                    && Array(titleWords[index..<index + $0.count]) == $0
            }) {
                consumedGroundedName = true
                index += name.count
                continue
            }
            let word = titleWords[index]
            index += 1
            // Hard reject country-name words even if a connector or
            // allowed-by-stay match would have let them through. This runs
            // BEFORE the connector check, so a demonym that merely resembles
            // a per-trip forbidden country token can never smuggle the bare
            // country in — e.g. "Greek" (connector) passes while "Greece"
            // (forbidden) rejects.
            if forbiddenCountryWords.contains(word) { return .forbiddenCountryWord(word) }
            if allowed.contains(word) { continue }
            if TripTitlePolicy.titleConnectorWords.contains(word) { continue }
            if homeWords.contains(word) { return .homePlaceWord(word) }
            return .ungroundedWord(word)
        }
        // Require at least one grounded stay word; connector and region words may decorate but cannot anchor a title.
        let grounded = consumedGroundedName || titleWords.contains { allowed.contains($0) }
        return grounded ? nil : .noGroundedWord(title)
    }

    /// Aggregated destination context shared by title grouping and ranking.
    private struct PromptGroup {
        var displayName: String
        var country: String
        var totalMinutes: Int
        var firstDate: Date
        var lastDate: Date
        var category: StayCategory
        var isAirport: Bool
        var stayCount: Int
    }

    /// Collapse a stay list into adjacent-displayName groups. Stays that
    /// share a title-level name AND a category AND
    /// an airport flag merge into one group; switching any starts a new
    /// group. Order-preserving so a "Madrid → Barcelona → Madrid" round
    /// trip surfaces both cities.
    nonisolated private func buildGroups(from stays: [Stay]) -> [PromptGroup] {
        var groups: [PromptGroup] = []
        for stay in stays {
            let displayName = Self.titlePlaceName(stay) ?? "Unknown"
            let country = stay.country ?? "?"
            if var last = groups.last,
               last.displayName == displayName,
               last.category == stay.category,
               last.isAirport == stay.isAirport {
                last.totalMinutes += stay.durationMinutes
                last.lastDate = max(last.lastDate, stay.endTime)
                last.stayCount += 1
                groups[groups.count - 1] = last
            } else {
                groups.append(PromptGroup(
                    displayName: displayName,
                    country: country,
                    totalMinutes: stay.durationMinutes,
                    firstDate: stay.startTime,
                    lastDate: stay.endTime,
                    category: stay.category,
                    isAirport: stay.isAirport,
                    stayCount: 1
                ))
            }
        }
        return groups
    }

    /// Share ranked candidates between model prompts and deterministic fallback so they agree on visited places.
    /// Exclude home-named stays while an away destination remains; offer all groups when no non-airport destinations remain.
    /// isTransitFallback lets deterministic fallback decline those groups; rank merged names by time, stay count, then first visit.
    private struct RankedTitleCandidates {
        var groups: [PromptGroup]
        var isTransitFallback: Bool
    }

    nonisolated private func rankedTitleCandidates(
        for trip: Trip,
        homePlaceNames: Set<String>
    ) -> RankedTitleCandidates {
        let chronological = trip.orderedStays.sorted { $0.startTime < $1.startTime }
        let nonTransit = chronological.filter { $0.category != .transit }
        let away = nonTransit.filter { !Self.isHomePlace($0, homePlaceNames: homePlaceNames) }
        let preFiltered: [Stay]
        if away.contains(where: { $0.category == .destination }) {
            preFiltered = away
        } else {
            preFiltered = nonTransit.isEmpty ? chronological : nonTransit
        }
        let allGroups = buildGroups(from: preFiltered)
        var candidates = allGroups.filter { $0.category == .destination && !$0.isAirport }
        var isTransitFallback = false
        if candidates.isEmpty {
            candidates = allGroups
            isTransitFallback = true
        }
        // Exclude bare country candidates because validation rejects them and fallback must not persist them.
        let forbiddenCountry = forbiddenCountryWords(for: trip)
        var byName: [String: PromptGroup] = [:]
        var order: [String] = []
        for group in candidates {
            if group.displayName == "Unknown" { continue }
            if TripTitlePolicy.isBareCountryName(group.displayName, forbidden: forbiddenCountry) { continue }
            if var merged = byName[group.displayName] {
                merged.totalMinutes += group.totalMinutes
                merged.stayCount += group.stayCount
                merged.firstDate = min(merged.firstDate, group.firstDate)
                merged.lastDate = max(merged.lastDate, group.lastDate)
                byName[group.displayName] = merged
            } else {
                byName[group.displayName] = group
                order.append(group.displayName)
            }
        }
        let ranked = order.compactMap { byName[$0] }.sorted { lhs, rhs in
            if lhs.totalMinutes != rhs.totalMinutes { return lhs.totalMinutes > rhs.totalMinutes }
            if lhs.stayCount != rhs.stayCount { return lhs.stayCount > rhs.stayCount }
            return lhs.firstDate < rhs.firstDate
        }
        return RankedTitleCandidates(groups: ranked, isTransitFallback: isTransitFallback)
    }

    /// Deterministic title from the same ranked list the prompt shows. Used
    /// by Stage 5 when AI generation exhausts the retry budget
    /// (`titleAttemptThreshold` consecutive failures — validator rejections,
    /// ANE errors, deserialize failures) so the trip exits the candidate
    /// pool with at least a sensible title, and by devices without Apple
    /// Intelligence through `Trip.recomputeSummary`'s twin ordering.
    ///
    /// The three places with the most time, shown in visit order, joined
    /// "A", "A & B", "A, B & C". Returns nil for an all-transit or
    /// airport-only trip and when no place resolved to a name, so
    /// `aiGeneratedTitle` stays nil and `Trip.displayName` falls through
    /// to `destinationSummary` instead of persisting "Unknown".
    nonisolated func computeFallbackTitle(
        for trip: Trip,
        homePlaceNames: Set<String> = []
    ) -> String? {
        let candidates = rankedTitleCandidates(for: trip, homePlaceNames: homePlaceNames)
        guard !candidates.isTransitFallback, !candidates.groups.isEmpty else { return nil }
        let names = candidates.groups.prefix(3)
            .sorted { $0.firstDate < $1.firstDate }
            .map { TripTitlePolicy.canonicalTitleSpelling($0.displayName) }
        let composed: String
        switch names.count {
        case 1:
            composed = names[0]
        case 2:
            composed = "\(names[0]) & \(names[1])"
        default:
            let head = names.dropLast().joined(separator: ", ")
            composed = "\(head) & \(names.last!)"
        }
        // The fallback is grounded by construction, but a place name can
        // still be too long or too wordy for the title policy; every caller
        // persists the result, so refuse here rather than at each site.
        if let failure = titleValidationFailure(
            composed, for: trip, homePlaceNames: homePlaceNames) {
            logger.info("Deterministic fallback title '\(composed)' for trip \(trip.id) rejected (\(String(describing: failure))); no fallback.")
            return nil
        }
        return composed
    }

    /// Prompt and decode grammar must share the same ranked names, spelling, and order;
    /// omit home, country, date, and calendar context that could leak into titles.
    struct TitlePromptMaterial: Sendable, Equatable {
        let prompt: String
        /// The listed names in prompt order and prompt spelling.
        let candidates: [String]
        /// The same places in stored spelling (`TripTitlePolicy.canonicalTitleSpelling`),
        /// parallel to `candidates`: what a chosen candidate is saved as.
        let titleSpellings: [String]
    }

    func titlePromptMaterial(for trip: Trip) -> TitlePromptMaterial {
        // Test and diagnostic surface: an unreadable set renders as no home.
        titlePromptMaterial(for: trip, homePlaceNames: (try? homePlaceNames(for: trip)) ?? [])
    }

    #if DEBUG
    func buildTitlePrompt(for trip: Trip) -> String {
        titlePromptMaterial(for: trip).prompt
    }
    #endif

    private func titlePromptMaterial(
        for trip: Trip,
        homePlaceNames: Set<String>
    ) -> TitlePromptMaterial {
        func latin(_ value: String) -> String { value.toLatinAsciiStrict }
        let ranked = rankedTitleCandidates(for: trip, homePlaceNames: homePlaceNames)
        var lines: [String] = ["Places visited, the place with the most time first:"]
        var candidates: [String] = []
        var titleSpellings: [String] = []
        for (index, group) in ranked.groups.prefix(maxGroupsInTitlePrompt).enumerated() {
            let name = latin(group.displayName)
            let stays = group.stayCount > 1 ? ", \(group.stayCount) stays" : ""
            lines.append("\(index + 1). \(name) (\(TripTitlePolicy.formattedMinutes(group.totalMinutes))\(stays))")
            candidates.append(name)
            titleSpellings.append(TripTitlePolicy.canonicalTitleSpelling(group.displayName))
        }
        lines.append("")
        lines.append("Title:")
        return TitlePromptMaterial(
            prompt: lines.joined(separator: "\n"), candidates: candidates, titleSpellings: titleSpellings)
    }
}
