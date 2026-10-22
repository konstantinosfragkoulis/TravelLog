import Foundation
import Testing
@testable import TravelLog

struct IsolatedCalendarDefaults: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @concurrent @Sendable () async throws -> Void) async throws {
        guard testCase != nil else { try await function(); return }
        let suite = "calendar-audit-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let geocoder = ForwardGeocoder(defaultsSuiteNameForTesting: suite)
        try await ForwardGeocoder.TestScope.$defaultsSuiteName.withValue(suite) {
            try await ForwardGeocoder.TestScope.$geocoder.withValue(geocoder) {
                try await function()
            }
        }
    }

    static var current: UserDefaults {
        guard let suite = ForwardGeocoder.TestScope.defaultsSuiteName else {
            preconditionFailure("Calendar defaults test must use IsolatedCalendarDefaults")
        }
        return UserDefaults(suiteName: suite)!
    }
}
