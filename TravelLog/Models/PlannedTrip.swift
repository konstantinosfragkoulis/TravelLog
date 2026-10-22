//
//  PlannedTrip.swift
//  TravelLog
//

import Foundation
import SwiftData

/// A future trip detected from the user's calendar — *intent*, never ground
/// truth. Written exclusively by `CalendarEnricher`; read by the UI (and,
/// later, widgets/Siri). It never creates, edits, or deletes a `Stay`/`Trip`:
/// once a real `Trip` materializes from location pings, the planned trip is
/// retired via `matchedTripID` + `status = .matched` and stands as a
/// historical record — the same one-directional, never-fabricate discipline
/// as `RememberedCountriesStorage` and `YearWrapped`.
///
/// ## CloudKit considerations
///
/// - No `@Attribute(.unique)`, no arrays, no relationships (lessons from
///   V1→V3). `matchedTripID` is a plain `UUID?` — same reason
///   `HiddenPhoto.tripID` / `PinnedPhoto.tripID` are plain fields.
/// - Every field is optional or defaulted → V13→V14 stays lightweight.
/// - Cross-device duplicate rows (two devices scanning the same synced
///   calendar) are converged by a deduplicator keyed on
///   `(eventExternalIdentifier ?? eventLocalIdentifier, startDate)` —
///   the composite includes `startDate` because recurring events expand to
///   many instances sharing one event identifier.
///
/// ## Privacy
///
/// Only the event's title, dates, and location text are ever persisted.
/// `EKEvent.notes` / attendees / organizer routinely contain third-party PII
/// and are scanned in-memory only, inside `CalendarEnricher` — they must
/// never be written to a field here.
///
/// Added in V14.
@Model
final class PlannedTrip {

    var id: UUID = UUID()

    /// `EKCalendarItem.calendarItemExternalIdentifier` — the cross-device
    /// dedup key of choice (tracks the server-side UID for synced accounts).
    /// nil for events without one (rare; local-only edge cases).
    var eventExternalIdentifier: String?

    /// `EKEvent.eventIdentifier` — always present on a fetched event; the
    /// per-device fallback key, and what re-fetches the source event on this
    /// device to verify it still exists.
    var eventLocalIdentifier: String = ""

    /// The calendar event's title (truncated at write time; never the notes).
    var title: String = ""

    var startDate: Date = Date.now
    var endDate: Date = Date.now
    var isAllDay: Bool = false

    /// Raw `EKEvent.location` text, kept for display even after resolution.
    var locationText: String?

    // MARK: - Forward-geocoding results (nil until resolved)

    var resolvedLatitude: Double?
    var resolvedLongitude: Double?
    var resolvedLocality: String?
    var resolvedCountry: String?
    var resolvedISOCountryCode: String?

    /// Great-circle distance from the `Home` active at `startDate`, computed
    /// once coordinates resolve. Mirrors `Stay.distanceFromHomeKm`.
    var distanceFromHomeKm: Double?

    /// Backs `PlannedTripConfidence`. String-stored like `DataSource` /
    /// `StayCategory` — forward-compatible, CloudKit-safe.
    var confidenceRaw: String = "low"

    /// Comma-joined detection-signal tags (`"flightCode,bookingKeyword"`) —
    /// same `String`-not-`[String]` encoding as `Stay.pingIDsString`.
    var signalsRaw: String = ""

    /// Backs `PlannedTripStatus`.
    var statusRaw: String = "upcoming"

    /// The real `Trip` this planned trip was matched to, once one exists.
    /// Plain field, never a relationship; orphan-swept, not cascaded.
    var matchedTripID: UUID?

    /// Encoded WeatherKit *forecast* snapshot (up to 10 days out).
    /// Explicitly provisional — never conflated with `Stay.weatherData`'s
    /// post-hoc historical truth.
    var forecastWeatherData: Data?

    var createdAt: Date = Date.now

    /// Bumped by every scan that still finds the source event; drives the
    /// staleness/orphan sweep for `.upcoming` rows (`.matched` rows are
    /// never swept — the historical record stands on its own).
    var lastSeenAt: Date = Date.now

    init(
        eventExternalIdentifier: String?,
        eventLocalIdentifier: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        locationText: String?
    ) {
        self.id = UUID()
        self.eventExternalIdentifier = eventExternalIdentifier
        self.eventLocalIdentifier = eventLocalIdentifier
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.locationText = locationText
        self.createdAt = .now
        self.lastSeenAt = .now
    }
}

// MARK: - Type-safe accessors

extension PlannedTrip {
    var confidence: PlannedTripConfidence {
        get { PlannedTripConfidence.decode(confidenceRaw) }
        set { confidenceRaw = newValue.rawValue }
    }

    var status: PlannedTripStatus {
        get { PlannedTripStatus.decode(statusRaw) }
        set { statusRaw = newValue.rawValue }
    }

    /// Decoded detection-signal tags.
    var signals: [String] {
        get { signalsRaw.isEmpty ? [] : signalsRaw.components(separatedBy: ",") }
        set { signalsRaw = newValue.joined(separator: ",") }
    }

    /// The instant this row stops counting as current in `timeZone`: the
    /// Trips-list card, the widget, the Next Trip intent and the scan's
    /// sweep keep a row while this is at or after now. A timed row ends at
    /// its `endDate`. An all-day row's stored end is the last second of its
    /// last day in the zone of the synced device that wrote it (EventKit's
    /// 23:59:59), which a device further west would otherwise pass hours
    /// before its own last day is over. Synced devices settle the start on
    /// the westernmost zone's midnight and the end on the easternmost
    /// zone's last second, so a start that is a local midnight here means
    /// the end was written here or further east: it then counts until the
    /// end of the day it renders on here, the day the card shows, and never
    /// earlier than `endDate`. Any other row keeps its `endDate`: a west
    /// written end already renders on a later day here and would otherwise
    /// linger a day after the trip (a phone that flew home east after the
    /// event ended). An exclusive-midnight end belongs to the day before it.
    func currentUntil(timeZone: TimeZone = .current) -> Date {
        guard isAllDay else { return endDate }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard calendar.startOfDay(for: startDate) == startDate else { return endDate }
        let lastDay = calendar.startOfDay(for: endDate.addingTimeInterval(-1))
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) else { return endDate }
        return max(endDate, dayEnd)
    }
}

// MARK: - PlannedTripForecast (Codable blob)

/// WeatherKit 10-day *forecast* snapshot for an upcoming planned trip,
/// encoded into `PlannedTrip.forecastWeatherData`. Explicitly provisional —
/// once the trip actually happens, `WeatherEnricher`'s historical query on
/// the real `Stay` is the authoritative record; this never feeds it.
///
/// **Forward-compatibility rule (the `WrappedStats` lesson): every field
/// added after first ship MUST be `Optional`** — synthesized Codable does
/// not fall back to defaults for missing keys.
nonisolated struct PlannedTripForecast: Codable, Sendable, Equatable {

    /// When this forecast was fetched — drives the once-daily refresh.
    var fetchedAt: Date
    var days: [Day]

    nonisolated struct Day: Codable, Sendable, Equatable {
        var date: Date
        /// `StayWeather.Condition` raw value (same compressed vocabulary as
        /// historical weather, so the same SF Symbols render it).
        var conditionRaw: String
        var minTemperatureC: Double
        var maxTemperatureC: Double
        var precipitationMm: Double
    }

    nonisolated func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    nonisolated static func decoded(from data: Data) -> PlannedTripForecast? {
        try? JSONDecoder().decode(PlannedTripForecast.self, from: data)
    }
}

extension PlannedTrip {
    /// Decoded forecast accessor over `forecastWeatherData`.
    var forecast: PlannedTripForecast? {
        get {
            guard let data = forecastWeatherData else { return nil }
            return PlannedTripForecast.decoded(from: data)
        }
        set { forecastWeatherData = newValue?.encoded() }
    }
}

/// How confidently the detection heuristics scored this event as a trip.
/// Buckets (not a boolean) so the UI can surface low-confidence detections
/// more quietly than high-confidence ones.
nonisolated enum PlannedTripConfidence: String, Codable, CaseIterable, Sendable {
    case high   = "high"
    case medium = "medium"
    case low    = "low"

    static func decode(_ raw: String) -> PlannedTripConfidence {
        PlannedTripConfidence(rawValue: raw) ?? .low
    }
}

/// Lifecycle of a planned trip.
nonisolated enum PlannedTripStatus: String, Codable, CaseIterable, Sendable {
    /// Detected; the event is in the future (or recent past, pending match).
    case upcoming  = "upcoming"
    /// Correlated to a real `Trip` (`matchedTripID` set). Terminal.
    case matched   = "matched"
    /// The event's dates passed without a matching real `Trip` appearing.
    /// A later detection whose refreshed dates are current again (an
    /// extended event) returns the row to `.upcoming`.
    case expired   = "expired"
    /// The user dismissed the card. Never re-created while the source event
    /// is unchanged (identity key still matches).
    case dismissed = "dismissed"

    static func decode(_ raw: String) -> PlannedTripStatus {
        PlannedTripStatus(rawValue: raw) ?? .upcoming
    }
}
