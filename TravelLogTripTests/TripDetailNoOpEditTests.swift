//
//  TripDetailNoOpEditTests.swift
//  TravelLogTests
//
//  Trip detail edits: a rename to the current name or a re-picked category
//  leaves the trip unedited; a real edit is the user's own, changes only the
//  tapped physical rows, and reports read and save failures.
//
//  `@MainActor` because the app target compiles MainActor-by-default →
//  `@Model` types are MainActor-isolated.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

/// Edit then Done with an untouched name, or re-picking a stay's current
/// category, must not mark the trip `userEdited`: that flag exempts the trip
/// from reclassification and regrouping for good.
@MainActor
struct TripDetailNoOpEditTests {

    private func makeStay(start: Date, category: StayCategory) -> Stay {
        let stay = Stay(
            startTime: start,
            endTime: start.addingTimeInterval(7200),
            centroidLatitude: 37.98,
            centroidLongitude: 23.72,
            h3IndexRes6: "861f01a07ffffff",
            pingCount: 4,
            distanceFromHomeKm: 250,
            pingIDs: []
        )
        stay.category = category
        return stay
    }

    @Test("renaming to the current name leaves the trip unedited")
    func sameNameRenameIsNoOp() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_735_484_800)

        let named = Trip(startDate: base)
        named.customName = "Cephalonia"
        let unnamed = Trip(startDate: base.addingTimeInterval(86_400))
        ctx.insert(named)
        ctx.insert(unnamed)
        try ctx.save()

        #expect(TripDetailView.applyRename(tripID: named.id, tripIdentifier: named.persistentModelID, newName: "Cephalonia", in: ctx))
        #expect(named.userEdited == false)
        #expect(named.customName == "Cephalonia")

        #expect(TripDetailView.applyRename(tripID: unnamed.id, tripIdentifier: unnamed.persistentModelID, newName: nil, in: ctx))
        #expect(unnamed.userEdited == false)
        #expect(unnamed.customName == nil)

        #expect(TripDetailView.applyRename(tripID: named.id, tripIdentifier: named.persistentModelID, newName: "Samos", in: ctx))
        #expect(named.userEdited == true)
        #expect(named.customName == "Samos")
    }

    @Test("re-picking a stay's current category leaves flags and AI text alone")
    func sameCategoryChangeIsNoOp() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_735_484_800)

        let trip = Trip(startDate: base)
        ctx.insert(trip)
        let stay = makeStay(start: base, category: .destination)
        ctx.insert(stay)
        stay.trip = trip
        trip.aiGeneratedTitle = "Island Hopping"
        trip.aiGeneratedSummary = "A week in the Cyclades."
        try ctx.save()

        #expect(TripDetailView.applyCategoryChange(
            stayID: stay.id, stayIdentifier: stay.persistentModelID,
            tripID: trip.id, tripIdentifier: trip.persistentModelID, newCategory: .destination, in: ctx))
        #expect(stay.userOverridden == false)
        #expect(trip.userEdited == false)
        #expect(trip.aiGeneratedTitle == "Island Hopping")
        #expect(trip.aiGeneratedSummary == "A week in the Cyclades.")

        #expect(TripDetailView.applyCategoryChange(
            stayID: stay.id, stayIdentifier: stay.persistentModelID,
            tripID: trip.id, tripIdentifier: trip.persistentModelID, newCategory: .transit, in: ctx))
        #expect(stay.category == .transit)
        #expect(stay.userOverridden == true)
        #expect(trip.userEdited == true)
    }

    @Test("a rename and a category change are the user's own edits: a temporary home's mark on the trip goes, the edit stays")
    func userEditsClearATemporaryHomesMark() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_735_484_800)

        let renamed = Trip(startDate: base)
        let recategorized = Trip(startDate: base.addingTimeInterval(86_400))
        for trip in [renamed, recategorized] {
            trip.userEdited = true
            trip.keptByTemporaryHome = true
            ctx.insert(trip)
        }
        let stay = makeStay(start: base.addingTimeInterval(86_400), category: .destination)
        ctx.insert(stay)
        stay.trip = recategorized
        try ctx.save()

        #expect(TripDetailView.applyRename(tripID: renamed.id, tripIdentifier: renamed.persistentModelID, newName: "Erasmus", in: ctx))
        #expect(TripDetailView.applyCategoryChange(
            stayID: stay.id, stayIdentifier: stay.persistentModelID,
            tripID: recategorized.id, tripIdentifier: recategorized.persistentModelID, newCategory: .transit, in: ctx))

        let fresh = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        #expect(fresh.count == 2)
        for trip in fresh {
            #expect(trip.userEdited)
            #expect(!trip.keptByTemporaryHome)
        }
    }
    @Test("category changes edit only the tapped physical rows", arguments: [false, true])
    func categoryChangeUsesPhysicalRows(tappedFirst: Bool) throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_735_484_800)
        let tapped = Trip(startDate: base)
        let twin = Trip(startDate: base)
        twin.id = tapped.id
        for row in tappedFirst ? [tapped, twin] : [twin, tapped] { ctx.insert(row) }
        let stay = makeStay(start: base, category: .destination)
        let stayTwin = makeStay(start: base, category: .destination)
        stayTwin.id = stay.id
        ctx.insert(stay)
        ctx.insert(stayTwin)
        stay.trip = tapped
        stayTwin.trip = twin
        tapped.aiGeneratedTitle = "Tapped title"
        twin.aiGeneratedTitle = "Twin title"
        try ctx.save()

        #expect(TripDetailView.applyCategoryChange(
            stayID: stay.id, stayIdentifier: stay.persistentModelID,
            tripID: tapped.id, tripIdentifier: tapped.persistentModelID, newCategory: .transit, in: ctx))
        #expect(stay.category == .transit)
        #expect(stay.userOverridden)
        #expect(tapped.userEdited)
        #expect(tapped.aiGeneratedTitle == nil)
        #expect(stayTwin.category == .destination)
        #expect(!stayTwin.userOverridden)
        #expect(!twin.userEdited)
        #expect(twin.aiGeneratedTitle == "Twin title")
    }

    @Test("a moved or deleted stay is not replaced by its UUID twin", arguments: [false, true])
    func categoryChangeRejectsStaleStay(deleted: Bool) throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_735_484_800)
        let trip = Trip(startDate: base)
        let elsewhere = Trip(startDate: base)
        elsewhere.id = trip.id
        ctx.insert(trip)
        ctx.insert(elsewhere)
        let stay = makeStay(start: base, category: .destination)
        let twin = makeStay(start: base, category: .destination)
        twin.id = stay.id
        ctx.insert(stay)
        ctx.insert(twin)
        stay.trip = trip
        twin.trip = trip
        try ctx.save()
        let stayID = stay.id
        let stayRow = stay.persistentModelID
        if deleted { ctx.delete(stay) } else { stay.trip = elsewhere }
        try ctx.save()

        #expect(!TripDetailView.applyCategoryChange(
            stayID: stayID, stayIdentifier: stayRow,
            tripID: trip.id, tripIdentifier: trip.persistentModelID, newCategory: .transit, in: ctx))
        #expect(twin.category == .destination)
        #expect(!trip.userEdited)
        #expect(!elsewhere.userEdited)
        #expect(!ctx.hasChanges)
    }

    #if DEBUG
    @Test("category read and save failures report failure and preserve unrelated edits",
          arguments: [TripDetailView.EditFault.categoryRead, .categorySave])
    func categoryChangeFailurePreservesPendingEdit(fault: TripDetailView.EditFault) throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_735_484_800)
        let trip = Trip(startDate: base)
        let unrelated = Trip(startDate: base)
        ctx.insert(trip)
        ctx.insert(unrelated)
        let stay = makeStay(start: base, category: .destination)
        ctx.insert(stay)
        stay.trip = trip
        trip.aiGeneratedTitle = "Keep title"
        try ctx.save()
        let tripID = trip.id
        let unrelatedID = unrelated.id
        unrelated.customName = "Earlier pending edit"

        TripDetailView.$editFaultForTesting.withValue(fault) {
            #expect(!TripDetailView.applyCategoryChange(
                stayID: stay.id, stayIdentifier: stay.persistentModelID,
                tripID: tripID, tripIdentifier: trip.persistentModelID, newCategory: .transit, in: ctx))
        }
        let fresh = ModelContext(container)
        let trips = try fresh.fetch(FetchDescriptor<Trip>())
        #expect(trips.first { $0.id == unrelatedID }?.customName == "Earlier pending edit")
        let unchanged = try #require(trips.first { $0.id == tripID })
        #expect(!unchanged.userEdited)
        #expect(unchanged.aiGeneratedTitle == "Keep title")
        #expect(unchanged.stays?.first?.category == .destination)
        #expect(unchanged.stays?.first?.userOverridden == false)
        #expect(!ctx.hasChanges)
    }
    #endif

}
