import CoreLocation
import Foundation
import Photos
import Testing
@testable import TravelLog

@MainActor
struct PhotoCountAdmissionTests {
    private struct Asset {
        let id: String
        var location: CLLocation? = nil
        var date: Date? = nil
        var subtypes: PHAssetMediaSubtype = []
        var source: PHAssetSourceType = .typeUserLibrary
    }

    @Test("Count admission equals the previous admission plus group total",
          arguments: [0, 1, 2])
    func admissionParity(layout: Int) {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let stays: [StaySnapshot] = layout == 0 ? [] : (0..<2).map { index in
            StaySnapshot(
                id: UUID(), latitude: 0, longitude: 0,
                startTime: start.addingTimeInterval(layout == 1 ? 0 : Double(index) * 14_400),
                endTime: start.addingTimeInterval(3600 + (layout == 1 ? 0 : Double(index) * 14_400)),
                orderInTrip: index, durationMinutes: 60, locality: nil,
                categoryRaw: StayCategory.destination.rawValue
            )
        }
        let matchContexts = stays.map {
            StayMatchContext(latitude: $0.latitude, longitude: $0.longitude,
                             startTime: $0.startTime, endTime: $0.endTime,
                             radiusMeters: 50_000, timeBuffer: 1800)
        }
        let groupContexts = stays.sorted { $0.orderInTrip < $1.orderInTrip }.map(StayGroupContext.init)
        let near = CLLocation(latitude: 0.1, longitude: 0.1)
        let hidden: Set<String> = ["hidden"]
        let fixtures: [Asset] = [
            Asset(id: "gps-in", location: near, date: start),
            Asset(id: "gps-out", location: CLLocation(latitude: 2, longitude: 2), date: start),
            Asset(id: "box-in-radius-out", location: CLLocation(latitude: 0.4, longitude: 0.4), date: start),
            Asset(id: "gps-time-fallback", location: near, date: start.addingTimeInterval(7200)),
            Asset(id: "no-gps-in", date: start),
            Asset(id: "no-gps-gap", date: start.addingTimeInterval(7200)),
            Asset(id: "second-window", date: start.addingTimeInterval(14_400)),
            Asset(id: "lower-edge", date: start.addingTimeInterval(-1800)),
            Asset(id: "upper-edge", date: start.addingTimeInterval(5400)),
            Asset(id: "before-edge", date: start.addingTimeInterval(-1801)),
            Asset(id: "after-edge", date: start.addingTimeInterval(5401)),
            Asset(id: "screenshot-gps", location: near, date: start, subtypes: .photoScreenshot),
            Asset(id: "screenshot-no-gps", date: start, subtypes: .photoScreenshot),
            Asset(id: "shared-gps", location: near, date: start, source: .typeCloudShared),
            Asset(id: "shared-no-gps", date: start, source: .typeCloudShared),
            Asset(id: "hidden", location: near, date: start),
            Asset(id: "missing-date-gps", location: near),
            Asset(id: "missing-date-no-gps")
        ]

        // Previous computePhotoGroups admission, before the hidden/date/grouping drops.
        let oldMatched = fixtures.filter { asset in
            if asset.subtypes.contains(.photoScreenshot) { return false }
            if asset.source == .typeCloudShared { return false }
            if let location = asset.location {
                return matchContexts.contains {
                    $0.boxContains(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                        && location.distance(from: $0.location) < 50_000
                }
            }
            let date = asset.date ?? .distantPast
            return matchContexts.contains { date >= $0.windowStart && date <= $0.windowEnd }
        }
        let oldVisible = oldMatched.filter { !hidden.contains($0.id) }
        var oldGroups: [UUID: [String]] = [:]
        for asset in oldVisible {
            guard let date = asset.date else { continue }
            guard let id = PhotoService.nearestStayID(
                assetLocation: asset.location, creationDate: date, sortedContexts: groupContexts
            ) else { continue }
            oldGroups[id, default: []].append(asset.id)
        }
        let oldTotal = stays.reduce(0) { $0 + (oldGroups[$1.id]?.count ?? 0) }

        var count = 0
        var admittedIDs: [String] = []
        for asset in fixtures {
            let admitted = PhotoService.isAdmittedAsset(
                location: asset.location, creationDate: asset.date,
                mediaSubtypes: asset.subtypes, sourceType: asset.source,
                localIdentifier: asset.id, hidden: hidden, matchContexts: matchContexts
            )
            #expect(admitted == oldGroups.values.contains { $0.contains(asset.id) }, "Fixture: \(asset.id)")
            if admitted {
                count += 1
                admittedIDs.append(asset.id)
            }
        }
        #expect(count == oldTotal)
        #expect(count == (layout == 0 ? 0 : (layout == 1 ? 5 : 6)))
        #expect(admittedIDs.sorted() == oldGroups.values.flatMap { $0 }.sorted())
        if layout == 1 {
            #expect(oldGroups.count == 1, "Identical windows assign each asset only once")
        }
    }
}
