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

    func record(_ observation: VisitObservation, defaults: UserDefaults = .standard) {
        // Every callback leaves one line, accepted or not: with only the
        // rejection notices below, a healthy first visit would be invisible
        // in the console.
        logger.notice("Visit callback: arrival \(observation.arrivalDate.map { "\($0)" } ?? "none"), departure \(observation.departureDate.map { "\($0)" } ?? "open"), accuracy \(observation.horizontalAccuracy, format: .fixed(precision: 0)) m.")
        guard !observation.arrivalWasDistantPast,
              let arrival = observation.arrivalDate else {
            logger.notice("Rejected visit: arrival is missing or distant past.")
            return
        }
        guard observation.latitude.isFinite,
              (-90...90).contains(observation.latitude) else {
            logger.notice("Rejected visit: latitude is invalid.")
            return
        }
        guard observation.longitude.isFinite,
              (-180...180).contains(observation.longitude) else {
            logger.notice("Rejected visit: longitude is invalid.")
            return
        }
        guard observation.horizontalAccuracy >= 0,
              observation.horizontalAccuracy < 5000 else {
            logger.notice("Rejected visit: horizontal accuracy is invalid.")
            return
        }
        guard arrival <= observation.receivedAt.addingTimeInterval(300) else {
            logger.notice("Rejected visit: arrival is too far in the future.")
            return
        }
        if let departure = observation.departureDate {
            guard departure > arrival else {
                logger.notice("Rejected visit: departure does not follow arrival.")
                return
            }
            guard departure <= observation.receivedAt.addingTimeInterval(300) else {
                logger.notice("Rejected visit: departure is too far in the future.")
                return
            }
        }

        let acceptanceFloor = defaults.object(
            forKey: Self.acceptanceFloorKey
        ) as? Date
        if let acceptanceFloor, arrival < acceptanceFloor {
            logger.notice("Rejected visit: arrival precedes the acceptance floor.")
            return
        }

        let lowerBound = arrival.addingTimeInterval(-1)
        let upperBound = arrival.addingTimeInterval(1)
        let predicate = #Predicate<Visit> {
            $0.arrivalDate >= lowerBound && $0.arrivalDate <= upperBound
        }
        let candidates: [Visit]
        do {
            candidates = try modelContext.fetch(
                FetchDescriptor<Visit>(predicate: predicate))
        } catch {
            logger.error("Rejected visit: candidate fetch failed: \(error.localizedDescription)")
            return
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
                try modelContext.save()
                logger.notice("Recorded \(observation.departureDate == nil ? "open" : "closed") visit arriving \(arrival).")
            } catch {
                modelContext.rollback()
                logger.error("Visit insert save failed: \(error.localizedDescription)")
            }
            return
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
            return
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
                try modelContext.save()
                logger.notice("Closed visit arriving \(arrival) with departure \(departure).")
            } catch {
                modelContext.rollback()
                logger.error("Visit update save failed: \(error.localizedDescription)")
            }
            return
        }

        if existing.departureDate == nil {
            logger.notice("Ignored differing open callback for an open visit.")
        } else if observation.departureDate == nil {
            logger.notice("Ignored open callback for a closed visit.")
        } else {
            logger.notice("Ignored differing closed callback for a closed visit.")
        }
    }

    private nonisolated static func sameDateBits(
        _ lhs: Date?,
        _ rhs: Date?
    ) -> Bool {
        lhs?.timeIntervalSinceReferenceDate.bitPattern
            == rhs?.timeIntervalSinceReferenceDate.bitPattern
    }
}
