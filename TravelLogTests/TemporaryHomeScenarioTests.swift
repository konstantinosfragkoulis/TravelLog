//
//  TemporaryHomeScenarioTests.swift
//  TravelLogTests
//
//  Acceptance scenarios for Temporary Home on the study-abroad harness: the
//  same 272-day trace, the same real urban-centre seeds and the same real
//  lanes (`PingRecorder.processLocations` → `StayClusterer` → the full
//  `TripClassifier` pipeline, Foundation Models pinned off, the launch
//  healing check once a day). Unlike the harness, every expectation here is
//  what a user should see, not what was observed.
//
//  Run (opt-in, like the harness; about a minute of CPU per variant):
//      TEST_RUNNER_STUDY_ABROAD_REPORT=/path/to/report.txt \
//      xcodebuild test -project TravelLog.xcodeproj -scheme TravelLog \
//        -destination 'platform=iOS Simulator,name=iPhone 17' \
//        -only-testing:TravelLogTests/TemporaryHomeScenarioTests \
//        -parallel-testing-enabled NO
//  The first test starts every variant at once, each on its own store.
//  TEST_RUNNER_STUDY_ABROAD_SERIAL=1 starts a variant only when its own test
//  asks for it.
//
//  What is mirrored by hand, because the production entry point reads the
//  wall clock or needs Foundation Models:
//  - The Temporary Home sheet's Save, End and Remove: the row write the save
//    worker makes (a picked day is the start of that civil day for Since and
//    its last second for Until, in the zone stored on the row), then
//    `applyTemporaryHomeChange` without its title stage: a shape and orbit
//    prime, `applyTemporaryHomeChangeCore` in one gate unit, a full pipeline
//    pass when the unit stamped or freed a stay, then the healing check.
//

import CoreLocation
import EventKit
import Foundation
import SwiftData
import Testing
@testable import TravelLog

// MARK: - Scenario instants

private enum THDates {
    static let zoneID = "Europe/Brussels"
    /// "Since" = the arrival day: 00:00 on day 0 in Brussels.
    static let arrivalDayStart = SAClock.at(0, 0, SAClock.brussels)
    /// "Until" = the departure day: 23:59:59 on day 150 in Brussels.
    static let departureDayEnd = SAClock.at(151, 0, SAClock.brussels).addingTimeInterval(-1)
    /// On landing, just before the first Belgian fix.
    static let landing = SAVariant.arrival
    /// The evening of day 45, at the flat, after Ieper and Bedburg.
    static let day45 = SAVariant.lateDeclaration
    /// The evening of day 70, at the flat, a week after the Athens weekend.
    static let day70 = SAClock.at(70, 20.5, SAClock.brussels)
    /// The evening of day 44, when the open trip is renamed.
    static let renameTime = SAClock.at(44, 21, SAClock.brussels)
    /// An hour after the last pass of the trace.
    static let afterTheRun = SAClock.at(SATrace.lastDay + 1, 13, SAClock.utc)
}

// MARK: - Tables

private struct THTripRow: Sendable {
    let id: UUID
    let startDay: Double
    let endDay: Double?
    let days: Int?
    let isComplete: Bool
    let summary: String
    let countries: String
    let stayIDs: Set<UUID>
    let categories: [UUID: String]
    let userEdited: Bool
    let customName: String?
    let source: String
    /// The name an earlier table gave the trip whose id this one carries.
    let mark: String?
    /// The first stay that starts at or after the trip's end: "home in Brussels centre".
    let followedBy: String
    /// The largest stored distance from home among the trip's stays.
    let farthestKm: Double

    /// "d0→d60" or "d0→open": whole scenario days, UTC.
    var span: String {
        let end = endDay.map { "d\(Int($0.rounded(.down)))" } ?? "open"
        return "d\(Int(startDay.rounded(.down)))→\(end)"
    }
}

private struct THTable: Sendable {
    let title: String
    let text: String
    let trips: [THTripRow]
    /// Stays inside the Brussels urban centre that start inside the temporary home's dates.
    let baseStays: Int
    /// Those of them that are home-class and in no trip.
    let baseStaysHomeAndTripless: Int
    /// Home-class stays inside the Brussels urban centre, whatever their date.
    let brusselsHomeStays: Int
    let homeStaysByOwner: [String: Int]
    let homeStaysInTrips: Int
    let triplessDestinations: Int
    let unclassified: Int
    let learnedDiscs: Int
    let parkedTrips: Int
    let healMoved: Int
    let travelDays: [Int: Int]
    let travelling: Set<Date>
    let staying: Set<Date>
    let away: Set<Date>
    /// One line per stay, "d18.369 destination d18→d18": when it starts, its
    /// category and its trip. Stay ids differ between runs; start times do not.
    let stayStates: Set<String>

    var spans: [String] { trips.map(\.span) }
    /// The stays whose state differs from `other`, both versions, in time order.
    func differences(from other: THTable) -> [String] {
        stayStates.symmetricDifference(other.stayStates).sorted()
    }
    func trip(_ span: String) -> THTripRow? { trips.first { $0.span == span } }
    func count(_ labels: Set<Date>, _ year: Int) -> Int { TravelDays.count(labels, inYear: year) }
}

private struct THResult: Sendable {
    var tables: [THTable] = []
    var outcomes: [TripClassifier.TemporaryHomeReconciliationOutcome] = []
    /// T1: Passport's and Siri's days away, read at the closing table's instant.
    var passportDaysAway: Int?
    var passportDaysAtTemporaryHomes: Int?
    var siriDaysAway: Int?
    var siriDaysAway2027: Int?
    var siriDaysAway2028: Int?

    func table(_ title: String) -> THTable? { tables.first { $0.title == title } }
}

// MARK: - One run

@MainActor
private final class THRun {
    let harness: SAHarness
    var result = THResult()
    /// Trip ids worth following across a rebuild, by a readable name.
    var marks: [UUID: String] = [:]
    private var notesShown = 0

    init(_ harness: SAHarness) { self.harness = harness }

    private enum Region: String, CaseIterable {
        case athens = "Athens centre"
        case brussels = "Brussels centre"
        case elsewhere = "elsewhere"
    }

    private func region(_ stay: Stay) -> Region {
        if harness.athensShape.contains(
            latitude: stay.centroidLatitude, longitude: stay.centroidLongitude) { return .athens }
        if harness.brusselsShape.contains(
            latitude: stay.centroidLatitude, longitude: stay.centroidLongitude) { return .brussels }
        return .elsewhere
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.padding(toLength: max(width, text.count + 1), withPad: " ", startingAt: 0)
    }

    // MARK: User actions

    /// The reconciliation Settings starts after a temporary-home save.
    /// `favorites` are the trips the user has favorited by then.
    private func reconcile(_ id: UUID, _ what: String, favorites: Set<UUID> = []) async {
        let classifier = harness.classifier
        let gate = harness.gate
        _ = await classifier.homeAreaFingerprint()
        let outcome = await gate.runReturning(
            touching: [.temporaryHome, .stay, .trip, .homeAreaOverride]
        ) {
            await classifier.applyTemporaryHomeChangeCore(
                temporaryHomeID: id, pinnedTripIDs: favorites)
        }
        var followUp = "no follow-up pass"
        if case .committed(let stamped, let freed, _, _) = outcome, stamped + freed > 0 {
            let committed = await classifier.classifyAndAssembleTripsQueuedWithGates(
                maxStaysPerCall: nil, gate: gate)
            followUp = "follow-up pass committed: \(committed)"
        }
        result.outcomes.append(outcome)
        harness.note("\(what); reconciliation \(outcome), \(followUp)")
        // Settings heals right after the reconciliation settles.
        await harness.heal()
    }

    /// The sheet's Save for a new temporary home at the Brussels flat.
    @discardableResult
    func declare(since: Date, until: Date?, at time: Date) async throws -> UUID {
        // The app is open: its activation pass runs first.
        await harness.pass(at: time)
        let place = SAPlaces.bruFlat
        let resolved = await GeocodeResolver.shared.resolve(
            latitude: place.lat, longitude: place.lon)
        let context = ModelContext(harness.container)
        let row = TemporaryHome(label: "Brussels", latitude: place.lat, longitude: place.lon,
                                startedAt: since, endedAt: until)
        row.locality = resolved?.localityForStorage
        row.administrativeArea = resolved?.administrativeArea
        row.country = resolved?.country
        row.isoCountryCode = resolved?.isoCountryCode
        row.timeZoneIdentifier = THDates.zoneID
        row.createdAt = time
        row.modifiedAt = time
        context.insert(row)
        try context.save()
        let id = row.id
        await reconcile(id, "declared temporary home \"Brussels\" since \(SAClock.stamp(since)) "
                        + "until \(SAClock.stamp(until))")
        return id
    }

    /// The sheet's Save after changing "Until".
    func setEnd(_ id: UUID, to end: Date?, at time: Date) async throws {
        await harness.pass(at: time)
        let context = ModelContext(harness.container)
        let rows = try context.fetch(FetchDescriptor<TemporaryHome>()).filter { $0.id == id }
        guard !rows.isEmpty else { throw SAError("the temporary home to edit is missing") }
        for row in rows {
            row.endedAt = end
            row.modifiedAt = time
        }
        try context.save()
        await reconcile(id, "set the temporary home's end to \(SAClock.stamp(end))")
    }

    /// "Remove Temporary Home": every row with the id carries the removal; the
    /// reconciliation withdraws the corrections keyed to it.
    func remove(_ id: UUID, at time: Date, favorites: Set<UUID> = []) async throws {
        await harness.pass(at: time)
        let context = ModelContext(harness.container)
        let rows = try context.fetch(FetchDescriptor<TemporaryHome>()).filter { $0.id == id }
        guard !rows.isEmpty else { throw SAError("the temporary home to remove is missing") }
        for row in rows {
            row.removedAt = time
            row.modifiedAt = time
        }
        try context.save()
        await reconcile(id, "removed the temporary home", favorites: favorites)
    }

    /// The id of the trip `mark` named.
    func marked(_ name: String) throws -> UUID {
        guard let id = marks.first(where: { $0.value == name })?.key else {
            throw SAError("no trip was marked \(name)")
        }
        return id
    }

    /// Name the trips that exist now, so later tables can show where their ids went.
    func mark(_ names: [String: String]) throws {
        let trips = try ModelContext(harness.container).fetch(FetchDescriptor<Trip>())
        for trip in trips {
            let end = trip.endDate.map { "d\(Int(SAClock.dayNumber($0).rounded(.down)))" } ?? "open"
            let span = "d\(Int(SAClock.dayNumber(trip.startDate).rounded(.down)))→\(end)"
            if let name = names[span] { marks[trip.id] = name }
        }
    }

    // MARK: Reading the store

    @discardableResult
    func table(_ title: String, closing: Bool = false) async throws -> THTable {
        let now = harness.now
        let context = ModelContext(harness.container)
        let trips = try context.fetch(FetchDescriptor<Trip>()).sorted { $0.startDate < $1.startDate }
        let stays = try context.fetch(FetchDescriptor<Stay>(sortBy: [SortDescriptor(\.startTime)]))
        let homes = try context.fetch(FetchDescriptor<Home>()).sorted { $0.startedAt < $1.startedAt }
        let temporaryHomes = HomeAnchors.collapsingTwins(
            try context.fetch(FetchDescriptor<TemporaryHome>()))
        let anchors = try HomeAnchors.fetch(in: context)

        var lines: [String] = []
        lines.append("")
        lines.append("=== \(title) ===")
        lines.append("at      \(SAClock.stamp(now))")
        for home in homes {
            lines.append("home    \(home.label): startedAt \(SAClock.stamp(home.startedAt)), "
                         + "endedAt \(SAClock.stamp(home.endedAt))")
        }
        for home in temporaryHomes {
            lines.append("temp    \(home.label): startedAt \(SAClock.stamp(home.startedAt)), "
                         + "endedAt \(SAClock.stamp(home.endedAt))")
        }

        lines.append("trips   \(trips.count)")
        var rows: [THTripRow] = []
        for (index, trip) in trips.enumerated() {
            let members = trip.stays ?? []
            let destinations = members.filter { $0.category == .destination }.count
            let transits = members.filter { $0.category == .transit }.count
            let days = trip.durationDays.map { "\($0)d" } ?? "-"
            let name = trip.customName.map { ", customName \"\($0)\"" } ?? ""
            let source = trip.sourceRaw == DataSource.liveSLC.rawValue ? "" : ", source \(trip.sourceRaw)"
            let memberIDs = Set(members.map(\.id))
            let lastEnd = members.map(\.endTime).max() ?? trip.startDate
            let next = stays.first { $0.startTime >= lastEnd && !memberIDs.contains($0.id) }
            let followedBy = next.map { "\($0.category.rawValue) in \(region($0).rawValue)" } ?? "nothing"
            let mark = marks[trip.id]
            let farthestKm = members.map(\.distanceFromHomeKm).max() ?? 0
            lines.append(String(
                format: "  %2ld  %@ -> %@  %@  %@  stays %ld (%ld dest, %ld transit)  [%@]  userEdited=%@  \"%@\"%@%@  up to %.0f km from home  then: %@%@",
                index + 1, SAClock.stamp(trip.startDate), SAClock.stamp(trip.endDate), days,
                trip.isComplete ? "complete" : "open", members.count, destinations, transits,
                trip.countryCodes, trip.userEdited ? "yes" : "no", trip.destinationSummary,
                name, source, farthestKm, followedBy, mark.map { "  id of \"\($0)\"" } ?? ""))
            rows.append(THTripRow(
                id: trip.id, startDay: SAClock.dayNumber(trip.startDate),
                endDay: trip.endDate.map(SAClock.dayNumber), days: trip.durationDays,
                isComplete: trip.isComplete, summary: trip.destinationSummary,
                countries: trip.countryCodes, stayIDs: memberIDs,
                categories: Dictionary(members.map { ($0.id, $0.categoryRaw) },
                                       uniquingKeysWith: { first, _ in first }),
                userEdited: trip.userEdited, customName: trip.customName,
                source: trip.sourceRaw, mark: mark, followedBy: followedBy,
                farthestKm: farthestKm))
        }
        let lostMarks = marks.filter { entry in !trips.contains { $0.id == entry.key } }
            .values.sorted()
        if !lostMarks.isEmpty {
            lines.append("        ids no trip carries any more: "
                         + lostMarks.map { "\"\($0)\"" }.joined(separator: ", "))
        }

        // Stays by where they are and what state they are in.
        let columns = ["home", "routine", "dest in trip", "dest tripless", "transit in trip",
                       "transit tripless", "unclassified"]
        var matrix: [Region: [Int]] = [:]
        for stay in stays {
            let column: Int
            switch stay.category {
            case .home: column = 0
            case .routine: column = 1
            case .destination: column = stay.trip == nil ? 3 : 2
            case .transit: column = stay.trip == nil ? 5 : 4
            case .unclassified: column = 6
            }
            matrix[region(stay), default: Array(repeating: 0, count: columns.count)][column] += 1
        }
        lines.append("stays   \(stays.count) total; rows are where the stay is, columns its state")
        lines.append("        " + Self.pad("where", 17) + columns.map { Self.pad($0, 18) }.joined())
        for region in Region.allCases {
            let row = matrix[region] ?? Array(repeating: 0, count: columns.count)
            lines.append("        " + Self.pad(region.rawValue, 17)
                         + row.map { Self.pad(String($0), 18) }.joined())
        }

        // `.home` stays by the owner their home writer recorded (`HomeAnchors.recordedOwner`).
        let temporaryRows = try context.fetch(FetchDescriptor<TemporaryHome>())
        let knownIDs = Set(temporaryRows.map(\.id))
        var owners: [String: Int] = [:]
        for stay in stays where stay.category == .home {
            let label = switch HomeAnchors.recordedOwner(
                temporaryHomeID: stay.temporaryHomeID, knownTemporaryHomeIDs: knownIDs) {
            case .realHome: "real Home"
            case .temporary(let id):
                "\(temporaryRows.first { $0.id == id }?.label ?? "?") (temporary)"
            case .unresolved: "unresolved"
            }
            owners[label, default: 0] += 1
        }
        lines.append(".home stays by owner: "
                     + (owners.isEmpty ? "none" : owners.sorted { $0.key < $1.key }
                        .map { "\($0.key) \($0.value)" }.joined(separator: ", ")))

        // The base: stays in the Brussels urban centre, inside and outside the dates.
        let brussels = stays.filter { region($0) == .brussels }
        let inDates = brussels.filter { stay in
            temporaryHomes.contains { HomeAnchor($0).covers(stay.startTime) }
        }
        let inDatesHome = inDates.filter { $0.category == .home && $0.trip == nil }
        let outside = brussels.count - inDates.count
        let outsideHome = brussels.filter { stay in
            stay.category == .home
                && !temporaryHomes.contains { HomeAnchor($0).covers(stay.startTime) }
        }.count
        lines.append("base    Brussels-centre stays that start inside the temporary home's dates: "
                     + "\(inDates.count), of them home and tripless \(inDatesHome.count); "
                     + "outside its dates: \(outside), of them home \(outsideHome)")

        let tripless = stays.filter { $0.trip == nil }
        let triplessDestinations = tripless.filter { $0.category == .destination }.count
        let unclassified = stays.filter { $0.category == .unclassified }.count
        lines.append("tripless: destination \(triplessDestinations), "
                     + "transit \(tripless.filter { $0.category == .transit }.count), "
                     + "unclassified \(tripless.filter { $0.category == .unclassified }.count)")
        let homeStaysInTrips = stays.filter { $0.category == .home && $0.trip != nil }.count

        let suppressed = await harness.classifier.suppressedGroups()
        lines.append("near-home activity (gate-suppressed groups): \(suppressed.count)"
                     + (suppressed.isEmpty ? "" : "  " + suppressed.map {
                         String(format: "d%.1f %@ %.1fh", SAClock.dayNumber($0.start),
                                $0.placeName ?? "?", $0.dwellHours)
                     }.joined(separator: "; ")))
        let learned = await harness.classifier.learnedPlaces()
        lines.append("learned orbit discs: \(learned.count)"
                     + (learned.isEmpty ? "" : "  " + learned.map { place in
                         let owner = anchors.first { $0.id == place.homeID }?.label ?? "?"
                         return String(format: "%@: %.3f,%.3f r %.1f km, %ld returns, first %@",
                                       owner, place.latitude, place.longitude, place.radiusKm,
                                       place.returnCount, SAClock.stamp(place.firstReturn))
                     }.joined(separator: "; ")))
        let parked = harness.parked.all.sorted { $0.startDate < $1.startDate }
        lines.append("trips parked for restore (healing or reconciliation): \(parked.count)"
                     + (parked.isEmpty ? "" : "  " + parked.map {
                         "\"\($0.displayName)\" \(SAClock.stamp($0.startDate))"
                     }.joined(separator: "; ")))

        // Trip days, and the away ledger Passport, Siri and Wrapped read.
        let travelling = try TravelDays.labels(
            container: harness.container, now: now, fallbackZone: SAClock.utc)
        let ledger = try TemporaryHomeLedger.result(
            travelling: travelling, container: harness.container, now: now,
            fallbackZone: SAClock.utc, checkCancellation: {})
        var travelDays: [Int: Int] = [:]
        for year in [2026, 2027, 2028] { travelDays[year] = TravelDays.count(travelling, inYear: year) }
        func perYear(_ labels: Set<Date>) -> String {
            [2026, 2027, 2028].map { "\($0) = \(TravelDays.count(labels, inYear: $0))" }
                .joined(separator: ", ")
        }
        lines.append("TravelDays labels (trips only): \(perYear(travelling)) (counted as of the 'at' line)")
        lines.append("ledger  away: \(perYear(ledger.away)); staying: \(perYear(ledger.staying)); "
                     + "travelling: \(perYear(ledger.travelling))")
        for home in temporaryHomes {
            let spans = ledger.spansByHome[home.id] ?? []
            lines.append("        staying spans of \(home.label): "
                         + (spans.isEmpty ? "none" : spans.map {
                             "\(SAClock.stamp($0.start)) -> \(SAClock.stamp($0.end))"
                         }.joined(separator: "; ")))
        }

        if closing {
            lines.append("seeds   Athens: \(Self.describe(harness.athensShape)); "
                         + "Brussels: \(Self.describe(harness.brusselsShape))")
            lines.append("trace   \(harness.fixes.count) live fixes")
        }
        lines.append("run     \(harness.passCount) pipeline passes, \(harness.healChecks) healing checks "
                     + "(\(harness.healRuns) found the home area changed and ran, "
                     + "moving \(harness.healMoved) trips or stays)")
        // A checkpoint lists what happened since the previous table; the
        // closing table lists everything.
        let notes = harness.notes
        let shown = closing ? notes[...] : notes[notesShown...]
        notesShown = notes.count
        if !shown.isEmpty {
            lines.append(closing ? "events (whole run)" : "events since the previous table")
            lines.append(contentsOf: shown.map { "  " + $0 })
        }

        var spanByTrip: [UUID: String] = [:]
        for row in rows { for id in row.stayIDs { spanByTrip[id] = row.span } }
        let stayStates = Set(stays.map {
            String(format: "d%07.3f %@ %@", SAClock.dayNumber($0.startTime), $0.category.rawValue,
                   spanByTrip[$0.id] ?? "-")
        })
        let table = THTable(
            title: title, text: lines.joined(separator: "\n"), trips: rows,
            baseStays: inDates.count, baseStaysHomeAndTripless: inDatesHome.count,
            brusselsHomeStays: brussels.filter { $0.category == .home }.count,
            homeStaysByOwner: owners, homeStaysInTrips: homeStaysInTrips,
            triplessDestinations: triplessDestinations, unclassified: unclassified,
            learnedDiscs: learned.count, parkedTrips: parked.count,
            healMoved: harness.healMoved, travelDays: travelDays,
            travelling: ledger.travelling, staying: ledger.staying, away: ledger.away,
            stayStates: stayStates)
        result.tables.append(table)
        return table
    }

    private static func describe(_ shape: HomeShape) -> String {
        switch shape.seed {
        case .urbanCentre(let id, let name):
            return String(format: "urban centre \"%@\" #%lld, %.0f km2, D* %.1f km",
                          name ?? "unnamed", id, shape.areaKm2, shape.areaEquivalentRadiusKm)
        case .fallbackDisc:
            return "fallback 1 km disc"
        }
    }

    /// Passport's days away (the Stats page reduction) and Siri's lifetime and
    /// per-year answers, at the harness's now.
    func readPassport() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = SAClock.utc
        let now = harness.now
        let aggregates = try StatsAggregator.compute(
            container: harness.container, now: now, calendar: calendar, checkCancellation: {})
        result.passportDaysAway = aggregates.passportData.daysAbroad
        result.passportDaysAtTemporaryHomes = aggregates.passportData.daysAtTemporaryHomes
        result.siriDaysAway = try StatsAggregator.passportSummary(
            container: harness.container, now: now, calendar: calendar).daysAbroad
        result.siriDaysAway2027 = try StatsAggregator.yearSummary(
            container: harness.container, year: 2027, calendar: calendar, now: now).daysAbroad
        result.siriDaysAway2028 = try StatsAggregator.yearSummary(
            container: harness.container, year: 2028, calendar: calendar, now: now).daysAbroad
        harness.note("Passport days away \(result.passportDaysAway ?? -1), "
                     + "days at temporary homes \(result.passportDaysAtTemporaryHomes ?? 0); "
                     + "Siri lifetime days away \(result.siriDaysAway ?? -1), "
                     + "2027: \(result.siriDaysAway2027 ?? -1), 2028: \(result.siriDaysAway2028 ?? -1)")
    }
}

// MARK: - Variants

private enum THVariant: String, CaseIterable, Sendable {
    case t1, t2, t3, t4, t5, t6, t7, t8b, t8c, t9

    var title: String {
        switch self {
        case .t1: "T1 temporary home declared on landing, since the arrival day, until the departure day"
        case .t2: "T2 temporary home declared late on day 45, since the arrival day"
        case .t3: "T3 temporary home declared on day 70, after the Athens weekend, since the arrival day"
        case .t4: "T4 prehistory: a photo-imported 2026 Brussels holiday, then T1"
        case .t5: "T5 no end set, then the end set retroactively to the departure day"
        case .t6: "T6 as T1, then Ieper is favorited and the temporary home is removed at the end of the run"
        case .t7: "T7 the open big trip is renamed on day 44, then the late declaration of T2"
        case .t8b: "T8 as T1 with four same-day returns from Wevelgem, 5 h each (the harness V7b trace)"
        case .t8c: "T8 as T1 with four Wevelgem day trips that leave a sparse fix on the way both legs (the harness V7c trace)"
        case .t9: "T9 as T1 with a sparse Athens weekend (one live fix, no visit)"
        }
    }

    var options: SATrace.Options {
        switch self {
        case .t8b: SAVariant.v7b.options
        case .t8c: SAVariant.v7c.options
        case .t9: SAVariant.v5b.options
        default: .init()
        }
    }

    @MainActor
    func run(_ run: THRun) async throws {
        let harness = run.harness
        let since = THDates.arrivalDayStart
        let until = THDates.departureDayEnd
        switch self {
        case .t1, .t9:
            await harness.advance(to: THDates.landing)
            try await run.declare(since: since, until: until, at: THDates.landing)

        case .t2:
            await harness.advance(to: THDates.day45)
            await harness.pass(at: THDates.day45)
            try run.mark(["d0→open": "the big trip"])
            try await run.table("T2 checkpoint: day 45, before the declaration")
            try await run.declare(since: since, until: until, at: THDates.day45)
            try await run.table("T2 checkpoint: day 45, right after the declaration")

        case .t3:
            await harness.advance(to: THDates.day70)
            await harness.pass(at: THDates.day70)
            try run.mark(["d0→d60": "the first blob", "d63→open": "the second blob"])
            try await run.table("T3 checkpoint: day 70, before the declaration")
            try await run.declare(since: since, until: until, at: THDates.day70)
            try await run.table("T3 checkpoint: day 70, right after the declaration")

        case .t4:
            try await harness.importPhotos(SATrace.importedHoliday())
            await harness.heal()
            try run.mark(["d-521→d-518": "the 2026 holiday"])
            try await run.table("T4 checkpoint: after the photo import, before any live fix")
            await harness.advance(to: THDates.landing)
            await harness.pass(at: THDates.landing)
            try await run.table("T4 checkpoint: day 0 on landing, before the declaration")
            try await run.declare(since: since, until: until, at: THDates.landing)
            try await run.table("T4 checkpoint: day 0, after the declaration and its healing check")

        case .t5:
            await harness.advance(to: THDates.landing)
            let id = try await run.declare(since: since, until: nil, at: THDates.landing)
            await harness.finish()
            try await run.table("T5 checkpoint: end of the run, no end set")
            try await run.setEnd(id, to: until, at: THDates.afterTheRun)
            try await run.table(title, closing: true)
            return

        case .t6:
            await harness.advance(to: THDates.landing)
            let id = try await run.declare(since: since, until: until, at: THDates.landing)
            await harness.finish()
            try run.mark(["d18→d18": "Ieper", "d39→d41": "Bedburg", "d100→d105": "Amsterdam",
                          "d232→d236": "the holiday"])
            try await run.table("T6 checkpoint: end of the run, before the removal")
            // The Ieper day trip is a favorite by the time the user removes it.
            try await run.remove(id, at: THDates.afterTheRun, favorites: [run.marked("Ieper")])
            try await run.table(title, closing: true)
            return

        case .t7:
            await harness.advance(to: THDates.renameTime)
            try await harness.renameOpenTrip("Erasmus", at: THDates.renameTime)
            try run.mark(["d0→open": "Erasmus"])
            await harness.advance(to: THDates.day45)
            try await run.declare(since: since, until: until, at: THDates.day45)
            try await run.table("T7 checkpoint: day 45, right after the declaration")

        case .t8b, .t8c:
            await harness.advance(to: THDates.landing)
            try await run.declare(since: since, until: until, at: THDates.landing)
            let name = self == .t8b ? "T8 (V7b trace)" : "T8 (V7c trace)"
            for (index, day) in SATrace.dayTripDays.enumerated() {
                await harness.advance(to: SAClock.at(day + 1, 12.5, SAClock.utc))
                try await run.table(
                    "\(name) checkpoint: midday after visit \(index + 1) (day \(day + 1)), healing check done")
            }
        }
        await harness.finish()
        if self == .t1 { try run.readPassport() }
        try await run.table(title, closing: true)
    }
}

/// Runs each variant once per process, all at once unless the serial switch is set.
@MainActor
private enum THRuns {
    private static var tasks: [THVariant: Task<THResult, Error>] = [:]

    private static var startsAllAtOnce: Bool {
        let environment = ProcessInfo.processInfo.environment
        return (environment["STUDY_ABROAD_SERIAL"] ?? environment["TEST_RUNNER_STUDY_ABROAD_SERIAL"]
                ?? "").isEmpty
    }

    static func result(for variant: THVariant) async throws -> THResult {
        let wanted = startsAllAtOnce ? THVariant.allCases : [variant]
        for each in wanted where tasks[each] == nil {
            tasks[each] = Task { try await execute(each) }
        }
        guard let task = tasks[variant] else { throw SAError("no run for \(variant)") }
        return try await task.value
    }

    private static func execute(_ variant: THVariant) async throws -> THResult {
        let titleSuite = "TemporaryHomeScenarioTitles-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: titleSuite) }
        // Foundation Models pinned off, title-failure bookkeeping in a
        // throwaway suite, no calendar access: the pipeline's own decisions only.
        return try await StayClassificationInference.TestHook.$availability.withValue(false) {
            try await TripClassifier.$failureDefaultsSuiteNameForTesting.withValue(titleSuite) {
                try await CalendarEnricher.TestScope.$authorizationStatus.withValue(.notDetermined) {
                    let harness = try await SAHarness.make(variant.options)
                    defer { harness.tearDown() }
                    let run = THRun(harness)
                    try await variant.run(run)
                    return run.result
                }
            }
        }
    }
}

// MARK: - Tests

@MainActor
@Suite("Temporary home scenarios (acceptance)", .serialized)
struct TemporaryHomeScenarioTests {

    /// Print every table of the variant and hand back the closing one.
    private func report(_ variant: THVariant) async throws -> (result: THResult, closing: THTable) {
        let result = try await THRuns.result(for: variant)
        for table in result.tables { SAReport.emit(table.text) }
        return (result, try #require(result.tables.last))
    }

    // Spans are whole scenario days in UTC ("d18→d18"); day 0 is the flight out.

    /// Ieper (day 18), Bedburg (days 39 to 41), Amsterdam (days 100 to 105).
    private static let excursions = ["d18→d18", "d39→d41", "d100→d105"]
    /// The Brussels holiday 82 days after the semester.
    private static let holiday = "d232→d236"

    /// What T1 promises and T2, T3, T5 and T9 must also end with.
    private func expectSemester(_ table: THTable, sourceLocation: SourceLocation = #_sourceLocation) {
        // Exactly three trips during the semester, then the later holiday.
        #expect(table.spans == Self.excursions + [Self.holiday], sourceLocation: sourceLocation)
        #expect(table.trips.map(\.days) == [1, 3, 6, 5], sourceLocation: sourceLocation)
        #expect(table.trips.allSatisfy { $0.isComplete }, sourceLocation: sourceLocation)
        // Each excursion closes on the return to Brussels; the holiday on the return to Athens.
        #expect(table.trips.map(\.followedBy) == [
            "home in Brussels centre", "home in Brussels centre", "home in Brussels centre",
            "home in Athens centre",
        ], sourceLocation: sourceLocation)
        // Every stay at the base inside the dates is home-class and tripless.
        #expect(table.baseStays > 500, sourceLocation: sourceLocation)
        #expect(table.baseStaysHomeAndTripless == table.baseStays, sourceLocation: sourceLocation)
        #expect(table.homeStaysInTrips == 0, sourceLocation: sourceLocation)
        #expect(table.triplessDestinations == 0, sourceLocation: sourceLocation)
        #expect(table.unclassified == 0, sourceLocation: sourceLocation)
        // Trip days: 1 + 3 + 6 in 2027, the holiday's 5 in 2028.
        #expect(table.travelDays == [2026: 0, 2027: 10, 2028: 5], sourceLocation: sourceLocation)
        // The excursions are measured from Brussels, the holiday from Athens.
        #expect(table.trips.map { $0.farthestKm < 250 } == [true, true, true, false],
                sourceLocation: sourceLocation)
        #expect((table.trips.last?.farthestKm ?? 0) > 2_000, sourceLocation: sourceLocation)
    }

    @Test("T1 declared on landing with the end on the departure day: Ieper, Bedburg and Amsterdam are the only trips of the semester, each closing on the return to Brussels; no flight day, Athens weekend or last morning is a trip; the later Brussels holiday is one",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func t1DeclaredOnLanding() async throws {
        let run = try await report(.t1)
        expectSemester(run.closing)
        // Nothing to rebuild on landing: the base has no stay yet.
        #expect(run.result.outcomes == [.committed(stamped: 0, freed: 0, rebuiltTrips: 0, protectedTrips: 0)])
        // No trip for the flight out (day 0), the Athens weekend (days 60 to
        // 63) or the flight home and the last morning (day 150).
        for day in [0, 60, 61, 62, 63, 150] {
            #expect(!run.closing.trips.contains { Int($0.startDay.rounded(.down)) == day },
                    "no trip may start on day \(day)")
        }
        #expect(run.closing.trips.map(\.summary).first == "Ieper")
        #expect(run.closing.trips.last?.countries == "BE")
        #expect(run.closing.learnedDiscs == 0)
        #expect(run.closing.parkedTrips == 0)
        #expect(run.closing.healMoved == 0)
    }

    @Test("T2 declared late on day 45 since the arrival day: the big open trip is gone, Ieper and Bedburg are separate completed trips, one of them keeps the big trip's id, and the rest of the semester is as T1",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func t2LateDeclaration() async throws {
        let run = try await report(.t2)
        let before = try #require(run.result.table("T2 checkpoint: day 45, before the declaration"))
        let after = try #require(run.result.table("T2 checkpoint: day 45, right after the declaration"))
        #expect(before.spans == ["d0→open"])
        let bigID = try #require(before.trips.first?.id)

        #expect(after.spans == ["d18→d18", "d39→d41"])
        #expect(after.trips.allSatisfy { $0.isComplete })
        #expect(after.trips.map(\.days) == [1, 3])
        #expect(after.trips.filter { $0.id == bigID }.count == 1)
        #expect(after.baseStaysHomeAndTripless == after.baseStays)
        #expect(after.baseStays > 100)
        #expect(after.travelDays[2027] == 4)

        // One trip rebuilt, nothing protected, nothing freed.
        if case .committed(let stamped, let freed, let rebuilt, let kept)? = run.result.outcomes.last {
            #expect(stamped == after.baseStays)
            #expect(freed == 0 && rebuilt == 1 && kept == 0)
        } else {
            Issue.record("the reconciliation did not commit: \(run.result.outcomes)")
        }

        expectSemester(run.closing)
        #expect(run.closing.trips.filter { $0.id == bigID }.count == 1)
        #expect(run.closing.parkedTrips == 0)
        #expect(run.closing.healMoved == 0)
    }

    @Test("T3 declared on day 70 since the arrival day: the completed first blob and the open second one are both rebuilt, and the semester ends as T1",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func t3DeclaredAfterTheAthensWeekend() async throws {
        let run = try await report(.t3)
        let before = try #require(run.result.table("T3 checkpoint: day 70, before the declaration"))
        let after = try #require(run.result.table("T3 checkpoint: day 70, right after the declaration"))
        #expect(before.spans == ["d0→d60", "d63→open"])
        let firstBlobID = try #require(before.trips.first?.id)

        #expect(after.spans == ["d18→d18", "d39→d41"])
        #expect(after.trips.allSatisfy { $0.isComplete })
        #expect(after.baseStaysHomeAndTripless == after.baseStays)
        // The completed blob's id lives on in one of its side trips.
        #expect(after.trips.filter { $0.id == firstBlobID }.count == 1)
        // Both trips rebuilt in the one unit; neither needed parking.
        if case .committed(let stamped, let freed, let rebuilt, let kept)? = run.result.outcomes.last {
            #expect(stamped == after.baseStays)
            #expect(freed == 0 && rebuilt == 2 && kept == 0)
        } else {
            Issue.record("the reconciliation did not commit: \(run.result.outcomes)")
        }
        #expect(after.parkedTrips == 0)

        expectSemester(run.closing)
        #expect(run.closing.healMoved == 0)
    }

    @Test("T4 prehistory: an imported 2026 Brussels holiday is still a trip with its four travel days after the declaration and after every healing check of the run",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func t4ImportedPrehistory() async throws {
        let run = try await report(.t4)
        try #require(run.result.tables.count == 4)
        let imported = run.result.tables[0]
        let holidayID = try #require(imported.trips.first?.id)
        #expect(imported.trips.count == 1)
        #expect(imported.travelDays[2026] == 4)
        for table in run.result.tables {
            let holiday = try #require(table.trips.first, "\(table.title)")
            #expect(holiday.id == holidayID, "\(table.title)")
            #expect(holiday.isComplete, "\(table.title)")
            #expect(holiday.stayIDs == imported.trips.first?.stayIDs, "\(table.title)")
            #expect(table.travelDays[2026] == 4, "\(table.title)")
            #expect(table.parkedTrips == 0, "\(table.title)")
            // No healing check moved anything up to this table.
            #expect(table.healMoved == 0, "\(table.title)")
        }
        #expect(run.closing.spans.dropFirst() == (Self.excursions + [Self.holiday])[...])
    }

    @Test("T5 forgotten end: with no end the later Brussels holiday is not a trip; setting the end retroactively to the departure day makes it one",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func t5ForgottenEndThenFixed() async throws {
        let run = try await report(.t5)
        let forgotten = try #require(run.result.table("T5 checkpoint: end of the run, no end set"))
        #expect(forgotten.spans == Self.excursions)
        #expect(forgotten.travelDays == [2026: 0, 2027: 10, 2028: 0])
        // Without an end the holiday's 14 stays in Brussels are home stays.
        #expect(forgotten.baseStays == forgotten.baseStaysHomeAndTripless)
        // The edit frees exactly those 14 and rebuilds nothing.
        #expect(run.result.outcomes.last
                == .committed(stamped: 0, freed: 14, rebuiltTrips: 0, protectedTrips: 0))
        expectSemester(run.closing)
        // The three excursions keep their ids through the edit.
        #expect(run.closing.trips.prefix(3).map(\.id) == forgotten.trips.map(\.id))
        // Days away were right all along: the holiday counted as days at the
        // temporary home before the edit and as trip days after it.
        #expect(forgotten.away == run.closing.away)
        #expect(forgotten.count(forgotten.staying, 2028) == 11)
        #expect(run.closing.count(run.closing.staying, 2028) == 6)
        // Every stay ends in the state the declaration with an end gives it.
        let landing = try #require(try await THRuns.result(for: .t1).tables.last)
        #expect(run.closing.differences(from: landing) == [])
    }

    @Test("T6 removal at the end of the run with the Ieper day trip favorited: no stay at the base is home-class any more, the semester is rebuilt as the trips an undeclared semester has, and the favorite stays its own trip with its id, stays and categories",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func t6Removal() async throws {
        let run = try await report(.t6)
        let before = try #require(run.result.table("T6 checkpoint: end of the run, before the removal"))
        expectSemester(before)
        let after = run.closing
        // The removal frees every stay the temporary home owned and keeps the favorite.
        #expect(run.result.outcomes.last == .committed(
            stamped: 0, freed: before.baseStays, rebuiltTrips: 0, protectedTrips: 1))
        #expect(after.brusselsHomeStays == 0)
        #expect(after.unclassified == 0)
        #expect(after.homeStaysInTrips == 0)
        #expect(after.triplessDestinations == 0)
        // What the harness's V0 (nothing declared) shows, around the kept favorite.
        #expect(after.spans == ["d0→d60", "d18→d18", "d63→d150", Self.holiday])
        #expect(after.trips.allSatisfy { $0.isComplete })
        #expect(after.travelDays == [2026: 0, 2027: 143, 2028: 11])
        // The favorite is the trip it was, now the user's own.
        let favorite = try #require(before.trip("d18→d18"))
        let kept = try #require(after.trip("d18→d18"))
        #expect(kept.id == favorite.id)
        #expect(kept.stayIDs == favorite.stayIDs)
        #expect(kept.categories == favorite.categories)
        #expect(kept.summary == favorite.summary)
        #expect(!favorite.userEdited)
        #expect(kept.userEdited)
        // The holiday was never touched. Each blob takes the id of the
        // largest excursion it absorbed.
        #expect(after.trip(Self.holiday)?.id == before.trip(Self.holiday)?.id)
        #expect(after.trip("d0→d60")?.id == before.trip("d39→d41")?.id)
        #expect(after.trip("d63→d150")?.id == before.trip("d100→d105")?.id)
    }

    @Test("T7 a renamed open trip, then the late declaration: the trip is archived in Removed Trips and split as T2 splits the trip nobody renamed, so the semester ends as T2's, every stay in the same state",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func t7RenamedOpenTrip() async throws {
        let run = try await report(.t7)
        let late = try await THRuns.result(for: .t2)
        let declared = try #require(run.result.table("T7 checkpoint: day 45, right after the declaration"))
        let lateDeclared = try #require(late.table("T2 checkpoint: day 45, right after the declaration"))
        #expect(declared.spans == ["d18→d18", "d39→d41"])
        #expect(declared.differences(from: lateDeclared) == [])
        #expect(!declared.trips.contains { $0.customName == "Erasmus" })
        // The renamed trip is the one record parked, and the counts are T2's.
        #expect(declared.parkedTrips == 1)
        #expect(declared.text.contains("\"Erasmus\""))
        #expect(run.result.outcomes.last == late.outcomes.last)

        expectSemester(run.closing)
        #expect(run.closing.differences(from: try #require(late.tables.last)) == [])
        #expect(run.closing.parkedTrips == 1)
        #expect(run.closing.healMoved == 0)
    }

    @Test("T8 Wevelgem four times (the harness V7b trace): the four day trips stay four trips, the temporary home learns no disc, and healing dissolves nothing",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func t8WevelgemFourTimes() async throws {
        try await expectFourWevelgemTrips(.t8b)
    }

    @Test("T8 Wevelgem four times with a sparse fix on the way both legs (the harness V7c trace): the four day trips stay four trips, no waypoint or town earns a disc, and healing dissolves nothing",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func t8WevelgemFourTimesSparseWaypoints() async throws {
        try await expectFourWevelgemTrips(.t8c)
    }

    private func expectFourWevelgemTrips(_ variant: THVariant) async throws {
        let run = try await report(variant)
        #expect(run.closing.spans == [
            "d18→d18", "d25→d25", "d39→d41", "d53→d53", "d81→d81", "d100→d105", "d123→d123",
            Self.holiday,
        ])
        #expect(run.closing.trips.allSatisfy { $0.isComplete })
        for day in SATrace.dayTripDays {
            let trip = try #require(run.closing.trip("d\(day)→d\(day)"))
            #expect(trip.days == 1)
            #expect(trip.summary == "Wevelgem")
            #expect(trip.followedBy == "home in Brussels centre")
        }
        for table in run.result.tables {
            #expect(table.learnedDiscs == 0, "\(table.title)")
            #expect(table.parkedTrips == 0, "\(table.title)")
            #expect(table.healMoved == 0, "\(table.title)")
        }
        #expect(run.closing.baseStaysHomeAndTripless == run.closing.baseStays)
    }

    @Test("T9 sparse Athens weekend (a single fix): the same three trips and the holiday",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func t9SparseAthensWeekend() async throws {
        let run = try await report(.t9)
        expectSemester(run.closing)
        // DESIGN section 5: one padded fix at the real home is not a boundary,
        // so the weekend does not cut the staying span and its two home days
        // count as away: 145 for 2027 where T1 has 143.
        #expect(run.closing.count(run.closing.away, 2027) == 145)
        #expect(run.closing.count(run.closing.away, 2028) == 11)
    }

    @Test("T10 the away ledger on T1's end state: days away cover the semester and the holiday, travelling is the trips' own days, the Athens weekend's home days are neither, and Passport and Siri report the ledger's number",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func t10AwayLedger() async throws {
        let result = try await THRuns.result(for: .t1)
        let table = try #require(result.tables.last)
        // Day 0 is 9 August 2027. V0 (nothing declared) counts 143 travel
        // days in 2027 and 11 in 2028: days 0 to 60 (61 labels), days 63
        // to 150 (88 labels: 82 up to 31 December, day 144, and 6 in 2028),
        // and the holiday of days 232 to 236 (5).
        // With the temporary home the same two stretches are staying spans:
        // the first runs from the first stay after the last Athens home stay
        // on day 0 to the last stay before the first Athens home stay on day
        // 60, the second from day 63 to the last stay before the Athens home
        // stay on day 150 (the temporary home ends on that day's last
        // second). Their boundary stays are the same airport and on-the-way
        // stays that bound V0's two blobs, so the labels are the same 61 and
        // 88. The holiday lies after the end, so it is a trip again: 5 trip
        // days. Away is the union: 61 + 82 = 143 in 2027, 6 + 5 = 11 in 2028.
        #expect(SAClock.calendar(SAClock.brussels).component(.year, from: SAClock.at(63, 12, SAClock.brussels))
                != SAClock.calendar(SAClock.brussels).component(.year, from: SAClock.at(150, 12, SAClock.brussels)))
        #expect(table.count(table.away, 2027) == 143)
        #expect(table.count(table.away, 2028) == 11)
        #expect(table.count(table.away, 2026) == 0)
        // Travelling is the trips' own days: 1 + 3 + 6 in 2027, the holiday in 2028.
        #expect(table.count(table.travelling, 2027) == 10)
        #expect(table.count(table.travelling, 2028) == 5)
        #expect(table.travelling.count == table.trips.compactMap(\.days).reduce(0, +))
        // Staying is the rest of the two spans.
        #expect(table.count(table.staying, 2027) == 133)
        #expect(table.count(table.staying, 2028) == 6)
        #expect(table.staying.isDisjoint(with: table.travelling))
        #expect(table.away == table.staying.union(table.travelling))
        // Saturday and Sunday of the Athens weekend (days 61 and 62) are at
        // home: neither away, staying nor travelling. The two flight days are away.
        for day in [61, 62] {
            let label = try #require(TravelDays.label(
                for: SAClock.at(day, 12, SAClock.athens), zone: SAClock.athens))
            #expect(!table.away.contains(label), "day \(day) is a day at home")
        }
        for day in [0, 60, 63, 150] {
            let label = try #require(TravelDays.label(
                for: SAClock.at(day, 12, SAClock.athens), zone: SAClock.athens))
            #expect(table.away.contains(label), "day \(day) is a flight day")
        }
        // Passport (the Stats reduction) and Siri (the projected adapter) agree with the ledger.
        #expect(result.passportDaysAway == table.away.count)
        #expect(result.passportDaysAtTemporaryHomes == table.staying.count)
        #expect(result.siriDaysAway == table.away.count)
        #expect(result.siriDaysAway2027 == 143)
        #expect(result.siriDaysAway2028 == 11)
    }

    // MARK: Late declaration against declaration on landing

    @Test("a late declaration leaves every stay in the state a declaration on landing gives it, the two station fixes of the Ieper day trip included, so that trip reads \"Ieper\" either way",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func lateDeclarationEndsAsDeclarationOnLanding() async throws {
        let landing = try #require(try await THRuns.result(for: .t1).tables.last)
        #expect(landing.trips.first?.summary == "Ieper")
        for variant in [THVariant.t2, .t3] {
            let late = try #require(try await THRuns.result(for: variant).tables.last)
            #expect(late.differences(from: landing) == [], "\(variant)")
            #expect(late.trips.map(\.summary) == landing.trips.map(\.summary), "\(variant)")
        }
    }

    @Test("a renamed trip the late declaration splits leaves the same side trips, with the same place lists, as the same trip nobody renamed",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func renamedTripSplitsLikeAnyOther() async throws {
        let renamed = try #require(try await THRuns.result(for: .t7).tables.last)
        let plain = try #require(try await THRuns.result(for: .t2).tables.last)
        #expect(renamed.trips.map(\.summary) == plain.trips.map(\.summary))
        #expect(renamed.trips.map(\.categories.count) == plain.trips.map(\.categories.count))
    }
}
