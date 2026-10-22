//
//  HomeHistoryScenarioTests.swift
//  TravelLogTests
//
//  Proof of concept: where the user lived, and since when, is a fact only
//  the user knows. Without it the prehistory pass lets every current Home
//  claim every stay older than all Homes, so a photo-imported holiday in a
//  city the user moved to years later reads as home, and the city the user
//  really lived in reads as trips. Each test seeds what the pipeline does
//  today, then applies the user's dated answer through the real Home change
//  unit (`applyHomeChangeCore`, the user's dates kept as given) and the real
//  ordinary pass, and asserts what the user ends up seeing.
//
//  Fixture time is whole days from midnight UTC on 1 January 2001, and every
//  stay carries the GMT zone. Places are bare coordinates.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Home history scenarios", IsolatedTitleDefaults())
struct HomeHistoryScenarioTests {

    private typealias Place = (lat: Double, lon: Double)
    /// Where the user used to live.
    private static let oldHome: Place = (46.0, 2.0)
    /// Where the user lives now, about 1,000 km from the old home.
    private static let newHome: Place = (41.0, 14.0)
    /// A third city, far from both.
    private static let elsewhere: Place = (52.0, 20.0)

    private func date(_ day: Double) -> Date { TemporaryHomeFixture.date(day) }

    @discardableResult
    private func stay(
        _ ctx: ModelContext, _ place: Place, _ from: Double, _ to: Double,
        source: DataSource = .photoImport
    ) -> Stay {
        TemporaryHomeFixture.stay(
            ctx, place, from: date(from), to: date(to), .unclassified, hex: "H",
            pingCount: 3, source: source, zone: "GMT")
    }

    private func home(
        _ ctx: ModelContext, _ label: String, at place: Place, since: Double, until: Double? = nil
    ) -> Home {
        let home = TemporaryHomeFixture.realHome(ctx, label, at: place)
        home.startedAt = date(since)
        home.endedAt = until.map { date($0) }
        return home
    }

    private func makeClassifier(_ container: ModelContainer) async -> TripClassifier {
        await TemporaryHomeFixture.classifier(
            container, squares: [(1, Self.oldHome), (2, Self.newHome)])
    }

    /// The user's answer, as a Settings save of explicit dates would apply
    /// it: one Home change unit per edited Home, then the ordinary pass.
    private func applyAnswer(_ classifier: TripClassifier, homes: [UUID]) async {
        for id in homes {
            #expect(await classifier.applyHomeChangeCore(homeID: id, backdatesStart: false).isSettled)
        }
        await TemporaryHomeFixture.ordinaryPass(classifier)
    }

    // MARK: Reading the store

    private struct StayFacts: Equatable {
        let category: StayCategory
        let tripID: UUID?
    }

    private func facts(_ stays: [Stay], _ container: ModelContainer) throws -> [StayFacts] {
        let byID = Dictionary(
            try ModelContext(container).fetch(FetchDescriptor<Stay>()).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        return stays.map { StayFacts(category: byID[$0.id]?.category ?? .unclassified,
                                     tripID: byID[$0.id]?.trip?.id) }
    }

    /// Each trip's stays, in start order.
    private func tripMembers(_ container: ModelContainer) throws -> [Set<UUID>] {
        try ModelContext(container).fetch(FetchDescriptor<Trip>())
            .sorted { $0.startDate < $1.startDate }
            .map { Set(($0.stays ?? []).map(\.id)) }
    }

    private func startedAt(_ id: UUID, _ container: ModelContainer) throws -> Date? {
        try ModelContext(container).fetch(FetchDescriptor<Home>(
            predicate: #Predicate<Home> { $0.id == id })).first?.startedAt
    }

    // MARK: - 1

    @Test("installed after a move, with years of photos: today the old home city reads as trips and a holiday in today's city reads as home; stating both homes with dates makes the old city home and the holiday a trip of its own")
    func installedAfterTheMove() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let current = home(ctx, "New", at: Self.newHome, since: 1000)
        // Photo history from before the install.
        let atOld = [stay(ctx, Self.oldHome, 100.2, 100.8), stay(ctx, Self.oldHome, 103.2, 103.8),
                     stay(ctx, Self.oldHome, 200.2, 200.8), stay(ctx, Self.oldHome, 302.2, 302.8)]
        let holiday = stay(ctx, Self.newHome, 101.2, 102.8)
        let away = stay(ctx, Self.elsewhere, 300.2, 301.8)
        // Live presence since the install.
        let live = stay(ctx, Self.newHome, 1000.2, 1005.8, source: .liveSLC)
        try ctx.save()
        let classifier = await makeClassifier(container)
        await TemporaryHomeFixture.ordinaryPass(classifier)

        // Today: the holiday is home and in no trip; the old home is travel.
        #expect(try facts([holiday, live], container).map(\.category) == [.home, .home])
        #expect(try facts([holiday], container)[0].tripID == nil)
        #expect(try facts(atOld, container).allSatisfy { $0.category == .destination && $0.tripID != nil })

        // The user's answer: "I lived at the old place from day 0 to day 900,
        // and here since day 900."
        let former = home(ctx, "Old", at: Self.oldHome, since: 0, until: 900)
        current.startedAt = date(900)
        try ctx.save()
        await applyAnswer(classifier, homes: [former.id, current.id])

        #expect(try facts(atOld, container).allSatisfy { $0 == StayFacts(category: .home, tripID: nil) })
        #expect(try facts([live], container)[0] == StayFacts(category: .home, tripID: nil))
        #expect(try facts([holiday, away], container).map(\.category) == [.destination, .destination])
        #expect(try tripMembers(container) == [[holiday.id], [away.id]])
        #expect(try startedAt(current.id, container) == date(900))
    }

    // MARK: - 2

    @Test("installed before a move: today a pre-install holiday in the later city reads as home, because both Homes claim everything older than them; the old Home's real start date is the one answer that fixes it")
    func installedBeforeTheMove() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        // The app knew the old home from the install on day 500 and the move on day 900.
        let former = home(ctx, "Old", at: Self.oldHome, since: 500, until: 900)
        _ = home(ctx, "New", at: Self.newHome, since: 900)
        let atOld = [stay(ctx, Self.oldHome, 100.2, 100.8), stay(ctx, Self.oldHome, 103.2, 103.8),
                     stay(ctx, Self.oldHome, 500.2, 899.8, source: .liveSLC)]
        let holiday = stay(ctx, Self.newHome, 101.2, 102.8)
        let live = stay(ctx, Self.newHome, 900.2, 905.8, source: .liveSLC)
        try ctx.save()
        let classifier = await makeClassifier(container)
        await TemporaryHomeFixture.ordinaryPass(classifier)

        #expect(try facts([holiday], container)[0] == StayFacts(category: .home, tripID: nil))
        #expect(try tripMembers(container).isEmpty)

        // The user's answer: "I lived at the old place since day 0."
        former.startedAt = date(0)
        try ctx.save()
        await applyAnswer(classifier, homes: [former.id])

        #expect(try facts(atOld + [live], container)
                .allSatisfy { $0 == StayFacts(category: .home, tripID: nil) })
        #expect(try facts([holiday], container)[0].category == .destination)
        #expect(try tripMembers(container) == [[holiday.id]])
    }

    // MARK: - 3

    @Test("a picked start date is the user's: a viewing visit to the new city just before the move stays a trip, where the automatic backdate pulls the start back over it", arguments: [false, true])
    func pickedStartDateIsKept(backdates: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        _ = home(ctx, "Old", at: Self.oldHome, since: 0, until: 900)
        let current = home(ctx, "New", at: Self.newHome, since: 900)
        stay(ctx, Self.oldHome, 800.2, 849.8, source: .liveSLC)
        // The last stay before the move, and the first in the new ring the
        // backdate reaches walking back from the latest stay.
        let viewing = stay(ctx, Self.newHome, 850.2, 851.8)
        let live = stay(ctx, Self.newHome, 900.2, 905.8, source: .liveSLC)
        try ctx.save()
        let classifier = await makeClassifier(container)

        #expect(await classifier.applyHomeChangeCore(
            homeID: current.id, backdatesStart: backdates).isSettled)
        await TemporaryHomeFixture.ordinaryPass(classifier)

        #expect(try startedAt(current.id, container) == date(backdates ? 850.2 : 900))
        #expect(try facts([live], container)[0] == StayFacts(category: .home, tripID: nil))
        #expect(try facts([viewing], container)[0].category == (backdates ? .home : .destination))
    }
}
