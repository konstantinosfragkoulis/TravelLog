//
//  TemporaryHomeSuggestion.swift
//  TravelLog
//
//  "Living in Brussels for now?": the question a long trip whose stays
//  point at one city asks on its row and detail page.
//

import CoreLocation
import Foundation

/// A suggestion the user must accept: it declares nothing, and "Set Up" opens
/// the form with the place and dates to review. A resort holiday, a hospital
/// stay or a posting can meet these rules too; the question and that review
/// are the guard. Eligibility never depends on Not Now: a dismissed
/// candidate is still a candidate, so other offers about the trip (the
/// demotion tip) stay off for it.
nonisolated enum TemporaryHomeSuggestion {

    nonisolated struct Candidate: Sendable, Equatable {
        let tripID: UUID
        /// The city the evidence points at, else nil ("here").
        let placeName: String?
        let prefill: TemporaryHomeFormSheet.Prefill
        /// An open trip (row and detail) rather than a completed one (detail only).
        let isOngoing: Bool

        static func == (a: Candidate, b: Candidate) -> Bool {
            a.tripID == b.tripID && a.placeName == b.placeName && a.isOngoing == b.isOngoing
                && a.prefill.name == b.prefill.name
                && a.prefill.coordinate?.latitude == b.prefill.coordinate?.latitude
                && a.prefill.coordinate?.longitude == b.prefill.coordinate?.longitude
                && a.prefill.since == b.prefill.since && a.prefill.until == b.prefill.until
        }
    }

    typealias TripStay = TemporaryHomeFormSheet.Prefill.TripStay

    /// The place a trip's destination evidence points at (`dominantPlace`).
    nonisolated struct Place: Sendable {
        /// The city when its stays carry one; nil for a 1 km cluster.
        let locality: String?
        /// Its logical stays, oldest first.
        let stays: [TripStay]
        /// The centre of the 1 km cluster inside it that holds the most time.
        let pin: CLLocationCoordinate2D
        /// Logical destination time in it, and in the whole trip.
        let seconds: TimeInterval
        let tripSeconds: TimeInterval
    }

    /// Civil days an open trip must have lasted, counted to now.
    static let ongoingMinimumDays = 14
    /// Civil days a completed trip must have lasted.
    static let completedMinimumDays = 28
    /// The place's share of the trip's logical destination time.
    static let minimumShare = 0.5
    /// Distinct overnight dates in the place, and the days they must span.
    static let minimumOvernights = 3
    static let minimumOvernightSpanDays = 7

    // MARK: - Entry points

    /// Reads stored fields of `trip` and its stays only, and the stays only
    /// once the trip is long enough and no temporary home covers it. Nil
    /// when no suggestion applies. Ignores Not Now (`isDismissed`). A trip
    /// whose `CacheKey` is unchanged answers from `cache`.
    @MainActor
    static func candidate(for trip: Trip, temporaryHomes: [TemporaryHome], now: Date) -> Candidate? {
        let anchors = HomeAnchors.collapsingTwins(temporaryHomes).map { HomeAnchor($0) }
        guard isEligible(
            startDate: trip.startDate, endDate: trip.endDate, isComplete: trip.isComplete,
            temporaryHomes: anchors, now: now, timeZone: .current) else { return nil }
        // Mapping the stays is cheap; the clustering a hit skips is not.
        let tripStays = TemporaryHomeFormSheet.Prefill.tripStays(of: trip)
        let key = cacheKey(
            tripID: trip.id, customName: trip.customName, startDate: trip.startDate,
            endDate: trip.endDate, isComplete: trip.isComplete,
            declarations: declarationsFingerprint(anchors), now: now, timeZone: .current,
            staysFingerprint: staysFingerprint(tripStays))
        return cache.candidate(for: key) {
            candidate(
                tripID: trip.id, customName: trip.customName, startDate: trip.startDate,
                endDate: trip.endDate, isComplete: trip.isComplete,
                stays: tripStays,
                temporaryHomes: anchors, now: now, timeZone: .current)
        }
    }

    // MARK: - Cache

    /// What one trip's evaluation depends on beyond `isEligible`, which runs
    /// before every lookup: the trip's stored fields, its stays, the
    /// declarations, the civil day and the zone.
    nonisolated struct CacheKey: Equatable, Sendable {
        let tripID: UUID
        let customName: String?
        let startDate: Date
        let endDate: Date?
        let isComplete: Bool
        let declarations: Int
        /// The start of the civil day of `now` in the evaluation's zone.
        let day: Date
        /// That zone: a stay with none reads its overnights in it, and two
        /// zones can share today's midnight but not a past date's 03:00.
        let zone: String
        /// Every stay field the evaluation reads (`staysFingerprint`), so a
        /// synced move or rename of a stay is a miss.
        var stays: Int = 0
    }

    static func cacheKey(
        tripID: UUID, customName: String?, startDate: Date, endDate: Date?, isComplete: Bool,
        declarations: Int, now: Date, timeZone: TimeZone, staysFingerprint: Int = 0
    ) -> CacheKey {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return CacheKey(
            tripID: tripID, customName: customName, startDate: startDate, endDate: endDate,
            isComplete: isComplete, declarations: declarations,
            day: calendar.startOfDay(for: now), zone: timeZone.identifier, stays: staysFingerprint)
    }

    /// Every field of `stays` the evaluation reads, whatever their order. The
    /// same stays give the same value in this process.
    static func staysFingerprint(_ stays: [TripStay]) -> Int {
        var hasher = Hasher()
        for stay in stays.sorted(by: fingerprintOrder) {
            hasher.combine(stay.id)
            hasher.combine(stay.start)
            hasher.combine(stay.end)
            hasher.combine(stay.latitude)
            hasher.combine(stay.longitude)
            hasher.combine(stay.isDestination)
            hasher.combine(stay.isAirport)
            hasher.combine(stay.locality)
            hasher.combine(stay.isoCountryCode)
            hasher.combine(stay.timeZoneIdentifier)
        }
        return hasher.finalize()
    }

    /// A total order over every field `staysFingerprint` hashes, so two copies
    /// of one stay that differ in any of them never tie on input order.
    private static func fingerprintOrder(_ a: TripStay, _ b: TripStay) -> Bool {
        func less(_ a: String?, _ b: String?) -> Bool {
            guard let a else { return b != nil }
            guard let b else { return false }
            return a < b
        }
        if a.start != b.start { return a.start < b.start }
        if a.id != b.id { return a.id.uuidString < b.id.uuidString }
        if a.end != b.end { return a.end < b.end }
        if a.latitude != b.latitude { return a.latitude < b.latitude }
        if a.longitude != b.longitude { return a.longitude < b.longitude }
        if a.isDestination != b.isDestination { return !a.isDestination }
        if a.isAirport != b.isAirport { return !a.isAirport }
        if a.locality != b.locality { return less(a.locality, b.locality) }
        if a.isoCountryCode != b.isoCountryCode { return less(a.isoCountryCode, b.isoCountryCode) }
        return less(a.timeZoneIdentifier, b.timeZoneIdentifier)
    }

    /// The temporary homes' ids and dates, whatever their order. The same
    /// declarations give the same value in this process.
    static func declarationsFingerprint(_ anchors: [HomeAnchor]) -> Int {
        var hasher = Hasher()
        for anchor in anchors.filter(\.isTemporary).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            hasher.combine(anchor.id)
            hasher.combine(anchor.startedAt)
            hasher.combine(anchor.endedAt)
        }
        return hasher.finalize()
    }

    /// The last answer per trip, reused while its key holds.
    nonisolated struct Cache {
        private var entries: [UUID: (key: CacheKey, candidate: Candidate?)] = [:]

        /// The cached answer for `key`, else `evaluate()`'s, which replaces the trip's entry.
        mutating func candidate(for key: CacheKey, evaluate: () -> Candidate?) -> Candidate? {
            if let entry = entries[key.tripID], entry.key == key { return entry.candidate }
            let candidate = evaluate()
            entries[key.tripID] = (key, candidate)
            return candidate
        }
    }

    @MainActor private static var cache = Cache()

    /// Device-local "Not Now" answers: trip ids, newest last.
    static let dismissalsKey = "temporaryHome.suggestion.notNow"

    /// The most answers kept; the oldest go first.
    private static let dismissalLimit = 200

    static func isDismissed(_ tripID: UUID) -> Bool {
        isDismissed(tripID, defaults: .standard)
    }

    static func dismiss(_ tripID: UUID) {
        dismiss(tripID, defaults: .standard)
    }

    static func isDismissed(_ tripID: UUID, defaults: UserDefaults) -> Bool {
        (defaults.stringArray(forKey: dismissalsKey) ?? []).contains(tripID.uuidString)
    }

    static func dismiss(_ tripID: UUID, defaults: UserDefaults) {
        var ids = (defaults.stringArray(forKey: dismissalsKey) ?? []).filter { $0 != tripID.uuidString }
        ids.append(tripID.uuidString)
        defaults.set(Array(ids.suffix(dismissalLimit)), forKey: dismissalsKey)
    }

    // MARK: - Pure core

    /// The rules that need no stay: an open trip of `ongoingMinimumDays`
    /// civil days so far, or a completed one of `completedMinimumDays`, in
    /// `timeZone` (as `Prefill.isOffered` counts), that no live temporary
    /// home covers: at its start or now while open, at its middle once
    /// completed.
    static func isEligible(
        startDate: Date, endDate: Date?, isComplete: Bool, temporaryHomes: [HomeAnchor],
        now: Date, timeZone: TimeZone
    ) -> Bool {
        let declarations = temporaryHomes.filter(\.isTemporary)
        guard isComplete else {
            return Trip.inclusiveDays(from: startDate, in: timeZone, to: now, in: timeZone) >= ongoingMinimumDays
                && !declarations.contains { $0.covers(startDate) || $0.covers(now) }
        }
        guard let endDate,
              Trip.inclusiveDays(from: startDate, in: timeZone, to: endDate, in: timeZone)
                >= completedMinimumDays else { return false }
        let middle = startDate.addingTimeInterval(endDate.timeIntervalSince(startDate) / 2)
        return !declarations.contains { $0.covers(middle) }
    }

    /// The whole rule: `isEligible`, then a dominant place holding at least
    /// `minimumShare` of the logical destination time and overnight on
    /// `minimumOvernights` distinct dates (a stay covers a date's 03:00 in
    /// its own zone) spanning `minimumOvernightSpanDays` days, first to last.
    static func candidate(
        tripID: UUID, customName: String?, startDate: Date, endDate: Date?, isComplete: Bool,
        stays: [TripStay], temporaryHomes: [HomeAnchor], now: Date, timeZone: TimeZone
    ) -> Candidate? {
        guard isEligible(
            startDate: startDate, endDate: endDate, isComplete: isComplete,
            temporaryHomes: temporaryHomes, now: now, timeZone: timeZone),
              let place = dominantPlace(stays), place.seconds >= minimumShare * place.tripSeconds
        else { return nil }
        let nights = overnightDates(of: place.stays, fallbackZone: timeZone).sorted()
        guard nights.count >= minimumOvernights, let first = nights.first, let last = nights.last,
              Int((last.timeIntervalSince(first) / 86_400).rounded()) + 1 >= minimumOvernightSpanDays
        else { return nil }
        return Candidate(
            tripID: tripID, placeName: place.locality,
            prefill: TemporaryHomeFormSheet.Prefill.forTrip(
                customName: customName, startDate: startDate, endDate: endDate,
                isComplete: isComplete, place: place),
            isOngoing: !isComplete)
    }

    /// The place with the most logical destination time, shared with
    /// "Set Up a Temporary Home…" (`Prefill.forTrip`). Logical stays are one
    /// per stay id, the longest copy; only non-airport destinations with a
    /// positive duration count. Stays that carry a city and country group by
    /// it; the others by 1 km single-linkage clusters. Nil with no evidence.
    static func dominantPlace(_ stays: [TripStay]) -> Place? {
        var logical: [UUID: TripStay] = [:]
        for stay in stays {
            if let kept = logical[stay.id], !isPreferred(stay, over: kept) { continue }
            logical[stay.id] = stay
        }
        let evidence = logical.values
            .filter { $0.isDestination && !$0.isAirport && $0.end > $0.start }
            .sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        guard !evidence.isEmpty else { return nil }

        var cities: [String: [TripStay]] = [:]
        var unplaced: [TripStay] = []
        for stay in evidence {
            if let key = cityKey(stay) { cities[key, default: []].append(stay) } else { unplaced.append(stay) }
        }
        // Cities in key order, then clusters in `HomeOrbit` order: equal totals keep the first.
        var groups: [(locality: String?, stays: [TripStay])] = cities.keys.sorted().map {
            (locality: cities[$0]?.first?.locality, stays: cities[$0] ?? [])
        }
        groups += clusters(of: unplaced).map { (locality: nil as String?, stays: $0.stays) }
        var best: (locality: String?, stays: [TripStay], seconds: TimeInterval)?
        for group in groups {
            let seconds = totalSeconds(group.stays)
            if let current = best, current.seconds >= seconds { continue }
            best = (group.locality, group.stays, seconds)
        }
        guard let best else { return nil }

        var strongest: (cluster: HomeOrbit.Cluster, seconds: TimeInterval)?
        for (cluster, members) in clusters(of: best.stays) {
            let seconds = totalSeconds(members)
            if let current = strongest, current.seconds >= seconds { continue }
            strongest = (cluster, seconds)
        }
        guard let strongest else { return nil }
        return Place(
            locality: best.locality, stays: best.stays,
            pin: CLLocationCoordinate2D(
                latitude: strongest.cluster.latitude, longitude: strongest.cluster.longitude),
            seconds: best.seconds, tripSeconds: totalSeconds(evidence))
    }

    /// The civil dates whose 03:00 a stay covers, read in the stay's own
    /// zone, as `TravelDays` label keys.
    static func overnightDates(of stays: [TripStay], fallbackZone: TimeZone) -> Set<Date> {
        var dates = Set<Date>()
        for stay in stays {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = StayTimeZone.resolve(stay.timeZoneIdentifier, fallback: fallbackZone)
            var day = calendar.startOfDay(for: stay.start)
            while day <= stay.end {
                if let night = calendar.date(bySettingHour: 3, minute: 0, second: 0, of: day),
                   night >= stay.start, night <= stay.end,
                   let label = TravelDays.labelCalendar.date(
                    from: calendar.dateComponents([.year, .month, .day], from: day)) {
                    dates.insert(label)
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return dates
    }

    // MARK: - Helpers

    /// Of two copies of one stay, the longer; equal ones by start, then the
    /// destination copy, then position, so the input order never decides.
    private static func isPreferred(_ a: TripStay, over b: TripStay) -> Bool {
        let (lengthA, lengthB) = (a.end.timeIntervalSince(a.start), b.end.timeIntervalSince(b.start))
        if lengthA != lengthB { return lengthA > lengthB }
        if a.start != b.start { return a.start < b.start }
        if a.isDestination != b.isDestination { return a.isDestination }
        return (a.latitude, a.longitude) < (b.latitude, b.longitude)
    }

    /// "GR|Athens" when the stay carries both a city and a country.
    private static func cityKey(_ stay: TripStay) -> String? {
        guard let locality = stay.locality?.trimmingCharacters(in: .whitespacesAndNewlines),
              !locality.isEmpty,
              let country = stay.isoCountryCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !country.isEmpty else { return nil }
        return country.uppercased() + "|" + locality
    }

    private static func totalSeconds(_ stays: [TripStay]) -> TimeInterval {
        stays.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    /// 1 km single-linkage clusters of `stays`, each with its stays, in
    /// `HomeOrbit.clusters`' fixed order. Every provenance counts here, so
    /// each stay is passed as live.
    private static func clusters(of stays: [TripStay]) -> [(cluster: HomeOrbit.Cluster, stays: [TripStay])] {
        let byID = Dictionary(stays.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let observations = stays.map {
            HomeOrbit.StayObservation(
                id: $0.id, start: $0.start, end: $0.end,
                latitude: $0.latitude, longitude: $0.longitude,
                isTransitNode: false, isLive: true)
        }
        return HomeOrbit.clusters(from: observations).map { cluster in
            (cluster: cluster, stays: cluster.members.compactMap { byID[$0.id] })
        }
    }
}
