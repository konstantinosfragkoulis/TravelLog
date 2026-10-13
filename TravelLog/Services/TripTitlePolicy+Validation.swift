//
//  TripTitlePolicy+Validation.swift
//  TravelLog
//

import Foundation

nonisolated extension TripTitlePolicy {

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
}
