//
//  SettingsView+DataManagement.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import SwiftUI
import SwiftData
import CoreLocation
import UIKit
import UserNotifications
import Photos
import PhotosUI
import EventKit
import UniformTypeIdentifiers
import WidgetKit
import WebKit
import os.log

extension SettingsModel {

    /// Decompress, parse, and fingerprint off-main with security-scoped, coordinated access inside the
    /// detached task. The decompressed document is a memory-mapped staging file, so a long ping history
    /// is never held in memory whole. Security scope is process-wide; the read-only import preview may
    /// run outside PipelineGate. The picker and a backup opened from Files or AirDrop both start here.
    /// A protected backup asks for its password first (`unlockProtectedBackup`).
    func prepareTripImport(from url: URL) async {
        discardLockedBackup()
        await prepareTripImport { try BackupFile.openedContents(of: url) }
    }

    /// The password prompt's answer for the protected backup waiting in `lockedBackupURL`. The
    /// password lives only in this call and the detached read; a wrong one asks again.
    func unlockProtectedBackup(password: String) async {
        guard let locked = lockedBackupURL else { return }
        await prepareTripImport {
            try BackupFile.unlockedContents(ofLockedCopy: locked, password: password)
        }
    }

    /// Removes the waiting protected backup's private copy (the prompt was cancelled, or another
    /// file replaced it).
    func discardLockedBackup() {
        showBackupPasswordPrompt = false
        backupPasswordWasWrong = false
        if let locked = lockedBackupURL {
            try? FileManager.default.removeItem(at: locked)
        }
        lockedBackupURL = nil
    }

    /// The password prompt was cancelled: no preparation still reading may publish afterwards.
    func cancelBackupPreparation() {
        backupPreparationGeneration += 1
        discardLockedBackup()
    }

    /// Reads, parses and previews one backup. A later request (another file opened or picked, an
    /// unlock, a cancel) supersedes this one: it then publishes nothing, and removes the private
    /// copy of a protected file it found, so the confirmation or prompt always belongs to the file
    /// the user chose last.
    func prepareTripImport(
        importer: TripDataImporter = AppDelegate.tripDataImporter,
        _ read: @escaping @Sendable () throws -> Data
    ) async {
        backupPreparationGeneration += 1
        let generation = backupPreparationGeneration
        do {
            let (payload, fingerprint) = try await Task.detached(priority: .userInitiated) {
                let data = try read()
                let payload = try TripDataImporter.parse(data)
                return (payload, ImportFence.fingerprint(of: data))
            }.value
            guard generation == backupPreparationGeneration else { return }
            discardLockedBackup()
            let queuedRemovedTripIDs = Set(
                ((try? DissolvedTripQueue.loadThrowing()) ?? []).map(\.id))
            let preview = try await importer.preview(
                of: payload,
                favouriteTripIDs: PinnedTripsStorage.shared.pinnedIDs,
                rememberedCountryCodes: RememberedCountriesStorage.shared.codes,
                queuedRemovedTripIDs: queuedRemovedTripIDs,
                newPreferences: BackupPreferences.additions(payload.preferences))
            guard generation == backupPreparationGeneration else { return }
            // Admit anything the commit would write, even when every trip already exists: unassigned stays,
            // home-area rows, Visits, titles an interrupted import of this file left uncompleted, or
            // settings and answers this device lacks.
            guard preview.hasImportableContent else {
                if preview.existingTrips == 1 {
                    tripImportResultMessage = String(
                        localized: "settings.data-import.nothing-new.existing.one",
                        defaultValue: "The \(preview.existingTrips, format: .number.grouping(.never)) trip in this file already exists, so there's nothing to import.",
                        comment: "Import result when the file's one trip already exists."
                    )
                } else if preview.existingTrips > 1 {
                    tripImportResultMessage = String(
                        localized: "settings.data-import.nothing-new.existing.other",
                        defaultValue: "All \(preview.existingTrips, format: .number.grouping(.never)) trips in this file already exist, so there's nothing to import.",
                        comment: "Import result when all of the file's multiple trips already exist."
                    )
                } else {
                    tripImportResultMessage = String(localized: "settings.data-import.nothing-importable", defaultValue: "No importable trips found in this file.", comment: "Import result when a file contains no importable trips.")
                }
                return
            }
            // Warn on a file fingerprint imported by another device: rows may still be hydrating,
            // and identical-UUID duplicates cannot be healed convergence-safely after the fact.
            let crossDeviceRepeat = ImportFence.warnsForCrossDeviceRepeat(of: fingerprint)
            pendingTripImport = (payload, preview, fingerprint, crossDeviceRepeat)
            showTripImportConfirmation = true
        } catch let found as ProtectedBackupFound {
            guard generation == backupPreparationGeneration else {
                try? FileManager.default.removeItem(at: found.lockedCopy)
                return
            }
            lockedBackupURL = found.lockedCopy
            backupPasswordWasWrong = false
            showBackupPasswordPrompt = true
        } catch TripDataImportError.wrongPassword
                    where lockedBackupURL != nil && generation == backupPreparationGeneration {
            backupPasswordWasWrong = true
            showBackupPasswordPrompt = true
        } catch {
            guard generation == backupPreparationGeneration else { return }
            discardLockedBackup()
            tripImportErrorMessage = error.localizedDescription
        }
    }

    func tripImportConfirmationText(
        for preview: ImportPreview, crossDeviceRepeat: Bool
    ) -> String {
        var lines: [String]
        if preview.newTrips > 0 {
            let first: String
            switch (preview.newTrips == 1, preview.newStays == 1) {
            case (true, true):
                first = String(localized: "settings.data-import.preview.new-trips-one.stays.one", defaultValue: "This file contains \(preview.newTrips, format: .number.grouping(.never)) new trip with \(preview.newStays, format: .number.grouping(.never)) stay.", comment: "Import preview for one new trip containing one stay.")
            case (true, false):
                first = String(localized: "settings.data-import.preview.new-trips-one.stays.other", defaultValue: "This file contains \(preview.newTrips, format: .number.grouping(.never)) new trip with \(preview.newStays, format: .number.grouping(.never)) stays.", comment: "Import preview for one new trip containing multiple stays.")
            case (false, true):
                first = String(localized: "settings.data-import.preview.new-trips-other.stays.one", defaultValue: "This file contains \(preview.newTrips, format: .number.grouping(.never)) new trips with \(preview.newStays, format: .number.grouping(.never)) stay.", comment: "Import preview for multiple new trips containing one stay in total.")
            case (false, false):
                first = String(localized: "settings.data-import.preview.new-trips-other.stays.other", defaultValue: "This file contains \(preview.newTrips, format: .number.grouping(.never)) new trips with \(preview.newStays, format: .number.grouping(.never)) stays.", comment: "Import preview for multiple new trips containing multiple stays.")
            }
            lines = [first]
        } else if preview.newStays > 0 {
            if preview.newStays == 1 {
                lines = [String(localized: "settings.data-import.preview.new-stays.one", defaultValue: "This file contains \(preview.newStays, format: .number.grouping(.never)) new stay.", comment: "Import preview for one new stay and no new trips.")]
            } else {
                lines = [String(localized: "settings.data-import.preview.new-stays.other", defaultValue: "This file contains \(preview.newStays, format: .number.grouping(.never)) new stays.", comment: "Import preview for multiple new stays and no new trips.")]
            }
        } else if preview.newHomeAreaRows > 0 {
            if preview.newHomeAreaRows == 1 {
                lines = [String(localized: "settings.data-import.preview.home-area-only.one", defaultValue: "This file restores \(preview.newHomeAreaRows, format: .number.grouping(.never)) home/place setting or taught correction. It contains no new trips.", comment: "Import preview for one home-area row and no new trips.")]
            } else {
                lines = [String(localized: "settings.data-import.preview.home-area-only.other", defaultValue: "This file restores \(preview.newHomeAreaRows, format: .number.grouping(.never)) home/place settings and taught corrections. It contains no new trips.", comment: "Import preview for multiple home-area rows and no new trips.")]
            }
        } else if preview.restorableTitles > 0 {
            if preview.restorableTitles == 1 {
                lines = [String(localized: "settings.data-import.preview.titles-only.one", defaultValue: "This file restores the title of \(preview.restorableTitles, format: .number.grouping(.never)) existing trip. It contains no new trips.", comment: "Import preview when the file only completes the missing title of one existing trip.")]
            } else {
                lines = [String(localized: "settings.data-import.preview.titles-only.other", defaultValue: "This file restores the titles of \(preview.restorableTitles, format: .number.grouping(.never)) existing trips. It contains no new trips.", comment: "Import preview when the file only completes the missing titles of multiple existing trips.")]
            }
        } else if preview.newVisits > 0 {
            if preview.newVisits == 1 {
                lines = [String(localized: "settings.data-import.preview.visits-only.one", defaultValue: "This file restores \(preview.newVisits, format: .number.grouping(.never)) recorded visit. It contains no new trips.", comment: "Import preview when the file only adds one recorded location visit and no trips.")]
            } else {
                lines = [String(localized: "settings.data-import.preview.visits-only.other", defaultValue: "This file restores \(preview.newVisits, format: .number.grouping(.never)) recorded visits. It contains no new trips.", comment: "Import preview when the file only adds multiple recorded location visits and no trips.")]
            }
        } else if preview.newChoices == 0 {
            // Records (pings, hex cells, recaps, plans, Removed Trips) and preferences are named only
            // when nothing else is new; otherwise they ride along like Visits. The result counts
            // restored preferences with the records too.
            let records = preview.newRecords + preview.newPreferences
            if records == 1 {
                lines = [String(localized: "settings.data-import.preview.records-only.one", defaultValue: "This file restores \(records, format: .number.grouping(.never)) item of location history or saved app data. It contains no new trips.", comment: "Import preview when the file only adds one location history entry, map cell, recap, planned trip or removed trip, and no trips.")]
            } else {
                lines = [String(localized: "settings.data-import.preview.records-only.other", defaultValue: "This file restores \(records, format: .number.grouping(.never)) items of location history and saved app data. It contains no new trips.", comment: "Import preview when the file only adds multiple location history entries, map cells, recaps, planned trips or removed trips, and no trips.")]
            }
        } else {
            // Choices are named only when nothing else is new; otherwise they ride along like Visits.
            if preview.newChoices == 1 {
                lines = [String(localized: "settings.data-import.preview.choices-only.one", defaultValue: "This file restores \(preview.newChoices, format: .number.grouping(.never)) saved choice for hidden/pinned photos, Favorites and Earlier Travels. It contains no new trips.", comment: "Import preview when the file only adds one saved choice and no trips.")]
            } else {
                lines = [String(localized: "settings.data-import.preview.choices-only.other", defaultValue: "This file restores \(preview.newChoices, format: .number.grouping(.never)) saved choices for hidden/pinned photos, Favorites and Earlier Travels. It contains no new trips.", comment: "Import preview when the file only adds multiple saved choices and no trips.")]
            }
        }
        if preview.newHomeAreaRows > 0, preview.newTrips > 0 || preview.newStays > 0 {
            if preview.newHomeAreaRows == 1 {
                lines.append(String(localized: "settings.data-import.preview.home-area-addition.one", defaultValue: "It also restores \(preview.newHomeAreaRows, format: .number.grouping(.never)) home/place setting or taught correction.", comment: "Import preview addition for one home-area row alongside trip or stay data."))
            } else {
                lines.append(String(localized: "settings.data-import.preview.home-area-addition.other", defaultValue: "It also restores \(preview.newHomeAreaRows, format: .number.grouping(.never)) home/place settings and taught corrections.", comment: "Import preview addition for multiple home-area rows alongside trip or stay data."))
            }
        }
        if preview.restorableTitles > 0,
           preview.newTrips > 0 || preview.newStays > 0 || preview.newHomeAreaRows > 0 {
            if preview.restorableTitles == 1 {
                lines.append(String(localized: "settings.data-import.preview.titles-addition.one", defaultValue: "It also restores the title of \(preview.restorableTitles, format: .number.grouping(.never)) existing trip.", comment: "Import preview addition when the file also completes the missing title of one existing trip."))
            } else {
                lines.append(String(localized: "settings.data-import.preview.titles-addition.other", defaultValue: "It also restores the titles of \(preview.restorableTitles, format: .number.grouping(.never)) existing trips.", comment: "Import preview addition when the file also completes the missing titles of multiple existing trips."))
            }
        }
        // Visits are named only when no trip or stay rows are new; otherwise they ride along unmentioned.
        if preview.newVisits > 0, preview.newTrips == 0, preview.newStays == 0,
           preview.newHomeAreaRows > 0 || preview.restorableTitles > 0 {
            if preview.newVisits == 1 {
                lines.append(String(localized: "settings.data-import.preview.visits-addition.one", defaultValue: "It also restores \(preview.newVisits, format: .number.grouping(.never)) recorded visit.", comment: "Import preview addition for one recorded location visit alongside home-area rows or trip titles."))
            } else {
                lines.append(String(localized: "settings.data-import.preview.visits-addition.other", defaultValue: "It also restores \(preview.newVisits, format: .number.grouping(.never)) recorded visits.", comment: "Import preview addition for multiple recorded location visits alongside home-area rows or trip titles."))
            }
        }
        // Trips whose titles are completed are named above, not as skipped.
        let skippedExistingTrips = max(0, preview.existingTrips - preview.restorableTitles)
        if skippedExistingTrips > 0 {
            if skippedExistingTrips == 1 {
                lines.append(String(localized: "settings.data-import.preview.existing-trips.one", defaultValue: "\(skippedExistingTrips, format: .number.grouping(.never)) trip already exists and will be skipped.", comment: "Import preview noting one existing trip that will be skipped."))
            } else {
                lines.append(String(localized: "settings.data-import.preview.existing-trips.other", defaultValue: "\(skippedExistingTrips, format: .number.grouping(.never)) trips already exist and will be skipped.", comment: "Import preview noting multiple existing trips that will be skipped."))
            }
        }
        if preview.malformedEntries > 0 {
            if preview.malformedEntries == 1 {
                lines.append(String(localized: "settings.data-import.preview.malformed.one", defaultValue: "\(preview.malformedEntries, format: .number.grouping(.never)) malformed entry will be ignored.", comment: "Import preview noting one malformed entry that will be ignored."))
            } else {
                lines.append(String(localized: "settings.data-import.preview.malformed.other", defaultValue: "\(preview.malformedEntries, format: .number.grouping(.never)) malformed entries will be ignored.", comment: "Import preview noting multiple malformed entries that will be ignored."))
            }
        }
        if crossDeviceRepeat {
            lines.append(String(localized: "settings.data-import.preview.cross-device-warning", defaultValue: "Warning: this backup was already imported on another device. If that device's data is still syncing to iCloud, importing here can create duplicate trips. Waiting for sync to finish first is safer.", comment: "Import preview warning when the same backup was imported on another device."))
        }
        return lines.joined(separator: " ")
    }

    /// Commit the import inside the pipeline gate (store-mutating) and
    /// return its outcome, pending geocode snapshots and merged selections
    /// from that unit.
    func performTripImport(payload: ImportPayload, fingerprint: String? = nil) async {
        isImportingTrips = true

        let importer = AppDelegate.tripDataImporter
        // Declare all inserted types: every store row a backup carries.
        let (outcome, pendingGeocode, mergedSelections) = await PipelineGate.shared.runReturning(touching: [
            .trip, .stay, .locationPing, .hexVisit, .home, .routinePlace, .homeAreaOverride, .visit,
            .temporaryHome, .hiddenPhoto, .pinnedPhoto, .yearWrapped, .plannedTrip, .photoImportState
        ]) {
            let outcome = await importer.importTrips(from: payload)
            let pendingGeocode = await importer.pendingGeocodes()
            // Restored live pings can be newer than this device's; re-derive
            // the reentry cursor inside the unit, as a launch would.
            if outcome.insertedPings > 0 {
                await AppDelegate.pingRecorder.restoreLastH3Index()
            }
            // Favorites, Earlier Travels and preferences join the user's sets
            // right after the commit, before the unit lets go: a queued unit
            // that reads the favourites (a temporary-home split) never sees
            // restored trips without them.
            let mergedSelections = await MainActor.run {
                (TripDataImporter.mergeSelections(of: outcome, from: payload),
                 outcome.saveFailed ? 0 : BackupPreferences.restore(payload.preferences))
            }
            return (outcome, pendingGeocode, mergedSelections)
        }

        // Restored photo choices: refetch every gallery, and map their cloud
        // identifiers to this device's photos, as a synced choice is.
        if outcome.insertedPhotoChoices > 0 {
            PhotoService.shared.invalidateTripCaches()
            await PhotoService.shared.runCloudIDMaintenance(backfill: true, refresh: true)
            PhotoService.shared.notifyChange()
        }
        let restoredChoices = outcome.insertedPhotoChoices + mergedSelections.0
        let restoredRecords = outcome.insertedPings + outcome.insertedRecords + mergedSelections.1

        let homeAreaRowsLanded = (outcome.insertedHomes
            + outcome.insertedOverrides
            + outcome.insertedRoutinePlaces
            + outcome.insertedTemporaryHomes
            + outcome.appliedTemporaryHomeRemovals)
        if outcome.saveFailed {
            // Surface save failure because attempted counts can exceed persisted rows; re-import remains idempotent.
            tripImportErrorMessage = String(localized: "settings.data-import.error.partial-save", defaultValue: "The import could not be fully saved. Some trips may be missing. Importing the same file again is safe and will fill the gaps.", comment: "Trip-data import error when only part of the imported data could be saved.")
        } else if outcome.insertedTrips > 0 || outcome.insertedStays > 0
                    || homeAreaRowsLanded > 0 || outcome.restoredTitles > 0
                    || outcome.insertedVisits > 0 || restoredChoices > 0 || restoredRecords > 0 {
            // Stays-only, home-layer-only, title-only, Visit-only, choice-only and record-only imports must report their changes even without new trips.
            var lines: [String] = []
            if outcome.insertedTrips > 0 {
                switch (outcome.insertedTrips == 1, outcome.insertedStays == 1) {
                case (true, true):
                    lines.append(String(localized: "settings.data-import.result.trips-one.stays.one", defaultValue: "Imported \(outcome.insertedTrips, format: .number.grouping(.never)) trip with \(outcome.insertedStays, format: .number.grouping(.never)) stay.", comment: "Trip-data import result for one trip containing one stay."))
                case (true, false):
                    lines.append(String(localized: "settings.data-import.result.trips-one.stays.other", defaultValue: "Imported \(outcome.insertedTrips, format: .number.grouping(.never)) trip with \(outcome.insertedStays, format: .number.grouping(.never)) stays.", comment: "Trip-data import result for one trip containing multiple stays."))
                case (false, true):
                    lines.append(String(localized: "settings.data-import.result.trips-other.stays.one", defaultValue: "Imported \(outcome.insertedTrips, format: .number.grouping(.never)) trips with \(outcome.insertedStays, format: .number.grouping(.never)) stay.", comment: "Trip-data import result for multiple trips containing one stay in total."))
                case (false, false):
                    lines.append(String(localized: "settings.data-import.result.trips-other.stays.other", defaultValue: "Imported \(outcome.insertedTrips, format: .number.grouping(.never)) trips with \(outcome.insertedStays, format: .number.grouping(.never)) stays.", comment: "Trip-data import result for multiple trips containing multiple stays."))
                }
            } else if outcome.insertedStays > 0 {
                if outcome.insertedStays == 1 {
                    lines.append(String(localized: "settings.data-import.result.stays.one", defaultValue: "Imported \(outcome.insertedStays, format: .number.grouping(.never)) stay.", comment: "Trip-data import result for one stay and no new trips."))
                } else {
                    lines.append(String(localized: "settings.data-import.result.stays.other", defaultValue: "Imported \(outcome.insertedStays, format: .number.grouping(.never)) stays.", comment: "Trip-data import result for multiple stays and no new trips."))
                }
            }
            if homeAreaRowsLanded > 0 {
                if homeAreaRowsLanded == 1 {
                    lines.append(String(localized: "settings.data-import.result.home-area.one", defaultValue: "Restored \(homeAreaRowsLanded, format: .number.grouping(.never)) home/place setting or taught correction.", comment: "Trip-data import result for one restored home-area row."))
                } else {
                    lines.append(String(localized: "settings.data-import.result.home-area.other", defaultValue: "Restored \(homeAreaRowsLanded, format: .number.grouping(.never)) home/place settings and taught corrections.", comment: "Trip-data import result for multiple restored home-area rows."))
                }
            }
            if outcome.restoredTitles > 0 {
                if outcome.restoredTitles == 1 {
                    lines.append(String(localized: "settings.data-import.result.titles.one", defaultValue: "Restored the title of \(outcome.restoredTitles, format: .number.grouping(.never)) existing trip.", comment: "Trip-data import result when the missing title of one existing trip was restored."))
                } else {
                    lines.append(String(localized: "settings.data-import.result.titles.other", defaultValue: "Restored the titles of \(outcome.restoredTitles, format: .number.grouping(.never)) existing trips.", comment: "Trip-data import result when the missing titles of multiple existing trips were restored."))
                }
            }
            if outcome.insertedVisits > 0, outcome.insertedTrips == 0, outcome.insertedStays == 0 {
                if outcome.insertedVisits == 1 {
                    lines.append(String(localized: "settings.data-import.result.visits.one", defaultValue: "Restored \(outcome.insertedVisits, format: .number.grouping(.never)) recorded visit.", comment: "Trip-data import result for one restored recorded location visit when no trips or stays were imported."))
                } else {
                    lines.append(String(localized: "settings.data-import.result.visits.other", defaultValue: "Restored \(outcome.insertedVisits, format: .number.grouping(.never)) recorded visits.", comment: "Trip-data import result for multiple restored recorded location visits when no trips or stays were imported."))
                }
            }
            if restoredChoices > 0 {
                if restoredChoices == 1 {
                    lines.append(String(localized: "settings.data-import.result.choices.one", defaultValue: "Restored \(restoredChoices, format: .number.grouping(.never)) saved choice for hidden/pinned photos, Favorites and Earlier Travels.", comment: "Trip-data import result for one restored saved choice."))
                } else {
                    lines.append(String(localized: "settings.data-import.result.choices.other", defaultValue: "Restored \(restoredChoices, format: .number.grouping(.never)) saved choices for hidden/pinned photos, Favorites and Earlier Travels.", comment: "Trip-data import result for multiple restored saved choices."))
                }
            }
            if restoredRecords > 0 {
                if restoredRecords == 1 {
                    lines.append(String(localized: "settings.data-import.result.records.one", defaultValue: "Restored \(restoredRecords, format: .number.grouping(.never)) item of location history or saved app data.", comment: "Trip-data import result for one restored location history entry, map cell, recap, planned trip, removed trip or preference."))
                } else {
                    lines.append(String(localized: "settings.data-import.result.records.other", defaultValue: "Restored \(restoredRecords, format: .number.grouping(.never)) items of location history and saved app data.", comment: "Trip-data import result for multiple restored location history entries, map cells, recaps, planned trips, removed trips or preferences."))
                }
            }
            if outcome.skippedExistingTrips > 0 {
                if outcome.skippedExistingTrips == 1 {
                    lines.append(String(localized: "settings.data-import.result.existing-trips.one", defaultValue: "\(outcome.skippedExistingTrips, format: .number.grouping(.never)) trip already existed.", comment: "Trip-data import result noting one existing trip."))
                } else {
                    lines.append(String(localized: "settings.data-import.result.existing-trips.other", defaultValue: "\(outcome.skippedExistingTrips, format: .number.grouping(.never)) trips already existed.", comment: "Trip-data import result noting multiple existing trips."))
                }
            }
            if outcome.skippedInvalidStays > 0 {
                if outcome.skippedInvalidStays == 1 {
                    lines.append(String(localized: "settings.data-import.result.invalid-stays.one", defaultValue: "\(outcome.skippedInvalidStays, format: .number.grouping(.never)) stay was skipped.", comment: "Trip-data import result noting one invalid stay that was skipped."))
                } else {
                    lines.append(String(localized: "settings.data-import.result.invalid-stays.other", defaultValue: "\(outcome.skippedInvalidStays, format: .number.grouping(.never)) stays were skipped.", comment: "Trip-data import result noting multiple invalid stays that were skipped."))
                }
            }
            tripImportResultMessage = lines.joined(separator: " ")
            if let fingerprint {
                ImportFence.recordImport(of: fingerprint)
            }
        } else {
            tripImportErrorMessage = String(localized: "settings.data-import.error.nothing-imported", defaultValue: "Nothing was imported. The file may duplicate existing data or contain no valid trips.", comment: "Trip-data import error when the operation imports nothing.")
        }

        // Heal after the import gate ends: resolution is ungated and apply chunks own their gates.
        // Do not wrap healPendingGeocodes in the non-reentrant gate.
        await importer.healPendingGeocodes(pendingGeocode)

        // Reload widgets after healing final place names; use the same captured outcome as the success alert.
        if !outcome.saveFailed,
           outcome.insertedTrips > 0 || outcome.insertedStays > 0
                || homeAreaRowsLanded > 0 || outcome.restoredTitles > 0 {
            WidgetCenter.shared.reloadAllTimelines()
        }

        // Home-layer imports change membership; re-prime and heal only when that content is present.
        if !outcome.saveFailed,
           homeAreaRowsLanded > 0 || !payload.homeStays.isEmpty
                || outcome.stagedTemporaryHomeReconciliations > 0 {
            if homeAreaRowsLanded > 0 {
                StoreChangeTracker.shared.bump(
                    [.home, .routinePlace, .homeAreaOverride, .temporaryHome])
            }
            // Collapse duplicate homes and repoint overrides BEFORE healing, matching the remote-sync ordering.
            // Healing must not judge restored trips against a transient doubled home set.
            if outcome.insertedHomes > 0 {
                await PipelineGate.shared.run(touching: [.home, .routinePlace, .trip, .homeAreaOverride]) {
                    await PlacesDeduplicator.deduplicateAll(
                        modelContainer: AppDelegate.modelContainer)
                }
            }
            // The import queued a reconciliation for each temporary home it inserted,
            // and for every stored one when stays landed; run them before healing.
            if outcome.stagedTemporaryHomeReconciliations > 0 {
                await CoverageReconciliationQueue.drainIfNeeded()
            }
            await HomeAreaHealing.healIfNeeded()
            if outcome.insertedHomes > 0 {
                _ = await AppDelegate.tripClassifier.generateTitlesStage(
                    maxTripsPerCall: nil)
                _ = await AppDelegate.tripTitleLocalizationService
                    .generateLocalizedTitlesStage(maxTripsPerCall: nil)
                WidgetCenter.shared.reloadAllTimelines()
            }
        }

        isImportingTrips = false
    }

    /// Parse Timeline off-main and feed fixes through bounded gated import batches, then the shared post-pipeline.
    /// Re-import deduplicates previously inserted fixes.
    func importTimeline(from url: URL) async {
        isImportingTimeline = true
        externalImportIsGPX = false
        defer { isImportingTimeline = false }

        // Read and parse inside the detached task with process-wide security scope; keep file I/O off MainActor.
        let parsed: TimelineParseResult
        do {
            parsed = try await Task.detached(priority: .userInitiated) {
                let securityScoped = url.startAccessingSecurityScopedResource()
                defer { if securityScoped { url.stopAccessingSecurityScopedResource() } }
                let prefix: Data
                let size: UInt64
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    prefix = try handle.read(upToCount: 64 * 1024) ?? Data()
                    size = try handle.seekToEnd()
                }
                if TimelineImportParser.preflightIsRawRecords(prefix: prefix) {
                    throw TimelineImportError.rawRecordsFile
                }
                guard size <= TimelineImportParser.maxFileBytes else {
                    throw TimelineImportError.tooLarge
                }
                let fileData = try Data(contentsOf: url, options: .mappedIfSafe)
                return try TimelineImportParser.parse(fileData)
            }.value
        } catch let error as TimelineImportError {
            timelineImportErrorMessage = Self.timelineErrorText(error)
            return
        } catch {
            timelineImportErrorMessage = error.localizedDescription
            return
        }

        let outcome = await recordExternalPings(
            parsed.pings, source: .timelineImport)
        guard !outcome.saveFailed else {
            timelineImportErrorMessage = String(
                localized: "settings.data-import.error.partial-save",
                defaultValue: "The import could not be fully saved. Some trips may be missing. Importing the same file again is safe and will fill the gaps.",
                comment: "Trip-data import error when only part of the imported data could be saved.")
            return
        }
        // Saved fixes whose trips were not rebuilt: a re-import of the same
        // file finalizes them.
        guard !outcome.processingFailed else {
            timelineImportErrorMessage = String(
                localized: "settings.data-import.error.processing-incomplete",
                defaultValue: "Your locations were imported, but some trips couldn't be rebuilt yet. Importing the same file again is safe and will finish them.",
                comment: "Timeline or GPX import error when the location fixes were saved but rebuilding trips from them did not finish.")
            return
        }
        let inserted = outcome.inserted

        let routePoints = parsed.activityCount + parsed.pathPointCount
        let firstLine: String
        switch (inserted == 1, parsed.visitCount == 1, routePoints == 1) {
        case (true, true, true):
            firstLine = String(localized: "settings.timeline-import.result.fixes-one.visits-one.points.one", defaultValue: "Imported \(inserted, format: .number.grouping(.never)) location fix from \(parsed.visitCount, format: .number.grouping(.never)) visit and \(routePoints, format: .number.grouping(.never)) route point.", comment: "Timeline import result for one fix, one visit, and one route point.")
        case (true, true, false):
            firstLine = String(localized: "settings.timeline-import.result.fixes-one.visits-one.points.other", defaultValue: "Imported \(inserted, format: .number.grouping(.never)) location fix from \(parsed.visitCount, format: .number.grouping(.never)) visit and \(routePoints, format: .number.grouping(.never)) route points.", comment: "Timeline import result for one fix, one visit, and multiple route points.")
        case (true, false, true):
            firstLine = String(localized: "settings.timeline-import.result.fixes-one.visits-other.points.one", defaultValue: "Imported \(inserted, format: .number.grouping(.never)) location fix from \(parsed.visitCount, format: .number.grouping(.never)) visits and \(routePoints, format: .number.grouping(.never)) route point.", comment: "Timeline import result for one fix, multiple visits, and one route point.")
        case (true, false, false):
            firstLine = String(localized: "settings.timeline-import.result.fixes-one.visits-other.points.other", defaultValue: "Imported \(inserted, format: .number.grouping(.never)) location fix from \(parsed.visitCount, format: .number.grouping(.never)) visits and \(routePoints, format: .number.grouping(.never)) route points.", comment: "Timeline import result for one fix, multiple visits, and multiple route points.")
        case (false, true, true):
            firstLine = String(localized: "settings.timeline-import.result.fixes-other.visits-one.points.one", defaultValue: "Imported \(inserted, format: .number.grouping(.never)) location fixes from \(parsed.visitCount, format: .number.grouping(.never)) visit and \(routePoints, format: .number.grouping(.never)) route point.", comment: "Timeline import result for multiple fixes, one visit, and one route point.")
        case (false, true, false):
            firstLine = String(localized: "settings.timeline-import.result.fixes-other.visits-one.points.other", defaultValue: "Imported \(inserted, format: .number.grouping(.never)) location fixes from \(parsed.visitCount, format: .number.grouping(.never)) visit and \(routePoints, format: .number.grouping(.never)) route points.", comment: "Timeline import result for multiple fixes, one visit, and multiple route points.")
        case (false, false, true):
            firstLine = String(localized: "settings.timeline-import.result.fixes-other.visits-other.points.one", defaultValue: "Imported \(inserted, format: .number.grouping(.never)) location fixes from \(parsed.visitCount, format: .number.grouping(.never)) visits and \(routePoints, format: .number.grouping(.never)) route point.", comment: "Timeline import result for multiple fixes, multiple visits, and one route point.")
        case (false, false, false):
            firstLine = String(localized: "settings.timeline-import.result.fixes-other.visits-other.points.other", defaultValue: "Imported \(inserted, format: .number.grouping(.never)) location fixes from \(parsed.visitCount, format: .number.grouping(.never)) visits and \(routePoints, format: .number.grouping(.never)) route points.", comment: "Timeline import result for multiple fixes, multiple visits, and multiple route points.")
        }
        var lines = [firstLine]
        let duplicates = parsed.pings.count - inserted
        if duplicates > 0 {
            if duplicates == 1 {
                lines.append(String(localized: "settings.timeline-import.result.duplicates.one", defaultValue: "\(duplicates, format: .number.grouping(.never)) duplicate already known was skipped.", comment: "Timeline import result noting one duplicate location fix."))
            } else {
                lines.append(String(localized: "settings.timeline-import.result.duplicates.other", defaultValue: "\(duplicates, format: .number.grouping(.never)) duplicates already known were skipped.", comment: "Timeline import result noting multiple duplicate location fixes."))
            }
        }
        if parsed.skippedSegments > 0 {
            if parsed.skippedSegments == 1 {
                lines.append(String(localized: "settings.timeline-import.result.skipped-segments.one", defaultValue: "\(parsed.skippedSegments, format: .number.grouping(.never)) segment couldn't be read.", comment: "Timeline import result noting one unreadable segment."))
            } else {
                lines.append(String(localized: "settings.timeline-import.result.skipped-segments.other", defaultValue: "\(parsed.skippedSegments, format: .number.grouping(.never)) segments couldn't be read.", comment: "Timeline import result noting multiple unreadable segments."))
            }
        }
        if inserted == 0 {
            lines.append(String(localized: "settings.timeline-import.result.already-imported", defaultValue: "Your history may already be fully imported.", comment: "Timeline import result when no new fixes were inserted because the history may already exist."))
        }
        timelineImportResultMessage = lines.joined(separator: " ")
    }

    /// Shared Timeline/GPX order: record → cluster → classify → recompute summaries.
    private func recordExternalPings(
        _ pings: [TimelinePing], source: DataSource
    ) async -> ExternalHistoryImporter.Outcome {
        await ExternalHistoryImporter.record(
            pings, source: source, recorder: AppDelegate.pingRecorder
        )
    }

    /// Parse GPX off-main and use the shared external-import pipeline.
    func importGPX(from url: URL) async {
        isImportingTimeline = true
        externalImportIsGPX = true
        defer { isImportingTimeline = false }

        // Read AND parse off-main (same rationale as importTimeline): the
        // security scope rides inside the detached task, keeping the file
        // bytes and the synchronous read off the MainActor entirely.
        let parsed: GPXParseResult
        do {
            parsed = try await Task.detached(priority: .userInitiated) {
                let securityScoped = url.startAccessingSecurityScopedResource()
                defer { if securityScoped { url.stopAccessingSecurityScopedResource() } }
                return try GPXImportParser.parse(contentsOf: url)
            }.value
        } catch let error as GPXImportError {
            timelineImportErrorMessage = Self.gpxErrorText(error)
            return
        } catch {
            timelineImportErrorMessage = error.localizedDescription
            return
        }

        let outcome = await recordExternalPings(
            parsed.pings, source: .gpxImport)
        guard !outcome.saveFailed else {
            timelineImportErrorMessage = String(
                localized: "settings.data-import.error.partial-save",
                defaultValue: "The import could not be fully saved. Some trips may be missing. Importing the same file again is safe and will fill the gaps.",
                comment: "Trip-data import error when only part of the imported data could be saved.")
            return
        }
        // Saved fixes whose trips were not rebuilt: a re-import of the same
        // file finalizes them.
        guard !outcome.processingFailed else {
            timelineImportErrorMessage = String(
                localized: "settings.data-import.error.processing-incomplete",
                defaultValue: "Your locations were imported, but some trips couldn't be rebuilt yet. Importing the same file again is safe and will finish them.",
                comment: "Timeline or GPX import error when the location fixes were saved but rebuilding trips from them did not finish.")
            return
        }
        let inserted = outcome.inserted

        let firstLine: String
        switch (inserted == 1, parsed.trackCount == 1) {
        case (true, true):
            firstLine = String(localized: "settings.gpx-import.result.points-one.tracks.one", defaultValue: "Imported \(inserted, format: .number.grouping(.never)) track point from \(parsed.trackCount, format: .number.grouping(.never)) track.", comment: "GPX import result for one point from one track.")
        case (true, false):
            firstLine = String(localized: "settings.gpx-import.result.points-one.tracks.other", defaultValue: "Imported \(inserted, format: .number.grouping(.never)) track point from \(parsed.trackCount, format: .number.grouping(.never)) tracks.", comment: "GPX import result for one point from multiple tracks.")
        case (false, true):
            firstLine = String(localized: "settings.gpx-import.result.points-other.tracks.one", defaultValue: "Imported \(inserted, format: .number.grouping(.never)) track points from \(parsed.trackCount, format: .number.grouping(.never)) track.", comment: "GPX import result for multiple points from one track.")
        case (false, false):
            firstLine = String(localized: "settings.gpx-import.result.points-other.tracks.other", defaultValue: "Imported \(inserted, format: .number.grouping(.never)) track points from \(parsed.trackCount, format: .number.grouping(.never)) tracks.", comment: "GPX import result for multiple points from multiple tracks.")
        }
        var lines = [firstLine]
        let duplicates = parsed.pings.count - inserted
        if duplicates > 0 {
            if duplicates == 1 {
                lines.append(String(localized: "settings.gpx-import.result.duplicates.one", defaultValue: "\(duplicates, format: .number.grouping(.never)) duplicate already known was skipped.", comment: "GPX import result noting one duplicate track point."))
            } else {
                lines.append(String(localized: "settings.gpx-import.result.duplicates.other", defaultValue: "\(duplicates, format: .number.grouping(.never)) duplicates already known were skipped.", comment: "GPX import result noting multiple duplicate track points."))
            }
        }
        if parsed.skippedPoints > 0 {
            if parsed.skippedPoints == 1 {
                lines.append(String(localized: "settings.gpx-import.result.skipped-points.one", defaultValue: "\(parsed.skippedPoints, format: .number.grouping(.never)) point had no usable time or coordinate.", comment: "GPX import result noting one unusable point."))
            } else {
                lines.append(String(localized: "settings.gpx-import.result.skipped-points.other", defaultValue: "\(parsed.skippedPoints, format: .number.grouping(.never)) points had no usable time or coordinate.", comment: "GPX import result noting multiple unusable points."))
            }
        }
        if inserted == 0 {
            lines.append(String(localized: "settings.gpx-import.result.already-imported", defaultValue: "This track may already be fully imported.", comment: "GPX import result when no new points were inserted because the track may already exist."))
        }
        timelineImportResultMessage = lines.joined(separator: " ")
    }

    private static func gpxErrorText(_ error: GPXImportError) -> String {
        switch error {
        case .notGPX:
            return String(localized: "settings.gpx-import.error.not-gpx", defaultValue: "This file doesn't look like a GPX track.", comment: "GPX import error when the selected file is not a GPX track.")
        case .empty:
            return String(localized: "settings.gpx-import.error.empty", defaultValue: "No timestamped track points were found in this file. Waypoint-only GPX files can't be imported. Travel Log needs times to reconstruct your history.", comment: "GPX import error when the file has no timestamped track points.")
        case .malformed:
            return String(localized: "settings.gpx-import.error.malformed", defaultValue: "This GPX file appears truncated or corrupted. The track breaks off mid-file. Re-export or re-download it, then try again.", comment: "GPX import error when the file is malformed or truncated.")
        case .tooLarge:
            return String(localized: "settings.gpx-import.error.too-large", defaultValue: "This GPX file is too large to import on this device. Export a shorter period, then try again.", comment: "GPX import error when the file is larger than the import can read.")
        }
    }

    private static func timelineErrorText(_ error: TimelineImportError) -> String {
        switch error {
        case .notJSON:
            return String(localized: "settings.timeline-import.error.not-json", defaultValue: "This file isn't a readable JSON export.", comment: "Timeline import error when the file is not readable JSON.")
        case .rawRecordsFile:
            return String(localized: "settings.timeline-import.error.raw-records", defaultValue: "This looks like the raw Records.json from Google Takeout, which is too large to process on a phone. In the Google Maps app, open your profile → Your Timeline → ⋯ → Location & privacy settings → Export Timeline data. That file imports here.", comment: "Timeline import error explaining how to export the supported file instead of raw Takeout records.")
        case .unrecognizedFormat:
            return String(localized: "settings.timeline-import.error.unrecognized-format", defaultValue: "This JSON file doesn't look like a Google Timeline export. Expected a Timeline export from the Google Maps app or a Takeout Semantic Location History file.", comment: "Timeline import error when the JSON format is not recognized.")
        case .empty:
            return String(localized: "settings.timeline-import.error.empty", defaultValue: "No usable location fixes were found in this file.", comment: "Timeline import error when the file has no usable location fixes.")
        case .tooLarge:
            return String(localized: "settings.timeline-import.error.too-large", defaultValue: "This Timeline file is too large to import on this device. Export a shorter period, then try again.", comment: "Timeline import error when the file is larger than the import can read.")
        }
    }

    func retryGeocoding() async {
        isRetryingGeocoding = true
        // The full geocoding drain groups by hex and owns bounded PipelineGate chunks.
        // Do not wrap it here: the gate is non-reentrant.
        await AppDelegate.pingRecorder.retryAllFailedGeocodingGated()
        isRetryingGeocoding = false
    }

    func backfillHexCountries() async {
        isBackfillingHexes = true
        // The heal owns bounded PipelineGate units so live saves interleave.
        // Do not wrap it here: the gate is non-reentrant.
        await AppDelegate.pingRecorder.backfillHexVisitCountries()
        isBackfillingHexes = false
    }

    func reclassifyAllTrips() async {
        isReclassifying = true
        let outcome = await AppDelegate.tripClassifier.reclassifyAll()
        if outcome == .completed {
            _ = await AppDelegate.tripTitleLocalizationService
                .generateLocalizedTitlesStage(maxTripsPerCall: nil)
        }
        // Units committed before a failure still publish.
        StoreChangeTracker.shared.bump([.trip, .stay])
        // Reload widgets after trip identity or title changes; their process cannot observe the tracker.
        WidgetCenter.shared.reloadAllTimelines()
        if outcome == .failed { saveFailed = true }
        isReclassifying = false
    }

    func deleteAllData() async {
        isDeleting = true
        // Revoke suspended Calendar work before the store wipe. Without this,
        // a scan that collected detections before Delete Everything could
        // apply them immediately after the gate and recreate PlannedTrip rows.
        await AppDelegate.calendarEnricher.beginCalendarDataRevocation()
        // Stop the foreground drain, and revoke every pipeline pass already
        // running, so none of their units queued behind the wipe lands work
        // prepared against the wiped store. Drains resume once it is done.
        ForegroundClassificationDrain.shared.pause()
        PipelineGate.shared.revokeQueuedPasses()
        defer { ForegroundClassificationDrain.shared.resume() }
        // Gate the wipe against all pipeline writes; the gate publishes the all-tables change.
        // Surface delete/save failures; derived caches may still be cleared safely on failure.
        let wipeSucceeded = await PipelineGate.shared.runReturning(touching: .all) {
            let succeeded = await DataWipe.execute(
                container: AppDelegate.modelContainer,
                afterCommit: { RememberedCountriesStorage.shared.clear() })
            // Re-derive the live reentry cursor inside the wipe unit, so no
            // live batch can count visits against wiped history in between.
            await AppDelegate.pingRecorder.restoreLastH3Index()
            return succeeded
        }
        // Local revocations run before the Spotlight wait below, so a
        // suspended Spotlight call cannot leave wiped content on screen.
        // Drop PhotoService's per-trip caches so any open trip view re-fetches.
        PhotoService.shared.invalidateAllCaches()

        // Drop the persisted Stats snapshot — the next cold launch must not
        // hydrate the wiped store's old totals for even a second. This also
        // revokes the aggregates an open Stats page is showing. A file left
        // on disk is reported like any other wipe residue.
        let statsSnapshotCleared = StatsSnapshotStore.clear()

        // Revoke in-flight search index builds and drop cached search documents.
        TripSearchIndexStore.shared.invalidateAll()

        // Clear persistent geocoder caches through their actors, including in-memory copies that could rewrite old data.
        await MapKitLocalityCache.shared.clearCache()
        await ForwardGeocoder.shared.clearCache()

        // Clear Calendar verdict text through its actor so in-flight work cannot restore deleted private event data.
        await AppDelegate.calendarEnricher.clearFMJudgmentCache()

        // Reload widgets explicitly because they cannot observe this process’s tracker.
        WidgetCenter.shared.reloadAllTimelines()

        // Revoke Spotlight donations last and outside the gate, unconditionally:
        // its wait is open-ended, so every local revocation above runs first. A
        // committed wipe can still return false after cleanup failures, and a
        // rolled-back one only re-donates the surviving trips.
        let spotlightRevoked = await SpotlightIndexer.shared.revokeAllDonations()
        if !wipeSucceeded || !spotlightRevoked || !statsSnapshotCleared {
            showDeleteError = true
        }

        isDeleting = false
    }

    /// With `password`, the backup is sealed with a key derived from it (`BackupEncryption`). The key
    /// is stretched before the gate unit, off-main; the password itself is never stored or logged.
    func exportData(password: String? = nil) async {
        isExporting = true

        // ExportSnapshotter reads the store in its own context off-main and writes the gzip file there,
        // pings page by page, so neither the main actor nor memory carries the whole history.
        let snapshotter = ExportSnapshotter(modelContainer: AppDelegate.modelContainer)
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

        TripDataExporter.removeStagedExports()
        exportFileURL = nil
        exportErrorMessage = nil
        let fileURL = TripDataExporter.exportFileURL()

        let sealing: BackupEncryption.Sealing?
        if let password {
            do {
                sealing = try await Task.detached(priority: .userInitiated) {
                    try BackupEncryption.Sealing(password: password)
                }.value
            } catch {
                settingsLogger.error("Export key derivation failed")
                showExportError = true
                isExporting = false
                return
            }
        } else {
            sealing = nil
        }

        // One read-only gate unit for all reads and the write: no gated write (import, wipe, pipeline)
        // can land between the trips, the home layer, the pings and the device-local state. A CloudKit
        // import is not gated and still can. Favorites and Earlier Travels live in iCloud key-value
        // storage, the Removed Trips queue and preferences on this device; all are read inside the
        // unit, so a temporary-home split that unpins a trip cannot land between its graph and its favourite.
        let outcome: Result<Void, any Error> =
            await PipelineGate.shared.runReturning(touching: []) {
                do {
                    let extras = try await MainActor.run {
                        BackupExtras(
                            favouriteTripIDs: PinnedTripsStorage.shared.pinnedIDs,
                            rememberedCountryCodes: RememberedCountriesStorage.shared.codes,
                            removedTrips: try DissolvedTripQueue.loadThrowing(),
                            preferences: BackupPreferences.current(),
                            appVersion: appVersion)
                    }
                    try await snapshotter.writeBackupFile(extras, to: fileURL, sealing: sealing)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }

        switch outcome {
        case .success:
            exportFileURL = fileURL
        case .failure(let error):
            // A failed read must fail the export; an empty file would pass for a backup. A row the
            // restore would refuse fails it too, saying which, so the user can change it.
            settingsLogger.error("Export failed: \(error.localizedDescription)")
            exportErrorMessage = (error as? BackupExportRefusal)?.errorDescription
            showExportError = true
        }

        isExporting = false
    }
}
