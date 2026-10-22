//
//  ExportStagingTests.swift
//  TravelLogTests
//
//  Staged backup and diagnostics copies in the temporary directory hold the
//  full history, so cleanup must find every one an interrupted share left,
//  and nothing else.
//

import Foundation
import Testing
@testable import TravelLog

@Suite("Export staging cleanup")
struct ExportStagingTests {

    @Test("removes staged backups (plain, gzip, .travellogbackup, half-written), restore and protected copies and diagnostics, keeps unrelated files")
    func removesOnlyStagedExports() throws {
        let directory = FileManager.default.temporaryDirectory
        let token = UUID().uuidString
        let backup = directory.appendingPathComponent("\(TripDataExporter.exportFilePrefix)\(token).json")
        let compressed = directory.appendingPathComponent("\(TripDataExporter.exportFilePrefix)\(token).json.gz")
        let backupFile = directory.appendingPathComponent(
            "\(TripDataExporter.exportFilePrefix)\(token).\(TripDataExporter.backupFileExtension)")
        let partial = directory.appendingPathComponent("\(TripDataExporter.exportFilePrefix)\(token).partial")
        let restoreCopy = directory.appendingPathComponent("\(TripDataExporter.restoreStagingPrefix)\(token).json")
        let lockedCopy = directory.appendingPathComponent(
            "\(TripDataExporter.restoreStagingPrefix)\(token).\(TripDataExporter.lockedCopyExtension)")
        let diagnostics = directory.appendingPathComponent(TripDataExporter.diagnosticsExportFileName)
        let unrelated = directory.appendingPathComponent("\(TripDataExporter.exportFilePrefix)\(token).txt")
        let staged = [backup, compressed, backupFile, partial, restoreCopy, lockedCopy, diagnostics]
        for url in staged + [unrelated] {
            try Data("{}".utf8).write(to: url)
        }
        defer { try? FileManager.default.removeItem(at: unrelated) }

        TripDataExporter.removeStagedExports()

        for url in staged {
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)")
        }
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
