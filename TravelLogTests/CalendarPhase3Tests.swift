//
//  CalendarPhase3Tests.swift
//  TravelLogTests
//
//  Calendar integration: forward geocoding (Tier-1 offline
//  city lookup against the bundled Geocoder.sqlite, using the same
//  bundled-data-testing pattern as AirportDetectorTests), the
//  distance-from-home detection signal, home-distance math, the
//  thin-history decision, and the forecast blob.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite(IsolatedCalendarDefaults())
struct CalendarPhase3Tests {

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

    // MARK: - Distance signal and recurrence penalty

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

    @Test func farMultiDayEventWithZeroTravelVocabularyDetects() {
        // No keywords, no flight code — distance (3) + multiDay (1) = 4.
        let detection = PlannedTripDetector.evaluate(
            snapshot("Grandma's place", durationHours: 3 * 24),
            distanceFromHomeKm: 450
        )
        #expect(detection?.confidence == .medium)
        #expect(detection?.signals.contains(PlannedTripDetector.signalFarFromHome) == true)
    }

    @Test func recurringFarRoutineIsSuppressedByThePenalty() {
        // The weekly far-away client site: distance (3) + multiDay (1)
        // - recurring (3) = 1 → below cutoff. THE case the recurrence
        // penalty exists for; latent until this signal landed.
        let detection = PlannedTripDetector.evaluate(
            snapshot("Client site", durationHours: 26, recurring: true),
            distanceFromHomeKm: 450
        )
        #expect(detection == nil)
    }

    @Test func nearbyEventGetsNoDistanceSignal() {
        let detection = PlannedTripDetector.evaluate(
            snapshot("Grandma's place", durationHours: 3 * 24),
            distanceFromHomeKm: 40
        )
        #expect(detection == nil)   // multiDay (1) alone stays below cutoff
    }

    // MARK: - Home distance

    @Test func distanceUsesHomeActiveAtDate() {
        let t0 = Date(timeIntervalSince1970: 1_602_419_200)
        let t1 = Date(timeIntervalSince1970: 1_702_419_200)
        // Old home: Athens (ended at t1). Current home: Berlin.
        let homes = [
            CalendarEnricher.HomeSnapshot(latitude: 37.98, longitude: 23.72, startedAt: t0, endedAt: t1),
            CalendarEnricher.HomeSnapshot(latitude: 52.52, longitude: 13.40, startedAt: t1, endedAt: nil),
        ]
        // A point in Athens: ~0 km from the OLD home for a date before t1,
        // far from the CURRENT home for a date after it.
        let before = CalendarEnricher.distanceFromActiveHome(homes, at: t1.addingTimeInterval(-1), latitude: 37.98, longitude: 23.72)
        let after = CalendarEnricher.distanceFromActiveHome(homes, at: t1.addingTimeInterval(1), latitude: 37.98, longitude: 23.72)
        #expect((before ?? 999) < 1)
        #expect((after ?? 0) > 1000)

        // No home covering the date → nil.
        #expect(CalendarEnricher.distanceFromActiveHome(homes, at: t0.addingTimeInterval(-1), latitude: 0, longitude: 0) == nil)
    }

    // MARK: - Thin-history decision

    @Test func thinHistoryVerdicts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // No past events at all means history is not thin. An
        // empty five-year lookback is what an empty calendar looks like, not
        // evidence of a truncated sync window; the old `true` here warned
        // users about a cap that wasn't there and pointed them at a sync
        // setting that would have changed nothing.
        #expect(!CalendarEnricher.isThinHistory(earliestEvent: nil, now: now))
        // Earliest event 10 days back — the shape of a "1 month back" sync cap.
        #expect(CalendarEnricher.isThinHistory(earliestEvent: now.addingTimeInterval(-10 * 86_400), now: now))
        // Earliest event 2 years back → healthy.
        #expect(!CalendarEnricher.isThinHistory(earliestEvent: now.addingTimeInterval(-730 * 86_400), now: now))
    }

    // MARK: - Forecast blob

    @Test func forecastRoundTripsThroughTheBlob() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let row = PlannedTrip(
            eventExternalIdentifier: nil, eventLocalIdentifier: "l",
            title: "Trip to Rome",
            startDate: .now.addingTimeInterval(2_419_200), endDate: .now.addingTimeInterval(2_419_200 + 86_400),
            isAllDay: false, locationText: nil
        )
        context.insert(row)

        #expect(row.forecast == nil)
        let forecast = PlannedTripForecast(
            fetchedAt: Date(timeIntervalSince1970: 1_802_419_200),
            days: [.init(date: .now.addingTimeInterval(2_419_200), conditionRaw: "clear", minTemperatureC: 18, maxTemperatureC: 27, precipitationMm: 0)]
        )
        row.forecast = forecast
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(fetched.forecast == forecast)
        #expect(StayWeather.Condition(rawValue: fetched.forecast!.days[0].conditionRaw) == .clear)
    }

    // MARK: - Reconcile persists + preserves resolution

    @Test func applyScanWritesAndPreservesResolvedFields() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let start = Date(timeIntervalSince1970: 1_822_419_200)
        let event = CalendarEventSnapshot(
            externalIdentifier: "ext", localIdentifier: "loc", title: "Trip to Rome",
            notes: nil, locationText: "Rome, Italy",
            startDate: start, endDate: start.addingTimeInterval(3 * 86_400),
            isAllDay: false, hasRecurrenceRules: false, isDetached: false,
            calendarTitle: "Personal", calendarKind: .icloud
        )
        let place = ForwardGeocodedPlace(latitude: 41.89, longitude: 12.51, locality: "Rome", country: "Italy", isoCountryCode: "IT")
        let resolvedDetection = PlannedTripDetection(
            snapshot: event, confidence: .high, signals: ["bookingTitle"],
            resolved: ResolvedPlannedPlace(place: place, distanceFromHomeKm: 1052)
        )

        let now = start.addingTimeInterval(-30 * 86_400)
        await enricher.applyScan(detections: [resolvedDetection], now: now)

        let context = ModelContext(container)
        var row = try #require(try context.fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(row.resolvedLocality == "Rome")
        #expect(row.resolvedISOCountryCode == "IT")
        #expect(row.distanceFromHomeKm == 1052)

        // A later scan that couldn't resolve (budget/offline) must keep the
        // earlier resolution.
        let unresolvedDetection = PlannedTripDetection(snapshot: event, confidence: .high, signals: ["bookingTitle"])
        await enricher.applyScan(detections: [unresolvedDetection], now: now.addingTimeInterval(3600))
        row = try #require(try context.fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(row.resolvedLocality == "Rome")
        #expect(row.distanceFromHomeKm == 1052)
    }

    @Test func definitiveRejectionClearsLegacyGeographyAndForecast() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let start = Date(timeIntervalSince1970: 1_822_419_200)
        let scanNow = start.addingTimeInterval(-30 * 86_400)
        let event = CalendarEventSnapshot(
            externalIdentifier: "legacy-ext", localIdentifier: "legacy-loc",
            title: "Grandma's place", notes: nil, locationText: "Conference Room 4b",
            startDate: start, endDate: start.addingTimeInterval(3 * 86_400),
            isAllDay: false, hasRecurrenceRules: false, isDetached: false,
            calendarTitle: "Personal", calendarKind: .icloud
        )

        let seedContext = ModelContext(container)
        let row = PlannedTrip(
            eventExternalIdentifier: event.externalIdentifier,
            eventLocalIdentifier: event.localIdentifier,
            title: event.title,
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: false,
            locationText: event.locationText
        )
        row.resolvedLatitude = 40.6839
        row.resolvedLongitude = -74.0282
        row.resolvedLocality = "New York"
        row.resolvedCountry = "United States"
        row.resolvedISOCountryCode = "US"
        row.distanceFromHomeKm = 7_900
        row.confidence = .medium
        row.signals = [PlannedTripDetector.signalFarFromHome, PlannedTripDetector.signalMultiDay]
        row.lastSeenAt = scanNow
        row.forecast = PlannedTripForecast(
            fetchedAt: start,
            days: [.init(
                date: start,
                conditionRaw: "clear",
                minTemperatureC: 10,
                maxTemperatureC: 20,
                precipitationMm: 0
            )]
        )
        seedContext.insert(row)
        try seedContext.save()

        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.applyScan(
            detections: [],
            rejectedGeocodes: [event],
            now: scanNow
        )

        let verifyContext = ModelContext(container)
        let healed = try #require(try verifyContext.fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(healed.resolvedLatitude == nil)
        #expect(healed.resolvedLongitude == nil)
        #expect(healed.resolvedLocality == nil)
        #expect(healed.resolvedCountry == nil)
        #expect(healed.resolvedISOCountryCode == nil)
        #expect(healed.distanceFromHomeKm == nil)
        #expect(healed.forecast == nil)
        #expect(!healed.signals.contains(PlannedTripDetector.signalFarFromHome))
        #expect(healed.confidence == .low)
    }
}
