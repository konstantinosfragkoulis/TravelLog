//
//  TripSearchGreeklishTests.swift
//  TravelLogTests
//
//  Greeklish, Greek written in Latin letters: one skeleton for both
//  scripts (`TripSearchText.greeklishSkeletons`) finds Greek place names
//  typed in Latin letters, and Greek date and kind words read as the words
//  they spell (`kalokairi 2025`, `pasxa`). Invented places.
//

import Foundation
import Testing
@testable import TravelLog

struct TripSearchGreeklishTests {

    @Test("Greek and the Latin spellings people use meet in one skeleton")
    func skeletons() {
        #expect(TripSearchText.greeklishSkeletons("χαροκαμπος") == ["xarokabos"])
        for spelling in ["xarokampos", "charokampos", "harokampos", "xarokabos"] {
            #expect(TripSearchText.greeklishSkeletons(spelling).contains("xarokabos"), "\(spelling)")
        }
        #expect(TripSearchText.greeklishSkeletons("μυλοπεταμος") == ["milopetamos"])
        #expect(TripSearchText.greeklishSkeletons("mylopotamos").contains("milopotamos"))
        #expect(TripSearchText.greeklishSkeletons("8alassini").contains("thalasini"))
        #expect(TripSearchText.greeklishSkeletons("θαλασσινη") == ["thalasini"])
        // Too short, or neither script.
        #expect(TripSearchText.greeklishSkeletons("χαρ").isEmpty)
        #expect(TripSearchText.greeklishSkeletons("東京旅行").isEmpty)
    }

    private func document(_ place: String, alternate: String) -> TripSearchDocument {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return TripSearchDocument(
            tripID: UUID(),
            fields: [
                TripSearchField(kind: .title, displayValues: [place]),
                TripSearchField(kind: .place, displayValues: [place]),
                TripSearchField(kind: .place, displayValues: [alternate], alternateOf: [place]),
            ],
            startDate: start, endDate: start.addingTimeInterval(86_400), startYear: 2023, startMonth: 11,
            durationDays: 2, isComplete: true)
    }

    @Test("a Greek place name typed in Greeklish finds the trip")
    func places() {
        let documents = [document("Charokampos", alternate: "Χαρόκαμπος"), document("Valdoria", alternate: "Βαλντόρια")]
        func found(_ query: String) -> [Int] {
            TripQueryParser.searchTrips(
                index: TripSearchIndex(documents: documents), query: query, allowsTrailingPartial: false,
                languageTag: "en")
                .filter { $0.strength != .partial }
                .map(\.documentIndex)
        }
        #expect(found("xarokampos") == [0])
        #expect(found("harokabos") == [0])
        #expect(found("valntoria") == [1])
        #expect(found("valdoria") == [1])
    }

    @Test("a Greek place name in Greeklish finds the trip while typing, not a one-letter typo of another")
    func placesWhileTyping() {
        // Καλίρνη spells kalirni; Kalirna is one letter from it.
        let kalirna = TripSearchDocument(
            tripID: UUID(),
            fields: [TripSearchField(kind: .title, displayValues: ["Kalirna"]), TripSearchField(kind: .place, displayValues: ["Kalirna"])],
            startDate: Date(timeIntervalSince1970: 1_700_000_000), endDate: Date(timeIntervalSince1970: 1_700_086_400),
            startYear: 2023, startMonth: 11, durationDays: 2, isComplete: true)
        let index = TripSearchIndex(documents: [document("Ardelos", alternate: "Καλίρνη"), kalirna])
        for (query, typing) in [("kalirni", true), ("kalirni ", true), ("kalirni", false)] {
            let hits = TripQueryParser.searchTrips(
                index: index, query: query, allowsTrailingPartial: typing, languageTag: "en")
                .filter { $0.strength != .partial }
            #expect(hits.map(\.documentIndex) == [0], "\(query) \(typing)")
            #expect(hits.allSatisfy { $0.strength == .strong }, "\(query) \(typing)")
        }
    }

    @Test("a word some trip has as typed is not a Greeklish spelling of another")
    func typedWordWins() {
        func place(_ name: String) -> TripSearchDocument {
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            return TripSearchDocument(
                tripID: UUID(),
                fields: [TripSearchField(kind: .title, displayValues: [name]), TripSearchField(kind: .place, displayValues: [name])],
                startDate: start, endDate: start.addingTimeInterval(86_400), startYear: 2023, startMonth: 11,
                durationDays: 2, isComplete: true)
        }
        // Κυλόρα spells kilora in Greeklish (υ as i), not as typed: ICU gives kylora.
        let index = TripSearchIndex(documents: [place("Kilora"), place("Κυλόρα")])
        func found(_ query: String, typing: Bool = false) -> [Int] {
            TripQueryParser.searchTrips(index: index, query: query, allowsTrailingPartial: typing, languageTag: "en")
                .filter { $0.strength != .partial }.map(\.documentIndex)
        }
        #expect(found("kilora") == [0])
        #expect(found("κυλορα") == [1])
        // Also while typing.
        #expect(found("kilora", typing: true) == [0])
    }

    @Test("Greek date and kind words in Greeklish read as the Greek words")
    func vocabulary() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let summer = TripQueryParser.parse("kalokairi 2025", now: now, languageTag: "en")
        #expect(summer.months == [6, 7, 8])
        #expect(summer.years == [2025])
        #expect(summer.placeTerms.isEmpty)
        #expect(TripQueryParser.parse("kalokeri 2025", now: now, languageTag: "en").months == [6, 7, 8])
        #expect(TripQueryParser.parse("pasxa", now: now, languageTag: "en").holidays == [.orthodoxEaster])
        #expect(TripQueryParser.parse("dekapentavgoustos", now: now, languageTag: "en").holidays == [.assumption])
        #expect(TripQueryParser.parse("nisia", now: now, languageTag: "en").facets == [.island])
        // Each word of a Greek phrase.
        #expect(TripQueryParser.parse("polles xwres", now: now, languageTag: "en").facets == [.multiCountry])
        // A word some trip has stays a place.
        let corpus = TripSearchIndex(documents: [document("Kalokeri", alternate: "Καλοκέρι")])
        #expect(TripQueryParser.parse("kalokeri 2025", now: now, languageTag: "en", corpus: corpus).months.isEmpty)
    }
}
