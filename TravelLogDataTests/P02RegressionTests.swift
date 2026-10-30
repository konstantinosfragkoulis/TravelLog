//
//  P02RegressionTests.swift
//  TravelLogTests
//
//  Historical regrouping and the summaries derived from it: hidden photos
//  that follow a regroup's stays, home stays that split completed trips,
//  failed reads in Stage 1.5, the suppression memo without temporary homes,
//  the departure owner, blank and foreign place names in titles, and the
//  widget country counts. Fixture places are fictional round coordinates
//  and fixture time is whole days from the reference date.
//

import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("P02 historical regrouping and derived summaries", IsolatedTitleDefaults())
struct P02RegressionTests {

    private static let day: TimeInterval = 24 * 60 * 60

    private func date(_ offset: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: offset * Self.day)
    }

    @discardableResult
    private func stay(
        _ ctx: ModelContext, day startDay: Double, hours: Double = 6,
        _ category: StayCategory, hex: String = "p02"
    ) -> Stay {
        let start = date(startDay)
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(hours * 3600),
            centroidLatitude: 0, centroidLongitude: 0, h3IndexRes6: hex,
            pingCount: 2, distanceFromHomeKm: 0, pingIDs: [])
        stay.category = category
        ctx.insert(stay)
        return stay
    }

    @discardableResult
    private func completedTrip(_ ctx: ModelContext, _ stays: [Stay], complete: Bool = true) -> Trip {
        let trip = Trip(startDate: stays[0].startTime)
        trip.endDate = complete ? stays[stays.count - 1].endTime : nil
        trip.isComplete = complete
        ctx.insert(trip)
        for (order, stay) in stays.enumerated() {
            stay.trip = trip
            stay.orderInTrip = order
        }
        return trip
    }

    private func hide(_ ctx: ModelContext, _ local: String, cloud: String? = nil, on tripID: UUID, at day: Double) {
        let row = HiddenPhoto(localIdentifier: local, tripID: tripID)
        row.cloudIdentifier = cloud
        row.hiddenAt = date(day)
        ctx.insert(row)
    }

    private static func makeSuite() -> String {
        let suite = "P02RegressionTests.\(UUID().uuidString)"
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        return suite
    }

    /// The ordinary back half (sanity, assembly, closure) and its one save,
    /// with the lineage log in `suite`.
    private func backHalf(
        _ classifier: TripClassifier, suite: String, favourites: Set<UUID> = []
    ) async throws {
        try await classifier.runIsolated { classifier in
            classifier.hiddenLineageDefaults = UserDefaults(suiteName: suite)!
            _ = try classifier.assembleClassificationResults(
                classified: 1, needsPublication: true, pinnedTripIDs: favourites)
        }
    }

    private struct TripRow: Equatable {
        let id: UUID
        let stays: Set<UUID>
    }

    private func trips(_ container: ModelContainer) throws -> [TripRow] {
        try ModelContext(container).fetch(FetchDescriptor<Trip>())
            .sorted { $0.startDate < $1.startDate }
            .map { TripRow(id: $0.id, stays: Set(($0.stays ?? []).map(\.id))) }
    }

    private func hidden(_ container: ModelContainer) throws -> [UUID: Set<String>] {
        var result: [UUID: Set<String>] = [:]
        for row in try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>()) {
            result[row.tripID, default: []].insert(row.localIdentifier)
        }
        return result
    }

    // MARK: - HIST-002

    /// A completed trip with a hidden photo is the user's whole journey and
    /// stays whole (`curatedCompletedTripStaysWholeWithImport`); assembly
    /// still takes an open one apart, so the open trip carries the lineage.
    @Test("a late home stay that splits an open trip hides its hidden photos on both pieces, and the piece with a fresh id can unhide on its own")
    func splitPiecesInheritHiddenPhotos() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        stay(ctx, day: 0, .home)
        let first = stay(ctx, day: 1, .destination, hex: "p02a")
        let second = stay(ctx, day: 5, .destination, hex: "p02b")
        let trip = completedTrip(ctx, [first, second], complete: false)
        stay(ctx, day: 6, .home)
        hide(ctx, "p02-photo", cloud: "p02-cloud", on: trip.id, at: 2)
        // The import: home on day 3, then somewhere new on day 3.5.
        stay(ctx, day: 3, .home)
        let imported = stay(ctx, day: 3.5, .destination, hex: "p02c")
        try ctx.save()
        let suite = Self.makeSuite()

        let classifier = TripClassifier(modelContainer: container)
        try await backHalf(classifier, suite: suite)

        let all = try trips(container)
        try #require(all.count == 2)
        // The id follows the later piece (equal overlap); the earlier is new.
        #expect(all[1] == TripRow(id: trip.id, stays: [imported.id, second.id]))
        #expect(all[0].stays == [first.id] && all[0].id != trip.id)
        let rows = try hidden(container)
        #expect(rows[trip.id] == ["p02-photo"])
        #expect(rows[all[0].id] == ["p02-photo"])
        let copy = try #require(try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>())
            .first { $0.tripID == all[0].id })
        #expect(copy.cloudIdentifier == "p02-cloud" && copy.hiddenAt == date(2))
        // The id was kept, so nothing is logged as retired.
        #expect(PhotoLineageStore.successors(defaults: UserDefaults(suiteName: suite)!).isEmpty)

        // Unhiding on the new piece leaves the original alone.
        let edit = ModelContext(container)
        for row in try edit.fetch(FetchDescriptor<HiddenPhoto>()) where row.tripID == all[0].id {
            edit.delete(row)
        }
        try edit.save()
        #expect(try hidden(container) == [trip.id: ["p02-photo"]])
    }

    @Test("a completed trip with a hidden photo stays whole when a late home stay arrives with new away stays inside it; the new stay joins it")
    func curatedCompletedTripStaysWholeWithImport() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        stay(ctx, day: 0, .home)
        let first = stay(ctx, day: 1, .destination, hex: "p02a")
        let second = stay(ctx, day: 5, .destination, hex: "p02b")
        let trip = completedTrip(ctx, [first, second])
        stay(ctx, day: 6, .home)
        hide(ctx, "p02-photo", on: trip.id, at: 2)
        try ctx.save()
        let suite = Self.makeSuite()
        let classifier = TripClassifier(modelContainer: container)
        try await backHalf(classifier, suite: suite)

        let late = ModelContext(container)
        stay(late, day: 3, .home)
        let imported = stay(late, day: 3.5, .destination, hex: "p02c")
        try late.save()
        try await backHalf(classifier, suite: suite)

        #expect(try trips(container) == [TripRow(id: trip.id, stays: [first.id, imported.id, second.id])])
        #expect(try hidden(container) == [trip.id: ["p02-photo"]])
        let defaults = UserDefaults(suiteName: suite)!
        #expect(PhotoLineageStore.successors(defaults: defaults).isEmpty)
        #expect(PhotoLineageStore.splits(defaults: defaults).isEmpty)
        #expect(try ModelContext(container).fetch(FetchDescriptor<Trip>()).allSatisfy { !$0.userEdited })
        #expect(await classifier.assemblyInvariantViolated() == false)
    }

    @Test("a bridge that merges two completed trips carries the retired trip's hidden photos onto the merged trip and logs its lineage with the save")
    func mergedConstituentPassesHiddenPhotos() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        stay(ctx, day: 0, .home)
        let first = stay(ctx, day: 1, .destination, hex: "p02a")
        let kept = completedTrip(ctx, [first])
        let second = stay(ctx, day: 5, .destination, hex: "p02b")
        let retired = completedTrip(ctx, [second])
        stay(ctx, day: 6, .home)
        // An unrelated trip later on inherits nothing.
        let elsewhere = completedTrip(ctx, [stay(ctx, day: 20, .destination, hex: "p02e")])
        stay(ctx, day: 21, .home)
        hide(ctx, "p02-retired", on: retired.id, at: 5)
        hide(ctx, "p02-kept", on: kept.id, at: 1)
        let bridge = stay(ctx, day: 3, .destination, hex: "p02c")
        try ctx.save()
        let suite = Self.makeSuite()

        let classifier = TripClassifier(modelContainer: container)
        try await backHalf(classifier, suite: suite)

        let merged = try #require(try trips(container).first { $0.id == kept.id })
        #expect(merged.stays == [first.id, bridge.id, second.id])
        #expect(try trips(container).contains { $0.id == retired.id } == false)
        let rows = try hidden(container)
        #expect(rows[kept.id] == ["p02-kept", "p02-retired"])
        #expect(rows[elsewhere.id] == nil)
        #expect(PhotoLineageStore.successors(defaults: UserDefaults(suiteName: suite)!)
            == [retired.id: [kept.id]])
    }

    @Test("a failed save puts the lineage log back and keeps the old trips and their photos")
    func failedSaveRestoresLineage() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        stay(ctx, day: 0, .home)
        let kept = completedTrip(ctx, [stay(ctx, day: 1, .destination, hex: "p02a")])
        let retired = completedTrip(ctx, [stay(ctx, day: 5, .destination, hex: "p02b")])
        stay(ctx, day: 6, .home)
        hide(ctx, "p02-retired", on: retired.id, at: 5)
        stay(ctx, day: 3, .destination, hex: "p02c")
        try ctx.save()
        let suite = Self.makeSuite()
        let earlier = UUID()
        PhotoLineageStore.record([.init(retiredID: earlier, successorIDs: [kept.id])],
                                 defaults: UserDefaults(suiteName: suite)!)

        let classifier = TripClassifier(modelContainer: container)
        await #expect(throws: CocoaError.self) {
            try await TripClassifier.SaveTestHook.$beforeSave.withValue({
                throw CocoaError(.fileWriteUnknown)
            }) {
                try await backHalf(classifier, suite: suite)
            }
        }
        #expect(PhotoLineageStore.successors(defaults: UserDefaults(suiteName: suite)!)
            == [earlier: [kept.id]])
        #expect(Set(try trips(container).map(\.id)) == [kept.id, retired.id])
        #expect(try hidden(container) == [retired.id: ["p02-retired"]])
    }

    @Test("a split that keeps the original id passes a photo hidden before the split, that syncs in after it, on to the other piece once; a later hide stays the original's, and unhiding on the piece sticks")
    func lateHiddenRowFollowsSplitKeepingTheID() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        stay(ctx, day: 0, .home)
        let first = stay(ctx, day: 1, .destination, hex: "p02a")
        let second = stay(ctx, day: 5, .destination, hex: "p02b")
        // Open: assembly takes an open trip apart, curated or not.
        let trip = completedTrip(ctx, [first, second], complete: false)
        stay(ctx, day: 6, .home)
        hide(ctx, "p02-photo", on: trip.id, at: 2)
        stay(ctx, day: 3, .home)
        stay(ctx, day: 3.5, .destination, hex: "p02c")
        try ctx.save()
        let suite = Self.makeSuite()
        let defaults = UserDefaults(suiteName: suite)!
        let classifier = TripClassifier(modelContainer: container)
        try await backHalf(classifier, suite: suite)

        let all = try trips(container)
        try #require(all.count == 2 && all[1].id == trip.id)
        let piece = all[0].id
        let split = try #require(PhotoLineageStore.splits(defaults: defaults)[trip.id])
        #expect(split.successorIDs == [piece])
        #expect(split.settledRowIDs.count == 1)

        // Another device hid one photo before it saw the split, and one after.
        let late = ModelContext(container)
        hide(late, "p02-late", on: trip.id, at: 2.5)
        let after = HiddenPhoto(localIdentifier: "p02-after", tripID: trip.id)
        after.hiddenAt = split.splitAt.addingTimeInterval(60)
        late.insert(after)
        try late.save()
        let now = Date.now
        #expect(await PhotoAnnotationDeduplicator.removeOrphans(modelContainer: container, now: now, defaults: defaults))
        #expect(try hidden(container) == [trip.id: ["p02-photo", "p02-late", "p02-after"],
                                          piece: ["p02-photo", "p02-late"]])

        let edit = ModelContext(container)
        for row in try edit.fetch(FetchDescriptor<HiddenPhoto>())
        where row.tripID == piece && row.localIdentifier == "p02-late" {
            edit.delete(row)
        }
        try edit.save()
        #expect(await PhotoAnnotationDeduplicator.removeOrphans(modelContainer: container, now: now, defaults: defaults))
        #expect(try hidden(container)[piece] == ["p02-photo"])
    }

    @Test("inside a temporary-home unit, an unrelated open trip its assembly takes apart at a home stay passes its hidden photo on to both pieces")
    func temporaryHomeAssemblyCarriesUnrelatedRegroupChoices() async throws {
        typealias Fixture = TemporaryHomeFixture
        let real: Fixture.Place = (44.3, 12.9)
        let base: Fixture.Place = (45.3, 13.9)
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        Fixture.realHome(ctx, "Home", at: real)
        let declared = Fixture.temporaryHome(ctx, "Term", at: base, from: 10, until: 20, zone: "GMT")
        // A trip the declaration covers, so the unit rebuilds and assembles.
        Fixture.trip(ctx, [Fixture.stay(ctx, base, from: Fixture.date(12), to: Fixture.date(12.5),
                                        .destination, hex: "B", pingCount: 2, zone: "GMT")], complete: true)
        // Far from both, weeks later: an open journey, with a night at home
        // between its stays that no assembly has read yet.
        Fixture.stay(ctx, real, from: Fixture.date(49), to: Fixture.date(49.5), .home, hex: "H", pingCount: 2)
        let early = Fixture.stay(ctx, (44.3, 14.5), from: Fixture.date(50), to: Fixture.date(50.3),
                                 .destination, hex: "A", pingCount: 2)
        let later = Fixture.stay(ctx, (44.3, 14.6), from: Fixture.date(54), to: Fixture.date(54.3),
                                 .destination, hex: "C", pingCount: 2)
        let journey = Fixture.trip(ctx, [early, later], complete: false)
        Fixture.stay(ctx, real, from: Fixture.date(52), to: Fixture.date(52.5), .home, hex: "H", pingCount: 2)
        hide(ctx, "p02-photo", on: journey.id, at: 50.1)
        try ctx.save()
        let (earlyID, laterID) = (early.id, later.id)

        let classifier = await Fixture.classifier(container, squares: [(1, real), (2, base)])
        await classifier.setDissolvedRecordSink { _ in }
        _ = await classifier.applyTemporaryHomeChangeCore(temporaryHomeID: declared.id, pinnedTripIDs: [])

        let check = ModelContext(container)
        let stays = try check.fetch(FetchDescriptor<Stay>())
        let earlyTrip = try #require(stays.first { $0.id == earlyID }?.trip?.id)
        let laterTrip = try #require(stays.first { $0.id == laterID }?.trip?.id)
        #expect(earlyTrip != laterTrip)
        let rows = try hidden(container)
        #expect(rows[earlyTrip] == ["p02-photo"])
        #expect(rows[laterTrip] == ["p02-photo"])
    }

    // MARK: - DET-002

    /// Settled history behind a home stay, then a journey with one new stay.
    private func stage15Store() throws -> (ModelContainer, history: [UUID], journey: UUID) {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let history = (0..<6).map { stay(ctx, day: Double($0), .destination, hex: "p02h\($0)").id }
        stay(ctx, day: 10, hours: 12, .home)
        stay(ctx, day: 11, .destination, hex: "p02j")
        let journey = stay(ctx, day: 12, .unclassified, hex: "p02n").id
        try ctx.save()
        return (container, history, journey)
    }

    private func categories(_ container: ModelContainer, _ ids: [UUID]) throws -> [StayCategory] {
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>())
        return ids.compactMap { id in stays.first { $0.id == id }?.category }
    }

    @Test("a failed latest-home read in Stage 1.5 throws before resetting anything instead of treating all history as the journey")
    func failedHomeReadResetsNothing() async throws {
        let (container, history, _) = try stage15Store()
        let classifier = TripClassifier(modelContainer: container)
        classifier.failReclassificationHomeReadForTesting = true
        defer { classifier.failReclassificationHomeReadForTesting = false }

        await #expect(throws: CocoaError.self) { try await classifier.prepareForReclassification() }
        #expect(await classifier.readFailureContextHasChangesForTesting() == false)

        // Through the pipeline the unit fails and commits nothing.
        let saves = OSAllocatedUnfairLock(initialState: 0)
        let result = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
            gate: PipelineGate(forTesting: ()), beforeSave: { saves.withLock { $0 += 1 } })
        #expect(!result.completed)
        #expect(saves.withLock { $0 } == 0)
        #expect(try categories(container, history) == Array(repeating: StayCategory.destination, count: history.count))
    }

    @Test("a read that finds the home stay keeps history settled, and one that finds no home stay still starts the journey at the beginning")
    func successfulHomeReadsKeepTheirMeaning() async throws {
        let (container, _, _) = try stage15Store()
        let classifier = TripClassifier(modelContainer: container)
        #expect(try await classifier.prepareForReclassification().count == 1)

        let empty = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(empty)
        let settled = (0..<6).map { stay(ctx, day: Double($0), .destination, hex: "p02e\($0)").id }
        // Blips (at most 20 minutes) after them do not count toward the window.
        for blip in 0..<3 { stay(ctx, day: 6.5 + Double(blip) * 0.01, hours: 0.25, .transit, hex: "p02b\(blip)") }
        stay(ctx, day: 7, .unclassified, hex: "p02n")
        try ctx.save()
        let reset = try await TripClassifier(modelContainer: empty).prepareForReclassification()
        #expect(Set(reset) == Set(settled.suffix(5)))
    }

    // MARK: - DET-001

    private static let base: TemporaryHomeFixture.Place = (44.3, 12.9)
    /// About 7 km beyond the base square's eastern edge.
    private static let east: TemporaryHomeFixture.Place = (44.3, 13.04)

    @Test("with real homes only, moving a suppressed stop about 220 m across the home area's edge, inside its fingerprint's allowance, re-arms the check and the next pass admits the joined trip; jitter that crosses nothing stays quiet")
    func realHomeOnlyEdgeCrossingRearmsSuppression() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        TemporaryHomeFixture.realHome(ctx, "Base", at: Self.base)
        func outing(_ place: TemporaryHomeFixture.Place, _ from: Double, _ to: Double) -> Stay {
            TemporaryHomeFixture.stay(
                ctx, place, from: TemporaryHomeFixture.date(from), to: TemporaryHomeFixture.date(to),
                .destination, hex: "p02", pingCount: 2)
        }
        let first = outing(Self.east, 9 + 10.0 / 24, 9 + 14.0 / 24)
        let stop = outing((44.349, 12.9), 10 + 10.0 / 24, 10 + 11.0 / 24)
        let second = outing(Self.east, 11 + 10.0 / 24, 11 + 14.0 / 24)
        try ctx.save()
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<TemporaryHome>()) == 0)

        let classifier = await TemporaryHomeFixture.classifier(container, squares: [(1, Self.base)])
        await TemporaryHomeFixture.ordinaryPass(classifier)
        // The stop inside the base splits two four-hour outings near home.
        #expect(try trips(container).isEmpty)
        #expect(await classifier.assemblyInvariantViolated() == false)

        // Live jitter of some 55 m inside the area crosses no edge: quiet.
        let jitter = ModelContext(container)
        let jittered = try #require(try jitter.fetch(FetchDescriptor<Stay>()).first { $0.id == stop.id })
        jittered.centroidLatitude = 44.3485
        try jitter.save()
        #expect(await classifier.assemblyInvariantViolated() == false)

        // Sync corrects only the stop's latitude: now just outside the base.
        let synced = ModelContext(container)
        let copy = try #require(try synced.fetch(FetchDescriptor<Stay>()).first { $0.id == stop.id })
        copy.centroidLatitude = 44.351
        try synced.save()
        #expect(await classifier.assemblyInvariantViolated() == true)

        await TemporaryHomeFixture.ordinaryPass(classifier)
        #expect(try trips(container).map(\.stays) == [[first.id, stop.id, second.id]])
        #expect(await classifier.assemblyInvariantViolated() == false)
    }

    // MARK: - TEMP-001

    private func temporaryRing(
        _ place: TemporaryHomeFixture.Place, id: UUID, from: Double, until: Double
    ) -> TripClassifier.HomeRing {
        var ring = TripClassifier.HomeRing(
            latitude: place.lat, longitude: place.lon, radiusKm: 25,
            startedAt: date(from), endedAt: date(until), homeID: id)
        ring.isTemporary = true
        ring.claimsPrehistory = false
        return ring
    }

    @Test("with overlapping temporary homes, the departure distance is measured from the one the home stay records, the one the header names, while it claims the stay")
    func departureAnchorFollowsRecordedOwner() throws {
        let ctx = ModelContext(try TestSupport.makeInMemoryContainer())
        let ownerID = UUID(), otherID = UUID()
        let owner: TemporaryHomeFixture.Place = (44.3, 12.9)
        let other: TemporaryHomeFixture.Place = (44.3, 13.1)
        let rings = [temporaryRing(owner, id: ownerID, from: 0, until: 30),
                     temporaryRing(other, id: otherID, from: 0, until: 30)]
        // The stay sits nearer the other centre; both areas hold it.
        let departure = stay(ctx, day: 10, .home)
        departure.centroidLatitude = 44.3
        departure.centroidLongitude = 13.05
        departure.temporaryHomeID = ownerID

        func anchor(_ rings: [TripClassifier.HomeRing]) -> (latitude: Double, longitude: Double)? {
            TripClassifier.departureHomeAnchor(tripStart: date(11), homeStays: [departure], homeRings: rings)
        }
        #expect(anchor(rings)?.longitude == owner.lon)

        // Controls: no recorded owner, an owner the store does not hold, and
        // an owner whose dates no longer hold the stay fall back to the nearest.
        departure.temporaryHomeID = nil
        #expect(anchor(rings)?.longitude == other.lon)
        departure.temporaryHomeID = UUID()
        #expect(anchor(rings)?.longitude == other.lon)
        departure.temporaryHomeID = ownerID
        #expect(anchor([temporaryRing(owner, id: ownerID, from: 0, until: 5), rings[1]])?.longitude
            == other.lon)
        // A single ring is unchanged.
        #expect(anchor([rings[0]])?.longitude == owner.lon)
    }

    // MARK: - TITLE-002

    @Test("a blank metro or island never hides the locality under it, in titles or in the stored summary")
    func blankPlaceLayersAreMissing() throws {
        for blank in ["", " ", "\n", " \t "] {
            #expect(TripTitlePolicy.titlePlaceName(
                metro: blank, island: blank, locality: "Ostra", country: "Fictland", iso: nil) == "Ostra")
            #expect(TripTitlePolicy.titlePlaceName(
                metro: nil, island: blank, locality: "Ostra", country: nil, iso: nil) == "Ostra")
            #expect(TripTitlePolicy.titlePlaceName(
                metro: blank, island: nil, locality: blank, country: nil, iso: nil) == nil)
        }
        #expect(TripTitlePolicy.titlePlaceName(
            metro: nil, island: "Velo", locality: "Ostra", country: nil, iso: nil) == "Velo")

        let ctx = ModelContext(try TestSupport.makeInMemoryContainer())
        let island = stay(ctx, day: 1, .destination)
        island.islandName = " "
        island.locality = "Ostra"
        let metro = stay(ctx, day: 2, hours: 3, .destination)
        metro.metroName = ""
        metro.locality = "Marvo"
        #expect(island.placeGroupName == "Ostra" && metro.placeGroupName == "Marvo")
        let trip = completedTrip(ctx, [island, metro])
        try ctx.save()
        #expect(trip.recomputeSummary())
        #expect(trip.destinationSummary == "Ostra, Marvo")
    }

    // MARK: - TITLE-001

    @Test("a home's name keeps out only places in the home's own country: a foreign namesake stays the trip's lead destination")
    func foreignNamesakeOfHomeStaysADestination() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = Home(label: "Base", latitude: 44.3, longitude: 12.9, radiusKm: 25, startedAt: date(-100))
        home.locality = "Brenna"
        home.isoCountryCode = "XA"
        ctx.insert(home)
        let namesake = stay(ctx, day: 1, hours: 10, .destination)
        namesake.locality = "Brenna"
        namesake.isoCountryCode = "XB"
        let other = stay(ctx, day: 2, hours: 2, .destination)
        other.locality = "Tollo"
        other.isoCountryCode = "XB"
        let trip = completedTrip(ctx, [namesake, other])
        try ctx.save()

        func expectTitle(_ expected: String, summary: String) throws {
            try ctx.save()
            TripTitleStore.invalidateHomePlaceIndex()
            let names = try TripClassifier.homePlaceNames(for: trip, in: ctx)
            #expect(names.contains("brenna"))
            let title = TripTitlePolicy.defaultTitle(
                stays: TripTitleStore.semanticSnapshot(for: trip).stays, homePlaceNames: names)
            #expect(title == expected)
            #expect(trip.recomputeSummary())
            #expect(trip.destinationSummary == summary)
        }
        try expectTitle("Brenna & Tollo", summary: "Brenna, Tollo")

        // The home's own country, or a country unknown on either side, is home.
        namesake.isoCountryCode = "XA"
        try expectTitle("Tollo", summary: "Tollo")
        namesake.isoCountryCode = nil
        try expectTitle("Tollo", summary: "Tollo")
        namesake.isoCountryCode = "XB"
        home.isoCountryCode = nil
        try expectTitle("Tollo", summary: "Tollo")
    }

    @Test("a home stay whose country changes, with the trip, the Homes and the home names unchanged, changes the title the trip is given")
    func homeCountryChangeChangesTheTitle() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let home = Home(label: "Base", latitude: 44.3, longitude: 12.9, radiusKm: 25, startedAt: date(-100))
        home.locality = "Calda"
        home.isoCountryCode = "XA"
        ctx.insert(home)
        let earlier = stay(ctx, day: 0, .home)
        earlier.locality = "Brenna"
        earlier.isoCountryCode = "XA"
        let namesake = stay(ctx, day: 1, hours: 10, .destination)
        namesake.locality = "Brenna"
        namesake.isoCountryCode = "XB"
        let other = stay(ctx, day: 2, hours: 2, .destination)
        other.locality = "Tollo"
        other.isoCountryCode = "XB"
        let trip = completedTrip(ctx, [namesake, other])
        try ctx.save()
        TripTitleStore.invalidateHomePlaceIndex()
        TripTitleStore.invalidateGeneratedTitles(for: trip, in: ctx)
        #expect(trip.aiGeneratedTitle == "Brenna & Tollo")

        // Another device places that evening at home in the namesake's country.
        earlier.isoCountryCode = "XB"
        try ctx.save()
        TripTitleStore.invalidateHomePlaceIndex()
        TripTitleStore.invalidateGeneratedTitles(for: trip, in: ctx)
        #expect(trip.aiGeneratedTitle == "Tollo")
    }

    // MARK: - WID-001

    @Test("both widgets count a completed trip's countries before its stays arrive, as Passport and Siri do, but not an ongoing trip's")
    func widgetsCountCompletedTripSummaries() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let visited = stay(ctx, day: 1, .destination)
        visited.isoCountryCode = "XA"
        let landed = completedTrip(ctx, [visited])
        landed.countryCodes = "XA"
        // Synced summaries whose stays have not landed on this device yet.
        let pending = Trip(startDate: date(10))
        pending.endDate = date(12)
        pending.isComplete = true
        pending.countryCodes = "XB,XC"
        ctx.insert(pending)
        let twin = Trip(startDate: date(10))
        twin.id = pending.id
        twin.endDate = date(12)
        twin.isComplete = true
        twin.countryCodes = "XB"
        ctx.insert(twin)
        let ongoing = Trip(startDate: date(20))
        ongoing.countryCodes = "XD"
        ctx.insert(ongoing)
        try ctx.save()

        let stats = try Stay.widgetTravelStats(in: container, pageSize: 1)
        #expect(stats.countryCodes == ["XA", "XB", "XC"])
        #expect(stats.tripCount == 2)
        #expect(try Stay.widgetVisitedCountryCodes(in: container, pageSize: 1) == ["XA", "XB", "XC"])
        let siri = try StatsAggregator.passportSummary(container: container, now: date(30))
        #expect(siri.countries == stats.countryCodes)

        // The new read is required: a failure throws, never a smaller set.
        #expect(throws: CocoaError.self) {
            try WidgetStoreRead.$failureForTesting.withValue({ read in
                if read == .completedTripCountries { throw CocoaError(.fileReadUnknown) }
            }) {
                try Stay.widgetVisitedCountryCodes(in: container, pageSize: 1)
            }
        }
    }

    // MARK: - HIST-007

    @Test("an imported home stay alone, with no new away stay, splits the completed trip it falls inside; one with a hidden photo stays whole with it")
    func homeOnlyImportSplitsCompletedTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        stay(ctx, day: 0, .home)
        let first = stay(ctx, day: 1, .destination, hex: "p02a")
        let second = stay(ctx, day: 5, .destination, hex: "p02b")
        let trip = completedTrip(ctx, [first, second])
        stay(ctx, day: 6, .home)
        let hiddenStays = [stay(ctx, day: 11, .destination, hex: "p02c"), stay(ctx, day: 15, .destination, hex: "p02d")]
        let hiddenTrip = completedTrip(ctx, hiddenStays)
        stay(ctx, day: 16, .home)
        hide(ctx, "p02-photo", on: hiddenTrip.id, at: 11)
        try ctx.save()
        let suite = Self.makeSuite()
        let classifier = TripClassifier(modelContainer: container)
        try await backHalf(classifier, suite: suite)
        #expect(try trips(container).count == 2)

        // The import holds only the evenings at home in between.
        let late = ModelContext(container)
        stay(late, day: 3, .home).source = .photoImport
        stay(late, day: 13, .home).source = .photoImport
        try late.save()
        try await backHalf(classifier, suite: suite)

        let all = try trips(container)
        try #require(all.count == 3)
        #expect(all[0].stays == [first.id] && all[1] == TripRow(id: trip.id, stays: [second.id]))
        #expect(all[2] == TripRow(id: hiddenTrip.id, stays: Set(hiddenStays.map(\.id))))
        #expect(try hidden(container) == [hiddenTrip.id: ["p02-photo"]])
        #expect(await classifier.assemblyInvariantViolated() == false)
    }

    @Test("one imported home photo or a single noisy fix inside a completed trip leaves it whole; a real evening and morning at home splits it")
    func onlyAMeasuredHomeStaySplitsAnAssembledTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        stay(ctx, day: 0, .home)
        let first = stay(ctx, day: 1, .destination, hex: "p02a")
        let second = stay(ctx, day: 5, .destination, hex: "p02b")
        let trip = completedTrip(ctx, [first, second])
        stay(ctx, day: 6, .home)
        try ctx.save()
        let suite = Self.makeSuite()
        let classifier = TripClassifier(modelContainer: container)
        try await backHalf(classifier, suite: suite)

        // One photo at home, and one GPX fix that strayed there for a moment.
        let late = ModelContext(container)
        let photo = stay(late, day: 2, hours: 0, .home)
        photo.source = .photoImport
        photo.pingCount = 1
        let fix = stay(late, day: 3, hours: 0.1, .home)
        fix.source = .gpxImport
        fix.pingCount = 1
        try late.save()
        try await backHalf(classifier, suite: suite)
        #expect(try trips(container) == [TripRow(id: trip.id, stays: [first.id, second.id])])

        // Photos that evening and the next morning: the user slept at home.
        let overnight = ModelContext(container)
        let evening = stay(overnight, day: 3.75, hours: 12, .home)
        evening.source = .photoImport
        evening.pingCount = 2
        try overnight.save()
        #expect(await classifier.assemblyInvariantViolated() == true)
        try await backHalf(classifier, suite: suite)
        let all = try trips(container)
        #expect(all.map(\.stays) == [[first.id], [second.id]])
        #expect(all.last?.id == trip.id)
    }

    @Test("a favourite, a named trip and one with a pinned photo stay whole across a late night at home, and an untouched trip splits; one no longer favourite is scanned again")
    func curatedTripsStayWholeAcrossLateHomeStays() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        var curated: [Trip] = []
        var plain: Trip?
        for (index, base) in [0.0, 10, 20, 30].enumerated() {
            stay(ctx, day: base, .home)
            let members = [stay(ctx, day: base + 1, .destination, hex: "p02-\(index)a"),
                           stay(ctx, day: base + 5, .destination, hex: "p02-\(index)b")]
            let trip = completedTrip(ctx, members)
            if index == 3 { plain = trip } else { curated.append(trip) }
            stay(ctx, day: base + 6, .home)
        }
        curated[1].customName = "Named"
        ctx.insert(PinnedPhoto(localIdentifier: "p02-pin", tripID: curated[2].id))
        try ctx.save()
        let favourite = curated[0].id
        let suite = Self.makeSuite()
        let classifier = TripClassifier(modelContainer: container)
        try await backHalf(classifier, suite: suite, favourites: [favourite])

        let late = ModelContext(container)
        for base in [0.0, 10, 20, 30] { stay(late, day: base + 3, .home) }
        try late.save()
        try await backHalf(classifier, suite: suite, favourites: [favourite])

        let all = try trips(container)
        #expect(all.count == 5)
        for trip in curated {
            #expect(all.contains { $0.id == trip.id && $0.stays.count == 2 })
        }
        let pieces = all.filter { $0.stays.count == 1 }
        #expect(pieces.count == 2 && pieces.contains { $0.id == plain?.id })

        // Nothing moved: no scan. The favourite unpinned: scanned again, and split.
        let scans = await classifier.historicalScanCountForTesting
        try await backHalf(classifier, suite: suite, favourites: [favourite])
        #expect(await classifier.historicalScanCountForTesting == scans)
        try await backHalf(classifier, suite: suite)
        #expect(await classifier.historicalScanCountForTesting == scans + 1)
        #expect(try trips(container).count == 6)
    }

    @Test("an assembly with nothing to group skips the completed-trip scan while its inputs hold; a home stay that comes to qualify at the same count re-arms it and splits the trip")
    func unchangedBoundariesSkipTheCompletedTripScan() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        stay(ctx, day: 0, .home)
        let first = stay(ctx, day: 1, .destination, hex: "p02a")
        let second = stay(ctx, day: 5, .destination, hex: "p02b")
        let trip = completedTrip(ctx, [first, second])
        // Ten minutes at home: short of the dwell a boundary needs.
        let brief = stay(ctx, day: 3, hours: 10.0 / 60, .home)
        brief.pingCount = 3
        stay(ctx, day: 6, .home)
        try ctx.save()
        let suite = Self.makeSuite()
        let classifier = TripClassifier(modelContainer: container)
        try await backHalf(classifier, suite: suite)
        #expect(await classifier.historicalScanCountForTesting == 1)
        try await backHalf(classifier, suite: suite)
        #expect(await classifier.historicalScanCountForTesting == 1)
        #expect(await classifier.assemblyInvariantViolated() == false)
        #expect(try trips(container) == [TripRow(id: trip.id, stays: [first.id, second.id])])

        // The same row now holds two hours at home; no home stay came or went.
        let grown = ModelContext(container)
        let row = try #require(try grown.fetch(FetchDescriptor<Stay>()).first { $0.id == brief.id })
        row.endTime = row.startTime.addingTimeInterval(2 * 3600)
        try grown.save()
        #expect(await classifier.assemblyInvariantViolated() == true)
        try await backHalf(classifier, suite: suite)
        #expect(await classifier.historicalScanCountForTesting == 2)
        #expect(try trips(container).map(\.stays) == [[first.id], [second.id]])
        #expect(await classifier.assemblyInvariantViolated() == false)
        try await backHalf(classifier, suite: suite)
        #expect(await classifier.historicalScanCountForTesting == 2)

        // The home stay after the last trip grows, as one lived in does: no trip
        // spans it, so the steady state holds and the scan stays skipped.
        let home = ModelContext(container)
        let last = try #require(try home.fetch(FetchDescriptor<Stay>(
            sortBy: [SortDescriptor(\.startTime, order: .reverse)])).first)
        #expect(last.category == .home)
        last.endTime = last.endTime.addingTimeInterval(3600)
        try home.save()
        #expect(await classifier.assemblyInvariantViolated() == false)
        try await backHalf(classifier, suite: suite)
        #expect(await classifier.historicalScanCountForTesting == 2)
    }

    @Test("a home stay that syncs in already classified re-arms the steady-state check, and the next pass splits the trip")
    func syncedHomeStayRearmsInvariant() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        stay(ctx, day: 0, .home)
        let first = stay(ctx, day: 1, .destination, hex: "p02a")
        let second = stay(ctx, day: 5, .destination, hex: "p02b")
        let trip = completedTrip(ctx, [first, second])
        stay(ctx, day: 6, .home)
        try ctx.save()
        let suite = Self.makeSuite()
        let classifier = TripClassifier(modelContainer: container)
        try await backHalf(classifier, suite: suite)
        #expect(await classifier.assemblyInvariantViolated() == false)

        let synced = ModelContext(container)
        stay(synced, day: 3, .home)
        try synced.save()
        #expect(await classifier.assemblyInvariantViolated() == true)

        try await backHalf(classifier, suite: suite)
        #expect(try trips(container).map(\.stays) == [[first.id], [second.id]])
        #expect(try trips(container).last?.id == trip.id)
        #expect(await classifier.assemblyInvariantViolated() == false)
    }

    @Test("an edited trip, and a trip whose inner home stay is a single unmeasured live fix, stay whole")
    func editedTripsAndPhantomHomesStayWhole() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        stay(ctx, day: 0, .home)
        let editedStays = [stay(ctx, day: 1, .destination, hex: "p02a"), stay(ctx, day: 5, .destination, hex: "p02b")]
        let edited = completedTrip(ctx, editedStays)
        edited.userEdited = true
        stay(ctx, day: 3, .home)
        stay(ctx, day: 6, .home)
        let phantomStays = [stay(ctx, day: 11, .destination, hex: "p02c"), stay(ctx, day: 15, .destination, hex: "p02d")]
        let phantomTrip = completedTrip(ctx, phantomStays)
        let phantom = stay(ctx, day: 13, hours: 0, .home)
        phantom.pingCount = 1
        stay(ctx, day: 16, .home)
        try ctx.save()

        let classifier = TripClassifier(modelContainer: container)
        try await backHalf(classifier, suite: Self.makeSuite())

        #expect(try trips(container) == [
            TripRow(id: edited.id, stays: Set(editedStays.map(\.id))),
            TripRow(id: phantomTrip.id, stays: Set(phantomStays.map(\.id))),
        ])
    }
}
