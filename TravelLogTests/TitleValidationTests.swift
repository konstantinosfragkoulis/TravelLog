//
//  TitleValidationTests.swift
//  TravelLogTests
//
//  Title validation (TripClassifier seams over TripTitlePolicy). Checks:
//
//   (a) `titleValidationFailure(_:for:)` returns the EXACT ungrounded word
//       for an ungrounded title, and nil for a fully grounded one.
//   (b) demonyms decorate a grounded place word while a made-up place word
//       fails. A demonym alone cannot carry a title.
//   (c) the connector vocabulary is exact.
//   (d) forbidden-country vs demonym precedence: "Greek" decorates a grounded
//       place word while "Greece" is a forbidden-country hard reject.
//
//  The tests check `titleValidationFailure`, `ungroundedTitleFailure` and
//  the `titleWordsAreGrounded` Bool API.
//
//  `@MainActor` because it constructs @Model Stay/Trip and instantiates the
//  @ModelActor TripClassifier (app is MainActor-by-default).
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct TitleValidationTests {

    private typealias StaySpec = (
        metro: String?, island: String?, locality: String?,
        admin: String?, iso: String?, country: String?
    )

    private func makeTrip(_ specs: [StaySpec]) throws -> (TripClassifier, Trip) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        let trip = Trip(startDate: .now)
        context.insert(trip)
        for (i, s) in specs.enumerated() {
            let stay = Stay(startTime: .now, endTime: .now,
                            centroidLatitude: 0, centroidLongitude: 0,
                            h3IndexRes6: "h\(i)", pingCount: 1,
                            distanceFromHomeKm: 0, pingIDs: [])
            stay.metroName = s.metro
            stay.islandName = s.island
            stay.locality = s.locality
            stay.administrativeArea = s.admin
            stay.isoCountryCode = s.iso
            stay.country = s.country
            stay.category = .destination
            stay.orderInTrip = i
            stay.trip = trip
            context.insert(stay)
        }
        return (classifier, trip)
    }

    // MARK: - (a) validation seam returns the exact ungrounded word / nil

    @Test("titleValidationFailure returns .ungroundedWord(exact word)")
    func failureNamesTheUngroundedWord() throws {
        let (c, trip) = try makeTrip([
            (metro: nil, island: "Syros", locality: "Ermoúpolis", admin: nil, iso: "GR", country: "Greece")
        ])
        // "Athens" is absent from the stays; it must surface as the offending word.
        #expect(c.titleValidationFailure("Syros & Athens", for: trip) == .ungroundedWord("athens"))
    }

    @Test("titleValidationFailure returns nil for a fully grounded title")
    func groundedTitleReturnsNil() throws {
        let (c, trip) = try makeTrip([
            (metro: nil, island: nil, locality: "Paris", admin: nil, iso: "FR", country: "France")
        ])
        #expect(c.titleValidationFailure("Paris", for: trip) == nil)
    }

    @Test("belt-and-suspenders checks each surface their own named reason")
    func beltAndSuspendersReasons() throws {
        let (c, trip) = try makeTrip([
            (metro: nil, island: nil, locality: "Paris", admin: nil, iso: "FR", country: "France")
        ])
        #expect(c.titleValidationFailure("", for: trip) == .empty)
        #expect(c.titleValidationFailure("A", for: trip) == .tooShort)
        #expect(c.titleValidationFailure("Paris\nParis", for: trip) == .multiLine)
        // "error" is an error-leak marker regardless of grounding.
        #expect(c.titleValidationFailure("An error occurred", for: trip) == .containsErrorWord("error"))
        // Nine grounded-or-connector words trip the ≤8 word cap first.
        let nineWords = "Paris and the and the and the and Paris"
        if case .tooManyWords(let n)? = c.titleValidationFailure(nineWords, for: trip) {
            #expect(n == 9)
        } else {
            Issue.record("expected .tooManyWords, got \(String(describing: c.titleValidationFailure(nineWords, for: trip)))")
        }
    }

    // MARK: - (b) demonyms decorate place words; made-up place words fail

    @Test("demonyms are connectors beside a place word; alone they are not a title")
    func newDemonymsGround() throws {
        // Iceland / Norway stays; the DEMONYMS ("icelandic", "norwegian")
        // differ from the country nouns ("iceland", "norway") so they are not
        // in the per-trip forbidden set. They decorate a grounded place
        // word; they cannot carry a title by themselves.
        let (c, trip) = try makeTrip([
            (metro: "Reykjavik", island: nil, locality: "Reykjavik", admin: nil, iso: "IS", country: "Iceland")
        ])
        #expect(c.titleValidationFailure("Reykjavik & the Icelandic Coast", for: trip) == nil)
        #expect(c.titleValidationFailure("Icelandic Coast", for: trip) == .noGroundedWord("Icelandic Coast"))

        let (c2, trip2) = try makeTrip([
            (metro: "Bergen", island: nil, locality: "Bergen", admin: nil, iso: "NO", country: "Norway")
        ])
        #expect(c2.titleWordsAreGrounded("Bergen & the Norwegian Coast", for: trip2))
        // A made-up place word alongside a valid demonym still fails, naming the fake word.
        #expect(c2.titleValidationFailure("Norwegian Atlantis", for: trip2) == .ungroundedWord("atlantis"))
    }

    // MARK: - (c) connector vocabulary

    @Test("connector vocabulary is exact")
    func exactVocabulary() {
        #expect(TripTitlePolicy.structuralTitleWords.count == 18)
        #expect(TripTitlePolicy.islandTitleWords.count == 4)
        #expect(TripTitlePolicy.unmappedRegionTitleWords.count == 19)
        #expect(TripTitlePolicy.titleDemonymISOCodes.count == 93)
        #expect(TripTitlePolicy.titleDemonymISOCodes.values.reduce(0) { $0 + $1.count } == 114)
        #expect(TripTitlePolicy.titleDemonymISOCodes["tuscan"] == ["it"])
        #expect(TripTitlePolicy.titleConnectorWords == TripTitlePolicy.structuralTitleWords
            .union(TripTitlePolicy.islandTitleWords)
            .union(TripTitlePolicy.unmappedRegionTitleWords)
            .union(TripTitlePolicy.titleDemonymISOCodes.keys))
        #expect(TripTitlePolicy.titleConnectorWords.count == 134)
    }

    // MARK: - (d) forbidden-country vs demonym precedence

    @Test("'Greek' grounds while 'Greece' is a forbidden-country hard reject")
    func greekAllowedGreeceRejected() throws {
        let (c, trip) = try makeTrip([
            (metro: nil, island: "Cephalonia", locality: "Lixoúri", admin: nil, iso: "GR", country: "Greece"),
            (metro: nil, island: "Mykonos", locality: "Mykonos", admin: nil, iso: "GR", country: "Greece"),
        ])
        // Demonym "Greek" passes as a connector beside a place word.
        #expect(c.titleWordsAreGrounded("Cephalonia & the Greek Islands", for: trip))
        #expect(c.titleValidationFailure("Cephalonia & the Greek Islands", for: trip) == nil)
        // Country noun "Greece" is a hard reject, surfaced as .forbiddenCountryWord.
        #expect(c.titleValidationFailure("Greece", for: trip) == .forbiddenCountryWord("greece"))
    }
}
