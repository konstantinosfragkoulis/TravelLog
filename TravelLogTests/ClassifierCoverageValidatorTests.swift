//
//  ClassifierCoverageValidatorTests.swift
//  TravelLogTests
//
//  Truth table for `TripClassifier.validateClassificationIndices`: the exact
//  cover gaps of one model response over 0..<count. Pure, no container.

import Testing
import Foundation
@testable import TravelLog

struct ClassifierCoverageValidatorTests {

    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let count: Int
        let indices: [Int]
        let missing: Set<Int>
        let duplicates: Set<Int>
        let outOfRange: Set<Int>
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(name: "exact cover passes clean",
            count: 3, indices: [0, 1, 2], missing: [], duplicates: [], outOfRange: []),
        Row(name: "order does not matter for coverage",
            count: 3, indices: [2, 0, 1], missing: [], duplicates: [], outOfRange: []),
        Row(name: "skipped index is reported missing",
            count: 3, indices: [0, 2], missing: [1], duplicates: [], outOfRange: []),
        Row(name: "second emission of an in-range index is a duplicate",
            count: 2, indices: [0, 1, 1], missing: [], duplicates: [1], outOfRange: []),
        Row(name: "negative and over-count indices are out of range",
            count: 2, indices: [0, 1, 2, -1], missing: [], duplicates: [], outOfRange: [2, -1]),
        Row(name: "out-of-range repeats stay out of range, not duplicates",
            count: 1, indices: [5, 5], missing: [0], duplicates: [], outOfRange: [5]),
        Row(name: "empty batch with no indices is clean",
            count: 0, indices: [], missing: [], duplicates: [], outOfRange: []),
    ]

    @Test("cover gaps of one response", arguments: rows)
    func coverGaps(row: Row) {
        let gaps = TripClassifier.validateClassificationIndices(
            count: row.count, indices: row.indices)
        #expect(gaps.missing == row.missing)
        #expect(gaps.duplicates == row.duplicates)
        #expect(gaps.outOfRange == row.outOfRange)
    }
}
