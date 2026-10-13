//
//  TimelineImportParserTests.swift
//  TravelLogTests
//
//  Pure parser tests for the Google Timeline import: both dialects,
//  coordinate-string
//  variants, tolerance counting, per-segment bounding, Records.json
//  refusal, and the chronological-output contract PingRecorder relies on.
//  No @Model construction — NOT @MainActor.
//

import Testing
import Foundation
@testable import TravelLog

struct TimelineImportParserTests {

    private func parse(_ json: String) throws -> TimelineParseResult {
        try TimelineImportParser.parse(Data(json.utf8))
    }

    // MARK: - Modern on-device export (semanticSegments)

    @Test("a visit segment yields dwell pings at the place coordinate")
    func visitSegmentYieldsDwellPings() throws {
        let result = try parse("""
        { "semanticSegments": [{
            "startTime": "2024-03-15T09:00:00.000-07:00",
            "endTime": "2024-03-15T11:00:00.000-07:00",
            "visit": { "topCandidate": { "placeLocation": { "latLng": "37.9838°, 23.7275°" } } }
        }] }
        """)
        #expect(result.format == "semanticSegments")
        #expect(result.visitCount == 1)
        #expect(result.skippedSegments == 0)
        // 2 h span at 1 h interior spacing → start + 2 interior + end.
        #expect(result.pings.count == 4)
        #expect(result.pings.allSatisfy { $0.latitude == 37.9838 && $0.longitude == 23.7275 })
        #expect(result.pings.allSatisfy { $0.horizontalAccuracy == TimelineImportParser.visitAccuracyMeters })
        // Offset parsing: -07:00 means 09:00 local = 16:00 UTC.
        let expectedStart = ISO8601DateFormatter().date(from: "2024-03-15T16:00:00Z")
        #expect(result.pings.first?.timestamp == expectedStart)
    }

    @Test("a week-long visit stays gap-bounded, an instantaneous visit emits one ping")
    func visitPingsAreBounded() throws {
        // The old contract capped a
        // week-long visit at start + 4 + end pings, which spread 168 h
        // evenly into ~34 h gaps and shattered ONE hotel stay into several
        // at the clusterer's 4 h split threshold. The contract now is
        // gap-boundedness: every consecutive pair ≤ visitInteriorMaxGapSeconds.
        let result = try parse("""
        { "semanticSegments": [
          { "startTime": "2024-03-01T00:00:00.000Z", "endTime": "2024-03-08T00:00:00.000Z",
            "visit": { "topCandidate": { "placeLocation": { "latLng": "1.0°, 2.0°" } } } },
          { "startTime": "2024-03-09T00:00:00.000Z", "endTime": "2024-03-09T00:00:00.000Z",
            "visit": { "topCandidate": { "placeLocation": { "latLng": "3.0°, 4.0°" } } } }
        ] }
        """)
        #expect(result.visitCount == 2)
        let week = result.pings.filter { $0.latitude == 1.0 }.map(\.timestamp).sorted()
        let span: TimeInterval = 7 * 24 * 3600
        let expectedInterior = Int((span / TimelineImportParser.visitInteriorMaxGapSeconds).rounded(.up)) - 1
        #expect(week.count == 2 + expectedInterior)
        for (a, b) in zip(week, week.dropFirst()) {
            #expect(b.timeIntervalSince(a) <= TimelineImportParser.visitInteriorMaxGapSeconds)
        }
        #expect(result.pings.filter { $0.latitude == 3.0 }.count == 1)
    }

    @Test("interior max gap stays strictly below the clusterer's split threshold")
    func interiorGapStaysBelowClustererThreshold() {
        // The parser carries its own copy of the bound (it is nonisolated;
        // the clusterer's constant is MainActor-isolated) — this pin is the
        // no-drift contract between them.
        #expect(TimelineImportParser.visitInteriorMaxGapSeconds < StayClusterer.timeGapThresholdSeconds)
    }

    @Test("a 30-hour visit no longer fragments at the clusterer threshold")
    func longVisitDoesNotFragment() throws {
        // Spreading 30 h evenly over 4 interior
        // pings produced 6 h gaps. The clusterer minted up to 6 stays for
        // one hotel visit.
        let result = try parse("""
        { "semanticSegments": [
          { "startTime": "2024-03-01T00:00:00.000Z", "endTime": "2024-03-02T06:00:00.000Z",
            "visit": { "topCandidate": { "placeLocation": { "latLng": "1.0°, 2.0°" } } } }
        ] }
        """)
        let times = result.pings.map(\.timestamp).sorted()
        for (a, b) in zip(times, times.dropFirst()) {
            #expect(b.timeIntervalSince(a) < StayClusterer.timeGapThresholdSeconds)
        }
    }

    @Test("short visits keep the dense hourly shape unchanged")
    func shortVisitShapeUnchanged() throws {
        // A 5 h visit: rawCount 5 ≥ cap 4 → 4 interior pings, exactly the
        // original output (the fragmentation floor only lifts long visits).
        let result = try parse("""
        { "semanticSegments": [
          { "startTime": "2024-03-01T00:00:00.000Z", "endTime": "2024-03-01T05:00:00.000Z",
            "visit": { "topCandidate": { "placeLocation": { "latLng": "1.0°, 2.0°" } } } }
        ] }
        """)
        #expect(result.pings.count == 2 + TimelineImportParser.visitInteriorCap)
    }

    @Test("timelinePath points ride minute offsets and are thinned to the cap")
    func timelinePathOffsetsAndThinning() throws {
        let points = (0..<40).map {
            #"{ "point": "10.0°, \#(20 + $0).0°", "durationMinutesOffsetFromStartTime": "\#($0)" }"#
        }.joined(separator: ",")
        let result = try parse("""
        { "semanticSegments": [{
            "startTime": "2024-03-15T09:00:00.000Z",
            "endTime": "2024-03-15T09:40:00.000Z",
            "timelinePath": [\(points)]
        }] }
        """)
        #expect(result.pings.count == TimelineImportParser.pathPointsPerSegmentCap)
        // First and last survive thinning; timestamps ride the offsets.
        #expect(result.pings.first?.longitude == 20.0)
        #expect(result.pings.last?.longitude == 59.0)
        let start = ISO8601DateFormatter().date(from: "2024-03-15T09:00:00Z")!
        #expect(result.pings.first?.timestamp == start)
        #expect(result.pings.last?.timestamp == start.addingTimeInterval(39 * 60))
    }

    @Test("an activity segment emits geo:-URI start/end fixes")
    func activitySegmentGeoURI() throws {
        let result = try parse("""
        { "semanticSegments": [{
            "startTime": "2023-11-24T09:00:00.000Z",
            "endTime": "2023-11-24T10:00:00.000Z",
            "activity": {
                "start": { "latLng": "geo:37.9838,23.7275" },
                "end": { "latLng": "geo:39.6628,20.8612" }
            }
        }] }
        """)
        #expect(result.activityCount == 1)
        #expect(result.pings.count == 2)
        #expect(result.pings.first?.latitude == 37.9838)
        #expect(result.pings.last?.latitude == 39.6628)
    }

    @Test("malformed segments are counted and skipped, never fatal")
    func malformedSegmentsAreTolerated() throws {
        let result = try parse("""
        { "semanticSegments": [
          { "startTime": "not-a-date", "endTime": "2024-03-15T10:00:00.000Z",
            "visit": { "topCandidate": { "placeLocation": { "latLng": "1.0°, 2.0°" } } } },
          { "startTime": "2024-03-15T09:00:00.000Z", "endTime": "2024-03-15T10:00:00.000Z",
            "visit": { "topCandidate": { "placeLocation": { "latLng": "garbage" } } } },
          { "startTime": "2024-03-15T09:00:00.000Z", "endTime": "2024-03-15T10:00:00.000Z",
            "visit": { "topCandidate": { "placeLocation": { "latLng": "95.0°, 2.0°" } } } },
          { "startTime": "2024-03-16T09:00:00.000Z", "endTime": "2024-03-16T10:00:00.000Z",
            "visit": { "topCandidate": { "placeLocation": { "latLng": "5.0°, 6.0°" } } } }
        ] }
        """)
        #expect(result.skippedSegments == 3)
        #expect(result.visitCount == 1)
    }

    // MARK: - Legacy Takeout (timelineObjects)

    @Test("a placeVisit round-trips E7 coordinates and Z timestamps")
    func placeVisitE7() throws {
        let result = try parse("""
        { "timelineObjects": [{
            "placeVisit": {
                "location": { "latitudeE7": 379838000, "longitudeE7": 237275000 },
                "duration": { "startTimestamp": "2023-11-14T22:13:20Z",
                              "endTimestamp": "2023-11-14T23:13:20Z" }
            }
        }] }
        """)
        #expect(result.format == "timelineObjects")
        #expect(result.visitCount == 1)
        #expect(result.pings.first?.latitude == 37.9838)
        #expect(result.pings.first?.longitude == 23.7275)
        // 1 h visit → start + 1 interior + end.
        #expect(result.pings.count == 3)
    }

    @Test("corrupt E7 values (overflow / exponent / fractional) skip the segment, never trap")
    func corruptE7ValuesAreSkippedNotFatal() throws {
        // Pre-fix, `int(_:)` fell through to the TRAPPING `Int64(Double)`:
        // any E7 field JSONSerialization backs with an out-of-range or
        // fractional Double (1e19 exponent literal, a 20-digit integer,
        // "379838000.5") hard-crashed the entire parse. The tolerance
        // contract demands these land in `skippedSegments` instead.
        let result = try parse("""
        { "timelineObjects": [
            { "placeVisit": {
                "location": { "latitudeE7": 1e19, "longitudeE7": 237275000 },
                "duration": { "startTimestamp": "2023-11-01T10:00:00Z",
                              "endTimestamp": "2023-11-01T12:00:00Z" } } },
            { "placeVisit": {
                "location": { "latitudeE7": 99999999999999999999, "longitudeE7": 237275000 },
                "duration": { "startTimestamp": "2023-11-02T10:00:00Z",
                              "endTimestamp": "2023-11-02T12:00:00Z" } } },
            { "placeVisit": {
                "location": { "latitudeE7": 379838000.5, "longitudeE7": 237275000 },
                "duration": { "startTimestamp": "2023-11-03T10:00:00Z",
                              "endTimestamp": "2023-11-03T12:00:00Z" } } },
            { "placeVisit": {
                "location": { "latitudeE7": 379838000, "longitudeE7": 237275000 },
                "duration": { "startTimestamp": "2023-11-04T10:00:00Z",
                              "endTimestamp": "2023-11-04T12:00:00Z" } } }
        ] }
        """)
        // The three corrupt segments skip; the clean sibling still parses.
        #expect(result.skippedSegments == 3)
        #expect(result.visitCount == 1)
        #expect(result.pings.allSatisfy { $0.latitude == 37.9838 })
    }

    @Test("corrupt legacy epoch-ms durations skip the segment, never trap; genuine ms still parse")
    func corruptEpochMillisecondsAreSkippedNotFatal() throws {
        // Pre-fix, DateParser's ms branch had no ceiling: `Double("1e30")`
        // is a FINITE Double that clears the >1e12 lower bound and yields a
        // far-future Date whose span arithmetic overflowed the trapping
        // `Int(_: Double)` in `visitPings` — one corrupt field aborted the
        // whole import (the corruptE7 crash class in a sibling path).
        let result = try parse("""
        { "timelineObjects": [
            { "placeVisit": {
                "location": { "latitudeE7": 379838000, "longitudeE7": 237275000 },
                "duration": { "startTimestampMs": "1541234567890",
                              "endTimestampMs": "1e30" } } },
            { "placeVisit": {
                "location": { "latitudeE7": 379838000, "longitudeE7": 237275000 },
                "duration": { "startTimestampMs": "99999999999999999999999",
                              "endTimestampMs": "99999999999999999999999" } } },
            { "placeVisit": {
                "location": { "latitudeE7": 379838000, "longitudeE7": 237275000 },
                "duration": { "startTimestampMs": "1541234567890",
                              "endTimestampMs": "1541238167890" } } }
        ] }
        """)
        // The 1e30 end and the 1e23-magnitude pair both skip; the genuine
        // ms-era visit (1 h → start + 1 interior + end) still parses.
        #expect(result.skippedSegments == 2)
        #expect(result.visitCount == 1)
        #expect(result.pings.count == 3)
        #expect(result.pings.first?.timestamp == Date(timeIntervalSince1970: 1_541_234_567_890 / 1000.0))
    }

    @Test("an activitySegment interpolates timeless waypoints across its duration")
    func activitySegmentWaypointInterpolation() throws {
        let result = try parse("""
        { "timelineObjects": [{
            "activitySegment": {
                "startLocation": { "latitudeE7": 100000000, "longitudeE7": 100000000 },
                "endLocation": { "latitudeE7": 200000000, "longitudeE7": 200000000 },
                "duration": { "startTimestamp": "2023-11-14T10:00:00Z",
                              "endTimestamp": "2023-11-14T12:00:00Z" },
                "waypointPath": { "waypoints": [
                    { "latE7": 120000000, "lngE7": 120000000 },
                    { "latE7": 150000000, "lngE7": 150000000 },
                    { "latE7": 180000000, "lngE7": 180000000 }
                ] }
            }
        }] }
        """)
        #expect(result.activityCount == 1)
        #expect(result.pings.count == 5)
        // Chronological: start, three evenly-spread waypoints, end.
        let start = ISO8601DateFormatter().date(from: "2023-11-14T10:00:00Z")!
        #expect(result.pings[0].timestamp == start)
        #expect(result.pings[1].timestamp == start.addingTimeInterval(2 * 3600 * 0.25))
        #expect(result.pings[2].timestamp == start.addingTimeInterval(2 * 3600 * 0.50))
        #expect(result.pings[4].timestamp == start.addingTimeInterval(2 * 3600))
        #expect(result.pings[2].latitude == 15.0)
    }

    // MARK: - Refusals & output contract

    @Test("raw Records preflight recognizes only a locations-first object")
    func rawRecordsPreflight() {
        #expect(TimelineImportParser.preflightIsRawRecords(
            prefix: Data(#"{"locations": ["#.utf8)))
        #expect(!TimelineImportParser.preflightIsRawRecords(
            prefix: Data(#"{"semanticSegments": ["#.utf8)))
        #expect(!TimelineImportParser.preflightIsRawRecords(
            prefix: Data(#"{"timelineObjects": ["#.utf8)))
        #expect(!TimelineImportParser.preflightIsRawRecords(
            prefix: Data(#"[{"locations": []}]"#.utf8)))

        var bomPrefix = Data([0xEF, 0xBB, 0xBF])
        bomPrefix.append(contentsOf: " \n\t{ \r\n \"locations\" : [".utf8)
        #expect(TimelineImportParser.preflightIsRawRecords(prefix: bomPrefix))

        #expect(!TimelineImportParser.preflightIsRawRecords(
            prefix: Data(#"{"locati"#.utf8)))
    }

    @Test("raw Records.json is refused with the dedicated error")
    func rawRecordsRefused() {
        #expect(throws: TimelineImportError.rawRecordsFile) {
            _ = try TimelineImportParser.parse(Data(#"{ "locations": [] }"#.utf8))
        }
    }

    @Test("unrecognized JSON and non-JSON throw their own errors")
    func unrecognizedInputs() {
        #expect(throws: TimelineImportError.unrecognizedFormat) {
            _ = try TimelineImportParser.parse(Data(#"{ "somethingElse": [] }"#.utf8))
        }
        #expect(throws: TimelineImportError.notJSON) {
            _ = try TimelineImportParser.parse(Data("not json".utf8))
        }
    }

    @Test("a file with only unusable segments throws .empty")
    func allSkippedThrowsEmpty() {
        #expect(throws: TimelineImportError.empty) {
            _ = try TimelineImportParser.parse(Data("""
            { "semanticSegments": [{ "startTime": "bad", "endTime": "bad" }] }
            """.utf8))
        }
    }

    @Test("output is chronologically sorted across out-of-order segments")
    func outputIsChronological() throws {
        let result = try parse("""
        { "semanticSegments": [
          { "startTime": "2024-06-01T00:00:00.000Z", "endTime": "2024-06-01T00:00:00.000Z",
            "visit": { "topCandidate": { "placeLocation": { "latLng": "2.0°, 2.0°" } } } },
          { "startTime": "2024-01-01T00:00:00.000Z", "endTime": "2024-01-01T00:00:00.000Z",
            "visit": { "topCandidate": { "placeLocation": { "latLng": "1.0°, 1.0°" } } } }
        ] }
        """)
        #expect(result.pings.map(\.timestamp) == result.pings.map(\.timestamp).sorted())
        #expect(result.pings.first?.latitude == 1.0)
    }

    @Test("coordinate string parsing covers degree, geo:, and negative forms")
    func coordinateStringVariants() {
        #expect(TimelineImportParser.parseCoordinate("37.9838°, 23.7275°")! == (37.9838, 23.7275))
        #expect(TimelineImportParser.parseCoordinate("geo:-33.8899,151.2689")! == (-33.8899, 151.2689))
        #expect(TimelineImportParser.parseCoordinate("-33.8688, -70.6693")! == (-33.8688, -70.6693))
        #expect(TimelineImportParser.parseCoordinate("91.0°, 0.0°") == nil)
        #expect(TimelineImportParser.parseCoordinate("banana") == nil)
    }

    // MARK: - Path point timestamps

    /// The defect: a missing offset defaulted to 0, so every point of the
    /// segment got the identical `start` instant at a DIFFERENT coordinate.
    /// `StayClusterer` then sees `timeSinceLast == 0` for each successor —
    /// neither the gap guard nor the negative-time guard fires — and each
    /// point beyond the distance threshold mints a zero-duration Stay.
    @Test("a path point with no time information at all is skipped, not stamped at the segment start")
    func offsetlessPathPointIsSkipped() throws {
        let result = try parse("""
        { "semanticSegments": [{
            "startTime": "2024-03-15T09:00:00.000Z",
            "endTime": "2024-03-15T09:40:00.000Z",
            "timelinePath": [
              { "point": "10.0°, 20.0°", "durationMinutesOffsetFromStartTime": "0" },
              { "point": "10.5°, 25.0°" },
              { "point": "11.0°, 30.0°", "durationMinutesOffsetFromStartTime": "30" }
            ]
        }] }
        """)
        #expect(result.pings.count == 2)
        #expect(result.pings.allSatisfy { $0.longitude != 25.0 })
    }

    /// Some exports stamp each path point with an absolute time instead.
    @Test("a path point carrying an absolute time is honoured")
    func absoluteTimePathPointIsHonoured() throws {
        let result = try parse("""
        { "semanticSegments": [{
            "startTime": "2024-03-15T09:00:00.000Z",
            "endTime": "2024-03-15T09:40:00.000Z",
            "timelinePath": [
              { "point": "10.0°, 20.0°", "time": "2024-03-15T09:05:00.000Z" },
              { "point": "11.0°, 30.0°", "time": "2024-03-15T09:35:00.000Z" }
            ]
        }] }
        """)
        #expect(result.pings.count == 2)
        let start = ISO8601DateFormatter().date(from: "2024-03-15T09:00:00Z")!
        #expect(result.pings.first?.timestamp == start.addingTimeInterval(5 * 60))
        #expect(result.pings.last?.timestamp == start.addingTimeInterval(35 * 60))
    }

    /// An absolute time far outside its own segment's window is inconsistent
    /// data. Clamping several such points would recreate the same
    /// one-instant collapse, so they are skipped.
    @Test("an absolute time outside the segment window is skipped, not clamped")
    func outOfWindowAbsoluteTimeIsSkipped() throws {
        let result = try parse("""
        { "semanticSegments": [{
            "startTime": "2024-03-15T09:00:00.000Z",
            "endTime": "2024-03-15T09:40:00.000Z",
            "timelinePath": [
              { "point": "10.0°, 20.0°", "time": "2024-03-15T09:05:00.000Z" },
              { "point": "11.0°, 30.0°", "time": "2024-03-16T22:00:00.000Z" }
            ]
        }] }
        """)
        #expect(result.pings.count == 1)
        #expect(result.pings.first?.longitude == 20.0)
    }

    /// A relative offset is bounded exactly like an absolute time. The old
    /// branch clamped only the upper side, so "-1e30" minted a ping at an
    /// absurd date and NaN slipped through `min` untouched.
    @Test("unbounded, non-finite or overshooting relative offsets are skipped; valid siblings survive")
    func invalidRelativeOffsetsAreSkipped() throws {
        let invalid = [
            #""-1e30""#, #""nan""#, #""-inf""#, #""inf""#, "-1e30",
            #""-5""#, #""42""#, #""1e308""#,
        ]
        let points = invalid.enumerated().map { index, offset in
            #"{ "point": "10.0°, \#(30 + index).0°", "durationMinutesOffsetFromStartTime": \#(offset) }"#
        }.joined(separator: ",")
        let result = try parse("""
        { "semanticSegments": [{
            "startTime": "2024-03-15T09:00:00.000Z",
            "endTime": "2024-03-15T09:40:00.000Z",
            "timelinePath": [
              { "point": "10.0°, 20.0°", "durationMinutesOffsetFromStartTime": "10" },
              \(points),
              { "point": "11.0°, 21.0°", "durationMinutesOffsetFromStartTime": 20 }
            ]
        }] }
        """)
        let start = ISO8601DateFormatter().date(from: "2024-03-15T09:00:00Z")!
        #expect(result.pings.map(\.longitude) == [20.0, 21.0])
        #expect(result.pings.map(\.timestamp) == [
            start.addingTimeInterval(10 * 60), start.addingTimeInterval(20 * 60),
        ])
        #expect(result.skippedSegments == 0)
    }

    @Test("relative offsets within the tolerance clamp into the segment window")
    func toleranceBoundaryOffsetsClamp() throws {
        let result = try parse("""
        { "semanticSegments": [{
            "startTime": "2024-03-15T09:00:00.000Z",
            "endTime": "2024-03-15T09:40:00.000Z",
            "timelinePath": [
              { "point": "10.0°, 20.0°", "durationMinutesOffsetFromStartTime": "-0.5" },
              { "point": "10.0°, 22.0°", "durationMinutesOffsetFromStartTime": "-1" },
              { "point": "10.0°, 24.0°", "durationMinutesOffsetFromStartTime": "41" }
            ]
        }] }
        """)
        let start = ISO8601DateFormatter().date(from: "2024-03-15T09:00:00Z")!
        let end = start.addingTimeInterval(40 * 60)
        #expect(result.pings.count == 3)
        #expect(result.pings.first { $0.longitude == 20.0 }?.timestamp == start)
        #expect(result.pings.first { $0.longitude == 22.0 }?.timestamp == start)
        #expect(result.pings.first { $0.longitude == 24.0 }?.timestamp == end)
    }

    @Test("an inconsistent offset falls back to the point's own consistent absolute time")
    func inconsistentOffsetFallsBackToAbsoluteTime() throws {
        let result = try parse("""
        { "semanticSegments": [{
            "startTime": "2024-03-15T09:00:00.000Z",
            "endTime": "2024-03-15T09:40:00.000Z",
            "timelinePath": [
              { "point": "10.0°, 20.0°", "durationMinutesOffsetFromStartTime": "-1e30",
                "time": "2024-03-15T09:05:00.000Z" },
              { "point": "11.0°, 30.0°", "durationMinutesOffsetFromStartTime": "nan",
                "time": "2024-03-17T09:05:00.000Z" }
            ]
        }] }
        """)
        let start = ISO8601DateFormatter().date(from: "2024-03-15T09:00:00Z")!
        #expect(result.pings.count == 1)
        #expect(result.pings.first?.longitude == 20.0)
        #expect(result.pings.first?.timestamp == start.addingTimeInterval(5 * 60))
    }

    @Test("a path segment whose every offset is invalid counts as skipped")
    func allInvalidPathSegmentIsSkipped() throws {
        let result = try parse("""
        { "semanticSegments": [
          { "startTime": "2024-03-15T09:00:00.000Z",
            "endTime": "2024-03-15T09:40:00.000Z",
            "timelinePath": [
              { "point": "10.0°, 20.0°", "durationMinutesOffsetFromStartTime": "-1e30" },
              { "point": "10.0°, 21.0°", "durationMinutesOffsetFromStartTime": "nan" }
            ] },
          { "startTime": "2024-03-16T09:00:00.000Z",
            "endTime": "2024-03-16T09:40:00.000Z",
            "timelinePath": [
              { "point": "12.0°, 22.0°", "durationMinutesOffsetFromStartTime": "5" }
            ] }
        ] }
        """)
        #expect(result.pings.count == 1)
        #expect(result.pings.first?.longitude == 22.0)
        #expect(result.skippedSegments == 1)

        #expect(throws: TimelineImportError.empty) {
            _ = try parse("""
            { "semanticSegments": [{
                "startTime": "2024-03-15T09:00:00.000Z",
                "endTime": "2024-03-15T09:40:00.000Z",
                "timelinePath": [
                  { "point": "10.0°, 20.0°", "durationMinutesOffsetFromStartTime": "-1e30" }
                ]
            }] }
            """)
        }
    }

    // MARK: - Date shape dispatch

    /// The helper as it was before shape dispatch, verbatim: fractional
    /// formatter, then plain, then epoch milliseconds.
    private struct OldOrderDateParser {
        let fractional: ISO8601DateFormatter
        let plain: ISO8601DateFormatter

        init() {
            fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            plain = ISO8601DateFormatter()
        }

        func date(_ raw: String) -> Date? {
            if let date = fractional.date(from: raw) { return date }
            if let date = plain.date(from: raw) { return date }
            if let ms = Double(raw), ms > 1_000_000_000_000, ms < 4_102_444_800_000 {
                return Date(timeIntervalSince1970: ms / 1000)
            }
            return nil
        }
    }

    @Test("timestamp strings parse to exactly the old formatter order's dates, and the same ones are rejected")
    func dateShapeDispatchMatchesOldOrder() throws {
        let oracle = OldOrderDateParser()
        let inputs: [String] = [
            // Plain, `Z` and offsets.
            "2024-03-15T09:00:00Z", "2024-03-15T09:00:00+02:00", "2024-03-15T09:00:00-07:00",
            "2024-03-15T09:00:00+00:00", "2024-03-15T09:00:00-00:00", "2024-03-15T09:00:00+0200",
            "2024-03-15T09:00:00+02", "2024-03-15T09:00:00+14:00", "2024-03-15T09:00:00+25:00",
            "2024-03-15T09:00:00", "2024-03-15T09:00Z", "2024-03-15 09:00:00Z",
            "2024-03-15t09:00:00z", "20240315T090000Z", "2024-03-15", "09:00:00Z",
            // Calendar and range boundaries.
            "2024-02-29T23:59:59Z", "2023-02-29T12:00:00Z", "2024-13-01T00:00:00Z",
            "2024-03-15T24:00:00Z", "2024-03-15T23:59:60Z", "1970-01-01T00:00:00Z",
            "1969-12-31T23:59:59Z", "0001-01-01T00:00:00Z", "2099-12-31T23:59:59Z",
            "9999-12-31T23:59:59Z",
            // Fractional seconds and fraction-like separators.
            "2024-03-15T09:00:00.000Z", "2024-03-15T09:00:00.5Z", "2024-03-15T09:00:00.123Z",
            "2024-03-15T09:00:00.123456789Z", "2024-03-15T09:00:00.999-07:00",
            "2024-03-15T09:00:00.500+02:00", "2024-03-15T09:00:00.Z", "2024-03-15T09:00:00.123",
            "2024-03-15T09:00:00,5Z", "2024-03-15T09:00.5Z", "2024.03.15T09:00:00Z",
            // Epoch milliseconds and their bounds.
            "1541234567890", "1000000000000", "1000000000001", "4102444799999", "4102444800000",
            "999999999999", "01541234567890", "99999999999999999999999", "0",
            "1541234567890.5", "1.54123456789e12", "1e30", "+1541234567890", "-1541234567890",
            " 1541234567890", "1541234567890 ", "0x166D3B3A8D2", "inf", "nan",
            "\u{FF11}\u{FF15}\u{FF14}\u{FF11}\u{FF12}\u{FF13}\u{FF14}\u{FF15}\u{FF16}\u{FF17}\u{FF18}\u{FF19}\u{FF10}",
            // Malformed.
            "", " ", "not a date", "T", "Z", "-", ".", ",",
            "2024-03-15T09:00:00ZZ", "2024-03-15T09:00:00Z ", " 2024-03-15T09:00:00Z",
        ]
        for raw in inputs {
            let file: [String: Any] = ["timelineObjects": [[
                "placeVisit": [
                    "location": ["latitudeE7": 379838000, "longitudeE7": 237275000],
                    "duration": ["startTimestamp": raw, "endTimestamp": raw],
                ],
            ]]]
            let data = try JSONSerialization.data(withJSONObject: file)
            if let expected = oracle.date(raw) {
                let result = try TimelineImportParser.parse(data)
                #expect(result.pings.map(\.timestamp) == [expected], "\(raw)")
            } else {
                #expect(throws: TimelineImportError.empty, "\(raw)") {
                    _ = try TimelineImportParser.parse(data)
                }
            }
        }

        // Anchors that keep the oracle honest: each shape is really accepted.
        let anchors: [(raw: String, epochSeconds: Double)] = [
            ("2024-03-15T09:00:00Z", 1_710_493_200),
            ("2024-03-15T09:00:00+02:00", 1_710_486_000),
            ("2024-03-15T09:00:00.500+02:00", 1_710_486_000.5),
            ("1541234567890", 1_541_234_567.89),
        ]
        for anchor in anchors {
            let date = try #require(oracle.date(anchor.raw), "\(anchor.raw)")
            #expect(abs(date.timeIntervalSince1970 - anchor.epochSeconds) < 0.001, "\(anchor.raw)")
        }
        #expect(oracle.date("4102444800000") == nil)
        #expect(oracle.date("not a date") == nil)
    }
}
