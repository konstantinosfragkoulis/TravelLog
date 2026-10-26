//
//  MigrationChainTests.swift
//  TravelLogTests
//
//  Two layers of released-schema migration coverage:
//
//  1. Plan-consistency pins that need no fixture: the shared
//     `CurrentTravelLogSchema` alias (the single selection
//     point both AppDelegate and the widget consume) must be the migration
//     plan's terminal schema, and the stage chain must cover every declared
//     schema hop. When V16 lands, these FAIL until the alias, the schema
//     list, and the stage list all move together.
//
//  2. A V14→CURRENT migration replay over an externally supplied captured
//     V14 store (same fixture + env contract as HomeShapeReplayTests; the
//     fixture is never modified, every open works on a fresh copy): open a copy at
//     V14, read ground-truth row counts, then open a second copy at
//     CURRENT + TravelLogMigrationPlan - the remaining staged migrations run -
//     and require every row to survive with key fields intact and the new
//     V15/V16 entities fetchable. A separate synthetic, historically faithful
//     V15 store directly exercises the current V15→V16 relationship hop;
//     the standing rule that a schema bump must ALSO be validated on a
//     physical device before shipping is unchanged.
//
//  NOTE deliberately NOT attempted here: synthetic fixtures for V3…V13.
//  Old `VersionedSchema` enums derive their model shapes from the classes as
//  compiled TODAY (only explicitly frozen models are historically faithful),
//  so a store written through e.g. `TravelLogSchemaV4` in this test host
//  would NOT reproduce the released on-disk V4 shape - it would green-light
//  nothing. Faithful early-chain fixtures require store files captured from
//  the old builds themselves.
//

import CoreData
import Foundation
import SwiftData
import Testing
@testable import TravelLog

@MainActor
private final class MigrationFirstDrainLog {
    var units: [UUID] = []
    var retired: Set<UUID> = []
    var favourites: Set<UUID>
    init(favourite: UUID) { favourites = [favourite] }
}

extension ReconciliationDrainTests {
@MainActor
@Suite("Migration chain", .serialized)
struct MigrationChainTests {

    @Test("the first V21 drain of a migrated V20 kept trip applies the deliberate split policy once, preserves its recovery copy and hidden photo choices, and acknowledges unchanged coverage", IsolatedTitleDefaults())
    func migratedV20KeepOnFirstDrain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("V20FirstDrain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "V20FirstDrain-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storeURL = directory.appendingPathComponent("migration.sqlite")
        let seeded = try writeSyntheticV20Store(at: storeURL)
        var originalStayIDs: Set<UUID> = [seeded.stayID]
        var weekendStayIDs: Set<UUID> = []
        let annotationDate = Date(timeIntervalSince1970: 1_719_958_400)
        var originalHiddenID: UUID?
        var originalPinnedID: UUID?
        // Extend the existing faithful V20 fixture through its frozen shapes,
        // before opening it with the current schema and real migration plan.
        do {
            let schema = Schema(versionedSchema: TravelLogSchemaV20.self)
            let legacy = try ModelContainer(for: schema, configurations: [ModelConfiguration(
                "SyntheticV20", schema: schema, url: storeURL, cloudKitDatabase: .none)])
            let ctx = ModelContext(legacy)
            let old = try #require(try ctx.fetch(FetchDescriptor<TravelLogSchemaV20.Trip>()).first)
            old.customName = "Semester and two weekends"
            let points: [(Double, Double, Double, Double)] = [
                (1, 2, 51.85, 4.35), (3, 5, 50.85, 4.35),
                (6, 7, 50.85, 6.35), (8, 10, 50.85, 4.35),
            ]
            for (index, point) in points.enumerated() {
                let stay = TravelLogSchemaV20.Stay()
                stay.startTime = old.startDate.addingTimeInterval(point.0 * 86_400)
                stay.endTime = old.startDate.addingTimeInterval(point.1 * 86_400)
                stay.durationMinutes = Int((point.1 - point.0) * 1_440)
                stay.centroidLatitude = point.2
                stay.centroidLongitude = point.3
                stay.categoryRaw = StayCategory.destination.rawValue
                stay.pingCount = 2
                stay.h3IndexRes6 = "upgrade-\(index)"
                stay.timeZoneIdentifier = "GMT"
                stay.orderInTrip = index + 1
                ctx.insert(stay)
                stay.trip = old
                originalStayIDs.insert(stay.id)
                if index == 0 || index == 2 { weekendStayIDs.insert(stay.id) }
            }
            old.endDate = old.startDate.addingTimeInterval(10 * 86_400)
            let hidden = try #require(try ctx.fetch(FetchDescriptor<HiddenPhoto>()).first)
            hidden.cloudIdentifier = "upgrade-hidden-cloud"
            hidden.hiddenAt = annotationDate
            originalHiddenID = hidden.id
            let pinned = try #require(try ctx.fetch(FetchDescriptor<PinnedPhoto>()).first)
            pinned.cloudIdentifier = "upgrade-pinned-cloud"
            pinned.pinnedAt = annotationDate
            originalPinnedID = pinned.id
            try ctx.save()
        }
        let container = try openMigrated(storeURL, name: "V20FirstDrain")
        let read = ModelContext(container)
        let migrated = try #require(try read.fetch(FetchDescriptor<Trip>()).first)
        #expect(migrated.userEdited && migrated.keptByTemporaryHome)
        #expect(Set((migrated.stays ?? []).map(\.id)) == originalStayIDs)
        let declaration = try #require(try read.fetch(FetchDescriptor<TemporaryHome>())
            .first { $0.id == seeded.liveID })
        #expect(declaration.coverageRevision == 0 && declaration.keptTripIDs.isEmpty)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).isEmpty)
        #expect(CoverageReconciliationQueue.Acknowledgements.load(from: directory).isEmpty)
        TripTitleStore.invalidateHomePlaceIndex()
        let classifier = await TemporaryHomeFixture.classifier(container, squares: [
            (1, (37.98, 23.72)), (2, (50.85, 4.35)),
        ])
        await classifier.setDissolvedRecordSink { records in
            try DissolvedTripQueue.append(records, in: directory)
        }
        let log = MigrationFirstDrainLog(favourite: seeded.tripID)
        let stages = CoverageReconciliationQueue.Stages(
            applyHome: { _, _ in .failed },
            applyRoutinePlace: { _, _ in .failed },
            applyTemporaryHome: { id, onSettled in
                log.units.append(id)
                return await StayClassificationInference.TestHook.$availability.withValue(false) {
                    await classifier.applyTemporaryHomeChange(
                        temporaryHomeID: id, pinnedTripIDs: { log.favourites },
                        gate: PipelineGate(forTesting: ()),
                        unpinRetired: { ids in
                            log.retired.formUnion(ids)
                            log.favourites.subtract(ids)
                        }, acknowledgementDirectory: directory, onSettled: onSettled)
                }
            }, generateLocalizedTitles: {}, publish: { _, _ in }, heal: {},
            isPersistentStore: { !container.configurations.contains(where: \.isStoredInMemoryOnly) },
            removalEvidence: {
                try? CoverageReconciliationQueue.removalEvidence(in: ModelContext(container))
            }, discoveryDigests: {
                await classifier.temporaryHomeDiscoveryDigests(pinnedTripIDs: log.favourites)
            }, acknowledgementDirectory: directory)
        #expect(await CoverageReconciliationQueue.drainIfNeeded(defaults: defaults, stages: stages))
        #expect(log.units.filter { $0 == seeded.liveID }.count == 1)
        #expect(log.retired == [seeded.tripID] && log.favourites.isEmpty)
        let archives = DissolvedTripQueue.load(from: directory)
        let record = try #require(archives.first { $0.id == seeded.tripID })
        #expect(record.splitCommitted == true && record.splitByTemporaryHomeID == seeded.liveID)
        #expect(record.customName == "Semester and two weekends" && record.wasFavourite == true)
        #expect(Set(record.stays.map(\.id)) == originalStayIDs)
        let archivedHidden = try #require(record.photoAnnotations?.first { !$0.isPinned })
        let archivedPinned = try #require(record.photoAnnotations?.first { $0.isPinned })
        #expect(archivedHidden.id == originalHiddenID && archivedHidden.cloudIdentifier == "upgrade-hidden-cloud")
        #expect(archivedPinned.id == originalPinnedID && archivedPinned.cloudIdentifier == "upgrade-pinned-cloud")
        let after = ModelContext(container)
        let pieces = try after.fetch(FetchDescriptor<Trip>())
        #expect(!pieces.contains { $0.id == seeded.tripID })
        #expect(pieces.count == 2)
        #expect(Set(pieces.flatMap { $0.stays ?? [] }.map(\.id)) == weekendStayIDs)
        let hiddenCopies = try after.fetch(FetchDescriptor<HiddenPhoto>())
        #expect(Set(hiddenCopies.map(\.tripID)) == Set(pieces.map(\.id)))
        #expect(hiddenCopies.count == pieces.count)
        #expect(hiddenCopies.allSatisfy {
            $0.id != originalHiddenID && $0.localIdentifier == archivedHidden.localIdentifier
                && $0.cloudIdentifier == "upgrade-hidden-cloud" && $0.hiddenAt == annotationDate
        })
        #expect(try after.fetchCount(FetchDescriptor<PinnedPhoto>()) == 0)
        #expect(CoverageReconciliationQueue.Acknowledgements.load(from: directory)[seeded.liveID] != nil)
        #expect(CoverageReconciliationQueue.pending(defaults: defaults).isEmpty)
        let unitsBeforeReplay = log.units
        let photoIDsBeforeReplay = Set(hiddenCopies.map(\.id))
        #expect(await CoverageReconciliationQueue.drainIfNeeded(defaults: defaults, stages: stages))
        #expect(log.units == unitsBeforeReplay)
        #expect(DissolvedTripQueue.load(from: directory) == archives)
        #expect(Set(try ModelContext(container).fetch(FetchDescriptor<HiddenPhoto>()).map(\.id)) == photoIDsBeforeReplay)
    }

    // MARK: - Plan consistency (no fixture required)

    @Test("CurrentTravelLogSchema is the migration plan's terminal schema, at version 21")
    func currentSchemaIsThePlanDestination() {
        let last = TravelLogMigrationPlan.schemas.last
        #expect(last == CurrentTravelLogSchema.self,
                "the shared alias and the plan's last schema must move together")
        #expect(CurrentTravelLogSchema.versionIdentifier == Schema.Version(21, 0, 0))
    }

    @Test("the stage chain visits every declared schema hop, in order")
    func stageChainCoversEveryHop() throws {
        let schemas = TravelLogMigrationPlan.schemas
        let stages = TravelLogMigrationPlan.stages
        #expect(stages.count == schemas.count - 1,
                "every consecutive schema pair needs exactly one stage")
        // Count alone can't catch a duplicated-plus-omitted stage pair.
        // `MigrationStage` hides its
        // associated values, so the from/to schemas are read via Mirror -
        // if SwiftData ever changes the case layout, the `#require` fails
        // loudly and this assertion must be rebuilt, not silently skipped.
        for (index, stage) in stages.enumerated() {
            let payload = Mirror(reflecting: stage).children.first?.value
            let hop = payload.map {
                Mirror(reflecting: $0).children.compactMap {
                    $0.value as? any VersionedSchema.Type
                }
            } ?? []
            try #require(hop.count == 2,
                         "MigrationStage no longer reflects its from/to schemas (got \(hop.count) at stage \(index))")
            // Metatype identity; Swift 6 cannot type-check `==` on two
            // `any VersionedSchema.Type` values inside `#expect`.
            #expect(ObjectIdentifier(hop[0]) == ObjectIdentifier(schemas[index]),
                    "stage \(index) must migrate FROM \(schemas[index])")
            #expect(ObjectIdentifier(hop[1]) == ObjectIdentifier(schemas[index + 1]),
                    "stage \(index) must migrate TO \(schemas[index + 1])")
        }
    }

    @Test("the CloudKit schema initializer's Core Data model has every current entity and property")
    func cloudKitSchemaModelMatchesCurrentSchema() throws {
        // `AppDelegate.initializeCloudKitDevelopmentSchema` builds its model this way;
        // a missing entity or property would be missing from CloudKit Production too.
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(
            for: CurrentTravelLogSchema.models))
        let schema = Schema(versionedSchema: CurrentTravelLogSchema.self)
        let entities = Dictionary(uniqueKeysWithValues: model.entities.compactMap { entity in
            entity.name.map { ($0, entity) }
        })
        #expect(entities.count == CurrentTravelLogSchema.models.count)
        #expect(Set(entities.keys) == Set(schema.entities.map(\.name)))
        for entity in schema.entities {
            let properties = Set(entities[entity.name]?.propertiesByName.keys.map { $0 } ?? [])
            #expect(properties == Set(entity.properties.map { $0.name }), "\(entity.name)")
        }
        // The V19 entity reaches CloudKit with every field and nothing CloudKit rejects.
        let temporaryHome = try #require(entities["TemporaryHome"])
        #expect(Set(temporaryHome.attributesByName.keys) == [
            "id", "label", "latitude", "longitude", "radiusKm",
            "locality", "administrativeArea", "country", "isoCountryCode",
            "startedAt", "endedAt", "timeZoneIdentifier", "createdAt", "modifiedAt",
            "removedAt", "coverageRevision", "keptTripIDs",
        ])
        #expect(temporaryHome.relationshipsByName.isEmpty)
        #expect(temporaryHome.uniquenessConstraints.isEmpty)
        // The V20 fields reach it too, optional or defaulted.
        let removedAt = try #require(temporaryHome.attributesByName["removedAt"])
        #expect(removedAt.isOptional)
        let provenance = try #require(entities["Stay"]?.attributesByName["temporaryHomeID"])
        #expect(provenance.isOptional)
        let kept = try #require(entities["Trip"]?.attributesByName["keptByTemporaryHome"])
        #expect(kept.isOptional || kept.defaultValue != nil, "CloudKit needs a default")
        #expect(entities["Stay"]?.uniquenessConstraints.isEmpty == true)
        #expect(entities["Trip"]?.uniquenessConstraints.isEmpty == true)
        // The V21 fields too: scalars, each optional or defaulted.
        let revision = try #require(temporaryHome.attributesByName["coverageRevision"])
        #expect(revision.attributeType == .integer64AttributeType)
        #expect(revision.isOptional || revision.defaultValue != nil, "CloudKit needs a default")
        let keptTrips = try #require(temporaryHome.attributesByName["keptTripIDs"])
        #expect(keptTrips.attributeType == .stringAttributeType)
        #expect(keptTrips.isOptional || keptTrips.defaultValue != nil, "CloudKit needs a default")
        let stampRevision = try #require(entities["Stay"]?.attributesByName["temporaryHomeRevision"])
        #expect(stampRevision.isOptional)
    }

    @Test("the V15 model set is the V14 set plus HomeAreaOverride")
    func v15IsAdditiveOverV14() {
        let v14 = Set(TravelLogSchemaV14.models.map { String(describing: $0) })
        let v15 = Set(TravelLogSchemaV15.models.map { String(describing: $0) })
        #expect(v14.isSubset(of: v15), "V15 must not drop a V14 entity")
        #expect(v15.subtracting(v14) == ["HomeAreaOverride"])
    }

    @Test("V11 through V15 use the frozen pre-V16 Stay/Trip relationship graph")
    func historicalStayTripGraphsAreFrozen() {
        let frozenStay = ObjectIdentifier(SchemaFrozenModels.Stay.self)
        let frozenTrip = ObjectIdentifier(SchemaFrozenModels.Trip.self)
        let liveStay = ObjectIdentifier(Stay.self)
        let liveTrip = ObjectIdentifier(Trip.self)

        let historicalStays = [
            ObjectIdentifier(TravelLogSchemaV11.Stay.self),
            ObjectIdentifier(TravelLogSchemaV12.Stay.self),
            ObjectIdentifier(TravelLogSchemaV13.Stay.self),
            ObjectIdentifier(TravelLogSchemaV14.Stay.self),
            ObjectIdentifier(TravelLogSchemaV15.Stay.self),
        ]
        let historicalTrips = [
            ObjectIdentifier(TravelLogSchemaV11.Trip.self),
            ObjectIdentifier(TravelLogSchemaV12.Trip.self),
            ObjectIdentifier(TravelLogSchemaV13.Trip.self),
            ObjectIdentifier(TravelLogSchemaV14.Trip.self),
            ObjectIdentifier(TravelLogSchemaV15.Trip.self),
        ]

        #expect(historicalStays.allSatisfy { $0 == frozenStay })
        #expect(historicalTrips.allSatisfy { $0 == frozenTrip })
        #expect(frozenStay != liveStay, "V16 must not mutate historical Stay identity")
        #expect(frozenTrip != liveTrip, "V16 must not mutate historical Trip identity")
    }

    @Test("the V16 model set is the V15 set plus TripTitleVariant")
    func v16AddsLocalizedTitleVariant() {
        let v15 = Set(TravelLogSchemaV15.models.map { String(describing: $0) })
        let v16 = Set(TravelLogSchemaV16.models.map { String(describing: $0) })
        #expect(v15.isSubset(of: v16), "V16 must not drop a V15 entity")
        #expect(v16.subtracting(v15) == ["TripTitleVariant"])
    }

    @Test("the V17 model set is the V16 set plus Visit")
    func v17AddsVisit() {
        let v16 = Set(TravelLogSchemaV16.models.map { String(describing: $0) })
        let v17 = Set(TravelLogSchemaV17.models.map { String(describing: $0) })
        #expect(v16.isSubset(of: v17), "V17 must not drop a V16 entity")
        #expect(v17.subtracting(v16) == ["Visit"])
    }

    @Test("a faithful synthetic V15 store migrates to V16 with Trip/Stay relationships intact")
    func syntheticV15MigratesToV16() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TravelLog-V15-V16-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "migration.sqlite")

        try writeSyntheticV15Store(at: storeURL)

        let currentSchema = Schema(versionedSchema: CurrentTravelLogSchema.self)
        let currentConfiguration = ModelConfiguration(
            "SyntheticV16", schema: currentSchema, url: storeURL,
            cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: currentSchema,
            migrationPlan: TravelLogMigrationPlan.self,
            configurations: [currentConfiguration])
        let context = ModelContext(container)

        let trips = try context.fetch(FetchDescriptor<Trip>())
        let stays = try context.fetch(FetchDescriptor<Stay>())
        let trip = try #require(trips.first)
        let stay = try #require(stays.first)
        #expect(trips.count == 1)
        #expect(stays.count == 1)
        #expect(trip.aiGeneratedTitle == "Athens Weekend")
        #expect(stay.h3IndexRes6 == "synthetic-v15")
        #expect(stay.trip?.id == trip.id)
        #expect(trip.stays?.map(\.id) == [stay.id])
        #expect(trip.titleSourceRevision == nil)
        #expect((trip.localizedTitles ?? []).isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<TripTitleVariant>()) == 0)
    }

    @Test("the V18 model set equals the V17 set (V18 only adds a Stay field)")
    func v18KeepsTheV17EntitySet() {
        let v17 = Set(TravelLogSchemaV17.models.map { String(describing: $0) })
        let v18 = Set(TravelLogSchemaV18.models.map { String(describing: $0) })
        #expect(v17 == v18)
    }

    @Test("V16 and V17 use the frozen pre-V18 Stay/Trip/TripTitleVariant graph")
    func v16AndV17UseTheFrozenGraph() {
        #expect(TravelLogSchemaV16.Stay.self == SchemaFrozenModelsV17.Stay.self)
        #expect(TravelLogSchemaV17.Stay.self == SchemaFrozenModelsV17.Stay.self)
        #expect(TravelLogSchemaV17.Trip.self == SchemaFrozenModelsV17.Trip.self)
        #expect(TravelLogSchemaV17.TripTitleVariant.self == SchemaFrozenModelsV17.TripTitleVariant.self)
        #expect(ObjectIdentifier(SchemaFrozenModelsV17.Stay.self) != ObjectIdentifier(Stay.self),
                "V18 must not mutate the historical Stay identity")
    }

    @Test("a faithful synthetic V17 store migrates to V18 with rows, relationships, and a nil zone")
    func syntheticV17MigratesToV18() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TravelLog-V17-V18-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "migration.sqlite")

        try writeSyntheticV17Store(at: storeURL)

        let currentSchema = Schema(versionedSchema: CurrentTravelLogSchema.self)
        let currentConfiguration = ModelConfiguration(
            "SyntheticV18", schema: currentSchema, url: storeURL,
            cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: currentSchema,
            migrationPlan: TravelLogMigrationPlan.self,
            configurations: [currentConfiguration])
        let context = ModelContext(container)

        let trips = try context.fetch(FetchDescriptor<Trip>())
        let stays = try context.fetch(FetchDescriptor<Stay>())
        let variants = try context.fetch(FetchDescriptor<TripTitleVariant>())
        let visits = try context.fetch(FetchDescriptor<Visit>())
        let trip = try #require(trips.first)
        let stay = try #require(stays.first)
        let variant = try #require(variants.first)
        #expect(trips.count == 1)
        #expect(stays.count == 1)
        #expect(variants.count == 1)
        #expect(visits.count == 1)
        #expect(trip.aiGeneratedTitle == "Athens Weekend")
        #expect(stay.h3IndexRes6 == "synthetic-v17")
        #expect(stay.distanceFromHomeKm == 12.5)
        #expect(stay.timeZoneIdentifier == nil, "pre-V18 rows carry no zone")
        #expect(variant.title == "Σαββατοκύριακο στην Αθήνα")
        #expect(stay.trip?.id == trip.id)
        #expect(trip.stays?.map(\.id) == [stay.id])
        #expect(variant.trip?.id == trip.id)
        #expect(trip.localizedTitles?.map(\.id) == [variant.id])
        #expect(visits.first?.stayID == stay.id)
        // The migrated row accepts the new field and the day count still
        // reads through the device-zone fallback.
        stay.timeZoneIdentifier = "Europe/Athens"
        try context.save()
        #expect(trip.durationDays == 2)
    }

    @Test("the V19 model set is the V18 set plus TemporaryHome")
    func v19AddsTemporaryHome() {
        let v18 = Set(TravelLogSchemaV18.models.map { String(describing: $0) })
        let v19 = Set(TravelLogSchemaV19.models.map { String(describing: $0) })
        #expect(v18.isSubset(of: v19), "V19 must not drop a V18 entity")
        #expect(v19.subtracting(v18) == ["TemporaryHome"])
    }

    @Test("V18 and V19 use the frozen pre-V20 Stay/Trip/TripTitleVariant graph, and V19 the frozen TemporaryHome")
    func v18AndV19UseTheFrozenV19Graph() {
        #expect(TravelLogSchemaV18.Stay.self == SchemaFrozenModelsV19.Stay.self)
        #expect(TravelLogSchemaV18.Trip.self == SchemaFrozenModelsV19.Trip.self)
        #expect(TravelLogSchemaV18.TripTitleVariant.self == SchemaFrozenModelsV19.TripTitleVariant.self)
        #expect(TravelLogSchemaV19.Stay.self == SchemaFrozenModelsV19.Stay.self)
        #expect(TravelLogSchemaV19.Trip.self == SchemaFrozenModelsV19.Trip.self)
        #expect(TravelLogSchemaV19.TripTitleVariant.self == SchemaFrozenModelsV19.TripTitleVariant.self)
        #expect(TravelLogSchemaV19.TemporaryHome.self == SchemaFrozenModelsV19.TemporaryHome.self)
        let frozen: [ObjectIdentifier] = [
            ObjectIdentifier(SchemaFrozenModelsV19.Stay.self),
            ObjectIdentifier(SchemaFrozenModelsV19.Trip.self),
            ObjectIdentifier(SchemaFrozenModelsV19.TripTitleVariant.self),
            ObjectIdentifier(SchemaFrozenModelsV19.TemporaryHome.self),
        ]
        let live: [ObjectIdentifier] = [
            ObjectIdentifier(Stay.self), ObjectIdentifier(Trip.self),
            ObjectIdentifier(TripTitleVariant.self), ObjectIdentifier(TemporaryHome.self),
        ]
        #expect(Set(frozen).isDisjoint(with: live), "V20 must not mutate the historical identities")
        // Every V18 and V19 model is either frozen or a model V20 did not change.
        for schema in [TravelLogSchemaV18.self, TravelLogSchemaV19.self] as [any VersionedSchema.Type] {
            for model in schema.models {
                #expect(!live.contains(ObjectIdentifier(model)),
                        "\(schema) still references the live \(model)")
            }
        }
        // The new fields exist in V20 only.
        func properties(_ schema: any VersionedSchema.Type, _ entity: String) -> Set<String> {
            Set(Schema(versionedSchema: schema).entities
                .first { $0.name == entity }?.properties.map(\.name) ?? [])
        }
        for (entity, field) in [
            ("Stay", "temporaryHomeID"), ("Trip", "keptByTemporaryHome"),
            ("TemporaryHome", "removedAt"),
        ] {
            #expect(!properties(TravelLogSchemaV19.self, entity).contains(field), "\(entity).\(field)")
            #expect(properties(TravelLogSchemaV20.self, entity).contains(field), "\(entity).\(field)")
        }
        #expect(!properties(TravelLogSchemaV18.self, "Stay").contains("temporaryHomeID"))
    }

    @Test("the V20 model set equals the V19 set (V20 only adds fields)")
    func v20KeepsTheV19EntitySet() {
        let v19 = Set(TravelLogSchemaV19.models.map { String(describing: $0) })
        let v20 = Set(TravelLogSchemaV20.models.map { String(describing: $0) })
        #expect(v19 == v20)
    }

    @Test("a synthetic V19 store migrates to V20 keeping a row of every entity, with the new fields at their defaults and writable")
    func syntheticV19MigratesToV20() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TravelLog-V19-V20-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "migration.sqlite")

        try writeSyntheticV19Store(at: storeURL)

        let currentSchema = Schema(versionedSchema: CurrentTravelLogSchema.self)
        let currentConfiguration = ModelConfiguration(
            "SyntheticV20", schema: currentSchema, url: storeURL,
            cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: currentSchema,
            migrationPlan: TravelLogMigrationPlan.self,
            configurations: [currentConfiguration])
        let context = ModelContext(container)

        func count<T: PersistentModel>(_ type: T.Type) throws -> Int {
            try context.fetchCount(FetchDescriptor<T>())
        }
        for type in CurrentTravelLogSchema.models {
            #expect(try count(type) == 1, "\(String(describing: type)) row lost in the V19 to V20 migration")
        }
        let trip = try #require(try context.fetch(FetchDescriptor<Trip>()).first)
        let stay = try #require(try context.fetch(FetchDescriptor<Stay>()).first)
        let variant = try #require(try context.fetch(FetchDescriptor<TripTitleVariant>()).first)
        let temporaryHome = try #require(try context.fetch(FetchDescriptor<TemporaryHome>()).first)
        #expect(trip.aiGeneratedTitle == "Athens Weekend")
        #expect(trip.userEdited)
        #expect(stay.h3IndexRes6 == "synthetic-v19")
        #expect(stay.category == .home)
        #expect(stay.trip?.id == trip.id)
        #expect(trip.stays?.map(\.id) == [stay.id])
        #expect(variant.trip?.id == trip.id)
        #expect(temporaryHome.label == "Erasmus")
        #expect(temporaryHome.endedAt == Date(timeIntervalSince1970: 1_729_958_400))

        // Defaults: no provenance, no keep mark, not removed.
        #expect(stay.temporaryHomeID == nil)
        #expect(!trip.keptByTemporaryHome)
        #expect(temporaryHome.removedAt == nil)
        #expect(try HomeAnchors.temporaryHomes(in: context).map(\.id) == [temporaryHome.id])

        // Each is writable and reads back.
        let removedAt = Date(timeIntervalSince1970: 1_739_958_400)
        stay.temporaryHomeID = temporaryHome.id
        trip.keptByTemporaryHome = true
        temporaryHome.removedAt = removedAt
        try context.save()
        let reread = ModelContext(container)
        #expect(try reread.fetch(FetchDescriptor<Stay>()).first?.temporaryHomeID == temporaryHome.id)
        #expect(try reread.fetch(FetchDescriptor<Trip>()).first?.keptByTemporaryHome == true)
        #expect(try reread.fetch(FetchDescriptor<TemporaryHome>()).first?.removedAt == removedAt)
        #expect(try HomeAnchors.temporaryHomes(in: reread).isEmpty)
    }

    @Test("the V21 model set equals the V20 set (V21 only adds fields)")
    func v21KeepsTheV20EntitySet() {
        let v20 = Set(TravelLogSchemaV20.models.map { String(describing: $0) })
        let v21 = Set(TravelLogSchemaV21.models.map { String(describing: $0) })
        #expect(v20 == v21)
    }

    @Test("V20 uses the frozen pre-V21 Stay/Trip/TripTitleVariant/TemporaryHome graph, and the V21 fields exist in V21 only")
    func v20UsesTheFrozenV20Graph() {
        #expect(TravelLogSchemaV20.Stay.self == SchemaFrozenModelsV20.Stay.self)
        #expect(TravelLogSchemaV20.Trip.self == SchemaFrozenModelsV20.Trip.self)
        #expect(TravelLogSchemaV20.TripTitleVariant.self == SchemaFrozenModelsV20.TripTitleVariant.self)
        #expect(TravelLogSchemaV20.TemporaryHome.self == SchemaFrozenModelsV20.TemporaryHome.self)
        let live: [ObjectIdentifier] = [
            ObjectIdentifier(Stay.self), ObjectIdentifier(Trip.self),
            ObjectIdentifier(TripTitleVariant.self), ObjectIdentifier(TemporaryHome.self),
        ]
        // Every V20 model is either frozen or a model V21 did not change.
        for model in TravelLogSchemaV20.models {
            #expect(!live.contains(ObjectIdentifier(model)),
                    "V20 still references the live \(model)")
        }
        func properties(_ schema: any VersionedSchema.Type, _ entity: String) -> Set<String> {
            Set(Schema(versionedSchema: schema).entities
                .first { $0.name == entity }?.properties.map(\.name) ?? [])
        }
        for entity in ["Stay", "Trip", "TripTitleVariant", "TemporaryHome"] {
            let v20 = properties(TravelLogSchemaV20.self, entity)
            let v21 = properties(TravelLogSchemaV21.self, entity)
            #expect(v20.isSubset(of: v21), "\(entity) must keep every V20 property")
        }
        // The V20 fields are still there; the V21 ones are new.
        for (entity, field) in [
            ("Stay", "temporaryHomeID"), ("Trip", "keptByTemporaryHome"),
            ("TemporaryHome", "removedAt"),
        ] {
            #expect(properties(TravelLogSchemaV20.self, entity).contains(field), "\(entity).\(field)")
        }
        for (entity, field) in [
            ("Stay", "temporaryHomeRevision"), ("TemporaryHome", "coverageRevision"),
            ("TemporaryHome", "keptTripIDs"),
        ] {
            #expect(!properties(TravelLogSchemaV20.self, entity).contains(field), "\(entity).\(field)")
            #expect(properties(TravelLogSchemaV21.self, entity).contains(field), "\(entity).\(field)")
        }
        #expect(properties(TravelLogSchemaV20.self, "Trip") == properties(TravelLogSchemaV21.self, "Trip"))
    }

    @Test("a synthetic V20 store migrates to V21 keeping a row of every entity and the V20 fields, with the new fields at their defaults and writable")
    func syntheticV20MigratesToV21() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TravelLog-V20-V21-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "migration.sqlite")

        let seeded = try writeSyntheticV20Store(at: storeURL)

        let container = try openMigrated(storeURL, name: "SyntheticV21")
        let context = ModelContext(container)
        try expectEveryV20RowSurvived(seeded, in: context)

        let trip = try #require(try context.fetch(FetchDescriptor<Trip>()).first)
        let stay = try #require(try context.fetch(FetchDescriptor<Stay>()).first)
        let live = try #require(try context.fetch(FetchDescriptor<TemporaryHome>())
            .first { $0.id == seeded.liveID })
        // Defaults: revision zero, no kept trips, a pre-V21 stamp.
        #expect(try context.fetch(FetchDescriptor<TemporaryHome>()).allSatisfy {
            $0.coverageRevision == 0 && $0.keptTripIDs.isEmpty
        })
        #expect(stay.temporaryHomeRevision == nil)
        #expect(TemporaryHome.nextCoverageRevision(of: [live]) == 1)

        // Each is writable and reads back.
        live.coverageRevision = 2
        live.addKeptTrip(trip.id)
        stay.setTemporaryHomeProvenance(live.id, revision: 2)
        try context.save()
        let reread = ModelContext(container)
        let rereadLive = try #require(try reread.fetch(FetchDescriptor<TemporaryHome>())
            .first { $0.id == seeded.liveID })
        #expect(rereadLive.coverageRevision == 2)
        #expect(TemporaryHome.keptTripIDs(of: [rereadLive]) == [trip.id])
        let rereadStay = try #require(try reread.fetch(FetchDescriptor<Stay>()).first)
        #expect(rereadStay.temporaryHomeID == seeded.liveID)
        #expect(rereadStay.temporaryHomeRevision == 2)
    }

    @Test("a synthetic V14 store migrates through every stage to V21 keeping a row of every V14 entity, with every later field at its default")
    func syntheticV14MigratesToV21() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TravelLog-V14-V21-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "migration.sqlite")

        try writeSyntheticV14Store(at: storeURL)

        let container = try openMigrated(storeURL, name: "SyntheticV14V21")
        let context = ModelContext(container)
        func count<T: PersistentModel>(_ type: T.Type) throws -> Int {
            try context.fetchCount(FetchDescriptor<T>())
        }
        // V14's Stay and Trip are frozen types; count their current counterparts.
        let v14Names = Set(TravelLogSchemaV14.models.map { String(describing: $0) })
        for type in CurrentTravelLogSchema.models {
            let expected = v14Names.contains(String(describing: type)) ? 1 : 0
            #expect(try count(type) == expected,
                    "\(String(describing: type)) after the V14 to V21 migration")
        }
        let trip = try #require(try context.fetch(FetchDescriptor<Trip>()).first)
        let stay = try #require(try context.fetch(FetchDescriptor<Stay>()).first)
        #expect(trip.aiGeneratedTitle == "Athens Weekend")
        #expect(trip.customName == "Spring in Athens")
        #expect(stay.h3IndexRes6 == "synthetic-v14")
        #expect(stay.trip?.id == trip.id)
        #expect(trip.stays?.map(\.id) == [stay.id])
        #expect(try context.fetch(FetchDescriptor<Home>()).first?.label == "Athens Home")
        // Every field added after V14 reads its default.
        #expect((trip.localizedTitles ?? []).isEmpty)
        #expect(trip.titleSourceRevision == nil)
        #expect(!trip.keptByTemporaryHome)
        #expect(stay.timeZoneIdentifier == nil)
        #expect(stay.temporaryHomeID == nil)
        #expect(stay.temporaryHomeRevision == nil)
    }

    @Test("the widget's read-only, plan-less open reads a store the app migrated to V21, new fields included")
    func widgetOpensTheMigratedStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TravelLog-Widget-V21-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "migration.sqlite")

        let seeded = try writeSyntheticV20Store(at: storeURL)
        try {
            let app = try openMigrated(storeURL, name: "AppV21")
            let context = ModelContext(app)
            let live = try #require(try context.fetch(FetchDescriptor<TemporaryHome>())
                .first { $0.id == seeded.liveID })
            live.coverageRevision = 3
            live.addKeptTrip(seeded.tripID)
            try context.save()
        }()

        let widget = try openAsWidget(storeURL)
        let context = ModelContext(widget)
        try expectEveryV20RowSurvived(seeded, in: context)
        let live = try #require(try context.fetch(FetchDescriptor<TemporaryHome>())
            .first { $0.id == seeded.liveID })
        #expect(live.coverageRevision == 3)
        #expect(live.keptTripIDSet == [seeded.tripID])
        #expect(try context.fetch(FetchDescriptor<Stay>()).first?.temporaryHomeRevision == nil)
    }

    @Test("a widget open that comes before the app's migration fails without touching the V20 store, and the app's migration afterwards keeps every row")
    func widgetBeforeAppLosesNothing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TravelLog-Widget-V20-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "migration.sqlite")

        let seeded = try writeSyntheticV20Store(at: storeURL)
        // The widget's configuration: current schema, read-only, no plan.
        #expect(throws: (any Error).self) { _ = try openAsWidget(storeURL) }
        // The store is still the V20 one: it opens at V20 with every row.
        try {
            let v20 = try ModelContainer(
                for: Schema(versionedSchema: TravelLogSchemaV20.self),
                configurations: [ModelConfiguration(
                    "StillV20", schema: Schema(versionedSchema: TravelLogSchemaV20.self),
                    url: storeURL, allowsSave: false, cloudKitDatabase: .none)])
            let context = ModelContext(v20)
            #expect(try context.fetchCount(FetchDescriptor<TravelLogSchemaV20.Stay>()) == 1)
            #expect(try context.fetchCount(FetchDescriptor<TravelLogSchemaV20.TemporaryHome>()) == 2)
        }()

        let app = try openMigrated(storeURL, name: "AppAfterWidget")
        try expectEveryV20RowSurvived(seeded, in: ModelContext(app))
        let widget = try openAsWidget(storeURL)
        try expectEveryV20RowSurvived(seeded, in: ModelContext(widget))
    }

    @Test("a synthetic V18 store migrates to V19 keeping a row of every entity, with an empty writable TemporaryHome table")
    func syntheticV18MigratesToV19() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TravelLog-V18-V19-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "migration.sqlite")

        try writeSyntheticV18Store(at: storeURL)

        let currentSchema = Schema(versionedSchema: CurrentTravelLogSchema.self)
        let currentConfiguration = ModelConfiguration(
            "SyntheticV19", schema: currentSchema, url: storeURL,
            cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: currentSchema,
            migrationPlan: TravelLogMigrationPlan.self,
            configurations: [currentConfiguration])
        let context = ModelContext(container)

        func count<T: PersistentModel>(_ type: T.Type) throws -> Int {
            try context.fetchCount(FetchDescriptor<T>())
        }
        // V18's Stay, Trip and TripTitleVariant are frozen types; count their
        // current counterparts.
        let v18Names = Set(TravelLogSchemaV18.models.map { String(describing: $0) })
        for type in CurrentTravelLogSchema.models where v18Names.contains(String(describing: type)) {
            #expect(try count(type) == 1, "\(String(describing: type)) row lost in the V18 to V19 migration")
        }
        let trip = try #require(try context.fetch(FetchDescriptor<Trip>()).first)
        let stay = try #require(try context.fetch(FetchDescriptor<Stay>()).first)
        let variant = try #require(try context.fetch(FetchDescriptor<TripTitleVariant>()).first)
        let home = try #require(try context.fetch(FetchDescriptor<Home>()).first)
        let override = try #require(try context.fetch(FetchDescriptor<HomeAreaOverride>()).first)
        #expect(trip.aiGeneratedTitle == "Athens Weekend")
        #expect(stay.h3IndexRes6 == "synthetic-v18")
        #expect(stay.timeZoneIdentifier == "Europe/Athens")
        #expect(stay.trip?.id == trip.id)
        #expect(trip.stays?.map(\.id) == [stay.id])
        #expect(variant.trip?.id == trip.id)
        #expect(home.label == "Athens Home")
        #expect(override.homeID == home.id)

        // The new table exists, starts empty and accepts a row.
        #expect(try context.fetchCount(FetchDescriptor<TemporaryHome>()) == 0)
        context.insert(TemporaryHome(
            label: "Erasmus", latitude: 50.85, longitude: 4.35,
            startedAt: Date(timeIntervalSince1970: 1_719_958_400)))
        try context.save()
        let reread = try ModelContext(container).fetch(FetchDescriptor<TemporaryHome>())
        #expect(reread.map(\.label) == ["Erasmus"])
        #expect(reread.first?.radiusKm == 25)
        #expect(reread.first?.endedAt == nil)
    }

    @Test("a faithful synthetic V16 store migrates to V17 with rows and relationships intact")
    func syntheticV16MigratesToV17() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TravelLog-V16-V17-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "migration.sqlite")

        try writeSyntheticV16Store(at: storeURL)

        let currentSchema = Schema(versionedSchema: CurrentTravelLogSchema.self)
        let currentConfiguration = ModelConfiguration(
            "SyntheticV17", schema: currentSchema, url: storeURL,
            cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: currentSchema,
            migrationPlan: TravelLogMigrationPlan.self,
            configurations: [currentConfiguration])
        let context = ModelContext(container)

        let trips = try context.fetch(FetchDescriptor<Trip>())
        let stays = try context.fetch(FetchDescriptor<Stay>())
        let variants = try context.fetch(FetchDescriptor<TripTitleVariant>())
        let trip = try #require(trips.first)
        let stay = try #require(stays.first)
        let variant = try #require(variants.first)
        #expect(trips.count == 1)
        #expect(stays.count == 1)
        #expect(variants.count == 1)
        #expect(trip.aiGeneratedTitle == "Athens Weekend")
        #expect(stay.h3IndexRes6 == "synthetic-v16")
        #expect(variant.title == "Σαββατοκύριακο στην Αθήνα")
        #expect(stay.trip?.id == trip.id)
        #expect(trip.stays?.map(\.id) == [stay.id])
        #expect(variant.trip?.id == trip.id)
        #expect(trip.localizedTitles?.map(\.id) == [variant.id])
        #expect(try context.fetchCount(FetchDescriptor<Visit>()) == 0)
    }

    @Test("V16 localized-title relationship is inverse-linked and cascades with Trip deletion")
    func localizedTitleRelationshipCascades() throws {
        let container = try TestSupport.makeInMemoryContainer()
        let context = ModelContext(container)
        let trip = Trip(startDate: .now)
        let variant = TripTitleVariant(
            languageTag: "el",
            title: "Αθήνα",
            sourceTitle: "Athens")
        context.insert(trip)
        context.insert(variant)
        trip.localizedTitles = [variant]
        try context.save()

        #expect(variant.trip?.id == trip.id)
        #expect(trip.localizedTitles?.map(\.id) == [variant.id])

        context.delete(trip)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<TripTitleVariant>()) == 0)
    }

    private func writeSyntheticV15Store(at url: URL) throws {
        let schema = Schema(versionedSchema: TravelLogSchemaV15.self)
        let configuration = ModelConfiguration(
            "SyntheticV15", schema: schema, url: url,
            cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let trip = TravelLogSchemaV15.Trip()
        trip.startDate = Date(timeIntervalSince1970: 1_719_958_400)
        trip.endDate = Date(timeIntervalSince1970: 1_720_044_800)
        trip.isComplete = true
        trip.destinationSummary = "Athens"
        trip.aiGeneratedTitle = "Athens Weekend"

        let stay = TravelLogSchemaV15.Stay()
        stay.startTime = trip.startDate
        stay.endTime = trip.endDate ?? trip.startDate
        stay.durationMinutes = 1_440
        stay.h3IndexRes6 = "synthetic-v15"
        stay.pingCount = 2
        stay.categoryRaw = "destination"
        context.insert(trip)
        context.insert(stay)
        stay.trip = trip
        stay.orderInTrip = 0
        trip.stays = [stay]

        try context.save()
    }

    private func writeSyntheticV16Store(at url: URL) throws {
        let schema = Schema(versionedSchema: TravelLogSchemaV16.self)
        let configuration = ModelConfiguration(
            "SyntheticV16", schema: schema, url: url,
            cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        // Frozen V16 shapes (`SchemaFrozenModelsV17`), not the live models:
        // V18 froze this graph, so a store written through the live types
        // would no longer match V16's structural hash.
        let trip = TravelLogSchemaV16.Trip()
        trip.startDate = Date(timeIntervalSince1970: 1_719_958_400)
        trip.endDate = Date(timeIntervalSince1970: 1_720_044_800)
        trip.isComplete = true
        trip.destinationSummary = "Athens"
        trip.aiGeneratedTitle = "Athens Weekend"

        let stay = TravelLogSchemaV16.Stay()
        stay.startTime = trip.startDate
        stay.endTime = trip.endDate ?? trip.startDate
        stay.durationMinutes = 1_440
        stay.centroidLatitude = 37.98
        stay.centroidLongitude = 23.72
        stay.h3IndexRes6 = "synthetic-v16"
        stay.pingCount = 2
        stay.categoryRaw = "destination"

        let variant = TravelLogSchemaV16.TripTitleVariant()
        variant.languageTag = "el"
        variant.title = "Σαββατοκύριακο στην Αθήνα"
        variant.sourceTitle = "Athens Weekend"

        context.insert(trip)
        context.insert(stay)
        context.insert(variant)
        stay.trip = trip
        stay.orderInTrip = 0
        trip.stays = [stay]
        variant.trip = trip
        trip.localizedTitles = [variant]

        try context.save()
    }

    private func writeSyntheticV17Store(at url: URL) throws {
        let schema = Schema(versionedSchema: TravelLogSchemaV17.self)
        let configuration = ModelConfiguration(
            "SyntheticV17", schema: schema, url: url,
            cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let trip = TravelLogSchemaV17.Trip()
        trip.startDate = Date(timeIntervalSince1970: 1_719_958_400)
        trip.endDate = Date(timeIntervalSince1970: 1_720_044_800)
        trip.isComplete = true
        trip.destinationSummary = "Athens"
        trip.aiGeneratedTitle = "Athens Weekend"
        trip.titleSourceRevision = UUID()

        let stay = TravelLogSchemaV17.Stay()
        stay.startTime = trip.startDate
        stay.endTime = trip.endDate ?? trip.startDate
        stay.durationMinutes = 1_440
        stay.centroidLatitude = 37.98
        stay.centroidLongitude = 23.72
        stay.h3IndexRes6 = "synthetic-v17"
        stay.pingCount = 2
        stay.distanceFromHomeKm = 12.5
        stay.categoryRaw = "destination"

        let variant = TravelLogSchemaV17.TripTitleVariant()
        variant.languageTag = "el"
        variant.title = "Σαββατοκύριακο στην Αθήνα"
        variant.sourceTitle = "Athens Weekend"
        variant.sourceRevision = trip.titleSourceRevision

        let visit = Visit(
            arrivalDate: trip.startDate,
            departureDate: trip.endDate,
            latitude: 37.98, longitude: 23.72,
            horizontalAccuracy: 20,
            receivedAt: trip.startDate)
        visit.stayID = stay.id

        context.insert(trip)
        context.insert(stay)
        context.insert(variant)
        context.insert(visit)
        stay.trip = trip
        stay.orderInTrip = 0
        trip.stays = [stay]
        variant.trip = trip
        trip.localizedTitles = [variant]

        try context.save()
    }

    /// One row of every V18 entity. Stay, Trip and TripTitleVariant are the
    /// frozen V18 shapes (`SchemaFrozenModelsV19`); V20 changed the live ones.
    /// The other models are live and unchanged since V18.
    private func writeSyntheticV18Store(at url: URL) throws {
        let schema = Schema(versionedSchema: TravelLogSchemaV18.self)
        let configuration = ModelConfiguration(
            "SyntheticV18", schema: schema, url: url,
            cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_719_958_400)

        let trip = TravelLogSchemaV18.Trip()
        trip.startDate = base
        trip.aiGeneratedTitle = "Athens Weekend"
        let variant = TravelLogSchemaV18.TripTitleVariant()
        variant.languageTag = "el"
        variant.title = "Σαββατοκύριακο στην Αθήνα"
        variant.sourceTitle = "Athens Weekend"
        let stay = TravelLogSchemaV18.Stay()
        stay.startTime = base
        stay.endTime = base.addingTimeInterval(3_600)
        stay.durationMinutes = 60
        stay.centroidLatitude = 37.98
        stay.centroidLongitude = 23.72
        stay.h3IndexRes6 = "synthetic-v18"
        stay.pingCount = 2
        stay.distanceFromHomeKm = 12.5
        stay.categoryRaw = "destination"
        stay.timeZoneIdentifier = "Europe/Athens"
        context.insert(trip)
        context.insert(variant)
        context.insert(stay)
        stay.trip = trip
        stay.orderInTrip = 0
        trip.stays = [stay]
        variant.trip = trip
        trip.localizedTitles = [variant]
        context.insert(LocationPing(
            timestamp: base, latitude: 37.98, longitude: 23.72,
            horizontalAccuracy: 30, h3IndexRes6: "synthetic-v18", source: .liveSLC))
        context.insert(HexVisit(
            h3Index: "synthetic-v18", firstVisited: base,
            centerLatitude: 37.98, centerLongitude: 23.72))
        context.insert(HiddenPhoto(localIdentifier: "asset-1", tripID: trip.id))
        context.insert(PinnedPhoto(localIdentifier: "asset-2", tripID: trip.id))
        context.insert(PhotoImportState(originDeviceID: "device-A"))
        context.insert(YearWrapped(year: 2023))
        context.insert(PlannedTrip(
            eventExternalIdentifier: "ext-1", eventLocalIdentifier: "loc-1",
            title: "Cephalonia", startDate: base, endDate: base.addingTimeInterval(86_400),
            isAllDay: false, locationText: nil))
        let home = Home(label: "Athens Home", latitude: 37.98, longitude: 23.72,
                        radiusKm: 25, startedAt: base)
        context.insert(home)
        context.insert(HomeAreaOverride(
            kind: .include, centerLatitude: 37.99, centerLongitude: 23.73,
            radiusKm: 1, homeID: home.id))
        context.insert(Visit(
            arrivalDate: base, departureDate: base.addingTimeInterval(3_600),
            latitude: 37.98, longitude: 23.72, horizontalAccuracy: 30,
            receivedAt: base.addingTimeInterval(3_600)))
        context.insert(RoutinePlace(label: "Office", latitude: 37.97, longitude: 23.71))

        try context.save()
    }

    /// One row of every V19 entity, Stay, Trip, TripTitleVariant and
    /// TemporaryHome through the frozen V19 shapes (`SchemaFrozenModelsV19`).
    private func writeSyntheticV19Store(at url: URL) throws {
        let schema = Schema(versionedSchema: TravelLogSchemaV19.self)
        let configuration = ModelConfiguration(
            "SyntheticV19", schema: schema, url: url,
            cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_719_958_400)

        let trip = TravelLogSchemaV19.Trip()
        trip.startDate = base
        trip.endDate = base.addingTimeInterval(86_400)
        trip.isComplete = true
        trip.userEdited = true
        trip.aiGeneratedTitle = "Athens Weekend"
        let variant = TravelLogSchemaV19.TripTitleVariant()
        variant.languageTag = "el"
        variant.title = "Σαββατοκύριακο στην Αθήνα"
        variant.sourceTitle = "Athens Weekend"
        let stay = TravelLogSchemaV19.Stay()
        stay.startTime = base
        stay.endTime = base.addingTimeInterval(3_600)
        stay.durationMinutes = 60
        stay.centroidLatitude = 50.85
        stay.centroidLongitude = 4.35
        stay.h3IndexRes6 = "synthetic-v19"
        stay.pingCount = 2
        stay.categoryRaw = "home"
        stay.timeZoneIdentifier = "Europe/Brussels"
        let temporaryHome = TravelLogSchemaV19.TemporaryHome()
        temporaryHome.label = "Erasmus"
        temporaryHome.latitude = 50.85
        temporaryHome.longitude = 4.35
        temporaryHome.startedAt = base.addingTimeInterval(-30 * 86_400)
        temporaryHome.endedAt = Date(timeIntervalSince1970: 1_729_958_400)
        context.insert(trip)
        context.insert(variant)
        context.insert(stay)
        context.insert(temporaryHome)
        stay.trip = trip
        stay.orderInTrip = 0
        trip.stays = [stay]
        variant.trip = trip
        trip.localizedTitles = [variant]
        context.insert(LocationPing(
            timestamp: base, latitude: 50.85, longitude: 4.35,
            horizontalAccuracy: 30, h3IndexRes6: "synthetic-v19", source: .liveSLC))
        context.insert(HexVisit(
            h3Index: "synthetic-v19", firstVisited: base,
            centerLatitude: 50.85, centerLongitude: 4.35))
        context.insert(HiddenPhoto(localIdentifier: "asset-1", tripID: trip.id))
        context.insert(PinnedPhoto(localIdentifier: "asset-2", tripID: trip.id))
        context.insert(PhotoImportState(originDeviceID: "device-A"))
        context.insert(YearWrapped(year: 2023))
        context.insert(PlannedTrip(
            eventExternalIdentifier: "ext-1", eventLocalIdentifier: "loc-1",
            title: "Cephalonia", startDate: base, endDate: base.addingTimeInterval(86_400),
            isAllDay: false, locationText: nil))
        let home = Home(label: "Athens Home", latitude: 37.98, longitude: 23.72,
                        radiusKm: 25, startedAt: base)
        context.insert(home)
        context.insert(HomeAreaOverride(
            kind: .include, centerLatitude: 50.86, centerLongitude: 4.36,
            radiusKm: 1, homeID: temporaryHome.id))
        context.insert(Visit(
            arrivalDate: base, departureDate: base.addingTimeInterval(3_600),
            latitude: 50.85, longitude: 4.35, horizontalAccuracy: 30,
            receivedAt: base.addingTimeInterval(3_600)))
        context.insert(RoutinePlace(label: "Office", latitude: 37.97, longitude: 23.71))

        try context.save()
    }

    /// The ids `writeSyntheticV20Store` wrote, for the checks after migration.
    private struct SeededV20 {
        let tripID: UUID
        let stayID: UUID
        let variantID: UUID
        let liveID: UUID
        let removedID: UUID
        let removedAt: Date
    }

    /// One row of every V20 entity (two temporary homes: a live one that
    /// stamped the stay and a removed one), Stay, Trip, TripTitleVariant and
    /// TemporaryHome through the frozen V20 shapes (`SchemaFrozenModelsV20`),
    /// with every V20 field set.
    private func writeSyntheticV20Store(at url: URL) throws -> SeededV20 {
        let schema = Schema(versionedSchema: TravelLogSchemaV20.self)
        let configuration = ModelConfiguration(
            "SyntheticV20", schema: schema, url: url,
            cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_719_958_400)

        let live = TravelLogSchemaV20.TemporaryHome()
        live.label = "Erasmus"
        live.latitude = 50.85
        live.longitude = 4.35
        live.startedAt = base.addingTimeInterval(-30 * 86_400)
        let removed = TravelLogSchemaV20.TemporaryHome()
        removed.label = "Old flat"
        removed.latitude = 38.72
        removed.longitude = -9.14
        removed.startedAt = base.addingTimeInterval(-400 * 86_400)
        removed.removedAt = base.addingTimeInterval(-200 * 86_400)
        let trip = TravelLogSchemaV20.Trip()
        trip.startDate = base
        trip.endDate = base.addingTimeInterval(86_400)
        trip.isComplete = true
        trip.userEdited = true
        trip.keptByTemporaryHome = true
        trip.aiGeneratedTitle = "Brussels Weekend"
        let variant = TravelLogSchemaV20.TripTitleVariant()
        variant.languageTag = "el"
        variant.title = "Σαββατοκύριακο στις Βρυξέλλες"
        variant.sourceTitle = "Brussels Weekend"
        let stay = TravelLogSchemaV20.Stay()
        stay.startTime = base
        stay.endTime = base.addingTimeInterval(3_600)
        stay.durationMinutes = 60
        stay.centroidLatitude = 50.85
        stay.centroidLongitude = 4.35
        stay.h3IndexRes6 = "synthetic-v20"
        stay.pingCount = 2
        stay.categoryRaw = "home"
        stay.temporaryHomeID = live.id
        stay.timeZoneIdentifier = "Europe/Brussels"
        for row in [live, removed] { context.insert(row) }
        context.insert(trip)
        context.insert(variant)
        context.insert(stay)
        stay.trip = trip
        stay.orderInTrip = 0
        trip.stays = [stay]
        variant.trip = trip
        trip.localizedTitles = [variant]
        context.insert(LocationPing(
            timestamp: base, latitude: 50.85, longitude: 4.35,
            horizontalAccuracy: 30, h3IndexRes6: "synthetic-v20", source: .liveSLC))
        context.insert(HexVisit(
            h3Index: "synthetic-v20", firstVisited: base,
            centerLatitude: 50.85, centerLongitude: 4.35))
        context.insert(HiddenPhoto(localIdentifier: "asset-1", tripID: trip.id))
        context.insert(PinnedPhoto(localIdentifier: "asset-2", tripID: trip.id))
        context.insert(PhotoImportState(originDeviceID: "device-A"))
        context.insert(YearWrapped(year: 2023))
        context.insert(PlannedTrip(
            eventExternalIdentifier: "ext-1", eventLocalIdentifier: "loc-1",
            title: "Cephalonia", startDate: base, endDate: base.addingTimeInterval(86_400),
            isAllDay: false, locationText: nil))
        context.insert(Home(label: "Athens Home", latitude: 37.98, longitude: 23.72,
                            radiusKm: 25, startedAt: base))
        context.insert(HomeAreaOverride(
            kind: .include, centerLatitude: 50.86, centerLongitude: 4.36,
            radiusKm: 1, homeID: live.id))
        context.insert(Visit(
            arrivalDate: base, departureDate: base.addingTimeInterval(3_600),
            latitude: 50.85, longitude: 4.35, horizontalAccuracy: 30,
            receivedAt: base.addingTimeInterval(3_600)))
        context.insert(RoutinePlace(label: "Office", latitude: 37.97, longitude: 23.71))

        try context.save()
        return SeededV20(
            tripID: trip.id, stayID: stay.id, variantID: variant.id,
            liveID: live.id, removedID: removed.id,
            removedAt: try #require(removed.removedAt))
    }

    /// Every row `writeSyntheticV20Store` wrote is there with its V20 fields
    /// and relationships, read through the current models.
    private func expectEveryV20RowSurvived(_ seeded: SeededV20, in context: ModelContext) throws {
        func count<T: PersistentModel>(_ type: T.Type) throws -> Int {
            try context.fetchCount(FetchDescriptor<T>())
        }
        for type in CurrentTravelLogSchema.models {
            let expected = type == TemporaryHome.self ? 2 : 1
            #expect(try count(type) == expected,
                    "\(String(describing: type)) rows after the V20 to V21 migration")
        }
        let trip = try #require(try context.fetch(FetchDescriptor<Trip>()).first)
        let stay = try #require(try context.fetch(FetchDescriptor<Stay>()).first)
        let variant = try #require(try context.fetch(FetchDescriptor<TripTitleVariant>()).first)
        let rows = try context.fetch(FetchDescriptor<TemporaryHome>())
        #expect(trip.id == seeded.tripID)
        #expect(trip.userEdited && trip.keptByTemporaryHome)
        #expect(trip.aiGeneratedTitle == "Brussels Weekend")
        #expect(stay.id == seeded.stayID)
        #expect(stay.h3IndexRes6 == "synthetic-v20")
        #expect(stay.category == .home)
        #expect(stay.temporaryHomeID == seeded.liveID)
        #expect(stay.timeZoneIdentifier == "Europe/Brussels")
        #expect(stay.trip?.id == trip.id)
        #expect(trip.stays?.map(\.id) == [stay.id])
        #expect(variant.id == seeded.variantID)
        #expect(variant.trip?.id == trip.id)
        #expect(rows.first { $0.id == seeded.liveID }?.label == "Erasmus")
        #expect(rows.first { $0.id == seeded.removedID }?.removedAt == seeded.removedAt)
        #expect(try HomeAnchors.temporaryHomes(in: context).map(\.id) == [seeded.liveID])
    }

    /// One row of every V14 entity. Stay and Trip are the frozen V11 to V15
    /// shapes (`SchemaFrozenModels`); the other models are live and unchanged
    /// since V14.
    private func writeSyntheticV14Store(at url: URL) throws {
        let schema = Schema(versionedSchema: TravelLogSchemaV14.self)
        let configuration = ModelConfiguration(
            "SyntheticV14", schema: schema, url: url,
            cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_719_958_400)

        let trip = TravelLogSchemaV14.Trip()
        trip.startDate = base
        trip.endDate = base.addingTimeInterval(86_400)
        trip.isComplete = true
        trip.customName = "Spring in Athens"
        trip.aiGeneratedTitle = "Athens Weekend"
        let stay = TravelLogSchemaV14.Stay()
        stay.startTime = base
        stay.endTime = base.addingTimeInterval(3_600)
        stay.durationMinutes = 60
        stay.centroidLatitude = 37.98
        stay.centroidLongitude = 23.72
        stay.h3IndexRes6 = "synthetic-v14"
        stay.pingCount = 2
        stay.categoryRaw = "destination"
        context.insert(trip)
        context.insert(stay)
        stay.trip = trip
        stay.orderInTrip = 0
        trip.stays = [stay]
        context.insert(LocationPing(
            timestamp: base, latitude: 37.98, longitude: 23.72,
            horizontalAccuracy: 30, h3IndexRes6: "synthetic-v14", source: .liveSLC))
        context.insert(HexVisit(
            h3Index: "synthetic-v14", firstVisited: base,
            centerLatitude: 37.98, centerLongitude: 23.72))
        context.insert(HiddenPhoto(localIdentifier: "asset-1", tripID: trip.id))
        context.insert(PinnedPhoto(localIdentifier: "asset-2", tripID: trip.id))
        context.insert(PhotoImportState(originDeviceID: "device-A"))
        context.insert(YearWrapped(year: 2023))
        context.insert(PlannedTrip(
            eventExternalIdentifier: "ext-1", eventLocalIdentifier: "loc-1",
            title: "Cephalonia", startDate: base, endDate: base.addingTimeInterval(86_400),
            isAllDay: false, locationText: nil))
        context.insert(Home(label: "Athens Home", latitude: 37.98, longitude: 23.72,
                            radiusKm: 25, startedAt: base))
        context.insert(RoutinePlace(label: "Office", latitude: 37.97, longitude: 23.71))

        try context.save()
    }

    /// The app's open: current schema with the staged plan.
    private func openMigrated(_ url: URL, name: String) throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentTravelLogSchema.self)
        return try ModelContainer(
            for: schema,
            migrationPlan: TravelLogMigrationPlan.self,
            configurations: [ModelConfiguration(
                name, schema: schema, url: url, cloudKitDatabase: .none)])
    }

    /// The widget's open (`SharedModelContainer.makeContainer`): current
    /// schema, read-only, no migration plan, no CloudKit.
    private func openAsWidget(_ url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: CurrentTravelLogSchema.self)
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                "TravelLog", schema: schema, url: url, allowsSave: false,
                cloudKitDatabase: .none)])
    }

    // MARK: - Captured-store V14→CURRENT replay (fixture-gated, same contract as
    // the home-shape replays: skips honestly without TRAVELLOG_REAL_FIXTURE)

    nonisolated private static var fixtureURL: URL? {
        guard let raw = ProcessInfo.processInfo.environment["TRAVELLOG_REAL_FIXTURE"],
              !raw.isEmpty else { return nil }
        let url = URL(fileURLWithPath: raw)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func openCopy(
        label: String, schema: Schema, plan: (any SchemaMigrationPlan.Type)?
    ) throws -> (ModelContainer, URL) {
        let fixture = try #require(Self.fixtureURL, "TRAVELLOG_REAL_FIXTURE unset")
        let configuration = ModelConfiguration(
            "\(label)-\(UUID().uuidString)", schema: schema,
            isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        do {
            try TestSupport.copyStoreFamily(from: fixture, to: configuration.url)
            let container: ModelContainer
            if let plan {
                container = try ModelContainer(for: schema, migrationPlan: plan,
                                               configurations: [configuration])
            } else {
                container = try ModelContainer(for: schema, configurations: [configuration])
            }
            return (container, configuration.url)
        } catch {
            // A failed copy/open leaves no orphaned store family behind -
            // the caller's cleanup `defer` never gets to run on this path.
            TestSupport.removeStoreFamily(at: configuration.url)
            throw error
        }
    }

    @Test("a captured V14 store migrates to current losing no rows, and new entities are fetchable", .enabled(
        if: MigrationChainTests.fixtureURL != nil,
        "Point TRAVELLOG_REAL_FIXTURE at a captured V14 store to run the migration replay"
    ))
    func realStoreMigratesV14ToCurrentLosslessly() throws {
        // Ground truth: the same store family read at its native V14.
        let (v14Container, v14URL) = try openCopy(
            label: "MigrationGroundTruth",
            schema: Schema(versionedSchema: TravelLogSchemaV14.self),
            plan: nil)
        defer { TestSupport.removeStoreFamily(at: v14URL) }
        let v14 = ModelContext(v14Container)
        // Count every V14 entity: a migration that silently emptied
        // PlannedTrip or the photo
        // annotations would have satisfied a five-table check.
        func v14Counts(in context: ModelContext) throws -> [String: Int] {
            [
                "Stay": try context.fetchCount(FetchDescriptor<TravelLogSchemaV14.Stay>()),
                "Trip": try context.fetchCount(FetchDescriptor<TravelLogSchemaV14.Trip>()),
                "LocationPing": try context.fetchCount(FetchDescriptor<LocationPing>()),
                "Home": try context.fetchCount(FetchDescriptor<Home>()),
                "RoutinePlace": try context.fetchCount(FetchDescriptor<RoutinePlace>()),
                "HexVisit": try context.fetchCount(FetchDescriptor<HexVisit>()),
                "HiddenPhoto": try context.fetchCount(FetchDescriptor<HiddenPhoto>()),
                "PinnedPhoto": try context.fetchCount(FetchDescriptor<PinnedPhoto>()),
                "PhotoImportState": try context.fetchCount(FetchDescriptor<PhotoImportState>()),
                "YearWrapped": try context.fetchCount(FetchDescriptor<YearWrapped>()),
                "PlannedTrip": try context.fetchCount(FetchDescriptor<PlannedTrip>()),
            ]
        }
        let v14Counts = try v14Counts(in: v14)
        try #require((v14Counts["Stay"] ?? 0) > 0 && (v14Counts["Trip"] ?? 0) > 0
                        && (v14Counts["LocationPing"] ?? 0) > 0,
                     "fixture unexpectedly empty — ground truth is meaningless")

        // The migration under test: a second pristine copy opened at CURRENT
        // with the real plan - exactly what AppDelegate's plan-bearing open
        // does on the first launch after an app update.
        let (migrated, migratedURL) = try openCopy(
            label: "MigrationV14toCurrent",
            schema: Schema(versionedSchema: CurrentTravelLogSchema.self),
            plan: TravelLogMigrationPlan.self)
        defer { TestSupport.removeStoreFamily(at: migratedURL) }
        let current = ModelContext(migrated)

        func currentCounts(in context: ModelContext) throws -> [String: Int] {
            [
                "Stay": try context.fetchCount(FetchDescriptor<Stay>()),
                "Trip": try context.fetchCount(FetchDescriptor<Trip>()),
                "LocationPing": try context.fetchCount(FetchDescriptor<LocationPing>()),
                "Home": try context.fetchCount(FetchDescriptor<Home>()),
                "RoutinePlace": try context.fetchCount(FetchDescriptor<RoutinePlace>()),
                "HexVisit": try context.fetchCount(FetchDescriptor<HexVisit>()),
                "HiddenPhoto": try context.fetchCount(FetchDescriptor<HiddenPhoto>()),
                "PinnedPhoto": try context.fetchCount(FetchDescriptor<PinnedPhoto>()),
                "PhotoImportState": try context.fetchCount(FetchDescriptor<PhotoImportState>()),
                "YearWrapped": try context.fetchCount(FetchDescriptor<YearWrapped>()),
                "PlannedTrip": try context.fetchCount(FetchDescriptor<PlannedTrip>()),
            ]
        }
        let currentCounts = try currentCounts(in: current)
        for (entity, before) in v14Counts.sorted(by: { $0.key < $1.key }) {
            #expect(currentCounts[entity] == before,
                    "\(entity): \(before) rows at V14 → \(currentCounts[entity] ?? -1) after migration")
        }

        // Post-V14 entities exist and start empty on this V14 store.
        #expect(try current.fetchCount(FetchDescriptor<HomeAreaOverride>()) == 0)
        #expect(try current.fetchCount(FetchDescriptor<TripTitleVariant>()) == 0)
        #expect(try current.fetchCount(FetchDescriptor<Visit>()) == 0)
        #expect(try current.fetchCount(FetchDescriptor<TemporaryHome>()) == 0)
        // Post-V14 fields read their defaults on every row: no provenance pair
        // (V20, V21) and no keep mark (V20).
        #expect(try current.fetchCount(FetchDescriptor<Stay>(predicate: #Predicate {
            $0.temporaryHomeID != nil || $0.temporaryHomeRevision != nil
        })) == 0)
        #expect(try current.fetchCount(FetchDescriptor<Trip>(predicate: #Predicate {
            $0.keptByTemporaryHome
        })) == 0)

        // Spot-check that migrated rows keep their non-default values: every
        // fetched stay keeps a non-empty H3 index and a positive ping count,
        // and relationships survive (some stay still belongs to a trip).
        var probe = FetchDescriptor<Stay>(sortBy: [SortDescriptor(\.startTime)])
        probe.fetchLimit = 50
        let stays = try current.fetch(probe)
        #expect(!stays.isEmpty)
        #expect(stays.allSatisfy { !$0.h3IndexRes6.isEmpty && $0.pingCount > 0 })
        let tripMembers = try current.fetchCount(FetchDescriptor<Stay>(
            predicate: #Predicate { $0.trip != nil }))
        #expect(tripMembers > 0, "trip relationships must survive migration")
    }
}
}
