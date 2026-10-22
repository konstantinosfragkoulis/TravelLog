import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct TripDisplayTextTests {
    private func date(_ string: String, zone: String = "Europe/Lisbon") -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return formatter.date(from: string)!
    }

    @Test("Nights count calendar days in the stop's own zone")
    func nightsInStopZone() {
        let lisbon = TimeZone(identifier: "Europe/Lisbon")!
        #expect(TripDisplayText.nights(from: date("2026-09-12T15:00:00"), to: date("2026-09-16T10:00:00"), timeZone: lisbon) == 4)
        #expect(TripDisplayText.nights(from: date("2026-09-14T09:00:00"), to: date("2026-09-14T18:00:00"), timeZone: lisbon) == 0)
        // 23:30 to 00:30 in Lisbon crosses a midnight there.
        #expect(TripDisplayText.nights(from: date("2026-09-14T23:30:00"), to: date("2026-09-15T00:30:00"), timeZone: lisbon) == 1)
        #expect(TripDisplayText.nights(from: date("2026-09-15T10:00:00"), to: date("2026-09-14T10:00:00"), timeZone: lisbon) == 0)
    }

    @Test("Same-month ranges drop the start month only where the day comes first")
    func rangeCompactsOnlyDayFirstLocales() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let start = date("2026-09-12T12:00:00", zone: "UTC")
        let end = date("2026-09-20T12:00:00", zone: "UTC")
        let nextMonthStart = date("2026-09-28T12:00:00", zone: "UTC")
        let nextMonthEnd = date("2026-10-03T12:00:00", zone: "UTC")

        for identifier in ["ja_JP", "zh_Hans_CN", "zh_Hant_TW", "ko_KR", "en_GB", "el_GR"] {
            let locale = Locale(identifier: identifier)
            let base = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            let dayMonth = base.day().month(.abbreviated)
            let dayFirst = !identifier.hasPrefix("ja") && !identifier.hasPrefix("zh") && !identifier.hasPrefix("ko")

            let sameMonth = TripDisplayText.range(from: start, to: end, includeYear: false, calendar: calendar, locale: locale)
            #expect(sameMonth.hasSuffix(dayMonth.format(end)), "\(identifier): \(sameMonth)")
            if dayFirst {
                #expect(sameMonth.hasPrefix(base.day().format(start)), "\(identifier): \(sameMonth)")
                #expect(!sameMonth.contains(dayMonth.format(start)), "\(identifier): \(sameMonth)")
            } else {
                #expect(sameMonth.hasPrefix(dayMonth.format(start)), "\(identifier): \(sameMonth)")
            }

            let crossMonth = TripDisplayText.range(from: nextMonthStart, to: nextMonthEnd, includeYear: false, calendar: calendar, locale: locale)
            #expect(crossMonth.hasPrefix(dayMonth.format(nextMonthStart)), "\(identifier): \(crossMonth)")
            #expect(crossMonth.hasSuffix(dayMonth.format(nextMonthEnd)), "\(identifier): \(crossMonth)")
        }

        let japanese = TripDisplayText.range(from: start, to: end, includeYear: false, calendar: calendar, locale: Locale(identifier: "ja_JP"))
        #expect(japanese.hasPrefix("9月12日"))
    }

    @Test("Overnight stops count nights; shorter stops read their time there")
    func stopLengthPhrases() {
        #expect(TripDisplayText.nightsPhrase(1) == "1 night")
        #expect(TripDisplayText.nightsPhrase(4) == "4 nights")
        #expect(TripDisplayText.stopDuration(minutes: 0) == "0 min")
        #expect(TripDisplayText.stopDuration(minutes: 40) == "40 min")
        #expect(TripDisplayText.stopDuration(minutes: 59) == "59 min")
        #expect(TripDisplayText.stopDuration(minutes: 60) == "1h")
        #expect(TripDisplayText.stopDuration(minutes: 180) == "3h")
        #expect(TripDisplayText.stopDuration(minutes: 185) == "3h 05m")
        #expect(TripDisplayText.stopDuration(minutes: 215) == "3h 35m")
        #expect(TripDisplayText.stopDuration(minutes: 100) == "1h 40m")
    }

    @Test("Year sections keep the given order and split by start year")
    func groupedByYear() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        let starts = ["2026-09-12T10:00:00", "2026-04-02T10:00:00", "2025-12-30T10:00:00", "2024-05-01T10:00:00"]
        let trips = starts.map { start -> Trip in
            let trip = Trip(startDate: date(start, zone: "UTC"))
            context.insert(trip)
            return trip
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let groups = TripsListView.groupedByYear(trips, calendar: calendar)
        #expect(groups.map(\.year) == [2026, 2025, 2024])
        #expect(groups.map(\.trips.count) == [2, 1, 1])
        #expect(groups[0].trips.map(\.id) == [trips[0].id, trips[1].id])
    }

    @Test("Stamps print the alpha-3 code and take their shape from the continent")
    func stampCodeAndShape() {
        #expect(CountryAlpha3.code(for: "PT") == "PRT")
        #expect(CountryAlpha3.code(for: "gb") == "GBR")
        #expect(CountryAlpha3.code(for: "JPN") == "JPN")
        #expect(CountryAlpha3.code(for: "ZZ") == "ZZ")
        #expect(PassportStamp.shape(for: "PT") == .circle)
        #expect(PassportStamp.shape(for: "CY") == .circle)
        #expect(PassportStamp.shape(for: "JP") == .hexagon)
        #expect(PassportStamp.shape(for: "MA") == .roundedRectangle)
        #expect(PassportStamp.shape(for: "US") == .roundedRectangle)
        #expect(PassportStamp.shape(for: "AU") == .roundedRectangle)
        #expect(PassportStamp.rotation(for: "PT") == -6)
        #expect(PassportStamp.rotation(for: "BR") == PassportStamp.rotation(for: "BRA"))
        #expect(PassportStamp.rotation(for: "BR") != 0)
    }
}
