import Testing
import Foundation
@testable import TravelLog

@MainActor
struct YearFilterPresetTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @Test func lastYearMeansPreviousCalendarYear() {
        #expect(YearFilterPicker.presetYears(count: 1, now: date(2026, 6, 15), calendar: calendar) == [2025])
    }

    @Test(arguments: [1, 12])
    func lastThreeYearsIncludeCurrentYearAtBothYearBoundaries(month: Int) {
        let now = date(2026, month, month == 1 ? 1 : 31)
        #expect(YearFilterPicker.presetYears(count: 3, now: now, calendar: calendar) == [2024, 2025, 2026])
    }

    @Test func lastFiveYearsIncludeCurrentYear() {
        #expect(YearFilterPicker.presetYears(count: 5, now: date(2026, 6, 15), calendar: calendar)
                == [2022, 2023, 2024, 2025, 2026])
    }

    @Test(arguments: [1, 3, 5])
    func presetsNeverIncludeFutureYears(count: Int) {
        let now = date(2026, 1, 1)
        let years = YearFilterPicker.presetYears(count: count, now: now, calendar: calendar)
        #expect(years.count == count)
        #expect(years.allSatisfy { $0 <= calendar.component(.year, from: now) })
    }

    @Test func sharedYearCalendarProducesGregorianPresets() {
        #expect(YearFilterPicker.presetYears(count: 3, now: date(2026, 6, 15), calendar: TripFilters.yearCalendar)
                == [2024, 2025, 2026])
    }
}
