//
//  MapTabRouter.swift
//  TravelLog
//

import Foundation
import SwiftUI

// MARK: - Highlight request

/// What the Stats page asks the hex map to highlight. The map cannot enter
/// a highlight mode on its own — only a Stats tap routes one in.
nonisolated enum HexHighlightRequest: Equatable, Sendable {

    /// "Greece — 57 hexes": every hex whose `HexVisit.isoCountryCode`
    /// matches.
    case country(code: String, name: String?)

    /// "New this year +12": every hex first visited in the current
    /// calendar year.
    case newThisYear

    var label: String {
        switch self {
        case .country(let code, let name):
            return AppLanguagePreference.currentLocale()
                .localizedString(forRegionCode: code)
                ?? name
                ?? code
        case .newThisYear:
            return String(
                localized: "map.highlight.new-this-year",
                defaultValue: "New this year",
                comment: "Map highlight label for places first visited this year."
            )
        }
    }

    /// Sendable value mirror of the `HexVisit` fields the matcher needs —
    /// keeps the matching pure and unit-testable.
    nonisolated struct HexRow: Sendable {
        let h3Index: String
        let isoCountryCode: String?
        let firstVisited: Date
    }

    /// Which hex indices does this request select? Pure; `now`/`calendar`
    /// injected so the year boundary is deterministic under test. The year
    /// is Gregorian, matching Stats; `calendar` supplies only the time zone.
    func matchingHexIndices(
        in rows: [HexRow],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Set<String> {
        switch self {
        case .country(let code, _):
            return Set(rows.filter { $0.isoCountryCode == code }.map(\.h3Index))
        case .newThisYear:
            var gregorian = TravelDays.labelCalendar
            gregorian.timeZone = calendar.timeZone
            guard let yearStart = gregorian.date(
                from: gregorian.dateComponents([.year], from: now)
            ) else { return [] }
            return Set(rows.filter { $0.firstVisited >= yearStart }.map(\.h3Index))
        }
    }
}

// MARK: - Router

/// Cross-tab signal: Stats → Map hex highlighting. Same single-set /
/// single-consume pattern as `TripsTabRouter`: a Stats tap sets the
/// request, `MainTabView` observes it and switches to the Map tab, and
/// `HexMapView` consumes it (computes the highlight set, shows the
/// dismissal chip) and clears the router so the same request doesn't
/// re-fire on subsequent tab switches.
@MainActor
@Observable
final class MapTabRouter {

    static let shared = MapTabRouter()

    private init() {}

    var requestedHighlight: HexHighlightRequest?

    func requestHighlight(_ request: HexHighlightRequest) {
        requestedHighlight = request
    }

    func clear() {
        requestedHighlight = nil
    }
}
