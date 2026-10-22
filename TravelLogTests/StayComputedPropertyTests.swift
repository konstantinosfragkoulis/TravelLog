//
//  StayComputedPropertyTests.swift
//  TravelLogTests
//
//  Stored-format accessors on `Stay`: the comma-joined `pingIDsString` and
//  the `weatherData` JSON blob. Both are persisted and synced, so a change
//  here corrupts existing rows. Also the branch boundaries of the
//  user-visible `formattedDuration`.
//

import Testing
import Foundation
@testable import TravelLog

@MainActor
struct StayComputedPropertyTests {

    static let u1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let u2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let u3 = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    /// Builds a Stay whose `durationMinutes` is derived from the start/end
    /// interval (init computes `Int(interval / 60)`).
    private func makeStay(minutes: Int) -> Stay {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end = start.addingTimeInterval(TimeInterval(minutes) * 60)
        return Stay(startTime: start, endTime: end,
                    centroidLatitude: 0, centroidLongitude: 0,
                    h3IndexRes6: "hex", pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
    }

    private func makeStay(lat: Double, lon: Double, hex: String) -> Stay {
        Stay(startTime: .now, endTime: .now,
             centroidLatitude: lat, centroidLongitude: lon,
             h3IndexRes6: hex, pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
    }

    // MARK: - formattedDuration

    @Test("formattedDuration renders each branch and boundary", arguments: [
        (45, "45m"),                  // sub-hour → minutes only
        (0, "0m"),                    // lower boundary of the <60 branch
        (59, "59m"),                  // upper boundary of the <60 branch
        (60, "1h"),                   // hours branch, no minute remainder
        (200, "3h 20m"),              // hours <24 with remainder
        (1439, "23h 59m"),            // upper boundary of the <24h branch
        (1440, "1d"),                 // days branch, no hour remainder
        (2 * 1440 + 5 * 60, "2d 5h"), // days branch with remainder (doc example)
    ])
    func formattedDurationBranches(minutes: Int, expected: String) {
        #expect(makeStay(minutes: minutes).formattedDuration == expected)
    }

    // MARK: - pingIDs round-trip

    @Test("empty pingIDs → empty pingIDsString → getter returns [] (guard short-circuit)")
    func pingIDsEmptyStringRoundTripsToEmptyArray() {
        let stay = makeStay(lat: 0, lon: 0, hex: "hex")
        #expect(stay.pingIDsString == "")
        #expect(stay.pingIDs == [])
    }

    @Test("setter comma-joins uuidStrings, getter splits back in order (round-trip identity)")
    func pingIDsSetterJoinsAndGetterSplits() {
        let stay = makeStay(lat: 0, lon: 0, hex: "hex")
        stay.pingIDs = [Self.u1, Self.u2, Self.u3]
        #expect(stay.pingIDsString == [Self.u1, Self.u2, Self.u3].map(\.uuidString).joined(separator: ","))
        #expect(stay.pingIDs == [Self.u1, Self.u2, Self.u3])
    }

    @Test("getter compactMap drops a non-UUID token (defensive parse)")
    func pingIDsGetterDropsMalformedTokens() {
        let stay = makeStay(lat: 0, lon: 0, hex: "hex")
        stay.pingIDsString = "\(Self.u1.uuidString),garbage,\(Self.u2.uuidString)"
        #expect(stay.pingIDs == [Self.u1, Self.u2])
    }

    // MARK: - weather blob

    @Test("weather round-trips through weatherData blob; setting nil clears it")
    func weatherBlobRoundTrip() throws {
        let stay = makeStay(lat: 0, lon: 0, hex: "hex")
        let value = StayWeather(condition: .partlyCloudy,
                                temperatureMinC: 12.5, temperatureMaxC: 24.0,
                                temperatureAvgC: 18.25, precipitationMm: 3.2,
                                windSpeedMs: 4.1, humidity: 0.65, isCacheHit: true)
        stay.weather = value
        #expect(stay.weatherData != nil)
        let decoded = try #require(stay.weather)
        #expect(decoded == value)

        stay.weather = nil
        #expect(stay.weatherData == nil)
        #expect(stay.weather == nil)
    }
}
