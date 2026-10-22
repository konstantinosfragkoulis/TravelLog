//
//  UnitsTemperaturePreferenceTests.swift
//  TravelLogTests
//
//  Pure unit tests for UnitsFormatter.TemperaturePreference (settings-format
//  subsystem). Covers the RawRepresentable contract the `.current` accessor
//  relies on (KVS string token → enum case, unknown → nil → coalesced .locale
//  in production) and the `useCelsius` decision for each case. The .celsius /
//  .fahrenheit cases are locale-independent and deterministically asserted;
//  the .locale case is pinned through the `prefersFahrenheit(for:)` seam with
//  concrete locales, and the full and compact formatters are pinned to agree.
//  No @Model objects constructed, so NOT @MainActor.
//

import Testing
import Foundation
@testable import TravelLog

struct UnitsTemperaturePreferenceTests {

    // MARK: - KVS token table (the persisted contract)

    @Test("KVS tokens are frozen; unknown token → nil (production coalesces to .locale)")
    func kvsTokensAreFrozen() {
        #expect(UnitsFormatter.TemperaturePreference(rawValue: "celsius") == .celsius)
        #expect(UnitsFormatter.TemperaturePreference(rawValue: "fahrenheit") == .fahrenheit)
        #expect(UnitsFormatter.TemperaturePreference(rawValue: "locale") == .locale)
        #expect(UnitsFormatter.TemperaturePreference(rawValue: "kelvin") == nil)
    }

    // MARK: - useCelsius decision per case

    @Test("explicit .celsius preference forces Celsius regardless of locale")
    func celsiusCaseUsesCelsius() {
        #expect(UnitsFormatter.TemperaturePreference.celsius.useCelsius == true)
    }

    @Test("explicit .fahrenheit preference forces Fahrenheit regardless of locale")
    func fahrenheitCaseDoesNotUseCelsius() {
        #expect(UnitsFormatter.TemperaturePreference.fahrenheit.useCelsius == false)
    }

    // MARK: - Locale temperature default
    // `prefersFahrenheit(for:)` is the injection seam the NOTE above wanted:
    // the locale is a parameter, so no global locale mutation.
    // The load-bearing pin is en_GB → Celsius: the UK's hybrid system uses
    // miles for distance (isImperial == true) but Celsius for weather, so
    // temperature must NOT reuse the distance flag.

    @Test("en_US defaults to Fahrenheit")
    func usLocalePrefersFahrenheit() {
        #expect(UnitsFormatter.prefersFahrenheit(for: Locale(identifier: "en_US")) == true)
    }

    @Test("en_GB defaults to Celsius, not Fahrenheit")
    func ukLocalePrefersCelsius() {
        #expect(UnitsFormatter.prefersFahrenheit(for: Locale(identifier: "en_GB")) == false)
    }

    @Test("de_DE defaults to Celsius")
    func metricLocalePrefersCelsius() {
        #expect(UnitsFormatter.prefersFahrenheit(for: Locale(identifier: "de_DE")) == false)
    }

    @Test("the system Temperature setting (mu) overrides the region default")
    func systemTemperatureOverridesRegion() {
        #expect(UnitsFormatter.prefersFahrenheit(for: Locale(identifier: "de_DE@mu=fahrenhe")) == true)
        #expect(UnitsFormatter.prefersFahrenheit(for: Locale(identifier: "en_US@mu=celsius")) == false)
        #expect(UnitsFormatter.TemperaturePreference.locale.useCelsius(locale: Locale(identifier: "de_DE@mu=fahrenhe")) == false)
        #expect(UnitsFormatter.TemperaturePreference.locale.useCelsius(locale: Locale(identifier: "en_US@mu=celsius")) == true)
    }

    // MARK: - Formatted string keeps the chosen unit
    // formatTemperature converts to the preferred unit first, so the formatter
    // must not convert back to the locale's unit.

    @Test("explicit Celsius in a US locale formats as °C")
    func celsiusInUSLocaleStaysCelsius() {
        let text = UnitsFormatter.formatTemp(
            Measurement(value: 24, unit: UnitTemperature.celsius),
            maxFractionDigits: 0, asProvided: true, locale: Locale(identifier: "en_US"))
        #expect(text.contains("24") && text.contains("°C") && !text.contains("°F"), "\(text)")
    }

    @Test("explicit Fahrenheit in a German locale formats as °F")
    func fahrenheitInGermanLocaleStaysFahrenheit() {
        let text = UnitsFormatter.formatTemp(
            Measurement(value: 24, unit: UnitTemperature.celsius).converted(to: .fahrenheit),
            maxFractionDigits: 0, asProvided: true, locale: Locale(identifier: "de_DE"))
        #expect(text.contains("75") && text.contains("°F") && !text.contains("°C"), "\(text)")
    }

    @Test("locale default honours the system temperature setting")
    func localeDefaultHonoursSystemTemperature() {
        let celsius = Measurement(value: 24, unit: UnitTemperature.celsius)
        let de = UnitsFormatter.formatTemp(
            celsius, maxFractionDigits: 0, asProvided: false,
            locale: Locale(identifier: "de_DE@mu=fahrenhe"))
        #expect(de.contains("75") && de.contains("°F") && !de.contains("°C"), "\(de)")
        let us = UnitsFormatter.formatTemp(
            celsius.converted(to: .fahrenheit), maxFractionDigits: 0, asProvided: false,
            locale: Locale(identifier: "en_US@mu=celsius"))
        #expect(us.contains("24") && us.contains("°C") && !us.contains("°F"), "\(us)")
    }

    // MARK: - Compact and full formatters agree
    // Before the fix the compact chip resolved Locale Default through
    // `measurementSystem == .us` while the full label used Foundation's
    // `.general` resolution, so a US user with the system Temperature set to
    // Celsius saw "75°" chips next to "24°C" labels.

    private static let overrideLocales = [
        "en_US", "en_GB", "de_DE", "de_DE@mu=fahrenhe", "en_US@mu=celsius",
        // `.us` measurement system, so the regional temperature preference is
        // exercised separately from `mu` (whatever Foundation resolves, both
        // formatters must follow it).
        "en_LR",
        "ar_EG", "ar_EG@mu=fahrenhe",
    ]

    @Test("compact Locale Default honours the system Temperature setting")
    func compactLocaleDefaultHonoursSystemTemperature() {
        #expect(UnitsFormatter.formatTemperatureCompact(
            24, preference: .locale, locale: Locale(identifier: "en_US@mu=celsius")) == "24°")
        #expect(UnitsFormatter.formatTemperatureCompact(
            24, preference: .locale, locale: Locale(identifier: "de_DE@mu=fahrenhe")) == "75°")
        #expect(UnitsFormatter.formatTemperatureCompact(
            24, preference: .locale, locale: Locale(identifier: "en_US")) == "75°")
        #expect(UnitsFormatter.formatTemperatureCompact(
            24, preference: .locale, locale: Locale(identifier: "en_GB")) == "24°")
    }

    @Test("explicit preferences ignore the locale in the compact formatter")
    func compactExplicitPreferenceIgnoresLocale() {
        for id in Self.overrideLocales {
            let locale = Locale(identifier: id)
            let celsius = UnitsFormatter.formatTemperatureCompact(24, preference: .celsius, locale: locale)
            let fahrenheit = UnitsFormatter.formatTemperatureCompact(24, preference: .fahrenheit, locale: locale)
            #expect(celsius == "\(24.formatted(.number.grouping(.never).locale(locale)))°", "\(id): \(celsius)")
            #expect(fahrenheit == "\(75.formatted(.number.grouping(.never).locale(locale)))°", "\(id): \(fahrenheit)")
        }
    }

    @Test("compact digits follow the injected locale")
    func compactUsesInjectedLocaleDigits() {
        #expect(UnitsFormatter.formatTemperatureCompact(
            24, preference: .celsius, locale: Locale(identifier: "ar_EG")) == "٢٤°")
        #expect(UnitsFormatter.formatTemperatureCompact(
            24, preference: .locale, locale: Locale(identifier: "ar_EG@mu=fahrenhe")) == "٧٥°")
    }

    @Test("rounding is half away from zero with no negative zero")
    func compactRoundingBoundaries() {
        let en = Locale(identifier: "en_US")
        #expect(UnitsFormatter.formatTemperatureCompact(24.5, preference: .celsius, locale: en) == "25°")
        #expect(UnitsFormatter.formatTemperatureCompact(-2.5, preference: .celsius, locale: en) == "\((-3).formatted(.number.grouping(.never).locale(en)))°")
        #expect(UnitsFormatter.formatTemperatureCompact(-0.4, preference: .celsius, locale: en) == "0°")
        #expect(UnitsFormatter.formatTemperatureCompact(0, preference: .celsius, locale: en) == "0°")
        #expect(UnitsFormatter.formatTemperatureCompact(0, preference: .fahrenheit, locale: en) == "32°")
        #expect(UnitsFormatter.formatTemperature(-0.4, preference: .celsius, locale: en)
                == UnitsFormatter.formatTemperature(0, preference: .celsius, locale: en))
    }

    @Test("Locale Default resolves the same unit as Foundation's general usage")
    func localeDefaultMatchesGeneralUsage() {
        for id in Self.overrideLocales {
            let locale = Locale(identifier: id)
            let general = UnitsFormatter.formatTemp(
                Measurement(value: 24, unit: UnitTemperature.celsius),
                maxFractionDigits: 0, asProvided: false, locale: locale)
            let full = UnitsFormatter.formatTemperature(24, preference: .locale, locale: locale)
            #expect(full == general, "\(id): \(full) vs \(general)")
        }
    }

    @Test("full and compact show the same number under every preference")
    func fullAndCompactAgree() {
        let values: [Double] = [24, 23.7, 24.5, -2.5, -0.4, 0, -17.5, 38.2]
        let preferences: [UnitsFormatter.TemperaturePreference] = [.locale, .celsius, .fahrenheit]
        for id in Self.overrideLocales {
            let locale = Locale(identifier: id)
            for preference in preferences {
                for value in values {
                    let compact = UnitsFormatter.formatTemperatureCompact(value, preference: preference, locale: locale)
                    let full = UnitsFormatter.formatTemperature(value, preference: preference, locale: locale)
                    #expect(compact.hasSuffix("°"), "\(id) \(preference) \(value): \(compact)")
                    // The whole localized number (sign and digits) appears in
                    // the full label, not as part of a longer number.
                    let number = String(compact.dropLast())
                    let range = full.range(of: number)
                    let before = range.flatMap { $0.lowerBound > full.startIndex ? full[full.index(before: $0.lowerBound)] : nil }
                    let after = range.flatMap { $0.upperBound < full.endIndex ? full[$0.upperBound] : nil }
                    #expect(range != nil && !(before?.isNumber ?? false) && !(after?.isNumber ?? false),
                            "\(id) \(preference) \(value): \(compact) vs \(full)")
                    #expect(compact.filter(\.isNumber) == full.filter(\.isNumber),
                            "\(id) \(preference) \(value): \(compact) vs \(full)")
                }
            }
        }
    }
}
