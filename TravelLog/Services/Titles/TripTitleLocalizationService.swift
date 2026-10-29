//
//  TripTitleLocalizationService.swift
//  TravelLog
//

import Foundation
import SwiftData
import WidgetKit
import os.log

/// Writes each generated trip title in the app's language as a
/// `TripTitleVariant`, so the widget and every other reader show it without
/// the place-name table. The variant names the canonical title's own places
/// (`TripTitlePolicy.localizedTitle`), each from the bundled offline table
/// (`PlaceNameTable`) or in its canonical spelling, joined with the
/// language's list connectors. Deterministic: every device writes the same
/// text for the same trip and language, and nothing is generated or retried.
@ModelActor
actor TripTitleLocalizationService {

    private let logger = Logger(
        subsystem: "com.travellog.app",
        category: "TripTitleLocalization")

    /// The trips per write unit: each is a short, bounded transaction.
    static let unitSize = 25

    /// Trip inputs already reconciled this launch, so a repeated trigger
    /// does not recompose the library. A changed canonical title rotates its
    /// revision, a variant another device syncs changes the shown text,
    /// enrichment can fill a place's name or country without changing the
    /// canonical title, and a stay's category or airport flag can change the
    /// layer a place is named by (an island or a town of its name) while the
    /// title stands, so each is a new key.
    private var settled: Set<SettledKey> = []

    private struct SettledKey: Hashable {
        let trip: PersistentIdentifier
        let sourceTitle: String
        let sourceRevision: UUID?
        let languageTag: String
        let shownVariant: String?
        let places: [String]
    }

    private var placeNames: @Sendable (TripTitlePolicy.TitlePlace, String) -> String? = {
        PlaceNameTable.shared.name(for: $0, languageTag: $1)
    }

    #if DEBUG
    func setPlaceNamesForTesting(_ lookup: @escaping @Sendable (TripTitlePolicy.TitlePlace, String) -> String?) {
        placeNames = lookup
        settled.removeAll()
    }
    #endif

    /// Bring every titled trip's variant for `languageTag` in line with its
    /// generated title, newest first, in short gated units that each re-read
    /// their rows. A variant is written only where the title the trip shows
    /// (its usable variant, else the canonical title) differs from the
    /// localized one, which also replaces a variant an older build stored.
    /// A finite limit bounds the variants written. Returns how many it wrote.
    @discardableResult
    func generateLocalizedTitlesStage(
        maxTripsPerCall: Int?,
        languageTag requestedTag: String = AppLanguagePreference.currentTag(),
        gate: PipelineGate = .shared
    ) async -> Int {
        guard let languageTag = AppLanguagePreference.normalizedSupportedTag(requestedTag),
              languageTag != "en" else { return 0 }
        var descriptor = FetchDescriptor<Trip>(
            predicate: #Predicate {
                ($0.customName ?? "") == "" && ($0.aiGeneratedTitle ?? "") != ""
            },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)])
        descriptor.relationshipKeyPathsForPrefetching = [\.localizedTitles]
        guard let fetched = try? ModelContext(modelContainer).fetch(descriptor) else { return 0 }
        // Rows, not models: each unit fetches its rows again in its own context.
        var rows = fetched.compactMap { trip -> (id: UUID, identifier: PersistentIdentifier)? in
            guard !trip.isDeleted, let key = settledKey(for: trip, languageTag: languageTag),
                  !settled.contains(key) else { return nil }
            return (trip.id, trip.persistentModelID)
        }[...]
        var written = 0
        while !rows.isEmpty, !Task.isCancelled {
            let remaining = maxTripsPerCall.map { max(0, $0 - written) }
            if remaining == 0 { break }
            let unit = Array(rows.prefix(Self.unitSize))
            rows = rows.dropFirst(unit.count)
            written += await gate.runReturning(touching: [.trip]) {
                await self.localize(unit, languageTag: languageTag, limit: remaining)
            }
        }
        if written > 0 {
            await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
        }
        return written
    }

    /// The detail screen's lane for one trip, so a trip opened directly does
    /// not wait for a drain. Returns the title the trip shows in
    /// `languageTag` once reconciled, or nil for an English, custom-named or
    /// untitled trip.
    func localizedTitle(
        for tripID: UUID,
        tripIdentifier: PersistentIdentifier? = nil,
        languageTag requestedTag: String = AppLanguagePreference.currentTag(),
        gate: PipelineGate = .shared
    ) async -> String? {
        guard let languageTag = AppLanguagePreference.normalizedSupportedTag(requestedTag),
              languageTag != "en" else { return nil }
        let context = ModelContext(modelContainer)
        guard let trip = fetchTrip(tripID: tripID, tripIdentifier: tripIdentifier, in: context),
              let key = settledKey(for: trip, languageTag: languageTag) else { return nil }
        let identifier = trip.persistentModelID
        if !settled.contains(key) {
            let written = await gate.runReturning(touching: [.trip]) {
                await self.localize([(tripID, identifier)], languageTag: languageTag, limit: nil)
            }
            if written > 0 {
                await MainActor.run { WidgetCenter.shared.reloadAllTimelines() }
            }
        }
        guard let current = fetchTrip(
            tripID: tripID, tripIdentifier: identifier, in: ModelContext(modelContainer)),
              current.customName?.isEmpty != false else { return nil }
        return TripTitleStore.localizedTitle(for: current, languageTag: languageTag)
            ?? TripTitleStore.normalized(current.aiGeneratedTitle)
    }

    // MARK: - Units

    /// One write unit. Returns how many variants it wrote; a failed save writes none.
    private func localize(
        _ rows: [(id: UUID, identifier: PersistentIdentifier)],
        languageTag: String,
        limit: Int?
    ) -> Int {
        let context = ModelContext(modelContainer)
        var written = 0
        var reconciled: [SettledKey] = []
        for row in rows {
            if let limit, written >= limit { break }
            guard !Task.isCancelled else { break }
            guard let trip = fetchTrip(tripID: row.id, tripIdentifier: row.identifier, in: context),
                  trip.customName?.isEmpty != false,
                  let canonical = TripTitleStore.normalized(trip.aiGeneratedTitle),
                  // A trip that synced ahead of its stays cannot say which
                  // places its title names; a later trigger localizes it.
                  TripTitleStore.holdsItsNamedStays(trip),
                  let homePlaceNames = try? TripTitleStore.homePlaceNames(for: trip, in: context),
                  let localized = TripTitlePolicy.localizedTitle(
                    canonicalTitle: canonical,
                    stays: TripTitleStore.semanticSnapshot(for: trip).stays,
                    homePlaceNames: homePlaceNames,
                    languageTag: languageTag,
                    placeName: { placeNames($0, languageTag) }) else { continue }
            let shown = TripTitleStore.localizedTitle(for: trip, languageTag: languageTag) ?? canonical
            if shown != localized, TripTitleStore.upsertVariant(
                languageTag: languageTag, title: localized, sourceTitle: canonical, for: trip, in: context) {
                written += 1
            }
            if let key = settledKey(for: trip, languageTag: languageTag) { reconciled.append(key) }
        }
        if written > 0 {
            do {
                try context.save()
            } catch {
                context.rollback()
                logger.error("Localized trip-title save failed: \(error.localizedDescription, privacy: .private)")
                return 0
            }
        }
        settled.formUnion(reconciled)
        return written
    }

    private func settledKey(for trip: Trip, languageTag: String) -> SettledKey? {
        guard trip.customName?.isEmpty != false,
              let source = TripTitleStore.normalized(trip.aiGeneratedTitle) else { return nil }
        return SettledKey(
            trip: trip.persistentModelID, sourceTitle: source,
            sourceRevision: trip.titleSourceRevision, languageTag: languageTag,
            shownVariant: TripTitleStore.localizedTitle(for: trip, languageTag: languageTag),
            places: trip.orderedStays.map {
                [$0.metroName, $0.islandName, $0.locality, $0.country, $0.isoCountryCode, $0.categoryRaw,
                 $0.isAirport ? "airport" : ""].map { $0 ?? "" }.joined(separator: "|")
            })
    }

    /// Resolve a physical SwiftData row when the caller has one, so CloudKit
    /// twins sharing an app UUID never receive each other's variant. Always
    /// a fetch: it returns live rows only.
    private func fetchTrip(
        tripID: UUID,
        tripIdentifier: PersistentIdentifier?,
        in context: ModelContext
    ) -> Trip? {
        let id = tripID
        let predicate = #Predicate<Trip> { $0.id == id }
        guard let trips = try? context.fetch(FetchDescriptor<Trip>(predicate: predicate)) else { return nil }
        return trips.first { trip in
            !trip.isDeleted && (tripIdentifier == nil || trip.persistentModelID == tripIdentifier)
        }
    }
}
