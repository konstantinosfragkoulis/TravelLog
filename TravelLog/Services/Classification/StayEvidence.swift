//
//  StayEvidence.swift
//  TravelLog
//

import Foundation
import SwiftData

/// What a stay's own observations say about how long it lasted, derived at
/// classification time from what the store holds. Every duration-driven
/// decision (the duration rules, the heuristics' brief-stop and base tests,
/// their night exemption, and the sanity pass) reads it, so the three sites
/// cannot disagree.
///
/// Clustering closes a stay by extending its end halfway toward the next
/// observation, capped at 12 hours. For live data the silence between
/// fixes is itself evidence of staying, so the stored interval is the
/// dwell. A stay built only from photos has no such evidence: the user was
/// there from its first photo to its last, and may have stayed until the
/// next observation anywhere. Its dwell is that interval; a rule that needs a
/// short stay needs the whole interval short, one that needs a long stay or
/// a night needs the photos themselves to show it.
nonisolated struct StayEvidence: Sendable, Equatable {
    /// The stored interval, the clustering extension included.
    let storedMinutes: Int
    let storedOvernight: Bool
    /// The dwell is known only between `observedMinutes` and `boundMinutes`.
    let photoOnly: Bool
    /// First to last member observation.
    let observedMinutes: Int
    /// The first observation spans solar 03:00 with the last.
    let observedOvernight: Bool
    /// First member observation to the next stay's start; nil when no later
    /// stay is known.
    let boundMinutes: Int?
    let isAirport: Bool
    /// The first and last member observation; a measured stay's stored
    /// interval.
    let firstObservation: Date
    let lastObservation: Date
    /// The stay spanned a night, or, photo-only, solar 03:00 came less than
    /// `nightLookaheadHours` after its last photo and before the next
    /// observation anywhere: the user may have slept there.
    let nightPossible: Bool

    /// How long after a stay's last photo a solar 03:00 still leaves a night
    /// there possible.
    static let nightLookaheadHours = 7

    /// The stored interval is the dwell.
    init(measured stay: Stay) {
        storedMinutes = stay.durationMinutes
        storedOvernight = Self.spansNight(from: stay.startTime, to: stay.endTime, longitude: stay.centroidLongitude)
        photoOnly = false
        observedMinutes = stay.durationMinutes
        observedOvernight = storedOvernight
        boundMinutes = stay.durationMinutes
        isAirport = stay.isAirport
        firstObservation = stay.startTime
        lastObservation = stay.endTime
        nightPossible = storedOvernight
    }

    /// A photo-only stay whose photos span `firstObservation...lastObservation`.
    init(photos stay: Stay, firstObservation: Date, lastObservation: Date, nextStart: Date?) {
        storedMinutes = stay.durationMinutes
        storedOvernight = Self.spansNight(from: stay.startTime, to: stay.endTime, longitude: stay.centroidLongitude)
        photoOnly = true
        observedMinutes = max(0, Int(lastObservation.timeIntervalSince(firstObservation) / 60))
        observedOvernight = Self.spansNight(from: firstObservation, to: lastObservation,
                                            longitude: stay.centroidLongitude)
        let bound = nextStart.map { max(0, Int($0.timeIntervalSince(firstObservation) / 60)) }
        boundMinutes = bound
        isAirport = stay.isAirport
        self.firstObservation = firstObservation
        self.lastObservation = lastObservation
        nightPossible = Self.photoNightPossible(first: firstObservation, last: lastObservation,
                                                nextStart: nextStart, longitude: stay.centroidLongitude)
    }

    /// Whether a photo-only stay whose photos span `first...last`, with
    /// the next stay starting at `nextStart` (nil when none is known), may
    /// hold a night: its photos span solar 03:00, or 03:00 falls in the
    /// unobserved time after the last photo, until the next stay's exact
    /// start (not the whole-minute bound) and at most the lookahead.
    static func photoNightPossible(first: Date, last: Date, nextStart: Date?, longitude: Double) -> Bool {
        var unobservedEnd = last.addingTimeInterval(Double(Self.nightLookaheadHours) * 3600)
        if let nextStart {
            unobservedEnd = min(unobservedEnd, nextStart)
        }
        return Self.spansNight(from: first, to: last, longitude: longitude)
            || Self.spansNight(from: last, to: unobservedEnd, longitude: longitude)
    }

    private static func spansNight(from start: Date, to end: Date, longitude: Double) -> Bool {
        CollectionsAggregator.intervalCrossesSolarHour(start: start, end: end, longitude: longitude, hour: 3)
    }

    /// The dwell was certainly shorter than `minutes`.
    func isShorter(than minutes: Int) -> Bool {
        guard let boundMinutes else { return false }
        return (photoOnly ? boundMinutes : storedMinutes) < minutes
    }

    /// The dwell certainly lasted at least `minutes`.
    func lasted(atLeast minutes: Int) -> Bool {
        (photoOnly ? observedMinutes : storedMinutes) >= minutes
    }

    /// The stay certainly spanned a night.
    var spansNight: Bool { photoOnly ? observedOvernight : storedOvernight }

    /// A short stop the duration rule settles as transit: the stored
    /// interval is at most `shortStopMinutes`, and for photos the next
    /// observation came soon enough to bound it (a stay no later
    /// observation closed was never extended, so its stored interval is
    /// only its photos).
    var isShortStop: Bool {
        guard storedMinutes <= StayClassificationInputs.shortStopMinutes else { return false }
        guard photoOnly else { return true }
        return boundMinutes.map { $0 <= 2 * StayClassificationInputs.shortStopMinutes } ?? false
    }

    /// An airport stay shorter than a day that shows no night. The place
    /// decides, unless the user observably slept there (an airport hotel):
    /// a night-spanning one is judged like any other stay.
    var isAirportStop: Bool { isAirport && storedMinutes < 24 * 60 && !spansNight }

    /// Observably brief: a measured dwell under an hour, or photos spanning
    /// under 45 minutes (a photo stay's stored interval is mostly
    /// clustering's extension, so only its photos show it brief).
    var isBrief: Bool {
        photoOnly ? observedMinutes < StayClassificationInputs.briefPhotoSpanMinutes : storedMinutes < 60
    }

    /// No transit lasts five days.
    var isLongStay: Bool { lasted(atLeast: 5 * 24 * 60) }

    /// The category the duration rules alone settle, or nil when only
    /// context can decide. Stage 2a and the sanity pass both read this.
    var settledCategory: StayCategory? {
        if isLongStay { return .destination }
        if isAirportStop || isShortStop { return .transit }
        return nil
    }

    /// The category the sanity pass moves a stay in `category` to, or nil
    /// when its evidence fits its category.
    func sanityCorrection(of category: StayCategory) -> StayCategory? {
        switch category {
        case .transit: return isLongStay ? .destination : nil
        case .destination: return isAirportStop || isShortStop ? .transit : nil
        default: return nil
        }
    }
}

extension TripClassifier {

    /// Evidence for `stays`, keyed by row. A stay's next stay is the first
    /// in `timeline` (classification order) starting after it, or, without
    /// a timeline, the first such stay the store holds. A photo-only stay's
    /// observation times are its member pings'; one whose pings are not all
    /// in the store keeps its stored interval as its dwell. A failed read
    /// throws.
    func stayEvidence(for stays: [Stay], timeline: [Stay]?,
                      in context: ModelContext? = nil) throws -> [ObjectIdentifier: StayEvidence] {
        let context = context ?? modelContext
        let photos = stays.filter { $0.source == .photoImport }
        var result: [ObjectIdentifier: StayEvidence] = [:]
        for stay in stays where stay.source != .photoImport {
            result[ObjectIdentifier(stay)] = StayEvidence(measured: stay)
        }
        guard !photos.isEmpty else { return result }

        // Member observation times, read once for every multi-photo stay.
        let wanted = Array(Set(photos.map(\.pingIDs).filter { $0.count > 1 }.joined()))
        var times: [UUID: Date] = [:]
        if !wanted.isEmpty {
            var descriptor = FetchDescriptor<LocationPing>(predicate: #Predicate { wanted.contains($0.id) })
            descriptor.propertiesToFetch = [\.id, \.timestamp]
            for ping in try context.fetch(descriptor) where !ping.isDeleted {
                times[ping.id] = min(times[ping.id] ?? ping.timestamp, ping.timestamp)
            }
        }
        let starts = timeline.map { $0.map(\.startTime) }
        for stay in photos {
            let next: Date?
            if let timeline, let starts {
                // The first start after this stay's own, by binary search.
                var low = 0, high = starts.count
                while low < high {
                    let middle = (low + high) / 2
                    if starts[middle] <= stay.startTime { low = middle + 1 } else { high = middle }
                }
                // A later-starting UUID twin is the same logical stay, not its successor.
                while low < timeline.count, timeline[low].id == stay.id { low += 1 }
                next = low < timeline.count ? starts[low] : nil
            } else {
                let start = stay.startTime
                let id = stay.id
                var descriptor = FetchDescriptor<Stay>(
                    predicate: #Predicate { $0.startTime > start && $0.id != id },
                    sortBy: [SortDescriptor(\.startTime)])
                descriptor.fetchLimit = 1
                next = try context.fetch(descriptor).first?.startTime
            }
            let ids = stay.pingIDs
            let observed = ids.count > 1 ? ids.compactMap { times[$0] } : []
            if ids.count > 1, observed.count != ids.count {
                result[ObjectIdentifier(stay)] = StayEvidence(measured: stay)
                continue
            }
            result[ObjectIdentifier(stay)] = StayEvidence(
                photos: stay,
                firstObservation: observed.min() ?? stay.startTime,
                lastObservation: observed.max() ?? stay.startTime,
                nextStart: next)
        }
        return result
    }
}
