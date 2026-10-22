//
//  TripDisplayText.swift
//  TravelLog
//
//  The short date and count phrases the Trips list and the trip page share:
//  "12 to 20 Sep", "Since 14 Oct", "4 nights", "3h 35m", "in 36 days".
//  Spans read "A to B" rather than an interval dash, compacting the shared
//  month where the locale writes the day first.
//

import SwiftUI

enum TripDisplayText {

    /// "12 to 20 Sep", "28 Sep to 3 Oct", "30 Dec 2025 to 2 Jan 2026", or
    /// one day "14 Sep". `includeYear` adds the year to the end; spans that
    /// cross a year always carry both.
    static func range(from start: Date, to end: Date, includeYear: Bool, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        let base = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let dayMonth = base.day().month(.abbreviated)
        let dayMonthYear = dayMonth.year()
        if calendar.isDate(start, inSameDayAs: end) || end < start {
            return start.formatted(includeYear ? dayMonthYear : dayMonth)
        }
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: end)
        let sameMonth = sameYear && calendar.component(.month, from: start) == calendar.component(.month, from: end)
        let endText = end.formatted(includeYear || !sameYear ? dayMonthYear : dayMonth)
        let startText: String
        if sameMonth && dayLeads(dayMonth, day: base.day(), sample: end) {
            startText = start.formatted(base.day())
        } else if sameYear {
            startText = start.formatted(dayMonth)
        } else {
            startText = start.formatted(dayMonthYear)
        }
        return String(
            localized: "trips.date-range.span",
            defaultValue: "\(startText) to \(endText)",
            comment: "A trip or stop's dates, from its first to its last day, e.g. 12 to 20 Sep. The placeholders are formatted dates.")
    }

    /// "12 to 20 Sep" from two instants each read in its own zone: the
    /// first day where the trip began, the last where it ended.
    static func range(from start: Date, in startZone: TimeZone, to end: Date, in endZone: TimeZone,
                      includeYear: Bool, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        guard let first = TravelDays.label(for: start, zone: startZone),
              let last = TravelDays.label(for: end, zone: endZone) else {
            return range(from: start, to: end, includeYear: includeYear, calendar: calendar, locale: locale)
        }
        // Labels are civil days at UTC midnight: read them in UTC, in the
        // reader's own calendar and language.
        var labels = calendar
        labels.timeZone = TravelDays.labelCalendar.timeZone
        return range(from: first, to: last, includeYear: includeYear, calendar: labels, locale: locale)
    }

    /// The zones a trip's first and last days are read in, the ones
    /// `Trip.durationDays` counts with: its earliest stay's and its
    /// latest-ending stay's (`TravelDays.boundaryStays`), else the calendar's.
    static func boundaryZones(of trip: Trip, calendar: Calendar = .current) -> (start: TimeZone, end: TimeZone) {
        let boundary = TravelDays.boundaryStays(of: trip.stays ?? [])
        return (StayTimeZone.resolve(boundary.first?.timeZoneIdentifier, fallback: calendar.timeZone),
                StayTimeZone.resolve(boundary.last?.timeZoneIdentifier, fallback: calendar.timeZone))
    }

    /// A trip's dates as its day count reads them: "8 to 13 Oct" beside
    /// "6 days" wherever the device is. An ongoing trip reads "Since 8 Oct".
    static func tripDates(_ trip: Trip, includeYear: Bool, calendar: Calendar = .current,
                          locale: Locale = .autoupdatingCurrent) -> String {
        let zones = boundaryZones(of: trip, calendar: calendar)
        guard let end = trip.endDate else { return since(trip.startDate, in: zones.start) }
        return range(from: trip.startDate, in: zones.start, to: end, in: zones.end,
                     includeYear: includeYear, calendar: calendar, locale: locale)
    }

    /// "14 Oct", with the year when it is not the current one. `zone`
    /// reads the day where it happened; nil, in the calendar's zone.
    static func day(_ date: Date, in zone: TimeZone? = nil, now: Date = .now, calendar: Calendar = .current) -> String {
        var dayMonth = Date.FormatStyle().day().month(.abbreviated)
        var local = calendar
        if let zone {
            dayMonth.timeZone = zone
            local.timeZone = zone
        }
        let sameYear = local.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? dayMonth : dayMonth.year())
    }

    /// Whether the locale writes "20 Sep" (day first), so "12 to 20 Sep" reads right.
    /// It must open with the bare day itself: "9月20日" starts with a digit, but
    /// its month, so "12日から9月20日" would read wrong.
    private static func dayLeads(_ style: Date.FormatStyle, day: Date.FormatStyle, sample: Date) -> Bool {
        style.format(sample).hasPrefix(day.format(sample))
    }

    /// "Since 14 Oct": an ongoing trip's start; it has no known end.
    static func since(_ date: Date, in zone: TimeZone? = nil) -> String {
        String(localized: "Since \(day(date, in: zone))")
    }

    /// Nights between a stop's first and last calendar day, in its own zone.
    nonisolated static func nights(from start: Date, to end: Date, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
        return max(0, days)
    }

    /// "4 nights" or "1 night", after an overnight stop's dates.
    static func nightsPhrase(_ nights: Int) -> String {
        nights == 1
            ? String(localized: "trip-detail.stop.nights.one", defaultValue: "\(nights, format: .number.grouping(.never)) night", comment: "Trip page stop caption for a one-night stay, after its dates.")
            : String(localized: "trip-detail.stop.nights.other", defaultValue: "\(nights, format: .number.grouping(.never)) nights", comment: "Trip page stop caption for a stay of several nights, after its dates.")
    }

    /// A stop's time there when it had no night: "40 min" under an hour,
    /// then "3h", "3h 05m".
    static func stopDuration(minutes: Int) -> String {
        let minutes = max(0, minutes)
        if minutes < 60 {
            return String(localized: "trip-detail.stop.duration.minutes", defaultValue: "\(minutes, format: .number.grouping(.never)) min", comment: "Trip page stop caption for a stop of under an hour, after its date, e.g. 40 min.")
        }
        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 {
            return String(localized: "trip-detail.stop.duration.hours", defaultValue: "\(hours, format: .number.grouping(.never))h", comment: "Trip page stop caption for a stop of whole hours, after its date, e.g. 3h.")
        }
        let restText = rest.formatted(.number.grouping(.never).precision(.integerLength(2...)))
        return String(localized: "trip-detail.stop.duration.hours-minutes", defaultValue: "\(hours, format: .number.grouping(.never))h \(restText)m", comment: "Trip page stop caption for a stop of hours and minutes, after its date, e.g. 3h 35m. The second placeholder is the minutes, always two digits.")
    }

    /// A stop's caption on the trip page and its map: "3 to 5 Jun · 2 nights"
    /// for a stay with nights, "5 Jun · 3h 35m" for a visit or a transit stop.
    /// Its dates are the stop's own days, in its zone like its nights, so a
    /// day trip never reads as two dates wherever the device is.
    static func stopCaption(_ stay: Stay, calendar: Calendar = .current, locale: Locale = .autoupdatingCurrent) -> String {
        var local = calendar
        local.timeZone = StayTimeZone.resolve(stay.timeZoneIdentifier, fallback: calendar.timeZone)
        let dates = range(from: stay.startTime, to: stay.endTime, includeYear: false, calendar: local, locale: locale)
        let nights = stay.category == .destination ? TimelineStop.nights(stay) : 0
        let length = nights > 0 ? nightsPhrase(nights) : stopDuration(minutes: stay.durationMinutes)
        return "\(dates) · \(length)"
    }

    /// Every country by name in visit order, as a localized list
    /// ("Portugal and Spain"); nil without countries.
    static func countryNames(_ codes: [String]) -> String? {
        guard !codes.isEmpty else { return nil }
        let names = codes.map { localizedCountryName(iso: $0, fallback: $0) ?? $0 }
        return names.formatted(.list(type: .and).locale(AppLanguagePreference.currentLocale()))
    }

    /// The trip's one country by name, or "3 countries".
    static func countries(_ codes: [String]) -> String? {
        switch codes.count {
        case 0:
            return nil
        case 1:
            return localizedCountryName(iso: codes[0], fallback: codes[0])
        default:
            return String(localized: "trips.country-count.several", defaultValue: "\(codes.count, format: .number.grouping(.never)) countries", comment: "Trip row label beside the flags of a trip through several countries.")
        }
    }

    /// "3 places".
    static func places(_ count: Int) -> String {
        count == 1
            ? String(localized: "trips.place-count.one", defaultValue: "\(count, format: .number.grouping(.never)) place", comment: "Count of a trip's destinations, on its row and its page, for one.")
            : String(localized: "trips.place-count.other", defaultValue: "\(count, format: .number.grouping(.never)) places", comment: "Count of a trip's destinations, on its row and its page, for several.")
    }

    /// "312 photos".
    static func photos(_ count: Int) -> String {
        count == 1
            ? String(localized: "trips.photo-count.one", defaultValue: "\(count, format: .number.grouping(.never)) photo", comment: "Count of a trip's photos, on its row and its page, for one.")
            : String(localized: "trips.photo-count.other", defaultValue: "\(count, format: .number.grouping(.never)) photos", comment: "Count of a trip's photos, on its row and its page, for several.")
    }
}

/// A trip's flags in visit order, then its country by name (or a count).
struct TripCountryLabel: View {
    let codes: [String]
    var flagSize: FlagView.Size = .small
    var maxFlags = 3
    /// False draws the flags alone, the name kept for VoiceOver.
    var showsName = true

    var body: some View {
        if !codes.isEmpty {
            let name = TripDisplayText.countries(codes)
            HStack(spacing: 7) {
                FlagRow(codes: Array(codes.prefix(maxFlags)), size: flagSize)
                if showsName, let name {
                    Text(name)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name ?? "")
        }
    }
}

/// The saffron "Active" pill with its dot: the one ongoing marker on trip rows and pages.
struct ActiveStatePill: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(AppTheme.onSaffron)
                .frame(width: 6, height: 6)
            Text(String(
                localized: "trips.state.active",
                defaultValue: "Active",
                comment: "State pill on an ongoing trip, on its Trips list row and its page, beside its day count and start date."))
                .font(.caption.weight(.bold))
                .lineLimit(1)
        }
        .foregroundStyle(AppTheme.onSaffron)
        .padding(.horizontal, 9)
        .frame(minHeight: 22)
        .background(AppTheme.saffron, in: .capsule)
    }
}
