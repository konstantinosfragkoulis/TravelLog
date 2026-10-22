//
//  WrappedMysteryFactTests.swift
//  TravelLogTests
//
//  YearWrappedGenerator subsystem, `computeMysteryFactValue(stays:destinations:trips:year:)`,
//  the Wrapped Card 9 "mystery fact" selector. Pins the three candidate
//  generators (returned-to-city: distinct trip ids >= 3, weighted count*2;
//  airport-days: summed airport durationMinutes / (60*24) >= 1, weighted days*3;
//  shortest-trip: durationDays <= 2, flat weight 4), their grammar (singular vs
//  plural day(s)), the "Unknown" grouping fallback, and the highest-score wins
//  selection.
//  @MainActor because it constructs `Stay`/`Trip` `@Model` objects and a
//  `@ModelActor`. `computeMysteryFactValue` is assumed `nonisolated` (see
//  productionChangesNeeded) so it is called synchronously without `await`.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct WrappedMysteryFactTests {

    private func gen() throws -> (YearWrappedGenerator, ModelContext) {
        let container = try TestSupport.makeInMemoryContainer()
        return (YearWrappedGenerator(modelContainer: container), ModelContext(container))
    }

    /// UTC date builder, keeps trip/stay durations stable across timezones.
    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// English rendering of the selected mystery fact - what the production
    /// path stores in `stats.mysteryFactText`.
    private func mysteryFactText(
        _ g: YearWrappedGenerator,
        stays: [Stay], destinations: [Stay], trips: [Trip], year: Int
    ) -> String? {
        g.computeMysteryFactValue(
            stays: stays, destinations: destinations, trips: trips, year: year
        )?.render(locale: Locale(identifier: "en"))
    }

    /// A destination stay in a named metro, linked into a trip for the
    /// distinct-trip-id grouping.
    private func makeDestination(_ ctx: ModelContext, metro: String?, trip: Trip) -> Stay {
        let s = Stay(startTime: utc(2026, 12, 21), endTime: utc(2026, 12, 22),
                     centroidLatitude: 0, centroidLongitude: 0,
                     h3IndexRes6: "h", pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
        s.category = .destination
        s.metroName = metro
        ctx.insert(s)
        s.trip = trip
        return s
    }

    /// An airport stay whose `durationMinutes` is derived from start/end.
    private func makeAirportStay(_ ctx: ModelContext, minutes: Int) -> Stay {
        let start = utc(2026, 12, 21, 0)
        let end = start.addingTimeInterval(TimeInterval(minutes) * 60)
        let s = Stay(startTime: start, endTime: end,
                     centroidLatitude: 0, centroidLongitude: 0,
                     h3IndexRes6: "h", pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
        s.isAirport = true
        ctx.insert(s)
        return s
    }

    /// A completed trip with a deterministic `displayName` (via customName) and a
    /// duration in calendar days controlled by start/end (durationDays inclusive).
    private func makeTrip(_ ctx: ModelContext, name: String, days: Int) -> Trip {
        let start = utc(2026, 12, 21)
        // durationDays = (end - start in days) + 1, clamped to >= 1 → end = start + (days-1)
        let end = Calendar.current.date(byAdding: .day, value: max(0, days - 1), to: start)!
        let t = Trip(startDate: start)
        t.endDate = end
        t.isComplete = true
        t.customName = name
        ctx.insert(t)
        return t
    }

    // MARK: - No data

    @Test("structured mystery facts render byte-identically to legacy English")
    func structuredMysteryFactEnglishParityMatrix() {
        let fixtures: [(fact: MysteryFact, legacy: String)] = [
            (.returnedCity(name: "Athens", times: 3), "You visited Athens on 3 trips this year."),
            (.airportDays(count: 1), "You spent 1 day in airports this year."),
            (.airportDays(count: 4), "You spent 4 days in airports this year."),
            (.shortestTrip(name: "Milan", days: 1), "Your shortest trip was 1 day to Milan."),
            (.shortestTrip(name: "Rome", days: 2), "Your shortest trip was 2 days to Rome.")
        ]

        for fixture in fixtures {
            #expect(fixture.fact.render(locale: Locale(identifier: "en")) == fixture.legacy)
        }
    }

    @Test("mystery display prefers a typed fact and preserves legacy stored prose")
    func mysteryDisplayResolverTruthTable() {
        var stats = WrappedStats()
        stats.mysteryFactText = "Stored legacy fact."
        #expect(WrappedDisplayResolver.resolvedMysteryFact(
            stats: stats,
            locale: Locale(identifier: "en")
        ) == "Stored legacy fact.")

        stats.mysteryFact = .airportDays(count: 1)
        #expect(WrappedDisplayResolver.resolvedMysteryFact(
            stats: stats,
            locale: Locale(identifier: "en")
        ) == "You spent 1 day in airports this year.")
    }

    @Test("production app locales preserve Portuguese Wrapped variants")
    func portugueseMysteryVariantsRemainDistinct() {
        var stats = WrappedStats()
        stats.mysteryFact = .airportDays(count: 4)
        let brazil = AppLanguagePreference.locale(
            for: "pt-BR",
            regionalLocale: Locale(identifier: "en_US"))
        let portugal = AppLanguagePreference.locale(
            for: "pt-PT",
            regionalLocale: Locale(identifier: "en_US"))

        let brazilian = WrappedDisplayResolver.resolvedMysteryFact(
            stats: stats,
            locale: brazil)
        let european = WrappedDisplayResolver.resolvedMysteryFact(
            stats: stats,
            locale: portugal)
        #expect(brazilian != european)
        #expect(brazilian?.contains("Você") == true)
        #expect(european?.contains("Passou") == true)
    }

    @Test("no qualifying data → nil")
    func noQualifyingDataReturnsNil() throws {
        let (g, _) = try gen()
        #expect(mysteryFactText(g, stays: [], destinations: [], trips: [], year: 2026) == nil)
    }

    // MARK: - Shortest trip

    @Test("a single 2-day trip yields the shortest-trip fact")
    func singleShortTripProducesShortestTripFact() throws {
        let (g, ctx) = try gen()
        let trip = makeTrip(ctx, name: "Rome", days: 2)
        #expect(trip.durationDays == 2)
        let fact = mysteryFactText(g, stays: [], destinations: [], trips: [trip], year: 2026)
        #expect(fact == "Your shortest trip was 2 days to Rome.")
        #expect(g.computeMysteryFactValue(
            stays: [], destinations: [], trips: [trip], year: 2026
        ) == .shortestTrip(name: "Rome", days: 2))
    }

    @Test("a 1-day trip uses singular 'day'")
    func shortestTripOneDaySingularGrammar() throws {
        let (g, ctx) = try gen()
        let trip = makeTrip(ctx, name: "Milan", days: 1)
        #expect(trip.durationDays == 1)
        let fact = mysteryFactText(g, stays: [], destinations: [], trips: [trip], year: 2026)
        #expect(fact == "Your shortest trip was 1 day to Milan.")
    }

    @Test("a 3-day-only trip produces no shortest-trip candidate (days <= 2 boundary)")
    func shortestTripOverTwoDaysProducesNoShortestCandidate() throws {
        let (g, ctx) = try gen()
        let trip = makeTrip(ctx, name: "Madrid", days: 3)
        #expect(trip.durationDays == 3)
        let fact = mysteryFactText(g, stays: [], destinations: [], trips: [trip], year: 2026)
        #expect(fact == nil)
    }

    // MARK: - Airport days

    @Test("airport candidate requires at least one full day (60*24-min boundary)")
    func airportDaysCandidateRequiresAtLeastOneFullDay() throws {
        // 12 hours total → 720 / (60*24) == 0 → no candidate → nil.
        let (g1, ctx1) = try gen()
        let halfDay = makeAirportStay(ctx1, minutes: 12 * 60)
        #expect(mysteryFactText(g1, stays: [halfDay], destinations: [], trips: [], year: 2026) == nil)

        // Exactly one full day (1440 minutes) → "You spent 1 day ..." (singular).
        let (g2, ctx2) = try gen()
        let fullDay = makeAirportStay(ctx2, minutes: 60 * 24)
        #expect(mysteryFactText(g2, stays: [fullDay], destinations: [], trips: [], year: 2026)
                == "You spent 1 day in airports this year.")
        #expect(g2.computeMysteryFactValue(
            stays: [fullDay], destinations: [], trips: [], year: 2026
        ) == .airportDays(count: 1))
    }

    @Test("airport days >= 2 use plural 'days' and the floored day count")
    func airportDaysPluralGrammar() throws {
        let (g, ctx) = try gen()
        // 2 days + 6 hours = 2*1440 + 360 = 3240 min → 3240 / 1440 == 2 (floored).
        let stay = makeAirportStay(ctx, minutes: 2 * 60 * 24 + 6 * 60)
        let fact = mysteryFactText(g, stays: [stay], destinations: [], trips: [], year: 2026)
        #expect(fact == "You spent 2 days in airports this year.")
    }

    // MARK: - Returned-to-city

    @Test("returned-to-city requires 3 distinct trips; 2 distinct → no candidate")
    func returnedToCityRequiresThreeDistinctTrips() throws {
        // 3 distinct trips, one Athens destination each → "...visited Athens on 3 trips..."
        let (g3, ctx3) = try gen()
        let t1 = makeTrip(ctx3, name: "T1", days: 5)
        let t2 = makeTrip(ctx3, name: "T2", days: 5)
        let t3 = makeTrip(ctx3, name: "T3", days: 5)
        let d1 = makeDestination(ctx3, metro: "Athens", trip: t1)
        let d2 = makeDestination(ctx3, metro: "Athens", trip: t2)
        let d3 = makeDestination(ctx3, metro: "Athens", trip: t3)
        let fact3 = mysteryFactText(g3,
            stays: [d1, d2, d3], destinations: [d1, d2, d3], trips: [t1, t2, t3], year: 2026)
        #expect(fact3 == "You visited Athens on 3 trips this year.")
        #expect(g3.computeMysteryFactValue(
            stays: [d1, d2, d3], destinations: [d1, d2, d3], trips: [t1, t2, t3], year: 2026
        ) == .returnedCity(name: "Athens", times: 3))

        // Only 2 distinct trips → distinct trip-id count is 2 (< 3) → no candidate.
        let (g2, ctx2) = try gen()
        let u1 = makeTrip(ctx2, name: "U1", days: 5)
        let u2 = makeTrip(ctx2, name: "U2", days: 5)
        let e1 = makeDestination(ctx2, metro: "Athens", trip: u1)
        let e2 = makeDestination(ctx2, metro: "Athens", trip: u2)
        let fact2 = mysteryFactText(g2,
            stays: [e1, e2], destinations: [e1, e2], trips: [u1, u2], year: 2026)
        #expect(fact2 == nil)
    }

    @Test("five stays sharing one trip count as one return, not five")
    func returnedCityCountsDistinctTripsNotStays() throws {
        let (g, ctx) = try gen()
        let trip = makeTrip(ctx, name: "Solo", days: 5)
        let stays = (0..<5).map { _ in makeDestination(ctx, metro: "Paris", trip: trip) }
        // distinct trip ids == 1 → below the >= 3 gate → no candidate → nil.
        let fact = mysteryFactText(g, stays: stays, destinations: stays, trips: [trip], year: 2026)
        #expect(fact == nil)
    }

    @Test("destinations without a usable name never form a returned-city fact",
          arguments: [nil, Trip.unknownDestinationSentinel] as [String?])
    func destinationsWithoutUsableNameNeverFormReturnedCity(metro: String?) throws {
        let (g, ctx) = try gen()
        let t1 = makeTrip(ctx, name: "T1", days: 5)
        let t2 = makeTrip(ctx, name: "T2", days: 5)
        let t3 = makeTrip(ctx, name: "T3", days: 5)
        let d1 = makeDestination(ctx, metro: metro, trip: t1)
        let d2 = makeDestination(ctx, metro: metro, trip: t2)
        let d3 = makeDestination(ctx, metro: metro, trip: t3)
        let fact = mysteryFactText(g,
            stays: [d1, d2, d3], destinations: [d1, d2, d3], trips: [t1, t2, t3], year: 2026)
        #expect(fact == nil)

        let airport = makeAirportStay(ctx, minutes: 60 * 24)
        let withAirport = mysteryFactText(g,
            stays: [d1, d2, d3, airport], destinations: [d1, d2, d3], trips: [t1, t2, t3], year: 2026)
        #expect(withAirport == "You spent 1 day in airports this year.")
    }

    // MARK: - Scoring / selection

    @Test("the highest-scoring candidate wins (city*2 vs airport*3 vs shortest=4)")
    func highestScoringCandidateWins() throws {
        let (g, ctx) = try gen()
        // Return-to-city across 4 distinct trips → score 4*2 = 8 (highest).
        let ct1 = makeTrip(ctx, name: "C1", days: 5)
        let ct2 = makeTrip(ctx, name: "C2", days: 5)
        let ct3 = makeTrip(ctx, name: "C3", days: 5)
        let ct4 = makeTrip(ctx, name: "C4", days: 5)
        let cd1 = makeDestination(ctx, metro: "Athens", trip: ct1)
        let cd2 = makeDestination(ctx, metro: "Athens", trip: ct2)
        let cd3 = makeDestination(ctx, metro: "Athens", trip: ct3)
        let cd4 = makeDestination(ctx, metro: "Athens", trip: ct4)
        // Airport fact of 1 day → score 1*3 = 3.
        let airport = makeAirportStay(ctx, minutes: 60 * 24)
        // Shortest trip of 1 day → flat score 4.
        let shortTrip = makeTrip(ctx, name: "Quickie", days: 1)

        let destinations = [cd1, cd2, cd3, cd4]
        let allStays = destinations + [airport]
        let trips = [ct1, ct2, ct3, ct4, shortTrip]

        let fact = mysteryFactText(g,
            stays: allStays, destinations: destinations, trips: trips, year: 2026)
        #expect(fact == "You visited Athens on 4 trips this year.")
    }

    @Test("a 2-day airport fact (score 6) outranks a 2-day shortest-trip fact (score 4)")
    func airportFactCanOutrankShortestTrip() throws {
        let (g, ctx) = try gen()
        // 2 full days of airport → score 2*3 = 6.
        let airport = makeAirportStay(ctx, minutes: 2 * 60 * 24)
        // 2-day shortest trip → flat score 4.
        let trip = makeTrip(ctx, name: "Weekend", days: 2)
        let fact = mysteryFactText(g,
            stays: [airport], destinations: [], trips: [trip], year: 2026)
        #expect(fact == "You spent 2 days in airports this year.")
    }
}
