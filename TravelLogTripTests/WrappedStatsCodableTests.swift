//
//  WrappedStatsCodableTests.swift
//  TravelLogTests
//
//  YearWrappedGenerator subsystem — the `WrappedStats` Codable blob persisted
//  in `YearWrapped.statsData`. Pins the default-value contract (relied on for
//  backwards-compatible decode of older blobs), the lossless JSON round-trip,
//  the try?-swallow contract (corrupt/empty blob → nil, never a crash), and the
//  forward-compatible "missing keys decode to defaults" migration property.
//  NOT @MainActor: `WrappedStats` is a `nonisolated struct` — no `@Model` type
//  is touched and no container is created.
//

import Testing
import Foundation
@testable import TravelLog

struct WrappedStatsCodableTests {

    /// A representative mix of scalar, optional, and array fields, exercising
    /// every category of property the round-trip must preserve.
    private func sampleStats() -> WrappedStats {
        var s = WrappedStats()
        s.countriesVisited = 7
        s.citiesVisited = 19
        s.totalDaysAbroad = 42
        s.totalHexesVisited = 311
        s.longestTripName = "Greek Islands"
        s.longestTripDays = 9
        s.longestTripStartDate = Date(timeIntervalSinceReferenceDate: 3)
        s.farthestDistanceKm = 9500.9
        s.farthestPlaceName = "Tokyo"
        s.hottestTempC = 34.5
        s.hottestLocality = "Athens"
        s.coldestTempC = -3.2
        s.coldestLocality = "Oslo"
        s.rainiestTripName = "Bergen"
        s.rainiestPrecipitationMm = 88.0
        s.flightKm = 12000.0
        s.driveKm = 800.5
        s.walkKm = 14.2
        s.totalGreatCircleKm = 12814.7
        s.newCountryCodes = ["GR", "IT", "FR"]
        s.mostVisitedCountryCode = "GR"
        s.mostVisitedCountryTripCount = 4
        s.daysAbroad = 42
        s.daysAtHome = 323
        s.mysteryFactText = "You returned to Athens 3 times this year."
        s.mysteryFact = .returnedCity(name: "Athens", times: 3)
        s.narrativeInputs = NarrativeInputs(
            year: 2026,
            tripDisplayNames: ["Vienna", "Tokyo"],
            tripStartDates: [Date(timeIntervalSinceReferenceDate: 1), Date(timeIntervalSinceReferenceDate: 2)],
            longestTripName: "Greek Islands",
            longestTripDays: 9,
            farthestPlaceName: "Tokyo",
            farthestDistanceKm: 9500.9,
            firstTimeCountryISOCodes: ["GR", "IT", "FR"]
        )
        s.tripsCompleted = 11
        return s
    }

    // MARK: - Defaults contract

    @Test("a freshly initialized WrappedStats has all-zero scalars, empty arrays, and nil optionals")
    func defaultsAreZeroAndEmpty() {
        let s = WrappedStats()
        // Int fields
        #expect(s.countriesVisited == 0)
        #expect(s.citiesVisited == 0)
        #expect(s.totalDaysAbroad == 0)
        #expect(s.totalHexesVisited == 0)
        #expect(s.longestTripDays == 0)
        #expect(s.mostVisitedCountryTripCount == 0)
        #expect(s.daysAbroad == 0)
        #expect(s.daysAtHome == 0)
        #expect(s.tripsCompleted == 0)
        // Double fields
        #expect(s.farthestDistanceKm == 0)
        #expect(s.flightKm == 0)
        #expect(s.driveKm == 0)
        #expect(s.walkKm == 0)
        #expect(s.totalGreatCircleKm == 0)
        // Array field
        #expect(s.newCountryCodes == [])
        // Optionals
        #expect(s.longestTripName == nil)
        #expect(s.longestTripStartDate == nil)
        #expect(s.farthestPlaceName == nil)
        #expect(s.hottestTempC == nil)
        #expect(s.hottestLocality == nil)
        #expect(s.coldestTempC == nil)
        #expect(s.coldestLocality == nil)
        #expect(s.rainiestTripName == nil)
        #expect(s.rainiestPrecipitationMm == nil)
        #expect(s.mostVisitedCountryCode == nil)
        #expect(s.mysteryFactText == nil)
        #expect(s.mysteryFact == nil)
        #expect(s.narrativeInputs == nil)
    }

    // MARK: - Round-trip

    @Test("encode → decode round-trips every field losslessly")
    func encodeThenDecodeRoundTripsAllFields() throws {
        let original = sampleStats()
        let data = try #require(original.encoded())
        let decoded = try #require(WrappedStats.decoded(from: data))

        #expect(decoded.countriesVisited == original.countriesVisited)
        #expect(decoded.citiesVisited == original.citiesVisited)
        #expect(decoded.totalDaysAbroad == original.totalDaysAbroad)
        #expect(decoded.totalHexesVisited == original.totalHexesVisited)
        #expect(decoded.longestTripName == original.longestTripName)
        #expect(decoded.longestTripDays == original.longestTripDays)
        #expect(decoded.longestTripStartDate == original.longestTripStartDate)
        #expect(decoded.farthestDistanceKm == original.farthestDistanceKm)
        #expect(decoded.farthestPlaceName == original.farthestPlaceName)
        #expect(decoded.hottestTempC == original.hottestTempC)
        #expect(decoded.hottestLocality == original.hottestLocality)
        #expect(decoded.coldestTempC == original.coldestTempC)
        #expect(decoded.coldestLocality == original.coldestLocality)
        #expect(decoded.rainiestTripName == original.rainiestTripName)
        #expect(decoded.rainiestPrecipitationMm == original.rainiestPrecipitationMm)
        #expect(decoded.flightKm == original.flightKm)
        #expect(decoded.driveKm == original.driveKm)
        #expect(decoded.walkKm == original.walkKm)
        #expect(decoded.totalGreatCircleKm == original.totalGreatCircleKm)
        #expect(decoded.newCountryCodes == original.newCountryCodes)
        #expect(decoded.mostVisitedCountryCode == original.mostVisitedCountryCode)
        #expect(decoded.mostVisitedCountryTripCount == original.mostVisitedCountryTripCount)
        #expect(decoded.daysAbroad == original.daysAbroad)
        #expect(decoded.daysAtHome == original.daysAtHome)
        #expect(decoded.mysteryFactText == original.mysteryFactText)
        #expect(decoded.mysteryFact == original.mysteryFact)
        #expect(decoded.narrativeInputs == original.narrativeInputs)
        #expect(decoded.tripsCompleted == original.tripsCompleted)
    }

    // MARK: - try? swallow contract

    @Test("decoding garbage or empty data returns nil rather than throwing")
    func decodeOfInvalidDataReturnsNil() {
        #expect(WrappedStats.decoded(from: Data("not json".utf8)) == nil)
        #expect(WrappedStats.decoded(from: Data()) == nil)
    }

    // MARK: - Forward-compatible migration

    @Test("decode ignores unknown future keys, but requires every non-optional key")
    func decodeForwardCompatBoundary() throws {
        // Forward-compat that HOLDS: a complete blob carrying an extra unknown
        // key (a field a FUTURE app version might add) still decodes cleanly.
        var s = WrappedStats()
        s.countriesVisited = 5
        let full = try #require(s.encoded())
        var dict = try #require(try JSONSerialization.jsonObject(with: full) as? [String: Any])
        dict["someFutureFieldV99"] = 123
        let augmented = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try #require(WrappedStats.decoded(from: augmented))
        #expect(decoded.countriesVisited == 5)

        // The LIMITATION (real Swift Codable behavior): a blob MISSING a
        // non-optional key fails to decode → nil. Swift does NOT substitute the
        // property's default value. Forward-compat therefore only holds when new
        // fields are added as OPTIONAL (exactly what WrappedStats' doc prescribes).
        #expect(WrappedStats.decoded(from: Data("{\"countriesVisited\":5}".utf8)) == nil)
    }

    @Test("a card from a newer build is dropped alone; every readable card survives unchanged")
    func decodeSalvagesAroundAnUnreadableOptionalCard() throws {
        var s = sampleStats()
        let start = Date(timeIntervalSinceReferenceDate: 762_345_678.123456)
        s.narrativeInputs = NarrativeInputs(
            year: 2025, tripDisplayNames: ["Greek Islands"], tripStartDates: [start],
            longestTripName: "Greek Islands", longestTripDays: 9, farthestPlaceName: "Tokyo",
            farthestDistanceKm: 9500.9, firstTimeCountryISOCodes: ["JP"])
        let full = try #require(s.encoded())
        var dict = try #require(try JSONSerialization.jsonObject(with: full) as? [String: Any])
        dict["mysteryFact"] = ["caseFromNewerBuild": ["name": "Somewhere"]]
        let newer = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try #require(WrappedStats.decoded(from: newer))
        #expect(decoded.mysteryFact == nil)
        #expect(decoded.countriesVisited == s.countriesVisited)
        #expect(decoded.farthestDistanceKm == s.farthestDistanceKm)
        #expect(decoded.longestTripName == s.longestTripName)
        // Exact dates matter: the calendar privacy scrub keys replacement names by start date.
        #expect(decoded.narrativeInputs == s.narrativeInputs)

        // Salvage never invents required totals.
        dict.removeValue(forKey: "countriesVisited")
        let broken = try JSONSerialization.data(withJSONObject: dict)
        #expect(WrappedStats.decoded(from: broken) == nil)
    }

}
