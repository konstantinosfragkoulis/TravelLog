//
//  HomeOrbit.swift
//  TravelLog
//
//  The home-area expansion engine: pure,
//  deriving learned "orbit" discs from qualifying same-day returns — the
//  mechanism that lets a cross-border commuter's office, the weekly market
//  over the border, or monthly Sundays at the parents' village become part
//  of HOME instead of minting trips forever.
//
//  scripts/home-orbit-replica.py is the independent Python oracle.
//  HomeOrbitTests checks parity with it using synthetic scenarios, including
//  refusal of short corridor dwells, overnight island visits and transit nodes.
//
//  # The rule
//
//  A CLUSTER (single-linkage, 1 km link, live non-transit stays only) earns a
//  disc valid at time t iff SOME 12-month window containing t holds >= 3
//  QUALIFYING RETURNS — excursions that (a) reached the cluster, (b) went
//  home the same day, (c) were not transit-only, and (d) dwelled >= 30 min at
//  the cluster. Clause (b) needs BOTH brackets witnessed by live stays inside
//  the seed: one before the excursion with observed support, and one starting
//  after every away observation within 12 h of the excursion's first start.
//  Its start is the return time. An excursion closed by an unknown gap or the
//  end of input never qualifies. K is a fixed 3: a distance-based threshold
//  can reject monthly routines that supply enough same-day returns.
//  The evidence requirements keep travel out: a short airport-corridor dwell
//  fails (d), an overnight island visit has no same-day return and fails (b),
//  and the terminal itself is a transit node (c). Evidence is counted against
//  SEED-ONLY excursions, once, never iterated: re-deriving against disc-inclusive
//  membership can make admission oscillate. With no distance term in K each
//  cluster qualifies independently, so runaway is
//  structurally impossible.
//
//  # What discs change and what they must never change
//
//  Discs extend MEMBERSHIP (a point inside a valid disc is home) and shorten
//  D. They never touch D*: the score's scale is always the SEED's area radius.
//  Letting the orbit inflate D* would suppress near-home trips.
//

import Foundation

/// Pure expansion engine. All inputs and outputs are Sendable values; the
/// caller owns fetching, home-era scoping and provenance filtering.
nonisolated enum HomeOrbit {

    // MARK: - Constants

    /// Clause (b): the witnessed home arrival must fall within this bounded
    /// window after the excursion's first start.
    static let returnWindowSeconds: TimeInterval = 12 * 3600

    /// Clause (d): minimum dwell AT the cluster for a visit to count.
    /// Brief passage through a corridor does not establish a routine place.
    static let dwellFloorSeconds: TimeInterval = 30 * 60

    /// Qualifying returns required in one window. FLAT — see the header.
    static let requiredReturns = 3

    /// The counting window. The shortest naturally de-seasonalised span
    /// (always contains one of each season).
    static let trailingWindowSeconds: TimeInterval = 365.25 * 24 * 3600

    /// Single-linkage link radius for grouping nearby routine stays.
    static let linkRadiusKm: Double = 1.0

    /// A disc is never smaller than this (matches `HomeShape.fallbackRadiusKm`
    /// conceptually: the minimum belief about a place's extent).
    static let discFloorRadiusKm: Double = 1.0

    // MARK: - Inputs

    /// One stay, reduced to what expansion needs. `isLive` is provenance:
    /// only live-SLC-observed stays anchor evidence or witness clause (b)'s
    /// home brackets (an imported timeline cannot witness a same-day return;
    /// refusing it undercounts, which is the safe direction).
    struct StayObservation: Sendable, Equatable {
        let id: UUID
        let start: Date
        let end: Date
        let latitude: Double
        let longitude: Double
        /// Airport (or future port/station): never anchors a cluster and
        /// never satisfies clause (a)/(d).
        let isTransitNode: Bool
        /// Own live evidence: live-SLC, or merged with a live fix or Visit of its
        /// own (carries an observed return); imports alone never do.
        let isLive: Bool

        init(id: UUID, start: Date, end: Date, latitude: Double, longitude: Double,
             isTransitNode: Bool, isLive: Bool) {
            self.id = id
            self.start = start
            self.end = max(start, end)
            self.latitude = latitude
            self.longitude = longitude
            self.isTransitNode = isTransitNode
            self.isLive = isLive
        }

        var confidenceInput: TripConfidence.StayInput {
            .init(id: id, start: start, end: end,
                  latitude: latitude, longitude: longitude,
                  isTransitNode: isTransitNode)
        }
    }

    // MARK: - Outputs

    /// A learned disc plus WHEN it applies. Derived, never persisted: a
    /// stored copy can go stale against stay history, the geocoder build and
    /// the home row. Only user overrides persist.
    struct OrbitDisc: Sendable, Equatable {
        let centerLatitude: Double
        let centerLongitude: Double
        let radiusKm: Double
        /// Closed validity windows, merged and sorted. A disc is home-area
        /// only at instants inside one of these.
        let validity: [DateInterval]
        /// Sorted qualifying-return times — the evidence, kept for the
        /// learned-places UI and the orbit fingerprint.
        let returnTimes: [Date]

        func isValid(at date: Date) -> Bool {
            validity.contains { $0.start <= date && date <= $0.end }
        }

        func covers(latitude: Double, longitude: Double, at date: Date) -> Bool {
            isValid(at: date) &&
            greatCircleKm(latitude, longitude, centerLatitude, centerLongitude) <= radiusKm
        }

        /// Distance beyond the disc's edge; 0 inside. Ignores validity —
        /// callers gate on `isValid` first.
        func distanceKm(toLatitude latitude: Double, longitude: Double) -> Double {
            max(0, greatCircleKm(latitude, longitude, centerLatitude, centerLongitude) - radiusKm)
        }

        /// The disc restricted to a home era. A disc's forward window (last
        /// return + 12 months) can outlive the home it belongs to; the era's
        /// end must win — otherwise a group straddling a home change is
        /// scored against a former home's disc for up to a year. Returns nil
        /// when nothing survives.
        func clamped(toEra era: DateInterval) -> OrbitDisc? {
            let windows = validity.compactMap { $0.intersection(with: era) }
                .filter { $0.duration > 0 }
            guard !windows.isEmpty else { return nil }
            return OrbitDisc(centerLatitude: centerLatitude,
                             centerLongitude: centerLongitude,
                             radiusKm: radiusKm,
                             validity: windows, returnTimes: returnTimes)
        }
    }

    /// Everything measured about one candidate cluster — admitted or not.
    /// The learned-places UI lists admitted ones; tests pin refusals.
    struct ClusterAudit: Sendable {
        let centerLatitude: Double
        let centerLongitude: Double
        let radiusKm: Double
        let stayCount: Int
        let qualifyingReturnTimes: [Date]
        let disc: OrbitDisc?
    }

    // MARK: - Derivation (one-shot, seed-only evidence)

    /// Derive the orbit for ONE home era. `observations` must already be
    /// scoped to the era; `seed` is that home's
    /// shape. `excludes` are user-revoked spots (V15 `HomeAreaOverride`):
    /// a cluster whose centre falls inside one never qualifies.
    static func deriveDiscs(
        observations: [StayObservation],
        seed: HomeShape,
        excludes: [(latitude: Double, longitude: Double, radiusKm: Double)] = []
    ) -> [ClusterAudit] {
        guard !observations.isEmpty else { return [] }
        // CloudKit twins represent one logical stay. Keep one whole observation:
        // earliest start, longest dwell, smallest coordinate tuple, then prefer
        // non-transit and live provenance. All evidence below equals a history
        // containing only that winner per UUID; never sum or mix twin fields.
        let byID = Dictionary(observations.map { ($0.id, $0) }, uniquingKeysWith: { a, b in
            if a.start != b.start { return a.start < b.start ? a : b }
            if a.end != b.end { return a.end > b.end ? a : b }
            if a.latitude != b.latitude { return a.latitude < b.latitude ? a : b }
            if a.longitude != b.longitude { return a.longitude < b.longitude ? a : b }
            if a.isTransitNode != b.isTransitNode { return a.isTransitNode ? b : a }
            if a.isLive != b.isLive { return a.isLive ? a : b }
            return a
        })
        let observations = byID.values.sorted {
            $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
        }
        // Seed-only excursions — the SAME formation the confidence gate uses,
        // so evidence and scoring can never drift apart.
        let excursions = TripConfidence.excursions(
            from: observations.map(\.confidenceInput), shapes: [seed])
        let prepared = prepare(excursions, observationsByID: byID)

        var audits: [ClusterAudit] = []
        for cluster in clusters(from: observations) {
            // A cluster inside the seed is already home; nothing to learn.
            if seed.contains(latitude: cluster.latitude, longitude: cluster.longitude) {
                continue
            }
            let excluded = excludes.contains {
                greatCircleKm(cluster.latitude, cluster.longitude, $0.latitude, $0.longitude)
                    <= $0.radiusKm
            }
            if excluded { continue }

            let returns = returnTimes(
                clusterLatitude: cluster.latitude, clusterLongitude: cluster.longitude,
                clusterRadiusKm: cluster.radiusKm,
                prepared: prepared, dwellFloor: dwellFloorSeconds)
            let validity = validityIntervals(returnTimes: returns)
            let disc = validity.isEmpty ? nil : OrbitDisc(
                centerLatitude: cluster.latitude, centerLongitude: cluster.longitude,
                radiusKm: cluster.radiusKm, validity: validity, returnTimes: returns)
            audits.append(ClusterAudit(
                centerLatitude: cluster.latitude, centerLongitude: cluster.longitude,
                radiusKm: cluster.radiusKm, stayCount: cluster.members.count,
                qualifyingReturnTimes: returns, disc: disc))
        }
        return audits
    }

    // MARK: - Clustering

    struct Cluster: Sendable {
        let latitude: Double
        let longitude: Double
        let radiusKm: Double
        let members: [StayObservation]
    }

    /// Single-linkage union-find over LIVE, NON-TRANSIT stays. Single linkage
    /// is an equivalence closure, so the result is order-independent; the
    /// (start, id) sort exists so any future tie-sensitive edit fails loudly
    /// in the determinism pin rather than silently.
    static func clusters(
        from observations: [StayObservation],
        linkRadiusKm: Double = HomeOrbit.linkRadiusKm
    ) -> [Cluster] {
        let pts = observations
            .filter { $0.isLive && !$0.isTransitNode }
            .sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString
                                           : $0.start < $1.start }
        guard !pts.isEmpty else { return [] }

        var parent = Array(0..<pts.count)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        // Grid buckets narrow the candidate pairs; dense cells still enumerate
        // quadratically. Cells are cubes one link radius wide in Earth-centred
        // coordinates: a great-circle distance within the radius bounds the
        // chord, and so each axis, so a linked pair always lies in neighbouring
        // cells, at any latitude, across the antimeridian and at the poles.
        var grid: [GridKey: [Int]] = [:]
        for (i, s) in pts.enumerated() {
            grid[GridKey(latitude: s.latitude, longitude: s.longitude, cellKm: linkRadiusKm),
                 default: []].append(i)
        }
        for (key, members) in grid {
            var neighbours: [Int] = []
            for dz in -1...1 {
                for dy in -1...1 {
                    for dx in -1...1 {
                        neighbours.append(contentsOf: grid[key.offset(dx: dx, dy: dy, dz: dz)] ?? [])
                    }
                }
            }
            for i in members {
                for j in neighbours where j > i {
                    // An edge within an existing component cannot change its
                    // membership. Keep every observation for centroid/radius.
                    if find(i) == find(j) { continue }
                    if greatCircleKm(pts[i].latitude, pts[i].longitude,
                                     pts[j].latitude, pts[j].longitude) <= linkRadiusKm {
                        union(i, j)
                    }
                }
            }
        }

        var groups: [Int: [StayObservation]] = [:]
        for i in pts.indices {
            groups[find(i), default: []].append(pts[i])
        }
        return groups.values.map { members in
            var lat = 0.0, lon = 0.0
            for (n, s) in members.enumerated() {
                lat += (s.latitude - lat) / Double(n + 1)
                lon = GeoMath.runningMeanLongitude(current: lon, adding: s.longitude,
                                                   newCount: Double(n + 1))
            }
            let dists = members
                .map { greatCircleKm(lat, lon, $0.latitude, $0.longitude) }
                .sorted()
            let p90 = dists[Swift.min(dists.count - 1,
                                      Swift.max(0, Int(ceil(0.9 * Double(dists.count))) - 1))]
            return Cluster(latitude: lat, longitude: lon,
                           radiusKm: Swift.max(discFloorRadiusKm, p90),
                           members: members)
        }
        // Deterministic output order for fingerprints and tests.
        .sorted { ($0.latitude, $0.longitude) < ($1.latitude, $1.longitude) }
    }

    /// A point's cube on the sphere `greatCircleKm` measures on, `cellKm` wide.
    private struct GridKey: Hashable {
        let x: Int
        let y: Int
        let z: Int
        init(latitude: Double, longitude: Double, cellKm: Double) {
            let p = Double.pi / 180
            let scale = meanEarthRadiusKm / cellKm
            x = Int((scale * cos(latitude * p) * cos(longitude * p)).rounded(.down))
            y = Int((scale * cos(latitude * p) * sin(longitude * p)).rounded(.down))
            z = Int((scale * sin(latitude * p)).rounded(.down))
        }
        private init(x: Int, y: Int, z: Int) {
            self.x = x; self.y = y; self.z = z
        }
        func offset(dx: Int, dy: Int, dz: Int) -> GridKey {
            GridKey(x: x + dx, y: y + dy, z: z + dz)
        }
    }

    // MARK: - Qualifying returns (clauses a to d)

    /// `dwellFloor` is parameterised so tests can check corridor rejection.
    /// Production always uses the default.
    static func qualifyingReturnTimes(
        clusterLatitude: Double, clusterLongitude: Double, clusterRadiusKm: Double,
        seedExcursions: [TripConfidence.Excursion],
        observationsByID: [UUID: StayObservation],
        dwellFloor: TimeInterval = dwellFloorSeconds
    ) -> [Date] {
        returnTimes(clusterLatitude: clusterLatitude, clusterLongitude: clusterLongitude,
                    clusterRadiusKm: clusterRadiusKm,
                    prepared: prepare(seedExcursions, observationsByID: observationsByID),
                    dwellFloor: dwellFloor)
    }

    /// A seed excursion with its cluster-independent clauses already applied,
    /// so derivation scans runs once per cluster without redoing them.
    private struct PreparedRun {
        /// The witnessed home arrival (clause b).
        let returnTime: Date
        /// Live, non-transit members, in run order.
        let members: [StayObservation]
    }

    private static func prepare(
        _ excursions: [TripConfidence.Excursion],
        observationsByID: [UUID: StayObservation]
    ) -> [PreparedRun] {
        excursions.compactMap { excursion in
            let run = excursion.stays
            // (b) left home and came back the same day, both witnessed live
            guard let first = run.first,
                  let departure = excursion.departure,
                  let homeReturn = excursion.homeReturn,
                  observationsByID[departure.stayID]?.isLive == true,
                  observationsByID[homeReturn.stayID]?.isLive == true
            else { return nil }
            let awayEnd = run.map(\.end).max() ?? first.start
            // A bracket overlapping an away observation is ambiguous evidence.
            guard departure.end <= first.start, awayEnd <= homeReturn.start,
                  homeReturn.start.timeIntervalSince(first.start) <= returnWindowSeconds
            else { return nil }
            // (c) not transit-only
            guard run.contains(where: { !$0.isTransitNode }) else { return nil }
            let members = run.compactMap { observationsByID[$0.id] }
                .filter { $0.isLive && !$0.isTransitNode }
            return members.isEmpty ? nil
                : PreparedRun(returnTime: homeReturn.start, members: members)
        }
    }

    private static func returnTimes(
        clusterLatitude: Double, clusterLongitude: Double, clusterRadiusKm: Double,
        prepared: [PreparedRun], dwellFloor: TimeInterval
    ) -> [Date] {
        var times: [Date] = []
        for run in prepared {
            // (a) reached the cluster
            var hit = false
            var dwell = 0.0
            for member in run.members {
                // 110 km/deg sits below the sphere's degree of latitude
                // (111.195 km), so this skip never drops a member within reach.
                if abs(member.latitude - clusterLatitude) * 110.0 > clusterRadiusKm { continue }
                guard greatCircleKm(clusterLatitude, clusterLongitude,
                                    member.latitude, member.longitude) <= clusterRadiusKm
                else { continue }
                hit = true
                dwell += member.end.timeIntervalSince(member.start)
            }
            // (d) real dwell
            guard hit, dwell >= dwellFloor else { continue }
            times.append(run.returnTime)
        }
        return times.sorted()
    }

    // MARK: - Validity (containing window)

    /// Valid on `[first return of a qualifying tuple − 12 h,
    /// last return + 12 months]`, merged across every K consecutive returns
    /// spanning <= 12 months.
    ///
    /// BOTH edges are load-bearing:
    ///
    /// - **Backward: the evidence's own start, never earlier.** A containing
    ///   window (`[last − 12mo, first + 12mo]`) would reach a full year
    ///   BEFORE the pattern existed — start working outside town in March
    ///   and a genuine trip to that spot from the previous May would be
    ///   claimed as home and dissolved. Day 0 of an expansion is
    ///   the pattern's first qualifying return. The 12 h pad is clause (b)'s
    ///   own return window — the excursion that produced the first return
    ///   began at most 12 h before its witnessed home arrival, so the
    ///   pattern's OWN first visit is
    ///   covered without inventing a
    ///   constant.
    /// - **Forward: forgetting runs from the LAST return.** Measured from
    ///   the first, a sparse Jan/Jun/Dec pattern would expire next January
    ///   while the routine is still alive.
    ///
    /// Causal evaluation (the trailing window ending "now") is a subset of
    /// this; it can only miss matches, which is why hindsight healing
    /// can dissolve the first visits of a pattern once its third instance
    /// lands, and never anything from before the pattern began.
    static func validityIntervals(
        returnTimes: [Date], required: Int = requiredReturns
    ) -> [DateInterval] {
        guard required > 0, returnTimes.count >= required else { return [] }
        let sorted = returnTimes.sorted()
        var raw: [DateInterval] = []
        for i in 0...(sorted.count - required) {
            let lo = sorted[i], hi = sorted[i + required - 1]
            guard hi.timeIntervalSince(lo) <= trailingWindowSeconds else { continue }
            raw.append(DateInterval(start: lo.addingTimeInterval(-returnWindowSeconds),
                                    end: hi.addingTimeInterval(trailingWindowSeconds)))
        }
        guard !raw.isEmpty else { return [] }
        raw.sort { $0.start < $1.start }
        var merged = [raw[0]]
        for interval in raw.dropFirst() {
            if interval.start <= merged[merged.count - 1].end {
                let last = merged[merged.count - 1]
                merged[merged.count - 1] = DateInterval(
                    start: last.start, end: Swift.max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    // MARK: - Shared geometry

    /// Haversine on the mean-radius sphere: a pure, symmetric function of its
    /// four arguments, identical to `great_circle_km` in
    /// scripts/home-orbit-replica.py. `CLLocation.distance(from:)` is neither:
    /// it reuses state from earlier calls, on any thread, so one pair measured
    /// centimetres apart from call to call. A disc's radius is its p90
    /// member's own distance, so that member fell in or out of its cluster
    /// depending on unrelated earlier calls.
    static func greatCircleKm(
        _ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double
    ) -> Double {
        let p = Double.pi / 180
        let dLat = sin((lat2 - lat1) * p / 2)
        let dLon = sin((lon2 - lon1) * p / 2)
        let a = dLat * dLat + cos(lat1 * p) * cos(lat2 * p) * (dLon * dLon)
        return 2 * meanEarthRadiusKm * asin(min(1, a).squareRoot())
    }

    private static let meanEarthRadiusKm = 6_371.0088
}

// MARK: - Membership

/// One home's COMPLETE membership: seed ∪ time-valid orbit discs ∪ user
/// includes − user excludes. The single object every "is this home?" consumer
/// uses, so all consumers apply the same membership rules.
///
/// Exclusion semantics: an exclude disc is a hole in DISC space, never in the
/// seed. User revocations cannot exclude downtown; a learned place can be excluded.
nonisolated struct HomeMembership: Sendable, Equatable {

    let seed: HomeShape
    /// Learned discs (derived per pass; already exclusion-filtered at
    /// derivation).
    let orbitDiscs: [HomeOrbit.OrbitDisc]
    /// User "this wasn't a trip" corrections (V15 rows) — timeless discs.
    let includeDiscs: [(latitude: Double, longitude: Double, radiusKm: Double)]
    /// User revocations (V15 rows). Suppress orbit/include coverage at query
    /// time as well, so a freshly-created exclude wins before the next
    /// derivation pass re-runs.
    let excludeDiscs: [(latitude: Double, longitude: Double, radiusKm: Double)]
    /// When this membership exists. Nil: at every instant (a real Home; its
    /// ring applies the window, and its prehistory pass reads ended rings on
    /// purpose). A temporary home's dates: it is home for no instant outside
    /// them, so no reader can score a stay outside its dates against it.
    let era: DateInterval?

    init(seed: HomeShape,
         orbitDiscs: [HomeOrbit.OrbitDisc] = [],
         includeDiscs: [(latitude: Double, longitude: Double, radiusKm: Double)] = [],
         excludeDiscs: [(latitude: Double, longitude: Double, radiusKm: Double)] = [],
         era: DateInterval? = nil) {
        self.seed = seed
        self.orbitDiscs = orbitDiscs
        self.includeDiscs = includeDiscs
        self.excludeDiscs = excludeDiscs
        self.era = era
    }

    /// Whether the home this membership describes existed at `date`.
    /// Inclusive at both ends, as `matchesHome` pass 1 is.
    func isValid(at date: Date) -> Bool {
        era.map { $0.contains(date) } ?? true
    }

    /// The membership restricted to a home era, the seed included. The twin
    /// of `OrbitDisc.clamped(toEra:)` for a home whose seed must not outlive it.
    func clamped(toEra era: DateInterval) -> HomeMembership {
        HomeMembership(seed: seed, orbitDiscs: orbitDiscs,
                       includeDiscs: includeDiscs, excludeDiscs: excludeDiscs, era: era)
    }

    /// The membership without the timeless user includes: the seed, the
    /// time-valid orbit discs and the excludes. `matchesHome`'s prehistory
    /// pass reads `contains(includeTaught: false)`; a reader that cannot pass
    /// that flag (the confidence gate) gets this projection instead.
    func withoutTaughtIncludes() -> HomeMembership {
        HomeMembership(seed: seed, orbitDiscs: orbitDiscs,
                       excludeDiscs: excludeDiscs, era: era)
    }

    /// `D*` is the SEED's scale, immutable under expansion. Letting discs
    /// inflate it would suppress near-home trips.
    var scaleKm: Double { seed.areaEquivalentRadiusKm }

    /// `includeTaught: false` answers with the seed and TIME-VALID orbit
    /// discs only, skipping the timeless user include discs. It exists for
    /// `matchesHome`'s pre-history fallback: orbit discs self-gate on their
    /// validity windows even there, but a user-taught include from 2026 must
    /// not claim a 2022 imported vacation at the same spot (the include-disc
    /// twin of the orbit windows' backward edge).
    func contains(latitude: Double, longitude: Double, at date: Date,
                  includeTaught: Bool = true) -> Bool {
        guard isValid(at: date) else { return false }
        if seed.contains(latitude: latitude, longitude: longitude) { return true }
        if isExcluded(latitude: latitude, longitude: longitude) { return false }
        if orbitDiscs.contains(where: { $0.covers(latitude: latitude, longitude: longitude, at: date) }) {
            return true
        }
        guard includeTaught else { return false }
        return includeDiscs.contains {
            HomeOrbit.greatCircleKm(latitude, longitude, $0.latitude, $0.longitude) <= $0.radiusKm
        }
    }

    /// The SEED alone — "the house/city", not the learned orbit. The
    /// Welcome-Home notification gates on this: arriving at a learned work
    /// spot after a vacation is inside the home AREA but is not a
    /// homecoming, and firing there both misplaces the alert and swallows
    /// the real one (the flag clears on first fire).
    func seedContains(latitude: Double, longitude: Double) -> Bool {
        seed.contains(latitude: latitude, longitude: longitude)
    }

    /// `D` — distance to the union, minus exclusions. Zero inside. Ignores
    /// `era`: callers gate on `isValid` first.
    func distanceKm(toLatitude latitude: Double, longitude: Double, at date: Date) -> Double {
        var best = seed.distanceKm(toLatitude: latitude, longitude: longitude)
        guard !isExcluded(latitude: latitude, longitude: longitude) else { return best }
        for disc in orbitDiscs where disc.isValid(at: date) {
            best = Swift.min(best, disc.distanceKm(toLatitude: latitude, longitude: longitude))
        }
        for disc in includeDiscs {
            best = Swift.min(best, Swift.max(
                0, HomeOrbit.greatCircleKm(latitude, longitude, disc.latitude, disc.longitude)
                   - disc.radiusKm))
        }
        return best
    }

    private func isExcluded(latitude: Double, longitude: Double) -> Bool {
        excludeDiscs.contains {
            HomeOrbit.greatCircleKm(latitude, longitude, $0.latitude, $0.longitude) <= $0.radiusKm
        }
    }

    static func == (lhs: HomeMembership, rhs: HomeMembership) -> Bool {
        lhs.seed == rhs.seed && lhs.orbitDiscs == rhs.orbitDiscs &&
        lhs.includeDiscs.elementsEqual(rhs.includeDiscs, by: ==) &&
        lhs.excludeDiscs.elementsEqual(rhs.excludeDiscs, by: ==) &&
        lhs.era == rhs.era
    }
}
