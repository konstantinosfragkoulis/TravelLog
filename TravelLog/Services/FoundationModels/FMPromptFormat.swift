//
//  FMPromptFormat.swift
//  TravelLog
//

import Foundation

/// Canonical, locale-independent rendering for values embedded in Foundation
/// Models prompts. The shapes match the former en-US `formatted` output while
/// preventing the UI locale from changing prompt bytes.
nonisolated enum FMPromptFormat {

    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let gregorian = Calendar(identifier: .gregorian)

    private static let numericDateAndShortTimeStyle = Date.FormatStyle(
        date: .numeric,
        time: .shortened,
        locale: posix,
        calendar: gregorian,
        timeZone: .gmt
    )

    private static let abbreviatedDateAndShortTimeStyle = Date.FormatStyle(
        date: .abbreviated,
        time: .shortened,
        locale: posix,
        calendar: gregorian,
        timeZone: .autoupdatingCurrent
    )

    private static let isoDayStyle = Date.ISO8601FormatStyle(timeZone: .gmt)
        .year()
        .month()
        .day()

    private static let wholeNumberStyle = FloatingPointFormatStyle<Double>.number
        .locale(posix)
        .grouping(.never)
        .precision(.fractionLength(0))
        .rounded(rule: .toNearestOrEven)

    /// In an explicit zone: a prompt rendered again later must not follow
    /// a zone change in between.
    static func numericDateAndShortTime(_ date: Date, timeZone: TimeZone) -> String {
        var style = numericDateAndShortTimeStyle
        style.timeZone = timeZone
        return date.formatted(style)
    }

    static func abbreviatedDateAndShortTime(_ date: Date) -> String {
        date.formatted(abbreviatedDateAndShortTimeStyle)
    }

    static func isoDay(_ date: Date) -> String {
        date.formatted(isoDayStyle)
    }

    static func wholeNumber(_ value: Double) -> String {
        value.formatted(wholeNumberStyle)
    }
}
