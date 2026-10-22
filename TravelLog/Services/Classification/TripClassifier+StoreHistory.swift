//
//  TripClassifier+StoreHistory.swift
//  TravelLog
//

import Foundation
import SwiftData

extension TripClassifier {

    /// What committed to the store after a history token, by entity: the
    /// change generation that lets a memo of a history-sized read stand on an
    /// unchanged store without reading it again. Store history counts every
    /// committed writer (this device's contexts, CloudKit, a restore), unlike
    /// `StoreChangeTracker`, which gate units bump whether or not they wrote.
    /// Tokens are kept in memory only, against this actor's own container.
    struct StoreHistoryWindow {
        /// One entity's changed rows. Past `storeHistoryRowLimit` they are no
        /// longer listed and `overflowed` is set: read the entity as wholly changed.
        struct Rows {
            var inserted: [PersistentIdentifier] = []
            var updated: [PersistentIdentifier] = []
            var deleted: [PersistentIdentifier] = []
            var overflowed = false
            var count: Int { inserted.count + updated.count + deleted.count }
        }

        /// The newest token the window read; the next window starts after it.
        let latest: DefaultHistoryToken
        let rows: [String: Rows]

        var isEmpty: Bool { rows.isEmpty }

        func rows<T: PersistentModel>(of type: T.Type) -> Rows? {
            rows[Schema.entityName(for: type)]
        }
    }

    nonisolated static let storeHistoryRowLimit = 256

    /// The newest history token, read before the reads it will date. Nil when
    /// the store keeps no history or the read fails: callers then hold no memo.
    func newestStoreHistoryToken() -> DefaultHistoryToken? {
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>(
            sortBy: [SortDescriptor(\.transactionIdentifier, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? modelContext.fetchHistory(descriptor))?.first?.token
    }

    /// Every transaction committed after `token`, listing up to `rowLimit` rows
    /// per entity. Nil when there is no token or the read fails: nothing is
    /// known, so everything may have changed.
    func storeHistory(
        after token: DefaultHistoryToken?, rowLimit: Int = TripClassifier.storeHistoryRowLimit
    ) -> StoreHistoryWindow? {
        guard let token else { return nil }
        let transactions: [DefaultHistoryTransaction]
        do {
            transactions = try modelContext.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>(
                predicate: #Predicate<DefaultHistoryTransaction> { $0.token > token }))
        } catch {
            return nil
        }
        var rows: [String: StoreHistoryWindow.Rows] = [:]
        for transaction in transactions {
            for change in transaction.changes {
                let id = change.changedPersistentIdentifier
                var entry = rows[id.entityName] ?? StoreHistoryWindow.Rows()
                if entry.overflowed || entry.count >= rowLimit {
                    entry = StoreHistoryWindow.Rows(overflowed: true)
                } else {
                    switch change {
                    case .insert: entry.inserted.append(id)
                    case .update: entry.updated.append(id)
                    case .delete: entry.deleted.append(id)
                    @unknown default: entry.overflowed = true
                    }
                }
                rows[id.entityName] = entry
            }
        }
        return StoreHistoryWindow(latest: transactions.map(\.token).max() ?? token, rows: rows)
    }
}
