//
//  WeatherAttributionFootnote.swift
//  TravelLog
//

import SwiftUI
import WeatherKit

/// WeatherKit's terms require this mark and legal link wherever Apple
/// Weather data renders.
struct WeatherAttributionFootnote: View {

    private static let fallbackLegalURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!
    @MainActor private static var cachedAttribution: WeatherAttribution?
    @MainActor private static var attributionTask: Task<WeatherAttribution, Error>?

    @State private var legalURL: URL = WeatherAttributionFootnote.fallbackLegalURL
    @State private var markURL: URL?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The mark's height at accessibility sizes, where it grows with the
    /// text; the smaller sizes keep the fixed 12 points.
    @ScaledMetric(relativeTo: .caption2) private var scaledMarkHeight: CGFloat = 12

    var body: some View {
        // Accessibility sizes stack the mark above the wrapping link, so
        // neither truncates; the other sizes keep the one-line row.
        let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        let layout = isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 6))
        layout {
            AsyncImage(url: markURL) { phase in
                let remoteLoaded = switch phase {
                case .success: true
                case .empty, .failure: false
                @unknown default: false
                }
                if Self.showsFallbackMark(hasMarkURL: markURL != nil, remoteLoaded: remoteLoaded) {
                    HStack(spacing: 2) {
                        Image(systemName: "apple.logo")
                        Text(verbatim: "Weather")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: isAccessibilitySize, vertical: false)
                } else if case .success(let image) = phase {
                    image
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(height: isAccessibilitySize ? scaledMarkHeight : 12)

            Link(destination: legalURL) {
                Text("Weather data provided by Apple Weather")
                    .underline()
                    .fixedSize(horizontal: false, vertical: isAccessibilitySize)
            }
            .font(.caption2)
        }
        .task(id: colorScheme) {
            // Re-keyed on the scheme: the mark URL is scheme-specific, so a
            // light/dark switch while on screen must reload it or the
            // wrong-contrast Apple Weather mark stays until the view is
            // recreated.
            await loadAttribution()
        }
    }

    nonisolated static func showsFallbackMark(hasMarkURL: Bool, remoteLoaded: Bool) -> Bool {
        !hasMarkURL || !remoteLoaded
    }

    private func loadAttribution() async {
        do {
            let attribution: WeatherAttribution
            if let cached = Self.cachedAttribution {
                attribution = cached
            } else {
                let task: Task<WeatherAttribution, Error>
                if let inFlight = Self.attributionTask {
                    task = inFlight
                } else {
                    task = Task { @MainActor in
                        defer { Self.attributionTask = nil }
                        let fetched = try await WeatherService.shared.attribution
                        Self.cachedAttribution = fetched
                        return fetched
                    }
                    Self.attributionTask = task
                }
                attribution = try await task.value
            }
            legalURL = attribution.legalPageURL
            markURL = colorScheme == .dark
                ? attribution.combinedMarkDarkURL
                : attribution.combinedMarkLightURL
        } catch {
            // Attribution failed — the fallback legal URL stays in place
        }
    }
}
