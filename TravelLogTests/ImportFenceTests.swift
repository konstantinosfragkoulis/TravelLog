//
//  ImportFenceTests.swift
//  TravelLogTests
//
//  Pins the cross-device double-import fence: identical-UUID Trip/Stay copies from a same-file two-device
//  import cannot be healed convergence-safely after the fact, so the fence
//  prevents them — a file fingerprint recorded in iCloud-KVS warns the
//  second device before it imports.
//

import Testing
import Foundation
@testable import TravelLog

struct ImportFenceTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func record(_ fp: String, device: String, daysAgo: Double = 0) -> ImportFence.Record {
        .init(fingerprint: fp, deviceID: device, date: t0.addingTimeInterval(-daysAgo * 86_400))
    }

    @Test("fingerprints are deterministic and content-sensitive")
    func fingerprintBasics() {
        let a = ImportFence.fingerprint(of: Data("backup-v1".utf8))
        #expect(a == ImportFence.fingerprint(of: Data("backup-v1".utf8)))
        #expect(a != ImportFence.fingerprint(of: Data("backup-v2".utf8)))
        #expect(a.count == 64)  // SHA256 hex
    }

    @Test("only a DIFFERENT device's record of the same file warns")
    func crossDeviceMatrix() {
        let records = [record("fp-1", device: "device-A")]
        // Another device importing the same file → warn.
        #expect(ImportFence.isCrossDeviceRepeat(
            records: records, fingerprint: "fp-1", deviceID: "device-B"))
        // Same device re-importing → silent (locally idempotent by id skip).
        #expect(!ImportFence.isCrossDeviceRepeat(
            records: records, fingerprint: "fp-1", deviceID: "device-A"))
        // A different file → silent.
        #expect(!ImportFence.isCrossDeviceRepeat(
            records: records, fingerprint: "fp-2", deviceID: "device-B"))
        #expect(!ImportFence.isCrossDeviceRepeat(
            records: [], fingerprint: "fp-1", deviceID: "device-B"))
    }

    @Test("appending replaces same-fingerprint records, keeps newest-first, and caps")
    func appendSemantics() {
        // Re-import on a second device takes over the fingerprint's record.
        let taken = ImportFence.appending(
            record("fp-1", device: "device-B"),
            to: [record("fp-1", device: "device-A", daysAgo: 2)]
        )
        #expect(taken.count == 1)
        #expect(taken.first?.deviceID == "device-B")

        // Cap: the oldest entries fall off, newest-first order preserved.
        let many = (0..<ImportFence.maxRecords + 3).map {
            record("fp-\($0)", device: "device-A", daysAgo: Double($0))
        }
        var accumulated: [ImportFence.Record] = []
        for entry in many.reversed() {
            accumulated = ImportFence.appending(entry, to: accumulated)
        }
        #expect(accumulated.count == ImportFence.maxRecords)
        #expect(accumulated.first?.fingerprint == "fp-0")
        #expect(!accumulated.contains { $0.fingerprint == "fp-\(ImportFence.maxRecords + 2)" })
    }
}
