//
//  WrappedPosterRenderTests.swift
//  TravelLogTests
//
//  Design-review render of the Wrapped poster cards and share image from
//  one invented year. Runs only when WRAPPED_RENDER_OUT names an output
//  directory (pass TEST_RUNNER_WRAPPED_RENDER_OUT to xcodebuild), so the
//  normal suite never writes files.
//

import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit
@testable import TravelLog

private let outputDirectory = ProcessInfo.processInfo.environment["WRAPPED_RENDER_OUT"]

@MainActor
@Suite("Wrapped poster render", .enabled(if: outputDirectory != nil))
struct WrappedPosterRenderTests {

    private static let size = CGSize(width: 393, height: 852)

    /// Invented countries in the ISO user-assigned range.
    private static let countryNames: [String: String] = [
        "QN": "Ostrelia", "QP": "Calderra", "QS": "Taressa", "QT": "Morwen", "QV": "Ashgrove",
    ]

    @Test("renders every card light and dark, at a large text size, a legacy recap and the share image")
    func renderAll() async throws {
        let directory = URL(fileURLWithPath: try #require(outputDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let year = Calendar(identifier: .gregorian).component(.year, from: .now) - 1
        let stats = Self.fixture(year: year)
        let container = try TestSupport.makeInMemoryContainer()

        let full = try cards(for: stats, year: year, in: container)
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            for (index, card) in full.enumerated() {
                try write(render(card, scheme: scheme),
                          to: directory.appendingPathComponent(String(format: "%02d-%@.png", index + 1, suffix)))
            }
        }
        try write(sheet(rows: [("Light", .light, .large, full), ("Dark", .dark, .large, full)]),
                  to: directory.appendingPathComponent("contact-sheet.png"))

        // Large Dynamic Type: the reflowed layouts.
        for size in [DynamicTypeSize.xxxLarge, .accessibility3] {
            let name = size == .xxxLarge ? "xxxLarge" : "ax3"
            for (index, card) in full.enumerated() {
                try write(render(card, scheme: .light, typeSize: size),
                          to: directory.appendingPathComponent(String(format: "%@-%02d-light.png", name, index + 1)))
            }
        }
        try write(sheet(rows: [("Text size xxxLarge", .light, .xxxLarge, full),
                               ("Text size accessibility 3", .dark, .accessibility3, full),
                               ("Text size accessibility 5", .light, .accessibility5, full)]),
                  to: directory.appendingPathComponent("contact-sheet-large-text.png"))

        // A recap saved before narrative inputs and the start date existed.
        var legacy = stats
        legacy.narrativeInputs = nil
        legacy.longestTripStartDate = nil
        legacy.usesTripSpanDays = nil
        legacy.newCountryCodes = []
        legacy.weatherExtremesSafe = nil
        let legacyCards = try cards(for: legacy, year: year, in: container, weatherCoverage: 0.4)
        try write(sheet(rows: [("Legacy recap", .light, .large, legacyCards)]),
                  to: directory.appendingPathComponent("contact-sheet-legacy.png"))

        // The share image, through the production off-main renderer.
        let share = WrappedShare(year: year, stats: stats, appLocaleIdentifier: "en_US")
        try await WrappedShareRenderer.pngData(for: share.content)
            .write(to: directory.appendingPathComponent("share-1080x1920.png"))
        var greek = stats
        greek.usesTripSpanDays = true
        let greekShare = WrappedShare(year: year, stats: greek, appLocaleIdentifier: "el")
        try await WrappedShareRenderer.pngData(for: greekShare.content)
            .write(to: directory.appendingPathComponent("share-1080x1920-el-locale.png"))
    }

    // MARK: - Fixture

    private static func fixture(year: Int) -> WrappedStats {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func day(_ month: Int, _ day: Int) -> Date {
            utc.date(from: DateComponents(year: year, month: month, day: day, hour: 9))!
        }
        var stats = WrappedStats()
        stats.countriesVisited = 9
        stats.citiesVisited = 31
        stats.totalDaysAbroad = 74
        stats.totalHexesVisited = 1_286
        stats.longestTripName = "Ostrel Highlands Loop"
        stats.longestTripDays = 19
        stats.longestTripStartDate = day(8, 2)
        stats.farthestDistanceKm = 9_412
        stats.farthestPlaceName = "Saltmere"
        stats.hottestTempC = 34.2
        stats.hottestLocality = "Port Halven"
        stats.coldestTempC = -6.4
        stats.coldestLocality = "Kelden Pass"
        stats.rainiestTripName = "Brisenn by Rail"
        stats.rainiestPrecipitationMm = 182
        stats.flightKm = 38_240
        stats.driveKm = 2_130
        stats.walkKm = 12
        stats.totalGreatCircleKm = 46_880
        stats.newCountryCodes = ["QP", "QS", "QT", "QV"]
        stats.mostVisitedCountryCode = "QN"
        stats.mostVisitedCountryTripCount = 4
        stats.daysAbroad = 74
        stats.daysAtHome = 291
        stats.usesTripSpanDays = true
        stats.tripsCompleted = 12
        stats.weatherExtremesSafe = true
        stats.mysteryFact = .returnedCity(name: "Vellmora", times: 4)
        let trips: [(String, Date)] = [
            ("Kelden Pass Weekend", day(2, 7)), ("Vellmora", day(3, 6)),
            ("Brisenn by Rail", day(4, 11)), ("Vellmora", day(4, 25)),
            ("Calderra Coast", day(6, 14)), ("Vellmora", day(7, 4)),
            ("Taressa and Morwen", day(7, 15)), ("Port Halven", day(7, 26)),
            ("Ostrel Highlands Loop", day(8, 2)), ("Saltmere", day(8, 28)),
            ("Vellmora", day(10, 18)), ("Ashgrove Lights", day(12, 12)),
        ]
        stats.narrativeInputs = NarrativeInputs(
            year: year, tripDisplayNames: trips.map(\.0), tripStartDates: trips.map(\.1),
            longestTripName: stats.longestTripName, longestTripDays: stats.longestTripDays,
            farthestPlaceName: stats.farthestPlaceName, farthestDistanceKm: stats.farthestDistanceKm,
            firstTimeCountryISOCodes: stats.newCountryCodes)
        stats.tripStartMonthCounts = WrappedStats.monthCounts(of: trips.map(\.1), year: year)
        return stats
    }

    private func cards(for stats: WrappedStats, year: Int, in container: ModelContainer,
                       weatherCoverage: Double = 0.9) throws -> [AnyView] {
        let row = YearWrapped(year: year)
        row.statsData = stats.encoded()
        row.weatherCoverage = weatherCoverage
        container.mainContext.insert(row)
        try container.mainContext.save()
        let names = Self.countryNames
        let view = WrappedPosterContent.$countryNameOverrideForTesting.withValue({ names[$0] ?? $0 }) {
            WrappedView(wrapped: row, onDismiss: {})
        }
        return view.settledCardsForRendering().map { AnyView($0.modelContainer(container)) }
    }

    // MARK: - Rendering

    private func render<V: View>(_ view: V, scheme: ColorScheme, typeSize: DynamicTypeSize = .large,
                                 size: CGSize = size, scale: CGFloat = 3) -> UIImage? {
        let content = view
            .frame(width: size.width, height: size.height)
            .background(Color(uiColor: .systemBackground))
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, typeSize)
            .environment(\.locale, Locale(identifier: "en_US"))
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// Every card side by side, one row per appearance or text size.
    private func sheet(rows: [(String, ColorScheme, DynamicTypeSize, [AnyView])]) -> UIImage? {
        let gap: CGFloat = 24
        let columns = rows.map(\.3.count).max() ?? 0
        let width = gap + CGFloat(columns) * (Self.size.width + gap)
        let height = 40 + CGFloat(rows.count) * (Self.size.height + 70)
        let view = VStack(alignment: .leading, spacing: 24) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: row.0).font(.system(size: 28, weight: .semibold)).foregroundStyle(.black.opacity(0.6))
                    HStack(spacing: gap) {
                        ForEach(Array(row.3.enumerated()), id: \.offset) { _, card in
                            card
                                .frame(width: Self.size.width, height: Self.size.height)
                                .environment(\.colorScheme, row.1)
                                .environment(\.dynamicTypeSize, row.2)
                                .clipShape(.rect(cornerRadius: 28))
                        }
                    }
                }
            }
        }
        .padding(gap)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(Color(white: 0.86))
        return render(view, scheme: .light, size: CGSize(width: width, height: height), scale: 1)
    }

    private func write(_ image: UIImage?, to url: URL) throws {
        let image = try #require(image, "render failed for \(url.lastPathComponent)")
        let data = try #require(image.pngData(), "PNG encode failed for \(url.lastPathComponent), size \(image.size)")
        try data.write(to: url)
    }
}
