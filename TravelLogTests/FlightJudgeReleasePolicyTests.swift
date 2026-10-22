import Foundation
import Testing
@testable import TravelLog

struct FlightJudgeReleasePolicyTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)
    private func at(_ hour: Double) -> Date { base.addingTimeInterval(hour * 3600) }
    private func point(_ longitude: Double, _ start: Double, _ end: Double,
                       observed: Double? = nil, island: String? = nil) -> FlightJudge.Stay {
        FlightJudge.Stay(id: UUID(), start: at(start), end: at(end), latitude: 0,
                         longitude: longitude, isAirport: longitude == 0 || longitude == 4.5,
                         islandName: island, pingCount: 1, isPhoto: false, mode: .unknown,
                         lastObservedAt: observed.map(at), firstObservedAt: observed == nil ? nil : at(start))
    }
    private var airports: FlightJudge.Airports {
        let origin = FlightJudge.Airport(code: "AAA", latitude: 0, longitude: 0, scheduled: true)
        let destination = FlightJudge.Airport(code: "BBB", latitude: 0, longitude: 4.5, scheduled: true)
        return FlightJudge.Airports(
            at: { _, lon in abs(lon) < 0.02 ? origin : abs(lon - 4.5) < 0.02 ? destination : nil },
            serving: { _, lon in abs(lon) < 0.9 ? origin : abs(lon - 4.5) < 0.9 ? destination : nil })
    }
    private func decision(_ rows: [FlightJudge.Stay], complete: Bool = true) throws -> FlightJudge.Decision {
        let timeline = FlightJudge.Timeline(rows, overlapCoverageComplete: complete)
        let journey = try #require(timeline.journey(containing: timeline.stays.count - 1))
        let assessment = try #require(FlightJudge.assess(journey, in: timeline, airports: airports))
        return FlightJudge.decide(assessment)
    }

    @Test("island labels alone cannot turn a surface-shaped segment into an automatic flight")
    func weakWaterSpeedHasNoRecordingAuthority() throws {
        let rows = [point(0, 0, 4, observed: 3.25, island: "A"),
                    point(2.25, 4.75, 4.76, observed: 4.75, island: "A"),
                    point(4.5, 5.6, 10, observed: 5.6, island: "B")]
        if case .record = try decision(rows) { Issue.record("Island metadata granted recording authority") }
    }

    @Test("actual observations preserve airborne recall; incomplete overlap evidence stays reviewable")
    func strongMeasuredFlightAndIncompleteCoverage() throws {
        let rows = [point(0, 0, 0, observed: 0), point(2.25, 0.4, 0.4, observed: 0.4),
                    point(4.5, 1, 5, observed: 1)]
        #expect(try decision(rows) == .record(.seenInAir))
        if case .record = try decision(rows, complete: false) { Issue.record("Incomplete overlap coverage recorded") }
        if case .none = try decision(rows, complete: false) { Issue.record("Incomplete coverage hid review evidence") }
    }

    @Test("an unmeasured imported boundary can suggest without claiming automatic surface exclusion")
    func unmeasuredWindowCannotRecord() throws {
        let unknown = [point(0, 0, 0.5), point(4.5, 1.5, 8)]
        if case .record = try decision(unknown) { Issue.record("Unmeasured timestamps recorded a flight") }
        let measured = [point(0, 0, 0.5, observed: 0.5), point(4.5, 1.5, 8, observed: 1.5)]
        #expect(try decision(measured) == .record(.tooFastForSurface))
    }

    @Test("a long far overlap remains a contradiction after twenty intervening rows")
    func completeActiveOverlapCoverage() {
        let padding = (1...20).map { number in
            let hour = Double(-10 + number) / 3
            return point(90, hour, hour + 0.01, observed: hour)
        }
        let timeline = FlightJudge.Timeline([point(90, -10, 20, observed: 20)] + padding
                                            + [point(0, 0, 2, observed: 1), point(4.5, 2.8, 9, observed: 2.8)])
        for index in timeline.stays.indices where timeline.stays[index].longitude < 5 {
            #expect(timeline.isConflicted[index])
        }
    }

    @Test("divergent physical UUID twins are still contradictory observations")
    func physicalTwinsCanConflict() {
        let first = point(0, 0, 2, observed: 1)
        let twin = FlightJudge.Stay(id: first.id, start: at(0), end: at(2), latitude: 0,
                                    longitude: 4.5, isAirport: false, islandName: nil,
                                    pingCount: 1, isPhoto: false, mode: .unknown,
                                    lastObservedAt: at(1), firstObservedAt: at(0))
        #expect(FlightJudge.Timeline([first, twin]).isConflicted == [true, true])
        #expect(FlightJudge.Timeline([first, first]).isConflicted == [false, false])
    }
}
