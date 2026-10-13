//
//  PlannedTripDetectorTests.swift
//  TravelLogTests
//
//  Phase 1 of the calendar integration: pure-function detection scoring and
//  planned-trip ↔ real-trip matching, over synthetic snapshots — no
//  EKEventStore anywhere.
//

import Foundation
import Testing
@testable import TravelLog

@MainActor
struct PlannedTripDetectorTests {

    // MARK: - Helpers

    private func snapshot(
        title: String,
        notes: String? = nil,
        location: String? = nil,
        start: Date = Date(timeIntervalSince1970: 1_830_240_000),
        durationHours: Double = 2,
        isAllDay: Bool = false,
        recurring: Bool = false,
        detached: Bool = false,
        kind: CalendarKind = .icloud,
        localIdentifier: String = "local-1",
        externalIdentifier: String? = "ext-1"
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(
            externalIdentifier: externalIdentifier,
            localIdentifier: localIdentifier,
            title: title,
            notes: notes,
            locationText: location,
            startDate: start,
            endDate: start.addingTimeInterval(durationHours * 3600),
            isAllDay: isAllDay,
            hasRecurrenceRules: recurring,
            isDetached: detached,
            calendarTitle: "Test",
            calendarKind: kind
        )
    }

    // MARK: - Detection

    @Test func flightCodeWithContextIsHighConfidence() throws {
        let result = PlannedTripDetector.evaluate(
            snapshot(title: "Flight BA742 to London", durationHours: 3)
        )
        let detection = try #require(result)
        // flightCode (4) + keyword "flight" (3) → 7 → high. (The
        // bookingTitle prefix "flight to " does NOT match this title.)
        #expect(detection.confidence == .high)
        #expect(detection.signals.contains(PlannedTripDetector.signalFlightCode))
    }

    @Test func alphanumericAirlineCodesDetect() {
        for title in ["U2 1234 departure", "Boarding B6915", "9W 456 to Mumbai flight"] {
            let detection = PlannedTripDetector.evaluate(snapshot(title: title))
            #expect(detection != nil, Comment(rawValue: "expected detection for \(title)"))
            #expect(detection?.signals.contains(PlannedTripDetector.signalFlightCode) == true, Comment(rawValue: title))
        }
    }

    @Test func flightCodeWithoutContextWordIsIgnored() {
        let detection = PlannedTripDetector.evaluate(snapshot(title: "AA123 budget review"))
        #expect(detection == nil)
    }

    @Test func flightCodeMatchReportsFieldDesignatorContextAndSpans() throws {
        let event = snapshot(title: "Boarding BA742 to London")
        let match = try #require(PlannedTripDetector.flightCodeMatch(in: event))

        #expect(match.field == .title)
        #expect(match.flightNumber == "BA742")
        #expect(match.airlineDesignator == "BA")
        #expect(match.contextToken == "boarding")

        let title = event.title as NSString
        let code = title.substring(with: NSRange(
            location: match.codeUTF16Range.lowerBound,
            length: match.codeUTF16Range.count
        ))
        let context = title.substring(with: NSRange(
            location: match.contextUTF16Range.lowerBound,
            length: match.contextUTF16Range.count
        ))
        #expect(code == "BA742")
        #expect(context == "Boarding")
    }

    @Test func flightCodeAndContextCannotCrossCalendarFields() throws {
        let event = snapshot(
            title: "AA123 budget review",
            notes: "Discuss the flight and airport pickup next month",
            location: "Gate conference room"
        )

        #expect(PlannedTripDetector.flightCodeMatch(in: event) == nil)
        #expect(!PlannedTripDetector.isFlightEvent(event))
        let raw = try #require(PlannedTripDetector.rawScore(event))
        #expect(!raw.signals.contains(PlannedTripDetector.signalFlightCode))
    }

    @Test func flightCodeCanUseContextWithinTheSameNonTitleField() throws {
        let event = snapshot(
            title: "London travel",
            notes: "Boarding BA742 at 08:20",
            location: "Heathrow"
        )
        let match = try #require(PlannedTripDetector.flightCodeMatch(in: event))
        #expect(match.field == .notes)
        #expect(match.flightNumber == "BA742")
        #expect(PlannedTripDetector.isFlightEvent(event))
    }

    @Test func distantContextAndReferenceNumbersAreRejected() {
        let distant = snapshot(
            title: "AA123 quarterly budget review meeting agenda notes before upcoming flight"
        )
        #expect(PlannedTripDetector.flightCodeMatch(in: distant) == nil)

        for title in [
            "Package arrival order AA123 status",
            "Arrival reference AA123",
            "Project departure ref B6915",
        ] {
            let event = snapshot(title: title)
            #expect(PlannedTripDetector.flightCodeMatch(in: event) == nil, Comment(rawValue: title))
            #expect(!PlannedTripDetector.isFlightEvent(event), Comment(rawValue: title))
        }
    }

    @Test func strongAviationContextOutweighsNearbyReferenceVocabulary() throws {
        let event = snapshot(title: "Flight arrival reference BA742")
        let match = try #require(PlannedTripDetector.flightCodeMatch(in: event))
        #expect(match.flightNumber == "BA742")
        #expect(match.contextToken == "flight")
    }

    @Test func explicitFlightTitleAllowsDistantSameFieldContext() throws {
        let event = snapshot(
            title: "Flight to London — itinerary details and seat assignment BA742"
        )
        let match = try #require(PlannedTripDetector.flightCodeMatch(in: event))
        #expect(match.field == .title)
        #expect(match.flightNumber == "BA742")
        #expect(match.contextToken == "flight")
    }

    @Test func autoGeneratedBookingTitlesDetect() {
        for title in ["Flight to Rome", "Hotel: Marriott Downtown", "Trip to Tokyo", "Reservation at Noma"] {
            let detection = PlannedTripDetector.evaluate(snapshot(title: title))
            #expect(detection != nil, Comment(rawValue: title))
            #expect(detection?.signals.contains(PlannedTripDetector.signalBookingTitle) == true, Comment(rawValue: title))
        }
    }

    @Test func multiDayVacationKeywordIsMediumConfidence() {
        let detection = PlannedTripDetector.evaluate(
            snapshot(title: "Family vacation", durationHours: 5 * 24, isAllDay: true)
        )
        // keyword (3) + multiDay (1) = 4 → medium.
        #expect(detection?.confidence == .medium)
    }

    @Test func keywordInNotesCountsButShortEventStaysLow() {
        let detection = PlannedTripDetector.evaluate(
            snapshot(title: "Sync with Anna", notes: "bring the itinerary printout")
        )
        // keyword (3) only → low (persisted, hidden in UI).
        #expect(detection?.confidence == .low)
        #expect(detection?.signals.contains(PlannedTripDetector.signalBookingKeyword) == true)
    }

    @Test func plainShortMeetingIsNotDetected() {
        #expect(PlannedTripDetector.evaluate(snapshot(title: "Dentist")) == nil)
        #expect(PlannedTripDetector.evaluate(snapshot(title: "Team standup")) == nil)
    }

    @Test func birthdayCalendarIsHardExcluded() {
        let detection = PlannedTripDetector.evaluate(
            snapshot(title: "Flight to Rome", kind: .birthday)
        )
        #expect(detection == nil)
    }

    @Test func subscribedCalendarIsPenalizedButNotExcluded() {
        // A subscribed holiday calendar's multi-day "holiday" entry: keyword
        // (3) + multiDay (1) - subscribed (3) = 1 → below the low cutoff.
        let holiday = PlannedTripDetector.evaluate(
            snapshot(title: "National Holiday", durationHours: 24 * 2, isAllDay: true, kind: .subscribed)
        )
        #expect(holiday == nil)

        // But strong text signals still push a subscribed entry over the bar:
        // flightCode (4) + keyword (3) - subscribed (3) = 4 → medium.
        let sharedPlanning = PlannedTripDetector.evaluate(
            snapshot(title: "Flight LH2471 boarding", kind: .subscribed)
        )
        #expect(sharedPlanning?.confidence == .medium)
    }

    @Test func recurringRoutineIsPenalizedOut() throws {
        // Weekly multi-day recurring block with zero travel vocabulary —
        // RoutinePlace territory, not a trip: multiDay (1) - recurring (3).
        let event = snapshot(title: "Client site", durationHours: 26, recurring: true)
        #expect(PlannedTripDetector.evaluate(event) == nil)
        // multiDay alone already misses the cutoff, so pin the penalty itself.
        let raw = try #require(PlannedTripDetector.rawScore(event))
        #expect(raw.signals.contains(PlannedTripDetector.signalRecurringPenalty))
        #expect(raw.score == -2)
    }

    @Test func googleHolidayCalendarEntryIsRejected() {
        // Google auto-shows national
        // holidays via a CalDAV calendar named "Holidays in Greece" — NOT
        // `.subscription`, so the subscribed penalty can't catch it — and
        // stamps "Public holiday" into the notes, which hits the `holiday`
        // booking keyword; all-day adds the multi-day weight.
        let holidayCalendarSnapshot = CalendarEventSnapshot(
            externalIdentifier: "ext-h",
            localIdentifier: "local-h",
            title: "The Restoration of Democracy",
            notes: "Public holiday",
            locationText: nil,
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_000_000 + 86_400),
            isAllDay: true,
            hasRecurrenceRules: false,
            isDetached: false,
            calendarTitle: "Holidays in Greece",
            calendarKind: .caldav
        )
        #expect(PlannedTripDetector.evaluate(holidayCalendarSnapshot) == nil)
    }

    @Test func realHolidayBookingOnNormalCalendarStillDetects() {
        // "holiday" as a booking keyword must keep working for the user's
        // own events — the penalties key on the CALENDAR title and on
        // public-holiday phrases, not on the word itself.
        let detection = PlannedTripDetector.evaluate(
            snapshot(title: "Summer holiday in Crete", durationHours: 7 * 24, isAllDay: true)
        )
        #expect(detection?.confidence == .medium)
    }

    @Test func modeTitledTransportBookingsDetect() {
        // Mode-prefixed ferry bookings have no booking keyword in sight
        // ("KASSANDRA LINES"); the mode-prefixed title is the signal.
        for title in [
            "Boat: KASSANDRA LINES from Cephalonia to Lefkada",
            "Boat: APOKORONAS LINES from Agios Dimitrios to Cephalonia",
            "Train: Eurostar from Paris to London",
        ] {
            let detection = PlannedTripDetector.evaluate(snapshot(title: title))
            #expect(detection != nil, Comment(rawValue: title))
            #expect(detection?.signals.contains(PlannedTripDetector.signalTransitTitle) == true, Comment(rawValue: title))
        }
    }

    /// The false-positive class the keyword waiver used to create: an ordinary recurring work event whose
    /// title merely CONTAINS booking vocabulary. It scored 3, had its -3
    /// recurrence penalty waived by that weakest signal, cleared the low
    /// cutoff of 2, and minted a `.low` PlannedTrip row for EVERY instance.
    /// Duration separates it from a genuine annual holiday.
    @Test func shortRecurringKeywordEventDoesNotSurvive() {
        let detection = PlannedTripDetector.evaluate(
            snapshot(title: "Daily check-in", durationHours: 1, recurring: true)
        )
        #expect(detection == nil)
    }

    @Test func recurringWithTravelKeywordSurvives() {
        // Annual "ski trip" recurrence: keyword fires → penalty waived.
        let detection = PlannedTripDetector.evaluate(
            snapshot(title: "Annual ski holiday", durationHours: 7 * 24, recurring: true)
        )
        #expect(detection != nil)
        #expect(detection?.signals.contains(PlannedTripDetector.signalRecurringPenalty) == false)
    }

    // NOTE: the recurrence penalty became operative with the
    // distance-from-home signal; see `recurringFarRoutineIsSuppressedByThePenalty`
    // below for the case it exists for. Without a distance, the tests above still hold: an event
    // with no text signal can't reach the cutoff on multiDay alone.

    @Test func ambiguousBandIsOnePointBelowCutoff() throws {
        // A multi-day event with no other signal scores exactly 1 — the
        // band the Phase-5 FM tie-breaker arbitrates.
        let raw = try #require(PlannedTripDetector.rawScore(snapshot(title: "Grandma", durationHours: 30)))
        #expect(raw.score == 1)
        #expect(PlannedTripDetector.isAmbiguous(score: raw.score))
        #expect(!PlannedTripDetector.isAmbiguous(score: 2))
        #expect(!PlannedTripDetector.isAmbiguous(score: 0))
        // Hard exclusions yield no raw score at all — never FM-judged.
        #expect(PlannedTripDetector.rawScore(snapshot(title: "Trip to Rome", kind: .birthday)) == nil)
    }

    // MARK: - Identity

    @Test func identityPrefersExternalIdentifierAndIncludesStartDate() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let a = snapshot(title: "X", start: start)
        let sameEventLaterInstance = snapshot(title: "X", start: start.addingTimeInterval(7 * 24 * 3600))
        // Recurrence instances share identifiers but differ in startDate →
        // distinct keys (§2.5).
        #expect(PlannedTripDetector.identityKey(for: a) != PlannedTripDetector.identityKey(for: sameEventLaterInstance))

        // Fallback to the local identifier when the external one is nil.
        let noExternal = snapshot(title: "X", start: start, localIdentifier: "L9", externalIdentifier: nil)
        #expect(PlannedTripDetector.identityKey(for: noExternal).hasPrefix("L9|"))
    }

    /// Midnight of a calendar day as EventKit would render a floating
    /// all-day event under the given device timezone.
    private func midnight(_ y: Int, _ m: Int, _ d: Int, tz: String) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: tz)!
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    @Test func allDayIdentitySurvivesTimezoneChanges() {
        // The SAME floating all-day event (May 25 2027) rendered under four
        // device timezones spanning UTC−10…+9 must mint ONE key — an
        // instant-based key changed with every timezone the user landed in,
        // duplicating the row mid-trip.
        // Each device renders the floating midnight in ITS OWN zone and reads
        // it back with that same zone — so the key must be passed the matching
        // timezone, which is what `TimeZone.current` supplies in production.
        // The fringe offsets +13/+14 and
        // −12 are included: the old noon-bias ordinal was off by one there, so
        // two synced devices minted different keys for one event.
        let zones = [
            "Europe/Athens", "America/New_York", "Asia/Tokyo", "Pacific/Honolulu",
            "Pacific/Apia",      // +13
            "Pacific/Kiritimati", // +14
            "Etc/GMT+12",        // −12
        ]
        let keys = zones.map { zone in
            PlannedTripDetector.identityKey(
                for: snapshot(
                    title: "Trip to Cephalonia",
                    start: midnight(2027, 5, 25, tz: zone),
                    isAllDay: true
                ),
                timeZone: TimeZone(identifier: zone)!
            )
        }
        #expect(Set(keys).count == 1)
    }

    @Test func allDayRecurrenceInstancesKeepDistinctKeys() {
        // Day-granular keys must not collapse adjacent instances of a DAILY
        // recurring all-day event — §2.5 (startDate participates) still holds
        // at the new granularity, and timed events keep the instant key.
        let d1 = snapshot(title: "X", start: midnight(2027, 5, 25, tz: "Europe/Athens"), isAllDay: true)
        let d2 = snapshot(title: "X", start: midnight(2027, 5, 26, tz: "Europe/Athens"), isAllDay: true)
        #expect(PlannedTripDetector.identityKey(for: d1) != PlannedTripDetector.identityKey(for: d2))
    }

    // MARK: - Matching

    private func candidate(_ uuid: String, start: Date, end: Date?) -> PlannedTripMatcher.TripCandidate {
        PlannedTripMatcher.TripCandidate(id: UUID(uuidString: uuid)!, startDate: start, endDate: end)
    }

    @Test func exactOverlapMatches() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(5 * 24 * 3600)
        let trip = candidate("11111111-1111-1111-1111-111111111111", start: start, end: end)
        let match = PlannedTripMatcher.bestMatch(
            plannedStart: start, plannedEnd: end, candidates: [trip], now: end.addingTimeInterval(86400)
        )
        #expect(match == trip.id)
    }

    @Test func insufficientOverlapDoesNotMatch() {
        let plannedStart = Date(timeIntervalSince1970: 1_700_000_000)
        let plannedEnd = plannedStart.addingTimeInterval(5 * 24 * 3600)
        // Trip ended weeks before the planned window (outside even the 1-day slack).
        let unrelated = candidate(
            "22222222-2222-2222-2222-222222222222",
            start: plannedStart.addingTimeInterval(-30 * 24 * 3600),
            end: plannedStart.addingTimeInterval(-20 * 24 * 3600)
        )
        let match = PlannedTripMatcher.bestMatch(
            plannedStart: plannedStart, plannedEnd: plannedEnd,
            candidates: [unrelated], now: plannedEnd.addingTimeInterval(86400)
        )
        #expect(match == nil)
    }

    @Test func ongoingTripMatchesViaNowAsOpenEnd() {
        let plannedStart = Date(timeIntervalSince1970: 1_700_000_000)
        let plannedEnd = plannedStart.addingTimeInterval(4 * 24 * 3600)
        let ongoing = candidate("33333333-3333-3333-3333-333333333333", start: plannedStart, end: nil)
        let match = PlannedTripMatcher.bestMatch(
            plannedStart: plannedStart, plannedEnd: plannedEnd,
            candidates: [ongoing], now: plannedStart.addingTimeInterval(2 * 24 * 3600)
        )
        #expect(match == ongoing.id)
    }

    @Test func tiebreakIsDeterministicOnUUIDString() {
        // Two identical candidates except id — the lexicographically smaller
        // uuidString must win on every device.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3 * 24 * 3600)
        let a = candidate("AAAAAAAA-0000-0000-0000-000000000000", start: start, end: end)
        let b = candidate("BBBBBBBB-0000-0000-0000-000000000000", start: start, end: end)
        let now = end.addingTimeInterval(86400)
        let forward = PlannedTripMatcher.bestMatch(plannedStart: start, plannedEnd: end, candidates: [a, b], now: now)
        let reversed = PlannedTripMatcher.bestMatch(plannedStart: start, plannedEnd: end, candidates: [b, a], now: now)
        #expect(forward == a.id)
        #expect(reversed == a.id)
    }

    @Test func closerStartDateWinsAtEqualOverlap() {
        // Back-to-back trips both fully covering the planned window's slack
        // edges is impossible; construct equal overlaps via containment:
        // planned 2d window inside both a 10d and a 10d trip, one starting
        // closer to the planned start.
        let plannedStart = Date(timeIntervalSince1970: 1_700_000_000)
        let plannedEnd = plannedStart.addingTimeInterval(2 * 24 * 3600)
        let near = candidate(
            "44444444-0000-0000-0000-000000000000",
            start: plannedStart.addingTimeInterval(-2 * 24 * 3600),
            end: plannedEnd.addingTimeInterval(6 * 24 * 3600)
        )
        let far = candidate(
            "55555555-0000-0000-0000-000000000000",
            start: plannedStart.addingTimeInterval(-6 * 24 * 3600),
            end: plannedEnd.addingTimeInterval(2 * 24 * 3600)
        )
        let match = PlannedTripMatcher.bestMatch(
            plannedStart: plannedStart, plannedEnd: plannedEnd,
            candidates: [far, near], now: plannedEnd.addingTimeInterval(10 * 24 * 3600)
        )
        #expect(match == near.id)
    }

    // MARK: - Task-shaped reminders

    @Test func taskShapedAllDayReminderNeverDetectsNorReachesTieBreaker() throws {
        // A one-off all-day reminder scores multiDay(+1) alone = 1 — exactly
        // the FM tie-breaker band. Task-verb titles must drop out of BOTH
        // detection and the band.
        for title in ["Cancel Perplexity", "Renew passport", "Pay rent", "Return library books"] {
            let snap = snapshot(title: title, durationHours: 24, isAllDay: true)
            #expect(PlannedTripDetector.evaluate(snap) == nil, Comment(rawValue: title))
            let raw = try #require(PlannedTripDetector.rawScore(snap))
            #expect(raw.signals.contains(PlannedTripDetector.signalTaskTitlePenalty), Comment(rawValue: title))
            #expect(!PlannedTripDetector.qualifiesForTieBreaker(score: raw.score, title: title), Comment(rawValue: title))
        }
    }

    @Test func taskShapedTitleWithBookingKeywordStaysOutOfTieBreakerBand() throws {
        // keyword(+3) + multiDay(+1) + taskTitle(−3) = 1 — lands IN the
        // ambiguous band by score, but the title gate keeps the FM out of it.
        let snap = snapshot(title: "Cancel hotel reservation", durationHours: 24, isAllDay: true)
        #expect(PlannedTripDetector.evaluate(snap) == nil)
        let raw = try #require(PlannedTripDetector.rawScore(snap))
        #expect(PlannedTripDetector.isAmbiguous(score: raw.score))
        #expect(!PlannedTripDetector.qualifiesForTieBreaker(score: raw.score, title: snap.title))
    }

    @Test func strongSignalsWaiveTheTaskPenaltyEntirely() throws {
        // A strong signal (flight code /
        // booking / transit title) waives the task penalty — an explicit
        // travel document must not be sunk by its own admin vocabulary.
        // flightCode(4) + keyword(3) + multiDay(1), no penalty → high.
        let detection = try #require(PlannedTripDetector.evaluate(
            snapshot(title: "Cancel flight AB123 to Athens", durationHours: 24, isAllDay: true)
        ))
        #expect(detection.confidence == .high)
        #expect(!detection.signals.contains(PlannedTripDetector.signalTaskTitlePenalty))
        // Keyword-only admin keeps the penalty (no strong signal fired).
        let keywordOnly = snapshot(title: "Hotel payment due", durationHours: 24, isAllDay: true)
        let raw = try #require(PlannedTripDetector.rawScore(keywordOnly))
        #expect(raw.signals.contains(PlannedTripDetector.signalTaskTitlePenalty))
        #expect(PlannedTripDetector.evaluate(keywordOnly) == nil)
    }

    @Test func barePlaceNameTitleStillQualifiesForTieBreaker() throws {
        // A bare place-name all-day block must survive the new gate.
        let snap = snapshot(title: "Cephalonia", durationHours: 48, isAllDay: true)
        #expect(PlannedTripDetector.evaluate(snap) == nil)
        let raw = try #require(PlannedTripDetector.rawScore(snap))
        #expect(PlannedTripDetector.qualifiesForTieBreaker(score: raw.score, title: snap.title))
    }

    @Test func taskVerbMatchesFirstWordOnlyAndExactly() {
        // Prefix collisions must not fire: "Booking.com" ≠ "book",
        // "Checkout" has no task verb, mid-title verbs don't count
        // (except the deliberate task-NOUN markers, tested below).
        #expect(PlannedTripDetector.isTaskShapedTitle("Cancel Perplexity"))
        #expect(PlannedTripDetector.isTaskShapedTitle("  cancel subscription"))
        #expect(!PlannedTripDetector.isTaskShapedTitle("Booking.com: Cephalonia Resort"))
        #expect(!PlannedTripDetector.isTaskShapedTitle("Checkout at noon"))
        #expect(!PlannedTripDetector.isTaskShapedTitle("Check in — Hilton"))
        #expect(!PlannedTripDetector.isTaskShapedTitle("Trip to cancel culture museum"))
        #expect(!PlannedTripDetector.isTaskShapedTitle(""))
    }

    @Test func returnTravelNounPhrasesAreNotTasks() throws {
        // "Return flight to London" is a NOUN
        // PHRASE naming a travel leg — the bare verb rule silently zeroed
        // such code-less titles from +3 (low detection) to 0 (invisible).
        for title in ["Return flight to London", "Return ferry to Agios Dimitrios", "Return trip home"] {
            #expect(!PlannedTripDetector.isTaskShapedTitle(title), Comment(rawValue: title))
        }
        // The keyword-scored travel title detects again (score 3 → .low).
        let detection = try #require(PlannedTripDetector.evaluate(
            snapshot(title: "Return flight to London", durationHours: 3)
        ))
        #expect(detection.confidence == .low)
        // The chore reading keeps its penalty.
        #expect(PlannedTripDetector.isTaskShapedTitle("Return library books"))
        // "Return to <place>" is a destination phrase, not a chore.
        #expect(!PlannedTripDetector.isTaskShapedTitle("Return to Athens"))
        #expect(!PlannedTripDetector.isTaskShapedTitle("Return to the island"))
    }

    @Test func nounFirstRemindersAreTaskShapedAndStayOutOfTheBand() throws {
        // Noun-first reminders reach the FM band
        // through the identical all-day +1 path the verb-first incident used.
        for title in ["Taxes due", "Passport renewal", "Dentist appointment", "Rent due", "Car insurance renewal"] {
            let snap = snapshot(title: title, durationHours: 24, isAllDay: true)
            #expect(PlannedTripDetector.isTaskShapedTitle(title), Comment(rawValue: title))
            #expect(PlannedTripDetector.evaluate(snap) == nil, Comment(rawValue: title))
            let raw = try #require(PlannedTripDetector.rawScore(snap))
            #expect(!PlannedTripDetector.qualifiesForTieBreaker(score: raw.score, title: title), Comment(rawValue: title))
        }
        // A bare single noun ("Dentist") passes the lexical gate; an FM
        // positive must now supply a literal, geographically grounded place.
        let bare = snapshot(title: "Dentist", durationHours: 24, isAllDay: true)
        let raw = try #require(PlannedTripDetector.rawScore(bare))
        #expect(PlannedTripDetector.qualifiesForTieBreaker(score: raw.score, title: "Dentist"))
    }

    @Test func groundingRequiresLiteralPlaceSpansWithoutBlockingCJK() {
        #expect(CalendarEnricher.groundingDestination("Cephalonia", in: snapshot(title: "Cephalonia wedding")) == "Cephalonia")
        #expect(CalendarEnricher.groundingDestination("Αθήνα", in: snapshot(title: "Γάμος στην Αθήνα")) == "Αθήνα")
        #expect(CalendarEnricher.groundingDestination("東京", in: snapshot(title: "東京で結婚式")) == "東京")
        #expect(CalendarEnricher.groundingDestination("東京", in: snapshot(title: "東京旅行")) == "東京")
        #expect(CalendarEnricher.groundingDestination("北京", in: snapshot(title: "北京出差")) == "北京")
        #expect(CalendarEnricher.groundingDestination("京", in: snapshot(title: "東京")) == nil)
        #expect(CalendarEnricher.groundingDestination("Paris", in: snapshot(title: "Parisian dinner")) == nil)
        #expect(CalendarEnricher.groundingDestination("York", in: snapshot(title: "Yorkshire and York")) == "York")
        #expect(CalendarEnricher.groundingDestination("Paris", in: snapshot(title: "Dentist")) == nil)
        #expect(CalendarEnricher.groundingDestination("", in: snapshot(title: "Cephalonia wedding")) == nil)
        #expect(CalendarEnricher.groundingDestination("Athens", in: snapshot(title: "Αθήνα")) == nil)
    }
}

// MARK: - Distance signal and recurrence penalty

extension PlannedTripDetectorTests {

    /// The distance-signal fixture: unlabeled title, a fixed start and a
    /// personal iCloud calendar (distinct from `snapshot(title:)` above).
    private func snapshot(
        _ title: String,
        durationHours: Double = 2,
        recurring: Bool = false
    ) -> CalendarEventSnapshot {
        let start = Date(timeIntervalSince1970: 1_802_419_200)
        return CalendarEventSnapshot(
            externalIdentifier: "e", localIdentifier: "l", title: title,
            notes: nil, locationText: nil,
            startDate: start, endDate: start.addingTimeInterval(durationHours * 3600),
            isAllDay: false, hasRecurrenceRules: recurring, isDetached: false,
            calendarTitle: "Personal", calendarKind: .icloud
        )
    }

    @Test func farMultiDayEventWithZeroTravelVocabularyDetects() {
        // No keywords, no flight code — distance (3) + multiDay (1) = 4.
        let detection = PlannedTripDetector.evaluate(
            snapshot("Grandma's place", durationHours: 3 * 24),
            distanceFromHomeKm: 450
        )
        #expect(detection?.confidence == .medium)
        #expect(detection?.signals.contains(PlannedTripDetector.signalFarFromHome) == true)
    }

    @Test func recurringFarRoutineIsSuppressedByThePenalty() {
        // The weekly far-away client site: distance (3) + multiDay (1)
        // - recurring (3) = 1 → below cutoff. THE case the recurrence
        // penalty exists for; latent until this signal landed.
        let detection = PlannedTripDetector.evaluate(
            snapshot("Client site", durationHours: 26, recurring: true),
            distanceFromHomeKm: 450
        )
        #expect(detection == nil)
    }

    @Test func nearbyEventGetsNoDistanceSignal() {
        let detection = PlannedTripDetector.evaluate(
            snapshot("Grandma's place", durationHours: 3 * 24),
            distanceFromHomeKm: 40
        )
        #expect(detection == nil)   // multiDay (1) alone stays below cutoff
    }
}
