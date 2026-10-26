import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct TravelDaysTests {
    private var utc: Calendar { TravelDays.labelCalendar }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @discardableResult
    private func trip(
        _ context: ModelContext, start: Date, end: Date?,
        firstZone: String? = "UTC", lastZone: String? = "UTC"
    ) -> Trip {
        let trip = Trip(startDate: start)
        trip.endDate = end
        trip.isComplete = end != nil
        context.insert(trip)
        let lastTime = max(start, end ?? start)
        for (time, zone) in [(start, firstZone), (lastTime, lastZone)] {
            let stay = Stay(startTime: time, endTime: time.addingTimeInterval(60),
                            centroidLatitude: 0, centroidLongitude: 0,
                            h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 100,
                            pingIDs: [], timeZoneIdentifier: zone)
            stay.category = .destination
            context.insert(stay)
            stay.trip = trip
        }
        return trip
    }

    @Test("Passport, Stats, Siri and Wrapped union overlaps and include ongoing spans, while average uses completed durations")
    func consumersAgreeWithoutChangingMean() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        trip(context, start: date(2025, 6, 1), end: date(2025, 6, 4))
        trip(context, start: date(2025, 6, 3), end: date(2025, 6, 6))
        trip(context, start: date(2025, 6, 8), end: nil)
        trip(context, start: date(2025, 6, 12), end: nil) // future, even after end clamping
        try context.save()
        let now = date(2025, 6, 11)
        let projected = try StatsAggregator.compute(container: container, now: now)
        let full = try StatsAggregator.compute(container: container, now: now, usingProjection: false)
        let passport = try StatsAggregator.passportSummary(container: container, now: now, calendar: utc)
        let siri = try StatsAggregator.yearSummary(container: container, year: 2025, calendar: utc, now: now)
        let wrapped = try TravelDays.count(inYear: 2025, container: container, now: now)
        #expect(projected.travelDaysTotal == 10) // June 1–6 plus June 8–11, including the gaps between stays
        #expect(projected.passportData.daysAbroad == 10)
        #expect(projected.passportData.averageTripDays == 4)
        #expect(projected.passportData.trips == 2)
        #expect(projected.passportData == full.passportData)
        #expect(projected.yearStats == full.yearStats)
        #expect(passport.daysAbroad == 10)
        #expect(siri.daysAbroad == 10)
        #expect(wrapped == 10)
        #expect(siri.trips == 2)
    }

    @Test("west-of-UTC labels stay in the correct civil year and month")
    func negativeZoneDoesNotRebucketLabelKeys() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let journey = trip(context, start: date(2025, 1, 1, hour: 6), end: date(2025, 1, 2, hour: 7),
                           firstZone: "America/Los_Angeles", lastZone: "America/Los_Angeles")
        var west = Calendar(identifier: .gregorian)
        west.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = date(2025, 1, 5)
        let labels = StatsAggregator.travelDaySet(trips: [journey], now: now, calendar: west)
        #expect(labels == Set([date(2024, 12, 31, hour: 0), date(2025, 1, 1, hour: 0)]))
        let ledger = StatsAggregator.yearStats(days: labels, completedTrips: [], calendar: west)
        #expect(ledger.map(\.year) == [2024, 2025])
        #expect(ledger.map(\.days) == [1, 1])
        #expect(StatsAggregator.favoriteMonth(days: labels, calendar: west)?.month == 1)
        #expect(StatsAggregator.travelDays(trips: [journey], now: now, calendar: west).thisYear == 1)
    }

    @Test("ledger and Siri assign New Year trips by the first boundary label", arguments: [false, true])
    func tripStartLabelYear(east: Bool) throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = east ? date(2024, 12, 31, hour: 23) : date(2025, 1, 1, hour: 6)
        let zone = east ? "Pacific/Kiritimati" : "America/Los_Angeles"
        let journey = trip(context, start: start, end: start.addingTimeInterval(60),
                           firstZone: zone, lastZone: zone)
        journey.countryCodes = "GR"
        try context.save()
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = utc.timeZone
        let year = east ? 2025 : 2024
        let now = date(2025, 1, 5)
        let labels = StatsAggregator.travelDaySet(trips: [journey], now: now, calendar: buddhist)
        let ledger = StatsAggregator.yearStats(days: labels, completedTrips: [journey], calendar: buddhist)
        #expect(ledger == [.init(year: year, trips: 1, days: 1, countries: 1)])
        let summary = try StatsAggregator.yearSummary(container: container, year: year, calendar: buddhist, now: now)
        #expect(summary.trips == 1)
        #expect(summary.daysAbroad == 1)
        #expect(summary.countries == ["GR"])
        let other = try StatsAggregator.yearSummary(container: container, year: east ? 2024 : 2025,
                                                calendar: buddhist, now: now)
        #expect(other.trips == 0)
    }

    @Test("date-line boundary zones define the inclusive labels, with a minimum of one on a reversed local span")
    func dateLineBoundaries() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let east = trip(context, start: date(2025, 1, 1, hour: 10), end: date(2025, 1, 1, hour: 12),
                        firstZone: "Pacific/Pago_Pago", lastZone: "Pacific/Kiritimati")
        let labels = TravelDays.labels(trips: [east], now: date(2025, 1, 5))
        #expect(labels == Set([date(2024, 12, 31, hour: 0), date(2025, 1, 1, hour: 0), date(2025, 1, 2, hour: 0)]))
        let west = trip(context, start: date(2025, 1, 1, hour: 10), end: date(2025, 1, 1, hour: 12),
                        firstZone: "Pacific/Kiritimati", lastZone: "Pacific/Pago_Pago")
        #expect(TravelDays.labels(trips: [west], now: date(2025, 1, 5)) == Set([date(2025, 1, 2, hour: 0)]))
    }

    @Test("year counts include carry-in and ongoing dates without changing start-year trip counts")
    func carryInAndOngoingYearCounts() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        trip(context, start: date(2024, 12, 30), end: date(2025, 1, 3))
        trip(context, start: date(2025, 1, 2), end: nil)
        try context.save()
        let now = date(2025, 1, 5)
        let summary = try StatsAggregator.yearSummary(container: container, year: 2025, calendar: utc, now: now)
        #expect(summary.daysAbroad == 5)
        #expect(summary.trips == 0)
        #expect(summary.countries.isEmpty)
        let generator = YearWrappedGenerator(modelContainer: container)
        let trips = try context.fetch(FetchDescriptor<Trip>())
        #expect(generator.computeDaysAbroad(trips: trips, year: 2025, now: now) == 5)
    }

    @Test("legacy zones use the injected fallback and pathological spans remain bounded")
    func legacyFallbackAndBoundedWalk() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let legacy = trip(context, start: date(2025, 5, 1, hour: 23), end: date(2025, 5, 2, hour: 1), firstZone: nil, lastZone: nil)
        let now = date(2025, 6, 1)
        #expect(TravelDays.labels(trips: [legacy], now: now, fallbackZone: TimeZone(secondsFromGMT: 0)!).count == 2)
        #expect(TravelDays.labels(trips: [legacy], now: now, fallbackZone: TimeZone(secondsFromGMT: 3 * 3600)!).count == 1)
        let ancient = trip(context, start: date(1900, 1, 1), end: date(2025, 1, 1))
        #expect(TravelDays.labels(trips: [ancient], now: now).count == 3_651)
        let malformed = trip(context, start: date(2025, 5, 5), end: date(2025, 5, 1))
        #expect(TravelDays.labels(trips: [malformed], now: now) == Set([date(2025, 5, 5, hour: 0)]))
    }

    @Test("spans that are not trips get the trip rules: boundary zones, the one-day minimum, the clip at now and the bounded walk")
    func spanLabelsFollowTripRules() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let now = date(2025, 6, 1)
        let zone = TimeZone(secondsFromGMT: 0)!
        func labels(_ start: Date, _ end: Date, _ first: String? = "UTC", _ last: String? = "UTC") -> Set<Date> {
            TravelDays.labels(
                forSpans: [(start: start, end: end, firstZone: first, lastZone: last)],
                now: now, fallbackZone: zone, checkCancellation: {})
        }
        // The same boundaries as a trip give the same labels.
        let west = trip(context, start: date(2025, 1, 1, hour: 6), end: date(2025, 1, 2, hour: 7),
                        firstZone: "America/Los_Angeles", lastZone: "America/Los_Angeles")
        let westLabels = labels(date(2025, 1, 1, hour: 6), date(2025, 1, 2, hour: 7),
                                "America/Los_Angeles", "America/Los_Angeles")
        #expect(westLabels == TravelDays.labels(trips: [west], now: now, fallbackZone: zone))
        #expect(westLabels == Set([date(2024, 12, 31, hour: 0), date(2025, 1, 1, hour: 0)]))
        // A reversed span keeps one day.
        #expect(labels(date(2025, 5, 5), date(2025, 5, 1)) == Set([date(2025, 5, 5, hour: 0)]))
        // A span that starts after now counts nothing; an end after now stops at now.
        #expect(labels(date(2025, 6, 2), date(2025, 6, 3)).isEmpty)
        #expect(labels(date(2025, 5, 30), date(2025, 6, 9))
                == Set([date(2025, 5, 30, hour: 0), date(2025, 5, 31, hour: 0), date(2025, 6, 1, hour: 0)]))
        // A missing zone falls back; a pathological span stays bounded.
        #expect(labels(date(2025, 5, 1, hour: 23), date(2025, 5, 2, hour: 1), nil, nil).count == 2)
        #expect(labels(date(1900, 1, 1), date(2025, 1, 1)).count == 3_651)
        // Several spans union.
        #expect(TravelDays.labels(
            forSpans: [
                (start: date(2025, 3, 1), end: date(2025, 3, 2), firstZone: "UTC", lastZone: "UTC"),
                (start: date(2025, 3, 2), end: date(2025, 3, 3), firstZone: "UTC", lastZone: "UTC"),
            ],
            now: now, fallbackZone: zone, checkCancellation: {}).count == 3)
    }

    @Test("file-backed boundary projections match full rows, including zones, ties, legacy rows and UUID twins")
    func projectedBoundaryParity() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let west = trip(context, start: date(2025, 1, 1, hour: 6), end: date(2025, 1, 2, hour: 7),
                        firstZone: "America/Los_Angeles", lastZone: "America/Los_Angeles")
        let twin = trip(context, start: date(2025, 6, 1), end: date(2025, 6, 2),
                        firstZone: "Pacific/Kiritimati", lastZone: "Pacific/Pago_Pago")
        twin.id = west.id // physical parents must not share their boundary zones
        // Same logical id and start instant, but different first-label years.
        let newYearEast = trip(context, start: date(2025, 1, 1, hour: 6), end: date(2025, 1, 1, hour: 7),
                               firstZone: "Pacific/Kiritimati", lastZone: "Pacific/Kiritimati")
        let newYearWest = trip(context, start: newYearEast.startDate, end: newYearEast.endDate,
                               firstZone: "America/Los_Angeles", lastZone: "America/Los_Angeles")
        newYearWest.id = newYearEast.id
        newYearEast.countryCodes = "KI"
        newYearWest.countryCodes = "US"
        trip(context, start: date(2024, 12, 30), end: date(2025, 1, 3))
        trip(context, start: date(2025, 6, 3), end: nil, firstZone: nil, lastZone: nil)
        trip(context, start: date(2025, 8, 1), end: nil)
        let legacy = Trip(startDate: date(2025, 4, 1)) // no stays: injected fallback
        legacy.endDate = date(2025, 4, 2)
        legacy.isComplete = true
        context.insert(legacy)
        // Same boundary times, different zones: smallest stable UUID wins.
        let stay = try #require(west.stays?.first)
        let tied = Stay(startTime: stay.startTime, endTime: stay.endTime,
                        centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "",
                        pingCount: 1, distanceFromHomeKm: 100, pingIDs: [],
                        timeZoneIdentifier: "Pacific/Kiritimati")
        tied.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        context.insert(tied)
        tied.trip = west
        for row in try context.fetch(FetchDescriptor<Stay>()) {
            row.weatherData = Data(repeating: 7, count: 65_536)
            row.pingIDsString = String(repeating: "payload,", count: 500)
        }
        try context.save()
        let now = date(2025, 6, 5)
        let zone = TimeZone(secondsFromGMT: 0)!
        let fullRows = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        let full = TravelDays.labels(trips: fullRows, now: now, fallbackZone: zone)
        let projected = try TravelDays.labels(container: container, now: now, fallbackZone: zone)
        #expect(projected == full)
        #expect(try TravelDays.labels(trips: fullRows, now: now, fallbackZone: zone,
                                       checkCancellation: Task.checkCancellation) == full)
        #expect(try TravelDays.labels(container: container, now: now, fallbackZone: zone,
                                       checkCancellation: Task.checkCancellation) == projected)
        #expect(TravelDays.count(projected, inYear: 2025) == TravelDays.count(full, inYear: 2025))
        #expect(!projected.contains(date(2025, 8, 1, hour: 0)))
        let passport = try StatsAggregator.passportSummary(container: container, now: now, calendar: utc)
        #expect(passport.daysAbroad == full.count)
        let siri = try StatsAggregator.yearSummary(container: container, year: 2025, calendar: utc, now: now)
        #expect(siri.daysAbroad == TravelDays.count(full, inYear: 2025))
        #expect(siri.countries.contains("KI"))
        #expect(!siri.countries.contains("US"))
        let previousYear = try StatsAggregator.yearSummary(container: container, year: 2024, calendar: utc, now: now)
        #expect(previousYear.countries.contains("US"))
        #expect(!previousYear.countries.contains("KI"))
        let ledger = StatsAggregator.yearStats(days: full, completedTrips: fullRows.filter(\.isComplete), calendar: utc)
        #expect(siri.trips == ledger.first { $0.year == 2025 }?.trips)
    }

    @Test("travel-day cancellation interrupts the trip input walk")
    func tripInputCancellation() {
        let rows = (0..<128).map { _ in Trip(startDate: date(2025, 1, 1)) }
        var calls = 0
        #expect(throws: CancellationError.self) {
            try TravelDays.labels(trips: rows, now: date(2025, 1, 2)) {
                calls += 1
                if calls == 32 { throw CancellationError() }
            }
        }
        #expect(calls == 32)
    }

    @Test("travel-day and Siri cancellation interrupts boundary stays", arguments: ["materialized", "projected", "yearSummary"])
    func boundaryStayCancellation(lane: String) throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let journey = trip(context, start: date(2025, 1, 1), end: date(2025, 1, 2))
        for _ in 0..<128 {
            let stay = Stay(startTime: date(2025, 1, 1), endTime: date(2025, 1, 2),
                            centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "",
                            pingCount: 1, distanceFromHomeKm: 100, pingIDs: [])
            context.insert(stay)
            stay.trip = journey
        }
        try context.save()
        var calls = 0
        func checkCancellation() throws {
            calls += 1
            if calls == 32 { throw CancellationError() }
        }
        #expect(throws: CancellationError.self) {
            switch lane {
            case "projected":
                _ = try TravelDays.labels(container: container, now: date(2025, 1, 3),
                                          checkCancellation: checkCancellation)
            case "yearSummary":
                _ = try StatsAggregator.yearSummary(container: container, year: 2025, calendar: utc,
                                                    now: date(2025, 1, 3), checkCancellation: checkCancellation)
            default:
                _ = try TravelDays.labels(trips: [journey], now: date(2025, 1, 3),
                                          checkCancellation: checkCancellation)
            }
        }
        #expect(calls == 32)
    }

    @Test("Trip duration and the day counts read the same boundary zones when boundary instants tie in different zones")
    func tiedBoundaryZonesAgreeWithDuration() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let east = "Pacific/Kiritimati", west = "Pacific/Pago_Pago"
        // Jan 2 in Kiritimati, Dec 31 in Pago Pago; the end is Jan 4 and Jan 2.
        let start = date(2025, 1, 1, hour: 10).addingTimeInterval(1_800)
        let end = date(2025, 1, 3, hour: 10).addingTimeInterval(1_800)
        let journey = Trip(startDate: start)
        journey.endDate = end
        journey.isComplete = true
        context.insert(journey)
        func stay(_ from: Date, _ to: Date, _ zone: String) -> Stay {
            let row = Stay(startTime: from, endTime: to, centroidLatitude: 0, centroidLongitude: 0,
                           h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 100, pingIDs: [],
                           timeZoneIdentifier: zone)
            row.category = .destination
            context.insert(row)
            row.trip = journey
            return row
        }
        let openings = [east, west].map { stay(start, start.addingTimeInterval(3_600), $0) }
        let closings = [east, west].map { stay(end.addingTimeInterval(-3_600), end, $0) }
        let now = date(2025, 2, 1)
        let zone = TimeZone(secondsFromGMT: 0)!
        let expected = [east + east: 3, east + west: 1, west + east: 5, west + west: 3]
        // Each zone takes the smaller id in turn at each end, whatever order
        // the relationship lists the tied stays in.
        for firstZone in [east, west] {
            for lastZone in [east, west] {
                for row in openings {
                    row.id = UUID(uuidString: row.timeZoneIdentifier == firstZone
                                  ? "00000000-0000-0000-0000-000000000001" : "FFFFFFFF-0000-0000-0000-000000000001")!
                }
                for row in closings {
                    row.id = UUID(uuidString: row.timeZoneIdentifier == lastZone
                                  ? "00000000-0000-0000-0000-000000000002" : "FFFFFFFF-0000-0000-0000-000000000002")!
                }
                try context.save()
                let duration = try #require(journey.durationDays)
                #expect(duration == expected[firstZone + lastZone], "\(firstZone) to \(lastZone)")
                let full = TravelDays.labels(trips: [journey], now: now, fallbackZone: zone)
                #expect(full.count == duration, "\(firstZone) to \(lastZone)")
                #expect(try TravelDays.labels(container: container, now: now, fallbackZone: zone) == full)
            }
        }
    }

    // MARK: - Parity with the per-consumer model walks

    /// `boundaryStays` as it was before it kept the leaders' keys as values.
    private func referenceBoundaryStays(of stays: [Stay]) -> (first: Stay?, last: Stay?) {
        var first: Stay?
        var last: Stay?
        for stay in stays {
            if first.map({ TravelDays.startsFirst(stay.startTime, stay.id, before: $0.startTime, $0.id) }) ?? true {
                first = stay
            }
            if last.map({ TravelDays.endsLast(stay.endTime, stay.id, after: $0.endTime, $0.id) }) ?? true {
                last = stay
            }
        }
        return (first, last)
    }

    /// The span each consumer used to build from its own `Trip.stays` walk.
    private func referenceSpan(of trip: Trip) -> TravelDays.Span {
        let boundary = referenceBoundaryStays(of: trip.stays ?? [])
        return TravelDays.Span(start: trip.startDate, end: trip.endDate,
                               firstZone: boundary.first?.timeZoneIdentifier,
                               lastZone: boundary.last?.timeZoneIdentifier)
    }

    @Test("boundary stays pick the reference rows on tied instants, UUID twins and empty input, in any order")
    func boundaryStaysMatchReference() {
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
        func stay(_ startHour: Int, _ endHour: Int, _ id: UUID, _ zone: String) -> Stay {
            let row = Stay(startTime: date(2025, 3, 1, hour: startHour), endTime: date(2025, 3, 1, hour: endHour),
                           centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "", pingCount: 1,
                           distanceFromHomeKm: 100, pingIDs: [], timeZoneIdentifier: zone)
            row.id = id
            return row
        }
        let rows = [
            stay(1, 5, high, "Asia/Tokyo"),        // ties the earliest start, larger id
            stay(1, 3, low, "Europe/Athens"),      // the earliest start, smaller id
            stay(1, 3, low, "Europe/Paris"),       // its UUID twin: the first met keeps it
            stay(2, 9, high, "America/New_York"),  // ties the latest end, larger id
            stay(4, 9, low, "Australia/Sydney"),   // the latest end, smaller id
            stay(6, 9, low, "UTC"),                // its UUID twin
        ]
        let empty = TravelDays.boundaryStays(of: [])
        #expect(empty.first == nil)
        #expect(empty.last == nil)
        var orders: [[Stay]] = []
        for shift in rows.indices {
            let rotated = Array(rows[shift...] + rows[..<shift])
            orders.append(rotated)
            orders.append(Array(rotated.reversed()))
        }
        for order in orders {
            let actual = TravelDays.boundaryStays(of: order)
            let expected = referenceBoundaryStays(of: order)
            #expect(actual.first === expected.first)
            #expect(actual.last === expected.last)
        }
    }

    @Test("the stored label calendar answers like a freshly built Gregorian UTC calendar")
    func storedLabelCalendarMatchesFreshCalendar() {
        var fresh = Calendar(identifier: .gregorian)
        fresh.timeZone = TimeZone(secondsFromGMT: 0)!
        let stored = TravelDays.labelCalendar
        #expect(stored.identifier == fresh.identifier)
        #expect(stored.timeZone == fresh.timeZone)
        let reference = Date(timeIntervalSince1970: 1_750_000_000)
        // 1900, just before the epoch, a leap day, both sides of a New Year, 2100.
        for seconds in [-2_208_988_800.0, -1, 951_782_400, 1_735_689_599, 1_735_689_600, 4_102_444_800] {
            let day = Date(timeIntervalSince1970: seconds)
            for component in [Calendar.Component.year, .month, .day] {
                #expect(stored.component(component, from: day) == fresh.component(component, from: day))
            }
            #expect(stored.date(byAdding: .day, value: 1, to: day) == fresh.date(byAdding: .day, value: 1, to: day))
            #expect(stored.dateComponents([.day], from: day, to: reference)
                    == fresh.dateComponents([.day], from: day, to: reference))
        }
    }

    @Test("one span walk per trip gives every consumer's boundaries: labels and durations, twins, ties and empty trips")
    func sharedSpansMatchPerConsumerWalks() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        func add(_ start: Date, _ end: Date, _ zone: String?, id: UUID, to parent: Trip) {
            let row = Stay(startTime: start, endTime: end, centroidLatitude: 0, centroidLongitude: 0,
                           h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 100, pingIDs: [],
                           timeZoneIdentifier: zone)
            row.id = id
            context.insert(row)
            row.trip = parent
        }
        let tied = trip(context, start: date(2025, 1, 1, hour: 10), end: date(2025, 1, 3, hour: 10),
                        firstZone: "Pacific/Kiritimati", lastZone: "Pacific/Pago_Pago")
        let opening = try #require(tied.stays?.first { $0.timeZoneIdentifier == "Pacific/Kiritimati" })
        let closing = try #require(tied.stays?.first { $0.timeZoneIdentifier == "Pacific/Pago_Pago" })
        // A UUID twin of the opening stay a minute later (an exact twin tie
        // follows the relationship's order, pinned above on explicit arrays),
        // and a closing stay tied on the instant with the smallest id, which
        // takes the last boundary.
        add(opening.startTime.addingTimeInterval(60), opening.endTime.addingTimeInterval(60),
            "Asia/Tokyo", id: opening.id, to: tied)
        add(closing.startTime, closing.endTime, "Europe/Athens",
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, to: tied)
        let ongoing = trip(context, start: date(2025, 2, 1), end: nil, firstZone: nil, lastZone: "Asia/Tokyo")
        let reversed = trip(context, start: date(2025, 5, 5), end: date(2025, 5, 1))
        let bare = Trip(startDate: date(2025, 4, 1))
        bare.endDate = date(2025, 4, 2)
        bare.isComplete = true
        context.insert(bare)
        try context.save()

        let trips = [tied, ongoing, reversed, bare]
        let spans = TravelDays.spans(trips: trips, checkCancellation: {})
        #expect(spans.count == trips.count)
        #expect(referenceSpan(of: tied).lastZone == "Europe/Athens")
        for (trip, span) in zip(trips, spans) {
            let reference = referenceSpan(of: trip)
            #expect(span.start == reference.start)
            #expect(span.end == reference.end)
            #expect(span.firstZone == reference.firstZone)
            #expect(span.lastZone == reference.lastZone)
            // Passport's duration from the span is `Trip.durationDays`.
            let duration = span.end.map {
                Trip.inclusiveDays(from: span.start, in: StayTimeZone.resolve(span.firstZone),
                                   to: $0, in: StayTimeZone.resolve(span.lastZone))
            }
            #expect(duration == trip.durationDays)
        }
        let now = date(2025, 6, 1)
        for zone in [TimeZone(secondsFromGMT: 0)!, TimeZone(identifier: "America/Los_Angeles")!] {
            let reference = TravelDays.labels(spans: trips.map { referenceSpan(of: $0) }, now: now,
                                              fallbackZone: zone, checkCancellation: {})
            #expect(TravelDays.labels(trips: trips, now: now, fallbackZone: zone) == reference)
        }
    }
}
