//
//  TripTitlePolicy+Validation.swift
//  TravelLog
//

import Foundation

nonisolated extension TripTitlePolicy {

    /// Lowercased ASCII letter-runs of a name or title, in order: both sides
    /// go through `toLatinAsciiStrict` so Greek-script display names meet
    /// their Latin candidates ("Saint-Tropez" is ["saint", "tropez"]).
    static func placeWords(_ text: String) -> [String] {
        text.toLatinAsciiStrict
            .split(whereSeparator: { !$0.isLetter })
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Structural connectors + compass words: they decorate a title but can
    /// never *name* a place by themselves, so they need no corroboration.
    /// A bare preposition can't hallucinate a place.
    static let structuralTitleWords: Set<String> = [
        "and", "in", "of", "the", "to",
        "loop", "tour", "trip", "visit",
        "central", "east", "eastern", "north", "northern",
        "south", "southern", "west", "western",
    ]

    /// Island words may decorate a title but cannot satisfy the grounded-stay requirement.
    static let islandTitleWords: Set<String> = [
        "isle", "isles", "island", "islands",
    ]

    /// Geographic-feature and region words with NO country mapping — they
    /// ride along freely next to a grounded word, but can never anchor a
    /// zero-grounded title (no stay field can corroborate "coast" or
    /// "alpine").
    static let unmappedRegionTitleWords: Set<String> = [
        "coast", "lake", "lakes", "mountain", "mountains", "region", "valley",
        "alpine", "alps", "atlantic", "balkan", "caribbean", "mediterranean",
        "pacific",
        "african", "american", "asian", "australian", "european",
    ]

    /// Map adjectival demonyms to lowercase ISO codes; connector eligibility never overrides forbiddenCountryWords.
    static let titleDemonymISOCodes: [String: Set<String>] = [
        // Regional adjectives.
        "adriatic": ["it", "hr", "si", "ba", "me", "al"],
        "aegean": ["gr", "tr"],
        "andalusian": ["es"],
        "andean": ["pe", "bo", "ec", "co", "cl", "ar"],
        "baltic": ["ee", "lv", "lt"],
        "bavarian": ["de"],
        "catalan": ["es"],
        "hawaiian": ["us"],
        "iberian": ["es", "pt"],
        "nordic": ["se", "no", "dk", "fi", "is"],
        "patagonian": ["ar", "cl"],
        "scandinavian": ["se", "no", "dk"],
        "tuscan": ["it"],
        // Demonyms (adjectival forms only), alphabetized.
        "albanian": ["al"], "algerian": ["dz"], "argentine": ["ar"],
        "argentinian": ["ar"], "austrian": ["at"], "belgian": ["be"],
        "bolivian": ["bo"], "bosnian": ["ba"], "brazilian": ["br"],
        "british": ["gb"], "bulgarian": ["bg"], "cambodian": ["kh"],
        "canadian": ["ca"], "chilean": ["cl"], "chinese": ["cn"],
        "colombian": ["co"], "croatian": ["hr"], "cuban": ["cu"],
        "czech": ["cz"], "danish": ["dk"], "dutch": ["nl"],
        "ecuadorian": ["ec"], "egyptian": ["eg"], "emirati": ["ae"],
        "english": ["gb"], "estonian": ["ee"], "ethiopian": ["et"],
        "filipino": ["ph"], "finnish": ["fi"], "french": ["fr"],
        "german": ["de"], "greek": ["gr"], "hungarian": ["hu"],
        "icelandic": ["is"], "indian": ["in"], "indonesian": ["id"],
        "irish": ["ie"], "israeli": ["il"], "italian": ["it"],
        "jamaican": ["jm"], "japanese": ["jp"], "jordanian": ["jo"],
        "kenyan": ["ke"], "kiwi": ["nz"], "korean": ["kr"],
        "laotian": ["la"], "latvian": ["lv"], "lebanese": ["lb"],
        "lithuanian": ["lt"], "luxembourgish": ["lu"], "malaysian": ["my"],
        "maltese": ["mt"], "mexican": ["mx"], "mongolian": ["mn"],
        "moroccan": ["ma"], "nepalese": ["np"], "nepali": ["np"],
        "norwegian": ["no"], "peruvian": ["pe"], "polish": ["pl"],
        "portuguese": ["pt"], "romanian": ["ro"], "russian": ["ru"],
        "scottish": ["gb"], "serbian": ["rs"], "singaporean": ["sg"],
        "slovak": ["sk"], "slovenian": ["si"], "spanish": ["es"],
        "swedish": ["se"], "swiss": ["ch"], "taiwanese": ["tw"],
        "tanzanian": ["tz"], "thai": ["th"], "tunisian": ["tn"],
        "turkish": ["tr"], "ukrainian": ["ua"], "uruguayan": ["uy"],
        "vietnamese": ["vn"], "welsh": ["gb"],
    ]

    /// Lowercase connector vocabulary may decorate titles but never replace grounded stay words; built once.
    static let titleConnectorWords: Set<String> =
        structuralTitleWords
            .union(islandTitleWords)
            .union(unmappedRegionTitleWords)
            .union(titleDemonymISOCodes.keys)

    /// The title policy for a composed title. Returns the FIRST failure, or
    /// nil when the title passes: its form (`formFailure`), that every word
    /// is grounded in the trip's own places, and that a multi-place title
    /// names the place with the most time. `stays` in `Trip.orderedStays` order.
    static func titleValidationFailure(
        _ title: String,
        stays: [StayInput],
        homePlaceNames: Set<String>
    ) -> ValidationFailure? {
        if let failure = formFailure(title) { return failure }
        if let ungrounded = ungroundedTitleFailure(
            title, stays: stays, homePlaceNames: homePlaceNames) { return ungrounded }
        return missingTopPlaceFailure(
            title, stays: stays, homePlaceNames: homePlaceNames)
    }

    /// The form a stored title must have whatever it names: one line of 2
    /// to 60 characters and at most 8 words, with no word that reads as an
    /// error ("error", "unknown"). Nil when it has it.
    static func formFailure(_ title: String) -> ValidationFailure? {
        if title.isEmpty { return .empty }
        if title.count < 2 { return .tooShort }
        if title.count > 60 { return .tooLong }
        let lowered = title.lowercased()
        if lowered.contains("error") { return .containsErrorWord("error") }
        if lowered.contains("unknown") { return .containsErrorWord("unknown") }
        if title.contains("\n") { return .multiLine }
        let wordCount = title.split(separator: " ").count
        if wordCount > 8 { return .tooManyWords(wordCount) }
        return nil
    }

    /// A multi-place title must name a time-dominant place; any tie in minutes qualifies regardless of ranking tiebreaks.
    /// Match whole names contiguously or permitted abbreviations after grounding; skip single-group and transit-fallback trips.
    static func missingTopPlaceFailure(
        _ stripped: String,
        stays: [StayInput],
        homePlaceNames: Set<String>
    ) -> ValidationFailure? {
        let ranked = rankedTitleCandidates(stays: stays, homePlaceNames: homePlaceNames)
        guard !ranked.isTransitFallback, ranked.groups.count > 1,
              let top = ranked.groups.first else { return nil }
        let titleWords = placeWords(stripped)
        let topGroups = ranked.groups.filter { $0.totalMinutes == top.totalMinutes }
        for group in topGroups where titleNamesPlace(titleWords, group.displayName) {
            return nil
        }
        return .missingTopPlace(top.displayName)
    }

    /// True when the title words contain the place's words as one
    /// contiguous run, or one of its permitted abbreviations (NYC and NY
    /// for New York, LA for Los Angeles, exactly as the grounding check
    /// allows them; titles from older builds can carry them). Abbreviations
    /// are checked first: a title that is only "NYC" or "LA" is shorter than
    /// the full name.
    private static func titleNamesPlace(_ titleWords: [String], _ displayName: String) -> Bool {
        let words = placeWords(displayName)
        guard !words.isEmpty else { return true }
        if words == ["new", "york"] && (titleWords.contains("nyc") || titleWords.contains("ny")) { return true }
        if words == ["los", "angeles"] && titleWords.contains("la") { return true }
        guard titleWords.count >= words.count else { return false }
        for start in 0...(titleWords.count - words.count)
        where Array(titleWords[start ..< start + words.count]) == words {
            return true
        }
        return false
    }

    /// The grounding half of title validation, surfacing WHICH word failed
    /// and WHY (`.forbiddenCountryWord` vs `.ungroundedWord`). nil ⇒ every
    /// title word is grounded.
    static func ungroundedTitleFailure(
        _ title: String,
        stays: [StayInput],
        homePlaceNames: Set<String>
    ) -> ValidationFailure? {
        // Only destination stays ground normal titles; transit and other categories cannot supply omitted places.
        // With no destinations, fall back to every stay as `rankedTitleCandidates` does.
        let destinationStays = stays.filter { category(of: $0) == .destination }
        // Exclude home-named destinations from grounding whenever an away destination remains, matching candidate eligibility;
        // trips containing only home-named destinations still ground on them.
        let awayStays = destinationStays.filter { !isHomePlace($0, homePlaceNames: homePlaceNames) }
        let groundingStays: [StayInput]
        if !awayStays.isEmpty {
            groundingStays = awayStays
        } else {
            groundingStays = destinationStays.isEmpty ? stays : destinationStays
        }
        // The words those dropped stays would have grounded, so a title
        // that uses one gets its own rejection reason. Words the surviving
        // stays also carry stay grounded (a "York" trip from a New York
        // home) — subtracted below once `allowed` is complete.
        var homeWords = Set<String>()
        if !awayStays.isEmpty {
            for stay in destinationStays where isHomePlace(stay, homePlaceNames: homePlaceNames) {
                for source in [stay.metroName, stay.islandName, stay.locality] {
                    guard let name = source else { continue }
                    for word in name.toLatinAsciiStrict.split(whereSeparator: { !$0.isLetter }) {
                        homeWords.insert(word.lowercased())
                    }
                }
            }
        }
        var allowed = Set<String>()
        for stay in groundingStays {
            for source in [stay.metroName, stay.islandName, stay.locality, stay.administrativeArea] {
                guard let name = source else { continue }
                for word in name.toLatinAsciiStrict.split(whereSeparator: { !$0.isLetter }) {
                    allowed.insert(word.lowercased())
                }
            }
            // Country code too — covers titles like "US Tour" if anyone
            // ever uses ISO codes. Unlikely but cheap.
            if let iso = stay.isoCountryCode, !iso.isEmpty {
                allowed.insert(iso.lowercased())
            }
        }
        // Country tokens must be subtracted and hard-rejected even if locality supplied them;
        // use the same forbiddenCountryWords helper as candidate construction.
        let forbiddenCountryWords = Self.forbiddenCountryWords(
            countryInputs: stays.map { ($0.country, $0.isoCountryCode) })
        allowed.subtract(forbiddenCountryWords)
        // Allow abbreviations only when the corresponding city words are grounded.
        if allowed.contains("new") && allowed.contains("york") {
            allowed.formUnion(["nyc", "ny"])
        }
        if allowed.contains("los") && allowed.contains("angeles") {
            allowed.insert("la")
        }
        homeWords.subtract(allowed)
        // A grounding place whose own name contains country words ("Mexico
        // City", "San Salvador") is consumed whole before the forbidden check;
        // a bare country name or a leftover country word still rejects.
        let titleName = titlePlaceNamer(stays: stays, homePlaceNames: homePlaceNames)
        let groundedNames: [[String]] = groundingStays.compactMap { stay in
            guard let name = titleName(stay), name != "Unknown",
                  !isBareCountryName(name, forbidden: forbiddenCountryWords) else { return nil }
            let words = placeWords(name)
            return words.contains(where: forbiddenCountryWords.contains) ? words : nil
        }.sorted { $0.count > $1.count }

        // Tokenize the title exactly like the vocabulary above, so a title in
        // stored spelling ("Tromsø") meets its place's words ("tromso").
        let titleWords = title.toLatinAsciiStrict
            .split(whereSeparator: { !$0.isLetter && $0 != "&" })
            .map { String($0).lowercased() }
            .filter { !$0.isEmpty && $0 != "&" }

        var consumedGroundedName = false
        var index = 0
        while index < titleWords.count {
            if let name = groundedNames.first(where: {
                index + $0.count <= titleWords.count
                    && Array(titleWords[index..<index + $0.count]) == $0
            }) {
                consumedGroundedName = true
                index += name.count
                continue
            }
            let word = titleWords[index]
            index += 1
            // Hard reject country-name words even if a connector or
            // allowed-by-stay match would have let them through. This runs
            // BEFORE the connector check, so a demonym that merely resembles
            // a per-trip forbidden country token can never smuggle the bare
            // country in — e.g. "Greek" (connector) passes while "Greece"
            // (forbidden) rejects.
            if forbiddenCountryWords.contains(word) { return .forbiddenCountryWord(word) }
            if allowed.contains(word) { continue }
            if titleConnectorWords.contains(word) { continue }
            if homeWords.contains(word) { return .homePlaceWord(word) }
            return .ungroundedWord(word)
        }
        // Require at least one grounded stay word; connector and region words may decorate but cannot anchor a title.
        let grounded = consumedGroundedName || titleWords.contains { allowed.contains($0) }
        return grounded ? nil : .noGroundedWord(title)
    }
}
