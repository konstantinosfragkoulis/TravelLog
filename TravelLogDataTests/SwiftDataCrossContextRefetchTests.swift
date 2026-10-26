//
//  SwiftDataCrossContextRefetchTests.swift
//  TravelLogTests
//
//  Pins a SwiftData behaviour weather invalidation relies on: a
//  long-lived `@ModelActor` context (the app keeps one `StayClusterer` for
//  the whole process) that already has a Stay registered sees the values
//  another `ModelContext` saved to that row as soon as it FETCHES the row
//  again. The clusterer only clears weather it can see, so if a platform
//  release starts serving the registered row's stale snapshot on refetch,
//  weather the enricher saved for the old geometry survives a boundary move.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

/// A stand-in for any long-lived app `@ModelActor`: it registers a Stay once
/// and keeps it, then refetches with the shapes the app's actors use.
@ModelActor
actor CrossContextStayReader {
    private var held: Stay?

    nonisolated enum FetchShape: String, Sendable, CaseIterable, CustomTestStringConvertible {
        /// A plain predicate fetch by id.
        case plain
        /// The clusterer's anchor read: newest by end time, fetchLimit 1.
        case newestByEndLimitOne
        /// A plain fetch while an unrelated insert is pending in this context.
        case withPendingUnrelatedInsert

        var testDescription: String { rawValue }
    }

    nonisolated struct WeatherSnapshot: Sendable, Equatable {
        let avgTemperatureC: Double?
        let conditionRaw: String?
        let hasWeatherData: Bool
    }

    /// Fetches and keeps the row, materialising its weather fields.
    func register(_ id: UUID) throws -> WeatherSnapshot? {
        held = try modelContext.fetch(FetchDescriptor<Stay>(predicate: #Predicate { $0.id == id })).first
        return held.map(Self.snapshot)
    }

    func refetch(_ id: UUID, shape: FetchShape) throws -> WeatherSnapshot? {
        switch shape {
        case .plain:
            return try modelContext.fetch(FetchDescriptor<Stay>(
                predicate: #Predicate { $0.id == id })).first.map(Self.snapshot)
        case .newestByEndLimitOne:
            var descriptor = FetchDescriptor<Stay>(sortBy: [SortDescriptor(\.endTime, order: .reverse)])
            descriptor.fetchLimit = 1
            return try modelContext.fetch(descriptor).first.map(Self.snapshot)
        case .withPendingUnrelatedInsert:
            modelContext.insert(LocationPing(
                timestamp: .distantPast, latitude: 0, longitude: 0,
                horizontalAccuracy: 5, h3IndexRes6: ""))
            let snapshot = try modelContext.fetch(FetchDescriptor<Stay>(
                predicate: #Predicate { $0.id == id })).first.map(Self.snapshot)
            #expect(modelContext.hasChanges, "the unrelated insert must still be pending during the fetch")
            modelContext.rollback()
            return snapshot
        }
    }

    private static func snapshot(_ stay: Stay) -> WeatherSnapshot {
        WeatherSnapshot(
            avgTemperatureC: stay.avgTemperatureC,
            conditionRaw: stay.weatherConditionRaw,
            hasWeatherData: stay.weatherData != nil)
    }
}

@MainActor
@Suite("SwiftData platform assumption: long-lived context refetch sees other contexts' saves")
struct SwiftDataCrossContextRefetchTests {

    /// A UTC instant on June `day`, 2025.
    private func utc(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        WeatherEnricher.utcCalendar.date(from: DateComponents(
            year: 2025, month: 6, day: day, hour: hour, minute: minute, second: second))!
    }

    private static let lat = 0.0
    private static let lon = -140.0
    private var cell: String { H3Service.cellIndex(latitude: Self.lat, longitude: Self.lon) ?? "" }

    private func insertStay(_ context: ModelContext, start: Date, end: Date) -> Stay {
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: Self.lat, centroidLongitude: Self.lon,
            h3IndexRes6: cell, pingCount: 0,
            distanceFromHomeKm: .greatestFiniteMagnitude, pingIDs: [])
        context.insert(stay)
        return stay
    }

    private func insertPing(_ context: ModelContext, at timestamp: Date) {
        let ping = LocationPing(
            timestamp: timestamp, latitude: Self.lat, longitude: Self.lon,
            horizontalAccuracy: 5, h3IndexRes6: cell)
        ping.isProcessed = false
        context.insert(ping)
    }

    /// Saves weather through its own short-lived context, as the enricher does.
    private func saveWeather(for id: UUID, in container: ModelContainer) throws {
        let context = ModelContext(container)
        let stay = try #require(try context.fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == id })).first)
        stay.weather = StayWeather(
            condition: .clear, temperatureMinC: 18, temperatureMaxC: 28,
            temperatureAvgC: 23, precipitationMm: 0, windSpeedMs: 3, humidity: 0.5)
        stay.avgTemperatureC = 23
        stay.weatherConditionRaw = StayWeather.Condition.clear.rawValue
        stay.precipitationMm = 0
        stay.dayKey = WeatherEnricher.computeDayKey(for: stay.startTime)
        try context.save()
    }

    private func fresh(_ id: UUID, in container: ModelContainer) throws -> Stay {
        try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == id })).first)
    }

    @Test("a long-lived @ModelActor context that holds a registered Stay sees another context's saved weather when it refetches the row",
          arguments: CrossContextStayReader.FetchShape.allCases)
    func longLivedActorRefetchSeesOtherContextSave(shape: CrossContextStayReader.FetchShape) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let stay = insertStay(context, start: utc(15, 20), end: utc(15, 22))
        let id = stay.id
        try context.save()

        let reader = CrossContextStayReader(modelContainer: container)
        let registered = try #require(try await reader.register(id))
        #expect(registered == CrossContextStayReader.WeatherSnapshot(avgTemperatureC: nil, conditionRaw: nil, hasWeatherData: false))

        try saveWeather(for: id, in: container)

        let refetched = try #require(try await reader.refetch(id, shape: shape))
        #expect(refetched == CrossContextStayReader.WeatherSnapshot(
            avgTemperatureC: 23, conditionRaw: StayWeather.Condition.clear.rawValue, hasWeatherData: true),
            "SwiftData served the registered row's stale snapshot on refetch; weather clearing in long-lived actors no longer holds")
    }

    @Test("the one long-lived StayClusterer clears weather another context saved on its registered anchor when a ping moves the validity key across UTC midnight")
    func sharedClustererSeesWeatherSavedAfterItRegisteredTheAnchor() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let anchor = insertStay(context, start: utc(15, 20), end: utc(15, 22))
        let id = anchor.id
        insertPing(context, at: utc(15, 23))
        try context.save()

        // One instance for the whole test, as `AppDelegate.stayClusterer`.
        let clusterer = StayClusterer(modelContainer: container)

        // First pass: an in-day extension registers the anchor in the
        // clusterer's context. The weather key holds, and there is no weather yet.
        _ = await clusterer.clusterUnprocessedPings()
        let extended = try fresh(id, in: container)
        #expect(extended.endTime == utc(15, 23))
        let keyBefore = WeatherEnricher.WeatherValidityKey(extended)

        // The enricher saves weather for that geometry through its own context.
        try saveWeather(for: id, in: container)
        #expect(try fresh(id, in: container).avgTemperatureC == 23)

        // Second pass on the SAME instance: the ping extends the anchor across
        // UTC midnight, so the stored weather no longer matches its key.
        insertPing(context, at: utc(16, 0, 30))
        try context.save()
        _ = await clusterer.clusterUnprocessedPings()

        let crossed = try fresh(id, in: container)
        #expect(crossed.endTime == utc(16, 0, 30))
        #expect(WeatherEnricher.WeatherValidityKey(crossed) != keyBefore)
        #expect(crossed.weatherData == nil && crossed.avgTemperatureC == nil
                    && crossed.weatherConditionRaw == nil && crossed.precipitationMm == nil
                    && crossed.dayKey == nil,
                "The long-lived clusterer did not see weather another context saved on its registered anchor, so the key move left stale weather behind")
    }
}
