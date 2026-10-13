//
//  TripSearchAI.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 22/5/26.
//

import Foundation
import FoundationModels

/// Foundation-Models-backed search fallback. Invoked when the shared local
/// resolver (`TripQueryParser.searchTrips`) returns zero results AND the
/// user's query is non-trivial.
///
/// # Design
///
/// We use Apple's `Tool` protocol so the LLM can issue structured
/// queries against the user's trip set instead of having every trip
/// stuffed into the prompt (4096-token budget would cap us at ~50 trips
/// of detail before truncation). The session exposes one tool —
/// `SearchTripsTool` — that takes its `Arguments` filter and returns the
/// matching trip snapshots; the model issues one or more tool calls,
/// then emits a final plain-text response listing compact result handles that
/// match the user's intent.
///
/// We deliberately use the **plain-text response** API (`respond(to:)`)
/// rather than `respond(to:generating:)` because Apple has not
/// documented combining `@Generable` output types with tool-enabled
/// sessions — risk of misbehavior or silent degradation. Numeric handles
/// map back to snapshot UUIDs after bounds checking; the LLM is
/// instructed to format the response strictly.
///
/// # Availability
///
/// Foundation Models requires Apple Intelligence. On devices where
/// `SystemLanguageModel.default.availability != .available` (older
/// hardware, Apple Intelligence off in Settings, region restriction),
/// the orchestrator returns `.unavailable` and the caller hides the
/// AI-suggested results section entirely.
enum TripSearchAI {

    /// Result of an AI search attempt. `unavailable` is distinct from
    /// `empty` so the UI can communicate "tried and found nothing" vs.
    /// "couldn't try at all".
    enum Outcome {
        case success([UUID])
        case empty
        case unavailable
        case failed
    }

    /// Compact numeric handles let all 40 tool results fit in the response budget.
    private static let maxResponseTokens: Int = 600

    /// Run the AI search.
    ///
    /// Parameters:
    /// - query: the user's natural-language search string. Whitespace-trimmed.
    /// - snapshots: `Sendable` value-type mirror of the trip set the local
    ///   matcher had access to. The caller builds these on the main actor
    ///   before invoking — passing live `[Trip]` (`@Model`, non-`Sendable`)
    ///   into this async function would let the Tool read model properties
    ///   from a non-main thread.
    /// Returns: an `Outcome` describing what happened. The caller is
    /// responsible for mapping `success([UUID])` back to `[Trip]` via
    /// the live `@Query` results.
    static func search(
        query: String,
        snapshots: [TripSnapshot],
        locale: Locale = .current,
        localeSupported: Bool = FMCapability.supportsCurrentLocale()
    ) async -> Outcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        guard FMLanguagePolicy.searchFMAllowed(
            locale: locale,
            supportsLocale: { _ in localeSupported }
        ) else {
            return .unavailable
        }

        // Availability check. The framework's availability can flip at
        // runtime (Apple Intelligence toggled in Settings.app while the
        // app is in the foreground), so we check on every invocation
        // rather than caching.
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        default:
            return .unavailable
        }

        let tool = SearchTripsTool(snapshots: snapshots)

        let instructions = """
        You help users search their personal travel diary. The user types a
        natural-language query (e.g. "Greek islands trip", "those flights to Tokyo",
        "winter 2023 ski"). You use the `searchTrips` tool to find candidate
        trips — call it once with filters that capture the user's intent. If
        the first call returns no matches, try a different filter
        combination (broader date range, alternative country codes, a
        different locality fragment) — but don't loop more than 3 times.

        Trip handles are numbers in the tool output, formatted as `[number] ...`.

        Respond with ONLY the comma-separated numeric handles of all matching trips —
        nothing else. If nothing matches the user's intent, respond with the
        single word: NONE
        """

        let session = LanguageModelSession(tools: [tool], instructions: instructions)

        do {
            let response = try await session.respond(
                to: trimmed,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxResponseTokens)
            )
            let text = response.content
            let ids = extractUUIDs(from: text, snapshots: snapshots)
            return ids.isEmpty ? .empty : .success(ids)
        } catch {
            return FMErrorClassifier.disposition(of: error) == .transient ? .unavailable : .failed
        }
    }

    /// Handles are stable 1-based snapshot indexes, including across tool retries.
    private static func extractUUIDs(from text: String, snapshots: [TripSnapshot]) -> [UUID] {
        var seen = Set<UUID>()
        var ordered: [UUID] = []
        // The model may echo the tool's `[n]` decoration or put one handle per line.
        for token in text.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            guard let handle = Int(token.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t"))),
                  handle > 0, handle <= snapshots.count else { continue }
            let id = snapshots[handle - 1].id
            if seen.insert(id).inserted { ordered.append(id) }
        }
        return ordered
    }

    #if DEBUG
    /// Test-only passthrough to the handle decoder.
    static func extractUUIDsForTesting(from text: String, snapshots: [TripSnapshot]) -> [UUID] {
        extractUUIDs(from: text, snapshots: snapshots)
    }
    #endif
}

// MARK: - TripSnapshot

/// Sendable, value-type mirror of a `Trip` for passing across actor
/// boundaries (specifically into `SearchTripsTool.call`, which runs as
/// part of the Foundation Models session's execution).
///
/// `@Model` instances are not safely `Sendable`. Snapshotting at the
/// orchestrator's entry point keeps the AI path purely value-based.
///
/// `nonisolated`: the initializer reads only stored `Trip`/`Stay` fields
/// and `nonisolated` derived values, so it can run on whichever isolation
/// owns the trips' `ModelContext`.
nonisolated struct TripSnapshot: Sendable {
    let id: UUID
    let displayName: String
    let destinationSummary: String
    let countryISOCodes: [String]      // e.g. ["GR", "IT"]
    let englishCountryNames: [String]  // e.g. ["Greece", "Italy"]
    let localityList: [String]         // every stay's locality, dedup'd
    let administrativeAreaList: [String] // every stay's admin area, dedup'd (state / region)
    /// The names the user sees: `destinationSummary` entries plus the metro
    /// and island names of destination (and unclassified) stays, dedup'd.
    /// "London" for a trip whose only locality is a London district.
    let placeNames: [String]
    let startDate: Date
    let endDate: Date?
    let durationDays: Int?             // mirrors `Trip.durationDays`
    let isComplete: Bool

    init(from trip: Trip) {
        self.id = trip.id
        self.displayName = trip.displayName
        self.destinationSummary = trip.destinationSummary
        let codes = trip.countryCodes.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        self.countryISOCodes = codes
        let englishLocale = Locale(identifier: "en_US")
        self.englishCountryNames = codes.compactMap { englishLocale.localizedString(forRegionCode: $0) }
        var loc: [String] = []
        var locSeen = Set<String>()
        var admin: [String] = []
        var adminSeen = Set<String>()
        var places: [String] = []
        var placeSeen = Set<String>()
        func addPlace(_ name: String?) {
            guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  name != Trip.unknownDestinationSentinel, placeSeen.insert(name).inserted else { return }
            places.append(name)
        }
        for name in trip.destinationSummary.split(separator: ",") { addPlace(String(name)) }
        for stay in trip.stays ?? [] {
            if let l = stay.locality, !l.isEmpty, locSeen.insert(l).inserted {
                loc.append(l)
            }
            if let a = stay.administrativeArea, !a.isEmpty, adminSeen.insert(a).inserted {
                admin.append(a)
            }
            // `categoryRaw`, not the MainActor `category` accessor; an
            // unknown raw value reads as unclassified, as `category` does.
            let category = StayCategory(rawValue: stay.categoryRaw) ?? .unclassified
            if category == .destination || category == .unclassified {
                addPlace(stay.metroName)
                addPlace(stay.islandName)
            }
        }
        self.localityList = loc
        self.administrativeAreaList = admin
        self.placeNames = places
        self.startDate = trip.startDate
        self.endDate = trip.endDate
        self.durationDays = trip.durationDays
        self.isComplete = trip.isComplete
    }
}

// MARK: - SearchTripsTool

/// Foundation Models `Tool` exposing a structured search over the
/// user's trip set. The LLM calls this with `Arguments` it has inferred
/// from the user's natural-language query; we filter our snapshots and
/// return matches as a list of `[<handle>] <one-line summary>` strings —
/// the orchestrator maps those stable snapshot indexes back to UUIDs.
struct SearchTripsTool: Tool {
    let snapshots: [TripSnapshot]
    /// Gregorian in the given calendar's time zone: a
    /// Buddhist or Japanese device calendar must not shift `year`.
    let calendar: Calendar

    init(snapshots: [TripSnapshot], calendar: Calendar = TripFilters.yearCalendar) {
        self.snapshots = snapshots
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        self.calendar = gregorian
    }

    let name = "searchTrips"
    let description = """
    Search the user's travel diary by combinable filters. Every parameter
    is optional; the result is the intersection of all provided filters.
    Returns a list of matching trips formatted as `[number] Name | countries | start-end`.
    """

    @Generable
    struct Arguments {
        @Guide(description: "ISO 3166-1 alpha-2 country code (e.g. GR, IT, JP). Two letters, uppercase. Used to match trips that visited this country.")
        let countryCode: String?

        @Guide(description: "Fragment of a country's English name (e.g. \"Italy\", \"Greece\"). Case-insensitive substring match against the expanded country name.")
        let countryNameContains: String?

        @Guide(description: "Fragment of a STATE or REGION or PROVINCE name (e.g. \"California\", \"Bavaria\", \"Tokyo\"). Use this when the user names a sub-national area rather than a city or country: \"California\" is a state, not a country, so use this field, NOT countryCode (CA is Canada's ISO code, not California's). Case-insensitive substring match against the trip's stays' administrativeArea field.")
        let administrativeAreaContains: String?

        @Guide(description: "Fragment of a city / locality name (e.g. \"Tokyo\", \"Lhasa\"). Case-insensitive substring match against any of the trip's stays.")
        let localityContains: String?

        @Guide(description: "Year the trip started, e.g. 2024. Set to nil for any year.")
        let year: Int?

        @Guide(description: "Month the trip started, 1-12. Set to nil for any month.")
        let month: Int?

        @Guide(description: "Minimum trip duration in days. Set to nil for any duration.")
        let minDurationDays: Int?

        @Guide(description: "Maximum trip duration in days. Set to nil for any duration.")
        let maxDurationDays: Int?
    }

    func call(arguments: Arguments) async throws -> [String] {
        let filtered = snapshots.enumerated().filter { entry in
            matches(snapshot: entry.element, arguments: arguments)
        }
        if filtered.isEmpty {
            return ["No trips matched these filters."]
        }
        let strings = filtered.prefix(40).map { entry -> String in
            let snap = entry.element
            let codes = snap.countryISOCodes.joined(separator: ",")
            let start = FMPromptFormat.isoDay(snap.startDate)
            let end = snap.endDate.map(FMPromptFormat.isoDay) ?? "ongoing"
            return "[\(entry.offset + 1)] \(snap.displayName.toLatinAsciiStrict) | \(codes) | \(start) to \(end)"
        }
        return strings
    }

    private func matches(snapshot: TripSnapshot, arguments: Arguments) -> Bool {
        // Defensive trimming on string arguments — the @Guide instructions
        // ask for clean values but the LLM occasionally adds incidental
        // whitespace that would otherwise miss an exact-match comparison
        // against the snapshot's pre-trimmed codes.
        let ws = CharacterSet.whitespacesAndNewlines
        if let code = arguments.countryCode?.uppercased()
            .trimmingCharacters(in: ws), !code.isEmpty {
            if !snapshot.countryISOCodes.contains(code) { return false }
        }
        if let name = arguments.countryNameContains?
            .trimmingCharacters(in: ws), !name.isEmpty {
            if !Self.anyContains(snapshot.englishCountryNames, name) { return false }
        }
        if let loc = arguments.localityContains?
            .trimmingCharacters(in: ws), !loc.isEmpty {
            if !Self.anyContains(snapshot.localityList + snapshot.placeNames, loc) { return false }
        }
        if let admin = arguments.administrativeAreaContains?
            .trimmingCharacters(in: ws), !admin.isEmpty {
            if !Self.anyContains(snapshot.administrativeAreaList, admin) { return false }
        }
        if let year = arguments.year {
            let snapYear = calendar.component(.year, from: snapshot.startDate)
            if snapYear != year { return false }
        }
        if let month = arguments.month {
            let snapMonth = calendar.component(.month, from: snapshot.startDate)
            if snapMonth != month { return false }
        }
        if let minDays = arguments.minDurationDays {
            guard let days = snapshot.durationDays, days >= minDays else { return false }
        }
        if let maxDays = arguments.maxDurationDays {
            guard let days = snapshot.durationDays, days <= maxDays else { return false }
        }
        return true
    }

    /// Substring match over the search normalization (case, diacritics,
    /// width, Latin transliteration): any form of `fragment` inside any form
    /// of any value, so an accented query "Bellinzóna" finds the stored "Bellinzona".
    private static func anyContains(_ values: [String], _ fragment: String) -> Bool {
        let needles = TripSearch.normalizedSearchForms(fragment)
        return values.contains { value in
            let forms = TripSearch.normalizedSearchForms(value)
            return needles.contains { needle in forms.contains { $0.contains(needle) } }
        }
    }

    #if DEBUG
    /// Test-only builder for `Arguments`, avoiding direct reliance on the
    /// `@Generable`-synthesized memberwise initializer. Behavior-neutral.
    static func argumentsForTesting(
        countryCode: String? = nil,
        countryNameContains: String? = nil,
        administrativeAreaContains: String? = nil,
        localityContains: String? = nil,
        year: Int? = nil,
        month: Int? = nil,
        minDurationDays: Int? = nil,
        maxDurationDays: Int? = nil
    ) -> Arguments {
        Arguments(
            countryCode: countryCode,
            countryNameContains: countryNameContains,
            administrativeAreaContains: administrativeAreaContains,
            localityContains: localityContains,
            year: year,
            month: month,
            minDurationDays: minDurationDays,
            maxDurationDays: maxDurationDays
        )
    }

    /// Test-only passthrough to the private `matches(snapshot:arguments:)`
    /// filter. Behavior-identical — no logic of its own.
    func matchesForTesting(snapshot: TripSnapshot, arguments: Arguments) -> Bool {
        matches(snapshot: snapshot, arguments: arguments)
    }
    #endif
}
