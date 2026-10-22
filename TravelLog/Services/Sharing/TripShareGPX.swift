//
//  TripShareGPX.swift
//  TravelLog
//
//  One GPX 1.1 document for every shared trip: a waypoint per destination
//  stay (named after its place), then a track per trip (named after the trip)
//  with its fixes in time order. Built from the same filtered trips as the
//  Travel Log file, so it leaves out the same home areas. A track breaks into
//  a new segment wherever the export removed evidence, the line would pass a
//  protected place, or the fixes are too far apart in time or distance to
//  say where the trip went between them, so no line crosses a home.
//

import Foundation

nonisolated enum TripShareGPX {

    static let fileExtension = "gpx"
    /// Fixes further apart than this start a new segment.
    static let maximumGap: TimeInterval = 3600
    static let maximumJumpKm = 25.0

    static func document(for trips: [SharedTrip], exclusions: TripShareExclusions, name: String?,
                         exportedAt: Date, languageTag: String = AppLanguagePreference.currentTag()) -> String {
        var lines: [String] = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<gpx version="1.1" creator="Travel Log" xmlns="http://www.topografix.com/GPX/1/1">"#,
            "  <metadata>",
        ]
        if let name = TripTitleStore.normalized(name) {
            lines.append("    <name>\(escaped(name))</name>")
        }
        lines.append("    <time>\(timestamp(exportedAt))</time>")
        lines.append("  </metadata>")
        // GPX 1.1 orders every waypoint before every track.
        for trip in trips {
            for stay in trip.destinations {
                lines.append(#"  <wpt lat="\#(coordinate(stay.latitude))" lon="\#(coordinate(stay.longitude))">"#)
                lines.append("    <time>\(timestamp(stay.startTime))</time>")
                if let place = TripTitleStore.normalized(stay.locality) ?? stay.placeName {
                    lines.append("    <name>\(escaped(place))</name>")
                }
                lines.append("  </wpt>")
            }
        }
        for trip in trips {
            lines.append("  <trk>")
            if let title = trip.displayTitle(languageTag: languageTag) {
                lines.append("    <name>\(escaped(title))</name>")
            }
            for segment in segments(of: trip, exclusions: exclusions) {
                lines.append("    <trkseg>")
                for ping in segment {
                    lines.append(#"      <trkpt lat="\#(coordinate(ping.latitude))" lon="\#(coordinate(ping.longitude))">"#)
                    if let altitude = ping.altitude, (ping.verticalAccuracy ?? -1) >= 0 {
                        lines.append("        <ele>\(String(format: "%.1f", altitude))</ele>")
                    }
                    lines.append("        <time>\(timestamp(ping.timestamp))</time>")
                    lines.append("      </trkpt>")
                }
                lines.append("    </trkseg>")
            }
            lines.append("  </trk>")
        }
        lines.append("</gpx>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The trip's fixes in time order, cut wherever a line may not join
    /// two neighbours.
    static func segments(of trip: SharedTrip, exclusions: TripShareExclusions) -> [[SharedPing]] {
        var segments: [[SharedPing]] = []
        var current: [SharedPing] = []
        for ping in trip.orderedPings {
            if let last = current.last, !joins(last, ping, trip: trip.shareID, exclusions: exclusions) {
                segments.append(current)
                current = []
            }
            current.append(ping)
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    static func joins(_ a: SharedPing, _ b: SharedPing, trip: UUID, exclusions: TripShareExclusions) -> Bool {
        b.timestamp.timeIntervalSince(a.timestamp) <= maximumGap
            && TripShareExport.haversineKm(a.latitude, a.longitude, b.latitude, b.longitude) <= maximumJumpKm
            && exclusions.joins(
                trip: trip,
                .init(latitude: a.latitude, longitude: a.longitude, date: a.timestamp),
                .init(latitude: b.latitude, longitude: b.longitude, date: b.timestamp))
    }

    static func coordinate(_ value: Double) -> String {
        String(format: "%.7f", value)
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
    }

    static func escaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                // XML 1.0 admits only its Char repertoire, and a numeric
                // reference cannot smuggle anything else in: drop the C0
                // controls but tab, newline and return, and U+FFFE/U+FFFF.
                // Swift scalars are never surrogates.
                guard isXMLChar(scalar) else { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// XML 1.0's Char production: #x9, #xA, #xD, #x20-#xD7FF, #xE000-#xFFFD
    /// and #x10000-#x10FFFF.
    static func isXMLChar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x9, 0xA, 0xD, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: true
        default: false
        }
    }
}
