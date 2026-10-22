//
//  StayClustererDateLineTests.swift
//  TravelLogTests
//
//  A stay near the date line keeps its place's calendar day however far
//  from it the pings are clustered: the geocoded country, not the longitude
//  alone, decides which side of the line the stay's zone falls on.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct StayClustererDateLineTests {

    nonisolated private static func geocode(_ country: String, _ code: String) -> GeocodeResolver.Result {
        GeocodeResolver.Result(country: country, isoCountryCode: code, administrativeArea: nil,
            metroName: nil, localityName: nil, subLocalityName: nil, islandName: nil)
    }

    private static let newYearsDay = TravelDays.labelCalendar.date(
        from: DateComponents(year: 2027, month: 1, day: 1))

    private static func dayLabel(of stay: Stay) -> Date? {
        TravelDays.label(for: stay.startTime, zone: StayTimeZone.resolve(stay.timeZoneIdentifier))
    }

    private static func insertPing(_ context: ModelContext, at timestamp: Date,
                                   latitude: Double, longitude: Double, source: DataSource) {
        context.insert(LocationPing(
            timestamp: timestamp, latitude: latitude, longitude: longitude, horizontalAccuracy: 10,
            h3IndexRes6: H3Service.cellIndex(latitude: latitude, longitude: longitude)!,
            source: source))
    }

    /// Clusters every pending ping and visit with the offline geocoder
    /// pinned to `result`. The device zone is whatever the test host runs
    /// in: each scenario lands on the same day for any device zone.
    private func clusteredStay(_ container: ModelContainer, geocode result: GeocodeResolver.Result) async throws -> Stay {
        let clusterer = StayClusterer(modelContainer: container)
        let outcome = await GeocodeResolver.TestHook.$resolve.withValue({ _, _ in result }) {
            await PipelineGate.shared.runReturning(touching: []) {
                await clusterer.clusterUnprocessedPingsReportingChanges()
            }
        }
        #expect(outcome.created == 1 && !outcome.failed)
        return try #require(ModelContext(container).fetch(FetchDescriptor<Stay>()).first)
    }

    @Test("a live Kiritimati stay clustered away from Kiribati keeps New Year's Day")
    func liveStayKeepsTheDateLineDate() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // 2027-01-01 10:00 in Kiritimati (UTC+14); solar time there is UTC-10.
        Self.insertPing(context, at: Date(timeIntervalSince1970: 1_798_747_200),
                        latitude: 1.98487, longitude: -157.47502, source: .liveSLC)
        try context.save()

        let stay = try await clusteredStay(container, geocode: Self.geocode("Kiribati", "KI"))
        #expect(stay.source == .liveSLC)
        #expect(Self.dayLabel(of: stay) == Self.newYearsDay)
    }

    @Test("a visit-only Tonga stay takes its country from the geocoder and keeps its day")
    func visitStayKeepsTheDateLineDate() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // 2027-01-01 12:00 to 14:00 in Nuku'alofa (UTC+13).
        let arrival = Date(timeIntervalSince1970: 1_798_758_000)
        context.insert(Visit(arrivalDate: arrival, departureDate: arrival.addingTimeInterval(7_200),
                             latitude: -21.13683, longitude: -175.20114, horizontalAccuracy: 20,
                             receivedAt: arrival.addingTimeInterval(7_200)))
        try context.save()

        let stay = try await clusteredStay(container, geocode: Self.geocode("Tonga", "TO"))
        #expect(stay.isoCountryCode == "TO")
        #expect(Self.dayLabel(of: stay) == Self.newYearsDay)
    }

    @Test("an imported Samoa photo lands on its Samoan day")
    func importedStayKeepsTheDateLineDate() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // 2027-01-01 03:00 in Apia (UTC+13); solar time there is UTC-11.
        Self.insertPing(context, at: Date(timeIntervalSince1970: 1_798_725_600),
                        latitude: -13.83333, longitude: -171.76666, source: .photoImport)
        try context.save()

        let stay = try await clusteredStay(container, geocode: Self.geocode("Samoa", "WS"))
        #expect(stay.source == .photoImport)
        #expect(stay.timeZoneIdentifier == TimeZone(secondsFromGMT: 13 * 3600)!.identifier)
        #expect(Self.dayLabel(of: stay) == Self.newYearsDay)
    }

    @Test("an imported pre-2012 Samoa photo keeps its Samoan day")
    func importedPreSwitchStayKeepsItsDate() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        // 2009-12-31 12:00 UTC: 01:00 on December 31 in Apia, then UTC-11.
        Self.insertPing(context, at: Date(timeIntervalSince1970: 1_262_260_800),
                        latitude: -13.83333, longitude: -171.76666, source: .photoImport)
        try context.save()

        let stay = try await clusteredStay(container, geocode: Self.geocode("Samoa", "WS"))
        #expect(stay.timeZoneIdentifier == TimeZone(secondsFromGMT: -11 * 3600)!.identifier)
        #expect(Self.dayLabel(of: stay)
                == TravelDays.labelCalendar.date(from: DateComponents(year: 2009, month: 12, day: 31)))
    }

    @Test("the shipped geocoder names the country of date-line towns")
    func shippedGeocoderPlacesDateLineTowns() async throws {
        let towns: [(latitude: Double, longitude: Double, code: String, zone: String)] = [
            (1.98487, -157.47502, "KI", "Pacific/Kiritimati"),  // London Village
            (-13.83333, -171.76666, "WS", "Pacific/Apia"),
            (-9.38516, -171.24675, "TK", "Pacific/Fakaofo"),
            (-21.13683, -175.20114, "TO", "Pacific/Tongatapu"),
            (-13.28163, -176.17453, "WF", "Pacific/Wallis"),
            (-18.23652, -178.81232, "FJ", "Pacific/Fiji"),       // Tubou, Lakeba
            (-43.95353, -176.55973, "NZ", "Pacific/Chatham"),    // Waitangi
            (65.58299, -170.99663, "RU", "Asia/Anadyr"),        // Lavrentiya
            (52.72, 174.11, "US", "America/Adak"),               // Shemya
            (-14.27806, -170.7025, "AS", "Pacific/Pago_Pago"),
        ]
        let date = Date(timeIntervalSince1970: 1_798_747_200)
        for town in towns {
            let result = try #require(await GeocodeResolver.shared.resolve(
                latitude: town.latitude, longitude: town.longitude), "\(town.zone)")
            #expect(result.isoCountryCode == town.code, "\(town.zone)")
            let approximate = StayTimeZone.approximateZone(
                forLongitude: town.longitude, isoCountryCode: result.isoCountryCode, at: date)
            let political = TimeZone(identifier: town.zone)!
            #expect(TravelDays.label(for: date, zone: approximate) == TravelDays.label(for: date, zone: political),
                    "\(town.zone)")
        }
    }
}
