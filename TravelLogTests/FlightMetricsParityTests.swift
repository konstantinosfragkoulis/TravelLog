import Foundation
import SwiftData
import Testing
@testable import TravelLog

/// The same recorded journey is counted once throughout Stats, including
/// after the user supplies connecting airports. Date uncertainty changes
/// year membership, never the existence of the historical journey.
@MainActor
struct FlightMetricsParityTests {
    private var utc: Calendar { TravelDays.labelCalendar }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func journey(
        in context: ModelContext, departure: Date, arrival: Date,
        retainedMembers: Bool = true
    ) -> Stay {
        func endpoint(_ time: Date, latitude: Double, longitude: Double,
                      category: StayCategory, place: String, iso: String) -> Stay {
            let ping = LocationPing(
                timestamp: time, latitude: latitude, longitude: longitude,
                horizontalAccuracy: 10, h3IndexRes6: "", source: .liveSLC)
            if retainedMembers { context.insert(ping) }
            let stay = Stay(
                startTime: time, endTime: time.addingTimeInterval(2 * 3600),
                centroidLatitude: latitude, centroidLongitude: longitude,
                h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 100,
                pingIDs: retainedMembers ? [ping.id] : [], timeZoneIdentifier: "UTC")
            stay.category = category
            stay.locality = place
            stay.isoCountryCode = iso
            context.insert(stay)
            return stay
        }
        _ = endpoint(departure, latitude: 37.98, longitude: 23.73,
                     category: .home, place: "Athens", iso: "GR")
        let destination = endpoint(arrival, latitude: 51.50, longitude: -0.12,
                                   category: .destination, place: "London", iso: "GB")
        destination.transitMode = .flight
        return destination
    }

    @Test("a supplied connection does not multiply any recorded-journey counter")
    func connectedJourneyParity() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let destination = journey(in: context, departure: date(2025, 7, 1, 8),
                                  arrival: date(2025, 7, 1, 16))
        try context.save()
        FlightStops.set(["FRA"], for: destination.id)
        defer { FlightStops.clear(destination.id) }

        let aggregate = try StatsAggregator.compute(container: container, calendar: utc)
        let lifetime = try StatsAggregator.passportSummary(container: container, calendar: utc)
        let year = try StatsAggregator.yearSummary(container: container, year: 2025, calendar: utc)
        let log = FlightLogProjection.make(
            flights: aggregate.collections.flights, candidates: [], year: nil, search: "")
        let overview = StatsOverview(aggregate, now: .now, calendar: utc)
        #expect(aggregate.computeDegraded == nil)
        #expect(aggregate.collections.flights.count == 1)
        #expect(aggregate.collections.flights.first?.stops?.map(\.code) == ["FRA"])
        #expect(aggregate.collections.flightStats.totalFlights == 1)
        #expect(aggregate.flightCount == 1)
        #expect(aggregate.passportData.flights == 1)
        #expect(overview.collections.flightCount == 1)
        #expect(lifetime.flights == 1)
        #expect(year.flights == 1)
        #expect(log.summary.journeyCount == 1)
        #expect(abs(aggregate.collections.flightStats.totalKm - log.summary.estimatedKm) < 0.01)
    }

    @Test("uncertain observation years remain lifetime journeys without entering either year")
    func uncertainYearParity() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = journey(in: context, departure: date(2024, 12, 31, 20),
                    arrival: date(2025, 1, 1, 8))
        try context.save()
        let aggregate = try StatsAggregator.compute(container: container, calendar: utc)
        let lifetime = try StatsAggregator.passportSummary(container: container, calendar: utc)
        #expect(aggregate.collections.flights.count == 1)
        #expect(lifetime.flights == 1)
        #expect(aggregate.passportData.flights == 1)
        let record = try #require(aggregate.collections.flights.first)
        #expect(FlightLogProjection.year(of: record) == nil)
        #expect(try StatsAggregator.yearSummary(container: container, year: 2024, calendar: utc).flights == 0)
        #expect(try StatsAggregator.yearSummary(container: container, year: 2025, calendar: utc).flights == 0)
    }

    @Test("missing member evidence keeps clock caution without discarding a bounded July year")
    func missingEvidenceYearParity() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = journey(in: context, departure: date(2025, 7, 1, 8),
                    arrival: date(2025, 7, 1, 16), retainedMembers: false)
        try context.save()
        let aggregate = try StatsAggregator.compute(container: container, calendar: utc)
        #expect(aggregate.collections.flights.count == 1)
        let record = try #require(aggregate.collections.flights.first)
        #expect(record.sourceEvidenceComplete == false)
        // This flag describes photo-like acquisition evidence. Missing live
        // members do not invent such evidence; year projection separately
        // widens clock caution when source completeness is false.
        #expect(record.observationNeedsTimeCaution == false)
        #expect(FlightLogProjection.year(of: record) == 2025)
        #expect(try StatsAggregator.passportSummary(container: container, calendar: utc).flights == 1)
        #expect(try StatsAggregator.yearSummary(container: container, year: 2025, calendar: utc).flights == 1)
    }

    @Test("new Wrapped flight distance matches the same year-scoped Log estimate")
    func wrappedDistanceParity() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        _ = journey(in: context, departure: date(2025, 7, 1, 8),
                    arrival: date(2025, 7, 1, 16))
        try context.save()
        let aggregate = try StatsAggregator.compute(container: container, calendar: utc)
        let log = FlightLogProjection.make(
            flights: aggregate.collections.flights, candidates: [], year: 2025, search: "")
        #expect(log.summary.journeyCount == 1)
        let generator = YearWrappedGenerator(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let generated = await gate.runReturning(touching: [.yearWrapped]) {
            await generator.forceRegenerate(forYear: 2025)
        }
        #expect(generated)
        let recap = try #require(try ModelContext(container).fetch(FetchDescriptor<YearWrapped>()).first)
        let blob = try #require(recap.statsData)
        let stats = try #require(WrappedStats.decoded(from: blob))
        #expect(abs(stats.flightKm - log.summary.estimatedKm) < 0.01)
    }

    @Test("a confirmed terminal flight survives an unfinished arrival-category rebuild in every metric")
    func terminalFlightSurvivesArrivalReclassification() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let destination = journey(in: context, departure: date(2025, 7, 1, 8),
                                  arrival: date(2025, 7, 1, 16))
        try context.save()
        FlightStops.set(["FRA"], for: destination.id)
        defer { FlightStops.clear(destination.id) }

        let before = try StatsAggregator.compute(container: container, calendar: utc)
        let priorRecord = try #require(before.collections.flights.first)
        let expectedKm = try #require(FlightLogProjection.estimatedDistanceKm(for: priorRecord))
        #expect(expectedKm > 0)
        #expect(before.flightCount == 1)
        #expect(before.passportData.flights == 1)
        #expect(try StatsAggregator.passportSummary(container: container, calendar: utc).flights == 1)
        #expect(try StatsAggregator.yearSummary(container: container, year: 2025, calendar: utc).flights == 1)

        // Rebuild reset commits category changes separately from later
        // classification. A failed/cancelled later unit leaves this state.
        // Flight confirmation is a terminal transit value, not a category
        // override, so resetting the category must not erase its metric.
        destination.category = .unclassified
        try context.save()
        #expect(destination.transitFromPreviousRaw == TransitMode.flight.rawValue)

        let after = try StatsAggregator.compute(container: container, calendar: utc)
        let lifetime = try StatsAggregator.passportSummary(container: container, calendar: utc)
        let year = try StatsAggregator.yearSummary(container: container, year: 2025, calendar: utc)
        let log = FlightLogProjection.make(
            flights: after.collections.flights, candidates: after.collections.possibleFlights,
            year: 2025, search: "")
        #expect(after.computeDegraded == nil)
        #expect(after.collections.flights.count == 1)
        #expect(after.collections.flightStats.totalFlights == 1)
        #expect(after.flightCount == 1)
        #expect(after.passportData.flights == 1)
        #expect(lifetime.flights == 1)
        #expect(year.flights == 1)
        #expect(log.summary.journeyCount == 1)
        #expect(abs(after.collections.flightStats.totalKm - expectedKm) < 0.01)
        #expect(abs(log.summary.estimatedKm - expectedKm) < 0.01)
        #expect(after.collections.possibleFlights.isEmpty)
        #expect(after.collections.places.isEmpty)

        // A newly generated Wrapped is a durable snapshot. Omitting the
        // still-confirmed flight here otherwise survives later successful
        // classification because existing recaps are not regenerated.
        let generator = YearWrappedGenerator(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let generated = await gate.runReturning(touching: [.yearWrapped]) {
            await generator.forceRegenerate(forYear: 2025)
        }
        #expect(generated)
        let recap = try #require(try ModelContext(container).fetch(FetchDescriptor<YearWrapped>()).first)
        let blob = try #require(recap.statsData)
        let stats = try #require(WrappedStats.decoded(from: blob))
        #expect(abs(stats.flightKm - expectedKm) < 0.01)
    }


    @Test("unclassified flight evidence never creates airport or place visits", arguments: [TransitMode.unknown, .flight])
    func backlogFlightEvidenceKeepsCollectionAdmission(_ mode: TransitMode) throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let destination = journey(in: context, departure: date(2025, 7, 1, 8),
                                  arrival: date(2025, 7, 1, 16))
        destination.category = .unclassified
        destination.transitMode = mode
        destination.isAirport = true
        destination.centroidLatitude = 51.4706
        destination.centroidLongitude = -0.461941
        let pingID = try #require(destination.pingIDs.first)
        let ping = try #require(context.fetch(FetchDescriptor<LocationPing>()).first { $0.id == pingID })
        ping.latitude = destination.centroidLatitude
        ping.longitude = destination.centroidLongitude
        try context.save()
        let result = try StatsAggregator.compute(container: container, calendar: utc)
        #expect(result.computeDegraded == nil)
        #expect(result.collections.flights.count == (mode == .flight ? 1 : 0))
        #expect(result.collections.possibleFlights.isEmpty)
        #expect(result.collections.airports.isEmpty)
        #expect(result.collections.places.isEmpty)
    }

}
