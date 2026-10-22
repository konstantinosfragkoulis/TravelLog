import Foundation
import SwiftData

/// Retained acquisition evidence, copied before the pure flight reductions.
/// Stored stay ends may include clustering's speculative tail. Only a real
/// member fix or a linked Visit supplies a measured departure boundary.
nonisolated enum FlightObservationBounds {
    nonisolated struct Evidence: Sendable, Equatable {
        let firstObservedAt: Date?
        let lastObservedAt: Date?
        let retainedSourceRaws: [String]
        let memberEvidenceComplete: Bool

        init(firstObservedAt: Date? = nil, lastObservedAt: Date?, retainedSourceRaws: [String], memberEvidenceComplete: Bool) {
            self.firstObservedAt = firstObservedAt
            self.lastObservedAt = lastObservedAt
            self.retainedSourceRaws = retainedSourceRaws
            self.memberEvidenceComplete = memberEvidenceComplete
        }
    }

    /// Required reads throw; a failed read is never evidence of an empty
    /// history. Bounded fetches release model arrays between chunks, and the
    /// caller's cancellation check keeps large imported histories interruptible.
    static func fetch(
        stays: [Stay], in context: ModelContext,
        checkCancellation: () throws -> Void = {}
    ) throws -> [PersistentIdentifier: Evidence] {
        var result: [PersistentIdentifier: Evidence] = [:]
        let uniqueRows = Dictionary(stays.map { ($0.persistentModelID, $0) },
                                    uniquingKeysWith: { first, _ in first }).values
        let rows = Array(uniqueRows)
        // A Visit's stayID is logical. It cannot choose between physical UUID
        // twins, even when only one twin happened to enter this neighbourhood.
        let logicalIDs = Array(Set(rows.map(\.id)))
        var twinCounts: [UUID: Int] = [:]
        for offset in stride(from: 0, to: logicalIDs.count, by: 512) {
            try checkCancellation()
            let ids = Array(logicalIDs[offset..<min(offset + 512, logicalIDs.count)])
            var descriptor = FetchDescriptor<Stay>(predicate: #Predicate { ids.contains($0.id) })
            descriptor.propertiesToFetch = [\.id]
            for stay in try context.fetch(descriptor) where !stay.isDeleted {
                twinCounts[stay.id, default: 0] += 1
            }
        }
        for offset in stride(from: 0, to: rows.count, by: 128) {
            try checkCancellation()
            let batch = Array(rows[offset..<min(offset + 128, rows.count)])
            let idsByRow = batch.map { Set($0.pingIDs) }
            let pingIDs = Array(Set(idsByRow.flatMap { $0 }))
            var pings: [UUID: PingEvidence] = [:]
            for pingOffset in stride(from: 0, to: pingIDs.count, by: 512) {
                try checkCancellation()
                let ids = Array(pingIDs[pingOffset..<min(pingOffset + 512, pingIDs.count)])
                var descriptor = FetchDescriptor<LocationPing>(predicate: #Predicate { ids.contains($0.id) })
                descriptor.propertiesToFetch = [\.id, \.timestamp, \.latitude, \.longitude,
                                                \.sourceRaw, \.horizontalAccuracy]
                for ping in try context.fetch(descriptor) where !ping.isDeleted {
                    let value = PingValue(ping)
                    if pings[ping.id] != nil { pings[ping.id]?.merge(value) }
                    else { pings[ping.id] = PingEvidence(value) }
                }
            }
            let stayIDs = Array(Set(batch.filter { twinCounts[$0.id] == 1 }.map(\.id)))
            var visits: [UUID: [VisitValue]] = [:]
            if !stayIDs.isEmpty {
                let linkedStayIDs: [UUID?] = stayIDs.map { $0 }
                let descriptor = FetchDescriptor<Visit>(predicate: #Predicate {
                    linkedStayIDs.contains($0.stayID)
                })
                for visit in try context.fetch(descriptor) where !visit.isDeleted {
                    if let stayID = visit.stayID { visits[stayID, default: []].append(VisitValue(visit)) }
                }
            }
            for (index, stay) in batch.enumerated() {
                try checkCancellation()
                let memberIDs = idsByRow[index]
                var sources: Set<String> = []
                var first: Date?
                var last: Date?
                var hasVisitObservation = false
                for id in memberIDs {
                    guard let evidence = pings[id] else { continue }
                    sources.formUnion(evidence.rawSources)
                    // UUID twins that disagree cannot identify a measured fix.
                    let value = evidence.first
                    guard evidence.agrees,
                          value.hasObservationTime,
                          value.timestamp >= stay.startTime, value.timestamp <= stay.endTime,
                          value.isValid else { continue }
                    last = max(last ?? value.timestamp, value.timestamp)
                    first = min(first ?? value.timestamp, value.timestamp)
                }
                for visit in visits[stay.id] ?? [] {
                    guard let end = visit.measuredEnd,
                          FlightJudge.haversineKm(stay.centroidLatitude, stay.centroidLongitude,
                                                  visit.latitude, visit.longitude) <= FlightJudge.clusterErrorKm
                    else { continue }
                    // A neighbouring stay can clip either boundary. Retain
                    // each actual in-range instant without clamping the other.
                    for observed in [visit.arrival, end]
                    where observed >= stay.startTime && observed <= stay.endTime {
                        hasVisitObservation = true
                        last = max(last ?? observed, observed)
                        first = min(first ?? observed, observed)
                    }
                }
                result[stay.persistentModelID] = Evidence(
                    firstObservedAt: first, lastObservedAt: last, retainedSourceRaws: sources.sorted(),
                    memberEvidenceComplete: memberIDs.isEmpty
                        ? hasVisitObservation && stay.sourceRaw == DataSource.liveSLC.rawValue
                        : memberIDs.allSatisfy { pings[$0] != nil })
            }
        }
        return result
    }

    private struct PingEvidence {
        let first: PingValue
        var rawSources: Set<String>
        var agrees = true
        init(_ value: PingValue) { first = value; rawSources = [value.sourceRaw] }
        mutating func merge(_ value: PingValue) {
            rawSources.insert(value.sourceRaw)
            agrees = agrees && value.sameObservation(as: first)
        }
    }

    private struct PingValue {
        let timestamp: Date
        let latitude: Double
        let longitude: Double
        let sourceRaw: String
        let horizontalAccuracy: Double
        init(_ ping: LocationPing) {
            timestamp = ping.timestamp; latitude = ping.latitude; longitude = ping.longitude
            sourceRaw = ping.sourceRaw; horizontalAccuracy = ping.horizontalAccuracy
        }
        var isValid: Bool {
            timestamp.timeIntervalSinceReferenceDate.isFinite && latitude.isFinite && longitude.isFinite
                && (-90...90).contains(latitude) && (-180...180).contains(longitude)
                && horizontalAccuracy.isFinite && horizontalAccuracy >= 0
        }
        var hasObservationTime: Bool {
            switch DataSource(rawValue: sourceRaw) {
            case .liveSLC, .foregroundStream, .photoImport, .gpxImport: true
            // Timeline can interpolate waypoints; JSON can synthesize stay
            // endpoints. A share flattens those original tags, and a merged
            // ping cannot recover which producer supplied its timestamp.
            case .timelineImport, .jsonImport, .sharedImport, .merged, nil: false
            }
        }
        func sameObservation(as other: Self) -> Bool {
            timestamp == other.timestamp && latitude == other.latitude && longitude == other.longitude
                && sourceRaw == other.sourceRaw && horizontalAccuracy == other.horizontalAccuracy
        }
    }

    private struct VisitValue {
        let arrival: Date
        let departure: Date?
        let received: Date
        let latitude: Double
        let longitude: Double
        let accuracy: Double
        init(_ visit: Visit) {
            arrival = visit.arrivalDate; departure = visit.departureDate; received = visit.receivedAt
            latitude = visit.latitude; longitude = visit.longitude; accuracy = visit.horizontalAccuracy
        }
        var measuredEnd: Date? {
            // A callback may arrive long after the visit began. Receipt time
            // does not measure continued presence at the callback location.
            let end = departure ?? arrival
            guard arrival.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite,
                  end >= arrival, latitude.isFinite, longitude.isFinite,
                  (-90...90).contains(latitude), (-180...180).contains(longitude),
                  accuracy.isFinite, accuracy >= 0 else { return nil }
            return end
        }
    }
}
