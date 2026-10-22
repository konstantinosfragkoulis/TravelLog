//
//  TemporaryHome.swift
//  TravelLog
//

import Foundation
import SwiftData

/// A dated place the user declares as a temporary home (a semester abroad);
/// the real `Home` keeps working. Inside `[startedAt, endedAt]` it is a trip
/// boundary, never for stays that predate every `Home`, and code that reads
/// `Home` rows for meaning (Welcome Home, the home country, titles) never
/// reads it. Added in V19, CloudKit-safe: no unique, array or relationship,
/// every field defaulted; readers collapse same-id twins, never delete them.
@Model
final class TemporaryHome {

    var id: UUID = UUID()

    /// User-facing label, e.g. "Erasmus". Empty means "use the place name".
    var label: String = ""

    var latitude: Double = 0
    var longitude: Double = 0

    /// Fallback circle in kilometers when no shape resolves. Same meaning as `Home.radiusKm`.
    var radiusKm: Double = 25

    /// Reverse-geocoded metadata for display purposes.
    var locality: String?
    var administrativeArea: String?
    var country: String?
    var isoCountryCode: String?

    /// When the stay began. The user's own statement; code never backdates it.
    var startedAt: Date = Date.now

    /// When the stay ends. Nil means open-ended; the date may lie in the future.
    var endedAt: Date?

    /// The time zone the dates were chosen in.
    var timeZoneIdentifier: String?

    var createdAt: Date = Date.now
    var modifiedAt: Date = Date.now

    /// When the user removed this declaration. Remove stamps every row with
    /// the id instead of deleting it, and readers drop an id as soon as any of
    /// its rows carries a value (`HomeAnchors.collapsingTwins`), so a removal
    /// outlives a same-id twin that syncs in later. Never cleared; declaring
    /// again mints a new id. Added in V20.
    var removedAt: Date?

    /// Bumped on every coverage change (place, dates, end, removal) to the
    /// highest revision among the id's rows plus one, on every row written
    /// (`nextCoverageRevision(of:)`). A stay stamped by this declaration
    /// records the revision it was stamped by (`Stay.temporaryHomeRevision`).
    /// Zero on rows written before V21. Added in V21.
    var coverageRevision: Int = 0

    /// Trips the user kept whole against this declaration, as comma-separated
    /// UUID strings (CloudKit takes no arrays). Writers only add
    /// (`addKeptTrip`); readers union it over every row of the id
    /// (`keptTripIDs(of:)`), since two devices can each hold one copy. Empty
    /// on rows written before V21. Added in V21.
    var keptTripIDs: String = ""

    /// The user's label, else the place name, else a localized default.
    func displayLabel(locale: Locale = AppLanguagePreference.currentLocale()) -> String {
        if !label.isEmpty { return label }
        if let locality, !locality.isEmpty { return locality }
        return localizedRendererString(
            localized: "temporary-home.default-label",
            defaultValue: "Temporary Home",
            bundle: nil,
            locale: locale)
    }

    /// Whether `now` lies inside the declared dates, both ends inclusive:
    /// the window rule `TripClassifier.matchesHome` pass 1 uses.
    func isActive(at now: Date) -> Bool {
        if let endedAt, now > endedAt { return false }
        return startedAt <= now
    }

    /// The kept trip ids of this row. Segments that are not a UUID are ignored.
    var keptTripIDSet: Set<UUID> {
        Set(keptTripIDs.split(separator: ",").compactMap {
            UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }

    /// Adds `id` to this row's kept trips. The stored string stays sorted and
    /// free of duplicates and junk, so equal sets are equal strings; nothing is
    /// written when it is already canonical and holds `id`.
    func addKeptTrip(_ id: UUID) {
        let canonical = keptTripIDSet.union([id]).map(\.uuidString).sorted()
            .joined(separator: ",")
        if keptTripIDs != canonical { keptTripIDs = canonical }
    }

    /// The union of the kept trips of `rows`, normally every physical row of
    /// one id: a keep written on one copy counts for the declaration.
    static func keptTripIDs(of rows: [TemporaryHome]) -> Set<UUID> {
        rows.reduce(into: Set<UUID>()) { $0.formUnion($1.keptTripIDSet) }
    }

    /// The revision a coverage change writes on every row of an id: one above
    /// the highest revision among `rows` (one when there is none).
    static func nextCoverageRevision(of rows: [TemporaryHome]) -> Int {
        (rows.map(\.coverageRevision).max() ?? 0) + 1
    }

    init(
        label: String,
        latitude: Double,
        longitude: Double,
        startedAt: Date,
        endedAt: Date? = nil
    ) {
        self.id = UUID()
        self.label = label
        self.latitude = latitude
        self.longitude = longitude
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}
