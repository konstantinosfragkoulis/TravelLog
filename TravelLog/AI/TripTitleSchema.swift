//
//  TripTitleSchema.swift
//  TravelLog
//
//  Guided-generation schema for the trip title generator (Stage 5 of the
//  trip pipeline). The model SELECTS from a closed list, the code FORMATS
//  (`TripTitlePolicy.composeTitle`).
//

import Foundation
import FoundationModels

/// The grammar the title model decodes under: an array of one to three
/// `places`, each an `anyOf` over the exact names the prompt lists (plus a
/// permitted abbreviation for a famous one), capped at the number of places
/// the trip has.
///
/// Why a dynamic schema and not a `@Generable` string array: asked to copy
/// names from a list into `places: [String]`, the on-device 3B model padded
/// one-place trips with plausible neighbours ("Livadeia & Athens") and
/// copied the instruction's own abbreviation example. Host-model results
/// do not reliably predict device behavior. Constrained decoding cannot
/// emit a token outside the grammar, so with the list AS the grammar an
/// invented place is impossible, not merely rejected.
///
/// Nothing here is persisted. The validator (`titleValidationFailure`)
/// still runs on the composed title as the second line of defence.
nonisolated enum TripTitleSchema {

    /// A title names at most this many places.
    static let maximumPlaces = 3

    enum Failure: Error, Equatable {
        /// The prompt offered no place, so there is nothing to choose from.
        case noCandidates
    }

    /// The abbreviations the model may return for a listed name. Kept in
    /// step with `TripTitlePolicy.composeTitle`, which folds them back onto
    /// the full name for de-duplication.
    static func abbreviations(for name: String) -> [String] {
        switch name.lowercased() {
        case "new york": return ["NYC"]
        case "los angeles": return ["LA"]
        default: return []
        }
    }

    /// Every string the model may emit: the listed names in list order,
    /// each followed by its abbreviations, de-duplicated.
    static func choices(for candidates: [String]) -> [String] {
        var seen = Set<String>()
        var choices: [String] = []
        for candidate in candidates {
            let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            for choice in [name] + abbreviations(for: name) where seen.insert(choice).inserted {
                choices.append(choice)
            }
        }
        return choices
    }

    /// The most places a title may name for a list of `candidateCount`
    /// places: a one-place trip gets one name, never a padded three.
    static func placeLimit(candidateCount: Int) -> Int {
        max(1, min(maximumPlaces, candidateCount))
    }

    /// The decode grammar for one prompt's candidate list.
    static func schema(candidates: [String]) throws -> GenerationSchema {
        let choices = choices(for: candidates)
        guard !choices.isEmpty else { throw Failure.noCandidates }
        let place = DynamicGenerationSchema(
            name: "Place",
            description: "A place name copied exactly from the list.",
            anyOf: choices)
        let places = DynamicGenerationSchema(
            arrayOf: place,
            minimumElements: 1,
            maximumElements: placeLimit(candidateCount: candidates.count))
        let root = DynamicGenerationSchema(
            name: "TripTitle",
            properties: [
                .init(
                    name: "places",
                    description: "The places the title names, from the top of the list, the place with the most time first.",
                    schema: places),
            ])
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// The chosen names out of a response decoded under `schema(candidates:)`.
    static func places(in content: GeneratedContent) throws -> [String] {
        try content.value([String].self, forProperty: "places")
    }

    /// One model turn under the grammar for `candidates`. Used for the first
    /// ask and for the same-session correction retry alike.
    static func respond(
        session: LanguageModelSession,
        prompt: String,
        candidates: [String],
        options: GenerationOptions
    ) async throws -> [String] {
        let schema = try schema(candidates: candidates)
        let response = try await session.respond(to: prompt, schema: schema, options: options)
        return try places(in: response.content)
    }
}
