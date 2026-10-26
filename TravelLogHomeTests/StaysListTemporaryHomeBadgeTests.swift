//
//  StaysListTemporaryHomeBadgeTests.swift
//  TravelLogTests
//
//  All Stays badges a home stay "Temporary Home" only when a live temporary
//  home recorded it (`Stay.temporaryHomeID`, as the classifier stamps a stay
//  it makes home inside that home's dates), never by the nearest centre. A
//  stay at the real Home, or at the same place outside the dates, keeps the
//  "Home" badge.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("All Stays temporary-home badge")
struct StaysListTemporaryHomeBadgeTests {

    private let start = Date(timeIntervalSinceReferenceDate: 770_969_600)
    private var end: Date { start.addingTimeInterval(150 * 86_400) }

    private func stay(
        _ context: ModelContext, at time: Date, _ category: StayCategory,
        latitude: Double, longitude: Double, by owner: UUID? = nil
    ) -> Stay {
        let stay = Stay(
            startTime: time, endTime: time.addingTimeInterval(6 * 3_600),
            centroidLatitude: latitude, centroidLongitude: longitude,
            h3IndexRes6: H3Service.cellIndex(latitude: latitude, longitude: longitude)!,
            pingCount: 3, distanceFromHomeKm: 0, pingIDs: [])
        context.insert(stay)
        stay.category = category
        stay.temporaryHomeID = owner
        return stay
    }

    /// Athens is home throughout; Brussels is a temporary home from `start`
    /// to `end`. Returns the context, the anchors the list resolves against
    /// and the temporary home's id.
    private func seededStore() throws -> (context: ModelContext, anchors: [HomeAnchor], temporaryID: UUID) {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        context.insert(Home(label: "Home", latitude: 37.9838, longitude: 23.7275,
                            startedAt: start.addingTimeInterval(-1_000 * 86_400)))
        let temporary = TemporaryHome(
            label: "Erasmus", latitude: 50.8882, longitude: 4.3222, startedAt: start, endedAt: end)
        context.insert(temporary)
        try context.save()
        let anchors = try HomeAnchors.fetch(in: context)
        return (context, anchors, temporary.id)
    }

    @Test("a home stay at the base inside the dates belongs to the temporary home")
    func baseStayIsTemporary() throws {
        let seeded = try seededStore()
        let base = stay(seeded.context, at: start.addingTimeInterval(40 * 86_400), .home,
                        latitude: 50.8845, longitude: 4.3233, by: seeded.temporaryID)
        let owner = StaysListView.temporaryHomeOwner(of: base, anchors: seeded.anchors)
        #expect(owner?.id == seeded.temporaryID)
        #expect(owner?.kind == .temporary)
    }

    @Test("a home stay at the base inside the dates that nothing recorded keeps the Home badge")
    func unrecordedBaseStayIsNotTemporary() throws {
        let seeded = try seededStore()
        let base = stay(seeded.context, at: start.addingTimeInterval(40 * 86_400), .home,
                        latitude: 50.8845, longitude: 4.3233)
        #expect(StaysListView.temporaryHomeOwner(of: base, anchors: seeded.anchors) == nil)
    }

    @Test("a home stay the temporary home recorded is badged wherever its centroid lies")
    func recordedStayFarFromTheCentreIsTemporary() throws {
        let seeded = try seededStore()
        let recorded = stay(seeded.context, at: start.addingTimeInterval(40 * 86_400), .home,
                            latitude: 37.9838, longitude: 23.7275, by: seeded.temporaryID)
        #expect(StaysListView.temporaryHomeOwner(of: recorded, anchors: seeded.anchors)?.id
                == seeded.temporaryID)
    }

    @Test("a home stay recorded by a temporary home this store does not hold live keeps the Home badge")
    func unknownOwnerIsNotTemporary() throws {
        let seeded = try seededStore()
        let orphan = stay(seeded.context, at: start.addingTimeInterval(40 * 86_400), .home,
                          latitude: 50.8845, longitude: 4.3233, by: UUID())
        #expect(StaysListView.temporaryHomeOwner(of: orphan, anchors: seeded.anchors) == nil)
    }

    @Test("a home stay in Athens inside the dates keeps the Home badge")
    func athensStayIsNotTemporary() throws {
        let seeded = try seededStore()
        let visit = stay(seeded.context, at: start.addingTimeInterval(60 * 86_400), .home,
                         latitude: 37.9838, longitude: 23.7275)
        #expect(StaysListView.temporaryHomeOwner(of: visit, anchors: seeded.anchors) == nil)
    }

    @Test("a home stay at the base before the start or after the end keeps the Home badge")
    func stayOutsideTheDatesIsNotTemporary() throws {
        let seeded = try seededStore()
        let before = stay(seeded.context, at: start.addingTimeInterval(-86_400), .home,
                          latitude: 50.8845, longitude: 4.3233)
        let after = stay(seeded.context, at: end.addingTimeInterval(86_400), .home,
                         latitude: 50.8845, longitude: 4.3233)
        #expect(StaysListView.temporaryHomeOwner(of: before, anchors: seeded.anchors) == nil)
        #expect(StaysListView.temporaryHomeOwner(of: after, anchors: seeded.anchors) == nil)
    }

    @Test("a stay at the base that is not home-category gets no temporary-home badge")
    func otherCategoriesAreNotTemporary() throws {
        let seeded = try seededStore()
        let time = start.addingTimeInterval(40 * 86_400)
        for category in [StayCategory.destination, .routine, .transit, .unclassified] {
            let other = stay(seeded.context, at: time, category, latitude: 50.8845, longitude: 4.3233)
            #expect(StaysListView.temporaryHomeOwner(of: other, anchors: seeded.anchors) == nil)
        }
    }

    @Test("with no temporary home no stay is badged temporary")
    func noTemporaryHome() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        context.insert(Home(label: "Home", latitude: 37.9838, longitude: 23.7275,
                            startedAt: start.addingTimeInterval(-1_000 * 86_400)))
        try context.save()
        let anchors = try HomeAnchors.fetch(in: context)
        let home = stay(context, at: start, .home, latitude: 37.9838, longitude: 23.7275)
        #expect(StaysListView.temporaryHomeOwner(of: home, anchors: anchors) == nil)
    }
}
