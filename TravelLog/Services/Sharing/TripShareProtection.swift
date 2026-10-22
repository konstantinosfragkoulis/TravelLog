//
//  TripShareProtection.swift
//  TravelLog
//
//  Protected time, as every shared output reads it: a place at an instant
//  is protected when `TripClassifier.matchesHome` puts it inside one of the
//  sender's home anchors (real or temporary) then. A span is protected
//  when any instant of it is, so a Visit or stay that only departs inside a
//  home's dates, or that a temporary home starts during, is caught. A line
//  between two shared points is protected when any point on it is during
//  the span between them; the GPX route and the card's route break there,
//  and wherever the export removed evidence (`TripShareExclusions`).
//

import Foundation

nonisolated extension TripShareExport {

    /// Whether any instant of `span` at the place is protected.
    /// `matchesHome` can only change where a ring's dates, a temporary
    /// home's era or an orbit disc's validity begins or ends, so it is read
    /// at the span's ends, at each such instant inside it, and once between
    /// each neighbouring pair.
    static func isInsideHome(
        during span: DateInterval, latitude: Double, longitude: Double,
        rings: [TripClassifier.HomeRing]
    ) -> Bool {
        guard !rings.isEmpty else { return false }
        var instants = [span.start, span.end]
        func add(_ date: Date) {
            if span.start < date && date < span.end { instants.append(date) }
        }
        for ring in rings {
            add(ring.startedAt)
            if let endedAt = ring.endedAt { add(endedAt) }
            guard let membership = ring.membership else { continue }
            if let era = membership.era { add(era.start); add(era.end) }
            for disc in membership.orbitDiscs {
                for window in disc.validity { add(window.start); add(window.end) }
            }
        }
        instants.sort()
        var previous: Date?
        for instant in instants {
            if let previous {
                guard instant > previous else { continue }
                let between = previous.addingTimeInterval(instant.timeIntervalSince(previous) / 2)
                if isInsideHome(between, latitude: latitude, longitude: longitude, rings: rings) { return true }
            }
            if isInsideHome(instant, latitude: latitude, longitude: longitude, rings: rings) { return true }
            previous = instant
        }
        return false
    }

    /// Points closer than this to a ring's area are read one by one.
    static let lineProbeKm = 0.01

    /// Whether the straight line from `a` to `b`, as a map draws it (linear
    /// in latitude and longitude), passes a protected place during `span`.
    /// It walks the line by the distance to the nearest area that could
    /// claim any instant of the span, so open country costs a few steps and
    /// only the stretch beside a home is read closely.
    static func lineCrossesHome(
        from a: (latitude: Double, longitude: Double), to b: (latitude: Double, longitude: Double),
        during span: DateInterval, rings: [TripClassifier.HomeRing]
    ) -> Bool {
        let nearby = ringsClaiming(span, rings: rings)
        guard !nearby.isEmpty else { return false }
        let dLat = b.latitude - a.latitude
        let dLon = GeoMath.wrappedLongitudeDelta(b.longitude, a.longitude)
        // Kilometres per unit of the line's parameter, an upper bound
        // anywhere on it (a degree of longitude is never longer than one of
        // latitude), so a step never outruns the clearance it was sized by.
        let kmPerUnit = (dLat * dLat + dLon * dLon).squareRoot() * 111.195
        var t = 0.0
        while true {
            let latitude = a.latitude + dLat * t
            let longitude = GeoMath.normalizedLongitude(a.longitude + dLon * t)
            let clearance = nearby.map { reachKm(latitude: latitude, longitude: longitude, ring: $0, during: span) }
                .min() ?? .infinity
            if clearance <= lineProbeKm,
               isInsideHome(during: span, latitude: latitude, longitude: longitude, rings: rings) {
                return true
            }
            guard t < 1, kmPerUnit > 0 else { return false }
            t = min(1, t + max(clearance * 0.9, lineProbeKm) / kmPerUnit)
        }
    }

    /// The rings that could claim some instant of `span`: those whose
    /// dates meet it, and every real home when part of it predates them all
    /// (`matchesHome`'s prehistory pass).
    static func ringsClaiming(_ span: DateInterval, rings: [TripClassifier.HomeRing]) -> [TripClassifier.HomeRing] {
        let prehistory = rings.contains { $0.claimsPrehistory && $0.endedAt == nil }
            && rings.allSatisfy { !$0.claimsPrehistory || span.start < $0.startedAt }
        return rings.filter { ring in
            (ring.startedAt <= span.end && (ring.endedAt.map { $0 >= span.start } ?? true))
                || (prehistory && ring.claimsPrehistory)
        }
    }

    /// Kilometres from a point to the nearest part of the ring's area that
    /// could hold during `span`, never more than the true distance: the
    /// seed, the orbit discs valid in it and the taught includes, with
    /// exclusions ignored; the declared radius for a ring without measured
    /// membership.
    static func reachKm(
        latitude: Double, longitude: Double, ring: TripClassifier.HomeRing, during span: DateInterval
    ) -> Double {
        guard let membership = ring.membership else {
            return max(0, HomeOrbit.greatCircleKm(latitude, longitude, ring.latitude, ring.longitude) - ring.radiusKm)
        }
        var best = membership.seed.distanceKm(toLatitude: latitude, longitude: longitude)
        for disc in membership.orbitDiscs
        where disc.validity.contains(where: { $0.start <= span.end && $0.end >= span.start }) {
            best = min(best, disc.distanceKm(toLatitude: latitude, longitude: longitude))
        }
        for disc in membership.includeDiscs {
            best = min(best, max(0, HomeOrbit.greatCircleKm(latitude, longitude, disc.latitude, disc.longitude)
                                     - disc.radiusKm))
        }
        return best
    }

    /// `a` to `b` as a span, whichever comes first.
    static func span(_ a: Date, _ b: Date) -> DateInterval {
        DateInterval(start: min(a, b), end: max(a, b))
    }
}

/// What the route drawings need to break their lines: the rings the export
/// judged against and, per trip, the spans whose evidence it removed. Kept
/// beside the file, never written into anything shared.
nonisolated struct TripShareExclusions: Sendable, Equatable {
    var rings: [TripClassifier.HomeRing] = []
    /// Merged, sorted and disjoint, per share id.
    var removed: [UUID: [DateInterval]] = [:]

    /// A shared point: where and when.
    struct Point: Sendable {
        let latitude: Double
        let longitude: Double
        let date: Date
    }

    /// Whether a line may join `a` to `b` of one trip: never across a span
    /// whose evidence the export removed, and never through a protected
    /// place.
    func joins(trip: UUID, _ a: Point, _ b: Point) -> Bool {
        let span = TripShareExport.span(a.date, b.date)
        if Self.overlaps(removed[trip] ?? [], span) { return false }
        return !TripShareExport.lineCrossesHome(
            from: (a.latitude, a.longitude), to: (b.latitude, b.longitude), during: span, rings: rings)
    }

    /// Whether any of the merged `spans` reaches inside the open `span`.
    static func overlaps(_ spans: [DateInterval], _ span: DateInterval) -> Bool {
        // The first span ending after `span` starts is the only candidate.
        var low = 0, high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if spans[mid].end > span.start { high = mid } else { low = mid + 1 }
        }
        return low < spans.count && spans[low].start < span.end
    }

    /// `spans` sorted and merged where they touch.
    static func merged(_ spans: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, span.start <= last.end {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, span.end))
            } else {
                result.append(span)
            }
        }
        return result
    }

    static func == (lhs: TripShareExclusions, rhs: TripShareExclusions) -> Bool {
        lhs.removed == rhs.removed && lhs.rings.elementsEqual(rhs.rings) { a, b in
            a.latitude == b.latitude && a.longitude == b.longitude && a.radiusKm == b.radiusKm
                && a.startedAt == b.startedAt && a.endedAt == b.endedAt && a.homeID == b.homeID
                && a.membership == b.membership && a.claimsPrehistory == b.claimsPrehistory
                && a.isTemporary == b.isTemporary
        }
    }
}
