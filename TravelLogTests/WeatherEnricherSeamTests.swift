//
//  WeatherEnricherSeamTests.swift
//  TravelLogTests
//
//  Cancellation with chunks remaining must persist no weather, and the daily
//  WeatherKit budget is consumed per request, not per candidate. Both are
//  tested through the `DailyWeatherSample`/`setWeatherProviderForTesting` seam.
//  WeatherKit's `DayWeather` has no public initializer, so the seam abstracts
//  above it.
//
//  `.serialized`: all tests mutate the process-global budget UserDefaults
//  keys; each saves and restores them.
//

import Foundation
import CoreLocation
import SwiftData
import Testing
@testable import TravelLog

@Suite(.serialized)
@MainActor
struct WeatherEnricherSeamTests {

    private static let hour: TimeInterval = 3600
    private static let day: TimeInterval = 86400

    /// A settled (ended >12 h ago), weatherless stay spanning exactly
    /// A `spanDays` value > 10 days forces the chunk loop.
    @discardableResult
    private func makeStay(in ctx: ModelContext, spanDays: Double, hex: String) -> Stay {
        let end = Date.now.addingTimeInterval(-13 * Self.hour)
        let stay = Stay(
            startTime: end.addingTimeInterval(-spanDays * Self.day),
            endTime: end,
            centroidLatitude: 37.98, centroidLongitude: 23.72,
            h3IndexRes6: hex, pingCount: 4,
            distanceFromHomeKm: 500, pingIDs: []
        )
        stay.category = .destination
        ctx.insert(stay)
        return stay
    }

    private func sample(_ condition: StayWeather.Condition = .clear) -> WeatherEnricher.DailyWeatherSample {
        WeatherEnricher.DailyWeatherSample(
            lowC: 18, highC: 28, precipitationMm: 0,
            windSpeedMs: 3, maxHumidity: 0.5, condition: condition
        )
    }

    /// Snapshot + restore the shared budget defaults around a test body,
    /// and seed a known remaining budget for today.
    private func withBudget(used: Int, _ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let savedDay = defaults.string(forKey: WeatherEnricher.budgetDayKey)
        let savedUsed = defaults.object(forKey: WeatherEnricher.budgetUsedKey)
        defer {
            defaults.set(savedDay, forKey: WeatherEnricher.budgetDayKey)
            defaults.set(savedUsed, forKey: WeatherEnricher.budgetUsedKey)
        }
        let today = ISO8601DateFormatter.string(
            from: .now, timeZone: .current, formatOptions: [.withFullDate]
        )
        defaults.set(today, forKey: WeatherEnricher.budgetDayKey)
        defaults.set(used, forKey: WeatherEnricher.budgetUsedKey)
        try await body()
    }

    // MARK: - budget is consumed per request

    @Test("a 21-day stay consumes THREE budget units; one per WeatherKit chunk, not one per candidate")
    func budgetConsumedPerChunkRequest() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeStay(in: ctx, spanDays: 21, hex: "WA")
        try ctx.save()
        let enricher = WeatherEnricher(modelContainer: container)
        let clearDay = sample()
        await enricher.setWeatherProviderForTesting { _, _, _ in [clearDay] }

        await withBudget(used: 0) {
            await enricher.enrichRecentStaysGated(limit: 5, gate: PipelineGate(forTesting: ()))
            let remaining = WeatherEnricher.remainingDailyBudget()
            // Counting per candidate would consume only 1 unit for this stay.
            #expect(WeatherEnricher.opportunisticDailyLimit - remaining == 3)
        }

        let fresh = ModelContext(container)
        let stays = try fresh.fetch(FetchDescriptor<Stay>())
        #expect(stays.first?.weatherConditionRaw == StayWeather.Condition.clear.rawValue)
    }

    @Test("budget exhaustion mid-stay persists nothing and leaves the stay immediately retryable (no failure backoff)")
    func budgetExhaustionMidStayIsRetryable() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeStay(in: ctx, spanDays: 21, hex: "WB")
        try ctx.save()
        let enricher = WeatherEnricher(modelContainer: container)
        let clearDay = sample()
        await enricher.setWeatherProviderForTesting { _, _, _ in [clearDay] }

        try await withBudget(used: WeatherEnricher.opportunisticDailyLimit - 1) {
            // 1 unit remaining; chunk 1 spends it, chunk 2 must throw
            // `budgetExhausted`. No partial weather may persist when the budget
            // runs out between chunks.
            await enricher.enrichRecentStaysGated(limit: 5, gate: PipelineGate(forTesting: ()))
            #expect(WeatherEnricher.remainingDailyBudget() == 0)
            let midFetch = ModelContext(container)
            let mid = try midFetch.fetch(FetchDescriptor<Stay>())
            #expect(mid.first?.weatherConditionRaw == nil)

            // Refill the budget and re-run: the stay must enrich NOW.
            // `budgetExhausted` stamping the 1-hour `failedFetchAt` backoff
            // would make `shouldEnrich` skip it here and fail this expect.
            UserDefaults.standard.set(0, forKey: WeatherEnricher.budgetUsedKey)
            await enricher.enrichRecentStaysGated(limit: 5, gate: PipelineGate(forTesting: ()))
            let fresh = ModelContext(container)
            let stays = try fresh.fetch(FetchDescriptor<Stay>())
            #expect(stays.first?.weatherConditionRaw == StayWeather.Condition.clear.rawValue)
        }
    }

    // MARK: - cancellation with chunks remaining

    @Test("cancellation after chunk 1 of 3 persists NO weather; the stay stays eligible for retry")
    func cancellationMidChunksPersistsNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeStay(in: ctx, spanDays: 21, hex: "WC")
        try ctx.save()
        let enricher = WeatherEnricher(modelContainer: container)

        // The provider uses a barrier to make cancellation timing deterministic:
        // it signals the test when chunk 1 is in flight, then holds until the
        // enrich task is cancelled, then RETURNS data. The loop must then
        // observe `Task.isCancelled` with chunks remaining and throw.
        // Breaking out of the loop would persist a partial result.
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let providerSample = sample()
        await enricher.setWeatherProviderForTesting { _, _, _ in
            enteredContinuation.yield()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return [providerSample]
        }

        try await withBudget(used: 0) {
            let gate = PipelineGate(forTesting: ())
            let enrichTask = Task { await enricher.enrichRecentStaysGated(limit: 5, gate: gate) }
            var iterator = entered.makeAsyncIterator()
            _ = await iterator.next()   // chunk 1 is in flight
            enrichTask.cancel()
            await enrichTask.value

            let fresh = ModelContext(container)
            let stays = try fresh.fetch(FetchDescriptor<Stay>())
            #expect(stays.first?.weatherConditionRaw == nil)
            #expect(stays.first?.weather == nil)
        }
    }

    // MARK: - Opportunistic home/routine window

    @Test("older extreme-month home stays are reached behind 600 newer shoulder-month home stays")
    func opportunisticReachesExtremeHomeStaysBehindShoulderRows() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // Nov/Dec passes sprint on the current local year; otherwise use last year.
        let localNow = Calendar.current.dateComponents([.year, .month], from: .now)
        let year = localNow.month! >= 11 ? localNow.year! : localNow.year! - 1

        func homeStay(start: Date, hex: String) -> Stay {
            let stay = Stay(
                startTime: start,
                endTime: start.addingTimeInterval(4 * Self.hour),
                centroidLatitude: 37.98, centroidLongitude: 23.72,
                h3IndexRes6: hex, pingCount: 4,
                distanceFromHomeKm: 0, pingIDs: []
            )
            stay.category = .home
            ctx.insert(stay)
            return stay
        }
        let january = utc.date(from: DateComponents(year: year, month: 1, day: 10, hour: 8))!
        let januaryIDs = (0..<5).map {
            homeStay(start: january.addingTimeInterval(Double($0) * Self.day), hex: "JAN\($0)").id
        }
        let october = utc.date(from: DateComponents(year: year, month: 10, day: 1))!
        for index in 0..<600 {
            _ = homeStay(start: october.addingTimeInterval(Double(index) * Self.hour), hex: "OCT\(index)")
        }
        let preFloor = homeStay(start: utc.date(from: DateComponents(year: 2020, month: 4, day: 2))!, hex: "OLD").id
        try ctx.save()

        let enricher = WeatherEnricher(modelContainer: container)
        let clearDay = sample()
        await enricher.setWeatherProviderForTesting { _, _, _ in [clearDay] }

        await withBudget(used: 0) {
            await enricher.enrichOpportunistically(gate: PipelineGate(forTesting: ()))
        }

        let fresh = ModelContext(container)
        let stays = try fresh.fetch(FetchDescriptor<Stay>())
        let enrichedJanuary = stays.filter { januaryIDs.contains($0.id) && $0.weatherConditionRaw == StayWeather.Condition.clear.rawValue }
        // Sprints may stop at score zero, so require progress rather than all five.
        #expect(!enrichedJanuary.isEmpty)
        let octoberTouched = stays.filter { $0.h3IndexRes6.hasPrefix("OCT") && $0.weatherConditionRaw != nil }
        #expect(octoberTouched.isEmpty)
        // Sprint windows exclude pre-floor years; ordinary passes must still mark them behind newer rows.
        if localNow.month! < 11 {
            let old = stays.first { $0.id == preFloor }
            #expect(old?.weatherConditionRaw == StayWeather.Condition.unavailable.rawValue)
        }
    }

    // MARK: - Trip open publishes .stay only after a write

    /// Applies every pending bump now instead of waiting out the real 500 ms
    /// debounce (`StoreChangeTrackerTests` pins the timer itself). The gated
    /// units await their bumps, so every bump of the call under test is pending.
    private func flushStoreChanges() async throws {
        StoreChangeTracker.shared.flushPendingForTesting()
    }

    @Test("opening an already-enriched trip leaves the .stay generation untouched", .timeLimit(.minutes(1)))
    func enrichedTripOpenDoesNotBumpStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let stay = makeStay(in: ctx, spanDays: 2, hex: "WT1")
        let trip = Trip(startDate: stay.startTime)
        ctx.insert(trip)
        stay.trip = trip
        stay.weatherConditionRaw = StayWeather.Condition.clear.rawValue
        stay.weatherData = Data([1])
        try ctx.save()
        let enricher = WeatherEnricher(modelContainer: container)
        let providerCalls = Counter()
        await enricher.setWeatherProviderForTesting { _, _, _ in
            await providerCalls.increment()
            return []
        }

        try await flushStoreChanges()
        let before = StoreChangeTracker.shared.token(for: .stay)
        await enricher.enrichStaysForTripGated(trip.id, gate: PipelineGate(forTesting: ()))
        try await flushStoreChanges()
        #expect(StoreChangeTracker.shared.token(for: .stay) == before)
        #expect(await providerCalls.value == 0)
    }

    @Test("a cache hit on trip open still publishes the .stay generation", .timeLimit(.minutes(1)))
    func cacheHitTripOpenBumpsStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let stay = makeStay(in: ctx, spanDays: 2, hex: "WT2")
        let trip = Trip(startDate: stay.startTime)
        ctx.insert(trip)
        stay.trip = trip
        let sibling = makeStay(in: ctx, spanDays: 2, hex: "WT2")
        sibling.weatherConditionRaw = StayWeather.Condition.clear.rawValue
        sibling.weatherData = Data([1])
        sibling.dayKey = WeatherEnricher.computeDayKey(for: sibling.startTime)
        try ctx.save()
        let enricher = WeatherEnricher(modelContainer: container)
        let stayID = stay.id

        try await flushStoreChanges()
        let before = StoreChangeTracker.shared.token(for: .stay)
        await enricher.enrichStaysForTripGated(trip.id, gate: PipelineGate(forTesting: ()))
        try await flushStoreChanges()
        #expect(StoreChangeTracker.shared.token(for: .stay) != before)
        let fresh = ModelContext(container)
        let cached = try fresh.fetch(FetchDescriptor<Stay>(predicate: #Predicate { $0.id == stayID })).first
        #expect(cached?.weatherConditionRaw == StayWeather.Condition.clear.rawValue)
    }

    // MARK: - Opportunistic fruitless latch

    /// A settled, weatherless destination stay on a trip: an opportunistic candidate with a positive sprint score.
    @discardableResult
    private func makeTripStay(in ctx: ModelContext, hex: String) -> Stay {
        let stay = makeStay(in: ctx, spanDays: 2, hex: hex)
        let trip = Trip(startDate: stay.startTime)
        ctx.insert(trip)
        stay.trip = trip
        return stay
    }

    private func condition(of stayID: UUID, in container: ModelContainer) throws -> String? {
        let fresh = ModelContext(container)
        return try fresh.fetch(FetchDescriptor<Stay>(predicate: #Predicate { $0.id == stayID })).first?.weatherConditionRaw
    }

    @Test("a cancelled pass never latches; the next pass fetches")
    func cancelledPassDoesNotLatch() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let stayID = makeTripStay(in: ctx, hex: "WL4").id
        try ctx.save()
        let enricher = WeatherEnricher(modelContainer: container)
        let providerCalls = Counter()
        let clearDay = sample()
        await enricher.setWeatherProviderForTesting { _, _, _ in
            await providerCalls.increment()
            return [clearDay]
        }

        await withBudget(used: 0) {
            let gate = PipelineGate(forTesting: ())
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                await enricher.enrichOpportunistically(gate: gate)
            }
            await cancelled.value
            await enricher.enrichOpportunistically(gate: gate)
        }
        #expect(await enricher.planCountForTesting == 2)
        #expect(await providerCalls.value == 1)
        #expect(try condition(of: stayID, in: container) == StayWeather.Condition.clear.rawValue)
    }

    @Test("a stay crossing the settle threshold changes the fruitless token within one local day")
    func settleCrossingChangesTheToken() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // 06:00 local, so now + 12 h is 18:00 the same local day.
        let now = Calendar.current.date(from: DateComponents(year: 2025, month: 6, day: 17, hour: 6))!
        let end = now.addingTimeInterval(-Self.hour)
        let stay = Stay(
            startTime: end.addingTimeInterval(-2 * Self.hour),
            endTime: end,
            centroidLatitude: 37.98, centroidLongitude: 23.72,
            h3IndexRes6: "WL5", pingCount: 4,
            distanceFromHomeKm: 500, pingIDs: []
        )
        stay.category = .destination
        ctx.insert(stay)
        try ctx.save()
        let enricher = WeatherEnricher(modelContainer: container)

        let unsettled = await enricher.fruitlessPassTokenForTesting(now: now)
        let settled = await enricher.fruitlessPassTokenForTesting(now: now.addingTimeInterval(12 * Self.hour))
        #expect(unsettled != settled)
    }

    @Test("a trip-membership or category change alone changes the fruitless token")
    func membershipAndCategoryChangesChangeTheToken() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let now = Calendar.current.date(from: DateComponents(year: 2025, month: 6, day: 17, hour: 12))!
        let end = now.addingTimeInterval(-13 * Self.hour)
        let stay = Stay(
            startTime: end.addingTimeInterval(-2 * Self.day),
            endTime: end,
            centroidLatitude: 37.98, centroidLongitude: 23.72,
            h3IndexRes6: "WL6", pingCount: 4,
            distanceFromHomeKm: 500, pingIDs: []
        )
        stay.category = .destination
        ctx.insert(stay)
        try ctx.save()
        let enricher = WeatherEnricher(modelContainer: container)
        let tripless = await enricher.fruitlessPassTokenForTesting(now: now)

        // Same rows, times and weather: only trip membership changes.
        let trip = Trip(startDate: stay.startTime)
        ctx.insert(trip)
        stay.trip = trip
        try ctx.save()
        let member = await enricher.fruitlessPassTokenForTesting(now: now)
        #expect(member != tripless)

        // Only the category changes.
        stay.category = .home
        try ctx.save()
        let home = await enricher.fruitlessPassTokenForTesting(now: now)
        #expect(home != member)
    }

    // MARK: - Opportunistic reranking over projected measurements

    @Test("an opportunistic pass requests in the order a full rerank of the measured values gives",
          .timeLimit(.minutes(1)))
    func opportunisticRerankMatchesFullRegroup() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        disableSprint(in: ctx)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let year = utc.component(.year, from: .now) - 1
        func makeRow(month: Int, day: Int, lat: Double, hex: String, trip: Trip?, tempC: Double? = nil) -> Stay {
            let start = utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
            let row = Stay(
                startTime: start, endTime: start.addingTimeInterval(Self.day),
                centroidLatitude: lat, centroidLongitude: 23.7,
                h3IndexRes6: hex, pingCount: 4,
                distanceFromHomeKm: 500, pingIDs: []
            )
            row.category = .destination
            if let tempC {
                row.avgTemperatureC = tempC
                row.weatherConditionRaw = StayWeather.Condition.clear.rawValue
            }
            ctx.insert(row)
            row.trip = trip
            return row
        }
        let measuredTrip = Trip(startDate: .now)
        let unmeasuredTrip = Trip(startDate: .now)
        ctx.insert(measuredTrip)
        ctx.insert(unmeasuredTrip)
        // Far records zero every candidate's seasonal urgency. The near-record row
        // promotes only its own trip (8+ days from every candidate), so its
        // projected trip id is what reorders the queue once `first` is measured.
        let measuredRows = [
            makeRow(month: 7, day: 1, lat: 80, hex: "WR-hot", trip: nil, tempC: 45),
            makeRow(month: 1, day: 1, lat: 80, hex: "WR-cold", trip: nil, tempC: -40),
            makeRow(month: 7, day: 1, lat: 38, hex: "WR-near", trip: measuredTrip, tempC: 44),
        ]
        let promoted = makeRow(month: 7, day: 10, lat: 38, hex: "WR-promoted", trip: measuredTrip)
        let second = makeRow(month: 7, day: 20, lat: 38, hex: "WR-second", trip: unmeasuredTrip)
        let first = makeRow(month: 7, day: 25, lat: 38, hex: "WR-first", trip: unmeasuredTrip)
        try ctx.save()

        let enricher = WeatherEnricher(modelContainer: container)
        let log = RequestLog()
        let mildDay = WeatherEnricher.DailyWeatherSample(
            lowC: 20, highC: 20, precipitationMm: 0,
            windSpeedMs: 3, maxHumidity: 0.5, condition: .clear
        )
        await enricher.setWeatherProviderForTesting { location, start, end in
            _ = await log.record(latitude: location.coordinate.latitude, start: start, end: end)
            return [mildDay]
        }
        await withBudget(used: 0) {
            await enricher.enrichOpportunistically(gate: PipelineGate(forTesting: ()))
        }
        let requested = await log.requests.map(\.start)

        // The pre-cache rerank: regroup every measured value before each pick.
        var measurements = measuredRows.map { row in
            WeatherEnrichmentPlanner.Measurement(
                latitude: row.centroidLatitude, longitude: row.centroidLongitude,
                startTime: row.startTime, endTime: row.endTime,
                tripID: row.trip?.id, avgTemperatureC: row.avgTemperatureC ?? .nan)
        }
        let candidates = [promoted, second, first].map { row in
            WeatherEnrichmentPlanner.Candidate(
                id: row.id, latitude: row.centroidLatitude, longitude: row.centroidLongitude,
                startTime: row.startTime, endTime: row.endTime,
                tripID: row.trip?.id, isTripStay: true)
        }
        var remaining = WeatherEnrichmentPlanner.rankedQueue(candidates, measurements: measurements).map(\.candidate)
        #expect(remaining.map(\.startTime) == [first.startTime, second.startTime, promoted.startTime])
        var expected: [Date] = []
        while let top = WeatherEnrichmentPlanner.nextCandidate(remaining, measurements: measurements) {
            let picked = remaining.remove(at: top.sourceIndex)
            expected.append(picked.startTime)
            measurements.append(WeatherEnrichmentPlanner.Measurement(
                latitude: picked.latitude, longitude: picked.longitude,
                startTime: picked.startTime, endTime: picked.endTime,
                tripID: picked.tripID, avgTemperatureC: 20))
        }
        #expect(expected == [first.startTime, promoted.startTime, second.startTime])
        #expect(requested == expected)
    }

    // MARK: - Apply witnesses: results land only on the geometry they were fetched for

    enum Lane: String, CaseIterable, Sendable { case trip, recent, opportunistic }
    enum Mutation: String, CaseIterable, Sendable { case start, centroid }

    /// One pass of `lane`, the way its production caller runs it.
    private func runPass(_ lane: Lane, _ enricher: WeatherEnricher, tripID: UUID, gate: PipelineGate) async {
        switch lane {
        case .trip: await enricher.enrichStaysForTripGated(tripID, gate: gate)
        case .recent: await enricher.enrichRecentStaysGated(limit: 10, gate: gate)
        case .opportunistic: await enricher.enrichOpportunistically(gate: gate)
        }
    }

    /// A Wrapped row for the current year turns Nov/Dec sprints off, so a
    /// score-zero candidate is still fetched by recency.
    private func disableSprint(in ctx: ModelContext) {
        ctx.insert(YearWrapped(year: Calendar.current.component(.year, from: .now)))
    }

    private func rows(_ stayID: UUID, in container: ModelContainer) throws -> [Stay] {
        try ModelContext(container).fetch(FetchDescriptor<Stay>(predicate: #Predicate { $0.id == stayID }))
    }

    /// Another writer's committed edit through its own context.
    private static func edit(_ stayID: UUID, in container: ModelContainer, _ mutation: Mutation) {
        let context = ModelContext(container)
        guard let stay = try? context.fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == stayID })).first else { return }
        switch mutation {
        case .start: stay.startTime = stay.startTime.addingTimeInterval(-3 * day)
        case .centroid: stay.centroidLatitude += 0.001
        }
        try? context.save()
    }

    private static func storeCondition(_ condition: StayWeather.Condition, on stayID: UUID, in container: ModelContainer) {
        let context = ModelContext(container)
        guard let stay = try? context.fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == stayID })).first else { return }
        stay.weatherConditionRaw = condition.rawValue
        stay.weatherData = Data([1])
        try? context.save()
    }

    /// Deletes the requested row and inserts a same-UUID replacement with identical geometry.
    private static func replace(_ stayID: UUID, in container: ModelContainer) {
        let context = ModelContext(container)
        guard let old = try? context.fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == stayID })).first else { return }
        let replacement = Stay(
            startTime: old.startTime, endTime: old.endTime,
            centroidLatitude: old.centroidLatitude, centroidLongitude: old.centroidLongitude,
            h3IndexRes6: old.h3IndexRes6, pingCount: old.pingCount,
            distanceFromHomeKm: old.distanceFromHomeKm, pingIDs: [])
        replacement.id = stayID
        replacement.category = .destination
        let trip = old.trip
        old.trip = nil
        context.delete(old)
        context.insert(replacement)
        replacement.trip = trip
        try? context.save()
    }

    @Test("a result fetched for geometry another writer changed in flight is dropped; the next pass fetches the new geometry",
          .timeLimit(.minutes(1)), arguments: Lane.allCases, Mutation.allCases)
    func inFlightGeometryChangeDropsTheResult(lane: Lane, mutation: Mutation) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let stay = makeTripStay(in: ctx, hex: "WG-\(lane.rawValue)-\(mutation.rawValue)")
        disableSprint(in: ctx)
        let stayID = stay.id
        let tripID = try #require(stay.trip?.id)
        let originalStart = stay.startTime
        let originalLatitude = stay.centroidLatitude
        try ctx.save()

        let enricher = WeatherEnricher(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let log = RequestLog()
        let clearDay = sample()
        await enricher.setWeatherProviderForTesting { location, start, end in
            let call = await log.record(latitude: location.coordinate.latitude, start: start, end: end)
            // The fetch runs outside every gate unit, so the writer can take the gate.
            if call == 1 {
                await gate.run(touching: [.stay]) { await Self.edit(stayID, in: container, mutation) }
            }
            return [clearDay]
        }

        try await withBudget(used: 0) {
            await runPass(lane, enricher, tripID: tripID, gate: gate)
            let dropped = try #require(try rows(stayID, in: container).first)
            #expect(dropped.weatherConditionRaw == nil)
            #expect(dropped.dayKey == nil)

            await runPass(lane, enricher, tripID: tripID, gate: gate)
        }

        let requests = await log.requests
        #expect(requests.count == 2)
        #expect(requests.first?.start == originalStart)
        switch mutation {
        case .start:
            #expect(requests.last?.start == originalStart.addingTimeInterval(-3 * Self.day))
        case .centroid:
            #expect(abs((requests.last?.latitude ?? 0) - (originalLatitude + 0.001)) < 1e-9)
        }
        let enriched = try #require(try rows(stayID, in: container).first)
        #expect(enriched.weatherConditionRaw == StayWeather.Condition.clear.rawValue)
        #expect(enriched.dayKey == WeatherEnricher.computeDayKey(for: enriched.startTime))
    }

    @Test("trip open never overwrites weather another writer stored while its request was in flight",
          .timeLimit(.minutes(1)))
    func tripOpenNeverOverwritesStoredWeather() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let stay = makeTripStay(in: ctx, hex: "WG-overwrite")
        let stayID = stay.id
        let tripID = try #require(stay.trip?.id)
        try ctx.save()

        let enricher = WeatherEnricher(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let clearDay = sample()
        await enricher.setWeatherProviderForTesting { _, _, _ in
            await gate.run(touching: [.stay]) { await Self.storeCondition(.snow, on: stayID, in: container) }
            return [clearDay]
        }
        await enricher.enrichStaysForTripGated(tripID, gate: gate)

        #expect(try condition(of: stayID, in: container) == StayWeather.Condition.snow.rawValue)
    }

    @Test("UUID twins each get their own request and keep the aggregate fetched for their own interval",
          .timeLimit(.minutes(1)), arguments: Lane.allCases)
    func twinsKeepTheirOwnAggregates(lane: Lane) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let first = makeTripStay(in: ctx, hex: "WG-twin-a-\(lane.rawValue)")
        let twin = makeStay(in: ctx, spanDays: 5, hex: "WG-twin-b-\(lane.rawValue)")
        twin.id = first.id
        twin.trip = first.trip
        disableSprint(in: ctx)
        let stayID = first.id
        let tripID = try #require(first.trip?.id)
        let firstStart = first.startTime
        try ctx.save()

        let enricher = WeatherEnricher(modelContainer: container)
        let log = RequestLog()
        let rainDay = sample(.rain)
        let snowDay = sample(.snow)
        await enricher.setWeatherProviderForTesting { location, start, end in
            _ = await log.record(latitude: location.coordinate.latitude, start: start, end: end)
            return [start == firstStart ? rainDay : snowDay]
        }
        await withBudget(used: 0) {
            await runPass(lane, enricher, tripID: tripID, gate: PipelineGate(forTesting: ()))
        }

        let requestCount = await log.requests.count
        #expect(requestCount == 2)
        let saved = try rows(stayID, in: container)
        #expect(saved.count == 2)
        for row in saved {
            let expected: StayWeather.Condition = row.startTime == firstStart ? .rain : .snow
            #expect(row.weatherConditionRaw == expected.rawValue)
        }
    }

    @Test("a same-UUID replacement inserted while the request was in flight is left untouched",
          .timeLimit(.minutes(1)), arguments: Lane.allCases)
    func replacementRowIsNotEnrichedByTheDeletedRowsResult(lane: Lane) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let stay = makeTripStay(in: ctx, hex: "WG-replace-\(lane.rawValue)")
        disableSprint(in: ctx)
        let stayID = stay.id
        let tripID = try #require(stay.trip?.id)
        try ctx.save()

        let enricher = WeatherEnricher(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let log = RequestLog()
        let clearDay = sample()
        await enricher.setWeatherProviderForTesting { location, start, end in
            let call = await log.record(latitude: location.coordinate.latitude, start: start, end: end)
            if call == 1 {
                await gate.run(touching: [.stay]) { await Self.replace(stayID, in: container) }
            }
            return [clearDay]
        }

        try await withBudget(used: 0) {
            await runPass(lane, enricher, tripID: tripID, gate: gate)
            let replacement = try rows(stayID, in: container)
            #expect(replacement.count == 1)
            #expect(replacement.first?.weatherConditionRaw == nil)

            // The replacement is ordinary backlog for the next pass.
            await runPass(lane, enricher, tripID: tripID, gate: gate)
        }
        #expect(try condition(of: stayID, in: container) == StayWeather.Condition.clear.rawValue)
    }

    @Test("a failed apply save persists no weather and the next pass retries", .timeLimit(.minutes(1)))
    func failedApplySaveLeavesTheStayRetryable() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let stayID = makeTripStay(in: ctx, hex: "WG-save").id
        try ctx.save()

        let enricher = WeatherEnricher(modelContainer: container)
        let clearDay = sample()
        await enricher.setWeatherProviderForTesting { _, _, _ in [clearDay] }
        await enricher.setFailNextApplySaveForTesting(true)

        try await withBudget(used: 0) {
            await enricher.enrichRecentStaysGated(limit: 5, gate: PipelineGate(forTesting: ()))
            let row = try #require(try rows(stayID, in: container).first)
            #expect(row.weatherConditionRaw == nil)
            #expect(row.weatherData == nil)
            #expect(row.dayKey == nil)

            await enricher.enrichRecentStaysGated(limit: 5, gate: PipelineGate(forTesting: ()))
        }
        #expect(try condition(of: stayID, in: container) == StayWeather.Condition.clear.rawValue)
    }

    // MARK: - Closure invalidation refetches the new geometry

    @Test("closing an enriched anchor across a UTC day clears it, and the next pass fetches the closed interval",
          .timeLimit(.minutes(1)))
    func closedAnchorIsRefetchedForItsNewInterval() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let today = WeatherEnricher.utcCalendar.startOfDay(for: .now)
        let anchorStart = today.addingTimeInterval(-4 * Self.day + 10 * Self.hour)
        let anchorEnd = today.addingTimeInterval(-3 * Self.day + 20 * Self.hour)
        let anchor = Stay(
            startTime: anchorStart, endTime: anchorEnd,
            centroidLatitude: 0, centroidLongitude: -140,
            h3IndexRes6: H3Service.cellIndex(latitude: 0, longitude: -140) ?? "",
            pingCount: 0, distanceFromHomeKm: 500, pingIDs: [])
        anchor.weather = StayWeather(
            condition: .rain, temperatureMinC: 10, temperatureMaxC: 14,
            temperatureAvgC: 12, precipitationMm: 4, windSpeedMs: 2, humidity: 0.8)
        anchor.avgTemperatureC = 12
        anchor.weatherConditionRaw = StayWeather.Condition.rain.rawValue
        anchor.precipitationMm = 4
        anchor.dayKey = WeatherEnricher.computeDayKey(for: anchorStart)
        ctx.insert(anchor)
        // A distant ping 16 hours later closes the anchor at the capped midpoint.
        let ping = LocationPing(
            timestamp: today.addingTimeInterval(-2 * Self.day + 12 * Self.hour),
            latitude: 0, longitude: -139.9, horizontalAccuracy: 5,
            h3IndexRes6: H3Service.cellIndex(latitude: 0, longitude: -139.9) ?? "")
        ping.isProcessed = false
        ctx.insert(ping)
        try ctx.save()
        let anchorID = anchor.id

        _ = await StayClusterer(modelContainer: container).clusterUnprocessedPings()
        let closedEnd = today.addingTimeInterval(-2 * Self.day + 4 * Self.hour)
        let closed = try #require(try rows(anchorID, in: container).first)
        #expect(closed.endTime == closedEnd)
        #expect(closed.weatherConditionRaw == nil)

        let enricher = WeatherEnricher(modelContainer: container)
        let log = RequestLog()
        let clearDay = sample()
        await enricher.setWeatherProviderForTesting { location, start, end in
            _ = await log.record(latitude: location.coordinate.latitude, start: start, end: end)
            return [clearDay]
        }
        await withBudget(used: 0) {
            await enricher.enrichRecentStaysGated(limit: 10, gate: PipelineGate(forTesting: ()))
        }

        let requests = await log.requests
        #expect(requests.contains { $0.start == anchorStart && $0.end == closedEnd })
        #expect(try condition(of: anchorID, in: container) == StayWeather.Condition.clear.rawValue)
    }
}

/// Every WeatherKit request the provider seam received, in order.
private actor RequestLog {
    struct Request: Sendable {
        let latitude: Double
        let start: Date
        let end: Date
    }

    private(set) var requests: [Request] = []

    /// Records a request and returns its 1-based call number.
    func record(latitude: Double, start: Date, end: Date) -> Int {
        requests.append(Request(latitude: latitude, start: start, end: end))
        return requests.count
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
