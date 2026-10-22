//
//  PermissionRobustnessTests.swift
//  TravelLogTests
//

import Foundation
import Testing
import UserNotifications
@testable import TravelLog

@Suite("Permission robustness decisions")
struct PermissionRobustnessTests {

    @Test("notification grant enables only preferences that have never been written")
    func notificationDefaultsAreAbsentOnly() throws {
        let suiteName = "PermissionRobustnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: NotificationService.countryWelcomeEnabledKey)

        NotificationService.enableDefaultFeaturesIfAuthorized(
            .authorized,
            defaults: defaults)

        #expect(defaults.object(
            forKey: NotificationService.countryWelcomeEnabledKey) != nil)
        #expect(!defaults.bool(
            forKey: NotificationService.countryWelcomeEnabledKey))
        #expect(defaults.bool(
            forKey: NotificationService.welcomeHomeEnabledKey))
    }

    @Test("notification statuses other than authorized leave absent preferences absent")
    func notificationDefaultsRequireFullAuthorization() throws {
        let suiteName = "PermissionRobustnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for status: UNAuthorizationStatus in [
            .notDetermined, .denied, .provisional, .ephemeral,
        ] {
            NotificationService.enableDefaultFeaturesIfAuthorized(
                status,
                defaults: defaults)
        }

        #expect(defaults.object(
            forKey: NotificationService.countryWelcomeEnabledKey) == nil)
        #expect(defaults.object(
            forKey: NotificationService.welcomeHomeEnabledKey) == nil)
    }

    @Test("country welcome fires once per foreign country per trip")
    func countryWelcomeDedupPerTrip() throws {
        let suiteName = "PermissionRobustnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let homes: Set<String> = ["GR"]

        func claim(_ code: String) -> Bool {
            NotificationService.claimCountryWelcome(
                code, homeCountryCodes: homes, defaults: defaults)
        }

        #expect(claim("FR"))
        #expect(claim("MC"))
        #expect(!claim("FR"))
        #expect(!claim("MC"))
        #expect(!claim("GR"))
        #expect(claim("FR"))

        // A failed schedule releases the claim so the next ping retries.
        #expect(claim("IT"))
        let tripEpoch = try #require(defaults.string(forKey: "notification_countryWelcomeTripEpoch"))
        NotificationService.releaseCountryWelcome("IT", tripEpoch: tripEpoch, defaults: defaults)
        #expect(claim("IT"))
        #expect(!claim("FR"))
    }

    @Test("an old scheduling failure cannot release a newer trip's country claim")
    func countryWelcomeObsoleteFailure() throws {
        let suiteName = "PermissionRobustnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let homes: Set<String> = ["GR"]
        let epochKey = "notification_countryWelcomeTripEpoch"

        #expect(NotificationService.claimCountryWelcome(
            "FR", homeCountryCodes: homes, defaults: defaults))
        let oldEpoch = try #require(defaults.string(forKey: epochKey))

        // The old add completion remains pending as a disabled home ping ends
        // that trip and a new trip claims the same country.
        #expect(!NotificationService.shouldDeliverCountryWelcome(
            "GR", homeCountryCodes: homes, enabled: false, defaults: defaults))
        #expect(defaults.string(forKey: epochKey) == nil)
        #expect(NotificationService.claimCountryWelcome(
            "FR", homeCountryCodes: homes, defaults: defaults))
        let newEpoch = try #require(defaults.string(forKey: epochKey))
        #expect(newEpoch != oldEpoch)

        // The callback reopens its captured suite rather than retaining a
        // task-local scope or affecting standard defaults.
        let callbackDefaults = try #require(UserDefaults(suiteName: suiteName))
        NotificationService.releaseCountryWelcome(
            "FR", tripEpoch: oldEpoch, defaults: callbackDefaults)
        NotificationService.releaseCountryWelcome(
            "FR", tripEpoch: nil, defaults: callbackDefaults)
        #expect(!NotificationService.claimCountryWelcome(
            "FR", homeCountryCodes: homes, defaults: defaults))

        // A failure belonging to the current trip must still allow retry.
        NotificationService.releaseCountryWelcome(
            "FR", tripEpoch: newEpoch, defaults: callbackDefaults)
        #expect(NotificationService.claimCountryWelcome(
            "FR", homeCountryCodes: homes, defaults: defaults))
        #expect(defaults.string(forKey: epochKey) == newEpoch)
    }

    @Test("country welcome honours the legacy single-country dedup value")
    func countryWelcomeLegacyDedup() throws {
        let suiteName = "PermissionRobustnessTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let homes: Set<String> = ["GR"]
        defaults.set("FR", forKey: "notification_lastCountryCode")

        #expect(!NotificationService.claimCountryWelcome(
            "FR", homeCountryCodes: homes, defaults: defaults))
        #expect(defaults.string(forKey: "notification_countryWelcomeTripEpoch") == nil)
        #expect(NotificationService.claimCountryWelcome(
            "MC", homeCountryCodes: homes, defaults: defaults))
        let tripEpoch = try #require(defaults.string(forKey: "notification_countryWelcomeTripEpoch"))
        NotificationService.releaseCountryWelcome("MC", tripEpoch: tripEpoch, defaults: defaults)
        #expect(NotificationService.claimCountryWelcome(
            "MC", homeCountryCodes: homes, defaults: defaults))
        #expect(!NotificationService.claimCountryWelcome(
            "FR", homeCountryCodes: homes, defaults: defaults))
        #expect(!NotificationService.claimCountryWelcome(
            "GR", homeCountryCodes: homes, defaults: defaults))
        #expect(defaults.object(forKey: "notification_lastCountryCode") == nil)
        #expect(defaults.string(forKey: "notification_countryWelcomeTripEpoch") == nil)
        #expect(NotificationService.claimCountryWelcome(
            "FR", homeCountryCodes: homes, defaults: defaults))
    }

    @Test("calendar revocation cleanup runs once after a grant or existing rows")
    func calendarRevocationDecision() {
        #expect(!CalendarEnricher.shouldCleanAfterRevocation(
            previouslyGranted: false,
            hasCalendarRows: false,
            authorizationDetermined: true,
            cleanupAlreadyCompleted: false))
        #expect(CalendarEnricher.shouldCleanAfterRevocation(
            previouslyGranted: true,
            hasCalendarRows: false,
            authorizationDetermined: true,
            cleanupAlreadyCompleted: false))
        #expect(CalendarEnricher.shouldCleanAfterRevocation(
            previouslyGranted: false,
            hasCalendarRows: true,
            authorizationDetermined: true,
            cleanupAlreadyCompleted: false))
        #expect(!CalendarEnricher.shouldCleanAfterRevocation(
            previouslyGranted: true,
            hasCalendarRows: true,
            authorizationDetermined: true,
            cleanupAlreadyCompleted: true))
        #expect(!CalendarEnricher.shouldCleanAfterRevocation(
            previouslyGranted: false,
            hasCalendarRows: true,
            authorizationDetermined: false,
            cleanupAlreadyCompleted: false))
        #expect(CalendarEnricher.shouldCleanAfterRevocation(
            previouslyGranted: true,
            hasCalendarRows: true,
            authorizationDetermined: false,
            cleanupAlreadyCompleted: false))
    }

    @Test("calendar revocation deletes only trips that have not started")
    func calendarFutureBoundary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(CalendarEnricher.isNotYetStarted(
            startDate: now.addingTimeInterval(1),
            now: now))
        #expect(!CalendarEnricher.isNotYetStarted(
            startDate: now,
            now: now))
        #expect(!CalendarEnricher.isNotYetStarted(
            startDate: now.addingTimeInterval(-1),
            now: now))
    }

    @Test("home save warns only when both geocode place fields are absent")
    func unmappedHomeDecision() {
        #expect(HomeSaveDecision.requiresUnmappedConfirmation(
            locality: nil,
            administrativeArea: nil))
        #expect(HomeSaveDecision.requiresUnmappedConfirmation(
            locality: "  ",
            administrativeArea: "\n"))
        #expect(!HomeSaveDecision.requiresUnmappedConfirmation(
            locality: "Athens",
            administrativeArea: nil))
        #expect(!HomeSaveDecision.requiresUnmappedConfirmation(
            locality: nil,
            administrativeArea: "Attica"))
    }

    @MainActor
    @Test("Wrapped preparation failure applies only to the active request and resets")
    func wrappedPreparationState() {
        let presenter = WrappedPresenter(forTesting: ())
        presenter.requestYear(2026)

        presenter.finishPreparing(forYear: 2025, outcome: .insufficientData)
        #expect(presenter.preparationFailure == nil)
        presenter.finishPreparing(forYear: 2025, outcome: .failed)
        #expect(presenter.preparationFailure == nil)

        presenter.finishPreparing(forYear: 2026, outcome: .insufficientData)
        #expect(presenter.preparationFailure
            == WrappedPresenter.PreparationFailure(year: 2026, reason: .insufficientData))

        presenter.requestYear(2026)
        #expect(presenter.preparationFailure == nil)

        presenter.finishPreparing(forYear: 2026, outcome: .created)
        #expect(presenter.preparationFailure == nil)

        presenter.clear()
        #expect(presenter.requestedYear == nil)
        #expect(presenter.preparationFailure == nil)
    }

    @MainActor
    @Test("a failed or busy Wrapped preparation is terminal and distinct from too little travel",
          arguments: [WrappedGenerationOutcome.failed, .busy])
    func wrappedPreparationFailureIsNotInsufficientData(outcome: WrappedGenerationOutcome) {
        let presenter = WrappedPresenter(forTesting: ())
        presenter.requestYear(2026)

        presenter.finishPreparing(forYear: 2026, outcome: outcome)
        #expect(presenter.preparationFailure
            == WrappedPresenter.PreparationFailure(year: 2026, reason: .failed))

        // A row that lands later (the preparation's own or a synced one)
        // clears the terminal state.
        presenter.finishPreparing(forYear: 2026, outcome: .existing)
        #expect(presenter.preparationFailure == nil)
    }
}
