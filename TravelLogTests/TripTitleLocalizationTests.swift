//
//  TripTitleLocalizationTests.swift
//  TravelLogTests
//

import Foundation
import os
import SQLite3
import SwiftData
import Testing
@testable import TravelLog

@MainActor
@Suite("Localized trip titles", .serialized, IsolatedTitleDefaults())
struct TripTitleLocalizationTests {

    @Test("Malformed incoming title cannot replace a valid variant with newer metadata")
    func malformedIncomingListPreservesValidVariant() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        trip.aiGeneratedTitle = "Athens"
        #expect(TripTitleStore.upsertVariant(languageTag: "el", title: "Αθήνα", sourceTitle: "Athens",
                                           for: trip, in: context))
        try context.save()
        let original = try #require(TripTitleStore.preferredVariant(for: trip, languageTag: "el"))
        let identity = original.persistentModelID
        #expect(!TripTitleStore.upsertVariant(languageTag: "el", title: "Αθήνα &", sourceTitle: "Athens",
                                            generationVersion: 99, updatedAt: .distantFuture,
                                            for: trip, in: context))
        try context.save()
        let winner = try #require(TripTitleStore.preferredVariant(for: trip, languageTag: "el"))
        #expect(winner.persistentModelID == identity)
        #expect(winner.title == "Αθήνα")
    }

    @Test("Malformed saved list titles cannot block a valid repair even with future metadata")
    func malformedSavedListCanBeRepaired() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        trip.aiGeneratedTitle = "Athens"
        let source = try #require(trip.aiGeneratedTitle)
        let bad = TripTitleVariant(languageTag: "el", title: "Αθήνα και", sourceTitle: source, trip: trip)
        bad.sourceRevision = trip.titleSourceRevision
        bad.updatedAt = .distantFuture
        context.insert(bad)
        try context.save()
        #expect(TripTitleStore.localizedTitle(for: trip, languageTag: "el") == nil)
        #expect(TripTitleStore.upsertVariant(languageTag: "el", title: "Αθήνα", sourceTitle: source,
                                           for: trip, in: context))
        try context.save()
        #expect(TripTitleStore.localizedTitle(for: trip, languageTag: "el") == "Αθήνα")
    }

    @Test("detail localization task key follows canonical source and app language")
    func detailTaskKeyInvalidation() {
        let tripID = UUID()
        let revision = UUID()
        let baseline = TripTitleLocalizationTaskKey(
            tripID: tripID,
            canonicalTitle: "Cycladic Summer",
            sourceRevision: revision,
            languageTag: "de",
            hasCustomName: false)

        #expect(baseline == TripTitleLocalizationTaskKey(
            tripID: tripID,
            canonicalTitle: "Cycladic Summer",
            sourceRevision: revision,
            languageTag: "de",
            hasCustomName: false))
        #expect(baseline != TripTitleLocalizationTaskKey(
            tripID: tripID,
            canonicalTitle: "Aegean Summer",
            sourceRevision: revision,
            languageTag: "de",
            hasCustomName: false))
        #expect(baseline != TripTitleLocalizationTaskKey(
            tripID: tripID,
            canonicalTitle: "Cycladic Summer",
            sourceRevision: UUID(),
            languageTag: "de",
            hasCustomName: false))
        #expect(baseline != TripTitleLocalizationTaskKey(
            tripID: tripID,
            canonicalTitle: "Cycladic Summer",
            sourceRevision: revision,
            languageTag: "el",
            hasCustomName: false))
        #expect(baseline != TripTitleLocalizationTaskKey(
            tripID: tripID,
            canonicalTitle: "Cycladic Summer",
            sourceRevision: revision,
            languageTag: "de",
            hasCustomName: true))
    }

    private func makeTrip(
        in context: ModelContext,
        offset: TimeInterval = 0,
        title: String = "Cycladic Summer"
    ) throws -> Trip {
        let trip = Trip(startDate: Date(
            timeIntervalSinceReferenceDate: 810_886_400 + offset))
        trip.aiGeneratedTitle = title
        trip.destinationSummary = "Athens, Cephalonia"
        context.insert(trip)
        try context.save()
        return trip
    }

    @Test("current-language variant wins, then canonical English, while custom name remains verbatim")
    func resolutionPrecedence() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let german = TripTitleVariant(
            languageTag: "de",
            title: "Kykladischer Sommer",
            sourceTitle: "Cycladic Summer",
            trip: trip)
        context.insert(german)
        try context.save()

        #expect(trip.displayName(languageTag: "de") == "Kykladischer Sommer")
        #expect(trip.displayName(languageTag: "fr") == "Cycladic Summer")
        #expect(trip.displayName(languageTag: "en") == "Cycladic Summer")

        trip.customName = "Our Anniversary"
        #expect(trip.displayName(languageTag: "de") == "Our Anniversary")
    }

    @Test("stale-source variants are never displayed")
    func staleSourceIsIgnored() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        context.insert(TripTitleVariant(
            languageTag: "fr",
            title: "Ancien titre",
            sourceTitle: "Old English Title",
            trip: trip))
        try context.save()

        #expect(trip.displayName(languageTag: "fr") == "Cycladic Summer")
    }

    @Test("duplicate winner is generation, then update time, then stable UUID")
    func deterministicWinner() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let old = Date(timeIntervalSinceReferenceDate: 100)
        let new = Date(timeIntervalSinceReferenceDate: 200)
        let lowVersion = TripTitleVariant(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            languageTag: "de", title: "Version one",
            sourceTitle: "Cycladic Summer", generationVersion: 1,
            updatedAt: new, trip: trip)
        let highVersionOld = TripTitleVariant(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            languageTag: "de", title: "Version two old",
            sourceTitle: "Cycladic Summer", generationVersion: TripTitleStore.currentGenerationVersion,
            updatedAt: old, trip: trip)
        let highVersionNewLargeID = TripTitleVariant(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            languageTag: "de", title: "Larger ID",
            sourceTitle: "Cycladic Summer", generationVersion: TripTitleStore.currentGenerationVersion,
            updatedAt: new, trip: trip)
        let expected = TripTitleVariant(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            languageTag: "de", title: "Expected",
            sourceTitle: "Cycladic Summer", generationVersion: TripTitleStore.currentGenerationVersion,
            updatedAt: new, trip: trip)
        for row in [lowVersion, highVersionOld, highVersionNewLargeID, expected] {
            context.insert(row)
        }
        try context.save()

        #expect(TripTitleStore.preferredVariant(for: trip, languageTag: "de")?.id == expected.id)
        #expect(trip.displayName(languageTag: "de") == "Expected")
    }

    @Test("canonical mutation deletes every derivative, including equal-text invalidation")
    func invalidationIsSemantic() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        context.insert(TripTitleVariant(
            languageTag: "de", title: "Kykladischer Sommer",
            sourceTitle: "Cycladic Summer", trip: trip))
        try context.save()

        TripTitleStore.invalidateGeneratedTitles(for: trip, in: context)
        try context.save()

        #expect(trip.aiGeneratedTitle == nil)
        #expect(try context.fetchCount(FetchDescriptor<TripTitleVariant>()) == 0)
    }

    @Test("upsert requires current source and collapses local duplicates")
    func guardedUpsert() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTrip(in: context)
        let a = TripTitleVariant(
            languageTag: "fr", title: "Été A",
            sourceTitle: "Cycladic Summer", trip: trip)
        let b = TripTitleVariant(
            languageTag: "fr", title: "Été B",
            sourceTitle: "Cycladic Summer", trip: trip)
        context.insert(a)
        context.insert(b)
        try context.save()

        #expect(!TripTitleStore.upsertVariant(
            languageTag: "de", title: "Falsch", sourceTitle: "Wrong Source",
            for: trip, in: context))
        #expect(TripTitleStore.upsertVariant(
            languageTag: "fr", title: "Été cycladique",
            sourceTitle: "Cycladic Summer", for: trip, in: context))
        try context.save()

        let french = try context.fetch(FetchDescriptor<TripTitleVariant>()).filter {
            $0.languageTag == "fr" && $0.sourceTitle == "Cycladic Summer"
        }
        #expect(french.count == 1)
        #expect(french.first?.title == "Été cycladique")
    }

    @Test("explicit fallback language selects that catalog's connector")
    func explicitFallbackLocalization() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: .now)
        trip.destinationSummary = "Athens, Cephalonia"
        context.insert(trip)
        try context.save()

        #expect(trip.displayName(languageTag: "en") == "Athens & Cephalonia")
        #expect(trip.displayName(languageTag: "el") == "Athens και Cephalonia")
    }

    @Test("Spanish joins a last place starting with an /i/ sound with e")
    func spanishConnectorBeforeISound() {
        #expect(Trip.placeList(["Velmar", "Ilvar"], languageTag: "es") == "Velmar e Ilvar")
        #expect(Trip.placeList(["Roma", "Ibiza"], languageTag: "es") == "Roma e Ibiza")
        #expect(Trip.placeList(["Madrid", "Hierro"], languageTag: "es") == "Madrid y Hierro")
        #expect(Trip.placeList(["Vigo", "Hío"], languageTag: "es") == "Vigo e Hío")
        #expect(Trip.placeList(["Tokio", "Osaka", "Hiroshima"], languageTag: "es") == "Tokio, Osaka e Hiroshima")
        #expect(Trip.placeList(["Ilvar", "Velmar"], languageTag: "es") == "Ilvar y Velmar")
        #expect(Trip.placeList(["Velmar", "Ίλβαρ"], languageTag: "es") == "Velmar y Ίλβαρ")
        // Every other language keeps its own connector.
        for tag in AppLanguagePreference.supportedTags where tag != "es" {
            #expect(Trip.placeList(["Velmar", "Ilvar"], languageTag: tag)
                == Trip.placeList(["Velmar", "Dorna"], languageTag: tag).replacingOccurrences(of: "Dorna", with: "Ilvar"))
            #expect(Trip.placeList(["Tokio", "Osaka", "Ibiza"], languageTag: tag)
                == Trip.placeList(["Tokio", "Osaka", "Dorna"], languageTag: tag).replacingOccurrences(of: "Dorna", with: "Ibiza"))
        }
        #expect(Trip.placeList(["Velmar", "Ilvar"], languageTag: "en") == "Velmar & Ilvar")
    }

    // MARK: - Deterministic localization

    private static let start = Date(timeIntervalSinceReferenceDate: 826_611_200)

    /// One destination stay per `(locality, hours)` in an invented country,
    /// an hour apart, in visit order.
    private static func stayInputs(_ places: [(String, Double)]) -> [TripTitlePolicy.StayInput] {
        var cursor = start
        return places.enumerated().map { index, place in
            let end = cursor.addingTimeInterval(place.1 * 3_600)
            defer { cursor = end.addingTimeInterval(3_600) }
            return TripTitlePolicy.StayInput(
                id: UUID(), orderInTrip: index, startTime: cursor, endTime: end,
                durationMinutes: Int(place.1 * 60), categoryRaw: StayCategory.destination.rawValue,
                isAirport: false, metroName: nil, islandName: nil, locality: place.0,
                administrativeArea: nil, country: "Velandia", isoCountryCode: "QX")
        }
    }

    /// An invented table: Velmora is Welmorn in German, and both places
    /// have Japanese names; nothing else has a name of its own.
    nonisolated private static func inventedName(_ place: TripTitlePolicy.TitlePlace, _ languageTag: String) -> String? {
        guard place.isoCountryCode == "QX" else { return nil }
        switch (place.name, languageTag) {
        case ("Velmora", "de"): return "Welmorn"
        case ("Velmora", "ja"): return "ヴェルモラ"
        case ("Ostrel", "ja"): return "オストレル"
        default: return nil
        }
    }

    private static func localized(
        _ canonical: String, _ stays: [TripTitlePolicy.StayInput], _ languageTag: String
    ) -> String? {
        TripTitlePolicy.localizedTitle(
            canonicalTitle: canonical, stays: stays, homePlaceNames: [], languageTag: languageTag,
            placeName: { inventedName($0, languageTag) })
    }

    @Test("a localized title names the canonical title's places from the table with the language's connector")
    func localizedTitleNamesCanonicalPlaces() throws {
        let stays = Self.stayInputs([("Velmora", 30), ("Ostrel", 10)])
        #expect(TripTitlePolicy.titleAlternatives(stays: stays, homePlaceNames: [])
            == ["Velmora & Ostrel", "Velmora"])
        #expect(Self.localized("Velmora & Ostrel", stays, "de") == "Welmorn & Ostrel")
        #expect(Self.localized("Velmora & Ostrel", stays, "ja") == "ヴェルモラとオストレル")
        #expect(Self.localized("Velmora & Ostrel", stays, "el") == "Velmora και Ostrel")
        #expect(Self.localized("Velmora", stays, "de") == "Welmorn")
        // A title the stays do not give names no places this can trust.
        #expect(Self.localized("Ostrel & Velmora", stays, "de") == nil)
    }

    @Test("a place the table has no name for keeps its canonical spelling")
    func missingNameKeepsCanonicalSpelling() throws {
        let stays = Self.stayInputs([("Velmora", 30), ("Ostrél", 10), ("Dunvar", 5)])
        let canonical = try #require(TripTitlePolicy.defaultTitle(stays: stays, homePlaceNames: []))
        #expect(canonical == "Velmora, Ostrel & Dunvar")
        #expect(Self.localized(canonical, stays, "fr") == "Velmora, Ostrel et Dunvar")
        #expect(Self.localized(canonical, stays, "de") == "Welmorn, Ostrel & Dunvar")
        #expect(Self.localized(canonical, stays, "zh-Hans") == "Velmora、Ostrel和Dunvar")
    }

    /// A destination stay in `iso` named by its island and town, `offset` hours after `start`.
    private static func islandStay(
        island: String?, locality: String, country: String, iso: String, hours: Double, offset: Double
    ) -> TripTitlePolicy.StayInput {
        let startTime = start.addingTimeInterval(offset * 3_600)
        return TripTitlePolicy.StayInput(
            id: UUID(), orderInTrip: nil, startTime: startTime,
            endTime: startTime.addingTimeInterval(hours * 3_600),
            durationMinutes: Int(hours * 60), categoryRaw: StayCategory.destination.rawValue,
            isAirport: false, metroName: nil, islandName: island, locality: locality,
            administrativeArea: nil, country: country, isoCountryCode: iso)
    }

    /// `canonical` in `languageTag`, its places named from the bundled table.
    private static func bundledLocalized(
        _ canonical: String, _ stays: [TripTitlePolicy.StayInput], _ languageTag: String
    ) -> String? {
        TripTitlePolicy.localizedTitle(
            canonicalTitle: canonical, stays: stays, homePlaceNames: [], languageTag: languageTag,
            placeName: { PlaceNameTable.shared.name(for: $0, languageTag: languageTag) })
    }

    @Test("an island takes its name from the table's island rows, never from a town of its name")
    func islandLayerNeverTakesTownName() throws {
        func stay(island: String?, hours: Double, offset: Double) -> TripTitlePolicy.StayInput {
            Self.islandStay(
                island: island, locality: "Ibiza", country: "Spain", iso: "ES", hours: hours, offset: offset)
        }
        // The town on its own takes the table's name for it.
        let town = [stay(island: nil, hours: 30, offset: 0)]
        #expect(TripTitlePolicy.titleOptions(stays: town, homePlaceNames: []).first?.places.map(\.layer) == [.locality])
        #expect(Self.bundledLocalized("Ibiza", town, "de") == "Ibiza-Stadt")
        // The island is Ibiza in German too.
        let island = [stay(island: "Ibiza", hours: 30, offset: 0)]
        #expect(TripTitlePolicy.titleOptions(stays: island, homePlaceNames: []).first?.places.map(\.layer) == [.island])
        #expect(Self.bundledLocalized("Ibiza", island, "de") == "Ibiza")
        // So is a place named by the island for any of its stays.
        let mixed = [stay(island: nil, hours: 3, offset: 0), stay(island: "Ibiza", hours: 30, offset: 4)]
        #expect(TripTitlePolicy.titleOptions(stays: mixed, homePlaceNames: []).first?.places.map(\.layer) == [.island])
        #expect(Self.bundledLocalized("Ibiza", mixed, "de") == "Ibiza")
    }

    @Test("islands take their own names in a localized title, one per place")
    func islandsTakeIslandNames() throws {
        // Each island's main town has a Greek name of its own.
        let lesbos = Self.islandStay(
            island: "Lesbos", locality: "Mytilene", country: "Greece", iso: "GR", hours: 40, offset: 0)
        let chios = Self.islandStay(
            island: "Chios", locality: "Chios", country: "Greece", iso: "GR", hours: 30, offset: 48)
        #expect(Self.bundledLocalized("Lesbos", [lesbos], "el") == "Λέσβος")
        let both = [lesbos, chios]
        let option = try #require(TripTitlePolicy.titleOptions(stays: both, homePlaceNames: []).first)
        #expect(option.title == "Lesbos & Chios")
        #expect(option.places.map(\.layer) == [.island, .island])
        #expect(Self.bundledLocalized("Lesbos & Chios", both, "el") == "Λέσβος και Χίος")
        // Islands named in another language than their country's, big ones included.
        let corsica = Self.islandStay(
            island: "Corsica", locality: "Ajaccio", country: "France", iso: "FR", hours: 30, offset: 0)
        #expect(Self.bundledLocalized("Corsica", [corsica], "de") == "Korsika")
        let sicily = Self.islandStay(
            island: "Sicily", locality: "Palermo", country: "Italy", iso: "IT", hours: 30, offset: 0)
        #expect(Self.bundledLocalized("Sicily", [sicily], "it") == "Sicilia")
    }

    @Test("an island the table has no island row for keeps its canonical spelling, whatever a town of its name is called")
    func islandWithoutRowKeepsCanonicalSpelling() throws {
        func stay(island: String?) -> TripTitlePolicy.StayInput {
            Self.islandStay(island: island, locality: "Capri", country: "Italy", iso: "IT", hours: 30, offset: 0)
        }
        #expect(PlaceNameTable.shared.name(for: "Capri", isoCountryCode: "IT", languageTag: "de", layer: .island) == nil)
        #expect(Self.bundledLocalized("Capri", [stay(island: nil)], "de") == "Stadt Capri")
        #expect(Self.bundledLocalized("Capri", [stay(island: "Capri")], "de") == "Capri")
    }

    @Test("an island never takes the name of a namesake island of its country or of an area it lies in")
    func islandNeverTakesNamesakeOrAreaName() throws {
        func island(_ name: String, _ iso: String, _ languageTag: String) -> String? {
            PlaceNameTable.shared.name(for: name, isoCountryCode: iso, languageTag: languageTag, layer: .island)
        }
        // Two islands of Japan are Nakanoshima (中之島, 中ノ島): neither names the other.
        #expect(island("Nakanoshima", "JP", "ja") == nil)
        // A province, a national park and a group are not the island.
        #expect(island("Cebu", "PH", "it") == nil)
        #expect(island("Cebu", "PH", "ja") == "セブ島")
        #expect(island("Gotska Sandon", "SE", "de") == nil)
        #expect(island("Gotska Sandon", "SE", "sv") == "Gotska Sandön")
        #expect(island("Vega", "NO", "fr") == nil)
        // A Han name ending in an area's suffix is the area's (萊夫卡斯州),
        // unless the island's Japanese and Chinese names agree on it (九州).
        #expect(island("Lefkada", "GR", "zh-Hans") == nil)
        #expect(island("Lefkada", "GR", "ja") == "レフカダ島")
        #expect(island("Kyushu", "JP", "ja") == "九州")
        #expect(island("Kyushu", "JP", "zh-Hans") == "九州")
    }

    /// A destination stay built from what the bundled geocoder stores for a point.
    private static func geocodedStay(_ result: GeocodeResolver.Result) -> TripTitlePolicy.StayInput {
        TripTitlePolicy.StayInput(
            id: UUID(), orderInTrip: 0, startTime: start, endTime: start.addingTimeInterval(30 * 3_600),
            durationMinutes: 30 * 60, categoryRaw: StayCategory.destination.rawValue,
            isAirport: false, metroName: result.metroName, islandName: result.islandName,
            locality: result.localityForStorage, administrativeArea: result.administrativeArea,
            country: result.country, isoCountryCode: result.isoCountryCode)
    }

    @Test("a stay on an overseas department's island localizes it under the code the stay stores")
    func overseasDepartmentIslandLocalizes() async throws {
        let result = try #require(
            await GeocodeResolver.shared.resolve(latitude: 14.7, longitude: -61.0),
            "bundled geocoder unavailable in this run")
        // The stay stores France's code (its admin-1 polygon's), where
        // GeoNames files the island under Martinique's.
        #expect(result.islandName == "Martinique")
        #expect(result.isoCountryCode == "FR")
        let stays = [Self.geocodedStay(result)]
        let canonical = try #require(TripTitlePolicy.defaultTitle(stays: stays, homePlaceNames: []))
        #expect(canonical == "Martinique")
        #expect(PlaceNameTable.shared.name(
            for: "Martinique", isoCountryCode: "MQ", languageTag: "es", layer: .island) == "Martinica")
        #expect(Self.bundledLocalized(canonical, stays, "es") == "Martinica")
    }

    @Test("a stay in a cross-border metro's other part localizes the metro like its core city")
    func crossBorderMetroLocalizes() async throws {
        // The German part of the Basel commuting zone.
        let result = try #require(
            await GeocodeResolver.shared.resolve(latitude: 47.6, longitude: 7.65),
            "bundled geocoder unavailable in this run")
        #expect(result.metroName == "Basel")
        #expect(result.isoCountryCode == "DE")
        let stays = [Self.geocodedStay(result)]
        let canonical = try #require(TripTitlePolicy.defaultTitle(stays: stays, homePlaceNames: []))
        #expect(canonical == "Basel")
        #expect(Self.bundledLocalized(canonical, stays, "fr") == "Bâle")
    }

    /// A trip with one destination stay per `(locality, hours)` in an
    /// invented country, titled with its default title.
    private func makeTitledTrip(_ places: [(String, Double)], in context: ModelContext) throws -> Trip {
        let trip = Trip(startDate: Self.start)
        context.insert(trip)
        for (index, input) in Self.stayInputs(places).enumerated() {
            let stay = Stay(
                startTime: input.startTime,
                endTime: input.endTime,
                centroidLatitude: 10 + Double(index) * 0.1,
                centroidLongitude: 20,
                h3IndexRes6: "8a2a1072b59ffff",
                pingCount: 2,
                distanceFromHomeKm: 40,
                pingIDs: [])
            stay.durationMinutes = input.durationMinutes
            stay.category = .destination
            stay.locality = input.locality
            stay.country = input.country
            stay.isoCountryCode = input.isoCountryCode
            context.insert(stay)
            stay.trip = trip
            stay.orderInTrip = index
        }
        trip.isComplete = true
        trip.endDate = trip.orderedStays.last?.endTime
        TripTitleStore.replaceCanonicalTitle(
            try TripTitleStore.generatedTitleAlternatives(for: trip, in: context).first, for: trip, in: context)
        try context.save()
        return trip
    }

    private func refetch(_ trip: Trip, in container: ModelContainer) throws -> Trip {
        let id = trip.id
        return try #require(try ModelContext(container).fetch(
            FetchDescriptor<Trip>(predicate: #Predicate { $0.id == id })).first)
    }

    @Test("the stage writes a variant only where the shown title differs, replaces an older one, and settles")
    func stageWritesDeterministicVariants() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTitledTrip([("Velmora", 30), ("Ostrel", 10)], in: context)
        let unnamed = try makeTitledTrip([("Dunvar", 5)], in: context)
        #expect(trip.aiGeneratedTitle == "Velmora & Ostrel")
        // A variant an older build stored for the same canonical title.
        #expect(TripTitleStore.upsertVariant(
            languageTag: "de", title: "Velmora und Ostrel", sourceTitle: "Velmora & Ostrel",
            updatedAt: .distantPast, for: trip, in: context))
        try context.save()

        let service = TripTitleLocalizationService(modelContainer: container)
        await service.setPlaceNamesForTesting { Self.inventedName($0, $1) }
        #expect(await service.generateLocalizedTitlesStage(maxTripsPerCall: nil, languageTag: "de") == 1)
        #expect(try refetch(trip, in: container).displayName(languageTag: "de") == "Welmorn & Ostrel")
        // The same text in German needs no row.
        #expect(try refetch(unnamed, in: container).localizedTitles?.isEmpty != false)
        #expect(try refetch(unnamed, in: container).displayName(languageTag: "de") == "Dunvar")

        #expect(await service.generateLocalizedTitlesStage(maxTripsPerCall: nil, languageTag: "de") == 0)
        #expect(await service.generateLocalizedTitlesStage(maxTripsPerCall: nil, languageTag: "en") == 0)
        let german = try ModelContext(container).fetch(FetchDescriptor<TripTitleVariant>())
            .filter { $0.languageTag == "de" }
        #expect(german.map(\.title) == ["Welmorn & Ostrel"])

        // The detail lane localizes one trip at once.
        #expect(await service.localizedTitle(for: trip.id, languageTag: "ja") == "ヴェルモラとオストレル")
        #expect(try refetch(trip, in: container).displayName(languageTag: "ja") == "ヴェルモラとオストレル")
    }

    @Test("a category edit that changes the layer a title names re-localizes it within the launch")
    func categoryEditRekeysLocalizedTitle() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTitledTrip([("Velmora", 30), ("Velmora", 2)], in: context)
        // The short stay lies on the island of the town's name, passing through.
        let pass = try #require(trip.orderedStays.last)
        pass.islandName = "Velmora"
        pass.category = .transit
        try context.save()
        #expect(trip.aiGeneratedTitle == "Velmora")

        let service = TripTitleLocalizationService(modelContainer: container)
        await service.setPlaceNamesForTesting { place, languageTag in
            guard place.name == "Velmora", languageTag == "de" else { return nil }
            return place.layer == .island ? "Velmora-Eiland" : "Welmorn"
        }
        #expect(await service.generateLocalizedTitlesStage(maxTripsPerCall: nil, languageTag: "de") == 1)
        #expect(try refetch(trip, in: container).displayName(languageTag: "de") == "Welmorn")

        // A destination on the island makes the place the island: the
        // English title and every place name stay, the German one changes.
        pass.category = .destination
        #expect(!TripTitleStore.invalidateGeneratedTitles(for: trip, in: context))
        try context.save()
        #expect(await service.generateLocalizedTitlesStage(maxTripsPerCall: nil, languageTag: "de") == 1)
        #expect(try refetch(trip, in: container).displayName(languageTag: "de") == "Velmora-Eiland")
    }

    @Test("a Home that changes which namesake a title names re-localizes it within the launch")
    func homeChangeRekeysLocalizedTitle() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTitledTrip([("Velmora", 30), ("Velmora", 10)], in: context)
        // The shorter stay is in a namesake town of another country.
        let namesake = try #require(trip.orderedStays.last)
        namesake.country = "Ostravia"
        namesake.isoCountryCode = "QW"
        try context.save()
        #expect(trip.aiGeneratedTitle == "Velmora")

        let service = TripTitleLocalizationService(modelContainer: container)
        await service.setPlaceNamesForTesting { Self.inventedName($0, $1) }
        #expect(await service.generateLocalizedTitlesStage(maxTripsPerCall: nil, languageTag: "de") == 1)
        #expect(try refetch(trip, in: container).displayName(languageTag: "de") == "Welmorn")

        // A Home in the first Velmora leaves the namesake as the place: the
        // English title and every stay stay, the German one changes.
        let home = Home(label: "Home", latitude: 10, longitude: 20,
                        startedAt: Self.start.addingTimeInterval(-365 * 86_400))
        home.locality = "Velmora"
        home.country = "Velandia"
        home.isoCountryCode = "QX"
        context.insert(home)
        try context.save()
        TripTitleStore.invalidateHomePlaceIndex()
        #expect(!TripTitleStore.invalidateGeneratedTitles(for: trip, in: context))
        #expect(await service.generateLocalizedTitlesStage(maxTripsPerCall: nil, languageTag: "de") == 1)
        #expect(try refetch(trip, in: container).displayName(languageTag: "de") == "Velmora")
    }

    @Test("a Home that syncs in while a title is composed leaves the trip for the next stage")
    func homeDuringCompositionLeavesTripUnsettled() async throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = try makeTitledTrip([("Velmora", 30), ("Velmora", 10)], in: context)
        let namesake = try #require(trip.orderedStays.last)
        namesake.country = "Ostravia"
        namesake.isoCountryCode = "QW"
        try context.save()
        #expect(trip.aiGeneratedTitle == "Velmora")

        // The Home lands, as a sync would, after the stage read the home
        // places for the composition and before it records the trip.
        let homePending = OSAllocatedUnfairLock(initialState: true)
        let homeStart = Self.start.addingTimeInterval(-365 * 86_400)
        let service = TripTitleLocalizationService(modelContainer: container)
        await service.setPlaceNamesForTesting { place, languageTag in
            if homePending.withLock({ pending in defer { pending = false }; return pending }) {
                let writer = ModelContext(container)
                let home = Home(label: "Home", latitude: 10, longitude: 20, startedAt: homeStart)
                home.locality = "Velmora"
                home.country = "Velandia"
                home.isoCountryCode = "QX"
                writer.insert(home)
                try? writer.save()
                TripTitleStore.invalidateHomePlaceIndex()
            }
            return Self.inventedName(place, languageTag)
        }
        #expect(await service.generateLocalizedTitlesStage(maxTripsPerCall: nil, languageTag: "de") == 1)
        #expect(try refetch(trip, in: container).displayName(languageTag: "de") == "Welmorn")
        #expect(!homePending.withLock { $0 })

        #expect(await service.generateLocalizedTitlesStage(maxTripsPerCall: nil, languageTag: "de") == 1)
        #expect(try refetch(trip, in: container).displayName(languageTag: "de") == "Velmora")
    }
}

@Suite("Place-name table")
struct PlaceNameTableTests {

    /// A table in the shape `scripts/build-place-names.py` writes, with invented places.
    private func makeTable() throws -> (table: PlaceNameTable, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaceNames-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, """
            CREATE TABLE place (name_key TEXT NOT NULL, iso_country TEXT NOT NULL, layer TEXT NOT NULL,
                geoname_id INTEGER NOT NULL, PRIMARY KEY (name_key, iso_country, layer)) WITHOUT ROWID;
            CREATE TABLE name (geoname_id INTEGER NOT NULL, language TEXT NOT NULL,
                name TEXT NOT NULL, PRIMARY KEY (geoname_id, language)) WITHOUT ROWID;
            INSERT INTO place VALUES ('velmora', 'QX', 'city', 1), ('ostrel', 'QX', 'city', 2),
                ('velmora', 'QY', 'city', 3), ('velmora', 'QX', 'island', 4), ('dunvar', 'QX', 'island', 5);
            INSERT INTO name VALUES
                (1, 'de', 'Welmorn'), (1, 'pt', 'Velmóra'), (1, 'pt-BR', 'Velmôra'),
                (1, 'zh-Hans', '維爾莫拉'), (1, 'zh-Hant', '韋爾莫拉'),
                (2, 'pt', 'Ostrela'), (2, 'zh-Hans', '奥斯特雷尔'),
                (3, 'de', 'Fremdmorn'),
                (4, 'de', 'Welmora-Eiland'), (4, 'el', 'Βελμόρα'),
                (5, 'de', 'Dunwar');
            """, nil, nil, nil) == SQLITE_OK)
        return (PlaceNameTable(url: url), url)
    }

    @Test("an island takes its name from island rows and any other place from city rows")
    func titlePlaceLookupByLayer() throws {
        let (table, url) = try makeTable()
        defer { try? FileManager.default.removeItem(at: url) }
        func name(_ place: String, _ layer: TripTitlePolicy.TitlePlaceLayer?, _ languageTag: String = "de") -> String? {
            table.name(
                for: TripTitlePolicy.TitlePlace(name: place, isoCountryCode: "QX", layer: layer),
                languageTag: languageTag)
        }
        for layer in [TripTitlePolicy.TitlePlaceLayer.metro, .locality, .region, nil] {
            #expect(name("Velmora", layer) == "Welmorn")
            // An island row never names a city, metro or region.
            #expect(name("Dunvar", layer) == nil)
        }
        #expect(name("Velmora", .island) == "Welmora-Eiland")
        #expect(name("Velmora", .island, "el") == "Βελμόρα")
        #expect(name("Dunvar", .island) == "Dunwar")
        // An island without an island row keeps its canonical spelling,
        // even where a city of its name has one.
        #expect(name("Ostrel", .island, "pt-PT") == nil)
        #expect(name("Ostrel", .locality, "pt-PT") == "Ostrela")
        // Search reads city rows only.
        #expect(table.names(for: "Dunvar", isoCountryCode: "QX").isEmpty)
    }

    @Test("names are looked up by folded stored name and country, never across countries")
    func lookupByNameAndCountry() throws {
        let (table, url) = try makeTable()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(table.name(for: "Velmora", isoCountryCode: "QX", languageTag: "de") == "Welmorn")
        #expect(table.name(for: " velmóra ", isoCountryCode: "qx", languageTag: "de") == "Welmorn")
        #expect(table.name(for: "Velmora", isoCountryCode: "QY", languageTag: "de") == "Fremdmorn")
        #expect(table.name(for: "Velmora", isoCountryCode: "QZ", languageTag: "de") == nil)
        #expect(table.name(for: "Velmora", isoCountryCode: nil, languageTag: "de") == nil)
        #expect(table.name(for: "Velmora", isoCountryCode: "QX", languageTag: "fr") == nil)
        #expect(table.name(for: "Velmora", isoCountryCode: "QX", languageTag: "en") == nil)
    }

    @Test("every language's stored name, as stored, for search")
    func allNamesForSearch() throws {
        let (table, url) = try makeTable()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(table.names(for: "Velmóra", isoCountryCode: "qx") == [
            "de": "Welmorn", "pt": "Velmóra", "pt-BR": "Velmôra", "zh-Hans": "維爾莫拉", "zh-Hant": "韋爾莫拉",
        ])
        #expect(table.names(for: "Velmora", isoCountryCode: "QZ").isEmpty)
        #expect(table.names(for: "Velmora", isoCountryCode: nil).isEmpty)
    }

    @Test("pt-BR rows override Portuguese for Brazil only, and Chinese follows its script")
    func portugueseAndChineseVariants() throws {
        let (table, url) = try makeTable()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(table.name(for: "Velmora", isoCountryCode: "QX", languageTag: "pt-BR") == "Velmôra")
        #expect(table.name(for: "Velmora", isoCountryCode: "QX", languageTag: "pt-PT") == "Velmóra")
        #expect(table.name(for: "Ostrel", isoCountryCode: "QX", languageTag: "pt-BR") == "Ostrela")
        // A Traditional name filed as Chinese reads Simplified.
        #expect(table.name(for: "Velmora", isoCountryCode: "QX", languageTag: "zh-Hans") == "维尔莫拉")
        // An explicit Traditional name wins; otherwise the Simplified one is converted.
        #expect(table.name(for: "Velmora", isoCountryCode: "QX", languageTag: "zh-Hant") == "韋爾莫拉")
        #expect(table.name(for: "Ostrel", isoCountryCode: "QX", languageTag: "zh-Hant") == "奧斯特雷爾")
    }

    @Test("a city of an overseas department has its names under the code its stays store too")
    func overseasDepartmentCityNamesUnderStoredCode() {
        // Stays there store FR (`GeocodeResolver.resolve`: admin-1 code first);
        // GeoNames files the city under Guadeloupe's code.
        for iso in ["GP", "FR"] {
            #expect(PlaceNameTable.shared.name(for: "Pointe-a-Pitre", isoCountryCode: iso, languageTag: "fr")
                    == "Pointe-à-Pitre", "\(iso)")
        }
    }

    @Test("the app bundles a table in the shape the lookup reads")
    func bundledTableShips() throws {
        let url = try #require(Bundle.main.url(forResource: "PlaceNames", withExtension: "sqlite"))
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        for layer in [PlaceNameTable.Layer.city, .island] {
            var statement: OpaquePointer?
            try #require(sqlite3_prepare_v2(db, """
                SELECT count(*) FROM place JOIN name ON name.geoname_id = place.geoname_id
                WHERE place.layer = '\(layer.rawValue)'
                """, -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            try #require(sqlite3_step(statement) == SQLITE_ROW)
            #expect(sqlite3_column_int64(statement, 0) > 0, "\(layer.rawValue)")
        }
    }
}
