//
//  StayPagedScanTests.swift
//  TravelLogTests
//
//  `Stay.forEachPage` is how the widget extension reads visited and transit
//  stays under its memory budget. These pin that paging visits every matching
//  row exactly once and that the paged aggregates equal the one-array ones.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@Suite("Stay paged scan")
@MainActor
struct StayPagedScanTests {

    private func makeStore() throws -> ModelContainer {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<235 {
            // Blocks of 5 rows (3 of them visited) share one start time, so the
            // row-paging boundaries below (50 and 100) fall inside a tie and only
            // the id tiebreak keeps the pages disjoint. Place, hex and country
            // advance with the index, so each page contributes values no other
            // page has.
            let block = index / 5
            let start = base.addingTimeInterval(Double(block) * 3_600)
            let stay = Stay(
                startTime: start, endTime: start.addingTimeInterval(300),
                centroidLatitude: -40 + Double(block) * 1.5,
                centroidLongitude: -60 + Double(block) * 2,
                h3IndexRes6: index % 13 == 0 ? "" : "86cell\(block)",
                pingCount: 1, distanceFromHomeKm: 10, pingIDs: [])
            stay.category = [.home, .routine, .destination, .transit, .unclassified][index % 5]
            stay.isoCountryCode = index % 7 == 0 ? nil : "C\(block)"
            context.insert(stay)
        }
        try context.save()
        return container
    }

    @Test("paging visits every matching row exactly once, across three pages")
    func pagedRowsMatchFullFetch() throws {
        let container = try makeStore()
        let all = try ModelContext(container).fetch(
            FetchDescriptor<Stay>(predicate: Stay.visitedCategoriesPredicate()))
        #expect(all.count == 141)

        var seen: [UUID] = []
        var starts: [Date] = []
        var pages = 0
        try Stay.forEachPage(
            matching: Stay.visitedCategoriesPredicate(),
            propertiesToFetch: [\.startTime], in: container, pageSize: 50
        ) { page in
            seen.append(contentsOf: page.map(\.id))
            starts.append(contentsOf: page.map(\.startTime))
            pages += 1
        }
        #expect(pages == 3)
        #expect(seen.count == all.count)
        #expect(Set(seen) == Set(all.map(\.id)))
        // One global order across pages, and the boundaries really split ties.
        #expect(starts == starts.sorted())
        #expect(starts[49] == starts[50])
        #expect(starts[99] == starts[100])
    }

    @Test("paged aggregates equal the one-array aggregates")
    func pagedAggregatesMatchFullFetch() throws {
        let container = try makeStore()
        let all = try ModelContext(container).fetch(
            FetchDescriptor<Stay>(predicate: Stay.visitedCategoriesPredicate()))

        var countries = Set<String>()
        var hexes = Set<String>()
        var cities = Stay.CityCountAccumulator()
        try Stay.forEachPage(
            matching: Stay.visitedCategoriesPredicate(),
            propertiesToFetch: [\.isoCountryCode, \.h3IndexRes6, \.centroidLatitude, \.centroidLongitude],
            in: container, pageSize: 40
        ) { page in
            for stay in page {
                if let code = stay.isoCountryCode { countries.insert(code) }
                if !stay.h3IndexRes6.isEmpty { hexes.insert(stay.h3IndexRes6) }
                cities.add(
                    h3IndexRes6: stay.h3IndexRes6,
                    latitude: stay.centroidLatitude, longitude: stay.centroidLongitude)
            }
        }
        #expect(countries == Set(all.compactMap(\.isoCountryCode)))
        #expect(hexes == Set(all.map(\.h3IndexRes6).filter { !$0.isEmpty }))
        #expect(cities.count() == Stay.deduplicatedCityCount(from: all))
        // 47 blocks, far apart: an accumulator reset between pages would count
        // only the last page's blocks.
        #expect(countries.count == 47)
        #expect(cities.count() >= 47)
    }

    @Test("an empty match calls the body once with no rows and stops")
    func emptyMatch() throws {
        let container = try TestSupport.makeInMemoryContainer()
        var calls = 0
        try Stay.forEachPage(
            matching: Stay.transitCategoryPredicate(), propertiesToFetch: [\.isAirport], in: container
        ) { page in
            calls += 1
            #expect(page.isEmpty)
        }
        #expect(calls == 1)
    }
}
