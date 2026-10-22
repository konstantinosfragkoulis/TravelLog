//
//  P08RegressionTests.swift
//  TravelLogTests
//
//  Stay interval reconciliation and the review follow-ups assigned with it:
//  what a Visit or a historical walk may change about stored stays and their
//  trips, which copy of a ping clustering places, and which identities a
//  restore, an export or an iCloud account change carry forward.
//
//  @MainActor because the app target compiles with MainActor-by-default
//  isolation; assertions re-fetch from a fresh context.
//

import Foundation
import SwiftData
import Testing
import os
@testable import TravelLog

// MARK: - MULTI-004 support

/// Application Support redirected to a test directory, for the restore marker.
private final class P08SupportDirectory: FileManager {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        [self.directory]
    }
}

// MARK: - Suite

@MainActor
@Suite("Stay interval reconciliation and follow-ups")
struct P08RegressionTests {

    /// Fictional instants and place.
    private static let base = Date(timeIntervalSinceReferenceDate: 830_000_000)
    private static let latitude = 44.3
    private static let longitude = 12.9

    private func at(_ hour: Double, day: Double = 0) -> Date {
        Self.base.addingTimeInterval(day * 86_400 + hour * 3_600)
    }

    /// A longitude `meters` east of the fixture place along its parallel.
    private func longitude(metersEast meters: Double) -> Double {
        Self.longitude + meters / (111_320 * cos(Self.latitude * .pi / 180))
    }

    @discardableResult
    private func insertPing(
        _ context: ModelContext, at timestamp: Date, metersEast: Double = 0,
        id: UUID? = nil, source: DataSource = .liveSLC, processed: Bool = true
    ) -> LocationPing {
        let lon = longitude(metersEast: metersEast)
        let ping = LocationPing(
            timestamp: timestamp, latitude: Self.latitude, longitude: lon,
            horizontalAccuracy: 10,
            h3IndexRes6: H3Service.cellIndex(latitude: Self.latitude, longitude: lon) ?? "",
            source: source)
        if let id { ping.id = id }
        ping.isProcessed = processed
        context.insert(ping)
        return ping
    }

    @discardableResult
    private func insertStay(
        _ context: ModelContext, start: Date, end: Date, metersEast: Double = 0,
        pingTimes: [Date] = []
    ) -> Stay {
        let lon = longitude(metersEast: metersEast)
        let pings = pingTimes.map { insertPing(context, at: $0, metersEast: metersEast) }
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: Self.latitude, centroidLongitude: lon,
            h3IndexRes6: H3Service.cellIndex(latitude: Self.latitude, longitude: lon) ?? "",
            pingCount: pings.count, distanceFromHomeKm: .greatestFiniteMagnitude,
            pingIDs: pings.map(\.id))
        context.insert(stay)
        return stay
    }

    @discardableResult
    private func insertVisit(
        _ context: ModelContext, arrival: Date, departure: Date?, metersEast: Double = 0
    ) -> Visit {
        let visit = Visit(
            arrivalDate: arrival, departureDate: departure,
            latitude: Self.latitude, longitude: longitude(metersEast: metersEast),
            horizontalAccuracy: 5, receivedAt: departure ?? arrival)
        context.insert(visit)
        return visit
    }

    private func stays(_ container: ModelContainer) throws -> [Stay] {
        try ModelContext(container).fetch(FetchDescriptor<Stay>(
            sortBy: [SortDescriptor(\.startTime, order: .forward)]))
    }

    private func stay(_ id: UUID, in container: ModelContainer) throws -> Stay {
        try #require(try stays(container).first { $0.id == id })
    }

    // MARK: - STAY-001

    nonisolated enum MovedBoundary: CaseIterable, Sendable {
        /// The Visit pulls the arrival stay's own start earlier.
        case arrivalStart
        /// The Visit pulls the predecessor's end back; the arrival stay's start holds.
        case predecessorEnd
    }

    @Test("a Visit that moves a leg's boundary keeps the user's Not a Flight and its distance; an automatic flight is still cleared",
          arguments: MovedBoundary.allCases, [TransitMode.notFlight, .flight])
    func visitIntervalKeepsNotAFlight(boundary: MovedBoundary, mode: TransitMode) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        var departure: Stay?
        let arrival: Stay
        switch boundary {
        case .arrivalStart:
            arrival = insertStay(context, start: at(12), end: at(14), pingTimes: [at(12.5), at(13)])
            insertVisit(context, arrival: at(11), departure: at(13.5))
        case .predecessorEnd:
            departure = insertStay(context, start: at(8), end: at(12.5), metersEast: 50_000,
                                   pingTimes: [at(8), at(8.5)])
            arrival = insertStay(context, start: at(12), end: at(14), pingTimes: [at(12.25), at(13)])
            insertVisit(context, arrival: at(12), departure: at(13.5))
        }
        arrival.transitFromPreviousRaw = mode.rawValue
        arrival.distanceFromPreviousKm = 500
        let arrivalID = arrival.id
        let departureID = departure?.id
        try context.save()

        _ = await StayClusterer(modelContainer: container).clusterUnprocessedPings()

        let saved = try stay(arrivalID, in: container)
        switch boundary {
        case .arrivalStart:
            #expect(saved.startTime == at(11))
        case .predecessorEnd:
            #expect(saved.startTime == at(12))
            #expect(try stay(try #require(departureID), in: container).endTime
                == at(12).addingTimeInterval(-60))
        }
        if mode == .notFlight {
            #expect(saved.transitFromPreviousRaw == TransitMode.notFlight.rawValue)
            #expect(saved.distanceFromPreviousKm == 500)
        } else {
            #expect(saved.transitFromPreviousRaw == nil)
            #expect(saved.distanceFromPreviousKm == nil)
        }
    }

    // MARK: - STAY-003

    @Test("a historical walk does not extend an imported stay across a stay the store holds, so it stays strictly between the pieces")
    func historicalExtensionStopsAtStoredStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let home = insertStay(context, start: at(10), end: at(11), pingTimes: [at(10.5)])
        home.category = .home
        // The live continuity anchor, the next day.
        insertStay(context, start: at(10, day: 1), end: at(12, day: 1), pingTimes: [at(11, day: 1)])
        // Two photos at one place away, either side of the home stay, inside the gap threshold.
        let early = insertPing(context, at: at(8), metersEast: 50_000, source: .photoImport, processed: false)
        let late = insertPing(context, at: at(11.5), metersEast: 50_000, source: .photoImport, processed: false)
        let homeID = home.id
        try context.save()

        #expect(await StayClusterer(modelContainer: container).clusterUnprocessedPings() == 2)

        let all = try stays(container)
        #expect(all.count == 4)
        let storedHome = try stay(homeID, in: container)
        #expect(storedHome.startTime == at(10))
        #expect(storedHome.endTime == at(11))
        let before = try #require(all.first { $0.pingIDs == [early.id] })
        let after = try #require(all.first { $0.pingIDs == [late.id] })
        #expect(before.endTime < storedHome.startTime)
        #expect(after.startTime > storedHome.endTime)
        #expect(after.startTime == at(11.5))
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocationPing>()).allSatisfy { $0.isProcessed })
    }

    @Test("with no stored stay between them, same-place historical pings still join one stay")
    func historicalExtensionWithoutConflictJoins() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        insertStay(context, start: at(10, day: 1), end: at(12, day: 1), pingTimes: [at(11, day: 1)])
        let early = insertPing(context, at: at(8), metersEast: 50_000, source: .photoImport, processed: false)
        let late = insertPing(context, at: at(11.5), metersEast: 50_000, source: .photoImport, processed: false)
        try context.save()

        #expect(await StayClusterer(modelContainer: container).clusterUnprocessedPings() == 1)

        let joined = try #require(try stays(container).first { $0.pingIDs.contains(early.id) })
        #expect(joined.pingIDs == [early.id, late.id])
        #expect(joined.startTime == at(8))
    }

    @Test("a stored stay at the same place between two historical pings is no barrier: they still join one stay")
    func historicalExtensionAcrossCompatibleStayJoins() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // A stay the store holds at the photos' own place, between them.
        let host = insertStay(context, start: at(10), end: at(11), metersEast: 50_000, pingTimes: [at(10.5)])
        insertStay(context, start: at(10, day: 1), end: at(12, day: 1), pingTimes: [at(11, day: 1)])
        let early = insertPing(context, at: at(8), metersEast: 50_000, source: .photoImport, processed: false)
        let late = insertPing(context, at: at(11.5), metersEast: 50_000, source: .photoImport, processed: false)
        let hostID = host.id
        try context.save()

        #expect(await StayClusterer(modelContainer: container).clusterUnprocessedPings() == 1,
                "a compatible stored stay fragmented the historical stay")

        let joined = try #require(try stays(container).first { $0.pingIDs.contains(early.id) })
        #expect(joined.pingIDs == [early.id, late.id])
        #expect(joined.startTime == at(8))
        let storedHost = try stay(hostID, in: container)
        #expect(storedHost.startTime == at(10))
        #expect(storedHost.endTime == at(11))
    }

    // MARK: - STAY-004

    @Test("a Visit that leaves a member's interval unchanged keeps a completed trip's wider saved dates; a trip that tracked its members follows them",
          arguments: [false, true])
    func visitKeepsIndependentlyWiderTripDates(edited: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // A restored or merged trip whose saved span is wider than its member.
        let member = insertStay(context, start: at(2), end: at(3), pingTimes: [at(2), at(3)])
        member.category = .destination
        let wider = Trip(startDate: at(0))
        wider.endDate = at(10)
        wider.isComplete = true
        wider.userEdited = edited
        context.insert(wider)
        member.trip = wider
        member.orderInTrip = 0
        insertVisit(context, arrival: at(2.2), departure: at(2.8))
        // A trip whose dates are its member's: an earlier arrival moves its start.
        let tracked = insertStay(context, start: at(20, day: 1), end: at(21, day: 1),
                                 pingTimes: [at(20.5, day: 1), at(21, day: 1)])
        tracked.category = .destination
        let follows = Trip(startDate: at(20, day: 1))
        follows.endDate = at(21, day: 1)
        follows.isComplete = true
        context.insert(follows)
        tracked.trip = follows
        tracked.orderInTrip = 0
        insertVisit(context, arrival: at(19, day: 1), departure: at(21, day: 1))
        let widerID = wider.id
        let followsID = follows.id
        let memberID = member.id
        try context.save()

        _ = await StayClusterer(modelContainer: container).clusterUnprocessedPings()

        let read = ModelContext(container)
        let trips = try read.fetch(FetchDescriptor<Trip>())
        let savedMember = try stay(memberID, in: container)
        #expect(savedMember.startTime == at(2))
        #expect(savedMember.endTime == at(3))
        let savedWider = try #require(trips.first { $0.id == widerID })
        #expect(savedWider.startDate == at(0))
        #expect(savedWider.endDate == at(10))
        let savedFollows = try #require(trips.first { $0.id == followsID })
        #expect(savedFollows.startDate == at(19, day: 1))
        #expect(savedFollows.endDate == at(21, day: 1))
    }

    // MARK: - FU-3

    @Test("a copy of a placed ping that arrives in a later run is settled, not placed again")
    func lateTwinOfPlacedPingIsSettled() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let first = insertPing(context, at: at(0), source: .photoImport, processed: false)
        let second = insertPing(context, at: at(0.5), metersEast: 800, source: .photoImport, processed: false)
        try context.save()
        let clusterer = StayClusterer(modelContainer: container)
        #expect(await clusterer.clusterUnprocessedPings() == 1)
        let placed = try #require(try stays(container).first)
        let centroid = (placed.centroidLatitude, placed.centroidLongitude)

        // Delayed hydration delivers unprocessed copies of both: the later one
        // would append to the stay again, the earlier one start a historical stay.
        insertPing(context, at: at(0.5), metersEast: 800, id: second.id, source: .photoImport, processed: false)
        insertPing(context, at: at(0), id: first.id, source: .photoImport, processed: false)
        try context.save()
        #expect(await clusterer.clusterUnprocessedPings() == 0)

        let all = try stays(container)
        #expect(all.count == 1)
        let stay = try #require(all.first)
        #expect(stay.pingIDs == [first.id, second.id])
        #expect(stay.pingCount == 2)
        #expect(stay.centroidLatitude == centroid.0)
        #expect(stay.centroidLongitude == centroid.1)
        let pings = try ModelContext(container).fetch(FetchDescriptor<LocationPing>())
        #expect(pings.count == 4, "every physical copy stays")
        #expect(pings.allSatisfy { $0.isProcessed })
    }

    @Test("a late copy and a current ping read only the stays around each, not the history between them")
    func lateTwinReadsOnlyItsNeighbourhood() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let host = insertStay(context, start: at(10), end: at(11), pingTimes: [at(10.5)])
        let placedID = try #require(host.pingIDs.first)
        // The history between the copy and today.
        for day in 2...9 {
            insertStay(context, start: at(10, day: Double(day)), end: at(11, day: Double(day)),
                       pingTimes: [at(10.5, day: Double(day))])
        }
        // Delayed hydration delivers a copy of the placed ping; a live ping arrives today.
        insertPing(context, at: at(10.5), id: placedID, source: .photoImport, processed: false)
        insertPing(context, at: at(10, day: 20), processed: false)
        let hostID = host.id
        try context.save()

        let pages = OSAllocatedUnfairLock(initialState: [Int]())
        let created = await StayClusterer.ReadTestHook.$memberPageRead.withValue({ count in
            pages.withLock { $0.append(count) }
        }) {
            await StayClusterer(modelContainer: container).clusterUnprocessedPings()
        }

        #expect(created == 1, "the copy is settled and the live ping starts today's stay")
        #expect(pages.withLock { $0 } == [1, 0],
                "membership reads covered more than the copy's and the live ping's own neighbourhoods")
        #expect(try stay(hostID, in: container).pingIDs == [placedID])
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocationPing>()).allSatisfy { $0.isProcessed })
    }

    @Test("membership neighbourhoods join only cohorts whose gap-threshold spans touch")
    func memberReadWindowsSplitDistantCohorts() {
        let margin = StayClusterer.timeGapThresholdSeconds
        let windows = StayClusterer.memberReadWindows(
            [at(0), at(3), at(10), at(0, day: 5)], margin: margin)
        #expect(windows.count == 2)
        #expect(windows.first?.lower == at(-4))
        #expect(windows.first?.upper == at(14))
        #expect(windows.last?.lower == at(-4, day: 5))
        #expect(windows.last?.upper == at(4, day: 5))
    }

    // MARK: - MULTI-004

    @Test("an import opened before launch consumes a restore is judged and recorded under a fresh identity")
    func pendingRestoreRotatesFenceIdentity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("P08RegressionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileManager = P08SupportDirectory(directory: directory)
        let suite = "P08RegressionTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))

        // The backup carries the original's identity and the sentinel flag,
        // but not the excluded marker; the original imported F after it.
        let original = ImportFence.deviceID(defaults: defaults)
        defaults.set(true, forKey: RestoreSentinel.flagKey)
        let fingerprint = ImportFence.fingerprint(of: Data("p08-file".utf8))
        let delivered = [ImportFence.Record(fingerprint: fingerprint, deviceID: original, date: Self.base)]
        #expect(RestoreSentinel.isRestorePending(defaults: defaults, fileManager: fileManager))

        // F is opened before the delayed launch work consumes the restore.
        let judged = ImportFence.confirmedDeviceID(defaults: defaults, fileManager: fileManager)
        #expect(judged != original)
        #expect(ImportFence.isCrossDeviceRepeat(records: delivered, fingerprint: fingerprint, deviceID: judged))

        // Once the restore is consumed the identity holds from launch to launch.
        #expect(RestoreSentinel.consumeRestoreDetection(defaults: defaults, fileManager: fileManager))
        let settled = ImportFence.confirmedDeviceID(defaults: defaults, fileManager: fileManager)
        #expect(settled != original)
        #expect(ImportFence.confirmedDeviceID(defaults: defaults, fileManager: fileManager) == settled)
        #expect(!RestoreSentinel.consumeRestoreDetection(defaults: defaults, fileManager: fileManager))
        #expect(ImportFence.confirmedDeviceID(defaults: defaults, fileManager: fileManager) == settled)
    }

    // MARK: - PERM-001

    @Test("the widget mirror keeps its account through an unavailable token, so a cold launch under another account drops it")
    func mirrorAttributionSurvivesUnavailableToken() throws {
        let suite = "P08RegressionTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let a = Data("account-a".utf8)
        let b = Data("account-b".utf8)

        // Written under A, then refreshed while iCloud withheld the token.
        RememberedCountriesStorage.writeMirrorAccount(a, to: defaults)
        RememberedCountriesStorage.writeMirrorAccount(nil, to: defaults)
        let tag = defaults.data(forKey: RememberedCountriesStorage.appGroupMirrorAccountKey)
        #expect(tag == a)

        // The app was not running when the account became B.
        #expect(RememberedCountriesStorage.mirrorBelongsToAnotherAccount(mirrored: tag, current: b))
        #expect(!RememberedCountriesStorage.mirrorBelongsToAnotherAccount(mirrored: tag, current: a))

        // A confirmed account with a known identity replaces the tag.
        RememberedCountriesStorage.writeMirrorAccount(b, to: defaults)
        #expect(defaults.data(forKey: RememberedCountriesStorage.appGroupMirrorAccountKey) == b)
    }

    // MARK: - P05-1 union export summary

    /// One Trip UUID held by two copies, neither holding every stay, with a
    /// Home whose place one of the destinations is named after.
    private func insertUnionTwins(_ context: ModelContext) -> UUID {
        let home = Home(label: "Home", latitude: Self.latitude, longitude: Self.longitude,
                        startedAt: at(0, day: -400))
        home.locality = "Homeville"
        home.isoCountryCode = "IT"
        context.insert(home)
        let tripID = UUID()
        func twin(_ places: [(hour: Double, locality: String, iso: String)]) {
            let trip = Trip(startDate: at(places[0].hour), source: .liveSLC)
            trip.id = tripID
            trip.endDate = at((places.last?.hour ?? 0) + 2)
            trip.isComplete = true
            context.insert(trip)
            for (index, place) in places.enumerated() {
                let stay = insertStay(context, start: at(place.hour), end: at(place.hour + 2),
                                      metersEast: 100_000 + place.hour * 1_000)
                stay.category = .destination
                stay.locality = place.locality
                stay.isoCountryCode = place.iso
                stay.trip = trip
                stay.orderInTrip = index
            }
        }
        twin([(6, "Other Town", "FR")])
        twin([(0, "Homeville", "IT"), (2, "Fictional Town", "IT")])
        return tripID
    }

    @Test("an export of same-id copies names their union against the Homes, so a reader keeping whole trips' summaries restores the names")
    func unionExportCarriesHomeAwareSummary() async throws {
        let source = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(source)
        let tripID = insertUnionTwins(context)
        try context.save()

        let snapshots = try await ExportSnapshotter(modelContainer: source).snapshotTrips()
        let entry = try #require(snapshots.first { $0.id == tripID })
        #expect(entry.stays.count == 3)
        #expect(entry.destinationSummary == "Fictional Town, Other Town")

        let data = try await ExportSnapshotter(modelContainer: source).exportData()
        let restored = try TestSupport.makeInMemoryContainer()
        let outcome = await TripDataImporter(modelContainer: restored)
            .importTrips(from: try TripDataImporter.parse(data))
        #expect(!outcome.saveFailed)
        let trip = try #require(try ModelContext(restored).fetch(FetchDescriptor<Trip>()).first)
        #expect(trip.destinationSummary == "Fictional Town, Other Town")
    }

    @Test("an export whose union summary cannot read the Homes writes nothing")
    func unionExportRefusesUnreadableHomes() async throws {
        let source = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(source)
        _ = insertUnionTwins(context)
        try context.save()

        let snapshotter = ExportSnapshotter(modelContainer: source)
        await #expect(throws: (any Error).self) {
            try await TripTitleStore.HomePlaceIndex.$failFetchForTesting.withValue(true) {
                try await snapshotter.snapshotTrips()
            }
        }
    }

    // MARK: - P05-2 union restore summary

    @Test("a restore that cannot read the Home places for a summary it must derive rolls back and reports itself incomplete")
    func unionRestoreFailsClosedOnUnreadableHomes() async throws {
        let start = Self.base.timeIntervalSinceReferenceDate
        let tripID = UUID()
        // A whole trip whose file left its summary for the restore to derive.
        let stayEntry: [String: Any] = [
            "id": UUID().uuidString,
            "startTime": start, "endTime": start + 2 * 3_600,
            "latitude": Self.latitude, "longitude": Self.longitude,
            "locality": "Fictional Town", "isoCountryCode": "IT",
        ]
        let tripEntry: [String: Any] = [
            "id": tripID.uuidString,
            "startDate": start, "endDate": start + 4 * 3_600,
            "stays": [stayEntry],
        ]
        let payload = try BackupFixture.parse(["trips": [tripEntry]])

        let failing = try TestSupport.makeInMemoryContainer()
        let failed = await TripTitleStore.HomePlaceIndex.$failFetchForTesting.withValue(true) {
            await TripDataImporter(modelContainer: failing).importTrips(from: payload)
        }
        #expect(failed.saveFailed)
        #expect(failed.insertedTrips == 0)
        #expect(try ModelContext(failing).fetch(FetchDescriptor<Trip>()).isEmpty)

        let readable = try TestSupport.makeInMemoryContainer()
        let outcome = await TripDataImporter(modelContainer: readable).importTrips(from: payload)
        #expect(!outcome.saveFailed)
        let trip = try #require(try ModelContext(readable).fetch(FetchDescriptor<Trip>()).first)
        #expect(trip.id == tripID)
        #expect(trip.destinationSummary == "Fictional Town")
    }

    // MARK: - HIST-002 lineage in tests

    @Test("a scoped test suite holds the lineage log of every classifier the test runs")
    func lineageLogFollowsTestScope() async throws {
        let suite = "P08RegressionTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let retired = UUID()
        let container = try TestSupport.makeInMemoryContainer()
        await TripClassifier.$hiddenLineageSuiteNameForTesting.withValue(suite) {
            let classifier = TripClassifier(modelContainer: container)
            await classifier.runIsolated { classifier in
                _ = PhotoLineageStore.record(
                    [.init(retiredID: retired, successorIDs: [UUID()])],
                    defaults: classifier.hiddenLineageDefaults)
            }
        }
        let scoped = try #require(UserDefaults(suiteName: suite))
        #expect(PhotoLineageStore.successors(defaults: scoped)[retired] != nil)
        #expect(PhotoLineageStore.successors(defaults: .standard)[retired] == nil)
    }
}
