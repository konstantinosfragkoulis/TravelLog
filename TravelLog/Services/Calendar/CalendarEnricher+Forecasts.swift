//
//  CalendarEnricher+Forecasts.swift
//  TravelLog
//

@preconcurrency import EventKit
import Foundation
import CryptoKit
import SwiftData
import CoreLocation
import WeatherKit
import WidgetKit
import os.log

extension CalendarEnricher {

    // MARK: - Forecast for imminent planned trips

    /// Forecasts refresh once per this interval while a trip is imminent.
    private static let forecastRefreshSeconds: TimeInterval = 20 * 60 * 60

    /// WeatherKit daily forecasts reach ~10 days out. Derived from
    /// `WeatherEnricher.maxDaysPerRequest`: the forecast lane consumes ONE
    /// budget unit per fetch, which is honest only while a single WeatherKit
    /// request covers the whole horizon. Deriving makes the coupling structural
    /// instead of a coincidence of two literals.
    private static let forecastHorizonSeconds: TimeInterval =
        TimeInterval(WeatherEnricher.maxDaysPerRequest) * 24 * 60 * 60

    /// At most this many rows get a forecast call per scan (overlapping
    /// planned trips are rare; this is belt-and-braces on top of the shared
    /// daily WeatherKit budget).
    private static let forecastRowsPerScan = 3

    /// Fetches WeatherKit daily forecasts for upcoming, resolved planned
    /// trips starting within the ~10-day horizon. Draws on the SAME daily
    /// budget as `WeatherEnricher`'s opportunistic fill so calendar work can
    /// never blow the shared WeatherKit tier. Network runs OUTSIDE the gate;
    /// each result is applied in its own small gate unit.
    struct ForecastRequest: Sendable {
        let id: UUID
        let identifier: PersistentIdentifier
        let latitude: Double
        let longitude: Double
        let startDate: Date
        let endDate: Date
    }

    func refreshForecastsIfNeeded(
        now: Date, expectedEpoch: UInt64
    ) async {
        guard expectedEpoch == calendarDataEpoch else { return }
        let horizon = now.addingTimeInterval(Self.forecastHorizonSeconds)
        let upcomingRaw = PlannedTripStatus.upcoming.rawValue
        let predicate = #Predicate<PlannedTrip> {
            $0.statusRaw == upcomingRaw && $0.resolvedLatitude != nil
        }
        guard let rows = try? modelContext.fetch(FetchDescriptor<PlannedTrip>(predicate: predicate)) else { return }

        let candidates = rows
            .filter { $0.startDate <= horizon && $0.endDate >= now }
            .filter { row in
                guard let forecast = row.forecast else { return true }
                return now.timeIntervalSince(forecast.fetchedAt) > Self.forecastRefreshSeconds
            }
            .filter { row in
                // Failure backoff: the attempt below burns
                // shared daily budget whether or not WeatherKit answers, so a
                // persistently failing row (offline, no data for the window)
                // must not re-burn it on every scan. Same rationale as
                // `WeatherEnricher.failedFetchAt`.
                guard let failedAt = failedForecastAt[row.id] else { return true }
                return now.timeIntervalSince(failedAt) >= Self.forecastRetryBackoffSeconds
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(Self.forecastRowsPerScan)
        guard !candidates.isEmpty else { return }

        // Value snapshots — nothing below touches a @Model row after an
        // await: a gated unit can delete/rewrite the row while the WeatherKit
        // call runs, and reading `row.id` afterwards faults a tombstone.
        let snapshots = candidates.compactMap { row -> ForecastRequest? in
            guard let latitude = row.resolvedLatitude, let longitude = row.resolvedLongitude else { return nil }
            return ForecastRequest(id: row.id, identifier: row.persistentModelID,
                latitude: latitude, longitude: longitude, startDate: row.startDate, endDate: row.endDate)
        }

        for candidate in snapshots {
            guard expectedEpoch == calendarDataEpoch else { return }
            guard WeatherEnricher.remainingDailyBudget() > 0 else { break }
            let windowStart = max(now, candidate.startDate)
            let windowEnd = min(candidate.endDate, now.addingTimeInterval(Self.forecastHorizonSeconds))
            guard windowStart < windowEnd else { continue }

            WeatherEnricher.consumeDailyBudget(1)
            guard let forecast = await fetchDailyForecast(
                latitude: candidate.latitude, longitude: candidate.longitude,
                start: windowStart, end: windowEnd, now: now
            ) else {
                if expectedEpoch == calendarDataEpoch {
                    failedForecastAt[candidate.id] = Date.now
                }
                continue
            }
            guard expectedEpoch == calendarDataEpoch else { return }
            failedForecastAt[candidate.id] = nil

            await PipelineGate.shared.run(touching: [.plannedTrip]) { [weak self] in
                await self?.applyForecast(forecast, request: candidate, expectedEpoch: expectedEpoch)
            }
        }
    }

    private static let forecastRetryBackoffSeconds: TimeInterval = 60 * 60

    private func fetchDailyForecast(
        latitude: Double, longitude: Double, start: Date, end: Date, now: Date
    ) async -> PlannedTripForecast? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            let daily = try await WeatherService.shared.weather(
                for: location, including: .daily(startDate: start, endDate: end)
            )
            guard !daily.forecast.isEmpty else { return nil }
            let days = daily.forecast.map { day in
                PlannedTripForecast.Day(
                    date: day.date,
                    conditionRaw: AppDelegate.weatherEnricher.mapCondition(day.condition).rawValue,
                    minTemperatureC: day.lowTemperature.converted(to: .celsius).value,
                    maxTemperatureC: day.highTemperature.converted(to: .celsius).value,
                    precipitationMm: day.precipitationAmountByType.precipitation.converted(to: .millimeters).value
                )
            }
            return PlannedTripForecast(fetchedAt: now, days: days)
        } catch {
            logger.debug("Planned-trip forecast fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func applyForecast(
        _ forecast: PlannedTripForecast,
        request: ForecastRequest,
        expectedEpoch: UInt64
    ) {
        guard expectedEpoch == calendarDataEpoch else { return }
        let identifier = request.identifier
        let predicate = #Predicate<PlannedTrip> { $0.persistentModelID == identifier }
        guard let row = try? modelContext.fetch(FetchDescriptor<PlannedTrip>(predicate: predicate)).first,
              !row.isDeleted, row.id == request.id, row.status == .upcoming,
              row.resolvedLatitude == request.latitude, row.resolvedLongitude == request.longitude,
              row.startDate == request.startDate, row.endDate == request.endDate else { return }
        row.forecast = forecast
        scanCycleMadeChanges = true
        try? modelContext.save()
    }

    #if DEBUG
    func applyForecastForTesting(_ forecast: PlannedTripForecast, request: ForecastRequest, epoch: UInt64) {
        applyForecast(forecast, request: request, expectedEpoch: epoch)
    }
    #endif
}
