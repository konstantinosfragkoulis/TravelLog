//
//  SettingsDataScreens.swift
//  TravelLog
//
//  Settings → Data: the Import & Export and Maintenance screens. Their
//  operations live on `SettingsModel`, so every screen sees the same
//  in-flight state and disables conflicting actions.
//

import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers
import os

// MARK: - Import & Export

struct SettingsImportExportView: View {
    @Bindable var model: SettingsModel

    @Query(sort: \PhotoImportState.startedAt, order: .forward)
    private var importStates: [PhotoImportState]

    /// Persistent running state blocks destructive actions; background import outlives transient UI flags.
    private var isImportRunning: Bool {
        importStates.contains { $0.status == .running }
    }

    var body: some View {
        List {
            PhotoImportSettingsSection(model: model)

            Section {
                Button {
                    model.showTripImportPicker = true
                } label: {
                    OperationRowLabel(isRunning: model.isImportingTrips) {
                        Text("Import Trip Data (JSON)")
                    }
                }
                .disabled(model.isAnyOperationRunning || isImportRunning)

                Button {
                    model.showTimelineImportPicker = true
                } label: {
                    OperationRowLabel(isRunning: model.isImportingTimeline) {
                        Text("Import Google Timeline")
                    }
                }
                .disabled(model.isAnyOperationRunning || isImportRunning)
                // On the BUTTON, not the outer chain: a second `.fileImporter`
                // on the same view as the JSON importer's is unreliable;
                // SwiftUI honors one per view.
                .fileImporter(
                    isPresented: $model.showTimelineImportPicker,
                    allowedContentTypes: [.json]
                ) { result in
                    switch result {
                    case .success(let url):
                        Task { await model.importTimeline(from: url) }
                    case .failure(let error):
                        model.externalImportIsGPX = false
                        model.timelineImportErrorMessage = error.localizedDescription
                    }
                }

                Button {
                    model.showGPXImportPicker = true
                } label: {
                    OperationRowLabel(isRunning: model.isImportingTimeline) {
                        Text("Import GPX Track")
                    }
                }
                .disabled(model.isAnyOperationRunning || isImportRunning)
                .fileImporter(
                    isPresented: $model.showGPXImportPicker,
                    // GPX has no built-in UTType; files usually surface as XML
                    // or a dynamic type. Accept both and let the parser judge.
                    allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml, .xml]
                ) { result in
                    switch result {
                    case .success(let url):
                        Task { await model.importGPX(from: url) }
                    case .failure(let error):
                        model.externalImportIsGPX = true
                        model.timelineImportErrorMessage = error.localizedDescription
                    }
                }
            } header: {
                Text(String(
                    localized: "settings.import-export.import.header",
                    defaultValue: "Import Files",
                    comment: "Header of the file-import section in Settings Import & Export."
                ))
            } footer: {
                Text(String(
                    localized: "settings.import-export.import.footer",
                    defaultValue: "Restore a Travel Log export, or add history from a Google Maps Timeline export (or a Takeout Semantic Location History file) or a GPX track with timestamps. Anything already here is skipped, so importing the same file twice is safe.",
                    comment: "Footer of the file-import section in Settings Import & Export: which files each import accepts, and that re-importing is safe."
                ))
            }

            Section {
                Button {
                    Task { await model.exportData() }
                } label: {
                    OperationRowLabel(isRunning: model.isExporting) {
                        Text("Export Trip Data (JSON)")
                    }
                }
                .disabled(model.isAnyOperationRunning)
            } footer: {
                Text(String(
                    localized: "settings.import-export.export.footer",
                    defaultValue: "The file includes your trips, home locations, routine places, time near home and home-area corrections. Keep it private.",
                    comment: "Footer of the export section in Settings Import & Export: what the exported file contains and that it is sensitive."
                ))
            }

            Section {
                Button(role: .destructive) {
                    model.showDeleteConfirmation = true
                } label: {
                    OperationRowLabel(isRunning: model.isDeleting) {
                        Text("Delete All Data")
                    }
                }
                .disabled(model.isAnyOperationRunning || isImportRunning)
            }
        }
        .headerProminence(.increased)
        .navigationTitle(SettingsDataLinks.importExportTitle)
        .sheet(isPresented: Binding<Bool>(
            get: { model.exportFileURL != nil },
            set: { if !$0 {
                // Delete the precise-location temporary export when sharing is dismissed.
                if let url = model.exportFileURL {
                    try? FileManager.default.removeItem(at: url)
                }
                model.exportFileURL = nil
            } }
        )) {
            if let url = model.exportFileURL {
                ActivityViewSheet(fileURL: url)
            }
        }
        .fileImporter(
            isPresented: $model.showTripImportPicker,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url):
                Task { await model.prepareTripImport(from: url) }
            case .failure(let error):
                model.tripImportErrorMessage = error.localizedDescription
            }
        }
        .modifier(ImportExportAlerts(model: model))
    }
}

/// Split from the screen's chain to stay within the Swift type-checker's budget.
private struct ImportExportAlerts: ViewModifier {
    @Bindable var model: SettingsModel

    func body(content: Content) -> some View {
        content
        .alert(model.externalImportIsGPX ? LocalizedStringKey("Import Complete") : LocalizedStringKey("Timeline Import Complete"), isPresented: Binding<Bool>(
            get: { model.timelineImportResultMessage != nil },
            set: { if !$0 { model.timelineImportResultMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = model.timelineImportResultMessage {
                Text(message)
            }
        }
        .alert(model.externalImportIsGPX ? LocalizedStringKey("Import Failed") : LocalizedStringKey("Timeline Import Failed"), isPresented: Binding<Bool>(
            get: { model.timelineImportErrorMessage != nil },
            set: { if !$0 { model.timelineImportErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = model.timelineImportErrorMessage {
                Text(message)
            }
        }
        .alert("Import Trips?", isPresented: $model.showTripImportConfirmation) {
            Button("Import") {
                if let pending = model.pendingTripImport {
                    model.pendingTripImport = nil
                    Task {
                        await model.performTripImport(
                            payload: pending.payload, fingerprint: pending.fingerprint
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) { model.pendingTripImport = nil }
        } message: {
            if let pending = model.pendingTripImport {
                Text(model.tripImportConfirmationText(
                    for: pending.preview, crossDeviceRepeat: pending.crossDeviceRepeat
                ))
            }
        }
        .alert("Import Complete", isPresented: Binding<Bool>(
            get: { model.tripImportResultMessage != nil },
            set: { if !$0 { model.tripImportResultMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = model.tripImportResultMessage {
                Text(message)
            }
        }
        .alert("Import Failed", isPresented: Binding<Bool>(
            get: { model.tripImportErrorMessage != nil },
            set: { if !$0 { model.tripImportErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = model.tripImportErrorMessage {
                Text(message)
            }
        }
        .alert("Delete All Data", isPresented: $model.showDeleteConfirmation) {
            Button("Delete Everything", role: .destructive) { Task { await model.deleteAllData() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(String(localized: "settings.delete-all.message", defaultValue: "This will permanently delete all pings, stays, trips, hex visits, year memories, detected upcoming trips, and your earlier-travels country checklist (on every synced device). Your homes, temporary homes and routine places will be kept. This cannot be undone.", comment: "Delete All Data confirmation message: what is deleted and what is kept."))
        }
        .alert("Export Failed", isPresented: $model.showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Could not export trip data. Please try again.")
        }
        .alert("Delete Incomplete", isPresented: $model.showDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Some data could not be deleted. Please try Delete All Data again.")
        }
        .alert("Discard Imported Data", isPresented: $model.showDiscardImportConfirmation) {
            Button("Discard", role: .destructive) { Task { await model.discardImport() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All trips and stays reconstructed from photos will be removed. Live-tracked data is preserved.")
        }
        .alert("Photo Import Error", isPresented: $model.showImportError, presenting: model.importErrorMessage) { _ in
            if model.canStartFreshAfterImportError {
                Button(String(localized: "settings.photo-import.action.start-fresh", defaultValue: "Start fresh import")) {
                    Task { await model.startImport() }
                }
            }
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}

// MARK: - Maintenance

struct SettingsMaintenanceView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        List {
            Section {
                Button {
                    Task { await model.retryGeocoding() }
                } label: {
                    OperationRowLabel(isRunning: model.isRetryingGeocoding) {
                        Text(String(
                            localized: "settings.maintenance.retry-place-names",
                            defaultValue: "Retry Missing Place Names",
                            comment: "Settings Maintenance button that retries naming places whose lookup failed."
                        ))
                    }
                }
                .disabled(model.isAnyOperationRunning)

                Button {
                    Task { await model.backfillHexCountries() }
                } label: {
                    OperationRowLabel(isRunning: model.isBackfillingHexes) {
                        MaintenanceRowText(
                            title: String(
                                localized: "settings.maintenance.fill-country-data",
                                defaultValue: "Fill Missing Country Data",
                                comment: "Settings Maintenance button that adds countries to older map visits."
                            ),
                            caption: String(
                                localized: "settings.maintenance.fill-country-data.caption",
                                defaultValue: "Adds countries to older map visits that don't have one.",
                                comment: "Caption under the Fill Missing Country Data button in Settings Maintenance."
                            ))
                    }
                }
                .disabled(model.isAnyOperationRunning)

                HistoryRebuildRow(model: model)

                Button {
                    Task { await model.regenerateAllTitles() }
                } label: {
                    OperationRowLabel(isRunning: model.isRegeneratingTitles) {
                        MaintenanceRowText(
                            title: String(localized: "Regenerate Trip Titles"),
                            caption: titleAvailabilityCaption)
                    }
                }
                .disabled(model.isAnyOperationRunning || !model.canonicalTripTitlesAvailable)

                // Explicit detection drains the lazy backlog and revisits terminal unknown legs after airport-data updates.
                Button {
                    model.detectFlights()
                } label: {
                    OperationRowLabel(isRunning: model.isDetectingFlights) {
                        Text("Detect Flights")
                    }
                }
                .disabled(model.isAnyOperationRunning)
            }

            Section {
                NavigationLink {
                    StaysListView()
                } label: {
                    Label("All Stays", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                }

                #if DEBUG
                // DEBUG exposes home-learning, confidence, FM status, and diagnostics export for device verification.
                NavigationLink {
                    DebugDiagnosticsView()
                } label: {
                    Label("Debug Diagnostics", systemImage: "wrench.and.screwdriver")
                }
                #endif
            } header: {
                Text(String(
                    localized: "settings.maintenance.inspect.header",
                    defaultValue: "Inspect Data",
                    comment: "Header of the Settings Maintenance section that opens the raw stays list."
                ))
            }
        }
        .headerProminence(.increased)
        .navigationTitle(SettingsDataLinks.maintenanceTitle)
        .onAppear { model.refreshCapabilities() }
        .alert(String(localized: "settings.title-regeneration.alert-title", defaultValue: "Trip Title Regeneration", comment: "Title of the trip-title regeneration result alert."), isPresented: Binding<Bool>(
            get: { model.titleRegenerationResultMessage != nil },
            set: { if !$0 { model.titleRegenerationResultMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = model.titleRegenerationResultMessage {
                Text(message)
            }
        }
        .alert(model.flightDetectFailed
            ? Text(String(
                localized: "common.save-error.try-again",
                defaultValue: "Couldn't save. Try again",
                comment: "Shared alert title after a user-authoritative save fails."
            ))
            : Text("Flight Detection Complete"), isPresented: Binding(
            get: { model.flightDetectResultMessage != nil },
            set: { if !$0 { model.flightDetectResultMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = model.flightDetectResultMessage, !message.isEmpty {
                Text(message)
            }
        }
        .alert(
            String(
                localized: "common.save-error.try-again",
                defaultValue: "Couldn't save. Try again",
                comment: "Shared alert title after a user-authoritative save fails."
            ),
            isPresented: $model.saveFailed
        ) {
            Button("OK", role: .cancel) {}
        }
    }

    private var titleAvailabilityCaption: String? {
        if !model.canonicalTripTitlesAvailable {
            return String(localized: "Requires Apple Intelligence")
        } else if model.selectedLanguageUsesEnglishTitleFallback {
            return String(localized: "Automatic titles are available in English")
        }
        return nil
    }
}

/// The single history-rebuild control. It owns the trip-store observation and
/// the backlog count, so a trip publication re-renders this row alone, and the
/// count runs off the main actor on its own context.
struct HistoryRebuildRow: View {
    @Bindable var model: SettingsModel

    /// Heuristic-only trips (`classifiedByAI == false && !userEdited`) that
    /// Apple Intelligence could classify again; offers the Enhance label.
    @State private var backlogCount = 0

    private struct RefreshKey: Equatable {
        let tripToken: Int
        let appleIntelligence: FMCapabilityState
    }

    var body: some View {
        // Both labels run reclassifyAll; Enhance is offered when FM is
        // available and heuristic backlog remains. User edits and favorites are preserved.
        Button {
            Task { await model.reclassifyAllTrips() }
        } label: {
            OperationRowLabel(isRunning: model.isReclassifying) {
                if offersEnhance {
                    Image(systemName: "sparkles")
                    Text("Enhance History with Apple Intelligence")
                } else {
                    MaintenanceRowText(
                        title: String(
                            localized: "settings.maintenance.rebuild-history",
                            defaultValue: "Rebuild Trip History",
                            comment: "Settings Maintenance button that checks every recorded stay again and rebuilds trips."
                        ),
                        caption: String(
                            localized: "settings.maintenance.rebuild-history.caption",
                            defaultValue: "Checks every recorded stay again and rebuilds your trips.",
                            comment: "Caption under the Rebuild Trip History button in Settings Maintenance."
                        ))
                }
            }
        }
        .disabled(model.isAnyOperationRunning)
        .task(id: RefreshKey(
            tripToken: StoreChangeTracker.shared.token(for: .trip),
            appleIntelligence: model.appleIntelligence
        )) {
            await refreshBacklog()
        }
    }

    private var offersEnhance: Bool {
        model.appleIntelligence == .available && backlogCount > 0
    }

    private func refreshBacklog() async {
        // Without Apple Intelligence the count cannot change the row.
        guard model.appleIntelligence == .available else {
            if backlogCount != 0 { backlogCount = 0 }
            return
        }
        let container = AppDelegate.modelContainer
        let interval = settingsSignposter.beginInterval("SettingsEnhanceBacklogCount")
        let count = await Task.detached(priority: .utility) {
            Self.backlogCount(in: container)
        }.value
        settingsSignposter.endInterval("SettingsEnhanceBacklogCount", interval, "count \(count)")
        // A newer trip publication restarted the task; its count wins.
        guard !Task.isCancelled else { return }
        if backlogCount != count { backlogCount = count }
    }

    /// A count on its own context; only the Int crosses back.
    nonisolated static func backlogCount(in container: ModelContainer) -> Int {
        let context = ModelContext(container)
        let predicate = #Predicate<Trip> { $0.classifiedByAI == false && $0.userEdited == false }
        return (try? context.fetchCount(FetchDescriptor<Trip>(predicate: predicate))) ?? 0
    }
}

// MARK: - Shared pieces

/// Titles of the two Data destinations, shared by the Settings rows and the screens.
enum SettingsDataLinks {
    static var importExportTitle: String {
        String(
            localized: "settings.data.import-export",
            defaultValue: "Import & Export",
            comment: "Settings Data row and screen title for importing and exporting travel data."
        )
    }

    static var maintenanceTitle: String {
        String(
            localized: "settings.data.maintenance",
            defaultValue: "Maintenance",
            comment: "Settings Data row and screen title for data repair tools."
        )
    }
}

private struct MaintenanceRowText: View {
    let title: String
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct OperationRowLabel<Content: View>: View {
    let isRunning: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            content
            if isRunning {
                Spacer()
                ProgressView()
            }
        }
    }
}

/// Wraps UIActivityViewController for sharing exported files.
private struct ActivityViewSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
