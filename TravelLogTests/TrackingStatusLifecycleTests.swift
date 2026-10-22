//
//  TrackingStatusLifecycleTests.swift
//  TravelLogTests
//
//  Pins the observer-task ownership fix: TrackingStatus
//  starts one finite check plus two indefinite NotificationCenter async-sequence
//  loops. Pre-fix the handles were unowned, so a released dashboard left both
//  loops suspended (subscription alive) until the NEXT matching notification
//  happened to fire. The class now owns the handles and cancels them in
//  `deinit` — release must cancel all three deterministically, with no
//  notification required.
//
//  @MainActor because TrackingStatus is a MainActor @Observable and the test
//  relies on the last reference dropping synchronously on the main actor.
//

import Testing
import Foundation
@testable import TravelLog

@MainActor
struct TrackingStatusLifecycleTests {

    @Test("releasing the instance cancels all three observer tasks without waiting for a notification")
    func deinitCancelsObserverTasks() {
        var status: TrackingStatus? = TrackingStatus()
        let tasks = status?.observerTasksForTesting ?? []
        #expect(tasks.count == 3, "expected the initial check + two observer loops")
        #expect(tasks.contains { !$0.isCancelled }, "tasks should be live while the instance is")

        status = nil   // last reference drops synchronously on the main actor

        #expect(tasks.allSatisfy { $0.isCancelled },
                "deinit must cancel every owned observer task")
    }
}
