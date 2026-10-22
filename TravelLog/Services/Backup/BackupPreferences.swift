//
//  BackupPreferences.swift
//  TravelLog
//
//  The device-local preferences a backup carries: the ones that change what
//  the user sees. Device settings and consent (iCloud sync, calendar
//  selection, notification toggles) and one-device tips stay out.
//

import Foundation

nonisolated struct BackupPreferences: Codable, Sendable, Equatable {
    /// Trip list sort (`TripSortOrder` raw value).
    var tripsSortOrder: String? = nil
    /// The saved trip filters blob (`TripFilters`).
    var tripFilters: String? = nil
    /// The temperature unit (iCloud key-value data).
    var temperatureUnit: String? = nil
    var splitHintDismissed: Bool? = nil
    var splitHintSeenTripIDs: String? = nil
    /// "Not Now" answers to temporary-home suggestions, newest last.
    var temporaryHomeSuggestionDismissals: [String] = []
    /// "Not Yet" answers to temporary-home end hints, newest last.
    var temporaryHomeEndHintDismissals: [String] = []
    /// Flight candidates the user dismissed, oldest first.
    var dismissedFlightCandidates: [String] = []
    /// Trip gaps confirmed as one trip (`TripGapAnswers`), oldest first.
    /// Optional so a file written before it existed still decodes.
    var tripGapConfirmations: [String]? = nil
    /// Flight times the user set (`FlightTimeOverrides`), newest last.
    /// Optional so a file written before it existed still decodes.
    var flightTimeOverrides: [String]? = nil
    /// Flight stops the user set (`FlightStops`), newest last.
    /// Optional so a file written before it existed still decodes.
    var flightStops: [String]? = nil

    nonisolated static let tripsSortOrderKey = "tripsSortOrder"
    nonisolated static let temperatureUnitKey = "temperatureUnit"
    /// The two dismissal lists' own bound (`TemporaryHomeSuggestion`,
    /// `TemporaryHomeCards`).
    private nonisolated static let dismissalLimit = 200

    /// The preferences as they are on this device. `ubiquitous` stands in
    /// for iCloud key-value storage in tests.
    @MainActor
    static func current(
        defaults: UserDefaults = .standard, ubiquitous: UserDefaults? = nil
    ) -> BackupPreferences {
        BackupPreferences(
            tripsSortOrder: defaults.string(forKey: tripsSortOrderKey),
            tripFilters: defaults.string(forKey: TripFilters.storeKey),
            temperatureUnit: ubiquitous.map { $0.string(forKey: temperatureUnitKey) }
                ?? NSUbiquitousKeyValueStore.default.string(forKey: temperatureUnitKey),
            splitHintDismissed: defaults.object(forKey: TripSplitHint.dismissedKey) as? Bool,
            splitHintSeenTripIDs: defaults.string(forKey: TripSplitHint.seenTripIDsKey),
            temporaryHomeSuggestionDismissals:
                defaults.stringArray(forKey: TemporaryHomeSuggestion.dismissalsKey) ?? [],
            temporaryHomeEndHintDismissals:
                defaults.stringArray(forKey: TemporaryHomeCards.endHintDismissalsKey) ?? [],
            dismissedFlightCandidates:
                defaults.stringArray(forKey: FlightCandidateDismissals.defaultsKey) ?? [],
            tripGapConfirmations: defaults.stringArray(forKey: TripGapAnswers.confirmedKey),
            flightTimeOverrides: defaults.stringArray(forKey: FlightTimeOverrides.defaultsKey),
            flightStops: defaults.stringArray(forKey: FlightStops.defaultsKey))
    }

    /// Adds a committed restore's preferences without overriding a choice
    /// made on this device: a setting lands only where this device has none,
    /// and a dismissal list gains the file's answers it lacks, kept within
    /// its bound. Returns how many settings and answers were added. It reads
    /// the storage as it is now, never a preview's count.
    @MainActor
    @discardableResult
    static func restore(
        _ preferences: BackupPreferences,
        defaults: UserDefaults = .standard, ubiquitous: UserDefaults? = nil
    ) -> Int {
        merge(preferences, defaults: defaults, ubiquitous: ubiquitous, apply: true)
    }

    /// How many settings and answers `restore` would add now, without
    /// writing anything: the import preview admits a file whose only new
    /// content is these. Answers a list's bound would drop at once count
    /// for nothing.
    @MainActor
    static func additions(
        _ preferences: BackupPreferences,
        defaults: UserDefaults = .standard, ubiquitous: UserDefaults? = nil
    ) -> Int {
        merge(preferences, defaults: defaults, ubiquitous: ubiquitous, apply: false)
    }

    /// `restore`'s rule, writing only with `apply`.
    @MainActor
    private static func merge(
        _ preferences: BackupPreferences,
        defaults: UserDefaults, ubiquitous: UserDefaults?, apply: Bool
    ) -> Int {
        var added = 0
        func setIfAbsent(_ value: String?, forKey key: String) {
            guard let value, defaults.object(forKey: key) == nil else { return }
            if apply { defaults.set(value, forKey: key) }
            added += 1
        }
        setIfAbsent(preferences.tripsSortOrder, forKey: tripsSortOrderKey)
        setIfAbsent(preferences.tripFilters, forKey: TripFilters.storeKey)
        setIfAbsent(preferences.splitHintSeenTripIDs, forKey: TripSplitHint.seenTripIDsKey)
        if let dismissed = preferences.splitHintDismissed,
           defaults.object(forKey: TripSplitHint.dismissedKey) == nil {
            if apply { defaults.set(dismissed, forKey: TripSplitHint.dismissedKey) }
            added += 1
        }
        if let unit = preferences.temperatureUnit {
            if let ubiquitous {
                if ubiquitous.string(forKey: temperatureUnitKey) == nil {
                    if apply { ubiquitous.set(unit, forKey: temperatureUnitKey) }
                    added += 1
                }
            } else if NSUbiquitousKeyValueStore.default.string(forKey: temperatureUnitKey) == nil {
                if apply { NSUbiquitousKeyValueStore.default.set(unit, forKey: temperatureUnitKey) }
                added += 1
            }
        }
        func union(_ entries: [String], forKey key: String, limit: Int?) {
            let held = defaults.stringArray(forKey: key) ?? []
            let heldSet = Set(held)
            var seen = Set<String>()
            let missing = entries.filter { !heldSet.contains($0) && seen.insert($0).inserted }
            guard !missing.isEmpty else { return }
            // The file's answers are older than this device's: they go first,
            // so a bound drops them before anything answered here.
            var merged = missing + held
            if let limit { merged = Array(merged.suffix(limit)) }
            // Only the file's answers the bound keeps count; when it keeps
            // none, the list is left as it is.
            let kept = merged.count - held.count
            guard kept > 0 else { return }
            if apply { defaults.set(merged, forKey: key) }
            added += kept
        }
        union(preferences.temporaryHomeSuggestionDismissals,
              forKey: TemporaryHomeSuggestion.dismissalsKey, limit: dismissalLimit)
        union(preferences.temporaryHomeEndHintDismissals,
              forKey: TemporaryHomeCards.endHintDismissalsKey, limit: dismissalLimit)
        union(preferences.dismissedFlightCandidates,
              forKey: FlightCandidateDismissals.defaultsKey, limit: nil)
        union(preferences.tripGapConfirmations ?? [],
              forKey: TripGapAnswers.confirmedKey, limit: nil)
        // The file's entries go first, so a time or stops set on this
        // device for the same flight stay the later one, which wins.
        union(preferences.flightTimeOverrides ?? [],
              forKey: FlightTimeOverrides.defaultsKey, limit: nil)
        union(preferences.flightStops ?? [],
              forKey: FlightStops.defaultsKey, limit: nil)
        return added
    }
}

extension BackupPreferences {
    /// A setting blob's bound (the filters and seen-trip lists are the
    /// largest), and an answer's, and how many answers a list keeps.
    private nonisolated static let maxSettingBytes = 1 << 20
    private nonisolated static let maxAnswerBytes = 1_024
    private nonisolated static let maxAnswers = 10_000

    /// Each preference decodes on its own: one of the wrong type or past its
    /// bound is left out, not the rest. A list keeps its newest answers.
    /// Values are not checked against what their readers know: every reader
    /// falls back on one it does not.
    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            guard let value = try? container.decodeIfPresent(String.self, forKey: key),
                  value.utf8.count <= Self.maxSettingBytes else { return nil }
            return value
        }
        func flag(_ key: CodingKeys) -> Bool? {
            (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? nil
        }
        func answers(_ key: CodingKeys) -> [String]? {
            guard let entries = try? container.decodeIfPresent([BackupLossy<String>].self, forKey: key) else {
                return nil
            }
            let kept = entries.compactMap(\.value).filter { $0.utf8.count <= Self.maxAnswerBytes }
            return Array(kept.suffix(Self.maxAnswers))
        }
        self.init(
            tripsSortOrder: text(.tripsSortOrder),
            tripFilters: text(.tripFilters),
            temperatureUnit: text(.temperatureUnit),
            splitHintDismissed: flag(.splitHintDismissed),
            splitHintSeenTripIDs: text(.splitHintSeenTripIDs),
            temporaryHomeSuggestionDismissals: answers(.temporaryHomeSuggestionDismissals) ?? [],
            temporaryHomeEndHintDismissals: answers(.temporaryHomeEndHintDismissals) ?? [],
            dismissedFlightCandidates: answers(.dismissedFlightCandidates) ?? [],
            tripGapConfirmations: answers(.tripGapConfirmations),
            flightTimeOverrides: answers(.flightTimeOverrides),
            flightStops: answers(.flightStops))
    }
}
