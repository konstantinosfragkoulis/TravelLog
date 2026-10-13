import SwiftUI
import MapKit

nonisolated struct HexCameraCommand: Equatable {
    nonisolated enum Kind {
        case followUser(animated: Bool)
        case region(MKCoordinateRegion, animated: Bool)
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
        case .region:
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

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat)
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
        map.addOverlay(context.coordinator.overlay, level: .aboveRoads)
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
        if frame.generation != coordinator.lastPublishedGeneration {
            coordinator.overlay.publish(frame)
            coordinator.renderer.setNeedsDisplay()
            coordinator.lastPublishedGeneration = frame.generation
        }

        var fitAnimated = false
        if let command = cameraCommand, command.sequence != coordinator.lastCameraSequence {
            coordinator.lastCameraSequence = command.sequence
            coordinator.cameraState.apply(command.kind)
            switch command.kind {
            case .followUser(let animated):
                fitAnimated = animated
                map.setUserTrackingMode(.follow, animated: animated)
            case .region(let region, let animated):
                map.setUserTrackingMode(.none, animated: false)
                map.setRegion(region, animated: animated)
            }
        }

        // Fit once for the current follow intent, whether cells arrive now or later.
        if coordinator.cameraState.fitContentIfNeeded(
            hasCells: !frame.cells.isEmpty, hasLocation: map.userLocation.location != nil
        ) {
            map.setUserTrackingMode(.none, animated: false)
            map.setVisibleMapRect(Self.fitRect(for: frame.cells), animated: fitAnimated)
        }
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
        let overlay = HexOverlay()
        lazy var renderer = HexOverlayRenderer(overlay: overlay)
        var lastPublishedGeneration = -1
        var lastCameraSequence = -1
        var cameraState = HexCameraState()
        var parent: HexNativeMap

        init(parent: HexNativeMap) {
            self.parent = parent
            super.init()
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if overlay === self.overlay { return renderer }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            // MapKit can call delegates synchronously during updateUIView.
            // Deliver SwiftUI feedback after that update has finished.
            Task { @MainActor [weak self, weak mapView] in
                guard let self, let mapView else { return }
                self.parent.onFollowChange(mapView.userTrackingMode == .follow)
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
            let coordinate = map.convert(recognizer.location(in: map), toCoordinateFrom: map)
            let zoomScale = Double(map.bounds.width) / map.visibleMapRect.size.width
            parent.onTap(coordinate, zoomScale)
        }

        @objc func handleInteraction(_ recognizer: UIGestureRecognizer) {
            if recognizer.state == .began || recognizer.state == .changed {
                cameraState.userInteracted = true
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
