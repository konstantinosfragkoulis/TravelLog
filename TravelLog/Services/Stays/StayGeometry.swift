//
//  StayGeometry.swift
//  TravelLog
//

import CoreLocation
import Foundation
/// Immutable `LocationPing` fields for deterministic, SwiftData-free repair math.
nonisolated struct StayGeometryPing: Equatable, Sendable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let sourceRaw: String
}

nonisolated struct StayGeometryVisit: Equatable, Sendable {
    let id: UUID
    let arrivalDate: Date
    let departureDate: Date?
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let receivedAt: Date

    var effectiveEnd: Date {
        departureDate ?? max(arrivalDate, receivedAt)
    }
}

/// Stay fields derived from pings and Visits; callers apply H3/airport metadata.
nonisolated struct StayGeometry: Equatable, Sendable {
    let startTime: Date
    let endTime: Date
    let durationMinutes: Int
    let centroidLatitude: Double
    let centroidLongitude: Double
    let sourceRaw: String

    /// Rebuild from ordered pings and canonical Visits; only Visit bounds clamp.
    static func recompute(
        from pings: [StayGeometryPing],
        visits: [StayGeometryVisit],
        earliestAllowedStart: Date?,
        latestAllowedEnd: Date?
    ) -> StayGeometry? {
        guard pings.allSatisfy({ Self.isValid(ping: $0) }) else { return nil }
        let canonicalVisits = Self.canonicalVisits(from: visits)
        guard !pings.isEmpty || !canonicalVisits.isEmpty else { return nil }

        var pingStart: Date?
        var pingEnd: Date?
        var centroidLatitude: Double?
        var centroidLongitude: Double?
        let normalizedSourceRaw: (String) -> String = {
            DataSource(rawValue: $0)?.derivedRecordSource.rawValue ?? $0
        }
        var sourceRaws: Set<String> = []
        for (offset, ping) in pings.enumerated() {
            pingStart = min(pingStart ?? ping.timestamp, ping.timestamp)
            pingEnd = max(pingEnd ?? ping.timestamp, ping.timestamp)
            let newCount = Double(offset + 1)
            centroidLatitude = (centroidLatitude ?? ping.latitude)
                + (ping.latitude - (centroidLatitude ?? ping.latitude)) / newCount
            centroidLongitude = GeoMath.runningMeanLongitude(
                current: centroidLongitude ?? GeoMath.normalizedLongitude(ping.longitude),
                adding: ping.longitude,
                newCount: newCount
            )
            sourceRaws.insert(normalizedSourceRaw(ping.sourceRaw))
        }

        var visitStart = canonicalVisits.map(\.arrivalDate).min()
        var visitEnd = canonicalVisits.map(\.effectiveEnd).max()
        if let earliestAllowedStart, let start = visitStart {
            visitStart = max(start, earliestAllowedStart)
        }
        if let latestAllowedEnd, let end = visitEnd {
            visitEnd = min(end, latestAllowedEnd)
        }
        if let start = visitStart, let end = visitEnd {
            visitEnd = max(end, start)
        }

        let startTime = min(pingStart ?? visitStart!, visitStart ?? pingStart!)
        let endTime = max(pingEnd ?? visitEnd!, visitEnd ?? pingEnd!)
        if centroidLatitude == nil,
           let bestVisit = canonicalVisits.min(by: {
               $0.horizontalAccuracy != $1.horizontalAccuracy
                   ? $0.horizontalAccuracy < $1.horizontalAccuracy
                   : $0.id.uuidString < $1.id.uuidString
           }) {
            centroidLatitude = bestVisit.latitude
            centroidLongitude = bestVisit.longitude
        }

        let sourceRaw: String = if canonicalVisits.isEmpty {
            sourceRaws.count == 1
                ? (sourceRaws.first ?? pings[0].sourceRaw)
                : DataSource.merged.rawValue
        } else if pings.isEmpty || sourceRaws.allSatisfy({
            $0 == DataSource.liveSLC.rawValue
        }) {
            DataSource.liveSLC.rawValue
        } else {
            DataSource.merged.rawValue
        }

        return StayGeometry(
            startTime: startTime,
            endTime: endTime,
            durationMinutes: max(0, Int(endTime.timeIntervalSince(startTime) / 60)),
            centroidLatitude: centroidLatitude!,
            centroidLongitude: centroidLongitude!,
            sourceRaw: sourceRaw
        )
    }

    private static func isValid(ping: StayGeometryPing) -> Bool {
        ping.timestamp.timeIntervalSinceReferenceDate.isFinite
            && ping.latitude.isFinite
            && ping.longitude.isFinite
            && (-90...90).contains(ping.latitude)
            && (-180...180).contains(ping.longitude)
    }

    private static func canonicalVisits(from visits: [StayGeometryVisit]) -> [StayGeometryVisit] {
        let valid = visits.filter { visit in
            visit.arrivalDate.timeIntervalSinceReferenceDate.isFinite
                && visit.receivedAt.timeIntervalSinceReferenceDate.isFinite
                && visit.latitude.isFinite
                && visit.longitude.isFinite
                && visit.horizontalAccuracy.isFinite
                && (-90...90).contains(visit.latitude)
                && (-180...180).contains(visit.longitude)
                && visit.departureDate.map {
                    $0.timeIntervalSinceReferenceDate.isFinite && $0 > visit.arrivalDate
                } ?? true
        }.sorted {
            $0.arrivalDate != $1.arrivalDate
                ? $0.arrivalDate < $1.arrivalDate
                : $0.id.uuidString < $1.id.uuidString
        }
        var groups: [[StayGeometryVisit]] = []
        for visit in valid {
            let bits = visit.arrivalDate.timeIntervalSinceReferenceDate.bitPattern
            let location = CLLocation(latitude: visit.latitude, longitude: visit.longitude)
            if let index = groups.firstIndex(where: { group in
                group[0].arrivalDate.timeIntervalSinceReferenceDate.bitPattern == bits
                    && location.distance(from: CLLocation(latitude: group[0].latitude,
                        longitude: group[0].longitude)) <= 3_000
            }) {
                groups[index].append(visit)
            } else {
                groups.append([visit])
            }
        }
        return groups.compactMap { group in
            group.min { lhs, rhs in
                let lhsClosed = lhs.departureDate != nil
                let rhsClosed = rhs.departureDate != nil
                if lhsClosed != rhsClosed { return lhsClosed }
                if lhs.horizontalAccuracy != rhs.horizontalAccuracy {
                    return lhs.horizontalAccuracy < rhs.horizontalAccuracy
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }
}
