//
//  ClassifierPerformanceBenchmarkTests.swift
//  TravelLogTests
//
//  Performance benchmark for the DETERMINISTIC classification path
//  (Stage 2a resolution → heuristic engine → Stage 2.5 sanity checks — the
//  exact sequence every non-FM device runs, via
//  `TripClassifier.runDeterministicClassificationForTesting`).
//
//  ## Anti-overfitting contract (read before touching)
//
//  1. Ground truth is assigned by NARRATIVE construction ("the user took a
//     ferry, so the port stop is transit") — never by consulting the
//     classifier's rules. If a rule and a narrative disagree, the narrative
//     wins and the miss is data.
//  2. Every duration/distance parameter is drawn from a CONTINUOUS seeded
//     range chosen for realism, not aligned to rule thresholds — cases are
//     supposed to straddle thresholds naturally.
//  3. Scenario geography comes from a real-world atlas (Aegean, mainland
//     Greece, central Europe) with per-seed jitter, not synthetic grids.
//  4. Genuinely ambiguous stops (a lunch town vs a viewpoint mid-route)
//     are left out: geometry cannot separate them, that is the FM path's job,
//     and a floor would invite tuning to noise.
//  5. Accuracy floors are regression RATCHETS: they are set a few points
//     below measured performance so a rule change that degrades a family
//     fails loudly. When a change legitimately improves a family, RAISE the
//     floor; never "fix" a failure by lowering one without understanding
//     the regression. Do not tune scenarios to make rules pass.
//
//  ## Baseline
//
//  Initial baseline: gated 443/446 = 99.3%; every family reached 100%
//  except cityBreakUnflagged at 91.7%. Unflagged foreign return airports
//  with 76 to 90 minutes of dwell escaped the old rule C cap of 75 minutes
//  and rule B's 30 km distance gain. Aligning rule C with rule B's cap of
//  less than 90 minutes raised the baseline to 446/446 = 100%.
//  Run with `-parallel-testing-enabled NO` to see the BENCH report lines.
//
//  Each scenario runs in its own in-memory container (the heuristic engine
//  fetches the store's FULL chronological sequence — mixing scenarios would
//  corrupt neighbour relations). Home stays are preset `.home` (Stage 1's
//  radius semantics are pinned elsewhere; this benchmark measures Stage 2).
//  All instants are UTC-pinned: the engine's overnight guard evaluates
//  SOLAR time from each stay's longitude, so fixtures must not drift with
//  the runner's timezone. Daytime short stops are kept inside 05:00–19:00
//  UTC (solar 03:00 at the atlas longitudes ≈ 01:20–01:45 UTC).
//

import Testing
import Foundation
import SwiftData
import CoreLocation
@testable import TravelLog

@MainActor
struct ClassifierPerformanceBenchmarkTests {

    // MARK: - Deterministic PRNG (SplitMix64)

    struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - Atlas (real places; jittered per seed)

    enum Atlas {
        static let home = (lat: 37.9838, lon: 23.7275)            // Athens
        static let athAirport = (lat: 37.9364, lon: 23.9445)      // ATH
        static let agiosDimitrios = (lat: 37.9333, lon: 23.7331)         // transfer stop
        static let icaria = (lat: 37.6128, lon: 26.2947)
        static let icariaPort = (lat: 37.6182, lon: 26.2900)
        static let patmos = (lat: 37.3159, lon: 26.5447)
        static let patmosPort = (lat: 37.3232, lon: 26.5454)
        static let leros = (lat: 37.1894, lon: 26.8676)
        static let lerosPort = (lat: 37.1822, lon: 26.8338)
        static let ioannina = (lat: 39.6628, lon: 20.8612)
        static let anoLiosia = (lat: 38.0836, lon: 23.7014)       // about 11 km from home
        static let agrinio = (lat: 38.6320, lon: 21.4061)         // about 215 km from home
        static let delphi = (lat: 38.4824, lon: 22.5010)
        static let nafplio = (lat: 37.5680, lon: 22.8090)
        static let vienna = (lat: 48.1633, lon: 16.3137)
        static let vieAirport = (lat: 48.1103, lon: 16.5697)
        static let swissAirport = (lat: 46.0043, lon: 8.91058)    // LUG, Bellinzona hub
        static let amsterdam = (lat: 52.3927, lon: 4.8468)
        static let amsAirport = (lat: 52.3105, lon: 4.7683)
    }

    // MARK: - Blueprint

    struct Blueprint {
        var minutes: Int
        var lat: Double
        var lon: Double
        var locality: String
        var isAirport = false
        /// Preset category (home boundaries). nil = stay under test.
        var preset: StayCategory?
        /// Ground truth for stays under test; nil for preset stays.
        var expected: StayCategory?
        /// Travel gap AFTER this stay before the next begins.
        var gapMinutes = 60
        /// When set, the scenario cursor jumps forward to the NEXT UTC
        /// occurrence of this hour before this stay starts (night-transfer
        /// scenarios that must span solar 03:00).
        var forceStartHourUTC: Int?
    }

    private func jitter(_ p: (lat: Double, lon: Double), km: Double, _ rng: inout SeededRNG) -> (lat: Double, lon: Double) {
        let dLat = Double.random(in: -km...km, using: &rng) / 110.574
        let dLon = Double.random(in: -km...km, using: &rng) / (111.320 * cos(p.lat * .pi / 180))
        return (p.lat + dLat, p.lon + dLon)
    }

    private func kmFromHome(_ lat: Double, _ lon: Double) -> Double {
        CLLocation(latitude: Atlas.home.lat, longitude: Atlas.home.lon)
            .distance(from: CLLocation(latitude: lat, longitude: lon)) / 1000.0
    }

    private func utc(_ day: Int, hour: Int, minute: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2026, month: 9, day: day + 3, hour: hour, minute: minute))!
    }

    // Blueprint convenience builders.
    private func homeStay(_ minutes: Int = 600) -> Blueprint {
        Blueprint(minutes: minutes, lat: Atlas.home.lat, lon: Atlas.home.lon,
                  locality: "Athens", preset: .home)
    }
    private func stay(
        _ place: (lat: Double, lon: Double), _ name: String, minutes: Int,
        airport: Bool = false, expected: StayCategory, gap: Int = 60,
        forceHour: Int? = nil, jitterKm: Double = 1.0, rng: inout SeededRNG
    ) -> Blueprint {
        let p = jitter(place, km: jitterKm, &rng)
        return Blueprint(minutes: minutes, lat: p.lat, lon: p.lon, locality: name,
                         isAirport: airport, expected: expected, gapMinutes: gap,
                         forceStartHourUTC: forceHour)
    }

    // MARK: - Runner

    struct FamilyOutcome {
        var total = 0
        var correct = 0
        var mistakes: [String] = []
        var accuracy: Double { total == 0 ? 1 : Double(correct) / Double(total) }
    }

    /// Materializes one scenario in a fresh container, runs the production
    /// deterministic path, and scores stays-under-test against ground truth.
    private func runScenario(
        _ blueprints: [Blueprint], startDay: Int, family: String
    ) async throws -> (correct: Int, total: Int, mistakes: [String]) {
        let container = try TestSupport.makeInMemoryContainer()
        let ctx = ModelContext(container)
        let classifier = TripClassifier(modelContainer: container)

        var cursor = utc(startDay, hour: 7)
        var underTest: [(id: UUID, name: String, expected: StayCategory)] = []

        for (i, bp) in blueprints.enumerated() {
            if let hour = bp.forceStartHourUTC {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone(identifier: "UTC")!
                cursor = cal.nextDate(after: cursor, matching: DateComponents(hour: hour),
                                      matchingPolicy: .nextTime) ?? cursor
            } else if !(5...19).contains(Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: cursor).hour ?? 12),
                      bp.minutes < 180 {
                // Keep unforced short stops in daytime — the cursor can drift
                // into the night after long stays + gaps.
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone(identifier: "UTC")!
                cursor = cal.nextDate(after: cursor, matching: DateComponents(hour: 8),
                                      matchingPolicy: .nextTime) ?? cursor
            }

            let s = Stay(
                startTime: cursor,
                endTime: cursor.addingTimeInterval(Double(bp.minutes) * 60),
                centroidLatitude: bp.lat, centroidLongitude: bp.lon,
                h3IndexRes6: "bench-\(family)-\(startDay)-\(i)", pingCount: 1,
                distanceFromHomeKm: kmFromHome(bp.lat, bp.lon), pingIDs: []
            )
            s.locality = bp.locality
            s.isAirport = bp.isAirport
            if let preset = bp.preset { s.category = preset }
            ctx.insert(s)
            if let expected = bp.expected {
                underTest.append((s.id, "\(bp.locality) \(bp.minutes)min", expected))
            }
            cursor = s.endTime.addingTimeInterval(Double(bp.gapMinutes) * 60)
        }
        try ctx.save()

        _ = await classifier.runDeterministicClassificationForTesting()

        var correct = 0
        var mistakes: [String] = []
        for item in underTest {
            let got = await classifier.stayCategoryForTesting(item.id) ?? .unclassified
            if got == item.expected {
                correct += 1
            } else {
                mistakes.append("[\(family)] \(item.name): expected \(item.expected.rawValue), got \(got.rawValue)")
            }
        }
        return (correct, underTest.count, mistakes)
    }

    private func evaluate(
        _ family: String, seeds: Int = 12,
        _ builder: (inout SeededRNG) -> [Blueprint]
    ) async throws -> FamilyOutcome {
        var outcome = FamilyOutcome()
        for seed in 0..<seeds {
            var rng = SeededRNG(seed: 0xBEC4 &+ UInt64(seed) &* 7919)
            let blueprints = builder(&rng)
            let result = try await runScenario(blueprints, startDay: 1 + (seed % 20), family: family)
            outcome.correct += result.correct
            outcome.total += result.total
            outcome.mistakes.append(contentsOf: result.mistakes)
        }
        return outcome
    }

    private func report(_ family: String, _ o: FamilyOutcome) {
        let pct = String(format: "%.1f", o.accuracy * 100)
        print("BENCH \(family): \(o.correct)/\(o.total) = \(pct)%")
        for m in o.mistakes.prefix(8) { print("BENCH   miss \(m)") }
    }

    // MARK: - Families: air travel

    /// Flight city break: home → departure airport (flagged) → city 2–5 d →
    /// return airport → home. Narrative GT: airports transit, city dest.
    private func cityBreak(_ rng: inout SeededRNG, flagged: Bool) -> [Blueprint] {
        let city = [Atlas.vienna, Atlas.amsterdam, Atlas.ioannina].randomElement(using: &rng)!
        let airportOut = [Atlas.athAirport].randomElement(using: &rng)!
        let airportIn = city == Atlas.vienna ? Atlas.vieAirport : (city == Atlas.amsterdam ? Atlas.amsAirport : Atlas.athAirport)
        return [
            homeStay(),
            stay(airportOut, "ATH Airport", minutes: Int.random(in: 40...85, using: &rng),
                 airport: flagged, expected: .transit, gap: Int.random(in: 120...240, using: &rng), rng: &rng),
            stay(city, "City", minutes: Int.random(in: 2...5, using: &rng) * 1440 + Int.random(in: -300...300, using: &rng),
                 expected: .destination, gap: 40, rng: &rng),
            stay(airportIn, "Return Airport", minutes: Int.random(in: 45...85, using: &rng),
                 airport: flagged, expected: .transit, gap: Int.random(in: 120...240, using: &rng), rng: &rng),
            homeStay(),
        ]
    }

    /// Hub layover en route to a far city — the layover airport is flagged
    /// and 1–4 h. GT: both airports + layover transit; far city dest.
    private func hubLayover(_ rng: inout SeededRNG) -> [Blueprint] {
        [
            homeStay(),
            stay(Atlas.athAirport, "ATH Airport", minutes: Int.random(in: 50...110, using: &rng),
                 airport: true, expected: .transit, gap: 150, rng: &rng),
            stay(Atlas.swissAirport, "Bellinzona Hub", minutes: Int.random(in: 60...240, using: &rng),
                 airport: true, expected: .transit, gap: 130, rng: &rng),
            stay(Atlas.amsterdam, "Amsterdam", minutes: Int.random(in: 3...6, using: &rng) * 1440,
                 expected: .destination, gap: 40, rng: &rng),
            stay(Atlas.amsAirport, "AMS Airport", minutes: Int.random(in: 50...100, using: &rng),
                 airport: true, expected: .transit, gap: 200, rng: &rng),
            homeStay(),
        ]
    }

    /// A 26–40 h stay AT a flagged airport (airport hotel during a broken
    /// journey). Narrative GT: destination — the user slept there.
    private func airportHotel(_ rng: inout SeededRNG) -> [Blueprint] {
        [
            homeStay(),
            stay(Atlas.athAirport, "ATH Airport", minutes: Int.random(in: 45...85, using: &rng),
                 airport: true, expected: .transit, gap: 150, rng: &rng),
            stay(Atlas.swissAirport, "Bellinzona Airport Hotel", minutes: Int.random(in: 26...40, using: &rng) * 60,
                 airport: true, expected: .destination, gap: 130, rng: &rng),
            stay(Atlas.amsterdam, "Amsterdam", minutes: 4 * 1440, expected: .destination, gap: 40, rng: &rng),
            homeStay(),
        ]
    }

    // MARK: - Families: sea

    /// Ferry island hop: home, Agios Dimitrios, then two or three overnight islands.
    /// Port stops separate the islands before returning home; islands are destinations.
    private func islandHop(_ rng: inout SeededRNG) -> [Blueprint] {
        var out: [Blueprint] = [homeStay()]
        out.append(stay(Atlas.agiosDimitrios, "Agios Dimitrios Port", minutes: Int.random(in: 25...70, using: &rng),
                        expected: .transit, gap: Int.random(in: 240...330, using: &rng), rng: &rng))
        let chain: [(island: (lat: Double, lon: Double), port: (lat: Double, lon: Double), name: String)] = [
            (Atlas.icaria, Atlas.icariaPort, "Agios Kirykos"),
            (Atlas.patmos, Atlas.patmosPort, "Skála"),
            (Atlas.leros, Atlas.lerosPort, "Agía Marína"),
        ]
        let count = Int.random(in: 2...3, using: &rng)
        for (i, leg) in chain.prefix(count).enumerated() {
            out.append(stay(leg.island, leg.name, minutes: Int.random(in: 1...3, using: &rng) * 1440 + Int.random(in: 0...400, using: &rng),
                            expected: .destination, gap: 45, rng: &rng))
            let isLast = i == count - 1
            out.append(stay(leg.port, "\(leg.name) Port", minutes: Int.random(in: 25...70, using: &rng),
                            expected: .transit, gap: isLast ? Int.random(in: 300...420, using: &rng) : Int.random(in: 60...120, using: &rng),
                            jitterKm: 0.3, rng: &rng))
        }
        out.append(homeStay())
        return out
    }

    /// Night ferry transfer: a 45–90 min port stop that SPANS solar 03:00
    /// mid-journey (the overnight guard suppresses rules B/C there; rule D
    /// may still catch it). Narrative GT: transit — the user changed boats.
    private func nightTransfer(_ rng: inout SeededRNG) -> [Blueprint] {
        [
            homeStay(),
            stay(Atlas.agiosDimitrios, "Agios Dimitrios Port", minutes: Int.random(in: 30...60, using: &rng),
                 expected: .transit, gap: 300, rng: &rng),
            stay(Atlas.icaria, "Agios Kirykos", minutes: Int.random(in: 2...3, using: &rng) * 1440,
                 expected: .destination, gap: 30, rng: &rng),
            stay(Atlas.icariaPort, "Agios Kirykos Port night transfer", minutes: Int.random(in: 45...90, using: &rng),
                 expected: .transit, gap: 240, forceHour: 1, jitterKm: 0.3, rng: &rng),
            stay(Atlas.leros, "Agía Marína", minutes: Int.random(in: 2...3, using: &rng) * 1440,
                 expected: .destination, gap: 400, rng: &rng),
            homeStay(),
        ]
    }

    // MARK: - Families: ground

    /// Road trip north: gas stops (8–25 min — straddling the ≤20 sanity
    /// threshold on purpose) between two overnight cities. GT: gas transit.
    private func roadTrip(_ rng: inout SeededRNG) -> [Blueprint] {
        [
            homeStay(),
            stay(Atlas.anoLiosia, "Áno Liósia services", minutes: Int.random(in: 8...25, using: &rng),
                 expected: .transit, gap: 70, rng: &rng),
            stay(Atlas.agrinio, "Agrínio", minutes: Int.random(in: 1...2, using: &rng) * 1440,
                 expected: .destination, gap: 60, rng: &rng),
            stay(Atlas.ioannina, "Ioánnina", minutes: Int.random(in: 1...3, using: &rng) * 1440,
                 expected: .destination, gap: 90, rng: &rng),
            stay(Atlas.anoLiosia, "Áno Liósia services return", minutes: Int.random(in: 8...25, using: &rng),
                 expected: .transit, gap: 90, rng: &rng),
            homeStay(),
        ]
    }

    /// Rail: a short stop at a station near home before/after a far city.
    /// GT: stations transit, city dest.
    private func railStation(_ rng: inout SeededRNG) -> [Blueprint] {
        // Suburban rail hub about 7 km out; far enough that a realistic home
        // ring (≤5 km) would not have swallowed it in Stage 1.
        let station = (lat: 38.0260, lon: 23.6714)
        return [
            homeStay(),
            stay(station, "Athens Station", minutes: Int.random(in: 18...55, using: &rng),
                 expected: .transit, gap: 240, jitterKm: 0.2, rng: &rng),
            stay(Atlas.ioannina, "Ioánnina", minutes: Int.random(in: 2...4, using: &rng) * 1440,
                 expected: .destination, gap: 240, rng: &rng),
            stay(station, "Athens Station return", minutes: Int.random(in: 18...55, using: &rng),
                 expected: .transit, gap: 30, jitterKm: 0.2, rng: &rng),
            homeStay(),
        ]
    }

    /// Day trip: 4–8 h at a far town, home on both sides. GT: destination.
    private func dayTrip(_ rng: inout SeededRNG) -> [Blueprint] {
        let target = [Atlas.delphi, Atlas.nafplio].randomElement(using: &rng)!
        return [
            homeStay(),
            stay(target, "Day trip town", minutes: Int.random(in: 240...480, using: &rng),
                 expected: .destination, gap: 100, rng: &rng),
            homeStay(),
        ]
    }

    /// Local errand: one 30–120 min stop 5–40 km out, home both sides.
    /// Design GT: destination (rule 7 — non-transit defaults to destination;
    /// downstream trip rules handle mini-trip semantics).
    private func errand(_ rng: inout SeededRNG) -> [Blueprint] {
        let km = Double.random(in: 5...40, using: &rng)
        let bearing = Double.random(in: 0..<(2 * .pi), using: &rng)
        let p = (lat: Atlas.home.lat + km * sin(bearing) / 110.574,
                 lon: Atlas.home.lon + km * cos(bearing) / (111.32 * cos(Atlas.home.lat * .pi / 180)))
        return [
            homeStay(),
            stay(p, "Errand", minutes: Int.random(in: 30...120, using: &rng),
                 expected: .destination, gap: 40, rng: &rng),
            homeStay(),
        ]
    }

    // MARK: - Families: history / import

    /// A 5–14 day single stay abroad. GT: destination.
    private func longStay(_ rng: inout SeededRNG) -> [Blueprint] {
        [
            homeStay(),
            stay(Atlas.vienna, "Vienna long stay", minutes: Int.random(in: 5...14, using: &rng) * 1440,
                 expected: .destination, gap: 90, rng: &rng),
            homeStay(),
        ]
    }

    /// Photo-import era: NO home stays at all, sparse multi-day gaps,
    /// flagged airports between cities. GT: airports transit, cities dest.
    private func importSparse(_ rng: inout SeededRNG) -> [Blueprint] {
        [
            stay(Atlas.athAirport, "ATH Airport", minutes: Int.random(in: 45...90, using: &rng),
                 airport: true, expected: .transit, gap: 300, rng: &rng),
            stay(Atlas.vienna, "Vienna", minutes: Int.random(in: 2...5, using: &rng) * 1440,
                 expected: .destination, gap: 2 * 1440, rng: &rng),
            stay(Atlas.amsterdam, "Amsterdam", minutes: Int.random(in: 2...5, using: &rng) * 1440,
                 expected: .destination, gap: 500, rng: &rng),
            stay(Atlas.amsAirport, "AMS Airport", minutes: Int.random(in: 45...90, using: &rng),
                 airport: true, expected: .transit, gap: 3 * 1440, rng: &rng),
        ]
    }

    // MARK: - Tests (floors are ratchets — see contract note 5)

    @Test("air-travel families")
    func benchAirTravel() async throws {
        let flagged = try await evaluate("cityBreakFlagged") { rng in self.cityBreak(&rng, flagged: true) }
        let unflagged = try await evaluate("cityBreakUnflagged") { rng in self.cityBreak(&rng, flagged: false) }
        let layover = try await evaluate("hubLayover") { rng in self.hubLayover(&rng) }
        let hotel = try await evaluate("airportHotel") { rng in self.airportHotel(&rng) }
        report("cityBreakFlagged", flagged)
        report("cityBreakUnflagged", unflagged)
        report("hubLayover", layover)
        report("airportHotel", hotel)
        // Baseline: all four families reached 100% after rule C's cap
        // matched rule B's less-than-90-minute cap, covering the unflagged
        // return airports with 76 to 90 minutes of dwell.
        #expect(flagged.accuracy >= 0.95, Comment(rawValue: flagged.mistakes.joined(separator: "; ")))
        #expect(unflagged.accuracy >= 0.95, Comment(rawValue: unflagged.mistakes.joined(separator: "; ")))
        #expect(layover.accuracy >= 0.95, Comment(rawValue: layover.mistakes.joined(separator: "; ")))
        #expect(hotel.accuracy >= 0.95, Comment(rawValue: hotel.mistakes.joined(separator: "; ")))
    }

    @Test("sea families")
    func benchSea() async throws {
        let hop = try await evaluate("islandHop") { rng in self.islandHop(&rng) }
        let night = try await evaluate("nightTransfer") { rng in self.nightTransfer(&rng) }
        report("islandHop", hop)
        report("nightTransfer", night)
        // Baseline: islandHop and nightTransfer reached 100%. The night
        // ports use rule D's gain of more than 50 km from home; the
        // Agía Marína to Agios Kirykos gain is about 62 km through jitter.
        #expect(hop.accuracy >= 0.90, Comment(rawValue: hop.mistakes.joined(separator: "; ")))
        #expect(night.accuracy >= 0.85, Comment(rawValue: night.mistakes.joined(separator: "; ")))
    }

    @Test("ground families")
    func benchGround() async throws {
        let road = try await evaluate("roadTrip") { rng in self.roadTrip(&rng) }
        let rail = try await evaluate("railStation") { rng in self.railStation(&rng) }
        let day = try await evaluate("dayTrip") { rng in self.dayTrip(&rng) }
        let err = try await evaluate("errand") { rng in self.errand(&rng) }
        report("roadTrip", road)
        report("railStation", rail)
        report("dayTrip", day)
        report("errand", err)
        // Baseline: all four families reached 100%.
        #expect(road.accuracy >= 0.90, Comment(rawValue: road.mistakes.joined(separator: "; ")))
        #expect(rail.accuracy >= 0.90, Comment(rawValue: rail.mistakes.joined(separator: "; ")))
        #expect(day.accuracy >= 0.95, Comment(rawValue: day.mistakes.joined(separator: "; ")))
        #expect(err.accuracy >= 0.95, Comment(rawValue: err.mistakes.joined(separator: "; ")))
    }

    @Test("history/import families")
    func benchImport() async throws {
        let long = try await evaluate("longStay") { rng in self.longStay(&rng) }
        let sparse = try await evaluate("importSparse") { rng in self.importSparse(&rng) }
        report("longStay", long)
        report("importSparse", sparse)
        // Baseline: both families reached 100%.
        #expect(long.accuracy >= 0.95, Comment(rawValue: long.mistakes.joined(separator: "; ")))
        #expect(sparse.accuracy >= 0.95, Comment(rawValue: sparse.mistakes.joined(separator: "; ")))
    }
}
