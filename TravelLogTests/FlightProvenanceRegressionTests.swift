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

    @Test("retained photos recover historical track mixtures without rewriting stored ownership")
    func legacyTrackEvidence() {
        for stored in [DataSource.timelineImport.rawValue, DataSource.gpxImport.rawValue] {
            let retained = [stored, DataSource.photoImport.rawValue, DataSource.photoImport.rawValue]
            #expect(DataSource.sourceRawsForEvidence(storedRaw: stored, retainedRaws: retained)
                == [stored, DataSource.photoImport.rawValue].sorted())
            #expect(DataSource.needsPhotoTimeCaution(
                storedRaw: stored, retainedRaws: retained, memberEvidenceComplete: true))
            #expect(DataSource.needsPhotoTimeCaution(
                storedRaw: stored, retainedRaws: [stored], memberEvidenceComplete: false))
            #expect(!DataSource.needsPhotoTimeCaution(
                storedRaw: stored, retainedRaws: [stored], memberEvidenceComplete: true))
        }
    }

    @Test("unknown retained raw values survive evidence union and stay cautious")
    func unknownEvidence() {
        let retained = ["futureSource", DataSource.foregroundStream.rawValue]
        #expect(DataSource.sourceRawsForEvidence(storedRaw: "futureSource", retainedRaws: retained)
            == ["futureSource", DataSource.foregroundStream.rawValue].sorted())
        #expect(DataSource.derivedRecordSourceRaw("futureSource") == "futureSource")
        #expect(DataSource.needsPhotoTimeCaution(
            storedRaw: DataSource.liveSLC.rawValue, retainedRaws: retained, memberEvidenceComplete: true))
    }

    @Test("legacy stored track tags are recovered from retained physical ping evidence",
          arguments: [DataSource.timelineImport.rawValue, DataSource.gpxImport.rawValue])
    func inheritedMixtureRecovery(trackRaw: String) throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let track = LocationPing(timestamp: Self.start, latitude: 37.98, longitude: 23.72,
                                 horizontalAccuracy: 10, h3IndexRes6: "test")
        track.sourceRaw = trackRaw
        let photo = LocationPing(timestamp: Self.start.addingTimeInterval(600),
                                 latitude: 37.98, longitude: 23.72,
                                 horizontalAccuracy: 10, h3IndexRes6: "test", source: .photoImport)
        let stay = Stay(startTime: Self.start, endTime: Self.start.addingTimeInterval(600),
                        centroidLatitude: 37.98, centroidLongitude: 23.72,
                        h3IndexRes6: "test", pingCount: 2, distanceFromHomeKm: 500,
                        pingIDs: [track.id, photo.id])
        // Reproduce the inherited bug, rather than running corrected import.
        stay.sourceRaw = trackRaw
        context.insert(track)
        context.insert(photo)
        context.insert(stay)
        try context.save()
        let result = try FlightObservationBounds.fetch(stays: [stay], in: context)
        let recovered = try #require(result[stay.persistentModelID])
        #expect(recovered.memberEvidenceComplete)
        #expect(Set(recovered.retainedSourceRaws) == Set([trackRaw, DataSource.photoImport.rawValue]))
        #expect(DataSource.needsPhotoTimeCaution(
            storedRaw: stay.sourceRaw, retainedRaws: recovered.retainedSourceRaws,
            memberEvidenceComplete: recovered.memberEvidenceComplete))
        #expect(stay.sourceRaw == trackRaw, "recovery does not rewrite persisted ownership")

        // If sync/pruning leaves a member absent, its source is unresolved.
        context.delete(photo)
        try context.save()
        let prunedResult = try FlightObservationBounds.fetch(stays: [stay], in: context)
        let pruned = try #require(prunedResult[stay.persistentModelID])
        #expect(!pruned.memberEvidenceComplete)
        #expect(DataSource.needsPhotoTimeCaution(
            storedRaw: stay.sourceRaw, retainedRaws: pruned.retainedSourceRaws,
            memberEvidenceComplete: pruned.memberEvidenceComplete))
        #expect(stay.sourceRaw == trackRaw)
    }

    @Test("import preattachment preserves track/photo mixtures, user overrides and protected source tags",
          arguments: [DataSource.timelineImport.rawValue, DataSource.gpxImport.rawValue,
                      DataSource.sharedImport.rawValue, "futureSource"])
    func persistedAttachment(hostRaw: String) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let original = LocationPing(timestamp: Self.start, latitude: 37.98, longitude: 23.72,
                                    horizontalAccuracy: 10, h3IndexRes6: "test")
        original.sourceRaw = hostRaw
        original.isProcessed = true
        let stay = Stay(startTime: Self.start, endTime: Self.start,
                        centroidLatitude: 37.98, centroidLongitude: 23.72,
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
                                  latitude: 37.98, longitude: 23.72, horizontalAccuracy: 10)
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
        let original = LocationPing(timestamp: Self.start, latitude: 37.98, longitude: 23.72,
                                    horizontalAccuracy: 10, h3IndexRes6: "test")
        original.sourceRaw = "futureSource"
        context.insert(original)
        try context.save()
        let recorder = PingRecorder(modelContainer: container)
        if sessionIndex { await recorder.beginImportDedupSession() }
        let inserted = try await recorder.recordImportedPings([
            ImportedPingCandidate(timestamp: Self.start, latitude: 37.98,
                                  longitude: 23.72, horizontalAccuracy: 10)
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
                        centroidLatitude: 37.98, centroidLongitude: 23.72,
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
