//
//  TitleNormalizationTests.swift
//  TravelLogTests
//
//  TripClassifier.normalizeAITitle(_:) — the cosmetic-stripping step that runs on
//  the Foundation-Models title output BEFORE the validation guard, so otherwise-good
//  titles aren't rejected for surrounding quotes / markdown. Strips whitespace,
//  ASCII + curly quotes, markdown emphasis (* _ `), and a single trailing period.
//  Pure string→string; tested synchronously (requires the production nonisolated+
//  internal change recorded in productionChangesNeeded).
//
//  `@MainActor` only because instantiating the @ModelActor TripClassifier here needs
//  a container; the method under test touches no actor state.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct TitleNormalizationTests {

    private func classifier() throws -> TripClassifier {
        TripClassifier(modelContainer: try TestSupport.makeInMemoryContainer())
    }

    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let cases: [(input: String, expected: String)]
        var idempotent = false
        var testDescription: String { name }
    }

    nonisolated static let rows: [Row] = [
        Row(name: "trims surrounding whitespace and newlines",
            cases: [("  Paris  ", "Paris"), ("\n Paris \n", "Paris")]),
        Row(name: "strips surrounding ASCII double quotes",
            cases: [("\"White Plains\"", "White Plains")]),
        Row(name: "strips surrounding ASCII single quotes",
            cases: [("'Tokyo'", "Tokyo")]),
        Row(name: "strips curly quotes (U+201C/U+201D and U+2018/U+2019)",
            cases: [("\u{201C}Kyoto\u{201D}", "Kyoto"), ("\u{2018}Kyoto\u{2019}", "Kyoto")]),
        Row(name: "strips markdown emphasis (* _) and backticks",
            cases: [("*Madrid*", "Madrid"), ("_Rome_", "Rome"), ("`Lisbon`", "Lisbon")]),
        Row(name: "unwinds nested wrapping, re-trimming whitespace between peels",
            cases: [("\"*White Plains*\"", "White Plains"), ("\"\"White Plains\"\"", "White Plains"),
                    ("\" \"White Plains\" \"", "White Plains")]),
        // The interior period of "St. Louis" (no trailing period) is untouched.
        Row(name: "strips exactly one trailing period; an interior period is preserved",
            cases: [("Paris.", "Paris"), ("St. Louis", "St. Louis")]),
        Row(name: "interior punctuation (commas, ampersand, spacing) is preserved",
            cases: [("Munich, Löbtau & Klagenfurt am Wörthersee", "Munich, Löbtau & Klagenfurt am Wörthersee")]),
        Row(name: "a string of only wrapping/whitespace collapses to empty",
            cases: [("\"\"", ""), ("   ", "")]),
        Row(name: "idempotent on clean input",
            cases: [("Tokyo & Kyoto", "Tokyo & Kyoto")], idempotent: true),
    ]

    @Test("normalizes one AI title", arguments: rows)
    func normalizes(row: Row) throws {
        let c = try classifier()
        for (input, expected) in row.cases {
            let once = c.normalizeAITitle(input)
            #expect(once == expected, "input \(input.debugDescription)")
            if row.idempotent {
                #expect(c.normalizeAITitle(once) == once)
            }
        }
    }
}
