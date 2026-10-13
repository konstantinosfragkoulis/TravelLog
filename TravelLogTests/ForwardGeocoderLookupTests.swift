//
//  ForwardGeocoderLookupTests.swift
//  TravelLogTests
//
//  Forward geocoding of calendar locations: the Tier-1 offline city lookup
//  against the bundled Geocoder.sqlite (the same bundled-data-testing
//  pattern as AirportDetectorTests), country names that must not stand in
//  for towns, candidate strings derived from free-form event text, and a
//  generic location that must not create distance evidence.
//

import Foundation
import Testing
@testable import TravelLog

@MainActor
@Suite(IsolatedCalendarDefaults())
struct ForwardGeocoderLookupTests {

    // MARK: - Tier-1 forward city lookup (real bundled DB)

    @Test func forwardLookupFindsMajorCities() async throws {
        let rome = try #require(await GeocodeResolver.shared.resolveCityName("Rome"))
        #expect(rome.isoCountryCode == "IT")   // most-populous homonym beats Rome, Georgia
        #expect(abs(rome.latitude - 41.89) < 0.1)

        let agiosDimitrios = try #require(await GeocodeResolver.shared.resolveCityName("Agios Dimitrios"))
        #expect(agiosDimitrios.isoCountryCode == "GR")

        let tokyo = try #require(await GeocodeResolver.shared.resolveCityName("tokyo"))
        #expect(tokyo.isoCountryCode == "JP")
    }

    @Test func forwardLookupHandlesAccentedInput() async throws {
        // Stored as "lixoúri" (GeoNames native name, lowercased with
        // diacritics preserved): accented input must hit via the plain
        // lowercased binding.
        let lixouri = try #require(await GeocodeResolver.shared.resolveCityName("Lixoúri"))
        #expect(lixouri.isoCountryCode == "GR")
    }

    @Test func forwardLookupCountryConstraint() async throws {
        #expect(await GeocodeResolver.shared.resolveCityName("Greece", isoCountryCode: "GR") == nil)
        let luxembourg = try #require(await GeocodeResolver.shared.resolveCityName("Luxembourg", isoCountryCode: "LU"))
        #expect(luxembourg.isoCountryCode == "LU")
        let rome = try #require(await GeocodeResolver.shared.resolveCityName("Rome"))
        #expect(rome.isoCountryCode == "IT")
    }

    @Test func forwardLookupMissesGracefully() async {
        #expect(await GeocodeResolver.shared.resolveCityName("Xqzzyville") == nil)
        #expect(await GeocodeResolver.shared.resolveCityName("") == nil)
        #expect(await GeocodeResolver.shared.resolveCityName(String(repeating: "a", count: 200)) == nil)
    }

    @Test func countryNameComponentIsNotATown() async throws {
        let geocoder = ForwardGeocoder.shared
        // Greece, NY / Mexico, PH must not stand in for the countries.
        #expect(await geocoder.resolveOutcome(
            "Hotel Grande Bretagne, Vasileos Georgiou A 1, Athina 105 64, Greece",
            allowNetwork: false
        ) == .unavailable)
        #expect(await geocoder.resolveOutcome("Greece", allowNetwork: false) == .unavailable)
        #expect(await geocoder.resolveOutcome("Mexico", allowNetwork: false) == .unavailable)

        for (text, iso) in [
            ("Rome, Italy", "IT"), ("Lixoúri, Greece", "GR"),
            ("Atlanta, Georgia", "US"), ("Luxembourg", "LU"),
        ] {
            guard case .resolved(let place) = await geocoder.resolveOutcome(text, allowNetwork: false) else {
                Issue.record("\(text) did not resolve offline")
                continue
            }
            #expect(place.isoCountryCode == iso, "\(text)")
        }
    }

    // MARK: - Candidate derivation

    @Test func candidateStringsDeriveFromFreeFormText() {
        #expect(ForwardGeocoder.candidateStrings(from: "Rome") == ["Rome"])
        #expect(ForwardGeocoder.candidateStrings(from: "Rome, Italy") == ["Rome, Italy", "Rome", "Italy"])
        // Multi-line postal address: every useful line remains available to
        // semantic scoring, in best-first order.
        #expect(ForwardGeocoder.candidateStrings(
            from: "Hotel Grande Bretagne\nSyntagma Square\nAthens"
        ) == ["Hotel Grande Bretagne", "Syntagma Square", "Athens"])
        #expect(ForwardGeocoder.candidateStrings(from: "   \n  ") == [])
    }

    @Test func genericCalendarLocationCannotCreateDistanceEvidence() async {
        let place = await ForwardGeocoder.shared.resolve("Conference Room 4b")
        #expect(place == nil)

        let detection = PlannedTripDetector.evaluate(
            snapshot("Quarterly planning", durationHours: 3 * 24),
            distanceFromHomeKm: place.map { _ in 500 }
        )
        #expect(detection == nil)
    }

    // MARK: - Fixtures

    private func snapshot(
        _ title: String,
        durationHours: Double = 2,
        recurring: Bool = false
    ) -> CalendarEventSnapshot {
        let start = Date(timeIntervalSince1970: 1_802_419_200)
        return CalendarEventSnapshot(
            externalIdentifier: "e", localIdentifier: "l", title: title,
            notes: nil, locationText: nil,
            startDate: start, endDate: start.addingTimeInterval(durationHours * 3600),
            isAllDay: false, hasRecurrenceRules: recurring, isDetached: false,
            calendarTitle: "Personal", calendarKind: .icloud
        )
    }
}
