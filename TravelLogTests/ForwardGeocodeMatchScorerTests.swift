//
//  ForwardGeocodeMatchScorerTests.swift
//  TravelLogTests
//

import Foundation
import Testing
@testable import TravelLog

struct ForwardGeocodeMatchScorerTests {

    typealias Candidate = ForwardGeocodeMatchScorer.Candidate

    @Test func smallPlaceNeedsAndReceivesIndependentAddressAgreement() {
        let result = ForwardGeocodeMatchScorer.evaluate(
            queryCandidates: ["Kypséli"],
            candidates: [Candidate(
                rank: 0,
                name: "Kypséli",
                address: "Kypséli, Aegina, Greece",
                mapLocality: "Kypséli",
                mapRegion: "Greece",
                reverseLocality: "Kypséli",
                reverseIsland: "Aegina",
                reverseCountry: "Greece"
            )]
        )

        #expect(result.isAccepted)
        #expect(result.candidateRank == 0)
        #expect(result.features.contains(.exactNamePhrase))
        #expect(result.features.contains(.fullGeographicCoverage))
    }

    @Test func categorizedVenueCanCorroborateACompleteNameMatch() {
        let result = ForwardGeocodeMatchScorer.evaluate(
            queryCandidates: ["Hotel Grande Bretagne"],
            candidates: [Candidate(
                rank: 0,
                name: "Hotel Grande Bretagne, A Luxury Collection Hotel",
                address: "1 Vasileos Georgiou A, Syntagma Square, Athens, Greece",
                mapLocality: "Athens",
                mapRegion: "Greece",
                pointOfInterestCategory: "MKPOICategoryHotel"
            )]
        )

        #expect(result.isAccepted)
        #expect(result.features.contains(.knownPointOfInterest))
        #expect(result.features.contains(.semanticCategoryAgreement))
    }

    @Test func exactStructuredAddressCanMatchWhenTheItemNameDiffers() {
        let result = ForwardGeocodeMatchScorer.evaluate(
            queryCandidates: ["10 Downing Street"],
            candidates: [Candidate(
                rank: 0,
                name: "Prime Minister's Office",
                address: "10 Downing Street, London, SW1A 2AA, England",
                mapLocality: "London",
                mapRegion: "United Kingdom"
            )]
        )

        #expect(result.isAccepted)
        #expect(result.features.contains(.exactAddressPhrase))
    }

    @Test func scorerChoosesAValidatedLaterResultInsteadOfTheFirstResult() {
        let result = ForwardGeocodeMatchScorer.evaluate(
            queryCandidates: ["Terminal 5 Heathrow"],
            candidates: [
                Candidate(
                    rank: 0,
                    name: "Terminal 5",
                    address: "Hounslow, England",
                    mapLocality: "Hounslow",
                    mapRegion: "United Kingdom"
                ),
                Candidate(
                    rank: 1,
                    name: "Heathrow Airport Terminal 5",
                    address: "Hounslow, England",
                    mapLocality: "Hounslow",
                    mapRegion: "United Kingdom",
                    pointOfInterestCategory: "MKPOICategoryPublicTransport"
                ),
            ]
        )

        #expect(result.isAccepted)
        #expect(result.candidateRank == 1)
    }

    @Test func genericCalendarLocationsAreRejectedBeforeSearch() {
        for query in [
            "Zoom Room 4b", "Conference Room 4b", "Building C", "Main Office",
            "Teams Meeting", "Google Meet", "Board Room", "Room 4B", "HQ",
            "Customer Site", "Client Office", "Home Office", "Offsite", "TBD",
            "Online", "Webex", "Meeting Room A", "Flight BA742",
        ] {
            let viable = ForwardGeocodeMatchScorer.viableQueryCandidates(from: [query])
            #expect(viable.isEmpty, Comment(rawValue: query))
        }
    }

    @Test func genericPrefixDoesNotHideARealVenueOnAnotherLine() {
        let candidates = ForwardGeocoder.candidateStrings(
            from: "Room 4B\nHotel Grande Bretagne\nAthens"
        )
        #expect(candidates == ["Room 4B", "Hotel Grande Bretagne", "Athens"])
        #expect(ForwardGeocodeMatchScorer.viableQueryCandidates(from: candidates)
            == ["Hotel Grande Bretagne", "Athens"])
    }

    @Test func everyDistinctiveTokenMustBeAccountedFor() {
        let wrongAddress = ForwardGeocodeMatchScorer.evaluate(
            queryCandidates: ["1 Apple Park Way"],
            candidates: [Candidate(
                rank: 0,
                name: "1 Park Way",
                address: "1 Park Way, Crawley, England",
                mapLocality: "Crawley",
                mapRegion: "United Kingdom"
            )]
        )
        #expect(!wrongAddress.isAccepted)
        #expect(wrongAddress.features.contains(.missingDistinctiveTokens))

        let wrongVilla = ForwardGeocodeMatchScorer.evaluate(
            queryCandidates: ["Villa Rosa Cephalonia"],
            candidates: [
                Candidate(
                    rank: 0,
                    name: "Villa Elia - Salinus Cephalonia Villas",
                    address: "Lixoúri, Cephalonia, Greece",
                    mapLocality: "Lixoúri",
                    mapRegion: "Greece"
                ),
                Candidate(
                    rank: 1,
                    name: "Villa Rose",
                    address: "Paxos, Greece",
                    mapLocality: "Faros",
                    mapRegion: "Greece",
                    pointOfInterestCategory: "MKPOICategoryHotel"
                ),
            ]
        )
        #expect(!wrongVilla.isAccepted)
        #expect(wrongVilla.features.contains(.missingDistinctiveTokens))
    }

    @Test func requestedPlaceTypeMustAlsoMatch() {
        let result = ForwardGeocodeMatchScorer.evaluate(
            queryCandidates: ["Athens Hotel"],
            candidates: [Candidate(
                rank: 0,
                name: "Athens International Airport",
                address: "Néa Mákri, Greece",
                mapLocality: "Néa Mákri",
                mapRegion: "Greece",
                pointOfInterestCategory: "MKPOICategoryAirport",
                reverseMetro: "Athens"
            )]
        )

        #expect(!result.isAccepted)
    }

    @Test func aBareNameEchoIsNotEnough() {
        let result = ForwardGeocodeMatchScorer.evaluate(
            queryCandidates: ["Syntagma Square"],
            candidates: [Candidate(
                rank: 0,
                name: "Syntagma Square",
                address: "Vasileos Georgiou A 2, Athens, Greece",
                mapLocality: "Athens",
                mapRegion: "Greece"
            )]
        )

        #expect(!result.isAccepted)
        #expect(result.score < ForwardGeocodeMatchScorer.acceptanceThreshold)
    }

    @Test func transliteratedPlaceEvidenceMatchesGreekQuery() {
        let result = ForwardGeocodeMatchScorer.evaluate(
            queryCandidates: ["Κεφαλονιά"],
            candidates: [Candidate(
                rank: 0,
                name: "Kephalonia",
                address: "Kephalonia, Greece",
                mapLocality: "Kephalonia",
                mapRegion: "Greece"
            )]
        )

        #expect(result.isAccepted)
    }
}

struct ForwardGeocoderCachePolicyTests {

    @Test func scoredRejectionsExpireButAcceptedCachePolicyRemainsIndependent() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(ForwardGeocoder.negativeCacheIsFresh(
            cachedAt: now.addingTimeInterval(-6 * 24 * 60 * 60),
            now: now
        ))
        #expect(!ForwardGeocoder.negativeCacheIsFresh(
            cachedAt: now.addingTimeInterval(-8 * 24 * 60 * 60),
            now: now
        ))
        // A backwards wall-clock correction must not prematurely expire it.
        #expect(ForwardGeocoder.negativeCacheIsFresh(
            cachedAt: now.addingTimeInterval(60),
            now: now
        ))
    }
}

@MainActor
struct ForwardGeocodeLiveReplayTests {

    /// Opt-in because MapKit results are network/locale dependent. Run with
    /// `TRAVELLOG_MAPKIT_REPLAY=1` during a calibration pass; deterministic
    /// fixtures above remain the ordinary CI contract. The `.enabled(if:)`
    /// trait reports the test as skipped
    /// because an ordinary run does not execute the live replay.
    @Test(.enabled(
        if: ProcessInfo.processInfo.environment["TRAVELLOG_MAPKIT_REPLAY"] == "1",
        "Set TRAVELLOG_MAPKIT_REPLAY=1 to run the live MapKit calibration replay"
    ))
    func labeledMapKitReplay() async {
        for query in [
            "Kypséli", "Cephalonia", "Hotel Grande Bretagne",
            "Athens International Airport", "10 Downing Street",
        ] {
            let result = await ForwardGeocoder.shared.liveReplayAssessment(for: query)
            #expect(result.isAccepted, Comment(rawValue: query))
        }

        for query in [
            "Conference Room 4b", "Building C", "Main Office", "Google Meet",
            "Board Room", "Acme HQ", "1 Apple Park Way", "Villa Rosa Cephalonia",
        ] {
            let result = await ForwardGeocoder.shared.liveReplayAssessment(for: query)
            #expect(!result.isAccepted, Comment(rawValue: query))
        }
    }
}
