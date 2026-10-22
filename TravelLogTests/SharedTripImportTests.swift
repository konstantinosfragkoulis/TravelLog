//
//  SharedTripImportTests.swift
//  TravelLogTests
//
//  The recipient side of trip sharing on real in-memory stores, with the
//  real clusterer and classifier (Foundation Models off): a round trip from
//  one store to another, the recipient's own evidence winning, idempotent
//  re-import, a partial overlap merging into one trip, and Remove Shared
//  Data deleting exactly what the share added. Places and dates are
//  fictional fixtures.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

// `.serialized`: the importer's single-flight flag and
// `ExternalHistoryImporter.isImportRunning` are process-global.
@MainActor
@Suite("Shared trip import", .serialized, IsolatedLineageDefaults())
struct SharedTripImportTests {

    typealias Place = (lat: Double, lon: Double)
    // Fictional fixtures.
    static let riverton: Place = (47.6, 3.1)
    static let bayview: Place = (45.5, 3.6)
    static let cliffside: Place = (44.3, 3.5)
    static let harborview: Place = (44.7, -5.1)
    /// A spring day in 2025, midnight UTC.
    static let base = Date(timeIntervalSinceReferenceDate: 762_652_800)

    static func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }

    /// Fixes every `step` hours from `from` to `to` around `place`.
    static func track(_ place: Place, from: Double, to: Double, step: Double = 0.5) -> [(Place, Double)] {
        stride(from: from, through: to, by: step).map { hours in
            let wobble = (hours.truncatingRemainder(dividingBy: 3) - 1.5) * 0.0004
            return ((place.lat + wobble, place.lon - wobble), hours)
        }
    }

    static func sharedTrip(
        id: UUID = UUID(), name: String? = "Coast Weekend",
        fixes: [(Place, Double)], visits: [(Place, Double, Double)] = []
    ) -> SharedTrip {
        let pings = fixes.map { place, hours in
            SharedPing(id: UUID(), timestamp: at(hours), latitude: place.lat, longitude: place.lon,
                       horizontalAccuracy: 25, altitude: nil, verticalAccuracy: nil, sourceRaw: "liveSLC")
        }
        let stay = SharedStay(
            id: UUID(), startTime: pings.first!.timestamp, endTime: pings.last!.timestamp,
            durationMinutes: 60, categoryRaw: StayCategory.destination.rawValue,
            latitude: fixes[0].0.lat, longitude: fixes[0].0.lon, h3IndexRes6: nil,
            pingCount: pings.count, pingIDs: pings.map(\.id), orderInTrip: 0,
            locality: "Bayview", subLocality: nil, administrativeArea: nil, country: nil,
            isoCountryCode: "ES", metroName: nil, islandName: nil, isAirport: false,
            sourceRaw: "liveSLC", userOverridden: false, continuesPreviousTrip: false,
            transitFromPreviousRaw: nil, distanceFromPreviousKm: nil, stepsWalked: nil,
            weatherData: nil, avgTemperatureC: nil, weatherConditionRaw: nil,
            precipitationMm: nil, dayKey: nil, timeZoneIdentifier: "Europe/Madrid")
        return SharedTrip(
            shareID: id, customName: name, startDate: pings.first!.timestamp,
            endDate: pings.last!.timestamp, isComplete: true, countryCodes: ["ES"],
            destinationSummary: "Bayview", stays: [stay], pings: pings,
            visits: visits.map { place, arrival, departure in
                SharedVisit(id: UUID(), arrivalDate: at(arrival), departureDate: at(departure),
                            latitude: place.lat, longitude: place.lon, horizontalAccuracy: 40,
                            stayID: stay.id)
            })
    }

    /// FM off for every classification pass the importer runs.
    static func withoutFM<T>(_ body: () async throws -> T) async rethrows -> T {
        try await StayClassificationInference.TestHook.$availability.withValue(false) {
            try await body()
        }
    }

    // MARK: - Round trip

    @Test("a trip goes from one store to another without home rows and lands as one named trip",
          .timeLimit(.minutes(2)))
    func roundTripBetweenStores() async throws {
        try await Self.withoutFM {
            // Sender: lives in Harborview, travelled to Bayview.
            let sender = try ShareHarness()
            defer { sender.tearDown() }
            try await sender.addHome("Home", Self.harborview, startedAt: Self.at(-24 * 365))
            sender.insertOwnPings(Self.track(Self.harborview, from: 0, to: 10))
            sender.insertOwnPings(Self.track(Self.bayview, from: 20, to: 70))
            sender.insertOwnPings(Self.track(Self.harborview, from: 80, to: 92))
            await sender.runPipeline()
            let senderTrip = try #require(sender.trips().first { trip in
                (trip.stays ?? []).contains { Self.km($0.centroidLatitude, $0.centroidLongitude, Self.bayview) < 5 }
            })
            let senderTripID = senderTrip.id
            let senderBayviewPingIDs = Set(sender.pings().filter {
                Self.km($0.latitude, $0.longitude, Self.bayview) < 5
            }.map(\.id))
            // The sender names it; a Visit sits inside the Bayview stay.
            let bayviewStay = try #require((senderTrip.stays ?? []).first {
                Self.km($0.centroidLatitude, $0.centroidLongitude, Self.bayview) < 5
            })
            senderTrip.customName = "Coast Weekend"
            // Between two fixes, so the import's proximity dedup keeps both ends.
            sender.tripsContext.insert(Visit(arrivalDate: Self.at(30.25), departureDate: Self.at(40.25),
                                             latitude: Self.bayview.lat, longitude: Self.bayview.lon,
                                             horizontalAccuracy: 40, receivedAt: Self.at(40.25), stayID: bayviewStay.id))
            try sender.tripsContext.save()

            let rings = try await sender.classifier.sharingHomeRings()
            let snapshot = try await TripShareSnapshotter(modelContainer: sender.container).trips(ids: [senderTripID])
            let (file, omitted) = TripShareExport.makeFile(
                trips: snapshot, rings: rings, senderName: "Sam", exportedAt: Self.at(100), appVersion: "1.0")
            #expect(omitted == 0)
            let data = try file.encoded()
            let json = try #require(String(data: data, encoding: .utf8))
            #expect(!json.contains("distanceFromHomeKm") && !json.contains("temporaryHome"))
            let shared = try #require(try TripShareFile.decode(data).trips.first)
            #expect(shared.shareID == senderTripID)
            #expect(shared.customName == "Coast Weekend")
            #expect(shared.visits.count == 1)
            // Nothing from the sender's home leaves.
            #expect(shared.pings.allSatisfy { Self.km($0.latitude, $0.longitude, Self.harborview) > 50 })
            #expect(shared.stays.allSatisfy { Self.km($0.latitude, $0.longitude, Self.harborview) > 50 })
            #expect(Set(shared.pings.map(\.id)).isSubset(of: senderBayviewPingIDs))

            // Recipient: lives in Riverton, has nothing of their own then.
            let recipient = try ShareHarness()
            defer { recipient.tearDown() }
            try await recipient.addHome("Home", Self.riverton, startedAt: Self.at(-24 * 365))
            let outcome = try await SharedTripImporter.importTrip(
                shared, senderName: file.senderName, environment: recipient.environment)

            let visitIDs = SharedTripImportPlan.evidence(of: shared).map(\.id).filter { id in
                !shared.pings.contains { $0.id == id }
            }
            #expect(visitIDs.count == 2)
            #expect(outcome.inserted == shared.pings.count + 2)
            #expect(!outcome.saveFailed && !outcome.processingFailed)
            let stored = recipient.pings()
            #expect(stored.allSatisfy { $0.source == .sharedImport })
            // Sender UUIDs survive; the Visit arrives as its two derived fixes.
            #expect(Set(stored.map(\.id)) == Set(shared.pings.map(\.id)).union(visitIDs))
            #expect(recipient.visits().isEmpty)
            // The pipeline made one trip of them, carrying the sender's name.
            let holders = try await recipient.store.tripsHolding(pingIDs: Set(stored.map(\.id)))
            #expect(holders.count == 1)
            let trip = try #require(recipient.trips().first { holders.contains($0.id) })
            #expect(trip.customName == "Coast Weekend")
            #expect(outcome.namedTripID == trip.id)
            #expect(!trip.userEdited)
            // A shared stay is never a home boundary, nor a home stay.
            #expect(recipient.stays().allSatisfy { $0.category != .home })
            let record = try #require(try SharedTripLedger.record(for: shared.shareID, in: recipient.ledgerDirectory))
            #expect(Set(record.insertedPingIDs) == Set(stored.map(\.id)))
            #expect(record.pendingPingIDs.isEmpty)
            #expect(record.senderName == "Sam")
        }
    }

    // MARK: - Own evidence wins

    @Test("the recipient's own fixes, stays and homes win over shared ones", .timeLimit(.minutes(2)))
    func ownEvidenceWins() async throws {
        try await Self.withoutFM {
            let recipient = try ShareHarness()
            defer { recipient.tearDown() }
            try await recipient.addHome("Home", Self.riverton, startedAt: Self.at(-24 * 365))
            // Their own Bayview day, hours 30 to 36.
            let own = recipient.insertOwnPings(Self.track(Self.bayview, from: 30, to: 36))
            await recipient.runPipeline()
            let ownStays = Set(recipient.stays().map(\.id))

            // Shared: two fixes in the recipient's home town, then Bayview
            // hours 20 to 60.
            let shared = Self.sharedTrip(fixes: [(Self.riverton, 2), (Self.riverton, 3)]
                + Self.track(Self.bayview, from: 20, to: 60))
            let outcome = try await SharedTripImporter.importTrip(
                shared, senderName: nil, environment: recipient.environment)

            #expect(outcome.droppedInsideHome == 2)
            let pad = SharedTripImportPlan.ownEvidencePadding / 3600
            let expectedDropped = Self.track(Self.bayview, from: 20, to: 60)
                .filter { $0.1 >= 30 - pad && $0.1 <= 36 + pad }.count
            #expect(outcome.droppedForOwnEvidence == expectedDropped)
            #expect(outcome.inserted == shared.pings.count - 2 - expectedDropped)

            let sharedPings = recipient.pings().filter { $0.source == .sharedImport }
            #expect(sharedPings.count == outcome.inserted)
            for ping in sharedPings {
                let hours = ping.timestamp.timeIntervalSince(Self.base) / 3600
                #expect(hours < 30 - pad || hours > 36 + pad)
                #expect(Self.km(ping.latitude, ping.longitude, Self.riverton) > 50)
            }
            // Their own fixes and stays are untouched: no stay mixes the two.
            let ownIDs = Set(own)
            #expect(Set(recipient.pings().filter { $0.source != .sharedImport }.map(\.id)) == ownIDs)
            let sharedIDs = Set(sharedPings.map(\.id))
            for stay in recipient.stays() {
                let ids = Set(stay.pingIDs)
                #expect(ids.isSubset(of: ownIDs) || ids.isSubset(of: sharedIDs))
                if ownStays.contains(stay.id) { #expect(ids.isSubset(of: ownIDs)) }
            }
        }
    }

    // MARK: - Re-import

    @Test("re-importing adds only new evidence and follows the sender's name until the user renames",
          .timeLimit(.minutes(2)))
    func reimportIsIdempotent() async throws {
        try await Self.withoutFM {
            let recipient = try ShareHarness()
            defer { recipient.tearDown() }
            try await recipient.addHome("Home", Self.riverton, startedAt: Self.at(-24 * 365))
            let shareID = UUID()
            let first = Self.sharedTrip(id: shareID, fixes: Self.track(Self.bayview, from: 20, to: 50))
            let initial = try await SharedTripImporter.importTrip(first, senderName: "Sam", environment: recipient.environment)
            #expect(initial.inserted == first.pings.count)
            let pingsAfterFirst = Set(recipient.pings().map(\.id))
            let tripsAfterFirst = recipient.trips().map(\.id)

            // The same file again: nothing new, nothing duplicated.
            let again = try await SharedTripImporter.importTrip(first, senderName: "Sam", environment: recipient.environment)
            #expect(again.inserted == 0)
            #expect(again.alreadyPresent == first.pings.count)
            #expect(Set(recipient.pings().map(\.id)) == pingsAfterFirst)
            #expect(recipient.trips().map(\.id) == tripsAfterFirst)
            #expect(try SharedTripLedger.load(in: recipient.ledgerDirectory).count == 1)

            // The sender re-shares an updated trip: more fixes, a new name.
            var updated = first
            updated.customName = "Coast Long Weekend"
            let extra = Self.sharedTrip(id: shareID, fixes: Self.track(Self.bayview, from: 50.5, to: 60)).pings
            updated.pings += extra
            let update = try await SharedTripImporter.importTrip(updated, senderName: "Sam", environment: recipient.environment)
            #expect(update.inserted == extra.count)
            #expect(recipient.pings().count == pingsAfterFirst.count + extra.count)
            let holders = try await recipient.store.tripsHolding(pingIDs: Set(recipient.pings().map(\.id)))
            #expect(holders.count == 1)
            let trip = try #require(recipient.trips().first { holders.contains($0.id) })
            #expect(trip.customName == "Coast Long Weekend")
            let record = try #require(try SharedTripLedger.record(for: shareID, in: recipient.ledgerDirectory))
            #expect(record.insertedPingIDs.count == first.pings.count + extra.count)

            // The user renames it; a later re-share never overwrites that.
            trip.customName = "Our Trip"
            trip.userEdited = true
            try recipient.tripsContext.save()
            updated.customName = "Coast Weekend Again"
            _ = try await SharedTripImporter.importTrip(updated, senderName: "Sam", environment: recipient.environment)
            let renamed = try #require(recipient.trips().first { $0.id == trip.id })
            #expect(renamed.customName == "Our Trip")
        }
    }

    // MARK: - Partial overlap

    @Test("a share that overlaps the recipient's own trip extends it into one trip", .timeLimit(.minutes(2)))
    func partialOverlapMergesIntoOneTrip() async throws {
        try await Self.withoutFM {
            let recipient = try ShareHarness()
            defer { recipient.tearDown() }
            try await recipient.addHome("Home", Self.riverton, startedAt: Self.at(-24 * 365))
            // Their own trip: home, Bayview for a day and a half, home.
            recipient.insertOwnPings(Self.track(Self.riverton, from: 0, to: 8))
            let ownBayview = recipient.insertOwnPings(Self.track(Self.bayview, from: 14, to: 50))
            recipient.insertOwnPings(Self.track(Self.riverton, from: 110, to: 120))
            await recipient.runPipeline()
            let ownTrips = recipient.trips().filter { trip in
                (trip.stays ?? []).contains { Set($0.pingIDs).isSubset(of: Set(ownBayview)) && !$0.pingIDs.isEmpty }
            }
            #expect(ownTrips.count == 1)
            let ownTripID = try #require(ownTrips.first?.id)

            // The share covers the same Bayview days, then Cliffside.
            let shared = Self.sharedTrip(fixes: Self.track(Self.bayview, from: 14, to: 50)
                + Self.track(Self.cliffside, from: 60, to: 100))
            let outcome = try await SharedTripImporter.importTrip(shared, senderName: "Sam", environment: recipient.environment)
            #expect(outcome.droppedForOwnEvidence > 0)
            #expect(outcome.inserted > 0)

            let sharedIDs = Set(recipient.pings().filter { $0.source == .sharedImport }.map(\.id))
            let holders = try await recipient.store.tripsHolding(pingIDs: sharedIDs)
            #expect(holders.count == 1)
            // One trip holds the recipient's Bayview and the shared Cliffside.
            let travelTrips = recipient.trips().filter { !($0.stays ?? []).isEmpty }
            #expect(travelTrips.count == 1)
            let merged = try #require(travelTrips.first)
            let stays = merged.stays ?? []
            #expect(stays.contains { Self.km($0.centroidLatitude, $0.centroidLongitude, Self.bayview) < 5 })
            #expect(stays.contains { Self.km($0.centroidLatitude, $0.centroidLongitude, Self.cliffside) < 5 })
            #expect(holders == [merged.id])
            _ = ownTripID
        }
    }

    // MARK: - Undo

    @Test("Remove Shared Data deletes exactly the rows the share added", .timeLimit(.minutes(2)))
    func undoRemovesExactlyImportedRows() async throws {
        try await Self.withoutFM {
            let recipient = try ShareHarness()
            defer { recipient.tearDown() }
            try await recipient.addHome("Home", Self.riverton, startedAt: Self.at(-24 * 365))
            recipient.insertOwnPings(Self.track(Self.riverton, from: 0, to: 8))
            let ownBayview = recipient.insertOwnPings(Self.track(Self.bayview, from: 14, to: 50))
            recipient.insertOwnPings(Self.track(Self.riverton, from: 110, to: 120))
            await recipient.runPipeline()
            let ownPingIDs = Set(recipient.pings().map(\.id))
            let ownStaysBefore = recipient.stays().filter { !Set($0.pingIDs).isDisjoint(with: Set(ownBayview)) }
                .map { ($0.id, $0.startTime, $0.endTime, Set($0.pingIDs)) }

            // A second share elsewhere in time, which must survive.
            let other = Self.sharedTrip(name: "Hill Days", fixes: Self.track(Self.cliffside, from: 400, to: 430))
            _ = try await SharedTripImporter.importTrip(other, senderName: "Alex", environment: recipient.environment)
            let otherIDs = Set(recipient.pings().filter { $0.source == .sharedImport }.map(\.id))
            #expect(otherIDs.count == other.pings.count)

            let shared = Self.sharedTrip(fixes: Self.track(Self.bayview, from: 14, to: 50)
                + Self.track(Self.cliffside, from: 60, to: 100),
                visits: [(Self.cliffside, 70.25, 80.25)])
            let outcome = try await SharedTripImporter.importTrip(shared, senderName: "Sam", environment: recipient.environment)
            #expect(outcome.inserted > 0)
            let record = try #require(try SharedTripLedger.record(for: shared.shareID, in: recipient.ledgerDirectory))
            let imported = Set(record.insertedPingIDs)
            #expect(imported.count == outcome.inserted)
            #expect(imported.isDisjoint(with: otherIDs))

            try await SharedTripImporter.removeSharedData(shareID: shared.shareID, environment: recipient.environment)

            let remaining = Set(recipient.pings().map(\.id))
            #expect(remaining == ownPingIDs.union(otherIDs))
            #expect(remaining.isDisjoint(with: imported))
            #expect(try SharedTripLedger.record(for: shared.shareID, in: recipient.ledgerDirectory) == nil)
            #expect(try SharedTripLedger.record(for: other.shareID, in: recipient.ledgerDirectory) != nil)
            // No stay still points at a removed fix.
            for stay in recipient.stays() { #expect(Set(stay.pingIDs).isDisjoint(with: imported)) }
            // Their own Bayview stays come back as they were.
            let ownStaysAfter = recipient.stays().filter { !Set($0.pingIDs).isDisjoint(with: Set(ownBayview)) }
                .map { ($0.id, $0.startTime, $0.endTime, Set($0.pingIDs)) }
            #expect(ownStaysAfter.map { $0.3 } == ownStaysBefore.map { $0.3 })
            #expect(ownStaysAfter.map { $0.1 } == ownStaysBefore.map { $0.1 })
            #expect(ownStaysAfter.map { $0.2 } == ownStaysBefore.map { $0.2 })
            // The sender's name left with their evidence.
            #expect(!recipient.trips().contains { $0.customName == "Coast Weekend" })
            #expect(recipient.trips().contains { $0.customName == "Hill Days" })

            // Removing again finds nothing.
            await #expect(throws: SharedTripImporter.RemovalError.notFound) {
                try await SharedTripImporter.removeSharedData(shareID: shared.shareID, environment: recipient.environment)
            }
        }
    }

    static func km(_ lat: Double, _ lon: Double, _ place: Place) -> Double {
        TripShareExport.haversineKm(lat, lon, place.lat, place.lon)
    }
}

/// One in-memory store with its own pipeline actors, test gate and ledger.
@MainActor
final class ShareHarness {
    let container: ModelContainer
    let context: ModelContext
    let recorder: PingRecorder
    let clusterer: StayClusterer
    let classifier: TripClassifier
    let store: SharedTripStore
    let gate = PipelineGate(forTesting: ())
    let ledgerDirectory: URL

    init() throws {
        container = try TestSupport.makeInMemoryContainer()
        context = ModelContext(container)
        tripsContext = ModelContext(container)
        recorder = PingRecorder(modelContainer: container)
        clusterer = StayClusterer(modelContainer: container)
        classifier = TripClassifier(modelContainer: container)
        store = SharedTripStore(modelContainer: container)
        ledgerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedTripLedger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ledgerDirectory, withIntermediateDirectories: true)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: ledgerDirectory)
    }

    var environment: SharedTripImporter.Environment {
        let clusterer = self.clusterer
        let classifier = self.classifier
        let gate = self.gate
        return SharedTripImporter.Environment(
            recorder: recorder,
            store: store,
            homeRings: { try await classifier.sharingHomeRings() },
            gate: gate,
            stages: ExternalHistoryImporter.Stages(
                cluster: {
                    _ = await clusterer.clusterUnprocessedPings()
                    return true
                },
                classify: {
                    await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                        reclassifyRecentStays: false, maxStaysPerCall: nil, gate: gate,
                        waitingForInFlight: false
                    ).completed
                },
                generateTitles: {},
                reloadWidgets: {}),
            ledgerDirectory: ledgerDirectory,
            afterRemoval: { _, _ in })
    }

    func addHome(_ label: String, _ place: SharedTripImportTests.Place, startedAt: Date) async throws {
        let resolved = await GeocodeResolver.shared.resolve(latitude: place.lat, longitude: place.lon)
        let home = Home(label: label, latitude: place.lat, longitude: place.lon, radiusKm: 25, startedAt: startedAt)
        home.locality = resolved?.localityForStorage
        home.administrativeArea = resolved?.administrativeArea
        home.country = resolved?.country
        home.isoCountryCode = resolved?.isoCountryCode
        context.insert(home)
        try context.save()
        TripTitleStore.invalidateHomePlaceIndex()
    }

    /// The user's own live fixes, unprocessed, as acquisition leaves them.
    @discardableResult
    func insertOwnPings(_ fixes: [(SharedTripImportTests.Place, Double)]) -> [UUID] {
        var ids: [UUID] = []
        for (place, hours) in fixes {
            let ping = LocationPing(
                timestamp: SharedTripImportTests.at(hours), latitude: place.lat, longitude: place.lon,
                horizontalAccuracy: 30,
                h3IndexRes6: H3Service.cellIndex(latitude: place.lat, longitude: place.lon) ?? "",
                source: .liveSLC)
            context.insert(ping)
            ids.append(ping.id)
        }
        try? context.save()
        return ids
    }

    func runPipeline() async {
        _ = await clusterer.clusterUnprocessedPings()
        _ = await classifier.classifyAndAssembleTripsWithGates(
            reclassifyRecentStays: false, maxStaysPerCall: nil, gate: gate)
    }

    private func fresh() -> ModelContext { ModelContext(container) }

    func pings() -> [LocationPing] { (try? fresh().fetch(FetchDescriptor<LocationPing>())) ?? [] }
    func stays() -> [Stay] {
        (try? fresh().fetch(FetchDescriptor<Stay>(sortBy: [SortDescriptor(\.startTime)]))) ?? []
    }
    func visits() -> [Visit] { (try? fresh().fetch(FetchDescriptor<Visit>())) ?? [] }
    /// The context the last `trips()` read on, so a test can edit and save them.
    private(set) var tripsContext: ModelContext

    func trips() -> [Trip] {
        tripsContext = fresh()
        return (try? tripsContext.fetch(FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.startDate)]))) ?? []
    }
}
