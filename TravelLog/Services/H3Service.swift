//
//  H3Service.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import SwiftH3
import Ch3

/// Provides H3 hexagonal geospatial indexing at resolution 6.
///
/// Resolution 6 hexes have an average area of ~36.13 km² and an average edge
/// length of ~3.23 km. Good for "neighborhood/small town" level coverage.
///
/// All methods are pure functions operating on primitive types.
/// No CoreLocation imports - callers pass raw lat/lon doubles.
///
/// ## Swift 6 Concurrency
///
/// Methods are explicitly `nonisolated` to prevent global actor inference.
/// Without this, Swift 6 may infer `@MainActor` isolation from module-level
/// context, preventing calls from `@ModelActor` contexts like `PingRecorder`.
enum H3Service {

    /// The fixed H3 resolution used throughout the app.
    nonisolated static let resolution: Int32 = 6

    // MARK: - Coordinate → Cell Index

    /// Convert latitude/longitude (degrees) to an H3 cell index hex string at resolution 6.
    ///
    /// Returns nil only if the coordinate is invalid (should never happen for real GPS data).
    nonisolated static func cellIndex(latitude: Double, longitude: Double) -> String? {
        let h3Coord = H3Coordinate(lat: latitude, lon: longitude)
        let index = SwiftH3.H3Index(coordinate: h3Coord, resolution: resolution)

        guard index.isValid else { return nil }

        return index.description
    }

    // MARK: - Cell Index → Center Coordinate

    /// Convert an H3 cell index hex string back to its center latitude/longitude (degrees).
    ///
    /// Returns nil if the hex string is invalid — including a non-zero value
    /// that is not a topologically valid H3 index (`h3IsValid`), for which the
    /// C boundary/center calls are undefined behaviour.
    nonisolated static func centerCoordinate(for hexString: String) -> (latitude: Double, longitude: Double)? {
        guard let rawValue = UInt64(hexString, radix: 16), rawValue != 0,
              h3IsValid(rawValue) != 0 else { return nil }

        var geoCoord = GeoCoord(lat: 0, lon: 0)
        h3ToGeo(rawValue, &geoCoord)

        return (
            latitude: geoCoord.lat * 180.0 / .pi,
            longitude: geoCoord.lon * 180.0 / .pi
        )
    }

    // MARK: - Cell Index → Boundary

    /// Get the boundary vertices of an H3 cell for rendering as a map polygon.
    ///
    /// Returns an array of (latitude, longitude) pairs forming the hex boundary.
    nonisolated static func cellBoundary(for hexString: String) -> [(latitude: Double, longitude: Double)]? {
        // `h3IsValid` guard: without it, a non-zero but
        // topologically-invalid index gives `h3ToGeoBoundary` undefined
        // behaviour, and `numVerts` could exceed the fixed C `verts` array,
        // reading past its bounds in the loop below.
        guard let rawValue = UInt64(hexString, radix: 16), rawValue != 0,
              h3IsValid(rawValue) != 0 else { return nil }

        var boundary = GeoBoundary()
        h3ToGeoBoundary(rawValue, &boundary)

        let count = Int(boundary.numVerts)
        guard count > 0 else { return nil }

        var coordinates: [(latitude: Double, longitude: Double)] = []
        coordinates.reserveCapacity(count)

        withUnsafePointer(to: boundary.verts) { ptr in
            ptr.withMemoryRebound(to: GeoCoord.self, capacity: count) { vertPtr in
                for i in 0..<count {
                    let vert = vertPtr[i]
                    coordinates.append((
                        latitude: vert.lat * 180.0 / .pi,
                        longitude: vert.lon * 180.0 / .pi
                    ))
                }
            }
        }

        return coordinates
    }
}
