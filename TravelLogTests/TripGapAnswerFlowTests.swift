//
//  TripGapAnswerFlowTests.swift
//  TravelLogTests
//
//  The "Did you go home?" questions as the Trips list and the answers' Undo
//  read them: the list's cached index (entry count and row badges), Undo
//  after "Yes" rejoining the halves with the question back, and "No" with
//  its Undo. Fictional coordinates around a home at (40, 10).
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Trip gap answers, Undo and the list's questions", .serialized)
struct TripGapAnswerFlowTests {

    private static let home = (lat: 40.0, lon: 10.0)
    private static let base = Date(timeIntervalSinceReferenceDate: 3_000 * 86_400)
    private func day(_ d: Double) -> Date { Self.base.addingTimeInterval(d * 86_400) }

    /// Two places about 334 km apart, each about 222 km from home: a gap
    /// three hours longer than the trip home and back is one the judge cannot call.
    private static let north = (lat: 42.0, lon: 10.0)
    private static let east = (lat: 40.0, lon: 12.6)

    private func km(_ lat: Double, _ lon: Double) -> Double {
        HomeOrbit.greatCircleKm(Self.home.lat, Self.home.lon, lat, lon)
    }

    private var unsureGap: TimeInterval {
        TripGapJudge.travelTime(km: km(Self.north.lat, Self.north.lon))
            + TripGapJudge.travelTime(km: km(Self.east.lat, Self.east.lon)) + 3 * 3600
    }

    private func defaults() throws -> (UserDefaults, String) {
        let name = "TripGapAnswerFlowTests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    /// A completed trip whose stays alternate between the two places, each
    /// pair `unsureGap` apart: `stops - 1` questions.
    @discardableResult
    private func trip(
        _ ctx: ModelContext, start: Date, stops: Int, complete: Bool = true
    ) throws -> (trip: Trip, stays: [Stay]) {
        let trip = Trip(startDate: start)
        trip.isComplete = complete
        ctx.insert(trip)
        var stays: [Stay] = []
        var time = start
        for index in 0..<stops {
            let place = index.isMultiple(of: 2) ? Self.north : Self.east
            let stay = Stay(
                startTime: time, endTime: time.addingTimeInterval(12 * 3600),
                centroidLatitude: place.lat, centroidLongitude: place.lon,
                h3IndexRes6: H3Service.cellIndex(latitude: place.lat, longitude: place.lon) ?? "cell",
                pingCount: 4, distanceFromHomeKm: km(place.lat, place.lon), pingIDs: [],
                source: .photoImport)
            stay.category = .destination
            stay.locality = index.isMultiple(of: 2) ? "Northport" : "Eastvale"
            stay.trip = trip
            stay.orderInTrip = index
            ctx.insert(stay)
            stays.append(stay)
            time = stay.endTime.addingTimeInterval(unsureGap)
        }
        trip.endDate = complete ? stays.last?.endTime : nil
        try ctx.save()
        return (trip, stays)
    }

    private func trips(_ container: ModelContainer) throws -> [Trip] {
        try container.mainContext.fetch(FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.startDate)]))
    }

    // MARK: - The list's index

    @Test("the list's cached index counts each row's questions and lists each once, oldest first")
    func listIndexCountsAndBadges() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let one = try trip(ctx, start: day(10), stops: 2)
        let three = try trip(ctx, start: day(1), stops: 4)
        let none = try trip(ctx, start: day(20), stops: 1)
        try trip(ctx, start: day(30), stops: 2, complete: false)

        let index = try TripGapQuestionIndex.load(container: container, confirmed: []) {}
        #expect(index.count(for: one.trip.persistentModelID) == 1)
        #expect(index.count(for: three.trip.persistentModelID) == 3)
        #expect(index.count(for: none.trip.persistentModelID) == 0)
        // The open trip asks nothing: four questions in all, the entry's count.
        #expect(index.ordered.count == 4)
        #expect(index.ordered.map(\.question.gapStart) == index.ordered.map(\.question.gapStart).sorted())
        #expect(index.ordered.first?.tripIdentifier == three.trip.persistentModelID)
        #expect(index.ordered.first?.question.title.contains("Northport") == true)

        // An answered gap leaves the badge and the entry.
        let answered = TripGapAnswers.key(earlier: three.stays[1].id, later: three.stays[2].id)
        let fewer = try TripGapQuestionIndex.load(container: container, confirmed: [answered]) {}
        #expect(fewer.count(for: three.trip.persistentModelID) == 2)
        #expect(fewer.ordered.count == 3)
        #expect(!fewer.ordered.contains { $0.id == answered })
    }

    @Test("no questions: no entry and no badges")
    func listIndexEmpty() throws {
        let container = try TestSupport.makeInMemoryContainer()
        #expect(try TripGapQuestionIndex.load(container: container, confirmed: []) {}.isEmpty)
        let ctx = container.mainContext
        let lone = try trip(ctx, start: day(1), stops: 1)
        let index = try TripGapQuestionIndex.load(container: container, confirmed: []) {}
        #expect(index.isEmpty)
        #expect(index.counts.isEmpty)
        #expect(index.count(for: lone.trip.persistentModelID) == 0)
    }

    // MARK: - Undo

    @Test("Undo after \"Yes\" rejoins the halves and the question asks again")
    func undoYesRestoresQuestion() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let (original, stays) = try trip(ctx, start: day(1), stops: 2)
        let (suite, name) = try defaults()
        defer { suite.removePersistentDomain(forName: name) }
        let question = try #require(TripGapQuestion.questions(for: original, defaults: suite).first)
        let splitAt = try #require(TripDetailView.gapSplitStay(for: question, in: original))

        let later = try #require(TripDetailView.applySplitReturningLaterHalf(
            tripID: original.id, tripIdentifier: original.persistentModelID,
            splitStayID: splitAt.id, splitStayIdentifier: splitAt.persistentModelID, in: ctx))
        #expect(try trips(container).map { $0.orderedStays.map(\.id) } == [[stays[0].id], [stays[1].id]])
        #expect(later.id != original.id)

        #expect(TripGapActions.rejoinHalves(
            question, earlier: TripGapActions.TripRef(original), later: later,
            container: container, defaults: suite))
        let rejoined = try trips(container)
        #expect(rejoined.count == 1)
        #expect(rejoined.first?.id == original.id)
        #expect(rejoined.first?.orderedStays.map(\.id) == stays.map(\.id))
        // The merge's seam is forgotten, so the gap asks again.
        #expect(TripGapAnswers.confirmed(defaults: suite).isEmpty)
        let asked = try #require(rejoined.first)
        #expect(TripGapQuestion.questions(for: asked, defaults: suite).map(\.id) == [question.id])
    }

    @Test("\"No\" keeps the trip and stops asking; its Undo asks again")
    func noThenUndo() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = container.mainContext
        let (kept, _) = try trip(ctx, start: day(1), stops: 2)
        let (suite, name) = try defaults()
        defer { suite.removePersistentDomain(forName: name) }
        let question = try #require(TripGapQuestion.questions(for: kept, defaults: suite).first)

        TripGapActions.keep(question, defaults: suite)
        #expect(TripGapQuestion.questions(for: kept, defaults: suite).isEmpty)
        // The Stops line keeps the answered gap as its quiet note.
        #expect(TripGapQuestion.gaps(for: kept, defaults: suite).map(\.answered) == [true])

        TripGapActions.undoKeep(question, defaults: suite)
        #expect(TripGapQuestion.questions(for: kept, defaults: suite).map(\.id) == [question.id])
        #expect(TripGapAnswers.confirmed(defaults: suite).isEmpty)
        #expect(try trips(container).count == 1)
    }

    @Test("Undo forgets only its own answer")
    func unconfirmKeepsOthers() throws {
        let (suite, name) = try defaults()
        defer { suite.removePersistentDomain(forName: name) }
        TripGapAnswers.confirm(["a>b", "c>d", "e>f"], defaults: suite)
        TripGapAnswers.unconfirm(["c>d"], defaults: suite)
        #expect(suite.stringArray(forKey: TripGapAnswers.confirmedKey) == ["a>b", "e>f"])
        TripGapAnswers.unconfirm(["a>b", "e>f"], defaults: suite)
        #expect(suite.object(forKey: TripGapAnswers.confirmedKey) == nil)
    }

    // MARK: - Copy

    @Test("the gap's length reads in days, or hours under a day")
    func lengthText() {
        let start = day(1).addingTimeInterval(20 * 3600)
        #expect(TripGapQuestion.lengthText(from: start, to: start.addingTimeInterval(12 * 86_400)).contains("12"))
        #expect(TripGapQuestion.lengthText(from: start, to: start.addingTimeInterval(14 * 3600)).contains("14"))
        let text = TripGapQuestion.lengthText(from: start, to: start.addingTimeInterval(30 * 3600))
        #expect(!text.contains("\u{2013}") && !text.contains("\u{2014}"))
    }
}
