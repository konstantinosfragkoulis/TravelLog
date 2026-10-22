//
//  TripGapAssemblyTests.swift
//  TravelLogTests
//
//  `TripGapJudge` inside trip assembly, the "Did you go home?" questions it
//  leaves for the user, and their answers. Fictional coordinates around a
//  home at (40, 10): a degree of latitude is about 111 km.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Trip gaps in assembly and questions", .serialized, IsolatedLineageDefaults())
struct TripGapAssemblyTests {

    private static let home = (lat: 40.0, lon: 10.0)
    private static let base = Date(timeIntervalSinceReferenceDate: 3_000 * 86_400)
    private func hour(_ h: Double) -> Date { Self.base.addingTimeInterval(h * 3600) }
    private func day(_ d: Double) -> Date { hour(d * 24) }

    private func km(_ lat: Double, _ lon: Double) -> Double {
        HomeOrbit.greatCircleKm(Self.home.lat, Self.home.lon, lat, lon)
    }

    @discardableResult
    private func stay(
        _ ctx: ModelContext, _ category: StayCategory, lat: Double, lon: Double,
        start: Date, hours: Double, locality: String? = nil
    ) -> Stay {
        let stay = Stay(
            startTime: start, endTime: start.addingTimeInterval(hours * 3600),
            centroidLatitude: lat, centroidLongitude: lon,
            h3IndexRes6: H3Service.cellIndex(latitude: lat, longitude: lon) ?? "cell",
            pingCount: 4, distanceFromHomeKm: km(lat, lon), pingIDs: [],
            source: .photoImport)
        stay.category = category
        stay.locality = locality
        ctx.insert(stay)
        return stay
    }

    private func homeStay(_ ctx: ModelContext, at start: Date) {
        stay(ctx, .home, lat: Self.home.lat, lon: Self.home.lon, start: start, hours: 12)
    }

    private func makeHome(_ ctx: ModelContext) {
        ctx.insert(Home(label: "Home", latitude: Self.home.lat, longitude: Self.home.lon,
                        radiusKm: 25, startedAt: day(-30)))
    }

    /// Assembly mutates the actor's context without saving; save it so a
    /// fresh context reads what assembly built.
    private func assemble(_ classifier: TripClassifier) async throws -> Int {
        let created = await classifier.assembleTrips()
        try await classifier.runIsolated { try $0.modelContext.save() }
        return created
    }

    private func trips(_ container: ModelContainer) throws -> [Trip] {
        try ModelContext(container).fetch(FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.startDate)]))
    }

    private func defaults() throws -> (UserDefaults, String) {
        let suite = "TripGapAssemblyTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    /// Two places about 334 km apart, each about 222 km from home: home is near
    /// the route. A gap three hours longer than the trip home and back is one
    /// the judge cannot call.
    private static let unsureEarlier = (lat: 42.0, lon: 10.0)
    private static let unsureLater = (lat: 40.0, lon: 12.6)
    private var unsureGapHours: Double {
        (TripGapJudge.travelTime(km: km(Self.unsureEarlier.lat, Self.unsureEarlier.lon))
         + TripGapJudge.travelTime(km: km(Self.unsureLater.lat, Self.unsureLater.lon))) / 3600 + 3
    }

    // MARK: - Assembly

    @Test("moving on after a week with nothing recorded and no home stay between is two trips")
    func clearGapSplits() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(ctx)
        homeStay(ctx, at: day(0))
        let a = stay(ctx, .destination, lat: 45, lon: 10, start: day(1), hours: 12)
        let b = stay(ctx, .destination, lat: 45, lon: 13, start: day(10), hours: 12)
        homeStay(ctx, at: day(20))
        try ctx.save()

        #expect(try await assemble(TripClassifier(modelContainer: container)) == 2)
        let built = try trips(container)
        #expect(built.map { $0.orderedStays.map(\.id) } == [[a.id], [b.id]])
        #expect(built.allSatisfy { $0.isComplete && !$0.userEdited })
        #expect(built.first?.endDate == a.endTime)
    }

    @Test("staying put through a long silence is one trip until three weeks pass")
    func samePlaceLongGap() async throws {
        for (gapDays, expected) in [(10.0, 1), (22.0, 2)] {
            let container = try TestSupport.makeInMemoryContainer()
            let ctx = ModelContext(container)
            makeHome(ctx)
            homeStay(ctx, at: day(0))
            stay(ctx, .destination, lat: 45, lon: 10, start: day(1), hours: 12)
            stay(ctx, .destination, lat: 45.05, lon: 10.05, start: day(1.5 + gapDays), hours: 12)
            homeStay(ctx, at: day(40))
            try ctx.save()

            #expect(try await assemble(TripClassifier(modelContainer: container)) == expected)
        }
    }

    @Test("a gap the judge cannot call stays one trip and becomes a question")
    func unsureGapKeepsOneTrip() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(ctx)
        homeStay(ctx, at: day(0))
        let a = stay(ctx, .destination, lat: Self.unsureEarlier.lat, lon: Self.unsureEarlier.lon,
                     start: day(1), hours: 12, locality: "Northport")
        let b = stay(ctx, .destination, lat: Self.unsureLater.lat, lon: Self.unsureLater.lon,
                     start: a.endTime.addingTimeInterval(unsureGapHours * 3600), hours: 12,
                     locality: "Eastvale")
        homeStay(ctx, at: day(5))
        try ctx.save()

        #expect(try await assemble(TripClassifier(modelContainer: container)) == 1)
        let trip = try #require(try trips(container).first)
        #expect(trip.orderedStays.map(\.id) == [a.id, b.id])
        let (suite, name) = try defaults()
        defer { suite.removePersistentDomain(forName: name) }
        let questions = TripGapQuestion.questions(for: trip, defaults: suite)
        #expect(questions.count == 1)
        #expect(questions.first?.earlierStayID == a.id)
        #expect(questions.first?.laterStayID == b.id)
        #expect(questions.first?.gapStart == a.endTime)
        #expect(questions.first?.gapEnd == b.startTime)
    }

    @Test("an open trip is not split by a silence in its recording; it is judged once home follows")
    func openTripIsNotSplit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(ctx)
        homeStay(ctx, at: day(0))
        let a = stay(ctx, .destination, lat: 45, lon: 10, start: day(1), hours: 12)
        let b = stay(ctx, .destination, lat: 45, lon: 13, start: day(10), hours: 12)
        try ctx.save()

        #expect(try await assemble(TripClassifier(modelContainer: container)) == 1)
        let open = try #require(try trips(container).first)
        #expect(!open.isComplete)
        #expect(open.orderedStays.map(\.id) == [a.id, b.id])

        homeStay(ctx, at: day(20))
        try ctx.save()
        #expect(try await assemble(TripClassifier(modelContainer: container)) == 2)
        #expect(try trips(container).map { $0.orderedStays.map(\.id) } == [[a.id], [b.id]])
    }

    @Test("a late stay regroups an unedited trip at its clear gap, never an edited one",
          arguments: [false, true])
    func editedTripIsNeverResplit(userEdited: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(ctx)
        homeStay(ctx, at: day(0))
        let a = stay(ctx, .destination, lat: 45, lon: 10, start: day(1), hours: 12)
        let b = stay(ctx, .destination, lat: 45, lon: 13, start: day(10), hours: 12)
        homeStay(ctx, at: day(20))
        let trip = Trip(startDate: a.startTime)
        trip.endDate = b.endTime
        trip.isComplete = true
        trip.userEdited = userEdited
        ctx.insert(trip)
        a.trip = trip
        a.orderInTrip = 0
        b.trip = trip
        b.orderInTrip = 1
        // A late import after the trip's last stay, before the return home.
        let late = stay(ctx, .destination, lat: 45, lon: 13.05, start: day(12), hours: 12)
        try ctx.save()
        let tripID = trip.id

        _ = try await assemble(TripClassifier(modelContainer: container))
        let built = try trips(container)
        if userEdited {
            let kept = try #require(built.first { $0.id == tripID })
            #expect(kept.orderedStays.map(\.id) == [a.id, b.id])
            #expect(kept.userEdited)
        } else {
            #expect(built.map { $0.orderedStays.map(\.id) } == [[a.id], [b.id, late.id]])
        }
    }

    @Test("a user merge across a clear gap sticks through later assembly")
    func userMergeSticks() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        makeHome(ctx)
        homeStay(ctx, at: day(0))
        let a = stay(ctx, .destination, lat: 45, lon: 10, start: day(1), hours: 12)
        let b = stay(ctx, .destination, lat: 45, lon: 13, start: day(10), hours: 12)
        homeStay(ctx, at: day(20))
        try ctx.save()
        #expect(try await assemble(TripClassifier(modelContainer: container)) == 2)

        let (suite, name) = try defaults()
        defer { suite.removePersistentDomain(forName: name) }
        let split = try trips(container)
        #expect(TripsListView.mergeTrips(
            sourceID: split[1].id, sourceIdentifier: split[1].persistentModelID,
            targetID: split[0].id, targetIdentifier: split[0].persistentModelID,
            container: container, gapAnswers: suite))
        #expect(TripGapAnswers.confirmed(defaults: suite)
            == [TripGapAnswers.key(earlier: a.id, later: b.id)])

        // A late stay beside the merged trip makes assembly run again.
        stay(ctx, .destination, lat: 45, lon: 13.05, start: day(12), hours: 12)
        try ctx.save()
        _ = try await assemble(TripClassifier(modelContainer: container))
        let merged = try #require(try trips(container).first { $0.userEdited })
        #expect(merged.orderedStays.map(\.id) == [a.id, b.id])
    }

    // MARK: - Questions

    private func signal(
        _ category: StayCategory = .destination, lat: Double, lon: Double,
        start: Double, hours: Double = 12,
        locality: String? = nil, region: String? = nil, country: String? = nil
    ) -> TripGapQuestion.StaySignal {
        TripGapQuestion.StaySignal(
            id: UUID(), category: category, startTime: hour(start),
            endTime: hour(start + hours), latitude: lat, longitude: lon,
            distanceFromHomeKm: km(lat, lon),
            locality: locality, region: region, country: country)
    }

    @Test("a question names each side by locality, then region, then country")
    func questionPlaceFallback() throws {
        let earlier = signal(lat: Self.unsureEarlier.lat, lon: Self.unsureEarlier.lon, start: 0,
                             locality: "  ", region: "Upper Vale", country: "Freedonia")
        let later = signal(lat: Self.unsureLater.lat, lon: Self.unsureLater.lon,
                           start: 12 + unsureGapHours, country: "Freedonia")
        let tripID = UUID()
        let questions = TripGapQuestion.questions(tripID: tripID, stays: [later, earlier])
        #expect(questions.count == 1)
        let question = try #require(questions.first)
        #expect(question.tripID == tripID)
        #expect(question.earlierPlace == "Upper Vale")
        #expect(question.laterPlace == "Freedonia")
        #expect(question.title.contains("Upper Vale"))
        #expect(question.title.contains("Freedonia"))
        #expect(!question.detail.isEmpty)
        #expect(!question.detail.contains("\u{2013}") && !question.detail.contains("\u{2014}"))
        #expect(TripGapQuestion.placeName(locality: "Northport", region: "Upper Vale", country: nil) == "Northport")
        #expect(TripGapQuestion.placeName(locality: nil, region: "", country: nil) == nil)
    }

    @Test("each side is named by the longest stay of its run, not the stop beside the gap")
    func questionNamesLongestStayOfEachRun() throws {
        let gap = unsureGapHours
        let earlier = Self.unsureEarlier, later = Self.unsureLater
        // Runs touch end to start, so only the two gaps are judged.
        let northport = signal(lat: 42.3, lon: 10.1, start: 0, hours: 72, locality: "Northport")
        let port = signal(lat: earlier.lat, lon: earlier.lon, start: 72, hours: 1, locality: "Port Kell")
        let harbour = signal(lat: later.lat, lon: later.lon, start: 73 + gap, hours: 1, locality: "Harbour Gate")
        let eastvale = signal(lat: 40.1, lon: 12.8, start: 74 + gap, hours: 48,
                              locality: nil, region: "Eastvale")
        let harbourAgain = signal(lat: later.lat, lon: later.lon, start: 122 + gap, hours: 1,
                                  locality: "Harbour Gate")
        let westmere = signal(lat: earlier.lat, lon: earlier.lon, start: 123 + 2 * gap, hours: 48,
                              locality: "Westmere")
        let stays = [northport, port, harbour, eastvale, harbourAgain, westmere]

        let questions = TripGapQuestion.questions(tripID: UUID(), stays: stays)
        #expect(questions.map(\.laterStayID) == [harbour.id, westmere.id])
        #expect(questions.map(\.earlierPlace) == ["Northport", "Eastvale"])
        #expect(questions.map(\.laterPlace) == ["Eastvale", "Westmere"])

        // An answered gap still bounds its runs.
        let answered = TripGapQuestion.questions(
            tripID: UUID(), stays: stays,
            confirmed: [TripGapAnswers.key(earlier: port.id, later: harbour.id)])
        #expect(answered.map(\.earlierPlace) == ["Eastvale"])
        #expect(answered.map(\.laterPlace) == ["Westmere"])
    }

    @Test("only unsure gaps ask, never across a home member or an answered gap")
    func questionExtraction() {
        let earlier = signal(lat: Self.unsureEarlier.lat, lon: Self.unsureEarlier.lon, start: 0)
        let later = signal(lat: Self.unsureLater.lat, lon: Self.unsureLater.lon, start: 12 + unsureGapHours)
        // A short hop between them leaves no time to go home.
        let soon = signal(lat: Self.unsureLater.lat, lon: Self.unsureLater.lon, start: 13)
        let homeMember = signal(.home, lat: Self.home.lat, lon: Self.home.lon, start: 12.5, hours: 1)
        let tripID = UUID()
        #expect(TripGapQuestion.questions(tripID: tripID, stays: [earlier, later]).count == 1)
        #expect(TripGapQuestion.questions(tripID: tripID, stays: [earlier, soon]).isEmpty)
        #expect(TripGapQuestion.questions(tripID: tripID, stays: [earlier, homeMember, later]).isEmpty)
        #expect(TripGapQuestion.questions(
            tripID: tripID, stays: [earlier, later],
            confirmed: [TripGapAnswers.key(earlier: earlier.id, later: later.id)]).isEmpty)
    }

    // MARK: - Answers

    private func unsureTrip(_ ctx: ModelContext) throws -> (trip: Trip, earlier: Stay, later: Stay) {
        let trip = Trip(startDate: day(1))
        trip.isComplete = true
        ctx.insert(trip)
        let earlier = stay(ctx, .destination, lat: Self.unsureEarlier.lat, lon: Self.unsureEarlier.lon,
                           start: day(1), hours: 12, locality: "Northport")
        let later = stay(ctx, .destination, lat: Self.unsureLater.lat, lon: Self.unsureLater.lon,
                         start: earlier.endTime.addingTimeInterval(unsureGapHours * 3600), hours: 12,
                         locality: "Eastvale")
        for (order, member) in [earlier, later].enumerated() {
            member.trip = trip
            member.orderInTrip = order
        }
        trip.endDate = later.endTime
        try ctx.save()
        return (trip, earlier, later)
    }

    @Test("\"Yes, I went home\" splits the trip at the later stay through Split Trip Here")
    func answerYesSplits() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let (trip, earlier, later) = try unsureTrip(ctx)
        let (suite, name) = try defaults()
        defer { suite.removePersistentDomain(forName: name) }
        let question = try #require(TripGapQuestion.questions(for: trip, defaults: suite).first)
        let splitAt = try #require(TripDetailView.gapSplitStay(for: question, in: trip))
        #expect(splitAt.id == later.id)

        #expect(TripDetailView.applySplit(
            tripID: trip.id, tripIdentifier: trip.persistentModelID,
            splitStayID: splitAt.id, splitStayIdentifier: splitAt.persistentModelID, in: ctx))
        let halves = try trips(container)
        #expect(halves.map { $0.orderedStays.map(\.id) } == [[earlier.id], [later.id]])
        #expect(halves.allSatisfy { $0.userEdited })
        #expect(halves.allSatisfy { TripGapQuestion.questions(for: $0, defaults: suite).isEmpty })
    }

    @Test("\"No, one trip\" keeps the trip and stops the question on this device")
    func answerNoStopsAsking() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let (trip, _, _) = try unsureTrip(ctx)
        let (suite, name) = try defaults()
        let (other, otherName) = try defaults()
        defer {
            suite.removePersistentDomain(forName: name)
            other.removePersistentDomain(forName: otherName)
        }
        let question = try #require(TripGapQuestion.questions(for: trip, defaults: suite).first)

        TripGapAnswers.confirmOneTrip(question, defaults: suite)
        TripGapAnswers.confirmOneTrip(question, defaults: suite)
        #expect(TripGapQuestion.questions(for: trip, defaults: suite).isEmpty)
        #expect(suite.stringArray(forKey: TripGapAnswers.confirmedKey) == [question.id])
        #expect(TripGapQuestion.questions(for: trip, defaults: other).count == 1)
        #expect(try trips(container).count == 1)
    }

    @Test("an open trip asks nothing")
    func openTripAsksNothing() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let (trip, _, _) = try unsureTrip(ctx)
        trip.isComplete = false
        trip.endDate = nil
        #expect(TripGapQuestion.questions(for: trip).isEmpty)
    }

    // MARK: - Sure gaps

    @Test("a long gap far from home with home well off the route is a sure one: no question")
    func sureGapAsksNothing() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let (trip, earlier, later) = try unsureTrip(ctx)
        let (suite, name) = try defaults()
        defer { suite.removePersistentDomain(forName: name) }
        #expect(TripGapQuestion.questions(for: trip, defaults: suite).count == 1)

        // Two days between two places far from home, home well off the route.
        for (member, lon) in [(earlier, 10.0), (later, 12.0)] {
            member.centroidLatitude = 49
            member.centroidLongitude = lon
            member.distanceFromHomeKm = km(49, lon)
        }
        later.startTime = earlier.endTime.addingTimeInterval(50 * 3600)
        later.endTime = later.startTime.addingTimeInterval(12 * 3600)
        #expect(TripGapQuestion.questions(for: trip, defaults: suite).isEmpty)
    }
}
