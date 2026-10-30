//
//  TripTitleStore+Derivation.swift
//  TravelLog
//

import Foundation
import SwiftData

/// The app's half of the title store: deriving a trip's generated title
/// from its inputs (`TripTitlePolicy`) wherever they change. The widget
/// shares the rest of `TripTitleStore` and never writes a title.
nonisolated extension TripTitleStore {

    /// Recompute derived trip fields and re-derive the generated title only
    /// when a writer actually changed a title input, and only where
    /// `mayDeriveSummary` allows it, judged on the stays as they were before
    /// the change: a parent owed a later pass keeps its summary and title,
    /// and the launch summary pass is owed it (`oweSummaryRefresh`).
    /// Every changed parent is processed first; the call then throws
    /// `HomePlaceNamesUnreadable` when any summary was built without its
    /// home-place filter. Units that latch or commit once roll back on it;
    /// a writer that may keep a degraded summary uses `try?`.
    @discardableResult
    static func invalidateChangedParentTitles(
        from snapshots: [ParentSemanticSnapshot],
        in context: ModelContext
    ) throws -> Int {
        var changed = 0
        var homePlacesRead = true
        var hydrating: Bool?
        var deferred = false
        for snapshot in snapshots {
            let trip = snapshot.trip
            guard !trip.isDeleted,
                  snapshot.semantic != semanticSnapshot(for: trip) else {
                continue
            }
            if !heldItsNamedStays(snapshot) {
                let mayBeHydrating = hydrating ?? storeMayBeHydrating()
                hydrating = mayBeHydrating
                guard mayDeriveSummary(holdsNamedStays: false, storeMayBeHydrating: mayBeHydrating) else {
                    deferred = true
                    continue
                }
            }
            if !trip.recomputeSummary() { homePlacesRead = false }
            invalidateGeneratedTitles(for: trip, in: context)
            changed += 1
        }
        if deferred { oweSummaryRefresh() }
        guard homePlacesRead else { throw HomePlaceNamesUnreadable() }
        return changed
    }

    /// Detects Home prompt changes that arrived outside a local writer (most
    /// importantly a completed CloudKit import). The hash stores no raw place
    /// text. A first run preserves existing generated artifacts while
    /// establishing a trustworthy baseline for future comparisons.
    @discardableResult
    static func reconcileActiveHomeTitleFingerprint(
        in context: ModelContext,
        defaults: UserDefaults = .standard,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> Int {
        let inputs = try fetchActiveHomeTitleInputs(in: context)
        let fingerprint = activeHomeTitleFingerprint(for: inputs)
        guard let previous = defaults.string(
            forKey: activeHomeTitleFingerprintKey) else {
            // Upgrade baseline: absence does not prove the Home prompt changed.
            // Preserve every durable title and begin detecting from this point.
            defaults.set(fingerprint, forKey: activeHomeTitleFingerprintKey)
            return 0
        }
        guard previous != fingerprint else { return 0 }

        let trips = try context.fetch(FetchDescriptor<Trip>())
        let invalidated = refreshGeneratedTitles(
            for: trips.filter { !$0.isDeleted }, in: context)
        do {
            if invalidated > 0 { try save(context) }
            defaults.set(fingerprint, forKey: activeHomeTitleFingerprintKey)
            return invalidated
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Invalidate the library only when the active-home content set changed.
    /// Radius/coordinate-only edits remain on the classifier's targeted path;
    /// physical ids and same-content twins never invalidate, while a changed
    /// locality or country, or a new or ended distinct Home, does.
    @discardableResult
    static func invalidateAllGeneratedTitlesIfActiveHomesChanged(
        from before: [ActiveHomeTitleInput],
        in context: ModelContext,
        preserving preservedTrips: [Trip] = []
    ) throws -> Bool {
        guard !hasEquivalentActiveHomePromptContent(
            before, try fetchActiveHomeTitleInputs(in: context)) else {
            return false
        }
        let preservedIdentities = Set(preservedTrips.map(ObjectIdentifier.init))
        let trips = try context.fetch(FetchDescriptor<Trip>())
        refreshGeneratedTitles(
            for: trips.filter { !$0.isDeleted && !preservedIdentities.contains(ObjectIdentifier($0)) },
            in: context)
        return true
    }

    /// A semantic trip mutation re-derives the generated title from the
    /// trip's inputs as they are now, in the caller's transaction. A title
    /// that still stands (`titleStands`: the default) keeps its revision and
    /// every localized variant (they translate the same text), so an ongoing
    /// trip's growing stay never churns them; any other is replaced by the
    /// default title, so a title grows with its trip and one derived from
    /// part of it gives way once the rest arrives. When the inputs give no
    /// title at all, a grounded stored title stays (`titleStands(_:among:stays:homePlaceNames:)`)
    /// and any other is cleared.
    /// An unreadable home-place set is not "no home": the title is cleared
    /// with its variants, and Stage 5 derives it once the set reads. Returns
    /// whether the trip's title state changed.
    @discardableResult
    static func invalidateGeneratedTitles(for trip: Trip, in context: ModelContext) -> Bool {
        let stays = semanticSnapshot(for: trip).stays
        guard let homePlaces = try? homePlaceNames(for: trip, in: context) else {
            return replaceCanonicalTitle(
                nil,
                for: trip,
                in: context,
                invalidateVariantsEvenIfUnchanged: true)
        }
        let alternatives = TripTitlePolicy.titleAlternatives(stays: stays, homePlaceNames: homePlaces)
        if let current = normalized(trip.aiGeneratedTitle),
           titleStands(current, among: alternatives, stays: stays, homePlaceNames: homePlaces) {
            return false
        }
        // Variants of a title the inputs no longer give go too, even when
        // the default is no title either: one that synced ahead of its
        // canonical row must not resurrect a title for the old stays.
        return replaceCanonicalTitle(
            alternatives.first,
            for: trip,
            in: context,
            invalidateVariantsEvenIfUnchanged: !(trip.localizedTitles ?? []).isEmpty)
    }

    /// Whether a stored generated title stands for inputs that give
    /// `alternatives` (`TripTitlePolicy.titleAlternatives`, the default
    /// first): it is the default.
    static func titleStands(_ title: String, among alternatives: [String]) -> Bool {
        title == alternatives.first
    }

    /// `titleStands`, and also, when `stays` give no title at all (no
    /// destination, or no place that names one), a well-formed stored title
    /// every word of which the trip's own places ground. No title is derived
    /// for such a trip, but an older build's model titled all-transit trips:
    /// clearing its synced title would only make that device title the trip
    /// again, and the two would alternate.
    static func titleStands(
        _ title: String,
        among alternatives: [String],
        stays: [TripTitlePolicy.StayInput],
        homePlaceNames: Set<String>
    ) -> Bool {
        if titleStands(title, among: alternatives) { return true }
        guard alternatives.isEmpty, !stays.isEmpty else { return false }
        return TripTitlePolicy.formFailure(title) == nil
            && TripTitlePolicy.ungroundedTitleFailure(title, stays: stays, homePlaceNames: homePlaceNames) == nil
    }

    /// `invalidateGeneratedTitles` for many trips against one home-place
    /// index read from `context`, its unsaved writes included: a home edit
    /// in the same transaction is what these callers react to, and the
    /// shared cache can still hold the rows from before it. A trip
    /// `mayDeriveSummary` leaves for a later pass keeps its title, and the
    /// launch summary pass is owed it (`oweSummaryRefresh`). Returns how many
    /// trips' titles changed.
    @discardableResult
    static func refreshGeneratedTitles(for trips: [Trip], in context: ModelContext) -> Int {
        let pinned = (try? HomePlaceIndex.uncached(for: context)) ?? HomePlaceIndex.pinned
        var hydrating: Bool?
        var deferred = false
        let refreshed = HomePlaceIndex.$pinned.withValue(pinned) {
            trips.reduce(0) { changed, trip in
                guard !trip.isDeleted else { return changed }
                guard mayDeriveSummary(holdsNamedStays: holdsItsNamedStays(trip), hydrating: &hydrating) else {
                    deferred = true
                    return changed
                }
                return changed + (invalidateGeneratedTitles(for: trip, in: context) ? 1 : 0)
            }
        }
        if deferred { oweSummaryRefresh() }
        return refreshed
    }

    /// Whether this device holds the stays a stored title was derived from:
    /// the trip has stays, and they give every place its stored summary
    /// names. A trip that synced ahead of its stays, wholly or in part, is
    /// left to a later check, so a title is never derived from part of a trip.
    static func holdsItsNamedStays(_ trip: Trip) -> Bool {
        namedPlacesHeld(summary: trip.destinationSummary, by: (trip.stays ?? []).map(\.placeGroupName))
    }

    /// `holdsItsNamedStays` for the stays `snapshot` recorded before a
    /// writer changed them, against the summary the trip still stores.
    static func heldItsNamedStays(_ snapshot: ParentSemanticSnapshot) -> Bool {
        namedPlacesHeld(summary: snapshot.trip.destinationSummary, by: snapshot.semantic.stays.map {
            normalized($0.metroName) ?? normalized($0.islandName) ?? normalized($0.locality)
        })
    }

    /// Whether stays with these place names (`Stay.placeGroupName`, one per
    /// stay) give every place `summary` names; false for no stays.
    private static func namedPlacesHeld(summary: String, by placeNames: [String?]) -> Bool {
        guard !placeNames.isEmpty else { return false }
        let own = Set(placeNames.flatMap {
            Trip.summaryComponents($0 ?? Trip.unknownDestinationSentinel)
        })
        return Set(Trip.summaryComponents(summary)).isSubset(of: own)
    }

    /// The one rule for every writer that derives a trip's summary,
    /// countries, provenance or title from its stays outside a membership
    /// change (the launch summary passes, and every stay-field writer through
    /// `invalidateChangedParentTitles`): a trip whose stored summary names
    /// places its stays do not give is owed a later pass while the store may
    /// still be hydrating, since a summary derived now would name only the
    /// part that synced and the stored-title check would then take it as the
    /// whole trip. Once hydration is settled, or the store does not sync,
    /// such a summary is stale naming and is derived again.
    static func mayDeriveSummary(holdsNamedStays: Bool, storeMayBeHydrating: Bool) -> Bool {
        holdsNamedStays || !storeMayBeHydrating
    }

    /// `mayDeriveSummary` for a writer judging many trips: the store is read
    /// (`storeMayBeHydrating`) once, at the first trip that does not hold its
    /// named stays, and kept in `hydrating`. Judge a trip on its stays before
    /// the writer changes them (`holdsItsNamedStays` then, or
    /// `heldItsNamedStays` of a snapshot): once stays left it, no trip gives
    /// every name it stored.
    static func mayDeriveSummary(holdsNamedStays: Bool, hydrating: inout Bool?) -> Bool {
        guard !holdsNamedStays else { return true }
        let mayBeHydrating = hydrating ?? storeMayBeHydrating()
        hydrating = mayBeHydrating
        return mayDeriveSummary(holdsNamedStays: false, storeMayBeHydrating: mayBeHydrating)
    }

    /// Whether rows may still be arriving from CloudKit
    /// (`AppDelegate.storeMayStillBeHydrating`), or the test override.
    static func storeMayBeHydrating() -> Bool {
        storeMayBeHydratingOverride ?? AppDelegate.storeMayStillBeHydrating(passStartedAt: .now)
    }

    /// Overrides `storeMayBeHydrating` in tests; nil reads the live state.
    @TaskLocal static var storeMayBeHydratingOverride: Bool?

    /// A writer left a trip's summary for a later pass: once the stays it
    /// waits for arrive, no stay-field write may come to derive it (a renamed
    /// place leaves its stays never giving the summary's names), so the
    /// launch summary pass runs again, latched or not, and the first launch
    /// after hydration settles derives it (`AppDelegate.oweTripSummaryRefresh`).
    static func oweSummaryRefresh() {
        AppDelegate.oweTripSummaryRefresh(
            defaults: summaryDebtSuiteForTesting.flatMap(UserDefaults.init(suiteName:)) ?? .standard)
    }

    /// The defaults suite `oweSummaryRefresh` records into in tests; nil
    /// records into the standard defaults.
    @TaskLocal static var summaryDebtSuiteForTesting: String?

    /// `TripTitlePolicy.titleAlternatives` for the trip as it is now, the
    /// default first. Throws `HomePlaceNamesUnreadable` when the trip era's
    /// home places cannot be read.
    static func generatedTitleAlternatives(for trip: Trip, in context: ModelContext) throws -> [String] {
        TripTitlePolicy.titleAlternatives(
            stays: semanticSnapshot(for: trip).stays,
            homePlaceNames: try homePlaceNames(for: trip, in: context))
    }

    /// The trip era's home place names for `trip` (`homePlaceNames(tripStart:…)`).
    /// The destinations carry the title-level name, the one
    /// `TripTitlePolicy.isHomePlace` compares.
    static func homePlaceNames(for trip: Trip, in context: ModelContext) throws -> Set<String> {
        try homePlaceNames(
            tripStart: trip.startDate,
            tripEnd: trip.endDate ?? .now,
            destinations: {
                trip.destinations.map {
                    (TripTitlePolicy.titlePlaceName(
                        metro: $0.metroName, island: $0.islandName, locality: $0.locality,
                        country: $0.country, iso: $0.isoCountryCode) ?? Trip.unknownDestinationSentinel,
                     $0.durationMinutes)
                }
            },
            in: context)
    }
}
