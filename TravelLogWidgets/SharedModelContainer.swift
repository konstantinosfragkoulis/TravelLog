import SwiftData
import Foundation
import os.log

enum SharedModelContainer {

    static let appGroupIdentifier = "group.com.kfragkoulis.TravelLog"

    /// The app's selected per-app language, mirrored at app launch. The
    /// widget process can have a different preferred localization, so every
    /// preformatted timeline string must use this locale explicitly.
    static var appLanguageTag: String {
        AppLanguagePreference.mirroredTag(appGroupIdentifier: appGroupIdentifier)
            ?? AppLanguagePreference.currentTag()
    }

    static var appLocale: Locale {
        AppLanguagePreference.locale(for: appLanguageTag)
    }

    /// Resolve a widget-catalog resource for the mirrored app language even
    /// when the extension process itself follows the system language.
    static func localizedString(
        _ key: String,
        defaultValue: String,
        languageTag: String? = nil
    ) -> String {
        let tag = languageTag ?? appLanguageTag
        return AppLanguagePreference.localizedString(
            key: key,
            defaultValue: defaultValue,
            languageTag: tag)
    }

    static func localizedFormat(
        _ key: String,
        defaultValue: String,
        arguments: [CVarArg],
        languageTag: String? = nil
    ) -> String {
        let tag = languageTag ?? appLanguageTag
        let format = localizedString(
            key,
            defaultValue: defaultValue,
            languageTag: tag
        )
        return String(
            format: format,
            locale: AppLanguagePreference.locale(for: tag),
            arguments: arguments
        )
    }

    static func formatInteger(_ value: Int, locale: Locale? = nil) -> String {
        value.formatted(
            IntegerFormatStyle<Int>.number
                .locale(locale ?? appLocale)
                .grouping(.never)
        )
    }

    /// `nil` when SwiftData cannot give us ANY container. Providers render
    /// their redacted placeholders and retry on a short timeline instead of
    /// trapping: a `fatalError` in a static initializer crash-loops the
    /// extension (the system relaunches it indefinitely, burning the widget
    /// reload budget) and leaves a permanently blank tile. A widget refresh
    /// can precede the app's first launch, when even the in-memory fallback
    /// below can throw.
    ///
    /// A computed accessor over a lock-guarded cache, NOT `static let`: a
    /// `static let` memoizes a `nil` result for the whole extension process,
    /// so the 15-minute retry timeline could never self-heal when WidgetKit
    /// reused the process — the retry would re-read the cached nil instead of
    /// re-attempting the open. Successful persistent containers are still
    /// created exactly once; an IN-MEMORY FALLBACK is cached only for
    /// `fallbackRetryInterval` — caching it unconditionally would leave all
    /// four widgets empty for the extension process's lifetime even after the
    /// main app opened/migrated the real store.
    static var container: ModelContainer? {
        containerLock.lock()
        defer { containerLock.unlock() }
        if let entry = cacheEntry {
            if !entry.isFallback { return entry.container }
            if Date.now.timeIntervalSince(entry.cachedAt) < fallbackRetryInterval {
                return entry.container
            }
            // Fallback past its backoff: re-attempt the persistent open below.
        }
        if let made = makeContainer() {
            cacheEntry = CacheEntry(container: made.container, isFallback: made.isFallback, cachedAt: .now)
            return made.container
        }
        // Total failure this attempt: keep any previously cached fallback
        // (stale-empty beats nil) and let the short timeline retry.
        return cacheEntry?.container
    }

    /// True when the currently cached container is the empty in-memory
    /// fallback rather than the persistent App-Group store. Providers then
    /// render their redacted placeholders (the fallback holds no data, so
    /// its zeros are not the user's history) and schedule the short
    /// `retryDate` timeline instead of the regular 6/12-hour one.
    static var containerIsFallback: Bool {
        containerLock.lock()
        defer { containerLock.unlock() }
        return cacheEntry?.isFallback ?? false
    }

    private struct CacheEntry {
        let container: ModelContainer
        let isFallback: Bool
        let cachedAt: Date
    }

    nonisolated(unsafe) private static var cacheEntry: CacheEntry?
    private static let containerLock = NSLock()

    /// How long a cached in-memory fallback is served before the persistent
    /// open is re-attempted. Matches the `retryDate` cadence so a doomed
    /// disk open isn't retried on every snapshot/timeline call.
    private static let fallbackRetryInterval: TimeInterval = 15 * 60

    private static func makeContainer() -> (container: ModelContainer, isFallback: Bool)? {
        let logger = Logger(subsystem: "com.travellog.app", category: "WidgetModelContainer")
        let schema = Schema(versionedSchema: CurrentTravelLogSchema.self)
        let config = ModelConfiguration(
            "TravelLog",
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: false,
            groupContainer: .identifier(appGroupIdentifier),
            cloudKitDatabase: .none
        )

        // iOS auto-creates only `Library/Caches` inside app-group containers;
        // `Library/Application Support` (where the store lives) exists only
        // after some process creates it — normally CoreData's error-recovery
        // during the app's first launch. A widget refresh that beats that
        // first launch finds the directory missing, and the read-only open
        // (`allowsSave: false`) has no recovery path. Pre-creating is
        // idempotent, allowed by the group sandbox, and matches the fix
        // Apple DTS recommends for first-install SwiftData App-Group errors.
        try? FileManager.default.createDirectory(
            at: config.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        do {
            // The main app migrates the shared App-Group store on launch when
            // needed using the explicit staged TravelLogMigrationPlan. The
            // widget opens it read-only (`allowsSave: false`) without a plan.
            // If the store still needs migration, this open fails and falls
            // back to the empty in-memory container below. The cache retries
            // the persistent open after fallbackRetryInterval.
            return (try ModelContainer(
                for: schema,
                configurations: [config]
            ), false)
        } catch {
            logger.error("Widget store open failed: \(String(describing: error)). Falling back to in-memory.")
            do {
                return (try ModelContainer(
                    for: schema,
                    configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, allowsSave: false, cloudKitDatabase: .none)]
                ), true)
            } catch {
                // Reachable in practice after all (iOS 27 beta 1, above) —
                // return nil and let providers degrade gracefully. The next
                // scheduled refresh retries from scratch; once the app has
                // launched once, the on-disk open above succeeds.
                logger.critical("Widget in-memory fallback also failed: \(String(describing: error))")
                return nil
            }
        }
    }

    /// Soon-retry timeline date for the nil-container and in-memory-fallback
    /// cases (the condition self-heals as soon as the app has launched once,
    /// so don't wait the regular 6 hours to show real data) and for a failed
    /// required read on a usable store, whose redacted placeholder must not
    /// stand until the next midnight or 6-hour reload.
    static var retryDate: Date {
        Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? Date.now.addingTimeInterval(900)
    }

    /// A required store read failed on a usable container. The provider shows
    /// its redacted placeholder and retries on `retryDate`.
    static func logReadFailure(_ widget: String, _ error: any Error) {
        Logger(subsystem: "com.travellog.app", category: "WidgetModelContainer")
            .error("\(widget, privacy: .public) read failed: \(String(describing: error), privacy: .public)")
    }

    /// Refresh date for day-granularity widgets (day counts / countdowns):
    /// the displayed value only changes at the local day boundary, so the
    /// reload is scheduled just past the next local midnight instead of a
    /// fixed hour offset — a fixed offset drifts against midnight and leaves
    /// the day number one-day stale for hours every day.
    /// A minute of slack keeps the render safely on the new day.
    static func nextDayBoundaryRefresh(after date: Date) -> Date {
        if let midnight = Calendar.current.nextDate(
            after: date,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) {
            return midnight.addingTimeInterval(60)
        }
        return date.addingTimeInterval(12 * 3600)
    }
}
