import Testing
import Foundation
import CoreGraphics
import SwiftData
@testable import TravelLog

/// The Trips list's flag rows and year headers: honest year totals, the
/// flag deck's geometry and the wash's colour rule.
@MainActor
struct TripsListYearTotalsTests {
    private func utc(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return formatter.date(from: string)!
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test("Year totals count trips by start year and overlapping days once")
    func yearTotals() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        let spans = [
            ("2026-09-02T10:00:00", "2026-09-14T10:00:00"), // 13 days
            ("2026-09-10T10:00:00", "2026-09-16T10:00:00"), // overlaps 10 to 14: adds 15, 16
            ("2026-01-15T10:00:00", "2026-01-19T10:00:00"), // 5 days
            ("2025-12-30T10:00:00", "2026-01-02T10:00:00"), // 2025, all 4 days
        ]
        let trips = spans.map { start, end -> Trip in
            let trip = Trip(startDate: utc(start))
            trip.endDate = utc(end)
            trip.isComplete = true
            context.insert(trip)
            return trip
        }
        let totals = TripsListView.computeYearTotals(
            trips, dayLabels: [:], calendar: utcCalendar, now: utc("2026-10-17T10:00:00"))
        #expect(totals[2026] == .init(trips: 3, days: 20))
        #expect(totals[2025] == .init(trips: 1, days: 4))
        #expect(TripsListView.computeYearTotals([], dayLabels: [:]).isEmpty)
    }

    @Test("Cached day labels win over the fallback")
    func yearTotalsUseCache() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        let trip = Trip(startDate: utc("2026-05-01T10:00:00"))
        trip.endDate = utc("2026-05-03T10:00:00")
        trip.isComplete = true
        context.insert(trip)
        let labels = [utc("2026-05-01T00:00:00"), utc("2026-05-02T00:00:00")]
        let totals = TripsListView.computeYearTotals(
            [trip], dayLabels: [trip.persistentModelID: labels], calendar: utcCalendar)
        #expect(totals[2026] == .init(trips: 1, days: 2))
    }

    @Test("The worker reads each completed trip's days in its boundary stays' zones")
    func workerDayLabels() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = container.mainContext
        // 23:00 UTC on 1 May is 08:00 on 2 May in Tokyo: three Tokyo days, 2 to 4 May.
        let trip = Trip(startDate: utc("2026-05-01T23:00:00"))
        trip.endDate = utc("2026-05-03T23:00:00")
        trip.isComplete = true
        context.insert(trip)
        let stay = Stay(startTime: utc("2026-05-01T23:00:00"), endTime: utc("2026-05-03T23:00:00"),
                        centroidLatitude: 35.68, centroidLongitude: 139.69, h3IndexRes6: "", pingCount: 1,
                        distanceFromHomeKm: 9000, pingIDs: [], timeZoneIdentifier: "Asia/Tokyo")
        context.insert(stay)
        stay.trip = trip
        let open = Trip(startDate: utc("2026-05-10T10:00:00"))
        context.insert(open)
        try context.save()
        let labels = try TripsListView.loadTripDayLabels(
            container: container, now: utc("2026-10-17T10:00:00"),
            fallbackZone: TimeZone(identifier: "UTC")!, checkCancellation: {})
        #expect(labels.count == 1)
        let days = try #require(labels[trip.persistentModelID]).sorted()
        #expect(days == [utc("2026-05-02T00:00:00"), utc("2026-05-03T00:00:00"), utc("2026-05-04T00:00:00")])
    }

    @Test("The deck fans one to three flags at the design's offsets")
    func deckOffsets() {
        #expect(FlagDeck.offsets(count: 1) == [.zero])
        #expect(FlagDeck.offsets(count: 2) == [.zero, CGPoint(x: 9, y: 8)])
        #expect(FlagDeck.offsets(count: 3) == [.zero, CGPoint(x: 6, y: 6), CGPoint(x: 12, y: 12)])
    }

    @Test("The wash takes one country's three bands, or several countries' lead colours")
    func washBands() throws {
        // One country: its own bands, top to bottom, at the wash's strength.
        let no = try #require(FlagColors.wash["NO"])
        let norway = FlagWash.bands(for: ["no"])
        #expect(norway.count == 3)
        #expect(norway[0] == WashTone(hex: try #require(no.top), alpha: FlagWash.alpha(try #require(no.top), base: FlagWash.strength)))
        #expect(norway[1] == WashTone(hex: try #require(no.middle), alpha: FlagWash.alpha(try #require(no.middle), base: FlagWash.strength)))
        // Two countries: the first's lead above, the second's below, meeting between.
        let gb = try #require(FlagColors.wash["GB"]), fr = try #require(FlagColors.wash["FR"])
        let pair = FlagWash.bands(for: ["GB", "FR"])
        #expect(pair[0] == WashTone(hex: gb.lead, alpha: FlagWash.alpha(gb.lead, base: FlagWash.strength)))
        #expect(pair[2] == WashTone(hex: fr.lead, alpha: FlagWash.alpha(fr.lead, base: FlagWash.strength)))
        #expect(pair[1] == pair[0].blended(with: pair[2]))
        // A band the flag leaves clear keeps its neighbour's colour at no strength.
        let de = try #require(FlagColors.wash["DE"])
        #expect(de.top == nil)
        let germany = FlagWash.bands(for: ["DE"])
        #expect(germany[0].alpha == 0 && germany[0].red == germany[1].red && germany[0].blue == germany[1].blue)
        #expect(FlagWash.bands(for: []) == [.clear, .clear, .clear])
        #expect(FlagWash.bands(for: ["ZZ"]) == [.clear, .clear, .clear])
        // Navy is lifted, capped; a bright colour keeps its base.
        #expect(abs(FlagWash.alpha(0x000091, base: 0.16) - 0.22) < 1e-9)
        #expect(FlagWash.alpha(0x000091, base: 0.30) == FlagWash.maxStrength)
        #expect(FlagWash.alpha(0xFFCC00, base: FlagWash.strength) == FlagWash.strength)
    }

    @Test("Every flag in the table has a vivid band and only real colours")
    func washTable() {
        #expect(FlagColors.wash.count > 200)
        for (code, entry) in FlagColors.wash {
            #expect(code.count == 2 && code == code.uppercased())
            let bands = [entry.top, entry.middle, entry.bottom]
            #expect(bands.contains { $0 != nil }, "\(code) has no colour")
            #expect(([entry.lead] + bands.compactMap { $0 }).allSatisfy { $0 <= 0xFFFFFF })
        }
    }

    @Test("Neighbouring rows' washes meet in one blended colour")
    func washesFlow() throws {
        let washes = RowWash.section([["TR"], ["GR"], [], ["PT", "ES"]])
        #expect(washes.count == 4)
        for index in 0..<(washes.count - 1) {
            #expect(washes[index].bottom == washes[index + 1].top)
        }
        // A card's first and last rows keep their own colour at its edges.
        #expect(washes[0].top == washes[0].upper)
        #expect(washes[3].bottom == washes[3].lower)
        // Turkey's red and Greece's blue meet half way, at their mean strength.
        let tr = try #require(FlagColors.wash["TR"]?.bottom), gr = try #require(FlagColors.wash["GR"]?.top)
        let meet = washes[0].bottom
        #expect(abs(meet.alpha - (FlagWash.alpha(tr, base: FlagWash.strength)
            + FlagWash.alpha(gr, base: FlagWash.strength)) / 2) < 1e-9)
        #expect(meet.red > 0 && meet.blue > 0)
        // The meeting colour stays saturated (a violet), not a grey average.
        let saturation = (max(meet.red, meet.green, meet.blue) - min(meet.red, meet.green, meet.blue))
            / max(meet.red, meet.green, meet.blue)
        #expect(saturation > 0.8)
        // A row without colours fades its neighbours to half strength, never grey.
        #expect(washes[2].upper == .clear && washes[2].middle == .clear)
        #expect(abs(washes[2].top.alpha - washes[1].lower.alpha / 2) < 1e-9)
        #expect(washes[2].top.blue == washes[1].lower.blue)
        // Two-country rows read both colours, top and bottom.
        #expect(washes[3].upper != washes[3].lower)
    }

    @Test("Beyond four countries the names line counts the rest")
    func countryLine() {
        #expect(TripRowText.countryLine([]) == nil)
        let six = TripRowText.countryLine(["SI", "HR", "BA", "ME", "AL", "MK"]) ?? ""
        #expect(six.hasSuffix("4 more"))
        let four = TripRowText.countryLine(["AT", "CZ", "SK", "HU"]) ?? ""
        #expect(!four.contains("more"))
    }
}
