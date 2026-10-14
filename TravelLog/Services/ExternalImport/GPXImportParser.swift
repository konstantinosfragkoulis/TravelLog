//
//  GPXImportParser.swift
//  TravelLog
//
//  External-history import:
//  GPX tracks from Garmin/Strava/hiking apps and Arc's GPX export. Only
//  TIMESTAMPED `<trkpt>` entries are usable — TravelLog reconstructs
//  history, so a coordinate without a time is dropped (and counted).
//  `<wpt>` waypoints are ignored by design: they carry no dwell evidence.
//
//  Recorded GPS tracks are dense (often 1 fix/second); points are thinned
//  to one per `minimumSpacingSeconds` per track segment so a week of
//  recording lands at photo-import scale, not six figures of rows. Output
//  reuses `TimelinePing` and rides the same Settings import spine.
//

import Foundation

nonisolated struct GPXParseResult: Sendable {
    var pings: [TimelinePing] = []
    var trackCount = 0
    /// Points dropped for a missing/unparsable time or coordinate
    /// (thinned points are NOT counted — they're represented, not lost).
    var skippedPoints = 0
}

nonisolated enum GPXImportError: Error, Equatable {
    /// Not XML, or XML without a single `<trkpt>`.
    case notGPX
    /// Track points existed but none carried a usable timestamp.
    case empty
    /// The XML broke mid-file (truncated download, corrupt export). Track
    /// points parsed before the failure exist, but importing them silently
    /// as a complete track would misrepresent the file.
    case malformed
}

nonisolated enum GPXImportParser {

    /// Keep at most one point per this interval within a track segment.
    static let minimumSpacingSeconds: TimeInterval = 60
    /// Recorded GPS fixes are real fixes — tighter than the Timeline
    /// import's synthesized visit/path accuracies.
    static let trackAccuracyMeters: Double = 30

    static func parse(_ data: Data) throws -> GPXParseResult {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        let parsedCleanly = parser.parse()

        guard delegate.sawTrackPoint else { throw GPXImportError.notGPX }
        // Order matters: a file that never yielded a <trkpt> is "not GPX"
        // regardless of where the XML broke; a file that DID yield track
        // points but then broke is a truncated real track — refuse rather
        // than silently import the fragment as complete.
        guard parsedCleanly else { throw GPXImportError.malformed }
        var result = delegate.result
        guard !result.pings.isEmpty else { throw GPXImportError.empty }
        result.pings.sort { $0.timestamp < $1.timestamp }
        return result
    }

    /// Classic streaming delegate — GPX files can be tens of MB, and
    /// `XMLParser` never materializes the whole tree.
    private final class Delegate: NSObject, XMLParserDelegate {
        var result = GPXParseResult()
        var sawTrackPoint = false

        private let isoFractional: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        private let isoPlain = ISO8601DateFormatter()

        private var inTrack = false
        private var currentPoint: (lat: Double, lon: Double)?
        private var currentTimeText = ""
        private var collectingTime = false
        private var lastKeptTimestamp: Date?

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            switch elementName {
            case "trk":
                inTrack = true
                result.trackCount += 1
            case "trkseg":
                // Segment boundary: the next point always survives thinning
                // (a gap in the recording is real signal).
                lastKeptTimestamp = nil
            case "trkpt":
                sawTrackPoint = true
                guard inTrack,
                      let lat = attributes["lat"].flatMap(Double.init),
                      let lon = attributes["lon"].flatMap(Double.init),
                      abs(lat) <= 90, abs(lon) <= 180 else {
                    currentPoint = nil
                    if inTrack { result.skippedPoints += 1 }
                    return
                }
                currentPoint = (lat, lon)
                currentTimeText = ""
            case "time" where currentPoint != nil:
                collectingTime = true
                currentTimeText = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if collectingTime { currentTimeText += string }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            switch elementName {
            case "time":
                collectingTime = false
            case "trkpt":
                defer { currentPoint = nil }
                guard let point = currentPoint else { return }
                let raw = currentTimeText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let timestamp = isoFractional.date(from: raw) ?? isoPlain.date(from: raw) else {
                    result.skippedPoints += 1
                    return
                }
                // Thin: one point per spacing window per segment. Only a
                // FORWARD-in-time neighbor thins — a backwards jump means
                // an out-of-order or restarted recording, and swallowing
                // that point would lose real signal.
                if let last = lastKeptTimestamp {
                    let delta = timestamp.timeIntervalSince(last)
                    if delta >= 0 && delta < GPXImportParser.minimumSpacingSeconds {
                        return
                    }
                }
                lastKeptTimestamp = timestamp
                result.pings.append(TimelinePing(
                    timestamp: timestamp,
                    latitude: point.lat,
                    longitude: point.lon,
                    horizontalAccuracy: GPXImportParser.trackAccuracyMeters
                ))
            case "trk":
                inTrack = false
            default:
                break
            }
        }
    }
}
