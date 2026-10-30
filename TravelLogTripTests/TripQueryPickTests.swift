//
//  TripQueryPickTests.swift
//  TravelLogTripTests
//
//  Queries that pick trips (`TripQueryParser.Ordinal`): nth ordinals and
//  "last time in X" in several languages, "last" against "previous",
//  superlatives ("longest", "farthest", "most countries"), and the kinds
//  around flights: via places ranked strong, connecting flights and trips
//  without a flight. Invented places and trips, UTC.
//

import Foundation
import Testing
@testable import TravelLog

struct TripQueryPickTests {

    private var utcCal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private var now: Date { date(2026, 7, 14) }

    private func date(_ y: Int, _ m: Int, _ d: Int = 10) -> Date {
        utcCal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func parse(_ q: String, languageTag: String = "en") -> TripQueryParser.ParsedQuery {
        TripQueryParser.parse(q, now: now, calendar: utcCal, languageTag: languageTag)
    }

    // MARK: - Parsing

    @Test(
        "nth ordinals and time words in every script",
        arguments: [
            ("3rd trip to Valdoria", "en", TripQueryParser.Ordinal.nth(3)), ("third trip to Valdoria", "en", .nth(3)),
            ("my 2nd trip", "en", .nth(2)), ("last time in Valdoria", "en", .previous),
            ("first time in Valdoria", "en", .first), ("most recent trip", "en", .last),
            ("previous trip", "en", .previous), ("dritte Reise nach Valdoria", "de", .nth(3)),
            ("3. Reise nach Valdoria", "de", .nth(3)), ("letztes Mal in Valdoria", "de", .previous),
            ("zum ersten Mal in Valdoria", "de", .first), ("tercer viaje a Valdoria", "es", .nth(3)),
            ("última vez en Valdoria", "es", .previous), ("la dernière fois à Valdoria", "fr", .previous),
            ("3e voyage à Valdoria", "fr", .nth(3)), ("terzo viaggio a Valdoria", "it", .nth(3)),
            ("derde reis naar Valdoria", "nl", .nth(3)), ("tredje resan till Valdoria", "sv", .nth(3)),
            ("üçüncü gezi", "tr", .nth(3)), ("τρίτο ταξίδι", "el", .nth(3)), ("chuyến đi thứ ba", "vi", .nth(3)),
            ("lần cuối cùng", "vi", .previous), ("세 번째 여행", "ko", .nth(3)), ("3번째 여행", "ko", .nth(3)),
            ("3回目のヴァルドリア", "ja", .nth(3)), ("二度目のヴァルドリア", "ja", .nth(2)),
            ("3番目の旅行", "ja", .nth(3)), ("初めてのヴァルドリア", "ja", .first),
            ("最後のヴァルドリア", "ja", .last), ("前回のヴァルドリア", "ja", .previous),
            ("第三次去瓦尔多", "zh-Hans", .nth(3)),
        ] as [(String, String, TripQueryParser.Ordinal)]
    )
    func ordinals(query: String, languageTag: String, ordinal: TripQueryParser.Ordinal) {
        let p = parse(query, languageTag: languageTag)
        #expect(p.ordinal == ordinal, "\(query)")
        #expect(p.placeTerms.allSatisfy { !["time", "mal", "vez", "fois", "3rd", "3e", "2nd"].contains($0.raw) }, "\(query)")
    }

    @Test("an ordinal needs a trip noun or a time word next to it, with no count or other word between")
    func notOrdinals() {
        #expect(parse("Second Beach").ordinal == nil)
        #expect(parse("first").ordinal == nil)
        #expect(parse("3rd").ordinal == nil)
        #expect(parse("last summer").ordinal == nil)
        #expect(parse("last-minute trip").ordinal == nil)
        #expect(parse("last minute trip").ordinal == nil)
        #expect(parse("last 3 trips").ordinal == nil)
        #expect(parse("my first two trips to Valdoria").ordinal == nil)
        #expect(parse("3. Mai", languageTag: "de").ordinal == nil)
    }

    @Test(
        "superlatives with or without a trip noun",
        arguments: [
            ("longest trip", "en", TripQueryParser.Ordinal.longest), ("shortest", "en", .shortest),
            ("farthest trip", "en", .farthest), ("trip with the most countries", "en", .mostCountries),
            ("längste Reise", "de", .longest), ("weiteste Reise", "de", .farthest),
            ("viaje más largo", "es", .longest), ("el viaje más lejano", "es", .farthest),
            ("le voyage le plus long", "fr", .longest), ("langste reis", "nl", .longest),
            ("en uzun gezi", "tr", .longest), ("一番長い旅行", "ja", .longest), ("最長の旅行", "ja", .longest),
            ("一番遠い旅行", "ja", .farthest), ("가장 긴 여행", "ko", .longest), ("最远的旅行", "zh-Hans", .farthest),
        ] as [(String, String, TripQueryParser.Ordinal)]
    )
    func superlatives(query: String, languageTag: String, ordinal: TripQueryParser.Ordinal) {
        let p = parse(query, languageTag: languageTag)
        #expect(p.ordinal == ordinal, "\(query)")
        #expect(p.minDurationDays == nil && p.maxDurationDays == nil, "\(query)")
        #expect(p.placeTerms.isEmpty, "\(query)")
    }

    @Test("length words and comparatives stay durations")
    func lengthsStay() {
        #expect(parse("long trips").ordinal == nil)
        #expect(parse("long trips").minDurationDays != nil)
        #expect(parse("viaje largo", languageTag: "es").ordinal == nil)
        #expect(parse("longer than a week").ordinal == nil)
        #expect(parse("longer than a week").minDurationDays == 8)
    }

    @Test(
        "kind words around flights",
        arguments: [
            ("connecting flights", "en", Set<TripSearchFacet>([.layover]), Set<TripSearchFacet>()),
            ("layovers", "en", [.layover], []), ("con escala", "es", [.layover], []), ("乗り継ぎ", "ja", [.layover], []),
            ("Zwischenstopps", "de", [.layover], []), ("largo recorrido", "es", [.longHaul], []),
            ("no flights", "en", [], [.flight]), ("trips without flying", "en", [], [.flight]),
            ("ohne Flug", "de", [], [.flight]), ("sin avión", "es", [], [.flight]), ("飛行機なし", "ja", [], [.flight]),
            ("flights without layovers", "en", [.flight], [.layover]),
            ("flights without a layover", "en", [.flight], [.layover]), ("uçaksız", "tr", [], [.flight]),
            ("Flüge ohne einen Zwischenstopp", "de", [.flight], [.layover]),
        ] as [(String, String, Set<TripSearchFacet>, Set<TripSearchFacet>)]
    )
    func kindWords(query: String, languageTag: String, facets: Set<TripSearchFacet>, excluded: Set<TripSearchFacet>) {
        let p = parse(query, languageTag: languageTag)
        #expect(p.facets == facets, "\(query)")
        #expect(p.excludedFacets == excluded, "\(query)")
        #expect(p.placeTerms.isEmpty, "\(query)")
    }

    @Test(
        "a bare layover word names the stop next to it",
        arguments: [("layover Valdoria", "en"), ("Zwischenstopp Valdoria", "de"), ("Valdoria乗り継ぎ", "ja")]
    )
    func bareLayoverWord(query: String, languageTag: String) {
        let p = parse(query, languageTag: languageTag)
        #expect(p.viaTerms.map(\.raw) == ["valdoria"], "\(query)")
        #expect(p.facets.isEmpty, "\(query)")
    }

    @Test(
        "a bare layover word before a connector is the kind, and the place after it the destination",
        arguments: [
            ("flight with a layover to Valdoria", "en"), ("Flug mit Umstieg nach Valdoria", "de"),
            ("vuelo con escala a Valdoria", "es"),
        ]
    )
    func layoverBeforeDestination(query: String, languageTag: String) {
        let p = parse(query, languageTag: languageTag)
        #expect(p.viaTerms.isEmpty, "\(query)")
        #expect(p.facets.contains(.layover), "\(query)")
        #expect(p.placeTerms.map(\.raw) == ["valdoria"], "\(query)")
    }

    // MARK: - Picking

    private func trip(
        _ place: String, _ start: Date, days: Int?, transit: [String] = [], title: String? = nil,
        codes: Set<String> = [], facets: Set<TripSearchFacet> = [], farthestKm: Double? = nil, id: UUID = UUID()
    ) -> TripSearchDocument {
        TripSearchDocument(
            tripID: id,
            fields: [
                TripSearchField(kind: .title, displayValues: [title ?? place]),
                TripSearchField(kind: .place, displayValues: [place]),
                TripSearchField(kind: .transit, displayValues: transit),
            ],
            startDate: start, endDate: days.map { start.addingTimeInterval(Double($0 - 1) * 86_400) },
            startYear: utcCal.component(.year, from: start), startMonth: utcCal.component(.month, from: start),
            durationDays: days, isComplete: days != nil, countryCodes: codes, facets: facets, farthestKm: farthestKm)
    }

    private func search(_ documents: [TripSearchDocument], _ query: String, languageTag: String = "en", typing: Bool = false)
        -> [TripSearchMatch] {
        TripQueryParser.searchTrips(
            index: TripSearchIndex(documents: documents), query: query, allowsTrailingPartial: typing,
            now: now, calendar: utcCal, languageTag: languageTag)
    }

    private func found(_ documents: [TripSearchDocument], _ query: String, languageTag: String = "en", typing: Bool = false)
        -> [Int] {
        search(documents, query, languageTag: languageTag, typing: typing).filter { $0.strength != .partial }.map(\.documentIndex)
    }

    /// 0 Valdoria 2020, 1 Marenza 2021, 2 Valdoria 2022 (12 days), 3 Valdoria
    /// 2024, 4 Marenza 2025 (12 days), 5 Valdoria now (ongoing).
    private var history: [TripSearchDocument] {
        [
            trip("Valdoria", date(2020, 5), days: 4, codes: ["IT"], farthestKm: 900),
            trip("Marenza", date(2021, 3), days: 3, codes: ["FR", "IT"], farthestKm: 4_500),
            trip("Valdoria", date(2022, 6), days: 12, codes: ["IT"], farthestKm: 900),
            trip("Valdoria", date(2024, 9), days: 2, codes: ["IT"], farthestKm: 900),
            trip("Marenza", date(2025, 1), days: 12, codes: ["FR"], farthestKm: 1_200),
            trip("Valdoria", date(2026, 7, 8), days: nil, codes: ["IT"], farthestKm: 9_000),
        ]
    }

    @Test("nth, last and previous pick by start date")
    func byStartDate() {
        #expect(found(history, "first trip to Valdoria") == [0])
        #expect(found(history, "2nd trip to Valdoria") == [2])
        #expect(found(history, "my 2nd Valdoria trip") == [2])
        #expect(found(history, "third trip to Valdoria") == [3])
        #expect(found(history, "4th trip to Valdoria") == [5])
        // The trip under way is the last; the visit before it the previous.
        #expect(found(history, "last trip") == [5])
        #expect(found(history, "most recent trip") == [5])
        #expect(found(history, "last time in Valdoria") == [3])
        #expect(found(history, "previous trip") == [4])
        #expect(found(history, "latest trip to Marenza") == [4])
    }

    @Test("trips sharing a start share a rank and use up as many ranks; twins are one trip")
    func ranks() {
        let twin = UUID()
        let documents = [
            trip("Valdoria", date(2021, 4), days: 3), trip("Marenza", date(2021, 4), days: 3),
            trip("Kostavo", date(2023, 2), days: 3, id: twin), trip("Kostavo", date(2023, 2), days: 3, id: twin),
            trip("Ostrel", date(2024, 6), days: 3),
        ]
        #expect(found(documents, "first trip") == [0, 1])
        #expect(found(documents, "2nd trip") == [0, 1])
        #expect(found(documents, "3rd trip") == [2, 3])
        #expect(found(documents, "4th trip") == [4])
        #expect(found(documents, "5th trip").isEmpty)
        // Twin rows that diverged rank once, by their earliest start.
        let split = UUID()
        let diverged = [
            trip("Kostavo", date(2020, 3), days: 3, id: split), trip("Kostavo", date(2021, 3), days: 3, id: split),
            trip("Valdoria", date(2022, 5), days: 3),
        ]
        #expect(found(diverged, "first trip") == [0, 1])
        #expect(found(diverged, "2nd trip") == [2])
    }

    @Test("a first visit under way has no previous one")
    func noPreviousVisit() {
        let documents = [trip("Marenza", date(2024, 4), days: 5), trip("Valdoria", date(2026, 7, 8), days: nil)]
        let matches = search(documents, "last time in Valdoria")
        #expect(matches.map(\.documentIndex) == [1])
        #expect(matches.allSatisfy { $0.strength == .partial })
        #expect(found(documents, "last trip to Valdoria") == [1])
    }

    @Test("an nth past the matching trips offers them as suggestions")
    func nthPastTheEnd() {
        let matches = search(history, "5th trip to Marenza")
        #expect(matches.allSatisfy { $0.strength == .partial })
        #expect(matches.map(\.documentIndex) == [1, 4])
    }

    @Test("superlatives keep every completed trip with the extreme value")
    func byMeasure() {
        #expect(found(history, "longest trip") == [2, 4])
        #expect(found(history, "longest trip to Marenza") == [4])
        #expect(found(history, "longest trip in 2022") == [2])
        #expect(found(history, "shortest trip") == [3])
        // The trip under way has no final length and no final distance.
        #expect(found(history, "farthest trip") == [1])
        #expect(found(history, "trip with the most countries") == [1])
        #expect(found(history, "längste Reise", languageTag: "de") == [2, 4])
    }

    @Test("every trip sharing the extreme value is an answer")
    func superlativeTies() {
        let weekends = (1...4).map { trip("Valdoria", date(2020 + $0, 5), days: 2, codes: ["IT"]) }
            + [trip("Marenza", date(2025, 8), days: 9, codes: ["FR"])]
        #expect(found(weekends, "shortest trip") == [0, 1, 2, 3])
        #expect(found(weekends, "longest trip") == [4])
        #expect(found(weekends, "trip with the most countries") == [0, 1, 2, 3, 4])
    }

    @Test("a superlative measures each logical trip once; one with a row under way is under way")
    func superlativeTwins() {
        let twin = UUID()
        let documents = [
            trip("Kostavo", date(2023, 3), days: 30, id: twin), trip("Kostavo", date(2026, 7, 1), days: nil, id: twin),
            trip("Valdoria", date(2024, 5), days: 20),
        ]
        #expect(found(documents, "longest trip") == [2])
        let settled = UUID()
        let both = [
            trip("Kostavo", date(2023, 3), days: 30, id: settled), trip("Kostavo", date(2023, 4), days: 12, id: settled),
            trip("Valdoria", date(2024, 5), days: 20),
        ]
        // Measured by its earliest-starting row; every row returned.
        #expect(found(both, "longest trip") == [0, 1])
    }

    @Test("a logical trip is dated and settled by every row, also rows the match tiers dropped")
    func twinsAcrossTiers() {
        // 1 is 0's twin under way; whole-name precedence makes its longer name similar only.
        let twin = UUID()
        let documents = [
            trip("Kostavo", date(2023, 3), days: 30, id: twin), trip("Upper Kostavo", date(2026, 7, 1), days: nil, id: twin),
            trip("Kostavo", date(2024, 5), days: 20),
        ]
        #expect(found(documents, "longest trip to Kostavo") == [2])
    }

    @Test("an ordinal picks among the strong matches when there are any")
    func strongFirst() {
        // 1 only passed through Valdoria, after the visit of 0.
        let documents = [
            trip("Valdoria", date(2021, 4), days: 5),
            trip("Marenza", date(2023, 8), days: 5, transit: ["Valdoria"]),
        ]
        #expect(found(documents, "last trip to Valdoria") == [0])
        #expect(found(documents, "first trip to Marenza") == [1])
    }

    @Test("while typing, an ordinal takes the start of a trip noun no place starts with")
    func typedTripNoun() {
        #expect(found(history, "last tri", typing: true) == [5])
        let documents = history + [trip("Trinmora", date(2019, 2), days: 3)]
        #expect(!found(documents, "last tri", typing: true).contains(5))
    }

    // MARK: - Flights

    @Test("a via place matched at a stop is a strong match; a stop alone otherwise is similar")
    func viaStrength() {
        let documents = [
            trip("Marenza", date(2023, 8), days: 5, transit: ["Valdoria"], facets: [.flight, .layover]),
            trip("Kostavo", date(2024, 2), days: 5, facets: [.flight]),
        ]
        let via = search(documents, "layover in Valdoria")
        #expect(via.map(\.documentIndex) == [0])
        #expect(via.first?.strength == .strong)
        #expect(search(documents, "Valdoria").first?.strength == .similar)
        #expect(found(documents, "connecting flights") == [0])
        #expect(found(documents, "flights without layovers") == [1])
    }

    @Test("a romaji long-vowel spelling reaches a stop in Japan; via names it strongly")
    func viaRomajiStop() {
        let stop = TripSearchDocument(
            tripID: UUID(),
            fields: [
                TripSearchField(kind: .title, displayValues: ["Marenza"]),
                TripSearchField(kind: .place, displayValues: ["Marenza"]),
                TripSearchField(kind: .transit, displayValues: ["Tokyo"], japanValues: ["Tokyo"]),
            ],
            startDate: date(2024, 2), endDate: date(2024, 2, 14), startYear: 2024, startMonth: 2,
            durationDays: 5, isComplete: true, countryCodes: [], facets: [.flight])
        #expect(search([stop], "via Toukyou").map(\.strength) == [.strong])
        #expect(search([stop], "Toukyou").map(\.strength) == [.similar])
    }

    @Test("trips without a kind; a kind is a fact, never a word of the title")
    func withoutKinds() {
        let documents = [
            trip("Marenza", date(2023, 8), days: 5, facets: [.flight]),
            trip("Kostavo", date(2024, 2), days: 5, title: "No flights"),
            trip("Valdoria", date(2025, 5), days: 9, facets: [.flight, .layover]),
        ]
        #expect(found(documents, "no flights") == [1])
        #expect(found(documents, "ohne Flug", languageTag: "de") == [1])
        #expect(found(documents, "flights") == [0, 2])
        #expect(found(documents, "flights without layovers") == [0])
        #expect(found(documents, "flights without a layover") == [0])
    }
}
