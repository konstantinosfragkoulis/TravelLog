//
//  TemporaryHomeFinalUITests.swift
//  TravelLogTests
//
//  Pure seams of the temporary-home UI: Settings rows for removed temporary
//  homes whose trips are still owed an update, the suggestion's per-trip
//  cache and the Trips list's suggestion pass key.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct TemporaryHomeFinalUITests {

    private typealias Suggestion = TemporaryHomeSuggestion
    private typealias Status = CoverageReconciliationQueue.TemporaryHomeStatus

    private let utc = TimeZone(secondsFromGMT: 0)!

    private func at(_ month: Int, _ day: Int, _ hour: Int = 12, shiftDates: Bool = true) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: 2025, month: month, day: day, hour: hour))!
            .addingTimeInterval(shiftDates ? 23_587_200 : 0)
    }

    private func anchor(id: UUID = UUID(), from start: Date, to end: Date? = nil) -> HomeAnchor {
        HomeAnchor(
            id: id, kind: .temporary, label: "", latitude: 50.8132, longitude: 4.3502,
            radiusKm: 25, locality: nil, isoCountryCode: nil, startedAt: start, endedAt: end)
    }

    // MARK: - Removed temporary homes still owed an update

    @Test("Settings lists a removed temporary home while its update is owed, by its name and status; a live one or a settled removal is not listed")
    func pendingRemovalsFollowTheQueue() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let live = TemporaryHome(label: "Erasmus", latitude: 50.8132, longitude: 4.3502, startedAt: at(9, 1))
        let failed = TemporaryHome(label: "", latitude: 41.4021, longitude: 2.2394, startedAt: at(3, 1))
        failed.locality = "Barcelona"
        failed.removedAt = at(9, 20)
        // A live twin of a removed id: the id reads as removed.
        let twin = TemporaryHome(label: "", latitude: 41.4021, longitude: 2.2394, startedAt: at(3, 1))
        twin.id = failed.id
        twin.locality = "Barcelona"
        let waiting = TemporaryHome(label: "Lisbon flat", latitude: 38.6835, longitude: -9.1346, startedAt: at(6, 1))
        waiting.removedAt = at(9, 21)
        let settled = TemporaryHome(label: "Beringen", latitude: 51.0495, longitude: 5.2294, startedAt: at(1, 1))
        settled.removedAt = at(9, 22)
        for row in [live, failed, twin, waiting, settled] { context.insert(row) }
        try context.save()
        let rows = try context.fetch(FetchDescriptor<TemporaryHome>())

        let statuses: [UUID: Status] = [
            live.id: .updating, failed.id: .failed, waiting.id: .waiting,
        ]
        let listed = TemporaryHomesSettingsSection.pendingRemovals(rows) { statuses[$0] }
        // Newest first, one row per id.
        #expect(listed == [
            .init(id: waiting.id, title: "Lisbon flat", status: .waiting),
            .init(id: failed.id, title: "Barcelona", status: .failed),
        ])
        // The status goes: so does the row.
        #expect(TemporaryHomesSettingsSection.pendingRemovals(rows) { _ in nil }.isEmpty)
    }

    @Test("a pending removal row reads its status from the queue: owed is updating, settled is nil")
    func pendingRemovalReadsTheQueue() throws {
        let suite = "TemporaryHomeFinalUITests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let removed = TemporaryHome(label: "Erasmus", latitude: 50.8132, longitude: 4.3502, startedAt: at(9, 1))
        removed.removedAt = at(9, 20)
        context.insert(removed)
        try context.save()
        let rows = try context.fetch(FetchDescriptor<TemporaryHome>())
        func listed() -> [TemporaryHomesSettingsSection.PendingRemoval] {
            TemporaryHomesSettingsSection.pendingRemovals(rows) {
                CoverageReconciliationQueue.temporaryHomeStatus(id: $0, defaults: defaults)
            }
        }
        #expect(listed().isEmpty)
        let staged = CoverageReconciliationQueue.stage(.temporaryHome, id: removed.id, defaults: defaults)
        #expect(listed() == [.init(id: removed.id, title: "Erasmus", status: .updating)])
        CoverageReconciliationQueue.complete(staged.entry, defaults: defaults)
        #expect(listed().isEmpty)
    }

    // MARK: - The suggestion cache and pass key

    private typealias TripStay = TemporaryHomeFormSheet.Prefill.TripStay

    /// A destination stay in Brussels; each argument is one field the evaluation reads.
    private func tripStay(
        _ id: UUID, start: Date? = nil, end: Date? = nil, latitude: Double = 50.8132,
        longitude: Double = 4.3502, isDestination: Bool = true, isAirport: Bool = false,
        locality: String? = "Brussels", country: String? = "BE", zone: String? = "Europe/Brussels"
    ) -> TripStay {
        TripStay(id: id, start: start ?? at(9, 2, 8), end: end ?? at(9, 9, 8),
                 latitude: latitude, longitude: longitude, isDestination: isDestination,
                 isAirport: isAirport, locality: locality, isoCountryCode: country,
                 timeZoneIdentifier: zone)
    }

    /// `stays` is a `staysFingerprint` value.
    private func key(
        tripID: UUID, name: String? = nil, end: Date? = nil, complete: Bool = false,
        stays: Int = 0, declarations: Int = 0, now: Date? = nil, zone: TimeZone? = nil,
        shiftDates: Bool = true
    ) -> Suggestion.CacheKey {
        Suggestion.cacheKey(
            tripID: tripID, customName: name, startDate: at(9, 1, 8, shiftDates: shiftDates), endDate: end,
            isComplete: complete, declarations: declarations,
            now: now ?? at(9, 20, 12, shiftDates: shiftDates), timeZone: zone ?? utc, staysFingerprint: stays)
    }

    @Test("the cache key holds through the day and moves with the trip, its stays, the declarations and the civil day in the given zone")
    func cacheKeyFollowsItsInputs() throws {
        let trip = UUID()
        let base = key(tripID: trip, shiftDates: false)
        #expect(key(tripID: trip, now: at(9, 20, 0, shiftDates: false), shiftDates: false) == base)
        #expect(key(tripID: trip, now: at(9, 20, 23, shiftDates: false), shiftDates: false) == base)
        #expect(key(tripID: trip, now: at(9, 21, 0, shiftDates: false), shiftDates: false) != base)
        // These September UTC times share a day in UTC and cross midnight in Brussels.
        let brussels = try #require(TimeZone(identifier: "Europe/Brussels"))
        #expect(key(tripID: trip, now: at(9, 20, 23, shiftDates: false), shiftDates: false) == key(tripID: trip, now: at(9, 20, 21, shiftDates: false), shiftDates: false))
        #expect(key(tripID: trip, now: at(9, 20, 23, shiftDates: false), zone: brussels, shiftDates: false)
                != key(tripID: trip, now: at(9, 20, 21, shiftDates: false), zone: brussels, shiftDates: false))
        #expect(key(tripID: UUID(), shiftDates: false) != base)
        #expect(key(tripID: trip, name: "Erasmus", shiftDates: false) != base)
        #expect(key(tripID: trip, end: at(9, 30, shiftDates: false), complete: true, shiftDates: false) != base)
        #expect(key(tripID: trip, declarations: 1, shiftDates: false) != base)

        // Its stays through their fingerprint: another stay, one fewer
        // destination, a later end.
        let ids = [UUID(), UUID(), UUID()]
        let three = ids.map { tripStay($0) }
        func keyOf(_ stays: [TripStay]) -> Suggestion.CacheKey {
            key(tripID: trip, stays: Suggestion.staysFingerprint(stays), shiftDates: false)
        }
        #expect(keyOf(three.reversed()) == keyOf(three))
        #expect(keyOf(three + [tripStay(UUID())]) != keyOf(three))
        #expect(keyOf([tripStay(ids[0], isDestination: false), three[1], three[2]]) != keyOf(three))
        #expect(keyOf([three[0], three[1], tripStay(ids[2], end: at(9, 20, 9))]) != keyOf(three))
    }

    @Test("a zone change that keeps today's midnight is still a miss: a stay with no zone of its own reads its overnights in the evaluation's zone")
    func cacheKeyFollowsTheZone() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let laPaz = try #require(TimeZone(identifier: "America/La_Paz"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        func on(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
            try #require(calendar.date(from: DateComponents(
                year: 2026, month: month, day: day, hour: hour, minute: minute)))
        }
        let now = try on(10, 6, 12)
        let tripID = UUID()
        let start = try on(1, 1, 0)
        let end = try on(2, 15, 0)
        // 06:45 to 07:15 UTC holds 03:00 in La Paz (UTC-4) but not in New
        // York (UTC-5 in January); both zones start 6 October at 04:00 UTC.
        let stays = try [2, 10, 18].map { day in
            TripStay(id: UUID(), start: try on(1, day, 6, 45), end: try on(1, day, 7, 15),
                     latitude: 50.8132, longitude: 4.3502, isDestination: true, isAirport: false,
                     locality: "Brussels", isoCountryCode: "BE", timeZoneIdentifier: nil)
        }
        func cacheKey(_ zone: TimeZone) -> Suggestion.CacheKey {
            Suggestion.cacheKey(
                tripID: tripID, customName: nil, startDate: start, endDate: end, isComplete: true,
                declarations: 0, now: now, timeZone: zone,
                staysFingerprint: Suggestion.staysFingerprint(stays))
        }
        #expect(cacheKey(newYork).day == cacheKey(laPaz).day)

        var cache = Suggestion.Cache()
        func ask(in zone: TimeZone) -> Suggestion.Candidate? {
            cache.candidate(for: cacheKey(zone)) {
                Suggestion.candidate(
                    tripID: tripID, customName: nil, startDate: start, endDate: end, isComplete: true,
                    stays: stays, temporaryHomes: [], now: now, timeZone: zone)
            }
        }
        #expect(ask(in: newYork) == nil)
        #expect(ask(in: laPaz)?.placeName == "Brussels")
        #expect(ask(in: newYork) == nil)
    }

    @Test("the stays fingerprint ignores order, of two copies of one stay too, and moves with every stay field the evaluation reads, so a synced move or rename of a stay is a cache miss")
    func staysFingerprintFollowsWhatTheEvaluationReads() {
        let (a, b) = (UUID(), UUID())
        let base = Suggestion.staysFingerprint([tripStay(a), tripStay(b)])
        #expect(Suggestion.staysFingerprint([tripStay(b), tripStay(a)]) == base)
        // One stay per field the evaluation reads, each `a` but for that field.
        let changed: [TripStay] = [
            tripStay(UUID()), tripStay(a, start: at(9, 2, 9)), tripStay(a, end: at(9, 9, 9)),
            tripStay(a, latitude: 50.8232), tripStay(a, longitude: 4.3602),
            tripStay(a, isDestination: false), tripStay(a, isAirport: true),
            tripStay(a, locality: "Dendermonde"), tripStay(a, locality: nil), tripStay(a, country: "NL"),
            tripStay(a, zone: nil),
        ]
        for stay in changed {
            #expect(Suggestion.staysFingerprint([stay, tripStay(b)]) != base)
        }
        // Two copies of `a` give one value in either order, whatever field tells them apart.
        for copy in changed where copy.id == a {
            #expect(Suggestion.staysFingerprint([tripStay(a), copy])
                    == Suggestion.staysFingerprint([copy, tripStay(a)]))
        }
    }

    @Test("the declarations fingerprint ignores order and follows ids and dates, never Homes")
    func declarationsFingerprint() {
        let a = anchor(from: at(9, 1))
        let b = anchor(from: at(2, 1), to: at(6, 30))
        #expect(Suggestion.declarationsFingerprint([a, b]) == Suggestion.declarationsFingerprint([b, a]))
        #expect(Suggestion.declarationsFingerprint([a]) != Suggestion.declarationsFingerprint([a, b]))
        let ended = anchor(id: a.id, from: at(9, 1), to: at(12, 20))
        #expect(Suggestion.declarationsFingerprint([ended]) != Suggestion.declarationsFingerprint([a]))
        let home = HomeAnchor(
            id: UUID(), kind: .home, label: "", latitude: 37.98, longitude: 23.73, radiusKm: 25,
            locality: nil, isoCountryCode: nil, startedAt: at(1, 1), endedAt: nil)
        #expect(Suggestion.declarationsFingerprint([a, home]) == Suggestion.declarationsFingerprint([a]))
    }

    @Test("an unchanged trip answers from the cache, nil answers included; a changed key evaluates again and replaces the entry")
    func cacheHitsAndMisses() {
        var cache = Suggestion.Cache()
        var evaluations = 0
        let tripID = UUID()
        let found = Suggestion.Candidate(
            tripID: tripID, placeName: "Brussels",
            prefill: .init(name: nil, coordinate: nil, since: at(9, 2, 10), until: nil), isOngoing: true)
        func ask(_ key: Suggestion.CacheKey, answer: Suggestion.Candidate?) -> Suggestion.Candidate? {
            cache.candidate(for: key) {
                evaluations += 1
                return answer
            }
        }
        let first = key(tripID: tripID)
        #expect(ask(first, answer: found) == found)
        #expect(ask(first, answer: nil) == found)
        #expect(evaluations == 1)

        let grown = key(tripID: tripID, stays: 1)
        #expect(ask(grown, answer: nil) == nil)
        #expect(ask(grown, answer: found) == nil)
        #expect(evaluations == 2)
        // The old key's entry was replaced.
        #expect(ask(first, answer: found) == found)
        #expect(evaluations == 3)

        // Another trip has its own entry.
        let other = key(tripID: UUID())
        #expect(ask(other, answer: nil) == nil)
        #expect(ask(first, answer: nil) == found)
        #expect(evaluations == 4)
    }

    @Test("a stored trip whose stays change is evaluated again: a base stay set to transit ends the question")
    func storedTripReevaluatesOnChange() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: at(9, 1, 8))
        context.insert(trip)
        var stays: [Stay] = []
        for (start, end) in [(at(9, 2, 10), at(9, 9, 18)), (at(9, 12, 21), at(9, 20, 8))] {
            let stay = Stay(
                startTime: start, endTime: end, centroidLatitude: 50.8135, centroidLongitude: 4.3519,
                h3IndexRes6: "", pingCount: 4, distanceFromHomeKm: 0, pingIDs: [],
                timeZoneIdentifier: "UTC")
            stay.category = .destination
            stay.locality = "Brussels"
            stay.isoCountryCode = "BE"
            context.insert(stay)
            stay.trip = trip
            stays.append(stay)
        }
        try context.save()
        let now = at(9, 20, 12)
        #expect(Suggestion.candidate(for: trip, temporaryHomes: [], now: now)?.placeName == "Brussels")
        #expect(Suggestion.candidate(for: trip, temporaryHomes: [], now: now)?.placeName == "Brussels")
        for stay in stays { stay.category = .transit }
        try context.save()
        #expect(Suggestion.candidate(for: trip, temporaryHomes: [], now: now) == nil)
    }

    @Test("the Trips list's suggestion pass key: the same inputs give the same key, any input moves it, the zone included")
    func passKeyFollowsItsInputs() throws {
        let erasmus = anchor(from: at(9, 20, 14))
        func passKey(
            trips: Int = 1, stays: Int = 1, declarations: [HomeAnchor]? = nil, now: Date? = nil,
            zone: TimeZone? = nil, tipLearned: Bool = false, dismissals: [String] = []
        ) -> TripsListView.SuggestionPassKey {
            TripsListView.suggestionPassKey(
                trips: trips, stays: stays, declarations: declarations ?? [erasmus],
                now: now ?? at(9, 20, 12), timeZone: zone ?? utc, tipLearned: tipLearned,
                dismissals: dismissals)
        }
        let base = passKey()
        // The slice recompute, the card load and the stay observer for one update.
        #expect(passKey() == base)
        #expect(passKey(now: at(9, 20, 13)) == base)
        #expect(passKey(trips: 2) != base)
        #expect(passKey(stays: 2) != base)
        #expect(passKey(declarations: []) != base)
        #expect(passKey(declarations: [anchor(id: erasmus.id, from: at(9, 20, 14), to: at(12, 20))]) != base)
        // A declaration that starts later today covers now from its start.
        #expect(passKey(now: at(9, 20, 15)) != base)
        #expect(passKey(now: at(9, 21, 0)) != passKey(now: at(9, 20, 23)))
        #expect(passKey(tipLearned: true) != base)
        #expect(passKey(dismissals: [UUID().uuidString]) != base)
        // New York and La Paz share midnight on 6 October 2026, not a January night.
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let laPaz = try #require(TimeZone(identifier: "America/La_Paz"))
        let sixOctober = Date(timeIntervalSince1970: 1_791_288_000)
        #expect(passKey(now: sixOctober, zone: newYork).day == passKey(now: sixOctober, zone: laPaz).day)
        #expect(passKey(now: sixOctober, zone: newYork) != passKey(now: sixOctober, zone: laPaz))
    }
}
