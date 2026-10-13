//
//  TripSearchFuzzyTests.swift
//  TravelLogTests
//
//  Pure-function search primitives: query terms (normalize → split), the
//  engine's bounded OSA edit distance (adjacent transposition is one edit)
//  and `matches(query:in:)` on single rows. No isolation, no @Model, so
//  this suite is NOT @MainActor.
//

import Testing
import Foundation
import os
@testable import TravelLog

struct TripSearchFuzzyTests {

    // MARK: - terms

    private static func firstForms(_ query: String) -> [String] {
        TripSearch.terms(query, languageTag: "en").compactMap { $0.alternatives.first?.first }
    }

    @Test("terms lowercase and diacritic-fold (café → cafe)")
    func termsLowercaseAndDiacriticFold() {
        let forms = Self.firstForms("Café Köln")
        #expect(forms == ["cafe", "koln"])
        #expect(!forms.contains("café"))
    }

    @Test("terms split on whitespace and punctuation, no empty terms")
    func termsSplitOnWhitespaceAndPunctuation() {
        let terms = TripSearch.terms("Paris, France; 2024!", languageTag: "en")
        #expect(terms.map(\.raw) == ["Paris", "France", "2024"])
        #expect(terms.map(\.isNumeric) == [false, false, true])
    }

    @Test("terms of empty / whitespace-only / punctuation-only queries are empty")
    func termsEmptyAndWhitespaceOnlyYieldNothing() {
        #expect(TripSearch.terms("", languageTag: "en").isEmpty)
        #expect(TripSearch.terms("   \n\t  ", languageTag: "en").isEmpty)
        #expect(TripSearch.terms(",.;-", languageTag: "en").isEmpty)
    }

    @Test("terms collapse runs of separators (no empty middle term)")
    func termsCollapseRunsOfSeparators() {
        #expect(Self.firstForms("a    b") == ["a", "b"])
    }

    // MARK: - Bounded OSA distance

    private static func distance(_ a: String, _ b: String, limit: Int = 3) -> Int? {
        var scratch = EditDistance()
        return scratch.within(
            ArraySlice(a.unicodeScalars.map(\.value)),
            ArraySlice(b.unicodeScalars.map(\.value)),
            limit: limit)
    }

    @Test("edit distance per elementary edit", arguments: [
        ("tokyo", "tokyo", 0),    // identical
        ("", "abc", 3),           // against empty → the other length
        ("abc", "", 3),
        ("", "", 0),
        ("tokyo", "tokio", 1),    // single substitution
        ("london", "londone", 1), // single insertion
        ("london", "londn", 1),   // single deletion
        ("london", "londno", 1),  // adjacent transposition counts as ONE edit
        ("tokyo", "toyko", 1),
        ("flaw", "lawn", 2),      // a clear 2-edit pair
    ])
    func editDistance(a: String, b: String, expected: Int) {
        #expect(Self.distance(a, b) == expected)
    }

    @Test("edit distance is symmetric and nil beyond the limit", arguments: [
        ("athens", "athns"),
        ("paris", "pariss"),
        ("tokyo", "toyko"),
        ("london", "londone")
    ])
    func editDistanceSymmetric(a: String, b: String) {
        #expect(Self.distance(a, b) == Self.distance(b, a))
        #expect(Self.distance("amsterdam", "rotterdam", limit: 2) == nil)
    }

    // MARK: - The engine on single rows

    @Test("matches(query:in:): word-start prefix, 4+ char typo, city abbreviations", arguments: [
        ("ny", "new york nyc trip", true),            // word start at any length
        ("nyc", "new york", true),                    // curated city abbreviation
        ("toyko", "tokyo japan", true),               // fuzzy kicks in at 4+ chars
        ("abc", "abd", false),                        // …but not below it
        ("londno", "a trip to london in spring", true), // fuzzy is per word
        ("tokyo", "amsterdam berlin", false),         // far words never match
        ("toxxo", "tokyo", false),                    // edit distance 2 is rejected at 5 chars
        ("Τόκιο", "tokyo japan", true),               // not ASCII: the engine goes through the memo
    ])
    func engineRowRules(token: String, haystack: String, engine: Bool) {
        TripSearch.normalizedFormsCache.withLock { $0.removeAll() }
        let cold = TripSearch.matches(query: token, in: [haystack], languageTag: "en")
        let warm = TripSearch.matches(query: token, in: [haystack], languageTag: "en")
        #expect(cold == engine)
        #expect(warm == cold)
    }
}
