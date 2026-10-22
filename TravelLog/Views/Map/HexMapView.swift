//
//  HexMapView.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import SwiftUI
import SwiftData
import MapKit
import UIKit

/// Full-screen MapKit map with vector overlays for H3 resolution-6 cells.
///
/// ## Key behaviors
/// - Shows the user's live location via the native map's location annotation.
/// - Location arrow button recenters the map on the user.
/// - Tap any hex for its sheet (place, entries, days, first/last visit, the
///   trips and photos recorded there); a trip row opens the trip.
/// - Draws cells as MapKit vector shapes (sharp at every zoom), with
///   minimum-size discs for distant explored cells (`HexOverlayScene`).
/// - A soft cobalt wash, brighter and denser with more visits, inside one
///   outline of the visited set (holes included; no line between visited
///   cells, `HexPalette`); the tapped cell wears the saffron ring, and
///   highlighted cells turn saffron over dimmed others.
/// - The "N explored" counter (top leading), location control (top
///   trailing) and highlight chip share one 44 pt glass line grammar at
///   16 pt gutters, over a soft fade under the status bar.
struct HexMapView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme

    /// Value snapshot of the `HexVisit` rows, refreshed once per data epoch /
    /// tab appearance by `refreshMapData()`, sorted by `lastVisited`
    /// descending. Backs the detail sheet and the highlight matcher. Live
    /// `@Query` here would re-materialize on every save and re-run the
    /// overlay precompute.
    @State private var hexRows: [HexVisitSnapshot] = []
    /// The other countries a drawn cell's rows carry (`Snapshot.countryCodes`).
    @State private var hexCountryCodes: [String: Set<String>] = [:]

    @State private var overlayFrame = HexOverlayFrame.empty
    @State private var frameGeneration = 0
    @State private var cameraCommand: HexCameraCommand?
    @State private var cameraSequence = 0
    @State private var followsUser = true
    @State private var cellGeometry: [HexCellGeometry] = []
    /// The visited set's outline, rebuilt only when the set changes.
    @State private var cellOutline = HexOutline.empty
    @State private var geometryID = 0
    // Stored as the h3Index (a value), not a HexVisit reference, so a
    // background dedup pass or CloudKit delete that removes the HexVisit cannot
    // leave a dangling managed-object reference. The sheet is derived from the
    // `hexRows` snapshot, so a deleted hex simply dismisses the sheet on the
    // next epoch refresh instead of crashing on property access.
    @State private var selectedHexIndex: String?
    /// A trip chosen in the sheet: pushed once the sheet has gone.
    @State private var pendingTrip: Trip?
    @State private var routedTrip: Trip?
    @State private var allOverlays: [HexOverlayData] = []
    // Gates the empty state and counter so a pending or failed first read is
    // not shown as "nothing explored".
    @State private var hasLoadedMapData = false
    @State private var maxVisitCount: Int = 1

    /// The store types the hex map renders. Only `Stay` (transit/real split)
    /// and `HexVisit` changes rebuild the map — a calendar scan, trip title,
    /// weather fill on an unrelated stay, or photo-import-state churn no longer
    /// restart the O(n) boundary recompute.
    private static let mapChanges: StoreChange = [.stay, .hexVisit]

    static func showsEmptyState(hasLoaded: Bool, overlayCount: Int) -> Bool {
        hasLoaded && overlayCount == 0
    }

    /// Overlays, geometry and highlight derive from the visible rows and the
    /// max count, so an identical load has nothing new to draw. A ping save
    /// moves the token even when no stay or hex changed.
    nonisolated static func needsRepublish(
        hasLoaded: Bool,
        previousRows: [HexVisitSnapshot],
        previousMax: Int,
        next: HexMapDataLoader.Snapshot
    ) -> Bool {
        !hasLoaded || previousMax != next.maxCount || previousRows != next.rows
    }

    /// The `StoreChangeTracker` token the current overlays were built from, so a
    /// tab re-appearance with an unchanged token skips the whole rebuild.
    @State private var lastMapToken: Int?

    /// Delete All Data's epoch the shown snapshot belongs to. A committed
    /// wipe moves it, and everything shown goes before the next read, which
    /// may fail; a load begun under an older epoch never lands.
    private let revocation = MapSnapshotRevocation.shared
    @State private var shownRevocationEpoch = MapSnapshotRevocation.shared.epoch

    @Namespace private var controlsNamespace

    /// Stats-routed highlight mode (e.g. "Greece" / "New this year").
    /// Only `MapTabRouter` can enter it — the map offers no entry point of
    /// its own — and the chip's ✕ exits back to the normal map.
    /// `highlightedHexes` is the precomputed h3 set the color pipeline
    /// checks per overlay.
    @State private var highlight: HexHighlightRequest?
    @State private var highlightedHexes: Set<String> = []
    private let mapRouter = MapTabRouter.shared

    /// H3 resolution 6 hex "radius" (center to vertex) in degrees.
    /// Minimum padding when framing a highlighted selection.
    private let hexRadiusDegrees: Double = 0.04

    var body: some View {
        ZStack {
            mapView

            // Hex counter (top leading, on the location control's line).
            hexCounter
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, AppTheme.gutter)
                .padding(.trailing, AppTheme.gutter + Self.controlHeight + 8)
                .padding(.top, 8)

            // My Location control (top trailing: a 44 pt circle whose top
            // edge sits 8 pt below the safe area, at the 16 pt gutter).
            GlassEffectContainer {
                VStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            issueCamera(.followUser(animated: true))
                        }
                    } label: {
                        Label("My Location", systemImage: followsUser ? "location.fill" : "location")
                            .font(.system(size: 15, weight: .semibold))
                            .labelStyle(.iconOnly)
                            .foregroundStyle(AppTheme.accent)
                            .frame(width: Self.controlHeight, height: Self.controlHeight)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectUnion(id: "mapControls", namespace: controlsNamespace)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, AppTheme.gutter)
            .padding(.top, 8)

            // Highlight chip (top leading) — names the active highlight and
            // is the way back to the normal map.
            if let highlight {
                VStack {
                    HStack {
                        highlightChip(for: highlight)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.leading, AppTheme.gutter)
                // Below the 44 pt control line.
                .padding(.top, 8 + Self.controlHeight + 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: highlight)
        // The map is full-bleed: no system bar may paint over it. iOS 26
        // left the bar transparent on its own; iOS 27 beta 8 draws a soft
        // scroll-edge effect (a progressive blur + dim band) behind the
        // title, treating the map as scrollable content, and neither
        // `.toolbarBackgroundVisibility(.hidden)` nor
        // `.scrollEdgeEffectHidden(for: .top)` removed it on the device.
        // So the navigation bar is gone altogether: with no bar there is
        // nothing for the system to draw an edge effect behind. The design
        // shows no title on the map, only the counter and the location
        // control over its own light fade (`mapView`). `navigationTitle`
        // stays for accessibility and the tab's identity.
        .navigationTitle("Exploration Map")
        .toolbar(.hidden, for: .navigationBar)
        // Fetch → snapshot → precompute, once per data epoch / tab
        // appearance. Replaces the live @Query trio and their count-based
        // onChange triggers: `.task(id:)` auto-cancels a superseded run,
        // the 500 ms epoch debounce coalesces import/sync save bursts into
        // one rebuild. Re-appearance retries unfinished or failed refreshes.
        // Category flips (AI reclassify, sanity check, user override) run
        // gated, so both directions of a transit/real move bump the epoch.
        // Reading the precise token in the id registers the Observation
        // dependency on exactly the map's types; the guard inside
        // `refreshMapData` additionally skips a re-appearance whose token is
        // unchanged.
        .task(id: StoreChangeTracker.shared.token(for: Self.mapChanges)) {
            await refreshMapData()
        }
        // Consume a Stats-routed highlight request. `initial: true` covers
        // the case where Stats fired the request before this view ever
        // rendered (first visit to the Map tab). Mirrors TripsListView's
        // router-consumer pattern: this view owns the highlight state and
        // is the only place that clears the router. On a first visit the
        // snapshot may still be empty here — `refreshMapData` re-derives
        // the match set from the `highlight` state once rows arrive.
        .onChange(of: mapRouter.requestedHighlight, initial: true) {
            applyPendingHighlight()
        }
        .onChange(of: colorScheme) {
            publishFrame()
        }
        .onChange(of: revocation.epoch) {
            dropRevokedSnapshot()
        }
        .onChange(of: selectedHexIndex) {
            publishFrame()
        }
        // The tapped hex's sheet. At its peek detent the map stays live, so
        // another tap moves the sheet to that cell and a tap on empty map
        // closes it, as the in-map panel did.
        .sheet(isPresented: hexSheetPresented, onDismiss: openPendingTrip) {
            if let hex = selectedHex {
                HexDetailSheet(
                    hex: hex,
                    markFill: markFill(for: hex),
                    onClose: { selectedHexIndex = nil },
                    onOpenTrip: { trip in
                        pendingTrip = trip
                        selectedHexIndex = nil
                    }
                )
                .presentationDetents([sheetPeek, .large])
                // The design's dark sheet: system glass would take on the
                // cobalt of the cells beneath it.
                .presentationBackground(Color(.secondarySystemGroupedBackground).opacity(0.94))
                .presentationBackgroundInteraction(.enabled(upThrough: sheetPeek))
                .presentationDragIndicator(.visible)
            }
        }
        .navigationDestination(item: $routedTrip) { trip in
            TripDetailView(trip: trip)
        }
        // Leaving the tab (or a routed switch away) closes the sheet, which
        // would otherwise cover the other tab.
        .onDisappear {
            selectedHexIndex = nil
        }
    }

    // MARK: - Map

    @ViewBuilder
    private var mapView: some View {
        HexNativeMap(
            frame: overlayFrame,
            cameraCommand: cameraCommand,
            onTap: handleTap(at:zoomScale:),
            onFollowChange: { followsUser = $0 }
        )
            // Keeps the status bar and the glass controls legible over a
            // bright basemap: 60% of the page colour fading out by 112 pt.
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [Color(.systemGroupedBackground).opacity(0.6), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 112)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            // Full-bleed like the SwiftUI Map was: a representable respects
            // the safe area by default, which left black bands behind the
            // status bar and the tab bar.
            .ignoresSafeArea()
            .overlay {
                if Self.showsEmptyState(
                    hasLoaded: hasLoadedMapData,
                    overlayCount: allOverlays.count
                ) {
                    VStack(spacing: 12) {
                        Image(systemName: "hexagon")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text("No hexes explored yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("As you move around, hexes will light up on the map.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 48)
                    }
                }
            }
    }

    // MARK: - Hex Counter (top leading)

    @ViewBuilder
    private var hexCounter: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "hexagon.fill")
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
            // Counter reflects the *displayed* hex count, not the raw
            // HexVisit row count. After the transit-only filter
            // (`refreshMapData`) some HexVisits may be hidden —
            // showing the raw count here would imply more exploration
            // than the user can actually see, which feels broken. The
            // counter stays hidden until the first successful load so a
            // pending or failed read never reads as "0 explored".
            Text("\(allOverlays.count)")
                .font(AppTheme.stat(.headline))
            Text("explored")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.leading, 12)
        .padding(.trailing, 15)
        .frame(minHeight: Self.controlHeight)
        .glassEffect(in: .capsule)
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
        .opacity(hasLoadedMapData ? 1 : 0)
    }

    // MARK: - Hex Detail Sheet

    /// The selected cell's row; nil once a refresh drops it, which closes
    /// the sheet.
    private var selectedHex: HexVisitSnapshot? {
        guard let index = selectedHexIndex else { return nil }
        return hexRows.first { $0.h3Index == index }
    }

    private var hexSheetPresented: Binding<Bool> {
        Binding(
            get: { selectedHex != nil },
            set: { if !$0 { selectedHexIndex = nil } }
        )
    }

    private func openPendingTrip() {
        guard let trip = pendingTrip else { return }
        pendingTrip = nil
        // A rebuild or sync can delete it during the dismissal animation.
        guard PhotoService.isLive(trip) else { return }
        routedTrip = trip
    }

    /// The cell's colour on the map, a little denser, for the sheet's mark.
    private func markFill(for hex: HexVisitSnapshot) -> Color {
        let dark = colorScheme == .dark
        let rgba = highlightedHexes.contains(hex.h3Index)
            ? HexPalette.saffron(dark: dark)
            : HexPalette.fill(visits: hex.visitCount, in: HexPalette.ramp(dark: dark))
        return Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: HexPalette.markAlpha(dark: dark))
    }

    /// The sheet's resting height: the design's panel (header, facts, three
    /// trips and a photo row), growing with the text size. The map stays
    /// live above it; `.large` shows the rest.
    private var sheetPeek: PresentationDetent {
        .height(sheetPeekHeight)
    }

    @ScaledMetric(relativeTo: .body) private var sheetPeekHeight: CGFloat = 372

    // MARK: - Tap Handling

    private func handleTap(at coordinate: CLLocationCoordinate2D, zoomScale: Double) {
        var bestMatch: HexOverlayData?
        var bestDistance = Double.greatestFiniteMagnitude

        for overlay in allOverlays {
            // Ground-scaled, wrap-safe prefilter: a raw-degree hypot would
            // reject valid taps at high latitude (a hex spans MORE longitude
            // degrees there, pushing in-hex taps past the cutoff) and treat a
            // hex across ±180° as ~360° away. Latitude-equivalent degrees keep
            // the 0.05 threshold meaning ~5.5 km everywhere.
            let dLat = overlay.centerLatitude - coordinate.latitude
            let dLon = GeoMath.wrappedLongitudeDelta(overlay.centerLongitude, coordinate.longitude)
                * cos(coordinate.latitude * .pi / 180)
            let centerDist = hypot(dLat, dLon)
            guard centerDist < 0.05 else { continue }

            if GeoMath.pointInPolygon(coordinate, polygon: overlay.boundary), centerDist < bestDistance {
                bestDistance = centerDist
                bestMatch = overlay
            }
        }

        var selectedID = bestMatch?.id
        if selectedID == nil, zoomScale.isFinite, zoomScale > 0 {
            let tap = MKMapPoint(coordinate)
            let worldWidth = MKMapSize.world.width
            var nearest: HexCellGeometry?
            var nearestDistance = Double.greatestFiniteMagnitude
            for cell in cellGeometry {
                let rawDX = abs(cell.center.x - tap.x)
                let dx = min(rawDX, abs(rawDX - worldWidth))
                let distance = hypot(dx, cell.center.y - tap.y)
                if distance < nearestDistance {
                    nearestDistance = distance
                    nearest = cell
                }
            }
            if let nearest, nearest.diameter * zoomScale < 2,
               nearestDistance <= 4 / zoomScale {
                selectedID = nearest.id
            }
        }

        // Keep the tapped cell clear of the sheet's medium detent.
        if let selectedID, selectedID != selectedHexIndex {
            issueCamera(.reveal(coordinate))
        }
        selectedHexIndex = selectedID
    }


    // MARK: - Overlay Computation

    /// Load boundaries off-main, then project and publish a complete frame on
    /// main. The loader captures pending edits before its worker hop.
    private func refreshMapData() async {
        // A committed wipe empties the map before this read, which may fail.
        let epoch = revocation.epoch
        if epoch != shownRevocationEpoch { dropRevokedSnapshot() }
        let token = StoreChangeTracker.shared.token(for: Self.mapChanges)
        if let last = lastMapToken, last == token { return }

        // A failed read or cancelled worker must not clear a populated map
        // or consume the token; the next appearance can retry.
        guard let result = try? await HexMapDataLoader.load(context: modelContext),
              !Task.isCancelled,
              token == StoreChangeTracker.shared.token(for: Self.mapChanges),
              epoch == revocation.epoch else { return }

        guard Self.needsRepublish(
            hasLoaded: hasLoadedMapData,
            previousRows: hexRows,
            previousMax: maxVisitCount,
            next: result
        ) else {
            lastMapToken = token
            if hexCountryCodes != result.countryCodes {
                hexCountryCodes = result.countryCodes
                rebuildActiveHighlight()
            }
            return
        }

        // Project and outline the cells off main, in paint order:
        // the overlays pair paint and geometry by index, and an outline
        // edge names its cell the same way.
        let order = Self.paintOrderIndices(result.overlays)
        let geometry = await Task.detached(priority: .userInitiated) {
            let painted = order.map { result.overlays[$0] }
            let cells = HexGeometryBuilder.build(painted)
            var position = [Int](repeating: 0, count: order.count)
            for (paintIndex, loaded) in order.enumerated() { position[loaded] = paintIndex }
            let outline = HexGeometryBuilder.buildOutline(result.outline, overlays: result.overlays, position: position)
            return (painted: painted, cells: cells, outline: outline)
        }.value
        guard !Task.isCancelled, token == StoreChangeTracker.shared.token(for: Self.mapChanges),
              epoch == revocation.epoch else { return }

        // Back on main: assign and publish immutable paint/geometry.
        // The VISIBLE rows, not the raw ones. Every consumer of `hexRows`
        // describes what is drawn or interactive — the tap lookup, the
        // highlight matcher, the highlight chip's count and the camera
        // framing — so feeding it the unfiltered set would make those
        // disagree with both the map overlays and Stats, which is exactly the
        // drift the single shared `HexVisibility` rule exists to prevent. A
        // hidden (aerial-only) cell has no overlay to tap and must not be
        // counted or framed.
        hexRows = result.rows
        hexCountryCodes = result.countryCodes
        allOverlays = geometry.painted
        maxVisitCount = result.maxCount
        lastMapToken = token
        hasLoadedMapData = true
        cellGeometry = geometry.cells
        cellOutline = geometry.outline
        geometryID += 1
        publishFrame()

        // Re-derive the active highlight against the fresh rows. This is
        // what heals the Stats→Map first-visit race: the router request is
        // consumed against an EMPTY snapshot (chip shows "0 hexes" for a
        // beat), then this pass fills the match set and frames the camera.
        rebuildActiveHighlight()
    }

    /// Delete All Data committed: the rows, cells, outline, selection and
    /// highlight all describe erased places. The map shows nothing (not
    /// "nothing explored") until a read succeeds.
    private func dropRevokedSnapshot() {
        shownRevocationEpoch = revocation.epoch
        hexRows = []
        hexCountryCodes = [:]
        allOverlays = []
        maxVisitCount = 1
        cellGeometry = []
        cellOutline = .empty
        geometryID += 1
        hasLoadedMapData = false
        lastMapToken = nil
        selectedHexIndex = nil
        highlight = nil
        highlightedHexes = []
        publishFrame()
    }

    /// Fewest visits first, so the busier, brighter cells paint on top and
    /// each level is one fill layer; ties keep the loader's order.
    nonisolated static func paintOrder(_ overlays: [HexOverlayData]) -> [HexOverlayData] {
        paintOrderIndices(overlays).map { overlays[$0] }
    }

    /// `paintOrder` as indices into `overlays`.
    nonisolated static func paintOrderIndices(_ overlays: [HexOverlayData]) -> [Int] {
        overlays.indices.sorted { (overlays[$0].visitCount, $0) < (overlays[$1].visitCount, $1) }
    }

    private func publishFrame() {
        // Resolve the palette once per frame, not once per cell.
        let dark = colorScheme == .dark
        let ramp = HexPalette.ramp(dark: dark)
        let compactRamp = HexPalette.compactRamp(dark: dark)
        let edge = HexPalette.outline(dark: dark)
        let highlighted = HexPalette.highlightPaint(dark: dark)
        let paints = allOverlays.map {
            paint(for: $0, ramp: ramp, compactRamp: compactRamp, edge: edge, highlighted: highlighted)
        }
        let selection = selectedHexIndex
            .flatMap { id in allOverlays.firstIndex { $0.id == id } }
            .map {
                HexSelectionPaint(
                    index: $0, ring: HexPalette.ring(dark: dark), halo: HexPalette.halo(dark: dark),
                    glow: HexPalette.glow(dark: dark)
                )
            }
        frameGeneration += 1
        overlayFrame = HexOverlayFrame(
            generation: frameGeneration, geometryID: geometryID, cells: cellGeometry, paints: paints,
            outline: cellOutline, selection: selection, dark: dark
        )
    }

    // MARK: - Overlay Color Helpers

    /// Resolve paint on main; the overlays receive only immutable RGBA values.
    /// Translucent cobalt by absolute visits (and its compact step for
    /// small cells) under one constant outline. A highlight turns its cells
    /// translucent saffron, drawn on top, and dims the rest while keeping
    /// their own colour legible.
    private func paint(
        for overlay: HexOverlayData, ramp: [HexRGBA], compactRamp: [HexRGBA], edge: HexRGBA,
        highlighted: HexCellPaint
    ) -> HexCellPaint {
        let own = HexCellPaint(
            fill: HexPalette.fill(visits: overlay.visitCount, in: ramp),
            compactFill: HexPalette.fill(visits: overlay.visitCount, in: compactRamp),
            stroke: edge, emphasized: false
        )
        guard !highlightedHexes.isEmpty else { return own }
        return highlightedHexes.contains(overlay.id) ? highlighted : HexPalette.dimmed(own)
    }

    private func issueCamera(_ kind: HexCameraCommand.Kind) {
        cameraSequence += 1
        cameraCommand = HexCameraCommand(sequence: cameraSequence, kind: kind)
    }

    // MARK: - Highlight Mode

    /// Consume the router's pending request: compute the matching hex set
    /// from the `hexRows` snapshot and clear the router (single-consume). A request that matches
    /// nothing still shows the chip — "0 hexes" with an exit — rather than
    /// silently doing nothing on a stale Stats tap. On a first Map visit
    /// the snapshot can still be empty; `refreshMapData` calls
    /// `rebuildActiveHighlight()` once rows land.
    private func applyPendingHighlight() {
        guard let request = mapRouter.requestedHighlight else { return }
        selectedHexIndex = nil
        highlightedHexes = request.matchingHexIndices(in: highlightRows())
        highlight = request
        mapRouter.clear()
        frameHighlightedHexes()
        publishFrame()
    }

    /// Re-derive the active highlight's match set against freshly-fetched
    /// rows (called at the end of every `refreshMapData` pass). Frames the
    /// camera only when the match set goes empty → non-empty — i.e. the
    /// deferred first framing of a request that arrived before data — so a
    /// routine epoch refresh never yanks a camera the user has panned.
    private func rebuildActiveHighlight() {
        guard let request = highlight else { return }
        let newMatches = request.matchingHexIndices(in: highlightRows())
        guard newMatches != highlightedHexes else { return }
        let isFirstMatch = highlightedHexes.isEmpty && !newMatches.isEmpty
        highlightedHexes = newMatches
        if isFirstMatch {
            frameHighlightedHexes()
        }
        publishFrame()
    }

    private func highlightRows() -> [HexHighlightRequest.HexRow] {
        HexMapDataLoader.highlightRows(hexRows, countryCodes: hexCountryCodes)
    }

    /// Frame the highlighted hexes IMMEDIATELY — no animation: the user
    /// arrives from Stats and the map should already be looking at the
    /// selection, not flying toward it. Region is the padded bounding
    /// box of the matched hex centers (hexRadiusDegrees keeps a lone
    /// hex from filling the screen edge-to-edge).
    private func frameHighlightedHexes() {
        let matched = hexRows.filter { highlightedHexes.contains($0.h3Index) }
        guard let first = matched.first else { return }
        var minLat = first.centerLatitude, maxLat = first.centerLatitude
        for visit in matched.dropFirst() {
            minLat = min(minLat, visit.centerLatitude); maxLat = max(maxLat, visit.centerLatitude)
        }
        // Unwrapped longitude bounding box: the raw min/max would frame a
        // Fiji-side selection as a whole-world span because +179° and −179°
        // bracket the entire range.
        guard let lonBox = GeoMath.boundingLongitude(of: matched.map(\.centerLongitude)) else { return }
        let latSpan = max((maxLat - minLat) * 1.4, hexRadiusDegrees * 8)
        let lonSpan = max(lonBox.span * 1.4, hexRadiusDegrees * 8)
        issueCamera(.region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: lonBox.center
            ),
            span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan)
        ), animated: false))
    }

    private func clearHighlight() {
        highlight = nil
        highlightedHexes = []
        publishFrame()
    }

    @ViewBuilder
    private func highlightChip(for request: HexHighlightRequest) -> some View {
        HStack(spacing: 8) {
            // The highlighted cells' saffron.
            Image(systemName: "hexagon.fill")
                .font(.caption)
                .foregroundStyle(AppTheme.saffron)
            Text(highlightedHexes.count == 1
                 ? String(localized: "hex-map.highlight-count.one", defaultValue: "\(request.label) · \(highlightedHexes.count, format: .number.grouping(.never)) hex", comment: "Map highlight chip label with one highlighted hex.")
                 : String(localized: "hex-map.highlight-count.other", defaultValue: "\(request.label) · \(highlightedHexes.count, format: .number.grouping(.never)) hexes", comment: "Map highlight chip label with zero or multiple highlighted hexes."))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Button {
                clearHighlight()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exit highlight")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: Self.controlHeight)
        .glassEffect(in: .capsule)
    }

    // MARK: - Layout

    /// The shared height of the map's glass controls.
    private static let controlHeight: CGFloat = 44
}
