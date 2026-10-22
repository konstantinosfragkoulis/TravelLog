//
//  PhotoViewerVisibilityTests.swift
//  TravelLogTests
//
//  The rules an open photo viewer reconciles with: a photo hidden on the trip
//  (say, from another device) leaves a normal viewer, an unhidden one leaves
//  the Hidden Photos viewer, an unreadable hidden list closes a normal viewer
//  rather than read as "nothing hidden", and the selection lands predictably.
//

import Testing
@testable import TravelLog

@Suite("Photo viewer visibility")
struct PhotoViewerVisibilityTests {

    private let ids = ["A", "B", "C"]
    private var all: Set<String> { Set(ids) }

    @Test("a photo hidden while a normal viewer is open leaves it; the rest keep their order")
    func hiddenPhotoLeavesNormalViewer() {
        #expect(PhotoViewerVisibility.visibleIDs(
            among: ids, existing: all, hidden: ["A"], isShowingHidden: false) == ["B", "C"])
        // Pin-only and unrelated changes leave the set as it was.
        #expect(PhotoViewerVisibility.visibleIDs(
            among: ids, existing: all, hidden: ["Z"], isShowingHidden: false) == ids)
        #expect(PhotoViewerVisibility.visibleIDs(
            among: ids, existing: all, hidden: [], isShowingHidden: false) == ids)
        // Deletion from the library still removes a photo.
        #expect(PhotoViewerVisibility.visibleIDs(
            among: ids, existing: ["A", "C"], hidden: ["C"], isShowingHidden: false) == ["A"])
        #expect(PhotoViewerVisibility.visibleIDs(
            among: ids, existing: all, hidden: all, isShowingHidden: false) == [])
    }

    @Test("the Hidden Photos viewer keeps only photos still hidden")
    func hiddenViewerUsesInverseMembership() {
        #expect(PhotoViewerVisibility.visibleIDs(
            among: ids, existing: all, hidden: ["A", "C"], isShowingHidden: true) == ["A", "C"])
        #expect(PhotoViewerVisibility.visibleIDs(
            among: ids, existing: ["A"], hidden: all, isShowingHidden: true) == ["A"])
    }

    @Test("an unreadable hidden list closes a normal viewer and never reads as nothing hidden")
    func unreadableHiddenListFailsClosed() {
        #expect(PhotoViewerVisibility.visibleIDs(
            among: ids, existing: all, hidden: nil, isShowingHidden: false) == nil)
        // A share decode that finishes then is refused the same way.
        #expect(PhotoViewerVisibility.visibleIDs(
            among: ["A"], existing: ["A"], hidden: nil, isShowingHidden: false) == nil)
        // The Hidden Photos viewer shows only photos that were hidden; it
        // keeps what still exists.
        #expect(PhotoViewerVisibility.visibleIDs(
            among: ids, existing: ["B"], hidden: nil, isShowingHidden: true) == ["B"])
    }

    @Test("a share whose photo was hidden during the decode is refused")
    func lateShareIsRevoked() {
        #expect(PhotoViewerVisibility.visibleIDs(
            among: ["A"], existing: ["A"], hidden: ["A"], isShowingHidden: false) == [])
        #expect(PhotoViewerVisibility.visibleIDs(
            among: ["A"], existing: ["A"], hidden: ["B"], isShowingHidden: false) == ["A"])
    }

    @Test("the selection stays, moves to the survivor at its place, or closes")
    func selectionAdvancesPredictably() {
        let ids = ["A", "B", "C", "D"]
        #expect(PhotoViewerVisibility.selection(after: "B", in: ids, survivors: ["B", "C"]) == "B")
        #expect(PhotoViewerVisibility.selection(after: "B", in: ids, survivors: ["A", "C", "D"]) == "C")
        #expect(PhotoViewerVisibility.selection(after: "D", in: ids, survivors: ["A", "B"]) == "B")
        #expect(PhotoViewerVisibility.selection(after: "A", in: ids, survivors: ["B", "C", "D"]) == "B")
        #expect(PhotoViewerVisibility.selection(after: "X", in: ids, survivors: ["C"]) == "C")
        #expect(PhotoViewerVisibility.selection(after: "A", in: ids, survivors: []) == nil)
    }

    /// An open viewer sharing "A" when "A" is hidden on the trip from
    /// another device, its reconciliation suspended on the library fetch.
    @MainActor
    @Test("an open share of a photo hidden meanwhile is withdrawn before the library fetch answers",
          arguments: [true, false])
    func hiddenShareIsWithdrawnBeforeFetch(newerPassStarted: Bool) async {
        var shown = ["A", "B", "C"]
        var sharing: String? = "A"
        var hidden: Set<String> = ["A"]
        var shownDuringFetch: [String] = []
        var sharingDuringFetch: String?
        var passes = 0
        await PhotoViewerVisibility.reconcile(
            ids: shown,
            fetchExisting: {
                shownDuringFetch = shown
                sharingDuringFetch = sharing
                // A second hide lands while PhotoKit answers; "C" left the library.
                hidden.insert("B")
                return ["A", "B"]
            },
            isCurrent: { !newerPassStarted },
            apply: { existing in
                passes += 1
                guard let visible = PhotoViewerVisibility.visibleIDs(
                    among: shown, existing: existing, hidden: hidden, isShowingHidden: false)
                else { return false }
                if let id = sharing, !visible.contains(id) { sharing = nil }
                shown = visible
                return !visible.isEmpty
            })
        #expect(sharingDuringFetch == nil, "the share sheet is gone before the fetch answers")
        #expect(shownDuringFetch == ["B", "C"])
        #expect(sharing == nil)
        // The post-fetch recheck rereads hidden photos and applies the library,
        // unless a newer pass took over.
        #expect(passes == (newerPassStarted ? 1 : 2))
        #expect(shown == (newerPassStarted ? ["B", "C"] : []))
    }

    @MainActor
    @Test("a viewer the hidden-photo pass closes never waits on the library fetch")
    func closedViewerSkipsFetch() async {
        var fetched = false
        await PhotoViewerVisibility.reconcile(
            ids: ["A"],
            fetchExisting: { fetched = true; return ["A"] },
            isCurrent: { true },
            apply: { _ in false })
        #expect(!fetched)
    }
}
