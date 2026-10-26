//
//  TemporaryHomeSaveWorkerTests.swift
//  TravelLogTests
//
//  The temporary-home write path behind the Settings sheet: add, edit, end and
//  remove on an injected context, the reconciliation each one queues before
//  its save, and the rule that turns a picked day into the stored instants.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct TemporaryHomeSaveWorkerTests {

    private let now = Date(timeIntervalSince1970: 1_790_928_000)
    /// When `makeRow`'s rows were last written: before `now`, so an edit
    /// under test advances them to `now`.
    private var stored: Date { now.addingTimeInterval(-86_400) }
    private let brussels = (lat: 50.8908, lon: 4.4396)
    private let dilbeek = (lat: 50.84799, lon: 4.25972)
    private let brusselsZone = "Europe/Brussels"

    private func utc(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "TemporaryHomeSaveWorkerTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    private func payload(
        target: TemporaryHomeSavePayload.Target,
        coord: (lat: Double, lon: Double),
        label: String = "Erasmus",
        locality: String? = "Brussels",
        adminArea: String? = "Brussels-Capital",
        country: String? = "Belgium",
        iso: String? = "BE",
        startedAt: Date,
        endedAt: Date? = nil,
        zone: String? = "Europe/Brussels"
    ) -> TemporaryHomeSavePayload {
        TemporaryHomeSavePayload(
            target: target,
            label: label,
            latitude: coord.lat,
            longitude: coord.lon,
            locality: locality,
            administrativeArea: adminArea,
            country: country,
            isoCountryCode: iso,
            startedAt: startedAt,
            endedAt: endedAt,
            timeZoneIdentifier: zone,
            now: now
        )
    }

    @discardableResult
    private func makeRow(
        in ctx: ModelContext,
        id: UUID? = nil,
        label: String = "Erasmus",
        coord: (lat: Double, lon: Double),
        startedAt: Date,
        endedAt: Date? = nil,
        zone: String? = "Europe/Brussels"
    ) -> TemporaryHome {
        let row = TemporaryHome(
            label: label, latitude: coord.lat, longitude: coord.lon,
            startedAt: startedAt, endedAt: endedAt)
        if let id { row.id = id }
        row.locality = "Brussels"
        row.administrativeArea = "Brussels-Capital"
        row.country = "Belgium"
        row.isoCountryCode = "BE"
        row.timeZoneIdentifier = zone
        row.createdAt = stored
        row.modifiedAt = stored
        ctx.insert(row)
        return row
    }

    private func rows(_ ctx: ModelContext) throws -> [TemporaryHome] {
        try ctx.fetch(FetchDescriptor<TemporaryHome>())
    }

    // MARK: - Add

    @Test("add inserts one temporary home with the payload's values and queues its reconciliation before the save")
    func addInsertsOneRowAndQueuesBeforeTheSave() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let end = try utc("2027-10-28T21:59:59Z")

        var queuedAtSave: [CoverageReconciliationQueue.Entry] = []
        let result = TemporaryHomeSaveWorker.apply(
            payload(target: .add, coord: brussels, startedAt: start, endedAt: end),
            context: ctx,
            save: { context in
                queuedAtSave = CoverageReconciliationQueue.pending(defaults: defaults)
                try context.save()
            },
            pendingDefaults: defaults)

        #expect(!result.failed)
        let saved = try rows(ModelContext(container))
        #expect(saved.count == 1)
        let row = try #require(saved.first)
        #expect(row.label == "Erasmus")
        #expect(row.latitude == brussels.lat)
        #expect(row.longitude == brussels.lon)
        #expect(row.locality == "Brussels")
        #expect(row.administrativeArea == "Brussels-Capital")
        #expect(row.country == "Belgium")
        #expect(row.isoCountryCode == "BE")
        #expect(row.startedAt == start)
        #expect(row.endedAt == end)
        #expect(row.timeZoneIdentifier == brusselsZone)
        #expect(row.createdAt == now)
        #expect(row.modifiedAt == now)

        let entry = try #require(result.pendingReconciliation)
        #expect(entry.kind == .temporaryHome)
        #expect(entry.id == row.id)
        #expect(queuedAtSave == [entry])
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [entry])
    }

    @Test("an add whose save fails leaves no temporary home and no queued reconciliation")
    func failedAddLeavesNoRowAndNoDebt() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let result = TemporaryHomeSaveWorker.apply(
            payload(target: .add, coord: brussels, startedAt: try utc("2027-05-30T22:00:00Z")),
            context: ctx,
            save: { _ in throw CocoaError(.fileWriteUnknown) },
            pendingDefaults: defaults)

        #expect(result.failed)
        #expect(result.pendingReconciliation == nil)
        #expect(!ctx.hasChanges)
        #expect(try rows(ModelContext(container)).isEmpty)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
    }

    @Test("a failed later edit keeps the reconciliation an earlier committed edit still owes")
    func failedEditKeepsEarlierDebt() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let row = makeRow(in: ctx, coord: brussels, startedAt: start)
        try ctx.save()

        let earlier = try #require(TemporaryHomeSaveWorker.apply(
            payload(target: .edit(row.id), coord: dilbeek, startedAt: start),
            context: ctx, pendingDefaults: defaults).pendingReconciliation)
        let failed = TemporaryHomeSaveWorker.apply(
            payload(target: .edit(row.id), coord: brussels, label: "Second", startedAt: start),
            context: ctx,
            save: { _ in throw CocoaError(.fileWriteUnknown) },
            pendingDefaults: defaults)

        #expect(failed.failed)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [earlier])
        let saved = try #require(try rows(ModelContext(container)).first)
        #expect(saved.label == "Erasmus")
        #expect(saved.latitude == dilbeek.lat)
    }

    // MARK: - Edit

    @Test("an edit writes the same values to every row that shares the id")
    func editWritesEverySameIDTwin() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let oldStart = try utc("2027-05-30T22:00:00Z")
        let original = makeRow(in: ctx, coord: brussels, startedAt: oldStart)
        let id = original.id
        makeRow(in: ctx, id: id, label: "Twin", coord: brussels, startedAt: oldStart)
        let other = makeRow(in: ctx, label: "Other", coord: dilbeek, startedAt: oldStart)
        let otherID = other.id
        try ctx.save()

        let newStart = try utc("2027-06-06T22:00:00Z")
        let newEnd = try utc("2027-10-18T21:59:59Z")
        let result = TemporaryHomeSaveWorker.apply(
            payload(
                target: .edit(id), coord: dilbeek, label: "Semester",
                locality: "Dilbeek", adminArea: "Flemish Brabant", country: "Belgium", iso: "BE",
                startedAt: newStart, endedAt: newEnd, zone: nil),
            context: ctx, pendingDefaults: defaults)

        #expect(!result.failed)
        let entry = try #require(result.pendingReconciliation)
        #expect(entry.kind == .temporaryHome && entry.id == id)
        let saved = try rows(ModelContext(container))
        #expect(saved.count == 3)
        let twins = saved.filter { $0.id == id }
        #expect(twins.count == 2)
        for twin in twins {
            #expect(twin.label == "Semester")
            #expect(twin.latitude == dilbeek.lat)
            #expect(twin.longitude == dilbeek.lon)
            #expect(twin.startedAt == newStart)
            #expect(twin.endedAt == newEnd)
            #expect(twin.modifiedAt == now)
            #expect(twin.createdAt == stored)
            #expect(twin.locality == "Dilbeek")
            #expect(twin.administrativeArea == "Flemish Brabant")
            #expect(twin.country == "Belgium")
            #expect(twin.isoCountryCode == "BE")
            // The payload carried no zone: the stored one stands.
            #expect(twin.timeZoneIdentifier == brusselsZone)
        }
        let untouched = try #require(saved.first { $0.id == otherID })
        #expect(untouched.label == "Other")
        #expect(untouched.startedAt == oldStart)
        #expect(untouched.modifiedAt == stored)
    }

    @Test("an edit that changes only the name saves it on every row and queues no reconciliation")
    func nameOnlyEditQueuesNothing() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let end = try utc("2027-10-28T21:59:59Z")
        let original = makeRow(in: ctx, coord: brussels, startedAt: start, endedAt: end)
        let id = original.id
        makeRow(in: ctx, id: id, label: "Twin", coord: brussels, startedAt: start, endedAt: end)
        try ctx.save()

        let result = TemporaryHomeSaveWorker.apply(
            payload(target: .edit(id), coord: brussels, label: "Semester",
                    startedAt: start, endedAt: end),
            context: ctx, pendingDefaults: defaults)

        #expect(!result.failed)
        #expect(result.pendingReconciliation == nil)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
        let saved = try rows(ModelContext(container))
        #expect(saved.map(\.label) == ["Semester", "Semester"])
        for row in saved {
            #expect(row.modifiedAt == now)
            #expect(row.latitude == brussels.lat)
            #expect(row.startedAt == start)
            #expect(row.endedAt == end)
        }
    }

    @Test("an edit that changes only the stored locality queues a reconciliation, since trip names read it; a lookup that answers nothing at the same pin keeps the stored locality and queues nothing")
    func aLocalityChangeAloneQueuesTheReconciliation() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let end = try utc("2027-10-28T21:59:59Z")
        let id = makeRow(in: ctx, coord: brussels, startedAt: start, endedAt: end).id
        try ctx.save()

        let unanswered = TemporaryHomeSaveWorker.apply(
            payload(target: .edit(id), coord: brussels, locality: nil, startedAt: start, endedAt: end),
            context: ctx, pendingDefaults: defaults)
        #expect(!unanswered.failed)
        #expect(unanswered.pendingReconciliation == nil)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)

        let renamed = TemporaryHomeSaveWorker.apply(
            payload(target: .edit(id), coord: brussels, locality: "Bruxelles",
                    startedAt: start, endedAt: end),
            context: ctx, pendingDefaults: defaults)
        #expect(!renamed.failed)
        let entry = try #require(renamed.pendingReconciliation)
        #expect(entry.kind == .temporaryHome && entry.id == id)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [entry])
        #expect(try rows(ModelContext(container)).map(\.locality) == ["Bruxelles"])
    }

    @Test("an edit that moves the place, the start or the end, or removes the end, queues a reconciliation",
          arguments: ["place", "start", "end", "end removed"])
    func coverageEditQueuesAReconciliation(change: String) throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let end = try utc("2027-10-28T21:59:59Z")
        let id = makeRow(in: ctx, coord: brussels, startedAt: start, endedAt: end).id
        try ctx.save()

        // The name stays "Erasmus": only the one field differs.
        let edit: TemporaryHomeSavePayload
        switch change {
        case "place":
            edit = payload(target: .edit(id), coord: dilbeek, startedAt: start, endedAt: end)
        case "start":
            edit = payload(target: .edit(id), coord: brussels,
                           startedAt: start.addingTimeInterval(86_400), endedAt: end)
        case "end":
            edit = payload(target: .edit(id), coord: brussels,
                           startedAt: start, endedAt: end.addingTimeInterval(86_400))
        default:
            edit = payload(target: .edit(id), coord: brussels, startedAt: start, endedAt: nil)
        }
        let result = TemporaryHomeSaveWorker.apply(edit, context: ctx, pendingDefaults: defaults)

        #expect(!result.failed)
        let entry = try #require(result.pendingReconciliation)
        #expect(entry.kind == .temporaryHome && entry.id == id)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [entry])
    }

    @Test("a name-only edit leaves the reconciliation an earlier edit still owes in place, whether its save succeeds or fails")
    func nameOnlyEditKeepsEarlierDebt() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let id = makeRow(in: ctx, coord: brussels, startedAt: start).id
        try ctx.save()

        let earlier = try #require(TemporaryHomeSaveWorker.apply(
            payload(target: .edit(id), coord: dilbeek, startedAt: start),
            context: ctx, pendingDefaults: defaults).pendingReconciliation)

        let renamed = TemporaryHomeSaveWorker.apply(
            payload(target: .edit(id), coord: dilbeek, label: "Renamed", startedAt: start),
            context: ctx, pendingDefaults: defaults)
        #expect(!renamed.failed)
        #expect(renamed.pendingReconciliation == nil)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [earlier])

        let failed = TemporaryHomeSaveWorker.apply(
            payload(target: .edit(id), coord: dilbeek, label: "Again", startedAt: start),
            context: ctx,
            save: { _ in throw CocoaError(.fileWriteUnknown) },
            pendingDefaults: defaults)
        #expect(failed.failed)
        #expect(failed.pendingReconciliation == nil)
        #expect(!ctx.hasChanges)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [earlier])
        #expect(try rows(ModelContext(container)).map(\.label) == ["Renamed"])
    }

    @Test("an edit of a temporary home that is gone changes nothing and queues nothing")
    func editOfAbsentIDIsNoChange() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let other = makeRow(in: ctx, label: "Other", coord: dilbeek, startedAt: start)
        try ctx.save()

        let result = TemporaryHomeSaveWorker.apply(
            payload(target: .edit(UUID()), coord: brussels, startedAt: start),
            context: ctx, pendingDefaults: defaults)

        #expect(result == .noChange)
        #expect(!ctx.hasChanges)
        #expect(try rows(ctx).count == 1)
        #expect(other.label == "Other")
        #expect(other.latitude == dilbeek.lat)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
    }

    @Test("a failed place lookup keeps the stored place names only while the pin moved less than 1 km; a pin moved farther stores what the lookup returned, also when that is nothing, so the old city's name does not follow the pin",
          arguments: [true, false])
    func placeNamesFollowThePinOnlyWithinOneKilometre(nearby: Bool) throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let id = makeRow(in: ctx, coord: brussels, startedAt: start).id
        makeRow(in: ctx, id: id, label: "Twin", coord: brussels, startedAt: start)
        try ctx.save()

        // About 600 m north of the stored pin, or the alternate city pin farther away.
        let moved = nearby ? (lat: brussels.lat + 0.0054, lon: brussels.lon) : dilbeek
        let result = TemporaryHomeSaveWorker.apply(
            payload(
                target: .edit(id), coord: moved,
                locality: nil, adminArea: nil, country: nil, iso: nil,
                startedAt: start, zone: nil),
            context: ctx, pendingDefaults: defaults)

        #expect(!result.failed)
        #expect(result.pendingReconciliation?.id == id)
        let saved = try rows(ModelContext(container))
        #expect(saved.count == 2)
        for row in saved {
            #expect(row.latitude == moved.lat)
            #expect(row.locality == (nearby ? "Brussels" : nil))
            #expect(row.administrativeArea == (nearby ? "Brussels-Capital" : nil))
            #expect(row.country == (nearby ? "Belgium" : nil))
            #expect(row.isoCountryCode == (nearby ? "BE" : nil))
            #expect(row.timeZoneIdentifier == brusselsZone)
        }
    }

    @Test("a place lookup that answers replaces the stored names field by field when the pin moved less than 1 km, and wholly when it moved farther",
          arguments: [true, false])
    func answeredLookupReplacesTheNamesItReturned(nearby: Bool) throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let id = makeRow(in: ctx, coord: brussels, startedAt: start).id
        try ctx.save()

        let moved = nearby ? (lat: brussels.lat + 0.0054, lon: brussels.lon) : dilbeek
        // The lookup returned a locality and a country, no region and no code.
        TemporaryHomeSaveWorker.apply(
            payload(
                target: .edit(id), coord: moved,
                locality: "Dilbeek", adminArea: nil, country: "Belgium", iso: nil,
                startedAt: start),
            context: ctx, pendingDefaults: defaults)

        let row = try #require(try rows(ModelContext(container)).first)
        #expect(row.locality == "Dilbeek")
        #expect(row.country == "Belgium")
        #expect(row.administrativeArea == (nearby ? "Brussels-Capital" : nil))
        #expect(row.isoCountryCode == (nearby ? "BE" : nil))
    }

    // MARK: - Reconciliation debt

    @Test("a save that changes the place or the dates, an end and a removal each queue the reconciliation before the save",
          arguments: ["place", "dates", "end", "remove"])
    func coverageChangeQueuesItsReconciliationBeforeTheSave(change: String) throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let end = try utc("2027-10-28T21:59:59Z")
        let id = makeRow(in: ctx, coord: brussels, startedAt: start, endedAt: end).id
        try ctx.save()

        let edit: TemporaryHomeSavePayload
        switch change {
        case "place":
            edit = payload(target: .edit(id), coord: dilbeek, startedAt: start, endedAt: end)
        case "dates":
            edit = payload(target: .edit(id), coord: brussels,
                           startedAt: start.addingTimeInterval(86_400), endedAt: nil)
        case "end":
            edit = .ending(id, on: try utc("2027-09-06T12:00:00Z"), now: now)
        default:
            edit = .removing(id, now: now)
        }
        var queuedAtSave: [CoverageReconciliationQueue.Entry] = []
        let result = TemporaryHomeSaveWorker.apply(
            edit, context: ctx,
            save: { context in
                queuedAtSave = CoverageReconciliationQueue.pending(defaults: defaults)
                try context.save()
            },
            pendingDefaults: defaults)

        #expect(!result.failed)
        let entry = try #require(result.pendingReconciliation)
        #expect(entry.kind == .temporaryHome && entry.id == id)
        #expect(queuedAtSave == [entry])
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [entry])
    }

    @Test("a save that fails withdraws only the reconciliation it queued; with an earlier committed edit still owed, that edit's entry stays",
          arguments: ["edit", "end", "remove"])
    func failedSaveWithdrawsOnlyItsOwnDebt(change: String) throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let id = makeRow(in: ctx, coord: brussels, startedAt: start).id
        try ctx.save()

        let endDay = try utc("2027-09-06T12:00:00Z")
        func failing(_ place: (lat: Double, lon: Double)) -> TemporaryHomeSavePayload {
            switch change {
            case "edit": return payload(target: .edit(id), coord: place, startedAt: start)
            case "end": return .ending(id, on: endDay, now: now)
            default: return .removing(id, now: now)
            }
        }
        func failedSave(_ edit: TemporaryHomeSavePayload) -> [UUID] {
            var queuedAtSave: [UUID] = []
            let failed = TemporaryHomeSaveWorker.apply(
                edit, context: ctx,
                save: { _ in
                    queuedAtSave = CoverageReconciliationQueue.pending(defaults: defaults).map(\.id)
                    throw CocoaError(.fileWriteUnknown)
                },
                pendingDefaults: defaults)
            #expect(failed.failed)
            #expect(failed.pendingReconciliation == nil)
            return queuedAtSave
        }

        // Nothing owed yet: the failed call had queued its entry and takes it back.
        #expect(failedSave(failing(dilbeek)) == [id])
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)

        // An earlier edit committed: the pin moved to Dilbeek.
        let earlier = try #require(TemporaryHomeSaveWorker.apply(
            payload(target: .edit(id), coord: dilbeek, startedAt: start),
            context: ctx, pendingDefaults: defaults).pendingReconciliation)

        // The failed call supersedes it while it saves, then puts it back.
        #expect(failedSave(failing(brussels)) == [id])
        #expect(CoverageReconciliationQueue.pending(defaults: defaults) == [earlier])
        let saved = try #require(try rows(ModelContext(container)).first)
        #expect(saved.latitude == dilbeek.lat)
        #expect(saved.endedAt == nil)
        #expect(saved.removedAt == nil)
    }

    @Test("a save that changes neither the place nor the dates queues a reconciliation when the form's preview found work for it")
    func unchangedCoverageWithWorkQueuesAReconciliation() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let id = makeRow(in: ctx, coord: brussels, startedAt: start).id
        try ctx.save()

        var edit = payload(target: .edit(id), coord: brussels, startedAt: start)
        edit.reconcilesUnchangedCoverage = true
        var queuedAtSave: [UUID] = []
        let saved = TemporaryHomeSaveWorker.apply(
            edit, context: ctx,
            save: {
                queuedAtSave = CoverageReconciliationQueue.pending(defaults: defaults).map(\.id)
                try $0.save()
            },
            pendingDefaults: defaults)

        #expect(!saved.failed)
        #expect(queuedAtSave == [id])
        #expect(saved.pendingReconciliation?.id == id)
        #expect(saved.pendingReconciliation?.kind == .temporaryHome)
    }

    @Test("the form asks for a reconciliation exactly when its preview has stays to stamp or free, trips to rebuild, merge or split, or a kept trip the user never edited")
    func owesReconciliationFollowsThePreview() throws {
        typealias Preview = TripClassifier.TemporaryHomeChangePreview
        let line = Preview.TripLine(
            id: UUID(), name: "Oudenaarde", start: try utc("2027-06-18T08:00:00Z"), end: nil, reasons: [])
        func preview(
            joining: Int = 0, leaving: Int = 0, rebuilt: [Preview.TripLine] = [],
            kept: [Preview.TripLine] = [], merged: [Preview.TripLine] = [],
            split: [Preview.TripLine] = []
        ) -> Preview {
            var preview = Preview(
                staysJoining: joining, staysLeaving: leaving, tripsRebuilt: rebuilt, tripsKept: kept,
                firstStayInArea: nil, lastStayInArea: nil, areaIsCityBoundary: true,
                tripsMerged: merged)
            preview.tripsSplit = split
            return preview
        }
        let edited = Preview.TripLine(
            id: UUID(), name: "Beringen", start: try utc("2027-06-22T08:00:00Z"), end: nil,
            reasons: [.userEdited, .pinned])
        #expect(!TemporaryHomeFormSheet.owesReconciliation(nil))
        #expect(!TemporaryHomeFormSheet.owesReconciliation(preview()))
        // A trip the user edited is kept already: it moves nothing.
        #expect(!TemporaryHomeFormSheet.owesReconciliation(preview(kept: [edited])))
        // One they only favorited is marked edited by the save, and the unit settles it.
        #expect(TemporaryHomeFormSheet.owesReconciliation(preview(kept: [line])))
        #expect(TemporaryHomeFormSheet.owesReconciliation(preview(joining: 1)))
        #expect(TemporaryHomeFormSheet.owesReconciliation(preview(leaving: 1)))
        #expect(TemporaryHomeFormSheet.owesReconciliation(preview(rebuilt: [line])))
        #expect(TemporaryHomeFormSheet.owesReconciliation(preview(merged: [line])))
        // A split trip is always the unit's work, whoever edited it: the
        // replay of an unchanged declaration that only detaches one included.
        #expect(TemporaryHomeFormSheet.owesReconciliation(preview(split: [edited])))
        #expect(TemporaryHomeFormSheet.owesReconciliation(preview(split: [line])))
    }

    // MARK: - End

    @Test("ending sets the end of that day, in the stored zone, on every row that shares the id, with the winner's name, place and start on each")
    func endSetsEndedAtOnEveryTwin() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let original = makeRow(in: ctx, coord: brussels, startedAt: start)
        let id = original.id
        // Ranked equal on dates, the twin loses on its stored content ("Erasmus" < "Twin").
        makeRow(in: ctx, id: id, label: "Twin", coord: brussels, startedAt: start)
        try ctx.save()

        // The chosen Brussels day ends at 21:59:59 UTC during summer time.
        let result = TemporaryHomeSaveWorker.apply(
            .ending(id, on: try utc("2027-10-28T07:30:00Z"), now: now),
            context: ctx, pendingDefaults: defaults)

        #expect(!result.failed)
        let entry = try #require(result.pendingReconciliation)
        #expect(entry.kind == .temporaryHome && entry.id == id)
        let saved = try rows(ModelContext(container))
        #expect(saved.count == 2)
        let expectedEnd = try utc("2027-10-28T21:59:59Z")
        for row in saved {
            #expect(row.endedAt == expectedEnd)
            #expect(row.startedAt == start)
            #expect(row.modifiedAt == now)
            #expect(row.latitude == brussels.lat)
            #expect(row.label == "Erasmus")
        }
    }

    @Test("an end is checked against the declaration the user sees: a losing twin that starts after the chosen day does not fail it, and every twin takes the winner's name, place, start and zone with the new end")
    func endValidatesAgainstTheWinnerAndWritesItToEveryTwin() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let winner = makeRow(in: ctx, coord: brussels, startedAt: start)
        winner.modifiedAt = stored.addingTimeInterval(60)
        let id = winner.id
        // Another device's older copy starts later, in another zone.
        let twin = makeRow(
            in: ctx, id: id, label: "Twin", coord: dilbeek,
            startedAt: try utc("2027-08-17T23:00:00Z"), zone: "Europe/London")
        twin.locality = "Dilbeek"
        twin.radiusKm = 10
        try ctx.save()

        // The chosen Brussels day is before the twin's start.
        let expectedEnd = try utc("2027-08-07T21:59:59Z")
        let result = TemporaryHomeSaveWorker.apply(
            .ending(id, on: try utc("2027-08-07T11:00:00Z"), now: now),
            context: ctx, pendingDefaults: defaults)

        #expect(!result.failed)
        #expect(result.pendingReconciliation?.id == id)
        let saved = try rows(ModelContext(container))
        #expect(saved.count == 2)
        for row in saved {
            #expect(row.label == "Erasmus")
            #expect(row.latitude == brussels.lat && row.longitude == brussels.lon)
            #expect(row.radiusKm == 25)
            #expect(row.locality == "Brussels")
            #expect(row.startedAt == start)
            #expect(row.timeZoneIdentifier == brusselsZone)
            #expect(row.endedAt == expectedEnd)
            #expect(row.modifiedAt == now)
        }
    }

    @Test("an edit or an end of rows last written by a clock that ran ahead stamps them just past that time, so a stale twin that syncs in later still loses",
          arguments: ["edit", "end"])
    func editAndEndOutrankATwinFromTheFuture(change: String) throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let future = now.addingTimeInterval(365 * 86_400)
        let endDay = try utc("2027-09-06T12:00:00Z")
        let expectedEnd = try utc("2027-09-06T21:59:59Z")
        let row = makeRow(in: ctx, coord: brussels, startedAt: start)
        row.modifiedAt = future
        let id = row.id
        try ctx.save()

        let edit: TemporaryHomeSavePayload = change == "edit"
            ? payload(target: .edit(id), coord: dilbeek, label: "Semester", startedAt: start)
            : .ending(id, on: endDay, now: now)
        let result = TemporaryHomeSaveWorker.apply(edit, context: ctx, pendingDefaults: defaults)
        #expect(!result.failed)
        let edited = try #require(try rows(ModelContext(container)).first)
        #expect(edited.modifiedAt == future.addingTimeInterval(0.001))

        // The other device's untouched copy arrives with the old values.
        let arrival = ModelContext(container)
        makeRow(in: arrival, id: id, coord: brussels, startedAt: start).modifiedAt = future
        try arrival.save()

        let winner = try #require(HomeAnchors.collapsingTwins(try rows(ModelContext(container))).first)
        if change == "edit" {
            #expect(winner.label == "Semester")
            #expect(winner.latitude == dilbeek.lat)
        } else {
            #expect(winner.endedAt == expectedEnd)
        }
    }

    // MARK: - Remove

    @Test("removing stamps every row that shares the id, keeps them and nothing else changes; the corrections keyed to it are left for the reconciliation it queues")
    func removeTombstonesEveryTwinAndLeavesItsCorrectionsToTheReconciliation() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let original = makeRow(in: ctx, coord: brussels, startedAt: start)
        let id = original.id
        makeRow(in: ctx, id: id, label: "Twin", coord: brussels, startedAt: start)
        let other = makeRow(in: ctx, label: "Other", coord: dilbeek, startedAt: start)
        let otherID = other.id
        let home = Home(label: "Home", latitude: 37.9838, longitude: 23.7275, radiusKm: 3)
        let homeID = home.id
        ctx.insert(home)
        func correction(_ owner: UUID?) -> UUID {
            let row = HomeAreaOverride(
                kind: .include, centerLatitude: brussels.lat, centerLongitude: brussels.lon,
                radiusKm: 1, homeID: owner)
            ctx.insert(row)
            return row.id
        }
        // The reconciliation frees the stays these two stamped and deletes them
        // in one unit (`removalWithdrawsTheCorrectionsTaughtToIt`); the worker
        // deleting them first would leave it nothing to find.
        let kept: Set<UUID> = [
            correction(id), correction(id),
            correction(otherID), correction(homeID), correction(nil),
        ]
        try ctx.save()

        let result = TemporaryHomeSaveWorker.apply(
            .removing(id, now: now), context: ctx, pendingDefaults: defaults)

        #expect(!result.failed)
        let entry = try #require(result.pendingReconciliation)
        #expect(entry.kind == .temporaryHome && entry.id == id)
        let fresh = ModelContext(container)
        let saved = try rows(fresh)
        #expect(saved.count == 3)
        let twins = saved.filter { $0.id == id }
        #expect(twins.count == 2)
        for twin in twins {
            #expect(twin.removedAt == now)
            #expect(twin.modifiedAt == now)
            #expect(twin.startedAt == start)
            #expect(twin.latitude == brussels.lat)
        }
        #expect(Set(twins.map(\.label)) == ["Erasmus", "Twin"])
        let untouched = try #require(saved.first { $0.id == otherID })
        #expect(untouched.removedAt == nil)
        #expect(untouched.modifiedAt == stored)
        #expect(try HomeAnchors.temporaryHomes(in: fresh).map(\.id) == [otherID])
        #expect(try fresh.fetch(FetchDescriptor<Home>()).map(\.id) == [homeID])
        let corrections = try fresh.fetch(FetchDescriptor<HomeAreaOverride>())
        #expect(Set(corrections.map(\.id)) == kept)
        #expect(corrections.count == 5)
    }

    @Test("a removal whose save fails keeps the temporary home live, its corrections and no queued reconciliation")
    func failedRemoveKeepsEverything() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let row = makeRow(in: ctx, coord: brussels, startedAt: try utc("2027-05-30T22:00:00Z"))
        let id = row.id
        ctx.insert(HomeAreaOverride(
            kind: .include, centerLatitude: brussels.lat, centerLongitude: brussels.lon,
            radiusKm: 1, homeID: id))
        try ctx.save()

        let result = TemporaryHomeSaveWorker.apply(
            .removing(id, now: now), context: ctx,
            save: { _ in throw CocoaError(.fileWriteUnknown) },
            pendingDefaults: defaults)

        #expect(result.failed)
        #expect(!ctx.hasChanges)
        let fresh = ModelContext(container)
        #expect(try rows(fresh).map(\.id) == [id])
        #expect(try rows(fresh).first?.removedAt == nil)
        #expect(try HomeAnchors.temporaryHomes(in: fresh).map(\.id) == [id])
        #expect(try fresh.fetchCount(FetchDescriptor<HomeAreaOverride>()) == 1)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
    }

    @Test("a removed temporary home is not removed, edited or ended again, even beside a live twin: each is no change, writes nothing and queues nothing",
          arguments: ["remove", "edit", "end"])
    func actionsOnARemovedIDAreNoChange(action: String) throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let tombstone = makeRow(in: ctx, coord: brussels, startedAt: start)
        tombstone.removedAt = stored
        let id = tombstone.id
        // A live twin from another device, written later.
        makeRow(in: ctx, id: id, label: "Twin", coord: brussels, startedAt: start)
            .modifiedAt = stored.addingTimeInterval(60)
        try ctx.save()

        let edit: TemporaryHomeSavePayload
        switch action {
        case "remove": edit = .removing(id, now: now)
        case "edit": edit = payload(target: .edit(id), coord: dilbeek, startedAt: start)
        default: edit = .ending(id, on: try utc("2027-09-06T12:00:00Z"), now: now)
        }
        var saves = 0
        let result = TemporaryHomeSaveWorker.apply(
            edit, context: ctx,
            save: { saves += 1; try $0.save() },
            pendingDefaults: defaults)

        #expect(!result.failed)
        #expect(result.pendingReconciliation == nil)
        #expect(saves == 0)
        #expect(!ctx.hasChanges)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
        let saved = try rows(ModelContext(container))
        #expect(saved.count == 2)
        #expect(Set(saved.map(\.removedAt)) == [stored, nil])
        #expect(Set(saved.map(\.modifiedAt)) == [stored, stored.addingTimeInterval(60)])
        #expect(saved.allSatisfy { $0.latitude == brussels.lat && $0.endedAt == nil })
    }

    // MARK: - Validation

    @Test("an end before the start is rejected on add, edit and end, with nothing written or queued")
    func untilBeforeSinceIsRejected() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let dayBefore = try utc("2027-05-29T21:59:59Z")
        let row = makeRow(in: ctx, coord: brussels, startedAt: start)
        let id = row.id
        try ctx.save()

        let added = TemporaryHomeSaveWorker.apply(
            payload(target: .add, coord: dilbeek, startedAt: start, endedAt: dayBefore),
            context: ctx, pendingDefaults: defaults)
        let edited = TemporaryHomeSaveWorker.apply(
            payload(target: .edit(id), coord: dilbeek, label: "Changed",
                    startedAt: start, endedAt: dayBefore),
            context: ctx, pendingDefaults: defaults)
        // The previous Brussels day ends before the start.
        let ended = TemporaryHomeSaveWorker.apply(
            .ending(id, on: try utc("2027-05-29T10:00:00Z"), now: now),
            context: ctx, pendingDefaults: defaults)

        #expect(added.failed && edited.failed && ended.failed)
        #expect(added.pendingReconciliation == nil)
        #expect(edited.pendingReconciliation == nil)
        #expect(ended.pendingReconciliation == nil)
        #expect(!ctx.hasChanges)
        let saved = try rows(ModelContext(container))
        #expect(saved.count == 1)
        let unchanged = try #require(saved.first)
        #expect(unchanged.id == id)
        #expect(unchanged.label == "Erasmus")
        #expect(unchanged.latitude == brussels.lat)
        #expect(unchanged.endedAt == nil)
        #expect(unchanged.modifiedAt == stored)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
    }

    @Test("an end on the start day itself is accepted")
    func endOnTheStartDayIsAccepted() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let row = makeRow(in: ctx, coord: brussels, startedAt: start)
        try ctx.save()

        let endOfStartDay = try utc("2027-05-31T21:59:59Z")

        let result = TemporaryHomeSaveWorker.apply(
            .ending(row.id, on: start, now: now), context: ctx, pendingDefaults: defaults)

        #expect(!result.failed)
        #expect(row.endedAt == endOfStartDay)
    }

    // MARK: - Date rule

    @Test("a picked day becomes the start and the last second of that civil day in the stored zone",
          arguments: [
            // West of UTC: 19:00 on 12 September in Los Angeles is already the 13th in UTC.
            ["America/Los_Angeles", "2027-09-13T02:00:00Z", "2027-09-12T07:00:00Z", "2027-09-13T06:59:59Z"],
            // East of UTC: 01:00 on 13 September in Brussels is still the 12th in UTC.
            ["Europe/Brussels", "2027-09-12T23:00:00Z", "2027-09-12T22:00:00Z", "2027-09-13T21:59:59Z"],
            // Clocks go forward in Brussels on 28 March 2027: a 23-hour day.
            ["Europe/Brussels", "2027-03-28T10:00:00Z", "2027-03-27T23:00:00Z", "2027-03-28T21:59:59Z"],
            // Clocks go back in Brussels on 31 October 2027: a 25-hour day.
            ["Europe/Brussels", "2027-10-31T10:00:00Z", "2027-10-30T22:00:00Z", "2027-10-31T22:59:59Z"],
            // Clocks go forward in Los Angeles on 14 March 2027.
            ["America/Los_Angeles", "2027-03-14T20:00:00Z", "2027-03-14T08:00:00Z", "2027-03-15T06:59:59Z"],
          ])
    func pickedDayMapsToItsCivilDay(_ row: [String]) throws {
        let zone = try #require(TimeZone(identifier: row[0]))
        let picked = try utc(row[1])
        let expectedStart = try utc(row[2])
        let expectedEnd = try utc(row[3])

        let bounds = TemporaryHomeSaveWorker.civilDayBounds(of: picked, in: zone)
        #expect(bounds.start == expectedStart)
        #expect(bounds.end == expectedEnd)
        // Any instant of the day gives the same day, its own ends included.
        let fromStart = TemporaryHomeSaveWorker.civilDayBounds(of: expectedStart, in: zone)
        #expect(fromStart.start == expectedStart)
        #expect(fromStart.end == expectedEnd)
        let fromEnd = TemporaryHomeSaveWorker.civilDayBounds(of: expectedEnd, in: zone)
        #expect(fromEnd.start == expectedStart)
        #expect(fromEnd.end == expectedEnd)
    }

    // MARK: - Pending edits

    @Test("an earlier pending edit in the context survives a failed temporary-home save")
    func earlierPendingEditsSurviveAFailedSave() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // Unsaved work from elsewhere on the same context.
        ctx.insert(RoutinePlace(
            label: "Office", latitude: dilbeek.lat, longitude: dilbeek.lon, radiusMeters: 300))

        var saves = 0
        let result = TemporaryHomeSaveWorker.apply(
            payload(target: .add, coord: brussels, startedAt: try utc("2027-05-30T22:00:00Z")),
            context: ctx,
            save: { context in
                saves += 1
                // The pre-save commits the earlier edit; the worker's own save fails.
                if saves == 2 { throw CocoaError(.fileWriteUnknown) }
                try context.save()
            },
            pendingDefaults: defaults)

        #expect(result.failed)
        #expect(saves == 2)
        #expect(!ctx.hasChanges)
        let fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<RoutinePlace>()).map(\.label) == ["Office"])
        #expect(try rows(fresh).isEmpty)
        #expect(defaults.object(forKey: CoverageReconciliationQueue.pendingKey) == nil)
    }

    // MARK: - Sheet copy

    @Test("the Settings date line reads Since, Starts or a range, with days read in the stored zone")
    func dateLineVariants() throws {
        let locale = Locale(identifier: "en_US")
        // The start of 31 May 2027 in Brussels is still 30 May in UTC and Los Angeles.
        let start = try utc("2027-05-30T22:00:00Z")
        let end = try utc("2027-10-28T21:59:59Z")
        func day(_ date: Date, _ zone: String) throws -> String {
            date.formatted(Date.FormatStyle(
                date: .abbreviated, time: .omitted, locale: locale,
                timeZone: try #require(TimeZone(identifier: zone))))
        }
        let startDay = try day(start, brusselsZone)
        let endDay = try day(end, brusselsZone)
        let startDayInLosAngeles = try day(start, "America/Los_Angeles")
        #expect(startDay.contains("31"))
        #expect(startDayInLosAngeles.contains("30"))

        let open = TemporaryHomesSettingsSection.dateLine(
            startedAt: start, endedAt: nil, timeZoneIdentifier: brusselsZone,
            now: start.addingTimeInterval(86_400), locale: locale)
        #expect(open == "Since \(startDay)")

        let upcoming = TemporaryHomesSettingsSection.dateLine(
            startedAt: start, endedAt: nil, timeZoneIdentifier: brusselsZone,
            now: start.addingTimeInterval(-86_400), locale: locale)
        #expect(upcoming == "Starts \(startDay)")

        let ranged = TemporaryHomesSettingsSection.dateLine(
            startedAt: start, endedAt: end, timeZoneIdentifier: brusselsZone,
            now: start.addingTimeInterval(-86_400), locale: locale)
        #expect(ranged == "\(startDay) to \(endDay)")
    }

    @Test("the What Changes lines appear only for non-zero counts and name at most three trips")
    func changeLinesFollowThePreview() throws {
        typealias Preview = TripClassifier.TemporaryHomeChangePreview
        let start = try utc("2027-05-30T22:00:00Z")
        func trips(_ names: [String]) -> [Preview.TripLine] {
            names.map { Preview.TripLine(id: UUID(), name: $0, start: start, end: nil, reasons: []) }
        }

        let nothing = Preview(
            staysJoining: 0, staysLeaving: 0, tripsRebuilt: [], tripsKept: [],
            firstStayInArea: nil, lastStayInArea: nil, areaIsCityBoundary: true)
        #expect(TemporaryHomeFormSheet.changeLines(for: nothing).isEmpty)

        let single = Preview(
            staysJoining: 1, staysLeaving: 0,
            tripsRebuilt: trips(["Oudenaarde"]), tripsKept: trips(["Beringen"]),
            firstStayInArea: nil, lastStayInArea: nil, areaIsCityBoundary: true)
        #expect(TemporaryHomeFormSheet.changeLines(for: single) == [
            "1 stay becomes time at this temporary home.",
            "1 trip will change to separate time here from trips away: Oudenaarde",
            "1 trip stays as it is: Beringen",
        ])

        let many = Preview(
            staysJoining: 1234, staysLeaving: 0,
            tripsRebuilt: trips(["Oudenaarde", "Bedburg", "Amsterdam", "Paris", "Lille"]),
            tripsKept: trips(["Beringen", "Knokke-Heist", "Namur", "Cologne"]),
            firstStayInArea: nil, lastStayInArea: nil, areaIsCityBoundary: false)
        #expect(TemporaryHomeFormSheet.changeLines(for: many) == [
            "1234 stays become time at this temporary home.",
            "5 trips will change to separate time here from trips away: Oudenaarde, Bedburg, Amsterdam and 2 more",
            "4 trips stay as they are: Beringen, Knokke-Heist, Namur and 1 more",
            "No city boundary here, so the area starts as 1 km around the pin. If everyday places nearby show up as trips, use This Wasn't a Trip on one of them.",
        ])
    }

    @Test("the What Changes lines name the trips a removal folds into a longer trip, after the stays that leave")
    func changeLinesReportTripsMerged() throws {
        typealias Preview = TripClassifier.TemporaryHomeChangePreview
        let start = try utc("2027-05-30T22:00:00Z")
        func trips(_ names: [String]) -> [Preview.TripLine] {
            names.map { Preview.TripLine(id: UUID(), name: $0, start: start, end: nil, reasons: []) }
        }
        let removal = Preview(
            staysJoining: 0, staysLeaving: 568, tripsRebuilt: [], tripsKept: trips(["Beringen"]),
            firstStayInArea: nil, lastStayInArea: nil, areaIsCityBoundary: true,
            tripsMerged: trips(["Oudenaarde", "Bedburg", "Amsterdam"]))
        #expect(TemporaryHomeFormSheet.changeLines(for: removal, areaNote: false) == [
            "568 stays stop counting as time here.",
            "3 trips will become part of a longer trip: Oudenaarde, Bedburg, Amsterdam",
            "1 trip stays as it is: Beringen",
        ])
        let one = Preview(
            staysJoining: 0, staysLeaving: 1, tripsRebuilt: [], tripsKept: [],
            firstStayInArea: nil, lastStayInArea: nil, areaIsCityBoundary: true,
            tripsMerged: trips(["Oudenaarde"]))
        #expect(TemporaryHomeFormSheet.changeLines(for: one, areaNote: false) == [
            "1 stay stops counting as time here.",
            "1 trip will become part of a longer trip: Oudenaarde",
        ])
    }

    @Test("a save marks a kept trip only when the user never edited it, and asks first; no line beyond the kept trips' own says so")
    func markingAKeptTripAddsNoLine() throws {
        typealias Preview = TripClassifier.TemporaryHomeChangePreview
        let start = try utc("2027-05-30T22:00:00Z")
        func kept(_ reasons: [TripClassifier.TripInteraction]...) -> Preview {
            Preview(
                staysJoining: 0, staysLeaving: 0, tripsRebuilt: [],
                tripsKept: reasons.enumerated().map {
                    Preview.TripLine(id: UUID(), name: "Trip \($0.offset)", start: start, end: nil,
                                     reasons: $0.element)
                },
                firstStayInArea: nil, lastStayInArea: nil, areaIsCityBoundary: true)
        }
        // Edited already, by the user or by an earlier save: nothing new is marked.
        let edited = kept([.userEdited], [.userEdited, .pinned])
        #expect(!TemporaryHomeFormSheet.marksKeptTrips(edited))
        #expect(TemporaryHomeFormSheet.changeLines(for: edited) == [
            "2 trips stay as they are: Trip 0, Trip 1",
        ])
        for reason in TripClassifier.TripInteraction.allCases where reason != .userEdited {
            let marking = kept([.userEdited], [reason])
            #expect(TemporaryHomeFormSheet.marksKeptTrips(marking), "\(reason)")
            #expect(TemporaryHomeFormSheet.asksBeforeSaving(marking), "\(reason)")
            #expect(TemporaryHomeFormSheet.changeLines(for: marking) == [
                "2 trips stay as they are: Trip 0, Trip 1",
            ], "\(reason)")
        }
    }

    // MARK: - Kept trips

    /// A trip row with `id`, as a sync or an import of one backup on two devices leaves twins.
    private func makeTrip(in ctx: ModelContext, id: UUID? = nil, edited: Bool = false) -> Trip {
        let trip = Trip(startDate: now.addingTimeInterval(-30 * 86_400))
        if let id { trip.id = id }
        trip.userEdited = edited
        ctx.insert(trip)
        return trip
    }

    private struct TripMarks: Equatable {
        let userEdited: Bool
        let keptByTemporaryHome: Bool
    }

    /// Every physical row's marks, in a stable order.
    private func marks(_ ctx: ModelContext) throws -> [UUID: [TripMarks]] {
        var result: [UUID: [TripMarks]] = [:]
        for trip in try ctx.fetch(FetchDescriptor<Trip>()) {
            result[trip.id, default: []].append(
                TripMarks(userEdited: trip.userEdited, keptByTemporaryHome: trip.keptByTemporaryHome))
        }
        return result.mapValues { rows in rows.sorted { !$0.userEdited && $1.userEdited } }
    }

    @Test("the save marks the trips the preview keeps in the same transaction as the temporary home, every row with each id, whatever the action; a trip the user edited keeps its own mark, a trip the preview did not list is left alone, and a failed save marks nothing",
          arguments: ["add", "edit", "end", "remove"])
    func workerMarkCommitsWithTheRow(action: String) throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let id = makeRow(in: ctx, coord: brussels, startedAt: start).id
        let favorite = makeTrip(in: ctx).id
        _ = makeTrip(in: ctx, id: favorite)
        let renamed = makeTrip(in: ctx, edited: true).id
        let other = makeTrip(in: ctx).id
        try ctx.save()
        let kept = [favorite, renamed]
        let edit: TemporaryHomeSavePayload
        switch action {
        case "add":
            var add = payload(target: .add, coord: dilbeek, startedAt: start)
            add.keptTripIDs = kept
            edit = add
        case "edit":
            var move = payload(target: .edit(id), coord: dilbeek, startedAt: start)
            move.keptTripIDs = kept
            edit = move
        case "end":
            edit = .ending(id, on: try utc("2027-10-28T07:30:00Z"), now: now, keptTripIDs: kept)
        default:
            edit = .removing(id, now: now, keptTripIDs: kept)
        }
        let unmarked = TripMarks(userEdited: false, keptByTemporaryHome: false)
        let usersOwn = TripMarks(userEdited: true, keptByTemporaryHome: false)
        let before = try marks(ModelContext(container))

        // The save fails: nothing is marked and nothing is queued.
        let failed = TemporaryHomeSaveWorker.apply(
            edit, context: ctx, save: { _ in throw CocoaError(.fileWriteUnknown) },
            pendingDefaults: defaults)
        #expect(failed.failed)
        #expect(!ctx.hasChanges)
        #expect(try marks(ModelContext(container)) == before)
        #expect(before[favorite] == [unmarked, unmarked])
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).isEmpty)

        // What the save committed is what the marks rode with: read inside it.
        var markedAtSave: [UUID: [TripMarks]] = [:]
        let saved = TemporaryHomeSaveWorker.apply(
            edit, context: ctx,
            save: {
                markedAtSave = try self.marks($0)
                try $0.save()
            },
            pendingDefaults: defaults)
        #expect(!saved.failed)
        #expect(saved.pendingReconciliation != nil)
        let ours = TripMarks(userEdited: true, keptByTemporaryHome: true)
        let after = try marks(ModelContext(container))
        #expect(after == markedAtSave)
        #expect(after[favorite] == [ours, ours])
        #expect(after[renamed] == [usersOwn])
        #expect(after[other] == [unmarked])
    }

    @Test("a save that changes no coverage and queues no reconciliation marks nothing, even with a kept list")
    func labelOnlySaveMarksNothing() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let id = makeRow(in: ctx, coord: brussels, startedAt: start).id
        let favorite = makeTrip(in: ctx).id
        try ctx.save()

        var rename = payload(target: .edit(id), coord: brussels, label: "Semester", startedAt: start)
        rename.keptTripIDs = [favorite]
        let saved = TemporaryHomeSaveWorker.apply(rename, context: ctx, pendingDefaults: defaults)
        #expect(!saved.failed)
        #expect(saved.pendingReconciliation == nil)
        #expect(try marks(ModelContext(container))[favorite]
                == [TripMarks(userEdited: false, keptByTemporaryHome: false)])
    }

    @Test("the form's save holds the trips its preview splits with the ones it keeps, in the declaration's own transaction, also when it ends the temporary home; a trip it rebuilds is left alone",
          arguments: ["add", "edit", "end"])
    func formHoldsSplitTripsInTheDeclarationsSave(action: String) throws {
        typealias Preview = TripClassifier.TemporaryHomeChangePreview
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let start = try utc("2027-05-30T22:00:00Z")
        let id = makeRow(in: ctx, coord: brussels, startedAt: start).id
        let kept = makeTrip(in: ctx).id
        let favorite = makeTrip(in: ctx).id
        _ = makeTrip(in: ctx, id: favorite)
        let renamed = makeTrip(in: ctx, edited: true).id
        let rebuilt = makeTrip(in: ctx).id
        try ctx.save()
        func line(_ id: UUID, _ reasons: [TripClassifier.TripInteraction]) -> Preview.TripLine {
            Preview.TripLine(id: id, name: "Trip", start: start, end: nil, reasons: reasons)
        }
        var preview = Preview(
            staysJoining: 3, staysLeaving: 0, tripsRebuilt: [line(rebuilt, [])],
            tripsKept: [line(kept, [.pinned])],
            firstStayInArea: nil, lastStayInArea: nil, areaIsCityBoundary: true)
        preview.tripsSplit = [line(favorite, [.pinned]), line(renamed, [.userEdited])]

        let save: TemporaryHomeSavePayload
        switch action {
        case "add":
            var add = payload(target: .add, coord: dilbeek, startedAt: start)
            add.keptTripIDs = TemporaryHomeFormSheet.heldTripIDs(preview)
            save = add
        case "edit":
            var move = payload(target: .edit(id), coord: dilbeek, startedAt: start)
            move.keptTripIDs = TemporaryHomeFormSheet.heldTripIDs(preview)
            save = move
        default:
            // The chosen Brussels morning in summer time.
            save = TemporaryHomeFormSheet.endingPayload(
                id, lastDay: try utc("2027-10-28T07:30:00Z"),
                in: try #require(TimeZone(identifier: brusselsZone)), preview: preview, now: now)
        }
        #expect(save.keptTripIDs == [kept, favorite, renamed])

        var markedAtSave: [UUID: [TripMarks]] = [:]
        let saved = TemporaryHomeSaveWorker.apply(
            save, context: ctx,
            save: {
                markedAtSave = try self.marks($0)
                try $0.save()
            },
            pendingDefaults: defaults)
        #expect(!saved.failed)
        #expect(saved.pendingReconciliation != nil)
        let ours = TripMarks(userEdited: true, keptByTemporaryHome: true)
        let after = try marks(ModelContext(container))
        #expect(after == markedAtSave)
        #expect(after[kept] == [ours])
        #expect(after[favorite] == [ours, ours])
        #expect(after[renamed] == [TripMarks(userEdited: true, keptByTemporaryHome: false)])
        #expect(after[rebuilt] == [TripMarks(userEdited: false, keptByTemporaryHome: false)])
        if action == "end" {
            let row = try #require(try rows(ModelContext(container)).first)
            #expect(row.endedAt == (try utc("2027-10-28T21:59:59Z")))
            #expect(row.startedAt == start)
        }
    }

    // MARK: - Arrival

    private static let athens = (lat: 38.0, lon: 23.8)
    private static let brusselsCentre = (lat: 50.85, lon: 4.35)
    /// About 52.2 km west of Brussels.
    private static let oudenaarde = (lat: 50.85168, lon: 3.60891)

    /// Athens is the real Home. A Brussels holiday `holidayDaysAgo` days
    /// before `now` (Brussels, Oudenaarde, Brussels), back home, then the
    /// semester: Brussels from 21 days ago, an open trip.
    private func seedHolidayThenSemester(
        _ container: ModelContainer, now: Date, holidayDaysAgo: Double
    ) throws -> (holidayTripID: UUID, holidayStayIDs: [UUID], arrival: Date, holidayStart: Date) {
        let ctx = ModelContext(container)
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        func stay(_ place: (lat: Double, lon: Double), from: Double, to: Double,
                  _ category: StayCategory) -> Stay {
            TemporaryHomeFixture.stay(
                ctx, place, from: ago(from), to: ago(to), category, hex: "S", pingCount: 6,
                zone: "Europe/Brussels")
        }
        func trip(_ stays: [Stay], complete: Bool) -> Trip {
            TemporaryHomeFixture.trip(ctx, stays, complete: complete)
        }
        ctx.insert(Home(label: "Athens", latitude: Self.athens.lat, longitude: Self.athens.lon,
                        radiusKm: 25, startedAt: ago(2000)))
        _ = stay(Self.athens, from: holidayDaysAgo + 20, to: holidayDaysAgo + 1, .home)
        let h1 = stay(Self.brusselsCentre, from: holidayDaysAgo, to: holidayDaysAgo - 1.5, .destination)
        let h2 = stay(Self.oudenaarde, from: holidayDaysAgo - 1.7, to: holidayDaysAgo - 2.3, .destination)
        let h3 = stay(Self.brusselsCentre, from: holidayDaysAgo - 2.5, to: holidayDaysAgo - 3.5, .destination)
        let holiday = trip([h1, h2, h3], complete: true)
        _ = stay(Self.athens, from: holidayDaysAgo - 4, to: 40, .home)
        _ = stay(Self.athens, from: 39.5, to: 22, .home)
        let s1 = stay(Self.brusselsCentre, from: 21, to: 12, .destination)
        let s2 = stay(Self.brusselsCentre, from: 11.5, to: 0.2, .destination)
        _ = trip([s1, s2], complete: false)
        try ctx.save()
        return (holiday.id, [h1.id, h3.id], s1.startTime, h1.startTime)
    }

    @Test("a new temporary home starts today and offers the semester's arrival, never an earlier holiday in the same city, recent or old; taking the offer leaves the holiday a trip",
          arguments: [60.0, 120.0])
    func arrivalIsOfferedNotAssigned(holidayDaysAgo: Double) async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try TestSupport.makeInMemoryContainer()
        let now = try utc("2025-06-22T12:00:00Z")
        let seeded = try seedHolidayThenSemester(container, now: now, holidayDaysAgo: holidayDaysAgo)
        let classifier = await TemporaryHomeFixture.classifier(
            container, squares: [(1, Self.athens), (2, Self.brusselsCentre)])
        let zone = try #require(TimeZone(identifier: brusselsZone))
        func draft(since: Date) -> HomeAnchor {
            HomeAnchor(
                id: UUID(), kind: .temporary, label: "Erasmus",
                latitude: Self.brusselsCentre.lat, longitude: Self.brusselsCentre.lon, radiusKm: 25,
                locality: nil, isoCountryCode: nil,
                startedAt: TemporaryHomeSaveWorker.civilDayBounds(of: since, in: zone).start,
                endedAt: nil)
        }

        // The form opens on today: the arrival is offered, the holiday only recorded.
        let opened = try #require(await classifier.previewTemporaryHomeChange(
            draft: draft(since: now), removing: false, pinnedTripIDs: []))
        #expect(TemporaryHomeFormSheet.offeredArrival(
            opened.arrivalInArea, since: now, until: nil, in: zone) == seeded.arrival)
        #expect(TemporaryHomeFormSheet.shownFirstRecorded(
            opened.firstStayInArea, arrival: opened.arrivalInArea, since: now, in: zone)
                == seeded.holidayStart)

        // Taken: Since is the arrival, which no longer offers itself.
        let since = seeded.arrival
        let taken = try #require(await classifier.previewTemporaryHomeChange(
            draft: draft(since: since), removing: false, pinnedTripIDs: []))
        #expect(TemporaryHomeFormSheet.offeredArrival(
            taken.arrivalInArea, since: since, until: nil, in: zone) == nil)
        #expect(!taken.tripsRebuilt.map(\.id).contains(seeded.holidayTripID))
        #expect(!TemporaryHomeFormSheet.heldTripIDs(taken).contains(seeded.holidayTripID))

        // Saved as the form saves it, then the unit Settings runs.
        var add = payload(
            target: .add, coord: Self.brusselsCentre,
            startedAt: TemporaryHomeSaveWorker.civilDayBounds(of: since, in: zone).start)
        add.keptTripIDs = TemporaryHomeFormSheet.heldTripIDs(taken)
        let saved = TemporaryHomeSaveWorker.apply(
            add, context: ModelContext(container), pendingDefaults: defaults)
        let rowID = try #require(saved.pendingReconciliation?.id)
        let outcome = await StayClassificationInference.TestHook.$availability.withValue(false) {
            await classifier.applyTemporaryHomeChangeCore(temporaryHomeID: rowID, pinnedTripIDs: [])
        }
        #expect(outcome.isSettled)
        let read = ModelContext(container)
        for id in seeded.holidayStayIDs {
            let stay = try #require(try read.fetch(FetchDescriptor<Stay>(
                predicate: #Predicate { $0.id == id })).first)
            #expect(stay.category == .destination)
            #expect(stay.trip?.id == seeded.holidayTripID)
        }
    }

    private func preview(
        staysJoining: Int = 0, staysLeaving: Int = 0, areaIsCityBoundary: Bool = true
    ) -> TripClassifier.TemporaryHomeChangePreview {
        TripClassifier.TemporaryHomeChangePreview(
            staysJoining: staysJoining, staysLeaving: staysLeaving,
            tripsRebuilt: [], tripsKept: [],
            firstStayInArea: nil, lastStayInArea: nil, areaIsCityBoundary: areaIsCityBoundary)
    }

    @Test("the What Changes lines say how many stays stop counting as time at the temporary home, in the singular and the plural, after the stays that join")
    func changeLinesReportStaysLeaving() {
        #expect(TemporaryHomeFormSheet.changeLines(for: preview(staysLeaving: 1)) == [
            "1 stay stops counting as time here.",
        ])
        #expect(TemporaryHomeFormSheet.changeLines(
            for: preview(staysJoining: 2, staysLeaving: 1234)) == [
            "2 stays become time at this temporary home.",
            "1234 stays stop counting as time here.",
        ])
        #expect(TemporaryHomeFormSheet.changeLines(for: preview(staysJoining: 2)) == [
            "2 stays become time at this temporary home.",
        ])
    }

    @Test("the Home form's area hint shows only once a preview reports a city boundary: it is hidden while there is no preview and when the preview reports the 1 km area")
    func areaSourceHintFollowsThePreview() {
        #expect(!TemporaryHomeFormSheet.showsAreaSourceHint(for: nil))
        #expect(TemporaryHomeFormSheet.showsAreaSourceHint(
            for: preview(areaIsCityBoundary: true)))
        #expect(!TemporaryHomeFormSheet.showsAreaSourceHint(
            for: preview(areaIsCityBoundary: false)))
    }
}
