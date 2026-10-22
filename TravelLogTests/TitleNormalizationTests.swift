//
//  TitleNormalizationTests.swift
//  TravelLogTests
//
//  TripTitlePolicy.normalizeAITitle(_:) — the cosmetic-stripping step that runs on
//  the Foundation-Models title output BEFORE the validation guard, so otherwise-good
//  titles aren't rejected for surrounding quotes / markdown. Strips whitespace,
//  ASCII + curly quotes, markdown emphasis (* _ `), and a single trailing period.
//  Pure string→string; tested synchronously with no store or actor.
//

import Testing
import Foundation
@testable import TravelLog

struct TitleNormalizationTests {

    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let cases: [(input: String, expected: String)]
        var idempotent = false
        var testDescription: String { name }
    }

    static let rows: [Row] = [
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
        Row(name: "a lone period empties; only one trailing period goes",
            cases: [(".", ""), ("Paris..", "Paris."), ("\"Σύρος.\"", "Σύρος")]),
        Row(name: "native script and unlisted wrapping marks are kept",
            cases: [("«Αθήνα»", "«Αθήνα»"), ("「京都」", "「京都」"), ("Tromsø & Bodø", "Tromsø & Bodø")]),
        Row(name: "idempotent on clean input",
            cases: [("Tokyo & Kyoto", "Tokyo & Kyoto")], idempotent: true),
    ]

    @Test("normalizes one AI title", arguments: rows)
    func normalizes(row: Row) {
        for (input, expected) in row.cases {
            let once = TripTitlePolicy.normalizeAITitle(input)
            #expect(once == expected, "input \(input.debugDescription)")
            if row.idempotent {
                #expect(TripTitlePolicy.normalizeAITitle(once) == once)
            }
        }
    }
}
