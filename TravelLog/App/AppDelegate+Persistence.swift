//
//  AppDelegate+Persistence.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//

import UIKit
import SwiftData
import BackgroundTasks
import UserNotifications
import WidgetKit
import CoreLocation
import CoreData
import os.log

extension AppDelegate {

    /// App Group identifier shared with the widget extension.
    /// Both the main app and the widget read/write the SwiftData store here.
    nonisolated static let appGroupIdentifier = "group.com.kfragkoulis.TravelLog"

    /// CloudKit container holding the synced store (matches the entitlements).
    nonisolated static let cloudKitContainerIdentifier = "iCloud.com.kfragkoulis.TravelLog"

    /// UserDefaults key for the user's iCloud sync preference.
    /// When true, the ModelContainer uses CloudKit's private database.
    /// Changing this requires an app restart (ModelContainer is static let).
    nonisolated static let iCloudSyncEnabledKey = "iCloudSyncEnabled"

    /// Last schema version successfully opened with the migration plan.
    /// Compare against `CurrentTravelLogSchema.versionIdentifier` so each schema bump
    /// re-arms migration while steady-state launches skip the redundant store open.
    nonisolated static let lastMigratedSchemaVersionKey = "lastMigratedSchemaVersion"

    /// Stores the last CloudKit setup error for display in Settings.
    nonisolated static let lastCloudKitErrorKey = "lastCloudKitError"

    /// How the process-wide SwiftData container was opened. Error payloads are
    /// strings rather than `Error` existentials so the value remains Sendable
    /// and can be read safely from any isolation domain.
    nonisolated enum ContainerMode: Equatable, Sendable {
        case persisted
        case localFallback(errorDescription: String)
        case inMemory(errorDescription: String)

        nonisolated var isPersistent: Bool {
            if case .inMemory = self { return false }
            return true
        }

        nonisolated var errorDescription: String? {
            switch self {
            case .persisted: nil
            case .localFallback(let description), .inMemory(let description): description
            }
        }
    }

    nonisolated private static let containerModeStorage =
        OSAllocatedUnfairLock(initialState: ContainerMode.persisted)

    /// Synchronous diagnostic/UI surface for the static container initializer.
    nonisolated static var containerMode: ContainerMode {
        containerModeStorage.withLock { $0 }
    }

    private nonisolated static func recordContainerMode(_ mode: ContainerMode) {
        containerModeStorage.withLock { $0 = mode }
    }

    /// The shared ModelContainer, initialized once and shared with the SwiftUI environment.
    ///
    /// Uses `TravelLogMigrationPlan` to handle schema evolution across app updates.
    /// If migration fails (corrupted store, unexpected schema), falls back to in-memory
    /// storage so the app can present an explicit recovery state. The on-disk store is
    /// NEVER deleted - a future update or manual recovery can still access it.
    ///
    /// The store lives in the App Groups container so the widget extension can read it.
    nonisolated static let modelContainer: ModelContainer = {
        let logger = Logger(subsystem: "com.travellog.app", category: "ModelContainer")
        let schema = Schema(versionedSchema: CurrentTravelLogSchema.self)

        let storeMoveOutcome = migrateStoreToAppGroupIfNeeded(
            schema: schema, logger: logger)
        let useLegacyStoreForSession =
            storeOpeningLocation(after: storeMoveOutcome) == .legacy

        // Run pending schema migrations locally BEFORE attempting CloudKit.
        // CloudKit containers have known issues with migration plans (FB13711459)
        // where willMigrate/didMigrate callbacks never fire. Running migrations
        // locally first ensures the store is at the latest schema version.
        let localConfig: ModelConfiguration
        if useLegacyStoreForSession {
            // The App-Group move failed before a complete destination store
            // existed. Keep the preserved legacy store visible this session;
            // because no destination main file is created, launch retries the
            // move next time.
            localConfig = ModelConfiguration(
                "TravelLog",
                schema: schema,
                isStoredInMemoryOnly: false,
                groupContainer: .none,
                cloudKitDatabase: .none
            )
        } else {
            localConfig = ModelConfiguration(
                "TravelLog",
                schema: schema,
                isStoredInMemoryOnly: false,
                groupContainer: .identifier(appGroupIdentifier),
                cloudKitDatabase: .none
            )
        }

        // Create Application Support before opening the App-Group store on a fresh install;
        // the read-only widget cannot recover by creating the missing directory.
        ensureStoreDirectoryExists(for: localConfig, logger: logger)

        // A committed Delete All Data may have left this device's obsolete
        // pre-App-Group family pending removal. Retire it only after a
        // persistent App Group container actually opened; never in a legacy
        // session or the in-memory fallback.
        func openedPersistent(_ container: ModelContainer) -> ModelContainer {
            if !useLegacyStoreForSession {
                retireObsoleteStoreFamilyIfPending(
                    legacyURL: legacyStoreURL(schema: schema),
                    activeURL: container.configurations.first?.url ?? localConfig.url,
                    logger: logger)
            }
            return container
        }

        let iCloudEnabled = UserDefaults.standard.bool(forKey: iCloudSyncEnabledKey)
        var persistentMode = ContainerMode.persisted
        logger.info("iCloud sync preference: \(iCloudEnabled)")

        // Run the migration plan when the stored schema version differs.
        // If a gated plan-less open fails, clear the key and retry once with the plan.
        let currentSchemaVersion = CurrentTravelLogSchema.versionIdentifier.description
        let needsMigrationPass =
            UserDefaults.standard.string(forKey: lastMigratedSchemaVersionKey) != currentSchemaVersion

        if needsMigrationPass {
            do {
                let migrated = try ModelContainer(
                    for: schema,
                    migrationPlan: TravelLogMigrationPlan.self,
                    configurations: [localConfig]
                )
                UserDefaults.standard.set(currentSchemaVersion, forKey: lastMigratedSchemaVersionKey)
                logger.info("Schema migration pass complete (\(currentSchemaVersion)).")
                if !iCloudEnabled {
                    // Single-open fast path: this container IS the final
                    // local-only container — no reason to close and reopen
                    // the identical configuration without the plan.
                    recordContainerMode(.persisted)
                    return openedPersistent(migrated)
                }
                // iCloud path: `migrated` releases here (scope end), closing
                // the store so the CloudKit-backed open below reopens the
                // already-migrated file. CloudKit containers cannot take the
                // plan themselves (FB13711459 — callbacks never fire).
            } catch {
                logger.error("Schema pre-migration failed: \(error.localizedDescription)")
            }
        }

        if iCloudEnabled {
            let cloudConfig: ModelConfiguration
            if useLegacyStoreForSession {
                cloudConfig = ModelConfiguration(
                    "TravelLog",
                    schema: schema,
                    isStoredInMemoryOnly: false,
                    groupContainer: .none,
                    cloudKitDatabase: .private(cloudKitContainerIdentifier)
                )
            } else {
                cloudConfig = ModelConfiguration(
                    "TravelLog",
                    schema: schema,
                    isStoredInMemoryOnly: false,
                    groupContainer: .identifier(appGroupIdentifier),
                    cloudKitDatabase: .private(cloudKitContainerIdentifier)
                )
            }
            do {
                let container = try ModelContainer(
                    for: schema,
                    configurations: [cloudConfig]
                )
                UserDefaults.standard.removeObject(forKey: lastCloudKitErrorKey)
                recordContainerMode(.persisted)
                return openedPersistent(container)
            } catch {
                let errorDetail = String(describing: error)
                logger.error("CloudKit ModelContainer failed: \(errorDetail). Disabling iCloud sync and falling back to local-only.")
                UserDefaults.standard.set(false, forKey: iCloudSyncEnabledKey)
                UserDefaults.standard.set(errorDetail, forKey: lastCloudKitErrorKey)
                persistentMode = .localFallback(errorDescription: errorDetail)
            }
        }

        do {
            let container = try ModelContainer(
                for: schema,
                configurations: [localConfig]
            )
            recordContainerMode(persistentMode)
            return openedPersistent(container)
        } catch {
            // If the skipped migration pass left a plan-less open failing, clear the gate
            // and retry with the plan before falling back to an in-memory store.
            if !needsMigrationPass {
                logger.error("Plan-less open failed after gated migration skip: \(error.localizedDescription). Retrying with migration plan.")
                UserDefaults.standard.removeObject(forKey: lastMigratedSchemaVersionKey)
                if let migrated = try? ModelContainer(
                    for: schema,
                    migrationPlan: TravelLogMigrationPlan.self,
                    configurations: [localConfig]
                ) {
                    UserDefaults.standard.set(currentSchemaVersion, forKey: lastMigratedSchemaVersionKey)
                    recordContainerMode(persistentMode)
                    return openedPersistent(migrated)
                }
            }
            let errorDetail = String(describing: error)
            logger.critical("ModelContainer creation failed: \(error.localizedDescription). Falling back to in-memory storage. On-disk store preserved at: \(localConfig.url.path)")
            do {
                // Keep the in-memory fallback independent of failable App-Group resolution.
                let container = try ModelContainer(
                    for: schema,
                    configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
                )
                recordContainerMode(.inMemory(errorDescription: errorDetail))
                return container
            } catch {
                // If even the in-memory schema cannot be realized, no usable container remains;
                // trap with a descriptive message.
                logger.critical("In-memory ModelContainer fallback also failed: \(error.localizedDescription)")
                fatalError("SwiftData unusable — cannot create an in-memory container: \(error)")
            }
        }
    }()

    #if DEBUG
    /// DEBUG-only, read-only migration diagnostic: model counts and HexVisit UUID distinctness.
    /// Latched once per install to avoid repeated full-table scans; clear the key to rerun.
    nonisolated static func logMigrationDiagnostic() {
        let gateKey = "debugMigrationDiagnosticLogged_v12"
        guard !UserDefaults.standard.bool(forKey: gateKey) else { return }
        UserDefaults.standard.set(true, forKey: gateKey)
        let logger = Logger(subsystem: "com.travellog.app", category: "MigrationDiagnostic")
        let ctx = ModelContext(modelContainer)
        func ct<T: PersistentModel>(_ t: T.Type) -> Int {
            (try? ctx.fetchCount(FetchDescriptor<T>())) ?? -1
        }
        // Distinctness only needs `id` — don't materialize full rows.
        var hexDescriptor = FetchDescriptor<HexVisit>()
        hexDescriptor.propertiesToFetch = [\.id]
        let hexes = (try? ctx.fetch(hexDescriptor)) ?? []
        let distinct = Set(hexes.map(\.id)).count
        let idVerdict: String
        if hexes.isEmpty {
            idVerdict = "no HexVisit rows (id distinctness N/A)"
        } else if hexes.count == distinct {
            idVerdict = "\(hexes.count) rows / \(distinct) distinct — PER-ROW UUIDs ✅"
        } else {
            idVerdict = "\(hexes.count) rows / \(distinct) distinct — SHARED/DUP UUIDs ⚠️ (plain ids; dedup merges these only into a minted row, so all-plain same-cell groups stay duplicated)"
        }
        logger.info("""
        === V12 MIGRATION DIAGNOSTIC (GATE 1) ===
        HexVisit id: \(idVerdict, privacy: .public)
        rows — Stay:\(ct(Stay.self), privacy: .public) Trip:\(ct(Trip.self), privacy: .public) LocationPing:\(ct(LocationPing.self), privacy: .public) HexVisit:\(hexes.count, privacy: .public) YearWrapped:\(ct(YearWrapped.self), privacy: .public) PhotoImportState:\(ct(PhotoImportState.self), privacy: .public) HiddenPhoto:\(ct(HiddenPhoto.self), privacy: .public) PinnedPhoto:\(ct(PinnedPhoto.self), privacy: .public) Home:\(ct(Home.self), privacy: .public) RoutinePlace:\(ct(RoutinePlace.self), privacy: .public)
        (if no 'Schema pre-migration failed' / NSCocoaErrorDomain 134504 / in-memory fallback appeared above, the lightweight V11→V12 migration succeeded)
        === END DIAGNOSTIC ===
        """)
    }
    #endif

    // MARK: - Database Migration

    /// Idempotently create the App-Group store's parent directory before opening it.
    private nonisolated static func ensureStoreDirectoryExists(for config: ModelConfiguration, logger: Logger) {
        let directory = config.url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // Non-fatal: the open below still gets CoreData's own recovery
            // attempt. Log so a future regression is visible in Console.
            logger.error("Could not pre-create store directory \(directory.path): \(error.localizedDescription)")
        }
    }

    /// One-time migration: copy the SwiftData store from the app's default container
    /// to the App Groups container so the widget extension can read it.
    ///
    /// Runs synchronously before ModelContainer initialization. If the store already
    /// exists at the new location (migration already done, or fresh install), this
    /// is a no-op. Old files are preserved as a backup until a committed Delete
    /// All Data retires them (`retireObsoleteStoreFamilyIfPending`). The returned outcome lets
    /// the caller keep using the legacy location for this session when the move did
    /// not complete, rather than creating a new empty App-Group store.
    @discardableResult
    private nonisolated static func migrateStoreToAppGroupIfNeeded(
        schema: Schema, logger: Logger
    ) -> StoreFamilyMoveOutcome {
        let oldConfig = ModelConfiguration(
            "TravelLog",
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        let newConfig = ModelConfiguration(
            "TravelLog",
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .identifier(appGroupIdentifier),
            cloudKitDatabase: .none
        )

        let outcome = migrateStoreFamily(
            from: oldConfig.url, to: newConfig.url, logger: logger,
            sourceRetirementPending: UserDefaults.standard.bool(
                forKey: DataWipe.legacyStoreRemovalPendingKey))
        switch outcome {
        case .noSourceStore:
            logger.debug("No store at default location - fresh install or already migrated.")
        case .destinationExists:
            logger.debug("Store already exists in App Group container - skipping migration.")
        case .sourceRetirementPending:
            logger.error("App Group store is missing, but Delete All Data retired the legacy store; not remigrating wiped history.")
        case .directoryCreationFailed, .rolledBack:
            break // already logged inside
        case .migrated:
            logger.info("Database migrated to App Group container successfully.")
        }
        return outcome
    }

    /// Internal test seam for the store-family move's all-or-nothing outcome.
    enum StoreFamilyMoveOutcome: Equatable {
        case noSourceStore
        case destinationExists
        /// The destination is missing, but a committed wipe already retired
        /// the source: copying it would resurrect wiped history.
        case sourceRetirementPending
        case directoryCreationFailed
        case rolledBack
        case migrated
    }

    nonisolated enum StoreOpeningLocation: Equatable, Sendable {
        case appGroup
        case legacy
    }

    /// Pure startup selection rule. A failed move leaves the legacy family as
    /// the only authoritative store; every other outcome uses the App Group.
    nonisolated static func storeOpeningLocation(
        after outcome: StoreFamilyMoveOutcome
    ) -> StoreOpeningLocation {
        switch outcome {
        case .directoryCreationFailed, .rolledBack: .legacy
        case .noSourceStore, .destinationExists, .sourceRetirementPending, .migrated: .appGroup
        }
    }

    /// URL-parameterized test seam for the ALL-OR-NOTHING App-Group store copy.
    /// The source must be closed: main, WAL, and SHM then form a consistent recoverable set,
    /// and SQLite replays committed WAL transactions on open without a separate checkpoint.
    /// On any failure, remove partial destination files and keep using the legacy store.
    /// No destination main file means the next launch retries; legacy remains authoritative until success.
    nonisolated static func migrateStoreFamily(
        from oldURL: URL, to newURL: URL, logger: Logger,
        sourceRetirementPending: Bool = false
    ) -> StoreFamilyMoveOutcome {
        let fm = FileManager.default

        guard fm.fileExists(atPath: oldURL.path) else {
            return .noSourceStore
        }
        guard !fm.fileExists(atPath: newURL.path) else {
            return .destinationExists
        }
        guard !sourceRetirementPending else {
            return .sourceRetirementPending
        }

        do {
            let parentDir = newURL.deletingLastPathComponent()
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create App Group directory: \(error.localizedDescription)")
            return .directoryCreationFailed
        }

        // Publish the destination MAIN file LAST because its existence selects the new store.
        // Copy sidecars first, then copy the main to a temporary file and rename on the same volume.
        // A kill must leave either no main file for retry or the complete recoverable family.
        let sidecarSuffixes = storeFamilySidecarSuffixes

        // Sweep leftovers from a previous crashed attempt: with no main
        // file present the sidecars (and temp main) are orphans, and
        // `copyItem` would otherwise fail on the collision.
        for suffix in sidecarSuffixes + [".tmp"] {
            try? fm.removeItem(at: URL(fileURLWithPath: newURL.path + suffix))
        }

        var copyFailed = false
        for suffix in sidecarSuffixes {
            let src = URL(fileURLWithPath: oldURL.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            do {
                try fm.copyItem(at: src, to: URL(fileURLWithPath: newURL.path + suffix))
            } catch {
                logger.error("Failed to copy \(src.lastPathComponent): \(error.localizedDescription)")
                copyFailed = true
                break
            }
        }
        if !copyFailed {
            let tmp = URL(fileURLWithPath: newURL.path + ".tmp")
            do {
                try fm.copyItem(at: oldURL, to: tmp)
                try fm.moveItem(at: tmp, to: newURL)
            } catch {
                logger.error("Failed to copy \(oldURL.lastPathComponent): \(error.localizedDescription)")
                copyFailed = true
            }
        }

        if copyFailed {
            for suffix in ["", ".tmp"] + sidecarSuffixes {
                try? fm.removeItem(at: URL(fileURLWithPath: newURL.path + suffix))
            }
            logger.error("Database migration to App Group failed; rolled back partial copy, will retry next launch.")
            return .rolledBack
        }

        return .migrated
    }

    /// Files that travel with a store's main file.
    nonisolated static let storeFamilySidecarSuffixes = [
        "-wal", "-shm", ".photo-import-checkpoint.json",
    ]

    /// The pre-App-Group store location in the app's own Application Support.
    nonisolated static func legacyStoreURL(schema: Schema) -> URL {
        ModelConfiguration(
            "TravelLog",
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .none,
            cloudKitDatabase: .none
        ).url
    }

    /// Result of retiring the obsolete pre-App-Group store family.
    nonisolated enum ObsoleteStoreFamilyRemoval: Equatable, Sendable {
        /// The legacy path is the open store itself (a legacy session).
        case activeStore
        /// No legacy family file exists.
        case nothingToRemove
        case removed
        /// The authoritative store's main file is missing, so the legacy
        /// family cannot be proven obsolete. Nothing was removed.
        case authorityUnproven
        /// A legacy file could not be removed. A surviving main keeps its
        /// WAL/SHM intact, so no partial family is ever adoptable.
        case failed

        var isComplete: Bool {
            switch self {
            case .activeStore, .nothingToRemove, .removed: true
            case .authorityUnproven, .failed: false
            }
        }
    }

    /// Positive identity check: the same resolved path or the same file.
    nonisolated private static func isSameStoreFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.standardizedFileURL.resolvingSymlinksInPath()
        let right = rhs.standardizedFileURL.resolvingSymlinksInPath()
        if left.path == right.path { return true }
        guard let leftID = try? left.resourceValues(
                forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let rightID = try? right.resourceValues(
                forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else {
            return false
        }
        return leftID.isEqual(rightID)
    }

    /// True when a legacy family file exists apart from the active store.
    nonisolated static func obsoleteStoreFamilyNeedsRetirement(
        legacyURL: URL, activeURL: URL
    ) -> Bool {
        guard !isSameStoreFile(legacyURL, activeURL) else { return false }
        let fm = FileManager.default
        return ([""] + storeFamilySidecarSuffixes).contains {
            fm.fileExists(atPath: legacyURL.path + $0)
        }
    }

    /// URL-parameterized seam: removes the obsolete legacy family (main
    /// first, then its known sidecars) only when `activeURL` names a
    /// different, existing store file. Never sweeps the directory, which also
    /// holds the dissolve queue, Stats snapshot and restore sentinel.
    nonisolated static func removeObsoleteStoreFamily(
        at legacyURL: URL,
        authoritative activeURL: URL,
        logger: Logger,
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> ObsoleteStoreFamilyRemoval {
        let fm = FileManager.default
        if isSameStoreFile(legacyURL, activeURL) { return .activeStore }
        let sidecars = storeFamilySidecarSuffixes.map {
            URL(fileURLWithPath: legacyURL.path + $0)
        }
        guard ([legacyURL] + sidecars).contains(where: { fm.fileExists(atPath: $0.path) }) else {
            return .nothingToRemove
        }
        guard fm.fileExists(atPath: activeURL.path) else {
            logger.error("Obsolete store retirement deferred: the authoritative store file is missing.")
            return .authorityUnproven
        }
        // Main first: without it migration reports `.noSourceStore`, so a
        // partially removed family can never be adopted. If the main
        // survives, keep its WAL/SHM rather than leave an adoptable main
        // without its committed transactions.
        if fm.fileExists(atPath: legacyURL.path) {
            do {
                try removeItem(legacyURL)
            } catch CocoaError.fileNoSuchFile {
                // Already gone.
            } catch {
                logger.error("Could not remove the obsolete store: \(error.localizedDescription)")
            }
            if fm.fileExists(atPath: legacyURL.path) { return .failed }
        }
        var residue = false
        for sidecar in sidecars where fm.fileExists(atPath: sidecar.path) {
            do {
                try removeItem(sidecar)
            } catch CocoaError.fileNoSuchFile {
                // Already gone.
            } catch {
                logger.error("Could not remove \(sidecar.lastPathComponent): \(error.localizedDescription)")
            }
            if fm.fileExists(atPath: sidecar.path) { residue = true }
        }
        return residue ? .failed : .removed
    }

    /// Runs the retirement a committed Delete All Data authorized, and clears
    /// that authority only once it completes. Nil when nothing is pending.
    /// Launch calls it only after a persistent App Group container opened.
    @discardableResult
    nonisolated static func retireObsoleteStoreFamilyIfPending(
        legacyURL: URL,
        activeURL: URL,
        defaults: UserDefaults = .standard,
        logger: Logger,
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> ObsoleteStoreFamilyRemoval? {
        guard defaults.bool(forKey: DataWipe.legacyStoreRemovalPendingKey) else { return nil }
        let outcome = removeObsoleteStoreFamily(
            at: legacyURL, authoritative: activeURL, logger: logger, removeItem: removeItem)
        if outcome.isComplete {
            defaults.removeObject(forKey: DataWipe.legacyStoreRemovalPendingKey)
        }
        return outcome
    }

    // MARK: - DEBUG: CloudKit Development schema

    #if DEBUG
    /// Launch argument for a Debug run that only initializes the CloudKit Development schema.
    nonisolated static let initializeCloudKitSchemaArgument = "-initializeCloudKitSchema"

    enum CloudKitSchemaInitializationError: Error {
        case modelUnavailable
    }

    /// CloudKit Development creates a field only when a synced record carries a value for it,
    /// and Production receives only what Development has. This creates every record type and
    /// field of the current schema: CloudKit uploads one representative record per entity and
    /// deletes it again. The throwaway store keeps real data out of it. SwiftData has no API
    /// for this, so it goes through a Core Data container built from the same models.
    nonisolated static func initializeCloudKitDevelopmentSchema() throws {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(
            for: CurrentTravelLogSchema.models) else {
            throw CloudKitSchemaInitializationError.modelUnavailable
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CloudKitSchemaInitialization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let description = NSPersistentStoreDescription(
            url: directory.appendingPathComponent("SchemaInitialization.store"))
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
            containerIdentifier: cloudKitContainerIdentifier)
        description.shouldAddStoreAsynchronously = false

        let container = NSPersistentCloudKitContainer(
            name: "SchemaInitialization", managedObjectModel: model)
        container.persistentStoreDescriptions = [description]
        var loadError: (any Error)?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        defer {
            let coordinator = container.persistentStoreCoordinator
            for store in coordinator.persistentStores {
                try? coordinator.remove(store)
            }
        }
        try container.initializeCloudKitSchema()
    }

    /// Called from `TravelLogApp.init`, before `didFinishLaunching` registers the CloudKit event
    /// observer and before the real store opens. Exiting afterwards keeps the throwaway
    /// container's events away from post-import maintenance and keeps a second mirror of the
    /// zone from running beside the real one.
    nonisolated static func initializeCloudKitSchemaAndExit() -> Never {
        let logger = Logger(subsystem: "com.travellog.app", category: "CloudKitSchema")
        do {
            try initializeCloudKitDevelopmentSchema()
            logger.notice("CloudKit Development schema initialized for schema \(CurrentTravelLogSchema.versionIdentifier.description, privacy: .public). Deploy it to Production in the CloudKit Console.")
            exit(EXIT_SUCCESS)
        } catch {
            logger.error("CloudKit Development schema initialization failed: \(String(describing: error), privacy: .public)")
            exit(EXIT_FAILURE)
        }
    }
    #endif
}
