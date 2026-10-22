import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct WrappedViewedStampTests {
    @Test("Revealed Wrapped stamps after a busy gate despite dismissal and preserves first views")
    func dismissalWhileGateBusyStillStamps() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let unseen = YearWrapped(year: 2025)
        let twin = YearWrapped(year: 2025)
        twin.id = unseen.id
        let viewed = YearWrapped(year: 2025)
        let firstView = Date(timeIntervalSince1970: 1_700_000_000)
        viewed.viewedAt = firstView
        let otherYear = YearWrapped(year: 2024)
        for row in [unseen, twin, viewed, otherYear] { context.insert(row) }
        try context.save()
        let gate = PipelineGate(forTesting: ())
        let entered = AuditAsyncBarrier()
        let release = AuditAsyncBarrier()
        let stampStarted = AuditAsyncBarrier()
        let blocker = Task {
            await gate.run(touching: []) {
                await entered.arrive()
                await release.wait(until: 1)
            }
        }
        await entered.wait(until: 1)
        let operation = Task {
            await WrappedView.$beforeViewedStampGateForTesting.withValue({
                await stampStarted.arrive()
            }) {
                await WrappedView.stampViewed(year: 2025, in: container, gate: gate)
            }
        }
        await stampStarted.wait(until: 1)
        let before = try ModelContext(container).fetch(FetchDescriptor<YearWrapped>())
        #expect(before.filter { $0.year == 2025 && $0.viewedAt == nil }.count == 2)
        operation.cancel()
        await release.arrive()
        await blocker.value
        await operation.value
        let after = try ModelContext(container).fetch(FetchDescriptor<YearWrapped>())
        #expect(after.filter { $0.year == 2025 }.allSatisfy { $0.viewedAt != nil })
        #expect(after.first { $0.id == viewed.id }?.viewedAt == firstView)
        #expect(after.first { $0.year == 2024 }?.viewedAt == nil)
    }
}
