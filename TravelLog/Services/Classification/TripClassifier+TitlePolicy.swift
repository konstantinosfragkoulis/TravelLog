//
//  TripClassifier+TitlePolicy.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import Foundation
import SwiftData

extension TripClassifier {

    /// The trip era's home place names, from the classifier's own context.
    /// Sync and cheap (a bounded projection fetch), so every title path reads
    /// one consistent set. Throws when the rows are unreadable; title work
    /// then fails closed.
    func homePlaceNames(for trip: Trip) throws -> Set<String> {
        try TripTitleStore.homePlaceNames(for: trip, in: modelContext)
    }

    /// The same set on the caller's context, for title passes outside the classifier.
    nonisolated static func homePlaceNames(for trip: Trip, in context: ModelContext) throws -> Set<String> {
        try TripTitleStore.homePlaceNames(for: trip, in: context)
    }

    typealias TitleValidationFailure = TripTitlePolicy.ValidationFailure

    /// `TripTitlePolicy.titleValidationFailure` over the trip's stays as they
    /// are now. Internal `nonisolated` seam for tests.
    nonisolated func titleValidationFailure(
        _ title: String,
        for trip: Trip,
        homePlaceNames: Set<String> = []
    ) -> TitleValidationFailure? {
        TripTitlePolicy.titleValidationFailure(
            title, stays: TripTitleStore.semanticSnapshot(for: trip).stays, homePlaceNames: homePlaceNames)
    }

    /// `TripTitlePolicy.missingTopPlaceFailure` over the trip's stays as they are now.
    nonisolated func missingTopPlaceFailure(
        _ title: String,
        for trip: Trip,
        homePlaceNames: Set<String> = []
    ) -> TitleValidationFailure? {
        TripTitlePolicy.missingTopPlaceFailure(
            title, stays: TripTitleStore.semanticSnapshot(for: trip).stays, homePlaceNames: homePlaceNames)
    }

    /// `TripTitlePolicy.forbiddenCountryWords` over the trip's ordered stays.
    /// Keep this pure and nonisolated so tests need not send a non-Sendable Trip across actors.
    nonisolated func forbiddenCountryWords(for trip: Trip) -> Set<String> {
        TripTitlePolicy.forbiddenCountryWords(countryInputs: trip.orderedStays.map { ($0.country, $0.isoCountryCode) })
    }

    #if DEBUG
    /// Ground titles only in stay names and bounded connectors; calendar text grants no vocabulary exemption.
    nonisolated func titleWordsAreGrounded(
        _ title: String,
        for trip: Trip,
        homePlaceNames: Set<String> = []
    ) -> Bool {
        ungroundedTitleFailure(title, for: trip, homePlaceNames: homePlaceNames) == nil
    }
    #endif

    /// `TripTitlePolicy.ungroundedTitleFailure` over the trip's stays as they
    /// are now. `titleWordsAreGrounded` is the Bool wrapper.
    nonisolated func ungroundedTitleFailure(
        _ title: String,
        for trip: Trip,
        homePlaceNames: Set<String> = []
    ) -> TitleValidationFailure? {
        TripTitlePolicy.ungroundedTitleFailure(
            title, stays: TripTitleStore.semanticSnapshot(for: trip).stays, homePlaceNames: homePlaceNames)
    }

    /// `TripTitlePolicy.defaultTitle` over the trip's stays as they are now:
    /// the title to persist, or nil.
    nonisolated func defaultTitle(
        for trip: Trip,
        homePlaceNames: Set<String> = []
    ) -> String? {
        TripTitlePolicy.defaultTitle(
            stays: TripTitleStore.semanticSnapshot(for: trip).stays, homePlaceNames: homePlaceNames)
    }

    /// `TripTitlePolicy.titleAlternatives` over the trip's stays as they are now.
    nonisolated func titleAlternatives(
        for trip: Trip,
        homePlaceNames: Set<String> = []
    ) -> [String] {
        TripTitlePolicy.titleAlternatives(
            stays: TripTitleStore.semanticSnapshot(for: trip).stays, homePlaceNames: homePlaceNames)
    }
}
