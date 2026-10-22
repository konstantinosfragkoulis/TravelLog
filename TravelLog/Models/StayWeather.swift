//
//  StayWeather.swift
//  TravelLog
//

import Foundation

/// Full weather snapshot for a single stay, encoded to `Data` and stored
/// in `Stay.weatherData`. The top-level queryable fields on Stay
/// (`avgTemperatureC`, `weatherConditionRaw`, `precipitationMm`) are
/// written alongside this blob so Wrapped/stats can query without decoding.
///
/// All temperatures in Celsius, precipitation in mm, wind in m/s.
/// Display-unit conversion happens in `UnitsFormatter` at render time.
nonisolated struct StayWeather: Codable, Sendable, Equatable {

    /// Dominant weather condition over the stay's duration.
    var condition: Condition

    /// Temperature range and average.
    var temperatureMinC: Double
    var temperatureMaxC: Double
    var temperatureAvgC: Double

    /// Total precipitation during the stay, in millimeters.
    var precipitationMm: Double

    /// Average wind speed during the stay, in meters per second.
    var windSpeedMs: Double?

    /// Average humidity as a fraction (0.0–1.0).
    var humidity: Double?

    /// Whether this data came from a (hex, day) cache hit on another stay
    /// rather than a direct WeatherKit call.
    var isCacheHit: Bool = false

    enum Condition: String, Codable, Sendable, CaseIterable {
        case clear         = "clear"
        case partlyCloudy  = "partlyCloudy"
        case cloudy        = "cloudy"
        case rain          = "rain"
        case heavyRain     = "heavyRain"
        case drizzle       = "drizzle"
        case snow          = "snow"
        case sleet         = "sleet"
        case thunderstorms = "thunderstorms"
        case fog           = "fog"
        case haze          = "haze"
        case windy         = "windy"
        case hot           = "hot"
        case cold          = "cold"
        case unknown       = "unknown"
        /// WeatherKit had no data for this date/location (pre-Aug-2021 or
        /// coverage gap). Terminal — never retried.
        case unavailable   = "unavailable"

        var systemImage: String {
            switch self {
            case .clear:         "sun.max.fill"
            case .partlyCloudy:  "cloud.sun.fill"
            case .cloudy:        "cloud.fill"
            case .rain:          "cloud.rain.fill"
            case .heavyRain:     "cloud.heavyrain.fill"
            case .drizzle:       "cloud.drizzle.fill"
            case .snow:          "cloud.snow.fill"
            case .sleet:         "cloud.sleet.fill"
            case .thunderstorms: "cloud.bolt.rain.fill"
            case .fog:           "cloud.fog.fill"
            case .haze:          "sun.haze.fill"
            case .windy:         "wind"
            case .hot:           "thermometer.sun.fill"
            case .cold:          "thermometer.snowflake"
            case .unknown:       "questionmark.circle"
            case .unavailable:   "xmark.circle"
            }
        }
    }
}

extension StayWeather {
    nonisolated func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    nonisolated static func decoded(from data: Data) -> StayWeather? {
        try? JSONDecoder().decode(StayWeather.self, from: data)
    }
}
