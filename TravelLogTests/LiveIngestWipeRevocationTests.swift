//
//  LiveIngestWipeRevocationTests.swift
//  TravelLogTests
//
//  Delete All Data advances a committed live acceptance floor beside the
//  Visit floor. The recorder's persistence choke point enforces it for
//  incoming and retried candidates, so a fix acquired before the wipe and
//  delivered after it (the foreground stream's 30 s pending buffer, a
//  delegate hop) or a failed-save retry can never restore wiped history.
//  Each test drives `DataWipe.execute` and `PingRecorder.processLocations`,
//  the bodies of the Settings wipe unit and the live ingest unit, against a
//  file-backed store and a throwaway defaults suite.
//

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Live ingest wipe revocation")
struct LiveIngestWipeRevocationTests {

    private let athens = (latitude: 37.9838, longitude: 23.7275)
    private let ioannina = (latitude: 39.6628, longitude: 20.8612)

    /// The recorder actor gets its own handle on the suite
    /// (`UserDefaults(suiteName: suite)!`), never this main-actor instance.
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "live-wipe-revocation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func candidate(
        at timestamp: Date, _ place: (latitude: Double, longitude: Double),
        source: DataSource = .foregroundStream
    ) -> LiveLocationCandidate {
        LiveLocationCandidate(
            CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: place.latitude, longitude: place.longitude),
                altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                course: -1, speed: -1, timestamp: timestamp),
            source: source)
    }

    private func pings(in container: ModelContainer) throws -> [LocationPing] {
        try ModelContext(container).fetch(FetchDescriptor<LocationPing>(
            sortBy: [SortDescriptor(\.timestamp)]))
    }

    private func hexVisits(in container: ModelContainer) throws -> [HexVisit] {
        try ModelContext(container).fetch(FetchDescriptor<HexVisit>())
    }

    private func wipe(
        _ container: ModelContainer, defaults: UserDefaults,
        beforeCommit: () throws -> Void = {}
    ) -> Bool {
        DataWipe.execute(
            container: container, defaults: defaults,
            beforeCommit: beforeCommit)
    }

    private func liveFloor(_ defaults: UserDefaults) -> Date? {
        defaults.object(forKey: PingRecorder.liveAcceptanceFloorKey) as? Date
    }

    @Test("a fix buffered before the wipe is rejected; a fresh fix is kept")
    func bufferedPreWipeFixIsRejected() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let seed = ModelContext(container)
        seed.insert(Trip(startDate: .now.addingTimeInterval(-86_400)))
        try seed.save()

        #expect(wipe(container, defaults: defaults))
        let floor = try #require(liveFloor(defaults))
        let visitFloor = try #require(
            defaults.object(forKey: VisitRecorder.acceptanceFloorKey) as? Date)
        #expect(floor == visitFloor, "both floors advance at one committed instant")

        let recorder = PingRecorder(modelContainer: container)
        let fresh = floor.addingTimeInterval(1)
        await recorder.processLocations([
            candidate(at: floor.addingTimeInterval(-20), athens),
            candidate(at: fresh, ioannina),
        ], defaults: UserDefaults(suiteName: suite)!)

        let saved = try pings(in: container)
        #expect(saved.map(\.timestamp) == [fresh])
        let hexes = try hexVisits(in: container)
        #expect(hexes.count == 1)
        #expect(hexes.first?.firstVisited == fresh)
    }

    @Test("a failed pre-wipe live save cannot be retried into the wiped store")
    func failedSaveRetryCannotSurviveWipe() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        let early = Date.now.addingTimeInterval(-60)

        await recorder.setFailNextLiveSaveForTesting(true)
        await recorder.processLocations([candidate(at: early, athens)], defaults: UserDefaults(suiteName: suite)!)
        #expect(try pings(in: container).isEmpty)

        #expect(wipe(container, defaults: defaults))
        let floor = try #require(liveFloor(defaults))
        let fresh = floor.addingTimeInterval(1)
        await recorder.processLocations([candidate(at: fresh, ioannina)], defaults: UserDefaults(suiteName: suite)!)

        let saved = try pings(in: container)
        #expect(saved.map(\.timestamp) == [fresh],
                "neither the retry buffer nor unsaved context residue may restore the pre-wipe fix")
        #expect(try hexVisits(in: container).count == 1)
    }

    @Test("a rolled-back wipe leaves the floor alone and keeps retry authority")
    func failedWipeKeepsRetryAuthority() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        let first = Date.now.addingTimeInterval(-600)

        await recorder.setFailNextLiveSaveForTesting(true)
        await recorder.processLocations([candidate(at: first, athens)], defaults: UserDefaults(suiteName: suite)!)
        #expect(!wipe(container, defaults: defaults,
                      beforeCommit: { throw CocoaError(.fileWriteUnknown) }))
        #expect(liveFloor(defaults) == nil)

        let second = Date.now
        await recorder.processLocations([candidate(at: second, ioannina)], defaults: UserDefaults(suiteName: suite)!)
        #expect(try pings(in: container).map(\.timestamp) == [first, second])
    }

    @Test("a fix exactly at the floor is kept; one before it is dropped")
    func floorBoundary() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let floor = Date(timeIntervalSinceReferenceDate: 819_958_400)
        defaults.set(floor, forKey: PingRecorder.liveAcceptanceFloorKey)
        let recorder = PingRecorder(modelContainer: container)

        await recorder.processLocations([
            candidate(at: floor.addingTimeInterval(-1), athens),
            candidate(at: floor, ioannina),
        ], defaults: UserDefaults(suiteName: suite)!)
        #expect(try pings(in: container).map(\.timestamp) == [floor])
    }

    @Test("an SLC batch made only of rejected fixes writes nothing, geocoding included")
    func rejectedOnlySLCBatchWritesNothing() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let floor = Date(timeIntervalSinceReferenceDate: 819_958_400)
        defaults.set(floor, forKey: PingRecorder.liveAcceptanceFloorKey)
        let context = ModelContext(container)
        let backlog = LocationPing(
            timestamp: floor.addingTimeInterval(3_600),
            latitude: athens.latitude, longitude: athens.longitude,
            horizontalAccuracy: 10,
            h3IndexRes6: try #require(H3Service.cellIndex(
                latitude: athens.latitude, longitude: athens.longitude)),
            source: .photoImport)
        context.insert(backlog)
        try context.save()
        #expect(!backlog.isGeocoded)

        let recorder = PingRecorder(modelContainer: container)
        let changes = await recorder.processLocations(
            [candidate(at: floor.addingTimeInterval(-5), ioannina, source: .liveSLC)],
            defaults: UserDefaults(suiteName: suite)!)
        #expect(changes.isEmpty)
        let saved = try pings(in: container)
        #expect(saved.count == 1)
        #expect(saved.first?.isGeocoded == false,
                "a fully rejected SLC wake must not drain the geocode backlog")
    }

    @Test("an explicit historical import is not subject to the live floor")
    func explicitImportIgnoresLiveFloor() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        #expect(wipe(container, defaults: defaults))
        let floor = try #require(liveFloor(defaults))
        let recorder = PingRecorder(modelContainer: container)

        let inserted = try await recorder.recordImportedPings([
            ImportedPingCandidate(
                timestamp: floor.addingTimeInterval(-86_400),
                latitude: athens.latitude, longitude: athens.longitude,
                horizontalAccuracy: 10),
        ])
        try await recorder.saveImportBatch()
        #expect(inserted == 1)
        #expect(try pings(in: container).count == 1)
    }

    @Test("a successful empty cursor fetch clears the live reentry cursor")
    func emptyStoreClearsLiveCursor() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let cell = try #require(H3Service.cellIndex(
            latitude: athens.latitude, longitude: athens.longitude))
        let base = Date(timeIntervalSinceReferenceDate: 819_958_400)
        let context = ModelContext(container)
        let livePing = LocationPing(
            timestamp: base, latitude: athens.latitude, longitude: athens.longitude,
            horizontalAccuracy: 10, h3IndexRes6: cell, source: .liveSLC)
        context.insert(livePing)
        context.insert(HexVisit(
            h3Index: cell, firstVisited: base,
            centerLatitude: athens.latitude, centerLongitude: athens.longitude))
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        await recorder.restoreLastH3Index()
        // Every live ping is gone; the hex row stays so reentry is observable.
        context.delete(livePing)
        try context.save()
        await recorder.restoreLastH3Index()

        await recorder.processLocations(
            [candidate(at: base.addingTimeInterval(3_600), athens)], defaults: UserDefaults(suiteName: suite)!)
        let hex = try #require(try hexVisits(in: container).first)
        #expect(hex.visitCount == 2,
                "a cursor derived from deleted history must not suppress the next reentry")
    }
}
