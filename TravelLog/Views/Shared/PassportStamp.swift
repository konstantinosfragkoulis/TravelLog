//
//  PassportStamp.swift
//  TravelLog
//
//  A country's passport stamp, the Midnight Cobalt way: a thin double
//  outline whose shape follows the continent (circle for Europe, hexagon
//  for Asia, rounded rectangle for Africa, the Americas and Oceania), the
//  ISO alpha-3 code in expanded capitals, the entry date small above it and
//  the year below, in the country's own ink at a slight fixed tilt.
//
//  Usage:
//
//      PassportStamp(iso: "PT", date: firstEntry, size: 84)
//      PassportStamp(iso: "GR", date: entry, size: 74, highlighted: true)
//
//  - `iso`: ISO 3166-1 alpha-2 code (alpha-3 is accepted too).
//  - `date`: the entry date: "12 SEP" on top, "2026" below. Nil leaves both
//    lines blank and the rules frame the code alone.
//  - `size`: the stamp's square side in points; everything scales with it.
//    The tilt draws outside the square slightly, so give it a few points of room.
//  - `ink`: overrides the country's ink (`PassportStamp.ink(for:)`).
//  - `highlighted`: a first visit: the saffron spark badge at the top right.
//  - `rotation`: overrides the country's fixed tilt, in degrees.
//
//  The view carries its own accessibility label ("Portugal stamp, 12 Sep 2026").
//

import SwiftUI
import UIKit

struct PassportStamp: View {
    let iso: String
    var date: Date?
    var size: CGFloat
    var ink: Color?
    var highlighted = false
    var rotation: Double?
    /// `.book`: the expanded Passport's page stamp (one short rule, the code,
    /// then the date and the year beneath it). `.classic` by default.
    var style: Style = .classic
    /// The ring around the first-visit badge: the surface the stamp sits
    /// on (the card by default; the page colour on the cobalt Passport).
    var badgeRing: Color?

    /// The two stamp faces.
    enum Style { case classic, book }

    init(iso: String, date: Date?, size: CGFloat, ink: Color? = nil,
         highlighted: Bool = false, rotation: Double? = nil, style: Style = .classic,
         badgeRing: Color? = nil) {
        self.iso = iso
        self.date = date
        self.size = size
        self.ink = ink
        self.highlighted = highlighted
        self.rotation = rotation
        self.style = style
        self.badgeRing = badgeRing
    }

    var body: some View {
        let shape = Self.shape(for: iso)
        let layout = shape.layout
        let color = ink ?? Self.ink(for: iso)
        ZStack {
            if style == .book {
                bookFace(shape: shape, color: color)
            } else {
                classicFace(shape: shape, layout: layout, color: color)
            }
        }
        .foregroundStyle(color)
        .frame(width: size, height: size)
        .rotationEffect(.degrees(rotation ?? Self.rotation(for: iso)))
        .overlay {
            if highlighted {
                StampNewBadge(diameter: max(14, size * 0.243), ring: badgeRing ?? AppTheme.card)
                    .offset(x: size * 0.42, y: -size * 0.39)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isImage)
    }

    /// The book face: the double outline, a short rule, the code large, the
    /// entry date and the year beneath, in the 100 pt design box. The type
    /// is set in points, not scaled with the stamp: the code 18 pt at a
    /// 74 pt stamp rising to 20 pt at 88 (21/23 of that in the narrower
    /// hexagon and rectangle), the date 10 pt and the year 8 pt.
    @ViewBuilder
    private func bookFace(shape: Shape, color: Color) -> some View {
        let s = size / 100
        // Rule, code, date and year baselines.
        let y: (rule: CGFloat, code: CGFloat, date: CGFloat, year: CGFloat) = shape == .roundedRectangle
            ? (25.5, 47.5, 60.5, 71) : (30, 56, 70, 81.5)
        let narrow: CGFloat = shape == .circle ? 1 : 21 / 23
        let codePoints = min(20, max(18, 18 + 2 * (size - 74) / 14)) * narrow
        StampFrame(shape: shape, outer: true, book: true)
            .stroke(color, style: StrokeStyle(lineWidth: 2.4 * s, lineJoin: .round))
        StampFrame(shape: shape, outer: false, book: true)
            .stroke(color, style: StrokeStyle(lineWidth: 0.9 * s, lineJoin: .round))
        Path { path in
            path.move(to: CGPoint(x: 41 * s, y: y.rule * s))
            path.addLine(to: CGPoint(x: 59 * s, y: y.rule * s))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 1.1 * s, lineCap: .round))
        bookLine(Text(verbatim: Self.alpha3(for: iso)), points: codePoints, tracking: 1, weight: .heavy, baseline: y.code)
        bookLine(topText, points: 10, tracking: 1.1, weight: .bold, baseline: y.date)
        bookLine(bottomText, points: 8, tracking: 1.3, weight: .semibold, baseline: y.year)
            .opacity(0.82)
    }

    /// One line of the book face in fixed points, its baseline on the
    /// design box's grid and its tracking in design units.
    private func bookLine(_ text: Text, points: CGFloat, tracking: CGFloat,
                          weight: Font.Weight, baseline: CGFloat) -> some View {
        let s = size / 100
        return text
            .font(.system(size: points, weight: weight).width(.expanded))
            .tracking(tracking * s)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: 84 * s)
            .position(x: 50 * s, y: baseline * s - points * 0.355)
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private func classicFace(shape: Shape, layout: (top: CGFloat, code: CGFloat, bottom: CGFloat),
                             color: Color) -> some View {
        let s = size / 100
        StampFrame(shape: shape, outer: true)
            .stroke(color, style: StrokeStyle(lineWidth: 2.6 * s, lineJoin: .round))
        StampFrame(shape: shape, outer: false)
            .stroke(color, style: StrokeStyle(lineWidth: 1 * s, lineJoin: .round))
        StampRules(topY: layout.top + 5, bottomY: layout.bottom - 10)
            .stroke(color, lineWidth: 0.8 * s)

        line(topText, size: 8.6, tracking: 1.6, weight: .bold, centerY: layout.top - 3.05)
        line(Text(verbatim: Self.alpha3(for: iso)), size: 24, tracking: 1.2, weight: .heavy,
             centerY: layout.code - 8.5)
        line(bottomText, size: 8.6, tracking: 1.6, weight: .bold, centerY: layout.bottom - 3.05)
    }

    /// One line of the stamp, its centre placed on the design's baseline grid.
    private func line(_ text: Text, size fontSize: CGFloat, tracking: CGFloat,
                      weight: Font.Weight, centerY: CGFloat) -> some View {
        let s = size / 100
        return text
            .font(.system(size: fontSize * s, weight: weight).width(.expanded))
            .tracking(tracking * s)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: 64 * s)
            .position(x: 50 * s, y: centerY * s)
            .frame(width: size, height: size)
    }

    private var topText: Text {
        guard let date else { return Text(verbatim: "") }
        let locale = AppLanguagePreference.currentLocale()
        return Text(verbatim: date.formatted(Date.FormatStyle(locale: locale).day().month(.abbreviated))
            .uppercased(with: locale)
            .replacingOccurrences(of: ".", with: ""))
    }

    private var bottomText: Text {
        guard let date else { return Text(verbatim: "") }
        return Text(verbatim: String(Calendar(identifier: .gregorian).component(.year, from: date)))
    }

    private var accessibilityText: String {
        let country = localizedCountryName(iso: iso.count == 2 ? iso : nil, fallback: Self.alpha3(for: iso)) ?? iso
        guard let date else {
            return String(localized: "passport-stamp.accessibility", defaultValue: "\(country) stamp", comment: "VoiceOver label of a passport stamp without a date; the placeholder is the country name.")
        }
        let dateText = date.formatted(Date.FormatStyle(locale: AppLanguagePreference.currentLocale()).day().month(.abbreviated).year())
        return String(localized: "passport-stamp.accessibility.dated", defaultValue: "\(country) stamp, \(dateText)", comment: "VoiceOver label of a passport stamp; the placeholders are the country name and the entry date.")
    }
}

// MARK: - Entry date

extension PassportStamp {
    /// Noon, in the device zone, on the civil day `instant` falls on in
    /// `zone`, so a stamp prints the entry's local date (the stay's own
    /// day) wherever the device is.
    nonisolated static func entryDate(_ instant: Date, in zone: TimeZone) -> Date {
        var entry = Calendar(identifier: .gregorian)
        entry.timeZone = zone
        let parts = entry.dateComponents([.year, .month, .day], from: instant)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        return local.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 12)) ?? instant
    }
}

// MARK: - Shape, ink and tilt

extension PassportStamp {
    nonisolated enum Shape {
        case circle, hexagon, roundedRectangle

        /// Baselines of the three lines in the 100 pt design box.
        var layout: (top: CGFloat, code: CGFloat, bottom: CGFloat) {
            switch self {
            case .circle: (31, 58.5, 76)
            case .hexagon: (33, 58.5, 74)
            case .roundedRectangle: (34, 58, 72)
            }
        }
    }

    /// Circle for Europe, hexagon for Asia, rounded rectangle for the rest.
    static func shape(for iso: String) -> Shape {
        let code = iso.uppercased()
        guard code.count == 2 else { return .circle }
        if europeanOverrides.contains(code) { return .circle }
        switch Locale.Region(code).continent?.identifier {
        case "150": return .circle
        case "142": return .hexagon
        case "002", "019", "009": return .roundedRectangle
        default: return .circle
        }
    }

    /// UN geography puts Cyprus in Western Asia; its passport says Europe.
    private static let europeanOverrides: Set<String> = ["CY"]

    static func alpha3(for iso: String) -> String {
        CountryAlpha3.code(for: iso)
    }

    /// The nine stamp inks, tuned for each appearance.
    enum Ink: CaseIterable {
        case petrol, oxblood, emerald, raspberry, aubergine, burnt, violet, teal, olive

        var color: Color {
            switch self {
            case .petrol: Self.dynamic(0x1B5A86, dark: 0x7DB8E8)
            case .oxblood: Self.dynamic(0x8E1B32, dark: 0xEF8E9C)
            case .emerald: Self.dynamic(0x08704D, dark: 0x5CCB9F)
            case .raspberry: Self.dynamic(0xA3184F, dark: 0xF28AB2)
            case .aubergine: Self.dynamic(0x5E2A72, dark: 0xC99BE0)
            case .burnt: Self.dynamic(0xA8430E, dark: 0xF0A06A)
            case .violet: Self.dynamic(0x4A36A8, dark: 0xAFA2F5)
            case .teal: Self.dynamic(0x0B6670, dark: 0x5EC4CC)
            case .olive: Self.dynamic(0x55611A, dark: 0xBCC878)
            }
        }

        /// The ink on the cobalt Passport: the same hue, lightness raised
        /// for the field (6.8:1 or better on the page), both appearances.
        var onField: Color {
            switch self {
            case .petrol: Color(UIColor(hex: 0x7DC6FF))
            case .oxblood: Color(UIColor(hex: 0xFF98A8))
            case .emerald: Color(UIColor(hex: 0x49DBA6))
            case .raspberry: Color(UIColor(hex: 0xFF95C0))
            case .aubergine: Color(UIColor(hex: 0xDCA4F8))
            case .burnt: Color(UIColor(hex: 0xFFA35F))
            case .violet: Color(UIColor(hex: 0xBDB0FF))
            case .teal: Color(UIColor(hex: 0x4FD3DD))
            case .olive: Color(UIColor(hex: 0xBCC966))
            }
        }

        /// An ongoing trip's stamp on the cobalt Passport.
        static let onFieldSaffron = Color(UIColor(hex: 0xFFC65A))

        private static func dynamic(_ light: UInt32, dark: UInt32) -> Color {
            Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        }
    }

    /// The country's ink: the design's assignments, then a stable hash.
    /// (The cobalt Passport inks its pages with `fieldInks(codes:ongoing:)`.)
    static func ink(for iso: String) -> Color {
        let code = alpha3(for: iso)
        if let assigned = assignedInks[code] { return assigned.color }
        return Ink.allCases[stableHash(code) % Ink.allCases.count].color
    }

    /// The country's fixed tilt in degrees, between -6 and 6 and never flat.
    static func rotation(for iso: String) -> Double {
        let code = alpha3(for: iso)
        if let assigned = assignedRotations[code] { return assigned }
        let tilts: [Double] = [-6, -5, -4, -3, 3, 4, 5, 6]
        return tilts[(stableHash(code) / 7) % tilts.count]
    }

    private static let assignedInks: [String: Ink] = [
        "GBR": .petrol, "PRT": .oxblood, "ITA": .emerald, "DNK": .raspberry, "JPN": .aubergine,
        "ESP": .burnt, "FRA": .violet, "AUT": .teal, "GRC": .olive,
    ]

    /// Inks for one Passport page on the cobalt field, in entry order; nil
    /// for an ongoing trip's stamp, which wears saffron. In the 3-column
    /// grid a stamp touches only the 4 stamps before it (left, up-right, up,
    /// up-left), so a stamp never shares an ink with those 4: a country with
    /// an assigned ink keeps it unless one of them has it; any other stamp
    /// takes the least recently used ink none of them has, preferring one
    /// no assigned country among the next 8 needs. Up to 9 stamps never
    /// repeat an ink; a longer year repeats inks only far apart.
    static func fieldInks(codes: [String], ongoing: [Bool]) -> [Ink?] {
        let order = Ink.allCases
        let alpha = codes.map(alpha3(for:))
        var result: [Ink?] = []
        var lastUsed: [Ink: Int] = [:]
        for index in alpha.indices {
            if ongoing[index] {
                result.append(nil)
                continue
            }
            let near = Set(result[max(0, index - 4)..<index].compactMap { $0 })
            let pick: Ink
            if let own = assignedInks[alpha[index]], !near.contains(own) {
                pick = own
            } else {
                let ahead = Set((index + 1..<min(alpha.count, index + 9)).compactMap { next in
                    ongoing[next] ? nil : assignedInks[alpha[next]]
                })
                let free = order.filter { !near.contains($0) }
                let preferred = free.filter { !ahead.contains($0) }
                let pool = preferred.isEmpty ? free : preferred
                func rank(_ ink: Ink) -> (Int, Int) { (lastUsed[ink] ?? -99, order.firstIndex(of: ink) ?? 0) }
                pick = pool.min { rank($0) < rank($1) } ?? order[0]
            }
            result.append(pick)
            lastUsed[pick] = index
        }
        return result
    }

    private static let assignedRotations: [String: Double] = [
        "FRA": -5, "ESP": 4, "JPN": 6, "AUT": -3, "DNK": -6, "ITA": 3, "GRC": -2, "PRT": -6, "GBR": 4,
    ]

    /// Same value on every launch and device (`hashValue` is seeded per process).
    private static func stableHash(_ code: String) -> Int {
        code.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    }
}

// MARK: - Drawing

/// The outer (2.6 pt) or inner (1 pt) outline, in the 100 pt design box
/// scaled to the frame.
private nonisolated struct StampFrame: SwiftUI.Shape {
    let shape: PassportStamp.Shape
    let outer: Bool
    /// The book face's slightly wider inner ring.
    var book = false

    func path(in rect: CGRect) -> Path {
        let s = rect.width / 100
        switch shape {
        case .circle:
            let r = (outer ? 46.6 : (book ? 41.2 : 40.6)) * s
            return Path(ellipseIn: CGRect(x: rect.midX - r, y: rect.midY - r, width: r * 2, height: r * 2))
        case .hexagon:
            let r = (outer ? (book ? 47.6 : 47.4) : (book ? 42.2 : 41)) * s
            var path = Path()
            for (index, degrees) in [-90.0, -30, 30, 90, 150, 210].enumerated() {
                let radians = degrees * .pi / 180
                let point = CGPoint(x: rect.midX + r * cos(radians), y: rect.midY + r * sin(radians))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            return path
        case .roundedRectangle:
            let size = outer ? CGSize(width: 95.4, height: 71.4) : CGSize(width: 84, height: 60)
            let box = CGRect(x: rect.midX - size.width * s / 2, y: rect.midY - size.height * s / 2,
                             width: size.width * s, height: size.height * s)
            return Path(roundedRect: box, cornerRadius: (outer ? 12 : 7.5) * s)
        }
    }
}

/// The two short rules between the date lines and the code.
private nonisolated struct StampRules: SwiftUI.Shape {
    let topY: CGFloat
    let bottomY: CGFloat

    func path(in rect: CGRect) -> Path {
        let s = rect.width / 100
        var path = Path()
        for y in [topY, bottomY] {
            path.move(to: CGPoint(x: 30 * s, y: y * s))
            path.addLine(to: CGPoint(x: 70 * s, y: y * s))
        }
        return path
    }
}

/// The saffron spark on a first visit's stamp, ringed in the card colour.
private struct StampNewBadge: View {
    let diameter: CGFloat
    let ring: Color

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: diameter * 0.6, weight: .bold))
            .foregroundStyle(AppTheme.onSaffron)
            .frame(width: diameter, height: diameter)
            .background(AppTheme.saffron, in: .circle)
            .padding(2)
            .background(ring, in: .circle)
            .shadow(color: AppTheme.saffron.opacity(0.4), radius: 5)
            .accessibilityHidden(true)
    }
}

#Preview {
    HStack(spacing: 20) {
        PassportStamp(iso: "PT", date: .now, size: 84)
        PassportStamp(iso: "JP", date: .now, size: 84)
        PassportStamp(iso: "MA", date: .now, size: 84, highlighted: true)
    }
    .padding()
}
