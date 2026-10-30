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
        #expect(classifier.defaultTitle(for: trip, homePlaceNames: ["limassol"]) == "Aegina")
    }

    @Test("a country-island locality remains a candidate for a different home")
    func nonHomeLocalityPreserved() throws {
        let (classifier, trip) = try makeTrip([StaySpec(locality: "Limassol"), aegina])
        #expect(classifier.defaultTitle(for: trip, homePlaceNames: ["athens"]) == "Limassol & Aegina")
        let (cyprusClassifier, cyprusTrip) = try makeTrip([
            StaySpec(locality: "Limassol"), StaySpec(locality: "Paphos"),
        ])
        #expect(cyprusClassifier.defaultTitle(for: cyprusTrip, homePlaceNames: ["athens"])
            == "Limassol & Paphos")
    }

    @Test("excluding Limassol does not exclude other Cyprus localities or change stay grouping")
    func otherLocalitiesRemainAway() throws {
        let (classifier, trip) = try makeTrip([
            StaySpec(locality: "Limassol"), StaySpec(locality: "Nicosia"), StaySpec(locality: "Paphos"),
        ])
        #expect(classifier.defaultTitle(for: trip, homePlaceNames: ["limassol"]) == "Nicosia & Paphos")
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
        #expect(classifier.defaultTitle(for: trip, homePlaceNames: ["valletta"]) == "Aegina")
        #expect(classifier.defaultTitle(for: trip, homePlaceNames: ["floriana"]) == "Valletta & Aegina")
        #expect(classifier.defaultTitle(for: trip, homePlaceNames: ["aegina"]) == "Valletta")
        #expect(classifier.defaultTitle(for: trip, homePlaceNames: ["kypseli"]) == "Valletta & Aegina")
        let (missingClassifier, missingTrip) = try makeTrip([StaySpec(locality: nil), aegina])
        #expect(missingClassifier.defaultTitle(for: missingTrip, homePlaceNames: ["limassol"]) == "Aegina")
    }

    @Test("a title-level name prefers the metro, then an island that is not the country, then the locality")
    func titlePlaceNameOrder() {
        func name(_ metro: String?, _ island: String?, _ locality: String?,
                  _ country: String?, _ iso: String?) -> String? {
            TripTitlePolicy.titlePlaceName(metro: metro, island: island, locality: locality, country: country, iso: iso)
        }
        #expect(name("Valletta", "Malta", "Floriana", "Malta", "MT") == "Valletta")
        #expect(name(nil, "Malta", "Floriana", "Malta", "MT") == "Floriana")
        #expect(name(nil, "Cyprus", "Limassol", nil, "CY") == "Limassol")
        #expect(name(nil, "Cyprus", nil, "Cyprus", "CY") == "Cyprus")
        #expect(name(nil, "Aegina", "Kypséli", "Greece", "GR") == "Aegina")
        #expect(name(nil, "", "Oia", "Greece", "GR") == "Oia")
        #expect(name(nil, nil, "Oia", "Greece", "GR") == "Oia")
        #expect(name(nil, nil, nil, "Greece", "GR") == nil)
    }

    @Test("the all-home exception remains for promoted localities")
    func allHomeLocalitiesKeepFallback() throws {
        let (classifier, trip) = try makeTrip([StaySpec(locality: "Limassol")])
        #expect(classifier.defaultTitle(for: trip, homePlaceNames: ["limassol"]) == "Limassol")
        #expect(classifier.titleValidationFailure("Limassol", for: trip, homePlaceNames: ["limassol"]) == nil)
    }
}
