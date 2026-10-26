//
//  GPXImportParserTests.swift
//  TravelLogTests
//
//  Pure parser tests for the GPX track import: timestamped-trkpt
//  extraction, per-segment
//  time thinning, waypoint/timeless tolerance, refusals, and the
//  chronological-output contract shared with the Timeline import.
//  No @Model construction — NOT @MainActor.
//

import Testing
import Foundation
@testable import TravelLog

struct GPXImportParserTests {

    private func parse(_ xml: String) throws -> GPXParseResult {
        try GPXImportParser.parse(Data(xml.utf8))
    }

    private func trkpt(_ lat: Double, _ lon: Double, _ time: String) -> String {
        #"<trkpt lat="\#(lat)" lon="\#(lon)"><time>\#(time)</time></trkpt>"#
    }

    @Test("timestamped track points parse with track accuracy and sorted output")
    func basicTrackParses() throws {
        let result = try parse("""
        <gpx><trk><trkseg>
        \(trkpt(37.98, 23.72, "2024-05-01T10:02:00Z"))
        \(trkpt(37.99, 23.73, "2024-05-01T10:00:00Z"))
        </trkseg></trk></gpx>
        """)
        #expect(result.trackCount == 1)
        #expect(result.pings.count == 2)
        #expect(result.pings.first?.latitude == 37.99)
        #expect(result.pings.map(\.timestamp) == result.pings.map(\.timestamp).sorted())
        #expect(result.pings.allSatisfy { $0.horizontalAccuracy == GPXImportParser.trackAccuracyMeters })
    }

    @Test("dense fixes are thinned to one per spacing window, per segment")
    func denseTrackIsThinned() throws {
        // 10 fixes 10 s apart (10:00:00…10:01:30) at 60 s spacing →
        // keep 10:00:00 and 10:01:00 only.
        let points = (0..<10).map { i in
            let seconds = i * 10
            let time = String(format: "2024-05-01T10:%02d:%02dZ", seconds / 60, seconds % 60)
            return trkpt(10.0 + Double(i) * 0.0001, 20.0, time)
        }.joined()
        let result = try parse("<gpx><trk><trkseg>\(points)</trkseg></trk></gpx>")
        #expect(result.pings.count == 2)
        // A new segment resets the thinning window even at the same instant.
        let twoSegments = try parse("""
        <gpx><trk>
        <trkseg>\(trkpt(1, 1, "2024-05-01T10:00:00Z"))\(trkpt(1, 1, "2024-05-01T10:00:30Z"))</trkseg>
        <trkseg>\(trkpt(2, 2, "2024-05-01T10:00:40Z"))</trkseg>
        </trk></gpx>
        """)
        #expect(twoSegments.pings.count == 2)
        #expect(twoSegments.pings.last?.latitude == 2)
    }

    @Test("timeless and malformed points are counted and skipped; waypoints ignored")
    func toleranceAndWaypoints() throws {
        let result = try parse("""
        <gpx>
        <wpt lat="5.0" lon="5.0"><time>2024-05-01T10:00:00Z</time></wpt>
        <trk><trkseg>
        <trkpt lat="1.0" lon="1.0"></trkpt>
        <trkpt lat="95.0" lon="1.0"><time>2024-05-01T10:00:00Z</time></trkpt>
        \(trkpt(2.0, 2.0, "2024-05-01T11:00:00Z"))
        </trkseg></trk></gpx>
        """)
        #expect(result.pings.count == 1)
        #expect(result.pings.first?.latitude == 2.0)
        #expect(result.skippedPoints == 2)
    }

    @Test("non-GPX XML and waypoint-only files throw their own errors")
    func refusals() {
        #expect(throws: GPXImportError.notGPX) {
            _ = try GPXImportParser.parse(Data("<html><body/></html>".utf8))
        }
        #expect(throws: GPXImportError.notGPX) {
            _ = try GPXImportParser.parse(Data("not xml at all".utf8))
        }
        // Track points exist but none carry a time → .empty.
        #expect(throws: GPXImportError.empty) {
            _ = try GPXImportParser.parse(Data(
                #"<gpx><trk><trkseg><trkpt lat="1.0" lon="1.0"/></trkseg></trk></gpx>"#.utf8
            ))
        }
    }
}
