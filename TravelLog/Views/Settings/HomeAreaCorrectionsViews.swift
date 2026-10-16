//
//  HomeAreaCorrectionsViews.swift
//  TravelLog
//
//  Home-area correction surfaces:
//
//  - `NearHomeActivityView` lists the confidence gate's suppressed
//    near-home excursions (tripless residue, invisible everywhere else) with
//    a "Log as a Trip" action. This is the user's repair channel for the
//    documented absorbing state: without it, a suppressed group could never
//    become a trip again.
//  - `HomeAreaPlacesView` — the transparency list: what defines the home
//    area (measured city boundary or radius), which places the user taught
//    in ("this wasn't a trip"), which they excluded. Learned orbit places
//    are included.
//
//  Both views render VALUE SNAPSHOTS (SuppressedGroup / OverrideRow) — never
//  live @Model rows across awaits (the deleted-model discipline). Mutations
//  run inside PipelineGate units, then re-fetch.
//

import SwiftUI
import SwiftData
import CoreLocation
import WidgetKit

// MARK: - Near-home activity

struct NearHomeActivityView: View {

    @State private var groups: [TripClassifier.SuppressedGroup] = []
    @State private var removedTrips: [DissolvedTripRecord] = []
    @State private var hasLoaded = false
    @State private var workingGroupID: UUID?
    @State private var restoreFailedMessage: String?
    @State private var forgetFailed = false
    /// The copy whose Forget Copy waits for its confirmation.
    @State private var forgetCandidate: DissolvedTripRecord?
    /// What Keep as One Trip did, for a split record's row.
    @State private var keepAlert: KeepAsOneTripAlert?

    var body: some View {
        List {
            if hasLoaded && groups.isEmpty && removedTrips.isEmpty {
                ContentUnavailableView(
                    "Nothing Here",
                    systemImage: "house",
                    description: Text("Short outings near home aren't logged as trips. When Travel Log sets one aside, it appears here so you can decide."))
            } else {
                if !groups.isEmpty {
                    Section {
                        ForEach(groups) { group in
                            row(for: group)
                        }
                    } footer: {
                        Text("These outings stayed near home, so Travel Log didn't log them as trips. Logging one marks it as a trip permanently.")
                    }
                }
                if !removedTrips.isEmpty {
                    Section {
                        ForEach(removedTrips) { record in
                            removedRow(for: record)
                        }
                    } header: {
                        Text("Removed Trips")
                    } footer: {
                        Text(String(
                            localized: "home-area.removed-trips.footer",
                            defaultValue: "These copies were saved when trips became part of a home area or were split by a temporary home. Restore or Keep as One Trip brings one back, and Keep as One Trip also stops that temporary home from splitting it again. Swipe to forget a copy.",
                            comment: "Footer of the Removed Trips section in Near-Home Activity. The rows are device-local copies of trips Travel Log removed when their places became part of the user's home area, or split when a temporary home covered them. Restore and Keep as One Trip are the names of the rows' buttons; a trip kept as one trip is not split by that temporary home again."))
                    }
                }
            }
        }
        .alert(keepAlert?.title ?? "", isPresented: Binding(
            get: { keepAlert != nil },
            set: { if !$0 { keepAlert = nil } }
        ), presenting: keepAlert) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            if let message = alert.message {
                Text(message)
            }
        }
        .confirmationDialog(
            forgetCandidate.map(Self.forgetTitle) ?? "",
            isPresented: Binding(
                get: { forgetCandidate != nil },
                set: { if !$0 { forgetCandidate = nil } }),
            titleVisibility: .visible,
            presenting: forgetCandidate
        ) { record in
            Button(Self.forgetCopyTitle, role: .destructive) { forget(record) }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text(Self.forgetMessage(for: record))
        }
        .headerProminence(.increased)
        .navigationTitle("Near-Home Activity")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .alert(forgetFailed
               ? String(
                   localized: "common.save-error.try-again",
                   defaultValue: "Couldn't save. Try again",
                   comment: "Shared alert title after a user-authoritative save fails.")
               : String(localized: "Couldn't Restore"),
               isPresented: Binding(
                   get: { forgetFailed || restoreFailedMessage != nil },
                   set: {
                       if !$0 {
                           restoreFailedMessage = nil
                           forgetFailed = false
                       }
                   })) {
            Button("OK", role: .cancel) {}
        } message: {
            if !forgetFailed {
                Text(restoreFailedMessage ?? "")
            }
        }
    }

    private func removedRow(for record: DissolvedTripRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.displayName(
                    languageTag: AppLanguagePreference.currentTag()))
                    .font(.headline)
                Text(Self.removedDateLine(for: record))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                restore(record)
            } label: {
                if workingGroupID == record.id {
                    ProgressView().controlSize(.small)
                } else if record.isSplitRecord {
                    // A temporary home split it: putting it back is Keep as One Trip.
                    Text(KeepAsOneTripAlert.actionTitle)
                        .font(.callout.weight(.medium))
                        .accessibilityLabel(KeepAsOneTripAlert.accessibilityLabel(
                            tripName: record.displayName(languageTag: AppLanguagePreference.currentTag())))
                } else {
                    Text("Restore")
                        .font(.callout.weight(.medium))
                }
            }
            .buttonStyle(.bordered)
            .disabled(workingGroupID != nil)
        }
        .padding(.vertical, 2)
        .swipeActions {
            // Asks first, so no destructive role: that role takes the row away at once.
            Button {
                forgetCandidate = record
            } label: {
                Label(Self.forgetCopyTitle, systemImage: "trash")
            }
            .tint(.red)
        }
    }

    /// Forget Copy, once confirmed: the saved copy goes, and with it Restore
    /// or Keep as One Trip for that trip.
    private func forget(_ record: DissolvedTripRecord) {
        Task {
            var failed = false
            do {
                try DissolvedTripQueue.remove(ids: [record.id])
            } catch {
                failed = true
                forgetFailed = true
            }
            await reload()
            // The queue's best-effort UI read may also fail. Keep the
            // recovery record visible when Forget did not succeed.
            if failed && !removedTrips.contains(where: { $0.id == record.id }) {
                removedTrips.append(record)
            }
        }
    }

    /// The swipe action on a saved copy and its confirmation's button.
    static var forgetCopyTitle: String {
        String(
            localized: "home-area.removed-trips.forget-copy",
            defaultValue: "Forget Copy",
            comment: "Swipe action on a row in Removed Trips, and the destructive button of its confirmation: deletes the device-local copy of a removed or split trip.")
    }

    static func forgetTitle(_ record: DissolvedTripRecord) -> String {
        let name = record.displayName(languageTag: AppLanguagePreference.currentTag())
        return String(
            localized: "home-area.removed-trips.forget.title",
            defaultValue: "Forget the saved copy of “\(name)”?",
            comment: "Title of the confirmation before a device-local copy in Removed Trips is deleted; the placeholder is the trip's name.")
    }

    /// What forgetting takes away: Keep as One Trip for a split trip, Restore for any other.
    static func forgetMessage(for record: DissolvedTripRecord) -> String {
        record.isSplitRecord
            ? String(
                localized: "home-area.removed-trips.forget.message",
                defaultValue: "You won't be able to use Keep as One Trip for it.",
                comment: "Message of the confirmation before the device-local copy of a trip a temporary home split is deleted from Removed Trips. Keep as One Trip is the name of the row's button.")
            : String(
                localized: "home-area.removed-trips.forget.message.restore",
                defaultValue: "You won't be able to restore it.",
                comment: "Message of the confirmation before the device-local copy of a trip removed when its places became part of the home area is deleted from Removed Trips; Restore is the row's button.")
    }

    /// Its day, or its days, as the review row and a temporary home's split
    /// trips show them.
    static func removedDateLine(for record: DissolvedTripRecord) -> String {
        guard let end = record.endDate,
              !Calendar.current.isDate(record.startDate, inSameDayAs: end) else {
            return record.startDate.formatted(date: .abbreviated, time: .omitted)
        }
        return (record.startDate..<end).formatted(
            Date.IntervalFormatStyle(date: .abbreviated, time: .omitted)
        )
    }

    /// Manual restore affirms "this was a trip": the stays retain that
    /// decision, so no future heal can dissolve the trip again.
    /// Failure handling is outcome-specific: a
    /// trip that's already back needs no scary alert; claimed stays are a
    /// permanent refusal (prune + honest message); MISSING stays may just
    /// not have hydrated yet on a restored device — the record stays, the
    /// message says so, and swipe-Forget remains the user's out.
    private func restore(_ record: DissolvedTripRecord) {
        guard !record.isSplitRecord else {
            keepWhole(record)
            return
        }
        workingGroupID = record.id
        Task {
            let outcome = await PipelineGate.shared.runReturning(touching: [.stay, .trip, .hiddenPhoto, .pinnedPhoto]) {
                await AppDelegate.tripClassifier.restoreDissolvedTrip(
                    record, markStaysSacred: true)
            }
            switch outcome {
            case .restored:
                try? DissolvedTripQueue.remove(ids: [record.id])
                StoreChangeTracker.shared.bump([.stay, .trip, .hiddenPhoto, .pinnedPhoto])
                WidgetCenter.shared.reloadAllTimelines()
            case .alreadyExists:
                // It came back by another route (auto-rescue, another
                // device, undo) while this list was open, and restore
                // committed any photo rows only this record held — prune.
                try? DissolvedTripQueue.remove(ids: [record.id])
                if record.carriesPhotoAnnotations {
                    PhotoService.shared.invalidateCache(for: record.id)
                }
            case .staysClaimed:
                let title = record.displayName(
                    languageTag: AppLanguagePreference.currentTag())
                restoreFailedMessage = String(
                    localized: "home-area.removed-trip.restore-error.stays-claimed",
                    defaultValue: "“\(title)” can't be restored. Its stays now belong to another trip.",
                    comment: "Error when a removed trip cannot be restored because its stays belong to another trip."
                )
            case .staysMissing:
                let title = record.displayName(
                    languageTag: AppLanguagePreference.currentTag())
                restoreFailedMessage = String(
                    localized: "home-area.removed-trip.restore-error.stays-missing",
                    defaultValue: "“\(title)” can't be restored right now. Its location history isn't on this device. If iCloud is still syncing, try again later, or swipe to forget it.",
                    comment: "Error when a removed trip cannot be restored because its location history is unavailable locally."
                )
            case .staysAmbiguous:
                let title = record.displayName(
                    languageTag: AppLanguagePreference.currentTag())
                restoreFailedMessage = String(
                    localized: "home-area.removed-trip.restore-error.stays-missing",
                    defaultValue: "“\(title)” can't be restored right now. Its location history isn't on this device. If iCloud is still syncing, try again later, or swipe to forget it.",
                    comment: "Error when a removed trip cannot be restored because its location history is unavailable locally."
                )
            case .saveFailed:
                // A transient persistence failure keeps the queue record. Use
                // the existing retry-oriented localized surface rather than
                // deleting the user's only recovery path.
                let title = record.displayName(
                    languageTag: AppLanguagePreference.currentTag())
                restoreFailedMessage = String(
                    localized: "home-area.removed-trip.restore-error.stays-missing",
                    defaultValue: "“\(title)” can't be restored right now. Its location history isn't on this device. If iCloud is still syncing, try again later, or swipe to forget it.",
                    comment: "Error when a removed trip cannot be restored because its location history is unavailable locally."
                )
            }
            await reload()
            workingGroupID = nil
        }
    }

    /// Restore of a trip a temporary home split: Keep as One Trip, which pins
    /// its favourite again and removes the record once it commits. Work done
    /// on the pieces since the split blocks it and is named.
    private func keepWhole(_ record: DissolvedTripRecord) {
        workingGroupID = record.id
        Task {
            let outcome = await HomeAreaHealing.keepSplitTrip(record)
            keepAlert = KeepAsOneTripAlert(
                outcome: outcome,
                tripName: record.displayName(languageTag: AppLanguagePreference.currentTag()))
            await reload()
            workingGroupID = nil
        }
    }

    private func row(for group: TripClassifier.SuppressedGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.placeName ?? String(
                        localized: "home-area.nearby-activity.place.unknown",
                        defaultValue: "Unknown place",
                        comment: "Fallback place name for suppressed near-home activity."
                    ))
                        .font(.headline)
                    Text(dateLine(for: group))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    logAsTrip(group)
                } label: {
                    if workingGroupID == group.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Log as a Trip")
                            .font(.callout.weight(.medium))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(workingGroupID != nil)
            }
            Text(String(localized: "home-area.nearby-activity.distance-dwell", defaultValue: "\(UnitsFormatter.formatDistance(kilometers: group.maxDistanceKm)) away · \(dwellText(group.dwellHours)) there", comment: "Near-home activity row caption. First placeholder is a formatted distance with its unit (km, mi, m or ft); second is how long the user stayed."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func dateLine(for group: TripClassifier.SuppressedGroup) -> String {
        let calendar = Calendar.current
        if calendar.isDate(group.start, inSameDayAs: group.end) {
            return group.start.formatted(date: .abbreviated, time: .omitted)
        }
        return (group.start..<group.end).formatted(
            Date.IntervalFormatStyle(date: .abbreviated, time: .omitted)
        )
    }

    private func dwellText(_ hours: Double) -> String {
        let duration = Duration.seconds(hours * 60 * 60)
        if hours < 1 {
            return duration.formatted(.units(
                allowed: [.minutes],
                width: .abbreviated,
                maximumUnitCount: 1,
                fractionalPart: .hide(rounded: .toNearestOrAwayFromZero)
            ))
        }
        return duration.formatted(.units(
            allowed: [.hours],
            width: .abbreviated,
            maximumUnitCount: 1,
            fractionalPart: .init(
                lengthLimits: 0...1,
                roundingRule: .toNearestOrAwayFromZero
            )
        ))
    }

    private func reload() async {
        groups = await AppDelegate.tripClassifier.suppressedGroups()
        // File read off-main; then prune records whose trip is PRESENT in
        // the store — after an undo or a cross-device restore, the trip is
        // back but the record lingers, and the list would show a "removed"
        // trip that is sitting in Past Trips.
        let records = await Task.detached(priority: .userInitiated) {
            DissolvedTripQueue.load()
        }.value
        guard !records.isEmpty else {
            removedTrips = []
            hasLoaded = true
            return
        }
        let context = ModelContext(AppDelegate.modelContainer)
        let recordIDs = records.map(\.id)
        // A trip is back only whole: a row without stays, or one still lacking
        // unassigned recorded stays (their Stay records are in flight or were
        // unlinked), keeps the record so Restore can reattach them.
        let returned = (try? context.fetch(FetchDescriptor<Trip>(
            predicate: #Predicate { recordIDs.contains($0.id) }))) ?? []
        let returnedByID = Dictionary(grouping: returned, by: \.id)
        // A split archive is never pruned as returned: Keep as One Trip or
        // Forget is the only way out.
        let candidates = records.filter { record in
            !record.isSplitRecord
                && returnedByID[record.id]?.contains(where: { !($0.stays ?? []).isEmpty }) == true
        }
        let recordedStayIDs = candidates.flatMap { $0.stays.map(\.id) }
        // A failed read proves nothing: keep those records.
        let recordedStays: [Stay]? = recordedStayIDs.isEmpty ? [] : (try? context.fetch(
            FetchDescriptor<Stay>(predicate: #Predicate { recordedStayIDs.contains($0.id) })))
        let existingIDs = Set(candidates.filter { record in
            recordedStays.map {
                TripClassifier.returnedTripIsWhole(
                    record, rows: returnedByID[record.id] ?? [], stays: $0)
            } ?? false
        }.map(\.id))
        let stale = records.filter { existingIDs.contains($0.id) }
        removedTrips = records.filter { !existingIDs.contains($0.id) }
        hasLoaded = true
        // A record may hold the only copy of its trip's hidden and pinned
        // photos (trip demotion deleted the rows). When the trip came back
        // without them (sync, import), commit them before pruning.
        var prunable = Set(stale.filter { !$0.carriesPhotoAnnotations }.map(\.id))
        let carrying = stale.filter(\.carriesPhotoAnnotations)
        if !carrying.isEmpty {
            let settled = await PipelineGate.shared.runReturning(
                touching: [.hiddenPhoto, .pinnedPhoto]
            ) {
                await AppDelegate.tripClassifier
                    .settleReturnedDissolvedTrips(carrying)
            }
            for id in settled { PhotoService.shared.invalidateCache(for: id) }
            prunable.formUnion(settled)
        }
        if !prunable.isEmpty {
            // A heal or demotion persists its record before its deleting save,
            // so the reads above can see a trip that unit is about to delete.
            // Under the gate that save has either committed or not started.
            let recheck = stale.filter { prunable.contains($0.id) }
            await PipelineGate.shared.run(touching: []) {
                await Self.removeRecordsOfWholeReturnedTrips(recheck)
            }
        }
    }

    /// Prunes only records whose trip is still back whole in the committed
    /// store; a failed read keeps them all.
    private static func removeRecordsOfWholeReturnedTrips(_ records: [DissolvedTripRecord]) {
        let context = ModelContext(AppDelegate.modelContainer)
        let ids = records.map(\.id)
        let stayIDs = records.flatMap { $0.stays.map(\.id) }
        guard let rows = try? context.fetch(FetchDescriptor<Trip>(
                  predicate: #Predicate { ids.contains($0.id) })),
              let stays = try? context.fetch(FetchDescriptor<Stay>(
                  predicate: #Predicate { stayIDs.contains($0.id) })) else { return }
        let rowsByID = Dictionary(grouping: rows, by: \.id)
        let whole = Set(records.filter {
            TripClassifier.returnedTripIsWhole($0, rows: rowsByID[$0.id] ?? [], stays: stays)
        }.map(\.id))
        if !whole.isEmpty {
            try? DissolvedTripQueue.remove(ids: whole)
        }
    }

    private func logAsTrip(_ group: TripClassifier.SuppressedGroup) {
        workingGroupID = group.id
        Task {
            let stamped = await PipelineGate.shared.runReturning(
                touching: [.stay, .trip]
            ) {
                await AppDelegate.tripClassifier
                    .logSuppressedGroupAsTrip(stayIDs: group.stayIDs)
            }
            if stamped > 0 {
                _ = await AppDelegate.tripClassifier.classifyAndAssembleTripsWithGates(
                    maxStaysPerCall: nil)
                _ = await AppDelegate.tripClassifier.generateTitlesStage(
                    maxTripsPerCall: nil)
                _ = await AppDelegate.tripTitleLocalizationService
                    .generateLocalizedTitlesStage(maxTripsPerCall: nil)
            }
            StoreChangeTracker.shared.bump([.stay, .trip])
            WidgetCenter.shared.reloadAllTimelines()
            await reload()
            workingGroupID = nil
        }
    }
}

// MARK: - Keep as One Trip

/// What Keep as One Trip tells the user once it ran, in Removed Trips and in
/// a temporary home's Split Trips alike: a short confirmation, what blocks
/// it, a retry later, or the shared save failure.
nonisolated struct KeepAsOneTripAlert: Equatable, Sendable {
    let title: String
    let message: String?
    /// Anything but `.kept`.
    let isFailure: Bool

    /// The button on a split trip's row.
    static var actionTitle: String {
        String(
            localized: "temporary-home.keep-as-one-trip",
            defaultValue: "Keep as One Trip",
            comment: "Button on a trip that setting up a temporary home split into time at it and trips of their own: puts it back together as the one trip it was.")
    }

    /// That button's VoiceOver label, naming the trip of its row.
    static func accessibilityLabel(tripName: String) -> String {
        String(
            localized: "temporary-home.keep-as-one-trip.accessibility-label",
            defaultValue: "Keep \(tripName) as one trip",
            comment: "VoiceOver label of the Keep as One Trip button on a row for a trip that a temporary home split; the placeholder is the trip's name.")
    }

    init(
        outcome: TripClassifier.KeepSplitOutcome, tripName: String,
        locale: Locale = AppLanguagePreference.currentLocale()
    ) {
        let cannot = String(
            localized: "temporary-home.keep-as-one-trip.failed.title",
            defaultValue: "Can't Keep as One Trip",
            comment: "Alert title when a trip a temporary home split cannot be put back together as one trip.")
        switch outcome {
        case .kept:
            title = String(
                localized: "temporary-home.keep-as-one-trip.kept.title",
                defaultValue: "Kept as One Trip",
                comment: "Alert title confirming that a trip a temporary home split is one trip again.")
            message = String(
                localized: "temporary-home.keep-as-one-trip.kept.message",
                defaultValue: "“\(tripName)” is one trip again.",
                comment: "Alert message confirming that a trip a temporary home split is one trip again; the placeholder is the trip's name.")
            isFailure = false
        case .blocked(let reasons):
            let changed = reasons.formatted(.list(type: .and).locale(locale))
            title = cannot
            message = String(
                localized: "temporary-home.keep-as-one-trip.blocked.message",
                defaultValue: "These trips or places changed since the split, so it can't be put back together: \(changed).",
                comment: "Alert message when a trip a temporary home split cannot be put back together because its pieces or stays changed since the split, by the user or by sync; the placeholder lists the trips or places that changed.")
            isFailure = true
        case .staysMissing:
            title = cannot
            message = String(
                localized: "temporary-home.keep-as-one-trip.missing.message",
                defaultValue: "Some location history for “\(tripName)” is missing on this device. If iCloud is syncing, try again later.",
                comment: "Alert message when a trip a temporary home split cannot be put back together because some of its recorded stays are not on this device: they may still be syncing from iCloud, or may be gone for good. The placeholder is the trip's name.")
            isFailure = true
        case .staysAmbiguous:
            title = cannot
            message = String(
                localized: "temporary-home.keep-as-one-trip.ambiguous.message",
                defaultValue: "The location history for “\(tripName)” has conflicting copies, so it can't be put back together yet.",
                comment: "Alert message when a trip a temporary home split cannot be put back together because some of its recorded stays exist in more than one differing copy on this device. The placeholder is the trip's name.")
            isFailure = true
        case .saveFailed:
            title = String(
                localized: "common.save-error.try-again",
                defaultValue: "Couldn't save. Try again",
                comment: "Shared alert title after a user-authoritative save fails.")
            message = nil
            isFailure = true
        }
    }
}

// MARK: - Transparency: places in the home area

struct HomeAreaPlacesView: View {

    /// Value snapshot of one taught place — the list never holds live models.
    /// A nearby Home edit copies a correction to the new Home era, so one
    /// place can own a row per era; they list once, keyed by `placeKey`, and
    /// the representative row is the current-era one when there is one.
    private struct OverrideRow: Identifiable, Sendable {
        let id: UUID
        let kind: HomeAreaOverride.Kind
        let latitude: Double
        let longitude: Double
        let homeID: UUID?
        let sourceTripName: String?
        let placeKey: String
    }

    @Query(sort: \Home.startedAt) private var homes: [Home]
    @State private var included: [OverrideRow] = []
    @State private var excluded: [OverrideRow] = []
    @State private var learned: [TripClassifier.LearnedPlace] = []
    /// Offline-geocoded display names, keyed by row/place id string
    /// (LearnedPlace ids are Strings, override rows use uuidString) — raw
    /// coordinates are unusable as a list. A resolver
    /// miss just leaves the coordinate fallback.
    @State private var placeNames: [String: String] = [:]
    @State private var working = false
    @State private var changeFailed = false

    var body: some View {
        List {
            Section {
                ForEach(homes.filter { $0.endedAt == nil }, id: \.persistentModelID) { home in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(home.displayLabel())
                            .font(.headline)
                        HomeAreaSourcePreview(coordinate: CLLocationCoordinate2D(
                            latitude: home.latitude, longitude: home.longitude))
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Home Area")
            }

            if !learned.isEmpty {
                Section {
                    ForEach(learned) { place in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(placeNames[place.id]
                                 ?? String(format: "%.3f°, %.3f°",
                                           place.latitude, place.longitude))
                            Text(learnedCaption(place))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                exclude(place)
                            } label: {
                                Label("Not Home", systemImage: "xmark.circle")
                            }
                        }
                    }
                } header: {
                    Text("Learned From Your Routine")
                } footer: {
                    Text("Places you return home from regularly: part of ordinary life, not travel. Swipe to exclude one; visits there become trips again.")
                }
            }

            if !included.isEmpty {
                Section {
                    ForEach(included) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rowTitle(row))
                                .font(.body)
                            if let source = row.sourceTripName {
                                Text("Added when you removed “\(source)”")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let era = endedHomeCaption(row) {
                                Text(era)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                remove(row)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Places You Added")
                } footer: {
                    Text(String(localized: "home-area.places-added.footer", defaultValue: "Future visits to these places count as home, not travel. Removing one also reconsiders your past visits there, so earlier trips can come back.", comment: "Footer of the Places You Added section in Home Area Places. Each row is a place the user taught as part of their home area; removing one also lets Travel Log classify the user's past visits there again."))
                }
            }

            if !excluded.isEmpty {
                Section {
                    ForEach(excluded) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rowTitle(row))
                            if let era = endedHomeCaption(row) {
                                Text(era)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                            .swipeActions {
                                Button(role: .destructive) {
                                    remove(row)
                                } label: {
                                    Label("Allow Again", systemImage: "arrow.uturn.backward")
                                }
                            }
                    }
                } header: {
                    Text("Places You Excluded")
                } footer: {
                    Text("Travel Log won't treat these as part of your home area, even when your routine suggests it.")
                }
            }
        }
        .headerProminence(.increased)
        .navigationTitle("Home Area Places")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .disabled(working)
        .alert(
            String(
                localized: "common.save-error.try-again",
                defaultValue: "Couldn't save. Try again",
                comment: "Shared alert title after a user-authoritative save fails."
            ),
            isPresented: $changeFailed
        ) {
            Button("OK", role: .cancel) {}
        }
    }

    private func rowTitle(_ row: OverrideRow) -> String {
        placeNames[row.id.uuidString]
            ?? String(format: "%.3f°, %.3f°", row.latitude, row.longitude)
    }

    /// An override scoped to an ENDED home still renders
    /// in these lists (its era's history consults it) — say so, instead of
    /// letting it read as a live rule of the current home area.
    private func endedHomeCaption(_ row: OverrideRow) -> String? {
        guard let homeID = row.homeID,
              let home = homes.first(where: { $0.id == homeID }),
              home.endedAt != nil else { return nil }
        if home.label.isEmpty {
            return String(
                localized: "home-area.ended-home-caption.default",
                defaultValue: "From a previous home, no longer your home",
                comment: "Attribution for a correction attached to a previous unnamed home."
            )
        }
        return String(
            localized: "home-area.ended-home-caption.named",
            defaultValue: "From \(home.label), no longer your home",
            comment: "Attribution for a correction attached to a named previous home."
        )
    }

    private func learnedCaption(_ place: TripClassifier.LearnedPlace) -> String {
        if let first = place.firstReturn {
            let date = first.formatted(date: .abbreviated, time: .omitted)
            if place.returnCount == 1 {
                return String(
                    localized: "home-area.learned-place.caption.with-date.one",
                    defaultValue: "\(place.returnCount, format: .number.grouping(.never)) return · since \(date)",
                    comment: "Learned home-area caption for one return, including the first return date."
                )
            }
            return String(
                localized: "home-area.learned-place.caption.with-date.other",
                defaultValue: "\(place.returnCount, format: .number.grouping(.never)) returns · since \(date)",
                comment: "Learned home-area caption for multiple returns, including the first return date."
            )
        }
        if place.returnCount == 1 {
            return String(
                localized: "home-area.learned-place.caption.one",
                defaultValue: "\(place.returnCount, format: .number.grouping(.never)) return",
                comment: "Learned home-area caption for one return with no known first-return date."
            )
        }
        return String(
            localized: "home-area.learned-place.caption.other",
            defaultValue: "\(place.returnCount, format: .number.grouping(.never)) returns",
            comment: "Learned home-area caption for multiple returns with no known first-return date."
        )
    }

    private func exclude(_ place: TripClassifier.LearnedPlace) {
        working = true
        Task {
            // `.stay` too: `excludeLearnedPlace` runs `unHomeStays`, which
            // mutates and saves Stay rows.
            let saved = await PipelineGate.shared.runReturning(touching: [.homeAreaOverride, .stay]) {
                await AppDelegate.tripClassifier.excludeLearnedPlace(place)
            }
            // A rolled-back exclusion changed nothing: skip healing and say so.
            guard saved else {
                changeFailed = true
                working = false
                return
            }
            StoreChangeTracker.shared.bump([.homeAreaOverride, .stay])
            await HomeAreaHealing.healIfNeeded()
            await reload()
            working = false
        }
    }

    private func reload() async {
        learned = await AppDelegate.tripClassifier.learnedPlaces()
        // Snapshot on main; @Query is only for the homes section.
        let context = ModelContext(AppDelegate.modelContainer)
        // A failed read keeps the last snapshot: an empty list would hide
        // rows that still exist and let a rolled-back removal look complete.
        if let fetched = try? context.fetch(FetchDescriptor<HomeAreaOverride>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])) {
            let currentHomeIDs = Set(homes.filter { $0.endedAt == nil }.map(\.id))
            var order: [String] = []
            var groups: [String: [HomeAreaOverride]] = [:]
            // Unknown kinds (a newer build's rows) are neither listed nor removable here.
            for row in fetched where row.kind != nil {
                let key = HomeAreaOverrideDeduplicator.placeKey(
                    kindRaw: row.kindRaw, latitude: row.centerLatitude,
                    longitude: row.centerLongitude)
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(row)
            }
            let rows = order.compactMap { key -> OverrideRow? in
                guard let members = groups[key],
                      let representative = members.first(where: { member in
                          member.homeID.map(currentHomeIDs.contains) ?? true
                      }) ?? members.first,
                      let kind = representative.kind else { return nil }
                return OverrideRow(
                    id: representative.id, kind: kind,
                    latitude: representative.centerLatitude,
                    longitude: representative.centerLongitude,
                    homeID: representative.homeID,
                    sourceTripName: representative.sourceTripName
                        ?? members.lazy.compactMap(\.sourceTripName).first,
                    placeKey: key)
            }
            included = rows.filter { $0.kind == .include }
            excluded = rows.filter { $0.kind == .exclude }
        }

        // Offline geocode pass: the bundled resolver
        // turns each place's coordinates into a name. Misses (open water,
        // remote areas) keep the coordinate fallback in the row.
        var names: [String: String] = [:]
        for (id, lat, lon) in learned.map({ ($0.id, $0.latitude, $0.longitude) })
            + (included + excluded).map({ ($0.id.uuidString, $0.latitude, $0.longitude) }) {
            guard let result = await GeocodeResolver.shared.resolve(
                latitude: lat, longitude: lon) else { continue }
            let name = (result.bestLocalityName != nil ? result.localityForStorage : nil)
                ?? result.metroName ?? result.islandName ?? result.administrativeArea
            if let name, !name.isEmpty { names[id] = name }
        }
        placeNames = names
    }

    private func remove(_ row: OverrideRow) {
        working = true
        Task {
            // Through the classifier, not a raw row delete: removal re-primes
            // the orbit and frees the `.home` stays the removed geometry had
            // claimed when the area shrinks, so no invisible history is
            // stranded. The healing pass then re-judges everything. One place
            // is withdrawn in every Home era it was carried to.
            let kindRaw = row.kind.rawValue
            let latitude = row.latitude
            let longitude = row.longitude
            let removed = await PipelineGate.shared.runReturning(touching: [.homeAreaOverride, .stay]) {
                await AppDelegate.tripClassifier.removeOverrides(
                    kindRaw: kindRaw, latitude: latitude, longitude: longitude)
            }
            // False covers a vanished row (synced deletion) and a rolled-back
            // removal alike: reload, and complain only if the row is still here.
            guard removed else {
                await reload()
                let stillPresent = (included + excluded).contains { $0.placeKey == row.placeKey }
                changeFailed = stillPresent
                working = false
                return
            }
            StoreChangeTracker.shared.bump([.homeAreaOverride, .stay])
            await HomeAreaHealing.healIfNeeded()
            await reload()
            working = false
        }
    }
}
