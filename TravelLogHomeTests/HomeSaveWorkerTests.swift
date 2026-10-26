//
//  HomeSaveWorkerTests.swift
//  TravelLogTests
//
//  `HomeFormSheet.save` used to mutate and
//  `try? modelContext.save()` on the main context with no `PipelineGate` unit,
//  while the sibling `deleteHomes` is gated precisely because an ungated
//  main-context save can race a gated lane (or the launch PlacesDeduplicator)
//  and be swallowed by the `try?`.
//
//  A static worker over an injected context lets the caller gate the write
//  and makes the add/edit branches testable outside the sheet body.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

// Serialized: the worker's DEBUG read-failure seams are static.
@Suite(.serialized)
@MainActor
struct HomeSaveWorkerTests {

    private let now = Date(timeIntervalSince1970: 1_726_006_400)
    private let athens = (lat: 37.9838, lon: 23.7275)
    /// About 5.6 km from Athens centre, comfortably past the 1 km "user moved" split.
    private let agiosDimitrios = (lat: 37.9334, lon: 23.7336)

    private func payload(
        target: HomeSavePayload.Target,
        coord: (lat: Double, lon: Double),
        label: String = "Home",
        radiusKm: Double = 3,
        locality: String? = "Athens",
        adminArea: String? = "Attica",
        country: String? = "Greece",
        iso: String? = "GR",
        endingExistingHomes: Bool = false,
        shown: Set<UUID> = []
    ) -> HomeSavePayload {
        HomeSavePayload(
            target: target,
            label: label,
            latitude: coord.lat,
            longitude: coord.lon,
            radiusKm: radiusKm,
            locality: locality,
            administrativeArea: adminArea,
            country: country,
            isoCountryCode: iso,
            endingExistingHomes: endingExistingHomes,
            shownActiveHomeIDs: shown,
            now: now
        )
    }

    private func makeHome(
        in ctx: ModelContext,
        coord: (lat: Double, lon: Double),
        radiusKm: Double = 3,
        label: String = "Home"
    ) -> Home {
        let home = Home(label: label, latitude: coord.lat, longitude: coord.lon, radiusKm: radiusKm)
        home.locality = "Athens"
        home.administrativeArea = "Attica"
        home.country = "Greece"
        home.isoCountryCode = "GR"
        ctx.insert(home)
        return home
    }

    private func homes(_ ctx: ModelContext) throws -> [Home] {
        try ctx.fetch(FetchDescriptor<Home>())
    }

    // MARK: - Add

    @Test("add with Keep Both leaves existing actives alone and returns the new id")
    func addKeepBothEndsNothing() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let existing = makeHome(in: ctx, coord: athens)
        try ctx.save()

        let result = HomeSaveWorker.apply(
            payload(target: .add, coord: agiosDimitrios, locality: "Agios Dimitrios", endingExistingHomes: false),
            context: ctx
        )

        #expect(result.reconcileHomeID != nil)
        #expect(result.titleInputsChanged)
        #expect(existing.endedAt == nil)
        #expect(try homes(ctx).count == 2)
    }

    /// Replace must end exactly the homes the confirmation dialog named,
    /// never a row that arrived via CloudKit during the geocode await.
    @Test("add with Replace ends ONLY the homes the dialog named")
    func addReplaceEndsOnlyShownHomes() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let shownHome = makeHome(in: ctx, coord: athens, label: "Shown")
        let arrivedDuringAwait = makeHome(in: ctx, coord: agiosDimitrios, label: "Synced")
        try ctx.save()

        _ = HomeSaveWorker.apply(
            payload(
                target: .add, coord: agiosDimitrios,
                endingExistingHomes: true, shown: [shownHome.id]
            ),
            context: ctx
        )

        #expect(shownHome.endedAt == now)
        #expect(arrivedDuringAwait.endedAt == nil)
    }

    // MARK: - Edit

    @Test("Replace fails closed when current homes cannot be read")
    func replaceCurrentHomesReadFailureRollsBack() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let original = makeHome(in: ctx, coord: athens)
        let originalID = original.id
        try ctx.save()

        HomeSaveWorker.failHomeWorkerCurrentHomesFetchForTesting = true
        defer { HomeSaveWorker.failHomeWorkerCurrentHomesFetchForTesting = false }
        let result = HomeSaveWorker.apply(
            payload(target: .add, coord: agiosDimitrios,
                    endingExistingHomes: true, shown: [originalID]),
            context: ctx)

        #expect(result.failed)
        #expect(result != .noChange)
        #expect(result.reconcileHomeID == nil)
        #expect(!result.titleInputsChanged)
        #expect(!ctx.hasChanges)
        let saved = try homes(ModelContext(container))
        #expect(saved.count == 1)
        let unchanged = try #require(saved.first)
        #expect(unchanged.id == originalID)
        #expect(unchanged.endedAt == nil)
    }

    @Test("a nearby edit rolls back its version bump when corrections cannot be read")
    func nearbyEditOverrideReadFailureRollsBack() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let original = makeHome(in: ctx, coord: athens)
        let originalID = original.id
        let correction = HomeAreaOverride(
            kind: .include, centerLatitude: athens.lat, centerLongitude: athens.lon,
            radiusKm: 1, homeID: originalID)
        let correctionID = correction.id
        ctx.insert(correction)
        try ctx.save()

        HomeSaveWorker.failHomeWorkerOverrideFetchForTesting = true
        defer { HomeSaveWorker.failHomeWorkerOverrideFetchForTesting = false }
        let result = HomeSaveWorker.apply(
            payload(target: .edit(originalID), coord: agiosDimitrios, label: "Moved"),
            context: ctx)

        #expect(result.failed)
        #expect(result != .noChange)
        #expect(result.reconcileHomeID == nil)
        #expect(!result.titleInputsChanged)
        #expect(!ctx.hasChanges)
        let fresh = ModelContext(container)
        let saved = try homes(fresh)
        #expect(saved.count == 1)
        let unchanged = try #require(saved.first)
        #expect(unchanged.id == originalID)
        #expect(unchanged.endedAt == nil)
        #expect(unchanged.label == "Home")
        #expect(unchanged.latitude == athens.lat)
        #expect(unchanged.longitude == athens.lon)
        let corrections = try fresh.fetch(FetchDescriptor<HomeAreaOverride>())
        #expect(corrections.count == 1)
        let savedCorrection = try #require(corrections.first)
        #expect(savedCorrection.id == correctionID)
        #expect(savedCorrection.homeID == originalID)
    }

    @Test("a home save error reports failure and rolls back title invalidation")
    func homeSaveFailureRollsBack() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let original = makeHome(in: ctx, coord: athens)
        let originalID = original.id
        let trip = Trip(startDate: now)
        trip.aiGeneratedTitle = "Athens Visit"
        ctx.insert(trip)
        ctx.insert(TripTitleVariant(
            languageTag: "de", title: "Athenbesuch",
            sourceTitle: "Athens Visit", trip: trip))
        try ctx.save()

        let result = HomeSaveWorker.apply(
            payload(target: .edit(originalID), coord: athens, locality: "Ioánnina"),
            context: ctx,
            save: { _ in throw CocoaError(.fileWriteUnknown) })

        #expect(result.failed)
        #expect(result != .noChange)
        #expect(result.reconcileHomeID == nil)
        #expect(!result.titleInputsChanged)
        #expect(!ctx.hasChanges)
        let fresh = ModelContext(container)
        let saved = try homes(fresh)
        #expect(saved.count == 1)
        let unchanged = try #require(saved.first)
        #expect(unchanged.id == originalID)
        #expect(unchanged.endedAt == nil)
        #expect(unchanged.locality == "Athens")
        let savedTrip = try #require(try fresh.fetch(FetchDescriptor<Trip>()).first)
        #expect(savedTrip.aiGeneratedTitle == "Athens Visit")
        #expect(try fresh.fetchCount(FetchDescriptor<TripTitleVariant>()) == 1)
    }

    @Test("edit beyond 1 km ends the old row and versions a new one")
    func editWithMoveVersionsNewHome() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let original = makeHome(in: ctx, coord: athens)
        try ctx.save()

        let result = HomeSaveWorker.apply(
            payload(target: .edit(original.id), coord: agiosDimitrios),
            context: ctx
        )

        #expect(original.endedAt == now)
        let all = try homes(ctx)
        #expect(all.count == 2)
        let created = try #require(all.first { $0.id != original.id })
        #expect(result.reconcileHomeID == created.id)
        // Same locality, country and ISO: the new row id alone leaves titles valid.
        #expect(!result.titleInputsChanged)
        #expect(created.startedAt == now)
    }

    @Test("in-place radius change updates the row and asks for reconciliation")
    func editInPlaceCoverageChangeReconciles() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let original = makeHome(in: ctx, coord: athens, radiusKm: 3)
        try ctx.save()

        let result = HomeSaveWorker.apply(
            payload(target: .edit(original.id), coord: athens, radiusKm: 8),
            context: ctx
        )

        #expect(result.reconcileHomeID == original.id)
        #expect(!result.titleInputsChanged)
        #expect(original.radiusKm == 8)
        #expect(try homes(ctx).count == 1)
    }

    @Test("label-only edit changes nothing that needs reconciliation")
    func editLabelOnlySkipsReconciliation() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let original = makeHome(in: ctx, coord: athens, radiusKm: 3, label: "Old")
        let trip = Trip(startDate: now)
        trip.aiGeneratedTitle = "Old Home Context"
        ctx.insert(trip)
        ctx.insert(TripTitleVariant(
            languageTag: "de",
            title: "Alter Heimatkontext",
            sourceTitle: "Old Home Context",
            trip: trip))
        try ctx.save()

        let result = HomeSaveWorker.apply(
            payload(target: .edit(original.id), coord: athens, label: "New", radiusKm: 3),
            context: ctx
        )

        #expect(result.reconcileHomeID == nil)
        #expect(!result.titleInputsChanged)
        #expect(original.label == "New")
        #expect(trip.aiGeneratedTitle == "Old Home Context")
        #expect(try ctx.fetchCount(FetchDescriptor<TripTitleVariant>()) == 1)
    }

    @Test("locality-only edit invalidates titles without coverage reconciliation")
    func editLocalityOnlyInvalidatesTitles() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let original = makeHome(in: ctx, coord: athens, radiusKm: 3)
        let trip = Trip(startDate: now)
        trip.aiGeneratedTitle = "Old Home Context"
        ctx.insert(trip)
        ctx.insert(TripTitleVariant(
            languageTag: "de",
            title: "Alter Heimatkontext",
            sourceTitle: "Old Home Context",
            trip: trip))
        try ctx.save()

        let result = HomeSaveWorker.apply(
            payload(
                target: .edit(original.id), coord: athens, label: "Home",
                radiusKm: 3, locality: "Ioánnina"),
            context: ctx
        )

        #expect(result.reconcileHomeID == nil)
        #expect(result.titleInputsChanged)
        #expect(original.locality == "Ioánnina")
        #expect(trip.aiGeneratedTitle == nil)
        #expect(try ctx.fetchCount(FetchDescriptor<TripTitleVariant>()) == 0)
    }

    /// A failed geocode must never blank fields the home pin, welcome
    /// notifications and the passport badge read.
    @Test("nil geocode fields never wipe existing place data")
    func nilGeocodeCoalescesRatherThanWipes() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let original = makeHome(in: ctx, coord: athens)
        try ctx.save()

        _ = HomeSaveWorker.apply(
            payload(
                target: .edit(original.id), coord: athens, label: "Renamed", radiusKm: 3,
                locality: nil, adminArea: nil, country: nil, iso: nil
            ),
            context: ctx
        )

        #expect(original.locality == "Athens")
        #expect(original.administrativeArea == "Attica")
        #expect(original.country == "Greece")
        #expect(original.isoCountryCode == "GR")
    }

    /// The row is gone before the worker
    /// runs, which the old inline `isDeleted` guard could not see.
    @Test("an edit whose target was deleted during the await writes nothing")
    func editOfDeletedHomeIsAbandoned() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let original = makeHome(in: ctx, coord: athens)
        let deletedID = original.id
        try ctx.save()
        ctx.delete(original)
        try ctx.save()

        let result = HomeSaveWorker.apply(
            payload(target: .edit(deletedID), coord: agiosDimitrios),
            context: ctx
        )

        #expect(result == .noChange)
        #expect(try homes(ctx).isEmpty)
    }

    @Test("failed onboarding Home save rolls back title invalidation")
    func onboardingSaveFailureRollsBackTitles() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = Trip(startDate: now)
        trip.aiGeneratedTitle = "Cycladic Summer"
        let revision = UUID()
        trip.titleSourceRevision = revision
        ctx.insert(trip)
        ctx.insert(TripTitleVariant(
            languageTag: "de",
            title: "Kykladischer Sommer",
            sourceTitle: "Cycladic Summer",
            sourceRevision: revision,
            trip: trip))
        try ctx.save()

        let home = Home(
            label: "Home",
            latitude: athens.lat,
            longitude: athens.lon,
            radiusKm: 3)
        #expect(throws: (any Error).self) {
            try OnboardingHomeSaveWorker.insert(
                home,
                in: ctx,
                save: { _ in throw CocoaError(.fileWriteUnknown) })
        }

        // Prove a later unrelated save cannot commit changes left pending by
        // the failed onboarding transaction.
        ctx.insert(RoutinePlace(
            label: "Office",
            latitude: agiosDimitrios.lat,
            longitude: agiosDimitrios.lon,
            radiusMeters: 300))
        try ctx.save()

        let fresh = ModelContext(container)
        #expect(try fresh.fetchCount(FetchDescriptor<Home>()) == 0)
        let reloaded = try #require(try fresh.fetch(FetchDescriptor<Trip>()).first)
        #expect(reloaded.aiGeneratedTitle == "Cycladic Summer")
        #expect(reloaded.titleSourceRevision == revision)
        #expect((reloaded.localizedTitles ?? []).count == 1)
    }
}
