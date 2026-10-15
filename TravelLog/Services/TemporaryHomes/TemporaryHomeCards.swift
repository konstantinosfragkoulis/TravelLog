//
//  TemporaryHomeCards.swift
//  TravelLog
//

import Foundation
import SwiftData

/// Value snapshots behind the Temporary Homes section of the trips list and
/// the temporary home detail page, built off the main actor on their own
/// context. Spans and day labels come from `TemporaryHomeLedger`; nothing
/// here decides what counts as staying.
nonisolated enum TemporaryHomeCards {

    nonisolated struct Card: Sendable, Identifiable, Equatable {
        nonisolated enum State: Sendable, Equatable { case upcoming, active, ended }

        let id: UUID
        /// The label, else the locality, else the localized default.
        let title: String
        /// "Brussels, Belgium" when known.
        let placeLine: String?
        let countryCode: String?
        let startedAt: Date
        let endedAt: Date?
        /// The zone the dates were chosen in; their days are read in it.
        let timeZoneIdentifier: String?
        let state: State
        /// Active only: inclusive civil days from `startedAt` to now.
        let dayNumber: Int?
        /// Day labels of its staying spans, trips taken from it included.
        let awayDays: Int
        /// Those labels that are not trip days.
        let stayingDays: Int
        /// Trips that left from it (`departurePlaceName`'s rule), oldest first.
        let tripIDs: [UUID]
        /// The destination countries of those trips, each once, in first-visit order.
        let tripCountryCodes: [String]
        /// Its stretches at a real Home after its first own stay (`homeRuns`),
        /// clipped to its dates and to now, oldest first.
        let visitsHome: [DateInterval]
        /// The end of the last home stay it owns, which the detail's End…
        /// presets (`endHint`). Only for an active temporary home, open-ended
        /// or with its end ahead, as soon as a qualifying stay at a real Home
        /// follows that stay, before the card's own prompt.
        let suggestedEnd: Date?
        /// The card's end hint: the start of the stretch at a real Home that
        /// has lasted `endHintHomeDays`. Nil until then, also with `suggestedEnd`,
        /// and always for one with a set end: a visit home before it is no sign it ended.
        let backHomeSince: Date?
        /// The last of `visitsHome` is still going on: it ends now.
        var visitHomeIsOngoing = false
        /// The user answered this end hint Not Yet (`dismissEndHint`): the
        /// card hides it, the detail page still offers its date.
        var endHintDismissed = false
        /// Ended lately while the user seems to be there still: the card asks
        /// whether to extend it (`extendSuggested`).
        var extendSuggested = false
        /// Its city, for the Extend question.
        var locality: String? = nil
        /// The zone each of `visitsHome` is read in, in its order: the zone of
        /// the real-home stay it starts with, not the temporary home's.
        var visitsHomeTimeZoneIdentifiers: [String?] = []
        /// The zone `backHomeSince` is read in: its real-home stay's.
        var backHomeTimeZoneIdentifier: String? = nil
        /// The next instant at which its state or hints change with no store
        /// write: its start, just after its end, a stretch at a real Home
        /// reaching `endHintHomeDays`, the end of the Extend window. Nil when
        /// none lies ahead.
        var nextReloadAt: Date? = nil

        /// The zone visit `index` of `visitsHome` is read in; the temporary
        /// home's own when the card carries none for it.
        func visitHomeTimeZoneIdentifier(at index: Int) -> String? {
            visitsHomeTimeZoneIdentifiers.indices.contains(index)
                ? visitsHomeTimeZoneIdentifiers[index] : timeZoneIdentifier
        }

        /// Its own country's flag, then the flags of the trips from it, each
        /// once: the form of `Trip.countryFlags`, which shows every flag.
        var countryFlags: String {
            var seen = Set<String>()
            var flags: [String] = []
            for code in [countryCode].compactMap({ $0 }) + tripCountryCodes
            where seen.insert(code.uppercased()).inserted {
                if let flag = flagEmoji(for: code) { flags.append(flag) }
            }
            return flags.joined(separator: " ")
        }
    }

    /// Civil days a stretch at a real Home must last, read in its first
    /// stay's zone, before the end hint shows.
    static let endHintHomeDays = 3

    /// A routine stay shorter than this (a gym or an office day) is part of a
    /// stretch at a real Home; a longer one ends it.
    static let routineInterruptionSeconds: TimeInterval = 12 * 3600

    /// How long an ended card stays in the trips list's top section, which
    /// is also how long it can offer Extend.
    static let recentlyEndedSeconds: TimeInterval = 30 * 86_400

    /// The trips list's two sections, each in the order of `cards`: upcoming
    /// and active cards and those that ended within `recentlyEndedSeconds`
    /// before `now`, then the ones that ended earlier. Pure.
    static func sections(_ cards: [Card], now: Date) -> (current: [Card], past: [Card]) {
        let cutoff = now.addingTimeInterval(-recentlyEndedSeconds)
        var current: [Card] = []
        var past: [Card] = []
        for card in cards {
            if let endedAt = card.endedAt, endedAt < cutoff {
                past.append(card)
            } else {
                current.append(card)
            }
        }
        return (current, past)
    }

    /// The store reads behind `load` and `departurePlaceName`. A DEBUG hook
    /// can fail one by name; the caller throws it.
    nonisolated enum Read: String, Sendable, CaseIterable {
        case temporaryHomes, travelDays, ledger, trips, departureStay, departureStays
    }

    #if DEBUG
    /// Task-local, so a detached worker must re-install it.
    @TaskLocal static var readFailureForTesting: (@Sendable (Read) throws -> Void)?
    #endif

    /// Test checkpoint immediately before a required read; a no-op in release.
    private static func checkRead(_ read: Read) throws {
        #if DEBUG
        try readFailureForTesting?(read)
        #endif
    }

    // MARK: - Cards

    /// One card per temporary home: active first, then upcoming, then ended
    /// with the latest end first. With no temporary home it returns `[]`
    /// after ONE fetch (the temporary-home rows). Any failed read throws, and
    /// so does `checkCancellation`, which runs between reads and per card.
    /// `defaults` holds the Not Yet answers.
    static func load(
        container: ModelContainer, now: Date, fallbackZone: TimeZone,
        defaults: UserDefaults = .standard, checkCancellation: () throws -> Void = {}
    ) throws -> [Card] {
        try checkCancellation()
        let context = ModelContext(container)
        try checkRead(.temporaryHomes)
        let allRows = try context.fetch(FetchDescriptor<TemporaryHome>())
        let rows = HomeAnchors.collapsingTwins(allRows)
        guard !rows.isEmpty else { return [] }
        // Every id a home stay can record, removed ones included.
        let knownIDs = Set(allRows.map(\.id))

        try checkCancellation()
        try checkRead(.travelDays)
        let travelling = try TravelDays.labels(
            container: container, now: now, fallbackZone: fallbackZone,
            checkCancellation: checkCancellation)
        try checkRead(.ledger)
        let inputs = try TemporaryHomeLedger.inputs(
            container: container, now: now, checkCancellation: checkCancellation)
        let ledger = try TemporaryHomeLedger.result(
            travelling: travelling, inputs: inputs, now: now,
            fallbackZone: fallbackZone, checkCancellation: checkCancellation)

        var tripDescriptor = FetchDescriptor<Trip>()
        tripDescriptor.propertiesToFetch = [\.id, \.startDate, \.countryCodes]
        try checkCancellation()
        try checkRead(.trips)
        var trips: [(id: UUID, start: Date, countryCodes: String)] = try context.fetch(tripDescriptor).map {
            (id: $0.id, start: $0.startDate, countryCodes: $0.countryCodes)
        }
        trips.sort { a, b in
            if a.start != b.start { return a.start < b.start }
            return a.id.uuidString < b.id.uuidString
        }
        try checkCancellation()
        let tripsFromHome = try tripIndicesByDepartureHome(
            tripStarts: trips.map(\.start), rows: rows, in: context)

        // The hints read the ledger's own stays: every stay from the earliest
        // start to now, in time order.
        try checkCancellation()
        let timeline = inputs.stays.sorted(by: timelineOrder)
        let runs = homeRuns(timeline, knownIDs: knownIDs, visitBackedStayIDs: inputs.visitBackedStayIDs)
        let locale = AppLanguagePreference.currentLocale()

        let cards: [Card] = try rows.map { row in
            try checkCancellation()
            let anchor = HomeAnchor(row)
            let spans = ledger.spansByHome[row.id] ?? []
            let spanLabels = try TravelDays.labels(
                forSpans: spans.map {
                    (start: $0.start, end: $0.end, firstZone: $0.firstZone, lastZone: $0.lastZone)
                },
                now: now, fallbackZone: fallbackZone, checkCancellation: checkCancellation)
            var tripIDs: [UUID] = []
            var tripCountryCodes: [String] = []
            for index in tripsFromHome[row.id] ?? [] {
                let trip = trips[index]
                // A same-id twin trip is listed once.
                if !tripIDs.contains(trip.id) { tripIDs.append(trip.id) }
                for code in trip.countryCodes.split(separator: ",").map(String.init)
                where !tripCountryCodes.contains(code) {
                    tripCountryCodes.append(code)
                }
            }
            let state: Card.State
            if row.startedAt > now {
                state = .upcoming
            } else if let endedAt = row.endedAt, now > endedAt {
                state = .ended
            } else {
                state = .active
            }
            let own = ownIndices(of: anchor, in: timeline)
            let visits = visitsHome(of: anchor, own: own, runs: runs, now: now)
            var hint = state == .active
                ? endHint(own: own, timeline: timeline, runs: runs, now: now, fallbackZone: fallbackZone)
                : (suggestedEnd: nil, shown: nil, pendingThreshold: nil)
            // Only an open end is asked about; the detail's End still presets the day.
            if row.endedAt != nil {
                hint.shown = nil
                hint.pendingThreshold = nil
            }

            var reloads: [Date] = hint.pendingThreshold.map { [$0] } ?? []
            switch state {
            case .upcoming:
                reloads.append(row.startedAt)
            case .active:
                // Just after the last second of its end day.
                if let endedAt = row.endedAt { reloads.append(endedAt.addingTimeInterval(1)) }
            case .ended:
                // Extend's window closes and the list moves the card down.
                if let endedAt = row.endedAt {
                    reloads.append(endedAt.addingTimeInterval(recentlyEndedSeconds + 1))
                }
            }

            return Card(
                id: row.id,
                title: title(for: row, locale: locale),
                placeLine: placeLine(for: row, locale: locale),
                countryCode: row.isoCountryCode,
                startedAt: row.startedAt,
                endedAt: row.endedAt,
                timeZoneIdentifier: row.timeZoneIdentifier,
                state: state,
                dayNumber: state == .active
                    ? dayNumber(startedAt: row.startedAt, timeZoneIdentifier: row.timeZoneIdentifier,
                                now: now, fallbackZone: fallbackZone)
                    : nil,
                awayDays: spanLabels.count,
                // Its own spans, not the ledger's per-home share: where two
                // temporary homes overlap, the share goes to the earlier one and
                // the difference would read as trip days nobody took.
                stayingDays: spanLabels.subtracting(travelling).count,
                tripIDs: tripIDs,
                tripCountryCodes: tripCountryCodes,
                visitsHome: visits.intervals,
                suggestedEnd: hint.suggestedEnd,
                backHomeSince: hint.shown?.backHomeSince,
                visitHomeIsOngoing: visits.lastIsOngoing,
                endHintDismissed: hint.shown.map {
                    isEndHintDismissed(id: row.id, backHomeSince: $0.backHomeSince, defaults: defaults)
                } ?? false,
                extendSuggested: state == .ended && extendSuggested(
                    for: anchor, timeline: timeline, knownIDs: knownIDs,
                    visitBackedStayIDs: inputs.visitBackedStayIDs, now: now),
                locality: row.locality,
                visitsHomeTimeZoneIdentifiers: visits.zones,
                backHomeTimeZoneIdentifier: hint.shown?.zone,
                nextReloadAt: reloads.filter { $0 > now }.min())
        }

        // `rows` come ordered by start, then id; active and upcoming keep that order.
        var ordered = cards.filter { $0.state == Card.State.active }
        ordered += cards.filter { $0.state == Card.State.upcoming }
        ordered += cards.filter { $0.state == Card.State.ended }.sorted { (a: Card, b: Card) -> Bool in
            let aEnd = a.endedAt ?? .distantPast
            let bEnd = b.endedAt ?? .distantPast
            if aEnd != bEnd { return aEnd > bEnd }
            return a.id.uuidString < b.id.uuidString
        }
        return ordered
    }

    /// How a view's load ended. A superseded load (its task was cancelled)
    /// is never shown, as cards or as a failure.
    nonisolated enum LoadOutcome: Sendable {
        case loaded([Card])
        case failed(any Error)
        case superseded
    }

    /// `load` on a detached worker the caller's task owns, the way
    /// `StatsAggregator.load` runs: cancelling the task cancels the worker,
    /// which stops at its next check.
    static func loadDetached(
        container: ModelContainer, now: Date, fallbackZone: TimeZone
    ) async -> LoadOutcome {
        #if DEBUG
        let readFailure = readFailureForTesting
        #endif
        let worker = Task.detached(priority: .userInitiated) {
            #if DEBUG
            return try $readFailureForTesting.withValue(readFailure) {
                try load(container: container, now: now, fallbackZone: fallbackZone) {
                    try Task.checkCancellation()
                }
            }
            #else
            return try load(container: container, now: now, fallbackZone: fallbackZone) {
                try Task.checkCancellation()
            }
            #endif
        }
        do {
            let cards = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            return Task.isCancelled ? .superseded : .loaded(cards)
        } catch {
            return Task.isCancelled || error is CancellationError ? .superseded : .failed(error)
        }
    }

    /// Inclusive civil days from `startedAt` to `now` in the zone the dates
    /// were chosen in: the Current Trip widget's rule and its work bound.
    static func dayNumber(
        startedAt: Date, timeZoneIdentifier: String?, now: Date, fallbackZone: TimeZone = .current
    ) -> Int {
        let zone = StayTimeZone.resolve(timeZoneIdentifier, fallback: fallbackZone)
        return min(3_651, Trip.inclusiveDays(from: startedAt, in: zone, to: now, in: zone))
    }

    /// The rule of `TemporaryHome.displayLabel`, which is main-actor bound.
    private static func title(for row: TemporaryHome, locale: Locale) -> String {
        if !row.label.isEmpty { return row.label }
        if let locality = row.locality, !locality.isEmpty { return locality }
        return localizedRendererString(
            localized: "temporary-home.default-label",
            defaultValue: "Temporary Home",
            bundle: nil,
            locale: locale)
    }

    /// The place line the Settings row shows: city and country, else the country.
    private static func placeLine(for row: TemporaryHome, locale: Locale) -> String? {
        guard let country = localizedCountryName(
            iso: row.isoCountryCode, fallback: row.country, locale: locale) else { return nil }
        guard let locality = row.locality, !locality.isEmpty else { return country }
        return String(localized: "\(locality), \(country)")
    }

    // MARK: - Evidence after the declaration

    /// Time order, then id; same-id twins by end, category and provenance,
    /// so the fetch order never decides.
    private static func timelineOrder(
        _ a: TemporaryHomeLedger.StaySample, _ b: TemporaryHomeLedger.StaySample
    ) -> Bool {
        if a.start != b.start { return a.start < b.start }
        if a.id != b.id { return a.id.uuidString < b.id.uuidString }
        if a.end != b.end { return a.end < b.end }
        if a.categoryRaw != b.categoryRaw { return a.categoryRaw < b.categoryRaw }
        return (a.temporaryHomeID?.uuidString ?? "") < (b.temporaryHomeID?.uuidString ?? "")
    }

    /// A stretch at a real Home: from a home stay no temporary home records
    /// that qualifies as a trip boundary (the assembly rule), through the
    /// real-home stays after it, until a stay that is neither at a real Home
    /// nor a short routine one (`routineInterruptionSeconds`). A short routine
    /// stay neither ends it nor extends it; a longer one, like a trip taken
    /// from home, is never part of one.
    private struct HomeRun {
        /// Timeline index of its first stay.
        let firstIndex: Int
        let start: Date
        /// The zone its days are read in: its first stay's.
        let zone: String?
        /// Its last real-home stay's end.
        let lastEnd: Date
        /// Its last real-home stay is the newest stay: it lasts until now.
        let isOngoing: Bool

        /// Never past now, whatever a stay's stored end says.
        func end(now: Date) -> Date { isOngoing ? now : min(lastEnd, now) }
    }

    private static func homeRuns(
        _ timeline: [TemporaryHomeLedger.StaySample], knownIDs: Set<UUID>, visitBackedStayIDs: Set<UUID>
    ) -> [HomeRun] {
        let homeRaw = StayCategory.home.rawValue
        let routineRaw = StayCategory.routine.rawValue
        var runs: [HomeRun] = []
        var open: (firstIndex: Int, lastIndex: Int, lastEnd: Date)?
        func close() {
            guard let run = open else { return }
            let first = timeline[run.firstIndex]
            runs.append(HomeRun(
                firstIndex: run.firstIndex, start: first.start, zone: first.timeZoneIdentifier,
                lastEnd: run.lastEnd, isOngoing: run.lastIndex == timeline.count - 1))
            open = nil
        }
        for (index, stay) in timeline.enumerated() {
            if stay.categoryRaw == homeRaw,
               HomeAnchors.recordedOwner(
                temporaryHomeID: stay.temporaryHomeID, knownTemporaryHomeIDs: knownIDs) == .realHome {
                if let run = open {
                    open = (run.firstIndex, index, max(run.lastEnd, stay.end))
                } else if TripClassifier.isQualifyingHomeBoundary(
                    category: .home, source: DataSource.decode(stay.sourceRaw),
                    startTime: stay.start, endTime: stay.end, pingCount: stay.pingCount,
                    hasVisit: visitBackedStayIDs.contains(stay.id)) {
                    open = (index, index, stay.end)
                }
                continue
            }
            if stay.categoryRaw == routineRaw,
               stay.end.timeIntervalSince(stay.start) < routineInterruptionSeconds { continue }
            close()
        }
        close()
        return runs
    }

    /// Timeline indices of the home stays `anchor` records.
    private static func ownIndices(
        of anchor: HomeAnchor, in timeline: [TemporaryHomeLedger.StaySample]
    ) -> [Int] {
        let homeRaw = StayCategory.home.rawValue
        return timeline.indices.filter {
            timeline[$0].categoryRaw == homeRaw && timeline[$0].temporaryHomeID == anchor.id
        }
    }

    /// Its visits to a real Home: the stretches at one (`homeRuns`) that
    /// start after its first own stay and inside its dates, clipped to its
    /// end and to now, each with its first stay's zone. The last is ongoing
    /// while it lasts until now and the temporary home is active.
    private static func visitsHome(
        of anchor: HomeAnchor, own: [Int], runs: [HomeRun], now: Date
    ) -> (intervals: [DateInterval], zones: [String?], lastIsOngoing: Bool) {
        guard let firstOwn = own.first else { return ([], [], false) }
        let upper = min(anchor.endedAt ?? now, now)
        var intervals: [DateInterval] = []
        var zones: [String?] = []
        var lastIsOngoing = false
        for run in runs where run.firstIndex > firstOwn && run.start <= upper {
            let start = max(run.start, anchor.startedAt)
            let end = min(run.end(now: now), upper)
            guard start <= end else { continue }
            intervals.append(DateInterval(start: start, end: end))
            zones.append(run.zone)
            lastIsOngoing = run.isOngoing && anchor.covers(now)
        }
        return (intervals, zones, lastIsOngoing)
    }

    /// The end of an active temporary home. `suggestedEnd`, the latest end
    /// of its own stays, as soon as any stretch at a real Home follows its
    /// last own stay: the detail's End… presets it at once. `shown`, the
    /// card's prompt: the latest such stretch that has lasted
    /// `endHintHomeDays` civil days, with its start and zone. A trip before
    /// then ends that stretch without a prompt; a later one can still prompt
    /// it, under its own `backHomeSince`. `pendingThreshold` is when the
    /// current stretch reaches the days.
    private static func endHint(
        own: [Int], timeline: [TemporaryHomeLedger.StaySample], runs: [HomeRun],
        now: Date, fallbackZone: TimeZone
    ) -> (suggestedEnd: Date?, shown: (backHomeSince: Date, zone: String?)?, pendingThreshold: Date?) {
        guard let lastOwn = own.last, let lastOwnEnd = own.map({ timeline[$0].end }).max() else {
            return (nil, nil, nil)
        }
        var suggestedEnd: Date?
        var shown: (backHomeSince: Date, zone: String?)?
        var pendingThreshold: Date?
        for run in runs where run.firstIndex > lastOwn {
            suggestedEnd = lastOwnEnd
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = StayTimeZone.resolve(run.zone, fallback: fallbackZone)
            guard let threshold = calendar.date(
                byAdding: .day, value: endHintHomeDays, to: calendar.startOfDay(for: run.start))
            else { continue }
            if run.end(now: now) >= threshold {
                shown = (backHomeSince: run.start, zone: run.zone)
            } else if run.isOngoing {
                pendingThreshold = threshold
            }
        }
        return (suggestedEnd, shown, pendingThreshold)
    }

    /// Whether an ended temporary home should offer Extend: it ended less
    /// than `recentlyEndedSeconds` ago, the latest corroborated stay that runs
    /// past its end and is not transit is there (one it made home, or one
    /// no home made home inside its area), and no qualifying stay at a real
    /// Home started since. The hint changes no classification.
    private static func extendSuggested(
        for anchor: HomeAnchor, timeline: [TemporaryHomeLedger.StaySample], knownIDs: Set<UUID>,
        visitBackedStayIDs: Set<UUID>, now: Date
    ) -> Bool {
        guard let endedAt = anchor.endedAt, now > endedAt,
              now.timeIntervalSince(endedAt) < recentlyEndedSeconds else { return false }
        let homeRaw = StayCategory.home.rawValue
        let transitRaw = StayCategory.transit.rawValue
        var present = false
        for stay in timeline where stay.end > endedAt {
            // The boundary rule's corroboration: long enough, not a lone unbacked fix.
            guard TripClassifier.isQualifyingHomeBoundary(
                category: .home, source: DataSource.decode(stay.sourceRaw),
                startTime: stay.start, endTime: stay.end, pingCount: stay.pingCount,
                hasVisit: visitBackedStayIDs.contains(stay.id)) else { continue }
            let owner = stay.categoryRaw == homeRaw
                ? HomeAnchors.recordedOwner(temporaryHomeID: stay.temporaryHomeID, knownTemporaryHomeIDs: knownIDs)
                : nil
            if owner == .realHome {
                // Back at a real Home since the end: it ended when it should.
                if stay.start > endedAt { return false }
                continue
            }
            // The latest such stay decides: a later one at another temporary home turns it off.
            if stay.categoryRaw == transitRaw { continue }
            if let owner {
                present = owner == .temporary(anchor.id)
            } else {
                present = HomeOrbit.greatCircleKm(
                    stay.latitude, stay.longitude, anchor.latitude, anchor.longitude) <= anchor.radiusKm
            }
        }
        return present
    }

    // MARK: - Not Yet

    /// Device-local: the end hints the user answered Not Yet, one
    /// "<id> <backHomeSince>" entry each, newest last. A later stretch at a
    /// real Home has another `backHomeSince`, so it asks again.
    static let endHintDismissalsKey = "temporaryHome.endHint.notYet"

    /// The most entries kept; the oldest go first.
    private static let endHintDismissalLimit = 200

    static func isEndHintDismissed(
        id: UUID, backHomeSince: Date, defaults: UserDefaults = .standard
    ) -> Bool {
        (defaults.stringArray(forKey: endHintDismissalsKey) ?? [])
            .contains(endHintDismissal(id: id, backHomeSince: backHomeSince))
    }

    static func dismissEndHint(id: UUID, backHomeSince: Date, defaults: UserDefaults = .standard) {
        let entry = endHintDismissal(id: id, backHomeSince: backHomeSince)
        var entries = (defaults.stringArray(forKey: endHintDismissalsKey) ?? []).filter { $0 != entry }
        entries.append(entry)
        defaults.set(Array(entries.suffix(endHintDismissalLimit)), forKey: endHintDismissalsKey)
    }

    private static func endHintDismissal(id: UUID, backHomeSince: Date) -> String {
        "\(id.uuidString) \(backHomeSince.timeIntervalSinceReferenceDate)"
    }

    // MARK: - Trip header

    /// The temporary home a trip left from, as a place name for "12 km from
    /// Brussels": the live one the latest home stay before the trip records
    /// (`HomeAnchors.recordedOwner`). A trip that leaves the base just after
    /// its end, with no real-home stay between, still left from it: the
    /// classifier measures its distance from the same stay. Nil when a real
    /// Home, a removed or an unsynced temporary home made that stay home,
    /// when none precedes the trip and, after ONE fetch, when no temporary
    /// home exists. Any failed read throws.
    static func departurePlaceName(tripStart: Date, container: ModelContainer) throws -> String? {
        let context = ModelContext(container)
        try checkRead(.temporaryHomes)
        let rows = HomeAnchors.collapsingTwins(try context.fetch(FetchDescriptor<TemporaryHome>()))
        // A temporary home owns no stay that starts before its own start.
        guard rows.contains(where: { $0.startedAt < tripStart }) else { return nil }

        let homeRaw = StayCategory.home.rawValue
        var descriptor = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.categoryRaw == homeRaw && $0.startTime < tripStart },
            sortBy: [SortDescriptor(\.startTime, order: .reverse), SortDescriptor(\.id, order: .reverse)]
        )
        descriptor.propertiesToFetch = [\.startTime, \.temporaryHomeID]
        descriptor.fetchLimit = 1
        try checkRead(.departureStay)
        guard let recordedID = try context.fetch(descriptor).first?.temporaryHomeID,
              let owner = rows.first(where: { $0.id == recordedID })
        else { return nil }
        // The sentence names a place, so the city comes before a custom label.
        if let locality = owner.locality, !locality.isEmpty { return locality }
        return owner.label.isEmpty ? nil : owner.label
    }

    // MARK: - Departure

    /// The trips that left from each temporary home (`departurePlaceName`'s
    /// rule), as indices into `tripStarts`, in that order. One home-stay read
    /// whatever the number of trips, and none when no trip starts after a
    /// temporary home does.
    private static func tripIndicesByDepartureHome(
        tripStarts: [Date], rows: [TemporaryHome], in context: ModelContext
    ) throws -> [UUID: [Int]] {
        // A temporary home owns no stay that starts before its own start, so
        // an earlier home stay never makes a trip one of its own.
        guard let earliestStart = rows.map(\.startedAt).min(),
              let latestTripStart = tripStarts.max(), earliestStart < latestTripStart else { return [:] }

        let homeRaw = StayCategory.home.rawValue
        var descriptor = FetchDescriptor<Stay>(
            predicate: #Predicate {
                $0.categoryRaw == homeRaw && $0.startTime >= earliestStart && $0.startTime < latestTripStart
            },
            sortBy: [SortDescriptor(\.startTime), SortDescriptor(\.id)]
        )
        descriptor.propertiesToFetch = [\.startTime, \.temporaryHomeID]
        try checkRead(.departureStays)
        let homeStays: [(start: Date, recordedID: UUID?)] = try context.fetch(descriptor).map {
            (start: $0.startTime, recordedID: $0.temporaryHomeID)
        }
        guard !homeStays.isEmpty else { return [:] }

        let liveIDs = Set(rows.map(\.id))
        var indices: [UUID: [Int]] = [:]
        for (index, tripStart) in tripStarts.enumerated() where earliestStart < tripStart {
            // Binary search: how many of the stays start before the trip.
            var low = 0
            var high = homeStays.count
            while low < high {
                let middle = (low + high) / 2
                if homeStays[middle].start < tripStart { low = middle + 1 } else { high = middle }
            }
            guard low > 0, let recordedID = homeStays[low - 1].recordedID,
                  liveIDs.contains(recordedID) else { continue }
            indices[recordedID, default: []].append(index)
        }
        return indices
    }
}
