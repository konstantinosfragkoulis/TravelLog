//
//  TripSnapshotMappingTests.swift
//  TravelLogTests
//
//  TripSnapshot.init(from:) — the Sendable value-type mirror of a Trip built
//  on the main actor before being handed to the AI search path. Verifies the
//  verbatim field copies (id/name/dates/duration/completion), ISO-code parse
//  + trim + empty-filter, ISO→en_US English-name expansion (order follows
//  codes), insertion-order dedup of stay localities / admin areas, and the
//  place names (summary entries plus destination/unclassified metro and
//  island names) the AI tool's locality filter searches.
//  Constructs Trip/Stay @Model objects, so this suite is @MainActor (the app
//  target is MainActor-by-default → @Model types are MainActor-isolated).
//

import Testing
import Foundation
import SwiftData
@testable import TravelLog

@MainActor
struct TripSnapshotMappingTests {

    private func day(_ year: Int, _ month: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: d, hour: 12))!
    }

    private func makeTrip(in ctx: ModelContext, start: Date) -> Trip {
        let trip = Trip(startDate: start)
        ctx.insert(trip)
        return trip
    }

    private func addDestination(
        to trip: Trip,
        in ctx: ModelContext,
        order: Int,
        locality: String? = nil,
        admin: String? = nil
    ) {
        let stay = Stay(startTime: trip.startDate, endTime: trip.startDate,
                        centroidLatitude: 0, centroidLongitude: 0,
                        h3IndexRes6: "8a000", pingCount: 1, distanceFromHomeKm: 0,
                        pingIDs: [])
        ctx.insert(stay)
        stay.category = .destination
        stay.locality = locality
        stay.administrativeArea = admin
        stay.trip = trip
        stay.orderInTrip = order
    }

    private func addStay(
        to trip: Trip,
        in ctx: ModelContext,
        order: Int,
        category: StayCategory,
        metroName: String? = nil,
        islandName: String? = nil
    ) {
        let stay = Stay(startTime: trip.startDate, endTime: trip.startDate,
                        centroidLatitude: 0, centroidLongitude: 0,
                        h3IndexRes6: "8a000", pingCount: 1, distanceFromHomeKm: 0,
                        pingIDs: [])
        ctx.insert(stay)
        stay.category = category
        stay.metroName = metroName
        stay.islandName = islandName
        stay.trip = trip
        stay.orderInTrip = order
    }

    @Test("snapshot copies id, names, dates, duration, and completion verbatim")
    func snapshotCopiesIdNameDatesAndCompletion() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 3, 13))
        trip.customName = "Spring Break"
        trip.destinationSummary = "London, Oxford"
        trip.endDate = day(2024, 3, 16)
        trip.isComplete = true

        let snap = TripSnapshot(from: trip)
        #expect(snap.id == trip.id)
        #expect(snap.displayName == trip.displayName)
        #expect(snap.destinationSummary == "London, Oxford")
        #expect(snap.startDate == trip.startDate)
        #expect(snap.endDate == trip.endDate)
        #expect(snap.durationDays == trip.durationDays)
        #expect(snap.isComplete == true)
    }

    @Test("snapshot parses and trims country ISO codes, filtering empties")
    func snapshotParsesAndTrimsCountryISOCodes() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2023, 12, 4))
        trip.countryCodes = " GR , IT "

        let snap = TripSnapshot(from: trip)
        #expect(snap.countryISOCodes == ["GR", "IT"])
    }

    @Test("snapshot expands ISO codes to English country names in code order")
    func snapshotExpandsEnglishCountryNames() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2023, 12, 4))
        trip.countryCodes = "GR,IT"

        let snap = TripSnapshot(from: trip)
        #expect(snap.englishCountryNames == ["Greece", "Italy"])
    }

    @Test("snapshot deduplicates stay localities and admin areas (insertion order)")
    func snapshotDeduplicatesLocalitiesAndAdminAreas() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2023, 12, 4))
        addDestination(to: trip, in: ctx, order: 0, locality: "Athens", admin: "Attica")
        addDestination(to: trip, in: ctx, order: 1, locality: "Athens", admin: "Attica")

        let snap = TripSnapshot(from: trip)
        #expect(snap.localityList == ["Athens"])
        #expect(snap.administrativeAreaList == ["Attica"])
    }

    @Test("empty countryCodes yields empty code and English-name arrays")
    func snapshotEmptyCountryCodesYieldsEmptyArrays() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2023, 12, 4))
        trip.countryCodes = ""

        let snap = TripSnapshot(from: trip)
        #expect(snap.countryISOCodes.isEmpty)
        #expect(snap.englishCountryNames.isEmpty)
    }

    @Test("an ongoing trip mirrors endDate and durationDays as nil")
    func snapshotMirrorsOngoingDurationAsNil() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2023, 12, 4)) // endDate nil

        let snap = TripSnapshot(from: trip)
        #expect(snap.endDate == nil)
        #expect(snap.durationDays == nil)
    }

    @Test("place names: summary entries, then destination and unclassified metro and island names, dedup'd")
    func snapshotCollectsPlaceNames() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 6, 3))
        trip.destinationSummary = "Athens, Cephalonia"
        addStay(to: trip, in: ctx, order: 0, category: .destination, metroName: "Athens")
        addStay(to: trip, in: ctx, order: 1, category: .destination, islandName: "Cephalonia")
        addStay(to: trip, in: ctx, order: 2, category: .unclassified, islandName: "Samos")
        addStay(to: trip, in: ctx, order: 3, category: .transit, metroName: "Doha")
        addStay(to: trip, in: ctx, order: 4, category: .home, metroName: "London")

        let snap = TripSnapshot(from: trip)
        #expect(snap.placeNames == ["Athens", "Cephalonia", "Samos"])
    }

    @Test("place names skip the unknown-destination sentinel")
    func snapshotPlaceNamesSkipUnknownSentinel() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let trip = makeTrip(in: ctx, start: day(2024, 6, 3))
        trip.destinationSummary = Trip.unknownDestinationSentinel

        let snap = TripSnapshot(from: trip)
        #expect(snap.placeNames.isEmpty)
    }
}
