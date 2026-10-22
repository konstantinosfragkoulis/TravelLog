//
//  DebugDiagnosticsTests.swift
//  TravelLogTests
//
//  Pins for the DEBUG-build diagnostics recorders (Services/Diagnostics/
//  DebugDiagnostics.swift): file round-trips, caps, corrupt-file
//  degradation, and the FM status lanes. All persistence runs against
//  scratch directories / scratch UserDefaults suites — never the app's
//  real Application Support.
//

import Foundation
import Testing
@testable import TravelLog

@Suite("Debug diagnostics recorders")
struct DebugDiagnosticsTests {

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("debug-diagnostics-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func gateAuditRoundTripsNewestFirstAndCaps() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(DebugGateAudit.load(from: dir).isEmpty)

        for i in 0..<(DebugGateAudit.maxPasses + 5) {
            let pass = DebugGateAudit.Pass(
                at: Date(timeIntervalSinceReferenceDate: Double(i)),
                threshold: 2.0,
                groups: [DebugGateAudit.GroupRecord(
                    id: UUID(),
                    start: Date(timeIntervalSinceReferenceDate: 0),
                    end: Date(timeIntervalSinceReferenceDate: 3600),
                    stayCount: 3, placeName: "Aegina",
                    score: 3.18, exemption: nil, cleared: true)])
            DebugGateAudit.record(pass, in: dir)
        }

        let loaded = DebugGateAudit.load(from: dir)
        #expect(loaded.count == DebugGateAudit.maxPasses)
        // Newest first; the cap dropped the OLDEST passes.
        #expect(loaded.first?.at == Date(timeIntervalSinceReferenceDate:
            Double(DebugGateAudit.maxPasses + 4)))
        #expect(loaded.last?.at == Date(timeIntervalSinceReferenceDate: 5))
        #expect(loaded.first?.groups.first?.placeName == "Aegina")
        #expect(loaded.first?.groups.first?.score == 3.18)

        DebugGateAudit.clear(in: dir)
        #expect(DebugGateAudit.load(from: dir).isEmpty)
    }

    @Test func healLogRoundTripsAndCaps() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 0..<(DebugHealLog.maxEntries + 3) {
            DebugHealLog.record(DebugHealLog.Entry(
                at: Date(timeIntervalSinceReferenceDate: Double(i)),
                kind: i % 2 == 0 ? "heal" : "rescue",
                tripsDissolved: i, recordsParked: 1, tripsRestored: 0), in: dir)
        }

        let loaded = DebugHealLog.load(from: dir)
        #expect(loaded.count == DebugHealLog.maxEntries)
        #expect(loaded.first?.at == Date(timeIntervalSinceReferenceDate:
            Double(DebugHealLog.maxEntries + 2)))
        #expect(loaded.first?.tripsDissolved == DebugHealLog.maxEntries + 2)
    }

    @Test func corruptFileReadsAsEmpty() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try #require(
            DebugDiagnosticsStore.url(DebugGateAudit.fileName, in: dir))
        try Data("not json at all".utf8).write(to: url)
        #expect(DebugGateAudit.load(from: dir).isEmpty)
    }

    @Test func schemaSeedExcludeDiscIsInert() {
        // The CloudKit schema-seed row is a 50 m exclude disc at 0°,0°.
        // Pin that membership verdicts and distances are BIT-identical with
        // and without it for real-world points (home centre, suburb, near
        // ring, far away) — the row exists only to create the
        // CD_HomeAreaOverride record type, never to change a verdict.
        let seed = HomeShape.fallbackDisc(latitude: 38.0, longitude: 23.8)
        let bare = HomeMembership(seed: seed)
        let seeded = HomeMembership(
            seed: seed,
            excludeDiscs: [(latitude: 0, longitude: 0, radiusKm: 0.05)])
        let probes: [(Double, Double)] = [
            (38.0, 23.8),          // home centre
            (38.0911, 23.7266),    // nearby mainland probe
            (37.9711, 23.6268),    // farther mainland probe
            (38.8652, 24.5601),    // far
            (39.2291, 20.2000),    // Paxos probe
        ]
        for (lat, lon) in probes {
            #expect(bare.contains(latitude: lat, longitude: lon, at: .now)
                 == seeded.contains(latitude: lat, longitude: lon, at: .now))
            #expect(bare.distanceKm(toLatitude: lat, longitude: lon, at: .now)
                 == seeded.distanceKm(toLatitude: lat, longitude: lon, at: .now))
        }
    }

    @Test func fmStatusKeepsSuccessAndErrorLanesIndependent() throws {
        let suiteName = "debug-fm-status-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let empty = DebugFMStatus.snapshot(defaults: defaults)
        #expect(empty.lastSuccessAt == nil)
        #expect(empty.lastErrorAt == nil)

        DebugFMStatus.recordFailure(
            feature: "Stay classification",
            message: "unsupportedLanguageOrLocale — Unsupported language id detected",
            defaults: defaults,
            at: Date(timeIntervalSinceReferenceDate: 100))
        DebugFMStatus.recordSuccess(
            feature: "Trip title", detail: "after one retry",
            defaults: defaults,
            at: Date(timeIntervalSinceReferenceDate: 200))

        let snapshot = DebugFMStatus.snapshot(defaults: defaults)
        // Error text is verbatim — the case name IS the diagnosis.
        #expect(snapshot.lastErrorMessage ==
            "unsupportedLanguageOrLocale — Unsupported language id detected")
        #expect(snapshot.lastErrorFeature == "Stay classification")
        #expect(snapshot.lastErrorAt == Date(timeIntervalSinceReferenceDate: 100))
        // A later success must NOT clear the error lane — both persist so
        // the screen can show "titles work, classification doesn't", which
        // was exactly the Greek-prompt field signature.
        #expect(snapshot.lastSuccessFeature == "Trip title")
        #expect(snapshot.lastSuccessDetail == "after one retry")
        #expect(snapshot.lastSuccessAt == Date(timeIntervalSinceReferenceDate: 200))
    }
}
