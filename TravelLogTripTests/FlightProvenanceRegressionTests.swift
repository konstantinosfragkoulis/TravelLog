import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Flight provenance regression")
struct FlightProvenanceRegressionTests {
    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("photo attachment retains mixed track provenance and protects shared or future host tags")
    func attachmentPolicy() {
        for host in [DataSource.timelineImport, .gpxImport, .jsonImport, .liveSLC] {
            #expect(DataSource.sourceRawAfterImportAttachment(
                hostRaw: host.rawValue, incomingRaw: DataSource.photoImport.rawValue)
                    == DataSource.merged.rawValue)
        }
        for host in [DataSource.sharedImport.rawValue, "futureSource"] {
            #expect(DataSource.sourceRawAfterImportAttachment(
                hostRaw: host, incomingRaw: DataSource.photoImport.rawValue) == host)
        }
        #expect(DataSource.sourceRawAfterImportAttachment(
            hostRaw: DataSource.gpxImport.rawValue, incomingRaw: DataSource.gpxImport.rawValue)
                == DataSource.gpxImport.rawValue)
        #expect(DataSource.sourceRawAfterImportAttachment(
            hostRaw: DataSource.liveSLC.rawValue, incomingRaw: DataSource.foregroundStream.rawValue)
                == DataSource.liveSLC.rawValue)
    }

    @Test("unknown raw values survive the derived-record lane")
    func unknownDerivedSource() {
        #expect(DataSource.derivedRecordSourceRaw("futureSource") == "futureSource")
        #expect(DataSource.derivedRecordSourceRaw(DataSource.foregroundStream.rawValue)
            == DataSource.liveSLC.rawValue)
    }

    @Test("import preattachment preserves track/photo mixtures, user overrides and protected source tags",
          arguments: [DataSource.timelineImport.rawValue, DataSource.gpxImport.rawValue,
                      DataSource.sharedImport.rawValue, "futureSource"])
    func persistedAttachment(hostRaw: String) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let original = LocationPing(timestamp: Self.start, latitude: 44.3, longitude: 12.9,
                                    horizontalAccuracy: 10, h3IndexRes6: "test")
        original.sourceRaw = hostRaw
        original.isProcessed = true
        let stay = Stay(startTime: Self.start, endTime: Self.start,
                        centroidLatitude: 44.3, centroidLongitude: 12.9,
                        h3IndexRes6: "test", pingCount: 1, distanceFromHomeKm: 500,
                        pingIDs: [original.id])
        stay.sourceRaw = hostRaw
        stay.category = .destination
        stay.userOverridden = true
        context.insert(original)
        context.insert(stay)
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let inserted = try await recorder.recordImportedPings([
            ImportedPingCandidate(timestamp: Self.start.addingTimeInterval(600),
                                  latitude: 44.3, longitude: 12.9, horizontalAccuracy: 10)
        ])
        try await recorder.saveImportBatch()
        #expect(inserted == 1)
        let reloaded = ModelContext(container)
        let storedStays = try reloaded.fetch(FetchDescriptor<Stay>())
        let result = try #require(storedStays.only)
        let expected = [DataSource.sharedImport.rawValue, "futureSource"].contains(hostRaw)
            ? hostRaw : DataSource.merged.rawValue
        #expect(result.sourceRaw == expected)
        #expect(result.userOverridden)
        #expect(result.category == .destination)
        #expect(result.pingIDs.count == 2)
        #expect(result.endTime == Self.start.addingTimeInterval(600))
        let pings = try reloaded.fetch(FetchDescriptor<LocationPing>())
        #expect(Set(pings.map(\.sourceRaw)) == Set([hostRaw, DataSource.photoImport.rawValue]))
        #expect(pings.allSatisfy { $0.isProcessed })
    }

    @Test("an unknown existing ping cannot authorize dropping a matching imported photo",
          arguments: [false, true])
    func unknownPingDoesNotDeduplicatePhoto(sessionIndex: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let original = LocationPing(timestamp: Self.start, latitude: 44.3, longitude: 12.9,
                                    horizontalAccuracy: 10, h3IndexRes6: "test")
        original.sourceRaw = "futureSource"
        context.insert(original)
        try context.save()
        let recorder = PingRecorder(modelContainer: container)
        if sessionIndex { await recorder.beginImportDedupSession() }
        let inserted = try await recorder.recordImportedPings([
            ImportedPingCandidate(timestamp: Self.start, latitude: 44.3,
                                  longitude: 12.9, horizontalAccuracy: 10)
        ])
        try await recorder.saveImportBatch()
        #expect(inserted == 1)
        let raws = try ModelContext(container).fetch(FetchDescriptor<LocationPing>()).map(\.sourceRaw)
        #expect(Set(raws) == Set(["futureSource", DataSource.photoImport.rawValue]))
    }

    @Test("trip summary retains a homogeneous unknown raw source")
    func tripSourceDoesNotBecomeLive() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: Self.start)
        let stay = Stay(startTime: Self.start, endTime: Self.start.addingTimeInterval(3600),
                        centroidLatitude: 44.3, centroidLongitude: 12.9,
                        h3IndexRes6: "test", pingCount: 0, distanceFromHomeKm: 500, pingIDs: [])
        stay.sourceRaw = "futureSource"
        stay.category = .destination
        context.insert(trip)
        context.insert(stay)
        stay.trip = trip
        trip.stays = [stay]
        trip.recomputeSummary()
        #expect(trip.sourceRaw == "futureSource")
        #expect(stay.sourceRaw == "futureSource")
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
