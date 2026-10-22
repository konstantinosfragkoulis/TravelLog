//
//  TripTitlePolicy+LegacySpelling.swift
//  TravelLog
//

import Foundation

nonisolated extension TripTitlePolicy {

    /// Whether a title can hold the retired prompt spelling at all: that
    /// transform only ever produced printable ASCII.
    static func mayHoldLegacySpelling(_ title: String) -> Bool {
        !title.isEmpty && title.unicodeScalars.allSatisfy(\.isASCII)
    }

    /// A stored title with a visited place in the retired prompt spelling,
    /// rewritten in stored spelling (`canonicalTitleSpelling`), or nil when
    /// it has none. That transform deleted letters with no ASCII
    /// decomposition ("Troms" for Tromsø, "Wrocaw" for Wrocław, "SaintJean"
    /// for Saint‑Jean), and such titles still arrive from backups and older
    /// devices. Grounding cannot catch them all: a region can own the
    /// shortened word (Tromsø lies in Troms). Only the trip's own place names
    /// are matched, as whole words, so a trip whose stays have not arrived
    /// has nothing to rewrite yet; a spelling that is also a run of words in
    /// one of those names is left alone. Spelling only: callers still apply
    /// the title policy to the result. `placeNames` holds the trip's distinct
    /// metro, island and locality names in `Trip.orderedStays` order.
    static func legacyTitleSpellingRepair(_ title: String, placeNames names: [String]) -> String? {
        guard mayHoldLegacySpelling(title) else { return nil }
        var respellings: [(legacy: String, legacyWords: [String], stored: String)] = []
        for name in names where name.unicodeScalars.contains(where: { !$0.isASCII }) {
            let legacy = legacyPromptSpelling(name)
            guard !legacy.isEmpty, title.range(of: legacy, options: .caseInsensitive) != nil else { continue }
            let legacyWords = placeWords(legacy)
            guard !legacyWords.isEmpty, legacyWords != placeWords(name) else { continue }
            respellings.append((legacy, legacyWords, canonicalTitleSpelling(name)))
        }
        guard !respellings.isEmpty else { return nil }
        let currentNames = names.map { placeWords($0) }
        var repaired = title
        for respelling in respellings.sorted(by: { $0.legacy.count > $1.legacy.count }) {
            let isCurrentWordRun = currentNames.contains { containsRun(respelling.legacyWords, in: $0) }
            guard !isCurrentWordRun else { continue }
            repaired = replacingWholeWords(respelling.legacy, with: respelling.stored, in: repaired)
        }
        return repaired == title ? nil : repaired
    }

    private static func containsRun(_ run: [String], in words: [String]) -> Bool {
        guard !run.isEmpty, words.count >= run.count else { return false }
        for start in 0...(words.count - run.count)
        where Array(words[start ..< start + run.count]) == run {
            return true
        }
        return false
    }

    /// The retired `toLatinAsciiStrict`, kept only to recognize titles
    /// written in it: `toLatinAscii` with whitespace runs as one space and
    /// every other scalar outside printable ASCII deleted.
    private static func legacyPromptSpelling(_ name: String) -> String {
        var result = String.UnicodeScalarView()
        var previousWasWhitespace = false
        for scalar in name.toLatinAscii.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !previousWasWhitespace {
                    result.append(" ")
                    previousWasWhitespace = true
                }
                continue
            }
            guard scalar.value >= 0x21, scalar.value <= 0x7E else { continue }
            result.append(scalar)
            previousWasWhitespace = false
        }
        return String(result).trimmingCharacters(in: .whitespaces)
    }

    /// Every case-insensitive occurrence of `target` with no letter on
    /// either side, replaced.
    private static func replacingWholeWords(
        _ target: String, with replacement: String, in text: String
    ) -> String {
        var result = ""
        var cursor = text.startIndex
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: target, options: .caseInsensitive,
                                     range: searchStart..<text.endIndex) {
            let letterBefore = range.lowerBound > text.startIndex
                && text[text.index(before: range.lowerBound)].isLetter
            let letterAfter = range.upperBound < text.endIndex && text[range.upperBound].isLetter
            if letterBefore || letterAfter {
                searchStart = text.index(after: range.lowerBound)
                continue
            }
            result += text[cursor..<range.lowerBound]
            result += replacement
            cursor = range.upperBound
            searchStart = range.upperBound
        }
        result += text[cursor...]
        return result
    }
}
