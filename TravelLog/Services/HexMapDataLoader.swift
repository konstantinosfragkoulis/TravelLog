import Foundation
import SwiftData
import CoreLocation

/// Read-only map preparation. Managed objects stay on the context's executor;
/// only values cross the worker boundary.
nonisolated enum HexMapDataLoader {
    struct Inputs: Sendable {
        let transit: [HexVisibility.TransitStay]
        /// Real-visit hexes; only those among the all-aerial transit hexes (the
        /// only ones it decides) when there are at most 500 of those.
        let realHexes: Set<String>
        let rows: [HexVisitSnapshot]
    }

    struct Snapshot: Sendable {
        let rows: [HexVisitSnapshot]
        let overlays: [HexOverlayData]
        let maxCount: Int
    }

    typealias BoundaryLookup = @Sendable (String) -> [(latitude: Double, longitude: Double)]?

    @MainActor
    static func load(
        context: ModelContext,
        boundaryForHex: @escaping BoundaryLookup = H3Service.cellBoundary(for:)
    ) async throws -> Snapshot {
        try Task.checkCancellation()
        // A fresh context cannot see pending inserts, deletes or category
        // edits. Preserve the old view-context read in that case,
        // without adding a save or sending managed objects to the worker.
        // Any pending edit selects this fallback and can block main during
        // fetch/snapshot preparation; keep write paths promptly saved.
        let pendingInputs = context.hasChanges ? try fetchInputs(context: context) : nil
        let container = context.container
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let inputs: Inputs
            if let pendingInputs {
                inputs = pendingInputs
            } else {
                let readContext = ModelContext(container)
                readContext.autosaveEnabled = false
                inputs = try fetchInputs(context: readContext)
            }
            return try buildSnapshot(inputs: inputs, boundaryForHex: boundaryForHex)
        }
        return try await withTaskCancellationHandler {
            let snapshot = try await worker.value
            // Also covers cancellation after the worker has already finished.
            try Task.checkCancellation()
            return snapshot
        } onCancel: {
            worker.cancel()
        }
    }

    /// Synchronous so all managed-object access remains on the caller's
    /// executor. SwiftData fetches themselves cannot be interrupted.
    static func fetchInputs(context: ModelContext) throws -> Inputs {
        try Task.checkCancellation()
        var transitDescriptor = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.categoryRaw == "transit" }
        )
        // Read only the scalar fields used here, avoiding weather and ping-ID
        // blobs. Compare the stored transit mode to avoid actor-isolated accessors.
        transitDescriptor.propertiesToFetch = [\.h3IndexRes6, \.categoryRaw, \.transitFromPreviousRaw, \.isAirport]
        let transitStays = try context.fetch(transitDescriptor)
        var transit: [HexVisibility.TransitStay] = []
        transit.reserveCapacity(transitStays.count)
        for stay in transitStays {
            try Task.checkCancellation()
            transit.append(HexVisibility.TransitStay(
                h3Index: stay.h3IndexRes6,
                isFlight: stay.transitFromPreviousRaw == TransitMode.flight.rawValue,
                isAirport: stay.isAirport
            ))
        }

        // Only an all-aerial transit hex can be hidden, and a real stay matters
        // only there: up to one IN list (500 values)
        // read the real stays in those hexes alone, beyond it the one all-real
        // read. The hidden set equals the all-real read's either way.
        let aerialOnly = Array(HexVisibility.hiddenHexes(transit: transit, realHexes: []))
        var realHexes = Set<String>()
        // With no all-aerial hex no real stay can change visibility: nothing to read.
        if !aerialOnly.isEmpty {
            try Task.checkCancellation()
            var realDescriptor = aerialOnly.count <= 500
                ? FetchDescriptor<Stay>(predicate: #Predicate {
                    aerialOnly.contains($0.h3IndexRes6) && ($0.categoryRaw == "home"
                        || $0.categoryRaw == "routine" || $0.categoryRaw == "destination")
                })
                : FetchDescriptor<Stay>(predicate: #Predicate {
                    $0.categoryRaw == "home" || $0.categoryRaw == "routine" || $0.categoryRaw == "destination"
                })
            realDescriptor.propertiesToFetch = [\.h3IndexRes6, \.categoryRaw]
            for stay in try context.fetch(realDescriptor) {
                try Task.checkCancellation()
                if !stay.h3IndexRes6.isEmpty { realHexes.insert(stay.h3IndexRes6) }
            }
        }

        try Task.checkCancellation()
        let visits = try context.fetch(FetchDescriptor<HexVisit>(
            sortBy: [SortDescriptor(\.lastVisited, order: .reverse)]
        ))
        var rows: [HexVisitSnapshot] = []
        rows.reserveCapacity(visits.count)
        for visit in visits {
            try Task.checkCancellation()
            rows.append(HexVisitSnapshot(
                h3Index: visit.h3Index,
                locality: visit.locality,
                country: visit.country,
                isoCountryCode: visit.isoCountryCode,
                firstVisited: visit.firstVisited,
                lastVisited: visit.lastVisited,
                visitCount: visit.visitCount,
                centerLatitude: visit.centerLatitude,
                centerLongitude: visit.centerLongitude
            ))
        }
        try Task.checkCancellation()
        return Inputs(transit: transit, realHexes: realHexes, rows: rows)
    }

    static func buildSnapshot(
        inputs: Inputs,
        boundaryForHex: BoundaryLookup = H3Service.cellBoundary(for:)
    ) throws -> Snapshot {
        try Task.checkCancellation()
        let hiddenHexes = HexVisibility.hiddenHexes(transit: inputs.transit, realHexes: inputs.realHexes)
        // `HexVisitDeduplicator` keeps ambiguous same-cell groups as separate
        // rows: fold each cell into its first (most recent) row, so a cell
        // draws one overlay and its identity stays unique.
        var cells: [HexVisitSnapshot] = []
        var cellPosition: [String: Int] = [:]
        cells.reserveCapacity(inputs.rows.count)
        for row in inputs.rows {
            try Task.checkCancellation()
            if let position = cellPosition[row.h3Index] {
                cells[position] = cells[position].merging(row)
            } else {
                cellPosition[row.h3Index] = cells.count
                cells.append(row)
            }
        }
        var rows: [HexVisitSnapshot] = []
        var overlays: [HexOverlayData] = []
        rows.reserveCapacity(cells.count)
        overlays.reserveCapacity(cells.count)
        var maxCount = 1
        for row in cells {
            try Task.checkCancellation()
            guard !hiddenHexes.contains(row.h3Index) else { continue }
            rows.append(row)
            // Preserve the existing boundary-failure policy: no polygon or
            // contribution to maxCount when an index cannot be rendered.
            guard let boundary = boundaryForHex(row.h3Index) else { continue }
            overlays.append(HexOverlayData(
                id: row.h3Index,
                boundary: boundary.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                },
                visitCount: row.visitCount,
                centerLatitude: row.centerLatitude,
                centerLongitude: row.centerLongitude
            ))
            maxCount = max(maxCount, row.visitCount)
        }
        try Task.checkCancellation()
        return Snapshot(rows: rows, overlays: overlays, maxCount: maxCount)
    }
}

// MARK: - HexOverlayData

nonisolated struct HexOverlayData: Identifiable, Sendable {
    let id: String
    let boundary: [CLLocationCoordinate2D]
    let visitCount: Int
    let centerLatitude: Double
    let centerLongitude: Double
}

// MARK: - HexVisitSnapshot

/// Plain-value copy of a `HexVisit` row — everything the popup, the
/// highlight matcher, and the camera framing read. See `hexRows`.
nonisolated struct HexVisitSnapshot: Sendable, Equatable {
    let h3Index: String
    let locality: String?
    let country: String?
    let isoCountryCode: String?
    let firstVisited: Date
    let lastVisited: Date
    let visitCount: Int
    let centerLatitude: Double
    let centerLongitude: Double

    /// Another row of the same cell folded in by `HexVisitDeduplicator`'s
    /// rules: earliest first visit, latest last visit, the larger count (never
    /// the sum), nil labels filled with the country pair kept consistent.
    /// The receiver's centre stays.
    func merging(_ other: HexVisitSnapshot) -> HexVisitSnapshot {
        var country = country
        var isoCountryCode = isoCountryCode
        if country == nil, isoCountryCode == nil {
            country = other.country
            isoCountryCode = other.isoCountryCode
        } else if isoCountryCode == nil, other.country == nil || other.country == country {
            isoCountryCode = other.isoCountryCode
        } else if country == nil, other.isoCountryCode == nil || other.isoCountryCode == isoCountryCode {
            country = other.country
        }
        return HexVisitSnapshot(
            h3Index: h3Index,
            locality: locality ?? other.locality,
            country: country,
            isoCountryCode: isoCountryCode,
            firstVisited: min(firstVisited, other.firstVisited),
            lastVisited: max(lastVisited, other.lastVisited),
            visitCount: max(visitCount, other.visitCount),
            centerLatitude: centerLatitude,
            centerLongitude: centerLongitude
        )
    }
}
