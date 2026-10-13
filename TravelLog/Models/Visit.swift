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
