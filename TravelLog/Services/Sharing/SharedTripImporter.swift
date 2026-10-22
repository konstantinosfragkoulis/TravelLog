//
//  SharedTripImporter.swift
//  TravelLog
//
//  Recipient side, the spine. Called only after the user answers Yes to
//  "Were you on this trip?":
//    1. read this user's home rings and own evidence (outside any gate);
//    2. admit the fixes `SharedTripImportPlan` allows;
//    3. record them in bounded `PipelineGate.shared` units, ledger first,
//       each admitting its fixes again against the own evidence and home
//       areas the store holds by then (rings reread before each unit);
//    4. run the ordinary pipeline (cluster, summaries, classify) the way the
//       Timeline and GPX imports do, each stage owning its own gates;
//    5. in one more unit, carry the sender's name onto the one trip that
//       holds the shared stays, if the user has not named it.
//  Removal deletes the ledger's rows in one unit and runs the pipeline again.
//  Gates are never nested and no model crosses an actor.
//

import Foundation
import SwiftData
import WidgetKit
import os.log

@MainActor
enum SharedTripImporter {

    private static let logger = Logger(subsystem: "com.travellog.app", category: "SharedTripImporter")

    struct Environment {
        var recorder: PingRecorder
        var store: SharedTripStore
        var homeRings: @MainActor @Sendable () async throws -> [TripClassifier.HomeRing]
        var gate: PipelineGate
        var stages: ExternalHistoryImporter.Stages
        /// Nil: the ledger in Application Support.
        var ledgerDirectory: URL?
        /// After a removal commits: the process-wide caches that described
        /// the deleted rows (Removed Trips records, the Stats snapshot).
        var afterRemoval: @MainActor @Sendable (_ store: SharedTripStore, _ deletedStayIDs: Set<UUID>) async -> Void

        static var live: Environment {
            Environment(
                recorder: AppDelegate.pingRecorder,
                store: SharedTripStore(modelContainer: AppDelegate.modelContainer),
                homeRings: { try await AppDelegate.tripClassifier.sharingHomeRings() },
                gate: .shared,
                stages: .live,
                ledgerDirectory: nil,
                afterRemoval: { store, deletedStayIDs in
                    if !deletedStayIDs.isEmpty {
                        await store.cleanDissolvedRecords(deletedStayIDs: deletedStayIDs)
                    }
                    _ = StatsSnapshotStore.clear()
                })
        }
    }

    struct Outcome: Sendable, Equatable {
        var inserted = 0
        var droppedForOwnEvidence = 0
        var droppedInsideHome = 0
        var alreadyPresent = 0
        /// A unit failed to save; fixes from earlier units stay recorded.
        var saveFailed = false
        /// Clustering or classification did not finish.
        var processingFailed = false
        var namedTripID: UUID?
    }

    enum ImportError: Error, Equatable {
        case busy
        case homesUnreadable
        case evidenceUnreadable
        case ledgerUnavailable
    }

    static let batchSize = 500
    /// Rings read for one unit before giving up while Homes keep changing.
    static let homeReadAttempts = 3
    private(set) static var isRunning = false

    static func importTrip(
        _ trip: SharedTrip, senderName: String?, environment: Environment = .live
    ) async throws(ImportError) -> Outcome {
        // One import spine at a time: each clears and reads the recorder's
        // affected-trip set, so a Timeline or GPX import must finish first.
        guard !isRunning, !ExternalHistoryImporter.isImportRunning else { throw .busy }
        isRunning = true
        defer { isRunning = false }

        let rings: [TripClassifier.HomeRing]
        do { rings = try await environment.homeRings() } catch { throw .homesUnreadable }
        let evidence = SharedTripImportPlan.evidence(of: trip)
        var outcome = Outcome()
        let admission: SharedTripImportPlan.Admission
        do {
            if let first = evidence.first?.timestamp, let last = evidence.last?.timestamp {
                let own = try await environment.store.ownEvidenceIntervals(
                    from: first, to: last, padding: SharedTripImportPlan.ownEvidencePadding)
                let existing = try await environment.store.existingPingIDs(evidence.map(\.id))
                admission = SharedTripImportPlan.admit(
                    evidence, ownEvidence: own, rings: rings, existingIDs: existing)
            } else {
                admission = .init()
            }
        } catch {
            throw .evidenceUnreadable
        }
        outcome.droppedForOwnEvidence = admission.droppedForOwnEvidence
        outcome.droppedInsideHome = admission.droppedInsideHome
        outcome.alreadyPresent = admission.alreadyPresent

        let shareID = trip.shareID
        let title = trip.displayTitle()
        let directory = environment.ledgerDirectory
        let previous: SharedTripLedger.Record?
        do {
            try SharedTripLedger.markPending([], shareID: shareID, title: title, senderName: senderName, in: directory)
            previous = try SharedTripLedger.record(for: shareID, in: directory)
        } catch {
            throw .ledgerUnavailable
        }

        await ExternalHistoryImporter.whileImportRunning {
            await environment.recorder.clearAffectedTripIDs()
            await environment.recorder.resetLastImportedH3Index()
            var index = 0
            let admitted = admission.admitted
            while index < admitted.count {
                let batch = admitted[index..<min(index + batchSize, admitted.count)].map {
                    ImportedPingCandidate(
                        timestamp: $0.timestamp, latitude: $0.latitude, longitude: $0.longitude,
                        horizontalAccuracy: $0.horizontalAccuracy,
                        altitude: $0.altitude, verticalAccuracy: $0.verticalAccuracy, id: $0.id)
                }
                index += batch.count
                let attempted = batch.compactMap(\.id)
                // Pending before the unit, so no committed row escapes the ledger.
                do {
                    try SharedTripLedger.markPending(attempted, shareID: shareID, title: title,
                                                     senderName: senderName, in: directory)
                } catch {
                    outcome.saveFailed = true
                    break
                }
                let recorder = environment.recorder
                // Own evidence and home areas can change after admission:
                // the unit admits its fixes again, against rings read after
                // a digest it compares, and a moved digest reads them again.
                var unit: SharedUnitOutcome?
                for _ in 0..<Self.homeReadAttempts {
                    guard let digest = try? await recorder.sharedImportHomeDigest(),
                          let rings = try? await environment.homeRings() else { break }
                    unit = await environment.gate.runReturning(
                        touching: [.locationPing, .hexVisit, .stay, .trip]
                    ) {
                        try? await recorder.recordSharedPings(batch, rings: rings, homeDigest: digest)
                    }
                    if unit?.homesChanged != true { break }
                }
                guard let unit, !unit.homesChanged else {
                    outcome.saveFailed = true
                    break
                }
                outcome.inserted += unit.inserted.count
                outcome.droppedForOwnEvidence += unit.droppedForOwnEvidence
                outcome.droppedInsideHome += unit.droppedInsideHome
                try? SharedTripLedger.commit(inserted: unit.inserted, attempted: attempted,
                                             shareID: shareID, in: directory)
            }

            // Also after a failed unit: committed fixes must not wait unclustered.
            let clustered = await environment.stages.cluster()
            let recorder = environment.recorder
            await environment.gate.run(touching: [.trip]) {
                await recorder.recomputeAffectedTripSummaries()
            }
            let classified = await environment.stages.classify()
            outcome.processingFailed = !clustered || !classified
        }

        // The sender's name, once the pipeline has placed the shared stays.
        if let record = try? SharedTripLedger.record(for: shareID, in: directory) {
            let store = environment.store
            let name = trip.customName
            let ids = Set(record.insertedPingIDs)
            let applied = previous?.appliedName
            let previousTripID = previous?.namedTripID
            let carried = await environment.gate.runReturning(touching: [.trip]) {
                try? await store.carrySenderName(
                    name, pingIDs: ids, previouslyApplied: applied, previousTripID: previousTripID)
            }
            if let carried {
                try? SharedTripLedger.setAppliedName(
                    carried.appliedName, tripID: carried.tripID, shareID: shareID, in: directory)
                outcome.namedTripID = carried.appliedName == nil ? nil : carried.tripID
            }
        }
        try? SharedTripLedger.removeIfEmpty(shareID: shareID, in: directory)

        await environment.stages.generateTitles()
        environment.stages.reloadWidgets()
        logger.info("Shared trip import: \(outcome.inserted) inserted, \(outcome.droppedForOwnEvidence) beside own evidence, \(outcome.droppedInsideHome) in home areas, \(outcome.alreadyPresent) already present.")
        return outcome
    }

    enum RemovalError: Error, Equatable {
        case busy
        case ledgerUnavailable
        case notFound
        case saveFailed
    }

    /// "Remove Shared Data": deletes exactly the rows the share added and
    /// rebuilds the trips around them through the ordinary pipeline.
    static func removeSharedData(
        shareID: UUID, environment: Environment = .live
    ) async throws(RemovalError) {
        // One import spine at a time: each clears and reads the recorder's
        // affected-trip set, so a Timeline or GPX import must finish first.
        guard !isRunning, !ExternalHistoryImporter.isImportRunning else { throw .busy }
        isRunning = true
        defer { isRunning = false }
        let directory = environment.ledgerDirectory
        let record: SharedTripLedger.Record
        do {
            guard let found = try SharedTripLedger.record(for: shareID, in: directory) else { throw RemovalError.notFound }
            record = found
        } catch let error as RemovalError {
            throw error
        } catch {
            throw .ledgerUnavailable
        }
        // Ids another share also inserted stay theirs.
        let others = ((try? SharedTripLedger.load(in: directory)) ?? [])
            .filter { $0.shareID != shareID }
            .reduce(into: Set<UUID>()) { $0.formUnion($1.insertedPingIDs) }
        let ids = record.allPingIDs.subtracting(others)
        let store = environment.store
        let applied = record.appliedName
        let namedTripID = record.namedTripID
        let removal = await ExternalHistoryImporter.whileImportRunning {
            await environment.gate.runReturning(touching: [.locationPing, .hexVisit, .stay, .trip]) {
                try? await store.removeSharedEvidence(
                    pingIDs: ids, appliedName: applied, namedTripID: namedTripID)
            }
        }
        guard let removal else { throw .saveFailed }
        do { try SharedTripLedger.remove(shareID: shareID, in: directory) } catch {
            logger.error("Shared trip ledger entry kept after removal: \(error.localizedDescription)")
        }
        await environment.afterRemoval(environment.store, removal.deletedStayIDs)
        _ = await environment.stages.cluster()
        _ = await environment.stages.classify()
        await environment.stages.generateTitles()
        environment.stages.reloadWidgets()
    }
}

extension SharedTripStore {
    /// Drops Removed Trips records that pointed at the stays a removal
    /// deleted, as the photo discard does. Best effort, after the commit.
    func cleanDissolvedRecords(deletedStayIDs: Set<UUID>) {
        do {
            let stays = try Set(modelContext.fetch(FetchDescriptor<Stay>()).map(\.id))
            let trips = try Set(modelContext.fetch(FetchDescriptor<Trip>()).map(\.id))
            try DissolvedTripQueue.removeRecords(
                deletedStayIDs: deletedStayIDs, remainingStayIDs: stays, remainingTripIDs: trips)
        } catch {
            Logger(subsystem: "com.travellog.app", category: "SharedTripStore")
                .error("Removed Trips cleanup after shared removal failed: \(error.localizedDescription)")
        }
    }
}
