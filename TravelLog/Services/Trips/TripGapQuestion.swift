//
//  TripGapQuestion.swift
//  TravelLog
//

import Foundation
import Observation
import SwiftData

/// A gap inside one trip that `TripGapJudge` calls `.unsure`: home was
/// reachable but not clearly on the way, so only the user knows whether they
/// went home. Assembly keeps such a trip whole; the question lets the user
/// split it ("Yes, I went home") or confirm it ("No, one trip").
///
/// Dates alone are unanswerable from memory, so the question names the places
/// on either side and the dates come second.
nonisolated struct TripGapQuestion: Equatable, Sendable, Identifiable {
    let tripID: UUID
    let earlierStayID: UUID
    let laterStayID: UUID
    /// When the earlier stay ended and the later one began.
    let gapStart: Date
    let gapEnd: Date
    /// Each side's place: the longest named stay of its run (see `questions`);
    /// nil when no stay of the run has a name yet.
    let earlierPlace: String?
    let laterPlace: String?
    /// The stays that named each side, so a view can show them beside the gap.
    let earlierPlaceStayID: UUID?
    let laterPlaceStayID: UUID?

    var id: String { TripGapAnswers.key(earlier: earlierStayID, later: laterStayID) }

    /// One stay as the question reads it. Value inputs only: no @Model access.
    nonisolated struct StaySignal: Sendable {
        let id: UUID
        let category: StayCategory
        let startTime: Date
        let endTime: Date
        let latitude: Double
        let longitude: Double
        /// The distance assembly stamped, from the trip's departure home.
        let distanceFromHomeKm: Double
        let locality: String?
        let region: String?
        let country: String?
    }

    /// One question per `.unsure` gap between consecutive away stays, in trip
    /// order, leaving out the gaps in `confirmed` (`TripGapAnswers` keys).
    /// A home or routine member between two away stays is home evidence, so
    /// no question spans it. Each side is read the way assembly judged it: the
    /// earlier stay's end and the later stay's start, with the stamped distance.
    ///
    /// Each side is named by the longest named stay of its run: the stays from
    /// the trip start, a home member or the previous unsure gap up to the gap,
    /// and from the gap to the next one or the trip end. A ferry port or an
    /// airport next to the gap never names a side.
    static func questions(
        tripID: UUID, stays: [StaySignal], confirmed: Set<String> = []
    ) -> [TripGapQuestion] {
        // Away stays in segments that home evidence separates.
        var segments: [[StaySignal]] = [[]]
        for stay in stays.sorted(by: { $0.startTime < $1.startTime }) {
            switch stay.category {
            case .home, .routine:
                if !(segments.last?.isEmpty ?? true) { segments.append([]) }
            case .unclassified:
                continue
            case .destination, .transit:
                segments[segments.count - 1].append(stay)
            }
        }
        var result: [TripGapQuestion] = []
        for segment in segments where segment.count > 1 {
            // Every unsure gap, answered or not, bounds a run, so a side's name
            // does not change when another gap is answered.
            let unsure = segment.indices.dropFirst().filter { index in
                let earlier = segment[index - 1], later = segment[index]
                guard earlier.endTime < later.startTime else { return false }
                return TripGapJudge.verdict(
                    after: TripGapJudge.Side(
                        latitude: earlier.latitude, longitude: earlier.longitude,
                        distanceFromHomeKm: earlier.distanceFromHomeKm, time: earlier.endTime),
                    before: TripGapJudge.Side(
                        latitude: later.latitude, longitude: later.longitude,
                        distanceFromHomeKm: later.distanceFromHomeKm, time: later.startTime)
                ) == .unsure
            }
            let bounds = [segment.startIndex] + unsure + [segment.endIndex]
            for (offset, index) in unsure.enumerated() {
                let earlier = segment[index - 1], later = segment[index]
                guard !confirmed.contains(TripGapAnswers.key(earlier: earlier.id, later: later.id))
                else { continue }
                let before = runName(segment[bounds[offset]..<index], nearestLast: true)
                let after = runName(segment[index..<bounds[offset + 2]], nearestLast: false)
                result.append(TripGapQuestion(
                    tripID: tripID, earlierStayID: earlier.id, laterStayID: later.id,
                    gapStart: earlier.endTime, gapEnd: later.startTime,
                    earlierPlace: before?.name, laterPlace: after?.name,
                    earlierPlaceStayID: before?.id, laterPlaceStayID: after?.id))
            }
        }
        return result
    }

    /// A run's longest named stay and its name; a tie goes to the stay
    /// nearer the gap.
    private static func runName(
        _ run: ArraySlice<StaySignal>, nearestLast: Bool
    ) -> (name: String, id: UUID)? {
        let ordered = nearestLast ? Array(run.reversed()) : Array(run)
        var best: (name: String, id: UUID, duration: TimeInterval)?
        for stay in ordered {
            guard let name = placeName(locality: stay.locality, region: stay.region,
                                       country: stay.country) else { continue }
            let duration = stay.endTime.timeIntervalSince(stay.startTime)
            if best == nil || duration > best!.duration { best = (name, stay.id, duration) }
        }
        return best.map { ($0.name, $0.id) }
    }

    /// A stay's name as the stops show it: its locality, else its region,
    /// else its country. Blank names count as missing.
    static func placeName(locality: String?, region: String?, country: String?) -> String? {
        [locality, region, country].lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    // MARK: - Copy

    var title: String {
        let earlier = earlierPlace ?? Self.unknownPlace
        let later = laterPlace ?? Self.unknownPlace
        return String(
            localized: "trip-gap.question.title",
            defaultValue: "Did you go home between \(earlier) and \(later)?",
            comment: "Question on a trip whose stops have a gap with nothing recorded. The placeholders are the place before the gap and the place after it.")
    }

    /// The question's secondary line: each side's place with its day, the
    /// year once at the end ("After A on Sat 3 Aug, before B on Mon 5 Aug 2024").
    var detail: String {
        let earlier = earlierPlace ?? Self.unknownPlace
        let later = laterPlace ?? Self.unknownPlace
        let calendar = Calendar.current
        let day = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
        let endText = gapEnd.formatted(day.year())
        if calendar.isDate(gapStart, inSameDayAs: gapEnd) {
            return String(
                localized: "trip-gap.question.detail.same-day",
                defaultValue: "After \(earlier), before \(later) on \(endText)",
                comment: "Secondary line under the did-you-go-home question when the gap starts and ends on one day. The placeholders are the place before the gap, the place after it and the day, e.g. Mon 5 Aug 2024.")
        }
        let sameYear = calendar.component(.year, from: gapStart) == calendar.component(.year, from: gapEnd)
        let startText = gapStart.formatted(sameYear ? day : day.year())
        return String(
            localized: "trip-gap.question.detail.between",
            defaultValue: "After \(earlier) on \(startText), before \(later) on \(endText)",
            comment: "Secondary line under the did-you-go-home question. The placeholders are the place before the gap, the day it was left (e.g. Sat 3 Aug), the place after the gap and the day it was reached (e.g. Mon 5 Aug 2024).")
    }

    /// The gap's length on the Stops line: "2 days with no locations", or
    /// under a day "14 hours with no locations".
    var lengthText: String { Self.lengthText(from: gapStart, to: gapEnd) }

    static func lengthText(from start: Date, to end: Date, calendar: Calendar = .current) -> String {
        let interval = end.timeIntervalSince(start)
        if interval < 86_400 {
            let hours = max(1, Int((interval / 3600).rounded()))
            return hours == 1
                ? String(localized: "trip-gap.length.hours.one", defaultValue: "\(hours, format: .number.grouping(.never)) hour with no locations", comment: "Note in a trip's gap with nothing recorded, shorter than a day: one hour.")
                : String(localized: "trip-gap.length.hours.other", defaultValue: "\(hours, format: .number.grouping(.never)) hours with no locations", comment: "Note in a trip's gap with nothing recorded, shorter than a day: several hours.")
        }
        let days = max(1, calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 1)
        return days == 1
            ? String(localized: "trip-gap.length.days.one", defaultValue: "\(days, format: .number.grouping(.never)) day with no locations", comment: "Note in a trip's gap with nothing recorded: one day.")
            : String(localized: "trip-gap.length.days.other", defaultValue: "\(days, format: .number.grouping(.never)) days with no locations", comment: "Note in a trip's gap with nothing recorded: several days.")
    }

    /// What each answer does, under the question in the questions sheet.
    var answersNote: String {
        let later = laterPlace ?? Self.unknownPlace
        return String(
            localized: "trip-gap.question.answers-note",
            defaultValue: "Yes makes \(later) its own trip. No keeps one trip and never asks about this again.",
            comment: "Note above the did-you-go-home answers in the questions sheet. The placeholder is the place after the gap, which starts the new trip on Yes.")
    }

    static var wentHomeTitle: String {
        String(
            localized: "trip-gap.answer.went-home",
            defaultValue: "Yes, I went home",
            comment: "Answer to the did-you-go-home question: splits the trip at the gap.")
    }

    static var oneTripTitle: String {
        String(
            localized: "trip-gap.answer.one-trip",
            defaultValue: "No, one trip",
            comment: "Answer to the did-you-go-home question: keeps the trip whole and stops asking.")
    }

    private static var unknownPlace: String {
        String(localized: "trip-detail.place.unknown", defaultValue: "Unknown",
               comment: "Fallback place name in trip details.")
    }
}

extension TripGapQuestion.StaySignal {
    nonisolated init(_ stay: Stay) {
        self.init(
            id: stay.id, category: stay.category,
            startTime: stay.startTime, endTime: stay.endTime,
            latitude: stay.centroidLatitude, longitude: stay.centroidLongitude,
            distanceFromHomeKm: stay.distanceFromHomeKm,
            locality: stay.locality, region: stay.administrativeArea, country: stay.country)
    }
}

extension TripGapQuestion {
    /// The questions a trip asks now. An open trip asks none: assembly never
    /// judges a trip still being recorded.
    static func questions(for trip: Trip, defaults: UserDefaults = .standard) -> [TripGapQuestion] {
        gaps(for: trip, defaults: defaults).filter { !$0.answered }.map(\.question)
    }

    /// Every gap a trip asks or asked about, in trip order: the unanswered
    /// questions, and the gaps this device confirmed as one trip, which the
    /// Stops line keeps as a quiet note.
    static func gaps(
        for trip: Trip, defaults: UserDefaults = .standard
    ) -> [(question: TripGapQuestion, answered: Bool)] {
        guard !trip.isDeleted, trip.isComplete else { return [] }
        let confirmed = TripGapAnswers.confirmed(defaults: defaults)
        return questions(
            tripID: trip.id, stays: trip.orderedStays.filter { !$0.isDeleted }.map(StaySignal.init)
        ).map { ($0, confirmed.contains($0.id)) }
    }
}

/// The Trips list's questions: each trip row's count for its badge, and
/// every question once, oldest gap first, as the questions sheet asks them.
/// Built off the main actor (`load`) when the trips or answers change, so no
/// row body computes a question.
nonisolated struct TripGapQuestionIndex: Equatable, Sendable {
    nonisolated struct Listed: Equatable, Sendable, Identifiable {
        let question: TripGapQuestion
        /// The trip row that asked it when the index was built.
        let tripIdentifier: PersistentIdentifier
        var id: String { question.id }
    }

    var counts: [PersistentIdentifier: Int] = [:]
    var ordered: [Listed] = []

    var isEmpty: Bool { ordered.isEmpty }

    func count(for trip: PersistentIdentifier) -> Int { counts[trip] ?? 0 }

    /// Value inputs only. UUID twins of one trip repeat its gaps; the sheet
    /// asks each once.
    static func build(
        _ trips: [(identifier: PersistentIdentifier, id: UUID, stays: [TripGapQuestion.StaySignal])],
        confirmed: Set<String>
    ) -> TripGapQuestionIndex {
        var index = TripGapQuestionIndex()
        var seen = Set<String>()
        for trip in trips {
            let questions = TripGapQuestion.questions(tripID: trip.id, stays: trip.stays, confirmed: confirmed)
            guard !questions.isEmpty else { continue }
            index.counts[trip.identifier] = questions.count
            for question in questions where seen.insert(question.id).inserted {
                index.ordered.append(Listed(question: question, tripIdentifier: trip.identifier))
            }
        }
        index.ordered.sort {
            ($0.question.gapStart, $0.question.id) < ($1.question.gapStart, $1.question.id)
        }
        return index
    }

    /// Every completed trip's questions, from the worker's own context:
    /// projected stay fields only, so no trip's `stays` relationship (weather
    /// and ping payloads) is faulted. A failed fetch throws; it is never read
    /// as "no questions".
    static func load(
        container: ModelContainer, confirmed: Set<String>, checkCancellation: () throws -> Void
    ) throws -> TripGapQuestionIndex {
        let context = ModelContext(container)
        var tripDescriptor = FetchDescriptor<Trip>(predicate: #Predicate { $0.isComplete })
        tripDescriptor.propertiesToFetch = [\.id]
        let trips = try context.fetch(tripDescriptor)
        try checkCancellation()
        guard !trips.isEmpty else { return TripGapQuestionIndex() }
        var stayDescriptor = FetchDescriptor<Stay>(predicate: #Predicate { $0.trip != nil })
        stayDescriptor.propertiesToFetch = [
            \.id, \.categoryRaw, \.startTime, \.endTime, \.centroidLatitude, \.centroidLongitude,
            \.distanceFromHomeKm, \.locality, \.administrativeArea, \.country, \.trip,
        ]
        let stays = try context.fetch(stayDescriptor)
        try checkCancellation()
        var signals: [PersistentIdentifier: [TripGapQuestion.StaySignal]] = [:]
        for stay in stays {
            // The projected to-one reference supplies the trip's identity only.
            guard let trip = stay.trip?.persistentModelID else { continue }
            signals[trip, default: []].append(TripGapQuestion.StaySignal(stay))
        }
        try checkCancellation()
        return build(
            trips.map { (identifier: $0.persistentModelID, id: $0.id, stays: signals[$0.persistentModelID] ?? []) },
            confirmed: confirmed)
    }
}

/// The gaps the user confirmed as one trip, so they are never asked again:
/// "No, one trip" answers and the seams of trips the user merged. A
/// device-local ledger of stay-ID pairs (not synced; a backup carries it in its
/// preferences, and Delete All Data clears it with the stays it names).
nonisolated enum TripGapAnswers {
    nonisolated static let confirmedKey = "tripGapConfirmedOneTrip_v1"

    /// The pair key: the earlier stay's ID, then the later one's.
    static func key(earlier: UUID, later: UUID) -> String {
        "\(earlier.uuidString)>\(later.uuidString)"
    }

    static func confirmed(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: confirmedKey) ?? [])
    }

    /// "No, one trip".
    static func confirmOneTrip(_ question: TripGapQuestion, defaults: UserDefaults = .standard) {
        confirm([question.id], defaults: defaults)
    }

    /// Adds keys the ledger lacks, oldest first.
    static func confirm(_ keys: [String], defaults: UserDefaults = .standard) {
        let held = defaults.stringArray(forKey: confirmedKey) ?? []
        var seen = Set(held)
        let missing = keys.filter { seen.insert($0).inserted }
        guard !missing.isEmpty else { return }
        defaults.set(held + missing, forKey: confirmedKey)
        TripGapAnswersRevision.advance()
    }

    /// Undo: the gaps ask again. Removes only `keys`, keeping the rest in order.
    static func unconfirm(_ keys: Set<String>, defaults: UserDefaults = .standard) {
        let held = defaults.stringArray(forKey: confirmedKey) ?? []
        let kept = held.filter { !keys.contains($0) }
        guard kept.count != held.count else { return }
        if kept.isEmpty {
            defaults.removeObject(forKey: confirmedKey)
        } else {
            defaults.set(kept, forKey: confirmedKey)
        }
        TripGapAnswersRevision.advance()
    }

    /// The gaps a merge joins: consecutive away stays of the merged trip that
    /// came from different trips. `fromSource` tells the two apart.
    static func mergeSeams(_ stays: [(id: UUID, category: StayCategory, fromSource: Bool)]) -> [String] {
        let away = stays.filter { $0.category == .destination || $0.category == .transit }
        return zip(away, away.dropFirst())
            .filter { $0.fromSource != $1.fromSource }
            .map { key(earlier: $0.id, later: $1.id) }
    }
}

/// Advances whenever this device's answers change. The ledger lives in
/// UserDefaults, which SwiftUI does not observe, so the trip page and the
/// Trips list read this to ask again after an answer or an Undo.
@MainActor @Observable
final class TripGapAnswersRevision {
    static let shared = TripGapAnswersRevision()
    private(set) var value = 0

    nonisolated static func advance() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { shared.value &+= 1 }
        } else {
            Task { @MainActor in shared.value &+= 1 }
        }
    }
}
