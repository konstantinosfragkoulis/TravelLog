//
//  TripSortOrderMetadataTests.swift
//  TravelLogTests
//
//  The persisted-token table for TripSortOrder's
//  @AppStorage("tripsSortOrder") value: these strings live in UserDefaults,
//  so a case rename silently resets every user's sort choice. TripSortOrder
//  is a plain String enum (no @Model), so this suite is NOT @MainActor.
//

import Testing
import Foundation
@testable import TravelLog

struct TripSortOrderMetadataTests {

    @Test("persisted tokens are frozen; unknown raw → nil (caller defaults to .dateNewest)")
    func persistedTokensAreFrozen() {
        let frozen: [(TripSortOrder, String)] = [
            (.dateNewest, "dateNewest"),
            (.dateOldest, "dateOldest"),
            (.significanceHighest, "significanceHighest"),
            (.durationLongest, "durationLongest"),
            (.durationShortest, "durationShortest"),
            (.photoCountHighest, "photoCountHighest"),
            (.photoCountLowest, "photoCountLowest"),
            (.countryCountHighest, "countryCountHighest"),
            (.nameAZ, "nameAZ"),
        ]
        #expect(frozen.count == TripSortOrder.allCases.count,
                "token table out of date — freeze the new case's token deliberately")
        for (order, token) in frozen {
            #expect(order.rawValue == token, "\(order) persisted token drifted")
            #expect(order.id == order.rawValue)
        }
        #expect(TripSortOrder(rawValue: "not-a-real-order") == nil)
    }
}
