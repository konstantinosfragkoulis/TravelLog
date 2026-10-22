//
//  CalendarEnricher+CalendarSelection.swift
//  TravelLog
//

@preconcurrency import EventKit
import Foundation
import CryptoKit
import SwiftData
import CoreLocation
import WeatherKit
import WidgetKit
import os.log

extension CalendarEnricher {

    // MARK: - Calendar selection

    /// Identifiers of the calendars the user wants considered. Absent/empty
    /// = all calendars. Device-local preference — calendar identifiers aren't
    /// portable across reinstalls the way per-event external identifiers are.
    /// Still the authoritative ID set, so an older build keeps the same scope.
    nonisolated static let selectedCalendarIDsKey = "calendarSelectedCalendarIDs_v1"
    /// Each selected identifier's account and calendar title, so an
    /// identifier EventKit re-mints (account re-added, provider full resync,
    /// backup restore) re-resolves to its one live calendar. Device-local.
    nonisolated static let selectedCalendarsKey = "calendarSelectedCalendars_v2"
    /// Whether the last resolution found none of an explicit selection's
    /// calendars; drives the Settings Calendars row's secondary state.
    nonisolated static let selectionUnavailableKey = "calendarSelectionUnavailable_v1"

    /// One calendar the Settings multi-select can offer.
    nonisolated struct CalendarChoice: Sendable, Identifiable, Equatable {
        let id: String
        let title: String
        let accountTitle: String
    }

    /// One stored selection entry. The titles are nil for an identifier
    /// carried over from the v1 format and not yet seen live.
    nonisolated struct SelectedCalendar: Codable, Sendable, Equatable {
        var id: String
        var accountTitle: String?
        var title: String?
    }

    nonisolated enum StoredCalendarSelection: Sendable, Equatable {
        /// Nothing chosen: every calendar.
        case all
        /// The user's explicit choice. An unreadable choice stays explicit
        /// (and resolves to nothing) rather than widening to every calendar.
        case explicit([SelectedCalendar])
    }

    nonisolated enum CalendarSelectionScope: Sendable, Equatable {
        case all
        case calendars(Set<String>)
        /// An explicit selection none of whose calendars resolves on this
        /// device: read no calendar rather than every calendar.
        case noneAvailable
    }

    nonisolated static func storedSelection(in defaults: UserDefaults) -> StoredCalendarSelection {
        var entries: [SelectedCalendar]?
        var unreadable = false
        if let object = defaults.object(forKey: selectedCalendarsKey) {
            if let data = object as? Data,
               let decoded = try? JSONDecoder().decode([SelectedCalendar].self, from: data) {
                entries = decoded
            } else {
                unreadable = true
            }
        }
        if let ids = defaults.stringArray(forKey: selectedCalendarIDsKey) {
            guard !ids.isEmpty else { return .all }
            var seen = Set<String>()
            return .explicit(ids.filter { seen.insert($0).inserted }.map { id in
                entries?.first { $0.id == id } ?? SelectedCalendar(id: id)
            })
        }
        if unreadable { return .explicit([]) }
        guard let entries, !entries.isEmpty else { return .all }
        return .explicit(entries)
    }

    /// Writes both formats; an empty selection means all calendars.
    nonisolated static func saveSelection(_ entries: [SelectedCalendar], in defaults: UserDefaults) {
        guard !entries.isEmpty else {
            defaults.removeObject(forKey: selectedCalendarsKey)
            defaults.removeObject(forKey: selectedCalendarIDsKey)
            return
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: selectedCalendarsKey)
        }
        defaults.set(entries.map(\.id), forKey: selectedCalendarIDsKey)
    }

    nonisolated static func recordSelectionAvailability(_ scope: CalendarSelectionScope, in defaults: UserDefaults) {
        let unavailable = scope == .noneAvailable
        if defaults.bool(forKey: selectionUnavailableKey) != unavailable {
            defaults.set(unavailable, forKey: selectionUnavailableKey)
        }
    }

    /// Stored entries for a new ID set from the Settings list: live choices
    /// carry their current titles, stale IDs keep what was stored for them.
    nonisolated static func selectionEntries(
        for ids: Set<String>, choices: [CalendarChoice], previous: [SelectedCalendar]
    ) -> [SelectedCalendar] {
        ids.sorted().map { id in
            if let choice = choices.first(where: { $0.id == id }) {
                return SelectedCalendar(id: id, accountTitle: choice.accountTitle, title: choice.title)
            }
            return previous.first { $0.id == id } ?? SelectedCalendar(id: id)
        }
    }

    /// Pure resolution of a stored selection against the live calendars.
    /// A stored ID that is live keeps its calendar (and refreshes its
    /// titles). A stale one with titles re-resolves only to a calendar that
    /// is the single live one with that account and title and that no other
    /// entry holds; anything ambiguous stays stale. A stale entry is kept, so
    /// its calendar counts again when it returns. `healed` is non-nil when
    /// the stored entries should be rewritten.
    nonisolated static func resolveSelection(
        _ stored: StoredCalendarSelection, live: [CalendarChoice]
    ) -> (scope: CalendarSelectionScope, healed: [SelectedCalendar]?) {
        guard case .explicit(let entries) = stored else { return (.all, nil) }
        let liveByID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var claimed = Set(entries.map(\.id)).intersection(liveByID.keys)
        var resolved = Set<String>()
        var result: [SelectedCalendar] = []
        var changed = false
        for entry in entries {
            var entry = entry
            if let choice = liveByID[entry.id] {
                if entry.accountTitle != choice.accountTitle || entry.title != choice.title {
                    entry.accountTitle = choice.accountTitle
                    entry.title = choice.title
                    changed = true
                }
                resolved.insert(entry.id)
            } else if let accountTitle = entry.accountTitle, let title = entry.title {
                let matches = live.filter { $0.accountTitle == accountTitle && $0.title == title }
                if matches.count == 1, let match = matches.first, !claimed.contains(match.id) {
                    entry.id = match.id
                    claimed.insert(match.id)
                    resolved.insert(match.id)
                    changed = true
                }
            }
            if result.contains(where: { $0.id == entry.id }) {
                changed = true
            } else {
                result.append(entry)
            }
        }
        let scope: CalendarSelectionScope = resolved.isEmpty ? .noneAvailable : .calendars(resolved)
        return (scope, changed ? result : nil)
    }

    nonisolated private static func choice(for calendar: EKCalendar) -> CalendarChoice {
        CalendarChoice(id: calendar.calendarIdentifier, title: calendar.title,
                       accountTitle: calendar.source?.title ?? "")
    }

    /// Live event calendars and their choices (the DEBUG binding replaces
    /// EventKit, with no `EKCalendar` objects).
    private func liveCalendars() -> (calendars: [EKCalendar], choices: [CalendarChoice]) {
        #if DEBUG
        if let bound = TestScope.liveCalendars { return ([], bound) }
        #endif
        let calendars = eventStore.calendars(for: .event)
        return (calendars, calendars.map(Self.choice(for:)))
    }

    func calendarChoices() -> [CalendarChoice] {
        guard Self.hasReadAccess else { return [] }
        return liveCalendars().choices
            .sorted {
                if $0.accountTitle != $1.accountTitle { return $0.accountTitle < $1.accountTitle }
                return $0.title < $1.title
            }
    }

    /// What the Settings calendar list shows: the live choices and the stored
    /// selection after re-resolution (empty `entries` = all calendars, unless
    /// `scope` is `.noneAvailable`: an unreadable explicit selection).
    nonisolated struct CalendarSelectionSnapshot: Sendable, Equatable {
        let choices: [CalendarChoice]
        let entries: [SelectedCalendar]
        let scope: CalendarSelectionScope
    }

    func calendarSelectionSnapshot() -> CalendarSelectionSnapshot {
        let choices = calendarChoices()
        let scope = Self.hasReadAccess ? resolveCalendarScope().scope : .all
        let entries: [SelectedCalendar]
        if case .explicit(let stored) = Self.storedSelection(in: Self.defaults) {
            entries = stored
        } else {
            entries = []
        }
        return CalendarSelectionSnapshot(choices: choices, entries: entries, scope: scope)
    }

    /// Set by the restore-sentinel hookup in AppDelegate. A restore re-mints
    /// EventKit identifiers; it now resolves like any other launch (titles
    /// re-find re-minted calendars, and a selection with nothing left reads no
    /// calendar and shows the Settings notice), so the flag is only consumed.
    nonisolated static let selectionRevalidationPendingKey = "calendarSelectionRevalidationPending_v1"

    /// The user's selection resolved against live calendars, healing
    /// re-minted identifiers and recording the Settings availability flag.
    /// `calendars` is nil for all calendars. Callers gate on read access.
    func resolveCalendarScope() -> (scope: CalendarSelectionScope, calendars: [EKCalendar]?) {
        let defaults = Self.defaults
        if defaults.object(forKey: Self.selectionRevalidationPendingKey) != nil {
            defaults.removeObject(forKey: Self.selectionRevalidationPendingKey)
        }
        let stored = Self.storedSelection(in: defaults)
        guard case .explicit = stored else {
            Self.recordSelectionAvailability(.all, in: defaults)
            return (.all, nil)
        }
        let live = liveCalendars()
        let resolution = Self.resolveSelection(stored, live: live.choices)
        // Skip the rewrite if Settings changed the selection meanwhile.
        if let healed = resolution.healed, Self.storedSelection(in: defaults) == stored {
            Self.saveSelection(healed, in: defaults)
        }
        Self.recordSelectionAvailability(resolution.scope, in: defaults)
        switch resolution.scope {
        case .all:
            return (.all, nil)
        case .noneAvailable:
            return (.noneAvailable, nil)
        case .calendars(let ids):
            return (resolution.scope, live.calendars.filter { ids.contains($0.calendarIdentifier) })
        }
    }

    // MARK: - Thin-history probe

    nonisolated static let thinHistoryProbeCompletedKey = "calendarThinHistoryProbe_v1"
    /// Set to the sync-capped account's title when the probe detects thin
    /// history; drives the one-time Settings tip.
    nonisolated static let thinHistoryAccountKey = "calendarThinHistoryAccount"
    nonisolated static let thinHistoryTipDismissedKey = "calendarThinHistoryTipDismissed"

    /// Forgets the probe's latch, the account name it copied, and the tip's
    /// dismissal, so the next probe starts fresh, and the scan's ledger of
    /// observed event sources. Delete Calendar Data and Delete All Data both
    /// use it; the calendar selection is not touched.
    nonisolated static func clearThinHistoryProbeState(in defaults: UserDefaults) {
        defaults.removeObject(forKey: thinHistoryProbeCompletedKey)
        defaults.removeObject(forKey: thinHistoryAccountKey)
        defaults.removeObject(forKey: thinHistoryTipDismissedKey)
        defaults.removeObject(forKey: observedEventSourcesKey)
    }

    // MARK: - Scanned calendars

    /// The calendars a scan over `scope` reads: the resolved selection, or
    /// every live calendar. The stale sweep may retire only a row whose event
    /// this device saw in one of them.
    func scannedCalendarIDs(for scope: CalendarSelectionScope) -> Set<String> {
        switch scope {
        case .calendars(let ids): return ids
        case .all: return Set(liveCalendars().choices.map(\.id))
        case .noneAvailable: return []
        }
    }

    /// The shape of a default Exchange/Google "1 month back" sync window.
    static let thinHistoryRecentWindowSeconds: TimeInterval = 45 * 24 * 60 * 60
    private static let thinHistoryLookbackSeconds: TimeInterval = 5 * 365 * 24 * 60 * 60

    /// True when the locally-synced history is suspiciously shallow —
    /// pure decision, unit-tested.
    ///
    /// A nil `earliestEvent` means the ~5-year lookback found NOTHING, which
    /// is not evidence of a truncated sync window — it is what an empty
    /// calendar looks like, and a sync setting would change nothing.
    /// "Thin" requires events to exist AND the oldest one to be recent.
    nonisolated static func isThinHistory(earliestEvent: Date?, now: Date) -> Bool {
        guard let earliestEvent else { return false }
        return now.timeIntervalSince(earliestEvent) < thinHistoryRecentWindowSeconds
    }

    /// A calendar account the thin-history probe may name.
    nonisolated struct ThinHistorySource: Hashable, Sendable {
        let id: String
        let title: String
    }

    /// The sync-capped accounts among `calendars` (the ones a scan reads),
    /// each with only its own calendars, in title order.
    nonisolated static func syncCappedGroups<C>(
        _ calendars: [C], source: (C) -> ThinHistorySource?
    ) -> [(source: ThinHistorySource, calendars: [C])] {
        var groups: [ThinHistorySource: [C]] = [:]
        for calendar in calendars {
            guard let account = source(calendar) else { continue }
            groups[account, default: []].append(calendar)
        }
        return groups
            .map { (source: $0.key, calendars: $0.value) }
            .sorted { ($0.source.title, $0.source.id) < ($1.source.title, $1.source.id) }
    }

    /// The first account whose own calendars hold only recent history, or
    /// nil. Each account is judged by its own earliest event: a selected
    /// local calendar's history says nothing about an Exchange account, and
    /// an account with no selected calendar is never named.
    nonisolated static func thinHistoryAccount<C>(
        _ groups: [(source: ThinHistorySource, calendars: [C])],
        now: Date, earliestEvent: ([C]) -> Date?
    ) -> String? {
        groups.first { isThinHistory(earliestEvent: earliestEvent($0.calendars), now: now) }?.source.title
    }

    /// The account iOS may sync-cap (Exchange and non-iCloud CalDAV; iCloud
    /// always syncs in full), as the probe names it.
    nonisolated private static func syncCappedSource(of calendar: EKCalendar) -> ThinHistorySource? {
        guard let source = calendar.source else { return nil }
        switch source.sourceType {
        case .exchange: break
        case .calDAV where source.title != "iCloud": break
        default: return nil
        }
        return ThinHistorySource(id: source.sourceIdentifier, title: source.title)
    }

    /// One-time (UserDefaults-gated, like `offlineGeocoderBackfill`): for
    /// each sync-capped account among the calendars scans read (non-iCloud,
    /// non-local: the only kind iOS sync-caps — iCloud always syncs in
    /// full), find the earliest past event in that account's own calendars
    /// over a ~5-year lookback (chunked ≤4 years, oldest first, stops at the
    /// first non-empty chunk). If it's suspiciously recent, record that
    /// account's name for the Settings tip. Recent history suggests, not
    /// proves, a sync limit, so the tip says it may be one. Past-lane
    /// evidence for older trips is impossible until the user flips that
    /// account's sync setting to "All Events" — a user-fixable condition,
    /// not an app bug.
    func runThinHistoryProbeIfNeeded(now: Date = .now) {
        guard Self.hasReadAccess else { return }
        let defaults = Self.defaults
        guard !defaults.bool(forKey: Self.thinHistoryProbeCompletedKey) else { return }

        // Respect the user's calendar selection: probing ALL calendars
        // would both break the Settings sheet's "only checked calendars
        // are read" promise and could mask a real warning (a deep-history
        // EXCLUDED calendar hides the selected account's shallow window) or
        // warn about an account the user deliberately excluded. A selection
        // with no available calendar has nothing to say yet: no enumeration
        // and no latch, so the probe runs once the selection resolves again.
        let selection = resolveCalendarScope()
        guard selection.scope != .noneAvailable else { return }

        let groups = Self.syncCappedGroups(
            selection.calendars ?? eventStore.calendars(for: .event), source: Self.syncCappedSource(of:))
        // No sync-capped account read: nothing this probe can say. Latch here
        // so we don't re-enumerate on every launch.
        guard !groups.isEmpty else {
            defaults.set(true, forKey: Self.thinHistoryProbeCompletedKey)
            return
        }

        let account = Self.thinHistoryAccount(groups, now: now) { calendars in
            var earliest: Date?
            var chunkStart = now.addingTimeInterval(-Self.thinHistoryLookbackSeconds)
            while chunkStart < now, earliest == nil {
                let chunkEnd = min(chunkStart.addingTimeInterval(Self.maxQuerySpanSeconds), now)
                let predicate = eventStore.predicateForEvents(withStart: chunkStart, end: chunkEnd, calendars: calendars)
                earliest = eventStore.events(matching: predicate)
                    .compactMap { $0.startDate }
                    .min()
                chunkStart = chunkEnd
            }
            return earliest
        }
        if let account {
            defaults.set(account, forKey: Self.thinHistoryAccountKey)
            logger.info("Thin calendar history detected; Settings tip armed.")
        }

        // Latch only once the scan AND the decision are done: set up front, an
        // app kill during the multi-year enumeration would disable the tip for
        // good, with no way to re-arm short of Delete Calendar Data. (App kill
        // is the only such interruption: this function is synchronous on the
        // actor and calls nothing that throws.) The guard above makes a repeat
        // pass free.
        defaults.set(true, forKey: Self.thinHistoryProbeCompletedKey)
    }
}
