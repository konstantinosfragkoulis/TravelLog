//
//  WhereWasIIntent.swift
//  TravelLog
//
//  "Where was I on June 10, 2023?"
//
//  Deliberately NOT built on `OnThisDayEngine`: that matcher answers
//  "this month+day across past years" and hard-excludes the target year.
//  An exact-date question is a plain interval-overlap fetch (the same
//  `startTime < dayEnd && endTime > dayStart` half-open window rule the engine
//  uses internally), which is both simpler and more precise here.
//

import AppIntents
import Foundation
import SwiftData
import SwiftUI

// MARK: - DayVisit

/// One place the user was at during the requested day or range — a Sendable reduction
/// of an overlapping `Stay` (the `TripEntity` discipline).
nonisolated struct DayVisit: Sendable, Equatable {
    /// `metroName ?? islandName ?? locality` — display granularity.
    let place: String?
    /// Country name in the process locale, falling back to the stay's
    /// stored geocoded country string.
    let countryName: String?
    let flag: String?
    let category: StayCategory
    let tripID: UUID?
    let tripName: String?
    /// A home stay whose owner is a temporary home, not a real Home.
    var isTemporaryHome = false
}

// MARK: - WhereWasIFetcher

/// Off-main fetch + reduction (the `StatsAggregator` pattern; container
/// as a parameter for in-memory testability).
nonisolated enum WhereWasIFetcher {

    /// Inclusive calendar dates become one half-open interval. Calendar addition
    /// preserves local midnight across daylight-saving transitions.
    static func dateWindow(from day: Date, through endDay: Date?, calendar: Calendar) -> DateInterval? {
        let start = calendar.startOfDay(for: day)
        let lastDay = calendar.startOfDay(for: endDay ?? day)
        guard lastDay >= start,
              let end = calendar.date(byAdding: .day, value: 1, to: lastDay) else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// Every classified stay overlapping the requested calendar dates,
    /// reduced to deduplicated `DayVisit`s in time order. Overlap rule
    /// mirrors `OnThisDayEngine`: `startTime < dayEnd && endTime > dayStart`
    /// (half-open: a stay ending exactly at 00:00 belongs to
    /// the previous day, not both). Throws on a failed read, which is never
    /// "no location data".
    static func visits(
        on day: Date,
        through endDay: Date? = nil,
        container: ModelContainer,
        calendar: Calendar = .current
    ) throws -> [DayVisit] {
        guard let window = dateWindow(from: day, through: endDay, calendar: calendar) else { return [] }
        let dayStart = window.start
        let dayEnd = window.end
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Stay>(
            predicate: #Predicate { $0.startTime < dayEnd && $0.endTime > dayStart },
            sortBy: [SortDescriptor(\Stay.startTime, order: .forward)]
        )
        try IntentRead.check(.dayStays)
        let stays = try context.fetch(descriptor)
        // Which home a home stay was at: the temporary home its writer
        // recorded (`HomeAnchors.recordedOwner`), never the nearest centre.
        // Every temporary-home id is read, removed ones included, and only
        // when the day has a recorded home stay. A failed read throws: it is
        // not "at the real home". Both are the day's required reads, so they
        // share `.dayStays`.
        let homeRaw = StayCategory.home.rawValue
        var knownTemporaryHomeIDs = Set<UUID>()
        if stays.contains(where: { $0.categoryRaw == homeRaw && $0.temporaryHomeID != nil }) {
            try IntentRead.check(.dayStays)
            var descriptor = FetchDescriptor<TemporaryHome>()
            descriptor.propertiesToFetch = [\.id]
            knownTemporaryHomeIDs = Set(try context.fetch(descriptor).map(\.id))
        }
        let appLocale = AppLanguagePreference.currentLocale()
        let languageTag = AppLanguagePreference.currentTag()

        var seen = Set<[String]>()
        var visits: [DayVisit] = []
        for stay in stays {
            guard let category = StayCategory(rawValue: stay.categoryRaw),
                  category != .unclassified else { continue }
            let place = stay.placeGroupName
            let code = stay.isoCountryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
            let country = code.isEmpty
                ? (stay.country ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                : code
            // Resolved before the dedup: a home stay at the real Home and one
            // at a temporary home in the same city are two answers.
            var isTemporaryHome = false
            if category == .home, case .temporary = HomeAnchors.recordedOwner(
                temporaryHomeID: stay.temporaryHomeID, knownTemporaryHomeIDs: knownTemporaryHomeIDs) {
                isTemporaryHome = true
            }
            let key = [category.rawValue, place ?? "", country, stay.trip?.id.uuidString ?? "",
                       isTemporaryHome ? "temporaryHome" : ""]
            guard seen.insert(key).inserted else { continue }
            visits.append(DayVisit(
                place: place,
                countryName: stay.isoCountryCode.flatMap {
                    appLocale.localizedString(forRegionCode: $0)
                } ?? stay.country,
                flag: stay.isoCountryCode.flatMap { flagEmoji(for: $0) },
                category: category,
                tripID: stay.trip?.id,
                tripName: stay.trip?.displayName(languageTag: languageTag),
                isTemporaryHome: isTemporaryHome
            ))
        }
        return visits
    }

    /// Single-day questions retain their original tier. Ranges include home,
    /// routine and transit visits even when another day has a destination.
    static func answer(
        on day: Date,
        through endDay: Date? = nil,
        container: ModelContainer,
        calendar: Calendar = .current
    ) throws -> [DayVisit] {
        let visits = try visits(on: day, through: endDay, container: container, calendar: calendar)
        return calendar.isDate(day, inSameDayAs: endDay ?? day) ? answerTier(visits) : visits
    }

    nonisolated struct Loaded: Sendable {
        let visits: [DayVisit]
        let trips: [TripEntity]
    }

    /// The intent's whole read: the answer and its parent trips, off-main.
    /// Throws `IntentDataError.unavailable` for a failed read or the
    /// in-memory fallback store, and when a deletion that clears the Stats
    /// snapshot (Delete All Data among them) moved its generation past
    /// `clearGeneration`, captured before the read, while it ran.
    static func load(
        on day: Date,
        through endDay: Date?,
        container: ModelContainer,
        calendar: Calendar,
        isPersistentStore: Bool,
        clearGeneration: Int = StatsSnapshotStore.clearGeneration
    ) async throws -> Loaded {
        let loaded = try await IntentDataError.detachedRead("Where Was I", isPersistentStore: isPersistentStore) { _ in
            let visits = try WhereWasIFetcher.answer(
                on: day, through: endDay, container: container, calendar: calendar)
            // Ordered, deduplicated parent trips so "open it" can chain.
            let trips = try TripEntityFetcher.entities(
                for: WhereWasIFetcher.tripIDs(in: visits), container: container)
            return Loaded(visits: visits, trips: trips)
        }
        try TripIntentSearch.refuseIfRevoked(since: clearGeneration)
        return loaded
    }

    /// Keep first-visit order for the parent-trip entities used by Shortcuts.
    static func tripIDs(in visits: [DayVisit]) -> [UUID] {
        var seen = Set<UUID>()
        return visits.compactMap(\.tripID).filter { seen.insert($0).inserted }
    }

    /// Pick the tier that best answers "where was I": actual destinations
    /// beat being home/at a routine place, which beats a transit-only day
    /// (a day spent flying still has an honest answer: the layover).
    static func answerTier(_ visits: [DayVisit]) -> [DayVisit] {
        let destinations = visits.filter { $0.category == .destination }
        if !destinations.isEmpty { return destinations }
        let home = visits.filter { $0.category == .home || $0.category == .routine }
        if !home.isEmpty { return home }
        return visits.filter { $0.category == .transit }
    }

    /// Spoken-answer text — pure, testable.
    static func dialogText(visits: [DayVisit], dayText: String) -> String {
        guard let first = visits.first else {
            return String(
                localized: "app-intent.where-was-i.no-data",
                defaultValue: "I don't have location data for \(dayText).",
                comment: "Siri response when there is no location data for the requested date."
            )
        }
        switch first.category {
        case .destination:
            let places = visits.map { placeDescription($0) }
            let joined: String
            if places.count > 1 {
                let preceding = places.dropLast().joined(separator: ", ")
                joined = String(
                    localized: "app-intent.where-was-i.place-list",
                    defaultValue: "\(preceding) and \(places[places.count - 1])",
                    comment: "List of places in a Where Was I Siri response."
                )
            } else {
                joined = places[0]
            }
            let tripNames = Set(visits.compactMap(\.tripName))
            if tripNames.count == 1, let tripName = tripNames.first {
                return String(
                    localized: "app-intent.where-was-i.destination-trip",
                    defaultValue: "On \(dayText), you were in \(joined) during your trip “\(tripName)”.",
                    comment: "Siri response naming destinations and their shared trip."
                )
            }
            return String(
                localized: "app-intent.where-was-i.destination",
                defaultValue: "On \(dayText), you were in \(joined).",
                comment: "Siri response naming destinations for a requested date."
            )
        case .home, .routine:
            if first.isTemporaryHome {
                if let place = first.place {
                    return String(
                        localized: "app-intent.where-was-i.temporary-home.place",
                        defaultValue: "On \(dayText), you were at your temporary home in \(place).",
                        comment: "Siri response naming the place of the user's temporary home for a requested date."
                    )
                }
                return String(
                    localized: "app-intent.where-was-i.temporary-home",
                    defaultValue: "On \(dayText), you were at your temporary home.",
                    comment: "Siri response for a date spent at the user's temporary home."
                )
            }
            // A routine place (an office, a campus, a gym) is not home.
            if first.category == .routine {
                if let place = first.place {
                    return String(
                        localized: "app-intent.where-was-i.routine-place",
                        defaultValue: "On \(dayText), you were at a routine place in \(place).",
                        comment: "Siri response for a date spent at one of the user's routine places (such as an office or a gym); the second placeholder is its city."
                    )
                }
                return String(
                    localized: "app-intent.where-was-i.routine",
                    defaultValue: "On \(dayText), you were at a routine place.",
                    comment: "Siri response for a date spent at one of the user's routine places (such as an office or a gym)."
                )
            }
            if let place = first.place {
                return String(
                    localized: "app-intent.where-was-i.home-place",
                    defaultValue: "On \(dayText), you were home in \(place).",
                    comment: "Siri response naming the place of the user's home for a requested date."
                )
            }
            return String(
                localized: "app-intent.where-was-i.home",
                defaultValue: "On \(dayText), you were home.",
                comment: "Siri response for a date spent at home."
            )
        case .transit:
            let stops = visits.compactMap(\.place)
            if stops.isEmpty {
                return String(
                    localized: "app-intent.where-was-i.transit",
                    defaultValue: "On \(dayText), you were in transit.",
                    comment: "Siri response for a date spent in transit with no known stops."
                )
            }
            return String(
                localized: "app-intent.where-was-i.transit-stops",
                defaultValue: "On \(dayText), you were in transit through \(stops.joined(separator: ", ")).",
                comment: "Siri response naming transit stops for a requested date."
            )
        case .unclassified:
            return String(
                localized: "app-intent.where-was-i.no-data",
                defaultValue: "I don't have location data for \(dayText).",
                comment: "Siri response when there is no location data for the requested date."
            )
        }
    }

    private static func placeDescription(_ visit: DayVisit, locale: Locale = .current) -> String {
        guard let place = visit.place else {
            return visit.countryName ?? String(
                localized: "app-intent.where-was-i.unknown-place",
                defaultValue: "an unknown place",
                locale: locale,
                comment: "Fallback place name in a Where Was I Siri response."
            )
        }
        if let country = visit.countryName {
            return String(
                localized: "app-intent.where-was-i.place-country",
                defaultValue: "\(place) (\(country))",
                locale: locale,
                comment: "Place followed by its country in a Where Was I Siri response."
            )
        }
        return place
    }

    static func rangeDialogText(visits: [DayVisit], rangeText: String, locale: Locale) -> String {
        guard !visits.isEmpty else {
            return String(
                localized: "app-intent.where-was-i.no-data",
                defaultValue: "I don't have location data for \(rangeText).",
                locale: locale,
                comment: "Siri response when there is no location data for the requested date."
            )
        }
        let formatter = ListFormatter()
        formatter.locale = locale
        let places = visits.map { placeDescription($0, locale: locale) }
        let joined = formatter.string(from: places) ?? places.joined(separator: ", ")
        return String(
            localized: "app-intent.where-was-i.range-result",
            defaultValue: "Your recorded places for \(rangeText) were \(joined).",
            locale: locale,
            comment: "Siri response listing all recorded places during an inclusive date range."
        )
    }
}

// MARK: - WhereWasIIntent

// MainActor-isolated (target default; `@Parameter` forbids `nonisolated`).
struct WhereWasIIntent: AppIntent {

    static let title: LocalizedStringResource = "Where Was I"
    /// Travel history is personal, so a locked device must be unlocked first.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let description = IntentDescription(
        LocalizedStringResource(
            "app-intent.where-was-i.description",
            defaultValue: "Tells you where you were on a date or during a date range, from your travel journal."
        ),
        categoryName: "Trips"
    )

    @Parameter(title: "Date", requestValueDialog: "For which date?")
    var date: Date

    @Parameter(title: LocalizedStringResource("app-intent.where-was-i.end-date", defaultValue: "End Date"))
    var endDate: Date?

    static var parameterSummary: some ParameterSummary {
        Summary("Where was I on \(\.$date)") {
            \.$endDate
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[TripEntity]> & ProvidesDialog & ShowsSnippetView {
        let day = date
        let lastDay = endDate
        let calendar = Calendar.current
        let appLocale = AppLanguagePreference.currentLocale()
        guard let window = WhereWasIFetcher.dateWindow(from: day, through: lastDay, calendar: calendar) else {
            let message = String(
                localized: "app-intent.where-was-i.invalid-range",
                defaultValue: "The end date must be on or after the start date.",
                locale: appLocale,
                comment: "Validation message for a reversed Where Was I calendar date range."
            )
            throw $endDate.needsValueError(IntentDialog("\(message)"))
        }
        let isSingleDay = calendar.isDate(day, inSameDayAs: lastDay ?? day)
        // The container initializer records the mode, so open it first.
        let container = AppDelegate.modelContainer
        let loaded = try await WhereWasIFetcher.load(
            on: day, through: lastDay, container: container, calendar: calendar,
            isPersistentStore: AppDelegate.containerMode.isPersistent)
        let answer = loaded.visits
        let entities = loaded.trips

        let style = Date.FormatStyle(date: .long, time: .omitted, locale: appLocale,
                                    calendar: calendar, timeZone: calendar.timeZone)
        let startText = window.start.formatted(style)
        let dayText: String
        if isSingleDay {
            dayText = startText
        } else {
            let endText = calendar.startOfDay(for: lastDay ?? day).formatted(style)
            dayText = String(
                localized: "app-intent.where-was-i.range-label",
                defaultValue: "\(startText) to \(endText)",
                locale: appLocale,
                comment: "Inclusive start and end date label for a Where Was I range."
            )
        }
        let message = isSingleDay
            ? WhereWasIFetcher.dialogText(visits: answer, dayText: dayText)
            : WhereWasIFetcher.rangeDialogText(visits: answer, rangeText: dayText, locale: appLocale)
        let dialog = IntentDialog("\(message)")
        return .result(
            value: entities,
            dialog: dialog,
            view: WhereWasISnippetView(dayText: dayText, visits: answer)
        )
    }
}
