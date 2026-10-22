//
//  StayWeatherValidityTests.swift
//  TravelLogTests
//
//  Stored weather is valid for the key the cache shares aggregates under:
//  res-6 cell, UTC start day and UTC day span. Every Stay geometry writer
//  (ping closure and extension, Visit reconciliation including the pulled-back
//  predecessor, import pre-attach, photo-discard host repair, the DEBUG
//  reference repair) must clear weather in its own transaction when that key
//  moves, and keep it when the edit stays inside the key.
//

import CoreLocation
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Stay weather validity key")
struct StayWeatherValidityTests {

    private static let lat = 0.0
    private static let lon = -140.0

    /// A UTC instant on June `day`, 2025.
    private func utc(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        WeatherEnricher.utcCalendar.date(from: DateComponents(
            year: 2025, month: 6, day: day, hour: hour, minute: minute, second: second))!
    }

    private func longitude(metersEast: Double) -> Double {
        Self.lon + metersEast / 111_320
    }

    private func cell(metersEast: Double) -> String {
        H3Service.cellIndex(latitude: Self.lat, longitude: longitude(metersEast: metersEast)) ?? ""
    }

    @discardableResult
    private func insertStay(
        _ context: ModelContext, start: Date, end: Date, metersEast: Double = 0,
        weather: Bool = true
    ) -> Stay {
        let stay = Stay(
            startTime: start, endTime: end,
            centroidLatitude: Self.lat, centroidLongitude: longitude(metersEast: metersEast),
            h3IndexRes6: cell(metersEast: metersEast), pingCount: 0,
            distanceFromHomeKm: .greatestFiniteMagnitude, pingIDs: [])
        if weather { giveWeather(stay) }
        context.insert(stay)
        return stay
    }

    private func giveWeather(_ stay: Stay) {
        stay.weather = StayWeather(
            condition: .clear, temperatureMinC: 18, temperatureMaxC: 28,
            temperatureAvgC: 23, precipitationMm: 0, windSpeedMs: 3, humidity: 0.5)
        stay.avgTemperatureC = 23
        stay.weatherConditionRaw = StayWeather.Condition.clear.rawValue
        stay.precipitationMm = 0
        stay.dayKey = WeatherEnricher.computeDayKey(for: stay.startTime)
    }

    @discardableResult
    private func insertPing(_ context: ModelContext, at timestamp: Date, metersEast: Double = 0) -> LocationPing {
        let ping = LocationPing(
            timestamp: timestamp, latitude: Self.lat, longitude: longitude(metersEast: metersEast),
            horizontalAccuracy: 5, h3IndexRes6: cell(metersEast: metersEast))
        ping.isProcessed = false
        context.insert(ping)
        return ping
    }

    private func insertVisit(
        _ context: ModelContext, arrival: Date, departure: Date, metersEast: Double = 0
    ) {
        context.insert(Visit(
            arrivalDate: arrival, departureDate: departure,
            latitude: Self.lat, longitude: longitude(metersEast: metersEast),
            horizontalAccuracy: 5, receivedAt: departure, stayID: nil, isProcessed: false))
    }

    private func stay(_ id: UUID, in container: ModelContainer) throws -> Stay {
        try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == id })).first)
    }

    private func isCleared(_ stay: Stay) -> Bool {
        stay.weatherData == nil && stay.avgTemperatureC == nil
            && stay.weatherConditionRaw == nil && stay.precipitationMm == nil && stay.dayKey == nil
    }

    private func isKept(_ stay: Stay) -> Bool {
        stay.weatherData != nil && stay.avgTemperatureC == 23
            && stay.weatherConditionRaw == StayWeather.Condition.clear.rawValue
            && stay.precipitationMm == 0 && stay.dayKey != nil
    }

    /// An east offset whose cell differs from the cell `delta` metres further east.
    private func cellBoundary(delta: Double) throws -> Double {
        let east = stride(from: 0.0, to: 50_000, by: 100).first {
            cell(metersEast: $0) != cell(metersEast: $0 + delta)
        }
        return try #require(east)
    }

    // MARK: - Helper

    @Test("the helper clears terminal .unavailable on a key change and writes nothing inside the key")
    func helperClearsUnavailableOnlyOnKeyChange() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let stay = insertStay(context, start: utc(15, 10), end: utc(15, 12), weather: false)
        stay.weatherConditionRaw = StayWeather.Condition.unavailable.rawValue
        stay.dayKey = WeatherEnricher.computeDayKey(for: stay.startTime)

        var before = WeatherEnricher.WeatherValidityKey(stay)
        stay.endTime = utc(15, 23)
        WeatherEnricher.clearWeatherIfKeyChanged(stay, from: before)
        #expect(stay.weatherConditionRaw == StayWeather.Condition.unavailable.rawValue)

        before = WeatherEnricher.WeatherValidityKey(stay)
        stay.endTime = utc(16, 1)
        WeatherEnricher.clearWeatherIfKeyChanged(stay, from: before)
        #expect(isCleared(stay))
    }

    // MARK: - Ping closure and extension

    @Test("closing an enriched anchor across UTC midnight clears its weather")
    func closureAcrossMidnightClearsWeather() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let anchor = insertStay(context, start: utc(15, 8), end: utc(15, 20))
        insertPing(context, at: utc(16, 12), metersEast: 10_000)
        try context.save()

        _ = await StayClusterer(modelContainer: container).clusterUnprocessedPings()

        let closed = try stay(anchor.id, in: container)
        #expect(closed.endTime == utc(16, 4))
        #expect(isCleared(closed))
    }

    @Test("closing an enriched anchor inside its UTC day keeps its weather")
    func closureInsideDayKeepsWeather() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let anchor = insertStay(context, start: utc(15, 8), end: utc(15, 10))
        insertPing(context, at: utc(15, 14), metersEast: 10_000)
        try context.save()

        _ = await StayClusterer(modelContainer: container).clusterUnprocessedPings()

        let closed = try stay(anchor.id, in: container)
        #expect(closed.endTime == utc(15, 12))
        #expect(isKept(closed))
    }

    @Test("a ping extending an enriched stay across UTC midnight clears its weather")
    func extensionAcrossMidnightClearsWeather() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let anchor = insertStay(context, start: utc(15, 20), end: utc(15, 23, 30))
        insertPing(context, at: utc(16, 0, 30))
        try context.save()

        _ = await StayClusterer(modelContainer: container).clusterUnprocessedPings()

        let extended = try stay(anchor.id, in: container)
        #expect(extended.endTime == utc(16, 0, 30))
        #expect(isCleared(extended))
    }

    // MARK: - Visit reconciliation

    @Test("a zero-ping Visit moving the stay into another cell clears weather with an unchanged interval")
    func visitCellMoveClearsWeather() async throws {
        let east = try cellBoundary(delta: 2_500)
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let target = insertStay(context, start: utc(15, 10), end: utc(15, 12), metersEast: east)
        insertVisit(context, arrival: utc(15, 10), departure: utc(15, 12), metersEast: east + 2_500)
        try context.save()

        _ = await StayClusterer(modelContainer: container).clusterUnprocessedPings()

        let saved = try stay(target.id, in: container)
        #expect(saved.startTime == utc(15, 10))
        #expect(saved.endTime == utc(15, 12))
        #expect(saved.h3IndexRes6 == cell(metersEast: east + 2_500))
        #expect(isCleared(saved))
    }

    @Test("a sub-minute Visit shift across UTC midnight clears weather even with the same day span")
    func subMinuteShiftAcrossMidnightClearsWeather() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let target = insertStay(context, start: utc(15, 0, 0, 10), end: utc(16, 0, 0, 10))
        insertVisit(context, arrival: utc(14, 23, 59, 50), departure: utc(15, 23, 59, 50))
        try context.save()

        _ = await StayClusterer(modelContainer: container).clusterUnprocessedPings()

        let saved = try stay(target.id, in: container)
        #expect(saved.startTime == utc(14, 23, 59, 50))
        #expect(saved.endTime == utc(15, 23, 59, 50))
        #expect(isCleared(saved))
    }

    @Test("a Visit pulling back the predecessor clears weather on the predecessor and the target")
    func visitPullbackClearsPredecessorAndTarget() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let previous = insertStay(context, start: utc(14, 22), end: utc(15, 1))
        let target = insertStay(context, start: utc(15, 2), end: utc(15, 4), metersEast: 10_000)
        insertVisit(context, arrival: utc(14, 23, 30), departure: utc(15, 4), metersEast: 10_000)
        try context.save()

        _ = await StayClusterer(modelContainer: container).clusterUnprocessedPings()

        let pulled = try stay(previous.id, in: container)
        #expect(pulled.endTime == utc(14, 23, 29))
        #expect(isCleared(pulled))
        #expect(isCleared(try stay(target.id, in: container)))
    }

    @Test("after a same-span shift the old weather cannot seed the cache for a stay at the old key",
          .timeLimit(.minutes(1)))
    func shiftedStayIsNoLongerACacheSource() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let shifted = insertStay(context, start: utc(15, 0, 0, 10), end: utc(16, 0, 0, 10))
        insertVisit(context, arrival: utc(14, 23, 59, 50), departure: utc(15, 23, 59, 50))
        // Same cell, UTC start day and span as the shifted stay held before.
        let sibling = insertStay(context, start: utc(15, 6), end: utc(16, 6), weather: false)
        sibling.category = .destination
        let trip = Trip(startDate: sibling.startTime)
        context.insert(trip)
        sibling.trip = trip
        try context.save()

        _ = await StayClusterer(modelContainer: container).clusterUnprocessedPings()
        #expect(isCleared(try stay(shifted.id, in: container)))

        let enricher = WeatherEnricher(modelContainer: container)
        let snowDay = WeatherEnricher.DailyWeatherSample(
            lowC: -4, highC: 1, precipitationMm: 6, windSpeedMs: 5, maxHumidity: 0.9, condition: .snow)
        await enricher.setWeatherProviderForTesting { _, _, _ in [snowDay] }
        await enricher.enrichStaysForTripGated(trip.id, gate: PipelineGate(forTesting: ()))

        #expect(try stay(sibling.id, in: container).weatherConditionRaw
            == StayWeather.Condition.snow.rawValue)
    }

    // MARK: - Import pre-attach

    @Test("an imported ping moving the start across UTC midnight clears weather; one inside the day keeps it",
          arguments: [true, false])
    func importAbsorptionFollowsTheKey(crossesMidnight: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let host = insertStay(context, start: utc(16, 1), end: utc(16, 2))
        host.pingCount = 1
        host.pingIDs = [UUID()]
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let timestamp = crossesMidnight ? utc(15, 22, 30) : utc(16, 0, 30)
        _ = try await recorder.recordImportedPing(
            timestamp: timestamp, latitude: Self.lat, longitude: Self.lon, horizontalAccuracy: 10)
        try await recorder.saveImportBatch()

        let saved = try stay(host.id, in: container)
        #expect(saved.startTime == timestamp)
        #expect(crossesMidnight ? isCleared(saved) : isKept(saved))
    }

    @Test("an imported ping moving the centroid into another cell clears weather")
    func importCellMoveClearsWeather() async throws {
        // Absorption moves the centroid halfway toward the ping (n = 2).
        let east = try cellBoundary(delta: 1_250)
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let host = insertStay(context, start: utc(15, 10), end: utc(15, 12), metersEast: east)
        host.pingCount = 1
        host.pingIDs = [UUID()]
        let originalCell = host.h3IndexRes6
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        _ = try await recorder.recordImportedPing(
            timestamp: utc(15, 11), latitude: Self.lat,
            longitude: longitude(metersEast: east + 2_500), horizontalAccuracy: 10)
        try await recorder.saveImportBatch()

        let saved = try stay(host.id, in: container)
        #expect(saved.pingCount == 2)
        #expect(saved.h3IndexRes6 != originalCell)
        #expect(isCleared(saved))
    }

    @Test("a failed import batch save rolls back the boundary change and the weather clear together")
    func failedImportSaveKeepsGeometryAndWeather() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let host = insertStay(context, start: utc(16, 1), end: utc(16, 2))
        host.pingCount = 1
        host.pingIDs = [UUID()]
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        _ = try await recorder.recordImportedPing(
            timestamp: utc(15, 22, 30), latitude: Self.lat, longitude: Self.lon, horizontalAccuracy: 10)
        await recorder.setFailNextImportBatchSaveForTesting(true)
        await #expect(throws: (any Error).self) { try await recorder.saveImportBatch() }

        let saved = try stay(host.id, in: container)
        #expect(saved.startTime == utc(16, 1))
        #expect(isKept(saved))
    }

    // MARK: - Repairs

    @Test("photo-discard host repair clears weather when the rebuilt geometry leaves the key, and keeps it inside")
    func discardHostRepairFollowsTheKey() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        func ping(_ time: Date, _ source: DataSource) -> LocationPing {
            let ping = LocationPing(
                timestamp: time, latitude: Self.lat, longitude: Self.lon,
                horizontalAccuracy: 30, h3IndexRes6: cell(metersEast: 0), source: source)
            ping.isProcessed = true
            context.insert(ping)
            return ping
        }
        // The photo ping opened the first host on the previous UTC day.
        let movedPings = [ping(utc(14, 23), .photoImport), ping(utc(15, 2), .liveSLC), ping(utc(15, 3), .liveSLC)]
        let moved = insertStay(context, start: utc(14, 23), end: utc(15, 3))
        moved.pingIDs = movedPings.map(\.id)
        moved.pingCount = 3
        moved.source = .merged
        // The photo ping sits inside the second host's UTC day and cell.
        let keptPings = [ping(utc(20, 8), .liveSLC), ping(utc(20, 9), .photoImport), ping(utc(20, 10), .liveSLC)]
        let kept = insertStay(context, start: utc(20, 8), end: utc(20, 10))
        kept.pingIDs = keptPings.map(\.id)
        kept.pingCount = 3
        kept.source = .merged
        try context.save()

        try await PhotoImportService(modelContainer: container).performDiscardTeardownForTesting()

        let rebuilt = try stay(moved.id, in: container)
        #expect(rebuilt.startTime == utc(15, 2))
        #expect(isCleared(rebuilt))
        let untouchedKey = try stay(kept.id, in: container)
        #expect(untouchedKey.startTime == utc(20, 8))
        #expect(isKept(untouchedKey))
    }

    @Test("the DEBUG reference repair clears weather when rebuilt geometry leaves the key")
    func debugReferenceRepairClearsWeather() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        var survivors: [UUID] = []
        for time in [utc(15, 2), utc(15, 3)] {
            let ping = LocationPing(
                timestamp: time, latitude: Self.lat, longitude: Self.lon,
                horizontalAccuracy: 30, h3IndexRes6: cell(metersEast: 0), source: .liveSLC)
            ping.isProcessed = true
            context.insert(ping)
            survivors.append(ping.id)
        }
        let damaged = insertStay(context, start: utc(14, 23), end: utc(15, 3))
        damaged.pingIDs = [UUID()] + survivors
        damaged.pingCount = 3
        damaged.source = .merged
        try context.save()

        let report = await DebugStayReferenceRepair(modelContainer: container).repair()
        #expect(report.errorDescription == nil)
        #expect(report.repairedStays == 1)

        let repaired = try stay(damaged.id, in: container)
        #expect(repaired.startTime == utc(15, 2))
        #expect(isCleared(repaired))
    }
}
