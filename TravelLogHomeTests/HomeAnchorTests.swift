//
//  HomeAnchorTests.swift
//  TravelLogTests
//
//  Pins the anchor list classification and attribution read: which rows it
//  returns and as what kind, the same-id twin rule, the inclusive date
//  window, and the `TemporaryHome` model's own date and label rules.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Home anchors")
struct HomeAnchorTests {

    private let base = Date(timeIntervalSince1970: 1_703_024_000)
    private let day: TimeInterval = 86_400

    private let athens = (lat: 37.9838, lon: 23.7275)
    private let brussels = (lat: 50.8002, lon: 4.2835)
    private let dendermonde = (lat: 51.0289, lon: 4.1006)

    private func anchor(
        _ kind: HomeAnchor.Kind, id: UUID = UUID(),
        at place: (lat: Double, lon: Double),
        from start: Date, to end: Date? = nil
    ) -> HomeAnchor {
        HomeAnchor(
            id: id, kind: kind, label: "", latitude: place.lat, longitude: place.lon,
            radiusKm: 25, locality: nil, isoCountryCode: nil, startedAt: start, endedAt: end)
    }

    private func temporaryHome(
        id: UUID, label: String, modifiedAt: Date, createdAt: Date
    ) -> TemporaryHome {
        let row = TemporaryHome(
            label: label, latitude: brussels.lat, longitude: brussels.lon, startedAt: base)
        row.id = id
        row.modifiedAt = modifiedAt
        row.createdAt = createdAt
        return row
    }

    // MARK: - fetch

    @Test("fetch returns every Home as a home anchor and every temporary home as a temporary anchor, with their stored fields")
    func fetchReturnsBothKinds() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let ended = Home(label: "London Flat", latitude: 51.5591, longitude: -0.1062,
                         radiusKm: 30, startedAt: base.addingTimeInterval(-400 * day))
        ended.endedAt = base.addingTimeInterval(-200 * day)
        let current = Home(label: "", latitude: athens.lat, longitude: athens.lon,
                           radiusKm: 25, startedAt: base.addingTimeInterval(-200 * day))
        current.locality = "Athens"
        current.isoCountryCode = "GR"
        let semester = TemporaryHome(
            label: "Erasmus", latitude: brussels.lat, longitude: brussels.lon,
            startedAt: base, endedAt: base.addingTimeInterval(150 * day))
        semester.locality = "Brussels"
        semester.isoCountryCode = "BE"
        semester.radiusKm = 12
        context.insert(ended)
        context.insert(current)
        context.insert(semester)
        try context.save()

        let anchors = try HomeAnchors.fetch(in: ModelContext(container))

        #expect(anchors.count == 3)
        let byID = Dictionary(uniqueKeysWithValues: anchors.map { ($0.id, $0) })
        #expect(byID[ended.id]?.kind == .home, "an ended Home is still returned; callers apply windows")
        #expect(byID[ended.id]?.endedAt == base.addingTimeInterval(-200 * day))
        #expect(byID[current.id] == HomeAnchor(
            id: current.id, kind: .home, label: "", latitude: athens.lat, longitude: athens.lon,
            radiusKm: 25, locality: "Athens", isoCountryCode: "GR",
            startedAt: base.addingTimeInterval(-200 * day), endedAt: nil))
        #expect(byID[semester.id] == HomeAnchor(
            id: semester.id, kind: .temporary, label: "Erasmus",
            latitude: brussels.lat, longitude: brussels.lon,
            radiusKm: 12, locality: "Brussels", isoCountryCode: "BE",
            startedAt: base, endedAt: base.addingTimeInterval(150 * day)))
        #expect(byID[semester.id]?.isTemporary == true)
        #expect(byID[current.id]?.isTemporary == false)
        #expect(try HomeAnchors.temporaryHomes(in: ModelContext(container)).map(\.id) == [semester.id])
    }

    @Test("with no temporary home, fetch returns exactly the Home rows and temporaryHomes is empty")
    func fetchWithoutTemporaryHomes() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let home = Home(label: "Home", latitude: athens.lat, longitude: athens.lon,
                        radiusKm: 25, startedAt: base)
        context.insert(home)
        try context.save()

        let anchors = try HomeAnchors.fetch(in: context)
        #expect(anchors.map(\.id) == [home.id])
        #expect(anchors.allSatisfy { $0.kind == .home })
        #expect(try HomeAnchors.temporaryHomes(in: context).isEmpty)
    }

    @Test("temporary homes come back ordered by start date")
    func temporaryHomesAreOrderedByStart() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let later = TemporaryHome(label: "Later", latitude: brussels.lat, longitude: brussels.lon,
                                  startedAt: base.addingTimeInterval(300 * day))
        let earlier = TemporaryHome(label: "Earlier", latitude: dendermonde.lat, longitude: dendermonde.lon,
                                    startedAt: base)
        context.insert(later)
        context.insert(earlier)
        try context.save()

        #expect(try HomeAnchors.temporaryHomes(in: context).map(\.label) == ["Earlier", "Later"])
    }

    // MARK: - Same-id twins

    @Test("the store keeps two rows with one id, and they read as one temporary home whichever was inserted first")
    func twinsCollapseIndependentOfInsertionOrder() throws {
        let sharedID = UUID()
        for newerFirst in [true, false] {
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            let older = temporaryHome(
                id: sharedID, label: "Old name", modifiedAt: base, createdAt: base)
            let newer = temporaryHome(
                id: sharedID, label: "New name",
                modifiedAt: base.addingTimeInterval(day), createdAt: base)
            for row in newerFirst ? [newer, older] : [older, newer] { context.insert(row) }
            try context.save()

            let reader = ModelContext(container)
            let anchors = try HomeAnchors.temporaryHomes(in: reader)
            #expect(anchors.map(\.id) == [sharedID])
            #expect(anchors.first?.label == "New name", "the latest edit wins")
            #expect(try HomeAnchors.fetch(in: reader).count == 1)
            #expect(try reader.fetchCount(FetchDescriptor<TemporaryHome>()) == 2,
                    "reading never deletes a twin row")
            #expect(!reader.hasChanges)
        }
    }

    @Test("twin ranking is latest modifiedAt, then earliest createdAt, then stored content, in either order")
    func twinRankingIsDeterministic() {
        let id = UUID()
        func winner(_ a: TemporaryHome, _ b: TemporaryHome) -> [String] {
            let forward = HomeAnchors.collapsingTwins([a, b]).map(\.label)
            let reversed = HomeAnchors.collapsingTwins([b, a]).map(\.label)
            #expect(forward == reversed, "the winner must not depend on row order")
            return forward
        }

        #expect(winner(
            temporaryHome(id: id, label: "Edited later", modifiedAt: base.addingTimeInterval(60),
                          createdAt: base.addingTimeInterval(30)),
            temporaryHome(id: id, label: "Edited earlier", modifiedAt: base, createdAt: base)
        ) == ["Edited later"])

        #expect(winner(
            temporaryHome(id: id, label: "Created first", modifiedAt: base, createdAt: base),
            temporaryHome(id: id, label: "Created second", modifiedAt: base,
                          createdAt: base.addingTimeInterval(30))
        ) == ["Created first"])

        #expect(winner(
            temporaryHome(id: id, label: "B", modifiedAt: base, createdAt: base),
            temporaryHome(id: id, label: "A", modifiedAt: base, createdAt: base)
        ) == ["A"])

        // Same dates and label: a later stored field still decides.
        let withEnd = temporaryHome(id: id, label: "Same", modifiedAt: base, createdAt: base)
        withEnd.endedAt = base.addingTimeInterval(day)
        withEnd.locality = "Has an end"
        let openEnded = temporaryHome(id: id, label: "Same", modifiedAt: base, createdAt: base)
        openEnded.locality = "Open"
        let forward = HomeAnchors.collapsingTwins([withEnd, openEnded]).map(\.locality)
        let reversed = HomeAnchors.collapsingTwins([openEnded, withEnd]).map(\.locality)
        #expect(forward.count == 1)
        #expect(forward == reversed)

        // Different ids are different temporary homes.
        let other = temporaryHome(id: UUID(), label: "Other", modifiedAt: base, createdAt: base)
        #expect(HomeAnchors.collapsingTwins([withEnd, other]).count == 2)
    }

    @Test("two rows with one id and identical stored content resolve to the same physical row in either order")
    func identicalTwinsResolveToOneRowInEitherOrder() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let id = UUID()
        // What two imports of one backup leave: nothing tells the rows apart.
        let first = temporaryHome(id: id, label: "Erasmus", modifiedAt: base, createdAt: base)
        let second = temporaryHome(id: id, label: "Erasmus", modifiedAt: base, createdAt: base)
        context.insert(first)
        context.insert(second)
        try context.save()

        let forward = HomeAnchors.collapsingTwins([first, second])
        let reversed = HomeAnchors.collapsingTwins([second, first])
        #expect(forward.count == 1)
        #expect(reversed.count == 1)
        #expect(forward.first?.persistentModelID == reversed.first?.persistentModelID)
    }

    // MARK: - Removal

    @Test("a removed id is gone whichever twin arrives: a live same-id row written later, inserted before or after the removed one, does not bring it back, other ids still read, and nothing is deleted")
    func removedIDIsDroppedWhateverTwinArrives() throws {
        let removedID = UUID()
        for liveFirst in [true, false] {
            let container = try TestSupport.makeInMemoryContainer()
            let context = ModelContext(container)
            let tombstone = temporaryHome(
                id: removedID, label: "Erasmus", modifiedAt: base, createdAt: base)
            tombstone.removedAt = base
            // Another device's copy: later edit, other dates, never removed.
            let lateTwin = temporaryHome(
                id: removedID, label: "Erasmus", modifiedAt: base.addingTimeInterval(30 * day),
                createdAt: base)
            lateTwin.startedAt = base.addingTimeInterval(-10 * day)
            lateTwin.endedAt = base.addingTimeInterval(200 * day)
            let other = temporaryHome(id: UUID(), label: "Other", modifiedAt: base, createdAt: base)
            for row in liveFirst ? [lateTwin, tombstone, other] : [tombstone, lateTwin, other] {
                context.insert(row)
            }
            try context.save()

            let reader = ModelContext(container)
            let rows = try reader.fetch(FetchDescriptor<TemporaryHome>())
            #expect(HomeAnchors.collapsingTwins(rows).map(\.id) == [other.id])
            #expect(try HomeAnchors.temporaryHomes(in: reader).map(\.id) == [other.id])
            #expect(try HomeAnchors.fetch(in: reader).map(\.id) == [other.id])
            #expect(HomeAnchors.removedIDs(rows) == [removedID])
            #expect(try reader.fetchCount(FetchDescriptor<TemporaryHome>()) == 3,
                    "reading never deletes a removed row or its twin")
            #expect(!reader.hasChanges)
        }
    }

    @Test("removedTwins gives one removed row per removed id, the same in either order, and never a live row of that id")
    func removedTwinsAreDeterministic() {
        let id = UUID()
        let first = temporaryHome(id: id, label: "B", modifiedAt: base, createdAt: base)
        first.removedAt = base.addingTimeInterval(day)
        let second = temporaryHome(id: id, label: "A", modifiedAt: base, createdAt: base)
        second.removedAt = base.addingTimeInterval(day)
        let live = temporaryHome(
            id: id, label: "Live", modifiedAt: base.addingTimeInterval(9 * day), createdAt: base)
        let unrelated = temporaryHome(id: UUID(), label: "Other", modifiedAt: base, createdAt: base)

        let forward = HomeAnchors.removedTwins([first, live, second, unrelated])
        let reversed = HomeAnchors.removedTwins([unrelated, second, live, first])
        #expect(forward.map(\.label) == ["A"])
        #expect(reversed.map(\.label) == ["A"])
        #expect(HomeAnchors.removedIDs([first, live, second, unrelated]) == [id])
        #expect(HomeAnchors.removedTwins([live, unrelated]).isEmpty)
        #expect(HomeAnchors.removedIDs([live, unrelated]).isEmpty)
    }

    // MARK: - covers

    @Test("covers is inclusive at both ends and false outside them")
    func coversIsInclusive() {
        let end = base.addingTimeInterval(100 * day)
        let dated = anchor(.temporary, at: brussels, from: base, to: end)
        #expect(!dated.covers(base.addingTimeInterval(-1)))
        #expect(dated.covers(base))
        #expect(dated.covers(base.addingTimeInterval(50 * day)))
        #expect(dated.covers(end))
        #expect(!dated.covers(end.addingTimeInterval(1)))
    }

    @Test("covers is open-ended when endedAt is nil, and a future start does not cover now")
    func coversOpenEndedAndFutureStart() {
        let now = base
        let openEnded = anchor(.temporary, at: brussels, from: now.addingTimeInterval(-day))
        #expect(openEnded.covers(now))
        #expect(openEnded.covers(now.addingTimeInterval(10_000 * day)))

        let future = anchor(.temporary, at: brussels, from: now.addingTimeInterval(30 * day))
        #expect(!future.covers(now))
        #expect(future.covers(now.addingTimeInterval(30 * day)))

        let futureEnd = anchor(.temporary, at: brussels, from: now.addingTimeInterval(-day),
                               to: now.addingTimeInterval(90 * day))
        #expect(futureEnd.covers(now), "an end date in the future still covers today")
    }

    // MARK: - TemporaryHome

    @Test("a new temporary home keeps the dates it was given and the fallback radius")
    func temporaryHomeInitKeepsTheUsersDates() {
        let end = base.addingTimeInterval(120 * day)
        let dated = TemporaryHome(
            label: "Erasmus", latitude: brussels.lat, longitude: brussels.lon,
            startedAt: base, endedAt: end)
        #expect(dated.startedAt == base)
        #expect(dated.endedAt == end)
        #expect(dated.radiusKm == 25)
        #expect(dated.latitude == brussels.lat)
        #expect(dated.longitude == brussels.lon)

        let openEnded = TemporaryHome(
            label: "", latitude: brussels.lat, longitude: brussels.lon, startedAt: base)
        #expect(openEnded.endedAt == nil)
        #expect(openEnded.id != dated.id)
    }

    @Test("isActive is true from the start instant through the end instant, and open-ended without an end")
    func temporaryHomeIsActive() {
        let end = base.addingTimeInterval(120 * day)
        let dated = TemporaryHome(
            label: "Erasmus", latitude: brussels.lat, longitude: brussels.lon,
            startedAt: base, endedAt: end)
        #expect(!dated.isActive(at: base.addingTimeInterval(-1)), "a future start is not active yet")
        #expect(dated.isActive(at: base))
        #expect(dated.isActive(at: base.addingTimeInterval(60 * day)))
        #expect(dated.isActive(at: end))
        #expect(!dated.isActive(at: end.addingTimeInterval(1)))

        let openEnded = TemporaryHome(
            label: "Erasmus", latitude: brussels.lat, longitude: brussels.lon, startedAt: base)
        #expect(openEnded.isActive(at: base.addingTimeInterval(10_000 * day)))
        #expect(!openEnded.isActive(at: base.addingTimeInterval(-day)))
    }

    @Test("displayLabel is the user's label, else the place name, else the default name")
    func temporaryHomeDisplayLabelFallbacks() {
        let english = Locale(identifier: "en")
        let row = TemporaryHome(
            label: "Erasmus", latitude: brussels.lat, longitude: brussels.lon, startedAt: base)
        row.locality = "Brussels"
        #expect(row.displayLabel(locale: english) == "Erasmus")

        row.label = ""
        #expect(row.displayLabel(locale: english) == "Brussels")

        row.locality = ""
        #expect(row.displayLabel(locale: english) == "Temporary Home")

        row.locality = nil
        #expect(row.displayLabel(locale: english) == "Temporary Home")
    }
}
