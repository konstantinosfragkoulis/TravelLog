//
//  TripShareCardTests.swift
//  TravelLogTests
//
//  The share card's content as pure values: the distance it counts, its
//  days, countries and places, when several trips share one summary image,
//  how many flags and summary rows fit, and the map's hex resolution.
//  Places and dates are fictional fixtures.
//

import Testing
import Foundation
@testable import TravelLog

@Suite("Trip share card")
struct TripShareCardTests {

    static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func stay(_ lat: Double, _ lon: Double, _ category: StayCategory = .destination,
                     hours: (Double, Double), order: Int?, country: String? = "AA",
                     locality: String? = "Alpha", distance: Double? = nil) -> SharedStay {
        SharedStay(
            id: UUID(), startTime: base.addingTimeInterval(hours.0 * 3600),
            endTime: base.addingTimeInterval(hours.1 * 3600),
            durationMinutes: Int((hours.1 - hours.0) * 60), categoryRaw: category.rawValue,
            latitude: lat, longitude: lon, h3IndexRes6: nil, pingCount: 0, pingIDs: [],
            orderInTrip: order, locality: locality, subLocality: nil, administrativeArea: nil,
            country: nil, isoCountryCode: country, metroName: nil, islandName: nil, isAirport: false,
            sourceRaw: "liveSLC", userOverridden: false, continuesPreviousTrip: false,
            transitFromPreviousRaw: nil, distanceFromPreviousKm: distance, stepsWalked: nil,
            weatherData: nil, avgTemperatureC: nil, weatherConditionRaw: nil, precipitationMm: nil,
            dayKey: nil, timeZoneIdentifier: "UTC")
    }

    static func trip(_ stays: [SharedStay], days: Double? = 4, codes: [String] = ["AA"],
                     start: Date = base, name: String? = "Fixture Trip") -> SharedTrip {
        SharedTrip(
            shareID: UUID(), customName: name, startDate: start,
            // `days` calendar days: the last one an hour after the first day's hour.
            endDate: days.map { start.addingTimeInterval(($0 - 1) * 86_400 + 3600) },
            isComplete: days != nil, countryCodes: codes, stays: stays)
    }

    // MARK: Distance

    @Test("distance adds the trip's own legs in trip order and never the leg from home")
    func distanceSkipsTheHomeLeg() {
        // Listed out of order: trip order decides which stay is first.
        let stays = [
            Self.stay(10.2, 150.2, hours: (50, 60), order: 2, distance: 80.5),
            Self.stay(10.0, 150.0, hours: (2, 20), order: 0, distance: 900),
            Self.stay(10.1, 150.1, .transit, hours: (30, 31), order: 1, distance: 120),
            Self.stay(10.3, 150.3, hours: (70, 80), order: 3, distance: nil),
        ]
        #expect(TripShareFigures.distanceKm(Self.trip(stays)) == 200.5)
        #expect(TripShareFigures.distanceKm(Self.trip([Self.stay(10, 150, hours: (1, 9), order: 0, distance: 900)])) == 0)
    }

    @Test("a filtered trip's legs are the great circles between its shared stays")
    func filteredLegsMeasureBetweenSharedStays() throws {
        let first = Self.stay(12.0, 152.0, hours: (2, 20), order: 0, distance: 4_000)
        let second = Self.stay(12.5, 152.5, hours: (30, 40), order: 1, distance: 999)
        let third = Self.stay(13.0, 152.0, hours: (50, 60), order: 2, distance: 999)
        let filtered = try #require(TripShareExport.excludingHomeAreas(
            Self.trip([first, second, third]), rings: []))
        let expected = TripShareExport.haversineKm(12.0, 152.0, 12.5, 152.5)
            + TripShareExport.haversineKm(12.5, 152.5, 13.0, 152.0)
        #expect(abs(TripShareFigures.distanceKm(filtered) - expected) < 0.001)
    }

    // MARK: Counts

    @Test("a trip counts its days, distinct countries and destinations")
    func tripFigures() {
        let stays = [
            Self.stay(10.0, 150.0, hours: (2, 40), order: 0, country: "AA"),
            Self.stay(10.4, 150.4, .transit, hours: (41, 42), order: 1, country: "BB", distance: 50),
            Self.stay(10.8, 150.8, hours: (44, 90), order: 2, country: "BB", distance: 50),
        ]
        let figures = TripShareFigures(Self.trip(stays, days: 4, codes: ["AA", "BB"]), now: Self.base)
        #expect(figures == TripShareFigures(days: 4, countries: 2, places: 2, kilometers: 100))
    }

    @Test("an ongoing trip counts its days so far")
    func ongoingDays() {
        let stays = [Self.stay(10.0, 150.0, hours: (2, 40), order: 0)]
        let ongoing = Self.trip(stays, days: nil)
        let now = Self.base.addingTimeInterval(9 * 86_400 + 3600)
        #expect(TripShareFigures(ongoing, now: now).days >= 10)
        #expect(TripShareFigures(ongoing, now: now).days <= 11)
    }

    @Test("a summary adds days, places and distance, and counts each country once")
    func summaryFigures() {
        let one = Self.trip([
            Self.stay(10.0, 150.0, hours: (2, 20), order: 0, country: "AA"),
            Self.stay(10.5, 150.5, hours: (30, 50), order: 1, country: "BB", distance: 60),
        ], days: 3, codes: ["AA", "BB"])
        let two = Self.trip([
            Self.stay(11.0, 151.0, hours: (2, 20), order: 0, country: "BB"),
        ], days: 2, codes: ["bb"], start: Self.base.addingTimeInterval(30 * 86_400))
        #expect(TripShareFigures([one, two], now: Self.base)
                == TripShareFigures(days: 5, countries: 2, places: 3, kilometers: 60))
    }

    @MainActor
    @Test("the card leaves out distance for one stop and countries when none is known")
    func countsLeaveOutEmptyFigures() {
        let locale = Locale(identifier: "en")
        let full = TripShareCardContent.counts(
            TripShareFigures(days: 105, countries: 5, places: 23, kilometers: 2_860), locale: locale)
        #expect(full.count == 4)
        #expect(full.first == TripShareCardContent.Count(value: "105", label: "days"))
        let oneStop = TripShareCardContent.counts(
            TripShareFigures(days: 1, countries: 1, places: 1, kilometers: 0), locale: locale)
        #expect(oneStop.map(\.label) == ["day", "country", "place"])
        let unnamed = TripShareCardContent.counts(
            TripShareFigures(days: 3, countries: 0, places: 2, kilometers: 40), locale: locale)
        #expect(unnamed.count == 3)
        #expect(!unnamed.map(\.label).contains("countries"))
    }

    @MainActor
    @Test("a trip with no names and no countries is still titled")
    func untitledTrip() {
        let trip = Self.trip([Self.stay(10, 150, hours: (1, 9), order: 0, country: nil, locality: nil)],
                             codes: [], name: nil)
        #expect(!TripShareCardContent.title(trip).isEmpty)
    }

    // MARK: Several trips

    @Test("five trips or more default to one summary image, with the choice offered")
    func summaryThreshold() {
        #expect(TripShareImages.defaultChoice(tripCount: 1) == .perTrip)
        #expect(TripShareImages.defaultChoice(tripCount: 4) == .perTrip)
        #expect(!TripShareImages.offersChoice(tripCount: 4))
        #expect(TripShareImages.defaultChoice(tripCount: 5) == .summary)
        #expect(TripShareImages.offersChoice(tripCount: 5))
        #expect(TripShareImages.defaultChoice(tripCount: 12) == .summary)
    }

    @MainActor
    @Test("the summary lists twelve trips, then eleven and a count of the rest")
    func summaryRows() throws {
        func summary(_ count: Int) -> TripShareCardContent {
            TripShareCardContent.summary((0..<count).map { index in
                Self.trip([Self.stay(10, 150, hours: (1, 9), order: 0)], days: 2,
                          start: Self.base.addingTimeInterval(Double(index) * 10 * 86_400),
                          name: "Trip \(index)")
            }, now: Self.base, locale: Locale(identifier: "en"))
        }
        guard case .summary(let twelve, let none) = summary(12).body else { Issue.record("not a summary"); return }
        #expect(twelve.count == 12)
        #expect(none == nil)
        guard case .summary(let rows, let more) = summary(14).body else { Issue.record("not a summary"); return }
        #expect(rows.count == 11)
        #expect(rows.first?.title == "Trip 0")
        let line = try #require(more)
        #expect(line.contains("3"))
    }

    // MARK: Flags

    @Test("up to six flags show whole; more show five and count the rest")
    func flagOverflow() {
        let codes = ["AA", "BB", "CC", "DD", "EE", "FF", "GG", "HH", "II", "JJ", "KK", "LL"]
        #expect(TripShareFlags(codes: []).shown.isEmpty)
        #expect(TripShareFlags(codes: Array(codes.prefix(5))) == TripShareFlags(codes: Array(codes.prefix(5))))
        #expect(TripShareFlags(codes: Array(codes.prefix(5))).shown.count == 5)
        #expect(TripShareFlags(codes: Array(codes.prefix(6))).shown.count == 6)
        #expect(TripShareFlags(codes: Array(codes.prefix(6))).extra == 0)
        let seven = TripShareFlags(codes: Array(codes.prefix(7)))
        #expect(seven.shown == Array(codes.prefix(5)))
        #expect(seven.extra == 2)
        #expect(TripShareFlags(codes: codes).extra == 7)
    }

    // MARK: Map

    @Test("the hex resolution is finer for a small trip than for a wide one")
    func resolutionFollowsSpan() throws {
        let small = TripShareMapGeometry.stations(of: Self.trip([
            Self.stay(20.00, 140.00, hours: (1, 30), order: 0),
            Self.stay(20.05, 140.08, hours: (40, 70), order: 1),
        ]))
        let wide = TripShareMapGeometry.stations(of: Self.trip([
            Self.stay(20.0, 140.0, hours: (1, 30), order: 0),
            Self.stay(24.0, 146.0, hours: (40, 70), order: 1),
        ]))
        let smallFrame = try #require(TripShareMapGeometry.frame(for: small))
        let wideFrame = try #require(TripShareMapGeometry.frame(for: wide))
        #expect(TripShareMapGeometry.resolution(for: smallFrame) > TripShareMapGeometry.resolution(for: wideFrame))
        #expect(small.map(\.isBase) == [true, true])
    }
}
