//
//  LocationPing.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import SwiftData

/// The immutable ground truth for all location data.
///
/// Each record represents a single Significant Location Change event from iOS.
/// These are never modified after creation (except for retry-geocoding nil fields).
/// All higher-level constructs (Stays, Trips) are derived from these pings.
@Model
final class LocationPing {

    var id: UUID = UUID()

    /// When iOS delivered this location update.
    var timestamp: Date = Date.now

    /// WGS84 coordinates from `CLLocation`.
    var latitude: Double = 0
    var longitude: Double = 0

    /// Horizontal accuracy in meters. Useful for filtering garbage readings.
    var horizontalAccuracy: Double = 0

    // MARK: - V13 Altitude

    /// Altitude in meters above mean sea level, as reported by `CLLocation`
    /// (live SLC) or the photo's EXIF GPS (`PHAsset.location`). The honest
    /// aerial-vs-surface signal: a cruise-altitude fix reads ~9–12 km, ground
    /// reads near local elevation, sea level ~0. `nil` for rows captured before
    /// V13 (the value was discarded at ingest then) and for fixes that carried
    /// no altitude. **Always read together with `verticalAccuracy`** — a
    /// negative `verticalAccuracy` means this altitude is invalid (cell/Wi-Fi
    /// fix with no GPS lock), not a real height. Added in V13.
    var altitude: Double?

    /// Vertical accuracy in meters (1σ) for `altitude`. Negative ⇒ the altitude
    /// reading is invalid and must not be trusted (the device had no usable
    /// vertical fix). `nil` for pre-V13 rows. Added in V13.
    var verticalAccuracy: Double?

    /// Hex string of the H3 cell index at resolution 6 (~36 km² per hex).
    var h3IndexRes6: String = ""

    // MARK: - Reverse Geocoded Fields
    // All geocoding is done with Locale "en_US" for consistency.
    // These may be nil if geocoding failed (network error, rate limit).

    var locality: String?
    var subLocality: String?
    var administrativeArea: String?
    var country: String?
    var isoCountryCode: String?

    /// Whether geocoding succeeded for this ping.
    var isGeocoded: Bool = false

    /// Whether this ping has been incorporated into a Stay by the clustering pipeline.
    var isProcessed: Bool = false

    /// Provenance of this ping. Defaults to `"liveSLC"` so V7→V8 lightweight
    /// migration backfills every pre-existing row to the live-tracking source.
    /// Use the `source` computed property below for type-safe access. Added in V8.
    var sourceRaw: String = DataSource.liveSLC.rawValue

    /// Type-safe accessor for `sourceRaw`. Reads via `DataSource.decode` so an
    /// unknown raw value (from a future schema) falls back to `.liveSLC`
    /// rather than crashing.
    var source: DataSource {
        get { DataSource.decode(sourceRaw) }
        set { sourceRaw = newValue.rawValue }
    }

    init(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        h3IndexRes6: String,
        altitude: Double? = nil,
        verticalAccuracy: Double? = nil,
        source: DataSource = .liveSLC
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.h3IndexRes6 = h3IndexRes6
        self.altitude = altitude
        self.verticalAccuracy = verticalAccuracy
        self.isGeocoded = false
        self.isProcessed = false
        self.sourceRaw = source.rawValue
    }

}
