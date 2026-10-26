import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Flight dismissal survives physical twins", .serialized)
struct FlightDismissalTwinRegressionTests {
    private func at(_ hour: Double) -> Date {
        Date(timeIntervalSince1970: 1_748_736_000 + hour * 3_600)
    }

    @discardableResult
    private func insert(_ point: (Double, Double), start: Double, end: Double,
                        observed: Double? = nil, airport: Bool = false,
                        transit: TransitMode? = .unknown, in context: ModelContext) -> Stay {
        let ping = LocationPing(timestamp: at(observed ?? end), latitude: point.0,
                                longitude: point.1, horizontalAccuracy: 10, h3IndexRes6: "")
        ping.isProcessed = true
        context.insert(ping)
        let row = Stay(startTime: at(start), endTime: at(end), centroidLatitude: point.0,
                       centroidLongitude: point.1, h3IndexRes6: "", pingCount: 1,
                       distanceFromHomeKm: 0, pingIDs: [ping.id])
        row.category = .transit
        row.isAirport = airport
        row.transitFromPreviousRaw = transit?.rawValue
        context.insert(row)
        return row
    }

    @Test("negative dismissal veto survives a divergent physical twin in every writer and projection",
          arguments: ["direct", "outside", "geometry", "collections", "projection"])
    func dismissedJourneyDoesNotResurface(path: String) async throws {
        try #require(AirportDetector.shared.airportCount > 0)
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        insert((37.9364, 23.9445), start: 6, end: 9, observed: 8.5,
               airport: true, in: context)
        let fix = insert((36, 18), start: 9.5, end: 9 + 35.0 / 60,
                         in: context)
        let oldTwin = insert((0, 0), start: -365 * 24, end: -365 * 24 + 1,
                             in: context)
        oldTwin.id = fix.id
        insert((35.84593, 14.49155), start: 10 + 40.0 / 60, end: 12,
               airport: true,
               transit: ["direct", "outside"].contains(path) ? nil : .unknown,
               in: context)
        let logicalID = fix.id
        try context.save()
        let physicalID = fix.persistentModelID
        let inferer = TransitInferer(modelContainer: container)
        switch path {
        case "direct":
            let result = await TransitInferer.TestScope.$dismissedArrivals.withValue([logicalID]) {
                await inferer.inferTransitForRecentStaysReportingChanges()
            }
            #expect(!result.failed && result.flights == 0)
        case "outside":
            let result = await TransitInferer.TestScope.$dismissedArrivals.withValue([logicalID]) {
                await inferer.inferTransitBatchOutsideGate(gate: PipelineGate(forTesting: ()), publishing: false)
            }
            #expect(!result.failed && result.flights == 0)
        case "geometry":
            let result = await TransitInferer.TestScope.$dismissedArrivals.withValue([logicalID]) {
                await inferer.reinferUnknownLegsGeometry(gate: PipelineGate(forTesting: ()))
            }
            #expect(!result.failed && result.complete && result.upgraded == 0)
        default:
            let fresh = ModelContext(container)
            let stays = try fresh.fetch(FetchDescriptor<Stay>())
            if path == "collections" {
                let result = CollectionsAggregator.aggregate(stays: stays, dismissedCandidates: [logicalID])
                #expect(!result.possibleFlights.contains { $0.id == logicalID })
            } else {
                let result = try CollectionsAggregator.flightLogRecords(
                    rows: stays.map { CollectionsAggregator.StayRow($0) },
                    predecessorOnly: [], dismissedCandidates: [logicalID])
                #expect(!result.candidates.contains { $0.id == logicalID })
            }
        }
        let reread = ModelContext(container)
        let physical = try #require(reread.model(for: physicalID) as? Stay)
        #expect(physical.transitFromPreviousRaw == TransitMode.unknown.rawValue)
    }
}
