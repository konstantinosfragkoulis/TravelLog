//
//  PassportSummaryParityTests.swift
//  TravelLogTests
//
//  Compares `StatsAggregator.passportSummary` with the full
//  `compute` pipeline: the focused fetch exists so TravelStatsIntent stops
//  paying for Collections/HexVisibility/On-This-Day to answer four counters,
//  and this parity test keeps the two paths consistent:
//  if the two paths ever disagree on countries/trips/daysAbroad/flights,
//  Siri and the Stats tab give different answers to the same question.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct PassportSummaryParityTests {

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    @discardableResult
    private func stay(
        _ ctx: ModelContext, category: StayCategory, iso: String?,
        start: Date, hours: Double = 5, flightLeg: Bool = false, trip: Trip? = nil
    ) -> Stay {
        let s = Stay(startTime: start, endTime: start.addingTimeInterval(hours * 3600),
                     centroidLatitude: 37.9, centroidLongitude: 23.7,
                     h3IndexRes6: "8a1eda62934ffff", pingCount: 3,
                     distanceFromHomeKm: 250, pingIDs: [])
        s.category = category
        s.isoCountryCode = iso
        if flightLeg { s.transitFromPreviousRaw = TransitMode.flight.rawValue }
        ctx.insert(s)
        if let trip { s.trip = trip }
        return s
    }

    @discardableResult
    private func trip(
        _ ctx: ModelContext, start: Date, days: Int, codes: String, complete: Bool = true
    ) -> Trip {
        let t = Trip(startDate: start)
        t.isComplete = complete
        if complete { t.endDate = start.addingTimeInterval(Double(days) * 86_400) }
        t.countryCodes = codes
        ctx.insert(t)
        return t
    }

    @Test("focused summary matches the full compute on a representative mixed store")
    func passportSummaryMatchesFullCompute() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        // Visited stays across all three visited categories, with a nil-ISO
        // row and a tripless destination residue row (both are part of the
        // canonical uniqueCountries semantics and must match in both paths).
        stay(ctx, category: .home, iso: "GR", start: utc(2025, 1, 10))
        stay(ctx, category: .routine, iso: "GR", start: utc(2025, 2, 3))
        stay(ctx, category: .destination, iso: "IT", start: utc(2025, 5, 2))
        stay(ctx, category: .destination, iso: nil, start: utc(2025, 5, 3))
        stay(ctx, category: .destination, iso: "JP", start: utc(2025, 9, 1))   // tripless residue
        // Non-visited categories must not contribute countries.
        stay(ctx, category: .transit, iso: "AE", start: utc(2025, 5, 1), flightLeg: true)
        stay(ctx, category: .unclassified, iso: "TR", start: utc(2025, 6, 1))

        // Completed trips carry their own countryCodes (the second source of
        // the union — includes "FR", which no stay carries) and durations.
        let rome = trip(ctx, start: utc(2025, 5, 1), days: 4, codes: "IT")
        stay(ctx, category: .destination, iso: "IT", start: utc(2025, 5, 2, 18), trip: rome)
        trip(ctx, start: utc(2024, 7, 1), days: 10, codes: "FR,IT")
        // Ongoing trip contributes travel dates, but not completed-trip count.
        trip(ctx, start: utc(2026, 8, 1), days: 0, codes: "ES", complete: false)

        // A second flight leg on a destination stay (flights count ANY category).
        stay(ctx, category: .destination, iso: "GB", start: utc(2024, 7, 2), flightLeg: true,
             trip: nil)
        try ctx.save()

        let now = utc(2026, 8, 3)
        let full = try StatsAggregator.compute(
            container: container, now: now)
        let focused = try StatsAggregator.passportSummary(container: container, now: now)

        #expect(focused.countries == full.uniqueCountries)
        #expect(focused.trips == full.passportData.trips)
        #expect(focused.daysAbroad == full.passportData.daysAbroad)
        #expect(focused.flights == full.passportData.flights)

        // Anchor the parity to concrete values so both paths failing the same
        // way cannot slip through: GR/IT (stays) ∪ JP (residue) ∪ GB ∪ FR
        // (trip codes); 2 completed trips; 2 flight legs.
        #expect(focused.countries == Set(["GR", "IT", "JP", "GB", "FR"]))
        #expect(focused.trips == 2)
        #expect(focused.flights == 2)
    }

    @Test("focused summary matches the full compute on an empty store")
    func passportSummaryEmptyStoreParity() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let full = try StatsAggregator.compute(container: container)
        let focused = try StatsAggregator.passportSummary(container: container)

        #expect(focused.countries == full.uniqueCountries)
        #expect(focused.countries.isEmpty)
        #expect(focused.trips == 0)
        #expect(focused.daysAbroad == 0)
        #expect(focused.flights == 0)
    }

    /// Two devices importing one backup converge two rows per trip
    /// (`Trip.id` cannot be unique under CloudKit). Passport, Siri's
    /// lifetime and year answers, the year ledger and the stats widget all
    /// count the twins as one trip.
    @Test("every trip counter counts a completed trip's same-UUID twin once")
    func tripCountersCollapseSameUUIDTwins() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let rome = trip(ctx, start: utc(2025, 5, 1), days: 4, codes: "IT")
        stay(ctx, category: .destination, iso: "IT", start: utc(2025, 5, 2), trip: rome)
        let romeTwin = trip(ctx, start: utc(2025, 5, 1), days: 4, codes: "IT")
        romeTwin.id = rome.id
        stay(ctx, category: .destination, iso: "IT", start: utc(2025, 5, 2), trip: romeTwin)
        let lisbon = trip(ctx, start: utc(2025, 9, 10), days: 3, codes: "PT")
        stay(ctx, category: .destination, iso: "PT", start: utc(2025, 9, 11), trip: lisbon)
        try ctx.save()
        #expect(try ctx.fetchCount(FetchDescriptor<Trip>()) == 3)

        let now = utc(2025, 12, 20)
        let full = try StatsAggregator.compute(container: container, now: now)
        let focused = try StatsAggregator.passportSummary(container: container, now: now)
        let year = try StatsAggregator.yearSummary(container: container, year: 2025, now: now)
        let widget = try Stay.widgetTravelStats(in: container)

        #expect(full.passportData.trips == 2)
        #expect(full.passportData.tripsThisYear == 2)
        #expect(full.yearStats?.first { $0.year == 2025 }?.trips == 2)
        #expect(focused.trips == 2)
        #expect(year.trips == 2)
        #expect(widget.tripCount == 2)
        // Country evidence is unchanged by the collapse.
        #expect(focused.countries == Set(["IT", "PT"]))
        #expect(year.countries == Set(["IT", "PT"]))
    }

    // MARK: - Farthest from home with a temporary home

    private static let athens = (lat: 37.9838, lon: 23.7275)
    private static let brussels = (lat: 50.8553, lon: 4.2613)
    private static let paris = (lat: 48.9212, lon: 2.3771)
    private static let rome = (lat: 41.9278, lon: 12.4172)

    /// Athens is the real Home. Rome is stamped from Athens (1,060 km);
    /// Paris from a Brussels base (254 km), though it lies about 2,100 km
    /// from Athens. With `semester`, Brussels is a temporary home.
    @discardableResult
    private func seedFarthest(_ ctx: ModelContext, semester: Bool) -> (paris: Stay, rome: Stay) {
        ctx.insert(Home(label: "Athens", latitude: Self.athens.lat, longitude: Self.athens.lon,
                        startedAt: utc(2020, 1, 1)))
        if semester {
            ctx.insert(TemporaryHome(label: "Semester", latitude: Self.brussels.lat,
                                     longitude: Self.brussels.lon,
                                     startedAt: utc(2025, 6, 16, 0), endedAt: utc(2025, 10, 4, 0)))
        }
        func destination(_ place: (lat: Double, lon: Double), _ name: String, stamped: Double,
                         start: Date, trip: Trip) -> Stay {
            let s = Stay(startTime: start, endTime: start.addingTimeInterval(2 * 86_400),
                         centroidLatitude: place.lat, centroidLongitude: place.lon,
                         h3IndexRes6: "", pingCount: 3, distanceFromHomeKm: stamped, pingIDs: [])
            s.category = .destination
            s.locality = name
            ctx.insert(s)
            s.trip = trip
            return s
        }
        let romeTrip = trip(ctx, start: utc(2025, 2, 13), days: 3, codes: "IT")
        let parisTrip = trip(ctx, start: utc(2025, 7, 25), days: 3, codes: "FR")
        return (paris: destination(Self.paris, "Paris", stamped: 254,
                                   start: utc(2025, 7, 25, 14), trip: parisTrip),
                rome: destination(Self.rome, "Rome", stamped: 1_060,
                                  start: utc(2025, 2, 13, 14), trip: romeTrip))
    }

    @Test("with a temporary home, Farthest from home measures every destination from the real Home of its start and leaves the stamps alone")
    func farthestWithTemporaryHomeUsesTheRealHome() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let parisID = seedFarthest(ctx, semester: true).paris.id
        try ctx.save()

        let passport = try StatsAggregator.compute(container: container, now: utc(2025, 10, 20)).passportData
        let expected = StayClusterer.closestHomeDistanceKm(
            latitude: Self.paris.lat, longitude: Self.paris.lon, atTime: utc(2025, 7, 25, 14),
            homes: [.init(latitude: Self.athens.lat, longitude: Self.athens.lon,
                          startedAt: utc(2020, 1, 1), endedAt: nil)])
        #expect(passport.furthestPlace == "Paris")
        // CLLocation distances wobble by centimetres between calls.
        #expect(abs((passport.furthestKm ?? 0) - expected) < 0.01)
        #expect((2_000...2_200).contains(passport.furthestKm ?? 0))
        // The stamp is the trip's departure distance and stays as it was.
        let paris = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == parisID })).first)
        #expect(paris.distanceFromHomeKm == 254)
    }

    @Test("once the only temporary home is removed, Farthest from home still measures from the real Home, since trips it kept are still stamped from the base")
    func farthestAfterTheOnlyTemporaryHomeIsRemovedUsesTheRealHome() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedFarthest(ctx, semester: true)
        for row in try ctx.fetch(FetchDescriptor<TemporaryHome>()) { row.removedAt = utc(2025, 10, 5) }
        try ctx.save()

        let passport = try StatsAggregator.compute(container: container, now: utc(2025, 10, 20)).passportData
        #expect(passport.furthestPlace == "Paris")
        #expect((2_000...2_200).contains(passport.furthestKm ?? 0))
    }

    @Test("without a temporary home, Farthest from home is the stored stamp exactly")
    func farthestWithoutTemporaryHomeIsTheStamp() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedFarthest(ctx, semester: false)
        try ctx.save()

        let passport = try StatsAggregator.compute(container: container, now: utc(2025, 10, 20)).passportData
        #expect(passport.furthestPlace == "Rome")
        #expect(passport.furthestKm == 1_060)
    }
}
