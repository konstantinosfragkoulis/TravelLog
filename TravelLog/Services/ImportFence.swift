//
//  ImportFence.swift
//  TravelLog
//
//  Two devices importing the SAME
//  backup JSON inside the CloudKit hydration window each see an empty
//  existing-id set and both insert identical-UUID Trip/Stay rows — and
//  because the copies are value-identical, no post-hoc deduplicator can pick
//  a survivor convergence-safely (the HexVisit shared-id lesson: a
//  delete-war to zero is worse than a duplicate). So this is PREVENTION:
//  each completed import records the file's fingerprint in iCloud Key-Value
//  Store (which syncs in seconds — far ahead of CloudKit row hydration),
//  and a second device importing the same file gets an explicit warning
//  before it proceeds. Same-device re-imports stay silent: those are
//  genuinely idempotent via the local existing-id skip.
//
//  Healing of rows that DO slip through both fences is deliberately not
//  attempted here — it needs a synced per-row origin discriminator (a future
//  schema change) to be war-safe.
//

import CryptoKit
import Foundation

nonisolated enum ImportFence {

    struct Record: Codable, Equatable {
        var fingerprint: String
        var deviceID: String
        var date: Date
    }

    static let kvsKey = "jsonImportFences_v1"
    static let deviceIDKey = "importFenceDeviceID_v1"
    /// Newest-first cap: backups are re-imported rarely; eight fingerprints
    /// comfortably cover a device-migration session without growing the
    /// 1 MB KVS budget.
    static let maxRecords = 8

    // MARK: - Pure core (test seams)

    static func fingerprint(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// True when this fingerprint was recorded by a DIFFERENT device — the
    /// cross-device double-import about to happen.
    static func isCrossDeviceRepeat(
        records: [Record], fingerprint: String, deviceID: String
    ) -> Bool {
        records.contains { $0.fingerprint == fingerprint && $0.deviceID != deviceID }
    }

    /// Newest-first append with same-fingerprint replacement (a re-import on
    /// THIS device takes over the record) and the size cap applied.
    static func appending(
        _ record: Record, to records: [Record]
    ) -> [Record] {
        var next = records.filter { $0.fingerprint != record.fingerprint }
        next.insert(record, at: 0)
        return Array(next.prefix(maxRecords))
    }

    // MARK: - IO wrappers

    /// Stable per-device identity for fence records (device-local by design;
    /// `identifierForVendor` can churn across reinstalls, which would only
    /// soften the fence, so a persisted UUID is used instead).
    static func deviceID(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: deviceIDKey) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: deviceIDKey)
        return fresh
    }

    static func loadRecords(store: NSUbiquitousKeyValueStore = .default) -> [Record] {
        guard let data = store.data(forKey: kvsKey) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    /// Was this exact file already imported on another device?
    static func warnsForCrossDeviceRepeat(of fingerprint: String) -> Bool {
        isCrossDeviceRepeat(
            records: loadRecords(), fingerprint: fingerprint, deviceID: deviceID()
        )
    }

    /// Record a completed import of `fingerprint` on this device.
    static func recordImport(
        of fingerprint: String,
        store: NSUbiquitousKeyValueStore = .default,
        now: Date = .now
    ) {
        let next = appending(
            Record(fingerprint: fingerprint, deviceID: deviceID(), date: now),
            to: loadRecords(store: store)
        )
        guard let data = try? JSONEncoder().encode(next) else { return }
        store.set(data, forKey: kvsKey)
        store.synchronize()
    }
}
