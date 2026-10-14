//
//  FMLanguagePolicy.swift
//  TravelLog
//

import Foundation

/// Language gates for Foundation Models features that emit or interpret
/// natural language. Classification is deliberately outside this policy.
nonisolated enum FMLanguagePolicy {

    /// Creative trip naming has one stable, backward-compatible source
    /// language. Localized variants are derived from this canonical title.
    static let canonicalTitleLocale = Locale(identifier: "en_US")

    /// Apple's current language list distinguishes Portuguese by region and
    /// Chinese by script. Other supported languages use their base language.
    private static let regionDistinguishedLanguages: Set<String> = ["pt"]
    private static let scriptDistinguishedLanguages: Set<String> = ["zh"]

    static func canonicalLanguageTag(for locale: Locale) -> String {
        guard let language = locale.language.languageCode?.identifier.lowercased() else {
            return ""
        }

        if scriptDistinguishedLanguages.contains(language),
           let script = locale.language.script?.identifier,
           !script.isEmpty {
            let canonicalScript = script.prefix(1).uppercased() + script.dropFirst().lowercased()
            return "\(language)-\(canonicalScript)"
        }

        if regionDistinguishedLanguages.contains(language),
           let region = locale.region?.identifier,
           !region.isEmpty {
            return "\(language)-\(region.uppercased())"
        }

        return language
    }

    /// Whether the canonical English title lane can run on this device.
    /// This deliberately does not depend on the app's selected UI language.
    static func canonicalTitlesEligible(
        fmAvailable: Bool,
        supportsLocale: (Locale) -> Bool
    ) -> Bool {
        fmAvailable && supportsLocale(canonicalTitleLocale)
    }

    static func searchFMAllowed(
        locale: Locale = .current,
        supportsLocale: (Locale) -> Bool
    ) -> Bool {
        supportsLocale(locale)
    }
}
