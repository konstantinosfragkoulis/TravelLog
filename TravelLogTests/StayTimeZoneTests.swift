//
//  StayTimeZoneTests.swift
//  TravelLogTests
//
//  The zone a stay is stamped with (V18): the device zone for live
//  observations, a longitude-derived fixed offset for imported history, and
//  the device-zone fallback for rows that carry nothing.
//

import Foundation
import Testing
@testable import TravelLog

struct StayTimeZoneTests {

    /// 2026-07-15 12:00 UTC, so DST zones are on summer time.
    static let july = Date(timeIntervalSince1970: 1_784_116_800)
    /// 2026-01-15 12:00 UTC, so southern DST zones are on summer time.
    static let january = Date(timeIntervalSince1970: 1_768_478_400)

    private static func zone(_ identifier: String) -> TimeZone { TimeZone(identifier: identifier)! }

    private static func label(_ date: Date, in identifier: String) -> Date? {
        TravelDays.label(for: date, zone: StayTimeZone.resolve(identifier))
    }

    @Test("live observations take the device zone; imports take the solar offset")
    func sourceDecidesTheRule() {
        let athens = Self.zone("Europe/Athens")
        let date = Self.july
        #expect(StayTimeZone.identifier(for: .liveSLC, longitude: 23.7, isoCountryCode: "GR", at: date, deviceZone: athens) == "Europe/Athens")
        #expect(StayTimeZone.identifier(for: .foregroundStream, longitude: 23.7, isoCountryCode: "GR", at: date, deviceZone: athens) == "Europe/Athens")
        // Los Angeles at −118.2° → −8 h; Tokyo at 139.7° → +9 h; Athens at 23.7° → +2 h.
        #expect(StayTimeZone.identifier(for: .photoImport, longitude: -118.2, isoCountryCode: "US", at: date, deviceZone: athens)
                == TimeZone(secondsFromGMT: -8 * 3600)!.identifier)
        #expect(StayTimeZone.identifier(for: .timelineImport, longitude: 139.7, isoCountryCode: "JP", at: date, deviceZone: athens)
                == TimeZone(secondsFromGMT: 9 * 3600)!.identifier)
        #expect(StayTimeZone.identifier(for: .gpxImport, longitude: 23.7, isoCountryCode: nil, at: date, deviceZone: athens)
                == TimeZone(secondsFromGMT: 2 * 3600)!.identifier)
    }

    @Test("a live stay far from the device zone falls back to solar time")
    func implausibleDeviceZoneFallsBack() {
        let london = Self.zone("Europe/London")
        let losAngeles = Self.zone("America/Los_Angeles")
        // Clustered after a flight: JFK pings read in London, Tokyo pings read in California.
        for code in ["US", nil] {
            #expect(StayTimeZone.identifier(for: .liveSLC, longitude: -73.8, isoCountryCode: code, at: Self.july, deviceZone: london)
                    == TimeZone(secondsFromGMT: -5 * 3600)!.identifier)
        }
        for code in ["JP", nil] {
            #expect(StayTimeZone.identifier(for: .foregroundStream, longitude: 139.7, isoCountryCode: code, at: Self.july, deviceZone: losAngeles)
                    == TimeZone(secondsFromGMT: 9 * 3600)!.identifier)
        }
    }

    @Test("legitimate political-vs-solar gaps keep the device zone, with or without a country")
    func wideRealGapsKeepDeviceZone() {
        let cases: [(Double, String, String)] = [
            (76.0, "CN", "Asia/Shanghai"),        // Kashgar
            (-175.2, "TO", "Pacific/Tongatapu"),
            (-157.4, "KI", "Pacific/Kiritimati"),
            (-171.7, "KI", "Pacific/Kanton"),
            (-176.56, "NZ", "Pacific/Chatham"),
            (-169.8, "RU", "Asia/Anadyr"),        // Uelen
            (174.1, "US", "America/Adak"),        // Shemya
            (-8.5, "ES", "Europe/Madrid"),        // Galicia
            (-165.4, "US", "America/Nome"),
            (-51.7, "GL", "America/Nuuk"),
        ]
        for date in [Self.january, Self.july] {
            for (longitude, code, identifier) in cases {
                for country in [code, nil] {
                    #expect(StayTimeZone.identifier(
                        for: .liveSLC, longitude: longitude, isoCountryCode: country,
                        at: date, deviceZone: Self.zone(identifier)) == identifier)
                }
            }
        }
    }

    @Test("a Kiritimati stay clustered in Tokyo keeps its New Year's Day")
    func dateLineFallbackKeepsThePoliticalDate() {
        // 2027-01-01 10:00 in Kiritimati (UTC+14), 05:00 in Tokyo.
        let start = Date(timeIntervalSince1970: 1_798_747_200)
        let newYear = TravelDays.labelCalendar.date(from: DateComponents(year: 2027, month: 1, day: 1))
        let identifier = StayTimeZone.identifier(
            for: .liveSLC, longitude: -157.475, isoCountryCode: "KI",
            at: start, deviceZone: Self.zone("Asia/Tokyo"))
        #expect(Self.label(start, in: identifier) == newYear)
        #expect(Self.label(start, in: "Pacific/Kiritimati") == newYear)
    }

    /// Real places whose country decides their side of the date line, and
    /// controls on the same meridians that keep the longitude's side.
    static let dateLinePlaces: [(longitude: Double, code: String, zone: String)] = [
        (-157.475, "KI", "Pacific/Kiritimati"),
        (-171.7, "KI", "Pacific/Kanton"),
        (-171.767, "WS", "Pacific/Apia"),
        (-171.22, "TK", "Pacific/Fakaofo"),
        (-175.204, "TO", "Pacific/Tongatapu"),
        (-176.176, "WF", "Pacific/Wallis"),
        (-178.8, "FJ", "Pacific/Fiji"),         // Lakeba, Lau
        (-176.56, "NZ", "Pacific/Chatham"),
        (-177.92, "NZ", "Pacific/Auckland"),    // Raoul, Kermadec
        (-169.81, "RU", "Asia/Anadyr"),         // Uelen
        (174.11, "US", "America/Adak"),         // Shemya
        (-157.86, "US", "Pacific/Honolulu"),
        (-176.64, "US", "America/Adak"),
        (-170.7, "AS", "Pacific/Pago_Pago"),
        (-169.92, "NU", "Pacific/Niue"),
        (-159.78, "CK", "Pacific/Rarotonga"),
        (172.93, "KI", "Pacific/Tarawa"),
        (179.19, "TV", "Pacific/Funafuti"),
        (174.76, "NZ", "Pacific/Auckland"),
        (144.75, "GU", "Pacific/Guam"),
    ]

    /// Noon UTC on 1990-01-15, 1990-07-15 and 2009-07-15: before Samoa and
    /// Tokelau (2011) and eastern Kiribati (1995) crossed the date line.
    static let preSwitchDates: [Date] = [632_404_800, 648_043_200, 1_247_659_200]
        .map { Date(timeIntervalSince1970: TimeInterval($0)) }

    @Test("imported stays near the date line land on their own calendar day")
    func importsKeepTheirSideOfTheDateLine() {
        for date in [Self.january, Self.july] + Self.preSwitchDates {
            for place in Self.dateLinePlaces {
                let political = Self.zone(place.zone).secondsFromGMT(for: date)
                let approximate = StayTimeZone.approximateZone(
                    forLongitude: place.longitude, isoCountryCode: place.code, at: date)
                #expect(abs(approximate.secondsFromGMT(for: date) - political) <= 3 * 3600,
                        "\(place.zone) at \(place.longitude)")
            }
        }
        // Codes are normalized; a code far from 180° never moves a day.
        #expect(StayTimeZone.approximateZone(forLongitude: -171.767, isoCountryCode: " ws ", at: Self.july).secondsFromGMT() == 13 * 3600)
        #expect(StayTimeZone.approximateZone(forLongitude: 144.75, isoCountryCode: "US", at: Self.july).secondsFromGMT() == 10 * 3600)
        #expect(StayTimeZone.approximateZone(forLongitude: -100, isoCountryCode: "RU", at: Self.july).secondsFromGMT() == -7 * 3600)
    }

    @Test("imported stays take the side their country kept on the stay's date")
    func importsFollowDateLineHistory() {
        let year1990 = Date(timeIntervalSince1970: 632_404_800)  // 1990-01-15 12:00 UTC
        let cases: [(longitude: Double, code: String, date: Date, hours: Int)] = [
            (-171.767, "WS", Date(timeIntervalSince1970: 1_262_260_800), -11),  // 2009-12-31 12:00 UTC
            (-171.767, "WS", Date(timeIntervalSince1970: 1_325_239_140), -11),  // 2011-12-30 09:59 UTC
            (-171.767, "WS", Date(timeIntervalSince1970: 1_325_239_260), 13),   // 2011-12-30 10:01 UTC
            (-171.22, "TK", Date(timeIntervalSince1970: 1_325_160_000), -11),   // 2011-12-29 12:00 UTC
            (-157.475, "KI", year1990, -10),                                    // Kiritimati
            (-171.7, "KI", year1990, -11),                                      // Kanton
            (172.93, "KI", year1990, 12),                                       // Tarawa
            (-175.204, "TO", year1990, 12),                                     // Tonga kept its side
            (174.11, "US", year1990, -12),                                      // Shemya
            (-171.767, "WS", Self.july, 13),
            (-157.475, "KI", Self.july, 14),
        ]
        for place in cases {
            let zone = StayTimeZone.approximateZone(
                forLongitude: place.longitude, isoCountryCode: place.code, at: place.date)
            #expect(zone.secondsFromGMT() == place.hours * 3600, "\(place.code) at \(place.longitude), \(place.date)")
        }
        // A photo from the last evening of 2009 in Apia stays on December 31.
        let evening = Date(timeIntervalSince1970: 1_262_260_800)
        let identifier = StayTimeZone.identifier(
            for: .photoImport, longitude: -171.767, isoCountryCode: "WS", at: evening)
        #expect(Self.label(evening, in: identifier)
                == TravelDays.labelCalendar.date(from: DateComponents(year: 2009, month: 12, day: 31)))
    }

    @Test("a live stay near the date line never takes a zone a day away, wherever it is clustered")
    func liveStaysKeepTheirSideOfTheDateLine() {
        let devices = ["Asia/Tokyo", "Europe/London", "America/Los_Angeles", "Pacific/Honolulu",
                       "Pacific/Apia", "Pacific/Pago_Pago", "Pacific/Auckland", "Australia/Sydney",
                       "Asia/Singapore", "Pacific/Kiritimati", "America/Adak", "Asia/Anadyr"]
        for date in [Self.january, Self.july] {
            for place in Self.dateLinePlaces {
                let political = Self.zone(place.zone).secondsFromGMT(for: date)
                for device in devices {
                    let identifier = StayTimeZone.identifier(
                        for: .liveSLC, longitude: place.longitude, isoCountryCode: place.code,
                        at: date, deviceZone: Self.zone(device))
                    let chosen = StayTimeZone.resolve(identifier).secondsFromGMT(for: date)
                    // Within the kept device-zone tolerance plus the widest real gap.
                    #expect(abs(chosen - political) <= 7 * 3600, "\(place.zone) clustered in \(device)")
                }
            }
        }
    }

    @Test("a device zone across the date line from a known country is not kept")
    func deviceZoneAcrossTheDateLineFallsBack() {
        let date = Self.july
        // Kiritimati read in Honolulu, Pago Pago read in Apia, and back.
        #expect(StayTimeZone.identifier(for: .liveSLC, longitude: -157.475, isoCountryCode: "KI",
                                        at: date, deviceZone: Self.zone("Pacific/Honolulu"))
                == TimeZone(secondsFromGMT: 14 * 3600)!.identifier)
        #expect(StayTimeZone.identifier(for: .liveSLC, longitude: -170.7, isoCountryCode: "AS",
                                        at: date, deviceZone: Self.zone("Pacific/Apia"))
                == TimeZone(secondsFromGMT: -11 * 3600)!.identifier)
        #expect(StayTimeZone.identifier(for: .liveSLC, longitude: -171.767, isoCountryCode: "WS",
                                        at: date, deviceZone: Self.zone("Pacific/Pago_Pago"))
                == TimeZone(secondsFromGMT: 13 * 3600)!.identifier)
        // Honolulu read in Sydney.
        #expect(StayTimeZone.identifier(for: .liveSLC, longitude: -157.86, isoCountryCode: "US",
                                        at: date, deviceZone: Self.zone("Australia/Sydney"))
                == TimeZone(secondsFromGMT: -11 * 3600)!.identifier)
    }

    @Test("the solar offset wraps and clamps")
    func approximateZoneBounds() {
        let date = Self.july
        #expect(StayTimeZone.approximateZone(forLongitude: 0, isoCountryCode: nil, at: date).secondsFromGMT() == 0)
        #expect(StayTimeZone.approximateZone(forLongitude: 179.9, isoCountryCode: nil, at: date).secondsFromGMT() == 12 * 3600)
        #expect(StayTimeZone.approximateZone(forLongitude: -179.9, isoCountryCode: nil, at: date).secondsFromGMT() == -12 * 3600)
        #expect(StayTimeZone.approximateZone(forLongitude: 383.7, isoCountryCode: nil, at: date).secondsFromGMT() == 2 * 3600)
        #expect(StayTimeZone.approximateZone(forLongitude: .nan, isoCountryCode: "KI", at: date).secondsFromGMT() == 0)
        #expect(StayTimeZone.approximateZone(forLongitude: 179.9, isoCountryCode: "US", at: date).secondsFromGMT() == -12 * 3600)
        #expect(StayTimeZone.approximateZone(forLongitude: -150.2, isoCountryCode: "KI", at: date).secondsFromGMT() == 14 * 3600)
    }

    @Test("resolve falls back for nil and unknown identifiers and round-trips fixed offsets")
    func resolveFallback() {
        let fallback = Self.zone("Europe/Athens")
        #expect(StayTimeZone.resolve(nil, fallback: fallback) == fallback)
        #expect(StayTimeZone.resolve("Not/AZone", fallback: fallback) == fallback)
        #expect(StayTimeZone.resolve("Asia/Tokyo", fallback: fallback).identifier == "Asia/Tokyo")
        let fixed = StayTimeZone.approximateZone(forLongitude: -118.2, isoCountryCode: "US", at: Self.july)
        #expect(StayTimeZone.resolve(fixed.identifier, fallback: fallback).secondsFromGMT() == -8 * 3600)
    }
}
