//
//  TripGapQuestionViews.swift
//  TravelLog
//
//  The "Did you go home?" pieces: the gap on the Stops line (a dashed rail
//  and a house mark, with the question or, once answered, a quiet note), the
//  answers' Undo toast, and the Trips list's entry and row badge.
//

import SwiftUI

extension AppTheme {
    /// The soft cobalt behind a question: the gap's card and the sheet's banner.
    static let questionFill = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(hex: 0x6E8BFF, alpha: 0.16)
            : UIColor(hex: 0x2F4BE0, alpha: 0.1)
    })
}

// MARK: - The rail

/// One piece of the Stops rail: solid cobalt, dashed where nothing was
/// recorded (4 pt on, 4 off), or clear past the line's ends.
struct TripGapRail: View {
    var clear = false
    var dashed = false

    var body: some View {
        if clear {
            Color.clear
        } else if dashed {
            RailLine()
                .stroke(AppTheme.routeLine, style: StrokeStyle(lineWidth: 4, dash: [4, 4]))
        } else {
            Rectangle().fill(AppTheme.routeLine)
        }
    }

    nonisolated private struct RailLine: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            }
        }
    }
}

/// The design's outlined house, drawn on a 24 pt grid.
struct HouseGlyph: View {
    var size: CGFloat = 13
    var color: Color = AppTheme.accent

    var body: some View {
        HouseShape()
            .stroke(color, style: StrokeStyle(lineWidth: 2 * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    nonisolated private struct HouseShape: Shape {
        func path(in rect: CGRect) -> Path {
            let s = rect.width / 24
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
            var path = Path()
            path.move(to: p(4, 11))
            path.addLine(to: p(12, 4.5))
            path.addLine(to: p(20, 11))
            path.move(to: p(6, 9.5))
            path.addLine(to: p(6, 20))
            path.addLine(to: p(18, 20))
            path.addLine(to: p(18, 9.5))
            path.move(to: p(10, 20))
            path.addLine(to: p(10, 15))
            path.addLine(to: p(14, 15))
            path.addLine(to: p(14, 20))
            return path
        }
    }
}

/// The gap's station: a 24 pt ring on the dashed rail with the house inside.
struct TripGapHouseMark: View {
    /// The surface under the ring, so the dashes stop at its edge.
    var fill: Color = AppTheme.card

    var body: some View {
        Circle()
            .fill(fill)
            .overlay(Circle().strokeBorder(AppTheme.routeLine, lineWidth: 1.5))
            .overlay(HouseGlyph(size: 13))
            .frame(width: 24, height: 24)
    }
}

/// The rail through a gap: dashes above and below the house mark, centred on the row.
struct TripGapRailColumn: View {
    var fill: Color = AppTheme.card

    var body: some View {
        VStack(spacing: 0) {
            TripGapRail(dashed: true).frame(width: 4).frame(maxHeight: .infinity)
            TripGapHouseMark(fill: fill)
            TripGapRail(dashed: true).frame(width: 4).frame(maxHeight: .infinity)
        }
        .frame(width: 18)
        .accessibilityHidden(true)
    }
}

// MARK: - The gap on the Stops line

/// The gap between two stops: the question with its two answers, or once
/// answered "No, one trip", a quiet note of how long nothing was recorded.
struct TripGapLineRow: View {
    let question: TripGapQuestion
    let answered: Bool
    /// An answer is saving: the buttons wait.
    var isBusy = false
    let onWentHome: () -> Void
    let onOneTrip: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            TripGapRailColumn()

            Group {
                if answered {
                    Text(question.lengthText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.top, 9)
                        .padding(.bottom, 11)
                } else {
                    questionCard
                        .padding(.top, 19)
                        .padding(.bottom, 23)
                }
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(.separator))
                    .frame(height: 0.5)
            }
        }
    }

    private var questionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(question.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(question.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            TripGapAnswerButtons(isBusy: isBusy, large: false, onWentHome: onWentHome, onOneTrip: onOneTrip)
                .padding(.top, 12)
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.questionFill, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .contain)
    }
}

/// "Yes, I went home" in cobalt and "No, one trip" on the neutral fill:
/// side by side on the Stops line (stacked when a language or text size
/// needs the room), stacked and larger in the sheet.
struct TripGapAnswerButtons: View {
    var isBusy = false
    /// The sheet's 50 pt stacked buttons.
    var large = false
    let onWentHome: () -> Void
    let onOneTrip: () -> Void

    var body: some View {
        Group {
            if large {
                VStack(spacing: 10) { buttons }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { buttons }
                    VStack(spacing: 8) { buttons }
                }
            }
        }
        .disabled(isBusy)
    }

    @ViewBuilder
    private var buttons: some View {
        Button(action: onWentHome) {
            label(TripGapQuestion.wentHomeTitle, primary: true)
        }
        .buttonStyle(.plain)
        Button(action: onOneTrip) {
            label(TripGapQuestion.oneTripTitle, primary: false)
        }
        .buttonStyle(.plain)
    }

    private func label(_ title: String, primary: Bool) -> some View {
        Text(title)
            .font(large ? .body.weight(.semibold) : .subheadline.weight(.semibold))
            .foregroundStyle(primary ? Color.white : Color.primary)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: !large, vertical: true)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: large ? 50 : 44)
            .background(primary ? AnyShapeStyle(AppTheme.cobaltFill) : AnyShapeStyle(AppTheme.inset), in: .capsule)
            .contentShape(.capsule)
    }
}

// MARK: - Undo

/// The answer's confirmation over the tab bar: a check, what happened, and Undo.
struct TripGapToast: View {
    let text: String
    var isBusy = false
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(TripGapActions.undoTitle, action: onUndo)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .contentShape(.rect)
                .disabled(isBusy)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(minHeight: 50)
        .glassEffect(in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text(TripGapActions.undoTitle)) { onUndo() }
    }
}

// MARK: - Trips list

/// "2 questions about your trips": the Trips list's way into the questions
/// sheet, under the filters, with the first question as its subtitle.
struct TripGapQuestionsEntry: View {
    let count: Int
    let firstTitle: String?

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.cobaltFill)
                .frame(width: 30, height: 30)
                .overlay(HouseGlyph(size: 17, color: .white))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(count))
                    .font(.headline)
                if let firstTitle {
                    Text(firstTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 1)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    static func title(_ count: Int) -> String {
        count == 1
            ? String(localized: "trip-gap.entry.title.one", defaultValue: "\(count, format: .number.grouping(.never)) question about your trips", comment: "Trips list entry that opens the did-you-go-home questions: one question.")
            : String(localized: "trip-gap.entry.title.other", defaultValue: "\(count, format: .number.grouping(.never)) questions about your trips", comment: "Trips list entry that opens the did-you-go-home questions: several questions.")
    }
}

/// "1 question" on a trip row that asks one.
struct TripGapBadge: View {
    let count: Int

    var body: some View {
        AppChip(label: Text(Self.text(count)), small: true)
    }

    static func text(_ count: Int) -> String {
        count == 1
            ? String(localized: "trip-gap.badge.one", defaultValue: "\(count, format: .number.grouping(.never)) question", comment: "Badge on a Trips list row whose trip asks one did-you-go-home question.")
            : String(localized: "trip-gap.badge.other", defaultValue: "\(count, format: .number.grouping(.never)) questions", comment: "Badge on a Trips list row whose trip asks several did-you-go-home questions.")
    }
}
