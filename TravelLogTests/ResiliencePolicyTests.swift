//
//  ResiliencePolicyTests.swift
//  TravelLogTests
//
//  Pure coverage of the resilience policies. No SwiftData store,
//  Core Location service, background task, or UI is exercised here.
//

import CoreLocation
import Foundation
import Testing
@testable import TravelLog

@MainActor
@Suite("Resilience policies")
struct ResiliencePolicyTests {

    private func liveCandidate(
        _ ordinal: Int, source: DataSource
    ) -> LiveLocationCandidate {
        LiveLocationCandidate(
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                altitude: 0,
                horizontalAccuracy: 10,
                verticalAccuracy: 10,
                course: -1,
                speed: -1,
                timestamp: Date(timeIntervalSince1970: TimeInterval(ordinal))
            ),
            source: source
        )
    }

    @Test("container modes expose persistence and retain their underlying errors")
    func containerModeMetadata() {
        let cloudError = "CloudKit unavailable"
        let diskError = "Disk full"

        #expect(AppDelegate.ContainerMode.persisted.isPersistent)
        #expect(AppDelegate.ContainerMode.persisted.errorDescription == nil)
        #expect(AppDelegate.ContainerMode.localFallback(
            errorDescription: cloudError).isPersistent)
        #expect(AppDelegate.ContainerMode.localFallback(
            errorDescription: cloudError).errorDescription == cloudError)
        #expect(!AppDelegate.ContainerMode.inMemory(
            errorDescription: diskError).isPersistent)
        #expect(AppDelegate.ContainerMode.inMemory(
            errorDescription: diskError).errorDescription == diskError)
    }

    @Test("failed live-location batches retry first and retain only the newest 200 values")
    func pingRetryBufferOrderingAndCap() {
        let buffered = [
            liveCandidate(1, source: .foregroundStream),
            liveCandidate(2, source: .liveSLC),
        ]
        let incoming = [
            liveCandidate(3, source: .liveSLC),
            liveCandidate(4, source: .foregroundStream),
        ]
        let next = PingRetryBufferPolicy.nextInput(
            buffered: buffered, incoming: incoming)
        #expect(next.map(\.timestamp) == (1...4).map {
            Date(timeIntervalSince1970: TimeInterval($0))
        })
        #expect(next.map(\.source) == [
            .foregroundStream, .liveSLC, .liveSLC, .foregroundStream,
        ])

        let attempted = (1...250).map {
            liveCandidate(
                $0,
                source: $0.isMultiple(of: 2) ? .foregroundStream : .liveSLC)
        }
        let retained = PingRetryBufferPolicy.retainedAfterFailure(attempted)
        #expect(retained.count == PingRetryBufferPolicy.capacity)
        #expect(retained.first?.timestamp
                == Date(timeIntervalSince1970: 51))
        #expect(retained.last?.timestamp
                == Date(timeIntervalSince1970: 250))
        #expect(retained.map(\.source)
                == attempted.suffix(PingRetryBufferPolicy.capacity).map(\.source))
        #expect(PingRetryBufferPolicy.retainedAfterFailure(
            incoming, capacity: 0).isEmpty)
    }

    @Test("background classification drains progress, ends at zero, and stops on a stalled backlog")
    func classificationDrainDecision() {
        #expect(AppDelegate.backgroundClassificationChunkSize == 60)
        var progress = ClassificationBacklogProgress(patience: AppDelegate.backgroundClassificationPatience)
        #expect(progress.record(remaining: 120, classified: 0) == .continueDrain)
        #expect(progress.record(remaining: 60, classified: 60) == .continueDrain)
        #expect(progress.record(remaining: 60, classified: 0) == .stalled)
        #expect(progress.record(remaining: 0, classified: 60) == .complete)
    }
}
