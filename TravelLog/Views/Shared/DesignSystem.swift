//
//  DesignSystem.swift
//  TravelLog
//
//  The app's one visual vocabulary: the cobalt accent (the AccentColor
//  asset, shared with Wrapped's mark), system grouped surfaces, one card
//  radius and two thumbnail radii, rounded numerals for statistics, one
//  chip and one status pill. Screens use these instead of local literals.
//

import SwiftUI
import UIKit

enum AppTheme {

    // MARK: Colour

    /// The app tint. Every icon, link, chart bar, map hex and selected chip.
    /// Read from the asset by name, so offscreen renders (share images)
    /// get cobalt too; `Color.accentColor` falls back to system blue there.
    static let accent = Color("AccentColor")
    /// Filled cobalt surfaces (Passport, Wrapped preparing), top to bottom.
    static let field = dynamic(UIColor(red: 0.12, green: 0.25, blue: 0.88, alpha: 1),
                               UIColor(red: 0.18, green: 0.28, blue: 0.86, alpha: 1))
    static let fieldDeep = dynamic(UIColor(red: 0.06, green: 0.14, blue: 0.58, alpha: 1),
                                   UIColor(red: 0.08, green: 0.13, blue: 0.46, alpha: 1))
    static let onField = Color.white
    static let onFieldSecondary = Color.white.opacity(0.78)

    /// Card fill on a grouped page.
    static let card = Color(.secondarySystemGroupedBackground)
    /// Tiles inside a card, neutral chips.
    static let inset = Color(.tertiarySystemFill)

    // MARK: Status (one vocabulary)

    /// Anything ongoing: the accent pill.
    static let ongoing = accent
    /// Needs the user's action: missing permission, flights to review.
    static let attention = Color.orange
    /// Something failed.
    static let failure = Color.red
    // Healthy states stay quiet: use `.secondary`.

    // MARK: Shape and space

    /// Cards, matching iOS inset grouped lists.
    static let cardRadius: CGFloat = 24
    /// Thumbnails 80 pt and up, inner tiles, the globe.
    static let thumbLarge: CGFloat = 12
    /// Thumbnails under 60 pt and chart bars.
    static let thumbSmall: CGFloat = 6
    static let gutter: CGFloat = 16
    static let cardPadding: CGFloat = 16

    // MARK: Type

    /// Every statistic: rounded, tabular digits.
    static func stat(_ style: Font.TextStyle = .title2, weight: Font.Weight = .bold) -> Font {
        .system(style, design: .rounded).weight(weight).monospacedDigit()
    }

    /// Expanded small capitals shared with Wrapped's poster headings.
    static let eyebrow = Font.footnote.weight(.semibold).width(.expanded)

    private static func dynamic(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

// MARK: - Components

/// The one chip: filters, metadata counts and small badges. Capsule,
/// neutral fill, accent when selected, orange when it asks for action.
struct AppChip: View {
    enum Style { case neutral, selected, attention }

    let label: Text
    var systemImage: String?
    var style: Style = .neutral
    var small = false

    var body: some View {
        HStack(spacing: small ? 3 : 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font((small ? Font.caption2 : .caption).weight(.semibold))
                    .accessibilityHidden(true)
            }
            label.font(small ? .caption.weight(.medium) : .subheadline.weight(.medium))
        }
        .lineLimit(1)
        .padding(.horizontal, small ? 8 : 12)
        .padding(.vertical, small ? 3 : 6)
        .foregroundStyle(foreground)
        .background(background, in: .capsule)
    }

    private var foreground: AnyShapeStyle {
        switch style {
        case .neutral: small ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
        case .selected: AnyShapeStyle(Color.white)
        case .attention: AnyShapeStyle(AppTheme.attention)
        }
    }

    private var background: AnyShapeStyle {
        switch style {
        case .neutral: AnyShapeStyle(AppTheme.inset)
        case .selected: AnyShapeStyle(AppTheme.accent)
        case .attention: AnyShapeStyle(AppTheme.attention.opacity(0.15))
        }
    }
}

/// Ongoing state, everywhere: the current trip, the active temporary
/// home, a journey that has begun.
struct StatusPill: View {
    let label: Text

    var body: some View {
        label
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(AppTheme.ongoing, in: .capsule)
    }
}

extension View {
    /// The card every non-List section wears on a grouped page.
    func appCard(padded: Bool = true) -> some View {
        self
            .padding(padded ? AppTheme.cardPadding : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.card, in: .rect(cornerRadius: AppTheme.cardRadius))
    }
}
