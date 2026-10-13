import CryptoKit
import Foundation
import MapKit

enum CountryPolygonProvider {

    // `nonisolated`: constructed inside the detached parse below — under the
    // project's default MainActor isolation the struct would otherwise be
    // main-actor-bound (repo pattern: pure value types are `nonisolated`).
    nonisolated struct CountryPolygon: Identifiable {
        let id: String
        let isoCode: String
        let polygon: MKPolygon
    }

    /// Each feature's byte range and ISO code, in file order: only requested
    /// countries reach MKGeoJSONDecoder (world ~150 ms, 10 countries ~25 ms).
    nonisolated struct FeatureIndex: Sendable {
        let data: Data
        let features: [(iso: String, range: Range<Int>)]
        let codes: Set<String>
    }

    /// `indexed` only for the bytes the index was validated against; any
    /// other bytes take the original whole-file parse and its failure semantics.
    nonisolated enum Source: Sendable {
        case indexed(FeatureIndex)
        case parsed([String: [CountryPolygon]])
    }

    /// The countries.geojson whose index matched a whole-file parse polygon
    /// for polygon; a changed file disables the index until revalidated.
    nonisolated static let indexedResourceSHA256 = "850a237e09f6bf7739826b344936c0b549d28bd4889bf810737bc4d7b9d228eb"

    /// Memoized one-shot parse, detached so the ~3.6 MB GeoJSON decode never
    /// runs on the main thread (a multi-hundred-ms stall on the first
    /// Stats-tab open). Sharing one `Task` handle means concurrent first
    /// callers await a single parse; every later call is a cached dictionary
    /// hit. The parse is **lazy** — kicked off by the first `polygons(for:)`
    /// call (GlobeView's `.task`), NOT prewarmed at launch: the decode is a
    /// large share of launch-burst CPU, paid even by users who never open Stats.
    private static var loadTask: Task<Source?, Never>?

    /// The one in-flight subset decode and the indexed countries decoded so
    /// far, for the current `loadTask`.
    private static var decodeTask: Task<[String: [CountryPolygon]]?, Never>?
    private static var decoded: [String: [CountryPolygon]] = [:]

    #if DEBUG
    /// Test seam: runs at the start of every subset decode, off the main actor.
    nonisolated(unsafe) static var decodeHookForTesting: (@Sendable (Set<String>) -> Void)?
    #endif

    /// Retry a released parse for active callers; cancelled callers return empty.
    /// Callers share the one pending decode, then recompute what they miss.
    static func polygons(for isoCodes: Set<String>) async -> [CountryPolygon] {
        while !Task.isCancelled {
            let load = sharedLoadTask()
            guard let source = await load.value else { continue }
            guard !Task.isCancelled else { return [] }
            let index: FeatureIndex
            switch source {
            case .parsed(let all):
                return isoCodes.flatMap { code in all[code.uppercased()] ?? [] }
            case .indexed(let built):
                index = built
            }
            if decodeTask == nil {
                let missing = index.codes.intersection(isoCodes.map { $0.uppercased() }).subtracting(decoded.keys)
                if missing.isEmpty {
                    return isoCodes.flatMap { code in decoded[code.uppercased()] ?? [] }
                }
                decodeTask = Task.detached(priority: .utility) { decode(missing, from: index) }
            }
            guard let pending = decodeTask else { continue }
            let fresh = await pending.value
            if decodeTask == pending { decodeTask = nil }
            // A release while decoding dropped this generation; don't refill its memo.
            if let fresh, load == loadTask { decoded.merge(fresh) { current, _ in current } }
        }
        return []
    }

    /// Drop the memoized parse (index and decoded countries, or the whole-world
    /// dictionary) so it's reclaimed when the globe isn't on screen.
    /// Called when the app backgrounds. The next `polygons(for:)`
    /// lazily re-parses off-main; `GlobeView` keeps its already-
    /// filtered *visited* subset in its own `@State`, so a foreground return
    /// shows the globe with no gap and re-parses only if the visited set
    /// actually changes, unless an active caller must retry a cancelled parse.
    ///
    /// The in-flight parse is CANCELLED, not just orphaned: nil-ing alone
    /// would let a mid-flight parse run to completion into a dropped handle
    /// while a foreground return kicked off a second whole-world decode
    /// alongside it. A cancelled parse bails at the next feature
    /// boundary and returns nil. Active awaiters retry with a fresh shared
    /// task; cancelled callers return empty without requesting another parse.
    static func releaseCache() {
        loadTask?.cancel()
        loadTask = nil
        decodeTask?.cancel()
        decodeTask = nil
        decoded = [:]
    }

    private static func sharedLoadTask() -> Task<Source?, Never> {
        if let loadTask { return loadTask }
        let task = Task.detached(priority: .utility) { () -> Source? in
            guard let url = Bundle.main.url(forResource: "countries", withExtension: "geojson"),
                  let data = try? Data(contentsOf: url, options: .alwaysMapped)
            else { return .parsed([:]) }
            return source(for: data)
        }
        loadTask = task
        return task
    }

    // MARK: - GeoJSON Parsing

    nonisolated static func source(for data: Data) -> Source? {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == indexedResourceSHA256 else { return parseGeoJSON(data).map(Source.parsed) }
        // Verified layout: one compact line, `properties` before geometry.
        let featureStart = Array(#"{"type":"Feature","#.utf8)
        let isoKey = Array(#""ISO_A2":""#.utf8)
        let features = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [(iso: String, range: Range<Int>)] in
            guard let base = raw.baseAddress else { return [] }
            func find(_ needle: [UInt8], from start: Int, to end: Int) -> Int? {
                guard start < end, let hit = memmem(base + start, end - start, needle, needle.count) else { return nil }
                return base.distance(to: UnsafeRawPointer(hit))
            }
            var starts: [Int] = []
            var cursor = 0
            while let start = find(featureStart, from: cursor, to: raw.count) {
                starts.append(start)
                cursor = start + featureStart.count
            }
            let close = raw.lastIndex(of: UInt8(ascii: "]")) ?? raw.count
            var features: [(iso: String, range: Range<Int>)] = []
            for (i, start) in starts.enumerated() {
                // A feature ends at its closing brace, before the separator.
                var end = i + 1 < starts.count ? starts[i + 1] : close
                while end > start, raw[end - 1] != UInt8(ascii: "}") { end -= 1 }
                guard let key = find(isoKey, from: start, to: end),
                      let quote = find([UInt8(ascii: "\"")], from: key + isoKey.count, to: end)
                else { continue }
                features.append((String(decoding: raw[(key + isoKey.count)..<quote], as: UTF8.self), start..<end))
            }
            return features
        }
        guard !Task.isCancelled else { return nil }
        return .indexed(FeatureIndex(data: data, features: features, codes: Set(features.map(\.iso))))
    }

    /// The requested countries' features, in file order, through the original
    /// parse (same ids, same per-feature cancellation).
    private nonisolated static func decode(_ codes: Set<String>, from index: FeatureIndex) -> [String: [CountryPolygon]]? {
        #if DEBUG
        decodeHookForTesting?(codes)
        #endif
        guard !Task.isCancelled else { return nil }
        var subset = Data(#"{"type":"FeatureCollection","features":["#.utf8)
        for (n, feature) in index.features.filter({ codes.contains($0.iso) }).enumerated() {
            if n > 0 { subset.append(UInt8(ascii: ",")) }
            subset.append(index.data[feature.range])
        }
        subset.append(contentsOf: Array("]}".utf8))
        guard var result = parseGeoJSON(subset) else { return nil }
        for code in codes where result[code] == nil { result[code] = [] }
        return result
    }

    private nonisolated static func parseGeoJSON(_ data: Data) -> [String: [CountryPolygon]]? {
        guard let geoObjects = try? MKGeoJSONDecoder().decode(data) else { return [:] }

        var result: [String: [CountryPolygon]] = [:]

        for object in geoObjects {
            // Honor releaseCache's cancellation — keep
            // decoding ~245 countries for a dropped handle helps nobody.
            if Task.isCancelled { return nil }
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

            // **APPEND, don't assign.** Natural Earth ships
            // multiple GeoJSON features per ISO code for some countries —
            // FR has two (mainland + overseas in feature 0, Clipperton
            // Island in feature 1), AU has four, KZ and BR have two each.
            // The previous `result[isoCode] = ...` overwrote each prior
            // feature, so the very-last-listed feature won: for France
            // that's Clipperton — a tiny Pacific atoll at (-109.2°,
            // 10.3°), invisible at globe scale. The result: France
            // appeared in the country list (which reads ISO codes from
            // stays + trips, never touches this provider) but its border
            // never drew on the globe. ID composes with the running
            // accumulated count so multiple features can coexist
            // without ID collisions.
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
}

/// `MKPolygon` carries no Sendable annotation (nothing in MapKit does), but
/// its geometry is immutable after creation: points are supplied only through
/// the class factory initializers, `MKMultiPoint` exposes no mutators, and
/// `interiorPolygons` is a readonly `atomic` property — MapKit itself reads
/// overlay objects from background rendering threads by design. These
/// polygons are created once on the parse task, never mutated (we don't touch
/// the mutable `MKShape.title`/`subtitle`), and only read afterwards, so the
/// unchecked conformance is sound. It is what lets the memoized `Task` above
/// carry the parsed dictionary across the detached→main boundary.
extension CountryPolygonProvider.CountryPolygon: @unchecked Sendable {}
