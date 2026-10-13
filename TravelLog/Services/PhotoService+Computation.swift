
import Photos
import UIKit
import CoreLocation
import SwiftData
import os.log

/// Sendable envelope for a bare `[PHAsset]` crossing the detached-compute
/// boundary (same `@unchecked` rationale as `StayPhotos`: `PHObject`s are
/// immutable, thread-safe snapshots). Used by `hiddenAssets(for:)`.
nonisolated struct ResolvedAssets: @unchecked Sendable {
    let assets: [PHAsset]
}

/// Sendable snapshot of the per-stay geometry `photosForTrip` needs, captured
/// on the main actor from the live `Stay` `@Model`s before hopping off-actor
/// to run the PhotoKit fetch + grouping. Mirrors the `TripSnapshot` pattern:
/// never carry a `@Model`/`ModelContext` across a `@Sendable` boundary.
/// `nonisolated` so it can be constructed and read from the off-main compute
/// (default-MainActor isolation would otherwise pin it to the main actor).
nonisolated struct StaySnapshot: Sendable, Hashable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let startTime: Date
    let endTime: Date
    /// Capture `orderInTrip ?? 0` to match the grouping sort key.
    let orderInTrip: Int
    let durationMinutes: Int
    let locality: String?
    let categoryRaw: String
}

/// The cache key and both detached computations read the same immutable input.
/// Stays retain physical multiplicity and the grouping sort's equal-order ties.
nonisolated struct TripPhotoSnapshot: Hashable, Sendable {
    let startDate: Date
    let endDate: Date?
    let stays: [StaySnapshot]

    var photoStays: [StaySnapshot] {
        stays.filter {
            $0.categoryRaw == StayCategory.destination.rawValue
                || $0.categoryRaw == StayCategory.transit.rawValue
        }
    }

    /// The gallery's fetch window: the trip's span widened by 30 minutes,
    /// an open trip running to now.
    var photoWindow: (start: Date, end: Date) {
        (startDate.addingTimeInterval(-1800), (endDate ?? Date.now).addingTimeInterval(1800))
    }

    /// Hasher tokens are comparable only within this process; never persist them.
    var shapeToken: Int {
        var hasher = Hasher()
        hasher.combine(self)
        return hasher.finalize()
    }
}

extension PhotoService {

    /// Nonisolated computation runs on the detached executor without actor-owned state.
    nonisolated static func computePhotoGroups(
        stays: [StaySnapshot],
        windowStart: Date,
        windowEnd: Date,
        hidden: Set<String>
    ) -> [StayPhotos] {
        var assets: [PHAsset] = []
        enumerateAdmittedAssets(stays: stays, windowStart: windowStart, windowEnd: windowEnd, hidden: hidden) {
            assets.append($0)
        }
        return groupAssetsByStay(assets, stays: stays)
    }

    nonisolated static func computePhotoCount(
        stays: [StaySnapshot],
        windowStart: Date,
        windowEnd: Date,
        hidden: Set<String>
    ) -> Int {
        var count = 0
        enumerateAdmittedAssets(stays: stays, windowStart: windowStart, windowEnd: windowEnd, hidden: hidden) { _ in
            count += 1
        }
        return count
    }

    /// Both consumers share the fetch and admission rules; counting retains no asset arrays.
    private nonisolated static func enumerateAdmittedAssets(
        stays: [StaySnapshot],
        windowStart: Date,
        windowEnd: Date,
        hidden: Set<String>,
        _ admit: @escaping (PHAsset) -> Void
    ) {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate <= %@ AND mediaType == %d",
            windowStart as CVarArg,
            windowEnd as CVarArg,
            PHAssetMediaType.image.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let fetchResult = PHAsset.fetchAssets(with: options)

        let matchContexts = Self.matchContexts(for: stays)

        fetchResult.enumerateObjects { asset, _, _ in
            guard isAdmittedAsset(
                location: asset.location, creationDate: asset.creationDate,
                mediaSubtypes: asset.mediaSubtypes, sourceType: asset.sourceType,
                localIdentifier: asset.localIdentifier, hidden: hidden, matchContexts: matchContexts
            ) else { return }
            admit(asset)
        }
    }

    /// Scalar seam includes the missing-date drop previously applied during grouping.
    nonisolated static func isAdmittedAsset(
        location: CLLocation?,
        creationDate: Date?,
        mediaSubtypes: PHAssetMediaSubtype,
        sourceType: PHAssetSourceType,
        localIdentifier: String,
        hidden: Set<String>,
        matchContexts: [StayMatchContext]
    ) -> Bool {
        guard let creationDate,
              !mediaSubtypes.contains(.photoScreenshot),
              sourceType != .typeCloudShared,
              !hidden.contains(localIdentifier) else { return false }
        if let location {
            return matchContexts.contains { context in
                // The box is only a coarse cull; exact geodesic distance decides admission.
                context.boxContains(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                    && location.distance(from: context.location) < 50_000
            }
        }
        return matchContexts.contains { context in
            creationDate >= context.windowStart && creationDate <= context.windowEnd
        }
    }

    /// The per-stay geometry gallery admission matches against; the Hidden
    /// Photos offer reuses it so both read one rule.
    nonisolated static func matchContexts(for stays: [StaySnapshot]) -> [StayMatchContext] {
        stays.map { stay in
            StayMatchContext(
                latitude: stay.latitude,
                longitude: stay.longitude,
                startTime: stay.startTime,
                endTime: stay.endTime,
                radiusMeters: 50_000,
                timeBuffer: 1800
            )
        }
    }

    /// Scalar seam for the Hidden Photos offer: a hidden photo is offered only
    /// where this trip's gallery would show it if nothing were hidden (its fetch
    /// window and media type, then `isAdmittedAsset`). A split copies hidden
    /// rows onto every piece, so this keeps another piece's photo off this one.
    /// One hidden in Photos is never offered: an identifier fetch includes it,
    /// the gallery's fetch does not.
    nonisolated static func isOfferedHiddenAsset(
        location: CLLocation?,
        creationDate: Date?,
        mediaType: PHAssetMediaType,
        mediaSubtypes: PHAssetMediaSubtype,
        sourceType: PHAssetSourceType,
        isHidden: Bool,
        windowStart: Date,
        windowEnd: Date,
        matchContexts: [StayMatchContext]
    ) -> Bool {
        guard mediaType == .image, !isHidden, let creationDate,
              creationDate >= windowStart, creationDate <= windowEnd else { return false }
        return isAdmittedAsset(
            location: location, creationDate: creationDate,
            mediaSubtypes: mediaSubtypes, sourceType: sourceType,
            localIdentifier: "", hidden: [], matchContexts: matchContexts
        )
    }

    nonisolated static func groupAssetsByStay(_ assets: [PHAsset], stays: [StaySnapshot]) -> [StayPhotos] {
        let sortedStays = stays.sorted { $0.orderInTrip < $1.orderInTrip }

        // Hoist per-stay geometry, but never radius-cull nearest-stay assignment: it has no distance threshold.
        let stayContexts = sortedStays.map(StayGroupContext.init)

        var groups: [UUID: [PHAsset]] = [:]

        for asset in assets {
            guard let creationDate = asset.creationDate else { continue }
            guard let stayID = nearestStayID(
                assetLocation: asset.location,
                creationDate: creationDate,
                sortedContexts: stayContexts
            ) else { continue }
            groups[stayID, default: []].append(asset)
        }

        // CloudKit twins can share one UUID; emit each bucket once so the gallery
        // total equals `computePhotoCount` for the same inputs.
        var emitted = Set<UUID>()
        return sortedStays.compactMap { stay in
            guard emitted.insert(stay.id).inserted,
                  let stayAssets = groups[stay.id], !stayAssets.isEmpty else { return nil }
            return StayPhotos(
                stayID: stay.id,
                stayLocality: stay.locality,
                stayStartTime: stay.startTime,
                assets: stayAssets
            )
        }
    }

    /// Pure assignment test seam avoids constructing PHAssets.
    /// 1. Among stays whose ±30 min window contains `creationDate`: for a
    ///    GPS asset, the geodesic-nearest wins (strict `<`, so the
    ///    lowest-`orderInTrip` stay wins ties); for a no-GPS asset, the FIRST
    ///    such stay in `orderInTrip` order wins.
    /// 2. If none qualify, fall back to the stay whose mid-time is closest to
    ///    `creationDate` (over ALL stays, not just the in-window ones).
    ///
    /// `sortedContexts` MUST already be sorted by `orderInTrip` (as
    /// `groupAssetsByStay` builds it) — the tie-breaks depend on that order.
    /// Returns `nil` only when `sortedContexts` is empty.
    nonisolated static func nearestStayID(
        assetLocation: CLLocation?,
        creationDate: Date,
        sortedContexts: [StayGroupContext]
    ) -> UUID? {
        var bestID: UUID?
        var bestDistance = Double.infinity

        for context in sortedContexts {
            guard creationDate >= context.bufferStart && creationDate <= context.bufferEnd else { continue }

            if let assetLocation {
                let distance = assetLocation.distance(from: context.location)
                if distance < bestDistance {
                    bestDistance = distance
                    bestID = context.id
                }
            } else if bestID == nil {
                bestID = context.id
            }
        }

        if bestID == nil {
            bestID = sortedContexts.min(by: { c1, c2 in
                let ref = creationDate.timeIntervalSinceReferenceDate
                return abs(ref - c1.midTimeReference) < abs(ref - c2.midTimeReference)
            })?.id
        }

        return bestID
    }
}

// MARK: - Stay Group Context (groupAssetsByStay precompute)

/// Precompute per-stay geometry once; nearest-stay assignment must not use a radius cull.
nonisolated struct StayGroupContext {
    let id: UUID
    let location: CLLocation
    let bufferStart: Date
    let bufferEnd: Date
    /// Mid-time key: startTime plus durationMinutes converted to half-duration seconds.
    let midTimeReference: Double

    init(_ stay: StaySnapshot) {
        id = stay.id
        location = CLLocation(latitude: stay.latitude, longitude: stay.longitude)
        bufferStart = stay.startTime.addingTimeInterval(-1800)
        bufferEnd = stay.endTime.addingTimeInterval(1800)
        midTimeReference = stay.startTime.timeIntervalSinceReferenceDate
            + Double(stay.durationMinutes) * 30
    }
}


// MARK: - Stay Match Context (photosForTrip precompute)

/// Precomputed matching geometry; the bounding box is only a coarse cull before exact geodesic distance.
/// The box fully contains the radius circle: Δlat = r / 111,320 m-per-°,
/// Δlon = Δlat / cos(lat) with cos clamped away from zero so extreme
/// latitudes degrade to an over-wide box (more exact checks, never a
/// missed match).
nonisolated struct StayMatchContext {
    let location: CLLocation
    let minLat: Double
    let maxLat: Double
    let lonSegments: [(min: Double, max: Double)]
    let windowStart: Date
    let windowEnd: Date

    init(latitude: Double, longitude: Double,
         startTime: Date, endTime: Date,
         radiusMeters: Double, timeBuffer: TimeInterval) {
        location = CLLocation(latitude: latitude, longitude: longitude)
        let deltaLat = radiusMeters / 111_320
        let cosLat = max(abs(cos(latitude * .pi / 180)), 0.01)
        let deltaLon = deltaLat / cosLat
        minLat = latitude - deltaLat
        maxLat = latitude + deltaLat
        // Wrap longitude bounds so photos across ±180° remain candidates.
        lonSegments = GeoMath.longitudeSegments(center: longitude, halfWidth: deltaLon)
        windowStart = startTime.addingTimeInterval(-timeBuffer)
        windowEnd = endTime.addingTimeInterval(timeBuffer)
    }

    func boxContains(latitude: Double, longitude: Double) -> Bool {
        latitude >= minLat && latitude <= maxLat
            && GeoMath.segmentsContain(lonSegments, longitude: longitude)
    }
}
