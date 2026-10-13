//
//  WeatherEnricher.swift
//  TravelLog
//

import Foundation
import SwiftData
import WeatherKit
import CoreLocation
import os.log

@ModelActor
actor WeatherEnricher {

    private let logger = Logger(subsystem: "com.travellog.app", category: "WeatherEnricher")

    private static let settledThresholdSeconds: TimeInterval = 12 * 60 * 60
    /// UTC Gregorian frame shared by every date window in this file.
    nonisolated static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
    /// Internal (not private) because `YearWrappedGenerator`'s extremes-safe
    /// gate must exclude pre-floor stays with the same boundary the terminal
    /// `.unavailable` marking uses.
    nonisolated static let weatherKitFloorDate: Date =
        WeatherEnricher.utcCalendar.date(from: DateComponents(year: 2021, month: 8, day: 1))!
    /// Maximum forecast span; CalendarEnricher.forecastHorizonSeconds must derive from this for shared quota accounting.
    nonisolated static let maxDaysPerRequest = 10

    /// Session-local retry backoff prevents repeated failed/no-data requests on every view or BG refresh; resets on relaunch.
    private var failedFetchAt: [UUID: Date] = [:]
    private static let retryBackoffSeconds: TimeInterval = 60 * 60 // 1 hour

    /// Keep a candidate window for free cache/terminal work even when network quota is exhausted.
    private static let exhaustedBudgetPlanningWindow = 10

    /// Testable daily sample mapped at the WeatherKit boundary; DayWeather has no public initializer.
    nonisolated struct DailyWeatherSample: Sendable {
        let lowC: Double
        let highC: Double
        let precipitationMm: Double
        let windSpeedMs: Double
        let maxHumidity: Double
        let condition: StayWeather.Condition
    }

    typealias DailyWeatherProvider = @Sendable (CLLocation, Date, Date) async throws -> [DailyWeatherSample]

    #if DEBUG
    /// Test-only override for the WeatherKit call.
    private var weatherProviderOverride: DailyWeatherProvider?

    func setWeatherProviderForTesting(_ provider: DailyWeatherProvider?) {
        weatherProviderOverride = provider
    }
    #endif

    /// The ONE place a daily forecast is fetched: the injected override in
    /// tests, WeatherKit (mapped to samples) in production.
    private func fetchDaily(location: CLLocation, start: Date, end: Date) async throws -> [DailyWeatherSample] {
        #if DEBUG
        if let weatherProviderOverride {
            return try await weatherProviderOverride(location, start, end)
        }
        #endif
        let forecast = try await WeatherService.shared.weather(
            for: location,
            including: .daily(startDate: start, endDate: end)
        )
        return forecast.map { day in
            DailyWeatherSample(
                lowC: day.lowTemperature.converted(to: .celsius).value,
                highC: day.highTemperature.converted(to: .celsius).value,
                precipitationMm: day.precipitationAmountByType.precipitation.converted(to: .millimeters).value,
                windSpeedMs: day.wind.speed.converted(to: .metersPerSecond).value,
                maxHumidity: day.maximumHumidity,
                condition: mapCondition(day.condition)
            )
        }
    }

    private enum WeatherEnricherError: Error {
        /// Empty forecasts are retryable failures, never terminal unknown weather.
        case noDailyData
        /// Quota exhaustion stops the loop without per-stay backoff; the stay itself did not fail.
        case budgetExhausted
    }

    // MARK: - Public

    /// Call UNGATED: plan/apply units own the non-reentrant PipelineGate.
    /// Apply free outcomes first, fetch between units, then apply each result in a short unit.
    /// Network waits must never hold the gate and starve SLC writes.
    func enrichStaysForTripGated(_ tripID: UUID, gate: PipelineGate = .shared) async {
        // Publish .stay only when the plan wrote, so opening an enriched trip rebuilds no Stats or Map.
        let pending: [StayWeatherRequest] = await gate.runReturning(touching: []) {
            let plan = await self.planTripEnrichment(tripID)
            if plan.applied > 0 { await StoreChangeTracker.shared.bump([.stay]) }
            return plan.pending
        }
        guard !pending.isEmpty else { return }

        var enriched = 0
        for request in pending {
            if Task.isCancelled { break }
            // UNGATED: the network round trip holds no lock and reads no model.
            guard let weather = await fetchWeatherForRequest(request) else { continue }
            let result = FetchedWeather(request: request, weather: weather)
            enriched += await gate.runReturning(touching: [.stay]) {
                await self.applyIfUnchanged([result])
            }
        }

        if enriched > 0 {
            logger.info("Enriched \(enriched) stay(s) with weather for trip \(tripID).")
        }
    }

    /// Unit-1 body: apply every free outcome and return a request witness for
    /// each physical row that still needs a WeatherKit round trip. Runs inside a
    /// gate unit, on a fresh context so no registered row predates another writer's save.
    private func planTripEnrichment(_ tripID: UUID) -> (pending: [StayWeatherRequest], applied: Int) {
        let context = ModelContext(modelContainer)
        let id = tripID
        let predicate = #Predicate<Trip> { $0.id == id }
        guard let trip = try? context.fetch(FetchDescriptor<Trip>(predicate: predicate)).first else {
            return ([], 0)
        }

        let stays = (trip.stays ?? []).sorted { $0.startTime < $1.startTime }
        var pending: [StayWeatherRequest] = []
        var applied = 0
        for stay in stays {
            guard shouldEnrich(stay) else { continue }

            if isPermanentlyUnavailable(stay) {
                markUnavailable(stay)
                applied += 1
                continue
            }
            if let cached = findCachedWeather(for: stay, in: context) {
                applyCachedWeather(cached, to: stay)
                applied += 1
                continue
            }
            pending.append(StayWeatherRequest(stay))
        }

        if applied > 0, !savePlan(context) {
            applied = 0
        }
        return (pending, applied)
    }

    /// The network step, deliberately OUTSIDE any gate unit. Fetches from the
    /// planned witness; the apply unit re-validates the row against it.
    private func fetchWeatherForRequest(_ request: StayWeatherRequest) async -> StayWeather? {
        do {
            // View-driven enrichment is deliberately unbudgeted, so it stays instant.
            let weather = try await fetchWeather(
                latitude: request.latitude,
                longitude: request.longitude,
                start: request.startTime,
                end: request.endTime,
                budgeted: false
            )
            failedFetchAt[request.id] = nil
            return weather
        } catch is CancellationError {
            // View cancellation is not failure: leave the stay immediately retryable.
            return nil
        } catch {
            // Back off failed requests across view opens and BG refreshes.
            failedFetchAt[request.id] = Date.now
            logger.error("WeatherKit enrichment failed for stay \(request.id): \(error.localizedDescription)")
            return nil
        }
    }

    /// Apply-unit body for every lane. Each aggregate lands only on the physical
    /// row it was requested for, and only while that row is live, still has no
    /// weather, and holds exactly the requested interval and centroid. A changed,
    /// deleted or replaced row drops its result without backoff, so the next pass
    /// replans from current geometry. A failed read or save rolls the batch back
    /// and applies nothing. Returns the count committed by a successful save.
    private func applyIfUnchanged(_ results: [FetchedWeather]) -> Int {
        let context = ModelContext(modelContainer)
        var applied = 0
        for result in results {
            let request = result.request
            let identifier = request.persistentID
            let fetched: Stay?
            do {
                fetched = try context.fetch(FetchDescriptor<Stay>(
                    predicate: #Predicate { $0.persistentModelID == identifier })).first
            } catch {
                logger.error("Weather apply read failed for stay \(request.id): \(error.localizedDescription)")
                context.rollback()
                return 0
            }
            guard let stay = fetched, !stay.isDeleted, request.matches(stay) else { continue }
            applyWeather(result.weather, to: stay)
            applied += 1
        }
        guard applied > 0 else { return 0 }
        do {
            #if DEBUG
            if failNextApplySaveForTesting {
                failNextApplySaveForTesting = false
                throw CocoaError(.fileWriteUnknown)
            }
            #endif
            try context.save()
            return applied
        } catch {
            logger.error("Weather apply save failed: \(error.localizedDescription)")
            context.rollback()
            return 0
        }
    }

    /// Commit a plan unit's free outcomes; a failed save rolls back and reports nothing applied.
    private func savePlan(_ context: ModelContext) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            logger.error("Weather plan save failed: \(error.localizedDescription)")
            context.rollback()
            return false
        }
    }

    #if DEBUG
    private var failNextApplySaveForTesting = false

    func setFailNextApplySaveForTesting(_ shouldFail: Bool) {
        failNextApplySaveForTesting = shouldFail
    }
    #endif

    /// Call UNGATED: plan and apply own separate units of the non-reentrant gate.
    /// Run WeatherKit between units so SLC writes never wait behind network I/O; apply validates each request witness.
    func enrichRecentStaysGated(limit: Int = 10, gate: PipelineGate = .shared) async {
        // Share the daily quota with opportunistic enrichment and PlannedTrip forecasts.
        // Consume per request/chunk; free cache and terminal work must run even after quota exhaustion.
        let plan = await gate.runReturning(touching: []) {
            let plan = await self.planRecentStays(limit: limit)
            if plan.appliedInPlan > 0 { await StoreChangeTracker.shared.bump([.stay]) }
            return plan
        }

        var results: [FetchedWeather] = []
        for entry in plan.networkCandidates {
            let request = entry.request
            guard Self.remainingDailyBudget() > 0 else { break }
            guard !Task.isCancelled, ProcessInfo.processInfo.thermalState != .critical else { break }
            do {
                let weather = try await fetchWeather(
                    latitude: request.latitude,
                    longitude: request.longitude,
                    start: request.startTime,
                    end: request.endTime
                )
                results.append(FetchedWeather(request: request, weather: weather))
                failedFetchAt[request.id] = nil
            } catch WeatherEnricherError.budgetExhausted {
                // Quota ran out mid-stay: not a per-stay failure, so no retry
                // backoff — the stay stays eligible once budget resets.
                break
            } catch is CancellationError {
                // Cancellation is not a service failure; do not delay the next retry with backoff.
                break
            } catch {
                failedFetchAt[request.id] = Date.now
                logger.error("WeatherKit enrichment failed for stay \(request.id): \(error.localizedDescription)")
            }
        }

        var applied = 0
        if !results.isEmpty {
            let toApply = results
            applied = await gate.runReturning(touching: [.stay]) { await self.applyIfUnchanged(toApply) }
        }

        let enriched = plan.appliedInPlan + applied
        if enriched > 0 {
            logger.info("Background-enriched \(enriched) stay(s) with weather.")
        }
    }

    /// Plan newest-first candidates of any category inside the gate, before network work.
    private func planRecentStays(limit: Int) async -> OpportunisticPlan {
        var plan = OpportunisticPlan()
        let context = ModelContext(modelContainer)
        let predicate = #Predicate<Stay> {
            $0.weatherConditionRaw == nil
        }
        var descriptor = FetchDescriptor<Stay>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        guard let stays = try? context.fetch(descriptor), !stays.isEmpty else {
            return plan
        }

        for stay in stays {
            guard !Task.isCancelled else { break }
            guard shouldEnrich(stay) else {
                if isPermanentlyUnavailable(stay) {
                    markUnavailable(stay)
                    plan.appliedInPlan += 1
                }
                continue
            }
            // Check permanent unavailability even after shouldEnrich passes; pre-floor stays must never spend quota.
            if isPermanentlyUnavailable(stay) {
                markUnavailable(stay)
                plan.appliedInPlan += 1
                continue
            }
            if let cached = findCachedWeather(for: stay, in: context) {
                applyCachedWeather(cached, to: stay)
                plan.appliedInPlan += 1
            } else {
                plan.networkCandidates.append(NetworkCandidate(
                    candidate: Self.candidateSnapshot(of: stay), request: StayWeatherRequest(stay)))
            }
        }

        if plan.appliedInPlan > 0, !savePlan(context) {
            plan.appliedInPlan = 0
        }
        return plan
    }

    /// Fill weather on activation in WeatherEnrichmentPlanner priority order, then by recency.
    /// Destination/transit candidates are eligible year-round; home/routine only in extreme months.
    /// Nov/Dec sprints target the current ungenerated Wrapped year and reserve forecast quota headroom.
    /// Only network requests spend budget; cached and terminal outcomes are free.
    /// The 20-request daily cap balances backlog progress against WeatherKit's monthly allowance, which is shared across all users.
    /// Call UNGATED: separate plan/apply units own the non-reentrant gate, with network work between them.
    /// Fetch trip and home/routine windows separately so ineligible home rows cannot evict older trip candidates.
    /// Home/routine candidates come from extreme-season windows so ineligible shoulder-month rows cannot evict older eligible ones.
    func enrichOpportunistically(gate: PipelineGate = .shared) async {
        // Set single-flight before any await so concurrent activations cannot plan the same stays and double-spend quota.
        guard !passInFlight else { return }
        passInFlight = true
        defer { passInFlight = false }

        // One instant for budget and token, so both read the same local day.
        let now = Date.now
        // Run free planning even with exhausted quota; the network loop independently enforces plannedBudget.
        let budget = Self.remainingDailyBudget(now: now)

        // Sprint only for the current ungenerated Wrapped year; reserve shared quota for PlannedTrip forecasts.
        let sprintYear = currentSprintYear()

        // Skip unchanged fruitless backlogs only within this local day; wall-clock eligibility and relaunch permit retries.
        let token = fruitlessPassToken(now: now, sprintYear: sprintYear)
        if token == lastFruitlessPassToken { return }

        let plannedBudget = sprintYear != nil ? min(budget, Self.sprintDailyCap) : budget
        // Size free-work candidates independently of remaining network budget.
        let planningWindow = max(plannedBudget, Self.exhaustedBudgetPlanningWindow)

        // Publish .stay only when cache or terminal outcomes were written, so fruitless plans rebuild nothing.
        let plan = await gate.runReturning(touching: []) {
            let plan = await self.planOpportunisticPass(budget: planningWindow, restrictToYear: sprintYear)
            if plan.appliedInPlan > 0 { await StoreChangeTracker.shared.bump([.stay]) }
            return plan
        }

        // Fetch ungated, reranking after each measurement so nearby candidates can gain priority within this pass.
        var results: [FetchedWeather] = []
        var attempted = 0
        var sprintConverged = false
        var interrupted = false
        var remaining = plan.networkCandidates
        // Grouped once, only when the loop can run; each new measurement rebuilds just its own year.
        var yearContexts = WeatherEnrichmentPlanner.YearContexts(
            plannedBudget > 0 && !remaining.isEmpty ? plan.measurements : [])
        while attempted < plannedBudget, !remaining.isEmpty {
            guard !Task.isCancelled, ProcessInfo.processInfo.thermalState != .critical else {
                interrupted = true
                break
            }
            guard let top = WeatherEnrichmentPlanner.nextCandidate(remaining.map(\.candidate), contexts: yearContexts)
            else { break }
            // Sprints stop at score zero to preserve forecast quota; ordinary passes still fill that tail by recency.
            if sprintYear != nil && top.score <= 0 {
                sprintConverged = true
                break
            }
            // Remove only this physical row: a UUID twin keeps its own request and witness.
            let entry = remaining.remove(at: top.sourceIndex)
            let candidate = entry.candidate
            let request = entry.request
            attempted += 1
            do {
                let weather = try await fetchWeather(
                    latitude: request.latitude,
                    longitude: request.longitude,
                    start: request.startTime,
                    end: request.endTime
                )
                results.append(FetchedWeather(request: request, weather: weather))
                // Only a pick still to come reads the contexts.
                if attempted < plannedBudget, !remaining.isEmpty {
                    yearContexts.append(WeatherEnrichmentPlanner.Measurement(
                        latitude: candidate.latitude,
                        longitude: candidate.longitude,
                        startTime: candidate.startTime,
                        endTime: candidate.endTime,
                        tripID: candidate.tripID,
                        avgTemperatureC: weather.temperatureAvgC
                    ))
                }
                failedFetchAt[candidate.id] = nil
            } catch WeatherEnricherError.budgetExhausted {
                // Mid-stay quota exhaustion creates neither backoff nor a fruitless latch; pending work retries next activation.
                break
            } catch is CancellationError {
                // Cancellation creates no backoff.
                interrupted = true
                break
            } catch {
                failedFetchAt[candidate.id] = Date.now
                logger.error("WeatherKit enrichment failed for stay \(candidate.id): \(error.localizedDescription)")
            }
        }

        var applied = 0
        if !results.isEmpty {
            let toApply = results
            applied = await gate.runReturning(touching: [.stay]) { await self.applyIfUnchanged(toApply) }
        }

        let enriched = plan.appliedInPlan + applied
        if enriched > 0 || attempted > 0 {
            logger.info("Opportunistic weather pass: \(enriched) stay(s) enriched, \(attempted) WeatherKit attempt(s) spent.")
        }
        // Latch only when no writes, attempts, or actionable candidates remain; thermal/cancelled work must retry.
        // A converged score-zero sprint may latch; changes to the nil-weather count invalidate it.
        let fruitless = enriched == 0 && attempted == 0 && !interrupted && !plan.interrupted
            && (plan.networkCandidates.isEmpty || sprintConverged)
        lastFruitlessPassToken = fruitless ? token : nil
    }

    /// Plan free outcomes under the gate and return ranked value snapshots.
    /// A pool up to 3× budget gives greedy reranking slack; requests remain budget-limited.
    private func planOpportunisticPass(budget: Int, restrictToYear: Int? = nil) async -> OpportunisticPlan {
        #if DEBUG
        planCountForTesting += 1
        #endif
        var plan = OpportunisticPlan()
        // A fresh context per unit: registered rows must not predate another writer's save.
        let context = ModelContext(modelContainer)

        // Sprint mode narrows both windows to the Wrapped year's stays.
        var yearStart = Date.distantPast
        var yearEnd = Date.distantFuture
        if let year = restrictToYear {
            yearStart = Self.utcCalendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? .distantPast
            yearEnd = Self.utcCalendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? .distantFuture
        }

        var tripDescriptor = FetchDescriptor<Stay>(
            predicate: #Predicate {
                $0.weatherConditionRaw == nil &&
                ($0.categoryRaw == "destination" || $0.categoryRaw == "transit") &&
                // Trip members only: the confidence gate keeps sub-θ errand
                // groups permanently tripless, and without this they'd consume
                // the shared WeatherKit budget year-round ahead of real trip
                // stays. Mirrored by
                // `YearWrappedGenerator.weatherExtremesSafe` — keep in sync.
                $0.trip != nil &&
                $0.startTime >= yearStart && $0.startTime < yearEnd
            },
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        )
        tripDescriptor.fetchLimit = 300
        // A failed candidate read plans as empty but must not latch.
        let tripStays: [Stay]
        do {
            tripStays = try context.fetch(tripDescriptor)
        } catch {
            plan.interrupted = true
            tripStays = []
        }

        // Fetch home/routine rows per extreme-season window, newest first, so
        // never-enriched shoulder-month rows cannot evict older eligible ones.
        var homeStays: [Stay] = []
        let newestYear = restrictToYear ?? Self.utcCalendar.component(.year, from: .now)
        let floorYear = Self.utcCalendar.component(.year, from: Self.weatherKitFloorDate)
        seasons: for year in stride(from: newestYear, through: floorYear, by: -1) {
            for (startYear, startMonth, endYear, endMonth) in [(year, 12, year + 1, 3), (year, 6, year, 9)] {
                guard let seasonStart = Self.utcCalendar.date(from: DateComponents(year: startYear, month: startMonth, day: 1)),
                      let seasonEnd = Self.utcCalendar.date(from: DateComponents(year: endYear, month: endMonth, day: 1))
                else { continue }
                let lower = max(seasonStart, yearStart)
                let upper = min(seasonEnd, yearEnd)
                guard lower < upper else { continue }
                var seasonDescriptor = FetchDescriptor<Stay>(
                    predicate: #Predicate {
                        $0.weatherConditionRaw == nil &&
                        ($0.categoryRaw == "home" || $0.categoryRaw == "routine") &&
                        $0.startTime >= lower && $0.startTime < upper
                    },
                    sortBy: [SortDescriptor(\.endTime, order: .reverse)]
                )
                seasonDescriptor.fetchLimit = 500 - homeStays.count
                do {
                    homeStays += try context.fetch(seasonDescriptor)
                } catch {
                    plan.interrupted = true
                }
                if homeStays.count >= 500 { break seasons }
            }
        }

        // Planner owns UTC extreme-month eligibility shared with Wrapped’s extremes-safe gate.
        let homeExtremes = homeStays.filter {
            WeatherEnrichmentPlanner.extremeHomeMonths
                .contains(WeatherEnrichmentPlanner.monthUTC(of: $0.startTime))
        }

        // Mark pre-floor home/routine stays terminal in every month so they cannot clog the nil-weather backlog.
        let floorDate = Self.weatherKitFloorDate
        var preFloorDescriptor = FetchDescriptor<Stay>(
            predicate: #Predicate {
                $0.weatherConditionRaw == nil &&
                ($0.categoryRaw == "home" || $0.categoryRaw == "routine") &&
                $0.endTime < floorDate &&
                $0.startTime >= yearStart && $0.startTime < yearEnd
            }
        )
        preFloorDescriptor.fetchLimit = 500
        let preFloorStays: [Stay]
        do {
            preFloorStays = try context.fetch(preFloorDescriptor)
        } catch {
            plan.interrupted = true
            preFloorStays = []
        }
        for stay in preFloorStays {
            markUnavailable(stay)
            plan.appliedInPlan += 1
        }

        // Measured context for ranking: every stay with a temperature in the
        // candidate years. Bounded by the candidate windows' year span, and
        // scanned only for scalar fields — this is what lets the planner
        // know the current records and their neighborhoods.
        let eligible = (tripStays + homeExtremes).filter { $0.weatherConditionRaw == nil && shouldEnrich($0) }
        plan.measurements = fetchMeasurements(coveringYearsOf: eligible, in: context)

        let snapshots = eligible.map { Self.candidateSnapshot(of: $0) }
        let rankedCandidates = WeatherEnrichmentPlanner.rankedQueue(
            snapshots,
            measurements: plan.measurements
        )

        // Apply ranked cache hits free; misses fill the network pool.
        let poolLimit = budget * 3
        for ranked in rankedCandidates {
            guard plan.networkCandidates.count < poolLimit else { break }
            guard !Task.isCancelled, ProcessInfo.processInfo.thermalState != .critical else {
                plan.interrupted = true
                break
            }
            // The carried index pairs this value with its physical row, even for identical UUID twins.
            let stay = eligible[ranked.sourceIndex]
            let candidate = ranked.candidate
            // The terminal-mark sweeps above never touch `eligible` rows
            // (shouldEnrich already excluded them), so no re-check needed —
            // but the pre-floor path still applies to walked trip stays.
            if isPermanentlyUnavailable(stay) {
                markUnavailable(stay)
                plan.appliedInPlan += 1
                continue
            }
            if let cached = findCachedWeather(for: stay, in: context) {
                applyCachedWeather(cached, to: stay)
                plan.appliedInPlan += 1
                // A cache hit is a measurement too — let it steer the
                // network phase's greedy re-rank.
                if let temp = stay.avgTemperatureC {
                    plan.measurements.append(WeatherEnrichmentPlanner.Measurement(
                        latitude: stay.centroidLatitude,
                        longitude: stay.centroidLongitude,
                        startTime: stay.startTime,
                        endTime: stay.endTime,
                        tripID: stay.trip?.id,
                        avgTemperatureC: temp
                    ))
                }
            } else {
                plan.networkCandidates.append(NetworkCandidate(
                    candidate: candidate, request: StayWeatherRequest(stay)))
            }
        }

        if plan.appliedInPlan > 0, !savePlan(context) {
            // The free outcomes rolled back; nothing was written, and the pass must not latch.
            plan.appliedInPlan = 0
            plan.interrupted = true
        }
        return plan
    }

    /// Cap sprint spending to leave shared daily budget for PlannedTrip forecasts.
    nonisolated static let sprintDailyCap = 15

    /// The Wrapped lead-up year, when a sprint should target it: it is
    /// November or December (device-local — matching the December auto-gen
    /// trigger in AppDelegate) and no YearWrapped row exists yet for the
    /// current year. Once generation lands the row, sprints stop.
    func currentSprintYear(now: Date = .now, calendar: Calendar = .current) -> Int? {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        guard gregorian.component(.month, from: now) >= 11 else { return nil }
        let year = gregorian.component(.year, from: now)
        let y = year
        let count = (try? modelContext.fetchCount(
            FetchDescriptor<YearWrapped>(predicate: #Predicate { $0.year == y })
        )) ?? 0
        return count == 0 ? year : nil
    }

    /// All measured temperatures within the UTC-year span of `stays` —
    /// the ranking context (current records + their neighborhoods).
    private func fetchMeasurements(
        coveringYearsOf stays: [Stay], in context: ModelContext
    ) -> [WeatherEnrichmentPlanner.Measurement] {
        guard !stays.isEmpty else { return [] }
        let years = stays.map { WeatherEnrichmentPlanner.yearUTC(of: $0.startTime) }
        guard let minYear = years.min(), let maxYear = years.max(),
              let windowStart = Self.utcCalendar.date(from: DateComponents(year: minYear, month: 1, day: 1)),
              let windowEnd = Self.utcCalendar.date(from: DateComponents(year: maxYear + 1, month: 1, day: 1))
        else { return [] }
        let descriptor = FetchDescriptor<Stay>(
            predicate: #Predicate {
                $0.avgTemperatureC != nil &&
                $0.startTime >= windowStart && $0.startTime < windowEnd
            }
        )
        let measured = (try? context.fetch(descriptor)) ?? []
        return measured.compactMap { stay in
            guard let temp = stay.avgTemperatureC else { return nil }
            return WeatherEnrichmentPlanner.Measurement(
                latitude: stay.centroidLatitude,
                longitude: stay.centroidLongitude,
                startTime: stay.startTime,
                endTime: stay.endTime,
                tripID: stay.trip?.id,
                avgTemperatureC: temp
            )
        }
    }

    /// Value snapshot of a stay for the planner (crosses the gate boundary).
    private nonisolated static func candidateSnapshot(of stay: Stay) -> WeatherEnrichmentPlanner.Candidate {
        WeatherEnrichmentPlanner.Candidate(
            id: stay.id,
            latitude: stay.centroidLatitude,
            longitude: stay.centroidLongitude,
            startTime: stay.startTime,
            endTime: stay.endTime,
            tripID: stay.trip?.id,
            isTripStay: stay.category == .destination || stay.category == .transit
        )
    }

    private struct OpportunisticPlan: Sendable {
        var appliedInPlan = 0
        /// Ranked (highest planner priority first); crosses the gate
        /// boundary, so value snapshots and request witnesses only.
        var networkCandidates: [NetworkCandidate] = []
        /// Measured context the network phase's greedy re-rank starts from.
        var measurements: [WeatherEnrichmentPlanner.Measurement] = []
        /// Cancellation, thermal pressure or a failed candidate read cut the plan short; the pass must not latch.
        var interrupted = false
    }

    /// The physical row and exact geometry one WeatherKit request was built
    /// from. Results cross the ungated network step only with this witness and
    /// apply only while the row still matches it.
    nonisolated fileprivate struct StayWeatherRequest: Sendable {
        let persistentID: PersistentIdentifier
        let id: UUID
        let latitude: Double
        let longitude: Double
        let startTime: Date
        let endTime: Date

        init(_ stay: Stay) {
            persistentID = stay.persistentModelID
            id = stay.id
            latitude = stay.centroidLatitude
            longitude = stay.centroidLongitude
            startTime = stay.startTime
            endTime = stay.endTime
        }

        /// Exact equality, stricter than `WeatherValidityKey`: an aggregate
        /// never lands on geometry other than the one it was fetched for.
        func matches(_ stay: Stay) -> Bool {
            stay.id == id && stay.weatherConditionRaw == nil
                && stay.startTime == startTime && stay.endTime == endTime
                && stay.centroidLatitude == latitude && stay.centroidLongitude == longitude
        }
    }

    /// A ranked planner value paired with the request witness of the physical row it came from.
    nonisolated fileprivate struct NetworkCandidate: Sendable {
        let candidate: WeatherEnrichmentPlanner.Candidate
        let request: StayWeatherRequest
    }

    nonisolated fileprivate struct FetchedWeather: Sendable {
        let request: StayWeatherRequest
        let weather: StayWeather
    }

    /// See the single-flight guard at the top of `enrichOpportunistically`.
    private var passInFlight = false
    #if DEBUG
    private(set) var planCountForTesting = 0
    #endif

    /// Signature of the opportunistic backlog: local calendar day +
    /// nil-weather row count + newest nil-weather endTime + settled
    /// nil-weather count + nil-weather trip stay count + total stay count +
    /// active backoffs + sprint year. Five cheap queries (4 COUNT + LIMIT-1).
    private var lastFruitlessPassToken: String?

    private func fruitlessPassToken(now: Date, sprintYear: Int?) -> String {
        let context = ModelContext(modelContainer)
        let predicate = #Predicate<Stay> { $0.weatherConditionRaw == nil }
        let count = (try? context.fetchCount(FetchDescriptor<Stay>(predicate: predicate))) ?? -1
        var newestDescriptor = FetchDescriptor<Stay>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.endTime, order: .reverse)]
        )
        newestDescriptor.fetchLimit = 1
        newestDescriptor.propertiesToFetch = [\.endTime]
        let newest = (try? context.fetch(newestDescriptor))?.first?.endTime.timeIntervalSinceReferenceDate ?? 0
        // Stays crossing the settle threshold and expiring backoffs become candidates without changing the counts above.
        let settledCutoff = now.addingTimeInterval(-Self.settledThresholdSeconds)
        let settledPredicate = #Predicate<Stay> { $0.weatherConditionRaw == nil && $0.endTime <= settledCutoff }
        let settled = (try? context.fetchCount(FetchDescriptor<Stay>(predicate: settledPredicate))) ?? -1
        // Reclassification moves stays into or out of the trip candidate set without changing the counts above.
        let tripPredicate = #Predicate<Stay> {
            $0.weatherConditionRaw == nil && $0.trip != nil &&
            ($0.categoryRaw == "destination" || $0.categoryRaw == "transit")
        }
        let tripCount = (try? context.fetchCount(FetchDescriptor<Stay>(predicate: tripPredicate))) ?? -1
        // A weathered sibling synced in makes a free cache hit possible without changing the nil-weather rows.
        let total = (try? context.fetchCount(FetchDescriptor<Stay>())) ?? -1
        let backoffs = failedFetchAt.values.filter { now.timeIntervalSince($0) < Self.retryBackoffSeconds }.count
        let day = ISO8601DateFormatter.string(
            from: now, timeZone: .current,
            formatOptions: [.withFullDate]
        )
        return "\(day)|\(count)|\(newest)|\(settled)|\(tripCount)|\(total)|\(backoffs)|\(sprintYear ?? 0)"
    }

    #if DEBUG
    func fruitlessPassTokenForTesting(now: Date) -> String {
        fruitlessPassToken(now: now, sprintYear: nil)
    }
    #endif

    // MARK: - Opportunistic budget

    /// Max WeatherKit attempts the opportunistic pass may spend per
    /// calendar day. View-driven enrichment (opening a trip) is NOT
    /// budgeted — it stays instant.
    nonisolated static let opportunisticDailyLimit = 20

    // Internal budget keys let tests save and restore shared quota state.
    nonisolated static let budgetDayKey = "weatherOpportunisticBudgetDay"
    nonisolated static let budgetUsedKey = "weatherOpportunisticBudgetUsed"

    /// Lock shared budget read-modify-write across WeatherEnricher and CalendarEnricher actors.
    /// The check/consume window across awaits still permits bounded soft-budget overshoot.
    private nonisolated static let budgetLock = NSLock()

    nonisolated static func remainingDailyBudget(now: Date = .now) -> Int {
        budgetLock.lock()
        defer { budgetLock.unlock() }
        let today = ISO8601DateFormatter.string(
            from: now, timeZone: .current,
            formatOptions: [.withFullDate]
        )
        let defaults = UserDefaults.standard
        if defaults.string(forKey: budgetDayKey) != today {
            return opportunisticDailyLimit
        }
        return max(0, opportunisticDailyLimit - defaults.integer(forKey: budgetUsedKey))
    }

    nonisolated static func consumeDailyBudget(_ used: Int, now: Date = .now) {
        budgetLock.lock()
        defer { budgetLock.unlock() }
        let today = ISO8601DateFormatter.string(
            from: now, timeZone: .current,
            formatOptions: [.withFullDate]
        )
        let defaults = UserDefaults.standard
        if defaults.string(forKey: budgetDayKey) != today {
            defaults.set(today, forKey: budgetDayKey)
            defaults.set(used, forKey: budgetUsedKey)
        } else {
            defaults.set(defaults.integer(forKey: budgetUsedKey) + used, forKey: budgetUsedKey)
        }
    }

    // MARK: - Core

    // MARK: - Eligibility

    private func shouldEnrich(_ stay: Stay) -> Bool {
        guard stay.weatherConditionRaw == nil else { return false }
        guard Date.now.timeIntervalSince(stay.endTime) >= Self.settledThresholdSeconds else {
            return false
        }
        // Respect the retry backoff for a recently-failed fetch so a
        // persistent failure isn't retried on every view open / BG refresh.
        if let lastFailure = failedFetchAt[stay.id],
           Date.now.timeIntervalSince(lastFailure) < Self.retryBackoffSeconds {
            return false
        }
        return true
    }

    nonisolated func isPermanentlyUnavailable(_ stay: Stay) -> Bool {
        stay.endTime < Self.weatherKitFloorDate
    }

    private func markUnavailable(_ stay: Stay) {
        stay.weatherConditionRaw = StayWeather.Condition.unavailable.rawValue
        stay.dayKey = computeDayKey(for: stay.startTime)
    }

    // MARK: - Cache

    /// Number of UTC days a stay's weather aggregate covers. `StayWeather`
    /// sums precipitation and takes extrema over the WHOLE fetched window, so
    /// two stays may share an aggregate only if they cover the same span.
    nonisolated static func weatherDaySpan(start: Date, end: Date) -> Int {
        let cal = Self.utcCalendar
        let from = cal.startOfDay(for: start)
        let to = cal.startOfDay(for: max(end, start))
        let days = cal.dateComponents([.day], from: from, to: to).day ?? 0
        return max(1, days + 1)
    }

    /// Weather validity key: the equivalence under which the cache shares an
    /// aggregate (res-6 cell, UTC start day, UTC day span). Every Stay geometry
    /// writer captures it before mutating and calls `clearWeatherIfKeyChanged`.
    nonisolated struct WeatherValidityKey: Equatable, Sendable {
        let hex: String
        let dayKey: Date
        let daySpan: Int

        init(_ stay: Stay) {
            hex = stay.h3IndexRes6
            dayKey = WeatherEnricher.computeDayKey(for: stay.startTime)
            daySpan = WeatherEnricher.weatherDaySpan(start: stay.startTime, end: stay.endTime)
        }
    }

    /// Clears every weather field, terminal `.unavailable` included, once the
    /// stay's key moved away from `before`, so the planner fetches for the new
    /// geometry. Writes nothing when the key holds or no field is set. Runs in
    /// the writer's own transaction: no save, no gate.
    nonisolated static func clearWeatherIfKeyChanged(_ stay: Stay, from before: WeatherValidityKey) {
        guard WeatherValidityKey(stay) != before else { return }
        guard stay.weatherData != nil || stay.avgTemperatureC != nil
                || stay.weatherConditionRaw != nil || stay.precipitationMm != nil
                || stay.dayKey != nil else { return }
        stay.weatherData = nil
        stay.avgTemperatureC = nil
        stay.weatherConditionRaw = nil
        stay.precipitationMm = nil
        stay.dayKey = nil
    }

    /// A source must share the target's whole validity key, judged from its
    /// current geometry: precipitation is summed and temperatures aggregate over the full window.
    private func findCachedWeather(for stay: Stay, in context: ModelContext) -> Stay? {
        let key = WeatherValidityKey(stay)
        let hex = key.hex
        guard !hex.isEmpty else { return nil }
        let day = key.dayKey
        let excludeID = stay.id
        let predicate = #Predicate<Stay> {
            $0.h3IndexRes6 == hex &&
            $0.dayKey == day &&
            $0.weatherData != nil &&
            $0.id != excludeID
        }
        var descriptor = FetchDescriptor<Stay>(predicate: predicate)
        // Small window then filter in memory: the span comparison cannot be
        // expressed in a SwiftData predicate.
        descriptor.fetchLimit = 8
        guard let candidates = try? context.fetch(descriptor) else { return nil }
        return candidates.first { WeatherValidityKey($0) == key }
    }

    private func applyCachedWeather(_ source: Stay, to target: Stay) {
        target.weatherData = source.weatherData
        target.avgTemperatureC = source.avgTemperatureC
        target.weatherConditionRaw = source.weatherConditionRaw
        target.precipitationMm = source.precipitationMm
        target.dayKey = Self.computeDayKey(for: target.startTime)
        if var decoded = target.weather {
            decoded.isCacheHit = true
            target.weather = decoded
        }
    }

    // MARK: - WeatherKit

    /// Coordinate-based core so the opportunistic pass can fetch from value
    /// snapshots outside the gate (no `@Model` access on the network path).
    ///
    /// Consume one budget unit BEFORE each request/chunk; budgeted false preserves unbudgeted view enrichment.
    private func fetchWeather(
        latitude: Double,
        longitude: Double,
        start: Date,
        end stayEnd: Date,
        budgeted: Bool = true
    ) async throws -> StayWeather {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let end = max(stayEnd, start.addingTimeInterval(86400))

        func consumeOneRequest() throws {
            guard budgeted else { return }
            guard Self.remainingDailyBudget() > 0 else {
                throw WeatherEnricherError.budgetExhausted
            }
            Self.consumeDailyBudget(1)
        }

        let dayCount = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 1
        var allDays: [DailyWeatherSample] = []

        if dayCount <= Self.maxDaysPerRequest {
            try consumeOneRequest()
            allDays = try await fetchDaily(location: location, start: start, end: end)
        } else {
            // Chunk stepping assumes half-open [start, end) WeatherKit ranges.
            // Verify daily counts for a >10-day stay on device before changing this: inclusive stepping could omit days.
            // If inclusivity is confirmed, use maxDaysPerRequest - 1 spans and advance one calendar day past the end.
            // Corrected stepping must use calendar days in the stay’s zone, not DST-naive fixed seconds.
            var chunkStart = start
            while chunkStart < end {
                let chunkEnd = min(
                    chunkStart.addingTimeInterval(TimeInterval(Self.maxDaysPerRequest) * 86400),
                    end
                )
                try consumeOneRequest()
                let chunk = try await fetchDaily(location: location, start: chunkStart, end: chunkEnd)
                guard !chunk.isEmpty else { throw WeatherEnricherError.noDailyData }
                allDays.append(contentsOf: chunk)
                chunkStart = chunkEnd
                // Never persist partial multi-chunk weather: non-nil weather blocks future enrichment, so throw and leave it retryable.
                if Task.isCancelled && chunkStart < end {
                    throw CancellationError()
                }
            }
        }

        guard !allDays.isEmpty else {
            // Empty daily data is retryable; terminal unknown would permanently block enrichment.
            throw WeatherEnricherError.noDailyData
        }

        return aggregate(allDays)
    }

    private func aggregate(_ days: [DailyWeatherSample]) -> StayWeather {
        let minC = days.map(\.lowC).min() ?? 0
        let maxC = days.map(\.highC).max() ?? 0
        let avgC = days.map { ($0.highC + $0.lowC) / 2.0 }.reduce(0, +) / Double(days.count)

        let totalPrecipMm = days.map(\.precipitationMm).reduce(0, +)

        let avgWindMs = days.map(\.windSpeedMs).reduce(0, +) / max(1, Double(days.count))

        let avgHumidity = days.map(\.maxHumidity).reduce(0, +) / Double(days.count)

        let conditionCounts = Dictionary(grouping: days, by: { $0.condition })
        // Break condition-count ties by the smallest raw value so dictionary order cannot change results.
        let dominantCondition = conditionCounts
            .max(by: {
                if $0.value.count != $1.value.count { return $0.value.count < $1.value.count }
                return $0.key.rawValue > $1.key.rawValue
            })?
            .key ?? .unknown

        return StayWeather(
            condition: dominantCondition,
            temperatureMinC: minC,
            temperatureMaxC: maxC,
            temperatureAvgC: avgC,
            precipitationMm: totalPrecipMm,
            windSpeedMs: avgWindMs,
            humidity: avgHumidity
        )
    }

    private func applyWeather(_ weather: StayWeather, to stay: Stay) {
        stay.weather = weather
        stay.avgTemperatureC = weather.temperatureAvgC
        stay.weatherConditionRaw = weather.condition.rawValue
        stay.precipitationMm = weather.precipitationMm
        stay.dayKey = Self.computeDayKey(for: stay.startTime)
    }

    // MARK: - Condition Mapping

    nonisolated func mapCondition(_ wc: WeatherCondition) -> StayWeather.Condition {
        switch wc {
        case .clear, .mostlyClear:
            return .clear
        case .partlyCloudy:
            return .partlyCloudy
        case .cloudy, .mostlyCloudy:
            return .cloudy
        case .drizzle, .freezingDrizzle:
            return .drizzle
        case .rain, .freezingRain, .sunShowers:
            return .rain
        case .heavyRain:
            return .heavyRain
        case .snow, .heavySnow, .flurries, .sunFlurries, .blowingSnow, .blizzard:
            return .snow
        case .sleet, .wintryMix:
            return .sleet
        case .thunderstorms, .scatteredThunderstorms, .isolatedThunderstorms,
             .strongStorms, .hail, .hurricane, .tropicalStorm:
            return .thunderstorms
        case .foggy:
            return .fog
        case .haze, .smoky, .blowingDust:
            return .haze
        case .windy, .breezy:
            return .windy
        case .hot:
            return .hot
        case .frigid:
            return .cold
        @unknown default:
            return .unknown
        }
    }

    // MARK: - Helpers

    /// Canonical cache-key day is UTC midnight; external dayKey writers must share this static helper.
    nonisolated static func computeDayKey(for date: Date) -> Date {
        Self.utcCalendar.startOfDay(for: date)
    }

    nonisolated func computeDayKey(for date: Date) -> Date {
        Self.computeDayKey(for: date)
    }
}
