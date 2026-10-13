//
//  ModelEdgeCaseTests.swift
//  TravelLogTests
//
//  Three small model edge gaps not covered by the existing suites:
//
//  1. `Stay.weather` corrupt-blob path. The getter is
//     `weatherData.flatMap { StayWeather.decoded(from: $0) }`, and
//     `StayWeather.decoded(from:)` is a `try? JSONDecoder().decode(...)`
//     that swallows decode errors and returns nil (StayWeather.swift
//     ~86-88, Stay.swift ~211-213). Existing `StayComputedPropertyTests`
//     only round-trips a *valid* blob and the nil-clear; it never feeds
//     non-JSON bytes. This proves the corrupt-blob → nil swallow.
//
//  2. `LocationPing` init defaults + `source` accessor round-trip. The
//     designated init sets `isGeocoded == false`, `isProcessed == false`,
//     and `sourceRaw == "liveSLC"`. The `source` getter decodes via
//     `DataSource.decode`, so an unknown token falls back to `.liveSLC`
//     (LocationPing.swift ~46-81). No dedicated LocationPing accessor
//     test exists in the suite.
//
//  3. `Trip.recomputeSummary()` all-`.merged` branch. The existing
//     `TripDisplayAndSummaryTests` covers all-liveSLC, all-photoImport,
//     mixed (→ merged via the else), and empty - but NOT the case where
//     every stay is itself already `.merged`. That hits the `allSame`
//     true branch resolving to `firstSource.rawValue` (== "merged"),
//     which is a distinct code path from the mixed-source
//     `DataSource.merged.rawValue` else (Trip.swift ~234-238).
//
//  `@MainActor` because the app target compiles MainActor-by-default,
//  which makes `@Model` types (Stay/Trip/LocationPing) MainActor-isolated;
//  touching them off-main would not compile. A TestSupport in-memory
//  container is used only for the Trip case, which links stays via the
//  `Stay.trip` relationship (matching the existing recomputeSummary tests).
//

import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import TravelLog

@MainActor
struct ModelEdgeCaseTests {

    // Deterministic fixture date - Date(timeIntervalSinceReferenceDate:)
    // avoids any wall-clock dependence.
    static let t0 = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func makeStay(source: DataSource = .liveSLC) -> Stay {
        Stay(
            startTime: Self.t0,
            endTime: Self.t0.addingTimeInterval(3_600),
            centroidLatitude: 0,
            centroidLongitude: 0,
            h3IndexRes6: "hex",
            pingCount: 1,
            distanceFromHomeKm: 0,
            pingIDs: [],
            source: source
        )
    }

    // MARK: - (1) Stay.weather corrupt-blob swallow

    @Test("Stay.weather returns nil when weatherData holds non-JSON bytes (try? swallow)")
    func weatherCorruptBlobDecodesToNil() {
        let stay = makeStay()
        // Bytes of a plain string that is not valid StayWeather JSON.
        stay.weatherData = Data("not-json".utf8)
        // The data is present (non-nil), so flatMap runs the decode, which
        // throws and is swallowed by `try?` → nil. Distinct from the
        // weatherData == nil path (flatMap short-circuits, also nil).
        #expect(stay.weatherData != nil)
        #expect(stay.weather == nil)
    }

    // MARK: - (2) LocationPing init defaults + source accessor

    @Test("LocationPing init defaults: isGeocoded/isProcessed false, source liveSLC")
    func locationPingInitDefaults() {
        let ping = LocationPing(
            timestamp: Self.t0,
            latitude: 37.9838,
            longitude: 23.7275,
            horizontalAccuracy: 10,
            h3IndexRes6: "hex"
        )
        #expect(ping.isGeocoded == false)
        #expect(ping.isProcessed == false)
        #expect(ping.sourceRaw == "liveSLC")
        #expect(ping.source == .liveSLC)
    }

    @Test("LocationPing.source: unknown raw decodes to .liveSLC; setter writes raw")
    func locationPingSourceAccessorRoundTrip() {
        let ping = LocationPing(
            timestamp: Self.t0,
            latitude: 0,
            longitude: 0,
            horizontalAccuracy: 0,
            h3IndexRes6: "hex"
        )
        // Unknown future token → safe fallback, no crash.
        ping.sourceRaw = "future-unknown-token"
        #expect(ping.source == .liveSLC)

        // Typed setter writes through to the backing raw string.
        ping.source = .photoImport
        #expect(ping.sourceRaw == "photoImport")
        #expect(ping.source == .photoImport)
    }

    // MARK: - (3) Trip.recomputeSummary all-.merged branch

    @Test("recomputeSummary: two stays both .merged → sourceRaw \"merged\" (allSame branch)")
    func recomputeSummaryAllMergedStaysIsMerged() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)

        let trip = Trip(startDate: Self.t0)
        context.insert(trip)

        let a = makeStay(source: .merged)
        let b = makeStay(source: .merged)
        context.insert(a); a.trip = trip; a.orderInTrip = 0; a.category = .destination
        context.insert(b); b.trip = trip; b.orderInTrip = 1; b.category = .destination

        // Sanity: both constituent stays really are .merged.
        #expect(a.source == .merged)
        #expect(b.source == .merged)

        trip.recomputeSummary()

        // allSatisfy(==firstSource) is true, so sourceRaw = firstSource.rawValue
        // ("merged"). This is the all-same-on-merged branch, distinct from the
        // mixed-source else that hard-codes DataSource.merged.rawValue.
        #expect(trip.sourceRaw == "merged")
        #expect(trip.source == .merged)
    }
}
