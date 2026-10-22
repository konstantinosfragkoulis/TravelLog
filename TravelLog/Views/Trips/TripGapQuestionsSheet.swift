//
//  TripGapQuestionsSheet.swift
//  TravelLog
//
//  The Trips list's questions sheet: every "Did you go home?" question, one
//  at a time across trips, each with its trip and the stops around its gap.
//  "Yes" shows the two trips it made, with Undo Split; "No" moves on under a
//  banner that offers Undo.
//

import SwiftData
import SwiftUI

struct TripGapQuestionsSheet: View {
    /// The list's questions, oldest gap first. A later load adds new ones;
    /// each is checked against its trip before it is asked.
    let listed: [TripGapQuestionIndex.Listed]
    /// Opens a trip's page: the list dismisses the sheet, then pushes it.
    let onOpenTrip: (Trip) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    enum Phase: Equatable {
        case asking
        /// "Yes" split the trip; Next Question moves on.
        case split(question: TripGapQuestion, earlier: TripGapActions.TripRef, later: TripGapActions.TripRef)
    }

    /// The live question on screen and the trip that asks it now.
    struct Current {
        let question: TripGapQuestion
        let trip: Trip
    }

    /// The last "No", while its banner offers Undo.
    struct Kept: Equatable {
        let question: TripGapQuestion
        let tripName: String
    }

    /// Every question this sheet has met, in asking order; those before
    /// `position` are answered.
    @State private var session: [TripGapQuestion] = []
    @State private var position = 0
    @State private var phase = Phase.asking
    @State private var current: Current?
    @State private var kept: Kept?
    @State private var isBusy = false
    @State private var saveFailed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let kept {
                keptBanner(kept)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ScrollView {
                content
                    .padding(.horizontal, 24)
                    .padding(.top, kept == nil ? 6 : 14)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppTheme.card)
        .presentationCornerRadius(38)
        .onAppear { refresh() }
        .onChange(of: listed) { _, _ in refresh() }
        // Sync or reassembly can take a question away (or change its trip) while it shows.
        .onChange(of: StoreChangeTracker.shared.token(for: [.trip, .stay])) { _, _ in refresh() }
        .alert(
            String(
                localized: "common.save-error.try-again",
                defaultValue: "Couldn't save. Try again",
                comment: "Shared alert title after a user-authoritative save fails."
            ),
            isPresented: $saveFailed
        ) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack {
            Color.clear.frame(width: 44, height: 1)
            Spacer(minLength: 0)
            if current != nil || phase != .asking {
                Text(Self.counterText(position + 1, of: session.count))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.inset, in: .circle)
            }
            .buttonStyle(.plain)
            .frame(width: 44, height: 44)
            .accessibilityLabel(String(
                localized: "trip-gap.sheet.close", defaultValue: "Close",
                comment: "VoiceOver label of the button that closes the did-you-go-home questions sheet."))
        }
        .frame(height: 44)
        .padding(.horizontal, 10)
        .padding(.top, 18)
    }

    @ViewBuilder
    private var footer: some View {
        switch phase {
        case .asking:
            if let current {
                VStack(spacing: 14) {
                    Text(current.question.answersNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                    TripGapAnswerButtons(
                        isBusy: isBusy, large: true,
                        onWentHome: { answerWentHome(current) },
                        onOneTrip: { answerOneTrip(current) })
                }
            } else {
                primaryButton(Self.doneTitle) { dismiss() }
            }
        case .split:
            primaryButton(position + 1 < session.count ? Self.nextTitle : Self.doneTitle) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    position += 1
                    phase = .asking
                    refresh()
                }
            }
            .disabled(isBusy)
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(AppTheme.cobaltFill, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .asking:
            if let current {
                asking(current)
            } else {
                finished
            }
        case .split(_, let earlier, let later):
            splitResult(earlier: earlier, later: later)
        }
    }

    private func asking(_ current: Current) -> some View {
        let question = current.question
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                SmallFlagDeck(codes: current.trip.countryCodeList)
                VStack(alignment: .leading, spacing: 0) {
                    Text(current.trip.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if current.trip.endDate != nil {
                        Text(TripDisplayText.tripDates(current.trip, includeYear: true))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)

            Text(question.title)
                .font(.title.bold())
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, kept == nil ? 20 : 14)
                .accessibilityAddTraits(.isHeader)
            Text(question.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, kept == nil ? 8 : 6)

            TripGapMiniLine(question: question, trip: current.trip)
                .padding(.top, kept == nil ? 20 : 14)
        }
        .id(question.id)
        .transition(.opacity)
    }

    private func splitResult(earlier: TripGapActions.TripRef, later: TripGapActions.TripRef) -> some View {
        let trips = [earlier, later].compactMap { TripGapActions.registeredTrip($0, in: modelContext) }
        return VStack(alignment: .leading, spacing: 0) {
            doneMark
                .padding(.top, 18)
            Text(TripGapActions.splitDoneText)
                .font(.title.bold())
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            Text(String(
                localized: "trip-gap.split.detail",
                defaultValue: "Each trip gets its own page, title and stamps.",
                comment: "Line under Split into 2 trips in the questions sheet, after the user answered Yes."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            VStack(spacing: 0) {
                ForEach(Array(trips.enumerated()), id: \.element.persistentModelID) { index, trip in
                    Button {
                        onOpenTrip(trip)
                    } label: {
                        SplitTripRow(trip: trip)
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle().fill(Color(.separator)).frame(height: 0.5).padding(.leading, 53)
                        }
                    }
                }
            }
            .background(AppTheme.inset, in: .rect(cornerRadius: 16))
            .padding(.top, 18)

            Button {
                undoSplit()
            } label: {
                Text(String(
                    localized: "trip-gap.sheet.undo-split", defaultValue: "Undo Split",
                    comment: "Button in the questions sheet that merges the two trips a Yes answer made back into one."))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .padding(.top, 14)
        }
        .transition(.opacity)
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 0) {
            doneMark
                .padding(.top, 18)
            Text(String(
                localized: "trip-gap.sheet.finished", defaultValue: "No more questions",
                comment: "Questions sheet title once every did-you-go-home question is answered."))
                .font(.title.bold())
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
        }
        .transition(.opacity)
    }

    private var doneMark: some View {
        Circle()
            .fill(AppTheme.cobaltFill)
            .frame(width: 56, height: 56)
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white))
            .accessibilityHidden(true)
    }

    private func keptBanner(_ kept: Kept) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(AppTheme.accent)
                .accessibilityHidden(true)
            Text(TripGapActions.keptTripText(kept.tripName))
                .font(.subheadline.weight(.medium))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                undoKept(kept)
            } label: {
                Text(TripGapActions.undoTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .frame(minHeight: 44)
        .background(AppTheme.questionFill, in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text(TripGapActions.undoTitle)) { undoKept(kept) }
    }

    // MARK: - Answers

    private func answerWentHome(_ current: Current) {
        guard !isBusy else { return }
        let earlier = TripGapActions.TripRef(current.trip)
        isBusy = true
        Task {
            let outcome = await TripGapActions.split(current.question, in: current.trip)
            isBusy = false
            switch outcome {
            case .split(let later):
                withAnimation(.easeInOut(duration: 0.25)) {
                    kept = nil
                    phase = .split(question: current.question, earlier: earlier, later: later)
                }
                TripGapActions.announce(TripGapActions.splitDoneText)
            case .stale:
                withAnimation { refresh() }
            case .failed:
                saveFailed = true
            }
        }
    }

    private func answerOneTrip(_ current: Current) {
        guard !isBusy else { return }
        TripGapActions.keep(current.question)
        let banner = Kept(question: current.question, tripName: current.trip.displayName)
        withAnimation(.easeInOut(duration: 0.25)) {
            kept = banner
            position += 1
            refresh()
        }
        TripGapActions.announce(TripGapActions.keptTripText(banner.tripName))
    }

    /// The banner's Undo: the question asks again, back in its place.
    private func undoKept(_ kept: Kept) {
        guard !isBusy else { return }
        TripGapActions.undoKeep(kept.question)
        withAnimation(.easeInOut(duration: 0.25)) {
            if let index = session.firstIndex(where: { $0.id == kept.question.id }) {
                position = index
            } else {
                session.insert(kept.question, at: position)
            }
            self.kept = nil
            phase = .asking
            refresh()
        }
        TripGapActions.announce(TripGapActions.undoneText)
    }

    private func undoSplit() {
        guard case let .split(question, earlier, later) = phase, !isBusy else { return }
        isBusy = true
        Task {
            let rejoined = await TripGapActions.undoSplit(question, earlier: earlier, later: later)
            isBusy = false
            guard rejoined else {
                saveFailed = true
                return
            }
            withAnimation(.easeInOut(duration: 0.25)) {
                phase = .asking
                refresh()
            }
            TripGapActions.announce(TripGapActions.undoneText)
        }
    }

    // MARK: - Session

    /// Adopts questions the list found since, then checks every unanswered
    /// one against its trip as it is now: a question sync or reassembly took
    /// away leaves the session, one whose trip changed is asked with its
    /// trip as it is. The current question follows.
    private func refresh() {
        let known = Set(session.map(\.id))
        session += listed.map(\.question).filter { !known.contains($0.id) }
        guard phase == .asking else { return }
        var index = position
        var first: Current?
        while index < session.count {
            if let live = Self.live(session[index], in: modelContext) {
                session[index] = live.question
                if first == nil { first = live }
                index += 1
            } else {
                session.remove(at: index)
            }
        }
        position = min(position, session.count)
        current = first
    }

    /// The question as its later stay's trip asks it now, or nil once it
    /// asks no more. The later stay is the anchor, so a question found under
    /// a trip a split or reassembly made is still found.
    static func live(_ question: TripGapQuestion, in context: ModelContext) -> Current? {
        let laterID = question.laterStayID
        guard let stays = try? context.fetch(FetchDescriptor<Stay>(predicate: #Predicate { $0.id == laterID }))
        else { return nil }
        for stay in stays where !stay.isDeleted {
            guard let trip = stay.trip, !trip.isDeleted,
                  let match = TripGapQuestion.questions(for: trip).first(where: { $0.id == question.id })
            else { continue }
            return Current(question: match, trip: trip)
        }
        return nil
    }

    // MARK: - Copy

    static func counterText(_ number: Int, of total: Int) -> String {
        String(localized: "trip-gap.sheet.counter",
               defaultValue: "\(number, format: .number.grouping(.never)) of \(total, format: .number.grouping(.never))",
               comment: "Questions sheet header: which did-you-go-home question this is, of how many, e.g. 1 of 2.")
    }

    static var nextTitle: String {
        String(localized: "trip-gap.sheet.next", defaultValue: "Next Question",
               comment: "Questions sheet button after a Yes answer: shows the next did-you-go-home question.")
    }

    static var doneTitle: String {
        String(localized: "trip-gap.sheet.done", defaultValue: "Done",
               comment: "Questions sheet button once no did-you-go-home question is left: closes the sheet.")
    }
}

// MARK: - Pieces

/// The questions sheet's trip mark: the trip's flags at the row size,
/// fanned as the list's deck fans them.
private struct SmallFlagDeck: View {
    let codes: [String]

    var body: some View {
        let shown: [String?] = codes.isEmpty ? [nil] : codes.prefix(2).map { $0 }
        let step = CGPoint(x: 9, y: 8)
        let size = FlagView.Size.regular.dimensions
        ZStack(alignment: .topLeading) {
            ForEach(Array(shown.enumerated()).reversed(), id: \.offset) { index, code in
                FlagView(iso: code, size: .regular)
                    .shadow(color: index == 0 && shown.count > 1 ? .black.opacity(0.35) : .clear, radius: 1.5, y: 1)
                    .padding(.leading, CGFloat(index) * step.x)
                    .padding(.top, CGFloat(index) * step.y)
            }
        }
        .frame(width: 42, height: size.height + CGFloat(shown.count - 1) * step.y, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// One of the two trips a "Yes" made: its flag, name, dates and length.
private struct SplitTripRow: View {
    let trip: Trip

    var body: some View {
        HStack(spacing: 12) {
            FlagView(iso: trip.countryCodeList.first, size: .regular)
                .frame(width: 27)
            VStack(alignment: .leading, spacing: 1) {
                Text(trip.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Text(meta)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        let dates = TripDisplayText.tripDates(trip, includeYear: true)
        guard let days = trip.durationDays else { return dates }
        return "\(dates) · \(TripRowText.days(days))"
    }
}

/// The stops around a gap, as the trip page's line draws them: the stop
/// before it (and the place that names that side, when another), the gap
/// with its length, then the stop after it (and the place that names it).
struct TripGapMiniLine: View {
    let question: TripGapQuestion
    let trip: Trip

    var body: some View {
        let ordered = trip.orderedStays.filter { !$0.isDeleted }
        let byID = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let before = Self.stops([question.earlierPlaceStayID, question.earlierStayID], in: byID)
        let after = Self.stops([question.laterStayID, question.laterPlaceStayID], in: byID)
        VStack(spacing: 0) {
            ForEach(Array(before.enumerated()), id: \.element.persistentModelID) { index, stay in
                MiniStop(stay: stay, showsSeparator: index > 0, dashedBelow: index == before.count - 1)
            }
            HStack(alignment: .top, spacing: 14) {
                TripGapRailColumn(fill: AppTheme.inset)
                Text(question.lengthText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .overlay(alignment: .top) {
                        if !before.isEmpty {
                            Rectangle().fill(Color(.separator)).frame(height: 0.5)
                        }
                    }
            }
            ForEach(Array(after.enumerated()), id: \.element.persistentModelID) { index, stay in
                MiniStop(stay: stay, showsSeparator: true, dashedAbove: index == 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(AppTheme.inset, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    /// The listed stays this trip still holds, once each, in order.
    private static func stops(_ ids: [UUID?], in byID: [UUID: Stay]) -> [Stay] {
        var seen = Set<UUID>()
        return ids.compactMap { id in
            guard let id, seen.insert(id).inserted else { return nil }
            return byID[id]
        }
    }

    /// A stop on the mini line: the trip page's station sizes, its name and caption.
    private struct MiniStop: View {
        let stay: Stay
        var showsSeparator = true
        var dashedAbove = false
        var dashedBelow = false

        var body: some View {
            let isDestination = stay.category == .destination
            let isVisit = isDestination && TimelineStop.isDayTrip(stay)
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 0) {
                    TripGapRail(dashed: dashedAbove).frame(width: 4, height: 16)
                    let size: CGFloat = !isDestination ? 10 : (isVisit ? 12 : 18)
                    let stroke: CGFloat = !isDestination ? 2.5 : (isVisit ? 3 : 4)
                    Circle()
                        .fill(AppTheme.card)
                        .overlay(Circle().strokeBorder(AppTheme.routeLine, lineWidth: stroke))
                        .frame(width: size, height: size)
                        .shadow(color: isDestination ? AppTheme.accentGlow : .clear, radius: 5)
                        .frame(width: 18, height: 14)
                        .zIndex(1)
                    TripGapRail(dashed: dashedBelow).frame(width: 4).frame(maxHeight: .infinity)
                }
                .frame(width: 18)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 0) {
                    Text(stay.locality ?? String(localized: "trip-detail.place.unknown", defaultValue: "Unknown", comment: "Fallback place name in trip details."))
                        .font(isDestination ? .headline : .subheadline)
                        .foregroundStyle(isDestination ? .primary : .secondary)
                    Text(verbatim: TripDisplayText.stopCaption(stay))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 9)
                .padding(.bottom, 11)
                .overlay(alignment: .top) {
                    if showsSeparator {
                        Rectangle().fill(Color(.separator)).frame(height: 0.5)
                    }
                }
            }
        }
    }
}
