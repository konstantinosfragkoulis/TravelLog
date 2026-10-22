//
//  TripShareStaging.swift
//  TravelLog
//
//  Builds every item one share sheet carries: the home-filtered trips (read
//  when the sheet opens, so its preview shows what will be sent, and read
//  again right before the system share sheet, which is refused if the trips
//  or the home areas changed meanwhile), then any of a Travel Log file, one
//  GPX file and the overview images (one per trip, or one summary of
//  several), written to a private temporary folder that is removed when the
//  sheet closes (and at the next launch or Delete All Data if it was not).
//  Filtering, encoding and writing run off the main actor on value
//  snapshots; only the images render on it.
//

import Foundation
import SwiftData
import UIKit

enum TripShareStaging {

    struct Options: Equatable {
        var overviewImage = true
        var travelLogFile = true
        var gpxRoute = false
        var images: TripShareImages = .perTrip

        var isEmpty: Bool { !overviewImage && !travelLogFile && !gpxRoute }
    }

    /// The chosen trips, filtered and ready to share.
    struct Prepared {
        let file: TripShareFile
        /// Trips that kept nothing once the home areas were left out.
        let omitted: Int
        /// Where the routes break; never written.
        let exclusions: TripShareExclusions

        /// Whether `other`, read later, would share exactly this: the same
        /// filtered trips, judged against the same home areas.
        func isCurrent(_ other: Prepared) -> Bool {
            file.trips == other.file.trips && omitted == other.omitted && exclusions == other.exclusions
        }
    }

    struct Staged {
        let directory: URL
        let items: [URL]
        /// Trips that kept nothing once the home areas were left out.
        let omitted: Int
    }

    enum StagingError: Error {
        case homesUnreadable
        case tripsUnreadable
        /// None of the chosen trips exists any more.
        case tripsMissing
        case nothingToShare
        /// The trips or the home areas changed after the preview was read.
        case changed
        /// The Travel Log file would be larger than a recipient opens.
        case tooLarge
        case writeFailed
    }

    nonisolated static let directoryPrefix = "TravelLog-Share-"

    /// Reads the chosen trips and leaves out everything inside the home areas.
    @MainActor
    static func prepare(
        tripIDs: [UUID],
        container: ModelContainer = AppDelegate.modelContainer,
        homeRings: (() async throws -> [TripClassifier.HomeRing])? = nil
    ) async throws(StagingError) -> Prepared {
        let rings: [TripClassifier.HomeRing]
        do {
            if let homeRings {
                rings = try await homeRings()
            } else {
                rings = try await AppDelegate.tripClassifier.sharingHomeRings()
            }
        } catch { throw .homesUnreadable }
        let raw: [SharedTrip]
        do { raw = try await TripShareSnapshotter(modelContainer: container).trips(ids: tripIDs) } catch {
            throw .tripsUnreadable
        }
        guard !raw.isEmpty else { throw .tripsMissing }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let export = await Task.detached(priority: .userInitiated) {
            TripShareExport.export(trips: raw, rings: rings, senderName: nil, exportedAt: .now, appVersion: version)
        }.value
        guard !export.file.trips.isEmpty else { throw .nothingToShare }
        return Prepared(file: export.file, omitted: export.omitted, exclusions: export.exclusions)
    }

    /// Writes the chosen items. `cards` holds trip cards the sheet already
    /// built for its preview; any other is built here. A Travel Log file
    /// over `TripShareFile.maximumFileBytes` is refused before anything is
    /// written, as the recipient would refuse it.
    @MainActor
    static func stage(
        _ prepared: Prepared, options: Options, senderName: String?,
        cards: [UUID: TripShareCardContent] = [:],
        maximumFileBytes: Int = TripShareFile.maximumFileBytes
    ) async throws(StagingError) -> Staged {
        var file = prepared.file
        file.senderName = TripTitleStore.normalized(senderName)
        file.exportedAt = .now
        let baseName = file.trips.count == 1
            ? fileName(file.trips[0].displayTitle())
            : String(localized: "trip-share.file-name.several", defaultValue: "Travel Log Trips",
                     comment: "File name (without extension) of a shared file holding several trips.")

        var outputs: [(name: String, data: Data)] = []
        if options.travelLogFile {
            let encoded = await Task.detached(priority: .userInitiated) { [file] in try? file.encoded() }.value
            guard let encoded else { throw .writeFailed }
            guard encoded.count <= maximumFileBytes else { throw .tooLarge }
            outputs.append((baseName + "." + TripShareFile.fileExtension, encoded))
        }
        if options.gpxRoute {
            let exclusions = prepared.exclusions
            let gpx = await Task.detached(priority: .userInitiated) { [file] in
                Data(TripShareGPX.document(for: file.trips, exclusions: exclusions, name: baseName,
                                           exportedAt: file.exportedAt).utf8)
            }.value
            outputs.append((baseName + "." + TripShareGPX.fileExtension, gpx))
        }
        var images: [(name: String, data: Data)] = []
        if options.overviewImage {
            if options.images == .summary && file.trips.count > 1 {
                if let png = TripShareCardRenderer.image(.summary(file.trips))?.pngData() {
                    images.append((baseName + ".png", png))
                }
            } else {
                var usedNames = Set<String>()
                for trip in file.trips {
                    var content = cards[trip.id]
                    if content == nil {
                        content = await TripShareCardRenderer.content(for: trip, exclusions: prepared.exclusions)
                    }
                    guard let content, let png = TripShareCardRenderer.image(content)?.pngData() else { continue }
                    var name = fileName(trip.displayTitle())
                    var suffix = 2
                    while !usedNames.insert(name).inserted { name = "\(fileName(trip.displayTitle())) \(suffix)"; suffix += 1 }
                    images.append((name + ".png", png))
                }
            }
        }
        // The images first, as the share sheet lists them.
        let items = images + outputs
        guard !items.isEmpty else { throw .writeFailed }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryPrefix + UUID().uuidString, isDirectory: true)
        let written = await Task.detached(priority: .userInitiated) { () -> [URL]? in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return try items.map { item in
                    let url = directory.appendingPathComponent(item.name)
                    try item.data.write(to: url, options: .completeFileProtection)
                    return url
                }
            } catch {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
        }.value
        guard let written else { throw .writeFailed }
        return Staged(directory: directory, items: written, omitted: prepared.omitted)
    }

    /// Stages `prepared`, then reads the trips and home areas again with
    /// `reread`, right before the system share sheet: the items are kept
    /// only while that read shares exactly what they hold. Otherwise they
    /// are removed and `staged` is nil; `current` is what the preview
    /// shows from now on. A failed read removes them too, and throws.
    @MainActor
    static func stageIfCurrent(
        _ prepared: Prepared, options: Options, senderName: String?,
        cards: [UUID: TripShareCardContent] = [:],
        maximumFileBytes: Int = TripShareFile.maximumFileBytes,
        reread: () async throws(StagingError) -> Prepared
    ) async throws(StagingError) -> (staged: Staged?, current: Prepared) {
        let staged = try await stage(prepared, options: options, senderName: senderName, cards: cards,
                                     maximumFileBytes: maximumFileBytes)
        let current: Prepared
        do throws(StagingError) {
            current = try await reread()
        } catch {
            discard(staged)
            throw error
        }
        guard current.isCurrent(prepared) else {
            discard(staged)
            return (nil, current)
        }
        return (staged, current)
    }

    /// Removes a staged folder that will not be shared.
    static func discard(_ staged: Staged) {
        try? FileManager.default.removeItem(at: staged.directory)
    }

    /// One share sheet's presentation. Staging can finish after the sheet
    /// was cancelled or closed; its folder then goes at once instead of
    /// waiting for the next launch or Delete All Data.
    @MainActor
    final class Lifetime {
        private(set) var isActive = true

        func end() {
            isActive = false
        }

        /// `staged` while the sheet is still up; otherwise it is removed.
        func adopt(_ staged: Staged) -> Staged? {
            guard isActive else {
                TripShareStaging.discard(staged)
                return nil
            }
            return staged
        }
    }

    /// A file name from a title: no path separators or control characters.
    nonisolated static func fileName(_ title: String?) -> String {
        let fallback = String(localized: "trip-share.file-name.untitled", defaultValue: "Travel Log Trip",
                              comment: "File name (without extension) of a shared trip with no title.")
        guard let title = TripTitleStore.normalized(title) else { return fallback }
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        let cleaned = String(title.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(80))
    }

    /// Every staged folder in `directory`; false while one could remain.
    @discardableResult
    nonisolated static func removeStagedShares(
        in directory: URL = FileManager.default.temporaryDirectory
    ) -> Bool {
        PrivateFileCleanup.removeEntries(in: directory) { $0.hasPrefix(directoryPrefix) }
    }
}
