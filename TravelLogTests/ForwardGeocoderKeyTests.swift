import Foundation
import Testing
@testable import TravelLog

/// Pins the forward-geocoder cache key: short texts keep their persisted
/// keys, and long texts that share the first 120 characters never share
/// a cached answer.
@MainActor
struct ForwardGeocoderKeyTests {
    @Test("texts of 120 characters or fewer keep their existing keys")
    func shortKeysAreUnchanged() {
        #expect(ForwardGeocoder.normalizedKey("  Rome, Italy \n") == "rome, italy")
        let exact = String(repeating: "Ab", count: 60)
        #expect(exact.count == 120)
        #expect(ForwardGeocoder.normalizedKey(exact) == exact.lowercased())
    }

    @Test("long texts sharing the first 120 characters get different keys")
    func longTextsSharingAPrefixDiffer() {
        let prefix = String(repeating: "Hotel Grande Bretagne ", count: 6)
        #expect(prefix.count > 120)
        let first = ForwardGeocoder.normalizedKey(prefix + "Athens")
        let second = ForwardGeocoder.normalizedKey(prefix + "Nafplio")
        #expect(first != second)
        #expect(first.hasPrefix(String(prefix.lowercased().prefix(120))))
        #expect(ForwardGeocoder.normalizedKey(prefix + "ATHENS ") == first)
    }

    @Test("a cached rejection for one long text does not answer another sharing its prefix")
    func cachedRejectionDoesNotLeakAcrossLongTexts() async {
        let suite = "ForwardGeocoderKeyTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let geocoder = ForwardGeocoder(defaultsSuiteNameForTesting: suite)
        let rooms = Array(repeating: "Conference Room 4B", count: 8).joined(separator: ", ")
        #expect(rooms.count > 120)
        #expect(await geocoder.resolveOutcome(rooms, allowNetwork: false) == .rejected)
        #expect(await geocoder.cachedResolution(for: rooms) == .unresolved)
        #expect(await geocoder.cachedResolution(for: rooms + ", Athens") == .miss)
    }
}
