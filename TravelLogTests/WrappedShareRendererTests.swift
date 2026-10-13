import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import TravelLog

@MainActor
struct WrappedShareRendererTests {
    @Test func concurrentExportsProduceDistinctNonblankStoryPNGs() async throws {
        let narratives = [
            "Athens and Crete made this a year to remember.",
            "Αθήνα και Κρήτη: μια χρονιά γεμάτη ταξίδια και αναμνήσεις.",
            "東京と京都を巡り、新しい思い出ができました。 여행의 추억。旅行足迹。",
            String(repeating: "Athens, Crete and Kyoto filled the year with memories. ", count: 40),
        ]
        let inputs = narratives.map { content(narrative: $0) }
        let images = try await withThrowingTaskGroup(of: Data.self) { group in
            for input in inputs {
                group.addTask { try await WrappedShareRenderer.pngData(for: input) }
            }
            var results: [Data] = []
            for try await data in group { results.append(data) }
            return results
        }
        #expect(images.count == inputs.count)
        #expect(Set(images).count == inputs.count)
        for data in images {
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 1080)
            #expect(image.height == 1920)
            let context = try #require(CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            // The dark background alone cannot satisfy this: headings/numbers/prose
            // must contribute substantial bright pixels to the decoded PNG.
            let brightSamples = stride(from: 0, to: image.width * image.height * 4, by: 80).filter {
                pixels[$0] > 180 && pixels[$0 + 1] > 180 && pixels[$0 + 2] > 180
            }.count
            #expect(brightSamples > 100)
        }
    }

    @Test func cancelledExportDoesNotReturnAPNG() async throws {
        let input = content(narrative: "A year in motion.")
        let export = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WrappedShareRenderer.pngData(for: input)
        }
        do {
            _ = try await export.value
            Issue.record("A cancelled export returned PNG data")
        } catch is CancellationError {
            // Both the detached renderer and its caller honor cancellation.
        }
    }

    private func content(narrative: String) -> WrappedShareRenderer.Content {
        .init(year: "2026", heading: "WRAPPED", tiles: [
            .init(value: "8", label: "COUNTRIES"),
            .init(value: "24", label: "CITIES"),
            .init(value: "47", label: "DAYS AWAY"),
            .init(value: "12,345", label: "KM"),
        ], narrative: narrative, branding: "TravelLog", language: "en")
    }
}
