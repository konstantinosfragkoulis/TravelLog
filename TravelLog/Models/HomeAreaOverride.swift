//
//  HomeAreaOverride.swift
//  TravelLog
//

import Foundation
import SwiftData

/// A user decision about home-area membership; the only persistence the
/// expansion needs for corrections and convergence. Derived orbit
/// discs are deliberately NOT persisted (they recompute from the stay
/// history; a stored twin goes stale against the geocoder build, the home
/// row, and the evidence — the `D`/`D*` lesson). What CANNOT be recomputed
/// is what the user decided, so exactly that is stored:
///
/// - `.include` — "this wasn't a trip": a disc the user taught into the home
///   area (trip demotion). Timeless within its home's era.
/// - `.exclude` — a learned place the user revoked from the Settings list:
///   suppresses orbit coverage at that spot AND bars the cluster from
///   re-qualifying at derivation time. A hole in DISC space only — the seed
///   (downtown) can never be excluded.
///
/// ## CloudKit considerations
///
/// No `@Attribute(.unique)`, no arrays, no relationships; every field
/// defaulted or optional → V14→V15 stays lightweight. `homeID` is a plain
/// `UUID?` (the `HiddenPhoto.tripID` pattern) scoping the override to a home
/// row's era; an override dies with its home (orbit state never
/// outlives the home it was learned for). Cross-device duplicate rows (the
/// same correction tapped on two devices) converge via
/// `HomeAreaOverrideDeduplicator`, keyed on `(kindRaw, homeID, centre
/// rounded to ~11 m)`.
///
/// Added in V15.
@Model
final class HomeAreaOverride {

    var id: UUID = UUID()

    /// `"include"` or `"exclude"` — String-stored like `DataSource` /
    /// `StayCategory` (forward-compatible, CloudKit-safe).
    var kindRaw: String = HomeAreaOverride.Kind.include.rawValue

    var centerLatitude: Double = 0
    var centerLongitude: Double = 0
    var radiusKm: Double = 1

    /// The home era this override belongs to. Optional per CloudKit; a nil
    /// value applies to every home ring and era (`withShapes`). Writers stamp
    /// it whenever a successful read finds a home, and never write nil for a
    /// failed read.
    var homeID: UUID?

    /// Trip-demotion provenance, display only: the name of the trip the user demoted
    /// ("added when you removed 'Aarau Sunday'"). Never consulted by logic.
    var sourceTripName: String?

    var createdAt: Date = Date.now

    init(kind: Kind, centerLatitude: Double, centerLongitude: Double,
         radiusKm: Double, homeID: UUID?, sourceTripName: String? = nil) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.radiusKm = radiusKm
        self.homeID = homeID
        self.sourceTripName = sourceTripName
        self.createdAt = .now
    }

    nonisolated enum Kind: String, Codable, Sendable {
        case include
        case exclude
    }

    /// Type-safe accessor; an unknown raw (from a future version) reads as
    /// nil so this build ignores rather than misapplies it.
    var kind: Kind? { Kind(rawValue: kindRaw) }
}
