//
//  HexVisibility.swift
//  TravelLog
//

import Foundation
import SwiftData

/// Single source of truth for which explored hexes the **Exploration map**
/// (`HexMapView`) and the **Stats** "Hexes explored" counter hide.
///
/// # The rule
///
/// A hex is hidden only when EVERY stay touching it is **aerial transit** — a
/// flyover the user never reached on the ground. Any hex with a real visit
/// (home / routine / destination) shows, and — the fix for the "my road trip is
/// invisible" report — any hex whose transit is **surface** travel (driving,
/// ferry/boat, walking, cycling, or unknown ground travel) ALSO shows. Only
/// flights and airport waypoints are suppressed.
///
/// # Why this replaced "hide every transit hex"
///
/// The previous rule hid every `.transit`-category hex (`transitHexes
/// .subtracting(realHexes)`). But a drive becomes a CHAIN of short `.transit`
/// "moving stays" — `StayClusterer` starts a new stay each time its running
/// centroid drifts past 3 km, i.e. roughly once per hex at highway speed — so a
/// whole road trip was hidden exactly like a single plane-window photo. Keying
/// on the travel MODE instead of the coarse category paints the road while still
/// dropping the flyover.
///
/// # Aerial signals (existing, CloudKit-synced fields — no schema change)
///
/// - `transitMode == .flight` — the leg into this stay was inferred a flight
///   (≥300 km displacement + an airport endpoint + impossible ground speed;
///   `TransitInferer`, CoreMotion-free, runs for every stay).
/// - `isAirport` — the stay is within ~3 km of a known major airport (layover /
///   gate-area waypoint).
///
/// Everything else is treated as surface travel and shown. This is deliberately
/// generous toward showing: the product wants road trips and ferries to count,
/// and the worst case of a missed flyover (e.g. an imported plane-window photo
/// with no usable altitude and no airport nearby) is ONE stray hex on the
/// exploration map — country crediting is a separate, destination-only path and
/// is unaffected. Both screens consume this verbatim so their counts can never
/// disagree.
nonisolated enum HexVisibility {

    /// Minimal `Sendable` projection of a transit `Stay` — the only inputs the
    /// rule needs, snapshotted on the caller's actor so no `@Model` crosses a
    /// boundary.
    struct TransitStay: Sendable {
        let h3Index: String
        let isFlight: Bool
        let isAirport: Bool

        /// A flyover / air-terminal waypoint, not surface travel.
        var isAerial: Bool { isFlight || isAirport }
    }

    /// The set of hex indices to HIDE: those whose every touching transit stay
    /// is aerial AND which carry no real-visit stay. A hex with at least one
    /// surface (non-aerial) transit stay — or any real-visit stay — is never
    /// hidden. Hexes with no associated stay at all (pings still pending the
    /// next clusterer pass) are not in `transit`, so they are never hidden.
    static func hiddenHexes(transit: [TransitStay], realHexes: Set<String>) -> Set<String> {
        // Per hex: does EVERY transit stay touching it read as aerial?
        var allAerialByHex: [String: Bool] = [:]
        for stay in transit where !stay.h3Index.isEmpty {
            let soFar = allAerialByHex[stay.h3Index] ?? true
            allAerialByHex[stay.h3Index] = soFar && stay.isAerial
        }

        var hidden = Set<String>()
        for (hex, allAerial) in allAerialByHex where allAerial && !realHexes.contains(hex) {
            hidden.insert(hex)
        }
        return hidden
    }

    /// Boundary-failure policy: **drop from both**.
    ///
    /// The map inherently drops a hex whose `H3Service.cellBoundary` returns
    /// nil (there is nothing to draw), so a counter that only applies the
    /// hidden set counts MORE than the map shows exactly in the failure case
    /// this shared rule exists to prevent. A hex is visible-and-counted only
    /// when it is not hidden AND renderable.
    ///
    /// `isRenderable` is injected (in the app: `H3Service.cellBoundary(for:)
    /// != nil`) because this file is compiled into the widget target, which
    /// does not link the H3 library. The widget's own counter passes
    /// `{ _ in true }` — it cannot validate indices, an accepted drift
    /// limited to corrupt rows that should not exist (every write path
    /// validates via `H3Service.cellIndex`).
    ///
    /// `HexMapView`'s overlay build applies this definitionally (its
    /// `guard let boundary … else { continue }` IS the renderability drop);
    /// `StatsAggregator` must apply it explicitly through this function so
    /// the two can never drift.
    static func isVisible(
        h3Index: String,
        hidden: Set<String>,
        isRenderable: (String) -> Bool
    ) -> Bool {
        !hidden.contains(h3Index) && isRenderable(h3Index)
    }
}

nonisolated extension HexVisibility {

    /// Distinct cells outside `hidden` among the `HexVisit` rows; rows are not
    /// cells, as `HexVisitDeduplicator` keeps ambiguous same-cell groups.
    /// Equals the distinct `h3Index` values passing `isVisible` with an
    /// always-true `isRenderable`. Reads `h3Index` alone in pages sorted by it,
    /// each in its own context, so only one page is resident: the widget
    /// extension's memory budget is the reason. The sort keeps a cell's rows
    /// adjacent, so comparing with the previous row counts each cell once.
    /// Each page starts after the last cell counted rather than at a row
    /// offset, so dedup deleting a counted duplicate between pages cannot
    /// shift an uncounted cell past the next page; the sort is lexical to
    /// match the predicate's comparison. Any failed page throws; a partial
    /// count is never returned. `beforeCount` runs before each page (a test
    /// checkpoint).
    static func visibleHexVisitCount(
        hidden: Set<String>, in container: ModelContainer, pageSize: Int = 2_000,
        beforeCount: () throws -> Void = {}
    ) throws -> Int {
        var count = 0
        var previous: String?
        while true {
            try beforeCount()
            let fetched = try autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                var descriptor = FetchDescriptor<HexVisit>(
                    sortBy: [SortDescriptor(\.h3Index, comparator: .lexical)])
                if let last = previous {
                    descriptor.predicate = #Predicate { $0.h3Index > last }
                }
                descriptor.propertiesToFetch = [\.h3Index]
                descriptor.fetchLimit = pageSize
                let page = try context.fetch(descriptor)
                for visit in page {
                    let cell = visit.h3Index
                    guard cell != previous else { continue }
                    previous = cell
                    if !hidden.contains(cell) { count += 1 }
                }
                return page.count
            }
            if fetched < pageSize { return count }
        }
    }
}
