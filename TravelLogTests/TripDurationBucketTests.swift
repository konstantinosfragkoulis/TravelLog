//
//  TripDurationBucketTests.swift
//  TravelLogTests
//
//  DurationBucket boundary arithmetic for the trip-length filter:
//  weekend 1–3, week 4–10, long 11+ (inclusive). Verifies the buckets
//  partition positive day-counts with no overlap/gap, reject 0 and
//  negative days, and round-trip their persisted raw values. DurationBucket
//  is a plain Sendable enum (no @Model), so this suite is NOT @MainActor.
//

import Testing
import Foundation
@testable import TravelLog

struct TripDurationBucketTests {

    // MARK: - Boundaries

    @Test("weekend bucket: inclusive 1…3, excludes 0 and 4")
    func weekendInclusiveLowerAndUpperBoundary() {
        #expect(DurationBucket.weekend.matches(days: 1) == true)
        #expect(DurationBucket.weekend.matches(days: 3) == true)
        #expect(DurationBucket.weekend.matches(days: 4) == false)
        #expect(DurationBucket.weekend.matches(days: 0) == false)
    }

    @Test("week bucket: inclusive 4…10, excludes 3 and 11")
    func weekRangeBoundaries() {
        #expect(DurationBucket.week.matches(days: 4) == true)
        #expect(DurationBucket.week.matches(days: 10) == true)
        #expect(DurationBucket.week.matches(days: 3) == false)
        #expect(DurationBucket.week.matches(days: 11) == false)
    }

    @Test("long bucket: 11+ open-ended, excludes 10")
    func longLowerBoundaryOpenEnded() {
        #expect(DurationBucket.long.matches(days: 11) == true)
        #expect(DurationBucket.long.matches(days: 10) == false)
        #expect(DurationBucket.long.matches(days: 365) == true)
    }

    // MARK: - Partition invariant

    @Test("exactly one bucket matches each day in 1…30 (no overlap, no gap)",
          arguments: Array(1...30))
    func bucketsPartitionPositiveDaysWithoutOverlap(days: Int) {
        let matching = DurationBucket.allCases.filter { $0.matches(days: days) }
        #expect(matching.count == 1)
    }

    @Test("zero and negative days match no bucket", arguments: [0, -1, -5])
    func zeroAndNegativeDaysMatchNoBucket(days: Int) {
        #expect(DurationBucket.allCases.filter { $0.matches(days: days) }.isEmpty)
    }

    // MARK: - Raw-value persistence

    @Test("rawValue round-trips for every case; raw strings are the stable JSON keys")
    func rawValueRoundTrip() {
        for b in DurationBucket.allCases {
            #expect(DurationBucket(rawValue: b.rawValue) == b)
        }
        #expect(DurationBucket.weekend.rawValue == "weekend")
        #expect(DurationBucket.week.rawValue == "week")
        #expect(DurationBucket.long.rawValue == "long")
    }
}
