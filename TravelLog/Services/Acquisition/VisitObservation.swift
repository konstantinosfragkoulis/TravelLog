//
//  VisitObservation.swift
//  TravelLog
//
//  Scalar production seam for Core Location visit callbacks.
//

import CoreLocation
import Foundation

nonisolated protocol VisitEventSource {
    var coordinate: CLLocationCoordinate2D { get }
    var horizontalAccuracy: CLLocationAccuracy { get }
    var arrivalDate: Date { get }
    var departureDate: Date { get }
}

extension CLVisit: VisitEventSource {}

nonisolated struct VisitObservation: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let receivedAt: Date
    let arrivalDate: Date?
    let departureDate: Date?
    let arrivalWasDistantPast: Bool
    let departureWasDistantFuture: Bool

    init<Source: VisitEventSource>(source: Source, receivedAt: Date) {
        let coordinate = source.coordinate
        let rawArrival = source.arrivalDate
        let rawDeparture = source.departureDate

        latitude = coordinate.latitude
        longitude = coordinate.longitude
        horizontalAccuracy = source.horizontalAccuracy
        self.receivedAt = receivedAt
        arrivalWasDistantPast = rawArrival == .distantPast
        departureWasDistantFuture = rawDeparture == .distantFuture
        arrivalDate = arrivalWasDistantPast ? nil : rawArrival
        departureDate = departureWasDistantFuture ? nil : rawDeparture
    }
}
