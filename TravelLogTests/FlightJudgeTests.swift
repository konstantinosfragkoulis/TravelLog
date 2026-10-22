//
//  FlightJudgeTests.swift
//  TravelLogTests
//
//  `FlightJudge`, the one answer to "did the user fly here?" that the
//  inferer and the Flight Log share: journeys cut at real places, the
//  window from the origin's last fix, each way of travelling's fastest and
//  usual times, and the decision with its one reason.
//
//  Airports are real `airports.json` points (ATH, JSY, AMS, CDG, LYS, SOF)
//  behind a fixture lookup, so these tests pin the rules, not the dataset.
//  Every other point is a round fictional coordinate.
//

import Testing
import Foundation
@testable import TravelLog

struct FlightJudgeTests {

    // MARK: - Fixtures

    private static let fixtureAirports: [FlightJudge.Airport] = [
        FlightJudge.Airport(code: "ATH", latitude: 37.9364, longitude: 23.9445, scheduled: true),
        FlightJudge.Airport(code: "JSY", latitude: 37.4228, longitude: 24.9509, scheduled: true),
        FlightJudge.Airport(code: "AMS", latitude: 52.3086, longitude: 4.76389, scheduled: true),
        FlightJudge.Airport(code: "CDG", latitude: 49.00896, longitude: 2.55412, scheduled: true),
        FlightJudge.Airport(code: "LYS", latitude: 45.726, longitude: 5.09014, scheduled: true),
        FlightJudge.Airport(code: "SOF", latitude: 42.6967, longitude: 23.4114, scheduled: true),
    ]

    private static func nearest(_ latitude: Double, _ longitude: Double, withinKm radius: Double) -> FlightJudge.Airport? {
        fixtureAirports
            .map { ($0, FlightJudge.haversineKm(latitude, longitude, $0.latitude, $0.longitude)) }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?.0
    }

    private static var airports: FlightJudge.Airports {
        FlightJudge.Airports(
            at: { nearest($0, $1, withinKm: 3) },
            serving: { nearest($0, $1, withinKm: FlightJudge.servingRadiusKm) })
    }

    /// About 22 km from ATH, on the mainland.
    private static let mainland = (lat: 38.0, lon: 23.7)
    /// About 14 km from AMS.
    private static let north = (lat: 52.4, lon: 4.9)
    /// A town about 5 km from JSY, on the island.
    private static let islandTown = (lat: 37.45, lon: 24.9)
    /// Open ocean, no airport within 1,000 km.
    private static let ocean = (lat: 30.0, lon: -40.0)

    private static let base = Date(timeIntervalSinceReferenceDate: 900_000_000)

    private func at(_ hours: Double) -> Date { Self.base.addingTimeInterval(hours * 3600) }

    private func stay(
        _ point: (lat: Double, lon: Double), _ from: Double, _ to: Double,
        airport: Bool = false, island: String? = nil, photo: Bool = false,
        mode: FlightJudge.Mode = .unknown, pings: Int = 1, id: UUID = UUID()
    ) -> FlightJudge.Stay {
        FlightJudge.Stay(id: id, start: at(from), end: at(to), latitude: point.lat, longitude: point.lon,
                         isAirport: airport, islandName: island, pingCount: pings, isPhoto: photo, mode: mode)
    }

    /// The journey ending at the last stay, judged.
    private func judge(
        _ stays: [FlightJudge.Stay], context: FlightJudge.Context? = nil
    ) throws -> (assessment: FlightJudge.Assessment, decision: FlightJudge.Decision) {
        let timeline = FlightJudge.Timeline(stays)
        let journey = try #require(timeline.journey(containing: timeline.stays.count - 1))
        let assessment = try #require(FlightJudge.assess(journey, in: timeline, airports: Self.airports))
        return (assessment, FlightJudge.decide(
            assessment, context: context ?? FlightJudge.context(of: journey, in: timeline)))
    }

    // MARK: - Journeys

    @Test("a stay of twenty minutes or more is a place; a brief fix on the move is a waypoint")
    func dwellMakesAnAnchor() throws {
        let origin = stay(Self.mainland, 0, 2)
        let fix = stay((lat: 38.2, lon: 23.4), 2.5, 2.6)
        let destination = stay((lat: 38.6, lon: 22.9), 3, 8)
        let timeline = FlightJudge.Timeline([destination, fix, origin])
        #expect(timeline.isAnchor == [true, false, true])
        let journey = try #require(timeline.journey(containing: 1))
        #expect(journey.origin == 0)
        #expect(journey.members == [1, 2])
        #expect(timeline.journeys() == [journey])

        // The same fix held for half an hour, its extension aside, is a place.
        let longStop = stay((lat: 38.2, lon: 23.4), 2.5, 3.1)
        let later = stay((lat: 38.6, lon: 22.9), 3.2, 8)
        #expect(FlightJudge.Timeline([origin, longStop, later]).isAnchor == [true, true, true])
    }

    @Test("a brief stay followed by two hours of silence is a place; the newest stay always is")
    func silenceMakesAnAnchor() {
        let origin = stay(Self.mainland, 0, 2)
        let photo = stay((lat: 38.2, lon: 23.4), 3, 3.05)
        let next = stay((lat: 38.3, lon: 23.3), 5.2, 9)
        #expect(FlightJudge.Timeline([origin, photo, next]).isAnchor == [true, true, true])
        // Newest: nothing after it yet.
        #expect(FlightJudge.Timeline([origin, photo]).isAnchor == [true, true])
    }

    @Test("an airport stay is a place, unless the phone only passed over it with the air on both sides")
    func airportAnchors() {
        let origin = stay(Self.mainland, 0, 2)
        // A two-minute fix in the JSY ring, about 125 km out and 1,300 km
        // on, each faster than anything crossing the water.
        let ring = stay((lat: 37.42, lon: 24.95), 2.2, 2.23, airport: true, island: "Twinisle")
        let far = stay((lat: 45.0, lon: 11.0), 5, 9)
        #expect(FlightJudge.Timeline([origin, ring, far]).isAnchor == [true, false, true])
        // Landed: the ground after it.
        let town = stay(Self.islandTown, 3, 9, island: "Twinisle")
        #expect(FlightJudge.Timeline([origin, ring, town]).isAnchor == [true, true, true])
    }

    @Test("the previous stay is the latest ending before, ties on the larger uuidString, never a UUID twin")
    func previousLinks() throws {
        let low = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let high = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let a = stay(Self.mainland, 0, 2, id: low)
        let b = stay((lat: 38.1, lon: 23.6), 1, 2, id: high)
        let c = stay((lat: 38.2, lon: 23.5), 3, 4)
        let timeline = FlightJudge.Timeline([c, a, b])
        let index = try #require(timeline.stays.firstIndex { $0.id == c.id })
        #expect(timeline.stays[try #require(timeline.previous[index])].id == high)
        // A twin of c ending before it is not its own previous.
        let twin = stay((lat: 38.2, lon: 23.5), 2.5, 2.8, id: c.id)
        let withTwin = FlightJudge.Timeline([a, b, twin, c])
        let last = try #require(withTwin.stays.lastIndex { $0.id == c.id })
        #expect(withTwin.stays[try #require(withTwin.previous[last])].id == high)
    }

    // MARK: - Window

    @Test("the window runs from the origin's last fix: its end less the half gap clustering added")
    func windowUndoesTheExtension() throws {
        let origin = stay(Self.mainland, 0, 2)
        let destination = stay(Self.north, 3, 9)
        let (assessment, _) = try judge([origin, destination])
        // The hour between the stays is half the silence: last seen at 1:00.
        #expect(assessment.lastSeenAtOrigin == at(1))
        #expect(assessment.windowSeconds == 2 * 3600)
        // The extension never exceeds the stay itself.
        let brief = stay(Self.mainland, 0, 0.5)
        let (short, _) = try judge([brief, stay(Self.north, 4, 9)])
        #expect(short.lastSeenAtOrigin == at(0))
        // A photo at either end adds its slack.
        let photo = stay(Self.mainland, 0, 2, photo: true)
        let (slack, _) = try judge([photo, destination])
        #expect(slack.photoEnd)
        #expect(slack.windowSeconds == 2 * 3600 + FlightJudge.photoClockSlackSeconds)
    }

    @Test("each way of travelling's fastest and usual hours follow the distance")
    func modeHours() throws {
        let (a, _) = try judge([stay(Self.mainland, 0, 4), stay(Self.north, 7, 12)])
        let d = a.distanceKm
        #expect(abs(a.road.fastest - d / 130) < 1e-9)
        #expect(abs(a.road.usual - (d * 1.3 / 80 + 0.25)) < 1e-9)
        #expect(abs(a.rail.fastest - (d / 250 + 0.25)) < 1e-9)
        #expect(abs(a.rail.usual - (d / 120 + 0.5)) < 1e-9)
        #expect(a.ferry == nil)
        #expect(a.served)
        let flight = try #require(a.flight)
        #expect(flight.fastest < a.surfaceFastestHours)
        #expect(flight.usual > flight.fastest)
        // Between two airports' own rings, rail is the airport-station kind.
        let (b, _) = try judge([stay((lat: 49.01, lon: 2.55), 0, 1, airport: true),
                                stay((lat: 45.73, lon: 5.09), 3, 4, airport: true)])
        #expect(b.airportToAirport)
        #expect(abs(b.rail.fastest - (b.distanceKm / 210 + 0.1)) < 1e-9)
        // Across water a ferry joins.
        let (c, _) = try judge([stay(Self.islandTown, 0, 4, island: "Twinisle"), stay(Self.mainland, 6, 9)])
        let ferry = try #require(c.ferry)
        #expect(c.crossesWater)
        #expect(abs(ferry.fastest - c.distanceKm / 80) < 1e-9)
        #expect(abs(ferry.usual - (c.distanceKm * 1.2 / 35 + 1)) < 1e-9)
        #expect(FlightJudge.blockHours(distanceKm: 780) == 1.5)
    }

    // MARK: - Decision

    @Test("recorded when no car or train could have made it in the window, with margin")
    func recordsWhenTheGroundIsRuledOut() throws {
        // About 2,170 km in six hours from the last fix: the fastest train
        // needs nearly nine.
        let (a, decision) = try judge([stay(Self.mainland, 0, 4), stay(Self.north, 7, 12)])
        #expect(abs(a.windowHours - 6) < 1e-9)
        #expect(decision == .record(.tooFastForSurface))
        #expect(FlightJudge.pace(a) == .onlyPlane)
        // Ten hours: a train cannot be ruled out with margin, but the road
        // and rail usually take far longer.
        let (b, slower) = try judge([stay(Self.mainland, 0, 4), stay(Self.north, 10, 12)])
        #expect(abs(b.windowHours - 10) < 1e-9)
        #expect(slower == .suggest(.tooFarOverland))
        #expect(FlightJudge.pace(b) == .planeOrFastTrain)
    }

    @Test("a window no flight fits, or ends no scheduled airport serves, is never a flight")
    func flightMustFit() throws {
        // Two hours for 2,170 km: not even a flight.
        let (tooShort, none) = try judge([stay(Self.mainland, 0, 1), stay(Self.north, 2, 6)])
        #expect(!tooShort.flightFits)
        #expect(none == .none)
        // Open ocean at both ends, however fast.
        let (ocean, unserved) = try judge([stay(Self.ocean, 0, 1),
                                           stay((lat: 35.0, lon: -40.0), 2, 3)])
        #expect(!ocean.served)
        #expect(unserved == .none)
    }

    @Test("seen in the air: a fix on the way reached faster than any train is recorded")
    func seenInTheAir() throws {
        // Last seen at 8:30, then a fix about 600 km on at 9:30, then the
        // destination.
        let origin = stay(Self.mainland, 6, 9)
        let fix = stay((lat: 42.5, lon: 19.0), 9.5, 9.6)
        let destination = stay(Self.north, 13, 18)
        let timeline = FlightJudge.Timeline([origin, fix, destination])
        #expect(timeline.isAnchor == [true, false, true])
        let (a, decision) = try judge([origin, fix, destination])
        #expect(try #require(a.airborneKmh) > FlightJudge.airborneKmh)
        #expect(decision == .record(.seenInAir))
    }

    @Test("a fast fix off the route, or faster than an airliner, is bad data, not a flight")
    func strayFixesProveNothing() throws {
        let origin = stay(Self.mainland, 6, 9)
        // Fast, but away from the destination.
        let offRoute = stay((lat: 33.0, lon: 28.0), 9.5, 9.6)
        let destination = stay(Self.north, 30, 40)
        let (a, _) = try judge([origin, offRoute, destination])
        #expect(a.airborneKmh == nil)
        // 1,500 km in half an hour.
        let impossible = stay((lat: 46.0, lon: 12.0), 9, 9.1)
        let (b, _) = try judge([stay(Self.mainland, 6, 8.5), impossible, destination])
        #expect(b.airborneKmh == nil)
    }

    @Test("airport to airport by high-speed rail is suggested, never recorded")
    func airportRailIsNeverRecorded() throws {
        // CDG to LYS, about 390 km, both with airport stations: three hours
        // from the last fix at one to the first at the other.
        let (a, decision) = try judge([stay((lat: 49.01, lon: 2.55), 0, 1, airport: true),
                                       stay((lat: 45.73, lon: 5.09), 3, 4, airport: true)])
        #expect(abs(a.windowHours - 3) < 1e-9)
        #expect(decision == .suggest(.airportToAirport))
        // Half a day later: a long gap from an airport, never a record.
        let (_, later) = try judge([stay((lat: 49.01, lon: 2.55), 0, 1, airport: true),
                                    stay((lat: 45.73, lon: 5.09), 12, 13, airport: true)])
        #expect(later == .suggest(.longGap))
    }

    @Test("across water faster than a ferry is suggested; a ferry's time is not")
    func acrossWater() throws {
        // The island town to the mainland, about 127 km, an hour and a half
        // from the last fix (2:00 less the 45 minutes clustering added):
        // the fastest ferry needs over an hour and a half.
        let (a, fast) = try judge([stay(Self.islandTown, 0, 2, island: "Twinisle"), stay(Self.mainland, 2.75, 6)])
        #expect(abs(a.windowHours - 1.5) < 1e-9)
        #expect(fast == .suggest(.acrossWater))
        let (_, ferry) = try judge([stay(Self.islandTown, 0, 3, island: "Twinisle"), stay(Self.mainland, 4, 9)])
        #expect(ferry == .none)
        // From the island's airport, faster than a ferry plausibly manages.
        let (_, fromAirport) = try judge([stay((lat: 37.42, lon: 24.95), 0, 3, airport: true, island: "Twinisle"),
                                          stay(Self.mainland, 4.5, 9)])
        #expect(fromAirport == .suggest(.acrossWater))
        // From the port inside the same airport's ring, 2 km from its point:
        // a ferry's time from a port.
        let (port, fromPort) = try judge([stay((lat: 37.44, lon: 24.94), 0, 3, airport: true, island: "Twinisle"),
                                          stay(Self.mainland, 4.5, 9)])
        #expect(!port.originAtAirport)
        #expect(fromPort == .none)
    }

    @Test("a far stay the timeline comes straight back from is bad data, never a flight's end")
    func straysAreNeverFlights() throws {
        // ATH's ring, then SOF's 2.5 hours on (faster than the airport
        // train), then back by ATH an hour and a half later: quicker than
        // flying out and back.
        let origin = stay((lat: 37.94, lon: 23.94), 0, 1, airport: true)
        let stray = stay((lat: 42.69, lon: 23.41), 2.5, 2.6, airport: true)
        let back = stay(Self.mainland, 4, 9)
        let timeline = FlightJudge.Timeline([origin, stray, back])
        #expect(timeline.isStray == [false, true, false])
        for index in [1, 2] {
            let journey = try #require(timeline.journey(containing: index))
            #expect(FlightJudge.assess(journey, in: timeline, airports: Self.airports) == nil)
        }
        // A day there is a trip out and back.
        let trip = FlightJudge.Timeline([origin, stray, stay(Self.mainland, 30, 40)])
        #expect(trip.isStray == [false, false, false])
        let out = try #require(trip.journey(containing: 1))
        let assessment = try #require(FlightJudge.assess(out, in: trip, airports: Self.airports))
        #expect(FlightJudge.decide(assessment) == .suggest(.tooFastForSurface))
    }

    @Test("a long gap is suggested only over distances rarely travelled by land, or from an airport")
    func longGaps() throws {
        // Three days for 2,170 km.
        let (_, far) = try judge([stay(Self.mainland, 0, 12), stay(Self.north, 72, 90)])
        #expect(far == .suggest(.longGap))
        // Three days for about 520 km of land: a road trip as likely.
        let (_, nearer) = try judge([stay(Self.mainland, 0, 12), stay((lat: 42.6, lon: 23.3), 72, 90)])
        #expect(nearer == .none)
        // The same from inside the ATH ring.
        let (_, fromAirport) = try judge([stay((lat: 37.94, lon: 23.94), 0, 12, airport: true),
                                          stay((lat: 42.6, lon: 23.3), 72, 90)])
        #expect(fromAirport == .suggest(.longGap))
        // Across water from an island airport's terminal, about 205 km: a
        // ferry does not leave from the runway. From the port in its ring,
        // a ferry's crossing.
        let (_, fromIsland) = try judge([stay((lat: 37.42, lon: 24.95), 0, 12, airport: true, island: "Twinisle"),
                                         stay((lat: 38.6, lon: 23.2), 36, 40)])
        #expect(fromIsland == .suggest(.longGap))
        let (_, fromPort) = try judge([stay((lat: 37.44, lon: 24.94), 0, 12, airport: true, island: "Twinisle"),
                                       stay((lat: 38.6, lon: 23.2), 36, 40)])
        #expect(fromPort == .none)
        #expect(FlightJudge.pace(try judge([stay(Self.mainland, 0, 12), stay(Self.north, 72, 90)]).assessment)
                == .inconclusive)
    }

    @Test("a leg measured on the ground re-opens only when the ground is ruled out, and only as a suggestion")
    func measuredOnTheGround() throws {
        let ground = FlightJudge.Context(measuredOnGround: true)
        let (_, ruledOut) = try judge([stay(Self.mainland, 0, 4), stay(Self.north, 7, 12)], context: ground)
        #expect(ruledOut == .suggest(.tooFastForSurface))
        let (_, possible) = try judge([stay(Self.mainland, 0, 4), stay(Self.north, 10, 12)], context: ground)
        #expect(possible == .none)
        // The context reads it from the journey's legs.
        let timeline = FlightJudge.Timeline([stay(Self.mainland, 0, 4), stay(Self.north, 7, 12, mode: .ground)])
        let journey = try #require(timeline.journey(containing: 1))
        #expect(FlightJudge.context(of: journey, in: timeline).measuredOnGround)
    }

    @Test("short hops are never suggested, and overlapping far stays are bad data")
    func shortHopsAndConflicts() throws {
        let (_, short) = try judge([stay(Self.mainland, 0, 2), stay((lat: 38.3, lon: 23.4), 2.2, 6)])
        #expect(short == .none)
        // A stay 100 km away overlapping the origin: nobody is in two places.
        let origin = stay(Self.mainland, 0, 4)
        let elsewhere = stay((lat: 38.9, lon: 23.7), 3, 3.5)
        let destination = stay(Self.north, 7, 12)
        let timeline = FlightJudge.Timeline([origin, elsewhere, destination])
        #expect(timeline.isConflicted[0] && timeline.isConflicted[1])
        let journey = try #require(timeline.journey(containing: 2))
        #expect(FlightJudge.assess(journey, in: timeline, airports: Self.airports) == nil)
    }

    @Test("pace words follow the same comparison: plane, fast train, ground, slow")
    func paceWords() throws {
        // About 510 km: fastest rail 2.3 h, fastest road 3.9 h, usual road
        // 8.6 h. The window is the arrival hour (last seen at 0:00).
        let far = (lat: 42.6, lon: 23.3)
        func pace(_ arrival: Double) throws -> FlightJudge.Pace {
            FlightJudge.pace(try judge([stay(Self.mainland, 0, 1), stay(far, arrival, arrival + 5)]).assessment)
        }
        #expect(try pace(2) == .onlyPlane)
        #expect(try pace(2.5) == .planeOrFastTrain)
        #expect(try pace(4.5) == .ground)
        #expect(try pace(9) == .slow)
    }

    // MARK: - Recording

    @Test("a journey's flight goes on its first stay; a later stay upgrades an unknown first")
    func recordingTargets() throws {
        let origin = stay(Self.mainland, 6, 9)
        let fix = stay((lat: 42.5, lon: 19.0), 9.5, 9.6)
        let destination = stay(Self.north, 13, 18, mode: .pending)
        let timeline = FlightJudge.Timeline([origin, fix, destination])
        let recording = FlightJudge.recording(for: 2, in: timeline, airports: Self.airports, dismissed: [])
        #expect(recording.decision == .record(.seenInAir))
        #expect(recording.target == 1)
        // The first stay judged itself, while it was the newest.
        let alone = FlightJudge.Timeline([origin, stay((lat: 42.5, lon: 19.0), 9.5, 9.6, mode: .pending)])
        #expect(FlightJudge.recording(for: 1, in: alone, airports: Self.airports, dismissed: []).target == 1)
    }

    @Test("a flight, the user's Not a Flight, or a dismissal anywhere in the journey closes it")
    func closedJourneys() {
        let origin = stay(Self.mainland, 6, 9)
        for mode in [FlightJudge.Mode.flight, .notFlight] {
            let fix = stay((lat: 42.5, lon: 19.0), 9.5, 9.6, mode: mode)
            let timeline = FlightJudge.Timeline([origin, fix, stay(Self.north, 13, 18, mode: .pending)])
            #expect(FlightJudge.recording(for: 2, in: timeline, airports: Self.airports, dismissed: []).target == nil)
        }
        let fix = stay((lat: 42.5, lon: 19.0), 9.5, 9.6)
        let timeline = FlightJudge.Timeline([origin, fix, stay(Self.north, 13, 18, mode: .pending)])
        #expect(FlightJudge.recording(for: 2, in: timeline, airports: Self.airports, dismissed: [fix.id]).target == nil)
        // A legacy ground mode on the first stay is never upgraded.
        let measured = stay((lat: 42.5, lon: 19.0), 9.5, 9.6, mode: .ground)
        let groundLine = FlightJudge.Timeline([origin, measured, stay(Self.north, 13, 18, mode: .pending)])
        #expect(FlightJudge.recording(for: 2, in: groundLine, airports: Self.airports, dismissed: []).target == nil)
    }
}
