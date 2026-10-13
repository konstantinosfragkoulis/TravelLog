//
//  DebugDiagnostics.swift
//  TravelLog
//
//  DEBUG-build field instrumentation, so a device answers "did FM run?", "is
//  that new trip real?" and "what does the home area actually contain?" without
//  Xcode attached. Three tiny recorders plus the value types the Debug
//  Diagnostics screens (Views/DebugDiagnosticsViews.swift) and the
//  diagnostics-export bundle render:
//
//  - `DebugGateAudit`   — the confidence gate's last assembly passes: every
//                         candidate group with its actual score vs θ,
//                         including the suppressed ones.
//  - `DebugFMStatus`    — last Foundation Models success and last error
//                         VERBATIM, per feature (the Greek-prompt
//                         `unsupportedLanguageOrLocale` failure would have
//                         been visible in Settings within a day).
//  - `DebugHealLog`     — what the last home-area heal / rescue passes did.
//
//  The whole file is `#if DEBUG`: nothing here exists in Release, and every
//  call site is fenced the same way, so shipping builds record nothing and
//  show nothing. Persistence is JSON files in Application Support with a
//  `debug-` prefix (the DissolvedTripQueue pattern: decode failure reads as
//  empty, writes are atomic, caps keep files bounded).
//

#if DEBUG

import Foundation
import os.log

// MARK: - Shared persistence

/// Capped JSON-file persistence for the debug recorders. Nonisolated on
/// purpose: recorders are called from the classifier actor and read from
/// MainActor views; plain file IO with atomic writes needs neither.
nonisolated enum DebugDiagnosticsStore {

    private static let logger = Logger(
        subsystem: "com.travellog.app", category: "DebugDiagnostics")

    /// Optional directory override so tests run against scratch space —
    /// the DissolvedTripQueue pattern.
    static func url(_ fileName: String, in directory: URL? = nil) -> URL? {
        if let directory { return directory.appendingPathComponent(fileName) }
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return base.appendingPathComponent(fileName)
    }

    static func load<T: Decodable>(
        _ type: T.Type, from fileName: String, in directory: URL? = nil
    ) -> T? {
        guard let url = url(fileName, in: directory),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(
        _ value: T, to fileName: String, in directory: URL? = nil
    ) {
        guard let url = url(fileName, in: directory) else { return }
        do {
            let data = try JSONEncoder().encode(value)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Debug diagnostics persist failed for \(fileName): \(error.localizedDescription)")
        }
    }
}

// MARK: - Home-area snapshot

/// Everything the home-area learning system currently believes, as one
/// Sendable value — assembled by `TripClassifier.debugHomeAreaSnapshot()`
/// from the SAME primed state the pipeline uses (never a parallel
/// derivation that could drift).
nonisolated struct DebugHomeAreaSnapshot: Codable, Sendable {

    nonisolated struct Window: Codable, Sendable {
        let start: Date
        let end: Date
    }

    nonisolated struct Disc: Codable, Sendable {
        let centerLatitude: Double
        let centerLongitude: Double
        let radiusKm: Double
        let returnTimes: [Date]
        let validity: [Window]
    }

    nonisolated struct HomeInfo: Codable, Sendable, Identifiable {
        let id: UUID
        let label: String
        let latitude: Double
        let longitude: Double
        let startedAt: Date
        let endedAt: Date?
        /// "urbanCentre" / "fallbackDisc" / "unprimed" (rollout off, or the
        /// resolver never ran for this coordinate).
        let seedKind: String
        let seedName: String?
        let seedID: Int64?
        let areaKm2: Double?
        /// `D*` — the confidence score's distance scale for this home.
        let dStarKm: Double?
        let discs: [Disc]
    }

    nonisolated struct OverrideInfo: Codable, Sendable, Identifiable {
        let id: UUID
        let kind: String
        let centerLatitude: Double
        let centerLongitude: Double
        let radiusKm: Double
        let homeID: UUID?
        let sourceTripName: String?
        let createdAt: Date
    }

    let generatedAt: Date
    let homes: [HomeInfo]
    let overrides: [OverrideInfo]
    /// The LIVE fingerprint — what `HomeAreaHealing.healIfNeeded` would
    /// compare against its stored copy right now.
    let fingerprint: String
}

// MARK: - Confidence-gate audit

/// Rolling record of the gate's recent assembly passes. Written from the
/// classifier actor at the exact site the gate filters candidate groups, so
/// the recorded verdict IS the verdict (the score is recomputed for display
/// through the same seams `groupClearsConfidence` uses).
nonisolated enum DebugGateAudit {

    nonisolated struct GroupRecord: Codable, Sendable, Identifiable {
        let id: UUID
        let start: Date
        let end: Date
        let stayCount: Int
        let placeName: String?
        /// Best excursion score in the group; nil when the group bypassed
        /// scoring (see `exemption`).
        let score: Double?
        /// Why the group bypassed scoring — nil means it was scored.
        let exemption: String?
        let cleared: Bool
        var fastPath: String? = nil
    }

    nonisolated struct Pass: Codable, Sendable {
        let at: Date
        let threshold: Double
        let groups: [GroupRecord]
    }

    static let fileName = "debug-gate-audit-v1.json"
    /// Enough history to cover a multi-day field test without unbounded
    /// growth; a pass is a handful of small records.
    static let maxPasses = 25

    /// Newest first.
    static func load(from directory: URL? = nil) -> [Pass] {
        (DebugDiagnosticsStore.load([Pass].self, from: fileName, in: directory) ?? [])
            .sorted { $0.at > $1.at }
    }

    static func record(_ pass: Pass, in directory: URL? = nil) {
        let all = ([pass] + load(from: directory)).prefix(maxPasses)
        DebugDiagnosticsStore.save(Array(all), to: fileName, in: directory)
    }

    static func clear(in directory: URL? = nil) {
        guard let url = DebugDiagnosticsStore.url(fileName, in: directory) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Foundation Models status

/// Last FM success and last FM error, per call, error text verbatim.
/// UserDefaults-backed (five small keys — no file needed).
nonisolated enum DebugFMStatus {

    nonisolated struct Snapshot: Codable, Sendable {
        let lastSuccessFeature: String?
        let lastSuccessDetail: String?
        let lastSuccessAt: Date?
        let lastErrorFeature: String?
        let lastErrorMessage: String?
        let lastErrorAt: Date?
    }

    private static let successFeatureKey = "debugFMLastSuccessFeature_v1"
    private static let successDetailKey = "debugFMLastSuccessDetail_v1"
    private static let successAtKey = "debugFMLastSuccessAt_v1"
    private static let errorFeatureKey = "debugFMLastErrorFeature_v1"
    private static let errorMessageKey = "debugFMLastErrorMessage_v1"
    private static let errorAtKey = "debugFMLastErrorAt_v1"

    static func recordSuccess(
        feature: String, detail: String? = nil,
        defaults: UserDefaults = .standard, at date: Date = .now
    ) {
        defaults.set(feature, forKey: successFeatureKey)
        defaults.set(detail, forKey: successDetailKey)
        defaults.set(date, forKey: successAtKey)
    }

    /// `message` should be the VERBATIM error — `String(describing: error)`
    /// beats `localizedDescription` here because FoundationModels' enum
    /// cases (`unsupportedLanguageOrLocale`, guardrail violations) localize
    /// into generic prose that hides the case.
    static func recordFailure(
        feature: String, message: String,
        defaults: UserDefaults = .standard, at date: Date = .now
    ) {
        defaults.set(feature, forKey: errorFeatureKey)
        defaults.set(message, forKey: errorMessageKey)
        defaults.set(date, forKey: errorAtKey)
    }

    static func snapshot(defaults: UserDefaults = .standard) -> Snapshot {
        Snapshot(
            lastSuccessFeature: defaults.string(forKey: successFeatureKey),
            lastSuccessDetail: defaults.string(forKey: successDetailKey),
            lastSuccessAt: defaults.object(forKey: successAtKey) as? Date,
            lastErrorFeature: defaults.string(forKey: errorFeatureKey),
            lastErrorMessage: defaults.string(forKey: errorMessageKey),
            lastErrorAt: defaults.object(forKey: errorAtKey) as? Date)
    }
}

// MARK: - Heal log

/// What the last home-area healing / rescue passes actually did. Only
/// passes that got past the fingerprint guard (or took the rescue gate) are
/// recorded — quiescent activations would be pure noise.
nonisolated enum DebugHealLog {

    nonisolated struct Entry: Codable, Sendable, Identifiable {
        let id: UUID
        let at: Date
        /// "heal" (fingerprint moved) or "rescue" (late-guard auto-restore).
        let kind: String
        let tripsDissolved: Int
        let recordsParked: Int
        let tripsRestored: Int

        init(at: Date, kind: String, tripsDissolved: Int,
             recordsParked: Int, tripsRestored: Int) {
            self.id = UUID()
            self.at = at
            self.kind = kind
            self.tripsDissolved = tripsDissolved
            self.recordsParked = recordsParked
            self.tripsRestored = tripsRestored
        }
    }

    static let fileName = "debug-heal-log-v1.json"
    static let maxEntries = 40

    /// Newest first.
    static func load(from directory: URL? = nil) -> [Entry] {
        (DebugDiagnosticsStore.load([Entry].self, from: fileName, in: directory) ?? [])
            .sorted { $0.at > $1.at }
    }

    static func record(_ entry: Entry, in directory: URL? = nil) {
        let all = ([entry] + load(from: directory)).prefix(maxEntries)
        DebugDiagnosticsStore.save(Array(all), to: fileName, in: directory)
    }

    static func clear(in directory: URL? = nil) {
        guard let url = DebugDiagnosticsStore.url(fileName, in: directory) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

#endif
