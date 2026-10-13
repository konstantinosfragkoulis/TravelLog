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

/// Full-screen MapKit map with one raster overlay for H3 resolution-6 cells.
///
/// ## Key behaviors
/// - Shows the user's live location via the native map's location annotation.
/// - Location arrow button recenters the map on the user.
/// - Tap any hex to see stats (country, first/last visit, entries, H3 index).
/// - Draws cells per map tile, with minimum-size discs for distant explored cells.
/// - Hex counter sits at bottom-right, clear of the control pill and title.
/// - Colors on the blue/light-blue spectrum.
struct HexMapView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme

    /// Value snapshot of the `HexVisit` rows, refreshed once per data epoch /
    /// tab appearance by `refreshMapData()`, sorted by `lastVisited`
    /// descending. Backs the detail popup and the highlight matcher. Live
    /// `@Query` here would re-materialize on every save and re-run the
    /// overlay precompute.
    @State private var hexRows: [HexVisitSnapshot] = []

    @State private var overlayFrame = HexOverlayFrame.empty
    @State private var frameGeneration = 0
    @State private var cameraCommand: HexCameraCommand?
    @State private var cameraSequence = 0
    @State private var followsUser = true
    @State private var cellGeometry: [HexCellGeometry] = []
    // Stored as the h3Index (a value), not a HexVisit reference, so a
    // background dedup pass or CloudKit delete that removes the HexVisit cannot
    // leave a dangling managed-object reference. The popup is derived from the
    // `hexRows` snapshot, so a deleted hex simply dismisses the popup on the
    // next epoch refresh instead of crashing on property access.
    @State private var selectedHexIndex: String?
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

            // Hex detail popup (bottom center, above counter)
            if let index = selectedHexIndex,
               let hex = hexRows.first(where: { $0.h3Index == index }) {
                VStack {
                    Spacer()
                    hexDetailPopup(hex)
                        .padding(.bottom, 64)
                        // Tap-absorber: any tap inside the popup
                        // rectangle that misses an interactive child
                        // (X button, etc.) is consumed here. Without
                        // this, the underlying MapKit view receives
                        // the tap too — selecting whatever hex sits
                        // beneath the popup. The X button's own
                        // action still fires first (inner gesture
                        // wins in SwiftUI), so this no-op only
                        // catches strays. `contentShape` makes the
                        // entire popped-out rect tappable, including
                        // the transparent corners of the glass shape.
                        .contentShape(.rect)
                        .onTapGesture { /* absorb */ }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Hex counter (bottom right)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    hexCounter
                }
            }

            // My Location control (top trailing, on the title row: its top
            // edge sits 8 pt below the safe area like the title capsule).
            GlassEffectContainer {
                VStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            issueCamera(.followUser(animated: true))
                        }
                    } label: {
                        Label("My Location", systemImage: followsUser ? "location.fill" : "location")
                            .bold()
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass)
                    .glassEffectUnion(id: "mapControls", namespace: controlsNamespace)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, 14)
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
                .padding(.leading, 14)
                .padding(.top, 68)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: highlight)
        // The map is full-bleed: nothing may paint over it under the title.
        // iOS 26 left the bar transparent on its own; iOS 27 beta 8 draws a
        // soft scroll-edge effect (a progressive blur + dim band) behind the
        // title, treating the map as scrollable content, and neither
        // `.toolbarBackgroundVisibility(.hidden)` nor
        // `.scrollEdgeEffectHidden(for: .top)` removed it on the device.
        // So the navigation bar is gone
        // altogether and the title is this view's own glass capsule: with no
        // bar there is nothing for the system to draw an edge effect behind.
        // `navigationTitle` stays for accessibility and the tab's identity.
        .navigationTitle("Exploration Map")
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            Text("Exploration Map")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .glassEffect(in: .capsule)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
                .allowsHitTesting(false)
        }
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

    // MARK: - Hex Counter (bottom right)

    @ViewBuilder
    private var hexCounter: some View {
        HStack(spacing: 6) {
            Image(systemName: "hexagon.fill")
                .foregroundStyle(.blue)
            // Counter reflects the *displayed* hex count, not the raw
            // HexVisit row count. After the transit-only filter
            // (`refreshMapData`) some HexVisits may be hidden —
            // showing the raw count here would imply more exploration
            // than the user can actually see, which feels broken. The
            // counter stays hidden until the first successful load so a
            // pending or failed read never reads as "0 explored".
            Text("\(allOverlays.count)")
                .font(.headline.monospacedDigit())
            Text("explored")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(in: .rect(cornerRadius: 12))
        .padding(.trailing, 16)
        .padding(.bottom, 16)
        .opacity(hasLoadedMapData ? 1 : 0)
    }

    // MARK: - Hex Detail Popup

    @ViewBuilder
    private func hexDetailPopup(_ hex: HexVisitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    // City + Country on separate lines, or combined if both present
                    if let locality = hex.locality,
                       let country = localizedCountryName(
                           iso: hex.isoCountryCode,
                           fallback: hex.country
                       ) {
                        Text(locality)
                            .font(.subheadline.bold())
                        Text(country)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let locality = hex.locality {
                        Text(locality)
                            .font(.subheadline.bold())
                    } else if let country = localizedCountryName(
                        iso: hex.isoCountryCode,
                        fallback: hex.country
                    ) {
                        Text(country)
                            .font(.subheadline.bold())
                    } else {
                        Text("Unknown Location")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                    }
                }

                if let code = hex.isoCountryCode, let flag = flagEmoji(for: code) {
                    Text(flag)
                        .font(.title3)
                }

                Spacer()

                Button {
                    withAnimation(.easeOut(duration: 0.2)) { selectedHexIndex = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        // 44×44 hit target (Apple's minimum) so taps near
                        // the ~17pt icon don't fall through to the Map
                        // underneath and select the hex below.
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            Divider()

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("First visited")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(hex.firstVisited.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last visited")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(hex.lastVisited.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Entries")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(hex.visitCount)")
                        .font(.caption.bold())
                }
            }

            Text(hex.h3Index)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(maxWidth: 320)
        .glassEffect(in: .rect(cornerRadius: 16))
        .padding(.horizontal)
    }

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

        withAnimation(.easeOut(duration: 0.2)) {
            selectedHexIndex = selectedID
        }
    }


    // MARK: - Overlay Computation

    /// Load boundaries off-main, then project and publish a complete frame on
    /// main. The loader captures pending edits before its worker hop.
    private func refreshMapData() async {
        let token = StoreChangeTracker.shared.token(for: Self.mapChanges)
        if let last = lastMapToken, last == token { return }

        // A failed read or cancelled worker must not clear a populated map
        // or consume the token; the next appearance can retry.
        guard let result = try? await HexMapDataLoader.load(context: modelContext),
              !Task.isCancelled,
              token == StoreChangeTracker.shared.token(for: Self.mapChanges) else { return }

        guard Self.needsRepublish(
            hasLoaded: hasLoadedMapData,
            previousRows: hexRows,
            previousMax: maxVisitCount,
            next: result
        ) else {
            lastMapToken = token
            return
        }

        // Back on main: assign, project once, and publish immutable paint/geometry.
        // The VISIBLE rows, not the raw ones. Every consumer of `hexRows`
        // describes what is drawn or interactive — the tap lookup, the
        // highlight matcher, the highlight chip's count and the camera
        // framing — so feeding it the unfiltered set would make those
        // disagree with both the map overlays and Stats, which is exactly the
        // drift the single shared `HexVisibility` rule exists to prevent. A
        // hidden (aerial-only) cell has no overlay to tap and must not be
        // counted or framed.
        hexRows = result.rows
        allOverlays = result.overlays
        maxVisitCount = result.maxCount
        lastMapToken = token
        hasLoadedMapData = true
        cellGeometry = HexGeometryBuilder.build(result.overlays)
        publishFrame()

        // Re-derive the active highlight against the fresh rows. This is
        // what heals the Stats→Map first-visit race: the router request is
        // consumed against an EMPTY snapshot (chip shows "0 hexes" for a
        // beat), then this pass fills the match set and frames the camera.
        rebuildActiveHighlight()
    }

    private func publishFrame() {
        // Resolve the highlight tint once per frame, not once per cell.
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let orange = rgba(UIColor(Color.orange), opacity: 1, traits: traits)
        let paints = allOverlays.map { paint(for: $0, orange: orange, traits: traits) }
        frameGeneration += 1
        overlayFrame = HexOverlayFrame(generation: frameGeneration, cells: cellGeometry, paints: paints)
    }

    // MARK: - Overlay Color Helpers

    /// Resolve paint on main; tile drawing receives only immutable RGBA values.
    private func paint(
        for overlay: HexOverlayData,
        orange: HexRGBA,
        traits: UITraitCollection
    ) -> HexCellPaint {
        if !highlightedHexes.isEmpty {
            if highlightedHexes.contains(overlay.id) {
                return HexCellPaint(
                    fill: orange.withOpacity(0.55), stroke: orange, emphasized: true
                )
            }
            return HexCellPaint(
                fill: rgba(fillColor(for: overlay.visitCount), opacity: 0.15, traits: traits),
                stroke: rgba(strokeColor(for: overlay.visitCount), opacity: 0.3, traits: traits),
                emphasized: false
            )
        }
        return HexCellPaint(
            fill: rgba(fillColor(for: overlay.visitCount), opacity: 0.5, traits: traits),
            stroke: rgba(strokeColor(for: overlay.visitCount), opacity: 1, traits: traits),
            emphasized: false
        )
    }

    private func rgba(_ color: UIColor, opacity: Double, traits: UITraitCollection) -> HexRGBA {
        let resolved = color.resolvedColor(with: traits)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return HexRGBA(r: Double(red), g: Double(green), b: Double(blue), a: Double(alpha) * opacity)
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
        hexRows.map {
            HexHighlightRequest.HexRow(
                h3Index: $0.h3Index,
                isoCountryCode: $0.isoCountryCode,
                firstVisited: $0.firstVisited
            )
        }
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
            Image(systemName: "hexagon.fill")
                .font(.caption)
                .foregroundStyle(.orange)
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
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
    }

    // MARK: - Color Helpers (Blue Spectrum)

    private func fillColor(for visitCount: Int) -> UIColor {
        let normalized = min(Double(visitCount) / Double(max(maxVisitCount, 1)), 1.0)
        let saturation = 0.3 + normalized * 0.5
        let brightness = 0.95 - normalized * 0.35
        return UIColor(hue: 0.58, saturation: CGFloat(saturation), brightness: CGFloat(brightness), alpha: 1)
    }

    private func strokeColor(for visitCount: Int) -> UIColor {
        let normalized = min(Double(visitCount) / Double(max(maxVisitCount, 1)), 1.0)
        let saturation = 0.4 + normalized * 0.4
        let brightness = 0.7 - normalized * 0.25
        return UIColor(hue: 0.58, saturation: CGFloat(saturation), brightness: CGFloat(brightness), alpha: 1)
    }
}
