import Foundation
import Testing
@testable import TravelLog

/// The Flight Log's year rule, search and the answers it shows before a
/// refreshed log carries them.
@MainActor
struct FlightLogProjectionTests {
    private typealias Flight = CollectionsAggregator.FlightRecord

    private func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func flight(
        _ from: String = "Athens", _ to: String = "London",
        fromISO: String? = "GR", toISO: String? = "GB",
        start: String = "2026-06-01T08:00:00Z", end: String = "2026-06-01T12:00:00Z",
        departureZone: String? = "Europe/Athens", arrivalZone: String? = "Europe/London"
    ) -> Flight {
        var record = Flight(id: UUID(), departureCode: "ATH", arrivalCode: "LHR",
                            departurePlace: from, arrivalPlace: to, departureISO: fromISO, arrivalISO: toISO,
                            date: instant(end), distanceKm: 2400, estimatedHours: 3.5,
                            isInternational: fromISO != toISO, timeZonesCrossed: 2, isOvernight: false,
                            departureWindowStart: instant(start), departureTimeZoneIdentifier: departureZone,
                            arrivalTimeZoneIdentifier: arrivalZone)
        record.presentationToken = record.id.uuidString
        return record
    }

    private func matches(_ records: [Flight], _ query: String) -> [UUID] {
        FlightLogView.searchIndex(records, languageTag: "en").matching(query).map(\.id)
    }

    @Test("A flight belongs to its arrival's civil year in the arrival zone")
    func arrivalYear() {
        let overNewYear = flight("Auckland", "Honolulu", start: "2025-12-31T23:00:00Z", end: "2026-01-02T10:00:00Z",
                                 departureZone: "Pacific/Auckland", arrivalZone: "Pacific/Honolulu")
        #expect(FlightLogProjection.year(of: overNewYear) == 2026)
        let lateEvening = flight(start: "2025-12-31T20:00:00Z", end: "2026-01-01T04:00:00Z",
                                 departureZone: "America/Los_Angeles", arrivalZone: "America/Los_Angeles")
        #expect(FlightLogProjection.year(of: lateEvening) == 2025)
        #expect(FlightLogView.yearSections([overNewYear, lateEvening]).map(\.year) == [2026, 2025])
    }

    @Test("The air-time estimate never outlasts the gap the flight fits in")
    func estimateFitsGap() {
        let roomy = flight(start: "2026-06-01T08:00:00Z", end: "2026-06-01T12:00:00Z")
        #expect(roomy.estimatedAirHours == 3.5 && roomy.flightHours == 3.5)
        let tight = flight(start: "2026-06-01T09:00:00Z", end: "2026-06-01T12:00:00Z")
        #expect(tight.estimatedAirHours == 3 && tight.flightHours == 3)
    }

    @Test("Saved times move the date and year; clearing them restores the original")
    func savedTimesResolveYear() {
        let original = flight(start: "2025-12-30T08:00:00Z", end: "2026-01-02T12:00:00Z",
                              departureZone: "Etc/UTC", arrivalZone: "Etc/UTC")
        let times = FlightTimeOverrides.Times(departure: instant("2025-12-31T08:00:00Z"),
                                              arrival: instant("2025-12-31T12:00:00Z"))
        #expect(FlightLogProjection.year(of: original) == 2026)
        let corrected = original.applyingUserTimes(times)
        #expect(FlightLogProjection.year(of: corrected) == 2025)
        #expect(FlightLogView.yearSections([corrected]).map(\.year) == [2025])
        #expect(FlightLogView.flightDateText(corrected) != FlightLogView.flightDateText(original))
        let cleared = corrected.applyingUserTimes(nil)
        #expect(FlightLogProjection.year(of: cleared) == 2026)
        #expect(FlightLogView.flightDateText(cleared) == FlightLogView.flightDateText(original))
    }

    @Test("Rows under a year leave it out, and ranges read in the single date's order")
    func rowDates() {
        // English with Greek region formats: the day leads in both.
        let locale = Locale(identifier: "en_US@rg=grzzzz")
        let sameDay = flight(start: "2026-10-08T08:00:00Z", end: "2026-10-08T12:00:00Z",
                             departureZone: "Etc/UTC", arrivalZone: "Etc/UTC")
        #expect(FlightLogView.flightDateText(sameDay, inYear: 2026, locale: locale) == "8 Oct")
        #expect(FlightLogView.flightDateText(sameDay, locale: locale) == "8 Oct 2026")
        let overnight = flight(start: "2026-07-01T20:00:00Z", end: "2026-07-02T06:00:00Z",
                               departureZone: "Etc/UTC", arrivalZone: "Etc/UTC")
        #expect(FlightLogView.flightDateText(overnight, inYear: 2026, locale: locale) == "1 to 2 Jul")
        #expect(FlightLogView.flightDateText(overnight, locale: locale) == "1 to 2 Jul 2026")
        // Under the arrival's year a window across New Year keeps both.
        let newYear = flight(start: "2025-12-31T20:00:00Z", end: "2026-01-01T06:00:00Z",
                             departureZone: "Etc/UTC", arrivalZone: "Etc/UTC")
        #expect(FlightLogView.flightDateText(newYear, inYear: 2026, locale: locale) == "31 Dec 2025 to 1 Jan 2026")
    }

    @Test("Rows lead with the destination's flag, then the origin's")
    func flagCodes() {
        #expect(FlightLogView.flagCodes(flight()) == ["GB", "GR"])
        #expect(FlightLogView.flagCodes(flight(fromISO: "gr", toISO: "GR")) == ["GR"])
        #expect(FlightLogView.flagCodes(flight(fromISO: nil)) == ["GB", ""])
        #expect(FlightLogView.flagCodes(flight(fromISO: nil, toISO: nil)) == [])
    }

    @Test("The summary's second line leaves out what says nothing")
    func summaryLine() {
        var stats = CollectionsAggregator.FlightStats()
        stats.totalFlights = 2
        stats.totalKm = 40_075
        stats.longestKm = 10_000
        stats.longestRouteLabel = "AMS → SIN"
        let once = 1.0.formatted(.number.precision(.fractionLength(1)))
        #expect(FlightLogView.summaryLine(stats) == "\(once)× around the Earth · longest AMS → SIN")
        stats.totalKm = 10_000
        #expect(FlightLogView.summaryLine(stats) == "Longest AMS → SIN")
        stats.totalFlights = 1
        #expect(FlightLogView.summaryLine(stats) == nil)
        #expect(FlightLogView.summaryHours(193.4) == "193h")
        #expect(FlightLogView.summaryHours(7.5) == FlightLogView.formatHours(7.5))
        // The figure's number and unit are the distance as written elsewhere.
        let parts = UnitsFormatter.distanceParts(kilometers: 127_139)
        let distance = UnitsFormatter.formatDistance(kilometers: 127_139)
        #expect(!parts.value.isEmpty && !parts.unit.isEmpty)
        #expect(distance.hasPrefix(parts.value) && distance.hasSuffix(parts.unit))
    }

    @Test("Search finds places, codes, airport cities and countries, folding case and accents")
    func search() {
        let athens = flight()
        var hanoi = flight("Hanoi", "Đà Nẵng", fromISO: "VN", toISO: "VN")
        hanoi.departureCode = "HAN"
        hanoi.arrivalCode = "DAD"
        let records = [athens, hanoi]
        for query in ["athens", "LHR", "lhr", "London", "Greece", "ATH LHR"] {
            #expect(matches(records, query) == [athens.id], "\(query)")
        }
        for query in ["da nang", "ĐÀ NẴNG", "Vietnam", "dad"] {
            #expect(matches(records, query) == [hanoi.id], "\(query)")
        }
        #expect(matches(records, "").count == 2)
    }

    @Test("An answer shows at once and goes only when a snapshot carries it")
    func overlayReconciles() {
        let shown = flight()
        let id = shown.presentationID
        var candidateRecord = flight("Velmora", "Saltreach", start: "2026-07-01T08:00:00Z",
                                     end: "2026-07-01T10:00:00Z")
        candidateRecord.presentationToken = "candidate"
        let candidate = CollectionsAggregator.PossibleFlight(record: candidateRecord, evidenceRaw: "fastLeg",
                                                             gapHours: 2)
        let before = CollectionsAggregator.Collections(flights: [shown], possibleFlights: [candidate])
        var overlay = FlightLogOverlay()
        overlay.resolved.insert(candidate.presentationID)
        overlay.confirmed[candidate.presentationID] = candidateRecord
        let times = FlightTimeOverrides.Times(departure: instant("2026-06-01T09:00:00Z"),
                                              arrival: instant("2026-06-01T11:30:00Z"))
        overlay.times[id] = .some(times)

        #expect(overlay.candidates(before.possibleFlights).isEmpty)
        #expect(overlay.flights(before.flights).map(\.id) == [candidateRecord, shown].map(\.id))
        #expect(overlay.flights(before.flights).last?.userTimes == times)

        // A refresh that started before the answers still shows them.
        overlay.reconcile(with: before)
        #expect(overlay.flights(before.flights).count == 2)
        #expect(overlay.candidates(before.possibleFlights).isEmpty)

        // The refreshed log carries both: nothing is left to overlay.
        let after = CollectionsAggregator.Collections(
            flights: [candidateRecord, shown.applyingUserTimes(times)], possibleFlights: [])
        overlay.reconcile(with: after)
        #expect(overlay.resolved.isEmpty && overlay.confirmed.isEmpty && overlay.times.isEmpty)
    }

    @Test("a refused edit falls back to the last saved value, never to an earlier unsaved one")
    func refusedEditsFallBackToSaved() {
        let shown = flight()
        let id = shown.presentationID
        let first = FlightTimeOverrides.Times(departure: instant("2026-06-01T09:00:00Z"),
                                              arrival: instant("2026-06-01T11:00:00Z"))
        let second = FlightTimeOverrides.Times(departure: instant("2026-06-01T09:30:00Z"),
                                               arrival: instant("2026-06-01T11:30:00Z"))
        // Two queued edits, both refused: the log's own value.
        var overlay = FlightLogOverlay()
        let a = overlay.beginTimes(first, for: id)
        let b = overlay.beginTimes(second, for: id)
        overlay.endTimes(a, value: first, for: id, committed: false)
        #expect(overlay.flights([shown]).first?.userTimes == second)
        overlay.endTimes(b, value: second, for: id, committed: false)
        #expect(overlay.flights([shown]).first?.userTimes == nil)
        let c = overlay.beginStops(["FRA"], for: id)
        let d = overlay.beginStops(["MUC"], for: id)
        overlay.endStops(c, value: ["FRA"], for: id, committed: false)
        overlay.endStops(d, value: ["MUC"], for: id, committed: false)
        #expect(overlay.stops[id] == nil)

        // The first saved, the second refused: the first.
        var saved = FlightLogOverlay()
        let e = saved.beginTimes(first, for: id)
        let f = saved.beginTimes(second, for: id)
        saved.endTimes(e, value: first, for: id, committed: true)
        saved.endTimes(f, value: second, for: id, committed: false)
        #expect(saved.flights([shown]).first?.userTimes == first)
    }

    @Test("rows, totals and Wrapped share one route distance")
    func oneRouteDistance() {
        var direct = flight()
        direct.departureLatitude = 37.94
        direct.departureLongitude = 23.94
        direct.arrivalLatitude = 51.47
        direct.arrivalLongitude = -0.45
        let routed = direct.applyingStops(["FRA"]) { AirportDetector.shared.airport(code: $0) }
        #expect(routed.flownKm > direct.flownKm)
        #expect(direct.flownKm == direct.distanceKm)
        let stats = CollectionsAggregator.flightStats(from: [direct, routed])
        #expect(abs(stats.totalKm - (direct.flownKm + routed.flownKm)) < 0.001)
        // Without the departure's point a stop invents no hop.
        var partial = flight()
        partial.arrivalLatitude = 51.47
        partial.arrivalLongitude = -0.45
        let partialRouted = partial.applyingStops(["FRA"]) { AirportDetector.shared.airport(code: $0) }
        #expect(partialRouted.flownKm == partial.distanceKm)
    }
}
