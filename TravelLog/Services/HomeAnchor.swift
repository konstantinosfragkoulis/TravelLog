//
//  HomeAnchor.swift
//  TravelLog
//
//  Compiled into the app and the widget extension.
//

import Foundation
import SwiftData

/// A place that can own a `.home` stay, as a value: a `Home` row or a
/// `TemporaryHome` row. Classification and attribution read this list. Code
/// that reads `Home` rows for meaning keeps reading `Home`.
nonisolated struct HomeAnchor: Sendable, Equatable, Identifiable {
    nonisolated enum Kind: String, Sendable { case home, temporary }

    let id: UUID
    let kind: Kind
    /// The stored label; empty when the user gave none.
    let label: String
    let latitude: Double
    let longitude: Double
    let radiusKm: Double
    let locality: String?
    let isoCountryCode: String?
    let startedAt: Date
    let endedAt: Date?

    var isTemporary: Bool { kind == .temporary }

    /// Inclusive window, the rule `TripClassifier.matchesHome` pass 1 uses.
    func covers(_ date: Date) -> Bool {
        if let endedAt, date > endedAt { return false }
        return startedAt <= date
    }
}

nonisolated extension HomeAnchor {
    init(_ home: Home) {
        self.init(
            id: home.id, kind: .home, label: home.label,
            latitude: home.latitude, longitude: home.longitude, radiusKm: home.radiusKm,
            locality: home.locality, isoCountryCode: home.isoCountryCode,
            startedAt: home.startedAt, endedAt: home.endedAt)
    }

    init(_ temporaryHome: TemporaryHome) {
        self.init(
            id: temporaryHome.id, kind: .temporary, label: temporaryHome.label,
            latitude: temporaryHome.latitude, longitude: temporaryHome.longitude,
            radiusKm: temporaryHome.radiusKm,
            locality: temporaryHome.locality, isoCountryCode: temporaryHome.isoCountryCode,
            startedAt: temporaryHome.startedAt, endedAt: temporaryHome.endedAt)
    }
}

nonisolated enum HomeAnchors {

    /// Every Home row plus every temporary home. Throws when either read fails.
    /// Home rows keep their fetch order and are not filtered by `endedAt`;
    /// callers apply windows.
    static func fetch(in context: ModelContext) throws -> [HomeAnchor] {
        let homes = try context.fetch(FetchDescriptor<Home>())
        return try homes.map { HomeAnchor($0) } + temporaryHomes(in: context)
    }

    /// Temporary homes only, same-id twins collapsed.
    static func temporaryHomes(in context: ModelContext) throws -> [HomeAnchor] {
        collapsingTwins(try context.fetch(FetchDescriptor<TemporaryHome>()))
            .map { HomeAnchor($0) }
    }

    /// One row per `id`, ordered by `startedAt` then `id`. Two devices
    /// importing one backup leave two physical rows with one `id`; the winner
    /// is the latest `modifiedAt`, then the earliest `createdAt`, then the
    /// smallest stored content, then the smaller row identifier, so the choice
    /// never depends on fetch order. The losing rows are left in the store.
    ///
    /// An id with any removed row is dropped before ranking: removal is a fact
    /// about the id, so no twin outranks it whatever its dates or `modifiedAt`.
    static func collapsingTwins(_ rows: [TemporaryHome]) -> [TemporaryHome] {
        let removed = removedIDs(rows)
        return oneRowPerID(rows.filter { !removed.contains($0.id) })
    }

    /// The ids with at least one removed row. The set only grows as rows
    /// arrive, so every device that holds a tombstone answers alike.
    static func removedIDs(_ rows: [TemporaryHome]) -> Set<UUID> {
        Set(rows.lazy.filter { $0.removedAt != nil }.map(\.id))
    }

    /// One removed row per removed id, ranked among that id's removed rows by
    /// the twin rule, in the same order as `collapsingTwins`. For export.
    static func removedTwins(_ rows: [TemporaryHome]) -> [TemporaryHome] {
        oneRowPerID(rows.filter { $0.removedAt != nil })
    }

    private static func oneRowPerID(_ rows: [TemporaryHome]) -> [TemporaryHome] {
        var winners: [UUID: TemporaryHome] = [:]
        for row in rows {
            if let current = winners[row.id], !outranks(row, current) { continue }
            winners[row.id] = row
        }
        return winners.values.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Who a `.home` stay belongs to where it is shown (cards, ledger, widget,
    /// departure attribution): what its home writer recorded in
    /// `Stay.temporaryHomeID`, never the nearest centre. Classification
    /// keeps its own rule.
    nonisolated enum RecordedOwner: Sendable, Equatable {
        /// Nothing recorded: a real Home made it home.
        case realHome
        /// The temporary home recorded, live or removed.
        case temporary(UUID)
        /// A recorded id no row in this store carries yet (it has not
        /// synced): nobody's until the row arrives.
        case unresolved
    }

    /// The owner `temporaryHomeID` records. `knownTemporaryHomeIDs` holds
    /// every id with a row in the store, removed ones included.
    static func recordedOwner(
        temporaryHomeID: UUID?, knownTemporaryHomeIDs: Set<UUID>
    ) -> RecordedOwner {
        guard let temporaryHomeID else { return .realHome }
        return knownTemporaryHomeIDs.contains(temporaryHomeID) ? .temporary(temporaryHomeID) : .unresolved
    }

    private static func outranks(_ a: TemporaryHome, _ b: TemporaryHome) -> Bool {
        if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        let (contentA, contentB) = (storedContent(a), storedContent(b))
        if contentA != contentB { return contentA.lexicographicallyPrecedes(contentB) }
        // Identical rows: the values agree, but callers also read the winner's
        // row identity, so that must not follow input order either.
        return String(describing: a.persistentModelID) < String(describing: b.persistentModelID)
    }

    /// Every stored field the two date ranks do not cover, in a fixed order.
    /// Nil and empty stay distinct, so rows that tie here are identical.
    private static func storedContent(_ row: TemporaryHome) -> [String] {
        func text(_ value: String?) -> String { value.map { "=" + $0 } ?? "" }
        func date(_ value: Date?) -> String {
            value.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? ""
        }
        return [
            row.label,
            String(row.latitude.bitPattern), String(row.longitude.bitPattern),
            String(row.radiusKm.bitPattern),
            text(row.locality), text(row.administrativeArea),
            text(row.country), text(row.isoCountryCode),
            date(row.startedAt), date(row.endedAt), text(row.timeZoneIdentifier),
            date(row.removedAt),
        ]
    }
}
