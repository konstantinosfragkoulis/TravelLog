//
//  TripDetailView.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import AppIntents
import FoundationModels
import SwiftUI
import TipKit
import SwiftData
import MapKit
import Photos
import UIKit
import WidgetKit
import os.log

/// Every value that can make the localized derivative of a trip title stale.
/// Keeping this value-only key separate from the live SwiftData model lets
/// SwiftUI cancel and restart the lazy title task when CloudKit, calendar
/// matching, or an in-place edit replaces the canonical source while the
/// detail screen remains open.
nonisolated struct TripTitleLocalizationTaskKey: Equatable {
    let tripID: UUID
    let canonicalTitle: String?
    let sourceRevision: UUID?
    let languageTag: String
    let hasCustomName: Bool
}

/// Displays the full details of a single trip.
///
/// Layout:
/// - Top: A MapKit map showing markers for each stay and a polyline connecting them.
/// - Bottom: A scrollable vertical timeline of stays with duration, category badges,
///   and location names. Destination stays are prominent; transit stays are compact.
///
/// Edit mode allows the user to reclassify individual stays (destination ↔ transit),
/// with overrides marked as `userOverridden: true` so the AI never re-classifies them.
struct TripDetailView: View {
    /// NSUserActivity type advertising the focused trip (declared in
    /// Info.plist `NSUserActivityTypes`).
    static let viewingTripActivityType = "com.kfragkoulis.TravelLog.viewing-trip"

    /// Sendable payload for the `.userActivity(_:element:_:)` update
    /// closure — the closure isn't MainActor-typed, so it can't read the
    /// `@Model` trip directly.
    struct ViewingTripActivity: Equatable {
        let id: UUID
        let name: String
    }

    @Bindable var trip: Trip
    @Environment(\.modelContext) private var modelContext

    @State var isEditing = false
    @State var editingName: String = ""
    /// A rename waiting for or holding the gate: edit mode and its draft
    /// stay until it commits.
    @State var isSavingRename = false
    @State var stayToSplitAt: Stay?
    @State var photoPresentation = TripPhotoPresentation(groups: [], pinnedIdentifiers: [])
    /// Ordering token for `loadPhotos()` — see the comment there.
    @State var photoLoadGeneration = 0
    /// True when no photo is visible but this device can show hidden ones:
    /// the Photos header then stays as the route to Hidden Photos.
    @State var hasRestorableHiddenPhotos = false
    @State var photoViewerAssetID: String?
    /// When set, the full-screen photo viewer is scoped to JUST this
    /// stay's photos (used by the timeline-row tap path). When nil
    /// (the existing top-section tap path), the viewer shows all of
    /// the trip's photos. Reset to nil whenever the viewer dismisses.
    @State var photoViewerScopeStayID: UUID?
    @State var pendingPinMutations = 0
    @State var assetPendingDelete: PHAsset?
    @State var isRegeneratingTitle = false
    @State var titleRegenFailed = false
    @State var saveFailed = false
    @AppStorage(TripSplitHint.dismissedKey) var splitHintDismissed = false
    @State var showSplitHint = false
    @Environment(\.scenePhase) private var scenePhase
    /// Read only by the suggestion task, never by the body.
    @Query var temporaryHomes: [TemporaryHome]
    /// "Living in Brussels for now?": the trip's temporary-home suggestion,
    /// reloaded by `TemporaryHomeSuggestionLoader`.
    @State var temporaryHomeSuggestion: TemporaryHomeSuggestion.Candidate?
    /// Advances on activation and at local midnight while the trip is short
    /// of the suggestion's day threshold (`nextSuggestionDayBoundary`), so a
    /// trip that crosses it while the screen stays open asks.
    @State var suggestionClockTick = 0
    /// The form "Set Up a Temporary Home…" and the suggestion's Set Up open.
    @State var temporaryHomeSheetMode: TemporaryHomeFormSheet.Mode?

    private var titleLocalizationTaskKey: TripTitleLocalizationTaskKey {
        TripTitleLocalizationTaskKey(
            tripID: trip.id,
            canonicalTitle: TripTitleStore.normalized(trip.aiGeneratedTitle),
            sourceRevision: trip.titleSourceRevision,
            languageTag: AppLanguagePreference.currentTag(),
            hasCustomName: TripTitleStore.normalized(trip.customName) != nil)
    }

    var body: some View {
        // Deleted-model guard: the bound row can be
        // hard-deleted out from under this view — Reclassify All re-mints
        // every non-user-edited trip, Delete All Data wipes the table, JSON
        // import replaces rows, and a CloudKit push can delete remotely —
        // and reading ANY property of an invalidated @Model TRAPS.
        // `isDeleted` is the one safe read (same contract as
        // TripsListView.filteringDeleted). Render a placeholder; the
        // parent's next recompute drops the navigation destination.
        if trip.isDeleted {
            ContentUnavailableView(
                "Trip Unavailable",
                systemImage: "suitcase",
                description: Text("This trip was removed or rebuilt.")
            )
        } else {
            temporaryHomeContent
        }
    }

    var detailContent: some View {
        // Sorted once per body evaluation (`trip.orderedStays` is a fresh
        // sort) and threaded into the sections that need it.
        let orderedStays = trip.orderedStays
        return ScrollView {
            VStack(spacing: 0) {
                mapSection(orderedStays)
                    .frame(height: 300)

                temporaryHomeSuggestionSection

                // The grouped-page grammar: an overview card, then headed
                // Photos and Timeline cards on the grouped background.
                headerSection
                    .appCard()
                    .padding(.horizontal, AppTheme.gutter)
                    .padding(.top, 16)

                photosSection
                    .padding(.horizontal, AppTheme.gutter)
                    .padding(.top, 24)

                timelineSection(orderedStays)
                    .padding(.horizontal, AppTheme.gutter)
                    .padding(.top, 24)
            }
            // Width clamp: scroll content is always exactly container-width,
            // so horizontal overflow is impossible even if the bound model is
            // invalidated mid-display. Every section already fills the width.
            .containerRelativeFrame(.horizontal)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(trip.displayName)
        .navigationBarTitleDisplayMode(.inline)
        // Onscreen awareness: advertise
        // the focused trip while this view is visible, so Siri can resolve
        // "this trip" / "share this" to the on-screen entity. Declared in
        // Info.plist `NSUserActivityTypes`. Sendable values are captured
        // up front — the update closure isn't MainActor-typed, so it must
        // not touch the `@Model` directly.
        .userActivity(
            Self.viewingTripActivityType,
            element: ViewingTripActivity(id: trip.id, name: trip.displayName)
        ) { viewing, activity in
            activity.title = viewing.name
            activity.appEntityIdentifier = EntityIdentifier(
                for: TripEntity.self,
                identifier: viewing.id
            )
        }
        .toolbar {
            // Favorite / unfavorite star. Toggles the trip's membership in
            // `PinnedTripsStorage` (iCloud-synced KVS, see service doc —
            // the class kept its "pinned" name to avoid migrating the KVS
            // data key; only the user-facing vocabulary is "Favorite").
            // Accent `star.fill` when favorited, plain `star` when not.
            // Hidden in edit mode so the toolbar doesn't crowd with the
            // Done button.
            //
            // Two icon buttons sharing one glass group — the fused pill is
            // wanted; what read badly was the text "Edit" fused next to an
            // icon. Editing ends with a
            // prominent Done in the confirmation slot.
            if isEditing {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveRename()
                    }
                    .disabled(isSavingRename)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    let isFavorite = PinnedTripsStorage.shared.isPinned(trip.id)
                    Button {
                        PinnedTripsStorage.shared.toggle(trip.id)
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .foregroundStyle(isFavorite ? AppTheme.accent : .primary)
                    }
                    .accessibilityLabel(isFavorite ? "Unfavorite trip" : "Favorite trip")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation {
                            editingName = trip.customName ?? ""
                            isEditing = true
                        }
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }
                // The trips list's "Set Up a Temporary Home…", reachable here
                // without a long press. A menu keeps Favorite and Edit as they
                // are and adds nothing to the page of an ordinary open trip.
                if TemporaryHomeFormSheet.Prefill.isOffered(
                    isComplete: trip.isComplete, startDate: trip.startDate, endDate: trip.endDate) {
                    ToolbarItem(placement: .topBarTrailing) {
                        moreActionsMenu
                    }
                }
            }
        }
        .alert("Split Trip?", isPresented: Binding(
            get: { stayToSplitAt != nil },
            set: { if !$0 { stayToSplitAt = nil } }
        )) {
            Button("Split", role: .destructive) {
                // `isDeleted` guard: the alert retains a live
                // Stay across user think-time — a background reclassify or
                // remote delete can invalidate it, and any other property
                // read on a deleted @Model traps.
                if let stay = stayToSplitAt, !stay.isDeleted {
                    performSplit(at: stay)
                }
                stayToSplitAt = nil
            }
            Button("Cancel", role: .cancel) { stayToSplitAt = nil }
        } message: {
            if let stay = stayToSplitAt, !stay.isDeleted {
                Text("Everything from \"\(stay.locality ?? String(localized: "trip-detail.place.unknown", defaultValue: "Unknown", comment: "Fallback place name in trip details."))\" onwards will become a separate trip.")
            }
        }
        .task {
            // The weather-enrichment WRITES are still serialized through
            // PipelineGate so they can't race a concurrent gated lane
            // (RootView scenePhase retries, TripsListView.runFullPipeline) on
            // the shared store — an ungated cross-context save can throw and
            // silently drop the OTHER lane's core Stay/Trip batch.
            //
            // Called UNGATED: the method takes the gate itself, in small
            // units, with the WeatherKit calls running BETWEEN them. Wrapping
            // it here would self-deadlock the non-reentrant gate and hold it
            // across unbounded network I/O, starving the background SLC
            // wake-ping save.
            await Self.runInitialLoad(
                for: trip,
                loadPhotos: { await loadPhotos() },
                enrich: { await AppDelegate.weatherEnricher.enrichStaysForTripGated($0) })
        }
        .task(id: titleLocalizationTaskKey) {
            // Independent priority lane: photo/weather work must not delay a
            // missing title, and title inference must not delay the gallery.
            guard !trip.isDeleted else { return }
            let tripID = trip.id
            let tripIdentifier = trip.persistentModelID
            _ = await AppDelegate.tripClassifier.ensureCanonicalTitle(
                for: tripID,
                tripIdentifier: tripIdentifier)
            _ = await AppDelegate.tripTitleLocalizationService.localizedTitle(
                for: tripID,
                tripIdentifier: tripIdentifier)
        }
        .task(id: trip.id) {
            showSplitHint = false
            guard !trip.isDeleted, !splitHintDismissed else { return }
            let stays = trip.orderedStays.map { stay in
                TripSplitHint.StaySignal(
                    startTime: stay.startTime,
                    endTime: stay.endTime,
                    isDestination: stay.category == .destination,
                    locality: stay.locality,
                    isImported: [.photoImport, .timelineImport, .gpxImport].contains(stay.source)
                )
            }
            guard TripSplitHint.isEligible(
                isComplete: trip.isComplete,
                userEdited: trip.userEdited,
                stays: stays
            ) else { return }
            // Deliberate settle delay: the card should read as a helpful notice
            // arriving after the page, not part of its furniture.
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, !trip.isDeleted else { return }
            // The ledger claim happens HERE, after the delay, as one
            // synchronous MainActor read-claim-write against UserDefaults —
            // not against the @AppStorage caches captured before the sleep.
            // That serializes concurrent scenes (two eligible trips open at
            // once can't both take the last slot) and re-validates a
            // dismissal that landed DURING the delay (e.g. the user split
            // within the settle window).
            let defaults = UserDefaults.standard
            guard !defaults.bool(forKey: TripSplitHint.dismissedKey) else { return }
            let seen = TripSplitHint.decodeSeenIDs(
                defaults.string(forKey: TripSplitHint.seenTripIDsKey) ?? "")
            let claim = TripSplitHint.claimPresentation(
                eligible: true, dismissed: false, seenIDs: seen, tripID: trip.id)
            guard claim.present else { return }
            if claim.updatedSeenIDs.count != seen.count {
                defaults.set(TripSplitHint.encodeSeenIDs(claim.updatedSeenIDs),
                             forKey: TripSplitHint.seenTripIDsKey)
            }
            withAnimation(.easeInOut(duration: 0.3)) { showSplitHint = true }
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { photoViewerAssetID != nil },
                set: {
                    if !$0 {
                        photoViewerAssetID = nil
                        photoViewerScopeStayID = nil
                    }
                }
            ),
            onDismiss: {
                // Re-fetch in case the user hid or pinned one or more photos in the viewer.
                Task { await loadPhotos() }
            }
        ) {
            if let id = photoViewerAssetID {
                PhotoViewerView(
                    assets: viewerAssets(),
                    initialAssetID: id,
                    tripID: trip.id,
                    onAssetsChanged: { _ in Task { await loadPhotos() } }
                )
            }
        }
        .alert("Hide Photo?", isPresented: Binding(
            get: { assetPendingDelete != nil },
            set: { if !$0 { assetPendingDelete = nil } }
        )) {
            Button("Hide") {
                // Stale-render tap guard: the body-level `isDeleted` check only
                // swaps content on the NEXT render, so a tap can still land on a
                // stale one after a background delete, and `trip.id` traps.
                if let asset = assetPendingDelete, !trip.isDeleted {
                    let mutation = PhotoService.shared.hidePhoto(localIdentifier: asset.localIdentifier, tripID: trip.id)
                    Task {
                        _ = await mutation.value
                        await loadPhotos()
                    }
                }
                assetPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { assetPendingDelete = nil }
        } message: {
            Text("This photo won't appear in this trip anymore. You can restore it later from Hidden Photos.")
        }
        .alert("Couldn't Generate a Title", isPresented: $titleRegenFailed) {
            Button("OK", role: .cancel) { titleRegenFailed = false }
        } message: {
            Text("A new title couldn't be generated right now. Try again in a moment.")
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
        // Catch changes that landed while we were backgrounded. Cold re-match
        // only for iCloud-sync users (CloudKit rows can arrive without a
        // push); see TripPhotosView's scenePhase handler.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            // The trip can be deleted by a background pass while this view is
            // backgrounded — precisely the window this handler fires in.
            // Reading `trip.id` on an invalidated @Model traps.
            guard !trip.isDeleted else { return }
            suggestionClockTick &+= 1
            PhotoService.shared.refreshAuthorizationStatus()
            if UserDefaults.standard.bool(forKey: AppDelegate.iCloudSyncEnabledKey) {
                PhotoService.shared.invalidateCache(for: trip.id)
            }
            Task { await loadPhotos() }
        }
        // Real-time PhotoKit reactivity (foreground): PhotoService bumps this
        // when the system library changes. The service has already wiped its
        // own caches, so loading again is fresh.
        .onChange(of: PhotoService.shared.changeToken) { _, _ in
            Task { await loadPhotos() }
        }
    }

}

