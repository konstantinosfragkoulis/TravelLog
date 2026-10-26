import Foundation
import SwiftData
import Testing
@testable import TravelLog

/// The ends a user sets on a recorded flight: storage, the record wearing
/// them, the Airports list and the Flight Log writer.
@MainActor
struct FlightRouteOverridesTests {
    private let base = Date(timeIntervalSince1970: 1_689_718_400)

    private struct Fixture {
        let context: ModelContext
        let defaults: UserDefaults
        let origin: Stay
        let arrival: Stay
    }

    /// An airport origin, then a recorded flight to a town with no fix at
    /// any airport: the first stay after landing is the arrival.
    private func fixture(mode: TransitMode = .flight) throws -> Fixture {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let defaults = try #require(UserDefaults(suiteName: "FlightRouteOverridesTests.\(UUID().uuidString)"))
        let origin = stay(start: 0, end: 2, latitude: 37.9364, longitude: 23.9445)
        origin.isAirport = true
        origin.isoCountryCode = "GR"
        let arrival = stay(start: 6, end: 30, latitude: 52.4, longitude: 4.9)
        arrival.category = .destination
        arrival.isoCountryCode = "NL"
        arrival.transitFromPreviousRaw = mode.rawValue
        context.insert(origin)
        context.insert(arrival)
        try context.save()
        return Fixture(context: context, defaults: defaults, origin: origin, arrival: arrival)
    }

    private func stay(start: Double, end: Double, latitude: Double, longitude: Double) -> Stay {
        let stay = Stay(startTime: base.addingTimeInterval(start * 3600),
                        endTime: base.addingTimeInterval(end * 3600),
                        centroidLatitude: latitude, centroidLongitude: longitude,
                        h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 100, pingIDs: [])
        stay.category = .transit
        stay.sourceRaw = DataSource.photoImport.rawValue
        stay.transitFromPreviousRaw = TransitMode.unknown.rawValue
        return stay
    }

    private func rows(_ fixture: Fixture) throws -> [CollectionsAggregator.StayRow] {
        try fixture.context.fetch(FetchDescriptor<Stay>()).map { CollectionsAggregator.StayRow($0) }
    }

    private func flight(_ fixture: Fixture) throws -> CollectionsAggregator.FlightRecord {
        try #require(try CollectionsAggregator.flightLogRecords(
            rows: rows(fixture), predecessorOnly: [], dismissedCandidates: [],
            flightTimes: [:], flightStops: FlightStops.all(defaults: fixture.defaults),
            flightRoutes: FlightRouteOverrides.all(defaults: fixture.defaults)).flights.first)
    }

    private func airport(_ code: String) throws -> AirportRecord {
        try #require(AirportDetector.shared.airport(code: code))
    }

    // MARK: Storage

    @Test("entries round-trip, the later one wins, and a reset keeps a tombstone")
    func storageRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "FlightRouteOverridesTests.\(UUID().uuidString)"))
        let id = UUID()
        FlightRouteOverrides.set(.init(arrival: "RTM"), for: id, defaults: defaults)
        #expect(FlightRouteOverrides.route(for: id, defaults: defaults) == .init(arrival: "RTM"))
        #expect(defaults.stringArray(forKey: FlightRouteOverrides.defaultsKey) == ["\(id.uuidString) - RTM"])
        FlightRouteOverrides.set(.init(departure: "FRA", arrival: "RTM"), for: id, defaults: defaults)
        #expect(FlightRouteOverrides.route(for: id, defaults: defaults) == .init(departure: "FRA", arrival: "RTM"))
        FlightRouteOverrides.set(.init(), for: id, defaults: defaults)
        #expect(FlightRouteOverrides.route(for: id, defaults: defaults)?.isEmpty == true)
        #expect(defaults.stringArray(forKey: FlightRouteOverrides.defaultsKey) == [id.uuidString])
        FlightRouteOverrides.clear(id, defaults: defaults)
        #expect(FlightRouteOverrides.route(for: id, defaults: defaults) == nil)
        #expect(defaults.object(forKey: FlightRouteOverrides.defaultsKey) == nil)
    }

    @Test("unreadable entries are skipped")
    func unreadableEntriesSkip() {
        let id = UUID().uuidString
        for entry in ["\(id) RTM", "\(id) rtm -", "\(id) RTM RTM", "\(id) - - -", "nope - RTM"] {
            #expect(FlightRouteOverrides.parse(entry) == nil, "\(entry)")
        }
        #expect(FlightRouteOverrides.parse("\(id) - -")?.route.isEmpty == true)
    }

    // MARK: The record

    @Test("a named arrival replaces the detected one, and a reset puts it back")
    func namedArrivalReplacesDetected() throws {
        let fixture = try fixture()
        let detected = try flight(fixture)
        #expect(detected.departureCode == "ATH")
        #expect(detected.arrivalCode != "RTM")
        #expect(detected.userRoute == nil)

        FlightRouteOverrides.set(.init(arrival: "RTM"), for: fixture.arrival.id, defaults: fixture.defaults)
        let named = try flight(fixture)
        let ath = try airport("ATH"), rtm = try airport("RTM")
        #expect(named.arrivalCode == "RTM")
        #expect(named.arrivalAirportName == rtm.name)
        #expect(named.arrivalName == rtm.city)
        #expect(named.arrivalLatitude == rtm.lat && named.arrivalLongitude == rtm.lon)
        #expect(named.distanceKm == CollectionsAggregator.haversineKm(lat1: ath.lat, lon1: ath.lon,
                                                                      lat2: rtm.lat, lon2: rtm.lon))
        #expect(named.estimatedHours == CollectionsAggregator.estimatedHours(distanceKm: named.distanceKm))
        #expect(named.isInternational == true)
        #expect(named.userRoute == .init(arrival: "RTM"))
        #expect(named.annotationSnapshot?.route == .init(arrival: "RTM"))
        // The window, places and date stay as the data saw them.
        #expect(named.arrivalPlace == detected.arrivalPlace)
        #expect(named.date == detected.date && named.departureWindowStart == detected.departureWindowStart)

        let reset = named.applyingRoute(.init()) { AirportDetector.shared.airport(code: $0) }
        #expect(reset.arrivalCode == detected.arrivalCode)
        #expect(reset.distanceKm == detected.distanceKm)
        #expect(reset.userRoute == nil && reset.detectedRoute == nil)
        // Applying again over a named route starts from the detected one.
        let again = named.applyingRoute(.init(departure: "FRA")) { AirportDetector.shared.airport(code: $0) }
        #expect(again.departureCode == "FRA" && again.arrivalCode == detected.arrivalCode)
    }

    @Test("one airport at both ends or an unknown code leaves the detected route")
    func unusableRoutesLeaveDetected() throws {
        let fixture = try fixture()
        let detected = try flight(fixture)
        let resolve: (String) -> AirportRecord? = { AirportDetector.shared.airport(code: $0) }
        #expect(detected.applyingRoute(.init(arrival: "ATH"), resolve: resolve) == detected)
        #expect(detected.applyingRoute(.init(arrival: "ZZ9"), resolve: resolve) == detected)
    }

    private func candidate(_ fixture: Fixture) throws -> CollectionsAggregator.PossibleFlight {
        try #require(try CollectionsAggregator.flightLogRecords(
            rows: rows(fixture), predecessorOnly: [], dismissedCandidates: [],
            flightTimes: [:], flightStops: [:],
            flightRoutes: FlightRouteOverrides.all(defaults: fixture.defaults)).candidates.first {
                $0.arrivalIdentifier == fixture.arrival.persistentModelID
            })
    }

    @Test("Confirm saves the ends set on a possible flight, which its question then names")
    func confirmSavesCandidateRoute() throws {
        let fixture = try fixture(mode: .unknown)
        let shown = try candidate(fixture)
        let target = try #require(FlightLogAuthority.Target(candidate: shown))
        let status = FlightLogAuthority.apply(.confirm(route: .init(arrival: "RTM")), target: target,
                                              context: fixture.context, defaults: fixture.defaults).status
        #expect(status == .committed)
        #expect(FlightRouteOverrides.route(for: fixture.arrival.id, defaults: fixture.defaults) == .init(arrival: "RTM"))
        // The row keeps the leg the data measured, not the named route's.
        let stored = try #require(try ModelContext(fixture.context.container).fetch(FetchDescriptor<Stay>()).first {
            $0.persistentModelID == fixture.arrival.persistentModelID
        })
        #expect(stored.distanceFromPreviousKm == (shown.legKm ?? shown.record.distanceKm))
        #expect(try flight(fixture).arrivalCode == "RTM")
    }

    @Test("a saved route shows on a possible flight, and Confirm keeps the measured leg")
    func candidateWearsSavedRoute() throws {
        let fixture = try fixture(mode: .unknown)
        let detected = try candidate(fixture)
        FlightRouteOverrides.set(.init(arrival: "RTM"), for: fixture.arrival.id, defaults: fixture.defaults)
        let named = try candidate(fixture)
        let rtm = try airport("RTM")
        #expect(named.record.arrivalCode == "RTM" && named.record.arrivalName == rtm.city)
        let target = try #require(FlightLogAuthority.Target(candidate: named))
        #expect(target.distanceKm == (detected.legKm ?? detected.record.distanceKm))
        // An editor that saw no route is stale once one is saved.
        let stale = try #require(FlightLogAuthority.Target(candidate: detected))
        #expect(FlightLogAuthority.apply(.confirm(route: .init(arrival: "EIN")), target: stale,
                                         context: fixture.context, defaults: fixture.defaults).status == .rejected)
    }

    @Test("a stop at a named end is left out of the route")
    func stopAtNamedEndDrops() throws {
        let fixture = try fixture()
        FlightStops.set(["FRA"], for: fixture.arrival.id, defaults: fixture.defaults)
        FlightRouteOverrides.set(.init(arrival: "FRA"), for: fixture.arrival.id, defaults: fixture.defaults)
        let record = try flight(fixture)
        #expect(record.arrivalCode == "FRA")
        #expect(record.stops == nil)
    }

    @Test("a named end joins the Airports list as flown through")
    func namedEndJoinsAirports() throws {
        let fixture = try fixture()
        let result = try CollectionsAggregator.aggregate(
            rows: rows(fixture), predecessorOnly: [], dismissedCandidates: [],
            flightTimes: [:], flightStops: [:],
            flightRoutes: [fixture.arrival.id: .init(arrival: "RTM")], checkCancellation: {})
        let entry = try #require(result.airports.first { $0.code == "RTM" })
        #expect(entry.flownThrough)
        #expect(entry.stayCount == 0 && entry.connectionCount == 1)
        #expect(result.flights.first?.arrivalCode == "RTM")
    }

    // MARK: Writer

    @Test("Set Route saves the ends, refuses a stale editor and records a reset")
    func setRouteWrites() throws {
        let fixture = try fixture()
        func apply(_ route: FlightRouteOverrides.Route,
                   _ target: FlightLogAuthority.Target) -> FlightLogAuthority.Result {
            FlightLogAuthority.apply(.setRoute(route), target: target, context: fixture.context,
                                     defaults: fixture.defaults)
        }
        let target = try #require(FlightLogAuthority.Target(record: try flight(fixture)))
        let saved = apply(.init(arrival: "RTM"), target)
        #expect(saved.status == .committed)
        #expect(FlightRouteOverrides.route(for: fixture.arrival.id, defaults: fixture.defaults) == .init(arrival: "RTM"))
        // The editor that saw no route is stale now.
        #expect(apply(.init(arrival: "EIN"), target).status == .rejected)
        let advanced = try #require(saved.updatedTarget)
        #expect(apply(.init(arrival: "RTM"), advanced).status == .unchanged)
        #expect(apply(.init(departure: "RTM", arrival: "RTM"), advanced).status == .rejected)
        #expect(apply(.init(), advanced).status == .committed)
        #expect(FlightRouteOverrides.route(for: fixture.arrival.id, defaults: fixture.defaults)?.isEmpty == true)
    }

    @Test("a backup carries the routes, and this device's entry stays the later one")
    func backupCarriesRoutes() throws {
        let defaults = try #require(UserDefaults(suiteName: "FlightRouteOverridesTests.\(UUID().uuidString)"))
        let id = UUID()
        FlightRouteOverrides.set(.init(arrival: "RTM"), for: id, defaults: defaults)
        let preferences = BackupPreferences.current(defaults: defaults, ubiquitous: defaults)
        #expect(preferences.flightRoutes == [FlightRouteOverrides.entry(id: id, route: .init(arrival: "RTM"))])
        let decoded = try JSONDecoder().decode(BackupPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded.flightRoutes == preferences.flightRoutes)

        let other = try #require(UserDefaults(suiteName: "FlightRouteOverridesTests.\(UUID().uuidString)"))
        FlightRouteOverrides.set(.init(arrival: "EIN"), for: id, defaults: other)
        #expect(BackupPreferences.restore(decoded, defaults: other, ubiquitous: other) == 1)
        #expect(FlightRouteOverrides.route(for: id, defaults: other) == .init(arrival: "EIN"))
    }
}
