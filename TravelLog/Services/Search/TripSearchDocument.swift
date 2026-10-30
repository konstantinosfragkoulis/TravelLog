//
//  TripSearchDocument.swift
//  TravelLog
//

import Foundation
import os

// # Trip search engine
//
// Pure values, nonisolated, no SwiftData. A `TripSearchDocument` is one trip
// as display strings grouped by `TripSearchFieldKind`; its normalized words
// (and compounds) are computed once when it is created. `TripSearchIndex`
// merges documents into a vocabulary with postings. `TripSearch.terms(_:)`
// turns a query into `TripSearchTerm`s and `TripSearch.match(terms:in:)`
// returns matches in index order. AND across terms.
//
// Term alternatives. A term matches a document when ANY of its alternatives
// does: a literal alternative (`alternatives`) when ALL its sub-tokens match,
// an alias alternative (`aliasAlternatives`: abbreviation classes, Hangul
// particle stems) when all its sub-tokens equal a word exactly, a city
// alternative (`cityAlternatives`) likewise but against place words only, and
// the country-code alternative (`countryCodes`, non-empty when the term or a
// 2 to 3 word phrase is a region word or a country name in any supported
// language) when the document's `countryCodes` intersect it. A 2 to 3 word
// phrase naming a region (more than one code) has no literal alternatives,
// so its words never match across fields ("west africa" never finds Cape
// Town through Western Cape and South Africa); a country phrase keeps them.
//
// Tiers per sub-token, lower is better:
// - T0 exact word. T1 word prefix; Han, kana, Hangul and Thai sub-tokens also
//   match inside a word. T2 compound (adjacent words of one place, region or
//   country value, "newyork"), alias or city alternative, country-code
//   alternative, or two adjacent query words joined ("hong kong" against
//   "hongkong").
// - T3 infix (4+ characters), T4 fuzzy (OSA: 1 edit from 4 characters with
//   the first character fixed at 4; 2 edits when the corpus word has 8+
//   characters and the sub-token 6+, so two typos never hide a long name,
//   with the first character fixed unless the sub-token has 8+ characters
//   and no T0 to T2 hit: "mailand" never finds Thailand. Such a long
//   sub-token with no other hit in any field kind also reaches a word 2
//   characters shorter with 2 edits, or any 6 or 7 character word when typed
//   without Latin letters, so a long foreign name finds its English place:
//   "lissabon" finds Lisbon, 런던 ("leondeon") finds London, "florance" with
//   a Florence trip never finds France),
//   T5 fuzzy prefix (trailing partial term only, 5+ characters, and only
//   when the sub-token has no T0 to T2 hit in any field kind: a finished
//   "vienna" does not also list Vietnam).
// - Gating, per field kind: a T0 to T2 hit of a sub-token in any document
//   (restricted to the requested fields) hides T3 to T5 for that sub-token in
//   postings of the same kind across the corpus; other kinds still reach
//   them. A posting is also hidden when its word's most specific kind in the
//   same document (place, region, country, transit, then title) is hidden, so
//   a title that repeats its place ("Paris Weekend") does not leak past
//   place gating. `paris` with a Paris place never finds Samos, `brat` with
//   Bratislava never finds Berat, but `roma` with a Romania country still
//   finds the Rome place, and `milano` in a title still finds a Milan place.
//   A term with any alias, city, country-code or joined hit skips T3 to T5
//   entirely, and so does a recognized region or country name (non-empty
//   `countryCodes`) even when no document has that country: `china` never
//   finds Chicago. A 4-character Latin alternative of a term typed without
//   Latin letters (`pali` for 파리, `rodo` for Ρόδο) skips T3 and T5 and
//   reaches T4 only by swapping its final vowel for another with the first
//   three characters equal (`roma` for ローマ finds Rome); one shorter than
//   4 letters matches at T0 only (ソウ, `sou`, never prefixes South Korea).
//   A finished region or country name matches its literal words at T0 only
//   ("austria" never prefixes a street named "Austriana").
// - Spellings (T2, exact words only, like Greeklish): a Latin word with
//   ou, oo or uu, or a kana word, is the place word with the same long-vowel
//   skeleton (`toukyou` finds Tokyo, ソール finds ソウル); ä, ö, ü, ø and å
//   spelled out are a normalized form of both sides (`muenchen`).
// - Digits: T0; 3+ digit tokens also prefix numeric words; a 2 digit token
//   matches the last two digits of a 19xx/20xx year; any digit token also
//   prefixes words that are not all digits (`30` finds "30th", `4` finds
//   "4x4") outside date words and compounds. Never infix or fuzzy.
//   Date words match at T0 and T1 only. Compounds never match at T3 to T5.
//
// Alternate names: a place's other-language names (`TripSearchPlaceNames`,
// a `.place` field with `alternateOf`; a region's and an island group's in a
// `.region` one) are place or region words, but only as typed:
// T0 exact, T1 prefix of a whole word only for the trailing partial term
// and only when the typed word is no stored place, region or transit word
// ("Velde" with a Velde district never starts "Veldenmark"),
// and compounds exactly (T2) or through two joined query words. Never
// infix (Han and kana included: 京都 never finds 東京都), never fuzzy, and
// never a spelling suggestion. Their native form only is indexed, without
// connecting or designator words, words shorter than 4 letters (2 Han,
// kana or Hangul) of multi-word names, or words naming a country ("Monaco
// di Baviera" never makes `monaco` find Munich), plus its umlauts spelled
// out. Their evidence names the stored place they belong to.
//
// Strength: `strong` when every term matched at T0 to T2 through a field
// other than `transit` (any field for a via place, `namesStop`); `similar`
// when a term needed T3 to T5 or matched only through `transit`; `partial`
// belongs to the resolver's fallback.
// Whole names first: when some document has a term exactly as a whole place,
// region, country or alternate name (with the query's other words), or the
// term names a country or region, a document that has it only as
// a word of a longer, different name is `similar` ("Baja California" for
// `california`, "New York" for `york`), unless its own title (a custom name)
// has it (`preferWholeNames`).
//
// Evidence: per term, the best non-title field in the order place, region,
// country, date, transit, unless the term also matched the title.

/// Field classes carry match strength and captions.
nonisolated enum TripSearchFieldKind: String, Sendable, CaseIterable, Hashable {
    case title      // custom name or display title plus every valid variant
    case place      // destinationSummary words, destination stay locality, metroName, islandName, subLocality;
                    // an alternate field adds the other-language names of locality, metro, island and
                    // subLocality, and subLocality's own name
    case region     // destination stay administrativeArea and GeoNames region; an alternate field adds
                    // their other-language names and those of the island group a stay lies in
    case country    // ISO codes, English + app-language names, curated aliases; destination stays only.
                    // Connecting words inside multi-word names ("of", "and") are not whole words.
    case date       // `TripSearchDocument.dateWords`
    case transit    // transit stay locality, metroName, islandName, administrativeArea (never country);
                    // an alternate field adds the other-language names of locality, metro and island

    var ordinal: Int {
        switch self {
        case .title: 0
        case .place: 1
        case .region: 2
        case .country: 3
        case .date: 4
        case .transit: 5
        }
    }

    /// Evidence priority, lower wins. Title never yields evidence.
    var evidenceRank: Int {
        switch self {
        case .place: 0
        case .region: 1
        case .country: 2
        case .date: 3
        case .transit: 4
        case .title: 5
        }
    }

    static let byOrdinal: [TripSearchFieldKind] = [.title, .place, .region, .country, .date, .transit]

    /// Kinds whose multi-word values also index adjacent compounds.
    var buildsCompounds: Bool { self == .place || self == .region || self == .country }
}

/// What kind of trip a document is, for the parser's facet words
/// ("islands", "abroad", "domestic"; `TripQueryVocabulary`).
nonisolated enum TripSearchFacet: String, Sendable, Hashable, CaseIterable {
    /// A destination stay on an island that is not a city's island (see
    /// `TripSearchDocument.make(from:)`).
    case island
    /// A destination country outside the trip's home countries.
    case abroad
    /// Every destination country is a home country.
    case domestic
    /// A stay reached by a recorded flight, or an airport stop.
    case flight
    /// A flight and a stay at least `TripSearchDocument.longHaulMinimumKm`
    /// from home or from the stay before it.
    case longHaul
    /// A connection: an airport stop reached by a flight and left by one.
    case layover
    /// Destination stays in two or more countries.
    case multiCountry
    /// Destination stays in exactly one country.
    case singleCountry
}

/// A Home's country and dates, which decide a trip's `abroad` and
/// `domestic` facets (`TripSearchDocument.homeCountryCodes`).
nonisolated struct TripSearchHome: Sendable, Hashable {
    var isoCountryCode: String
    var startedAt: Date
    var endedAt: Date?
}

nonisolated struct TripSearchField: Sendable, Equatable {
    var kind: TripSearchFieldKind
    /// Original display strings this field was built from (for captions).
    var displayValues: [String]
    /// Alternate names only: the stored value each display value names
    /// (`displayValues[i]` is another name of `alternateOf[i]`), which
    /// evidence shows. Empty for every other field.
    var alternateOf: [String]

    /// A title the user named the trip (its custom name), not one derived
    /// from its places: a term it has stays strong under whole-name
    /// precedence (see the engine notes).
    var isUserNamed: Bool
    /// The display values that name an island (a stay's island, an island
    /// name's other names): what an island suffix typed means (済州島).
    var islandValues: Set<String>
    /// The display values that name a place in Japan (a stay stored in JP,
    /// its other names): the places romaji long vowels spell (`toukyou`).
    var japanValues: Set<String>

    /// Other names of stored values, matched only as typed (see the engine notes).
    var isAlternate: Bool { !alternateOf.isEmpty }

    init(
        kind: TripSearchFieldKind, displayValues: [String], alternateOf: [String] = [], isUserNamed: Bool = false,
        islandValues: Set<String> = [], japanValues: Set<String> = []
    ) {
        self.kind = kind
        self.displayValues = displayValues
        self.alternateOf = alternateOf
        self.isUserNamed = isUserNamed
        self.islandValues = islandValues
        self.japanValues = japanValues
    }

    /// The other names (`TripSearchPlaceNames`) of `places`, each a stored
    /// name with its country and layer, then `adding` (other names already
    /// known, each with the stored name it names), as one alternate field
    /// of `kind` (`.place`, or `.region` for regions and island groups).
    static func alternatePlaceNames(
        of places: [(name: String, isoCountryCode: String?, layer: PlaceNameTable.Layer)],
        placeNames: TripSearchPlaceNames,
        adding known: [(name: String, of: String)] = [],
        kind: TripSearchFieldKind = .place
    ) -> TripSearchField {
        var names: [String] = []
        var sources: [String] = []
        var islands = Set<String>()
        var japan = Set<String>()
        for place in places {
            for name in placeNames.names(for: place.name, isoCountryCode: place.isoCountryCode, layer: place.layer) {
                names.append(name)
                sources.append(place.name)
                if place.layer == .island { islands.insert(name) }
                if place.isoCountryCode?.uppercased() == TripSearchIndex.japan { japan.insert(name) }
            }
        }
        for name in known {
            names.append(name.name)
            sources.append(name.of)
        }
        return TripSearchField(
            kind: kind, displayValues: names, alternateOf: sources, islandValues: islands, japanValues: japan)
    }
}

/// Builder-local normalization memo for batches (no lock, no cap). Not
/// Sendable: create one per build pass.
nonisolated final class TripSearchNormalizer {
    private var memo: [String: [String]] = [:]

    init() {}

    func forms(_ value: String) -> [String] {
        if let forms = memo[value] { return forms }
        let forms = TripSearchText.forms(value)
        memo[value] = forms
        return forms
    }
}

/// One trip as plain values. Normalization happens here, once.
nonisolated struct TripSearchDocument: Sendable, Equatable {
    nonisolated struct Word: Sendable, Equatable, Hashable {
        let text: String
        let kind: TripSearchFieldKind
        /// Indices into `fields` and that field's `displayValues`.
        let field: Int
        let value: Int
        let isCompound: Bool
        /// From an alternate field: matched only as typed.
        var isAlternate = false
        /// Some value with the word names a place in Japan, or an island
        /// (`TripSearchField.japanValues`, `islandValues`), whichever value
        /// the word was first seen in.
        var namesJapan = false
        var namesIsland = false
    }

    let tripID: UUID
    /// Trimmed, deduplicated per field; empty values and fields dropped.
    let fields: [TripSearchField]
    let startDate: Date
    let endDate: Date?
    /// Gregorian components from `TripFilters.yearCalendar` (device zone).
    let startYear: Int
    let startMonth: Int
    let durationDays: Int?
    let isComplete: Bool
    /// Uppercase ISO codes of destination (and unclassified) stays plus
    /// `trip.countryCodes`; region words and foreign names match these.
    let countryCodes: Set<String>
    /// The trip's kinds the parser's facet words filter on.
    let facets: Set<TripSearchFacet>
    /// The largest distance from home of a destination stay, in km ("farthest
    /// trip"); nil when unknown.
    let farthestKm: Double?
    /// Normalized words and compounds, deduplicated by (text, kind, compound).
    let words: [Word]
    /// Whole words (no compounds) of place, region and country.
    let strictPlaceWords: Set<String>
    /// Whole words (no compounds) of every field.
    let wholeWords: Set<String>
    /// The native normalized words of each value of every field but dates,
    /// one entry per segment, with its field kind: the names the parser's
    /// name pass looks up (`TripSearchIndex.namePhrase`).
    let nameValues: [NameValue]
    /// Every indexed form of each place, region, country and transit value,
    /// one entry per segment: the whole names the engine's name precedence
    /// compares a query with.
    let geographicNames: [GeographicName]
    /// Indices into `fields` of the titles the user named (`isUserNamed`).
    let userNamedFields: Set<Int>

    nonisolated struct NameValue: Sendable, Equatable {
        let words: [String]
        let kind: TripSearchFieldKind
        let isAlternate: Bool
    }

    nonisolated struct GeographicName: Sendable, Equatable {
        /// The words without connecting words inside the name, and for an
        /// administrative area without designators ("Vessa de Lunero" is
        /// vessa, lunero; "County Cork" is cork; "La Vessa" stays la,
        /// vessa; elided "L'Aquila" is aquila), or all of them when nothing
        /// else is left.
        let words: [String]
        /// The first word and every word joined, as typed for a compound.
        let first: String
        let joined: String
        let kind: TripSearchFieldKind

        init(_ segment: [String], kind: TripSearchFieldKind) {
            // Designators only in administrative areas: "Seo District" is
            // the district's own name, not a designated Seo. Compass words
            // stay: "Northern Ireland" is no whole Ireland. Every compass
            // word of `placeNameNoiseWords` is in `compassWords`.
            // Connecting words only inside a name: a leading article names
            // ("La Vessa" is no Vessa), unless elided ("L'Aquila" is Aquila).
            let content = segment.enumerated().filter { offset, word in
                !((offset > 0 || word.unicodeScalars.count == 1) && TripSearchAliases.nameStopWords.contains(word))
                    && !(kind == .region && ((TripSearchAliases.placeNameNoiseWords.contains(word)
                        && !TripSearchAliases.compassWords.contains(word))
                        || TripSearchAliases.administrativeDesignators.contains(word)))
            }.map(\.element)
            words = content.isEmpty ? segment : content
            first = segment.first ?? ""
            joined = segment.joined()
            self.kind = kind
        }
    }

    /// The memberwise initializer is the public API; tests build documents
    /// directly. Pass one `normalizer` to a batch of documents to share its
    /// memo; without one the global bounded memo is used.
    init(
        tripID: UUID,
        fields: [TripSearchField],
        startDate: Date,
        endDate: Date?,
        startYear: Int,
        startMonth: Int,
        durationDays: Int?,
        isComplete: Bool,
        countryCodes: Set<String> = [],
        facets: Set<TripSearchFacet> = [],
        farthestKm: Double? = nil,
        normalizer: TripSearchNormalizer? = nil
    ) {
        var cleaned: [TripSearchField] = []
        for field in fields {
            var seen = Set<String>()
            var values: [String] = []
            var sources: [String] = []
            for (offset, value) in field.displayValues.enumerated() {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
                values.append(trimmed)
                if field.isAlternate {
                    sources.append(field.alternateOf.indices.contains(offset) ? field.alternateOf[offset] : trimmed)
                }
            }
            if !values.isEmpty {
                var kept = field
                kept.displayValues = values
                kept.alternateOf = sources
                kept.islandValues = Set(field.islandValues.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                kept.japanValues = Set(field.japanValues.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                cleaned.append(kept)
            }
        }

        var words: [Word] = []
        var wordPositions: [WordKey: Int] = [:]
        var strict = Set<String>()
        var whole = Set<String>()
        var nameValues: [NameValue] = []
        var geographicNames: [GeographicName] = []
        // A word an ordinary field already has keeps that field's matching.
        // A repeated word keeps its first value and gains the others' traits.
        func add(
            _ text: String, _ kind: TripSearchFieldKind, _ field: Int, _ value: Int,
            compound: Bool, alternate: Bool, japan: Bool, island: Bool
        ) {
            let key = WordKey(text: text, kind: kind, isCompound: compound)
            if let position = wordPositions[key] {
                words[position].namesJapan = words[position].namesJapan || japan
                words[position].namesIsland = words[position].namesIsland || island
                return
            }
            wordPositions[key] = words.count
            words.append(Word(
                text: text, kind: kind, field: field, value: value, isCompound: compound, isAlternate: alternate,
                namesJapan: japan, namesIsland: island))
            guard !compound else { return }
            whole.insert(text)
            if kind.buildsCompounds { strict.insert(text) }
        }
        // Alternate fields last, so a word an ordinary field has is never theirs.
        let order = cleaned.indices.filter { !cleaned[$0].isAlternate }
            + cleaned.indices.filter { cleaned[$0].isAlternate }
        for fieldIndex in order {
            let field = cleaned[fieldIndex]
            let dropsStopWords = field.kind == .country
            let alternate = field.isAlternate
            for (valueIndex, value) in field.displayValues.enumerated() {
                let forms = normalizer?.forms(value) ?? TripSearch.normalizedSearchForms(value)
                // Another script's romanization is not what anyone types for it.
                // Names are the native form only: a romanization finds a
                // trip but never outranks query syntax.
                if field.kind != .date, let native = forms.first {
                    for segment in TripSearchText.segments(native) where !segment.isEmpty {
                        nameValues.append(NameValue(words: segment, kind: field.kind, isAlternate: alternate))
                    }
                }
                // An alternate name is matched as typed: its native form, and
                // that form with umlauts spelled out (`TripSearchText.forms`).
                let indexed = alternate
                    ? Array(forms.prefix(1)) + [TripSearchText.umlautSpelling(value)].compactMap { $0 } : forms
                let japan = field.japanValues.contains(value)
                let island = field.islandValues.contains(value)
                for form in indexed {
                    for segment in TripSearchText.segments(form) {
                        if field.kind != .title, field.kind != .date {
                            geographicNames.append(GeographicName(segment, kind: field.kind))
                        }
                        // Only connecting words inside a name drop; a leading
                        // article ("La Réunion", Danish "De Forenede ...")
                        // stays, so typing it keeps the country in a picker.
                        for (offset, word) in segment.enumerated()
                        where !(dropsStopWords && offset > 0 && TripSearchAliases.nameStopWords.contains(word))
                            && !(alternate && Self.isAlternateNoise(word, inName: segment)) {
                            add(word, field.kind, fieldIndex, valueIndex, compound: false, alternate: alternate,
                                japan: japan, island: island)
                        }
                        guard field.kind.buildsCompounds, segment.count >= 2 else { continue }
                        for start in 0..<(segment.count - 1) {
                            let pair = segment[start] + segment[start + 1]
                            add(pair, field.kind, fieldIndex, valueIndex, compound: true, alternate: alternate,
                                japan: japan, island: island)
                            if start + 2 < segment.count {
                                add(pair + segment[start + 2], field.kind, fieldIndex, valueIndex,
                                    compound: true, alternate: alternate, japan: japan, island: island)
                            }
                        }
                    }
                }
            }
        }

        self.tripID = tripID
        self.fields = cleaned
        self.startDate = startDate
        self.endDate = endDate
        self.startYear = startYear
        self.startMonth = startMonth
        self.durationDays = durationDays
        self.isComplete = isComplete
        self.countryCodes = Set(countryCodes.map { $0.uppercased() })
        self.facets = facets
        self.farthestKm = farthestKm
        self.words = words
        self.strictPlaceWords = strict
        self.wholeWords = whole
        self.nameValues = nameValues
        self.geographicNames = geographicNames
        self.userNamedFields = Set(cleaned.indices.filter { cleaned[$0].isUserNamed })
    }

    /// A word of an alternate name that does not name the place alone: a
    /// connecting or designator word, a word naming a country (the
    /// country-code alternative already finds trips there), or in a
    /// multi-word name a word shorter than 4 letters or 2 Han, kana or
    /// Hangul characters ("Đôn" of "Luân Đôn"). Its compounds stay.
    static func isAlternateNoise(_ word: String, inName words: [String]) -> Bool {
        if TripSearchAliases.nameStopWords.contains(word) || TripSearchAliases.placeNameNoiseWords.contains(word) {
            return true
        }
        if words.count > 1 {
            let scalars = word.unicodeScalars
            let minimum = scalars.contains(where: TripSearchText.isCJK) ? 2 : 4
            if scalars.count < minimum { return true }
        }
        return TripSearchAliases.isCountryName(word)
    }

    private nonisolated struct WordKey: Hashable {
        let text: String
        let kind: TripSearchFieldKind
        let isCompound: Bool
    }

    /// Year, wide month and abbreviated month for `start` and `end` in the
    /// app language, Gregorian, plus the plain ASCII year (ja, ko and zh
    /// format years as 2024年 / 2024년). Deduplicated, in date order.
    static func dateWords(
        start: Date,
        end: Date?,
        languageTag: String,
        calendar: Calendar = TripFilters.yearCalendar
    ) -> [String] {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let locale = AppLanguagePreference.locale(for: languageTag)
        let style = Date.FormatStyle(
            date: .omitted, time: .omitted, locale: locale,
            calendar: gregorian, timeZone: gregorian.timeZone)
        var values: [String] = []
        for date in [start] + (end.map { [$0] } ?? []) {
            values.append(String(gregorian.component(.year, from: date)))
            values.append(date.formatted(style.year()))
            values.append(date.formatted(style.month(.wide)))
            values.append(date.formatted(style.month(.abbreviated)))
        }
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }
}

nonisolated enum TripSearchStrength: Int, Sendable, Comparable {
    case strong = 0, similar = 1, partial = 2

    static func < (lhs: TripSearchStrength, rhs: TripSearchStrength) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

nonisolated struct TripSearchEvidence: Sendable, Equatable {
    var kind: TripSearchFieldKind
    /// The display value that satisfied a query term ("Frankfurt", "Bali");
    /// for a country-code alternative, the matched ISO code.
    var text: String
}

nonisolated struct TripSearchMatch: Sendable, Equatable {
    var documentIndex: Int
    var strength: TripSearchStrength
    /// At most one entry per query term, in query order; empty when every
    /// term hit the title.
    var evidence: [TripSearchEvidence]
}

/// One query word (or recognized 2 to 3 word phrase) with its alternatives.
nonisolated struct TripSearchTerm: Sendable, Equatable {
    /// Original text as typed (trimmed); words of a phrase joined by a space.
    var raw: String
    /// Literal alternatives, normalized. "Θεσσαλονίκη" gives
    /// [["θεσσαλονικη"], ["thessalonike"], ["thessaloniki"]]; "東京旅行" gives
    /// [["東京旅行"], ["東京", "旅行"]].
    var alternatives: [[String]]
    /// Abbreviation classes and Hangul particle stems: exact words only, T2.
    var aliasAlternatives: [[String]]
    /// City abbreviations ("newyork" for `nyc`): exact place words only, T2.
    var cityAlternatives: [[String]]
    /// A Han, kana or Hangul word without its island suffix (済州 of
    /// 済州島): exact words, T2 in island values and similar elsewhere
    /// (宮古島 typed is Miyako Island, not the city 宮古).
    var islandStems: [[String]]
    /// Uppercase ISO codes when the term names a region or a country; matches
    /// documents whose `countryCodes` intersect it (T2, evidence `.country`).
    var countryCodes: Set<String>
    /// Every character is a digit after width folding.
    var isNumeric: Bool
    /// Last term and the query does not end in a separator: T5 may apply.
    var isTrailingPartial: Bool
    /// The place a via word names (`layover in Frankfurt`): a stop is what
    /// it asks for, so a transit hit is as strong as any other.
    var namesStop = false

    init(
        raw: String,
        alternatives: [[String]],
        aliasAlternatives: [[String]] = [],
        cityAlternatives: [[String]] = [],
        islandStems: [[String]] = [],
        countryCodes: Set<String> = [],
        isNumeric: Bool = false,
        isTrailingPartial: Bool = false
    ) {
        self.raw = raw
        self.alternatives = alternatives
        self.aliasAlternatives = aliasAlternatives
        self.cityAlternatives = cityAlternatives
        self.islandStems = islandStems
        self.countryCodes = countryCodes
        self.isNumeric = isNumeric
        self.isTrailingPartial = isTrailingPartial
    }
}

// MARK: - Index

/// Immutable inverted index over documents. `init` only merges the
/// documents' precomputed words into a vocabulary with postings.
nonisolated struct TripSearchIndex: Sendable {
    nonisolated struct Posting: Sendable {
        let document: Int32
        let field: UInt16
        let value: UInt16
        let kind: UInt8
        let isCompound: Bool
        /// The word's most specific non-compound kind in this document, by
        /// `evidenceRank` (a title word that repeats a place gates as place).
        var gateKind: UInt8
        /// An alternate name's word: matched only as typed.
        var isAlternate = false
        /// `TripSearchDocument.Word.namesJapan`, `namesIsland`.
        var namesJapan = false
        var namesIsland = false
    }

    /// Word ids by Unicode scalar length. Sparse: only lengths some word has
    /// are stored, so one very long word (an uncapped trip name) costs one
    /// bucket, not one per length up to it. Ranges iterate ascending by
    /// length, each bucket's ids in vocabulary order.
    nonisolated struct LengthBuckets: Sendable {
        /// The occupied lengths, ascending, and each one's ids.
        private let lengths: [Int]
        private let ids: [[Int32]]

        init(_ idsByLength: [Int: [Int32]]) {
            let sorted = idsByLength.sorted { $0.key < $1.key }
            lengths = sorted.map(\.key)
            ids = sorted.map(\.value)
        }

        /// The first stored position whose length is at least `length`.
        private func position(atLeast length: Int) -> Int {
            var low = 0
            var high = lengths.count
            while low < high {
                let middle = (low + high) / 2
                if lengths[middle] < length { low = middle + 1 } else { high = middle }
            }
            return low
        }

        /// The ids of the words of exactly `length` scalars ([] for none).
        subscript(length: Int) -> [Int32] {
            let index = position(atLeast: length)
            return index < lengths.count && lengths[index] == length ? ids[index] : []
        }

        /// The occupied (length, ids) buckets with a length in `range`, ascending.
        func buckets(in range: ClosedRange<Int>) -> Zip2Sequence<ArraySlice<Int>, ArraySlice<[Int32]>> {
            let start = position(atLeast: range.lowerBound)
            let end = range.upperBound == .max ? lengths.count : position(atLeast: range.upperBound + 1)
            let bounds = start..<max(start, end)
            return zip(lengths[bounds], ids[bounds])
        }

        /// The occupied buckets of every length from `lower` up, ascending.
        func buckets(from lower: Int) -> Zip2Sequence<ArraySlice<Int>, ArraySlice<[Int32]>> {
            buckets(in: lower...Int.max)
        }
    }

    let documents: [TripSearchDocument]
    /// Unique per built index, for memo identity.
    let generation: UInt64

    let vocabulary: [String]
    let wordIDs: [String: Int32]
    let scalars: [[UInt32]]
    let postings: [[Posting]]
    /// Word ids in Unicode scalar (UTF-8 byte) order, for prefix ranges.
    let sortedIDs: [Int32]
    let idsByLength: LengthBuckets
    let cjkIDs: [Int32]
    let yearIDs: [Int32]
    let numericWord: [Bool]
    /// Per word, a bit per `TripSearchFieldKind.ordinal` of its non-compound
    /// postings: weak tiers skip words whose kinds are all gated.
    let wholeWordKinds: [UInt8]
    let documentsByCountryCode: [String: [Int32]]
    /// Name phrases by key (`namePhrase`).
    private let namePhrases: [String: NamePhrase]
    /// Greek words of the place, region and country fields by their
    /// Greeklish skeleton (`TripSearchText.greeklishSkeletons`), so
    /// `xarokampos` and `8alassini` find Χαρόκαμπος and Θαλασσινή.
    let greekWordsBySkeleton: [String: [String]]
    /// Latin words of place, region, country and transit values naming
    /// places in Japan and kana words of those fields, by their
    /// `TripSearchText.longVowelSkeleton` or `kanaLongVowelSkeleton`, so
    /// `toukyou` finds Tokyo and ソール finds ソウル.
    let wordsByLongVowelSkeleton: [String: [String]]

    private static let generations = OSAllocatedUnfairLock(initialState: UInt64(0))

    /// Where romaji long-vowel spellings name places (`wordsByLongVowelSkeleton`).
    static let japan = "JP"


    init(documents: [TripSearchDocument]) {
        self.documents = documents
        self.generation = Self.generations.withLock { value in
            value &+= 1
            return value
        }

        var vocabulary: [String] = []
        var wordIDs: [String: Int32] = [:]
        var postings: [[Posting]] = []
        var kinds: [UInt8] = []
        var byCode: [String: [Int32]] = [:]
        for (documentIndex, document) in documents.enumerated() {
            let doc = Int32(documentIndex)
            for word in document.words {
                let id: Int32
                if let existing = wordIDs[word.text] {
                    id = existing
                } else {
                    id = Int32(vocabulary.count)
                    wordIDs[word.text] = id
                    vocabulary.append(word.text)
                    postings.append([])
                    kinds.append(0)
                }
                if !word.isCompound { kinds[Int(id)] |= 1 << UInt8(word.kind.ordinal) }
                postings[Int(id)].append(Posting(
                    document: doc,
                    field: UInt16(clamping: word.field),
                    value: UInt16(clamping: word.value),
                    kind: UInt8(word.kind.ordinal),
                    isCompound: word.isCompound,
                    gateKind: UInt8(word.kind.ordinal),
                    isAlternate: word.isAlternate,
                    namesJapan: word.namesJapan,
                    namesIsland: word.namesIsland))
            }
            for code in document.countryCodes { byCode[code, default: []].append(doc) }
        }
        // A word's postings in one document are adjacent: give its whole
        // postings the most specific kind among them as `gateKind`.
        for id in postings.indices {
            var start = 0
            while start < postings[id].count {
                let document = postings[id][start].document
                var end = start
                var best: TripSearchFieldKind?
                while end < postings[id].count, postings[id][end].document == document {
                    let posting = postings[id][end]
                    let kind = TripSearchFieldKind.byOrdinal[Int(posting.kind)]
                    if !posting.isCompound, best.map({ kind.evidenceRank < $0.evidenceRank }) ?? true { best = kind }
                    end += 1
                }
                if let best, end - start > 1 {
                    for offset in start..<end where !postings[id][offset].isCompound {
                        let posting = postings[id][offset]
                        guard posting.kind != UInt8(best.ordinal) else { continue }
                        postings[id][offset].gateKind = UInt8(best.ordinal)
                    }
                }
                start = end
            }
        }

        var scalars: [[UInt32]] = []
        scalars.reserveCapacity(vocabulary.count)
        var idsByLength: [Int: [Int32]] = [:]
        var cjk: [Int32] = []
        var years: [Int32] = []
        var numeric: [Bool] = []
        numeric.reserveCapacity(vocabulary.count)
        for (index, word) in vocabulary.enumerated() {
            let values = word.unicodeScalars.map(\.value)
            scalars.append(values)
            let length = values.count
            idsByLength[length, default: []].append(Int32(index))
            if values.contains(where: TripSearchText.isCJK) { cjk.append(Int32(index)) }
            let isNumeric = !values.isEmpty && values.allSatisfy { $0 >= 48 && $0 <= 57 }
            numeric.append(isNumeric)
            if isNumeric, length == 4, (values[0] == 49 && values[1] == 57) || (values[0] == 50 && values[1] == 48) {
                years.append(Int32(index))
            }
        }
        let sorted = (0..<Int32(vocabulary.count)).sorted {
            scalars[Int($0)].lexicographicallyPrecedes(scalars[Int($1)])
        }

        self.vocabulary = vocabulary
        self.wordIDs = wordIDs
        self.scalars = scalars
        self.postings = postings
        self.sortedIDs = sorted
        self.idsByLength = LengthBuckets(idsByLength)
        self.cjkIDs = cjk
        self.yearIDs = years
        self.numericWord = numeric
        self.wholeWordKinds = kinds
        self.documentsByCountryCode = byCode
        let placeKinds: UInt8 = (1 << TripSearchFieldKind.place.ordinal)
            | (1 << TripSearchFieldKind.region.ordinal) | (1 << TripSearchFieldKind.country.ordinal)
        var greek: [String: [String]] = [:]
        for (id, word) in vocabulary.enumerated()
        where kinds[id] & placeKinds != 0 && word.unicodeScalars.contains(where: TripSearchText.isGreek) {
            for skeleton in TripSearchText.greeklishSkeletons(word) { greek[skeleton, default: []].append(word) }
        }
        self.greekWordsBySkeleton = greek
        // Stops too, so "via Toukyou" reaches a Tokyo stop (similar unless via names it).
        let spellingKinds = placeKinds | (1 << TripSearchFieldKind.transit.ordinal)
        var longVowels: [String: [String]] = [:]
        for (id, word) in vocabulary.enumerated() where kinds[id] & spellingKinds != 0 {
            let scalars = word.unicodeScalars
            if scalars.count >= 4, scalars.allSatisfy({ $0.isASCII && $0.properties.isAlphabetic }),
               postings[id].contains(where: \.namesJapan) {
                longVowels[TripSearchText.longVowelSkeleton(word), default: []].append(word)
            } else if scalars.count >= 2, scalars.allSatisfy({ TripSearchText.isKana($0.value) }) {
                longVowels[TripSearchText.kanaLongVowelSkeleton(word), default: []].append(word)
            }
        }
        self.wordsByLongVowelSkeleton = longVowels
        var names: [String: NamePhrase] = [:]
        for (documentIndex, document) in documents.enumerated() {
            let id = Int32(documentIndex)
            for value in document.nameValues {
                let words = value.words
                let isDestination = value.kind.buildsCompounds
                for start in words.indices {
                    for end in (start + 1)...min(words.count, start + Self.maxNameWords) {
                        let key = words[start..<end].joined(separator: " ")
                        var phrase = names[key] ?? NamePhrase()
                        if phrase.documents.last != id { phrase.documents.append(id) }
                        let whole = start == 0 && end == words.count
                        // A lone alternate-name word that names nothing alone
                        // (`Prefecture`) is no name.
                        let noise = value.isAlternate && end - start == 1
                            && TripSearchDocument.isAlternateNoise(words[start], inName: words)
                        if isDestination, !noise {
                            phrase.isDestination = true
                            if whole { phrase.isCompleteDestination = true }
                        } else if value.kind == .transit {
                            phrase.isTransit = true
                            if whole { phrase.isCompleteTransit = true }
                        }
                        names[key] = phrase
                    }
                }
            }
        }
        self.namePhrases = names
    }

    /// A run of adjacent words inside one value of some document (never
    /// across values), and where it occurs.
    nonisolated struct NamePhrase: Sendable {
        /// The documents with it in a value of any field but dates.
        var documents: [Int32] = []
        /// Inside a place, region or country value; the whole of one.
        var isDestination = false
        var isCompleteDestination = false
        /// Inside a transit value; the whole of one.
        var isTransit = false
        var isCompleteTransit = false
    }

    /// Words of the longest name phrases the index keeps.
    static let maxNameWords = 8

    /// The name phrase of normalized words joined by spaces, if some
    /// document has it.
    func namePhrase(_ key: String) -> NamePhrase? { namePhrases[key] }

    var isEmpty: Bool { documents.isEmpty }

    /// Whole normalized words of the place, region and country fields of one
    /// document, excluding compounds (the parser's strict place reading).
    func strictPlaceWords(of documentIndex: Int) -> Set<String> {
        documents[documentIndex].strictPlaceWords
    }

    /// Whole normalized words of every field of one document, no compounds.
    func wholeWords(of documentIndex: Int) -> Set<String> {
        documents[documentIndex].wholeWords
    }

    /// True when any document has any normalized form of `word` as a whole
    /// word (not a compound) in any field.
    func containsWord(_ word: String) -> Bool {
        TripSearch.normalizedSearchForms(word).contains { form in
            guard let id = wordIDs[form] else { return false }
            return wholeWordKinds[Int(id)] != 0
        }
    }

    /// True when any document has a normalized form of `word` as a whole
    /// word in a field of one of `kinds`.
    func containsWord(_ word: String, in kinds: Set<TripSearchFieldKind>) -> Bool {
        let mask = kinds.reduce(UInt8(0)) { $0 | (UInt8(1) << UInt8($1.ordinal)) }
        return TripSearch.normalizedSearchForms(word).contains { form in
            guard let id = wordIDs[form] else { return false }
            return wholeWordKinds[Int(id)] & mask != 0
        }
    }

    /// Distinct strict place words (place, region, country; no compounds)
    /// of any document that start with the native normalized `prefix`.
    func strictPlaceWords(withPrefix prefix: String) -> [String] {
        guard let form = TripSearch.normalizedSearchForms(prefix).first else { return [] }
        let placeKinds: UInt8 = (1 << TripSearchFieldKind.place.ordinal)
            | (1 << TripSearchFieldKind.region.ordinal) | (1 << TripSearchFieldKind.country.ordinal)
        let key = form.unicodeScalars.map(\.value)
        var result: [String] = []
        var position = lowerBound(key)
        while position < sortedIDs.count {
            let id = Int(sortedIDs[position])
            guard scalars[id].starts(with: key) else { break }
            if wholeWordKinds[id] & placeKinds != 0 {
                result.append(vocabulary[id])
            }
            position += 1
        }
        return result
    }

    /// First position in `sortedIDs` whose word is not below `key`.
    func lowerBound(_ key: [UInt32]) -> Int {
        var low = 0
        var high = sortedIDs.count
        while low < high {
            let mid = (low + high) / 2
            if scalars[Int(sortedIDs[mid])].lexicographicallyPrecedes(key) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// Distinct documents a word appears in, over the given kinds.
    func documentCount(ofWord id: Int, kinds: Set<TripSearchFieldKind>) -> Int {
        var last: Int32 = -1
        var count = 0
        for posting in postings[id] where kinds.contains(TripSearchFieldKind.byOrdinal[Int(posting.kind)]) {
            if posting.document != last {
                count += 1
                last = posting.document
            }
        }
        return count
    }
}

// MARK: - Text

/// Normalization and script helpers shared by documents, terms and tables.
nonisolated enum TripSearchText {
    static let separators = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)
    /// Separators compounds never span: list punctuation, not word-internal
    /// hyphens, apostrophes, periods or the katakana middle dot (サン・フランシスコ).
    static let listBreaks: Set<Unicode.Scalar> = [
        ",", ";", "&", "/", "|", "+", "(", ")", "[", "]", "·", "、", "，", "；",
    ]

    private static let foldOptions: String.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
    ]
    private static let latinASCII = StringTransform("Latin-ASCII")
    private static let anyLatinASCII = StringTransform("Any-Latin; Latin-ASCII")
    private static let greekUNGEGN = StringTransform("Greek-Latin/UNGEGN; Latin-ASCII")

    /// Native form (case, diacritic and width folded, then Latin-ASCII so
    /// đ ø ł æ þ ı ß fold), a Latin form (`Any-Latin; Latin-ASCII`, omitted
    /// for Han), for Greek a UNGEGN form, and with ä, ö, ü, ø or å the
    /// native form with them spelled out (`umlautSpelling`). Deduplicated,
    /// trimmed, the native form first. ASCII input skips every transform.
    static func forms(_ value: String) -> [String] {
        if value.utf8.allSatisfy({ $0 < 0x80 }) {
            let form = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return form.isEmpty ? [] : [form]
        }
        let folded = value.lowercased().folding(options: foldOptions, locale: nil)
        var candidates = [folded.applyingTransform(latinASCII, reverse: false)?.lowercased() ?? folded]
        let scalars = value.unicodeScalars
        if !scalars.contains(where: { $0.properties.isIdeographic }),
           let latin = value.applyingTransform(anyLatinASCII, reverse: false) {
            candidates.append(latin.lowercased().folding(options: foldOptions, locale: nil))
        }
        if scalars.contains(where: isGreek),
           let greek = value.applyingTransform(greekUNGEGN, reverse: false) {
            candidates.append(greek.lowercased().folding(options: foldOptions, locale: nil))
        }
        if let spelled = umlautSpelling(value) { candidates.append(spelled) }
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    /// Letters people spell out without the key for them (German and Nordic
    /// convention: München as Muenchen, Tromsø as Tromsoe).
    private static let spelledOutLetters: [Character: String] = [
        "ä": "ae", "ö": "oe", "ü": "ue", "ø": "oe", "å": "aa",
    ]

    /// The native form with ä, ö, ü, ø and å spelled out, or nil when the
    /// value has none. It is the same script, so an alternate name indexes
    /// it too (`muenchen` finds Munich through its German name).
    static func umlautSpelling(_ value: String) -> String? {
        let lowered = value.lowercased().precomposedStringWithCanonicalMapping
        guard lowered.contains(where: { spelledOutLetters[$0] != nil }) else { return nil }
        let spelled = lowered.map { spelledOutLetters[$0] ?? String($0) }.joined()
        let folded = spelled.folding(options: foldOptions, locale: nil)
        let form = (folded.applyingTransform(latinASCII, reverse: false)?.lowercased() ?? folded)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return form.isEmpty ? nil : form
    }

    /// The native form alone (recognition tables need no transliteration).
    static func nativeForm(_ value: String) -> String {
        if value.utf8.allSatisfy({ $0 < 0x80 }) {
            return value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let folded = value.lowercased().folding(options: foldOptions, locale: nil)
        return (folded.applyingTransform(latinASCII, reverse: false)?.lowercased() ?? folded)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words of a normalized form, split on whitespace, punctuation and
    /// symbols; pieces without a letter or digit are dropped.
    static func words(_ form: String) -> [String] {
        segments(form).flatMap { $0 }
    }

    /// Words grouped into runs that list punctuation does not interrupt.
    static func segments(_ form: String) -> [[String]] {
        var result: [[String]] = []
        var segment: [String] = []
        var word = String.UnicodeScalarView()
        func flushWord() {
            // Leftover variation selectors or joiners from emoji are not words.
            if word.contains(where: { $0.properties.isAlphabetic || $0.properties.numericType != nil }) {
                segment.append(String(word))
            }
            word = String.UnicodeScalarView()
        }
        for scalar in form.unicodeScalars {
            if separators.contains(scalar) {
                flushWord()
                if listBreaks.contains(scalar), !segment.isEmpty {
                    result.append(segment)
                    segment = []
                }
            } else {
                word.append(scalar)
            }
        }
        flushWord()
        if !segment.isEmpty { result.append(segment) }
        return result
    }

    /// Raw query tokens with their ranges, split on the separator set.
    static func rawTokens(_ text: String) -> [(text: String, range: Range<String.Index>)] {
        var result: [(String, Range<String.Index>)] = []
        var start: String.Index?
        var index = text.unicodeScalars.startIndex
        while index < text.unicodeScalars.endIndex {
            let scalar = text.unicodeScalars[index]
            if separators.contains(scalar) {
                if let begin = start {
                    result.append((String(text.unicodeScalars[begin..<index]), begin..<index))
                    start = nil
                }
            } else if start == nil {
                start = index
            }
            index = text.unicodeScalars.index(after: index)
        }
        if let begin = start {
            result.append((String(text.unicodeScalars[begin...]), begin..<text.unicodeScalars.endIndex))
        }
        return result
    }

    static func endsWithSeparator(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last else { return true }
        return separators.contains(last)
    }

    /// Han, kana, Hangul, and scripts written without spaces (Thai, Lao,
    /// Khmer, Myanmar): infix counts as a word match, never fuzzy.
    static func isCJK(_ value: UInt32) -> Bool {
        switch value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0x3005, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0x20000...0x2FFFF, 0xFF66...0xFF9F,
             0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF,
             0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF:
            return true
        default:
            return false
        }
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool { isCJK(scalar.value) }

    static func isHanOrKana(_ value: UInt32) -> Bool {
        switch value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0x3005, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0x20000...0x2FFFF:
            return true
        default:
            return false
        }
    }

    static func isHangulSyllable(_ scalar: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7AF).contains(scalar.value)
    }

    /// Greeklish skeletons of a normalized word: Greek and the Latin letters
    /// people type for it fold to one spelling, so χ, `x`, `ch`, `kh` and
    /// `h` meet, as do η, ι, υ, ει, οι and `i`, `y`; ο, ω and `o`, `w`;
    /// αι, ε and `ai`, `e`; ου and `ou`, `u`; θ and `th`, `8`; μπ and `b`,
    /// `mp`; ντ and `d`, `nt`; doubled letters once. A Latin `h` (χ or η)
    /// and `x` (χ or ξ) give each reading. Empty for a word of neither
    /// script, or one shorter than four letters.
    static func greeklishSkeletons(_ word: String) -> Set<String> {
        let scalars = Array(word.unicodeScalars)
        guard scalars.count >= 4 else { return [] }
        if scalars.allSatisfy(isGreek) {
            return [collapse(greekSkeleton(String(scalars.map(Character.init))))]
        }
        guard scalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || $0 == "8" || $0 == "3") }) else { return [] }
        var variants = [""]
        var index = 0
        let letters = scalars.map(Character.init)
        func add(_ options: [String]) {
            variants = options.count == 1 || variants.count >= 8
                ? variants.map { $0 + options[0] }
                : variants.flatMap { prefix in options.map { prefix + $0 } }
        }
        let pairs: [String: String] = [
            "ou": "u", "ai": "e", "ei": "i", "oi": "i", "ui": "i", "au": "av", "eu": "ev",
            "th": "th", "ch": "x", "kh": "x", "ph": "f", "ps": "ps", "ks": "ks", "mp": "b", "nt": "d",
            "dh": "d", "gk": "g", "gg": "g", "ts": "ts", "tz": "tz",
        ]
        let singles: [Character: [String]] = [
            "a": ["a"], "b": ["b"], "c": ["k"], "d": ["d"], "e": ["e"], "f": ["f"], "g": ["g"],
            "h": ["x", "i"], "i": ["i"], "j": ["tz"], "k": ["k"], "l": ["l"], "m": ["m"], "n": ["n"],
            "o": ["o"], "p": ["p"], "q": ["k"], "r": ["r"], "s": ["s"], "t": ["t"], "u": ["u"],
            "v": ["v"], "w": ["o"], "x": ["x", "ks"], "y": ["i"], "z": ["z"], "8": ["th"], "3": ["ks"],
        ]
        while index < letters.count {
            if index + 1 < letters.count, let pair = pairs[String(letters[index...index + 1])] {
                add([pair])
                index += 2
            } else {
                add(singles[letters[index]] ?? [String(letters[index])])
                index += 1
            }
        }
        return Set(variants.map(collapse))
    }

    private static func greekSkeleton(_ word: String) -> String {
        let pairs: [String: String] = [
            "ου": "u", "αι": "e", "ει": "i", "οι": "i", "υι": "i", "αυ": "av", "ευ": "ev",
            "μπ": "b", "ντ": "d", "γγ": "g", "γκ": "g", "τσ": "ts", "τζ": "tz",
        ]
        let singles: [Character: String] = [
            "α": "a", "β": "v", "γ": "g", "δ": "d", "ε": "e", "ζ": "z", "η": "i", "θ": "th",
            "ι": "i", "κ": "k", "λ": "l", "μ": "m", "ν": "n", "ξ": "ks", "ο": "o", "π": "p",
            "ρ": "r", "σ": "s", "ς": "s", "τ": "t", "υ": "i", "φ": "f", "χ": "x", "ψ": "ps", "ω": "o",
        ]
        let letters = Array(word)
        var result = ""
        var index = 0
        while index < letters.count {
            if index + 1 < letters.count, let pair = pairs[String(letters[index...index + 1])] {
                result += pair
                index += 2
            } else {
                result += singles[letters[index]] ?? String(letters[index])
                index += 1
            }
        }
        return result
    }

    /// Doubled letters once (`σσ`, `ll`).
    private static func collapse(_ skeleton: String) -> String {
        var result = ""
        for character in skeleton where character != result.last { result.append(character) }
        return result
    }

    /// A lowercase ASCII word with the long o and u of Japanese place names
    /// written once: ou, oo and uu fold to o and u (`toukyou`, `tokyo` and
    /// Hepburn `tōkyō` folded all give `tokyo`, `kyuushuu` gives `kyushu`).
    /// Long a, e and i stay: Hepburn names keep them (Niigata), and a doubled
    /// one is a typo, not a spelling.
    static func longVowelSkeleton(_ word: String) -> String {
        var result = ""
        var previous: Character?
        for character in word {
            if previous == "o", character == "o" || character == "u" { continue }
            if previous == "u", character == "u" { continue }
            result.append(character)
            previous = character
        }
        return result
    }

    /// The vowel of each katakana syllable, small ones included.
    private static let kanaVowels: [Character: Character] = {
        var table: [Character: Character] = [:]
        for (vowel, row) in [
            ("a", "アカガサザタダナハバパマヤャラワァヮ"), ("i", "イキギシジチヂニヒビピミリヰィ"),
            ("u", "ウクグスズツヅヌフブプムユュルヴゥ"), ("e", "エケゲセゼテデネヘベペメレヱェ"),
            ("o", "オコゴソゾトドノホボポモヨョロヲォ"),
        ] as [(Character, String)] {
            for kana in row { table[kana] = vowel }
        }
        return table
    }()

    /// A kana word in katakana with long vowels written once: the
    /// prolonged sound mark, a ウ after an o or u syllable and a vowel kana
    /// repeating its syllable's vowel are dropped (ソウル, ソール and そうる
    /// all give ソル; とうきょう gives トキョ like トウキョウ).
    static func kanaLongVowelSkeleton(_ word: String) -> String {
        var result = ""
        var vowel: Character?
        for scalar in word.unicodeScalars {
            var value = scalar.value
            if (0x3041...0x3096).contains(value) { value += 0x60 }
            guard let character = Unicode.Scalar(value).map(Character.init) else { continue }
            if character == "ー" { continue }
            let own = kanaVowels[character]
            if let vowel, "アイウエオ".contains(character),
               own == vowel || (character == "ウ" && (vowel == "o" || vowel == "u")) {
                continue
            }
            result.append(character)
            vowel = own
        }
        return result
    }

    /// Hiragana, katakana and the prolonged sound mark.
    static func isKana(_ value: UInt32) -> Bool {
        (0x3041...0x309F).contains(value) || (0x30A0...0x30FF).contains(value) || (0x31F0...0x31FF).contains(value)
    }

    static func isGreek(_ scalar: Unicode.Scalar) -> Bool {
        (0x0370...0x03FF).contains(scalar.value) || (0x1F00...0x1FFF).contains(scalar.value)
    }

    /// ASCII digits or Han numerals: never infix on date words.
    static func isDigitLike(_ value: UInt32) -> Bool {
        switch value {
        case 48...57, 0x3007, 0x4E00, 0x4E8C, 0x4E09, 0x56DB, 0x4E94, 0x516D, 0x4E03, 0x516B,
             0x4E5D, 0x5341, 0x767E, 0x5343:
            return true
        default:
            return false
        }
    }

    /// Every letter is Latin (spaces and marks allowed).
    static func isLatinScript(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            !scalar.properties.isAlphabetic
                || scalar.value < 0x0250
                || (0x1E00...0x1EFF).contains(scalar.value)
        }
    }

    /// Latin, Greek or Cyrillic letters only (spelling suggestions).
    static func isAlphabeticEuropean(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            guard scalar.properties.isAlphabetic else { return false }
            let value = scalar.value
            return value < 0x0250 || (0x1E00...0x1EFF).contains(value)
                || (0x0370...0x03FF).contains(value) || (0x1F00...0x1FFF).contains(value)
                || (0x0400...0x04FF).contains(value)
        }
    }

    /// One root-locale word tokenizer, reset per call. Creating one costs
    /// more than segmenting a word; the lock covers Siri's off-main parses.
    private static let rootTokenizer = OSAllocatedUnfairLock<CFStringTokenizer?>(uncheckedState: nil)

    /// Word boundaries for a Han or kana run, root locale (the zh-Hans
    /// locale splits 東京 into 東 and 京).
    static func segmentCJK(_ text: String) -> [String] {
        let string = text as CFString
        let length = CFStringGetLength(string)
        guard length > 0 else { return [text] }
        let nsText = text as NSString
        let result: [String] = rootTokenizer.withLockUnchecked { cached in
            let range = CFRangeMake(0, length)
            if let cached {
                CFStringTokenizerSetString(cached, string, range)
            } else {
                cached = CFStringTokenizerCreate(
                    nil, string, range, kCFStringTokenizerUnitWordBoundary,
                    CFLocaleCreate(nil, CFLocaleIdentifier("root" as CFString)))
            }
            guard let tokenizer = cached else { return [] }
            var tokens: [String] = []
            while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
                let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                let token = nsText.substring(with: NSRange(location: range.location, length: range.length))
                let trimmed = token.trimmingCharacters(in: separators)
                if !trimmed.isEmpty { tokens.append(trimmed) }
            }
            // Do not keep the caller's string alive until the next call.
            CFStringTokenizerSetString(tokenizer, "" as CFString, CFRangeMake(0, 0))
            return tokens
        }
        return result.isEmpty ? [text] : result
    }
}

// MARK: - Engine

/// The tiered matcher behind `TripSearch.match(terms:in:)`.
nonisolated enum TripSearchEngine {
    static let none: UInt8 = 255
    static let tierExact: UInt8 = 0
    static let tierPrefix: UInt8 = 1
    static let tierAlias: UInt8 = 2
    static let tierInfix: UInt8 = 3
    static let tierFuzzy: UInt8 = 4
    static let tierFuzzyPrefix: UInt8 = 5
    static let strongLimit: UInt8 = 2

    /// Per document result of one sub-token or alternative.
    nonisolated struct Hit {
        var any: UInt8 = none
        /// Best tier through a field other than transit.
        var strong: UInt8 = none
        var title = false
        /// Through a title the user named (`userNamedFields`).
        var ownTitle = false
        var evidenceRank: UInt8 = none
        var evidenceWord: Int32 = -1
        var evidencePosting: Int32 = -1
    }

    private nonisolated struct SubTokenKey: Hashable {
        let text: String
        let trailing: Bool
        /// 0 literal, 1 alias, 2 city, 3 alias of places in Japan, 4 island stem.
        let source: UInt8
        /// The term already matched exactly elsewhere: no weak tiers.
        let termGated: Bool
        /// The term was typed without Latin letters.
        var romanized = false
        /// A finished region or country name: exact words only.
        var exactOnly = false
    }

    private nonisolated struct Context {
        let index: TripSearchIndex
        let allowed: [Bool]
        var cache: [SubTokenKey: [Hit]] = [:]
        var scratch = EditDistance()

        func allows(_ kind: UInt8) -> Bool { allowed[Int(kind)] }
    }

    static func match(
        terms: [TripSearchTerm],
        in index: TripSearchIndex,
        fields: Set<TripSearchFieldKind>?
    ) -> [TripSearchMatch] {
        let count = index.documents.count
        guard !terms.isEmpty else {
            return (0..<count).map { TripSearchMatch(documentIndex: $0, strength: .strong, evidence: []) }
        }
        guard count > 0 else { return [] }
        let allowed = TripSearchFieldKind.byOrdinal.map { fields?.contains($0) ?? true }
        var context = Context(index: index, allowed: allowed)

        // Adjacent query words joined ("hong kong" typed against "hongkong").
        var joined: [Int: [Hit]] = [:]
        if terms.count >= 2 {
            for position in 0..<(terms.count - 1) {
                guard let left = joinable(terms[position]), let right = joinable(terms[position + 1]) else { continue }
                joined[position] = joinedHits(
                    left + right, trailing: terms[position + 1].isTrailingPartial, context: &context)
            }
        }

        var termHits: [[Hit]] = []
        termHits.reserveCapacity(terms.count)
        for (position, term) in terms.enumerated() {
            // Exact alternatives first: any hit gates the literal weak tiers.
            var exact: [[Hit]] = []
            for alternative in term.aliasAlternatives where !alternative.isEmpty {
                let subHits = alternative.map { aliasHits($0, placeOnly: false, context: &context) }
                exact.append(combine(subHits, count: count))
            }
            for alternative in term.cityAlternatives where !alternative.isEmpty {
                let subHits = alternative.map { aliasHits($0, placeOnly: true, context: &context) }
                exact.append(combine(subHits, count: count))
            }
            for stem in term.islandStems where !stem.isEmpty {
                exact.append(combine(stem.map { islandStemHits($0, context: &context) }, count: count))
            }
            if !term.countryCodes.isEmpty, allowed[TripSearchFieldKind.country.ordinal] {
                exact.append(codeHits(term.countryCodes, context: context))
            }
            if let hits = joined[position] { exact.append(hits) }
            if position > 0, let hits = joined[position - 1] { exact.append(hits) }
            // Greeklish: a Latin word whose skeleton is a Greek place word's
            // (`xarokampos` for Χαρόκαμπος), exact words only, also while
            // the word is being typed. A word some trip has as typed is that
            // word, not a spelling of another.
            if !index.greekWordsBySkeleton.isEmpty, term.alternatives.count >= 1,
               let typed = term.alternatives.first, typed.count == 1, !index.containsWord(typed[0]) {
                for skeleton in TripSearchText.greeklishSkeletons(typed[0]) {
                    for word in index.greekWordsBySkeleton[skeleton] ?? [] {
                        exact.append(aliasHits(word, placeOnly: false, context: &context))
                    }
                }
            }
            // Japanese long vowels: a romanization that spells them out
            // (wapuro `toukyou`, `oosaka`) or kana that writes them another
            // way (ソール for ソウル) is the place word with the same
            // `longVowelSkeleton` or `kanaLongVowelSkeleton`, exact words
            // only. Typed Latin needs an ou, oo or uu and finds only names
            // of places in Japan (`loundon` stays a typo of London, also on
            // a London and Tokyo trip; `hoorn` is no spelling of Horn); a
            // word some trip has as typed is that word.
            if !index.wordsByLongVowelSkeleton.isEmpty {
                let kanaTyped = term.raw.unicodeScalars.contains { TripSearchText.isKana($0.value) }
                    && !term.raw.unicodeScalars.contains { $0.isASCII && $0.properties.isAlphabetic }
                for alternative in term.alternatives where alternative.count == 1 {
                    let token = alternative[0]
                    let scalars = token.unicodeScalars
                    let skeleton: String
                    if scalars.count >= 4, scalars.allSatisfy({ $0.isASCII && $0.properties.isAlphabetic }) {
                        skeleton = TripSearchText.longVowelSkeleton(token)
                        guard skeleton != token || kanaTyped else { continue }
                    } else if kanaTyped, scalars.count >= 2, scalars.allSatisfy({ TripSearchText.isKana($0.value) }) {
                        skeleton = TripSearchText.kanaLongVowelSkeleton(token)
                    } else {
                        continue
                    }
                    guard skeleton.count >= 2, !index.containsWord(token) else { continue }
                    for word in index.wordsByLongVowelSkeleton[skeleton] ?? [] {
                        exact.append(aliasHits(word, placeOnly: false, japanOnly: !kanaTyped, context: &context))
                    }
                }
            }
            // A recognized region or country name is not a typo, whether or
            // not any trip has that country ("china" never finds Chicago).
            let termGated = !term.countryCodes.isEmpty || exact.contains { $0.contains { $0.any != none } }
            // Typed without Latin letters: its Latin alternatives are
            // romanizations (see `literalHits`).
            let romanized = !term.raw.unicodeScalars.contains { $0.isASCII && $0.properties.isAlphabetic }
            // A finished region or country name matches its words only as
            // whole words ("austria" never finds a street named "Austriana"); its
            // code alternative already finds every trip in the country.
            let exactOnly = !term.countryCodes.isEmpty && !term.isTrailingPartial
            var alternatives: [[Hit]] = []
            for alternative in term.alternatives where !alternative.isEmpty {
                var subHits: [[Hit]] = []
                for (offset, token) in alternative.enumerated() {
                    let trailing = term.isTrailingPartial && offset == alternative.count - 1
                    // A romanization under 4 letters is a whole word or
                    // nothing: ソウ (`sou`) does not prefix South Korea. A 1
                    // to 2 syllable Hangul or Greek prefix (파, Ρό) likewise
                    // no longer prefixes English names through `pa` or `ro`;
                    // its native form still prefixes the other-language
                    // names while typed (파리, Ρόδος).
                    let shortRomanization = romanized && token.unicodeScalars.count < 4
                        && token.unicodeScalars.allSatisfy { $0.isASCII }
                        && token.unicodeScalars.contains { $0.properties.isAlphabetic }
                    subHits.append(literalHits(
                        token, trailing: trailing, termGated: termGated, romanized: romanized,
                        exactOnly: exactOnly || shortRomanization, context: &context))
                }
                alternatives.append(combine(subHits, count: count))
            }
            termHits.append(best(of: alternatives + exact, count: count))
        }
        preferWholeNames(terms: terms, hits: &termHits, context: context)

        var matches: [TripSearchMatch] = []
        for document in 0..<count {
            var strong = true
            var matched = true
            for (position, hits) in termHits.enumerated() {
                let hit = hits[document]
                if hit.any == none { matched = false; break }
                if (terms[position].namesStop ? hit.any : hit.strong) > strongLimit { strong = false }
            }
            guard matched else { continue }
            var evidence: [TripSearchEvidence] = []
            for (position, hits) in termHits.enumerated() {
                let hit = hits[document]
                guard !hit.title, hit.evidenceRank != none,
                      let item = evidenceItem(hit, document: document, term: terms[position], index: index)
                else { continue }
                evidence.append(item)
            }
            matches.append(TripSearchMatch(
                documentIndex: document,
                strength: strong ? .strong : .similar,
                evidence: evidence))
        }
        return matches
    }

    // MARK: Alternatives

    /// A term's one word, which joins its neighbour's into a compound. Han,
    /// kana and Hangul words join only for whole names (サン・フランシスコ is
    /// サンフランシスコ); they match compounds by segments.
    private static func joinable(_ term: TripSearchTerm, includingCJK: Bool = false) -> String? {
        guard !term.isNumeric, let first = term.alternatives.first, first.count == 1,
              includingCJK || !first[0].unicodeScalars.contains(where: isCJK) else { return nil }
        return first[0]
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool { TripSearchText.isCJK(scalar) }

    /// Worst tier of the sub-tokens, per document (all must match).
    private static func combine(_ subHits: [[Hit]], count: Int) -> [Hit] {
        guard var result = subHits.first else { return Array(repeating: Hit(), count: count) }
        guard subHits.count > 1 else { return result }
        for document in 0..<count {
            var hit = result[document]
            for other in subHits.dropFirst() {
                let next = other[document]
                hit.any = max(hit.any, next.any)
                hit.strong = max(hit.strong, next.strong)
                hit.title = hit.title || next.title
                hit.ownTitle = hit.ownTitle || next.ownTitle
                if hit.evidenceRank == none {
                    hit.evidenceRank = next.evidenceRank
                    hit.evidenceWord = next.evidenceWord
                    hit.evidencePosting = next.evidencePosting
                }
            }
            if hit.any == none { hit = Hit() }
            result[document] = hit
        }
        return result
    }

    /// Best alternative per document: the lowest strong tier, then the
    /// lowest tier; the title flag is set when any matching alternative hit it.
    private static func best(of alternatives: [[Hit]], count: Int) -> [Hit] {
        var result = Array(repeating: Hit(), count: count)
        for alternative in alternatives {
            for document in 0..<count {
                let candidate = alternative[document]
                guard candidate.any != none else { continue }
                var current = result[document]
                let title = current.title || candidate.title
                let ownTitle = current.ownTitle || candidate.ownTitle
                if current.any == none
                    || candidate.strong < current.strong
                    || (candidate.strong == current.strong && candidate.any < current.any) {
                    current = candidate
                }
                current.title = title
                current.ownTitle = ownTitle
                result[document] = current
            }
        }
        return result
    }

    // MARK: Whole names

    /// The words a query (or one of its terms) covers in a stored name:
    /// literal and alias tokens as whole words, the last token of a literal
    /// alternative also as a prefix while it is being typed, and city
    /// abbreviations, typed compounds and joined query words as a whole
    /// name ("nyc", "newyork" and "new york" cover New York).
    private nonisolated struct NameCover {
        var words = Set<String>()
        var prefixes: [String] = []
        var names = Set<String>()

        mutating func add(_ term: TripSearchTerm) {
            for alternative in term.alternatives where !alternative.isEmpty {
                words.formUnion(alternative)
                if alternative.count == 1 { names.insert(alternative[0]) }
                if term.isTrailingPartial, let last = alternative.last { prefixes.append(last) }
            }
            for alternative in term.aliasAlternatives + term.cityAlternatives + term.islandStems
            where alternative.count == 1 {
                words.insert(alternative[0])
                names.insert(alternative[0])
            }
        }

        mutating func merge(_ other: NameCover) {
            words.formUnion(other.words)
            prefixes += other.prefixes
            names.formUnion(other.names)
        }

        func covers(_ word: String, typing: Bool) -> Bool {
            words.contains(word) || (typing && prefixes.contains { word.utf8.starts(with: $0.utf8) })
        }

        /// A multi-word name typed as one word, or being typed past its
        /// first word ("newyo").
        func coversJoined(_ name: TripSearchDocument.GeographicName, typing: Bool) -> Bool {
            names.contains(name.joined)
                || (typing && name.joined.utf8.count > name.first.utf8.count
                    && prefixes.contains {
                        $0.utf8.count > name.first.utf8.count && name.joined.utf8.starts(with: $0.utf8)
                    })
        }
    }

    /// True when `name` is whole for a term: the term covers one of its
    /// words and the query covers every one (connecting words aside), or
    /// the term covers it joined. `typing` admits the word being typed as a
    /// prefix.
    private static func isWholeName(
        _ name: TripSearchDocument.GeographicName, term: NameCover, query: NameCover, typing: Bool
    ) -> Bool {
        if term.coversJoined(name, typing: typing) { return true }
        return name.words.contains { term.covers($0, typing: typing) }
            && name.words.allSatisfy { query.covers($0, typing: typing) }
    }

    /// Whole-name precedence. When some trip has a term exactly as a whole
    /// place, region, country or alternate name, or the term names a
    /// country or region, a trip that has the term only as a word of a longer,
    /// different name ("Baja California" for `california`, "New York" for
    /// `york`, a street "Paseo de Austria" for `austria`) is similar,
    /// not strong. A name the word being typed completes is whole too (it
    /// keeps "Barcelona" strong while `bar` also names Bar), but only an
    /// exact name demotes others, so `san` with Santavelia keeps San Diego.
    /// A trip whose own title has the term stays strong.
    private static func preferWholeNames(terms: [TripSearchTerm], hits termHits: inout [[Hit]], context: Context) {
        var covers = Array(repeating: NameCover(), count: terms.count)
        var query = NameCover()
        for (position, term) in terms.enumerated() {
            covers[position].add(term)
            if position + 1 < terms.count, let left = joinable(term, includingCJK: true),
               let right = joinable(terms[position + 1], includingCJK: true) {
                covers[position].names.insert(left + right)
                covers[position + 1].names.insert(left + right)
            }
        }
        for cover in covers { query.merge(cover) }
        let index = context.index
        let codesAllowed = context.allows(UInt8(TripSearchFieldKind.country.ordinal))
        // A connecting word ("de" of "Vessa de Lunero") names nothing.
        let connecting: (TripSearchTerm) -> Bool = { term in
            term.cityAlternatives.isEmpty && term.aliasAlternatives.isEmpty && term.countryCodes.isEmpty
                && term.alternatives.allSatisfy { $0.allSatisfy(TripSearchAliases.nameStopWords.contains) }
        }
        let destination: UInt8 = (1 << TripSearchFieldKind.place.ordinal)
            | (1 << TripSearchFieldKind.region.ordinal) | (1 << TripSearchFieldKind.country.ordinal)
        for (position, term) in terms.enumerated()
        where !term.isNumeric && !term.alternatives.isEmpty && !connecting(term) {
            let cover = covers[position]
            let hits = termHits[position]
            // An exact whole name lies in a document with one of the term's
            // words (or compounds) exactly in a destination field. A
            // recognized region or country name is whole whether or not any
            // trip is there ("austria" with no Austria trip still ranks
            // "Paseo de Austria" similar), but with no trip there and
            // no exact name, an administrative area of another country that
            // is the same name with a compass qualifier (Northern Ireland)
            // stays strong; New Mexico is no Mexico.
            var triggered = false
            var checked = Set<Int32>()
            for token in cover.words.union(cover.names) where !triggered {
                guard let id = index.wordIDs[token] else { continue }
                for posting in index.postings[Int(id)]
                where (destination >> posting.kind) & 1 == 1 && context.allows(posting.kind)
                    && hits[Int(posting.document)].strong <= strongLimit && checked.insert(posting.document).inserted {
                    triggered = index.documents[Int(posting.document)].geographicNames.contains { name in
                        name.kind != .transit && context.allows(UInt8(name.kind.ordinal))
                            && isWholeName(name, term: cover, query: query, typing: false)
                    }
                    if triggered { break }
                }
            }
            let unvisitedName = !triggered && !term.countryCodes.isEmpty
                && !term.countryCodes.contains { index.documentsByCountryCode[$0] != nil }
            triggered = triggered || !term.countryCodes.isEmpty
            guard triggered else { continue }
            for document in 0..<index.documents.count
            where hits[document].strong <= strongLimit && !hits[document].ownTitle {
                let doc = index.documents[document]
                if codesAllowed, !term.countryCodes.isDisjoint(with: doc.countryCodes) { continue }
                // Transit names never protect: a transit match is similar anyway.
                let whole = doc.geographicNames.contains { name in
                    name.kind != .transit && context.allows(UInt8(name.kind.ordinal))
                        && (isWholeName(name, term: cover, query: query, typing: true)
                            || (unvisitedName && name.kind == .region
                                && term.alternatives.contains(name.words.filter {
                                    !TripSearchAliases.compassWords.contains($0)
                                })))
                }
                if !whole { termHits[position][document].strong = tierInfix }
            }
        }
    }

    private static func codeHits(_ codes: Set<String>, context: Context) -> [Hit] {
        var result = Array(repeating: Hit(), count: context.index.documents.count)
        for code in codes {
            for document in context.index.documentsByCountryCode[code] ?? [] {
                result[Int(document)] = Hit(
                    any: tierAlias, strong: tierAlias, title: false,
                    evidenceRank: UInt8(TripSearchFieldKind.country.evidenceRank * 8) + tierAlias,
                    evidenceWord: -2, evidencePosting: -1)
            }
        }
        return result
    }

    private static func evidenceItem(
        _ hit: Hit,
        document: Int,
        term: TripSearchTerm,
        index: TripSearchIndex
    ) -> TripSearchEvidence? {
        if hit.evidenceWord == -2 {
            let codes = index.documents[document].countryCodes.intersection(term.countryCodes)
            guard let code = codes.sorted().first else { return nil }
            return TripSearchEvidence(kind: .country, text: code)
        }
        guard hit.evidenceWord >= 0 else { return nil }
        let posting = index.postings[Int(hit.evidenceWord)][Int(hit.evidencePosting)]
        let field = index.documents[document].fields[Int(posting.field)]
        let value = Int(posting.value)
        return TripSearchEvidence(
            kind: TripSearchFieldKind.byOrdinal[Int(posting.kind)],
            text: field.isAlternate ? field.alternateOf[value] : field.displayValues[value])
    }

    // MARK: Sub-tokens

    /// Records one word's postings at `tier` (compound postings at T2 or
    /// worse; `filter` may drop postings). Returns a bit per recorded kind.
    @discardableResult
    private static func record(
        word id: Int32,
        tier: UInt8,
        into result: inout [Hit],
        context: Context,
        filter: (TripSearchIndex.Posting) -> Bool = { _ in true }
    ) -> UInt8 {
        var kinds: UInt8 = 0
        let postings = context.index.postings[Int(id)]
        for (offset, posting) in postings.enumerated() where context.allows(posting.kind) && filter(posting) {
            kinds |= 1 << posting.kind
            let postingTier = posting.isCompound ? max(tier, tierAlias) : tier
            let document = Int(posting.document)
            var hit = result[document]
            hit.any = min(hit.any, postingTier)
            let kind = TripSearchFieldKind.byOrdinal[Int(posting.kind)]
            if kind != .transit { hit.strong = min(hit.strong, postingTier) }
            if kind == .title {
                hit.title = true
                if postingTier <= strongLimit,
                   context.index.documents[document].userNamedFields.contains(Int(posting.field)) {
                    hit.ownTitle = true
                }
            } else {
                let rank = UInt8(kind.evidenceRank * 8) + postingTier
                if rank < hit.evidenceRank {
                    hit.evidenceRank = rank
                    hit.evidenceWord = id
                    hit.evidencePosting = Int32(offset)
                }
            }
            result[document] = hit
        }
        return kinds
    }

    private static func literalHits(
        _ token: String,
        trailing: Bool,
        termGated: Bool,
        romanized: Bool = false,
        exactOnly: Bool = false,
        context: inout Context
    ) -> [Hit] {
        let key = SubTokenKey(
            text: token, trailing: trailing, source: 0, termGated: termGated, romanized: romanized,
            exactOnly: exactOnly)
        if let cached = context.cache[key] { return cached }
        let index = context.index
        let count = index.documents.count
        var result = Array(repeating: Hit(), count: count)
        let scalars = token.unicodeScalars.map(\.value)
        let length = scalars.count
        guard length > 0 else { return result }
        let isNumeric = scalars.allSatisfy { $0 >= 48 && $0 <= 57 }
        let hasDigit = scalars.contains(where: TripSearchText.isDigitLike)
        let isCJK = scalars.contains(where: TripSearchText.isCJK)
        let dateOrdinal = UInt8(TripSearchFieldKind.date.ordinal)
        // "of" or "and" alone never reaches a compound ("ofamerica"); typed
        // between two words the joined pair still does.
        let isStopWord = TripSearchAliases.nameStopWords.contains(token)
        let direct: (TripSearchIndex.Posting) -> Bool = { !(isStopWord && $0.isCompound) }
        // T0 exact.
        let exactID = index.wordIDs[token]
        // An alternate name is a prefix match only while it is being typed,
        // only of a whole word, and not when the typed word is already a
        // stored place, region, country, transit or date word ("Velde" with
        // a Velde district never starts "Veldenmark"; "May", read as
        // the month, never starts another language's "Mayo…"). A title word
        // is free text and does not count.
        let titleKind = UInt8(TripSearchFieldKind.title.ordinal)
        let typedIsStored = exactID.map { id in
            index.postings[Int(id)].contains { !$0.isAlternate && $0.kind != titleKind }
        } ?? false
        let directPrefix: (TripSearchIndex.Posting) -> Bool = { posting in
            direct(posting) && (!posting.isAlternate || (trailing && !posting.isCompound && !typedIsStored))
        }

        // Kinds with a T0 to T2 hit anywhere in the corpus.
        var strongKinds: UInt8 = 0

        if let id = exactID {
            strongKinds |= record(word: id, tier: tierExact, into: &result, context: context, filter: direct)
        }
        if exactOnly {
            context.cache[key] = result
            return result
        }

        // T1 prefix. Numeric tokens prefix numeric words at 3+ digits only,
        // and other words ("30th", "4x4") at any length outside date words
        // and compounds.
        var position = index.lowerBound(scalars)
        while position < index.sortedIDs.count {
            let id = index.sortedIDs[position]
            guard index.scalars[Int(id)].starts(with: scalars) else { break }
            if id != exactID {
                if !isNumeric || (length >= 3 && index.numericWord[Int(id)]) {
                    strongKinds |= record(
                        word: id, tier: tierPrefix, into: &result, context: context, filter: directPrefix)
                } else if !index.numericWord[Int(id)] {
                    strongKinds |= record(word: id, tier: tierPrefix, into: &result, context: context) { posting in
                        !posting.isCompound && posting.kind != dateOrdinal && !posting.isAlternate
                    }
                }
            }
            position += 1
        }
        // A 2 digit token is the last two digits of a year.
        if isNumeric, length == 2 {
            for id in index.yearIDs where index.scalars[Int(id)].suffix(2).elementsEqual(scalars) {
                strongKinds |= record(word: id, tier: tierPrefix, into: &result, context: context)
            }
        }
        // Scripts without spaces: infix is a word match. Digit-bearing tokens
        // never infix on date words (1月 inside 11月).
        if isCJK {
            for id in index.cjkIDs where id != exactID {
                let word = index.scalars[Int(id)]
                guard word.count > length, !word.starts(with: scalars), contains(word, scalars) else { continue }
                strongKinds |= record(word: id, tier: tierPrefix, into: &result, context: context) { posting in
                    !(hasDigit && posting.kind == dateOrdinal) && !posting.isAlternate
                }
            }
        }

        // Gating: weak tiers only in field kinds without a T0 to T2 hit
        // anywhere, judged by the posting's kind and its gate kind (never
        // date words, never compounds).
        var allowedKinds: UInt8 = 0
        for (ordinal, allowed) in context.allowed.enumerated() where allowed { allowedKinds |= 1 << UInt8(ordinal) }
        let gatedKinds = strongKinds
        let weakKinds = termGated ? 0 : allowedKinds & ~gatedKinds & ~(1 << dateOrdinal)
        if weakKinds != 0, !isCJK, !hasDigit, length >= 4 {
            let weak: (TripSearchIndex.Posting) -> Bool = { posting in
                !posting.isCompound && !posting.isAlternate
                    && (weakKinds >> posting.kind) & 1 == 1 && (gatedKinds >> posting.gateKind) & 1 == 0
            }
            let kinds = index.wholeWordKinds
            // A 4-letter romanization ("pali" for 파리, "rodo" for Ρόδο) is
            // too loose for T3 and T5 and only swaps a final vowel at T4
            // ("roma" for ローマ finds Rome).
            let romanized4 = romanized && length == 4 && scalars.allSatisfy { $0 < 0x80 }
            // Kinds with a T3 or T4 hit.
            var weakHitKinds: UInt8 = 0
            // T3 infix.
            for (_, ids) in index.idsByLength.buckets(from: length + 1) where !romanized4 {
                for id in ids
                where kinds[Int(id)] & weakKinds != 0 && contains(index.scalars[Int(id)], scalars) {
                    weakHitKinds |= record(word: id, tier: tierInfix, into: &result, context: context, filter: weak)
                }
            }
            // T4 fuzzy. The budget follows the corpus word: 2 edits reach
            // only 8+ letter words (barclna finds Barcelona, romantic does
            // not find Romania), with the first letter fixed unless the
            // sub-token is a long one with no T0 to T2 hit (mailand does not
            // find Thailand, estambul still finds Istanbul).
            let typedLong = length >= 8 && strongKinds == 0
            let reach = length >= 6 ? 2 : 1
            for (bucket, ids) in index.idsByLength.buckets(in: max(1, length - reach)...(length + reach)) {
                let budget = bucket >= 8 && length >= 6 ? 2 : 1
                guard abs(bucket - length) <= budget else { continue }
                for id in ids where kinds[Int(id)] & weakKinds != 0 {
                    let word = index.scalars[Int(id)]
                    if length == 4, word.first != scalars.first { continue }
                    if romanized4 {
                        guard word.count == 4, word.prefix(3).elementsEqual(scalars.prefix(3)),
                              isVowel(word[3]), isVowel(scalars[3]) else { continue }
                    }
                    if let distance = context.scratch.within(scalars[...], word[...], limit: budget) {
                        if distance == 2, !typedLong, word.first != scalars.first { continue }
                        weakHitKinds |= record(word: id, tier: tierFuzzy, into: &result, context: context, filter: weak)
                    }
                }
            }
            // T4 for a long foreign name of a shorter English place, when the
            // 8+ letter sub-token has no other hit at all: 2 edits to a word 2
            // letters shorter (lissabon finds Lisbon, florance with a
            // Florence trip does not find France), or to any word of 6 or 7
            // letters for a romanization (mikonosu for ミコノス).
            if typedLong, weakHitKinds == 0 {
                for bucket in [length - 2, length - 1]
                where bucket < 8 && (romanized || bucket == length - 2) {
                    for id in index.idsByLength[bucket] where kinds[Int(id)] & weakKinds != 0 {
                        let word = index.scalars[Int(id)]
                        if context.scratch.within(scalars[...], word[...], limit: 2) != nil {
                            record(word: id, tier: tierFuzzy, into: &result, context: context, filter: weak)
                        }
                    }
                }
            }
            // T5 fuzzy prefix while typing, only for a sub-token that does
            // not already match as typed somewhere. Deliberately never for a
            // finished word (Siri): tried as a last resort it turned "beach"
            // into "Bachelor party" and hid misspelt months from the
            // parser's date-typo reading ("Agust"); spoken input arrives
            // spelled, and other-language names (Sevilla) match exactly.
            if trailing, length >= 5, strongKinds == 0, !romanized4 {
                for (_, ids) in index.idsByLength.buckets(from: length - 1) {
                    for id in ids where kinds[Int(id)] & weakKinds != 0 {
                        let word = index.scalars[Int(id)]
                        guard word.first == scalars.first else { continue }
                        for prefix in (length - 1)...(length + 1) where prefix <= word.count {
                            if EditDistance.withinOne(scalars[...], word[..<prefix]) {
                                record(word: id, tier: tierFuzzyPrefix, into: &result, context: context, filter: weak)
                                break
                            }
                        }
                    }
                }
            }
        }
        context.cache[key] = result
        return result
    }

    /// An island stem's exact word hits (済州 of 済州島): T2 in island
    /// values, T3 (similar) in any other, so 宮古島 never strongly finds
    /// the city of 宮古.
    private static func islandStemHits(_ token: String, context: inout Context) -> [Hit] {
        let key = SubTokenKey(text: token, trailing: false, source: 4, termGated: false)
        if let cached = context.cache[key] { return cached }
        var result = Array(repeating: Hit(), count: context.index.documents.count)
        if let id = context.index.wordIDs[token] {
            record(word: id, tier: tierInfix, into: &result, context: context) { !$0.namesIsland }
            record(word: id, tier: tierAlias, into: &result, context: context) { $0.namesIsland }
        }
        context.cache[key] = result
        return result
    }

    /// Exact word hits at T2; `placeOnly` keeps place postings, `japanOnly`
    /// postings of values naming places in Japan.
    private static func aliasHits(
        _ token: String, placeOnly: Bool, japanOnly: Bool = false, context: inout Context
    ) -> [Hit] {
        let key = SubTokenKey(
            text: token, trailing: false, source: placeOnly ? 2 : (japanOnly ? 3 : 1), termGated: false)
        if let cached = context.cache[key] { return cached }
        var result = Array(repeating: Hit(), count: context.index.documents.count)
        if let id = context.index.wordIDs[token] {
            let place = UInt8(TripSearchFieldKind.place.ordinal)
            record(word: id, tier: tierAlias, into: &result, context: context) { posting in
                (!placeOnly || posting.kind == place)
                    && (!japanOnly || posting.namesJapan)
            }
        }
        context.cache[key] = result
        return result
    }

    /// Joined adjacent words: exact or prefix of any word, reported at T2.
    /// An alternate name's compound is a prefix match only while the second
    /// word is being typed.
    private static func joinedHits(_ token: String, trailing: Bool, context: inout Context) -> [Hit] {
        var result = Array(repeating: Hit(), count: context.index.documents.count)
        let scalars = token.unicodeScalars.map(\.value)
        let index = context.index
        let exactID = index.wordIDs[token]
        var position = index.lowerBound(scalars)
        while position < index.sortedIDs.count {
            let id = index.sortedIDs[position]
            guard index.scalars[Int(id)].starts(with: scalars) else { break }
            let admitsAlternate = trailing || id == exactID
            record(word: id, tier: tierAlias, into: &result, context: context) { admitsAlternate || !$0.isAlternate }
            position += 1
        }
        return result
    }

    static func contains(_ haystack: [UInt32], _ needle: [UInt32]) -> Bool {
        let n = needle.count
        guard n > 0, haystack.count >= n else { return n == 0 }
        let first = needle[0]
        var start = 0
        while start + n <= haystack.count {
            if haystack[start] == first {
                var offset = 1
                while offset < n, haystack[start + offset] == needle[offset] { offset += 1 }
                if offset == n { return true }
            }
            start += 1
        }
        return false
    }

    /// ASCII a, e, i, o, u (romanizations are folded lowercase).
    private static func isVowel(_ scalar: UInt32) -> Bool {
        scalar == 97 || scalar == 101 || scalar == 105 || scalar == 111 || scalar == 117
    }
}

/// Bounded optimal string alignment (Damerau with adjacent transpositions)
/// over Unicode scalars, reusing its row buffers across calls.
nonisolated struct EditDistance {
    private var previous2: [Int] = []
    private var previous: [Int] = []
    private var current: [Int] = []

    /// The distance when it is at most `limit`, else nil.
    mutating func within(_ a: ArraySlice<UInt32>, _ b: ArraySlice<UInt32>, limit: Int) -> Int? {
        let m = a.count
        let n = b.count
        if abs(m - n) > limit { return nil }
        if limit <= 1 {
            guard Self.withinOne(a, b) else { return nil }
            let distance = a.elementsEqual(b) ? 0 : 1
            return distance <= limit ? distance : nil
        }
        if m == 0 || n == 0 { return max(m, n) }
        if previous.count < n + 1 {
            previous2 = Array(repeating: 0, count: n + 1)
            previous = Array(repeating: 0, count: n + 1)
            current = Array(repeating: 0, count: n + 1)
        }
        let a0 = a.startIndex
        let b0 = b.startIndex
        let big = limit + 1
        for j in 0...n {
            previous[j] = min(j, big)
            previous2[j] = big
            current[j] = big
        }
        for i in 1...m {
            let low = max(1, i - limit)
            let high = min(n, i + limit)
            current[0] = min(i, big)
            if low > 1 { current[low - 1] = big }
            var rowMin = current[0]
            let ai = a[a0 + i - 1]
            for j in low...high {
                let bj = b[b0 + j - 1]
                let cost = ai == bj ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, ai == b[b0 + j - 2], a[a0 + i - 2] == bj {
                    value = min(value, previous2[j - 2] + 1)
                }
                value = min(value, big)
                current[j] = value
                rowMin = min(rowMin, value)
            }
            if high < n { current[high + 1] = big }
            if rowMin > limit { return nil }
            swap(&previous2, &previous)
            swap(&previous, &current)
        }
        let distance = previous[n]
        return distance <= limit ? distance : nil
    }

    /// At most one insertion, deletion, substitution or adjacent
    /// transposition.
    static func withinOne(_ a: ArraySlice<UInt32>, _ b: ArraySlice<UInt32>) -> Bool {
        let m = a.count
        let n = b.count
        guard abs(m - n) <= 1 else { return false }
        let a0 = a.startIndex
        let b0 = b.startIndex
        var prefix = 0
        while prefix < min(m, n), a[a0 + prefix] == b[b0 + prefix] { prefix += 1 }
        if prefix == min(m, n) { return true }
        if m == n {
            if a[(a0 + prefix + 1)...].elementsEqual(b[(b0 + prefix + 1)...]) { return true }
            return prefix + 1 < m
                && a[a0 + prefix] == b[b0 + prefix + 1]
                && a[a0 + prefix + 1] == b[b0 + prefix]
                && a[(a0 + prefix + 2)...].elementsEqual(b[(b0 + prefix + 2)...])
        }
        if m > n { return a[(a0 + prefix + 1)...].elementsEqual(b[(b0 + prefix)...]) }
        return a[(a0 + prefix)...].elementsEqual(b[(b0 + prefix + 1)...])
    }
}
