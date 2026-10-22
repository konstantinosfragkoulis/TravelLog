//
//  LocalizedTripTitleResult.swift
//  TravelLog
//

import FoundationModels

/// Guided output for localizing an existing canonical trip title. Creative
/// trip naming remains in `TripTitleSchema`; this lane only preserves that
/// title's meaning in another supported language.
@Generable
struct LocalizedTripTitleResult {
    @Guide(description: "Briefly check which words carry meaning, which are proper nouns, and what language the localized title uses.")
    var reasoning: String

    @Guide(description: "The localized trip title only. Preserve proper nouns and do not add or remove destinations. One line, maximum 60 characters.")
    var title: String

    @Guide(description: "The BCP-47 language tag of the localized title, such as de, el, pt-BR, or zh-Hant.")
    var outputLanguageTag: String

    @Guide(description: "True only when the localized title preserves the complete meaning of the source title.")
    var preservesMeaning: Bool

    @Guide(description: "True only when every destination and proper noun from the source is preserved and none was added.")
    var preservesDestinationsAndProperNouns: Bool
}

/// Independent backtranslation: code extracts whole known place names from
/// the complete English rendering instead of trusting a self-graded Bool.
@Generable
struct LocalizedTripTitleEnglishResult {
    @Guide(description: "The entire supplied title faithfully rendered in English, using conventional English place names. Preserve every place and every other meaningful word; do not add explanations or omit descriptors.")
    var englishTitle: String
}
