//
//  Trip.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//


import Foundation
import SwiftData

/// A trip is a sequence of non-home, non-routine stays between leaving home and returning home.
///
/// Trips are assembled from classified stays by the trip classification pipeline.
/// A trip like Athens → London → Oxford → London → Athens would contain three
/// destination stays (London, Oxford, London) under a single Trip.
@Model
final class Trip {

    /// Persisted fallback used when a destination stay has no resolved name.
    /// This byte is a storage contract; display code checks it structurally.
    nonisolated static let unknownDestinationSentinel = "Unknown"

    var id: UUID = UUID()

    var startDate: Date = Date.now

    /// Nil if the trip is still ongoing (user hasn't returned home yet).
    var endDate: Date?

    /// Whether the user has returned home, closing this trip.
    var isComplete: Bool = false

    /// User-provided custom name for this trip. When set, takes precedence
    /// over the auto-generated `destinationSummary` for display purposes.
    var customName: String?

    // MARK: - Derived Summary

    /// Human-readable destination summary, e.g. "London, Oxford" or "Dubai".
    /// Recomputed whenever stays change.
    var destinationSummary: String = ""

    /// Comma-separated ISO country codes of this trip's **destination** stays
    /// only (not transit). Drives `countryFlags` on the trip card and the
    /// per-country breakdown in `StatsView`. Transit countries are excluded:
    /// flying through a country does not count as visiting it.
    var countryCodes: String = ""

    /// AI-generated concise human title (e.g. "White Plains & NYC", "Greek Islands").
    /// Populated by Stage 5 of the trip pipeline using Apple's Foundation Models
    /// framework. Preferred over `destinationSummary` in `displayName` when set.
    /// Nil when Apple Intelligence is unavailable, when the AI declined a result,
    /// or when the trip has no destination stays to title. Added in V9.
    var aiGeneratedTitle: String?

    /// Identifies the current semantic incarnation of `aiGeneratedTitle`.
    /// Localized variants must carry the same revision as well as the same
    /// source text. This prevents an out-of-order CloudKit row from becoming
    /// current again when a later title happens to reuse identical English
    /// words. Nil is the pre-V16/never-localized compatibility state. Added V16.
    var titleSourceRevision: UUID?

    // MARK: - V11 FM Summary

    /// AI-generated narrative paragraph (~80 words) written by earlier
    /// builds; nothing generates, shows or clears one now. Kept so existing
    /// text survives sync, backup, restore and the removed-trip archive.
    /// Added in V11.
    var aiGeneratedSummary: String?

    /// When the summary was generated. Used for debugging and potential
    /// future invalidation rules. Added in V11.
    var summaryGeneratedAt: Date?

    /// Prompt version that produced this summary. Application treats nil
    /// as version 1. Optional (not defaulted Int) per Apple's official
    /// guidance for lightweight CloudKit migrations. Added in V11.
    var summaryGenerationVersion: Int?

    /// How the summary was produced: "foundationModels" or "deterministic".
    /// Backs `SummarySource` enum. Added in V11.
    var summarySourceRaw: String?

    // MARK: - Classification Metadata

    /// Whether the trip was assembled with AI classification.
    var classifiedByAI: Bool = false

    /// Whether the user has manually edited any aspect of this trip.
    var userEdited: Bool = false

    /// True when `userEdited` was set by a temporary-home change to keep a trip
    /// the user favorited or annotated whole, not by an edit of the user's.
    /// Every user edit clears it. Nothing releases the mark automatically: a
    /// favorite or photo choice that is gone is not the user's consent. The
    /// flag says which marks are this feature's, so that a release the user
    /// asks for can be built on it. Added in V20.
    var keptByTemporaryHome: Bool = false

    // MARK: - Provenance

    /// Provenance of this trip. Defaults to `"liveSLC"` for V7→V8 lightweight
    /// migration. Derived from the constituent stays by `recomputeSummary()`:
    /// `"photoImport"` when all constituent stays are imported, or `"merged"`
    /// when stays span both sources. Use the `source` computed property for
    /// type-safe access. Added in V8.
    var sourceRaw: String = DataSource.liveSLC.rawValue

    // MARK: - Relationships

    @Relationship(deleteRule: .nullify, inverse: \Stay.trip)
    var stays: [Stay]?

    /// Per-language renderings of `aiGeneratedTitle`. The canonical title
    /// remains on `aiGeneratedTitle`; variants are invalidated/rebuilt by
    /// higher-level title services when that source changes. Optional on both
    /// sides for CloudKit compatibility. Deleting a Trip deletes its derived
    /// variants, while deleting one variant never affects the Trip. Added V16.
    @Relationship(deleteRule: .cascade, inverse: \TripTitleVariant.trip)
    var localizedTitles: [TripTitleVariant]?

    /// The ordered destination stays (convenience - filters out transit).
    var destinations: [Stay] {
        Self.stablySorted((stays ?? []).filter { $0.category == .destination })
    }

    /// The transit stays (layovers, connections).
    var transits: [Stay] {
        Self.stablySorted((stays ?? []).filter { $0.category == .transit })
    }

    /// Count-only companions to `destinations`/`transits`: one linear pass,
    /// no relationship sort — for call sites that never render the ordering.
    var destinationCount: Int {
        (stays ?? []).reduce(into: 0) { count, stay in
            if stay.category == .destination { count += 1 }
        }
    }

    var transitCount: Int {
        (stays ?? []).reduce(into: 0) { count, stay in
            if stay.category == .transit { count += 1 }
        }
    }

    /// All stays in trip order.
    var orderedStays: [Stay] {
        Self.stablySorted(stays ?? [])
    }

    /// Deterministic stay order: `orderInTrip ?? 0` alone ties for
    /// nil-order rows (JSON imports, mid-migration states), and Swift's sort is
    /// not stable — so every derived value downstream (`destinationSummary`,
    /// `countryCodes`, exports, Wrapped routes) could differ between two
    /// devices holding the SAME synced rows, churning CloudKit with spurious
    /// conflicting writes. (startTime, id) break ties identically everywhere.
    /// The keys are read once per stay, not through SwiftData on every
    /// comparison; the same comparisons over the same input order give the
    /// same result, ties included.
    nonisolated static func stablySorted(_ stays: [Stay]) -> [Stay] {
        guard stays.count > 1 else { return stays }
        return stays.map { (order: $0.orderInTrip ?? 0, start: $0.startTime, stay: $0) }
            .sorted { a, b in
                if a.order != b.order { return a.order < b.order }
                if a.start != b.start { return a.start < b.start }
                return a.stay.id.uuidString < b.stay.id.uuidString
            }
            .map(\.stay)
    }

    /// Duration in calendar days (inclusive). Returns nil if trip is ongoing.
    /// A trip from April 10-13 spans 4 days, not 3.
    ///
    /// Each boundary is read in the calendar of the place it happened: the
    /// first day in the zone of the trip's earliest stay, the last day in the
    /// zone of its latest-ending stay, picked by `TravelDays.boundaryStays` so
    /// duration and every day count agree on tied boundaries. Only the two
    /// boundaries define the count, so a trip crossing any number of zones in
    /// between needs no per-day tracking. Rows without a zone fall back to
    /// the device zone.
    ///
    /// `nonisolated`: pure function of stored fields, read off-main by
    /// `StatsAggregator`.
    nonisolated var durationDays: Int? {
        guard let endDate else { return nil }
        let boundary = TravelDays.boundaryStays(of: stays ?? [])
        return Self.inclusiveDays(
            from: startDate, in: StayTimeZone.resolve(boundary.first?.timeZoneIdentifier),
            to: endDate, in: StayTimeZone.resolve(boundary.last?.timeZoneIdentifier))
    }

    /// Inclusive calendar-day span between two instants, each read in its
    /// own zone. Pure; the seam `durationDays` is built on.
    nonisolated static func inclusiveDays(
        from start: Date, in startZone: TimeZone,
        to end: Date, in endZone: TimeZone
    ) -> Int {
        let first = TravelDays.label(for: start, zone: startZone) ?? start
        let last = TravelDays.label(for: end, zone: endZone) ?? end
        let days = TravelDays.labelCalendar.dateComponents([.day], from: first, to: last).day ?? 0
        return max(1, days + 1)
    }

    /// The name to display for this trip.
    ///
    /// Preference order:
    ///   1. `customName` (V4+) — the user's explicit override always wins.
    ///   2. A current-language `TripTitleVariant` whose source text and source
    ///      revision still match the canonical title.
    ///   3. `aiGeneratedTitle` (V9+) — the canonical English title and the
    ///      fallback for languages the installed model does not support.
    ///   4. `destinationSummary` (V1+) — the legacy comma-join of stay
    ///      localities. Last-ditch fallback when neither (1) nor (2) is set.
    ///   5. `"Trip"` — when everything else is empty.
    ///
    /// `nonisolated`: pure function of stored fields, read off-main by
    /// `StatsAggregator`.
    nonisolated var displayName: String {
        displayName(languageTag: AppLanguagePreference.currentTag())
    }

    /// Locale-explicit form for tests, widgets, and persisted snapshots.
    nonisolated func displayName(locale: Locale) -> String {
        displayName(languageTag: FMLanguagePolicy.canonicalLanguageTag(for: locale))
    }

    /// Language-explicit form. The language tag controls both the stored
    /// variant lookup and the deterministic fallback's connector strings.
    /// It performs no I/O or generation, so every display consumer can use it
    /// synchronously while a missing variant is produced in the background.
    nonisolated func displayName(languageTag rawLanguageTag: String) -> String {
        let languageTag = AppLanguagePreference.normalizedSupportedTag(rawLanguageTag) ?? "en"
        if let customName, !customName.isEmpty { return customName }
        if let localized = TripTitleStore.localizedTitle(
            for: self,
            languageTag: languageTag) {
            return localized
        }
        if let aiGeneratedTitle, !aiGeneratedTitle.isEmpty { return aiGeneratedTitle }
        let joined = Self.curatedJoin(destinationSummary, languageTag: languageTag)
        if !joined.isEmpty { return joined }
        return Self.localizedString(
            key: "trip.display-name.fallback",
            defaultValue: "Trip",
            languageTag: languageTag
        )
    }

    /// Whether `displayName` resolves above its final generic fallback tier.
    /// This deliberately mirrors `displayName` exactly, including an all-
    /// Unknown persisted destination summary remaining a usable tier-3 value.
    nonisolated var hasUsableDisplayName: Bool {
        if let customName, !customName.isEmpty { return true }
        if let aiGeneratedTitle, !aiGeneratedTitle.isEmpty { return true }
        return !Self.curatedJoin(destinationSummary).isEmpty
    }

    nonisolated static func isUsableDestinationName(_ name: String) -> Bool {
        name != unknownDestinationSentinel
    }

    /// Render the comma-joined `destinationSummary` (persisted, byte-stable)
    /// as a natural-language list for DISPLAY only; never written back:
    ///   "" → "", "Athens" → "Athens", "Athens, Cephalonia" → "Athens & Cephalonia",
    ///   "Athens, Cephalonia, Ios" → "Athens, Cephalonia & Ios".
    /// Whitespace around each component is trimmed and empty components are
    /// dropped, so a stray "Athens,, Cephalonia" still reads "Athens & Cephalonia".
    /// Pure + `nonisolated` so it's unit-testable off any actor (mirrors the
    /// repo's static-seam pattern).
    nonisolated static func naturalJoin(_ summary: String) -> String {
        naturalJoin(summary, languageTag: AppLanguagePreference.currentTag())
    }

    nonisolated static func naturalJoin(
        _ summary: String,
        languageTag rawLanguageTag: String
    ) -> String {
        let languageTag = AppLanguagePreference.normalizedSupportedTag(rawLanguageTag) ?? "en"
        let parts = summary
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2:
            return localizedFormat(
                key: "trip.display-name.two-places",
                defaultValue: "%1$@ & %2$@",
                languageTag: languageTag,
                arguments: [parts[0], parts[1]]
            )
        default:
            let head = parts.dropLast().joined(separator: ", ")
            return localizedFormat(
                key: "trip.display-name.place-list",
                defaultValue: "%1$@ & %2$@",
                languageTag: languageTag,
                arguments: [head, parts[parts.count - 1]]
            )
        }
    }

    /// The most places a display fallback names. Three reads as a title;
    /// four reads as a list.
    nonisolated static let curatedDisplayLimit = 3

    /// Visit order, except that with more than `curatedDisplayLimit`
    /// destinations the ones with the most time spent come first (still in
    /// visit order among themselves), so `curatedJoin` shows where the
    /// trip really went: "Renens, Bern & Bellinzona", not the first three
    /// stops. Ties keep visit order. Pure static seam for tests.
    nonisolated static func leadingBySignificance(
        _ names: [String], minutes: [String: Int]
    ) -> [String] {
        guard names.count > curatedDisplayLimit else { return names }
        let ranked = names.enumerated().sorted { lhs, rhs in
            let l = minutes[lhs.element] ?? 0, r = minutes[rhs.element] ?? 0
            if l != r { return l > r }
            return lhs.offset < rhs.offset
        }
        let leading = Set(ranked.prefix(curatedDisplayLimit).map(\.element))
        return names.filter { leading.contains($0) } + names.filter { !leading.contains($0) }
    }

    /// Display-time curation over the persisted `destinationSummary` — the
    /// length discipline FM titles get (≤3 places), for trips that have no
    /// title yet (non-FM devices, and the pre-title window on FM devices).
    /// Like `naturalJoin` this is DISPLAY only, never written back: fallback
    /// titles staying nil IS the title self-heal mechanism.
    ///   - "Unknown" components (un-geocoded stays) are dropped whenever a
    ///     named component exists — mirrors `computeFallbackTitle`'s filter.
    ///     An ALL-Unknown summary renders unchanged (still communicates
    ///     "recorded but not geocoded" rather than a bare "Trip").
    ///   - ≤3 names render exactly like `naturalJoin`.
    ///   - >3 names render only the first three — which `recomputeSummary`
    ///     orders by time spent — with no trailing count: a title, not an
    ///     inventory (the flags and the detail page carry the rest).
    nonisolated static func curatedJoin(_ summary: String) -> String {
        curatedJoin(summary, languageTag: AppLanguagePreference.currentTag())
    }

    nonisolated static func curatedJoin(
        _ summary: String,
        languageTag rawLanguageTag: String
    ) -> String {
        let languageTag = AppLanguagePreference.normalizedSupportedTag(rawLanguageTag) ?? "en"
        var parts = summary
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let named = parts.filter(Self.isUsableDestinationName)
        if !named.isEmpty { parts = named }
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2:
            return localizedFormat(
                key: "trip.display-name.two-places",
                defaultValue: "%1$@ & %2$@",
                languageTag: languageTag,
                arguments: [parts[0], parts[1]]
            )
        default:
            return localizedFormat(
                key: "trip.display-name.three-places",
                defaultValue: "%1$@, %2$@ & %3$@",
                languageTag: languageTag,
                arguments: [parts[0], parts[1], parts[2]]
            )
        }
    }

    /// Explicit catalog-language lookup. `String(localized:locale:)` uses its
    /// locale for interpolation formatting but does not choose a different
    /// bundle localization, which matters in the widget process when the
    /// widget's system language differs from the app's per-app language.
    nonisolated private static func localizedString(
        key: String,
        defaultValue: String,
        languageTag: String
    ) -> String {
        AppLanguagePreference.localizedString(
            key: key,
            defaultValue: defaultValue,
            languageTag: languageTag)
    }

    nonisolated private static func localizedFormat(
        key: String,
        defaultValue: String,
        languageTag: String,
        arguments: [CVarArg]
    ) -> String {
        let format = localizedString(
            key: key,
            defaultValue: defaultValue,
            languageTag: languageTag)
        return String(
            format: format,
            locale: AppLanguagePreference.locale(for: languageTag),
            arguments: arguments)
    }

    /// The trip's ISO country codes in stored order, for `FlagRow`.
    var countryCodeList: [String] {
        countryCodes.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    /// Unique country flag emojis for this trip.
    var countryFlags: String {
        countryCodes
            .split(separator: ",")
            .compactMap { flagEmoji(for: String($0)) }
            .joined(separator: " ")
    }

    /// Type-safe accessor for `sourceRaw`. Reads via `DataSource.decode` so an
    /// unknown raw value (from a future schema) falls back to `.liveSLC`.
    var source: DataSource {
        get { DataSource.decode(sourceRaw) }
        set { sourceRaw = newValue.rawValue }
    }

    init(startDate: Date, source: DataSource = .liveSLC) {
        self.id = UUID()
        self.startDate = startDate
        self.endDate = nil
        self.isComplete = false
        self.destinationSummary = ""
        self.countryCodes = ""
        self.classifiedByAI = false
        self.userEdited = false
        self.stays = []
        self.sourceRaw = source.rawValue
    }

    /// Recompute summary fields from the current stays.
    ///
    /// Derives `destinationSummary`, `countryCodes`, and (since V8)
    /// `sourceRaw` from the trip's constituent stays. Called whenever the
    /// stay list changes (assembleTrips, closeTrip, sanityCheck, trip
    /// merge, user edits in `TripDetailView`, and post-import in
    /// `PingRecorder.recomputeAffectedTripSummaries()`).
    ///
    /// Returns false only for a managed trip whose home-place read failed:
    /// its summary then keeps home-named places, as an unmanaged trip's
    /// does. Units that latch or commit once treat false as a required-read
    /// failure and roll back; interactive and import writers may keep it.
    @discardableResult
    func recomputeSummary() -> Bool {
        let destinationStays = destinations
        let names = summaryNames(of: destinationStays)
        destinationSummary = names.list.joined(separator: ", ")

        // Unique country codes - **destination stays only**. Transit stays
        // are deliberately excluded: a 3-hour layover at FRA on the way to
        // BOS shouldn't make Germany count as "visited" on the trip card,
        // the flag row, or `StatsView.countryStats`.
        // `AppDelegate.runTripCountryCodesRecomputeIfNeeded()` re-derives this
        // for existing trips. Home, routine, and unclassified stays were never
        // in this list. Iterate the ORDERED destinations: the raw relationship
        // order would persist a fetch-order comma string that could differ
        // across devices and diverge from destinationSummary.
        var seenCodes = Set<String>()
        var orderedCodes: [String] = []
        for stay in destinationStays {
            if let code = stay.isoCountryCode, seenCodes.insert(code).inserted {
                orderedCodes.append(code)
            }
        }
        countryCodes = orderedCodes.joined(separator: ",")

        // V8: derive provenance from constituent stays. Trip is
        //   - `.liveSLC` if every stay is `.liveSLC`
        //   - `.photoImport` if every stay is `.photoImport`
        //   - `.merged` otherwise (mixed sources, or any single stay that
        //     is itself `.merged`)
        //
        // Empty trips leave `sourceRaw` at its current value — they
        // shouldn't exist normally, but defaulting to whatever was
        // already there is safer than fabricating a provenance for a
        // trip with no constituent data.
        let allStays = stays ?? []
        if let firstSource = allStays.first?.source {
            let allSame = allStays.allSatisfy { $0.source == firstSource }
            sourceRaw = allSame ? firstSource.rawValue : DataSource.merged.rawValue
        }
        return names.homePlacesRead
    }

    /// The destination names `recomputeSummary` stores, in its order, without
    /// writing them. Nil when the home-place read failed.
    func summaryNames() -> [String]? {
        let names = summaryNames(of: destinations)
        return names.homePlacesRead ? names.list : nil
    }

    /// A stored summary or country list's components, split the way
    /// `curatedJoin` reads them.
    nonisolated static func summaryComponents(_ list: String) -> [String] {
        list.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func summaryNames(of destinationStays: [Stay]) -> (list: [String], homePlacesRead: Bool) {
        Self.summaryNames(of: destinationStays, tripStart: startDate, tripEnd: endDate, in: modelContext)
    }

    /// `recomputeSummary`'s destination names for these destination stays in
    /// trip order, a trip with these dates in `modelContext` would store. A
    /// backup's merged same-id copies name their union with it.
    nonisolated static func summaryNames(
        of destinationStays: [Stay], tripStart: Date, tripEnd: Date?, in modelContext: ModelContext?
    ) -> (list: [String], homePlacesRead: Bool) {
        // Unique destination names in visit order via metro → island →
        // locality, the same granularity as the AI title prompt's
        // `buildGroups` helper, so a city never splits into its districts
        // (Whitechapel and other London districts group under "London"). Stays with
        // nil metro/island fall through to locality.
        //
        // Home-named destinations are left out: the metro is a commuting
        // zone, so a wait at a home-area ferry port reads "Athens" for an Athens
        // resident, and the summary (the title on devices without Apple
        // Intelligence) would say "Aegina & Athens". See
        // `TripTitleStore.homePlaceNames`. A trip with nothing else keeps
        // them: better "Athens" than an empty name. Unmanaged trips (no
        // context yet, e.g. mid-import) keep every name; assembly
        // recomputes them once they are in the store. A temporary home's
        // name stays when most of the trip's destination time is there.
        var homePlacesRead = true
        let homePlaces: Set<String>
        if let modelContext {
            do {
                homePlaces = try TripTitleStore.homePlaceNames(
                    tripStart: tripStart, tripEnd: tripEnd ?? .now,
                    destinations: {
                        destinationStays.map {
                            ($0.placeGroupName ?? Self.unknownDestinationSentinel, $0.durationMinutes)
                        }
                    },
                    in: modelContext)
            } catch {
                homePlaces = []
                homePlacesRead = false
            }
        } else {
            homePlaces = []
        }
        var seenDestinations = Set<String>()
        var orderedDestinations: [String] = []
        var minutesByName: [String: Int] = [:]
        var homeNamed: [String] = []
        for stay in destinationStays {
            let name = stay.placeGroupName
                ?? Self.unknownDestinationSentinel
            if !homePlaces.isEmpty,
               TripTitleStore.isHomePlace(name, isoCountryCode: stay.isoCountryCode, in: homePlaces) {
                if !homeNamed.contains(name) { homeNamed.append(name) }
                continue
            }
            minutesByName[name, default: 0] += stay.durationMinutes
            if seenDestinations.insert(name).inserted {
                orderedDestinations.append(name)
            }
        }
        if orderedDestinations.isEmpty { orderedDestinations = homeNamed }
        return (Self.leadingBySignificance(orderedDestinations, minutes: minutesByName),
                homePlacesRead)
    }
}

// MARK: - Flag Emoji Helper

/// Convert an ISO 3166-1 alpha-2 country code to a flag emoji.
/// Internal visibility - shared by Trip, StatsView, and any other consumer.
nonisolated func flagEmoji(for countryCode: String) -> String? {
    // Length-check the ORIGINAL string too: Unicode case mapping can grow
    // it — "ß".uppercased() == "SS", which would otherwise sail through the
    // post-uppercase checks and render 🇸🇸 for a 1-char garbage input.
    guard countryCode.count == 2 else { return nil }
    let code = countryCode.uppercased()
    // Exactly two ASCII letters. The letter check matters: the Regional
    // Indicator arithmetic below is total over ANY 2-char ASCII input, so
    // without it a corrupt stored code like "12" would render two arbitrary
    // symbols instead of no flag (pinned by FlagEmojiTests).
    guard code.count == 2,
          code.unicodeScalars.allSatisfy({ (65...90).contains($0.value) })
    else { return nil }

    let base: UInt32 = 0x1F1E6 - 65 // Regional Indicator Symbol Letter A minus ASCII 'A'
    let scalars = code.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
        Unicode.Scalar(base + scalar.value)
    }
    guard scalars.count == 2 else { return nil }
    return String(scalars.map { Character($0) })
}

// MARK: - Shared fetch predicates (app + widget)

extension Trip {

    /// Completed trips only — the widget's trip counter and the current-trip
    /// provider's "most recent finished trip" fallback both filter on this.
    /// One factory shared with the tests so provider and app counts can't
    /// drift.
    nonisolated static func completedPredicate() -> Predicate<Trip> {
        #Predicate<Trip> { $0.isComplete == true }
    }
}

// MARK: - Current Trip widget read (app + widget)

extension Trip {

    /// Value snapshot of the trip the Current Trip widget shows. The title
    /// is resolved while the model is still in its context; the provider only
    /// formats dates and the fallback copy.
    nonisolated struct WidgetSnapshot: Sendable, Equatable {
        /// nil for an ongoing trip with no usable name yet; the widget then
        /// shows its own "Traveling" fallback.
        let title: String?
        let countryFlags: String
        let startDate: Date
        let endDate: Date?
        let dayCount: Int
        let isOngoing: Bool
        /// An active temporary home the user is at, not a trip: `startDate`
        /// is its start and `dayCount` the day of the stay.
        var isTemporaryHome = false
        /// A temporary home's stored zone, the one its days are read in.
        /// nil for a trip.
        var timeZoneIdentifier: String? = nil
        /// An ongoing trip's last stay's zone, where its day count changes.
        /// Scheduling only: its dates read in the zones below.
        var dayCountTimeZoneIdentifier: String? = nil
        /// A trip's earliest and latest-ending stays' zones, where its first
        /// and last days are read, as `dayCount` reads them. nil for a
        /// temporary home, or a stay with no zone: the device's then.
        var startDayTimeZoneIdentifier: String? = nil
        var endDayTimeZoneIdentifier: String? = nil

        /// The start day as the widget prints it ("Sep 13"): a temporary
        /// home's in its stored zone, a trip's in its first stay's, else in
        /// the device's.
        func startDayText(locale: Locale) -> String {
            var style = Date.FormatStyle(locale: locale).month().day()
            if let zone = timeZoneIdentifier ?? startDayTimeZoneIdentifier {
                style.timeZone = StayTimeZone.resolve(zone)
            }
            return startDate.formatted(style)
        }

        /// A finished trip's dates as the widget prints them ("Sep 13 to 18"):
        /// each end's civil day in its stay's zone, so they agree with
        /// `dayCount` wherever the device is. nil for an ongoing one.
        func dateRangeText(locale: Locale) -> String? {
            guard let endDate else { return nil }
            let first = TravelDays.label(for: startDate, zone: StayTimeZone.resolve(startDayTimeZoneIdentifier)) ?? startDate
            let last = TravelDays.label(for: endDate, zone: StayTimeZone.resolve(endDayTimeZoneIdentifier)) ?? endDate
            var style = Date.IntervalFormatStyle(locale: locale).month().day()
            style.timeZone = TravelDays.labelCalendar.timeZone
            return DateRangeText.format(first..<max(first, last), style)
        }

        /// When the day count next changes: a minute past the next midnight
        /// of the device's calendar, or of the zone the count is read in
        /// (a temporary home's stored zone, an ongoing trip's last stay's)
        /// when its midnight comes first. A temporary home's end is the last
        /// second of a day in that zone, so this catches it too.
        func nextDayBoundary(after date: Date, deviceCalendar: Calendar = .current) -> Date {
            var calendars = [deviceCalendar]
            if let countingZone = dayCountTimeZoneIdentifier ?? timeZoneIdentifier {
                var stored = Calendar(identifier: .gregorian)
                stored.timeZone = StayTimeZone.resolve(countingZone, fallback: deviceCalendar.timeZone)
                calendars.append(stored)
            }
            let midnights = calendars.compactMap {
                $0.nextDate(after: date, matching: DateComponents(hour: 0, minute: 0, second: 0),
                            matchingPolicy: .nextTime)
            }
            return (midnights.min() ?? date.addingTimeInterval(12 * 3600 - 60)).addingTimeInterval(60)
        }
    }

    /// The newest ongoing trip, else an active temporary home the user is
    /// at, else the newest completed trip, else nil. nil means every read
    /// succeeded and found nothing. Throws when a read fails, and never
    /// reaches the completed trip after a failed earlier read: that would
    /// show a finished trip while the user is traveling or at the temporary
    /// home.
    @MainActor
    static func widgetSnapshot(
        in context: ModelContext, now: Date, languageTag: String
    ) throws -> WidgetSnapshot? {
        var ongoingDescriptor = FetchDescriptor<Trip>(
            predicate: #Predicate<Trip> { $0.isComplete == false },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        ongoingDescriptor.fetchLimit = 1
        try WidgetStoreRead.check(.ongoingTrip)
        if let trip = try context.fetch(ongoingDescriptor).first {
            let first = (trip.stays ?? []).min {
                $0.startTime == $1.startTime ? $0.id.uuidString < $1.id.uuidString : $0.startTime < $1.startTime
            }
            let last = (trip.stays ?? []).max {
                $0.endTime == $1.endTime ? $0.id.uuidString > $1.id.uuidString : $0.endTime < $1.endTime
            }
            let dayCount = min(3_651, inclusiveDays(
                from: trip.startDate, in: StayTimeZone.resolve(first?.timeZoneIdentifier),
                to: now, in: StayTimeZone.resolve(last?.timeZoneIdentifier)))
            return WidgetSnapshot(
                title: trip.hasUsableDisplayName ? trip.displayName(languageTag: languageTag) : nil,
                countryFlags: trip.countryFlags,
                startDate: trip.startDate,
                endDate: nil,
                dayCount: dayCount,
                isOngoing: true,
                dayCountTimeZoneIdentifier: last?.timeZoneIdentifier,
                startDayTimeZoneIdentifier: first?.timeZoneIdentifier
            )
        }

        // A temporary home the user is at outranks the last finished trip:
        // it is active now and recorded the newest home stay in the store
        // (`Stay.temporaryHomeID`, never the nearest centre), so a newer
        // routine or tripless stay near it changes nothing. With no temporary
        // home active now, nothing else is read.
        try WidgetStoreRead.check(.temporaryHomes)
        let temporaryHomes = try HomeAnchors.collapsingTwins(context.fetch(FetchDescriptor<TemporaryHome>()))
        if temporaryHomes.contains(where: { $0.isActive(at: now) }) {
            let homeRaw = StayCategory.home.rawValue
            var latestDescriptor = FetchDescriptor<Stay>(
                predicate: #Predicate<Stay> { $0.categoryRaw == homeRaw },
                sortBy: [SortDescriptor(\.startTime, order: .reverse), SortDescriptor(\.id, order: .reverse)]
            )
            latestDescriptor.propertiesToFetch = [\.startTime, \.temporaryHomeID]
            latestDescriptor.fetchLimit = 1
            try WidgetStoreRead.check(.latestHomeStay)
            // nil is the real Home's; a removed or unsynced id has no live
            // row here. Either falls through to the finished trip.
            if let stay = try context.fetch(latestDescriptor).first,
               let ownerID = stay.temporaryHomeID,
               let base = temporaryHomes.first(where: { $0.id == ownerID }),
               base.isActive(at: now) {
                let zone = StayTimeZone.resolve(base.timeZoneIdentifier)
                return WidgetSnapshot(
                    title: base.displayLabel(locale: AppLanguagePreference.locale(for: languageTag)),
                    countryFlags: base.isoCountryCode.flatMap { flagEmoji(for: $0) } ?? "",
                    startDate: base.startedAt,
                    endDate: nil,
                    dayCount: min(3_651, inclusiveDays(from: base.startedAt, in: zone, to: now, in: zone)),
                    isOngoing: true,
                    isTemporaryHome: true,
                    timeZoneIdentifier: base.timeZoneIdentifier
                )
            }
        }

        var completedDescriptor = FetchDescriptor<Trip>(
            predicate: completedPredicate(),
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        completedDescriptor.fetchLimit = 1
        try WidgetStoreRead.check(.completedTrip)
        if let trip = try context.fetch(completedDescriptor).first {
            let boundary = TravelDays.boundaryStays(of: trip.stays ?? [])
            return WidgetSnapshot(
                title: trip.displayName(languageTag: languageTag),
                countryFlags: trip.countryFlags,
                startDate: trip.startDate,
                endDate: trip.endDate,
                dayCount: trip.durationDays ?? 1,
                isOngoing: false,
                startDayTimeZoneIdentifier: boundary.first?.timeZoneIdentifier,
                endDayTimeZoneIdentifier: boundary.last?.timeZoneIdentifier
            )
        }
        return nil
    }
}
