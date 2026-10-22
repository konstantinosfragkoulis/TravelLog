import Foundation
import Testing
@testable import TravelLog

@MainActor
struct FlightLogProjectionTests {
    private typealias Flight = CollectionsAggregator.FlightRecord

    private func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func flight(
        _ from: String = "Athens", _ to: String = "London",
        fromPoint: (Double, Double)? = (37.98, 23.73),
        toPoint: (Double, Double)? = (51.50, -0.13),
        fromISO: String = "GR", toISO: String = "GB",
        start: String = "2026-06-01T08:00:00Z", end: String = "2026-06-01T12:00:00Z",
        departureZone: String? = "Europe/Athens", arrivalZone: String? = "Europe/London"
    ) -> Flight {
        var record = Flight(id: UUID(), departureCode: "ATH", arrivalCode: "LHR",
                            departurePlace: from, arrivalPlace: to, departureISO: fromISO, arrivalISO: toISO,
                            date: instant(end), distanceKm: 2400, estimatedHours: 3.5,
                            isInternational: fromISO != toISO, timeZonesCrossed: 2, isOvernight: false,
                            departureWindowStart: instant(start), departureTimeZoneIdentifier: departureZone,
                            arrivalTimeZoneIdentifier: arrivalZone)
        record.departureObservedLatitude = fromPoint?.0
        record.departureObservedLongitude = fromPoint?.1
        record.arrivalObservedLatitude = toPoint?.0
        record.arrivalObservedLongitude = toPoint?.1
        record.departureAirportResolutionRaw = "likely"
        record.arrivalAirportResolutionRaw = "likely"
        record.departureSourceRaw = "liveSLC"
        record.arrivalSourceRaw = "liveSLC"
        record.journeySourceRaws = ["liveSLC"]
        record.observationDateQualityRaw = "observedWindow"
        record.observationNeedsTimeCaution = false
        record.sourceEvidenceComplete = true
        record.logicalIdentityIsAmbiguous = false
        record.departurePlaceGranularityRaw = "locality"
        record.arrivalPlaceGranularityRaw = "metro"
        record.departureStayStart = instant(start)
        return record
    }

    private func snapshot(_ records: [Flight], query: String = "") -> FlightLogProjection.Snapshot {
        FlightLogProjection.make(flights: records, candidates: [], year: nil, search: query)
    }

    @Test("Both interval bounds are checked in both endpoint zones")
    func dateLineYearRemainsUncertain() {
        let first = flight("Auckland", "Honolulu", start: "2025-12-31T23:00:00Z", end: "2026-01-02T10:00:00Z",
                           departureZone: "Pacific/Auckland", arrivalZone: "Pacific/Honolulu")
        let second = flight("Auckland", "Honolulu", start: "2025-12-31T01:00:00Z", end: "2026-01-01T09:00:00Z",
                            departureZone: "Pacific/Auckland", arrivalZone: "Pacific/Honolulu")
        #expect(FlightLogProjection.year(of: first) == nil)
        #expect(FlightLogProjection.year(of: second) == nil)
        #expect(FlightLogProjection.make(flights: [first, second], candidates: [], year: 2026, search: "").records.isEmpty)
        #expect(FlightLogProjection.make(flights: [first, second], candidates: [], year: nil, search: "", onlyUncertainDates: true).records.count == 2)
        #expect(FlightLogProjection.year(of: flight()) == 2026)
    }

    @Test("Unknown zones and photo clock uncertainty never create exact years")
    func sourceAndZoneUncertainty() {
        var photo = flight(start: "2026-01-01T00:05:00Z", end: "2026-01-01T01:00:00Z",
                           departureZone: "Etc/UTC", arrivalZone: "Etc/UTC")
        photo.observationNeedsTimeCaution = true
        photo.journeySourceRaws = ["liveSLC", "photoImport"]
        #expect(FlightLogProjection.year(of: photo) == nil)
        let unstamped = flight(start: "2026-01-01T00:30:00Z", end: "2026-01-01T02:00:00Z",
                               departureZone: nil, arrivalZone: "not/a-zone")
        #expect(FlightLogProjection.year(of: unstamped) == nil)
        var incomplete = flight()
        incomplete.sourceEvidenceComplete = false
        #expect(FlightLogProjection.year(of: incomplete) == 2026)
        incomplete.sourceEvidenceComplete = true
        incomplete.logicalIdentityIsAmbiguous = true
        #expect(FlightLogProjection.year(of: incomplete) == 2026)
        var nearBoundary = flight(start: "2026-01-01T00:05:00Z", end: "2026-01-01T01:00:00Z",
                                  departureZone: "Etc/UTC", arrivalZone: "Etc/UTC")
        nearBoundary.sourceEvidenceComplete = false
        #expect(FlightLogProjection.year(of: nearBoundary) == nil)
        var legacy = photo
        legacy.userDeparture = instant("2026-01-01T00:10:00Z")
        legacy.userArrival = instant("2026-01-01T01:00:00Z")
        #expect(FlightLogProjection.year(of: legacy) == nil)
    }

    @Test("solar fixed offsets retain New Year uncertainty without hiding bounded midyear history")
    func approximateZoneYearMembership() throws {
        var imported = flight(start: "2025-12-31T22:30:00Z", end: "2025-12-31T23:40:00Z",
                              departureZone: "GMT", arrivalZone: "GMT")
        imported.departureSourceRaw = "photoImport"
        imported.arrivalSourceRaw = "photoImport"
        imported.journeySourceRaws = ["photoImport"]
        imported.observationNeedsTimeCaution = true
        for hours in -12...14 {
            let fixed = try #require(TimeZone(secondsFromGMT: hours * 3600))
            imported.departureTimeZoneIdentifier = fixed.identifier
            imported.arrivalTimeZoneIdentifier = fixed.identifier
            #expect(FlightLogProjection.year(of: imported) == nil)
            var july = flight(start: "2026-07-01T08:00:00Z", end: "2026-07-01T12:00:00Z",
                              departureZone: fixed.identifier, arrivalZone: fixed.identifier)
            july.observationNeedsTimeCaution = true
            #expect(FlightLogProjection.year(of: july) == 2026)
        }
        imported.departureTimeZoneIdentifier = "Europe/Paris"
        imported.arrivalTimeZoneIdentifier = "Europe/London"
        #expect(FlightLogProjection.year(of: imported) == nil)
        imported.departureTimeZoneIdentifier = "Etc/UTC"
        imported.arrivalTimeZoneIdentifier = "Etc/UTC"
        #expect(FlightLogProjection.year(of: imported) == 2025)
        imported.departureTimeZoneIdentifier = "UTC"
        imported.arrivalTimeZoneIdentifier = "UTC"
        #expect(FlightLogProjection.year(of: imported) == nil)
        let saved = FlightTimeOverrides.Times(departure: instant("2025-12-31T22:45:00Z"),
                                              arrival: instant("2025-12-31T23:30:00Z"))
        let corrected = imported.applyingUserTimes(saved)
        #expect(corrected.userTimes == saved)
        #expect(FlightLogProjection.year(of: corrected) == nil)
    }

    @Test("Pasted routes retain endpoint and connection search terms")
    func routePunctuationIsSearchable() {
        let record = flight()
        for query in [FlightLogProjection.primaryRoute(record), "Athens ↔ London", "ATH → LHR", "ATH-LHR",
                      "ATH -> LHR", "ATH <-> LHR", "ATH/LHR", "ATH — LHR", "ＡＴＨ → ｌｈｒ"] {
            #expect(snapshot([record], query: query).records.count == 1)
        }
        #expect(snapshot([record], query: "ATH → JFK").records.isEmpty)
        #expect(snapshot([record], query: "Athens → missing").records.isEmpty)
    }

    @Test("Airport aliases and international names use symmetric invariant casing")
    func invariantAirportSearch() {
        var record = flight("İstanbul", "Islamabad")
        record.departureCode = "IST"
        record.arrivalCode = "ISB"
        for query in ["IST", "ist", "IsT", "ISB", "isb", "istanbul", "İstanbul", "İST → isb"] {
            #expect(snapshot([record], query: query).records.count == 1)
        }
    }

    @Test("Distant same-country homonyms remain distinct geographical routes")
    func homonymsDoNotMakeFalseRepeat() {
        var west = flight("Portland", "Boston", fromPoint: (45.5152, -122.6784), toPoint: (42.3601, -71.0589), fromISO: "US", toISO: "US")
        var east = flight("Portland", "Boston", fromPoint: (43.6591, -70.2568), toPoint: (42.3601, -71.0589), fromISO: "US", toISO: "US")
        west.departureAdministrativeArea = "Oregon"
        east.departureAdministrativeArea = "Maine"
        let identities = FlightLogProjection.geographicIdentities(for: [west, east])
        #expect(identities[0].departure != identities[1].departure)
        #expect(snapshot([west, east]).summary.routeCount == 2)
        #expect(snapshot([west, east]).summary.mostRecordedRouteCount == 1)
        east.departureAdministrativeArea = nil
        west.departureAdministrativeArea = nil
        #expect(snapshot([west, east]).summary.routeCount == 2)
    }

    @Test("Country-wide fallback labels do not erase their endpoint geometry")
    func coarseLabelsKeepDistinctPoints() {
        var record = flight("Australia", "Australia", fromPoint: (-31.9523, 115.8613), toPoint: (-33.8688, 151.2093), fromISO: "AU", toISO: "AU")
        record.departurePlaceGranularityRaw = "country"
        record.arrivalPlaceGranularityRaw = "country"
        let identity = FlightLogProjection.geographicIdentities(for: [record])[0]
        #expect(identity.departure != identity.arrival)
        #expect(snapshot([record]).summary.routeCount == 1)
        #expect((FlightLogProjection.estimatedDistanceKm(for: record) ?? 0) > 3200)
    }

    @Test("A real named metro retains nearby repeat and multi-airport grouping")
    func metroAndNearbyRepeatGrouping() {
        var heathrow = flight("London", "Boston", fromPoint: (51.47, -0.4543), toPoint: (42.3656, -71.0096), fromISO: "GB", toISO: "US")
        var gatwick = flight("London", "Boston", fromPoint: (51.1537, -0.1821), toPoint: (42.3656, -71.0096), fromISO: "GB", toISO: "US")
        heathrow.departurePlaceGranularityRaw = "metro"
        gatwick.departurePlaceGranularityRaw = "metro"
        heathrow.departureCode = "LHR"
        gatwick.departureCode = "LGW"
        heathrow.departureAdministrativeArea = "Hillingdon"
        gatwick.departureAdministrativeArea = "West Sussex"
        #expect(snapshot([heathrow, gatwick]).summary.routeCount == 1)
        let near = flight(fromPoint: (37.9801, 23.7299))
        #expect(snapshot([flight(), near]).summary.routeCount == 1)
        let variants = [heathrow, gatwick, heathrow]
        let forward = FlightLogProjection.geographicIdentities(for: variants)
        let reverse = FlightLogProjection.geographicIdentities(for: Array(variants.reversed()))
        #expect(forward == Array(reverse.reversed()))
        #expect(forward[0] == forward[2])
        #expect(snapshot(variants).summary.mostRecordedRouteCount == 3)
    }

    @Test("A chain of nearby observations cannot bridge distant places")
    func completeLinkPreventsGeographicChains() {
        func endpoint(_ longitude: Double) -> FlightGeographicIdentity.Endpoint {
            .init(place: "Country", iso: "QQ", administrativeArea: nil, granularity: "country",
                  latitude: 0, longitude: longitude, observedAirportCode: nil)
        }
        let inputs = [endpoint(0), endpoint(0.08), endpoint(0.16)]
        let identities = FlightGeographicIdentity.resolve(inputs)
        #expect(identities[0] == identities[1])
        #expect(identities[0] != identities[2])
        #expect(identities == Array(FlightGeographicIdentity.resolve(Array(inputs.reversed())).reversed()))
        let duplicate = FlightGeographicIdentity.resolve(inputs + [inputs[0], inputs[1]])
        #expect(Array(duplicate.prefix(3)) == identities)
    }

    @Test("Likely airport guesses cannot supply absent observed geography")
    func missingGeometryHasNoFalseAirportAuthority() {
        var record = flight(fromPoint: nil)
        record.departureLatitude = 37.9364
        record.departureLongitude = 23.9445
        #expect(FlightLogProjection.geographicIdentities(for: [record])[0].departure == nil)
        #expect(snapshot([record]).summary.routeCount == 0)
        #expect(snapshot([record]).summary.routeJourneyCount == 0)
        #expect(snapshot([record]).summary.journeyCount == 1)
        record.departureLatitude = nil
        record.departureLongitude = nil
        record.departureAirportResolutionRaw = "observedNearby"
        #expect(FlightLogProjection.geographicIdentities(for: [record])[0].departure == "airport:ATH")
        #expect(snapshot([record]).summary.routeCount == 1)
        var invalid = flight(fromPoint: (.nan, 181))
        invalid.departureCode = nil
        #expect(FlightLogProjection.geographicIdentities(for: [invalid])[0].departure == nil)
    }

    @Test("Nearby dateline positions match without producing a Greenwich midpoint")
    func nearbyDatelineCoordinatesMatch() {
        let west = FlightGeographicIdentity.Endpoint(place: "Dateline", iso: "QQ", administrativeArea: nil,
                    granularity: "locality", latitude: 0, longitude: 179.98, observedAirportCode: nil)
        let east = FlightGeographicIdentity.Endpoint(place: "Dateline", iso: "QQ", administrativeArea: nil,
                    granularity: "locality", latitude: 0, longitude: -179.98, observedAirportCode: nil)
        let keys = FlightGeographicIdentity.resolve([west, east])
        #expect(keys[0] == keys[1])
    }

    @Test("Full connection order remains part of bidirectional route identity")
    func connectionOrderAndReverseRoutes() {
        let frankfurt = Flight.Stop(AirportRecord(code: "FRA", lat: 50.03, lon: 8.57,
                                                  name: "Frankfurt", city: "Frankfurt", iso: "DE", svc: true))
        let paris = Flight.Stop(AirportRecord(code: "CDG", lat: 49.01, lon: 2.55,
                                              name: "Charles de Gaulle", city: "Paris", iso: "FR", svc: true))
        var forward = flight()
        forward.stops = [frankfurt, paris]
        var reverse = flight("London", "Athens", fromPoint: (51.50, -0.13), toPoint: (37.98, 23.73), fromISO: "GB", toISO: "GR")
        reverse.stops = [paris, frankfurt]
        var different = forward
        different.stops = [paris, frankfurt]
        #expect(snapshot([forward, reverse]).summary.routeCount == 1)
        #expect(snapshot([forward, different]).summary.routeCount == 2)
        #expect(snapshot([forward], query: "ATH → FRA → CDG → LHR").records.count == 1)
        #expect(snapshot([forward], query: "ATH → MUC → LHR").records.isEmpty)
    }

    @Test("Search scope and uncertain years apply equally to the review queue")
    func candidateScopeDoesNotInflateStatistics() {
        let record = flight()
        let candidate = CollectionsAggregator.PossibleFlight(record: record, evidenceRaw: "fastLeg", gapHours: 4)
        let result = FlightLogProjection.make(flights: [], candidates: [candidate], year: 2026, search: "ATH → LHR")
        #expect(result.records.isEmpty)
        #expect(result.candidates.count == 1)
        #expect(result.summary.journeyCount == 0)
        #expect(result.summary.routeCount == 0)
        #expect(result.summary.routeJourneyCount == 0)
    }
}
