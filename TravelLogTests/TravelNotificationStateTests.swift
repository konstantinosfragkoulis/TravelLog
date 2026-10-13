//
//  TravelNotificationStateTests.swift
//  TravelLogTests
//
//  Pins that the per-trip notification state follows the user home while an
//  alert is off. Country Welcome: a home-country ping clears
//  the notified set even when the alert is off, and a foreign ping while off
//  neither claims nor releases. Welcome Home: coming home while the alert is
//  off clears the recorded departure, so re-enabling it at home cannot
//  announce a stale trip. The live path is driven through the real
//  `PingRecorder.processLocations`, with the defaults, the resolver and the
//  scheduler scoped to each test.
//

import CoreLocation
import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

private final class DeliveryLog: Sendable {
    private let lock = OSAllocatedUnfairLock<[NotificationService.Delivery]>(initialState: [])
    var all: [NotificationService.Delivery] { lock.withLock { $0 } }
    func append(_ delivery: NotificationService.Delivery) { lock.withLock { $0.append(delivery) } }
}

@MainActor
@Suite("Travel notification state while alerts are off")
struct TravelNotificationStateTests {

    private static let notifiedKey = "notification_notifiedCountryCodes"
    private static let legacyKey = "notification_lastCountryCode"
    private static let wasAbroadKey = "notification_wasAbroad"
    private static let departureKey = "notification_departureDate"

    private let homes: Set<String> = ["GR"]
    private let utc = TimeZone(identifier: "UTC")!
    private let base = Date(timeIntervalSince1970: 1_729_030_400)

    private func withDefaults(
        _ body: (UserDefaults, String) async throws -> Void
    ) async throws {
        let suiteName = "TravelNotificationStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await body(defaults, suiteName)
    }

    // MARK: - Country Welcome decision

    @Test("a home-country ping clears the trip while Country Welcome is off")
    func homeCountryResetsWhileDisabled() async throws {
        try await withDefaults { defaults, _ in
            #expect(NotificationService.shouldDeliverCountryWelcome(
                "FR", homeCountryCodes: homes, enabled: true, defaults: defaults))
            #expect(NotificationService.hasCountryWelcomeDedupState(defaults: defaults))

            #expect(!NotificationService.shouldDeliverCountryWelcome(
                "GR", homeCountryCodes: homes, enabled: false, defaults: defaults))
            #expect(!NotificationService.hasCountryWelcomeDedupState(defaults: defaults))

            // Back on, the next visit to France is a new trip.
            #expect(NotificationService.shouldDeliverCountryWelcome(
                "FR", homeCountryCodes: homes, enabled: true, defaults: defaults))
        }
    }

    @Test("the legacy single-country value alone is pending state and is reset while off")
    func legacyOnlyStateResetsWhileDisabled() async throws {
        try await withDefaults { defaults, _ in
            defaults.set("FR", forKey: Self.legacyKey)
            #expect(NotificationService.hasCountryWelcomeDedupState(defaults: defaults))

            #expect(!NotificationService.shouldDeliverCountryWelcome(
                "GR", homeCountryCodes: homes, enabled: false, defaults: defaults))
            #expect(defaults.object(forKey: Self.legacyKey) == nil)
            #expect(!NotificationService.hasCountryWelcomeDedupState(defaults: defaults))
        }
    }

    @Test("a foreign ping while off neither claims nor releases, so a continuing trip keeps its dedup")
    func foreignWhileDisabledPreservesClaims() async throws {
        try await withDefaults { defaults, _ in
            #expect(NotificationService.shouldDeliverCountryWelcome(
                "FR", homeCountryCodes: homes, enabled: true, defaults: defaults))

            #expect(!NotificationService.shouldDeliverCountryWelcome(
                "IT", homeCountryCodes: homes, enabled: false, defaults: defaults))
            #expect(!NotificationService.shouldDeliverCountryWelcome(
                "FR", homeCountryCodes: homes, enabled: false, defaults: defaults))
            #expect(defaults.stringArray(forKey: Self.notifiedKey) == ["FR"])

            // Back on mid-trip: France stays deduped, Italy was never claimed.
            #expect(!NotificationService.shouldDeliverCountryWelcome(
                "FR", homeCountryCodes: homes, enabled: true, defaults: defaults))
            #expect(NotificationService.shouldDeliverCountryWelcome(
                "IT", homeCountryCodes: homes, enabled: true, defaults: defaults))
        }
    }

    @Test("Country Welcome schedules only while on, and missing country evidence keeps pending state")
    func countryWelcomeSchedulesThroughSeam() async throws {
        try await withDefaults { defaults, suiteName in
            let log = DeliveryLog()
            defaults.set(["FR"], forKey: Self.notifiedKey)
            NotificationService.TestScope.$defaultsSuiteName.withValue(suiteName) {
                NotificationService.TestScope.$deliver.withValue({ log.append($0) }) {
                    defaults.set(false, forKey: NotificationService.countryWelcomeEnabledKey)
                    NotificationService.checkCountryWelcome(
                        isoCountryCode: nil, countryName: nil, homeCountryCodes: homes)
                    NotificationService.checkCountryWelcome(
                        isoCountryCode: "GR", countryName: "Greece", homeCountryCodes: [])
                    #expect(defaults.stringArray(forKey: Self.notifiedKey) == ["FR"])

                    NotificationService.checkCountryWelcome(
                        isoCountryCode: "IT", countryName: "Italy", homeCountryCodes: homes)
                    NotificationService.checkCountryWelcome(
                        isoCountryCode: "GR", countryName: "Greece", homeCountryCodes: homes)
                    #expect(!NotificationService.hasCountryWelcomeDedupState(defaults: defaults))
                    #expect(log.all.isEmpty)

                    defaults.set(true, forKey: NotificationService.countryWelcomeEnabledKey)
                    NotificationService.checkCountryWelcome(
                        isoCountryCode: "FR", countryName: "France", homeCountryCodes: homes)
                    NotificationService.checkCountryWelcome(
                        isoCountryCode: "FR", countryName: "France", homeCountryCodes: homes)
                }
            }
            #expect(log.all == [.countryWelcome("FR")])
        }
    }

    // MARK: - Welcome Home decision

    @Test("coming home while Welcome Home is off clears the departure without announcing")
    func homecomingWhileDisabledClearsDeparture() async throws {
        try await withDefaults { defaults, _ in
            #expect(NotificationService.welcomeHomeDaysToDeliver(
                isWithinHomeRadius: false, enabled: true, now: base, zone: utc, defaults: defaults) == nil)
            #expect(NotificationService.hasWelcomeHomeDepartureState(defaults: defaults))

            let later = base.addingTimeInterval(5 * 86_400)
            #expect(NotificationService.welcomeHomeDaysToDeliver(
                isWithinHomeRadius: true, enabled: false, now: later, zone: utc, defaults: defaults) == nil)
            #expect(!NotificationService.hasWelcomeHomeDepartureState(defaults: defaults))
            #expect(defaults.object(forKey: Self.departureKey) == nil)

            // Re-enabled at home: no stale "Welcome home" for the old trip.
            #expect(NotificationService.welcomeHomeDaysToDeliver(
                isWithinHomeRadius: true, enabled: true,
                now: later.addingTimeInterval(3600), zone: utc, defaults: defaults) == nil)
        }
    }

    @Test("Welcome Home on announces the inclusive days and clears both keys")
    func homecomingWhileEnabledAnnounces() async throws {
        try await withDefaults { defaults, _ in
            #expect(NotificationService.welcomeHomeDaysToDeliver(
                isWithinHomeRadius: false, enabled: true, now: base, zone: utc, defaults: defaults) == nil)
            let later = base.addingTimeInterval(3 * 86_400)
            let expected = NotificationService.welcomeHomeDisplayDays(departure: base, now: later, zone: utc)
            #expect(expected != nil)
            #expect(NotificationService.welcomeHomeDaysToDeliver(
                isWithinHomeRadius: true, enabled: true, now: later, zone: utc, defaults: defaults) == expected)
            #expect(!NotificationService.hasWelcomeHomeDepartureState(defaults: defaults))
            #expect(defaults.object(forKey: Self.departureKey) == nil)
        }
    }

    @Test("off outside home records no departure but keeps one already recorded")
    func awayWhileDisabledTracksNothingNew() async throws {
        try await withDefaults { defaults, _ in
            #expect(NotificationService.welcomeHomeDaysToDeliver(
                isWithinHomeRadius: false, enabled: false, now: base, zone: utc, defaults: defaults) == nil)
            #expect(!NotificationService.hasWelcomeHomeDepartureState(defaults: defaults))
            #expect(defaults.object(forKey: Self.departureKey) == nil)

            // Re-enabled abroad with no departure: the next observation starts one.
            let reenabled = base.addingTimeInterval(86_400)
            _ = NotificationService.welcomeHomeDaysToDeliver(
                isWithinHomeRadius: false, enabled: true, now: reenabled, zone: utc, defaults: defaults)
            #expect(defaults.double(forKey: Self.departureKey) == reenabled.timeIntervalSince1970)

            // Off and on again abroad: the recorded departure is kept.
            _ = NotificationService.welcomeHomeDaysToDeliver(
                isWithinHomeRadius: false, enabled: false,
                now: reenabled.addingTimeInterval(86_400), zone: utc, defaults: defaults)
            _ = NotificationService.welcomeHomeDaysToDeliver(
                isWithinHomeRadius: false, enabled: true,
                now: reenabled.addingTimeInterval(2 * 86_400), zone: utc, defaults: defaults)
            #expect(defaults.double(forKey: Self.departureKey) == reenabled.timeIntervalSince1970)
        }
    }

    @Test("a homecoming with no departure timestamp still clears the flag")
    func homecomingWithoutTimestampClears() async throws {
        try await withDefaults { defaults, _ in
            defaults.set(true, forKey: Self.wasAbroadKey)
            #expect(NotificationService.welcomeHomeDaysToDeliver(
                isWithinHomeRadius: true, enabled: true, now: base, zone: utc, defaults: defaults) == nil)
            #expect(!NotificationService.hasWelcomeHomeDepartureState(defaults: defaults))
        }
    }

    @Test("Welcome Home schedules nothing for a homecoming while off")
    func welcomeHomeSchedulesThroughSeam() async throws {
        try await withDefaults { defaults, suiteName in
            let log = DeliveryLog()
            NotificationService.TestScope.$defaultsSuiteName.withValue(suiteName) {
                NotificationService.TestScope.$deliver.withValue({ log.append($0) }) {
                    defaults.set(true, forKey: Self.wasAbroadKey)
                    defaults.set(Date.now.addingTimeInterval(-3 * 86_400).timeIntervalSince1970,
                                 forKey: Self.departureKey)
                    defaults.set(false, forKey: NotificationService.welcomeHomeEnabledKey)
                    NotificationService.checkWelcomeHome(isWithinHomeRadius: true)
                    #expect(log.all.isEmpty)
                    #expect(!NotificationService.hasWelcomeHomeDepartureState(defaults: defaults))

                    defaults.set(true, forKey: NotificationService.welcomeHomeEnabledKey)
                    NotificationService.checkWelcomeHome(isWithinHomeRadius: true)
                    #expect(log.all.isEmpty)

                    defaults.set(true, forKey: Self.wasAbroadKey)
                    defaults.set(Date.now.addingTimeInterval(-3 * 86_400).timeIntervalSince1970,
                                 forKey: Self.departureKey)
                    NotificationService.checkWelcomeHome(isWithinHomeRadius: true)
                }
            }
            #expect(log.all.count == 1)
            if case .welcomeHome(let days) = log.all.first {
                #expect((3...5).contains(days), "\(days)")
            } else {
                Issue.record("expected a Welcome Home delivery, got \(log.all)")
            }
        }
    }

    // MARK: - Live ping path

    private static let athens = (latitude: 37.9838, longitude: 23.7275)
    private static let rome = (latitude: 41.8848, longitude: 12.4414)
    private static let paris = (latitude: 48.8425, longitude: 2.4310)

    /// Offline resolution by longitude band, so the test does not depend on
    /// the bundled geocoder. Rows at `unresolvedLongitude` resolve to nothing.
    private nonisolated static let unresolvedLongitude = -150.0

    private nonisolated static func resolve(longitude: Double) -> GeocodeResolver.Result? {
        if longitude == unresolvedLongitude { return nil }
        let (country, iso) = longitude > 20 ? ("Greece", "GR") : longitude > 10 ? ("Italy", "IT") : ("France", "FR")
        return GeocodeResolver.Result(
            country: country, isoCountryCode: iso, administrativeArea: nil,
            metroName: nil, localityName: nil, subLocalityName: nil, islandName: nil)
    }

    private func candidate(_ offsetHours: Double, _ coordinate: (latitude: Double, longitude: Double)) -> LiveLocationCandidate {
        LiveLocationCandidate(
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude),
                altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                course: -1, speed: -1, timestamp: base.addingTimeInterval(offsetHours * 3600)),
            source: .foregroundStream)
    }

    private func makeRecorder() throws -> PingRecorder {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let home = Home(label: "Home", latitude: Self.athens.latitude, longitude: Self.athens.longitude)
        home.isoCountryCode = "GR"
        context.insert(home)
        try context.save()
        return PingRecorder(modelContainer: container)
    }

    private func live(
        suiteName: String, log: DeliveryLog, _ body: () async throws -> Void
    ) async throws {
        try await NotificationService.TestScope.$defaultsSuiteName.withValue(suiteName) {
            try await NotificationService.TestScope.$deliver.withValue({ log.append($0) }) {
                try await GeocodeResolver.TestHook.$resolve.withValue({ _, longitude in
                    Self.resolve(longitude: longitude)
                }) {
                    try await body()
                }
            }
        }
    }

    @Test("live pings reset a Country Welcome trip at home while the alert is off")
    func liveHomePingResetsWhileDisabled() async throws {
        try await withDefaults { defaults, suiteName in
            let recorder = try makeRecorder()
            let log = DeliveryLog()
            defaults.set(false, forKey: NotificationService.countryWelcomeEnabledKey)
            defaults.set(false, forKey: NotificationService.welcomeHomeEnabledKey)
            defaults.set(["FR"], forKey: Self.notifiedKey)

            try await live(suiteName: suiteName, log: log) {
                // Abroad while off: nothing new is claimed and France stays claimed.
                await recorder.processLocations([candidate(0, Self.rome)],
                                                  defaults: TestSupport.liveFloorFreeDefaults)
                #expect(defaults.stringArray(forKey: Self.notifiedKey) == ["FR"])

                // No country evidence: the pending state is kept.
                await recorder.processLocations([candidate(2, (latitude: 0, longitude: Self.unresolvedLongitude))],
                                                  defaults: TestSupport.liveFloorFreeDefaults)
                #expect(defaults.stringArray(forKey: Self.notifiedKey) == ["FR"])

                // Home while off: the trip ends.
                await recorder.processLocations([candidate(4, Self.athens)],
                                                  defaults: TestSupport.liveFloorFreeDefaults)
                #expect(!NotificationService.hasCountryWelcomeDedupState(defaults: defaults))

                // Back on, the next visit to France is welcomed.
                defaults.set(true, forKey: NotificationService.countryWelcomeEnabledKey)
                await recorder.processLocations([candidate(30, Self.paris)],
                                                  defaults: TestSupport.liveFloorFreeDefaults)
            }
            #expect(log.all == [.countryWelcome("FR")])
            #expect(!defaults.bool(forKey: Self.wasAbroadKey))
        }
    }

    @Test("live pings keep a Country Welcome trip deduped across an off and on abroad")
    func liveTripContinuesAcrossToggle() async throws {
        try await withDefaults { defaults, suiteName in
            let recorder = try makeRecorder()
            let log = DeliveryLog()
            defaults.set(true, forKey: NotificationService.countryWelcomeEnabledKey)
            defaults.set(false, forKey: NotificationService.welcomeHomeEnabledKey)

            try await live(suiteName: suiteName, log: log) {
                await recorder.processLocations([candidate(0, Self.paris)],
                                                  defaults: TestSupport.liveFloorFreeDefaults)
                defaults.set(false, forKey: NotificationService.countryWelcomeEnabledKey)
                await recorder.processLocations([candidate(2, Self.rome)],
                                                  defaults: TestSupport.liveFloorFreeDefaults)
                defaults.set(true, forKey: NotificationService.countryWelcomeEnabledKey)
                await recorder.processLocations([candidate(4, Self.paris)],
                                                  defaults: TestSupport.liveFloorFreeDefaults)
            }
            #expect(log.all == [.countryWelcome("FR")])
            #expect(defaults.stringArray(forKey: Self.notifiedKey) == ["FR"])
        }
    }
}
