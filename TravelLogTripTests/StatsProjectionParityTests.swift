//
//  StatsProjectionParityTests.swift
//  TravelLogTests
//
//  Oracle for the Stats fetch projection:
//  `StatsAggregator.compute` now fetches Stay rows with `propertiesToFetch`
//  limited to the enumerated read surface, keeping `weatherData` blobs and
//  `pingIDsString` out of every recompute. The contract is EXACT output
//  equality against the full-fetch reference lane
//  (`usingProjection: false`), compared field-by-field over the whole
//  `Aggregates` value - every card, collection, passport row, and On This
//  Day group at once. The seeded store deliberately carries fat
//  weather blobs and long ping-ID strings so the exclusion is exercised,
//  and populates every fetched lane (visited/transit/unclassified stays,
//  trips, hexes, homes) so parity is not vacuous.
//
//  This oracle guards output
//  CORRECTNESS - any SwiftData projection behavior that changes a value
//  (defaults instead of stored data, broken relationship traversal). It
//  CANNOT detect a property omitted from the lists: SwiftData lazily
//  faults omitted properties in on access, so the output stays identical
//  and only the per-row fetch cost regresses. The guard for omissions is
//  the enumeration contract documented on `aggregateStayProperties` /
//  `predecessorStayProperties` themselves.
//
//  An env-gated twin runs the same comparison over an externally supplied captured fixture.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
@Suite("Stats fetch projection parity")
struct StatsProjectionParityTests {

    private static let base = Date(timeIntervalSinceReferenceDate: 1_028 * 86_400)
    private func d(_ days: Double) -> Date { Self.base.addingTimeInterval(days * 86_400) }

    /// Field-by-field comparison so a failure names the diverging card
    /// instead of dumping two multi-kilobyte JSON blobs.
    private func expectFieldParity(
        _ a: StatsAggregator.Aggregates, _ b: StatsAggregator.Aggregates,
        context: String
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func check<T: Encodable>(_ name: String, _ keyPath: KeyPath<StatsAggregator.Aggregates, T>) throws {
            let lhs = try encoder.encode(a[keyPath: keyPath])
            let rhs = try encoder.encode(b[keyPath: keyPath])
            #expect(lhs == rhs, "\(context): field '\(name)' diverged")
        }
        try check("computeDegraded", \.computeDegraded)
        try check("totalPings", \.totalPings)
        try check("totalStays", \.totalStays)
        try check("totalHexes", \.totalHexes)
        try check("totalTrips", \.totalTrips)
        try check("trackingSince", \.trackingSince)
        try check("newHexesThisYear", \.newHexesThisYear)
        try check("newHexesByYear", \.newHexesByYear)
        try check("topHexCountries", \.topHexCountries)
        try check("flightCount", \.flightCount)
        try check("onThisDayGroups", \.onThisDayGroups)
        // Set equality directly - JSON encodes a Set in iteration order,
        // which legitimately differs between two computes (same elements).
        #expect(a.uniqueCountries == b.uniqueCountries,
                "\(context): field 'uniqueCountries' diverged")
        try check("countryStats", \.countryStats)
        try check("lastTrip", \.lastTrip)
        try check("passportData", \.passportData)
        try check("collections", \.collections)
        try check("homeHexCountries", \.homeHexCountries)
        try check("travelDaysThisYear", \.travelDaysThisYear)
        try check("travelDaysTotal", \.travelDaysTotal)
        try check("yearStats", \.yearStats)
        try check("favoriteMonth", \.favoriteMonth)
        try check("favoriteMonthDays", \.favoriteMonthDays)
        try check("awayDaysTotal", \.awayDaysTotal)
        try check("awayDaysThisYear", \.awayDaysThisYear)
        try check("stayingDaysTotal", \.stayingDaysTotal)
    }

    @discardableResult
    private func makeStay(
        _ ctx: ModelContext, category: StayCategory, startDay: Double, endDay: Double,
        lat: Double, lon: Double, hex: String, locality: String?, iso: String?,
        distanceFromHome: Double
    ) -> Stay {
        let stay = Stay(
            startTime: d(startDay), endTime: d(endDay),
            centroidLatitude: lat, centroidLongitude: lon,
            h3IndexRes6: hex, pingCount: 4,
            distanceFromHomeKm: distanceFromHome,
            // Long ping-ID string - one of the two heavy columns the
            // projection exists to exclude.
            pingIDs: (0..<40).map { _ in UUID() }
        )
        stay.category = category
        stay.locality = locality
        stay.isoCountryCode = iso
        stay.country = iso == "GR" ? "Greece" : iso == "IT" ? "Italy" : nil
        stay.administrativeArea = "Region-\(hex)"
        // Fat weather blob + the scalar fields the passport rows read.
        stay.weatherData = Data(repeating: 0xAB, count: 32_768)
        stay.avgTemperatureC = 18 + lat.truncatingRemainder(dividingBy: 7)
        stay.weatherConditionRaw = "clear"
        ctx.insert(stay)
        return stay
    }

    private func seedStore(_ container: ModelContainer) throws {
        let ctx = ModelContext(container)

        let home = Home(label: "Home", latitude: 37.98, longitude: 23.72, radiusKm: 25,
                        startedAt: d(-30))
        home.isoCountryCode = "GR"
        ctx.insert(home)

        let trip = Trip(startDate: d(10))
        trip.endDate = d(14)
        trip.isComplete = true
        ctx.insert(trip)

        // Visited lane: home + routine + destinations (two countries so
        // countryStats/passport/flags all populate).
        makeStay(ctx, category: .home, startDay: 0, endDay: 2,
                 lat: 37.98, lon: 23.72, hex: "861eda747ffffff",
                 locality: "Athens", iso: "GR", distanceFromHome: 0)
        makeStay(ctx, category: .routine, startDay: 2, endDay: 2.2,
                 lat: 38.02277, lon: 23.8576, hex: "861eda2b7ffffff",
                 locality: "Gérakas", iso: "GR", distanceFromHome: 6)
        let cephalonia = makeStay(ctx, category: .destination, startDay: 10, endDay: 12,
                             lat: 38.20133, lon: 20.43706, hex: "863f2c087ffffff",
                             locality: "Lixoúri", iso: "GR", distanceFromHome: 160)
        cephalonia.islandName = "Cephalonia"
        cephalonia.trip = trip
        let rome = makeStay(ctx, category: .destination, startDay: 12.5, endDay: 14,
                            lat: 41.90, lon: 12.49, hex: "861e8052fffffff",
                            locality: "Rome", iso: "IT", distanceFromHome: 1050)
        rome.metroName = "Rome"
        rome.trip = trip
        rome.transitFromPreviousRaw = TransitMode.flight.rawValue
        rome.distanceFromPreviousKm = 1050

        // Transit lane: an airport stay (flight-leg endpoint + aerial hex rule).
        let airport = makeStay(ctx, category: .transit, startDay: 12.4, endDay: 12.45,
                               lat: 37.936, lon: 23.946, hex: "861eda29fffffff",
                               locality: "Airport", iso: "GR", distanceFromHome: 30)
        airport.isAirport = true

        // Unclassified lane: joins the Collections predecessor walk only.
        makeStay(ctx, category: .unclassified, startDay: 12.46, endDay: 12.48,
                 lat: 38.90, lon: 16.60, hex: "863f244efffffff",
                 locality: "Calabria Stop", iso: "IT", distanceFromHome: 700)

        let visitedCells = [
            (37.98, 23.72, "861eda747ffffff"),
            (38.20133, 20.43706, "863f2c087ffffff"),
            (41.90, 12.49, "861e8052fffffff"),
        ]
        for (i, coords) in visitedCells.enumerated() {
            let hexVisit = HexVisit(
                h3Index: coords.2, firstVisited: d(Double(i)),
                centerLatitude: coords.0, centerLongitude: coords.1
            )
            hexVisit.isoCountryCode = i == 2 ? "IT" : "GR"
            hexVisit.country = i == 2 ? "Italy" : "Greece"
            ctx.insert(hexVisit)
        }

        for i in 0..<5 {
            ctx.insert(LocationPing(
                timestamp: d(Double(i) * 0.1),
                latitude: 37.98, longitude: 23.72,
                horizontalAccuracy: 30, h3IndexRes6: "861eda747ffffff", source: .liveSLC
            ))
        }
        try ctx.save()
    }

    @Test("projected compute equals full-fetch compute over a seeded store carrying fat excluded columns")
    func seededStoreParity() throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedStore(container)
        let now = d(20)

        let projected = try StatsAggregator.compute(
            container: container, now: now, usingProjection: true)
        let full = try StatsAggregator.compute(
            container: container, now: now, usingProjection: false)

        // Parity must not be vacuous: the reference lane saw real data on
        // every fetched surface.
        #expect(full.totalStays == 6)
        #expect(full.totalHexes == 3)
        #expect(full.flightCount == 1)
        #expect(full.uniqueCountries.contains("IT"))
        #expect(full.computeDegraded == nil)

        try expectFieldParity(projected, full,
                              context: "projected-vs-full over the seeded store (the projection CHANGED a value)")
    }

    @Test("projected compute equals full-fetch compute when a temporary home adds staying days")
    func temporaryHomeParity() throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedStore(container)
        let ctx = ModelContext(container)
        // A stay in Rome from day 14, ended on day 22. The trip covers days 10 to 14.
        let rome = TemporaryHome(label: "Rome", latitude: 41.90, longitude: 12.49,
                                 startedAt: d(14), endedAt: d(22))
        ctx.insert(rome)
        // Recorded by Rome, as the classifier stamps a home stay inside its dates.
        makeStay(ctx, category: .home, startDay: 14.5, endDay: 18,
                 lat: 41.90, lon: 12.49, hex: "861e8052fffffff",
                 locality: "Rome", iso: "IT", distanceFromHome: 0).temporaryHomeID = rome.id
        // The unclassified lane supplies the run's latest end, so its start
        // and end must survive the predecessor projection.
        makeStay(ctx, category: .unclassified, startDay: 18.5, endDay: 19.5,
                 lat: 41.80, lon: 12.60, hex: "861e8042fffffff",
                 locality: nil, iso: "IT", distanceFromHome: 0)
        try ctx.save()
        let now = d(25)
        let utc = TravelDays.labelCalendar

        let projected = try StatsAggregator.compute(
            container: container, now: now, usingProjection: true, calendar: utc)
        let full = try StatsAggregator.compute(
            container: container, now: now, usingProjection: false, calendar: utc)

        // Not vacuous: days 14 to 19 at the temporary home, day 14 already a trip day.
        #expect(full.travelDaysTotal == 5)
        #expect(full.travelDaysThisYear == 5)
        #expect(full.yearStats?.reduce(0) { $0 + $1.days } == 5)
        #expect(full.favoriteMonthDays == 5)
        #expect(full.stayingDaysTotal == 5)
        #expect(full.awayDaysTotal == 10)
        #expect(full.awayDaysThisYear == 10)
        #expect(full.passportData.daysAbroad == 10)
        #expect(full.countryStats.first(where: { $0.code == "IT" })?.isTemporaryHome == true)
        #expect(full.computeDegraded == nil)

        try expectFieldParity(projected, full,
                              context: "projected-vs-full with a temporary home")
    }

    @Test("with no temporary home, compute equals the reducer called without anchors and sets none of the temporary-home fields")
    func noTemporaryHomeLeavesAggregatesUnchanged() throws {
        let container = try TestSupport.makeInMemoryContainer()
        try seedStore(container)
        let now = d(20)
        let utc = TravelDays.labelCalendar

        let computed = try StatsAggregator.compute(
            container: container, now: now, usingProjection: false, calendar: utc)

        // The same rows, fetched the way compute fetches them, through the
        // reducer's call shape from before temporary homes existed.
        let ctx = ModelContext(container)
        let visited = try ctx.fetch(FetchDescriptor<Stay>(predicate: Stay.visitedCategoriesPredicate()))
        let transit = try ctx.fetch(FetchDescriptor<Stay>(predicate: Stay.transitCategoryPredicate()))
        let unclassified = try ctx.fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.categoryRaw == "unclassified" }))
        let trips = try ctx.fetch(FetchDescriptor<Trip>())
        let hexVisits = try ctx.fetch(FetchDescriptor<HexVisit>())
        let reference = StatsAggregator.aggregate(
            visitedStays: visited, transitStays: transit, unclassifiedStays: unclassified,
            trips: trips, hexVisits: hexVisits,
            totalPings: 5, totalStays: 6, flightCount: 1, trackingSince: d(0),
            homeCountryCodes: ["GR"], now: now, calendar: utc)

        try expectFieldParity(computed, reference,
                              context: "compute-vs-reducer with no temporary home")
        #expect(computed.travelDaysTotal == 5)
        #expect(computed.passportData.daysAbroad == 5)
        #expect(computed.awayDaysTotal == nil)
        #expect(computed.awayDaysThisYear == nil)
        #expect(computed.stayingDaysTotal == nil)
        #expect(computed.passportData.daysAtTemporaryHomes == nil)
        #expect(computed.countryStats.allSatisfy { $0.isTemporaryHome == nil })
        #expect(computed.countryStats.first(where: { $0.code == "GR" })?.isHome == true)
    }

    /// Destination reads test trip membership per stay; an unprojected
    /// to-one reference faults the full row, weather and ping payloads included.
    @Test("aggregate projection includes the to-one trip reference")
    func aggregateProjectionIncludesTrip() {
        #expect(StatsAggregator.aggregateStayProperties.contains(\Stay.trip as PartialKeyPath<Stay>))
    }

    // MARK: - Captured-fixture twin (same env contract as the migration replay)

    nonisolated private static var fixtureURL: URL? {
        guard let raw = ProcessInfo.processInfo.environment["TRAVELLOG_REAL_FIXTURE"],
              !raw.isEmpty else { return nil }
        let url = URL(fileURLWithPath: raw)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @Test("projected compute equals full-fetch compute over a captured historical store", .enabled(
        if: StatsProjectionParityTests.fixtureURL != nil,
        "Point TRAVELLOG_REAL_FIXTURE at a captured historical store to run the projection parity replay"
    ))
    func realFixtureParity() throws {
        let fixture = try #require(Self.fixtureURL)
        let schema = Schema(versionedSchema: CurrentTravelLogSchema.self)
        let configuration = ModelConfiguration(
            "StatsProjectionParity-\(UUID().uuidString)", schema: schema,
            isStoredInMemoryOnly: false, cloudKitDatabase: .none)

        let fm = FileManager.default
        try? fm.createDirectory(at: configuration.url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        // Cleanup registered BEFORE the fallible copy loop, so a mid-family
        // copy failure can't leave earlier files behind.
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? fm.removeItem(at: URL(fileURLWithPath: configuration.url.path + suffix))
            }
        }
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: configuration.url.path + suffix))
            let sidecar = URL(fileURLWithPath: fixture.path + suffix)
            guard fm.fileExists(atPath: sidecar.path) else { continue }
            try fm.copyItem(at: sidecar,
                            to: URL(fileURLWithPath: configuration.url.path + suffix))
            try? fm.setAttributes([.posixPermissions: 0o644],
                                  ofItemAtPath: configuration.url.path + suffix)
        }
        // The fixture is a V14 store - the copy opens through the migration
        // plan exactly like the production opener.
        let container = try ModelContainer(
            for: schema, migrationPlan: TravelLogMigrationPlan.self,
            configurations: [configuration])

        // Fixed `now` so both lanes see identical ongoing-trip elapsed time.
        let now = Date(timeIntervalSinceReferenceDate: 1_048 * 86_400)

        let projected = try StatsAggregator.compute(
            container: container, now: now, usingProjection: true)
        let full = try StatsAggregator.compute(
            container: container, now: now, usingProjection: false)
        // Determinism control: two runs of the SAME lane must agree, or any
        // projected-vs-full difference is fetch-order noise, not the projection.
        let fullRepeat = try StatsAggregator.compute(
            container: container, now: now, usingProjection: false)

        try #require(full.totalStays > 0, "fixture unexpectedly empty — parity would be vacuous")
        try expectFieldParity(full, fullRepeat,
                              context: "full-vs-full (compute is NONDETERMINISTIC on this store)")
        try expectFieldParity(projected, full,
                              context: "projected-vs-full (the projection CHANGED a value — SwiftData partial-fetch misbehavior)")
    }
}
