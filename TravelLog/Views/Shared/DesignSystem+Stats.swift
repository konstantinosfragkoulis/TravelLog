//
//  DesignSystem+Stats.swift
//  TravelLog
//
//  Stats-page pieces of the shared vocabulary: the section shell every
//  Stats card wears (headline header above an `.appCard()`) and the
//  globe's ocean stand-in.
//

import SwiftUI
import UIKit

extension AppTheme {
    /// The globe's loading stand-in, matching the imagery's dark ocean so
    /// the swap reads as the globe resolving, top to bottom.
    static let globeOcean = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.07, green: 0.11, blue: 0.27, alpha: 1)
        : UIColor(red: 0.09, green: 0.14, blue: 0.30, alpha: 1) })
    static let globeOceanDeep = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.02, green: 0.04, blue: 0.12, alpha: 1)
        : UIColor(red: 0.03, green: 0.06, blue: 0.15, alpha: 1) })
}

// MARK: - Passport book (Midnight Cobalt)

extension AppTheme {
    /// The lift in the Passport cover's top trailing corner.
    static let coverGlow = cobaltFill
    /// The Passport cover's soft cobalt drop shadow.
    static let coverShadow = Color(UIColor(hex: 0x2742D8, alpha: 0.18))
    /// The fine foil rule on a stamp page.
    static let foilLine = foil.opacity(0.55)
    /// The dot grid printed on a stamp page.
    static let stampGrid = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(hex: 0xE6C27A, alpha: 0.13) : UIColor(hex: 0xC9983A, alpha: 0.2) })
    /// An unselected page dot.
    static let pageDotOff = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 235 / 255, green: 235 / 255, blue: 245 / 255, alpha: 0.22)
        : UIColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.2) })
    /// The glow under saffron marks; dark only.
    static let saffronGlow = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(hex: 0xFFBE3D, alpha: 0.4) : UIColor(hex: 0xF2A516, alpha: 0) })
}

/// A Stats section: its headline header (and optional trailing caption)
/// on the grouped page, the content in the one card below it, as an inset
/// grouped list draws a section.
struct StatsSection<Trailing: View, Content: View>: View {
    let title: String
    var spacing: CGFloat = 12
    var padded = true
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let content: Content

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility sizes the caption drops below the title, so
        // neither squeezes the other.
        let header = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        VStack(alignment: .leading, spacing: 8) {
            header {
                Text(title)
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                trailing
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .appCard(padded: padded)
        }
    }
}

extension StatsSection where Trailing == EmptyView {
    init(title: String, spacing: CGFloat = 12, padded: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(title: title, spacing: spacing, padded: padded, trailing: { EmptyView() }, content: content)
    }
}
