//
//  CanonicalTitleLifecycleTests.swift
//  TravelLogTests
//
//  The canonical title's lifecycle: Stage 5 names untitled trips, a changed
//  input derives the title again in its own transaction (keeping the
//  default, with its translations), and the launch pass and the calendar
//  wipe bring every stored title under the deterministic policy.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Canonical title lifecycle", .serialized, IsolatedTitleDefaults())
struct CanonicalTitleLifecycleTests {

    private static let start = Date(timeIntervalSinceReferenceDate: 826_611_200)

    /// A trip with one destination stay per `(locality, hours)`, an hour apart,
    /// in visit order. `complete` false leaves it ongoing.
    private func makeTrip(
        _ places: [(String, Double)],
        complete: Bool = true,
        in context: ModelContext
    ) throws -> Trip {
        let trip = Trip(startDate: Self.start)
        context.insert(trip)
        var cursor = Self.start
        for (index, (locality, hours)) in places.enumerated() {
            let stay = Stay(
                startTime: cursor,
                endTime: cursor.addingTimeInterval(hours * 3_600),
                centroidLatitude: 37.3 + Double(index) * 0.1,
                centroidLongitude: 23.5,
                h3IndexRes6: "8a2a1072b59ffff",
                pingCount: 2,
                distanceFromHomeKm: 40,
                pingIDs: [])
            stay.durationMinutes = Int(hours * 60)
            stay.category = .destination
            stay.locality = locality
            stay.country = "Greece"
            stay.isoCountryCode = "GR"
            context.insert(stay)
            stay.trip = trip
            stay.orderInTrip = index
            cursor = stay.endTime.addingTimeInterval(3_600)
        }
        trip.isComplete = complete
        trip.endDate = complete ? trip.orderedStays.last?.endTime : nil
        try context.save()
        return trip
    }

    private func fetchTrip(_ id: UUID, in container: ModelContainer) throws -> Trip? {
        try fetchTrip(id, in: ModelContext(container))
    }

    private func fetchTrip(_ id: UUID, in context: ModelContext) throws -> Trip? {
        try context.fetch(FetchDescriptor<Trip>(predicate: #Predicate { $0.id == id })).first
    }

    // MARK: - Stage 5

    @Test("Stage 5 titles untitled trips and passes over custom-named and nameless ones")
    func stageFiveTitlesUntitledTrips() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let titled = try makeTrip([("Aegina", 30), ("Hydra", 10)], in: context)
        let named = try makeTrip([("Poros", 5)], in: context)
        named.customName = "Weekend"
        let transit = try makeTrip([("Spetses", 2)], in: context)
        transit.orderedStays[0].category = .transit
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.generateTitlesStage(
            maxTripsPerCall: nil, applyGate: PipelineGate(forTesting: ())) == 1)
        #expect(try fetchTrip(titled.id, in: container)?.aiGeneratedTitle == "Aegina & Hydra")
        #expect(try fetchTrip(named.id, in: container)?.aiGeneratedTitle == nil)
        #expect(try fetchTrip(transit.id, in: container)?.aiGeneratedTitle == nil)
        // Nothing left to name.
        #expect(await classifier.generateTitlesStage(
            maxTripsPerCall: nil, applyGate: PipelineGate(forTesting: ())) == 0)
    }

    @Test("a finite Stage 5 limit counts titles written, not trips passed over")
    func stageFiveLimitCountsWrites() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let older = try makeTrip([("Aegina", 30)], in: context)
        // Newer and nameless: an all-transit trip takes no title.
        let transit = try makeTrip([("Spetses", 2)], in: context)
        transit.startDate = Self.start.addingTimeInterval(86_400)
        transit.orderedStays[0].category = .transit
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.generateTitlesStage(
            maxTripsPerCall: 1, applyGate: PipelineGate(forTesting: ())) == 1)
        #expect(try fetchTrip(older.id, in: container)?.aiGeneratedTitle == "Aegina")
    }

    @Test("the detail screen's ensure names an untitled trip at once and never a custom-named one")
    func ensureNamesUntitledTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip([("Aegina", 30)], in: context)
        let named = try makeTrip([("Hydra", 30)], in: context)
        named.customName = "Island Day"
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.ensureCanonicalTitle(
            for: trip.id, gate: PipelineGate(forTesting: ())) == "Aegina")
        #expect(await classifier.ensureCanonicalTitle(
            for: named.id, gate: PipelineGate(forTesting: ())) == nil)
        #expect(try fetchTrip(named.id, in: container)?.aiGeneratedTitle == nil)
    }

    // MARK: - Changed inputs

    @Test("an extended live stay that keeps the ranked names leaves the title, its revision and its translations untouched")
    func extendedStayKeepsTitleAndVariants() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let trip = try makeTrip([("Aegina", 30), ("Hydra", 10), ("Poros", 5), ("Spetses", 2)],
                                complete: false, in: ModelContext(container))
        let classifier = TripClassifier(modelContainer: container)
        _ = await classifier.generateTitlesStage(maxTripsPerCall: nil, applyGate: PipelineGate(forTesting: ()))

        let context = ModelContext(container)
        let live = try #require(try fetchTrip(trip.id, in: context))
        #expect(live.aiGeneratedTitle == "Aegina, Hydra & Poros")
        #expect(TripTitleStore.upsertVariant(
            languageTag: "de", title: "Ägina, Hydra & Poros", sourceTitle: "Aegina, Hydra & Poros",
            for: live, in: context))
        try context.save()
        let revision = try #require(live.titleSourceRevision)

        // A live fix extends the last stay: its end and duration change.
        let last = try #require(live.orderedStays.last)
        let snapshots = TripTitleStore.parentSemanticSnapshots(for: [last])
        last.endTime = last.endTime.addingTimeInterval(2 * 3_600)
        last.durationMinutes += 120
        #expect(try TripTitleStore.invalidateChangedParentTitles(from: snapshots, in: context) == 1)
        try context.save()

        #expect(live.aiGeneratedTitle == "Aegina, Hydra & Poros")
        #expect(live.titleSourceRevision == revision)
        #expect(TripTitleStore.localizedTitle(for: live, languageTag: "de") == "Ägina, Hydra & Poros")

        // Growing past Poros changes the ranked names: the title follows and
        // its translation, made for the old text, goes.
        let grown = TripTitleStore.parentSemanticSnapshots(for: [last])
        last.endTime = last.endTime.addingTimeInterval(4 * 3_600)
        last.durationMinutes += 240
        _ = try TripTitleStore.invalidateChangedParentTitles(from: grown, in: context)
        try context.save()
        #expect(live.aiGeneratedTitle == "Aegina, Hydra & Spetses")
        #expect(live.titleSourceRevision != revision)
        #expect((live.localizedTitles ?? []).isEmpty)
    }

    @Test("a membership change replaces a title the trip no longer gives")
    func membershipChangeReplacesStaleTitle() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip([("Aegina", 30), ("Hydra", 10)], in: context)
        trip.aiGeneratedTitle = "Aegina & Hydra"
        try context.save()

        let hydra = try #require(trip.orderedStays.last)
        hydra.trip = nil
        TripTitleStore.invalidateGeneratedTitles(for: trip, in: context)
        #expect(trip.aiGeneratedTitle == "Aegina")
        // A trip left with no destination derives no title, but keeps a
        // grounded one: clearing it would let an older build title it again.
        trip.orderedStays[0].category = .transit
        #expect(try TripTitleStore.generatedTitleAlternatives(for: trip, in: context).isEmpty)
        #expect(!TripTitleStore.invalidateGeneratedTitles(for: trip, in: context))
        #expect(trip.aiGeneratedTitle == "Aegina")
    }

    @Test("an unreadable home-place set clears the title instead of keeping one it cannot check")
    func unreadableHomePlacesClearTitle() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip([("Aegina", 30)], in: context)
        trip.aiGeneratedTitle = "Aegina"
        try context.save()
        TripTitleStore.invalidateHomePlaceIndex()
        TripTitleStore.HomePlaceIndex.$failFetchForTesting.withValue(true) {
            #expect(TripTitleStore.invalidateGeneratedTitles(for: trip, in: context))
        }
        #expect(trip.aiGeneratedTitle == nil)
        TripTitleStore.invalidateHomePlaceIndex()
    }

    @Test("a home edit derives every title against the unsaved home, keeping the titles it leaves current")
    func homeEditUsesUnsavedHome() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let homeTrip = try makeTrip([("Aegina", 10), ("Hydra", 30)], in: context)
        homeTrip.aiGeneratedTitle = "Aegina & Hydra"
        let other = try makeTrip([("Poros", 10)], in: context)
        other.aiGeneratedTitle = "Poros"
        let otherRevision = UUID()
        other.titleSourceRevision = otherRevision
        try context.save()
        // Fill the shared cache with the rows from before the edit.
        _ = try TripTitleStore.homePlaceNames(for: homeTrip, in: context)

        let before = try TripTitleStore.fetchActiveHomeTitleInputs(in: context)
        let home = Home(label: "Home", latitude: 37.7, longitude: 23.4,
                        startedAt: Self.start.addingTimeInterval(-86_400))
        home.locality = "Aegina"
        home.isoCountryCode = "GR"
        context.insert(home)
        #expect(try TripTitleStore.invalidateAllGeneratedTitlesIfActiveHomesChanged(
            from: before, in: context))
        #expect(homeTrip.aiGeneratedTitle == "Hydra")
        #expect(other.aiGeneratedTitle == "Poros")
        #expect(other.titleSourceRevision == otherRevision)
        context.rollback()
        TripTitleStore.invalidateHomePlaceIndex()
    }

    /// Attaches a destination stay at `locality` for `hours` after the
    /// trip's last one, as a live writer would, and derives the title again.
    private func attachStay(
        _ locality: String, hours: Double, to trip: Trip, in context: ModelContext
    ) throws {
        let snapshots = TripTitleStore.parentSemanticSnapshots(for: trip.orderedStays)
        let begin = (trip.orderedStays.last?.endTime ?? Self.start).addingTimeInterval(3_600)
        let stay = Stay(
            startTime: begin, endTime: begin.addingTimeInterval(hours * 3_600),
            centroidLatitude: 38.1, centroidLongitude: 23.5,
            h3IndexRes6: "8a2a1072b59ffff", pingCount: 2, distanceFromHomeKm: 40, pingIDs: [])
        stay.durationMinutes = Int(hours * 60)
        stay.category = .destination
        stay.locality = locality
        stay.country = "Greece"
        stay.isoCountryCode = "GR"
        context.insert(stay)
        stay.trip = trip
        stay.orderInTrip = trip.orderedStays.count
        _ = try TripTitleStore.invalidateChangedParentTitles(from: snapshots, in: context)
    }

    /// Lengthens the trip's stay at `locality` by `hours`, as a live fix
    /// would, and derives the title again.
    private func extendStay(
        _ locality: String, by hours: Double, of trip: Trip, in context: ModelContext
    ) throws {
        let stay = try #require(trip.orderedStays.first { $0.locality == locality })
        let snapshots = TripTitleStore.parentSemanticSnapshots(for: [stay])
        stay.endTime = stay.endTime.addingTimeInterval(hours * 3_600)
        stay.durationMinutes += Int(hours * 60)
        _ = try TripTitleStore.invalidateChangedParentTitles(from: snapshots, in: context)
    }

    @Test("an ongoing one-place title grows when a shorter second place joins")
    func oneplaceTitleGrowsWithTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let trip = try makeTrip([("Velmora", 30)], complete: false, in: ModelContext(container))
        let classifier = TripClassifier(modelContainer: container)
        _ = await classifier.generateTitlesStage(maxTripsPerCall: nil, applyGate: PipelineGate(forTesting: ()))

        let context = ModelContext(container)
        let live = try #require(try fetchTrip(trip.id, in: context))
        #expect(live.aiGeneratedTitle == "Velmora")
        // "Velmora" is still one of the alternatives, but not the default.
        try attachStay("Castrel", hours: 5, to: live, in: context)
        #expect(live.aiGeneratedTitle == "Velmora & Castrel")
        let revision = live.titleSourceRevision
        // Growing the new stay keeps the ranked names: no churn.
        try extendStay("Castrel", by: 2, of: live, in: context)
        #expect(live.aiGeneratedTitle == "Velmora & Castrel")
        #expect(live.titleSourceRevision == revision)
    }

    @Test("a stored alternative other than the default gives way to the default on an input change")
    func nonDefaultAlternativeGivesWay() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip([("Velmora", 20), ("Castrel", 30)], complete: false, in: context)
        trip.aiGeneratedTitle = "Castrel"
        try context.save()
        try extendStay("Castrel", by: 1, of: trip, in: context)
        #expect(trip.aiGeneratedTitle == "Velmora & Castrel")
    }

    // MARK: - Stored titles from older builds

    @Test("the launch pass keeps current titles and replaces every other with the default")
    func launchPassDerivesStoredTitles() async throws {
        #expect(AppDelegate.tripSummaryMetroRefreshCompletedKey == "tripSummaryMetroRefreshCompleted_v7")
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let current = try makeTrip([("Aegina", 30)], in: context)
        current.aiGeneratedTitle = "Aegina"
        let revision = UUID()
        current.titleSourceRevision = revision
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Ägina", sourceTitle: "Aegina",
            sourceRevision: revision, trip: current))
        // An older build's model title, ranked by time instead of visit order
        // (Hydra holds too little of the time to lead as a base).
        let timeOrdered = try makeTrip([("Aegina", 20), ("Hydra", 30)], in: context)
        timeOrdered.aiGeneratedTitle = "Hydra & Aegina"
        // The retired prompt spelling deleted letters it could not transliterate.
        let mangled = try makeTrip([("Tromsø", 30)], in: context)
        mangled.orderedStays[0].country = "Norway"
        mangled.orderedStays[0].isoCountryCode = "NO"
        mangled.aiGeneratedTitle = "Troms"
        let staleRevision = UUID()
        mangled.titleSourceRevision = staleRevision
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Troms", sourceTitle: "Troms",
            sourceRevision: staleRevision, trip: mangled))
        // A custom name is never touched, nor its hidden title.
        let named = try makeTrip([("Poros", 30)], in: context)
        named.customName = "Poros Weekend"
        named.aiGeneratedTitle = "Old"
        try context.save()

        let result = await AppDelegate.recomputeAllTripSummariesForMetroRefresh(modelContainer: container)
        #expect(result.saved)
        let kept = try #require(try fetchTrip(current.id, in: container))
        #expect(kept.aiGeneratedTitle == "Aegina")
        #expect(kept.titleSourceRevision == revision)
        #expect(TripTitleStore.localizedTitle(for: kept, languageTag: "de") == "Ägina")
        #expect(try fetchTrip(timeOrdered.id, in: container)?.aiGeneratedTitle == "Aegina & Hydra")
        let respelled = try #require(try fetchTrip(mangled.id, in: container))
        #expect(respelled.aiGeneratedTitle == "Tromsø")
        #expect(respelled.titleSourceRevision != staleRevision)
        #expect((respelled.localizedTitles ?? []).isEmpty)
        #expect(try fetchTrip(named.id, in: container)?.aiGeneratedTitle == "Old")
    }

    @Test("while the store hydrates, the launch pass leaves the title of a trip whose stays have not all synced")
    func launchPassWaitsForPartiallySyncedTrips() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let partial = try makeTrip([("Aegina", 10), ("Hydra", 30)], in: context)
        partial.aiGeneratedTitle = "Saronic Escape"
        partial.recomputeSummary()
        // Hydra's stay has not reached this device yet.
        let hydra = try #require(partial.stays?.first { $0.locality == "Hydra" })
        hydra.trip = nil
        try context.save()

        let result = await AppDelegate.recomputeAllTripSummariesForMetroRefresh(
            modelContainer: container, storeMayBeHydrating: true)
        #expect(result.saved)
        #expect(result.owed == 1)
        #expect(try fetchTrip(partial.id, in: container)?.aiGeneratedTitle == "Saronic Escape")
    }

    @Test("a title derived from part of a synced trip heals when the missing stay arrives")
    func partiallySyncedTitleHeals() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip([("Velmora", 30), ("Castrel", 10)], in: context)
        trip.recomputeSummary()
        // Castrel's stay has not reached this device; the title names only Velmora.
        let castrel = try #require(trip.stays?.first { $0.locality == "Castrel" })
        castrel.trip = nil
        trip.aiGeneratedTitle = "Velmora"
        try context.save()
        #expect(AppDelegate.reconcileStoredTitles(modelContainer: container))
        #expect(try fetchTrip(trip.id, in: container)?.aiGeneratedTitle == "Velmora")

        castrel.trip = trip
        try context.save()
        #expect(AppDelegate.reconcileStoredTitles(modelContainer: container))
        #expect(try fetchTrip(trip.id, in: container)?.aiGeneratedTitle == "Velmora & Castrel")
    }

    @Test("while the store hydrates, the launch pass owes a partly synced trip its summary and title")
    func launchPassOwesPartlySyncedTripWhileHydrating() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip([("Velmora", 20), ("Castrel", 30)], in: context)
        trip.recomputeSummary()
        let title = try #require(try TripTitleStore.generatedTitleAlternatives(for: trip, in: context).first)
        trip.aiGeneratedTitle = title
        let revision = UUID()
        trip.titleSourceRevision = revision
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Velmora und Castrel", sourceTitle: title,
            sourceRevision: revision, trip: trip))
        let summary = trip.destinationSummary
        let codes = trip.countryCodes
        #expect(Trip.summaryComponents(summary).count == 2)
        // Castrel's stay has not reached this device yet.
        let castrel = try #require(trip.stays?.first { $0.locality == "Castrel" })
        castrel.trip = nil
        try context.save()

        func expectUntouched() throws {
            let stored = try #require(try fetchTrip(trip.id, in: container))
            #expect(stored.destinationSummary == summary)
            #expect(stored.countryCodes == codes)
            #expect(stored.aiGeneratedTitle == title)
            #expect(stored.titleSourceRevision == revision)
            #expect(TripTitleStore.localizedTitle(for: stored, languageTag: "de") == "Velmora und Castrel")
        }
        // Two launches before the stay arrives, each followed by the stored-title check.
        for _ in 0..<2 {
            let pass = await AppDelegate.recomputeAllTripSummariesForMetroRefresh(
                modelContainer: container, storeMayBeHydrating: true)
            #expect(pass.saved)
            #expect(pass.owed == 1)
            let countries = await AppDelegate.recomputeAllTripCountryCodes(
                modelContainer: container, storeMayBeHydrating: true)
            #expect(countries.saved)
            #expect(countries.owed == 1)
            #expect(AppDelegate.reconcileStoredTitles(modelContainer: container))
            try expectUntouched()
        }

        castrel.trip = trip
        try context.save()
        let completed = await AppDelegate.recomputeAllTripSummariesForMetroRefresh(
            modelContainer: container, storeMayBeHydrating: true)
        #expect(completed.saved)
        #expect(completed.owed == 0)
        #expect(AppDelegate.reconcileStoredTitles(modelContainer: container))
        try expectUntouched()
    }

    @Test("while the store hydrates, a stay-field writer owes a partly synced trip its summary and title")
    func stayFieldWriterOwesPartlySyncedTripWhileHydrating() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip([("Velmora", 20), ("Castrel", 30)], in: context)
        trip.recomputeSummary()
        let title = try #require(try TripTitleStore.generatedTitleAlternatives(for: trip, in: context).first)
        trip.aiGeneratedTitle = title
        let revision = UUID()
        trip.titleSourceRevision = revision
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Velmora und Castrel", sourceTitle: title,
            sourceRevision: revision, trip: trip))
        let summary = trip.destinationSummary
        // Castrel's stay has not reached this device yet.
        let castrel = try #require(trip.stays?.first { $0.locality == "Castrel" })
        castrel.trip = nil
        try context.save()
        let velmora = try #require(trip.stays?.first)

        // The launch geocoder fills Velmora's region, as its chunks do.
        let owed = TripTitleStore.$storeMayBeHydratingOverride.withValue(true) {
            let snapshots = TripTitleStore.parentSemanticSnapshots(for: [velmora])
            velmora.administrativeArea = "Northreach"
            return Result { try TripTitleStore.invalidateChangedParentTitles(from: snapshots, in: context) }
        }
        #expect(try owed.get() == 0)
        try context.save()
        #expect(AppDelegate.reconcileStoredTitles(modelContainer: container))
        let stored = try #require(try fetchTrip(trip.id, in: container))
        #expect(stored.destinationSummary == summary)
        #expect(stored.aiGeneratedTitle == title)
        #expect(stored.titleSourceRevision == revision)
        #expect(TripTitleStore.localizedTitle(for: stored, languageTag: "de") == "Velmora und Castrel")

        // Once hydration is settled, the same change derives the trip from its stays.
        let derived = TripTitleStore.$storeMayBeHydratingOverride.withValue(false) {
            let snapshots = TripTitleStore.parentSemanticSnapshots(for: [velmora])
            velmora.administrativeArea = "Southreach"
            return Result { try TripTitleStore.invalidateChangedParentTitles(from: snapshots, in: context) }
        }
        #expect(try derived.get() == 1)
        #expect(trip.destinationSummary == "Velmora")
    }

    @Test("a writer that leaves a partly synced trip for later owes the launch summary pass, which derives it once hydration settles")
    func deferredTripOwesLaunchSummaryPass() async throws {
        let defaults = IsolatedTitleDefaults.current
        defaults.set(true, forKey: AppDelegate.tripSummaryMetroRefreshCompletedKey)
        #expect(!AppDelegate.tripSummaryRefreshDue(defaults: defaults).due)

        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip([("Velmora", 20), ("Castrel", 30)], in: context)
        trip.recomputeSummary()
        let title = try #require(try TripTitleStore.generatedTitleAlternatives(for: trip, in: context).first)
        trip.aiGeneratedTitle = title
        let revision = UUID()
        trip.titleSourceRevision = revision
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Velmora und Castrel", sourceTitle: title,
            sourceRevision: revision, trip: trip))
        // Castrel's stay has not reached this device yet.
        let castrel = try #require(trip.stays?.first { $0.locality == "Castrel" })
        castrel.trip = nil
        try context.save()
        let velmora = try #require(trip.stays?.first)

        // Geocoding renames Velmora's place while the store hydrates.
        let deferred = TripTitleStore.$storeMayBeHydratingOverride.withValue(true) {
            let snapshots = TripTitleStore.parentSemanticSnapshots(for: [velmora])
            velmora.locality = "Mirelo"
            return Result { try TripTitleStore.invalidateChangedParentTitles(from: snapshots, in: context) }
        }
        #expect(try deferred.get() == 0)
        try context.save()
        let due = AppDelegate.tripSummaryRefreshDue(defaults: defaults)
        #expect(due.due)

        // Castrel arrives; no stay still names Velmora, so no stay-field
        // writer would take the trip as holding its named stays again.
        castrel.trip = trip
        try context.save()
        #expect(!TripTitleStore.holdsItsNamedStays(trip))

        // The next launch, with hydration settled, runs the pass.
        let pass = await AppDelegate.recomputeAllTripSummariesForMetroRefresh(
            modelContainer: container, storeMayBeHydrating: false)
        #expect(pass.saved)
        #expect(pass.owed == 0)
        let stored = try #require(try fetchTrip(trip.id, in: container))
        #expect(Set(Trip.summaryComponents(stored.destinationSummary)) == ["Mirelo", "Castrel"])
        // Its title follows the stays it names now, under a new revision,
        // and the variant of the old title goes with it.
        let derived = try TripTitleStore.generatedTitleAlternatives(for: stored, in: ModelContext(container)).first
        #expect(derived != nil)
        #expect(stored.aiGeneratedTitle == derived)
        #expect(stored.aiGeneratedTitle != title)
        #expect(stored.titleSourceRevision != revision)
        #expect((stored.localizedTitles ?? []).isEmpty)
        #expect(TripTitleStore.localizedTitle(for: stored, languageTag: "de") != "Velmora und Castrel")

        // A debt recorded while that pass ran waits for the next one.
        AppDelegate.oweTripSummaryRefresh(defaults: defaults)
        AppDelegate.latchTripSummaryRefresh(settling: due.owedToken, defaults: defaults)
        let next = AppDelegate.tripSummaryRefreshDue(defaults: defaults)
        #expect(next.due)
        AppDelegate.latchTripSummaryRefresh(settling: next.owedToken, defaults: defaults)
        #expect(!AppDelegate.tripSummaryRefreshDue(defaults: defaults).due)
    }

    @Test("while the store hydrates, a Home change that syncs in owes a partly synced trip its title")
    func homeChangeOwesPartlySyncedTripWhileHydrating() async throws {
        let defaults = IsolatedTitleDefaults.current
        defaults.set(true, forKey: AppDelegate.tripSummaryMetroRefreshCompletedKey)

        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let home = Home(label: "Home", latitude: 44.3, longitude: 12.9,
                        startedAt: Self.start.addingTimeInterval(-86_400))
        home.locality = "Lumora"
        context.insert(home)
        let trip = try makeTrip([("Velmora", 20), ("Castrel", 30)], in: context)
        trip.recomputeSummary()
        let title = try #require(try TripTitleStore.generatedTitleAlternatives(for: trip, in: context).first)
        trip.aiGeneratedTitle = title
        let revision = UUID()
        trip.titleSourceRevision = revision
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Velmora und Castrel", sourceTitle: title,
            sourceRevision: revision, trip: trip))
        let summary = trip.destinationSummary
        #expect(Trip.summaryComponents(summary).count == 2)
        // Castrel's stay has not reached this device yet.
        let castrel = try #require(trip.stays?.first { $0.locality == "Castrel" })
        castrel.trip = nil
        try context.save()
        // The first run records the baseline.
        #expect(try TripTitleStore.reconcileActiveHomeTitleFingerprint(in: context, defaults: defaults) == 0)
        #expect(!AppDelegate.tripSummaryRefreshDue(defaults: defaults).due)

        func expectUntouched() throws {
            let stored = try #require(try fetchTrip(trip.id, in: container))
            #expect(stored.destinationSummary == summary)
            #expect(stored.aiGeneratedTitle == title)
            #expect(stored.titleSourceRevision == revision)
            #expect(TripTitleStore.localizedTitle(for: stored, languageTag: "de") == "Velmora und Castrel")
        }
        // The Home's new locality syncs in ahead of Castrel's stay.
        home.locality = "Sorrel"
        try context.save()
        let owed = TripTitleStore.$storeMayBeHydratingOverride.withValue(true) {
            Result { try TripTitleStore.reconcileActiveHomeTitleFingerprint(in: context, defaults: defaults) }
        }
        #expect(try owed.get() == 0)
        try expectUntouched()
        let due = AppDelegate.tripSummaryRefreshDue(defaults: defaults)
        #expect(due.due)

        // Castrel arrives; the owed pass derives the whole trip under the new Home.
        castrel.trip = trip
        try context.save()
        let pass = await AppDelegate.recomputeAllTripSummariesForMetroRefresh(
            modelContainer: container, storeMayBeHydrating: true)
        #expect(pass.saved)
        #expect(pass.owed == 0)
        try expectUntouched()
        AppDelegate.latchTripSummaryRefresh(settling: due.owedToken, defaults: defaults)
        #expect(!AppDelegate.tripSummaryRefreshDue(defaults: defaults).due)
        TripTitleStore.invalidateHomePlaceIndex()
    }

    @Test("an all-transit trip takes no new title but keeps a grounded one an older build synced")
    func allTransitTripKeepsGroundedSyncedTitle() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let grounded = try makeTrip([("Velmora", 2)], in: context)
        let ungrounded = try makeTrip([("Castrel", 2)], in: context)
        for trip in [grounded, ungrounded] {
            for stay in trip.stays ?? [] { stay.category = .transit }
            trip.recomputeSummary()
            #expect(try TripTitleStore.generatedTitleAlternatives(for: trip, in: context).isEmpty)
        }
        grounded.aiGeneratedTitle = "Velmora"
        let revision = UUID()
        grounded.titleSourceRevision = revision
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Velmora", sourceTitle: "Velmora",
            sourceRevision: revision, trip: grounded))
        ungrounded.aiGeneratedTitle = "Harbour Layover"
        try context.save()

        #expect(!TripTitleStore.invalidateGeneratedTitles(for: grounded, in: context))
        #expect(AppDelegate.reconcileStoredTitles(modelContainer: container))
        let pass = await AppDelegate.recomputeAllTripSummariesForMetroRefresh(modelContainer: container)
        #expect(pass.saved)
        #expect(AppDelegate.reconcileStoredTitles(modelContainer: container))

        let kept = try #require(try fetchTrip(grounded.id, in: container))
        #expect(kept.aiGeneratedTitle == "Velmora")
        #expect(kept.titleSourceRevision == revision)
        #expect((kept.localizedTitles ?? []).count == 1)
        let cleared = try #require(try fetchTrip(ungrounded.id, in: container))
        #expect(TripTitleStore.normalized(cleared.aiGeneratedTitle) == nil)
    }

    @Test("a grounded all-transit title keeps the translation an older build stored; a destination trip's gives way")
    func allTransitTripKeepsOlderGenerationTranslation() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let grounded = try makeTrip([("Velmora", 2)], in: context)
        let rotated = try makeTrip([("Castrel", 2)], in: context)
        for trip in [grounded, rotated] {
            for stay in trip.stays ?? [] { stay.category = .transit }
            trip.recomputeSummary()
        }
        let older = TripTitleStore.currentGenerationVersion - 1
        grounded.aiGeneratedTitle = "Velmora"
        let revision = UUID()
        grounded.titleSourceRevision = revision
        context.insert(TripTitleVariant(
            languageTag: "el", title: "Βελμόρα", sourceTitle: "Velmora",
            sourceRevision: revision, generationVersion: older, trip: grounded))
        // A translation of an earlier revision of the same text never shows.
        rotated.aiGeneratedTitle = "Castrel"
        rotated.titleSourceRevision = UUID()
        context.insert(TripTitleVariant(
            languageTag: "el", title: "Καστρέλ", sourceTitle: "Castrel",
            sourceRevision: UUID(), generationVersion: older, trip: rotated))
        let destination = try makeTrip([("Dunvar", 10)], in: context)
        destination.recomputeSummary()
        destination.aiGeneratedTitle = "Dunvar"
        let destinationRevision = UUID()
        destination.titleSourceRevision = destinationRevision
        context.insert(TripTitleVariant(
            languageTag: "el", title: "Ντάνβαρ", sourceTitle: "Dunvar",
            sourceRevision: destinationRevision, generationVersion: older, trip: destination))
        try context.save()
        // Localization writes a destination trip a current translation, so its older one never shows.
        #expect(try fetchTrip(destination.id, in: container)?.displayName(languageTag: "el") == "Dunvar")

        let service = TripTitleLocalizationService(modelContainer: container)
        await service.setPlaceNamesForTesting { place, languageTag in
            place.name == "Dunvar" && languageTag == "el" ? "Ντούνβαρ" : nil
        }
        for _ in 0..<2 {
            let pass = await AppDelegate.recomputeAllTripSummariesForMetroRefresh(modelContainer: container)
            #expect(pass.saved)
            #expect(AppDelegate.reconcileStoredTitles(modelContainer: container))
            await service.generateLocalizedTitlesStage(maxTripsPerCall: nil, languageTag: "el")

            let kept = try #require(try fetchTrip(grounded.id, in: container))
            #expect(kept.aiGeneratedTitle == "Velmora")
            #expect(kept.titleSourceRevision == revision)
            #expect(kept.displayName(languageTag: "el") == "Βελμόρα")
            #expect(try fetchTrip(rotated.id, in: container)?.displayName(languageTag: "el") == "Castrel")
            #expect(try fetchTrip(destination.id, in: container)?.displayName(languageTag: "el") == "Ντούνβαρ")
        }

        // A current translation wins over the older one.
        let writer = ModelContext(container)
        let retitled = try #require(try fetchTrip(grounded.id, in: writer))
        writer.insert(TripTitleVariant(
            languageTag: "el", title: "Βέλμορα", sourceTitle: "Velmora",
            sourceRevision: revision, trip: retitled))
        try writer.save()
        #expect(try fetchTrip(grounded.id, in: container)?.displayName(languageTag: "el") == "Βέλμορα")
    }

    @Test("titles arriving from an older device are checked as the launch pass checks them")
    func arrivingTitlesAreChecked() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip([("Aegina", 20), ("Hydra", 30)], in: context)
        trip.aiGeneratedTitle = "Saronic Escape"
        try context.save()
        #expect(AppDelegate.reconcileStoredTitles(modelContainer: container))
        #expect(try fetchTrip(trip.id, in: container)?.aiGeneratedTitle == "Aegina & Hydra")
    }

    // MARK: - Calendar wipe

    @Test("the calendar wipe derives every title again and drops every translation in one transaction")
    func calendarWipeDerivesTitles() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let legacy = try makeTrip([("Aegina", 20), ("Hydra", 30)], in: context)
        legacy.aiGeneratedTitle = "Dentist Appointment"
        let current = try makeTrip([("Poros", 10)], in: context)
        current.aiGeneratedTitle = "Poros"
        let revision = UUID()
        current.titleSourceRevision = revision
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Poros", sourceTitle: "Poros",
            sourceRevision: revision, trip: current))
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        let result = await classifier.clearThenRegenerateAllTitlesForCalendarWipe(
            gate: PipelineGate(forTesting: ()))
        #expect(result == .init(cleared: true, revocationFinished: true, generated: 2))
        #expect(try fetchTrip(legacy.id, in: container)?.aiGeneratedTitle == "Aegina & Hydra")
        let kept = try #require(try fetchTrip(current.id, in: container))
        #expect(kept.aiGeneratedTitle == "Poros")
        #expect(kept.titleSourceRevision != revision)
        #expect((kept.localizedTitles ?? []).isEmpty)
    }

    @Test("a failed calendar wipe writes nothing and leaves the revocation unfinished")
    func failedCalendarWipeWritesNothing() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let legacy = try makeTrip([("Aegina", 10)], in: context)
        legacy.aiGeneratedTitle = "Dentist Appointment"
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        await classifier.failNextCalendarTitleWipeClear()
        let result = await classifier.clearThenRegenerateAllTitlesForCalendarWipe(
            gate: PipelineGate(forTesting: ()), finishRevocationAfterClear: {
                Issue.record("the revocation must not finish after a failed wipe")
                return true
            })
        #expect(!result.cleared)
        #expect(try fetchTrip(legacy.id, in: container)?.aiGeneratedTitle == "Dentist Appointment")
    }
}
