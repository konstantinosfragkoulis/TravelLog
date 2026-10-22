//
//  BackupEncryptionTests.swift
//  TravelLogTests
//
//  A backup protected with a password: it reads back with the password and
//  only with it, a wrong one can be retried, any change to its header or
//  segments is refused before a byte is restored, a tampered header cannot
//  demand unbounded work, and an unprotected backup reads as before.
//
//  All places, names and dates are fictional fixtures.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
@Suite("Password-protected backups")
struct BackupEncryptionTests {

    private static let password = "lantern harbour 42"
    /// The floor a header may ask for, so each derivation stays quick here.
    private static let iterations = BackupEncryption.acceptedIterations.lowerBound

    private func scratch() throws -> URL {
        try HardeningFixture.scratchDirectory("BackupEncryption")
    }

    /// `document` written through the protected sink, as the export writes it.
    private func seal(
        _ document: Data, to url: URL, password: String = BackupEncryptionTests.password,
        segmentSize: Int = 4_096
    ) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let sink = try BackupEncryptedFileSink(
            path: url.path,
            sealing: BackupEncryption.Sealing(
                password: password, iterations: Self.iterations, segmentSize: segmentSize))
        // Written in pieces, like the exporter's 64 KiB flushes.
        var offset = 0
        while offset < document.count {
            let end = min(offset + 3_000, document.count)
            try sink.write(document.subdata(in: offset..<end))
            offset = end
        }
        try sink.close()
    }

    /// A document large enough to fill many 4 KiB segments once compressed.
    private func largeDocument() -> Data {
        HardeningFixture.document(pings: 2_000)
    }

    @Test("a protected backup reads back as the document with its password, over many segments, and holds no plaintext")
    func roundTrip() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = largeDocument()
        let file = directory.appendingPathComponent("protected.travellogbackup")
        try seal(document, to: file)

        let sealed = try Data(contentsOf: file)
        #expect(BackupEncryption.isEnvelope(sealed))
        #expect(!sealed.starts(with: [0x1f, 0x8b]))
        #expect(sealed.count > BackupEncryption.headerLength + 4 * (4_096 + 16), "spans several segments")
        #expect(sealed.range(of: Data(Self.password.utf8)) == nil)
        #expect(sealed.range(of: Data("Mirto".utf8)) == nil)

        let staged = try BackupFile.stagedContents(of: file, password: Self.password)
        #expect(staged == document)
        let payload = try TripDataImporter.parse(staged)
        #expect(payload.trips.count == 1)
        #expect(payload.malformedTrips == 0 && payload.malformedStays == 0)
    }

    @Test("the export writes a protected backup through the store snapshot, and it imports")
    func exportWritesProtectedBackup() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: HardeningFixture.at(0))
        trip.endDate = HardeningFixture.at(10)
        trip.isComplete = true
        context.insert(trip)
        let stay = Stay(
            startTime: HardeningFixture.at(1), endTime: HardeningFixture.at(9),
            centroidLatitude: HardeningFixture.harbour.lat, centroidLongitude: HardeningFixture.harbour.lon,
            h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 100, pingIDs: [])
        stay.trip = trip
        context.insert(stay)
        try context.save()

        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("export.travellogbackup")
        let sealing = try BackupEncryption.Sealing(password: Self.password, iterations: Self.iterations)
        try await ExportSnapshotter(modelContainer: container)
            .writeBackupFile(BackupExtras(), to: file, sealing: sealing)
        #expect(try BackupEncryption.isProtectedFile(file))
        let payload = try TripDataImporter.parse(
            BackupFile.stagedContents(of: file, password: Self.password))
        #expect(payload.trips.map(\.id) == [trip.id])
    }

    @Test("a wrong password is refused with its own message before anything is decrypted, and the right one then opens it")
    func wrongPasswordCanBeRetried() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("protected.travellogbackup")
        let document = HardeningFixture.document()
        try seal(document, to: file)

        #expect(throws: TripDataImportError.wrongPassword) {
            try BackupFile.stagedContents(of: file, password: "lantern harbour 43")
        }
        #expect(throws: TripDataImportError.wrongPassword) {
            try BackupFile.stagedContents(of: file, password: "")
        }
        #expect(throws: TripDataImportError.wrongPassword) { try BackupFile.stagedContents(of: file) }
        #expect(try BackupFile.stagedContents(of: file, password: Self.password) == document)
        let message = TripDataImportError.wrongPassword.localizedDescription
        #expect(message == String(
            localized: "data-import.error.wrong-password",
            defaultValue: "That password is incorrect. Check it and try again."))
        #expect(!message.contains("\u{2014}") && !message.contains("\u{2013}"))
    }

    @Test("the same password typed composed or decomposed derives the same key")
    func passwordIsNormalized() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("protected.travellogbackup")
        let document = HardeningFixture.document()
        try seal(document, to: file, password: "caf\u{E9} \u{3AC}")
        #expect(try BackupFile.stagedContents(of: file, password: "cafe\u{301} \u{3B1}\u{301}") == document)
    }

    @Test("a flipped ciphertext or tag byte, a cut-off, reordered or extended file is refused as damaged",
          arguments: ["ciphertext", "tag", "cutAtSegment", "cutMidSegment", "swapped", "appended", "dropFinal"])
    func tamperedSegmentsAreRefused(tamper: String) throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("protected.travellogbackup")
        try seal(largeDocument(), to: file)
        var bytes = [UInt8](try Data(contentsOf: file))
        let header = BackupEncryption.headerLength
        let record = 4_096 + BackupEncryption.tagLength
        switch tamper {
        case "ciphertext": bytes[header + record + 100] ^= 0x01
        case "tag": bytes[header + 2 * record - 1] ^= 0x80
        case "cutAtSegment": bytes = Array(bytes.prefix(header + 3 * record))
        case "cutMidSegment": bytes = Array(bytes.prefix(header + 3 * record + 1_000))
        case "swapped":
            let first = Array(bytes[header..<(header + record)])
            let second = Array(bytes[(header + record)..<(header + 2 * record)])
            bytes.replaceSubrange(header..<(header + 2 * record), with: second + first)
        case "appended": bytes += [UInt8](repeating: 0x2A, count: 40)
        default:
            // The final segment is whatever follows the last full record.
            let body = bytes.count - header
            let final = body % record == 0 ? record : body % record
            bytes = Array(bytes.prefix(bytes.count - final))
        }
        try Data(bytes).write(to: file)
        #expect(throws: TripDataImportError.protectedBackupDamaged) {
            try BackupFile.stagedContents(of: file, password: Self.password)
        }
    }

    @Test("a header asking for billions of iterations, a huge segment, another version, or cut short fails fast without deriving a key")
    func tamperedHeaderIsBounded() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("protected.travellogbackup")
        try seal(HardeningFixture.document(), to: file)
        let original = [UInt8](try Data(contentsOf: file))

        func refused(_ edit: (inout [UInt8]) -> Void) throws -> any Error {
            var bytes = original
            edit(&bytes)
            try Data(bytes).write(to: file)
            let clock = ContinuousClock()
            var thrown: (any Error)?
            let elapsed = clock.measure {
                do { _ = try BackupFile.stagedContents(of: file, password: Self.password) } catch { thrown = error }
            }
            #expect(elapsed < .seconds(1), "a bounds failure must not run the key derivation")
            return try #require(thrown)
        }

        // Iterations at offset 10, the segment size at 14 (big-endian).
        let hugeIterations = try refused { $0.replaceSubrange(10..<14, with: [0xFF, 0xFF, 0xFF, 0xFF]) }
        #expect(hugeIterations as? TripDataImportError == .protectedBackupDamaged)
        let fewIterations = try refused { $0.replaceSubrange(10..<14, with: [0, 0, 0, 1]) }
        #expect(fewIterations as? TripDataImportError == .protectedBackupDamaged)
        let hugeSegment = try refused { $0.replaceSubrange(14..<18, with: [0x7F, 0xFF, 0xFF, 0xFF]) }
        #expect(hugeSegment as? TripDataImportError == .protectedBackupDamaged)
        let zeroSegment = try refused { $0.replaceSubrange(14..<18, with: [0, 0, 0, 0]) }
        #expect(zeroSegment as? TripDataImportError == .protectedBackupDamaged)
        let newer = try refused { $0[8] = 2 }
        #expect(newer as? TripDataImportError == .protectedBackupNewer)
        let otherKDF = try refused { $0[9] = 7 }
        #expect(otherKDF as? TripDataImportError == .protectedBackupNewer)
        let cut = try refused { $0 = Array($0.prefix(30)) }
        #expect(cut as? TripDataImportError == .protectedBackupDamaged)
        let headerOnly = try refused { $0 = Array($0.prefix(BackupEncryption.headerLength)) }
        #expect(headerOnly is TripDataImportError)
    }

    @Test("a changed salt or check reads as a wrong password; a changed nonce or segment size fails authentication")
    func headerFieldsAreAuthenticated() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("protected.travellogbackup")
        try seal(largeDocument(), to: file)
        let original = [UInt8](try Data(contentsOf: file))
        func outcome(flipping offset: Int) throws -> TripDataImportError? {
            var bytes = original
            bytes[offset] ^= 0x01
            try Data(bytes).write(to: file)
            do {
                _ = try BackupFile.stagedContents(of: file, password: Self.password)
                return nil
            } catch {
                return error as? TripDataImportError
            }
        }
        #expect(try outcome(flipping: 20) == .wrongPassword, "salt")
        #expect(try outcome(flipping: 50) == .wrongPassword, "check")
        #expect(try outcome(flipping: 40) == .protectedBackupDamaged, "nonce")
        #expect(try outcome(flipping: 16) == .protectedBackupDamaged, "segment size")
    }

    @Test("an opened protected backup waits as a private sealed copy that a later password opens")
    func openedProtectedBackupWaitsForPassword() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("protected.travellogbackup")
        let document = HardeningFixture.document()
        try seal(document, to: file)

        var locked: URL?
        do {
            _ = try BackupFile.openedContents(of: file)
            Issue.record("a protected backup must ask for its password")
        } catch let found as ProtectedBackupFound {
            locked = found.lockedCopy
        }
        let copy = try #require(locked)
        #expect(copy.lastPathComponent.hasPrefix(TripDataExporter.restoreStagingPrefix))
        #expect(copy.pathExtension == TripDataExporter.lockedCopyExtension)
        #expect(try Data(contentsOf: copy) == Data(contentsOf: file))
        #expect(FileManager.default.fileExists(atPath: file.path), "the user's own file is left in place")

        #expect(throws: TripDataImportError.wrongPassword) {
            try BackupFile.unlockedContents(ofLockedCopy: copy, password: "wrong")
        }
        #expect(try BackupFile.unlockedContents(ofLockedCopy: copy, password: Self.password) == document)
        try FileManager.default.removeItem(at: copy)
    }

    @Test("an unprotected backup reads exactly as before, a password given for it is ignored, and a protected bomb still fails fast")
    func unprotectedBackupIsUnchanged() throws {
        let directory = try scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = HardeningFixture.document()
        let gzipped = directory.appendingPathComponent("plain.travellogbackup")
        try HardeningFixture.gzip(document, to: gzipped)
        #expect(try BackupFile.stagedContents(of: gzipped) == document)
        #expect(try BackupFile.stagedContents(of: gzipped, password: Self.password) == document)
        #expect(try BackupFile.openedContents(of: gzipped) == document)
        let json = directory.appendingPathComponent("plain.json")
        try document.write(to: json)
        #expect(try BackupFile.stagedContents(of: json) == document)
        #expect(!(try BackupEncryption.isProtectedFile(gzipped)))

        let bomb = directory.appendingPathComponent("bomb.travellogbackup")
        FileManager.default.createFile(atPath: bomb.path, contents: nil)
        let sink = try BackupEncryptedFileSink(
            path: bomb.path,
            sealing: BackupEncryption.Sealing(password: Self.password, iterations: Self.iterations))
        let zeros = Data(count: 1 << 20)
        for _ in 0..<256 { try sink.write(zeros) }
        try sink.close()
        #expect(throws: TripDataImportError.tooLarge) {
            try BackupFile.stagedContents(of: bomb, password: Self.password)
        }
    }

    @Test("the export's iteration count is calibrated within its bounds, all of which a header may carry")
    func iterationsAreCalibratedWithinBounds() {
        let iterations = BackupEncryption.calibratedIterations(for: Self.password)
        #expect(BackupEncryption.exportIterations.contains(iterations))
        #expect(BackupEncryption.acceptedIterations.contains(BackupEncryption.exportIterations.lowerBound))
        #expect(BackupEncryption.acceptedIterations.contains(BackupEncryption.exportIterations.upperBound))
        #expect(BackupEncryption.acceptedSegmentSizes.contains(UInt32(BackupEncryption.segmentSize)))
    }
}
