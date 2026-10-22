//
//  TripSearch.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 22/5/26.
//

import Foundation
import os

/// Local trip search, no dependencies on SwiftData / SwiftUI.
///
/// The engine lives in `TripSearchDocument.swift`: documents normalized once,
/// an inverted `TripSearchIndex`, tiered and gated matching with a strength
/// per trip. This type holds its entry points (`terms`, `match`, `matches`,
/// `spellingSuggestion`) and the shared normalization and alias helpers.
/// `TripQueryParser.searchTrips(index:...)` layers dates, durations and the
/// partial fallback on top; `TripSearchIndexStore` builds documents from
/// trips.
///
/// # AI fallback
///
/// When local search finds no strong or similar match AND the query is non-trivial,
/// `TripsListView` invokes `TripSearchAI.search(...)`, which uses Foundation
/// Models tool calling to translate the natural-language query into a
/// structured filter and runs it against the same dataset. That path is in
/// `TripSearchAI.swift` (which co-locates `SearchTripsTool`).
enum TripSearch {

    nonisolated static let normalizedFormsCache = OSAllocatedUnfairLock(
        initialState: [String: [String]]())

    /// Every title users may have seen for the current canonical source.
    /// A custom name intentionally hides generated aliases; otherwise the
    /// current display, canonical English title, and each valid cached
    /// language variant stay searchable across language switches.
    nonisolated static func titleAliases(
        for trip: Trip,
        languageTag: String = AppLanguagePreference.currentTag()
    ) -> [String] {
        if let custom = TripTitleStore.normalized(trip.customName) {
            return [custom]
        }

        var values = [trip.displayName(languageTag: languageTag)]
        if let canonical = TripTitleStore.normalized(trip.aiGeneratedTitle) {
            values.append(canonical)
            for tag in AppLanguagePreference.supportedTags.sorted()
                where tag != "en" {
                if let title = TripTitleStore.localizedTitle(
                    for: trip,
                    languageTag: tag) {
                    values.append(title)
                }
            }
        }
        return uniqueNonempty(values)
    }

    /// ISO code, English and app-language region names, and the curated
    /// aliases (`uk`, `turkey`, `holland`); "&" names also spelled with
    /// "and". Names in other languages are recognized on the query side.
    nonisolated static func countryAliases(
        for rawCodes: [String],
        languageTag: String = AppLanguagePreference.currentTag()
    ) -> [String] {
        var values: [String] = []
        for rawCode in rawCodes {
            let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard !code.isEmpty else { continue }
            values.append(code)
            if let name = TripSearchAliases.countryName(code, languageTag: languageTag, english: true) {
                values.append(name)
                if name.contains("&") {
                    values.append(name.replacingOccurrences(of: "&", with: "and"))
                }
            }
            if let name = TripSearchAliases.countryName(code, languageTag: languageTag) {
                values.append(name)
            }
            values.append(contentsOf: TripSearchAliases.countryAliases[code] ?? [])
        }
        return uniqueNonempty(values)
    }

    /// Native, Latin and (for Greek) UNGEGN search forms, see
    /// `TripSearchText.forms`. The same transform is applied to query and
    /// corpus, so `Ελλάδα`, `Ellada` and `Tromso` find their stored names
    /// without replacing the native-script form. ASCII input bypasses the memo.
    nonisolated static func normalizedSearchForms(_ value: String) -> [String] {
        if value.utf8.allSatisfy({ $0 < 0x80 }) { return TripSearchText.forms(value) }
        if let forms = normalizedFormsCache.withLock({ $0[value] }) { return forms }
        let forms = TripSearchText.forms(value)
        normalizedFormsCache.withLock { cache in
            if cache.count >= 4096 { cache.removeAll(keepingCapacity: true) }
            cache[value] = forms
        }
        return forms
    }

    /// Raw display strings plus their normalized native and Latin forms for
    /// external indexes whose tokenizer/transliteration behavior is not part
    /// of our contract (Core Spotlight, Siri entity keywords).
    nonisolated static func searchVocabulary(_ values: [String]) -> [String] {
        uniqueNonempty(values.flatMap { [$0] + normalizedSearchForms($0) })
    }

    /// The engine over one document whose single `place` field is `parts`.
    /// True for strong or similar. An empty query matches; a non-empty query
    /// that yields no terms (only symbols or emoji) does not.
    nonisolated static func matches(
        query: String,
        in parts: [String],
        languageTag: String = AppLanguagePreference.currentTag()
    ) -> Bool {
        strength(query: query, in: parts, languageTag: languageTag) != nil
    }

    /// True for strong or similar; empty terms match.
    nonisolated static func matches(
        terms: [TripSearchTerm],
        in parts: [String]
    ) -> Bool {
        guard !terms.isEmpty else { return true }
        return !match(terms: terms, in: partsIndex(parts)).isEmpty
    }

    #if DEBUG
    /// Strong matches only, for small callers that must not show typo hits.
    nonisolated static func matchesStrongly(
        query: String,
        in parts: [String],
        languageTag: String = AppLanguagePreference.currentTag()
    ) -> Bool {
        strength(query: query, in: parts, languageTag: languageTag) == .strong
    }
    #endif

    /// Match strength of `parts` for `query`, nil when it does not match.
    /// An empty query is strong.
    nonisolated static func strength(
        query: String,
        in parts: [String],
        languageTag: String = AppLanguagePreference.currentTag()
    ) -> TripSearchStrength? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .strong }
        let terms = terms(query, languageTag: languageTag)
        guard !terms.isEmpty else { return nil }
        return match(terms: terms, in: partsIndex(parts)).first?.strength
    }

    private nonisolated static let partsDocumentID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private nonisolated static func partsIndex(_ parts: [String]) -> TripSearchIndex {
        TripSearchIndex(documents: [TripSearchDocument(
            tripID: partsDocumentID,
            fields: [TripSearchField(kind: .place, displayValues: parts)],
            startDate: .distantPast, endDate: nil, startYear: 0, startMonth: 0,
            durationDays: nil, isComplete: true)])
    }

    private nonisolated static func uniqueNonempty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

}

// MARK: - Engine entry points

extension TripSearch {

    /// Split a query into terms. Separators: whitespace, punctuation and
    /// symbols. Han and kana words also get a segmented alternative (root
    /// locale CFStringTokenizer, particles の と 之 的 dropped); Hangul words
    /// of 3+ syllables also get a particle-stripped stem as an exact-word
    /// alias; Greek words ending in -ς, -ου or -ων also get the stem as a
    /// literal alternative (Ιταλίας, Χανιών, Ιουλίου) when 4+ letters remain.
    /// Abbreviation classes add alias alternatives, city abbreviations city
    /// alternatives. A word or an
    /// adjacent 2 to 3 word phrase that exactly names a region (English or
    /// `languageTag`) or a country (any supported language, curated aliases)
    /// becomes one term carrying `countryCodes`; a region phrase has no
    /// literal alternatives. `isTrailingPartial` is set on the last term
    /// when `allowsTrailingPartial` and the query does not end in a
    /// separator.
    nonisolated static func terms(
        _ query: String,
        languageTag: String = AppLanguagePreference.currentTag(),
        allowsTrailingPartial: Bool = true
    ) -> [TripSearchTerm] {
        let singles = TripSearchText.rawTokens(query).compactMap { token -> (term: TripSearchTerm, key: String)? in
            guard let term = term(forToken: token.text), let native = normalizedSearchForms(token.text).first else {
                return nil
            }
            return (term, TripSearchText.words(native).joined(separator: " "))
        }
        var result: [TripSearchTerm] = []
        var position = 0
        while position < singles.count {
            var consumed = 1
            var phrase: TripSearchTerm?
            let longest = min(TripSearchAliases.maxPhraseWords, singles.count - position)
            for length in stride(from: longest, through: 1, by: -1) {
                let slice = singles[position..<(position + length)]
                guard !slice.contains(where: { $0.term.isNumeric || $0.key.isEmpty }) else { continue }
                let key = slice.map(\.key).joined(separator: " ")
                guard let codes = TripSearchAliases.countryCodes(forPhrase: key, languageTag: languageTag),
                      !codes.isEmpty else { continue }
                phrase = phraseTerm(slice.map(\.term), codes: codes)
                consumed = length
                break
            }
            result.append(phrase ?? singles[position].term)
            position += consumed
        }
        if allowsTrailingPartial, !TripSearchText.endsWithSeparator(query), !result.isEmpty {
            result[result.count - 1].isTrailingPartial = true
        }
        return result
    }

    private nonisolated static func term(forToken token: String) -> TripSearchTerm? {
        let forms = normalizedSearchForms(token)
        guard let native = forms.first else { return nil }
        var alternatives: [[String]] = []
        func add(_ alternative: [String]) {
            if !alternative.isEmpty, !alternatives.contains(alternative) { alternatives.append(alternative) }
        }
        for form in forms {
            let words = TripSearchText.words(form)
            add(words)
            let hasHanOrKana = words.contains { $0.unicodeScalars.contains { TripSearchText.isHanOrKana($0.value) } }
            guard hasHanOrKana else { continue }
            var segmented: [String] = []
            for word in words {
                guard word.unicodeScalars.contains(where: { TripSearchText.isHanOrKana($0.value) }) else {
                    segmented.append(word)
                    continue
                }
                let segments = TripSearchText.segmentCJK(word).filter { !TripSearchAliases.cjkParticles.contains($0) }
                segmented.append(contentsOf: segments.isEmpty ? [word] : segments)
            }
            add(segmented)
        }

        let nativeWords = TripSearchText.words(native)
        var aliases: [[String]] = []
        var cities: [[String]] = []
        if nativeWords.count == 1, let word = nativeWords.first {
            // The stem of a particle is an exact word only: 말라가 must not
            // become 말라 inside 과테말라 or at the start of 말라위.
            if word.unicodeScalars.count >= 3, word.unicodeScalars.allSatisfy(TripSearchText.isHangulSyllable),
               let particle = TripSearchAliases.hangulParticles.first(where: { word.hasSuffix($0) }) {
                let stem = String(word.unicodeScalars.dropLast(particle.unicodeScalars.count))
                if stem.unicodeScalars.count >= 2 {
                    for form in normalizedSearchForms(stem) {
                        let words = TripSearchText.words(form)
                        if !words.isEmpty, !aliases.contains(words) { aliases.append(words) }
                    }
                }
            }
            // Greek genitive endings; the stem also prefixes the nominative
            // (χανι → χανια, ιουλι → ιουλιος).
            if word.unicodeScalars.allSatisfy(TripSearchText.isGreek),
               let ending = TripSearchAliases.greekEndings.first(where: { word.hasSuffix($0) }) {
                let stem = String(word.unicodeScalars.dropLast(ending.unicodeScalars.count))
                if stem.unicodeScalars.count >= 4 {
                    for form in normalizedSearchForms(stem) { add(TripSearchText.words(form)) }
                }
            }
            for members in TripSearchAliases.abbreviationClasses where members.contains(word) {
                aliases.append(contentsOf: members.filter { $0 != word }.map { [$0] })
            }
            cities = TripSearchAliases.cityAbbreviations[word] ?? []
        }
        guard !alternatives.isEmpty else { return nil }
        return TripSearchTerm(
            raw: token.trimmingCharacters(in: .whitespacesAndNewlines),
            alternatives: alternatives,
            aliasAlternatives: aliases,
            cityAlternatives: cities,
            isNumeric: native.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 })
    }

    /// One term for a recognized region or country phrase. A country
    /// phrase's literal alternatives still match the words themselves,
    /// without connecting words ("bosnia and herzegovina" also finds
    /// "Bosnia & Herzegovina"). A region phrase (more than one code) keeps
    /// only its codes: its words would match across fields ("west" in
    /// Western Cape, "africa" in South Africa).
    private nonisolated static func phraseTerm(_ parts: [TripSearchTerm], codes: Set<String>) -> TripSearchTerm {
        guard parts.count > 1 else {
            var term = parts[0]
            term.countryCodes = codes
            return term
        }
        guard codes.count == 1 else {
            return TripSearchTerm(
                raw: parts.map(\.raw).joined(separator: " "), alternatives: [], countryCodes: codes)
        }
        let widest = parts.map(\.alternatives.count).max() ?? 1
        var alternatives: [[String]] = []
        for offset in 0..<widest {
            let words = parts.flatMap { $0.alternatives[min(offset, $0.alternatives.count - 1)] }
            let content = words.filter { !TripSearchAliases.nameStopWords.contains($0) }
            let alternative = content.isEmpty ? words : content
            if !alternatives.contains(alternative) { alternatives.append(alternative) }
        }
        return TripSearchTerm(
            raw: parts.map(\.raw).joined(separator: " "),
            alternatives: alternatives,
            countryCodes: codes)
    }

    /// The engine over every field. Order = index order, AND across terms.
    /// Empty `terms` returns every document as strong; callers decide what an
    /// empty or all-symbol query means.
    nonisolated static func match(
        terms: [TripSearchTerm],
        in index: TripSearchIndex
    ) -> [TripSearchMatch] {
        TripSearchEngine.match(terms: terms, in: index, fields: nil)
    }

    /// The engine restricted to `fields`: other postings are invisible, for
    /// matching, gating and evidence alike. Country-code alternatives need
    /// `.country`.
    nonisolated static func match(
        terms: [TripSearchTerm],
        in index: TripSearchIndex,
        fields: Set<TripSearchFieldKind>
    ) -> [TripSearchMatch] {
        TripSearchEngine.match(terms: terms, in: index, fields: fields)
    }

    /// Builds the region and foreign country-name tables ahead of the first
    /// query (one-time Locale work); safe off the main thread.
    nonisolated static func prewarmVocabulary(languageTag: String = AppLanguagePreference.currentTag()) {
        TripSearchAliases.prewarm(languageTag: languageTag)
    }

    /// "Did you mean". Nil when the query already has a strong match.
    /// Otherwise each word (Latin, Greek or Cyrillic, 4+ letters, not
    /// numeric, not part of a recognized country or region name such as
    /// "Austria", not a word `isKnownWord` accepts as typed) without a strong
    /// match of its own is replaced by the closest place, region, country or
    /// title word with the same first letter within 1 edit at 4 letters, 2 at
    /// 5 to 9 and 3 at 10+; a candidate 2 or more edits away must also share
    /// the first three letters (Split is not Spain, Turin is not Tunis).
    /// Ties: smaller distance, more trips, then place, region, country,
    /// title. The corrected query is returned in the corpus word's display
    /// casing only when it differs from the input and `accepts` (default: the
    /// engine finds a strong match) approves it.
    nonisolated static func spellingSuggestion(
        for query: String,
        in index: TripSearchIndex,
        languageTag: String = AppLanguagePreference.currentTag(),
        accepts: ((String) -> Bool)? = nil,
        isKnownWord: ((String) -> Bool)? = nil
    ) -> String? {
        guard !index.isEmpty else { return nil }
        func hasStrong(_ text: String) -> Bool {
            let terms = terms(text, languageTag: languageTag, allowsTrailingPartial: false)
            guard !terms.isEmpty else { return false }
            return match(terms: terms, in: index).contains { $0.strength == .strong }
        }
        let queryTerms = terms(query, languageTag: languageTag, allowsTrailingPartial: false)
        guard !queryTerms.isEmpty, !hasStrong(query) else { return nil }
        // A real country the user has not visited is not a typo for another.
        let recognized = Set(queryTerms.filter { !$0.countryCodes.isEmpty }
            .flatMap { $0.raw.split(separator: " ").map(String.init) })

        var replacements: [(range: Range<String.Index>, candidates: [String])] = []
        for token in TripSearchText.rawTokens(query) {
            // A correctly spelled place the user has not visited (Berlin) is
            // not a typo for one they have (Bergen).
            guard TripSearchText.isAlphabeticEuropean(token.text), !recognized.contains(token.text),
                  isKnownWord?(token.text.trimmingCharacters(in: .whitespacesAndNewlines)) != true,
                  !hasStrong(token.text),
                  let native = normalizedSearchForms(token.text).first else { continue }
            let scalars = native.unicodeScalars.map(\.value)
            guard scalars.count >= 4 else { continue }
            let candidates = suggestionCandidates(for: scalars, in: index)
            if !candidates.isEmpty { replacements.append((token.range, candidates)) }
        }
        guard !replacements.isEmpty else { return nil }

        let verify = accepts ?? hasStrong
        let original = normalizedSearchForms(query).first
        func corrected(_ choices: [Int]) -> String {
            var text = query
            for (replacement, choice) in zip(replacements, choices).reversed() {
                text.replaceSubrange(replacement.range, with: replacement.candidates[choice])
            }
            return text
        }
        var attempts = [Array(repeating: 0, count: replacements.count)]
        if replacements.count == 1 {
            attempts += (1..<replacements[0].candidates.count).map { [$0] }
        }
        for choices in attempts {
            let text = corrected(choices)
            if normalizedSearchForms(text).first != original, verify(text) { return text }
        }
        return nil
    }

    private nonisolated static func suggestionCandidates(
        for scalars: [UInt32],
        in index: TripSearchIndex
    ) -> [String] {
        let length = scalars.count
        let budget = length >= 10 ? 3 : (length >= 5 ? 2 : 1)
        let kinds: Set<TripSearchFieldKind> = [.place, .region, .country, .title]
        var scratch = EditDistance()
        var scored: [(distance: Int, documents: Int, rank: Int, display: String)] = []
        for (_, ids) in index.idsByLength.buckets(in: max(1, length - budget)...(length + budget)) {
            for id in ids {
                let word = index.scalars[Int(id)]
                guard word.first == scalars.first, !index.numericWord[Int(id)],
                      let distance = scratch.within(scalars[...], word[...], limit: budget),
                      distance > 0,
                      distance < 2 || word.starts(with: scalars.prefix(3)) else { continue }
                var rank = Int.max
                var display: String?
                for posting in index.postings[Int(id)] where !posting.isCompound {
                    let kind = TripSearchFieldKind.byOrdinal[Int(posting.kind)]
                    guard kinds.contains(kind) else { continue }
                    let kindRank = kind == .title ? 3 : kind.evidenceRank
                    guard kindRank < rank,
                          let text = displayWord(index.vocabulary[Int(id)], posting: posting, in: index)
                    else { continue }
                    rank = kindRank
                    display = text
                }
                guard let display else { continue }
                scored.append((distance, index.documentCount(ofWord: Int(id), kinds: kinds), rank, display))
            }
        }
        scored.sort {
            ($0.distance, -$0.documents, $0.rank, $0.display) < ($1.distance, -$1.documents, $1.rank, $1.display)
        }
        var seen = Set<String>()
        return scored.map(\.display).filter { seen.insert($0).inserted }.prefix(5).map { $0 }
    }

    /// The display spelling of a normalized word: the word at the same
    /// position of its display value, when the native form keeps the word
    /// boundaries. Words that exist only in a transliterated form have none.
    private nonisolated static func displayWord(
        _ word: String,
        posting: TripSearchIndex.Posting,
        in index: TripSearchIndex
    ) -> String? {
        let value = index.documents[Int(posting.document)].fields[Int(posting.field)]
            .displayValues[Int(posting.value)]
        let normalized = TripSearchText.words(normalizedSearchForms(value).first ?? "")
        let original = TripSearchText.rawTokens(value).map(\.text)
        guard normalized.count == original.count, let position = normalized.firstIndex(of: word) else { return nil }
        return original[position]
    }
}
