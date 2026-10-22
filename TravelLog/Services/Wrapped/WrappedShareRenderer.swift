import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// The export receives already-localized strings, never UI or model objects.
///
/// Layout: the Wrapped poster. A cobalt story image (1080 x 1920) with a
/// small heading, the year split over two lines in compressed black
/// numerals, up to four value + label rows, and a footer. Every string is
/// fitted whole: it shrinks (labels may wrap to three lines, the footnote
/// to two) down to a floor, and a string that still cannot fit fails the
/// export rather than being clipped, so the share sheet can retry.
nonisolated enum WrappedShareRenderer {
    struct Row: Sendable, Equatable {
        let value: String
        let label: String
    }

    struct Content: Sendable {
        /// The year, already split for the two-line numeral ("20", "26").
        let yearLines: [String]
        let heading: String
        let rows: [Row]
        /// Bottom leading text, normally the app name.
        let branding: String
        /// Bottom trailing text, e.g. the first-visit country codes.
        let footnote: String?
        let language: String

        /// Every string the image draws, for tests and privacy checks.
        var allText: [String] {
            yearLines + [heading, branding] + rows.flatMap { [$0.value, $0.label] } + [footnote].compactMap { $0 }
        }
    }

    static let canvas = CGSize(width: 1080, height: 1920)
    /// The poster colour, fixed so a shared image looks the same whatever
    /// the sender's appearance.
    static let cobalt = CGColor(red: 0.12, green: 0.25, blue: 0.88, alpha: 1)

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
        let width = Int(canvas.width)
        let height = Int(canvas.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard (1...2).contains(content.yearLines.count),
              (1...4).contains(content.rows.count),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(cobalt)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let white = CGColor(gray: 1, alpha: 1)
        let soft = CGColor(gray: 1, alpha: 0.82)

        try text(content.heading, face: .heading, size: 36, minimum: 22, color: white,
                 tracking: 6, lines: 1,
                 topRect: CGRect(x: 80, y: 96, width: 920, height: 60),
                 language: content.language, in: context)

        // The year as one or two giant compressed lines, glyphs resting on
        // the bottom of their band.
        let yearBand: CGFloat = content.yearLines.count == 2 ? 430 : 600
        for (index, line) in content.yearLines.enumerated() {
            try Task.checkCancellation()
            try numeral(line, size: 600, minimum: 180, color: white, alignment: .left,
                        topRect: CGRect(x: 76, y: 170 + CGFloat(index) * (yearBand + 20),
                                        width: 928, height: yearBand),
                        in: context)
        }

        // Value rows: the numeral right-aligned in the leading column, the
        // label beside it, sharing a bottom line.
        let rowTop: CGFloat = 1110
        let rowHeight: CGFloat = 148
        for (index, row) in content.rows.enumerated() {
            try Task.checkCancellation()
            let y = rowTop + CGFloat(index) * rowHeight
            try numeral(row.value, size: 132, minimum: 48, color: white, alignment: .right,
                        topRect: CGRect(x: 80, y: y, width: 430, height: 110),
                        in: context)
            try text(row.label, face: .label, size: 44, minimum: 22, color: soft, lines: 3,
                     topRect: CGRect(x: 540, y: y + 46, width: 460, height: 100),
                     language: content.language, in: context)
        }

        try text(content.branding, face: .heading, size: 32, minimum: 22, color: soft, lines: 1,
                 topRect: CGRect(x: 80, y: 1776, width: 380, height: 60),
                 language: content.language, in: context)
        if let footnote = content.footnote, !footnote.isEmpty {
            try text(footnote, face: .heading, size: 32, minimum: 20, color: soft,
                     alignment: .right, lines: 2,
                     topRect: CGRect(x: 480, y: 1776, width: 520, height: 90),
                     language: content.language, in: context)
        }
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

    private enum Face { case label, heading }

    /// The system font for `language` (so CJK and Greek pick the right
    /// cascade) at the face's weight and width.
    private static func font(_ face: Face, size: CGFloat, language: String) -> CTFont {
        let weight: Double = face == .label ? 0.4 : 0.3
        let width: Double = face == .heading ? 0.2 : 0
        let base = CTFontCreateUIFontForLanguage(.system, size, language as CFString)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontTraitsAttribute: [kCTFontWeightTrait: weight, kCTFontWidthTrait: width],
        ] as CFDictionary)
        return CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
    }

    /// One line of compressed black numerals sized by its glyphs, not its
    /// line height, so the digits can fill their band. Shrinks until the
    /// glyph bounds fit; never clips. `UIFont` is thread-safe and is used
    /// here only as the CTFont it bridges to.
    private static func numeral(
        _ value: String, size: CGFloat, minimum: CGFloat, color: CGColor,
        alignment: CTTextAlignment, topRect: CGRect, in context: CGContext
    ) throws {
        guard !value.isEmpty else { return }
        let rect = flipped(topRect, in: context)
        var fontSize = size
        while fontSize >= minimum {
            try Task.checkCancellation()
            let ctFont = UIFont.systemFont(ofSize: fontSize, weight: .black, width: .compressed) as CTFont
            let string = NSAttributedString(string: value, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ])
            let line = CTLineCreateWithAttributedString(string)
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            if bounds.width <= rect.width, bounds.height <= rect.height {
                let x = alignment == .right ? rect.maxX - bounds.maxX : rect.minX - bounds.minX
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: x, y: rect.minY - bounds.minY)
                CTLineDraw(line, context)
                return
            }
            fontSize -= max(2, fontSize * 0.04)
        }
        throw CocoaError(.fileWriteUnknown)
    }

    /// Fit the complete string, including languages without word spaces, in
    /// at most `lines` lines. Never silently clip: if even the minimum size
    /// cannot fit, report a failed share for a retry.
    private static func text(
        _ value: String, face: Face, size: CGFloat, minimum: CGFloat,
        color: CGColor, tracking: CGFloat = 0, alignment: CTTextAlignment = .natural,
        lines: Int, topRect: CGRect, language: String, in context: CGContext
    ) throws {
        guard !value.isEmpty else { return }
        let rect = flipped(topRect, in: context)
        var fontSize = size
        while fontSize >= minimum {
            try Task.checkCancellation()
            let ctFont = font(face, size: fontSize, language: language)
            var align = alignment
            let paragraph = withUnsafePointer(to: &align) { pointer in
                var setting = CTParagraphStyleSetting(spec: .alignment,
                                                       valueSize: MemoryLayout<CTTextAlignment>.size,
                                                       value: pointer)
                return CTParagraphStyleCreate(&setting, 1)
            }
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                NSAttributedString.Key(kCTKernAttributeName as String): tracking * fontSize / size,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
                NSAttributedString.Key(kCTLanguageAttributeName as String): language,
            ]
            let string = NSAttributedString(string: value, attributes: attributes)
            let framesetter = CTFramesetterCreateWithAttributedString(string)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                                CGPath(rect: rect, transform: nil), nil)
            let lineCount = CFArrayGetCount(CTFrameGetLines(frame))
            if CTFrameGetVisibleStringRange(frame).length == string.length, lineCount <= lines {
                context.textMatrix = .identity
                CTFrameDraw(frame, context)
                return
            }
            fontSize -= max(2, fontSize * 0.04)
        }
        throw CocoaError(.fileWriteUnknown)
    }

    /// Layout rects are written top-down; Core Graphics draws bottom-up.
    private static func flipped(_ rect: CGRect, in context: CGContext) -> CGRect {
        CGRect(x: rect.minX, y: CGFloat(context.height) - rect.maxY,
               width: rect.width, height: rect.height)
    }
}
