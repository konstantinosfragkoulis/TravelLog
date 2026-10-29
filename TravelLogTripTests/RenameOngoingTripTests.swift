import Foundation
import SwiftData
import Testing
@testable import TravelLog

/// Renaming a trip marks it userEdited. A stay of that trip left unclassified
/// must still settle, and the rename must reach the tapped physical row.
@MainActor
@Suite("Renaming an ongoing trip", IsolatedTitleDefaults(), .timeLimit(.minutes(1)))
struct RenameOngoingTripTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func stay(day: Double, latitude: Double, locality: String, country: String,
                      code: String, category: StayCategory, in context: ModelContext) -> Stay {
        let begin = start.addingTimeInterval(day * 86_400)
        let stay = Stay(startTime: begin, endTime: begin.addingTimeInterval(6 * 3600),
            centroidLatitude: latitude, centroidLongitude: latitude, h3IndexRes6: "rename-\(locality)",
            pingCount: 2, distanceFromHomeKm: 200, pingIDs: [])
        stay.locality = locality
        stay.country = country
        stay.isoCountryCode = code
        stay.category = category
        context.insert(stay)
        return stay
    }

    private func trip(_ stays: [Stay], complete: Bool, in context: ModelContext) -> Trip {
        let trip = Trip(startDate: stays[0].startTime)
        context.insert(trip)
        trip.stays = stays
        for (index, stay) in stays.enumerated() {
            stay.trip = trip
            stay.orderInTrip = index
        }
        if complete {
            trip.endDate = stays.last?.endTime
            trip.isComplete = true
        }
        trip.recomputeSummary()
        return trip
    }

    @Test("an edited trip's unclassified member settles; its classified and overridden members keep their categories")
    func preparationSettlesEditedTripMember() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let reset = stay(day: 0, latitude: 0, locality: "Athens", country: "Greece", code: "GR",
            category: .unclassified, in: context)
        let settled = stay(day: 1, latitude: 10, locality: "Bari", country: "Italy", code: "IT",
            category: .destination, in: context)
        let overridden = stay(day: 2, latitude: 20, locality: "Split", country: "Croatia", code: "HR",
            category: .transit, in: context)
        overridden.userOverridden = true
        let edited = trip([reset, settled, overridden], complete: false, in: context)
        edited.customName = "Kyklades"
        edited.userEdited = true
        try context.save()
        let ids = (reset: reset.id, settled: settled.id, overridden: overridden.id)
        let tripIdentifier = edited.persistentModelID
        let classifier = TripClassifier(modelContainer: container)
        _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
            reclassifyRecentStays: false, gate: PipelineGate(forTesting: ()))

        let check = ModelContext(container)
        let rows = try check.fetch(FetchDescriptor<Stay>())
        let current = try #require(rows.first { $0.id == ids.reset })
        #expect(current.category == .destination)
        #expect(!current.userOverridden)
        #expect(try #require(rows.first { $0.id == ids.settled }).category == .destination)
        let user = try #require(rows.first { $0.id == ids.overridden })
        #expect(user.category == .transit)
        #expect(user.userOverridden)
        let owner = try #require(current.trip)
        #expect(owner.persistentModelID == tripIdentifier)
        #expect(owner.customName == "Kyklades")
        #expect((owner.stays ?? []).count == 3)
        #expect(owner.countryCodes == "GR,IT")
    }

    @Test("renaming one of two UUID twins names the tapped row only; a vanished row is never replaced by its twin")
    func renameActsOnTappedTwin() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let rowA = Trip(startDate: start)
        let rowB = Trip(startDate: start)
        rowB.id = rowA.id
        context.insert(rowA)
        context.insert(rowB)
        try context.save()
        let identifierA = rowA.persistentModelID
        let identifierB = rowB.persistentModelID

        #expect(TripDetailView.applyRename(tripID: rowA.id, tripIdentifier: identifierB,
            newName: "Kyklades", in: context))
        var rows = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        var a = try #require(rows.first { $0.persistentModelID == identifierA })
        let b = try #require(rows.first { $0.persistentModelID == identifierB })
        #expect(b.customName == "Kyklades")
        #expect(b.userEdited)
        #expect(a.customName == nil)
        #expect(!a.userEdited)

        context.delete(rowB)
        try context.save()
        #expect(TripDetailView.applyRename(tripID: rowA.id, tripIdentifier: identifierB,
            newName: "Samos", in: context))
        rows = try ModelContext(container).fetch(FetchDescriptor<Trip>())
        #expect(rows.count == 1)
        a = try #require(rows.first)
        #expect(a.persistentModelID == identifierA)
        #expect(a.customName == nil)
        #expect(!a.userEdited)
    }
}
