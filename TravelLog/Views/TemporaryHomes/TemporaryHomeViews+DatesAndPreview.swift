//
//  TemporaryHomeViews+DatesAndPreview.swift
//  TravelLog
//
//  The Settings section that lists temporary homes, the add/edit sheet, and
//  the gated write path they share.
//

import SwiftUI
import SwiftData
import Combine
import CoreLocation
import WidgetKit
import os.log

extension TemporaryHomeFormSheet {

    // MARK: Dates

    /// Whether `a` and `b` fall on the same civil day in `zone`.
    nonisolated private static func sameCivilDay(_ a: Date, _ b: Date, in zone: TimeZone) -> Bool {
        TemporaryHomeSaveWorker.civilDayBounds(of: a, in: zone).start
            == TemporaryHomeSaveWorker.civilDayBounds(of: b, in: zone).start
    }

    /// The preview's arrival to offer as Since, never to assign: only when it
    /// falls on another day than the picked Since and not after the picked
    /// end (`until`, nil when open), days read in `zone`.
    nonisolated static func offeredArrival(
        _ arrival: Date?, since: Date, until: Date?, in zone: TimeZone
    ) -> Date? {
        guard let arrival, !sameCivilDay(arrival, since, in: zone) else { return nil }
        if let until,
           arrival > TemporaryHomeSaveWorker.civilDayBounds(of: until, in: zone).end {
            return nil
        }
        return arrival
    }

    /// The first recorded stay in the area, shown only while it says
    /// something the picked Since and the offered arrival do not.
    nonisolated static func shownFirstRecorded(
        _ first: Date?, arrival: Date?, since: Date, in zone: TimeZone
    ) -> Date? {
        guard let first, !sameCivilDay(first, since, in: zone) else { return nil }
        if let arrival, sameCivilDay(first, arrival, in: zone) { return nil }
        return first
    }

    var offeredArrival: Date? {
        Self.offeredArrival(
            preview?.arrivalInArea, since: since, until: hasEnd ? until : nil, in: zone)
    }

    var shownFirstRecorded: Date? {
        Self.shownFirstRecorded(
            preview?.firstStayInArea, arrival: preview?.arrivalInArea, since: since, in: zone)
    }

    /// Since becomes the arrival the user tapped. It is an instant, a stay's
    /// start: should the place's zone arrive later, its day is the one at the place.
    func useArrival(_ arrival: Date) {
        since = arrival
        sinceIsInstant = true
        keepUntilFromSince()
        reviewWentStale = false
    }

    /// The civil day `picked` falls on in `old`, as noon of that day in `new`.
    nonisolated static func sameDay(_ picked: Date, from old: TimeZone, in new: TimeZone) -> Date {
        var source = Calendar(identifier: .gregorian)
        source.timeZone = old
        var target = Calendar(identifier: .gregorian)
        target.timeZone = new
        var day = source.dateComponents([.year, .month, .day], from: picked)
        day.hour = 12
        return target.date(from: day) ?? picked
    }

    /// Reads the days in `newZone` from here on. A picked day stays: a start
    /// on 13 Sep is 13 Sep at the place, wherever it was picked. An instant
    /// stays an instant, so its day becomes the one it falls on at the place.
    private func adoptZone(_ newZone: TimeZone) {
        guard newZone.identifier != zone.identifier else { return }
        if !sinceIsInstant { since = Self.sameDay(since, from: zone, in: newZone) }
        if !untilIsInstant { until = Self.sameDay(until, from: zone, in: newZone) }
        zone = newZone
        keepUntilFromSince()
    }

    /// An instant and a picked day can swap order when the zone changes; Until
    /// then takes Since's day, as it does when Since is picked past it.
    private func keepUntilFromSince() {
        guard TemporaryHomeSaveWorker.civilDayBounds(of: until, in: zone).end
            < TemporaryHomeSaveWorker.civilDayBounds(of: since, in: zone).start else { return }
        until = since
        untilIsInstant = sinceIsInstant
    }

    struct PlaceKey: Equatable {
        let latitude: Double
        let longitude: Double
    }

    var placeKey: PlaceKey? {
        selectedCoordinate.map { PlaceKey(latitude: $0.latitude, longitude: $0.longitude) }
    }

    /// The chosen place's own zone, from MapKit. Without an answer the zone
    /// of a stay recorded there (`refreshPreview`) or the one in use stands.
    func resolvePlaceZone() async {
        // An end is read in the stored zone, as the worker reads it.
        guard !isEnding else { return }
        // Another place: the zone the last one gave does not carry over.
        zoneIsFromPlace = false
        adoptZone(baseZone)
        guard let key = placeKey,
              let found = await PlaceTimeZone.lookup(
                  latitude: key.latitude, longitude: key.longitude),
              key == placeKey else { return }
        zoneIsFromPlace = true
        adoptZone(found)
    }

    /// "Brussels, Belgium" for the chosen pin, from the offline geocoder
    /// the save reads it with first (no MapKit request), for that pin only:
    /// an answer for a pin moved meanwhile is dropped. The stored place
    /// answers for the stored pin on edit.
    func resolvePlaceName() async {
        guard let key = placeKey, placeName?.key != key else { return }
        let result = await GeocodeResolver.shared.resolve(latitude: key.latitude, longitude: key.longitude)
        guard key == placeKey else { return }
        placeName = Self.placeLine(
            locality: result?.localityForStorage, isoCountryCode: result?.isoCountryCode,
            country: result?.country
        ).map { (key: key, line: $0) }
    }

    var sinceBinding: Binding<Date> {
        Binding(
            get: { since },
            set: {
                since = $0
                sinceIsInstant = false
                keepUntilFromSince()
                reviewWentStale = false
            })
    }

    var untilBinding: Binding<Date> {
        Binding(
            get: { until },
            set: {
                until = $0
                untilIsInstant = false
                reviewWentStale = false
            })
    }

    var hasEndBinding: Binding<Bool> {
        Binding(
            get: { hasEnd },
            set: {
                if $0 { keepUntilFromSince() }
                hasEnd = $0
                reviewWentStale = false
            })
    }

    /// The picked days as the instants that are stored. An end keeps the stored start.
    var resolvedDates: (startedAt: Date, endedAt: Date?) {
        let startedAt = storedStart
            ?? TemporaryHomeSaveWorker.civilDayBounds(of: since, in: zone).start
        let endedAt = hasEnd
            ? TemporaryHomeSaveWorker.civilDayBounds(of: until, in: zone).end : nil
        return (startedAt, endedAt)
    }

    var datesAreValid: Bool {
        let dates = resolvedDates
        return TemporaryHomeSaveWorker.datesAreValid(
            startedAt: dates.startedAt, endedAt: dates.endedAt)
    }

    var isValid: Bool {
        selectedCoordinate != nil && datesAreValid
    }

    // MARK: Preview

    private var draftID: UUID {
        switch mode {
        case .add: newDraftID
        case .edit(let id), .extend(let id), .end(let id, _): id
        }
    }

    /// The store's change token for what the review reads. Observed, so a
    /// write there changes `previewKey` and re-runs the preview.
    private var changeToken: Int {
        StoreChangeTracker.shared.token(for: Self.reviewedChanges)
    }

    /// The favourites the preview holds: a trip favourited on another device
    /// while the form is open can be split, so the review runs again.
    /// Observed, like `changeToken`.
    private var favoritesToken: Int {
        Self.favoritesFingerprint(PinnedTripsStorage.shared.pinnedIDs)
    }

    /// The same set gives the same value in this process, whatever its order.
    nonisolated static func favoritesFingerprint(_ ids: Set<UUID>) -> Int {
        var hasher = Hasher()
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) { hasher.combine(id) }
        return hasher.finalize()
    }

    /// Nil while there is nothing to preview: no place yet, or the end before the start.
    var previewKey: PreviewKey? {
        guard let coord = selectedCoordinate, datesAreValid else { return nil }
        let dates = resolvedDates
        return PreviewKey(
            latitude: coord.latitude, longitude: coord.longitude,
            startedAt: dates.startedAt, endedAt: dates.endedAt, changes: changeToken,
            favorites: favoritesToken)
    }

    var review: Review {
        Self.review(current: previewKey, previewed: previewedKey, preview: preview)
    }

    /// A preview stands for the inputs it was computed for; nil there is a
    /// failed read, never an empty change.
    nonisolated static func review(
        current: PreviewKey?, previewed: PreviewKey?,
        preview: TripClassifier.TemporaryHomeChangePreview?
    ) -> Review {
        guard let current else { return .none }
        guard previewed == current else { return .checking }
        return preview == nil ? .failed : .ready
    }

    /// Whether the confirmation raised for `confirmed` may commit: only while
    /// the inputs on screen, the store's change token included, are the ones
    /// it was raised for and their review succeeded.
    nonisolated static func confirmationCommits(
        confirmed: PreviewKey?, current: PreviewKey?, previewed: PreviewKey?,
        preview: TripClassifier.TemporaryHomeChangePreview?
    ) -> Bool {
        confirmed != nil && confirmed == current
            && review(current: current, previewed: previewed, preview: preview) == .ready
    }

    /// The removal key for what is on screen now. Observed, like `previewKey`.
    var currentRemovalKey: RemovalKey {
        RemovalKey(changes: changeToken, favorites: favoritesToken)
    }

    /// Whether the removal confirmation may commit: only while neither the
    /// store nor the favourites changed since its lines were read.
    nonisolated static func removalCommits(reviewed: RemovalKey?, current: RemovalKey) -> Bool {
        reviewed == current
    }

    /// Reads the preview again for the same inputs, after a failed read.
    func retryPreview() {
        previewedKey = nil
        Task { await refreshPreview() }
    }

    func refreshPreview() async {
        guard let key = previewKey else {
            preview = nil
            previewedKey = nil
            return
        }
        // Another place: what was first recorded at the old one no longer applies.
        if previewedKey?.latitude != key.latitude || previewedKey?.longitude != key.longitude {
            preview = nil
        }
        let draft = HomeAnchor(
            id: draftID, kind: .temporary, label: label,
            latitude: key.latitude, longitude: key.longitude, radiusKm: radiusKm,
            locality: nil, isoCountryCode: nil,
            startedAt: key.startedAt, endedAt: key.endedAt)
        // Counted before the read: a write that lands during it fails the save's check.
        let pinned = PinnedTripsStorage.shared.pinnedIDs
        let inputs = TemporaryHomeSaveWorker.currentInputs(pinnedTripIDs: pinned)
        let result = await AppDelegate.tripClassifier.previewTemporaryHomeChange(
            draft: draft, removing: false, pinnedTripIDs: pinned)
        // Staleness is judged by key, not by `Task.isCancelled` (see
        // `HomeAreaSourcePreview`): a cancelled task's answer still stands
        // while its inputs are the ones on screen.
        guard key == previewKey else { return }
        preview = result
        previewedKey = key
        previewedInputs = inputs

        // Stays recorded there carry the place's zone; MapKit's answer outranks
        // them, and so does the zone a row already stores for this pin. An end
        // stays in the zone the worker reads it in.
        if !isEnding, !zoneIsFromPlace, placeKey != placeWithStoredZone,
           let recorded = result?.areaTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) {
            adoptZone(recorded)
        }
    }

    /// The stays and trips a removal would touch, in the sheet's own preview lines.
    /// - Returns: false when the read failed: nothing is confirmed then.
    func refreshRemovalLines() async -> Bool {
        guard let id = editedID, let coord = selectedCoordinate else {
            removalLines = []
            removalKeptTripIDs = []
            removalKey = nil
            return false
        }
        // Before the read: a write or a synced favourite that lands during it
        // asks for another.
        let pinned = PinnedTripsStorage.shared.pinnedIDs
        let key = RemovalKey(changes: changeToken, favorites: Self.favoritesFingerprint(pinned))
        let inputs = TemporaryHomeSaveWorker.currentInputs(pinnedTripIDs: pinned)
        let dates = resolvedDates
        let draft = HomeAnchor(
            id: id, kind: .temporary, label: label,
            latitude: coord.latitude, longitude: coord.longitude, radiusKm: radiusKm,
            locality: nil, isoCountryCode: nil,
            startedAt: dates.startedAt, endedAt: dates.endedAt)
        let result = await AppDelegate.tripClassifier.previewTemporaryHomeChange(
            draft: draft, removing: true, pinnedTripIDs: pinned)
        removalLines = result.map { Self.changeLines(for: $0, areaNote: false) } ?? []
        removalKeptTripIDs = Self.heldTripIDs(result)
        removalKey = result == nil ? nil : key
        removalInputs = result == nil ? nil : inputs
        return result != nil
    }
}
