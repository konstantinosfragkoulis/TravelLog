import Foundation
import SwiftData

/// Inclusive trip-span civil dates, shared by Stats, Passport, Siri and Wrapped.
/// Keys encode Gregorian date labels at UTC midnight, not the instant of local
/// midnight. Consumers must bucket them with `labelCalendar` even west of UTC.
nonisolated enum TravelDays {
    /// Fixed, so built once: day loops read it for every label.
    static let labelCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static let maxSpanDays = 3_650

    static func label(for date: Date, zone: TimeZone) -> Date? {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        return labelCalendar.date(from: local.dateComponents([.year, .month, .day], from: date))
    }

    /// The boundary rule every trip day count shares, `Trip.durationDays`
    /// included: the first stay starts earliest and the last ends latest, and
    /// equal instants go to the smallest UUID so every device reads one zone.
    static func startsFirst(_ date: Date, _ id: UUID, before other: Date, _ otherID: UUID) -> Bool {
        date == other ? id.uuidString < otherID.uuidString : date < other
    }

    static func endsLast(_ date: Date, _ id: UUID, after other: Date, _ otherID: UUID) -> Bool {
        date == other ? id.uuidString < otherID.uuidString : date > other
    }

    /// A trip's boundary stays under that rule; of same-UUID copies the first met wins.
    static func boundaryStays(of stays: [Stay]) -> (first: Stay?, last: Stay?) {
        boundaryStays(of: stays, checkCancellation: {})
    }

    static func boundaryStays(
        of stays: [Stay], checkCancellation: () throws -> Void
    ) rethrows -> (first: Stay?, last: Stay?) {
        // The leaders' keys are kept as values: each stay's fields are read once.
        var first: (stay: Stay, date: Date, id: UUID)?
        var last: (stay: Stay, date: Date, id: UUID)?
        for stay in stays {
            try checkCancellation()
            let id = stay.id
            let start = stay.startTime
            if first.map({ startsFirst(start, id, before: $0.date, $0.id) }) ?? true {
                first = (stay, start, id)
            }
            let end = stay.endTime
            if last.map({ endsLast(end, id, after: $0.date, $0.id) }) ?? true {
                last = (stay, end, id)
            }
        }
        return (first?.stay, last?.stay)
    }

    struct Span {
        let start: Date
        let end: Date?
        let firstZone: String?
        let lastZone: String?
    }

    private struct Boundary {
        let date: Date
        let id: UUID
        let zone: String?
    }

    /// Already-materialized model path used by the full Stats reduction.
    static func labels(
        trips: [Trip], now: Date = .now, fallbackZone: TimeZone = .current
    ) -> Set<Date> {
        labels(trips: trips, now: now, fallbackZone: fallbackZone, checkCancellation: {})
    }

    static func labels(
        trips: [Trip], now: Date = .now, fallbackZone: TimeZone = .current,
        checkCancellation: () throws -> Void
    ) rethrows -> Set<Date> {
        try labels(spans: spans(trips: trips, checkCancellation: checkCancellation),
                   now: now, fallbackZone: fallbackZone, checkCancellation: checkCancellation)
    }

    /// One span per trip, in input order, from one walk of each trip's stays.
    /// Stats reuses them for the day labels, the year ledger and
    /// `Trip.durationDays`, which would otherwise walk `Trip.stays` again.
    static func spans(
        trips: [Trip], checkCancellation: () throws -> Void
    ) rethrows -> [Span] {
        try checkCancellation()
        return try trips.map { trip in
            try checkCancellation()
            let boundary = try boundaryStays(of: trip.stays ?? [], checkCancellation: checkCancellation)
            return Span(start: trip.startDate, end: trip.endDate,
                        firstZone: boundary.first?.timeZoneIdentifier,
                        lastZone: boundary.last?.timeZoneIdentifier)
        }
    }

    /// Focused consumers need only trip dates and boundary time zones. Keep
    /// this context separate from other projections and never walk Trip.stays:
    /// that to-many fault would materialize weather and ping payloads.
    static func labels(
        container: ModelContainer, now: Date = .now, fallbackZone: TimeZone = .current,
        checkCancellation: () throws -> Void = {}
    ) throws -> Set<Date> {
        try checkCancellation()
        let context = ModelContext(container)
        var tripDescriptor = FetchDescriptor<Trip>()
        tripDescriptor.propertiesToFetch = [\.startDate, \.endDate]
        let trips = try context.fetch(tripDescriptor)
        try checkCancellation()
        guard !trips.isEmpty else { return [] }
        var stayDescriptor = FetchDescriptor<Stay>(predicate: #Predicate { $0.trip != nil })
        stayDescriptor.propertiesToFetch = [\.id, \.startTime, \.endTime, \.timeZoneIdentifier, \.trip]
        try checkCancellation()
        let stays = try context.fetch(stayDescriptor)
        try checkCancellation()
        let spans = try projectedSpans(trips: trips, boundaryStays: stays,
                                       checkCancellation: checkCancellation)
        return try labels(spans: Array(spans.values), now: now, fallbackZone: fallbackZone,
                          checkCancellation: checkCancellation)
    }

    /// One scalar span per physical trip, keeping UUID twins distinct. Reads
    /// only projected fields; the to-many `Trip.stays` relationship stays lazy.
    static func projectedSpans(
        trips: [Trip], boundaryStays: [Stay], checkCancellation: () throws -> Void
    ) rethrows -> [PersistentIdentifier: Span] {
        var boundaries: [PersistentIdentifier: (first: Boundary, last: Boundary)] = [:]
        for stay in boundaryStays {
            try checkCancellation()
            // The projected to-one reference supplies physical identity; its
            // Trip fields and inverse stays relationship are never read.
            guard let tripID = stay.trip?.persistentModelID else { continue }
            let id = stay.id
            let zone = stay.timeZoneIdentifier
            let first = Boundary(date: stay.startTime, id: id, zone: zone)
            let last = Boundary(date: stay.endTime, id: id, zone: zone)
            if var existing = boundaries[tripID] {
                if startsFirst(first.date, first.id, before: existing.first.date, existing.first.id) {
                    existing.first = first
                }
                if endsLast(last.date, last.id, after: existing.last.date, existing.last.id) {
                    existing.last = last
                }
                boundaries[tripID] = existing
            } else {
                boundaries[tripID] = (first, last)
            }
        }
        var spans: [PersistentIdentifier: Span] = [:]
        for trip in trips {
            try checkCancellation()
            let tripID = trip.persistentModelID
            let boundary = boundaries[tripID]
            spans[tripID] = Span(start: trip.startDate, end: trip.endDate,
                                 firstZone: boundary?.first.zone,
                                 lastZone: boundary?.last.zone)
        }
        return spans
    }

    static func labels(
        spans: [Span], now: Date, fallbackZone: TimeZone,
        checkCancellation: () throws -> Void
    ) rethrows -> Set<Date> {
        let calendar = labelCalendar
        var result = Set<Date>()
        for span in spans {
            try checkCancellation()
            guard span.start <= now else { continue }
            let end = min(max(span.end ?? now, span.start), now)
            guard var day = label(for: span.start, zone: StayTimeZone.resolve(
                span.firstZone, fallback: fallbackZone)),
                  let endLabel = label(for: end, zone: StayTimeZone.resolve(
                    span.lastZone, fallback: fallbackZone)) else { continue }
            // Date-line travel or malformed boundaries retain the one-day
            // minimum used by Trip.durationDays.
            let last = max(day, endLabel)
            if let length = calendar.dateComponents([.day], from: day, to: last).day,
               length > maxSpanDays,
               let clamped = calendar.date(byAdding: .day, value: -maxSpanDays, to: last) {
                day = clamped
            }
            while day <= last {
                try checkCancellation()
                result.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return result
    }

    /// Labels for spans that are not trips (`TemporaryHomeLedger`'s staying
    /// spans). They go through the trip reducer itself, so zone resolution,
    /// the one-day minimum, the future clip and the span clamp are one code path.
    static func labels(
        forSpans spans: [(start: Date, end: Date, firstZone: String?, lastZone: String?)],
        now: Date, fallbackZone: TimeZone,
        checkCancellation: () throws -> Void
    ) rethrows -> Set<Date> {
        try labels(
            spans: spans.map {
                Span(start: $0.start, end: $0.end, firstZone: $0.firstZone, lastZone: $0.lastZone)
            },
            now: now, fallbackZone: fallbackZone, checkCancellation: checkCancellation)
    }

    static func count(_ labels: Set<Date>, inYear year: Int) -> Int {
        count(labels, inYear: year, checkCancellation: {})
    }

    static func count(
        _ labels: Set<Date>, inYear year: Int, checkCancellation: () throws -> Void
    ) rethrows -> Int {
        try checkCancellation()
        guard year > 0, year < 10_000 else { return 0 }
        return try labels.count {
            try checkCancellation()
            return labelCalendar.component(.year, from: $0) == year
        }
    }

    static func daysInYear(_ year: Int) -> Int {
        guard year > 0, year < 10_000,
              let start = labelCalendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { return 365 }
        return labelCalendar.range(of: .day, in: .year, for: start)?.count ?? 365
    }

    /// Separate day inputs from the start-year/completed scopes of other
    /// statistics. Fetching all trip spans includes carry-in and ongoing rows;
    /// filtering by UTC start year would lose valid local New Year dates.
    static func count(
        inYear year: Int, container: ModelContainer,
        now: Date = .now, fallbackZone: TimeZone = .current,
        checkCancellation: () throws -> Void = {}
    ) throws -> Int {
        return try count(labels(container: container, now: now, fallbackZone: fallbackZone,
                                checkCancellation: checkCancellation),
                         inYear: year, checkCancellation: checkCancellation)
    }
}
