import EventKit
import Foundation
import Testing
@testable import TravelLog

struct IsolatedTitleDefaults: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @concurrent @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { try await function(); return }
        let suite = "title-audit-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        try await TripClassifier.$failureDefaultsSuiteNameForTesting.withValue(suite) {
            try await TripTitleLocalizationService.$failureDefaultsSuiteNameForTesting.withValue(suite) {
                // The classifiers these suites run log regrouping lineage too.
                try await TripClassifier.$hiddenLineageSuiteNameForTesting.withValue(suite) {
                    // Title/classification fixtures never grant calendar access;
                    // pin it so no case blocks on the calendar daemon.
                    try await CalendarEnricher.TestScope.$authorizationStatus.withValue(.notDetermined) {
                        try await function()
                    }
                }
            }
        }
    }

    static var current: UserDefaults {
        guard let suite = TripClassifier.failureDefaultsSuiteNameForTesting else {
            preconditionFailure("Title test must use IsolatedTitleDefaults")
        }
        return UserDefaults(suiteName: suite)!
    }
}
