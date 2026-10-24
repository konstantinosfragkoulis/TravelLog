//
//  Visit.swift
//  TravelLog
//

import Foundation
import SwiftData

/// One evolving Core Location visit observation.
///
/// Logical identity is `arrivalDate`'s exact
/// `timeIntervalSinceReferenceDate.bitPattern`. The recorder coalesces
/// exact-arrival callbacks only when their coordinates are within 3,000 m.
///
/// `receivedAt` is the receipt time of the latest callback that created or
/// updated this row. An exact redelivery is a no-op and does not touch it.
@Model
final class Visit {

    var id: UUID = UUID()
    var arrivalDate: Date = Date.now
    var departureDate: Date? = nil
    var latitude: Double = 0
    var longitude: Double = 0
    var horizontalAccuracy: Double = 0
    var receivedAt: Date = Date.now
    var stayID: UUID? = nil
    var isProcessed: Bool = false

    init(
        id: UUID = UUID(),
        arrivalDate: Date = .now,
        departureDate: Date? = nil,
        latitude: Double = 0,
        longitude: Double = 0,
        horizontalAccuracy: Double = 0,
        receivedAt: Date = .now,
        stayID: UUID? = nil,
        isProcessed: Bool = false
    ) {
        self.id = id
        self.arrivalDate = arrivalDate
        self.departureDate = departureDate
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.receivedAt = receivedAt
        self.stayID = stayID
        self.isProcessed = isProcessed
    }
}

extension Visit {
    /// The stays a closed visit ended: their end is the departure, never
    /// run on into the silence after it (`StayClusterer` skips them), so
    /// `FlightJudge` takes nothing off it. `arrivingWithin` limits the read
    /// to visits that arrived in that span.
    nonisolated static func departedStayIDs(
        arrivingWithin span: ClosedRange<Date>? = nil, in context: ModelContext
    ) throws -> Set<UUID> {
        var descriptor: FetchDescriptor<Visit>
        if let span {
            let from = span.lowerBound, to = span.upperBound
            descriptor = FetchDescriptor(predicate: #Predicate {
                $0.departureDate != nil && $0.stayID != nil && $0.arrivalDate >= from && $0.arrivalDate <= to
            })
        } else {
            descriptor = FetchDescriptor(predicate: #Predicate { $0.departureDate != nil && $0.stayID != nil })
        }
        descriptor.propertiesToFetch = [\.stayID]
        return Set(try context.fetch(descriptor).compactMap(\.stayID))
    }
}
