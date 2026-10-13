//
//  MapLocationPicker.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import SwiftUI
import MapKit

/// A reusable full-screen map view for picking a location.
///
/// The user can:
/// 1. Tap anywhere on the map to place/move the pin
/// 2. Tap "Use Current Location" to snap to their GPS position
/// 3. Use the search bar to find a place by name
///
/// The selected coordinate is communicated back through the binding.
struct MapLocationPicker: View {

    /// The currently selected coordinate (if any).
    @Binding var selectedCoordinate: CLLocationCoordinate2D?

    @State private var cameraPosition: MapCameraPosition
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching = false
    @State private var currentSearchTask: Task<Void, Never>?
    @State private var locationFetcher = OneShotLocationFetcher()
    @State private var locationFetchFailed = false

    init(selectedCoordinate: Binding<CLLocationCoordinate2D?>) {
        self._selectedCoordinate = selectedCoordinate
        self._cameraPosition = State(initialValue: .region(Self.initialRegion(selected: selectedCoordinate.wrappedValue)))
    }

    /// The camera opens on the bound pin, so editing a place abroad starts
    /// there; Athens only when nothing is selected yet.
    nonisolated static func initialRegion(selected: CLLocationCoordinate2D?) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: selected.flatMap { CLLocationCoordinate2DIsValid($0) ? $0 : nil }
                ?? CLLocationCoordinate2D(latitude: 37.98, longitude: 23.73), // Athens default
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            mapView
            controlsOverlay
        }
        .safeAreaInset(edge: .top) {
            searchBar
        }
        // A fix arriving after the picker closes must not move the saved pin.
        .onDisappear { locationFetcher.cancel() }
    }

    // MARK: - Map

    @ViewBuilder
    private var mapView: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                if let coord = selectedCoordinate {
                    Marker("Selected", coordinate: coord)
                        .tint(.red)
                }

                ForEach(searchResults, id: \.self) { item in
                    Marker(
                        item.name ?? String(
                            localized: "map-location-picker.result.fallback",
                            defaultValue: "Result",
                            comment: "Fallback map marker label when a search result has no name."
                        ),
                        coordinate: item.location.coordinate
                    )
                    .tint(.blue)
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .all))
            .onTapGesture { screenPosition in
                if let coordinate = proxy.convert(screenPosition, from: .local) {
                    cancelSearch()
                    locationFetcher.cancel()
                    withAnimation {
                        selectedCoordinate = coordinate
                        searchResults = [] // Clear search results on tap
                    }
                }
            }
        }
    }

    // MARK: - Search Bar

    @ViewBuilder
    private var searchBar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search for a place…", text: $searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .onSubmit {
                        performSearch()
                    }

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                }

                if !searchText.isEmpty {
                    Button {
                        cancelSearch()
                        searchText = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.top, 8)

            if !searchResults.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(searchResults, id: \.self) { item in
                            Button {
                                selectSearchResult(item)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name ?? String(
                                            localized: "map-location-picker.result.unknown",
                                            defaultValue: "Unknown",
                                            comment: "Fallback search-result name in the map location picker."
                                        ))
                                            .font(.subheadline.bold())
                                            .foregroundStyle(.primary)
                                        if let address = item.address?.fullAddress {
                                            Text(address)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "mappin")
                                        .foregroundStyle(.tint)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                            }
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .frame(maxHeight: 200)
                .background(.regularMaterial, in: .rect(cornerRadius: 12))
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlsOverlay: some View {
        VStack(spacing: 12) {
            Button {
                snapToCurrentLocation()
            } label: {
                Label("Use Current Location", systemImage: "location.fill")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.blue)

            if locationFetchFailed {
                Text("Could not get current location")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let coord = selectedCoordinate {
                Text("\(coord.latitude, specifier: "%.5f"), \(coord.longitude, specifier: "%.5f")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text("Tap on the map to place a pin")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .padding()
    }

    // MARK: - Actions

    private func performSearch() {
        guard !searchText.isEmpty else { return }

        currentSearchTask?.cancel()

        isSearching = true

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
        if let region = cameraPosition.region {
            request.region = region
        }

        currentSearchTask = Task {
            let search = MKLocalSearch(request: request)
            do {
                let response = try await search.start()
                guard !Task.isCancelled else { return }
                searchResults = Array(response.mapItems.prefix(5))
                isSearching = false
            } catch {
                guard !Task.isCancelled else { return }
                searchResults = []
                isSearching = false
            }
        }
    }

    private func cancelSearch() {
        currentSearchTask?.cancel()
        currentSearchTask = nil
        isSearching = false
    }

    private func selectSearchResult(_ item: MKMapItem) {
        let coordinate = item.location.coordinate
        locationFetcher.cancel()

        withAnimation {
            selectedCoordinate = coordinate
            searchResults = []
            searchText = item.name ?? ""
            cameraPosition = .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ))
        }
    }

    /// Use a dedicated one-shot CLLocationManager so we don't hijack
    /// the main LocationService's SLC pipeline.
    private func snapToCurrentLocation() {
        locationFetchFailed = false
        locationFetcher.requestLocation(
            onSuccess: { location in
                let coord = location.coordinate
                withAnimation {
                    selectedCoordinate = coord
                    cameraPosition = .region(MKCoordinateRegion(
                        center: coord,
                        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                    ))
                }
            },
            onError: {
                locationFetchFailed = true
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    locationFetchFailed = false
                }
            }
        )
    }
}

// MARK: - OneShotLocationFetcher

/// A lightweight CLLocationManager wrapper that requests a single GPS fix.
///
/// This is separate from `LocationService` so that requesting the user's
/// current location in the map picker doesn't interrupt the SLC pipeline.
private class OneShotLocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var onSuccess: ((CLLocation) -> Void)?
    private var onError: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestLocation(onSuccess: @escaping (CLLocation) -> Void, onError: @escaping () -> Void) {
        self.onSuccess = onSuccess
        self.onError = onError
        // If the user reaches the picker before granting location permission,
        // requesting a fix outright just fails silently. Prompt when the status
        // is undetermined and wait for the auth callback below; fail cleanly if
        // already denied/restricted.
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            finishError()
        }
    }

    /// Drops a pending request: a pin the user chose since wins over its fix.
    func cancel() {
        guard onSuccess != nil || onError != nil else { return }
        onSuccess = nil
        onError = nil
        manager.stopUpdatingLocation()
    }

    private func finishError() {
        onError?()
        onSuccess = nil
        onError = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Only act on a change while a request is pending (this also fires once
        // at init with the current status, which we must ignore).
        guard onSuccess != nil || onError != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .notDetermined:
            break   // prompt still on screen
        default:
            finishError()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else { return }
        onSuccess?(location)
        onSuccess = nil
        onError = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finishError()
    }
}
