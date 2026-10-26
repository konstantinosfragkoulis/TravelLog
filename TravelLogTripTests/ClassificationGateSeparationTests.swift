import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Classification gate separation", IsolatedTitleDefaults(), .timeLimit(.minutes(1)))
struct ClassificationGateSeparationTests {
    private func fixture() throws -> (ModelContainer, UUID) {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let stay = Stay(startTime: start, endTime: start.addingTimeInterval(6 * 3600),
            centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "classification-gate",
            pingCount: 2, distanceFromHomeKm: 200, pingIDs: [])
        stay.locality = "Athens"
        stay.country = "Greece"
        context.insert(stay)
        try context.save()
        return (container, stay.id)
    }

    @Test("an independent writer completes while inference waits, and stale evidence is rejected",
          arguments: ["unrelated", "edit", "override", "replace", "neighbor", "home", "routine", "homeOverride"])
    func inferenceDoesNotHoldGateAndRejectsChangedInput(change: String) async throws {
        let (container, stayID) = try fixture()
        let seed = ModelContext(container)
        if change == "home" {
            seed.insert(Home(label: "Distant home", latitude: 50, longitude: 50,
                radiusKm: 25.1, startedAt: .distantPast))
        }
        if change == "routine" {
            seed.insert(RoutinePlace(label: "Work", latitude: 50, longitude: 50, startedAt: .distantPast))
        }
        if change == "homeOverride" {
            seed.insert(HomeAreaOverride(kind: .include, centerLatitude: 50, centerLongitude: 50,
                radiusKm: 1, homeID: nil))
        }
        try seed.save()
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let result = await StayClassificationInference.TestHook.$availability.withValue(true) {
            await StayClassificationInference.TestHook.$response.withValue({ _ in
                // Waiting for this gate unit is the deterministic admission proof.
                // Holding the outer writer gate during respond would deadlock.
                await gate.run(touching: [.stay]) {
                    await MainActor.run {
                        let context = ModelContext(container)
                        guard let stay = try? context.fetch(FetchDescriptor<Stay>()).first else {
                            Issue.record("Missing seeded stay"); return
                        }
                        if change == "home", let home = try? context.fetch(FetchDescriptor<Home>()).first {
                            home.radiusKm = 25.2 // Identical Int-rounded model prompt.
                        }
                        if change == "routine", let place = try? context.fetch(FetchDescriptor<RoutinePlace>()).first {
                            place.latitude = 0 // Prompt renders labels only.
                        }
                        if change == "homeOverride", let row = try? context.fetch(FetchDescriptor<HomeAreaOverride>()).first {
                            row.radiusKm = 2 // Not rendered in the model prompt.
                        }
                        if change == "edit" { stay.locality = "Rome" }
                        if change == "override" { stay.userOverridden = true; stay.category = .destination }
                        if change == "replace" || change == "neighbor" {
                            let copy = Stay(startTime: stay.startTime, endTime: stay.endTime,
                                centroidLatitude: stay.centroidLatitude, centroidLongitude: stay.centroidLongitude,
                                h3IndexRes6: stay.h3IndexRes6, pingCount: 2, distanceFromHomeKm: 200, pingIDs: [])
                            copy.locality = stay.locality
                            copy.country = stay.country
                            if change == "replace" { copy.id = stay.id; context.delete(stay) }
                            context.insert(copy)
                        }
                        do { try context.save() } catch { Issue.record(error) }
                    }
                }
                return [.init(stayIndex: 0, category: "transit")]
            }) {
                await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                    reclassifyRecentStays: false, gate: gate)
            }
        }
        let rows = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        let stay = try #require(rows.first { $0.id == stayID })
        #expect(stay.category == (change == "unrelated" ? .transit : change == "override" ? .destination : .unclassified))
        if change == "unrelated" { #expect(result.needsPublication) }
    }

    @Test("a settled owned-gate pass retains the no-publication outcome")
    func settledPassPublishesNothing() async throws {
        let (container, _) = try fixture()
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        await StayClassificationInference.TestHook.$availability.withValue(false) {
            _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                reclassifyRecentStays: false, gate: gate)
            let second = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                reclassifyRecentStays: false, gate: gate)
            #expect(!second.needsPublication)
        }
    }

    @Test("the finish stage reads stays only when the pass has outcomes to credit",
          arguments: [false, true])
    func finishStageFetchIsBoundedToOutcomes(unclassified: Bool) async throws {
        let (container, _) = try fixture()
        if !unclassified {
            let context = ModelContext(container)
            let first = try #require(context.fetch(FetchDescriptor<Stay>()).first)
            first.category = .destination
            for index in 1...5 {
                let start = first.startTime.addingTimeInterval(Double(index) * 86400)
                let stay = Stay(startTime: start, endTime: start.addingTimeInterval(21600),
                    centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "settled-\(index)",
                    pingCount: 2, distanceFromHomeKm: 200, pingIDs: [])
                stay.category = .destination
                context.insert(stay)
            }
            try context.save()
        }
        let fetches = OSAllocatedUnfairLock(initialState: 0)
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        await TripClassifier.CalendarTestHook.$finishStaysFetched.withValue({
            fetches.withLock { $0 += 1 }
        }) {
            await StayClassificationInference.TestHook.$availability.withValue(true) {
                await StayClassificationInference.TestHook.$response.withValue({ _ in
                    [.init(stayIndex: 0, category: "destination")]
                }) {
                    _ = await classifier.classifyAndAssembleTripsWithGates(reclassifyRecentStays: false, gate: gate)
                }
            }
        }
        #expect(fetches.withLock { $0 } == (unclassified ? 1 : 0))
    }

    @Test("model classifications preserve their provenance through fresh-context apply and assembly")
    func acceptedModelOutputPreservesProvenance() async throws {
        let (container, _) = try fixture()
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        await StayClassificationInference.TestHook.$availability.withValue(true) {
            await StayClassificationInference.TestHook.$response.withValue({ _ in
                [.init(stayIndex: 0, category: "destination")]
            }) {
                _ = await classifier.classifyAndAssembleTripsWithGates(reclassifyRecentStays: false, gate: gate)
            }
        }
        let trips = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        #expect(trips.count == 1)
        #expect(trips.first?.classifiedByAI == true)
    }
    @Test("rebuild retains photo annotation ownership while inference is suspended",
          arguments: ["success", "cancel", "saveFailure"])
    func rebuildKeepsIdentityDuringInference(outcome: String) async throws {
        let (container, _) = try fixture()
        let context = ModelContext(container)
        let stay = try #require(context.fetch(FetchDescriptor<Stay>()).first)
        stay.category = .destination
        let trip = Trip(startDate: stay.startTime)
        trip.endDate = stay.endTime
        trip.isComplete = true
        context.insert(trip)
        trip.stays = [stay]
        stay.trip = trip
        let retained = Trip(startDate: stay.startTime.addingTimeInterval(-86400))
        retained.userEdited = true
        context.insert(retained)
        let hidden = HiddenPhoto(localIdentifier: "retained-hidden", tripID: trip.id)
        let pinned = PinnedPhoto(localIdentifier: "retained-pinned", tripID: trip.id)
        context.insert(hidden)
        context.insert(pinned)
        try context.save()
        let tripID = trip.id
        let tripIdentifier = trip.persistentModelID
        let retainedIdentifier = retained.persistentModelID
        let retainedID = retained.id
        let suite = "classification-orphans-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set([hidden.id.uuidString: now.addingTimeInterval(-172800).timeIntervalSince1970,
                      pinned.id.uuidString: now.addingTimeInterval(-172800).timeIntervalSince1970],
                     forKey: "orphanFirstObserved_v1")
        let invocations = OSAllocatedUnfairLock(initialState: (responses: 0, saves: 0))
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        await StayClassificationInference.TestHook.$availability.withValue(true) {
            await StayClassificationInference.TestHook.$response.withValue({ _ in
                invocations.withLock { $0.responses += 1 }
                await gate.run(touching: []) {
                    await PhotoAnnotationDeduplicator.removeOrphans(modelContainer: container,
                        now: now, defaults: UserDefaults(suiteName: suite)!)
                    await MainActor.run {
                        let check = ModelContext(container)
                        #expect((try? check.fetch(FetchDescriptor<Trip>()))?.contains { $0.id == tripID } == true)
                        #expect((try? check.fetchCount(FetchDescriptor<HiddenPhoto>())) == 1)
                        #expect((try? check.fetchCount(FetchDescriptor<PinnedPhoto>())) == 1)
                    }
                }
                if outcome == "cancel" { withUnsafeCurrentTask { $0?.cancel() } }
                return [.init(stayIndex: 0, category: "destination")]
            }) {
                // Isolate the deliberate cancellation from the test runner task.
                await Task {
                    if outcome == "saveFailure" {
                        await classifier.reclassifyAll(gate: gate, beforeReplacementSave: {
                            invocations.withLock { $0.saves += 1 }
                            throw CocoaError(.fileWriteUnknown)
                        })
                    } else {
                        await classifier.reclassifyAll(gate: gate)
                    }
                }.value
            }
        }
        #expect(invocations.withLock { $0.responses } == 1)
        #expect(invocations.withLock { $0.saves } == (outcome == "saveFailure" ? 1 : 0))
        let check = ModelContext(container)
        let surviving = try #require(check.fetch(FetchDescriptor<Trip>()).first { $0.id == tripID })
        if outcome != "success" { #expect(surviving.persistentModelID == tripIdentifier) }
        let retainedTrip = try #require(check.fetch(FetchDescriptor<Trip>()).first { $0.id == retainedID })
        #expect(retainedTrip.persistentModelID == retainedIdentifier)
        #expect(retainedTrip.userEdited)
        #expect(try check.fetchCount(FetchDescriptor<HiddenPhoto>()) == 1)
        #expect(try check.fetchCount(FetchDescriptor<PinnedPhoto>()) == 1)
    }

    @Test("a rejected rebuild batch keeps the trip identity and its annotations")
    func rejectedRebuildBatchKeepsIdentity() async throws {
        let (container, stayID) = try fixture()
        let context = ModelContext(container)
        let stay = try #require(context.fetch(FetchDescriptor<Stay>()).first)
        stay.category = .destination
        let trip = Trip(startDate: stay.startTime)
        trip.endDate = stay.endTime
        trip.isComplete = true
        context.insert(trip)
        trip.stays = [stay]
        stay.trip = trip
        context.insert(HiddenPhoto(localIdentifier: "rejected-hidden", tripID: trip.id))
        context.insert(PinnedPhoto(localIdentifier: "rejected-pinned", tripID: trip.id))
        try context.save()
        let tripID = trip.id
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        await StayClassificationInference.TestHook.$availability.withValue(true) {
            await StayClassificationInference.TestHook.$response.withValue({ _ in
                await gate.run(touching: [.stay]) {
                    await MainActor.run {
                        let context = ModelContext(container)
                        guard let stay = try? context.fetch(FetchDescriptor<Stay>()).first else {
                            Issue.record("Missing seeded stay"); return
                        }
                        stay.locality = "Rome"
                        do { try context.save() } catch { Issue.record(error) }
                    }
                }
                return [.init(stayIndex: 0, category: "destination")]
            }) {
                await classifier.reclassifyAll(gate: gate)
            }
        }
        let check = ModelContext(container)
        let trips = try check.fetch(FetchDescriptor<Trip>())
        let surviving = try #require(trips.first { $0.id == tripID })
        let current = try #require(check.fetch(FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(current.trip?.id == surviving.id)
        #expect(current.category != .unclassified)
        let tripIDs = Set(trips.map(\.id))
        #expect(try check.fetch(FetchDescriptor<HiddenPhoto>()).allSatisfy { tripIDs.contains($0.tripID) })
        #expect(try check.fetch(FetchDescriptor<PinnedPhoto>()).allSatisfy { tripIDs.contains($0.tripID) })
    }

    @Test("an ordinary pass leaves attached reset stays outside its batch for later model passes")
    func strandedFallbackStaysWithinBatch() async throws {
        let (container, _) = try fixture()
        let context = ModelContext(container)
        let first = try #require(context.fetch(FetchDescriptor<Stay>()).first)
        let trip = Trip(startDate: first.startTime)
        trip.isComplete = true
        context.insert(trip)
        var stays = [first]
        for day in 1...2 {
            let start = first.startTime.addingTimeInterval(Double(day) * 86_400)
            let stay = Stay(startTime: start, endTime: start.addingTimeInterval(6 * 3600),
                centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "classification-gate",
                pingCount: 2, distanceFromHomeKm: 200, pingIDs: [])
            stay.locality = "Athens"
            stay.country = "Greece"
            context.insert(stay)
            stays.append(stay)
        }
        trip.endDate = stays.last?.endTime
        trip.stays = stays
        for stay in stays { stay.trip = trip }
        try context.save()
        let laterIDs = Set(stays.dropFirst().map(\.id))
        let classifier = TripClassifier(modelContainer: container)
        _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
            reclassifyRecentStays: false, maxStaysPerCall: 1, gate: PipelineGate(forTesting: ()),
            fmAvailable: true, response: { _ in [.init(stayIndex: 0, category: "destination")] })
        let rows = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        let later = rows.filter { laterIDs.contains($0.id) }
        #expect(later.count == 2)
        #expect(later.allSatisfy { $0.category == .unclassified })
    }

    /// Two reset members of one trip; `covered` sits where coverage will arrive during inference.
    private func strandedTripFixture(rebuild: Bool) throws
        -> (container: ModelContainer, coveredID: UUID, otherID: UUID, tripID: UUID) {
        let (container, coveredID) = try fixture()
        let context = ModelContext(container)
        let covered = try #require(context.fetch(FetchDescriptor<Stay>()).first)
        let start = covered.startTime.addingTimeInterval(86_400)
        let other = Stay(startTime: start, endTime: start.addingTimeInterval(6 * 3600),
            centroidLatitude: 10, centroidLongitude: 10, h3IndexRes6: "classification-gate-other",
            pingCount: 2, distanceFromHomeKm: 200, pingIDs: [])
        other.locality = "Xánthi"
        other.country = "Greece"
        context.insert(other)
        let trip = Trip(startDate: covered.startTime)
        context.insert(trip)
        trip.stays = [covered, other]
        covered.trip = trip
        other.trip = trip
        if rebuild {
            covered.category = .destination
            other.category = .destination
            trip.endDate = other.endTime
            trip.isComplete = true
            context.insert(HiddenPhoto(localIdentifier: "stranded-hidden", tripID: trip.id))
        }
        try context.save()
        return (container, coveredID, other.id, trip.id)
    }

    @Test("a stranded trip stay honours home or routine coverage that arrived during inference",
          arguments: [("routine", false), ("home", false), ("routine", true)])
    func strandedFallbackHonoursArrivingCoverage(coverage: String, rebuild: Bool) async throws {
        let (container, coveredID, otherID, tripID) = try strandedTripFixture(rebuild: rebuild)
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        await StayClassificationInference.TestHook.$availability.withValue(true) {
            await StayClassificationInference.TestHook.$response.withValue({ _ in
                // An ungated writer, as a CloudKit import is, lands coverage mid-inference.
                await MainActor.run {
                    let context = ModelContext(container)
                    if coverage == "routine" {
                        context.insert(RoutinePlace(label: "Gym", latitude: 0, longitude: 0,
                            startedAt: .distantPast))
                    } else {
                        context.insert(Home(label: "Home", latitude: 0, longitude: 0,
                            radiusKm: 1, startedAt: .distantPast))
                    }
                    do { try context.save() } catch { Issue.record(error) }
                }
                return [.init(stayIndex: 0, category: "destination"),
                        .init(stayIndex: 1, category: "destination")]
            }) {
                if rebuild {
                    await classifier.reclassifyAll(gate: gate)
                } else {
                    _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                        reclassifyRecentStays: false, gate: gate)
                }
            }
        }
        let expected: StayCategory = coverage == "routine" ? .routine : .home
        var rows = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        var covered = try #require(rows.first { $0.id == coveredID })
        var other = try #require(rows.first { $0.id == otherID })
        #expect(covered.category == expected)
        #expect(covered.trip == nil)
        #expect(other.category == .destination)
        if coverage == "routine" { #expect(other.trip?.id == tripID) }

        // A later ordinary pass keeps the settled outcome.
        await StayClassificationInference.TestHook.$availability.withValue(false) {
            _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                reclassifyRecentStays: false, gate: gate)
        }
        let check = ModelContext(container)
        rows = try check.fetch(FetchDescriptor<Stay>())
        covered = try #require(rows.first { $0.id == coveredID })
        other = try #require(rows.first { $0.id == otherID })
        #expect(covered.category == expected)
        #expect(other.category == .destination)
        if rebuild {
            let tripIDs = Set(try check.fetch(FetchDescriptor<Trip>()).map(\.id))
            #expect(tripIDs.contains(tripID))
            #expect(try check.fetch(FetchDescriptor<HiddenPhoto>()).allSatisfy { tripIDs.contains($0.tripID) })
        }
    }

    @Test("an unreadable coverage table leaves stranded trip stays unclassified for a retry",
          arguments: ["routine", "home"])
    func strandedFallbackRetriesAfterCoverageReadFailure(failing: String) async throws {
        let (container, coveredID, otherID, tripID) = try strandedTripFixture(rebuild: false)
        let classifier = TripClassifier(modelContainer: container)
        defer {
            classifier.failRoutineReadForTesting = false
            classifier.failHomeReadForTesting = false
        }
        let gate = PipelineGate(forTesting: ())
        _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
            reclassifyRecentStays: false, gate: gate, fmAvailable: true, response: { _ in
                await MainActor.run {
                    let context = ModelContext(container)
                    context.insert(RoutinePlace(label: "Gym", latitude: 0, longitude: 0,
                        startedAt: .distantPast))
                    do { try context.save() } catch { Issue.record(error) }
                }
                if failing == "routine" {
                    classifier.failRoutineReadForTesting = true
                } else {
                    classifier.failHomeReadForTesting = true
                }
                return [.init(stayIndex: 0, category: "destination"),
                        .init(stayIndex: 1, category: "destination")]
            })
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)
        var rows = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        var covered = try #require(rows.first { $0.id == coveredID })
        var other = try #require(rows.first { $0.id == otherID })
        #expect(covered.category == .unclassified)
        #expect(other.category == .unclassified)
        #expect(covered.trip?.id == tripID)
        #expect(other.trip?.id == tripID)

        classifier.failRoutineReadForTesting = false
        classifier.failHomeReadForTesting = false
        await StayClassificationInference.TestHook.$availability.withValue(false) {
            _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                reclassifyRecentStays: false, gate: gate)
        }
        rows = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        covered = try #require(rows.first { $0.id == coveredID })
        other = try #require(rows.first { $0.id == otherID })
        #expect(covered.category == .routine)
        #expect(covered.trip == nil)
        #expect(other.category == .destination)
        #expect(other.trip?.id == tripID)
    }

    @Test("an earlier batch override cannot retain stale model provenance")
    func earlierBatchOverrideDropsModelCredit() async throws {
        let (container, firstID) = try fixture()
        let context = ModelContext(container)
        let first = try #require(context.fetch(FetchDescriptor<Stay>()).first)
        // Trips split only at home boundaries, not at an unobserved time gap.
        // Keep the overridden first stay out of the later legitimately FM trip.
        let homeStart = first.endTime.addingTimeInterval(86400)
        let boundary = Stay(startTime: homeStart, endTime: homeStart.addingTimeInterval(21600),
            centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "home-boundary",
            pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
        boundary.category = .home
        boundary.userOverridden = true
        context.insert(boundary)
        for index in 0..<20 {
            let start = first.startTime.addingTimeInterval(365 * 86400 + Double(index) * 43200)
            let stay = Stay(startTime: start, endTime: start.addingTimeInterval(21600),
                centroidLatitude: 1, centroidLongitude: 1, h3IndexRes6: "later-\(index)",
                pingCount: 2, distanceFromHomeKm: 200, pingIDs: [])
            stay.locality = "Rome"
            stay.country = "Italy"
            context.insert(stay)
        }
        try context.save()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        await StayClassificationInference.TestHook.$availability.withValue(true) {
            await StayClassificationInference.TestHook.$response.withValue({ _ in
                let call = calls.withLock { value in value += 1; return value }
                if call == 2 {
                    await gate.run(touching: [.stay]) {
                        await MainActor.run {
                            let writer = ModelContext(container)
                            guard let row = try? writer.fetch(FetchDescriptor<Stay>()).first(where: { $0.id == firstID }) else {
                                Issue.record("Missing earlier batch stay"); return
                            }
                            row.userOverridden = true
                            row.category = .destination
                            do { try writer.save() } catch { Issue.record(error) }
                        }
                    }
                }
                return (0..<(call == 1 ? 20 : 1)).map {
                    .init(stayIndex: $0, category: "transit")
                }
            }) {
                _ = await classifier.classifyAndAssembleTripsWithGates(reclassifyRecentStays: false,
                    maxStaysPerCall: nil, gate: gate)
            }
        }
        #expect(calls.withLock { $0 } == 2)
        let check = ModelContext(container)
        let original = try #require(check.fetch(FetchDescriptor<Stay>()).first { $0.id == firstID })
        let trip = try #require(original.trip)
        #expect(original.userOverridden)
        #expect(Set((trip.stays ?? []).map(\.id)) == [firstID])
        #expect(!trip.classifiedByAI)
        let later = try check.fetch(FetchDescriptor<Stay>()).filter { $0.locality == "Rome" }
        #expect(later.count == 20)
        #expect(later.allSatisfy { $0.category == .transit })
    }

    @Test("revoking calendar evidence discards the hinted batch and still commits the hint-free batch")
    func calendarRevocationIsScopedToHintedBatch() async throws {
        let (container, hintedID) = try fixture()
        let context = ModelContext(container)
        let first = try #require(context.fetch(FetchDescriptor<Stay>()).first)
        first.source = .photoImport
        var lastID = hintedID
        for index in 1...20 {
            let start = first.startTime.addingTimeInterval(Double(index) * 86400)
            let stay = Stay(startTime: start, endTime: start.addingTimeInterval(21600),
                centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "calendar-\(index)",
                pingCount: 2, distanceFromHomeKm: 200, pingIDs: [])
            context.insert(stay)
            lastID = stay.id
        }
        try context.save()
        let authority = ForwardGeocoder.RequestAuthority()
        let calls = OSAllocatedUnfairLock(initialState: (responses: 0, authorities: 0, timelines: 0))
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        await TripClassifier.CalendarTestHook.$hints.withValue([hintedID: "Athens conference"]) {
            await TripClassifier.CalendarTestHook.$authority.withValue(authority) {
                await TripClassifier.CalendarTestHook.$authorityRequested.withValue({
                    calls.withLock { $0.authorities += 1 }
                }) {
                    await TripClassifier.CalendarTestHook.$timelineFetched.withValue({
                        calls.withLock { $0.timelines += 1 }
                    }) {
                        await StayClassificationInference.TestHook.$availability.withValue(true) {
                            await StayClassificationInference.TestHook.$response.withValue({ prompt in
                                let call = calls.withLock { $0.responses += 1; return $0.responses }
                                #expect(prompt.contains("CALENDAR:") == (call == 1))
                                authority.revoke()
                                return (0..<(call == 1 ? 20 : 1)).map {
                                    .init(stayIndex: $0, category: "transit")
                                }
                            }) {
                                _ = await classifier.classifyAndAssembleTripsWithGates(
                                    reclassifyRecentStays: false, maxStaysPerCall: nil, gate: gate)
                            }
                        }
                    }
                }
            }
        }
        #expect(calls.withLock { $0.responses } == 2)
        #expect(calls.withLock { $0.authorities } == 1)
        #expect(calls.withLock { $0.timelines } == 1)
        let rows = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(rows.count == 21)
        #expect(rows.filter { $0.id != lastID }.allSatisfy { $0.category == .unclassified })
        #expect(rows.first { $0.id == lastID }?.category == .transit)
    }

    @Test("bounded dependencies reject neighbour edits but accept distant stay writes",
          arguments: ["unrelatedEdit", "unrelatedInsert", "neighborDelete", "neighborMove", "neighborInsert"])
    func boundedDependencyWrites(change: String) async throws {
        let (container, stayID) = try fixture()
        let seed = ModelContext(container)
        let first = try #require(seed.fetch(FetchDescriptor<Stay>()).first)
        var nearbyID = stayID
        var distantID = stayID
        for index in 1...6 {
            let start = first.startTime.addingTimeInterval(Double(index) * 86400)
            let stay = Stay(startTime: start, endTime: start.addingTimeInterval(21600),
                centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "dependency-\(index)",
                pingCount: 2, distanceFromHomeKm: 200, pingIDs: [])
            stay.category = .home
            stay.userOverridden = true
            seed.insert(stay)
            if index == 1 { nearbyID = stay.id }
            distantID = stay.id
        }
        try seed.save()
        let neighborID = nearbyID
        let unrelatedID = distantID
        let gate = PipelineGate(forTesting: ())
        let classifier = TripClassifier(modelContainer: container)
        await StayClassificationInference.TestHook.$availability.withValue(true) {
            await StayClassificationInference.TestHook.$response.withValue({ _ in
                await gate.run(touching: [.stay]) {
                    await MainActor.run {
                        let writer = ModelContext(container)
                        do {
                            let rows = try writer.fetch(FetchDescriptor<Stay>())
                            let id = change.hasPrefix("unrelated") ? unrelatedID : neighborID
                            let row = try #require(rows.first { $0.id == id })
                            if change == "neighborDelete" { writer.delete(row) }
                            if change == "neighborMove" { row.startTime = row.startTime.addingTimeInterval(999999) }
                            if change == "unrelatedEdit" { row.endTime = row.endTime.addingTimeInterval(3600) }
                            if change.hasSuffix("Insert") {
                                let start = row.startTime.addingTimeInterval(60)
                                let added = Stay(startTime: start, endTime: start.addingTimeInterval(21600),
                                    centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "inserted",
                                    pingCount: 2, distanceFromHomeKm: 200, pingIDs: [])
                                writer.insert(added)
                            }
                            try writer.save()
                        } catch { Issue.record(error) }
                    }
                }
                return [.init(stayIndex: 0, category: "transit")]
            }) {
                _ = await classifier.classifyAndAssembleTripsWithGates(reclassifyRecentStays: false, gate: gate)
            }
        }
        let row = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(row.category == (change.hasPrefix("unrelated") ? .transit : .unclassified))
    }

    @Test("a rolled-back batch save retains conservative publication after clean assembly")
    func failedBatchSavePublishesAndRollsBack() async throws {
        let (container, stayID) = try fixture()
        let classifier = TripClassifier(modelContainer: container)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let gate = PipelineGate(forTesting: ())
        let result = await StayClassificationInference.TestHook.$availability.withValue(true) {
            await StayClassificationInference.TestHook.$response.withValue({ _ in
                [.init(stayIndex: 0, category: "destination")]
            }) {
                await classifier.classifyAndAssembleTripsReportingChangesWithGates(
                    reclassifyRecentStays: false, gate: gate, beforeSave: {
                        let call = calls.withLock { $0 += 1; return $0 }
                        if call == 2 { throw CocoaError(.fileWriteUnknown) }
                    })
            }
        }
        #expect(result.created == 0 && result.needsPublication)
        let check = ModelContext(container)
        #expect(try check.fetch(FetchDescriptor<Stay>()).first { $0.id == stayID }?.category == .unclassified)
        #expect(try check.fetchCount(FetchDescriptor<Trip>()) == 0)
    }

    @Test("fallback look-ahead beyond the prompt window is validated",
          arguments: [false, true])
    func heuristicLookAheadIsADependency(change: Bool) async throws {
        let (container, stayID) = try fixture()
        let seed = ModelContext(container)
        let first = try #require(seed.fetch(FetchDescriptor<Stay>()).first)
        first.endTime = first.startTime.addingTimeInterval(45 * 60)
        first.durationMinutes = 45 // Stored at init; Rule B reads this, not the dates.
        var targetID = stayID
        for index in 1...7 {
            let start = first.startTime.addingTimeInterval(Double(index) * 86400)
            let stay = Stay(startTime: start, endTime: start.addingTimeInterval(21600),
                centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: "lookahead-\(index)",
                pingCount: 2, distanceFromHomeKm: index == 5 ? 300 : 200, pingIDs: [])
            stay.category = index == 7 ? .home : .destination
            stay.userOverridden = true
            seed.insert(stay)
            if index == 5 { targetID = stay.id }
        }
        try seed.save()
        let dependencyID = targetID
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        await StayClassificationInference.TestHook.$availability.withValue(true) {
            await StayClassificationInference.TestHook.$response.withValue({ _ in
                if change {
                    await gate.run(touching: [.stay]) {
                        await MainActor.run {
                            let writer = ModelContext(container)
                            do {
                                let row = try #require(writer.fetch(FetchDescriptor<Stay>()).first { $0.id == dependencyID })
                                row.distanceFromHomeKm = 200
                                try writer.save()
                            } catch { Issue.record(error) }
                        }
                    }
                }
                throw CocoaError(.coderReadCorrupt)
            }) {
                _ = await classifier.classifyAndAssembleTripsWithGates(reclassifyRecentStays: false, gate: gate)
            }
        }
        let row = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(row.category == (change ? .unclassified : .transit))
    }

    @Test("ended place geometry from an unrelated era does not invalidate a batch")
    func irrelevantHistoricalGeometryDoesNotDiscardBatch() async throws {
        let (container, stayID) = try fixture()
        let seed = ModelContext(container)
        let stay = try #require(seed.fetch(FetchDescriptor<Stay>()).first)
        let home = Home(label: "Old home", latitude: 50, longitude: 50, radiusKm: 25,
            startedAt: stay.startTime.addingTimeInterval(-10 * 86400))
        home.endedAt = stay.startTime.addingTimeInterval(-5 * 86400)
        seed.insert(home)
        let homeID = home.id
        seed.insert(HomeAreaOverride(kind: .include, centerLatitude: 50, centerLongitude: 50,
            radiusKm: 1, homeID: homeID))
        try seed.save()
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        await StayClassificationInference.TestHook.$availability.withValue(true) {
            await StayClassificationInference.TestHook.$response.withValue({ _ in
                await gate.run(touching: [.home]) {
                    await MainActor.run {
                        let writer = ModelContext(container)
                        do {
                            let home = try #require(writer.fetch(FetchDescriptor<Home>()).first { $0.id == homeID })
                            home.radiusKm = 26
                            let row = try #require(writer.fetch(FetchDescriptor<HomeAreaOverride>()).first)
                            row.radiusKm = 2
                            try writer.save()
                        } catch { Issue.record(error) }
                    }
                }
                return [.init(stayIndex: 0, category: "transit")]
            }) {
                _ = await classifier.classifyAndAssembleTripsWithGates(reclassifyRecentStays: false, gate: gate)
            }
        }
        let row = try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first { $0.id == stayID })
        #expect(row.category == .transit)
    }

}
