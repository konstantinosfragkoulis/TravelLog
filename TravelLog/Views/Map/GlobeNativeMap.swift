import SwiftUI
import MapKit

struct GlobeNativeMap: UIViewRepresentable {
    let frame: CountryOverlayFrame
    let showsImagery: Bool
    let resetSequence: Int
    let onCameraChange: (MKMapCamera) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        context.coordinator.applyConfiguration(to: map)
        map.isScrollEnabled = true
        map.isZoomEnabled = true
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        map.showsScale = false
        map.showsUserLocation = false
        map.showsUserTrackingButton = false
        map.cameraZoomRange = MKMapView.CameraZoomRange(
            minCenterCoordinateDistance: 1_500_000,
            maxCenterCoordinateDistance: 200_000_000
        )
        map.delegate = context.coordinator
        map.camera = GlobeView.initialCamera
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if frame.generation != coordinator.lastPublishedGeneration {
            coordinator.countries.publish(frame, on: map)
            coordinator.lastPublishedGeneration = frame.generation
        }
        coordinator.applyConfiguration(to: map)
        if resetSequence != coordinator.lastResetSequence {
            coordinator.lastResetSequence = resetSequence
            map.setCamera(GlobeView.initialCamera, animated: true)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let countries = CountryOverlayLayer()
        var lastPublishedGeneration = -1
        var lastShowsImagery: Bool?
        var lastResetSequence: Int
        var parent: GlobeNativeMap

        init(parent: GlobeNativeMap) {
            self.parent = parent
            // Creation already applies the initial camera without animation.
            self.lastResetSequence = parent.resetSequence
            super.init()
        }

        func applyConfiguration(to map: MKMapView) {
            guard lastShowsImagery != parent.showsImagery else { return }
            lastShowsImagery = parent.showsImagery
            if parent.showsImagery {
                map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
            } else {
                let configuration = MKStandardMapConfiguration(elevationStyle: .flat)
                configuration.pointOfInterestFilter = .excludingAll
                map.preferredConfiguration = configuration
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            countries.renderer(for: overlay) ?? MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // MapKit can call delegates during updateUIView; defer SwiftUI feedback.
            Task { @MainActor [weak self, weak mapView] in
                guard let self, let mapView else { return }
                self.parent.onCameraChange(mapView.camera)
            }
        }
    }
}
