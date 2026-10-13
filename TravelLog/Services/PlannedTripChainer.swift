//
//  PlannedTripChainer.swift
//  TravelLog
//

import Foundation
import SwiftData

/// One display card's worth of chained planned-trip legs: "home port →
/// Cephalonia → Lefkada → home port" across several calendar events is ONE
/// journey named "Cephalonia → Lefkada". Value type built at render time; nothing
/// here persists; the underlying `PlannedTrip` rows keep their own per-leg
/// lifecycle (matching/expiry stays per-row).
nonisolated struct PlannedJourney: Identifiable, Sendable, Equatable {
    /// The earliest leg's row id — stable across re-renders of the same chain.
    let id: UUID
    /// Every member `PlannedTrip` row id, chronological. Dismissing the
    /// journey dismisses all of them.
    let legIDs: [UUID]
    /// Destination names in visit order — transit and return legs excluded.
    let destinations: [String]
    /// Earliest leg's title, shown when no destination could be extracted.
    let fallbackTitle: String
    let startDate: Date
    let endDate: Date
    /// Highest confidence among the legs (one strong leg vouches for the
    /// chain it anchors).
    let confidence: PlannedTripConfidence

    var displayName: String {
        displayName(locale: .current)
    }

    /// Locale-explicit route rendering for widgets. The journey itself is
    /// structured data; only the route separator is localized, and nothing is
    /// generated or persisted by this display path.
    func displayName(locale: Locale) -> String {
        let languageTag = AppLanguagePreference.normalizedSupportedTag(
            FMLanguagePolicy.canonicalLanguageTag(for: locale)
        ) ?? "en"
        let separator = AppLanguagePreference.localizedString(
            key: "planned-trip.display-name.route-separator",
            defaultValue: " → ",
            languageTag: languageTag)
        return destinations.isEmpty
            ? fallbackTitle
            : destinations.joined(separator: separator)
    }

    var legCount: Int { legIDs.count }
}

/// Deterministic, display-time grouping of planned-trip rows into journeys —
/// the future-lane analogue of `TripClassifier` assembling stays into one
/// `Trip`. Pure functions over value inputs (same testing shape as
/// `PlannedTripDetector`); no AI, no geocoding. An island-hopping itinerary
/// (3 "Trip to X" + 3 "Boat: … from A to B" events) must render as one
/// journey with the return leg recognized, not as a stack of six sibling
/// cards.
nonisolated enum PlannedTripChainer {

    /// Value slice of a `PlannedTrip` row (`@Model`s never enter pure logic).
    struct Leg: Sendable, Equatable {
        let id: UUID
        let title: String
        let startDate: Date
        let endDate: Date
        let confidence: PlannedTripConfidence

        init(id: UUID, title: String, startDate: Date, endDate: Date, confidence: PlannedTripConfidence) {
            self.id = id
            self.title = title
            self.startDate = startDate
            self.endDate = endDate
            self.confidence = confidence
        }
    }

    /// Two legs belong to the same journey when the next starts within this
    /// gap of the running chain's end. Generous on purpose — an island hop
    /// with an unbooked middle day is still one journey; two separate
    /// weekend trips a week apart are not. Tunable, like every threshold
    /// in this app.
    static let chainGapSeconds: TimeInterval = 48 * 60 * 60

    // MARK: - Chaining

    /// Whether a journey card should be suppressed because the travel it
    /// predicted is ALREADY HAPPENING as a real ongoing `Trip`:
    /// `CalendarEnricher.applyScan` retires an `.upcoming`
    /// `PlannedTrip` only after its `endDate` passes, so without this
    /// check a started journey would render under "Upcoming" next to the
    /// "Currently Traveling" row for the ENTIRE trip — reading as a second
    /// trip. A journey is superseded once it has started (`startDate` at
    /// or before now) and any ongoing trip's window overlaps it (an
    /// ongoing trip is `[start, ∞)`, so overlap ⇔ `start ≤ journeyEnd`).
    /// Future journeys always render; a started journey with NO ongoing
    /// trip still renders (detection may have missed the trip — the card
    /// is then the only trace).
    static func journeyIsSupersededByOngoingTrip(
        journeyStart: Date,
        journeyEnd: Date,
        now: Date,
        ongoingTripStartDates: [Date]
    ) -> Bool {
        guard journeyStart <= now else { return false }
        return ongoingTripStartDates.contains { $0 <= journeyEnd }
    }

    /// The single next journey the Upcoming Trip widget and the Next Trip
    /// intent name: medium+ confidence, minus journeys an ongoing trip
    /// already covers, earliest first. Mirrors the Trips-list card.
    static func nextJourney(
        from legs: [Leg],
        homeNames: [String],
        now: Date,
        ongoingTripStartDates: [Date]
    ) -> PlannedJourney? {
        journeys(from: legs, homeNames: homeNames)
            .filter { $0.confidence != .low }
            .filter {
                !journeyIsSupersededByOngoingTrip(
                    journeyStart: $0.startDate,
                    journeyEnd: $0.endDate,
                    now: now,
                    ongoingTripStartDates: ongoingTripStartDates
                )
            }
            .min { $0.startDate < $1.startDate }
    }

    /// When the Upcoming Trip widget should flip to "On trip": the journey's
    /// start, if it falls after `now` and before the timeline's `refresh`.
    /// A timed first leg (a 14:00 flight) otherwise stays on the countdown
    /// until the next midnight reload.
    static func startTransitionDate(journeyStart: Date, now: Date, refresh: Date) -> Date? {
        journeyStart > now && journeyStart < refresh ? journeyStart : nil
    }

    /// Groups legs into journeys. `homeNames` (Home labels/localities/admin
    /// areas) lets "Trip to <home>" be recognized as the return leg even
    /// when no transport leg names the origin, and anchors the chain-boundary
    /// rules below.
    ///
    /// # Chain-boundary semantics
    ///
    /// Temporal adjacency alone over-merged: "fly home from Portugal Sat" +
    /// "drive to a wedding Sun" is two journeys 24 h apart, not one. Within
    /// the 48 h gap a leg STARTS A NEW journey when either:
    ///
    /// - the chain already CAME HOME — a previous leg's extracted
    ///   destination matched a Home name — and this leg neither references
    ///   home itself nor shares a place token with the chain (the island
    ///   hop's trailing "Trip to <home>" stay after its return ferry still
    ///   merges; the unrelated wedding drive does not); or
    /// - the leg DEPARTS FROM home ("… from <home> to X") toward a place
    ///   the chain never mentioned — leaving home again is a new journey.
    ///   The shared-place exception keeps a home-origin transport leg
    ///   attached when an all-day stay event for the same destination
    ///   sorted ahead of it ("Trip to Rome" at 00:00, "Flight from Athens
    ///   to Rome" at 08:00).
    ///
    /// A leg whose ORIGIN simply doesn't match the chain deliberately does
    /// NOT split: real ferry titles put vessel names in the "from" slot
    /// ("from VESSEL to home port"), so only a POSITIVE home match
    /// carries boundary meaning — a wrong origin still suppresses nothing.
    /// Legs with no route text at all keep the pure temporal behavior.
    static func journeys(from legs: [Leg], homeNames: [String]) -> [PlannedJourney] {
        guard !legs.isEmpty else { return [] }

        let normalizedHomeNames = Set(homeNames.map(normalized).filter { !$0.isEmpty })
        let routesByTitle = Dictionary(uniqueKeysWithValues: Set(legs.map(\.title)).map { ($0, extractRoute(title: $0)) })

        // A `.low` leg may chain ONLY if it carries place evidence. Low legs
        // participating in chaining is allowed when supported by a place: a
        // low-confidence "Boat: Cephalonia" leg genuinely belongs to the journey;
        // but the discriminator has to be place evidence, not confidence.
        // Chaining is purely temporal for legs with no route text, and BOTH
        // split rules (`closedChainRejects`, `departsHomeAnew`) require
        // `extractRoute` to yield something, which a title like "Standup
        // check-in" never does. So a recurring meeting within 48 h of a real
        // trip would be absorbed into it, and because the merged journey takes
        // `max(confidence)` the card would still surface — with the junk row's
        // date and title, since identity comes from `chain[0]`. A placeless low
        // leg dropped here would only ever have formed a low-confidence
        // journey, which the caller filters out anyway, so nothing renderable
        // is lost.
        let chainable = legs.filter { leg in
            guard leg.confidence == .low else { return true }
            if !placeTokens(route: routesByTitle[leg.title]!, excludingHome: normalizedHomeNames).isEmpty { return true }
            let route = routesByTitle[leg.title]!
            return route.origin != nil || route.destination != nil
        }
        guard !chainable.isEmpty else { return [] }

        // Deterministic order: (startDate, endDate, uuid) is a strict total
        // order, so shuffled inputs produce identical journeys.
        let sorted = chainable.sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            if $0.endDate != $1.endDate { return $0.endDate < $1.endDate }
            return $0.id.uuidString < $1.id.uuidString
        }

        var chains: [[Leg]] = []
        var current: [Leg] = [sorted[0]]
        var chainEnd = sorted[0].endDate
        var chainPlaces = placeTokens(route: routesByTitle[sorted[0].title]!, excludingHome: normalizedHomeNames)
        var chainCameHome = isHomecoming(route: routesByTitle[sorted[0].title]!, homeNames: normalizedHomeNames)

        for leg in sorted.dropFirst() {
            let withinGap = leg.startDate.timeIntervalSince(chainEnd) <= chainGapSeconds
            let legPlaces = placeTokens(route: routesByTitle[leg.title]!, excludingHome: normalizedHomeNames)
            let sharesPlace = !legPlaces.isDisjoint(with: chainPlaces)
            let referencesHome = isHomecoming(route: routesByTitle[leg.title]!, homeNames: normalizedHomeNames)
            let closedChainRejects = chainCameHome && !referencesHome && !sharesPlace
            let departsHomeAnew = departsHome(route: routesByTitle[leg.title]!, homeNames: normalizedHomeNames) && !sharesPlace

            if withinGap && !closedChainRejects && !departsHomeAnew {
                current.append(leg)
                chainEnd = max(chainEnd, leg.endDate)
                chainPlaces.formUnion(legPlaces)
                chainCameHome = chainCameHome || referencesHome
            } else {
                chains.append(current)
                current = [leg]
                chainEnd = leg.endDate
                chainPlaces = legPlaces
                chainCameHome = referencesHome
            }
        }
        chains.append(current)

        return chains.map { journey(from: $0, routesByTitle: routesByTitle, normalizedHomeNames: normalizedHomeNames) }
    }

    /// Normalized non-home place tokens a leg's title mentions (route origin
    /// + destination). Home names are excluded so "everything touches home"
    /// can't glue unrelated journeys together.
    private static func placeTokens(route: (origin: String?, destination: String?), excludingHome homeNames: Set<String>) -> Set<String> {
        var tokens = Set<String>()
        for place in [route.origin, route.destination].compactMap({ $0 }) {
            let key = normalized(place)
            if !key.isEmpty && !homeNames.contains(key) { tokens.insert(key) }
        }
        return tokens
    }

    /// The leg's extracted destination is a Home name — a return leg.
    private static func isHomecoming(route: (origin: String?, destination: String?), homeNames: Set<String>) -> Bool {
        guard let destination = route.destination else { return false }
        return homeNames.contains(normalized(destination))
    }

    /// The leg's extracted origin is a Home name — an outbound leg.
    private static func departsHome(route: (origin: String?, destination: String?), homeNames: Set<String>) -> Bool {
        guard let origin = route.origin else { return false }
        return homeNames.contains(normalized(origin))
    }

    private static func journey(from chain: [Leg], routesByTitle: [String: (origin: String?, destination: String?)], normalizedHomeNames: Set<String>) -> PlannedJourney {
        // The chain's origin: the first leg that names one ("Boat: … FROM
        // home port to Cephalonia"). A later leg whose destination equals it is the
        // return ticket, not another destination.
        let chainOrigin = chain
            .compactMap { routesByTitle[$0.title]!.origin }
            .map(normalized)
            .first

        var indexByKey: [String: Int] = [:]
        var destinationDescriptors: [(name: String, isTransit: Bool)] = []
        for leg in chain {
            guard let destination = routesByTitle[leg.title]!.destination else { continue }
            let key = normalized(destination)
            guard !key.isEmpty else { continue }
            // Return-leg exclusion: back to the chain's own origin, or to
            // any Home place name.
            if key == chainOrigin || normalizedHomeNames.contains(key) { continue }
            let isTransit = hasTransitPrefix(title: leg.title) || routesByTitle[leg.title]!.origin != nil
            if let existing = indexByKey[key] {
                // A ferry's route endpoint often precedes the stay event for
                // the same place ("Boat: … to Cephalonia" then "Trip to Cephalonia");
                // the stay sighting upgrades the descriptor so the place
                // still names the journey.
                if destinationDescriptors[existing].isTransit && !isTransit {
                    destinationDescriptors[existing] = (destination, false)
                }
            } else {
                indexByKey[key] = destinationDescriptors.count
                destinationDescriptors.append((destination, isTransit))
            }
        }
        // Stay-shaped legs ("Trip to Cephalonia") name the journey; transport
        // legs' destinations only step in when nothing else is available
        // (a boats-only itinerary).
        let stayDestinations = destinationDescriptors.filter { !$0.isTransit }.map(\.name)
        let destinations = stayDestinations.isEmpty
            ? destinationDescriptors.map(\.name)
            : stayDestinations

        let rank: [PlannedTripConfidence: Int] = [.low: 0, .medium: 1, .high: 2]
        let confidence = chain
            .map(\.confidence)
            .max { (rank[$0] ?? 0) < (rank[$1] ?? 0) } ?? .low

        return PlannedJourney(
            id: chain[0].id,
            legIDs: chain.map(\.id),
            destinations: destinations,
            fallbackTitle: chain[0].title,
            startDate: chain[0].startDate,
            endDate: chain.map(\.endDate).max() ?? chain[0].endDate,
            confidence: confidence
        )
    }

    // MARK: - Route extraction

    /// Transport-booking shapes whose "destination" is a route endpoint, not
    /// a stay: mode-prefixed titles and explicit "from A to B" routes.
    static func isTransitLeg(title: String) -> Bool {
        hasTransitPrefix(title: title) || extractRoute(title: title).origin != nil
    }

    private static func hasTransitPrefix(title: String) -> Bool {
        let lowercased = title.lowercased()
        return ["boat:", "ferry:", "train:", "bus:", "flight:"].contains(where: { lowercased.hasPrefix($0) })
    }

    /// Pulls (origin, destination) place text out of an event title.
    /// - "Boat: OPERATOR from Cephalonia to Lefkada" → ("Cephalonia", "Lefkada")
    /// - "Trip to Cephalonia" / "Flight to Rome" → (nil, "Cephalonia"/"Rome")
    /// - "Team standup" → (nil, nil)
    /// Free-text parsing is best-effort by nature: a vessel name in the
    /// "from" slot ("from VESSEL to home port") still yields the correct
    /// destination. A wrong origin suppresses nothing (it will not match a later
    /// destination).
    static func extractRoute(title: String) -> (origin: String?, destination: String?) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)

        if let match = trimmed.firstMatch(of: fromToRegex) {
            return (cleaned(String(match.1)), cleaned(String(match.2)))
        }
        if let match = trimmed.firstMatch(of: toDestinationRegex) {
            return (nil, cleaned(String(match.1)))
        }
        return (nil, nil)
    }

    /// "… from <origin> to <destination>" anywhere in the title. Lazy origin
    /// capture so "from A to B to C" splits at the FIRST "to".
    private static var fromToRegex: Regex<(Substring, Substring, Substring)> {
        /(?i)\bfrom\s+(.+?)\s+to\s+(.+)$/
    }

    /// "<mode/booking word> to <destination>" title prefixes.
    private static var toDestinationRegex: Regex<(Substring, Substring)> {
        /(?i)^(?:trip|flight|travel|drive|ferry|boat|train|bus|sail(?:ing)?)\s+to\s+(.+)$/
    }

    private static func cleaned(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, ".,;:!?)".contains(last) {
            text.removeLast()
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(80))
    }

    /// Case- and diacritic-insensitive comparison key ("Lefkada" == "lefkada",
    /// "résumé" == "resume").
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

// MARK: - Store inputs (app + widget)

extension PlannedTripChainer {

    /// Everything `nextJourney` reads from the store.
    nonisolated struct StoreInputs: Sendable, Equatable {
        let legs: [Leg]
        let homeNames: [String]
        let ongoingTripStartDates: [Date]
    }

    /// The one read behind the Upcoming Trip widget and the Next Trip intent,
    /// so both name the same journey. Throws when any read fails: a failed
    /// Home read lets a return leg survive chaining and a failed ongoing-trip
    /// read un-suppresses a covered journey, so either would name a different
    /// journey than the app. Callers treat a throw as unavailable, not "none".
    nonisolated static func storeInputs(in context: ModelContext, now: Date) throws -> StoreInputs {
        let upcomingRaw = PlannedTripStatus.upcoming.rawValue
        let predicate = #Predicate<PlannedTrip> { $0.statusRaw == upcomingRaw }
        try WidgetStoreRead.check(.plannedTrips)
        let rows = try context.fetch(FetchDescriptor<PlannedTrip>(predicate: predicate))
        // Low-confidence legs ride along into chaining; `nextJourney` then
        // surfaces medium+ journeys only.
        let legs = rows
            .filter { $0.currentUntil() >= now }
            .map {
                Leg(id: $0.id, title: $0.title,
                    startDate: $0.startDate, endDate: $0.endDate, confidence: $0.confidence)
            }
        // Home names let a return leg that only names the Home city end the
        // chain.
        try WidgetStoreRead.check(.homes)
        let homes = try context.fetch(FetchDescriptor<Home>())
        // A temporary home that has not ended at `now` names a return leg
        // like a Home. An ended one adds nothing, so a later trip to that
        // city keeps its name. Its read shares the `.homes` checkpoint.
        let temporaryHomes = try HomeAnchors.collapsingTwins(context.fetch(FetchDescriptor<TemporaryHome>()))
            .filter { ($0.endedAt ?? .distantFuture) >= now }
        var homeNames = homes.flatMap { [$0.label, $0.locality ?? "", $0.administrativeArea ?? ""] }
        homeNames += temporaryHomes.flatMap { [$0.label, $0.locality ?? "", $0.administrativeArea ?? ""] }
        // Like the app card, drop a started journey an ongoing trip covers.
        var ongoingDescriptor = FetchDescriptor<Trip>(predicate: #Predicate<Trip> { $0.isComplete == false })
        ongoingDescriptor.propertiesToFetch = [\.startDate]
        try WidgetStoreRead.check(.ongoingTrips)
        let ongoingTripStartDates = try context.fetch(ongoingDescriptor).map(\.startDate)
        return StoreInputs(legs: legs, homeNames: homeNames, ongoingTripStartDates: ongoingTripStartDates)
    }
}
