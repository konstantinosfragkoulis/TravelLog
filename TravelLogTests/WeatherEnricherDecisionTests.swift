//
//  WeatherEnricherDecisionTests.swift
//  TravelLogTests
//
//  Decision logic of `WeatherEnricher`. Most of the suite covers the three
//  fixture-able helpers that carry no actor/modelContext state:
//   • mapCondition(_:)        — WeatherKit WeatherCondition → StayWeather.Condition
//                               (regression guard that the table stays exhaustive
//                               over today's 34 SDK cases; family-collapse rules).
//   • computeDayKey(for:)     — the UTC day in the weather cache key (INV-C): UTC startOfDay,
//                               idempotent, timezone-stable across CloudKit peers.
//   • isPermanentlyUnavailable(_:) — the pre-2021-08-01 terminal `.unavailable`
//                               boundary (INV-A pre-floor), strict `<` at the floor.
//  It also covers the Wrapped weather sprint-year decision
//  (`currentSprintYear(now:calendar:)`), an actor method the sprint tests await.
//
//  `@MainActor` because `isPermanentlyUnavailable` builds/reads a `@Model` `Stay`,
//  which is MainActor-isolated under the app target's MainActor-by-default
//  setting; the pure value tests (mapCondition/computeDayKey) ride along
//  harmlessly. Calls to the three helpers are synchronous (no `await`) because
//  they are `nonisolated`, the same precedent as `YearWrappedGenerator.computeDaysAbroad`.
//

import Testing
import Foundation
import SwiftData
import WeatherKit
@testable import TravelLog

@MainActor
struct WeatherEnricherDecisionTests {

    private func enricher() throws -> WeatherEnricher {
        WeatherEnricher(modelContainer: try TestSupport.makeInMemoryContainer())
    }

    /// UTC date — matches the UTC gregorian calendar `computeDayKey` uses.
    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, _ s: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    /// A minimal `Stay` whose only field the predicate-under-test reads is `endTime`.
    private func makeStay(end: Date) -> Stay {
        Stay(startTime: end.addingTimeInterval(-3600), endTime: end,
             centroidLatitude: 0, centroidLongitude: 0,
             h3IndexRes6: "h", pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
    }

    @Test("Wrapped weather sprints use the Gregorian year in the device zone")
    func sprintYearUsesLocalGregorianCalendar() async throws {
        let sut = try enricher()
        for identifier in [Calendar.Identifier.buddhist, .japanese] {
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = TimeZone(secondsFromGMT: 2 * 3600)!
            // October in UTC, November in the device zone.
            #expect(await sut.currentSprintYear(now: utc(2026, 10, 31, 23), calendar: calendar) == 2026)
            #expect(await sut.currentSprintYear(now: utc(2026, 10, 31, 20), calendar: calendar) == nil)
        }
    }

    @Test("a Gregorian Wrapped row stops a sprint on a Buddhist-calendar device")
    func existingWrappedStopsGregorianSprint() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(YearWrapped(year: 2026))
        try context.save()
        let sut = WeatherEnricher(modelContainer: container)
        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(await sut.currentSprintYear(now: utc(2026, 11, 15), calendar: calendar) == nil)
    }

    // MARK: - mapCondition: exhaustiveness

    @Test("every WeatherKit condition maps to a non-.unknown StayWeather condition (regression guard against a future unmapped SDK case)")
    func everyWeatherKitConditionMapsToANonUnknownStayCondition() throws {
        let sut = try enricher()
        for wc in WeatherCondition.allCases {
            #expect(sut.mapCondition(wc) != .unknown, "\(wc) fell through to .unknown")
        }
    }

    // MARK: - mapCondition: family collapse

    @Test("clear family collapses to .clear (mostlyClear folded in)",
          arguments: [WeatherCondition.clear, .mostlyClear])
    func clearFamilyCollapsesToClear(wc: WeatherCondition) throws {
        let sut = try enricher()
        #expect(sut.mapCondition(wc) == .clear)
    }

    @Test("cloudy family collapses to .cloudy; partlyCloudy stays distinct",
          arguments: [WeatherCondition.cloudy, .mostlyCloudy])
    func cloudyFamilyCollapsesToCloudy(wc: WeatherCondition) throws {
        let sut = try enricher()
        #expect(sut.mapCondition(wc) == .cloudy)
        #expect(sut.mapCondition(.partlyCloudy) == .partlyCloudy)
    }

    @Test("drizzle family maps to .drizzle",
          arguments: [WeatherCondition.drizzle, .freezingDrizzle])
    func drizzleFamilyMapsToDrizzle(wc: WeatherCondition) throws {
        let sut = try enricher()
        #expect(sut.mapCondition(wc) == .drizzle)
    }

    @Test("rain family maps to .rain; heavyRain stays distinct",
          arguments: [WeatherCondition.rain, .freezingRain, .sunShowers])
    func rainFamilyMapsToRain(wc: WeatherCondition) throws {
        let sut = try enricher()
        #expect(sut.mapCondition(wc) == .rain)
        #expect(sut.mapCondition(.heavyRain) == .heavyRain)
    }

    @Test("all snow variants collapse to .snow",
          arguments: [WeatherCondition.snow, .heavySnow, .flurries, .sunFlurries, .blowingSnow, .blizzard])
    func allSnowVariantsCollapseToSnow(wc: WeatherCondition) throws {
        let sut = try enricher()
        #expect(sut.mapCondition(wc) == .snow)
    }

    @Test("sleet and wintry mix map to .sleet",
          arguments: [WeatherCondition.sleet, .wintryMix])
    func sleetAndWintryMixMapToSleet(wc: WeatherCondition) throws {
        let sut = try enricher()
        #expect(sut.mapCondition(wc) == .sleet)
    }

    @Test("all storm variants collapse to .thunderstorms",
          arguments: [WeatherCondition.thunderstorms, .scatteredThunderstorms, .isolatedThunderstorms,
                      .strongStorms, .hail, .hurricane, .tropicalStorm])
    func allStormVariantsCollapseToThunderstorms(wc: WeatherCondition) throws {
        let sut = try enricher()
        #expect(sut.mapCondition(wc) == .thunderstorms)
    }

    @Test("fog/haze/windy/hot/cold singletons map directly; haze family grouped; frigid→cold")
    func fogHazeWindyHotColdMapDirectly() throws {
        let sut = try enricher()
        #expect(sut.mapCondition(.foggy) == .fog)
        #expect(sut.mapCondition(.haze) == .haze)
        #expect(sut.mapCondition(.smoky) == .haze)
        #expect(sut.mapCondition(.blowingDust) == .haze)
        #expect(sut.mapCondition(.windy) == .windy)
        #expect(sut.mapCondition(.breezy) == .windy)
        #expect(sut.mapCondition(.hot) == .hot)
        #expect(sut.mapCondition(.frigid) == .cold)
    }

    // MARK: - computeDayKey: UTC stability + idempotence (INV-C)

    @Test("computeDayKey truncates to UTC start-of-day, discarding the time component")
    func computeDayKeyIsUTCStartOfDay() throws {
        let sut = try enricher()
        #expect(sut.computeDayKey(for: utc(2026, 6, 15, 14)) == utc(2026, 6, 15, 0))
    }

    @Test("computeDayKey is idempotent — re-deriving the key yields the same key")
    func computeDayKeyIsIdempotent() throws {
        let sut = try enricher()
        let once = sut.computeDayKey(for: utc(2026, 6, 15, 14, 37, 12))
        #expect(sut.computeDayKey(for: once) == once)
    }

    @Test("two instants on the same UTC day share one dayKey; one second into the next day differs")
    func sameUTCDayDifferentTimesShareOneDayKey() throws {
        let sut = try enricher()
        let early = sut.computeDayKey(for: utc(2026, 6, 15, 0, 1))
        let late  = sut.computeDayKey(for: utc(2026, 6, 15, 23, 59))
        #expect(early == late)
        let nextDay = sut.computeDayKey(for: utc(2026, 6, 16, 0, 0, 1))
        #expect(nextDay != early)
    }

    @Test("computeDayKey keys on a fixed UTC frame (not Calendar.current), so keys are stable across devices")
    func computeDayKeyCrossesUTCMidnightNotLocalMidnight() throws {
        let sut = try enricher()
        // Just before UTC midnight → that UTC day.
        let beforeMidnight = sut.computeDayKey(for: utc(2026, 6, 15, 23, 59, 59))
        #expect(beforeMidnight == utc(2026, 6, 15, 0))
        // Just after UTC midnight → the next UTC day.
        let afterMidnight = sut.computeDayKey(for: utc(2026, 6, 16, 0, 0, 1))
        #expect(afterMidnight == utc(2026, 6, 16, 0))
        #expect(beforeMidnight != afterMidnight)
    }

    // MARK: - isPermanentlyUnavailable: pre-2021-08-01 floor (INV-A)

    @Test("a stay ending before 2021-08-01 UTC is permanently unavailable (terminal .unavailable)")
    func preFloorStayIsPermanentlyUnavailable() throws {
        let sut = try enricher()
        let stay = makeStay(end: utc(2021, 7, 31))
        #expect(sut.isPermanentlyUnavailable(stay) == true)
    }

    @Test("boundary: a stay ending exactly at 2021-08-01 00:00 UTC is NOT permanently unavailable (strict <)")
    func atFloorStayIsNotPermanentlyUnavailable() throws {
        let sut = try enricher()
        let stay = makeStay(end: utc(2021, 8, 1, 0, 0, 0))
        #expect(sut.isPermanentlyUnavailable(stay) == false)
    }

    @Test("a modern stay (2026) is NOT permanently unavailable — eligible for WeatherKit")
    func postFloorStayIsNotPermanentlyUnavailable() throws {
        let sut = try enricher()
        let stay = makeStay(end: utc(2026, 6, 1))
        #expect(sut.isPermanentlyUnavailable(stay) == false)
    }
}
