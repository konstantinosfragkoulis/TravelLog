//
//  TemporaryHomeNotificationTests.swift
//  TravelLogTests
//
//  Country Welcome stays quiet in the country of a temporary home whose
//  dates cover now, and a ping there ends the country trip as a home-country
//  ping does. An ended or not yet started temporary home changes nothing.
//  A real Home with no country stamped takes its country from its own home
//  stays, never from the ones a temporary home owns.
//  The set is pinned as a pure function, then through the real
//  `PingRecorder.processLocations` with the defaults, the resolver and the
//  scheduler scoped to each test.
//

import CoreLocation
import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

private final class WelcomeLog: Sendable {
    private let lock = OSAllocatedUnfairLock<[NotificationService.Delivery]>(initialState: [])
    var all: [NotificationService.Delivery] { lock.withLock { $0 } }
    func append(_ delivery: NotificationService.Delivery) { lock.withLock { $0.append(delivery) } }
}

@MainActor
@Suite("Country Welcome around a temporary home")
struct TemporaryHomeNotificationTests {

    private let now = Date(timeIntervalSinceReferenceDate: 804_233_600)
    private let realHomes: Set<String> = ["GR"]

    private func days(_ count: Double) -> TimeInterval { count * 86_400 }

    private func temporaryHome(
        iso: String?, startsIn start: Double, endsIn end: Double?
    ) -> HomeAnchor {
        HomeAnchor(
            id: UUID(), kind: .temporary, label: "Erasmus",
            latitude: 50.8562, longitude: 4.4066, radiusKm: 25,
            locality: "Brussels", isoCountryCode: iso,
            startedAt: now.addingTimeInterval(days(start)),
            endedAt: end.map { now.addingTimeInterval(days($0)) })
    }

    private func quietCodes(_ temporaryHomes: [HomeAnchor]) -> Set<String> {
        PingRecorder.countryWelcomeQuietCodes(
            homeCountryCodes: realHomes, temporaryHomes: temporaryHomes, now: now)
    }

    // MARK: - The quiet set

    @Test("with no temporary home the quiet set is the real-home set")
    func noTemporaryHomeKeepsTheRealHomeSet() {
        #expect(quietCodes([]) == ["GR"])
    }

    @Test("a temporary home whose dates cover now adds its country")
    func activeTemporaryHomeAddsItsCountry() {
        #expect(quietCodes([temporaryHome(iso: "BE", startsIn: -30, endsIn: 120)]) == ["GR", "BE"])
        #expect(quietCodes([temporaryHome(iso: "BE", startsIn: -30, endsIn: nil)]) == ["GR", "BE"])
    }

    @Test("the start and end instants themselves count as active")
    func boundaryInstantsAreActive() {
        #expect(quietCodes([temporaryHome(iso: "BE", startsIn: 0, endsIn: 120)]) == ["GR", "BE"])
        #expect(quietCodes([temporaryHome(iso: "BE", startsIn: -30, endsIn: 0)]) == ["GR", "BE"])
    }

    @Test("an ended temporary home adds nothing")
    func endedTemporaryHomeAddsNothing() {
        #expect(quietCodes([temporaryHome(iso: "BE", startsIn: -150, endsIn: -1)]) == ["GR"])
    }

    @Test("a temporary home that has not started yet adds nothing")
    func futureTemporaryHomeAddsNothing() {
        #expect(quietCodes([temporaryHome(iso: "BE", startsIn: 1, endsIn: 150)]) == ["GR"])
        #expect(quietCodes([temporaryHome(iso: "BE", startsIn: 1, endsIn: nil)]) == ["GR"])
    }

    @Test("an active temporary home with no country code adds nothing")
    func missingCountryCodeAddsNothing() {
        #expect(quietCodes([temporaryHome(iso: nil, startsIn: -30, endsIn: 120)]) == ["GR"])
    }

    @Test("only the active ones among several temporary homes add their countries")
    func onlyActiveOnesCount() {
        let codes = quietCodes([
            temporaryHome(iso: "BE", startsIn: -30, endsIn: 120),
            temporaryHome(iso: "IT", startsIn: -400, endsIn: -200),
            temporaryHome(iso: "ES", startsIn: 200, endsIn: nil),
        ])
        #expect(codes == ["GR", "BE"])
    }

    @Test("with no resolved real-home country the set stays empty, so the check stays silent")
    func unresolvedRealHomeStaysSilent() {
        let codes = PingRecorder.countryWelcomeQuietCodes(
            homeCountryCodes: [],
            temporaryHomes: [temporaryHome(iso: "BE", startsIn: -30, endsIn: 120)],
            now: now)
        #expect(codes.isEmpty)
    }

    @Test("a ping in the temporary home's country is not welcomed and ends the country trip")
    func quietCountryEndsTheTrip() throws {
        let suiteName = "TemporaryHomeNotificationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let quiet = quietCodes([temporaryHome(iso: "BE", startsIn: -30, endsIn: 120)])

        #expect(NotificationService.shouldDeliverCountryWelcome(
            "FR", homeCountryCodes: quiet, enabled: true, defaults: defaults))
        #expect(!NotificationService.shouldDeliverCountryWelcome(
            "BE", homeCountryCodes: quiet, enabled: true, defaults: defaults))
        #expect(!NotificationService.hasCountryWelcomeDedupState(defaults: defaults))
        // Back from the base, the next visit to France is a new trip.
        #expect(NotificationService.shouldDeliverCountryWelcome(
            "FR", homeCountryCodes: quiet, enabled: true, defaults: defaults))
    }

    // MARK: - Live ping path

    private typealias Coordinate = (latitude: Double, longitude: Double)
    private static let athens: Coordinate = (37.9838, 23.7275)
    private static let rome: Coordinate = (41.8684, 12.4207)
    private static let paris: Coordinate = (48.8896, 2.3705)
    /// About 47 km apart, inside the same 50 km Home ring.
    private static let roermond: Coordinate = (51.1972, 5.9896)
    private static let bedburg: Coordinate = (50.9912, 6.5718)

    /// Offline resolution by longitude band, so the test does not depend on
    /// the bundled geocoder.
    private nonisolated static func resolve(longitude: Double) -> GeocodeResolver.Result? {
        let (country, iso): (String, String) = longitude > 20 ? ("Greece", "GR")
            : longitude > 10 ? ("Italy", "IT")
            : longitude > 6.2807 ? ("Germany", "DE")
            : longitude > 5 ? ("Netherlands", "NL")
            : ("France", "FR")
        return GeocodeResolver.Result(
            country: country, isoCountryCode: iso, administrativeArea: nil,
            metroName: nil, localityName: nil, subLocalityName: nil, islandName: nil)
    }

    private func candidate(_ offsetHours: Double, _ coordinate: Coordinate) -> LiveLocationCandidate {
        LiveLocationCandidate(
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                course: -1, speed: -1,
                timestamp: Date(timeIntervalSince1970: 1_704_233_600).addingTimeInterval(offsetHours * 3_600)),
            source: .foregroundStream)
    }

    /// A Greek real Home and a temporary home in Paris. The live check reads
    /// the clock, so the dates are offsets from the real now, weeks wide.
    private func makeRecorder(startsIn start: Double, endsIn end: Double?) throws -> PingRecorder {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let home = Home(label: "Home", latitude: Self.athens.latitude, longitude: Self.athens.longitude)
        home.isoCountryCode = "GR"
        context.insert(home)
        let temporary = TemporaryHome(
            label: "Erasmus", latitude: Self.paris.latitude, longitude: Self.paris.longitude,
            startedAt: Date.now.addingTimeInterval(days(start)),
            endedAt: end.map { Date.now.addingTimeInterval(days($0)) })
        temporary.isoCountryCode = "FR"
        context.insert(temporary)
        try context.save()
        return PingRecorder(modelContainer: container)
    }

    private func live(
        _ body: (UserDefaults, WelcomeLog) async throws -> Void
    ) async throws {
        let suiteName = "TemporaryHomeNotificationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: NotificationService.countryWelcomeEnabledKey)
        defaults.set(false, forKey: NotificationService.welcomeHomeEnabledKey)
        let log = WelcomeLog()
        try await NotificationService.TestScope.$defaultsSuiteName.withValue(suiteName) {
            try await NotificationService.TestScope.$deliver.withValue({ log.append($0) }) {
                try await GeocodeResolver.TestHook.$resolve.withValue({ _, longitude in
                    Self.resolve(longitude: longitude)
                }) {
                    try await body(defaults, log)
                }
            }
        }
    }

    @Test("live pings at an active temporary home are not welcomed and end the country trip")
    func liveActiveTemporaryHomeIsQuiet() async throws {
        let recorder = try makeRecorder(startsIn: -30, endsIn: 30)
        try await live { defaults, log in
            // At the base: no welcome to its country.
            await recorder.processLocations([candidate(0, Self.paris)],
                                              defaults: TestSupport.liveFloorFreeDefaults)
            #expect(log.all.isEmpty)

            // A weekend away is welcomed.
            await recorder.processLocations([candidate(2, Self.rome)],
                                              defaults: TestSupport.liveFloorFreeDefaults)
            #expect(log.all == [.countryWelcome("IT")])

            // Back at the base the country trip ends, so the next visit is new.
            await recorder.processLocations([candidate(4, Self.paris)],
                                              defaults: TestSupport.liveFloorFreeDefaults)
            #expect(!NotificationService.hasCountryWelcomeDedupState(defaults: defaults))
            await recorder.processLocations([candidate(30, Self.rome)],
                                              defaults: TestSupport.liveFloorFreeDefaults)
            #expect(log.all == [.countryWelcome("IT"), .countryWelcome("IT")])
        }
    }

    @Test("live pings in the country of an ended or not yet started temporary home are welcomed",
          arguments: [(-60.0, -30.0), (30.0, 60.0)])
    func liveInactiveTemporaryHomeIsWelcomed(startsIn: Double, endsIn: Double) async throws {
        let recorder = try makeRecorder(startsIn: startsIn, endsIn: endsIn)
        try await live { _, log in
            await recorder.processLocations([candidate(0, Self.paris)],
                                              defaults: TestSupport.liveFloorFreeDefaults)
            #expect(log.all == [.countryWelcome("FR")])
        }
    }

    // MARK: - A real Home with no country stamped

    /// A Roermond Home with no country stamped and a 50 km ring, which
    /// reaches Bedburg. Three home stays in Bedburg, two in Roermond, all in
    /// the last month. With `withTemporaryHome`, an active temporary home in
    /// Bedburg; with `recordedByIt` too, it recorded the three German stays,
    /// as a "This Was Home" correction stamps them for the nearest covering
    /// centre. Without it they are the real Home's, as the classifier records
    /// a home stay inside a real Home's ring. Dates are offsets from the real
    /// now, as in `makeRecorder`.
    private func makeBorderRecorder(
        withTemporaryHome: Bool, recordedByIt: Bool = true
    ) throws -> PingRecorder {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(Home(
            label: "Home", latitude: Self.roermond.latitude, longitude: Self.roermond.longitude,
            radiusKm: 50, startedAt: Date.now.addingTimeInterval(-days(2_000))))
        var owner: UUID?
        if withTemporaryHome {
            let temporary = TemporaryHome(
                label: "", latitude: Self.bedburg.latitude, longitude: Self.bedburg.longitude,
                startedAt: Date.now.addingTimeInterval(-days(30)),
                endedAt: Date.now.addingTimeInterval(days(30)))
            temporary.isoCountryCode = "DE"
            context.insert(temporary)
            if recordedByIt { owner = temporary.id }
        }
        func homeStay(at place: Coordinate, iso: String, daysAgo: Double, by owner: UUID? = nil) {
            let start = Date.now.addingTimeInterval(-days(daysAgo))
            let stay = Stay(
                startTime: start, endTime: start.addingTimeInterval(8 * 3_600),
                centroidLatitude: place.latitude, centroidLongitude: place.longitude,
                h3IndexRes6: "", pingCount: 4, distanceFromHomeKm: 0, pingIDs: [],
                timeZoneIdentifier: "UTC")
            stay.category = .home
            stay.temporaryHomeID = owner
            stay.isoCountryCode = iso
            context.insert(stay)
        }
        for daysAgo in [27.0, 24.0, 21.0] {
            homeStay(at: Self.bedburg, iso: "DE", daysAgo: daysAgo, by: owner)
        }
        for daysAgo in [18.0, 15.0] { homeStay(at: Self.roermond, iso: "NL", daysAgo: daysAgo) }
        try context.save()
        return PingRecorder(modelContainer: container)
    }

    @Test("home stays the real Home recorded decide its country even beside a temporary home, never the nearest centre: the German majority makes the Netherlands an arrival")
    func liveUnstampedHomeBesideATemporaryHomeReadsTheRecord() async throws {
        let recorder = try makeBorderRecorder(withTemporaryHome: true, recordedByIt: false)
        try await live { _, log in
            await recorder.processLocations([candidate(0, Self.bedburg)],
                                              defaults: TestSupport.liveFloorFreeDefaults)
            #expect(log.all.isEmpty)
            await recorder.processLocations([candidate(2, Self.roermond)],
                                              defaults: TestSupport.liveFloorFreeDefaults)
            #expect(log.all == [.countryWelcome("NL")])
        }
    }

    @Test("home stays a temporary home recorded do not decide an unstamped real Home's country: neither the real home's country nor the temporary home's is welcomed, and a third one is")
    func liveUnstampedHomeBesideATemporaryHomeKeepsBothCountriesQuiet() async throws {
        let recorder = try makeBorderRecorder(withTemporaryHome: true)
        try await live { _, log in
            // Back at the real home: the Netherlands, by its own two stays.
            await recorder.processLocations([candidate(0, Self.roermond)],
                                              defaults: TestSupport.liveFloorFreeDefaults)
            #expect(log.all.isEmpty)

            // At the temporary home.
            await recorder.processLocations([candidate(2, Self.bedburg)],
                                              defaults: TestSupport.liveFloorFreeDefaults)
            #expect(log.all.isEmpty)

            // The quiet set is not empty: a third country is still an arrival.
            await recorder.processLocations([candidate(4, Self.paris)],
                                              defaults: TestSupport.liveFloorFreeDefaults)
            #expect(log.all == [.countryWelcome("FR")])
        }
    }

    @Test("with no temporary home the same home stays decide the unstamped Home's country as before: the German majority makes the Netherlands an arrival")
    func liveUnstampedHomeWithoutATemporaryHomeResolvesAsBefore() async throws {
        let recorder = try makeBorderRecorder(withTemporaryHome: false)
        try await live { _, log in
            await recorder.processLocations([candidate(0, Self.bedburg)],
                                              defaults: TestSupport.liveFloorFreeDefaults)
            #expect(log.all.isEmpty)
            await recorder.processLocations([candidate(2, Self.roermond)],
                                              defaults: TestSupport.liveFloorFreeDefaults)
            #expect(log.all == [.countryWelcome("NL")])
        }
    }
}
