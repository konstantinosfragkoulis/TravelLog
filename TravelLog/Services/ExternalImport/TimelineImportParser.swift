//
//  TimelineImportParser.swift
//  TravelLog
//
//  Pure parser for Google Timeline location-history exports.
//  Two dialects, auto-detected:
//
//    • the modern on-device export (Google Maps → your profile → Your
//      Timeline → export): top-level `semanticSegments[]` with `visit` /
//      `activity` / `timelinePath` entries and `"37.98°, 23.72°"`-style
//      (or `geo:`-URI) coordinate strings;
//    • the legacy Takeout "Semantic Location History" monthly files:
//      top-level `timelineObjects[]` with `placeVisit` / `activitySegment`
//      entries and E7 integer coordinates.
//
//  The raw Takeout `Records.json` (top-level `locations[]`, potentially
//  GB-scale) is DETECTED and refused with guidance — parsing it on-device
//  is a jetsam hazard and the semantic exports carry the same story.
//
//  Tolerance-first (the `TripDataImporter.parse` philosophy): a segment
//  missing its required core is counted in `skippedSegments` and dropped;
//  nothing short of not-JSON / unrecognized shape is fatal. Output pings
//  are BOUNDED per segment (visit interior cap, waypoint thinning) and
//  globally sorted chronologically — `PingRecorder.recordImportedPings`
//  processes candidates in array order for its hex-reentry semantics.
//

import Foundation

/// One synthesized location fix from a Timeline export. Deliberately its
/// own tiny value type (not `ImportedPingCandidate`) so the parser stays
/// decoupled and directly unit-testable.
nonisolated struct TimelinePing: Sendable, Equatable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
}

nonisolated struct TimelineParseResult: Sendable {
    var pings: [TimelinePing] = []
    var visitCount = 0
    var activityCount = 0
    var pathPointCount = 0
    var skippedSegments = 0
    /// Which dialect the file matched ("semanticSegments" / "timelineObjects").
    var format = ""
}

nonisolated enum TimelineImportError: Error, Equatable {
    case notJSON
    /// Raw Takeout `Records.json` — refused by design; the alert copy
    /// points the user at the semantic on-device export instead.
    case rawRecordsFile
    /// JSON, but neither dialect's top-level key is present.
    case unrecognizedFormat
    /// Parsed cleanly but produced zero usable fixes.
    case empty
    /// Larger than `TimelineImportParser.maxFileBytes`, or its fixes would
    /// pass `TimelineImportParser.maxRetainedPings`.
    case tooLarge
}

nonisolated enum TimelineImportParser {

    /// The largest export taken. The whole document is parsed at once, at
    /// several times its size in memory, so a larger one would not fit on
    /// a phone; the semantic exports this reads stay far below it.
    static let maxFileBytes: UInt64 = 256 << 20

    /// Visit dwell is evidenced by interior pings at this spacing (dense,
    /// hourly)…
    static let visitInteriorSpacingSeconds: TimeInterval = 60 * 60
    /// …with the DENSE tier capped at this many rows for short visits.
    static let visitInteriorCap = 4
    /// Fragmentation guard: consecutive synthesized pings must never be
    /// farther apart than the clusterer's stay-splitting gap, or one long
    /// visit shatters into several stays (a 30 h visit with 6 h gaps becomes
    /// up to 6 stays at the same coordinate). This constant MUST
    /// stay strictly below `StayClusterer.timeGapThresholdSeconds` (4 h);
    /// the margin is deliberate headroom. The equality contract is pinned
    /// by `TimelineImportParserTests.interiorGapStaysBelowClustererThreshold`
    /// — the clusterer's constant is MainActor-isolated, so this
    /// `nonisolated` parser carries its own copy.
    static let visitInteriorMaxGapSeconds: TimeInterval = 3 * 60 * 60
    /// Absolute ceiling on interior pings per visit (≈250 days at the max
    /// gap). Beyond this a "visit" is data noise; letting it fragment is
    /// preferable to synthesizing unbounded rows.
    static let visitInteriorAbsoluteCap = 2000
    /// The most fixes one file may yield, whatever its size: the byte ceiling
    /// bounds the document, not what its visits synthesize (one long visit
    /// is up to `visitInteriorAbsoluteCap` + 2 fixes from a few hundred
    /// bytes). Every append is admitted against it before it is built, and a
    /// file past it is refused as too large, never imported in part. Ten
    /// years of densely kept history stay far below it.
    static let maxRetainedPings = 1_000_000
    /// Path/waypoint points per segment are thinned evenly to this many.
    static let pathPointsPerSegmentCap = 10
    /// Honest-ish accuracies for synthesized fixes: visits are
    /// place-anchored (tight), path points are route-shaped (loose).
    static let visitAccuracyMeters: Double = 65
    static let pathAccuracyMeters: Double = 100
    /// Slack allowed around a `timelinePath` point's own segment window,
    /// whether it carries an ABSOLUTE time or a relative offset: it
    /// must fall inside the window, give or take rounding at the boundaries.
    static let pathAbsoluteTimeToleranceSeconds: TimeInterval = 60

    // MARK: - Entry

    /// Fast-path detector for raw Takeout `Records.json`. Only the first
    /// object key is inspected; all other shapes fall through to the full
    /// parser, which remains the authority for complete validation.
    nonisolated static func preflightIsRawRecords(prefix: Data) -> Bool {
        let bytes = Array(prefix)
        var index = 0

        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            index = 3
        }

        func skipWhitespace() {
            while index < bytes.count,
                  bytes[index] == 0x20 || bytes[index] == 0x09
                    || bytes[index] == 0x0A || bytes[index] == 0x0D {
                index += 1
            }
        }

        skipWhitespace()
        guard index < bytes.count, bytes[index] == 0x7B else { return false }
        index += 1
        skipWhitespace()
        guard index < bytes.count, bytes[index] == 0x22 else { return false }

        let keyStart = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                let keyData = Data(bytes[keyStart...index])
                guard let key = try? JSONDecoder().decode(String.self, from: keyData),
                      key == "locations" else {
                    return false
                }
                index += 1
                skipWhitespace()
                return index < bytes.count && bytes[index] == 0x3A
            } else if byte < 0x20 {
                return false
            }
            index += 1
        }
        return false
    }

    static func parse(_ data: Data, maxPings: Int = maxRetainedPings) throws -> TimelineParseResult {
        let parsed = try? JSONSerialization.jsonObject(with: data)
        // The legacy Takeout files are objects too; a top-level ARRAY is
        // the on-device Android export variant that wraps segments
        // directly — accept it as semanticSegments.
        if let rootArray = parsed as? [[String: Any]] {
            return try parseSemanticSegments(rootArray, dates: DateParser(), maxPings: maxPings)
        }
        guard let root = parsed as? [String: Any] else {
            throw TimelineImportError.notJSON
        }
        if root["locations"] != nil { throw TimelineImportError.rawRecordsFile }
        if let segments = root["semanticSegments"] as? [[String: Any]] {
            return try parseSemanticSegments(segments, dates: DateParser(), maxPings: maxPings)
        }
        if let objects = root["timelineObjects"] as? [[String: Any]] {
            return try parseTimelineObjects(objects, dates: DateParser(), maxPings: maxPings)
        }
        throw TimelineImportError.unrecognizedFormat
    }

    // MARK: - Modern on-device export (`semanticSegments`)

    /// A path point's `durationMinutesOffsetFromStartTime` (stringified or
    /// numeric minutes) as a timestamp inside the segment window, or nil when
    /// absent, non-finite, or outside `[start, end]` by more than the
    /// tolerance.
    private static func relativePathTimestamp(
        _ entry: [String: Any], start: Date, end: Date
    ) -> Date? {
        let raw = entry["durationMinutesOffsetFromStartTime"]
        guard let offsetMinutes = (raw as? String).flatMap(Double.init) ?? (raw as? Double),
              offsetMinutes.isFinite else { return nil }
        let offsetSeconds = offsetMinutes * 60
        guard offsetSeconds.isFinite else { return nil }
        return boundedPathTimestamp(
            start.addingTimeInterval(offsetSeconds), start: start, end: end)
    }

    /// `candidate` clamped into `[start, end]` when it lies within
    /// `pathAbsoluteTimeToleranceSeconds` of that window; nil otherwise.
    private static func boundedPathTimestamp(
        _ candidate: Date, start: Date, end: Date
    ) -> Date? {
        let seconds = candidate.timeIntervalSinceReferenceDate
        guard seconds.isFinite,
              candidate >= start.addingTimeInterval(-pathAbsoluteTimeToleranceSeconds),
              candidate <= end.addingTimeInterval(pathAbsoluteTimeToleranceSeconds) else {
            return nil
        }
        return min(max(candidate, start), end)
    }

    /// Refuses the file before `count` more fixes would pass `maxPings`.
    private static func admit(_ count: Int, after result: TimelineParseResult, maxPings: Int) throws {
        guard count <= maxPings - result.pings.count else { throw TimelineImportError.tooLarge }
    }

    private static func parseSemanticSegments(
        _ segments: [[String: Any]], dates: DateParser, maxPings: Int
    ) throws -> TimelineParseResult {
        var result = TimelineParseResult()
        result.format = "semanticSegments"

        for segment in segments {
            guard let start = dates.date(segment["startTime"]),
                  let end = dates.date(segment["endTime"]),
                  end >= start else {
                result.skippedSegments += 1
                continue
            }

            if let visit = segment["visit"] as? [String: Any] {
                let top = visit["topCandidate"] as? [String: Any]
                let place = top?["placeLocation"]
                // Both shapes exist in the wild: a nested {"latLng": "…"}
                // object and a bare coordinate string.
                let coordinate = coordinateString(from: place) ?? coordinateString(from: visit["placeLocation"])
                guard let coord = coordinate.flatMap(parseCoordinate) else {
                    result.skippedSegments += 1
                    continue
                }
                try admit(visitPingCount(start: start, end: end), after: result, maxPings: maxPings)
                result.pings.append(contentsOf: visitPings(at: coord, start: start, end: end))
                result.visitCount += 1
                continue
            }

            if let path = segment["timelinePath"] as? [[String: Any]] {
                var points: [TimelinePing] = []
                for entry in path {
                    guard let coord = coordinateString(from: entry["point"]).flatMap(parseCoordinate) else { continue }
                    // Offset is a stringified minute count from segment start.
                    // Some exports instead stamp each point with an absolute
                    // `time`; accept that shape too, and SKIP a point carrying
                    // neither rather than defaulting the offset to 0.
                    //
                    // A `?? 0` default fabricates a value the pipeline cannot
                    // detect as wrong: every surviving point of the segment
                    // gets the identical `start` instant at a different
                    // coordinate, so `StayClusterer` sees `timeSinceLast == 0`
                    // for each successor — neither the gap guard nor the
                    // negative-time guard fires — and each point >3 km from
                    // the last mints a zero-duration Stay, i.e. a burst of
                    // phantom stays at one instant. Skipping matches how every
                    // other field in this parser handles a missing value.
                    //
                    // Both shapes share one window: the segment's own span
                    // plus a small tolerance for rounding at the boundaries,
                    // clamped into the span so a path point never sits
                    // outside the segment that declares it. A point well
                    // outside (or a non-finite offset such as "nan" or
                    // "-1e30") is inconsistent data and is skipped rather
                    // than clamped, which would collapse several such points
                    // onto one instant. An inconsistent offset falls back to
                    // a consistent absolute time on the same point, if any.
                    let timestamp: Date
                    if let relative = relativePathTimestamp(entry, start: start, end: end) {
                        timestamp = relative
                    } else if let absolute = dates.date(entry["time"] ?? entry["timestamp"]),
                              let bounded = boundedPathTimestamp(absolute, start: start, end: end) {
                        timestamp = bounded
                    } else {
                        continue
                    }
                    points.append(TimelinePing(
                        timestamp: timestamp, latitude: coord.lat, longitude: coord.lon,
                        horizontalAccuracy: pathAccuracyMeters
                    ))
                }
                guard !points.isEmpty else {
                    result.skippedSegments += 1
                    continue
                }
                let thinned = thin(points, to: pathPointsPerSegmentCap)
                try admit(thinned.count, after: result, maxPings: maxPings)
                result.pings.append(contentsOf: thinned)
                result.pathPointCount += thinned.count
                continue
            }

            if let activity = segment["activity"] as? [String: Any] {
                try admit(2, after: result, maxPings: maxPings)
                var emitted = 0
                if let coord = coordinateString(from: (activity["start"] as? [String: Any])?["latLng"] ?? activity["start"]).flatMap(parseCoordinate) {
                    result.pings.append(TimelinePing(
                        timestamp: start, latitude: coord.lat, longitude: coord.lon,
                        horizontalAccuracy: pathAccuracyMeters
                    ))
                    emitted += 1
                }
                if let coord = coordinateString(from: (activity["end"] as? [String: Any])?["latLng"] ?? activity["end"]).flatMap(parseCoordinate) {
                    result.pings.append(TimelinePing(
                        timestamp: end, latitude: coord.lat, longitude: coord.lon,
                        horizontalAccuracy: pathAccuracyMeters
                    ))
                    emitted += 1
                }
                if emitted == 0 { result.skippedSegments += 1 } else { result.activityCount += 1 }
                continue
            }

            // A segment with usable times but no recognized payload
            // (e.g. `timelineMemory`) — not an error, just nothing for us.
            result.skippedSegments += 1
        }

        return try finalize(result)
    }

    // MARK: - Legacy Takeout (`timelineObjects`)

    private static func parseTimelineObjects(
        _ objects: [[String: Any]], dates: DateParser, maxPings: Int
    ) throws -> TimelineParseResult {
        var result = TimelineParseResult()
        result.format = "timelineObjects"

        for object in objects {
            if let visit = object["placeVisit"] as? [String: Any] {
                guard let location = visit["location"] as? [String: Any],
                      let coord = e7Coordinate(location),
                      let duration = visit["duration"] as? [String: Any],
                      let start = dates.date(duration["startTimestamp"] ?? duration["startTimestampMs"]),
                      let end = dates.date(duration["endTimestamp"] ?? duration["endTimestampMs"]),
                      end >= start else {
                    result.skippedSegments += 1
                    continue
                }
                try admit(visitPingCount(start: start, end: end), after: result, maxPings: maxPings)
                result.pings.append(contentsOf: visitPings(at: coord, start: start, end: end))
                result.visitCount += 1
                continue
            }

            if let activity = object["activitySegment"] as? [String: Any] {
                guard let duration = activity["duration"] as? [String: Any],
                      let start = dates.date(duration["startTimestamp"] ?? duration["startTimestampMs"]),
                      let end = dates.date(duration["endTimestamp"] ?? duration["endTimestampMs"]),
                      end >= start else {
                    result.skippedSegments += 1
                    continue
                }
                var points: [TimelinePing] = []
                if let startLocation = activity["startLocation"] as? [String: Any],
                   let coord = e7Coordinate(startLocation) {
                    points.append(TimelinePing(
                        timestamp: start, latitude: coord.lat, longitude: coord.lon,
                        horizontalAccuracy: pathAccuracyMeters
                    ))
                }
                // Waypoints carry no timestamps — interpolate evenly across
                // the segment (route evidence, not dwell evidence).
                if let waypointPath = activity["waypointPath"] as? [String: Any],
                   let waypoints = waypointPath["waypoints"] as? [[String: Any]], !waypoints.isEmpty {
                    let span = end.timeIntervalSince(start)
                    for (i, waypoint) in waypoints.enumerated() {
                        guard let coord = e7Coordinate(waypoint, latKey: "latE7", lonKey: "lngE7") else { continue }
                        let fraction = Double(i + 1) / Double(waypoints.count + 1)
                        points.append(TimelinePing(
                            timestamp: start.addingTimeInterval(span * fraction),
                            latitude: coord.lat, longitude: coord.lon,
                            horizontalAccuracy: pathAccuracyMeters
                        ))
                    }
                }
                if let endLocation = activity["endLocation"] as? [String: Any],
                   let coord = e7Coordinate(endLocation) {
                    points.append(TimelinePing(
                        timestamp: end, latitude: coord.lat, longitude: coord.lon,
                        horizontalAccuracy: pathAccuracyMeters
                    ))
                }
                guard !points.isEmpty else {
                    result.skippedSegments += 1
                    continue
                }
                let thinned = thin(points, to: pathPointsPerSegmentCap)
                try admit(thinned.count, after: result, maxPings: maxPings)
                result.pings.append(contentsOf: thinned)
                result.activityCount += 1
                result.pathPointCount += max(0, thinned.count - 2)
                continue
            }

            result.skippedSegments += 1
        }

        return try finalize(result)
    }

    // MARK: - Shared synthesis / helpers

    private static func finalize(_ raw: TimelineParseResult) throws -> TimelineParseResult {
        guard !raw.pings.isEmpty else { throw TimelineImportError.empty }
        var result = raw
        result.pings.sort { $0.timestamp < $1.timestamp }
        return result
    }

    /// Visit → start + end + interior pings (hourly, capped) at the place
    /// coordinate, so `StayClusterer` sees genuine dwell. An instantaneous
    /// visit emits a single ping.
    private static func visitPings(at coord: (lat: Double, lon: Double), start: Date, end: Date) -> [TimelinePing] {
        func ping(_ t: Date) -> TimelinePing {
            TimelinePing(timestamp: t, latitude: coord.lat, longitude: coord.lon,
                         horizontalAccuracy: visitAccuracyMeters)
        }
        guard end > start else { return [ping(start)] }
        var pings = [ping(start)]
        let span = end.timeIntervalSince(start)
        let interiorCount = visitInteriorCount(span: span)
        if interiorCount > 0 {
            for i in 1...interiorCount {
                pings.append(ping(start.addingTimeInterval(span * Double(i) / Double(interiorCount + 1))))
            }
        }
        pings.append(ping(end))
        return pings
    }

    /// How many fixes `visitPings` builds for a visit, without building them.
    static func visitPingCount(start: Date, end: Date) -> Int {
        end > start ? visitInteriorCount(span: end.timeIntervalSince(start)) + 2 : 1
    }

    private static func visitInteriorCount(span: TimeInterval) -> Int {
        // Clamp in floating point BEFORE converting: `Int(_: Double)` traps
        // on overflow, and `min` applied to its result is too late. Defense
        // in depth behind DateParser's epoch ceiling.
        let rawCount = span / visitInteriorSpacingSeconds
        let denseCount = rawCount >= Double(visitInteriorCap) ? visitInteriorCap : Int(rawCount)
        // Fragmentation floor: enough interior pings that the
        // even spread keeps every gap ≤ `visitInteriorMaxGapSeconds`
        // (gap == span / (interiorCount + 1)), so the clusterer sees one
        // continuous stay however long the visit is. Same float-first
        // clamping discipline as above.
        let neededRaw = (span / visitInteriorMaxGapSeconds).rounded(.up) - 1
        let neededCount = neededRaw >= Double(visitInteriorAbsoluteCap)
            ? visitInteriorAbsoluteCap
            : max(0, Int(neededRaw))
        return max(denseCount, neededCount)
    }

    /// Evenly thin an ordered point list to at most `cap` entries, always
    /// keeping the first and last.
    private static func thin(_ points: [TimelinePing], to cap: Int) -> [TimelinePing] {
        guard points.count > cap, cap >= 2 else { return points }
        var thinned: [TimelinePing] = []
        for i in 0..<cap {
            let index = Int((Double(i) * Double(points.count - 1) / Double(cap - 1)).rounded())
            thinned.append(points[index])
        }
        return thinned
    }

    /// Pull a coordinate STRING out of the several shapes the modern export
    /// uses: a bare string, or `{"latLng": "…"}`.
    private static func coordinateString(from value: Any?) -> String? {
        if let s = value as? String { return s }
        if let dict = value as? [String: Any] { return dict["latLng"] as? String }
        return nil
    }

    /// `"37.9838°, 23.7275°"` / `"geo:37.9838,23.7275"` → coordinate.
    static func parseCoordinate(_ raw: String) -> (lat: Double, lon: Double)? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("geo:") { text = String(text.dropFirst(4)) }
        text = text.replacingOccurrences(of: "°", with: "")
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2,
              let lat = Double(parts[0]), let lon = Double(parts[1]),
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return (lat, lon)
    }

    /// Legacy E7 integers → coordinate. Values outside range (Google's
    /// occasional 4e9-offset corruption on negative longitudes) are
    /// rejected → the segment is skipped, not mis-placed.
    private static func e7Coordinate(
        _ dict: [String: Any],
        latKey: String = "latitudeE7",
        lonKey: String = "longitudeE7"
    ) -> (lat: Double, lon: Double)? {
        guard let latE7 = int(dict[latKey]), let lonE7 = int(dict[lonKey]) else { return nil }
        let lat = Double(latE7) / 1e7
        let lon = Double(lonE7) / 1e7
        guard abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return (lat, lon)
    }

    private static func int(_ value: Any?) -> Int64? {
        if let i = value as? Int64 { return i }
        if let i = value as? Int { return Int64(i) }
        // Integral doubles that fit Int64 already bridged via `as? Int64`
        // above (SE-0170 exact-fit NSNumber casts), so a Double landing
        // here is corrupt (exponent literal wider than Int64, fractional
        // E7, NaN/±Inf). `Int64(exactly:)` rejects all of those into the
        // segment-skip path — the trapping `Int64(_:)` would abort the
        // whole import on a single bad field.
        if let d = value as? Double { return Int64(exactly: d) }
        if let s = value as? String { return Int64(s) }
        return nil
    }

    /// ISO-8601 date parsing, both with and without fractional seconds,
    /// plus the legacy `…Ms` epoch-millisecond strings. Instantiated once
    /// per `parse()` call and threaded through (`ISO8601DateFormatter` is
    /// not Sendable, so it can't live in a static — the TripDataImporter
    /// pattern).
    private struct DateParser {
        let fractional: ISO8601DateFormatter
        let plain: ISO8601DateFormatter

        init() {
            fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            plain = ISO8601DateFormatter()
        }

        func date(_ value: Any?) -> Date? {
            guard let raw = value as? String else { return nil }
            // Try the parse that matches the string's shape first: a failed
            // formatter attempt costs tens of microseconds per date. An
            // all-digit string is never an internet date-time, and only a
            // string with a fraction separator can need `fractional`. Both
            // formatters and the epoch check stay as fallbacks, so the
            // accepted strings and their dates are unchanged.
            let utf8 = raw.utf8
            if !utf8.isEmpty,
               utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
               let date = Self.epochMillisecondDate(raw) {
                return date
            }
            if utf8.contains(where: { $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: ",") }) {
                if let date = fractional.date(from: raw) { return date }
                if let date = plain.date(from: raw) { return date }
            } else {
                if let date = plain.date(from: raw) { return date }
                if let date = fractional.date(from: raw) { return date }
            }
            return Self.epochMillisecondDate(raw)
        }

        private static func epochMillisecondDate(_ raw: String) -> Date? {
            // Ceiling rejects corrupt magnitudes (`"1e30"` is a finite Double
            // that clears the lower bound but yields a Date whose interval
            // arithmetic overflows Int downstream) and non-finite values
            // (+inf fails `<`, NaN fails `>`). Real Takeout timestamps are
            // bounded by the export date; 2100 leaves generous slack.
            if let ms = Double(raw), ms > 1_000_000_000_000, ms < epochMillisecondCeiling {
                return Date(timeIntervalSince1970: ms / 1000)
            }
            return nil
        }

        /// 2100-01-01T00:00:00Z in epoch milliseconds.
        static let epochMillisecondCeiling: Double = 4_102_444_800_000
    }
}
