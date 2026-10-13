//
//  ForwardGeocoderQualifierTests.swift
//  TravelLogTests
//
//  Explicit countries in calendar location text bind the offline city
//  lookup: "London, ON, Canada" is London, Canada, not the more
//  populous London, GB. A country-named part that is also a subdivision
//  ("Atlanta, Georgia") may match by admin-1 name. Runs against the real
//  bundled Geocoder.sqlite; each test gets a fresh, isolated geocoder cache.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite(.serialized, IsolatedCalendarDefaults())
struct ForwardGeocoderQualifierTests {

    private var geocoder: ForwardGeocoder { ForwardGeocoder.shared }

    private func offlinePlace(_ text: String) async -> ForwardGeocodedPlace? {
        guard case .resolved(let place) = await geocoder.resolveOutcome(text, allowNetwork: false) else {
            return nil
        }
        return place
    }

    // MARK: - Tier 1 against the bundled database

    @Test("an explicit country picks that country's homonym")
    func explicitCountryBindsTheOfflineLookup() async throws {
        let cases: [(text: String, iso: String, latitude: Double)] = [
            ("London, Canada", "CA", 42.98), ("London, ON, Canada", "CA", 42.98),
            ("Hamilton, New Zealand", "NZ", -37.78), ("Kingston, Ontario, Canada", "CA", 44.23),
            ("Birmingham, AL, USA", "US", 33.52), ("Rome, Georgia", "US", 34.26),
            ("Tbilisi, Georgia", "GE", 41.69), ("Atlanta, Georgia", "US", 33.75),
            ("Rome, Italy", "IT", 41.89), ("Lixoúri, Greece", "GR", 38.20), ("Luxembourg", "LU", 49.61),
        ]
        for (text, iso, latitude) in cases {
            guard let place = await offlinePlace(text) else {
                Issue.record("\(text) did not resolve offline")
                continue
            }
            #expect(place.isoCountryCode == iso, "\(text)")
            #expect(abs(place.latitude - latitude) < 0.2, "\(text)")
        }
    }

    @Test("no qualifying homonym is a miss, never the globally largest one or the qualifier itself",
          arguments: ["Tokyo, Canada", "Tbilisi, Georgia, USA", "Tokyo, Luxembourg"])
    func unsatisfiableQualifiersMiss(text: String) async {
        #expect(await geocoder.resolveOutcome(text, allowNetwork: false) == .unavailable)
        #expect(await geocoder.cachedResolution(for: text) == .miss)
    }

    @Test("a country beyond the candidate cap still binds the lookup")
    func qualifierPastTheCandidateCapStillApplies() async throws {
        let text = "London\nSuite 4, Floor 2, Building A, Block B, Gate C, Wing D, Door E, Hall F, Room G, Desk H, Bay I, Canada"
        #expect(!ForwardGeocoder.candidateStrings(from: text).contains("Canada"))
        let place = try #require(await offlinePlace(text))
        #expect(place.isoCountryCode == "CA")
    }

    @Test("v3 positives are discarded on load and on wipe")
    func v3CacheIsDiscarded() async throws {
        let defaults = IsolatedCalendarDefaults.current
        let poisoned = #"{"london, canada":{"place":{"latitude":51.54548,"longitude":-0.17664,"locality":"London","country":"United Kingdom","isoCountryCode":"GB"},"cachedAt":780000000}}"#
        defaults.set(Data(poisoned.utf8), forKey: "forwardGeocodeCache_v3")

        let place = try #require(await offlinePlace("London, Canada"))
        #expect(place.isoCountryCode == "CA")
        #expect(defaults.data(forKey: "forwardGeocodeCache_v3") == nil)
        #expect(defaults.data(forKey: "forwardGeocodeCache_v4") != nil)

        defaults.set(Data(poisoned.utf8), forKey: "forwardGeocodeCache_v3")
        await geocoder.clearCache()
        #expect(defaults.data(forKey: "forwardGeocodeCache_v3") == nil)
        #expect(defaults.data(forKey: "forwardGeocodeCache_v4") == nil)
    }

    // MARK: - Pure policy

    @Test("qualifiers come from every part; each must be met by country or admin-1 name")
    func qualifierPolicy() {
        let parts = ForwardGeocoder.textParts(from: "Hotel X\nAtlanta, Georgia, USA")
        #expect(parts == ["Hotel X", "Atlanta", "Georgia", "USA"])
        let qualifiers = ForwardGeocoder.countryQualifiers(in: parts)
        #expect(qualifiers.map(\.isoCountryCode) == ["GE", "US"])
        #expect(ForwardGeocoder.satisfies(isoCountryCode: "US", admin1Name: "Georgia", qualifiers: qualifiers))
        #expect(!ForwardGeocoder.satisfies(isoCountryCode: "GE", admin1Name: "Tbilisi", qualifiers: qualifiers))
        #expect(!ForwardGeocoder.satisfies(isoCountryCode: nil, admin1Name: nil, qualifiers: qualifiers))
        #expect(ForwardGeocoder.satisfies(isoCountryCode: "GB", admin1Name: nil, qualifiers: []))
    }

    @Test("a network result cannot satisfy the destination through its country qualifier")
    func networkQualifierIsNotTheDestination() {
        let luxembourgCity = ForwardGeocoder.NetworkResult(
            candidate: .init(rank: 0, name: "Luxembourg", address: "Luxembourg, Luxembourg",
                             mapLocality: "Luxembourg", reverseLocality: "Luxembourg",
                             reverseAdministrativeArea: "Luxembourg", reverseCountry: "Luxembourg"),
            isoCountryCode: "LU", admin1Name: "Luxembourg")
        // The scorer alone, fed every alternative, takes the qualifier as the place.
        #expect(ForwardGeocodeMatchScorer.evaluate(
            queryCandidates: ForwardGeocodeMatchScorer.viableQueryCandidates(
                from: ForwardGeocoder.candidateStrings(from: "Tokyo, Luxembourg")),
            candidates: [luxembourgCity.candidate]).isAccepted)
        #expect(!ForwardGeocoder.networkAssessment(rawText: "Tokyo, Luxembourg", results: [luxembourgCity]).isAccepted)
        #expect(ForwardGeocoder.networkAssessment(rawText: "Luxembourg", results: [luxembourgCity]).isAccepted)

        let tokyo = ForwardGeocoder.NetworkResult(
            candidate: .init(rank: 1, name: "Tokyo", address: "Tokyo, Japan", mapLocality: "Tokyo",
                             reverseLocality: "Tokyo", reverseAdministrativeArea: "Tokyo", reverseCountry: "Japan"),
            isoCountryCode: "JP", admin1Name: "Tokyo")
        let japan = ForwardGeocoder.networkAssessment(rawText: "Tokyo, Japan", results: [luxembourgCity, tokyo])
        #expect(japan.isAccepted)
        #expect(japan.candidateRank == 1)
        // The real Tokyo still fails the explicit LU qualifier.
        #expect(!ForwardGeocoder.networkAssessment(rawText: "Tokyo, Luxembourg", results: [luxembourgCity, tokyo]).isAccepted)

        // Any Greek address used to satisfy the bare "Greece" of a venue line.
        let greekStreet = ForwardGeocoder.NetworkResult(
            candidate: .init(rank: 0, name: "Ermou 10", address: "Ermou 10, Athina 105 63, Greece",
                             reverseLocality: "Athens", reverseCountry: "Greece"),
            isoCountryCode: "GR", admin1Name: "Attica")
        let hotel = ForwardGeocoder.NetworkResult(
            candidate: .init(rank: 1, name: "Hotel Grande Bretagne",
                             address: "Vasileos Georgiou A 1, Athina 105 64, Greece",
                             pointOfInterestCategory: "MKPOICategoryHotel",
                             reverseLocality: "Athens", reverseCountry: "Greece"),
            isoCountryCode: "GR", admin1Name: "Attica")
        let venue = "Hotel Grande Bretagne, Greece"
        #expect(!ForwardGeocoder.networkAssessment(rawText: venue, results: [greekStreet]).isAccepted)
        let venueAssessment = ForwardGeocoder.networkAssessment(rawText: venue, results: [greekStreet, hotel])
        #expect(venueAssessment.isAccepted)
        #expect(venueAssessment.candidateRank == 1)
    }

    @Test("a network result that is the place a country-named part names satisfies that part")
    func countryNamedDestinationIsAdmitted() {
        // Kowloon's Jordan: both parts are country names, and neither is the other's country.
        #expect(ForwardGeocoder.countryQualifiers(in: ["Jordan", "Hong Kong"]).map(\.isoCountryCode) == ["JO", "HK"])
        let jordanHK = ForwardGeocoder.NetworkResult(
            candidate: .init(rank: 1, name: "Jordan", address: "Jordan, Hong Kong", mapLocality: "Kowloon",
                             reverseLocality: "Hong Kong", reverseSubLocality: "Yau Tsim Mong District",
                             reverseCountry: "Hong Kong"),
            isoCountryCode: "HK", admin1Name: nil)
        let hongKong = ForwardGeocoder.NetworkResult(
            candidate: .init(rank: 0, name: "Hong Kong", address: "Hong Kong", mapLocality: "Hong Kong",
                             reverseLocality: "Hong Kong", reverseCountry: "Hong Kong"),
            isoCountryCode: "HK", admin1Name: nil)
        let jordanCountry = ForwardGeocoder.NetworkResult(
            candidate: .init(rank: 0, name: "Jordan", address: "Jordan", reverseLocality: "Amman",
                             reverseAdministrativeArea: "Amman", reverseCountry: "Jordan"),
            isoCountryCode: "JO", admin1Name: "Amman")
        let kowloon = ForwardGeocoder.networkAssessment(rawText: "Jordan, Hong Kong", results: [hongKong, jordanHK])
        #expect(kowloon.isAccepted)
        #expect(kowloon.candidateRank == 1)
        // The country of Jordan is not in Hong Kong, and Hong Kong is not Jordan.
        #expect(!ForwardGeocoder.networkAssessment(rawText: "Jordan, Hong Kong", results: [jordanCountry]).isAccepted)
        #expect(!ForwardGeocoder.networkAssessment(rawText: "Jordan, Hong Kong", results: [hongKong]).isAccepted)

        // A US town named like a country, with its state as the other part.
        #expect(ForwardGeocoder.countryQualifiers(in: ["Lebanon", "NH"]).map(\.isoCountryCode) == ["LB"])
        let lebanonNH = ForwardGeocoder.NetworkResult(
            candidate: .init(rank: 0, name: "Lebanon", address: "Lebanon, NH 03766, United States",
                             mapLocality: "Lebanon", mapRegion: "NH", reverseLocality: "Lebanon",
                             reverseAdministrativeArea: "New Hampshire", reverseCountry: "United States"),
            isoCountryCode: "US", admin1Name: "New Hampshire")
        #expect(ForwardGeocoder.networkAssessment(rawText: "Lebanon, NH", results: [lebanonNH]).isAccepted)
        let peruIndiana = ForwardGeocoder.NetworkResult(
            candidate: .init(rank: 0, name: "Peru", address: "Peru, IN 46970, United States",
                             mapLocality: "Peru", mapRegion: "IN", reverseLocality: "Peru",
                             reverseAdministrativeArea: "Indiana", reverseCountry: "United States"),
            isoCountryCode: "US", admin1Name: "Indiana")
        #expect(ForwardGeocoder.networkAssessment(rawText: "Peru, IN", results: [peruIndiana]).isAccepted)
        // Text naming only a country-named place (a Spanish user's "Granada") accepts that place.
        #expect(ForwardGeocoder.networkAssessment(rawText: "Peru", results: [peruIndiana]).isAccepted)

        // The same rule for a qualifier from a device-language name: Spanish "Granada" is Grenada.
        let grenada = ForwardGeocoder.CountryQualifier(text: "Granada", foldedText: "granada", isoCountryCode: "GD")
        let spain = ForwardGeocoder.CountryQualifier(text: "España", foldedText: "espana", isoCountryCode: "ES")
        #expect(ForwardGeocoder.satisfies(isoCountryCode: "ES", admin1Name: "Andalusia",
                                          placeNames: ["Granada"], qualifiers: [grenada, spain]))
        #expect(!ForwardGeocoder.satisfies(isoCountryCode: "ES", admin1Name: "Andalusia",
                                           placeNames: ["Sevilla"], qualifiers: [grenada, spain]))

        // A categorized point of interest named like the country is not that country.
        let canadaRestaurant = ForwardGeocoder.NetworkResult(
            candidate: .init(rank: 0, name: "Canada", address: "1 High Street, London, England, United Kingdom",
                             mapLocality: "London", pointOfInterestCategory: "MKPOICategoryRestaurant",
                             reverseLocality: "London", reverseAdministrativeArea: "England",
                             reverseCountry: "United Kingdom"),
            isoCountryCode: "GB", admin1Name: "England")
        #expect(canadaRestaurant.placeNames == ["London", "London"])
        #expect(!ForwardGeocoder.networkAssessment(rawText: "London, Canada", results: [canadaRestaurant]).isAccepted)
    }

    @Test("a bare country is a destination alternative only when the text names nothing else")
    func destinationAlternatives() async {
        func destinations(_ text: String) -> [String] {
            ForwardGeocoder.destinationCandidates(
                ForwardGeocodeMatchScorer.viableQueryCandidates(from: ForwardGeocoder.candidateStrings(from: text)),
                parts: ForwardGeocoder.textParts(from: text))
        }
        #expect(destinations("Tokyo, Luxembourg") == ["Tokyo, Luxembourg", "Tokyo"])
        #expect(destinations("Luxembourg") == ["Luxembourg"])
        #expect(destinations("Greece\nZoom Room").isEmpty)
        // Nothing but a qualifier and boilerplate is a deterministic rejection, even offline.
        #expect(await geocoder.resolveOutcome("Greece\nZoom Room", allowNetwork: false) == .rejected)
        #expect(await geocoder.cachedResolution(for: "Greece\nZoom Room") == .unresolved)
    }

    @Test("a literal destination keeps the countries its event names")
    func contextualQueryCarriesCountries() {
        #expect(ForwardGeocoder.contextualQuery("London", context: ["London wedding", "London, ON, Canada"])
            == "London, Canada")
        #expect(ForwardGeocoder.contextualQuery("Cephalonia", context: ["Cephalonia wedding", ""]) == "Cephalonia")
        #expect(ForwardGeocoder.contextualQuery("Greece", context: ["Greece trip", "Athens, Greece"]) == "Greece")
        #expect(ForwardGeocoder.contextualQuery("Rome, Italy", context: ["Rome", "Italy"]) == "Rome, Italy")
    }

    // MARK: - The calendar scan

    private func event(_ title: String, location: String) -> CalendarEventSnapshot {
        let start = Date.now.addingTimeInterval(30 * 86_400)
        return CalendarEventSnapshot(externalIdentifier: "offsite", localIdentifier: "offsite", title: title,
            notes: nil, locationText: location, startDate: start, endDate: start.addingTimeInterval(3 * 86_400),
            isAllDay: false, hasRecurrenceRules: false, isDetached: false, calendarTitle: "Test", calendarKind: .icloud)
    }

    nonisolated private static let londonGB = ForwardGeocodedPlace(latitude: 51.54548, longitude: -0.17664,
        locality: "London", country: "United Kingdom", isoCountryCode: "GB")

    private func seedHome(_ container: ModelContainer, latitude: Double, longitude: Double) throws {
        let context = ModelContext(container)
        context.insert(Home(label: "Home", latitude: latitude, longitude: longitude,
                            startedAt: Date.now.addingTimeInterval(-365 * 86_400)))
        try context.save()
    }

    private func scan(_ enricher: CalendarEnricher, _ snapshot: CalendarEventSnapshot) async -> CalendarEnricher.ScanAnalysis {
        let epoch = await enricher.calendarDataEpochForTesting()
        return await enricher.resolveAndAugment(
            detections: PlannedTripDetector.detect(in: [snapshot]), allSnapshots: [snapshot],
            allowFMTieBreaker: false, allowNetworkResolution: false, expectedEpoch: epoch, geocoder: geocoder)
    }

    private func seedPoisonedRow(_ enricher: CalendarEnricher, container: ModelContainer,
                                 _ snapshot: CalendarEventSnapshot) async throws {
        await enricher.applyScan(detections: [PlannedTripDetection(snapshot: snapshot, confidence: .medium,
            signals: [PlannedTripDetector.signalFarFromHome, PlannedTripDetector.signalMultiDay],
            resolved: ResolvedPlannedPlace(place: Self.londonGB, distanceFromHomeKm: 5_700))],
            now: .now.addingTimeInterval(-86_400))
        let context = ModelContext(container)
        let row = try #require(try context.fetch(FetchDescriptor<PlannedTrip>()).first)
        row.forecastWeatherData = Data([1, 2, 3])
        try context.save()
    }

    @Test("a UK home sees London, ON as far away, and a stored GB place heals to CA")
    func canadianLondonFromUKHome() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedHome(container, latitude: 51.54548, longitude: -0.17664)
        let enricher = CalendarEnricher(modelContainer: container)
        let offsite = event("Team offsite", location: "London, ON, Canada")
        try await seedPoisonedRow(enricher, container: container, offsite)

        let analysis = await scan(enricher, offsite)
        let detection = try #require(analysis.detections.first)
        #expect(detection.resolved?.place.isoCountryCode == "CA")
        #expect((detection.resolved?.distanceFromHomeKm ?? 0) > 5_000)
        #expect(detection.signals.contains(PlannedTripDetector.signalFarFromHome))

        await enricher.applyScan(detections: analysis.detections, rejectedGeocodes: analysis.rejectedGeocodes,
            deferredGroundingSnapshots: analysis.deferredGroundingSnapshots, now: .now)
        let row = try #require(try ModelContext(container).fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(row.resolvedISOCountryCode == "CA")
        #expect(row.forecastWeatherData == nil)
    }

    @Test("a home in London, ON withdraws a stored GB place and its far-from-home evidence")
    func canadianLondonFromCanadianHomeWithdrawsPoisonedEvidence() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedHome(container, latitude: 42.98339, longitude: -81.23304)
        let enricher = CalendarEnricher(modelContainer: container)
        let offsite = event("Team offsite", location: "London, ON, Canada")
        try await seedPoisonedRow(enricher, container: container, offsite)

        let analysis = await scan(enricher, offsite)
        #expect(analysis.detections.isEmpty)
        #expect(analysis.rejectedGeocodes == [offsite])

        await enricher.applyScan(detections: analysis.detections, rejectedGeocodes: analysis.rejectedGeocodes,
            deferredGroundingSnapshots: analysis.deferredGroundingSnapshots, now: .now)
        let row = try #require(try ModelContext(container).fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(row.resolvedISOCountryCode == nil)
        #expect(row.distanceFromHomeKm == nil)
        #expect(row.forecastWeatherData == nil)
        #expect(row.confidence == .low)
        #expect(!row.signals.contains(PlannedTripDetector.signalFarFromHome))
    }

    private actor Lookups {
        var texts: [String] = []
        func record(_ text: String) { texts.append(text) }
    }

    @Test("FM grounding of a bare city keeps the event's country and ignores a bare-city cache hit")
    func groundingKeepsTheEventCountry() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.clearFMJudgmentCache()
        let wedding = event("London wedding", location: "London, ON, Canada")
        let londonCA = ForwardGeocodedPlace(latitude: 42.98339, longitude: -81.23304,
            locality: "London", country: "Canada", isoCountryCode: "CA")
        let resolutions = Lookups()
        let epoch = await enricher.calendarDataEpochForTesting()
        let analysis = await enricher.resolveAndAugment(
            detections: PlannedTripDetector.detect(in: [wedding]), allSnapshots: [wedding],
            allowFMTieBreaker: true, allowNetworkResolution: true, expectedEpoch: epoch,
            cacheLookup: { text in text == "London" ? .resolved(Self.londonGB) : .miss },
            resolve: { text, _, _ in
                await resolutions.record(text)
                return text == "London, Canada" ? .resolved(londonCA) : .rejected
            },
            judge: { _ in PlannedTripJudgment(reasoning: "Fixture", isTrip: true, destination: "London") })

        #expect(await resolutions.texts == ["London, ON, Canada", "London, Canada"])
        let detection = try #require(analysis.detections.first)
        #expect(detection.resolved?.place.isoCountryCode == "CA")
    }
}
