import Foundation
import Testing

struct PrivacyPolicyCopyTests {
    @Test("Settings bundles the same privacy policy the site publishes")
    func bundledPolicyMatchesPublishedPolicy() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let bundled = try String(contentsOf: repository.appendingPathComponent("TravelLog/PrivacyPolicy.html"),
                                 encoding: .utf8)
        let published = try String(contentsOf: repository.appendingPathComponent("legal/privacy-policy.html"),
                                   encoding: .utf8)
        #expect(bundled == published)
    }
}
