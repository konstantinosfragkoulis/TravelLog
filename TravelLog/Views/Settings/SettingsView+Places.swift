//
//  SettingsView+Places.swift
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

let settingsLogger = Logger(
    subsystem: "com.travellog.app", category: "SettingsView")

extension SettingsView {

    // MARK: - Actions

    /// "Delete" a home by ending it (setting endedAt) rather than physically removing it.
    /// This preserves the historical record so that past stays are still correctly
    /// classified against the home that was active at the time.
    /// Gate the write against pipeline saves and publish tracker changes.
    func deleteHomes(at offsets: IndexSet) {
        let ids = Set(offsets.compactMap { homes.indices.contains($0) ? homes[$0].id : nil })
        // `homes` is the active-only slice, so it IS the active set.
        let endable = HomeSaveDecision.endableHomeIDs(
            requested: ids, activeIDs: Set(homes.map(\.id)))
        guard !endable.isEmpty else {
            if !ids.isEmpty { showLastHomeAlert = true }
            return
        }
        Task {
            let outcome = await PipelineGate.shared.runReturning(
                touching: [.home, .trip]
            ) {
                await Self.endHomes(ids: endable)
            }
            switch outcome {
            case .ended:
                _ = await AppDelegate.tripClassifier.regenerateAllTitles()
                _ = await AppDelegate.tripTitleLocalizationService
                    .generateLocalizedTitlesStage(maxTripsPerCall: nil)
                WidgetCenter.shared.reloadAllTimelines()
            case .refusedLastHome:
                showLastHomeAlert = true
            case .failed:
                saveFailed = true
            case .nothingToEnd:
                break
            }
        }
    }

    private static func endHomes(ids: Set<UUID>) -> HomeEndOutcome {
        endHomes(ids: ids, context: AppDelegate.modelContainer.mainContext)
    }

    static func endHomes(
        ids: Set<UUID>,
        context modelContext: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) -> HomeEndOutcome {
        // Rollback is context-wide; preserve earlier pending edits first.
        if modelContext.hasChanges {
            do {
                try save(modelContext)
            } catch {
                settingsLogger.error("Home ending pre-save failed: \(error.localizedDescription)")
                return .failed
            }
        }
        // Gated re-validation (the performMerge pattern): the UI decided
        // against its @Query snapshot, but a synced change can land between
        // the swipe and gate entry — re-derive the active set here and let
        // `endableHomeIDs` refuse again if this would end the last home(s).
        // A failed read is not absence: it must not pass for "nothing to end".
        let actives: [Home]
        do {
            actives = try fetchActiveHomesForEnding(in: modelContext)
        } catch {
            settingsLogger.error("Home ending read failed: \(error.localizedDescription)")
            return .failed
        }
        let activeIDs = Set(actives.map(\.id))
        guard !ids.isDisjoint(with: activeIDs) else { return .nothingToEnd }
        let endable = HomeSaveDecision.endableHomeIDs(
            requested: ids, activeIDs: activeIDs)
        let rows = actives.filter { endable.contains($0.id) }
        guard !rows.isEmpty else { return .refusedLastHome }
        let titleInputsBefore: [TripTitleStore.ActiveHomeTitleInput]
        do {
            titleInputsBefore = try TripTitleStore
                .fetchActiveHomeTitleInputs(in: modelContext)
        } catch {
            settingsLogger.error("Home ending title-input read failed: \(error.localizedDescription)")
            return .failed
        }
        for row in rows {
            row.endedAt = .now
        }
        do {
            _ = try TripTitleStore
                .invalidateAllGeneratedTitlesIfActiveHomesChanged(
                    from: titleInputsBefore,
                    in: modelContext)
            try save(modelContext)
        } catch {
            modelContext.rollback()
            settingsLogger.error("Home ending save failed: \(error.localizedDescription)")
            return .failed
        }
        // Bookkeeping after the commit; it never turns an ended Home into a failure.
        try? TripTitleStore.recordActiveHomeTitleFingerprint(
            in: modelContext)
        return .ended
    }

    private static func fetchActiveHomesForEnding(in context: ModelContext) throws -> [Home] {
        #if DEBUG
        if failHomeEndFetchForTesting { throw CocoaError(.fileReadUnknown) }
        #endif
        let activePredicate = #Predicate<Home> { $0.endedAt == nil }
        return try context.fetch(FetchDescriptor<Home>(predicate: activePredicate))
    }

    #if DEBUG
    nonisolated(unsafe) static var failHomeEndFetchForTesting = false
    #endif

    /// Serialize routine-place deletion through the gate as for homes.
    func deactivateRoutinePlaces(at offsets: IndexSet) {
        let ids = Set(offsets.compactMap { routinePlaces.indices.contains($0) ? routinePlaces[$0].id : nil })
        Task {
            let saved = await PipelineGate.shared.runReturning(touching: [.routinePlace]) {
                await Self.deactivateRoutines(ids: ids)
            }
            if !saved { saveFailed = true }
        }
    }

    private static func deactivateRoutines(ids: Set<UUID>) -> Bool {
        deactivateRoutines(ids: ids, context: AppDelegate.modelContainer.mainContext)
    }

    static func deactivateRoutines(ids: Set<UUID>, context modelContext: ModelContext) -> Bool {
        // Rollback is context-wide; preserve earlier pending edits first.
        if modelContext.hasChanges {
            do {
                try modelContext.save()
            } catch {
                settingsLogger.error("Routine-place removal pre-save failed: \(error.localizedDescription)")
                return false
            }
        }
        do {
            let rows = try fetchRoutinesForDeactivation(ids: ids, in: modelContext)
            guard !rows.isEmpty else { return true }
            for row in rows {
                row.isActive = false
                row.endedAt = .now
            }
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            settingsLogger.error("Routine-place removal save failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func fetchRoutinesForDeactivation(
        ids: Set<UUID>, in context: ModelContext
    ) throws -> [RoutinePlace] {
        #if DEBUG
        if failRoutineFetchForTesting { throw CocoaError(.fileReadUnknown) }
        #endif
        let predicate = #Predicate<RoutinePlace> { ids.contains($0.id) }
        return try context.fetch(FetchDescriptor<RoutinePlace>(predicate: predicate))
    }

    #if DEBUG
    nonisolated(unsafe) static var failRoutineFetchForTesting = false
    #endif
}

// MARK: - Home Form Sheet (Add & Edit)

/// Unified form for creating and editing Home records.
enum HomeFormMode: Identifiable {
    case add
    case edit(Home)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let home): home.id.uuidString
        }
    }
}

/// What a Home removal swipe did, so the UI can answer each case honestly.
nonisolated enum HomeEndOutcome: Sendable, Equatable {
    /// The Homes were ended and the change committed.
    case ended
    /// Ending them would leave no active Home.
    case refusedLastHome
    /// None of the requested Homes is still active.
    case nothingToEnd
    /// A read or save failed; nothing changed.
    case failed
}

/// Pure home-save decision seams; route every form branch through them for consistent reconciliation.
enum HomeSaveDecision {

    /// The keep-both / replace dialog's two commit choices.
    nonisolated enum AddChoice {
        case keepBothHomes
        case replaceExistingHomes
    }

    /// An `.add` with other active homes must ask which kind of add it is.
    nonisolated static func promptsAddChoice(isAdd: Bool, activeHomeCount: Int) -> Bool {
        isAdd && activeHomeCount > 0
    }

    /// Only the explicit "I Moved — Replace" choice ends the existing
    /// active homes. Keep-both is the multi-home path.
    nonisolated static func endsExistingHomes(_ choice: AddChoice) -> Bool {
        choice == .replaceExistingHomes
    }

    /// A reverse geocode with neither a locality nor an administrative area is
    /// likely an ocean coordinate or an unmapped land area and needs explicit
    /// confirmation before it becomes a home.
    nonisolated static func requiresUnmappedConfirmation(
        locality: String?,
        administrativeArea: String?
    ) -> Bool {
        let hasLocality = locality?.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty == false
        let hasAdministrativeArea = administrativeArea?.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty == false
        return !hasLocality && !hasAdministrativeArea
    }

    /// A deletion (swipe) may never end the LAST active home. Trips are
    /// what happen between stays at home: with zero active homes no new
    /// stay can classify `.home`, no trip can ever close (`closeTrip`
    /// needs a qualifying home boundary), `matchesHome`'s pre-history
    /// fallback disarms (it requires a current home), and the confidence
    /// gate falls into its home-less decline path. Returns the ids that
    /// may actually be ended: everything requested, or NOTHING when the
    /// request would empty the active set — refuse whole rather than
    /// leave an arbitrary survivor the user didn't choose.
    nonisolated static func endableHomeIDs(
        requested: Set<UUID>, activeIDs: Set<UUID>
    ) -> Set<UUID> {
        guard !requested.isEmpty else { return [] }
        return activeIDs.subtracting(requested).isEmpty ? [] : requested
    }

    /// An in-place edit needs `applyHomeChange` reconciliation whenever the
    /// home's COVERAGE changed (radius or any location delta) — a grown
    /// ring can swallow an in-flight trip's stays (which should become
    /// home and close the trip), and a shrunk ring strands `.home` stays
    /// outside coverage. Label-only edits change nothing classification
    /// reads.
    nonisolated static func coverageChanged(
        oldLatitude: Double, oldLongitude: Double, oldRadiusKm: Double,
        newLatitude: Double, newLongitude: Double, newRadiusKm: Double
    ) -> Bool {
        oldRadiusKm != newRadiusKm
            || oldLatitude != newLatitude
            || oldLongitude != newLongitude
    }
}

/// Confirmation summary shown once a coordinate is chosen in a location form:
/// the place's name when the form knows it, else "Location set".
@ViewBuilder
func locationSetSummary(_ coord: CLLocationCoordinate2D, placeName: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Label {
            if let placeName {
                Text(placeName)
            } else {
                Text("Location set")
            }
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.accent)
        }
        .font(.subheadline)
        Text("\(coord.latitude, specifier: "%.5f"), \(coord.longitude, specifier: "%.5f")")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
    }
}

struct HomeFormSheet: View {

    let mode: HomeFormMode
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var label: String
    @State private var cityName: String
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var radiusKm: Double
    @State private var showMapPicker = false
    @State private var isSaving = false
    @State private var saveFailed = false
    /// Ask keep-both or replace when adding beside active homes; all consumers use the active-home union/minimum.
    /// Arrival at ANY active home closes a trip.
    @State private var showAddChoice = false
    @State private var existingActiveLabels: [String] = []
    /// End only the active-home IDs shown in the confirmation, never homes arriving during an await.
    @State private var existingActiveIDsShown: Set<UUID> = []
    @State private var pendingUnmappedSave: HomeSavePayload?
    @State private var showUnmappedConfirmation = false

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    init(mode: HomeFormMode) {
        self.mode = mode

        switch mode {
        case .add:
            _label = State(initialValue: "")
            _cityName = State(initialValue: "")
            _selectedCoordinate = State(initialValue: nil)
            _radiusKm = State(initialValue: 25.0)
        case .edit(let home):
            _label = State(initialValue: home.label)
            _cityName = State(initialValue: home.locality ?? "")
            _selectedCoordinate = State(initialValue: CLLocationCoordinate2D(latitude: home.latitude, longitude: home.longitude))
            _radiusKm = State(initialValue: home.radiusKm)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Label (e.g., \"London Flat\")", text: $label)
                    TextField("City name for stats (e.g., \"Athens\")", text: $cityName)
                }
                // The save captured the form; a later edit would not be the one saved.
                .disabled(isSaving)

                Section("Location") {
                    if let coord = selectedCoordinate {
                        HStack {
                            locationSetSummary(coord)
                            Spacer()
                        }

                        RadiusMapPreview(coordinate: coord, radiusMeters: nil)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }

                    Button {
                        showMapPicker = true
                    } label: {
                        Label(
                            selectedCoordinate == nil ? "Choose on Map" : "Change Location",
                            systemImage: "map"
                        )
                    }
                }
                .disabled(isSaving)

                // Membership uses city boundaries or learned home areas; preserve legacy radiusKm untouched on edit.
                Section("Home Area") {
                    HomeAreaSourcePreview(coordinate: selectedCoordinate)
                }
            }
            .navigationTitle(isEditing ? "Edit Home" : "New Home")
        .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { attemptSave() }
                            .disabled(!isValid)
                    }
                }
            }
            // A save in flight reports back to this sheet.
            .interactiveDismissDisabled(isSaving)
            .confirmationDialog(
                existingActiveLabels.count == 1
                    ? String(
                        localized: "settings.home-add.existing.one",
                        defaultValue: "You already have a home: \(existingActiveLabels[0])",
                        comment: "Add-home confirmation title when one existing home is active."
                    )
                    : String(
                        localized: "settings.home-add.existing.other",
                        defaultValue: "You already have \(existingActiveLabels.count, format: .number.grouping(.never)) homes",
                        comment: "Add-home confirmation title when multiple existing homes are active."
                    ),
                isPresented: $showAddChoice,
                titleVisibility: .visible
            ) {
                Button("Keep Both as a Second Home") {
                    save(endingExistingHomes: HomeSaveDecision.endsExistingHomes(.keepBothHomes))
                }
                Button("Replace Existing Home", role: .destructive) {
                    save(endingExistingHomes: HomeSaveDecision.endsExistingHomes(.replaceExistingHomes))
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(String(localized: "settings.home-add.choice.message", defaultValue: "Keep both if this is a genuine second home, like a summer or winter house. Arriving at either one ends a trip. Replace if you moved; the old home stays in your history for past trips. For a few months of study or work, cancel and add a temporary home instead.", comment: "Message of the add-home confirmation that offers keeping both homes or replacing the existing one."))
            }
            .alert(
                unmappedHomeConfirmationText,
                isPresented: $showUnmappedConfirmation,
                presenting: pendingUnmappedSave
            ) { payload in
                Button("Save") {
                    pendingUnmappedSave = nil
                    Task { await commit(payload) }
                }
                Button("Cancel", role: .cancel) {
                    pendingUnmappedSave = nil
                    isSaving = false
                }
            }
            .navigationDestination(isPresented: $showMapPicker) {
                MapLocationPicker(selectedCoordinate: $selectedCoordinate)
                    .navigationTitle("Choose Location")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showMapPicker = false }
                        }
                    }
            }
            .alert(
                String(
                    localized: "common.save-error.try-again",
                    defaultValue: "Couldn't save. Try again",
                    comment: "Shared alert title after a user-authoritative save fails."
                ),
                isPresented: $saveFailed
            ) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private var isValid: Bool {
        selectedCoordinate != nil
    }

    private var unmappedHomeConfirmationText: String {
        String(
            localized: "home.unmapped.confirmation",
            defaultValue: "This location looks unmapped or at sea. Trip detection may not recognize returns home. Save anyway?",
            comment: "Confirmation shown before saving a home whose reverse geocode found neither a locality nor an administrative area."
        )
    }

    /// Save-button entry: an `.add` while other homes are active routes
    /// through the keep-both / replace choice; everything else (first home,
    /// edits) saves directly. Edits never touch OTHER homes.
    private func attemptSave() {
        if case .add = mode {
            let activePredicate = #Predicate<Home> { $0.endedAt == nil }
            let actives = (try? modelContext.fetch(FetchDescriptor<Home>(predicate: activePredicate))) ?? []
            if HomeSaveDecision.promptsAddChoice(isAdd: true, activeHomeCount: actives.count) {
                existingActiveLabels = actives.map { $0.displayLabel() }.sorted()
                // Capture only homes shown in the dialog; do not end newly synced homes after geocoding awaits.
                existingActiveIDsShown = Set(actives.map(\.id))
                showAddChoice = true
                return
            }
        }
        save(endingExistingHomes: false)
    }

    private func save(endingExistingHomes: Bool) {
        guard let coord = selectedCoordinate else { return }

        // Capture the edit target ID before awaiting; never carry a model across suspension.
        var target: HomeSavePayload.Target = .add
        if case .edit(let home) = mode {
            guard !home.isDeleted else {
                dismiss()
                return
            }
            target = .edit(home.id)
        }

        isSaving = true
        let label = self.label
        let cityName = self.cityName
        let radiusKm = self.radiusKm
        let shownActiveHomeIDs = self.existingActiveIDsShown

        Task {
            // Opt into one-shot MapKit fallback when offline home geocoding lacks locality.
            var geocodedLocality: String?
            var adminArea: String?
            var countryName: String?
            var countryCode: String?

            if let r = await GeocodeResolver.shared.resolveWithFallback(
                latitude: coord.latitude, longitude: coord.longitude
            ) {
                // Country-name guard (`Result.localityForStorage`) — never
                // store the country name as the home's city.
                geocodedLocality = r.localityForStorage
                adminArea = r.administrativeArea
                countryName = r.country
                countryCode = r.isoCountryCode
            }

            // Use user-provided city name if set, otherwise fall back to geocoded
            let resolvedLocality = cityName.isEmpty ? geocodedLocality : cityName

            let payload = HomeSavePayload(
                target: target,
                label: label,
                latitude: coord.latitude,
                longitude: coord.longitude,
                radiusKm: radiusKm,
                locality: resolvedLocality,
                administrativeArea: adminArea,
                country: countryName,
                isoCountryCode: countryCode,
                endingExistingHomes: endingExistingHomes,
                shownActiveHomeIDs: shownActiveHomeIDs,
                now: .now
            )

            if HomeSaveDecision.requiresUnmappedConfirmation(
                locality: geocodedLocality,
                administrativeArea: adminArea
            ) {
                pendingUnmappedSave = payload
                showUnmappedConfirmation = true
                return
            }

            await commit(payload)
        }
    }

    private func commit(_ payload: HomeSavePayload) async {
        // Gate the save against pipeline writes; run(touching:) publishes the home change.
        // AppDelegate.modelContainer.mainContext must match the context injected by TravelLogApp.
        // `.homeAreaOverride` too: a nearby move copies corrections to the new Home.
        let saveResult = await PipelineGate.shared.runReturning(
            touching: [.home, .trip, .homeAreaOverride]
        ) {
            await MainActor.run {
                HomeSaveWorker.apply(payload, context: AppDelegate.modelContainer.mainContext)
            }
        }

        guard !saveResult.failed else {
            isSaving = false
            saveFailed = true
            return
        }

        // Reconcile home changes from contiguous arrival so existing stays close the trip at the real homecoming.
        // Keep reconciliation OUTSIDE the gate: the classifier self-serializes and long runs must not starve SLC saves.
        // The worker queued the reconciliation before its save; a failed or
        // cancelled one stays queued for the activation and launch drain,
        // which repeats this whole sequence in order.
        if let pending = saveResult.pendingReconciliation {
            Task {
                let outcome = await AppDelegate.tripClassifier.applyHomeChange(
                    homeID: pending.id,
                    onSettled: { CoverageReconciliationQueue.complete(pending) })
                guard outcome.isSettled else { return }
                _ = await AppDelegate.tripTitleLocalizationService
                    .generateLocalizedTitlesStage(maxTripsPerCall: nil)
                StoreChangeTracker.shared.bump([.home, .stay, .trip])
                WidgetCenter.shared.reloadAllTimelines()
                // Heal changed membership immediately; unchanged fingerprints are a no-op.
                await HomeAreaHealing.healIfNeeded()
            }
        } else if saveResult.titleInputsChanged {
            Task {
                _ = await AppDelegate.tripClassifier.regenerateAllTitles()
                _ = await AppDelegate.tripTitleLocalizationService
                    .generateLocalizedTitlesStage(maxTripsPerCall: nil)
                WidgetCenter.shared.reloadAllTimelines()
            }
        }

        isSaving = false
        dismiss()
    }
}

// MARK: - Home save (gated write path)

/// Capture all HomeSaveWorker inputs before geocoding; no model crosses suspension.
struct HomeSavePayload: Sendable {
    enum Target: Sendable {
        case add
        /// The row's ID, never the row — it can be hard-deleted mid-await.
        case edit(UUID)
    }
    let target: Target
    let label: String
    let latitude: Double
    let longitude: Double
    let radiusKm: Double
    /// Nil geocode fields preserve stored metadata under the coalesce-don’t-wipe rule.
    let locality: String?
    let administrativeArea: String?
    let country: String?
    let isoCountryCode: String?
    let endingExistingHomes: Bool
    /// Active homes actually named by the confirmation dialog.
    let shownActiveHomeIDs: Set<UUID>
    /// One clock read for every `endedAt`/`startedAt` written by this save.
    let now: Date
}

/// Gated home-save worker accepts Sendable inputs and refetches models on an injected context.
/// Context injection provides an in-memory test seam.
enum HomeSaveWorker {

    struct Result: Equatable {
        let reconcileHomeID: UUID?
        let titleInputsChanged: Bool
        let failed: Bool
        /// The queued reconciliation for `reconcileHomeID`, committed with the save.
        var pendingReconciliation: CoverageReconciliationQueue.Entry? = nil

        static let noChange = Result(
            reconcileHomeID: nil,
            titleInputsChanged: false,
            failed: false)

        static let failure = Result(
            reconcileHomeID: nil,
            titleInputsChanged: false,
            failed: true)
    }

    #if DEBUG
    nonisolated(unsafe) static var failHomeWorkerOverrideFetchForTesting = false
    nonisolated(unsafe) static var failHomeWorkerCurrentHomesFetchForTesting = false
    #endif

    /// Carry overrides for pin corrections or in-town moves within the legacy radius cap;
    /// larger relocations leave teachings scoped to the ended home era.
    static let overrideCarryLimitKm = 25.0

    /// Copy each ended nearby Home's corrections to the successor era. The
    /// originals stay with their Home, which keeps classifying its own era;
    /// ownership is never repointed (that is only right for a dedup loser).
    /// Copies keep kind (raw), centre, radius, provenance and creation date,
    /// and skip a successor row that already has the same identity.
    @MainActor
    private static func carryOverrides(
        from endedHomeIDs: [UUID], to newHomeID: UUID, in context: ModelContext
    ) throws {
        guard !endedHomeIDs.isEmpty else { return }
        #if DEBUG
        if failHomeWorkerOverrideFetchForTesting { throw CocoaError(.fileReadUnknown) }
        #endif
        let ended = Set(endedHomeIDs)
        let all = try context.fetch(FetchDescriptor<HomeAreaOverride>())
            .filter { !$0.isDeleted }
        func successorKey(_ row: HomeAreaOverride) -> String {
            HomeAreaOverrideDeduplicator.identityKey(
                kindRaw: row.kindRaw, homeID: newHomeID,
                latitude: row.centerLatitude, longitude: row.centerLongitude)
        }
        var successorKeys = Set(all.filter { $0.homeID == newHomeID }.map(successorKey))
        // The override deduplicator's winner order, so colliding sources
        // copy the same row whatever the fetch order.
        let sources = all
            .filter { row in row.homeID.map(ended.contains) ?? false }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        for row in sources {
            guard successorKeys.insert(successorKey(row)).inserted else { continue }
            let copy = HomeAreaOverride(
                kind: .include,
                centerLatitude: row.centerLatitude,
                centerLongitude: row.centerLongitude,
                radiusKm: row.radiusKm,
                homeID: newHomeID,
                sourceTripName: row.sourceTripName)
            copy.kindRaw = row.kindRaw
            copy.createdAt = row.createdAt
            context.insert(copy)
        }
    }

    @MainActor
    private static func fetchCurrentHomes(
        shownIDs: Set<UUID>, in context: ModelContext
    ) throws -> [Home] {
        #if DEBUG
        if failHomeWorkerCurrentHomesFetchForTesting { throw CocoaError(.fileReadUnknown) }
        #endif
        let currentPredicate = #Predicate<Home> {
            $0.endedAt == nil && shownIDs.contains($0.id)
        }
        return try context.fetch(FetchDescriptor<Home>(predicate: currentPredicate))
    }

    /// - Returns: the targeted reconciliation ID plus whether the global
    ///   active-home title prompt changed.
    @MainActor
    @discardableResult
    static func apply(
        _ payload: HomeSavePayload,
        context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() },
        pendingDefaults: UserDefaults = .standard
    ) -> Result {
        var reconcileHomeID: UUID?
        // Rollback is context-wide; preserve earlier pending edits first.
        if context.hasChanges {
            do {
                try save(context)
            } catch {
                settingsLogger.error("Home save pre-save failed: \(error.localizedDescription)")
                return .failure
            }
        }
        do {
            let titleInputsBefore = try TripTitleStore.fetchActiveHomeTitleInputs(in: context)

            switch payload.target {
            case .add:
                // Only “I Moved — Replace” ends active homes; “Keep Both” preserves them.
                var endedNearby: [UUID] = []
                if payload.endingExistingHomes {
                    let currentHomes = try fetchCurrentHomes(
                        shownIDs: payload.shownActiveHomeIDs, in: context)
                    for existing in currentHomes {
                        existing.endedAt = payload.now
                        let km = CLLocation(latitude: existing.latitude,
                                            longitude: existing.longitude)
                            .distance(from: CLLocation(latitude: payload.latitude,
                                                       longitude: payload.longitude)) / 1000.0
                        if km <= overrideCarryLimitKm { endedNearby.append(existing.id) }
                    }
                }

                let home = Home(
                    label: payload.label,
                    latitude: payload.latitude,
                    longitude: payload.longitude,
                    radiusKm: payload.radiusKm
                )
                home.locality = payload.locality
                home.administrativeArea = payload.administrativeArea
                home.country = payload.country
                home.isoCountryCode = payload.isoCountryCode
                context.insert(home)
                reconcileHomeID = home.id
                try carryOverrides(from: endedNearby, to: home.id, in: context)

            case .edit(let homeID):
                // Refetch by ID after suspension; if dedup deleted the target, its survivor already carries the data.
                let id = homeID
                let predicate = #Predicate<Home> { $0.id == id }
                guard let home = try context.fetch(FetchDescriptor<Home>(predicate: predicate)).first else {
                    return .noChange
                }

                let oldLocation = CLLocation(latitude: home.latitude, longitude: home.longitude)
                let newLocation = CLLocation(latitude: payload.latitude, longitude: payload.longitude)
                let distance = oldLocation.distance(from: newLocation)

                if distance > 1000 {
                    // Significant move: end the old record, create a new version so
                    // the old coordinates still classify historical stays.
                    home.endedAt = payload.now
                    let oldHomeID = home.id

                    let newHome = Home(
                        label: payload.label,
                        latitude: payload.latitude,
                        longitude: payload.longitude,
                        radiusKm: payload.radiusKm,
                        startedAt: payload.now
                    )
                    newHome.locality = payload.locality
                    newHome.administrativeArea = payload.administrativeArea
                    newHome.country = payload.country
                    newHome.isoCountryCode = payload.isoCountryCode
                    context.insert(newHome)
                    reconcileHomeID = newHome.id
                    // Carry teachings across a >1 km pin-edit version bump, using the replace path’s distance guard.
                    if distance / 1000.0 <= overrideCarryLimitKm {
                        try carryOverrides(from: [oldHomeID], to: newHome.id, in: context)
                    }
                } else {
                    // Reconcile coverage changes against the refetched row; label-only edits skip reconciliation.
                    let needsReconcile = HomeSaveDecision.coverageChanged(
                        oldLatitude: home.latitude, oldLongitude: home.longitude,
                        oldRadiusKm: home.radiusKm,
                        newLatitude: payload.latitude, newLongitude: payload.longitude,
                        newRadiusKm: payload.radiusKm
                    )
                    home.label = payload.label
                    home.latitude = payload.latitude
                    home.longitude = payload.longitude
                    home.radiusKm = payload.radiusKm
                    // Coalesce, don’t wipe: failed lookups change no stored metadata.
                    home.locality = payload.locality ?? home.locality
                    home.administrativeArea = payload.administrativeArea ?? home.administrativeArea
                    home.country = payload.country ?? home.country
                    home.isoCountryCode = payload.isoCountryCode ?? home.isoCountryCode
                    if needsReconcile {
                        reconcileHomeID = home.id
                    }
                }
            }

            let titleInputsChanged = try TripTitleStore
                .invalidateAllGeneratedTitlesIfActiveHomesChanged(
                    from: titleInputsBefore,
                    in: context)
            // Queue the reconciliation before the edit can become durable,
            // so no kill leaves a committed edit without its reconciliation.
            let staged = reconcileHomeID.map {
                CoverageReconciliationQueue.stage(.home, id: $0, defaults: pendingDefaults)
            }
            do {
                try save(context)
            } catch {
                // Withdraw only this edit: an earlier committed edit of the
                // same Home may still owe its reconciliation.
                if let staged {
                    CoverageReconciliationQueue.withdraw(staged, defaults: pendingDefaults)
                }
                throw error
            }
            try? TripTitleStore.recordActiveHomeTitleFingerprint(in: context)
            return Result(
                reconcileHomeID: reconcileHomeID,
                titleInputsChanged: titleInputsChanged,
                failed: false,
                pendingReconciliation: staged?.entry)
        } catch {
            context.rollback()
            return .failure
        }
    }
}

// MARK: - Routine Place Form Sheet (Add & Edit)

enum RoutinePlaceFormMode: Identifiable {
    case add
    case edit(RoutinePlace)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let place): place.id.uuidString
        }
    }
}

struct RoutinePlaceFormSheet: View {

    let mode: RoutinePlaceFormMode
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var label: String
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var radiusMeters: Double
    @State private var showMapPicker = false
    @State private var isSaving = false
    @State private var saveFailed = false

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    init(mode: RoutinePlaceFormMode) {
        self.mode = mode

        switch mode {
        case .add:
            _label = State(initialValue: "")
            _selectedCoordinate = State(initialValue: nil)
            _radiusMeters = State(initialValue: 500.0)
        case .edit(let place):
            _label = State(initialValue: place.label)
            _selectedCoordinate = State(initialValue: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude))
            _radiusMeters = State(initialValue: place.radiusMeters)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Label (e.g., \"University\", \"Gym\")", text: $label)
                }
                // The save captured the form; a later edit would not be the one saved.
                .disabled(isSaving)

                Section("Location") {
                    if let coord = selectedCoordinate {
                        HStack {
                            locationSetSummary(coord)
                            Spacer()
                        }

                        RadiusMapPreview(coordinate: coord, radiusMeters: radiusMeters)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }

                    Button {
                        showMapPicker = true
                    } label: {
                        Label(
                            selectedCoordinate == nil ? "Choose on Map" : "Change Location",
                            systemImage: "map"
                        )
                    }
                }
                .disabled(isSaving)

                Section("Radius") {
                    VStack {
                        Slider(value: $radiusMeters, in: 100...2000, step: 100)
                        Text(UnitsFormatter.formatRoutineRadius(radiusMeters))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isSaving)
            }
            .navigationTitle(isEditing ? "Edit Routine Place" : "New Routine Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .disabled(!isValid)
                    }
                }
            }
            // A save in flight reports back to this sheet.
            .interactiveDismissDisabled(isSaving)
            .navigationDestination(isPresented: $showMapPicker) {
                MapLocationPicker(selectedCoordinate: $selectedCoordinate)
                    .navigationTitle("Choose Location")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showMapPicker = false }
                        }
                    }
            }
            .alert(
                String(
                    localized: "common.save-error.try-again",
                    defaultValue: "Couldn't save. Try again",
                    comment: "Shared alert title after a user-authoritative save fails."
                ),
                isPresented: $saveFailed
            ) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private var isValid: Bool {
        !label.isEmpty && selectedCoordinate != nil
    }

    private func save() {
        guard !isSaving, let coord = selectedCoordinate else { return }

        var target: RoutinePlaceSavePayload.Target = .add
        if case .edit(let place) = mode {
            guard !place.isDeleted else {
                dismiss()
                return
            }
            target = .edit(place.id)
        }

        let payload = RoutinePlaceSavePayload(
            target: target,
            label: label,
            latitude: coord.latitude,
            longitude: coord.longitude,
            radiusMeters: radiusMeters,
            now: .now
        )

        isSaving = true
        Task {
            // Gate routine-place saves against pipeline writes and publish tracker changes.
            let result = await PipelineGate.shared.runReturning(touching: [.routinePlace]) {
                await MainActor.run {
                    RoutinePlaceSaveWorker.apply(payload, context: AppDelegate.modelContainer.mainContext)
                }
            }

            guard !result.failed else {
                isSaving = false
                saveFailed = true
                return
            }

            // Reconciliation OUTSIDE the gate — the classifier self-serializes
            // on its own `isRunning` and can run for minutes. A failed or
            // cancelled one stays queued for the activation and launch drain.
            if let pending = result.pendingReconciliation {
                Task {
                    let outcome = await AppDelegate.tripClassifier.applyRoutinePlaceChange(
                        placeID: pending.id,
                        onSettled: { CoverageReconciliationQueue.complete(pending) })
                    guard outcome.isSettled else { return }
                    _ = await AppDelegate.tripTitleLocalizationService
                        .generateLocalizedTitlesStage(maxTripsPerCall: nil)
                    StoreChangeTracker.shared.bump([.routinePlace, .stay, .trip])
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }

            isSaving = false
            dismiss()
        }
    }
}

// MARK: - Routine-place save (gated write path)

/// Sendable capture for RoutinePlaceSaveWorker.
struct RoutinePlaceSavePayload: Sendable {
    enum Target: Sendable {
        case add
        case edit(UUID)
    }
    let target: Target
    let label: String
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double
    let now: Date
}

/// The routine-place add/edit write, as a static worker over an injected
/// context — same `performMerge` shape as `HomeSaveWorker`.
enum RoutinePlaceSaveWorker {

    struct Result: Equatable {
        let reconcileID: UUID?
        let failed: Bool
        /// The queued reconciliation for `reconcileID`, committed with the save.
        var pendingReconciliation: CoverageReconciliationQueue.Entry? = nil

        static let failure = Result(reconcileID: nil, failed: true)
    }

    /// - Returns: the place ID needing reconciliation, or nil, plus whether the save failed.
    ///
    /// Only in-place COVERAGE changes reconcile historical stays.
    /// New and moved places start now: matchesRoutine’s time rules prevent them from applying retroactively.
    @MainActor
    @discardableResult
    static func apply(
        _ payload: RoutinePlaceSavePayload,
        context: ModelContext,
        save: (ModelContext) throws -> Void = { try $0.save() },
        pendingDefaults: UserDefaults = .standard
    ) -> Result {
        var reconcileID: UUID?
        // Rollback is context-wide; preserve earlier pending edits first.
        if context.hasChanges {
            do {
                try save(context)
            } catch {
                settingsLogger.error("Routine-place save pre-save failed: \(error.localizedDescription)")
                return .failure
            }
        }
        switch payload.target {
        case .add:
            let place = RoutinePlace(
                label: payload.label,
                latitude: payload.latitude,
                longitude: payload.longitude,
                radiusMeters: payload.radiusMeters
            )
            context.insert(place)

        case .edit(let placeID):
            let id = placeID
            let predicate = #Predicate<RoutinePlace> { $0.id == id }
            let fetched: RoutinePlace?
            do {
                fetched = try context.fetch(FetchDescriptor<RoutinePlace>(predicate: predicate)).first
            } catch {
                // A failed read is not absence; nothing is mutated yet.
                settingsLogger.error("Routine-place edit fetch failed: \(error.localizedDescription)")
                return .failure
            }
            // Deleted meanwhile: nothing to change.
            guard let place = fetched else {
                return Result(reconcileID: nil, failed: false)
            }

            let oldLocation = CLLocation(latitude: place.latitude, longitude: place.longitude)
            let newLocation = CLLocation(latitude: payload.latitude, longitude: payload.longitude)
            let distance = oldLocation.distance(from: newLocation)

            if distance > 500 {
                // Significant move: end the old record, create a new version so
                // the old coordinates still classify historical stays.
                place.endedAt = payload.now

                let newPlace = RoutinePlace(
                    label: payload.label,
                    latitude: payload.latitude,
                    longitude: payload.longitude,
                    radiusMeters: payload.radiusMeters,
                    startedAt: payload.now
                )
                context.insert(newPlace)
            } else {
                // Minor edit — update in place. Coverage changes reconcile;
                // a label-only edit does not.
                let coverageChanged = HomeSaveDecision.coverageChanged(
                    oldLatitude: place.latitude, oldLongitude: place.longitude,
                    oldRadiusKm: place.radiusMeters / 1000.0,
                    newLatitude: payload.latitude, newLongitude: payload.longitude,
                    newRadiusKm: payload.radiusMeters / 1000.0
                )
                place.label = payload.label
                place.latitude = payload.latitude
                place.longitude = payload.longitude
                place.radiusMeters = payload.radiusMeters
                if coverageChanged { reconcileID = place.id }
            }
        }

        // Queued before the save, as for Homes.
        let staged = reconcileID.map {
            CoverageReconciliationQueue.stage(.routinePlace, id: $0, defaults: pendingDefaults)
        }
        do {
            try save(context)
            return Result(reconcileID: reconcileID, failed: false,
                          pendingReconciliation: staged?.entry)
        } catch {
            // The app reuses its main ModelContext. Leaving failed edits
            // pending lets an unrelated later save commit them, while a
            // non-nil ID would also launch reconciliation against data that
            // never persisted.
            context.rollback()
            // Withdraw only this edit, restoring an earlier committed
            // edit's owed reconciliation of the same place.
            if let staged {
                CoverageReconciliationQueue.withdraw(staged, defaults: pendingDefaults)
            }
            return .failure
        }
    }
}
