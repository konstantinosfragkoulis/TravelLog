//
//  VisitRecorder.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 2/9/26.
//

import CoreLocation
import Foundation
import SwiftData
import os.log

@ModelActor
actor VisitRecorder {

    nonisolated static let acceptanceFloorKey = "visitAcceptanceFloor"

    private let logger = Logger(subsystem: "com.travellog.app", category: "VisitRecorder")

    /// What one callback did to the store.
    nonisolated enum Outcome: Equatable, Sendable {
        /// Inserted or closed a Visit row.
        case recorded
        /// Rejected by validation or the acceptance floor, or ignored as a
        /// redelivery or a callback an existing row already supersedes.
        case ignored
        /// A required read or save failed and rolled back; the observation is
        /// owed to a retry.
        case failed
    }

    /// Most failed observations kept for retry.
    nonisolated static let retryCapacity = 32

    /// Validated observations whose read or save failed. Deliberately
    /// actor-local and unpersisted, like the live-ping retry buffer: a failed
    /// transaction rolls back, so this buffer is the only owner of the
    /// callback, and bounded drop-oldest retention keeps a long storage outage
    /// from growing memory. Every retry passes the acceptance floor again, so
    /// a wipe committed meanwhile revokes what it covers.
    private var failedObservations: [VisitObservation] = []

    #if DEBUG
    /// Required-read or save faults the next attempts throw, in order.
    nonisolated enum Fault: Sendable { case read, save }
    private var faultsForTesting: [Fault] = []

    func setFaultsForTesting(_ faults: [Fault]) { faultsForTesting = faults }

    var failedObservationCountForTesting: Int { failedObservations.count }

    private func injectFault(_ fault: Fault) throws {
        guard faultsForTesting.first == fault else { return }
        faultsForTesting.removeFirst()
        throw CocoaError(fault == .read ? .fileReadUnknown : .fileWriteUnknown)
    }
    #endif

    /// Records one callback after replaying, in arrival order, every earlier
    /// one a failed transaction left owed, so an open Visit lands before the
    /// callback that closes it.
    @discardableResult
    func record(_ observation: VisitObservation, defaults: UserDefaults = .standard) -> Outcome {
        retryFailedObservations(defaults: defaults)
        let outcome = attempt(observation, defaults: defaults)
        if outcome == .failed { retain([observation]) }
        return outcome
    }

    /// Replays the owed observations; returns true when one of them changed
    /// the store. Cheap when nothing is owed.
    @discardableResult
    func retryFailedObservations(defaults: UserDefaults = .standard) -> Bool {
        guard !failedObservations.isEmpty else { return false }
        let owed = failedObservations
        failedObservations.removeAll()
        var stillOwed: [VisitObservation] = []
        var recorded = false
        for observation in owed {
            switch attempt(observation, defaults: defaults) {
            case .recorded: recorded = true
            case .ignored: break
            case .failed: stillOwed.append(observation)
            }
        }
        retain(stillOwed)
        if !stillOwed.isEmpty {
            logger.error("\(stillOwed.count) visit callback(s) still owed after a retry.")
        }
        return recorded
    }

    private func retain(_ observations: [VisitObservation]) {
        failedObservations = Array(
            (failedObservations + observations).suffix(Self.retryCapacity))
    }

    private func attempt(_ observation: VisitObservation, defaults: UserDefaults) -> Outcome {
        // Every callback leaves one line, accepted or not: with only the
        // rejection notices below, a healthy first visit would be invisible
        // in the console.
        logger.notice("Visit callback: arrival \(observation.arrivalDate.map { "\($0)" } ?? "none"), departure \(observation.departureDate.map { "\($0)" } ?? "open"), accuracy \(observation.horizontalAccuracy, format: .fixed(precision: 0)) m.")
        guard !observation.arrivalWasDistantPast,
              let arrival = observation.arrivalDate else {
            logger.notice("Rejected visit: arrival is missing or distant past.")
            return .ignored
        }
        guard observation.latitude.isFinite,
              (-90...90).contains(observation.latitude) else {
            logger.notice("Rejected visit: latitude is invalid.")
            return .ignored
        }
        guard observation.longitude.isFinite,
              (-180...180).contains(observation.longitude) else {
            logger.notice("Rejected visit: longitude is invalid.")
            return .ignored
        }
        guard observation.horizontalAccuracy >= 0,
              observation.horizontalAccuracy < 5000 else {
            logger.notice("Rejected visit: horizontal accuracy is invalid.")
            return .ignored
        }
        guard arrival <= observation.receivedAt.addingTimeInterval(300) else {
            logger.notice("Rejected visit: arrival is too far in the future.")
            return .ignored
        }
        if let departure = observation.departureDate {
            guard departure > arrival else {
                logger.notice("Rejected visit: departure does not follow arrival.")
                return .ignored
            }
            guard departure <= observation.receivedAt.addingTimeInterval(300) else {
                logger.notice("Rejected visit: departure is too far in the future.")
                return .ignored
            }
        }

        let acceptanceFloor = defaults.object(
            forKey: Self.acceptanceFloorKey
        ) as? Date
        if let acceptanceFloor, arrival < acceptanceFloor {
            logger.notice("Rejected visit: arrival precedes the acceptance floor.")
            return .ignored
        }

        let lowerBound = arrival.addingTimeInterval(-1)
        let upperBound = arrival.addingTimeInterval(1)
        let predicate = #Predicate<Visit> {
            $0.arrivalDate >= lowerBound && $0.arrivalDate <= upperBound
        }
        let candidates: [Visit]
        do {
            #if DEBUG
            try injectFault(.read)
            #endif
            candidates = try modelContext.fetch(
                FetchDescriptor<Visit>(predicate: predicate))
        } catch {
            logger.error("Visit candidate fetch failed; the callback stays owed: \(error.localizedDescription)")
            return .failed
        }

        let incomingLocation = CLLocation(
            latitude: observation.latitude,
            longitude: observation.longitude)
        let compatible = candidates.filter { visit in
            guard Self.sameDateBits(visit.arrivalDate, arrival) else {
                return false
            }
            let persistedLocation = CLLocation(
                latitude: visit.latitude,
                longitude: visit.longitude)
            return incomingLocation.distance(from: persistedLocation) <= 3000
        }
        let existing = compatible.min { lhs, rhs in
            let lhsClosed = lhs.departureDate != nil
            let rhsClosed = rhs.departureDate != nil
            if lhsClosed != rhsClosed { return lhsClosed }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        guard let existing else {
            modelContext.insert(Visit(
                arrivalDate: arrival,
                departureDate: observation.departureDate,
                latitude: observation.latitude,
                longitude: observation.longitude,
                horizontalAccuracy: observation.horizontalAccuracy,
                receivedAt: observation.receivedAt,
                isProcessed: false))
            do {
                #if DEBUG
                try injectFault(.save)
                #endif
                try modelContext.save()
                logger.notice("Recorded \(observation.departureDate == nil ? "open" : "closed") visit arriving \(arrival).")
                return .recorded
            } catch {
                modelContext.rollback()
                logger.error("Visit insert save failed; the callback stays owed: \(error.localizedDescription)")
                return .failed
            }
        }

        let payloadMatches = Self.sameDateBits(
            existing.arrivalDate, observation.arrivalDate)
            && Self.sameDateBits(
                existing.departureDate, observation.departureDate)
            && existing.latitude.bitPattern == observation.latitude.bitPattern
            && existing.longitude.bitPattern == observation.longitude.bitPattern
            && existing.horizontalAccuracy.bitPattern
                == observation.horizontalAccuracy.bitPattern
        if payloadMatches {
            logger.debug("Ignored exact visit redelivery.")
            return .ignored
        }

        if existing.departureDate == nil,
           let departure = observation.departureDate {
            existing.departureDate = departure
            existing.receivedAt = observation.receivedAt
            existing.isProcessed = false
            if observation.horizontalAccuracy < existing.horizontalAccuracy {
                existing.latitude = observation.latitude
                existing.longitude = observation.longitude
                existing.horizontalAccuracy = observation.horizontalAccuracy
            }
            do {
                #if DEBUG
                try injectFault(.save)
                #endif
                try modelContext.save()
                logger.notice("Closed visit arriving \(arrival) with departure \(departure).")
                return .recorded
            } catch {
                modelContext.rollback()
                logger.error("Visit update save failed; the callback stays owed: \(error.localizedDescription)")
                return .failed
            }
        }

        if existing.departureDate == nil {
            logger.notice("Ignored differing open callback for an open visit.")
        } else if observation.departureDate == nil {
            logger.notice("Ignored open callback for a closed visit.")
        } else {
            logger.notice("Ignored differing closed callback for a closed visit.")
        }
        return .ignored
    }

    private nonisolated static func sameDateBits(
        _ lhs: Date?,
        _ rhs: Date?
    ) -> Bool {
        lhs?.timeIntervalSinceReferenceDate.bitPattern
            == rhs?.timeIntervalSinceReferenceDate.bitPattern
    }
}
