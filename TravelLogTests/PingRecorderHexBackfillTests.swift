//
//  PingRecorderHexBackfillTests.swift
//  TravelLogTests
//
//  Pins `backfillHexVisitCountries(gate:)`'s outcome: its units bump
//  `.hexVisit` only when the heal actually saved, so a no-op launch must
//  report no healed rows and leave the row untouched. The resolver is pinned off so
//  the outcome does not depend on Geocoder.sqlite being in the test host.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("PingRecorder hex visit backfill", .timeLimit(.minutes(1)))
struct PingRecorderHexBackfillTests {

    @Test("a hex with no donor ping and no resolver hit reports no change")
    func noDonorReportsNoChange() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let hex = try #require(H3Service.cellIndex(latitude: 0, longitude: -140))
        context.insert(HexVisit(h3Index: hex, firstVisited: .distantPast,
            centerLatitude: 0, centerLongitude: -140))
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let outcome = await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in nil }) {
            await recorder.backfillHexVisitCountries(gate: PipelineGate(forTesting: ()))
        }

        #expect(outcome == PingRecorder.HexHealOutcome(healed: 0, completed: true))
        let row = try #require(ModelContext(container).fetch(FetchDescriptor<HexVisit>()).first)
        #expect(row.locality == nil)
        #expect(row.country == nil)
        #expect(row.isoCountryCode == nil)
    }

    @Test("a geocoded donor ping in the same cell heals the hex and reports a change")
    func donorPingHealsHex() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let latitude = 37.9838
        let longitude = 23.7275
        let hex = try #require(H3Service.cellIndex(latitude: latitude, longitude: longitude))
        let visit = HexVisit(h3Index: hex, firstVisited: .distantPast,
            centerLatitude: latitude, centerLongitude: longitude)
        visit.locality = "Athens"
        context.insert(visit)
        let ping = LocationPing(timestamp: Date(timeIntervalSince1970: 1_586_089_600),
            latitude: latitude, longitude: longitude, horizontalAccuracy: 10, h3IndexRes6: hex)
        ping.isGeocoded = true
        ping.locality = "Athens"
        ping.country = "Greece"
        ping.isoCountryCode = "GR"
        context.insert(ping)
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let outcome = await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in nil }) {
            await recorder.backfillHexVisitCountries(gate: PipelineGate(forTesting: ()))
        }

        #expect(outcome == PingRecorder.HexHealOutcome(healed: 1, completed: true))
        let row = try #require(ModelContext(container).fetch(FetchDescriptor<HexVisit>()).first)
        #expect(row.locality == "Athens")
        #expect(row.country == "Greece")
        #expect(row.isoCountryCode == "GR")
    }
}
