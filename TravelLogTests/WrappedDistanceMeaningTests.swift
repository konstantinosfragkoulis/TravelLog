import Foundation
import Testing
@testable import TravelLog

@MainActor
struct WrappedDistanceMeaningTests {
    private let english = Locale(identifier: "en")

    @Test("a saved connection's route can exceed the recorded-place path without claiming to be its subtotal")
    func connectingRouteAndRecordedPathKeepTheirMeaning() {
        var stats = WrappedStats()
        stats.totalGreatCircleKm = 2_429.827
        stats.flightKm = 3_118.525
        let content = WrappedPosterContent(year: 2025, stats: stats, weatherCoverage: 0, locale: english)

        #expect(content.totalKm == stats.totalGreatCircleKm)
        #expect(content.modes.first?.km == stats.flightKm)
        #expect(content.totalKm < (content.modes.first?.km ?? 0))
        #expect(WrappedPosterCard.distanceCaption(
            unit: "km", hasRecordedPath: content.totalKm > 0, locale: english
        ) == "km between recorded places, in straight lines.")

        let inputs = NarrativeInputs(
            year: 2025, tripDisplayNames: [], tripStartDates: [],
            longestTripName: nil, longestTripDays: nil, farthestPlaceName: nil,
            farthestDistanceKm: nil, firstTimeCountryISOCodes: [])
        stats.narrativeInputs = inputs
        let narrative = WrappedDisplayResolver.resolvedNarrative(
            storedProse: "You covered 2429 km in total.", stats: stats, locale: english)
        #expect(narrative?.contains("Straight-line distance between your recorded places was 2429 km.") == true)
        #expect(narrative?.contains("in total") == false)
        #expect(stats.totalGreatCircleKm == 2_429.827)
        #expect(stats.flightKm == 3_118.525)
    }

    @Test("a recap without a recorded-place path retains its mode-sum caption and legacy stored prose")
    func modeSumFallbackAndLegacyProse() {
        var stats = WrappedStats()
        stats.flightKm = 3_118.525
        let content = WrappedPosterContent(year: 2025, stats: stats, weatherCoverage: 0, locale: english)
        #expect(content.totalKm == 0)
        #expect(content.modes.map(\.km).reduce(0, +) == stats.flightKm)
        #expect(WrappedPosterCard.distanceCaption(
            unit: "km", hasRecordedPath: content.totalKm > 0, locale: english
        ) == "km in total.")
        let storedProse = "You covered 2429 km in total."
        #expect(WrappedDisplayResolver.resolvedNarrative(
            storedProse: storedProse, stats: stats, locale: english) == storedProse)
    }
}
