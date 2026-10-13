import Foundation

/// Checks place-only titles without guessing unfamiliar English aliases.
/// Full phrase coverage is required on BOTH sides before comparing places.
nonisolated enum LocalizedTitlePlaceVerifier {
    struct Reference: Sendable {
        fileprivate let phrases: [Phrase]
        fileprivate let places: Set<String>
    }

    fileprivate struct Phrase: Sendable {
        let words: [String]
        let identity: String?
    }

    enum Verdict: Equatable, Sendable {
        case match
        case mismatch(missing: [String], added: [String])
        /// This title cannot be compared using the captured vocabulary.
        /// It says nothing about model availability or other queued trips.
        case unavailable
    }

    static func reference(
        sourceTitle: String, snapshot: TripTitleStore.SemanticSnapshot
    ) -> Reference? {
        var names = Set<String>()
        var canonicalIdentities: [String: String] = [:]
        var ambiguousNames = Set<String>()
        for stay in snapshot.stays {
            // A metro and its locality are different names, not aliases.
            for name in [stay.metroName, stay.islandName, stay.locality,
                         stay.administrativeArea, stay.country].compactMap({ $0 }) {
                guard let nativeWords = words(in: name), !nativeWords.isEmpty else { continue }
                let native = nativeWords.joined(separator: " ")
                // Title candidates use the strict transform and canonical
                // titles store `canonicalTitleSpelling`, both deterministic,
                // including for imported non-Latin stay names ("Tverʹ" for
                // Тверь). Keep every spelling as one place, without guessing
                // exonyms.
                let canonicalWords = words(in: name.toLatinAsciiStrict) ?? []
                let canonical = canonicalWords.isEmpty ? native : canonicalWords.joined(separator: " ")
                let storedWords = words(in: TripClassifier.canonicalTitleSpelling(name)) ?? []
                let stored = storedWords.isEmpty ? native : storedWords.joined(separator: " ")
                names.formUnion([native, stored, canonical])
                let placeIdentity = identity(canonical)
                for alias in [native, stored, canonical] {
                    if let existing = canonicalIdentities[alias], existing != placeIdentity {
                        ambiguousNames.insert(alias)
                    } else {
                        canonicalIdentities[alias] = placeIdentity
                    }
                }
            }
        }
        // Only the abbreviation families already accepted by composeTitle.
        if !names.isDisjoint(with: ["new york", "nyc", "ny"]) {
            names.formUnion(["new york", "nyc", "ny"])
        }
        if !names.isDisjoint(with: ["los angeles", "la"]) {
            names.formUnion(["los angeles", "la"])
        }
        let phrases = names.map { name in
            Phrase(words: name.components(separatedBy: " "),
                   identity: ambiguousNames.contains(name) ? nil : canonicalIdentities[name] ?? identity(name))
        }.sorted {
            if $0.words.count != $1.words.count { return $0.words.count > $1.words.count }
            return $0.words.joined(separator: " ") < $1.words.joined(separator: " ")
        }
        guard let places = parse(sourceTitle, phrases: phrases) else { return nil }
        return Reference(phrases: phrases, places: places)
    }

    static func compare(englishTitle: String, reference: Reference) -> Verdict {
        // Unknown aliases or leftover meaning are inconclusive, even if an
        // already-recognized name would otherwise appear to be missing.
        guard let actual = parse(englishTitle, phrases: reference.phrases) else { return .unavailable }
        let missing = reference.places.subtracting(actual).sorted()
        let added = actual.subtracting(reference.places).sorted()
        return missing.isEmpty && added.isEmpty ? .match : .mismatch(missing: missing, added: added)
    }

    private static func parse(_ title: String, phrases: [Phrase]) -> Set<String>? {
        guard let tokens = words(in: title), !tokens.isEmpty else { return nil }
        var places = Set<String>()
        var offset = 0
        while offset < tokens.count {
            guard let phrase = phrases.first(where: {
                offset + $0.words.count <= tokens.count
                    && Array(tokens[offset..<(offset + $0.words.count)]) == $0.words
            }), let identity = phrase.identity,
                  places.insert(identity).inserted else { return nil }
            offset += phrase.words.count
            if offset == tokens.count { break }
            // A separator belongs BETWEEN complete places. Never discard
            // leading/trailing/repeated connectors or join adjacent phrases.
            guard ["and", "&", ",", ";", "/"].contains(tokens[offset]) else { return nil }
            let separator = tokens[offset]
            offset += 1
            // An Oxford comma is one boundary, not an empty list member.
            // Consume only this precise pair; &&, ,&, and repeated conjunctions
            // still cannot stand in place of a complete place phrase.
            if separator == ",", offset < tokens.count, tokens[offset] == "and" {
                offset += 1
            }
            guard offset < tokens.count else { return nil }
        }
        return places.isEmpty ? nil : places
    }

    static func hasCompleteListBoundaries(_ title: String, languageTag: String) -> Bool {
        TripTitleStore.hasCompleteListBoundaries(title, languageTag: languageTag)
    }

    /// Short proper names do not admit reliable language identification.
    /// Require native script where the target normally uses one; an all-Latin
    /// ambiguous answer falls back to the canonical title instead of being
    /// stored as a verified translation. This is not a language-quality proof.
    static func hasExpectedScript(_ title: String, languageTag: String) -> Bool {
        let ranges: [ClosedRange<UInt32>]
        switch languageTag {
        case "el": ranges = [0x0370...0x03FF, 0x1F00...0x1FFF]
        case "ja": ranges = [0x3040...0x30FF, 0x3400...0x9FFF]
        case "ko": ranges = [0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF]
        case "zh-Hans", "zh-Hant": ranges = [0x3400...0x9FFF]
        default: return true
        }
        return title.unicodeScalars.contains { scalar in ranges.contains { $0.contains(scalar.value) } }
    }

    private static func identity(_ name: String) -> String {
        switch name {
        case "ny", "nyc": return "new york"
        case "la": return "los angeles"
        default: return name
        }
    }

    private static func words(in text: String) -> [String]? {
        let normalized = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                      locale: Locale(identifier: "en_US_POSIX"))
        // Spaces and common title/name punctuation separate words. Unfamiliar
        // symbols remain inconclusive rather than disappearing from coverage.
        let separators = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "&,;/'’‘\"“”-.‐‑–—()"))
        var words: [String] = []
        var current = ""
        for scalar in normalized.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if separators.contains(scalar) {
                if !current.isEmpty { words.append(current); current = "" }
                // List boundaries cannot weld "New & York" into "New York".
                if "&,;/".unicodeScalars.contains(scalar) { words.append(String(scalar)) }
            } else {
                return nil
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
