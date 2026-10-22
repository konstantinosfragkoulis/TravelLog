import Testing
import Foundation
import SwiftData
import CoreLocation
import os
@testable import TravelLog

@MainActor
@Suite("Map preparation and cancellation")
struct HexMapDataLoaderTests {
    private let date = Date(timeIntervalSince1970: 1_750_000_000)

    private func hex(_ index: Int) throws -> String {
        try #require(H3Service.cellIndex(latitude: 38 + Double(index), longitude: 24))
    }

    @discardableResult
    private func visit(_ index: Int, context: ModelContext, invalid: Bool = false) throws -> HexVisit {
        let row = HexVisit(
            h3Index: invalid ? "invalid" : try hex(index),
            firstVisited: date.addingTimeInterval(Double(index)),
            centerLatitude: 38 + Double(index), centerLongitude: 24
        )
        row.lastVisited = date.addingTimeInterval(Double(index + 100))
        row.visitCount = index + 1
        row.locality = "Place \(index)"
        row.country = "Greece"
        row.isoCountryCode = "GR"
        context.insert(row)
        return row
    }

    @discardableResult
    private func stay(
        _ index: Int, context: ModelContext, category: StayCategory = .transit,
        flight: Bool = false, airport: Bool = false
    ) throws -> Stay {
        let row = Stay(
            startTime: date, endTime: date.addingTimeInterval(3600),
            centroidLatitude: 38 + Double(index), centroidLongitude: 24,
            h3IndexRes6: try hex(index), pingCount: 2,
            distanceFromHomeKm: 0, pingIDs: []
        )
        row.category = category
        row.transitFromPreviousRaw = flight ? TransitMode.flight.rawValue : nil
        row.isAirport = airport
        // Unused large fields must not change the projected result.
        row.weatherData = Data(repeating: 0xAA, count: 32_768)
        context.insert(row)
        return row
    }

    @Test("background reads preserve visibility, ordering, metadata and geometry")
    func backgroundSnapshotParity() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        for index in 0..<8 { try visit(index, context: context, invalid: index == 7) }
        try stay(0, context: context, flight: true) // hidden
        try stay(1, context: context, airport: true) // hidden
        try stay(2, context: context) // surface
        try stay(3, context: context, flight: true)
        try stay(3, context: context) // surface wins
        try stay(4, context: context, flight: true)
        try stay(4, context: context, category: .destination) // real wins
        // 5 has no stay; an unclassified stay does not hide 6.
        try stay(6, context: context, category: .unclassified, flight: true)
        try context.save()
        #expect(!context.hasChanges)

        // Independent full-fetch reference using the expected visible cells.
        let expected = try context.fetch(FetchDescriptor<HexVisit>(
            sortBy: [SortDescriptor(\.lastVisited, order: .reverse)]
        )).filter { $0.h3Index != (try? hex(0)) && $0.h3Index != (try? hex(1)) }
        let offMain = OSAllocatedUnfairLock(initialState: true)
        let snapshot = try await HexMapDataLoader.load(context: context) { id in
            offMain.withLock { $0 = $0 && !Thread.isMainThread }
            return H3Service.cellBoundary(for: id)
        }
        #expect(offMain.withLock { $0 })
        // The invalid index has no polygon, so no row either.
        #expect(snapshot.rows.count == 5)
        #expect(snapshot.rows == expected.filter { $0.h3Index != "invalid" }.map {
            HexVisitSnapshot(h3Index: $0.h3Index, locality: $0.locality,
                             country: $0.country, isoCountryCode: $0.isoCountryCode,
                             firstVisited: $0.firstVisited, lastVisited: $0.lastVisited,
                             visitCount: $0.visitCount, centerLatitude: $0.centerLatitude,
                             centerLongitude: $0.centerLongitude)
        })
        #expect(snapshot.overlays.map(\.id) == snapshot.rows.map(\.h3Index))
        #expect(snapshot.maxCount == 7) // invalid row's count of 8 is excluded
        for overlay in snapshot.overlays {
            let row = try #require(expected.first { $0.h3Index == overlay.id })
            let boundary = try #require(H3Service.cellBoundary(for: row.h3Index))
            #expect(overlay.boundary.map(\.latitude) == boundary.map(\.latitude))
            #expect(overlay.boundary.map(\.longitude) == boundary.map(\.longitude))
            #expect(overlay.visitCount == row.visitCount)
            #expect(overlay.centerLatitude == row.centerLatitude)
            #expect(overlay.centerLongitude == row.centerLongitude)
        }
        #expect(!context.hasChanges)
    }

    @Test("a retained same-cell duplicate draws one overlay with merged metadata")
    func duplicateCellRowsCollapse() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let first = try visit(0, context: context)
        try visit(1, context: context)
        try context.save()
        let normal = try await HexMapDataLoader.load(context: context)
        #expect(normal.rows.map(\.h3Index) == [try hex(1), try hex(0)])
        #expect(normal.maxCount == 2)

        // A second row for cell 0, newest and with a larger count but no labels.
        let twin = try visit(0, context: context)
        twin.firstVisited = date.addingTimeInterval(500)
        twin.lastVisited = date.addingTimeInterval(1_000)
        twin.visitCount = 5
        twin.centerLatitude = 99
        twin.locality = nil
        twin.country = nil
        twin.isoCountryCode = nil
        try context.save()
        let merged = try await HexMapDataLoader.load(context: context)
        #expect(merged.overlays.map(\.id) == [try hex(0), try hex(1)])
        #expect(merged.rows.map(\.h3Index) == merged.overlays.map(\.id))
        #expect(merged.rows.first == HexVisitSnapshot(
            h3Index: try hex(0), locality: first.locality, country: "Greece", isoCountryCode: "GR",
            firstVisited: first.firstVisited, lastVisited: twin.lastVisited,
            visitCount: 5, centerLatitude: 99, centerLongitude: 24))
        #expect(merged.overlays.first?.visitCount == 5) // the larger count, not the sum
        #expect(merged.maxCount == 5)
        #expect(Array(merged.rows.dropFirst()) == Array(normal.rows.prefix(1)))
    }

    @Test("a merged row never pairs one row's country with another's ISO code")
    func mergeKeepsCountryPair() {
        func row(_ country: String?, _ iso: String?) -> HexVisitSnapshot {
            HexVisitSnapshot(h3Index: "cell", locality: nil, country: country, isoCountryCode: iso,
                             firstVisited: date, lastVisited: date, visitCount: 1,
                             centerLatitude: 0, centerLongitude: 0)
        }
        let norway = row("Norway", nil)
        #expect(norway.merging(row("Sweden", "SE")).isoCountryCode == nil)
        #expect(norway.merging(row("Norway", "NO")).isoCountryCode == "NO")
        #expect(row(nil, "SE").merging(row("Norway", "NO")).country == nil)
        let empty = row(nil, nil).merging(row("Sweden", "SE"))
        #expect(empty.country == "Sweden" && empty.isoCountryCode == "SE")
    }

    @Test("pending inserts, deletes and category changes remain visible without a save")
    func pendingContextEdits() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        try visit(0, context: context)
        let deleted = try visit(1, context: context)
        let categoryEdit = try stay(0, context: context, flight: true)
        try visit(3, context: context)
        let reverseEdit = try stay(3, context: context, category: .destination, flight: true)
        try context.save()

        let before = try await HexMapDataLoader.load(context: context)
        #expect(before.rows.map(\.h3Index) == [try hex(3), try hex(1)])
        categoryEdit.category = .destination
        reverseEdit.category = .transit
        context.delete(deleted)
        try visit(2, context: context)
        let pending = try await HexMapDataLoader.load(context: context)
        #expect(pending.rows.map(\.h3Index) == [try hex(2), try hex(0)])
        #expect(pending.overlays.map(\.id) == pending.rows.map(\.h3Index))
        #expect(context.hasChanges)

        // The worker must not implicitly commit any of those edits.
        let committedContext = ModelContext(container)
        let committed = try HexMapDataLoader.fetchInputs(context: committedContext)
        let committedSnapshot = try HexMapDataLoader.buildSnapshot(inputs: committed)
        #expect(committedSnapshot.rows.map(\.h3Index) == [try hex(3), try hex(1)])
    }

    /// The pre-change read: every real stay's hex, then the shared hide rule.
    private func oldHiddenHexes(_ context: ModelContext) throws -> (hidden: Set<String>, real: Set<String>) {
        var transitDescriptor = FetchDescriptor<Stay>(predicate: #Predicate { $0.categoryRaw == "transit" })
        transitDescriptor.propertiesToFetch = [\.h3IndexRes6, \.categoryRaw, \.transitFromPreviousRaw, \.isAirport]
        let transit = try context.fetch(transitDescriptor).map {
            HexVisibility.TransitStay(
                h3Index: $0.h3IndexRes6,
                isFlight: $0.transitFromPreviousRaw == TransitMode.flight.rawValue,
                isAirport: $0.isAirport)
        }
        var realDescriptor = FetchDescriptor<Stay>(predicate: #Predicate {
            $0.categoryRaw == "home" || $0.categoryRaw == "routine" || $0.categoryRaw == "destination"
        })
        realDescriptor.propertiesToFetch = [\.h3IndexRes6, \.categoryRaw]
        var realHexes = Set<String>()
        for stay in try context.fetch(realDescriptor) where !stay.h3IndexRes6.isEmpty {
            realHexes.insert(stay.h3IndexRes6)
        }
        return (HexVisibility.hiddenHexes(transit: transit, realHexes: realHexes), realHexes)
    }

    @Test("reading real stays only in all-aerial hexes hides exactly what the full read hid",
          arguments: [200, 1_100])
    func restrictedRealReadParity(cells: Int) throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        func cell(_ index: Int) throws -> String {
            try #require(H3Service.cellIndex(
                latitude: 30 + Double(index / 40) * 0.2, longitude: 10 + Double(index % 40) * 0.2))
        }
        @discardableResult
        func add(_ h3: String, _ category: StayCategory, flight: Bool = false,
                 airport: Bool = false, twinOf: Stay? = nil) -> Stay {
            let row = Stay(startTime: date, endTime: date.addingTimeInterval(3600),
                           centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: h3,
                           pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
            row.category = category
            row.transitFromPreviousRaw = flight ? TransitMode.flight.rawValue : nil
            row.isAirport = airport
            if let twinOf { row.id = twinOf.id }
            context.insert(row)
            return row
        }
        // Eight shapes; 6 in 8 cells are all-aerial: 150 (restricted read) or 825 (all-real read).
        var flightOnly: [Stay] = [], realOverFlight: [Stay] = [], airportOnlyCells: [String] = [],
            homeOverAirport: [Stay] = []
        for index in 0..<cells {
            let h3 = try cell(index)
            switch index % 8 {
            case 0: flightOnly.append(add(h3, .transit, flight: true))
            case 1: add(h3, .transit, airport: true); airportOnlyCells.append(h3)
            case 2: add(h3, .transit)
            case 3: add(h3, .transit, flight: true); realOverFlight.append(add(h3, .destination))
            case 4: add(h3, .transit, airport: true); homeOverAirport.append(add(h3, .home))
            case 5:
                let transit = add(h3, .transit, flight: true)
                add(h3, .transit, flight: true, twinOf: transit)
                let routine = add(h3, .routine)
                add(h3, .routine, twinOf: routine)
            case 6: add(h3, .transit, flight: true); add(h3, .unclassified)
            default: add(h3, .destination)
            }
        }
        add("", .transit, flight: true)
        add("", .destination)
        try context.save()

        func assertParity(_ context: ModelContext) throws {
            // The new read first, so a fresh context reaches it cold.
            let inputs = try HexMapDataLoader.fetchInputs(context: context)
            let old = try oldHiddenHexes(context)
            let aerialOnly = HexVisibility.hiddenHexes(transit: inputs.transit, realHexes: [])
            #expect(HexVisibility.hiddenHexes(transit: inputs.transit, realHexes: inputs.realHexes) == old.hidden)
            #expect(inputs.realHexes == (aerialOnly.count <= 500 ? old.real.intersection(aerialOnly) : old.real))
        }
        try assertParity(context)
        try assertParity(ModelContext(container))
        #expect(try oldHiddenHexes(context).hidden.count == (0..<cells).count { [0, 1, 6].contains($0 % 8) })

        // Unsaved edits in both directions, inserts and deletes.
        flightOnly[0].category = .destination
        flightOnly[1].isAirport = true
        realOverFlight[0].category = .transit
        realOverFlight[1].h3IndexRes6 = try cell(2)
        homeOverAirport[0].category = .unclassified
        context.delete(homeOverAirport[1])
        add(airportOnlyCells[0], .routine)
        add(airportOnlyCells[1], .transit)
        #expect(context.hasChanges)
        try assertParity(context)
        #expect(try oldHiddenHexes(context).hidden != oldHiddenHexes(ModelContext(container)).hidden)
        // A fresh context still reads the committed state.
        try assertParity(ModelContext(container))
    }

    @Test("empty and all-hidden stores produce a complete empty snapshot", arguments: [false, true])
    func emptySnapshot(hidden: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        if hidden {
            try visit(0, context: context)
            try stay(0, context: context, flight: true)
            try context.save()
        }
        let snapshot = try await HexMapDataLoader.load(context: context)
        #expect(snapshot.rows.isEmpty)
        #expect(snapshot.overlays.isEmpty)
        #expect(snapshot.maxCount == 1)
    }

    @Test("an already cancelled caller does not start geometry work")
    func cancelledBeforeLoad() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        try visit(0, context: context)
        try context.save()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let caller = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await HexMapDataLoader.load(context: context) { id in
                calls.withLock { $0 += 1 }
                return H3Service.cellBoundary(for: id)
            }
        }
        do {
            _ = try await caller.value
            Issue.record("Cancelled load returned a snapshot")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(calls.withLock { $0 } == 0)
    }

    @Test("parent cancellation stops the active worker after its current boundary",
          .timeLimit(.minutes(1)), arguments: [1, 3])
    func cancelsActiveWorker(heldBoundary: Int) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        for index in 0..<3 { try visit(index, context: context) }
        try context.save()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let cancelCaller = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
        let caller = Task { @MainActor in
            return try await HexMapDataLoader.load(context: context) { id in
                let count = calls.withLock { $0 += 1; return $0 }
                if count == heldBoundary {
                    // Request parent cancellation while its detached worker
                    // is in this boundary. The loader must forward it before
                    // the worker attempts another boundary or returns a result.
                    let cancel = cancelCaller.withLock { $0 }
                    #expect(cancel != nil)
                    cancel?()
                    // A newly detached worker can beat handler registration.
                    // Bound only forwarding after the cancellation request,
                    // without waiting for the test's MainActor to resume.
                    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                    while !Task.isCancelled, ContinuousClock.now < deadline {
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    #expect(Task.isCancelled)
                }
                return H3Service.cellBoundary(for: id)
            }
        }
        // Install before yielding MainActor to the caller task; no timed
        // hold depends on this test resuming amid unrelated suite work.
        cancelCaller.withLock { $0 = { caller.cancel() } }
        defer {
            cancelCaller.withLock { $0 = nil }
            caller.cancel()
        }
        do {
            _ = try await caller.value
            Issue.record("Cancelled worker returned a partial snapshot")
        } catch {
            #expect(error is CancellationError)
        }
        // Cancelling at the first boundary detects continued work; the last
        // boundary covers cancellation at the end of the loop.
        #expect(caller.isCancelled)
        #expect(calls.withLock { $0 } == heldBoundary)
    }
}
