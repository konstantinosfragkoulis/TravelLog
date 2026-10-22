//
//  HomeAreaSourcePreview.swift
//  TravelLog
//

import SwiftUI
import CoreLocation
import os.log

/// Tells the user what will define the home area at the chosen coordinate:
/// the measured boundary of the GHS urban centre that contains it, or, outside
/// any urban centre, a small starting area that grows from learned routines.
///
/// Renders nothing while no coordinate is chosen yet or the probe hasn't
/// answered — never blocks the form on the resolver.
struct HomeAreaSourcePreview: View {

    let coordinate: CLLocationCoordinate2D?

    private enum Probe: Equatable {
        case urbanCentre(name: String?)
        case noBoundary
    }

    @State private var probe: Probe?

    var body: some View {
        Group {
            if coordinate != nil {
                switch probe {
                case .urbanCentre(let name):
                    Label(
                        "Home area: the measured city boundary of \(name ?? "your city").",
                        systemImage: "building.2"
                    )
                case .noBoundary:
                    Label(
                        "No city boundary here. Your home area starts small and learns from your weekly routine.",
                        systemImage: "circle.dashed"
                    )
                case nil:
                    // MUST render something while the probe is in flight:
                    // modifiers on an EmptyView never run, so a blank
                    // pre-probe body would mean the `.task` below never fires
                    // and the view stays blank FOREVER.
                    Label("Checking for a city boundary…",
                          systemImage: "circle.dashed")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        // `task(id:)` re-probes when the user re-picks the coordinate.
        //
        // Staleness is guarded by KEY COMPARISON, deliberately NOT by
        // `Task.isCancelled`: during a sheet
        // presentation the Form pre-builds this row, fires the task, and the
        // transition churn can cancel it WITHOUT a later re-appear to re-fire
        // it. The actor call still returns (cancellation is cooperative —
        // and it's a cache hit in microseconds), but an isCancelled guard
        // would swallow the answer, leaving the view on "Checking…" forever
        // in Edit Home. A cancelled task's answer is still THE answer as long
        // as the coordinate it probed is the coordinate on screen.
        .task(id: coordinateKey) {
            guard let coordinate else {
                probe = nil
                return
            }
            probe = nil
            let key = coordinateKey
            let started = Date.now
            let shape = await HomeShapeProvider.shared.shape(
                latitude: coordinate.latitude, longitude: coordinate.longitude)
            Self.logger.info("Home-area probe for \(key, privacy: .private) resolved in \(Int(Date.now.timeIntervalSince(started) * 1000), privacy: .public) ms (cancelled: \(Task.isCancelled, privacy: .public)).")
            guard key == coordinateKey else { return }
            switch shape.seed {
            case .urbanCentre(_, let name): probe = .urbanCentre(name: name)
            case .fallbackDisc: probe = .noBoundary
            }
        }
    }

    private static let logger = Logger(
        subsystem: "com.travellog.app", category: "HomeAreaSourcePreview")

    /// `task(id:)` needs an Equatable identity; CLLocationCoordinate2D isn't.
    /// Rounded to ~1 m, matching `HomeShapeProvider`'s cache key.
    private var coordinateKey: String {
        coordinate.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) } ?? ""
    }
}
