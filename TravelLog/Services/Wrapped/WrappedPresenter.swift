//
//  WrappedPresenter.swift
//  TravelLog
//

import Foundation
import Observation

/// Cross-tab signal for presenting a `YearWrapped` view from anywhere
/// (notification tap, Settings → Memories, generation-complete banner).
///
/// `RootView` observes `requestedYear` and presents `WrappedView` as a
/// fullScreenCover when set. Consumers set the year to present, then
/// call `clear()` once dismissed.
///
/// Same single-set/single-consume pattern as `TripsTabRouter`.
@MainActor
@Observable
final class WrappedPresenter {

    static let shared = WrappedPresenter()

    /// Year to present. nil = no Wrapped is being requested.
    var requestedYear: Int?

    /// Why a requested year's preparation ended without a committed row.
    struct PreparationFailure: Equatable {
        enum Reason: Equatable {
            /// The year has too little travel for a recap yet.
            case insufficientData
            /// Reading, building or saving the recap failed; a retry may work.
            case failed
        }

        let year: Int
        let reason: Reason
    }

    /// Terminal state of the requested year's preparation. RootView uses it
    /// to replace the preparation spinner with the matching terminal text; a
    /// row that lands later still takes over the cover.
    var preparationFailure: PreparationFailure?

    private init() {}

    #if DEBUG
    init(forTesting: Void) {}
    #endif

    func requestYear(_ year: Int) {
        requestedYear = year
        preparationFailure = nil
    }

    /// Records how the requested year's generation ended. Stale completions
    /// for another year are ignored.
    func finishPreparing(forYear year: Int, outcome: WrappedGenerationOutcome) {
        guard requestedYear == year else { return }
        switch outcome {
        case .existing, .created:
            preparationFailure = nil
        case .insufficientData:
            preparationFailure = PreparationFailure(year: year, reason: .insufficientData)
        case .busy, .failed:
            preparationFailure = PreparationFailure(year: year, reason: .failed)
        }
    }

    func clear() {
        requestedYear = nil
        preparationFailure = nil
    }
}
