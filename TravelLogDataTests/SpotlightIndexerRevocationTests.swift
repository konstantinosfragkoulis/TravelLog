//
//  SpotlightIndexerRevocationTests.swift
//  TravelLogTests
//
//  Delete All Data revokes Spotlight donations through the indexer's own
//  serialized passes: the revocation deletes before it reads, a pass that
//  captured a pre-wipe snapshot never indexes it or publishes its token
//  once the donation epoch moved, and the caller learns whether a deletion
//  that started after its request succeeded. A fake index records every
//  operation and can hold one on an "entered" handshake, so every ordering
//  below is forced rather than timed.
//

import Foundation
import Testing
@testable import TravelLog

/// A one-shot gate: `wait()` suspends until `open()`.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

private final class Hold: @unchecked Sendable {
    let entered = Latch()
    let release = Latch()
}

private final class FakeSpotlightIndex: @unchecked Sendable {
    enum Operation: Equatable {
        case delete
        case index([UUID])
    }

    private let lock = NSLock()
    private var entities: [TripEntity] = []
    private var fetchFails = false
    private var deleteFailures = 0
    private var log: [Operation] = []
    private var deleteHold: Hold?
    private var indexHold: Hold?

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func setEntities(_ value: [TripEntity]) { locked { entities = value } }
    func setFetchFails(_ value: Bool) { locked { fetchFails = value } }
    func failNextDeletes(_ count: Int) { locked { deleteFailures = count } }
    func holdNextDelete() -> Hold { locked { let hold = Hold(); deleteHold = hold; return hold } }
    func holdNextIndex() -> Hold { locked { let hold = Hold(); indexHold = hold; return hold } }
    var operations: [Operation] { locked { log } }

    private func fetch() throws -> [TripEntity] {
        let (fails, value) = locked { (fetchFails, entities) }
        if fails { throw CocoaError(.fileReadUnknown) }
        return value
    }

    private func delete() async throws {
        let hold = locked { () -> Hold? in
            log.append(.delete)
            defer { deleteHold = nil }
            return deleteHold
        }
        if let hold {
            hold.entered.open()
            await hold.release.wait()
        }
        let fail = locked { () -> Bool in
            guard deleteFailures > 0 else { return false }
            deleteFailures -= 1
            return true
        }
        if fail { throw CocoaError(.fileWriteUnknown) }
    }

    private func index(_ value: [TripEntity]) async throws {
        let hold = locked { () -> Hold? in
            log.append(.index(value.map(\.tripID)))
            defer { indexHold = nil }
            return indexHold
        }
        if let hold {
            hold.entered.open()
            await hold.release.wait()
        }
    }

    var seam: SpotlightIndexer.Operations {
        SpotlightIndexer.Operations(
            fetchEntities: { try self.fetch() },
            deleteAllEntities: { try await self.delete() },
            indexEntities: { try await self.index($0) })
    }
}

@Suite("Spotlight wipe revocation", .timeLimit(.minutes(1)))
struct SpotlightIndexerRevocationTests {

    private let tokenKey = "spotlightDonatedToken_v1"

    /// The indexer actor gets its own handle on the suite
    /// (`UserDefaults(suiteName: suite)!`), never the test's instance.
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "spotlight-revocation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func trip(_ title: String) -> TripEntity {
        TripEntity(
            id: TripEntityID(tripID: UUID()), title: title, titleAliases: [], destinationSummary: title,
            startDate: Date(timeIntervalSinceReferenceDate: 800_000_000), endDate: nil,
            isOngoing: false, countryCodes: ["PT"], countryNames: ["Portugal"],
            localities: [title])
    }

    private func digest(_ entities: [TripEntity]) -> String {
        let tag = AppLanguagePreference.currentTag()
        return SpotlightIndexer.contentDigest(
            for: entities, languageTag: tag, locale: AppLanguagePreference.locale(for: tag))
    }

    /// Waits until the revocation has registered on the indexer actor.
    private func awaitRevocationRegistered(_ indexer: SpotlightIndexer) async {
        while await !indexer.hasPendingRevocation() { await Task.yield() }
    }

    @Test("revocation during indexing is followed by a corrective deletion before it returns")
    func revocationDuringIndexing() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = FakeSpotlightIndex()
        let lisbon = trip("Lisbon")
        fake.setEntities([lisbon])
        let hold = fake.holdNextIndex()
        let indexer = SpotlightIndexer(operations: fake.seam, defaults: UserDefaults(suiteName: suite)!)

        let pass = Task { await indexer.refresh() }
        await hold.entered.wait()
        fake.setEntities([])
        let revocation = Task { await indexer.revokeAllDonations() }
        await awaitRevocationRegistered(indexer)
        hold.release.open()

        #expect(await revocation.value)
        #expect(fake.operations.last == .delete,
                "revocation returned only after the corrective deletion")
        await pass.value
        #expect(fake.operations == [.delete, .index([lisbon.tripID]), .delete])
        #expect(defaults.string(forKey: tokenKey) != digest([lisbon]),
                "the stale pass must not publish its pre-wipe token")
        #expect(defaults.string(forKey: tokenKey) == digest([]))
    }

    @Test("revocation during a pass's deletion prevents the stale index call")
    func revocationDuringDeletion() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = FakeSpotlightIndex()
        fake.setEntities([trip("Porto")])
        let hold = fake.holdNextDelete()
        let indexer = SpotlightIndexer(operations: fake.seam, defaults: UserDefaults(suiteName: suite)!)

        let pass = Task { await indexer.refresh() }
        await hold.entered.wait()
        fake.setEntities([])
        let revocation = Task { await indexer.revokeAllDonations() }
        await awaitRevocationRegistered(indexer)
        hold.release.open()

        #expect(await revocation.value)
        await pass.value
        #expect(fake.operations == [.delete, .delete],
                "a snapshot captured before the wipe must never be indexed")
    }

    @Test("an idle revocation deletes immediately and records the empty set")
    func idleRevocation() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("pre-wipe", forKey: tokenKey)
        let fake = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(operations: fake.seam, defaults: UserDefaults(suiteName: suite)!)

        #expect(await indexer.revokeAllDonations())
        // An actor hop runs after the pass's remaining synchronous work.
        #expect(await !indexer.hasPendingRevocation())
        #expect(fake.operations == [.delete])
        #expect(defaults.string(forKey: tokenKey) == digest([]))
    }

    @Test("a failed read after revocation still deletes and leaves no token")
    func revocationWithFailedRead() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("pre-wipe", forKey: tokenKey)
        let fake = FakeSpotlightIndex()
        fake.setFetchFails(true)
        let indexer = SpotlightIndexer(operations: fake.seam, defaults: UserDefaults(suiteName: suite)!)

        #expect(await indexer.revokeAllDonations(),
                "the revocation succeeded even though rebuilding donations failed")
        #expect(await !indexer.hasPendingRevocation())
        #expect(fake.operations == [.delete])
        #expect(defaults.string(forKey: tokenKey) == nil)
    }

    @Test("a failed revocation reports false and stays pending")
    func failedRevocation() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("pre-wipe", forKey: tokenKey)
        let fake = FakeSpotlightIndex()
        fake.failNextDeletes(1)
        let indexer = SpotlightIndexer(operations: fake.seam, defaults: UserDefaults(suiteName: suite)!)

        #expect(await !indexer.revokeAllDonations())
        #expect(await indexer.hasPendingRevocation())
        #expect(defaults.string(forKey: tokenKey) == nil)

        #expect(await indexer.revokeAllDonations())
        #expect(await !indexer.hasPendingRevocation())
        #expect(fake.operations == [.delete, .delete])
    }

    @Test("concurrent revocations each complete exactly once")
    func concurrentRevocations() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = FakeSpotlightIndex()
        fake.setEntities([trip("Faro")])
        let hold = fake.holdNextDelete()
        let indexer = SpotlightIndexer(operations: fake.seam, defaults: UserDefaults(suiteName: suite)!)

        let pass = Task { await indexer.refresh() }
        await hold.entered.wait()
        fake.setEntities([])
        let first = Task { await indexer.revokeAllDonations() }
        let second = Task { await indexer.revokeAllDonations() }
        await awaitRevocationRegistered(indexer)
        hold.release.open()

        let results = [await first.value, await second.value]
        #expect(results == [true, true])
        await pass.value
        #expect(fake.operations.allSatisfy { $0 == .delete },
                "no pre-wipe snapshot may be indexed")
    }

    @Test("a token drop during an in-flight donation reruns instead of publishing")
    func tokenDropDuringDonation() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = FakeSpotlightIndex()
        let braga = trip("Braga")
        fake.setEntities([braga])
        let hold = fake.holdNextIndex()
        let indexer = SpotlightIndexer(operations: fake.seam, defaults: UserDefaults(suiteName: suite)!)

        let pass = Task { await indexer.refresh() }
        await hold.entered.wait()
        await indexer.invalidateDonationToken()
        hold.release.open()
        await pass.value

        #expect(fake.operations == [
            .delete, .index([braga.tripID]), .delete, .index([braga.tripID]),
        ])
        #expect(defaults.string(forKey: tokenKey) == digest([braga]))
    }

    @Test func queuedRerunNeedsAnInFlightPass() {
        var state = SpotlightIndexer.RefreshPassState()
        state.queueRerun()
        #expect(!state.hasPendingRerun, "an idle owner has nothing to rerun")
        let claimed = state.claim()
        #expect(claimed)
        state.queueRerun()
        #expect(state.hasPendingRerun)
        let rerun = state.finishPass()
        #expect(rerun)
        let again = state.finishPass()
        #expect(!again)
    }
}
