import BackgroundTasks
import Foundation
import Testing
@testable import TravelLog

@MainActor
@Suite("Background task submission", .serialized, .timeLimit(.minutes(1)))
struct BackgroundTaskSubmitterTests {
    @Test("a main actor caller receives completion within five seconds")
    func mainActorCompletion() async {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await BackgroundTaskSubmitter.submit(
                BGAppRefreshTaskRequest(identifier: "com.travellog.dailyPipeline"))
            Issue.record("Expected the simulator to reject submission")
        } catch {
            #expect((error as? BGTaskScheduler.Error)?.code == .unavailable)
        }
        #expect(start.duration(to: clock.now) < .seconds(5))
    }

    @Test("the renewal wait returns at its bound while the submission is still pending")
    func renewalWaitIsBounded() async {
        let hold = AsyncStream<Void>.makeStream()
        let renewal = Task { for await _ in hold.stream { break } }
        // A wait that ignores its bound never returns, so the suite time limit fails this test.
        await BackgroundTaskSubmitter.awaitRenewal(renewal, seconds: 0.05)
        hold.continuation.yield()
        await renewal.value
    }

    @Test("the renewal wait returns as soon as the submission lands")
    func renewalWaitReturnsWhenRenewalLands() async {
        let renewal = Task {}
        await BackgroundTaskSubmitter.awaitRenewal(renewal, seconds: 3600)
    }
}
