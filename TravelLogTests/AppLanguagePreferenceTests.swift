//
//  AppLanguagePreferenceTests.swift
//  TravelLogTests
//

import Foundation
import Testing
@testable import TravelLog

@Suite(.serialized)
struct AppLanguagePreferenceTests {

    @Test("supported tags exactly match the shipped localization matrix")
    func supportedTagMatrix() {
        #expect(AppLanguagePreference.supportedTags == [
            "en", "de", "fr", "it", "es", "pt-BR", "pt-PT", "nl", "da",
            "sv", "nb", "tr", "vi", "ja", "ko", "zh-Hans", "zh-Hant", "el",
        ])
    }

    @Test("bundle and defaults spellings normalize to canonical app tags")
    func tagNormalization() {
        #expect(AppLanguagePreference.normalizedSupportedTag("de-DE") == "de")
        #expect(AppLanguagePreference.normalizedSupportedTag("pt_BR") == "pt-BR")
        #expect(AppLanguagePreference.normalizedSupportedTag("pt-PT") == "pt-PT")
        #expect(AppLanguagePreference.normalizedSupportedTag("zh_CN") == "zh-Hans")
        #expect(AppLanguagePreference.normalizedSupportedTag("zh-Hant-HK") == "zh-Hant")
        #expect(AppLanguagePreference.normalizedSupportedTag("Base") == nil)
        #expect(AppLanguagePreference.normalizedSupportedTag("") == nil)
    }

    @Test("base languages preserve region while pt and zh variants stay faithful")
    func formattingLocales() {
        let greekUS = AppLanguagePreference.locale(
            for: "el", regionalLocale: Locale(identifier: "en_US")
        )
        #expect(greekUS.language.languageCode?.identifier == "el")
        #expect(greekUS.region?.identifier == "US")

        let portugueseBrazil = AppLanguagePreference.locale(
            for: "pt-BR", regionalLocale: Locale(identifier: "en_GB")
        )
        #expect(portugueseBrazil.language.languageCode?.identifier == "pt")
        #expect(portugueseBrazil.region?.identifier == "BR")

        let traditionalChinese = AppLanguagePreference.locale(
            for: "zh-Hant", regionalLocale: Locale(identifier: "en_US")
        )
        #expect(traditionalChinese.language.script?.identifier == "Hant")
    }

    @Test("explicit app locale preserves the exact Portuguese choice")
    func exactAppLocale() {
        let portuguese = AppLanguagePreference.locale(
            for: "pt-PT",
            regionalLocale: Locale(identifier: "en_US"))
        #expect(portuguese.language.languageCode?.identifier == "pt")
        #expect(portuguese.region?.identifier == "PT")
    }

    @Test("Portuguese variants keep distinct dates and country labels")
    func portugueseVariantsStayDistinct() {
        let brazil = AppLanguagePreference.locale(
            for: "pt-BR",
            regionalLocale: Locale(identifier: "en_US"))
        let portugal = AppLanguagePreference.locale(
            for: "pt-PT",
            regionalLocale: Locale(identifier: "en_US"))
        let date = Date(timeIntervalSinceReferenceDate: 805_550_400)
        let styleBR = Date.FormatStyle(
            date: .abbreviated, time: .omitted, locale: brazil)
        let stylePT = Date.FormatStyle(
            date: .abbreviated, time: .omitted, locale: portugal)

        #expect(date.formatted(styleBR) != date.formatted(stylePT))
        #expect(brazil.localizedString(forRegionCode: "AM")
                != portugal.localizedString(forRegionCode: "AM"))
    }

    @Test("explicit catalog lookup is independent of the test process language")
    func explicitCatalogLookup() {
        let english = AppLanguagePreference.localizedString(
            key: "home.place.default-label",
            defaultValue: "Home",
            languageTag: "en")
        let greek = AppLanguagePreference.localizedString(
            key: "home.place.default-label",
            defaultValue: "Home",
            languageTag: "el")

        #expect(english == "Home")
        #expect(!greek.isEmpty)
        #expect(greek != english)
    }

    @Test("App Group mirror reports changes and rejects invalid values")
    func appGroupMirror() throws {
        let suiteName = "app-language-preference-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(AppLanguagePreference.mirrorCurrentToAppGroup(
            defaults: defaults,
            locale: Locale(identifier: "el_US")
        ))
        let mirrored = AppLanguagePreference.mirroredTag(
            appGroupIdentifier: suiteName,
            defaults: defaults
        )
        #expect(mirrored == AppLanguagePreference.currentTag(
            locale: Locale(identifier: "el_US")
        ))

        #expect(AppLanguagePreference.mirrorCurrentToAppGroup(
            defaults: defaults,
            locale: Locale(identifier: "el_US")
        ) == false)

        defaults.set("unsupported", forKey: AppLanguagePreference.appGroupMirrorKey)
        #expect(AppLanguagePreference.mirroredTag(
            appGroupIdentifier: suiteName,
            defaults: defaults
        ) == nil)
    }
}
