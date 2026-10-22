//
//  DesignSystem.swift
//  TravelLog
//
//  The app's one visual vocabulary: Cobalt & Saffron. Cobalt (the
//  AccentColor asset, shared with Wrapped's mark) carries structure,
//  navigation and history; saffron marks only the moments that matter
//  (ongoing, upcoming, new, peaks, the selected hex). System grouped
//  surfaces, one card radius and two thumbnail radii, rounded numerals for
//  statistics, one chip and one status pill. Screens use these instead of
//  local literals.
//

import SwiftUI
import UIKit

enum AppTheme {

    // MARK: Colour

    /// The app tint. Icons, links, chart bars, map hexes and selected chips.
    /// Read from the asset by name, so offscreen renders (share images)
    /// get cobalt too; `Color.accentColor` falls back to system blue there.
    static let accent = Color("AccentColor")
    /// Filled cobalt surfaces (Passport, Wrapped preparing), top to bottom.
    static let field = dynamic(hex: 0x2742D8, dark: 0x2742D8)
    static let fieldMid = dynamic(hex: 0x172B9E, dark: 0x172B9E)
    static let fieldDeep = dynamic(hex: 0x0B1556, dark: 0x0B1556)
    /// The deepest field, where the expanded Passport's cobalt ends.
    static let fieldNight = Color(UIColor(hex: 0x070E3A))
    static let onField = Color.white
    static let onFieldSecondary = Color.white.opacity(0.74)
    /// Solid cobalt under white text: plates, pills, tiles, markers.
    static let cobaltFill = Color(UIColor(hex: 0x3D5CF0))
    /// Chart bars and data marks on a card.
    static let bar = dynamic(hex: 0x3D5CF0, dark: 0x5B78F6)

    /// The second voice, only for what matters now: fills and graphics.
    static let saffron = dynamic(hex: 0xF2A516, dark: 0xFFBE3D)
    /// Saffron for text on card or page backgrounds (4.5:1 or better).
    static let saffronText = dynamic(hex: 0x9A5800, dark: 0xFFC65A)
    /// Soft saffron wash behind saffron glyphs.
    static let saffronSoft = dynamic(UIColor(hex: 0xF2A516, alpha: 0.16), UIColor(hex: 0xFFBE3D, alpha: 0.15))
    /// Text and glyphs on a saffron fill.
    static let onSaffron = Color(UIColor(hex: 0x2A1B00))
    /// Gold foil details on a cobalt field.
    static let foil = Color(UIColor(hex: 0xE6C27A))

    /// Card fill on a grouped page.
    static let card = Color(.secondarySystemGroupedBackground)
    /// Tiles inside a card, neutral chips.
    static let inset = Color(.tertiarySystemFill)

    // MARK: Status (one vocabulary)

    /// Anything ongoing: the saffron pill.
    static let ongoing = saffron
    /// Needs the user's action: missing permission, flights to review.
    static let attention = Color.orange
    /// Something failed.
    static let failure = Color.red
    // Healthy states stay quiet: use `.secondary`.

    // MARK: Shape and space

    /// Cards, matching iOS inset grouped lists: the lists clip their
    /// sections to a 26 pt circular corner (measured on iOS 26 and 27).
    static let cardRadius: CGFloat = 26
    /// The list's own section corner, for anything drawn inside a list row
    /// background that must follow its clip exactly (use `.circular`).
    static let listCardRadius: CGFloat = 26
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

    private static func dynamic(hex light: UInt32, dark: UInt32) -> Color {
        dynamic(UIColor(hex: light), UIColor(hex: dark))
    }
}

extension UIColor {
    /// An sRGB colour from a 0xRRGGBB literal.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

// MARK: - Components

/// The one chip: filters, metadata counts and small badges. Capsule,
/// neutral fill, accent when selected, orange when it asks for action,
/// saffron for something new. A small neutral chip's glyph wears the accent.
struct AppChip: View {
    enum Style { case neutral, selected, attention, new }

    let label: Text
    var systemImage: String?
    var style: Style = .neutral
    var small = false

    var body: some View {
        HStack(spacing: small ? 3 : 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font((small ? Font.caption2 : .caption).weight(.semibold))
                    .foregroundStyle(glyph)
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
        case .new: AnyShapeStyle(AppTheme.onSaffron)
        }
    }

    private var glyph: AnyShapeStyle {
        style == .neutral && small ? AnyShapeStyle(AppTheme.accent) : foreground
    }

    private var background: AnyShapeStyle {
        switch style {
        case .neutral: AnyShapeStyle(AppTheme.inset)
        case .selected: AnyShapeStyle(AppTheme.accent)
        case .attention: AnyShapeStyle(AppTheme.attention.opacity(0.15))
        case .new: AnyShapeStyle(AppTheme.saffron)
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
            .foregroundStyle(AppTheme.onSaffron)
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

// MARK: - Route marks (trip map and the Stops line)

extension AppTheme {
    /// The route line on the trip map and the Stops rail.
    static let routeLine = dynamic(hex: 0x3D5CF0, dark: 0x6E8BFF)
    /// The map route's casing and its stations' fill: near-black in dark,
    /// white in light, so the line holds on any basemap.
    static let routeCasing = dynamic(hex: 0xFFFFFF, dark: 0x05060A)
    /// The soft cobalt bloom around the route and the rail's stations; dark only.
    static let accentGlow = dynamic(UIColor(hex: 0x2F4BE0, alpha: 0), UIColor(hex: 0x6E8BFF, alpha: 0.42))
    /// The 1 pt rim on the Active trip's card.
    static let saffronEdge = dynamic(UIColor(hex: 0xD68C00, alpha: 0.45), UIColor(hex: 0xFFBE3D, alpha: 0.34))
    /// The top fade under the navigation buttons on a full-bleed map.
    static let mapEdge = dynamic(UIColor(hex: 0xF2F2F7, alpha: 0.6), UIColor(hex: 0x000000, alpha: 0.6))
}

// MARK: - Weather glyphs

/// Multicolour weather symbols draw their clouds white, which vanishes on a
/// light card; light mode gives them a grey hairline edge, as the design's
/// outlined cloud does. Dark keeps the symbol as drawn.
private struct WeatherGlyphEdge: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .shadow(color: colorScheme == .dark ? .clear : Color(white: 0.45).opacity(0.9), radius: 0.4)
            .shadow(color: colorScheme == .dark ? .clear : Color(white: 0.45).opacity(0.5), radius: 0.4)
    }
}

extension View {
    /// Multicolour rendering with the light-mode edge.
    func weatherGlyph() -> some View {
        symbolRenderingMode(.multicolor).modifier(WeatherGlyphEdge())
    }
}
