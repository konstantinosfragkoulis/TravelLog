import Foundation
import SwiftData

/// Read-only lookup behind the map's detail sheet: the stays recorded in one
/// resolution-6 cell, the trips they belong to, and the civil days they
/// touched. Managed objects stay on the context's executor; only values cross
/// the worker boundary, and the caller resolves trips on its own context.
nonisolated enum HexCellTripsLoader {
    struct Snapshot: Sendable, Equatable {
        /// Trip UUIDs, newest start first; same-id twins collapse to one.
        let tripIDs: [UUID]
        /// The exact row each id's stays point at, so a synced twin without
        /// the cell's stays never stands in for it.
        let tripRows: [UUID: PersistentIdentifier]
        /// The stays in the cell, for matching trip photos to it.
        let stayIDs: Set<UUID>
        /// Distinct civil days (in each stay's zone) any stay in the cell touched.
        let days: Int

        static let empty = Snapshot(tripIDs: [], tripRows: [:], stayIDs: [], days: 0)
    }

    /// One stay can add at most this many day labels, like `TravelDays`.
    private static let maxSpanDays = 3_650

    @MainActor
    static func load(h3Index: String, context: ModelContext) async throws -> Snapshot {
        try Task.checkCancellation()
        // A fresh context cannot see pending edits: read on the view context
        // then, as `HexMapDataLoader` does.
        if context.hasChanges {
            return try fetch(h3Index: h3Index, context: context)
        }
        let container = context.container
        let worker = Task.detached(priority: .userInitiated) {
            let readContext = ModelContext(container)
            readContext.autosaveEnabled = false
            return try fetch(h3Index: h3Index, context: readContext)
        }
        return try await withTaskCancellationHandler {
            let snapshot = try await worker.value
            try Task.checkCancellation()
            return snapshot
        } onCancel: {
            worker.cancel()
        }
    }

    /// Synchronous so all managed-object access stays on the caller's executor.
    static func fetch(h3Index: String, context: ModelContext) throws -> Snapshot {
        try Task.checkCancellation()
        guard !h3Index.isEmpty else { return .empty }
        var descriptor = FetchDescriptor<Stay>(predicate: #Predicate { $0.h3IndexRes6 == h3Index })
        // Scalars and the to-one trip only: no weather or ping payloads.
        descriptor.propertiesToFetch = [\.id, \.startTime, \.endTime, \.timeZoneIdentifier, \.trip]
        let stays = try context.fetch(descriptor)

        var stayIDs = Set<UUID>()
        var labels = Set<Date>()
        var trips: [UUID: Date] = [:]
        var tripRows: [UUID: PersistentIdentifier] = [:]
        for stay in stays {
            try Task.checkCancellation()
            stayIDs.insert(stay.id)
            let zone = stay.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
            if var day = TravelDays.label(for: stay.startTime, zone: zone),
               let last = TravelDays.label(for: max(stay.startTime, stay.endTime), zone: zone) {
                var added = 0
                while day <= last, added < maxSpanDays {
                    labels.insert(day)
                    added += 1
                    guard let next = TravelDays.labelCalendar.date(byAdding: .day, value: 1, to: day) else { break }
                    day = next
                }
            }
            if let trip = stay.trip, !trip.isDeleted, trips[trip.id] == nil {
                trips[trip.id] = trip.startDate
                tripRows[trip.id] = trip.persistentModelID
            }
        }
        let tripIDs = trips.sorted { $0.value == $1.value ? $0.key.uuidString < $1.key.uuidString : $0.value > $1.value }
            .map(\.key)
        return Snapshot(tripIDs: tripIDs, tripRows: tripRows, stayIDs: stayIDs, days: labels.count)
    }
}
