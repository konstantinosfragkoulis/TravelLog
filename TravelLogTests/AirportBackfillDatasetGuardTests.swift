//
//  AirportBackfillDatasetGuardTests.swift
//  TravelLogTests
//
//  An airports.json read failure leaves the detector empty, so every
//  proximity query answers false. The launch backfill must treat that as a
//  failed read, not as "no airports": it writes nothing and reports
//  not-saved, so its one-shot latch stays unset and the pass retries. A
//  loaded one re-stamps each flag from the airport's own ring and hands a
//  stay whose flag moved back to classification.
//

import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import TravelLog

@MainActor
struct AirportBackfillDatasetGuardTests {

    @Test("an unloaded airport dataset keeps every airport flag and leaves the backfill unlatched")
    func unloadedDatasetChangesNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // Generic fixture: a flagged stay and an unflagged one, anywhere.
        let flagged = Stay(
            startTime: start, endTime: start.addingTimeInterval(3600),
            centroidLatitude: 10, centroidLongitude: 10,
            h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 20, pingIDs: []
        )
        flagged.isAirport = true
        let unflagged = Stay(
            startTime: start, endTime: start.addingTimeInterval(3600),
            centroidLatitude: 20, centroidLongitude: 20,
            h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 300, pingIDs: []
        )
        unflagged.isAirport = false
        ctx.insert(flagged)
        ctx.insert(unflagged)
        try ctx.save()

        let result = await AppDelegate.backfillAirports(modelContainer: container, datasetLoaded: false)
        // saved:false is what keeps runAirportBackfillIfNeeded from latching.
        #expect(!result.saved)
        #expect(result.flagged == 0)

        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(stays.count == 2)
        for stay in stays {
            #expect(stay.isAirport == (stay.distanceFromHomeKm == 20))
        }
    }

    @Test("a stay the old 3 km ring flagged is cleared and judged again; a user's label stays")
    func clearedFlagHandsTheStayBack() async throws {
        let detector = AirportDetector.shared
        // A short-runway field with no other airport for 6 km; a town 2 km
        // off sat inside the old flat ring, outside the field's own.
        let field = try #require(detector.allAirports.first { airport in
            airport.ringMeters <= 1600 && detector.airports(
                near: CLLocationCoordinate2D(latitude: airport.lat, longitude: airport.lon),
                radiusMeters: 6000).count == 1
        })
        let town = (lat: field.lat + 2000.0 / 111_320.0, lon: field.lon)
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func stay(hours: Double, overridden: Bool) -> Stay {
            let stay = Stay(
                startTime: start, endTime: start.addingTimeInterval(hours * 3600),
                centroidLatitude: town.lat, centroidLongitude: town.lon,
                h3IndexRes6: "", pingCount: 4, distanceFromHomeKm: 300, pingIDs: [])
            stay.isAirport = true
            stay.category = .transit
            stay.userOverridden = overridden
            return stay
        }
        let automatic = stay(hours: 6, overridden: false)
        let chosen = stay(hours: 5, overridden: true)
        ctx.insert(automatic)
        ctx.insert(chosen)
        try ctx.save()

        let result = await AppDelegate.backfillAirports(modelContainer: container)
        #expect(result.saved)
        #expect(result.flagged == 2)

        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(stays.allSatisfy { !$0.isAirport })
        #expect(stays.first { !$0.userOverridden }?.category == .unclassified)
        #expect(stays.first { $0.userOverridden }?.category == .transit)
    }
}
