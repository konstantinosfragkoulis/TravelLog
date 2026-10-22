//
//  PresenceEvidence.swift
//  TravelLog
//

import Foundation

/// Single source of truth for **what the observation stream can and cannot
/// certify** about where the user was.
///
/// # The problem
///
/// Presence is inferred from silence: SLC fires on movement, so *not* moving
/// produces no pings, and a stay's dwell is the span between its first and last
/// ping. That inference is sound over minutes and hours. It is not sound over
/// weeks — and the imported lanes make it worse, because a gap in the photo
/// timeline is the absence of *photographs*, not the absence of movement.
///
/// Live fixes can provide frequent observations, while imported photos can
/// leave long gaps. Sparse photography does not establish continuous presence.
///
/// # What goes wrong without this
///
/// Separate trips can appear as one run of away-from-home stays when nothing
/// is recorded between them. Joining across those gaps invents a continuous
/// absence. The observations do not establish whether the user returned home.
///
/// # The rule
///
/// > An interval containing **no observation at all**, longer than
/// > `unknownGapSeconds`, is `.unknown`. It is neither presence nor absence,
/// > and no span may be certified across it.
///
/// `unknown` is a first-class outcome, not a degenerate case of "away".
///
/// # Why seven days
///
/// The threshold must tolerate short gaps in photography within a trip while
/// refusing to join separate trips across long intervals with no observations.
/// Splitting at every unsupported gap would fragment sparse photo histories;
/// this file splits only at `unknown` gaps.
///
/// A full week without evidence cannot certify continuous absence. Treat the
/// threshold as a limit: widen it only against evidence, never to make a case pass.
///
/// # Duration inside a run
///
/// Counting only supported time with `min(gap, horizon)` would shorten displayed
/// trip durations whenever photographs are sparse. Duration therefore remains
/// the raw span within a run; unknown gaps separate runs instead.
nonisolated enum PresenceEvidence {

    /// An interval with no observation at all, longer than this, is `.unknown`.
    /// See the type doc for the balance between sparse evidence and unknown gaps.
    static let unknownGapSeconds: TimeInterval = 7 * 24 * 60 * 60

    /// What the stream can say about the interval between two observations.
    enum IntervalSupport: Sendable, Equatable {
        /// Bounded by observations closely enough to carry a claim across it.
        case observed
        /// Longer than `unknownGapSeconds` with nothing recorded inside it.
        /// Neither presence nor absence — a hole in the record.
        case unknown
    }

    /// Classify the interval between the end of one observation and the start
    /// of the next. Order is caller-supplied; a non-positive interval (adjacent
    /// or overlapping observations) is `.observed`.
    static func support(fromEndOf earlier: Date, toStartOf later: Date) -> IntervalSupport {
        later.timeIntervalSince(earlier) > unknownGapSeconds ? .unknown : .observed
    }
}
