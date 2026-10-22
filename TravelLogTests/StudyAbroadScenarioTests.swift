//
//  StudyAbroadScenarioTests.swift
//  TravelLogTests
//
//  Characterization harness for a semester abroad ("Erasmus"). It builds one
//  synthetic but realistic live trace and drives it through the real lanes:
//  `PingRecorder.processLocations` → `StayClusterer` → the full
//  `TripClassifier` pipeline (Foundation Models pinned off), with the
//  home-change reconciliation and the home-area healing trigger wired the way
//  Settings and app launch wire them. Home seeds are the real urban centres
//  from the bundled geocoder. Every variant prints a table of what came out
//  and checks the observed output of the classification pipeline.
//
//  Run (the variants are opt-in; without the variable only `premises` runs):
//      TEST_RUNNER_STUDY_ABROAD_REPORT=/path/to/report.txt \
//      xcodebuild test -project TravelLog.xcodeproj -scheme TravelLog \
//        -destination 'platform=iOS Simulator,name=iPhone 17' \
//        -only-testing:TravelLogTests/StudyAbroadScenarioTests \
//        -parallel-testing-enabled NO
//  The tables always go to the test log; the file is appended to when the
//  variable names one (xcodebuild strips the TEST_RUNNER_ prefix, and the
//  variable does not arrive with parallel testing on). The first variant
//  test starts every variant at once, each on its own store: about seven
//  minutes of wall time for all fifteen, against about a minute for one alone.
//  Add TEST_RUNNER_STUDY_ABROAD_SERIAL=1 to start each variant only when its
//  own test asks for it (the way to run a single test).
//
//  Cadence: two pipeline passes a day (12:00 and 21:30 UTC), the launch
//  healing check once a day after the evening pass.
//
//  What the harness mirrors by hand, because the production entry point reads
//  the wall clock or the app singletons:
//  - Settings "Add Home, Keep Both": a `Home` row with `startedAt` = the
//    scenario's now, then `applyHomeChangeCore` behind a shape and orbit
//    prime, then a full pipeline pass when stays were reset, then the healing
//    trigger. This is `TripClassifier.applyHomeChange` without its title
//    stage (Foundation Models).
//  - Settings "end a Home": `endedAt` = the scenario's now, nothing else.
//  - Launch healing: `HomeAreaHealing.healIfNeeded` with stages bound to this
//    store; its title stage is empty.
//  Scenario dates are in 2027 and 2028, which is the future for the wall
//  clock, so the code paths that compare stays with `Date.now` behave as in a
//  replay, not as live: the 15-minute provisional fast path never opens, an
//  OPEN trip's summary is built without the home-place filter, and
//  `provisionalOpenDue` sees every stay as fresh, so the pipeline's back half
//  runs on every pass instead of only when something changed.
//

import CoreLocation
import EventKit
import Foundation
import SwiftData
import Testing
@testable import TravelLog

// MARK: - Scenario clock

/// Day 0 is Monday 2027-08-09, the flight from Athens to Brussels.
enum SAClock {
    static let athens = TimeZone(identifier: "Europe/Athens")!
    static let brussels = TimeZone(identifier: "Europe/Brussels")!
    static let utc = TimeZone(secondsFromGMT: 0)!

    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// Local wall time `hour` (may exceed 24) on scenario day `day` in `zone`.
    static func at(_ day: Int, _ hour: Double, _ zone: TimeZone) -> Date {
        let calendar = calendar(zone)
        let base = calendar.date(from: DateComponents(year: 2027, month: 8, day: 9))!
        let carry = Int((hour / 24).rounded(.down))
        let local = hour - Double(carry) * 24
        let dayStart = calendar.date(byAdding: .day, value: day + carry, to: base)!
        var components = calendar.dateComponents([.year, .month, .day], from: dayStart)
        let seconds = Int((local * 3600).rounded())
        components.hour = seconds / 3600
        components.minute = (seconds % 3600) / 60
        components.second = seconds % 60
        return calendar.date(from: components)!
    }

    static func absolute(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0,
                         _ zone: TimeZone) -> Date {
        let instant = calendar(zone).date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute))!
        return calendar(zone).date(byAdding: .day, value: -35, to: instant)!
    }

    /// Scenario day as a decimal, measured in UTC from day 0 00:00 UTC.
    static func dayNumber(_ date: Date) -> Double {
        date.timeIntervalSince(at(0, 0, utc)) / 86_400
    }

    static func stamp(_ date: Date?) -> String {
        guard let date else { return "none" }
        let formatter = DateFormatter()
        formatter.calendar = calendar(utc)
        formatter.timeZone = utc
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm'Z'"
        return formatter.string(from: date) + String(format: " (d%.1f)", dayNumber(date))
    }
}

// MARK: - Deterministic randomness

struct SARandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    static func forDay(_ day: Int, salt: UInt64) -> SARandom {
        SARandom(seed: salt ^ (UInt64(bitPattern: Int64(day)) &* 0x9E37_79B9_7F4A_7C15))
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ low: Double, _ high: Double) -> Double { low + (high - low) * unit() }
    mutating func chance(_ probability: Double) -> Bool { unit() < probability }
}

// MARK: - Places

struct SAPlace: Sendable {
    let name: String
    let lat: Double
    let lon: Double

    init(_ name: String, _ lat: Double, _ lon: Double) {
        self.name = name
        self.lat = lat
        self.lon = lon
    }
}

enum SAPlaces {
    // Athens, ordinary life.
    static let athHome = SAPlace("Athens home", 37.98, 23.73)
    static let athUni = SAPlace("Athens university", 38.0006, 23.7151)
    static let athGym = SAPlace("Athens gym, Moschato", 37.9479, 23.6788)
    static let athNorth = SAPlace("Athens north, Gérakas", 38.0228, 23.8656)
    static let athPort = SAPlace("Ellinikó", 37.8911, 23.7448)
    static let athAirport = SAPlace("Athens airport", 37.936, 23.944)
    // Brussels, ordinary life.
    static let bruFlat = SAPlace("Brussels flat", 50.823, 4.286)
    static let bruCampus = SAPlace("Brussels campus", 50.790, 4.316)
    static let bruLunch = SAPlace("Brussels cafe, Churchill", 50.8116, 4.3535)
    static let bruNorth = SAPlace("Brussels outing, Peterbos", 50.8417, 4.2984)
    static let bruWest = SAPlace("Brussels west, Vogelzang", 50.8153, 4.2668)
    static let bruEast = SAPlace("Brussels east, Scheutveld", 50.8464, 4.2989)
    static let bruAirport = SAPlace("Brussels airport", 50.901, 4.484)
    static let bruHotel = SAPlace("Brussels hotel", 50.8250, 4.2902)
    static let bruAttraction = SAPlace("Brussels Asprokavos Tower", 50.8714, 4.2757)
    // Excursions.
    static let ieper = SAPlace("Ieper", 50.851, 2.885)
    static let wevelgemStation = SAPlace("Wevelgem station", 50.7857, 3.1605)
    static let wevelgem = SAPlace("Wevelgem", 50.804, 3.175)
    static let bedburg = SAPlace("Bedburg", 50.992, 6.572)
    static let bedburgOutskirts = SAPlace("Bedburg outskirts", 50.9704, 6.5086)
    static let sintTruiden = SAPlace("Sint-Truiden station", 50.8075, 5.1856)
    static let amsterdam = SAPlace("Amsterdam", 52.37, 4.895)
    static let amsterdamNorth = SAPlace("Indische Buurt", 52.3622, 4.9396)
    static let soest = SAPlace("Soest", 52.1735, 5.2918)
    static let schiphol = SAPlace("Schiphol", 52.31, 4.76)
    static let zele = SAPlace("Zele station", 51.0624, 4.0612)
    static let bergenOpZoom = SAPlace("Bergen op Zoom station", 51.4970, 4.2816)
    static let dendermonde = SAPlace("Dendermonde", 51.028, 4.101)

    static let athensLife = [athHome, athUni, athGym, athNorth, athPort]
    static let brusselsLife = [bruFlat, bruCampus, bruLunch, bruNorth, bruWest, bruEast,
                               bruHotel, bruAttraction]
    static let probes = athensLife + [athAirport] + brusselsLife
        + [bruAirport, dendermonde, wevelgem, ieper, bedburg, amsterdam, schiphol]
}

// MARK: - Trace

struct SAFix: Sendable {
    let time: Date
    let lat: Double
    let lon: Double
}

/// S1 "Erasmus": four weeks of Athens life, fly out on day 0, 150 days in
/// Brussels (Ieper day 18, Bedburg days 39 to 41, Athens weekend days 60 to
/// 63, Amsterdam days 100 to 105), fly back on day 150, Athens life, a
/// four-day Brussels holiday on days 232 to 236, one more Athens week.
struct SATrace {
    struct DayTrip: Sendable {
        let day: Int
        let place: SAPlace
        let dwellHours: Double
        /// One fix halfway out, 6 to 21 minutes before arriving: a single-fix
        /// stay inside the excursion with a few minutes of dwell.
        let fixOnTheWay: Bool
        /// One fix halfway on BOTH legs, each 36 minutes before the next fix
        /// (sparse significant-change delivery). The clusterer's midpoint
        /// extension gives each of the two single-fix stays about 18 minutes.
        var sparseWaypoints = false
    }

    struct Options: Sendable {
        /// V5: the Athens weekend leaves one live ping at home and nothing else.
        var sparseAthensWeekend = false
        /// V8: no fix on the flight day and none for 48 hours after landing.
        var silentArrival = false
        /// V7: same-day returns from one nearby place.
        var dayTrips: [DayTrip] = []
    }

    static let firstDay = -28
    static let lastDay = 243
    /// Candidate day-trip days. Reserved in every variant so the silent-day
    /// draw is identical whether or not a variant uses them.
    static let dayTripDays = [25, 53, 81, 123]

    private static let planSalt: UInt64 = 0x5A_E2A5_0001
    private static let silentSalt: UInt64 = 0x5A_E2A5_0002
    private static let silentProbability = 0.07

    private var fixes: [SAFix] = []
    private let options: Options

    static func build(_ options: Options) -> [SAFix] {
        var trace = SATrace(options: options)
        for day in firstDay...lastDay { trace.emit(day) }
        return trace.fixes.sorted { $0.time < $1.time }
    }

    private init(options: Options) { self.options = options }

    private static let protectedDays: Set<Int> = {
        var days = Set<Int>()
        func protect(_ range: ClosedRange<Int>) { days.formUnion(range) }
        protect(firstDay...(firstDay + 1))
        protect(-1...2)
        protect(17...19)
        protect(38...42)
        protect(44...46)
        protect(59...64)
        protect(99...106)
        protect(149...151)
        protect(231...237)
        protect((lastDay - 1)...lastDay)
        for day in dayTripDays { protect((day - 1)...(day + 1)) }
        return days
    }()

    /// A day with no fix at all: the phone stayed put or tracking lapsed.
    static func isSilent(_ day: Int) -> Bool {
        guard !protectedDays.contains(day) else { return false }
        var random = SARandom.forDay(day, salt: silentSalt)
        return random.chance(silentProbability)
    }

    // MARK: Emission primitives

    /// The last place a `dwell` left, so the next one can add a fix on the way.
    private var lastDwell: (place: SAPlace, day: Int, leave: Double, zone: TimeZone)?

    private mutating func emitFix(_ place: SAPlace, _ day: Int, _ hour: Double, _ zone: TimeZone,
                                  _ random: inout SARandom, spread: Double) {
        fixes.append(SAFix(
            time: SAClock.at(day, hour, zone),
            lat: place.lat + random.range(-spread, spread),
            lon: place.lon + random.range(-spread, spread) * 1.5))
    }

    /// One isolated fix, as when passing through a station.
    private mutating func ping(_ place: SAPlace, _ day: Int, _ hour: Double, _ zone: TimeZone,
                               _ random: inout SARandom, spread: Double = 0.0012) {
        emitFix(place, day, hour, zone, &random, spread: spread)
        lastDwell = nil
    }

    /// Fixes for being at `place` from `from` to `to` local hours: one on
    /// arrival, usually a second within half an hour, then every 40 to 90
    /// minutes, and usually one just before leaving. A move of 6.5 km or more
    /// from the previous place the same day usually leaves one fix on the way,
    /// 6 to 21 minutes before arriving, which clusters into a single-fix stay
    /// of its own with a few minutes of dwell.
    private mutating func dwell(_ place: SAPlace, _ day: Int, _ from: Double, _ to: Double,
                                _ zone: TimeZone, _ random: inout SARandom,
                                spread: Double = 0.0012) {
        if let previous = lastDwell, previous.day == day, previous.zone == zone,
           (0.25...2.0).contains(from - previous.leave),
           HomeOrbit.greatCircleKm(previous.place.lat, previous.place.lon,
                                   place.lat, place.lon) >= 6.5,
           random.chance(0.85) {
            let midway = SAPlace("on the way",
                                 (previous.place.lat + place.lat) / 2,
                                 (previous.place.lon + place.lon) / 2)
            emitFix(midway, day, from - random.range(0.1, 0.35), zone, &random, spread: 0.002)
        }
        var last = from + random.range(0, 0.05)
        emitFix(place, day, last, zone, &random, spread: spread)
        if to - from >= 0.4, random.chance(0.85) {
            last = from + random.range(0.22, 0.45)
            emitFix(place, day, last, zone, &random, spread: spread)
        }
        while true {
            let next = last + random.range(0.7, 1.5)
            guard next < to - 0.25 else { break }
            last = next
            emitFix(place, day, last, zone, &random, spread: spread)
        }
        let leaving = to - random.range(0.03, 0.12)
        if leaving - last > 0.2, random.chance(0.8) {
            emitFix(place, day, leaving, zone, &random, spread: spread)
        }
        lastDwell = (place, day, to, zone)
    }

    // MARK: Day plans

    private mutating func emit(_ day: Int) {
        var random = SARandom.forDay(day, salt: Self.planSalt)
        let athens = SAClock.athens
        let brussels = SAClock.brussels
        let p = SAPlaces.self

        if let trip = options.dayTrips.first(where: { $0.day == day }) {
            dayTrip(trip, &random)
            return
        }
        if options.silentArrival, (0...2).contains(day) {
            // Landed about 12:35 on day 0; the first fix comes 48 hours later.
            if day == 2 {
                dwell(p.bruFlat, day, 12.7, 16.8, brussels, &random)
                dwell(p.bruFlat, day, 18.5, 22.4, brussels, &random)
            }
            return
        }
        if options.sparseAthensWeekend, (60...63).contains(day) {
            switch day {
            case 60:
                dwell(p.bruFlat, day, 7.8, 8.3, brussels, &random)
                dwell(p.bruCampus, day, 9.0, 12.5, brussels, &random)
                dwell(p.bruFlat, day, 13.0, 14.5, brussels, &random)
            case 61:
                ping(p.athHome, day, 15.0, athens, &random)
            case 63:
                dwell(p.bruFlat, day, 15.7, 18.2, brussels, &random)
                dwell(p.bruFlat, day, 20.0, 22.4, brussels, &random)
            default:
                break
            }
            return
        }

        switch day {
        case 0:
            dwell(p.athHome, day, 6.7, 7.2, athens, &random)
            dwell(p.athAirport, day, 8.2, 9.4, athens, &random, spread: 0.003)
            dwell(p.bruAirport, day, 12.7, 13.2, brussels, &random, spread: 0.003)
            dwell(p.bruFlat, day, 14.2, 17.2, brussels, &random)
            dwell(p.bruFlat, day, 18.5, 22.6, brussels, &random)
        case 18:
            dwell(p.bruFlat, day, 7.5, 7.95, brussels, &random)
            ping(p.wevelgemStation, day, 8.85, brussels, &random)
            dwell(p.ieper, day, 9.6, 17.9, brussels, &random, spread: 0.005)
            ping(p.wevelgemStation, day, 18.7, brussels, &random)
            dwell(p.bruFlat, day, 19.75, 22.2, brussels, &random)
        case 39:
            dwell(p.bruFlat, day, 7.8, 8.3, brussels, &random)
            dwell(p.bruCampus, day, 9.0, 12.5, brussels, &random)
            dwell(p.bruFlat, day, 13.1, 14.0, brussels, &random)
            ping(p.sintTruiden, day, 15.6, brussels, &random)
            dwell(p.bedburg, day, 16.5, 22.6, brussels, &random, spread: 0.004)
        case 40:
            dwell(p.bedburg, day, 9.5, 12.5, brussels, &random, spread: 0.004)
            dwell(p.bedburgOutskirts, day, 13.3, 15.3, brussels, &random)
            dwell(p.bedburg, day, 16.0, 22.5, brussels, &random, spread: 0.004)
        case 41:
            dwell(p.bedburg, day, 9.0, 14.8, brussels, &random, spread: 0.004)
            ping(p.sintTruiden, day, 15.8, brussels, &random)
            dwell(p.bruFlat, day, 17.4, 22.2, brussels, &random)
        case 60:
            dwell(p.bruFlat, day, 7.8, 8.3, brussels, &random)
            dwell(p.bruCampus, day, 9.0, 12.5, brussels, &random)
            dwell(p.bruFlat, day, 13.0, 14.5, brussels, &random)
            dwell(p.bruAirport, day, 15.5, 16.2, brussels, &random, spread: 0.003)
            dwell(p.athAirport, day, 21.25, 21.8, athens, &random, spread: 0.003)
            dwell(p.athHome, day, 22.5, 23.8, athens, &random)
        case 61:
            dwell(p.athHome, day, 10.5, 11.5, athens, &random)
            dwell(p.athNorth, day, 12.5, 16.0, athens, &random)
            dwell(p.athHome, day, 17.0, 19.0, athens, &random)
            dwell(p.athHome, day, 21.0, 23.2, athens, &random)
        case 62:
            dwell(p.athHome, day, 11.0, 12.0, athens, &random)
            dwell(p.athPort, day, 13.0, 15.5, athens, &random)
            dwell(p.athHome, day, 16.5, 18.5, athens, &random)
            dwell(p.athHome, day, 20.5, 22.9, athens, &random)
        case 63:
            dwell(p.athHome, day, 8.0, 8.6, athens, &random)
            dwell(p.athAirport, day, 10.0, 11.3, athens, &random, spread: 0.003)
            dwell(p.bruAirport, day, 14.2, 14.7, brussels, &random, spread: 0.003)
            dwell(p.bruFlat, day, 15.7, 18.2, brussels, &random)
            dwell(p.bruFlat, day, 20.0, 22.4, brussels, &random)
        case 100:
            dwell(p.bruFlat, day, 8.0, 8.5, brussels, &random)
            ping(p.zele, day, 9.7, brussels, &random)
            ping(p.bergenOpZoom, day, 10.85, brussels, &random)
            ping(p.schiphol, day, 11.6, brussels, &random)
            dwell(p.amsterdam, day, 12.2, 22.8, brussels, &random, spread: 0.006)
        case 101:
            dwell(p.amsterdam, day, 9.5, 13.0, brussels, &random, spread: 0.006)
            dwell(p.amsterdamNorth, day, 13.6, 16.5, brussels, &random)
            dwell(p.amsterdam, day, 17.2, 23.0, brussels, &random, spread: 0.006)
        case 102:
            dwell(p.amsterdam, day, 9.0, 9.8, brussels, &random, spread: 0.006)
            dwell(p.soest, day, 10.6, 16.0, brussels, &random, spread: 0.004)
            dwell(p.amsterdam, day, 17.0, 22.5, brussels, &random, spread: 0.006)
        case 103:
            dwell(p.amsterdam, day, 10.0, 22.9, brussels, &random, spread: 0.008)
        case 104:
            dwell(p.amsterdam, day, 10.5, 14.0, brussels, &random, spread: 0.006)
            dwell(p.amsterdamNorth, day, 14.7, 18.0, brussels, &random)
            dwell(p.amsterdam, day, 18.8, 23.3, brussels, &random, spread: 0.006)
        case 105:
            dwell(p.amsterdam, day, 9.0, 12.8, brussels, &random, spread: 0.006)
            ping(p.schiphol, day, 13.6, brussels, &random)
            ping(p.bergenOpZoom, day, 14.5, brussels, &random)
            ping(p.zele, day, 15.7, brussels, &random)
            dwell(p.bruFlat, day, 17.0, 22.2, brussels, &random)
        case 150:
            dwell(p.bruFlat, day, 7.5, 8.1, brussels, &random)
            dwell(p.bruAirport, day, 9.5, 10.8, brussels, &random, spread: 0.003)
            dwell(p.athAirport, day, 15.5, 16.0, athens, &random, spread: 0.003)
            dwell(p.athHome, day, 17.0, 21.7, athens, &random)
        case 232:
            dwell(p.athHome, day, 6.5, 7.0, athens, &random)
            dwell(p.athAirport, day, 8.0, 9.3, athens, &random, spread: 0.003)
            dwell(p.bruAirport, day, 12.6, 13.1, brussels, &random, spread: 0.003)
            dwell(p.bruHotel, day, 14.2, 22.6, brussels, &random, spread: 0.005)
        case 233:
            dwell(p.bruHotel, day, 9.0, 10.0, brussels, &random)
            dwell(p.bruAttraction, day, 10.8, 13.2, brussels, &random)
            dwell(p.bruHotel, day, 14.0, 23.0, brussels, &random, spread: 0.005)
        case 234:
            dwell(p.bruHotel, day, 9.5, 10.2, brussels, &random)
            dwell(p.bruEast, day, 11.0, 14.0, brussels, &random)
            dwell(p.bruHotel, day, 15.0, 23.0, brussels, &random, spread: 0.005)
        case 235:
            dwell(p.bruHotel, day, 10.0, 12.5, brussels, &random, spread: 0.005)
            dwell(p.bruCampus, day, 13.2, 16.0, brussels, &random)
            dwell(p.bruHotel, day, 17.0, 23.0, brussels, &random, spread: 0.005)
        case 236:
            dwell(p.bruHotel, day, 8.5, 9.1, brussels, &random)
            dwell(p.bruAirport, day, 10.8, 12.1, brussels, &random, spread: 0.003)
            dwell(p.athAirport, day, 16.7, 17.2, athens, &random, spread: 0.003)
            dwell(p.athHome, day, 18.2, 22.2, athens, &random)
        case 1...149:
            guard !Self.isSilent(day) else { return }
            brusselsDay(day, &random)
        default:
            guard !Self.isSilent(day) else { return }
            athensDay(day, &random)
        }
    }

    private static func isWeekend(_ day: Int) -> Bool {
        ((day % 7) + 7) % 7 >= 5
    }

    private mutating func brusselsDay(_ day: Int, _ random: inout SARandom) {
        let zone = SAClock.brussels
        let p = SAPlaces.self
        if !Self.isWeekend(day) {
            dwell(p.bruFlat, day, 7.8, 8.3, zone, &random)
            dwell(p.bruCampus, day, 9.0, 12.8, zone, &random)
            if random.chance(0.7) { dwell(p.bruLunch, day, 13.05, 13.8, zone, &random) }
            if random.chance(0.85) { dwell(p.bruCampus, day, 14.05, 17.0, zone, &random) }
            dwell(p.bruFlat, day, 17.7, 19.8, zone, &random)
            if random.chance(0.45) {
                let out = [p.bruNorth, p.bruEast, p.bruWest][Int(random.next() % 3)]
                dwell(out, day, 20.3, 22.6, zone, &random)
                dwell(p.bruFlat, day, 23.1, 23.5, zone, &random)
            } else if random.chance(0.3) {
                // A quick errand across town: one fix there, then home again.
                let errand = [p.bruNorth, p.bruEast, p.bruWest][Int(random.next() % 3)]
                ping(errand, day, 20.6, zone, &random)
                ping(p.bruFlat, day, 21.5, zone, &random)
                if random.chance(0.5) { ping(p.bruFlat, day, 23.0, zone, &random) }
            } else {
                if random.chance(0.6) { ping(p.bruFlat, day, 21.5, zone, &random) }
                if random.chance(0.5) { ping(p.bruFlat, day, 23.0, zone, &random) }
            }
            return
        }
        switch random.next() % 3 {
        case 0:
            dwell(p.bruFlat, day, 10.5, 11.2, zone, &random)
            dwell(p.bruWest, day, 11.8, 13.1, zone, &random)
            dwell(p.bruFlat, day, 13.7, 17.0, zone, &random)
            dwell(p.bruEast, day, 17.7, 19.5, zone, &random)
            dwell(p.bruFlat, day, 20.2, 22.2, zone, &random)
        case 1:
            dwell(p.bruFlat, day, 11.0, 12.0, zone, &random)
            dwell(p.bruNorth, day, 12.7, 15.5, zone, &random)
            dwell(p.bruFlat, day, 16.2, 18.0, zone, &random)
            if random.chance(0.7) { ping(p.bruFlat, day, 20.0, zone, &random) }
            if random.chance(0.6) { ping(p.bruFlat, day, 22.5, zone, &random) }
        default:
            dwell(p.bruFlat, day, 9.5, 10.0, zone, &random)
            dwell(p.bruCampus, day, 10.6, 16.0, zone, &random)
            dwell(p.bruFlat, day, 16.7, 19.0, zone, &random)
            dwell(p.bruEast, day, 20.0, 23.5, zone, &random)
            dwell(p.bruFlat, day, 24.2, 24.5, zone, &random)
        }
    }

    private mutating func athensDay(_ day: Int, _ random: inout SARandom) {
        let zone = SAClock.athens
        let p = SAPlaces.self
        if !Self.isWeekend(day) {
            dwell(p.athHome, day, 7.9, 8.4, zone, &random)
            dwell(p.athUni, day, 9.1, 13.0, zone, &random)
            if random.chance(0.5) { dwell(p.athGym, day, 13.6, 15.0, zone, &random) }
            if random.chance(0.6) { dwell(p.athUni, day, 15.6, 17.5, zone, &random) }
            dwell(p.athHome, day, 18.2, 20.0, zone, &random)
            if random.chance(0.4) {
                dwell(p.athNorth, day, 20.8, 23.3, zone, &random)
                dwell(p.athHome, day, 24.0, 24.4, zone, &random)
            } else if random.chance(0.3) {
                let errand = [p.athGym, p.athPort, p.athUni][Int(random.next() % 3)]
                ping(errand, day, 20.8, zone, &random)
                ping(p.athHome, day, 21.7, zone, &random)
                if random.chance(0.5) { ping(p.athHome, day, 23.2, zone, &random) }
            } else {
                if random.chance(0.6) { ping(p.athHome, day, 21.7, zone, &random) }
                if random.chance(0.5) { ping(p.athHome, day, 23.2, zone, &random) }
            }
            return
        }
        dwell(p.athHome, day, 10.5, 11.5, zone, &random)
        if random.chance(0.5) {
            dwell(p.athPort, day, 12.3, 15.0, zone, &random)
        } else {
            dwell(p.athNorth, day, 12.5, 16.0, zone, &random)
        }
        dwell(p.athHome, day, 16.8, 18.2, zone, &random)
        if random.chance(0.5) { dwell(p.athGym, day, 18.8, 20.5, zone, &random) }
        dwell(p.athHome, day, 21.2, 23.0, zone, &random)
    }

    /// Flat, out to the place for `dwellHours`, back to the flat the same day.
    /// The fix on the way is explicit here, never drawn, so a variant controls
    /// exactly which excursions hold a stay outside the place itself.
    private mutating func dayTrip(_ trip: DayTrip, _ random: inout SARandom) {
        let zone = SAClock.brussels
        let p = SAPlaces.self
        let day = trip.day
        dwell(p.bruFlat, day, 8.0, 8.5, zone, &random)
        let arrive = 9.5
        let leave = arrive + trip.dwellHours
        let midway = SAPlace("on the way", (p.bruFlat.lat + trip.place.lat) / 2,
                             (p.bruFlat.lon + trip.place.lon) / 2)
        if trip.sparseWaypoints {
            ping(midway, day, arrive - 0.6, zone, &random, spread: 0.002)
        } else if trip.fixOnTheWay {
            ping(midway, day, arrive - random.range(0.1, 0.35), zone, &random, spread: 0.002)
        }
        lastDwell = nil
        dwell(trip.place, day, arrive, leave, zone, &random, spread: 0.003)
        let back = leave + 1.0
        if trip.sparseWaypoints {
            ping(midway, day, back - 0.6, zone, &random, spread: 0.002)
        }
        lastDwell = nil
        dwell(p.bruFlat, day, back, back + 0.7, zone, &random)
        if back < 13.0 { dwell(p.bruCampus, day, 14.0, 17.0, zone, &random) }
        dwell(p.bruFlat, day, 17.7, 19.8, zone, &random)
        ping(p.bruFlat, day, 21.5, zone, &random)
        ping(p.bruFlat, day, 23.0, zone, &random)
    }

    // MARK: Imported pre-history (V4)

    /// A four-day Brussels holiday in March 2026, with Athens photos before
    /// and after it. Every date precedes the Athens Home row.
    static func importedHoliday() -> [ImportedPingCandidate] {
        let athens = SAClock.athens
        let brussels = SAClock.brussels
        let p = SAPlaces.self
        var random = SARandom(seed: 0x5A_E2A5_0003)
        var out: [ImportedPingCandidate] = []
        func photo(_ place: SAPlace, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
                   _ zone: TimeZone, year: Int = 2026) {
            out.append(ImportedPingCandidate(
                timestamp: SAClock.absolute(year, month, day, hour, minute, zone),
                latitude: place.lat + random.range(-0.002, 0.002),
                longitude: place.lon + random.range(-0.003, 0.003),
                horizontalAccuracy: 10))
        }
        photo(p.athHome, 3, 28, 13, 0, athens)
        photo(p.athHome, 4, 5, 12, 0, athens)
        photo(p.athHome, 4, 5, 12, 20, athens)
        photo(p.bruHotel, 4, 10, 14, 0, brussels)
        photo(p.bruHotel, 4, 10, 16, 30, brussels)
        photo(p.bruHotel, 4, 10, 20, 0, brussels)
        photo(p.bruAttraction, 4, 11, 10, 0, brussels)
        photo(p.bruAttraction, 4, 11, 11, 15, brussels)
        photo(p.bruHotel, 4, 11, 13, 30, brussels)
        photo(p.bruHotel, 4, 11, 18, 0, brussels)
        photo(p.bruHotel, 4, 11, 21, 0, brussels)
        photo(p.bruLunch, 4, 12, 11, 0, brussels)
        photo(p.bruHotel, 4, 12, 15, 0, brussels)
        photo(p.bruHotel, 4, 12, 19, 30, brussels)
        photo(p.bruHotel, 4, 13, 10, 0, brussels)
        photo(p.bruHotel, 4, 13, 12, 30, brussels)
        photo(p.athHome, 4, 16, 13, 0, athens)
        photo(p.athHome, 4, 16, 13, 30, athens)
        photo(p.athHome, 7, 1, 19, 0, athens)
        photo(p.athHome, 12, 25, 14, 0, athens)
        photo(p.athHome, 5, 10, 18, 0, athens, year: 2027)
        return out.sorted { $0.timestamp < $1.timestamp }
    }
}

// MARK: - Harness

struct SAError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Collects the recovery records healing parks, from the classifier's sink
/// (off the main actor) and from the healing trigger's drain.
final class SAParkedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [DissolvedTripRecord] = []

    func append(_ incoming: [DissolvedTripRecord]) {
        lock.lock()
        defer { lock.unlock() }
        for record in incoming where !records.contains(where: { $0.id == record.id }) {
            records.append(record)
        }
    }

    var all: [DissolvedTripRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}

struct SATripRow: Sendable, Equatable {
    let startDay: Double
    let endDay: Double?
    let isComplete: Bool
    let summary: String
    let countries: String
    let stays: Int
    let userEdited: Bool
    let customName: String?

    /// "d0→d60" or "d0→open": whole scenario days, UTC.
    var span: String {
        let end = endDay.map { "d\(Int($0.rounded(.down)))" } ?? "open"
        return "d\(Int(startDay.rounded(.down)))→\(end)"
    }
}

/// One printed table and the facts the pins read from it.
struct SASnapshot: Sendable {
    let title: String
    let text: String
    let trips: [SATripRow]
    let homeStartDays: [String: Double]
    let homeStaysByHome: [String: Int]
    let triplessDestinations: Int
    let suppressedGroups: Int
    let learnedDiscs: Int
    let dissolvedTrips: Int
    let travelDays: [Int: Int]

    var spans: [String] { trips.map(\.span) }
}

@MainActor
final class SAHarness {
    let container: ModelContainer
    let recorder: PingRecorder
    let clusterer: StayClusterer
    let classifier: TripClassifier
    let gate = PipelineGate(forTesting: ())
    let athensShape: HomeShape
    let brusselsShape: HomeShape

    private let healSuite: String
    private let healDefaults: UserDefaults
    let parked = SAParkedBox()
    let fixes: [SAFix]
    private var cursor = 0
    private var ticks: [(time: Date, heals: Bool)] = []
    private var tickIndex = 0
    private(set) var now: Date
    private(set) var notes: [String] = []
    private var notesShown = 0
    private(set) var passCount = 0
    private(set) var healChecks = 0
    private(set) var healRuns = 0
    private(set) var healMoved = 0
    private(set) var snapshots: [SASnapshot] = []

    static let installDate = SAClock.at(SATrace.firstDay, 0, SAClock.athens)
    static let traceEnd = SAClock.at(SATrace.lastDay + 1, 12, SAClock.utc)

    static func make(_ options: SATrace.Options = .init()) async throws -> SAHarness {
        let p = SAPlaces.self
        let athens = await HomeShapeProvider.shared.shape(
            latitude: p.athHome.lat, longitude: p.athHome.lon)
        let brussels = await HomeShapeProvider.shared.shape(
            latitude: p.bruFlat.lat, longitude: p.bruFlat.lon)
        let harness = try SAHarness(options: options, athensShape: athens, brusselsShape: brussels)
        await harness.classifier.setDissolvedRecordSink { [parked = harness.parked] records in
            parked.append(records)
        }
        // Onboarding: the Athens Home exists before any live fix.
        try await harness.insertHome(label: "Athens", place: p.athHome, startedAt: installDate)
        return harness
    }

    private init(options: SATrace.Options, athensShape: HomeShape, brusselsShape: HomeShape) throws {
        container = try TestSupport.makeInMemoryContainer()
        recorder = PingRecorder(modelContainer: container)
        clusterer = StayClusterer(modelContainer: container)
        classifier = TripClassifier(modelContainer: container)
        self.athensShape = athensShape
        self.brusselsShape = brusselsShape
        healSuite = "StudyAbroadScenario-\(UUID().uuidString)"
        healDefaults = UserDefaults(suiteName: healSuite)!
        fixes = SATrace.build(options)
        now = Self.installDate
        // Two pipeline passes a day, at 12:00 and 21:30 UTC; the evening one
        // is followed by the launch healing check.
        for day in SATrace.firstDay...(SATrace.lastDay + 1) {
            ticks.append((SAClock.at(day, 12, SAClock.utc), false))
            ticks.append((SAClock.at(day, 21.5, SAClock.utc), true))
        }
    }

    func tearDown() {
        healDefaults.removePersistentDomain(forName: healSuite)
    }

    func note(_ text: String) {
        notes.append("\(SAClock.stamp(now))  \(text)")
    }

    // MARK: Ingest and passes

    private func ingest(upTo time: Date) async {
        var batch: [LiveLocationCandidate] = []
        while cursor < fixes.count, fixes[cursor].time <= time {
            let fix = fixes[cursor]
            batch.append(LiveLocationCandidate(CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: fix.lat, longitude: fix.lon),
                altitude: 0, horizontalAccuracy: 65, verticalAccuracy: -1,
                course: -1, speed: -1, timestamp: fix.time), source: .liveSLC))
            cursor += 1
        }
        guard !batch.isEmpty else { return }
        _ = await recorder.processLocations(batch, defaults: TestSupport.liveFloorFreeDefaults)
    }

    /// One app wake: cluster what arrived, then the ordinary pipeline pass.
    func pass(at time: Date, heals: Bool = false) async {
        now = max(now, time)
        await ingest(upTo: time)
        _ = await clusterer.clusterUnprocessedPings()
        _ = await classifier.classifyAndAssembleTripsWithGates(gate: gate)
        passCount += 1
        if heals { await heal() }
    }

    /// The launch healing check (`HomeAreaHealing.healIfNeeded`) on this store.
    func heal() async {
        healChecks += 1
        let classifier = self.classifier
        let gate = self.gate
        let stages = HomeAreaHealing.Stages(
            rescue: {},
            fingerprint: { await classifier.homeAreaFingerprint() },
            heal: { [weak self] stale in
                let outcome = await gate.runReturning(touching: [.stay, .trip]) {
                    await classifier.healHomeAreaCorrections(
                        pinnedTripIDs: [], staleCoverage: stale)
                }
                self?.healRuns += 1
                self?.healMoved += outcome.moved
                if outcome.moved > 0 || outcome.failed {
                    self?.note("healing ran and moved \(outcome.moved) trip(s) or stay(s) (failed: \(outcome.failed))")
                }
                return outcome
            },
            drainParked: { await classifier.drainParkedDissolvedTrips() },
            classify: {
                await classifier.classifyAndAssembleTripsQueuedWithGates(
                    maxStaysPerCall: nil, gate: gate)
            },
            generateTitles: {},
            coverage: { try await classifier.homeAreaCoverage() },
            bumpChanges: {},
            reloadWidgets: {})
        _ = await HomeAreaHealing.healIfNeeded(defaults: healDefaults, stages: stages)
    }

    /// Run every scheduled pass up to `target`, then ingest the remaining
    /// fixes up to it without a pass.
    func advance(to target: Date) async {
        while tickIndex < ticks.count, ticks[tickIndex].time <= target {
            let tick = ticks[tickIndex]
            tickIndex += 1
            await pass(at: tick.time, heals: tick.heals)
        }
        now = max(now, target)
        await ingest(upTo: target)
    }

    func finish() async {
        await advance(to: Self.traceEnd)
        await pass(at: Self.traceEnd, heals: true)
    }

    // MARK: User actions

    @discardableResult
    private func insertHome(label: String, place: SAPlace, startedAt: Date) async throws -> UUID {
        let resolved = await GeocodeResolver.shared.resolve(
            latitude: place.lat, longitude: place.lon)
        let context = ModelContext(container)
        let home = Home(label: label, latitude: place.lat, longitude: place.lon,
                        radiusKm: 25, startedAt: startedAt)
        home.locality = resolved?.localityForStorage
        home.administrativeArea = resolved?.administrativeArea
        home.country = resolved?.country
        home.isoCountryCode = resolved?.isoCountryCode
        context.insert(home)
        try context.save()
        TripTitleStore.invalidateHomePlaceIndex()
        return home.id
    }

    /// Settings, Add Home, "Keep Both as a Second Home", at scenario time `at`.
    @discardableResult
    func declareHome(label: String, place: SAPlace, at time: Date) async throws -> UUID {
        // The app is open: its activation pass runs first.
        await pass(at: time)
        let homeID = try await insertHome(label: label, place: place, startedAt: time)
        // `applyHomeChange`: prime shapes and orbits, reconcile, then a full
        // pass when stays were reset. Its title stage is not run.
        _ = await classifier.homeAreaFingerprint()
        let classifier = self.classifier
        let outcome = await gate.runReturning(touching: [.home, .stay, .trip]) {
            await classifier.applyHomeChangeCore(homeID: homeID)
        }
        var followUp = "no follow-up pass"
        if outcome.resetCount > 0 {
            let committed = await classifier.classifyAndAssembleTripsQueuedWithGates(
                maxStaysPerCall: nil, gate: gate)
            followUp = "follow-up pass committed: \(committed)"
        }
        let stored = try ModelContext(container).fetch(FetchDescriptor<Home>())
            .first { $0.id == homeID }
        note("declared Home \"\(label)\" with startedAt = now; reconciliation \(outcome), "
             + "\(followUp); startedAt is now \(SAClock.stamp(stored?.startedAt))")
        // Settings heals right after the reconciliation settles.
        await heal()
        return homeID
    }

    /// Settings, swipe to delete a Home: `endedAt` = now and nothing else.
    func endHome(_ homeID: UUID, at time: Date) async throws {
        await pass(at: time)
        let context = ModelContext(container)
        guard let home = try context.fetch(FetchDescriptor<Home>()).first(where: { $0.id == homeID })
        else { throw SAError("the Home to end is missing") }
        home.endedAt = time
        try context.save()
        TripTitleStore.invalidateHomePlaceIndex()
        note("ended Home \"\(home.label)\" with endedAt = now")
    }

    /// The rename sheet in the trip detail, on the one open trip.
    func renameOpenTrip(_ name: String, at time: Date) async throws {
        await pass(at: time)
        let context = ModelContext(container)
        let open = try context.fetch(FetchDescriptor<Trip>()).filter { !$0.isComplete }
        guard open.count == 1, let trip = open.first else {
            throw SAError("expected one open trip to rename, found \(open.count)")
        }
        let stays = (trip.stays ?? []).count
        guard TripDetailView.applyRename(tripID: trip.id, tripIdentifier: trip.persistentModelID, newName: name, in: context) else {
            throw SAError("the rename did not save")
        }
        note("renamed the open trip (start \(SAClock.stamp(trip.startDate)), \(stays) stays) "
             + "to \"\(name)\"; userEdited is now \(trip.userEdited)")
    }

    /// List the stays that joined a trip from `time` on: what the trip holds
    /// for the days after a rename.
    func noteTripStays(since time: Date) throws {
        let stays = try ModelContext(container).fetch(FetchDescriptor<Stay>(
            sortBy: [SortDescriptor(\.startTime)]))
            .filter { $0.trip != nil && $0.startTime >= time }
        let listing = stays.map {
            String(format: "d%.2f %@ %ldmin %ld fix", SAClock.dayNumber($0.startTime),
                   $0.category.rawValue, $0.durationMinutes, $0.pingCount)
        }.joined(separator: "; ")
        note("trip members that started after \(SAClock.stamp(time)): \(stays.count)  \(listing)")
    }

    /// A photo import through the import lane, then cluster and classify as
    /// the import service does (no recent-stay reconsideration, no cap).
    func importPhotos(_ candidates: [ImportedPingCandidate]) async throws {
        await recorder.beginImportDedupSession()
        let accepted = try await recorder.recordImportedPings(candidates, source: .photoImport)
        try await recorder.saveImportBatch()
        await recorder.endImportDedupSession()
        _ = await clusterer.clusterUnprocessedPings()
        _ = await classifier.classifyAndAssembleTripsWithGates(
            reclassifyRecentStays: false, maxStaysPerCall: nil, gate: gate)
        note("imported \(accepted) photo fixes dated \(SAClock.stamp(candidates.first?.timestamp)) "
             + "to \(SAClock.stamp(candidates.last?.timestamp))")
    }

    // MARK: Reading the store

    private enum Region: String, CaseIterable {
        case athens = "Athens centre"
        case brussels = "Brussels centre"
        case elsewhere = "elsewhere"
    }

    private func region(_ latitude: Double, _ longitude: Double) -> Region {
        if athensShape.contains(latitude: latitude, longitude: longitude) { return .athens }
        if brusselsShape.contains(latitude: latitude, longitude: longitude) { return .brussels }
        return .elsewhere
    }

    private static func describe(_ shape: HomeShape) -> String {
        switch shape.seed {
        case .urbanCentre(let id, let name):
            return String(format: "urban centre \"%@\" #%lld, %.0f km2, D* %.1f km",
                          name ?? "unnamed", id, shape.areaKm2, shape.areaEquivalentRadiusKm)
        case .fallbackDisc:
            return "fallback 1 km disc"
        }
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.padding(toLength: max(width, text.count + 1), withPad: " ", startingAt: 0)
    }

    /// Record the table for one variant, or for one checkpoint inside it.
    func snapshot(_ title: String, closing: Bool = true) async throws {
        let context = ModelContext(container)
        let trips = try context.fetch(FetchDescriptor<Trip>()).sorted { $0.startDate < $1.startDate }
        let stays = try context.fetch(FetchDescriptor<Stay>(sortBy: [SortDescriptor(\.startTime)]))
        let homes = try context.fetch(FetchDescriptor<Home>()).sorted { $0.startedAt < $1.startedAt }
        var lines: [String] = []
        lines.append("")
        lines.append("=== \(title) ===")
        lines.append("at      \(SAClock.stamp(now))")
        for home in homes {
            lines.append("home    \(home.label): startedAt \(SAClock.stamp(home.startedAt)), "
                         + "endedAt \(SAClock.stamp(home.endedAt))")
        }
        lines.append("trips   \(trips.count)")
        var rows: [SATripRow] = []
        for (index, trip) in trips.enumerated() {
            let members = trip.stays ?? []
            let destinations = members.filter { $0.category == .destination }.count
            let transits = members.filter { $0.category == .transit }.count
            let days = trip.durationDays.map { "\($0)d" } ?? "-"
            let name = trip.customName.map { ", customName \"\($0)\"" } ?? ""
            let source = trip.sourceRaw == DataSource.liveSLC.rawValue ? "" : ", source \(trip.sourceRaw)"
            lines.append(String(
                format: "  %2ld  %@ -> %@  %@  %@  stays %ld (%ld dest, %ld transit)  [%@]  userEdited=%@  \"%@\"%@%@",
                index + 1, SAClock.stamp(trip.startDate), SAClock.stamp(trip.endDate), days,
                trip.isComplete ? "complete" : "open", members.count, destinations, transits,
                trip.countryCodes, trip.userEdited ? "yes" : "no", trip.destinationSummary,
                name, source))
            rows.append(SATripRow(
                startDay: SAClock.dayNumber(trip.startDate),
                endDay: trip.endDate.map(SAClock.dayNumber),
                isComplete: trip.isComplete, summary: trip.destinationSummary,
                countries: trip.countryCodes, stays: members.count,
                userEdited: trip.userEdited, customName: trip.customName))
        }

        // Stays by where they are and what state they are in.
        let columns = ["home", "routine", "dest in trip", "dest tripless", "transit in trip",
                       "transit tripless", "unclassified"]
        var matrix: [Region: [Int]] = [:]
        for stay in stays {
            let column: Int
            switch stay.category {
            case .home: column = 0
            case .routine: column = 1
            case .destination: column = stay.trip == nil ? 3 : 2
            case .transit: column = stay.trip == nil ? 5 : 4
            case .unclassified: column = 6
            }
            matrix[region(stay.centroidLatitude, stay.centroidLongitude),
                   default: Array(repeating: 0, count: columns.count)][column] += 1
        }
        lines.append("stays   \(stays.count) total; rows are where the stay is, columns its state")
        lines.append("        " + Self.pad("where", 17) + columns.map { Self.pad($0, 18) }.joined())
        for region in Region.allCases {
            let row = matrix[region] ?? Array(repeating: 0, count: columns.count)
            lines.append("        " + Self.pad(region.rawValue, 17)
                         + row.map { Self.pad(String($0), 18) }.joined())
        }

        // `.home` stays by nearest Home row.
        var nearest: [String: Int] = [:]
        for stay in stays where stay.category == .home {
            let label = homes.min {
                HomeOrbit.greatCircleKm($0.latitude, $0.longitude,
                                        stay.centroidLatitude, stay.centroidLongitude)
                    < HomeOrbit.greatCircleKm($1.latitude, $1.longitude,
                                              stay.centroidLatitude, stay.centroidLongitude)
            }?.label ?? "none"
            nearest[label, default: 0] += 1
        }
        lines.append(".home stays by nearest Home: "
                     + (nearest.isEmpty ? "none" : nearest.sorted { $0.key < $1.key }
                        .map { "\($0.key) \($0.value)" }.joined(separator: ", ")))
        let tripless = stays.filter { $0.trip == nil }
        let triplessDestinations = tripless.filter { $0.category == .destination }.count
        lines.append("tripless: destination \(triplessDestinations), "
                     + "transit \(tripless.filter { $0.category == .transit }.count), "
                     + "unclassified \(tripless.filter { $0.category == .unclassified }.count)")

        let liveHome = stays.filter { $0.category == .home && $0.source == .liveSLC }
        let measured = liveHome.filter {
            $0.pingCount >= 2 && $0.endTime.timeIntervalSince($0.startTime) >= 15 * 60
        }
        let single = liveHome.filter { $0.pingCount == 1 }
        lines.append("live .home stays \(liveHome.count): \(measured.count) with 2+ fixes and 15+ min "
                     + "(the ones that can bound a trip), \(single.count) single-fix")

        let suppressed = await classifier.suppressedGroups()
        lines.append("near-home activity (gate-suppressed groups): \(suppressed.count)"
                     + (suppressed.isEmpty ? "" : "  " + suppressed.map {
                         String(format: "d%.1f %@ %.1fh", SAClock.dayNumber($0.start),
                                $0.placeName ?? "?", $0.dwellHours)
                     }.joined(separator: "; ")))
        let learned = await classifier.learnedPlaces()
        lines.append("learned orbit discs: \(learned.count)"
                     + (learned.isEmpty ? "" : "  " + learned.map { place in
                         let owner = homes.first { $0.id == place.homeID }?.label ?? "?"
                         return String(format: "%@: %.3f,%.3f r %.1f km, %ld returns, first %@",
                                       owner, place.latitude, place.longitude, place.radiusKm,
                                       place.returnCount, SAClock.stamp(place.firstReturn))
                     }.joined(separator: "; ")))
        let dissolved = parked.all.sorted { $0.startDate < $1.startDate }
        lines.append("trips dissolved by healing (parked for restore): \(dissolved.count)"
                     + (dissolved.isEmpty ? "" : "  " + dissolved.map {
                         "\"\($0.displayName)\" \(SAClock.stamp($0.startDate))"
                     }.joined(separator: "; ")))

        let labels = try TravelDays.labels(container: container, now: now, fallbackZone: SAClock.utc)
        var travelDays: [Int: Int] = [:]
        for year in [2026, 2027, 2028] { travelDays[year] = TravelDays.count(labels, inYear: year) }
        lines.append("TravelDays labels: 2026 = \(travelDays[2026] ?? 0), "
                     + "2027 = \(travelDays[2027] ?? 0), 2028 = \(travelDays[2028] ?? 0) "
                     + "(counted as of the 'at' line)")

        if closing {
            var gaps24 = 0, gaps48 = 0, longest = 0.0
            for (previous, next) in zip(fixes, fixes.dropFirst()) {
                let hours = next.time.timeIntervalSince(previous.time) / 3600
                if hours > 24 { gaps24 += 1 }
                if hours > 48 { gaps48 += 1 }
                longest = max(longest, hours)
            }
            let span = Double(SATrace.lastDay - SATrace.firstDay + 1)
            lines.append(String(
                format: "trace   %ld live fixes over %.0f days (%.1f a day), gaps over 24 h: %ld, over 48 h: %ld, longest %.1f h",
                fixes.count, span, Double(fixes.count) / span, gaps24, gaps48, longest))
            lines.append("seeds   Athens: \(Self.describe(athensShape)); Brussels: \(Self.describe(brusselsShape))")
            lines.append("run     \(passCount) pipeline passes, \(healChecks) healing checks "
                         + "(\(healRuns) found the home area changed and ran, moving \(healMoved) trips or stays)")
        }
        // A checkpoint lists what happened since the previous table; the
        // closing table lists everything.
        let shown = closing ? notes[...] : notes[notesShown...]
        notesShown = notes.count
        if !shown.isEmpty {
            lines.append(closing ? "events (whole run)" : "events since the previous table")
            lines.append(contentsOf: shown.map { "  " + $0 })
        }
        snapshots.append(SASnapshot(
            title: title, text: lines.joined(separator: "\n"), trips: rows,
            homeStartDays: Dictionary(homes.map { ($0.label, SAClock.dayNumber($0.startedAt)) },
                                      uniquingKeysWith: { first, _ in first }),
            homeStaysByHome: nearest, triplessDestinations: triplessDestinations,
            suppressedGroups: suppressed.count, learnedDiscs: learned.count,
            dissolvedTrips: dissolved.count, travelDays: travelDays))
    }
}

// MARK: - Variants

enum SAVariant: String, CaseIterable, Sendable {
    case v0, v1, v2, v3, v3b, v3c, v4, v5a, v5b, v6, v7, v7b, v7c, v8, v8b

    /// Just before the first Belgian fix on day 0 (the airport, 12:42 local).
    static let arrival = SAClock.at(0, 12.6, SAClock.brussels)
    /// The evening of day 45, at the flat, after Ieper and Bedburg.
    static let lateDeclaration = SAClock.at(45, 20.5, SAClock.brussels)
    /// The evening of day 150, back at the Athens home.
    static let finalReturn = SAClock.at(150, 22, SAClock.athens)
    /// The morning of day 150, still at the flat, before the first fix of the day.
    static let beforeLeaving = SAClock.at(150, 7, SAClock.brussels)

    var title: String {
        switch self {
        case .v0: "V0 nothing declared: only the Athens Home"
        case .v1: "V1 second Home at the Brussels flat, declared at arrival, never ended"
        case .v2: "V2 late declaration on day 45, the way Settings adds a Home"
        case .v3: "V3 as V1, Brussels Home ended at the final return, then the Brussels holiday"
        case .v3b: "V3b as V1, the user forgets to end the Brussels Home, then the Brussels holiday"
        case .v3c: "V3c as V1, Brussels Home ended on the last morning at the flat, before leaving"
        case .v4: "V4 prehistory: a photo-imported Brussels holiday from before every Home, then V1"
        case .v5a: "V5a sparse Athens weekend (one live fix, no visit), nothing declared"
        case .v5b: "V5b sparse Athens weekend (one live fix, no visit), Brussels Home as V1"
        case .v6: "V6 as V2, but the open big trip is renamed (userEdited) before the late declaration"
        case .v7: "V7 as V1 with four same-day returns from Dendermonde, 2 h each"
        case .v7b: "V7b as V1 with four same-day returns from Wevelgem, 5 h each"
        case .v7c: "V7c as V7b, but every visit leaves one fix on the way out and one on the way back, each 36 min before the next fix"
        case .v8: "V8 as V1, no fix on the flight day and 48 h of silence after landing"
        case .v8b: "V8b nothing declared, no fix on the flight day and 48 h of silence after landing"
        }
    }

    var options: SATrace.Options {
        switch self {
        case .v5a, .v5b:
            return .init(sparseAthensWeekend: true)
        case .v7:
            return .init(dayTrips: Self.dayTrips(to: SAPlaces.dendermonde, dwellHours: 2))
        case .v7b:
            return .init(dayTrips: Self.dayTrips(to: SAPlaces.wevelgem, dwellHours: 5))
        case .v7c:
            return .init(dayTrips: SATrace.dayTripDays.map {
                .init(day: $0, place: SAPlaces.wevelgem, dwellHours: 5, fixOnTheWay: false,
                      sparseWaypoints: true)
            })
        case .v8, .v8b:
            return .init(silentArrival: true)
        default:
            return .init()
        }
    }

    /// Visits 1 and 3 leave a fix on the way out; visits 2 and 4 do not.
    private static func dayTrips(to place: SAPlace, dwellHours: Double) -> [SATrace.DayTrip] {
        SATrace.dayTripDays.enumerated().map { index, day in
            .init(day: day, place: place, dwellHours: dwellHours, fixOnTheWay: index % 2 == 0)
        }
    }

    @MainActor
    func run(_ harness: SAHarness) async throws {
        let flat = SAPlaces.bruFlat
        switch self {
        case .v0, .v5a, .v8b:
            break

        case .v1, .v5b, .v8:
            await harness.advance(to: Self.arrival)
            try await harness.declareHome(label: "Brussels", place: flat, at: Self.arrival)

        case .v2:
            await harness.advance(to: Self.lateDeclaration)
            await harness.pass(at: Self.lateDeclaration)
            try await harness.snapshot("V2 checkpoint: day 45, before the declaration", closing: false)
            try await harness.declareHome(label: "Brussels", place: flat, at: Self.lateDeclaration)
            try await harness.snapshot("V2 checkpoint: day 45, right after the declaration",
                                       closing: false)

        case .v3:
            await harness.advance(to: Self.arrival)
            let brussels = try await harness.declareHome(
                label: "Brussels", place: flat, at: Self.arrival)
            await harness.advance(to: Self.finalReturn)
            try await harness.endHome(brussels, at: Self.finalReturn)

        case .v3c:
            await harness.advance(to: Self.arrival)
            let brussels = try await harness.declareHome(
                label: "Brussels", place: flat, at: Self.arrival)
            await harness.advance(to: Self.beforeLeaving)
            try await harness.endHome(brussels, at: Self.beforeLeaving)

        case .v3b:
            await harness.advance(to: Self.arrival)
            try await harness.declareHome(label: "Brussels", place: flat, at: Self.arrival)
            let eve = SAClock.at(231, 22, SAClock.athens)
            await harness.advance(to: eve)
            await harness.pass(at: eve)
            try await harness.snapshot("V3b checkpoint: day 231, the evening before the holiday",
                                       closing: false)

        case .v4:
            try await harness.importPhotos(SATrace.importedHoliday())
            await harness.heal()
            try await harness.snapshot("V4 checkpoint: after the photo import, before any live fix",
                                       closing: false)
            await harness.advance(to: Self.arrival)
            await harness.pass(at: Self.arrival)
            try await harness.snapshot("V4 checkpoint: day 0 on landing, before the declaration",
                                       closing: false)
            try await harness.declareHome(label: "Brussels", place: flat, at: Self.arrival)
            try await harness.snapshot(
                "V4 checkpoint: day 0, after the declaration and its healing check", closing: false)

        case .v6:
            let renameTime = SAClock.at(44, 21, SAClock.brussels)
            await harness.advance(to: renameTime)
            try await harness.renameOpenTrip("Erasmus", at: renameTime)
            await harness.advance(to: Self.lateDeclaration)
            try await harness.declareHome(label: "Brussels", place: flat, at: Self.lateDeclaration)
            try harness.noteTripStays(since: renameTime)
            try await harness.snapshot("V6 checkpoint: day 45, right after the declaration",
                                       closing: false)

        case .v7, .v7b, .v7c:
            await harness.advance(to: Self.arrival)
            try await harness.declareHome(label: "Brussels", place: flat, at: Self.arrival)
            let name = self == .v7 ? "V7" : (self == .v7b ? "V7b" : "V7c")
            for (index, day) in SATrace.dayTripDays.enumerated() {
                if index == 2 {
                    // The third return. The last fix of the day is at 23:00
                    // local; this pass runs before that night's healing check.
                    await harness.advance(to: SAClock.at(day, 20.9, SAClock.utc))
                    await harness.pass(at: SAClock.at(day, 23.2, SAClock.brussels))
                    try await harness.snapshot(
                        "\(name) checkpoint: evening of visit 3 (day \(day)), before that night's healing check",
                        closing: false)
                }
                await harness.advance(to: SAClock.at(day + 1, 12.5, SAClock.utc))
                try await harness.snapshot(
                    "\(name) checkpoint: midday after visit \(index + 1) (day \(day + 1)), healing check done",
                    closing: false)
            }
        }
        await harness.finish()
        try await harness.snapshot(title)
    }
}

/// Runs each variant once per process. The first request starts all of them,
/// each on its own store, pipeline actors and gate, so the suite's wall time
/// is well under the sum of its variants.
@MainActor
private enum SARuns {
    private static var tasks: [SAVariant: Task<[SASnapshot], Error>] = [:]

    /// With `TEST_RUNNER_STUDY_ABROAD_SERIAL` set, a variant starts only when
    /// its own test asks for it: the way to run one test without the others.
    private static var startsAllAtOnce: Bool {
        let environment = ProcessInfo.processInfo.environment
        return (environment["STUDY_ABROAD_SERIAL"] ?? environment["TEST_RUNNER_STUDY_ABROAD_SERIAL"]
                ?? "").isEmpty
    }

    static func snapshots(for variant: SAVariant) async throws -> [SASnapshot] {
        let wanted = startsAllAtOnce ? SAVariant.allCases : [variant]
        for each in wanted where tasks[each] == nil {
            tasks[each] = Task { try await execute(each) }
        }
        guard let task = tasks[variant] else { throw SAError("no run for \(variant)") }
        return try await task.value
    }

    private static func execute(_ variant: SAVariant) async throws -> [SASnapshot] {
        let titleSuite = "StudyAbroadTitles-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: titleSuite) }
        // Foundation Models pinned off, title-failure bookkeeping in a
        // throwaway suite, no calendar access: the pipeline's own decisions only.
        return try await StayClassificationInference.TestHook.$availability.withValue(false) {
            try await TripClassifier.$failureDefaultsSuiteNameForTesting.withValue(titleSuite) {
                try await CalendarEnricher.TestScope.$authorizationStatus.withValue(.notDetermined) {
                    let harness = try await SAHarness.make(variant.options)
                    defer { harness.tearDown() }
                    try await variant.run(harness)
                    return harness.snapshots
                }
            }
        }
    }
}

// MARK: - Output

enum SAReport {
    /// Prints to the test log and appends to the report file when asked.
    static func emit(_ text: String) {
        print(text)
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TEST_RUNNER_STUDY_ABROAD_REPORT"]
                ?? environment["STUDY_ABROAD_REPORT"], !path.isEmpty,
              let data = (text + "\n").data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Tests

@MainActor
@Suite("Study abroad scenario (characterization)", .serialized, IsolatedLineageDefaults())
struct StudyAbroadScenarioTests {

    private typealias P = SAPlaces

    /// The variants replay nine months through the whole pipeline, about a
    /// minute of CPU each, so they run only on request. `premises` always runs.
    nonisolated static var requested: Bool {
        let environment = ProcessInfo.processInfo.environment
        return ["STUDY_ABROAD_REPORT", "TEST_RUNNER_STUDY_ABROAD_REPORT",
                "STUDY_ABROAD", "TEST_RUNNER_STUDY_ABROAD"]
            .contains { !(environment[$0] ?? "").isEmpty }
    }
    nonisolated static let optIn: Comment =
        "Set TEST_RUNNER_STUDY_ABROAD=1 (or TEST_RUNNER_STUDY_ABROAD_REPORT=<file>) to run the scenario variants"

    /// Print every table of the variant and hand back the closing one.
    private func report(_ variant: SAVariant) async throws -> (all: [SASnapshot], closing: SASnapshot) {
        let snapshots = try await SARuns.snapshots(for: variant)
        for snapshot in snapshots { SAReport.emit(snapshot.text) }
        return (snapshots, try #require(snapshots.last))
    }

    // MARK: Premises

    @Test("premises: real home seeds resolve, and the trace's places sit where the scenario assumes")
    func premises() async throws {
        let athens = await HomeShapeProvider.shared.shape(
            latitude: P.athHome.lat, longitude: P.athHome.lon)
        let brussels = await HomeShapeProvider.shared.shape(
            latitude: P.bruFlat.lat, longitude: P.bruFlat.lon)
        var lines = ["", "=== Premises: where each place sits ==="]
        lines.append("place".padding(toLength: 30, withPad: " ", startingAt: 0)
                     + "in Athens seed  km beyond  in Brussels seed  km beyond  airport")
        for place in P.probes {
            let coordinate = CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon)
            lines.append(place.name.padding(toLength: 30, withPad: " ", startingAt: 0) + String(
                format: "%@  %9.1f  %@  %9.1f  %@",
                (athens.contains(latitude: place.lat, longitude: place.lon) ? "yes" : "no")
                    .padding(toLength: 14, withPad: " ", startingAt: 0),
                athens.distanceKm(toLatitude: place.lat, longitude: place.lon),
                (brussels.contains(latitude: place.lat, longitude: place.lon) ? "yes" : "no")
                    .padding(toLength: 16, withPad: " ", startingAt: 0),
                brussels.distanceKm(toLatitude: place.lat, longitude: place.lon),
                AirportDetector.shared.isNearAirport(coordinate) ? "yes" : "no"))
        }
        SAReport.emit(lines.joined(separator: "\n"))

        for place in P.athensLife {
            #expect(athens.contains(latitude: place.lat, longitude: place.lon),
                    "\(place.name) must be ordinary Athens life")
        }
        for place in P.brusselsLife {
            #expect(brussels.contains(latitude: place.lat, longitude: place.lon),
                    "\(place.name) must be ordinary Brussels life")
        }
    }

    // MARK: Variants
    //
    // Spans are whole scenario days in UTC ("d0→d60"); day 0 is the flight out.
    // These expectations describe the observed classification output.

    /// Ieper (day 18), Bedburg (days 39 to 41), Amsterdam (days 100 to 105).
    private static let excursions = ["d18→d18", "d39→d41", "d100→d105"]
    private static let holiday = "d232→d236"

    @Test("V0 nothing declared: only the Athens Home",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func v0NothingDeclared() async throws {
        let run = try await report(.v0)
        // The weekend in Athens cuts the semester in two; the excursions sit inside.
        #expect(run.closing.spans == ["d0→d60", "d63→d150", Self.holiday])
        #expect(run.closing.travelDays == [2026: 0, 2027: 143, 2028: 11])
        #expect(run.closing.homeStaysByHome.keys.sorted() == ["Athens"])
    }

    @Test("V1 second Home at the Brussels flat, declared at arrival, never ended",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func v1SecondHomeAtArrival() async throws {
        let run = try await report(.v1)
        // The excursions are trips of their own; neither flight day nor the
        // later Brussels holiday is travel.
        #expect(run.closing.spans == Self.excursions)
        #expect(run.closing.travelDays == [2026: 0, 2027: 10, 2028: 0])
    }

    @Test("V2 late declaration on day 45, the way Settings adds a Home",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func v2LateDeclaration() async throws {
        let run = try await report(.v2)
        let before = try #require(run.all.first)
        let after = try #require(run.all.dropFirst().first)
        #expect(before.spans == ["d0→open"])
        // The Home backdates to the return from Bedburg, not to the arrival:
        // days 0 to 41 stay one completed trip with Ieper and Bedburg inside.
        #expect(after.spans == ["d0→d41"])
        #expect(after.homeStartDays["Brussels"].map { Int($0) } == 41)
        #expect(run.closing.spans == ["d0→d41", "d100→d105"])
        #expect(run.closing.trips.first?.summary == "Kortrijk, Ieper, Bedburg")
        #expect(before.trips.first?.summary == "Brussels, Ieper, Bedburg, Kortrijk")
        #expect(run.closing.travelDays == [2026: 0, 2027: 48, 2028: 0])
    }

    @Test("V3 as V1, Brussels Home ended at the final return, then the Brussels holiday",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func v3EndedAtFinalReturn() async throws {
        let run = try await report(.v3)
        #expect(run.closing.spans == Self.excursions + [Self.holiday])
        #expect(run.closing.travelDays == [2026: 0, 2027: 10, 2028: 5])
    }

    @Test("V3b as V1, the user forgets to end the Brussels Home, then the Brussels holiday",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func v3bNeverEnded() async throws {
        let run = try await report(.v3b)
        // The holiday is home time: no trip, no travel day.
        #expect(run.closing.spans == Self.excursions)
        #expect(run.closing.travelDays == [2026: 0, 2027: 10, 2028: 0])
    }

    @Test("V3c as V1, Brussels Home ended on the last morning at the flat, before leaving",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func v3cEndedBeforeLeaving() async throws {
        let run = try await report(.v3c)
        // The last morning at the flat and the flight home become a one-day trip.
        #expect(run.closing.spans == Self.excursions + ["d150→d150", Self.holiday])
        #expect(run.closing.travelDays == [2026: 0, 2027: 10, 2028: 6])
    }

    @Test("V4 prehistory: a photo-imported Brussels holiday from before every Home, then V1",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func v4ImportedPrehistory() async throws {
        let run = try await report(.v4)
        try #require(run.all.count == 4)
        let imported = run.all[0], landing = run.all[1], declared = run.all[2]
        #expect(imported.trips.count == 1)
        #expect(imported.travelDays[2026] == 4)
        #expect(landing.trips.count == 1)
        // Declaring the Brussels Home dissolves the 2026 holiday at the healing
        // check that follows the save; its stays become home stays.
        #expect(declared.trips.isEmpty)
        #expect(declared.dissolvedTrips == 1)
        #expect(declared.travelDays[2026] == 0)
        #expect(declared.homeStaysByHome["Brussels"] == 7)
        #expect(run.closing.spans == Self.excursions)
        #expect(run.closing.dissolvedTrips == 1)
    }

    @Test("V5a sparse Athens weekend (one live fix, no visit), nothing declared",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func v5aSparseWeekendNothingDeclared() async throws {
        let run = try await report(.v5a)
        // One fix at home does not bound a trip: the semester is one trip.
        #expect(run.closing.spans == ["d0→d150", Self.holiday])
        #expect(run.closing.travelDays == [2026: 0, 2027: 145, 2028: 11])
    }

    @Test("V5b sparse Athens weekend (one live fix, no visit), Brussels Home as V1",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func v5bSparseWeekendSecondHome() async throws {
        let run = try await report(.v5b)
        #expect(run.closing.spans == Self.excursions)
        #expect(run.closing.travelDays == [2026: 0, 2027: 10, 2028: 0])
    }

    @Test("V6 as V2, but the open big trip is renamed (userEdited) before the late declaration",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func v6UserEditedBigTrip() async throws {
        let run = try await report(.v6)
        let after = try #require(run.all.first)
        // The Home backdates as in V2, but no stay of the renamed trip is
        // reset: the trip stays open and no Brussels stay is a home stay yet.
        #expect(after.spans == ["d0→open"])
        #expect(after.homeStartDays["Brussels"].map { Int($0) } == 41)
        #expect(after.homeStaysByHome["Brussels"] == nil)
        let big = try #require(run.closing.trips.first)
        #expect(run.closing.spans == ["d0→d45", "d100→d105"])
        #expect(big.userEdited)
        #expect(big.customName == "Erasmus")
        #expect(run.closing.travelDays == [2026: 0, 2027: 52, 2028: 0])
    }

    @Test("V7 as V1 with four same-day returns from Dendermonde, 2 h each",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func v7DendermondeOrbit() async throws {
        let run = try await report(.v7)
        // Tables: after visit 1, after visit 2, evening of visit 3, after
        // visit 3, after visit 4, closing.
        try #require(run.all.count == 6)
        // Never a trip: visits 1 and 2 are near-home activity, and the third
        // return teaches a disc that turns all of them into home stays.
        #expect(run.all.allSatisfy { !$0.spans.contains { $0.hasPrefix("d25") || $0.hasPrefix("d53") } })
        #expect(run.all[0].suppressedGroups == 1)
        #expect(run.all[1].suppressedGroups == 2)
        #expect(run.all[1].learnedDiscs == 0)
        #expect(run.all[2].learnedDiscs == 1)
        #expect(run.all[2].triplessDestinations == 2)
        #expect(run.all[3].suppressedGroups == 0)
        #expect(run.all[3].triplessDestinations == 0)
        #expect(run.closing.spans == Self.excursions)
        #expect(run.closing.learnedDiscs == 1)
        #expect(run.closing.dissolvedTrips == 0)
    }

    @Test("V7b as V1 with four same-day returns from Wevelgem, 5 h each",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func v7bWevelgemOrbit() async throws {
        let run = try await report(.v7b)
        // Tables: after visit 1, after visit 2, evening of visit 3, after
        // visit 3, after visit 4, closing.
        try #require(run.all.count == 6)
        // Visits 1 and 2 are trips. The third return teaches a disc: visit 3
        // is never a trip, and that night's healing dissolves the visit-2 trip
        // (all of it inside the disc) but keeps the visit-1 trip (it holds a
        // stay on the way). Visit 4 is home time.
        #expect(run.all[0].spans == ["d18→d18", "d25→d25"])
        #expect(run.all[1].spans == ["d18→d18", "d25→d25", "d39→d41", "d53→d53"])
        #expect(run.all[2].spans == run.all[1].spans)
        #expect(run.all[2].learnedDiscs == 1)
        #expect(run.all[3].spans == ["d18→d18", "d25→d25", "d39→d41"])
        #expect(run.all[3].dissolvedTrips == 1)
        #expect(run.all[4].spans == ["d18→d18", "d25→d25", "d39→d41", "d100→d105"])
        #expect(run.closing.spans == ["d18→d18", "d25→d25", "d39→d41", "d100→d105"])
        #expect(run.closing.dissolvedTrips == 1)
        #expect(run.closing.travelDays == [2026: 0, 2027: 11, 2028: 0])
    }

    @Test("V7c as V7b, but every visit leaves one fix on the way out and one on the way back, each 36 min before the next fix",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func v7cSparseWaypoints() async throws {
        let run = try await report(.v7c)
        try #require(run.all.count == 6)
        // The two single-fix stays on the way get about 18 minutes each from
        // the clusterer's midpoint extension, which meets the orbit's 30-minute
        // dwell floor: the waypoint earns a disc of its own on the third
        // return, and healing then dissolves BOTH earlier Wevelgem trips.
        #expect(run.all[0].spans == ["d18→d18", "d25→d25"])
        #expect(run.all[1].spans == ["d18→d18", "d25→d25", "d39→d41", "d53→d53"])
        #expect(run.all[2].learnedDiscs == 2)
        #expect(run.all[3].spans == ["d18→d18", "d39→d41"])
        #expect(run.all[3].dissolvedTrips == 2)
        #expect(run.closing.spans == Self.excursions)
        #expect(run.closing.learnedDiscs == 2)
        #expect(run.closing.dissolvedTrips == 2)
        #expect(run.closing.travelDays == [2026: 0, 2027: 10, 2028: 0])
    }

    @Test("V8 as V1, no fix on the flight day and 48 h of silence after landing",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func v8SilentArrival() async throws {
        let run = try await report(.v8)
        #expect(run.closing.spans == Self.excursions)
        #expect(run.closing.travelDays == [2026: 0, 2027: 10, 2028: 0])
    }

    @Test("V8b nothing declared, no fix on the flight day and 48 h of silence after landing",
          .enabled(if: StudyAbroadScenarioTests.requested, StudyAbroadScenarioTests.optIn))
    func v8bSilentArrivalNothingDeclared() async throws {
        let run = try await report(.v8b)
        // The trip starts with the first Brussels fix, two days after landing.
        #expect(run.closing.spans == ["d2→d60", "d63→d150", Self.holiday])
        #expect(run.closing.travelDays == [2026: 0, 2027: 141, 2028: 11])
    }
}
