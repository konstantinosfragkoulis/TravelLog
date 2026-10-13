//
//  TripSearchAILogicTests.swift
//  TravelLogTests
//
//  Pure-logic coverage for TripSearchAI (AI/TripSearchAI.swift). None of the
//  paths exercised here touch FoundationModels inference:
//
//    1. TripSearchAI.extractUUIDs(from:)  - RFC-4122 regex scan, Set dedup,
//       insertion-order preservation, garbage rejection, empty input.
//    2. SearchTripsTool.matches(snapshot:arguments:) - the 8-filter AND
//       intersection (country code / English-name / locality / admin-area /
//       year / month / min+max duration), including the ongoing-trip
//       (nil durationDays) short-circuit on the duration filters, the
//       search-normalized substring match (Köniz vs Koniz), place names
//       (island, metro) in the locality filter, and Gregorian years under
//       a non-Gregorian calendar.
//    3. SearchTripsTool.call(arguments:) - output formatting: prefix(40) cap,
//       the literal word "ongoing" for a nil endDate, and the
//       "[UUID] name | codes | start to end" shape.
//
//  Private symbols are reached via behavior-neutral #if DEBUG passthroughs
//  added to production (extractUUIDsForTesting, matchesForTesting,
//  argumentsForTesting). TripSnapshot has no public memberwise init, so every
//  snapshot is built from a real Trip @Model fixture via TripSnapshot(from:);
//  constructing @Model objects forces this suite onto @MainActor.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct TripSearchAILogicTests {

    // MARK: - Fixture helpers

    /// Build a date with the SAME calendar production uses for year/month
    /// extraction (`TripFilters.yearCalendar`: Gregorian, device zone), so an
    /// asserted year/month round-trips regardless of the test host's
    /// timezone or calendar.
    private func day(_ year: Int, _ month: Int, _ d: Int) -> Date {
        TripFilters.yearCalendar.date(from: DateComponents(year: year, month: month, day: d, hour: 12))!
    }

    private func makeTrip(in ctx: ModelContext, start: Date) -> Trip {
        let trip = Trip(startDate: start)
        ctx.insert(trip)
        return trip
    }

    @discardableResult
    private func addDestination(
        to trip: Trip,
        in ctx: ModelContext,
        order: Int,
        locality: String? = nil,
        admin: String? = nil,
        isoCountryCode: String? = nil,
        islandName: String? = nil
    ) -> Stay {
        let stay = Stay(startTime: trip.startDate, endTime: trip.startDate,
                        centroidLatitude: 0, centroidLongitude: 0,
                        h3IndexRes6: "8a000", pingCount: 1, distanceFromHomeKm: 0,
                        pingIDs: [])
        ctx.insert(stay)
        stay.category = .destination
        stay.locality = locality
        stay.administrativeArea = admin
        stay.isoCountryCode = isoCountryCode
        stay.islandName = islandName
        stay.trip = trip
        stay.orderInTrip = order
        return stay
    }

    /// A fully populated, COMPLETE Greece trip snapshot:
    ///   - codes "GR" -> englishCountryNames ["Greece"]
    ///   - localities ["Athens"], admin ["Attica"]
    ///   - start 2024-06-10, end 2024-06-14 -> durationDays 5 (inclusive)
    private func greeceSnapshot() throws -> TripSnapshot {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 6, 10))
        trip.countryCodes = "GR"
        trip.endDate = day(2024, 6, 14)
        trip.isComplete = true
        addDestination(to: trip, in: ctx, order: 0, locality: "Athens", admin: "Attica", isoCountryCode: "GR")
        return TripSnapshot(from: trip)
    }

    // MARK: - extractUUIDs

    @Test("extractUUIDs removes duplicates, keeping first occurrence")
    func extractDeduplicates() {
        let a = UUID()
        let b = UUID()
        // a appears twice (different letter-casing of the same value) - UUID
        // equality is case-insensitive so both parse to `a` and dedup.
        let text = "\(a.uuidString) \(b.uuidString) \(a.uuidString.lowercased())"
        let result = TripSearchAI.extractUUIDsForTesting(from: text)
        #expect(result == [a, b])
    }

    @Test("extractUUIDs preserves first-seen order even when input is reordered")
    func extractPreservesOrder() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let text = "\(third.uuidString), \(first.uuidString), \(second.uuidString)"
        let result = TripSearchAI.extractUUIDsForTesting(from: text)
        // Order follows appearance in the text, NOT creation order.
        #expect(result == [third, first, second])
    }

    @Test("extractUUIDs ignores surrounding prose and bracket decoration")
    func extractIgnoresProse() {
        let a = UUID()
        let text = "The best matches are: [\(a.uuidString)] Athens trip. NONE others."
        let result = TripSearchAI.extractUUIDsForTesting(from: text)
        #expect(result == [a])
    }

    @Test("extractUUIDs returns empty for non-UUID garbage")
    func extractRejectsGarbage() {
        // A short hex run, a too-short group, and a word are all non-matches.
        let text = "deadbeef, 1234-5678, not-a-uuid, NONE"
        let result = TripSearchAI.extractUUIDsForTesting(from: text)
        #expect(result.isEmpty)
    }

    @Test("extractUUIDs returns empty for empty input")
    func extractEmptyInput() {
        #expect(TripSearchAI.extractUUIDsForTesting(from: "").isEmpty)
    }

    // MARK: - matches: single filters (positive + negative)

    @Test("country-code filter: matches the visited code, rejects others")
    func matchesCountryCode() throws {
        let snap = try greeceSnapshot()
        let tool = SearchTripsTool(snapshots: [snap])
        let hit = SearchTripsTool.argumentsForTesting(countryCode: "GR")
        let miss = SearchTripsTool.argumentsForTesting(countryCode: "IT")
        #expect(tool.matchesForTesting(snapshot: snap, arguments: hit))
        #expect(!tool.matchesForTesting(snapshot: snap, arguments: miss))
    }

    @Test("country-code filter is trimmed and upper-cased before comparison")
    func matchesCountryCodeTrimmedUppercased() throws {
        let snap = try greeceSnapshot()
        let tool = SearchTripsTool(snapshots: [snap])
        let args = SearchTripsTool.argumentsForTesting(countryCode: "  gr  ")
        #expect(tool.matchesForTesting(snapshot: snap, arguments: args))
    }

    @Test("country-name filter is a case-insensitive substring of the English name")
    func matchesCountryName() throws {
        let snap = try greeceSnapshot()
        let tool = SearchTripsTool(snapshots: [snap])
        let hit = SearchTripsTool.argumentsForTesting(countryNameContains: "GREE")
        let miss = SearchTripsTool.argumentsForTesting(countryNameContains: "Italy")
        #expect(tool.matchesForTesting(snapshot: snap, arguments: hit))
        #expect(!tool.matchesForTesting(snapshot: snap, arguments: miss))
    }

    @Test("locality filter is a case-insensitive substring of any stay locality")
    func matchesLocality() throws {
        let snap = try greeceSnapshot()
        let tool = SearchTripsTool(snapshots: [snap])
        let hit = SearchTripsTool.argumentsForTesting(localityContains: "athen")
        let miss = SearchTripsTool.argumentsForTesting(localityContains: "Tokyo")
        #expect(tool.matchesForTesting(snapshot: snap, arguments: hit))
        #expect(!tool.matchesForTesting(snapshot: snap, arguments: miss))
    }

    @Test("admin-area filter is a case-insensitive substring of any stay admin area")
    func matchesAdminArea() throws {
        let snap = try greeceSnapshot()
        let tool = SearchTripsTool(snapshots: [snap])
        let hit = SearchTripsTool.argumentsForTesting(administrativeAreaContains: "attic")
        let miss = SearchTripsTool.argumentsForTesting(administrativeAreaContains: "Bavaria")
        #expect(tool.matchesForTesting(snapshot: snap, arguments: hit))
        #expect(!tool.matchesForTesting(snapshot: snap, arguments: miss))
    }

    @Test("year filter matches the start-date year and rejects others")
    func matchesYear() throws {
        let snap = try greeceSnapshot() // starts 2024
        let tool = SearchTripsTool(snapshots: [snap])
        #expect(tool.matchesForTesting(snapshot: snap,
                                       arguments: SearchTripsTool.argumentsForTesting(year: 2024)))
        #expect(!tool.matchesForTesting(snapshot: snap,
                                        arguments: SearchTripsTool.argumentsForTesting(year: 2023)))
    }

    @Test("month filter matches the start-date month and rejects others")
    func matchesMonth() throws {
        let snap = try greeceSnapshot() // starts June (6)
        let tool = SearchTripsTool(snapshots: [snap])
        #expect(tool.matchesForTesting(snapshot: snap,
                                       arguments: SearchTripsTool.argumentsForTesting(month: 6)))
        #expect(!tool.matchesForTesting(snapshot: snap,
                                        arguments: SearchTripsTool.argumentsForTesting(month: 7)))
    }

    @Test("min/max duration filters bound the durationDays inclusively")
    func matchesDurationBounds() throws {
        let snap = try greeceSnapshot() // durationDays == 5
        let tool = SearchTripsTool(snapshots: [snap])
        #expect(snap.durationDays == 5)
        // Within range
        #expect(tool.matchesForTesting(snapshot: snap,
                                       arguments: SearchTripsTool.argumentsForTesting(minDurationDays: 5, maxDurationDays: 5)))
        // Below min
        #expect(!tool.matchesForTesting(snapshot: snap,
                                        arguments: SearchTripsTool.argumentsForTesting(minDurationDays: 6)))
        // Above max
        #expect(!tool.matchesForTesting(snapshot: snap,
                                        arguments: SearchTripsTool.argumentsForTesting(maxDurationDays: 4)))
    }

    @Test("empty / nil arguments match everything (no filters applied)")
    func matchesNoFilters() throws {
        let snap = try greeceSnapshot()
        let tool = SearchTripsTool(snapshots: [snap])
        // All-nil
        #expect(tool.matchesForTesting(snapshot: snap, arguments: SearchTripsTool.argumentsForTesting()))
        // Whitespace-only string args are trimmed to empty and skipped.
        let blanks = SearchTripsTool.argumentsForTesting(
            countryCode: "   ", countryNameContains: "  ",
            administrativeAreaContains: "", localityContains: " ")
        #expect(tool.matchesForTesting(snapshot: snap, arguments: blanks))
    }

    // MARK: - matches: normalization, place names, calendar

    @Test("text filters fold diacritics on both sides: Köniz finds the stored Koniz")
    func matchesFoldDiacritics() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 1, 15))
        trip.countryCodes = "CH"
        addDestination(to: trip, in: ctx, order: 0, locality: "Koniz", admin: "Koniz", isoCountryCode: "CH")
        let snap = TripSnapshot(from: trip)
        let tool = SearchTripsTool(snapshots: [snap])

        #expect(tool.matchesForTesting(snapshot: snap,
                                       arguments: SearchTripsTool.argumentsForTesting(localityContains: "Köniz")))
        #expect(tool.matchesForTesting(snapshot: snap,
                                       arguments: SearchTripsTool.argumentsForTesting(localityContains: "KONIZ")))
        #expect(tool.matchesForTesting(snapshot: snap,
                                       arguments: SearchTripsTool.argumentsForTesting(administrativeAreaContains: "kön")))
        #expect(!tool.matchesForTesting(snapshot: snap,
                                        arguments: SearchTripsTool.argumentsForTesting(localityContains: "Zug")))
    }

    @Test("locality filter also searches place names: Kephallenia finds a stay on the island of Kephallenia")
    func matchesIslandPlaceName() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 2, 5))
        trip.countryCodes = "GR"
        trip.destinationSummary = "Lixoúri"
        addDestination(to: trip, in: ctx, order: 0, locality: "Lixoúri", admin: "Ionian Islands",
                       isoCountryCode: "GR", islandName: "Kephallenia")
        let snap = TripSnapshot(from: trip)
        let tool = SearchTripsTool(snapshots: [snap])

        #expect(tool.matchesForTesting(snapshot: snap,
                                       arguments: SearchTripsTool.argumentsForTesting(localityContains: "Kephallenia")))
        #expect(tool.matchesForTesting(snapshot: snap,
                                       arguments: SearchTripsTool.argumentsForTesting(localityContains: "Κεφαλληνία")))
        #expect(!tool.matchesForTesting(snapshot: snap,
                                        arguments: SearchTripsTool.argumentsForTesting(localityContains: "Samos")))
    }

    @Test("year and month stay Gregorian when the tool is handed a Buddhist calendar")
    func matchesYearIgnoresBuddhistCalendar() throws {
        let snap = try greeceSnapshot() // starts 2024-06-10 (Gregorian)
        let buddhist = Calendar(identifier: .buddhist)
        // The premise: the Buddhist era numbers this date 2567.
        #expect(buddhist.component(.year, from: snap.startDate) == 2567)

        let tool = SearchTripsTool(snapshots: [snap], calendar: buddhist)
        #expect(tool.matchesForTesting(snapshot: snap,
                                       arguments: SearchTripsTool.argumentsForTesting(year: 2024, month: 6)))
        #expect(!tool.matchesForTesting(snapshot: snap,
                                        arguments: SearchTripsTool.argumentsForTesting(year: 2567)))
    }

    // MARK: - matches: AND combination

    @Test("filters AND-combine: all must pass for a match")
    func matchesAndCombine() throws {
        let snap = try greeceSnapshot()
        let tool = SearchTripsTool(snapshots: [snap])
        // Every filter satisfied -> match.
        let allTrue = SearchTripsTool.argumentsForTesting(
            countryCode: "GR",
            countryNameContains: "Greece",
            localityContains: "Athens",
            year: 2024,
            month: 6,
            minDurationDays: 1,
            maxDurationDays: 30)
        #expect(tool.matchesForTesting(snapshot: snap, arguments: allTrue))

        // One filter wrong (month) -> overall reject, proving AND not OR.
        let oneWrong = SearchTripsTool.argumentsForTesting(
            countryCode: "GR",
            countryNameContains: "Greece",
            localityContains: "Athens",
            year: 2024,
            month: 12,
            minDurationDays: 1,
            maxDurationDays: 30)
        #expect(!tool.matchesForTesting(snapshot: snap, arguments: oneWrong))
    }

    // MARK: - matches: ongoing trip (nil durationDays) excluded from duration filters

    @Test("ongoing trip (nil durationDays) is excluded by a min-duration filter")
    func matchesOngoingExcludedByMinDuration() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 1, 15)) // endDate nil -> ongoing
        trip.countryCodes = "GR"
        addDestination(to: trip, in: ctx, order: 0, locality: "Athens", isoCountryCode: "GR")
        let snap = TripSnapshot(from: trip)
        #expect(snap.durationDays == nil)

        let tool = SearchTripsTool(snapshots: [snap])
        // A min-duration filter requires a non-nil durationDays -> ongoing fails.
        #expect(!tool.matchesForTesting(snapshot: snap,
                                        arguments: SearchTripsTool.argumentsForTesting(minDurationDays: 1)))
        // Likewise a max-duration filter.
        #expect(!tool.matchesForTesting(snapshot: snap,
                                        arguments: SearchTripsTool.argumentsForTesting(maxDurationDays: 1000)))
        // But a non-duration filter still matches the ongoing trip.
        #expect(tool.matchesForTesting(snapshot: snap,
                                       arguments: SearchTripsTool.argumentsForTesting(countryCode: "GR")))
    }

    // MARK: - call() formatting

    @Test("call formats a matched trip as [UUID] name | codes | start to end")
    func callFormatsMatchLine() async throws {
        let snap = try greeceSnapshot()
        let tool = SearchTripsTool(snapshots: [snap])
        let args = SearchTripsTool.argumentsForTesting(countryCode: "GR")
        let lines = try await tool.call(arguments: args)
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        // ISO8601 .withFullDate is GMT-anchored yyyy-MM-dd.
        #expect(line.contains("[\(snap.id.uuidString)]"))
        #expect(line.contains(snap.displayName))
        #expect(line.contains("GR"))
        #expect(line.contains(" to "))
        #expect(line.contains("2024-06"))
    }

    @Test("call uses the word \"ongoing\" for a nil endDate")
    func callUsesOngoingForNilEndDate() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 1, 15)) // endDate nil
        trip.countryCodes = "GR"
        addDestination(to: trip, in: ctx, order: 0, locality: "Athens", isoCountryCode: "GR")
        let snap = TripSnapshot(from: trip)
        #expect(snap.endDate == nil)

        let tool = SearchTripsTool(snapshots: [snap])
        let lines = try await tool.call(arguments: SearchTripsTool.argumentsForTesting(countryCode: "GR"))
        let line = try #require(lines.first)
        #expect(line.contains("ongoing"))
    }

    @Test("call returns the no-match sentinel when nothing matches the filters")
    func callReturnsNoMatchSentinel() async throws {
        let snap = try greeceSnapshot()
        let tool = SearchTripsTool(snapshots: [snap])
        let lines = try await tool.call(arguments: SearchTripsTool.argumentsForTesting(countryCode: "JP"))
        #expect(lines == ["No trips matched these filters."])
    }

    @Test("call caps the output at 40 lines via prefix(40)")
    func callCapsAt40Lines() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        var snaps: [TripSnapshot] = []
        // 41 matching trips -> only 40 lines should come back.
        for _ in 0..<41 {
            let trip = makeTrip(in: ctx, start: day(2024, 1, 15))
            trip.countryCodes = "GR"
            trip.endDate = day(2024, 1, 19)
            addDestination(to: trip, in: ctx, order: 0, locality: "Athens", isoCountryCode: "GR")
            snaps.append(TripSnapshot(from: trip))
        }
        let tool = SearchTripsTool(snapshots: snaps)
        let lines = try await tool.call(arguments: SearchTripsTool.argumentsForTesting(countryCode: "GR"))
        #expect(lines.count == 40)
    }
}
