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
/// - Top: a full-bleed MapKit route map: the cobalt line through each
///   place's station, no names at rest. A tapped station names itself in a
///   callout; touching stations share a double ring that opens a chooser.
///   A pull down past the page's top (or a drag on the grabber at its foot)
///   opens it to two thirds of the page; one swipe up puts it back.
/// - Then the title card (title, flags and country, dates, the brief figures
///   and the country's passport stamp), the Photos strip, and the Stops line
///   (a metro-style rail, visits and transit on smaller stations, weather on
///   the right).
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
        /// This row's entity identity, so "this trip" never resolves to a twin.
        let id: TripEntityID
        let name: String
    }

    @Bindable var trip: Trip
    @Environment(\.modelContext) var modelContext

    @State var isEditing = false
    /// The route map's callout or chooser; one place at most is selected,
    /// on the map and on the Stops rail alike.
    @State var mapFocus: TripMapFocus?
    /// The stop row flashing after the map's callout scrolled to it.
    @State var flashedStop: PersistentIdentifier?
    /// The stop row tapped to show it on the map, tinted while the page scrolls up.
    @State var pressedStop: PersistentIdentifier?
    /// Where the page can scroll, set by the map's callout and the Stops rows.
    @State var pagePosition = ScrollPosition(edge: .top)
    /// The page and row geometry that places a stop under the navigation
    /// buttons; a reference, so its writes never redraw the page.
    @State var stopScroll = StopScrollMetrics()
    /// Scrolled past the map: the page fades in behind the bar's buttons.
    @State private var isPastMap = false
    /// The route map opened to two thirds of the page by a pull down; it
    /// rests at its own height each time the trip opens.
    @State var isMapExpanded = false
    /// The page's visible height, two thirds of which the opened map takes.
    @State private var pageHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
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
    /// Set once the user has split a trip: the Split Trip tip stays away.
    @AppStorage(TripSplitHint.dismissedKey) var splitHintDismissed = false
    /// The last "Did you go home?" answer, while its Undo toast shows.
    @State var gapAnswerToast: TripGapAnswerToast?
    /// The later half the last "Yes" split off, listed under the Stops.
    @State var splitOffTrip: TripGapActions.TripRef?
    /// An answer or its Undo is saving; the answers wait for it.
    @State var isAnsweringGap = false
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
    @State var shareRequest: TripShareRequest?
    /// The title card's 24 pt title, scaled with the reader's text size.
    @ScaledMetric(relativeTo: .title2) var titleSize: CGFloat = 24

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

    /// The page content's coordinate space, where the Stops rows measure themselves.
    nonisolated static let pageSpace = "trip-detail.page"

    var detailContent: some View {
        pageScroll
        .overlay(alignment: .top) {
            LinearGradient(
                stops: [
                    .init(color: Color(.systemGroupedBackground), location: 0),
                    .init(color: Color(.systemGroupedBackground), location: 0.72),
                    .init(color: Color(.systemGroupedBackground).opacity(0), location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
                .frame(height: 152)
                .ignoresSafeArea(edges: .top)
                .opacity(isPastMap ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: isPastMap)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(trip.displayName)
        .navigationBarTitleDisplayMode(.inline)
        // The title card names the trip; the bar keeps only its buttons
        // over the map. The title still names the page for the back stack.
        .toolbar(removing: .title)
        // Onscreen awareness: advertise
        // the focused trip while this view is visible, so Siri can resolve
        // "this trip" / "share this" to the on-screen entity. Declared in
        // Info.plist `NSUserActivityTypes`. Sendable values are captured
        // up front — the update closure isn't MainActor-typed, so it must
        // not touch the `@Model` directly.
        .userActivity(
            Self.viewingTripActivityType,
            element: ViewingTripActivity(
                id: TripEntityID(tripID: trip.id, row: trip.persistentModelID), name: trip.displayName)
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
            // Two icon buttons sharing one glass group: the star and the
            // pencil, which enters edit mode. Editing ends with a prominent
            // Done in the confirmation slot.
            if isEditing {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveRename()
                    }
                    .disabled(isSavingRename)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        guard !trip.isDeleted else { return }
                        shareRequest = TripShareRequest(tripIDs: [trip.id])
                    } label: {
                        Label(String(localized: "trip-share.menu.share", defaultValue: "Share…",
                                     comment: "Context menu and toolbar action that opens the trip share sheet."),
                              systemImage: "square.and.arrow.up")
                    }
                }
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
                            mapFocus = nil
                            // Editing needs the page free to scroll.
                            isMapExpanded = false
                            editingName = trip.customName ?? ""
                            isEditing = true
                        }
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }
            }
        }
        .sheet(item: $shareRequest) { request in
            TripShareSheet(request: request)
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
        // An inset, not an overlay: the page scrolls its last row clear of the toast.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let toast = gapAnswerToast {
                TripGapToast(text: toast.text, isBusy: isAnsweringGap) { undoGapAnswer() }
                    .padding(.horizontal, AppTheme.gutter)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.token) {
                        try? await Task.sleep(for: TripGapActions.undoWindow)
                        guard !Task.isCancelled, gapAnswerToast?.token == toast.token, !isAnsweringGap else { return }
                        withAnimation(.easeInOut(duration: 0.3)) { gapAnswerToast = nil }
                    }
            }
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


    private var pageScroll: some View {
        // Sorted once per body evaluation (`trip.orderedStays` is a fresh
        // sort) and threaded into the sections that need it.
        let orderedStays = trip.orderedStays
        // Where the page has scrolled past the map, opened or at rest.
        let pastMapOffset = mapHeight - 80
        return ScrollView {
            VStack(spacing: 0) {
                // Full bleed under the navigation buttons, faded at the top
                // so they hold on any basemap.
                mapSection(orderedStays, onOpenStop: { openStopInList($0, among: orderedStays) })
                    .frame(height: mapHeight)
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [AppTheme.mapEdge, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 112)
                            .allowsHitTesting(false)
                    }
                    .overlay(alignment: .bottom) {
                        mapGrabber
                    }

                VStack(spacing: 0) {
                    temporaryHomeSuggestionSection

                    // The grouped-page grammar: the title card, then the headed
                    // Photos strip and Stops card on the grouped background.
                    headerSection(orderedStays)
                        .padding(.horizontal, AppTheme.gutter)
                        .padding(.top, 16)

                    photosSection
                        .padding(.horizontal, AppTheme.gutter)
                        .padding(.top, 24)

                    timelineSection(orderedStays, onShowOnMap: { showStopOnMap($0) })
                        .padding(.horizontal, AppTheme.gutter)
                        .padding(.top, 24)

                    if let splitOff = liveSplitOffTrip {
                        splitOffSection(splitOff)
                            .padding(.horizontal, AppTheme.gutter)
                            .padding(.top, 24)
                            .transition(.opacity)
                    }
                }
                // Under the opened map the page holds still: a swipe up
                // anywhere on it, gaps included, puts the map back first.
                .contentShape(Rectangle())
                .simultaneousGesture(mapCloseSwipe, isEnabled: holdsPageForMap)
            }
            .padding(.bottom, 32)
            .coordinateSpace(.named(Self.pageSpace))
            // Fills the page's width. Not `containerRelativeFrame`: with the
            // scroll view under the status bar, its container on the iPhone
            // Duo (status bar in a side column) is wider than the page, and
            // the page then centres off the screen's leading edge.
            .frame(maxWidth: .infinity)
            // The page's hold is its own: the map's pan, the Photos strip and
            // the chooser's list keep scrolling under it.
            .environment(\.isScrollEnabled, true)
        }
        .ignoresSafeArea(edges: .top)
        .scrollDisabled(holdsPageForMap)
        // With the scroll view under the status bar the system draws no
        // scroll-edge effect, so once the map has scrolled away the page
        // colour fades in behind the buttons in its place.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > pastMapOffset
        } action: { _, isPast in
            isPastMap = isPast
        }
        .scrollPosition($pagePosition)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height
        } action: { _, maxOffset in
            stopScroll.maxOffset = maxOffset
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.height
        } action: { _, height in
            pageHeight = height
        }
        // The reader's own scroll dismisses the map's callout; the page's
        // scrolls to a stop or back to the map do not.
        .onScrollPhaseChange { old, phase, context in
            if (phase == .tracking || phase == .interacting), mapFocus != nil {
                mapFocus = nil
            }
            // A pull down past the top, let go, opens the map.
            if old == .interacting, !isMapExpanded,
               -(context.geometry.contentOffset.y + context.geometry.contentInsets.top) > Self.mapPullDistance {
                setMapExpanded(true)
            }
        }
    }

    /// The route map's height at rest.
    static let restingMapHeight: CGFloat = 300
    /// How far past the page's top a pull, let go, opens the map.
    static let mapPullDistance: CGFloat = 40

    /// The map at rest, or opened to two thirds of the page's visible height
    /// (measured, so the iPhone Duo's inner screen gets its own two thirds).
    var mapHeight: CGFloat {
        isMapExpanded ? max(Self.restingMapHeight, (pageHeight * 2 / 3).rounded()) : Self.restingMapHeight
    }

    /// The opened map holds the page still, so the first swipe up closes it
    /// and only the next scrolls. Not under VoiceOver, whose scrolling can't
    /// make that swipe: the grabber closes the map there.
    private var holdsPageForMap: Bool {
        isMapExpanded && !voiceOverEnabled
    }

    /// A swipe up on the page under the opened map closes it as soon as it
    /// reads as one, so the map follows the finger back.
    private var mapCloseSwipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let rise = -value.translation.height
                if rise > 20, rise > abs(value.translation.width) {
                    setMapExpanded(false)
                }
            }
    }

    /// Opens or closes the route map on a spring, at once under Reduce
    /// Motion. The map re-frames the route to its new size itself.
    /// `revealing` scrolls the page back to the map's top as it opens.
    func setMapExpanded(_ expanded: Bool, revealing: Bool = false) {
        guard expanded != isMapExpanded else { return }
        withAnimation(reduceMotion ? nil : Animation.spring(duration: 0.45, bounce: 0.12)) {
            isMapExpanded = expanded
            if expanded, revealing {
                pagePosition.scrollTo(edge: .top)
            }
        }
    }

    /// The map callout's tap: the page scrolls the stop's row 112 pt down,
    /// under the navigation buttons, and the row flashes.
    private func openStopInList(_ id: PersistentIdentifier, among orderedStays: [Stay]) {
        // The row's top in the page: the Stops rows' top, then each row and
        // gap above it, measured once laid out and estimated until then (a
        // lazy row far down may not be yet). An opened map closes on the
        // way, so the page measured under it rises by the difference.
        let mapLift = mapHeight - Self.restingMapHeight
        var y = stopScroll.rowsTop - mapLift
        let gapsBefore = isEditing ? [] : Set(stopGaps.map(\.question.laterStayID))
        for stay in orderedStays {
            if gapsBefore.contains(stay.id) {
                y += stopScroll.gapHeights[stay.id] ?? 64
            }
            let rowID = stay.persistentModelID
            if rowID == id { break }
            y += stopScroll.heights[rowID] ?? TimelineStop.estimatedRowHeight(
                stay, hasPhotos: !(photoPresentation.assetsByStay[stay.id] ?? []).isEmpty)
        }
        let target = max(0, min(stopScroll.maxOffset - mapLift, y - 112))
        withAnimation(.smooth(duration: 0.45)) {
            isMapExpanded = false
            pagePosition.scrollTo(y: target)
        }
        withAnimation(.easeOut(duration: 0.2)) { flashedStop = id }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard flashedStop == id else { return }
            withAnimation(.easeOut(duration: 0.4)) { flashedStop = nil }
        }
    }

    /// A stop row's tap: the page scrolls to the top and the map selects
    /// that place (its group's chooser opens on it when it shares a ring).
    private func showStopOnMap(_ id: PersistentIdentifier) {
        pressedStop = id
        withAnimation(.smooth(duration: 0.45)) {
            pagePosition.scrollTo(edge: .top)
        }
        mapFocus = .listed(id)
        Task {
            try? await Task.sleep(for: .seconds(0.35))
            guard pressedStop == id else { return }
            withAnimation(.easeOut(duration: 0.3)) { pressedStop = nil }
        }
    }
}

/// The trip page's scroll geometry for placing a stop row under the
/// navigation buttons. Written from geometry callbacks and read only by the
/// map callout's tap, so it is a plain reference that never redraws the page.
final class StopScrollMetrics {
    /// The farthest the page scrolls.
    var maxOffset: CGFloat = .greatestFiniteMagnitude
    /// The Stops rows' top in the page.
    var rowsTop: CGFloat = 0
    /// Each laid-out gap row's height, by the stay below it.
    var gapHeights: [UUID: CGFloat] = [:]
    /// Each laid-out row's height.
    var heights: [PersistentIdentifier: CGFloat] = [:]
}
