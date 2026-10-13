//
//  PhotoServiceStayShapeTokenTests.swift
//  TravelLogTests
//
//  `PhotoService.stayShapeToken` self-invalidates the per-trip photo cache
//  when the reused ongoing row's stays accrete, extend, reclassify, or the
//  trip closes (stable `Trip.id` no longer implies a stable photo set).
//
//  `@MainActor` because the app target compiles MainActor-by-default →
//  `@Model` types are MainActor-isolated.
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct PhotoServiceStayShapeTokenTests {

    private func makeStay(start: Date, end: Date) -> Stay {
        Stay(
            startTime: start,
            endTime: end,
            centroidLatitude: 37.98,
            centroidLongitude: 23.72,
            h3IndexRes6: "861f01a07ffffff",
            pingCount: 4,
            distanceFromHomeKm: 250,
            pingIDs: []
        )
    }

    @Test("token is stable for an unchanged trip and moves on every photo-relevant mutation")
    func tokenTracksStayShape() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)

        let base = Date(timeIntervalSince1970: 1_735_484_800)
        let trip = Trip(startDate: base)
        ctx.insert(trip)
        let first = makeStay(start: base, end: base.addingTimeInterval(7200))
        ctx.insert(first)
        first.trip = trip

        let initial = PhotoService.stayShapeToken(for: trip)
        #expect(PhotoService.stayShapeToken(for: trip) == initial,
                "same shape must produce the same token within a process")

        // Pipeline appends a stay to the reused ongoing row (stable id).
        let second = makeStay(
            start: base.addingTimeInterval(10_000),
            end: base.addingTimeInterval(14_000)
        )
        ctx.insert(second)
        second.trip = trip
        let afterAppend = PhotoService.stayShapeToken(for: trip)
        #expect(afterAppend != initial)

        // A wake ping extends the last stay's endTime.
        second.endTime = second.endTime.addingTimeInterval(3600)
        let afterExtend = PhotoService.stayShapeToken(for: trip)
        #expect(afterExtend != afterAppend)

        // Reclassification flips a category without changing the stay set.
        first.categoryRaw = StayCategory.destination.rawValue
        let afterReclassify = PhotoService.stayShapeToken(for: trip)
        #expect(afterReclassify != afterExtend)

        trip.endDate = base.addingTimeInterval(20_000)
        let afterClose = PhotoService.stayShapeToken(for: trip)
        #expect(afterClose != afterReclassify)

        // Geocoding fills the header locality in place.
        first.locality = "Athens"
        let afterLocality = PhotoService.stayShapeToken(for: trip)
        #expect(afterLocality != afterClose)
    }
}
