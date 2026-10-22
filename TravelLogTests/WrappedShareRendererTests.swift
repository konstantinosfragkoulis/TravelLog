import Foundation
import CoreGraphics
import ImageIO
import Testing
@testable import TravelLog

@MainActor
struct WrappedShareRendererTests {
    @Test func concurrentExportsProduceDistinctNonblankStoryPNGs() async throws {
        // Latin, Greek, CJK and a label long enough to need the wrap and
        // shrink path: every one must fit whole.
        let labels = [
            "days away",
            "ημέρες μακριά από το σπίτι",
            "日間の旅行 여행 일수 旅行天数",
            String(repeating: "days spent away from home ", count: 3),
        ]
        let inputs = labels.map { content(label: $0) }
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
            // The cobalt background alone cannot satisfy this: the year,
            // numbers and labels must contribute substantial white pixels.
            let samples = stride(from: 0, to: image.width * image.height * 4, by: 80)
            let white = samples.filter {
                pixels[$0] > 200 && pixels[$0 + 1] > 200 && pixels[$0 + 2] > 200
            }.count
            #expect(white > 2_000)
            // And the poster is the cobalt field, not a blank or dark canvas.
            let cobalt = samples.filter {
                pixels[$0 + 2] > 180 && pixels[$0] < 80
            }.count
            #expect(cobalt > image.width * image.height * 4 / 80 / 2)
        }
    }

    @Test func textThatCannotFitWholeFailsInsteadOfClipping() async throws {
        let input = content(label: String(repeating: "far too long a label ", count: 60))
        await #expect(throws: (any Error).self) {
            _ = try await WrappedShareRenderer.pngData(for: input)
        }
    }

    @Test func cancelledExportDoesNotReturnAPNG() async throws {
        let input = content(label: "trips")
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

    @Test("the payload builds the poster from the saved totals, grouped, at most four rows")
    func payloadRows() {
        var stats = WrappedStats()
        stats.tripsCompleted = 12
        stats.countriesVisited = 9
        stats.citiesVisited = 31
        stats.totalDaysAbroad = 74
        stats.daysAbroad = 74
        stats.usesTripSpanDays = true
        stats.totalGreatCircleKm = 46_880
        stats.newCountryCodes = ["QP", "QS"]
        let share = WrappedShare(year: 2025, stats: stats, appLocaleIdentifier: "en_US")
        #expect(share.content.yearLines == ["20", "25"])
        #expect(share.content.heading == "TRAVEL")
        #expect(share.content.rows.count == 4)
        #expect(share.content.rows[0] == .init(value: "12", label: "trips"))
        #expect(share.content.rows[2] == .init(value: "74", label: "days away"))
        #expect(share.content.rows[3].value == (UnitsFormatter.isImperial ? "29,130" : "46,880"))
        #expect(share.content.footnote == "First visits: QP QS")

        // Without a trip or a distance, cities fill a row; no first visits,
        // no footnote.
        var sparse = WrappedStats()
        sparse.countriesVisited = 1
        sparse.citiesVisited = 1
        let small = WrappedShare(year: 2025, stats: sparse, appLocaleIdentifier: "en_US")
        #expect(small.content.rows == [.init(value: "1", label: "country"), .init(value: "1", label: "city")])
        #expect(small.content.footnote == nil)
    }

    private func content(label: String) -> WrappedShareRenderer.Content {
        .init(yearLines: ["20", "26"], heading: "TRAVEL", rows: [
            .init(value: "8", label: "countries"),
            .init(value: "24", label: "cities"),
            .init(value: "47", label: label),
            .init(value: "12,345", label: "kilometers"),
        ], branding: "TravelLog", footnote: "First visits: QP QS", language: "en")
    }
}
