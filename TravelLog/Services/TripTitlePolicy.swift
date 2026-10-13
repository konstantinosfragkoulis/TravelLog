//
//  TripTitlePolicy.swift
//  TravelLog
//

import Foundation

/// The value-only half of canonical trip titles: how a title is composed,
/// spelled and cleaned up. It reads no model, context or defaults, so the
/// classifier keeps every storage read and write and callers test it directly.
nonisolated enum TripTitlePolicy {

    /// Strip cosmetic wrapping that the model sometimes adds despite being
    /// told not to. Trims whitespace, surrounding ASCII quotes (`"`, `'`),
    /// curly quotes (`“`, `”`, `‘`, `’`), markdown emphasis (`*`, `_`),
    /// and a single leading/trailing period.
    static func normalizeAITitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip surrounding quote-class characters in a tight loop so
        // nested wrapping (`""White Plains""` or `"*White Plains*"`) is unwound.
        let stripChars: Set<Character> = [
            "\"", "'", "“", "”", "‘", "’", "*", "_", "`"
        ]
        while let first = s.first, stripChars.contains(first) {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while let last = s.last, stripChars.contains(last) {
            s.removeLast()
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Strip a single trailing period (the model occasionally appends
        // one despite the "no punctuation" rule).
        if s.hasSuffix(".") {
            s = String(s.dropLast())
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    /// Format up to three selected places; a full name and its permitted abbreviation count as one destination.
    static func composeTitle(places: [String]) -> String {
        var seen = Set<String>()
        var names: [String] = []
        for raw in places {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(titleDedupeKey(name)).inserted else { continue }
            names.append(name)
            if names.count == 3 { break }
        }
        guard !names.isEmpty else { return "" }
        switch names.count {
        case 1: return names[0]
        case 2: return "\(names[0]) & \(names[1])"
        default: return "\(names[0]), \(names[1]) & \(names[2])"
        }
    }

    /// The spelling a canonical title stores for a place: its display name
    /// in the geocoder's stored form (`toLatinAscii`: Latin, diacritics
    /// stripped, letters such as ø and ł kept), so "Tromsø" stays Tromsø
    /// and an imported "Σύρος" becomes Syros. The prompt and decode
    /// grammar use the ASCII `toLatinAsciiStrict` spelling instead.
    static func canonicalTitleSpelling(_ displayName: String) -> String {
        displayName.toLatinAscii
    }

    /// `composeTitle` over the model's chosen places in stored spelling:
    /// each chosen prompt candidate becomes the `titleSpellings` entry at its
    /// position (`Tromso` → `Tromsø`). When two places share one prompt
    /// spelling the better-ranked one wins, as in the grammar; a choice that
    /// is no candidate (the NYC and LA abbreviations) passes through.
    static func composeCanonicalTitle(
        places: [String],
        candidates: [String],
        titleSpellings: [String]
    ) -> String {
        var spelling: [String: String] = [:]
        for (candidate, stored) in zip(candidates, titleSpellings) {
            let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if spelling[key] == nil { spelling[key] = stored }
        }
        return composeTitle(places: places.map { place in
            spelling[place.trimmingCharacters(in: .whitespacesAndNewlines)] ?? place
        })
    }

    /// The abbreviations the instructions and the validator both allow,
    /// folded onto the full name so `composeTitle` never lists a place
    /// twice under two spellings.
    private static func titleDedupeKey(_ name: String) -> String {
        switch name.lowercased() {
        case "nyc", "ny": return "new york"
        case "la": return "los angeles"
        case let other: return other
        }
    }

    /// Same shape as `Stay.formattedDuration` but works on a raw minute
    /// count (used by the title prompt's grouped duration display).
    static func formattedMinutes(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 {
            return remainingMinutes > 0 ? "\(hours)h \(remainingMinutes)m" : "\(hours)h"
        }
        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours > 0 ? "\(days)d \(remainingHours)h" : "\(days)d"
    }

    /// Keep instructions focused on selecting ranked candidates; filtering, grouping, and TripTitleSchema enforce eligible vocabulary.
    static let titleInstructions = """
        You choose the title of a trip for a personal travel diary.

        The prompt lists the places the trip visited, the place with the most \
        time first.

        Return places: one to three names from the top of the list, copied \
        exactly. One name when the trip has one place, both when it has two, \
        all three when it has three, only the first two or three when it has \
        more.

        Never add a place, region, or country that is not in the list.
        """

    /// Rejection fragments complete the same-session retry prompt; nil from validation means success.
    /// A pure seam, so validation is testable without crossing actor boundaries.
    nonisolated enum ValidationFailure: Equatable {
        case empty
        case tooShort
        case tooLong
        case containsErrorWord(String)
        case multiLine
        case tooManyWords(Int)
        case forbiddenCountryWord(String)
        case ungroundedWord(String)
        case noGroundedWord(String)
        /// Grounded place words can still omit the time-dominant place, which needs a distinct rejection reason.
        case missingTopPlace(String)
        /// A word naming the user's home area — a home-named stay the
        /// prompt deliberately left out (`TripTitleStore.homePlaceNames`).
        case homePlaceWord(String)

        /// A phrase completing "…was rejected because it <fragment>."
        var promptFragment: String {
            switch self {
            case .empty:
                return "was empty"
            case .tooShort:
                return "was too short — a title needs at least 2 characters"
            case .tooLong:
                return "was too long — keep it under 60 characters"
            case .containsErrorWord(let word):
                return "contained the word \"\(word)\", which reads like an error leak, not a place — write a real place-based title"
            case .multiLine:
                return "spanned more than one line — write a single-line title"
            case .tooManyWords(let count):
                return "had too many words (\(count)) — use at most 8"
            case .forbiddenCountryWord(let word):
                return "used the word \"\(word)\", which is a country name — use ONLY the place names listed in the prompt, never the country"
            case .ungroundedWord(let word):
                return "used the word \"\(word)\", which is not the name of any place you visited — pick ONLY from the places listed in the prompt"
            case .noGroundedWord(let title):
                return "(\"\(title)\") named only generic regions or descriptors with NONE of this trip's actual destinations — include at least one of the places listed in the prompt"
            case .missingTopPlace(let place):
                return "left out \"\(place)\", the place with the most time on this trip, include it alongside the other places named"
            case .homePlaceWord(let word):
                return "used the word \"\(word)\", which names the user's home area — home is never a destination; use ONLY the places listed in the prompt"
            }
        }
    }
}
