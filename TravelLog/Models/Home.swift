//
//  Home.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//


import Foundation
import SwiftData
import CoreLocation

/// Represents a home location.
///
/// The app uses a radius-based approach: any stay whose centroid falls within
/// `radiusKm` of the home coordinate is classified as "home."
///
/// When a user relocates, the previous Home's `endedAt` is set and a new Home is created.
/// Past trips are evaluated against whichever Home was active at the time of the trip.
@Model
final class Home {

    var id: UUID = UUID()

    /// User-facing label, e.g. "Athens Home" or "London Flat".
    var label: String = ""

    var latitude: Double = 0
    var longitude: Double = 0

    /// Radius in kilometers. Any stay within this radius is classified as "home".
    /// Default 25 km - covers a typical metropolitan area. See also `RoutinePlace.radiusMeters` (meters).
    var radiusKm: Double = 25

    /// Reverse-geocoded metadata for display purposes.
    var locality: String?
    var administrativeArea: String?
    var country: String?
    var isoCountryCode: String?

    /// When the user started living here.
    var startedAt: Date = Date.now

    /// When the user moved away. Nil means this is the current home.
    var endedAt: Date?

    /// Convenience flag derived from `endedAt`.
    var isCurrent: Bool {
        endedAt == nil
    }

    /// User-facing label for an unnamed default home. A stored non-empty
    /// label, including the legacy "Home" value, remains user data.
    func displayLabel(locale: Locale = AppLanguagePreference.currentLocale()) -> String {
        guard label.isEmpty else { return label }
        return localizedRendererString(
            localized: "home.place.default-label",
            defaultValue: "Home",
            bundle: nil,
            locale: locale)
    }

    init(
        label: String,
        latitude: Double,
        longitude: Double,
        radiusKm: Double = 25.0,
        startedAt: Date = .now
    ) {
        self.id = UUID()
        self.label = label
        self.latitude = latitude
        self.longitude = longitude
        self.radiusKm = radiusKm
        self.startedAt = startedAt
    }

    /// Returns the distance in kilometers from this home to a given coordinate.
    func distanceKm(to coordinate: CLLocationCoordinate2D) -> Double {
        let homeLocation = CLLocation(latitude: latitude, longitude: longitude)
        let targetLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return homeLocation.distance(from: targetLocation) / 1000.0
    }

    /// Whether a given coordinate is within this home's radius.
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        distanceKm(to: coordinate) <= radiusKm
    }
}
