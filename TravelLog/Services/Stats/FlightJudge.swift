//
//  FlightJudge.swift
//  TravelLog
//
//  One deterministic answer to "did the user fly here?", shared by the
//  inferer that records flights (`TransitInferer`) and the Flight Log that
//  suggests them (`CollectionsAggregator`), so the two never disagree.
//
//  # Model
//
//  - **Journeys, not stay pairs.** The timeline is cut at anchors: an
//    airport stay, a stay the user spent at least `anchorDwellSeconds` in,
//    a stay followed by a long silence, or the newest or oldest stay. The brief stays
//    between two anchors (fixes in the air, in a car, on a ferry, a photo on
//    the way) are the journey's waypoints. A flight belongs to the journey,
//    and is kept on its first stay after the origin: the stay whose
//    `transitFromPreviousRaw` holds it.
//  - **The window.** A stored stay end may be a measured Visit departure or
//    a speculative clustering extension. Retained member fixes and Visits
//    supply explicit observed bounds; a missing last observation uses the
//    stored start as the widest known departure bound. Automatic authority
//    requires retained observations at both ends. Photo times add
//    `photoClockSlackSeconds`; a raw impossible speed stays review evidence.
//  - **Bad data.** A stay overlapping a far one (`conflictKm`), and a
//    stray (a far stay the timeline comes straight back from, quicker than
//    flying out and back: another person's photo in a shared library, one
//    bad fix), is never a journey's end or a fix in the air.
//  - **Modes.** For each way of travelling the judge knows the fastest
//    door-to-door time anyone manages over the great-circle distance and the
//    usual time: road, high-speed rail, a ferry where the ends are on
//    different islands, and a flight with the drives to and from the
//    airports and the time spent in them. A window shorter than a mode's
//    fastest time rules that mode out; a long window rules nothing out (a
//    data gap is not evidence against flying).
//  - **Seen in the air.** Two fixes of the journey, one of them a waypoint,
//    far enough apart to outrun GPS and cluster error, reached faster than
//    any surface transport (rail tops out near 350 km/h, so `airborneKmh` on
//    land), on the way to the destination. Lower cross-water pace is useful
//    for review, but island names cannot rule out bridges or tunnels.
//  - **Airports.** An end inside a scheduled airport's ring flies from it;
//    across water only by the terminal (`islandAirportTerminalKm`), since a
//    small island's ring also holds its port. Any other end reaches the
//    nearest scheduled airport within `servingRadiusKm` by road, and the
//    flight's times include that drive.
//  - **Decision.** Recorded only when every surface mode is ruled out with
//    margin, or the phone was seen in the air, and a scheduled airport
//    serves both ends. Suggested when a flight fits the window and beats
//    what the ground usually manages, with airport or water evidence; a long
//    gap is suggested only over distances people rarely travel by land or
//    sea, or from or to an airport. One reason per decision, carrying its
//    numbers.
//
//  Pure values only: no models, no isolation. Walks are bounded after an
//  O(n log n) sort, including pathological simultaneous overlaps.
//

import Foundation

nonisolated enum FlightJudge {

    // MARK: - Inputs

    /// What the stored inbound mode says about the leg into a stay.
    nonisolated enum Mode: Sendable, Equatable {
        /// Not classified yet (`nil`).
        case pending
        case unknown
        case flight
        /// The user's Not a Flight.
        case notFlight
        /// A legacy CoreMotion-era ground mode: measured, if flaky.
        case ground

        init(raw: String?) {
            switch raw {
            case nil: self = .pending
            case TransitMode.unknown.rawValue: self = .unknown
            case TransitMode.flight.rawValue: self = .flight
            case TransitMode.notFlight.rawValue: self = .notFlight
            default: self = .ground
            }
        }
    }

    /// The fields of one stay the judge reads, copied once.
    nonisolated struct Stay: Sendable, Equatable {
        let id: UUID
        let start: Date
        let end: Date
        let latitude: Double
        let longitude: Double
        /// `Stay.isAirport`: inside an airport's 3 km ring.
        let isAirport: Bool
        let islandName: String?
        let pingCount: Int
        /// Photo-style timestamp caution, including mixed, shared and unknown
        /// import provenance. This flag does not label the source for the UI.
        let isPhoto: Bool
        let mode: Mode
        let firstObservedAt: Date?
        /// Last retained member fix or Visit observation. A stored stay end
        /// alone cannot distinguish a measured Visit departure from a ping
        /// stay's speculative midpoint extension.
        let lastObservedAt: Date?

        init(id: UUID, start: Date, end: Date, latitude: Double, longitude: Double,
             isAirport: Bool, islandName: String?, pingCount: Int, isPhoto: Bool, mode: Mode,
             lastObservedAt: Date? = nil, firstObservedAt: Date? = nil) {
            self.id = id
            self.start = start
            self.end = end
            self.latitude = latitude
            self.longitude = longitude
            self.isAirport = isAirport
            self.islandName = islandName
            self.pingCount = pingCount
            self.isPhoto = isPhoto
            self.mode = mode
            self.firstObservedAt = firstObservedAt
            self.lastObservedAt = lastObservedAt
        }

        /// Seconds spent here as stored, the clustering extension included.
        var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    }

    /// An airport the judge measures against.
    nonisolated struct Airport: Sendable, Equatable {
        let code: String
        let latitude: Double
        let longitude: Double
        /// Scheduled service (`AirportRecord.svc`, nil counting as true).
        let scheduled: Bool

        init(code: String, latitude: Double, longitude: Double, scheduled: Bool) {
            self.code = code
            self.latitude = latitude
            self.longitude = longitude
            self.scheduled = scheduled
        }
    }

    /// How the judge finds airports. `at` is the airport whose ring holds a
    /// point (any service, the `Stay.isAirport` radius); `serving` the
    /// nearest airport with scheduled service within `servingRadiusKm`.
    nonisolated struct Airports {
        let at: (Double, Double) -> Airport?
        let serving: (Double, Double) -> Airport?

        init(at: @escaping (Double, Double) -> Airport?,
             serving: @escaping (Double, Double) -> Airport?) {
            self.at = at
            self.serving = serving
        }
    }

    // MARK: - Tunables

    /// A stay this long (its extension aside) is a real place, an anchor.
    /// Single-fix stays logged on the move (in a car, on a ferry, in the
    /// air) dwell under ten minutes; a café, a port wait or a hotel lasts
    /// longer.
    static let anchorDwellSeconds: TimeInterval = 20 * 60
    /// A stay followed by this much silence is an anchor too: nobody is in
    /// transit through a photo taken the day before (unless the fixes on
    /// either side show it was in the air).
    static let anchorSilenceSeconds: TimeInterval = 2 * 3600
    /// Longest chain of stays one journey walks through.
    static let maxMembers = 48
    /// `StayClusterer.maxStayExtensionSeconds`: a closed stay's end runs at
    /// most this far into the silence after it.
    static let stayExtensionCapSeconds: TimeInterval = 12 * 3600
    /// Added to every window with a photo at either end. A photo's creation
    /// date is an absolute instant from the phone's clock; the slack covers
    /// a location the camera fixed a little before the shot.
    static let photoClockSlackSeconds: TimeInterval = 15 * 60
    /// How far a stay's centroid may sit from the fix that ended or began
    /// it: a single fix's error, or `StayClusterer.distanceThresholdMeters`.
    static let singleFixErrorKm: Double = 1.5
    static let clusterErrorKm: Double = 3
    /// Two fixes closer than this (after the error above) prove no speed.
    static let airborneMinKm: Double = 25
    /// Faster than any train (about 350 km/h at most) or car.
    static let airborneKmh: Double = 400
    /// Review evidence between islands. Bridge/tunnel topology is unknown,
    /// so this lower threshold never grants automatic airborne authority.
    static let airborneOverWaterKmh: Double = 250
    /// Faster than an airliner with the jet stream behind it: two fixes this
    /// far apart this soon are bad data (a photo's clock, a stray fix), not
    /// a flight.
    static let impossibleKmh: Double = 1_100
    /// How many stays ahead a fix is compared with, for dense fixes.
    static let airborneLookahead = 4
    /// From the faster pair's first fix on, the journey keeps at least this
    /// pace to its destination: a stray fix on a drive does not.
    static let airborneOnwardKmh: Double = 150
    /// A stay overlapping one this far away in time is bad data: nobody is
    /// in two places at once (five cluster radii apart).
    static let conflictKm: Double = 15

    /// Fastest door-to-door road average over the great circle (a clear
    /// motorway, no stops).
    static let roadFastestKmh: Double = 130
    /// Usual road: 1.3 times the great circle at 80 km/h, plus getting going.
    static let roadDetour: Double = 1.3
    static let roadUsualKmh: Double = 80
    static let roadUsualOverheadHours: Double = 0.25
    /// The fastest scheduled rail nets about 250 km/h over the great circle
    /// station to station; a station at each end costs a quarter hour.
    /// Between two airports with their own stations, about 210 km/h and a
    /// few minutes.
    static let railFastestKmh: Double = 250
    static let railFastestOverheadHours: Double = 0.25
    static let airportRailFastestKmh: Double = 210
    static let airportRailFastestOverheadHours: Double = 0.1
    static let railUsualKmh: Double = 120
    static let railUsualOverheadHours: Double = 0.5
    /// The fastest catamarans net nearly 80 km/h over the great circle from
    /// the last fix at one port to the first at the other (40 to 77 km/h
    /// measured on island routes). A usual ferry sails 35 km/h on a route
    /// 1.2 times the great circle, with an hour at the ports.
    static let ferryFastestKmh: Double = 80
    static let ferryFastestOverheadHours: Double = 0
    static let ferryDetour: Double = 1.2
    static let ferryUsualKmh: Double = 35
    static let ferryUsualOverheadHours: Double = 1
    /// A flight at its fastest: the drive to and from the airports at 100
    /// km/h, a last fix at the gate a few minutes before pushback (half an
    /// hour from the kerb), 850 km/h in the air, a fifth of an hour climbing,
    /// descending and taxiing, and a first fix minutes after landing (or a
    /// fifth of an hour to the kerb).
    static let flightAccessFastestKmh: Double = 100
    static let flightDepartureFastestHours: (atAirport: Double, elsewhere: Double) = (0.15, 0.5)
    static let flightCruiseKmh: Double = 850
    static let flightClimbHours: Double = 0.2
    static let flightArrivalFastestHours: (atAirport: Double, elsewhere: Double) = (0.05, 0.2)
    /// A usual flight: 50 km/h to the airport, an hour and a half before
    /// departure (three quarters from inside), the block time, half an hour
    /// out (a quarter from inside).
    static let flightAccessUsualKmh: Double = 50
    static let flightDepartureUsualHours: (atAirport: Double, elsewhere: Double) = (0.75, 1.5)
    static let flightArrivalUsualHours: (atAirport: Double, elsewhere: Double) = (0.25, 0.5)
    /// A window this much shorter than a flight's fastest time still fits
    /// one (the fastest times are estimates).
    static let flightFitSlack: Double = 0.85

    /// A scheduled airport this close serves a place.
    static let servingRadiusKm: Double = 100
    /// Across water, an end is at its airport only this close to the
    /// airport's point. A small island's airport ring (3 km) also holds the
    /// town and the port beside the runway: the terminal stays measured lie
    /// within 1.5 km, the ports 2 km and more out. A larger airport's own
    /// grounds reach further, but only island crossings end at a port.
    static let islandAirportTerminalKm: Double = 1.75
    /// Recording needs the window this many times shorter than the fastest
    /// surface time (itself the fastest anyone manages anywhere), over at
    /// least `recordMinKm`.
    static let recordMargin: Double = 1.15
    static let recordMinKm: Double = 100
    /// Seen in the air: the journey must still move this far, with the fix
    /// in the air within this long of leaving the origin.
    static let seenInAirMinKm: Double = 50
    static let seenInAirMaxLeadSeconds: TimeInterval = 18 * 3600
    /// Nothing shorter is suggested.
    static let suggestMinKm: Double = 80
    /// "Too far to travel by land in this time": from or to an airport.
    static let overlandMinKm: Double = 300
    /// Long gaps: only over distances rarely travelled by land...
    static let longGapMinKm: Double = 1000
    /// ...or shorter ones first or last seen at an airport: beyond a three
    /// hour drive (about 325 km of road), or across water beyond a short
    /// ferry crossing or a bridge, once the window outlasts the usual ferry.
    /// Water alone proves nothing over a
    /// long gap: ferries cover most crossings this long, and river islands
    /// carry island names too.
    static let longGapAirportMinKm: Double = 250
    static let longGapWaterAirportMinKm: Double = 150
    /// A stray: a stay at least this far from the stays on either side of
    /// it, which lie within `strayReturnFraction` of that distance of each
    /// other (at least `strayReturnKm`), the round trip quicker than two
    /// usual flights (`blockHours` plus an hour at the airports each way)
    /// and the time spent there. Another person's photo in a shared
    /// library, or one bad fix: nobody flies out and back that fast.
    static let strayMinKm: Double = 100
    static let strayReturnKm: Double = 30
    static let strayReturnFraction: Double = 0.1
    static let strayAirportHours: Double = 1
    /// Airport to airport fits a flight with this much waiting around.
    static let airportToAirportSpareHours: Double = 2

    // MARK: - Block time

    /// Hours in the air for a flight this far: 780 km/h averaged over climb
    /// and descent, plus half an hour for taxi and runway. The Flight Log's
    /// estimate and the judge's usual flight share it.
    static func blockHours(distanceKm: Double) -> Double {
        distanceKm / 780 + 0.5
    }

    // MARK: - Timeline

    /// Stays in start order with their chain links: `previous` is the latest
    /// stay ending before one starts (equal ends break on the larger
    /// uuidString, as the inferer's predecessor read does; a UUID twin is
    /// never its own), `next` the earliest stay whose previous it is.
    nonisolated struct Timeline {
        let stays: [Stay]
        /// Each stay's position in the input.
        let inputIndex: [Int]
        let previous: [Int?]
        let next: [Int?]
        /// Seconds of `end` beyond the last retained measured observation
        /// (or beyond start when backing is unavailable).
        let extensionSeconds: [TimeInterval]
        let isAnchor: [Bool]
        /// Overlaps a stay `conflictKm` or more away.
        let isConflicted: [Bool]
        /// Pathological active-overlap density exceeded the bounded exact
        /// comparison budget. These rows may still be reviewed.
        let overlapUncertain: [Bool]
        /// A far stay the timeline comes straight back from (`strayMinKm`):
        /// bad data, never a flight's end or a fix in the air.
        let isStray: [Bool]
        /// Bounded store readers explicitly disclose truncated overlap
        /// coverage. Incomplete evidence may suggest, never auto-record.
        let overlapCoverageComplete: Bool

        init(_ input: [Stay], overlapCoverageComplete: Bool = true) {
            self.overlapCoverageComplete = overlapCoverageComplete
            let order = input.indices.map { (index: $0, start: input[$0].start, key: input[$0].id.uuidString) }
                .sorted {
                    if $0.start != $1.start { return $0.start < $1.start }
                    if $0.key != $1.key { return $0.key < $1.key }
                    return $0.index < $1.index
                }
                .map(\.index)
            let stays = order.map { input[$0] }
            self.stays = stays
            self.inputIndex = order
            let count = stays.count
            let byEnd = (0..<count).map { (index: $0, end: stays[$0].end, key: stays[$0].id.uuidString) }
                .sorted {
                    if $0.end != $1.end { return $0.end < $1.end }
                    if $0.key != $1.key { return $0.key < $1.key }
                    return $0.index < $1.index
                }
            // Skip a whole suffix of UUID twins in constant time. They stay
            // distinct physical rows, but none is its own predecessor.
            var previousDifferent = [Int?](repeating: nil, count: count)
            for position in byEnd.indices where position > 0 {
                previousDifferent[position] = byEnd[position - 1].key == byEnd[position].key
                    ? previousDifferent[position - 1] : position - 1
            }
            var previous = [Int?](repeating: nil, count: count)
            for index in 0..<count {
                let start = stays[index].start
                var low = 0, high = byEnd.count
                while low < high {
                    let middle = (low + high) / 2
                    if byEnd[middle].end < start { low = middle + 1 } else { high = middle }
                }
                guard low > 0 else { continue }
                let last = low - 1
                let candidate = stays[byEnd[last].index].id == stays[index].id
                    ? previousDifferent[last] : last
                if let candidate { previous[index] = byEnd[candidate].index }
            }
            var next = [Int?](repeating: nil, count: count)
            for index in 0..<count {
                if let earlier = previous[index], next[earlier] == nil { next[earlier] = index }
            }
            var extensions = [TimeInterval](repeating: 0, count: count)
            for index in 0..<count {
                let stay = stays[index]
                // Without raw backing the earliest possible last observation
                // is the stored start. Guessing a midpoint narrows the window
                // and can grant flight authority that the data does not have.
                let measured = stay.lastObservedAt.flatMap { observed -> Date? in
                    observed >= stay.start && observed <= stay.end ? observed : nil
                } ?? stay.start
                extensions[index] = max(0, stay.end.timeIntervalSince(measured))
            }
            self.previous = previous
            self.next = next
            self.extensionSeconds = extensions
            var anchors = [Bool](repeating: false, count: count)
            for index in 0..<count {
                anchors[index] = FlightJudge.isAnchor(index, stays: stays, previous: previous, next: next,
                                                      extensions: extensions)
            }
            self.isAnchor = anchors
            // Compare every active interval, independent of how many newer
            // rows have intervened. Cap pathological simultaneous density,
            // disclosing omitted evidence instead of silently trusting it.
            let activeLimit = 512
            var active: [Int] = []
            var droppedUntil = Date.distantPast
            var conflicted = [Bool](repeating: false, count: count)
            var overlapUncertain = [Bool](repeating: false, count: count)
            for index in 0..<count {
                let stay = stays[index]
                active.removeAll { stays[$0].end <= stay.start }
                overlapUncertain[index] = droppedUntil > stay.start
                // Distinct input entries are physical rows. Logical UUID
                // twins still contradict one another when far apart.
                for earlier in active {
                    if FlightJudge.km(stays[earlier], stay) >= FlightJudge.conflictKm {
                        conflicted[index] = true
                        conflicted[earlier] = true
                    }
                }
                active.append(index)
                if active.count > activeLimit,
                   let position = active.indices.min(by: { stays[active[$0]].end < stays[active[$1]].end }) {
                    let dropped = active.remove(at: position)
                    overlapUncertain[dropped] = true
                    droppedUntil = max(droppedUntil, stays[dropped].end)
                }
            }
            self.isConflicted = conflicted
            self.overlapUncertain = overlapUncertain
            var strays = [Bool](repeating: false, count: count)
            for index in 0..<count {
                guard let earlier = previous[index], let later = next[index] else { continue }
                let out = FlightJudge.km(stays[earlier], stays[index])
                let back = FlightJudge.km(stays[index], stays[later])
                let gap = FlightJudge.km(stays[earlier], stays[later])
                guard out >= FlightJudge.strayMinKm, back >= FlightJudge.strayMinKm,
                      gap <= max(FlightJudge.strayReturnKm, FlightJudge.strayReturnFraction * min(out, back))
                else { continue }
                var window = stays[later].start.timeIntervalSince(
                    stays[earlier].end.addingTimeInterval(-extensions[earlier]))
                if stays[earlier].isPhoto || stays[index].isPhoto || stays[later].isPhoto {
                    window += FlightJudge.photoClockSlackSeconds
                }
                let dwell = stays[index].duration - extensions[index]
                let flights = FlightJudge.blockHours(distanceKm: out) + FlightJudge.blockHours(distanceKm: back)
                    + 2 * FlightJudge.strayAirportHours
                strays[index] = window < flights * 3600 + dwell
            }
            self.isStray = strays
        }

        /// The last time the phone saw the user at `index` before the next
        /// stay began: its end less the extension clustering added.
        func lastSeen(_ index: Int) -> Date {
            stays[index].end.addingTimeInterval(-extensionSeconds[index])
        }

        /// The journey whose stays after the origin hold `index`; nil when
        /// it has no origin.
        func journey(containing index: Int) -> Journey? {
            var members = [index]
            var cursor = index
            while let earlier = previous[cursor], !isAnchor[earlier], members.count < FlightJudge.maxMembers {
                members.insert(earlier, at: 0)
                cursor = earlier
            }
            guard let origin = previous[cursor] else { return nil }
            cursor = index
            while !isAnchor[cursor], let later = next[cursor], members.count < FlightJudge.maxMembers {
                members.append(later)
                cursor = later
            }
            return Journey(origin: origin, members: members)
        }

        /// Every journey, each ending at an anchor (or where a chain is cut).
        func journeys() -> [Journey] {
            var result: [Journey] = []
            for index in stays.indices where isAnchor[index] || next[index] == nil {
                var members = [index]
                var cursor = index
                while let earlier = previous[cursor], !isAnchor[earlier], members.count < FlightJudge.maxMembers {
                    members.insert(earlier, at: 0)
                    cursor = earlier
                }
                guard let origin = previous[cursor] else { continue }
                result.append(Journey(origin: origin, members: members))
            }
            return result
        }
    }

    /// An origin anchor and the stays after it, the last one the
    /// destination.
    nonisolated struct Journey: Sendable, Equatable {
        let origin: Int
        let members: [Int]
        /// The stay whose inbound leg holds the journey's flight.
        var first: Int { members[0] }
        var destination: Int { members[members.count - 1] }
    }

    private static func isAnchor(
        _ index: Int, stays: [Stay], previous: [Int?], next: [Int?], extensions: [TimeInterval]
    ) -> Bool {
        // The newest stay, and the oldest: nothing is known past either.
        guard let later = next[index], previous[index] != nil else { return true }
        let stay = stays[index]
        let dwell = stay.duration - extensions[index]
        if dwell >= anchorDwellSeconds { return true }
        let silence = stays[later].start.timeIntervalSince(stay.end) + extensions[index]
        // A fix with the air on both sides of it is the plane passing,
        // never a place: an airport's ring overflown, or one fix in a long
        // silence mid-flight. A landing has the ground after it.
        func inTheAir() -> Bool {
            guard let earlier = previous[index] else { return false }
            let earlierSeen = stays[earlier].end.addingTimeInterval(-extensions[earlier])
            let lastSeen = stay.end.addingTimeInterval(-extensions[index])
            guard let before = segmentKmh(stays[earlier], seenAt: earlierSeen, stay),
                  before > airborneBar(stays[earlier], stay),
                  let after = segmentKmh(stay, seenAt: lastSeen, stays[later]),
                  after > airborneBar(stay, stays[later]) else { return false }
            return true
        }
        if stay.isAirport { return !(dwell < 5 * 60 && inTheAir()) }
        if silence >= anchorSilenceSeconds { return !inTheAir() }
        return false
    }

    // MARK: - Geometry

    /// Great-circle km (spherical, antimeridian safe).
    static func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = min(1, max(0, sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        ))
        return 6_371 * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    static func km(_ a: Stay, _ b: Stay) -> Double {
        haversineKm(a.latitude, a.longitude, b.latitude, b.longitude)
    }

    /// Different islands, or an island and the mainland. Islands joined by
    /// bridges or tunnels read as water too: recording never relies on it.
    static func crossesWater(_ a: Stay, _ b: Stay) -> Bool {
        let from = a.islandName ?? "", to = b.islandName ?? ""
        return from != to && (!from.isEmpty || !to.isEmpty)
    }

    private static func fixError(_ stay: Stay) -> Double {
        stay.pingCount <= 1 ? singleFixErrorKm : clusterErrorKm
    }

    private static func airborneBar(_ a: Stay, _ b: Stay) -> Double {
        crossesWater(a, b) ? airborneOverWaterKmh : airborneKmh
    }

    /// The slowest average speed the data allows from `a` (last seen at
    /// `seenAt`) to `b`'s first fix, nil under `airborneMinKm`.
    private static func segmentKmh(_ a: Stay, seenAt: Date, _ b: Stay) -> Double? {
        let distance = km(a, b) - fixError(a) - fixError(b)
        guard distance >= airborneMinKm else { return nil }
        var seconds = b.start.timeIntervalSince(seenAt)
        if a.isPhoto || b.isPhoto { seconds += photoClockSlackSeconds }
        guard seconds > 0 else { return nil }
        return distance / (seconds / 3600)
    }

    /// Clock slack may explain a raw overspeed, but that explanation remains
    /// review evidence. Automatic airborne evidence must be physically
    /// plausible before slack and exceed the ordinary land-speed threshold.
    private static func automaticAirborneKmh(_ a: Stay, seenAt: Date, _ b: Stay) -> Double? {
        // Use two retained observations. A destination stay may last much
        // longer than its first fix; using its later measured observation
        // only weakens this speed claim, without pretending its stored start
        // is a measured timestamp in synthetic imported history.
        guard a.lastObservedAt == seenAt, let arrived = b.lastObservedAt else { return nil }
        let seconds = arrived.timeIntervalSince(seenAt)
        let distance = km(a, b) - fixError(a) - fixError(b)
        guard seconds > 0, distance >= airborneMinKm,
              distance / (seconds / 3600) <= impossibleKmh else { return nil }
        let uncertainty = a.isPhoto || b.isPhoto ? photoClockSlackSeconds : 0
        let speed = distance / ((seconds + uncertainty) / 3600)
        guard speed > airborneKmh, speed <= impossibleKmh else { return nil }
        return speed
    }

    // MARK: - Assessment

    /// A mode's fastest and usual door-to-door hours.
    nonisolated struct ModeHours: Sendable, Equatable, Codable {
        let fastest: Double
        let usual: Double
    }

    /// Everything the decision compares, kept for the reason and the Flight
    /// Log's detail sheet.
    nonisolated struct Assessment: Sendable, Equatable, Codable {
        /// Origin to destination, great circle.
        let distanceKm: Double
        /// From the origin's last fix to the destination's first, at most.
        let windowSeconds: TimeInterval
        let lastSeenAtOrigin: Date
        /// Timestamp caution at either end (its clock may be off).
        let photoEnd: Bool
        let crossesWater: Bool
        let originAtAirport: Bool
        let destinationAtAirport: Bool
        /// Different airports at both ends.
        let airportToAirport: Bool
        /// A scheduled airport serves both ends.
        let served: Bool
        /// The fastest segment seen in the air, km/h.
        let airborneKmh: Double?
        /// Seconds from the origin's last fix to that segment's end.
        let airborneLeadSeconds: TimeInterval?
        let automaticAirborneKmh: Double?
        let automaticAirborneLeadSeconds: TimeInterval?
        let recordingEvidenceComplete: Bool?
        /// Automatic whole-window authority uses real retained observations
        /// at both ends. Synthetic imported timestamps remain review evidence.
        let automaticWindowSeconds: TimeInterval?
        let road: ModeHours
        let rail: ModeHours
        /// Only across water.
        let ferry: ModeHours?
        /// nil when no scheduled airport serves an end.
        let flight: ModeHours?

        var windowHours: Double { windowSeconds / 3600 }
        /// The fastest any surface mode manages (a bridge may exist, so the
        /// road and rail count across water too).
        var surfaceFastestHours: Double { min(road.fastest, rail.fastest) }
        /// What the road or rail usually take (a bridge may exist).
        var surfaceUsualHours: Double { min(road.usual, rail.usual) }
        var flightFits: Bool {
            guard let flight else { return false }
            return windowHours >= flight.fastest * FlightJudge.flightFitSlack
        }
    }

    /// The comparison for `journey`; nil when its window is empty.
    static func assess(_ journey: Journey, in timeline: Timeline, airports: Airports) -> Assessment? {
        let stays = timeline.stays
        guard !timeline.isConflicted[journey.origin], !timeline.isConflicted[journey.destination],
              !timeline.isStray[journey.origin], !timeline.isStray[journey.destination] else { return nil }
        let origin = stays[journey.origin]
        let destination = stays[journey.destination]
        let lastSeen = timeline.lastSeen(journey.origin)
        let firstSeen = destination.firstObservedAt.flatMap { observed -> Date? in
            observed >= destination.start && observed <= destination.end ? observed : nil
        } ?? destination.start
        var window = firstSeen.timeIntervalSince(lastSeen)
        guard window > 0 else { return nil }
        if origin.isPhoto || destination.isPhoto { window += photoClockSlackSeconds }
        let distance = km(origin, destination)
        let water = crossesWater(origin, destination)
        var automaticWindow: TimeInterval?
        if let departed = origin.lastObservedAt, let arrived = destination.firstObservedAt,
           departed >= origin.start, departed <= origin.end,
           arrived >= destination.start, arrived <= destination.end, arrived > departed {
            automaticWindow = arrived.timeIntervalSince(departed)
                + (origin.isPhoto || destination.isPhoto ? photoClockSlackSeconds : 0)
        }

        // An end inside a scheduled airport's ring (across water, by its
        // terminal) flies from it; any other drives to the nearest
        // scheduled airport.
        func ends(_ stay: Stay) -> (at: Airport?, airport: Airport?, access: Double?) {
            let at = airports.at(stay.latitude, stay.longitude).flatMap { airport -> Airport? in
                guard airport.scheduled else { return nil }
                guard water else { return airport }
                let km = haversineKm(stay.latitude, stay.longitude, airport.latitude, airport.longitude)
                return km <= islandAirportTerminalKm ? airport : nil
            }
            if let at { return (at, at, 0) }
            guard let serving = airports.serving(stay.latitude, stay.longitude) else { return (nil, nil, nil) }
            let km = haversineKm(stay.latitude, stay.longitude, serving.latitude, serving.longitude)
            return km <= servingRadiusKm ? (nil, serving, km) : (nil, nil, nil)
        }
        let from = ends(origin), to = ends(destination)
        let originAt = from.at, destinationAt = to.at

        let road = ModeHours(
            fastest: distance / roadFastestKmh,
            usual: distance * roadDetour / roadUsualKmh + roadUsualOverheadHours)
        let airportToAirport = originAt != nil && destinationAt != nil && originAt?.code != destinationAt?.code
        let rail = ModeHours(
            fastest: airportToAirport
                ? distance / airportRailFastestKmh + airportRailFastestOverheadHours
                : distance / railFastestKmh + railFastestOverheadHours,
            usual: distance / railUsualKmh + railUsualOverheadHours)
        let ferry = water ? ModeHours(
            fastest: distance / ferryFastestKmh + ferryFastestOverheadHours,
            usual: distance * ferryDetour / ferryUsualKmh + ferryUsualOverheadHours) : nil
        var flight: ModeHours?
        if let originAccess = from.access, let destinationAccess = to.access,
           let departure = from.airport, let arrival = to.airport {
            let air = haversineKm(departure.latitude, departure.longitude, arrival.latitude, arrival.longitude)
            let fromAirport = originAt != nil, toAirport = destinationAt != nil
            let fastest = originAccess / flightAccessFastestKmh + destinationAccess / flightAccessFastestKmh
                + (fromAirport ? flightDepartureFastestHours.atAirport : flightDepartureFastestHours.elsewhere)
                + air / flightCruiseKmh + flightClimbHours
                + (toAirport ? flightArrivalFastestHours.atAirport : flightArrivalFastestHours.elsewhere)
            let usual = originAccess / flightAccessUsualKmh + destinationAccess / flightAccessUsualKmh
                + (fromAirport ? flightDepartureUsualHours.atAirport : flightDepartureUsualHours.elsewhere)
                + blockHours(distanceKm: air)
                + (toAirport ? flightArrivalUsualHours.atAirport : flightArrivalUsualHours.elsewhere)
            flight = ModeHours(fastest: fastest, usual: usual)
        }

        // Seen in the air: the fastest pair of fixes, each compared with the
        // few after it, moving toward the destination. A waypoint must be
        // one of them: the origin to the destination is the window's test.
        // Strays and conflicting stays are bad data, never in the air.
        let chain = ([journey.origin] + journey.members).filter {
            $0 == journey.origin || $0 == journey.destination
                || (!timeline.isStray[$0] && !timeline.isConflicted[$0])
        }
        var airborne: (kmh: Double, lead: TimeInterval)?
        var automaticAirborne: (kmh: Double, lead: TimeInterval)?
        for i in chain.indices {
            let a = stays[chain[i]]
            let seenAt = timeline.lastSeen(chain[i])
            for j in (i + 1)..<min(chain.count, i + 1 + airborneLookahead) where i > 0 || j < chain.count - 1 {
                let b = stays[chain[j]]
                guard let speed = segmentKmh(a, seenAt: seenAt, b), speed > airborneBar(a, b),
                      speed <= impossibleKmh else { continue }
                let progress = km(a, destination) - km(b, destination)
                guard progress >= 0.5 * km(a, b) else { continue }
                let onwardHours = firstSeen.timeIntervalSince(seenAt) / 3600
                guard onwardHours > 0, km(a, destination) / onwardHours >= airborneOnwardKmh else { continue }
                if speed > (airborne?.kmh ?? 0) {
                    airborne = (speed, b.start.timeIntervalSince(lastSeen))
                }
                if let automatic = automaticAirborneKmh(a, seenAt: seenAt, b),
                   automatic > (automaticAirborne?.kmh ?? 0) {
                    automaticAirborne = (automatic, (b.lastObservedAt ?? b.start).timeIntervalSince(lastSeen))
                }
            }
        }

        return Assessment(
            distanceKm: distance,
            windowSeconds: window,
            lastSeenAtOrigin: lastSeen,
            photoEnd: origin.isPhoto || destination.isPhoto,
            crossesWater: water,
            originAtAirport: originAt != nil,
            destinationAtAirport: destinationAt != nil,
            airportToAirport: airportToAirport,
            served: from.access != nil && to.access != nil,
            airborneKmh: airborne?.kmh,
            airborneLeadSeconds: airborne?.lead,
            automaticAirborneKmh: automaticAirborne?.kmh,
            automaticAirborneLeadSeconds: automaticAirborne?.lead,
            recordingEvidenceComplete: timeline.overlapCoverageComplete
                && ([journey.origin] + journey.members).allSatisfy { !timeline.overlapUncertain[$0] },
            automaticWindowSeconds: automaticWindow,
            road: road, rail: rail, ferry: ferry, flight: flight)
    }

    // MARK: - Decision

    /// Why a journey looks like a flight, strongest first.
    nonisolated enum Reason: String, Sendable, Equatable, Codable, CaseIterable {
        /// Two fixes on the way, faster than anything on the ground.
        case seenInAir
        /// Faster than any car or train manages over the distance.
        case tooFastForSurface
        /// From one airport straight to another.
        case airportToAirport
        /// Between islands, or an island and the mainland, faster than any
        /// ferry (from or to an airport, faster than a ferry plausibly
        /// manages: half way from the fastest to the usual).
        case acrossWater
        /// Faster than the road or rail usually manage: from or to an
        /// airport, or over a distance rarely travelled by land.
        case tooFarOverland
        /// A long gap over a distance rarely travelled by land, or from or to
        /// an airport.
        case longGap
    }

    nonisolated enum Decision: Sendable, Equatable {
        /// Write `.flight` without asking.
        case record(Reason)
        /// Offer it in the Flight Log.
        case suggest(Reason)
        case none
    }

    /// What the stays of the journey already say.
    nonisolated struct Context: Sendable, Equatable {
        /// A legacy ground mode on one of its legs: only impossible speed
        /// re-opens it, and never without the user.
        var measuredOnGround = false

        init(measuredOnGround: Bool = false) {
            self.measuredOnGround = measuredOnGround
        }
    }

    static func context(of journey: Journey, in timeline: Timeline) -> Context {
        Context(measuredOnGround: journey.members.contains { timeline.stays[$0].mode == .ground })
    }

    static func decide(_ a: Assessment, context: Context = Context()) -> Decision {
        guard a.served, a.flightFits else { return .none }
        let seenInAir = a.airborneKmh != nil && a.distanceKm >= seenInAirMinKm
        guard seenInAir || a.distanceKm >= suggestMinKm else { return .none }
        let surfaceRuledOut = a.windowHours * recordMargin < a.surfaceFastestHours
        if !context.measuredOnGround && a.recordingEvidenceComplete == true {
            if a.automaticAirborneKmh != nil, a.distanceKm >= seenInAirMinKm,
               let lead = a.automaticAirborneLeadSeconds, lead <= seenInAirMaxLeadSeconds {
                return .record(.seenInAir)
            }
            if let window = a.automaticWindowSeconds,
               window / 3600 * recordMargin < a.surfaceFastestHours,
               a.distanceKm >= recordMinKm { return .record(.tooFastForSurface) }
        }
        if context.measuredOnGround {
            // Measured on the ground: only what recording would accept.
            if seenInAir { return .suggest(.seenInAir) }
            if surfaceRuledOut { return .suggest(.tooFastForSurface) }
            return .none
        }
        if seenInAir { return .suggest(.seenInAir) }
        if a.windowHours < a.surfaceFastestHours { return .suggest(.tooFastForSurface) }
        if a.airportToAirport,
           a.windowHours < max(a.ferry?.usual ?? a.surfaceUsualHours,
                               (a.flight?.usual ?? 0) + airportToAirportSpareHours) {
            return .suggest(.airportToAirport)
        }
        // Across water over ferry distances; a longer crossing is a long
        // gap's to offer.
        if let ferry = a.ferry, a.distanceKm < longGapMinKm,
           a.windowHours < ferry.fastest
            || (a.windowHours < (ferry.fastest + ferry.usual) / 2
                && (a.originAtAirport || a.destinationAtAirport)) {
            return .suggest(.acrossWater)
        }
        let atAirport = a.originAtAirport || a.destinationAtAirport
        if a.windowHours < a.surfaceUsualHours {
            if a.distanceKm >= overlandMinKm, atAirport || a.distanceKm >= longGapMinKm {
                return .suggest(.tooFarOverland)
            }
            return .none
        }
        // Across water a shorter crossing counts once the window outlasts
        // the usual ferry.
        let shortCrossing = a.crossesWater && a.distanceKm >= longGapWaterAirportMinKm
            && a.windowHours >= a.ferry?.usual ?? 0
        if a.distanceKm >= longGapMinKm || (atAirport && (a.distanceKm >= longGapAirportMinKm || shortCrossing)) {
            return .suggest(.longGap)
        }
        return .none
    }

    // MARK: - Recording

    /// What the inferer may write for the stay at `index`: the verdict on
    /// the journey holding it, and the stay a flight would go on.
    nonisolated struct Recording: Sendable, Equatable {
        let journey: Journey?
        let assessment: Assessment?
        let decision: Decision
        /// The journey's first stay while the journey may still take a
        /// flight: no other stay of it holds a flight or the user's Not a
        /// Flight, none of its stays was dismissed in the Flight Log, and
        /// the first is `index` itself or an `.unknown` leg. nil otherwise.
        let target: Int?
    }

    static func recording(
        for index: Int, in timeline: Timeline, airports: Airports, dismissed: Set<UUID>
    ) -> Recording {
        guard let journey = timeline.journey(containing: index) else {
            return Recording(journey: nil, assessment: nil, decision: .none, target: nil)
        }
        let stays = timeline.stays
        let closed = journey.members.contains { member in
            if dismissed.contains(stays[member].id) { return true }
            guard member != index else { return false }
            return stays[member].mode == .flight || stays[member].mode == .notFlight
        }
        let first = journey.first
        let target = !closed && (first == index || stays[first].mode == .unknown) ? first : nil
        guard let assessment = assess(journey, in: timeline, airports: airports) else {
            return Recording(journey: journey, assessment: nil, decision: .none, target: target)
        }
        let decision = decide(assessment, context: context(of: journey, in: timeline))
        return Recording(journey: journey, assessment: assessment, decision: decision, target: target)
    }

    // MARK: - Pace

    /// The window's average in words, from the same comparison.
    nonisolated enum Pace: Sendable, Equatable {
        /// Over a day: the average proves nothing.
        case inconclusive
        /// Faster than any car or train.
        case onlyPlane
        /// Faster than any car; only a fast train comes close.
        case planeOrFastTrain
        /// Within what a car or train manages.
        case ground
        /// Slower than the road usually is.
        case slow
    }

    static func pace(_ a: Assessment) -> Pace {
        if a.windowSeconds > 24 * 3600 { return .inconclusive }
        if a.windowHours < a.surfaceFastestHours { return .onlyPlane }
        if a.windowHours < a.road.fastest { return .planeOrFastTrain }
        if a.windowHours < a.road.usual { return .ground }
        return .slow
    }
}
