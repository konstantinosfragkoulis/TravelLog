//
//  RememberedCountriesStorage.swift
//  TravelLog
//

import Foundation
import os.log
import WidgetKit

/// Countries the user visited BEFORE TravelLog could know about them —
/// the pre-history answer.
///
/// # Why this exists, and why it's only countries
///
/// Live tracking starts at install; the photo import reaches back only as
/// far as the photo library does. Trips older than both are invisible, so
/// the passport's headline country count is silently wrong for almost
/// every user — and nobody remembers the exact dates of a 2019 trip well
/// enough for manual trip entry to be honest (or compatible with the
/// app's zero-friction philosophy). A one-time "which countries have you
/// been to?" checklist is the minimal truthful fix: no dates, no fake
/// pings, no fabricated trips — just ISO codes that augment the country
/// count, the country list, and the globe. Remembered countries never
/// create stays/trips/hexes and never participate in Wrapped (which is
/// strictly per-year tracked data).
///
/// # Storage
///
/// iCloud Key-Value Store, exactly like `PinnedTripsStorage` (no SwiftData
/// schema change, syncs across devices, survives reinstall): one key, a
/// JSON-encoded sorted `[String]` of ISO 3166-1 alpha-2 codes.
/// Last-writer-wins is acceptable for a rarely-edited checklist.
@MainActor
@Observable
final class RememberedCountriesStorage {

    static let shared = RememberedCountriesStorage()

    private static let storeKey = "rememberedCountryCodes"

    /// Nonisolated: notifications arrive on arbitrary queues; the store is
    /// thread-safe per Apple docs. Mutations stay main-isolated.
    private let store = NSUbiquitousKeyValueStore.default

    private let logger = Logger(subsystem: "com.travellog.app", category: "RememberedCountries")

    /// Uppercased ISO alpha-2 codes. Updated on init, on every toggle, and
    /// on external-change notifications; `@Observable` redraws observers.
    private(set) var codes: Set<String> = []

    /// iCloud account replacements the observer has seen, counted on the
    /// posting thread (see `PinnedTripsStorage`), and how many `codes`
    /// already reflects.
    nonisolated private static let sharedAccountChanges = OSAllocatedUnfairLock(initialState: 0)
    nonisolated private let accountChanges: OSAllocatedUnfairLock<Int>
    @ObservationIgnored private var adoptedAccountChanges = 0

    #if DEBUG
    private var testDefaults: UserDefaults?

    /// Isolated persistence for tests; never observes or writes the shared
    /// KVS or the widgets' mirror.
    init(forTesting defaults: UserDefaults) {
        testDefaults = defaults
        accountChanges = OSAllocatedUnfairLock(initialState: 0)
        loadFromStore()
    }

    /// What the observer records when KVS reports an account change, before
    /// its main-actor handler has run.
    func noteAccountChangeForTesting() {
        accountChanges.withLock { $0 += 1 }
    }
    #endif

    private init() {
        accountChanges = Self.sharedAccountChanges
        loadFromStore(missing: .launch)
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: nil
        ) { note in
            let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            // Same handling as PinnedTripsStorage: an account change adopts
            // the new account's values, a missing key included, without
            // writing; other changes reconcile only on genuine server /
            // initial-sync changes.
            if reason == NSUbiquitousKeyValueStoreAccountChange {
                RememberedCountriesStorage.sharedAccountChanges.withLock { $0 += 1 }
                Task { @MainActor in
                    RememberedCountriesStorage.shared.adoptAccountChanges()
                }
                return
            }
            guard reason == NSUbiquitousKeyValueStoreServerChange
                || reason == NSUbiquitousKeyValueStoreInitialSyncChange else {
                return
            }
            Task { @MainActor in
                RememberedCountriesStorage.shared.loadFromStore()
            }
        }
        store.synchronize()
    }

    // MARK: - Public surface

    func contains(_ code: String) -> Bool {
        codes.contains(code.uppercased())
    }

    func toggle(_ code: String) {
        let normalized = code.uppercased()
        // The intent is what the user saw; refreshing must not reverse it.
        let remove = codes.contains(normalized)
        refreshBeforeEdit()
        if remove {
            guard codes.contains(normalized) else { return }
            codes.remove(normalized)
        } else {
            guard Self.isValidCode(normalized), !codes.contains(normalized) else { return }
            codes.insert(normalized)
        }
        saveToStore()
    }

    /// Backup-restore hook: adds the valid codes and removes none. Returns
    /// how many were not remembered yet. Like `PinnedTripsStorage.merge`, the
    /// union is taken against the stored set as it is now, not a snapshot an
    /// unrun change notification has yet to refresh.
    @discardableResult
    func merge(_ newCodes: Set<String>) -> Int {
        guard !newCodes.isEmpty else { return 0 }
        refreshBeforeEdit()
        let added = Self.normalized(Array(newCodes)).subtracting(codes)
        guard !added.isEmpty else { return 0 }
        codes.formUnion(added)
        saveToStore()
        logger.info("Merged \(added.count) remembered countr(ies) from a backup.")
        return added.count
    }

    /// Delete-All-Data hook: the checklist lives in
    /// iCloud-KVS — outside the SwiftData store — so the wipe must clear it
    /// explicitly or the passport count, globe highlight, and flag list keep
    /// showing "remembered" countries the alert promised were gone, and the
    /// retained set re-syncs to other devices. Writes an EMPTY array (key
    /// present) so peers' load path converges to cleared rather than
    /// treating nil as not-yet-synced.
    func clear() {
        codes = []
        saveToStore()
        logger.info("Remembered countries cleared (Delete All Data).")
    }

    // MARK: - Normalization (pure, testable)

    /// Uppercase, exactly two ASCII letters, AND a real ISO 3166-1
    /// country/territory (`CountryCatalog.isoCountryCodes`). Garbage in a
    /// synced blob (hand-edited, older build) must not become a phantom country
    /// — and neither must the supranational CLDR codes that
    /// `Locale.Region.isoRegions` carries (EU/EZ/UN would render "European
    /// Union"/"Eurozone"/"United Nations" in the picker). Membership also
    /// cleanses already-synced offenders on load, since `normalized` filters
    /// through here.
    nonisolated static func isValidCode(_ code: String) -> Bool {
        code.count == 2
            && code.allSatisfy { $0.isASCII && $0.isLetter && $0.isUppercase }
            && CountryCatalog.isoCountryCodes.contains(code)
    }

    nonisolated static func normalized(_ raw: [String]) -> Set<String> {
        Set(raw.map { $0.uppercased() }.filter(isValidCode))
    }

    /// Adopts an account replacement the observer counted and `codes` does
    /// not reflect yet: the local store holds the new account's values, so
    /// its missing key means an empty checklist, for the widgets' mirror too.
    func adoptAccountChanges() {
        let seen = accountChanges.withLock { $0 }
        guard seen != adoptedAccountChanges else { return }
        adoptedAccountChanges = seen
        loadFromStore(missing: .accountReplaced)
        logger.info("Adopted an iCloud account change.")
    }

    /// Every explicit edit starts from the current account's checklist as
    /// stored now, so a delivered change whose notification has not run yet
    /// survives the whole-set save. A missing value keeps the known set.
    private func refreshBeforeEdit() {
        adoptAccountChanges()
        loadFromStore()
    }

    // MARK: - Persistence

    /// What a missing KVS value means to `loadFromStore`.
    private enum MissingValue {
        /// Not yet synced, or a same-account cache reset: keep what is known.
        case preserve
        /// Launch: keep, except a widget mirror written under another account.
        case launch
        /// An adopted account replacement: the new account has none.
        case accountReplaced
    }

    private func loadFromStore(missing: MissingValue = .preserve) {
        let storedData: Data?
        #if DEBUG
        if let testDefaults {
            storedData = testDefaults.data(forKey: Self.storeKey)
        } else {
            storedData = store.data(forKey: Self.storeKey)
        }
        #else
        storedData = store.data(forKey: Self.storeKey)
        #endif
        guard let data = storedData else {
            // nil = not-yet-synced or account switch — never wipe local
            // state on it (an empty checklist writes `[]`, key present),
            // unless the observer reported the account replacement.
            switch missing {
            case .preserve:
                return
            case .accountReplaced:
                if !codes.isEmpty { codes = [] }
            case .launch:
                // An account switch made while the app was not running
                // posts no change this process saw. The mirror outlived it,
                // so drop it once it provably belongs to another account.
                #if DEBUG
                if testDefaults != nil { return }
                #endif
                guard let group = UserDefaults(suiteName: AppDelegate.appGroupIdentifier),
                      Self.mirrorBelongsToAnotherAccount(
                        mirrored: group.data(forKey: Self.appGroupMirrorAccountKey),
                        current: Self.currentAccountIdentity()) else { return }
            }
            #if DEBUG
            if testDefaults != nil { return }
            #endif
            mirrorToAppGroup([])
            return
        }
        let strings = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        let parsed = Self.normalized(strings)
        if parsed != codes {
            codes = parsed
            logger.debug("Loaded \(parsed.count) remembered countr(ies) from store.")
        }
        // Refresh the widget-readable mirror on every load too, so an existing
        // install populates it without waiting for the user to toggle a
        // country.
        #if DEBUG
        if testDefaults != nil { return }
        #endif
        mirrorToAppGroup(parsed.sorted())
    }

    private func saveToStore() {
        let strings = codes.sorted()
        guard let data = try? JSONEncoder().encode(strings) else {
            logger.error("Failed to encode remembered countries.")
            return
        }
        #if DEBUG
        if let testDefaults {
            testDefaults.set(data, forKey: Self.storeKey)
            return
        }
        #endif
        store.set(data, forKey: Self.storeKey)
        store.synchronize()
        mirrorToAppGroup(strings)
    }

    /// App-Group key the WIDGETS read. Same JSON as the KVS payload.
    nonisolated static let appGroupMirrorKey = "rememberedCountryCodesMirror_v1"

    /// Mirror the checklist into the App Group container for the widgets
    /// (see `RememberedCountriesMirror`).
    ///
    /// Reloads the two stats widgets when the mirrored set changed, so an
    /// edit shows there right away instead of at the next 6-hour refresh.
    /// The unchanged launch-time load spends no reload budget.
    private func mirrorToAppGroup(_ strings: [String]) {
        guard let defaults = UserDefaults(suiteName: AppDelegate.appGroupIdentifier) else { return }
        Self.writeMirrorAccount(Self.currentAccountIdentity(), to: defaults)
        if Self.writeMirror(strings, to: defaults) {
            WidgetCenter.shared.reloadTimelines(ofKind: "TravelStatsWidget")
            WidgetCenter.shared.reloadTimelines(ofKind: "StatsAccessoryWidget")
        }
    }

    /// Writes the mirror and returns whether its bytes changed. Inputs are
    /// always sorted arrays from the same encoder, so byte equality is a
    /// stable change test.
    nonisolated static func writeMirror(_ strings: [String], to defaults: UserDefaults) -> Bool {
        guard let data = try? JSONEncoder().encode(strings) else { return false }
        if defaults.data(forKey: appGroupMirrorKey) == data { return false }
        defaults.set(data, forKey: appGroupMirrorKey)
        return true
    }

    /// App-Group key for the archived iCloud identity the mirror was last
    /// written under while one was known. Absent when none ever was.
    nonisolated static let appGroupMirrorAccountKey = "rememberedCountryCodesMirrorAccount_v1"

    /// The archived `ubiquityIdentityToken`, or nil when iCloud reports no
    /// identity (signed out, or unavailable to this app).
    private static func currentAccountIdentity() -> Data? {
        guard let token = FileManager.default.ubiquityIdentityToken else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false)
    }

    /// Only two known, different identities attribute the mirror to another
    /// account; an unknown one never clears it.
    nonisolated static func mirrorBelongsToAnotherAccount(mirrored: Data?, current: Data?) -> Bool {
        guard let mirrored, let current else { return false }
        return mirrored != current
    }

    /// An unknown identity keeps the last known one: iCloud can withhold the
    /// token (iCloud Drive off, or not answering yet) while the account
    /// stays, and an untagged mirror could never be told apart from the next
    /// account's at a cold launch. A known, different identity replaces it.
    nonisolated static func writeMirrorAccount(_ identity: Data?, to defaults: UserDefaults) {
        guard let identity else { return }
        defaults.set(identity, forKey: appGroupMirrorAccountKey)
    }
}
