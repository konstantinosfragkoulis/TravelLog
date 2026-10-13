//
//  TemporaryHomeSuggestionTests.swift
//  TravelLogTests
//
//  "Living in Brussels for now?": which trips ask, what the question
//  prefills, and that Not Now is remembered on this device without changing
//  which trips are candidates. Everything is in UTC unless a stay names its
//  own zone, and expected values are written out by hand.
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
