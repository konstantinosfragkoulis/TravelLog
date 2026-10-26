//
//  P09aRegressionTests.swift
//  TravelLogTests
//
//  Regression tests for the calendar, Trips list, search and intent fixes
//  of package P09a.
//

import EventKit
import Foundation
import SwiftData
import Testing
@testable import TravelLog

// MARK: - CAL-003: temporary-home dates in upcoming journeys

@MainActor
@Suite("Upcoming journeys read a temporary home only inside its dates")
struct PlannedJourneyTemporaryHomeDatesTests {

    private let now = Date(timeIntervalSince1970: 1_824_796_800)

    private func days(_ count: Double) -> Date { now.addingTimeInterval(count * 86_400) }

    private func leg(_ title: String, from start: Double, to end: Double) -> PlannedTripChainer.Leg {
        PlannedTripChainer.Leg(id: UUID(), title: title, startDate: days(start), endDate: days(end),
                               confidence: .high)
    }

    /// A holiday to Brussels then Paris, inside the 48-hour chaining gap.
    private var holiday: [PlannedTripChainer.Leg] {
        [leg("Trip to Brussels", from: 2, to: 4), leg("Trip to Paris", from: 4.5, to: 6)]
    }

    private func names(temporaryFrom start: Double, to end: Double?) -> PlannedTripChainer.HomeNames {
        PlannedTripChainer.HomeNames(
            permanent: ["Home", "Athens"],
            temporary: [.init(names: ["Erasmus", "Brussels"], startedAt: days(start), endedAt: end.map { days($0) })])
    }

    @Test("a temporary home that starts after the holiday leaves its city a destination")
    func futureTemporaryHomeKeepsEarlierHoliday() {
        let journeys = PlannedTripChainer.journeys(from: holiday, homeNames: names(temporaryFrom: 30, to: 120))
        #expect(journeys.count == 1)
        #expect(journeys.first?.destinations == ["Brussels", "Paris"])
    }

    @Test("a temporary home that ends before the holiday leaves its city a destination")
    func endedTemporaryHomeKeepsLaterHoliday() {
        let journeys = PlannedTripChainer.journeys(from: holiday, homeNames: names(temporaryFrom: -60, to: 1))
        #expect(journeys.count == 1)
        #expect(journeys.first?.destinations == ["Brussels", "Paris"])
    }

    @Test("a temporary home active over the legs still closes the chain at its city")
    func activeTemporaryHomeStillClosesTheChain() {
        for homeNames in [names(temporaryFrom: -10, to: nil), names(temporaryFrom: 3, to: 40)] {
            let journeys = PlannedTripChainer.journeys(from: holiday, homeNames: homeNames)
            #expect(journeys.count == 2)
            #expect(journeys.map(\.destinations) == [[], ["Paris"]])
        }
    }

    @Test("an all-day leg that ends at the start's midnight lies wholly before the dates")
    func legEndingAtStartIsOutside() {
        let dated = PlannedTripChainer.HomeNames.Dated(names: ["Brussels"], startedAt: days(4), endedAt: days(9))
        #expect(!dated.overlaps(start: days(2), end: days(4)))
        #expect(dated.overlaps(start: days(2), end: days(4.01)))
        #expect(dated.overlaps(start: days(4), end: days(4)))
        #expect(dated.overlaps(start: days(9), end: days(10)))
        #expect(!dated.overlaps(start: days(9.01), end: days(10)))
    }

    @Test("the widget and intent inputs carry the temporary home's dates")
    func storeInputsCarryDates() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let home = Home(label: "Home", latitude: 44.3, longitude: 12.9, startedAt: days(-1_000))
        home.locality = "Athens"
        context.insert(home)
        let temporary = TemporaryHome(label: "Erasmus", latitude: 45.3, longitude: 13.9,
                                      startedAt: days(30), endedAt: days(120))
        temporary.locality = "Brussels"
        context.insert(temporary)
        for (title, start, end) in [("Trip to Brussels", 2.0, 4.0), ("Trip to Paris", 4.5, 6.0)] {
            let row = PlannedTrip(eventExternalIdentifier: nil, eventLocalIdentifier: title, title: title,
                                  startDate: days(start), endDate: days(end), isAllDay: false, locationText: nil)
            row.confidence = .high
            context.insert(row)
        }
        try context.save()

        let inputs = try PlannedTripChainer.storeInputs(in: context, now: now)
        #expect(inputs.homeNames.temporary.map(\.startedAt) == [days(30)])
        let journey = try #require(PlannedTripChainer.nextJourney(
            from: inputs.legs, homeNames: inputs.homeNames, now: now,
            ongoingTripStartDates: inputs.ongoingTripStartDates))
        #expect(journey.destinations == ["Brussels", "Paris"])
    }
}

// MARK: - CAL-001: stale retirement needs this device's own sight of the source

@MainActor
@Suite(.serialized, IsolatedCalendarDefaults())
struct PlannedTripSourceAuthorityTests {

    private typealias Choice = CalendarEnricher.CalendarChoice

    private let travel = Choice(id: "A", title: "Travel", accountTitle: "Google")
    private let work = Choice(id: "B", title: "Work", accountTitle: "Exchange")

    private var defaults: UserDefaults { IsolatedCalendarDefaults.current }

    private func withLiveCalendars(_ live: [Choice], _ body: () async -> Void) async {
        await CalendarEnricher.TestScope.$authorizationStatus.withValue(.fullAccess) {
            await CalendarEnricher.TestScope.$liveCalendars.withValue(live) {
                await body()
            }
        }
    }

    private func count(_ container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(FetchDescriptor<PlannedTrip>())
    }

    private func select(_ ids: [String]?) {
        defaults.set(true, forKey: CalendarEnricher.thinHistoryProbeCompletedKey)
        if let ids {
            defaults.set(ids, forKey: CalendarEnricher.selectedCalendarIDsKey)
        } else {
            defaults.removeObject(forKey: CalendarEnricher.selectedCalendarIDsKey)
            defaults.removeObject(forKey: CalendarEnricher.selectedCalendarsKey)
        }
    }

    @Test("another device's plan survives a scan of calendars this device never saw it in")
    func unseenSourceKeepsTheRow() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let start = Date.now.addingTimeInterval(20 * 86_400)
        let row = PlannedTrip(eventExternalIdentifier: "device-a-event", eventLocalIdentifier: "device-a-event",
                              title: "Trip to Rome", startDate: start, endDate: start.addingTimeInterval(3 * 86_400),
                              isAllDay: false, locationText: nil)
        row.lastSeenAt = Date.now.addingTimeInterval(-10 * 86_400)
        context.insert(row)
        try context.save()
        let enricher = CalendarEnricher(modelContainer: container)

        for selection in [["B"], nil] as [[String]?] {
            select(selection)
            await withLiveCalendars([travel, work]) { await enricher.scanUpcomingTrips() }
            #expect(try count(container) == 1)
        }
    }

    @Test("a plan this device saw in a calendar retires only from a scan that reads that calendar")
    func ownSourceRetiresOnlyWhenRead() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let start = Date.now.addingTimeInterval(20 * 86_400)
        let event = CalendarEventSnapshot(
            externalIdentifier: "ext-p09a", localIdentifier: "local-p09a", title: "Trip to Rome",
            notes: nil, locationText: nil, startDate: start, endDate: start.addingTimeInterval(3 * 86_400),
            isAllDay: false, hasRecurrenceRules: false, isDetached: false,
            calendarTitle: "Travel", calendarKind: .caldav, calendarIdentifier: "A")
        let detection = PlannedTripDetection(snapshot: event, confidence: .high, signals: ["bookingTitle"])
        #expect(await enricher.applyScan(detections: [detection], now: Date.now.addingTimeInterval(-10 * 86_400),
                                         readCalendarIDs: ["A"]))
        #expect(try count(container) == 1)

        // Calendar A is no longer read here: no evidence about its event.
        select(["B"])
        await withLiveCalendars([travel, work]) { await enricher.scanUpcomingTrips() }
        #expect(try count(container) == 1)

        // A scan that reads A and does not find the event retires the row.
        select(["A"])
        await withLiveCalendars([travel, work]) { await enricher.scanUpcomingTrips() }
        #expect(try count(container) == 0)
        #expect(defaults.dictionary(forKey: CalendarEnricher.observedEventSourcesKey)?.isEmpty ?? true)
    }

    @Test("the ledger decides authority from this device's own sightings")
    func ledgerDecision() {
        let key = "event|1"
        let observed = [CalendarEnricher.sourceLedgerDigest(key): CalendarEnricher.sourceLedgerDigest("A")]
        let readA = Set(["A"].map(CalendarEnricher.sourceLedgerDigest))
        let readB = Set(["B"].map(CalendarEnricher.sourceLedgerDigest))
        #expect(CalendarEnricher.scanReadsSource(of: key, observed: observed, readDigests: readA))
        #expect(!CalendarEnricher.scanReadsSource(of: key, observed: observed, readDigests: readB))
        #expect(!CalendarEnricher.scanReadsSource(of: "event|2", observed: observed, readDigests: readA))
        #expect(CalendarEnricher.scanReadsSource(of: key, observed: observed, readDigests: nil))
        let unknownCalendar = [CalendarEnricher.sourceLedgerDigest(key): ""]
        #expect(!CalendarEnricher.scanReadsSource(of: key, observed: unknownCalendar, readDigests: readA))
    }
}

// MARK: - CONS-001: retained year caches follow the viewing zone

@MainActor
@Suite("The Trips year filter and picker follow a zone change")
struct TripsListYearZoneTests {

    /// 2026-12-31T23:30Z: 2026 in Los Angeles, 2027 in Athens.
    private let boundary = Date(timeIntervalSince1970: 1_798_759_800)

    private func gregorian(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func sliceKey(zone: String) -> TripsListView.SliceRecomputeKey {
        var filters = TripFilters()
        filters.years = [2026]
        return TripsListView.SliceRecomputeKey(
            storeToken: 7, debouncedQuery: "", searchActive: false, filters: filters,
            sortRaw: "dateNewest", pinnedIDs: [], photoGeneration: 0, aiSuccessIDs: [],
            searchGeneration: 0, searchStayToken: 0, allowsTrailingPartial: false,
            searchClock: TripsListView.sliceSearchClock(
                query: "", clock: TripsListView.makeSearchClock(now: boundary, timeZone: TimeZone(identifier: zone)!)),
            yearZoneID: zone)
    }

    @Test("an idle list's slice key changes with the zone, so year filters rerun")
    func sliceKeyCarriesTheZone() {
        #expect(sliceKey(zone: "America/Los_Angeles") != sliceKey(zone: "Europe/Athens"))
        #expect(sliceKey(zone: "Europe/Athens") == sliceKey(zone: "Europe/Athens"))
    }

    @Test("the year picker rebuilds on a zone change with no trip write")
    func pickerKeyCarriesTheZone() {
        let losAngeles = TripsListView.YearPickerKey(tripToken: 7, yearZoneID: "America/Los_Angeles")
        let athens = TripsListView.YearPickerKey(tripToken: 7, yearZoneID: "Europe/Athens")
        #expect(losAngeles != athens)
        #expect(TripsListView.computeAvailableYears(
            startDates: [boundary], calendar: gregorian("America/Los_Angeles")) == [2026])
        #expect(TripsListView.computeAvailableYears(
            startDates: [boundary], calendar: gregorian("Europe/Athens")) == [2027])
    }
}

// MARK: - TIME-003: year sections and totals use the Gregorian year

@MainActor
@Suite("Trips year sections and totals read Gregorian years")
struct TripsListGregorianYearTests {

    /// Mid-year starts: no zone moves them across a year boundary.
    private func trips(in context: ModelContext) -> [Trip] {
        [(2026, 6), (1996, 6)].map { year, month in
            var parts = DateComponents(year: year, month: month, day: 15, hour: 12)
            parts.timeZone = TimeZone(identifier: "UTC")
            let trip = Trip(startDate: Calendar(identifier: .gregorian).date(from: parts)!)
            trip.endDate = trip.startDate.addingTimeInterval(2 * 86_400)
            trip.isComplete = true
            context.insert(trip)
            return trip
        }
    }

    @Test("by default each Gregorian year is its own section with its own totals")
    func defaultsAreGregorian() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let trips = trips(in: context)
        #expect(TripsListView.groupedByYear(trips).map(\.year) == [2026, 1996])
        let totals = TripsListView.computeYearTotals(trips, dayLabels: [:])
        #expect(Set(totals.keys) == [2026, 1996])
        #expect(totals[2026]?.trips == 1)
        #expect(Set(TripsListView.computeAvailableYears(startDates: trips.map(\.startDate))) == Set(totals.keys))
    }

    @Test("an era calendar would pool Heisei 8 and Reiwa 8, which is why the default is Gregorian")
    func eraCalendarPoolsYears() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = TimeZone(identifier: "UTC")!
        let groups = TripsListView.groupedByYear(trips(in: context), calendar: japanese)
        #expect(groups.map(\.year) == [8])
        #expect(groups.first?.trips.count == 2)
    }
}

// MARK: - SEARCH-004: Siri never presents a partial match as a result

@MainActor
@Suite("Search Trips keeps partial matches apart from results")
struct SearchTripsPartialMatchTests {

    private func seed(_ name: String, year: Int, in context: ModelContext) -> Trip {
        var parts = DateComponents(year: year, month: 6, day: 10, hour: 12)
        parts.timeZone = TimeZone(identifier: "UTC")
        let trip = Trip(startDate: Calendar(identifier: .gregorian).date(from: parts)!)
        trip.endDate = trip.startDate.addingTimeInterval(4 * 86_400)
        trip.isComplete = true
        trip.customName = "\(name) Weekend"
        trip.destinationSummary = name
        context.insert(trip)
        return trip
    }

    @Test("a place with a year no trip has is a labeled suggestion, never a result")
    func partialIsASuggestion() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let paris = seed("Paris", year: 2023, in: context)
        _ = seed("Rome", year: 2024, in: context)
        try context.save()

        let ranked = try TripIntentSearch.rankedLocalMatches(query: "paris 2024", container: container, languageTag: "en")
        #expect(ranked.map(\.strength) == [.partial])
        let outcome = TripIntentSearch.outcome(local: ranked)
        #expect(outcome.matches.isEmpty)
        #expect(outcome.suggestions.map(\.tripID) == [paris.id])

        let message = SearchTripsIntent.message(for: outcome, query: "paris 2024")
        #expect(message.contains("Paris Weekend"))
        #expect(message != SearchTripsIntent.message(
            for: TripIntentSearch.Outcome(matches: outcome.suggestions), query: "paris 2024"))
        #expect(message != SearchTripsIntent.message(for: TripIntentSearch.Outcome(), query: "paris 2024"))
    }

    @Test("an exact query still matches, and fallback trips replace suggestions")
    func exactAndFallbackStayResults() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let paris = seed("Paris", year: 2023, in: context)
        let rome = seed("Rome", year: 2024, in: context)
        try context.save()

        let exact = TripIntentSearch.outcome(local: try TripIntentSearch.rankedLocalMatches(
            query: "paris 2023", container: container, languageTag: "en"))
        #expect(exact.matches.map(\.tripID) == [paris.id])
        #expect(exact.suggestions.isEmpty)

        let partial = try TripIntentSearch.rankedLocalMatches(query: "paris 2024", container: container, languageTag: "en")
        let fallback = TripEntityFetcher.entity(from: rome, languageTag: "en")
        let answered = TripIntentSearch.outcome(local: partial, fallback: [fallback])
        #expect(answered.matches.map(\.tripID) == [rome.id])
        #expect(answered.suggestions.isEmpty)
        #expect(TripIntentSearch.outcome(local: partial, fallback: []).matches.isEmpty)
        #expect(TripIntentSearch.outcome(local: [], fallback: nil).suggestions.isEmpty)
    }
}

// MARK: - SEARCH-003: a search result opens the row it matched

@MainActor
@Suite("Trip entities keep the physical row they were built from")
struct TripEntityRowIdentityTests {

    private let start = Date(timeIntervalSinceReferenceDate: 790_000_000)

    @discardableResult
    private func trip(_ name: String, id: UUID, stays: Int, in context: ModelContext) -> Trip {
        let trip = Trip(startDate: start)
        trip.id = id
        trip.endDate = start.addingTimeInterval(3 * 86_400)
        trip.isComplete = true
        trip.customName = name
        context.insert(trip)
        for index in 0..<stays {
            let stay = Stay(startTime: start.addingTimeInterval(Double(index) * 86_400),
                            endTime: start.addingTimeInterval(Double(index) * 86_400 + 43_200),
                            centroidLatitude: 44.3, centroidLongitude: 12.9, h3IndexRes6: "",
                            pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
            context.insert(stay)
            stay.category = .destination
            stay.orderInTrip = index
            stay.trip = trip
        }
        return trip
    }

    @Test("a search result for one of two divergent twins resolves to that twin, also after serialization")
    func searchResultKeepsItsRow() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let shared = UUID()
        trip("Mountain Week", id: shared, stays: 0, in: context)
        let harbor = trip("Harbor Week", id: shared, stays: 2, in: context)
        trip("Mountain Week", id: shared, stays: 1, in: context)
        try context.save()

        let result = try #require(try TripIntentSearch.localMatches(query: "harbor", container: container, languageTag: "en").first)
        #expect(result.title == "Harbor Week")
        #expect(result.id.row == harbor.persistentModelID)

        let restored = try #require(TripEntityID.entityIdentifier(for: result.id.entityIdentifierString))
        #expect(restored.tripID == shared)
        #expect(restored.row != nil)
        #expect(TripEntityID.entityIdentifier(for: shared.uuidString) == TripEntityID(tripID: shared))
        #expect(TripEntityID.entityIdentifier(for: "\(shared.uuidString)~not-a-row") == nil)
        let resolved = try TripEntityFetcher.entities(for: [restored], container: container)
        #expect(resolved.map(\.title) == ["Harbor Week"])

        let rows = try context.fetch(FetchDescriptor<Trip>())
        #expect(TripEntityFetcher.resolve(restored, among: rows)?.persistentModelID == harbor.persistentModelID)
        // The UUID alone is ambiguous: the populated twins disagree.
        #expect(try TripEntityFetcher.entities(for: [shared], container: container).isEmpty)
        #expect(TripEntityFetcher.resolve(TripEntityID(tripID: shared), among: rows) == nil)
    }

    @Test("a row that is gone resolves to nothing, never to its twin")
    func deletedRowRefusesSubstitution() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let shared = UUID()
        trip("Mountain Week", id: shared, stays: 1, in: context)
        let harbor = trip("Harbor Week", id: shared, stays: 2, in: context)
        try context.save()
        let identity = TripEntityID(tripID: shared, row: harbor.persistentModelID)
        context.delete(harbor)
        try context.save()

        #expect(try TripEntityFetcher.entities(for: [identity], container: container).isEmpty)
        // With one row left, the UUID alone opens it.
        #expect(try TripEntityFetcher.entities(for: [shared], container: container).map(\.title) == ["Mountain Week"])
    }

    @Test("a UUID-only route opens the only populated twin, and one of identical twins")
    func uuidRouteRepresentative() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let shellID = UUID()
        trip("Harbor Week", id: shellID, stays: 0, in: context)
        let populated = trip("Harbor Week", id: shellID, stays: 2, in: context)
        let twinID = UUID()
        trip("Lake Days", id: twinID, stays: 0, in: context)
        trip("Lake Days", id: twinID, stays: 0, in: context)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<Trip>())
        #expect(TripEntityFetcher.representative(of: rows.filter { $0.id == shellID })?.persistentModelID
                == populated.persistentModelID)
        let identical = rows.filter { $0.id == twinID }
        let chosen = try #require(TripEntityFetcher.representative(of: identical))
        #expect(TripEntityFetcher.representative(of: identical.reversed())?.persistentModelID == chosen.persistentModelID)
        #expect(try TripEntityFetcher.entities(for: [twinID], container: container).count == 1)
    }

    @Test("Spotlight lists divergent twins one row each, and agreeing twins once")
    func allEntitiesListsDivergentRows() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let shared = UUID()
        trip("Mountain Week", id: shared, stays: 1, in: context)
        trip("Harbor Week", id: shared, stays: 2, in: context)
        try context.save()

        let all = try TripEntityFetcher.allEntities(container: container)
        #expect(Set(all.map(\.title)) == ["Mountain Week", "Harbor Week"])
        #expect(all.allSatisfy { $0.id.row != nil && $0.tripID == shared })
        for entity in all {
            #expect(try TripEntityFetcher.entities(for: [entity.id], container: container).map(\.title) == [entity.title])
        }
    }
}

// MARK: - CAL-004: the thin-history tip names only an account it probed

@Suite("The thin-history tip judges each selected account by its own calendars")
struct ThinHistoryAttributionTests {

    private typealias Source = CalendarEnricher.ThinHistorySource

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let exchange = Source(id: "src-exchange", title: "Work Exchange")
    private let google = Source(id: "src-google", title: "Google")

    /// Calendar name to its sync-capped account (nil: local or iCloud).
    private var accounts: [String: Source] {
        ["work": exchange, "travel": google, "travel-2": google]
    }

    private func account(for selected: [String], earliest: [String: Date]) -> (String?, [[String]]) {
        var probed: [[String]] = []
        let groups = CalendarEnricher.syncCappedGroups(selected) { accounts[$0] }
        let name = CalendarEnricher.thinHistoryAccount(groups, now: now) { calendars in
            probed.append(calendars)
            return calendars.compactMap { earliest[$0] }.min()
        }
        return (name, probed)
    }

    @Test("a selected local calendar with recent events names no excluded account")
    func localSelectionNamesNothing() {
        let (name, probed) = account(for: ["home"], earliest: ["home": now.addingTimeInterval(-86_400)])
        #expect(name == nil)
        #expect(probed.isEmpty)
    }

    @Test("a selected account is named from its own recent history only")
    func selectedAccountJudgedAlone() {
        let recent = now.addingTimeInterval(-10 * 86_400)
        let deep = now.addingTimeInterval(-900 * 86_400)
        let (name, probed) = account(
            for: ["home", "travel", "travel-2"], earliest: ["home": deep, "travel": recent, "travel-2": recent])
        #expect(name == "Google")
        #expect(probed == [["travel", "travel-2"]])

        let deepGoogle = account(for: ["travel", "work"], earliest: ["travel": deep, "work": recent])
        #expect(deepGoogle.0 == "Work Exchange")
        #expect(deepGoogle.1 == [["travel"], ["work"]])

        #expect(account(for: ["travel", "work"], earliest: ["travel": deep, "work": deep]).0 == nil)
        #expect(account(for: ["travel"], earliest: [:]).0 == nil)
    }
}

// MARK: - LIMIT-002: sparse search length buckets

@MainActor
@Suite("Search length buckets store only occupied lengths, in ascending order")
struct SearchLengthBucketTests {

    @Test("ranges visit occupied lengths ascending and absent lengths read empty")
    func sparseRanges() {
        let buckets = TripSearchIndex.LengthBuckets([1_024: [1], 3: [0], 7: [2, 3], 8: [4]])
        #expect(buckets.buckets(from: 0).map { $0.0 } == [3, 7, 8, 1_024])
        #expect(buckets.buckets(from: 0).map { $0.1 } == [[0], [2, 3], [4], [1]])
        #expect(buckets.buckets(in: 4...8).map { $0.0 } == [7, 8])
        #expect(buckets.buckets(in: 9...1_023).map { $0.0 }.isEmpty)
        #expect(buckets.buckets(from: 8).map { $0.0 } == [8, 1_024])
        #expect(buckets.buckets(from: 2_000).map { $0.0 }.isEmpty)
        #expect(buckets[1_024] == [1])
        #expect(buckets[500].isEmpty)
        #expect(TripSearchIndex.LengthBuckets([:]).buckets(from: 0).map { $0.0 }.isEmpty)
    }

    @Test("one very long title word adds one bucket, and the trip is still found")
    func longTitleWord() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let trip = Trip(startDate: Date(timeIntervalSinceReferenceDate: 790_000_000))
        trip.endDate = trip.startDate.addingTimeInterval(2 * 86_400)
        trip.isComplete = true
        trip.customName = "Lake " + String(repeating: "x", count: 1_000)
        context.insert(trip)
        try context.save()

        let index = TripSearchIndex(documents: [TripSearchDocument.make(from: trip, languageTag: "en")])
        let lengths = index.idsByLength.buckets(from: 0).map { $0.0 }
        #expect(lengths == lengths.sorted())
        #expect(lengths.count <= index.vocabulary.count)
        #expect((lengths.last ?? 0) >= 1_000)
        let matches = TripQueryParser.searchTrips(index: index, query: "lake", allowsTrailingPartial: false, languageTag: "en")
        #expect(matches.map(\.documentIndex) == [0])
    }
}

// MARK: - SEARCH-005: a failed redonation leaves no stale persisted token

/// A Spotlight index whose content, index failures and index calls the test controls.
private final class RedonationIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var entities: [TripEntity] = []
    private var failIndex = false
    private var deleteFails = false
    private var indexCalls = 0

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func set(_ value: [TripEntity], failIndex: Bool = false, failDelete: Bool = false) {
        locked { entities = value; self.failIndex = failIndex; deleteFails = failDelete }
    }

    var indexCount: Int { locked { indexCalls } }

    var seam: SpotlightIndexer.Operations {
        SpotlightIndexer.Operations(
            fetchEntities: { self.locked { self.entities } },
            deleteAllEntities: {
                if self.locked({ self.deleteFails }) { throw CocoaError(.fileWriteUnknown) }
            },
            indexEntities: { _ in
                let fails = self.locked { () -> Bool in
                    self.indexCalls += 1
                    return self.failIndex
                }
                if fails { throw CocoaError(.fileWriteUnknown) }
            })
    }
}

@Suite("Spotlight redonation after a failed index write", .timeLimit(.minutes(1)))
struct SpotlightRedonationTokenTests {

    private let tokenKey = "spotlightDonatedToken_v1"

    private func trip(_ title: String) -> TripEntity {
        TripEntity(
            id: TripEntityID(tripID: UUID()), title: title, titleAliases: [], destinationSummary: title,
            startDate: Date(timeIntervalSinceReferenceDate: 800_000_000), endDate: nil,
            isOngoing: false, countryCodes: ["PT"], countryNames: ["Portugal"], localities: [title])
    }

    private func digest(_ entities: [TripEntity]) -> String {
        let tag = AppLanguagePreference.currentTag()
        return SpotlightIndexer.contentDigest(
            for: entities, languageTag: tag, locale: AppLanguagePreference.locale(for: tag))
    }

    @Test("content that reverts after a delete and a failed index is donated again on relaunch")
    func revertedContentRedonates() async throws {
        let suite = "spotlight-redonation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let index = RedonationIndex()
        let contentA = [trip("Lisbon")]

        let first = SpotlightIndexer(operations: index.seam, defaults: UserDefaults(suiteName: suite)!)
        index.set(contentA)
        await first.refresh()
        #expect(defaults.string(forKey: tokenKey) == digest(contentA))

        // B deletes the old entities, then its index write fails.
        index.set([trip("Braga")], failIndex: true)
        await first.refresh()
        #expect(defaults.string(forKey: tokenKey) == nil)

        // The content is back to A and the app relaunches before any retry.
        index.set(contentA)
        let relaunched = SpotlightIndexer(operations: index.seam, defaults: UserDefaults(suiteName: suite)!)
        let before = index.indexCount
        await relaunched.refresh()
        #expect(index.indexCount == before + 1)
        #expect(defaults.string(forKey: tokenKey) == digest(contentA))

        // Control: unchanged content on the next launch donates nothing.
        let again = SpotlightIndexer(operations: index.seam, defaults: UserDefaults(suiteName: suite)!)
        await again.refresh()
        #expect(index.indexCount == before + 1)
    }

    @Test("a failed delete also leaves no token, so the next launch retries")
    func failedDeleteRetries() async throws {
        let suite = "spotlight-redonation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let index = RedonationIndex()
        let contentA = [trip("Lisbon")]
        let indexer = SpotlightIndexer(operations: index.seam, defaults: UserDefaults(suiteName: suite)!)
        index.set(contentA)
        await indexer.refresh()
        index.set([trip("Braga")], failDelete: true)
        await indexer.refresh()
        #expect(defaults.string(forKey: tokenKey) == nil)
    }
}
