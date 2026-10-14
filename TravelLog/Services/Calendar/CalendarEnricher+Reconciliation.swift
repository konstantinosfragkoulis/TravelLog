//
//  CalendarEnricher+Reconciliation.swift
//  TravelLog
//

@preconcurrency import EventKit
import Foundation
import CryptoKit
import SwiftData
import CoreLocation
import WeatherKit
import WidgetKit
import os.log

extension CalendarEnricher {

    nonisolated private static func canPreserveDeferredGrounding(_ row: PlannedTrip, for snapshot: CalendarEventSnapshot, timeZone: TimeZone) -> Bool {
        guard row.status == .upcoming, row.signals.contains(PlannedTripDetector.signalFMTieBreaker),
              row.resolvedLatitude != nil, row.resolvedLongitude != nil,
              snapshot.title.count <= maxPersistedTitleLength, row.title == snapshot.title,
              row.locationText == snapshot.locationText, row.isAllDay == snapshot.isAllDay else { return false }
        if snapshot.isAllDay {
            return PlannedTripDetector.renderedDayKey(row.startDate, timeZone: timeZone) == PlannedTripDetector.renderedDayKey(snapshot.startDate, timeZone: timeZone)
                && PlannedTripDetector.renderedDayKey(row.endDate, timeZone: timeZone) == PlannedTripDetector.renderedDayKey(snapshot.endDate, timeZone: timeZone)
        }
        return row.startDate == snapshot.startDate && row.endDate == snapshot.endDate
    }

    /// Whether a stored all-day start can be the floating date that
    /// `snapshotStart` renders as in `timeZone`. A row keeps only its writer's
    /// midnight, not the writer's zone, so this is the evidence it offers:
    /// the instant is that date's midnight at an offset a place uses (UTC-11
    /// to UTC+14; only Etc/GMT+12 has UTC-12), and it is not a midnight in
    /// the reader's own zone. A reader midnight was written at the reader's
    /// offset, so the day it renders on already is its floating date, and
    /// the exact key ruled that date out.
    /// A writer exactly 24 h east of the reader (UTC+14 against UTC-10)
    /// fails the second test and keeps the separate row an exact miss gives.
    ///
    /// The offset range spans 25 h, so a writer offset of +13 h or more also
    /// makes the instant the previous day's midnight 24 h further west, and
    /// one of -10 h or less makes it the next day's 24 h further east.
    /// `excludingAdjacentDays` rejects those instants: Honolulu's November 5
    /// is also November 6 at UTC+14.
    nonisolated static func allDayStart(
        _ storedStart: Date, canBeFloatingDayOf snapshotStart: Date, timeZone: TimeZone, excludingAdjacentDays: Bool
    ) -> Bool {
        var reader = Calendar(identifier: .gregorian)
        reader.timeZone = timeZone
        guard reader.startOfDay(for: storedStart) != storedStart else { return false }
        let day = reader.dateComponents([.year, .month, .day], from: snapshotStart)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = .gmt
        guard let floatingMidnight = utc.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else {
            return false
        }
        let realOffsets: ClosedRange<TimeInterval> = -11 * 3600...14 * 3600
        let writerOffset = floatingMidnight.timeIntervalSince(storedStart)
        guard realOffsets.contains(writerOffset) else { return false }
        guard excludingAdjacentDays else { return true }
        return !realOffsets.contains(writerOffset - 24 * 3600) && !realOffsets.contains(writerOffset + 24 * 3600)
    }

    /// Reconciles one scan's detections against the `PlannedTrip` table:
    /// upsert on the `(externalID ?? localID, startDate)` composite key,
    /// stale-sweep `.upcoming` rows whose source event vanished, then run
    /// retirement (match-to-real-`Trip` / expiry). Internal (not private)
    /// so tests can drive it with synthetic detections — the same seam
    /// `StatsAggregator`-style pure logic uses, since `EKEventStore` cannot
    /// be faked.
    ///
    /// `PlannedTrip` writes only — never touches `Stay`/`Trip` rows.
    /// Returns false when the reconcile cannot complete this pass.
    @discardableResult
    func applyScan(
        detections: [PlannedTripDetection],
        rejectedGeocodes: [CalendarEventSnapshot] = [],
        deferredGroundingSnapshots: [CalendarEventSnapshot] = [],
        now: Date,
        expectedEpoch: UInt64? = nil,
        timeZone: TimeZone = .current
    ) -> Bool {
        guard !Task.isCancelled, expectedEpoch == nil || expectedEpoch == calendarDataEpoch else {
            return false
        }
        // Abort rather than reconcile against a phantom empty table: read as
        // "no rows yet", a transient store error would insert a FRESH row for
        // every detection instead of updating the existing ones — and
        // `PlannedTripDeduplicator` only runs for iCloud users, so a
        // local-only account would keep those duplicates permanently.
        // Skipping this pass costs nothing: the next scan redoes the whole thing.
        guard let existing = try? modelContext.fetch(FetchDescriptor<PlannedTrip>()) else {
            logger.error("PlannedTrip fetch failed; skipping this reconcile rather than inserting duplicates.")
            return false
        }
        var byKey: [String: PlannedTrip] = [:]
        for row in existing {
            byKey[PlannedTripDetector.identityKey(
                externalIdentifier: row.eventExternalIdentifier,
                localIdentifier: row.eventLocalIdentifier,
                startDate: row.startDate,
                isAllDay: row.isAllDay,
                timeZone: timeZone
            )] = row
        }

        func clearStoredGeography(on row: PlannedTrip) {
            if row.resolvedLatitude != nil { row.resolvedLatitude = nil }
            if row.resolvedLongitude != nil { row.resolvedLongitude = nil }
            if row.resolvedLocality != nil { row.resolvedLocality = nil }
            if row.resolvedCountry != nil { row.resolvedCountry = nil }
            if row.resolvedISOCountryCode != nil { row.resolvedISOCountryCode = nil }
            if row.distanceFromHomeKm != nil { row.distanceFromHomeKm = nil }
            if row.forecastWeatherData != nil { row.forecastWeatherData = nil }
            failedForecastAt[row.id] = nil
        }

        // Resolve preservation BEFORE applying broad-query rejections. A broad
        // location may fail while the exact destination is merely unavailable;
        // erasing its coordinates first would defeat this conservative keep.
        var seenKeys = Set<String>()
        for snapshot in deferredGroundingSnapshots {
            let key = PlannedTripDetector.identityKey(for: snapshot, timeZone: timeZone)
            guard let row = byKey[key], Self.canPreserveDeferredGrounding(row, for: snapshot, timeZone: timeZone) else { continue }
            seenKeys.insert(key)
            if now.timeIntervalSince(row.lastSeenAt) > Self.lastSeenRefreshSeconds { row.lastSeenAt = now }
        }

        // A row created solely by legacy unscored distance may no longer be a
        // detection at all, so it will not appear in `detections`. Heal its
        // persisted evidence immediately without treating it as seen: the
        // ordinary stale grace can then retire the row safely.
        for snapshot in rejectedGeocodes {
            let key = PlannedTripDetector.identityKey(for: snapshot, timeZone: timeZone)
            guard !seenKeys.contains(key), let row = byKey[key] else { continue }
            clearStoredGeography(on: row)
            if let reevaluated = PlannedTripDetector.evaluate(snapshot) {
                if row.confidence != reevaluated.confidence { row.confidence = reevaluated.confidence }
                if row.signals != reevaluated.signals { row.signals = reevaluated.signals }
            } else {
                if row.confidence != .low { row.confidence = .low }
                let signals = row.signals.filter { $0 != PlannedTripDetector.signalFarFromHome }
                if row.signals != signals { row.signals = signals }
            }
        }

        // A stored all-day instant is the writer's midnight, so a reader
        // further west renders it on the PREVIOUS day and its key misses the
        // snapshot's. Exact keys win for every detection first; only then may
        // an unmatched all-day snapshot adopt the nearest same-event all-day
        // row that no detection's key already names and that can be the
        // snapshot's own floating date. Nearness alone is no evidence: the
        // previous or next occurrence of a series, or an event moved by a
        // day, starts just as near. Even the floating date is not unique
        // within an hour of either end of the offset range, so a recurring
        // occurrence adopts only a row that no real offset makes an adjacent
        // day: adopting its neighbour would hide this occurrence behind that
        // one's dismissal or match, while a separate row is at worst shown
        // again. A single event has no neighbour to take, and at worst keeps
        // its status across a one-day move. The all-day refresh below then
        // re-renders the adopted row's instants.
        let detectionKeys = detections.map { PlannedTripDetector.identityKey(for: $0.snapshot, timeZone: timeZone) }
        var resolved: [PlannedTrip?] = detectionKeys.map { byKey[$0] }
        let claimedKeys = Set(detectionKeys)
        for index in detections.indices where resolved[index] == nil && detections[index].snapshot.isAllDay {
            let snapshot = detections[index].snapshot
            let eventID = snapshot.externalIdentifier ?? snapshot.localIdentifier
            let hasOtherOccurrences = snapshot.hasRecurrenceRules || snapshot.isDetached
            let adopted = existing.filter { row in
                row.isAllDay
                    && (row.eventExternalIdentifier ?? row.eventLocalIdentifier) == eventID
                    && Self.allDayStart(row.startDate, canBeFloatingDayOf: snapshot.startDate, timeZone: timeZone,
                                        excludingAdjacentDays: hasOtherOccurrences)
                    && !resolved.contains { $0 === row }
                    && !claimedKeys.contains(PlannedTripDetector.identityKey(
                        externalIdentifier: row.eventExternalIdentifier,
                        localIdentifier: row.eventLocalIdentifier,
                        startDate: row.startDate,
                        isAllDay: row.isAllDay,
                        timeZone: timeZone
                    ))
            }.min { lhs, rhs in
                let lhsDistance = abs(lhs.startDate.timeIntervalSince(snapshot.startDate))
                let rhsDistance = abs(rhs.startDate.timeIntervalSince(snapshot.startDate))
                return lhsDistance != rhsDistance ? lhsDistance < rhsDistance : lhs.id.uuidString < rhs.id.uuidString
            }
            resolved[index] = adopted
        }

        for (index, detection) in detections.enumerated() {
            let snapshot = detection.snapshot
            let key = detectionKeys[index]
            seenKeys.insert(key)

            let title = String(snapshot.title.prefix(Self.maxPersistedTitleLength))
            let row: PlannedTrip
            if let existing = byKey[key] ?? resolved[index] {
                // Status is deliberately NOT touched, except for the expired
                // repair after the date refresh below: `.dismissed` is never
                // resurrected while the identity key holds, and
                // `.matched` is terminal.
                // Assign only actual changes throughout the update path —
                // same-value writes still dirty the row, and a dirty row
                // means a save plus a CloudKit export on every scan.
                row = existing
                // An adopted row now owns this key, so a later same-key
                // snapshot (the same invite in another calendar) reuses it.
                byKey[key] = row
                // Compare the full source before overwriting its stored text,
                // using the same conservative check as deferred grounding.
                if detection.resolved == nil, detection.geocodeDisposition == .notAttempted,
                   snapshot.title.count > Self.maxPersistedTitleLength || row.title != snapshot.title
                    || row.locationText != snapshot.locationText {
                    clearStoredGeography(on: row)
                }
                if row.title != title { row.title = title }
                // `startDate` refreshes like every other field: an all-day
                // event's absolute instant is re-rendered against the
                // device's CURRENT timezone while the identity key (the day
                // the event renders as) deliberately stays stable across that
                // shift, so without it a tz change would leave startDate at
                // the OLD zone's midnight while endDate refreshed, skewing the
                // card's dates/countdown and the widget's daysUntilStart.
                if snapshot.isAllDay {
                    // Refresh an all-day row's instants only when the intended
                    // start or end DAY changed.
                    // EventKit renders a floating midnight in the device's own
                    // zone, so two synced devices in different zones produce
                    // different absolute instants for the SAME day — and an
                    // unconditional refresh would make each device rewrite the
                    // other's value on every scan, a permanent write-war costing a
                    // save and a CloudKit export per scan on both devices, forever.
                    // Comparing the rendered day keeps the refresh's guarantee
                    // (a real date change still propagates). EventKit ends an
                    // all-day event at 23:59:59 of its last day in the device
                    // zone, so rewriting both fields on any mismatch would make
                    // two zones reverse each other forever. Fixing only the field
                    // that renders on the wrong day lets devices settle: the
                    // start on the westernmost device's midnight, the end on
                    // the easternmost device's last second, both of which
                    // render on the right days in every zone less than 24 h apart.
                    // Devices more than 24 h apart (UTC+14 and UTC-11) still
                    // alternate: no instant starts the same day in both, and
                    // settling would need the floating date stored on the row.
                    let storedDay = PlannedTripDetector.renderedDayKey(row.startDate, timeZone: timeZone)
                    let snapshotDay = PlannedTripDetector.renderedDayKey(snapshot.startDate, timeZone: timeZone)
                    let storedEndDay = PlannedTripDetector.renderedDayKey(row.endDate, timeZone: timeZone)
                    let snapshotEndDay = PlannedTripDetector.renderedDayKey(snapshot.endDate, timeZone: timeZone)
                    if storedDay != snapshotDay {
                        row.startDate = snapshot.startDate
                        if row.endDate != snapshot.endDate { row.endDate = snapshot.endDate }
                    } else if storedEndDay != snapshotEndDay {
                        row.endDate = snapshot.endDate
                    }
                } else {
                    if row.startDate != snapshot.startDate { row.startDate = snapshot.startDate }
                    if row.endDate != snapshot.endDate { row.endDate = snapshot.endDate }
                }
                if row.isAllDay != snapshot.isAllDay { row.isAllDay = snapshot.isAllDay }
                if row.locationText != snapshot.locationText { row.locationText = snapshot.locationText }
                // `.expired` means the source dates passed. A current
                // detection whose refreshed dates are still current is fresh
                // evidence against that, timed or all-day: an event extended
                // after it expired, another device expiring it on dates this
                // one already saw extended, or a row an earlier build left
                // expired after refreshing its end. Matched and dismissed
                // rows stay terminal.
                if row.status == .expired, row.currentUntil(timeZone: timeZone) >= now {
                    row.status = .upcoming
                }
            } else {
                row = PlannedTrip(
                    eventExternalIdentifier: snapshot.externalIdentifier,
                    eventLocalIdentifier: snapshot.localIdentifier,
                    title: title,
                    startDate: snapshot.startDate,
                    endDate: snapshot.endDate,
                    isAllDay: snapshot.isAllDay,
                    locationText: snapshot.locationText
                )
                modelContext.insert(row)
                row.lastSeenAt = now
                byKey[key] = row
            }
            if row.confidence != detection.confidence { row.confidence = detection.confidence }
            if row.signals != detection.signals { row.signals = detection.signals }
            // Refresh `lastSeenAt` only once meaningfully stale (see
            // `lastSeenRefreshSeconds`) — it was the one guaranteed-new
            // value that forced a save per scan.
            if now.timeIntervalSince(row.lastSeenAt) > Self.lastSeenRefreshSeconds {
                row.lastSeenAt = now
            }
            // Preserve unchanged-source geography across budget/offline/transient
            // misses, but actively clear a legacy V1 value when the V2 scorer
            // has definitively rejected the current event text. A wrong
            // coordinate must not keep supplying far-from-home or forecasts.
            if detection.geocodeDisposition == .rejected {
                clearStoredGeography(on: row)
            } else if let resolved = detection.resolved {
                if row.resolvedLatitude != resolved.place.latitude || row.resolvedLongitude != resolved.place.longitude {
                    row.forecastWeatherData = nil
                    failedForecastAt[row.id] = nil
                }
                if row.resolvedLatitude != resolved.place.latitude { row.resolvedLatitude = resolved.place.latitude }
                if row.resolvedLongitude != resolved.place.longitude { row.resolvedLongitude = resolved.place.longitude }
                if row.resolvedLocality != resolved.place.locality { row.resolvedLocality = resolved.place.locality }
                if row.resolvedCountry != resolved.place.country { row.resolvedCountry = resolved.place.country }
                if row.resolvedISOCountryCode != resolved.place.isoCountryCode { row.resolvedISOCountryCode = resolved.place.isoCountryCode }
                if row.distanceFromHomeKm != resolved.distanceFromHomeKm { row.distanceFromHomeKm = resolved.distanceFromHomeKm }
            }
        }

        // Stale sweep + retirement. Only `.upcoming` rows are ever swept or
        // retired; `.matched` is a historical record (its source event's
        // continued existence is irrelevant — the `YearWrapped` philosophy),
        // `.dismissed` is a terminal user state, and `.expired` returns only
        // through a current detection above.
        // Lazy: the full-Trip-table fetch is consumed ONLY by the
        // retirement branch below, so a scan with nothing to retire (the
        // common case — every scenePhase activation) shouldn't touch the
        // Trip table at all.
        var tripCandidates: [PlannedTripMatcher.TripCandidate]?
        for row in existing where row.status == .upcoming {
            let key = PlannedTripDetector.identityKey(
                externalIdentifier: row.eventExternalIdentifier,
                localIdentifier: row.eventLocalIdentifier,
                startDate: row.startDate,
                isAllDay: row.isAllDay,
                timeZone: timeZone
            )

            // An all-day row stays current until its last day ends in this
            // zone, however far east the device that wrote its end sits.
            let currentUntil = row.currentUntil(timeZone: timeZone)
            if currentUntil >= now {
                // Current/future event. If this scan didn't see it (deleted
                // at source, edited into a new identity, or dropped below
                // the detection threshold), age it out past the grace.
                if !seenKeys.contains(key), now.timeIntervalSince(row.lastSeenAt) > Self.staleGraceSeconds {
                    modelContext.delete(row)
                }
                continue
            }

            // Dates have passed: try to retire against a real trip; expire
            // after the grace when nothing matches.
            let candidates: [PlannedTripMatcher.TripCandidate]
            if let cached = tripCandidates {
                candidates = cached
            } else {
                do {
                    candidates = try fetchTripCandidates()
                } catch {
                    // A failed read cannot decide match versus expiry. Undo
                    // this reconcile so the next scan can retry every row.
                    modelContext.rollback()
                    logger.error("Trip candidate fetch failed; deferring calendar retirement: \(error.localizedDescription)")
                    return false
                }
                tripCandidates = candidates
            }
            if let match = PlannedTripMatcher.bestMatch(
                plannedStart: row.startDate,
                plannedEnd: row.endDate,
                candidates: candidates,
                now: now
            ) {
                row.matchedTripID = match
                row.status = .matched
            } else if now.timeIntervalSince(currentUntil) > Self.expiryGraceSeconds {
                row.status = .expired
            }
        }

        if modelContext.hasChanges {
            do {
                #if DEBUG
                if failNextScanSaveForTesting {
                    failNextScanSaveForTesting = false
                    throw CocoaError(.fileWriteUnknown)
                }
                #endif
                try modelContext.save()
                // Only a committed reconcile counts toward the widget reload.
                scanCycleMadeChanges = true
                logger.info("Calendar scan reconciled: \(detections.count) detection(s).")
            } catch {
                // Undo the unsaved reconcile so a later unrelated save on this
                // context cannot commit it; the next scan redoes it.
                modelContext.rollback()
                logger.error("Calendar scan save failed: \(error.localizedDescription)")
                return false
            }
        }
        return true
    }

    private func fetchTripCandidates() throws -> [PlannedTripMatcher.TripCandidate] {
        #if DEBUG
        if failTripCandidateFetchForTesting { throw CocoaError(.fileReadUnknown) }
        #endif
        let trips = try modelContext.fetch(FetchDescriptor<Trip>())
        // Provisional all-transit rows cannot consume a calendar match.
        let candidates = trips.filter {
            $0.isComplete || $0.userEdited
                || ($0.stays ?? []).contains { $0.category == .destination }
        }
        return candidates.map {
            PlannedTripMatcher.TripCandidate(id: $0.id, startDate: $0.startDate, endDate: $0.endDate)
        }
    }
}
