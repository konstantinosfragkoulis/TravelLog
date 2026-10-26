import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Classifier dependency read failures", IsolatedTitleDefaults())
struct ClassifierReadFailureTests {
    private func fixture(complete: Bool = false) throws -> (ModelContainer, UUID, PersistentIdentifier, UUID) {
        // TestSupport uses a separate temporaryStoreURL for every container.
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_723_587_200)
        let stay = Stay(startTime: start, endTime: start.addingTimeInterval(6 * 3600),
            centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "read-failure",
            pingCount: 2, distanceFromHomeKm: 200, pingIDs: [])
        stay.category = .destination
        stay.locality = "Athens"
        stay.country = "Greece"
        let trip = Trip(startDate: start)
        trip.customName = "Read failure fixture"
        trip.isComplete = complete
        if complete { trip.endDate = stay.endTime }
        context.insert(stay)
        context.insert(trip)
        stay.trip = trip
        stay.orderInTrip = 0
        context.insert(HiddenPhoto(localIdentifier: "retained-photo", tripID: trip.id))
        try context.save()
        return (container, trip.id, trip.persistentModelID, stay.id)
    }

    @Test("assembly rolls back incomplete-trip, trip-stay, home-boundary, edited-trip adoption and completed-trip read failures",
          arguments: [1, 2, 3, 4, 5])
    func assemblyReadFailureRetainsIdentity(fetchCall: Int) async throws {
        let (container, tripID, identifier, stayID) = try fixture()
        let classifier = TripClassifier(modelContainer: container)
        classifier.assemblyFetchFailureCallForTesting = fetchCall
        classifier.failAssemblyStayFetchForTesting = true
        defer { classifier.failAssemblyStayFetchForTesting = false }

        #expect(await classifier.assembleTrips() == -1)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(await classifier.baselinePassPending())
        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.count == 1)
        #expect(trips.first?.id == tripID)
        #expect(trips.first?.orders == [0])
        let check = ModelContext(container)
        let retained = try #require(check.fetch(FetchDescriptor<Trip>()).first)
        #expect(retained.id == tripID && retained.persistentModelID == identifier)
        #expect(try check.fetch(FetchDescriptor<Stay>()).first { $0.id == stayID }?.trip?.id == tripID)
        #expect(try check.fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID) == [tripID])
    }

    @Test("a failed edited-trip adoption read rolls back instead of minting a split trip")
    func adoptionReadFailureDoesNotSplitEditedTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_723_587_200)
        func destination(_ offset: TimeInterval, _ key: String) -> Stay {
            let stay = Stay(startTime: start.addingTimeInterval(offset),
                endTime: start.addingTimeInterval(offset + 6 * 3600),
                centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: key,
                pingCount: 2, distanceFromHomeKm: 200, pingIDs: [])
            stay.category = .destination
            stay.locality = "Athens"
            stay.country = "Greece"
            context.insert(stay)
            return stay
        }
        let first = destination(0, "adoption-first")
        let later = destination(24 * 3600, "adoption-later")
        let trip = Trip(startDate: start)
        trip.userEdited = true
        context.insert(trip)
        first.trip = trip
        first.orderInTrip = 0
        try context.save()
        let tripID = trip.id
        let laterID = later.id

        let classifier = TripClassifier(modelContainer: container)
        classifier.assemblyFetchFailureCallForTesting = 4
        classifier.failAssemblyStayFetchForTesting = true
        #expect(await classifier.assembleTrips() == -1)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(await classifier.assembledTripsForTesting().map(\.id) == [tripID])
        #expect(await classifier.tripStayIDsForTesting(tripID) == [first.id])

        // assembleTrips leaves saving to its caller, so read the classifier's context.
        classifier.failAssemblyStayFetchForTesting = false
        #expect(await classifier.assembleTrips() == 1)
        let trips = await classifier.assembledTripsForTesting()
        #expect(trips.map(\.id) == [tripID])
        #expect(trips.first?.orders == [0, 1])
        #expect(await classifier.tripStayIDsForTesting(tripID) == [first.id, laterID])
    }

    @Test("failed assembly or UUID restoration aborts the rebuild before replacement save",
          arguments: [false, true])
    func rebuildReadFailureDoesNotCommitReplacement(identityFailure: Bool) async throws {
        let (container, tripID, identifier, _) = try fixture(complete: true)
        let classifier = TripClassifier(modelContainer: container)
        classifier.failIdentityRestorationFetchForTesting = identityFailure
        classifier.failAssemblyStayFetchForTesting = !identityFailure
        defer {
            classifier.failIdentityRestorationFetchForTesting = false
            classifier.failAssemblyStayFetchForTesting = false
        }
        await StayClassificationInference.TestHook.$availability.withValue(true) {
            await StayClassificationInference.TestHook.$response.withValue({ _ in
                [.init(stayIndex: 0, category: "destination")]
            }) {
                await classifier.reclassifyAll(gate: PipelineGate(forTesting: ()),
                    beforeReplacementSave: { Issue.record("A failed dependency read must skip replacement save") })
            }
        }
        #expect(await classifier.baselinePassPending())
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        let check = ModelContext(container)
        let trips = try check.fetch(FetchDescriptor<Trip>())
        #expect(trips.count == 1)
        #expect(trips.first?.id == tripID)
        #expect(trips.first?.persistentModelID == identifier)
        #expect(try check.fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID) == [tripID])
    }

    @Test("ordinary pipeline skips back-half saves and rolls back staged sanity corrections")
    func pipelineAssemblyFailureSkipsSaveAndLatch() async throws {
        let (container, tripID, _, stayID) = try fixture()
        let seed = ModelContext(container)
        let stay = try #require(seed.fetch(FetchDescriptor<Stay>()).first)
        // Stage 2.5 would demote this short airport destination to transit.
        stay.isAirport = true
        try seed.save()
        let classifier = TripClassifier(modelContainer: container)
        classifier.failAssemblyStayFetchForTesting = true
        defer { classifier.failAssemblyStayFetchForTesting = false }
        let saves = OSAllocatedUnfairLock(initialState: 0)
        let result = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                reclassifyRecentStays: false, gate: PipelineGate(forTesting: ()), beforeSave: {
                    saves.withLock { $0 += 1 }
                })
        }
        #expect(result.created == 0 && result.needsPublication)
        #expect(saves.withLock { $0 } == 1, "Only preparation may save before the failed assembly")
        #expect(await classifier.baselinePassPending())
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        let check = ModelContext(container)
        let retained = try #require(check.fetch(FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(retained.category == .destination)
        #expect(retained.trip?.id == tripID)
        #expect(try check.fetch(FetchDescriptor<Trip>()).map(\.id) == [tripID])
        #expect(try check.fetch(FetchDescriptor<HiddenPhoto>()).map(\.tripID) == [tripID])
    }

    @Test("removing an include rolls back when un-homing cannot read or save", arguments: [false, true])
    func overrideRemovalFailureRetainsTeaching(saveFailure: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let row = HomeAreaOverride(kind: .include, centerLatitude: 0, centerLongitude: 0,
            radiusKm: 1, homeID: nil)
        let stay = Stay(startTime: .distantPast, endTime: .distantPast.addingTimeInterval(7200),
            centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "protected",
            pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
        stay.category = .home
        stay.userOverridden = true
        context.insert(row)
        context.insert(stay)
        try context.save()
        let classifier = TripClassifier(modelContainer: container)
        classifier.failUnHomeStaysFetchForTesting = !saveFailure
        defer { classifier.failUnHomeStaysFetchForTesting = false }
        if saveFailure { await classifier.failNextUnHomeStaysSaveForTesting() }
        #expect(await classifier.removeOverride(id: row.id) == false)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        let check = ModelContext(container)
        #expect(try check.fetch(FetchDescriptor<HomeAreaOverride>()).map(\.id) == [row.id])
        let retained = try #require(check.fetch(FetchDescriptor<Stay>()).first)
        #expect(retained.category == .home)
        #expect(retained.userOverridden)
    }

    @Test("exclusion reports un-home failure and rolls back the inserted override")
    func exclusionReadFailureIsReported() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let classifier = TripClassifier(modelContainer: container)
        classifier.failUnHomeStaysFetchForTesting = true
        defer { classifier.failUnHomeStaysFetchForTesting = false }
        let place = TripClassifier.LearnedPlace(latitude: 0, longitude: 0, radiusKm: 1,
            returnCount: 3, firstReturn: nil, homeID: nil)
        #expect(await classifier.excludeLearnedPlace(place) == false)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<HomeAreaOverride>()) == 0)
    }

    @Test("Stage 1 home read failure leaves stays unclassified and mints no trip")
    func preFilterHomeReadFailureRollsBack() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(Home(label: "Home", latitude: 0, longitude: 0, radiusKm: 25,
            startedAt: start.addingTimeInterval(-86_400 * 100)))
        // Six days would resolve deterministically as a destination if pre-filter missed home.
        let stay = Stay(startTime: start, endTime: start.addingTimeInterval(6 * 86_400),
            centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "home",
            pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
        context.insert(stay)
        try context.save()
        let stayID = stay.id
        let classifier = TripClassifier(modelContainer: container)
        classifier.failHomeReadForTesting = true
        defer { classifier.failHomeReadForTesting = false }
        await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.classifyAndAssembleTripsWithGates(reclassifyRecentStays: false,
                maxStaysPerCall: nil, gate: PipelineGate(forTesting: ()))
        }
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        var check = ModelContext(container)
        #expect(try check.fetch(FetchDescriptor<Stay>()).first { $0.id == stayID }?.category == .unclassified)
        #expect(try check.fetchCount(FetchDescriptor<Trip>()) == 0)

        classifier.failHomeReadForTesting = false
        await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.classifyAndAssembleTripsWithGates(reclassifyRecentStays: false,
                maxStaysPerCall: nil, gate: PipelineGate(forTesting: ()))
        }
        check = ModelContext(container)
        #expect(try check.fetch(FetchDescriptor<Stay>()).first { $0.id == stayID }?.category == .home)
        #expect(try check.fetchCount(FetchDescriptor<Trip>()) == 0)
    }

    @Test("assembly home read failure rolls back and mints no trip at home")
    func assemblyHomeReadFailureRollsBack() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(Home(label: "Home", latitude: 0, longitude: 0, radiusKm: 25,
            startedAt: start.addingTimeInterval(-86_400 * 100)))
        let stay = Stay(startTime: start, endTime: start.addingTimeInterval(6 * 86_400),
            centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "home",
            pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
        stay.category = .destination
        context.insert(stay)
        try context.save()
        let classifier = TripClassifier(modelContainer: container)
        classifier.failHomeReadForTesting = true
        defer { classifier.failHomeReadForTesting = false }

        #expect(await classifier.assembleTrips() == -1)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<Trip>()) == 0)
    }

    @Test("home change rolls back on an all-homes read failure")
    func homeChangeHomeReadFailureRetainsHomeStays() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(Home(label: "A", latitude: 0, longitude: 0, radiusKm: 25,
            startedAt: start.addingTimeInterval(-86_400 * 100)))
        let edited = Home(label: "B", latitude: 2, longitude: 0, radiusKm: 25,
            startedAt: start.addingTimeInterval(-86_400 * 100))
        context.insert(edited)
        let stay = Stay(startTime: start, endTime: start.addingTimeInterval(7200),
            centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "home",
            pingCount: 2, distanceFromHomeKm: 0.5, pingIDs: [])
        stay.category = .home
        context.insert(stay)
        try context.save()
        let stayID = stay.id
        let classifier = TripClassifier(modelContainer: container)
        classifier.failHomeReadForTesting = true
        defer { classifier.failHomeReadForTesting = false }
        #expect(await classifier.applyHomeChangeCore(homeID: edited.id) == .failed)
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        let retained = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>())
            .first { $0.id == stayID })
        #expect(retained.category == .home)
        #expect(retained.distanceFromHomeKm == 0.5)
    }
}
