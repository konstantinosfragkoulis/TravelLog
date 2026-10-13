//
//  TemporaryHomeDistanceTests.swift
//  TravelLogTests
//
//  Distances once a temporary home exists. A live ping that extends a stay
//  keeps the measurement assembly gave it: a trip member stays measured from
//  the trip's departure home, a tripless stay from the homes of its own start.
//  A new recap's farthest place is measured from the real Home of each stay's
//  start, never from a stamp a temporary home measured. Stores without a
//  temporary home keep today's numbers.
//  Throwaway stores, primed square shapes, the model lane pinned off.
//

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Temporary home distances", .serialized, IsolatedTitleDefaults())
struct TemporaryHomeDistanceTests {

    private typealias Place = (lat: Double, lon: Double)
    private static let athens: Place = (38.0, 23.8)
    private static let brussels: Place = (50.8833, 4.3029)
    /// About 50 km north of Brussels, outside its 10 km square.
    private static let outing: Place = (51.3333, 4.3024)
    private static let utc = TimeZone(secondsFromGMT: 0)!
    private static let hour: TimeInterval = 3600

    private func makeClassifier(_ container: ModelContainer) async -> TripClassifier {
        await TemporaryHomeFixture.classifier(container, squares: [(1, Self.athens), (2, Self.brussels)])
    }

    /// One ordinary pipeline pass.
    private func ordinaryPass(_ classifier: TripClassifier) async {
        await TemporaryHomeFixture.ordinaryPass(classifier)
    }

    private func stored(_ id: UUID, _ container: ModelContainer) throws -> Stay {
        let found = try ModelContext(container).fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == id }))
        try #require(found.count == 1)
        return found[0]
    }

    private func cluster(_ clusterer: StayClusterer) async {
        _ = await clusterer.clusterUnprocessedPingsReportingChanges(
            defaults: TestSupport.liveFloorFreeDefaults)
    }

    private func ping(_ at: Date, _ place: Place) -> LocationPing {
        LocationPing(timestamp: at, latitude: place.lat, longitude: place.lon,
                     horizontalAccuracy: 10,
                     h3IndexRes6: H3Service.cellIndex(latitude: place.lat, longitude: place.lon) ?? "",
                     source: .liveSLC)
    }

    private func homeStay(_ ctx: ModelContext, from start: Date, to end: Date) {
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: Self.athens.lat, centroidLongitude: Self.athens.lon,
            h3IndexRes6: H3Service.cellIndex(latitude: Self.athens.lat, longitude: Self.athens.lon) ?? "",
            pingCount: 2, distanceFromHomeKm: 0, pingIDs: [], source: .liveSLC,
            timeZoneIdentifier: "Europe/Athens")
        stay.category = .home
        ctx.insert(stay)
    }

    private static func km(_ a: Place, _ b: Place) -> Double {
        CLLocation(latitude: a.lat, longitude: a.lon)
            .distance(from: CLLocation(latitude: b.lat, longitude: b.lon)) / 1000
    }

    // MARK: - Live extension

    @Test("a live ping that extends an Athens trip's stay past an upcoming temporary home's start keeps the departure distance",
          arguments: [false, true])
    func liveExtensionKeepsDepartureDistance(renamed: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        // The semester begins at a UTC midnight at least three hours ago.
        let semesterStart = calendar.startOfDay(for: Date.now.addingTimeInterval(-3 * Self.hour))

        ctx.insert(Home(label: "Athens", latitude: Self.athens.lat, longitude: Self.athens.lon,
                        radiusKm: 25, startedAt: semesterStart.addingTimeInterval(-1000 * 86_400)))
        homeStay(ctx, from: semesterStart.addingTimeInterval(-72 * Self.hour),
                 to: semesterStart.addingTimeInterval(-24 * Self.hour))
        // Declared in advance: Brussels from the semester's first day, open-ended.
        let semester = TemporaryHome(
            label: "Semester", latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            startedAt: semesterStart, endedAt: nil)
        semester.timeZoneIdentifier = "UTC"
        ctx.insert(semester)
        // The evening before: arrived at a hotel 50 km north of Brussels.
        for offset in [-8.0, -6, -4, -2, -0.5] {
            ctx.insert(ping(semesterStart.addingTimeInterval(offset * Self.hour), Self.outing))
        }
        try ctx.save()

        let clusterer = StayClusterer(modelContainer: container)
        await cluster(clusterer)
        let classifier = await makeClassifier(container)
        await ordinaryPass(classifier)

        let hotel = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>())
            .first { abs($0.centroidLatitude - Self.outing.lat) < 0.01 })
        let hotelID = hotel.id
        try #require(hotel.category == .destination)
        let trip = try #require(hotel.trip)
        try #require(!trip.isComplete)
        let tripID = trip.id
        let startBefore = hotel.startTime
        let before = hotel.distanceFromHomeKm
        try #require(before > 2_000)
        if renamed {
            // TripDetailView's rename marks the trip edited.
            let edit = ModelContext(container)
            let row = try #require(try edit.fetch(FetchDescriptor<Trip>()).first { $0.id == tripID })
            row.customName = "Moving to Brussels"
            row.userEdited = true
            try edit.save()
        }

        // One more live ping at the hotel, 15 minutes into the semester.
        ctx.insert(ping(semesterStart.addingTimeInterval(0.25 * Self.hour), Self.outing))
        try ctx.save()
        await cluster(clusterer)

        let extended = try stored(hotelID, container)
        try #require(extended.endTime >= semesterStart.addingTimeInterval(0.25 * Self.hour))
        #expect(extended.startTime == startBefore)
        #expect(extended.category == .destination)
        #expect(extended.trip?.id == tripID)
        #expect(abs(extended.distanceFromHomeKm - before) < 1,
                "after the extension: \(extended.distanceFromHomeKm) km, was \(before) km")

        // The same wake's ordinary pass, on the warm classifier.
        await ordinaryPass(classifier)
        let afterWarm = try stored(hotelID, container)
        #expect(afterWarm.trip?.id == tripID)
        #expect(abs(afterWarm.distanceFromHomeKm - before) < 1,
                "after the next ordinary pass: \(afterWarm.distanceFromHomeKm) km, was \(before) km")

        // The next launch's first pass (a fresh classifier runs its back half once).
        let cold = await makeClassifier(container)
        await ordinaryPass(cold)
        let afterCold = try stored(hotelID, container)
        #expect(afterCold.trip?.id == tripID)
        #expect(abs(afterCold.distanceFromHomeKm - before) < 1,
                "after a cold launch pass: \(afterCold.distanceFromHomeKm) km, was \(before) km")
    }

    @Test("during an active temporary home, a live ping that extends a trip's stay keeps the distance from the real home it left")
    func activeLiveExtensionKeepsRealHomeDeparture() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let now = Date.now
        let amsterdam: Place = (52.4151, 4.9665)

        ctx.insert(Home(label: "Athens", latitude: Self.athens.lat, longitude: Self.athens.lon,
                        radiusKm: 25, startedAt: now.addingTimeInterval(-1000 * 86_400)))
        let semester = TemporaryHome(
            label: "Semester", latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            startedAt: now.addingTimeInterval(-60 * 86_400), endedAt: nil)
        semester.timeZoneIdentifier = "UTC"
        ctx.insert(semester)
        // A weekend visit home to Athens during the semester.
        homeStay(ctx, from: now.addingTimeInterval(-72 * Self.hour),
                 to: now.addingTimeInterval(-24 * Self.hour))
        // Then straight from Athens to Amsterdam.
        for offset in [-10.0, -8, -6, -4] {
            ctx.insert(ping(now.addingTimeInterval(offset * Self.hour), amsterdam))
        }
        try ctx.save()

        let clusterer = StayClusterer(modelContainer: container)
        await cluster(clusterer)
        let classifier = await makeClassifier(container)
        await ordinaryPass(classifier)

        let visit = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>())
            .first { abs($0.centroidLatitude - amsterdam.lat) < 0.01 })
        let visitID = visit.id
        try #require(visit.category == .destination)
        let tripID = try #require(visit.trip?.id)
        let before = visit.distanceFromHomeKm
        try #require(before > 2_000)

        ctx.insert(ping(now.addingTimeInterval(-2 * Self.hour), amsterdam))
        try ctx.save()
        await cluster(clusterer)
        let extended = try stored(visitID, container)
        try #require(extended.endTime >= now.addingTimeInterval(-2 * Self.hour))
        #expect(extended.trip?.id == tripID)
        #expect(abs(extended.distanceFromHomeKm - before) < 1,
                "after the extension: \(extended.distanceFromHomeKm) km, was \(before) km")

        await ordinaryPass(classifier)
        let afterWarm = try stored(visitID, container)
        #expect(abs(afterWarm.distanceFromHomeKm - before) < 1,
                "after the next ordinary pass: \(afterWarm.distanceFromHomeKm) km, was \(before) km")
    }

    @Test("a stay no trip holds keeps the homes of its own start when an extension crosses a temporary home's start")
    func triplessExtensionUsesItsStartEra() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = Date(timeIntervalSinceReferenceDate: 793_347_200)
        ctx.insert(Home(label: "Athens", latitude: Self.athens.lat, longitude: Self.athens.lon,
                        radiusKm: 25, startedAt: start.addingTimeInterval(-1000 * 86_400)))
        let semester = TemporaryHome(
            label: "Semester", latitude: Self.brussels.lat, longitude: Self.brussels.lon,
            startedAt: start.addingTimeInterval(2 * Self.hour), endedAt: nil)
        semester.timeZoneIdentifier = "UTC"
        ctx.insert(semester)
        ctx.insert(ping(start, Self.outing))
        try ctx.save()

        let clusterer = StayClusterer(modelContainer: container)
        await cluster(clusterer)
        let created = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        let id = created.id
        #expect(abs(created.distanceFromHomeKm - Self.km(Self.athens, Self.outing)) < 1)

        // Three hours later, an hour into the temporary home's dates.
        ctx.insert(ping(start.addingTimeInterval(3 * Self.hour), Self.outing))
        try ctx.save()
        await cluster(clusterer)

        let extended = try stored(id, container)
        #expect(extended.trip == nil)
        #expect(extended.endTime == start.addingTimeInterval(3 * Self.hour))
        #expect(abs(extended.distanceFromHomeKm - Self.km(Self.athens, Self.outing)) < 1,
                "after the extension: \(extended.distanceFromHomeKm) km")
    }

    @Test("without a temporary home an extension still measures from the homes of the ping's time, as before")
    func extensionWithoutTemporaryHomeIsUnchanged() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = Date(timeIntervalSinceReferenceDate: 793_347_200)
        let move = start.addingTimeInterval(2 * Self.hour)
        // A move from Athens to Brussels two hours after the stay begins.
        let athens = Home(label: "Athens", latitude: Self.athens.lat, longitude: Self.athens.lon,
                          radiusKm: 25, startedAt: start.addingTimeInterval(-1000 * 86_400))
        athens.endedAt = move
        ctx.insert(athens)
        ctx.insert(Home(label: "Brussels", latitude: Self.brussels.lat, longitude: Self.brussels.lon,
                        radiusKm: 25, startedAt: move))
        ctx.insert(ping(start, Self.outing))
        try ctx.save()

        let clusterer = StayClusterer(modelContainer: container)
        await cluster(clusterer)
        let created = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        let id = created.id
        #expect(abs(created.distanceFromHomeKm - Self.km(Self.athens, Self.outing)) < 1)

        ctx.insert(ping(start.addingTimeInterval(3 * Self.hour), Self.outing))
        try ctx.save()
        await cluster(clusterer)

        let extended = try stored(id, container)
        #expect(abs(extended.distanceFromHomeKm - Self.km(Self.brussels, Self.outing)) < 1,
                "after the extension: \(extended.distanceFromHomeKm) km")
    }

    // MARK: - A new recap's farthest place

    private static let paris: Place = (48.8259, 2.3632)
    private static let rome: Place = (41.8988, 12.5661)

    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    /// Athens is the real Home. Rome is stamped from Athens (1,050 km);
    /// Paris from the Brussels base (264 km), about 2,100 km from Athens.
    private func seedYear(_ ctx: ModelContext) {
        ctx.insert(Home(label: "Athens", latitude: Self.athens.lat, longitude: Self.athens.lon,
                        startedAt: utc(2020, 1, 1)))
        for (place, name, stamped, start) in [
            (Self.rome, "Rome", 1_050.0, utc(2025, 2, 13, 14)),
            (Self.paris, "Paris", 264.0, utc(2025, 7, 25, 14)),
        ] {
            let trip = Trip(startDate: start)
            trip.endDate = start.addingTimeInterval(2 * 86_400)
            trip.isComplete = true
            ctx.insert(trip)
            let stay = Stay(startTime: start, endTime: start.addingTimeInterval(2 * 86_400),
                            centroidLatitude: place.lat, centroidLongitude: place.lon,
                            h3IndexRes6: "", pingCount: 3, distanceFromHomeKm: stamped, pingIDs: [],
                            timeZoneIdentifier: "UTC")
            stay.category = .destination
            stay.locality = name
            ctx.insert(stay)
            stay.trip = trip
        }
    }

    private func insertSemester(_ ctx: ModelContext) {
        let semester = TemporaryHome(label: "Semester", latitude: Self.brussels.lat,
                                     longitude: Self.brussels.lon,
                                     startedAt: utc(2025, 6, 16, 0), endedAt: utc(2025, 10, 4, 0))
        semester.timeZoneIdentifier = "UTC"
        ctx.insert(semester)
    }

    private func recap(_ container: ModelContainer) throws -> WrappedStats {
        let row = try #require(ModelContext(container).fetch(FetchDescriptor<YearWrapped>()).first)
        return try #require(row.statsData.flatMap(WrappedStats.decoded(from:)))
    }

    @Test("with a temporary home, a new recap's farthest place is measured from the real Home, not from the stamps")
    func newRecapFarthestUsesTheRealHome() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedYear(ctx)
        insertSemester(ctx)
        try ctx.save()

        #expect(await YearWrappedGenerator(modelContainer: container).forceRegenerate(forYear: 2025))
        let stats = try recap(container)
        #expect(stats.farthestPlaceName == "Paris")
        #expect(abs(stats.farthestDistanceKm - Self.km(Self.athens, Self.paris)) < 0.01)
        let stamps = try ModelContext(container).fetch(FetchDescriptor<Stay>()).map(\.distanceFromHomeKm)
        #expect(Set(stamps) == [1_050, 264])
    }

    @Test("without a temporary home a recap's farthest is the stamp, and a recap generated before a temporary home keeps its numbers")
    func recapWithoutTemporaryHomeKeepsTheStamp() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        seedYear(ctx)
        try ctx.save()

        let generator = YearWrappedGenerator(modelContainer: container)
        #expect(await generator.forceRegenerate(forYear: 2025))
        let before = try recap(container)
        #expect(before.farthestPlaceName == "Rome")
        #expect(before.farthestDistanceKm == 1_050)

        insertSemester(ctx)
        try ctx.save()
        #expect(await generator.generateIfNeeded(forYear: 2025) == .existing)
        let after = try recap(container)
        #expect(after.farthestPlaceName == "Rome")
        #expect(after.farthestDistanceKm == 1_050)
    }
}
