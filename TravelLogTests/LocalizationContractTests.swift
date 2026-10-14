//
//  LocalizationContractTests.swift
//  TravelLogTests
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

struct LocalizationContractTests {

    private static let supportedLocaleIdentifiers = [
        "en", "de", "fr", "it", "es", "pt-BR", "pt-PT", "nl", "da",
        "sv", "nb", "tr", "vi", "ja", "ko", "zh-Hans", "zh-Hant", "el"
    ]

    @Test("split plural keys resolve and formatted Int interpolation stays ungrouped in English")
    func englishSplitKeysAndUngroupedIntegerFormatting() {
        // The preceding catalog-plural probe selected one/other correctly but
        // rendered 40_075 as "40,075". Split whole-sentence keys plus the
        // ungrouped FormatStyle preserve the legacy interpolation bytes.
        let locale = Locale(identifier: "en")

        let one = localizedRendererString(
            localized: "localization.proof.split.one",
            defaultValue: "\(1, format: .number.grouping(.never)) proof items",
            bundle: nil,
            locale: locale)
        let three = localizedRendererString(
            localized: "localization.proof.split.other",
            defaultValue: "\(3, format: .number.grouping(.never)) proof items",
            bundle: nil,
            locale: locale)
        let fiveDigits = 40_075
        let fiveDigitPlural = localizedRendererString(
            localized: "localization.proof.split.other",
            defaultValue: "\(fiveDigits, format: .number.grouping(.never)) proof items",
            bundle: nil,
            locale: locale)

        #expect(one == "1 proof item")
        #expect(three == "3 proof items")
        #expect(fiveDigitPlural == "\(fiveDigits) proof items")
    }

    @Test("welcome-home body renders the English day count")
    func welcomeHomeDaySplit() {
        let locale = Locale(identifier: "en")
        let threeDays = 3

        let other = localizedRendererString(
            localized: "notification.welcome-home.body.other",
            defaultValue: "You were away for \(threeDays, format: .number.grouping(.never)) days. Welcome back!",
            bundle: nil,
            locale: locale)

        #expect(other == "You were away for 3 days. Welcome back!")
    }

    @MainActor
    @Test("photo-import persisted tokens localize and legacy values stay verbatim")
    func photoImportPersistedErrorTokens() {
        let locale = Locale(identifier: "en")
        let expected = [
            "importError.backgroundTaskStart": "Could not start background task.",
            "importError.backgroundTaskResume": "Could not resume background task.",
            "importError.abandoned": "Import abandoned for more than 7 days; auto-cancelled on launch.",
            "importError.permissionRevoked": "Photo access was revoked. Re-grant in iOS Settings → Privacy → Photos → TravelLog, then resume.",
            "importError.lowPowerMode": "Paused: Low Power Mode is enabled. Disable it (Settings → Battery → Low Power Mode) or plug in your iPhone, then resume.",
            "importError.thermal": "Paused: device is in a critical thermal state. Try again when it has cooled.",
            "importError.batchSaveFailed": "Could not save an imported photo batch.",
            "importError.batchReadFailed": "Could not read saved import data. Try again.",
            "importError.libraryChanged": "The photo library changed during import. Resume to try again.",
            "importError.checkpointSaveFailed": "Could not save import progress.",
            "importError.finalizationSaveFailed": "Could not save the imported photos as stays. Resume to try again."
        ]

        for (token, message) in expected {
            #expect(photoImportLastErrorText(token, locale: locale) == message)
        }

        let legacy = "disk full on an older build"
        #expect(photoImportLastErrorText(legacy, locale: locale) == legacy)
        #expect(photoImportLastErrorText("importError.future", locale: locale) == "importError.future")
    }

    @MainActor
    @Test("onboarding persists the empty home-label sentinel and display falls back")
    func onboardingDefaultHomeLabel() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let home = Home(
            label: OnboardingView.defaultHomeLabel,
            latitude: 37.9838,
            longitude: 23.7275
        )
        context.insert(home)
        try context.save()

        let stored = try #require(context.fetch(FetchDescriptor<Home>()).first)
        #expect(stored.label.isEmpty)
        #expect(stored.displayLabel(locale: Locale(identifier: "en")) == "Home")

        let legacy = Home(label: "Home", latitude: 0, longitude: 0)
        #expect(legacy.displayLabel(locale: Locale(identifier: "el")) == "Home")
    }

    @Test("three deterministic fixtures per renderer stay fully resolved in every supported locale")
    func rendererSmokeMatrix() {
        let narratives = narrativeFixtures()
        let mysteryFacts: [MysteryFact] = [
            .returnedCity(name: "Athens", times: 3),
            .airportDays(count: 1),
            .shortestTrip(name: "Milan", days: 2)
        ]

        for identifier in Self.supportedLocaleIdentifiers {
            let locale = Locale(identifier: identifier)
            for (inputs, stats) in narratives {
                expectResolved(YearWrappedGenerator.deterministicNarrative(
                    from: inputs,
                    stats: stats,
                    locale: locale,
                    bundle: .main
                ))
            }
            for fact in mysteryFacts {
                expectResolved(fact.render(locale: locale, bundle: .main))
            }
        }
    }

    @Test("English Wrapped narrative golden")
    func englishWrappedNarrativeGolden() {
        let fixture = narrativeFixtures()[1]
        let rendered = YearWrappedGenerator.deterministicNarrative(
            from: fixture.0,
            stats: fixture.1,
            locale: Locale(identifier: "en")
        )
        #expect(rendered == "In 2025, you visited 3 countries and 7 cities across 4 trips. The year ran from Vienna to Tokyo. Your longest trip, Athens & Cephalonia, lasted 9 days. You made it as far as Tokyo, 9500 km from home. You covered 5200 km in total. You set foot in Japan and Vietnam for the first time. You spent 21 days abroad and 344 at home.")
    }

    @Test("English mystery-fact golden")
    func englishMysteryFactGolden() {
        let rendered = MysteryFact.returnedCity(name: "Athens", times: 3)
            .render(locale: Locale(identifier: "en"))
        #expect(rendered == "You returned to Athens 3 times this year.")
    }

    @Test("German, Greek, and Japanese Wrapped narrative goldens")
    func localizedWrappedNarrativeGoldens() {
        let fixture = narrativeFixtures()[1]
        #expect(YearWrappedGenerator.deterministicNarrative(
            from: fixture.0, stats: fixture.1, locale: Locale(identifier: "de"), bundle: .main
        ) == "Im Jahr 2025 besuchten Sie 3 Länder und 7 Städte auf 4 Reisen. Das Jahr reichte von Vienna bis Tokyo. Ihre längste Reise, Athens & Cephalonia, dauerte 9 Tage. Sie kamen bis nach Tokyo, 9500 km von zu Hause entfernt. Sie legten insgesamt 5200 km zurück. Sie betraten Japan und Vietnam zum ersten Mal. Sie verbrachten 21 Tage im Ausland und 344 zu Hause.")
        #expect(YearWrappedGenerator.deterministicNarrative(
            from: fixture.0, stats: fixture.1, locale: Locale(identifier: "el"), bundle: .main
        ) == "Το 2025 επισκέφθηκες 3 χώρες και 7 πόλεις σε 4 ταξίδια. Η χρονιά κύλησε από Vienna έως Tokyo. Το μεγαλύτερο ταξίδι σου, Athens & Cephalonia, διήρκεσε 9 ημέρες. Ο πιο μακρινός προορισμός σου ήταν: Tokyo, 9500 χλμ. από την κατοικία σου. Διένυσες συνολικά 5200 χλμ. Χώρες που επισκέφθηκες για πρώτη φορά: Ιαπωνία και Βιετνάμ. Πέρασες 21 ημέρες στο εξωτερικό και 344 στην κατοικία σου.")
        #expect(YearWrappedGenerator.deterministicNarrative(
            from: fixture.0, stats: fixture.1, locale: Locale(identifier: "ja"), bundle: .main
        ) == "2025年は3か国、7都市を4件の旅行で訪れました。 一年はViennaからTokyoまで続きました。 最長の旅行「Athens & Cephalonia」は9日間でした。 自宅から9500 km離れたTokyoまで足を延ばしました。 合計5200 kmを移動しました。 初めて日本、ベトナムを訪れました。 海外で21日、自宅で344日過ごしました。")
    }

    @Test("German, Greek, and Japanese mystery-fact goldens")
    func localizedMysteryFactGoldens() {
        let fixture = MysteryFact.returnedCity(name: "Athens", times: 3)
        #expect(fixture.render(locale: Locale(identifier: "de"), bundle: .main)
                == "Sie kehrten dieses Jahr 3 Mal nach Athens zurück.")
        #expect(fixture.render(locale: Locale(identifier: "el"), bundle: .main)
                == "Επέστρεψες στην πόλη «Athens» 3 φορές φέτος.")
        #expect(fixture.render(locale: Locale(identifier: "ja"), bundle: .main)
                == "今年はAthensを3回再訪しました。")
    }

    @Test("localized percentage rendering uses comma decimals")
    func localizedPercentageCommaDecimal() {
        #expect(CountryCatalog.percentText(
            0.042,
            locale: Locale(identifier: "de")
        ) == "4,2%")
    }

    @Test("representative semantic keys resolve from the host app catalog")
    func semanticKeyResolutionSpotCheck() {
        let locale = Locale(identifier: "en")
        let resolved = [
            ("notification.country-welcome.body", String(localized: "notification.country-welcome.body", locale: locale)),
            ("notification.welcome-home.title", String(localized: "notification.welcome-home.title", locale: locale)),
            ("wrapped.mystery.shortest-trip.other", String(localized: "wrapped.mystery.shortest-trip.other", locale: locale)),
            ("wrapped.notification.ready.body", String(localized: "wrapped.notification.ready.body", locale: locale))
        ]

        for (key, value) in resolved {
            #expect(!value.isEmpty)
            #expect(value != key)
        }
    }

    @Test("LocalizedStringResource resolves representative host-catalog keys in German, Greek, and Japanese")
    func localizedStringResourceHostCatalogResolution() {
        let resources: [LocalizedStringResource] = [
            LocalizedStringResource(
                "notification.welcome-home.title",
                defaultValue: "Welcome Home!",
                bundle: .atURL(Bundle.main.bundleURL)
            ),
            LocalizedStringResource(
                "wrapped.notification.ready.body",
                defaultValue: "See your year of travel: countries, cities, distances, and more.",
                bundle: .atURL(Bundle.main.bundleURL)
            ),
            LocalizedStringResource(
                "settings.apple-intelligence.status.downloading",
                defaultValue: "Downloading…",
                bundle: .atURL(Bundle.main.bundleURL)
            )
        ]
        let english = resources.map { original in
            var resource = original
            resource.locale = Locale(identifier: "en")
            return String(localized: resource)
        }

        for identifier in ["de", "el", "ja"] {
            for (index, original) in resources.enumerated() {
                var resource = original
                resource.locale = Locale(identifier: identifier)
                let localized = String(localized: resource)
                #expect(!localized.isEmpty)
                #expect(localized != resource.key)
                #expect(localized != english[index])
            }
        }
    }

    private func expectResolved(_ value: String) {
        #expect(!value.isEmpty)
        #expect(!value.contains("%"))
        #expect(!value.contains("{"))
        #expect(!value.contains("}"))
    }

    private func narrativeFixtures() -> [(NarrativeInputs, WrappedStats)] {
        var sparse = WrappedStats()
        sparse.countriesVisited = 1
        sparse.tripsCompleted = 1

        var rich = WrappedStats()
        rich.countriesVisited = 3
        rich.citiesVisited = 7
        rich.tripsCompleted = 4
        rich.longestTripName = "Athens & Cephalonia"
        rich.longestTripDays = 9
        rich.farthestPlaceName = "Tokyo"
        rich.farthestDistanceKm = 9_500
        rich.totalGreatCircleKm = 5_200
        rich.newCountryCodes = ["JP", "VN"]
        rich.daysAbroad = 21
        rich.daysAtHome = 344

        var manyCountries = WrappedStats()
        manyCountries.countriesVisited = 5
        manyCountries.citiesVisited = 1
        manyCountries.tripsCompleted = 2
        manyCountries.newCountryCodes = ["JP", "VN", "TH", "KH"]
        manyCountries.daysAbroad = 1
        manyCountries.daysAtHome = 364

        return [
            (
                NarrativeInputs(
                    year: 2024,
                    tripDisplayNames: ["Syros"],
                    tripStartDates: [Date(timeIntervalSinceReferenceDate: -21_168_000)],
                    longestTripName: nil,
                    longestTripDays: nil,
                    farthestPlaceName: nil,
                    farthestDistanceKm: nil,
                    firstTimeCountryISOCodes: []
                ),
                sparse
            ),
            (
                NarrativeInputs(
                    year: 2025,
                    tripDisplayNames: ["Vienna", "Athens & Cephalonia", "Tokyo"],
                    tripStartDates: [0.0, 1.0, 2.0].map { Date(timeIntervalSinceReferenceDate: -21_168_000 + $0) },
                    longestTripName: rich.longestTripName,
                    longestTripDays: rich.longestTripDays,
                    farthestPlaceName: rich.farthestPlaceName,
                    farthestDistanceKm: rich.farthestDistanceKm,
                    firstTimeCountryISOCodes: rich.newCountryCodes
                ),
                rich
            ),
            (
                NarrativeInputs(
                    year: 2026,
                    tripDisplayNames: ["Athens", "Lisbon"],
                    tripStartDates: [0.0, 1.0].map { Date(timeIntervalSinceReferenceDate: -21_168_000 + $0) },
                    longestTripName: nil,
                    longestTripDays: nil,
                    farthestPlaceName: nil,
                    farthestDistanceKm: nil,
                    firstTimeCountryISOCodes: manyCountries.newCountryCodes
                ),
                manyCountries
            )
        ]
    }
}
