//
//  PinnedOverlayFilterTests.swift
//  TravelLogTests
//
//  The pure pinned-overlay filter used by `TripDetailView.photosSection`
//  instead of a per-render SwiftData fetch.
//

import Testing
import Foundation
import Photos
@testable import TravelLog

/// PHAsset stub: `localIdentifier`/`creationDate` are plain readonly
/// properties on PHObject/PHAsset, overridable in a subclass; the standard
/// PhotoKit stubbing seam (no framework calls are faked).
private final class StubPHAsset: PHAsset, @unchecked Sendable {
    private let stubID: String
    private let stubDate: Date?

    init(id: String, date: Date?) {
        self.stubID = id
        self.stubDate = date
        super.init()
    }

    override var localIdentifier: String { stubID }
    override var creationDate: Date? { stubDate }
}

@MainActor
struct PinnedOverlayFilterTests {

    private func group(stayStart: Date, assets: [PHAsset]) -> StayPhotos {
        StayPhotos(
            stayID: UUID(),
            stayLocality: nil,
            stayStartTime: stayStart,
            assets: assets
        )
    }

    @Test("empty pinned set short-circuits to []")
    func emptyPinnedSet() {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let groups = [group(stayStart: base, assets: [StubPHAsset(id: "a", date: base)])]
        #expect(PhotoService.pinnedAssets(in: groups, pinnedIdentifiers: []).isEmpty)
    }

    @Test("filters across groups and sorts chronologically")
    func filtersAndSorts() {
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        let early = StubPHAsset(id: "early", date: base)
        let middle = StubPHAsset(id: "middle", date: base.addingTimeInterval(600))
        let late = StubPHAsset(id: "late", date: base.addingTimeInterval(1200))
        let unpinned = StubPHAsset(id: "unpinned", date: base.addingTimeInterval(300))

        // Later stay listed first: the sort, not group order, must decide.
        let groups = [
            group(stayStart: base.addingTimeInterval(1000), assets: [late, middle]),
            group(stayStart: base, assets: [early, unpinned]),
        ]

        let pinned = PhotoService.pinnedAssets(
            in: groups,
            pinnedIdentifiers: ["early", "middle", "late"]
        )
        #expect(pinned.map(\.localIdentifier) == ["early", "middle", "late"])
    }
}
