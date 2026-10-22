import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct PhotoAnnotationGateTests {
    @Test("Failed annotation saves report failure and roll back; deleted parents cannot gain annotations")
    func failedMutation() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: .now)
        context.insert(trip)
        try context.save()
        let tripID = trip.id
        let service = PhotoService(forTesting: ())
        service.mutationContainerForTesting = container
        service.mutationGateForTesting = PipelineGate(forTesting: ())
        service.failAnnotationSaveForTesting = true
        #expect(!(await service.hidePhoto(localIdentifier: "fixture", tripID: tripID).value))
        #expect(!(await service.pinPhoto(localIdentifier: "fixture", tripID: tripID).value))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<HiddenPhoto>()) == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PinnedPhoto>()) == 0)
        service.failAnnotationSaveForTesting = false
        #expect(await service.pinPhoto(localIdentifier: "fixture", tripID: tripID).value)
        service.failAnnotationSaveForTesting = true
        #expect(!(await service.unpinPhoto(localIdentifier: "fixture", tripID: tripID).value))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PinnedPhoto>()) == 1)
        context.delete(trip)
        try context.save()
        service.failAnnotationSaveForTesting = false
        #expect(!(await service.hidePhoto(localIdentifier: "another", tripID: tripID).value))
    }

    @Test("Queued photo edits persist in submission order and remain idempotent")
    func queuedEdits() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let service = PhotoService(forTesting: ())
        service.mutationContainerForTesting = container
        service.mutationGateForTesting = PipelineGate(forTesting: ())
        let trip = Trip(startDate: .now)
        let context = ModelContext(container)
        context.insert(trip)
        try context.save()
        let tripID = trip.id
        let hide = service.hidePhoto(localIdentifier: "fixture", tripID: tripID)
        let restore = service.unhidePhoto(localIdentifier: "fixture", tripID: tripID)
        let pin = service.pinPhoto(localIdentifier: "fixture", tripID: tripID)
        let unpin = service.unpinPhoto(localIdentifier: "fixture", tripID: tripID)
        #expect(await hide.value)
        #expect(await restore.value)
        #expect(await pin.value)
        #expect(await unpin.value)
        #expect(try context.fetchCount(FetchDescriptor<HiddenPhoto>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PinnedPhoto>()) == 0)
        #expect(await service.pinPhoto(localIdentifier: "fixture", tripID: tripID).value)
        #expect(await service.pinPhoto(localIdentifier: "fixture", tripID: tripID).value)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PinnedPhoto>()) == 1)
    }

    @Test("Opening Wrapped saves viewedAt for physical twins and preserves first view")
    func viewedStampIsDurable() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let first = YearWrapped(year: 2025)
        let twin = YearWrapped(year: 2025)
        twin.id = first.id
        context.insert(first)
        context.insert(twin)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let viewed = YearWrapped(year: 2025)
        viewed.viewedAt = old
        context.insert(viewed)
        try context.save()
        await WrappedView.stampViewed(year: 2025, in: container, gate: PipelineGate(forTesting: ()))
        let rows = try ModelContext(container).fetch(FetchDescriptor<YearWrapped>())
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.viewedAt != nil })
        #expect(rows.first { $0.id == viewed.id }?.viewedAt == old)
    }
}
