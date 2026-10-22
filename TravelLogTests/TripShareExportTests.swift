//
//  TripShareExportTests.swift
//  TravelLogTests
//
//  The sender side of trip sharing, as pure values: every home-derived row
//  and field stays out of the file, the GPX route has the GPX 1.1 shape, and
//  the file format refuses what it does not know. Places and dates are
//  fictional fixtures.
//

import Testing
import Foundation
@testable import TravelLog

@Suite("Trip share export")
struct TripShareExportTests {

    // Fictional fixtures: a home town, its temporary home and two places
    // well outside both.
    static let home = (lat: 51.8, lon: 10.8)
    static let temporaryHome = (lat: 49.3, lon: 11.4)
    static let lakeside = (lat: 52.2, lon: 12.1)
    static let hillTown = (lat: 51.2, lon: 11.7)
    static let base = Date(timeIntervalSinceReferenceDate: 700_000_000)

    static func ping(_ place: (lat: Double, lon: Double), _ hours: Double, source: String = "liveSLC") -> SharedPing {
        SharedPing(id: UUID(), timestamp: base.addingTimeInterval(hours * 3600),
                   latitude: place.lat + 0.001, longitude: place.lon - 0.001,
                   horizontalAccuracy: 20, altitude: 210, verticalAccuracy: 8, sourceRaw: source)
    }

    static func stay(_ place: (lat: Double, lon: Double), _ category: StayCategory,
                     pings: [SharedPing], order: Int, locality: String, country: String = "FR") -> SharedStay {
        SharedStay(
            id: UUID(), startTime: pings.map(\.timestamp).min()!, endTime: pings.map(\.timestamp).max()!,
            durationMinutes: 60, categoryRaw: category.rawValue,
            latitude: place.lat, longitude: place.lon, h3IndexRes6: "861f8a6dfffffff",
            pingCount: pings.count, pingIDs: pings.map(\.id), orderInTrip: order,
            locality: locality, subLocality: nil, administrativeArea: nil, country: nil,
            isoCountryCode: country, metroName: nil, islandName: nil, isAirport: false,
            sourceRaw: "liveSLC", userOverridden: false, continuesPreviousTrip: false,
            transitFromPreviousRaw: "car", distanceFromPreviousKm: 123,
            stepsWalked: 4_000, weatherData: Data([1, 2, 3]), avgTemperatureC: 21,
            weatherConditionRaw: "clear", precipitationMm: 0, dayKey: base,
            timeZoneIdentifier: "Europe/Paris")
    }

    /// The sender's real home ring, and a temporary home claiming only
    /// hours 40 to 60 of the trip.
    static var rings: [TripClassifier.HomeRing] {
        var temporary = TripClassifier.HomeRing(
            latitude: temporaryHome.lat, longitude: temporaryHome.lon, radiusKm: 10,
            startedAt: base.addingTimeInterval(40 * 3600), endedAt: base.addingTimeInterval(60 * 3600))
        temporary.claimsPrehistory = false
        temporary.isTemporary = true
        return [
            TripClassifier.HomeRing(
                latitude: home.lat, longitude: home.lon, radiusKm: 15,
                startedAt: base.addingTimeInterval(-365 * 86_400), endedAt: nil),
            temporary,
        ]
    }

    static func distanceKm(_ lat: Double, _ lon: Double, _ place: (lat: Double, lon: Double)) -> Double {
        TripShareExport.haversineKm(lat, lon, place.lat, place.lon)
    }

    /// A trip that starts at home, visits the lakeside (with a fix taken
    /// back home in its window), passes the temporary home inside and
    /// outside its dates, and holds a home and a routine stay.
    static func mixedTrip() -> (trip: SharedTrip, keptStayIDs: Set<UUID>, homePingIDs: Set<UUID>) {
        let atHome = [ping(home, 0), ping(home, 1)]
        let lakesidePings = [ping(lakeside, 5), ping(lakeside, 8), ping(lakeside, 20)]
        let strayHomePing = ping(home, 12)
        let insideTemporary = [ping(temporaryHome, 45), ping(temporaryHome, 47)]
        let outsideTemporaryDates = [ping(temporaryHome, 70), ping(temporaryHome, 72)]
        let hill = [ping(hillTown, 80), ping(hillTown, 83)]
        let routine = [ping(hillTown, 90), ping(hillTown, 91)]

        let homeStay = stay(home, .home, pings: atHome, order: 0, locality: "Homeburg")
        let lakesideStay = stay(lakeside, .destination, pings: lakesidePings + [strayHomePing], order: 1,
                                locality: "Lakeside", country: "CH")
        let temporaryStay = stay(temporaryHome, .destination, pings: insideTemporary, order: 2, locality: "Portside")
        let laterPortStay = stay(temporaryHome, .destination, pings: outsideTemporaryDates, order: 3, locality: "Portside")
        let transitStay = stay(hillTown, .transit, pings: hill, order: 4, locality: "Hill Town")
        let routineStay = stay(hillTown, .routine, pings: routine, order: 5, locality: "Hill Town")
        let trip = SharedTrip(
            shareID: UUID(), customName: "Spring Loop", canonicalTitle: "A Spring Loop",
            startDate: base, endDate: base.addingTimeInterval(91 * 3600), isComplete: true,
            countryCodes: ["FR", "CH"], destinationSummary: "Homeburg, Lakeside, Portside",
            stays: [homeStay, lakesideStay, temporaryStay, laterPortStay, transitStay, routineStay],
            pings: atHome + lakesidePings + [strayHomePing] + insideTemporary + outsideTemporaryDates + hill + routine,
            visits: [
                SharedVisit(id: UUID(), arrivalDate: base.addingTimeInterval(5 * 3600),
                            departureDate: base.addingTimeInterval(20 * 3600),
                            latitude: lakeside.lat, longitude: lakeside.lon,
                            horizontalAccuracy: 30, stayID: lakesideStay.id),
                SharedVisit(id: UUID(), arrivalDate: base.addingTimeInterval(0.5 * 3600),
                            departureDate: base.addingTimeInterval(1 * 3600),
                            latitude: home.lat, longitude: home.lon,
                            horizontalAccuracy: 30, stayID: homeStay.id),
            ])
        return (trip, [lakesideStay.id, laterPortStay.id, transitStay.id],
                Set((atHome + [strayHomePing] + insideTemporary).map(\.id)))
    }

    @Test("export drops every home, temporary-home and routine row, and every home-derived field")
    func exportExcludesHomeDerivedRows() throws {
        let (trip, keptStayIDs, homePingIDs) = Self.mixedTrip()
        let filtered = try #require(TripShareExport.excludingHomeAreas(trip, rings: Self.rings))

        #expect(Set(filtered.stays.map(\.id)) == keptStayIDs)
        #expect(filtered.stays.allSatisfy {
            $0.categoryRaw == StayCategory.destination.rawValue || $0.categoryRaw == StayCategory.transit.rawValue
        })
        // No fix, Visit or stay inside a home anchor at its time.
        #expect(filtered.pings.allSatisfy { !homePingIDs.contains($0.id) })
        for ping in filtered.pings {
            #expect(!TripShareExport.isInsideHome(ping.timestamp, latitude: ping.latitude,
                                                 longitude: ping.longitude, rings: Self.rings))
        }
        #expect(filtered.visits.count == 1)
        #expect(filtered.visits.allSatisfy { Self.distanceKm($0.latitude, $0.longitude, Self.home) > 50 })
        let keptPingIDs = Set(filtered.pings.map(\.id))
        for stay in filtered.stays {
            #expect(Set(stay.pingIDs).isSubset(of: keptPingIDs))
            #expect(stay.pingCount == stay.pingIDs.count)
        }

        // The stay that lost its home fix is rebuilt from what is left: its
        // window and centroid no longer reach home, and its weather goes.
        let lakeside = try #require(filtered.stays.first { $0.locality == "Lakeside" })
        #expect(lakeside.pingIDs.count == 3)
        #expect(lakeside.endTime == Self.base.addingTimeInterval(20 * 3600))
        #expect(Self.distanceKm(lakeside.latitude, lakeside.longitude, Self.lakeside) < 1)
        #expect(lakeside.weatherData == nil && lakeside.avgTemperatureC == nil && lakeside.dayKey == nil)
        // The first leg starts at the sender's home, and the leg after a
        // dropped stay starts somewhere the file does not show.
        #expect(lakeside.transitFromPreviousRaw == nil && lakeside.distanceFromPreviousKm == nil)
        let laterPort = try #require(filtered.stays.first { $0.locality == "Portside" })
        #expect(laterPort.transitFromPreviousRaw == nil && laterPort.distanceFromPreviousKm == nil)
        // A leg between two shared stays keeps its mode, measured between them.
        let transit = try #require(filtered.stays.first { $0.locality == "Hill Town" })
        #expect(transit.transitFromPreviousRaw == "car")
        let leg = try #require(transit.distanceFromPreviousKm)
        #expect(abs(leg - TripShareExport.haversineKm(laterPort.latitude, laterPort.longitude,
                                                      transit.latitude, transit.longitude)) < 0.001)

        // Trip fields come from the kept stays only.
        #expect(filtered.startDate == Self.base.addingTimeInterval(5 * 3600))
        #expect(filtered.endDate == Self.base.addingTimeInterval(83 * 3600))
        #expect(filtered.countryCodes == ["CH", "FR"])
        #expect(filtered.destinationSummary == "Lakeside, Portside")
        #expect(!filtered.destinationSummary.contains("Homeburg"))

        // Nothing home-derived, photo-related or device-local is in the file.
        let file = TripShareFile(exportedAt: Self.base, senderName: "Sam", appVersion: "1.0", trips: [filtered])
        let json = try #require(String(data: try file.encoded(), encoding: .utf8))
        for forbidden in ["distanceFromHomeKm", "temporaryHome", "photo", "Photo", "localIdentifier",
                          "hidden", "pinned", "favourite", "favorite", "Homeburg"] {
            #expect(!json.contains(forbidden), "file carries \(forbidden)")
        }
        #expect(json.contains(#""shareFormatVersion":1"#))
        #expect(json.contains(trip.shareID.uuidString))
    }

    @Test("a trip that is all home evidence is left out of the file")
    func allHomeTripIsOmitted() {
        let atHome = [Self.ping(Self.home, 0), Self.ping(Self.home, 3)]
        let trip = SharedTrip(
            shareID: UUID(), startDate: Self.base, endDate: Self.base.addingTimeInterval(3 * 3600),
            isComplete: true, stays: [Self.stay(Self.home, .destination, pings: atHome, order: 0, locality: "Homeburg")],
            pings: atHome)
        let (file, omitted) = TripShareExport.makeFile(
            trips: [trip], rings: Self.rings, senderName: "  ", exportedAt: Self.base, appVersion: nil)
        #expect(file.trips.isEmpty)
        #expect(omitted == 1)
        #expect(file.senderName == nil)
    }

    @Test("the GPX route lists every waypoint first, then one named track per trip with fixes in time order")
    func gpxShape() throws {
        let (mixed, _, _) = Self.mixedTrip()
        let first = try #require(TripShareExport.excludingHomeAreas(mixed, rings: Self.rings))
        var second = SharedTrip(
            shareID: UUID(), customName: "Fish & Chips <Weekend>", startDate: Self.base.addingTimeInterval(200 * 3600),
            endDate: Self.base.addingTimeInterval(230 * 3600), isComplete: true)
        // Out of order on purpose: the track must sort them.
        second.pings = [Self.ping(Self.hillTown, 230), Self.ping(Self.hillTown, 200), Self.ping(Self.hillTown, 215)]
        second.stays = [Self.stay(Self.hillTown, .destination, pings: second.pings, order: 0, locality: "Hill Town")]

        let gpx = TripShareGPX.document(for: [first, second], exclusions: TripShareExclusions(rings: Self.rings),
                                        name: "Our Trips", exportedAt: Self.base, languageTag: "en")
        let parsed = try GPXProbe.parse(gpx)

        #expect(parsed.version == "1.1")
        #expect(gpx.contains(#"xmlns="http://www.topografix.com/GPX/1/1""#))
        #expect(parsed.metadataName == "Our Trips")
        // GPX 1.1 orders every waypoint before every track.
        let firstTrack = try #require(parsed.order.firstIndex(of: "trk"))
        #expect(parsed.order.lastIndex(of: "wpt").map { $0 < firstTrack } == true)
        #expect(parsed.waypoints.map(\.name) == first.destinations.map(\.locality) + ["Hill Town"])
        #expect(parsed.tracks.map(\.name) == ["Spring Loop", "Fish & Chips <Weekend>"])
        #expect(parsed.tracks[0].points.count == first.pings.count)
        #expect(parsed.tracks[1].points.count == 3)
        for track in parsed.tracks {
            let times = track.points.map(\.time)
            #expect(times == times.sorted())
            #expect(track.points.allSatisfy { $0.elevation == "210.0" })
        }
        // Home exclusion carries into the route.
        for point in parsed.tracks.flatMap(\.points) {
            #expect(Self.distanceKm(point.lat, point.lon, Self.home) > 15)
        }
        #expect(gpx.contains("Fish &amp; Chips &lt;Weekend&gt;"))
    }

    @Test("the file round-trips and refuses unknown versions, damage and emptiness")
    func fileFormat() throws {
        let (mixed, _, _) = Self.mixedTrip()
        let trip = try #require(TripShareExport.excludingHomeAreas(mixed, rings: Self.rings))
        let file = TripShareFile(exportedAt: Self.base, senderName: "Sam", appVersion: "1.0", trips: [trip, trip])
        let decoded = try TripShareFile.decode(try file.encoded())
        #expect(decoded.trips == [trip])
        #expect(decoded.senderName == "Sam")
        #expect(decoded.exportedAt == Self.base)

        #expect(throws: TripShareFile.DecodeError.unsupportedVersion(2)) {
            try TripShareFile.decode(Data(#"{"shareFormatVersion":2,"exportedAt":0,"trips":[]}"#.utf8))
        }
        #expect(throws: TripShareFile.DecodeError.unreadable) {
            try TripShareFile.decode(Data("not a trip".utf8))
        }
        #expect(throws: TripShareFile.DecodeError.empty) {
            try TripShareFile.decode(Data(#"{"shareFormatVersion":1,"exportedAt":0,"trips":[]}"#.utf8))
        }
        // Impossible rows are dropped, unknown keys ignored.
        let json = #"""
        {"shareFormatVersion":1,"exportedAt":0,"futureField":true,"trips":[{"shareID":"\#(UUID().uuidString)",
        "startDate":700000000,"isComplete":true,"pings":[
        {"id":"\#(UUID().uuidString)","timestamp":700000000,"latitude":95,"longitude":4,"horizontalAccuracy":10,"sourceRaw":"liveSLC"},
        {"id":"\#(UUID().uuidString)","timestamp":700000100,"latitude":45,"longitude":4,"horizontalAccuracy":10,"sourceRaw":"liveSLC"}]}]}
        """#
        let lenient = try TripShareFile.decode(Data(json.utf8))
        #expect(lenient.trips.first?.pings.count == 1)
    }
}

/// Reads a GPX document back with `XMLParser`, so the test checks real XML.
private final class GPXProbe: NSObject, XMLParserDelegate {
    struct Point { var lat: Double; var lon: Double; var time = ""; var elevation: String? }
    struct Waypoint { var name: String? }
    struct Track { var name: String?; var points: [Point] = [] }

    var version: String?
    var metadataName: String?
    var order: [String] = []
    var waypoints: [Waypoint] = []
    var tracks: [Track] = []
    private var path: [String] = []
    private var text = ""

    static func parse(_ gpx: String) throws -> GPXProbe {
        let probe = GPXProbe()
        let parser = XMLParser(data: Data(gpx.utf8))
        parser.delegate = probe
        guard parser.parse() else { throw parser.parserError ?? CocoaError(.fileReadCorruptFile) }
        return probe
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        path.append(name)
        text = ""
        switch name {
        case "gpx":
            version = attributes["version"]
        case "wpt":
            order.append(name)
            waypoints.append(Waypoint())
        case "trk":
            order.append(name)
            tracks.append(Track())
        case "trkpt":
            tracks[tracks.count - 1].points.append(Point(
                lat: Double(attributes["lat"] ?? "") ?? .nan, lon: Double(attributes["lon"] ?? "") ?? .nan))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let parent = path.dropLast().last
        switch (name, parent) {
        case ("name", "metadata"): metadataName = text
        case ("name", "wpt"): waypoints[waypoints.count - 1].name = text
        case ("name", "trk"): tracks[tracks.count - 1].name = text
        case ("time", "trkpt"):
            let t = tracks.count - 1
            tracks[t].points[tracks[t].points.count - 1].time = text
        case ("ele", "trkpt"):
            let t = tracks.count - 1
            tracks[t].points[tracks[t].points.count - 1].elevation = text
        default: break
        }
        path.removeLast()
        text = ""
    }
}
