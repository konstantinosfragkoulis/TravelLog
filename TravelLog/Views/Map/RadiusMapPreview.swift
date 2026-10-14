//
//  RadiusMapPreview.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 12/5/26.
//

import SwiftUI
import MapKit
import CoreLocation

/// A non-interactive map that shows a pin — and, when a radius is supplied,
/// a circle — around a chosen coordinate. Home forms pass `nil` since the
/// home-area redesign: membership is
/// the measured city boundary or the learned home area there, and drawing a
/// circle would promise geometry the classifier no longer uses. Routine
/// Place forms still pass their radius — that circle is real.
///
/// `MapCircle` renders a geodesic circle measured in meters, so at high
/// latitudes the circle appears visually elongated on screen — this is
/// correct cartography (the map projection isn't flat), not a bug.
struct RadiusMapPreview: View {

    let coordinate: CLLocationCoordinate2D

    /// Always meters — matches `MapCircle`'s API and avoids any unit
    /// conversion ambiguity at the call site. nil ⇒ pin only, no circle.
    let radiusMeters: Double?

    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $cameraPosition, interactionModes: []) {
            // A non-literal title selects the verbatim initializer, so
            // string extraction does not add an empty key to the catalog.
            Marker(String(), coordinate: coordinate)
                .tint(.red)
            if let radiusMeters {
                MapCircle(center: coordinate, radius: radiusMeters)
                    .foregroundStyle(Color.accentColor.opacity(0.18))
                    .stroke(Color.accentColor, lineWidth: 1.5)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .allowsHitTesting(false)
        .onAppear { updateCamera(animated: false) }
        .onChange(of: radiusMeters) { _, _ in updateCamera(animated: true) }
        .onChange(of: coordinate.latitude) { _, _ in updateCamera(animated: true) }
        .onChange(of: coordinate.longitude) { _, _ in updateCamera(animated: true) }
    }

    private func updateCamera(animated: Bool) {
        // Show ~4× the radius as the visible span so the circle fits with
        // breathing room. Floor at 200 m to keep tiny radii from looking
        // lost; with no radius, show a fixed neighbourhood-scale 2 km span.
        let span = max((radiusMeters ?? 500) * 4, 200)
        let region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: span,
            longitudinalMeters: span
        )
        if animated {
            withAnimation(.easeInOut(duration: 0.25)) {
                cameraPosition = .region(region)
            }
        } else {
            cameraPosition = .region(region)
        }
    }
}
