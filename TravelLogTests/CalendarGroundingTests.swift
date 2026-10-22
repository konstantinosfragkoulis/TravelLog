import Foundation
import SwiftData
import Testing
@testable import TravelLog

// Extend the existing serialized suite: these tests share its real judgment-cache
// defaults keys, and drive resolveAndAugment rather than a parallel policy replica.
extension CalendarEnricherScanTests {
    private actor GroundingCalls {
        var judgments = 0
        var resolutions: [String] = []
        func judged() { judgments += 1 }
        func resolved(_ text: String) { resolutions.append(text) }
    }

    nonisolated private static func groundingEvent(_ title: String, location: String? = nil, id: String = "grounding",
                                                  start: Date = .now.addingTimeInterval(15_724_800).addingTimeInterval(60 * 86_400)) -> CalendarEventSnapshot {
        return CalendarEventSnapshot(externalIdentifier: id, localIdentifier: id, title: title,
            notes: nil, locationText: location, startDate: start, endDate: start.addingTimeInterval(48 * 3600),
            isAllDay: false, hasRecurrenceRules: false, isDetached: false, calendarTitle: "Test", calendarKind: .icloud)
    }

    nonisolated private static func groundingVerdict(_ destination: String, isTrip: Bool = true) -> PlannedTripJudgment {
        PlannedTripJudgment(reasoning: "Fixture", isTrip: isTrip, destination: destination)
    }

    nonisolated private static var groundingPlace: ForwardGeocodedPlace {
        .init(latitude: 38.20133, longitude: 20.43706, locality: "Lixoúri", country: "Greece", isoCountryCode: "GR")
    }

    private func groundingScan(
        _ enricher: CalendarEnricher, _ snapshots: [CalendarEventSnapshot],
        resolutionBudget: Int = 25, judgmentBudget: Int = 5, allowFM: Bool = true,
        now: Date = .now.addingTimeInterval(15_724_800),
        cache: @escaping @Sendable (String) async -> ForwardGeocoder.CachedResolution = { _ in .miss },
        resolve: @escaping @Sendable (String, Bool, Bool) async -> ForwardGeocoder.ResolutionOutcome = { _, _, _ in .unavailable },
        judge: @escaping @Sendable (CalendarEventSnapshot) async -> PlannedTripJudgment? = { _ in nil }
    ) async -> CalendarEnricher.ScanAnalysis {
        let epoch = await enricher.calendarDataEpochForTesting()
        return await enricher.resolveAndAugment(detections: PlannedTripDetector.detect(in: snapshots),
            allSnapshots: snapshots, allowFMTieBreaker: allowFM, allowNetworkResolution: true,
            expectedEpoch: epoch, now: now, resolutionBudget: resolutionBudget,
            judgmentBudget: judgmentBudget, cacheLookup: cache, resolve: resolve, judge: judge)
    }

    private func reconcileGrounding(_ analysis: CalendarEnricher.ScanAnalysis, with enricher: CalendarEnricher, now: Date = .now.addingTimeInterval(15_724_800)) async {
        await enricher.applyScan(detections: analysis.detections, rejectedGeocodes: analysis.rejectedGeocodes,
            deferredGroundingSnapshots: analysis.deferredGroundingSnapshots, now: now)
    }

    @Test func literalCephaloniaGroundingRetriesResolverWithoutRepeatingModel() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.clearFMJudgmentCache()
        let event = Self.groundingEvent("Cephalonia wedding")
        let calls = GroundingCalls()
        let first = await groundingScan(enricher, [event], resolve: { text, _, cacheMisses in
            #expect(!cacheMisses)
            await calls.resolved(text)
            return .unavailable
        }, judge: { _ in
            await calls.judged()
            return Self.groundingVerdict("Cephalonia")
        })
        #expect(first.detections.isEmpty)
        #expect(first.deferredGroundingSnapshots.count == 1)
        await reconcileGrounding(first, with: enricher)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PlannedTrip>()) == 0)
        let second = await groundingScan(enricher, [event], resolve: { text, _, cacheMisses in
            #expect(!cacheMisses)
            await calls.resolved(text)
            return .resolved(Self.groundingPlace)
        }, judge: { _ in
            await calls.judged()
            return nil
        })
        #expect(second.detections.first?.resolved?.place.locality == "Lixoúri")
        #expect(await calls.judgments == 1)
        #expect(await calls.resolutions == ["Cephalonia", "Cephalonia"])
    }

    @Test func unusablePositiveExtractionHasBoundedCooldownAndRemainsRetryable() async throws {
        for invalid in ["", "Paris", "Dentist", "Cephalonia"] {
            let container = try TestSupport.makeInMemoryContainer()
            let enricher = CalendarEnricher(modelContainer: container)
            await enricher.clearFMJudgmentCache()
            let literal = invalid == "Cephalonia" ? "Κεφαλονιά" : "Cephalonia"
            let event = Self.groundingEvent("\(literal) wedding")
            let now = Date.now.addingTimeInterval(15_724_800)
            let first = await groundingScan(enricher, [event], now: now,
                resolve: { _, _, _ in Issue.record("Nonliteral output reached the resolver"); return .rejected },
                judge: { _ in Self.groundingVerdict(invalid) })
            #expect(first.detections.isEmpty)
            #expect(first.deferredGroundingSnapshots.count == 1)
            // A new actor proves the cooldown survives cache hydration.
            let reloaded = CalendarEnricher(modelContainer: container)
            let deferred = await groundingScan(reloaded, [event], now: now.addingTimeInterval(1),
                judge: { _ in Issue.record("Invalid extraction repeated inside cooldown"); return nil })
            #expect(deferred.detections.isEmpty)
            #expect(deferred.deferredGroundingSnapshots.count == 1)
            let next = await groundingScan(reloaded, [event],
                now: now.addingTimeInterval(CalendarEnricher.invalidJudgmentRetryInterval),
                cache: { _ in .resolved(Self.groundingPlace) },
                judge: { _ in Self.groundingVerdict(literal) })
            #expect(next.detections.count == 1)
        }
    }

    @Test func unavailableJudgmentIsNotCachedAsInvalidOrFalse() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.clearFMJudgmentCache()
        let event = Self.groundingEvent("Cephalonia wedding")
        let first = await groundingScan(enricher, [event], judge: { _ in nil })
        #expect(first.deferredGroundingSnapshots.count == 1)
        let next = await groundingScan(enricher, [event], cache: { _ in .resolved(Self.groundingPlace) },
            judge: { _ in Self.groundingVerdict("Cephalonia") })
        #expect(next.detections.count == 1)
    }

    @Test func positiveLiteralWithRejectedGeographyNeverCreatesCard() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.clearFMJudgmentCache()
        let event = Self.groundingEvent("Cephalonia wedding")
        let calls = GroundingCalls()
        for _ in 0..<2 {
            let result = await groundingScan(enricher, [event], resolve: { text, _, cacheRejections in
                #expect(text == "Cephalonia")
                #expect(!cacheRejections)
                await calls.resolved(text)
                return .rejected
            }, judge: { _ in await calls.judged(); return Self.groundingVerdict("Cephalonia") })
            #expect(result.detections.isEmpty)
            #expect(result.deferredGroundingSnapshots.isEmpty)
            #expect(result.rejectedGeocodes == [event])
            await reconcileGrounding(result, with: enricher)
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PlannedTrip>()) == 0)
        #expect(await calls.judgments == 1)
        #expect(await calls.resolutions.count == 2)
    }

    @Test func zeroQuotasStillAllowBothCacheHitsAndNegativeVerdicts() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.clearFMJudgmentCache()
        let positive = Self.groundingEvent("Cephalonia wedding", id: "positive")
        let negative = Self.groundingEvent("Florence wedding", id: "negative")
        let calls = GroundingCalls()
        _ = await groundingScan(enricher, [positive, negative], resolutionBudget: 0,
            judge: { event in
                await calls.judged()
                return Self.groundingVerdict(event.externalIdentifier == "negative" ? "" : "Cephalonia",
                                            isTrip: event.externalIdentifier != "negative")
            })
        #expect(await calls.judgments == 2)
        let cached = await groundingScan(enricher, [positive, negative], resolutionBudget: 0, judgmentBudget: 0, allowFM: false,
            cache: { _ in .resolved(Self.groundingPlace) },
            resolve: { _, _, _ in Issue.record("Spent resolution work beyond quota"); return .unavailable },
            judge: { _ in Issue.record("Spent FM work beyond quota"); return nil })
        #expect(cached.detections.map(\.snapshot.externalIdentifier) == [positive.externalIdentifier])
        #expect(cached.deferredGroundingSnapshots.isEmpty)
    }

    @Test func unavailableDetectionsCannotStarveLaterDetectionOrExactFMGrounding() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.clearFMJudgmentCache()
        let early = (0..<25).map {
            Self.groundingEvent("Trip to Unavailable \($0)", location: "Unavailable \($0)", id: "early-\($0)")
        }
        let late = Self.groundingEvent("Trip to Florence", location: "Florence", id: "late")
        let ambiguous = Self.groundingEvent("Cephalonia wedding", id: "ambiguous")
        let events = early + [late, ambiguous]
        let deterministic = PlannedTripDetector.detect(in: events)
        #expect(deterministic.map(\.snapshot.externalIdentifier) == (early + [late]).map(\.externalIdentifier))
        let calls = GroundingCalls()

        for pass in 0..<2 {
            let before = await calls.resolutions.count
            let analysis = await groundingScan(enricher, events, resolve: { text, _, cacheRejections in
                await calls.resolved(text)
                if text == "Cephalonia" { #expect(!cacheRejections) }
                return text.hasPrefix("Unavailable") ? .unavailable : .resolved(Self.groundingPlace)
            }, judge: { event in
                #expect(event.externalIdentifier == "ambiguous")
                await calls.judged()
                return Self.groundingVerdict("Cephalonia")
            })
            let requests = Array((await calls.resolutions).dropFirst(before))
            #expect(requests.count == 25)
            if pass == 0 {
                #expect(requests == early.map { $0.locationText! })
                #expect(analysis.detections.allSatisfy { $0.resolved == nil })
                #expect(analysis.deferredGroundingSnapshots == [ambiguous])
            } else {
                #expect(requests.prefix(2) == ["Florence", "Cephalonia"])
                #expect(analysis.detections.map(\.snapshot.externalIdentifier) == events.map(\.externalIdentifier))
                #expect(analysis.detections.suffix(2).allSatisfy { $0.resolved != nil })
                #expect(analysis.deferredGroundingSnapshots.isEmpty)
            }
        }
        // A judgment obtained after the first scan's resolution quota ran out
        // must be reused when its exact destination finally gets a turn.
        #expect(await calls.judgments == 1)
    }

    @Test func combinedSchedulingServicesBothQuotasAcrossRepeatedUncachedFailures() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.clearFMJudgmentCache()
        let detected = (0..<4).map {
            Self.groundingEvent("Trip to Unavailable \($0)", location: "Unavailable \($0)", id: "detected-\($0)")
        }
        let ambiguous = (0..<3).map { Self.groundingEvent("Cephalonia wedding", id: "ambiguous-\($0)") }
        let calls = GroundingCalls()
        let judgments = GroundingCalls()
        for _ in 0..<6 {
            let resolutionCount = await calls.resolutions.count
            let judgmentCount = await judgments.resolutions.count
            _ = await groundingScan(enricher, detected + ambiguous, resolutionBudget: 2, judgmentBudget: 1,
                resolve: { text, _, _ in await calls.resolved(text); return .unavailable },
                judge: { event in await judgments.resolved(event.localIdentifier); return nil })
            #expect(await calls.resolutions.count - resolutionCount == 2)
            #expect(await judgments.resolutions.count - judgmentCount == 1)
        }
        #expect(Set(await calls.resolutions) == Set(detected.compactMap(\.locationText)))
        #expect(Set(await judgments.resolutions) == Set(ambiguous.map(\.localIdentifier)))
    }

    @Test func rotatingCursorPreventsBothUncachedFailureKindsFromStarvingLaterEvents() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let events = [Self.groundingEvent("Cephalonia wedding", id: "first"), Self.groundingEvent("Florence wedding", id: "second")]
        for invalidExtraction in [true, false] {
            await enricher.clearFMJudgmentCache()
            if !invalidExtraction {
                for event in events {
                    await enricher.seedJudgmentCacheForTesting(key: CalendarEnricher.judgmentCacheKey(for: event),
                        isTrip: true, eventEndDate: event.endDate, destination: event.title.components(separatedBy: " ")[0])
                }
            }
            for pass in 0..<2 {
                let result = await groundingScan(enricher, events, resolutionBudget: 1, judgmentBudget: 1,
                    resolve: { text, _, _ in text == "Florence" ? .resolved(Self.groundingPlace) : .rejected },
                    judge: { event in Self.groundingVerdict(event.externalIdentifier == "first" ? "" : "Florence") })
                if pass == 0 { #expect(result.detections.isEmpty) }
                else { #expect(result.detections.first?.snapshot.externalIdentifier == "second") }
            }
        }
    }

    @Test func broadFlorenceRejectionCannotEraseDeferredExactGeographyOrForecast() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.clearFMJudgmentCache()
        let event = Self.groundingEvent("Florence wedding", location: "Florence reception details")
        let earlier = Date.now.addingTimeInterval(15_724_800).addingTimeInterval(-4 * 86_400)
        let seed = PlannedTripDetection(snapshot: event, confidence: .medium,
            signals: [PlannedTripDetector.signalFMTieBreaker],
            resolved: ResolvedPlannedPlace(place: Self.groundingPlace, distanceFromHomeKm: nil))
        await enricher.applyScan(detections: [seed], now: earlier)
        let context = ModelContext(container)
        let row = try #require(try context.fetch(FetchDescriptor<PlannedTrip>()).first)
        row.forecastWeatherData = Data([1, 2, 3])
        try context.save()
        let analysis = await groundingScan(enricher, [event], resolve: { text, _, cacheMisses in
            if cacheMisses { #expect(text == event.locationText); return .rejected }
            #expect(text == "Florence")
            return .unavailable
        }, judge: { _ in Self.groundingVerdict("Florence") })
        #expect(analysis.detections.isEmpty)
        #expect(analysis.rejectedGeocodes.count == 1)
        await reconcileGrounding(analysis, with: enricher)
        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(saved.resolvedLatitude == Self.groundingPlace.latitude)
        #expect(saved.forecastWeatherData == Data([1, 2, 3]))
        #expect(saved.lastSeenAt > earlier)
        // A measured rejection of the exact phrase is different from an outage.
        let rejection = await groundingScan(enricher, [event], resolve: { _, _, _ in .rejected })
        #expect(rejection.deferredGroundingSnapshots.isEmpty)
        await reconcileGrounding(rejection, with: enricher, now: .now.addingTimeInterval(15_724_800).addingTimeInterval(4 * 86_400))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PlannedTrip>()) == 0)
    }

    @Test func unknownDoesNotPreserveUngroundedChangedOrTruncatedCards() async throws {
        for variant in ["ungrounded", "changed", "truncated", "relocated", "retimed"] {
            let container = try TestSupport.makeInMemoryContainer()
            let enricher = CalendarEnricher(modelContainer: container)
            await enricher.clearFMJudgmentCache()
            let title = variant == "truncated" ? String(repeating: "Cephalonia ", count: 40) : "Cephalonia wedding"
            let event = Self.groundingEvent(title)
            await enricher.applyScan(detections: [.init(snapshot: event, confidence: .medium,
                signals: [PlannedTripDetector.signalFMTieBreaker], resolved: variant == "ungrounded" ? nil
                    : ResolvedPlannedPlace(place: Self.groundingPlace, distanceFromHomeKm: nil))],
                now: .now.addingTimeInterval(15_724_800).addingTimeInterval(-4 * 86_400))
            if ["changed", "relocated", "retimed"].contains(variant) {
                let context = ModelContext(container)
                let row = try #require(try context.fetch(FetchDescriptor<PlannedTrip>()).first)
                if variant == "changed" { row.title = "Florence wedding" }
                if variant == "relocated" { row.locationText = "Florence" }
                if variant == "retimed" { row.endDate = row.endDate.addingTimeInterval(3600) }
                try context.save()
            }
            let analysis = await groundingScan(enricher, [event], resolutionBudget: 0, judgmentBudget: 0)
            await reconcileGrounding(analysis, with: enricher)
            #expect(try ModelContext(container).fetchCount(FetchDescriptor<PlannedTrip>()) == 0)
        }
    }

    @Test(arguments: [false, true], ["both", "title", "location", "unchanged", "truncated"])
    func unresolvedDestinationEditsClearGeographyAndRetry(unavailable: Bool, edit: String) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let now = Date(timeIntervalSince1970: 1_835_724_800)
        let start = now.addingTimeInterval(5 * 86_400)
        let earlier = now.addingTimeInterval(-4 * 86_400)
        let oldTitle = edit == "truncated" ? "Trip to Rome " + String(repeating: "x", count: 200) : "Trip to Rome"
        let title = ["both", "title"].contains(edit) ? "Trip to Tokyo" : oldTitle
        let location = ["both", "location"].contains(edit) ? "Tokyo" : "Rome"
        let event = Self.groundingEvent(title, location: location, id: "edited", start: start)
        let blocker = Self.groundingEvent("Trip to Athens", location: "Athens", id: "blocker", start: start)
        let seedContext = ModelContext(container)
        let row = PlannedTrip(eventExternalIdentifier: event.externalIdentifier,
            eventLocalIdentifier: event.localIdentifier, title: String(oldTitle.prefix(200)),
            startDate: start, endDate: event.endDate, isAllDay: false, locationText: "Rome")
        row.resolvedLatitude = 41.89
        row.resolvedLongitude = 12.51
        row.resolvedLocality = "Rome"
        row.resolvedCountry = "Italy"
        row.resolvedISOCountryCode = "IT"
        row.distanceFromHomeKm = 1052
        row.forecastWeatherData = Data([1, 2, 3])
        row.lastSeenAt = earlier
        let status: PlannedTripStatus = edit == "location" ? .dismissed : .upcoming
        row.status = status
        seedContext.insert(row)
        try seedContext.save()
        let rowID = row.id
        let enricher = CalendarEnricher(modelContainer: container)
        let calls = GroundingCalls()
        let snapshots = [blocker, event]
        let first = await groundingScan(enricher, snapshots,
            resolutionBudget: unavailable ? 2 : 1, allowFM: false, now: now,
            resolve: { text, _, _ in
                await calls.resolved(text)
                return .unavailable
            })
        #expect(await calls.resolutions == (unavailable ? ["Athens", location] : ["Athens"]))
        let unresolved = try #require(first.detections.first { $0.snapshot.localIdentifier == "edited" })
        #expect(unresolved.resolved == nil)
        #expect(unresolved.geocodeDisposition == .notAttempted)
        await PipelineGate.shared.run(touching: [.plannedTrip]) {
            await enricher.applyScan(detections: first.detections, now: now)
        }
        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<PlannedTrip>()).first { $0.id == rowID })
        #expect(saved.title == String(title.prefix(200)))
        #expect(saved.locationText == location)
        #expect(saved.status == status)
        #expect(saved.lastSeenAt == now)
        let preserve = edit == "unchanged"
        #expect(saved.resolvedLatitude == (preserve ? 41.89 : nil))
        #expect(saved.resolvedLongitude == (preserve ? 12.51 : nil))
        #expect(saved.resolvedLocality == (preserve ? "Rome" : nil))
        #expect(saved.resolvedCountry == (preserve ? "Italy" : nil))
        #expect(saved.resolvedISOCountryCode == (preserve ? "IT" : nil))
        #expect(saved.distanceFromHomeKm == (preserve ? 1052 : nil))
        #expect(saved.forecastWeatherData == (preserve ? Data([1, 2, 3]) : nil))

        let destination = ForwardGeocodedPlace(latitude: 35.68, longitude: 139.69,
            locality: "Tokyo", country: "Japan", isoCountryCode: "JP")
        let retryCalls = GroundingCalls()
        let retry = await groundingScan(enricher, snapshots,
            resolutionBudget: unavailable ? 2 : 1, allowFM: false, now: now.addingTimeInterval(1),
            resolve: { text, _, _ in
                await retryCalls.resolved(text)
                return .resolved(destination)
            })
        // An enabled exhausted quota resumes at the denied event next time.
        #expect(await retryCalls.resolutions == (unavailable ? ["Athens", location] : [location]))
        let resolved = try #require(retry.detections.first { $0.snapshot.localIdentifier == "edited" })
        #expect(resolved.geocodeDisposition == .accepted)
        #expect(resolved.resolved?.place == destination)
        await PipelineGate.shared.run(touching: [.plannedTrip]) {
            await enricher.applyScan(detections: retry.detections, now: now.addingTimeInterval(1))
        }
        let recovered = try #require(try ModelContext(container).fetch(FetchDescriptor<PlannedTrip>()).first { $0.id == rowID })
        #expect(recovered.resolvedLatitude == destination.latitude)
        #expect(recovered.resolvedLongitude == destination.longitude)
        #expect(recovered.resolvedLocality == destination.locality)
        #expect(recovered.resolvedCountry == destination.country)
        #expect(recovered.resolvedISOCountryCode == destination.isoCountryCode)
        #expect(recovered.distanceFromHomeKm == nil) // No home in this fixture.
        #expect(recovered.forecastWeatherData == nil)
        #expect(recovered.status == status)
    }

    @Test func acceptedNewCoordinatesDiscardPreviousDestinationForecast() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let event = Self.groundingEvent("Cephalonia wedding")
        let old = Self.groundingPlace
        await enricher.applyScan(detections: [.init(snapshot: event, confidence: .medium,
            signals: [PlannedTripDetector.signalFMTieBreaker], resolved: .init(place: old, distanceFromHomeKm: nil))], now: .now.addingTimeInterval(15_724_800))
        let context = ModelContext(container)
        let row = try #require(try context.fetch(FetchDescriptor<PlannedTrip>()).first)
        row.forecastWeatherData = Data([1, 2, 3])
        try context.save()
        let moved = ForwardGeocodedPlace(latitude: 43.77, longitude: 11.25, locality: "Florence", country: "Italy", isoCountryCode: "IT")
        await enricher.applyScan(detections: [.init(snapshot: event, confidence: .medium,
            signals: [PlannedTripDetector.signalFMTieBreaker], resolved: .init(place: moved, distanceFromHomeKm: nil))], now: .now.addingTimeInterval(15_724_800))
        let saved = try #require(try ModelContext(container).fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(saved.resolvedLocality == "Florence")
        #expect(saved.forecastWeatherData == nil)
    }

    @Test func suspendedJudgmentCannotStartResolutionOrRepopulateCachesAfterWipe() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.clearFMJudgmentCache()
        IsolatedCalendarDefaults.current.set(Data("old private event".utf8), forKey: CalendarEnricher.legacyFMJudgmentCacheKey)
        IsolatedCalendarDefaults.current.set(Data("v2 private event".utf8), forKey: CalendarEnricher.plaintextFMJudgmentCacheKey)
        let event = Self.groundingEvent("Cephalonia wedding")
        let result = await groundingScan(enricher, [event], resolve: { _, _, _ in
            Issue.record("A pre-wipe judgment launched a resolver after the wipe")
            return .resolved(Self.groundingPlace)
        }, judge: { _ in
            let deletion = await enricher.deleteAllCalendarData()
            #expect(deletion.succeeded)
            return Self.groundingVerdict("Cephalonia")
        })
        #expect(result.detections.isEmpty)
        #expect(IsolatedCalendarDefaults.current.data(forKey: CalendarEnricher.fmJudgmentCacheKey) == nil)
        #expect(IsolatedCalendarDefaults.current.data(forKey: CalendarEnricher.legacyFMJudgmentCacheKey) == nil)
        #expect(IsolatedCalendarDefaults.current.data(forKey: CalendarEnricher.plaintextFMJudgmentCacheKey) == nil)
    }

    @Test func lazyJudgmentCacheUpgradeRemovesOldEventPII() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        IsolatedCalendarDefaults.current.removeObject(forKey: CalendarEnricher.fmJudgmentCacheKey)
        IsolatedCalendarDefaults.current.set(Data("old private event".utf8), forKey: CalendarEnricher.legacyFMJudgmentCacheKey)
        IsolatedCalendarDefaults.current.set(Data("v2 private event".utf8), forKey: CalendarEnricher.plaintextFMJudgmentCacheKey)
        _ = await groundingScan(enricher, [], resolutionBudget: 0, judgmentBudget: 0)
        #expect(IsolatedCalendarDefaults.current.data(forKey: CalendarEnricher.legacyFMJudgmentCacheKey) == nil)
        #expect(IsolatedCalendarDefaults.current.data(forKey: CalendarEnricher.plaintextFMJudgmentCacheKey) == nil)
    }

    @Test func judgmentKeysHashUnambiguousFieldsAndPersistOnlyDerivedPlace() async throws {
        let start = Date.now.addingTimeInterval(15_724_800).addingTimeInterval(60 * 86_400)
        let a = Self.groundingEvent("Cephalonia wedding|SECRET_GUEST", location: "PRIVATE_VENUE", start: start)
        let b = Self.groundingEvent("Cephalonia wedding", location: "SECRET_GUEST|PRIVATE_VENUE", start: start)
        let key = CalendarEnricher.judgmentCacheKey(for: a)
        #expect(key == CalendarEnricher.judgmentCacheKey(for: a))
        #expect(key.count == 64)
        #expect(key != CalendarEnricher.judgmentCacheKey(for: b))
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.clearFMJudgmentCache()
        _ = await groundingScan(enricher, [a], resolutionBudget: 0,
            judge: { _ in Self.groundingVerdict("Cephalonia") })
        let data = try #require(IsolatedCalendarDefaults.current.data(forKey: CalendarEnricher.fmJudgmentCacheKey))
        let stored = String(decoding: data, as: UTF8.self)
        #expect(stored.contains(key))
        #expect(stored.contains("Cephalonia")) // Derived destination is still calendar data.
        #expect(!stored.contains("SECRET_GUEST"))
        #expect(!stored.contains("PRIVATE_VENUE"))
        #expect(!stored.contains("wedding"))
    }
    @Test func positiveOnlyGeocoderDoesNotCachePreflightRejectionsOrOfflineMisses() async {
        let geocoder = ForwardGeocoder.shared
        await geocoder.clearCache()
        let generic = "Conference Room 4b"
        #expect(await geocoder.resolveOutcome(generic, allowNetwork: false, cacheRejections: false) == .rejected)
        #expect(await geocoder.cachedResolution(for: generic) == .miss)
        // The ordinary location lane retains its existing negative-cache policy.
        #expect(await geocoder.resolveOutcome(generic, allowNetwork: false) == .rejected)
        #expect(await geocoder.cachedResolution(for: generic) == .unresolved)
        let missing = "UnlistedGroundingFixturePlace"
        #expect(await geocoder.resolveOutcome(missing, allowNetwork: false, cacheRejections: false) == .unavailable)
        #expect(await geocoder.cachedResolution(for: missing) == .miss)
    }

    @Test func wipeDuringCacheLookupPreventsTheNextResolver() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        await enricher.clearFMJudgmentCache()
        let event = Self.groundingEvent("Cephalonia wedding")
        let analysis = await groundingScan(enricher, [event], cache: { _ in
            let result = await enricher.deleteAllCalendarData()
            #expect(result.succeeded)
            return .miss
        }, resolve: { _, _, _ in
            Issue.record("A cache lookup completed after wipe and started a new resolver")
            return .unavailable
        }, judge: { _ in Self.groundingVerdict("Cephalonia") })
        #expect(analysis.detections.isEmpty)
        #expect(IsolatedCalendarDefaults.current.data(forKey: CalendarEnricher.fmJudgmentCacheKey) == nil)
    }

    @Test func allDayDeferredPreservationUsesRenderedDaysAndDoesNotResurrectDismissals() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let enricher = CalendarEnricher(modelContainer: container)
        let start = Calendar.current.startOfDay(for: .now.addingTimeInterval(15_724_800).addingTimeInterval(60 * 86_400))
        let event = CalendarEventSnapshot(externalIdentifier: "floating", localIdentifier: "floating", title: "Cephalonia wedding",
            notes: nil, locationText: nil, startDate: start, endDate: start.addingTimeInterval(48 * 3600),
            isAllDay: true, hasRecurrenceRules: false, isDetached: false, calendarTitle: "Test", calendarKind: .icloud)
        await enricher.applyScan(detections: [.init(snapshot: event, confidence: .medium,
            signals: [PlannedTripDetector.signalFMTieBreaker], resolved: .init(place: Self.groundingPlace, distanceFromHomeKm: nil))],
            now: .now.addingTimeInterval(15_724_800).addingTimeInterval(-4 * 86_400))
        let context = ModelContext(container)
        let row = try #require(try context.fetch(FetchDescriptor<PlannedTrip>()).first)
        // Different instants still rendering on the same calendar days.
        row.startDate = start.addingTimeInterval(3600)
        row.endDate = event.endDate.addingTimeInterval(3600)
        try context.save()
        await enricher.applyScan(detections: [], deferredGroundingSnapshots: [event], now: .now.addingTimeInterval(15_724_800))
        let verify = ModelContext(container)
        let saved = try #require(try verify.fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(saved.startDate == start.addingTimeInterval(3600))
        saved.status = .dismissed
        let previousSeen = saved.lastSeenAt
        try verify.save()
        await enricher.applyScan(detections: [], deferredGroundingSnapshots: [event], now: .now.addingTimeInterval(15_724_800).addingTimeInterval(4 * 86_400))
        let terminal = try #require(try ModelContext(container).fetch(FetchDescriptor<PlannedTrip>()).first)
        #expect(terminal.status == .dismissed)
        #expect(terminal.lastSeenAt == previousSeen)
    }

}
