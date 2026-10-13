//
//  HexHighlightRequestTests.swift
//  TravelLogTests
//
//  Pure-function tests for the Stats → Map hex-highlight matcher:
//  country selection by ISO code and the new-this-year boundary (the
//  calendar-year start must include Jan 1 of the current year and exclude
//  Dec 31 of the previous one).
//

import Testing
import Foundation
@testable import TravelLog

struct HexHighlightRequestTests {

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Self.utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func row(_ h3: String, iso: String?, first: Date) -> HexHighlightRequest.HexRow {
        HexHighlightRequest.HexRow(h3Index: h3, isoCountryCode: iso, firstVisited: first)
    }

    @Test("country request selects exactly the matching ISO rows; nil-ISO rows never match")
    func countryMatching() {
        let rows = [
            row("hexA", iso: "GR", first: date(2024, 5, 1)),
            row("hexB", iso: "GR", first: date(2022, 1, 1)),
            row("hexC", iso: "JP", first: date(2024, 5, 1)),
            row("hexD", iso: nil, first: date(2024, 5, 1))
        ]
        let matched = HexHighlightRequest.country(code: "GR", name: "Greece")
            .matchingHexIndices(in: rows, now: date(2026, 6, 10), calendar: Self.utc)
        #expect(matched == ["hexA", "hexB"])
    }

    @Test("newThisYear includes Jan 1 of the current year and excludes Dec 31 of the previous")
    func newThisYearBoundary() {
        let rows = [
            row("janFirst", iso: "GR", first: date(2026, 1, 1)),
            row("midYear", iso: "GR", first: date(2026, 6, 9)),
            row("decLast", iso: "GR", first: date(2025, 12, 31)),
            row("ancient", iso: "JP", first: date(2019, 3, 3))
        ]
        let matched = HexHighlightRequest.newThisYear
            .matchingHexIndices(in: rows, now: date(2026, 6, 10), calendar: Self.utc)
        #expect(matched == ["janFirst", "midYear"])
    }

    @Test("newThisYear uses the Gregorian year even when the device calendar is not Gregorian")
    func newThisYearIgnoresDeviceCalendarSystem() {
        let rows = [
            row("persianYear", iso: "GR", first: date(2025, 6, 1)),
            row("decLast", iso: "GR", first: date(2025, 12, 31)),
            row("janSecond", iso: "GR", first: date(2026, 1, 2))
        ]
        var persian = Calendar(identifier: .persian)
        persian.timeZone = TimeZone(identifier: "UTC")!
        let persianMatched = HexHighlightRequest.newThisYear
            .matchingHexIndices(in: rows, now: date(2026, 2, 10), calendar: persian)
        #expect(persianMatched == ["janSecond"])

        var hebrew = Calendar(identifier: .hebrew)
        hebrew.timeZone = TimeZone(identifier: "UTC")!
        let hebrewRows = [row("march", iso: "GR", first: date(2026, 3, 1))]
        let hebrewMatched = HexHighlightRequest.newThisYear
            .matchingHexIndices(in: hebrewRows, now: date(2026, 10, 1), calendar: hebrew)
        #expect(hebrewMatched == ["march"])
    }

    @Test("empty input yields empty sets for both request kinds")
    func emptyInput() {
        let now = date(2026, 6, 10)
        #expect(HexHighlightRequest.newThisYear.matchingHexIndices(in: [], now: now, calendar: Self.utc).isEmpty)
        #expect(HexHighlightRequest.country(code: "GR", name: nil).matchingHexIndices(in: [], now: now, calendar: Self.utc).isEmpty)
    }

    @Test("labels: country prefers the locale's region name over the stored one; newThisYear is fixed")
    func labels() {
        let localized = AppLanguagePreference.currentLocale().localizedString(forRegionCode: "GR")
        #expect(localized != nil)
        #expect(HexHighlightRequest.country(code: "GR", name: "Hellas").label == localized)
        #expect(HexHighlightRequest.country(code: "GR", name: nil).label == localized)
        if AppLanguagePreference.currentLocale().localizedString(forRegionCode: "ZZZ") == nil {
            #expect(HexHighlightRequest.country(code: "ZZZ", name: "Somewhere").label == "Somewhere")
            #expect(HexHighlightRequest.country(code: "ZZZ", name: nil).label == "ZZZ")
        }
        #expect(HexHighlightRequest.newThisYear.label == "New this year")
    }
}
