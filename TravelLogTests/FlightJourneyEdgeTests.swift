import Foundation
import SwiftData
import Testing
@testable import TravelLog

/// A visit's departure is the last fix at a stay, and a journey another
/// one passes through never hides it from review.
@MainActor
struct FlightJourneyEdgeTests {
    private let base = Date(timeIntervalSince1970: 1_689_718_400)

    private func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }

    private func stay(_ start: Double, _ end: Double, _ latitude: Double, _ longitude: Double,
                      airport: Bool = false, mode: TransitMode = .unknown,
                      source: DataSource = .liveSLC) -> Stay {
        let stay = Stay(startTime: at(start), endTime: at(end),
                        centroidLatitude: latitude, centroidLongitude: longitude,
                        h3IndexRes6: "", pingCount: 4, distanceFromHomeKm: 100, pingIDs: [], source: source)
        stay.category = .transit
        stay.isAirport = airport
        stay.transitFromPreviousRaw = mode.rawValue
        return stay
    }

    private func judgeStay(_ stay: Stay, departed: Bool = false) -> FlightJudge.Stay {
        FlightJudge.Stay(id: stay.id, start: stay.startTime, end: stay.endTime,
                         latitude: stay.centroidLatitude, longitude: stay.centroidLongitude,
                         isAirport: stay.isAirport, islandName: nil, pingCount: stay.pingCount,
                         isPhoto: false, mode: FlightJudge.Mode(raw: stay.transitFromPreviousRaw),
                         endIsDeparture: departed)
    }

    private func records(_ stays: [Stay], departed: Set<UUID> = []) throws -> (
        flights: [CollectionsAggregator.FlightRecord], candidates: [CollectionsAggregator.PossibleFlight]
    ) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        for stay in stays { context.insert(stay) }
        try context.save()
        return try CollectionsAggregator.flightLogRecords(
            rows: stays.map { CollectionsAggregator.StayRow($0) }, predecessorOnly: [],
            dismissedCandidates: [], flightTimes: [:], flightStops: [:], departedStayIDs: departed)
    }

    @Test("a stay a visit's departure ended was last seen at its end, in the judge and the record")
    func visitDepartureIsTheLastFix() throws {
        let origin = stay(0, 2, 37.9364, 23.9445, airport: true)
        let arrival = stay(5, 29, 52.3086, 4.76389, airport: true, mode: .flight)
        let timeline = FlightJudge.Timeline([judgeStay(origin), judgeStay(arrival)])
        // Clustering ran the end on into the silence: the last fix is earlier.
        #expect(timeline.lastSeen(0) == at(0))
        let departed = FlightJudge.Timeline([judgeStay(origin, departed: true), judgeStay(arrival)])
        #expect(departed.lastSeen(0) == at(2))

        #expect(try records([origin, arrival]).flights.first?.departureWindowStart == at(0))
        let record = try #require(try records([origin, arrival], departed: [origin.id]).flights.first)
        #expect(record.departureWindowStart == at(2))
    }

    @Test("a journey that is not the stay's own never keeps the stay's own one out of review")
    func otherJourneyDoesNotBlockReview() throws {
        // Landing for minutes, then a short stop; a stay starting inside that
        // stop has the landing before it too and ends a journey first. The
        // landing's own journey runs on to the city.
        let origin = stay(0, 2, 37.9364, 23.9445, airport: true)
        // Not an airport stay (one is always a journey's end): a fix on the way.
        let landing = stay(5, 5.1, 52.3086, 4.76389)
        let stop = stay(5.3, 5.4, 52.3, 4.8)
        let overlapping = stay(5.35, 8, 52.3, 4.9)
        let city = stay(5.6, 30, 52.4, 4.9)
        let reduced = try records([origin, landing, stop, overlapping, city])
        let candidate = try #require(reduced.candidates.first)
        #expect(reduced.candidates.count == 1)
        #expect(candidate.arrivalIdentifier == landing.persistentModelID)
        #expect(candidate.record.actionGuard?.arrival == city.persistentModelID)
    }

    @Test("a row leaves out a distance or duration the data cannot give")
    func unknownMeasuresStayHidden() {
        #expect(FlightLogView.distanceAndDuration(km: 0, hours: 0, estimated: true) == nil)
        #expect(FlightLogView.distanceAndDuration(km: 0, hours: 2, estimated: true)
            == "≈ " + FlightLogView.formatHours(2))
        #expect(FlightLogView.distanceAndDuration(km: 0, hours: 2, estimated: false)
            == FlightLogView.formatHours(2))
        #expect(FlightLogView.distanceAndDuration(km: 900, hours: 0, estimated: true)
            == UnitsFormatter.formatDistance(kilometers: 900))
    }

    @Test("a changed flight and a failed save say different things")
    func refusalsAreDistinct() {
        #expect(FlightDetailSheet.Refusal.changed.title != FlightDetailSheet.Refusal.failed.title)
    }
}
