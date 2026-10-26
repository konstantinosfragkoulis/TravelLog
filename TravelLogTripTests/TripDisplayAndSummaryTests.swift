//
//  TripDisplayAndSummaryTests.swift
//  TravelLogTests
//
//  Covers `Trip` display + summary derivation: displayName 4-tier
//  precedence (custom → AI → destinationSummary → "Trip"), countryFlags,
//  the destinations/transits/orderedStays filters & sorts, recomputeSummary()
//  (destinationSummary metro→island→locality fallback + dedup, countryCodes
//  destination-only + the FRA-layover regression guard, sourceRaw
//  derivation), the source accessor, and the global flagEmoji(for:)
//  helper. Container-backed for the recomputeSummary cases (stays linked via
//  stay.trip = trip; stay.orderInTrip).
//
//  `@MainActor` because the app target compiles with MainActor-by-default
//  isolation, which makes `@Model` types (`Trip`, `Stay`) MainActor-isolated.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct TripDisplayAndSummaryTests {

    // MARK: - Fixtures

    private func makeStay(lat: Double = 0, lon: Double = 0, hex: String = "hex") -> Stay {
        Stay(startTime: .now, endTime: .now,
             centroidLatitude: lat, centroidLongitude: lon,
             h3IndexRes6: hex, pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
    }

    /// Inserts a trip + its stays into a fresh in-memory context, linking each
    /// stay to the trip and assigning `orderInTrip` by array position.
    private func makeLinkedTrip(stays: [Stay]) throws -> Trip {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: .now)
        context.insert(trip)
        for (i, stay) in stays.enumerated() {
            context.insert(stay)
            stay.trip = trip
            stay.orderInTrip = i
        }
        return trip
    }

    // MARK: - displayName precedence

    @Test("customName wins over aiGeneratedTitle and destinationSummary (tier 1)")
    func displayNameCustomNameWinsOverEverything() {
        let trip = Trip(startDate: .now)
        trip.customName = "My Trip"
        trip.aiGeneratedTitle = "AI"
        trip.destinationSummary = "London"
        #expect(trip.displayName == "My Trip")
    }

    @Test("empty (non-nil) customName is rejected by the !isEmpty guard → falls to AI title")
    func displayNameEmptyCustomNameFallsThrough() {
        let trip = Trip(startDate: .now)
        trip.customName = ""
        trip.aiGeneratedTitle = "AI Title"
        #expect(trip.displayName == "AI Title")
    }

    @Test("aiGeneratedTitle used when no customName (tier 2)")
    func displayNameAITitleUsedWhenNoCustom() {
        let trip = Trip(startDate: .now)
        trip.aiGeneratedTitle = "White Plains & NYC"
        trip.destinationSummary = "x"
        #expect(trip.displayName == "White Plains & NYC")
    }

    @Test("empty aiGeneratedTitle is rejected by the !isEmpty guard → falls to destinationSummary")
    func displayNameEmptyAITitleFallsThrough() {
        let trip = Trip(startDate: .now)
        trip.aiGeneratedTitle = ""
        trip.destinationSummary = "Lisbon"
        #expect(trip.displayName == "Lisbon")
    }

    @Test("destinationSummary used when no customName/AI title (tier 3), rendered as a natural-language join")
    func displayNameDestinationSummaryWhenNoCustomOrAI() {
        let trip = Trip(startDate: .now)
        trip.destinationSummary = "London, Oxford"
        // Presentation-only polish: the persisted comma-join is rendered with
        // an ampersand before the last component. `destinationSummary`
        // itself is unchanged.
        #expect(trip.displayName == "London & Oxford")
        #expect(trip.destinationSummary == "London, Oxford")
    }

    @Test("all three empty/nil → \"Trip\" literal fallback (tier 4)")
    func displayNameFallbackToLiteralTrip() {
        let trip = Trip(startDate: .now)
        #expect(trip.displayName == "Trip")
    }

    @Test("hasUsableDisplayName mirrors all displayName fallback tiers structurally")
    func usableDisplayNameTruthTable() {
        let trip = Trip(startDate: .now)
        #expect(trip.hasUsableDisplayName == false)

        trip.customName = "Trip"
        #expect(trip.hasUsableDisplayName)

        trip.customName = " "
        #expect(trip.hasUsableDisplayName)

        trip.customName = ""
        trip.aiGeneratedTitle = "AI Title"
        #expect(trip.hasUsableDisplayName)

        trip.aiGeneratedTitle = ""
        trip.destinationSummary = "Athens, Unknown"
        #expect(trip.hasUsableDisplayName)

        trip.destinationSummary = Trip.unknownDestinationSentinel
        #expect(trip.hasUsableDisplayName)

        trip.destinationSummary = ", ,"
        #expect(trip.hasUsableDisplayName == false)
        #expect(Trip.isUsableDestinationName(Trip.unknownDestinationSentinel) == false)
        #expect(Trip.isUsableDestinationName("Athens"))
    }

    // MARK: - countryFlags

    @Test("no codes → empty flag string")
    func countryFlagsEmptyWhenNoCodes() {
        let trip = Trip(startDate: .now)
        #expect(trip.countryCodes == "")
        #expect(trip.countryFlags == "")
    }

    @Test("\"GR,GB\" → \"🇬🇷 🇬🇧\" (space-joined regional-indicator flags)")
    func countryFlagsMapsCodesToEmojiSpaceJoined() {
        let trip = Trip(startDate: .now)
        trip.countryCodes = "GR,GB"
        #expect(trip.countryFlags == "🇬🇷 🇬🇧")
    }

    @Test("invalid 3-letter token is compactMap-dropped, leaving 2 flags")
    func countryFlagsSkipsInvalidCodes() {
        let trip = Trip(startDate: .now)
        trip.countryCodes = "GR,XXX,GB"
        #expect(trip.countryFlags == "🇬🇷 🇬🇧")
    }

    // MARK: - destinations / transits / orderedStays

    @Test("destinations returns only .destination stays, sorted by orderInTrip")
    func destinationsFilterExcludesNonDestinationAndSortsByOrder() throws {
        let s0 = makeStay(); s0.category = .transit          // order 0
        let s1 = makeStay(); s1.category = .destination      // order 1
        let s2 = makeStay(); s2.category = .destination      // order 2
        let s3 = makeStay(); s3.category = .home             // order 3
        // Insert in scrambled order, but makeLinkedTrip assigns orderInTrip
        // by position; we want destination@1 before destination@2.
        let trip = try makeLinkedTrip(stays: [s0, s1, s2, s3])
        let dests = trip.destinations
        #expect(dests.count == 2)
        #expect(dests.map { $0.orderInTrip } == [1, 2])
    }

    @Test("transits returns only .transit stays, sorted by orderInTrip")
    func transitsFilterReturnsOnlyTransitSorted() throws {
        let s0 = makeStay(); s0.category = .transit
        let s1 = makeStay(); s1.category = .destination
        let s2 = makeStay(); s2.category = .destination
        let s3 = makeStay(); s3.category = .home
        let trip = try makeLinkedTrip(stays: [s0, s1, s2, s3])
        let transits = trip.transits
        #expect(transits.count == 1)
        #expect(transits.first?.orderInTrip == 0)
    }

    @Test("orderedStays returns every stay sorted ascending by orderInTrip; nil sorts as 0")
    func orderedStaysSortsAllByOrderInTrip() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: .now)
        context.insert(trip)
        let a = makeStay(); context.insert(a); a.trip = trip; a.orderInTrip = 2
        let b = makeStay(); context.insert(b); b.trip = trip; b.orderInTrip = nil // sorts as 0
        let c = makeStay(); context.insert(c); c.trip = trip; c.orderInTrip = 1
        let ordered = trip.orderedStays
        #expect(ordered.count == 3)
        // nil(0), 1, 2
        #expect(ordered.map { $0.orderInTrip } == [nil, 1, 2])
    }

    /// The comparator `orderedStays` sorted with before keys were read once per stay.
    private static func oldStableStayOrder(_ a: Stay, _ b: Stay) -> Bool {
        if (a.orderInTrip ?? 0) != (b.orderInTrip ?? 0) {
            return (a.orderInTrip ?? 0) < (b.orderInTrip ?? 0)
        }
        if a.startTime != b.startTime { return a.startTime < b.startTime }
        return a.id.uuidString < b.id.uuidString
    }

    @Test("key-copied stay order equals the model comparator's, row for row, ties and UUID twins included")
    func stablySortedMatchesModelComparator() throws {
        // Seeded (SplitMix64) so a failing shape can be replayed.
        struct Seeded: RandomNumberGenerator {
            var state: UInt64
            mutating func next() -> UInt64 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return z ^ (z >> 31)
            }
        }
        var rng = Seeded(state: 20_261_009)
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let ids = (0..<6).map { UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0)")! }
        for size in [0, 1, 2, 3, 5, 12, 19, 20, 21, 33, 64, 150] {
            for _ in 0..<20 {
                // Few distinct orders, times and ids, so ties and exact twins are common.
                var stays: [Stay] = (0..<size).map { _ in
                    let start = base.addingTimeInterval(Double(Int.random(in: 0..<4, using: &rng)) * 3600)
                    let stay = Stay(startTime: start, endTime: start, centroidLatitude: 0,
                                    centroidLongitude: 0, h3IndexRes6: "hex", pingCount: 1,
                                    distanceFromHomeKm: 0, pingIDs: [])
                    stay.orderInTrip = [nil, 0, 1, 2, 2, 3].randomElement(using: &rng)!
                    stay.id = ids.randomElement(using: &rng)!
                    return stay
                }
                stays.shuffle(using: &rng)
                let old = stays.sorted(by: Self.oldStableStayOrder)
                let new = Trip.stablySorted(stays)
                #expect(new.count == old.count)
                #expect(zip(new, old).allSatisfy { $0 === $1 })
            }
        }
        // The accessors on a stored trip: rows in the same order the comparator gives.
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: base)
        context.insert(trip)
        for index in 0..<30 {
            let stay = makeStay()
            context.insert(stay)
            stay.trip = trip
            stay.startTime = base.addingTimeInterval(Double(index % 7) * 60)
            stay.orderInTrip = index % 5 == 0 ? nil : index % 9
            stay.category = [.destination, .transit, .home][index % 3]
        }
        try context.save()
        let fresh = try #require(ModelContext(container).fetch(FetchDescriptor<Trip>()).first)
        let rows = fresh.stays ?? []
        #expect(fresh.orderedStays.map(\.id) == rows.sorted(by: Self.oldStableStayOrder).map(\.id))
        #expect(fresh.destinations.map(\.id)
            == rows.filter { $0.category == .destination }.sorted(by: Self.oldStableStayOrder).map(\.id))
        #expect(fresh.transits.map(\.id)
            == rows.filter { $0.category == .transit }.sorted(by: Self.oldStableStayOrder).map(\.id))
    }

    @Test("fresh Trip (stays == []) → destinations/transits/orderedStays all empty")
    func destinationsEmptyWhenStaysNil() {
        let trip = Trip(startDate: .now)
        #expect(trip.destinations.isEmpty)
        #expect(trip.transits.isEmpty)
        #expect(trip.orderedStays.isEmpty)
    }

    // MARK: - recomputeSummary: destinationSummary

    @Test("destinationSummary uses metro ?? island ?? locality fallback")
    func recomputeSummaryBuildsDestinationSummaryWithMetroFallback() throws {
        let a = makeStay(); a.category = .destination; a.metroName = "Athens"
        let b = makeStay(); b.category = .destination; b.metroName = nil; b.islandName = "Cephalonia"
        let trip = try makeLinkedTrip(stays: [a, b])
        trip.recomputeSummary()
        #expect(trip.destinationSummary == "Athens, Cephalonia")
    }

    @Test("destinationSummary falls to locality, then \"Unknown\" when all three nil")
    func recomputeSummaryFallsToLocalityWhenNoMetroOrIsland() throws {
        let a = makeStay(); a.category = .destination
        a.metroName = nil; a.islandName = nil; a.locality = "Oxford"
        let b = makeStay(); b.category = .destination
        b.metroName = nil; b.islandName = nil; b.locality = nil
        let trip = try makeLinkedTrip(stays: [a, b])
        trip.recomputeSummary()
        #expect(trip.destinationSummary == "Oxford, Unknown")
    }

    @Test("destinationSummary dedupes duplicate names, first-seen order (London-Oxford-London)")
    func recomputeSummaryDedupesDuplicateDestinationNames() throws {
        let a = makeStay(); a.category = .destination; a.metroName = "London"
        let b = makeStay(); b.category = .destination; b.metroName = "Oxford"
        let c = makeStay(); c.category = .destination; c.metroName = "London"
        let trip = try makeLinkedTrip(stays: [a, b, c])
        trip.recomputeSummary()
        #expect(trip.destinationSummary == "London, Oxford")
    }

    @Test("summaryNames gives exactly the list recomputeSummary stores, with and without a temporary home in the store",
          arguments: [false, true])
    func recomputeSummaryEqualsItsNamePass(withTemporaryHome: Bool) throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = Date(timeIntervalSinceReferenceDate: 821_168_000)
        let home = Home(label: "Home", latitude: 37.98, longitude: 23.72,
                        startedAt: start.addingTimeInterval(-400 * 86_400))
        home.locality = "Athens"
        context.insert(home)
        if withTemporaryHome {
            let semester = TemporaryHome(
                label: "Semester", latitude: 50.85, longitude: 4.35,
                startedAt: start.addingTimeInterval(-30 * 86_400),
                endedAt: start.addingTimeInterval(30 * 86_400))
            semester.locality = "Brussels"
            context.insert(semester)
        }
        let trip = Trip(startDate: start)
        trip.endDate = start.addingTimeInterval(3 * 86_400)
        trip.isComplete = true
        context.insert(trip)
        // A port wait named like the home, an hour at the base, then more than three places.
        let visits: [(String, Double)] = [
            ("Athens", 1), ("Brussels", 1), ("Beringen", 10), ("Ieper", 5), ("Knokke-Heist", 2),
        ]
        var begin = start
        for (order, visit) in visits.enumerated() {
            let stay = Stay(startTime: begin, endTime: begin.addingTimeInterval(visit.1 * 3_600),
                            centroidLatitude: 51.04954, centroidLongitude: 5.22606,
                            h3IndexRes6: "hex-\(order)", pingCount: 2, distanceFromHomeKm: 100, pingIDs: [])
            context.insert(stay)
            stay.category = .destination
            stay.metroName = visit.0
            stay.trip = trip
            stay.orderInTrip = order
            begin = begin.addingTimeInterval((visit.1 + 1) * 3_600)
        }
        try context.save()
        TripTitleStore.invalidateHomePlaceIndex()

        let names = try #require(trip.summaryNames())
        #expect(trip.recomputeSummary())
        #expect(names.joined(separator: ", ") == trip.destinationSummary)
        #expect(trip.destinationSummary == (withTemporaryHome
            ? "Beringen, Ieper, Knokke-Heist" : "Beringen, Ieper, Knokke-Heist, Brussels"))
    }

    @Test("a stored summary's components are split on commas, trimmed, with empty ones dropped")
    func summaryComponentsSplitTheStoredList() {
        #expect(Trip.summaryComponents("Athens, Cephalonia,, Lefkada ") == ["Athens", "Cephalonia", "Lefkada"])
        #expect(Trip.summaryComponents("") == [])
    }

    // MARK: - recomputeSummary: countryCodes

    @Test("countryCodes: destination stays only, deduped, order-preserved; transit excluded")
    func recomputeSummaryCountryCodesDestinationOnlyDedupedOrdered() throws {
        let a = makeStay(); a.category = .destination; a.isoCountryCode = "GB"; a.metroName = "London"
        let b = makeStay(); b.category = .destination; b.isoCountryCode = "GB"; b.metroName = "Oxford"
        let c = makeStay(); c.category = .destination; c.isoCountryCode = "FR"; c.metroName = "Paris"
        let t = makeStay(); t.category = .transit; t.isoCountryCode = "DE"
        let trip = try makeLinkedTrip(stays: [a, b, c, t])
        trip.recomputeSummary()
        #expect(trip.countryCodes == "GB,FR")
    }

    @Test("transit + home stays only (no destinations) → empty countryCodes (FRA-layover guard)")
    func recomputeSummaryIgnoresTransitAndHomeForCodes() throws {
        let t = makeStay(); t.category = .transit; t.isoCountryCode = "DE"
        let h = makeStay(); h.category = .home; h.isoCountryCode = "GR"
        let trip = try makeLinkedTrip(stays: [t, h])
        trip.recomputeSummary()
        #expect(trip.countryCodes == "")
    }

    @Test("recomputeSummary is idempotent (no accumulation/drift across two calls)")
    func recomputeSummaryIsIdempotent() throws {
        let a = makeStay(); a.category = .destination; a.metroName = "Athens"; a.isoCountryCode = "GR"
        let b = makeStay(); b.category = .destination; b.metroName = "Paris"; b.isoCountryCode = "FR"
        let trip = try makeLinkedTrip(stays: [a, b])
        trip.recomputeSummary()
        let summary1 = trip.destinationSummary
        let codes1 = trip.countryCodes
        let src1 = trip.sourceRaw
        trip.recomputeSummary()
        #expect(trip.destinationSummary == summary1)
        #expect(trip.countryCodes == codes1)
        #expect(trip.sourceRaw == src1)
    }

    // MARK: - recomputeSummary: sourceRaw derivation

    @Test("all .liveSLC stays → sourceRaw \"liveSLC\"")
    func recomputeSummarySourceAllLiveStaysIsLive() throws {
        let a = makeStay(); a.category = .destination
        let b = makeStay(); b.category = .destination
        let trip = try makeLinkedTrip(stays: [a, b])
        trip.recomputeSummary()
        #expect(trip.sourceRaw == "liveSLC")
    }

    @Test("all .photoImport stays → sourceRaw \"photoImport\" (allSame, non-live first)")
    func recomputeSummarySourceAllImportStaysIsPhotoImport() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: .now)
        context.insert(trip)
        let a = Stay(startTime: .now, endTime: .now, centroidLatitude: 0, centroidLongitude: 0,
                     h3IndexRes6: "hex", pingCount: 1, distanceFromHomeKm: 0, pingIDs: [], source: .photoImport)
        let b = Stay(startTime: .now, endTime: .now, centroidLatitude: 0, centroidLongitude: 0,
                     h3IndexRes6: "hex", pingCount: 1, distanceFromHomeKm: 0, pingIDs: [], source: .photoImport)
        context.insert(a); a.trip = trip; a.orderInTrip = 0; a.category = .destination
        context.insert(b); b.trip = trip; b.orderInTrip = 1; b.category = .destination
        trip.recomputeSummary()
        #expect(trip.sourceRaw == "photoImport")
    }

    @Test("mixed .liveSLC + .photoImport stays → sourceRaw \"merged\"")
    func recomputeSummarySourceMixedStaysIsMerged() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: .now)
        context.insert(trip)
        let a = Stay(startTime: .now, endTime: .now, centroidLatitude: 0, centroidLongitude: 0,
                     h3IndexRes6: "hex", pingCount: 1, distanceFromHomeKm: 0, pingIDs: [], source: .liveSLC)
        let b = Stay(startTime: .now, endTime: .now, centroidLatitude: 0, centroidLongitude: 0,
                     h3IndexRes6: "hex", pingCount: 1, distanceFromHomeKm: 0, pingIDs: [], source: .photoImport)
        context.insert(a); a.trip = trip; a.orderInTrip = 0; a.category = .destination
        context.insert(b); b.trip = trip; b.orderInTrip = 1; b.category = .destination
        trip.recomputeSummary()
        #expect(trip.sourceRaw == "merged")
    }

    @Test("empty trip leaves sourceRaw unchanged (allStays.first is nil → body skipped)")
    func recomputeSummaryEmptyTripLeavesSourceUnchanged() {
        let trip = Trip(startDate: .now)
        trip.sourceRaw = "photoImport"
        trip.recomputeSummary()
        #expect(trip.sourceRaw == "photoImport")
    }

    // MARK: - source accessor

    @Test("trip.source setter writes raw; unknown raw decodes to .liveSLC")
    func tripSourceSetterAndUnknownRawFallback() {
        let trip = Trip(startDate: .now)
        trip.source = .merged
        #expect(trip.sourceRaw == "merged")
        trip.sourceRaw = "future"
        #expect(trip.source == .liveSLC)
    }

    // MARK: - recomputeSummary: home places + significance (2026-09)

    @Test("destinationSummary drops home-named destinations when the store knows the home")
    func recomputeSummaryExcludesHomePlaces() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: .now)
        context.insert(trip)
        // A home stay in the same era: its metro is what "home" is called.
        let home = makeStay(); home.category = .home; home.metroName = "Athens"; home.locality = "Palaió Fáliro"
        context.insert(home)
        let port = makeStay(); port.category = .destination; port.metroName = "Athens"; port.locality = "Agia Kyriakií Spáton"
        // Only the home-named stay carries a code, so the code proves it still counts.
        port.isoCountryCode = "GR"
        let island = makeStay(); island.category = .destination; island.islandName = "Aegina"
        for (i, stay) in [port, island].enumerated() {
            context.insert(stay); stay.trip = trip; stay.orderInTrip = i
        }

        trip.recomputeSummary()
        #expect(trip.destinationSummary == "Aegina")
        // Country codes still count every destination stay.
        #expect(trip.countryCodes == "GR")
    }

    @Test("a trip entirely inside the home area keeps its name in the summary")
    func recomputeSummaryKeepsHomeOnlyTrip() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: .now)
        context.insert(trip)
        let home = makeStay(); home.category = .home; home.metroName = "Athens"
        context.insert(home)
        let stay = makeStay(); stay.category = .destination; stay.metroName = "Athens"; stay.locality = "Agios Dimitrios"
        context.insert(stay); stay.trip = trip; stay.orderInTrip = 0

        trip.recomputeSummary()
        #expect(trip.destinationSummary == "Athens")
    }

    @Test("with more than three destinations the summary leads with the three where the most time was spent")
    func recomputeSummaryLeadsWithSignificantPlaces() throws {
        let specs: [(String, Int)] = [
            ("Renens", 2_000), ("Riehen", 300), ("Aarburg", 200),
            ("Bern", 600), ("Köniz", 1_500), ("Ajaccio", 400), ("Bort-les-Orgues", 350),
        ]
        let stays = specs.map { name, minutes -> Stay in
            let stay = makeStay(); stay.category = .destination
            stay.metroName = name; stay.durationMinutes = minutes
            return stay
        }
        let trip = try makeLinkedTrip(stays: stays)
        trip.recomputeSummary()
        #expect(trip.destinationSummary == "Renens, Bern, Köniz, Riehen, Aarburg, Ajaccio, Bort-les-Orgues")
        #expect(Trip.curatedJoin(trip.destinationSummary) == "Renens, Bern & Köniz")
    }

    // MARK: - TripTitleStore.homePlaceNames

    @Test("homePlaceNames: era-bounded home stays plus overlapping Home rows, normalized")
    func homePlaceNamesAreEraBoundedAndNormalized() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let now = Date.now
        let recent = makeStay(); recent.category = .home; recent.metroName = "Köniz"
        recent.startTime = now.addingTimeInterval(-30 * 86_400)
        let ancient = makeStay(); ancient.category = .home; ancient.metroName = "London"
        ancient.startTime = now.addingTimeInterval(-3 * 365 * 86_400)
        let destination = makeStay(); destination.category = .destination; destination.metroName = "Paris"
        for stay in [recent, ancient, destination] { context.insert(stay) }
        let current = Home(label: "Home", latitude: 0, longitude: 0)
        current.locality = "Παλαιό Φάληρο"
        current.startedAt = now.addingTimeInterval(-86_400)
        context.insert(current)
        let former = Home(label: "Old", latitude: 0, longitude: 0)
        former.locality = "Manchester"
        former.startedAt = now.addingTimeInterval(-5 * 365 * 86_400)
        former.endedAt = now.addingTimeInterval(-4 * 365 * 86_400)
        context.insert(former)
        // A home given up 120 days before the trip: its era does not
        // overlap the trip, so "Leeds" is a destination again.
        let recentlyLeft = Home(label: "Recent", latitude: 0, longitude: 0)
        recentlyLeft.locality = "Leeds"
        recentlyLeft.startedAt = now.addingTimeInterval(-400 * 86_400)
        recentlyLeft.endedAt = now.addingTimeInterval(-120 * 86_400)
        context.insert(recentlyLeft)

        let names = try TripTitleStore.homePlaceNames(tripStart: now, tripEnd: now, in: context)
        #expect(names.contains("koniz"))
        #expect(names.contains("palaio phalero"))
        #expect(!names.contains("london"))
        #expect(!names.contains("manchester"))
        #expect(!names.contains("leeds"))
        #expect(!names.contains("paris"))
    }

    @Test("creating an in-memory container clears cached home place names")
    func inMemoryContainerFactoryClearsHomePlaceIndex() throws {
        let firstContainer = try TestSupport.makeInMemoryContainer()
        let firstContext = ModelContext(firstContainer)
        let now = Date.now
        #expect(try TripTitleStore.homePlaceNames(
            tripStart: now, tripEnd: now, in: firstContext).isEmpty)

        let athens = makeStay()
        athens.category = .home
        athens.metroName = "Athens"
        firstContext.insert(athens)
        try firstContext.save()

        _ = try TestSupport.makeInMemoryContainer()

        let names = try TripTitleStore.homePlaceNames(
            tripStart: now, tripEnd: now, in: firstContext)
        #expect(names.contains("athens"))
    }

    // Another context could refill the shared cache with
    // the rows from before a write unit's unsaved changes.
    @Test("a pinned home-place snapshot is what every read gets while it is pinned, even after another context refilled the cache; an uncached read sees its context's unsaved home stay; outside the pin reads go through the cache as before")
    func pinnedHomePlaceIndexWinsOverTheSharedCache() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let unit = ModelContext(container)
        let now = Date.now
        let athens = makeStay()
        athens.category = .home
        athens.metroName = "Athens"
        unit.insert(athens)
        try unit.save()
        // A stay the unit settled home and has not saved yet.
        let ixelles = makeStay()
        ixelles.category = .home
        ixelles.metroName = "Ixelles"
        unit.insert(ixelles)

        let snapshot = try TripTitleStore.HomePlaceIndex.uncached(for: unit)
        #expect(Set(snapshot.stays.map { $0.name }) == ["athens", "ixelles"])

        // Another context fills the shared cache from the committed rows.
        let other = ModelContext(container)
        TripTitleStore.invalidateHomePlaceIndex()
        let refilled = try TripTitleStore.HomePlaceIndex.current(for: other)
        #expect(Set(refilled.stays.map { $0.name }) == ["athens"])

        try TripTitleStore.HomePlaceIndex.$pinned.withValue(snapshot) {
            let pinned = try TripTitleStore.HomePlaceIndex.current(for: other)
            #expect(Set(pinned.stays.map { $0.name }) == ["athens", "ixelles"])
            let names = try TripTitleStore.homePlaceNames(tripStart: now, tripEnd: now, in: other)
            #expect(names.contains("ixelles"))
        }

        let unpinned = try TripTitleStore.HomePlaceIndex.current(for: other)
        #expect(Set(unpinned.stays.map { $0.name }) == ["athens"])
        let names = try TripTitleStore.homePlaceNames(tripStart: now, tripEnd: now, in: other)
        #expect(!names.contains("ixelles"))
    }

    @Test("normalizedPlaceName folds script, diacritics, case and whitespace")
    func normalizedPlaceNameFolds() {
        #expect(TripTitleStore.normalizedPlaceName("Köniz ") == "koniz")
        #expect(TripTitleStore.normalizedPlaceName("New   York") == "new york")
        #expect(TripTitleStore.normalizedPlaceName("Αθήνα") == "athena")
    }

    // MARK: - Departure label

    @Test("the detail's departure label reloads when an input moves under a kept trip id")
    func departureLabelKeyFollowsItsInputs() {
        let tracker = StoreChangeTracker(forTesting: ())
        let tripID = UUID()
        let start = Date(timeIntervalSince1970: 1_778_662_800)  // 2026-05-13 09:00 UTC
        func key(_ startDate: Date = start) -> TripDetailView.DepartureLabelTaskKey {
            TripDetailView.departureLabelTaskKey(tripID: tripID, startDate: startDate, tracker: tracker)
        }
        // Reconciliation keeps ids while homes, temporary homes, stays and trips move.
        for change in [StoreChange.home, .temporaryHome, .stay, .trip] {
            let before = key()
            tracker.applyNowForTesting(change)
            #expect(key() != before, "a \(change.rawValue) change reloads the label")
        }
        let settled = key()
        tracker.applyNowForTesting([.hexVisit, .locationPing, .plannedTrip])
        #expect(key() == settled, "unrelated changes do not reload it")
        #expect(key(start.addingTimeInterval(3_600)) != settled, "a moved start reloads it")
    }

    @Test("a renamed temporary home renames a kept trip's departure label on a fresh read")
    func departureLabelReadsTheCurrentBase() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func at(_ month: Int, _ day: Int, _ hour: Int = 12, year: Int = 2026) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let home = Home(label: "Home", latitude: 37.9838, longitude: 23.7275, startedAt: at(9, 3, year: 2025))
        context.insert(home)
        let base = TemporaryHome(
            label: "Erasmus", latitude: 50.8503, longitude: 4.3517, startedAt: at(5, 4, 0))
        base.locality = "Brussels"
        base.timeZoneIdentifier = "UTC"
        context.insert(base)
        let homeStay = Stay(
            startTime: at(5, 5, 10), endTime: at(5, 12, 18),
            centroidLatitude: 50.8503, centroidLongitude: 4.3517,
            h3IndexRes6: "", pingCount: 4, distanceFromHomeKm: 0, pingIDs: [],
            timeZoneIdentifier: "UTC")
        homeStay.category = .home
        homeStay.temporaryHomeID = base.id
        context.insert(homeStay)
        try context.save()

        let tripStart = at(5, 13, 9)
        #expect(try TemporaryHomeCards.departurePlaceName(tripStart: tripStart, container: container) == "Brussels")
        // The stored name refresh renames the place; the trip and its id stay.
        base.locality = "Ixelles"
        try context.save()
        #expect(try TemporaryHomeCards.departurePlaceName(tripStart: tripStart, container: container) == "Ixelles")
    }

    // MARK: - Stay category menu

    @Test("the stay category menu offers Automatic only for a stay the user set")
    func automaticOnlyForAUserSetStay() {
        #expect(TripDetailView.offersAutomaticCategory(userOverridden: true))
        #expect(!TripDetailView.offersAutomaticCategory(userOverridden: false))
        #expect(TripDetailView.automaticCategoryTitle == "Automatic")
    }
}
