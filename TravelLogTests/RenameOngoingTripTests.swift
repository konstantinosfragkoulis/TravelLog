import Foundation
import os
import SwiftData
import Testing
@testable import TravelLog

/// Renaming a trip marks it userEdited, which keeps the model lane away from
/// its stays. A stay already reset for reclassification when the rename lands
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

    /// The model call renames the trip once, through the production worker in
    /// its own gate unit, as the trip detail's Done does while inference waits.
    private func renamingResponse(container: ModelContainer, gate: PipelineGate, tripID: UUID,
                                  tripIdentifier: PersistentIdentifier, renamed: OSAllocatedUnfairLock<Bool>)
        -> @Sendable (String) async throws -> [StayClassificationInference.Classification] {
        { prompt in
            if !renamed.withLock({ $0 }) {
                let saved = await gate.runReturning(touching: [.trip]) {
                    await MainActor.run {
                        TripDetailView.applyRename(tripID: tripID, tripIdentifier: tripIdentifier,
                            newName: "Kyklades", in: ModelContext(container))
                    }
                }
                #expect(saved)
                renamed.withLock { $0 = true }
            }
            let count = prompt.components(separatedBy: "\n").filter { $0.hasPrefix("[") }.count
            return (0..<count).map { .init(stayIndex: $0, category: "transit") }
        }
    }

    @Test("a member reset for reclassification settles when the ongoing trip is renamed during inference")
    func renameDuringInferenceSettlesResetMember() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let member = stay(day: 0, latitude: 0, locality: "Athens", country: "Greece", code: "GR",
            category: .destination, in: context)
        let ongoing = trip([member], complete: false, in: context)
        // New journey data, so recent reconsideration resets the member.
        _ = stay(day: 1, latitude: 10, locality: "Twinville", country: "Greece", code: "GR",
            category: .unclassified, in: context)
        try context.save()
        let memberID = member.id
        let tripID = ongoing.id
        let tripIdentifier = ongoing.persistentModelID
        let renamed = OSAllocatedUnfairLock(initialState: false)
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
            reclassifyRecentStays: true, gate: gate, fmAvailable: true,
            response: renamingResponse(container: container, gate: gate, tripID: tripID,
                tripIdentifier: tripIdentifier, renamed: renamed))
        #expect(renamed.withLock { $0 })

        let check = ModelContext(container)
        let current = try #require(check.fetch(FetchDescriptor<Stay>()).first { $0.id == memberID })
        // The rejected model answer (transit) does not apply; the heuristics settle it.
        #expect(current.category == .destination)
        let owner = try #require(current.trip)
        #expect(owner.persistentModelID == tripIdentifier)
        #expect(owner.customName == "Kyklades")
        #expect(owner.userEdited)
        #expect(owner.countryCodes == "GR")
    }

    @Test("an edited trip's unclassified member settles without the model; its classified and overridden members keep their categories")
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
        let prompts = OSAllocatedUnfairLock(initialState: 0)
        let classifier = TripClassifier(modelContainer: container)
        _ = await classifier.classifyAndAssembleTripsReportingChangesWithGates(
            reclassifyRecentStays: false, gate: PipelineGate(forTesting: ()), fmAvailable: true,
            response: { _ in
                prompts.withLock { $0 += 1 }
                return [.init(stayIndex: 0, category: "transit")]
            })
        #expect(prompts.withLock { $0 } == 0)

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

    @Test("a completed rebuild target renamed during inference keeps its members, settled, and a fresh summary")
    func renamedRebuildTargetSettlesAndRefreshesSummary() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let first = stay(day: 0, latitude: 0, locality: "Athens", country: "Greece", code: "GR",
            category: .destination, in: context)
        let second = stay(day: 1, latitude: 10, locality: "Bari", country: "Italy", code: "IT",
            category: .destination, in: context)
        let completed = trip([first, second], complete: true, in: context)
        try context.save()
        let memberIDs = Set([first.id, second.id])
        let tripID = completed.id
        let tripIdentifier = completed.persistentModelID
        let renamed = OSAllocatedUnfairLock(initialState: false)
        let classifier = TripClassifier(modelContainer: container)
        let gate = PipelineGate(forTesting: ())
        await StayClassificationInference.TestHook.$availability.withValue(true) {
            await StayClassificationInference.TestHook.$response.withValue(
                renamingResponse(container: container, gate: gate, tripID: tripID,
                    tripIdentifier: tripIdentifier, renamed: renamed)) {
                _ = await classifier.reclassifyAll(gate: gate)
            }
        }
        #expect(renamed.withLock { $0 })

        let check = ModelContext(container)
        let owner = try #require(check.fetch(FetchDescriptor<Trip>()).first { $0.id == tripID })
        #expect(owner.persistentModelID == tripIdentifier)
        #expect(owner.customName == "Kyklades")
        #expect(owner.isComplete)
        let members = owner.stays ?? []
        #expect(Set(members.map(\.id)) == memberIDs)
        #expect(members.allSatisfy { $0.category == .destination })
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
