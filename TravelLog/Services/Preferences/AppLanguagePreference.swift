//
//  AppLanguagePreference.swift
//  TravelLog
//

import Foundation

/// Canonical identity for the app's selected UI language.
///
/// The bundle choice is authoritative: `Locale.current` deliberately combines
/// the per-app language with the user's regional preferences, so its region
/// alone cannot distinguish `pt-BR` from `pt-PT`, and its inferred Chinese
/// script is not as direct as the localization selected by Foundation.
///
/// The main app mirrors this tag into its App Group at launch. The widget
/// extension reads that mirror because its own bundle may follow the system
/// language even when the user selected a different per-app language.
nonisolated enum AppLanguagePreference {

    static let appGroupMirrorKey = "appLanguageTag_v1"

    /// Every localization shipped by both the app and widget catalogs.
    static let supportedTags: Set<String> = [
        "en", "de", "fr", "it", "es", "pt-BR", "pt-PT", "nl", "da",
        "sv", "nb", "tr", "vi", "ja", "ko", "zh-Hans", "zh-Hant", "el",
    ]

    /// The app localization selected by Foundation, normalized to the exact
    /// tag vocabulary used by persisted title variants and cross-process
    /// caches. Unknown/empty bundle states fall back through the existing FM
    /// language canonicalizer, then English.
    static func currentTag(
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        if let preferred = bundle.preferredLocalizations.first,
           let normalized = normalizedSupportedTag(preferred) {
            return normalized
        }

        let localeTag = FMLanguagePolicy.canonicalLanguageTag(for: locale)
        return normalizedSupportedTag(localeTag) ?? "en"
    }

    /// The user's preferred languages (Settings › Language & Region) as
    /// supported app tags, in order and without duplicates; languages the
    /// app does not ship are dropped.
    static func preferredTags(_ languages: [String] = Locale.preferredLanguages) -> [String] {
        var tags: [String] = []
        for language in languages {
            guard let tag = normalizedSupportedTag(language), !tags.contains(tag) else { continue }
            tags.append(tag)
        }
        return tags
    }

    /// A formatting locale for an app-language tag. Base-language choices
    /// retain the user's region (Greek UI + US region becomes `el_US`) so
    /// dates, numbers, and units keep their regional behavior. Portuguese
    /// variants and Chinese scripts are complete choices in their own right
    /// and must not be rewritten using an unrelated regional locale.
    static func locale(
        for tag: String,
        regionalLocale: Locale = .current
    ) -> Locale {
        let fallback = normalizedSupportedTag(
            FMLanguagePolicy.canonicalLanguageTag(for: regionalLocale)
        ) ?? "en"
        let normalized = normalizedSupportedTag(tag) ?? fallback

        if normalized == "pt-BR" || normalized == "pt-PT"
            || normalized == "zh-Hans" || normalized == "zh-Hant" {
            return Locale(identifier: normalized)
        }

        guard let region = regionalLocale.region?.identifier, !region.isEmpty else {
            return Locale(identifier: normalized)
        }
        return Locale(identifier: "\(normalized)_\(region)")
    }

    /// Formatting/localization locale for the app's authoritative bundle
    /// language. Unlike `Locale.current`, this preserves an explicitly chosen
    /// Portuguese variant or Chinese script when the user's region belongs to
    /// another language.
    static func currentLocale(
        bundle: Bundle = .main,
        regionalLocale: Locale = .current
    ) -> Locale {
        locale(
            for: currentTag(bundle: bundle, locale: regionalLocale),
            regionalLocale: regionalLocale)
    }

    /// Persist the current app-language tag into an App-Group defaults suite.
    /// Returns true only when the value changed, so launch can spend a widget
    /// reload precisely when cached timeline strings may be stale.
    @discardableResult
    static func mirrorCurrentToAppGroup(
        defaults: UserDefaults,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> Bool {
        let tag = currentTag(bundle: bundle, locale: locale)
        guard defaults.string(forKey: appGroupMirrorKey) != tag else { return false }
        defaults.set(tag, forKey: appGroupMirrorKey)
        // The consumer is a separate extension process that may start as soon
        // as WidgetCenter receives the launch-triggered reload request.
        defaults.synchronize()
        return true
    }

    /// Read the app's mirrored language from an App-Group suite. Invalid or
    /// pre-feature values are ignored so the widget can fall back to its own
    /// bundle selection instead of constructing an unsupported locale.
    static func mirroredTag(
        appGroupIdentifier: String,
        defaults: UserDefaults? = nil
    ) -> String? {
        let store = defaults ?? UserDefaults(suiteName: appGroupIdentifier)
        guard let raw = store?.string(forKey: appGroupMirrorKey) else { return nil }
        return normalizedSupportedTag(raw)
    }

    /// Resolve a string from one explicit catalog language. Foundation's
    /// locale parameters format interpolations but do not reliably override
    /// the process-selected catalog; loading the exact `.lproj` bundle does.
    /// This is also used by the widget, whose process language can differ
    /// from the app's mirrored per-app language.
    static func localizedString(
        key: String,
        defaultValue: String,
        languageTag rawTag: String,
        bundle: Bundle = .main
    ) -> String {
        guard let tag = normalizedSupportedTag(rawTag),
              let path = bundle.path(forResource: tag, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else {
            return bundle.localizedString(
                forKey: key,
                value: defaultValue,
                table: nil)
        }
        return localizedBundle.localizedString(
            forKey: key,
            value: defaultValue,
            table: nil)
    }

    /// Internal pure seam for tests and old/defaults-value normalization.
    static func normalizedSupportedTag(_ raw: String) -> String? {
        let components = raw
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", omittingEmptySubsequences: true)
            .map(String.init)
        guard let first = components.first else { return nil }
        let language = first.lowercased()

        if language == "pt" {
            let region = components.dropFirst().first {
                $0.caseInsensitiveCompare("BR") == .orderedSame
                    || $0.caseInsensitiveCompare("PT") == .orderedSame
            }
            guard let region else { return nil }
            return region.caseInsensitiveCompare("BR") == .orderedSame ? "pt-BR" : "pt-PT"
        }

        if language == "zh" {
            if components.contains(where: { $0.caseInsensitiveCompare("Hans") == .orderedSame }) {
                return "zh-Hans"
            }
            if components.contains(where: { $0.caseInsensitiveCompare("Hant") == .orderedSame }) {
                return "zh-Hant"
            }
            if components.contains(where: {
                $0.caseInsensitiveCompare("CN") == .orderedSame
                    || $0.caseInsensitiveCompare("SG") == .orderedSame
            }) {
                return "zh-Hans"
            }
            if components.contains(where: {
                $0.caseInsensitiveCompare("TW") == .orderedSame
                    || $0.caseInsensitiveCompare("HK") == .orderedSame
                    || $0.caseInsensitiveCompare("MO") == .orderedSame
            }) {
                return "zh-Hant"
            }
            return nil
        }

        return supportedTags.contains(language) ? language : nil
    }
}
