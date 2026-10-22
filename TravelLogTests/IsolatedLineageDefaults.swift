import Foundation
import Testing
@testable import TravelLog

/// Gives each test case its own hidden-photo lineage log: every classifier a
/// case runs regroups trips into it instead of the test host's standard
/// defaults, where entries would outlive the case and reach the next one.
struct IsolatedLineageDefaults: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @concurrent @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { try await function(); return }
        let suite = "lineage-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        try await TripClassifier.$hiddenLineageSuiteNameForTesting.withValue(suite) {
            try await function()
        }
    }
}
