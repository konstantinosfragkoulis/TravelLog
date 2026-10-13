//
//  LocalizedCountryNameTests.swift
//  TravelLogTests
//

import Foundation
import Testing
@testable import TravelLog

struct LocalizedCountryNameTests {
    private let english = Locale(identifier: "en")

    @Test("a known ISO code resolves through the injected locale")
    func knownCodeLocalizes() {
        #expect(localizedCountryName(
            iso: "GR",
            fallback: "Stored Greece",
            locale: english
        ) == "Greece")
    }

    @Test("missing ISO uses the stored fallback")
    func missingCodeUsesFallback() {
        #expect(localizedCountryName(
            iso: nil,
            fallback: "Stored Country",
            locale: english
        ) == "Stored Country")
    }

    @Test("missing ISO and fallback returns nil")
    func missingInputsReturnNil() {
        #expect(localizedCountryName(iso: nil, fallback: nil, locale: english) == nil)
    }

    @Test("explicit Portuguese variants do not collapse to the regional default")
    func portugueseVariantsRemainDistinct() {
        let brazil = AppLanguagePreference.locale(
            for: "pt-BR", regionalLocale: Locale(identifier: "en_US"))
        let portugal = AppLanguagePreference.locale(
            for: "pt-PT", regionalLocale: Locale(identifier: "en_US"))
        #expect(localizedCountryName(iso: "AM", fallback: nil, locale: brazil)
                != localizedCountryName(iso: "AM", fallback: nil, locale: portugal))
    }

    @Test("stats country rows show the app-language name, not the stored English one")
    func statsCountryRowLocalizes() {
        let german = Locale(identifier: "de")
        #expect(StatsView.countryDisplayName(
            CountryStat(code: "GR", name: "Greece", tripCount: 1, isHome: false),
            locale: german) == "Griechenland")
        #expect(StatsView.countryDisplayName(
            CountryStat(code: "IT", name: "IT", tripCount: 1, isHome: false),
            locale: german) == "Italien")
        #expect(StatsView.countryDisplayName(
            CountryStat(code: "ZZZ", name: "Stored", tripCount: 1, isHome: false),
            locale: german) == "Stored")
    }
}
