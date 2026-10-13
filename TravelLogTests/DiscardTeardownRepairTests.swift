//
//  DiscardTeardownRepairTests.swift
//  TravelLogTests
//
//  Photo-discard teardown repairs.
//
//  Deleting import stays must detach them from their
//  trip. SwiftData applies the `.nullify` delete rule at
//  `processPendingChanges` time, and the only save in the teardown is the
//  last step, so date and emptiness repair could re-derive the
//  trip's boundaries from the very stays being discarded, silently no-opping
//  the fix it was written to be, and `recomputeSummary` folded their
//  localities back in. `applyHomeChangeCore`'s equivalent repair works
//  precisely because `resetStay` clears `stay.trip` first.
//
//  Discard must only rewrite `.merged` rows that
//  this import touched. `.merged` is not photo-specific: a Timeline or
//  GPX import attaching a ping to a `.liveSLC` stay produces the same source.
//  So an untouched stay was rewritten and downgraded to `.liveSLC`, making the
//  field lie about a stay the discard never touched.
//

import Foundation
import CoreLocation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct DiscardTeardownRepairTests {

    private static let base = Date(timeIntervalSinceReferenceDate: 744 * 86_400)
    private func d(_ days: Double) -> Date { Self.base.addingTimeInterval(days * 86_400) }

    private let athens = (lat: 37.9838, lon: 23.7275)

    @discardableResult
    private func makePing(
        in ctx: ModelContext,
        source: DataSource,
        at day: Double = 0,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) -> LocationPing {
        let ping = LocationPing(
            timestamp: d(day),
            latitude: latitude ?? athens.lat,
            longitude: longitude ?? athens.lon,
            horizontalAccuracy: 30, h3IndexRes6: "8a2a1072b59ffff", source: source
        )
        ping.isProcessed = true
        ctx.insert(ping)
        return ping
    }

    @discardableResult
    private func makeStay(
        in ctx: ModelContext, source: DataSource, startDay: Double,
        endDay: Double, pingIDs: [UUID],
        latitude: Double? = nil,
        longitude: Double? = nil
    ) -> Stay {
        let stay = Stay(
            startTime: d(startDay), endTime: d(endDay),
            centroidLatitude: latitude ?? athens.lat,
            centroidLongitude: longitude ?? athens.lon,
            h3IndexRes6: "8a2a1072b59ffff", pingCount: max(1, pingIDs.count),
            distanceFromHomeKm: 40, pingIDs: pingIDs
        )
        stay.source = source
        stay.category = .destination
        stay.locality = "Athens"
        ctx.insert(stay)
        return stay
    }

    @discardableResult
    private func makeVisit(
        in ctx: ModelContext,
        stayID: UUID,
        arrival: Date,
        departure: Date? = nil,
        receivedAt: Date? = nil,
        latitude: Double? = nil
    ) -> Visit {
        let visit = Visit(
            arrivalDate: arrival,
            departureDate: departure,
            latitude: latitude ?? athens.lat,
            longitude: athens.lon,
            horizontalAccuracy: 20,
            receivedAt: receivedAt ?? departure ?? arrival,
            stayID: stayID,
            isProcessed: true
        )
        ctx.insert(visit)
        return visit
    }

    private func refetchTrip(_ id: UUID, _ container: ModelContainer) throws -> Trip? {
        let predicate = #Predicate<Trip> { $0.id == id }
        return try ModelContext(container).fetch(FetchDescriptor<Trip>(predicate: predicate)).first
    }

    private func refetchStay(_ id: UUID, _ container: ModelContainer) throws -> Stay? {
        let predicate = #Predicate<Stay> { $0.id == id }
        return try ModelContext(container).fetch(FetchDescriptor<Stay>(predicate: predicate)).first
    }

    @discardableResult
    private func makeTrip(
        in ctx: ModelContext, source: DataSource, startDay: Double, endDay: Double?
    ) -> Trip {
        let trip = Trip(startDate: d(startDay), source: source)
        trip.endDate = endDay.map { d($0) }
        trip.isComplete = endDay != nil
        ctx.insert(trip)
        return trip
    }

    private func tripRows(_ id: UUID, _ container: ModelContainer) throws -> [Trip] {
        try ModelContext(container).fetch(FetchDescriptor<Trip>(
            predicate: #Predicate<Trip> { $0.id == id }))
    }

    // MARK: - C6-DISCARD-CENTROID

    @Test("discard neighbor index matches strict chronological neighbors with UUID twins")
    func indexedNeighborsMatchChronologicalBounds() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        var stays: [Stay] = []
        for index in 0..<60 {
            let stay = makeStay(in: context, source: .merged, startDay: Double(index),
                endDay: Double(index) + 0.25, pingIDs: [UUID()])
            // Three separated physical rows can share one logical ID; neither
            // direction may treat those rows as a different neighboring stay.
            if index >= 20, index < 40 { stay.id = stays[index - 20].id }
            stays.append(stay)
        }
        try context.save()
        let service = PhotoImportService(modelContainer: container)
        let bounds = try await service.discardNeighborBoundsForTesting()
        for stay in stays {
            let previous = stays.filter { $0.id != stay.id && $0.startTime < stay.startTime }
                .max { $0.startTime < $1.startTime }
            let next = stays.filter { $0.id != stay.id && $0.startTime > stay.startTime }
                .min { $0.startTime < $1.startTime }
            #expect(bounds.previousEnds[stay.persistentModelID] == previous?.endTime)
            #expect(bounds.nextStarts[stay.persistentModelID] == next?.startTime)
        }
    }

    @Test("discard cancellation leaves the complete transaction intact", arguments: [false, true])
    func cancellationRollsBackDiscard(beforeSave: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let ping = makePing(in: context, source: .photoImport)
        let stay = makeStay(in: context, source: .photoImport, startDay: 0, endDay: 1, pingIDs: [ping.id])
        // A trip owning the stay, with photo choices, so the rollback covers
        // the staged annotation cleanup too.
        let trip = makeTrip(in: context, source: .photoImport, startDay: 0, endDay: 1)
        stay.trip = trip
        context.insert(HiddenPhoto(localIdentifier: "H1", tripID: trip.id))
        context.insert(PinnedPhoto(localIdentifier: "P1", tripID: trip.id))
        try context.save()
        let service = PhotoImportService(modelContainer: container)
        let reloads = DiscardWidgetReloadCounter()
        let operation = Task {
            if !beforeSave { withUnsafeCurrentTask { $0?.cancel() } }
            return await PhotoImportService.$cancelBeforeDiscardSaveForTesting.withValue(beforeSave) {
                do {
                    try await service.performDiscardTeardownForTesting { await reloads.record() }
                    return false
                } catch { return true }
            }
        }
        #expect(await operation.value)
        #expect(await reloads.count == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Stay>()) == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Trip>()) == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<HiddenPhoto>()) == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PinnedPhoto>()) == 1)
    }

    @Test("successful discard removes its local checkpoint journal")
    func discardClearsCheckpointJournal() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let state = PhotoImportState(originDeviceID: "test-device")
        state.status = .paused
        context.insert(state)
        try context.save()
        try PhotoImportCheckpointJournal.seed(PhotoImportStateSnapshot(from: state), in: container)
        let service = PhotoImportService(modelContainer: container)
        try await service.performDiscardTeardownForTesting()
        #expect(try PhotoImportCheckpointJournal.read(in: container) == nil)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PhotoImportState>()) == 0)
    }

    /// Seeds a photo-import trip with one hidden and one pinned photo, demotes
    /// it ("This Wasn't a Trip") into `dir`'s queue, and returns its record.
    private func demoteAnnotatedPhotoTrip(
        in container: ModelContainer, queue dir: URL
    ) async throws -> DissolvedTripRecord {
        let ctx = ModelContext(container)
        let ping = makePing(in: ctx, source: .photoImport)
        let stay = makeStay(
            in: ctx, source: .photoImport, startDay: 0, endDay: 1, pingIDs: [ping.id])
        let trip = Trip(startDate: d(0), source: .photoImport)
        trip.endDate = d(1)
        trip.isComplete = true
        ctx.insert(trip)
        stay.trip = trip
        ctx.insert(HiddenPhoto(localIdentifier: "H1", tripID: trip.id))
        ctx.insert(PinnedPhoto(localIdentifier: "P1", tripID: trip.id))
        try ctx.save()
        let tripID = trip.id

        let classifier = TripClassifier(modelContainer: container)
        await classifier.setDissolvedRecordSink { try DissolvedTripQueue.append($0, in: dir) }
        #expect(await classifier.demoteSeededTrip(tripID).isDemoted)
        let record = try #require(DissolvedTripQueue.load(from: dir).first { $0.id == tripID })
        #expect(record.sourceRaw == DataSource.photoImport.rawValue)
        #expect(Set((record.photoAnnotations ?? []).map(\.localIdentifier)) == ["H1", "P1"])
        return record
    }

    private func mergedControlRecord() -> DissolvedTripRecord {
        DissolvedTripRecord(
            id: UUID(), dissolvedAt: d(-1), displayName: "Control",
            startDate: d(-3), endDate: d(-2),
            isComplete: true, destinationSummary: "Athens", countryCodes: "GR",
            classifiedByAI: false, aiGeneratedTitle: nil,
            aiGeneratedSummary: nil, summarySourceRaw: nil,
            sourceRaw: DataSource.merged.rawValue,
            customName: nil, userEdited: false,
            stays: [.init(id: UUID(), categoryRaw: "destination", orderInTrip: 0)])
    }

    @Test("deleting imported data after demoting a photo-import trip drops its recovery record and photo identifiers")
    func discardDropsDemotedPhotoTripRecoveryRecord() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("discard-demoted-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = try await demoteAnnotatedPhotoTrip(in: container, queue: dir)
        let control = mergedControlRecord()
        try DissolvedTripQueue.append([control], in: dir)

        let service = PhotoImportService(modelContainer: container)
        try await service.performDiscardTeardownForTesting(dissolvedQueueDirectory: dir)

        let queued = DissolvedTripQueue.load(from: dir)
        #expect(!queued.contains { $0.id == record.id })
        let queuedPhotoIDs = queued.flatMap { $0.photoAnnotations ?? [] }.map(\.localIdentifier)
        #expect(!queuedPhotoIDs.contains("H1"))
        #expect(!queuedPhotoIDs.contains("P1"))
        #expect(queued == [control])
        let tripID = record.id
        let ctx = ModelContext(container)
        #expect(try ctx.fetchCount(FetchDescriptor<HiddenPhoto>(
            predicate: #Predicate { $0.tripID == tripID })) == 0)
        #expect(try ctx.fetchCount(FetchDescriptor<PinnedPhoto>(
            predicate: #Predicate { $0.tripID == tripID })) == 0)

        // The stays it pointed at are gone, so a restore could never succeed.
        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .staysMissing)
        #expect(try refetchTrip(tripID, container) == nil)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<HiddenPhoto>()) == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PinnedPhoto>()) == 0)
    }

    @Test("a rolled-back discard keeps the demoted photo trip's recovery record")
    func rolledBackDiscardKeepsDemotedPhotoTripRecoveryRecord() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("discard-rollback-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = try await demoteAnnotatedPhotoTrip(in: container, queue: dir)

        let service = PhotoImportService(modelContainer: container)
        let operation = Task {
            await PhotoImportService.$cancelBeforeDiscardSaveForTesting.withValue(true) {
                do {
                    try await service.performDiscardTeardownForTesting(
                        dissolvedQueueDirectory: dir)
                    return false
                } catch { return true }
            }
        }
        #expect(await operation.value)
        let kept = try #require(DissolvedTripQueue.load(from: dir).first { $0.id == record.id })
        #expect(kept.photoAnnotations == record.photoAnnotations)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Stay>()) == 1)
    }

    private func photoIdentifiers(
        of tripID: UUID, _ container: ModelContainer
    ) throws -> (hidden: [String], pinned: [String]) {
        let ctx = ModelContext(container)
        let hidden = try ctx.fetch(FetchDescriptor<HiddenPhoto>(
            predicate: #Predicate { $0.tripID == tripID })).map(\.localIdentifier)
        let pinned = try ctx.fetch(FetchDescriptor<PinnedPhoto>(
            predicate: #Predicate { $0.tripID == tripID })).map(\.localIdentifier)
        return (hidden, pinned)
    }

    @Test("a demoted photo trip whose stay a live Visit merged keeps its recovery record and photo choices through the discard")
    func discardKeepsRecordOfVisitMergedDemotedPhotoStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("discard-merged-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = try await demoteAnnotatedPhotoTrip(in: container, queue: dir)
        let stayID = try #require(record.stays.first?.id)

        // A delayed live Visit lands on the demoted photo stay.
        let ctx = ModelContext(container)
        ctx.insert(Visit(
            arrivalDate: d(0.25), departureDate: d(0.5),
            latitude: athens.lat, longitude: athens.lon,
            horizontalAccuracy: 20, receivedAt: d(0.5)))
        try ctx.save()
        _ = await StayClusterer(modelContainer: container).clusterUnprocessedPings()
        #expect(try refetchStay(stayID, container)?.source == .merged)

        // An unrelated imported stay, so the discard deletes a stay.
        let otherPing = makePing(in: ctx, source: .photoImport, at: 5)
        let other = makeStay(
            in: ctx, source: .photoImport, startDay: 5, endDay: 6, pingIDs: [otherPing.id])
        let otherID = other.id
        try ctx.save()

        let service = PhotoImportService(modelContainer: container)
        try await service.performDiscardTeardownForTesting(dissolvedQueueDirectory: dir)

        #expect(try refetchStay(otherID, container) == nil)
        #expect(try refetchStay(stayID, container) != nil)
        #expect(DissolvedTripQueue.load(from: dir) == [record])

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .restored)
        #expect(try refetchTrip(record.id, container)?.stays?.map(\.id) == [stayID])
        let photos = try photoIdentifiers(of: record.id, container)
        #expect(photos.hidden == ["H1"])
        #expect(photos.pinned == ["P1"])
    }

    @Test("a demoted photo trip that came back holding other stays keeps its recovery record through the discard")
    func discardKeepsRecordOfReturnedDemotedPhotoTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("discard-returned-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = try await demoteAnnotatedPhotoTrip(in: container, queue: dir)
        let stayID = try #require(record.stays.first?.id)

        // The trip comes back (a sync or an import) holding a live stay.
        let ctx = ModelContext(container)
        let livePing = makePing(in: ctx, source: .liveSLC, at: 3)
        let liveStay = makeStay(
            in: ctx, source: .liveSLC, startDay: 3, endDay: 4, pingIDs: [livePing.id])
        let returned = Trip(startDate: d(3), source: .liveSLC)
        returned.id = record.id
        returned.endDate = d(4)
        returned.isComplete = true
        ctx.insert(returned)
        liveStay.trip = returned
        try ctx.save()

        let service = PhotoImportService(modelContainer: container)
        try await service.performDiscardTeardownForTesting(dissolvedQueueDirectory: dir)

        #expect(try refetchStay(stayID, container) == nil)
        #expect(DissolvedTripQueue.load(from: dir) == [record])

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .alreadyExists)
        let photos = try photoIdentifiers(of: record.id, container)
        #expect(photos.hidden == ["H1"])
        #expect(photos.pinned == ["P1"])
    }

    @Test("a surviving UUID twin of a demoted photo stay keeps its recovery record through the discard")
    func discardKeepsRecordWhenStayTwinSurvives() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("discard-twin-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = try await demoteAnnotatedPhotoTrip(in: container, queue: dir)
        let stayID = try #require(record.stays.first?.id)
        let photoPingIDs = try #require(try refetchStay(stayID, container)).pingIDs

        // Another device's copy of the stay merged a live Visit.
        let ctx = ModelContext(container)
        let twin = makeStay(
            in: ctx, source: .merged, startDay: 0, endDay: 1, pingIDs: photoPingIDs)
        twin.id = stayID
        makeVisit(in: ctx, stayID: stayID, arrival: d(0.25), departure: d(0.5))
        try ctx.save()

        let service = PhotoImportService(modelContainer: container)
        try await service.performDiscardTeardownForTesting(dissolvedQueueDirectory: dir)

        let rows = try ModelContext(container).fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == stayID }))
        #expect(rows.count == 1)
        #expect(rows.first?.source == .liveSLC)
        #expect(DissolvedTripQueue.load(from: dir) == [record])

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.restoreDissolvedTrip(
            record, markStaysSacred: true) == .restored)
    }

    @Test("discard refuses a fresh running session owned by another device")
    func discardRefusesFreshForeignRunningSession() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let state = PhotoImportState(originDeviceID: "other-device")
        state.status = .running
        state.lastUpdated = Date.now.addingTimeInterval(-70)
        context.insert(state)
        makePing(in: context, source: .photoImport)
        try context.save()
        let service = PhotoImportService(modelContainer: container)
        do {
            try await service.discard()
            Issue.record("A fresh foreign running session must not be discarded")
        } catch PhotoImportError.alreadyRunning {} catch {
            Issue.record("Unexpected discard error: \(error)")
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PhotoImportState>()) == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 1)

        state.lastUpdated = Date.now.addingTimeInterval(-PhotoImportService.foreignSessionTakeoverSeconds - 1)
        try context.save()
        try await service.discard()
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PhotoImportState>()) == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 0)
    }

    @Test("journal cleanup failure reports committed deletion and permits a cleanup retry")
    func discardJournalCleanupFailureCanRetry() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let state = PhotoImportState(originDeviceID: "test-device")
        state.status = .paused
        context.insert(state)
        makePing(in: context, source: .photoImport)
        try context.save()
        try PhotoImportCheckpointJournal.seed(PhotoImportStateSnapshot(from: state), in: container)
        let service = PhotoImportService(modelContainer: container)
        let reloads = DiscardWidgetReloadCounter()
        await PhotoImportCheckpointJournal.$failClearForTesting.withValue(true) {
            do {
                try await service.performDiscardTeardownForTesting {
                    await reloads.record()
                }
                Issue.record("Cleanup failure must remain visible")
            } catch PhotoImportError.persistenceFailure {} catch {
                Issue.record("Unexpected cleanup error: \(error)")
            }
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PhotoImportState>()) == 0)
        #expect(try PhotoImportCheckpointJournal.read(in: container) != nil)
        // The thrown cleanup error is delivered only after the injected reload.
        #expect(await reloads.count == 1)
        try await service.performDiscardTeardownForTesting()
        #expect(try PhotoImportCheckpointJournal.read(in: container) == nil)
    }

    @Test("a queue cleanup failure after a committed discard is not reported and keeps the queue bytes")
    func discardQueueCleanupFailureIsNotReportedAfterCommit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("discard-unreadable-queue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queueURL = try #require(DissolvedTripQueue.fileURL(in: dir))
        let originalBytes = Data("not valid queue JSON".utf8)
        try originalBytes.write(to: queueURL)
        let ctx = ModelContext(container)
        let ping = makePing(in: ctx, source: .photoImport)
        let stayID = makeStay(
            in: ctx, source: .photoImport, startDay: 0, endDay: 1, pingIDs: [ping.id]).id
        try ctx.save()

        // The deletion commits; the cleanup's unreadable queue is logged,
        // not thrown, so the caller reconciles the committed deletion.
        let service = PhotoImportService(modelContainer: container)
        let reloads = DiscardWidgetReloadCounter()
        try await service.performDiscardTeardownForTesting(dissolvedQueueDirectory: dir) {
            await reloads.record()
        }

        #expect(try refetchStay(stayID, container) == nil)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 0)
        #expect(await reloads.count == 1)
        #expect(try Data(contentsOf: queueURL) == originalBytes)
    }

    @Test("discard rebuilds every host-derived field from surviving pings")
    func touchedHostGeometryIsReconstructed() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        // ATH is at roughly 37.9364, 23.9445. The two live pings are just
        // outside the detector's 3 km radius; the photo ping is close enough
        // both to attach to their host and to pull the three-ping centroid
        // inside the airport radius.
        let liveA = makePing(
            in: ctx, source: .liveSLC, at: 10,
            latitude: 37.9504, longitude: 23.9147
        )
        let liveB = makePing(
            in: ctx, source: .liveSLC, at: 12,
            latitude: 37.9506, longitude: 23.9147
        )
        let photo = makePing(
            in: ctx, source: .photoImport, at: 8,
            latitude: 37.9304, longitude: 23.9147
        )

        let importedCentroidLatitude = (liveA.latitude + liveB.latitude + photo.latitude) / 3
        let stay = makeStay(
            in: ctx, source: .merged, startDay: 8, endDay: 12,
            pingIDs: [liveA.id, liveB.id, photo.id],
            latitude: importedCentroidLatitude,
            longitude: 23.9147
        )
        stay.isAirport = true
        stay.h3IndexRes6 = "stale-photo-cell"
        stay.category = .routine
        stay.userOverridden = true
        stay.distanceFromHomeKm = 123.45
        let stayID = stay.id
        try ctx.save()

        let expectedLatitude = (liveA.latitude + liveB.latitude) / 2
        let expectedH3 = try #require(
            H3Service.cellIndex(latitude: expectedLatitude, longitude: 23.9147)
        )
        #expect(!AirportDetector.shared.isNearAirport(
            .init(latitude: expectedLatitude, longitude: 23.9147)
        ))

        let service = PhotoImportService(modelContainer: container)
        try await service.performDiscardTeardownForTesting()

        let repaired = try #require(try refetchStay(stayID, container))
        #expect(repaired.pingIDs == [liveA.id, liveB.id])
        #expect(repaired.pingCount == 2)
        #expect(repaired.startTime == d(10))
        #expect(repaired.endTime == d(12))
        #expect(repaired.durationMinutes == 2 * 24 * 60)
        #expect(abs(repaired.centroidLatitude - expectedLatitude) < 1e-12)
        #expect(abs(repaired.centroidLongitude - 23.9147) < 1e-12)
        #expect(repaired.h3IndexRes6 == expectedH3)
        #expect(!repaired.isAirport)
        #expect(repaired.source == .liveSLC)

        // These are not geometric derivatives. Discard must not erase the
        // user's classification or reinterpret historical home distance.
        #expect(repaired.category == .routine)
        #expect(repaired.userOverridden)
        #expect(repaired.distanceFromHomeKm == 123.45)
    }

    @Test("ping-only host repair preserves canonical and localized titles")
    func pingOnlyHostRepairPreservesTitles() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let liveA = makePing(in: ctx, source: .liveSLC, at: 10)
        let photo = makePing(in: ctx, source: .photoImport, at: 11)
        let liveB = makePing(in: ctx, source: .liveSLC, at: 12)
        let stay = makeStay(
            in: ctx,
            source: .merged,
            startDay: 10,
            endDay: 12,
            pingIDs: [liveA.id, photo.id, liveB.id])
        let trip = Trip(startDate: d(10))
        trip.isComplete = true
        trip.endDate = d(12)
        trip.aiGeneratedTitle = "Athens"
        ctx.insert(trip)
        stay.trip = trip
        stay.orderInTrip = 0
        ctx.insert(TripTitleVariant(
            languageTag: "de",
            title: "Athen",
            sourceTitle: "Athens",
            trip: trip))
        let tripID = trip.id
        try ctx.save()

        let service = PhotoImportService(modelContainer: container)
        try await service.performDiscardTeardownForTesting()

        let saved = try #require(try refetchTrip(tripID, container))
        #expect(saved.aiGeneratedTitle == "Athens")
        #expect(saved.localizedTitles?.first?.title == "Athen")
        #expect(saved.orderedStays.first?.pingCount == 2)
    }

    @Test("one surviving ping restores both imported time edges")
    func singleSurvivorRestoresBothTimeEdges() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let live = makePing(
            in: ctx, source: .liveSLC, at: 10,
            latitude: 40.6911, longitude: -73.9231
        )
        let earlyPhoto = makePing(
            in: ctx, source: .photoImport, at: 8,
            latitude: 40.6913, longitude: -73.9231
        )
        let latePhoto = makePing(
            in: ctx, source: .photoImport, at: 12,
            latitude: 40.6915, longitude: -73.9231
        )
        let stay = makeStay(
            in: ctx, source: .merged, startDay: 8, endDay: 12,
            pingIDs: [live.id, earlyPhoto.id, latePhoto.id],
            latitude: (live.latitude + earlyPhoto.latitude + latePhoto.latitude) / 3,
            longitude: (live.longitude + earlyPhoto.longitude + latePhoto.longitude) / 3
        )
        let stayID = stay.id
        try ctx.save()

        let service = PhotoImportService(modelContainer: container)
        try await service.performDiscardTeardownForTesting()

        let repaired = try #require(try refetchStay(stayID, container))
        #expect(repaired.pingIDs == [live.id])
        #expect(repaired.pingCount == 1)
        #expect(repaired.startTime == d(10))
        #expect(repaired.endTime == d(10))
        #expect(repaired.durationMinutes == 0)
        #expect(repaired.centroidLatitude == live.latitude)
        #expect(repaired.centroidLongitude == live.longitude)
        #expect(repaired.h3IndexRes6 == H3Service.cellIndex(
            latitude: live.latitude, longitude: live.longitude
        ))
    }

    @Test("external-import hosts rebuild geometry without losing provenance")
    func externalHostGeometryIsReconstructed() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let jsonA = makePing(
            in: ctx, source: .jsonImport, at: 10,
            latitude: 35.0, longitude: 25.0
        )
        let jsonB = makePing(
            in: ctx, source: .jsonImport, at: 11,
            latitude: 35.2, longitude: 25.2
        )
        let photo = makePing(
            in: ctx, source: .photoImport, at: 8,
            latitude: 35.4, longitude: 25.4
        )
        let stay = makeStay(
            in: ctx, source: .jsonImport, startDay: 8, endDay: 11,
            pingIDs: [jsonA.id, jsonB.id, photo.id],
            latitude: 35.2, longitude: 25.2
        )
        let stayID = stay.id
        try ctx.save()

        let service = PhotoImportService(modelContainer: container)
        try await service.performDiscardTeardownForTesting()

        let repaired = try #require(try refetchStay(stayID, container))
        #expect(repaired.source == .jsonImport)
        #expect(repaired.pingIDs == [jsonA.id, jsonB.id])
        #expect(repaired.startTime == d(10))
        #expect(repaired.endTime == d(11))
        #expect(repaired.durationMinutes == 24 * 60)
        #expect(abs(repaired.centroidLatitude - 35.1) < 1e-12)
        #expect(abs(repaired.centroidLongitude - 25.1) < 1e-12)
    }

    // MARK: - Discarded stay relationships

    /// A completed live-SLC trip that a
    /// photo import extended backwards. Discarding must shrink it back.
    @Test("a surviving trip's start shrinks to its first NON-discarded stay")
    func tripStartShrinksAfterDiscard() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let importPing = makePing(in: ctx, source: .photoImport, at: 8)
        let livePing = makePing(in: ctx, source: .liveSLC, at: 10)

        let imported = makeStay(in: ctx, source: .photoImport, startDay: 8, endDay: 8.5,
                                pingIDs: [importPing.id])
        let live = makeStay(in: ctx, source: .liveSLC, startDay: 10, endDay: 14,
                            pingIDs: [livePing.id])

        let trip = Trip(startDate: d(8))
        trip.isComplete = true
        trip.endDate = d(14)
        ctx.insert(trip)
        imported.trip = trip; imported.orderInTrip = 0
        live.trip = trip; live.orderInTrip = 1
        // Simulate CloudKit's variant-first arrival. The discard repair must
        // invalidate derivatives even though the canonical row is currently nil.
        ctx.insert(TripTitleVariant(
            languageTag: "de",
            title: "Lixoúri und Athen",
            sourceTitle: "Lixoúri & Athens",
            trip: trip))
        let tripID = trip.id
        try ctx.save()

        let service = PhotoImportService(modelContainer: container)
        try await service.performDiscardTeardownForTesting()

        let reloaded = try #require(try refetchTrip(tripID, container))
        #expect(reloaded.startDate == d(10))
        #expect(reloaded.endDate == d(14))
        #expect((reloaded.localizedTitles ?? []).isEmpty)
    }

    /// The empty-trip branch: a non-import trip left with nothing but
    /// discarded stays is a ghost; completed trips are never rebuilt by
    /// assembly, so it must be deleted rather than left behind.
    @Test("a surviving trip left with no stays is deleted")
    func emptiedTripIsDeleted() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let importPing = makePing(in: ctx, source: .photoImport, at: 8)
        let imported = makeStay(in: ctx, source: .photoImport, startDay: 8, endDay: 8.5,
                                pingIDs: [importPing.id])

        // Deliberately a live-SLC-sourced trip so step 5 does not delete it.
        let trip = Trip(startDate: d(8))
        trip.isComplete = true
        trip.endDate = d(8.5)
        ctx.insert(trip)
        imported.trip = trip; imported.orderInTrip = 0
        ctx.insert(HiddenPhoto(localIdentifier: "H1", tripID: trip.id))
        ctx.insert(PinnedPhoto(localIdentifier: "P1", tripID: trip.id))
        try ctx.save()

        let service = PhotoImportService(modelContainer: container)
        try await service.performDiscardTeardownForTesting()

        // Its photo choices go in the same save. No orphan sweep runs, and
        // one could not help: it skips a store with zero trips.
        let fresh = ModelContext(container)
        #expect(try fresh.fetchCount(FetchDescriptor<Trip>()) == 0)
        #expect(try fresh.fetchCount(FetchDescriptor<HiddenPhoto>()) == 0)
        #expect(try fresh.fetchCount(FetchDescriptor<PinnedPhoto>()) == 0)
    }

    @Test("an emptied trip's populated UUID twin keeps the shared photo choices")
    func emptiedTripWithPopulatedTwinKeepsAnnotations() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let importPing = makePing(in: ctx, source: .photoImport, at: 8)
        let livePing = makePing(in: ctx, source: .liveSLC, at: 10)
        let imported = makeStay(in: ctx, source: .photoImport, startDay: 8, endDay: 8.5,
                                pingIDs: [importPing.id])
        let live = makeStay(in: ctx, source: .liveSLC, startDay: 10, endDay: 14,
                            pingIDs: [livePing.id])
        // A stale live-sourced row the discard empties, and another device's
        // copy of the same trip holding a live stay.
        let emptied = makeTrip(in: ctx, source: .liveSLC, startDay: 8, endDay: 8.5)
        imported.trip = emptied
        let twin = makeTrip(in: ctx, source: .liveSLC, startDay: 10, endDay: 14)
        twin.id = emptied.id
        live.trip = twin
        let tripID = emptied.id
        ctx.insert(HiddenPhoto(localIdentifier: "H1", tripID: tripID))
        ctx.insert(PinnedPhoto(localIdentifier: "P1", tripID: tripID))
        try ctx.save()
        let twinRow = twin.persistentModelID

        try await PhotoImportService(modelContainer: container).performDiscardTeardownForTesting()

        #expect(try tripRows(tripID, container).map(\.persistentModelID) == [twinRow])
        let photos = try photoIdentifiers(of: tripID, container)
        #expect(photos.hidden == ["H1"])
        #expect(photos.pinned == ["P1"])
    }

    /// The summary must stop naming the discarded stay's place. This is the
    /// half that only works because the stay is detached before the repair;
    /// `recomputeSummary` reads the relationship array too.
    @Test("a repaired trip's summary no longer names the discarded stay")
    func summaryDropsDiscardedPlace() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let importPing = makePing(in: ctx, source: .photoImport, at: 8)
        let livePing = makePing(in: ctx, source: .liveSLC, at: 10)

        let imported = makeStay(in: ctx, source: .photoImport, startDay: 8, endDay: 8.5,
                                pingIDs: [importPing.id])
        imported.locality = "Lixoúri"
        imported.isoCountryCode = "GR"
        let live = makeStay(in: ctx, source: .liveSLC, startDay: 10, endDay: 14,
                            pingIDs: [livePing.id])
        live.locality = "Athens"
        live.isoCountryCode = "GR"

        let trip = Trip(startDate: d(8))
        trip.isComplete = true
        trip.endDate = d(14)
        ctx.insert(trip)
        imported.trip = trip; imported.orderInTrip = 0
        live.trip = trip; live.orderInTrip = 1
        let tripID = trip.id
        try ctx.save()

        let service = PhotoImportService(modelContainer: container)
        try await service.performDiscardTeardownForTesting()

        let reloaded = try #require(try refetchTrip(tripID, container))
        #expect(!reloaded.destinationSummary.contains("Lixoúri"))
    }

    // MARK: - UUID twins and photo choices

    /// Two photo-import copies of one trip and another device's copy that
    /// also holds a live stay. The discard deletes the photo copies by
    /// physical row, repairs the surviving copy from its live stay, and keeps
    /// the photo choices every copy shares.
    @Test("discard keeps a populated UUID twin's photo choices and repairs that twin",
          arguments: [false, true], [false, true])
    func discardKeepsPopulatedTwinAnnotations(survivorFirst: Bool, survivorOpen: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let sharedID = UUID()

        func insertImportCopy(_ day: Double) {
            let ping = makePing(in: ctx, source: .photoImport, at: day)
            let stay = makeStay(in: ctx, source: .photoImport, startDay: day, endDay: day + 0.5,
                                pingIDs: [ping.id])
            stay.locality = "Lixoúri"
            let trip = makeTrip(in: ctx, source: .photoImport, startDay: day, endDay: day + 0.5)
            trip.id = sharedID
            stay.trip = trip
        }
        func insertSurvivor() -> Trip {
            let photoPing = makePing(in: ctx, source: .photoImport, at: 8)
            let livePing = makePing(in: ctx, source: .liveSLC, at: 10)
            let photoStay = makeStay(in: ctx, source: .photoImport, startDay: 8, endDay: 8.5,
                                     pingIDs: [photoPing.id])
            photoStay.locality = "Lixoúri"
            let liveStay = makeStay(in: ctx, source: .liveSLC, startDay: 10, endDay: 14,
                                    pingIDs: [livePing.id])
            let trip = makeTrip(in: ctx, source: .merged, startDay: 8,
                                endDay: survivorOpen ? nil : 14)
            trip.id = sharedID
            trip.destinationSummary = "Lixoúri, Athens"
            photoStay.trip = trip; photoStay.orderInTrip = 0
            liveStay.trip = trip; liveStay.orderInTrip = 1
            ctx.insert(TripTitleVariant(
                languageTag: "de", title: "Lixoúri und Athen",
                sourceTitle: "Lixoúri & Athens", trip: trip))
            return trip
        }

        var survivor: Trip?
        if survivorFirst { survivor = insertSurvivor() }
        insertImportCopy(2)
        insertImportCopy(4)
        if !survivorFirst { survivor = insertSurvivor() }
        ctx.insert(HiddenPhoto(localIdentifier: "H1", tripID: sharedID))
        ctx.insert(PinnedPhoto(localIdentifier: "P1", tripID: sharedID))
        try ctx.save()
        let survivorRow = try #require(survivor).persistentModelID

        try await PhotoImportService(modelContainer: container).performDiscardTeardownForTesting()

        let rows = try tripRows(sharedID, container)
        #expect(rows.map(\.persistentModelID) == [survivorRow])
        let repaired = try #require(rows.first)
        #expect(repaired.startDate == d(10))
        #expect(repaired.endDate == (survivorOpen ? nil : d(14)))
        #expect(repaired.source == .liveSLC)
        #expect(!repaired.destinationSummary.contains("Lixoúri"))
        #expect((repaired.localizedTitles ?? []).isEmpty)
        let photos = try photoIdentifiers(of: sharedID, container)
        #expect(photos.hidden == ["H1"])
        #expect(photos.pinned == ["P1"])
    }

    /// A stale non-photo copy whose only stays were imported is emptied and
    /// deleted by the repair tail, the photo copy by step 5: no row with the
    /// UUID survives, so its photo choices go, once, in the same save.
    @Test("discard removes the photo choices when every UUID twin is deleted")
    func discardRemovesAnnotationsWhenNoTwinSurvives() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let importCopy = makeTrip(in: ctx, source: .photoImport, startDay: 2, endDay: 3)
        let firstPing = makePing(in: ctx, source: .photoImport, at: 2)
        let firstStay = makeStay(in: ctx, source: .photoImport, startDay: 2, endDay: 3,
                                 pingIDs: [firstPing.id])
        firstStay.trip = importCopy
        let stale = makeTrip(in: ctx, source: .liveSLC, startDay: 2, endDay: 3)
        stale.id = importCopy.id
        let secondPing = makePing(in: ctx, source: .photoImport, at: 2.5)
        let secondStay = makeStay(in: ctx, source: .photoImport, startDay: 2.5, endDay: 3,
                                  pingIDs: [secondPing.id])
        secondStay.trip = stale
        // An unrelated live trip keeps the store non-empty.
        let livePing = makePing(in: ctx, source: .liveSLC, at: 20)
        let other = makeTrip(in: ctx, source: .liveSLC, startDay: 20, endDay: 21)
        let otherStay = makeStay(in: ctx, source: .liveSLC, startDay: 20, endDay: 21,
                                 pingIDs: [livePing.id])
        otherStay.trip = other
        let tripID = importCopy.id
        let otherID = other.id
        ctx.insert(HiddenPhoto(localIdentifier: "H1", tripID: tripID))
        ctx.insert(PinnedPhoto(localIdentifier: "P1", tripID: tripID))
        ctx.insert(HiddenPhoto(localIdentifier: "H2", tripID: otherID))
        try ctx.save()

        try await PhotoImportService(modelContainer: container).performDiscardTeardownForTesting()

        #expect(try tripRows(tripID, container).isEmpty)
        let photos = try photoIdentifiers(of: tripID, container)
        #expect(photos.hidden.isEmpty)
        #expect(photos.pinned.isEmpty)
        #expect(try photoIdentifiers(of: otherID, container).hidden == ["H2"])
    }

    @Test("a failed photo-choice read rolls the whole discard back and a retry completes it")
    func annotationReadFailureRollsBackDiscard() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let ping = makePing(in: ctx, source: .photoImport)
        let stay = makeStay(in: ctx, source: .photoImport, startDay: 0, endDay: 1, pingIDs: [ping.id])
        let trip = makeTrip(in: ctx, source: .photoImport, startDay: 0, endDay: 1)
        stay.trip = trip
        let tripID = trip.id
        ctx.insert(HiddenPhoto(localIdentifier: "H1", tripID: tripID))
        ctx.insert(PinnedPhoto(localIdentifier: "P1", tripID: tripID))
        try ctx.save()
        let service = PhotoImportService(modelContainer: container)

        let operation = Task {
            await PhotoImportService.$failDiscardAnnotationFetchForTesting.withValue(true) {
                do {
                    try await service.performDiscardTeardownForTesting()
                    return false
                } catch { return true }
            }
        }
        #expect(await operation.value)
        let afterFailure = ModelContext(container)
        #expect(try afterFailure.fetchCount(FetchDescriptor<Trip>()) == 1)
        #expect(try afterFailure.fetchCount(FetchDescriptor<Stay>()) == 1)
        #expect(try afterFailure.fetchCount(FetchDescriptor<LocationPing>()) == 1)
        #expect(try photoIdentifiers(of: tripID, container).hidden == ["H1"])
        #expect(try photoIdentifiers(of: tripID, container).pinned == ["P1"])

        try await service.performDiscardTeardownForTesting()
        let afterRetry = ModelContext(container)
        #expect(try afterRetry.fetchCount(FetchDescriptor<Trip>()) == 0)
        #expect(try afterRetry.fetchCount(FetchDescriptor<Stay>()) == 0)
        #expect(try afterRetry.fetchCount(FetchDescriptor<HiddenPhoto>()) == 0)
        #expect(try afterRetry.fetchCount(FetchDescriptor<PinnedPhoto>()) == 0)
    }

    // MARK: - Untouched merged stays

    /// A `.merged` stay this import never touched (the Timeline/GPX case)
    /// must be left exactly as it was.
    @Test("a merged stay holding no photo pings keeps its source and pings")
    func untouchedMergedStayIsLeftAlone() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        // There IS a photo import in the store, so the teardown does real work.
        let importPing = makePing(in: ctx, source: .photoImport, at: 8)
        makeStay(in: ctx, source: .photoImport, startDay: 8, endDay: 8.5, pingIDs: [importPing.id])

        let livePing = makePing(in: ctx, source: .liveSLC, at: 20)
        let gpxPing = makePing(in: ctx, source: .gpxImport, at: 20.1)
        let merged = makeStay(in: ctx, source: .merged, startDay: 20, endDay: 21,
                              pingIDs: [livePing.id, gpxPing.id])
        merged.isAirport = true
        merged.h3IndexRes6 = "untouched-cell"
        let mergedID = merged.id
        try ctx.save()

        let service = PhotoImportService(modelContainer: container)
        try await service.performDiscardTeardownForTesting()

        let reloaded = try #require(try refetchStay(mergedID, container))
        #expect(reloaded.source == .merged)
        #expect(reloaded.pingIDs.count == 2)
        #expect(reloaded.pingCount == 2)
        #expect(reloaded.startTime == d(20))
        #expect(reloaded.endTime == d(21))
        #expect(reloaded.durationMinutes == 24 * 60)
        #expect(reloaded.centroidLatitude == athens.lat)
        #expect(reloaded.centroidLongitude == athens.lon)
        #expect(reloaded.h3IndexRes6 == "untouched-cell")
        #expect(reloaded.isAirport)
    }

    /// Once the photo evidence is removed, a Stay backed only by GPX evidence
    /// is no longer mixed. Derive provenance from the remaining pings instead
    /// of preserving a stale `.merged` label.
    @Test("a merged stay becomes .gpxImport when only a GPX ping survives")
    func gpxOnlyRemainderBecomesGPX() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let photoPing = makePing(in: ctx, source: .photoImport, at: 20)
        let gpxPing = makePing(in: ctx, source: .gpxImport, at: 20.1)
        let merged = makeStay(in: ctx, source: .merged, startDay: 20, endDay: 21,
                              pingIDs: [photoPing.id, gpxPing.id])
        let mergedID = merged.id
        try ctx.save()

        let service = PhotoImportService(modelContainer: container)
        try await service.performDiscardTeardownForTesting()

        let reloaded = try #require(try refetchStay(mergedID, container))
        #expect(reloaded.source == .gpxImport)
        #expect(reloaded.pingIDs == [gpxPing.id])
    }

    @Test("a live plus GPX remainder stays mixed after photo removal")
    func genuinelyMixedRemainderStaysMerged() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let photoPing = makePing(in: ctx, source: .photoImport, at: 20)
        let livePing = makePing(in: ctx, source: .liveSLC, at: 20.1)
        let gpxPing = makePing(in: ctx, source: .gpxImport, at: 20.2)
        let merged = makeStay(
            in: ctx, source: .merged, startDay: 20, endDay: 20.2,
            pingIDs: [photoPing.id, livePing.id, gpxPing.id]
        )
        let mergedID = merged.id
        try ctx.save()

        let service = PhotoImportService(modelContainer: container)
        try await service.performDiscardTeardownForTesting()

        let reloaded = try #require(try refetchStay(mergedID, container))
        #expect(reloaded.source == .merged)
        #expect(reloaded.pingIDs == [livePing.id, gpxPing.id])
    }

    @Test("active import defers dedup, then idle reconciliation permits discard", arguments: [false, true])
    func activeImportDefersWholeDedup(externalImport: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let live = makePing(in: ctx, source: .liveSLC, at: 19)
        let winner = makePing(in: ctx, source: .photoImport, at: 20)
        let duplicate = makePing(in: ctx, source: .photoImport, at: 20 + 30.0 / 86_400)
        let unrelated = makePing(in: ctx, source: .photoImport, at: 21)
        // The orphan prepass must not write to process-global defaults.
        for ping in [winner, duplicate, unrelated] { ping.isProcessed = false }
        let originalIDs = [live.id, duplicate.id, unrelated.id]
        let liveID = live.id
        let winnerID = winner.id
        let unrelatedID = unrelated.id
        let stay = makeStay(
            in: ctx, source: .merged, startDay: 19, endDay: 21,
            pingIDs: originalIDs)
        let stayID = stay.id
        try ctx.save()

        await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true,
            importActivityForTesting: (photo: !externalImport, external: externalImport))

        let activeRows = try ModelContext(container).fetch(FetchDescriptor<LocationPing>())
        #expect(activeRows.count == 4)
        let activeStay = try #require(try refetchStay(stayID, container))
        #expect(activeStay.pingIDs == originalIDs)
        #expect(activeStay.pingCount == 3)
        #expect(Set(originalIDs).isSubset(of: Set(activeRows.map(\.id))))

        await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true,
            importActivityForTesting: (photo: false, external: false))

        let idleRows = try ModelContext(container).fetch(FetchDescriptor<LocationPing>())
        #expect(Set(idleRows.map(\.id)) == Set([liveID, winnerID, unrelatedID]))
        let idleStay = try #require(try refetchStay(stayID, container))
        #expect(idleStay.pingIDs == [liveID, unrelatedID])
        #expect(idleStay.pingCount == 2)

        // A further pass has no duplicates and must leave discard retryable.
        await PhotoImportPingDeduplicator.deduplicateAll(
            modelContainer: container, bypassSingleFlightForTesting: true)
        let service = PhotoImportService(modelContainer: container)
        try await service.performDiscardTeardownForTesting()

        let remainingRows = try ModelContext(container).fetch(FetchDescriptor<LocationPing>())
        #expect(remainingRows.map(\.id) == [liveID])
        let repaired = try #require(try refetchStay(stayID, container))
        #expect(repaired.pingIDs == [liveID])
        #expect(repaired.pingCount == 1)
        #expect(repaired.source == .liveSLC)
    }

    @Test("discard fails closed when a surviving referenced ping is not hydrated")
    func missingSurvivingPingRollsBackDiscard() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let photoPing = makePing(in: ctx, source: .photoImport, at: 20)
        let missingLivePingID = UUID()
        let merged = makeStay(
            in: ctx, source: .merged, startDay: 19, endDay: 20,
            pingIDs: [missingLivePingID, photoPing.id]
        )
        let mergedID = merged.id
        let photoID = photoPing.id
        try ctx.save()

        let service = PhotoImportService(modelContainer: container)
        var sawExpectedError = false
        do {
            try await service.performDiscardTeardownForTesting()
            Issue.record("Discard unexpectedly succeeded with an unresolved surviving ping UUID")
        } catch PhotoImportError.incompleteLocalData {
            sawExpectedError = true
        } catch {
            Issue.record("Discard threw the wrong error: \(error)")
        }
        #expect(sawExpectedError)

        let untouched = try #require(try refetchStay(mergedID, container))
        #expect(untouched.pingIDs == [missingLivePingID, photoID])
        #expect(untouched.startTime == d(19))
        let id = photoID
        let photoPredicate = #Predicate<LocationPing> { $0.id == id }
        let photos = try ModelContext(container).fetch(
            FetchDescriptor<LocationPing>(predicate: photoPredicate)
        )
        #expect(photos.count == 1)
    }

    /// Two rows sharing one logical ping UUID but DISAGREEING on coordinates
    /// cannot identify one authoritative position; the transaction must fail
    /// closed rather than pick an arbitrary copy and sync fabricated geometry.
    @Test("disagreeing duplicate ping copies fail the discard closed")
    func disagreeingDuplicatePingCopiesFailClosed() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let photoPing = makePing(in: ctx, source: .photoImport, at: 20)
        let live = makePing(in: ctx, source: .liveSLC, at: 20.1)
        let conflictingCopy = makePing(
            in: ctx, source: .liveSLC, at: 20.1, latitude: athens.lat + 0.5
        )
        conflictingCopy.id = live.id
        let merged = makeStay(
            in: ctx, source: .merged, startDay: 20, endDay: 20.1,
            pingIDs: [live.id, photoPing.id]
        )
        let mergedID = merged.id
        let liveID = live.id
        let photoID = photoPing.id
        try ctx.save()

        let service = PhotoImportService(modelContainer: container)
        var sawExpectedError = false
        do {
            try await service.performDiscardTeardownForTesting()
            Issue.record("Discard unexpectedly succeeded with disagreeing duplicate ping copies")
        } catch PhotoImportError.inconsistentLocalData {
            sawExpectedError = true
        } catch {
            Issue.record("Discard threw the wrong error: \(error)")
        }
        #expect(sawExpectedError)

        let untouched = try #require(try refetchStay(mergedID, container))
        #expect(untouched.pingIDs == [liveID, photoID])
        let id = photoID
        let photoPredicate = #Predicate<LocationPing> { $0.id == id }
        let photos = try ModelContext(container).fetch(
            FetchDescriptor<LocationPing>(predicate: photoPredicate)
        )
        #expect(photos.count == 1)
    }

    /// Byte-identical duplicate copies (transient CloudKit convergence) are
    /// consistent evidence: the discard proceeds and EVERY copy of a released
    /// ping returns to the clusterer, so no processed orphan survives for the
    /// deduplicator's later survivor pick.
    @Test("agreeing duplicate copies of a released ping are all released")
    func agreeingDuplicateCopiesAreAllReleased() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let photoPing = makePing(in: ctx, source: .photoImport, at: 20)
        let live = makePing(in: ctx, source: .liveSLC, at: 20.1)
        let duplicateCopy = makePing(in: ctx, source: .liveSLC, at: 20.1)
        duplicateCopy.id = live.id
        let importStay = makeStay(
            in: ctx, source: .photoImport, startDay: 20, endDay: 20.1,
            pingIDs: [photoPing.id, live.id]
        )
        let importStayID = importStay.id
        let liveID = live.id
        try ctx.save()

        let service = PhotoImportService(modelContainer: container)
        try await service.performDiscardTeardownForTesting()

        let predicate = #Predicate<LocationPing> { $0.id == liveID }
        let copies = try ModelContext(container).fetch(
            FetchDescriptor<LocationPing>(predicate: predicate)
        )
        #expect(copies.count == 2)
        #expect(copies.allSatisfy { !$0.isProcessed })
        #expect(try refetchStay(importStayID, container) == nil)
    }

    /// The original, unchanged behaviour: a live+photo stay reverts.
    @Test("a merged stay with only live pings left reverts to .liveSLC")
    func liveOnlyRemainderReverts() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let photoPing = makePing(in: ctx, source: .photoImport, at: 20)
        let livePing = makePing(in: ctx, source: .liveSLC, at: 20.1)
        let merged = makeStay(in: ctx, source: .merged, startDay: 20, endDay: 21,
                              pingIDs: [photoPing.id, livePing.id])
        let mergedID = merged.id
        try ctx.save()

        let service = PhotoImportService(modelContainer: container)
        try await service.performDiscardTeardownForTesting()

        let reloaded = try #require(try refetchStay(mergedID, container))
        #expect(reloaded.source == .liveSLC)
        #expect(reloaded.pingIDs == [livePing.id])
    }

    @Test("a merged host survives photo removal on Visit evidence alone")
    func visitOnlyMergedHostSurvives() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let photo = makePing(in: ctx, source: .photoImport, at: 10)
        let host = makeStay(
            in: ctx, source: .merged, startDay: 10, endDay: 11,
            pingIDs: [photo.id]
        )
        let stayID = host.id
        let visit = makeVisit(
            in: ctx, stayID: stayID, arrival: d(9), departure: d(12),
            latitude: 38.25
        )
        let visitID = visit.id
        try ctx.save()

        try await PhotoImportService(modelContainer: container)
            .performDiscardTeardownForTesting()

        let rebuilt = try #require(try refetchStay(stayID, container))
        #expect(rebuilt.pingIDs.isEmpty)
        #expect(rebuilt.pingCount == 0)
        #expect(rebuilt.startTime == d(9))
        #expect(rebuilt.endTime == d(12))
        #expect(rebuilt.centroidLatitude == 38.25)
        #expect(rebuilt.source == .liveSLC)
        let savedVisit = try ModelContext(container).fetch(
            FetchDescriptor<Visit>(predicate: #Predicate { $0.id == visitID })
        ).first
        #expect(savedVisit?.stayID == stayID)
    }

    @Test("a live ping plus Visit rebuild stays live after photo removal")
    func livePingAndVisitRebuildTogether() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let live = makePing(
            in: ctx, source: .foregroundStream, at: 20.5, latitude: 38.1
        )
        let photo = makePing(in: ctx, source: .photoImport, at: 20.6)
        let host = makeStay(
            in: ctx, source: .merged, startDay: 20, endDay: 21,
            pingIDs: [live.id, photo.id]
        )
        makeVisit(in: ctx, stayID: host.id, arrival: d(20), departure: d(21),
                  latitude: 39)
        let stayID = host.id
        try ctx.save()

        try await PhotoImportService(modelContainer: container)
            .performDiscardTeardownForTesting()

        let rebuilt = try #require(try refetchStay(stayID, container))
        #expect(rebuilt.pingIDs == [live.id])
        #expect(rebuilt.pingCount == 1)
        #expect(rebuilt.startTime == d(20))
        #expect(rebuilt.endTime == d(21))
        #expect(rebuilt.centroidLatitude == live.latitude)
        #expect(rebuilt.source == .liveSLC)
    }

    @Test("photo-import Stays are deleted even when a Visit links to them")
    func visitDoesNotChangePhotoImportStayDeletion() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let photo = makePing(in: ctx, source: .photoImport, at: 30)
        let imported = makeStay(
            in: ctx, source: .photoImport, startDay: 30, endDay: 31,
            pingIDs: [photo.id]
        )
        let stayID = imported.id
        let visit = makeVisit(
            in: ctx, stayID: stayID, arrival: d(30), departure: d(31)
        )
        let visitID = visit.id
        try ctx.save()

        try await PhotoImportService(modelContainer: container)
            .performDiscardTeardownForTesting()

        #expect(try refetchStay(stayID, container) == nil)
        let savedVisit = try ModelContext(container).fetch(
            FetchDescriptor<Visit>(predicate: #Predicate { $0.id == visitID })
        ).first
        #expect(savedVisit?.stayID == stayID)
    }

    @Test("neighbour clamps survive photo teardown")
    func s3NeighbourClampSurvivesTeardown() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let tuesday = d(1)
        let wednesday = d(2)
        let h1End = tuesday.addingTimeInterval(3_600)
        let h2Start = h1End.addingTimeInterval(1)
        let h3Start = wednesday.addingTimeInterval(8 * 3_600)
        let h2End = h3Start.addingTimeInterval(-1)
        let h1 = makeStay(
            in: ctx, source: .liveSLC, startDay: 0.75,
            endDay: 1 + 1.0 / 24, pingIDs: []
        )
        h1.endTime = h1End
        let photo = makePing(in: ctx, source: .photoImport, at: 1.5)
        let h2 = makeStay(
            in: ctx, source: .merged, startDay: 1, endDay: 2,
            pingIDs: [photo.id]
        )
        h2.startTime = h2Start
        h2.endTime = h2End
        let h3 = makeStay(
            in: ctx, source: .liveSLC, startDay: 2 + 8.0 / 24,
            endDay: 3, pingIDs: []
        )
        h3.startTime = h3Start
        makeVisit(
            in: ctx,
            stayID: h2.id,
            arrival: tuesday.addingTimeInterval(30 * 60),
            departure: h3Start.addingTimeInterval(30 * 60)
        )
        let h2ID = h2.id
        try ctx.save()

        try await PhotoImportService(modelContainer: container)
            .performDiscardTeardownForTesting()

        let rebuilt = try #require(try refetchStay(h2ID, container))
        #expect(rebuilt.startTime == h2Start)
        #expect(rebuilt.endTime == h2End)
        #expect(rebuilt.pingCount == 0)
        #expect(rebuilt.source == .liveSLC)
    }
}

private actor DiscardWidgetReloadCounter {
    private(set) var count = 0
    func record() { count += 1 }
}
