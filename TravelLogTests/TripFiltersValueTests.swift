//
//  TripFiltersValueTests.swift
//  TravelLogTests
//
//  Value-type behavior of TripFilters (the trips-list filter set):
//  isActive dimension accounting, and Codable +
//  Equatable round-tripping (the same encode/decode logic the persisted
//  "tripFiltersJSON" blob relies on, exercised here directly via
//  JSONEncoder/Decoder to avoid mutating shared UserDefaults). TripFilters
//  is a plain Sendable struct (no @Model), so this suite is NOT @MainActor.
//

import Testing
import Foundation
@testable import TravelLog

struct TripFiltersValueTests {

    // MARK: - isActive

    @Test("a default-constructed filter is inactive")
    func defaultFilterIsInactive() {
        let f = TripFilters()
        #expect(f.isActive == false)
    }

    @Test("setting any single dimension flips isActive to true")
    func isActiveTrueWhenAnySingleDimensionSet() {
        var years = TripFilters(); years.years = [2024]
        #expect(years.isActive == true)

        var countries = TripFilters(); countries.countryCodes = ["GR"]
        #expect(countries.isActive == true)

        var durations = TripFilters(); durations.durations = [.week]
        #expect(durations.isActive == true)

        var photos = TripFilters(); photos.requiresPhotos = true
        #expect(photos.isActive == true)
    }

    // MARK: - Codable round-trip

    @Test("Codable round-trip preserves all dimensions (decoded == original)")
    func codableRoundTripPreservesAllDimensions() throws {
        var original = TripFilters()
        original.years = [2022, 2024]
        original.countryCodes = ["GR", "IT", "FR"]
        original.durations = [.weekend, .week, .long]
        original.requiresPhotos = true

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TripFilters.self, from: data)
        #expect(decoded == original)
    }

    @Test("a FROZEN saved-filters JSON blob still decodes (UserDefaults compat)")
    func frozenSavedFiltersBlobStillDecodes() throws {
        // Hand-written fixture in the on-disk shape `saveToDefaults` produced
        // when this test was frozen (2026-08-08). A current-encoder round trip
        // cannot catch a field/token rename breaking every user's SAVED
        // filters — this fixture can (frozen inputs for
        // compatibility, not self round-trips).
        let frozen = Data("""
        {"years":[2022,2024],"countryCodes":["GR","IT"],"durations":["weekend","long"],"requiresPhotos":true}
        """.utf8)
        let decoded = try JSONDecoder().decode(TripFilters.self, from: frozen)
        #expect(decoded.years == [2022, 2024])
        #expect(decoded.countryCodes == ["GR", "IT"])
        #expect(decoded.durations == [.weekend, .long])
        #expect(decoded.requiresPhotos == true)
    }
}
