import Testing
import Foundation
@testable import TravelLog

/// A ping save moves the map token without touching any stay or hex, so an
/// identical load must not rebuild geometry or repaint the overlay.
@Suite("Map republish skip")
struct HexMapRepublishTests {
    private static let date = Date(timeIntervalSince1970: 1_750_000_000)

    private static func row(
        _ id: String,
        locality: String? = nil,
        visitCount: Int = 1
    ) -> HexVisitSnapshot {
        HexVisitSnapshot(
            h3Index: id, locality: locality, country: "Greece", isoCountryCode: "GR",
            firstVisited: date, lastVisited: date.addingTimeInterval(3600),
            visitCount: visitCount, centerLatitude: 37.9, centerLongitude: 23.7
        )
    }

    private static let rows = [row("a", visitCount: 3), row("b")]

    private static func needs(
        hasLoaded: Bool = true,
        previousMax: Int = 3,
        next: [HexVisitSnapshot],
        nextMax: Int = 3
    ) -> Bool {
        HexMapView.needsRepublish(
            hasLoaded: hasLoaded,
            previousRows: rows,
            previousMax: previousMax,
            next: HexMapDataLoader.Snapshot(rows: next, overlays: [], maxCount: nextMax)
        )
    }

    @Test func identicalFrameSkips() {
        #expect(!Self.needs(next: Self.rows))
    }

    @Test func firstLoadPublishes() {
        #expect(Self.needs(hasLoaded: false, next: Self.rows))
    }

    @Test func visitCountChangePublishes() {
        #expect(Self.needs(next: [Self.row("a", visitCount: 3), Self.row("b", visitCount: 2)]))
    }

    @Test func localityFillPublishes() {
        #expect(Self.needs(next: [Self.row("a", visitCount: 3), Self.row("b", locality: "Athens")]))
    }

    @Test func hiddenOrRowSetChangePublishes() {
        #expect(Self.needs(next: [Self.row("a", visitCount: 3)]))
        #expect(Self.needs(next: Self.rows + [Self.row("c")]))
    }

    @Test func maxChangePublishes() {
        #expect(Self.needs(next: Self.rows, nextMax: 4))
    }
}
