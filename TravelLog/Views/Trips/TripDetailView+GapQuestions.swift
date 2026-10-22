//
//  TripDetailView+GapQuestions.swift
//  TravelLog
//
//  The "Did you go home?" answers. "Yes" is the existing Split Trip Here at
//  the gap's later stay; "No" records the gap as one trip on this device.
//  Both offer Undo: a split merges back, a "No" is forgotten.
//

import SwiftData
import SwiftUI
import UIKit
import WidgetKit

/// The last answer on the trip page, while its Undo toast shows.
struct TripGapAnswerToast: Equatable {
    enum Kind: Equatable {
        case split(earlier: TripGapActions.TripRef, later: TripGapActions.TripRef)
        case kept
    }

    let question: TripGapQuestion
    let kind: Kind
    /// A fresh token per answer restarts the toast's timer.
    let token = UUID()

    var text: String {
        switch kind {
        case .split: TripGapActions.splitDoneText
        case .kept: TripGapActions.keptDoneText
        }
    }
}

extension TripDetailView {

    /// Every gap the Stops line marks: the unanswered questions and the
    /// gaps answered "No, one trip", in trip order. Reads the answers'
    /// revision, so an answer or an Undo redraws the line.
    var stopGaps: [(question: TripGapQuestion, answered: Bool)] {
        _ = TripGapAnswersRevision.shared.value
        return TripGapQuestion.gaps(for: trip)
    }

    /// "Yes, I went home": splits the trip at the gap's later stay, so both
    /// halves become the user's own edit. The page keeps the earlier half
    /// and lists the later one under the Stops.
    func answerGapQuestionWentHome(_ question: TripGapQuestion) {
        guard !isAnsweringGap, !trip.isDeleted else { return }
        let earlier = TripGapActions.TripRef(trip)
        isAnsweringGap = true
        Task {
            let outcome = await TripGapActions.split(question, in: trip)
            isAnsweringGap = false
            switch outcome {
            case .split(let later):
                withAnimation(.easeInOut(duration: 0.3)) {
                    splitOffTrip = later
                    gapAnswerToast = TripGapAnswerToast(question: question, kind: .split(earlier: earlier, later: later))
                }
                TripGapActions.announce(TripGapActions.splitDoneText)
                // The later stays moved; their photos leave this gallery.
                await loadPhotos()
            case .stale:
                // The trip changed under the question; the page already shows it as it is.
                break
            case .failed:
                saveFailed = true
            }
        }
    }

    /// "No, one trip": the gap is never asked again on this device.
    func answerGapQuestionOneTrip(_ question: TripGapQuestion) {
        guard !isAnsweringGap else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            TripGapActions.keep(question)
            gapAnswerToast = TripGapAnswerToast(question: question, kind: .kept)
        }
        TripGapActions.announce(TripGapActions.keptDoneText)
    }

    /// The toast's Undo: a split merges the later half back into this trip
    /// and the question asks again; a "No" is forgotten.
    func undoGapAnswer() {
        guard let toast = gapAnswerToast, !isAnsweringGap else { return }
        switch toast.kind {
        case .kept:
            withAnimation(.easeInOut(duration: 0.3)) {
                TripGapActions.undoKeep(toast.question)
                gapAnswerToast = nil
            }
            TripGapActions.announce(TripGapActions.undoneText)
        case .split(let earlier, let later):
            isAnsweringGap = true
            Task {
                let rejoined = await TripGapActions.undoSplit(toast.question, earlier: earlier, later: later)
                isAnsweringGap = false
                guard rejoined else {
                    saveFailed = true
                    return
                }
                withAnimation(.easeInOut(duration: 0.3)) {
                    if splitOffTrip == later { splitOffTrip = nil }
                    if gapAnswerToast?.token == toast.token { gapAnswerToast = nil }
                }
                TripGapActions.announce(TripGapActions.undoneText)
                await loadPhotos()
            }
        }
    }

    /// The later half the last "Yes" split off, while it is still a trip.
    var liveSplitOffTrip: Trip? {
        guard let ref = splitOffTrip else { return nil }
        return TripGapActions.registeredTrip(ref, in: modelContext)
    }

    /// The stay a "Yes" splits at: the question's later stay, while it is
    /// still a later stop of this trip with the earlier stay before it. Nil
    /// when the trip changed since the question was asked.
    static func gapSplitStay(for question: TripGapQuestion, in trip: Trip) -> Stay? {
        guard !trip.isDeleted, trip.id == question.tripID else { return nil }
        let ordered = trip.orderedStays
        guard let index = ordered.firstIndex(where: { !$0.isDeleted && $0.id == question.laterStayID }),
              index > 0,
              ordered[..<index].contains(where: { !$0.isDeleted && $0.id == question.earlierStayID })
        else { return nil }
        return ordered[index]
    }
}

/// The answers the trip page and the questions sheet share, and their Undo.
@MainActor
enum TripGapActions {

    /// A trip row's physical identity, which a UUID twin never stands in for.
    struct TripRef: Hashable, Sendable {
        let id: UUID
        let identifier: PersistentIdentifier

        init(id: UUID, identifier: PersistentIdentifier) {
            self.id = id
            self.identifier = identifier
        }

        init(_ trip: Trip) {
            self.init(id: trip.id, identifier: trip.persistentModelID)
        }
    }

    enum SplitOutcome: Equatable {
        case split(later: TripRef)
        /// The question no longer applies: answered elsewhere, or the trip changed.
        case stale
        case failed
    }

    /// "Yes, I went home" through the gate, as Split Trip Here does it.
    static func split(_ question: TripGapQuestion, in trip: Trip) async -> SplitOutcome {
        guard !trip.isDeleted,
              TripGapQuestion.questions(for: trip).contains(where: { $0.id == question.id }),
              let stay = TripDetailView.gapSplitStay(for: question, in: trip) else { return .stale }
        // The user has split a trip: the Split Trip tip has nothing to teach.
        UserDefaults.standard.set(true, forKey: TripSplitHint.dismissedKey)
        let tripID = trip.id
        let tripIdentifier = trip.persistentModelID
        let stayID = stay.id
        let stayIdentifier = stay.persistentModelID
        let later = await PipelineGate.shared.runReturning(touching: [.trip, .stay, .hiddenPhoto]) {
            await TripDetailView.applySplitReturningLaterHalf(
                tripID: tripID, tripIdentifier: tripIdentifier,
                splitStayID: stayID, splitStayIdentifier: stayIdentifier)
        }
        return later.map { .split(later: $0) } ?? .failed
    }

    /// Undo of a "Yes": merges the later half back into the earlier one
    /// through the gate, then forgets the seam the merge recorded, so the
    /// question asks again. The rejoined trip keeps the user-edited mark and
    /// gets a fresh title, as any merge does.
    static func undoSplit(_ question: TripGapQuestion, earlier: TripRef, later: TripRef) async -> Bool {
        let rejoined = await PipelineGate.shared.runReturning(touching: [.trip, .stay, .hiddenPhoto, .pinnedPhoto]) {
            await rejoinHalves(question, earlier: earlier, later: later)
        }
        guard rejoined else { return false }
        TripsListView.carryFavouriteAfterMerge(sourceID: later.id, targetID: earlier.id)
        WidgetCenter.shared.reloadAllTimelines()
        return true
    }

    /// `undoSplit`'s store work, inside the caller's gate unit.
    static func rejoinHalves(
        _ question: TripGapQuestion, earlier: TripRef, later: TripRef,
        container: ModelContainer = AppDelegate.modelContainer,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard TripsListView.mergeTrips(
            sourceID: later.id, sourceIdentifier: later.identifier,
            targetID: earlier.id, targetIdentifier: earlier.identifier,
            container: container, gapAnswers: defaults) else { return false }
        TripGapAnswers.unconfirm([question.id], defaults: defaults)
        return true
    }

    /// "No, one trip".
    static func keep(_ question: TripGapQuestion, defaults: UserDefaults = .standard) {
        TripGapAnswers.confirmOneTrip(question, defaults: defaults)
    }

    /// Undo of a "No": the gap asks again.
    static func undoKeep(_ question: TripGapQuestion, defaults: UserDefaults = .standard) {
        TripGapAnswers.unconfirm([question.id], defaults: defaults)
    }

    /// The trip row `ref` names, when this context holds it and it is live.
    /// No fetch: a body may call it.
    static func registeredTrip(_ ref: TripRef, in context: ModelContext) -> Trip? {
        guard let trip: Trip = context.registeredModel(for: ref.identifier),
              !trip.isDeleted, trip.id == ref.id else { return nil }
        return trip
    }

    static func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    /// How long an answer's Undo stays offered: longer while VoiceOver
    /// reads, so the user can reach it.
    static var undoWindow: Duration {
        UIAccessibility.isVoiceOverRunning ? .seconds(15) : .seconds(6)
    }

    // MARK: - Copy

    static var splitDoneText: String {
        String(localized: "trip-gap.split.done", defaultValue: "Split into 2 trips",
               comment: "Confirmation after the user answered Yes to the did-you-go-home question and the trip was split in two.")
    }

    static var keptDoneText: String {
        String(localized: "trip-gap.kept.done", defaultValue: "Kept as one trip",
               comment: "Confirmation after the user answered No to the did-you-go-home question.")
    }

    static var undoTitle: String {
        String(localized: "trip-gap.undo", defaultValue: "Undo",
               comment: "Button that undoes the last did-you-go-home answer.")
    }

    static var undoneText: String {
        String(localized: "trip-gap.undo.done", defaultValue: "Undone. The question is back.",
               comment: "VoiceOver announcement after the user undid a did-you-go-home answer.")
    }

    static func keptTripText(_ tripName: String) -> String {
        String(localized: "trip-gap.kept.trip", defaultValue: "Kept \(tripName) as one trip.",
               comment: "Banner in the questions sheet after the user answered No. The placeholder is the trip's name.")
    }
}
