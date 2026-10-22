//
//  CalendarTripNaming.swift
//  TravelLog
//

import Foundation

/// Picks the calendar event most suitable to describe a stay for the Stage-2
/// classification prompt (`TripClassifier.classificationHints`) — a
/// different question from "is this event a trip" (`PlannedTripDetector`),
/// with a deliberately opposite vocabulary: "vacation" is a great *detection*
/// signal and a useless *description*, so it sits on the deny-list here while
/// boosting scores there. Keep the two lists literally separate.
///
/// This is the calendar's role in past-trip classification. Titles take no
/// calendar input: a title
/// says where, and the 3B model cannot read most calendars. Nothing here is
/// persisted and nothing here reaches a title.
///
/// Pure functions over snapshots — unit-testable without an `EKEventStore`.
nonisolated enum CalendarTripNaming {

    /// Whole-title (normalized) deny-list: boilerplate that describes
    /// nothing. Compared against the ENTIRE normalized title, so "OOO —
    /// Lisbon" survives while a bare "OOO" is denied.
    static let genericTitles: Set<String> = [
        "busy", "ooo", "out of office", "vacation", "holiday", "holidays",
        "pto", "travel", "trip", "flight", "hotel", "away", "off",
        "annual leave", "leave", "day off", "free", "tentative", "reminder",
    ]

    /// A candidate must clear this to be offered as prompt context at all —
    /// a short unrelated event that merely overlaps the stay scores ~1 and
    /// stays out; coverage or a place match is required.
    static let minimumScore: Double = 1.5

    /// The best candidate's title (trimmed, capped), or nil when no
    /// overlapping event is suitable. Route paperwork ("Athens - Aegina
    /// ferry") is kept on purpose: it is genuine classification evidence.
    static func bestCandidate(
        events: [CalendarEventSnapshot],
        tripStart: Date,
        tripEnd: Date,
        tripPlaceNames: [String]
    ) -> String? {
        // `TripTitleStore.normalizedPlaceName` transliterates as well as
        // folding, so a Greek "Σύρος" location meets the geocoder's "Syros".
        let normalizedPlaces = tripPlaceNames
            .map(TripTitleStore.normalizedPlaceName)
            .filter { !$0.isEmpty }

        let ranked = events
            .compactMap { event -> (score: Double, event: CalendarEventSnapshot)? in
                guard let score = namingScore(
                    event, tripStart: tripStart, tripEnd: tripEnd,
                    normalizedPlaces: normalizedPlaces
                ) else { return nil }
                return (score, event)
            }
            .sorted { a, b in
                // Deterministic: score desc, then earlier start, then id.
                if a.score != b.score { return a.score > b.score }
                if a.event.startDate != b.event.startDate { return a.event.startDate < b.event.startDate }
                return a.event.localIdentifier < b.event.localIdentifier
            }

        guard let best = ranked.first, best.score >= minimumScore else { return nil }
        let title = best.event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(title.prefix(80))
    }

    /// Suitability score for one event, nil when disqualified.
    /// Signals: non-recurring beats recurring; span coverage of
    /// the window; event text agreeing with the stay's own place names.
    static func namingScore(
        _ event: CalendarEventSnapshot,
        tripStart: Date,
        tripEnd: Date,
        normalizedPlaces: [String]
    ) -> Double? {
        guard tripEnd > tripStart else { return nil }
        // Birthday-calendar events describe a person, not a stay:
        // "Γιάννης's birthday" must not caption a vacation that merely
        // overlapped it.
        guard event.calendarKind != .birthday else { return nil }
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        guard !genericTitles.contains(PlannedTripChainer.normalized(title)) else { return nil }
        // Point-to-point transport bookings ("Boat: … from A to B") carry a
        // route; the hint reads better from the stay itself.
        guard !PlannedTripChainer.isTransitLeg(title: title) else { return nil }

        let overlap = min(event.endDate, tripEnd)
            .timeIntervalSince(max(event.startDate, tripStart))
        guard overlap > 0 else { return nil }

        let location = event.locationText ?? ""
        let titlePlaces = matchedPlaces(in: title, among: normalizedPlaces)
        let locationPlaces = matchedPlaces(in: location, among: normalizedPlaces)

        var score = 1.0
        if event.hasRecurrenceRules && !event.isDetached {
            // A weekly "Book Club" that happens to overlap must not outrank
            // a one-off "Sarah's Wedding".
            score *= 0.3
        }
        // Multi-day span covering most of the window beats a single-instant
        // event.
        score += 2.0 * min(1.0, overlap / tripEnd.timeIntervalSince(tripStart))
        // Event text naming a place the stay is at raises confidence
        // sharply (a wedding's venue city, "Oktoberfest München").
        if !titlePlaces.isEmpty || !locationPlaces.isEmpty {
            score += 2.0
        }
        return score
    }

    /// The normalized place names `text` contains as WHOLE phrases: "York"
    /// is not in "New York", "Cephalonia" is in "a venue, Cephalonia", and
    /// "Saint-Tropez" meets "Saint Tropez". Both sides transliterate.
    static func matchedPlaces(in text: String, among normalizedPlaces: [String]) -> Set<String> {
        let textTokens = placeTokens(text)
        guard !textTokens.isEmpty else { return [] }
        var matched = Set<String>()
        for place in normalizedPlaces {
            let wanted = placeTokens(place)
            guard !wanted.isEmpty, wanted.count <= textTokens.count else { continue }
            for start in 0...(textTokens.count - wanted.count)
            where Array(textTokens[start..<start + wanted.count]) == wanted {
                matched.insert(place)
                break
            }
        }
        return matched
    }

    private static func placeTokens(_ text: String) -> [String] {
        TripTitleStore.normalizedPlaceName(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
