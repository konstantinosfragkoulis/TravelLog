import SwiftUI
import MapKit

nonisolated struct HexCameraCommand: Equatable {
    nonisolated enum Kind {
        case followUser(animated: Bool)
        case region(MKCoordinateRegion, animated: Bool)
        /// Pan just enough that a tapped point clears the detail sheet's
        /// peek detent; zoom is kept.
        case reveal(CLLocationCoordinate2D)
    }

    let sequence: Int
    let kind: Kind

    static func == (a: Self, b: Self) -> Bool { a.sequence == b.sequence }
}

nonisolated struct HexCameraState {
    var didFitContent = false
    var userInteracted = false
    var didRestoreFollow = false

    mutating func apply(_ command: HexCameraCommand.Kind) {
        switch command {
        case .followUser:
            // A new follow request supersedes every earlier viewport intent.
            didFitContent = false
            userInteracted = false
            didRestoreFollow = false
        case .region, .reveal:
            didFitContent = true
            didRestoreFollow = true
        }
    }

    mutating func fitContentIfNeeded(hasCells: Bool, hasLocation: Bool) -> Bool {
        guard !didFitContent, !userInteracted, hasCells, !hasLocation else { return false }
        didFitContent = true
        return true
    }

    mutating func restoreFollowIfNeeded(hasLocation: Bool, trackingIsNone: Bool) -> Bool {
        guard didFitContent, !didRestoreFollow, !userInteracted,
              hasLocation, trackingIsNone else { return false }
        didRestoreFollow = true
        return true
    }
}

struct HexNativeMap: UIViewRepresentable {
    let frame: HexOverlayFrame
    let cameraCommand: HexCameraCommand?
    let onTap: (_ coordinate: CLLocationCoordinate2D, _ zoomScale: Double) -> Void
    let onFollowChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// How far out following the user lands: city level, a few cells
    /// across, as in the design. MapKit's own follow zoom is street level,
    /// inside a single translucent cell.
    static let followDistance: CLLocationDistance = 80_000

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        // A quiet basemap under the cells: muted colours, no points of
        // interest, so the exploration layer carries the colour.
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = configuration
        map.showsUserLocation = true
        map.isScrollEnabled = true
        map.isZoomEnabled = true
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        map.showsScale = false
        map.showsUserTrackingButton = false
        map.delegate = context.coordinator
        // The night veil under the cells (and under the labels).
        map.addOverlay(context.coordinator.veil, level: .aboveRoads)
        context.coordinator.scene.attach(map)
        context.coordinator.holdFollowDistance(map)
        map.setUserTrackingMode(.follow, animated: false)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleInteraction(_:)))
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleInteraction(_:)))
        for recognizer in [tap, pan, pinch] as [UIGestureRecognizer] {
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = context.coordinator
            map.addGestureRecognizer(recognizer)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.veilRenderer.isDark = context.environment.colorScheme == .dark
        if frame.generation != coordinator.lastPublishedGeneration {
            coordinator.scene.publish(frame)
            coordinator.lastPublishedGeneration = frame.generation
        }

        var fitAnimated = false
        if let command = cameraCommand, command.sequence != coordinator.lastCameraSequence {
            coordinator.lastCameraSequence = command.sequence
            coordinator.cameraState.apply(command.kind)
            switch command.kind {
            case .followUser(let animated):
                fitAnimated = animated
                coordinator.holdFollowDistance(map)
                map.setUserTrackingMode(.follow, animated: animated)
            case .region(let region, let animated):
                coordinator.releaseFollowDistance(map)
                map.setUserTrackingMode(.none, animated: false)
                map.setRegion(region, animated: animated)
            case .reveal(let coordinate):
                coordinator.releaseFollowDistance(map)
                Self.reveal(coordinate, in: map)
            }
        }

        // Fit once for the current follow intent, whether cells arrive now or later.
        if coordinator.cameraState.fitContentIfNeeded(
            hasCells: !frame.cells.isEmpty, hasLocation: map.userLocation.location != nil
        ) {
            coordinator.releaseFollowDistance(map)
            map.setUserTrackingMode(.none, animated: false)
            map.setVisibleMapRect(Self.fitRect(for: frame.cells), animated: fitAnimated)
        }
    }

    /// The peeking sheet covers a little under the lower half of the
    /// full-bleed map: a point below 45% of its height moves up to 30%.
    private static func reveal(_ coordinate: CLLocationCoordinate2D, in map: MKMapView) {
        let height = map.bounds.height
        let point = map.convert(coordinate, toPointTo: map)
        guard height > 0, point.y > height * 0.45 else { return }
        let center = CGPoint(x: map.bounds.midX, y: map.bounds.midY + point.y - height * 0.3)
        map.setUserTrackingMode(.none, animated: false)
        map.setCenter(map.convert(center, toCoordinateFrom: map), animated: true)
    }

    nonisolated static func fitRect(for cells: [HexCellGeometry]) -> MKMapRect {
        guard let first = cells.first else { return .null }
        let worldWidth = MKMapSize.world.width
        let anchorLongitude = first.center.x / worldWidth * 360 - 180
        let bounds = cells.reduce(MKMapRect.null) { result, cell in
            let longitude = cell.center.x / worldWidth * 360 - 180
            let unwrapped = anchorLongitude + GeoMath.wrappedLongitudeDelta(longitude, anchorLongitude)
            let shiftX = (unwrapped - longitude) / 360 * worldWidth
            return result.union(MKMapRect(
                x: cell.bounds.minX + shiftX, y: cell.bounds.minY,
                width: cell.bounds.width, height: cell.bounds.height
            ))
        }
        return bounds.insetBy(dx: -bounds.width * 0.2, dy: -bounds.height * 0.2)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        let scene = HexOverlayScene()
        let veil = MapVeilOverlay()
        lazy var veilRenderer = MapVeilRenderer(overlay: veil)
        var lastPublishedGeneration = -1
        var lastCameraSequence = -1
        var cameraState = HexCameraState()
        var parent: HexNativeMap
        /// The zoom range to restore once following has landed at
        /// `followDistance`; nil while no floor is held.
        private var heldZoomRange: MKMapView.CameraZoomRange??

        init(parent: HexNativeMap) {
            self.parent = parent
            super.init()
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if overlay === veil { return veilRenderer }
            return scene.renderer(for: overlay) ?? MKOverlayRenderer(overlay: overlay)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            scene.cameraMoved(mapView)
        }

        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            // MapKit can call delegates synchronously during updateUIView.
            // Deliver SwiftUI feedback after that update has finished.
            Task { @MainActor [weak self, weak mapView] in
                guard let self, let mapView else { return }
                self.parent.onFollowChange(mapView.userTrackingMode == .follow)
            }
        }

        /// Follow zooms in only as far as `followDistance`: a temporary
        /// zoom floor, lifted once the camera lands on the user or the
        /// user takes over, so pinching closer stays free.
        func holdFollowDistance(_ map: MKMapView) {
            if heldZoomRange == nil { heldZoomRange = .some(map.cameraZoomRange) }
            map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: HexNativeMap.followDistance)
        }

        func releaseFollowDistance(_ map: MKMapView) {
            guard let held = heldZoomRange else { return }
            heldZoomRange = nil
            map.cameraZoomRange = held
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            scene.cameraSettled(mapView)
            guard heldZoomRange != nil, mapView.userTrackingMode == .follow,
                  mapView.userLocation.location != nil else { return }
            // After MapKit's own update: lifting the floor inside the
            // callback could restart the follow zoom.
            Task { @MainActor [weak self, weak mapView] in
                guard let self, let mapView else { return }
                self.releaseFollowDistance(mapView)
            }
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard cameraState.restoreFollowIfNeeded(
                hasLocation: userLocation.location != nil,
                trackingIsNone: mapView.userTrackingMode == .none
            ) else { return }
            mapView.setUserTrackingMode(.follow, animated: true)
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let map = recognizer.view as? MKMapView else { return }
            // A tap (including the first tap of a double-tap zoom) is a user
            // choice of viewport too; a late location fix must not recenter.
            cameraState.userInteracted = true
            releaseFollowDistance(map)
            let coordinate = map.convert(recognizer.location(in: map), toCoordinateFrom: map)
            let zoomScale = Double(map.bounds.width) / map.visibleMapRect.size.width
            parent.onTap(coordinate, zoomScale)
        }

        @objc func handleInteraction(_ recognizer: UIGestureRecognizer) {
            if recognizer.state == .began || recognizer.state == .changed {
                cameraState.userInteracted = true
                if let map = recognizer.view as? MKMapView { releaseFollowDistance(map) }
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

/// The whole world, under the cells: MapKit's muted dark style still paints
/// parks and land in greens, and the design's map is near black so the
/// cobalt cells carry it.
nonisolated final class MapVeilOverlay: NSObject, MKOverlay {
    let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    let boundingMapRect = MKMapRect.world
}

/// Fills the veil in dark mode only; light keeps the basemap as it is.
nonisolated final class MapVeilRenderer: MKOverlayRenderer {
    private let lock = NSLock()
    private var _isDark = false

    /// Set on the main thread from `updateUIView`; read while drawing.
    var isDark: Bool {
        get { lock.withLock { _isDark } }
        set {
            let changed = lock.withLock { () -> Bool in
                defer { _isDark = newValue }
                return _isDark != newValue
            }
            if changed { setNeedsDisplay() }
        }
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard isDark else { return }
        context.setFillColor(UIColor.black.withAlphaComponent(0.42).cgColor)
        context.fill(rect(for: mapRect))
    }
}
