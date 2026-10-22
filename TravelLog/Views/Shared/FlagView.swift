//
//  FlagView.swift
//  TravelLog
//
//  A country's flag as a flat rounded rectangle, from the bundled vector
//  flag set (`flag-<iso>` image sets in Flags.xcassets, lipis/flag-icons
//  4:3 artwork), with a hairline edge so white and dark flags hold their
//  shape on any surface. Unknown codes draw a neutral placeholder rather
//  than another country's flag.
//
//  Shared with the widget extension (pbxproj membershipExceptions, with
//  Flags.xcassets and FlagAssetCodes.swift).
//

import SwiftUI
import UIKit
import WidgetKit

struct FlagView: View {
    /// Point sizes from the design: rows, headers, Stats lists.
    enum Size {
        case small, regular, large

        var dimensions: CGSize {
            switch self {
            case .small: CGSize(width: 20, height: 14)
            case .regular: CGSize(width: 28, height: 19)
            case .large: CGSize(width: 36, height: 24)
            }
        }

        /// The gap between flags in a row: wide enough that two flags
        /// read as two, not as one striped banner.
        var rowSpacing: CGFloat {
            switch self {
            case .small: 5
            case .regular: 6
            case .large: 8
            }
        }
    }

    let iso: String?
    var size: Size = .regular

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dimensions = size.dimensions
        let shape = RoundedRectangle(cornerRadius: dimensions.height * 0.16, style: .continuous)
        if let name = Self.assetName(for: iso), Self.unframed.contains(name) {
            // Not a rectangle: drawn whole, with no clip or edge.
            Image(name)
                .resizable()
                .widgetAccentedRenderingMode(.fullColor)
                .aspectRatio(contentMode: .fit)
                .frame(width: dimensions.width, height: dimensions.height)
                .accessibilityHidden(true)
        } else {
            Group {
                if let name = Self.assetName(for: iso) {
                    if Self.stretched.contains(name) {
                        Image(name)
                            .resizable()
                            .widgetAccentedRenderingMode(.fullColor)
                    } else {
                        Image(name)
                            .resizable()
                            .widgetAccentedRenderingMode(.fullColor)
                            .aspectRatio(contentMode: .fill)
                    }
                } else {
                    Color(.tertiarySystemFill)
                }
            }
            .frame(width: dimensions.width, height: dimensions.height)
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12),
                                   lineWidth: 0.5)
            )
            .accessibilityHidden(true)
        }
    }

    /// The bundled image for an ISO 3166-1 alpha-2 code, if one ships.
    /// A set lookup, never a bundle probe: safe per row in long lists.
    nonisolated static func assetName(for iso: String?) -> String? {
        guard let iso, iso.utf8.count == 2 else { return nil }
        let code = iso.lowercased()
        return FlagAssetCodes.shipped.contains(code) ? "flag-\(code)" : nil
    }

    /// Flags whose 4:3 artwork would lose a framing border to the 3:2 crop
    /// (Grenada, Sri Lanka, Montenegro): scaled to the frame instead, which
    /// widens them toward their official, wider proportions.
    private static let stretched: Set<String> = ["flag-gd", "flag-lk", "flag-me"]
    /// Nepal's pennants: transparent around the shape, so never cropped.
    private static let unframed: Set<String> = ["flag-np"]

    /// ISO codes back out of a flag-emoji string (regional-indicator pairs),
    /// in order, for surfaces whose values only carry the emoji. Anything
    /// else in the string is skipped.
    nonisolated static func isoCodes(fromFlagEmoji text: String) -> [String] {
        let base: UInt32 = 0x1F1E6
        var codes: [String] = []
        var pending: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            guard (base...base + 25).contains(scalar.value),
                  let letter = Unicode.Scalar(scalar.value - base + 65) else {
                pending = nil
                continue
            }
            if let first = pending {
                codes.append(String(Character(first)) + String(Character(letter)))
                pending = nil
            } else {
                pending = letter
            }
        }
        return codes
    }
}

/// Several flags in visit order, as one compact row.
struct FlagRow: View {
    let codes: [String]
    var size: FlagView.Size = .regular

    var body: some View {
        HStack(spacing: size.rowSpacing) {
            ForEach(Array(codes.enumerated()), id: \.offset) { _, code in
                FlagView(iso: code, size: size)
            }
        }
    }
}
