import Foundation
import Testing
@testable import TravelLog

@Suite("Whole-place localized title verification")
struct LocalizedTitlePlaceVerifierTests {
    @Test("List separators cannot stand before, after, or instead of a place")
    func completeListsOnly() throws {
        let reference = try #require(LocalizedTitlePlaceVerifier.reference(
            sourceTitle: "Athens & Crete", snapshot: snapshot(["Athens", "Crete"])))
        for title in ["and Athens & Crete", "Athens & Crete and", "Athens && Crete",
                      "Athens Crete", "/ Athens & Crete", "Athens & Crete,"] {
            #expect(LocalizedTitlePlaceVerifier.compare(englishTitle: title, reference: reference) == .unavailable)
        }
        for (title, language) in [("Αθήνα και", "el"), ("και Ρώμη", "el"),
                                  ("Παρίσι &", "el"), ("/ 伦敦", "zh-Hans"),
                                  ("Paris und", "de"), ("Paris & & Berlin", "de")] {
            #expect(!LocalizedTitlePlaceVerifier.hasCompleteListBoundaries(title, languageTag: language))
        }
        #expect(LocalizedTitlePlaceVerifier.hasCompleteListBoundaries("Αθήνα και Κρήτη", languageTag: "el"))
        #expect(!LocalizedTitlePlaceVerifier.hasExpectedScript("Athens & Crete", languageTag: "el"))
        #expect(LocalizedTitlePlaceVerifier.hasExpectedScript("Αθήνα & Κρήτη", languageTag: "el"))
        #expect(LocalizedTitlePlaceVerifier.hasExpectedScript("Paris & Berlin", languageTag: "de"))
    }

    @Test("Oxford commas are one boundary between complete places")
    func oxfordCommaLists() throws {
        let reference = try #require(LocalizedTitlePlaceVerifier.reference(
            sourceTitle: "Athens, Crete & Rhodes", snapshot: snapshot(["Athens", "Crete", "Rhodes"])))
        #expect(LocalizedTitlePlaceVerifier.compare(
            englishTitle: "Athens, Crete, and Rhodes", reference: reference) == .match)
        #expect(LocalizedTitlePlaceVerifier.hasCompleteListBoundaries(
            "Athen, Kreta, und Rhodos", languageTag: "de"))
        #expect(LocalizedTitlePlaceVerifier.hasCompleteListBoundaries(
            "Αθήνα, Κρήτη, και Ρόδος", languageTag: "el"))
        for title in [", and Athens", "Athens, and", "Athens,, and Crete",
                      "Athens, and and Crete", "Athens, & Crete", "Athens & and Crete"] {
            #expect(LocalizedTitlePlaceVerifier.compare(englishTitle: title, reference: reference) == .unavailable)
            #expect(!LocalizedTitlePlaceVerifier.hasCompleteListBoundaries(title, languageTag: "en"))
        }
    }

    @Test("List boundaries preserve language fallback and supplementary Unicode letters")
    func languageAndUnicodeListBoundaries() {
        let fixtures: [(String, String, Bool)] = [
            ("𠀋 & 北京", "zh-Hans", true), ("𠀋 &", "zh-Hant", false),
            ("😀𠀋, and 東京", "en", true), ("Αθήνα και", "el", false),
            ("Paris và", "vi", false), ("Paris OG", "nb", false),
            ("Paris und", "de-DE", false), ("Paris und", "DE", true),
            ("Paris and", "xx", false), ("Paris and", "", false),
            ("Ogaden & Bergen", "nb", true), ("Izmir ve1", "tr", true),
            ("E & Paris", "es", false), ("Paris e", "pt-BR", false),
        ]
        for (title, language, expected) in fixtures {
            #expect(TripTitleStore.hasCompleteListBoundaries(
                title, languageTag: language) == expected)
        }
    }

    private func snapshot(_ names: [String]) -> TripTitleStore.SemanticSnapshot {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return .init(tripID: UUID(), startDate: date, endDate: date, isComplete: true,
                     customName: nil, stays: names.map { name in
            .init(id: UUID(), orderInTrip: nil, startTime: date, endTime: date,
                  durationMinutes: 60, categoryRaw: "destination", isAirport: false,
                  metroName: nil, islandName: nil, locality: name,
                  administrativeArea: nil, country: nil, isoCountryCode: nil)
        })
    }

    @Test("Complete phrases, list order, and established abbreviations preserve identity")
    func phrasesAndAliases() throws {
        let reference = try #require(LocalizedTitlePlaceVerifier.reference(
            sourceTitle: "New York & Los Angeles", snapshot: snapshot(["New York", "Los Angeles"])))
        for english in ["LA and NYC", "Los Angeles, New York", "NY / LA"] {
            #expect(LocalizedTitlePlaceVerifier.compare(englishTitle: english, reference: reference) == .match)
        }
        for english in ["New & York and LA", "New, York and LA", "New; York and LA", "New / York and LA"] {
            #expect(LocalizedTitlePlaceVerifier.compare(englishTitle: english, reference: reference) == .unavailable)
        }
    }

    @Test("Raw-script names and canonical spellings share identity without inventing exonyms")
    func rawScriptCanonicalAliases() throws {
        let reference = try #require(LocalizedTitlePlaceVerifier.reference(
            sourceTitle: "Syros & Bei Jing", snapshot: snapshot(["Σύρος", "北京", "Κεφαλονιά"])))
        for title in ["Syros & Bei Jing", "Σύρος & 北京"] {
            #expect(LocalizedTitlePlaceVerifier.compare(englishTitle: title, reference: reference) == .match)
        }
        #expect(LocalizedTitlePlaceVerifier.compare(englishTitle: "Syros & Kephalonia", reference: reference)
            == .mismatch(missing: ["bei jing"], added: ["kephalonia"]))
        for title in ["Syros & Σύρος & Bei Jing", "Syros & Bei & Jing",
                      "Syros & Beijing", "Syros weekend & Bei Jing"] {
            #expect(LocalizedTitlePlaceVerifier.compare(englishTitle: title, reference: reference) == .unavailable)
        }
        let nativeSource = try #require(LocalizedTitlePlaceVerifier.reference(
            sourceTitle: "Σύρος", snapshot: snapshot(["Σύρος"])))
        #expect(LocalizedTitlePlaceVerifier.compare(englishTitle: "Syros", reference: nativeSource) == .match)
    }

    @Test("Word-identical spellings are one place in either input order without shorter-place fallback")
    func wordIdenticalSpellingsShareIdentity() throws {
        for names in [["Saint‑Jean", "Saint Jean"], ["Saint Jean", "Saint‑Jean"]] {
            let input = snapshot(names + ["Saint", "Jean"])
            // Every title spelling of Saint‑Jean keeps its hyphen as a word
            // boundary now, so it and Saint Jean are one phrase, one place.
            for spelling in ["Saint‑Jean", "Saint‑Jean".toLatinAsciiStrict,
                             TripTitlePolicy.canonicalTitleSpelling("Saint‑Jean"), "Saint Jean"] {
                let reference = try #require(LocalizedTitlePlaceVerifier.reference(
                    sourceTitle: spelling, snapshot: input))
                for english in ["Saint Jean", "Saint-Jean", "Saint‑Jean"] {
                    #expect(LocalizedTitlePlaceVerifier.compare(englishTitle: english, reference: reference) == .match)
                }
                // The welded spelling of the retired prompt transform names no place.
                #expect(LocalizedTitlePlaceVerifier.compare(englishTitle: "SaintJean", reference: reference) == .unavailable)
            }
            #expect(LocalizedTitlePlaceVerifier.reference(sourceTitle: "SaintJean", snapshot: input) == nil)
            // Separate places never merge into the longer phrase, nor does it split.
            let separatePlaces = try #require(LocalizedTitlePlaceVerifier.reference(
                sourceTitle: "Saint & Jean", snapshot: input))
            #expect(LocalizedTitlePlaceVerifier.compare(englishTitle: "Saint Jean", reference: separatePlaces)
                == .mismatch(missing: ["jean", "saint"], added: ["saint jean"]))
            #expect(LocalizedTitlePlaceVerifier.compare(englishTitle: "Jean & Saint", reference: separatePlaces) == .match)
        }
    }

    @Test("Stored title spellings of imported native-script names verify as that place")
    func storedSpellingIsAnAlias() throws {
        for native in ["Тверь", "Σύρος", "Tromsø"] {
            let stored = TripTitlePolicy.canonicalTitleSpelling(native)
            let reference = try #require(LocalizedTitlePlaceVerifier.reference(
                sourceTitle: stored, snapshot: snapshot([native, "Paris"])))
            for english in [stored, native.toLatinAsciiStrict] {
                #expect(LocalizedTitlePlaceVerifier.compare(englishTitle: english, reference: reference) == .match)
            }
            let identity = native.toLatinAsciiStrict.lowercased()
                .split(whereSeparator: { !$0.isLetter }).joined(separator: " ")
            #expect(LocalizedTitlePlaceVerifier.compare(englishTitle: "Paris", reference: reference)
                == .mismatch(missing: [identity], added: ["paris"]))
        }
    }

    @Test("Whole phrases cannot be replaced by overlapping words or another field")
    func distinctPlaces() throws {
        let reference = try #require(LocalizedTitlePlaceVerifier.reference(
            sourceTitle: "New York", snapshot: snapshot(["New York", "New Orleans", "York", "Manhattan"])))
        #expect(LocalizedTitlePlaceVerifier.compare(englishTitle: "New Orleans & York", reference: reference)
            == .mismatch(missing: ["new york"], added: ["new orleans", "york"]))
        #expect(LocalizedTitlePlaceVerifier.compare(englishTitle: "Manhattan", reference: reference)
            == .mismatch(missing: ["new york"], added: ["manhattan"]))
    }

    @Test("Every meaningful source word must be grounded before checking missing places")
    func partialCoverageIsUnavailable() throws {
        for source in ["Paris & Atlantis", "Paris Weekend", "Paris Coast", "Paris & Paris"] {
            #expect(LocalizedTitlePlaceVerifier.reference(sourceTitle: source, snapshot: snapshot(["Paris"])) == nil)
        }
        let reference = try #require(LocalizedTitlePlaceVerifier.reference(
            sourceTitle: "Firenze & Paris", snapshot: snapshot(["Firenze", "Paris"])))
        #expect(LocalizedTitlePlaceVerifier.compare(englishTitle: "Florence", reference: reference) == .unavailable)
        #expect(LocalizedTitlePlaceVerifier.compare(englishTitle: "Paris", reference: reference)
            == .mismatch(missing: ["firenze"], added: []))
    }

    @Test("Repeated identities are not silently collapsed")
    func duplicatesAreUnavailable() throws {
        let reference = try #require(LocalizedTitlePlaceVerifier.reference(
            sourceTitle: "Paris & New York", snapshot: snapshot(["Paris", "New York"])))
        for english in ["Paris, Paris & New York", "Paris & NYC & NY"] {
            #expect(LocalizedTitlePlaceVerifier.compare(englishTitle: english, reference: reference) == .unavailable)
        }
    }

    @Test("Ordinary name punctuation and diacritics remain comparable")
    func punctuation() throws {
        let reference = try #require(LocalizedTitlePlaceVerifier.reference(
            sourceTitle: "St. John's & Saint-Jean", snapshot: snapshot(["St. John’s", "Saint-Jean"])))
        #expect(LocalizedTitlePlaceVerifier.compare(englishTitle: "Saint‑Jean and St John's", reference: reference) == .match)
    }
}
