//
//  SettingsView+PhotoImport.swift
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

/// Resolve stable photo-import tokens at display time; older values and arbitrary errors remain readable verbatim.
func photoImportLastErrorText(
    _ value: String,
    locale: Locale = AppLanguagePreference.currentLocale()
) -> String {
    switch value {
    case "importError.backgroundTaskStart":
        localizedRendererString(
            localized: "photo-import.persisted-error.background-task-start",
            defaultValue: "Could not start background task.",
            bundle: nil,
            locale: locale)
    case "importError.backgroundTaskResume":
        localizedRendererString(
            localized: "photo-import.persisted-error.background-task-resume",
            defaultValue: "Could not resume background task.",
            bundle: nil,
            locale: locale)
    case "importError.abandoned":
        localizedRendererString(
            localized: "photo-import.persisted-error.abandoned",
            defaultValue: "Import abandoned for more than 7 days; auto-cancelled on launch.",
            bundle: nil,
            locale: locale)
    case "importError.permissionRevoked":
        localizedRendererString(
            localized: "photo-import.persisted-error.permission-revoked",
            defaultValue: "Photo access was revoked. Re-grant in iOS Settings → Privacy → Photos → TravelLog, then resume.",
            bundle: nil,
            locale: locale)
    case "importError.lowPowerMode":
        localizedRendererString(
            localized: "photo-import.persisted-error.low-power-mode",
            defaultValue: "Paused: Low Power Mode is enabled. Disable it (Settings → Battery → Low Power Mode) or plug in your iPhone, then resume.",
            bundle: nil,
            locale: locale)
    case "importError.thermal":
        localizedRendererString(
            localized: "photo-import.persisted-error.thermal",
            defaultValue: "Paused: device is in a critical thermal state. Try again when it has cooled.",
            bundle: nil,
            locale: locale)
    case "importError.batchSaveFailed":
        localizedRendererString(
            localized: "photo-import.persisted-error.batch-save",
            defaultValue: "Could not save an imported photo batch.",
            bundle: nil,
            locale: locale)
    case "importError.batchReadFailed":
        localizedRendererString(
            localized: "photo-import.persisted-error.batch-read",
            defaultValue: "Could not read saved import data. Try again.",
            bundle: nil,
            locale: locale)
    case "importError.finalizationSaveFailed":
        localizedRendererString(
            localized: "photo-import.persisted-error.finalization",
            defaultValue: "Could not save the imported photos as stays. Resume to try again.",
            bundle: nil,
            locale: locale)
    case "importError.libraryChanged":
        localizedRendererString(
            localized: "photo-import.persisted-error.library-changed",
            defaultValue: "The photo library changed during import. Resume to try again.",
            bundle: nil,
            locale: locale)
    case "importError.checkpointSaveFailed":
        localizedRendererString(
            localized: "photo-import.persisted-error.checkpoint-save",
            defaultValue: "Could not save import progress.",
            bundle: nil,
            locale: locale)
    default:
        value
    }
}

/// Settings → Import & Export → Photo Library Import. Owns its query so
/// progress commits re-render only this section, never the whole screen.
struct PhotoImportSettingsSection: View {
    @Bindable var model: SettingsModel

    @Query(sort: \PhotoImportState.startedAt, order: .forward)
    private var importStates: [PhotoImportState]
    @AppStorage(AppDelegate.iCloudSyncEnabledKey) private var iCloudSyncEnabled = false

    /// Seconds after which a `.running` state row's `lastUpdated` is
    /// considered stale and the loop is presumed dead (force-quit, crash,
    /// BG task expired). Matches `RootView.runningStaleThreshold` so the
    /// banner and Settings row agree on what "actively running" means.
    private static let staleRunningThreshold: TimeInterval = 60

    /// Hoisted: building a formatter per row render is measurable while scrolling.
    private static let fullRelativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let abbreviatedRelativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        Section {
            importStatusRow
        } header: {
            Text("Photo Library Import")
        } footer: {
            importSectionFooter
        }

        if showDeleteImportedRow {
            Section {
                deleteImportedDataRow
            }
        }
    }

    @ViewBuilder
    private var importStatusRow: some View {
        let state = importStates.first

        if isImportRunningOnAnotherDevice {
            // Disable local start while another device’s running state remains fresh.
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import in progress on another device")
                    Text(otherDeviceUpdatedAgo(from: state?.lastUpdated))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ProgressView()
            }
            .foregroundStyle(.secondary)
        } else if let state {
            switch state.status {
            case .running:
                // Treat stale running state as paused, matching RootView’s recovery heuristic.
                if isStalled(state) {
                    resumableImportRow(state: state, label: String(localized: "settings.photo-import.action.resume-interrupted", defaultValue: "Resume photo import (interrupted)", comment: "Settings action for resuming an interrupted photo import."))
                } else {
                    runningImportRow(state: state)
                }
            case .paused:
                resumableImportRow(state: state, label: String(localized: "settings.photo-import.action.resume", defaultValue: "Resume photo import", comment: "Settings action for resuming a paused photo import."))
            case .failed:
                failedImportRow(state: state)
            case .completed:
                startImportRow(label: String(localized: "settings.photo-import.action.rescan", defaultValue: "Re-scan photo library", comment: "Settings action for scanning the photo library again."), subtitle: completedSubtitle(state: state))
            case .cancelled:
                startImportRow(label: String(localized: "settings.photo-import.action.start-fresh", defaultValue: "Start fresh import", comment: "Settings action for starting a fresh photo import after cancellation."), subtitle: nil)
            case .idle:
                startImportRow(label: String(localized: "settings.photo-import.action.start", defaultValue: "Import past trips from photos", comment: "Settings action for starting a photo-library trip import."), subtitle: nil)
            }
        } else {
            startImportRow(label: String(localized: "settings.photo-import.action.start", defaultValue: "Import past trips from photos", comment: "Settings action for starting a photo-library trip import."), subtitle: nil)
        }
    }

    @ViewBuilder
    private func runningImportRow(state: PhotoImportState) -> some View {
        Button(role: .destructive) {
            Task { await model.cancelImport() }
        } label: {
            // Ongoing, not failing: the row reads in primary and the accent;
            // only Cancel wears the destructive red.
            let total = Double(max(state.totalAssetCount, state.processedAssetCount, 1))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Import in progress")
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(Double(state.processedAssetCount) / total, format: .percent.precision(.fractionLength(0)))
                        .font(AppTheme.stat(.title3))
                        .foregroundStyle(AppTheme.accent)
                }
                ProgressView(value: Double(state.processedAssetCount), total: total)
                    .progressViewStyle(.linear)
                    .tint(AppTheme.accent)
                HStack(alignment: .firstTextBaseline) {
                    Text(progressSubtitle(state: state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.isCancellingImport {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Cancel")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.failure)
                    }
                }
            }
        }
        .disabled(isAnyImportOperationRunning)
    }

    @ViewBuilder
    private func resumableImportRow(state: PhotoImportState, label: String) -> some View {
        Button {
            Task { await model.resumeImport() }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                    if let lastError = state.lastError, !lastError.isEmpty {
                        Text(photoImportLastErrorText(lastError))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if state.processedAssetCount > 0 || state.acceptedPingCount > 0 {
                        Text(progressSubtitle(state: state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.isStartingImport { ProgressView().controlSize(.small) }
            }
        }
        .disabled(isAnyImportOperationRunning || model.isAnyOperationRunning)
    }

    @ViewBuilder
    private func failedImportRow(state: PhotoImportState) -> some View {
        Button {
            Task { await model.resumeImport() }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(
                        localized: "settings.photo-import.action.retry-failed",
                        defaultValue: "Retry photo import (failed)",
                        comment: "Settings action, shown in red, for retrying a failed photo import from where it stopped."
                    ))
                    .foregroundStyle(AppTheme.failure)
                    if let lastError = state.lastError, !lastError.isEmpty {
                        Text(photoImportLastErrorText(lastError))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if model.isStartingImport { ProgressView().controlSize(.small) }
            }
        }
        .disabled(isAnyImportOperationRunning || model.isAnyOperationRunning)
    }

    @ViewBuilder
    private func startImportRow(label: String, subtitle: String?) -> some View {
        Button {
            Task { await model.startImport() }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.isStartingImport { ProgressView().controlSize(.small) }
            }
        }
        .disabled(model.photoAuthStatus == .denied || model.photoAuthStatus == .restricted || isAnyImportOperationRunning || model.isAnyOperationRunning)
    }

    @ViewBuilder
    private var deleteImportedDataRow: some View {
        Button(role: .destructive) {
            model.showDiscardImportConfirmation = true
        } label: {
            HStack {
                Text("Delete imported data")
                if model.isDiscardingImport {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(isAnyImportOperationRunning || model.isAnyOperationRunning)
    }

    /// Offer discard for persisted work, including stale running rows when no local loop remains active.
    private var showDeleteImportedRow: Bool {
        guard let state = importStates.first else { return false }
        switch state.status {
        case .completed, .cancelled, .failed, .paused: return true
        case .running: return isStalled(state) && !isImportRunningOnAnotherDevice
        case .idle: return false
        }
    }

    private func isStalled(_ state: PhotoImportState) -> Bool {
        guard state.status == .running else { return false }
        return Date().timeIntervalSince(state.lastUpdated) > Self.staleRunningThreshold
    }

    /// Keep photo-import UI activity separate so progress remains inspectable during other data operations.
    private var isAnyImportOperationRunning: Bool {
        model.isStartingImport || model.isCancellingImport || model.isDiscardingImport
    }

    private var isImportRunningOnAnotherDevice: Bool {
        guard let state = importStates.first, state.status == .running else { return false }
        guard !state.originDeviceID.isEmpty,
              state.originDeviceID != SettingsModel.thisDeviceID else { return false }
        // Allow remote takeover after the 60-second stall threshold plus 30 seconds of CloudKit slack.
        // Ping dedup handles duplicates from the remaining cross-device race window.
        return Date().timeIntervalSince(state.lastUpdated) < 90
    }

    @ViewBuilder
    private var importSectionFooter: some View {
        if let state = importStates.first, state.status == .running, !isStalled(state) {
            // Genuinely alive: Dynamic Island / Lock Screen UI is up.
            Text(String(
                localized: "settings.photo-import.footer.running",
                defaultValue: "Import continues in the background. Follow it in the Dynamic Island or on the Lock Screen.",
                comment: "Settings photo-import footer while an import runs on this device."
            ))
        } else if let state = importStates.first, state.status == .running, isStalled(state) {
            // Stale running state implies a stopped loop.
            Text(String(
                localized: "settings.photo-import.footer.interrupted",
                defaultValue: "The last import stopped early. Resume to continue where it left off, or delete the imported data to discard it.",
                comment: "Settings photo-import footer after an import was interrupted (app closed or background time ran out)."
            ))
        } else if importStates.first?.status == .failed {
            Text(String(
                localized: "settings.photo-import.footer.failed",
                defaultValue: "Retrying continues where it left off. Imported data is kept.",
                comment: "Settings photo-import footer after an import failed."
            ))
        } else if model.photoAuthStatus == .denied || model.photoAuthStatus == .restricted {
            Text(String(
                localized: "settings.photo-import.footer.no-access",
                defaultValue: "Photo import needs photo access. Allow it in Settings.",
                comment: "Settings photo-import footer when photo access is denied or restricted."
            ))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "settings.photo-import.footer", defaultValue: "Reads only timestamps and locations from your photos to rebuild trips you took before installing TravelLog. TravelLog never uploads or changes your photos.", comment: "Settings photo-import footer explaining what the import reads."))
                if iCloudSyncEnabled {
                    // Warn that imports can race before CloudKit shares ownership; ping dedup may leave duplicate stays or trips.
                    Text(String(
                        localized: "settings.photo-import.footer.sync-warning",
                        defaultValue: "With iCloud Sync on, import on one device at a time. Importing on two at once can create duplicate trips.",
                        comment: "Settings photo-import footer warning, shown when iCloud Sync is on, to import on one device at a time."
                    ))
                }
            }
        }
    }

    // MARK: - Photo Import Helpers

    private func progressSubtitle(state: PhotoImportState) -> String {
        let processed = state.processedAssetCount
        let accepted = state.acceptedPingCount
        if state.totalAssetCount > 0 {
            if state.totalAssetCount == 1 {
                return String(localized: "settings.photo-import.progress.total.one", defaultValue: "\(processed, format: .number.grouping(.never)) of \(state.totalAssetCount, format: .number.grouping(.never)) photos · \(accepted, format: .number.grouping(.never)) accepted", comment: "Photo import progress with a one-photo library and accepted-location count.")
            }
            return String(localized: "settings.photo-import.progress.total.other", defaultValue: "\(processed, format: .number.grouping(.never)) of \(state.totalAssetCount, format: .number.grouping(.never)) photos · \(accepted, format: .number.grouping(.never)) accepted", comment: "Photo import progress with a multi-photo library and accepted-location count.")
        }
        if processed == 1 {
            return String(localized: "settings.photo-import.progress.scanned.one", defaultValue: "\(processed, format: .number.grouping(.never)) photos scanned · \(accepted, format: .number.grouping(.never)) accepted", comment: "Photo import progress after scanning one photo, with accepted-location count.")
        }
        return String(localized: "settings.photo-import.progress.scanned.other", defaultValue: "\(processed, format: .number.grouping(.never)) photos scanned · \(accepted, format: .number.grouping(.never)) accepted", comment: "Photo import progress after scanning multiple photos, with accepted-location count.")
    }

    private func completedSubtitle(state: PhotoImportState) -> String {
        guard let completedAt = state.completedAt else {
            if state.acceptedPingCount == 1 {
                return String(localized: "settings.photo-import.completed.one", defaultValue: "\(state.acceptedPingCount, format: .number.grouping(.never)) photos imported", comment: "Completed photo import subtitle when one photo location was imported.")
            }
            return String(localized: "settings.photo-import.completed.other", defaultValue: "\(state.acceptedPingCount, format: .number.grouping(.never)) photos imported", comment: "Completed photo import subtitle when multiple photo locations were imported.")
        }
        let relativeDate = Self.fullRelativeFormatter.localizedString(for: completedAt, relativeTo: .now)
        if state.acceptedPingCount == 1 {
            return String(localized: "settings.photo-import.last-scan.one", defaultValue: "Last scan \(relativeDate) · \(state.acceptedPingCount, format: .number.grouping(.never)) photos", comment: "Last photo scan subtitle with its relative date and one imported photo location.")
        }
        return String(localized: "settings.photo-import.last-scan.other", defaultValue: "Last scan \(relativeDate) · \(state.acceptedPingCount, format: .number.grouping(.never)) photos", comment: "Last photo scan subtitle with its relative date and multiple imported photo locations.")
    }

    private func otherDeviceUpdatedAgo(from date: Date?) -> String {
        guard let date else {
            return String(localized: "settings.photo-import.other-device.currently-active", defaultValue: "Currently active", comment: "Photo import status when another device is currently active.")
        }
        let relativeDate = Self.abbreviatedRelativeFormatter.localizedString(for: date, relativeTo: .now)
        return String(localized: "settings.photo-import.other-device.updated", defaultValue: "Updated \(relativeDate)", comment: "Photo import status showing when another device last updated its progress.")
    }
}

extension SettingsModel {

    /// Compare device identity with import ownership to disable starts during another device’s active import.
    /// identifierForVendor is best-effort and may rotate on reinstall.
    static let thisDeviceID: String = {
        UIDevice.current.identifierForVendor?.uuidString ?? ""
    }()

    func startImport() async {
        canStartFreshAfterImportError = false
        isStartingImport = true
        defer { isStartingImport = false }
        do {
            try await AppDelegate.photoImportService.start(originDeviceID: Self.thisDeviceID)
        } catch let error as PhotoImportError {
            importErrorMessage = userFacingMessage(for: error)
            showImportError = true
        } catch {
            importErrorMessage = error.localizedDescription
            showImportError = true
        }
    }

    func resumeImport() async {
        canStartFreshAfterImportError = false
        isStartingImport = true
        defer { isStartingImport = false }
        do {
            try await AppDelegate.photoImportService.resume()
        } catch let error as PhotoImportError {
            if case .inconsistentLocalData = error {
                canStartFreshAfterImportError = true
                importErrorMessage = String(localized: "settings.photo-import.error.checkpoint-unverified", defaultValue: "Saved progress could not be verified. Start a fresh import. Existing locations are kept.")
            } else {
                importErrorMessage = userFacingMessage(for: error)
            }
            showImportError = true
        } catch {
            importErrorMessage = error.localizedDescription
            showImportError = true
        }
    }

    func cancelImport() async {
        canStartFreshAfterImportError = false
        isCancellingImport = true
        defer { isCancellingImport = false }
        if case .failure(let error) = await AppDelegate.photoImportService.cancel() {
            importErrorMessage = userFacingMessage(for: error)
            showImportError = true
        }
    }

    func discardImport() async {
        canStartFreshAfterImportError = false
        isDiscardingImport = true
        defer { isDiscardingImport = false }
        do {
            try await AppDelegate.photoImportService.discard()
            // Recluster released pings and heal home membership, matching the banner path.
            await PostDiscardReconcile.run()
        } catch let error as PhotoImportError {
            importErrorMessage = userFacingMessage(for: error)
            showImportError = true
        } catch {
            importErrorMessage = error.localizedDescription
            showImportError = true
        }
    }

    private func userFacingMessage(for error: PhotoImportError) -> String {
        error.userFacingMessage
    }
}
