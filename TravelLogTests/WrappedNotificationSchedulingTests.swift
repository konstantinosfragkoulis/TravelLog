//
//  WrappedNotificationSchedulingTests.swift
//  TravelLogTests
//
//  YearWrappedGenerator subsystem — the Dec-1 "Wrapped is ready" notification
//  date decision. Pins the stable category identifier and
//  the synchronous Bool return of `scheduleWrappedNotification(forYear:)`: Dec 1
//  of a past year is before `Date.now` → the guard fails, nothing is scheduled,
//  and the caller must NOT mark it scheduled (the dead-reminder fix).
//  NOT @MainActor: both symbols are static and touch no `@Model` type.
//

import Testing
import Foundation
import UserNotifications
@testable import TravelLog

struct WrappedNotificationSchedulingTests {

    @Test("delivery-time notification lookup resolves the app string catalog")
    func deliveryTimeLocalizationResolvesCompiledCatalog() {
        #expect(Bundle.main.bundleURL.pathExtension == "app")

        let key = "notification.country-welcome.body"
        let resolved = NSString.localizedUserNotificationString(
            forKey: key,
            arguments: ["Greece"]
        )

        let template = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        #expect(template != key)
        #expect(resolved != key)
        #expect(resolved == String(format: template, "Greece"))
    }

    @Test("the English country-welcome catalog preserves its wording and argument")
    func englishCountryWelcomeWording() {
        let template = AppLanguagePreference.localizedString(
            key: "notification.country-welcome.body",
            defaultValue: "notification.country-welcome.body",
            languageTag: "en")
        #expect(String(format: template, "Greece") == "You've arrived in Greece. Enjoy your trip!")
    }

    /// Derive concrete past/future years from "now" so the assertions stay valid
    /// regardless of when they run (the decision keys off `fireDate > Date.now`).
    /// Gregorian, like the years the scheduler receives.
    private var currentYear: Int {
        Calendar(identifier: .gregorian).component(.year, from: .now)
    }

    // MARK: - Category identifier

    @Test("the Wrapped notification category identifier is the stable constant")
    func categoryIdentifierIsStable() {
        #expect(YearWrappedGenerator.wrappedNotificationCategory == "WRAPPED_YEAR")
    }

    // MARK: - Date decision

    @Test("years whose Dec 1 is guaranteed past decide by fireDate, not year equality",
          arguments: [-5, -1])
    func yearAtBoundaryOfTodayDecidesByDateNotYearEquality(offset: Int) {
        // currentYear-5 and currentYear-1 both have a Dec 1 that is in the past as
        // of any time in the first half of a year; each must return false. The
        // current year is intentionally excluded — mid-year-vs-Dec-1 is ambiguous
        // to assert deterministically.
        #expect(YearWrappedGenerator.scheduleWrappedNotification(forYear: currentYear + offset) == false)
    }
}
