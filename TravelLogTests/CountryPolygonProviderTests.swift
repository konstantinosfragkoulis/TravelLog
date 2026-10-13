//
//  CountryPolygonProviderTests.swift
//  TravelLogTests
//
//  Bundled-resource checks for CountryPolygonProvider
//  against the REAL countries.geojson; same regression class as
//  AirportDetectorTests: the resource ships in the app bundle, so its
//  absence or shape drift is a packaging defect that should fail loudly.
//
//  The load-bearing check is the multi-feature append rule:
//  Natural Earth ships several features per ISO code for some
//  countries, and an assign-instead-of-append regression makes the LAST
//  feature win; for France that's Clipperton, a Pacific atoll, so the
//  mainland border silently vanishes from the globe while every other
//  surface still lists FR. The mainland-containment assertion below fails
//  on exactly that regression.
//
//  `.serialized`: the provider memoizes one process-global parse task and
//  `releaseCache` cancels it; serialization limits cancellation interleaving
//  within this suite, and the decode tests install a process-global hook.
//  Active callers retry releases from other suites.
//

import Testing
import Foundation
import MapKit
@testable import TravelLog

@MainActor
@Suite("CountryPolygonProvider bundled resource", .serialized)
struct CountryPolygonProviderTests {

    private func contains(_ polygons: [CountryPolygonProvider.CountryPolygon],
                          latitude: Double, longitude: Double) -> Bool {
        let point = MKMapPoint(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        return polygons.contains { $0.polygon.boundingMapRect.contains(point) }
    }

    @Test("France keeps its MAINLAND across multi-feature append (Clipperton must not win)")
    func franceMainlandSurvivesMultiFeatureAppend() async {
        let fr = await CountryPolygonProvider.polygons(for: ["FR"])
        #expect(!fr.isEmpty, "bundled countries.geojson missing or unparseable")
        // Paris must fall inside some FR polygon's bounding rect; under the
        // assign regression only Clipperton (-109.2°, 10.3°) survives and
        // this fails.
        #expect(contains(fr, latitude: 48.85, longitude: 2.35),
                "mainland France lost — the multi-feature APPEND rule regressed")
        // And the multi-feature structure itself: more than one polygon.
        #expect(fr.count > 1)
    }

    // Title is honest about what count > 1 can prove: under the assign
    // regression only the LAST feature survives (count == 1), so > 1 pins
    // the append rule; it cannot pin the exact feature count, which is a
    // property of the bundled data.
    @Test("multi-feature countries accumulate MORE than the last feature (AU)")
    func australiaAccumulatesAllFeatures() async {
        let au = await CountryPolygonProvider.polygons(for: ["AU"])
        #expect(contains(au, latitude: -33.87, longitude: 151.2), "Sydney missing")
        #expect(au.count > 1)
    }

    @Test("lookup uppercases: 'gr' and 'GR' return the same polygons")
    func lookupIsCaseInsensitive() async {
        let upper = await CountryPolygonProvider.polygons(for: ["GR"])
        let lower = await CountryPolygonProvider.polygons(for: ["gr"])
        #expect(!upper.isEmpty)
        #expect(upper.map(\.id) == lower.map(\.id))
    }

    @Test("unknown codes return empty without disturbing known ones")
    func unknownCodesReturnEmpty() async {
        let unknown = await CountryPolygonProvider.polygons(for: ["XX", "ZZ"])
        #expect(unknown.isEmpty)
        let mixed = await CountryPolygonProvider.polygons(for: ["XX", "GR"])
        #expect(!mixed.isEmpty)
        #expect(mixed.allSatisfy { $0.isoCode == "GR" })
    }

    @Test("polygon IDs are unique across a multi-country query")
    func idsAreUniqueAcrossCountries() async {
        let all = await CountryPolygonProvider.polygons(for: ["FR", "AU", "GR", "US", "BR", "KZ"])
        #expect(!all.isEmpty)
        #expect(Set(all.map(\.id)).count == all.count, "composed feature IDs collided")
    }

    // Deliberately does NOT claim to prove a re-parse happened; a no-op
    // `releaseCache` yields the same observable result. What this pins is
    // the DETERMINISM contract: whatever release does, the next request
    // must produce identical polygons.
    @Test("a request after releaseCache yields identical polygons")
    func releaseCacheReloadsIdentically() async {
        let before = await CountryPolygonProvider.polygons(for: ["GR"])
        CountryPolygonProvider.releaseCache()
        let after = await CountryPolygonProvider.polygons(for: ["GR"])
        #expect(before.map(\.id) == after.map(\.id),
                "the re-parse must be deterministic")
        // Leave the suite without the ~8 MB whole-world memo resident.
        CountryPolygonProvider.releaseCache()
    }

    // The byte index is enabled only for the exact bytes it was validated
    // against; other bytes silently take the slower whole-file parse. A
    // changed countries.geojson fails here: set `indexedResourceSHA256` to
    // its digest and run `providerParity` once with every code of the new
    // file (`Set(WholeFileParse.bundled.keys)`) before shipping it.
    @Test("the bundled GeoJSON is the one the byte index was validated against")
    func bundledFileTakesTheIndex() throws {
        let url = try #require(Bundle.main.url(forResource: "countries", withExtension: "geojson"))
        guard case .indexed(let index) = CountryPolygonProvider.source(for: try Data(contentsOf: url)) else {
            Issue.record("countries.geojson changed: revalidate the byte index"); return
        }
        #expect(index.features.count == 244)
    }

    @Test("a request survives releaseCache while loading")
    func releaseCacheDuringLoadReturnsPolygons() async {
        CountryPolygonProvider.releaseCache()
        let request = Task {
            await CountryPolygonProvider.polygons(for: ["GR"])
        }
        await Task.yield()
        CountryPolygonProvider.releaseCache()
        let polygons = await request.value
        #expect(!polygons.isEmpty, "cache release must not empty an active request")
        CountryPolygonProvider.releaseCache()
    }

    // MARK: - Byte index against the whole-file parse

    // The arrays `polygons(for:)` returned before the byte index: same Set
    // iteration, ids, order per code and bit-equal rings, for multi-feature
    // countries (FR 2 features, AU 4, KZ and BR 2 each), mixed case,
    // duplicates after uppercasing and unknown codes. Expected arrays come
    // from the same Set instance the provider gets: two Sets built from one
    // literal can iterate in different orders.
    @Test("indexed lookups return what the whole-file parse returned, cold and memoized")
    func providerParity() async {
        let oracle = WholeFileParse.bundled
        #expect(!oracle.isEmpty, "bundled countries.geojson missing or unparseable")
        let multiFeature: Set<String> = ["GR", "FR", "AU", "KZ", "BR"]
        let sets: [Set<String>] = [multiFeature, ["fr", "Au", "XX", "gr", "GR", "-99", ""], []]
        for codes in sets {
            let expected = codes.flatMap { oracle[$0.uppercased()] ?? [] }
            CountryPolygonProvider.releaseCache()
            let cold = await CountryPolygonProvider.polygons(for: codes)
            let memoized = await CountryPolygonProvider.polygons(for: codes)
            #expect(WholeFileParse.same(cold, expected), "cold \(codes.sorted())")
            #expect(WholeFileParse.same(memoized, expected), "memoized \(codes.sorted())")
        }
        // A grown set adds the newly decoded country to the memoized ones.
        CountryPolygonProvider.releaseCache()
        _ = await CountryPolygonProvider.polygons(for: multiFeature)
        let grown = multiFeature.union(["IT"])
        let grownResult = await CountryPolygonProvider.polygons(for: grown)
        #expect(WholeFileParse.same(grownResult, grown.flatMap { oracle[$0] ?? [] }))
        CountryPolygonProvider.releaseCache()
    }

    // Any other bytes take the old whole-file parse with its failure
    // semantics. A few bundled features joined with other separators (valid
    // GeoJSON, different bytes) parse exactly as before; an invalid root
    // fails as a whole instead of yielding its valid features.
    @Test("bytes the index was not validated against take the whole-file parse")
    func unverifiedBytesFallBack() throws {
        let url = try #require(Bundle.main.url(forResource: "countries", withExtension: "geojson"))
        guard case .indexed(let index) = CountryPolygonProvider.source(for: try Data(contentsOf: url)) else {
            Issue.record("countries.geojson changed: revalidate the byte index"); return
        }
        let codes: Set<String> = ["GR", "FR", "AU"]
        var changed = Data(#"{"type":"FeatureCollection","features":["#.utf8)
        for (n, feature) in index.features.filter({ codes.contains($0.iso) }).enumerated() {
            if n > 0 { changed.append(contentsOf: Array(",\n".utf8)) }
            changed.append(index.data[feature.range])
        }
        changed.append(contentsOf: Array("]}\n".utf8))
        guard case .parsed(let parsed) = CountryPolygonProvider.source(for: changed) else {
            Issue.record("changed bytes must not take the index"); return
        }
        let oracle = WholeFileParse.parse(changed)
        #expect(Set(oracle.keys) == codes)
        #expect(Set(parsed.keys) == Set(oracle.keys))
        for code in codes {
            #expect(WholeFileParse.same(parsed[code] ?? [], oracle[code] ?? []), "\(code)")
        }
        let bogus = Data(String(decoding: changed, as: UTF8.self).replacingOccurrences(
            of: #"{"type":"FeatureCollection""#, with: #"{"type":"BogusCollection""#).utf8)
        guard case .parsed(let none) = CountryPolygonProvider.source(for: bogus) else {
            Issue.record("a bogus root must not take the index"); return
        }
        #expect(none.isEmpty)
    }
}

#if DEBUG
extension CountryPolygonProviderTests {

    private func withProbe(_ body: (DecodeProbe) async throws -> Void) async rethrows {
        let probe = DecodeProbe()
        CountryPolygonProvider.releaseCache()
        CountryPolygonProvider.decodeHookForTesting = { probe.hook($0) }
        defer {
            CountryPolygonProvider.decodeHookForTesting = nil
            probe.release()
            CountryPolygonProvider.releaseCache()
        }
        try await body(probe)
    }

    @Test("releaseCache during a held decode cancels it; the active caller decodes afresh",
          .timeLimit(.minutes(1)))
    func releaseDuringDecode() async throws {
        try await withProbe { probe in
            let codes: Set<String> = ["GR", "FR"]
            probe.holdNextDecode()
            let request = Task { await CountryPolygonProvider.polygons(for: codes) }
            try await probe.waitUntilHeld()
            CountryPolygonProvider.releaseCache()
            probe.release()
            let result = await request.value
            #expect(WholeFileParse.same(result, codes.flatMap { WholeFileParse.bundled[$0] ?? [] }))
            let afterRetry = probe.snapshot
            #expect(afterRetry.cancelledAfterHold == true, "release must cancel the in-flight decode")
            #expect(afterRetry.calls == [codes, codes], "the retry must decode afresh")
            // The new generation is memoized: no further decode.
            _ = await CountryPolygonProvider.polygons(for: ["GR"])
            #expect(probe.snapshot.calls.count == 2)
        }
    }

    // The generation guard: a decode that finished before a release must not
    // fill the next generation's memo. The main actor stays blocked while the
    // released decode finishes, so its caller resumes only after the release.
    // A decode slower than the block is cancelled instead, which passes too.
    @Test("a decode finished before releaseCache never fills the next memo", .timeLimit(.minutes(1)))
    func releasedGenerationDoesNotRefill() async throws {
        try await withProbe { probe in
            let codes: Set<String> = ["GR"]
            probe.holdNextDecode()
            let request = Task { await CountryPolygonProvider.polygons(for: codes) }
            try await probe.waitUntilHeld()
            probe.release()
            usleep(30_000)
            CountryPolygonProvider.releaseCache()
            let result = await request.value
            #expect(WholeFileParse.same(result, WholeFileParse.bundled["GR"] ?? []))
            #expect(probe.snapshot.calls == [codes, codes], "the released result must not be memoized")
        }
    }

    @Test("overlapping and larger requests share one pending decode", .timeLimit(.minutes(1)))
    func overlappingRequests() async throws {
        try await withProbe { probe in
            let first: Set<String> = ["FR", "US"]
            let overlapping: Set<String> = ["FR", "AU"]
            let larger: Set<String> = ["FR", "US", "GR", "KZ", "BR"]
            probe.holdNextDecode()
            let a = Task { await CountryPolygonProvider.polygons(for: first) }
            try await probe.waitUntilHeld()
            let b = Task { await CountryPolygonProvider.polygons(for: overlapping) }
            let c = Task { await CountryPolygonProvider.polygons(for: first) }
            let d = Task { await CountryPolygonProvider.polygons(for: larger) }
            // B, C and D find A's decode pending while it is held.
            try await Task.sleep(for: .milliseconds(30))
            #expect(probe.snapshot.calls.count == 1, "no second decode may start while one is pending")
            probe.release()
            let (ra, rb, rc, rd) = await (a.value, b.value, c.value, d.value)
            func expected(_ codes: Set<String>) -> [CountryPolygonProvider.CountryPolygon] {
                codes.flatMap { WholeFileParse.bundled[$0] ?? [] }
            }
            #expect(WholeFileParse.same(ra, expected(first)))
            #expect(WholeFileParse.same(rb, expected(overlapping)))
            #expect(WholeFileParse.same(rc, expected(first)))
            #expect(WholeFileParse.same(rd, expected(larger)))
            let calls = probe.snapshot.calls
            // Every country decoded exactly once across all decodes.
            let decodedCodes = calls.flatMap { $0 }
            #expect(decodedCodes.count == Set(decodedCodes).count, "a country was decoded twice: \(calls)")
            #expect(Set(decodedCodes) == larger.union(overlapping))
            // A's decode, then at most one per waiter for what it still misses.
            #expect(calls.first == first && calls.count <= 3, "\(calls)")
        }
    }

    @Test("a cancelled caller returns empty; its decode still fills the memo; unknown codes never decode",
          .timeLimit(.minutes(1)))
    func cancelledAndUnknown() async throws {
        try await withProbe { probe in
            probe.holdNextDecode()
            let request = Task { await CountryPolygonProvider.polygons(for: ["GR"]) }
            try await probe.waitUntilHeld()
            request.cancel()
            probe.release()
            #expect(await request.value.isEmpty)
            #expect(probe.snapshot.cancelledAfterHold == false, "a caller's cancel must not cancel shared work")
            let again = await CountryPolygonProvider.polygons(for: ["GR"])
            #expect(WholeFileParse.same(again, WholeFileParse.bundled["GR"] ?? []))
            #expect(probe.snapshot.calls == [["GR"]], "the completed decode must be reused")

            #expect(await CountryPolygonProvider.polygons(for: ["XX", "ZZ", "", "-99"]).isEmpty)
            #expect(probe.snapshot.calls == [["GR"]], "unknown codes must not decode")
            let mixed = await CountryPolygonProvider.polygons(for: ["fr", "XX"])
            #expect(WholeFileParse.same(mixed, WholeFileParse.bundled["FR"] ?? []))
            #expect(probe.snapshot.calls == [["GR"], ["FR"]], "only indexed codes decode")
        }
    }
}

/// Records every subset decode through the provider's DEBUG hook and can
/// hold the next one at a barrier until the test releases it.
private final class DecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Set<String>] = []
    private var holdNext = false
    private var entered = false
    private var cancelledAfterHold: Bool?
    private let proceed = DispatchSemaphore(value: 0)

    func hook(_ codes: Set<String>) {
        lock.lock()
        calls.append(codes)
        let hold = holdNext
        holdNext = false
        if hold { entered = true }
        lock.unlock()
        guard hold else { return }
        proceed.wait()
        lock.lock()
        cancelledAfterHold = Task.isCancelled
        lock.unlock()
    }

    func holdNextDecode() { lock.lock(); holdNext = true; entered = false; lock.unlock() }
    func release() { proceed.signal() }
    var snapshot: (calls: [Set<String>], entered: Bool, cancelledAfterHold: Bool?) {
        lock.lock(); defer { lock.unlock() }
        return (calls, entered, cancelledAfterHold)
    }

    func waitUntilHeld() async throws {
        for _ in 0..<2_500 where !snapshot.entered {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(snapshot.entered, "the held decode never started")
    }
}
#endif

/// `CountryPolygonProvider.parseGeoJSON` at ac678f9, verbatim except the
/// bundle read and the cancellation check: the whole-file parse the byte
/// index must reproduce.
private enum WholeFileParse {
    typealias CountryPolygon = CountryPolygonProvider.CountryPolygon

    static let bundled: [String: [CountryPolygon]] = {
        guard let url = Bundle.main.url(forResource: "countries", withExtension: "geojson"),
              let data = try? Data(contentsOf: url)
        else { return [:] }
        return parse(data)
    }()

    static func parse(_ data: Data) -> [String: [CountryPolygon]] {
        guard let geoObjects = try? MKGeoJSONDecoder().decode(data) else { return [:] }

        var result: [String: [CountryPolygon]] = [:]

        for object in geoObjects {
            guard let feature = object as? MKGeoJSONFeature,
                  let propsData = feature.properties,
                  let props = try? JSONSerialization.jsonObject(with: propsData) as? [String: Any],
                  let isoCode = props["ISO_A2"] as? String,
                  isoCode != "-99",
                  isoCode.count == 2
            else { continue }

            var mkPolygons: [MKPolygon] = []
            for geometry in feature.geometry {
                if let polygon = geometry as? MKPolygon {
                    mkPolygons.append(polygon)
                } else if let multi = geometry as? MKMultiPolygon {
                    mkPolygons.append(contentsOf: multi.polygons)
                }
            }

            let existingCount = result[isoCode]?.count ?? 0
            let newPolygons = mkPolygons.enumerated().map { index, polygon in
                CountryPolygon(
                    id: "\(isoCode)_\(existingCount + index)",
                    isoCode: isoCode,
                    polygon: polygon
                )
            }
            result[isoCode, default: []].append(contentsOf: newPolygons)
        }

        return result
    }

    /// Same ids and codes in the same order, every ring point bit-equal.
    static func same(_ a: [CountryPolygon], _ b: [CountryPolygon]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            $0.id == $1.id && $0.isoCode == $1.isoCode && samePolygon($0.polygon, $1.polygon)
        }
    }

    private static func samePolygon(_ a: MKPolygon, _ b: MKPolygon) -> Bool {
        guard a.pointCount == b.pointCount else { return false }
        let pa = a.points(), pb = b.points()
        for i in 0..<a.pointCount
        where pa[i].x.bitPattern != pb[i].x.bitPattern || pa[i].y.bitPattern != pb[i].y.bitPattern {
            return false
        }
        let ia = a.interiorPolygons ?? [], ib = b.interiorPolygons ?? []
        return ia.count == ib.count && zip(ia, ib).allSatisfy { samePolygon($0, $1) }
    }
}
