import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct FlightObservationBoundsTests {
    private let base = Date(timeIntervalSince1970: 1_750_000_000)
    private func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }

    private func stay(in context: ModelContext, start: Double = 0, end: Double = 2) -> Stay {
        let row = Stay(startTime: at(start), endTime: at(end), centroidLatitude: 38,
                       centroidLongitude: 24, h3IndexRes6: "", pingCount: 0,
                       distanceFromHomeKm: 0, pingIDs: [])
        context.insert(row)
        return row
    }

    @Test("closed Visit and ping-backed midpoint stay retain the same actual end")
    func measuredRepresentationsAgree() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let visitStay = stay(in: context, end: 1)
        context.insert(Visit(arrivalDate: at(0), departureDate: at(1), latitude: 38,
                             longitude: 24, horizontalAccuracy: 10, receivedAt: at(1.2),
                             stayID: visitStay.id, isProcessed: true))
        let pingStay = stay(in: context, end: 2)
        let ping = LocationPing(timestamp: at(1), latitude: 38, longitude: 24,
                                horizontalAccuracy: 10, h3IndexRes6: "")
        pingStay.pingIDs = [ping.id]
        context.insert(ping)
        try context.save()
        let evidence = try FlightObservationBounds.fetch(stays: [visitStay, pingStay], in: context)
        #expect(evidence[visitStay.persistentModelID]?.lastObservedAt == at(1))
        #expect(evidence[visitStay.persistentModelID]?.firstObservedAt == at(0))
        #expect(evidence[visitStay.persistentModelID]?.memberEvidenceComplete == true)
        #expect(evidence[pingStay.persistentModelID]?.lastObservedAt == at(1))
    }

    @Test("an open Visit callback receipt does not measure continued presence")
    func delayedOpenVisitDoesNotNarrowWindow() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let row = stay(in: context, end: 12)
        context.insert(Visit(arrivalDate: at(0), latitude: 38, longitude: 24,
                             horizontalAccuracy: 10, receivedAt: at(10), stayID: row.id,
                             isProcessed: true))
        try context.save()
        let evidence = try FlightObservationBounds.fetch(stays: [row], in: context)
        #expect(evidence[row.persistentModelID]?.lastObservedAt == at(0))
    }

    @Test("a same-place successor clipping a closed Visit's departure preserves its actual arrival")
    func clippedClosedVisitRetainsArrival() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let row = stay(in: context, end: 2)
        let successor = stay(in: context, start: 2 + 1.0 / 3600, end: 4)
        context.insert(Visit(arrivalDate: at(0.25), departureDate: at(3), latitude: 38,
                             longitude: 24, horizontalAccuracy: 10, receivedAt: at(3.2),
                             stayID: row.id, isProcessed: true))
        try context.save()
        let evidence = try FlightObservationBounds.fetch(stays: [row, successor], in: context)
        let value = try #require(evidence[row.persistentModelID])
        #expect(row.endTime == successor.startTime.addingTimeInterval(-1))
        #expect(value.firstObservedAt == at(0.25))
        #expect(value.lastObservedAt == at(0.25))
        #expect(value.memberEvidenceComplete)
    }

    @Test("a closed Visit's actual departure survives when its arrival precedes the clipped stay")
    func clippedClosedVisitRetainsDeparture() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let row = stay(in: context)
        context.insert(Visit(arrivalDate: at(-1), departureDate: at(1), latitude: 38,
                             longitude: 24, horizontalAccuracy: 10, receivedAt: at(10),
                             stayID: row.id, isProcessed: true))
        try context.save()
        let value = try #require(FlightObservationBounds.fetch(stays: [row], in: context)[row.persistentModelID])
        #expect(value.firstObservedAt == at(1))
        #expect(value.lastObservedAt == at(1))
    }

    @Test("out-of-range Visit instants and a departure before arrival supply no measured boundary")
    func invalidOrOutsideVisitInstantsAreNotClamped() throws {
        for (arrival, departure) in [(-1.0, 3.0), (1.0, -1.0)] {
            let context = ModelContext(try TestSupport.makeInMemoryContainer())
            let row = stay(in: context)
            context.insert(Visit(arrivalDate: at(arrival), departureDate: at(departure), latitude: 38,
                                 longitude: 24, horizontalAccuracy: 10, receivedAt: at(10),
                                 stayID: row.id, isProcessed: true))
            try context.save()
            let value = try #require(FlightObservationBounds.fetch(stays: [row], in: context)[row.persistentModelID])
            #expect(value.firstObservedAt == nil && value.lastObservedAt == nil)
            #expect(!value.memberEvidenceComplete)
        }
    }

    @Test("synthetic external points retain provenance without claiming observed timestamps")
    func syntheticSourcesRemainReviewEvidence() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        var rows: [Stay] = []
        for source in [DataSource.timelineImport, .jsonImport, .sharedImport, .merged] {
            let row = stay(in: context)
            row.sourceRaw = source.rawValue
            let ping = LocationPing(timestamp: at(1), latitude: 38, longitude: 24,
                                    horizontalAccuracy: 10, h3IndexRes6: "", source: source)
            row.pingIDs = [ping.id]
            context.insert(ping)
            rows.append(row)
        }
        try context.save()
        let evidence = try FlightObservationBounds.fetch(stays: rows, in: context)
        for row in rows {
            let value = try #require(evidence[row.persistentModelID])
            #expect(value.lastObservedAt == nil && value.firstObservedAt == nil)
            #expect(value.retainedSourceRaws == [row.sourceRaw])
            #expect(value.memberEvidenceComplete)
        }
    }

    @Test("Visit UUID links cannot choose a physical stay twin outside the requested set")
    func visitCannotChoosePhysicalTwin() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let row = stay(in: context)
        let twin = stay(in: context, start: 10, end: 12)
        twin.id = row.id
        context.insert(Visit(arrivalDate: at(0), departureDate: at(1), latitude: 38,
                             longitude: 24, horizontalAccuracy: 10, receivedAt: at(1),
                             stayID: row.id, isProcessed: true))
        try context.save()
        let value = try #require(FlightObservationBounds.fetch(stays: [row], in: context)[row.persistentModelID])
        #expect(value.lastObservedAt == nil && !value.memberEvidenceComplete)
    }

    @Test("missing members are incomplete evidence and required cancellation throws")
    func missingMembersAndCancellation() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let row = stay(in: context)
        row.pingIDs = [UUID()]
        try context.save()
        let value = try #require(FlightObservationBounds.fetch(stays: [row], in: context)[row.persistentModelID])
        #expect(value.lastObservedAt == nil && !value.memberEvidenceComplete)
        #expect(throws: CancellationError.self) {
            _ = try FlightObservationBounds.fetch(stays: [row], in: context,
                                                  checkCancellation: { throw CancellationError() })
        }
    }

    @Test("physical ping twins retain every source and measure only an identical observation")
    func pingTwinsCannotChooseAnObservation() throws {
        for conflicting in [false, true] {
            let context = ModelContext(try TestSupport.makeInMemoryContainer())
            let row = stay(in: context)
            let first = LocationPing(timestamp: at(0.5), latitude: 38, longitude: 24,
                                     horizontalAccuracy: 10, h3IndexRes6: "", source: .gpxImport)
            let twin = LocationPing(timestamp: at(conflicting ? 1 : 0.5), latitude: 38, longitude: 24,
                                    horizontalAccuracy: 10, h3IndexRes6: "",
                                    source: conflicting ? .photoImport : .gpxImport)
            twin.id = first.id
            row.pingIDs = [first.id]
            context.insert(first)
            context.insert(twin)
            try context.save()
            let value = try #require(FlightObservationBounds.fetch(stays: [row], in: context)[row.persistentModelID])
            #expect(value.lastObservedAt == (conflicting ? nil : at(0.5)))
            #expect(value.firstObservedAt == (conflicting ? nil : at(0.5)))
            #expect(value.retainedSourceRaws == (conflicting ? ["gpxImport", "photoImport"] : ["gpxImport"]))
            #expect(value.memberEvidenceComplete)
        }
    }
}
