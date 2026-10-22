//
//  P07RegressionTests.swift
//  TravelLogTests
//
//  Capture, geography and initialization: what a first launch may accept,
//  which failed evidence stays owed, and which coordinate an answer belongs to.
//
//  @MainActor because the app target compiles with MainActor-by-default
//  isolation; assertions re-fetch from a fresh context.
//

import CoreLocation
import Foundation
import SwiftData
import Testing
import UIKit
@testable import TravelLog

@MainActor
@Suite("Capture, geography and initialization")
struct P07RegressionTests {

    /// Fictional instants (stored reference-date numbers) and place.
    private static let start: TimeInterval = 800_000_000
    private static let latitude = 44.3
    private static let longitude = 12.9

    // MARK: - SCHEMA-001

    @Test("nonpersistent storage routes to recovery before any onboarding step",
          arguments: [false, true], [false, true])
    func nonpersistentStorageNeverReachesOnboarding(onboardingComplete: Bool, hasHome: Bool) {
        #expect(RootView.route(
            onboardingComplete: onboardingComplete, isPersistentStore: false, hasHome: hasHome)
            == .storageUnavailable)
        let healthy = RootView.route(
            onboardingComplete: onboardingComplete, isPersistentStore: true, hasHome: hasHome)
        #expect(healthy == (onboardingComplete && hasHome ? .main : .onboarding))
    }

    // MARK: - ACQ-004

    private struct StubVisit: VisitEventSource {
        let coordinate: CLLocationCoordinate2D
        let horizontalAccuracy: CLLocationAccuracy
        let arrivalDate: Date
        let departureDate: Date
    }

    private static func visit(arrivalHour: Double, departureHour: Double?) -> VisitObservation {
        let base = Date(timeIntervalSinceReferenceDate: start)
        let arrival = base.addingTimeInterval(arrivalHour * 3_600)
        let departure = departureHour.map { base.addingTimeInterval($0 * 3_600) }
        return VisitObservation(
            source: StubVisit(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                horizontalAccuracy: 20, arrivalDate: arrival,
                departureDate: departure ?? .distantFuture),
            receivedAt: (departure ?? arrival).addingTimeInterval(60))
    }

    /// Actor calls take a fresh handle on the suite: a handle cannot be
    /// shared across isolation domains.
    private static func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "P07Regression-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test("a closed Visit whose read or save failed lands on the next trigger", arguments: [
        VisitRecorder.Fault.read, .save,
    ])
    func failedVisitInsertStaysOwed(fault: VisitRecorder.Fault) async throws {
        let (defaults, suite) = try Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = VisitRecorder(modelContainer: container)
        await recorder.setFaultsForTesting([fault])

        let closed = Self.visit(arrivalHour: 1, departureHour: 3)
        #expect(await recorder.record(closed, defaults: UserDefaults(suiteName: suite)!) == .failed)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Visit>()) == 0)
        #expect(await recorder.failedObservationCountForTesting == 1)

        #expect(await recorder.retryFailedObservations(defaults: UserDefaults(suiteName: suite)!))
        let rows = try ModelContext(container).fetch(FetchDescriptor<Visit>())
        #expect(rows.count == 1)
        #expect(rows.first?.departureDate == closed.departureDate)
        #expect(await recorder.failedObservationCountForTesting == 0)

        // The platform redelivering it afterwards adds nothing.
        #expect(await recorder.record(closed, defaults: UserDefaults(suiteName: suite)!) == .ignored)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Visit>()) == 1)
    }

    @Test("a departure whose close failed is replayed before the next callback")
    func failedVisitCloseIsReplayedFirst() async throws {
        let (defaults, suite) = try Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = VisitRecorder(modelContainer: container)

        #expect(await recorder.record(
            Self.visit(arrivalHour: 1, departureHour: nil), defaults: UserDefaults(suiteName: suite)!) == .recorded)
        await recorder.setFaultsForTesting([.save])
        let closing = Self.visit(arrivalHour: 1, departureHour: 3)
        #expect(await recorder.record(closing, defaults: UserDefaults(suiteName: suite)!) == .failed)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Visit>()).first?.departureDate == nil)

        // An unrelated later callback replays the owed departure first.
        #expect(await recorder.record(
            Self.visit(arrivalHour: 5, departureHour: nil), defaults: UserDefaults(suiteName: suite)!) == .recorded)
        let rows = try ModelContext(container).fetch(
            FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrivalDate)]))
        #expect(rows.count == 2)
        #expect(rows.first?.departureDate == closing.departureDate)
        #expect(await recorder.failedObservationCountForTesting == 0)
    }

    @Test("an owed Visit older than a wipe committed meanwhile is dropped")
    func owedVisitRespectsAcceptanceFloor() async throws {
        let (defaults, suite) = try Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = VisitRecorder(modelContainer: container)
        await recorder.setFaultsForTesting([.save])
        #expect(await recorder.record(
            Self.visit(arrivalHour: 1, departureHour: 3), defaults: UserDefaults(suiteName: suite)!) == .failed)

        defaults.set(Date(timeIntervalSinceReferenceDate: Self.start + 2 * 3_600),
                     forKey: VisitRecorder.acceptanceFloorKey)
        #expect(await recorder.retryFailedObservations(defaults: UserDefaults(suiteName: suite)!) == false)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Visit>()) == 0)
        #expect(await recorder.failedObservationCountForTesting == 0)
    }

    // MARK: - ACQ-003

    private static func liveCandidate(source: DataSource, offset: TimeInterval = 0) -> LiveLocationCandidate {
        LiveLocationCandidate(
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                course: -1, speed: -1,
                timestamp: Date(timeIntervalSinceReferenceDate: start + offset)),
            source: source)
    }

    @Test("a live fix coinciding with an imported row still lands with live provenance and its arrival check",
          arguments: [DataSource.photoImport, .sharedImport, .gpxImport, .timelineImport, .jsonImport])
    func liveFixIsNotSwallowedByImportedRow(imported: DataSource) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let cell = try #require(H3Service.cellIndex(latitude: Self.latitude, longitude: Self.longitude))
        let importedRow = LocationPing(
            timestamp: Date(timeIntervalSinceReferenceDate: Self.start),
            latitude: Self.latitude, longitude: Self.longitude, horizontalAccuracy: 10,
            h3IndexRes6: cell, source: imported)
        let importedID = importedRow.id
        context.insert(importedRow)
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        await recorder.processLocations(
            [Self.liveCandidate(source: .liveSLC)], defaults: TestSupport.liveFloorFreeDefaults)

        let pings = try ModelContext(container).fetch(FetchDescriptor<LocationPing>())
        #expect(pings.count == 2)
        #expect(pings.contains { $0.id == importedID && $0.source == imported })
        #expect(pings.contains { $0.id != importedID && $0.source == .liveSLC })
        #expect(await recorder.travelNotificationCheckCountForTesting == 1)
    }

    @Test("live redelivery of a stored live fix is still deduplicated")
    func liveRedeliveryStillDeduplicates() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let recorder = PingRecorder(modelContainer: container)
        await recorder.processLocations(
            [Self.liveCandidate(source: .foregroundStream)], defaults: TestSupport.liveFloorFreeDefaults)
        await recorder.processLocations(
            [Self.liveCandidate(source: .liveSLC, offset: 30)], defaults: TestSupport.liveFloorFreeDefaults)

        let pings = try ModelContext(container).fetch(FetchDescriptor<LocationPing>())
        #expect(pings.count == 1)
        #expect(pings.first?.source == .foregroundStream)
    }

    // MARK: - ACQ-001

    private nonisolated static let northAnswer = GeocodeResolver.Result(
        country: "Northland", isoCountryCode: "AA", administrativeArea: "North Region",
        metroName: nil, localityName: "North Town", subLocalityName: nil, islandName: nil)
    private nonisolated static let southAnswer = GeocodeResolver.Result(
        country: "Southland", isoCountryCode: "BB", administrativeArea: "South Region",
        metroName: nil, localityName: "South Town", subLocalityName: nil, islandName: nil)

    /// Two points of one res-6 cell, either side of its centre.
    private struct BorderCell {
        let cell: String
        let north: (latitude: Double, longitude: Double)
        let south: (latitude: Double, longitude: Double)
        let split: Double
    }

    private static func borderCell() throws -> BorderCell {
        let cell = try #require(H3Service.cellIndex(latitude: latitude, longitude: longitude))
        let centre = try #require(H3Service.centerCoordinate(for: cell))
        let north = (latitude: centre.latitude + 0.002, longitude: centre.longitude)
        let south = (latitude: centre.latitude - 0.002, longitude: centre.longitude)
        try #require(H3Service.cellIndex(latitude: north.latitude, longitude: north.longitude) == cell)
        try #require(H3Service.cellIndex(latitude: south.latitude, longitude: south.longitude) == cell)
        return BorderCell(cell: cell, north: north, south: south, split: centre.latitude)
    }

    /// The answer on either side of the split.
    private nonisolated static func sideAnswer(latitude: Double, split: Double) -> GeocodeResolver.Result {
        latitude > split ? northAnswer : southAnswer
    }

    @Test("the backlog drain gives every ping and stay of a cell the answer at its own coordinate")
    func hexDrainResolvesExactCoordinates() async throws {
        let border = try Self.borderCell()
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let base = Date(timeIntervalSinceReferenceDate: Self.start)
        // Whichever ping the cell starts from, the other must not take its answer.
        for (offset, point) in [(0.0, border.south), (60.0, border.north)] {
            context.insert(LocationPing(
                timestamp: base.addingTimeInterval(offset),
                latitude: point.latitude, longitude: point.longitude,
                horizontalAccuracy: 10, h3IndexRes6: border.cell, source: .photoImport))
        }
        let stay = Stay(startTime: base, endTime: base.addingTimeInterval(3_600),
            centroidLatitude: border.north.latitude, centroidLongitude: border.north.longitude,
            h3IndexRes6: border.cell, pingCount: 1, distanceFromHomeKm: 50, pingIDs: [])
        let stayID = stay.id
        context.insert(stay)
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        let split = border.split
        await recorder.setHexResolverForTesting { lat, _ in Self.sideAnswer(latitude: lat, split: split) }
        #expect(await recorder.geocodeByUniqueHex(gate: PipelineGate(forTesting: ())) == 2)

        let fresh = ModelContext(container)
        for ping in try fresh.fetch(FetchDescriptor<LocationPing>()) {
            let expected = Self.sideAnswer(latitude: ping.latitude, split: split)
            #expect(ping.isGeocoded)
            #expect(ping.isoCountryCode == expected.isoCountryCode)
            #expect(ping.locality == expected.localityName)
        }
        let row = try #require(try fresh.fetch(FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(row.isoCountryCode == "AA" && row.locality == "North Town")
    }

    @Test("the launch re-geocode never copies one point's answer to another point of its cell")
    func launchBackfillResolvesExactCoordinates() async throws {
        let border = try Self.borderCell()
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let base = Date(timeIntervalSinceReferenceDate: Self.start)
        for (offset, point) in [(0.0, border.south), (60.0, border.north), (120.0, border.south)] {
            context.insert(LocationPing(
                timestamp: base.addingTimeInterval(offset),
                latitude: point.latitude, longitude: point.longitude,
                horizontalAccuracy: 10, h3IndexRes6: border.cell, source: .liveSLC))
        }
        try context.save()

        let split = border.split
        let outcome = await GeocodeResolver.TestHook.$resolve.withValue({ lat, _ in
            Self.sideAnswer(latitude: lat, split: split)
        }) {
            await AppDelegate.backfillOfflineGeocoder(
                modelContainer: container, gate: PipelineGate(forTesting: ()))
        }
        #expect(outcome.saved)
        #expect(outcome.updatedPings == 3)
        for ping in try ModelContext(container).fetch(FetchDescriptor<LocationPing>()) {
            #expect(ping.isoCountryCode == Self.sideAnswer(latitude: ping.latitude, split: split).isoCountryCode)
        }
    }

    // MARK: - LIFE-002

    /// A country-less transit stay in a trip whose destination codes name `tripCode`.
    private static func seedTransitStay(
        in container: ModelContainer, knownISO: String?, tripCode: String
    ) throws -> UUID {
        let context = ModelContext(container)
        let base = Date(timeIntervalSinceReferenceDate: start)
        let trip = Trip(startDate: base)
        trip.countryCodes = tripCode
        context.insert(trip)
        let stay = Stay(startTime: base, endTime: base.addingTimeInterval(3_600),
            centroidLatitude: latitude, centroidLongitude: longitude,
            h3IndexRes6: "p07-transit-cell", pingCount: 0, distanceFromHomeKm: 80, pingIDs: [])
        stay.category = .transit
        stay.isoCountryCode = knownISO
        stay.trip = trip
        context.insert(stay)
        try context.save()
        return stay.id
    }

    private static func restoreCountry(
        in container: ModelContainer, offlineISO: String?
    ) async -> Bool {
        let offline = offlineISO.map {
            GeocodeResolver.Result(
                country: Locale(identifier: "en_US").localizedString(forRegionCode: $0),
                isoCountryCode: $0, administrativeArea: nil, metroName: nil,
                localityName: nil, subLocalityName: nil, islandName: nil)
        }
        return await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in offline }) {
            await AppDelegate.restoreWipedStayCountry(modelContainer: container).saved
        }
    }

    @Test("a stay that still knows its ISO gets that country's name, never the trip's or the resolver's")
    func knownISOWinsCountryRestore() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let stayID = try Self.seedTransitStay(in: container, knownISO: "FI", tripCode: "EE")
        #expect(await Self.restoreCountry(in: container, offlineISO: "EE"))
        let stay = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(stay.isoCountryCode == "FI")
        #expect(stay.country == Locale(identifier: "en_US").localizedString(forRegionCode: "FI")?.toLatinAscii)
    }

    @Test("a transit stay takes its centroid's country, and never a destination-only trip code",
          arguments: ["FI", nil] as [String?])
    func transitStayIgnoresTripCodes(offlineISO: String?) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let stayID = try Self.seedTransitStay(in: container, knownISO: nil, tripCode: "EE")
        #expect(await Self.restoreCountry(in: container, offlineISO: offlineISO))
        let stay = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(stay.isoCountryCode == offlineISO)
        #expect((stay.country == nil) == (offlineISO == nil))
    }

    // MARK: - LIFE-003

    @Test("the first syncing launch after a local-only one re-arms every latched dataset repair")
    func cloudTransitionRearmsDatasetRepairs() throws {
        let (defaults, suite) = try Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = AppDelegate.datasetRepairCompletionKeys
        #expect(keys.contains(AppDelegate.airportBackfillDatasetKey))
        #expect(keys.contains(AppDelegate.offlineGeocoderBackfillCompletedKey))
        #expect(keys.contains(AppDelegate.tripSummaryMetroRefreshCompletedKey))
        func latchAll() { for key in keys { defaults.set(true, forKey: key) } }
        func latched() -> Bool { keys.allSatisfy { defaults.bool(forKey: $0) } }
        func launch(cloud: Bool, persistent: Bool = true) -> Bool {
            AppDelegate.rearmDatasetRepairsOnCloudTransition(
                syncsWithCloud: cloud, isPersistentStore: persistent, defaults: defaults)
        }

        // A local-only first setup latches over its empty store.
        latchAll()
        #expect(!launch(cloud: false))
        #expect(latched())
        // The in-memory fallback records nothing.
        #expect(!launch(cloud: true, persistent: false))
        #expect(latched())
        // iCloud on at the next launch: every repair is owed again.
        #expect(launch(cloud: true))
        #expect(keys.allSatisfy { defaults.object(forKey: $0) == nil })
        // Later syncing launches keep what they latch.
        latchAll()
        #expect(!launch(cloud: true))
        #expect(latched())
        // Turning sync off never re-arms.
        #expect(!launch(cloud: false))
        #expect(latched())
    }

    @Test("a syncing launch with no recorded previous mode re-arms once, as an upgraded install must")
    func unrecordedSyncingLaunchRearmsOnce() throws {
        let (defaults, suite) = try Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let keys = AppDelegate.datasetRepairCompletionKeys
        func latchAll() { for key in keys { defaults.set(true, forKey: key) } }
        func latched() -> Bool { keys.allSatisfy { defaults.bool(forKey: $0) } }
        func launch(cloud: Bool, persistent: Bool = true) -> Bool {
            AppDelegate.rearmDatasetRepairsOnCloudTransition(
                syncsWithCloud: cloud, isPersistentStore: persistent, defaults: defaults)
        }

        // An older build latched these with iCloud already on but never
        // recorded its mode. The in-memory fallback still records nothing.
        latchAll()
        #expect(!launch(cloud: true, persistent: false))
        #expect(defaults.object(forKey: AppDelegate.lastLaunchSyncedWithCloudKey) == nil)
        #expect(latched())
        // The first persistent syncing launch cannot prove they ran over
        // synced history, so every repair is owed again.
        #expect(launch(cloud: true))
        #expect(defaults.object(forKey: AppDelegate.lastLaunchSyncedWithCloudKey) as? Bool == true)
        #expect(keys.allSatisfy { defaults.object(forKey: $0) == nil })
        // Only once: later syncing launches keep what they latch.
        latchAll()
        #expect(!launch(cloud: true))
        #expect(latched())
    }

    @Test("a local-only launch with no recorded previous mode records it without re-arming")
    func unrecordedLocalLaunchDoesNotRearm() throws {
        let (defaults, suite) = try Self.isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in AppDelegate.datasetRepairCompletionKeys { defaults.set(true, forKey: key) }
        #expect(!AppDelegate.rearmDatasetRepairsOnCloudTransition(
            syncsWithCloud: false, isPersistentStore: true, defaults: defaults))
        #expect(defaults.object(forKey: AppDelegate.lastLaunchSyncedWithCloudKey) as? Bool == false)
        #expect(AppDelegate.datasetRepairCompletionKeys.allSatisfy { defaults.bool(forKey: $0) })
    }

    // MARK: - GEO-001

    /// Two fictional homonyms, the more populous first.
    private static let fairhavens = [
        GeocodeResolver.ForwardCityHomonym(
            hit: .init(name: "Fairhaven", isoCountryCode: "AA", latitude: 44.3, longitude: 12.9),
            admin1Name: "West Province"),
        GeocodeResolver.ForwardCityHomonym(
            hit: .init(name: "Fairhaven", isoCountryCode: "AA", latitude: 45.3, longitude: 13.9),
            admin1Name: "East Province"),
    ]

    @Test("a named state or province picks its homonym, and an unmet one is a miss, never the largest")
    func admin1PartBindsOfflineHomonym() {
        #expect(ForwardGeocoder.firstHomonym(
            Self.fairhavens, isoCountryCode: nil, satisfying: [])?.latitude == 44.3)
        #expect(ForwardGeocoder.firstHomonym(
            Self.fairhavens, isoCountryCode: nil, satisfying: [],
            inAdmin1Named: ["east province"])?.latitude == 45.3)
        #expect(ForwardGeocoder.firstHomonym(
            Self.fairhavens, isoCountryCode: nil, satisfying: [],
            inAdmin1Named: ["north province"]) == nil)
    }

    private static func fairhavenResult(province: String, code: String, rank: Int) -> ForwardGeocoder.NetworkResult {
        ForwardGeocoder.NetworkResult(
            candidate: .init(rank: rank, name: "Fairhaven", address: "Fairhaven, \(code) 12345, Southland",
                             mapLocality: "Fairhaven", mapRegion: code, reverseLocality: "Fairhaven",
                             reverseAdministrativeArea: province, reverseCountry: "Southland"),
            isoCountryCode: "AA", admin1Name: province)
    }

    @Test("a network result outside a named state or province is never accepted")
    func admin1PartBindsNetworkResults() {
        let west = Self.fairhavenResult(province: "West Province", code: "WP", rank: 0)
        let east = Self.fairhavenResult(province: "East Province", code: "EP", rank: 1)
        let text = "Fairhaven, East Province"
        #expect(!ForwardGeocoder.networkAssessment(
            rawText: text, results: [west], admin1Parts: ["east province"]).isAccepted)
        let assessment = ForwardGeocoder.networkAssessment(
            rawText: text, results: [west, east], admin1Parts: ["east province"])
        if assessment.isAccepted { #expect(assessment.candidateRank == east.candidate.rank) }
        // A place the part itself names still satisfies it.
        #expect(ForwardGeocoder.satisfies(
            admin1Name: "Capital District", placeNames: ["East Province"], admin1Parts: ["east province"]))
        #expect(ForwardGeocoder.satisfies(admin1Name: "West Province", admin1Parts: []))
    }

    // MARK: - ACQ-002

    @Test("a state or province is recognized whatever its accents or case")
    func admin1NameIgnoresAccentsAndCase() async {
        #expect(await GeocodeResolver.shared.isAdmin1Name("Québec"))
        #expect(await GeocodeResolver.shared.isAdmin1Name("QUEBEC"))
        #expect(await GeocodeResolver.shared.isAdmin1Name("Korce County"))
        #expect(!(await GeocodeResolver.shared.isAdmin1Name("Fairhaven Province")))
    }

    @Test("a map cell's country and ISO stay one pair; a contradicting donor fills nothing")
    func hexPlaceMergeKeepsCountryPair() {
        func merge(_ row: (String?, String?, String?), _ donor: (String?, String?, String?))
            -> (locality: String?, country: String?, isoCountryCode: String?) {
            PingRecorder.mergedHexPlace(
                locality: row.0, country: row.1, isoCountryCode: row.2,
                donorLocality: donor.0, donorCountry: donor.1, donorISOCountryCode: donor.2)
        }
        let south: (String?, String?, String?) = ("South Town", "Southland", "BB")
        // Known country, missing ISO: another country's donor leaves the row as it was.
        let conflict = merge(("North Town", "Northland", nil), south)
        #expect(conflict.locality == "North Town" && conflict.country == "Northland" && conflict.isoCountryCode == nil)
        // Known ISO, missing country and locality: the same.
        let reverse = merge((nil, nil, "AA"), south)
        #expect(reverse.locality == nil && reverse.country == nil && reverse.isoCountryCode == "AA")
        // A compatible donor completes the row.
        let healed = merge((nil, "Northland", nil), ("North Town", "Northland", "AA"))
        #expect(healed.locality == "North Town" && healed.isoCountryCode == "AA")
        // A blank row takes the donor whole.
        let blank = merge((nil, nil, nil), south)
        #expect(blank.locality == "South Town" && blank.country == "Southland" && blank.isoCountryCode == "BB")
    }

    @Test("healing a country-only map cell next to a border never pairs it with the other country's ISO")
    func hexHealRejectsContradictingDonor() async throws {
        let border = try Self.borderCell()
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let hex = HexVisit(h3Index: border.cell, firstVisited: Date(timeIntervalSinceReferenceDate: Self.start),
                           centerLatitude: border.north.latitude, centerLongitude: border.north.longitude)
        hex.locality = "North Town"
        hex.country = "Northland"
        context.insert(hex)
        let donor = LocationPing(
            timestamp: Date(timeIntervalSinceReferenceDate: Self.start),
            latitude: border.south.latitude, longitude: border.south.longitude,
            horizontalAccuracy: 10, h3IndexRes6: border.cell)
        donor.applyResolverResult(Self.southAnswer)
        context.insert(donor)
        try context.save()

        let recorder = PingRecorder(modelContainer: container)
        _ = await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in Self.southAnswer }) {
            await recorder.backfillHexVisitCountries(gate: PipelineGate(forTesting: ()))
        }
        let row = try #require(try ModelContext(container).fetch(FetchDescriptor<HexVisit>()).first)
        #expect(row.country == "Northland")
        #expect(row.isoCountryCode == nil)
        #expect(row.locality == "North Town")
    }

    // MARK: - LIFE-004

    @Test("a geocoder that failed to open leaves the launch re-geocode and country restore owed")
    func unavailableGeocoderKeepsRepairsOwed() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(LocationPing(
            timestamp: Date(timeIntervalSinceReferenceDate: Self.start),
            latitude: Self.latitude, longitude: Self.longitude, horizontalAccuracy: 10,
            h3IndexRes6: "p07-unavailable-cell"))
        try context.save()

        let (backfill, restore) = await GeocodeResolver.TestHook.$unavailable.withValue(true) {
            (await AppDelegate.backfillOfflineGeocoder(
                modelContainer: container, gate: PipelineGate(forTesting: ())),
             await AppDelegate.restoreWipedStayCountry(modelContainer: container))
        }
        #expect(!backfill.saved)
        #expect(backfill.updatedPings == 0)
        #expect(!restore.saved)
        #expect(try ModelContext(container).fetch(FetchDescriptor<LocationPing>()).first?.isGeocoded == false)

        // Once it opens, the same pass completes.
        let recovered = await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in Self.southAnswer }) {
            await AppDelegate.backfillOfflineGeocoder(
                modelContainer: container, gate: PipelineGate(forTesting: ()))
        }
        #expect(recovered.saved)
        #expect(recovered.updatedPings == 1)
    }

    // MARK: - PERM-003

    @Test("a device without significant-change monitoring is never Fully Operational", arguments: [false, true])
    func unsupportedMonitoringIsNotOperational(available: Bool) {
        let status = TrackingStatus(
            authorizationStatus: { .authorizedAlways },
            accuracyAuthorization: { .fullAccuracy },
            backgroundRefreshStatus: { .available },
            significantChangeMonitoringAvailable: { available })
        #expect(status.isSignificantChangeMonitoringAvailable == available)
        #expect(status.issues.contains(.monitoringUnavailable) == !available)
        if !available {
            #expect(!status.isFullyOperational)
            #expect(!TrackingIssue.monitoringUnavailable.canOpenSettings)
            #expect(!TrackingIssue.monitoringUnavailable.canRequestPermission)
            #expect(!TrackingIssue.monitoringUnavailable.title.isEmpty)
            #expect(!TrackingIssue.monitoringUnavailable.description.isEmpty)
        }
    }

    // MARK: - PIMP-005

    @Test("the import row the screens show is the service's, not the earliest-started duplicate")
    func importScreensUseTheServiceRow() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let base = Date(timeIntervalSinceReferenceDate: Self.start)
        let completed = PhotoImportState(originDeviceID: "device-a")
        completed.id = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        completed.status = .completed
        completed.startedAt = base.addingTimeInterval(3_600)
        let paused = PhotoImportState(originDeviceID: "device-a")
        paused.id = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        paused.status = .paused
        paused.startedAt = base
        context.insert(completed)
        context.insert(paused)
        try context.save()

        // What the screens' query hands them: earliest start first.
        let rows = try ModelContext(container).fetch(FetchDescriptor<PhotoImportState>(
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]))
        #expect(rows.first?.status == .paused)
        let selected = try #require(PhotoImportStateSnapshot.selectState(from: rows))
        #expect(selected.id == completed.id)
        #expect(selected.status == .completed)
    }
}
