import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
struct WrappedTravelDaysTests {
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        TravelDays.labelCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @Test("calendar title revocation scrubs every saved recap without changing historical totals")
    func calendarWipeScrubsSavedRecaps() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let sentinel = "PRIVATE_CALENDAR_OCCASION"
        let trip = Trip(startDate: date(2025, 2, 1))
        trip.aiGeneratedTitle = sentinel
        trip.destinationSummary = "Lisbon"
        context.insert(trip)
        let custom = Trip(startDate: date(2025, 5, 1))
        custom.id = trip.id // CloudKit UUID twins must remain distinct physical rows.
        custom.customName = "Our special holiday"
        custom.aiGeneratedTitle = sentinel + "_CUSTOM"
        context.insert(custom)
        var snapshot = WrappedStats()
        snapshot.daysAbroad = 91
        snapshot.totalDaysAbroad = 91
        snapshot.daysAtHome = 274
        snapshot.countriesVisited = 7
        snapshot.tripsCompleted = 9
        snapshot.longestTripName = sentinel
        snapshot.longestTripDays = 12
        snapshot.rainiestTripName = sentinel
        snapshot.mysteryFact = .shortestTrip(name: sentinel, days: 2)
        snapshot.mysteryFactText = "Two days at \(sentinel)"
        snapshot.narrativeInputs = NarrativeInputs(
            year: 2025, tripDisplayNames: [sentinel, custom.customName!],
            tripStartDates: [trip.startDate, custom.startDate], longestTripName: sentinel,
            longestTripDays: 12, farthestPlaceName: "Tokyo", farthestDistanceKm: 9000,
            firstTimeCountryISOCodes: ["JP"])
        let row = YearWrapped(year: 2025)
        row.statsData = snapshot.encoded()
        row.yearNarrative = "Legacy FM prose mentioning \(sentinel)"
        row.yearNarrativeSourceRaw = "foundationModels"
        context.insert(row)
        let legacy = YearWrapped(year: 2025)
        legacy.id = row.id // Scrub every physical recap, even UUID twins.
        snapshot.narrativeInputs = nil
        snapshot.longestTripName = custom.customName
        snapshot.rainiestTripName = custom.aiGeneratedTitle
        legacy.statsData = snapshot.encoded()
        legacy.yearNarrative = row.yearNarrative
        context.insert(legacy)
        try context.save()
        let generatedAt = row.generatedAt

        let enricher = CalendarEnricher(modelContainer: container)
        let deleted = await PipelineGate.shared.runReturning(touching: [.plannedTrip]) {
            await enricher.deleteAllCalendarData()
        }
        #expect(deleted.succeeded)
        // The production clear transaction is also used by Settings and launch recovery.
        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.clearCalendarTitlesForTesting())
        let rows = try ModelContext(container).fetch(FetchDescriptor<YearWrapped>())
        #expect(rows.count == 2)
        for saved in rows {
            let data = try #require(saved.statsData)
            #expect(!String(decoding: data, as: UTF8.self).contains(sentinel))
            #expect(saved.yearNarrative == nil)
            let stats = try #require(WrappedStats.decoded(from: data))
            #expect(stats.daysAbroad == 91)
            #expect(stats.totalDaysAbroad == 91)
            #expect(stats.daysAtHome == 274)
            #expect(stats.countriesVisited == 7)
            #expect(stats.tripsCompleted == 9)
            #expect(stats.longestTripDays == 12)
            #expect(stats.mysteryFact == .shortestTrip(name: "Lisbon", days: 2))
            #expect(stats.mysteryFactText == nil)
            let narrative = WrappedDisplayResolver.resolvedNarrative(
                storedProse: saved.yearNarrative, stats: stats, locale: Locale(identifier: "en"))
            #expect(!(narrative ?? "").contains(sentinel))
            if let inputs = stats.narrativeInputs {
                #expect(saved.generatedAt == generatedAt)
                #expect(stats.longestTripName == "Lisbon")
                #expect(stats.rainiestTripName == "Lisbon")
                #expect(inputs.tripDisplayNames == ["Lisbon", "Our special holiday"])
                #expect(inputs.longestTripName == "Lisbon")
                #expect(inputs.tripStartDates == [trip.startDate, custom.startDate])
                #expect(try #require(narrative).contains("Our special holiday"))
            } else {
                #expect(stats.longestTripName == "Our special holiday")
                #expect(stats.rainiestTripName == "Our special holiday")
                #expect(narrative == nil)
            }
        }
    }

    @Test("an unreadable recap is deleted so calendar title revocation can finish")
    func calendarWipeDeletesUnreadableRecap() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: date(2025, 2, 1))
        trip.aiGeneratedTitle = "Legacy calendar title"
        context.insert(trip)
        let row = YearWrapped(year: 2025)
        row.statsData = Data("unreadable historical blob".utf8)
        row.yearNarrative = "Legacy prose"
        context.insert(row)
        var readable = WrappedStats()
        readable.countriesVisited = 4
        let kept = YearWrapped(year: 2024)
        kept.statsData = readable.encoded()
        context.insert(kept)
        try context.save()
        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.clearCalendarTitlesForTesting())
        let verify = ModelContext(container)
        #expect(try verify.fetch(FetchDescriptor<Trip>()).first?.aiGeneratedTitle == nil)
        let saved = try verify.fetch(FetchDescriptor<YearWrapped>())
        #expect(saved.map(\.year) == [2024])
        #expect(saved.first?.statsData.flatMap(WrappedStats.decoded(from:))?.countriesVisited == 4)
    }

    @Test("a recap card written by a newer build is dropped while the readable totals are scrubbed and kept")
    func calendarWipeSalvagesNewerBuildRecap() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let sentinel = "PRIVATE_CALENDAR_OCCASION"
        let trip = Trip(startDate: date(2025, 2, 1))
        trip.aiGeneratedTitle = sentinel
        trip.destinationSummary = "Lisbon"
        context.insert(trip)
        var snapshot = WrappedStats()
        snapshot.countriesVisited = 7
        snapshot.daysAbroad = 91
        snapshot.longestTripName = sentinel
        let readable = try #require(snapshot.encoded())
        var object = try #require(try JSONSerialization.jsonObject(with: readable) as? [String: Any])
        object["mysteryFact"] = ["favouriteTrip": ["name": sentinel]]
        let row = YearWrapped(year: 2025)
        row.statsData = try JSONSerialization.data(withJSONObject: object)
        context.insert(row)
        try context.save()
        let classifier = TripClassifier(modelContainer: container)
        #expect(await classifier.clearCalendarTitlesForTesting())
        let saved = try #require(ModelContext(container).fetch(FetchDescriptor<YearWrapped>()).first)
        let data = try #require(saved.statsData)
        #expect(!String(decoding: data, as: UTF8.self).contains(sentinel))
        let stats = try #require(WrappedStats.decoded(from: data))
        #expect(stats.countriesVisited == 7)
        #expect(stats.daysAbroad == 91)
        #expect(stats.longestTripName == "Lisbon")
        #expect(stats.mysteryFact == nil)
    }

    @Test("a historical recap retains its saved counts and prose even when current travel dates differ")
    func savedRecapRetainsGenerationSemantics() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: date(2024, 12, 30))
        trip.endDate = date(2025, 1, 3)
        trip.isComplete = true
        context.insert(trip)
        var original = WrappedStats()
        original.daysAbroad = 91
        original.totalDaysAbroad = 91
        original.daysAtHome = 274
        original.countriesVisited = 7
        let row = YearWrapped(year: 2025)
        row.statsData = original.encoded()
        row.yearNarrative = "Old prose said 91 days away."
        context.insert(row)
        try context.save()
        let originalBlob = row.statsData
        let originalGeneration = row.generatedAt
        let presented = WrappedViewData(wrapped: row)
        let blob = try #require(presented.statsData)
        let stats = try #require(WrappedStats.decoded(from: blob))
        #expect(try TravelDays.count(inYear: 2025, container: container, now: date(2025, 2, 1),
                                    fallbackZone: TimeZone(secondsFromGMT: 0)!) == 3)
        #expect(stats.daysAbroad == 91)
        #expect(stats.totalDaysAbroad == 91)
        #expect(stats.daysAtHome == 274)
        #expect(stats.countriesVisited == 7)
        #expect(WrappedDisplayResolver.resolvedNarrative(
            storedProse: presented.yearNarrative, stats: stats,
            locale: Locale(identifier: "en")) == "Old prose said 91 days away.")
        let reread = try #require(ModelContext(container).fetch(FetchDescriptor<YearWrapped>()).first)
        #expect(reread.statsData == originalBlob)
        #expect(reread.generatedAt == originalGeneration)
    }

    @Test("structured narrative uses the historical snapshot's counts and full-year denominator")
    func structuredNarrativeUsesSavedCounts() throws {
        var snapshot = WrappedStats()
        snapshot.daysAbroad = 40
        snapshot.totalDaysAbroad = 40
        snapshot.daysAtHome = 326
        snapshot.narrativeInputs = NarrativeInputs(
            year: 2024, tripDisplayNames: [], tripStartDates: [], longestTripName: nil,
            longestTripDays: nil, farthestPlaceName: nil, farthestDistanceKm: nil,
            firstTimeCountryISOCodes: [])
        let text = try #require(WrappedDisplayResolver.resolvedNarrative(
            storedProse: "Old paragraph", stats: snapshot, locale: Locale(identifier: "en")))
        #expect(text.contains("40 days abroad"))
        #expect(text.contains("326"))
    }

    @Test("share payload uses the same historical away count and wording as its cards")
    func sharePayloadUsesSavedCounts() {
        var snapshot = WrappedStats()
        snapshot.totalDaysAbroad = 91
        snapshot.daysAbroad = 91
        snapshot.countriesVisited = 3
        // A legacy blob (no trip-span flag) keeps "abroad" on the poster.
        let legacy = WrappedShare(year: 2025, stats: snapshot, appLocaleIdentifier: "en")
        #expect(legacy.content.rows.contains(.init(value: "91", label: "days abroad")))
        #expect(legacy.content.yearLines == ["20", "25"])
        snapshot.usesTripSpanDays = true
        let current = WrappedShare(year: 2025, stats: snapshot, appLocaleIdentifier: "en")
        #expect(current.content.rows.contains(.init(value: "91", label: "days away")))
        #expect(WrappedUnits(locale: Locale(identifier: "en"), stats: snapshot).daysAway(91) == "days away")
        #expect(snapshot.daysAbroad == snapshot.totalDaysAbroad)
    }

    @Test("new trip-span snapshots say away while legacy JSON retains abroad wording")
    func tripSpanWordingAndLegacyDecode() throws {
        var snapshot = WrappedStats()
        snapshot.daysAbroad = 3
        snapshot.totalDaysAbroad = 3
        snapshot.daysAtHome = 362
        snapshot.narrativeInputs = NarrativeInputs(
            year: 2025, tripDisplayNames: [], tripStartDates: [], longestTripName: nil,
            longestTripDays: nil, farthestPlaceName: nil, farthestDistanceKm: nil,
            firstTimeCountryISOCodes: [])
        let legacyBlob = try #require(snapshot.encoded())
        #expect(!String(decoding: legacyBlob, as: UTF8.self).contains("usesTripSpanDays"))
        let legacy = try #require(WrappedStats.decoded(from: legacyBlob))
        #expect(legacy.usesTripSpanDays == nil)
        #expect(try #require(WrappedDisplayResolver.resolvedNarrative(
            storedProse: nil, stats: legacy, locale: Locale(identifier: "en")))
            .contains("3 days abroad"))

        snapshot.usesTripSpanDays = true
        let newBlob = try #require(snapshot.encoded())
        let restored = try #require(WrappedStats.decoded(from: newBlob))
        #expect(restored.usesTripSpanDays == true)
        let text = try #require(WrappedDisplayResolver.resolvedNarrative(
            storedProse: nil, stats: restored, locale: Locale(identifier: "en")))
        #expect(text.contains("3 days away"))
        #expect(!text.contains("abroad"))
        let greek = try #require(WrappedDisplayResolver.resolvedNarrative(
            storedProse: nil, stats: restored, locale: Locale(identifier: "el")))
        #expect(greek.contains("μακριά από το σπίτι"))
        #expect(!greek.contains("εξωτερικό"))
    }

    @Test("new domestic-trip recap persists trip-span semantics and says away")
    func generatedDomesticRecapUsesAwayWording() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: date(2025, 10, 19))
        trip.endDate = date(2025, 10, 21)
        trip.isComplete = true
        trip.countryCodes = "GR"
        context.insert(trip)
        let stay = Stay(startTime: trip.startDate, endTime: trip.endDate!,
                        centroidLatitude: 37.6839, centroidLongitude: 26.8173,
                        h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 274, pingIDs: [])
        stay.category = .destination
        stay.locality = "Pagóndas"
        stay.isoCountryCode = "GR"
        stay.timeZoneIdentifier = "Europe/Athens"
        context.insert(stay)
        stay.trip = trip
        let home = Stay(startTime: date(2025, 1, 1), endTime: date(2025, 1, 2),
                        centroidLatitude: 37.98, centroidLongitude: 23.73,
                        h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 0, pingIDs: [])
        home.category = .home
        home.isoCountryCode = "GR"
        context.insert(home)
        try context.save()
        let generator = YearWrappedGenerator(modelContainer: container)
        #expect(await generator.forceRegenerate(forYear: 2025))
        let row = try #require(ModelContext(container).fetch(FetchDescriptor<YearWrapped>()).first)
        let blob = try #require(row.statsData)
        let stats = try #require(WrappedStats.decoded(from: blob))
        #expect(stats.usesTripSpanDays == true)
        #expect(stats.daysAbroad == 3)
        #expect(try #require(row.yearNarrative).contains("3 days away"))
        #expect(try #require(WrappedDisplayResolver.resolvedNarrative(
            storedProse: row.yearNarrative, stats: stats, locale: Locale(identifier: "en")))
            .contains("3 days away"))
        #expect(stats.newCountryCodes.isEmpty)
    }

    @Test("first-time countries exclude home, transit and tripless stays", arguments: [false, true])
    func firstTimeCountriesUseTripDestinationsOnly(withPriorItaly: Bool) async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        func addStay(_ start: Date, _ category: StayCategory, _ iso: String, trip: Trip? = nil) {
            let stay = Stay(startTime: start, endTime: start.addingTimeInterval(3600 * 20),
                            centroidLatitude: 40, centroidLongitude: 20,
                            h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 500, pingIDs: [])
            stay.category = category
            stay.locality = iso
            stay.isoCountryCode = iso
            context.insert(stay)
            stay.trip = trip
        }
        let trip = Trip(startDate: date(2025, 6, 1))
        trip.endDate = date(2025, 6, 5)
        trip.isComplete = true
        trip.countryCodes = "IT,FR"
        context.insert(trip)
        addStay(date(2025, 1, 10), .home, "GR")
        addStay(date(2025, 6, 1), .transit, "QA", trip: trip)
        addStay(date(2025, 6, 2), .destination, "IT", trip: trip)
        addStay(date(2025, 6, 4), .destination, "FR", trip: trip)
        addStay(date(2025, 8, 1), .destination, "MK")
        if withPriorItaly { addStay(date(2024, 5, 1), .destination, "IT") }
        try context.save()
        let generator = YearWrappedGenerator(modelContainer: container)
        #expect(await generator.forceRegenerate(forYear: 2025))
        let row = try #require(ModelContext(container).fetch(FetchDescriptor<YearWrapped>())
            .first { $0.year == 2025 })
        let blob = try #require(row.statsData)
        let stats = try #require(WrappedStats.decoded(from: blob))
        let expected = withPriorItaly ? ["FR"] : ["FR", "IT"]
        #expect(stats.newCountryCodes == expected)
        #expect(stats.narrativeInputs?.firstTimeCountryISOCodes == expected)
        let narrative = try #require(row.yearNarrative)
        #expect(!narrative.contains("Greece"))
    }

    @Test("an earlier transit stop in a country does not keep a later first visit there from being a new stamp")
    func earlierTransitStopIsNoPriorVisit() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        func addStay(_ start: Date, _ category: StayCategory, _ iso: String, trip: Trip) {
            let stay = Stay(startTime: start, endTime: start.addingTimeInterval(3600 * 20),
                            centroidLatitude: 25.27, centroidLongitude: 51.6,
                            h3IndexRes6: "", pingCount: 1, distanceFromHomeKm: 3000, pingIDs: [])
            stay.category = category
            stay.locality = iso
            stay.isoCountryCode = iso
            context.insert(stay)
            stay.trip = trip
        }
        func addTrip(_ start: Date, _ end: Date, _ codes: String) -> Trip {
            let trip = Trip(startDate: start)
            trip.endDate = end
            trip.isComplete = true
            trip.countryCodes = codes
            context.insert(trip)
            return trip
        }
        // 2024: a layover in Qatar on the way to Thailand.
        let earlier = addTrip(date(2024, 3, 1), date(2024, 3, 9), "QA,TH")
        addStay(date(2024, 3, 1), .transit, "QA", trip: earlier)
        addStay(date(2024, 3, 2), .destination, "TH", trip: earlier)
        // 2025: a real visit to Qatar and a return to Thailand.
        let visit = addTrip(date(2025, 4, 1), date(2025, 4, 9), "QA,TH")
        addStay(date(2025, 4, 1), .destination, "QA", trip: visit)
        addStay(date(2025, 4, 5), .destination, "TH", trip: visit)
        try context.save()
        let generator = YearWrappedGenerator(modelContainer: container)
        #expect(await generator.forceRegenerate(forYear: 2025))
        let row = try #require(ModelContext(container).fetch(FetchDescriptor<YearWrapped>())
            .first { $0.year == 2025 })
        let stats = try #require(row.statsData.flatMap(WrappedStats.decoded(from:)))
        #expect(stats.newCountryCodes == ["QA"])
    }
}
