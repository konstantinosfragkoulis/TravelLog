//
//  PipelineGateOrderingTests.swift
//  TravelLogTests
//
//  Asserts the FIFO ordering invariant of `PipelineGate.run(_:)`. The gate is a
//  non-reentrant serial actor that chains each submitted unit after the previous
//  tail (`await previous.value` before running the new `work`). Line coverage is
//  already 100%, but nothing pins the *order* in which units execute — a dropped
//  `await previous.value` would still cover every line yet let units interleave.
//  These tests record the execution order of N submitted closures and require it
//  to equal the submission order.
//
//  Isolation: `PipelineGate.shared` is a process-global singleton whose `tail`
//  carries state across the whole process (and across parallel test suites). We
//  therefore use a FRESH instance per test via the DEBUG-only `init(forTesting:)`
//  so we never observe or mutate the shared chain.
//

import Testing
import Foundation
@testable import TravelLog

/// Serializes order-recording from the gate's `@Sendable` work closures. Because
/// every append happens on this actor, the recorded array is race-free and the
/// test asserts purely on the gate's sequencing, not on a data race.
private actor OrderRecorder {
    private(set) var order: [Int] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0

    func append(_ index: Int) {
        order.append(index)
    }

    /// Overlap oracle: `enter`/`exit` bracket a unit's body so the recorder can
    /// observe two units being inside the gate at once. The actor serializes
    /// the *bookkeeping*, but it cannot serialize the units themselves — if the
    /// gate ever ran two units concurrently, both would `enter` before either
    /// `exit`s and `maxInFlight` would exceed 1.
    func enter(_ index: Int) {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        order.append(index)
    }

    func exit() {
        inFlight -= 1
    }
}

/// Multi-waiter latch for the held-unit oracle.
private actor GateLatch {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        released = true
        for continuation in continuations { continuation.resume() }
        continuations.removeAll()
    }
}

/// A ~10 ms real-time suspension: unlike `Task.yield()`, this genuinely
/// lets other tasks run even when the scheduler would resume us at once.
private func briefSleep() async {
    try? await Task.sleep(for: .milliseconds(10))
}

/// Polled oracle flag. Bounded waits are sleeps on the cooperative pool, never
/// thread-blocking waiters, so parallel suites cannot starve each other.
private actor GateFlag {
    private(set) var isSet = false
    func set() { isSet = true }
    /// True once set; false when the deadline passes first.
    func waitUntilSet(deadline: Duration) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now + deadline
        while !isSet {
            if clock.now >= end { return false }
            await briefSleep()
        }
        return true
    }
}

@Suite("PipelineGate FIFO ordering")
struct PipelineGateOrderingTests {

    /// Under CONCURRENT submission, the order in which tasks win the actor and
    /// enqueue is itself non-deterministic, so the gate's FIFO guarantee is over
    /// ENQUEUE order — NOT the index `i`. What the gate must guarantee even under
    /// concurrent load is MUTUAL EXCLUSION with no lost or duplicated units:
    /// every index runs exactly once, and no two units are ever inside the gate
    /// at the same time (`maxInFlight == 1` — the pre-2026-08-08 assertions
    /// checked only exactly-once, which a gate that ran units concurrently
    /// would still satisfy). (Strict index-order FIFO is pinned separately by
    /// `sequentialSubmissionsRunInOrder`, where submission order is deterministic.)
    @Test("concurrently-submitted units run exactly once and never overlap")
    func runSerializesConcurrentSubmissionsWithoutLoss() async {
        let gate = PipelineGate(forTesting: ())
        let recorder = OrderRecorder()
        let n = 10

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<n {
                group.addTask {
                    await gate.run {
                        await recorder.enter(i)
                        // Suspend mid-unit (twice) so an overlapping unit gets
                        // every scheduling opportunity to interleave before we
                        // leave — the yield is what makes the oracle sensitive.
                        await Task.yield()
                        await Task.yield()
                        await recorder.exit()
                    }
                }
            }
            await group.waitForAll()
        }

        let recorded = await recorder.order
        #expect(recorded.count == n)
        #expect(Set(recorded) == Set(0..<n))
        #expect(await recorder.maxInFlight == 1, "two gate units overlapped")
    }

    @Test("a queued submission starts only after its held predecessor finishes")
    func sequentialSubmissionsRunInOrder() async {
        let gate = PipelineGate(forTesting: ())
        let recorder = OrderRecorder()
        let started = GateLatch()
        let release = GateLatch()
        let submitted = GateLatch()
        let successorStarted = GateFlag()
        let first = Task.detached {
            await gate.run {
                await recorder.append(0)
                await started.release()
                await release.wait()
                await recorder.append(1)
            }
        }
        await started.wait()
        let second = Task.detached {
            await submitted.release()
            await gate.run {
                await successorStarted.set()
                await recorder.append(2)
            }
        }
        await submitted.wait()
        let earlyStart = await successorStarted.waitUntilSet(deadline: .milliseconds(200))
        #expect(!earlyStart, "successor started before the held predecessor released")
        #expect(await recorder.order == [0])
        await release.release()
        await first.value
        await second.value
        #expect(await recorder.order == [0, 1, 2])
    }

    /// Helper tasks are detached: a MainActor-inherited task would compete
    /// with every other parallel suite for the main actor, and the positive
    /// oracle (gate B completes while gate A is held) must not race a timer.
    /// A shared chain deadlocks here and trips the time limit instead.
    @Test("fresh instances have independent serial chains", .timeLimit(.minutes(1)))
    func freshInstancesAreIndependent() async {
        let gateA = PipelineGate(forTesting: ())
        let gateB = PipelineGate(forTesting: ())
        let recA = OrderRecorder()
        let recB = OrderRecorder()
        let started = GateLatch()
        let release = GateLatch()
        let submitted = GateLatch()
        let successorStarted = GateFlag()
        let first = Task.detached {
            await gateA.run {
                await recA.append(0)
                await started.release()
                await release.wait()
                await recA.append(1)
            }
        }
        await started.wait()
        let successor = Task.detached {
            await submitted.release()
            await gateA.run {
                await successorStarted.set()
                await recA.append(2)
            }
        }
        await submitted.wait()
        let independent = Task.detached {
            await gateB.run { await recB.append(0) }
        }
        await independent.value
        let earlyStart = await successorStarted.waitUntilSet(deadline: .milliseconds(200))
        #expect(!earlyStart, "gate A successor must remain blocked on its own chain")
        #expect(await recA.order == [0])
        #expect(await recB.order == [0])
        await release.release()
        await first.value
        await successor.value
        #expect(await recA.order == [0, 1, 2])
    }

    /// `run` returns only AFTER its own `work` has finished (it awaits
    /// `unit.value`). Submitting sequentially, the recorder must already hold the
    /// just-submitted index the instant each `run` returns.
    @Test("run returns only after its own work completes")
    func runReturnsAfterWorkCompletes() async {
        let gate = PipelineGate(forTesting: ())
        let recorder = OrderRecorder()

        for i in 0..<5 {
            await gate.run {
                await Task.yield()
                await recorder.append(i)
            }
            // By the time run() returns, this unit must have recorded — so the
            // last element is exactly i and the count is i+1.
            let snapshot = await recorder.order
            #expect(snapshot.count == i + 1)
            #expect(snapshot.last == i)
        }
    }

    /// `runReturning` shares `run`'s chain: units of both flavors interleave
    /// in exact submission order, and each `runReturning` hands back its own
    /// closure's value (the property the chunked drain/weather drivers rely
    /// on to decide whether to continue).
    @Test("runReturning serializes on the same chain and returns its unit's value")
    func runReturningSharesChainAndReturnsValue() async {
        let gate = PipelineGate(forTesting: ())
        let recorder = OrderRecorder()
        let started = GateLatch()
        let release = GateLatch()
        let submitted = GateLatch()
        let valueProduced = GateFlag()
        let first = Task.detached {
            await gate.run {
                await recorder.append(0)
                await started.release()
                await release.wait()
                await recorder.append(1)
            }
        }
        await started.wait()
        let second = Task.detached {
            await submitted.release()
            let value = await gate.runReturning {
                await recorder.append(2)
                return 70
            }
            await valueProduced.set()
            return value
        }
        await submitted.wait()
        let earlyValue = await valueProduced.waitUntilSet(deadline: .milliseconds(200))
        #expect(!earlyValue, "runReturning produced a value while run was held")
        #expect(await recorder.order == [0])
        await release.release()
        await first.value
        #expect(await second.value == 70)
        #expect(await recorder.order == [0, 1, 2])
    }

    // MARK: - Cancellation forwarding (lets the BG-refresh handler gate its
    // steps without losing graceful expiration).

    /// Cancelling the task that awaits `run` must propagate into the gate unit
    /// so `Task.isCancelled` becomes true inside `work`. The closure returns
    /// ONLY when cancelled, so a non-forwarding gate would spin forever and the
    /// `.timeLimit` would fire.
    @Test("run forwards the awaiting caller's cancellation into the unit", .timeLimit(.minutes(1)))
    func runForwardsCallerCancellation() async {
        let gate = PipelineGate(forTesting: ())
        let outer = Task {
            await gate.run(touching: []) {
                while !Task.isCancelled { await Task.yield() }
            }
        }
        // Let the unit enter the closure, then cancel the awaiting caller.
        for _ in 0..<100 { await Task.yield() }
        outer.cancel()
        await outer.value   // must return; a non-forwarding gate hangs here
    }

    @Test("runReturning forwards the awaiting caller's cancellation into the unit", .timeLimit(.minutes(1)))
    func runReturningForwardsCallerCancellation() async {
        let gate = PipelineGate(forTesting: ())
        let outer = Task { () -> Int in
            await gate.runReturning(touching: []) { () -> Int in
                while !Task.isCancelled { await Task.yield() }
                return 7
            }
        }
        for _ in 0..<100 { await Task.yield() }
        outer.cancel()
        let value = await outer.value
        #expect(value == 7)
    }
}
