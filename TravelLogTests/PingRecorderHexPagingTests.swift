import Foundation
import SwiftData
import Testing
@testable import TravelLog

private actor HexPageProbe {
    private(set) var resolutions = 0
    private(set) var observations: [Int] = []
    func resolve() { resolutions += 1 }
    func observe(_ count: Int) { observations.append(count) }
}

@MainActor
@Suite("PingRecorder bounded hex pages", .serialized, .timeLimit(.minutes(1)))
struct PingRecorderHexPagingTests {
    private let answer = GeocodeResolver.Result(
        country: "Greece", isoCountryCode: "GR", administrativeArea: "Attiki",
        metroName: "Athens", localityName: "Athens", subLocalityName: nil, islandName: nil)

    private func seed(_ counts: [Int]) throws -> ModelContainer {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        for (cell, count) in counts.enumerated() {
            let latitude = 37.9838 + Double(cell)
            let hex = try #require(H3Service.cellIndex(latitude: latitude, longitude: 23.7275))
            for i in 0..<count {
                let ping = LocationPing(timestamp: Date(timeIntervalSince1970: Double(i)),
                    latitude: latitude, longitude: 23.7275, horizontalAccuracy: 10, h3IndexRes6: hex)
                // Physical rows sharing UUIDs must still all leave the predicate.
                ping.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                context.insert(ping)
            }
            context.insert(Stay(startTime: .distantPast, endTime: .distantPast,
                centroidLatitude: latitude, centroidLongitude: 23.7275,
                h3IndexRes6: hex, pingCount: count, distanceFromHomeKm: 0, pingIDs: []))
            context.insert(HexVisit(h3Index: hex, firstVisited: .distantPast,
                centerLatitude: latitude, centerLongitude: 23.7275))
        }
        try context.save()
        return container
    }

    @Test("1200 physical rows use three pages and resolve/update the cell once")
    func concentratedCell() async throws {
        let container = try seed([1_200])
        let recorder = PingRecorder(modelContainer: container)
        let probe = HexPageProbe()
        let answer = answer
        await recorder.setHexResolverForTesting { _, _ in
            await probe.resolve()
            return answer
        }
        #expect(await recorder.retryAllFailedGeocodingGated(gate: PipelineGate(forTesting: ())))
        let stats = await recorder.hexPageStatsForTesting
        #expect(stats.rows == [500, 500, 200])
        #expect(stats.associatedUpdates == 1)
        #expect(await probe.resolutions == 1)
        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<LocationPing>()).allSatisfy {
            $0.isGeocoded && $0.locality == "Athens" && $0.country == "Greece" && $0.isoCountryCode == "GR"
        })
        #expect(try context.fetch(FetchDescriptor<Stay>()).first?.locality == "Athens")
        #expect(try context.fetch(FetchDescriptor<HexVisit>()).first?.locality == "Athens")
    }

    @Test("three small cells share one unit")
    func mixedCells() async throws {
        let container = try seed([10, 10, 10])
        let recorder = PingRecorder(modelContainer: container)
        let answer = answer
        await recorder.setHexResolverForTesting { _, _ in answer }
        #expect(await recorder.geocodeByUniqueHex(gate: PipelineGate(forTesting: ())) == 30)
        let stats = await recorder.hexPageStatsForTesting
        #expect(stats.rows == [30])
        #expect(stats.associatedUpdates == 3)
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocationPing>()).allSatisfy { $0.isGeocoded })
    }

    @Test("a failed page save reports no progress and does not retry the cell forever")
    func failedPageSave() async throws {
        let container = try seed([1_200])
        let recorder = PingRecorder(modelContainer: container)
        let answer = answer
        await recorder.setHexResolverForTesting { _, _ in answer }
        await recorder.setFailNextGeocodeSaveForTesting(true)
        #expect(await recorder.geocodeByUniqueHex(gate: PipelineGate(forTesting: ())) == 0)
        #expect(await recorder.hexPageStatsForTesting.rows == [500])
        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<LocationPing>()).allSatisfy { !$0.isGeocoded })
        #expect(try context.fetch(FetchDescriptor<Stay>()).first?.locality == nil)
        #expect(try context.fetch(FetchDescriptor<HexVisit>()).first?.locality == nil)
    }

    @Test("a resolver miss skips the cell once and preserves every row")
    func missTerminates() async throws {
        let container = try seed([1_200])
        let recorder = PingRecorder(modelContainer: container)
        let probe = HexPageProbe()
        await recorder.setHexResolverForTesting { _, _ in
            await probe.resolve()
            return nil
        }
        #expect(await recorder.geocodeByUniqueHex(gate: PipelineGate(forTesting: ())) == 0)
        #expect(await probe.resolutions == 1)
        #expect(await recorder.hexPageStatsForTesting.associatedUpdates == 0)
        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<LocationPing>()).allSatisfy { !$0.isGeocoded && $0.country == nil })
        #expect(try context.fetch(FetchDescriptor<Stay>()).first?.locality == nil)
        #expect(try context.fetch(FetchDescriptor<HexVisit>()).first?.locality == nil)
    }

    @Test("a competing gate unit finishes between saved pages")
    func gateFairness() async throws {
        let container = try seed([1_200])
        let recorder = PingRecorder(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let probe = HexPageProbe()
        let answer = answer
        await recorder.setHexResolverForTesting { _, _ in answer }
        await recorder.setAfterHexPageForTesting {
            await gate.run(touching: []) {
                let rows = await recorder.hexPageStatsForTesting.rows.reduce(0, +)
                await probe.observe(rows)
            }
        }
        #expect(await recorder.retryAllFailedGeocodingGated(gate: gate))
        #expect(await probe.observations == [500, 1_000, 1_200])
    }

    /// One cell with a few ungeocoded pings and `blank` locality-nil stays, preceded in
    /// insertion order by `foreign` stays the country guard must skip.
    private func seedStayHeavyCell(blank: Int, foreign: Int = 0, pings: Int) throws -> ModelContainer {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let latitude = 37.9838, longitude = 23.7275
        let hex = try #require(H3Service.cellIndex(latitude: latitude, longitude: longitude))
        for i in 0..<pings {
            context.insert(LocationPing(timestamp: Date(timeIntervalSince1970: Double(i)),
                latitude: latitude, longitude: longitude, horizontalAccuracy: 10, h3IndexRes6: hex))
        }
        for _ in 0..<foreign {
            let stay = Stay(startTime: .distantPast, endTime: .distantPast,
                centroidLatitude: latitude, centroidLongitude: longitude,
                h3IndexRes6: hex, pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
            stay.country = "France"
            stay.isoCountryCode = "FR"
            context.insert(stay)
        }
        for _ in 0..<blank {
            context.insert(Stay(startTime: .distantPast, endTime: .distantPast,
                centroidLatitude: latitude, centroidLongitude: longitude,
                h3IndexRes6: hex, pingCount: 1, distanceFromHomeKm: 0, pingIDs: []))
        }
        context.insert(HexVisit(h3Index: hex, firstVisited: .distantPast,
            centerLatitude: latitude, centerLongitude: longitude))
        try context.save()
        return container
    }

    @Test("a cell's locality-nil stays commit in bounded units a competing unit can interleave")
    func associatedStaysArePaged() async throws {
        let container = try seedStayHeavyCell(blank: 1_200, pings: 3)
        let recorder = PingRecorder(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let probe = HexPageProbe()
        let answer = answer
        await recorder.setHexResolverForTesting { _, _ in answer }
        await recorder.setAfterHexPageForTesting {
            await gate.run(touching: []) {
                let unnamed = (try? ModelContext(container).fetchCount(
                    FetchDescriptor<Stay>(predicate: #Predicate { $0.locality == nil }))) ?? -1
                await probe.observe(unnamed)
            }
        }
        #expect(await recorder.geocodeByUniqueHex(gate: gate) == 3)
        let stats = await recorder.hexPageStatsForTesting
        #expect(stats.stayRows == [500, 500, 200])
        #expect(stats.rows == [0, 0, 3])
        #expect(stats.associatedUpdates == 1)
        // Each unit's Stay edits are durable before the competing unit runs.
        #expect(await probe.observations == [700, 200, 0])
        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<Stay>()).allSatisfy {
            $0.locality == "Athens" && $0.country == "Greece" && $0.isoCountryCode == "GR"
        })
        #expect(try context.fetch(FetchDescriptor<LocationPing>()).allSatisfy { $0.isGeocoded })
        #expect(try context.fetch(FetchDescriptor<HexVisit>()).first?.locality == "Athens")
    }

    @Test("stays the country guard skips are not refetched by later stay pages")
    func skippedStaysDoNotStarveLaterPages() async throws {
        let container = try seedStayHeavyCell(blank: 300, foreign: 700, pings: 1)
        let recorder = PingRecorder(modelContainer: container)
        let answer = answer
        await recorder.setHexResolverForTesting { _, _ in answer }
        #expect(await recorder.geocodeByUniqueHex(gate: PipelineGate(forTesting: ())) == 1)
        #expect(await recorder.hexPageStatsForTesting.stayRows == [500, 500, 0])
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        let foreign = stays.filter { $0.isoCountryCode == "FR" }
        #expect(foreign.count == 700)
        #expect(foreign.allSatisfy { $0.locality == nil && $0.country == "France" && $0.administrativeArea == nil })
        let blank = stays.filter { $0.isoCountryCode != "FR" }
        #expect(blank.count == 300)
        #expect(blank.allSatisfy { $0.locality == "Athens" && $0.country == "Greece" })
    }

    @Test("hex-centre answer never moves a stay to another country")
    func hexCentreKeepsStayCountry() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        var stays: [Stay] = []
        for (latitude, longitude) in [(43.8022, 7.4306), (46.07287, -1.08845), (44.5, 6.5)] {
            let hex = try #require(H3Service.cellIndex(latitude: latitude, longitude: longitude))
            context.insert(LocationPing(timestamp: .distantPast, latitude: latitude, longitude: longitude,
                horizontalAccuracy: 10, h3IndexRes6: hex))
            let stay = Stay(startTime: .distantPast, endTime: .distantPast,
                centroidLatitude: latitude, centroidLongitude: longitude,
                h3IndexRes6: hex, pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
            context.insert(stay)
            stays.append(stay)
        }
        stays[0].country = "Monaco"
        stays[0].isoCountryCode = "MC"
        stays[2].country = "France"
        stays[2].isoCountryCode = "FR"
        stays[2].administrativeArea = "Hautes-Alpes"
        try context.save()
        let ids = stays.map(\.persistentModelID)
        let recorder = PingRecorder(modelContainer: container)
        let result = GeocodeResolver.Result(
            country: "France", isoCountryCode: "FR", administrativeArea: "Provence-Alpes-Cote d'Azur",
            metroName: nil, localityName: "Beausoleil", subLocalityName: nil, islandName: nil)
        await recorder.setHexResolverForTesting { _, _ in result }
        #expect(await recorder.geocodeByUniqueHex(gate: PipelineGate(forTesting: ())) == 3)
        let fresh = ModelContext(container)
        let monaco = try #require(fresh.model(for: ids[0]) as? Stay)
        #expect(monaco.isoCountryCode == "MC" && monaco.country == "Monaco")
        #expect(monaco.locality == nil && monaco.administrativeArea == nil)
        let blank = try #require(fresh.model(for: ids[1]) as? Stay)
        #expect(blank.isoCountryCode == "FR" && blank.country == "France" && blank.locality == "Beausoleil")
        #expect(blank.administrativeArea == "Provence-Alpes-Cote d'Azur")
        let french = try #require(fresh.model(for: ids[2]) as? Stay)
        #expect(french.locality == "Beausoleil" && french.administrativeArea == "Hautes-Alpes")
        #expect(try fresh.fetch(FetchDescriptor<LocationPing>()).allSatisfy { $0.isGeocoded })
    }

    @Test("paged output writes the whole-cell fields to every ping, stay and hex and leaves each row in its own cell", arguments: [true, false])
    func pagedFields(hasPlace: Bool) async throws {
        let paged = try seed([1_200, 10, 10])
        let before = try rowsPerCell(paged)
        #expect(before.count == 9)
        #expect(before.filter { $0.key.hasPrefix("ping|") }.values.sorted() == [10, 10, 1_200])
        #expect(before.filter { !$0.key.hasPrefix("ping|") }.values.allSatisfy { $0 == 1 })
        let result = hasPlace ? answer : GeocodeResolver.Result(
            country: nil, isoCountryCode: nil, administrativeArea: "Region only",
            metroName: nil, localityName: nil, subLocalityName: nil, islandName: nil)
        // A region-only answer names no place, so no ping counts as geocoded,
        // yet its region still fills the blank stays.
        let place: (locality: String?, region: String?, country: String?, iso: String?) = hasPlace
            ? ("Athens", "Attiki", "Greece", "GR")
            : (nil, "Region only", nil, nil)
        let recorder = PingRecorder(modelContainer: paged)
        await recorder.setHexResolverForTesting { _, _ in result }
        #expect(await recorder.geocodeByUniqueHex(gate: PipelineGate(forTesting: ())) == (hasPlace ? 1_220 : 0))
        let context = ModelContext(paged)
        let pings = try context.fetch(FetchDescriptor<LocationPing>())
        #expect(pings.count == 1_220)
        #expect(pings.allSatisfy {
            $0.isGeocoded == hasPlace && $0.locality == place.locality && $0.subLocality == nil
                && $0.administrativeArea == place.region && $0.country == place.country
                && $0.isoCountryCode == place.iso
        })
        let stays = try context.fetch(FetchDescriptor<Stay>())
        #expect(stays.count == 3)
        #expect(stays.allSatisfy {
            $0.locality == place.locality && $0.administrativeArea == place.region
                && $0.country == place.country && $0.isoCountryCode == place.iso
        })
        let hexes = try context.fetch(FetchDescriptor<HexVisit>())
        #expect(hexes.count == 3)
        #expect(hexes.allSatisfy {
            $0.locality == place.locality && $0.country == place.country && $0.isoCountryCode == place.iso
        })
        #expect(await recorder.hexPageStatsForTesting.rows.allSatisfy { $0 <= 500 })
        #expect(try rowsPerCell(paged) == before)
    }

    /// Ping, stay and hex rows per H3 cell, so a pass that moves rows between
    /// cells fails even when the totals and the written fields still hold.
    private func rowsPerCell(_ container: ModelContainer) throws -> [String: Int] {
        let context = ModelContext(container)
        var counts: [String: Int] = [:]
        for ping in try context.fetch(FetchDescriptor<LocationPing>()) {
            counts["ping|" + ping.h3IndexRes6, default: 0] += 1
        }
        for stay in try context.fetch(FetchDescriptor<Stay>()) {
            counts["stay|" + stay.h3IndexRes6, default: 0] += 1
        }
        for hex in try context.fetch(FetchDescriptor<HexVisit>()) {
            counts["hex|" + hex.h3Index, default: 0] += 1
        }
        return counts
    }
}
