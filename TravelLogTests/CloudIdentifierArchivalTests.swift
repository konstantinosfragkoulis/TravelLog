import Photos
import Testing
@testable import TravelLog

@Suite("Cloud identifier archival strings")
struct CloudIdentifierArchivalTests {
    // PhotoKit accepts three nonempty archival components; a bare UUID is invalid.
    private let archived = "00112233-4455-6677-8899-AABBCCDDEEFF:1:1234567890"

    @Test("legacy cloud identifier strings retain their archival representation")
    func legacyFormatCompatibility() throws {
        let legacy = PHCloudIdentifier(stringValue: archived)
        let stored = legacy.stringValue
        #expect(stored == archived)
        #expect(legacy.archivalStringValue == stored)
        let restored = try #require(PHCloudIdentifier(archivalStringValue: stored))
        #expect(restored.archivalStringValue == stored)
    }

    @Test("cache decoding skips malformed stored strings and retains valid identifiers")
    func skipsMalformedStrings() throws {
        let legacy = PHCloudIdentifier(stringValue: archived)
        let stored = legacy.stringValue
        let identifiers: Set<String> = [stored, "", "not a cloud identifier", "00112233-4455-6677-8899-AABBCCDDEEFF"]
        let decoded = PhotoService.decodeCloudIdentifiers(identifiers)
        #expect(decoded.map(\.archivalStringValue) == [stored])
        #expect(identifiers.count - decoded.count == 3)
    }

    @Test("cache refresh ignores mappings that only restate each row's stored local ID")
    func effectiveMappingsIgnoreRedundantEntries() {
        func changed(_ old: [String: String], _ new: [String: String], _ rows: [String: Set<String>]) -> Bool {
            PhotoService.effectiveCloudMappings(old, rowLocalIDsByCloudID: rows)
                != PhotoService.effectiveCloudMappings(new, rowLocalIDsByCloudID: rows)
        }
        #expect(!changed([:], ["c": "L"], ["c": ["L"]]))
        #expect(changed([:], ["c": "L2"], ["c": ["L1"]]))
        #expect(!changed(["c": "L"], [:], ["c": ["L"]]))
        #expect(changed(["c": "L"], ["c": "L2"], ["c": ["L"]]))
        #expect(changed(["c": "L"], [:], [:]))
        #expect(changed([:], ["c": "L"], ["c": ["L", "L1"]]))
    }
}
