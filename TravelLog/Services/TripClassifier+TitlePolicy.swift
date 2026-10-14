//
//  TripClassifier+TitlePolicy.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import SwiftData
import CoreLocation
import FoundationModels
import WidgetKit
import os.log

extension TripClassifier {

    // MARK: - Title Retry Budget

    /// Bound title failures so rejected output cannot repeatedly consume the title-generation slots.
    static let titleAttemptThreshold = 2

    typealias CanonicalTitleShape = TripTitlePolicy.CanonicalTitleShape

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
        TripTitlePolicy.titleFailureKey(for: shape)
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
        let shape = canonicalTitleShape(
            for: trip,
            activeHomes: activeHomes,
            homePlaceNames: homeNames)
        // The shape already holds the trip's stays as values: rank those.
        let material = titlePromptMaterial(stays: shape.trip.stays, homePlaceNames: homeNames)
        return PreparedCanonicalTitleInput(
            shape: shape,
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
    /// carry the title-level name, the one `TripTitlePolicy.isHomePlace` compares.
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

    /// `TripTitlePolicy.titleValidationFailure` over the trip's stays as they
    /// are now. Internal `nonisolated` seam for tests.
    nonisolated func titleValidationFailure(
        _ stripped: String,
        for trip: Trip,
        homePlaceNames: Set<String> = []
    ) -> TitleValidationFailure? {
        TripTitlePolicy.titleValidationFailure(
            stripped, stays: TripTitleStore.semanticSnapshot(for: trip).stays, homePlaceNames: homePlaceNames)
    }

    /// `TripTitlePolicy.missingTopPlaceFailure` over the trip's stays as they are now.
    nonisolated func missingTopPlaceFailure(
        _ stripped: String,
        for trip: Trip,
        homePlaceNames: Set<String> = []
    ) -> TitleValidationFailure? {
        TripTitlePolicy.missingTopPlaceFailure(
            stripped, stays: TripTitleStore.semanticSnapshot(for: trip).stays, homePlaceNames: homePlaceNames)
    }

    /// `TripTitlePolicy.legacyTitleSpellingRepair` over the trip's own place
    /// names. Reads no stay when the title cannot hold the retired spelling,
    /// and only the three name fields when it can.
    nonisolated static func legacyTitleSpellingRepair(_ title: String, for trip: Trip) -> String? {
        guard TripTitlePolicy.mayHoldLegacySpelling(title) else { return nil }
        var names: [String] = []
        var seen = Set<String>()
        for stay in trip.orderedStays {
            for case let name? in [stay.metroName, stay.islandName, stay.locality]
            where seen.insert(name).inserted {
                names.append(name)
            }
        }
        return TripTitlePolicy.legacyTitleSpellingRepair(title, placeNames: names)
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

    /// `TripTitlePolicy.ungroundedTitleFailure` over the trip's stays as they
    /// are now. `titleWordsAreGrounded` is the Bool wrapper.
    nonisolated func ungroundedTitleFailure(
        _ title: String,
        for trip: Trip,
        homePlaceNames: Set<String> = []
    ) -> TitleValidationFailure? {
        TripTitlePolicy.ungroundedTitleFailure(
            title, stays: TripTitleStore.semanticSnapshot(for: trip).stays, homePlaceNames: homePlaceNames)
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
        let stays = TripTitleStore.semanticSnapshot(for: trip).stays
        let candidates = TripTitlePolicy.rankedTitleCandidates(stays: stays, homePlaceNames: homePlaceNames)
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
        if let failure = TripTitlePolicy.titleValidationFailure(
            composed, stays: stays, homePlaceNames: homePlaceNames) {
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
        titlePromptMaterial(
            stays: TripTitleStore.semanticSnapshot(for: trip).stays,
            homePlaceNames: (try? homePlaceNames(for: trip)) ?? [])
    }

    #if DEBUG
    func buildTitlePrompt(for trip: Trip) -> String {
        titlePromptMaterial(for: trip).prompt
    }
    #endif

    private func titlePromptMaterial(
        stays: [TripTitlePolicy.StayInput],
        homePlaceNames: Set<String>
    ) -> TitlePromptMaterial {
        func latin(_ value: String) -> String { value.toLatinAsciiStrict }
        let ranked = TripTitlePolicy.rankedTitleCandidates(stays: stays, homePlaceNames: homePlaceNames)
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
