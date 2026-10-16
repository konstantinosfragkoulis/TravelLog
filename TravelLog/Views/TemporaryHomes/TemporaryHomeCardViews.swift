//
//  TemporaryHomeCardViews.swift
//  TravelLog
//
//  The temporary home card in the trips list, its detail page, and the
//  prefill "Set Up a Temporary Home…" opens the form with.
//

import Combine
import SwiftUI
import UIKit
import SwiftData
import CoreLocation
import os.log

private let temporaryHomeCardLogger = Logger(
    subsystem: "com.travellog.app", category: "TemporaryHomeCardViews")

// MARK: - Card row

/// One temporary home in the trips list. Pure display over the card value;
/// the end hint's End opens the form's end mode and Extend its extend mode,
/// both through `presentForm`, and Not Yet writes through
/// `TemporaryHomeCards.dismissEndHint`.
struct TemporaryHomeCardRow: View {

    let card: TemporaryHomeCards.Card
    /// Presents the form from the list's own sheet: a reload can move this
    /// row to another section, which would drop a sheet the row owned and
    /// the draft in it.
    let presentForm: (TemporaryHomeFormSheet.Mode) -> Void

    /// The end hint answered Not Yet here, hidden before the list reloads.
    @State private var notYetBackHomeSince: Date?
    /// Where its owed reconciliation stands; nil when nothing is owed.
    @State private var status: CoverageReconciliationQueue.TemporaryHomeStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.title)
                    .font(.headline)

                Spacer()

                if let flag = card.countryCode.flatMap({ flagEmoji(for: $0) }) {
                    Text(flag)
                        .font(.title3)
                }
            }

            if card.state == .active {
                TemporaryHomeNowLine(card: card)
            } else {
                Text(TemporaryHomesSettingsSection.dateLine(
                    startedAt: card.startedAt, endedAt: card.endedAt,
                    timeZoneIdentifier: card.timeZoneIdentifier, now: .now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let parts = Self.detailParts(awayDays: card.awayDays, tripCount: card.tripIDs.count)
            if !parts.isEmpty {
                Text(parts.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let suggestedEnd = card.suggestedEnd, let backHomeSince = card.backHomeSince,
               !card.endHintDismissed, notYetBackHomeSince != backHomeSince {
                endHintRow(suggestedEnd: suggestedEnd, backHomeSince: backHomeSince)
            }

            if card.extendSuggested {
                extendHintRow
            }

            if let status {
                TemporaryHomeUpdatingLine(status: status) { retry() }
            }
        }
        .padding(.vertical, 4)
        // The queue is device-local: read it again whenever the list reloads,
        // and when a drain records a failure or a deferral, which writes nothing else.
        .task(id: StoreChangeTracker.shared.token(for: [.temporaryHome, .stay, .trip])) {
            readStatus()
        }
        .onReceive(TemporaryHomesSettingsSection.queueStatusChanges) { _ in
            readStatus()
        }
    }

    private func readStatus() {
        let read = CoverageReconciliationQueue.temporaryHomeStatus(id: card.id)
        if read != status { status = read }
    }

    /// Try Again: updating at once, then whatever the drain left.
    private func retry() {
        status = .updating
        let id = card.id
        Task {
            await CoverageReconciliationQueue.retryTemporaryHome(id: id)
            readStatus()
        }
    }

    /// The edit form with the end turned off, for Extend.
    nonisolated static func extendMode(for card: TemporaryHomeCards.Card) -> TemporaryHomeFormSheet.Mode {
        .extend(id: card.id)
    }

    /// The form's end mode, preset to the suggested day when there is one.
    nonisolated static func endMode(for card: TemporaryHomeCards.Card) -> TemporaryHomeFormSheet.Mode {
        .end(id: card.id, suggested: card.suggestedEnd)
    }

    /// The hint, then Not Yet and End at the trailing edge.
    private func endHintRow(suggestedEnd: Date, backHomeSince: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.endHintText(
                backHomeSince: backHomeSince, backHomeTimeZoneIdentifier: card.backHomeTimeZoneIdentifier,
                suggestedEnd: suggestedEnd, timeZoneIdentifier: card.timeZoneIdentifier))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Spacer()

                hintButton(String(
                    localized: "temporary-home.card.end-hint.not-yet",
                    defaultValue: "Not Yet",
                    comment: "Button on a temporary home card that hides the suggestion to end it, until the user is back home again another time."
                ), bold: false) {
                    notYetBackHomeSince = backHomeSince
                    TemporaryHomeCards.dismissEndHint(id: card.id, backHomeSince: backHomeSince)
                }

                hintButton(String(
                    localized: "temporary-home.card.end-hint.action",
                    defaultValue: "End",
                    comment: "Button on a temporary home card that opens a form to end the temporary home, preset to the suggested date."
                ), bold: true) {
                    presentForm(Self.endMode(for: card))
                }
            }
        }
    }

    /// "Still in Brussels?", then Extend, which opens the edit form.
    private var extendHintRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Self.extendHintText(locality: card.locality))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            hintButton(String(
                localized: "temporary-home.card.extend-hint.action",
                defaultValue: "Extend",
                comment: "Button on the card of a temporary home that ended lately, while the user still seems to be there, that opens its form to move or remove the end date."
            ), bold: true) {
                presentForm(Self.extendMode(for: card))
            }
        }
    }

    /// Borderless, so the row's link does not swallow the tap. The frame
    /// sits inside the label: it is the hit area, and the word keeps its
    /// place at the trailing edge.
    private func hintButton(_ title: String, bold: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(bold ? .caption.bold() : .caption)
                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    /// "Still in Brussels?", or the same question about the temporary home
    /// when its city is unknown.
    nonisolated static func extendHintText(locality: String?) -> String {
        guard let locality, !locality.isEmpty else {
            return String(
                localized: "temporary-home.card.extend-hint.no-place",
                defaultValue: "Still at this temporary home?",
                comment: "Question on the card of a temporary home that ended lately while the user still seems to be there, when its city is unknown. An Extend button follows it."
            )
        }
        return String(
            localized: "temporary-home.card.extend-hint",
            defaultValue: "Still in \(locality)?",
            comment: "Question on the card of a temporary home that ended lately while the user still seems to be there; the placeholder is its city. An Extend button follows it."
        )
    }

    /// "12 days away from home" and "3 trips"; a zero part is left out.
    nonisolated static func detailParts(awayDays: Int, tripCount: Int) -> [String] {
        var parts: [String] = []
        if awayDays > 0 {
            parts.append(awayDays == 1
                ? String(
                    localized: "temporary-home.card.days-away.one",
                    defaultValue: "\(awayDays, format: .number.grouping(.never)) day away from home",
                    comment: "Temporary home card detail: one day the user spent away from their real, permanent home during this temporary home (time at the temporary home and trips taken from it both count).")
                : String(
                    localized: "temporary-home.card.days-away.other",
                    defaultValue: "\(awayDays, format: .number.grouping(.never)) days away from home",
                    comment: "Temporary home card detail: multiple days the user spent away from their real, permanent home during this temporary home (time at the temporary home and trips taken from it both count)."))
        }
        if tripCount > 0 {
            parts.append(tripCount == 1
                ? String(
                    localized: "temporary-home.card.trips.one",
                    defaultValue: "\(tripCount, format: .number.grouping(.never)) trip",
                    comment: "Temporary home card detail: one trip taken from this temporary home.")
                : String(
                    localized: "temporary-home.card.trips.other",
                    defaultValue: "\(tripCount, format: .number.grouping(.never)) trips",
                    comment: "Temporary home card detail: multiple trips taken from this temporary home."))
        }
        return parts
    }

    /// "Back home since 11 Feb. End it on 10 Feb?": the return read in the
    /// zone of the real-home stay it began with, the end in the temporary
    /// home's own zone, the zone the worker ends it in.
    nonisolated static func endHintText(
        backHomeSince: Date, backHomeTimeZoneIdentifier: String?,
        suggestedEnd: Date, timeZoneIdentifier: String?,
        locale: Locale = AppLanguagePreference.currentLocale()
    ) -> String {
        func day(_ date: Date, in zone: String?) -> String {
            date.formatted(Date.FormatStyle(
                locale: locale, timeZone: StayTimeZone.resolve(zone)).day().month(.abbreviated))
        }
        let back = day(backHomeSince, in: backHomeTimeZoneIdentifier)
        let end = day(suggestedEnd, in: timeZoneIdentifier)
        return String(
            localized: "temporary-home.card.end-hint",
            defaultValue: "Back home since \(back). End it on \(end)?",
            comment: "Hint on the card of an open-ended temporary home the user seems to have left: the day they got back home, then the day of their last stay at the temporary home, offered as its end date."
        )
    }
}

/// Where a temporary home's owed reconciliation stands, while its change is
/// saved and the trips it changes are not yet: "Updating trips…" with a
/// spinner, "Changes saved. Trips will update automatically." or
/// "Couldn't update trips." with Try Again (`retry`).
struct TemporaryHomeUpdatingLine: View {

    let status: CoverageReconciliationQueue.TemporaryHomeStatus
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if status == .updating {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(Self.text(for: status))
                .font(.caption)
                .foregroundStyle(.secondary)
            if Self.offersRetry(status) {
                Spacer()
                // Borderless, so a list row's link does not swallow the tap.
                Button(action: retry) {
                    Text(Self.retryTitle)
                        .font(.caption.bold())
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
    }

    nonisolated static func text(for status: CoverageReconciliationQueue.TemporaryHomeStatus) -> String {
        switch status {
        case .updating:
            String(
                localized: "temporary-home.updating-trips",
                defaultValue: "Updating trips…",
                comment: "Shown on a temporary home's card and detail page after a change to it is saved, while the app is still updating the trips the change affects.")
        case .waiting:
            String(
                localized: "temporary-home.updating-trips.waiting",
                defaultValue: "Changes saved. Trips will update automatically.",
                comment: "Shown on a temporary home's card and detail page after a change to it is saved, when updating the trips it affects was put off for now; the app tries again by itself, so the user need do nothing.")
        case .failed:
            String(
                localized: "temporary-home.updating-trips.failed",
                defaultValue: "Couldn't update trips.",
                comment: "Shown on a temporary home's card and detail page when updating the trips a saved change to it affects failed. A Try Again button follows it.")
        }
    }

    /// Only after a failure: a deferral retries by itself.
    nonisolated static func offersRetry(_ status: CoverageReconciliationQueue.TemporaryHomeStatus) -> Bool {
        status == .failed
    }

    nonisolated static var retryTitle: String {
        String(
            localized: "temporary-home.updating-trips.retry",
            defaultValue: "Try Again",
            comment: "Button beside \"Couldn't update trips.\" on a temporary home's card and detail page: updates the trips its saved change affects again.")
    }
}

/// The green "Active" and "Day N" of an active temporary home, as `ActiveTripRow`
/// shows "Now": its dates are current, which says nothing of where the user is.
private struct TemporaryHomeNowLine: View {

    let card: TemporaryHomeCards.Card

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text(String(
                    localized: "temporary-home.state.active",
                    defaultValue: "Active",
                    comment: "State of a temporary home whose dates include today, beside its day count; the user may not be there right now."
                ))
                    .font(.caption.bold())
                    .foregroundStyle(.green)
            }

            Text(verbatim: "·")
                .foregroundStyle(.tertiary)

            // Minute ticks land on the stored zone's midnight, so the day flips with no store write.
            TimelineView(.everyMinute) { context in
                let displayDay = TemporaryHomeCards.dayNumber(
                    startedAt: card.startedAt, timeZoneIdentifier: card.timeZoneIdentifier,
                    now: context.date)
                Text(displayDay == 1
                     ? String(localized: "trips.active-day.one", defaultValue: "Day \(displayDay, format: .number.grouping(.never))", comment: "Ongoing trip row label for its first day.")
                     : String(localized: "trips.active-day.other", defaultValue: "Day \(displayDay, format: .number.grouping(.never))", comment: "Ongoing trip row label for a later day."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Detail

/// One temporary home: its dates, its days, the trips taken from it, the
/// visits home and the trips it split. Reloads its card on store changes and
/// on the clock, and pops once the temporary home is removed.
struct TemporaryHomeDetailView: View {

    /// The card follows its stores and the clock tick.
    private struct ReloadKey: Equatable {
        let storeToken: Int
        let clockTick: Int
    }

    let cardID: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    /// Advances when only the clock can change the card: the app activates or the day changes.
    @State private var clockTick = 0
    @State private var card: TemporaryHomeCards.Card?
    /// The rows behind `card.tripIDs`, oldest first.
    @State private var trips: [Trip] = []
    @State private var sheetMode: TemporaryHomeFormSheet.Mode?
    /// Where its owed reconciliation stands; nil when nothing is owed.
    @State private var status: CoverageReconciliationQueue.TemporaryHomeStatus?
    /// The device-local archives of the trips it split (`splitTrips`).
    @State private var splitTrips: [DissolvedTripRecord] = []
    /// The last read of those archives failed: the list on screen is the
    /// last one read, and the section offers Try Again.
    @State private var splitTripsLoadFailed = false
    /// The split trip Keep as One Trip is running for.
    @State private var keepingID: UUID?
    @State private var keepAlert: KeepAsOneTripAlert?

    /// `card` is the list's snapshot, shown until this view's own load lands.
    init(cardID: UUID, card: TemporaryHomeCards.Card? = nil) {
        self.cardID = cardID
        _card = State(initialValue: card)
    }

    var body: some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .task(id: ReloadKey(
                storeToken: StoreChangeTracker.shared.token(for: [.temporaryHome, .stay, .trip]),
                clockTick: clockTick)) {
                await reload()
            }
            // The trips list's clock: the state, the day and "Now" move with no store write.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                clockTick &+= 1
            }
            // UIKit posts it at local midnight (queued while the app is suspended).
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                clockTick &+= 1
            }
            // The card's own next change: its start, just after its end, a
            // hint's threshold, read in the stored zones, not the device's.
            .task(id: card?.nextReloadAt) {
                guard let next = card?.nextReloadAt else { return }
                let delay = next.timeIntervalSinceNow
                if delay > 0 {
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
                clockTick &+= 1
            }
            // A drain records a failure or a deferral device-locally and writes nothing else.
            .onReceive(TemporaryHomesSettingsSection.queueStatusChanges) { _ in
                readStatus()
            }
            .sheet(item: $sheetMode) { mode in
                TemporaryHomeFormSheet(mode: mode)
            }
            .alert(keepAlert?.title ?? "", isPresented: Binding(
                get: { keepAlert != nil },
                set: { if !$0 { keepAlert = nil } }
            ), presenting: keepAlert) { _ in
                Button("OK", role: .cancel) {}
            } message: { alert in
                if let message = alert.message {
                    Text(message)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let card {
            List {
                headerSection(card)
                daysSection(card)
                tripsSection(card)
                visitsHomeSection(card)
                splitTripsSection
                actionsSection(card)
            }
            .navigationTitle(card.title)
        } else {
            ProgressView()
        }
    }

    // MARK: Sections

    private func headerSection(_ card: TemporaryHomeCards.Card) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(card.title)
                        .font(.title3.bold())

                    Spacer()

                    if !card.countryFlags.isEmpty {
                        Text(card.countryFlags)
                            .font(.title2)
                    }
                }

                if let placeLine = card.placeLine {
                    Text(placeLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(TemporaryHomesSettingsSection.dateLine(
                    startedAt: card.startedAt, endedAt: card.endedAt,
                    timeZoneIdentifier: card.timeZoneIdentifier, now: .now))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                switch card.state {
                case .active:
                    TemporaryHomeNowLine(card: card)
                case .upcoming:
                    Text(String(
                        localized: "temporary-home.state.upcoming",
                        defaultValue: "Upcoming",
                        comment: "State of a temporary home whose start date is still ahead."
                    ))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                case .ended:
                    Text(String(
                        localized: "temporary-home.state.ended",
                        defaultValue: "Ended",
                        comment: "State of a temporary home whose end date has passed."
                    ))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                }

                if let status {
                    TemporaryHomeUpdatingLine(status: status) { retryUpdate() }
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func daysSection(_ card: TemporaryHomeCards.Card) -> some View {
        let onTrips = card.awayDays - card.stayingDays
        if card.awayDays > 0 || card.stayingDays > 0 {
            Section {
                if card.awayDays > 0 {
                    LabeledContent(String(
                        localized: "temporary-home.detail.days.away",
                        defaultValue: "Days away from home",
                        comment: "Temporary home detail row label: days the user spent away from their real, permanent home during this temporary home. The rows under it split the figure into 'At this temporary home' and 'On trips from here'."
                    )) {
                        Text(card.awayDays, format: .number)
                    }
                }
                if card.stayingDays > 0 {
                    LabeledContent(String(
                        localized: "temporary-home.detail.days.staying",
                        defaultValue: "At this temporary home",
                        comment: "Temporary home detail row: days spent at the temporary home itself, not on a trip."
                    )) {
                        Text(card.stayingDays, format: .number)
                    }
                }
                // The two above subtracted: every trip day inside its spans,
                // the trip that arrived here included, so the rows add up.
                if onTrips > 0 {
                    LabeledContent(String(
                        localized: "temporary-home.detail.days.on-trips",
                        defaultValue: "On trips",
                        comment: "Temporary home detail row label: days spent on trips during this temporary home."
                    )) {
                        Text(onTrips, format: .number)
                    }
                }
            } header: {
                Text(String(
                    localized: "temporary-home.detail.days.header",
                    defaultValue: "Days",
                    comment: "Header of the temporary home detail section that counts days."
                ))
            }
        }
    }

    private func tripsSection(_ card: TemporaryHomeCards.Card) -> some View {
        Section {
            if card.tripIDs.isEmpty {
                Text(String(
                    localized: "temporary-home.detail.trips.empty",
                    defaultValue: "No trips from here yet.",
                    comment: "Shown in the temporary home detail when no trip was taken from the temporary home."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else {
                // `isDeleted` is the one safe read on a row a rebuild removed.
                ForEach(trips.filter { !$0.isDeleted }, id: \.persistentModelID) { trip in
                    NavigationLink {
                        TripDetailView(trip: trip)
                    } label: {
                        TemporaryHomeTripRow(trip: trip)
                    }
                }
            }
        } header: {
            Text(String(
                localized: "temporary-home.detail.trips.header",
                defaultValue: "Trips From Here",
                comment: "Header of the temporary home detail section listing the trips taken from the temporary home."
            ))
        }
    }

    @ViewBuilder
    private func visitsHomeSection(_ card: TemporaryHomeCards.Card) -> some View {
        if !card.visitsHome.isEmpty {
            Section {
                ForEach(Array(card.visitsHome.enumerated()), id: \.element) { index, visit in
                    Text(Self.visitText(
                        visit, isOngoing: card.visitHomeIsOngoing && visit == card.visitsHome.last,
                        timeZoneIdentifier: card.visitHomeTimeZoneIdentifier(at: index)))
                }
            } header: {
                Text(String(
                    localized: "temporary-home.detail.visits-home.header",
                    defaultValue: "Visits Home",
                    comment: "Header of the temporary home detail section listing the periods spent back at the real home."
                ))
            }
        }
    }

    /// The curated trips its setup split, each with Keep as One Trip. Hidden
    /// when there are none and the last read succeeded.
    @ViewBuilder
    private var splitTripsSection: some View {
        if !splitTrips.isEmpty || splitTripsLoadFailed {
            Section {
                ForEach(splitTrips) { record in
                    splitTripRow(record)
                }
                if splitTripsLoadFailed {
                    splitTripsFailedRow
                }
            } header: {
                Text(String(
                    localized: "temporary-home.detail.split-trips.header",
                    defaultValue: "Split Trips",
                    comment: "Header of the temporary home detail section listing the trips that setting it up split into time at it and trips of their own."
                ))
            } footer: {
                Text(String(
                    localized: "temporary-home.detail.split-trips.footer",
                    defaultValue: "These trips were split by a change to this temporary home. Keep as One Trip puts a trip back together and stops this temporary home from splitting it again. Copies are kept on this device only.",
                    comment: "Footer of the temporary home detail section listing the trips that setting it up, or a later change to it, split; explains its Keep as One Trip buttons, that a kept trip is not split by this temporary home again, and that the copies they restore from live on this device only."
                ))
            }
        }
    }

    /// The archives could not be read: the rows above are the last read.
    private var splitTripsFailedRow: some View {
        HStack {
            Text(String(
                localized: "temporary-home.detail.split-trips.failed",
                defaultValue: "Couldn't load split trips.",
                comment: "Row in the Split Trips section of a temporary home's detail when the device-local copies of the trips it split could not be read. A Try Again button follows it."
            ))
            .foregroundStyle(.secondary)
            Spacer()
            Button(String(
                localized: "temporary-home.detail.split-trips.retry",
                defaultValue: "Try Again",
                comment: "Button beside \"Couldn't load split trips.\" in a temporary home's detail: reads the copies of the trips it split again."
            )) {
                Task { await loadSplitTrips() }
            }
        }
    }

    /// Its name and dates, then Keep as One Trip.
    private func splitTripRow(_ record: DissolvedTripRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.displayName(languageTag: AppLanguagePreference.currentTag()))
                    .font(.subheadline.weight(.semibold))
                Text(NearHomeActivityView.removedDateLine(for: record))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                keepAsOneTrip(record)
            } label: {
                if keepingID == record.id {
                    ProgressView().controlSize(.small)
                } else {
                    Text(KeepAsOneTripAlert.actionTitle)
                        .font(.callout.weight(.medium))
                        .accessibilityLabel(KeepAsOneTripAlert.accessibilityLabel(
                            tripName: record.displayName(languageTag: AppLanguagePreference.currentTag())))
                }
            }
            .buttonStyle(.bordered)
            .disabled(keepingID != nil)
        }
        .padding(.vertical, 2)
    }

    private func actionsSection(_ card: TemporaryHomeCards.Card) -> some View {
        Section {
            Button("Edit") {
                sheetMode = .edit(id: card.id)
            }
            if card.extendSuggested {
                Button(String(
                    localized: "temporary-home.detail.extend",
                    defaultValue: "Extend",
                    comment: "Button in the detail of a temporary home that ended lately, while the user still seems to be there, that opens its form to move or remove the end date."
                )) {
                    sheetMode = TemporaryHomeCardRow.extendMode(for: card)
                }
            }
            if card.state == .active {
                // The form picks the day, preset to the suggested one, and shows what changes.
                Button(String(
                    localized: "temporary-home.detail.end",
                    defaultValue: "End…",
                    comment: "Button in the temporary home detail that opens a form to pick its last day and end it."
                )) {
                    sheetMode = TemporaryHomeCardRow.endMode(for: card)
                }
            }
        }
    }

    // MARK: Pure

    /// The archives of the trips `temporaryHomeID` split, newest split first.
    nonisolated static func splitTrips(
        _ records: [DissolvedTripRecord], temporaryHomeID: UUID
    ) -> [DissolvedTripRecord] {
        records
            .filter { $0.splitByTemporaryHomeID == temporaryHomeID }
            .sorted { $0.dissolvedAt > $1.dissolvedAt }
    }

    /// The Split Trips list after a read of the archives: a successful read
    /// replaces it, a failed one keeps the last list and says so. Pure.
    nonisolated static func splitTripsAfterLoad(
        _ result: Result<[DissolvedTripRecord], any Error>, previous: [DissolvedTripRecord],
        temporaryHomeID: UUID
    ) -> (records: [DissolvedTripRecord], failed: Bool) {
        switch result {
        case .success(let records): (splitTrips(records, temporaryHomeID: temporaryHomeID), false)
        case .failure: (previous, true)
        }
    }

    // MARK: Copy

    /// A visit home: its days, or "Since 20 Dec" while it goes on, read in
    /// the zone of the real-home stay it began with.
    nonisolated static func visitText(
        _ visit: DateInterval, isOngoing: Bool, timeZoneIdentifier: String?,
        locale: Locale = AppLanguagePreference.currentLocale()
    ) -> String {
        guard isOngoing else { return dateRange(visit, timeZoneIdentifier: timeZoneIdentifier, locale: locale) }
        let start = visit.start.formatted(Date.FormatStyle(
            date: .abbreviated, time: .omitted, locale: locale,
            timeZone: StayTimeZone.resolve(timeZoneIdentifier)))
        return String(
            localized: "temporary-home.detail.visits-home.ongoing",
            defaultValue: "Since \(start)",
            comment: "Row in the Visits Home section of a temporary home's detail for a visit back at the real home that is still going on; the placeholder is the day it began."
        )
    }

    /// One day, or a range of days, read in `timeZoneIdentifier`.
    nonisolated static func dateRange(
        _ interval: DateInterval, timeZoneIdentifier: String?,
        locale: Locale = AppLanguagePreference.currentLocale()
    ) -> String {
        let zone = StayTimeZone.resolve(timeZoneIdentifier)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        if calendar.isDate(interval.start, inSameDayAs: interval.end) {
            return interval.start.formatted(Date.FormatStyle(
                date: .abbreviated, time: .omitted, locale: locale, timeZone: zone))
        }
        return (interval.start..<interval.end).formatted(Date.IntervalFormatStyle(
            date: .abbreviated, time: .omitted, locale: locale, timeZone: zone))
    }

    // MARK: Load & actions

    private func reload() async {
        // The trips of the card already on screen, before the fresh card lands.
        loadTrips()
        readStatus()
        let outcome = await TemporaryHomeCards.loadDetached(
            container: modelContext.container, now: .now, fallbackZone: .current)
        if case .superseded = outcome { return }
        await loadSplitTrips()
        guard !Task.isCancelled else { return }
        switch outcome {
        case .superseded:
            return
        case .loaded(let cards):
            guard let fresh = cards.first(where: { $0.id == cardID }) else {
                // Removed: nothing is left to show.
                dismiss()
                return
            }
            card = fresh
            loadTrips()
        case .failed(let error):
            // A failed read is not a removal: keep what is on screen.
            temporaryHomeCardLogger.error("Temporary home detail load failed: \(error.localizedDescription)")
        }
    }

    private func loadTrips() {
        let ids = card?.tripIDs ?? []
        guard !ids.isEmpty else {
            trips = []
            return
        }
        do {
            let rows = try modelContext.fetch(FetchDescriptor<Trip>(
                predicate: #Predicate { ids.contains($0.id) }))
            // The card's order; a same-id twin is shown once.
            var byID: [UUID: Trip] = [:]
            for row in rows where byID[row.id] == nil { byID[row.id] = row }
            trips = ids.compactMap { byID[$0] }
        } catch {
            // A failed read is not "no trips": keep the rows on screen.
            temporaryHomeCardLogger.error("Temporary home trips read failed: \(error.localizedDescription)")
        }
    }

    /// The queue file is read off-main, as Removed Trips reads it. A failed
    /// read is not "no split trips": the rows on screen stay.
    private func loadSplitTrips() async {
        let result = await Task.detached(priority: .userInitiated) {
            Result { try DissolvedTripQueue.loadThrowing() }
        }.value
        if case .failure(let error) = result {
            temporaryHomeCardLogger.error("Split trips read failed: \(error.localizedDescription)")
        }
        let loaded = Self.splitTripsAfterLoad(result, previous: splitTrips, temporaryHomeID: cardID)
        splitTrips = loaded.records
        splitTripsLoadFailed = loaded.failed
    }

    private func readStatus() {
        let read = CoverageReconciliationQueue.temporaryHomeStatus(id: cardID)
        if read != status { status = read }
    }

    /// Try Again on a failed update: updating at once, then whatever the drain left.
    private func retryUpdate() {
        status = .updating
        let id = cardID
        Task {
            await CoverageReconciliationQueue.retryTemporaryHome(id: id)
            readStatus()
        }
    }

    /// Keep as One Trip (`HomeAreaHealing.keepSplitTrip`), then what it did,
    /// worded as Removed Trips words it. A kept trip's row goes.
    private func keepAsOneTrip(_ record: DissolvedTripRecord) {
        keepingID = record.id
        Task {
            let outcome = await HomeAreaHealing.keepSplitTrip(record)
            keepAlert = KeepAsOneTripAlert(
                outcome: outcome,
                tripName: record.displayName(languageTag: AppLanguagePreference.currentTag()))
            await loadSplitTrips()
            keepingID = nil
        }
    }
}

/// A trip taken from a temporary home: name, flags, dates and day count.
private struct TemporaryHomeTripRow: View {

    let trip: Trip

    var body: some View {
        // A delete can land before the parent refilters; `isDeleted` is the one safe read then.
        if !trip.isDeleted {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(trip.hasUsableDisplayName ? trip.displayName : String(localized: "trips.active-name.fallback", defaultValue: "Trip in Progress", comment: "Fallback title for an ongoing trip without a usable name."))
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    if !trip.countryFlags.isEmpty {
                        Text(trip.countryFlags)
                    }
                }

                HStack(spacing: 16) {
                    Label(formattedDateRange, systemImage: "calendar")

                    if let days = trip.durationDays {
                        Label(days == 1
                              ? String(localized: "trips.duration-days.one", defaultValue: "\(days, format: .number.grouping(.never)) day", comment: "Completed trip row duration of one day.")
                              : String(localized: "trips.duration-days.other", defaultValue: "\(days, format: .number.grouping(.never)) days", comment: "Completed trip row duration of multiple days."), systemImage: "clock")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    /// The trips list row's date range.
    private var formattedDateRange: String {
        let start = trip.startDate.formatted(date: .abbreviated, time: .omitted)
        if let endDate = trip.endDate {
            if Calendar.current.isDate(trip.startDate, inSameDayAs: endDate) { return start }
            return (trip.startDate..<endDate).formatted(
                Date.IntervalFormatStyle(date: .abbreviated, time: .omitted)
            )
        }
        return String(localized: "trips.date-range.now", defaultValue: "\(start) - now", comment: "Open trip date range ending now; preserve the English hyphen glyph.")
    }
}

// MARK: - Prefill from a trip

nonisolated extension TemporaryHomeFormSheet.Prefill {

    /// One stay of a trip, reduced to what the prefill and the suggestion read.
    nonisolated struct TripStay: Sendable {
        let id: UUID
        let start: Date
        let end: Date
        let latitude: Double
        let longitude: Double
        let isDestination: Bool
        let isAirport: Bool
        /// Its city and country, which group the evidence by place.
        var locality: String? = nil
        var isoCountryCode: String? = nil
        /// The zone its overnight dates are read in.
        var timeZoneIdentifier: String? = nil
    }

    /// Whether a trip is offered "Set Up a Temporary Home…": one still open,
    /// or one that lasted 14 days or more. It reads stored trip fields only,
    /// so the trips list's menus add no stay reads; the days are counted in
    /// one zone, which can differ by a day from the row's own count.
    static func isOffered(
        isComplete: Bool, startDate: Date, endDate: Date?, timeZone: TimeZone = .current
    ) -> Bool {
        guard isComplete, let endDate else { return true }
        return Trip.inclusiveDays(from: startDate, in: timeZone, to: endDate, in: timeZone) >= 14
    }

    /// What "Set Up a Temporary Home…" opens the form with for a trip: its
    /// custom name and, from the place its stays point at
    /// (`TemporaryHomeSuggestion.dominantPlace`, the suggestion's own rule),
    /// that place's pin, the start of the first stay there (the arrival)
    /// and, once the trip is complete, the end of the last one (the
    /// departure). With no destination evidence: no pin and the trip's own
    /// dates. Pure.
    static func forTrip(
        customName: String?, startDate: Date, endDate: Date?, isComplete: Bool, stays: [TripStay]
    ) -> TemporaryHomeFormSheet.Prefill {
        forTrip(
            customName: customName, startDate: startDate, endDate: endDate, isComplete: isComplete,
            place: TemporaryHomeSuggestion.dominantPlace(stays))
    }

    /// `forTrip` over a place already found. Pure.
    static func forTrip(
        customName: String?, startDate: Date, endDate: Date?, isComplete: Bool,
        place: TemporaryHomeSuggestion.Place?
    ) -> TemporaryHomeFormSheet.Prefill {
        var name: String?
        if let customName, !customName.isEmpty { name = customName }
        guard let place, let arrival = place.stays.first else {
            return TemporaryHomeFormSheet.Prefill(
                name: name, coordinate: nil, since: startDate, until: isComplete ? endDate : nil)
        }
        return TemporaryHomeFormSheet.Prefill(
            name: name,
            coordinate: place.pin,
            since: arrival.start,
            until: isComplete ? place.stays.map(\.end).max() : nil)
    }

    /// The stays of a stored trip as the prefill and the suggestion read
    /// them. Reads stored fields only.
    static func tripStays(of trip: Trip) -> [TripStay] {
        let destinationRaw = StayCategory.destination.rawValue
        return (trip.stays ?? []).map {
            TripStay(
                id: $0.id, start: $0.startTime, end: $0.endTime,
                latitude: $0.centroidLatitude, longitude: $0.centroidLongitude,
                isDestination: $0.categoryRaw == destinationRaw, isAirport: $0.isAirport,
                locality: $0.locality, isoCountryCode: $0.isoCountryCode,
                timeZoneIdentifier: $0.timeZoneIdentifier)
        }
    }

    /// The prefill for a stored trip. Reads stored fields only.
    static func forTrip(_ trip: Trip) -> TemporaryHomeFormSheet.Prefill {
        forTrip(
            customName: trip.customName, startDate: trip.startDate, endDate: trip.endDate,
            isComplete: trip.isComplete, stays: tripStays(of: trip))
    }
}
