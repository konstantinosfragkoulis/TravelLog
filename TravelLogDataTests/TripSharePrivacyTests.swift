//
//  TripSharePrivacyTests.swift
//  TravelLogTests
//
//  Every shared output keeps the share sheet's promise: no home, no time
//  near one. A Visit or stay is judged over its whole span, a stay that
//  lost only a Visit is rebuilt, a generated title the kept stays no longer
//  ground falls back, the GPX route and the card's route break where
//  evidence was removed or a line would cross a home, Share refuses a
//  preview the trips or homes moved under, and a file the recipient would
//  refuse is never handed over. A seeded property run then checks all of it
//  over many random trips. Places and dates are fictional fixtures, out at
//  sea.
//

import Testing
import Foundation
import SwiftData
import CoreGraphics
@testable import TravelLog

@MainActor
@Suite("Trip share privacy")
struct TripSharePrivacyTests {

    typealias Place = (lat: Double, lon: Double)
    typealias HomeRing = TripClassifier.HomeRing

    static let base = Date(timeIntervalSinceReferenceDate: 810_000_000)
    static func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }

    // Fictional fixtures.
    static let home: Place = (10.0, 150.0)
    static let newHome: Place = (10.5, 150.5)
    static let temporaryHome: Place = (10.0, 151.0)
    static let lakeside: Place = (10.3, 150.3)
    static let ridge: Place = (10.25, 150.75)
    static let cove: Place = (10.3, 150.9)

    // MARK: Builders

    static func ping(_ place: Place, _ hours: Double) -> SharedPing {
        SharedPing(id: UUID(), timestamp: at(hours), latitude: place.lat, longitude: place.lon,
                   horizontalAccuracy: 20, altitude: nil, verticalAccuracy: nil, sourceRaw: "liveSLC")
    }

    static func visit(_ place: Place, _ arrival: Double, _ departure: Double, stay: UUID) -> SharedVisit {
        SharedVisit(id: UUID(), arrivalDate: at(arrival), departureDate: at(departure),
                    latitude: place.lat, longitude: place.lon, horizontalAccuracy: 30, stayID: stay)
    }

    static func stay(_ place: Place, _ category: StayCategory = .destination, pings: [SharedPing],
                     from: Double? = nil, to: Double? = nil, order: Int, locality: String) -> SharedStay {
        SharedStay(
            id: UUID(), startTime: from.map(at) ?? pings.map(\.timestamp).min()!,
            endTime: to.map(at) ?? pings.map(\.timestamp).max()!,
            durationMinutes: 60, categoryRaw: category.rawValue,
            latitude: place.lat, longitude: place.lon, h3IndexRes6: "861f8a6dfffffff",
            pingCount: pings.count, pingIDs: pings.map(\.id), orderInTrip: order,
            locality: locality, subLocality: nil, administrativeArea: nil, country: nil,
            isoCountryCode: "AA", metroName: nil, islandName: nil, isAirport: false,
            sourceRaw: "liveSLC", userOverridden: false, continuesPreviousTrip: false,
            transitFromPreviousRaw: "car", distanceFromPreviousKm: 50,
            stepsWalked: nil, weatherData: Data([1, 2, 3]), avgTemperatureC: 21,
            weatherConditionRaw: "clear", precipitationMm: 0, dayKey: base,
            timeZoneIdentifier: "UTC")
    }

    static func trip(_ stays: [SharedStay], pings: [SharedPing], visits: [SharedVisit] = [],
                     name: String? = nil, title: String? = nil,
                     localized: [SharedLocalizedTitle] = []) -> SharedTrip {
        SharedTrip(
            shareID: UUID(), customName: name, canonicalTitle: title, localizedTitles: localized,
            startDate: stays.map(\.startTime).min()!, endDate: stays.map(\.endTime).max()!,
            isComplete: true, countryCodes: ["AA"], destinationSummary: "",
            stays: stays, pings: pings, visits: visits)
    }

    static func ring(_ place: Place, km: Double, from: Double, to: Double? = nil,
                     temporary: Bool = false, membership: HomeMembership? = nil) -> HomeRing {
        var ring = HomeRing(latitude: place.lat, longitude: place.lon, radiusKm: km,
                            startedAt: at(from), endedAt: to.map(at), homeID: UUID(), membership: membership)
        ring.claimsPrehistory = !temporary
        ring.isTemporary = temporary
        return ring
    }

    static func km(_ lat: Double, _ lon: Double, _ place: Place) -> Double {
        TripShareExport.haversineKm(lat, lon, place.lat, place.lon)
    }

    // MARK: Visits and stays over their whole span

    @Test("a stay that loses only a home-area Visit is rebuilt from what it keeps")
    func visitOnlyDropRebuildsTheStay() throws {
        let rings = [Self.ring(Self.home, km: 5, from: -24 * 365)]
        let pings = [Self.ping(Self.lakeside, 10), Self.ping(Self.lakeside, 12)]
        var stay = Self.stay(Self.lakeside, pings: pings, from: 2, to: 12, order: 0, locality: "Lakeside")
        // The home Visit pulled the stay's start and centre toward home.
        stay.latitude = 10.2
        stay.longitude = 150.2
        let kept = Self.visit(Self.lakeside, 10, 12, stay: stay.id)
        let atHome = Self.visit(Self.home, 2, 9, stay: stay.id)
        let filtered = try #require(TripShareExport.excludingHomeAreas(
            Self.trip([stay], pings: pings, visits: [kept, atHome]), rings: rings))

        let shared = try #require(filtered.stays.first)
        #expect(filtered.visits.map(\.id) == [kept.id])
        #expect(shared.startTime == Self.at(10) && shared.endTime == Self.at(12))
        #expect(shared.durationMinutes == 120)
        #expect(Self.km(shared.latitude, shared.longitude, Self.lakeside) < 0.01)
        #expect(shared.h3IndexRes6 == H3Service.cellIndex(latitude: shared.latitude, longitude: shared.longitude))
        #expect(shared.weatherData == nil && shared.avgTemperatureC == nil && shared.dayKey == nil)
        #expect(filtered.startDate == Self.at(10))
    }

    @Test("a Visit or stay that meets a dated home's start, an ended home or a temporary home's start mid-span goes")
    func straddlingSpansAreProtected() throws {
        let rings = [
            Self.ring(Self.home, km: 5, from: -24 * 365, to: 10),
            Self.ring(Self.newHome, km: 5, from: 20),
            Self.ring(Self.temporaryHome, km: 5, from: 40, to: 60, temporary: true),
        ]
        // Arrives before the new home's dates, departs inside them.
        #expect(!TripShareExport.isInsideHome(Self.at(18), latitude: Self.newHome.lat,
                                              longitude: Self.newHome.lon, rings: rings))
        #expect(TripShareExport.isInsideHome(during: DateInterval(start: Self.at(18), end: Self.at(22)),
                                             latitude: Self.newHome.lat, longitude: Self.newHome.lon, rings: rings))
        #expect(!TripShareExport.isInsideHome(during: DateInterval(start: Self.at(12), end: Self.at(19)),
                                              latitude: Self.newHome.lat, longitude: Self.newHome.lon, rings: rings))

        let ridgePings = [Self.ping(Self.ridge, 15), Self.ping(Self.ridge, 16)]
        let ridgeStay = Self.stay(Self.ridge, pings: ridgePings, from: 8, to: 22, order: 0, locality: "Ridge")
        let ridgeVisit = Self.visit(Self.ridge, 15, 16, stay: ridgeStay.id)
        let intoNewHome = Self.visit(Self.newHome, 18, 22, stay: ridgeStay.id)
        let outOfOldHome = Self.visit(Self.home, 8, 12, stay: ridgeStay.id)

        let covePings = [Self.ping(Self.cove, 36), Self.ping(Self.cove, 37)]
        let coveStay = Self.stay(Self.cove, pings: covePings, from: 35, to: 45, order: 1, locality: "Cove")
        let intoTemporaryHome = Self.visit(Self.temporaryHome, 35, 45, stay: coveStay.id)

        // A stay at the temporary home that runs past its start.
        let portPings = [Self.ping(Self.temporaryHome, 30), Self.ping(Self.temporaryHome, 32)]
        let portStay = Self.stay(Self.temporaryHome, pings: portPings, from: 30, to: 41, order: 2, locality: "Port")

        let filtered = try #require(TripShareExport.excludingHomeAreas(
            Self.trip([ridgeStay, coveStay, portStay], pings: ridgePings + covePings + portPings,
                      visits: [ridgeVisit, intoNewHome, outOfOldHome, intoTemporaryHome]),
            rings: rings))

        #expect(filtered.visits.map(\.id) == [ridgeVisit.id])
        #expect(Set(filtered.stays.map(\.locality)) == ["Ridge", "Cove"])
        #expect(Set(filtered.pings.map(\.id)) == Set((ridgePings + covePings).map(\.id)))
        let ridge = try #require(filtered.stays.first { $0.locality == "Ridge" })
        #expect(ridge.startTime == Self.at(15) && ridge.endTime == Self.at(16))
        let cove = try #require(filtered.stays.first { $0.locality == "Cove" })
        #expect(cove.startTime == Self.at(36) && cove.endTime == Self.at(37))
        Self.expectNothingProtected(filtered, rings: rings)
    }

    @Test("a stay whose fixes are outside a home's dates keeps them, but its Visit departing inside them goes")
    func visitDepartingIntoATemporaryHomeGoes() throws {
        let rings = [Self.ring(Self.temporaryHome, km: 5, from: 40, to: 60, temporary: true)]
        let pings = [Self.ping(Self.temporaryHome, 30), Self.ping(Self.temporaryHome, 32)]
        let stay = Self.stay(Self.temporaryHome, pings: pings, order: 0, locality: "Port")
        let lingering = Self.visit(Self.temporaryHome, 30, 42, stay: stay.id)
        let filtered = try #require(TripShareExport.excludingHomeAreas(
            Self.trip([stay], pings: pings, visits: [lingering]), rings: rings))

        #expect(filtered.visits.isEmpty)
        #expect(filtered.pings.count == 2)
        let shared = try #require(filtered.stays.first)
        #expect(shared.startTime == Self.at(30) && shared.endTime == Self.at(32))
        #expect(filtered.endDate == Self.at(32))
        // No instant the file carries falls in the temporary home's dates.
        let protected = DateInterval(start: Self.at(40), end: Self.at(60))
        let instants = filtered.pings.map(\.timestamp) + filtered.stays.flatMap { [$0.startTime, $0.endTime] }
            + [filtered.startDate] + [filtered.endDate].compactMap { $0 }
        #expect(instants.allSatisfy { !protected.contains($0) })
    }

    // MARK: Legs, titles

    @Test("a leg across removed evidence or through a home loses its mode and distance")
    func legsAcrossHomesAreCleared() throws {
        let rings = [Self.ring(Self.home, km: 5, from: -24 * 365)]
        let west: Place = (10.0, 149.95)
        let east: Place = (10.0, 150.05)
        let westPings = [Self.ping(west, 1), Self.ping(west, 2)]
        let eastPings = [Self.ping(east, 3), Self.ping(east, 4)]
        let farPings = [Self.ping(Self.lakeside, 6), Self.ping(Self.lakeside, 7)]
        let filtered = try #require(TripShareExport.excludingHomeAreas(Self.trip([
            Self.stay(west, pings: westPings, order: 0, locality: "West"),
            Self.stay(east, pings: eastPings, order: 1, locality: "East"),
            Self.stay(Self.lakeside, pings: farPings, order: 2, locality: "Lakeside"),
        ], pings: westPings + eastPings + farPings), rings: rings))

        let east1 = try #require(filtered.stays.first { $0.locality == "East" })
        #expect(east1.transitFromPreviousRaw == nil && east1.distanceFromPreviousKm == nil)
        let lake = try #require(filtered.stays.first { $0.locality == "Lakeside" })
        #expect(lake.transitFromPreviousRaw == "car" && lake.distanceFromPreviousKm != nil)
    }

    @Test("a generated title naming a dropped home-area stay is composed again from the kept stays")
    func titleFallsBackWhenItNamesADroppedStay() throws {
        let rings = [Self.ring(Self.home, km: 5, from: -24 * 365)]
        let homePings = [Self.ping(Self.home, 1), Self.ping(Self.home, 3)]
        let lakePings = [Self.ping(Self.lakeside, 10), Self.ping(Self.lakeside, 30)]
        let stays = [
            Self.stay(Self.home, pings: homePings, order: 0, locality: "Homeburg"),
            Self.stay(Self.lakeside, pings: lakePings, order: 1, locality: "Lakeside"),
        ]
        let localized = [SharedLocalizedTitle(languageTag: "de", title: "Homeburg & Lakeside")]
        let named = try #require(TripShareExport.excludingHomeAreas(Self.trip(
            stays, pings: homePings + lakePings, title: "Homeburg & Lakeside", localized: localized), rings: rings))
        #expect(named.canonicalTitle == "Lakeside")
        #expect(named.localizedTitles.isEmpty)
        for tag in ["en", "de"] {
            #expect(named.displayTitle(languageTag: tag) == "Lakeside")
        }
        let json = try #require(String(data: try TripShareFile(
            exportedAt: Self.base, trips: [named]).encoded(), encoding: .utf8))
        #expect(!json.contains("Homeburg"))

        // A title the kept stays still ground travels with its renderings,
        // and the sender's own name always does.
        let grounded = try #require(TripShareExport.excludingHomeAreas(Self.trip(
            stays, pings: homePings + lakePings, name: "Homeburg Getaway", title: "Lakeside",
            localized: [SharedLocalizedTitle(languageTag: "de", title: "Lakeside")]), rings: rings))
        #expect(grounded.canonicalTitle == "Lakeside")
        #expect(grounded.localizedTitles.count == 1)
        #expect(grounded.customName == "Homeburg Getaway")
    }

    // MARK: Routes

    @Test("the GPX route breaks where fixes were removed, where a line would cross a home and across long gaps")
    func gpxSegmentsSplit() throws {
        let rings = [Self.ring(Self.home, km: 5, from: -24 * 365)]
        // Along the home's parallel, 1.1 km a fix, five minutes apart.
        let line = stride(from: 0, through: 30, by: 1).map { step in
            Self.ping((10.0, 149.85 + Double(step) * 0.01), Double(step) / 12)
        }
        let west = line.filter { $0.longitude < 149.955 }
        let east = line.filter { $0.longitude > 150.045 }
        let inside = line.filter { !west.contains($0) && !east.contains($0) }
        let trip = Self.trip([
            Self.stay((10.0, 149.9), .transit, pings: west, order: 0, locality: "West"),
            Self.stay(Self.home, .home, pings: inside, order: 1, locality: "Homeburg"),
            Self.stay((10.0, 150.1), .transit, pings: east, order: 2, locality: "East"),
        ], pings: line)
        let export = TripShareExport.export(trips: [trip], rings: rings, senderName: nil,
                                            exportedAt: Self.base, appVersion: nil)
        let shared = try #require(export.file.trips.first)
        let segments = TripShareGPX.segments(of: shared, exclusions: export.exclusions)
        #expect(segments.count == 2)
        #expect(segments.map(\.count) == [west.count, east.count])
        let gpx = TripShareGPX.document(for: [shared], exclusions: export.exclusions, name: nil,
                                        exportedAt: Self.base, languageTag: "en")
        #expect(gpx.components(separatedBy: "<trkseg>").count - 1 == 2)
        for point in Self.trackPoints(gpx) {
            #expect(Self.km(point.lat, point.lon, Self.home) > 5)
        }

        // Two fixes either side of the home, nothing removed between them.
        let across = [Self.ping((10.0, 149.95), 1), Self.ping((10.0, 150.05), 1.2)]
        let crossing = Self.trip([Self.stay((10.0, 149.95), .transit, pings: across, order: 0, locality: "Road")],
                                 pings: across)
        #expect(TripShareGPX.segments(of: crossing, exclusions: TripShareExclusions(rings: rings)).count == 2)
        #expect(TripShareGPX.segments(of: crossing, exclusions: TripShareExclusions()).count == 1)

        // A long gap breaks even far from any home.
        let gap = [Self.ping(Self.lakeside, 1), Self.ping(Self.lakeside, 1.5), Self.ping(Self.lakeside, 4)]
        let resting = Self.trip([Self.stay(Self.lakeside, pings: gap, order: 0, locality: "Lakeside")], pings: gap)
        #expect(TripShareGPX.segments(of: resting, exclusions: TripShareExclusions(rings: rings)).map(\.count)
                == [2, 1])
    }

    @Test("the card's route breaks around a dropped home stay and never draws through a home")
    func cardRouteSplits() throws {
        let rings = [Self.ring(Self.home, km: 5, from: -24 * 365)]
        func stop(_ place: Place, _ hours: Double, _ order: Int, _ category: StayCategory = .destination) -> (SharedStay, [SharedPing]) {
            let pings = [Self.ping(place, hours), Self.ping(place, hours + 1)]
            return (Self.stay(place, category, pings: pings, order: order, locality: "Stop \(order)"), pings)
        }
        let stops = [
            stop((10.0, 149.7), 1, 0), stop((10.1, 149.8), 4, 1),
            stop(Self.home, 8, 2, .home),
            stop((10.1, 150.2), 12, 3), stop((10.0, 150.3), 16, 4),
        ]
        let trip = Self.trip(stops.map { $0.0 }, pings: stops.flatMap { $0.1 })
        let export = TripShareExport.export(trips: [trip], rings: rings, senderName: nil,
                                            exportedAt: Self.base, appVersion: nil)
        let shared = try #require(export.file.trips.first)
        let layout = try #require(TripShareMapGeometry.layout(for: shared, exclusions: export.exclusions))
        #expect(layout.route.map(\.count) == [2, 2])
        #expect(layout.stations.count == 4)

        // Two places either side of the home with nothing between: no line.
        let pair = [stop((10.0, 149.95), 1, 0), stop((10.0, 150.05), 3, 1)]
        let straight = Self.trip(pair.map { $0.0 }, pings: pair.flatMap { $0.1 })
        let crossing = try #require(TripShareMapGeometry.layout(
            for: straight, exclusions: TripShareExclusions(rings: rings)))
        #expect(crossing.route.isEmpty)
        let open = try #require(TripShareMapGeometry.layout(for: straight, exclusions: TripShareExclusions()))
        #expect(open.route.map(\.count) == [2])
    }

    // MARK: Share sheet

    /// A stored trip with one destination stay and its fixes.
    static func insertTrip(_ place: Place, hours: [Double], in context: ModelContext) -> Trip {
        let pings = hours.map {
            LocationPing(timestamp: at($0), latitude: place.lat, longitude: place.lon,
                         horizontalAccuracy: 20, h3IndexRes6: "861f8a6dfffffff")
        }
        pings.forEach(context.insert)
        let trip = Trip(startDate: at(hours.min()!))
        trip.endDate = at(hours.max()!)
        trip.isComplete = true
        context.insert(trip)
        let stay = Stay(startTime: at(hours.min()!), endTime: at(hours.max()!),
                        centroidLatitude: place.lat, centroidLongitude: place.lon,
                        h3IndexRes6: "861f8a6dfffffff", pingCount: pings.count, distanceFromHomeKm: 40,
                        pingIDs: pings.map(\.id), timeZoneIdentifier: "UTC")
        stay.category = .destination
        stay.orderInTrip = 0
        stay.locality = "Fixture"
        context.insert(stay)
        stay.trip = trip
        return trip
    }

    @Test("Share refuses a preview that a home change or a deleted trip made stale",
          .timeLimit(.minutes(2)))
    func shareRevalidates() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let lake = Self.insertTrip(Self.lakeside, hours: [10, 12, 14], in: context)
        let ridge = Self.insertTrip(Self.ridge, hours: [30, 32], in: context)
        try context.save()
        let ids = [lake.id, ridge.id]
        let homes = [Self.ring(Self.home, km: 5, from: -24 * 365)]
        func read(_ rings: [HomeRing]) async throws(TripShareStaging.StagingError) -> TripShareStaging.Prepared {
            try await TripShareStaging.prepare(tripIDs: ids, container: container, homeRings: { rings })
        }

        let preview = try await read(homes)
        #expect(preview.file.trips.count == 2)
        #expect(preview.isCurrent(try await read(homes)))

        // Unchanged: the items are handed over.
        let options = TripShareStaging.Options(overviewImage: false, travelLogFile: true, gpxRoute: true)
        let ready = try await TripShareStaging.stageIfCurrent(
            preview, options: options, senderName: nil, reread: { () async throws(TripShareStaging.StagingError) in
                try await read(homes) })
        let staged = try #require(ready.staged)
        #expect(staged.items.count == 2)
        #expect(staged.items.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        TripShareStaging.discard(staged)

        // A temporary home now covers the lakeside trip; a home's dates moved.
        let temporary = homes + [Self.ring(Self.lakeside, km: 5, from: 0, to: 20, temporary: true)]
        let refused = try await TripShareStaging.stageIfCurrent(
            preview, options: options, senderName: nil, reread: { () async throws(TripShareStaging.StagingError) in
                try await read(temporary) })
        #expect(refused.staged == nil)
        #expect(refused.current.file.trips.map(\.shareID) == [ridge.id])
        let redated = [Self.ring(Self.home, km: 5, from: -24 * 30)]
        #expect(!preview.isCurrent(try await read(redated)))

        // A trip deleted while the sheet was open.
        context.delete(lake)
        try context.save()
        let afterDelete = try await read(homes)
        #expect(!preview.isCurrent(afterDelete))
        #expect(afterDelete.file.trips.map(\.shareID) == [ridge.id])
        context.delete(ridge)
        try context.save()
        await #expect(throws: TripShareStaging.StagingError.tripsMissing) { try await read(homes) }
    }

    @Test("a Travel Log file larger than a recipient opens is refused before anything is written")
    func sizeLimit() async throws {
        let pings = (0..<200).map { Self.ping(Self.lakeside, Double($0) / 10) }
        let trip = Self.trip([Self.stay(Self.lakeside, pings: pings, order: 0, locality: "Lakeside")], pings: pings)
        let export = TripShareExport.export(trips: [trip], rings: [], senderName: nil,
                                            exportedAt: Self.base, appVersion: nil)
        let prepared = TripShareStaging.Prepared(file: export.file, omitted: 0, exclusions: export.exclusions)
        // The stage stamps its own time, so the limit keeps a margin.
        let size = try export.file.encoded().count
        let options = TripShareStaging.Options(overviewImage: false, travelLogFile: true, gpxRoute: true)
        await #expect(throws: TripShareStaging.StagingError.tooLarge) {
            try await TripShareStaging.stage(prepared, options: options, senderName: nil, maximumFileBytes: size / 2)
        }
        let staged = try await TripShareStaging.stage(prepared, options: options, senderName: nil,
                                                      maximumFileBytes: size + 1_000)
        #expect(staged.items.count == 2)
        TripShareStaging.discard(staged)
        #expect(!FileManager.default.fileExists(atPath: staged.directory.path))
    }

    // MARK: Property

    @Test("over many random trips, nothing shared touches a home in its protected time")
    func randomTripsNeverTouchProtectedTime() throws {
        var rng = SeededGenerator(seed: 0x5EED_7123)
        let p1: Place = (10.0, 150.0), p2: Place = (10.2, 150.3), p3: Place = (9.9, 150.4), p4: Place = (10.3, 150.0)
        let learned = HomeMembership(
            seed: .fallbackDisc(latitude: p1.lat, longitude: p1.lon),
            orbitDiscs: [HomeOrbit.OrbitDisc(
                centerLatitude: p1.lat + 0.03, centerLongitude: p1.lon + 0.03, radiusKm: 3,
                validity: [DateInterval(start: Self.at(24), end: Self.at(72))], returnTimes: [])],
            includeDiscs: [(latitude: p1.lat - 0.04, longitude: p1.lon, radiusKm: 1.5)])
        let rings = [
            Self.ring(p1, km: 4, from: -24, to: 120, membership: learned),
            Self.ring(p2, km: 6, from: 120),
            Self.ring(p3, km: 3, from: 288),
            Self.ring(p4, km: 5, from: 48, to: 96, temporary: true),
            Self.ring(p2, km: 8, from: 192, to: 216, temporary: true),
        ]
        let centres = [p1, p2, p3, p4]
        let categories: [StayCategory] = [.destination, .destination, .destination, .destination,
                                          .transit, .home, .routine]

        func near(_ place: Place, _ km: Double) -> Place {
            let d = km / 111
            return (place.lat + Double.random(in: -d...d, using: &rng),
                    place.lon + Double.random(in: -d...d, using: &rng))
        }
        func anywhere() -> Place {
            Bool.random(using: &rng)
                ? near(centres.randomElement(using: &rng)!, 9)
                : (Double.random(in: 9.8...10.4, using: &rng), Double.random(in: 149.8...150.6, using: &rng))
        }

        // The default run's trips are the first 24 of the soak run's 70.
        let tripCount = TestSupport.soak ? 70 : 24
        var trips: [SharedTrip] = []
        for _ in 0..<tripCount {
            var clock = Double.random(in: -96...300, using: &rng)
            var stays: [SharedStay] = []
            var pings: [SharedPing] = []
            var visits: [SharedVisit] = []
            for order in 0..<Int.random(in: 2...7, using: &rng) {
                let centre = anywhere()
                let length = Double.random(in: 0.5...30, using: &rng)
                let own = (0..<Int.random(in: 1...10, using: &rng)).map { _ in
                    Self.ping(near(centre, 3), clock + Double.random(in: 0...length, using: &rng))
                }
                let stay = Self.stay(centre, categories.randomElement(using: &rng)!, pings: own,
                                     from: clock, to: clock + length, order: order, locality: "Place \(order)")
                for _ in 0..<Int.random(in: 0...2, using: &rng) {
                    let arrival = clock + Double.random(in: -6...length, using: &rng)
                    let place = Bool.random(using: &rng) ? near(centre, 2) : near(centres.randomElement(using: &rng)!, 4)
                    visits.append(Self.visit(place, arrival, arrival + Double.random(in: 0.2...20, using: &rng),
                                             stay: stay.id))
                }
                stays.append(stay)
                pings += own
                clock += length + Double.random(in: 0.2...12, using: &rng)
            }
            trips.append(Self.trip(stays, pings: pings, visits: visits, title: "Place 0"))
        }

        let export = TripShareExport.export(trips: trips, rings: rings, senderName: nil,
                                            exportedAt: Self.base, appVersion: nil)
        #expect(!export.file.trips.isEmpty)
        var checkedLines = 0
        for trip in export.file.trips {
            Self.expectNothingProtected(trip, rings: rings)
            for segment in TripShareGPX.segments(of: trip, exclusions: export.exclusions) {
                for (a, b) in zip(segment, segment.dropFirst()) {
                    let span = TripShareExport.span(a.timestamp, b.timestamp)
                    for step in 0...40 {
                        let t = Double(step) / 40
                        let lat = a.latitude + (b.latitude - a.latitude) * t
                        let lon = a.longitude + (b.longitude - a.longitude) * t
                        #expect(!Self.protectedSomewhere(lat, lon, span, rings), "GPX line crosses a home")
                    }
                    checkedLines += 1
                }
            }
            guard let layout = TripShareMapGeometry.layout(for: trip, exclusions: export.exclusions) else { continue }
            let stations = TripShareMapGeometry.stations(of: trip)
            let points = stations.map {
                layout.frame.point(TripShareMapGeometry.project(latitude: $0.latitude, unwrappedLongitude: $0.longitude))
            }
            for run in layout.route {
                var cursor = 0
                let indices = run.map { point -> Int in
                    let index = points[cursor...].firstIndex(of: point)!
                    cursor = index
                    return index
                }
                for (offset, curve) in TripShareMapGeometry.curves(run).enumerated() {
                    let span = TripShareExport.span(stations[indices[offset]].end, stations[indices[offset + 1]].start)
                    for step in 0...TripShareMapGeometry.curveSamples {
                        let position = TripShareMapGeometry.coordinate(
                            curve.point(at: Double(step) / Double(TripShareMapGeometry.curveSamples)),
                            frame: layout.frame)
                        #expect(!Self.protectedSomewhere(position.latitude, position.longitude, span, rings),
                                "card route crosses a home")
                    }
                    checkedLines += 1
                }
            }
        }
        #expect(checkedLines > tripCount * 10 / 7)
    }

    // MARK: Oracle

    /// Every shared fix, Visit and stay, by brute force over its span.
    static func expectNothingProtected(_ trip: SharedTrip, rings: [HomeRing]) {
        for ping in trip.pings {
            #expect(!protectedSomewhere(ping.latitude, ping.longitude,
                                        DateInterval(start: ping.timestamp, duration: 0), rings), "fix")
        }
        for visit in trip.visits {
            let span = TripShareExport.span(visit.arrivalDate, visit.departureDate ?? visit.arrivalDate)
            #expect(!protectedSomewhere(visit.latitude, visit.longitude, span, rings), "Visit")
        }
        for stay in trip.stays {
            #expect(!protectedSomewhere(stay.latitude, stay.longitude,
                                        TripShareExport.span(stay.startTime, stay.endTime), rings), "stay")
        }
        #expect(trip.startDate == trip.stays.map(\.startTime).min())
    }

    /// `matchesHome` read at the span's ends, on a grid across it, and at
    /// and beside every ring edge inside it.
    static func protectedSomewhere(_ lat: Double, _ lon: Double, _ span: DateInterval, _ rings: [HomeRing]) -> Bool {
        var instants = [span.start, span.end]
        instants += (1..<64).map { span.start.addingTimeInterval(span.duration * Double($0) / 64) }
        for ring in rings {
            var edges = [ring.startedAt] + [ring.endedAt].compactMap { $0 }
            for disc in ring.membership?.orbitDiscs ?? [] {
                edges += disc.validity.flatMap { [$0.start, $0.end] }
            }
            for edge in edges {
                instants += [edge, edge.addingTimeInterval(-1), edge.addingTimeInterval(1)].filter(span.contains)
            }
        }
        return instants.contains {
            TripClassifier.matchesHome(stayStart: $0, latitude: lat, longitude: lon, homes: rings)
        }
    }

    static func trackPoints(_ gpx: String) -> [(lat: Double, lon: Double)] {
        let pattern = try! NSRegularExpression(pattern: #"<trkpt lat="([-0-9.]+)" lon="([-0-9.]+)">"#)
        let range = NSRange(gpx.startIndex..., in: gpx)
        return pattern.matches(in: gpx, range: range).compactMap { match in
            guard let lat = Range(match.range(at: 1), in: gpx), let lon = Range(match.range(at: 2), in: gpx)
            else { return nil }
            return (Double(gpx[lat])!, Double(gpx[lon])!)
        }
    }
}

/// SplitMix64: the same trips on every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
