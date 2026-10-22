//
//  HomeBoundaryIndexTests.swift
//  TravelLogTests
//
//  Differential tests: the sorted home-boundary index and the reconciliation
//  pool index against the linear scans they replaced, frozen below, over
//  thousands of random fictional span sets and queries. Instants sit on a
//  coarse grid so equal endpoints, touching gaps and zero-length spans are
//  common. Every answer must match.
//

import Foundation
import Testing
@testable import TravelLog

@Suite("Home boundary index")
struct HomeBoundaryIndexTests {

    typealias Span = TripClassifier.HomeBoundarySpan
    typealias Index = TripClassifier.HomeBoundaryIndex

    /// The scans as assembly ran them before the index: frozen reference.
    enum Frozen {
        static func hasHomeStayBetween(afterEnd: Date, beforeStart: Date, spans: [Span]) -> Bool {
            guard afterEnd <= beforeStart else { return false }
            let timeRange = afterEnd...beforeStart
            return spans.contains { timeRange.contains($0.start) || timeRange.contains($0.end) }
        }

        static func hasStart(atOrAfter date: Date, spans: [Span]) -> Bool {
            spans.contains { $0.start >= date }
        }

        static func affects(pool: [(start: Date, end: Date)], tripStart: Date, tripEnd: Date,
                            firstStart: Date, lastEnd: Date, spans: [Span]) -> Bool {
            pool.contains { s in
                if s.start < tripEnd && s.end > tripStart { return true }
                if s.start >= lastEnd {
                    return !hasHomeStayBetween(afterEnd: lastEnd, beforeStart: s.start, spans: spans)
                }
                if s.end <= firstStart {
                    return !hasHomeStayBetween(afterEnd: s.end, beforeStart: firstStart, spans: spans)
                }
                return false
            }
        }
    }

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
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }
        mutating func bool(_ percent: Int = 50) -> Bool { int(0...99) < percent }
    }

    static let origin = Date(timeIntervalSinceReferenceDate: 10_000_000)
    /// Five-minute grid steps, so live dwell straddles the 15-minute minimum.
    static func at(_ step: Int) -> Date { origin.addingTimeInterval(Double(step) * 300) }

    /// Random stays through the unchanged qualification rule: every category,
    /// source, ping count and Visit combination, short and long dwell,
    /// reversed and zero-length spans, and duplicated rows for UUID twins.
    static func spans(_ random: inout Random) -> [Span] {
        let count = random.bool(10) ? 0 : random.int(1...24)
        var spans: [Span] = []
        for _ in 0..<count {
            let start = random.int(0...60)
            let end = start + random.int(-2...8)
            let category = [StayCategory.home, .home, .home, .routine, .destination, .transit].randomElement(using: &random)!
            let source = DataSource.allCases.randomElement(using: &random)!
            guard TripClassifier.isQualifyingHomeBoundary(
                category: category, source: source, startTime: at(start), endTime: at(end),
                pingCount: random.int(0...3), hasVisit: random.bool(30)) else { continue }
            let span = Span(start: at(start), end: at(end))
            spans.append(span)
            if random.bool(15) { spans.append(span) }
        }
        return spans
    }

    @Test("hasHomeStayBetween and closure tests match the linear scan")
    func boundaryQueriesMatchScan() {
        var random = Random(state: 20_261_020)
        var queries = 0
        for _ in 0..<4_000 {
            let spans = Self.spans(&random)
            let index = Index(spans)
            for _ in 0..<40 {
                let lower = Self.at(random.int(-4...66))
                let upper = random.bool(15) ? lower : Self.at(random.int(-4...66))
                #expect(index.hasEndpoint(from: lower, through: upper)
                        == Frozen.hasHomeStayBetween(afterEnd: lower, beforeStart: upper, spans: spans))
                #expect(index.hasStart(atOrAfter: lower) == Frozen.hasStart(atOrAfter: lower, spans: spans))
                queries += 1
            }
        }
        #expect(queries == 160_000)
    }

    @Test("Completed reconciliation's pool index matches the scan")
    func reconciliationMatchesScan() throws {
        var random = Random(state: 7_031_977)
        for _ in 0..<6_000 {
            let spans = Self.spans(&random)
            let index = Index(spans)
            let pool: [(start: Date, end: Date)] = (0..<(random.bool(10) ? 0 : random.int(1...14))).map { _ in
                let start = random.int(0...60)
                return (Self.at(start), Self.at(start + random.int(-1...6)))
            }
            let poolIndex = try #require(TripClassifier.ReconciliationPoolIndex(pool))
            for _ in 0..<20 {
                // Mostly well-formed trips, sometimes arbitrary dates.
                let first = random.int(0...60)
                let last = first + random.int(0...10)
                let tripStart = random.bool(85) ? first : random.int(0...60)
                let lastEnd = last + random.int(0...4)
                let tripEnd = random.bool(85) ? lastEnd : random.int(0...66)
                let fast = poolIndex.affects(
                    tripStart: Self.at(tripStart), tripEnd: Self.at(tripEnd),
                    firstStart: Self.at(first), lastEnd: Self.at(lastEnd),
                    boundaries: index)
                let scan = Frozen.affects(
                    pool: pool, tripStart: Self.at(tripStart), tripEnd: Self.at(tripEnd),
                    firstStart: Self.at(first), lastEnd: Self.at(lastEnd), spans: spans)
                #expect(fast == scan, "pool \(pool) trip \(tripStart)-\(tripEnd) first \(first) last \(lastEnd)")
            }
        }
    }

    /// `Date`'s `<=` and `>=` are derived from `<`, so they hold for NaN: the
    /// scan matched a NaN endpoint in every gap. The index must too.
    @Test("NaN endpoints and queries answer as the scan does, or fall back")
    func nanMatchesScan() {
        let nan = Date(timeIntervalSinceReferenceDate: .nan)
        let spans = [Span(start: nan, end: Self.at(3)), Span(start: Self.at(5), end: nan),
                     Span(start: Self.at(8), end: Self.at(9))]
        let index = Index(spans)
        let points = [nan, Self.at(0), Self.at(3), Self.at(5), Self.at(8), Self.at(9), Self.at(12)]
        for lower in points {
            for upper in points {
                #expect(index.hasEndpoint(from: lower, through: upper)
                        == Frozen.hasHomeStayBetween(afterEnd: lower, beforeStart: upper, spans: spans))
            }
            #expect(index.hasStart(atOrAfter: lower) == Frozen.hasStart(atOrAfter: lower, spans: spans))
        }
        let clean = Index([Span(start: Self.at(8), end: Self.at(9))])
        for point in points {
            #expect(clean.hasEndpoint(from: nan, through: point)
                    == Frozen.hasHomeStayBetween(afterEnd: nan, beforeStart: point, spans: [Span(start: Self.at(8), end: Self.at(9))]))
            #expect(clean.hasStart(atOrAfter: nan) == Frozen.hasStart(atOrAfter: nan, spans: [Span(start: Self.at(8), end: Self.at(9))]))
        }
        #expect(TripClassifier.ReconciliationPoolIndex([(nan, Self.at(1))]) == nil)
        let pool = TripClassifier.ReconciliationPoolIndex([(Self.at(1), Self.at(2))])
        #expect(pool?.affects(tripStart: nan, tripEnd: Self.at(4), firstStart: Self.at(3),
                              lastEnd: Self.at(4), boundaries: index) == nil)
    }
}
