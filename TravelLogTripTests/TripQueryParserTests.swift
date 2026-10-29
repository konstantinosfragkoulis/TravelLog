//
//  TripQueryParserTests.swift
//  TravelLogTests
//
//  Deterministic NL query parsing (TripQueryParser) and the shared resolver
//  over a `TripSearchIndex`: the structured pass that runs next to the
//  engine, the place-first reading of ambiguous words, and the partial
//  fallback. Everything here is pure: `parse` takes an injected `now`,
//  calendar and language, and fixtures are `TripSearchDocument`s built with
//  the public initializer, so no fixture depends on the runner's clock,
//  timezone or language.
//

import Testing
import Foundation
import os
@testable import TravelLog

struct TripQueryParserTests {

    private var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int = 15) -> Date {
        utcCal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func parse(_ q: String, now: Date? = nil, languageTag: String = "en") -> TripQueryParser.ParsedQuery {
        TripQueryParser.parse(q, now: now ?? date(2026, 7, 14), calendar: utcCal, languageTag: languageTag)
    }

    /// One trip as the index sees it: the place is the destination summary
    /// and, unless `title` is given, the display title too.
    private func trip(
        _ place: String,
        year: Int = 2026,
        month: Int,
        day: Int = 1,
        durationDays: Int? = 4,
        title: String? = nil,
        countries: [String] = [],
        transit: [String] = [],
        languageTag: String = "en",
        dayShift: Int = 0
    ) -> TripSearchDocument {
        let start = utcCal.date(byAdding: .day, value: dayShift, to: date(year, month, day))!
        let end = durationDays.map { utcCal.date(byAdding: .day, value: $0 - 1, to: start)! }
        return TripSearchDocument(
            tripID: UUID(),
            fields: [
                TripSearchField(kind: .title, displayValues: [title ?? place]),
                TripSearchField(kind: .place, displayValues: [place]),
                TripSearchField(
                    kind: .country,
                    displayValues: TripSearch.countryAliases(for: countries, languageTag: languageTag)),
                TripSearchField(
                    kind: .date,
                    displayValues: TripSearchDocument.dateWords(
                        start: start, end: end, languageTag: languageTag, calendar: utcCal)),
                TripSearchField(kind: .transit, displayValues: transit),
            ],
            startDate: start,
            endDate: end,
            startYear: utcCal.component(.year, from: start),
            startMonth: utcCal.component(.month, from: start),
            durationDays: durationDays,
            isComplete: end != nil,
            countryCodes: Set(countries))
    }

    private func search(
        _ trips: [TripSearchDocument],
        _ query: String,
        now: Date? = nil,
        typing: Bool = false,
        languageTag: String = "en"
    ) -> [TripSearchMatch] {
        TripQueryParser.searchTrips(
            index: TripSearchIndex(documents: trips),
            query: query,
            allowsTrailingPartial: typing,
            now: now ?? date(2026, 7, 14),
            calendar: utcCal,
            languageTag: languageTag)
    }

    /// Trip IDs of a search, in index order.
    private func found(
        _ trips: [TripSearchDocument],
        _ query: String,
        now: Date? = nil,
        typing: Bool = false,
        languageTag: String = "en"
    ) -> [UUID] {
        search(trips, query, now: now, typing: typing, languageTag: languageTag).map { trips[$0.documentIndex].tripID }
    }

    private func raws(_ terms: [TripSearchTerm]) -> [String] { terms.map(\.raw) }

    @Test("a structured date query matches months wholly inside a trip")
    func interiorMonthMatchesStructuredDates() {
        let spanning = trip("Paris", year: 2024, month: 5, day: 20, durationDays: 52)
        let outside = trip("Rome", year: 2024, month: 7)
        #expect(found([spanning, outside], "trips in June 2024") == [spanning.tripID])
        let matches = search([spanning], "Paris in June 2024")
        #expect(matches.count == 1)
        #expect(matches.first?.strength == .strong)
        #expect(!TripQueryParser.matchesFilters(spanning, parsed: parse("June 2025"), calendar: utcCal))
    }

    @Test("interior months preserve paired clauses and winter's year offset")
    func interiorMonthsPreserveDateClausePairing() {
        let spanning = trip("Paris", year: 2024, month: 10, durationDays: 153)
        #expect(TripQueryParser.matchesFilters(spanning, parsed: parse("winter 2024"), calendar: utcCal))
        #expect(!TripQueryParser.matchesFilters(spanning, parsed: parse("summer 2024 or winter 2025"), calendar: utcCal))
    }

    @Test("long trips match interior years and recurring months without walking their span")
    func longTripMatchesInteriorDateClauses() {
        let spanning = trip("Paris", year: 2000, month: 3, durationDays: 365 * 30)
        for query in ["June 2024", "2024", "February"] {
            #expect(TripQueryParser.matchesFilters(spanning, parsed: parse(query), calendar: utcCal), "\(query)")
        }
        #expect(!TripQueryParser.matchesFilters(spanning, parsed: parse("June 2031"), calendar: utcCal))
        let ongoing = trip("Paris", year: 2024, month: 5, durationDays: nil)
        #expect(!TripQueryParser.matchesFilters(ongoing, parsed: parse("June 2024"), calendar: utcCal))
    }

    // MARK: - parse: seasons and dates

    @Test("\"summer 2024\" → summer months + year, no residual terms")
    func summerWithYear() {
        let p = parse("summer 2024")
        #expect(p.months == [6, 7, 8])
        #expect(p.years == [2024])
        #expect(p.placeTerms.isEmpty)
        #expect(p.isClaimable)
    }

    @Test("\"last summer\" resolves to the most recent completed summer")
    func lastSummer() {
        // Mid-July 2026: this year's summer isn't over → 2025.
        #expect(parse("last summer").years == [2025])
        #expect(parse("last summer").months == [6, 7, 8])
        // September 2026: summer just ended → 2026.
        #expect(parse("last summer", now: date(2026, 9)).years == [2026])
    }

    @Test("\"last winter\" uses December-year labeling and handles mid-winter")
    func lastWinter() {
        // July 2026 → the winter that ended Feb 2026 is winter 2025.
        let p = parse("last winter")
        #expect(p.years == [2025])
        #expect(p.months == [12, 1, 2])
        // January 2026 (mid-winter) → last COMPLETED winter is 2024.
        #expect(parse("last winter", now: date(2026, 1)).years == [2024])
    }

    @Test("two anchored seasons keep their own years instead of last-wins")
    func multiSeasonUnions() {
        let p = parse("this summer last winter")
        #expect(p.months.isSuperset(of: [6, 7, 8, 12, 1, 2]))
        // Now 14 July 2026: summer 2026 or winter 2025 (Dec 2025 to Feb 2026).
        let summer2026 = trip("Oslo", year: 2026, month: 7, day: 10, durationDays: 3)
        let dec2025 = trip("Oslo", year: 2025, month: 12, day: 10, durationDays: 3)
        let jan2026 = trip("Oslo", year: 2026, month: 1, day: 10, durationDays: 3)
        let feb2026 = trip("Oslo", year: 2026, month: 2, day: 10, durationDays: 3)
        let summer2025 = trip("Oslo", year: 2025, month: 7, day: 10, durationDays: 3)
        let jan2025 = trip("Oslo", year: 2025, month: 1, day: 10, durationDays: 3)
        let dec2024 = trip("Oslo", year: 2024, month: 12, day: 10, durationDays: 3)
        let all = [summer2026, dec2025, jan2026, feb2026, summer2025, jan2025, dec2024]
        #expect(found(all, "this summer last winter")
            == [summer2026.tripID, dec2025.tripID, jan2026.tripID, feb2026.tripID])
    }

    @Test("\"more than <Int.max> days\" clamps instead of trapping")
    func intMaxDurationClamps() {
        let p = parse("more than 9223372036854775807 days")
        #expect(p.minDurationDays == Int.max)
        #expect(parse("99999999999999999999 weeks").maxDurationDays == Int.max)
    }

    @Test("\"last year\" / \"this year\" / \"last month\" resolve against the injected now")
    func relativeYearAndMonth() {
        #expect(parse("last year").years == [2025])
        #expect(parse("this year").years == [2026])
        let lastMonth = parse("last month")
        #expect(lastMonth.months == [6])
        #expect(lastMonth.years == [2026])
        // January wraps to December of the previous year.
        let janCase = parse("last month", now: date(2026, 1))
        #expect(janCase.months == [12])
        #expect(janCase.years == [2025])
    }

    @Test("month name + bare year: \"may 2024\"")
    func monthNameAndYear() {
        let p = parse("may 2024")
        #expect(p.months == [5])
        #expect(p.years == [2024])
    }

    @Test("anchored month names are unambiguously structured")
    func anchoredMonthNames() {
        let thisMay = parse("this May")
        #expect(thisMay.months == [5])
        #expect(thisMay.years == [2026])
        #expect(thisMay.placeInterpretation == nil)

        // In July 2026, the most recent completed May is May 2026. In March,
        // it is May 2025.
        #expect(parse("last May").years == [2026])
        #expect(parse("last May", now: date(2026, 3)).years == [2025])
        #expect(parse("May 2025").placeInterpretation == nil)
    }

    @Test("\"summer of 2024\" anchors through the year connector")
    func yearConnector() {
        let p = parse("summer of 2024")
        #expect(p.months == [6, 7, 8])
        #expect(p.years == [2024])
        #expect(p.placeInterpretation == nil)
        #expect(p.placeTerms.isEmpty)
    }

    // MARK: - parse: durations

    @Test("duration phrases map to the FM tool's min/max semantics")
    func durationPhrases() {
        #expect(parse("longer than a week").minDurationDays == 8)
        #expect(parse("less than a week").maxDurationDays == 6)
        #expect(parse("at least a week").minDurationDays == 7)
        #expect(parse("more than 10 days").minDurationDays == 11)
        #expect(parse("less than 4 days").maxDurationDays == 3)
        #expect(parse("at least 5 days").minDurationDays == 5)
        #expect(parse("up to 4 days").maxDurationDays == 4)
        #expect(parse("3 days or more").minDurationDays == 3)
        #expect(parse("2 days or less").maxDurationDays == 2)

        let weekLong = parse("week-long trips")
        #expect(weekLong.minDurationDays == 6)
        #expect(weekLong.maxDurationDays == 8)

        let exact = parse("5-day trips")
        #expect(exact.minDurationDays == 5)
        #expect(exact.maxDurationDays == 5)

        #expect(parse("day trips").maxDurationDays == 1)

        let weekend = parse("weekend trips")
        #expect(weekend.minDurationDays == 2)
        #expect(weekend.maxDurationDays == 3)
    }

    /// Duration grammar: over/under are strict, `N+` is
    /// inclusive, a week is 6 to 8 days, N weeks are 7N ± N, a fortnight is 12 to 16.
    @Test(
        "duration grammar table",
        arguments: [
            ("trips over 10 days", 11, nil), ("under 5 days", nil, 4), ("10+ days", 10, nil),
            ("2 weeks", 12, 16), ("a week in rome", 6, 8), ("five days", 5, 5),
            ("1 week", 6, 8), ("one week", 6, 8), ("a week", 6, 8), ("3 weeks", 18, 24),
            ("fortnight", 12, 16), ("a fortnight", 12, 16), ("twenty-one days", 21, 21),
            ("twenty one days", 21, 21), ("more than 2 weeks", 15, nil),
            ("less than two weeks", nil, 13), ("at least 2 weeks", 14, nil), ("up to 3 days", nil, 3),
            ("shorter than 3 days", nil, 2), ("longer than a fortnight", 15, nil),
            ("weeklong", 6, 8), ("week long", 6, 8), ("2+ weeks", 14, nil), ("weekend", 2, 3),
            ("weekends", 2, 3), ("2 weeks or more", 14, nil),
        ] as [(String, Int?, Int?)]
    )
    func durationGrammar(query: String, min: Int?, max: Int?) {
        let p = parse(query)
        #expect(p.minDurationDays == min, "\(query)")
        #expect(p.maxDurationDays == max, "\(query)")
    }

    @Test("\"a week in rome\" keeps rome as the only place term")
    func weekInRome() {
        let p = parse("a week in rome")
        #expect(raws(p.placeTerms) == ["rome"])
        #expect(p.isClaimable)
    }

    @Test("structured filter + residual place terms: \"trips longer than a week in greece\"")
    func durationPlusPlace() {
        let p = parse("trips longer than a week in greece")
        #expect(p.minDurationDays == 8)
        #expect(raws(p.placeTerms) == ["greece"])
        #expect(p.droppedNoise)
        #expect(p.isClaimable)
    }

    // MARK: - parse: years

    @Test("years are OR'd and ranges fill spans of at most ten years")
    func yearsAndRanges() {
        #expect(parse("2024 2025").years == [2024, 2025])
        #expect(parse("2023-2024").years == [2023, 2024])
        #expect(parse("2023 to 2024").years == [2023, 2024])
        #expect(parse("2023–2024").years == [2023, 2024])
        #expect(parse("2024-2023").years == [2023, 2024])
        #expect(parse("2020-2030").years == Set(2020...2030))
        #expect(parse("2000-2024").years == [2000, 2024])
        #expect(parse("2023-2024").placeTerms.isEmpty)
        #expect(parse("１９９９").years == [1999])
        #expect(parse("1899").years.isEmpty)
    }

    @Test("a year list and a year range return trips starting in any listed year")
    func yearsSearch() {
        let y2022 = trip("Oslo", year: 2022, month: 6)
        let y2023 = trip("Rome", year: 2023, month: 6)
        let y2024 = trip("Paris", year: 2024, month: 6)
        let y2025 = trip("Lima", year: 2025, month: 6)
        let all = [y2022, y2023, y2024, y2025]
        #expect(found(all, "2023-2024") == [y2023.tripID, y2024.tripID])
        #expect(found(all, "2024 2025") == [y2024.tripID, y2025.tripID])
    }

    // MARK: - parse: claimability

    @Test("place-only query with no noise is NOT claimable (the engine already tried it)")
    func bareQueryNotClaimable() {
        let p = parse("tokyo")
        #expect(!p.hasStructuredFilter)
        #expect(!p.droppedNoise)
        #expect(!p.isClaimable)
    }

    @Test("noise-stripped place query IS claimable: \"trips to greece\"")
    func noiseStrippedClaimable() {
        let p = parse("trips to greece")
        #expect(!p.hasStructuredFilter)
        #expect(p.droppedNoise)
        #expect(raws(p.placeTerms) == ["greece"])
        #expect(p.isClaimable)
    }

    @Test("\"long\" is place text except before a trip noun or weekend")
    func longIsPlaceTextUnlessLength() {
        let beach = parse("long beach")
        #expect(raws(beach.placeTerms) == ["long", "beach"])
        #expect(!beach.droppedNoise)
        #expect(!beach.isClaimable)

        #expect(raws(parse("ha long").placeTerms) == ["ha", "long"])

        let longTrips = parse("long trips")
        #expect(longTrips.placeTerms.isEmpty)
        #expect(longTrips.droppedNoise)
        #expect(longTrips.minDurationDays == 8)
        #expect(longTrips.maxDurationDays == nil)
        #expect(longTrips.isClaimable)

        let weekend = parse("long weekend in paris")
        #expect(weekend.minDurationDays == 3)
        #expect(weekend.maxDurationDays == 4)
        #expect(raws(weekend.placeTerms) == ["paris"])

        #expect(raws(parse("long trip to greece").placeTerms) == ["greece"])
        #expect(raws(parse("long visit to greece").placeTerms) == ["greece"])
        #expect(raws(parse("long visits to greece").placeTerms) == ["greece"])

        let hyphenated = parse("long-weekend in paris")
        #expect(hyphenated.minDurationDays == 3)
        #expect(hyphenated.maxDurationDays == 4)
        #expect(raws(hyphenated.placeTerms) == ["paris"])

        let weekLong = parse("week-long trips")
        #expect(weekLong.minDurationDays == 6)
        #expect(weekLong.maxDurationDays == 8)
    }

    @Test("\"long\" after a name some trip has that ends in it stays that name; otherwise a length")
    func longAfterPlaceText() {
        let haLong = parse("ha long trips")
        #expect(raws(haLong.placeTerms) == ["ha"])
        #expect(haLong.droppedNoise)
        #expect(haLong.isClaimable)
        #expect(haLong.minDurationDays == 8)
        #expect(haLong.placeInterpretation == nil)

        let corpus = TripSearchIndex(documents: [trip("Ha Long", month: 5), trip("Long Beach", month: 6)])
        func named(_ query: String) -> TripQueryParser.ParsedQuery {
            TripQueryParser.parse(query, now: date(2026, 7, 14), calendar: utcCal, languageTag: "en", corpus: corpus)
        }
        #expect(raws(named("ha long trips").placeTerms) == ["ha", "long"])
        #expect(named("ha long trips").minDurationDays == nil)
        #expect(named("ha long trips over 5 days").minDurationDays == 6)
        // The next "long" is a length again, read by its own position.
        #expect(named("ha long long trips").minDurationDays == 8)
        #expect(raws(named("ha long long trips").placeTerms) == ["ha", "long"])
        let weekend = named("long beach long weekend")
        #expect(raws(weekend.placeTerms) == ["long", "beach"])
        #expect(weekend.minDurationDays == 3 && weekend.maxDurationDays == 4)

        // Nothing, noise, a year or a date word before "long" leaves it filler.
        for query in ["long trips", "my long trips", "show me long trips", "2024 long trips", "last summer long trips", "week-long trips"] {
            #expect(parse(query).placeInterpretation == nil, "\(query)")
            #expect(!raws(parse(query).placeTerms).contains("long"), "\(query)")
        }
    }

    // MARK: - season/month words inside place names

    /// "Palm Springs" matched the
    /// plural season pattern and set a spring-months filter; "Idaho Falls" set
    /// an autumn one. Both then reported `hasStructuredFilter`, so the parser
    /// CLAIMED a pure place search and silently date-filtered it.
    @Test("plural place names are not seasons: \"palm springs\" / \"idaho falls\"")
    func pluralPlaceNamesAreNotSeasons() {
        let springs = parse("palm springs")
        #expect(springs.months.isEmpty)
        #expect(raws(springs.placeTerms) == ["palm", "springs"])
        #expect(!springs.isClaimable)

        let falls = parse("idaho falls")
        #expect(falls.months.isEmpty)
        #expect(raws(falls.placeTerms) == ["idaho", "falls"])
        #expect(!falls.isClaimable)
    }

    /// A bare season/month still claims, including alongside place terms,
    /// while retaining the alternate place reading for corpus-aware search.
    @Test("a bare season or month claims the query")
    func bareSeasonAloneStillClaims() {
        let placeAndSeason = parse("greece summer")
        #expect(placeAndSeason.months == [6, 7, 8])
        #expect(raws(placeAndSeason.placeTerms) == ["greece"])
        #expect(placeAndSeason.isClaimable)
        #expect(placeAndSeason.placeInterpretation.map { raws($0.placeTerms) } == ["greece", "summer"])

        let season = parse("summer")
        #expect(season.months == [6, 7, 8])
        #expect(season.placeTerms.isEmpty)
        #expect(season.isClaimable)

        let month = parse("trips in december")
        #expect(month.months == [12])
        #expect(month.placeTerms.isEmpty)
        #expect(month.isClaimable)
    }

    /// And a year or duration alongside it is structure regardless of places.
    @Test("a year or duration keeps the query claimable even with place terms")
    func corroboratedFiltersStillClaim() {
        let withYear = parse("greece summer 2024")
        #expect(withYear.years == [2024])
        #expect(withYear.months == [6, 7, 8])
        #expect(raws(withYear.placeTerms) == ["greece"])
        #expect(withYear.isClaimable)
        #expect(withYear.placeInterpretation == nil)
    }

    /// The natural phrasing
    /// of a place-plus-season query carries a preposition, which is a noise
    /// word, so it still claims through the noise arm.
    @Test("\"greece in summer\" still claims: the preposition keeps it in the noise arm")
    func placePlusSeasonWithPrepositionStillClaims() {
        let p = parse("greece in summer")
        #expect(p.months == [6, 7, 8])
        #expect(raws(p.placeTerms) == ["greece"])
        #expect(p.droppedNoise)
        #expect(p.isClaimable)
    }

    // MARK: - Resolver: place-first reading

    @Test("ambiguous month and season words prefer matching place names")
    func ambiguousWordsPreferPlaces() {
        let fixtures: [(name: String, month: Int)] = [
            ("Winter Park", 7),
            ("Spring", 10),
            ("May", 10),
            ("March", 10),
            ("Fall River", 4),
        ]

        for fixture in fixtures {
            let placeTrip = trip(fixture.name, month: fixture.month)
            let matches = found([placeTrip], "trips to \(fixture.name)")
            #expect(matches == [placeTrip.tripID], "\(fixture.name)")
        }
    }

    @Test("place interpretation does not confuse formatted month dates with a place")
    func placeInterpretationExcludesDateStrings() {
        let mayPlace = trip("May", month: 10)
        let unrelatedMayTrip = trip("Lisbon", month: 5)

        for query in ["trips to May", "May"] {
            #expect(found([mayPlace, unrelatedMayTrip], query) == [mayPlace.tripID], "\(query)")
        }
    }

    @Test("a prefix inside another place name cannot hijack a bare month query")
    func ambiguousTokenRequiresWholeWordPlaceMatch() {
        // "may" starts "Mayfair" but is not a whole word of it, so the place
        // interpretation must not claim the query. The engine then returns
        // BOTH readings (prefix match for Mayfair, month date word for the
        // May trip): the date reading is no longer masked.
        let mayfair = trip("Mayfair", month: 10)
        let lisbonInMay = trip("Lisbon", month: 5)

        let matches = found([mayfair, lisbonInMay], "may")
        #expect(matches.count == 2)
        #expect(matches.contains(lisbonInMay.tripID))
    }

    @Test("a separated year constrains a matching ambiguous place name")
    func ambiguousPlaceWithYear() {
        let place2025 = trip("Winter Park", year: 2025, month: 7)
        let place2024 = trip("Winter Park", year: 2024, month: 7)
        #expect(found([place2025, place2024], "trips to Winter Park 2025") == [place2025.tripID])
    }

    @Test("failed place reading falls through to the structured season filter")
    func placeThenStructuredFallback() {
        let summerGreece = trip("Greece", month: 7)
        let winterGreece = trip("Greece", month: 1)
        #expect(found([summerGreece, winterGreece], "greece summer") == [summerGreece.tripID])
    }

    @Test("a filler word in one custom name does not hide other structured matches")
    func fillerWordInCustomNameKeepsStructuredMatches() {
        func trips(cephaloniaTitle: String?, creteTitle: String?) -> [TripSearchDocument] {
            [
                trip("Athens", month: 5, countries: ["GR"], dayShift: 119),
                trip("Cephalonia", month: 7, title: cephaloniaTitle, countries: ["GR"], dayShift: 119),
                trip("Crete", month: 9, title: creteTitle, countries: ["GR"]),
                trip("Lisbon", month: 6, title: "Family trip", countries: ["PT"]),
            ]
        }
        let first = trips(cephaloniaTitle: "Family trip", creteTitle: nil)
        #expect(found(first, "greece trips") == first.prefix(3).map(\.tripID))

        let second = trips(cephaloniaTitle: nil, creteTitle: "Summer vacation")
        #expect(found(second, "greece vacation") == second.prefix(3).map(\.tripID))
    }

    @Test("a place name containing long does not broaden to its other words")
    func longPlaceNameStaysLiteral() {
        let longBeach = trip("Long Beach", month: 5)
        let miamiBeach = trip("Miami Beach", month: 6)
        let longIsland = trip("Long Island", month: 8, dayShift: 119)
        let canaries = trip("Canary Islands", month: 9)
        let hongKong = trip("Hong Kong", month: 10)
        let all = [longBeach, miamiBeach, longIsland, canaries, hongKong]

        for query in ["Long Beach", "trips to Long Beach", "Long Beach 2026"] {
            #expect(found(all, query) == [longBeach.tripID], "\(query)")
        }

        #expect(found(all, "Long Island") == [longIsland.tripID])

        // "long" stays filler here, so it cannot typo-match "Kong".
        #expect(!found(all, "long trips").contains(hongKong.tripID))

        let namedLongBeach = trip("Long Beach", month: 7, title: "LB trip")
        let beachTrips = found(all + [namedLongBeach], "Long Beach trip")
        #expect(beachTrips == [longBeach.tripID, namedLongBeach.tripID])
        #expect(!beachTrips.contains(miamiBeach.tripID))
    }

    @Test("\"long\" after a place word matches that place before it reads as filler")
    func longAfterPlaceWordPrefersThatPlace() {
        let haLong = trip("Ha Long", month: 4)
        let hanoi = trip("Hanoi", month: 7)
        let liminKhersonisou = trip("Limín Khersonísou", month: 8, dayShift: 119)
        let hongKong = trip("Hong Kong", month: 10)
        let longBeach = trip("Long Beach", month: 5)
        let parisShort = trip("Paris", month: 3, durationDays: 3)
        let parisLong = trip("Paris", month: 11, durationDays: 6)
        let athens = trip("Athens", month: 5, durationDays: 3, countries: ["GR"], dayShift: 119)
        let cephalonia = trip("Cephalonia", month: 7, durationDays: 10, countries: ["GR"], dayShift: 119)
        let all = [haLong, hanoi, liminKhersonisou, hongKong, longBeach, parisShort, parisLong, athens, cephalonia]

        for query in ["Ha Long trips", "Ha Long trip", "Ha Long trips 2026"] {
            #expect(found(all, query) == [haLong.tripID], "\(query)")
        }

        // No whole-word "long" next to the place: the length reading runs.
        #expect(found(all, "Greece long trips") == [cephalonia.tripID])

        #expect(found(all, "Paris long weekend") == [parisShort.tripID])

        // A typo neighbour of "long" must not let Long Beach hide Hong Kong.
        #expect(found(all, "Hong Kong long trips").contains(hongKong.tripID))

        #expect(found(all, "long visit to Greece") == [cephalonia.tripID])
    }

    @Test("month, year, and relative-season queries keep structured semantics")
    func anchoredQueriesStayStructured() {
        let parisMay2025 = trip("Paris", year: 2025, month: 5)
        let parisJune2025 = trip("Paris", year: 2025, month: 6)
        let winter2025 = trip("Oslo", year: 2025, month: 12)
        let winter2024 = trip("Oslo", year: 2024, month: 12)

        #expect(found([parisMay2025, parisJune2025], "trips in May 2025") == [parisMay2025.tripID])
        #expect(found([winter2025, winter2024], "last winter") == [winter2025.tripID])
    }

    @Test("preposition-less place plus month still resolves as a date filter")
    func placePlusMonthFallback() {
        let parisMay = trip("Paris", month: 5)
        let parisJune = trip("Paris", month: 6)
        #expect(found([parisMay, parisJune], "paris may") == [parisMay.tripID])
    }

    @Test("place reading preserves unambiguous duration filters")
    func placeReadingPreservesDuration() {
        let long = trip("Winter Park", month: 7, durationDays: 10)
        let short = trip("Winter Park", month: 7, durationDays: 3)
        #expect(found([long, short], "Winter Park longer than a week") == [long.tripID])
    }

    @Test("both search branches preserve duration bounds and ongoing trips")
    func durationBounds() throws {
        let short = trip("Winter Park", month: 7, durationDays: 3)
        let long = trip("Winter Park", month: 7, durationDays: 10)
        let ongoing = trip("Winter Park", month: 7, durationDays: nil)
        let trips = [long, ongoing, short]
        let index = TripSearchIndex(documents: trips)
        let cases: [(String, [TripSearchDocument])] = [
            ("", trips), ("longer than a week", [long]),
            ("up to 4 days", [short]), ("3-day trips", [short]),
        ]
        for (duration, expected) in cases {
            let query = "Winter Park \(duration)"
            var parsed = try #require(parse(query).placeInterpretation)
            parsed.dates = TripQueryParser.DateFilter(clauses: [.init(months: [.init(month: 7)], years: [2026])])
            let filtered = TripQueryParser.filter(index: index, parsed: parsed).map { trips[$0.documentIndex].tripID }
            #expect(filtered == expected.map(\.tripID), "\(query)")
            #expect(found(trips, query) == expected.map(\.tripID), "\(query)")
        }
    }

    // MARK: - matchesFilters / filter

    @Test("winter + year wraps the year boundary: winter 2024 = Dec 2024 to Feb 2025")
    func winterYearWrap() {
        let winter: Set<TripQueryParser.DateMonth> = [
            .init(month: 12), .init(month: 1, yearOffset: 1), .init(month: 2, yearOffset: 1),
        ]
        var p = TripQueryParser.ParsedQuery()
        p.dates.clauses = [.init(months: winter, years: [2024])]
        func hit(_ y: Int, _ m: Int) -> Bool {
            TripQueryParser.matchesFilters(trip("Oslo", year: y, month: m, durationDays: 5), parsed: p)
        }
        #expect(hit(2024, 12))
        #expect(hit(2025, 1))
        #expect(hit(2025, 2))
        #expect(!hit(2024, 2))   // Feb 2024 belongs to winter 2023
        #expect(!hit(2023, 12))
        #expect(!hit(2024, 7))

        // Winter wraps per wanted year.
        p.dates.clauses = [.init(months: winter, years: [2023, 2025])]
        #expect(hit(2024, 1))
        #expect(hit(2025, 12))
        #expect(!hit(2024, 12))
    }

    // MARK: - Date clauses

    /// Three-day mid-month Oslo trips, one per (year, month).
    private func midMonth(_ months: [(Int, Int)], place: String = "Oslo", countries: [String] = []) -> [TripSearchDocument] {
        months.map { trip(place, year: $0.0, month: $0.1, day: 10, durationDays: 3, countries: countries) }
    }

    @Test("each explicit date clause keeps its own months and years", arguments: [
        "summer 2024 or winter 2025", "summer 2024 and winter 2025", "summer of 2024 or winter of 2025",
    ])
    func explicitClausesKeepTheirAssociation(query: String) {
        let trips = midMonth([(2024, 6), (2025, 6), (2024, 12), (2025, 12), (2026, 1), (2025, 1)])
        let expected = [trips[0].tripID, trips[3].tripID, trips[4].tripID]
        let matches = search(trips, query)
        #expect(matches.map { trips[$0.documentIndex].tripID } == expected, "\(query)")
        #expect(matches.allSatisfy { $0.strength == .strong }, "\(query)")
        // The finished and the still-typing resolver paths agree.
        #expect(found(trips, query, typing: true) == expected, "\(query)")
    }

    @Test("loose months and years join every explicit clause")
    func looseDatePartsJoinEveryClause() {
        let trips = midMonth([(2024, 6), (2025, 6), (2025, 12), (2026, 1), (2025, 1), (2024, 7), (2024, 8), (2025, 8)])
        let ids = trips.map(\.tripID)
        #expect(found(trips, "summer 2024 or 2025") == [ids[0], ids[1], ids[5], ids[6], ids[7]])
        #expect(found(trips, "july 2024 or august") == [ids[5], ids[6]])
        #expect(found(trips, "summer or winter 2025") == [ids[1], ids[2], ids[3], ids[7]])
    }

    @Test("a loose month next to winter keeps winter's year wrap")
    func looseMonthKeepsWinterWrap() {
        let trips = midMonth([(2024, 7), (2024, 12), (2025, 1), (2024, 1), (2025, 7)])
        #expect(found(trips, "july winter 2024") == [trips[0].tripID, trips[1].tripID, trips[2].tripID])
    }

    @Test("CJK numeric dates pair each year with its own month")
    func cjkNumericClausesStayApart() {
        let trips = midMonth([(2024, 7), (2025, 1), (2025, 7), (2024, 1)])
        #expect(found(trips, "2024年7月 2025年1月", languageTag: "ja") == [trips[0].tripID, trips[1].tripID])
        #expect(found(trips, "2024年7月", languageTag: "ja") == [trips[0].tripID])
    }

    @Test("the engine pass respects each consumed clause")
    func enginePassKeepsClauseAssociation() {
        let japan = midMonth([(2024, 6), (2025, 6), (2026, 1)], place: "Tokyo", countries: ["JP"])
        let paris = midMonth([(2024, 6)], place: "Paris", countries: ["FR"])
        let trips = japan + paris
        #expect(found(trips, "japan summer 2024 or winter 2025") == [japan[0].tripID, japan[2].tripID])
    }

    @Test("the place reading keeps an explicit year equal to a recent-season year")
    func placeReadingKeepsExplicitYear() {
        // Now 14 July 2026: Swedish `våras` is spring 2026, and Puerto Varas.
        let recent = trip("Puerto Varas", year: 2026, month: 1, day: 10, durationDays: 3, languageTag: "sv")
        let older = trip("Puerto Varas", year: 2025, month: 1, day: 10, durationDays: 3, languageTag: "sv")
        #expect(found([recent, older], "våras 2026", languageTag: "sv") == [recent.tripID])
        #expect(found([recent, older], "våras", languageTag: "sv") == [recent.tripID, older.tripID])
    }

    @Test("year-only, month-only and empty clauses are wildcards on the other part")
    func clauseWildcards() {
        let yearOnly = TripQueryParser.DateClause(years: [2024])
        #expect(yearOnly.matches(year: 2024, month: 7))
        #expect(!yearOnly.matches(year: 2025, month: 7))
        let monthOnly = TripQueryParser.DateClause(months: [.init(month: 7)])
        #expect(monthOnly.matches(year: 1999, month: 7))
        #expect(!monthOnly.matches(year: 2024, month: 8))
        #expect(TripQueryParser.DateClause().matches(year: 2024, month: 3))

        let trips = midMonth([(2026, 3), (2025, 3), (2026, 7), (2024, 7)])
        #expect(found(trips, "this year") == [trips[0].tripID, trips[2].tripID])
        #expect(found(trips, "2024") == [trips[3].tripID])
        #expect(found(trips, "july") == [trips[2].tripID, trips[3].tripID])
        var parsed = TripQueryParser.ParsedQuery()
        parsed.dates.looseYears = [2026]
        #expect(TripQueryParser.filter(index: TripSearchIndex(documents: trips), parsed: parsed, calendar: utcCal)
            .map(\.documentIndex) == [0, 2])
    }

    @Test("the end date is read in the resolver's calendar, not the device zone")
    func endDateUsesInjectedCalendar() throws {
        var kiritimati = Calendar(identifier: .gregorian)
        kiritimati.timeZone = try #require(TimeZone(identifier: "Pacific/Kiritimati"))
        // 31 Dec 2025 10:30 UTC is 1 Jan 2026 00:30 at UTC+14 only.
        let start = utcCal.date(from: DateComponents(year: 2025, month: 12, day: 28))!
        let end = utcCal.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 10, minute: 30))!
        let document = TripSearchDocument(
            tripID: UUID(),
            fields: [TripSearchField(kind: .place, displayValues: ["Kiribati"])],
            startDate: start,
            endDate: end,
            startYear: 2025,
            startMonth: 12,
            durationDays: 4,
            isComplete: true,
            countryCodes: [])
        let january = parse("january 2026")
        #expect(TripQueryParser.matchesFilters(document, parsed: january, calendar: kiritimati))
        #expect(!TripQueryParser.matchesFilters(document, parsed: january, calendar: utcCal))
        let matches = TripQueryParser.searchTrips(
            index: TripSearchIndex(documents: [document]), query: "january 2026", allowsTrailingPartial: false,
            now: date(2026, 7, 14), calendar: kiritimati, languageTag: "en")
        #expect(matches.map(\.documentIndex) == [0])
    }

    @Test("Upcoming reads explicit date clauses the way the list does")
    func upcomingKeepsClauseAssociation() {
        let calendar = TripFilters.yearCalendar
        func noon(_ y: Int, _ m: Int, _ d: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
        }
        func matches(_ start: Date) -> Bool {
            TripsListView.journeyMatchesSearch(
                "summer 2024 or winter 2025", parts: ["Oslo"], startDate: start,
                endDate: start.addingTimeInterval(2 * 86_400), allowsTrailingPartial: false, languageTag: "en")
        }
        #expect(matches(noon(2026, 1, 10)))
        #expect(matches(noon(2024, 7, 10)))
        #expect(!matches(noon(2025, 7, 10)))
        #expect(!matches(noon(2024, 12, 10)))
    }

    @Test("duration filters exclude ongoing trips (nil duration): FM-tool parity")
    func nilDurationExcluded() {
        var p = TripQueryParser.ParsedQuery()
        p.minDurationDays = 2
        #expect(!TripQueryParser.matchesFilters(trip("Oslo", month: 7, durationDays: nil, dayShift: 119), parsed: p))
    }

    @Test("place terms keep the engine's typo tolerance")
    func placeTokenTypoTolerance() {
        let athens = trip("Athens", month: 7, durationDays: 5, countries: ["GR"], dayShift: 119)
        let index = TripSearchIndex(documents: [athens])
        var p = TripQueryParser.ParsedQuery()
        p.placeTerms = TripSearch.terms("grece", languageTag: "en", allowsTrailingPartial: false)
        #expect(TripQueryParser.filter(index: index, parsed: p).map(\.documentIndex) == [0])
        p.placeTerms = TripSearch.terms("lisbon", languageTag: "en", allowsTrailingPartial: false)
        #expect(TripQueryParser.filter(index: index, parsed: p).isEmpty)
    }

    @Test("filter intersects duration + year, preserving order")
    func filterEndToEnd() {
        let long2025 = trip("Rome", year: 2025, month: 6, durationDays: 10)
        let short2025 = trip("Oslo", year: 2025, month: 7, durationDays: 2)
        let long2024 = trip("Lima", year: 2024, month: 6, durationDays: 12)
        let trips = [long2025, short2025, long2024]

        var p = TripQueryParser.ParsedQuery()
        p.minDurationDays = 8
        p.dates.looseYears = [2025]

        let hits = TripQueryParser.filter(index: TripSearchIndex(documents: trips), parsed: p)
        #expect(hits.map(\.documentIndex) == [0])
        #expect(hits.first?.strength == .strong)
    }

    // MARK: - Acceptance: years and seasons

    @Test("a year finds trips starting in it and the one spanning New Year into it")
    func yearFindsSpanningTrip() {
        let y2023 = trip("Rome", year: 2023, month: 6)
        let y2024 = trip("Paris", year: 2024, month: 6)
        let y2025 = trip("Lima", year: 2025, month: 6)
        let spanning = trip("Oslo", year: 2023, month: 12, day: 28, durationDays: 7)
        let all = [y2023, y2024, y2025, spanning]
        for query in ["2024", "24"] {
            let matches = search(all, query)
            #expect(matches.map { all[$0.documentIndex].tripID } == [y2024.tripID, spanning.tripID], "\(query)")
            #expect(matches.allSatisfy { $0.strength == .strong }, "\(query)")
        }
    }

    @Test("noise words do not narrow the engine pass of a claimed query")
    func fillerHiddenFromClaimedEnginePass() {
        let y2024 = trip("Paris", year: 2024, month: 6)
        let spanning = trip("Oslo", year: 2023, month: 12, day: 28, durationDays: 7)
        let y2023 = trip("Rome", year: 2023, month: 6)
        #expect(found([y2024, spanning, y2023], "trips in 2024") == [y2024.tripID, spanning.tripID])
        #expect(found([y2024, spanning, y2023], "show me my 2024 trips") == [y2024.tripID, spanning.tripID])
    }

    @Test("the resolver runs off the main actor")
    func resolverIsNonisolated() async {
        let trips = [trip("Paris", month: 6), trip("Rome", month: 12)]
        let index = TripSearchIndex(documents: trips)
        let now = date(2026, 7, 14)
        let calendar = utcCal
        let detached = await Task.detached {
            TripQueryParser.searchTrips(
                index: index, query: "summer", allowsTrailingPartial: false,
                now: now, calendar: calendar, languageTag: "en")
        }.value
        #expect(detached.map(\.documentIndex) == [0])
    }

    @Test("a bare season or month is not hijacked by a title")
    func titlesDoNotHijackDateWords() {
        let japan = trip("Tokyo", month: 4, title: "Japan in Spring", countries: ["JP"])
        let parisApril = trip("Paris", month: 4)
        let romeJuly = trip("Rome", month: 7)
        #expect(found([japan, parisApril, romeJuly], "spring") == [japan.tripID, parisApril.tripID])

        let prague = trip("Prague", month: 3, title: "Prague in December")
        let berlin = trip("Berlin", month: 12)
        let oslo = trip("Oslo", month: 7)
        #expect(found([prague, berlin, oslo], "december") == [prague.tripID, berlin.tripID])
    }

    @Test("trips to Winter Park returns only Winter Park")
    func winterParkIsAPlace() {
        let winterPark = trip("Winter Park", month: 7)
        let oslo = trip("Oslo", month: 12)
        let chamonix = trip("Chamonix", month: 1)
        #expect(found([winterPark, oslo, chamonix], "trips to Winter Park") == [winterPark.tripID])
        // With no Winter Park trip, the season reading returns the winter trips.
        #expect(found([oslo, chamonix], "winter") == [oslo.tripID, chamonix.tripID])
    }

    @Test("cold and warm normalization memos give the same result")
    func memoParity() {
        let trips = [trip("Μύκονος", month: 7, countries: ["GR"]), trip("Tromsø", month: 1), trip("Paris", month: 7)]
        let query = "tromso trips"
        let warm = search(trips, query)
        TripSearch.normalizedFormsCache.withLock { $0.removeAll() }
        let cold = search(trips, query)
        #expect(cold == warm)
        #expect(cold.map(\.documentIndex) == [1])
    }

    // MARK: - Acceptance: partial fallback

    @Test("words that no single trip matches return each trip as partial")
    func partialPlaces() {
        let paris = trip("Paris", month: 3)
        let london = trip("London", month: 5, dayShift: 119)
        let rome = trip("Rome", month: 6)
        let matches = search([paris, london, rome], "paris london")
        #expect(matches.map(\.documentIndex) == [0, 1])
        #expect(matches.allSatisfy { $0.strength == .partial })
    }

    @Test("a place with a year that never happened drops the year, not the place")
    func partialDropsYear() {
        let paxos = trip("Paxos", year: 2023, month: 6)
        let paris2024 = trip("Paris", year: 2024, month: 6)
        let matches = search([paxos, paris2024], "paxos 2024")
        #expect(matches.map(\.documentIndex) == [0])
        #expect(matches.first?.strength == .partial)
    }

    @Test("the partial fallback keeps the trips matching the most words")
    func partialKeepsBestCount() {
        let paris = trip("Paris", month: 3, title: "Paris and Rome")
        let rome = trip("Rome", month: 5)
        let lima = trip("Lima", month: 6)
        let matches = search([paris, rome, lima], "paris rome lima")
        #expect(matches.map(\.documentIndex) == [0])
        #expect(matches.first?.strength == .partial)
    }

    @Test("the partial fallback caps at eight words")
    func partialFallbackCap() {
        let names = ["Paris", "London", "Rome", "Berlin", "Madrid", "Lisbon", "Vienna", "Prague", "Oslo"]
        let trips = names.enumerated().map {
            trip($0.element, month: $0.offset + 1,
                 dayShift: [1, 3, 4, 6, 8].contains($0.offset) ? 119 : 0)
        }
        let eight = search(trips, names.prefix(8).joined(separator: " "))
        #expect(eight.map(\.documentIndex) == Array(0..<8))
        #expect(eight.allSatisfy { $0.strength == .partial })
        #expect(search(trips, names.joined(separator: " ")).isEmpty)
    }

    @Test("empty, whitespace and symbol-only queries return nothing")
    func emptyAndZeroTermQueries() {
        let trips = [trip("Paris", month: 1), trip("Rome", month: 11)]
        for query in ["", "   ", "🏖️", "+", "🇬🇷"] {
            #expect(search(trips, query).isEmpty, "\(query)")
            #expect(search(trips, query, typing: true).isEmpty, "\(query)")
        }
        #expect(search([], "paris").isEmpty)
        // No terms, but a structured filter: that filter still applies.
        #expect(found(trips, "１月", languageTag: "ja") == [trips[0].tripID])
    }

    // MARK: - Acceptance: localized parsing

    @Test("a localized bare month finds that month only")
    func localizedMonths() {
        let julyDE = trip("Berlin", month: 7, languageTag: "de")
        let juneDE = trip("München", month: 6, languageTag: "de")
        #expect(parse("Juli", languageTag: "de").months == [7])
        #expect(found([julyDE, juneDE], "Juli", languageTag: "de") == [julyDE.tripID])

        let julyEL = trip("Αθήνα", month: 7, languageTag: "el")
        let juneEL = trip("Κρήτη", month: 6, languageTag: "el")
        #expect(parse("Ιούλιος", languageTag: "el").months == [7])
        #expect(found([julyEL, juneEL], "Ιούλιος", languageTag: "el") == [julyEL.tripID])
        #expect(found([julyEL, juneEL], "Ιουλίου", languageTag: "el") == [julyEL.tripID])
    }

    @Test(
        "A27: localized season plus year",
        arguments: [
            ("καλοκαίρι 2024", "el"), ("Sommer 2024", "de"), ("été 2024", "fr"),
            ("verano de 2024", "es"), ("zomer 2024", "nl"), ("2024 yazı", "tr"),
            ("mùa hè năm 2024", "vi"), ("2024年夏", "zh-Hans"), ("2024년 여름", "ko"),
            ("kalokairi 2024", "el"), ("καλοκαίρι του 2024", "el"), ("hè 2024", "vi"),
            ("2024 yazında", "tr"),
        ]
    )
    func localizedSeasonWithYear(query: String, languageTag: String) {
        let p = parse(query, languageTag: languageTag)
        #expect(p.months == [6, 7, 8], "\(query)")
        #expect(p.years == [2024], "\(query)")
        #expect(p.placeTerms.isEmpty, "\(query)")
        #expect(p.placeInterpretation == nil, "\(query)")
    }

    @Test("numeric CJK and Vietnamese months never read as 11 or 12")
    func numericMonths() {
        func corpus(_ tag: String) -> [TripSearchDocument] {
            [
                trip("A", year: 2024, month: 1, languageTag: tag),
                trip("B", year: 2024, month: 11, languageTag: tag),
                trip("C", year: 2025, month: 1, languageTag: tag),
                trip("D", year: 2024, month: 10, languageTag: tag),
                trip("E", year: 2024, month: 12, languageTag: tag),
            ]
        }
        let cases: [(query: String, tag: String, expected: [Int])] = [
            ("1月", "ja", [0, 2]), ("tháng 1", "vi", [0, 2]), ("thg 1", "vi", [0, 2]),
            ("1월", "ko", [0, 2]), ("1월에", "ko", [0, 2]), ("一月", "zh-Hans", [0, 2]),
            ("十一月", "zh-Hans", [1]), ("十二月", "zh-Hans", [4]), ("11月", "ja", [1]),
            ("2024年1月", "ja", [0]), ("2024년 1월", "ko", [0]), ("tháng 12", "vi", [4]),
            ("２０２４年", "zh-Hant", [0, 1, 3, 4]),
        ]
        for (query, tag, expected) in cases {
            let trips = corpus(tag)
            #expect(search(trips, query, languageTag: tag).map(\.documentIndex) == expected, "\(tag) \(query)")
        }
        #expect(parse("２０２４").years == [2024])
        #expect(parse("tháng 1", languageTag: "vi").months == [1])
        #expect(parse("tháng 1", languageTag: "vi").placeTerms.isEmpty)
        // A year connector before a bare year is noise, not a place word.
        #expect(parse("năm 2024", languageTag: "vi").placeTerms.isEmpty)
        #expect(parse("năm 2024", languageTag: "vi").years == [2024])
    }

    @Test("localized relative dates and anchored seasons")
    func localizedRelativeDates() {
        #expect(parse("πέρσι", languageTag: "el").years == [2025])
        #expect(parse("φέτος", languageTag: "el").years == [2026])
        #expect(parse("letztes Jahr", languageTag: "de").years == [2025])
        #expect(parse("去年", languageTag: "ja").years == [2025])
        #expect(parse("작년", languageTag: "ko").years == [2025])

        for (query, tag) in [
            ("letzten Sommer", "de"), ("l'été dernier", "fr"), ("el verano pasado", "es"),
            ("το περασμένο καλοκαίρι", "el"), ("지난 여름", "ko"), ("vorige zomer", "nl"),
        ] {
            let p = parse(query, languageTag: tag)
            #expect(p.months == [6, 7, 8], "\(query)")
            #expect(p.years == [2025], "\(query)")
            #expect(p.placeInterpretation == nil, "\(query)")
        }

        let inSummer = parse("im Sommer", languageTag: "de")
        #expect(inSummer.anchoredMonths == [6, 7, 8])
        #expect(inSummer.years.isEmpty)
        #expect(inSummer.placeInterpretation == nil)

        let thisSummer = parse("この夏", languageTag: "ja")
        #expect(thisSummer.months == [6, 7, 8])
        #expect(thisSummer.years == [2026])

        let recent = parse("i somras", languageTag: "sv")
        #expect(recent.months == [6, 7, 8])
        #expect(recent.years == [2025])
    }

    @Test("localized weekend words and filler")
    func localizedWeekendAndFiller() {
        for (query, tag) in [("Wochenende", "de"), ("week-end", "fr"), ("fin de semana", "es"), ("週末", "ja"), ("Σαββατοκύριακο", "el")] {
            let p = parse(query, languageTag: tag)
            #expect(p.minDurationDays == 2, "\(query)")
            #expect(p.maxDurationDays == 3, "\(query)")
            #expect(p.placeTerms.isEmpty, "\(query)")
        }
        let reise = parse("Reise nach Paris", languageTag: "de")
        #expect(raws(reise.placeTerms) == ["paris"])
        #expect(reise.droppedNoise)
        #expect(raws(parse("ταξίδι στην Αθήνα", languageTag: "el").placeTerms) == ["αθηνα"])
        #expect(raws(parse("Roma'da", languageTag: "tr").placeTerms) == ["roma"])
        // Greek filler matches only its native form: Kai is a city.
        #expect(raws(parse("kai", languageTag: "el").placeTerms) == ["kai"])
    }

    @Test("place-first cascade for date words that are also place names")
    func localizedDateWordsThatArePlaces() {
        let rio = trip("Rio de Janeiro", month: 3, languageTag: "pt-BR")
        let lisbon = trip("Lisboa", month: 1, languageTag: "pt-BR")
        #expect(found([rio, lisbon], "rio de janeiro", languageTag: "pt-BR") == [rio.tripID])
        // Bare, the month word still prefers the place, like `winter` and Winter Park.
        #expect(found([rio, lisbon], "janeiro", languageTag: "pt-BR") == [rio.tripID])
        #expect(found([lisbon], "janeiro", languageTag: "pt-BR") == [lisbon.tripID])

        let chiangMai = trip("Chiang Mai", month: 2, languageTag: "de")
        let mayTrip = trip("Wien", month: 5, languageTag: "de")
        #expect(found([chiangMai, mayTrip], "Chiang Mai", languageTag: "de") == [chiangMai.tripID])

        let laPaz = trip("La Paz", month: 4, languageTag: "es")
        let paz = trip("Paz", month: 6, languageTag: "es")
        #expect(found([laPaz, paz], "la paz", languageTag: "es") == [laPaz.tripID])

        let varas = trip("Puerto Varas", year: 2025, month: 11, languageTag: "sv")
        let spring = trip("Oslo", year: 2026, month: 4, languageTag: "sv")
        #expect(found([varas, spring], "puerto varas", languageTag: "sv") == [varas.tripID])

        // 夏 inside 夏威夷 (Hawaii) is not a season; 春 in 東京の春 is.
        #expect(parse("夏威夷", languageTag: "zh-Hans").months.isEmpty)
        #expect(parse("東京の春", languageTag: "ja").months == [3, 4, 5])
        let tokyoSpring = trip("東京", month: 10, title: "東京の春", languageTag: "ja")
        let osaka = trip("大阪", month: 7, languageTag: "ja")
        #expect(found([tokyoSpring, osaka], "東京の春", languageTag: "ja") == [tokyoSpring.tripID])
        #expect(found([tokyoSpring, osaka], "春", languageTag: "ja") == [tokyoSpring.tripID])
    }

    // MARK: - Typing

    @Test("a typed prefix of a season completes to it unless a place starts with it")
    func trailingCompletion() {
        let parisJune = trip("Paris", month: 6)
        let romeDecember = trip("Rome", month: 12)
        let base = [parisJune, romeDecember]
        #expect(found(base, "summ", typing: true) == found(base, "summer"))
        #expect(found(base, "summ", typing: true) == [parisJune.tripID])
        #expect(found(base, "wint", typing: true) == [romeDecember.tripID])
        #expect(found(base, "summ").isEmpty)

        let summerland = trip("Summerland", month: 10)
        #expect(found(base + [summerland], "summ", typing: true) == [summerland.tripID])

        let lastSumm = search([trip("Oslo", year: 2025, month: 7), trip("Oslo", year: 2026, month: 7)], "last summ", typing: true)
        #expect(lastSumm.map(\.documentIndex) == [0])

        // A finished word (separator typed) never completes.
        #expect(found(base, "summ ", typing: true).isEmpty)
    }

    @Test("Siri-style full sentences pass allowsTrailingPartial false")
    func fullSentences() {
        let paris = trip("Paris", month: 6)
        let parisDecember = trip("Paris", month: 12)
        let tokyo = trip("Tokyo", month: 4)
        let all = [paris, parisDecember, tokyo]
        #expect(found(all, "show me my trips to tokyo") == [tokyo.tripID])

        let typed = search(all, "paris summ", typing: true)
        #expect(typed.map(\.documentIndex) == [0])
        #expect(typed.first?.strength == .strong)
        let spoken = search(all, "paris summ")
        #expect(spoken.map(\.documentIndex) == [0, 1])
        #expect(spoken.allSatisfy { $0.strength == .partial })

        // A trailing filler word that starts a place is kept while typing.
        #expect(found(all, "trips to", typing: true) == [tokyo.tripID])
        #expect(found(all, "trips to").isEmpty)
    }

    @Test("the trailing flag comes from the original query, not the residual words")
    func trailingFlagFromOriginalQuery() {
        let barcelona = trip("Barcelona", month: 5, dayShift: 119)
        let paris = trip("Paris", month: 6)
        for prefix in ["barc", "barcl", "barcle", "barcleo", "barcleon"] {
            #expect(found([barcelona, paris], "trips to \(prefix)", typing: true) == [barcelona.tripID], "\(prefix)")
        }
        #expect(found([barcelona, paris], "trips to barcl ", typing: true).isEmpty)

        // `barcl` is the typed word only when nothing follows it.
        let barcelona2024 = trip("Barcelona", year: 2024, month: 5)
        #expect(found([barcelona2024, paris], "2024 barcl", typing: true) == [barcelona2024.tripID])
        #expect(found([barcelona2024, paris], "barcl 2024", typing: true).isEmpty)
    }

    // MARK: - Durations while typing

    @Test("a trailing duration unit is never completed to weekend")
    func typedDurationUnitParity() {
        let names = ["Paris", "Berlin", "Lisbon", "Oslo", "Tokyo"]
        let days = [3, 5, 7, 10, 14]
        let trips = zip(names, days).enumerated().map {
            trip($0.element.0, month: $0.offset + 1, durationDays: $0.element.1,
                 dayShift: [1, 3].contains($0.offset) ? 119 : 0)
        }
        let ids = trips.map(\.tripID)
        let cases: [(String, [UUID])] = [
            ("a week", [ids[2]]), ("1 week", [ids[2]]), ("one week", [ids[2]]),
            ("trips over a week", [ids[3], ids[4]]), ("more than a week", [ids[3], ids[4]]),
            ("trips under a week", [ids[0], ids[1]]),
        ]
        for (query, expected) in cases {
            #expect(found(trips, query) == expected, "\(query)")
            #expect(found(trips, query, typing: true) == expected, "typing \(query)")
        }
        #expect(found(trips, "a weeke", typing: true) == [ids[0]])
    }

    @Test("a German or Dutch week noun, or a unit prefix after a count, is never completed to weekend")
    func typedWeekNounParity() {
        for languageTag in ["de", "nl"] {
            let trips = [
                trip("Paris", month: 3, durationDays: 3, languageTag: languageTag),
                trip("Rom", month: 5, durationDays: 7, languageTag: languageTag),
            ]
            for query in ["eine Woche", "eine Woch", "ein Woche", "een week", "een wee", "twee weken"] {
                #expect(
                    search(trips, query, typing: true, languageTag: languageTag)
                        == search(trips, query, languageTag: languageTag),
                    "\(languageTag) \(query)")
            }
        }
        let german = [trip("Paris", month: 3, durationDays: 3, languageTag: "de")]
        #expect(found(german, "eine Woche", typing: true, languageTag: "de").isEmpty)
        // A bare prefix still completes, like `weeke`.
        #expect(found(german, "Woch", typing: true, languageTag: "de") == [german[0].tripID])
        #expect(found(german, "Wochene", typing: true, languageTag: "de") == [german[0].tripID])
    }

    // MARK: - Dates spanning a boundary

    @Test("a month plus year keeps the trip that spans into that month")
    func monthYearKeepsSpanningTrip() {
        // Ends 8 January 2024; mid-month ends keep the fixture zone-independent.
        let newYear = trip("Vienna", year: 2023, month: 12, day: 20, durationDays: 20)
        let tromso = trip("Tromso", year: 2024, month: 1)
        let december = trip("Paris", year: 2023, month: 12, day: 2, durationDays: 5)
        let all = [newYear, tromso, december]
        for query in ["january 2024", "jan 2024", "2024 january", "in january 2024"] {
            #expect(found(all, query) == [newYear.tripID, tromso.tripID], "\(query)")
        }
        #expect(found(all, "december 2023") == [newYear.tripID, december.tripID])

        let tokyoSpring = trip("Tokyo", year: 2024, month: 3, day: 25, durationDays: 12)
        let tokyoMay = trip("Tokyo", year: 2024, month: 5)
        let tokyo = search([tokyoSpring, tokyoMay], "tokyo in april")
        #expect(tokyo.map(\.documentIndex) == [0])
        #expect(tokyo.first?.strength == .strong)
    }

    // MARK: - Typing and filler

    @Test("a typed filler that only finds partial matches yields to the finished words")
    func typedFillerYieldsToFinishedReading() {
        let rome = trip("Rome", month: 3)
        let india = trip("India", month: 5)
        let warsaw = trip("Warsaw", month: 6)
        let all = [rome, india, warsaw]
        let typed = search(all, "rome in", typing: true)
        #expect(typed.map { all[$0.documentIndex].tripID } == [rome.tripID])
        #expect(typed.allSatisfy { $0.strength == .strong })
        #expect(found(all, "rome in ", typing: true) == [rome.tripID])
        // A filler that alone starts a place still reads as that place.
        #expect(found(all, "war", typing: true, languageTag: "de") == [warsaw.tripID])
    }

    @Test("a typed filler that also matches a title word does not narrow the finished reading")
    func typedFillerTitleWordYieldsToFinishedReading() {
        let all = [
            trip("Kyoto", month: 10, title: "Autumn in Kyoto", countries: ["JP"]),
            trip("Osaka", month: 4, countries: ["JP"]),
            trip("India", month: 2, countries: ["IN"]),
            trip("Lisbon", month: 5, durationDays: 3, title: "Weekend in Lisbon"),
            trip("Porto", month: 6, durationDays: 2),
            trip("Crete", month: 8, durationDays: 7, title: "A week in Crete"),
            trip("Oslo", month: 9, durationDays: 7, dayShift: 119),
        ]
        let expected: [(String, [Int])] = [
            ("japan in", [0, 1]), ("weekend in", [3, 4]), ("weekend i", [3, 4]),
            ("a week in", [5, 6]), ("a week i", [5, 6]),
        ]
        for (query, indices) in expected {
            let finished = search(all, query)
            #expect(finished.map(\.documentIndex) == indices, "\(query)")
            #expect(finished.allSatisfy { $0.strength == .strong }, "\(query)")
            #expect(search(all, query, typing: true) == finished, "typing \(query)")
        }
    }

    @Test("an English possessive strips to its word")
    func englishPossessive() {
        let romeMarch = trip("Rome", year: 2016, month: 3)
        let romeSeptember = trip("Rome", year: 2025, month: 9)
        let tokyo = trip("Tokyo", month: 5)
        let all = [romeMarch, romeSeptember, tokyo]
        for query in ["rome's", "rome’s", "Rome's trips"] {
            #expect(found(all, query) == [romeMarch.tripID, romeSeptember.tripID], "\(query)")
        }
        #expect(raws(parse("rome's").placeTerms) == ["rome"])
        let bosch = trip("'s-Hertogenbosch", month: 6)
        #expect(found(all + [bosch], "'s-Hertogenbosch") == [bosch.tripID])
    }

    // MARK: - Localized forms

    @Test("French `en` before a country is filler, not an England prefix")
    func frenchEnIsFiller() {
        let rome = trip("Rome", year: 2023, month: 5, countries: ["IT"], languageTag: "fr")
        let milan = trip("Milan", year: 2024, month: 9, countries: ["IT"], languageTag: "fr")
        let london = trip("Londres", month: 3, title: "England", countries: ["GB"], languageTag: "fr")
        let all = [rome, milan, london]
        #expect(raws(parse("voyage en Italie", languageTag: "fr").placeTerms) == ["italie"])
        let matches = search(all, "voyage en Italie", languageTag: "fr")
        #expect(matches.map { all[$0.documentIndex].tripID } == [rome.tripID, milan.tripID])
        #expect(matches.allSatisfy { $0.strength == .strong })
        #expect(found(all, "voyage en Italie 2023", languageTag: "fr") == [rome.tripID])
    }

    @Test("French `ai été` is have been, not summer")
    func frenchHaveBeen() {
        let romeJuly = trip("Rome", year: 2024, month: 7, languageTag: "fr")
        let romeMarch = trip("Rome", year: 2024, month: 3, languageTag: "fr")
        let romeNovember = trip("Rome", year: 2023, month: 11, languageTag: "fr")
        let parisJuly = trip("Paris", year: 2024, month: 7, languageTag: "fr")
        let all = [romeJuly, romeMarch, romeNovember, parisJuly]
        for query in ["j'ai été à Rome", "on a été à Rome", "nous avons été à Rome"] {
            let matches = search(all, query, languageTag: "fr")
            #expect(
                matches.map { all[$0.documentIndex].tripID } == [romeJuly.tripID, romeMarch.tripID, romeNovember.tripID],
                "\(query)")
            #expect(matches.allSatisfy { $0.strength == .strong }, "\(query)")
            #expect(parse(query, languageTag: "fr").months.isEmpty, "\(query)")
        }
        #expect(found(all, "été 2024", languageTag: "fr") == [romeJuly.tripID, parisJuly.tripID])
        #expect(found(all, "Rome été", languageTag: "fr") == [romeJuly.tripID])
    }

    @Test(
        "a last frame after an in-frame word still anchors the season",
        arguments: [
            ("pendant l'été dernier", "fr"), ("durant l'été dernier", "fr"), ("pendant le printemps dernier", "fr"),
            ("nell'estate scorsa", "it"), ("durante l'estate scorsa", "it"), ("en el verano pasado", "es"),
            ("en la primavera pasada", "es"), ("durante o verão passado", "pt-BR"),
        ]
    )
    func lastFrameBeatsInFrame(query: String, languageTag: String) {
        let p = parse(query, languageTag: languageTag)
        #expect(!p.months.isEmpty, "\(query)")
        #expect(p.months == p.anchoredMonths, "\(query)")
        #expect(p.years == [p.months.contains(7) ? 2025 : 2026], "\(query)")
        #expect(p.placeTerms.isEmpty, "\(query)")
    }

    @Test("an in-frame alone still anchors months without a year")
    func inFrameAloneUnchanged() {
        for (query, tag) in [("en été", "fr"), ("in estate", "it"), ("no verão", "pt-BR"), ("το καλοκαίρι", "el")] {
            let p = parse(query, languageTag: tag)
            #expect(p.anchoredMonths == [6, 7, 8], "\(query)")
            #expect(p.years.isEmpty, "\(query)")
            #expect(p.placeTerms.isEmpty, "\(query)")
        }
    }

    @Test("frames take numeric months")
    func framesTakeNumericMonths() {
        let cases: [(String, String, Int)] = [
            ("지난 7월", "ko", 2025), ("이번 7월", "ko", 2026), ("tháng 7 này", "vi", 2026),
            ("tháng 7 vừa rồi", "vi", 2025), ("この7月", "ja", 2026), ("这个7月", "zh-Hans", 2026),
        ]
        for (query, tag, year) in cases {
            let p = parse(query, languageTag: tag)
            #expect(p.months == [7], "\(query)")
            #expect(p.years == [year], "\(query)")
            #expect(p.placeTerms.isEmpty, "\(query)")
        }
        #expect(parse("7월", languageTag: "ko").years.isEmpty)
        #expect(parse("작년 7월", languageTag: "ko").years == [2025])
    }

    @Test("Chinese and Korean month, season and weekend forms")
    func cjkForms() {
        for (query, tag) in [("7月份", "zh-Hans"), ("七月份", "zh-Hans"), ("7月份", "zh-Hant")] {
            let p = parse(query, languageTag: tag)
            #expect(p.months == [7], "\(query)")
            #expect(p.placeTerms.isEmpty, "\(query)")
        }
        #expect(parse("去年7月份", languageTag: "zh-Hans").years == [2025])

        for (query, tag) in [("上个夏天", "zh-Hans"), ("上個夏天", "zh-Hant")] {
            let p = parse(query, languageTag: tag)
            #expect(p.months == [6, 7, 8], "\(query)")
            #expect(p.years == [2025], "\(query)")
            #expect(p.placeTerms.isEmpty, "\(query)")
        }
        for query in ["夏天的时候", "夏天去过哪里"] {
            let p = parse(query, languageTag: "zh-Hans")
            #expect(p.months == [6, 7, 8], "\(query)")
            #expect(p.placeTerms.isEmpty, "\(query)")
        }

        let lastMonth = parse("지난달에", languageTag: "ko")
        #expect(lastMonth.months == [6])
        #expect(lastMonth.years == [2026])
        #expect(lastMonth.placeTerms.isEmpty)
        for (query, months) in [("여름여행", [6, 7, 8]), ("겨울여행", [12, 1, 2])] as [(String, Set<Int>)] {
            let p = parse(query, languageTag: "ko")
            #expect(p.months == months, "\(query)")
            #expect(p.placeTerms.isEmpty, "\(query)")
        }
        let weekend = parse("주말여행", languageTag: "ko")
        #expect(weekend.minDurationDays == 2)
        #expect(weekend.maxDurationDays == 3)
        #expect(weekend.placeTerms.isEmpty)
    }

    @Test("Turkish locative season possessives and `ayı` month frames")
    func turkishForms() {
        let romaJuly = trip("Roma", year: 2024, month: 7, languageTag: "tr")
        let romaMarch = trip("Roma", year: 2024, month: 3, languageTag: "tr")
        let matches = search([romaJuly, romaMarch], "2024 yazında Roma", languageTag: "tr")
        #expect(matches.map(\.documentIndex) == [0])
        #expect(matches.first?.strength == .strong)

        let winter = parse("2024 kışında", languageTag: "tr")
        #expect(winter.months == [12, 1, 2])
        #expect(winter.years == [2024])
        #expect(winter.placeTerms.isEmpty)
        let july = parse("Temmuz ayı", languageTag: "tr")
        #expect(july.months == [7])
        #expect(july.placeTerms.isEmpty)
        // Anchor-only: alone it is no season.
        #expect(parse("yazında", languageTag: "tr").months.isEmpty)
    }

    @Test("Turkish `geçen` and `bu` frames combine with `ayında` and `ayı`")
    func turkishCombinedMonthFrames() {
        let now = date(2026, 9, 26)
        let roma = trip("Roma", year: 2025, month: 7, languageTag: "tr")
        let antalya = trip("Antalya", year: 2026, month: 7, countries: ["TR"], languageTag: "tr")
        let all = [roma, antalya]
        for query in [
            "geçen Temmuz ayında", "geçtiğimiz Temmuz ayında", "geçen Temmuz ayı",
            "bu Temmuz ayında", "bu Temmuz ayı", "geçen Temmuz ayında Antalya",
        ] {
            let parsed = parse(query, now: now, languageTag: "tr")
            #expect(parsed.years == [2026], "\(query)")
            #expect(parsed.months == [7], "\(query)")
            #expect(raws(parsed.placeTerms).allSatisfy { $0 == "antalya" }, "\(query)")
            let matches = search(all, query, now: now, languageTag: "tr")
            #expect(matches.map(\.documentIndex) == [1], "\(query)")
            #expect(matches.allSatisfy { $0.strength == .strong }, "\(query)")
        }
        // The single frames are unchanged.
        #expect(found(all, "geçen Temmuz", now: now, languageTag: "tr") == [antalya.tripID])
        #expect(found(all, "Temmuz ayında", now: now, languageTag: "tr") == [roma.tripID, antalya.tripID])
        #expect(found(all, "geçen yaz", now: now, languageTag: "tr") == [antalya.tripID])
    }

    @Test("Vietnamese bare `hè` is summer; the other bare syllables stay places")
    func vietnameseSummer() {
        for query in ["nghỉ hè", "kỳ nghỉ hè"] {
            let p = parse(query, languageTag: "vi")
            #expect(p.months == [6, 7, 8], "\(query)")
            #expect(p.placeTerms.isEmpty, "\(query)")
        }
        let lastSummer = parse("hè năm ngoái", languageTag: "vi")
        #expect(lastSummer.months == [6, 7, 8])
        #expect(lastSummer.years == [2025])
        #expect(parse("Hạ Long", languageTag: "vi").months.isEmpty)

        let daNangJuly = trip("Đà Nẵng", year: 2024, month: 7, languageTag: "vi")
        let daNangMarch = trip("Đà Nẵng", year: 2024, month: 3, languageTag: "vi")
        let matches = search([daNangJuly, daNangMarch], "đi Đà Nẵng hè 2024", languageTag: "vi")
        #expect(matches.map(\.documentIndex) == [0])
        #expect(matches.first?.strength == .strong)
    }

    @Test("Greek colloquial frames, verbs, trip nouns and the ΣΚ abbreviation")
    func greekForms() {
        let thisWinter = parse("αυτό τον χειμώνα", languageTag: "el")
        #expect(thisWinter.months == [12, 1, 2])
        #expect(thisWinter.years == [2026])
        #expect(thisWinter.placeTerms.isEmpty)
        let previous = parse("προηγούμενο καλοκαίρι", languageTag: "el")
        #expect(previous.months == [6, 7, 8])
        #expect(previous.years == [2025])
        #expect(previous.placeTerms.isEmpty)
        #expect(raws(parse("ήμουν στο Παρίσι", languageTag: "el").placeTerms) == ["παρισι"])
        let short = parse("τριήμερο Βιέννη", languageTag: "el")
        #expect(raws(short.placeTerms) == ["βιεννη"])
        #expect(short.droppedNoise)
        for query in ["ΣΚ στη Βιέννη", "Σ/Κ Βιέννη"] {
            let p = parse(query, languageTag: "el")
            #expect(p.minDurationDays == 2, "\(query)")
            #expect(p.maxDurationDays == 3, "\(query)")
            #expect(raws(p.placeTerms) == ["βιεννη"], "\(query)")
        }
    }

    @Test("German `dieses Jahres` and travel verbs; `bin` stays place-first")
    func germanForms() {
        let thisYear = parse("Reisen dieses Jahres", languageTag: "de")
        #expect(thisYear.years == [2026])
        #expect(thisYear.placeTerms.isEmpty)

        let rom = trip("Rom", year: 2024, month: 7, languageTag: "de")
        let binZayed = trip("Mohammed Bin Zayed City", year: 2025, month: 3, languageTag: "de")
        for query in ["wo bin ich 2024 gewesen", "wohin bin ich 2024 gereist"] {
            let matches = search([rom, binZayed], query, languageTag: "de")
            #expect(matches.map(\.documentIndex) == [0], "\(query)")
            #expect(matches.first?.strength == .strong, "\(query)")
        }
        #expect(found([rom, binZayed], "Bin Zayed", languageTag: "de") == [binZayed.tripID])
    }

    @Test("Danish, Norwegian, Dutch, Italian and Spanish everyday forms")
    func europeanForms() {
        for (query, months) in [("i sommers", [6, 7, 8]), ("i vinters", [12, 1, 2])] as [(String, Set<Int>)] {
            let p = parse(query, languageTag: "da")
            #expect(p.months == months, "\(query)")
            #expect(p.years == [2025], "\(query)")
        }
        for (query, tag) in [("helga", "nb"), ("weekendje weg", "nl"), ("finesettimana", "it")] {
            let p = parse(query, languageTag: tag)
            #expect(p.minDurationDays == 2, "\(query)")
            #expect(p.maxDurationDays == 3, "\(query)")
            #expect(p.placeTerms.isEmpty, "\(query)")
        }
        let weekEnd = parse("week-end a Roma", languageTag: "it")
        #expect(weekEnd.minDurationDays == 2)
        #expect(raws(weekEnd.placeTerms) == ["roma"])
        #expect(raws(parse("citytrip Parijs", languageTag: "nl").placeTerms) == ["parijs"])
        #expect(raws(parse("ho visitato Roma", languageTag: "it").placeTerms) == ["roma"])
        #expect(raws(parse("he estado en Roma", languageTag: "es").placeTerms) == ["roma"])
    }

    // MARK: - Prewarm

    @Test("prewarm builds the parser off the main actor and parsing stays stable across tasks")
    func prewarmOffMain() async {
        await Task.detached { TripQueryParser.prewarm(languageTag: "ja") }.value
        let now = date(2026, 7, 14)
        let calendar = utcCal
        let results = await withTaskGroup(of: TripQueryParser.ParsedQuery.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    TripQueryParser.parse("2024年1月 10+ days", now: now, calendar: calendar, languageTag: "ja")
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == 8)
        for parsed in results {
            #expect(parsed.months == [1])
            #expect(parsed.years == [2024])
            #expect(parsed.minDurationDays == 10)
        }
    }
}
