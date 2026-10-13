//
//  HomeEndOutcomeTests.swift
//  TravelLogTests
//
//  Removing a Home in Settings reports what happened, so a failed
//  read or save raises the save-error alert and a refusal raises the
//  last-Home alert, instead of the row silently reappearing. Driven through
//  `SettingsView.endHomes(ids:context:)`, the gated body of the swipe.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

// Serialized: `SettingsView.failHomeEndFetchForTesting` is static.
@MainActor
@Suite(.serialized)
struct HomeEndOutcomeTests {

    private let fingerprintKey = TripTitleStore.activeHomeTitleFingerprintKey

    /// The title fingerprint lives in `.standard`; put back what was there.
    private func preservingFingerprint(_ body: () throws -> Void) rethrows {
        let saved = UserDefaults.standard.object(forKey: fingerprintKey)
        defer { UserDefaults.standard.set(saved, forKey: fingerprintKey) }
        try body()
    }

    private func makeHome(
        _ ctx: ModelContext, label: String, lat: Double, locality: String
    ) -> Home {
        let home = Home(label: label, latitude: lat, longitude: 23.7, radiusKm: 3)
        home.locality = locality
        home.country = "Greece"
        home.isoCountryCode = "GR"
        ctx.insert(home)
        return home
    }

    private func activeIDs(_ container: ModelContainer) throws -> Set<UUID> {
        Set(try ModelContext(container).fetch(FetchDescriptor<Home>(
            predicate: #Predicate { $0.endedAt == nil })).map(\.id))
    }

    @Test("ending one of two active Homes commits and invalidates Home-derived titles")
    func endingCommits() throws {
        try preservingFingerprint {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let athens = makeHome(ctx, label: "Athens", lat: 37.98, locality: "Athens")
            let xanthi = makeHome(ctx, label: "Xánthi", lat: 38.25, locality: "Xánthi")
            let trip = Trip(startDate: .now)
            trip.aiGeneratedTitle = "Xánthi Weekend"
            ctx.insert(trip)
            try ctx.save()

            #expect(SettingsView.endHomes(ids: [xanthi.id], context: ctx) == .ended)
            #expect(try activeIDs(container) == [athens.id])
            let reloaded = try #require(try ModelContext(container).fetch(FetchDescriptor<Trip>()).first)
            #expect(reloaded.aiGeneratedTitle == nil)
        }
    }

    @Test("ending the last active Home is refused and changes nothing")
    func lastHomeIsRefused() throws {
        try preservingFingerprint {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let only = makeHome(ctx, label: "Athens", lat: 37.98, locality: "Athens")
            try ctx.save()

            #expect(SettingsView.endHomes(ids: [only.id], context: ctx) == .refusedLastHome)
            #expect(!ctx.hasChanges)
            #expect(try activeIDs(container) == [only.id])
        }
    }

    @Test("a Home ended elsewhere while the swipe waited turns the request into a last-Home refusal")
    func concurrentEndIsRefused() throws {
        try preservingFingerprint {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let athens = makeHome(ctx, label: "Athens", lat: 37.98, locality: "Athens")
            let xanthi = makeHome(ctx, label: "Xánthi", lat: 38.25, locality: "Xánthi")
            try ctx.save()
            #expect(try activeIDs(container) == [athens.id, xanthi.id])

            let other = ModelContext(container)
            let synced = try #require(try other.fetch(FetchDescriptor<Home>()).first { $0.id == xanthi.id })
            synced.endedAt = .now
            try other.save()

            #expect(SettingsView.endHomes(ids: [athens.id], context: ctx) == .refusedLastHome)
            #expect(try activeIDs(container) == [athens.id])
        }
    }

    @Test("unknown and already-ended Homes are nothing to end")
    func nothingToEnd() throws {
        try preservingFingerprint {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let athens = makeHome(ctx, label: "Athens", lat: 37.98, locality: "Athens")
            let old = makeHome(ctx, label: "Old", lat: 38.25, locality: "Xánthi")
            old.endedAt = .now
            try ctx.save()

            #expect(SettingsView.endHomes(ids: [old.id, UUID()], context: ctx) == .nothingToEnd)
            #expect(!ctx.hasChanges)
            #expect(try activeIDs(container) == [athens.id])
        }
    }

    @Test("a failed active-Home read reports failure, keeps the Home, and keeps an earlier pending edit")
    func readFailureReportsFailure() throws {
        try preservingFingerprint {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let athens = makeHome(ctx, label: "Athens", lat: 37.98, locality: "Athens")
            let xanthi = makeHome(ctx, label: "Xánthi", lat: 38.25, locality: "Xánthi")
            try ctx.save()
            // An unrelated edit pending on the shared context.
            athens.label = "Home"

            SettingsView.failHomeEndFetchForTesting = true
            defer { SettingsView.failHomeEndFetchForTesting = false }
            #expect(SettingsView.endHomes(ids: [xanthi.id], context: ctx) == .failed)
            #expect(try activeIDs(container) == [athens.id, xanthi.id])
            let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<Home>())
                .first { $0.id == athens.id })
            #expect(saved.label == "Home")
        }
    }

    @Test("a failed pre-save reports failure before ending anything and leaves the earlier edit pending")
    func preSaveFailureReportsFailure() throws {
        try preservingFingerprint {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let athens = makeHome(ctx, label: "Athens", lat: 37.98, locality: "Athens")
            let xanthi = makeHome(ctx, label: "Xánthi", lat: 38.25, locality: "Xánthi")
            try ctx.save()
            athens.label = "Home"

            #expect(SettingsView.endHomes(
                ids: [xanthi.id], context: ctx,
                save: { _ in throw CocoaError(.fileWriteUnknown) }) == .failed)
            #expect(ctx.hasChanges, "the unrelated edit is neither committed nor discarded")
            #expect(athens.label == "Home")
            #expect(xanthi.endedAt == nil)
            #expect(try activeIDs(container) == [athens.id, xanthi.id])
        }
    }

    @Test("a failed final save rolls the removal and its title invalidation back")
    func finalSaveFailureRollsBack() throws {
        try preservingFingerprint {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            let athens = makeHome(ctx, label: "Athens", lat: 37.98, locality: "Athens")
            let xanthi = makeHome(ctx, label: "Xánthi", lat: 38.25, locality: "Xánthi")
            let trip = Trip(startDate: .now)
            trip.aiGeneratedTitle = "Xánthi Weekend"
            ctx.insert(trip)
            try ctx.save()

            #expect(SettingsView.endHomes(
                ids: [xanthi.id], context: ctx,
                save: { _ in throw CocoaError(.fileWriteUnknown) }) == .failed)
            #expect(!ctx.hasChanges)
            #expect(xanthi.endedAt == nil)
            #expect(trip.aiGeneratedTitle == "Xánthi Weekend")
            #expect(try activeIDs(container) == [athens.id, xanthi.id])

            // A retry without the fault commits.
            #expect(SettingsView.endHomes(ids: [xanthi.id], context: ctx) == .ended)
            #expect(try activeIDs(container) == [athens.id])
        }
    }
}
