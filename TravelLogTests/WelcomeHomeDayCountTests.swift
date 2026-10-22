//
//  WelcomeHomeDayCountTests.swift
//  TravelLogTests
//
//  The Welcome Home body counts inclusive calendar days like
//  `Trip.durationDays`, and stays silent until a full day away.
//

import Testing
import Foundation
@testable import TravelLog

struct WelcomeHomeDayCountTests {

    private let zone = TimeZone(identifier: "Europe/Athens")!

    private func date(_ month: Int, _ day: Int, _ hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @Test("Mon 09:00 to Wed 08:00 counts 3 days")
    func earlierReturnTimeCountsCalendarDays() {
        #expect(NotificationService.welcomeHomeDisplayDays(
            departure: date(3, 2, 9), now: date(3, 4, 8), zone: zone) == 3)
    }

    @Test("Fri 18:00 to Sun 17:00 counts 3 days")
    func weekendTripCountsCalendarDays() {
        #expect(NotificationService.welcomeHomeDisplayDays(
            departure: date(3, 6, 18), now: date(3, 8, 17), zone: zone) == 3)
    }

    @Test("Mon 09:00 to Tue 10:00 counts 2 days")
    func overnightTripCountsTwoDays() {
        #expect(NotificationService.welcomeHomeDisplayDays(
            departure: date(3, 2, 9), now: date(3, 3, 10), zone: zone) == 2)
    }

    @Test("under a full day away stays silent")
    func underOneDayIsNil() {
        #expect(NotificationService.welcomeHomeDisplayDays(
            departure: date(3, 2, 9), now: date(3, 3, 8), zone: zone) == nil)
    }

    @Test("a span across the spring DST change keeps calendar days")
    func dstChangeKeepsCalendarDays() {
        #expect(NotificationService.welcomeHomeDisplayDays(
            departure: date(3, 28, 12), now: date(3, 30, 11), zone: zone) == 3)
    }
}
