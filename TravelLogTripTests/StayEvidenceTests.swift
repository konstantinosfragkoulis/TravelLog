//
//  StayEvidenceTests.swift
//  TravelLogTests
//
//  `StayEvidence`: what a stay's own observations say about its dwell. Live
//  stays keep their stored interval; a photo-only stay's dwell lies between
//  its photos' span and the next observation, so it is short only when that
//  whole interval is, a base or overnight only when its photos show it.
//  Stage 2a, the heuristics and the sanity pass all read it.
//
//  Fixtures sit at longitude 0, so solar time is UTC.
//

import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Stay evidence", IsolatedTitleDefaults(), .timeLimit(.minutes(1)))
struct StayEvidenceTests {

    private func utc(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: 2, day: day, hour: hour, minute: minute))!
    }

    /// A stay whose pings are inserted with it, at `observations`; the
    /// stored end is `end` (clustering's extension included).
    @discardableResult
    private func stay(
        _ context: ModelContext, observations: [Date], end: Date, latitude: Double,
        source: DataSource, category: StayCategory = .unclassified
    ) -> Stay {
        let pings = observations.map {
            LocationPing(timestamp: $0, latitude: latitude, longitude: 0, horizontalAccuracy: 10,
                         h3IndexRes6: "evidence", source: source)
        }
        pings.forEach(context.insert)
        let row = Stay(startTime: observations[0], endTime: end, centroidLatitude: latitude,
            centroidLongitude: 0, h3IndexRes6: "evidence-\(latitude)", pingCount: pings.count,
            distanceFromHomeKm: 500, pingIDs: pings.map(\.id), source: source)
        row.category = category
        context.insert(row)
        return row
    }

    // MARK: - The value

    @Test("a single photo's extended night is not observed; a burst through the night and a live stay are")
    func observedOvernightVersusExtended() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let single = stay(context, observations: [utc(1, 22)], end: utc(2, 4), latitude: 0, source: .photoImport)
        let extended = StayEvidence(photos: single, firstObservation: utc(1, 22),
                                    lastObservation: utc(1, 22), nextStart: utc(2, 10))
        #expect(extended.storedOvernight)
        #expect(!extended.spansNight)

        let burst = StayEvidence(photos: single, firstObservation: utc(1, 22),
                                 lastObservation: utc(2, 4), nextStart: utc(2, 10))
        #expect(burst.spansNight)

        let live = stay(context, observations: [utc(3, 22)], end: utc(4, 4), latitude: 0, source: .liveSLC)
        #expect(StayEvidence(measured: live).spansNight)
    }

    @Test("a single photo with a capped extension is neither short nor long")
    func cappedSinglePhotoHasUnknownDwell() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let single = stay(context, observations: [utc(1, 10)], end: utc(1, 22), latitude: 0, source: .photoImport)
        let evidence = StayEvidence(photos: single, firstObservation: utc(1, 10),
                                    lastObservation: utc(1, 10), nextStart: utc(2, 16))
        #expect(evidence.storedMinutes == 720)
        #expect(!evidence.isShorter(than: 180))
        #expect(!evidence.lasted(atLeast: 360))
        #expect(evidence.settledCategory == nil)
    }

    @Test("a short photo stay is a short stop only when the next observation bounds it")
    func photoShortStopNeedsABound() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let single = stay(context, observations: [utc(1, 10)], end: utc(1, 10, 5), latitude: 0,
                          source: .photoImport)
        let bounded = StayEvidence(photos: single, firstObservation: utc(1, 10),
                                   lastObservation: utc(1, 10), nextStart: utc(1, 10, 10))
        #expect(bounded.isShortStop)
        #expect(bounded.settledCategory == .transit)
        let unbounded = StayEvidence(photos: single, firstObservation: utc(1, 10),
                                     lastObservation: utc(1, 10), nextStart: nil)
        #expect(!unbounded.isShortStop)
        #expect(unbounded.settledCategory == nil)
    }

    @Test("a live stay keeps its stored interval: short stop, sub-three-hour stop and base as before")
    func liveStaysAreMeasured() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        let stop = StayEvidence(measured: stay(context, observations: [utc(1, 10)], end: utc(1, 10, 15),
                                               latitude: 0, source: .liveSLC))
        #expect(stop.isShortStop)
        let errand = StayEvidence(measured: stay(context, observations: [utc(2, 10)], end: utc(2, 12, 45),
                                                 latitude: 0, source: .liveSLC))
        #expect(errand.isShorter(than: 180))
        #expect(!errand.isShortStop)
        let base = StayEvidence(measured: stay(context, observations: [utc(3, 8)], end: utc(3, 15),
                                               latitude: 0, source: .liveSLC))
        #expect(base.lasted(atLeast: 360))
    }

    @Test("a photo stay whose next observation came hours later is not a sub-three-hour stop")
    func photoStopUnderThreeHoursNeedsTheWholeInterval() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        // Photos 78 minutes apart, the next observation 174 minutes after the last.
        let pair = stay(context, observations: [utc(1, 10), utc(1, 11, 18)], end: utc(1, 12, 45),
                        latitude: 0, source: .photoImport)
        let evidence = StayEvidence(photos: pair, firstObservation: utc(1, 10),
                                    lastObservation: utc(1, 11, 18), nextStart: utc(1, 14, 12))
        #expect(evidence.storedMinutes == 165)
        #expect(evidence.observedMinutes == 78)
        #expect(!evidence.isShorter(than: 180))
    }

    @Test("a photo stay may have spanned the night when solar 03:00 came within seven hours of its last photo and before the next observation")
    func nightPossibleBounds() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        func evidence(lastPhoto: Date, nextStart: Date?) -> StayEvidence {
            let row = stay(context, observations: [lastPhoto], end: lastPhoto.addingTimeInterval(3600),
                           latitude: 0, source: .photoImport)
            return StayEvidence(photos: row, firstObservation: lastPhoto, lastObservation: lastPhoto,
                                nextStart: nextStart)
        }
        // 03:00 comes 6 h 59 min after a photo at 20:01, 7 h 01 min after one at 19:59.
        #expect(evidence(lastPhoto: utc(1, 20, 1), nextStart: utc(2, 9)).nightPossible)
        #expect(!evidence(lastPhoto: utc(1, 19, 59), nextStart: utc(2, 9)).nightPossible)
        #expect(evidence(lastPhoto: utc(1, 20, 1), nextStart: nil).nightPossible)
        // The next observation at 02:30 shows the user moved on before 03:00.
        let bounded = evidence(lastPhoto: utc(3, 22), nextStart: utc(4, 2, 30))
        #expect(!bounded.nightPossible)
        #expect(!bounded.spansNight)
        #expect(evidence(lastPhoto: utc(3, 22), nextStart: utc(4, 4)).nightPossible)
        // Seconds count: a photo at 22:00:45 and the next stay at 03:00:15
        // leave 03:00 unobserved, though whole minutes would end at 02:59:45.
        let seconds = evidence(lastPhoto: utc(5, 22).addingTimeInterval(45),
                               nextStart: utc(6, 3).addingTimeInterval(15))
        #expect(seconds.boundMinutes == 299)
        #expect(seconds.nightPossible)
        // A live stay's night is its stored interval's.
        let live = StayEvidence(measured: stay(context, observations: [utc(7, 22)], end: utc(7, 23, 30),
                                               latitude: 0, source: .liveSLC))
        #expect(!live.nightPossible)
        #expect(live.firstObservation == utc(7, 22))
        #expect(live.lastObservation == utc(7, 23, 30))
    }

    @Test("an airport stay under a day is a stop only when it shows no night")
    func airportStopNeedsNoNight() throws {
        let context = ModelContext(try TestSupport.makeInMemoryContainer())
        func airport(_ start: Date, _ end: Date, source: DataSource = .liveSLC) -> Stay {
            let row = stay(context, observations: [start], end: end, latitude: 0, source: source)
            row.isAirport = true
            return row
        }
        let day = StayEvidence(measured: airport(utc(1, 9), utc(1, 17)))
        #expect(day.isAirportStop)
        #expect(day.settledCategory == .transit)
        let night = StayEvidence(measured: airport(utc(2, 22), utc(3, 6)))
        #expect(!night.isAirportStop)
        #expect(night.settledCategory == nil)
        #expect(night.sanityCorrection(of: .destination) == nil)
        // One evening photo whose stored interval runs past 03:00 shows no night.
        let photo = airport(utc(4, 22), utc(5, 4), source: .photoImport)
        let evening = StayEvidence(photos: photo, firstObservation: utc(4, 22), lastObservation: utc(4, 22),
                                   nextStart: utc(5, 10))
        #expect(evening.isAirportStop)
        #expect(evening.nightPossible)
    }

    // MARK: - Through the classifier

    /// A short live stop 5.6 km from a photo stay, with a far stay after it:
    /// the journey test calls it the photo stay's departure point only when
    /// the photos themselves span six hours.
    @Test("only a photo burst spanning six hours is a base for the stop beside it", arguments: [false, true])
    func photoBaseNeedsObservedDwell(burst: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let photos = burst ? [utc(1, 10), utc(1, 13), utc(1, 17)] : [utc(1, 10)]
        stay(context, observations: photos, end: utc(1, 22), latitude: 0, source: .photoImport)
        let port = stay(context, observations: [utc(1, 22, 30)], end: utc(1, 23), latitude: 0.05, source: .liveSLC)
        stay(context, observations: [utc(2, 2)], end: utc(2, 12), latitude: 1, source: .liveSLC)
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        let outcome = await classifier.runDeterministicClassificationForTesting()
        #expect(outcome.resolved >= 0)
        #expect(await classifier.stayCategoryForTesting(port.id) == (burst ? .transit : .destination))
    }

    @Test("the sanity pass leaves an unbounded short photo destination, and corrects a bounded one")
    func sanityReadsTheSameEvidence() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let lone = stay(context, observations: [utc(1, 10)], end: utc(1, 10, 10), latitude: 0,
                        source: .photoImport, category: .destination)
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.sanityFixpointViolatedForTesting() == false)
        #expect(await classifier.sanityCheckClassifications() == 0)
        #expect(await classifier.stayCategoryForTesting(lone.id) == .destination)

        // The next observation, twenty minutes after the photo, bounds it.
        stay(context, observations: [utc(1, 10, 20)], end: utc(1, 16), latitude: 1,
             source: .liveSLC, category: .destination)
        try context.save()
        #expect(await classifier.sanityFixpointViolatedForTesting())
        #expect(await classifier.sanityCheckClassifications() == 1)
        #expect(await classifier.stayCategoryForTesting(lone.id) == .transit)
        #expect(await classifier.sanityFixpointViolatedForTesting() == false)
    }

    @Test("a later-starting UUID twin does not bound its own photo stay")
    func twinIsNotTheNextStay() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let lone = stay(context, observations: [utc(1, 10)], end: utc(1, 10, 10), latitude: 0,
                        source: .photoImport, category: .destination)
        let twin = stay(context, observations: [utc(1, 10, 20)], end: utc(1, 10, 30), latitude: 0,
                        source: .photoImport, category: .destination)
        twin.id = lone.id
        try context.save()

        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.sanityFixpointViolatedForTesting() == false)
        #expect(await classifier.sanityCheckClassifications() == 0)
        #expect(await classifier.stayCategoryForTesting(lone.id) == .destination)
    }
}
