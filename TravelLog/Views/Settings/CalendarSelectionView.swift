//
//  CalendarSelectionView.swift
//  TravelLog
//

import SwiftUI

/// Settings multi-select over the user's calendars:
/// not every calendar is travel-relevant (Holidays, a
/// shared school calendar, work deadlines). Selection is a device-local
/// `UserDefaults` preference — **empty means all calendars** — consumed by
/// `CalendarEnricher.eventsOverlapping`, so every lane (upcoming-trip scan,
/// trip naming, flight corroboration) respects it. An explicit selection
/// none of whose calendars is available reads no calendar, and this list
/// says so.
struct CalendarSelectionView: View {

    @State private var choices: [CalendarEnricher.CalendarChoice] = []
    /// nil reads every calendar. A set, even an empty one (an unreadable
    /// stored choice), is the user's explicit choice.
    @State private var selection: Set<String>? = nil
    @State private var storedEntries: [CalendarEnricher.SelectedCalendar] = []
    @State private var loaded = false

    enum SelectionState: Equatable {
        /// Nothing chosen: every calendar is read.
        case all
        /// At least one chosen calendar is available.
        case some
        /// Calendars were chosen but none of them is available: none is read.
        case noneAvailable
    }

    /// Mirrors `CalendarEnricher.resolveSelection` over what this list shows.
    static func selectionState(selected: Set<String>, live: Set<String>) -> SelectionState {
        selectionState(selection: selected.isEmpty ? nil : selected, live: live)
    }

    static func selectionState(selection: Set<String>?, live: Set<String>) -> SelectionState {
        guard let selection else { return .all }
        return selection.isDisjoint(with: live) ? .noneAvailable : .some
    }

    /// The list's selection from a snapshot. Empty entries mean every
    /// calendar, except when the stored choice resolved to nothing: an
    /// unreadable explicit selection stays explicit and empty, never all.
    static func initialSelection(from snapshot: CalendarEnricher.CalendarSelectionSnapshot) -> Set<String>? {
        let ids = Set(snapshot.entries.map(\.id))
        return ids.isEmpty && snapshot.scope != .noneAvailable ? nil : ids
    }

    private var selectionState: SelectionState {
        Self.selectionState(selection: selection, live: Set(choices.map(\.id)))
    }

    var body: some View {
        List {
            if loaded && selectionState == .noneAvailable {
                Section {
                    Label {
                        Text(Self.unavailableNotice)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(AppTheme.attention)
                    }
                    .font(.subheadline)
                }
            }
            Section {
                if loaded && choices.isEmpty {
                    Text("No calendars found.")
                        .foregroundStyle(.secondary)
                }
                ForEach(choices) { choice in
                    Button {
                        toggle(choice.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.title)
                                    .foregroundStyle(.primary)
                                if !choice.accountTitle.isEmpty {
                                    Text(choice.accountTitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if Self.isIncluded(choice.id, in: selection) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } footer: {
                // With nothing available no checkmark shows, so the "at least
                // one stays checked" rule would read false; the notice above
                // explains that state instead.
                if !(loaded && selectionState == .noneAvailable) {
                    Text("Travel Log only looks for trips in the checked calendars, and at least one always stays checked. Birthday calendars are always ignored.")
                }
            }
        }
        .navigationTitle("Calendars")
        .task {
            // Resolution first: a re-minted identifier is re-found by its
            // account and title before the checkmarks are drawn.
            let snapshot = await AppDelegate.calendarEnricher.calendarSelectionSnapshot()
            choices = snapshot.choices
            storedEntries = snapshot.entries
            selection = Self.initialSelection(from: snapshot)
            loaded = true
        }
        .onDisappear {
            // Re-scan with the new selection; rows from now-excluded
            // calendars age out via the normal staleness sweep.
            Task.detached(priority: .background) {
                await AppDelegate.calendarEnricher.scanUpcomingTrips()
            }
        }
    }

    static var unavailableNotice: String {
        String(
            localized: "settings.calendar-selection.unavailable-notice",
            defaultValue: "None of the calendars you checked are available, so Travel Log isn't reading any calendar. Check the calendars to use.",
            comment: "Calendar selection notice when every calendar the user checked has disappeared from this device (account removed or calendar deleted)."
        )
    }

    /// No selection = all calendars included.
    static func isIncluded(_ id: String, in selection: Set<String>?) -> Bool {
        selection?.contains(id) ?? true
    }

    /// Empty `selected` = all calendars; the result uses the same encoding.
    static func toggled(_ selected: Set<String>, live: Set<String>, id: String) -> Set<String> {
        toggled(selection: selected.isEmpty ? nil : selected, live: live, id: id)
    }

    /// Toggles `id` in `selection` (nil = all). An explicit empty selection
    /// only gains the tapped calendar. The result is stored form: empty
    /// means all calendars.
    static func toggled(selection: Set<String>?, live: Set<String>, id: String) -> Set<String> {
        var selected: Set<String>
        if let selection {
            selected = selection
            if selected.contains(id) {
                // Unchecking the LAST calendar would leave the empty set — the
                // "all calendars" sentinel — so every checkmark would silently
                // reappear. Keep at least one checked;
                // the footer documents the rule.
                // Count only calendars that still resolve: stale IDs (deleted
                // calendar, removed account) must not let the last live one be
                // unchecked, which the engine reads as "all calendars".
                if selected.intersection(live).count > 1 { selected.remove(id) }
            } else {
                selected.insert(id)
            }
        } else {
            // "All" → unchecking one: materialize the full set minus it.
            selected = live
            selected.remove(id)
        }
        // Everything re-checked collapses back to the "all" sentinel, so
        // calendars added later are included by default again, whatever
        // stale IDs are also stored.
        if !live.isEmpty && live.isSubset(of: selected) { return [] }
        return selected
    }

    private func toggle(_ id: String) {
        let next = Self.toggled(selection: selection, live: Set(choices.map(\.id)), id: id)
        selection = next.isEmpty ? nil : next
        storedEntries = Self.save(next, choices: choices, previous: storedEntries, in: CalendarEnricher.defaults)
    }

    /// Persists a toggled selection (empty = all calendars) with its entries
    /// and availability flag, returning the stored entries.
    static func save(
        _ ids: Set<String>, choices: [CalendarEnricher.CalendarChoice],
        previous: [CalendarEnricher.SelectedCalendar], in defaults: UserDefaults
    ) -> [CalendarEnricher.SelectedCalendar] {
        let entries = CalendarEnricher.selectionEntries(for: ids, choices: choices, previous: previous)
        CalendarEnricher.saveSelection(entries, in: defaults)
        CalendarEnricher.recordSelectionAvailability(
            CalendarEnricher.resolveSelection(entries.isEmpty ? .all : .explicit(entries), live: choices).scope,
            in: defaults)
        return entries
    }
}
