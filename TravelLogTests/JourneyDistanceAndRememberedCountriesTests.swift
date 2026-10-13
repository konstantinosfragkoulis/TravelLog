//
//  JourneyDistanceAndRememberedCountriesTests.swift
//  TravelLogTests
//
//  Pins two pure helpers added in the June-2026 stats-accuracy pass:
//
//  1. `YearWrappedGenerator.journeyDistanceKm`, the geometric yearly
//     total that replaced the inference-bound sum, because
//     `distanceFromPreviousKm` only exists for legs the 7-day CoreMotion
//     window attributed. Verifies leg summation, the commute exclusion
//     (home/routine → home/routine legs don't count), and edge cases.
//
//  2. `RememberedCountriesStorage` normalization: synced KVS blobs may
//     contain garbage from older builds or hand edits; invalid codes must
//     not become phantom passport countries.
//

import Testing
import Foundation
@testable import TravelLog

struct JourneyDistanceTests {

    // Athens to Ioánnina is about 311 km, a stable fixture.
    private let athens = (lat: 37.9838, lon: 23.7275)
    private let ioannina = (lat: 39.6628, lon: 20.8612)

    private func row(_ coords: (lat: Double, lon: Double), local: Bool = false)
        -> (latitude: Double, longitude: Double, isLocal: Bool) {
        (latitude: coords.lat, longitude: coords.lon, isLocal: local)
    }

    @Test("a single out-and-back sums both legs (about 622 km through Ioánnina)")
    func outAndBackSumsBothLegs() {
        let total = YearWrappedGenerator.journeyDistanceKm(of: [
            row(athens, local: true),
            row(ioannina),
            row(athens, local: true)
        ])
        #expect(total > 580 && total < 640)
    }

    @Test("legs between two local stays (home/routine commutes) are excluded")
    func commuteLegsExcluded() {
        // home → routine → home → routine: every leg is local↔local.
        let nearAthens = (lat: 38.05, lon: 23.80)
        let total = YearWrappedGenerator.journeyDistanceKm(of: [
            row(athens, local: true),
            row(nearAthens, local: true),
            row(athens, local: true),
            row(nearAthens, local: true)
        ])
        #expect(total == 0)
    }

    @Test("a local→destination leg counts even though one endpoint is local")
    func mixedLegCounts() {
        let total = YearWrappedGenerator.journeyDistanceKm(of: [
            row(athens, local: true),
            row(ioannina, local: false)
        ])
        #expect(total > 290 && total < 320)
    }

    @Test("empty and single-stay inputs yield zero")
    func degenerateInputs() {
        #expect(YearWrappedGenerator.journeyDistanceKm(of: []) == 0)
        #expect(YearWrappedGenerator.journeyDistanceKm(of: [row(athens)]) == 0)
    }
}

struct RememberedCountriesNormalizationTests {

    @Test("normalization uppercases, dedupes, and drops invalid codes")
    func normalizationFiltersGarbage() {
        let result = RememberedCountriesStorage.normalized(
            ["gr", "GR", "JP", "j", "jpn", "12", "G R", "", "us"]
        )
        #expect(result == ["GR", "JP", "US"])
    }

    @Test("isValidCode accepts two uppercase letters that name a real country")
    func validCodeBoundaries() {
        #expect(RememberedCountriesStorage.isValidCode("GR"))
        #expect(!RememberedCountriesStorage.isValidCode("gr"))
        #expect(!RememberedCountriesStorage.isValidCode("GRC"))
        #expect(!RememberedCountriesStorage.isValidCode("G1"))
        #expect(!RememberedCountriesStorage.isValidCode(""))
        // Supranational CLDR codes are shape-valid but not countries;
        // `Locale.Region.isoRegions` carries them and they rendered as
        // "European Union"/"Eurozone"/"United Nations" in the picker.
        // `CountryCatalog` membership kills them.
        #expect(!RememberedCountriesStorage.isValidCode("EU"))
        #expect(!RememberedCountriesStorage.isValidCode("EZ"))
        #expect(!RememberedCountriesStorage.isValidCode("UN"))
        // Real territories stay selectable.
        #expect(RememberedCountriesStorage.isValidCode("PR"))
    }

    @Test("the widget mirror reports a change only when the stored set differs")
    func widgetMirrorWriteReportsChanges() throws {
        let suite = "test.mirror.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(RememberedCountriesStorage.writeMirror(["FR", "GR"], to: defaults))
        #expect(!RememberedCountriesStorage.writeMirror(["FR", "GR"], to: defaults))
        #expect(RememberedCountriesStorage.writeMirror(["FR"], to: defaults))
        #expect(RememberedCountriesStorage.writeMirror([], to: defaults))
        #expect(!RememberedCountriesStorage.writeMirror([], to: defaults))

        let data = try #require(defaults.data(forKey: RememberedCountriesStorage.appGroupMirrorKey))
        #expect(try JSONDecoder().decode([String].self, from: data) == [])
    }

    @Test("search ignores case and diacritics and matches the region code")
    func searchIgnoresCaseAndDiacritics() {
        // The Greek name is the app-language name, so the Greek UI is passed.
        #expect(RememberedCountriesPicker.matchesSearch(code: "GR", query: "ελλαδα", languageTag: "el"))
        #expect(RememberedCountriesPicker.matchesSearch(code: "RE", query: "reunion", languageTag: "en"))
        #expect(RememberedCountriesPicker.matchesSearch(code: "CW", query: "curacao", languageTag: "en"))
        #expect(RememberedCountriesPicker.matchesSearch(code: "GR", query: "gr", languageTag: "en"))
        #expect(!RememberedCountriesPicker.matchesSearch(code: "GR", query: "spain", languageTag: "en"))
    }
}
