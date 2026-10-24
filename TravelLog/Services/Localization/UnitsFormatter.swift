//
//  UnitsFormatter.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 12/5/26.
//

import Foundation

/// Locale-aware distance formatting.
///
/// **Storage is always metric.** `Home.radiusKm`, `RoutinePlace.radiusMeters`,
/// and `Stay.distanceFromHomeKm` are stored in their original metric units;
/// no conversion ever happens at the storage boundary, so there is zero
/// floating-point drift on edit or save.
///
/// This helper only formats values *for display*. The user-preferred unit
/// system is read from `Locale.current.measurementSystem` on every call,
/// so SwiftUI views naturally re-render with new units after a locale change.
enum UnitsFormatter {

    /// True when the user's locale prefers imperial units.
    /// Returns true for `.us` and `.uk` measurement systems; false for `.metric`.
    /// UK is treated as imperial here because British road signage and casual
    /// distance talk uses miles.
    nonisolated static var isImperial: Bool {
        Locale.current.measurementSystem != .metric
    }

    /// True when the user's locale prefers Fahrenheit for temperature.
    /// Temperature does not follow the distance flag: the UK's hybrid system
    /// (miles for roads) still uses Celsius for weather, so `isImperial` must
    /// not be reused here.
    nonisolated static var prefersFahrenheit: Bool {
        prefersFahrenheit(for: .current)
    }

    /// Testable seam for `prefersFahrenheit`. Foundation's `.general`
    /// temperature resolution, the same one `formatTemp(asProvided: false)`
    /// uses: it honours the system Temperature setting (`mu`) and regional
    /// preferences, not just the measurement system.
    nonisolated static func prefersFahrenheit(for locale: Locale) -> Bool {
        UnitTemperature(forLocale: locale, usage: .general).symbol == UnitTemperature.fahrenheit.symbol
    }

    /// Format a RoutinePlace radius (stored as meters).
    /// Examples: "500 m", "1,500 m" (metric), "1,640 ft", "6,234 ft" (imperial).
    /// The unit chosen here is kept (`.asProvided`): the general usage would
    /// switch to km or mi before rounding, showing 1,500 m as "2 km".
    /// `locale` is a test seam.
    static func formatRoutineRadius(_ meters: Double, locale: Locale = .current) -> String {
        let source = Measurement(value: meters, unit: UnitLength.meters)
        let target = locale.measurementSystem != .metric ? source.converted(to: .feet) : source
        return target.formatted(
            .measurement(
                width: .abbreviated,
                usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(0))
            ).locale(locale)
        )
    }

    /// Format an arbitrary distance from kilometers, auto-scaling to a
    /// sensible unit (m/ft for short distances, km/mi for longer).
    /// Examples: "350 m" / "1,148 ft" for 0.35 km, "12.4 km" / "7.7 mi" for 12.4 km.
    static func formatDistance(kilometers km: Double) -> String {
        let (measurement, digits) = displayDistance(kilometers: km)
        return measurement.formatted(distanceStyle(maxFractionDigits: digits))
    }

    /// `formatDistance`'s number and unit apart, for a figure that sets its
    /// unit in the label below it: ("127.139", "km").
    static func distanceParts(kilometers km: Double) -> (value: String, unit: String) {
        let (measurement, digits) = displayDistance(kilometers: km)
        let text = measurement.formatted(distanceStyle(maxFractionDigits: digits).attributed)
        var value = "", unit = ""
        for run in text.runs {
            switch run.measurement {
            case .value: value += String(text[run.range].characters)
            case .unit: unit += String(text[run.range].characters)
            default: break
            }
        }
        return (value, unit)
    }

    /// The unit a distance reads in, and the fraction digits it keeps.
    private static func displayDistance(kilometers km: Double) -> (Measurement<UnitLength>, Int) {
        if isImperial {
            let miles = km / 1.609_344
            if miles < 0.1 {
                return (Measurement(value: miles * 5_280, unit: UnitLength.feet), 0)
            }
            return (Measurement(value: miles, unit: UnitLength.miles), miles < 100 ? 1 : 0)
        } else {
            if km < 1.0 {
                return (Measurement(value: km * 1_000, unit: UnitLength.meters), 0)
            }
            return (Measurement(value: km, unit: UnitLength.kilometers), km < 100 ? 1 : 0)
        }
    }

    // MARK: - Temperature (V11)

    /// User's preferred temperature unit. Reads from iCloud KVS first
    /// (cross-device preference); falls back to locale.
    nonisolated enum TemperaturePreference: String {
        case locale     = "locale"
        case celsius    = "celsius"
        case fahrenheit = "fahrenheit"

        static var current: TemperaturePreference {
            let raw = NSUbiquitousKeyValueStore.default.string(forKey: "temperatureUnit") ?? "locale"
            return TemperaturePreference(rawValue: raw) ?? .locale
        }

        var useCelsius: Bool { useCelsius(locale: .current) }

        func useCelsius(locale: Locale) -> Bool {
            switch self {
            case .celsius: return true
            case .fahrenheit: return false
            case .locale: return !prefersFahrenheit(for: locale)
            }
        }
    }

    /// The display value for a temperature stored in Celsius: the unit is
    /// resolved once from the preference and locale, and the value is
    /// rounded once (half away from zero, no negative zero). Both formatters
    /// below use it, so a compact chip and a full label never disagree on
    /// unit or rounding.
    nonisolated static func displayTemperature(_ celsius: Double, preference: TemperaturePreference, locale: Locale) -> Measurement<UnitTemperature> {
        let source = Measurement(value: celsius, unit: UnitTemperature.celsius)
        let target = preference.useCelsius(locale: locale) ? source : source.converted(to: .fahrenheit)
        let rounded = target.value.rounded()
        return Measurement(value: rounded == 0 ? 0 : rounded, unit: target.unit)
    }

    /// Format a temperature stored in Celsius for display.
    /// Respects the user's temperature preference (iCloud KVS synced).
    /// Examples: "24°C" (metric/celsius), "75°F" (imperial/fahrenheit).
    /// `preference` and `locale` are test seams.
    nonisolated static func formatTemperature(_ celsius: Double, preference: TemperaturePreference = .current, locale: Locale = .current) -> String {
        // The unit is already resolved, so the formatter must not convert again.
        formatTemp(displayTemperature(celsius, preference: preference, locale: locale),
                   maxFractionDigits: 0, asProvided: true, locale: locale)
    }

    /// Compact temperature for inline chips: "24°" (no unit suffix).
    /// `preference` and `locale` are test seams.
    nonisolated static func formatTemperatureCompact(_ celsius: Double, preference: TemperaturePreference = .current, locale: Locale = .current) -> String {
        let value = Int(displayTemperature(celsius, preference: preference, locale: locale).value)
        // Localized integer (locale digits + minus sign), not ASCII string
        // interpolation.
        return "\(value.formatted(.number.grouping(.never).locale(locale)))°"
    }

    /// `asProvided` keeps the measurement's unit; `.general` usage converts
    /// to the locale's unit, which also honours the system Temperature
    /// setting (`mu`). `locale` is a test seam.
    nonisolated static func formatTemp(_ measurement: Measurement<UnitTemperature>, maxFractionDigits: Int, asProvided: Bool, locale: Locale = .current) -> String {
        measurement.formatted(
            .measurement(
                width: .abbreviated,
                usage: asProvided ? .asProvided : .general,
                numberFormatStyle: .number.precision(.fractionLength(0...maxFractionDigits))
            ).locale(locale)
        )
    }

    // MARK: - Private

    private static func distanceStyle(maxFractionDigits: Int) -> Measurement<UnitLength>.FormatStyle {
        .measurement(
            width: .abbreviated,
            numberFormatStyle: .number.precision(.fractionLength(0...maxFractionDigits))
        )
    }
}
