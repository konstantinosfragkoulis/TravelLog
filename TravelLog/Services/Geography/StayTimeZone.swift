//
//  StayTimeZone.swift
//  TravelLog
//

import Foundation

/// The zone a stay is stamped with at creation (`Stay.timeZoneIdentifier`)
/// and the rule for reading it back. A trip's day count is taken in the
/// calendar of the places where its boundary stays happened; only the two
/// boundaries matter, so no per-day zone tracking is needed.
nonisolated enum StayTimeZone {

    /// The identifier to stamp on a new stay.
    ///
    /// - Live observations (`liveSLC`, `foregroundStream`, and the records
    ///   derived from them): the device was physically at the stay, so its
    ///   zone is the stay's zone — exact, DST included. Clustering can run
    ///   hours after capture, on the far side of a flight, so a device zone
    ///   implausible for the stay's place at its start falls back to the
    ///   solar offset below.
    /// - Imported history (photos, Timeline, GPX, JSON without the field):
    ///   nothing records the zone, so derive a fixed offset from longitude.
    ///   Solar time is within an hour or two of the political zone almost
    ///   everywhere, which only matters when a boundary lands inside that
    ///   window around local midnight — and is always closer than the
    ///   importing device's zone for far-away places.
    ///
    /// `isoCountryCode` is the stay's geocoded country, which puts the stay
    /// on its side of the date line (`solarHours`). Without it the side is
    /// unknown, so a device zone plausible on either side is kept.
    static func identifier(
        for source: DataSource,
        longitude: Double,
        isoCountryCode: String?,
        at date: Date,
        deviceZone: TimeZone = .current
    ) -> String {
        guard source.isLiveObservation else {
            return approximateZone(forLongitude: longitude, isoCountryCode: isoCountryCode, at: date).identifier
        }
        guard longitude.isFinite else { return deviceZone.identifier }
        let solar = solarHours(forLongitude: longitude, isoCountryCode: isoCountryCode, at: date)
        let deviceHours = Double(deviceZone.secondsFromGMT(for: date)) / 3600
        var gap = abs(deviceHours - solar)
        if countryCode(isoCountryCode) == nil {
            gap = gap.truncatingRemainder(dividingBy: 24)
            gap = min(gap, 24 - gap)
        }
        return gap <= maxLiveSolarGapHours
            ? deviceZone.identifier
            : zone(forSolarHours: solar).identifier
    }

    /// Widest real political-vs-solar gap is about 3.2 h (western Xinjiang,
    /// western Alaska in summer); flights between regions exceed it.
    static let maxLiveSolarGapHours: Double = 3.5

    /// Fixed-offset zone at the nearest whole hour of solar time, on the
    /// stay's side of the date line on `date` when its country is known.
    static func approximateZone(forLongitude longitude: Double, isoCountryCode: String?, at date: Date) -> TimeZone {
        guard longitude.isFinite else { return TimeZone(secondsFromGMT: 0)! }
        return zone(forSolarHours: solarHours(forLongitude: longitude, isoCountryCode: isoCountryCode, at: date))
    }

    /// Solar hours at `longitude`, a day later or earlier where the country
    /// keeps the date of the far side of 180°. Longitude alone cannot tell
    /// Kiritimati (UTC+14) from Honolulu (UTC-10); the country can, and
    /// tzdata says which side it kept on `date`.
    static func solarHours(forLongitude longitude: Double, isoCountryCode: String?, at date: Date) -> Double {
        let wrapped = GeoMath.normalizedLongitude(longitude)
        let hours = wrapped / 15
        guard abs(wrapped) >= dateLineReachDegrees,
              let code = countryCode(isoCountryCode) else { return hours }
        // An unknown zone keeps today's side.
        if hours < 0, let id = asianDateZones[code],
           (TimeZone(identifier: id)?.secondsFromGMT(for: date) ?? 1) > 0 { return hours + 24 }
        if hours > 0, let id = americanDateZones[code],
           (TimeZone(identifier: id)?.secondsFromGMT(for: date) ?? -1) < 0 { return hours - 24 }
        return hours
    }

    /// The date line strays at most 30° from 180° (Kiribati's Line Islands
    /// reach 150°W), so nearer longitudes always keep their own side's date.
    static let dateLineReachDegrees: Double = 150

    /// Countries whose land east of 180° keeps the Asian-side date today: the
    /// Line and Phoenix Islands, Samoa, Tokelau, Tonga, Wallis and Futuna,
    /// eastern Fiji, the Chatham and Kermadec Islands, and eastern Chukotka.
    /// Each maps to a zone of that land, and its side is read from tzdata at
    /// the stay's date, so Samoa and Tokelau before 2011-12-30 and eastern
    /// Kiribati before 1995 keep the American-side date.
    static let asianDateZones: [String: String] = [
        "FJ": "Pacific/Fiji", "KI": "Pacific/Kiritimati", "NZ": "Pacific/Chatham",
        "RU": "Asia/Anadyr", "TK": "Pacific/Fakaofo", "TO": "Pacific/Tongatapu",
        "WF": "Pacific/Wallis", "WS": "Pacific/Apia",
    ]

    /// Countries whose land west of 180° keeps the American-side date: the
    /// western Aleutians, read from tzdata at the stay's date like above.
    static let americanDateZones: [String: String] = ["US": "America/Adak"]

    private static func zone(forSolarHours hours: Double) -> TimeZone {
        guard hours.isFinite else { return TimeZone(secondsFromGMT: 0)! }
        let rounded = Int(hours.rounded())
        return TimeZone(secondsFromGMT: max(-12, min(14, rounded)) * 3600)
            ?? TimeZone(secondsFromGMT: 0)!
    }

    /// An ISO 3166-1 alpha-2 code, uppercased, or nil for anything else.
    private static func countryCode(_ raw: String?) -> String? {
        guard let code = raw?.trimmingCharacters(in: .whitespaces).uppercased(),
              code.count == 2,
              code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return code
    }

    /// The zone to compute with for a stored identifier. Nil or unknown
    /// (pre-V18 rows, a zone this OS no longer knows) reads as the fallback,
    /// which is the device zone — the pre-V18 behaviour.
    static func resolve(_ identifier: String?, fallback: TimeZone = .current) -> TimeZone {
        guard let identifier, let zone = TimeZone(identifier: identifier) else { return fallback }
        return zone
    }
}
