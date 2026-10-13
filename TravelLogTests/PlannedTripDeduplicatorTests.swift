//
//  PlannedTripDeduplicatorTests.swift
//  TravelLogTests
//
//  Cross-device convergence for duplicate PlannedTrip rows — synthetic
//  duplicate sets over an in-memory container, same style as the other
//  deduplicator suites.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct PlannedTripDeduplicatorTests {

    private let start = Date(timeIntervalSince1970: 1_826_006_400)

    private func makeRow(
        _ context: ModelContext,
        external: String? = "ext-1",
        local: String = "local-A",
        startDate: Date? = nil,
        createdAt: Date,
        status: PlannedTripStatus = .upcoming,
        matchedTripID: UUID? = nil,
        lastSeenAt: Date? = nil
    ) -> PlannedTrip {
        let row = PlannedTrip(
            eventExternalIdentifier: external,
            eventLocalIdentifier: local,
            title: "Trip to Cephalonia",
            startDate: startDate ?? start,
            endDate: (startDate ?? start).addingTimeInterval(4 * 86_400),
            isAllDay: false,
            locationText: nil
        )
        row.createdAt = createdAt
        row.status = status
        row.matchedTripID = matchedTripID
        row.lastSeenAt = lastSeenAt ?? createdAt
        context.insert(row)
        return row
    }

    @Test func duplicatesCollapseToOldestByCreatedAt() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let older = makeRow(context, local: "local-A", createdAt: start.addingTimeInterval(-7200))
        _ = makeRow(context, local: "local-B", createdAt: start.addingTimeInterval(-3600))
        try context.save()

        await PlannedTripDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try context.fetch(FetchDescriptor<PlannedTrip>())
        #expect(rows.count == 1)
        #expect(rows.first?.id == older.id)
    }

    /// Red/green pin: the survivor is chosen by
    /// AGE, which says nothing about how much enrichment a row carries. Two-
    /// device onboarding routinely leaves one row forward-geocoded and
    /// forecast-filled while the other is bare — and if the bare one is older,
    /// the merge used to discard all of it. Nothing re-derives it: the scan's
    /// resolution pass only visits still-unresolved rows, and the lost
    /// `distanceFromHomeKm` drives detection signal 4 (+3, far-from-home), so
    /// the card can drop below the display cutoff and vanish.
    @Test func survivorAbsorbsResolvedLocationForecastAndSignals() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        // Older row wins on age but did no resolution work at all.
        let survivor = makeRow(context, local: "local-A", createdAt: start.addingTimeInterval(-7200))
        #expect(survivor.resolvedLatitude == nil)

        // The younger duplicate is the one that actually resolved.
        let enriched = makeRow(context, local: "local-B", createdAt: start.addingTimeInterval(-3600))
        enriched.resolvedLatitude = 38.1994
        enriched.resolvedLongitude = 20.4373
        enriched.resolvedLocality = "Lixoúri"
        enriched.resolvedCountry = "Greece"
        enriched.resolvedISOCountryCode = "GR"
        enriched.distanceFromHomeKm = 289.6
        enriched.forecastWeatherData = Data("forecast-blob".utf8)
        enriched.confidence = .high
        enriched.signals = ["farFromHome", "booking"]
        // (Confidence is NOT monotonic — `applyScan` re-stamps it per scan and
        // can lower it. Taking the max here is a deterministic merge rule, not
        // a claim that confidence only rises.)

        survivor.signals = ["multiDay"]
        try context.save()

        await PlannedTripDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try context.fetch(FetchDescriptor<PlannedTrip>())
        #expect(rows.count == 1)
        let merged = try #require(rows.first)
        #expect(merged.id == survivor.id)

        // The whole geocode travels as one unit — never a name from one
        // resolution at another's coordinates.
        #expect(merged.resolvedLatitude == 38.1994)
        #expect(merged.resolvedLongitude == 20.4373)
        #expect(merged.resolvedLocality == "Lixoúri")
        #expect(merged.resolvedCountry == "Greece")
        #expect(merged.resolvedISOCountryCode == "GR")

        #expect(merged.distanceFromHomeKm == 289.6)
        #expect(merged.forecastWeatherData == Data("forecast-blob".utf8))
        // Confidence only ever rises as signals accumulate; take the strongest.
        #expect(merged.confidence == .high)
        // Signals are evidence tags — the union, sorted for byte-identical
        // `signalsRaw` across devices.
        #expect(merged.signals == ["booking", "farFromHome", "multiDay"])
    }

    /// The resolution is ONE unit: `distanceFromHomeKm` and the forecast are
    /// each computed FROM a specific coordinate, so they may only come from
    /// the row that supplied that coordinate. Folding them independently could
    /// pair row X's place name with row Y's distance — detection signal 4
    /// measured against a location the row no longer claims.
    @Test func enrichmentNeverMixesTwoDifferentResolutions() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        // Survivor (oldest) resolved nothing at all.
        let survivor = makeRow(context, local: "local-A", createdAt: start.addingTimeInterval(-7200))

        // Donor X — lower uuid wins the resolved-location fold, but it never
        // measured a distance or fetched a forecast.
        let x = makeRow(context, local: "local-B", createdAt: start.addingTimeInterval(-3600))
        x.resolvedLatitude = 38.1994
        x.resolvedLongitude = 20.4373
        x.resolvedLocality = "Lixoúri"

        // Donor Y resolved somewhere ELSE and stamped values for ITS place.
        let y = makeRow(context, local: "local-C", createdAt: start.addingTimeInterval(-1800))
        y.resolvedLatitude = 48.8335
        y.resolvedLongitude = 2.4138
        y.resolvedLocality = "Paris"
        y.distanceFromHomeKm = 2093.8
        y.forecastWeatherData = Data("paris-forecast".utf8)

        // Force X to be the min-uuid resolved donor regardless of generated ids.
        let (lower, higher) = x.id.uuidString < y.id.uuidString ? (x, y) : (y, x)
        try context.save()

        await PlannedTripDeduplicator.deduplicateAll(modelContainer: container)

        let merged = try #require(try context.fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(merged.id == survivor.id)
        // Whichever row won the coordinate, the derived values must be ITS own
        // — never the other resolution's.
        #expect(merged.resolvedLatitude == lower.resolvedLatitude)
        #expect(merged.resolvedLocality == lower.resolvedLocality)
        #expect(merged.distanceFromHomeKm == lower.distanceFromHomeKm)
        #expect(merged.forecastWeatherData == lower.forecastWeatherData)
        // Pre-fix, the independent min-uuid folds could hand the survivor
        // `higher`'s distance/forecast alongside `lower`'s place.
        if lower.distanceFromHomeKm == nil {
            #expect(merged.distanceFromHomeKm != higher.distanceFromHomeKm)
        }
    }

    @Test func alreadyResolvedSurvivorIsNotOverwrittenByALoser() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        let survivor = makeRow(context, local: "local-A", createdAt: start.addingTimeInterval(-7200))
        survivor.resolvedLatitude = 37.9838
        survivor.resolvedLongitude = 23.7275
        survivor.resolvedLocality = "Athens"
        survivor.distanceFromHomeKm = 0.5

        let other = makeRow(context, local: "local-B", createdAt: start.addingTimeInterval(-3600))
        other.resolvedLatitude = 38.1994
        other.resolvedLongitude = 20.4373
        other.resolvedLocality = "Lixoúri"
        other.distanceFromHomeKm = 289.6
        try context.save()

        await PlannedTripDeduplicator.deduplicateAll(modelContainer: container)

        let merged = try #require(try context.fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(merged.resolvedLocality == "Athens")
        #expect(merged.resolvedLatitude == 37.9838)
        #expect(merged.distanceFromHomeKm == 0.5)
    }

    @Test func survivorAbsorbsMostAdvancedStatusAndNewestLastSeen() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let tripID = UUID()
        // Older row (survivor) is still .upcoming; the newer duplicate was
        // matched on the other device and was seen more recently.
        let survivor = makeRow(context, local: "local-A", createdAt: start.addingTimeInterval(-7200))
        _ = makeRow(
            context, local: "local-B",
            createdAt: start.addingTimeInterval(-3600),
            status: .matched, matchedTripID: tripID,
            lastSeenAt: start.addingTimeInterval(9999)
        )
        try context.save()

        await PlannedTripDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try context.fetch(FetchDescriptor<PlannedTrip>())
        #expect(rows.count == 1)
        #expect(rows.first?.id == survivor.id)
        #expect(rows.first?.status == .matched)
        #expect(rows.first?.matchedTripID == tripID)
        #expect(rows.first?.lastSeenAt == start.addingTimeInterval(9999))
    }

    @Test func dismissalOnEitherDeviceSurvivesTheMerge() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let survivor = makeRow(context, local: "local-A", createdAt: start.addingTimeInterval(-7200))
        _ = makeRow(
            context, local: "local-B",
            createdAt: start.addingTimeInterval(-3600),
            status: .dismissed
        )
        try context.save()

        await PlannedTripDeduplicator.deduplicateAll(modelContainer: container)

        let rows = try context.fetch(FetchDescriptor<PlannedTrip>())
        #expect(rows.count == 1)
        #expect(rows.first?.id == survivor.id)
        #expect(rows.first?.status == .dismissed)
    }

    @Test func recurrenceInstancesAreDistinctIdentitiesNotDuplicates() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // Same event identifiers, different startDates — two expanded
        // occurrences of one recurring event. Must NOT merge.
        _ = makeRow(context, startDate: start, createdAt: start.addingTimeInterval(-7200))
        _ = makeRow(context, startDate: start.addingTimeInterval(7 * 86_400), createdAt: start.addingTimeInterval(-7200))
        try context.save()

        await PlannedTripDeduplicator.deduplicateAll(modelContainer: container)

        #expect(try context.fetch(FetchDescriptor<PlannedTrip>()).count == 2)
    }

    @Test func nilExternalIdentifiersFallBackToLocalAndStayApart() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // Local-only calendars have no external identifier; per-device local
        // ids differ, so cross-"device" rows deliberately don't merge
        // (local calendars can't sync, so real duplicates can't occur).
        _ = makeRow(context, external: nil, local: "device-1-id", createdAt: start.addingTimeInterval(-7200))
        _ = makeRow(context, external: nil, local: "device-2-id", createdAt: start.addingTimeInterval(-3600))
        try context.save()

        await PlannedTripDeduplicator.deduplicateAll(modelContainer: container)

        #expect(try context.fetch(FetchDescriptor<PlannedTrip>()).count == 2)
    }

    @Test func convergenceIsOrderIndependent() async throws {
        // Both "devices" hold the same three duplicate rows; whichever order
        // the dedup encounters them in, the surviving (id, status) pair is
        // identical — the deterministic-survivor requirement every dedup
        // in this app satisfies.
        func run(_ createdOffsets: [(String, TimeInterval, PlannedTripStatus)]) async throws -> (UUID, PlannedTripStatus) {
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            for (local, offset, status) in createdOffsets {
                let row = makeRow(context, local: local, createdAt: start.addingTimeInterval(offset), status: status)
                // Fixed UUIDs so both runs agree on identity tiebreaks.
                row.id = UUID(uuidString: "00000000-0000-0000-0000-00000000000\(local.last!)")!
                try context.save()
            }
            await PlannedTripDeduplicator.deduplicateAll(modelContainer: container)
            let rows = try context.fetch(FetchDescriptor<PlannedTrip>())
            let row = try #require(rows.first)
            #expect(rows.count == 1)
            return (row.id, row.status)
        }

        let a = try await run([("l1", -7200, .upcoming), ("l2", -3600, .expired), ("l3", -1800, .dismissed)])
        let b = try await run([("l3", -1800, .dismissed), ("l1", -7200, .upcoming), ("l2", -3600, .expired)])
        #expect(a == b)
        #expect(a.1 == .dismissed)
    }

    /// UUID twins tied on the survivor's (createdAt, id) name no single row:
    /// opposite fetch orders would let two devices delete each other's twin.
    @Test func ambiguousSurvivorTwinsAreRetained() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let created = start.addingTimeInterval(-7200)
        let first = makeRow(context, local: "local-A", createdAt: created, status: .dismissed)
        let twin = makeRow(context, local: "local-B", createdAt: created)
        twin.id = first.id
        _ = makeRow(context, local: "local-C", createdAt: start.addingTimeInterval(-3600))
        try context.save()

        #expect(await PlannedTripDeduplicator.deduplicateAll(modelContainer: container))

        let rows = try ModelContext(container).fetch(FetchDescriptor<PlannedTrip>())
        #expect(rows.count == 3)
        #expect(rows.filter { $0.id == first.id }.count == 2)
        #expect(rows.filter { $0.status == .dismissed }.count == 1)
    }

    @Test func statusPriorityOrdering() {
        #expect(PlannedTripDeduplicator.statusPriority(.matched) > PlannedTripDeduplicator.statusPriority(.dismissed))
        #expect(PlannedTripDeduplicator.statusPriority(.dismissed) > PlannedTripDeduplicator.statusPriority(.expired))
        #expect(PlannedTripDeduplicator.statusPriority(.expired) > PlannedTripDeduplicator.statusPriority(.upcoming))
    }
}
