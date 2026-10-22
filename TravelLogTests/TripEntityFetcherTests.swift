//
//  TripEntityFetcherTests.swift
//  TravelLogTests
//
//  `TripEntityFetcher` opens its own ModelContext over the container, so
//  every test saves the seeding context before calling the fetcher
//  (unsaved inserts are invisible to a fresh context).
//

import CoreSpotlight
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct TripEntityFetcherTests {

    @Test func spotlightRefreshCollisionQueuesExactlyOneFollowUp() {
        var state = SpotlightIndexer.RefreshPassState()
        let firstClaim = state.claim()
        let secondClaim = state.claim()
        let thirdClaim = state.claim()
        #expect(firstClaim)
        #expect(!secondClaim)
        #expect(!thirdClaim)
        #expect(state.isInFlight)
        #expect(state.hasPendingRerun)
        let shouldRerun = state.finishPass()
        #expect(shouldRerun)
        #expect(state.isInFlight)
        #expect(!state.hasPendingRerun)
        let shouldStop = state.finishPass()
        #expect(!shouldStop)
        #expect(!state.isInFlight)
    }

    // MARK: - Seeding helpers

    private func makeStay(
        in context: ModelContext,
        start: Date,
        hours: Double = 24,
        category: StayCategory = .destination,
        locality: String? = nil,
        metroName: String? = nil,
        islandName: String? = nil,
        isoCountryCode: String? = nil,
        orderInTrip: Int? = nil
    ) -> Stay {
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(hours * 3600),
            centroidLatitude: 48.8828,
            centroidLongitude: 2.2524,
            h3IndexRes6: "861fb462fffffff",
            pingCount: 5,
            distanceFromHomeKm: 2000,
            pingIDs: []
        )
        stay.categoryRaw = category.rawValue
        stay.locality = locality
        stay.metroName = metroName
        stay.islandName = islandName
        stay.isoCountryCode = isoCountryCode
        stay.orderInTrip = orderInTrip
        context.insert(stay)
        return stay
    }

    @discardableResult
    private func makeTrip(
        in context: ModelContext,
        start: Date,
        end: Date? = nil,
        customName: String? = nil,
        countryCodes: String = "",
        destinationSummary: String = ""
    ) -> Trip {
        let trip = Trip(startDate: start)
        trip.endDate = end
        trip.isComplete = end != nil
        trip.customName = customName
        trip.countryCodes = countryCodes
        trip.destinationSummary = destinationSummary
        context.insert(trip)
        return trip
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - Field mapping

    @Test func mapsTripFieldsIntoEntity() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        let trip = makeTrip(
            in: context,
            start: date(2025, 1, 21),
            end: date(2025, 1, 25),
            customName: "Athens Hop",
            countryCodes: "GR,IT",
            destinationSummary: "Athens, Palermo"
        )
        let athens = makeStay(
            in: context, start: date(2025, 1, 21),
            metroName: "Athens", isoCountryCode: "GR", orderInTrip: 0
        )
        athens.trip = trip
        let palermo = makeStay(
            in: context, start: date(2025, 1, 23),
            locality: "Palermo", isoCountryCode: "IT", orderInTrip: 1
        )
        palermo.trip = trip
        try context.save()

        let entities = try TripEntityFetcher.allEntities(container: container)
        let entity = try #require(entities.first)

        #expect(entities.count == 1)
        #expect(entity.tripID == trip.id)
        #expect(entity.title == "Athens Hop")
        #expect(entity.destinationSummary == "Athens, Palermo")
        #expect(entity.isOngoing == false)
        #expect(entity.countryCodes == ["GR", "IT"])
        #expect(entity.countryNames == ["Greece", "Italy"])
        #expect(entity.localities == ["Athens", "Palermo"])
        #expect(entity.flags.contains("🇬🇷"))
        #expect(entity.flags.contains("🇮🇹"))
    }

    @Test func ongoingTripIsFlaggedAndDated() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        makeTrip(in: context, start: date(2026, 2, 11), customName: "Somewhere")
        try context.save()

        let entity = try #require(try TripEntityFetcher.allEntities(container: container).first)
        #expect(entity.isOngoing)
        #expect(entity.endDate == nil)
        #expect(entity.dateRangeText(locale: Locale(identifier: "en_US"))
            .contains("ongoing"))
    }

    @Test func localitiesUseMetroIslandLocalityFallbackAndSkipTransit() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = makeTrip(in: context, start: date(2025, 3, 14), end: date(2025, 3, 22))

        let island = makeStay(
            in: context, start: date(2025, 3, 14),
            locality: "Ermoúpolis", islandName: "Syros", orderInTrip: 0
        )
        island.trip = trip
        let localityOnly = makeStay(
            in: context, start: date(2025, 3, 17),
            locality: "Kárystos", orderInTrip: 1
        )
        localityOnly.trip = trip
        let layover = makeStay(
            in: context, start: date(2025, 3, 21), hours: 3,
            category: .transit, locality: "Frankfurt", isoCountryCode: "DE", orderInTrip: 2
        )
        layover.trip = trip
        try context.save()

        let entity = try #require(try TripEntityFetcher.allEntities(container: container).first)
        // Island name wins over locality; transit stays contribute nothing.
        #expect(entity.localities == ["Syros", "Kárystos"])
    }

    // MARK: - ID resolution

    @Test func entitiesForIdsPreservesOrderAndDropsUnknown() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let first = makeTrip(in: context, start: date(2024, 1, 1), end: date(2024, 1, 5), customName: "First")
        let second = makeTrip(in: context, start: date(2025, 3, 1), end: date(2025, 3, 5), customName: "Second")
        try context.save()

        let resolved = try TripEntityFetcher.entities(
            for: [second.id, UUID(), first.id],
            container: container
        )
        #expect(resolved.map(\.title) == ["Second", "First"])
    }

    @Test func recentEntitiesHonorsLimitNewestFirst() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        makeTrip(in: context, start: date(2023, 5, 1), end: date(2023, 5, 3), customName: "Old")
        makeTrip(in: context, start: date(2025, 5, 1), end: date(2025, 5, 3), customName: "Newer")
        makeTrip(in: context, start: date(2026, 5, 1), customName: "Newest")
        try context.save()

        let recent = try TripEntityFetcher.recentEntities(limit: 2, container: container)
        #expect(recent.map(\.title) == ["Newest", "Newer"])
    }

    /// Two devices importing the same backup converge same-id twins. Each
    /// trip is one entity, and twins never take a suggestion slot from
    /// another trip.
    @Test func sameIDTwinsCollapseToOneEntity() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        makeTrip(in: context, start: date(2023, 5, 1), end: date(2023, 5, 3), customName: "Old")
        let newer = makeTrip(in: context, start: date(2025, 5, 1), end: date(2025, 5, 3), customName: "Newer")
        let newest = makeTrip(in: context, start: date(2026, 5, 1), customName: "Newest")
        for original in [newest, newest, newer] {
            let twin = makeTrip(in: context, start: original.startDate, end: original.endDate,
                                customName: original.customName)
            twin.id = original.id
        }
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Trip>()) == 6)

        let all = try TripEntityFetcher.allEntities(container: container)
        #expect(all.map(\.title) == ["Newest", "Newer", "Old"])
        for limit in 1...4 {
            let recent = try TripEntityFetcher.recentEntities(limit: limit, container: container)
            #expect(recent.map(\.title) == Array(["Newest", "Newer", "Old"].prefix(limit)))
        }
    }

    // MARK: - Spotlight attributes

    @Test func attributeSetCarriesSearchVocabulary() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = makeTrip(
            in: context,
            start: date(2025, 6, 10),
            end: date(2025, 6, 14),
            customName: "Paris Weekend",
            countryCodes: "FR",
            destinationSummary: "Paris"
        )
        let stay = makeStay(
            in: context, start: date(2025, 6, 10),
            metroName: "Paris", isoCountryCode: "FR", orderInTrip: 0
        )
        stay.trip = trip
        try context.save()

        let entity = try #require(try TripEntityFetcher.allEntities(container: container).first)
        let attributes = entity.attributeSet
        #expect(attributes.title == "Paris Weekend")
        let keywords = attributes.keywords ?? []
        #expect(keywords.contains("Paris"))
        #expect(keywords.contains("France"))
        #expect(keywords.contains("FR"))
        #expect(attributes.startDate == entity.startDate)
        #expect(attributes.endDate == entity.endDate)
        #expect(attributes.contentDescription?.contains("Paris") == true)
        #expect(keywords.contains("2025"))
        #expect(keywords.contains("June"))
    }

    @Test func spotlightKeywordsCarryStartAndEndDateWords() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = makeTrip(
            in: context,
            start: date(2024, 12, 28),
            end: date(2025, 1, 3),
            destinationSummary: "Vienna"
        )
        trip.aiGeneratedTitle = "Viennese New Year"
        try context.save()

        let entity = TripEntityFetcher.entity(from: trip, languageTag: "el")
        let locale = AppLanguagePreference.locale(
            for: "el",
            regionalLocale: Locale(identifier: "en_US"))
        let keywords = entity.attributeSet(locale: locale).keywords ?? []

        for word in ["2024", "2025", "December", "January", "Dec", "Jan"] {
            #expect(keywords.contains(word), "\(word)")
        }
        let greek = TripSearchDocument.dateWords(start: entity.startDate, end: entity.endDate, languageTag: "el")
        #expect(Set(greek).isSubset(of: Set(keywords)))
    }

    @Test func spotlightKeepsValidTitleAliasesAndLocalizedCountryNames() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = makeTrip(
            in: context,
            start: date(2025, 1, 21),
            end: date(2025, 1, 25),
            countryCodes: "GR",
            destinationSummary: "Cephalonia")
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
        context.insert(german)
        context.insert(greek)
        context.insert(stale)
        try context.save()

        let entity = TripEntityFetcher.entity(from: trip, languageTag: "el")
        let locale = AppLanguagePreference.locale(
            for: "el",
            regionalLocale: Locale(identifier: "en_US"))
        let attributes = entity.attributeSet(locale: locale)

        #expect(entity.title == "Κυκλαδίτικο Καλοκαίρι")
        #expect(entity.titleAliases.contains("Cycladic Summer"))
        #expect(entity.titleAliases.contains("Kykladischer Sommer"))
        #expect(!entity.titleAliases.contains("Titre Obsolète"))
        #expect(attributes.alternateNames?.contains("Cycladic Summer") == true)
        #expect(attributes.keywords?.contains("Ελλάδα") == true)
        #expect(attributes.keywords?.contains("ellada") == true)
        #expect(attributes.keywords?.contains("Greece") == true)
        #expect(attributes.keywords?.contains("Kykladischer Sommer") == true)
        #expect(attributes.keywords?.contains("kykladitiko kalokairi") == true)
        #expect(attributes.keywords?.contains("Titre Obsolète") == false)
    }

    /// Parity guard for the prefetched `allEntities` fetch: relationship
    /// content read through a fresh context must match per-row faulting.
    @Test func allEntitiesKeepsVariantAliasesAndStayOrder() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = makeTrip(
            in: context,
            start: date(2025, 1, 21),
            end: date(2025, 1, 25),
            countryCodes: "GR",
            destinationSummary: "Cephalonia")
        let revision = UUID()
        trip.aiGeneratedTitle = "Cycladic Summer"
        trip.titleSourceRevision = revision
        context.insert(TripTitleVariant(
            languageTag: "de",
            title: "Kykladischer Sommer",
            sourceTitle: "Cycladic Summer",
            sourceRevision: revision,
            trip: trip))
        context.insert(TripTitleVariant(
            languageTag: "fr",
            title: "Titre Obsolète",
            sourceTitle: "Cycladic Summer",
            sourceRevision: UUID(),
            trip: trip))
        let samos = makeStay(
            in: context, start: date(2025, 1, 24),
            locality: "Néon Karlovásion", isoCountryCode: "GR", orderInTrip: 2)
        samos.trip = trip
        let cephalonia = makeStay(
            in: context, start: date(2025, 1, 21),
            locality: "Lixoúri", isoCountryCode: "GR", orderInTrip: 0)
        cephalonia.trip = trip
        let ferry = makeStay(
            in: context, start: date(2025, 1, 22), hours: 3,
            category: .transit, locality: "Agios Dimitrios", isoCountryCode: "GR", orderInTrip: 1)
        ferry.trip = trip
        let lefkada = makeStay(
            in: context, start: date(2025, 1, 23),
            locality: "Lefkáda", isoCountryCode: "GR", orderInTrip: 1)
        lefkada.trip = trip
        try context.save()

        let entities = try TripEntityFetcher.allEntities(container: container)
        let entity = try #require(entities.first)

        #expect(entities.count == 1)
        #expect(entity.titleAliases.contains("Cycladic Summer"))
        #expect(entity.titleAliases.contains("Kykladischer Sommer"))
        #expect(!entity.titleAliases.contains("Titre Obsolète"))
        #expect(entity.localities == ["Lixoúri", "Lefkáda", "Néon Karlovásion"])
    }

    @Test func spotlightDigestCoversNoncurrentValidTitleAliases() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = makeTrip(
            in: context,
            start: date(2025, 1, 21),
            end: date(2025, 1, 25),
            countryCodes: "GR",
            destinationSummary: "Cephalonia")
        let revision = UUID()
        trip.aiGeneratedTitle = "Cycladic Summer"
        trip.titleSourceRevision = revision
        let german = TripTitleVariant(
            languageTag: "de",
            title: "Kykladischer Sommer",
            sourceTitle: "Cycladic Summer",
            sourceRevision: revision,
            trip: trip)
        context.insert(german)
        try context.save()

        let locale = AppLanguagePreference.locale(
            for: "el",
            regionalLocale: Locale(identifier: "en_US"))
        let before = TripEntityFetcher.entity(from: trip, languageTag: "el")
        let beforeDigest = SpotlightIndexer.contentDigest(
            for: [before], languageTag: "el", locale: locale)

        german.title = "Sommer auf den Kykladen"
        german.updatedAt = german.updatedAt.addingTimeInterval(1)
        try context.save()
        let after = TripEntityFetcher.entity(from: trip, languageTag: "el")

        #expect(after.title == before.title)
        #expect(SpotlightIndexer.contentDigest(
            for: [after], languageTag: "el", locale: locale) != beforeDigest)
    }

    @Test func storedNarrativeNeverReachesSpotlight() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = makeTrip(
            in: context,
            start: date(2025, 1, 21),
            end: date(2025, 1, 25),
            customName: "Paris Weekend",
            countryCodes: "FR",
            destinationSummary: "Paris"
        )
        trip.aiGeneratedSummary = "A stored narrative must not leak."
        trip.summarySourceRaw = SummarySource.foundationModels.rawValue
        try context.save()

        let entity = try #require(
            try TripEntityFetcher.allEntities(container: container).first
        )
        let description = try #require(entity.attributeSet.contentDescription)
        #expect(!description.contains("must not leak"))
        #expect(description.hasPrefix("Paris · "))
        let digest = SpotlightIndexer.contentDigest(for: [entity])

        trip.aiGeneratedSummary = "A different narrative is still omitted."
        trip.summarySourceRaw = SummarySource.deterministic.rawValue
        try context.save()
        let changed = try #require(
            try TripEntityFetcher.allEntities(container: container).first
        )
        #expect(SpotlightIndexer.contentDigest(for: [changed]) == digest)
    }

    @Test func spotlightDigestIsAppLanguageAndFinalDescriptionKeyed() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        makeTrip(
            in: context,
            start: date(2026, 2, 11),
            customName: "Athens Hop",
            destinationSummary: "Athens"
        )
        try context.save()

        let entity = try #require(try TripEntityFetcher.allEntities(container: container).first)
        let englishLocale = AppLanguagePreference.locale(
            for: "en", regionalLocale: Locale(identifier: "en_US")
        )
        let greekLocale = AppLanguagePreference.locale(
            for: "el", regionalLocale: Locale(identifier: "en_US")
        )

        let english = SpotlightIndexer.contentDigest(
            for: [entity], languageTag: "en", locale: englishLocale
        )
        let greek = SpotlightIndexer.contentDigest(
            for: [entity], languageTag: "el", locale: greekLocale
        )

        #expect(english != greek)
        #expect(entity.attributeSet(locale: englishLocale).contentDescription
            == entity.spotlightContentDescription(locale: englishLocale))
        #expect(entity.attributeSet(locale: greekLocale).contentDescription
            == entity.spotlightContentDescription(locale: greekLocale))
    }
}
