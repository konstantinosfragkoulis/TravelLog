//
//  PlaceTimeZone.swift
//  TravelLog
//

import CoreLocation
import MapKit

/// The time zone of a coordinate, asked of MapKit. The offline geocoder
/// carries no zones, so this is the only exact source for a place the user
/// has not been to yet. Nil when MapKit does not answer; callers keep the
/// zone they have.
enum PlaceTimeZone {
    static func lookup(latitude: Double, longitude: Double) async -> TimeZone? {
        guard let request = MKReverseGeocodingRequest(
            location: CLLocation(latitude: latitude, longitude: longitude)) else { return nil }
        return try? await request.mapItems.first?.timeZone
    }
}
