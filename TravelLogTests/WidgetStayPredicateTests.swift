//
//  WidgetStayPredicateTests.swift
//  TravelLogTests
//
//  Tests the SHARED fetch-predicate factories the widget TimelineProviders
//  (TravelStatsProvider, StatsAccessoryProvider, CurrentTripProvider) fetch
//  with: `Stay.visitedCategoriesPredicate()`, `Stay.transitCategoryPredicate()`
//  and `Trip.completedPredicate()`. The providers themselves bind to
//  SharedModelContainer.container (an App-Group on-disk store) and are not
//  instantiable in tests — but since the 2026-08-08 signal-repair pass the
//  predicates are PRODUCTION factories compiled into both targets, so these
//  tests exercise the exact selection the widgets run, not a copy of it.
//  (The factories capture StayCategory rawValues rather than string literals,
//  so the old literal-drift pin is structurally impossible to violate; the
//  persisted-token stability of the rawValues themselves is pinned by the
//  StayCategory token table in ModelEnumRawValueTests.)
//  @MainActor because the app target is MainActor-by-default, which makes
//  @Model types (Stay, Trip) MainActor-isolated.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct WidgetStayPredicateTests {

    private func makeStay(category: StayCategory, isoCountryCode: String? = nil) -> Stay {
        let stay = Stay(
            startTime: .now, endTime: .now,
            centroidLatitude: 0, centroidLongitude: 0,
            h3IndexRes6: "8a00000000000ff", pingCount: 1,
            distanceFromHomeKm: 0, pingIDs: []
        )
        stay.category = category
        stay.isoCountryCode = isoCountryCode
        return stay
    }

    @Test("the shared visited predicate selects exactly home + routine + destination")
    func visitedPredicateSelectsHomeRoutineDestination() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        for category in StayCategory.allCases {
            context.insert(makeStay(category: category))
        }

        let fetched = try context.fetch(
            FetchDescriptor<Stay>(predicate: Stay.visitedCategoriesPredicate()))
        #expect(Set(fetched.map(\.category)) == [.home, .routine, .destination])
    }

    @Test("the shared transit predicate selects exactly the transit category")
    func transitPredicateSelectsOnlyTransit() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        for category in StayCategory.allCases {
            context.insert(makeStay(category: category))
        }

        let fetched = try context.fetch(
            FetchDescriptor<Stay>(predicate: Stay.transitCategoryPredicate()))
        #expect(fetched.map(\.category) == [.transit])
    }

    @Test("the shared completed-trip predicate counts only trips with isComplete == true")
    func completedTripPredicateCountsOnlyComplete() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        let complete = Trip(startDate: .now)
        complete.isComplete = true
        context.insert(complete)

        let incomplete = Trip(startDate: .now)
        incomplete.isComplete = false
        context.insert(incomplete)

        let count = try context.fetchCount(
            FetchDescriptor<Trip>(predicate: Trip.completedPredicate()))
        #expect(count == 1)
    }
}
