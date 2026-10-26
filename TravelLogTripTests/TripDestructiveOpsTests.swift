//
//  TripDestructiveOpsTests.swift
//  TravelLogTests
//
//  Tests for the destructive trip operations: the merge worker, the full
//  cascade delete, and the Remove-Keep-Map-History tombstone, using the static
//  ID-based workers the gated UI paths call, against injected in-memory
//  containers. The load-bearing contracts:
//
//  - Merge recomputes order/dates, clears stale AI metadata, marks
//    userEdited to protect the trip from regrouping, and never leaves the
//    absorbed row behind; hidden choices carry onto the target.
//  - Cascade delete removes the trip's exclusive pings and prunes ONLY
//    hexes left with zero pings — a hex shared with other travel keeps its
//    HexVisit row (the map must not lose real exploration).
//  - Remove-Keep-Data leaves a resurrection-proof tombstone: stays survive
//    as `.unclassified` + `userOverridden` with the trip link severed, and
//    every ping stays put.
//  - All three tolerate a missing row (rapid second invocation) as a no-op.
//

import CoreLocation
import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

private actor CalendarWipeStageProbe {
    private(set) var result: Int?
    func record(_ value: Int) { result = value }
}

@MainActor
@Suite("Trip destructive operations", .serialized)
struct TripDestructiveOpsTests {

    private static let base = Date(timeIntervalSinceReferenceDate: 623 * 86_400)
    private func d(_ days: Double) -> Date { Self.base.addingTimeInterval(days * 86_400) }

    private struct StubVisit: VisitEventSource {
        let coordinate: CLLocationCoordinate2D
        let horizontalAccuracy: CLLocationAccuracy
        let arrivalDate: Date
        let departureDate: Date
    }

    /// Insert a stay with its own backing pings; returns the stay.
    @discardableResult
    private func seedStay(
        _ ctx: ModelContext, trip: Trip?, startDay: Double, endDay: Double,
        hex: String, pingCount: Int = 2
    ) -> Stay {
        var pingIDs: [UUID] = []
        for i in 0..<pingCount {
            let ping = LocationPing(
                timestamp: d(startDay).addingTimeInterval(Double(i) * 600),
                latitude: 37.98, longitude: 23.72,
                horizontalAccuracy: 30, h3IndexRes6: hex, source: .liveSLC)
            ctx.insert(ping)
            pingIDs.append(ping.id)
        }
        let stay = Stay(
            startTime: d(startDay), endTime: d(endDay),
            centroidLatitude: 37.98, centroidLongitude: 23.72,
            h3IndexRes6: hex, pingCount: pingCount,
            distanceFromHomeKm: 100, pingIDs: pingIDs)
        stay.category = .destination
        stay.locality = "Athens"
        stay.trip = trip
        ctx.insert(stay)
        return stay
    }

    private func count<T: PersistentModel>(_ type: T.Type, _ container: ModelContainer) -> Int {
        (try? ModelContext(container).fetchCount(FetchDescriptor<T>())) ?? -1
    }

    /// A row the list showed but another unit deleted before this one ran:
    /// its identity as captured before the gate.
    private func vanishedTrip(_ container: ModelContainer) throws -> (id: UUID, identifier: PersistentIdentifier) {
        let other = ModelContext(container)
        let trip = Trip(startDate: d(-5))
        other.insert(trip)
        try other.save()
        let identity = (id: trip.id, identifier: trip.persistentModelID)
        other.delete(trip)
        try other.save()
        return identity
    }

    @discardableResult
    private func seedVisit(_ ctx: ModelContext, stay: Stay) -> Visit {
        let visit = Visit(
            arrivalDate: stay.startTime,
            departureDate: stay.endTime,
            latitude: stay.centroidLatitude,
            longitude: stay.centroidLongitude,
            horizontalAccuracy: 20,
            receivedAt: stay.endTime,
            stayID: stay.id,
            isProcessed: true
        )
        ctx.insert(visit)
        return visit
    }

    // MARK: - Calendar title wipe

    @Test("calendar wipe queues behind a title apply and clears it before regeneration",
          .timeLimit(.minutes(1)))
    func calendarWipeCannotPreserveLateTitle() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: d(0))
        trip.aiGeneratedTitle = "Before wipe"
        context.insert(trip)
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        let tripID = trip.id
        await classifier.setRunningLatchForTesting(true)

        let wipe = Task {
            await classifier.clearThenRegenerateAllTitlesForCalendarWipe(
                locale: Locale(identifier: "en"),
                gate: PipelineGate(forTesting: ())
            )
        }

        // The wipe must remain queued while the simulated in-flight title
        // operation owns the classifier latch. Land the title that survived
        // the old split clear→regenerate composition, then release the owner.
        while !(await classifier.calendarWipeIsWaitingForLatchForTesting()) {
            await Task.yield()
        }
        await classifier.setAITitleForTesting("Applied while wipe was queued", tripID: tripID)
        #expect(await classifier.aiTitleFieldsForTesting(tripID)?.title
                == "Applied while wipe was queued")
        await classifier.setRunningLatchForTesting(false)

        let result = await wipe.value
        #expect(result.cleared)
        #expect(result.revocationFinished)
        #expect(result.generated == 0)
        #expect(await classifier.aiTitleFieldsForTesting(tripID)?.title == nil,
                "the queued wipe must clear the late apply before its inline regeneration")
    }

    @Test("ordinary title generation cannot enter after a calendar wipe clears")
    func calendarWipeExcludesCalendarAwareStageFive() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: d(0))
        trip.aiGeneratedTitle = "Calendar Festival"
        context.insert(trip)
        let stay = seedStay(
            context,
            trip: trip,
            startDay: 0,
            endDay: 1,
            hex: "8a1eda74301ffff")
        trip.endDate = stay.endTime
        trip.isComplete = true
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        let probe = CalendarWipeStageProbe()
        await classifier.setTitleGenerationOverrideForTesting { _ in
            "A calendar-derived late title"
        }
        await classifier.setCalendarWipeAfterClearOverrideForTesting {
            let result = await classifier.generateTitlesStage(
                maxTripsPerCall: 1,
                applyGate: gate)
            await probe.record(result)
        }

        let result = await classifier.clearThenRegenerateAllTitlesForCalendarWipe(
            locale: Locale(identifier: "en"),
            gate: gate)

        #expect(result.cleared)
        #expect(await probe.result == 0)
        #expect(await classifier.aiTitleFieldsForTesting(trip.id)?.title
                != "A calendar-derived late title")
        await classifier.setCalendarWipeAfterClearOverrideForTesting(nil)
        await classifier.setTitleGenerationOverrideForTesting(nil)
    }

    @Test("calendar wipe finishes revocation before the slow refill")
    func calendarWipeFinishesRevocationBeforeRefill() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: d(0))
        trip.aiGeneratedTitle = "Calendar Festival"
        context.insert(trip)
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        let finished = OSAllocatedUnfairLock(initialState: false)
        let finishedBeforeRefill = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        await classifier.setCalendarWipeAfterClearOverrideForTesting {
            let value = finished.withLock { $0 }
            finishedBeforeRefill.withLock { $0 = value }
        }

        let result = await classifier.clearThenRegenerateAllTitlesForCalendarWipe(
            locale: Locale(identifier: "en"),
            gate: PipelineGate(forTesting: ()),
            finishRevocationAfterClear: {
                finished.withLock { $0 = true }
                return true
            })
        await classifier.setCalendarWipeAfterClearOverrideForTesting(nil)

        #expect(result.cleared)
        #expect(result.revocationFinished)
        #expect(finishedBeforeRefill.withLock { $0 } == true,
                "a kill during the refill must not leave the revocation pending")
    }

    @Test("a failed revocation finish still reports the committed clear")
    func calendarWipeReportsUnfinishedRevocation() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: d(0))
        trip.aiGeneratedTitle = "Calendar Festival"
        context.insert(trip)
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        let result = await classifier.clearThenRegenerateAllTitlesForCalendarWipe(
            locale: Locale(identifier: "en"),
            gate: PipelineGate(forTesting: ()),
            finishRevocationAfterClear: { false })

        #expect(result.cleared)
        #expect(!result.revocationFinished)
        #expect(await classifier.aiTitleFieldsForTesting(trip.id)?.title
                != "Calendar Festival")
    }

    @Test("a cancelled calendar wipe never starts after its queued wait",
          .timeLimit(.minutes(1)))
    func cancelledCalendarWipeIsInert() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: d(0))
        trip.aiGeneratedTitle = "Keep me"
        context.insert(trip)
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.setRunningLatchForTesting(true)
        let wipe = Task {
            await classifier.clearThenRegenerateAllTitlesForCalendarWipe(
                locale: Locale(identifier: "en"),
                gate: PipelineGate(forTesting: ()))
        }
        while !(await classifier.calendarWipeIsWaitingForLatchForTesting()) {
            await Task.yield()
        }
        wipe.cancel()
        await classifier.setRunningLatchForTesting(false)

        let result = await wipe.value
        #expect(!result.cleared)
        #expect(!result.revocationFinished)
        #expect(result.generated == 0)
        #expect(await classifier.aiTitleFieldsForTesting(trip.id)?.title == "Keep me")
    }

    @Test("calendar wipe clear phase removes every canonical and localized title")
    func calendarWipeClearIsAtomicAcrossLibrary() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        for index in 0..<3 {
            let trip = Trip(startDate: d(Double(index)))
            trip.aiGeneratedTitle = "Calendar title \(index)"
            context.insert(trip)
            context.insert(TripTitleVariant(
                languageTag: "de", title: "Kalendertitel \(index)",
                sourceTitle: "Calendar title \(index)", trip: trip))
        }
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.clearCalendarTitlesForTesting())
        let verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<Trip>())
            .allSatisfy { $0.aiGeneratedTitle == nil })
        #expect(try verify.fetch(FetchDescriptor<TripTitleVariant>()).isEmpty)
    }

    @Test("calendar wipe reports a clear failure and rolls titles back")
    func calendarWipeClearFailureIsVisible() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: d(0))
        trip.aiGeneratedTitle = "Calendar title"
        context.insert(trip)
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.failNextCalendarTitleWipeClear()
        let result = await classifier.clearThenRegenerateAllTitlesForCalendarWipe(
            locale: Locale(identifier: "en"),
            gate: PipelineGate(forTesting: ()))

        #expect(!result.cleared)
        #expect(!result.revocationFinished)
        #expect(result.generated == 0)
        let verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<Trip>()).first?
            .aiGeneratedTitle == "Calendar title")
    }

    // MARK: - Merge

    @Test("merge absorbs stays, recomputes order and dates, clears the stale AI title and keeps the stored narrative")
    func mergeAbsorbsAndRecomputes() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext

        let source = Trip(startDate: d(0))
        source.endDate = d(2)
        source.isComplete = true
        ctx.insert(source)
        seedStay(ctx, trip: source, startDay: 0, endDay: 1, hex: "hexA")
        seedStay(ctx, trip: source, startDay: 1, endDay: 2, hex: "hexB")

        let target = Trip(startDate: d(5))
        target.endDate = d(7)
        target.isComplete = true
        target.aiGeneratedTitle = "Old Target Title"
        target.aiGeneratedSummary = "Old summary"
        ctx.insert(target)
        seedStay(ctx, trip: target, startDay: 5, endDay: 6, hex: "hexC")
        seedStay(ctx, trip: target, startDay: 6, endDay: 7, hex: "hexD")

        // Hidden choices carry to the target; source pins are removed.
        ctx.insert(HiddenPhoto(localIdentifier: "h-1", tripID: source.id))
        ctx.insert(PinnedPhoto(localIdentifier: "p-1", tripID: source.id))
        try ctx.save()
        let sourceID = source.id
        let targetID = target.id

        #expect(TripsListView.mergeTrips(
            sourceID: sourceID, sourceIdentifier: source.persistentModelID,
            targetID: targetID, targetIdentifier: target.persistentModelID, container: container))

        #expect(count(Trip.self, container) == 1, "the absorbed source row must be gone")
        let fresh = ModelContext(container)
        let mergedID = targetID
        let merged = try #require(try fresh.fetch(
            FetchDescriptor<Trip>(predicate: #Predicate { $0.id == mergedID })).first)
        let stays = (merged.stays ?? []).sorted { $0.startTime < $1.startTime }
        #expect(stays.count == 4)
        #expect(stays.map(\.orderInTrip) == [0, 1, 2, 3],
                "orderInTrip must be recomputed across the union, chronologically")
        #expect(merged.startDate == d(0), "startDate must extend to the earlier trip")
        #expect(merged.endDate == d(7))
        #expect(merged.isComplete)
        #expect(merged.userEdited, "a merged trip is user-edited and protected from regrouping")
        #expect(merged.aiGeneratedTitle == nil,
                "the generated title described the stays before merging and must be regenerated")
        #expect(merged.aiGeneratedSummary == "Old summary",
                "a stored narrative cannot be regenerated, so a merge keeps it")
        let hidden = try fresh.fetch(FetchDescriptor<HiddenPhoto>())
        #expect(hidden.map(\.tripID) == [targetID])
        #expect(hidden.map(\.localIdentifier) == ["h-1"])
        #expect(count(PinnedPhoto.self, container) == 0)
    }

    @Test("merge preserves the union of hidden identifiers without duplicating target choices")
    func mergeUnionsHiddenChoices() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let source = Trip(startDate: d(0))
        let target = Trip(startDate: d(3))
        ctx.insert(source)
        ctx.insert(target)
        seedStay(ctx, trip: source, startDay: 0, endDay: 1, hex: "hexA")
        seedStay(ctx, trip: target, startDay: 3, endDay: 4, hex: "hexB")
        let carried = HiddenPhoto(localIdentifier: "private-local", tripID: source.id)
        carried.cloudIdentifier = "private-cloud"
        carried.hiddenAt = d(-5)
        let existing = HiddenPhoto(localIdentifier: "target-local", tripID: target.id)
        existing.cloudIdentifier = "shared-cloud"
        existing.hiddenAt = d(-3)
        let cloudDuplicate = HiddenPhoto(localIdentifier: "other-device-local", tripID: source.id)
        cloudDuplicate.cloudIdentifier = existing.cloudIdentifier
        let localDuplicate = HiddenPhoto(localIdentifier: existing.localIdentifier, tripID: source.id)
        let sourceDuplicate = HiddenPhoto(localIdentifier: carried.localIdentifier, tripID: source.id)
        sourceDuplicate.cloudIdentifier = carried.cloudIdentifier
        for row in [carried, existing, cloudDuplicate, localDuplicate, sourceDuplicate] { ctx.insert(row) }
        ctx.insert(PinnedPhoto(localIdentifier: "pin", tripID: source.id))
        try ctx.save()
        let carriedID = carried.id
        let targetID = target.id
        let existingID = existing.id

        #expect(TripsListView.mergeTrips(
            sourceID: source.id, sourceIdentifier: source.persistentModelID,
            targetID: targetID, targetIdentifier: target.persistentModelID, container: container))
        let rows = try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.tripID == targetID })
        #expect(rows.contains { $0.id == existingID && $0.hiddenAt == d(-3) })
        let copy = try #require(rows.first { $0.localIdentifier == "private-local" })
        #expect(copy.id != carriedID)
        #expect(copy.cloudIdentifier == "private-cloud")
        #expect(copy.hiddenAt == d(-5))
        #expect(count(PinnedPhoto.self, container) == 0)
    }

    @Test("merging keeps hidden choices whose cloud identity is new to the target")
    func mergeKeepsCloudIdentifiedHiddenChoices() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let source = Trip(startDate: d(0))
        let target = Trip(startDate: d(3))
        ctx.insert(source)
        ctx.insert(target)
        seedStay(ctx, trip: source, startDay: 0, endDay: 1, hex: "hexA")
        seedStay(ctx, trip: target, startDay: 3, endDay: 4, hex: "hexB")
        // Cloud-only photos share the empty local identifier.
        let targetCloudOnly = HiddenPhoto(localIdentifier: "", tripID: target.id)
        targetCloudOnly.cloudIdentifier = "cloud-a"
        let sourceCloudOnly = HiddenPhoto(localIdentifier: "", tripID: source.id)
        sourceCloudOnly.cloudIdentifier = "cloud-b"
        // A legacy local-only target row must not shadow the source's cloud identity.
        let targetLegacy = HiddenPhoto(localIdentifier: "shared-local", tripID: target.id)
        let sourceRicher = HiddenPhoto(localIdentifier: "shared-local", tripID: source.id)
        sourceRicher.cloudIdentifier = "cloud-c"
        for row in [targetCloudOnly, sourceCloudOnly, targetLegacy, sourceRicher] { ctx.insert(row) }
        try ctx.save()
        let targetID = target.id

        #expect(TripsListView.mergeTrips(
            sourceID: source.id, sourceIdentifier: source.persistentModelID,
            targetID: targetID, targetIdentifier: target.persistentModelID, container: container))
        #expect(await PhotoAnnotationDeduplicator.deduplicateAll(modelContainer: container))
        let rows = try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
        #expect(rows.allSatisfy { $0.tripID == targetID })
        #expect(Set(rows.compactMap(\.cloudIdentifier)) == ["cloud-a", "cloud-b", "cloud-c"])
        #expect(rows.contains { $0.localIdentifier == "shared-local" && $0.cloudIdentifier == nil })
    }

    @Test("merging with an ongoing target keeps the union ongoing")
    func mergeOngoingSemantics() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let source = Trip(startDate: d(0))
        source.endDate = d(2)
        source.isComplete = true
        ctx.insert(source)
        seedStay(ctx, trip: source, startDay: 0, endDay: 2, hex: "hexA")
        let target = Trip(startDate: d(3))
        target.isComplete = false
        ctx.insert(target)
        seedStay(ctx, trip: target, startDay: 3, endDay: 4, hex: "hexB")
        try ctx.save()
        let targetID = target.id

        #expect(TripsListView.mergeTrips(
            sourceID: source.id, sourceIdentifier: source.persistentModelID,
            targetID: targetID, targetIdentifier: target.persistentModelID, container: container))

        let fresh = ModelContext(container)
        let merged = try #require(try fresh.fetch(
            FetchDescriptor<Trip>(predicate: #Predicate { $0.id == targetID })).first)
        #expect(!merged.isComplete, "complete ∧ ongoing must merge to ongoing")
        #expect(merged.endDate == nil, "an ongoing union has no end date")
    }

    @Test("a merge is the user's own edit: a temporary home's mark on either trip does not carry to the merged trip")
    func mergeClearsATemporaryHomesMark() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let source = Trip(startDate: d(0))
        source.endDate = d(2)
        source.isComplete = true
        let target = Trip(startDate: d(3))
        target.endDate = d(4)
        target.isComplete = true
        for trip in [source, target] {
            trip.userEdited = true
            trip.keptByTemporaryHome = true
            ctx.insert(trip)
        }
        seedStay(ctx, trip: source, startDay: 0, endDay: 2, hex: "hexA")
        seedStay(ctx, trip: target, startDay: 3, endDay: 4, hex: "hexB")
        try ctx.save()
        let targetID = target.id

        #expect(TripsListView.mergeTrips(
            sourceID: source.id, sourceIdentifier: source.persistentModelID,
            targetID: targetID, targetIdentifier: target.persistentModelID, container: container))

        let merged = try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>(predicate: #Predicate { $0.id == targetID })).first)
        #expect(merged.userEdited)
        #expect(!merged.keptByTemporaryHome)
    }

    @Test("merge with a missing source is a clean no-op — rapid second merge")
    func mergeMissingSourceNoOp() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let target = Trip(startDate: d(3))
        ctx.insert(target)
        seedStay(ctx, trip: target, startDay: 3, endDay: 4, hex: "hexB")
        try ctx.save()
        let gone = try vanishedTrip(container)

        #expect(!TripsListView.mergeTrips(
            sourceID: gone.id, sourceIdentifier: gone.identifier,
            targetID: target.id, targetIdentifier: target.persistentModelID, container: container))

        #expect(count(Trip.self, container) == 1)
        #expect((target.stays ?? []).count == 1, "nothing half-merged on a missing row")
    }

    @Test("merge reports annotation read failure and preserves an earlier pending edit")
    func mergeAnnotationFailurePreservesPendingEdit() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let source = Trip(startDate: d(0))
        let target = Trip(startDate: d(3))
        let unrelated = Trip(startDate: d(10))
        ctx.insert(source)
        ctx.insert(target)
        ctx.insert(unrelated)
        seedStay(ctx, trip: source, startDay: 0, endDay: 1, hex: "hexA")
        seedStay(ctx, trip: target, startDay: 3, endDay: 4, hex: "hexB")
        target.aiGeneratedTitle = "Keep target title"
        ctx.insert(HiddenPhoto(localIdentifier: "h-merge", tripID: source.id))
        ctx.insert(PinnedPhoto(localIdentifier: "p-merge", tripID: source.id))
        try ctx.save()
        let sourceID = source.id
        let targetID = target.id
        let unrelatedID = unrelated.id
        unrelated.aiGeneratedSummary = "Earlier pending edit"

        TripsListView.failCascadeDependencyFetchForTesting = true
        defer { TripsListView.failCascadeDependencyFetchForTesting = false }
        #expect(!TripsListView.mergeTrips(
            sourceID: sourceID, sourceIdentifier: source.persistentModelID,
            targetID: targetID, targetIdentifier: target.persistentModelID, container: container))

        #expect(!ctx.hasChanges)
        let trips = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        #expect(trips.count == 3)
        let persistedSource = try #require(trips.first { $0.id == sourceID })
        let persistedTarget = try #require(trips.first { $0.id == targetID })
        #expect(persistedSource.stays?.count == 1)
        #expect(persistedTarget.stays?.count == 1)
        #expect(persistedTarget.startDate == d(3))
        #expect(!persistedTarget.userEdited)
        #expect(persistedTarget.aiGeneratedTitle == "Keep target title")
        #expect(trips.first { $0.id == unrelatedID }?.aiGeneratedSummary == "Earlier pending edit")
        #expect(count(Stay.self, container) == 2)
        #expect(count(LocationPing.self, container) == 4)
        #expect(count(HiddenPhoto.self, container) == 1)
        #expect(count(PinnedPhoto.self, container) == 1)
    }

    @Test("merge reports a trip read failure without absorbing either trip")
    func mergeTripReadFailureIsNotSuccess() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let source = Trip(startDate: d(0))
        let target = Trip(startDate: d(3))
        ctx.insert(source)
        ctx.insert(target)
        seedStay(ctx, trip: source, startDay: 0, endDay: 1, hex: "hexA")
        try ctx.save()

        TripsListView.failTripFetchForTesting = true
        defer { TripsListView.failTripFetchForTesting = false }
        #expect(!TripsListView.mergeTrips(
            sourceID: source.id, sourceIdentifier: source.persistentModelID,
            targetID: target.id, targetIdentifier: target.persistentModelID, container: container))
        #expect(!ctx.hasChanges)
        #expect(count(Trip.self, container) == 2)
        #expect(count(Stay.self, container) == 1)
        #expect(source.stays?.count == 1)
        #expect(!target.userEdited)
    }

    // MARK: - Cascade delete

    @Test("cascade delete removes exclusive pings and prunes only ping-less hexes")
    func cascadeDeleteSparesSharedHexes() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext

        // Doomed trip: one stay in exclusive hexE, one in shared hexS.
        let doomed = Trip(startDate: d(0))
        doomed.endDate = d(2)
        doomed.isComplete = true
        ctx.insert(doomed)
        seedStay(ctx, trip: doomed, startDay: 0, endDay: 1, hex: "hexE")
        seedStay(ctx, trip: doomed, startDay: 1, endDay: 2, hex: "hexS")

        // Survivor trip with its own ping in the shared hex.
        let survivor = Trip(startDate: d(10))
        survivor.endDate = d(11)
        survivor.isComplete = true
        ctx.insert(survivor)
        seedStay(ctx, trip: survivor, startDay: 10, endDay: 11, hex: "hexS")

        for hex in ["hexE", "hexS"] {
            ctx.insert(HexVisit(h3Index: hex, firstVisited: d(0),
                                centerLatitude: 37.98, centerLongitude: 23.72))
        }
        ctx.insert(HiddenPhoto(localIdentifier: "h-1", tripID: doomed.id))
        try ctx.save()
        let doomedID = doomed.id
        let survivorID = survivor.id

        #expect(TripsListView.deleteTrip(
            tripID: doomedID, tripIdentifier: doomed.persistentModelID, container: container))

        let fresh = ModelContext(container)
        #expect(count(Trip.self, container) == 1)
        #expect(try fresh.fetch(
            FetchDescriptor<Trip>(predicate: #Predicate { $0.id == survivorID })).first != nil)
        // Exclusive pings die; the survivor's 2 pings in hexS remain.
        #expect(count(LocationPing.self, container) == 2)
        #expect(count(Stay.self, container) == 1)
        let hexes = try fresh.fetch(FetchDescriptor<HexVisit>())
        #expect(hexes.map(\.h3Index) == ["hexS"],
                "hexE (zero remaining pings) must be pruned; the shared hexS must SURVIVE")
        #expect(count(HiddenPhoto.self, container) == 0)
    }

    @Test("cascade delete of a missing trip is a no-op")
    func cascadeDeleteMissingNoOp() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let trip = Trip(startDate: d(0))
        ctx.insert(trip)
        seedStay(ctx, trip: trip, startDay: 0, endDay: 1, hex: "hexA")
        try ctx.save()

        // A trip another unit already deleted is a success, not a save failure.
        let gone = try vanishedTrip(container)
        #expect(TripsListView.deleteTrip(
            tripID: gone.id, tripIdentifier: gone.identifier, container: container))

        #expect(count(Trip.self, container) == 1)
        #expect(count(Stay.self, container) == 1)
        #expect(count(LocationPing.self, container) == 2)
    }

    @Test("full delete removes linked Visits and preserves unrelated Visits")
    func fullDeleteCascadesVisitsByStayID() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let doomed = Trip(startDate: d(0))
        let survivor = Trip(startDate: d(10))
        ctx.insert(doomed)
        ctx.insert(survivor)
        let doomedStay = seedStay(
            ctx, trip: doomed, startDay: 0, endDay: 1, hex: "hexD"
        )
        let survivorStay = seedStay(
            ctx, trip: survivor, startDay: 10, endDay: 11, hex: "hexS"
        )
        seedVisit(ctx, stay: doomedStay)
        let survivingVisit = seedVisit(ctx, stay: survivorStay)
        let survivingVisitID = survivingVisit.id
        let survivorStayID = survivorStay.id
        let doomedID = doomed.id
        try ctx.save()

        TripsListView.deleteTrip(
            tripID: doomedID, tripIdentifier: doomed.persistentModelID, container: container)

        let fresh = ModelContext(container)
        let visits = try fresh.fetch(FetchDescriptor<Visit>())
        #expect(visits.count == 1)
        #expect(visits.first?.id == survivingVisitID)
        #expect(visits.first?.stayID == survivorStayID)
    }

    @Test("a valid late callback can recreate evidence after full deletion")
    func lateVisitCallbackCanRecreateEvidence() async throws {
        let suiteName = "TripDestructiveOpsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let trip = Trip(startDate: d(0))
        ctx.insert(trip)
        let stay = seedStay(
            ctx, trip: trip, startDay: 0, endDay: 1, hex: "hexA"
        )
        seedVisit(ctx, stay: stay)
        let tripID = trip.id
        try ctx.save()
        TripsListView.deleteTrip(
            tripID: tripID, tripIdentifier: trip.persistentModelID, container: container)
        #expect(count(Visit.self, container) == 0)

        let arrival = d(0.5)
        await VisitRecorder(modelContainer: container).record(VisitObservation(
            source: StubVisit(
                coordinate: CLLocationCoordinate2D(latitude: 37.98, longitude: 23.72),
                horizontalAccuracy: 20,
                arrivalDate: arrival,
                departureDate: .distantFuture
            ),
            receivedAt: arrival.addingTimeInterval(60)
        ), defaults: UserDefaults(suiteName: suiteName)!)

        let visits = try ModelContext(container).fetch(FetchDescriptor<Visit>())
        #expect(visits.count == 1)
        #expect(visits.first?.stayID == nil)
    }

    // MARK: - Remove, keep map history

    @Test("remove-keep-data tombstones the stays and keeps every ping and hex")
    func removeKeepDataTombstones() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let trip = Trip(startDate: d(0))
        trip.endDate = d(2)
        trip.isComplete = true
        ctx.insert(trip)
        let firstStay = seedStay(
            ctx, trip: trip, startDay: 0, endDay: 1, hex: "hexA"
        )
        let secondStay = seedStay(
            ctx, trip: trip, startDay: 1, endDay: 2, hex: "hexB"
        )
        seedVisit(ctx, stay: firstStay)
        seedVisit(ctx, stay: secondStay)
        ctx.insert(HexVisit(h3Index: "hexA", firstVisited: d(0),
                            centerLatitude: 37.98, centerLongitude: 23.72))
        ctx.insert(PinnedPhoto(localIdentifier: "p-1", tripID: trip.id))
        try ctx.save()
        let tripID = trip.id

        #expect(TripsListView.removeTripKeepData(
            tripID: tripID, tripIdentifier: trip.persistentModelID, container: container))

        #expect(count(Trip.self, container) == 0, "the journal entry is gone")
        #expect(count(LocationPing.self, container) == 4, "raw history survives")
        #expect(count(HexVisit.self, container) == 1, "exploration survives")
        #expect(count(PinnedPhoto.self, container) == 0, "annotations die with the trip")
        #expect(count(Visit.self, container) == 2, "Visit evidence survives")
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(stays.count == 2)
        for stay in stays {
            #expect(stay.trip == nil)
            #expect(stay.orderInTrip == nil)
            #expect(stay.category == .unclassified)
            #expect(stay.userOverridden,
                    "the tombstone flag — without it the next pipeline pass re-mints the trip")
        }
    }

    @Test("keep-data removal reports an unreadable trip instead of treating it as absent")
    func removeKeepDataTripReadFailureIsNotSuccess() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let trip = Trip(startDate: d(0))
        ctx.insert(trip)
        seedStay(ctx, trip: trip, startDay: 0, endDay: 1, hex: "hexA")
        ctx.insert(PinnedPhoto(localIdentifier: "p-keep", tripID: trip.id))
        try ctx.save()
        let tripID = trip.id

        TripsListView.failTripFetchForTesting = true
        defer { TripsListView.failTripFetchForTesting = false }
        #expect(!TripsListView.removeTripKeepData(
            tripID: tripID, tripIdentifier: trip.persistentModelID, container: container))
        #expect(!ctx.hasChanges)
        #expect(count(Trip.self, container) == 1)
        #expect(count(LocationPing.self, container) == 2)
        #expect(count(PinnedPhoto.self, container) == 1)
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(stays.count == 1)
        #expect(stays.first?.trip?.id == tripID)
        #expect(stays.first?.category == .destination)
        #expect(stays.first?.userOverridden == false)
    }

    @Test("keep-data annotation failure preserves an earlier pending edit")
    func removeKeepDataAnnotationFailurePreservesPendingEdit() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let trip = Trip(startDate: d(0))
        let unrelated = Trip(startDate: d(10))
        ctx.insert(trip)
        ctx.insert(unrelated)
        seedStay(ctx, trip: trip, startDay: 0, endDay: 1, hex: "hexA")
        ctx.insert(HiddenPhoto(localIdentifier: "h-keep", tripID: trip.id))
        try ctx.save()
        let tripID = trip.id
        let unrelatedID = unrelated.id
        unrelated.aiGeneratedSummary = "Earlier pending edit"

        TripsListView.failCascadeDependencyFetchForTesting = true
        defer { TripsListView.failCascadeDependencyFetchForTesting = false }
        #expect(!TripsListView.removeTripKeepData(
            tripID: tripID, tripIdentifier: trip.persistentModelID, container: container))
        #expect(!ctx.hasChanges)
        let fresh = ModelContext(container)
        let trips = try fresh.fetch(FetchDescriptor<Trip>())
        #expect(trips.count == 2)
        #expect(trips.first { $0.id == unrelatedID }?.aiGeneratedSummary == "Earlier pending edit")
        let stays = try fresh.fetch(FetchDescriptor<Stay>())
        #expect(stays.count == 1)
        #expect(stays.first?.trip?.id == tripID)
        #expect(stays.first?.userOverridden == false)
        #expect(count(HiddenPhoto.self, container) == 1)
        #expect(count(LocationPing.self, container) == 2)
    }

    @Test("keep-data removal still succeeds when a successful read finds no trip")
    func removeKeepDataMissingTripIsSuccess() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let gone = try vanishedTrip(container)
        #expect(TripsListView.removeTripKeepData(
            tripID: gone.id, tripIdentifier: gone.identifier, container: container))
        #expect(!container.mainContext.hasChanges)
    }

    @Test("cascade delete keeps the trip and every row when a dependency read fails")
    func cascadeDeleteFailsClosedOnDependencyReadFailure() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let trip = Trip(startDate: d(0))
        trip.endDate = d(2)
        trip.isComplete = true
        ctx.insert(trip)
        seedStay(ctx, trip: trip, startDay: 0, endDay: 1, hex: "hexE")
        ctx.insert(HexVisit(h3Index: "hexE", firstVisited: d(0),
                            centerLatitude: 37.98, centerLongitude: 23.72))
        ctx.insert(HiddenPhoto(localIdentifier: "h-1", tripID: trip.id))
        try ctx.save()
        let tripID = trip.id

        TripsListView.failCascadeDependencyFetchForTesting = true
        defer { TripsListView.failCascadeDependencyFetchForTesting = false }
        #expect(!TripsListView.deleteTrip(
            tripID: tripID, tripIdentifier: trip.persistentModelID, container: container))

        #expect(!ctx.hasChanges, "a failed read must leave nothing pending")
        #expect(count(Trip.self, container) == 1)
        #expect(count(Stay.self, container) == 1)
        #expect(count(LocationPing.self, container) == 2)
        #expect(count(HexVisit.self, container) == 1)
        #expect(count(HiddenPhoto.self, container) == 1)
    }

    /// The workers act on the tapped physical row, never on a UUID twin.
    @Test("removing one UUID twin removes exactly that row and keeps shared annotations only for a populated survivor",
          arguments: ["delete", "keep-data", "merge"],
          [(false, false), (false, true), (true, false), (true, true)])
    func twinDeletionKeepsSharedAnnotations(path: String, twins: (Bool, Bool)) throws {
        let (emptySelected, emptyTwinFirst) = twins
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let populated = Trip(startDate: d(0))
        populated.endDate = d(2)
        populated.isComplete = true
        // A synced duplicate: a second physical row with the same UUID.
        let empty = Trip(startDate: d(0))
        empty.endDate = d(2)
        empty.isComplete = true
        empty.id = populated.id
        for row in emptyTwinFirst ? [empty, populated] : [populated, empty] { ctx.insert(row) }
        seedStay(ctx, trip: populated, startDay: 0, endDay: 1, hex: "hexT")
        let target = Trip(startDate: d(5))
        target.endDate = d(6)
        target.isComplete = true
        ctx.insert(target)
        seedStay(ctx, trip: target, startDay: 5, endDay: 6, hex: "hexU")
        ctx.insert(PinnedPhoto(localIdentifier: "p-1", tripID: populated.id))
        ctx.insert(HiddenPhoto(localIdentifier: "h-1", tripID: populated.id))
        try ctx.save()
        let twinID = populated.id
        let targetID = target.id
        let targetRow = target.persistentModelID
        let selected = emptySelected ? empty.persistentModelID : populated.persistentModelID
        let other = emptySelected ? populated.persistentModelID : empty.persistentModelID
        let suite = "TripDestructiveOpsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let pins = PinnedTripsStorage(forTesting: defaults)
        pins.pin(twinID)

        // The worker and the favourite step the views run after it.
        func remove(_ row: PersistentIdentifier) -> Bool {
            let saved: Bool
            switch path {
            case "delete":
                saved = TripsListView.deleteTrip(tripID: twinID, tripIdentifier: row, container: container)
            case "keep-data":
                saved = TripsListView.removeTripKeepData(tripID: twinID, tripIdentifier: row, container: container)
            default:
                saved = TripsListView.mergeTrips(
                    sourceID: twinID, sourceIdentifier: row,
                    targetID: targetID, targetIdentifier: targetRow, container: container)
            }
            if saved, path == "merge" {
                TripsListView.carryFavouriteAfterMerge(
                    sourceID: twinID, targetID: targetID, pins: pins, container: container)
            } else if saved {
                TripsListView.unpinUnlessTripRowSurvives(twinID, pins: pins, container: container)
            }
            return saved
        }
        func twinRows() throws -> [Trip] {
            try ModelContext(container).fetch(FetchDescriptor<Trip>()).filter { $0.id == twinID }
        }

        #expect(remove(selected))
        #expect(try twinRows().map(\.persistentModelID) == [other], "exactly the tapped row goes")
        // A populated survivor still shows the annotations and the favourite.
        // An empty survivor must not inherit them, or the ghost sweep could
        // never remove it.
        let survivorPopulated = emptySelected
        let kept = survivorPopulated ? 1 : 0
        #expect(count(PinnedPhoto.self, container) == kept)
        #expect(count(HiddenPhoto.self, container) == kept + (path == "merge" ? 1 : 0))
        #expect(pins.isPinned(twinID) == survivorPopulated)
        if survivorPopulated {
            #expect(try twinRows().first?.stays?.count == 1, "the populated twin keeps its stay")
            #expect(count(LocationPing.self, container) == 4, "no evidence of the untapped twin is touched")
        }
        // The carry is unconditional (carryFavouriteAfterMerge): the target
        // inherits the favourite whichever twin was merged, and a populated
        // survivor keeps its own as asserted above. Only a merge pins it.
        #expect(pins.isPinned(targetID) == (path == "merge"),
                "only the merged trip inherits the favourite")

        // The unit ran after its row was gone: the twin is not a stand-in.
        #expect(remove(selected) == (path != "merge"))
        #expect(try twinRows().map(\.persistentModelID) == [other])

        // Removing the survivor frees its source annotations and favourite.
        #expect(remove(other))
        #expect(try twinRows().isEmpty)
        #expect(count(PinnedPhoto.self, container) == 0)
        #expect(count(HiddenPhoto.self, container) == (path == "merge" ? 1 : 0))
        #expect(!pins.isPinned(twinID))
    }

    /// Two populated twins with disjoint stays, each with its own pings, Visit and hex.
    @Test("a destructive action on one populated UUID twin leaves the other twin's history intact",
          arguments: ["delete", "keep-data", "merge"], [false, true])
    func populatedTwinHistoryIsIsolated(path: String, selectedFirst: Bool) throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let selected = Trip(startDate: d(0))
        selected.endDate = d(1)
        selected.isComplete = true
        let other = Trip(startDate: d(0))
        other.endDate = d(3)
        other.isComplete = true
        other.id = selected.id
        for row in selectedFirst ? [selected, other] : [other, selected] { ctx.insert(row) }
        let selectedStay = seedStay(ctx, trip: selected, startDay: 0, endDay: 1, hex: "hexA")
        let otherStay = seedStay(ctx, trip: other, startDay: 2, endDay: 3, hex: "hexB")
        seedVisit(ctx, stay: selectedStay)
        let otherVisit = seedVisit(ctx, stay: otherStay)
        for hex in ["hexA", "hexB"] {
            ctx.insert(HexVisit(h3Index: hex, firstVisited: d(0),
                                centerLatitude: 37.98, centerLongitude: 23.72))
        }
        let target = Trip(startDate: d(5))
        target.endDate = d(6)
        target.isComplete = true
        ctx.insert(target)
        seedStay(ctx, trip: target, startDay: 5, endDay: 6, hex: "hexC")
        try ctx.save()
        let tripID = selected.id
        let selectedStayID = selectedStay.id
        let otherStayID = otherStay.id
        let otherVisitID = otherVisit.id
        let otherPingIDs = Set(otherStay.pingIDs)
        let otherRow = other.persistentModelID

        let saved: Bool
        switch path {
        case "delete":
            saved = TripsListView.deleteTrip(
                tripID: tripID, tripIdentifier: selected.persistentModelID, container: container)
        case "keep-data":
            saved = TripsListView.removeTripKeepData(
                tripID: tripID, tripIdentifier: selected.persistentModelID, container: container)
        default:
            saved = TripsListView.mergeTrips(
                sourceID: tripID, sourceIdentifier: selected.persistentModelID,
                targetID: target.id, targetIdentifier: target.persistentModelID, container: container)
        }
        #expect(saved)

        let fresh = ModelContext(container)
        let twins = try fresh.fetch(FetchDescriptor<Trip>()).filter { $0.id == tripID }
        #expect(twins.map(\.persistentModelID) == [otherRow])
        #expect(twins.first?.stays?.map(\.id) == [otherStayID], "the untapped twin keeps its own stay")
        let stays = try fresh.fetch(FetchDescriptor<Stay>())
        let survivingOther = try #require(stays.first { $0.id == otherStayID })
        #expect(survivingOther.category == .destination)
        #expect(!survivingOther.userOverridden)
        let pingIDs = Set(try fresh.fetch(FetchDescriptor<LocationPing>()).map(\.id))
        #expect(otherPingIDs.isSubset(of: pingIDs))
        #expect(try fresh.fetch(FetchDescriptor<Visit>()).contains { $0.id == otherVisitID })
        #expect(try fresh.fetch(FetchDescriptor<HexVisit>()).contains { $0.h3Index == "hexB" })
        let selectedStayNow = stays.first { $0.id == selectedStayID }
        switch path {
        case "delete":
            #expect(selectedStayNow == nil)
            #expect(pingIDs.count == 4, "only the tapped twin's pings go")
            #expect(try fresh.fetch(FetchDescriptor<Visit>()).count == 1)
            #expect(!(try fresh.fetch(FetchDescriptor<HexVisit>()).contains { $0.h3Index == "hexA" }))
        case "keep-data":
            #expect(selectedStayNow?.trip == nil)
            #expect(selectedStayNow?.userOverridden == true)
            #expect(pingIDs.count == 6)
        default:
            #expect(selectedStayNow?.trip?.persistentModelID == target.persistentModelID)
            #expect(pingIDs.count == 6)
        }
    }

    @Test("a full delete keeps the Visits and pings a surviving same-UUID stay twin still references")
    func fullDeleteKeepsStayTwinEvidence() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let doomed = Trip(startDate: d(0))
        let keeper = Trip(startDate: d(0))
        ctx.insert(doomed)
        ctx.insert(keeper)
        let doomedStay = seedStay(ctx, trip: doomed, startDay: 0, endDay: 1, hex: "hexD")
        // A double import's stay copy on another trip: same stay UUID, its own
        // ping plus one reference shared with the doomed copy.
        let keeperPing = LocationPing(
            timestamp: d(0.5), latitude: 37.98, longitude: 23.72,
            horizontalAccuracy: 30, h3IndexRes6: "hexD", source: .jsonImport)
        ctx.insert(keeperPing)
        let sharedPingID = try #require(doomedStay.pingIDs.first)
        let exclusivePingID = try #require(doomedStay.pingIDs.last)
        let twinStay = Stay(
            startTime: d(0), endTime: d(1),
            centroidLatitude: 37.98, centroidLongitude: 23.72,
            h3IndexRes6: "hexD", pingCount: 2,
            distanceFromHomeKm: 100, pingIDs: [keeperPing.id, sharedPingID])
        twinStay.id = doomedStay.id
        twinStay.category = .destination
        twinStay.trip = keeper
        ctx.insert(twinStay)
        let visit = seedVisit(ctx, stay: doomedStay)
        ctx.insert(HexVisit(h3Index: "hexD", firstVisited: d(0),
                            centerLatitude: 37.98, centerLongitude: 23.72))
        try ctx.save()
        let visitID = visit.id
        let keeperPingID = keeperPing.id

        #expect(TripsListView.deleteTrip(
            tripID: doomed.id, tripIdentifier: doomed.persistentModelID, container: container))

        let fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<Trip>()).count == 1)
        #expect(try fresh.fetch(FetchDescriptor<Stay>()).count == 1)
        #expect(try fresh.fetch(FetchDescriptor<Visit>()).map(\.id) == [visitID],
                "the surviving stay twin still owns the Visit linked by its UUID")
        let pingIDs = Set(try fresh.fetch(FetchDescriptor<LocationPing>()).map(\.id))
        #expect(pingIDs == [keeperPingID, sharedPingID], "only the doomed copy's exclusive ping goes")
        #expect(!pingIDs.contains(exclusivePingID))
        #expect(count(HexVisit.self, container) == 1)
    }

    @Test("a full delete keeps the pings a surviving stay with a different UUID still references",
          arguments: [false, true])
    func fullDeleteKeepsPingsSharedAcrossStayUUIDs(deleteSecondDevicesTrip: Bool) throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        // Two devices clustered the same synced pings before either's
        // isProcessed flag reached the other: each built its own stay (fresh
        // UUID) and trip over them. The user then deletes one "duplicate".
        let firstTrip = Trip(startDate: d(0))
        let secondTrip = Trip(startDate: d(0))
        ctx.insert(firstTrip)
        ctx.insert(secondTrip)
        let firstStay = seedStay(ctx, trip: firstTrip, startDay: 0, endDay: 1, hex: "hexD", pingCount: 3)
        let sharedPingIDs = Array(firstStay.pingIDs.prefix(2))
        let firstOnlyPingID = try #require(firstStay.pingIDs.last)
        let secondStay = Stay(
            startTime: d(0), endTime: d(1),
            centroidLatitude: 37.98, centroidLongitude: 23.72,
            h3IndexRes6: "hexD", pingCount: 2,
            distanceFromHomeKm: 100, pingIDs: sharedPingIDs)
        secondStay.category = .destination
        secondStay.trip = secondTrip
        ctx.insert(secondStay)
        #expect(secondStay.id != firstStay.id)
        let (doomed, keeper) = deleteSecondDevicesTrip ? (secondTrip, firstTrip) : (firstTrip, secondTrip)
        ctx.insert(HexVisit(h3Index: "hexD", firstVisited: d(0),
                            centerLatitude: 37.98, centerLongitude: 23.72))
        try ctx.save()
        let keeperID = keeper.id
        let keeperStayID = (deleteSecondDevicesTrip ? firstStay : secondStay).id

        #expect(TripsListView.deleteTrip(
            tripID: doomed.id, tripIdentifier: doomed.persistentModelID, container: container))

        let fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<Trip>()).map(\.id) == [keeperID])
        let survivingStays = try fresh.fetch(FetchDescriptor<Stay>())
        #expect(survivingStays.map(\.id) == [keeperStayID])
        let pingIDs = Set(try fresh.fetch(FetchDescriptor<LocationPing>()).map(\.id))
        let keeperPingIDs = Set(try #require(survivingStays.first).pingIDs)
        #expect(keeperPingIDs.isSubset(of: pingIDs),
                "the surviving stay's pings are its evidence; none may dangle")
        if deleteSecondDevicesTrip {
            #expect(pingIDs == Set(sharedPingIDs + [firstOnlyPingID]), "the doomed stay owned no ping of its own")
        } else {
            #expect(pingIDs == Set(sharedPingIDs), "only the doomed stay's exclusive ping goes")
        }
        #expect(count(HexVisit.self, container) == 1, "the hex still has pings")
    }

    @Test("a manual merge moves the absorbed trip's favourite to the merged trip",
          arguments: [(true, false), (false, false), (true, true), (false, true)])
    func mergeCarriesFavourite(sourcePinned: Bool, targetPinned: Bool) throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let source = Trip(startDate: d(0))
        source.endDate = d(2)
        source.isComplete = true
        ctx.insert(source)
        seedStay(ctx, trip: source, startDay: 0, endDay: 2, hex: "hexA")
        let target = Trip(startDate: d(5))
        target.endDate = d(7)
        target.isComplete = true
        ctx.insert(target)
        seedStay(ctx, trip: target, startDay: 5, endDay: 7, hex: "hexB")
        try ctx.save()
        let sourceID = source.id
        let targetID = target.id
        let suite = "TripDestructiveOpsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let pins = PinnedTripsStorage(forTesting: defaults)
        if sourcePinned { pins.pin(sourceID) }
        if targetPinned { pins.pin(targetID) }

        #expect(TripsListView.mergeTrips(
            sourceID: sourceID, sourceIdentifier: source.persistentModelID,
            targetID: targetID, targetIdentifier: target.persistentModelID, container: container))
        TripsListView.carryFavouriteAfterMerge(
            sourceID: sourceID, targetID: targetID, pins: pins, container: container)

        #expect(!pins.isPinned(sourceID), "the absorbed trip's UUID is freed")
        #expect(pins.isPinned(targetID) == (sourcePinned || targetPinned))
    }

    @Test("merging a trip into its own UUID twin is refused")
    func mergeIntoOwnTwinIsRefused() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let trip = Trip(startDate: d(0))
        trip.endDate = d(2)
        trip.isComplete = true
        ctx.insert(trip)
        seedStay(ctx, trip: trip, startDay: 0, endDay: 1, hex: "hexV")
        let twin = Trip(startDate: d(0))
        twin.endDate = d(2)
        twin.isComplete = true
        twin.id = trip.id
        ctx.insert(twin)
        try ctx.save()

        #expect(!TripsListView.mergeTrips(
            sourceID: trip.id, sourceIdentifier: trip.persistentModelID,
            targetID: trip.id, targetIdentifier: twin.persistentModelID, container: container))
        #expect(count(Trip.self, container) == 2)
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        #expect(stays.count == 1 && stays.first?.trip?.id == trip.id, "no stay loses its trip")
    }

    /// Undo of "This Wasn't a Trip" re-pins only when the demote freed a pin.
    /// The undo itself is private view state; this pins the report it reads
    /// and that storage takes the freed id back.
    @Test("the demote unpin reports whether it freed a favourite, and the freed id can be pinned again",
          arguments: [(true, false), (false, false), (true, true)])
    func demoteUnpinReportsFreedFavourite(pinned: Bool, populatedRow: Bool) throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let trip = Trip(startDate: d(0))
        trip.endDate = d(2)
        trip.isComplete = true
        let tripID = trip.id
        if populatedRow {
            ctx.insert(trip)
            seedStay(ctx, trip: trip, startDay: 0, endDay: 1, hex: "hexW")
            try ctx.save()
        }
        let suite = "TripDestructiveOpsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let pins = PinnedTripsStorage(forTesting: defaults)
        if pinned { pins.pin(tripID) }

        let freed = TripsListView.unpinUnlessTripRowSurvives(tripID, pins: pins, container: container)

        #expect(freed == (pinned && !populatedRow))
        #expect(pins.isPinned(tripID) == (pinned && populatedRow))
        // Pinning the freed id again, as Undo does, restores the favourite.
        if freed { pins.pin(tripID) }
        #expect(pins.isPinned(tripID) == pinned)
    }
}
