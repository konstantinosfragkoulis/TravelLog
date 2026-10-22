//
//  AirportBackfillDatasetGuardTests.swift
//  TravelLogTests
//
//  An airports.json read failure leaves the detector empty, so every
//  proximity query answers false. The launch backfill must treat that as a
//  failed read, not as "no airports": it writes nothing and reports
//  not-saved, so its one-shot latch stays unset and the pass retries.
//

import Testing
import Foundation
import SwiftData
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
}
