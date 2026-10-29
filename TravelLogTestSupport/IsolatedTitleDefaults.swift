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
        // The classifiers these suites run log regrouping lineage.
        try await TripClassifier.$hiddenLineageSuiteNameForTesting.withValue(suite) {
            // Title/classification fixtures never grant calendar access;
            // pin it so no case blocks on the calendar daemon.
            try await CalendarEnricher.TestScope.$authorizationStatus.withValue(.notDetermined) {
                // Writers that leave a trip for a later summary pass record it here.
                try await TripTitleStore.$summaryDebtSuiteForTesting.withValue(suite) {
                    try await function()
                }
            }
        }
    }

    static var current: UserDefaults {
        guard let suite = TripClassifier.hiddenLineageSuiteNameForTesting else {
            preconditionFailure("Title test must use IsolatedTitleDefaults")
        }
        return UserDefaults(suiteName: suite)!
    }
}
