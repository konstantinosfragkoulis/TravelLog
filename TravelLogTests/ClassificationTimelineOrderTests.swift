//
//  ClassificationTimelineOrderTests.swift
//  TravelLogTests
//
//  Differential test: the keyed timeline sort against the comparator sort
//  it replaced, over shuffled fictional timelines where most rows share a
//  start and some share a UUID. Every order must match.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Classification timeline order")
struct ClassificationTimelineOrderTests {
    static let base = Date(timeIntervalSince1970: 1_704_067_200)

    /// SplitMix64, so a failure replays from its seed.
    struct Random: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private func insertStay(at start: Date, index: Int, in context: ModelContext) -> Stay {
        let stay = Stay(startTime: start, endTime: start.addingTimeInterval(1800),
            centroidLatitude: 0, centroidLongitude: Double(index) / 1000, h3IndexRes6: "sort",
            pingCount: 2, distanceFromHomeKm: 50, pingIDs: [])
        context.insert(stay)
        return stay
    }

    @Test("The keyed timeline sort gives exactly the classification order, ties and twins included")
    func keyedSortMatchesClassificationOrder() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        var random = Random(state: 4_242)
        let twins = (0..<8).map { _ in UUID() }
        for index in 0..<600 {
            // Few distinct starts, so most rows tie; some rows share a UUID too.
            let start = Self.base.addingTimeInterval(Double(Int.random(in: 0..<40, using: &random)) * 3600)
            let stay = insertStay(at: start, index: index, in: context)
            if index % 5 == 0 { stay.id = twins[index % twins.count] }
        }
        try context.save()
        for _ in 0..<5 {
            let stays = try context.fetch(FetchDescriptor<Stay>()).shuffled(using: &random)
            let expected = stays.sorted(by: TripClassifier.classificationOrder).map(\.persistentModelID)
            #expect(TripClassifier.sortedForClassification(stays).map(\.persistentModelID) == expected)
        }
        #expect(TripClassifier.sortedForClassification([]).isEmpty)
    }

    @Test("A timeline holding a NaN start keeps the comparator sort")
    func nanStartTakesTheComparatorSort() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        var random = Random(state: 77)
        var stays = (0..<40).map { index in
            insertStay(at: Self.base.addingTimeInterval(Double(index % 6) * 3600), index: index, in: context)
        }
        // Set after insertion: the initializer derives whole minutes from the span.
        let unordered = insertStay(at: Self.base, index: 40, in: context)
        unordered.startTime = Date(timeIntervalSinceReferenceDate: .nan)
        stays.append(unordered)
        stays.shuffle(using: &random)
        #expect(TripClassifier.sortedForClassification(stays).map(\.persistentModelID)
            == stays.sorted(by: TripClassifier.classificationOrder).map(\.persistentModelID))
    }
}
