import Foundation
import Testing
@testable import TravelLog

struct FlightJudgeReleasePolicyTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)
    private func at(_ hour: Double) -> Date { base.addingTimeInterval(hour * 3600) }
    private func point(_ longitude: Double, _ start: Double, _ end: Double,
                       island: String? = nil) -> FlightJudge.Stay {
        FlightJudge.Stay(id: UUID(), start: at(start), end: at(end), latitude: 0,
                         longitude: longitude, isAirport: longitude == 0 || longitude == 4.5,
                         islandName: island, pingCount: 1, isPhoto: false, mode: .unknown)
    }
    private var airports: FlightJudge.Airports {
        let origin = FlightJudge.Airport(code: "AAA", latitude: 0, longitude: 0, scheduled: true)
        let destination = FlightJudge.Airport(code: "BBB", latitude: 0, longitude: 4.5, scheduled: true)
        return FlightJudge.Airports(
            at: { _, lon in abs(lon) < 0.02 ? origin : abs(lon - 4.5) < 0.02 ? destination : nil },
            serving: { _, lon in abs(lon) < 0.9 ? origin : abs(lon - 4.5) < 0.9 ? destination : nil })
    }
    private func decision(_ rows: [FlightJudge.Stay]) throws -> FlightJudge.Decision {
        let timeline = FlightJudge.Timeline(rows)
        let journey = try #require(timeline.journey(containing: timeline.stays.count - 1))
        let assessment = try #require(FlightJudge.assess(journey, in: timeline, airports: airports))
        return FlightJudge.decide(assessment)
    }

    @Test("island labels alone cannot turn a surface-shaped segment into an automatic flight")
    func weakWaterSpeedHasNoRecordingAuthority() throws {
        let rows = [point(0, 0, 4, island: "A"), point(2.25, 4.75, 4.76, island: "A"),
                    point(4.5, 5.6, 10, island: "B")]
        if case .record = try decision(rows) { Issue.record("Island metadata granted recording authority") }
    }

    @Test("a waypoint faster than any land transport still records the flight")
    func landPaceSeenInAirRecords() throws {
        let rows = [point(0, 0, 0), point(2.25, 0.4, 0.4), point(4.5, 1, 5)]
        #expect(try decision(rows) == .record(.seenInAir))
    }
}
