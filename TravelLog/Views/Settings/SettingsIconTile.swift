//
//  SettingsIconTile.swift
//  TravelLog
//

import SwiftUI
import UIKit

/// A Settings row's icon: a white filled symbol on a small rounded tile,
/// coloured by what the row is about. Cobalt for the record and its
/// sources, graphite for housekeeping. Decorative: the row's title carries
/// the meaning for VoiceOver.
struct SettingsIconTile: View {
    enum Meaning {
        /// The record and its sources: tracking, sync, photos, calendar,
        /// homes, temporary homes, recaps.
        case record
        /// Housekeeping: notifications, units, data, about.
        case housekeeping
    }

    static let side: CGFloat = 30

    let systemImage: String
    let meaning: Meaning

    var body: some View {
        Image(systemName: systemImage)
            .resizable()
            .scaledToFit()
            .symbolVariant(.fill)
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .frame(width: Self.side, height: Self.side)
            .background(fill, in: .rect(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }

    private var fill: Color {
        switch meaning {
        case .record: Self.cobalt
        case .housekeeping: Self.graphite
        }
    }

    // Tile fills, tuned for a white glyph in each appearance.
    private static let cobalt = tile(light: 0x2F4BE0, dark: 0x3D5CF0)
    private static let graphite = tile(light: 0x8E8E93, dark: 0x3A3A3C)

    private static func tile(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

/// A Settings row: its tile, then its title, with the row's separator
/// starting under the title as in the system Settings app.
struct SettingsTileLabel<Title: View>: View {
    let systemImage: String
    let meaning: SettingsIconTile.Meaning
    @ViewBuilder var title: Title

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconTile(systemImage: systemImage, meaning: meaning)
            title
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
    }
}

extension SettingsTileLabel where Title == Text {
    /// A title already localized; a literal goes to the key initializer, as with `Text`.
    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, systemImage: String, meaning: SettingsIconTile.Meaning) {
        self.init(systemImage: systemImage, meaning: meaning) { Text(title) }
    }

    init(_ title: LocalizedStringKey, systemImage: String, meaning: SettingsIconTile.Meaning) {
        self.init(systemImage: systemImage, meaning: meaning) { Text(title) }
    }
}

/// A Settings action without a tile (Open Settings, Delete All
/// Data): an empty tile-wide slot keeps its title in the titles' column.
struct SettingsUntiledLabel<Title: View>: View {
    @ViewBuilder var title: Title

    var body: some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: SettingsIconTile.side, height: 1)
                .accessibilityHidden(true)
            title
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
    }
}

/// The trailing chevron of a row that opens a sheet, drawn as a
/// navigation link draws its own.
struct SettingsChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

extension Text {
    /// A Settings section header: subheadline semibold, secondary, as
    /// written (never upper-cased).
    func settingsHeader() -> some View {
        self
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}

extension View {
    /// The Settings list metrics: 52 pt rows.
    func settingsList() -> some View {
        environment(\.defaultMinListRowHeight, 52)
    }
}
