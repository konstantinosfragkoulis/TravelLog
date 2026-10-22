import SwiftUI
import MapKit

struct GlobeView: View {

    @Environment(\.colorScheme) private var colorScheme

    let visitedCountryCodes: Set<String>
    var height: CGFloat = 300

    static let initialCamera = MKMapCamera(
        lookingAtCenter: CLLocationCoordinate2D(latitude: 20, longitude: 0),
        fromDistance: 55_000_000,
        pitch: 0,
        heading: 0
    )

    @State private var resetSequence = 0
    @State private var showGlobe = true
    @State private var isUserNavigated = false
    @State private var countryPolygons: [CountryPolygonProvider.CountryPolygon] = []
    @State private var frame = CountryOverlayFrame.empty
    @State private var frameGeneration = 0

    /// The code set the current `countryPolygons` were filtered for. Gates
    /// the `.task(id:)` below: without it, every Stats re-appearance would
    /// re-await `polygons(for:)`, which re-kicks the FULL ~3.6 MB GeoJSON
    /// parse whenever the app has backgrounded in between (`releaseCache()`
    /// drops the memo on every `.background`), even though this view's
    /// already-filtered subset is still perfectly valid.
    /// The bundle data is immutable, so the only legitimate invalidation is
    /// a change to the code set — exactly what the task id captures.
    @State private var loadedCodes: Set<String>?

    /// Deferred native map creation (first Stats open per launch). Instantiating
    /// a Metal-backed imagery MKMapView is the single heaviest main-thread
    /// step of the first Stats visit, and would land INSIDE the tab-switch
    /// animation. A ~400 ms placeholder pushes it past the
    /// transition, where the same main-thread block is invisible. Once
    /// created, the map stays resident (the tab keeps its view hierarchy),
    /// so this costs one brief placeholder per launch.
    @State private var mapReady = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if mapReady {
                GlobeNativeMap(
                    frame: frame,
                    showsImagery: showGlobe,
                    resetSequence: resetSequence
                ) { camera in
                    // Any deviation from the initial camera arms Reset Zoom,
                    // pans at default zoom and zoom-outs included, so there is
                    // always a way back to the initial framing.
                    let initial = Self.initialCamera
                    isUserNavigated =
                        abs(camera.centerCoordinateDistance - initial.centerCoordinateDistance) > 1_000_000
                        || abs(camera.centerCoordinate.latitude - initial.centerCoordinate.latitude) > 1
                        || abs(GeoMath.wrappedLongitudeDelta(
                            camera.centerCoordinate.longitude,
                            initial.centerCoordinate.longitude
                        )) > 1
                }

                VStack(spacing: 8) {
                    Button {
                        showGlobe.toggle()
                    } label: {
                        Label("Map Style", systemImage: showGlobe ? "map.fill" : "globe.americas.fill")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass)

                    Button {
                        resetSequence += 1
                    } label: {
                        Label("Reset Zoom", systemImage: isUserNavigated ? "minus.magnifyingglass" : "magnifyingglass")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glass)
                    .contentTransition(.symbolEffect(.replace))
                    .disabled(!isUserNavigated)
                }
                // One glass control shape, stacked from the corner's top line.
                .buttonBorderShape(.circle)
                .padding(12)
            } else {
                // Ocean-dark stand-in matching the imagery globe's tone, so
                // the swap reads as the globe "resolving", not a layout jump.
                LinearGradient(
                    colors: [AppTheme.globeOcean, AppTheme.globeOceanDeep],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .overlay {
                    ProgressView()
                        .tint(.white.opacity(0.5))
                }
                .task {
                    try? await Task.sleep(for: .milliseconds(400))
                    // A cancelled sleep (tab exited during the wait) returns
                    // early — don't create the map off-screen; the next
                    // appearance restarts the timer.
                    guard !Task.isCancelled else { return }
                    mapReady = true
                }
            }
        }
        .frame(height: height)
        .clipShape(.rect(cornerRadius: AppTheme.thumbLarge))
        // Bundle geometry is immutable, so IDs capture polygon membership changes.
        .onChange(of: countryPolygons.map(\.id), initial: true) {
            publishFrame()
        }
        .onChange(of: colorScheme) {
            publishFrame()
        }
        // Country polygons load asynchronously: this `.task` kicks off the
        // provider's lazy, memoized off-main parse (see
        // `CountryPolygonProvider`).
        .task(id: visitedCountryCodes) {
            // Re-appearance with an unchanged code set is a no-op — the
            // subset in @State is still valid even if the provider's memo
            // was released while backgrounded (see `loadedCodes`).
            if loadedCodes == visitedCountryCodes { return }
            let polygons = await CountryPolygonProvider.polygons(for: visitedCountryCodes)
            // The provider retries released parses for active callers.
            // Cancelled invocations return empty; do not store their result
            // or mark a superseded code set as loaded.
            guard !Task.isCancelled else { return }
            countryPolygons = polygons
            loadedCodes = visitedCountryCodes
        }
    }

    private func publishFrame() {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let resolved = UIColor(Color.accentColor).resolvedColor(with: traits)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let tint = HexRGBA(r: Double(red), g: Double(green), b: Double(blue), a: Double(alpha))
        frameGeneration += 1
        frame = CountryOverlayFrame(
            generation: frameGeneration, polygons: countryPolygons,
            fill: tint.withOpacity(0.5), stroke: tint.withOpacity(0.75)
        )
    }
}
