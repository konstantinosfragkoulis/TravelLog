//
//  WidgetTheme.swift
//  TravelLogWidgets
//
//  The app's Midnight Cobalt roles for the widget extension (the app's
//  `AppTheme` is not in this target): cobalt is the AccentColor asset,
//  saffron marks only what is happening now, surfaces are the grouped
//  card colours.
//

import SwiftUI
import UIKit
import WidgetKit

enum WidgetTheme {
    /// The grouped card surface (#1C1C1E dark, white light).
    static let card = Color(.secondarySystemGroupedBackground)
    static let saffron = dynamic(light: 0xF2A516, dark: 0xFFBE3D)
    static let onSaffron = Color(uiColor: UIColor(rgb: 0x2A1B00))

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        let lightColor = UIColor(rgb: light)
        let darkColor = UIColor(rgb: dark)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor })
    }
}

private extension UIColor {
    convenience init(rgb hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

/// The saffron "Active" pill of the app's active trip card.
struct WidgetActivePill: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(WidgetTheme.onSaffron)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(WidgetTheme.onSaffron)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(WidgetTheme.saffron))
        .widgetAccentable()
    }
}
