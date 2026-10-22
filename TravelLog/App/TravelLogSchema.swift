//
//  TravelLogSchema.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 28/4/26.
//

import Foundation
import SwiftData

// MARK: - Frozen shared model (HexVisit pre-V12 shape)

/// Frozen pre-`id` shape of `HexVisit` — its form from V2 through V11. The live
/// `HexVisit` gained a `UUID id` in V12; V3…V11 alias
/// this type (`typealias HexVisit = SchemaFrozenModels.HexVisit`) so their
/// `VersionedSchema` structural hashes stay anchored to the shape actually on
/// disk for those versions. The SwiftData entity name is
/// the class name ("HexVisit"), so aliasing it is hash-equivalent to the prior
/// live reference. DO NOT EDIT — this freezes schema history.
enum SchemaFrozenModels {
    @Model final class HexVisit {
        var h3Index: String = ""
        var firstVisited: Date = Date.now
        var lastVisited: Date = Date.now
        var visitCount: Int = 1
        var locality: String?
        var country: String?
        var isoCountryCode: String?
        var centerLatitude: Double = 0
        var centerLongitude: Double = 0
        init() {}
    }

    /// Frozen pre-`altitude` shape of `LocationPing` — its form from V8 through
    /// V12. `LocationPing` gained `sourceRaw` in V8 and was referenced LIVE by
    /// V8…V12; the live model gains `altitude` / `verticalAccuracy` in V13, so
    /// V8…V12 alias this type (`typealias LocationPing =
    /// SchemaFrozenModels.LocationPing`) to keep their `VersionedSchema`
    /// structural hashes anchored to the shape on disk for those versions.
    /// The SwiftData entity name is the class name
    /// ("LocationPing"), so aliasing is hash-equivalent to the prior live
    /// reference. DO NOT EDIT — this freezes schema history.
    @Model final class LocationPing {
        var id: UUID = UUID()
        var timestamp: Date = Date.now
        var latitude: Double = 0
        var longitude: Double = 0
        var horizontalAccuracy: Double = 0
        var h3IndexRes6: String = ""
        var locality: String?
        var subLocality: String?
        var administrativeArea: String?
        var country: String?
        var isoCountryCode: String?
        var isGeocoded: Bool = false
        var isProcessed: Bool = false
        var sourceRaw: String = "liveSLC"
        init() {}
    }

    /// Frozen V11-through-V15 `Stay` shape. Those five schemas originally
    /// referenced the top-level live `Stay`; V16 changes the inverse `Trip`
    /// model by adding `localizedTitles`, so every historical schema that
    /// referenced the live Stay/Trip graph must now close that graph over
    /// frozen types. Keeping both sides together is required: freezing Trip
    /// alone would leave `Stay.trip` pointing at the new live Trip while the
    /// frozen `Trip.stays` points back here, recreating the relationship-type
    /// drift that caused the first V10 migration failure. DO NOT EDIT.
    @Model final class Stay {
        var id: UUID = UUID()
        var startTime: Date = Date.now
        var endTime: Date = Date.now
        var durationMinutes: Int = 0
        var centroidLatitude: Double = 0
        var centroidLongitude: Double = 0
        var locality: String?
        var administrativeArea: String?
        var country: String?
        var isoCountryCode: String?
        var subLocality: String?
        var metroName: String?
        var islandName: String?
        var weatherData: Data?
        var avgTemperatureC: Double?
        var weatherConditionRaw: String?
        var precipitationMm: Double?
        var dayKey: Date?
        var transitFromPreviousRaw: String?
        var distanceFromPreviousKm: Double?
        var stepsWalked: Int?
        var isAirport: Bool = false
        var h3IndexRes6: String = ""
        var pingCount: Int = 0
        var distanceFromHomeKm: Double = 0
        var categoryRaw: String = ""
        var userOverridden: Bool = false
        var continuesPreviousTrip: Bool = false
        @Relationship var trip: Trip?
        var orderInTrip: Int?
        var pingIDsString: String = ""
        var sourceRaw: String = "liveSLC"

        init() {}
    }

    /// Frozen V11-through-V15 `Trip` shape, paired with the frozen `Stay`
    /// immediately above. This is the exact persisted shape before V16 adds
    /// the optional `localizedTitles` relationship. DO NOT EDIT.
    @Model final class Trip {
        var id: UUID = UUID()
        var startDate: Date = Date.now
        var endDate: Date?
        var isComplete: Bool = false
        var customName: String?
        var destinationSummary: String = ""
        var countryCodes: String = ""
        var aiGeneratedTitle: String?
        var aiGeneratedSummary: String?
        var summaryGeneratedAt: Date?
        var summaryGenerationVersion: Int?
        var summarySourceRaw: String?
        var classifiedByAI: Bool = false
        var userEdited: Bool = false
        var sourceRaw: String = "liveSLC"
        @Relationship(deleteRule: .nullify, inverse: \Stay.trip)
        var stays: [Stay]?

        init() {}
    }
}

// MARK: - V3 Schema (CloudKit-Safe Attributes) - FROZEN LocationPing/Stay/Trip

/// Converts Stay.pingIDs from [UUID] (transformable) to pingIDsString (String)
/// so all attributes are CloudKit-compatible scalar types.
///
/// **Frozen note:** `LocationPing`, `Stay`, `Trip` are inline-declared at their
/// V3-era shape (Stay uses `pingIDsString`; Trip has no `customName`, which
/// arrived in V4; none of the three has `sourceRaw`, which arrives in V8).
/// This freeze landed alongside the V7→V8 schema bump under the rule that
/// any model whose shape will change in a later version must be inline-frozen
/// in every preceding `VersionedSchema` enum that previously referenced it as
/// a live type. `Home`, `RoutinePlace`, `HexVisit` remain live references —
/// they haven't been edited since V2.
enum TravelLogSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    // HexVisit frozen at its pre-`id` shape (see SchemaFrozenModels).
    typealias HexVisit = SchemaFrozenModels.HexVisit

    static var models: [any PersistentModel.Type] {
        [
            LocationPing.self,    // resolves to TravelLogSchemaV3.LocationPing below
            Stay.self,            // resolves to TravelLogSchemaV3.Stay below
            Trip.self,            // resolves to TravelLogSchemaV3.Trip below
            Home.self,            // live; unchanged since V2
            RoutinePlace.self,    // live; unchanged since V2
            HexVisit.self,        // live; unchanged since V2
        ]
    }

    /// V3-era LocationPing: no `sourceRaw` (that arrives in V8).
    @Model final class LocationPing {
        var id: UUID = UUID()
        var timestamp: Date = Date.now
        var latitude: Double = 0
        var longitude: Double = 0
        var horizontalAccuracy: Double = 0
        var h3IndexRes6: String = ""
        var locality: String?
        var subLocality: String?
        var administrativeArea: String?
        var country: String?
        var isoCountryCode: String?
        var isGeocoded: Bool = false
        var isProcessed: Bool = false

        init() {}
    }

    /// V3-era Stay: `pingIDsString` (introduced in V3); no `sourceRaw` (V8).
    @Model final class Stay {
        var id: UUID = UUID()
        var startTime: Date = Date.now
        var endTime: Date = Date.now
        var durationMinutes: Int = 0
        var centroidLatitude: Double = 0
        var centroidLongitude: Double = 0
        var locality: String?
        var administrativeArea: String?
        var country: String?
        var isoCountryCode: String?
        var h3IndexRes6: String = ""
        var pingCount: Int = 0
        var distanceFromHomeKm: Double = 0
        var categoryRaw: String = ""
        var userOverridden: Bool = false
        var continuesPreviousTrip: Bool = false
        @Relationship var trip: Trip?
        var orderInTrip: Int?
        var pingIDsString: String = ""

        init() {}
    }

    /// V3-era Trip: no `customName` (added in V4); no `sourceRaw` (added in V8).
    @Model final class Trip {
        var id: UUID = UUID()
        var startDate: Date = Date.now
        var endDate: Date?
        var isComplete: Bool = false
        var destinationSummary: String = ""
        var countryCodes: String = ""
        var classifiedByAI: Bool = false
        var userEdited: Bool = false
        @Relationship(deleteRule: .nullify, inverse: \Stay.trip)
        var stays: [Stay]?

        init() {}
    }
}

// MARK: - V4 Schema (Trip Custom Names) - FROZEN LocationPing/Stay/Trip

/// Adds Trip.customName for user-editable trip names.
///
/// **Frozen note:** `LocationPing`, `Stay`, `Trip` are inline-declared at their
/// V4-era shape (Trip now carries `customName`; none of the three has
/// `sourceRaw`, which arrives in V8). Frozen alongside V3 as part of the V7→V8
/// bump.
enum TravelLogSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    // HexVisit frozen at its pre-`id` shape (see SchemaFrozenModels).
    typealias HexVisit = SchemaFrozenModels.HexVisit

    static var models: [any PersistentModel.Type] {
        [
            LocationPing.self,    // resolves to TravelLogSchemaV4.LocationPing below
            Stay.self,            // resolves to TravelLogSchemaV4.Stay below
            Trip.self,            // resolves to TravelLogSchemaV4.Trip below
            Home.self,            // live; unchanged since V2
            RoutinePlace.self,    // live; unchanged since V2
            HexVisit.self,        // live; unchanged since V2
        ]
    }

    /// V4-era LocationPing: no `sourceRaw` (added in V8).
    @Model final class LocationPing {
        var id: UUID = UUID()
        var timestamp: Date = Date.now
        var latitude: Double = 0
        var longitude: Double = 0
        var horizontalAccuracy: Double = 0
        var h3IndexRes6: String = ""
        var locality: String?
        var subLocality: String?
        var administrativeArea: String?
        var country: String?
        var isoCountryCode: String?
        var isGeocoded: Bool = false
        var isProcessed: Bool = false

        init() {}
    }

    /// V4-era Stay: no `sourceRaw` (added in V8).
    @Model final class Stay {
        var id: UUID = UUID()
        var startTime: Date = Date.now
        var endTime: Date = Date.now
        var durationMinutes: Int = 0
        var centroidLatitude: Double = 0
        var centroidLongitude: Double = 0
        var locality: String?
        var administrativeArea: String?
        var country: String?
        var isoCountryCode: String?
        var h3IndexRes6: String = ""
        var pingCount: Int = 0
        var distanceFromHomeKm: Double = 0
        var categoryRaw: String = ""
        var userOverridden: Bool = false
        var continuesPreviousTrip: Bool = false
        @Relationship var trip: Trip?
        var orderInTrip: Int?
        var pingIDsString: String = ""

        init() {}
    }

    /// V4-era Trip: introduces `customName`; no `sourceRaw` (added in V8).
    @Model final class Trip {
        var id: UUID = UUID()
        var startDate: Date = Date.now
        var endDate: Date?
        var isComplete: Bool = false
        var customName: String?
        var destinationSummary: String = ""
        var countryCodes: String = ""
        var classifiedByAI: Bool = false
        var userEdited: Bool = false
        @Relationship(deleteRule: .nullify, inverse: \Stay.trip)
        var stays: [Stay]?

        init() {}
    }
}

// MARK: - V5 Schema (Hidden Photos) - FROZEN LocationPing/Stay/Trip/HiddenPhoto

/// Adds HiddenPhoto, a per-trip user-suppressed photo block list.
/// `PhotoService.photosForTrip` consults this at fetch time to filter the
/// returned `PHAsset`s. Lightweight migration: a brand-new entity, no changes
/// to existing model shapes.
///
/// **Frozen note:** `HiddenPhoto` is inline-declared at its V5-era shape (no
/// `cloudIdentifier` — added in V7). `LocationPing`, `Stay`, `Trip` are also
/// inline-declared at their V5-era shape (no `sourceRaw` — added in V8); this
/// freeze landed alongside the V7→V8 bump. `Home`,
/// `RoutinePlace`, `HexVisit` remain live references — they haven't been
/// edited since V2.
enum TravelLogSchemaV5: VersionedSchema {
    static let versionIdentifier = Schema.Version(5, 0, 0)

    // HexVisit frozen at its pre-`id` shape (see SchemaFrozenModels).
    typealias HexVisit = SchemaFrozenModels.HexVisit

    static var models: [any PersistentModel.Type] {
        [
            LocationPing.self,    // resolves to TravelLogSchemaV5.LocationPing below
            Stay.self,            // resolves to TravelLogSchemaV5.Stay below
            Trip.self,            // resolves to TravelLogSchemaV5.Trip below
            Home.self,            // live; unchanged since V2
            RoutinePlace.self,    // live; unchanged since V2
            HexVisit.self,        // live; unchanged since V2
            HiddenPhoto.self,     // resolves to TravelLogSchemaV5.HiddenPhoto below
        ]
    }

    /// V5-era LocationPing: no `sourceRaw` (added in V8).
    @Model final class LocationPing {
        var id: UUID = UUID()
        var timestamp: Date = Date.now
        var latitude: Double = 0
        var longitude: Double = 0
        var horizontalAccuracy: Double = 0
        var h3IndexRes6: String = ""
        var locality: String?
        var subLocality: String?
        var administrativeArea: String?
        var country: String?
        var isoCountryCode: String?
        var isGeocoded: Bool = false
        var isProcessed: Bool = false

        init() {}
    }

    /// V5-era Stay: no `sourceRaw` (added in V8).
    @Model final class Stay {
        var id: UUID = UUID()
        var startTime: Date = Date.now
        var endTime: Date = Date.now
        var durationMinutes: Int = 0
        var centroidLatitude: Double = 0
        var centroidLongitude: Double = 0
        var locality: String?
        var administrativeArea: String?
        var country: String?
        var isoCountryCode: String?
        var h3IndexRes6: String = ""
        var pingCount: Int = 0
        var distanceFromHomeKm: Double = 0
        var categoryRaw: String = ""
        var userOverridden: Bool = false
        var continuesPreviousTrip: Bool = false
        @Relationship var trip: Trip?
        var orderInTrip: Int?
        var pingIDsString: String = ""

        init() {}
    }

    /// V5-era Trip: no `sourceRaw` (added in V8).
    @Model final class Trip {
        var id: UUID = UUID()
        var startDate: Date = Date.now
        var endDate: Date?
        var isComplete: Bool = false
        var customName: String?
        var destinationSummary: String = ""
        var countryCodes: String = ""
        var classifiedByAI: Bool = false
        var userEdited: Bool = false
        @Relationship(deleteRule: .nullify, inverse: \Stay.trip)
        var stays: [Stay]?

        init() {}
    }

    /// V5-era HiddenPhoto: no `cloudIdentifier` (that was added in V7).
    @Model final class HiddenPhoto {
        var id: UUID = UUID()
        var localIdentifier: String = ""
        var tripID: UUID = UUID()
        var hiddenAt: Date = Date.now

        init(localIdentifier: String, tripID: UUID) {
            self.id = UUID()
            self.localIdentifier = localIdentifier
            self.tripID = tripID
            self.hiddenAt = .now
        }
    }
}

// MARK: - V6 Schema (Pinned Photos) - FROZEN LocationPing/Stay/Trip + photo annotations

/// Adds PinnedPhoto, a per-trip user-pinned/favorited photo list.
/// Lightweight migration: brand-new entity, no changes
/// to existing model shapes.
///
/// **Frozen note:** `HiddenPhoto` and `PinnedPhoto` are inline-declared at
/// their V6-era shape (no `cloudIdentifier`, added in V7). This preserves V6's
/// structural hash for the on-disk store written by devices that were last at
/// V6; freezing prevents staged migration from seeing an unknown model version.
///
/// `LocationPing`, `Stay`, `Trip` are also inline-declared at their V6-era
/// shape (no `sourceRaw`, added in V8) — frozen alongside the V7→V8 bump.
/// `Home`, `RoutinePlace`, `HexVisit` remain live references (unchanged since V2).
enum TravelLogSchemaV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(6, 0, 0)

    // HexVisit frozen at its pre-`id` shape (see SchemaFrozenModels).
    typealias HexVisit = SchemaFrozenModels.HexVisit

    static var models: [any PersistentModel.Type] {
        [
            LocationPing.self,    // resolves to TravelLogSchemaV6.LocationPing below
            Stay.self,            // resolves to TravelLogSchemaV6.Stay below
            Trip.self,            // resolves to TravelLogSchemaV6.Trip below
            Home.self,            // live; unchanged since V2
            RoutinePlace.self,    // live; unchanged since V2
            HexVisit.self,        // live; unchanged since V2
            HiddenPhoto.self,     // resolves to TravelLogSchemaV6.HiddenPhoto below
            PinnedPhoto.self,     // resolves to TravelLogSchemaV6.PinnedPhoto below
        ]
    }

    /// V6-era LocationPing: no `sourceRaw` (added in V8).
    @Model final class LocationPing {
        var id: UUID = UUID()
        var timestamp: Date = Date.now
        var latitude: Double = 0
        var longitude: Double = 0
        var horizontalAccuracy: Double = 0
        var h3IndexRes6: String = ""
        var locality: String?
        var subLocality: String?
        var administrativeArea: String?
        var country: String?
        var isoCountryCode: String?
        var isGeocoded: Bool = false
        var isProcessed: Bool = false

        init() {}
    }

    /// V6-era Stay: no `sourceRaw` (added in V8).
    @Model final class Stay {
        var id: UUID = UUID()
        var startTime: Date = Date.now
        var endTime: Date = Date.now
        var durationMinutes: Int = 0
        var centroidLatitude: Double = 0
        var centroidLongitude: Double = 0
        var locality: String?
        var administrativeArea: String?
        var country: String?
        var isoCountryCode: String?
        var h3IndexRes6: String = ""
        var pingCount: Int = 0
        var distanceFromHomeKm: Double = 0
        var categoryRaw: String = ""
        var userOverridden: Bool = false
        var continuesPreviousTrip: Bool = false
        @Relationship var trip: Trip?
        var orderInTrip: Int?
        var pingIDsString: String = ""

        init() {}
    }

    /// V6-era Trip: no `sourceRaw` (added in V8).
    @Model final class Trip {
        var id: UUID = UUID()
        var startDate: Date = Date.now
        var endDate: Date?
        var isComplete: Bool = false
        var customName: String?
        var destinationSummary: String = ""
        var countryCodes: String = ""
        var classifiedByAI: Bool = false
        var userEdited: Bool = false
        @Relationship(deleteRule: .nullify, inverse: \Stay.trip)
        var stays: [Stay]?

        init() {}
    }

    /// V6-era HiddenPhoto: no `cloudIdentifier` (added in V7).
    @Model final class HiddenPhoto {
        var id: UUID = UUID()
        var localIdentifier: String = ""
        var tripID: UUID = UUID()
        var hiddenAt: Date = Date.now

        init(localIdentifier: String, tripID: UUID) {
            self.id = UUID()
            self.localIdentifier = localIdentifier
            self.tripID = tripID
            self.hiddenAt = .now
        }
    }

    /// V6-era PinnedPhoto: no `cloudIdentifier` (added in V7).
    @Model final class PinnedPhoto {
        var id: UUID = UUID()
        var localIdentifier: String = ""
        var tripID: UUID = UUID()
        var pinnedAt: Date = Date.now

        init(localIdentifier: String, tripID: UUID) {
            self.id = UUID()
            self.localIdentifier = localIdentifier
            self.tripID = tripID
            self.pinnedAt = .now
        }
    }
}

// MARK: - V7 Schema (Cross-Device Photo Identity)

/// Adds an optional `cloudIdentifier: String?` column to `HiddenPhoto` and
/// `PinnedPhoto`. `PHAsset.localIdentifier` is per-device on iCloud Photos
/// libraries, so hide/pin state didn't propagate correctly across devices
/// (the row synced but the localIdentifier didn't match anything on the
/// receiving device). `PHCloudIdentifier` is the canonical, cross-device,
/// stable identifier — `PhotoService` now captures it at hide/pin time (in
/// the background, best-effort) and uses it to translate back to *this
/// device's* localIdentifier at read time.
///
/// Lightweight migration: a single optional column added to two existing
/// models. Optional is required by both SwiftData lightweight-migration
/// semantics and CloudKit's "no nil for non-optional keypath" rule for
/// new attributes on existing record types.
/// **Frozen note (V7→V8 prep):** `LocationPing`, `Stay`, `Trip` are
/// inline-declared here at their V7-era shape (no `sourceRaw` — added in V8)
/// so V7's structural hash stays anchored to what's currently on disk for
/// users at V7 once the live model files gain the new field.
/// Any model whose shape will change in V8 must be
/// inline-frozen in V7 *before* the live file is edited.
///
/// `HiddenPhoto`, `PinnedPhoto`, `Home`, `RoutinePlace`, `HexVisit` remain
/// live references — none of them changes shape in V8.
enum TravelLogSchemaV7: VersionedSchema {
    static let versionIdentifier = Schema.Version(7, 0, 0)

    // HexVisit frozen at its pre-`id` shape (see SchemaFrozenModels).
    typealias HexVisit = SchemaFrozenModels.HexVisit

    static var models: [any PersistentModel.Type] {
        [
            LocationPing.self,    // resolves to TravelLogSchemaV7.LocationPing below
            Stay.self,            // resolves to TravelLogSchemaV7.Stay below
            Trip.self,            // resolves to TravelLogSchemaV7.Trip below
            Home.self,            // live; unchanged in V8
            RoutinePlace.self,    // live; unchanged in V8
            HexVisit.self,        // live; unchanged in V8
            HiddenPhoto.self,     // live; unchanged in V8 (cloudIdentifier was added in V7)
            PinnedPhoto.self,     // live; unchanged in V8 (cloudIdentifier was added in V7)
        ]
    }

    /// V7-era LocationPing: no `sourceRaw` (added in V8).
    @Model final class LocationPing {
        var id: UUID = UUID()
        var timestamp: Date = Date.now
        var latitude: Double = 0
        var longitude: Double = 0
        var horizontalAccuracy: Double = 0
        var h3IndexRes6: String = ""
        var locality: String?
        var subLocality: String?
        var administrativeArea: String?
        var country: String?
        var isoCountryCode: String?
        var isGeocoded: Bool = false
        var isProcessed: Bool = false

        init() {}
    }

    /// V7-era Stay: no `sourceRaw` (added in V8).
    @Model final class Stay {
        var id: UUID = UUID()
        var startTime: Date = Date.now
        var endTime: Date = Date.now
        var durationMinutes: Int = 0
        var centroidLatitude: Double = 0
        var centroidLongitude: Double = 0
        var locality: String?
        var administrativeArea: String?
        var country: String?
        var isoCountryCode: String?
        var h3IndexRes6: String = ""
        var pingCount: Int = 0
        var distanceFromHomeKm: Double = 0
        var categoryRaw: String = ""
        var userOverridden: Bool = false
        var continuesPreviousTrip: Bool = false
        @Relationship var trip: Trip?
        var orderInTrip: Int?
        var pingIDsString: String = ""

        init() {}
    }

    /// V7-era Trip: no `sourceRaw` (added in V8).
    @Model final class Trip {
        var id: UUID = UUID()
        var startDate: Date = Date.now
        var endDate: Date?
        var isComplete: Bool = false
        var customName: String?
        var destinationSummary: String = ""
        var countryCodes: String = ""
        var classifiedByAI: Bool = false
        var userEdited: Bool = false
        @Relationship(deleteRule: .nullify, inverse: \Stay.trip)
        var stays: [Stay]?

        init() {}
    }
}

// MARK: - V8 Schema (Photo Library Import — Provenance + Import State) — FROZEN Stay/Trip

/// Adds `sourceRaw: String` to `LocationPing`, `Stay`, and `Trip` (defaulted
/// to `"liveSLC"` so V7→V8 lightweight migration backfills every pre-existing
/// row safely). Adds the `PhotoImportState` singleton-style model that tracks
/// the lifecycle of a photo-library import (status, watermark, error, origin
/// device).
///
/// All five changes are additive and CloudKit-safe:
///   - `sourceRaw` is a defaulted scalar `String` (no unique constraint, no
///     array attribute, no relationship change).
///   - `PhotoImportState` is a brand-new entity with only scalar fields and
///     no relationships.
///
/// V7's inline-freeze of `LocationPing` / `Stay` / `Trip` (see V7 enum above)
/// is what makes this migration safe: V7's structural hash remains anchored
/// to its pre-V8 shape regardless of what the live model files now look like.
///
/// **Frozen note (V8→V9 prep):** `Stay` and `Trip` are inline-declared here
/// at their V8-era shape so V8's structural hash stays anchored to what's
/// currently on disk for users at V8 once the live model files gain V9's new
/// fields (`Stay.isAirport`, `Trip.aiGeneratedTitle`).
/// Any model whose shape will change in V9 must be inline-frozen in V8
/// *before* the live file is edited. `LocationPing` remains a live reference
/// — its shape doesn't change in V9.
enum TravelLogSchemaV8: VersionedSchema {
    static let versionIdentifier = Schema.Version(8, 0, 0)

    // HexVisit frozen at its pre-`id` shape (see SchemaFrozenModels).
    typealias HexVisit = SchemaFrozenModels.HexVisit
    // LocationPing frozen at its pre-`altitude` shape (see SchemaFrozenModels). V13
    typealias LocationPing = SchemaFrozenModels.LocationPing

    static var models: [any PersistentModel.Type] {
        [
            LocationPing.self,        // live; unchanged in V9 (gained `sourceRaw` in V8)
            Stay.self,                // resolves to TravelLogSchemaV8.Stay below
            Trip.self,                // resolves to TravelLogSchemaV8.Trip below
            Home.self,                // live; unchanged since V2
            RoutinePlace.self,        // live; unchanged since V2
            HexVisit.self,            // live; unchanged since V2
            HiddenPhoto.self,         // live; unchanged since V7 (cloudIdentifier)
            PinnedPhoto.self,         // live; unchanged since V7 (cloudIdentifier)
            PhotoImportState.self,    // live; new in V8
        ]
    }

    /// V8-era Stay: no `isAirport` (added in V9).
    @Model final class Stay {
        var id: UUID = UUID()
        var startTime: Date = Date.now
        var endTime: Date = Date.now
        var durationMinutes: Int = 0
        var centroidLatitude: Double = 0
        var centroidLongitude: Double = 0
        var locality: String?
        var administrativeArea: String?
        var country: String?
        var isoCountryCode: String?
        var h3IndexRes6: String = ""
        var pingCount: Int = 0
        var distanceFromHomeKm: Double = 0
        var categoryRaw: String = ""
        var userOverridden: Bool = false
        var continuesPreviousTrip: Bool = false
        @Relationship var trip: Trip?
        var orderInTrip: Int?
        var pingIDsString: String = ""
        var sourceRaw: String = "liveSLC"

        init() {}
    }

    /// V8-era Trip: no `aiGeneratedTitle` (added in V9).
    @Model final class Trip {
        var id: UUID = UUID()
        var startDate: Date = Date.now
        var endDate: Date?
        var isComplete: Bool = false
        var customName: String?
        var destinationSummary: String = ""
        var countryCodes: String = ""
        var classifiedByAI: Bool = false
        var userEdited: Bool = false
        var sourceRaw: String = "liveSLC"
        @Relationship(deleteRule: .nullify, inverse: \Stay.trip)
        var stays: [Stay]?

        init() {}
    }
}

// MARK: - V9 Schema (Smart Trip Titles + Airport Detection)

/// Adds defaulted scalar `Stay.isAirport` and optional `Trip.aiGeneratedTitle`.
///
/// Both are lightweight: defaulted scalars added to existing CloudKit-synced
/// models. No new entities. V8's inline-frozen `Stay` and `Trip` (above)
/// anchor V8's structural hash so the V8→V9 lightweight migration is
/// recognized cleanly on devices currently at V8.
enum TravelLogSchemaV9: VersionedSchema {
    static let versionIdentifier = Schema.Version(9, 0, 0)

    // HexVisit frozen at its pre-`id` shape (see SchemaFrozenModels).
    typealias HexVisit = SchemaFrozenModels.HexVisit
    // LocationPing frozen at its pre-`altitude` shape (see SchemaFrozenModels). V13
    typealias LocationPing = SchemaFrozenModels.LocationPing

    static var models: [any PersistentModel.Type] {
        [
            LocationPing.self,        // live; unchanged in V10
            Stay.self,                // resolves to TravelLogSchemaV9.Stay below
            Trip.self,                // resolves to TravelLogSchemaV9.Trip below
            Home.self,                // live; unchanged since V2
            RoutinePlace.self,        // live; unchanged since V2
            HexVisit.self,            // live; unchanged since V2
            HiddenPhoto.self,         // live; unchanged since V7
            PinnedPhoto.self,         // live; unchanged since V7
            PhotoImportState.self,    // live; unchanged since V8
        ]
    }

    /// V9-era Stay: gained `isAirport` in V9; lacks the V10
    /// additions (`subLocality`, `metroName`, `islandName`).
    /// Inline-frozen so V9's structural hash stays stable when the
    /// live `Stay` gains its V10 fields. Devices currently at V9 use
    /// this shape as their on-disk schema; the V9→V10 migration
    /// (additive lightweight) adds the 3 optional columns.
    @Model final class Stay {
        var id: UUID = UUID()
        var startTime: Date = Date.now
        var endTime: Date = Date.now
        var durationMinutes: Int = 0
        var centroidLatitude: Double = 0
        var centroidLongitude: Double = 0
        var locality: String?
        var administrativeArea: String?
        var country: String?
        var isoCountryCode: String?
        var isAirport: Bool = false
        var h3IndexRes6: String = ""
        var pingCount: Int = 0
        var distanceFromHomeKm: Double = 0
        var categoryRaw: String = ""
        var userOverridden: Bool = false
        var continuesPreviousTrip: Bool = false
        @Relationship var trip: Trip?
        var orderInTrip: Int?
        var pingIDsString: String = ""
        var sourceRaw: String = "liveSLC"

        init() {}
    }

    /// V9-era Trip: unchanged in V10, but inline-frozen here ANYWAY
    /// to keep the `Stay.trip ↔ Trip.stays` inverse-relationship type
    /// identity consistent within the V9 schema. BOTH must freeze so
    /// V9's relationship graph stays closed over its own frozen types.
    @Model final class Trip {
        var id: UUID = UUID()
        var startDate: Date = Date.now
        var endDate: Date?
        var isComplete: Bool = false
        var customName: String?
        var destinationSummary: String = ""
        var countryCodes: String = ""
        var classifiedByAI: Bool = false
        var userEdited: Bool = false
        var aiGeneratedTitle: String?
        var sourceRaw: String = "liveSLC"
        @Relationship(deleteRule: .nullify, inverse: \Stay.trip)
        var stays: [Stay]?

        init() {}
    }
}

// MARK: - V10 Schema (Offline Geocoder — subLocality / metroName / islandName)

/// Adds optional `Stay.subLocality`, `Stay.metroName`, and `Stay.islandName` from the offline geocoder.
///
/// All three are additive optional Strings — V9→V10 is lightweight.
/// V9’s Stay and Trip must both be inline-frozen to anchor its structural hash.
///
/// Backfill re-geocodes Stay, LocationPing, and HexVisit and populates the three new Stay fields.
enum TravelLogSchemaV10: VersionedSchema {
    static let versionIdentifier = Schema.Version(10, 0, 0)

    // HexVisit frozen at its pre-`id` shape (see SchemaFrozenModels).
    typealias HexVisit = SchemaFrozenModels.HexVisit
    // LocationPing frozen at its pre-`altitude` shape (see SchemaFrozenModels). V13
    typealias LocationPing = SchemaFrozenModels.LocationPing

    static var models: [any PersistentModel.Type] {
        [
            LocationPing.self,        // live; unchanged in V11
            Stay.self,                // resolves to TravelLogSchemaV10.Stay below
            Trip.self,                // resolves to TravelLogSchemaV10.Trip below
            Home.self,                // live; unchanged since V2
            RoutinePlace.self,        // live; unchanged since V2
            HexVisit.self,            // live; unchanged since V2
            HiddenPhoto.self,         // live; unchanged since V7
            PinnedPhoto.self,         // live; unchanged since V7
            PhotoImportState.self,    // live; unchanged since V8
        ]
    }

    /// V10-era Stay: gained `subLocality`/`metroName`/`islandName` in V10;
    /// lacks the V11 additions (weather fields, transit mode, steps, dayKey).
    /// Inline-frozen so V10's structural hash stays stable when the live
    /// `Stay` gains its V11 fields. Both Stay AND Trip are frozen to keep
    /// the `Stay.trip ↔ Trip.stays` inverse relationship's type identity
    /// closed within V10's schema graph.
    @Model final class Stay {
        var id: UUID = UUID()
        var startTime: Date = Date.now
        var endTime: Date = Date.now
        var durationMinutes: Int = 0
        var centroidLatitude: Double = 0
        var centroidLongitude: Double = 0
        var locality: String?
        var administrativeArea: String?
        var country: String?
        var isoCountryCode: String?
        var subLocality: String?
        var metroName: String?
        var islandName: String?
        var isAirport: Bool = false
        var h3IndexRes6: String = ""
        var pingCount: Int = 0
        var distanceFromHomeKm: Double = 0
        var categoryRaw: String = ""
        var userOverridden: Bool = false
        var continuesPreviousTrip: Bool = false
        @Relationship var trip: Trip?
        var orderInTrip: Int?
        var pingIDsString: String = ""
        var sourceRaw: String = "liveSLC"

        init() {}
    }

    /// V10-era Trip: unchanged from V9, but inline-frozen here to keep the
    /// `Stay.trip ↔ Trip.stays` inverse relationship type-consistent within
    /// the V10 schema graph. Without both frozen, V10.Stay.trip → live Trip
    /// while live Trip.stays → V10.Stay, causing relationship-type drift.
    @Model final class Trip {
        var id: UUID = UUID()
        var startDate: Date = Date.now
        var endDate: Date?
        var isComplete: Bool = false
        var customName: String?
        var destinationSummary: String = ""
        var countryCodes: String = ""
        var aiGeneratedTitle: String?
        var classifiedByAI: Bool = false
        var userEdited: Bool = false
        var sourceRaw: String = "liveSLC"
        @Relationship(deleteRule: .nullify, inverse: \Stay.trip)
        var stays: [Stay]?

        init() {}
    }
}

// MARK: - V11 Schema (Weather + Transit + FM Summaries + YearWrapped)

/// Adds weather enrichment, transit-mode inference, FM trip summaries, and
/// the `YearWrapped` entity for annual recaps.
///
/// **Stay gains 8 fields:**
///   - Weather: `weatherData` (Codable blob), `avgTemperatureC`,
///     `weatherConditionRaw`, `precipitationMm`, `dayKey` (cache key).
///   - Transit: `transitFromPreviousRaw`, `distanceFromPreviousKm`.
///   - Pedometer: `stepsWalked`.
///
/// **Trip gains 4 fields:**
///   - `aiGeneratedSummary`, `summaryGeneratedAt`,
///     `summaryGenerationVersion`, `summarySourceRaw`.
///
/// **New entity: `YearWrapped`** — annual recap snapshot, CloudKit-synced.
///   No `@Attribute(.unique)` on year (CloudKit incompatible); uniqueness
///   enforced by fetch-before-insert + `YearWrappedDeduplicator`.
///
/// All additive optional fields → V10→V11 is lightweight. V10 inline-
/// freezes both `Stay` and `Trip` (above) so V10's structural hash is
/// anchored.
enum TravelLogSchemaV11: VersionedSchema {
    static let versionIdentifier = Schema.Version(11, 0, 0)

    // HexVisit frozen at its pre-`id` shape (see SchemaFrozenModels).
    typealias HexVisit = SchemaFrozenModels.HexVisit
    // LocationPing frozen at its pre-`altitude` shape (see SchemaFrozenModels). V13
    typealias LocationPing = SchemaFrozenModels.LocationPing
    // V16 changes live Trip; freeze the full historical inverse graph.
    typealias Stay = SchemaFrozenModels.Stay
    typealias Trip = SchemaFrozenModels.Trip

    static var models: [any PersistentModel.Type] {
        [
            LocationPing.self,        // live; unchanged in V11
            Stay.self,                // frozen V11 shape; see SchemaFrozenModels
            Trip.self,                // frozen V11 shape; see SchemaFrozenModels
            Home.self,                // live; unchanged since V2
            RoutinePlace.self,        // live; unchanged since V2
            HexVisit.self,            // live; unchanged since V2
            HiddenPhoto.self,         // live; unchanged since V7
            PinnedPhoto.self,         // live; unchanged since V7
            PhotoImportState.self,    // live; unchanged since V8
            YearWrapped.self,         // NEW in V11
        ]
    }
}

// MARK: - V12 Schema (HexVisit gains a stable `id` for dedup)

/// Adds `UUID id` to `HexVisit` so `HexVisitDeduplicator` has a stable,
/// CloudKit-syncable cross-device key. All other models
/// are unchanged from V11; the new field is defaulted so V11→V12 is a
/// lightweight migration. `HexVisit.self` here resolves to the LIVE `HexVisit`
/// (with `id`) because V12 — unlike V3…V11 — declares no `typealias HexVisit`.
/// `LocationPing` is aliased to its frozen pre-`altitude` shape (frozen for
/// V13; the live model gained `altitude` / `verticalAccuracy` then).
enum TravelLogSchemaV12: VersionedSchema {
    static let versionIdentifier = Schema.Version(12, 0, 0)

    // LocationPing frozen at its pre-`altitude` shape (see SchemaFrozenModels). V13
    typealias LocationPing = SchemaFrozenModels.LocationPing
    // V16 changes live Trip; freeze the full historical inverse graph.
    typealias Stay = SchemaFrozenModels.Stay
    typealias Trip = SchemaFrozenModels.Trip

    static var models: [any PersistentModel.Type] {
        [
            LocationPing.self,
            Stay.self,
            Trip.self,
            Home.self,
            RoutinePlace.self,
            HexVisit.self,            // live; gained `id` in V12
            HiddenPhoto.self,
            PinnedPhoto.self,
            PhotoImportState.self,
            YearWrapped.self,
        ]
    }
}

// MARK: - V13 Schema (LocationPing gains altitude + verticalAccuracy)

/// Adds `altitude: Double?` and `verticalAccuracy: Double?` to `LocationPing`
/// to retain aerial-versus-surface evidence. Both fields are additive, defaulted-nil optional scalars
/// (CloudKit-safe: no unique, no array, no relationship), so V12→V13 is a
/// lightweight migration that backfills nil on every existing row; only NEW
/// pings populate them (live capture + a re-import EXIF backfill). `verticalAccuracy`
/// negative ⇒ the altitude reading is invalid (cell/Wi-Fi fix, no GPS lock).
/// `LocationPing.self` here resolves to the LIVE model (with altitude) because
/// V13 — unlike V8…V12 — declares no `typealias LocationPing`. All other models
/// are unchanged from V12. MUST be runtime-validated on device
/// (install old → upgrade → fetch) before shipping.
enum TravelLogSchemaV13: VersionedSchema {
    static let versionIdentifier = Schema.Version(13, 0, 0)

    // V16 changes live Trip; freeze the full historical inverse graph.
    typealias Stay = SchemaFrozenModels.Stay
    typealias Trip = SchemaFrozenModels.Trip

    static var models: [any PersistentModel.Type] {
        [
            LocationPing.self,        // live; gained altitude/verticalAccuracy in V13
            Stay.self,
            Trip.self,
            Home.self,
            RoutinePlace.self,
            HexVisit.self,
            HiddenPhoto.self,
            PinnedPhoto.self,
            PhotoImportState.self,
            YearWrapped.self,
        ]
    }
}

// MARK: - V14 Schema (adds the PlannedTrip entity)

/// Adds `PlannedTrip` — a calendar-detected future trip (see the model's doc).
/// Pure-additive: a wholly new entity, no existing model's shape changes, so
/// V13 needs no inline freeze/alias (same class of bump as V5 `HiddenPhoto` /
/// V6 `PinnedPhoto`; the freeze rule only fires when a model that an earlier
/// version references changes shape). `PlannedTrip` is CloudKit-clean: no
/// unique constraints, no arrays, no relationships, every field optional or
/// defaulted → V13→V14 is a lightweight migration that simply creates the new
/// table. All other models are unchanged from V13. MUST be runtime-validated
/// on device (install old → upgrade → fetch) before shipping.
enum TravelLogSchemaV14: VersionedSchema {
    static let versionIdentifier = Schema.Version(14, 0, 0)

    // V16 changes live Trip; freeze the full historical inverse graph.
    typealias Stay = SchemaFrozenModels.Stay
    typealias Trip = SchemaFrozenModels.Trip

    static var models: [any PersistentModel.Type] {
        [
            LocationPing.self,
            Stay.self,
            Trip.self,
            Home.self,
            RoutinePlace.self,
            HexVisit.self,
            HiddenPhoto.self,
            PinnedPhoto.self,
            PhotoImportState.self,
            YearWrapped.self,
            PlannedTrip.self,         // new in V14
        ]
    }
}

// MARK: - V15 Schema (adds the HomeAreaOverride entity)

/// Adds `HomeAreaOverride` for home-area include discs and learned-place exclusions.
/// Pure-additive: a wholly new entity, no existing
/// model's shape changes, so V14 needs no inline freeze/alias (the same class
/// of bump as V14's `PlannedTrip`). CloudKit-clean: no unique constraints, no
/// arrays, no relationships, every field optional or defaulted → V14→V15 is a
/// lightweight migration that simply creates the new table. All other models
/// are unchanged from V14. MUST be runtime-validated on device (install old →
/// upgrade → fetch) before shipping.
enum TravelLogSchemaV15: VersionedSchema {
    static let versionIdentifier = Schema.Version(15, 0, 0)

    // V16 changes live Trip; freeze the full historical inverse graph.
    typealias Stay = SchemaFrozenModels.Stay
    typealias Trip = SchemaFrozenModels.Trip

    static var models: [any PersistentModel.Type] {
        [
            LocationPing.self,
            Stay.self,
            Trip.self,
            Home.self,
            RoutinePlace.self,
            HexVisit.self,
            HiddenPhoto.self,
            PinnedPhoto.self,
            PhotoImportState.self,
            YearWrapped.self,
            PlannedTrip.self,
            HomeAreaOverride.self,    // new in V15
        ]
    }
}

// MARK: - Frozen V16–V17 Stay/Trip/TripTitleVariant graph

/// The exact persisted shapes V16 and V17 wrote to disk, frozen before V18
/// adds `Stay.timeZoneIdentifier`. All three must freeze together: `Trip`
/// closes the `Stay.trip ↔ Trip.stays` inverse, and `TripTitleVariant`
/// closes `Trip.localizedTitles ↔ TripTitleVariant.trip` — leaving either
/// side live would point a frozen relationship at a live type.
/// DO NOT EDIT — this freezes schema history.
enum SchemaFrozenModelsV17 {
    @Model final class Stay {
        var id: UUID = UUID()
        var startTime: Date = Date.now
        var endTime: Date = Date.now
        var durationMinutes: Int = 0
        var centroidLatitude: Double = 0
        var centroidLongitude: Double = 0
        var locality: String?
        var administrativeArea: String?
        var country: String?
        var isoCountryCode: String?
        var subLocality: String?
        var metroName: String?
        var islandName: String?
        var weatherData: Data?
        var avgTemperatureC: Double?
        var weatherConditionRaw: String?
        var precipitationMm: Double?
        var dayKey: Date?
        var transitFromPreviousRaw: String?
        var distanceFromPreviousKm: Double?
        var stepsWalked: Int?
        var isAirport: Bool = false
        var h3IndexRes6: String = ""
        var pingCount: Int = 0
        var distanceFromHomeKm: Double = 0
        var categoryRaw: String = ""
        var userOverridden: Bool = false
        var continuesPreviousTrip: Bool = false
        @Relationship var trip: Trip?
        var orderInTrip: Int?
        var pingIDsString: String = ""
        var sourceRaw: String = "liveSLC"

        init() {}
    }

    @Model final class Trip {
        var id: UUID = UUID()
        var startDate: Date = Date.now
        var endDate: Date?
        var isComplete: Bool = false
        var customName: String?
        var destinationSummary: String = ""
        var countryCodes: String = ""
        var aiGeneratedTitle: String?
        var titleSourceRevision: UUID?
        var aiGeneratedSummary: String?
        var summaryGeneratedAt: Date?
        var summaryGenerationVersion: Int?
        var summarySourceRaw: String?
        var classifiedByAI: Bool = false
        var userEdited: Bool = false
        var sourceRaw: String = "liveSLC"
        @Relationship(deleteRule: .nullify, inverse: \Stay.trip)
        var stays: [Stay]?
        @Relationship(deleteRule: .cascade, inverse: \TripTitleVariant.trip)
        var localizedTitles: [TripTitleVariant]?

        init() {}
    }

    @Model final class TripTitleVariant {
        var id: UUID = UUID()
        var languageTag: String = ""
        var title: String = ""
        var sourceTitle: String = ""
        var sourceRevision: UUID?
        var generationVersion: Int = 1
        var updatedAt: Date = Date.now
        @Relationship var trip: Trip?

        init() {}
    }
}

// MARK: - V16 Schema (localized AI-title variants)

/// Adds `TripTitleVariant`, one localized rendering of a Trip's canonical
/// `aiGeneratedTitle`, a source-revision UUID on both records, and an optional
/// inverse relationship on `Trip`.
///
/// V11 through V15 previously referenced the live Stay/Trip relationship
/// graph. Both models are frozen above and aliased by every one of those
/// schemas before the live Trip changes here; freezing only V15 would still
/// change the structural hashes of stores written at V11–V14.
///
/// The new entity has no unique constraints, all scalar fields are defaulted,
/// and both relationship sides are optional. Trip owns variants with a
/// cascade delete rule because they are derived children with no independent
/// lifetime. V15→V16 is therefore an additive lightweight migration, subject
/// to the standing physical-device upgrade validation before shipping.
enum TravelLogSchemaV16: VersionedSchema {
    static let versionIdentifier = Schema.Version(16, 0, 0)
    // Frozen since V18 (`Stay.timeZoneIdentifier`); see `SchemaFrozenModelsV17`.
    typealias Stay = SchemaFrozenModelsV17.Stay
    typealias Trip = SchemaFrozenModelsV17.Trip
    typealias TripTitleVariant = SchemaFrozenModelsV17.TripTitleVariant

    static var models: [any PersistentModel.Type] {
        [
            LocationPing.self,
            Stay.self,
            Trip.self,                // gained optional localizedTitles in V16
            Home.self,
            RoutinePlace.self,
            HexVisit.self,
            HiddenPhoto.self,
            PinnedPhoto.self,
            PhotoImportState.self,
            YearWrapped.self,
            PlannedTrip.self,
            HomeAreaOverride.self,
            TripTitleVariant.self,    // new in V16
        ]
    }
}

// MARK: - V17 Schema (Core Location visits)

/// Pure-additive Visit evidence. Existing model shapes are unchanged.
enum TravelLogSchemaV17: VersionedSchema {
    static let versionIdentifier = Schema.Version(17, 0, 0)
    // Frozen since V18 (`Stay.timeZoneIdentifier`); see `SchemaFrozenModelsV17`.
    typealias Stay = SchemaFrozenModelsV17.Stay
    typealias Trip = SchemaFrozenModelsV17.Trip
    typealias TripTitleVariant = SchemaFrozenModelsV17.TripTitleVariant

    static var models: [any PersistentModel.Type] {
        [
            LocationPing.self,
            Stay.self,
            Trip.self,
            Home.self,
            RoutinePlace.self,
            HexVisit.self,
            HiddenPhoto.self,
            PinnedPhoto.self,
            PhotoImportState.self,
            YearWrapped.self,
            PlannedTrip.self,
            HomeAreaOverride.self,
            TripTitleVariant.self,
            Visit.self,
        ]
    }
}

// MARK: - V18 Schema (stay time zones)

/// Adds the optional `Stay.timeZoneIdentifier` so trip day counts can be
/// taken in the calendar of the place where each boundary stay happened
/// instead of the viewing device's zone. Pure-additive, optional, no
/// constraints: a lightweight migration, subject to the standing
/// physical-device upgrade validation before shipping.
enum TravelLogSchemaV18: VersionedSchema {
    static let versionIdentifier = Schema.Version(18, 0, 0)
    // Frozen since V20 (`Stay.temporaryHomeID`); see `SchemaFrozenModelsV19`.
    typealias Stay = SchemaFrozenModelsV19.Stay
    typealias Trip = SchemaFrozenModelsV19.Trip
    typealias TripTitleVariant = SchemaFrozenModelsV19.TripTitleVariant

    static var models: [any PersistentModel.Type] {
        [
            LocationPing.self,
            Stay.self,                // gained optional timeZoneIdentifier in V18
            Trip.self,
            Home.self,
            RoutinePlace.self,
            HexVisit.self,
            HiddenPhoto.self,
            PinnedPhoto.self,
            PhotoImportState.self,
            YearWrapped.self,
            PlannedTrip.self,
            HomeAreaOverride.self,
            TripTitleVariant.self,
            Visit.self,
        ]
    }
}

// MARK: - V19 Schema (adds the TemporaryHome entity)

/// Adds `TemporaryHome`, a dated place the user declares as a temporary home
/// (see the model's doc). Pure-additive: a wholly new entity, no existing
/// model's shape changes, so V18 needs no inline freeze/alias (the same class
/// of bump as V15's `HomeAreaOverride` and V17's `Visit`). CloudKit-clean: no
/// unique constraints, no arrays, no relationships, every field optional or
/// defaulted, so V18→V19 is a lightweight migration that simply creates the
/// new table. All other models are unchanged from V18. MUST be
/// runtime-validated on device (install old → upgrade → fetch) before shipping.
enum TravelLogSchemaV19: VersionedSchema {
    static let versionIdentifier = Schema.Version(19, 0, 0)
    // Frozen since V20 (`Stay.temporaryHomeID`, `Trip.keptByTemporaryHome`,
    // `TemporaryHome.removedAt`); see `SchemaFrozenModelsV19`.
    typealias Stay = SchemaFrozenModelsV19.Stay
    typealias Trip = SchemaFrozenModelsV19.Trip
    typealias TripTitleVariant = SchemaFrozenModelsV19.TripTitleVariant
    typealias TemporaryHome = SchemaFrozenModelsV19.TemporaryHome

    static var models: [any PersistentModel.Type] {
        [
            LocationPing.self,
            Stay.self,
            Trip.self,
            Home.self,
            RoutinePlace.self,
            HexVisit.self,
            HiddenPhoto.self,
            PinnedPhoto.self,
            PhotoImportState.self,
            YearWrapped.self,
            PlannedTrip.self,
            HomeAreaOverride.self,
            TripTitleVariant.self,
            Visit.self,
            TemporaryHome.self,       // new in V19
        ]
    }
}

// MARK: - Frozen V18–V19 Stay/Trip/TripTitleVariant graph and V19 TemporaryHome

/// The exact persisted shapes V18 and V19 wrote to disk, frozen before V20
/// adds `Stay.temporaryHomeID`, `Trip.keptByTemporaryHome` and
/// `TemporaryHome.removedAt`. `Stay`, `Trip` and `TripTitleVariant` freeze
/// together for the reason `SchemaFrozenModelsV17` gives: each closes an
/// inverse relationship of another. `TemporaryHome` has no relationship and
/// is referenced by V19 only. DO NOT EDIT — this freezes schema history.
enum SchemaFrozenModelsV19 {
    @Model final class Stay {
        var id: UUID = UUID()
        var startTime: Date = Date.now
        var endTime: Date = Date.now
        var durationMinutes: Int = 0
        var centroidLatitude: Double = 0
        var centroidLongitude: Double = 0
        var locality: String?
        var administrativeArea: String?
        var country: String?
        var isoCountryCode: String?
        var subLocality: String?
        var metroName: String?
        var islandName: String?
        var weatherData: Data?
        var avgTemperatureC: Double?
        var weatherConditionRaw: String?
        var precipitationMm: Double?
        var dayKey: Date?
        var transitFromPreviousRaw: String?
        var distanceFromPreviousKm: Double?
        var stepsWalked: Int?
        var isAirport: Bool = false
        var h3IndexRes6: String = ""
        var pingCount: Int = 0
        var distanceFromHomeKm: Double = 0
        var categoryRaw: String = ""
        var userOverridden: Bool = false
        var continuesPreviousTrip: Bool = false
        @Relationship var trip: Trip?
        var orderInTrip: Int?
        var pingIDsString: String = ""
        var sourceRaw: String = "liveSLC"
        var timeZoneIdentifier: String?

        init() {}
    }

    @Model final class Trip {
        var id: UUID = UUID()
        var startDate: Date = Date.now
        var endDate: Date?
        var isComplete: Bool = false
        var customName: String?
        var destinationSummary: String = ""
        var countryCodes: String = ""
        var aiGeneratedTitle: String?
        var titleSourceRevision: UUID?
        var aiGeneratedSummary: String?
        var summaryGeneratedAt: Date?
        var summaryGenerationVersion: Int?
        var summarySourceRaw: String?
        var classifiedByAI: Bool = false
        var userEdited: Bool = false
        var sourceRaw: String = "liveSLC"
        @Relationship(deleteRule: .nullify, inverse: \Stay.trip)
        var stays: [Stay]?
        @Relationship(deleteRule: .cascade, inverse: \TripTitleVariant.trip)
        var localizedTitles: [TripTitleVariant]?

        init() {}
    }

    @Model final class TripTitleVariant {
        var id: UUID = UUID()
        var languageTag: String = ""
        var title: String = ""
        var sourceTitle: String = ""
        var sourceRevision: UUID?
        var generationVersion: Int = 1
        var updatedAt: Date = Date.now
        @Relationship var trip: Trip?

        init() {}
    }

    @Model final class TemporaryHome {
        var id: UUID = UUID()
        var label: String = ""
        var latitude: Double = 0
        var longitude: Double = 0
        var radiusKm: Double = 25
        var locality: String?
        var administrativeArea: String?
        var country: String?
        var isoCountryCode: String?
        var startedAt: Date = Date.now
        var endedAt: Date?
        var timeZoneIdentifier: String?
        var createdAt: Date = Date.now
        var modifiedAt: Date = Date.now

        init() {}
    }
}

// MARK: - V20 Schema (temporary-home provenance, kept trips, removals)

/// Adds three optional or defaulted attributes, all for temporary homes:
/// `Stay.temporaryHomeID` (which temporary home made the stay home, written
/// with its category), `Trip.keptByTemporaryHome` (the trip is kept whole by
/// this feature's mark, which the user can release) and
/// `TemporaryHome.removedAt` (a removal outlives every same-id twin).
/// No unique constraints, no arrays, no new relationships: a lightweight
/// migration. V18 and V19 alias `SchemaFrozenModelsV19`. MUST be
/// runtime-validated on device (install old → upgrade → fetch) and the
/// CloudKit schema deployed to Production before shipping.
enum TravelLogSchemaV20: VersionedSchema {
    static let versionIdentifier = Schema.Version(20, 0, 0)
    // Frozen since V21 (`Stay.temporaryHomeRevision`,
    // `TemporaryHome.coverageRevision`, `TemporaryHome.keptTripIDs`); see
    // `SchemaFrozenModelsV20`.
    typealias Stay = SchemaFrozenModelsV20.Stay
    typealias Trip = SchemaFrozenModelsV20.Trip
    typealias TripTitleVariant = SchemaFrozenModelsV20.TripTitleVariant
    typealias TemporaryHome = SchemaFrozenModelsV20.TemporaryHome

    static var models: [any PersistentModel.Type] {
        [
            LocationPing.self,
            Stay.self,                // gained optional temporaryHomeID in V20
            Trip.self,                // gained keptByTemporaryHome in V20
            Home.self,
            RoutinePlace.self,
            HexVisit.self,
            HiddenPhoto.self,
            PinnedPhoto.self,
            PhotoImportState.self,
            YearWrapped.self,
            PlannedTrip.self,
            HomeAreaOverride.self,
            TripTitleVariant.self,
            Visit.self,
            TemporaryHome.self,       // gained optional removedAt in V20
        ]
    }
}

// MARK: - Frozen V20 Stay/Trip/TripTitleVariant/TemporaryHome graph

/// The exact persisted shapes V20 wrote to disk, frozen before V21 adds
/// `Stay.temporaryHomeRevision`, `TemporaryHome.coverageRevision` and
/// `TemporaryHome.keptTripIDs`. `Stay`, `Trip` and `TripTitleVariant` freeze
/// together for the reason `SchemaFrozenModelsV17` gives: each closes an
/// inverse relationship of another. `TemporaryHome` has no relationship.
/// DO NOT EDIT: this freezes schema history.
enum SchemaFrozenModelsV20 {
    @Model final class Stay {
        var id: UUID = UUID()
        var startTime: Date = Date.now
        var endTime: Date = Date.now
        var durationMinutes: Int = 0
        var centroidLatitude: Double = 0
        var centroidLongitude: Double = 0
        var locality: String?
        var administrativeArea: String?
        var country: String?
        var isoCountryCode: String?
        var subLocality: String?
        var metroName: String?
        var islandName: String?
        var weatherData: Data?
        var avgTemperatureC: Double?
        var weatherConditionRaw: String?
        var precipitationMm: Double?
        var dayKey: Date?
        var transitFromPreviousRaw: String?
        var distanceFromPreviousKm: Double?
        var stepsWalked: Int?
        var isAirport: Bool = false
        var h3IndexRes6: String = ""
        var pingCount: Int = 0
        var distanceFromHomeKm: Double = 0
        var categoryRaw: String = ""
        var userOverridden: Bool = false
        var temporaryHomeID: UUID?
        var continuesPreviousTrip: Bool = false
        @Relationship var trip: Trip?
        var orderInTrip: Int?
        var pingIDsString: String = ""
        var sourceRaw: String = "liveSLC"
        var timeZoneIdentifier: String?

        init() {}
    }

    @Model final class Trip {
        var id: UUID = UUID()
        var startDate: Date = Date.now
        var endDate: Date?
        var isComplete: Bool = false
        var customName: String?
        var destinationSummary: String = ""
        var countryCodes: String = ""
        var aiGeneratedTitle: String?
        var titleSourceRevision: UUID?
        var aiGeneratedSummary: String?
        var summaryGeneratedAt: Date?
        var summaryGenerationVersion: Int?
        var summarySourceRaw: String?
        var classifiedByAI: Bool = false
        var userEdited: Bool = false
        var keptByTemporaryHome: Bool = false
        var sourceRaw: String = "liveSLC"
        @Relationship(deleteRule: .nullify, inverse: \Stay.trip)
        var stays: [Stay]?
        @Relationship(deleteRule: .cascade, inverse: \TripTitleVariant.trip)
        var localizedTitles: [TripTitleVariant]?

        init() {}
    }

    @Model final class TripTitleVariant {
        var id: UUID = UUID()
        var languageTag: String = ""
        var title: String = ""
        var sourceTitle: String = ""
        var sourceRevision: UUID?
        var generationVersion: Int = 1
        var updatedAt: Date = Date.now
        @Relationship var trip: Trip?

        init() {}
    }

    @Model final class TemporaryHome {
        var id: UUID = UUID()
        var label: String = ""
        var latitude: Double = 0
        var longitude: Double = 0
        var radiusKm: Double = 25
        var locality: String?
        var administrativeArea: String?
        var country: String?
        var isoCountryCode: String?
        var startedAt: Date = Date.now
        var endedAt: Date?
        var timeZoneIdentifier: String?
        var createdAt: Date = Date.now
        var modifiedAt: Date = Date.now
        var removedAt: Date?

        init() {}
    }
}

// MARK: - V21 Schema (temporary-home coverage revisions and kept trips)

/// Adds three defaulted or optional attributes, all for temporary homes:
/// `TemporaryHome.coverageRevision` (bumped on every coverage change, so a
/// unit can tell a stale copy of the declaration from the one a stay was
/// stamped by), `TemporaryHome.keptTripIDs` (trips the user kept whole, a
/// comma-separated UUID string because CloudKit takes no arrays) and
/// `Stay.temporaryHomeRevision` (the revision that stamped the stay, written
/// and cleared with `temporaryHomeID`). No unique constraints, no arrays, no
/// new relationships: a lightweight migration. V20 aliases
/// `SchemaFrozenModelsV20`. MUST be runtime-validated on device (install old
/// → upgrade → fetch) and the CloudKit schema deployed to Production before
/// shipping.
enum TravelLogSchemaV21: VersionedSchema {
    static let versionIdentifier = Schema.Version(21, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            LocationPing.self,
            Stay.self,                // gained optional temporaryHomeRevision in V21
            Trip.self,
            Home.self,
            RoutinePlace.self,
            HexVisit.self,
            HiddenPhoto.self,
            PinnedPhoto.self,
            PhotoImportState.self,
            YearWrapped.self,
            PlannedTrip.self,
            HomeAreaOverride.self,
            TripTitleVariant.self,
            Visit.self,
            TemporaryHome.self,       // gained coverageRevision and keptTripIDs in V21
        ]
    }
}

// MARK: - Current schema (single selection point)

/// Both app data containers and the widget’s read-only container consume this current-schema alias.
/// On a bump, move this alias together with the new schema and migration stage.
/// `MigrationChainTests.currentSchemaIsThePlanDestination` requires alias, final schema, and version to agree.
typealias CurrentTravelLogSchema = TravelLogSchemaV21

// MARK: - Migration Plan

enum TravelLogMigrationPlan: SchemaMigrationPlan {
    /// V3 onward is covered by `schemas` below. V1/V2 were dev-only iterations
    /// before the App Group store migration and are omitted. A V1/V2-shaped
    /// store is NOT rescued by the no-plan
    /// implicit-lightweight open path — `Stay.pingIDs` changed TYPE
    /// ([UUID] → String) on the way to V3, which lightweight migration
    /// cannot express, so such an open would FAIL rather than silently
    /// convert. Acceptable only because those shapes never left dev devices.
    ///
    /// NOTE: V3 is NOT structurally identical to V4 — `TravelLogSchemaV4` adds
    /// `Trip.customName` (compare `TravelLogSchemaV3.Trip` /
    /// `TravelLogSchemaV4.Trip`); the `.lightweight(V3→V4)` stage handles that
    /// additive change. V3 must remain included so V3-shaped stores migrate forward.
    ///
    /// The data-bearing containers in
    /// `AppDelegate.modelContainer` (CloudKit + local fallback) open the store
    /// WITH this plan (`migrationPlan: TravelLogMigrationPlan.self`), so the
    /// staged lightweight migrations run there. The widget's
    /// `SharedModelContainer` opens WITHOUT the plan (read-only; it must never
    /// mutate the store shape — the app migrates first). Defense in depth:
    /// every stage is additive and CloudKit-clean, so even a plan-less open
    /// would lightweight-migrate implicitly. Any schema change here MUST be
    /// runtime-validated on device before shipping, never compiler-only.
    ///
    /// V5, V6, V7, V8 are properly **frozen inline** (see each enum's note
    /// above) so their structural hashes are stable across future edits to
    /// the live `LocationPing` / `Stay` / `Trip` / `HiddenPhoto` /
    /// `PinnedPhoto` types. V8 freezes `Stay` / `Trip` alongside
    /// the V9 bump because V9 adds `isAirport` / `aiGeneratedTitle`.
    ///
    /// **Rule going forward**: when
    /// bumping from VN to VN+1, freeze in VN inline any model whose
    /// shape will change in VN+1 — BEFORE editing the live `Models/`
    /// file. Otherwise VN's hash drifts and the on-disk store written
    /// at VN becomes unrecognizable.
    ///
    /// Corollary: a model may stay LIVE across several
    /// consecutive versions only while NO bump in that range touches its
    /// shape — `Stay`/`Trip` are live V11→V14 on exactly that basis. The
    /// next change to either file must freeze the pre-change shape into
    /// EVERY version that references it live, not just the newest one.
    static var schemas: [any VersionedSchema.Type] {
        [TravelLogSchemaV3.self, TravelLogSchemaV4.self, TravelLogSchemaV5.self, TravelLogSchemaV6.self, TravelLogSchemaV7.self, TravelLogSchemaV8.self, TravelLogSchemaV9.self, TravelLogSchemaV10.self, TravelLogSchemaV11.self, TravelLogSchemaV12.self, TravelLogSchemaV13.self, TravelLogSchemaV14.self, TravelLogSchemaV15.self, TravelLogSchemaV16.self, TravelLogSchemaV17.self, TravelLogSchemaV18.self, TravelLogSchemaV19.self, TravelLogSchemaV20.self, TravelLogSchemaV21.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: TravelLogSchemaV3.self, toVersion: TravelLogSchemaV4.self),
            .lightweight(fromVersion: TravelLogSchemaV4.self, toVersion: TravelLogSchemaV5.self),
            .lightweight(fromVersion: TravelLogSchemaV5.self, toVersion: TravelLogSchemaV6.self),
            .lightweight(fromVersion: TravelLogSchemaV6.self, toVersion: TravelLogSchemaV7.self),
            .lightweight(fromVersion: TravelLogSchemaV7.self, toVersion: TravelLogSchemaV8.self),
            .lightweight(fromVersion: TravelLogSchemaV8.self, toVersion: TravelLogSchemaV9.self),
            .lightweight(fromVersion: TravelLogSchemaV9.self, toVersion: TravelLogSchemaV10.self),
            .lightweight(fromVersion: TravelLogSchemaV10.self, toVersion: TravelLogSchemaV11.self),
            .lightweight(fromVersion: TravelLogSchemaV11.self, toVersion: TravelLogSchemaV12.self),
            .lightweight(fromVersion: TravelLogSchemaV12.self, toVersion: TravelLogSchemaV13.self),
            .lightweight(fromVersion: TravelLogSchemaV13.self, toVersion: TravelLogSchemaV14.self),
            .lightweight(fromVersion: TravelLogSchemaV14.self, toVersion: TravelLogSchemaV15.self),
            .lightweight(fromVersion: TravelLogSchemaV15.self, toVersion: TravelLogSchemaV16.self),
            .lightweight(
                fromVersion: TravelLogSchemaV16.self,
                toVersion: TravelLogSchemaV17.self
            ),
            .lightweight(
                fromVersion: TravelLogSchemaV17.self,
                toVersion: TravelLogSchemaV18.self
            ),
            .lightweight(
                fromVersion: TravelLogSchemaV18.self,
                toVersion: TravelLogSchemaV19.self
            ),
            .lightweight(
                fromVersion: TravelLogSchemaV19.self,
                toVersion: TravelLogSchemaV20.self
            ),
            .lightweight(
                fromVersion: TravelLogSchemaV20.self,
                toVersion: TravelLogSchemaV21.self
            ),
        ]
    }
}
