//
//  CalendarSelectionToggleTests.swift
//  TravelLogTests
//

import Testing
@testable import TravelLog

@MainActor
@Suite
struct CalendarSelectionToggleTests {
    @Test func staleIDsDoNotLetTheLastLiveCalendarBeUnchecked() {
        #expect(CalendarSelectionView.toggled(["A", "X"], live: ["A", "B"], id: "A") == ["A", "X"])
    }

    @Test func checkingEveryLiveCalendarCollapsesToAllDespiteStaleIDs() {
        #expect(CalendarSelectionView.toggled(["A", "X"], live: ["A", "B"], id: "B") == [])
    }

    @Test func unchangedRulesWithoutStaleIDs() {
        #expect(CalendarSelectionView.toggled([], live: ["A", "B"], id: "A") == ["B"])
        #expect(CalendarSelectionView.toggled(["A", "B"], live: ["A", "B", "C"], id: "B") == ["A"])
        #expect(CalendarSelectionView.toggled(["A"], live: ["A", "B"], id: "A") == ["A"])
        #expect(CalendarSelectionView.toggled([], live: ["A"], id: "A") == [])
    }
}
