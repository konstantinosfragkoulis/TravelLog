//
//  TitleTemporaryHomeTests.swift
//  TravelLogTests
//
//  A temporary home keeps its place out of trip names for its own dates
//  only. The home stays it owns do not feed the 180-day window that
//  real-home stays feed, and a store with no temporary home builds the
//  home-place index it always built.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Trip names around a temporary home")
struct TitleTemporaryHomeTests {

    private typealias Place = (latitude: Double, longitude: Double)
    private static let athens: Place = (37.9838, 23.7275)
    private static let brussels: Place = (50.8503, 4.3517)

    private let base = Date(timeIntervalSinceReferenceDate: 777_017_600)

    private func day(_ offset: Double) -> Date {
        base.addingTimeInterval(offset * 86_400)
    }

    /// `owner` is the temporary home that recorded the stay, as the
    /// classifier stamps a home stay inside its dates and outside a real
    /// Home's area.
    @discardableResult
    private func homeStay(
        _ context: ModelContext, day offset: Double, at place: Place, metro: String?,
        by owner: UUID? = nil
    ) -> Stay {
        let stay = Stay(
            startTime: day(offset), endTime: day(offset).addingTimeInterval(8 * 3_600),
            centroidLatitude: place.latitude, centroidLongitude: place.longitude,
            h3IndexRes6: "home-\(offset)", pingCount: 3, distanceFromHomeKm: 0, pingIDs: [])
        context.insert(stay)
        stay.category = .home
        stay.temporaryHomeID = owner
        stay.metroName = metro
        return stay
    }

    /// A completed trip whose destinations carry `names`, in visit order,
    /// three hours each unless `hours` says otherwise.
    private func trip(
        _ context: ModelContext, from start: Double, to end: Double, visiting names: [String],
        hours: [Double]? = nil
    ) throws -> Trip {
        let trip = Trip(startDate: day(start))
        trip.endDate = day(end)
        trip.isComplete = true
        context.insert(trip)
        var begin = day(start)
        for (index, name) in names.enumerated() {
            let length = (hours?[index] ?? 3) * 3_600
            defer { begin = begin.addingTimeInterval(length + 3_600) }
            let stay = Stay(
                startTime: begin, endTime: begin.addingTimeInterval(length),
                centroidLatitude: 51.04954, centroidLongitude: 5.22606,
                h3IndexRes6: "trip-\(start)-\(index)", pingCount: 2,
                distanceFromHomeKm: 100, pingIDs: [])
            context.insert(stay)
            stay.category = .destination
            stay.metroName = name
            stay.orderInTrip = index
            stay.trip = trip
        }
        try context.save()
        return trip
    }

    /// The name the trip card shows on a device without a generated title.
    private func summary(of trip: Trip) -> String {
        #expect(trip.recomputeSummary())
        return trip.destinationSummary
    }

    /// Athens is home throughout (the Home row's own locality is the suburb,
    /// so "Athens" comes from home stays only). Brussels is a temporary home
    /// from day 200 to day 350, with one visit home on day 260.
    private func seedSemester(_ context: ModelContext) throws {
        let home = Home(
            label: "Home", latitude: Self.athens.latitude, longitude: Self.athens.longitude,
            startedAt: day(-1_000))
        home.locality = "Palaió Fáliro"
        context.insert(home)
        homeStay(context, day: 0, at: Self.athens, metro: "Athens")
        homeStay(context, day: 260, at: Self.athens, metro: "Athens")

        let temporary = TemporaryHome(
            label: "Erasmus", latitude: Self.brussels.latitude, longitude: Self.brussels.longitude,
            startedAt: day(200), endedAt: day(350))
        temporary.locality = "Brussels"
        context.insert(temporary)
        for offset in [201.0, 300, 349] {
            homeStay(context, day: offset, at: Self.brussels, metro: "Brussels", by: temporary.id)
        }
        try context.save()
        TripTitleStore.invalidateHomePlaceIndex()
    }

    // MARK: - Inside the dates

    @Test("a trip inside the temporary home's dates drops the base's name when it went somewhere else too")
    func tripInsideDatesDropsBaseName() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        try seedSemester(context)
        let weekend = try trip(context, from: 220, to: 223, visiting: ["Brussels", "Beringen"])
        #expect(summary(of: weekend) == "Beringen")
    }

    @Test("a trip inside the temporary home's dates keeps the base's name when it is the only place")
    func tripInsideDatesKeepsOnlyName() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        try seedSemester(context)
        let errand = try trip(context, from: 230, to: 231, visiting: ["Brussels"])
        #expect(summary(of: errand) == "Brussels")
    }

    @Test("a trip that straddles the temporary home's start or end drops the base's name")
    func tripOverlappingDatesDropsBaseName() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        try seedSemester(context)
        let arriving = try trip(context, from: 198, to: 202, visiting: ["Brussels", "Beringen"])
        let leaving = try trip(context, from: 349.5, to: 352, visiting: ["Brussels", "Beringen"])
        #expect(summary(of: arriving) == "Beringen")
        #expect(summary(of: leaving) == "Beringen")
    }

    // MARK: - A trip at the base

    /// The home place names the title paths use for `trip`.
    private func titleHomeNames(of trip: Trip, in context: ModelContext) -> [String]? {
        (try? TripTitleStore.homePlaceNames(for: trip, in: context))?.sorted()
    }

    @Test("a trip that spent most of its time at the base keeps the base in its place list, and the title paths stop treating the base as a home place for it")
    func tripMostlyAtTheBaseKeepsTheBaseName() async throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        try seedSemester(context)
        // A trip the declaration kept whole: 30 hours in Brussels, 3 in Beringen.
        let kept = try trip(context, from: 220, to: 223, visiting: ["Brussels", "Beringen"],
                            hours: [30, 3])
        #expect(summary(of: kept) == "Brussels, Beringen")
        #expect(titleHomeNames(of: kept, in: context) == ["athens", "palaio faliro"])
    }

    @Test("a side trip from the base still drops a short stop named like the base, in the place list and in the title paths")
    func sideTripStillDropsAShortStopNamedLikeTheBase() async throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        try seedSemester(context)
        // An hour at a station in the Brussels metro on the way to Beringen.
        let side = try trip(context, from: 220, to: 223, visiting: ["Brussels", "Beringen"],
                            hours: [1, 30])
        #expect(summary(of: side) == "Beringen")
        #expect(titleHomeNames(of: side, in: context) == ["athens", "brussels", "palaio faliro"])
    }

    @Test("the real home's name is dropped from a trip however much of the trip was spent there, with a temporary home in the store")
    func realHomeNameIsDroppedWhateverItsShare() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        try seedSemester(context)
        // Inside the temporary home's dates, 40 days from the visit home on day 260.
        let nearHome = try trip(context, from: 300.5, to: 303, visiting: ["Athens", "Aegina"],
                                hours: [30, 3])
        #expect(summary(of: nearHome) == "Aegina")
    }

    @Test("with no temporary home the home names are the same whatever the trip's destinations are")
    func noTemporaryHomeIgnoresTheDestinations() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let brussels = Home(
            label: "Brussels", latitude: Self.brussels.latitude, longitude: Self.brussels.longitude,
            startedAt: day(200))
        brussels.locality = "Brussels"
        context.insert(brussels)
        homeStay(context, day: 201, at: Self.brussels, metro: "Brussels")
        try context.save()
        TripTitleStore.invalidateHomePlaceIndex()

        let plain = try TripTitleStore.homePlaceNames(
            tripStart: day(220), tripEnd: day(223), in: context)
        let atHome = try TripTitleStore.homePlaceNames(
            tripStart: day(220), tripEnd: day(223),
            destinations: { [("Brussels", 1_800), ("Beringen", 180)] }, in: context)
        #expect(plain == ["brussels"])
        #expect(atHome == plain)
        // A trip that is nearly all Brussels still loses the real home's name.
        let mostly = try trip(context, from: 220, to: 223, visiting: ["Brussels", "Beringen"],
                              hours: [30, 3])
        #expect(summary(of: mostly) == "Beringen")
    }

    // MARK: - Outside the dates

    @Test("a trip 60 days before the temporary home starts keeps the base's name")
    func tripBeforeStartKeepsBaseName() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        try seedSemester(context)
        let flatHunting = try trip(context, from: 137, to: 140, visiting: ["Brussels", "Beringen"])
        #expect(summary(of: flatHunting) == "Brussels, Beringen")
        let names = try TripTitleStore.homePlaceNames(
            tripStart: day(137), tripEnd: day(140), in: context)
        #expect(!names.contains("brussels"))
    }

    @Test("a trip 60 days after the temporary home ends keeps the base's name")
    func tripAfterEndKeepsBaseName() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        try seedSemester(context)
        let reunion = try trip(context, from: 410, to: 413, visiting: ["Brussels", "Beringen"])
        #expect(summary(of: reunion) == "Brussels, Beringen")
        let names = try TripTitleStore.homePlaceNames(
            tripStart: day(410), tripEnd: day(413), in: context)
        #expect(!names.contains("brussels"))
    }

    // MARK: - Recorded owner

    /// A Brussels home stay on day 210, inside the dates, that the real Home
    /// recorded (nil) or whose recorded owner has no row here.
    @Test("a home stay at the base is named by its record, never the nearest centre: the real Home's feeds the 180-day window, an unsynced owner's names nothing",
          arguments: [false, true])
    func homeStayAtTheBaseReadsItsRecord(unsynced: Bool) throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        try seedSemester(context)
        homeStay(context, day: 210, at: Self.brussels, metro: "Brussels", by: unsynced ? UUID() : nil)
        try context.save()
        TripTitleStore.invalidateHomePlaceIndex()

        // 73 days before the stay, outside the temporary home's dates.
        let names = try TripTitleStore.homePlaceNames(
            tripStart: day(137), tripEnd: day(140), in: context)
        #expect(names.contains("brussels") == !unsynced)
    }

    // MARK: - The real Home

    @Test("real-home stays still keep their name out of trips within 180 days, with a temporary home in the store")
    func realHomePaddingIsUnchanged() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        try seedSemester(context)
        // 100 days after the day-0 home stay.
        let spring = try trip(context, from: 100, to: 102, visiting: ["Athens", "Aegina"])
        // 140 days after the visit home on day 260, which lies inside the
        // temporary home's dates and is still the real Home's stay.
        let afterVisit = try trip(context, from: 400, to: 402, visiting: ["Athens", "Aegina"])
        // 200 days after that visit: outside the window.
        let muchLater = try trip(context, from: 460, to: 462, visiting: ["Athens", "Aegina"])
        #expect(summary(of: spring) == "Aegina")
        #expect(summary(of: afterVisit) == "Aegina")
        #expect(summary(of: muchLater) == "Athens, Aegina")
    }

    // MARK: - No temporary home

    /// The rule before temporary homes, read straight from the rows: every
    /// home stay within 180 days of the trip, plus every Home whose era
    /// overlaps it.
    private func namesBeforeTemporaryHomes(
        tripStart: Date, tripEnd: Date, in context: ModelContext
    ) throws -> Set<String> {
        let padding: TimeInterval = 180 * 86_400
        var names = Set<String>()
        for stay in try context.fetch(FetchDescriptor<Stay>()) where stay.category == .home {
            guard let name = stay.placeGroupName,
                  stay.startTime >= tripStart.addingTimeInterval(-padding),
                  stay.startTime <= tripEnd.addingTimeInterval(padding) else { continue }
            names.insert(TripTitleStore.normalizedPlaceName(name))
        }
        for home in try context.fetch(FetchDescriptor<Home>()) {
            guard let locality = home.locality, home.startedAt <= tripEnd,
                  (home.endedAt ?? .distantFuture) >= tripStart else { continue }
            names.insert(TripTitleStore.normalizedPlaceName(locality))
        }
        names.remove("")
        return names
    }

    @Test("with no temporary home every trip window gets the home names it got before")
    func noTemporaryHomeMatchesTheOldRule() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        // The same places as the semester, declared the old way: Brussels
        // as a second Home that ended.
        let athens = Home(
            label: "Home", latitude: Self.athens.latitude, longitude: Self.athens.longitude,
            startedAt: day(-1_000))
        athens.locality = "Palaió Fáliro"
        context.insert(athens)
        let brussels = Home(
            label: "Brussels", latitude: Self.brussels.latitude, longitude: Self.brussels.longitude,
            startedAt: day(200))
        brussels.locality = "Brussels"
        brussels.endedAt = day(350)
        context.insert(brussels)
        context.insert(Home(label: "Unnamed", latitude: 0, longitude: 0, startedAt: day(-50)))
        homeStay(context, day: 0, at: Self.athens, metro: "Athens")
        homeStay(context, day: 260, at: Self.athens, metro: "Athens")
        homeStay(context, day: 270, at: Self.athens, metro: nil)
        for offset in [201.0, 300, 349] {
            homeStay(context, day: offset, at: Self.brussels, metro: "Brussels")
        }
        try context.save()
        TripTitleStore.invalidateHomePlaceIndex()

        var distinct = Set<Set<String>>()
        for start in stride(from: -400.0, through: 800, by: 20) {
            for length in [0.0, 3, 45] {
                let tripStart = day(start)
                let tripEnd = day(start + length)
                let names = try TripTitleStore.homePlaceNames(
                    tripStart: tripStart, tripEnd: tripEnd, in: context)
                let expected = try namesBeforeTemporaryHomes(
                    tripStart: tripStart, tripEnd: tripEnd, in: context)
                #expect(names == expected, "trip from day \(start) for \(length) days")
                distinct.insert(names)
            }
        }
        // The matrix crosses every combination the store can produce.
        #expect(distinct.contains(["palaio faliro"]))
        #expect(distinct.contains(["palaio faliro", "athens"]))
        #expect(distinct.contains(["palaio faliro", "athens", "brussels"]))
        #expect(distinct.contains(["palaio faliro", "brussels"]))
    }

    // MARK: - Invalidation

    @Test("ending a temporary home early takes its place name back out of later trips once the change is published")
    func temporaryHomeEditInvalidatesIndex() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let temporary = TemporaryHome(
            label: "Erasmus", latitude: Self.brussels.latitude, longitude: Self.brussels.longitude,
            startedAt: day(200), endedAt: day(350))
        temporary.locality = "Brussels"
        context.insert(temporary)
        try context.save()
        TripTitleStore.invalidateHomePlaceIndex()

        // With no home stay yet, the row's own place name already applies.
        #expect(try TripTitleStore.homePlaceNames(
            tripStart: day(220), tripEnd: day(223), in: context) == ["brussels"])

        temporary.endedAt = day(210)
        try context.save()
        StoreChangeTracker(forTesting: ()).bump(.temporaryHome)

        #expect(try TripTitleStore.homePlaceNames(
            tripStart: day(220), tripEnd: day(223), in: context).isEmpty)
    }
}
