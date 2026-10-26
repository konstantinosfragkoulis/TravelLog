//
//  SchemaV21Tests.swift
//  TravelLogTests
//
//  The V21 model helpers: a stay's temporary-home provenance is a pair (the
//  declaration and the coverage revision that stamped it), written and
//  cleared together; a declaration's kept trips are a canonical comma string
//  that only grows, read as a union over every row of an id; and the next
//  coverage revision is one above every row's. The migrations themselves
//  live in `MigrationChainTests`.
//
//  @MainActor because the app target compiles with MainActor-by-default
//  isolation; persistence checks re-fetch from a fresh context.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Schema V21 helpers")
struct SchemaV21Tests {

    private static let start = Date(timeIntervalSince1970: 1_674_598_400)

    private func stay() -> Stay {
        Stay(
            startTime: Self.start, endTime: Self.start.addingTimeInterval(3_600),
            centroidLatitude: 50.85, centroidLongitude: 4.35,
            h3IndexRes6: "861fa4d07ffffff", pingCount: 2,
            distanceFromHomeKm: 0, pingIDs: [])
    }

    private func temporaryHome(id: UUID = UUID(), kept: String = "", revision: Int = 0) -> TemporaryHome {
        let row = TemporaryHome(label: "Erasmus", latitude: 50.85, longitude: 4.35,
                                startedAt: Self.start)
        row.id = id
        row.keptTripIDs = kept
        row.coverageRevision = revision
        return row
    }

    // MARK: - Stay provenance pair

    @Test("a stay that leaves home loses both halves of its provenance, whatever category it becomes; staying home keeps them")
    func leavingHomeClearsThePair() {
        let id = UUID()
        for category in StayCategory.allCases where category != .home {
            let row = stay()
            row.category = .home
            row.setTemporaryHomeProvenance(id, revision: 4)
            row.category = .home
            #expect(row.temporaryHomeID == id)
            #expect(row.temporaryHomeRevision == 4)
            row.category = category
            #expect(row.temporaryHomeID == nil, "\(category)")
            #expect(row.temporaryHomeRevision == nil, "\(category)")
        }
    }

    @Test("the provenance setter writes both halves, a nil id clears both, and a pre-V21 stamp keeps a nil revision")
    func theSetterWritesThePair() {
        let first = UUID(), second = UUID()
        let row = stay()
        row.category = .home
        row.setTemporaryHomeProvenance(first, revision: 2)
        #expect(row.temporaryHomeID == first)
        #expect(row.temporaryHomeRevision == 2)
        // A handoff takes the new owner's revision.
        row.setTemporaryHomeProvenance(second, revision: 7)
        #expect(row.temporaryHomeID == second)
        #expect(row.temporaryHomeRevision == 7)
        // A revision never stands alone.
        row.setTemporaryHomeProvenance(nil, revision: 9)
        #expect(row.temporaryHomeID == nil)
        #expect(row.temporaryHomeRevision == nil)
        row.setTemporaryHomeProvenance(first, revision: nil)
        #expect(row.temporaryHomeID == first)
        #expect(row.temporaryHomeRevision == nil)
    }

    @Test("the provenance pair persists, and clearing it through the category commits both halves")
    func thePairPersists() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let id = UUID()
        let row = stay()
        row.category = .home
        row.setTemporaryHomeProvenance(id, revision: 3)
        context.insert(row)
        try context.save()

        let reread = ModelContext(container)
        let saved = try #require(try reread.fetch(FetchDescriptor<Stay>()).first)
        #expect(saved.temporaryHomeID == id)
        #expect(saved.temporaryHomeRevision == 3)
        saved.category = .destination
        try reread.save()
        let cleared = try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
        #expect(cleared.temporaryHomeID == nil)
        #expect(cleared.temporaryHomeRevision == nil)
    }

    @Test("writing the provenance a stay already holds leaves the row clean")
    func unchangedProvenanceIsNotWritten() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let id = UUID()
        let row = stay()
        row.category = .home
        row.setTemporaryHomeProvenance(id, revision: 3)
        context.insert(row)
        try context.save()
        #expect(!context.hasChanges)

        row.setTemporaryHomeProvenance(id, revision: 3)
        #expect(!context.hasChanges)
    }

    // MARK: - Kept trips

    @Test("kept trip ids parse from the comma string, ignoring segments that are not a UUID, spaces around one, and empty segments")
    func keptTripIDsIgnoreJunk() {
        let a = UUID(), b = UUID()
        #expect(temporaryHome().keptTripIDSet.isEmpty)
        let row = temporaryHome(kept: "\(a.uuidString),not-a-uuid,, \(b.uuidString.lowercased()) ,42")
        #expect(row.keptTripIDSet == [a, b])
    }

    @Test("adding a kept trip keeps one sorted, deduplicated string without junk, and adding one already held in that form writes nothing")
    func addingKeptTripsIsCanonical() throws {
        let ids = (0..<3).map { _ in UUID() }
        let row = temporaryHome(kept: "junk,\(ids[2].uuidString)")
        row.addKeptTrip(ids[0])
        row.addKeptTrip(ids[1])
        row.addKeptTrip(ids[0])
        let expected = ids.map(\.uuidString).sorted().joined(separator: ",")
        #expect(row.keptTripIDs == expected)
        #expect(row.keptTripIDSet == Set(ids))

        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(row)
        try context.save()
        row.addKeptTrip(ids[1])
        #expect(!context.hasChanges, "an id already held changes nothing")
        let reread = try #require(try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>()).first)
        #expect(reread.keptTripIDs == expected)
    }

    @Test("the kept trips of a declaration are the union over its rows, so a keep on either copy counts")
    func keptTripsUnionOverRows() {
        let id = UUID()
        let a = UUID(), b = UUID(), c = UUID()
        let phone = temporaryHome(id: id, kept: a.uuidString)
        let tablet = temporaryHome(id: id, kept: "\(b.uuidString),\(a.uuidString)")
        let empty = temporaryHome(id: id)
        #expect(TemporaryHome.keptTripIDs(of: [phone, tablet, empty]) == [a, b])
        #expect(TemporaryHome.keptTripIDs(of: []).isEmpty)
        tablet.addKeptTrip(c)
        #expect(TemporaryHome.keptTripIDs(of: [phone, tablet]) == [a, b, c])
    }

    // MARK: - Coverage revision

    @Test("the next coverage revision is one above the highest among the rows, and one for none or for rows written before V21")
    func nextCoverageRevision() {
        let id = UUID()
        #expect(TemporaryHome.nextCoverageRevision(of: []) == 1)
        #expect(TemporaryHome.nextCoverageRevision(of: [temporaryHome(id: id)]) == 1)
        #expect(TemporaryHome.nextCoverageRevision(of: [
            temporaryHome(id: id, revision: 4), temporaryHome(id: id, revision: 6),
            temporaryHome(id: id, revision: 5),
        ]) == 7)
    }

    @Test("a new declaration starts at revision zero with no kept trips, and both fields persist")
    func newDeclarationDefaultsAndPersists() throws {
        let row = TemporaryHome(label: "Erasmus", latitude: 50.85, longitude: 4.35,
                                startedAt: Self.start)
        #expect(row.coverageRevision == 0)
        #expect(row.keptTripIDs.isEmpty)
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        context.insert(row)
        let kept = UUID()
        row.coverageRevision = TemporaryHome.nextCoverageRevision(of: [row])
        row.addKeptTrip(kept)
        try context.save()
        let reread = try #require(try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>()).first)
        #expect(reread.coverageRevision == 1)
        #expect(reread.keptTripIDSet == [kept])
    }
}
