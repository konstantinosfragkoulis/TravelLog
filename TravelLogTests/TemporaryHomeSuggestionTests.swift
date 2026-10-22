//
//  TemporaryHomeSuggestionTests.swift
//  TravelLogTests
//
//  "Living in Brussels for now?": which trips ask, what the question
//  prefills, and that Not Now is remembered on this device without changing
//  which trips are candidates. Everything is in UTC unless a stay names its
//  own zone, and expected values are written out by hand. The per-trip
//  suggestion cache (its key, the stays and declarations fingerprints, hits
//  and misses) is covered at the end.
//

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Temporary home suggestion")
struct TemporaryHomeSuggestionTests {

    private typealias Place = (lat: Double, lon: Double)
    private typealias TripStay = TemporaryHomeFormSheet.Prefill.TripStay

    private let brussels: Place = (50.8855, 4.3734)
    /// About 341 m from `brussels`.
    private let flat: Place = (50.8882, 4.3757)
    /// About 2.6 km from `brussels`, in the same city.
    private let campus: Place = (50.8652, 4.3917)
    private let beringen: Place = (51.0538, 5.2268)
    private let rome: Place = (41.9603, 12.4645)
    private let paris: Place = (48.8193, 2.4441)

    private let utc = TimeZone(secondsFromGMT: 0)!

    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func label(_ year: Int, _ month: Int, _ day: Int) -> Date {
        TravelDays.labelCalendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func tripStay(
        at place: Place, from start: Date, to end: Date, city: String? = nil, country: String? = nil,
        zone: String? = "UTC", id: UUID = UUID(), destination: Bool = true, airport: Bool = false
    ) -> TripStay {
        TripStay(
            id: id, start: start, end: end, latitude: place.lat, longitude: place.lon,
            isDestination: destination, isAirport: airport,
            locality: city, isoCountryCode: country, timeZoneIdentifier: zone)
    }

    /// A semester begun on 22 December: a night in Rome on the way, then
    /// Brussels from 23 December, at the flat from 2 January.
    private var semesterStays: [TripStay] {
        [
            tripStay(at: rome, from: at(2025, 12, 22, 8), to: at(2025, 12, 23, 8), city: "Rome", country: "IT"),
            tripStay(at: brussels, from: at(2025, 12, 23, 10), to: at(2025, 12, 30, 18), city: "Brussels", country: "BE"),
            tripStay(at: flat, from: at(2026, 1, 2, 21), to: at(2026, 1, 10, 8), city: "Brussels", country: "BE"),
        ]
    }

    private func anchor(from start: Date, to end: Date? = nil) -> HomeAnchor {
        HomeAnchor(
            id: UUID(), kind: .temporary, label: "", latitude: brussels.lat, longitude: brussels.lon,
            radiusKm: 25, locality: nil, isoCountryCode: nil, startedAt: start, endedAt: end)
    }

    private func candidate(
        name: String? = nil, start: Date, end: Date? = nil, complete: Bool = false,
        stays: [TripStay], declarations: [HomeAnchor] = [], now: Date
    ) -> TemporaryHomeSuggestion.Candidate? {
        TemporaryHomeSuggestion.candidate(
            tripID: UUID(), customName: name, startDate: start, endDate: end, isComplete: complete,
            stays: stays, temporaryHomes: declarations, now: now, timeZone: utc)
    }

    // MARK: - Ongoing trips

    @Test("an open trip of 20 days that lives in Brussels asks about Brussels, prefilled from the arrival there with the end open")
    func openSemesterIsACandidate() throws {
        let found = try #require(candidate(
            name: "Erasmus", start: at(2025, 12, 22, 8), stays: semesterStays, now: at(2026, 1, 10, 12)))
        #expect(found.placeName == "Brussels")
        #expect(found.isOngoing)
        #expect(found.prefill.name == "Erasmus")
        // The arrival in Brussels, not the night in Rome on the way.
        #expect(found.prefill.since == at(2025, 12, 23, 10))
        #expect(found.prefill.until == nil)
        // The strongest 1 km cluster in the city: the first stay and the flat, 341 m apart.
        let pin = try #require(found.prefill.coordinate)
        #expect(abs(pin.latitude - (brussels.lat + flat.lat) / 2) < 1e-6)
    }

    @Test("an open trip asks from its 14th civil day, not on its 13th")
    func openTripNeedsFourteenDays() {
        let start = at(2025, 12, 22, 8)
        // 22 December to 3 January is 13 civil days; to 4 January is 14.
        #expect(candidate(start: start, stays: semesterStays, now: at(2026, 1, 3, 23)) == nil)
        #expect(candidate(start: start, stays: semesterStays, now: at(2026, 1, 4, 0)) != nil)
    }

    @Test("a live temporary home that covers the open trip's start or today means no question")
    func coveringDeclarationSilencesAnOpenTrip() {
        let start = at(2025, 12, 22, 8)
        let now = at(2026, 1, 10, 12)
        #expect(candidate(start: start, stays: semesterStays,
                          declarations: [anchor(from: at(2025, 12, 22, 0), to: at(2025, 12, 26, 23))], now: now) == nil)
        #expect(candidate(start: start, stays: semesterStays,
                          declarations: [anchor(from: at(2026, 1, 8, 0))], now: now) == nil)
        // One that covers neither, a past one, changes nothing.
        #expect(candidate(start: start, stays: semesterStays,
                          declarations: [anchor(from: at(2025, 6, 21, 0), to: at(2025, 10, 20, 23))], now: now) != nil)
    }

    // MARK: - Completed trips

    @Test("a completed trip asks from 28 civil days, prefilled from the arrival to the last stay in the place")
    func completedTripNeedsTwentyEightDays() throws {
        let start = at(2025, 12, 22, 8)
        let stays = semesterStays
        // 22 December to 17 January is 27 civil days.
        #expect(candidate(start: start, end: at(2026, 1, 17, 20), complete: true,
                          stays: stays, now: at(2026, 2, 19)) == nil)
        let found = try #require(candidate(start: start, end: at(2026, 1, 18, 9), complete: true,
                                           stays: stays, now: at(2026, 2, 19)))
        #expect(!found.isOngoing)
        #expect(found.prefill.since == at(2025, 12, 23, 10))
        #expect(found.prefill.until == at(2026, 1, 10, 8))
    }

    @Test("a temporary home that covers the middle of a completed trip means no question")
    func coveringDeclarationSilencesACompletedTrip() {
        let start = at(2025, 12, 22, 8)
        let end = at(2026, 2, 20, 8)
        #expect(candidate(start: start, end: end, complete: true, stays: semesterStays,
                          declarations: [anchor(from: at(2026, 1, 10, 0), to: at(2026, 1, 25, 23))],
                          now: at(2026, 2, 25)) == nil)
        // Covering only its first days: the middle, 21 January, is not covered.
        #expect(candidate(start: start, end: end, complete: true, stays: semesterStays,
                          declarations: [anchor(from: at(2025, 12, 22, 0), to: at(2025, 12, 31, 23))],
                          now: at(2026, 2, 25)) != nil)
    }

    // MARK: - Evidence

    @Test("a road trip spread over many cities has no place with half the time")
    func roadTripHasNoDominantPlace() {
        let cities: [(Place, String)] = [(brussels, "Brussels"), (beringen, "Beringen"), (paris, "Paris"), (rome, "Rome")]
        var stays: [TripStay] = []
        for (index, (place, city)) in cities.enumerated() {
            let from = at(2025, 12, 22, 18).addingTimeInterval(Double(2 + index * 5 - 1) * 86_400)
            stays.append(tripStay(at: place, from: from, to: from.addingTimeInterval(4 * 86_400),
                                  city: city, country: "XX"))
        }
        #expect(candidate(start: at(2025, 12, 22, 8), stays: stays, now: at(2026, 1, 15)) == nil)
    }

    @Test("one short recorded stay is no evidence; the same place over three nights spanning a week is")
    func overnightsMustRepeatAcrossAWeek() {
        let start = at(2025, 12, 22, 8)
        let now = at(2026, 1, 10)
        let sparse = [tripStay(at: brussels, from: at(2025, 12, 26, 10), to: at(2025, 12, 26, 14), city: "Brussels", country: "BE")]
        #expect(candidate(start: start, stays: sparse, now: now) == nil)

        func night(_ day: Int) -> TripStay {
            tripStay(at: brussels, from: at(2025, 12, 22, 20).addingTimeInterval(Double(day - 1) * 86_400), to: at(2025, 12, 22, 8).addingTimeInterval(Double(day + 1 - 1) * 86_400), city: "Brussels", country: "BE")
        }
        // Nights into 24, 25 and 26 December: three dates spanning three days.
        #expect(candidate(start: start, stays: [night(2), night(3), night(4)], now: now) == nil)
        // Into 24, 27 and 30 December: three dates spanning seven days.
        #expect(candidate(start: start, stays: [night(2), night(5), night(8)], now: now) != nil)
        // Two nights are not enough, however far apart.
        #expect(candidate(start: start, stays: [night(2), night(15)], now: now) == nil)
    }

    @Test("a stay covers a date's 03:00 in its own zone")
    func overnightIsReadInTheStaysZone() {
        // 17:00 to 19:00 UTC on 22 December is 02:00 to 04:00 on 23 December in Tokyo.
        let tokyo = tripStay(at: brussels, from: at(2025, 12, 22, 17), to: at(2025, 12, 22, 19), zone: "Asia/Tokyo")
        #expect(TemporaryHomeSuggestion.overnightDates(of: [tokyo], fallbackZone: utc) == [label(2025, 12, 23)])
        let inUTC = tripStay(at: brussels, from: at(2025, 12, 22, 17), to: at(2025, 12, 22, 19))
        #expect(TemporaryHomeSuggestion.overnightDates(of: [inUTC], fallbackZone: utc).isEmpty)
        // A zone it does not store falls back to the given one.
        let unknown = tripStay(at: brussels, from: at(2025, 12, 22, 2), to: at(2025, 12, 22, 4), zone: nil)
        #expect(TemporaryHomeSuggestion.overnightDates(of: [unknown], fallbackZone: utc) == [label(2025, 12, 22)])
    }

    @Test("two rows of one stay count once, as the longer copy, so a twin cannot outweigh the real place")
    func sameIDTwinsCountOnce() throws {
        let twinID = UUID()
        let stays = [
            tripStay(at: brussels, from: at(2025, 12, 23, 20), to: at(2025, 12, 24, 20), city: "Brussels", country: "BE"),
            tripStay(at: brussels, from: at(2025, 12, 26, 20), to: at(2025, 12, 27, 20), city: "Brussels", country: "BE"),
            tripStay(at: brussels, from: at(2025, 12, 30, 20), to: at(2026, 1, 1, 0), city: "Brussels", country: "BE"),
            // 76 hours in Brussels; both Paris copies together would be 79.
            tripStay(at: paris, from: at(2026, 1, 2, 8), to: at(2026, 1, 3, 23), city: "Paris", country: "FR", id: twinID),
            tripStay(at: paris, from: at(2026, 1, 2, 8), to: at(2026, 1, 4, 0), city: "Paris", country: "FR", id: twinID),
        ]
        let place = try #require(TemporaryHomeSuggestion.dominantPlace(stays))
        #expect(place.locality == "Brussels")
        #expect(place.seconds == 76 * 3_600)
        // The longer Paris copy, 40 hours, counts once.
        #expect(place.tripSeconds == (76 + 40) * 3_600)
        #expect(candidate(start: at(2025, 12, 22, 8), stays: stays, now: at(2026, 1, 10))?.placeName == "Brussels")
    }

    @Test("a dorm and a campus 2.6 kilometres apart are one city that outweighs a longer hotel stay elsewhere, and the pin is the dorm")
    func cityGroupsSeveralClusters() throws {
        var stays: [TripStay] = []
        for day in [2, 4, 6, 8] {
            // Nights at the dorm: 12 hours each, 48 in all.
            stays.append(tripStay(at: brussels, from: at(2025, 12, 22, 20).addingTimeInterval(Double(day - 1) * 86_400), to: at(2025, 12, 22, 8).addingTimeInterval(Double(day + 1 - 1) * 86_400),
                                  city: "Brussels", country: "BE"))
            // Days on campus: 9 hours each, 36 in all.
            stays.append(tripStay(at: campus, from: at(2025, 12, 22, 9).addingTimeInterval(Double(day + 1 - 1) * 86_400), to: at(2025, 12, 22, 18).addingTimeInterval(Double(day + 1 - 1) * 86_400),
                                  city: "Brussels", country: "BE"))
        }
        // One 60-hour hotel stay in Beringen: more than either cluster alone.
        stays.append(tripStay(at: beringen, from: at(2025, 12, 31, 12), to: at(2026, 1, 3, 0), city: "Beringen", country: "BE"))

        let found = try #require(candidate(start: at(2025, 12, 22, 8), stays: stays, now: at(2026, 1, 10)))
        #expect(found.placeName == "Brussels")
        let pin = try #require(found.prefill.coordinate)
        #expect(abs(pin.latitude - brussels.lat) < 1e-6)
        #expect(abs(pin.longitude - brussels.lon) < 1e-6)
        // "Set Up a Temporary Home…" reads the same place.
        let prefill = TemporaryHomeFormSheet.Prefill.forTrip(
            customName: nil, startDate: at(2025, 12, 22, 8), endDate: nil, isComplete: false, stays: stays)
        #expect(prefill.coordinate?.latitude == pin.latitude)
        #expect(prefill.since == at(2025, 12, 23, 20))

        // Without the city the same stays group by 1 km clusters, and Beringen's hotel wins.
        let unplaced = stays.map {
            TripStay(id: $0.id, start: $0.start, end: $0.end, latitude: $0.latitude, longitude: $0.longitude,
                     isDestination: true, isAirport: false)
        }
        let place = try #require(TemporaryHomeSuggestion.dominantPlace(unplaced))
        #expect(place.locality == nil)
        #expect(abs(place.pin.latitude - beringen.lat) < 1e-6)
    }

    @Test("stays with no city still ask, by 1 km cluster, about \"here\"")
    func unplacedStaysAskAboutHere() throws {
        let stays = semesterStays.map {
            TripStay(id: $0.id, start: $0.start, end: $0.end, latitude: $0.latitude, longitude: $0.longitude,
                     isDestination: true, isAirport: false)
        }
        let found = try #require(candidate(start: at(2025, 12, 22, 8), stays: stays, now: at(2026, 1, 10, 12)))
        #expect(found.placeName == nil)
        #expect(found.prefill.since == at(2025, 12, 23, 10))
    }

    @Test("airports, stays that are not destinations and stays with no duration are not evidence")
    func onlyLastingDestinationsCount() {
        let zaventem: Place = (50.9010, 4.4844)
        let stays = [
            tripStay(at: zaventem, from: at(2025, 12, 23, 0), to: at(2026, 1, 10, 0), airport: true),
            tripStay(at: beringen, from: at(2025, 12, 23, 0), to: at(2026, 1, 10, 0), destination: false),
            tripStay(at: rome, from: at(2025, 12, 26, 0), to: at(2025, 12, 26, 0)),
        ]
        #expect(TemporaryHomeSuggestion.dominantPlace(stays) == nil)
        #expect(candidate(start: at(2025, 12, 22, 8), stays: stays, now: at(2026, 1, 10)) == nil)
    }

    // MARK: - Stored trips and Not Now

    @Test("a stored open trip asks; a removed temporary home over it does not silence it; a live one does; Not Now is remembered and leaves it a candidate")
    func storedTripAndDismissal() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: at(2025, 12, 22, 8))
        trip.customName = "Erasmus"
        context.insert(trip)
        for row in semesterStays {
            let stay = Stay(
                startTime: row.start, endTime: row.end,
                centroidLatitude: row.latitude, centroidLongitude: row.longitude,
                h3IndexRes6: "", pingCount: 4, distanceFromHomeKm: 0, pingIDs: [],
                timeZoneIdentifier: row.timeZoneIdentifier)
            stay.category = .destination
            stay.locality = row.locality
            stay.isoCountryCode = row.isoCountryCode
            context.insert(stay)
            stay.trip = trip
        }
        let removed = TemporaryHome(label: "", latitude: brussels.lat, longitude: brussels.lon,
                                    startedAt: at(2025, 12, 22, 0))
        removed.removedAt = at(2025, 12, 31)
        context.insert(removed)
        try context.save()
        let now = at(2026, 1, 10, 12)

        let rows = try context.fetch(FetchDescriptor<TemporaryHome>())
        let found = try #require(TemporaryHomeSuggestion.candidate(for: trip, temporaryHomes: rows, now: now))
        #expect(found.tripID == trip.id)
        #expect(found.placeName == "Brussels")
        #expect(found.prefill.name == "Erasmus")
        #expect(found.prefill.since == at(2025, 12, 23, 10))

        let suite = "TemporaryHomeSuggestionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!TemporaryHomeSuggestion.isDismissed(trip.id, defaults: defaults))
        TemporaryHomeSuggestion.dismiss(trip.id, defaults: defaults)
        #expect(TemporaryHomeSuggestion.isDismissed(trip.id, defaults: defaults))
        // Not Now hides the line; the trip stays a candidate (no demotion tip for it).
        #expect(TemporaryHomeSuggestion.candidate(for: trip, temporaryHomes: rows, now: now) == found)

        let live = TemporaryHome(label: "", latitude: brussels.lat, longitude: brussels.lon,
                                 startedAt: at(2025, 12, 22, 0))
        context.insert(live)
        try context.save()
        let withLive = try context.fetch(FetchDescriptor<TemporaryHome>())
        #expect(TemporaryHomeSuggestion.candidate(for: trip, temporaryHomes: withLive, now: now) == nil)
    }

    @Test("Not Now keeps the latest 200 trips on this device and forgets the oldest")
    func dismissalsArePruned() throws {
        let suite = "TemporaryHomeSuggestionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ids = (0..<201).map { _ in UUID() }
        for id in ids { TemporaryHomeSuggestion.dismiss(id, defaults: defaults) }
        #expect(!TemporaryHomeSuggestion.isDismissed(ids[0], defaults: defaults))
        #expect(ids.dropFirst().allSatisfy { TemporaryHomeSuggestion.isDismissed($0, defaults: defaults) })
        #expect(defaults.stringArray(forKey: TemporaryHomeSuggestion.dismissalsKey)?.count == 200)
        // Answering again moves a trip to the newest end.
        TemporaryHomeSuggestion.dismiss(ids[1], defaults: defaults)
        TemporaryHomeSuggestion.dismiss(UUID(), defaults: defaults)
        #expect(TemporaryHomeSuggestion.isDismissed(ids[1], defaults: defaults))
        #expect(!TemporaryHomeSuggestion.isDismissed(ids[2], defaults: defaults))
    }
}

// MARK: - Suggestion cache and fingerprints

extension TemporaryHomeSuggestionTests {

    private typealias Suggestion = TemporaryHomeSuggestion

    /// A 2025 date in UTC, moved 273 days later unless `shiftDates` is false.
    private func fixtureDate(_ month: Int, _ day: Int, _ hour: Int = 12, shiftDates: Bool = true) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: 2025, month: month, day: day, hour: hour))!
            .addingTimeInterval(shiftDates ? 23_587_200 : 0)
    }

    private func declarationAnchor(id: UUID = UUID(), from start: Date, to end: Date? = nil) -> HomeAnchor {
        HomeAnchor(
            id: id, kind: .temporary, label: "", latitude: 50.8132, longitude: 4.3502,
            radiusKm: 25, locality: nil, isoCountryCode: nil, startedAt: start, endedAt: end)
    }

    /// A cache-fixture destination stay in Brussels (unlabeled id, unlike
    /// `tripStay(at:from:to:)` above); each argument is one field the evaluation reads.
    private func tripStay(
        _ id: UUID, start: Date? = nil, end: Date? = nil, latitude: Double = 50.8132,
        longitude: Double = 4.3502, isDestination: Bool = true, isAirport: Bool = false,
        locality: String? = "Brussels", country: String? = "BE", zone: String? = "Europe/Brussels"
    ) -> TripStay {
        TripStay(id: id, start: start ?? fixtureDate(9, 2, 8), end: end ?? fixtureDate(9, 9, 8),
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
            tripID: tripID, customName: name, startDate: fixtureDate(9, 1, 8, shiftDates: shiftDates), endDate: end,
            isComplete: complete, declarations: declarations,
            now: now ?? fixtureDate(9, 20, 12, shiftDates: shiftDates), timeZone: zone ?? utc, staysFingerprint: stays)
    }

    @Test("the cache key holds through the day and moves with the trip, its stays, the declarations and the civil day in the given zone")
    func cacheKeyFollowsItsInputs() throws {
        let trip = UUID()
        let base = key(tripID: trip, shiftDates: false)
        #expect(key(tripID: trip, now: fixtureDate(9, 20, 0, shiftDates: false), shiftDates: false) == base)
        #expect(key(tripID: trip, now: fixtureDate(9, 20, 23, shiftDates: false), shiftDates: false) == base)
        #expect(key(tripID: trip, now: fixtureDate(9, 21, 0, shiftDates: false), shiftDates: false) != base)
        // These September UTC times share a day in UTC and cross midnight in Brussels.
        let brussels = try #require(TimeZone(identifier: "Europe/Brussels"))
        #expect(key(tripID: trip, now: fixtureDate(9, 20, 23, shiftDates: false), shiftDates: false) == key(tripID: trip, now: fixtureDate(9, 20, 21, shiftDates: false), shiftDates: false))
        #expect(key(tripID: trip, now: fixtureDate(9, 20, 23, shiftDates: false), zone: brussels, shiftDates: false)
                != key(tripID: trip, now: fixtureDate(9, 20, 21, shiftDates: false), zone: brussels, shiftDates: false))
        #expect(key(tripID: UUID(), shiftDates: false) != base)
        #expect(key(tripID: trip, name: "Erasmus", shiftDates: false) != base)
        #expect(key(tripID: trip, end: fixtureDate(9, 30, shiftDates: false), complete: true, shiftDates: false) != base)
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
        #expect(keyOf([three[0], three[1], tripStay(ids[2], end: fixtureDate(9, 20, 9))]) != keyOf(three))
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
            tripStay(UUID()), tripStay(a, start: fixtureDate(9, 2, 9)), tripStay(a, end: fixtureDate(9, 9, 9)),
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
        let a = declarationAnchor(from: fixtureDate(9, 1))
        let b = declarationAnchor(from: fixtureDate(2, 1), to: fixtureDate(6, 30))
        #expect(Suggestion.declarationsFingerprint([a, b]) == Suggestion.declarationsFingerprint([b, a]))
        #expect(Suggestion.declarationsFingerprint([a]) != Suggestion.declarationsFingerprint([a, b]))
        let ended = declarationAnchor(id: a.id, from: fixtureDate(9, 1), to: fixtureDate(12, 20))
        #expect(Suggestion.declarationsFingerprint([ended]) != Suggestion.declarationsFingerprint([a]))
        let home = HomeAnchor(
            id: UUID(), kind: .home, label: "", latitude: 37.98, longitude: 23.73, radiusKm: 25,
            locality: nil, isoCountryCode: nil, startedAt: fixtureDate(1, 1), endedAt: nil)
        #expect(Suggestion.declarationsFingerprint([a, home]) == Suggestion.declarationsFingerprint([a]))
    }

    @Test("an unchanged trip answers from the cache, nil answers included; a changed key evaluates again and replaces the entry")
    func cacheHitsAndMisses() {
        var cache = Suggestion.Cache()
        var evaluations = 0
        let tripID = UUID()
        let found = Suggestion.Candidate(
            tripID: tripID, placeName: "Brussels",
            prefill: .init(name: nil, coordinate: nil, since: fixtureDate(9, 2, 10), until: nil), isOngoing: true)
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
        let trip = Trip(startDate: fixtureDate(9, 1, 8))
        context.insert(trip)
        var stays: [Stay] = []
        for (start, end) in [(fixtureDate(9, 2, 10), fixtureDate(9, 9, 18)), (fixtureDate(9, 12, 21), fixtureDate(9, 20, 8))] {
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
        let now = fixtureDate(9, 20, 12)
        #expect(Suggestion.candidate(for: trip, temporaryHomes: [], now: now)?.placeName == "Brussels")
        #expect(Suggestion.candidate(for: trip, temporaryHomes: [], now: now)?.placeName == "Brussels")
        for stay in stays { stay.category = .transit }
        try context.save()
        #expect(Suggestion.candidate(for: trip, temporaryHomes: [], now: now) == nil)
    }
}
