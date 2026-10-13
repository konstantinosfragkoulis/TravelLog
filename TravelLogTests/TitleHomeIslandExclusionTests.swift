import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct TitleHomeIslandExclusionTests {
    private struct StaySpec {
        var locality: String?
        var island: String? = "Cyprus"
        var metro: String? = nil
        var country: String = "Cyprus"
        var iso: String = "CY"
        var hours: Double = 1
    }

    private let aegina = StaySpec(
        locality: "Kypséli", island: "Aegina", country: "Greece", iso: "GR")

    private func makeTrip(_ specs: [StaySpec]) throws -> (TripClassifier, Trip) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)
        var cursor = Date(timeIntervalSinceReferenceDate: 820_563_200)
        let trip = Trip(startDate: cursor)
        context.insert(trip)
        for (index, spec) in specs.enumerated() {
            let end = cursor.addingTimeInterval(spec.hours * 3600)
            let stay = Stay(startTime: cursor, endTime: end,
                            centroidLatitude: 35, centroidLongitude: 33,
                            h3IndexRes6: "h\(index)", pingCount: 1,
                            distanceFromHomeKm: 100, pingIDs: [])
            stay.locality = spec.locality
            stay.islandName = spec.island
            stay.metroName = spec.metro
            stay.country = spec.country
            stay.isoCountryCode = spec.iso
            stay.category = .destination
            stay.orderInTrip = index
            stay.trip = trip
            context.insert(stay)
            cursor = end.addingTimeInterval(3600)
        }
        try context.save()
        return (classifier, trip)
    }

    @Test("a country-island home locality is excluded from the fallback")
    func homeLocalityExcludedFromFallback() throws {
        let (classifier, trip) = try makeTrip([StaySpec(locality: "Limassol"), aegina])
        #expect(classifier.computeFallbackTitle(for: trip, homePlaceNames: ["limassol"]) == "Aegina")
    }

    @Test("a country-island locality remains a candidate for a different home")
    func nonHomeLocalityPreserved() throws {
        let (classifier, trip) = try makeTrip([StaySpec(locality: "Limassol"), aegina])
        #expect(classifier.computeFallbackTitle(for: trip, homePlaceNames: ["athens"]) == "Limassol & Aegina")
        let (cyprusClassifier, cyprusTrip) = try makeTrip([
            StaySpec(locality: "Limassol"), StaySpec(locality: "Paphos"),
        ])
        #expect(cyprusClassifier.computeFallbackTitle(for: cyprusTrip, homePlaceNames: ["athens"])
            == "Limassol & Paphos")
    }

    @Test("excluding Limassol does not exclude other Cyprus localities or change stay grouping")
    func otherLocalitiesRemainAway() throws {
        let (classifier, trip) = try makeTrip([
            StaySpec(locality: "Limassol"), StaySpec(locality: "Nicosia"), StaySpec(locality: "Paphos"),
        ])
        #expect(classifier.computeFallbackTitle(for: trip, homePlaceNames: ["limassol"]) == "Nicosia & Paphos")
        #expect(trip.orderedStays.map(\.placeGroupName) == ["Cyprus", "Cyprus", "Cyprus"])
        #expect(classifier.titleValidationFailure("Nicosia & Paphos", for: trip, homePlaceNames: ["limassol"]) == nil)
    }

    @Test("a promoted home locality is rejected as a home word")
    func homeLocalityCannotGroundTitle() throws {
        let (classifier, trip) = try makeTrip([StaySpec(locality: "Limassol"), aegina])
        #expect(classifier.ungroundedTitleFailure("Limassol & Aegina", for: trip, homePlaceNames: ["limassol"])
            == .homePlaceWord("limassol"))
        #expect(classifier.titleValidationFailure("Limassol & Aegina", for: trip, homePlaceNames: ["limassol"])
            == .homePlaceWord("limassol"))
    }

    @Test("a long home locality stay cannot dominate title ranking")
    func homeLocalityExcludedFromRanking() throws {
        let (classifier, trip) = try makeTrip([
            StaySpec(locality: "Limassol", hours: 100), aegina, StaySpec(locality: "Paphos", hours: 2),
        ])
        #expect(classifier.missingTopPlaceFailure("Aegina", for: trip, homePlaceNames: ["limassol"])
            == .missingTopPlace("Paphos"))
        #expect(classifier.missingTopPlaceFailure("Paphos", for: trip, homePlaceNames: ["limassol"]) == nil)
    }

    @Test("metro priority, ordinary islands, and missing localities keep their home matching")
    func titleNameBoundariesPreserved() throws {
        let (classifier, trip) = try makeTrip([
            StaySpec(locality: "Floriana", island: "Malta", metro: "Valletta", country: "Malta", iso: "MT"),
            aegina,
        ])
        #expect(classifier.computeFallbackTitle(for: trip, homePlaceNames: ["valletta"]) == "Aegina")
        #expect(classifier.computeFallbackTitle(for: trip, homePlaceNames: ["floriana"]) == "Valletta & Aegina")
        #expect(classifier.computeFallbackTitle(for: trip, homePlaceNames: ["aegina"]) == "Valletta")
        #expect(classifier.computeFallbackTitle(for: trip, homePlaceNames: ["kypseli"]) == "Valletta & Aegina")
        let (missingClassifier, missingTrip) = try makeTrip([StaySpec(locality: nil), aegina])
        #expect(missingClassifier.computeFallbackTitle(for: missingTrip, homePlaceNames: ["limassol"]) == "Aegina")
    }

    @Test("policy eight is reserved for a promoted locality that actually reaches title candidates",
          arguments: ["country", "unknown", "home", "away"])
    func retryPolicyMatchesPromotedCandidateEligibility(caseName: String) async throws {
        let locality = caseName == "country" ? "Cyprus" : caseName == "unknown" ? "Unknown" : "Limassol"
        let (classifier, trip) = try makeTrip([StaySpec(locality: locality), aegina])
        let tripID = trip.id
        let fetched = try #require(await classifier.canonicalTitleShapeForTesting(tripID: tripID))
        let shape = TripClassifier.CanonicalTitleShape(trip: fetched.trip, activeHomes: fetched.activeHomes,
            homePlaceNames: caseName == "home" ? ["limassol"] : [])
        let key = await classifier.canonicalTitleFailureKeyForTesting(shape)
        #expect(key.contains(caseName == "away" ? "|v8|" : "|v7|"))
    }

    @Test("the all-home exception remains for promoted localities")
    func allHomeLocalitiesKeepFallback() throws {
        let (classifier, trip) = try makeTrip([StaySpec(locality: "Limassol")])
        #expect(classifier.computeFallbackTitle(for: trip, homePlaceNames: ["limassol"]) == "Limassol")
        #expect(classifier.titleValidationFailure("Limassol", for: trip, homePlaceNames: ["limassol"]) == nil)
    }
}
