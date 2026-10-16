//
//  DesignSystem+Stats.swift
//  TravelLog
//
//  Stats-page pieces of the shared vocabulary: the section shell every
//  Stats card wears (headline header above an `.appCard()`), the muted
//  accent for past chart bars, and the globe's ocean stand-in.
//

import SwiftUI
import UIKit

extension AppTheme {
    /// Past or unselected chart bars: the accent, muted.
    static let accentMuted = accent.opacity(0.35)

    /// The globe's loading stand-in, matching the imagery's dark ocean so
    /// the swap reads as the globe resolving, top to bottom.
    static let globeOcean = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.07, green: 0.11, blue: 0.27, alpha: 1)
        : UIColor(red: 0.09, green: 0.14, blue: 0.30, alpha: 1) })
    static let globeOceanDeep = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.02, green: 0.04, blue: 0.12, alpha: 1)
        : UIColor(red: 0.03, green: 0.06, blue: 0.15, alpha: 1) })
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
                    .font(.headline)
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
