//
//  TripSearchHaystackTests.swift
//  TravelLogTests
//
//  The model bridge of the trips search: `TripSearchDocument.make(from:)`
//  (title aliases, place/region/country/transit fields per stay category,
//  ISO -> English and app-language country names, Gregorian date words) and
//  the engine and resolver over the documents it builds (AND semantics,
//  order preserving). Builds Trip/Stay @Model graphs via TestSupport, so the
//  suite is @MainActor: the app target is MainActor-by-default, which makes
//  @Model types MainActor-isolated.
//
//  Month words come from the explicit app language passed in, so assertions
//  on "January" / "Jan" are locale-stable.
//

import Testing
import Foundation
import SwiftData
import os
@testable import TravelLog

@MainActor
struct TripSearchHaystackTests {

    // MARK: - Date helper (Calendar.current, noon to avoid TZ/DST skew)

    private func day(_ year: Int, _ month: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: d, hour: 12))!
    }

    // MARK: - Fixture builders

    private func makeTrip(in ctx: ModelContext, start: Date) -> Trip {
        let trip = Trip(startDate: start)
        ctx.insert(trip)
        return trip
    }

    @discardableResult
    private func addStay(
        to trip: Trip,
        in ctx: ModelContext,
        order: Int,
        category: StayCategory? = .destination,
        locality: String? = nil,
        country: String? = nil,
        admin: String? = nil,
        iso: String? = nil,
        metro: String? = nil,
        island: String? = nil,
        subLocality: String? = nil
    ) -> Stay {
        let stay = Stay(startTime: trip.startDate, endTime: trip.startDate,
                        centroidLatitude: 0, centroidLongitude: 0,
                        h3IndexRes6: "8a000", pingCount: 1, distanceFromHomeKm: 0,
                        pingIDs: [])
        ctx.insert(stay)
        // nil keeps the stored default (""), which reads as unclassified.
        if let category { stay.category = category }
        stay.locality = locality
        stay.country = country
        stay.administrativeArea = admin
        stay.isoCountryCode = iso
        stay.metroName = metro
        stay.islandName = island
        stay.subLocality = subLocality
        stay.trip = trip
        stay.orderInTrip = order
        return stay
    }

    private func addDestination(
        to trip: Trip,
        in ctx: ModelContext,
        order: Int,
        locality: String? = nil,
        country: String? = nil,
        admin: String? = nil,
        iso: String? = nil
    ) {
        addStay(to: trip, in: ctx, order: order, locality: locality,
                country: country, admin: admin, iso: iso)
    }

    private func values(_ document: TripSearchDocument, _ kind: TripSearchFieldKind) -> [String] {
        document.fields.first { $0.kind == kind }?.displayValues ?? []
    }

    // MARK: - Document fields

    @Test("title words are lowercased and diacritic-folded; display values keep the original")
    func titleWordsAreLowercasedAndDiacriticFolded() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 3, 2))
        trip.customName = "Αθήνα Café"

        let document = TripSearchDocument.make(from: trip, languageTag: "en")
        #expect(values(document, .title) == ["Αθήνα Café"])
        #expect(document.wholeWords.contains("cafe"))
        #expect(!document.wholeWords.contains("Café"))
        #expect(!document.wholeWords.contains("café"))
        #expect(document.words.allSatisfy { $0.text == $0.text.lowercased() })
    }

    @Test("country field expands ISO codes to English country names AND keeps the codes")
    func countryFieldExpandsISOCodesToEnglishCountryNames() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 3, 2))
        trip.countryCodes = "GR,IT"

        let document = TripSearchDocument.make(from: trip, languageTag: "en")
        let country = values(document, .country)
        #expect(country.contains("Greece"))
        #expect(country.contains("Italy"))
        #expect(country.contains("GR"))
        #expect(country.contains("IT"))
        #expect(document.countryCodes == ["GR", "IT"])
        for word in ["greece", "italy", "gr", "it"] {
            #expect(document.wholeWords.contains(word))
        }
    }

    @Test("destination stays feed locality to place, admin area to region, ISO and stored country to country")
    func destinationStayFeedsPlaceRegionAndCountry() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 3, 2))
        addDestination(to: trip, in: ctx, order: 0,
                       locality: "Gérakas", country: "Greece",
                       admin: "Attica", iso: "GR")

        let document = TripSearchDocument.make(from: trip, languageTag: "en")
        #expect(values(document, .place).contains("Gérakas"))
        #expect(values(document, .region) == ["Attica"])
        #expect(values(document, .country).contains("Greece"))
        #expect(document.countryCodes == ["GR"])
        #expect(document.wholeWords.isSuperset(of: ["gerakas", "attica", "greece"]))
    }

    @Test("date field has year and month forms for the start date")
    func dateFieldHasYearAndMonthForms() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 1, 15))

        let date = values(TripSearchDocument.make(from: trip, languageTag: "en"), .date)
        #expect(date.contains("2024"))
        #expect(date.contains("January"))
        #expect(date.contains("Jan"))
    }

    @Test("date field adds end-date words when complete; an ongoing trip contributes only its start")
    func dateFieldIncludesEndDateFormsWhenComplete() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let complete = makeTrip(in: ctx, start: day(2023, 12, 28))
        complete.endDate = day(2024, 1, 3)
        let completeDates = values(TripSearchDocument.make(from: complete, languageTag: "en"), .date)
        #expect(completeDates.contains("2023"))
        #expect(completeDates.contains("2024"))

        let ongoing = makeTrip(in: ctx, start: day(2025, 5, 1))
        let ongoingDates = values(TripSearchDocument.make(from: ongoing, languageTag: "en"), .date)
        #expect(ongoingDates.contains("2025"))
        #expect(!ongoingDates.contains("2024"))
    }

    @Test("ja, ko and zh date fields keep the plain ASCII year", arguments: ["ja", "ko", "zh-Hans"])
    func dateFieldKeepsASCIIYear(languageTag: String) throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 6, 1))

        let document = TripSearchDocument.make(from: trip, languageTag: languageTag)
        #expect(values(document, .date).contains("2024"))
        #expect(document.wholeWords.contains("2024"))
    }

    @Test("repeated stay codes produce each country alias once", arguments: ["en", "el"])
    func repeatedCountryCodesDeduplicateAliases(languageTag: String) throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = makeTrip(in: context, start: Date(timeIntervalSinceReferenceDate: 0))
        trip.customName = "Journey"
        let codes = ["GR", "gr", "IT", "GR", "gr"]
        for (index, code) in codes.enumerated() {
            addStay(to: trip, in: context, order: index, locality: "Stop\(index)", iso: code)
        }

        let document = TripSearchDocument.make(from: trip, languageTag: languageTag)
        #expect(values(document, .title) == ["Journey"])
        #expect(values(document, .place) == (0..<codes.count).map { "Stop\($0)" })
        #expect(values(document, .country)
            == TripSearch.countryAliases(for: ["GR", "IT"], languageTag: languageTag))
        #expect(document.countryCodes == ["GR", "IT"])
        #expect(Set(document.words).count == document.words.count)
    }

    @Test("field kinds follow the stay category; home, routine and the Unknown sentinel are not indexed")
    func fieldKindsFollowStayCategory() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 3, 2))
        trip.customName = "Crete Loop"
        trip.destinationSummary = "Crete, Unknown"
        addStay(to: trip, in: ctx, order: 0, category: .home,
                locality: "Athens", country: "Greece", admin: "Attica", iso: "GR")
        addStay(to: trip, in: ctx, order: 1, category: .transit,
                locality: "Frankfurt", country: "Germany", admin: "Hesse", iso: "DE", metro: "Rhine-Main")
        addStay(to: trip, in: ctx, order: 2, category: .destination,
                locality: "Limín Khersonísou", country: "Greece", admin: "Crete Region", iso: "GR",
                island: "Crete", subLocality: "Splantzia")
        addStay(to: trip, in: ctx, order: 3, category: nil,
                locality: "Pitsídia", admin: "Heraklion Regional Unit", iso: "gr")
        addStay(to: trip, in: ctx, order: 4, category: .routine,
                locality: "Gérakas", iso: "GR")
        addStay(to: trip, in: ctx, order: 5, category: .destination,
                locality: "Metropolis", iso: "FR", metro: "Alès")

        let document = TripSearchDocument.make(from: trip, languageTag: "en")
        let place = values(document, .place)
        let region = values(document, .region)
        let country = values(document, .country)
        let transit = values(document, .transit)

        #expect(place == ["Crete", "Limín Khersonísou", "Splantzia", "Pitsídia", "Metropolis", "Alès"])
        #expect(region == ["Crete Region", "Heraklion Regional Unit"])
        #expect(transit == ["Frankfurt", "Rhine-Main", "Hesse"])
        #expect(country.contains("Greece"))
        #expect(country.contains("France"))
        #expect(!country.contains("Germany"))
        #expect(!country.contains("DE"))
        #expect(document.countryCodes == ["GR", "FR"])
        for absent in ["athens", "attica", "gerakas", "unknown", "germany"] {
            #expect(!document.wholeWords.contains(absent))
        }
    }

    @Test("a custom name hides generated title aliases")
    func customNameHidesGeneratedTitles() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 3, 2))
        let revision = UUID()
        trip.aiGeneratedTitle = "Cycladic Summer"
        trip.titleSourceRevision = revision
        ctx.insert(TripTitleVariant(
            languageTag: "de",
            title: "Kykladischer Sommer",
            sourceTitle: "Cycladic Summer",
            sourceRevision: revision,
            trip: trip))
        trip.customName = "Cephalonia With Friends"

        let document = TripSearchDocument.make(from: trip, languageTag: "de")
        #expect(values(document, .title) == ["Cephalonia With Friends"])
    }

    @Test("stay-zone duration, including an ongoing trip, survives make(from:) and drives the resolver")
    func durationBoundsWithStays() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func date(_ month: Int, _ d: Int) -> Date {
            utc.date(from: DateComponents(year: 2026, month: month, day: d))!
        }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        func winterPark(days: Int?) -> Trip {
            let trip = makeTrip(in: ctx, start: date(7, 1))
            trip.destinationSummary = "Winter Park"
            if let days {
                trip.endDate = utc.date(byAdding: .day, value: days - 1, to: trip.startDate)
                trip.isComplete = true
            }
            let stay = addStay(to: trip, in: ctx, order: 0, locality: "Winter Park")
            stay.startTime = trip.startDate
            stay.endTime = trip.endDate ?? trip.startDate
            stay.timeZoneIdentifier = "UTC"
            return trip
        }
        let long = winterPark(days: 10)
        let ongoing = winterPark(days: nil)
        let short = winterPark(days: 3)
        try ctx.save()
        let trips = [long, ongoing, short]
        let documents = trips.map { TripSearchDocument.make(from: $0, languageTag: "en", calendar: utc) }
        #expect(documents.map(\.durationDays) == [10, nil, 3])
        #expect(documents.map(\.startYear) == [2026, 2026, 2026])
        #expect(documents.map(\.startMonth) == [7, 7, 7])
        #expect(documents.map(\.isComplete) == [true, false, true])

        let index = TripSearchIndex(documents: documents)
        let cases: [(String, [Trip])] = [
            ("", trips), ("longer than a week", [long]),
            ("up to 4 days", [short]), ("3-day trips", [short]),
        ]
        for (duration, expected) in cases {
            let query = duration.isEmpty ? "Winter Park" : "Winter Park \(duration)"
            let searched = TripQueryParser.searchTrips(
                index: index, query: query, allowsTrailingPartial: false,
                now: date(7, 14), calendar: utc, languageTag: "en")
            #expect(searched.map { trips[$0.documentIndex].id } == expected.map(\.id), "\(query)")
        }
    }

    @Test("make(from:) in a detached task with its own context equals the main-context build")
    func offMainBuildEqualsMainBuild() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 3, 2))
        trip.endDate = day(2024, 3, 10)
        trip.isComplete = true
        trip.countryCodes = "GR"
        trip.destinationSummary = "Limín Khersonísou, Rethymno"
        let revision = UUID()
        trip.aiGeneratedTitle = "Cretan Summer"
        trip.titleSourceRevision = revision
        ctx.insert(TripTitleVariant(
            languageTag: "el",
            title: "Κρητικό Καλοκαίρι",
            sourceTitle: "Cretan Summer",
            sourceRevision: revision,
            trip: trip))
        addStay(to: trip, in: ctx, order: 1, locality: "Rethymno", admin: "Crete", iso: "GR")
        addStay(to: trip, in: ctx, order: 0, locality: "Limín Khersonísou", country: "Greece", admin: "Crete", iso: "GR")
        addStay(to: trip, in: ctx, order: 2, category: .transit, locality: "Agios Dimitrios", iso: "GR")
        let other = makeTrip(in: ctx, start: day(2022, 12, 1))
        other.customName = "Lisbon"
        try ctx.save()

        let main = [trip, other].map { TripSearchDocument.make(from: $0, languageTag: "el") }
            .sorted { $0.tripID.uuidString < $1.tripID.uuidString }
        let offMain = await Task.detached {
            let context = ModelContext(container)
            let trips = (try? context.fetch(FetchDescriptor<Trip>())) ?? []
            let normalizer = TripSearchNormalizer()
            return trips.map { TripSearchDocument.make(from: $0, languageTag: "el", normalizer: normalizer) }
                .sorted { $0.tripID.uuidString < $1.tripID.uuidString }
        }.value
        #expect(offMain == main)
        #expect(main.count == 2)
    }

    // MARK: - Matching over built documents

    private func searchCheckingMemo(
        _ trips: [Trip],
        query: String,
        languageTag: String = "en"
    ) -> [Trip] {
        func run() -> [TripSearchMatch] {
            let index = TripSearchIndex(documents: trips.map {
                TripSearchDocument.make(from: $0, languageTag: languageTag)
            })
            return TripSearch.match(terms: TripSearch.terms(query, languageTag: languageTag), in: index)
        }
        TripSearch.normalizedFormsCache.withLock { $0.removeAll() }
        let cold = run()
        let warm = run()
        #expect(cold == warm)
        return warm.map { trips[$0.documentIndex] }
    }

    @Test("an empty or whitespace query yields no terms; the engine then returns every document in order")
    func emptyQueryYieldsNoTerms() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let a = makeTrip(in: ctx, start: day(2024, 1, 1)); a.customName = "Trip A"
        let b = makeTrip(in: ctx, start: day(2024, 2, 1)); b.customName = "Trip B"
        let trips = [a, b]

        #expect(TripSearch.terms("", languageTag: "en").isEmpty)
        #expect(TripSearch.terms("   ", languageTag: "en").isEmpty)
        #expect(searchCheckingMemo(trips, query: "").map(\.id) == trips.map(\.id))
        #expect(searchCheckingMemo(trips, query: "   ").map(\.id) == trips.map(\.id))
    }

    @Test("matching preserves the input order of matching trips")
    func matchPreservesInputOrder() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let a = makeTrip(in: ctx, start: day(2024, 1, 1)); a.customName = "Trip Alpha"
        let b = makeTrip(in: ctx, start: day(2024, 2, 1)); b.customName = "Trip Beta"
        let c = makeTrip(in: ctx, start: day(2024, 3, 1)); c.customName = "Trip Gamma"
        let trips = [a, b, c]

        let result = searchCheckingMemo(trips, query: "trip")
        #expect(result.map(\.id) == [a, b, c].map(\.id))
    }

    @Test("all terms must match (AND); the resolver's fallback reports the rest as partial")
    func allTermsRequiredAndSemantics() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 3, 2))
        addDestination(to: trip, in: ctx, order: 0,
                       locality: "Athens", country: "Greece", admin: nil, iso: "GR")
        let trips = [trip]

        #expect(searchCheckingMemo(trips, query: "athens greece").count == 1)
        #expect(searchCheckingMemo(trips, query: "athens tokyo").isEmpty)

        let index = TripSearchIndex(documents: [TripSearchDocument.make(from: trip, languageTag: "en")])
        let resolved = TripQueryParser.searchTrips(
            index: index, query: "athens tokyo", allowsTrailingPartial: false, languageTag: "en")
        #expect(resolved.map(\.documentIndex) == [0])
        #expect(resolved.map(\.strength) == [.partial])
    }

    @Test("matches by ISO -> English country-name expansion alone")
    func matchesByExpandedCountryName() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 3, 2))
        trip.countryCodes = "GR"

        #expect(searchCheckingMemo([trip], query: "greece").count == 1)
    }

    @Test("Greek country endonym and Latin transliteration match alongside English")
    func matchesLocalizedCountryAndTransliteration() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 3, 2))
        trip.countryCodes = "GR"

        #expect(searchCheckingMemo([trip], query: "Ελλάδα", languageTag: "el").count == 1)
        #expect(searchCheckingMemo([trip], query: "Ellada", languageTag: "el").count == 1)
        #expect(searchCheckingMemo([trip], query: "Greece", languageTag: "el").count == 1)
    }

    @Test("valid titles remain aliases across a language switch")
    func keepsCanonicalAndLocalizedTitleAliases() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 3, 2))
        let revision = UUID()
        trip.aiGeneratedTitle = "Cycladic Summer"
        trip.titleSourceRevision = revision
        let german = TripTitleVariant(
            languageTag: "de",
            title: "Kykladischer Sommer",
            sourceTitle: "Cycladic Summer",
            sourceRevision: revision,
            trip: trip)
        let greek = TripTitleVariant(
            languageTag: "el",
            title: "Κυκλαδίτικο Καλοκαίρι",
            sourceTitle: "Cycladic Summer",
            sourceRevision: revision,
            trip: trip)
        let stale = TripTitleVariant(
            languageTag: "fr",
            title: "Titre Obsolète",
            sourceTitle: "Cycladic Summer",
            sourceRevision: UUID(),
            trip: trip)
        ctx.insert(german)
        ctx.insert(greek)
        ctx.insert(stale)

        #expect(searchCheckingMemo([trip], query: "Cycladic", languageTag: "de").count == 1)
        #expect(searchCheckingMemo([trip], query: "Kykladischer", languageTag: "el").count == 1)
        #expect(searchCheckingMemo([trip], query: "Κυκλαδίτικο", languageTag: "de").count == 1)
        #expect(searchCheckingMemo([trip], query: "Obsolete", languageTag: "de").isEmpty)
    }

    @Test("typo tolerance works end-to-end (londno -> London) for 4+ char terms")
    func typoToleranceEndToEnd() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 3, 2))
        addDestination(to: trip, in: ctx, order: 0,
                       locality: "London", country: "United Kingdom", admin: nil, iso: "GB")

        #expect(searchCheckingMemo([trip], query: "londno").count == 1)
    }

    @Test("no match returns empty (the AI-fallback trigger condition)")
    func noMatchReturnsEmpty() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 3, 2))
        trip.customName = "Athens"

        #expect(searchCheckingMemo([trip], query: "reykjavik").isEmpty)
    }

    @Test("matching is case-insensitive (athens / ATHENS both match)")
    func matchingIsCaseInsensitive() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 3, 2))
        trip.customName = "Athens"

        #expect(searchCheckingMemo([trip], query: "athens").count == 1)
        #expect(searchCheckingMemo([trip], query: "ATHENS").count == 1)
    }
}
