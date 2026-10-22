import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite(IsolatedTitleDefaults())
struct HomeOrbitPrimingTests {
    static let base = Date(timeIntervalSince1970: 1_704_067_200)
    static let day: TimeInterval = 86_400

    nonisolated static func seed(area: Double = 100) -> HomeShape {
        .urbanCentre(id: 1, name: "TestCity", areaKm2: area,
                     rings: [[[23.75, 37.95, 23.85, 37.95, 23.85, 38.05, 23.75, 38.05]]],
                     centreLatitude: 38, centreLongitude: 23.8)
    }

    private func fixture() async throws -> TripClassifier {
        let classifier = TripClassifier(modelContainer: try TestSupport.makeInMemoryContainer())
        try await classifier.seedOrbitPrimingFixture(base: Self.base)
        await classifier.primeShapeForTesting(latitude: 38, longitude: 23.8, shape: Self.seed())
        return classifier
    }

    private func checkParity(_ classifier: TripClassifier, seed: HomeShape = HomeOrbitPrimingTests.seed()) async throws {
        let actual = await classifier.primedOrbitsForTesting()
        let expected = try await classifier.oldOrbitPrimingOracle(seed: seed)
        #expect(actual == expected)
    }

    @Test("Projected orbit primes match the old full-fetch path through edits and rollback")
    func parityAndInvalidation() async throws {
        let classifier = try await fixture()
        try await checkParity(classifier)
        let original = await classifier.primedOrbitsForTesting()
        #expect(original.count == 2)
        #expect(original.values.allSatisfy { !$0.isEmpty })
        #expect(await classifier.orbitDerivationCountForTesting == 2)

        let fingerprint = try #require(await classifier.homeAreaFingerprint())
        let coverage = try await classifier.homeAreaCoverage()
        #expect(await classifier.homeAreaFingerprint() == fingerprint)
        #expect(try await classifier.homeAreaCoverage() == coverage)
        #expect(await classifier.orbitDerivationCountForTesting == 2)

        for change in ["insert", "exclude", "era", "source", "airport", "end", "latitude", "longitude", "start", "id"] {
            let before = await classifier.orbitDerivationCountForTesting
            try await classifier.changeOrbitPrimingFixture(change, base: Self.base)
            try await checkParity(classifier)
            #expect(await classifier.orbitDerivationCountForTesting == before + 1, "change: \(change)")
        }

        let beforeSeed = await classifier.orbitDerivationCountForTesting
        await classifier.primeShapeForTesting(latitude: 38, longitude: 23.8, shape: Self.seed(area: 101))
        try await checkParity(classifier, seed: Self.seed(area: 101))
        #expect(await classifier.orbitDerivationCountForTesting == beforeSeed + 2)

        let saved = await classifier.primedOrbitsForTesting()
        let beforeInsert = await classifier.orbitDerivationCountForTesting
        try await classifier.changeOrbitPrimingFixture("unsaved", base: Self.base)
        _ = await classifier.primedOrbitsForTesting(seedsOnly: true)
        #expect(await classifier.orbitDerivationCountForTesting == beforeInsert)
        try await checkParity(classifier, seed: Self.seed(area: 101))
        #expect(await classifier.orbitDerivationCountForTesting == beforeInsert + 1)
        #expect(await classifier.primedOrbitsForTesting() != saved)
        try await classifier.changeOrbitPrimingFixture("rollback", base: Self.base)
        try await checkParity(classifier, seed: Self.seed(area: 101))
        #expect(await classifier.primedOrbitsForTesting() == saved)
        #expect(await classifier.orbitDerivationCountForTesting == beforeInsert + 2)

        let beforeOutside = await classifier.orbitDerivationCountForTesting
        try await classifier.changeOrbitPrimingFixture("outside", base: Self.base)
        try await checkParity(classifier, seed: Self.seed(area: 101))
        #expect(await classifier.orbitDerivationCountForTesting == beforeOutside)
    }

    @Test("A full classification pass and healing reads derive once per unchanged home")
    func pipelineDerivationCount() async throws {
        let classifier = try await fixture()
        _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
            reclassifyRecentStays: false, fmAvailable: false, response: { _ in [] })
        let afterClassification = await classifier.orbitDerivationCountForTesting
        #expect(afterClassification == 2)
        let fingerprint = try #require(await classifier.homeAreaFingerprint())
        let defaults = try #require(UserDefaults(suiteName: "HomeOrbitPriming-\(UUID())"))
        defaults.set(fingerprint, forKey: HomeAreaHealing.fingerprintKey)
        await HomeAreaHealing.healIfNeeded(defaults: defaults, stages: .init(
            rescue: {}, fingerprint: { await classifier.homeAreaFingerprint() },
            heal: { _ in Issue.record("Unchanged input must skip healing"); return .init(moved: 0, failed: true) },
            drainParked: { [] }, classify: { true }, generateTitles: {},
            coverage: { try await classifier.homeAreaCoverage() }, bumpChanges: {}, reloadWidgets: {}))
        _ = try await classifier.homeAreaCoverage()
        #expect(await classifier.orbitDerivationCountForTesting == 2)
        try await checkParity(classifier)
    }

    @Test("A settled pass derives no orbits; the next reader derives once from current evidence")
    func settledPassDefersDerivation() async throws {
        let classifier = try await fixture()
        _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
            reclassifyRecentStays: false, fmAvailable: false, response: { _ in [] })
        #expect(await classifier.baselinePassPending() == false)
        let afterBaseline = await classifier.orbitDerivationCountForTesting

        // An ongoing stay grows: the era's orbit inputs change, nothing awaits judgment.
        try await classifier.changeOrbitPrimingFixture("end", base: Self.base)
        _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
            reclassifyRecentStays: false, fmAvailable: false, response: { _ in [] })
        #expect(await classifier.orbitDerivationCountForTesting == afterBaseline)

        try await checkParity(classifier)
        #expect(await classifier.orbitDerivationCountForTesting == afterBaseline + 1)
    }
}

extension TripClassifier {
    // Full-object fetch and per-home filtering copied from the earlier production path.
    func oldOrbitPrimingOracle(seed: HomeShape) throws -> [String: [HomeOrbit.OrbitDisc]] {
        let homes = try modelContext.fetch(FetchDescriptor<Home>())
        let allStays = try modelContext.fetch(FetchDescriptor<Stay>(sortBy: [SortDescriptor(\.startTime)]))
        let overrides = try modelContext.fetch(FetchDescriptor<HomeAreaOverride>())
        var orbits: [String: [HomeOrbit.OrbitDisc]] = [:]
        for home in homes {
            let windowEnd = home.endedAt ?? .distantFuture
            let observations = allStays
                .filter { $0.startTime >= home.startedAt && $0.startTime <= windowEnd }
                .map {
                    HomeOrbit.StayObservation(
                        id: $0.id, start: $0.startTime, end: $0.endTime,
                        latitude: $0.centroidLatitude, longitude: $0.centroidLongitude,
                        isTransitNode: $0.isAirport,
                        isLive: $0.sourceRaw == DataSource.liveSLC.rawValue
                            || $0.sourceRaw == DataSource.merged.rawValue)
                }
            let excludes = overrides
                .filter { ($0.homeID == nil || $0.homeID == home.id) && $0.kind == .exclude }
                .map { (latitude: $0.centerLatitude, longitude: $0.centerLongitude, radiusKm: $0.radiusKm) }
            orbits[home.id.uuidString] = HomeOrbit.deriveDiscs(
                observations: observations, seed: seed, excludes: excludes).compactMap(\.disc)
        }
        return orbits
    }

    func seedOrbitPrimingFixture(base: Date) throws {
        modelContext.autosaveEnabled = false
        for era in 0..<2 {
            let home = Home(label: "Era \(era)", latitude: 38, longitude: 23.8,
                            startedAt: base.addingTimeInterval(Double(era * 100) * 86_400))
            if era == 0 { home.endedAt = base.addingTimeInterval(100 * 86_400) }
            modelContext.insert(home)
            modelContext.insert(HomeAreaOverride(kind: .exclude, centerLatitude: 0,
                centerLongitude: 0, radiusKm: 1, homeID: home.id))
            for day in stride(from: era * 100, to: era * 100 + 90, by: 2) {
                for (hour, longitude, hours) in [(0.0, 23.8, 8.0), (10, 23.99, 5), (17, 23.8, 7)] {
                    let start = base.addingTimeInterval(Double(day) * 86_400 + hour * 3600)
                    let stay = Stay(startTime: start, endTime: start.addingTimeInterval(hours * 3600),
                        centroidLatitude: 38, centroidLongitude: longitude,
                        h3IndexRes6: "fixture", pingCount: 2, distanceFromHomeKm: 15, pingIDs: [])
                    stay.category = longitude == 23.8 ? .home : .destination
                    stay.userOverridden = true
                    stay.source = day % 4 == 0 ? .liveSLC : .merged
                    // A merged stay is live evidence only with its own Visit.
                    if stay.source == .merged { modelContext.insert(Visit(stayID: stay.id)) }
                    modelContext.insert(stay)
                }
            }
        }
        for index in 0..<30 {
            let start = base.addingTimeInterval(Double(index * 6) * 86_400 + 9 * 3600)
            let stay = Stay(startTime: start, endTime: start.addingTimeInterval(600),
                centroidLatitude: 38, centroidLongitude: 23.9,
                h3IndexRes6: "noise", pingCount: 2, distanceFromHomeKm: 8, pingIDs: [])
            stay.isAirport = index % 2 == 0
            stay.source = .photoImport
            stay.category = .transit
            stay.userOverridden = true
            modelContext.insert(stay)
        }
        modelContext.insert(HomeAreaOverride(kind: .exclude, centerLatitude: -10,
            centerLongitude: -10, radiusKm: 1, homeID: nil))
        modelContext.insert(HomeAreaOverride(kind: .include, centerLatitude: 37,
            centerLongitude: 23, radiusKm: 1, homeID: nil))
        try modelContext.save()
        modelContext.rollback() // force the first prime to read stored rows
    }

    func changeOrbitPrimingFixture(_ change: String, base: Date) throws {
        if change == "rollback" { modelContext.rollback(); return }
        if ["insert", "unsaved", "outside"].contains(change) {
            let offset: Double = change == "outside" ? -1 : (change == "unsaved" ? 187 : 35)
            // Odd days hold no fixture stays: 16:00 lies within 12 h of the
            // next day's 00:00 home stay, so the visit is a witnessed return.
            let start = base.addingTimeInterval(offset * 86_400 + 16 * 3600)
            modelContext.insert(Stay(startTime: start, endTime: start.addingTimeInterval(5 * 3600),
                centroidLatitude: 38, centroidLongitude: 23.99,
                h3IndexRes6: "insert", pingCount: 2, distanceFromHomeKm: 15, pingIDs: []))
        } else if change == "exclude" {
            let home = try modelContext.fetch(FetchDescriptor<Home>(sortBy: [SortDescriptor(\.startedAt)])).first!
            let row = try modelContext.fetch(FetchDescriptor<HomeAreaOverride>()).first { $0.homeID == home.id }!
            row.centerLatitude = 38
            row.centerLongitude = 23.99
        } else if change == "era" {
            let home = try modelContext.fetch(FetchDescriptor<Home>(sortBy: [SortDescriptor(\.startedAt)])).first!
            home.endedAt = base.addingTimeInterval(99 * 86_400)
        } else {
            let stay = try modelContext.fetch(FetchDescriptor<Stay>(sortBy: [SortDescriptor(\.startTime)])).first!
            switch change {
            case "source": stay.source = .photoImport
            case "airport": stay.isAirport.toggle()
            case "end": stay.endTime += 60
            case "latitude": stay.centroidLatitude += 0.001
            case "longitude": stay.centroidLongitude += 0.001
            case "start": stay.startTime += 1
            case "id": stay.id = UUID()
            default: break
            }
        }
        if change != "unsaved" { try modelContext.save() }
    }
}
