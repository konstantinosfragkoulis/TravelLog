//
//  TripsListSearchPresentationTests.swift
//  TravelLogTests
//
//  Pure seams behind the Trips list search presentation: grouping by match
//  strength (search, filters, sort, then grouping), the
//  match caption, the hidden-by-filters count, the trailing-partial flag,
//  "Did you mean" gating, spell-checker language choice, the Upcoming
//  journey filter, the result count, the no-results card's quiet period
//  and the wipe revocation of settled slices. The view
//  itself is never instantiated.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct TripsListSearchPresentationTests {

    private typealias Row = (item: String, strength: TripSearchStrength, isComplete: Bool, isPinned: Bool)

    // MARK: - Grouping

    @Test func strongPinnedGoesToFavoritesAndSimilarPinnedStaysSimilar() {
        let groups = TripsListView.groupSearchResults([
            (item: "strong-pinned", strength: .strong, isComplete: true, isPinned: true),
            (item: "similar-pinned", strength: .similar, isComplete: true, isPinned: true),
            (item: "partial-pinned", strength: .partial, isComplete: false, isPinned: true),
        ] as [Row])
        #expect(groups.pinned == ["strong-pinned"])
        #expect(groups.similar == ["similar-pinned"])
        #expect(groups.partial == ["partial-pinned"])
        #expect(groups.active.isEmpty)
        #expect(groups.completed.isEmpty)
    }

    @Test func strongRowsSplitByCompletionAndEveryGroupKeepsSortOrder() {
        let sorted: [Row] = [
            (item: "p1", strength: .partial, isComplete: true, isPinned: false),
            (item: "s1", strength: .similar, isComplete: false, isPinned: false),
            (item: "c1", strength: .strong, isComplete: true, isPinned: false),
            (item: "a1", strength: .strong, isComplete: false, isPinned: false),
            (item: "s2", strength: .similar, isComplete: true, isPinned: false),
            (item: "c2", strength: .strong, isComplete: true, isPinned: false),
            (item: "p2", strength: .partial, isComplete: false, isPinned: false),
            (item: "a2", strength: .strong, isComplete: false, isPinned: false),
        ]
        let groups = TripsListView.groupSearchResults(sorted)
        #expect(groups.active == ["a1", "a2"])
        #expect(groups.completed == ["c1", "c2"])
        // Similar and partial ignore completion and keep the input order.
        #expect(groups.similar == ["s1", "s2"])
        #expect(groups.partial == ["p1", "p2"])
        #expect(groups.pinned.isEmpty)
    }

    @Test func withoutAQueryEveryRowGroupsAsToday() {
        // No query: every trip is strong, so grouping is the familiar Favorites / Current / Past split.
        let groups = TripsListView.groupSearchResults([
            (item: "pinned", strength: .strong, isComplete: false, isPinned: true),
            (item: "ongoing", strength: .strong, isComplete: false, isPinned: false),
            (item: "done", strength: .strong, isComplete: true, isPinned: false),
        ] as [Row])
        #expect(groups.pinned == ["pinned"])
        #expect(groups.active == ["ongoing"])
        #expect(groups.completed == ["done"])
        #expect(groups.similar.isEmpty && groups.partial.isEmpty)
    }

    @Test func filteringDeletedDropsDeletedRowsFromEveryGroup() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let kept = Trip(startDate: Date(timeIntervalSince1970: 1_700_000_000))
        let deleted = Trip(startDate: Date(timeIntervalSince1970: 1_710_000_000))
        context.insert(kept)
        context.insert(deleted)
        try context.save()
        context.delete(deleted)
        #expect(deleted.isDeleted)

        var slices = TripsListView.TripSlices()
        slices.all = [kept, deleted]
        slices.pinned = [deleted]
        slices.active = [deleted]
        slices.completed = [kept, deleted]
        slices.similar = [deleted, kept]
        slices.partial = [deleted]
        let live = slices.filteringDeleted()
        #expect(live.all.map(\.id) == [kept.id])
        #expect(live.pinned.isEmpty)
        #expect(live.active.isEmpty)
        #expect(live.completed.map(\.id) == [kept.id])
        #expect(live.similar.map(\.id) == [kept.id])
        #expect(live.partial.isEmpty)
    }

    // MARK: - Match caption

    @Test func captionNamesPlaceAndRegionEvidence() {
        let place = TripsListView.matchCaption(for: [TripSearchEvidence(kind: .place, text: "Oxford")])
        #expect(place == TripsListView.MatchCaption(kind: .includes, value: "Oxford"))
        #expect(place?.systemImage == "mappin")
        let region = TripsListView.matchCaption(for: [TripSearchEvidence(kind: .region, text: "Catalonia")])
        #expect(region == TripsListView.MatchCaption(kind: .includes, value: "Catalonia"))
    }

    @Test func captionNamesTransitEvidenceAsPassedThrough() {
        let caption = TripsListView.matchCaption(for: [TripSearchEvidence(kind: .transit, text: "Frankfurt")])
        #expect(caption == TripsListView.MatchCaption(kind: .passedThrough, value: "Frankfurt"))
        #expect(caption?.systemImage == "airplane")
    }

    @Test func captionSkipsTitleDateAndCountryEvidence() {
        #expect(TripsListView.matchCaption(for: []) == nil)
        #expect(TripsListView.matchCaption(for: [TripSearchEvidence(kind: .title, text: "Honeymoon")]) == nil)
        #expect(TripsListView.matchCaption(for: [TripSearchEvidence(kind: .date, text: "2024")]) == nil)
        #expect(TripsListView.matchCaption(for: [TripSearchEvidence(kind: .country, text: "DE")]) == nil)
    }

    @Test func captionPrefersADestinationOverATransitStop() {
        let caption = TripsListView.matchCaption(for: [
            TripSearchEvidence(kind: .transit, text: "Frankfurt"),
            TripSearchEvidence(kind: .country, text: "US"),
            TripSearchEvidence(kind: .place, text: "White Plains"),
        ])
        #expect(caption == TripsListView.MatchCaption(kind: .includes, value: "White Plains"))
    }

    // MARK: - Hidden by filters

    @Test func hiddenByFiltersCountsStrictMatchesTheFiltersRemove() {
        #expect(TripsListView.hiddenByFiltersCount(preFilterCount: 7, strictCount: 3, filtersActive: true) == 4)
        #expect(TripsListView.hiddenByFiltersCount(preFilterCount: 3, strictCount: 3, filtersActive: true) == 0)
        #expect(TripsListView.hiddenByFiltersCount(preFilterCount: 7, strictCount: 3, filtersActive: false) == 0)
        #expect(TripsListView.hiddenByFiltersCount(preFilterCount: 0, strictCount: 2, filtersActive: true) == 0)
    }

    // MARK: - Trailing partial

    @Test func trailingPartialOnlyWhileTheLastWordIsStillBeingTyped() {
        #expect(TripsListView.allowsTrailingPartial(rawQuery: "par"))
        #expect(TripsListView.allowsTrailingPartial(rawQuery: "trips to lis"))
        #expect(!TripsListView.allowsTrailingPartial(rawQuery: "paris "))
        #expect(!TripsListView.allowsTrailingPartial(rawQuery: "paris,"))
        #expect(!TripsListView.allowsTrailingPartial(rawQuery: "paris."))
        #expect(!TripsListView.allowsTrailingPartial(rawQuery: ""))
    }

    // MARK: - Did you mean

    private static func document(place: [String], countries: [String] = []) -> TripSearchDocument {
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        return TripSearchDocument(
            tripID: UUID(),
            fields: [
                TripSearchField(kind: .place, displayValues: place),
                TripSearchField(kind: .country, displayValues: TripSearch.countryAliases(
                    for: countries, languageTag: "en")),
            ],
            startDate: start,
            endDate: nil,
            startYear: 2024,
            startMonth: 7,
            durationDays: nil,
            isComplete: true,
            countryCodes: Set(countries))
    }

    private static let suggestionIndex = TripSearchIndex(documents: [
        document(place: ["Ioánnina"], countries: ["GR"]),
        document(place: ["Barcelona"], countries: ["ES"]),
    ])

    @Test func didYouMeanOffersTheResolverVerifiedCorrection() {
        let suggestion = TripsListView.spellingSuggestion(
            query: "ioanna", hasStrongMatch: false, index: Self.suggestionIndex,
            languageTag: "en", isKnownWord: { _ in false })
        #expect(suggestion == "Ioánnina")
    }

    @Test func didYouMeanStaysQuietWhenStrongResultsExist() {
        #expect(TripsListView.spellingSuggestion(
            query: "ioanna", hasStrongMatch: true, index: Self.suggestionIndex,
            languageTag: "en", isKnownWord: nil) == nil)
        #expect(TripsListView.spellingSuggestion(
            query: "barcelona", hasStrongMatch: false, index: Self.suggestionIndex,
            languageTag: "en", isKnownWord: nil) == nil)
        #expect(TripsListView.spellingSuggestion(
            query: "   ", hasStrongMatch: false, index: Self.suggestionIndex,
            languageTag: "en", isKnownWord: nil) == nil)
    }

    @Test func didYouMeanKeepsAKnownWordAsTyped() {
        // A correctly spelled place the user never visited is not a typo for one they did.
        #expect(TripsListView.spellingSuggestion(
            query: "ioanna", hasStrongMatch: false, index: Self.suggestionIndex,
            languageTag: "en", isKnownWord: { _ in true }) == nil)
    }

    @Test func spellCheckLanguagesPreferTheExactDictionaryAndSkipMissingOnes() {
        let available = ["en_US", "en_GB", "pt_PT", "pt_BR", "el_GR", "de"]
        #expect(TripsListView.spellCheckLanguages(for: ["en", "pt-BR"], available: available) == ["en_US", "pt_BR"])
        #expect(TripsListView.spellCheckLanguages(for: ["en", "de"], available: available) == ["en_US", "de"])
        #expect(TripsListView.spellCheckLanguages(for: ["en", "el"], available: available) == ["en_US", "el_GR"])
        #expect(TripsListView.spellCheckLanguages(for: ["en", "zh-Hans"], available: available) == ["en_US"])
        #expect(TripsListView.spellCheckLanguages(for: ["en", "en"], available: available) == ["en_US"])
        #expect(TripsListView.spellCheckLanguages(for: ["ja"], available: available).isEmpty)
    }

    @Test func spellCheckUsesOnlyDictionariesOfTheWordsScript() {
        // en passes every Greek or Cyrillic word, so a typo there would never get "Did you mean".
        let available = ["en_US", "de", "el_GR", "ru_RU"]
        #expect(TripsListView.spellCheckLanguages(forWord: "Ιωάννιννα", languageTag: "en", available: available).isEmpty)
        #expect(TripsListView.spellCheckLanguages(forWord: "Ιωάννιννα", languageTag: "el", available: available) == ["el_GR"])
        #expect(TripsListView.spellCheckLanguages(forWord: "шанхаии", languageTag: "en", available: available).isEmpty)
        #expect(TripsListView.spellCheckLanguages(forWord: "barcelnoa", languageTag: "el", available: available) == ["en_US"])
        #expect(TripsListView.spellCheckLanguages(forWord: "barcelnoa", languageTag: "ja", available: available) == ["en_US"])
        #expect(TripsListView.spellCheckLanguages(forWord: "barcelnoa", languageTag: "de", available: available) == ["en_US", "de"])
        #expect(TripsListView.spellCheckLanguages(forWord: "東京", languageTag: "ja", available: available).isEmpty)
        #expect(TripsListView.spellCheckLanguages(forWord: "Tokyoκ", languageTag: "el", available: available).isEmpty)
    }

    @Test func spellCheckScriptReadsLettersOnly() {
        #expect(TripsListView.spellCheckScript(of: "Hà Nội") == "Latn")
        #expect(TripsListView.spellCheckScript(of: "café2024") == "Latn")
        #expect(TripsListView.spellCheckScript(of: "Ηράκλειο") == "Grek")
        #expect(TripsListView.spellCheckScript(of: "Ηρα\u{301}κλειο") == "Grek")
        #expect(TripsListView.spellCheckScript(of: "Москва") == "Cyrl")
        #expect(TripsListView.spellCheckScript(of: "東京") == nil)
        #expect(TripsListView.spellCheckScript(of: "Tokyoκ") == nil)
        #expect(TripsListView.spellCheckScript(of: "2024") == nil)
    }

    // MARK: - Upcoming journeys while searching

    private static let kyotoParts = TripsListView.journeySearchParts(
        journeyTitles: ["Kyoto → Osaka", "Flight to Kyoto"],
        legs: [
            TripsListView.JourneySearchLeg(
                title: "Flight to Kyoto", locationText: "Kansai International Airport",
                resolvedLocality: "Kyoto", resolvedCountry: "Japan", resolvedISOCountryCode: "JP"),
            TripsListView.JourneySearchLeg(
                title: "Hotel Nikko", locationText: nil,
                resolvedLocality: "Osaka", resolvedCountry: nil, resolvedISOCountryCode: nil),
        ],
        languageTag: "en")

    @Test func upcomingJourneyMatchesItsTitlesPlacesAndCountryStrongly() {
        #expect(TripsListView.journeyMatchesSearch("kyoto", parts: Self.kyotoParts, languageTag: "en"))
        #expect(TripsListView.journeyMatchesSearch("osa", parts: Self.kyotoParts, languageTag: "en"))
        #expect(TripsListView.journeyMatchesSearch("nikko", parts: Self.kyotoParts, languageTag: "en"))
        #expect(TripsListView.journeyMatchesSearch("kansai", parts: Self.kyotoParts, languageTag: "en"))
        #expect(TripsListView.journeyMatchesSearch("japan", parts: Self.kyotoParts, languageTag: "en"))
        #expect(TripsListView.journeyMatchesSearch("JP", parts: Self.kyotoParts, languageTag: "en"))
    }

    @Test func upcomingJourneyIgnoresTyposAndOtherPlaces() {
        #expect(!TripsListView.journeyMatchesSearch("kyotp", parts: Self.kyotoParts, languageTag: "en"))
        #expect(!TripsListView.journeyMatchesSearch("lisbon", parts: Self.kyotoParts, languageTag: "en"))
        #expect(!TripsListView.journeyMatchesSearch("kyoto lisbon", parts: Self.kyotoParts, languageTag: "en"))
    }

    @Test func upcomingJourneyAnswersThePhrasingsPastTripsAnswer() {
        // The list's resolver drops filler words, as it does for past trips.
        for query in ["trip to kyoto", "trips to kyoto", "kyoto trip", "japan trips", "my kyoto trip"] {
            #expect(TripsListView.journeyMatchesSearch(query, parts: Self.kyotoParts, languageTag: "en"), "\(query)")
        }
    }

    @Test func upcomingJourneyMatchesItsOwnYearAndMonth() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TripFilters.yearCalendar.timeZone
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 18)))
        func matches(_ query: String) -> Bool {
            TripsListView.journeyMatchesSearch(
                query, parts: Self.kyotoParts, startDate: start, endDate: end, languageTag: "en")
        }
        #expect(matches("kyoto 2026"))
        #expect(matches("kyoto in october"))
        #expect(!matches("kyoto 2019"))
        #expect(!matches("kyoto in may"))
        // Without dates no year or month can match.
        #expect(!TripsListView.journeyMatchesSearch("kyoto 2026", parts: Self.kyotoParts, languageTag: "en"))
    }

    // MARK: - Result count

    @Test func matchingUpcomingJourneysCountAsResults() {
        // A planned Tokyo trip is the answer to "tokyo": VoiceOver must not hear "No matching trips".
        #expect(TripsListView.searchResultCount(visibleTrips: 0, visibleJourneys: 1) == 1)
        #expect(TripsListView.searchResultCount(visibleTrips: 2, visibleJourneys: 1) == 3)
        #expect(TripsListView.searchResultCount(visibleTrips: 4, visibleJourneys: 0) == 4)
    }

    @Test func searchFeedbackWaitsForTypingToPause() {
        // One count announcement per pause, not one per settled keystroke.
        #expect(TripsListView.resultCountAnnouncementDelay >= .milliseconds(500))
        #expect(TripsListView.resultCountAnnouncementDelay <= .milliseconds(750))
    }

    // MARK: - No-results card quiet period

    @Test func emptyCardWaitsForTheFieldsQuietPeriod() {
        func visible(
            query: String = "zqw", revealed: String?, fieldSettled: Bool = true, resultsCurrent: Bool = true,
            resultsEmpty: Bool = true, hasAnyTrips: Bool = true, journeysEmpty: Bool = true
        ) -> Bool {
            TripsListView.emptyStateCardVisible(
                query: query, revealedQuery: revealed, fieldSettled: fieldSettled, resultsCurrent: resultsCurrent,
                resultsEmpty: resultsEmpty, hasAnyTrips: hasAnyTrips, journeysEmpty: journeysEmpty)
        }
        // The local search settles 100 ms after each key; the card still
        // waits until the field has been quiet.
        #expect(!visible(revealed: nil))
        #expect(!visible(query: "zqwe", revealed: "zqw"))
        #expect(visible(revealed: "zqw"))
        #expect(!visible(query: "", revealed: ""))
        // Every settled-state gate still applies once the pause is over.
        #expect(!visible(revealed: "zqw", fieldSettled: false))
        #expect(!visible(revealed: "zqw", resultsCurrent: false))
        #expect(!visible(revealed: "zqw", resultsEmpty: false))
        #expect(!visible(revealed: "zqw", hasAnyTrips: false))
        #expect(!visible(revealed: "zqw", journeysEmpty: false))
    }

    @Test func emptyCardQuietPeriodOutlastsTheLocalDebounce() {
        // The card waits past the local debounce, so a settled keystroke alone never reveals it.
        #expect(TripsListView.emptyStateDelay > TripsListView.localSearchDebounce)
        // Longer than a typical keystroke gap, so typing does not blink it.
        #expect(TripsListView.emptyStateDelay >= .milliseconds(300))
        // The zero count, announced after a settled recompute, never outruns it.
        #expect(TripsListView.emptyStateDelay
            < TripsListView.localSearchDebounce + TripsListView.resultCountAnnouncementDelay)
    }

    // MARK: - Wipe during the rebuild

    @Test func wipeRevokesSearchSlicesSettledBeforeIt() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: Date(timeIntervalSince1970: 1_700_000_000))
        context.insert(trip)
        var settled = TripsListView.TripSlices()
        settled.query = "weding"
        settled.all = [trip]
        settled.similar = [trip]
        settled.strictCount = 1
        settled.preFilterCount = 1
        settled.spellingSuggestion = "Wedding"
        settled.wipeRevision = 0

        let revoked = try #require(TripsListView.slicesWhilePreparing(settled, wipeRevision: 1))
        // An empty query is current for no search, so no rows, suggestion,
        // or empty card show until the rebuilt index answers.
        #expect(revoked.query.isEmpty)
        #expect(revoked.all.isEmpty && revoked.similar.isEmpty && revoked.partial.isEmpty)
        #expect(revoked.pinned.isEmpty && revoked.active.isEmpty && revoked.completed.isEmpty)
        #expect(revoked.spellingSuggestion == nil)
        #expect(revoked.strictCount == 0 && revoked.preFilterCount == 0)
        // Stamped with the wipe, so the rerun the reset triggers keeps it.
        #expect(revoked.wipeRevision == 1)
        #expect(TripsListView.slicesWhilePreparing(revoked, wipeRevision: 1) == nil)
    }

    @Test func ordinaryPreparationKeepsSettledSlices() {
        var settled = TripsListView.TripSlices()
        settled.query = "lisbon"
        settled.spellingSuggestion = "Lisbon"
        settled.wipeRevision = 2
        // A publish or a changed row without a wipe keeps the last answer on screen.
        #expect(TripsListView.slicesWhilePreparing(settled, wipeRevision: 2) == nil)
        // Unsearched slices hold no search text, so a wipe keeps the plain list.
        var unsearched = TripsListView.TripSlices()
        unsearched.wipeRevision = 0
        #expect(TripsListView.slicesWhilePreparing(unsearched, wipeRevision: 1) == nil)
    }

    @Test func journeySearchPartsDropEmptyValues() {
        let parts = TripsListView.journeySearchParts(
            journeyTitles: ["Rome", " "],
            legs: [TripsListView.JourneySearchLeg(
                title: "", locationText: "", resolvedLocality: nil, resolvedCountry: nil, resolvedISOCountryCode: "")],
            languageTag: "en")
        #expect(parts == ["Rome"])
    }

    // MARK: - Temporary homes while searching

    private static let erasmusParts = TripsListView.temporaryHomeSearchParts(
        label: "Erasmus", locality: "Brussels", country: "Belgique", isoCountryCode: "BE", languageTag: "en")

    private static func matchesErasmus(_ query: String) -> Bool {
        TripsListView.journeyMatchesSearch(query, parts: erasmusParts, languageTag: "en")
    }

    @Test("search finds a temporary home by its label, its city and its country")
    func temporaryHomeMatchesLabelAndPlace() {
        #expect(Self.matchesErasmus("erasmus"))
        #expect(Self.matchesErasmus("Erasm"))
        #expect(Self.matchesErasmus("brussels"))
        // The stored country, and the country's name in the app language from its code.
        #expect(Self.matchesErasmus("belgique"))
        #expect(Self.matchesErasmus("belgium"))
    }

    @Test("search does not show a temporary home for another place or a typo")
    func temporaryHomeIgnoresOtherPlaces() {
        #expect(!Self.matchesErasmus("lisbon"))
        #expect(!Self.matchesErasmus("erasmus lisbon"))
        // No dates are indexed: a year alone never lists a temporary home.
        #expect(!Self.matchesErasmus("2025"))
    }

    @Test("a temporary home without a label or place answers nothing")
    func temporaryHomeSearchPartsDropEmptyValues() {
        let parts = TripsListView.temporaryHomeSearchParts(
            label: "", locality: nil, country: nil, isoCountryCode: nil, languageTag: "en")
        #expect(parts.isEmpty)
        #expect(!TripsListView.journeyMatchesSearch("brussels", parts: parts, languageTag: "en"))
    }
}
