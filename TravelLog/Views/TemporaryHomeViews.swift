//
//  TemporaryHomeViews.swift
//  TravelLog
//
//  The Settings section that lists temporary homes, the add/edit sheet, and
//  the gated write path they share.
//

import SwiftUI
import SwiftData
import Combine
import CoreLocation
import WidgetKit
import os.log

let temporaryHomeLogger = Logger(
    subsystem: "com.travellog.app", category: "TemporaryHomeViews")

// MARK: - Settings section

/// The Temporary Homes section of Settings. Owns its query and its sheet so
/// `SettingsView` only places it.
struct TemporaryHomesSettingsSection: View {
    @Query(sort: \TemporaryHome.startedAt, order: .reverse) private var allRows: [TemporaryHome]
    @State private var sheetMode: TemporaryHomeFormSheet.Mode?
    /// Removed temporary homes whose trips are still owed an update here.
    @State private var pendingRemovals: [PendingRemoval] = []

    /// A removed temporary home whose reconciliation is still owed on this
    /// device: its card is gone, so its status and Try Again live here.
    nonisolated struct PendingRemoval: Identifiable, Equatable, Sendable {
        let id: UUID
        let title: String
        let status: CoverageReconciliationQueue.TemporaryHomeStatus
    }

    /// One row per id (same-id twins read as one), newest first.
    private var rows: [TemporaryHome] {
        HomeAnchors.collapsingTwins(allRows.filter { !$0.isDeleted }).reversed()
    }

    var body: some View {
        Section {
            ForEach(rows) { row in
                Button {
                    sheetMode = .edit(id: row.id)
                } label: {
                    TemporaryHomeRow(temporaryHome: row)
                }
                .tint(.primary)
            }

            ForEach(pendingRemovals) { removal in
                VStack(alignment: .leading, spacing: 4) {
                    Text(removal.title)
                        .font(.subheadline.bold())
                    TemporaryHomeUpdatingLine(status: removal.status) { retry(removal.id) }
                }
                .padding(.vertical, 2)
            }

            // The sheet hangs off one row: a modifier on the Section would apply to every row.
            Button(String(
                localized: "settings.temporary-homes.add",
                defaultValue: "Add Temporary Home",
                comment: "Settings button that opens the form for a new temporary home."
            )) {
                sheetMode = .add(prefill: nil)
            }
            .sheet(item: $sheetMode) { mode in
                TemporaryHomeFormSheet(mode: mode)
            }
            // The queue is device-local: read it again whenever the rows
            // change, and when a drain records a failure or a deferral.
            .task(id: StoreChangeTracker.shared.token(for: [.temporaryHome])) {
                readPendingRemovals()
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .receive(on: RunLoop.main)) { _ in
                readPendingRemovals()
            }
        } header: {
            Text(String(
                localized: "settings.temporary-homes.header",
                defaultValue: "Temporary Homes",
                comment: "Header of the Settings section listing temporary homes."
            ))
        } footer: {
            Text(String(
                localized: "settings.temporary-homes.footer",
                defaultValue: "A place you're living in for a while, like a semester abroad. Trips away from it end when you come back to it, and your home keeps working as usual.",
                comment: "Footer of the Settings section listing temporary homes."
            ))
        }
    }

    private func readPendingRemovals() {
        let read = Self.pendingRemovals(allRows.filter { !$0.isDeleted }) {
            CoverageReconciliationQueue.temporaryHomeStatus(id: $0)
        }
        if read != pendingRemovals { pendingRemovals = read }
    }

    /// Try Again: updating at once, then whatever the drain left.
    private func retry(_ id: UUID) {
        pendingRemovals = pendingRemovals.map {
            $0.id == id ? PendingRemoval(id: id, title: $0.title, status: .updating) : $0
        }
        Task {
            await CoverageReconciliationQueue.retryTemporaryHome(id: id)
            readPendingRemovals()
        }
    }

    /// The removed ids among `rows` whose reconciliation `status` still owes,
    /// newest first, named by their removed row; an id goes once its status is nil.
    static func pendingRemovals(
        _ rows: [TemporaryHome],
        status: (UUID) -> CoverageReconciliationQueue.TemporaryHomeStatus?
    ) -> [PendingRemoval] {
        HomeAnchors.removedTwins(rows).reversed().compactMap { row in
            status(row.id).map { PendingRemoval(id: row.id, title: row.displayLabel(), status: $0) }
        }
    }

    /// "Since 13 Sep 2027", "13 Sep 2027 to 10 Feb 2028" or "Starts 13 Sep 2027".
    /// The days are read in the zone they were chosen in, so another device
    /// zone never shows the neighbouring day.
    static func dateLine(
        startedAt: Date, endedAt: Date?, timeZoneIdentifier: String?, now: Date,
        locale: Locale = AppLanguagePreference.currentLocale()
    ) -> String {
        let zone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
        let style = Date.FormatStyle(
            date: .abbreviated, time: .omitted, locale: locale, timeZone: zone)
        let start = startedAt.formatted(style)
        if let endedAt {
            let end = endedAt.formatted(style)
            return String(
                localized: "temporary-home.dates.range",
                defaultValue: "\(start) to \(end)",
                comment: "Date line of a temporary home with a set end: start date, then end date."
            )
        }
        if startedAt > now {
            return String(
                localized: "temporary-home.dates.starts",
                defaultValue: "Starts \(start)",
                comment: "Date line of an open-ended temporary home whose start date is still ahead."
            )
        }
        return String(
            localized: "temporary-home.dates.since",
            defaultValue: "Since \(start)",
            comment: "Date line of an open-ended temporary home that has started."
        )
    }
}

private struct TemporaryHomeRow: View {
    let temporaryHome: TemporaryHome

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(temporaryHome.displayLabel())
                    .font(.subheadline.bold())
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let locality = temporaryHome.locality,
               let country = localizedCountryName(
                   iso: temporaryHome.isoCountryCode,
                   fallback: temporaryHome.country
               ) {
                Text("\(locality), \(country)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let country = localizedCountryName(
                iso: temporaryHome.isoCountryCode,
                fallback: temporaryHome.country
            ) {
                Text(country)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(TemporaryHomesSettingsSection.dateLine(
                startedAt: temporaryHome.startedAt,
                endedAt: temporaryHome.endedAt,
                timeZoneIdentifier: temporaryHome.timeZoneIdentifier,
                now: .now))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Temporary Home Form Sheet (Add, Edit & End)

/// Unified form for declaring, editing, ending and removing a temporary home.
struct TemporaryHomeFormSheet: View {
    /// What a caller already knows when it opens the form for a new temporary home.
    nonisolated struct Prefill: Sendable {
        var name: String?
        var coordinate: CLLocationCoordinate2D?
        /// Any instant of the first day; the form reads the day in the device zone.
        var since: Date?
        /// Any instant of the last day. Nil leaves the end open.
        var until: Date?
    }

    nonisolated enum Mode: Identifiable, Sendable {
        case add(prefill: Prefill?)
        /// The row's id, never the row: it can be removed while the sheet is open.
        case edit(id: UUID)
        /// The edit form with "Set an End Date" turned off once the stored
        /// dates are in: Save removes the end unless the user sets one again.
        case extend(id: UUID)
        /// Only the last day and what ending on it changes; the place and the
        /// start stay the stored ones. `suggested` is any instant of the day to
        /// preset, read in the stored zone; nil presets today.
        case end(id: UUID, suggested: Date?)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let id): id.uuidString
            case .extend(let id): "extend-\(id.uuidString)"
            case .end(let id, _): "end-\(id.uuidString)"
            }
        }
    }

    /// The inputs a preview is computed for. `changes` is the store's change
    /// token for the tables it reads, so any write there asks for a new review;
    /// `favorites` is `favoritesFingerprint` of the favourites it holds, which
    /// sync apart from the store.
    nonisolated struct PreviewKey: Equatable, Sendable {
        let latitude: Double
        let longitude: Double
        let startedAt: Date
        let endedAt: Date?
        let changes: Int
        let favorites: Int
    }

    /// What the removal's lines were read against: the store's change token
    /// and `favoritesFingerprint` of the favourites the read held.
    nonisolated struct RemovalKey: Equatable, Sendable {
        let changes: Int
        let favorites: Int
    }

    /// Where the review of what a save changes stands, for the inputs on screen.
    nonisolated enum Review: Equatable, Sendable {
        /// No place yet, or the end before the start: nothing to review.
        case none
        /// The preview for these inputs is still reading.
        case checking
        /// The preview for these inputs could not read the store: nothing
        /// that changes history commits until a retry succeeds.
        case failed
        case ready
    }

    /// The store changes that re-run the review: stays, trips and temporary homes.
    nonisolated static let reviewedChanges: StoreChange = [.stay, .trip, .temporaryHome]

    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State var label: String
    @State var selectedCoordinate: CLLocationCoordinate2D?
    @State var since: Date
    @State var hasEnd: Bool
    @State var until: Date
    /// The zone the picked days are read in: the place's own once it is known,
    /// until then the stored zone on edit and the device zone for a new one.
    @State var zone: TimeZone = .current
    /// True once MapKit named the zone of the chosen coordinate.
    @State var zoneIsFromPlace = false
    /// The zone to fall back to when the place changes: the device's for a new one, the stored one on edit.
    @State var baseZone: TimeZone = .current
    /// On edit, the stored pin when the row stores a zone for it. At that pin
    /// only MapKit's answer replaces the stored zone; stays recorded there do not.
    @State var placeWithStoredZone: PlaceKey?
    /// True while `since` (`until`) still holds an instant nobody picked as a
    /// day: now, a trip's first stay, the arrival the user took. Its day is
    /// the instant's own day at the place, whatever zone the form started in.
    @State var sinceIsInstant = true
    @State var untilIsInstant = true
    /// Legacy fallback circle; never edited here, only carried into the preview draft.
    @State var radiusKm = 25.0
    @State private var didSeedFromStore = false
    /// End mode: the stored start, which the preview keeps as it is, and the
    /// place the sheet names instead of editing it.
    @State var storedStart: Date?
    @State private var endPlace: (title: String, detail: String?)?
    /// The id a new temporary home previews under; an edit previews under its own.
    @State var newDraftID = UUID()
    @State private var showMapPicker = false
    @State private var isSaving = false
    @State private var saveFailed = false
    @State private var pendingUnmappedSave: TemporaryHomeSavePayload?
    /// The inputs `pendingUnmappedSave` was reviewed for.
    @State private var pendingUnmappedKey: PreviewKey?
    @State private var showUnmappedConfirmation = false
    @State private var showRemoveConfirmation = false
    @State private var showSaveConfirmation = false
    /// The inputs the save confirmation was raised for.
    @State private var confirmedKey: PreviewKey?
    /// What removing would change, read when Remove is tapped and shown in its confirmation.
    @State var removalLines: [String] = []
    /// The trips that removal keeps, which the removal marks with it.
    @State var removalKeptTripIDs: [UUID] = []
    /// The store's change token and favourites when the removal lines were
    /// read: a later write or synced favourite reads them again before
    /// anything is removed.
    @State var removalKey: RemovalKey?
    /// The removal's own preview failed: Remove waits for a retry that succeeds.
    @State private var removalCheckFailed = false
    @State private var isLoadingRemoval = false
    @State var preview: TripClassifier.TemporaryHomeChangePreview?
    /// The inputs `preview` was computed for. Differs from `previewKey` while a preview runs.
    @State var previewedKey: PreviewKey?

    /// Edit and Extend: the form of a stored temporary home.
    private var isEditing: Bool {
        editedID != nil
    }

    /// The id Edit and Extend save over.
    var editedID: UUID? {
        switch mode {
        case .edit(let id), .extend(let id): id
        case .add, .end: nil
        }
    }

    var isEnding: Bool {
        if case .end = mode { return true }
        return false
    }

    init(mode: Mode) {
        self.mode = mode

        var prefill: Prefill?
        if case .add(let given) = mode { prefill = given }
        // Today unless the caller knows the first day; never a guess from history.
        let since = prefill?.since ?? .now
        _label = State(initialValue: prefill?.name ?? "")
        _selectedCoordinate = State(initialValue: prefill?.coordinate)
        _since = State(initialValue: since)
        _hasEnd = State(initialValue: prefill?.until != nil)
        _until = State(initialValue: max(prefill?.until ?? since, since))
    }

    var body: some View {
        NavigationStack {
            form
                .confirmationDialog(
                    String(
                        localized: "temporary-home.remove.confirmation.title",
                        defaultValue: "Remove this temporary home?",
                        comment: "Title of the confirmation shown before a temporary home is removed."
                    ),
                    isPresented: $showRemoveConfirmation,
                    titleVisibility: .visible
                ) {
                    // Lines read before a later write confirm nothing: read them again.
                    Button("Remove", role: .destructive) {
                        if Self.removalCommits(reviewed: removalKey, current: currentRemovalKey) {
                            remove()
                        } else {
                            checkRemoval()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(([String(
                        localized: "temporary-home.remove.confirmation.message",
                        defaultValue: "Travel Log will rebuild this period as ordinary trips. Trips you edited stay as they are.",
                        comment: "Message of the confirmation shown before a temporary home is removed."
                    )] + removalLines).joined(separator: "\n\n"))
                }
                .alert(
                    unmappedConfirmationText,
                    isPresented: $showUnmappedConfirmation,
                    presenting: pendingUnmappedSave
                ) { payload in
                    Button("Save") {
                        pendingUnmappedSave = nil
                        // Reviewed before a later write: review again first.
                        guard pendingUnmappedKey == previewKey else {
                            isSaving = false
                            return
                        }
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
                .onAppear { seedFromStoreIfNeeded() }
                // Re-runs when the place or the dates change.
                .task(id: previewKey) { await refreshPreview() }
                .task(id: placeKey) { await resolvePlaceZone() }
        }
    }

    /// Split from `body` to stay within the type-checker's budget.
    private var form: some View {
        Form {
            if isEnding {
                endPlaceSection
                endDateSection
            } else {
                nameSection
                locationSection
                datesSection
            }
            if selectedCoordinate != nil {
                changesSection
            }
            if isEditing {
                removeSection
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else if isEnding {
                    Button(Self.endActionTitle) { requestSave() }
                        .disabled(!canCommit)
                } else {
                    Button("Save") { requestSave() }
                        .disabled(!canCommit)
                }
            }
        }
        // A save or a removal in flight reports back to this sheet.
        .interactiveDismissDisabled(isSaving)
        .confirmationDialog(
            saveConfirmationTitle,
            isPresented: $showSaveConfirmation,
            titleVisibility: .visible
        ) {
            // Lines for other instants (the place's zone arrived meanwhile) or
            // read before a later write confirm nothing, also once the preview
            // for the new inputs has landed.
            if isEnding {
                Button(Self.endActionTitle) { saveIfConfirmed() }
            } else {
                Button("Save") { saveIfConfirmed() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text((preview.map { Self.changeLines(for: $0, areaNote: false) } ?? [])
                .joined(separator: "\n\n"))
        }
    }

    private var title: String {
        switch mode {
        case .add:
            String(
                localized: "temporary-home.form.title.new",
                defaultValue: "New Temporary Home",
                comment: "Navigation title of the form that adds a temporary home.")
        case .edit, .extend:
            String(
                localized: "temporary-home.form.title.edit",
                defaultValue: "Edit Temporary Home",
                comment: "Navigation title of the form that edits a temporary home.")
        case .end:
            String(
                localized: "temporary-home.form.title.end",
                defaultValue: "End Temporary Home",
                comment: "Navigation title of the form that ends a temporary home on a chosen last day.")
        }
    }

    private var saveConfirmationTitle: String {
        isEnding
            ? String(
                localized: "temporary-home.end.confirmation.title",
                defaultValue: "End this temporary home?",
                comment: "Title of the confirmation shown before ending a temporary home when ending it changes existing trips.")
            : String(
                localized: "temporary-home.save.confirmation.title",
                defaultValue: "Save this temporary home?",
                comment: "Title of the confirmation shown before saving a temporary home when the save rebuilds existing trips.")
    }

    /// End mode's commit button, in the toolbar and in its confirmation.
    private static var endActionTitle: String {
        String(
            localized: "temporary-home.form.end",
            defaultValue: "End",
            comment: "Button that ends a temporary home on the chosen last day, in the form's toolbar and in its confirmation.")
    }

    /// Not while the preview is still reading or failed: the commit would
    /// otherwise skip the review and the confirmation the preview decides.
    private var canCommit: Bool {
        isValid && review == .ready && !isLoadingRemoval
    }

    // MARK: Sections

    private var nameSection: some View {
        Section("Name") {
            TextField(
                String(
                    localized: "temporary-home.form.name.prompt",
                    defaultValue: "Name (e.g., \"Erasmus\")",
                    comment: "Prompt of the name field in the temporary home form."
                ),
                text: $label)
        }
    }

    private var locationSection: some View {
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

            if selectedCoordinate != nil, Self.showsAreaSourceHint(for: preview) {
                HomeAreaSourcePreview(coordinate: selectedCoordinate)
            }
        }
    }

    /// The Home form's area hint fits a temporary home only inside a city
    /// boundary: its no-boundary sentence promises learning a temporary home
    /// does not do, and "What Changes" already explains the 1 km area. Hidden
    /// while there is no preview to tell.
    nonisolated static func showsAreaSourceHint(
        for preview: TripClassifier.TemporaryHomeChangePreview?
    ) -> Bool {
        preview?.areaIsCityBoundary ?? false
    }

    private var datesSection: some View {
        Section {
            DatePicker(
                String(
                    localized: "temporary-home.form.since",
                    defaultValue: "Since",
                    comment: "Label of the start date picker in the temporary home form."
                ),
                selection: sinceBinding,
                displayedComponents: .date)
                .environment(\.timeZone, zone)

            Toggle(
                String(
                    localized: "temporary-home.form.set-end-date",
                    defaultValue: "Set an End Date",
                    comment: "Toggle in the temporary home form that reveals the end date picker."
                ),
                isOn: hasEndBinding)

            if hasEnd {
                DatePicker(
                    String(
                        localized: "temporary-home.form.until",
                        defaultValue: "Until",
                        comment: "Label of the end date picker in the temporary home form."
                    ),
                    selection: untilBinding,
                    in: TemporaryHomeSaveWorker.civilDayBounds(of: since, in: zone).start...,
                    displayedComponents: .date)
                    .environment(\.timeZone, zone)
            }

            if let arrival = offeredArrival {
                Button { useArrival(arrival) } label: {
                    Text(arrivalText(arrival))
                }
            }

            if let first = shownFirstRecorded {
                Text(firstRecordedText(first))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(String(
                localized: "temporary-home.form.section.dates",
                defaultValue: "Dates",
                comment: "Header of the dates section in the temporary home form."
            ))
        } footer: {
            Text(String(
                localized: "temporary-home.form.dates.footer",
                defaultValue: "Leave the end open if you're not sure yet. You can end it later.",
                comment: "Footer of the dates section in the temporary home form."
            ))
        }
    }

    /// End mode: the temporary home being ended, named, not editable.
    private var endPlaceSection: some View {
        Section {
            if let endPlace {
                VStack(alignment: .leading, spacing: 4) {
                    Text(endPlace.title)
                        .font(.subheadline.bold())
                    if let detail = endPlace.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// End mode: the last day, in the stored zone the worker ends it in.
    private var endDateSection: some View {
        Section {
            DatePicker(
                String(
                    localized: "temporary-home.form.last-day",
                    defaultValue: "Last Day Here",
                    comment: "Label of the date picker in the form that ends a temporary home: the last day spent at the temporary home."
                ),
                selection: untilBinding,
                in: TemporaryHomeSaveWorker.civilDayBounds(
                    of: storedStart ?? since, in: zone).start...,
                displayedComponents: .date)
                .environment(\.timeZone, zone)
        }
    }

    private var changesSection: some View {
        Section {
            switch review {
            case .none:
                EmptyView()
            case .checking:
                ProgressView()
            case .failed:
                failedReviewRow { retryPreview() }
            case .ready:
                if let preview {
                    ForEach(Self.changeLines(for: preview), id: \.self) { line in
                        Text(line)
                    }
                }
            }
        } header: {
            Text(String(
                localized: "temporary-home.form.section.changes",
                defaultValue: "What Changes",
                comment: "Header of the temporary home form section that previews the effect on existing stays and trips."
            ))
        } footer: {
            if !isEnding {
                Text(String(
                    localized: "temporary-home.form.changes.footer",
                    defaultValue: "Trips away from here will end when you come back. Your home keeps working as usual.",
                    comment: "Footer of the temporary home form section that previews the effect on existing stays and trips."
                ))
            }
        }
    }

    /// The review could not read the store: say so and offer to read again.
    private func failedReviewRow(retry: @escaping () -> Void) -> some View {
        HStack {
            Text(String(
                localized: "temporary-home.form.changes.failed",
                defaultValue: "Couldn't check what changes.",
                comment: "Row in the temporary home form when the preview of what a save, an end or a removal changes could not be read. Saving stays unavailable until a retry succeeds."
            ))
            .foregroundStyle(.secondary)
            Spacer()
            Button(String(
                localized: "temporary-home.form.changes.retry",
                defaultValue: "Try Again",
                comment: "Button beside the row saying the temporary home form could not check what changes; reads the preview again."
            ), action: retry)
        }
    }

    private var removeSection: some View {
        Section {
            Button(role: .destructive) {
                checkRemoval()
            } label: {
                HStack {
                    Text(String(
                        localized: "temporary-home.form.remove",
                        defaultValue: "Remove Temporary Home",
                        comment: "Destructive button in the form that edits a temporary home."
                    ))
                    if isLoadingRemoval {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isSaving || isLoadingRemoval || review == .failed || removalCheckFailed)

            if removalCheckFailed, !isLoadingRemoval {
                failedReviewRow { checkRemoval() }
            }
        }
    }

    /// Reads what removing changes, then asks with those lines. A failed read
    /// asks nothing: Remove waits for a retry that succeeds.
    private func checkRemoval() {
        guard !isSaving, !isLoadingRemoval else { return }
        isLoadingRemoval = true
        removalCheckFailed = false
        Task {
            let checked = await refreshRemovalLines()
            isLoadingRemoval = false
            // Never over a save that started meanwhile.
            guard !isSaving else { return }
            if checked {
                showRemoveConfirmation = true
            } else {
                removalCheckFailed = true
            }
        }
    }

    /// Confirmation summary shown once a coordinate is chosen (the Home form's).
    @ViewBuilder
    private func locationSetSummary(_ coord: CLLocationCoordinate2D) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Location set", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
            Text("\(coord.latitude, specifier: "%.5f"), \(coord.longitude, specifier: "%.5f")")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Copy

    private var unmappedConfirmationText: String {
        String(
            localized: "temporary-home.unmapped.confirmation",
            defaultValue: "This location looks unmapped or at sea. Trip detection may not recognize when you come back here. Save anyway?",
            comment: "Confirmation shown before saving a temporary home whose reverse geocode found neither a locality nor an administrative area."
        )
    }

    private func firstRecordedText(_ date: Date) -> String {
        let day = date.formatted(Date.FormatStyle(
            date: .abbreviated, time: .omitted,
            locale: AppLanguagePreference.currentLocale(), timeZone: zone))
        return String(
            localized: "temporary-home.form.first-recorded",
            defaultValue: "First recorded here on \(day).",
            comment: "Caption under the date pickers of the temporary home form: the date of the earliest recorded stay in the chosen area."
        )
    }

    /// "Arrived Sep 13? Use That Date", the day read in the zone the form shows days in.
    nonisolated static func arrivalText(
        _ arrival: Date, in zone: TimeZone,
        locale: Locale = AppLanguagePreference.currentLocale()
    ) -> String {
        let day = arrival.formatted(
            Date.FormatStyle(locale: locale, timeZone: zone).day().month(.abbreviated))
        return String(
            localized: "temporary-home.form.arrival",
            defaultValue: "Arrived \(day)? Use That Date",
            comment: "Tappable row under the date pickers of the temporary home form: the day the user seems to have arrived in the chosen area, after their last time at home. Tapping it sets that day as the start date."
        )
    }

    private func arrivalText(_ arrival: Date) -> String {
        Self.arrivalText(arrival, in: zone)
    }

    /// The "What Changes" rows for a preview, each only when it has something to say.
    /// `areaNote` adds the line about a place with no city boundary; a removal has no use for it.
    static func changeLines(
        for preview: TripClassifier.TemporaryHomeChangePreview, areaNote: Bool = true
    ) -> [String] {
        var lines: [String] = []
        let stays = preview.staysJoining
        if stays > 0 {
            lines.append(stays == 1
                ? String(
                    localized: "temporary-home.form.changes.stays-joining.one",
                    defaultValue: "\(stays, format: .number.grouping(.never)) stay becomes time at this temporary home.",
                    comment: "Temporary home preview line for one existing stay that will count as time at the temporary home.")
                : String(
                    localized: "temporary-home.form.changes.stays-joining.other",
                    defaultValue: "\(stays, format: .number.grouping(.never)) stays become time at this temporary home.",
                    comment: "Temporary home preview line for multiple existing stays that will count as time at the temporary home."))
        }
        let leaving = preview.staysLeaving
        if leaving > 0 {
            lines.append(leaving == 1
                ? String(
                    localized: "temporary-home.form.changes.stays-leaving.one",
                    defaultValue: "\(leaving, format: .number.grouping(.never)) stay stops counting as time here.",
                    comment: "Temporary home preview line for one existing stay that will no longer count as time at the temporary home.")
                : String(
                    localized: "temporary-home.form.changes.stays-leaving.other",
                    defaultValue: "\(leaving, format: .number.grouping(.never)) stays stop counting as time here.",
                    comment: "Temporary home preview line for multiple existing stays that will no longer count as time at the temporary home."))
        }
        let merged = preview.tripsMerged.count
        if merged > 0 {
            let names = tripNames(preview.tripsMerged)
            lines.append(merged == 1
                ? String(
                    localized: "temporary-home.form.changes.trips-merged.one",
                    defaultValue: "\(merged, format: .number.grouping(.never)) trip will become part of a longer trip: \(names)",
                    comment: "Temporary home preview line for one existing trip that will be absorbed into a longer trip when time at the temporary home stops counting; the trip name follows the colon.")
                : String(
                    localized: "temporary-home.form.changes.trips-merged.other",
                    defaultValue: "\(merged, format: .number.grouping(.never)) trips will become part of a longer trip: \(names)",
                    comment: "Temporary home preview line for multiple existing trips that will be absorbed into a longer trip when time at the temporary home stops counting; trip names follow the colon."))
        }
        let rebuilt = preview.tripsRebuilt.count
        if rebuilt > 0 {
            let names = tripNames(preview.tripsRebuilt)
            lines.append(rebuilt == 1
                ? String(
                    localized: "temporary-home.form.changes.trips-rebuilt.one",
                    defaultValue: "\(rebuilt, format: .number.grouping(.never)) trip will be rebuilt around it: \(names)",
                    comment: "Temporary home preview line for one trip that will be rebuilt; the trip name follows the colon.")
                : String(
                    localized: "temporary-home.form.changes.trips-rebuilt.other",
                    defaultValue: "\(rebuilt, format: .number.grouping(.never)) trips will be rebuilt around it: \(names)",
                    comment: "Temporary home preview line for multiple trips that will be rebuilt; trip names follow the colon."))
        }
        let split = preview.tripsSplit.count
        if split > 0 {
            lines.append(split == 1
                ? String(
                    localized: "temporary-home.form.changes.trips-split.one",
                    defaultValue: "“\(preview.tripsSplit[0].name)” will be split into time here and trips away. A copy stays in Removed Trips on this device.",
                    comment: "Temporary home preview line for one trip the user renamed, edited or favorited that the temporary home covers. Its stays here count as time at the temporary home from now on and each outing becomes a separate trip; the trip as it was is kept, on this device only, in Removed Trips (a screen in Settings), from where the user can keep it as one trip. The placeholder is the trip's name.")
                : String(
                    localized: "temporary-home.form.changes.trips-split.other",
                    defaultValue: "\(split, format: .number.grouping(.never)) trips will be split into time here and trips away: \(tripNames(preview.tripsSplit)). Copies stay in Removed Trips on this device.",
                    comment: "Temporary home preview line for multiple trips the user renamed, edited or favorited that the temporary home covers. Their stays here count as time at the temporary home from now on and each outing becomes a separate trip; each trip as it was is kept, on this device only, in Removed Trips (a screen in Settings), from where the user can keep it as one trip. First placeholder is the count, second the trip names."))
        }
        let kept = preview.tripsKept.count
        if kept > 0 {
            let names = tripNames(preview.tripsKept)
            lines.append(kept == 1
                ? String(
                    localized: "temporary-home.form.changes.trips-kept.one",
                    defaultValue: "\(kept, format: .number.grouping(.never)) trip stays as it is: \(names)",
                    comment: "Temporary home preview line for one trip that stays exactly as it is: one the user renamed, edited, favorited or chose photos for, that a removal or shorter dates would otherwise merge with others, or one they chose to keep as one trip. The trip name follows the colon.")
                : String(
                    localized: "temporary-home.form.changes.trips-kept.other",
                    defaultValue: "\(kept, format: .number.grouping(.never)) trips stay as they are: \(names)",
                    comment: "Temporary home preview line for multiple trips that each stay exactly as they are: ones the user renamed, edited, favorited or chose photos for, that a removal or shorter dates would otherwise merge with others, or ones they chose to keep as one trip. Trip names follow the colon."))
        }
        if areaNote, !preview.areaIsCityBoundary {
            lines.append(String(
                localized: "temporary-home.form.changes.no-city-boundary",
                defaultValue: "No city boundary here, so the area starts as 1 km around the pin. If everyday places nearby show up as trips, use This Wasn't a Trip on one of them.",
                comment: "Temporary home preview line shown when the chosen location lies in no measured city boundary. This Wasn't a Trip is the name of a trip action."))
        }
        return lines
    }

    /// At most three names, then how many more.
    private static func tripNames(
        _ trips: [TripClassifier.TemporaryHomeChangePreview.TripLine]
    ) -> String {
        let shown = trips.prefix(3).map(\.name).joined(separator: ", ")
        let extra = trips.count - min(trips.count, 3)
        guard extra > 0 else { return shown }
        return extra == 1
            ? String(
                localized: "temporary-home.form.changes.names-more.one",
                defaultValue: "\(shown) and \(extra, format: .number.grouping(.never)) more",
                comment: "List of up to three trip names followed by a count of one further trip.")
            : String(
                localized: "temporary-home.form.changes.names-more.other",
                defaultValue: "\(shown) and \(extra, format: .number.grouping(.never)) more",
                comment: "List of up to three trip names followed by a count of multiple further trips.")
    }

    // MARK: Load & save

    /// Edit and end mode hold an id; the row is read once the sheet has a context.
    private func seedFromStoreIfNeeded() {
        let id: UUID
        switch mode {
        case .add: return
        case .edit(let edited), .extend(let edited): id = edited
        case .end(let ended, _): id = ended
        }
        guard !didSeedFromStore else { return }
        didSeedFromStore = true
        do {
            let rows = try modelContext.fetch(FetchDescriptor<TemporaryHome>(
                predicate: #Predicate { $0.id == id }))
            // Removed meanwhile: nothing to edit.
            guard let row = HomeAnchors.collapsingTwins(rows).first else {
                dismiss()
                return
            }
            label = row.label
            selectedCoordinate = CLLocationCoordinate2D(
                latitude: row.latitude, longitude: row.longitude)
            radiusKm = row.radiusKm
            let storedZone = row.timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
            zone = storedZone ?? .current
            baseZone = zone
            if storedZone != nil {
                placeWithStoredZone = PlaceKey(latitude: row.latitude, longitude: row.longitude)
            }
            // Stored days: they keep their labels when the place's zone is adopted.
            sinceIsInstant = false
            untilIsInstant = row.endedAt == nil
            since = row.startedAt
            hasEnd = Self.seededHasEnd(storedEnd: row.endedAt, mode: mode)
            until = row.endedAt ?? max(row.startedAt, .now)
            // After the seeding, which sets the stored end: the preset wins.
            if case .end(_, let suggested) = mode {
                storedStart = row.startedAt
                endPlace = (row.displayLabel(), Self.placeLine(of: row))
                hasEnd = true
                untilIsInstant = false
                until = max(suggested ?? .now, row.startedAt)
            }
        } catch {
            // A failed read is not absence: never offer an empty form to save over the row.
            temporaryHomeLogger.error("Temporary home form read failed: \(error.localizedDescription)")
            dismiss()
        }
    }

    /// Whether "Set an End Date" starts on once a stored row is seeded: Edit
    /// keeps the stored end, Extend turns it off (the stored day stays in
    /// the picker should the user turn it on again), End always has one.
    nonisolated static func seededHasEnd(storedEnd: Date?, mode: Mode) -> Bool {
        switch mode {
        case .add, .edit: storedEnd != nil
        case .extend: false
        case .end: true
        }
    }

    /// End mode's place line: city and country, else the country (the Settings row's).
    private static func placeLine(of row: TemporaryHome) -> String? {
        guard let country = localizedCountryName(
            iso: row.isoCountryCode, fallback: row.country) else { return nil }
        guard let locality = row.locality, !locality.isEmpty else { return country }
        return String(localized: "\(locality), \(country)")
    }

    /// Whether a save has stays to stamp or free, trips to rebuild, merge or
    /// split, or trips to keep that are not marked yet.
    nonisolated static func owesReconciliation(
        _ preview: TripClassifier.TemporaryHomeChangePreview?
    ) -> Bool {
        guard let preview else { return false }
        return preview.staysJoining > 0 || preview.staysLeaving > 0
            || !preview.tripsRebuilt.isEmpty || !preview.tripsMerged.isEmpty
            || !preview.tripsSplit.isEmpty || marksKeptTrips(preview)
    }

    /// Whether the save marks a kept trip edited that the user had not
    /// edited: from then on the trip keeps its stays as they are.
    nonisolated static func marksKeptTrips(
        _ preview: TripClassifier.TemporaryHomeChangePreview
    ) -> Bool {
        preview.tripsKept.contains { !$0.reasons.contains(.userEdited) }
    }

    /// Whether a save asks first, with the preview's own lines: it rebuilds,
    /// merges or splits trips, frees stays or keeps a trip for good.
    nonisolated static func asksBeforeSaving(
        _ preview: TripClassifier.TemporaryHomeChangePreview
    ) -> Bool {
        !preview.tripsRebuilt.isEmpty || !preview.tripsMerged.isEmpty
            || !preview.tripsSplit.isEmpty || preview.staysLeaving > 0
            || marksKeptTrips(preview)
    }

    /// The trips a save holds in its own transaction (`keptTripIDs`): the ones
    /// the preview keeps and the ones it splits. Nil holds nothing.
    nonisolated static func heldTripIDs(
        _ preview: TripClassifier.TemporaryHomeChangePreview?
    ) -> [UUID] {
        guard let preview else { return [] }
        return preview.tripsKept.map(\.id) + preview.tripsSplit.map(\.id)
    }

    /// End mode's commit: the narrow `.end` payload for the picked last day,
    /// read in the zone the form shows it in (the stored one), holding what
    /// the preview for that end keeps or splits.
    nonisolated static func endingPayload(
        _ id: UUID, lastDay: Date, in zone: TimeZone,
        preview: TripClassifier.TemporaryHomeChangePreview?, now: Date
    ) -> TemporaryHomeSavePayload {
        .ending(
            id, on: TemporaryHomeSaveWorker.civilDayBounds(of: lastDay, in: zone).end,
            now: now, keptTripIDs: heldTripIDs(preview))
    }

    /// Nothing commits without a review of the inputs on screen that
    /// succeeded; one that changes history asks first.
    private func requestSave() {
        guard review == .ready, let preview else { return }
        if Self.asksBeforeSaving(preview) {
            confirmedKey = previewKey
            showSaveConfirmation = true
        } else {
            save()
        }
    }

    private func saveIfConfirmed() {
        guard Self.confirmationCommits(
            confirmed: confirmedKey, current: previewKey, previewed: previewedKey,
            preview: preview) else { return }
        save()
    }

    private func save() {
        guard !isSaving, review == .ready,
              let coord = selectedCoordinate, datesAreValid else { return }

        let target: TemporaryHomeSavePayload.Target
        switch mode {
        case .add: target = .add
        case .edit(let id), .extend(let id): target = .edit(id)
        case .end(let id, _):
            // The narrow end: the worker refetches the winner and keeps its content.
            isSaving = true
            let payload = Self.endingPayload(
                id, lastDay: until, in: zone, preview: preview, now: .now)
            Task { await commit(payload) }
            return
        }

        isSaving = true
        let label = self.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let dates = resolvedDates
        let zoneIdentifier = zone.identifier
        // What the preview on screen says a save would do. The place and dates
        // may be unchanged and history still owe it: a trip that was kept
        // because it was a favorite is no longer one.
        let owesReconciliation = Self.owesReconciliation(preview)
        let keptTripIDs = Self.heldTripIDs(preview)
        let reviewed = previewKey

        Task {
            // Opt into one-shot MapKit fallback when offline geocoding lacks locality.
            var geocodedLocality: String?
            var adminArea: String?
            var countryName: String?
            var countryCode: String?

            if let r = await GeocodeResolver.shared.resolveWithFallback(
                latitude: coord.latitude, longitude: coord.longitude
            ) {
                // Never store the country name as the city (`Result.localityForStorage`).
                geocodedLocality = r.localityForStorage
                adminArea = r.administrativeArea
                countryName = r.country
                countryCode = r.isoCountryCode
            }

            // A write while the place was looked up asks for a new review first.
            guard reviewed == previewKey else {
                isSaving = false
                return
            }

            let payload = TemporaryHomeSavePayload(
                target: target,
                label: label,
                latitude: coord.latitude,
                longitude: coord.longitude,
                locality: geocodedLocality,
                administrativeArea: adminArea,
                country: countryName,
                isoCountryCode: countryCode,
                startedAt: dates.startedAt,
                endedAt: dates.endedAt,
                timeZoneIdentifier: zoneIdentifier,
                now: .now,
                reconcilesUnchangedCoverage: owesReconciliation,
                keptTripIDs: keptTripIDs
            )

            if HomeSaveDecision.requiresUnmappedConfirmation(
                locality: geocodedLocality,
                administrativeArea: adminArea
            ) {
                pendingUnmappedSave = payload
                pendingUnmappedKey = reviewed
                showUnmappedConfirmation = true
                return
            }

            await commit(payload)
        }
    }

    private func remove() {
        guard let id = editedID else { return }
        isSaving = true
        let keptTripIDs = removalKeptTripIDs
        Task { await commit(.removing(id, keptTripIDs: keptTripIDs)) }
    }

    private func commit(_ payload: TemporaryHomeSavePayload) async {
        guard await TemporaryHomeSaveWorker.commit(payload) else {
            isSaving = false
            saveFailed = true
            return
        }
        // The reconciliation runs on in the background, like a Home change.
        isSaving = false
        dismiss()
    }
}

