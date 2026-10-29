//
//  TemporaryHomeFixture.swift
//  TravelLogTests
//
//  The construction the temporary-home suites share. Each builder writes
//  exactly what its arguments say and nothing else: no provenance, revision,
//  zone or edit mark a caller did not pass. The suites' deliberate differences
//  (a GMT zone, a synced revision, an id-only legacy stamp, another epoch)
//  stay visible in their own wrappers.
//

import Foundation
import SwiftData
@testable import TravelLog

@MainActor
enum TemporaryHomeFixture {

    typealias Place = (lat: Double, lon: Double)

    /// Whole fixture days from midnight UTC on 1 January 2001.
    nonisolated static func date(_ day: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: day * 86_400)
    }

    /// A 10 km square urban centre around `centre`.
    nonisolated static func squareShape(id: Int64, around centre: Place) -> HomeShape {
        HomeShape.urbanCentre(
            id: id, name: "City \(id)", areaKm2: 100,
            rings: [[[centre.lon - 0.05, centre.lat - 0.05, centre.lon + 0.05, centre.lat - 0.05,
                      centre.lon + 0.05, centre.lat + 0.05, centre.lon - 0.05, centre.lat + 0.05]]],
            centreLatitude: centre.lat, centreLongitude: centre.lon)
    }

    /// An inserted stay at `place`. `idOnlyStamp` writes the temporary-home
    /// id alone, with no revision; a stamp with a revision is the caller's
    /// `setTemporaryHomeProvenance`.
    @discardableResult
    static func stay(
        _ ctx: ModelContext, _ place: Place, from start: Date, to end: Date,
        _ category: StayCategory, hex: String, pingCount: Int,
        source: DataSource = .liveSLC, zone: String? = nil,
        airport: Bool = false, idOnlyStamp: UUID? = nil
    ) -> Stay {
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: place.lat, centroidLongitude: place.lon,
            h3IndexRes6: hex, pingCount: pingCount, distanceFromHomeKm: 0, pingIDs: [],
            source: source, timeZoneIdentifier: zone)
        stay.category = category
        stay.temporaryHomeID = idOnlyStamp
        stay.isAirport = airport
        ctx.insert(stay)
        return stay
    }

    /// An inserted trip holding `stays` in order. A complete trip ends with
    /// its last stay; an open one has no end.
    @discardableResult
    static func trip(_ ctx: ModelContext, _ stays: [Stay], complete: Bool) -> Trip {
        let trip = Trip(startDate: stays[0].startTime)
        trip.isComplete = complete
        trip.endDate = complete ? stays[stays.count - 1].endTime : nil
        ctx.insert(trip)
        for (order, stay) in stays.enumerated() {
            stay.trip = trip
            stay.orderInTrip = order
        }
        return trip
    }

    /// The real home, 25 km, since fixture day -1000. No home stay.
    @discardableResult
    static func realHome(_ ctx: ModelContext, _ label: String, at place: Place) -> Home {
        let home = Home(label: label, latitude: place.lat, longitude: place.lon,
                        radiusKm: 25, startedAt: date(-1000))
        ctx.insert(home)
        return home
    }

    /// An inserted declaration. A nil `zone` leaves the zone unset.
    static func temporaryHome(
        _ ctx: ModelContext, _ label: String, at place: Place,
        from: Double, until: Double?, zone: String?
    ) -> TemporaryHome {
        let row = TemporaryHome(label: label, latitude: place.lat, longitude: place.lon,
                                startedAt: date(from), endedAt: until.map { date($0) })
        if let zone { row.timeZoneIdentifier = zone }
        ctx.insert(row)
        return row
    }

    /// A classifier primed with a 10 km square per `squares` entry, then a
    /// 1 km fallback disc at each of `discs`.
    static func classifier(
        _ container: ModelContainer, squares: [(id: Int64, place: Place)], discs: [Place] = []
    ) async -> TripClassifier {
        let classifier = TripClassifier(modelContainer: container)
        for (id, place) in squares {
            await classifier.primeShapeForTesting(
                latitude: place.lat, longitude: place.lon,
                shape: squareShape(id: id, around: place))
        }
        for place in discs {
            await classifier.primeShapeForTesting(
                latitude: place.lat, longitude: place.lon,
                shape: .fallbackDisc(latitude: place.lat, longitude: place.lon))
        }
        return classifier
    }

    /// One ordinary pipeline pass.
    static func ordinaryPass(_ classifier: TripClassifier) async {
        _ = await classifier.classifyAndAssembleTripsWithGates(
            maxStaysPerCall: nil, gate: PipelineGate(forTesting: ()))
    }
}
