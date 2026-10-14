//
//  TripSort.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 22/5/26.
//

import Foundation

/// User-selectable sort order for the trips list. Persisted locally via
/// `@AppStorage("tripsSortOrder")` — see `TripsListView` for the binding
/// (deliberately local, not iCloud-synced;
/// matches Apple Mail / Photos / Files / Day One convention for view-state
/// preferences).
///
/// # Default
///
/// `.dateNewest` — preserves the pre-feature behavior (`@Query` was
/// `\Trip.startDate, order: .reverse`). Existing users won't see any
/// re-ordering on first launch after the upgrade.
///
/// # Stability
///
/// Every comparator below uses a deterministic secondary tiebreaker
/// (`startDate` desc) and tertiary tiebreaker (`id.uuidString`) so equal
/// primary keys never flip-flop between renders.
nonisolated enum TripSortOrder: String, CaseIterable, Identifiable {
    case dateNewest
    case dateOldest
    case significanceHighest
    case durationLongest
    case durationShortest
    case photoCountHighest
    case photoCountLowest
    case countryCountHighest
    case nameAZ

    var id: String { rawValue }

    /// Whether this order ranks by `PhotoService.cachedPhotoCount` and so
    /// requires the photo-count prewarm. Used to skip the full-library photo
    /// fetch sweep on the common date/duration/name sorts.
    var usesPhotoCount: Bool {
        self == .photoCountHighest || self == .photoCountLowest
    }

    /// Display label shown in the toolbar Picker. Sentence case.
    var label: String {
        switch self {
        case .dateNewest:
            String(localized: "trip-sort.date-newest.label", defaultValue: "Newest First", comment: "Trip sort option label.")
        case .dateOldest:
            String(localized: "trip-sort.date-oldest.label", defaultValue: "Oldest First", comment: "Trip sort option label.")
        case .significanceHighest:
            String(localized: "trip-sort.significance-highest.label", defaultValue: "Biggest First", comment: "Trip sort option label.")
        case .durationLongest:
            String(localized: "trip-sort.duration-longest.label", defaultValue: "Longest Duration", comment: "Trip sort option label.")
        case .durationShortest:
            String(localized: "trip-sort.duration-shortest.label", defaultValue: "Shortest Duration", comment: "Trip sort option label.")
        case .photoCountHighest:
            String(localized: "trip-sort.photo-count-highest.label", defaultValue: "Most Photos", comment: "Trip sort option label.")
        case .photoCountLowest:
            String(localized: "trip-sort.photo-count-lowest.label", defaultValue: "Fewest Photos", comment: "Trip sort option label.")
        case .countryCountHighest:
            String(localized: "trip-sort.country-count-highest.label", defaultValue: "Most Countries", comment: "Trip sort option label.")
        case .nameAZ:
            String(localized: "trip-sort.name-a-z.label", defaultValue: "Name (A – Z)", comment: "Trip sort option label.")
        }
    }

    /// Compact label for the chip face (`"Sort: <shortLabel>"`). Trims
    /// the trailing qualifier so the chip stays narrow at typical
    /// device widths — "Sort: Newest" fits where "Sort: Newest First"
    /// would push the next chip off-screen on iPhone mini-class
    /// devices.
    var shortLabel: String {
        switch self {
        case .dateNewest:
            String(localized: "trip-sort.date-newest.short-label", defaultValue: "Newest", comment: "Compact trip sort option label.")
        case .dateOldest:
            String(localized: "trip-sort.date-oldest.short-label", defaultValue: "Oldest", comment: "Compact trip sort option label.")
        case .significanceHighest:
            String(localized: "trip-sort.significance-highest.short-label", defaultValue: "Biggest", comment: "Compact trip sort option label.")
        case .durationLongest:
            String(localized: "trip-sort.duration-longest.short-label", defaultValue: "Longest", comment: "Compact trip sort option label.")
        case .durationShortest:
            String(localized: "trip-sort.duration-shortest.short-label", defaultValue: "Shortest", comment: "Compact trip sort option label.")
        case .photoCountHighest:
            String(localized: "trip-sort.photo-count-highest.short-label", defaultValue: "Most Photos", comment: "Compact trip sort option label.")
        case .photoCountLowest:
            String(localized: "trip-sort.photo-count-lowest.short-label", defaultValue: "Fewest Photos", comment: "Compact trip sort option label.")
        case .countryCountHighest:
            String(localized: "trip-sort.country-count-highest.short-label", defaultValue: "Most Countries", comment: "Compact trip sort option label.")
        case .nameAZ:
            String(localized: "trip-sort.name-a-z.short-label", defaultValue: "Name A–Z", comment: "Compact trip sort option label.")
        }
    }

    /// SF Symbol shown next to each option in the Picker. Chosen to be
    /// instantly recognizable: calendar for date, clock for duration,
    /// photo stack for photo count, globe for country count, textformat
    /// for name.
    var systemImage: String {
        switch self {
        case .dateNewest, .dateOldest:                "calendar"
        case .significanceHighest:                    "arrow.up.right"
        case .durationLongest, .durationShortest:     "clock"
        case .photoCountHighest, .photoCountLowest:   "photo.stack"
        case .countryCountHighest:                    "globe"
        case .nameAZ:                                 "textformat"
        }
    }
}

/// Pure-function namespace for sorting `[Trip]` by a `TripSortOrder`.
/// Marked `@MainActor` because the photo-count case reads from
/// `PhotoService` (which is `@MainActor`). All other cases would work
/// off-main, but isolating the whole namespace keeps callers honest —
/// `TripsListView` invokes this from inside `body` (which is also
/// `@MainActor`-isolated), so there's no actor hop and no perf cost.
@MainActor
enum TripSorter {

    /// Sort `trips` in-place-style (returns a new array). Stable across
    /// renders via deterministic tiebreakers — see `TripSortOrder` for
    /// the contract.
    ///
    /// - Parameters:
    ///   - trips: input trip set; left unmodified
    ///   - order: which criterion to sort by
    ///   - photoService: required only by the `photoCount*` cases; pass
    ///     `PhotoService.shared` from the call site. Made explicit (rather
    ///     than reaching for the singleton inside) so unit tests can pass
    ///     a fixture, and so the static analyzer can see the dependency.
    static func sort(
        _ trips: [Trip],
        by order: TripSortOrder,
        photoService: PhotoService
    ) -> [Trip] {
        switch order {
        case .dateNewest:
            return trips.sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate { return lhs.startDate > rhs.startDate }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        case .dateOldest:
            return trips.sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        case .significanceHighest:
            // Scores snapshotted once before the sort: `significance` walks
            // the trip's stays, so calling it per comparison would be
            // O(n log n × stays). Each score travels with its own row, never
            // through a `Trip.id` lookup: UUID twins are distinct physical
            // rows (CloudKit cannot enforce uniqueness) whose stays, dates and
            // countries can differ, so each ranks by its own value.
            let now = Date.now
            let scored = trips.map { (trip: $0, score: significance($0, now: now)) }
            return scored.sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.trip.startDate != rhs.trip.startDate { return lhs.trip.startDate > rhs.trip.startDate }
                return lhs.trip.id.uuidString < rhs.trip.id.uuidString
            }.map(\.trip)
        case .durationLongest:
            // `now` hoisted out of the comparator: `Date.now` per comparison
            // was both a syscall × O(n log n) and a (theoretical) strict-weak-
            // ordering violation when the clock ticked mid-sort.
            // Keys snapshotted once per row, as in significance: calendar
            // days first, the count the row shows, so a 10 h overnight trip
            // ("2 days") outranks a 14 h day trip ("1 day"); elapsed seconds
            // only break ties.
            let now = Date.now
            let keyed = trips.map { (trip: $0, key: durationKey($0, now: now)) }
            return keyed.sorted { lhs, rhs in
                if lhs.key.days != rhs.key.days { return lhs.key.days > rhs.key.days }
                if lhs.key.seconds != rhs.key.seconds { return lhs.key.seconds > rhs.key.seconds }
                if lhs.trip.startDate != rhs.trip.startDate { return lhs.trip.startDate > rhs.trip.startDate }
                return lhs.trip.id.uuidString < rhs.trip.id.uuidString
            }.map(\.trip)
        case .durationShortest:
            let now = Date.now
            let keyed = trips.map { (trip: $0, key: durationKey($0, now: now)) }
            return keyed.sorted { lhs, rhs in
                if lhs.key.days != rhs.key.days { return lhs.key.days < rhs.key.days }
                if lhs.key.seconds != rhs.key.seconds { return lhs.key.seconds < rhs.key.seconds }
                if lhs.trip.startDate != rhs.trip.startDate { return lhs.trip.startDate > rhs.trip.startDate }
                return lhs.trip.id.uuidString < rhs.trip.id.uuidString
            }.map(\.trip)
        case .photoCountHighest:
            // Counts snapshotted once before the sort: `cachedPhotoCount`
            // walks the trip's cached photo groups, so calling it per
            // comparison made the sort O(n log n × groups). Keying the
            // snapshot by UUID loses nothing: the count cache itself is
            // keyed by UUID, so UUID twins already share one count.
            let counts = photoCountsByTripID(trips, photoService: photoService)
            return trips.sorted { lhs, rhs in
                let l = counts[lhs.id] ?? 0
                let r = counts[rhs.id] ?? 0
                if l != r { return l > r }
                if lhs.startDate != rhs.startDate { return lhs.startDate > rhs.startDate }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        case .photoCountLowest:
            let counts = photoCountsByTripID(trips, photoService: photoService)
            return trips.sorted { lhs, rhs in
                let l = counts[lhs.id] ?? 0
                let r = counts[rhs.id] ?? 0
                if l != r { return l < r }
                if lhs.startDate != rhs.startDate { return lhs.startDate > rhs.startDate }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        case .countryCountHighest:
            // Precompute once per row: in the comparator the string-split
            // count would re-run O(n log n) times. Per row, not
            // per UUID, as in significance: UUID twins can list different
            // countries.
            let counted = trips.map { (trip: $0, count: countryCount($0)) }
            return counted.sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                if lhs.trip.startDate != rhs.trip.startDate { return lhs.trip.startDate > rhs.trip.startDate }
                return lhs.trip.id.uuidString < rhs.trip.id.uuidString
            }.map(\.trip)
        case .nameAZ:
            let namedTrips = trips.map { (trip: $0, name: $0.displayName) }
            return namedTrips.sorted { lhs, rhs in
                let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                if lhs.trip.startDate != rhs.trip.startDate { return lhs.trip.startDate > rhs.trip.startDate }
                return lhs.trip.id.uuidString < rhs.trip.id.uuidString
            }.map(\.trip)
        }
    }

    /// How "big" a trip was, for the `.significanceHighest` display ranking:
    /// the `TripConfidence` score shape — log₂ distance × log-scaled duration
    /// — evaluated over the trip's STORED fields. `D` is the farthest any of
    /// the trip's stays reached (`Stay.distanceFromHomeKm`, the min-over-
    /// homes-active-at-the-time POINT distance — the same home-at-the-time
    /// semantics as Wrapped's `farthestFromHome`). `T` is the trip duration
    /// (ongoing → `now`, matching `durationSeconds`).
    ///
    /// The distance unit is `1 km` — the model's documented `D*` floor — NOT
    /// the live home shape's `areaEquivalentRadiusKm`. Deliberate, three ways:
    /// the sort path is synchronous while `HomeShapeProvider` is an actor; a
    /// fixed unit keeps the ranking stable when the user edits or moves home
    /// (a *display* order shouldn't reshuffle history on a Settings change);
    /// and any single positive scale yields a deterministic total order, which
    /// is all a sort needs. This is a ranking key, never a gate — θ and trip
    /// existence are untouched. Internal (not private) as a test seam.
    static func significance(_ trip: Trip, now: Date) -> Double {
        let farthestKm = (trip.stays ?? []).map(\.distanceFromHomeKm).max() ?? 0
        let hours = durationSeconds(trip, now: now) / 3600
        return TripConfidence.score(distanceKm: farthestKm, durationHours: hours, scaleKm: 1)
    }

    /// Duration sort key: the calendar days the row shows (`durationDays`,
    /// or the ongoing row's day count up to `now`), then elapsed seconds.
    private static func durationKey(_ trip: Trip, now: Date) -> (days: Int, seconds: TimeInterval) {
        (trip.durationDays ?? TripsListView.ongoingDisplayDay(for: trip, now: now), durationSeconds(trip, now: now))
    }

    /// Trip duration in seconds, the tiebreak within the duration sorts.
    /// For ongoing trips (`endDate == nil`), uses `Date.now` as the
    /// effective end — this puts a 3-day-old open trip at "3 days" rather
    /// than "0" / Int.min / etc., which matches user intuition for an
    /// active journey.
    private static func durationSeconds(_ trip: Trip, now: Date) -> TimeInterval {
        let end = trip.endDate ?? now
        return max(0, end.timeIntervalSince(trip.startDate))
    }

    /// One `cachedPhotoCount` call per trip, snapshotted before sorting.
    private static func photoCountsByTripID(
        _ trips: [Trip],
        photoService: PhotoService
    ) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        counts.reserveCapacity(trips.count)
        for trip in trips {
            counts[trip.id] = photoService.cachedPhotoCount(for: trip.id) ?? 0
        }
        return counts
    }

    /// Unique-country count from the stored `countryCodes` string ("GR,IT,DE").
    /// Uses the same comma-split convention as `Trip.countryFlags` and
    /// `Trip.recomputeSummary`.
    private static func countryCount(_ trip: Trip) -> Int {
        trip.countryCodes
            .split(separator: ",")
            .filter { !$0.isEmpty }
            .count
    }
}
