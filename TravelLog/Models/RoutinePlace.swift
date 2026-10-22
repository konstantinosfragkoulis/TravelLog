//
//  RoutinePlace.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//


import Foundation
import SwiftData
import CoreLocation

/// A place the user visits regularly that should not be counted as a trip destination.
///
/// Examples: university, gym, office, partner's house.
/// Stays within a routine place's radius are classified as "routine" and excluded
/// from trip generation.
@Model
final class RoutinePlace {

    var id: UUID = UUID()

    /// User-facing label, e.g. "University" or "Gym".
    var label: String = ""

    var latitude: Double = 0
    var longitude: Double = 0

    /// Radius in meters. Stays whose centroid falls within this radius are "routine".
    /// Default 500m - appropriate for a building or campus. See also `Home.radiusKm` (kilometers).
    var radiusMeters: Double = 500

    /// Whether this routine place is currently active.
    /// Inactive places are kept for historical classification but hidden from the UI.
    var isActive: Bool = true

    /// When this routine place became active.
    var startedAt: Date = Date.now

    /// When this routine place was ended (due to location edit or removal).
    /// Nil means this version is current.
    var endedAt: Date?

    /// Whether this is the current version (not ended and still active).
    var isCurrent: Bool {
        isActive && endedAt == nil
    }

    init(
        label: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double = 500.0,
        startedAt: Date = .now
    ) {
        self.id = UUID()
        self.label = label
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.isActive = true
        self.startedAt = startedAt
    }

    /// Whether a given coordinate is within this routine place's radius.
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let placeLocation = CLLocation(latitude: latitude, longitude: longitude)
        let targetLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return placeLocation.distance(from: targetLocation) <= radiusMeters
    }
}
