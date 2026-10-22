import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct FlightLogAuthorityTwinOrderRegressionTests {
    @Test("a stable classified/backlog origin twin cannot make every fresh confirmation stale")
    func classifiedAndBacklogOriginTwinsKeepActionAuthority() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_689_718_400)
        func origin() -> Stay {
            let stay = Stay(startTime: base, endTime: base.addingTimeInterval(2 * 3600),
                            centroidLatitude: 37.9364, centroidLongitude: 23.9445,
                            h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 30, pingIDs: [])
            stay.category = .transit
            stay.isAirport = true
            stay.isoCountryCode = "GR"
            stay.sourceRaw = DataSource.photoImport.rawValue
            return stay
        }
        let first = origin(), second = origin()
        second.id = first.id
        let arrival = Stay(startTime: base.addingTimeInterval(5 * 3600),
                           endTime: base.addingTimeInterval(29 * 3600),
                           centroidLatitude: 52.3086, centroidLongitude: 4.76389,
                           h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 2_000, pingIDs: [])
        arrival.category = .destination
        arrival.isAirport = true
        arrival.isoCountryCode = "NL"
        arrival.sourceRaw = DataSource.photoImport.rawValue
        arrival.transitFromPreviousRaw = TransitMode.unknown.rawValue
        context.insert(first); context.insert(second); context.insert(arrival)
        try context.save()

        // Pick the backlog twin using the authority reader's actual store order;
        // this avoids assuming insertion or PersistentIdentifier ordering.
        func authorityFetch(_ context: ModelContext) throws -> [Stay] {
            var descriptor = FetchDescriptor<Stay>()
            descriptor.propertiesToFetch = [\.id, \.startTime, \.endTime, \.categoryRaw, \.transitFromPreviousRaw]
            return try context.fetch(descriptor).filter { !$0.isDeleted }
        }
        let initial = try authorityFetch(context).filter { $0.id == first.id }
        let backlog = try #require(initial.first)
        let classified = try #require(initial.last)
        #expect(backlog.persistentModelID != classified.persistentModelID)
        backlog.category = .unclassified
        try context.save()
        let readContext = ModelContext(container)
        let stableOrder = try authorityFetch(readContext).filter { $0.id == first.id }
        #expect(stableOrder.map(\.persistentModelID) == initial.map(\.persistentModelID))
        #expect(stableOrder.first?.category == .unclassified)

        func target() throws -> FlightLogAuthority.Target {
            let rows = try readContext.fetch(FetchDescriptor<Stay>())
            let evidence = try FlightObservationBounds.fetch(stays: rows, in: readContext)
            let projection = try CollectionsAggregator.flightLogRecords(
                rows: rows.filter { $0.category != .unclassified }.map {
                    CollectionsAggregator.StayRow($0, observationEvidence: evidence[$0.persistentModelID])
                }, predecessorOnly: rows.filter { $0.category == .unclassified }.map {
                    CollectionsAggregator.Endpoint($0, categoryRaw: $0.categoryRaw,
                        observationEvidence: evidence[$0.persistentModelID])
                }, dismissedCandidates: [], flightTimes: [:], flightStops: [:])
            let candidate = try #require(projection.candidates.first {
                $0.arrivalIdentifier == arrival.persistentModelID
            })
            let target = try #require(FlightLogAuthority.Target(candidate: candidate))
            let canonicalOrigin = [backlog, classified].max {
                $0.persistentModelID < $1.persistentModelID
            }
            #expect(target.witness.nodes.first?.physicalIdentifier == canonicalOrigin?.persistentModelID)
            return target
        }
        let suiteName = "FlightLogAuthorityTwinOrder.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let shown = try target()
        // No source, preference or epoch change occurs between fresh projection
        // and apply; current code nevertheless rejects the changed local election.
        let result = FlightLogAuthority.apply(.confirm(), target: shown, context: readContext, defaults: defaults)
        #expect(result.status == .committed)
        // On the unfixed implementation, recapturing an authoritative projection
        // selects the backlog twin again, so refreshing cannot unblock the user.
        if result.status == .rejected {
            let refreshed = try target()
            #expect(FlightLogAuthority.apply(.confirm(), target: refreshed,
                context: readContext, defaults: defaults).status == .committed)
        }
    }
}
