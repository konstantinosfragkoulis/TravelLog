//
//  OpenedFileTests.swift
//  TravelLogTests
//
//  Files the system opens Travel Log with: the trip and backup types are
//  declared so Files hands them to Travel Log rather than previewing them,
//  each opened URL goes to its own screen, and only the system's Inbox copy
//  is ever removed.
//

import Foundation
import Testing
import UniformTypeIdentifiers
@testable import TravelLog

@Suite("Opened files")
struct OpenedFileTests {

    @Test("the trip type is data and content, not JSON, and owns its extension")
    func tripTypeConformance() {
        let trip = UTType.travelLogTrip
        #expect(trip.identifier == "com.kfragkoulis.travellog.trip")
        #expect(trip.conforms(to: .data))
        #expect(trip.conforms(to: .content))
        #expect(!trip.conforms(to: .json))
        #expect(!trip.conforms(to: .text))
        #expect(UTType(filenameExtension: TripShareFile.fileExtension) == trip)
        #expect(trip.isDeclared)
    }

    @Test("the backup type is data and content, not gzip, and owns its extension")
    func backupTypeConformance() {
        let backup = UTType.travelLogBackup
        #expect(backup.identifier == "com.kfragkoulis.travellog.backup")
        #expect(backup.conforms(to: .data))
        #expect(backup.conforms(to: .content))
        #expect(!backup.conforms(to: .gzip))
        #expect(!backup.conforms(to: .json))
        #expect(UTType(filenameExtension: "travellogbackup") == backup)
        #expect(backup.isDeclared)
    }

    @Test("both document types are owned by Travel Log, opened in place, and named in every language")
    func documentTypesAreDeclared() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info["LSSupportsOpeningDocumentsInPlace"] as? Bool == true)
        let types = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
        for identifier in [UTType.travelLogTrip.identifier, UTType.travelLogBackup.identifier] {
            let declaration = types.first { ($0["LSItemContentTypes"] as? [String])?.contains(identifier) == true }
            #expect(declaration?["LSHandlerRank"] as? String == "Owner", "\(identifier)")
            let name = try #require(declaration?["CFBundleTypeName"] as? String, "\(identifier)")
            // The name is the InfoPlist.strings key; every language translates it.
            for language in Bundle.main.localizations where language != "en" && language != "Base" {
                let folder = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
                let localized = Bundle(path: folder)?.localizedString(forKey: name, value: nil, table: "InfoPlist")
                #expect(localized != nil && localized != name, "\(name) in \(language)")
            }
        }
    }

    @Test("a backup is written as TravelLog-Export-<date>.travellogbackup")
    func backupFileName() {
        let day = Date(timeIntervalSinceReferenceDate: 950_000_000)
        let url = TripDataExporter.exportFileURL(now: day)
        let expected = "TravelLog-Export-\(day.formatted(.iso8601.year().month().day())).travellogbackup"
        #expect(url.lastPathComponent == expected)
        #expect(url.pathExtension == TripDataExporter.backupFileExtension)
        #expect(UTType(filenameExtension: url.pathExtension) == .travelLogBackup)
        #expect(OpenedFile.kind(of: url) == .backup)
    }

    @Test("the backup picker takes the new type, an earlier build's .json.gz and plain JSON")
    @MainActor
    func backupPickerTypes() throws {
        let allowed = SettingsImportExportView.backupContentTypes
        func accepts(_ fileExtension: String) throws -> Bool {
            let type = try #require(UTType(filenameExtension: fileExtension))
            return allowed.contains { type.conforms(to: $0) }
        }
        #expect(try accepts("travellogbackup"))
        #expect(try accepts("gz"))
        #expect(try accepts("json"))
        #expect(try !accepts("travellogtrip"))
    }

    @Test("an opened URL routes to the trip preview, the backup import or neither")
    func routing() {
        let folder = URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/Downloads", isDirectory: true)
        #expect(OpenedFile.kind(of: folder.appendingPathComponent("Lakeside.travellogtrip")) == .trip)
        #expect(OpenedFile.kind(of: folder.appendingPathComponent("Lakeside.TravelLogTrip")) == .trip)
        #expect(OpenedFile.kind(of: folder.appendingPathComponent("TravelLog-Export-2031-04-05.travellogbackup")) == .backup)
        #expect(OpenedFile.kind(of: folder.appendingPathComponent("TravelLog-Export-2031-04-05.TRAVELLOGBACKUP")) == .backup)
        // An earlier build's backup is restored through the picker, never routed.
        #expect(OpenedFile.kind(of: folder.appendingPathComponent("TravelLog-Export-2031-04-05.json.gz")) == .other)
        #expect(OpenedFile.kind(of: folder.appendingPathComponent("notes.json")) == .other)
        #expect(OpenedFile.kind(of: URL(string: "travellog://trips")!) == .other)
        #expect(OpenedFile.kind(of: URL(string: "https://example.com/Lakeside.travellogtrip")!) == .other)
    }

    @Test("only a file in the system's Inbox counts as its copy")
    func inboxCopy() {
        let documents = URL(fileURLWithPath: "/tmp/OpenedFileTests/Documents", isDirectory: true)
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true)
        #expect(OpenedFile.isInboxCopy(inbox.appendingPathComponent("Lakeside.travellogtrip"), inbox: inbox))
        #expect(!OpenedFile.isInboxCopy(documents.appendingPathComponent("Lakeside.travellogtrip"), inbox: inbox))
        #expect(!OpenedFile.isInboxCopy(
            inbox.appendingPathComponent("Nested", isDirectory: true).appendingPathComponent("Lakeside.travellogtrip"),
            inbox: inbox))
        #expect(!OpenedFile.isInboxCopy(
            FileManager.default.temporaryDirectory.appendingPathComponent("Lakeside.travellogtrip"), inbox: inbox))
        #expect(!OpenedFile.isInboxCopy(URL(string: "https://example.com/Inbox/Lakeside.travellogtrip")!, inbox: inbox))
    }

    @Test("a file read through the opened-file path is read whole and left in place")
    func coordinatedReadLeavesOriginal() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenedFileTests-\(UUID().uuidString).travellogtrip")
        try Data("{\"shareFormatVersion\":1}".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = try OpenedFile.read(file) { try Data(contentsOf: $0) }
        #expect(String(decoding: data, as: UTF8.self) == "{\"shareFormatVersion\":1}")
        OpenedFile.removeInboxCopy(file)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
