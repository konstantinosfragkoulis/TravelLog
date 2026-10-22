//
//  DateRangeText.swift
//  TravelLog
//

import Foundation

/// Date ranges as the app writes them. `Date.IntervalFormatStyle` joins the
/// two ends with an en dash, and the app's copy never uses em or en dashes,
/// so the dash becomes the language's own connective ("3 to 5 Jan",
/// "3. bis 5. Jan."). Ranges the style writes without a dash (Japanese,
/// Korean and Chinese use their own range marks) pass through unchanged.
/// Shared with the widget extension, which resolves the key in its catalog.
nonisolated enum DateRangeText {
    static func format(_ range: Range<Date>, _ style: Date.IntervalFormatStyle) -> String {
        joined(range.formatted(style), locale: style.locale)
    }

    /// Rejoins a formatted range at its first em or en dash.
    static func joined(_ text: String, locale: Locale) -> String {
        guard let dash = text.firstIndex(where: { $0 == "\u{2013}" || $0 == "\u{2014}" }) else {
            return text
        }
        let start = String(text[..<dash]).trimmingCharacters(in: .whitespaces)
        let end = String(text[text.index(after: dash)...]).trimmingCharacters(in: .whitespaces)
        return localizedRendererString(
            localized: "date-range.joined",
            defaultValue: "\(start) to \(end)",
            bundle: nil,
            locale: locale)
    }
}
