//
//  DemotionTestSupport.swift
//  TravelLogTests
//
//  "This Wasn't a Trip" acts on the tapped physical row. Fixtures seed one
//  row per trip UUID, so this resolves that row the way the list captures it
//  before the gate and hands its identifier to the production demotion.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

extension TripClassifier {
    func demoteSeededTrip(_ tripID: UUID) -> DemotionOutcome {
        let id = tripID
        let rows = (try? ModelContext(modelContainer).fetch(FetchDescriptor<Trip>(
            predicate: #Predicate<Trip> { $0.id == id }))) ?? []
        guard rows.count == 1, let row = rows.first else {
            Issue.record("expected exactly one seeded row for trip \(tripID), found \(rows.count)")
            return .unavailable
        }
        return demoteTripToHomeArea(tripID: tripID, tripIdentifier: row.persistentModelID)
    }
}

extension TripClassifier.DemotionOutcome {
    var isDemoted: Bool {
        if case .demoted = self { return true }
        return false
    }
}
