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

    @Test("removes staged backups and diagnostics, keeps unrelated files")
    func removesOnlyStagedExports() throws {
        let directory = FileManager.default.temporaryDirectory
        let token = UUID().uuidString
        let backup = directory.appendingPathComponent("\(TripDataExporter.exportFilePrefix)\(token).json")
        let diagnostics = directory.appendingPathComponent(TripDataExporter.diagnosticsExportFileName)
        let unrelated = directory.appendingPathComponent("\(TripDataExporter.exportFilePrefix)\(token).txt")
        for url in [backup, diagnostics, unrelated] {
            try Data("{}".utf8).write(to: url)
        }
        defer { try? FileManager.default.removeItem(at: unrelated) }

        TripDataExporter.removeStagedExports()

        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(!FileManager.default.fileExists(atPath: diagnostics.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
