//
//  ImportPhotoSpanResetTests.swift
//  TravelLogTests
//
//  A photo-only stop is a journey stop only while its photos span under 45
//  minutes. Another photo absorbed inside its stored interval moves no
//  duration, airport or night input, so import reads the host's member photo
//  times (one per UUID, a twin's earliest, as `StayEvidence` does) and hands
//  an automatic transit host back once its span reaches 45 minutes, or once
//  its last photo brings solar 03:00 within the night lookahead before the
//  next stay starts (a night is then possible there). Span and night count
//  only while the duration rules leave the stop to the journey test: an
//  airport stop is transit whatever its night, so it is handed back only when
//  its photos come to span one. A fix of another source makes the stored
//  interval the stop's dwell, so it hands the stop back when that interval
//  is no brief stop, and a photo-only destination back when that interval
//  is brief or shorter than a departure stop where its photos were not, or
//  when one of its photos has not synced yet. A photo that makes a stay a
//  base (photos spanning six hours), or no longer one, hands back the stops
//  beside it whose journey test reads it. A failed read of those times
//  rolls the batch back for replay.
//

import Foundation
import SwiftData
import CoreLocation
import Testing
@testable import TravelLog

@MainActor
@Suite("Import photo span resets", .serialized)
struct ImportPhotoSpanResetTests {

    private static let place = (lat: 44.3, lon: 12.9)
    private static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ minutes: Double) -> Date {
        Self.base.addingTimeInterval(minutes * 60)
    }

    private var cell: String { H3Service.cellIndex(latitude: Self.place.lat, longitude: Self.place.lon) ?? "" }

    /// A photo-only transit stop from 0 to 120 minutes whose photos sit at
    /// `photos` minutes; `twin` adds a later row under the second photo's id.
    @discardableResult
    private func seedStop(_ context: ModelContext, photos: [Double], twin: Double? = nil) throws -> UUID {
        let pings = photos.map {
            LocationPing(timestamp: at($0), latitude: Self.place.lat, longitude: Self.place.lon,
                         horizontalAccuracy: 10, h3IndexRes6: cell, source: .photoImport)
        }
        pings.forEach(context.insert)
        for ping in pings { ping.isProcessed = true }
        if let twin {
            let copy = LocationPing(timestamp: at(twin), latitude: Self.place.lat, longitude: Self.place.lon,
                                    horizontalAccuracy: 10, h3IndexRes6: cell, source: .photoImport)
            copy.id = pings[1].id
            copy.isProcessed = true
            context.insert(copy)
        }
        let stop = Stay(startTime: at(0), endTime: at(120), centroidLatitude: Self.place.lat,
                        centroidLongitude: Self.place.lon, h3IndexRes6: cell, pingCount: pings.count,
                        distanceFromHomeKm: 500, pingIDs: pings.map(\.id), source: .photoImport)
        stop.category = .transit
        context.insert(stop)
        try context.save()
        return stop.id
    }

    private func importPhoto(at minutes: Double, _ recorder: PingRecorder) async throws {
        _ = try await recorder.recordImportedPings([
            ImportedPingCandidate(timestamp: at(minutes), latitude: Self.place.lat,
                                  longitude: Self.place.lon, horizontalAccuracy: 10)
        ], source: .photoImport)
        try await recorder.saveImportBatch()
    }

    private func stop(_ id: UUID, _ container: ModelContainer) throws -> Stay {
        try #require(try ModelContext(container).fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == id })).first)
    }

    @Test("a photo that stretches the span past 45 minutes hands the stop back; one inside 45 does not")
    func spanCrossingResets() async throws {
        for (minutes, reset) in [(50.0, true), (40.0, false)] {
            let container = try TestSupport.makeInMemoryContainer()
            let id = try seedStop(ModelContext(container), photos: [0, 30])
            try await importPhoto(at: minutes, PingRecorder(modelContainer: container))
            let saved = try stop(id, container)
            #expect(saved.pingIDs.count == 3)
            #expect(saved.durationMinutes == 120)
            #expect(saved.category == (reset ? .unclassified : .transit))
        }
    }

    @Test("a member photo stored twice counts once, at its earlier time")
    func twinMemberPhotoCountsOnce() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let id = try seedStop(ModelContext(container), photos: [0, 30], twin: 35)
        try await importPhoto(at: 50, PingRecorder(modelContainer: container))
        #expect(try stop(id, container).category == .unclassified)
    }

    // MARK: - Other evidence

    @Test("a GPX fix inside a brief photo stop's span hands it back: its stored interval is now its dwell")
    func otherEvidenceInsideTheSpanResets() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let id = try seedStop(ModelContext(container), photos: [0, 30])
        let recorder = PingRecorder(modelContainer: container)
        _ = try await recorder.recordImportedPings([
            ImportedPingCandidate(timestamp: at(20), latitude: Self.place.lat,
                                  longitude: Self.place.lon, horizontalAccuracy: 10)
        ], source: .gpxImport)
        try await recorder.saveImportBatch()
        let saved = try stop(id, container)
        // Nothing a photo-only reading sees moves; the stay is now judged on
        // 120 measured minutes, which are no brief stop.
        #expect(saved.pingIDs.count == 3)
        #expect(saved.durationMinutes == 120)
        #expect(saved.source == .merged)
        #expect(saved.category == .unclassified)
    }

    /// A photo-only stop whose photos sit at 0 and 50 minutes, stored to
    /// `storedTo` (clustering's extension halfway to the next stay, at
    /// `nextAt`), after a measured stay at `westLon` and before one 40 km
    /// east. All three wait for classification.
    private func seedJourney(_ context: ModelContext, westLon: Double, storedTo: Double,
                             nextAt: Double) throws -> UUID {
        let pings = [0.0, 50].map {
            LocationPing(timestamp: at($0), latitude: Self.place.lat, longitude: Self.place.lon,
                         horizontalAccuracy: 10, h3IndexRes6: cell, source: .photoImport)
        }
        pings.forEach(context.insert)
        for ping in pings { ping.isProcessed = true }
        let stop = Stay(startTime: at(0), endTime: at(storedTo), centroidLatitude: Self.place.lat,
                        centroidLongitude: Self.place.lon, h3IndexRes6: cell, pingCount: pings.count,
                        distanceFromHomeKm: 500, pingIDs: pings.map(\.id), source: .photoImport)
        context.insert(stop)
        for (lon, from, to) in [(westLon, -400.0, -5.0), (13.4, nextAt, nextAt + 300)] {
            TemporaryHomeFixture.stay(
                context, (Self.place.lat, lon), from: at(from), to: at(to), .unclassified,
                hex: H3Service.cellIndex(latitude: Self.place.lat, longitude: lon) ?? "", pingCount: 4)
        }
        try context.save()
        return stop.id
    }

    @Test("a GPX fix that makes a photo destination's stored interval its dwell hands it back: brief between far stays, or short beside a base, it is a journey stop",
          arguments: [(12.4, 55.0, 60.0), (12.8, 75.0, 100.0)] as [(Double, Double, Double)])
    func otherEvidenceHandsADestinationBack(westLon: Double, storedTo: Double, nextAt: Double) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let id = try seedJourney(ModelContext(container), westLon: westLon, storedTo: storedTo, nextAt: nextAt)
        let classifier = TripClassifier(modelContainer: container)
        await TemporaryHomeFixture.ordinaryPass(classifier)
        // Photos spanning 50 minutes are no brief stop; beside the base 8 km
        // west, the next stay starts 100 minutes after the first photo, so
        // the dwell may have lasted a departure stop's 90.
        #expect(try stop(id, container).category == .destination)

        let recorder = PingRecorder(modelContainer: container)
        _ = try await recorder.recordImportedPings([
            ImportedPingCandidate(timestamp: at(20), latitude: Self.place.lat,
                                  longitude: Self.place.lon, horizontalAccuracy: 10)
        ], source: .gpxImport)
        try await recorder.saveImportBatch()
        let saved = try stop(id, container)
        // No duration band, airport or night moves; the stored 55 minutes
        // are brief, the stored 75 shorter than a departure stop.
        #expect(saved.pingIDs.count == 3)
        #expect(saved.durationMinutes == Int(storedTo))
        #expect(saved.source == .merged)
        #expect(saved.category == .unclassified)
        await TemporaryHomeFixture.ordinaryPass(classifier)
        #expect(try stop(id, container).category == .transit)
    }

    @Test("a GPX fix hands a photo destination back while one of its photos has not synced: its photos no longer show what judged it",
          arguments: [(12.4, 55.0, 60.0), (12.8, 75.0, 100.0)] as [(Double, Double, Double)])
    func otherEvidenceHandsADestinationBackWithAPhotoMissing(westLon: Double, storedTo: Double,
                                                            nextAt: Double) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let id = try seedJourney(ModelContext(container), westLon: westLon, storedTo: storedTo, nextAt: nextAt)
        let classifier = TripClassifier(modelContainer: container)
        await TemporaryHomeFixture.ordinaryPass(classifier)
        #expect(try stop(id, container).category == .destination)
        // The 50-minute photo's ping is not on this device yet: the stop
        // still lists it, and its stored interval stands in for its photos
        // before the fix as after it.
        let context = ModelContext(container)
        let missingID = try #require(try stop(id, container).pingIDs.last)
        for ping in try context.fetch(FetchDescriptor<LocationPing>(predicate: #Predicate { $0.id == missingID })) {
            context.delete(ping)
        }
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<LocationPing>()) == 1)

        let recorder = PingRecorder(modelContainer: container)
        _ = try await recorder.recordImportedPings([
            ImportedPingCandidate(timestamp: at(20), latitude: Self.place.lat,
                                  longitude: Self.place.lon, horizontalAccuracy: 10)
        ], source: .gpxImport)
        try await recorder.saveImportBatch()
        let saved = try stop(id, container)
        #expect(saved.pingIDs.count == 3)
        #expect(saved.durationMinutes == Int(storedTo))
        #expect(saved.source == .merged)
        #expect(saved.category == .unclassified)
        await TemporaryHomeFixture.ordinaryPass(classifier)
        #expect(try stop(id, container).category == .transit)
    }

    // MARK: - Night possible

    /// At longitude 0 solar time is UTC; a fictional UTC midnight.
    private static let nightPlace = (lat: 45.0, lon: 0.0)
    private static let midnight = Date(timeIntervalSinceReferenceDate: 9_000 * 86_400)

    private func evening(_ hour: Double) -> Date {
        Self.midnight.addingTimeInterval(hour * 3600)
    }

    /// A photo-only transit stop stored from 19:30 to 21:30 whose photos sit
    /// at 19:30 and 19:50: brief, and its last photo's seven-hour lookahead
    /// ends at 02:50, short of 03:00. `nextStayAt` adds a stay 55 km away.
    private func seedEveningStop(_ context: ModelContext, nextStayAt: Double?) throws -> UUID {
        let place = Self.nightPlace
        let cell = H3Service.cellIndex(latitude: place.lat, longitude: place.lon) ?? ""
        let pings = [19.5, 19.5 + 20.0 / 60].map {
            LocationPing(timestamp: evening($0), latitude: place.lat, longitude: place.lon,
                         horizontalAccuracy: 10, h3IndexRes6: cell, source: .photoImport)
        }
        pings.forEach(context.insert)
        for ping in pings { ping.isProcessed = true }
        let stop = Stay(startTime: evening(19.5), endTime: evening(21.5), centroidLatitude: place.lat,
                        centroidLongitude: place.lon, h3IndexRes6: cell, pingCount: pings.count,
                        distanceFromHomeKm: 500, pingIDs: pings.map(\.id), source: .photoImport)
        stop.category = .transit
        context.insert(stop)
        if let nextStayAt {
            let next = Stay(startTime: evening(nextStayAt), endTime: evening(nextStayAt + 10),
                            centroidLatitude: place.lat + 0.5, centroidLongitude: place.lon,
                            h3IndexRes6: H3Service.cellIndex(latitude: place.lat + 0.5, longitude: place.lon) ?? "",
                            pingCount: 1, distanceFromHomeKm: 500, pingIDs: [], source: .photoImport)
            next.category = .destination
            context.insert(next)
        }
        try context.save()
        return stop.id
    }

    @Test("a photo that brings solar 03:00 within reach of the stop's last photo hands it back, unless the next stay starts first",
          arguments: [(20.0 + 10.0 / 60, nil, true), (19.5 + 25.0 / 60, nil, false), (20.0 + 10.0 / 60, 23.0, false)]
            as [(Double, Double?, Bool)])
    func nightPossibleCrossingResets(photoAt hour: Double, nextStayAt: Double?, reset: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let id = try seedEveningStop(ModelContext(container), nextStayAt: nextStayAt)
        let recorder = PingRecorder(modelContainer: container)
        _ = try await recorder.recordImportedPings([
            ImportedPingCandidate(timestamp: evening(hour), latitude: Self.nightPlace.lat,
                                  longitude: Self.nightPlace.lon, horizontalAccuracy: 10)
        ], source: .photoImport)
        try await recorder.saveImportBatch()
        let saved = try stop(id, container)
        // The photo lands inside the stored interval and keeps the span under
        // 45 minutes: only the night input can move.
        #expect(saved.pingIDs.count == 3)
        #expect(saved.durationMinutes == 120)
        #expect(saved.category == (reset ? .unclassified : .transit))
    }

    // MARK: - A base beside a stop

    /// A port about 5 km east of the photo stay, and a place about 100 km
    /// further east.
    private static let port = (lat: 44.3, lon: 12.96)
    private static let farPlace = (lat: 44.3, lon: 14.2)

    /// Fixture day hours, UTC; under an hour behind solar time here, so
    /// every stay is daytime.
    private func clock(_ hour: Double) -> Date {
        Self.midnight.addingTimeInterval(hour * 3600)
    }

    /// A photo-only stay stored from 08:00 to 15:45 whose photos sit at
    /// `photos` hours, a measured 30-minute port stay and a measured stay
    /// at the far place: the port at 16:00 and the far stay at 18:00, or
    /// the far stay at 03:30 and the port at 07:00. All three wait for
    /// classification.
    private func seedPortBeside(_ context: ModelContext, photos: [Double],
                                portAfter: Bool) throws -> (stay: UUID, port: UUID) {
        let pings = photos.map {
            LocationPing(timestamp: clock($0), latitude: Self.place.lat, longitude: Self.place.lon,
                         horizontalAccuracy: 10, h3IndexRes6: cell, source: .photoImport)
        }
        pings.forEach(context.insert)
        for ping in pings { ping.isProcessed = true }
        let stay = Stay(startTime: clock(8), endTime: clock(15.75), centroidLatitude: Self.place.lat,
                        centroidLongitude: Self.place.lon, h3IndexRes6: cell, pingCount: pings.count,
                        distanceFromHomeKm: 500, pingIDs: pings.map(\.id), source: .photoImport)
        context.insert(stay)
        let (portFrom, farFrom, farTo) = portAfter ? (16.0, 18.0, 22.0) : (7.0, 3.5, 6.0)
        let port = TemporaryHomeFixture.stay(
            context, Self.port, from: clock(portFrom), to: clock(portFrom + 0.5), .unclassified,
            hex: H3Service.cellIndex(latitude: Self.port.lat, longitude: Self.port.lon) ?? "", pingCount: 4)
        TemporaryHomeFixture.stay(
            context, Self.farPlace, from: clock(farFrom), to: clock(farTo), .unclassified,
            hex: H3Service.cellIndex(latitude: Self.farPlace.lat, longitude: Self.farPlace.lon) ?? "",
            pingCount: 4)
        try context.save()
        return (stay.id, port.id)
    }

    /// The pass a finished import runs: no recent-stay reclassification.
    private func importPass(_ classifier: TripClassifier) async {
        _ = await classifier.classifyAndAssembleTripsWithGates(
            reclassifyRecentStays: false, gate: PipelineGate(forTesting: ()))
    }

    @Test("a photo that makes a stay a base hands back the port stop beside it, after or before it; one that leaves it short of six hours does not",
          arguments: [(true, 14.5, true), (false, 14.5, true), (true, 13.5, false)] as [(Bool, Double, Bool)])
    func photoThatMakesABaseHandsBackItsPort(portAfter: Bool, photoAt: Double, base: Bool) async throws {
        // Every photo present from the start: photos spanning six and a
        // half hours make the stay a base, and the port beside it, 100 km
        // from the far stay, its departure or arrival stop.
        let expected: StayCategory = base ? .transit : .destination
        let control = try TestSupport.makeInMemoryContainer()
        let controlIDs = try seedPortBeside(ModelContext(control), photos: [8, 11, photoAt], portAfter: portAfter)
        await importPass(TripClassifier(modelContainer: control))
        #expect(try stop(controlIDs.port, control).category == expected)

        let container = try TestSupport.makeInMemoryContainer()
        let ids = try seedPortBeside(ModelContext(container), photos: [8, 11], portAfter: portAfter)
        let classifier = TripClassifier(modelContainer: container)
        await importPass(classifier)
        // Photos three hours apart show no base, and the port, 5 km from
        // the stay, is no through-stop either.
        #expect(try stop(ids.stay, container).category == .destination)
        let port = try stop(ids.port, container)
        #expect(port.category == .destination)
        #expect(!(port.trip?.isComplete ?? false))

        let recorder = PingRecorder(modelContainer: container)
        _ = try await recorder.recordImportedPings([
            ImportedPingCandidate(timestamp: clock(photoAt), latitude: Self.place.lat,
                                  longitude: Self.place.lon, horizontalAccuracy: 10)
        ], source: .photoImport)
        try await recorder.saveImportBatch()
        // The photo lands inside the stored interval: nothing of the stay's
        // own moves, and it keeps its category.
        let host = try stop(ids.stay, container)
        #expect(host.pingIDs.count == 3)
        #expect(host.durationMinutes == 465)
        #expect(host.source == .photoImport)
        #expect(host.category == .destination)
        #expect(try stop(ids.port, container).category == (base ? .unclassified : .destination))
        await importPass(classifier)
        #expect(try stop(ids.port, container).category == expected)
    }

    /// Every copy of the port's id, in start order.
    private func portCopies(_ id: UUID, _ container: ModelContainer) throws -> [StayCategory] {
        try ModelContext(container).fetch(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.id == id }, sortBy: [SortDescriptor(\.startTime)])).map(\.category)
    }

    /// A later, longer copy of the port under its id, as a sync can leave one.
    private func addPortTwin(_ id: UUID, _ container: ModelContainer) throws {
        let context = ModelContext(container)
        let twin = TemporaryHomeFixture.stay(
            context, Self.port, from: clock(16 + 5.0 / 60), to: clock(19 + 5.0 / 60), .unclassified,
            hex: H3Service.cellIndex(latitude: Self.port.lat, longitude: Self.port.lon) ?? "", pingCount: 4)
        twin.id = id
        try context.save()
    }

    @Test("a photo that makes a stay a base hands back every copy of the port beside it")
    func photoThatMakesABaseHandsBackEveryPortCopy() async throws {
        let control = try TestSupport.makeInMemoryContainer()
        let controlIDs = try seedPortBeside(ModelContext(control), photos: [8, 11, 14.5], portAfter: true)
        try addPortTwin(controlIDs.port, control)
        await importPass(TripClassifier(modelContainer: control))
        #expect(try portCopies(controlIDs.port, control) == [.transit, .transit])

        let container = try TestSupport.makeInMemoryContainer()
        let ids = try seedPortBeside(ModelContext(container), photos: [8, 11], portAfter: true)
        try addPortTwin(ids.port, container)
        let classifier = TripClassifier(modelContainer: container)
        await importPass(classifier)
        // One decision for the port, judged by its earlier, 30-minute copy.
        #expect(try portCopies(ids.port, container) == [.destination, .destination])

        let recorder = PingRecorder(modelContainer: container)
        _ = try await recorder.recordImportedPings([
            ImportedPingCandidate(timestamp: clock(14.5), latitude: Self.place.lat,
                                  longitude: Self.place.lon, horizontalAccuracy: 10)
        ], source: .photoImport)
        try await recorder.saveImportBatch()
        #expect(try stop(ids.stay, container).durationMinutes == 465)
        #expect(try portCopies(ids.port, container) == [.unclassified, .unclassified])
        await importPass(classifier)
        #expect(try portCopies(ids.port, container) == [.transit, .transit])
    }

    // MARK: - Airport stop

    /// ATH reference point (OurAirports), the centre of its ring.
    private static let athens = (lat: 37.9364, lon: 23.9445)

    /// Solar `hour` at the airport on the fixture's day.
    private func solar(_ hour: Double) -> Date {
        Self.midnight.addingTimeInterval((hour - Self.athens.lon / 15) * 3600)
    }

    @Test("an airport stop's span, possible night or other evidence changes nothing while the airport rule settles it; photos that show a night there hand it back",
          arguments: [(19.5, 21.5, 20.0 + 10.0 / 60, .photoImport, false), (19.5, 21.5, 20.0, .gpxImport, false),
                      (22.0, 30.0, 28.0, .photoImport, true)]
            as [(Double, Double, Double, DataSource, Bool)])
    func airportStopResetsOnlyWhenItsRuleMoves(storedFrom: Double, storedTo: Double, photoAt: Double,
                                               source: DataSource, reset: Bool) async throws {
        let place = Self.athens
        try #require(AirportDetector.shared.isNearAirport(
            CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon)))
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let cell = H3Service.cellIndex(latitude: place.lat, longitude: place.lon) ?? ""
        // Two photos twenty minutes apart at the stored start.
        let pings = [storedFrom, storedFrom + 20.0 / 60].map {
            LocationPing(timestamp: solar($0), latitude: place.lat, longitude: place.lon,
                         horizontalAccuracy: 10, h3IndexRes6: cell, source: .photoImport)
        }
        pings.forEach(context.insert)
        for ping in pings { ping.isProcessed = true }
        let seeded = Stay(startTime: solar(storedFrom), endTime: solar(storedTo), centroidLatitude: place.lat,
                          centroidLongitude: place.lon, h3IndexRes6: cell, pingCount: pings.count,
                          distanceFromHomeKm: 500, pingIDs: pings.map(\.id), source: .photoImport)
        seeded.isAirport = true
        seeded.category = .transit
        context.insert(seeded)
        try context.save()
        let id = seeded.id
        let minutes = seeded.durationMinutes

        let recorder = PingRecorder(modelContainer: container)
        _ = try await recorder.recordImportedPings([
            ImportedPingCandidate(timestamp: solar(photoAt), latitude: place.lat,
                                  longitude: place.lon, horizontalAccuracy: 10)
        ], source: source)
        try await recorder.saveImportBatch()
        let saved = try stop(id, container)
        #expect(saved.pingIDs.count == 3)
        #expect(saved.durationMinutes == minutes)
        #expect(saved.isAirport)
        // 20:10: solar 03:00 comes within seven hours, but an airport stop
        // under a day is transit whatever its night. A GPX fix at 20:00 makes
        // the stored interval the dwell, which shows no night either. 04:00:
        // the photos now span solar 03:00, so the stay may be an airport
        // hotel night.
        #expect(saved.category == (reset ? .unclassified : .transit))
    }

    #if DEBUG
    @Test("a failed member-photo read saves nothing and a retry hands the stop back")
    func memberPhotoReadFailureReplays() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let id = try seedStop(ModelContext(container), photos: [0, 30])
        let recorder = PingRecorder(modelContainer: container)
        await recorder.setFailNextImportMemberPhotoFetchForTesting(true)
        await #expect(throws: CocoaError.self) {
            _ = try await recorder.recordImportedPings([
                ImportedPingCandidate(timestamp: at(50), latitude: Self.place.lat,
                                      longitude: Self.place.lon, horizontalAccuracy: 10)
            ], source: .photoImport)
        }
        let untouched = try stop(id, container)
        #expect(untouched.pingIDs.count == 2)
        #expect(untouched.category == .transit)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<LocationPing>()) == 2)

        try await importPhoto(at: 50, recorder)
        #expect(try stop(id, container).category == .unclassified)
    }
    #endif
}
