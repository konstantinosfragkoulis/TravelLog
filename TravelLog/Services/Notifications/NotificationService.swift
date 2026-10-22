//
//  NotificationService.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 6/5/26.
//

import Foundation
import UserNotifications
import os.log

/// Handles local push notifications for travel events.
///
/// Two notification types:
/// 1. **Country Welcome** - fires when the user arrives in a foreign country
/// 2. **Welcome Home** - fires when the user returns home after >= 1 day away
///
/// All state is stored in UserDefaults (not SwiftData) because notification
/// dedup state is ephemeral, device-local, and doesn't need CloudKit sync.
///
/// Called from `PingRecorder.processOneLocation()` on every SLC ping,
/// including background relaunches. Notification scheduling is <100ms
/// and fits comfortably within the ~10 second background budget.
enum NotificationService {

    private nonisolated static let logger = Logger(subsystem: "com.travellog.app", category: "Notifications")

    // MARK: - UserDefaults Keys (public for @AppStorage bindings)

    nonisolated static let countryWelcomeEnabledKey = "countryWelcomeEnabled"
    nonisolated static let welcomeHomeEnabledKey = "welcomeHomeEnabled"

    // MARK: - Internal State Keys

    /// Legacy single-country dedup value, read only so a trip in progress at
    /// upgrade keeps its suppression. Cleared on the next home ping.
    private nonisolated static let lastNotifiedCountryCodeKey = "notification_lastCountryCode"
    private nonisolated static let notifiedCountryCodesKey = "notification_notifiedCountryCodes"
    private nonisolated static let countryWelcomeTripEpochKey = "notification_countryWelcomeTripEpoch"
    private nonisolated static let wasAbroadKey = "notification_wasAbroad"
    private nonisolated static let departureDateKey = "notification_departureDate"

    // MARK: - State Defaults

    #if DEBUG
    nonisolated enum TestScope {
        /// Routes the toggles and per-trip state to an isolated suite.
        @TaskLocal static var defaultsSuiteName: String?
        /// Receives each notification that would be scheduled, instead of
        /// the notification center.
        @TaskLocal static var deliver: (@Sendable (Delivery) -> Void)?
    }
    #endif

    /// A notification the travel checks decided to schedule.
    nonisolated enum Delivery: Sendable, Equatable {
        case countryWelcome(String)
        case welcomeHome(days: Int)
    }

    /// The defaults holding the alert toggles and the per-trip state.
    nonisolated static var stateDefaults: UserDefaults {
        stateDefaults(suiteName: stateSuiteName)
    }

    private nonisolated static var stateSuiteName: String? {
        #if DEBUG
        return TestScope.defaultsSuiteName
        #else
        return nil
        #endif
    }

    private nonisolated static func stateDefaults(suiteName: String?) -> UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    /// True when a Country Welcome trip claim is still recorded. The live
    /// ping path uses it to keep resetting the trip on a home-country ping
    /// while the alert is off, without resolving home countries otherwise.
    nonisolated static func hasCountryWelcomeDedupState(defaults: UserDefaults = .standard) -> Bool {
        !(defaults.stringArray(forKey: notifiedCountryCodesKey) ?? []).isEmpty
            || defaults.string(forKey: lastNotifiedCountryCodeKey) != nil
    }

    /// True while a Welcome Home departure is recorded. The live ping path
    /// uses it to end that trip at home while the alert is off.
    nonisolated static func hasWelcomeHomeDepartureState(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: wasAbroadKey)
    }

    /// Delete All Data: forgets the per-trip travel state (notified countries,
    /// departure). The alert toggles are preferences and stay.
    nonisolated static func clearTravelState(defaults: UserDefaults = .standard) {
        for key in [lastNotifiedCountryCodeKey, notifiedCountryCodesKey,
                    countryWelcomeTripEpochKey, wasAbroadKey, departureDateKey] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Authorization

    @discardableResult
    static func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            logger.info("Notification authorization \(granted ? "granted" : "denied").")
            return granted
        } catch {
            logger.error("Notification authorization failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Reconciles a grant made in iOS Settings with the app's default-on alert
    /// preferences. An absent key means the user has never made a choice; an
    /// existing false value is deliberate and must never be overwritten.
    nonisolated static func enableDefaultFeaturesIfAuthorized(
        _ authorizationStatus: UNAuthorizationStatus,
        defaults: UserDefaults = .standard
    ) {
        guard authorizationStatus == .authorized else { return }
        if defaults.object(forKey: countryWelcomeEnabledKey) == nil {
            defaults.set(true, forKey: countryWelcomeEnabledKey)
        }
        if defaults.object(forKey: welcomeHomeEnabledKey) == nil {
            defaults.set(true, forKey: welcomeHomeEnabledKey)
        }
    }

    // MARK: - Country Welcome

    /// Check if a country welcome notification should be sent.
    ///
    /// Fires when the user arrives in a country that is NOT any home's country.
    /// Dedup: only one notification per foreign country per trip. Resets when
    /// the user returns to a home country, even while the alert is off.
    static func checkCountryWelcome(
        isoCountryCode: String?,
        countryName: String?,
        homeCountryCodes: Set<String>
    ) {
        // The release below runs later, so it carries the suite, not the scope.
        let suiteName = stateSuiteName
        let defaults = stateDefaults(suiteName: suiteName)
        guard let countryCode = isoCountryCode else { return }
        guard !homeCountryCodes.isEmpty else { return }

        guard shouldDeliverCountryWelcome(
            countryCode,
            homeCountryCodes: homeCountryCodes,
            enabled: defaults.bool(forKey: countryWelcomeEnabledKey),
            defaults: defaults
        ) else { return }
        let tripEpoch = defaults.string(forKey: countryWelcomeTripEpochKey)

        #if DEBUG
        if let deliver = TestScope.deliver {
            deliver(.countryWelcome(countryCode))
            return
        }
        #endif

        let flag = flagEmoji(for: countryCode) ?? ""
        let displayName = localizedCountryName(
            iso: countryCode,
            fallback: countryName
        ) ?? countryCode

        let content = UNMutableNotificationContent()
        content.title = NSString.localizedUserNotificationString(
            forKey: "notification.country-welcome.title",
            arguments: [displayName, flag]
        )
        content.body = NSString.localizedUserNotificationString(
            forKey: "notification.country-welcome.body",
            arguments: [displayName]
        )
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "country-welcome-\(countryCode)",
            content: content,
            trigger: nil
        )

        // A failed `add` releases the claim:
        // authorization revoked at the system level or a transient scheduling
        // error must not consume this country until the user returns home.
        // Claiming before `add` stops two pings in one batch from both
        // scheduling; the release hops back to the main actor so the
        // read-modify-write never races a claim.
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to schedule country welcome: \(error.localizedDescription)")
                Task { @MainActor in
                    releaseCountryWelcome(
                        countryCode, tripEpoch: tripEpoch,
                        defaults: stateDefaults(suiteName: suiteName))
                }
                return
            }
            logger.info("Scheduled country welcome for \(displayName) (\(countryCode)).")
        }
    }

    /// The Country Welcome decision for one observed country. A home country
    /// ends the trip whether or not the alert is on, so a trip that ended
    /// while it was off cannot keep suppressing the next visit. While the
    /// alert is off a foreign country neither claims nor releases anything,
    /// so a trip that continues across an off and on keeps its dedup.
    nonisolated static func shouldDeliverCountryWelcome(
        _ countryCode: String,
        homeCountryCodes: Set<String>,
        enabled: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard enabled || homeCountryCodes.contains(countryCode) else { return false }
        return claimCountryWelcome(countryCode, homeCountryCodes: homeCountryCodes, defaults: defaults)
    }

    /// Applies the per-trip dedup rule. A home country clears the trip's
    /// notified set and returns false; a foreign country not yet notified this
    /// trip is recorded and returns true.
    nonisolated static func claimCountryWelcome(
        _ countryCode: String,
        homeCountryCodes: Set<String>,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if homeCountryCodes.contains(countryCode) {
            defaults.removeObject(forKey: notifiedCountryCodesKey)
            defaults.removeObject(forKey: lastNotifiedCountryCodeKey)
            defaults.removeObject(forKey: countryWelcomeTripEpochKey)
            return false
        }
        var notified = defaults.stringArray(forKey: notifiedCountryCodesKey) ?? []
        if let legacy = defaults.string(forKey: lastNotifiedCountryCodeKey),
           !notified.contains(legacy) {
            notified.append(legacy)
        }
        guard !notified.contains(countryCode) else { return false }
        notified.append(countryCode)
        defaults.set(notified, forKey: notifiedCountryCodesKey)
        if defaults.string(forKey: countryWelcomeTripEpochKey) == nil {
            defaults.set(UUID().uuidString, forKey: countryWelcomeTripEpochKey)
        }
        return true
    }

    /// Undoes a claim whose notification could not be scheduled, so the next
    /// ping in that country retries. A delayed failure from an ended trip
    /// cannot release the same country claimed by a newer trip.
    nonisolated static func releaseCountryWelcome(
        _ countryCode: String,
        tripEpoch: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let tripEpoch,
              defaults.string(forKey: countryWelcomeTripEpochKey) == tripEpoch else { return }
        var notified = defaults.stringArray(forKey: notifiedCountryCodesKey) ?? []
        notified.removeAll { $0 == countryCode }
        defaults.set(notified, forKey: notifiedCountryCodesKey)
        if defaults.string(forKey: lastNotifiedCountryCodeKey) == countryCode {
            defaults.removeObject(forKey: lastNotifiedCountryCodeKey)
        }
    }

    // MARK: - Welcome Home

    /// Days shown in the Welcome Home body: nil until a full day away, then
    /// the inclusive calendar-day span (Mon to Wed is 3), like `Trip.durationDays`.
    nonisolated static func welcomeHomeDisplayDays(departure: Date, now: Date, zone: TimeZone) -> Int? {
        var calendar = Calendar.current
        calendar.timeZone = zone
        guard (calendar.dateComponents([.day], from: departure, to: now).day ?? 0) >= 1 else { return nil }
        return Trip.inclusiveDays(from: departure, in: zone, to: now, in: zone)
    }

    /// Check if a welcome home notification should be sent.
    ///
    /// Fires when the user returns to any home's radius after being away
    /// for at least 1 day. Tracks abroad/home transitions via UserDefaults.
    static func checkWelcomeHome(isWithinHomeRadius: Bool) {
        let defaults = stateDefaults
        guard let days = welcomeHomeDaysToDeliver(
            isWithinHomeRadius: isWithinHomeRadius,
            enabled: defaults.bool(forKey: welcomeHomeEnabledKey),
            now: .now,
            zone: .current,
            defaults: defaults
        ) else { return }

        #if DEBUG
        if let deliver = TestScope.deliver {
            deliver(.welcomeHome(days: days))
            return
        }
        #endif

        let content = UNMutableNotificationContent()
        content.title = NSString.localizedUserNotificationString(
            forKey: "notification.welcome-home.title",
            arguments: []
        )
        let dayText = days.formatted(.number.grouping(.never))
        content.body = NSString.localizedUserNotificationString(
            forKey: "notification.welcome-home.body.other",
            arguments: [dayText]
        )
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "welcome-home-\(Int(Date.now.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Failed to schedule welcome home: \(error.localizedDescription)")
            } else {
                logger.info("Scheduled welcome home notification (\(days) days away).")
            }
        }
    }

    /// The Welcome Home transition for one observation, returning the days
    /// to announce when a notification is due. Coming home ends the trip
    /// whether or not the alert is on: both transition keys are cleared, so
    /// turning the alert back on at home cannot announce a stale trip.
    /// Departures are only recorded while the alert is on (the live path
    /// skips the home check entirely while it is off with no trip pending),
    /// and a departure already recorded is kept across an off and on.
    nonisolated static func welcomeHomeDaysToDeliver(
        isWithinHomeRadius: Bool,
        enabled: Bool,
        now: Date,
        zone: TimeZone,
        defaults: UserDefaults = .standard
    ) -> Int? {
        let wasAbroad = defaults.bool(forKey: wasAbroadKey)

        guard isWithinHomeRadius else {
            if enabled && !wasAbroad {
                defaults.set(true, forKey: wasAbroadKey)
                defaults.set(now.timeIntervalSince1970, forKey: departureDateKey)
            }
            return nil
        }

        guard wasAbroad else { return nil }
        let departureTimestamp = defaults.double(forKey: departureDateKey)
        defaults.set(false, forKey: wasAbroadKey)
        defaults.removeObject(forKey: departureDateKey)

        guard enabled, departureTimestamp > 0 else { return nil }
        // Inclusive calendar days, matching `Trip.durationDays`.
        return welcomeHomeDisplayDays(
            departure: Date(timeIntervalSince1970: departureTimestamp), now: now, zone: zone)
    }
}
