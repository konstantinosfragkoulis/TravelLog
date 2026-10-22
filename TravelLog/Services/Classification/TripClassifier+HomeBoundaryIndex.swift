//
//  TripClassifier+HomeBoundaryIndex.swift
//  TravelLog
//

import Foundation

extension TripClassifier {

    /// The qualifying home boundaries of one assembly, read as two sorted
    /// lists of instants: every span's start and every span's end.
    /// `hasHomeStayBetween` asks whether any endpoint lies in a closed gap and
    /// `closeTrip` whether any start lies at or after an instant, so both are
    /// binary searches instead of span scans. Duplicate endpoints and exact
    /// `Date` values are kept. NaN has no place in a sorted order, and `Date`'s
    /// `<=` and `>=` hold for it, so a NaN endpoint or query takes the scan.
    nonisolated struct HomeBoundaryIndex: Sendable {
        let starts: [Date]
        let ends: [Date]
        private let spans: [HomeBoundarySpan]
        /// True when an endpoint is NaN: every query then scans `spans`.
        let scansOnly: Bool

        init(_ spans: [HomeBoundarySpan]) {
            self.spans = spans
            scansOnly = spans.contains { $0.start.isNaN || $0.end.isNaN }
            starts = scansOnly ? [] : spans.map(\.start).sorted()
            ends = scansOnly ? [] : spans.map(\.end).sorted()
        }

        var isEmpty: Bool { spans.isEmpty }

        /// The first index whose instant is not before `date`.
        static func lowerBound(_ dates: [Date], _ date: Date) -> Int {
            var low = 0, high = dates.count
            while low < high {
                let mid = (low + high) / 2
                if dates[mid] < date { low = mid + 1 } else { high = mid }
            }
            return low
        }

        /// The first index whose instant is after `date`.
        static func upperBound(_ dates: [Date], _ date: Date) -> Int {
            var low = 0, high = dates.count
            while low < high {
                let mid = (low + high) / 2
                if dates[mid] <= date { low = mid + 1 } else { high = mid }
            }
            return low
        }

        /// True when a start or an end lies in `lower...upper`.
        func hasEndpoint(from lower: Date, through upper: Date) -> Bool {
            guard lower <= upper else { return false }
            if scansOnly || lower.isNaN || upper.isNaN {
                let range = lower...upper
                return spans.contains { range.contains($0.start) || range.contains($0.end) }
            }
            for dates in [starts, ends] {
                let index = Self.lowerBound(dates, lower)
                if index < dates.count, dates[index] <= upper { return true }
            }
            return false
        }

        /// True when a start lies at or after `date`.
        func hasStart(atOrAfter date: Date) -> Bool {
            if scansOnly || date.isNaN { return spans.contains { $0.start >= date } }
            return starts.last.map { $0 >= date } ?? false
        }

        /// The earliest start or end at or after `date`. Neither `date` nor the
        /// index may hold NaN.
        func firstEndpoint(atOrAfter date: Date) -> Date? {
            let start = Self.lowerBound(starts, date)
            let end = Self.lowerBound(ends, date)
            let candidates = [start < starts.count ? starts[start] : nil,
                              end < ends.count ? ends[end] : nil].compactMap { $0 }
            return candidates.min()
        }

        /// The latest start or end at or before `date`. Neither `date` nor the
        /// index may hold NaN.
        func lastEndpoint(atOrBefore date: Date) -> Date? {
            let start = Self.upperBound(starts, date)
            let end = Self.upperBound(ends, date)
            let candidates = [start > 0 ? starts[start - 1] : nil,
                              end > 0 ? ends[end - 1] : nil].compactMap { $0 }
            return candidates.max()
        }
    }

    /// Completed-trip reconciliation's fixed pool of unassigned stays, indexed
    /// so each trip's three-branch test is a few binary searches instead of a
    /// scan of the pool. Nil when a pool date is NaN; callers scan instead.
    nonisolated struct ReconciliationPoolIndex: Sendable {
        /// Pool starts, ascending, and the latest end among each prefix.
        private let starts: [Date]
        private let prefixLatestEnd: [Date]
        /// Pool ends, ascending, and a sparse table of the earliest start
        /// over each power-of-two run of that order.
        private let ends: [Date]
        private let earliestStart: [[Date]]

        init?(_ pool: [(start: Date, end: Date)]) {
            guard !pool.contains(where: { $0.start.isNaN || $0.end.isNaN }) else { return nil }
            let byStart = pool.sorted { $0.start < $1.start }
            starts = byStart.map(\.start)
            var latest: [Date] = []
            latest.reserveCapacity(byStart.count)
            for stay in byStart { latest.append(latest.last.map { max($0, stay.end) } ?? stay.end) }
            prefixLatestEnd = latest
            let byEnd = pool.sorted { $0.end < $1.end }
            ends = byEnd.map(\.end)
            var table = [byEnd.map(\.start)]
            var width = 1
            while width * 2 <= byEnd.count {
                let previous = table[table.count - 1]
                table.append((0...(byEnd.count - width * 2)).map { min(previous[$0], previous[$0 + width]) })
                width *= 2
            }
            earliestStart = table
        }

        private func earliestStart(in range: Range<Int>) -> Date {
            var level = 0
            while (1 << (level + 1)) <= range.count { level += 1 }
            return min(earliestStart[level][range.lowerBound],
                       earliestStart[level][range.upperBound - (1 << level)])
        }

        /// Whether any pool stay `s` passes completed reconciliation's test for
        /// a trip, exactly as the scan evaluates it:
        /// (1) `s.start < tripEnd && s.end > tripStart`; otherwise
        /// (2) when `s.start >= lastEnd`, no boundary endpoint in `lastEnd...s.start`; otherwise
        /// (3) when `s.end <= firstStart`, no boundary endpoint in `s.end...firstStart`.
        /// When no stay passes (1), the others are free of it, so each branch
        /// is one range query. Nil when a trip or boundary date is NaN; callers scan instead.
        func affects(tripStart: Date, tripEnd: Date, firstStart: Date, lastEnd: Date,
                     boundaries: HomeBoundaryIndex) -> Bool? {
            guard !boundaries.scansOnly,
                  ![tripStart, tripEnd, firstStart, lastEnd].contains(where: \.isNaN) else { return nil }
            // (1) Some stay starting before the trip ends ends after it starts.
            let before = HomeBoundaryIndex.lowerBound(starts, tripEnd)
            if before > 0, prefixLatestEnd[before - 1] > tripStart { return true }
            // (2) The earliest stay starting at or after lastEnd starts before the next boundary.
            let after = HomeBoundaryIndex.lowerBound(starts, lastEnd)
            if after < starts.count {
                guard let next = boundaries.firstEndpoint(atOrAfter: lastEnd),
                      next <= starts[after] else { return true }
            }
            // (3) A stay starting before lastEnd ends after the last boundary
            // at or before firstStart, and no later than firstStart.
            let previous = boundaries.lastEndpoint(atOrBefore: firstStart)
            let low = previous.map { HomeBoundaryIndex.upperBound(ends, $0) } ?? 0
            let high = HomeBoundaryIndex.upperBound(ends, firstStart)
            if low < high, earliestStart(in: low..<high) < lastEnd { return true }
            return false
        }
    }
}

extension Date {
    /// A NaN interval: unordered, and `Date`'s derived `<=` and `>=` hold for it.
    nonisolated fileprivate var isNaN: Bool { timeIntervalSinceReferenceDate.isNaN }
}
