//
//  TransitDrainOutcomeTests.swift
//  TravelLogTests
//
//  The foreground drain's inbound-leg pass reports how it ended. A failed
//  batch or a round cap reached with legs left is never taken for an
//  exhausted pass: the drain does not report `.drained` while legs wait
//  (Stats counts flights from them), and capped progress continues in a
//  trailing run.
//

import Foundation
import Testing
@testable import TravelLog

@MainActor
private final class TransitScript {
    var outcomes: [ForegroundClassificationDrain.TransitOutcome]
    var calls = 0
    var titleRefills = 0
    init(_ outcomes: [ForegroundClassificationDrain.TransitOutcome]) { self.outcomes = outcomes }

    func next() -> ForegroundClassificationDrain.TransitOutcome {
        calls += 1
        return outcomes.isEmpty ? .exhausted : outcomes.removeFirst()
    }

    func drain() -> ForegroundClassificationDrain {
        ForegroundClassificationDrain(environment: .init(
            bite: { _, _ in .init(completed: true, classified: 0) },
            backlog: { 0 },
            titles: { await MainActor.run { self.titleRefills += 1 } },
            transit: { _ in await self.next() },
            mayRun: { true },
            systemAllowsWork: { true }))
    }
}

@MainActor
@Suite("Transit drain outcome", .serialized)
struct TransitDrainOutcomeTests {

    private nonisolated static func batch(fetched: Int, classified: Int, failed: Bool = false) -> TransitInferer.DrainOutcome {
        .init(fetched: fetched, classified: classified, flights: 0,
              needsPublication: classified > 0, failed: failed)
    }

    @Test("a failed batch ends the pass failed, not exhausted")
    func failedBatchIsFailed() async {
        let full = TransitInferer.inferenceBatchSize
        var answers = [Self.batch(fetched: full, classified: full), Self.batch(fetched: 0, classified: 0, failed: true)]
        let outcome = await ForegroundClassificationDrain.drainTransit(unitPolicy: { true }) {
            answers.removeFirst()
        }
        #expect(outcome == .failed)
    }

    @Test("the round cap after progress leaves the pass incomplete; without progress it failed")
    func roundCapIsNotExhaustion() async {
        let full = TransitInferer.inferenceBatchSize
        let progressing = await ForegroundClassificationDrain.drainTransit(maxRounds: 3, unitPolicy: { true }) {
            Self.batch(fetched: full, classified: full)
        }
        #expect(progressing == .incomplete)
        let stuck = await ForegroundClassificationDrain.drainTransit(maxRounds: 3, unitPolicy: { true }) {
            Self.batch(fetched: full, classified: 0)
        }
        #expect(stuck == .failed)
    }

    @Test("a short batch is exhausted only when it classified every leg it read")
    func shortBatchExhaustion() async {
        var answers = [Self.batch(fetched: 3, classified: 2), Self.batch(fetched: 1, classified: 1)]
        var rounds = 0
        let outcome = await ForegroundClassificationDrain.drainTransit(unitPolicy: { true }) {
            rounds += 1
            return answers.removeFirst()
        }
        #expect(outcome == .exhausted)
        #expect(rounds == 2, "a leg another writer moved is read again")
        let refused = await ForegroundClassificationDrain.drainTransit(unitPolicy: { false }) {
            Self.batch(fetched: 0, classified: 0)
        }
        #expect(refused == .incomplete)
    }

    @Test("legs a failed pass left pending keep the drain from reporting drained")
    func failedTransitIsNotDrained() async {
        let script = TransitScript([.failed])
        let drain = script.drain()
        drain.request()
        #expect(await drain.waitUntilIdle() == .failed)
        #expect(script.calls == 1, "a failed pass does not retry itself")
    }

    @Test("a capped pass continues in a trailing run, which then drains", .timeLimit(.minutes(1)))
    func cappedTransitContinues() async {
        let script = TransitScript([.incomplete, .exhausted])
        let drain = script.drain()
        drain.request()
        #expect(await drain.waitUntilIdle() == .drained)
        #expect(script.calls == 2)
    }
}
