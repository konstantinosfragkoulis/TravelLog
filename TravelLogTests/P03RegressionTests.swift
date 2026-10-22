//
//  P03RegressionTests.swift
//  TravelLogTests
//
//  Import ownership and source removal: which import may stand in for
//  another's evidence, what Discard Imported Photos and Remove Shared Data
//  may take with them, and what the import parsers and the GPX writer
//  accept or emit.
//
//  @MainActor because the app target compiles with MainActor-by-default
//  isolation; assertions re-fetch from a fresh context. Every place and
//  instant is fictional.
//

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Import ownership and source removal", IsolatedLineageDefaults())
struct P03RegressionTests {

    static let base = Date(timeIntervalSinceReferenceDate: 820_000_000)
    static let latitude = 44.3
    static let longitude = 12.9

    func at(_ hours: Double) -> Date {
        Self.base.addingTimeInterval(hours * 3_600)
    }

    /// A longitude `meters` east of the fixture place along its parallel.
    func longitude(metersEast meters: Double) -> Double {
        Self.longitude + meters / (111_320 * cos(Self.latitude * .pi / 180))
    }

    func cell(metersEast meters: Double = 0) -> String {
        H3Service.cellIndex(latitude: Self.latitude, longitude: longitude(metersEast: meters)) ?? ""
    }

    @discardableResult
    func insertPing(
        _ context: ModelContext, at timestamp: Date, metersEast: Double = 0,
        source: DataSource, id: UUID? = nil, processed: Bool = true
    ) -> LocationPing {
        let ping = LocationPing(
            timestamp: timestamp, latitude: Self.latitude,
            longitude: longitude(metersEast: metersEast), horizontalAccuracy: 20,
            h3IndexRes6: cell(metersEast: metersEast), source: source)
        if let id { ping.id = id }
        ping.isProcessed = processed
        context.insert(ping)
        return ping
    }

    @discardableResult
    func insertStay(
        _ context: ModelContext, from start: Date, to end: Date, pings: [LocationPing],
        source: DataSource, metersEast: Double = 0, category: StayCategory = .destination,
        trip: Trip? = nil, order: Int = 0
    ) -> Stay {
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: Self.latitude, centroidLongitude: longitude(metersEast: metersEast),
            h3IndexRes6: cell(metersEast: metersEast), pingCount: pings.count,
            distanceFromHomeKm: 400, pingIDs: pings.map(\.id), source: source)
        stay.category = category
        context.insert(stay)
        if let trip {
            stay.trip = trip
            stay.orderInTrip = order
        }
        return stay
    }

    @discardableResult
    func insertTrip(_ context: ModelContext, from start: Date, to end: Date?,
                    source: DataSource = .liveSLC) -> Trip {
        let trip = Trip(startDate: start, source: source)
        trip.endDate = end
        trip.isComplete = end != nil
        context.insert(trip)
        return trip
    }

    func candidate(_ timestamp: Date, metersEast: Double = 0) -> ImportedPingCandidate {
        ImportedPingCandidate(
            timestamp: timestamp, latitude: Self.latitude,
            longitude: longitude(metersEast: metersEast), horizontalAccuracy: 20)
    }

    func pings(_ container: ModelContainer) throws -> [LocationPing] {
        try ModelContext(container).fetch(FetchDescriptor<LocationPing>())
    }

    func stay(_ id: UUID, _ container: ModelContainer) throws -> Stay? {
        try ModelContext(container).fetch(FetchDescriptor<Stay>(predicate: #Predicate { $0.id == id })).first
    }

    func trip(_ id: UUID, _ container: ModelContainer) throws -> Trip? {
        try ModelContext(container).fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.id == id })).first
    }

    // MARK: - OWN-001

    /// A Timeline or GPX fix at a photo's exact position and time is the
    /// user's own evidence: it is stored beside the photo row, and
    /// Discard Imported Photos leaves it.
    @Test("an external fix matching a photo is kept and survives the photo discard",
          arguments: [DataSource.gpxImport, .timelineImport])
    func externalFixBesidePhotoSurvivesDiscard(source: DataSource) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        insertPing(context, at: at(0), source: .photoImport)
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let accepted = try await recorder.recordImportedPings([candidate(at(0))], source: source)
        try await recorder.saveImportBatch()
        #expect(accepted == 1)
        // The same file again is recognized as the same evidence.
        let repeated = try await recorder.recordImportedPings([candidate(at(0))], source: source)
        try await recorder.saveImportBatch()
        #expect(repeated == 0)

        try await PhotoImportService(modelContainer: container).performDiscardTeardownForTesting()
        let left = try pings(container)
        #expect(left.map(\.source) == [source])
        #expect(left.first?.timestamp == at(0))
    }

    @Test("an external fix matching a shared fix is kept; a photo matching permanent evidence is not")
    func admissionFollowsRemovalDomains() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        insertPing(context, at: at(0), source: .sharedImport)
        insertPing(context, at: at(5), source: .liveSLC)
        insertPing(context, at: at(10), source: .gpxImport)
        insertPing(context, at: at(15), source: .sharedImport)
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        // Remove Shared Data could take the shared row: the Timeline fix stays its own.
        #expect(try await recorder.recordImportedPings([candidate(at(0))], source: .timelineImport) == 1)
        // A photo beside permanent evidence is redundant.
        #expect(try await recorder.recordImportedPings([candidate(at(5))], source: .photoImport) == 0)
        #expect(try await recorder.recordImportedPings([candidate(at(10))], source: .photoImport) == 0)
        // A photo beside a shared fix is kept, for the same reason as the Timeline fix.
        #expect(try await recorder.recordImportedPings([candidate(at(15).addingTimeInterval(30))]) == 1)
        try await recorder.saveImportBatch()
        #expect(try pings(container).count == 6)
    }

    @Test("the launch deduplicator keeps a photo and a Timeline fix of the same moment, in either order",
          arguments: [false, true])
    func postHocDedupKeepsCrossDomainPair(photoFirst: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        insertPing(context, at: at(0).addingTimeInterval(photoFirst ? 0 : 20), source: .photoImport)
        insertPing(context, at: at(0).addingTimeInterval(photoFirst ? 20 : 0), source: .timelineImport)
        // Same-domain controls still collapse.
        insertPing(context, at: at(3), source: .photoImport)
        insertPing(context, at: at(3).addingTimeInterval(10), source: .photoImport)
        insertPing(context, at: at(6), source: .timelineImport)
        insertPing(context, at: at(6).addingTimeInterval(10), source: .gpxImport)
        try context.save()

        await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true)

        let left = try pings(container).sorted { $0.timestamp < $1.timestamp }
        #expect(left.map(\.timestamp) == [at(0), at(0).addingTimeInterval(20), at(3), at(6)])
        #expect(Set(left.prefix(2).map(\.source)) == [.photoImport, .timelineImport])
    }

    // MARK: - HIST-003

    @Test("a GPX or Timeline fix joining a photo host marks the host and its trip mixed",
          arguments: [DataSource.gpxImport, .timelineImport])
    func externalFixMarksPhotoHostMixed(source: DataSource) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let photo = insertPing(context, at: at(0), source: .photoImport)
        let trip = insertTrip(context, from: at(0), to: at(2), source: .photoImport)
        let host = insertStay(context, from: at(0), to: at(2), pings: [photo],
                              source: .photoImport, trip: trip)
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        #expect(try await recorder.recordImportedPings([candidate(at(1))], source: source) == 1)
        try await recorder.saveImportBatch()

        let saved = try #require(try stay(host.id, container))
        #expect(saved.pingIDs.count == 2)
        #expect(saved.source == .merged)
        #expect(try self.trip(trip.id, container)?.source == .merged)
    }

    /// A host absorbed before absorption marked it mixed still reads
    /// `.photoImport`: the discard decides from the fixes it holds, so the
    /// trip keeps its id, name and photo choices on the surviving GPX fix.
    @Test("discard repairs a photo-tagged host holding an external fix and keeps its trip")
    func discardRepairsStalePhotoTaggedHost() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let photo = insertPing(context, at: at(0), source: .photoImport)
        let gpx = insertPing(context, at: at(1), metersEast: 400, source: .gpxImport)
        let trip = insertTrip(context, from: at(0), to: at(1), source: .photoImport)
        trip.customName = "Harbour week"
        let host = insertStay(context, from: at(0), to: at(1), pings: [photo, gpx],
                              source: .photoImport, trip: trip)
        context.insert(HiddenPhoto(localIdentifier: "H1", tripID: trip.id))
        try context.save()
        let gpxID = gpx.id
        let tripID = trip.id

        try await PhotoImportService(modelContainer: container).performDiscardTeardownForTesting()

        let kept = try #require(try self.trip(tripID, container))
        #expect(kept.customName == "Harbour week")
        let repaired = try #require(try stay(host.id, container))
        #expect(repaired.pingIDs == [gpxID])
        #expect(repaired.source == .gpxImport)
        #expect(repaired.startTime == at(1))
        #expect(repaired.trip?.id == tripID)
        let hidden = try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
        #expect(hidden.map(\.tripID) == [tripID])
        #expect(try pings(container).map(\.id) == [gpxID])
    }

    // MARK: - PIMP-001

    /// A shared stay that absorbed a later photo keeps its `.sharedImport`
    /// tag; the discard still finds it by the photo fix it holds and puts
    /// its membership, geometry and trip back to the shared evidence alone.
    @Test("discard repairs a shared host that absorbed a photo, and its trip")
    func discardRepairsSharedHost() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let shared = insertPing(context, at: at(0), source: .sharedImport)
        let trip = insertTrip(context, from: at(0), to: at(0), source: .sharedImport)
        let host = insertStay(context, from: at(0), to: at(0), pings: [shared],
                              source: .sharedImport, trip: trip)
        try context.save()
        let sharedID = shared.id
        let tripID = trip.id

        let recorder = PingRecorder(modelContainer: container)
        #expect(try await recorder.recordImportedPings([candidate(at(1), metersEast: 600)]) == 1)
        try await recorder.saveImportBatch()
        let absorbed = try #require(try stay(host.id, container))
        #expect(absorbed.pingCount == 2)
        #expect(absorbed.endTime == at(1))
        #expect(absorbed.source == .sharedImport)

        try await PhotoImportService(modelContainer: container).performDiscardTeardownForTesting()

        let repaired = try #require(try stay(host.id, container))
        #expect(repaired.pingIDs == [sharedID])
        #expect(repaired.pingCount == 1)
        #expect(repaired.endTime == at(0))
        #expect(repaired.centroidLongitude == Self.longitude)
        #expect(repaired.source == .sharedImport)
        let kept = try #require(try self.trip(tripID, container))
        #expect(kept.endDate == at(0))
    }

    // MARK: - PIMP-004

    /// A Visit-backed host is rebuilt against the stays the discard keeps:
    /// a photo-only successor it deletes no longer cuts the Visit short,
    /// while a surviving live successor still does.
    @Test("discard clamps a surviving Visit only at neighbours that survive", arguments: [false, true])
    func discardClampsAtSurvivingNeighbours(successorSurvives: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let live = insertPing(context, at: at(0.5), source: .liveSLC)
        let photo = insertPing(context, at: at(1), source: .photoImport)
        let host = insertStay(context, from: at(0), to: at(1), pings: [live, photo], source: .merged)
        context.insert(Visit(
            arrivalDate: at(0), departureDate: at(20),
            latitude: Self.latitude, longitude: Self.longitude, horizontalAccuracy: 20,
            receivedAt: at(20), stayID: host.id, isProcessed: true))
        if successorSurvives {
            let later = insertPing(context, at: at(10.5), metersEast: 5_000, source: .liveSLC)
            insertStay(context, from: at(10), to: at(11), pings: [later], source: .liveSLC, metersEast: 5_000)
        } else {
            let later = insertPing(context, at: at(10.5), metersEast: 5_000, source: .photoImport)
            insertStay(context, from: at(10), to: at(11), pings: [later], source: .photoImport, metersEast: 5_000)
        }
        try context.save()

        try await PhotoImportService(modelContainer: container).performDiscardTeardownForTesting()

        let rebuilt = try #require(try stay(host.id, container))
        #expect(rebuilt.startTime == at(0))
        #expect(rebuilt.endTime == (successorSurvives ? at(10).addingTimeInterval(-1) : at(20)))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Stay>()) == (successorSurvives ? 2 : 1))
    }

    // MARK: - PIMP-003

    @Test("without local evidence authority a contained map cell is kept, not deleted or shrunk")
    func hexRepairNeedsLocalAuthority() {
        // A synced row [15, 20] the import widened to [10, 25] looks import-born.
        let delete = PhotoImportService.hexVisitRepairAction(
            rowFirstVisited: at(10), rowLastVisited: at(25), importFirst: at(10), importLast: at(25),
            survivingFirst: nil, survivingLast: nil, localEvidenceIsComplete: false)
        #expect(delete == .keep)
        let shrink = PhotoImportService.hexVisitRepairAction(
            rowFirstVisited: at(10), rowLastVisited: at(25), importFirst: at(10), importLast: at(25),
            survivingFirst: at(17), survivingLast: at(18), localEvidenceIsComplete: false)
        #expect(shrink == .keep)
        // A local-only store keeps the containment rule.
        #expect(PhotoImportService.hexVisitRepairAction(
            rowFirstVisited: at(10), rowLastVisited: at(25), importFirst: at(10), importLast: at(25),
            survivingFirst: nil, survivingLast: nil, localEvidenceIsComplete: true) == .delete)
    }

    @Test("a photo discard in a synced store keeps the map cell its photos marked", arguments: [false, true])
    func discardKeepsCellInSyncedStore(synced: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        insertPing(context, at: at(0), source: .photoImport)
        let row = HexVisit(h3Index: cell(), firstVisited: at(0),
                           centerLatitude: Self.latitude, centerLongitude: Self.longitude)
        row.lastVisited = at(0)
        context.insert(row)
        try context.save()

        let service = PhotoImportService(modelContainer: container)
        try await PhotoImportService.HexAuthorityTestHook.$treatStoreAsSynced.withValue(synced) {
            try await service.performDiscardTeardownForTesting()
        }

        let cells = try ModelContext(container).fetch(FetchDescriptor<HexVisit>())
        #expect(cells.count == (synced ? 1 : 0))
        #expect(try pings(container).isEmpty)
    }

    // MARK: - SHARE-008

    /// Counts the home-ring reads of one shared import.
    @MainActor final class RingReads {
        var count = 0
    }

    func sharedEnvironment(
        _ container: ModelContainer, ledger: URL,
        homeRings: @escaping @MainActor @Sendable () async throws -> [TripClassifier.HomeRing]
    ) -> SharedTripImporter.Environment {
        SharedTripImporter.Environment(
            recorder: PingRecorder(modelContainer: container),
            store: SharedTripStore(modelContainer: container),
            homeRings: homeRings,
            gate: PipelineGate(forTesting: ()),
            stages: ExternalHistoryImporter.Stages(
                cluster: { true }, classify: { true }, generateTitles: {}, reloadWidgets: {}),
            ledgerDirectory: ledger,
            afterRemoval: { _, _ in })
    }

    func sharedTrip(at timestamps: [Date]) -> SharedTrip {
        SharedTrip(
            shareID: UUID(), startDate: timestamps[0], endDate: timestamps.last, isComplete: true,
            pings: timestamps.map {
                SharedPing(id: UUID(), timestamp: $0, latitude: Self.latitude,
                           longitude: Self.longitude, horizontalAccuracy: 20, sourceRaw: "liveSLC")
            })
    }

    /// A live fix that lands after the import's first read but before its
    /// recording unit still wins: the unit admits again and leaves the
    /// shared fix out.
    @Test("own evidence arriving after admission still keeps a shared fix out")
    func ownEvidenceArrivingAfterAdmissionWins() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ledger = FileManager.default.temporaryDirectory
            .appendingPathComponent("P03Ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ledger) }
        let reads = RingReads()
        let liveTime = Self.base.addingTimeInterval(600)
        let environment = sharedEnvironment(container, ledger: ledger) {
            reads.count += 1
            if reads.count == 2 {
                let context = ModelContext(container)
                context.insert(LocationPing(
                    timestamp: liveTime, latitude: Self.latitude, longitude: Self.longitude,
                    horizontalAccuracy: 20,
                    h3IndexRes6: H3Service.cellIndex(latitude: Self.latitude, longitude: Self.longitude) ?? "",
                    source: .liveSLC))
                try context.save()
            }
            return []
        }

        let outcome = try await SharedTripImporter.importTrip(
            sharedTrip(at: [at(0)]), senderName: nil, environment: environment)

        #expect(reads.count == 2)
        #expect(outcome.inserted == 0)
        #expect(outcome.droppedForOwnEvidence == 1)
        #expect(try pings(container).map(\.source) == [.liveSLC])
    }

    /// A Home added between the ring read and the unit moves the digest:
    /// the unit writes nothing and the rings are read again.
    @Test("a Home that changes before the unit makes it read the rings again")
    func homeChangeBeforeUnitRereadsRings() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ledger = FileManager.default.temporaryDirectory
            .appendingPathComponent("P03Ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ledger) }
        let reads = RingReads()
        let environment = sharedEnvironment(container, ledger: ledger) {
            reads.count += 1
            if reads.count == 2 {
                // After this read's digest, as a sync would land it.
                let context = ModelContext(container)
                context.insert(Home(label: "Far", latitude: -30.5, longitude: 150.5, radiusKm: 25,
                                    startedAt: Self.base.addingTimeInterval(-86_400)))
                try context.save()
            }
            return []
        }

        let outcome = try await SharedTripImporter.importTrip(
            sharedTrip(at: [at(0)]), senderName: nil, environment: environment)

        #expect(reads.count == 3)
        #expect(outcome.inserted == 1)
        #expect(!outcome.saveFailed)
    }

    // MARK: - SHARE-007

    /// `holder`: 0 the first row holds the shared stay unnamed, 1 it holds
    /// it under the user's own name, 2 both UUID twins hold shared stays.
    @Test("the sender's name goes only onto the one physical trip holding the shared stays",
          arguments: [0, 1, 2])
    func senderNameTargetsThePhysicalHolder(holder: Int) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let first = insertTrip(context, from: at(0), to: at(5))
        if holder == 1 { first.customName = "Our own name" }
        let twin = insertTrip(context, from: at(0), to: at(5))
        twin.id = first.id
        let shared = insertPing(context, at: at(1), source: .sharedImport)
        insertStay(context, from: at(1), to: at(2), pings: [shared], source: .sharedImport, trip: first)
        var ids: Set<UUID> = [shared.id]
        if holder == 2 {
            let other = insertPing(context, at: at(3), source: .sharedImport)
            insertStay(context, from: at(3), to: at(4), pings: [other], source: .sharedImport, trip: twin)
            ids.insert(other.id)
        }
        try context.save()
        let firstRow = first.persistentModelID
        let twinRow = twin.persistentModelID

        let result = try await SharedTripStore(modelContainer: container).carrySenderName(
            "Sender's trip", pingIDs: ids, previouslyApplied: nil, previousTripID: nil)

        let fresh = ModelContext(container)
        let names = Dictionary(uniqueKeysWithValues: try fresh.fetch(FetchDescriptor<Trip>())
            .map { ($0.persistentModelID, $0.customName) })
        switch holder {
        case 0:
            #expect(result.tripID == first.id && result.appliedName == "Sender's trip")
            #expect(names[firstRow] == "Sender's trip")
        case 1:
            #expect(result.tripID == nil && result.appliedName == nil)
            #expect(names[firstRow] == "Our own name")
        default:
            #expect(result.tripID == nil && result.appliedName == nil)
            #expect(names[firstRow] == .some(nil))
        }
        // The twin holding none of the shared stays is never written.
        #expect(names[twinRow] == .some(nil))
    }

    // MARK: - EXT-001

    /// `protection`: 0 none, 1 the user set the stay, 2 the user edited the trip.
    @Test("a historical stop grown by imported fixes is judged again unless the user owns it",
          arguments: [0, 1, 2])
    func grownStopIsReclassified(protection: Int) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = insertTrip(context, from: at(0), to: at(14))
        trip.userEdited = protection == 2
        let stop = insertStay(context, from: at(0), to: at(0).addingTimeInterval(300), pings: [],
                              source: .liveSLC, category: .transit, trip: trip, order: 0)
        stop.durationMinutes = 5
        stop.userOverridden = protection == 1
        let base = insertStay(context, from: at(10), to: at(14), pings: [], source: .liveSLC,
                              metersEast: 50_000, trip: trip, order: 1)
        base.durationMinutes = 240
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let fixes = (1...6).map { candidate(at(Double($0))) }
        #expect(try await recorder.recordImportedPings(fixes, source: .gpxImport) == 6)
        try await recorder.saveImportBatch()

        let grown = try #require(try stay(stop.id, container))
        #expect(grown.durationMinutes == 360)
        if protection == 0 {
            #expect(grown.category == .unclassified)
            #expect(grown.trip == nil)
        } else {
            #expect(grown.category == .transit)
            #expect(grown.trip?.id == trip.id)
        }
        #expect(try stay(base.id, container)?.trip?.id == trip.id)
    }

    /// The accepted limitation: a completed trip's only stop is not judged
    /// again when it grows. Reset, it would leave its trip empty with no pass
    /// to rebuild it, so the stop keeps its category and the trip, curated or
    /// not, keeps the stop, its id and its name.
    @Test("a completed trip's only stop grown by imported fixes keeps its category and its trip",
          arguments: [false, true])
    func grownSoleMemberKeepsItsTrip(named: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = insertTrip(context, from: at(0), to: at(0).addingTimeInterval(300))
        if named { trip.customName = "Harbour stop" }
        let stop = insertStay(context, from: at(0), to: at(0).addingTimeInterval(300), pings: [],
                              source: .liveSLC, category: .transit, trip: trip, order: 0)
        stop.durationMinutes = 5
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let fixes = (1...6).map { candidate(at(Double($0))) }
        #expect(try await recorder.recordImportedPings(fixes, source: .gpxImport) == 6)
        try await recorder.saveImportBatch()

        let grown = try #require(try stay(stop.id, container))
        #expect(grown.durationMinutes == 360)
        #expect(grown.category == .transit)
        #expect(grown.trip?.id == trip.id)
        let kept = try #require(try self.trip(trip.id, container))
        #expect((kept.stays ?? []).map(\.id) == [stop.id])
        #expect(kept.customName == (named ? "Harbour stop" : nil))
        #expect(kept.endDate == grown.endTime, "the trip widens to cover its grown stop")
    }

    @Test("fixes inside a stay's window leave its category and trip alone")
    func fixesInsideTheWindowKeepCategory() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = insertTrip(context, from: at(0), to: at(14))
        let host = insertStay(context, from: at(0), to: at(4), pings: [], source: .liveSLC,
                              category: .destination, trip: trip, order: 0)
        host.durationMinutes = 240
        insertStay(context, from: at(10), to: at(14), pings: [], source: .liveSLC,
                   metersEast: 50_000, trip: trip, order: 1)
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        #expect(try await recorder.recordImportedPings([candidate(at(2))], source: .timelineImport) == 1)
        try await recorder.saveImportBatch()

        let saved = try #require(try stay(host.id, container))
        #expect(saved.category == .destination)
        #expect(saved.trip?.id == trip.id)
    }

    // MARK: - SHARE-004

    /// Removing the shared half of a mixed stay moves it to its Timeline
    /// fix: its place names, zone, steps and legs go with the old place and
    /// window, the user's Not a Flight stays, and the automatic stay is
    /// judged again outside its trip.
    @Test("removing shared evidence clears what the moved stay no longer supports")
    func sharedRemovalClearsStaleDerivedFields() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = insertTrip(context, from: at(-10), to: at(6))
        let earlier = insertStay(context, from: at(-10), to: at(-8), pings: [], source: .liveSLC,
                                 metersEast: 40_000, trip: trip, order: 0)
        let shared = insertPing(context, at: at(0), metersEast: -20_000, source: .sharedImport)
        let timeline = insertPing(context, at: at(6), metersEast: 2_000, source: .timelineImport)
        let mixed = insertStay(context, from: at(0), to: at(6), pings: [shared, timeline],
                               source: .merged, metersEast: -10_000, trip: trip, order: 1)
        mixed.h3IndexRes6 = cell(metersEast: -20_000)
        mixed.durationMinutes = 360
        mixed.locality = "Old Harbour"
        mixed.country = "Italy"
        mixed.isoCountryCode = "IT"
        mixed.stepsWalked = 1_200
        mixed.timeZoneIdentifier = "GMT-0500"
        mixed.transitFromPreviousRaw = TransitMode.flight.rawValue
        mixed.distanceFromPreviousKm = 300
        let next = insertStay(context, from: at(10), to: at(12), pings: [], source: .liveSLC,
                              metersEast: 60_000)
        next.transitFromPreviousRaw = TransitMode.notFlight.rawValue
        next.distanceFromPreviousKm = 200
        try context.save()

        _ = try await SharedTripStore(modelContainer: container).removeSharedEvidence(
            pingIDs: [shared.id], appliedName: nil, namedTripID: nil)

        let moved = try #require(try stay(mixed.id, container))
        #expect(moved.pingIDs == [timeline.id])
        #expect(moved.source == .timelineImport)
        #expect(moved.locality == nil)
        #expect(moved.isoCountryCode == "IT")
        #expect(moved.stepsWalked == nil)
        #expect(moved.timeZoneIdentifier == StayTimeZone.identifier(
            for: .timelineImport, longitude: moved.centroidLongitude, isoCountryCode: "IT", at: at(6)))
        #expect(moved.transitFromPreviousRaw == nil && moved.distanceFromPreviousKm == nil)
        #expect(moved.category == .unclassified)
        #expect(moved.trip == nil)
        let kept = try #require(try stay(next.id, container))
        #expect(kept.transitFromPreviousRaw == TransitMode.notFlight.rawValue)
        #expect(kept.distanceFromPreviousKm == 200)
        #expect(try stay(earlier.id, container)?.trip?.id == trip.id)
    }

    // MARK: - EXT-003

    func gpx(root: String, prefix: String) -> Data {
        let p = prefix.isEmpty ? "" : prefix + ":"
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <\(p)gpx version="1.1" creator="Test" \(root)>
          <\(p)trk><\(p)trkseg>
            <\(p)trkpt lat="44.3" lon="12.9"><\(p)time>2026-01-02T03:04:05Z</\(p)time></\(p)trkpt>
          </\(p)trkseg></\(p)trk>
        </\(p)gpx>
        """.utf8)
    }

    @Test("GPX reads alike with a prefixed, a default or no namespace")
    func gpxNamespacesParse() throws {
        let gpx11 = "http://www.topografix.com/GPX/1/1"
        for (root, prefix) in [("xmlns:g=\"\(gpx11)\"", "g"), ("xmlns=\"\(gpx11)\"", ""), ("", "")] {
            let result = try GPXImportParser.parse(gpx(root: root, prefix: prefix))
            #expect(result.pings.count == 1)
            #expect(result.pings.first?.latitude == 44.3)
            #expect(result.trackCount == 1)
        }
    }

    @Test("a prefixed document of another namespace is not GPX")
    func foreignNamespaceIsNotGPX() {
        #expect(throws: GPXImportError.notGPX) {
            try GPXImportParser.parse(gpx(root: "xmlns:f=\"urn:example:other\"", prefix: "f"))
        }
    }

    // MARK: - LIMIT-001

    static let longVisits = """
    { "semanticSegments": [
      { "startTime": "2024-01-01T00:00:00Z", "endTime": "2024-01-13T00:00:00Z",
        "visit": { "topCandidate": { "placeLocation": { "latLng": "44.3°, 12.9°" } } } },
      { "startTime": "2024-02-01T00:00:00Z", "endTime": "2024-02-13T00:00:00Z",
        "visit": { "topCandidate": { "placeLocation": { "latLng": "44.3°, 12.9°" } } } }
    ] }
    """

    static let longPlaceVisits = """
    { "timelineObjects": [
      { "placeVisit": { "location": { "latitudeE7": 443000000, "longitudeE7": 129000000 },
          "duration": { "startTimestamp": "2024-01-01T00:00:00Z", "endTimestamp": "2024-01-13T00:00:00Z" } } },
      { "placeVisit": { "location": { "latitudeE7": 443000000, "longitudeE7": 129000000 },
          "duration": { "startTimestamp": "2024-02-01T00:00:00Z", "endTimestamp": "2024-02-13T00:00:00Z" } } }
    ] }
    """

    /// A twelve-day visit synthesizes 97 fixes from a few hundred bytes; the
    /// budget is checked before each visit is built, in both dialects.
    @Test("a Timeline file whose fixes pass the budget is refused before they are built",
          arguments: [false, true])
    func timelineBudgetRefusesBeforeSynthesis(legacy: Bool) throws {
        let json = legacy ? Self.longPlaceVisits : Self.longVisits
        let start = ISO8601DateFormatter().date(from: "2024-01-01T00:00:00Z")!
        let end = ISO8601DateFormatter().date(from: "2024-01-13T00:00:00Z")!
        let perVisit = TimelineImportParser.visitPingCount(start: start, end: end)
        #expect(perVisit == 97)
        let fits = try TimelineImportParser.parse(Data(json.utf8), maxPings: 2 * perVisit)
        #expect(fits.pings.count == 2 * perVisit)
        #expect(throws: TimelineImportError.tooLarge) {
            try TimelineImportParser.parse(Data(json.utf8), maxPings: 2 * perVisit - 1)
        }
    }

    // MARK: - EXT-002

    var quietStages: ExternalHistoryImporter.Stages {
        ExternalHistoryImporter.Stages(
            cluster: { true }, classify: { true }, generateTitles: {}, reloadWidgets: {})
    }

    func fix(_ timestamp: Date) -> TimelinePing {
        TimelinePing(timestamp: timestamp, latitude: Self.latitude, longitude: Self.longitude,
                     horizontalAccuracy: 20)
    }

    func visitCount(_ container: ModelContainer) throws -> Int? {
        let key = cell()
        return try ModelContext(container).fetch(FetchDescriptor<HexVisit>(
            predicate: #Predicate { $0.h3Index == key })).first?.visitCount
    }

    /// A file that starts in the cell the previous one ended in is a new
    /// visit there, as after a relaunch; a retried file whose first fixes
    /// are already stored continues the visit they began.
    @Test("each import file counts its own map-cell visits")
    func hexCursorFollowsOneFile() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)

        _ = await ExternalHistoryImporter.record(
            [fix(at(0))], source: .timelineImport, recorder: recorder, stages: quietStages)
        #expect(try visitCount(container) == 1)

        // The same file again with one more fix: its stored prefix still
        // places the run in the cell, so the new fix continues that visit.
        let retried = await ExternalHistoryImporter.record(
            [fix(at(0)), fix(at(2))], source: .timelineImport, recorder: recorder, stages: quietStages)
        #expect(retried.inserted == 1)
        #expect(try visitCount(container) == 1)

        // An independent file days later starts a new visit in the same cell.
        _ = await ExternalHistoryImporter.record(
            [fix(at(240))], source: .gpxImport, recorder: recorder, stages: quietStages)
        #expect(try visitCount(container) == 2)
    }

    // MARK: - COMPAT-001

    @Test("GPX text keeps only XML 1.0 characters, so a pasted noncharacter cannot break the file")
    func gpxTextIsXMLSafe() {
        let pasted = "Har\u{FFFE}bour\u{FFFF} \u{1}week\t🌊 \u{10FFFF}&"
        let escaped = TripShareGPX.escaped(pasted)
        #expect(escaped == "Harbour week\t🌊 \u{10FFFF}&amp;")
        let document = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><name>\(escaped)</name>"
        #expect(XMLParser(data: Data(document.utf8)).parse())
        #expect(!XMLParser(data: Data("<name>Har\u{FFFE}bour</name>".utf8)).parse())
    }

    // MARK: - SHARE-006

    /// The sender's GPX breaks this route at the hour-long gap; the file
    /// itself records no break, so the preview draws no line at all.
    @Test("the shared trip preview draws no line its file cannot vouch for")
    func sharedPreviewDrawsNoInventedRoute() {
        let trip = sharedTrip(at: [at(0), at(0).addingTimeInterval(60), at(5)])
        #expect(TripShareGPX.segments(of: trip, exclusions: TripShareExclusions()).count == 2)
        #expect(SharedTripRouteMap.routeLines(for: trip).isEmpty)
    }

    // MARK: - FU-1, FU-2

    func freshDefaults() -> UserDefaults {
        let suite = "P03RegressionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// A completed photo trip holding one photo fix, as one device's graph.
    @discardableResult
    func photoTrip(_ context: ModelContext, from start: Date, to end: Date,
                   fixAt time: Date, name: String? = nil) -> Trip {
        let trip = insertTrip(context, from: start, to: end, source: .photoImport)
        trip.customName = name
        trip.destinationSummary = "Harbour Town"
        trip.countryCodes = "IT"
        let ping = insertPing(context, at: time, source: .photoImport)
        insertStay(context, from: time, to: time, pings: [ping], source: .photoImport, trip: trip)
        return trip
    }

    /// Two duplicate graphs named differently would each carry a name onto
    /// the one counterpart; the sweep could take only one, stranding the
    /// other's choices. Both keep their graphs. One name carries at once,
    /// with its photo choices, in the save that empties its trip.
    @Test("duplicate trips with competing names keep their graphs; a single name carries as they empty",
          arguments: [false, true])
    func competingNamedLosersKeepTheirGraphs(competing: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let winner = photoTrip(context, from: at(0), to: at(4), fixAt: at(1))
        let first = photoTrip(context, from: at(0), to: at(4), fixAt: at(1).addingTimeInterval(20),
                              name: "Harbour week")
        let second = photoTrip(context, from: at(0), to: at(4), fixAt: at(1).addingTimeInterval(40),
                               name: competing ? "Island days" : nil)
        context.insert(HiddenPhoto(localIdentifier: "H1", tripID: first.id))
        context.insert(PinnedPhoto(localIdentifier: "P2", tripID: second.id))
        try context.save()
        let defaults = freshDefaults()

        await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true, defaults: defaults)

        let fresh = ModelContext(container)
        let hidden = try fresh.fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID)
        let pinned = try fresh.fetch(FetchDescriptor<PinnedPhoto>()).map(\.tripID)
        let stays = try fresh.fetch(FetchDescriptor<Stay>())
        if competing {
            #expect(stays.count == 3)
            #expect(try trip(winner.id, container)?.customName == nil)
            #expect(hidden == [first.id] && pinned == [second.id])
            #expect(TripDeduplicator.carriedWinners(defaults: defaults).isEmpty)
        } else {
            #expect(stays.count == 1)
            #expect(try trip(winner.id, container)?.customName == "Harbour week")
            #expect(hidden == [winner.id] && pinned == [winner.id])
            #expect(TripDeduplicator.carriedWinners(defaults: defaults)
                == [first.id: winner.id, second.id: winner.id])
        }
    }

    /// Two graphs of one journey whose dates differ by a second never match
    /// the identical-journey rule; the trip holding every fix that
    /// duplicates the other's proves it. The emptied trip's name moves at
    /// once, and the sweep removes the empty row through the logged carry.
    @Test("a duplicate trip a second off its counterpart is carried onto it and swept away")
    func nearDuplicateGraphConverges() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let winner = photoTrip(context, from: at(0), to: at(4), fixAt: at(1))
        let loser = photoTrip(context, from: at(0).addingTimeInterval(1), to: at(4),
                              fixAt: at(1).addingTimeInterval(20), name: "Harbour week")
        context.insert(HiddenPhoto(localIdentifier: "H1", tripID: loser.id))
        try context.save()
        let defaults = freshDefaults()

        await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true, defaults: defaults)
        #expect(try trip(winner.id, container)?.customName == "Harbour week")
        #expect(try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID) == [winner.id])
        #expect(try trip(loser.id, container)?.stays?.isEmpty == true)

        _ = await TripDeduplicator.deduplicateAll(modelContainer: container, now: at(1_000), defaults: defaults)
        let swept = await TripDeduplicator.deduplicateAll(
            modelContainer: container, now: at(1_030), defaults: defaults)
        #expect(swept.deleted == 1)
        #expect(try trip(loser.id, container) == nil)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Trip>()).map(\.id) == [winner.id])
    }
}
