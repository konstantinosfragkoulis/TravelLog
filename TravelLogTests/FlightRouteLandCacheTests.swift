import Foundation
import Testing
@testable import TravelLog

@MainActor
@Suite("Flight route outline lifecycle")
struct FlightRouteLandCacheTests {
    private let oldRings = [[FlightRouteGeometry.Point(latitude: 10, longitude: 20)]]
    private let freshRings = [[FlightRouteGeometry.Point(latitude: 40, longitude: 50)]]

    @Test("A backgrounded cache cannot start provider work; completed rings remain reusable")
    func suspensionAdmissionAndCompletedReuse() async {
        let loader = ControlledLoader()
        let cache = FlightRouteLandCache { await loader.load() }
        cache.suspend()
        #expect(await cache.value().isEmpty)
        #expect(loader.calls == 0)

        cache.resume()
        let request = Task { await cache.value() }
        await loader.waitForCall(1)
        loader.finish(1, with: freshRings)
        #expect(await request.value == freshRings)
        #expect(await cache.value() == freshRings)
        #expect(loader.calls == 1)

        cache.suspend()
        #expect(await cache.value() == freshRings)
        cache.resume()
        #expect(await cache.value() == freshRings)
        #expect(loader.calls == 1)
    }

    @Test("A released pending fill cannot retry, publish, or erase its foreground replacement")
    func cancellationRejectsLateGeneration() async {
        let loader = ControlledLoader()
        let cache = FlightRouteLandCache { await loader.load() }
        let oldRequest = Task { await cache.value() }
        await loader.waitForCall(1)
        cache.suspend()
        #expect(await cache.value().isEmpty)
        #expect(loader.calls == 1)

        cache.resume()
        let replacement = Task { await cache.value() }
        await loader.waitForCall(2)
        loader.finish(1, with: oldRings)
        #expect(await oldRequest.value.isEmpty)
        #expect(loader.cancelledCalls.contains(1))
        // If the old completion cleared the replacement's handle, this
        // concurrent waiter would start a third load rather than share it.
        let concurrent = Task { await cache.value() }
        await Task.yield()
        loader.finish(2, with: freshRings)
        #expect(await replacement.value == freshRings)
        #expect(await concurrent.value == freshRings)
        #expect(await cache.value() == freshRings)
        #expect(loader.calls == 2)
    }

    /// Continuations make cancellation and foreground re-entry exact rather
    /// than relying on a decoder's speed or on wall-clock sleeps.
    @MainActor
    private final class ControlledLoader {
        private(set) var calls = 0
        private(set) var cancelledCalls = Set<Int>()
        private var pending: [Int: CheckedContinuation<FlightRouteLandCache.Rings, Never>] = [:]
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func load() async -> FlightRouteLandCache.Rings {
            calls += 1
            let call = calls
            let value = await withCheckedContinuation { continuation in
                pending[call] = continuation
                let ready = waiters.filter { $0.0 <= calls }
                waiters.removeAll { $0.0 <= calls }
                ready.forEach { $0.1.resume() }
            }
            if Task.isCancelled { cancelledCalls.insert(call) }
            return value
        }

        func waitForCall(_ count: Int) async {
            if calls >= count { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }

        func finish(_ call: Int, with rings: FlightRouteLandCache.Rings) {
            guard let continuation = pending.removeValue(forKey: call) else {
                Issue.record("No pending outline load \(call)")
                return
            }
            continuation.resume(returning: rings)
        }
    }
}
