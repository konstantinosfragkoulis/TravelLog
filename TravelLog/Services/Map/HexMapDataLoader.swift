import Foundation
import Observation
import SwiftData
import CoreLocation
import Ch3

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
        /// The visited set's outline (`outlineEdges(of:)`), indexed into `overlays`.
        var outline: [HexOutlineEdgeData] = []
        /// Every country of a cell's rows, for the cells whose display row
        /// does not carry them all: Stats counts a cell in each of them.
        var countryCodes: [String: Set<String>] = [:]
    }

    /// The highlight matcher's rows: each row, and again under every other
    /// country its cell's rows carry, so a Stats country routes to every
    /// cell it counted there. One geometry cell either way.
    static func highlightRows(
        _ rows: [HexVisitSnapshot], countryCodes: [String: Set<String>]
    ) -> [HexHighlightRequest.HexRow] {
        rows.flatMap { row in
            let others = (countryCodes[row.h3Index] ?? [])
                .subtracting([row.isoCountryCode].compactMap { $0 })
                .sorted()
            return ([row.isoCountryCode] + others.map { Optional($0) }).map {
                HexHighlightRequest.HexRow(
                    h3Index: row.h3Index, isoCountryCode: $0, firstVisited: row.firstVisited)
            }
        }
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
        // The merge keeps one country; Stats credits the cell to each.
        var cellCountries: [String: Set<String>] = [:]
        cells.reserveCapacity(inputs.rows.count)
        for row in inputs.rows {
            try Task.checkCancellation()
            if let code = row.isoCountryCode { cellCountries[row.h3Index, default: []].insert(code) }
            if let position = cellPosition[row.h3Index] {
                cells[position] = cells[position].merging(row)
            } else {
                cellPosition[row.h3Index] = cells.count
                cells.append(row)
            }
        }
        var rows: [HexVisitSnapshot] = []
        var overlays: [HexOverlayData] = []
        var countryCodes: [String: Set<String>] = [:]
        rows.reserveCapacity(cells.count)
        overlays.reserveCapacity(cells.count)
        var maxCount = 1
        for row in cells {
            try Task.checkCancellation()
            guard !hiddenHexes.contains(row.h3Index) else { continue }
            // An index that cannot be rendered has no polygon, no
            // contribution to maxCount and no row: nothing can tap, count or
            // frame it, as Stats drops it from its counts.
            guard let boundary = boundaryForHex(row.h3Index) else { continue }
            rows.append(row)
            if let codes = cellCountries[row.h3Index],
               codes != Set([row.isoCountryCode].compactMap { $0 }) {
                countryCodes[row.h3Index] = codes
            }
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
        let outline = try outlineEdges(of: overlays)
        return Snapshot(rows: rows, overlays: overlays, maxCount: maxCount, outline: outline,
                        countryCodes: countryCodes)
    }

    /// The edges of the visited set's outline: every edge of a drawn cell
    /// whose neighbour across it is not drawn (so holes are outlined too),
    /// once each, owned by the drawn cell. An edge between two drawn cells
    /// is never part of it. Built once per load, off main: at most six H3
    /// neighbour lookups per cell, and one edge boundary per outline edge
    /// (a cell with no drawn neighbour takes its own boundary as one loop).
    /// Pentagons have five edges; an index H3 cannot read has none.
    static func outlineEdges(of overlays: [HexOverlayData]) throws -> [HexOutlineEdgeData] {
        var indexes = [UInt64](repeating: 0, count: overlays.count)
        var visited = Set<UInt64>(minimumCapacity: overlays.count)
        for (position, overlay) in overlays.enumerated() {
            guard let index = UInt64(overlay.id, radix: 16), index != 0, h3IsValid(index) != 0 else { continue }
            indexes[position] = index
            visited.insert(index)
        }

        var outline: [HexOutlineEdgeData] = []
        var edges = [UInt64](repeating: 0, count: 6)
        var open: [UInt64] = []
        open.reserveCapacity(6)
        for (position, index) in indexes.enumerated() where index != 0 {
            if position % 256 == 0 { try Task.checkCancellation() }
            edges.withUnsafeMutableBufferPointer { buffer in
                buffer.initialize(repeating: 0)
                getH3UnidirectionalEdgesFromHexagon(index, buffer.baseAddress!)
            }
            open.removeAll(keepingCapacity: true)
            var edgeCount = 0
            for edge in edges where edge != 0 {
                edgeCount += 1
                if !visited.contains(getDestinationH3IndexFromUnidirectionalEdge(edge)) {
                    open.append(edge)
                }
            }
            guard !open.isEmpty else { continue }
            if open.count == edgeCount, let ring = overlays[position].boundary.first {
                // Alone: the whole boundary, closed, keeping any distortion
                // vertices the neighbours' edges would carry.
                outline.append(HexOutlineEdgeData(cell: position, vertices: overlays[position].boundary + [ring]))
                continue
            }
            for edge in open {
                var boundary = GeoBoundary()
                getH3UnidirectionalEdgeBoundary(edge, &boundary)
                let vertices = coordinates(of: &boundary)
                if vertices.count >= 2 {
                    outline.append(HexOutlineEdgeData(cell: position, vertices: vertices))
                }
            }
        }
        return outline
    }

    private static func coordinates(of boundary: inout GeoBoundary) -> [CLLocationCoordinate2D] {
        let count = min(max(Int(boundary.numVerts), 0), Int(MAX_CELL_BNDRY_VERTS))
        return withUnsafePointer(to: &boundary.verts) { tuple in
            tuple.withMemoryRebound(to: GeoCoord.self, capacity: count) { verts in
                (0..<count).map {
                    CLLocationCoordinate2D(latitude: verts[$0].lat * 180 / .pi, longitude: verts[$0].lon * 180 / .pi)
                }
            }
        }
    }
}

// MARK: - MapSnapshotRevocation

/// Delete All Data's signal to the exploration map: a committed wipe moves
/// the epoch, and the map drops every row, cell and highlight it shows
/// before it reads again, so a failed read cannot keep erased places on
/// screen. A load or projection begun under an older epoch is discarded.
@MainActor
@Observable
final class MapSnapshotRevocation {
    static let shared = MapSnapshotRevocation()

    private init() {}

    private(set) var epoch = 0

    func revoke() {
        epoch += 1
    }
}

// MARK: - HexOutlineEdgeData

/// One stretch of the visited set's outline: the edge a drawn cell shares
/// with a cell that is not drawn. Two vertices, or more where the edge
/// crosses an icosahedron face, or the whole closed boundary of a cell with
/// no drawn neighbour.
nonisolated struct HexOutlineEdgeData: Sendable {
    /// Into the snapshot's `overlays`.
    let cell: Int
    /// Degrees, unwrapped later around the owning cell's centre, as its ring is.
    let vertices: [CLLocationCoordinate2D]
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
