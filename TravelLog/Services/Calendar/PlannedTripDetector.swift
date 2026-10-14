//
//  PlannedTripDetector.swift
//  TravelLog
//

import Foundation

/// One calendar event judged "probably a trip" by `PlannedTripDetector`,
/// carrying the confidence bucket and the signal tags that fired.
nonisolated struct PlannedTripDetection: Sendable, Equatable {
    let snapshot: CalendarEventSnapshot
    let confidence: PlannedTripConfidence
    let signals: [String]
    /// Forward-geocoded place + home distance; nil until/unless
    /// the scan's resolution pass succeeds for this event.
    let resolved: ResolvedPlannedPlace?
    /// Why `resolved` is absent. A transient/budget/offline miss must preserve
    /// an older trusted resolution; a scored rejection must remove legacy
    /// V1 geography so it can no longer supply `farFromHome` or forecasts.
    let geocodeDisposition: PlannedTripGeocodeDisposition

    init(
        snapshot: CalendarEventSnapshot,
        confidence: PlannedTripConfidence,
        signals: [String],
        resolved: ResolvedPlannedPlace? = nil,
        geocodeDisposition: PlannedTripGeocodeDisposition? = nil
    ) {
        self.snapshot = snapshot
        self.confidence = confidence
        self.signals = signals
        self.resolved = resolved
        self.geocodeDisposition = geocodeDisposition ?? (resolved == nil ? .notAttempted : .accepted)
    }
}

nonisolated enum PlannedTripGeocodeDisposition: String, Sendable, Equatable {
    case notAttempted
    case accepted
    case rejected
}

/// A detection's forward-geocoding outcome, ready for `PlannedTrip`'s
/// `resolved*` fields.
nonisolated struct ResolvedPlannedPlace: Sendable, Equatable {
    let place: ForwardGeocodedPlace
    /// Great-circle distance from the `Home` active at the event's start,
    /// nil when no home exists for that date.
    let distanceFromHomeKm: Double?
}

/// Deterministic, heuristic trip detection over calendar-event snapshots.
/// Pure functions, no EventKit or FM; the ambiguous band is handled separately
/// by `PlannedTripTieBreaker`. Fully unit-testable, like `HexVisibility` and
/// `OnThisDayEngine`.
///
/// Scoring is additive over weighted signals with fixed detection thresholds.
nonisolated enum PlannedTripDetector {

    // MARK: - Signal tags (persisted comma-joined in `PlannedTrip.signalsRaw`)

    static let signalFlightCode = "flightCode"
    static let signalBookingTitle = "bookingTitle"
    static let signalTransitTitle = "transitTitle"
    static let signalBookingKeyword = "bookingKeyword"
    static let signalMultiDay = "multiDay"
    static let signalFarFromHome = "farFromHome"
    static let signalRecurringPenalty = "recurring"
    static let signalSubscribedPenalty = "subscribedCalendar"
    static let signalHolidayCalendarPenalty = "holidayCalendar"
    static let signalHolidayEventPenalty = "holidayEvent"
    static let signalTaskTitlePenalty = "taskTitle"

    // MARK: - Tunables

    /// IATA-style flight designator: airline code (two letters, or letter+digit
    /// combos like U2 / B6 / 9W) + 1–4 digit flight number. Deliberately NOT
    /// `[A-Z]{2}\d+` — alphanumeric airline designators are common. Matched
    /// only when a co-occurring context word (below) also appears, which
    /// suppresses "AA123 budget review"-style false positives.
    ///
    /// Computed (not stored): `Regex` is not `Sendable`, so a `static let`
    /// trips strict concurrency. Rebuilding the literal per evaluation is
    /// noise at calendar-event volumes (hundreds, not millions).
    private static var flightCodeRegex: Regex<(Substring, Substring)> {
        /\b([A-Z]{2}|[A-Z][0-9]|[0-9][A-Z])\s?[0-9]{1,4}\b/
    }

    /// Whole tokens that can establish aviation context near a designator.
    /// Exact token matching avoids accidental substring hits such as
    /// `department` satisfying `depart`.
    private static let flightContextWords: Set<String> = [
        "flight", "fly", "flying", "board", "boarding", "gate", "airport",
        "airline", "terminal", "depart", "departs", "departing", "departure",
        "departures", "arrive", "arrives", "arriving", "arrival", "arrivals", "✈",
    ]

    /// Context that remains decisive even when nearby text contains a generic
    /// reference marker. Arrival/departure alone can describe packages or
    /// projects; these terms are specifically aviation-shaped.
    private static let strongFlightContextWords: Set<String> = [
        "flight", "fly", "flying", "board", "boarding", "gate", "airport",
        "airline", "terminal", "✈",
    ]

    /// Tokens close to a code-like value that identify common non-flight IDs.
    /// They only veto weak arrival/departure context; explicit aviation words
    /// still win (`Flight booking reference BA742`).
    private static let nonFlightReferenceWords: Set<String> = [
        "order", "reference", "ref", "invoice", "case", "project", "budget",
    ]

    /// Maximum token distance between the airline designator and its context.
    /// Four preserves shapes such as `9W 456 to Mumbai flight` while preventing
    /// an unrelated sentence elsewhere in a notes field from vouching for it.
    private static let flightContextWindowTokens = 4

    enum FlightTextField: String, Sendable, Equatable {
        case title
        case location
        case notes
    }

    /// Structured evidence shared by planned-trip scoring and transit
    /// corroboration. Ranges are UTF-16 offsets so diagnostics can identify a
    /// span without retaining calendar text or non-Sendable String indices.
    struct FlightCodeMatch: Sendable, Equatable {
        let field: FlightTextField
        let flightNumber: String
        let airlineDesignator: String
        let contextToken: String
        let codeUTF16Range: Range<Int>
        let contextUTF16Range: Range<Int>
    }

    private struct FlightTextToken {
        let normalized: String
        let range: Range<String.Index>
    }

    /// Gmail/Google Calendar auto-import title shapes are regular and common.
    /// Prefix-matched case-insensitively.
    private static let bookingTitlePrefixes: [String] = [
        "flight to ", "hotel:", "trip to ", "reservation at ", "stay at ",
    ]

    /// Point-to-point transport bookings the user (or an importer) titles by
    /// mode: "Boat: OPERATOR from Cephalonia to Lefkada", "Train: Eurostar …".
    /// Strong signal: these are explicit travel documents. The chainer
    /// (`PlannedTripChainer`) later treats them as transit legs of a journey
    /// rather than standalone destinations.
    private static let transitTitlePrefixes: [String] = [
        "boat:", "ferry:", "train:", "bus:",
    ]

    /// First words that mark a TASK-shaped title — an imperative to-do the
    /// user parked on the calendar ("Cancel Perplexity", "Renew passport",
    /// "Pay rent", "Return library books"). A one-off all-day reminder
    /// scores exactly 1 (multi-day
    /// alone), which is the ambiguous band. The FM tie-breaker handles bare
    /// place-name titles like "Cephalonia" and can misread a proper noun
    /// as a place and mint a medium-confidence card. A verb-first title is
    /// by construction not a bare place name, so these are (a) penalized in
    /// scoring and (b) hard-excluded from the tie-breaker band.
    ///
    /// Exact FIRST-WORD matches (letters-only token), so "Booking.com: …"
    /// ("booking") never collides with "book", and "Checkout at noon" is
    /// untouched by "check" — which is deliberately absent anyway: "Check
    /// in — Hilton" is a genuine travel event. English-only, like the rest
    /// of the detection vocabulary.
    private static let taskVerbFirstWords: Set<String> = [
        "cancel", "cancelled", "canceled", "renew", "renewal", "pay",
        "call", "phone", "email", "text", "message", "submit", "send",
        "return", "buy", "order", "sell", "pick", "drop", "collect",
        "schedule", "reschedule", "remind", "reminder", "sign", "register",
        "file", "review", "finish", "complete", "update", "upgrade",
        "install", "backup", "clean", "fix", "repair", "book",
        "expires", "expiry", "deadline", "due",
    ]

    /// Travel-mode nouns that turn a leading "return" into a NOUN PHRASE,
    /// not an imperative — "Return flight to London" names a travel leg;
    /// "Return library books" is a chore (the bare verb rule alone would
    /// zero code-less return-leg titles from +3 to 0).
    private static let returnTravelNouns: Set<String> = [
        "flight", "flights", "ferry", "ferries", "boat", "train", "bus",
        "trip", "journey", "leg",
    ]

    /// Task NOUN markers: noun-first reminder titles —
    /// "Taxes due", "Passport renewal", "Dentist appointment", "Rent due" —
    /// are the same all-day-reminder shape as the verb-first incident and
    /// reached the FM tie-breaker band through the identical +1 multiDay
    /// path. Any of these words anywhere in the title marks personal admin.
    /// (A bare single noun like "Dentist" is lexically indistinguishable
    /// from a place name without a gazetteer — that residual case is
    /// handled by the hardened tie-breaker instructions instead.)
    private static let taskNounMarkers: Set<String> = [
        "due", "renewal", "expiry", "expires", "deadline", "appointment",
        "checkup", "payment", "bill", "invoice", "reminder", "chore",
        "errand", "taxes",
    ]

    /// True when the title is task-shaped: it BEGINS with a task verb
    /// (imperative to-do) or contains a task-noun marker (noun-first
    /// reminder) — except the "return + travel noun" noun-phrase case and
    /// "Return to <place>" (a destination phrase, not a chore — "Return
    /// library books" has no "to").
    static func isTaskShapedTitle(_ title: String) -> Bool {
        let words = title.split(whereSeparator: { !$0.isLetter }).map { $0.lowercased() }
        guard let first = words.first else { return false }
        if first == "return", words.count >= 2,
           returnTravelNouns.contains(words[1]) || words[1] == "to" {
            return false
        }
        if taskVerbFirstWords.contains(first) { return true }
        return words.contains(where: { taskNounMarkers.contains($0) })
    }

    /// Whether an event may be sent to the FM tie-breaker: it must
    /// sit in the ambiguous band AND not carry a task-shaped title (the
    /// band exists to catch bare place-name titles; a to-do reminder can
    /// never be one, and the small model has proven it will occasionally
    /// read "Cancel Perplexity" as travel). Consumed by the scan; pure and
    /// pinned by tests.
    static func qualifiesForTieBreaker(score: Int, title: String) -> Bool {
        isAmbiguous(score: score) && !isTaskShapedTitle(title)
    }

    /// Substrings of a CALENDAR's title that mark it as a holidays calendar.
    /// Google's built-in holiday calendars ("Holidays in Greece", "US
    /// Holidays") sync over CalDAV — NOT as `.subscription` — so the
    /// subscribed-calendar penalty never fires for them; the calendar title
    /// is the only reliable tell. Penalty, not exclusion: a genuine booking
    /// that somehow lives on such a calendar can still win on strong signals.
    private static let holidayCalendarMarkers: [String] = [
        "holiday", "αργίες",
    ]

    /// Event-text phrases that mark public-holiday/observance entries
    /// (Google stamps these into the notes of auto-shown holiday events —
    /// which would otherwise HIT the "holiday" booking keyword).
    private static let holidayEventPhrases: [String] = [
        "public holiday", "observance", "national holiday", "bank holiday",
    ]

    /// Case-insensitive substring keywords (title, location, and — in-memory
    /// only — notes). The trip-*detection* vocabulary; deliberately a
    /// different list from the trip-*naming* deny-list: "vacation" is
    /// a great detection signal and a terrible trip name.
    private static let bookingKeywords: [String] = [
        "hotel", "hostel", "check-in", "check in", "checkout", "check-out",
        "departure", "boarding", "reservation", "airbnb", "booking.com",
        "itinerary", "vacation", "holiday", "resort", "flight", "cruise",
        "camping", "road trip", "roadtrip", "getaway", "ferry", "ferries",
    ]

    /// Events spanning more than this are weakly trip-like on duration
    /// alone. Internal: the scan's near-miss resolution sweep reuses it as
    /// its worth-geocoding floor.
    static let multiDayThresholdSeconds: TimeInterval = 20 * 60 * 60

    /// Signal 4: an event whose resolved location is at least this
    /// far from the Home active at its date is trip-like even with zero
    /// travel vocabulary. Same order as the trip pipeline's own
    /// distance-from-home semantics; tunable like every threshold here.
    static let farFromHomeThresholdKm: Double = 100

    // Signal weights & bucket cutoffs.
    private static let strongWeight = 4     // flight code, booking title
    private static let mediumWeight = 3     // booking keyword
    private static let weakWeight = 1       // multi-day span
    private static let recurrencePenalty = -3
    private static let subscribedPenalty = -3
    private static let holidayPenalty = -4
    private static let taskTitlePenalty = -3
    private static let highCutoff = 6
    private static let mediumCutoff = 4
    private static let lowCutoff = 2

    // MARK: - API

    /// Scores every snapshot; returns a detection for each event that clears
    /// the low-confidence cutoff. Order-preserving, duplicates untouched —
    /// identity/dedup is the reconciler's job, not the detector's.
    static func detect(in snapshots: [CalendarEventSnapshot]) -> [PlannedTripDetection] {
        snapshots.compactMap { evaluate($0) }
    }

    /// Scores one snapshot. Returns nil for non-detections (score below the
    /// low cutoff, or a hard-excluded calendar kind).
    ///
    /// `distanceFromHomeKm` (signal 4): the resolved location's
    /// distance from the Home active at the event's date, when the scan's
    /// resolution pass produced one. It is the primary signal for events
    /// with zero travel vocabulary — and, unlike the text signals, it does
    /// NOT waive the recurrence penalty: a recurring far-away event is
    /// `RoutinePlace` territory (a weekly client site), exactly what the
    /// penalty exists to suppress.
    static func evaluate(
        _ snapshot: CalendarEventSnapshot,
        distanceFromHomeKm: Double? = nil
    ) -> PlannedTripDetection? {
        guard let (score, signals) = rawScore(snapshot, distanceFromHomeKm: distanceFromHomeKm) else {
            return nil
        }
        let confidence: PlannedTripConfidence
        switch score {
        case highCutoff...: confidence = .high
        case mediumCutoff..<highCutoff: confidence = .medium
        case lowCutoff..<mediumCutoff: confidence = .low
        default: return nil
        }
        return PlannedTripDetection(snapshot: snapshot, confidence: confidence, signals: signals)
    }

    /// True when a raw score sits just below the detection cutoff — the
    /// ambiguous band the FM tie-breaker arbitrates.
    static func isAmbiguous(score: Int) -> Bool {
        score == lowCutoff - 1
    }

    static let signalFMTieBreaker = "fmTieBreaker"

    /// The additive score + fired signal tags, before bucketing. nil only
    /// for hard exclusions (`.birthday`). Internal so the scan can ask
    /// "how close was this?" for tie-breaking.
    static func rawScore(
        _ snapshot: CalendarEventSnapshot,
        distanceFromHomeKm: Double? = nil
    ) -> (score: Int, signals: [String])? {
        // Birthdays calendar entries are never trips; hard exclusion.
        guard snapshot.calendarKind != .birthday else { return nil }

        var score = 0
        var signals: [String] = []

        // The haystack for keyword/context scans. Notes participate here
        // IN MEMORY ONLY — nothing derived from them is persisted beyond
        // the signal tag itself.
        let haystack = [snapshot.title, snapshot.locationText ?? "", snapshot.notes ?? ""]
            .joined(separator: "\n")
        let lowercased = haystack.lowercased()

        // 1. Flight-code pattern, context-gated.
        if flightCodeMatch(in: snapshot) != nil {
            score += strongWeight
            signals.append(signalFlightCode)
        }

        // 2. Auto-generated booking titles.
        let lowercasedTitle = snapshot.title.lowercased()
        if bookingTitlePrefixes.contains(where: { lowercasedTitle.hasPrefix($0) }) {
            score += strongWeight
            signals.append(signalBookingTitle)
        }

        // 2b. Mode-titled transport bookings ("Boat: … from Cephalonia to Lefkada").
        if transitTitlePrefixes.contains(where: { lowercasedTitle.hasPrefix($0) }) {
            score += strongWeight
            signals.append(signalTransitTitle)
        }

        // 3. Booking keyword list (counted once, however many match).
        if bookingKeywords.contains(where: { lowercased.contains($0) }) {
            score += mediumWeight
            signals.append(signalBookingKeyword)
        }

        // 4. Distance from home: medium-strong; the primary
        // signal for keyword-free events with a resolvable location.
        if let distanceFromHomeKm, distanceFromHomeKm >= farFromHomeThresholdKm {
            score += mediumWeight
            signals.append(signalFarFromHome)
        }

        // 5. Multi-day span.
        if snapshot.endDate.timeIntervalSince(snapshot.startDate) > multiDayThresholdSeconds {
            score += weakWeight
            signals.append(signalMultiDay)
        }

        // 6. Recurrence de-weighting: a recurring event whose only virtue is
        // its span is far more likely a routine (`RoutinePlace` territory)
        // than a trip. Waived when a STRONG text signal (1–2) fired — an
        // annual "ski trip" recurrence should surface every year.
        //
        // Signal 3 (a booking KEYWORD anywhere in title + location + notes)
        // waives it only for a MULTI-DAY event. That vocabulary — "check-in",
        // "check in", "holiday", "reservation" — occurs constantly in ordinary
        // recurring work events, so on its own the weakest signal in the table
        // would cancel the penalty designed to suppress exactly those: a
        // weekly "Daily check-in" would score 3, have its -3 waived, clear the
        // low cutoff of 2, and mint a `.low` row for EVERY instance. Duration
        // is what actually separates the two cases — an "Annual ski holiday"
        // spanning a week is a trip; an hour-long recurring "check-in" is not.
        let hasTextSignal = signals.contains(signalFlightCode)
            || signals.contains(signalBookingTitle)
            || (signals.contains(signalBookingKeyword) && signals.contains(signalMultiDay))
        if snapshot.hasRecurrenceRules && !snapshot.isDetached && !hasTextSignal {
            score += recurrencePenalty
            signals.append(signalRecurringPenalty)
        }

        // 7. Subscribed calendars (Holidays, sports fixtures) — strong
        // negative but not a hard exclusion: a shared "trip planning"
        // subscription is a legitimate real case that strong text signals
        // can still push over the line.
        if snapshot.calendarKind == .subscribed {
            score += subscribedPenalty
            signals.append(signalSubscribedPenalty)
        }

        // 8. Holiday-calendar / holiday-event penalties: Google auto-shows
        // public holidays such as "The Restoration of Democracy" from its
        // CalDAV "Holidays in Greece" calendar; the event's "Public holiday"
        // notes hit the `holiday` booking keyword and all-day → multiDay
        // would push it to a medium-confidence card.
        let lowercasedCalendar = snapshot.calendarTitle.lowercased()
        if holidayCalendarMarkers.contains(where: { lowercasedCalendar.contains($0) }) {
            score += holidayPenalty
            signals.append(signalHolidayCalendarPenalty)
        }
        if holidayEventPhrases.contains(where: { lowercased.contains($0) }) {
            score += holidayPenalty
            signals.append(signalHolidayEventPenalty)
        }

        // 9. Task-shaped titles ("Cancel Perplexity", "Renew passport") —
        // to-do reminders parked on the calendar. Penalty, not exclusion,
        // and WAIVED when a strong signal (1-2b) fired: an explicit travel
        // document ("Flight BA123 —
        // check-in deadline", "Trip to Rome + visa appointment") must not
        // be sunk by its own admin vocabulary; keyword-only admin ("Hotel
        // payment due") stays penalized. A bare all-day reminder drops out
        // of both the detection range AND the FM tie-breaker band (see
        // `qualifiesForTieBreaker`).
        let hasStrongSignal = signals.contains(signalFlightCode)
            || signals.contains(signalBookingTitle)
            || signals.contains(signalTransitTitle)
        if !hasStrongSignal && isTaskShapedTitle(snapshot.title) {
            score += taskTitlePenalty
            signals.append(signalTaskTitlePenalty)
        }

        return (score, signals)
    }

    /// Find flight-code evidence without allowing context to cross calendar
    /// fields. Title, location, and notes are scanned independently and in a
    /// deterministic order; the first valid field-local match wins.
    static func flightCodeMatch(in snapshot: CalendarEventSnapshot) -> FlightCodeMatch? {
        let fields: [(FlightTextField, String)] = [
            (.title, snapshot.title),
            (.location, snapshot.locationText ?? ""),
            (.notes, snapshot.notes ?? ""),
        ]
        for (field, text) in fields {
            let allowsDistantContext = field == .title && isExplicitFlightTitle(text)
            if let match = flightCodeMatch(
                in: text,
                field: field,
                allowsDistantContext: allowsDistantContext
            ) {
                return match
            }
        }
        return nil
    }

    private static func flightCodeMatch(
        in text: String,
        field: FlightTextField,
        allowsDistantContext: Bool
    ) -> FlightCodeMatch? {
        let tokens = flightTokens(in: text)
        guard !tokens.isEmpty else { return nil }

        for regexMatch in text.matches(of: flightCodeRegex) {
            let codeRange = regexMatch.range
            let codeTokenIndices = tokens.indices.filter { index in
                tokens[index].range.lowerBound < codeRange.upperBound
                    && tokens[index].range.upperBound > codeRange.lowerBound
            }
            guard !codeTokenIndices.isEmpty else { continue }

            let hasReferenceMarker = tokens.indices.contains { index in
                guard nonFlightReferenceWords.contains(tokens[index].normalized) else { return false }
                let distance = codeTokenIndices.map { abs($0 - index) }.min() ?? .max
                return distance <= 2
            }
            let contextCandidates = tokens.indices.compactMap { index -> (Int, Int, FlightTextToken)? in
                let token = tokens[index]
                guard flightContextWords.contains(token.normalized) else { return nil }
                let distance = codeTokenIndices.map { abs($0 - index) }.min() ?? .max
                guard allowsDistantContext || distance <= flightContextWindowTokens else { return nil }
                guard allowsDistantContext
                        || strongFlightContextWords.contains(token.normalized)
                        || !hasReferenceMarker
                else { return nil }
                return (distance, index, token)
            }.sorted { lhs, rhs in
                lhs.0 != rhs.0 ? lhs.0 < rhs.0 : lhs.1 < rhs.1
            }
            guard let (_, _, contextToken) = contextCandidates.first else { continue }

            let fullCode = String(regexMatch.output.0)
                .replacingOccurrences(of: " ", with: "")
                .uppercased()
            return FlightCodeMatch(
                field: field,
                flightNumber: fullCode,
                airlineDesignator: String(regexMatch.output.1).uppercased(),
                contextToken: contextToken.normalized,
                codeUTF16Range: utf16Range(codeRange, in: text),
                contextUTF16Range: utf16Range(contextToken.range, in: text)
            )
        }
        return nil
    }

    private static func isExplicitFlightTitle(_ text: String) -> Bool {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return title.hasPrefix("flight:") || title.hasPrefix("flight to ")
    }

    private static func utf16Range(
        _ range: Range<String.Index>,
        in text: String
    ) -> Range<Int> {
        let lower = text[..<range.lowerBound].utf16.count
        return lower..<(lower + text[range].utf16.count)
    }

    /// Lightweight Unicode tokenization with source ranges. Calendar flight
    /// vocabulary is ASCII, but ordinary surrounding text need not be.
    private static func flightTokens(in text: String) -> [FlightTextToken] {
        var tokens: [FlightTextToken] = []
        var tokenStart: String.Index?
        var index = text.startIndex

        func flushToken(endingAt end: String.Index) {
            guard let start = tokenStart else { return }
            let range = start..<end
            tokens.append(FlightTextToken(
                normalized: text[range].lowercased(),
                range: range
            ))
            tokenStart = nil
        }

        while index < text.endIndex {
            let next = text.index(after: index)
            let character = text[index]
            let isAlphanumeric = character.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
            }
            if isAlphanumeric {
                if tokenStart == nil { tokenStart = index }
            } else {
                flushToken(endingAt: index)
                if character.unicodeScalars.contains(where: { $0.value == 0x2708 }) {
                    tokens.append(FlightTextToken(normalized: "✈", range: index..<next))
                }
            }
            index = next
        }
        flushToken(endingAt: text.endIndex)
        return tokens
    }

    /// True when the event is specifically a FLIGHT (not merely trip-like):
    /// a context-gated flight code anywhere in its text, or a flight-shaped
    /// title. Used by `TransitInferer` to corroborate `.flight` on legs the
    /// pure geometry heuristic under-detects (short regional hops, airport
    /// detector misses) — a strong, independent signal, so it is deliberately
    /// narrower than trip detection.
    static func isFlightEvent(_ snapshot: CalendarEventSnapshot) -> Bool {
        if flightCodeMatch(in: snapshot) != nil { return true }
        let lowercasedTitle = snapshot.title.lowercased()
        return lowercasedTitle.hasPrefix("flight to ") || lowercasedTitle.hasPrefix("flight:")
    }

    // MARK: - Identity

    /// The composite upsert/dedup key for a detection ↔ `PlannedTrip` row.
    /// `startDate` participates because recurring events expand to many
    /// instances sharing one event identifier; the external identifier
    /// is preferred because it is cross-device-durable for synced accounts.
    /// The calendar date an instant RENDERS as in `timeZone`, as `yyyy-MM-dd`.
    ///
    /// The one place all-day "which day is this?" is decided, used
    /// both for the identity key and for deciding whether a synced row's
    /// stored instants actually need refreshing.
    static func renderedDayKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
        )
    }

    /// - Parameter timeZone: the zone the all-day instant was RENDERED in —
    ///   i.e. the device's own zone in production. Injectable so a test can
    ///   model several devices honestly; a single test process has one
    ///   `TimeZone.current`, so without this the cross-device case cannot be
    ///   expressed at all.
    static func identityKey(
        externalIdentifier: String?,
        localIdentifier: String,
        startDate: Date,
        isAllDay: Bool,
        timeZone: TimeZone = .current
    ) -> String {
        let id = externalIdentifier ?? localIdentifier
        if isAllDay {
            // Read the RENDERED calendar date in the device's own timezone
            // rather than doing instant arithmetic. EventKit renders a
            // floating all-day event's midnight in the CURRENT zone, so every
            // device sees the same intended y/m/d when it asks its own
            // calendar — whereas instant arithmetic with a noon bias is exact
            // only for offsets ≤ +12. No additive bias can fix that: across
            // offsets −12…+14 the rendered instant spans 26 hours, which
            // cannot collapse into a single UTC day. At +13/+14 (Samoa, Tonga,
            // NZ in DST, Kiribati) and exactly −12, two synced devices would
            // compute DIFFERENT keys for one event — minting duplicate rows,
            // and giving `PlannedTripDeduplicator` two survivors to fight over.
            return "\(id)|d:\(renderedDayKey(startDate, timeZone: timeZone))"
        }
        // Whole seconds, not the raw Double: the Double's
        // shortest-round-trip description would make the key hostage to
        // sub-second noise in what EventKit hands back — the same instance
        // could mint two keys across scans or devices. Calendar events carry
        // whole-second precision, so truncation is lossless.
        return "\(id)|\(Int(startDate.timeIntervalSinceReferenceDate.rounded()))"
    }

    static func identityKey(
        for snapshot: CalendarEventSnapshot,
        timeZone: TimeZone = .current
    ) -> String {
        identityKey(
            externalIdentifier: snapshot.externalIdentifier,
            localIdentifier: snapshot.localIdentifier,
            startDate: snapshot.startDate,
            isAllDay: snapshot.isAllDay,
            timeZone: timeZone
        )
    }
}

// MARK: - Matching planned trips to real trips

/// Deterministic correlation of a `PlannedTrip`'s date range to real `Trip`s
/// — pure functions so two devices computing the match independently agree
/// (the same requirement every dedup convergence rule here satisfies).
nonisolated enum PlannedTripMatcher {

    /// Sendable slice of a real `Trip` (the `TripSnapshot` discipline —
    /// `@Model`s never cross into scoring code).
    struct TripCandidate: Sendable, Equatable {
        let id: UUID
        let startDate: Date
        let endDate: Date?   // nil = ongoing

        init(id: UUID, startDate: Date, endDate: Date?) {
            self.id = id
            self.startDate = startDate
            self.endDate = endDate
        }
    }

    /// Slack applied to the planned window before computing overlap — a
    /// flight that lands after midnight or a day-early departure shouldn't
    /// miss the match.
    private static let slackSeconds: TimeInterval = 24 * 60 * 60

    /// A candidate must cover at least this fraction of the shorter of the
    /// two ranges (planned vs. trip) to count as a match.
    private static let minOverlapFraction: Double = 0.5

    /// The best-matching trip for a planned date range, or nil when nothing
    /// clears the overlap bar. Ties break on (overlap desc, |start-date
    /// proximity| asc, `id.uuidString` asc) — a strict total order, so the
    /// result is device-independent.
    static func bestMatch(
        plannedStart: Date,
        plannedEnd: Date,
        candidates: [TripCandidate],
        now: Date
    ) -> UUID? {
        let windowStart = plannedStart.addingTimeInterval(-slackSeconds)
        let windowEnd = plannedEnd.addingTimeInterval(slackSeconds)
        guard windowStart < windowEnd else { return nil }
        let plannedDuration = plannedEnd.timeIntervalSince(plannedStart)

        var best: (overlap: TimeInterval, startGap: TimeInterval, uuid: String, id: UUID)?
        for candidate in candidates {
            let tripEnd = candidate.endDate ?? now
            guard candidate.startDate < tripEnd else { continue }

            let overlap = min(windowEnd, tripEnd).timeIntervalSince(max(windowStart, candidate.startDate))
            guard overlap > 0 else { continue }

            let tripDuration = tripEnd.timeIntervalSince(candidate.startDate)
            let shorter = max(min(plannedDuration, tripDuration), 1)
            guard overlap / shorter >= minOverlapFraction else { continue }

            let startGap = abs(candidate.startDate.timeIntervalSince(plannedStart))
            let key = (overlap: overlap, startGap: startGap, uuid: candidate.id.uuidString, id: candidate.id)
            if let current = best {
                if key.overlap > current.overlap
                    || (key.overlap == current.overlap && key.startGap < current.startGap)
                    || (key.overlap == current.overlap && key.startGap == current.startGap
                        && key.uuid < current.uuid) {
                    best = key
                }
            } else {
                best = key
            }
        }
        return best?.id
    }
}
