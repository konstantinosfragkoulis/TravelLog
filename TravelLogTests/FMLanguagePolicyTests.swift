//
//  FMLanguagePolicyTests.swift
//  TravelLogTests
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite(.serialized)
struct FMLanguagePolicyTests {

    private func utc(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: 12
        ))!
    }

    @Test("canonical language tags preserve only Apple's distinguished script or region")
    func canonicalLanguageTags() {
        let matrix = [
            ("en_US", "en"),
            ("el_GR", "el"),
            ("pt_BR", "pt-BR"),
            ("pt_PT", "pt-PT"),
            ("zh_Hans_CN", "zh-Hans"),
            ("zh_Hant_TW", "zh-Hant"),
            ("de_DE", "de"),
        ]

        for (identifier, expected) in matrix {
            #expect(FMLanguagePolicy.canonicalLanguageTag(
                for: Locale(identifier: identifier)
            ) == expected)
        }
    }

    @Test("search follows locale support")
    func searchEligibility() {
        let german = Locale(identifier: "de_DE")
        #expect(FMLanguagePolicy.searchFMAllowed(
            locale: german,
            supportsLocale: { locale in locale.identifier == german.identifier }
        ))
        #expect(!FMLanguagePolicy.searchFMAllowed(
            locale: german,
            supportsLocale: { _ in false }
        ))
    }

    @Test("strict prompt transliteration preserves Greek transliteration")
    func strictGreekTransliteration() {
        #expect("Σύρος".toLatinAsciiStrict == "Syros")
    }

    @Test("strict prompt transliteration drops untransliterable non-ASCII scalars")
    func strictOutputIsASCIIOnly() {
        let strict = "🙂  ☃︎  §".toLatinAsciiStrict
        #expect(strict.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(!strict.contains("🙂"))
        #expect(!strict.contains("☃"))
        #expect(!strict.contains("§"))
        #expect(!strict.contains("  "))
    }

    @Test("strict prompt transliteration spells Latin letters with no decomposition instead of dropping them")
    func strictTransliteratesUndecomposableLatinLetters() {
        let cases: [(String, String)] = [
            ("Tromsø", "Tromso"), ("Bodø", "Bodo"), ("Wrocław", "Wroclaw"), ("Łódź", "Lodz"),
            ("Gießen", "Giessen"), ("Ærøskøbing", "AEroskobing"), ("Đà Nẵng", "Da Nang"),
            ("Kırşehir", "Kirsehir"), ("Øresund", "Oresund"), ("L’Aquila", "L'Aquila"),
            ("Köniz", "Koniz"), ("São Paulo", "Sao Paulo"),
            // Other scripts keep their transliteration.
            ("Αθήνα", "Athena"), ("Москва", "Moskva"), ("北京", "bei jing"),
        ]
        for (native, expected) in cases {
            let strict = native.toLatinAsciiStrict
            #expect(strict == expected, "\(native)")
            #expect(strict.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E }, "\(native)")
            #expect(strict.toLatinAsciiStrict == strict, "\(native)")
        }
    }

    @Test("strict prompt transliteration leaves printable ASCII byte-identical")
    func strictASCIIIdentity() {
        let ascii = "Athens & Cephalonia, GR (2026) - no emoji!"
        #expect(ascii.toLatinAsciiStrict == ascii)
        #expect(Array(ascii.utf8) == Array(ascii.toLatinAsciiStrict.utf8))
    }

    @Test("Delete Calendar Data removes localized derivatives and uses a destination fallback")
    func calendarWipeUsesSafeFallback() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: utc(2025, 8, 19))
        trip.aiGeneratedTitle = "Existing AI Title"
        let stay = Stay(
            startTime: utc(2025, 8, 19),
            endTime: utc(2025, 8, 20),
            centroidLatitude: 37.98,
            centroidLongitude: 23.72,
            h3IndexRes6: "calendar-wipe",
            pingCount: 2,
            distanceFromHomeKm: 100,
            pingIDs: [])
        stay.category = .destination
        stay.locality = "Athens"
        context.insert(trip)
        context.insert(stay)
        stay.trip = trip
        stay.orderInTrip = 0
        context.insert(TripTitleVariant(
            languageTag: "el",
            title: "Υπάρχων τίτλος",
            sourceTitle: "Existing AI Title",
            trip: trip))
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        let result = await classifier.clearThenRegenerateAllTitlesForCalendarWipe(
            gate: PipelineGate(forTesting: ())
        )

        let id = trip.id
        let predicate = #Predicate<Trip> { $0.id == id }
        let after = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>(predicate: predicate)
        ).first)
        #expect(result.cleared)
        #expect(result.generated == 1)
        #expect(after.aiGeneratedTitle == "Athens")
        #expect(try ModelContext(container).fetchCount(
            FetchDescriptor<TripTitleVariant>()) == 0)
    }

    @Test("Wrapped generation creates a row with the deterministic narrative lane")
    func wrappedGenerationCreatesDeterministicRow() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        let earlyStay = Stay(
            startTime: utc(2025, 4, 19),
            endTime: utc(2025, 4, 19).addingTimeInterval(3_600),
            centroidLatitude: 0,
            centroidLongitude: 0,
            h3IndexRes6: "wrapped-policy",
            pingCount: 1,
            distanceFromHomeKm: 0,
            pingIDs: []
        )
        context.insert(earlyStay)

        var trips: [Trip] = []
        let starts = [utc(2025, 5, 20), utc(2025, 6, 19), utc(2025, 7, 20)]
        for (index, name) in ["Athens", "Cephalonia", "Berlin"].enumerated() {
            let start = starts[index]
            let trip = Trip(startDate: start)
            trip.endDate = start.addingTimeInterval(Double(index == 0 ? 1 : 2) * 86_400)
            trip.isComplete = true
            trip.customName = name
            context.insert(trip)
            trips.append(trip)
        }
        try context.save()

        let generator = YearWrappedGenerator(modelContainer: container)
        let generated = await generator.generateIfNeeded(forYear: 2025)

        let year = 2025
        let predicate = #Predicate<YearWrapped> { $0.year == year }
        let wrapped = try #require(try ModelContext(container).fetch(
            FetchDescriptor<YearWrapped>(predicate: predicate)
        ).first)
        let stats = try #require(wrapped.statsData.flatMap(WrappedStats.decoded(from:)))
        let tripLines = YearWrappedGenerator.tripLines(from: trips)
        let expected = YearWrappedGenerator.deterministicNarrativeText(
            stats: stats,
            year: year,
            tripLines: tripLines
        )

        #expect(generated == .created)
        #expect(wrapped.yearNarrativeSourceRaw == SummarySource.deterministic.rawValue)
        #expect(wrapped.yearNarrative == expected)
        #expect(stats.narrativeInputs?.tripDisplayNames == ["Athens", "Cephalonia", "Berlin"])
        #expect(stats.narrativeInputs?.tripStartDates == trips.map(\.startDate))
        #expect(stats.mysteryFact == .shortestTrip(name: "Athens", days: 2))
        #expect(stats.mysteryFactText == "Your shortest trip was 2 days to Athens.")
    }
}
