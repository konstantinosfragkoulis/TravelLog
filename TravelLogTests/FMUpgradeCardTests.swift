//
//  FMUpgradeCardTests.swift
//  TravelLogTests
//
//  Pure seams for the non-FM → FM transition polish:
//    - `Trip.naturalJoin`: the presentation-only "Athens, Cephalonia & Lefkada" join
//      for the `destinationSummary` fallback (never persisted).
//    - `TripsListView.computeHeuristicBacklogCount`: the count of trips still
//      on the heuristic engine that the FM upgrade would improve.
//    - `TripsListView.computeFMUpgradeCardVisible`: the one-time upgrade card's
//      visibility matrix.
//  All three are pure static functions tested without a view host, mirroring
//  the `computeAvailable*` seam-testing pattern.
//

import Testing
import Foundation
@testable import TravelLog

@MainActor
struct FMUpgradeCardTests {

    // MARK: - Trip.naturalJoin

    @Test("naturalJoin renders each component count, trimming and dropping blanks", arguments: [
        ("", ""),                                         // 0 components
        (",", ""),                                        // all-separator string yields no components
        ("  ,  , ", ""),                                  // blank components only
        ("Athens", "Athens"),                             // single component verbatim
        ("  Athens  ", "Athens"),                         // single component trimmed
        ("Athens, Cephalonia", "Athens & Cephalonia"),              // two join with an ampersand
        ("Athens, Cephalonia, Lefkada", "Athens, Cephalonia & Lefkada"),    // commas then a final ampersand
        ("Athens, Cephalonia, Lefkada, Samos, Milos", "Athens, Cephalonia, Lefkada, Samos & Milos"), // five
        ("  Athens ,  Cephalonia , Lefkada ", "Athens, Cephalonia & Lefkada"), // whitespace around every component
        ("Athens,, Cephalonia", "Athens & Cephalonia"),             // empty components dropped, not blank-rendered
        ("Athens, , , Cephalonia, Lefkada", "Athens, Cephalonia & Lefkada"), // runs of empty components dropped
    ])
    func naturalJoinRendersComponents(summary: String, expected: String) {
        #expect(Trip.naturalJoin(summary) == expected)
    }

    // MARK: - Trip.curatedJoin (display-time fallback-title curation)

    @Test("curatedJoin matches naturalJoin exactly for 0-3 components")
    func curatedJoinSmallCounts() {
        for summary in ["", ",", "Athens", "Athens, Cephalonia", "Athens, Cephalonia, Lefkada"] {
            #expect(Trip.curatedJoin(summary) == Trip.naturalJoin(summary))
        }
    }

    @Test("curatedJoin caps long summaries at the first three names, with no trailing count")
    func curatedJoinCapsAtThree() {
        #expect(
            Trip.curatedJoin("Athens, Cephalonia, Lefkada, Samos, Milos")
                == "Athens, Cephalonia & Lefkada"
        )
        #expect(Trip.curatedJoin("A, B, C, D") == "A, B & C")
    }

    @Test("leadingBySignificance moves the three longest-visited names first, visit order among them")
    func leadingBySignificanceOrdersByTime() {
        let names = ["Renens", "Riehen", "Aarburg", "Bern", "Bellinzona", "Ajaccio", "Bort-les-Orgues"]
        let minutes = ["Renens": 2_000, "Riehen": 300, "Aarburg": 200,
                       "Bern": 600, "Bellinzona": 1_500, "Ajaccio": 400, "Bort-les-Orgues": 350]
        #expect(Trip.leadingBySignificance(names, minutes: minutes)
                == ["Renens", "Bern", "Bellinzona", "Riehen", "Aarburg", "Ajaccio", "Bort-les-Orgues"])
        // Three or fewer: untouched, whatever the minutes say.
        #expect(Trip.leadingBySignificance(["A", "B", "C"], minutes: ["C": 900]) == ["A", "B", "C"])
        // Ties keep visit order.
        #expect(Trip.leadingBySignificance(["A", "B", "C", "D"], minutes: [:]) == ["A", "B", "C", "D"])
    }

    @Test("curatedJoin drops Unknown components when named ones exist; all-Unknown renders unchanged")
    func curatedJoinUnknownFilter() {
        #expect(Trip.curatedJoin("Unknown, Athens, Cephalonia") == "Athens & Cephalonia")
        // Dropping Unknowns can bring a long list back under the cap.
        #expect(Trip.curatedJoin("Unknown, Athens, Cephalonia, Lefkada, Unknown") == "Athens, Cephalonia & Lefkada")
        // All-Unknown keeps the current rendering — still tells the user
        // something was recorded, rather than collapsing to bare "Trip".
        #expect(Trip.curatedJoin("Unknown, Unknown") == "Unknown & Unknown")
    }

    @Test("displayName's fallback tier renders the curated join, never the full comma-join")
    @MainActor
    func displayNameUsesCuratedJoin() {
        let trip = Trip(startDate: Date(timeIntervalSinceReferenceDate: 0))
        trip.destinationSummary = "Athens, Cephalonia, Lefkada, Samos, Milos"
        #expect(trip.displayName == "Athens, Cephalonia & Lefkada")
        // Higher tiers still win.
        trip.aiGeneratedTitle = "Cycladic Summer"
        #expect(trip.displayName == "Cycladic Summer")
        trip.customName = "Honeymoon"
        #expect(trip.displayName == "Honeymoon")
    }

    // MARK: - computeHeuristicBacklogCount

    @Test("counts only trips that are heuristic AND not user-edited")
    func backlogCountsHeuristicUnedited() {
        let count = TripsListView.computeHeuristicBacklogCount([
            (classifiedByAI: false, userEdited: false),   // counts
            (classifiedByAI: false, userEdited: false),   // counts
            (classifiedByAI: true, userEdited: false),    // AI — excluded
            (classifiedByAI: false, userEdited: true),    // edited — excluded
            (classifiedByAI: true, userEdited: true),     // both — excluded
        ])
        #expect(count == 2)
    }

    @Test("empty input → 0")
    func backlogEmpty() {
        #expect(TripsListView.computeHeuristicBacklogCount([]) == 0)
    }

    // MARK: - computeFMUpgradeCardVisible

    private let transitionDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("upgrade-card visibility: baseline shows; each blocking condition hides", arguments: [
        (true, true, 3, false, false, false, true),   // latched, available, backlog ≥ threshold, not dismissed, no scope
        (false, true, 5, false, false, false, false), // the unavailable→available transition never latched
        (true, false, 5, false, false, false, false), // FM is not available right now (e.g. toggled back off)
        (true, true, 5, true, false, false, false),   // dismissed
        (true, true, 5, false, true, false, false),   // searching (list scoped to real trips)
        (true, true, 5, false, false, true, false),   // filters active (same rule as the Upcoming card)
    ])
    func cardVisibilityMatrix(latched: Bool, capabilityAvailable: Bool, backlogCount: Int,
                              dismissed: Bool, isSearching: Bool, filtersActive: Bool,
                              expected: Bool) {
        #expect(
            TripsListView.computeFMUpgradeCardVisible(
                becameAvailableAt: latched ? transitionDate : nil,
                capabilityAvailable: capabilityAvailable,
                backlogCount: backlogCount,
                dismissed: dismissed,
                isSearching: isSearching,
                filtersActive: filtersActive
            ) == expected
        )
    }

    @Test("hidden below the backlog threshold, visible at it (boundary = 3)")
    func cardBacklogBoundary() {
        func visible(_ backlog: Int) -> Bool {
            TripsListView.computeFMUpgradeCardVisible(
                becameAvailableAt: transitionDate,
                capabilityAvailable: true,
                backlogCount: backlog,
                dismissed: false,
                isSearching: false,
                filtersActive: false
            )
        }
        #expect(!visible(0))
        #expect(!visible(2))
        #expect(visible(3))
        #expect(visible(4))
        #expect(TripsListView.fmUpgradeBacklogThreshold == 3)
    }
}
