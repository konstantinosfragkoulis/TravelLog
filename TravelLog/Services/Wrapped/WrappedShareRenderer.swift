import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// The export receives already-localized strings, never UI or model objects.
nonisolated enum WrappedShareRenderer {
    struct Tile: Sendable {
        let value: String
        let label: String
    }

    struct Content: Sendable {
        let year: String
        let heading: String
        let tiles: [Tile]
        let narrative: String
        let branding: String
        let language: String
    }

    static func pngData(for content: Content) async throws -> Data {
        try Task.checkCancellation()
        let render = Task.detached(priority: .userInitiated) {
            try renderPNG(content)
        }
        return try await withTaskCancellationHandler {
            let data = try await render.value
            try Task.checkCancellation()
            return data
        } onCancel: {
            render.cancel()
        }
    }

    private static func renderPNG(_ content: Content) throws -> Data {
        // Keep bitmap allocation, text layout, drawing and PNG encoding off the UI queue.
        dispatchPrecondition(condition: .notOnQueue(.main))
        try Task.checkCancellation()
        let width = 1080
        let height = 1920
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard content.tiles.count == 4,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let gold = CGColor(red: 0.85, green: 0.72, blue: 0.42, alpha: 1)
        let background = CGGradient(colorsSpace: space, colors: [
            CGColor(red: 0.10, green: 0.15, blue: 0.34, alpha: 1),
            CGColor(red: 0.04, green: 0.07, blue: 0.18, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(background, start: CGPoint(x: 0, y: height),
                                   end: .zero, options: [])
        let glow = CGGradient(colorsSpace: space, colors: [
            gold.copy(alpha: 0.25)!, gold.copy(alpha: 0)!,
        ] as CFArray, locations: [0, 1])!
        context.drawRadialGradient(glow, startCenter: CGPoint(x: width, y: height),
                                   startRadius: 0, endCenter: CGPoint(x: width, y: height),
                                   endRadius: 900, options: [])

        try text(content.heading, font: .heading, size: 40, minimum: 24,
                 color: gold, tracking: 20, topRect: CGRect(x: 80, y: 80, width: 920, height: 70),
                 language: content.language, in: context)
        try text(content.year, font: .year, size: 220, minimum: 150,
                 topRect: CGRect(x: 80, y: 185, width: 920, height: 285),
                 language: content.language, in: context)
        for (index, tile) in content.tiles.enumerated() {
            try Task.checkCancellation()
            let x = CGFloat(80 + (index % 2) * 484)
            let y = CGFloat(530 + (index / 2) * 215)
            try text(tile.value, font: .value, size: 96, minimum: 40,
                     topRect: CGRect(x: x, y: y, width: 436, height: 120),
                     language: content.language, in: context)
            try text(tile.label, font: .label, size: 28, minimum: 16,
                     color: CGColor(gray: 1, alpha: 0.55), tracking: 6,
                     topRect: CGRect(x: x, y: y + 122, width: 436, height: 82),
                     language: content.language, in: context)
        }
        try text(content.narrative, font: .narrative, size: 34, minimum: 18,
                 color: CGColor(gray: 1, alpha: 0.92), lineSpacing: 10,
                 topRect: CGRect(x: 80, y: 1000, width: 920, height: 700),
                 language: content.language, in: context)
        // A text-presentation airplane preserves the existing icon without UIKit/SF Symbols.
        try text("✈︎", font: .heading, size: 38, minimum: 30,
                 color: CGColor(gray: 1, alpha: 0.6),
                 topRect: CGRect(x: 80, y: 1780, width: 50, height: 60),
                 language: content.language, in: context)
        try text(content.branding, font: .heading, size: 40, minimum: 32,
                 color: CGColor(gray: 1, alpha: 0.6),
                 topRect: CGRect(x: 144, y: 1780, width: 856, height: 60),
                 language: content.language, in: context)
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try Task.checkCancellation()
        return data as Data
    }

    /// Fit the complete string, including languages without word spaces. Never silently clip
    /// a narrative; if even the minimum size cannot fit, report a failed share for a retry.
    private enum Face { case year, value, label, heading, narrative }

    private static func text(
        _ value: String, font face: Face, size: CGFloat, minimum: CGFloat,
        color: CGColor = CGColor(gray: 1, alpha: 1), tracking: CGFloat = 0,
        lineSpacing: CGFloat = 0, topRect: CGRect, language: String, in context: CGContext
    ) throws {
        guard !value.isEmpty else { return }
        let rect = CGRect(x: topRect.minX, y: 1920 - topRect.maxY,
                          width: topRect.width, height: topRect.height)
        var fontSize = size
        while fontSize >= minimum {
            try Task.checkCancellation()
            let font: CTFont
            if face == .narrative {
                font = CTFontCreateWithName("Georgia" as CFString, fontSize, nil)
            } else {
                let weight: Double = switch face {
                case .year: 0.62
                case .value: 0.56
                case .heading: 0.3
                case .label: 0.23
                case .narrative: 0
                }
                let base = CTFontCreateUIFontForLanguage(.system, fontSize, language as CFString)
                    ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
                let descriptor = CTFontDescriptorCreateWithAttributes([
                    kCTFontTraitsAttribute: [kCTFontWeightTrait: weight],
                ] as CFDictionary)
                font = CTFontCreateCopyWithAttributes(base, fontSize, nil, descriptor)
            }
            var spacing = lineSpacing * fontSize / size
            let paragraph = withUnsafePointer(to: &spacing) { pointer in
                var setting = CTParagraphStyleSetting(spec: .lineSpacingAdjustment,
                                                       valueSize: MemoryLayout<CGFloat>.size,
                                                       value: pointer)
                return CTParagraphStyleCreate(&setting, 1)
            }
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                NSAttributedString.Key(kCTKernAttributeName as String): tracking * fontSize / size,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
                NSAttributedString.Key(kCTLanguageAttributeName as String): language,
            ]
            let string = NSAttributedString(string: value, attributes: attributes)
            let framesetter = CTFramesetterCreateWithAttributedString(string)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                                CGPath(rect: rect, transform: nil), nil)
            if CTFrameGetVisibleStringRange(frame).length == string.length {
                context.textMatrix = .identity
                CTFrameDraw(frame, context)
                return
            }
            fontSize -= 2
        }
        throw CocoaError(.fileWriteUnknown)
    }
}
