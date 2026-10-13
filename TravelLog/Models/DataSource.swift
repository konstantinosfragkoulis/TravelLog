//
//  DataSource.swift
//  TravelLog
//


/// Provenance tag for `LocationPing`, `Stay`, and `Trip` records.
///
/// The value is persisted as `String` (via each model's `sourceRaw` property)
/// rather than as a SwiftData enum attribute so that:
///   1. Adding new cases in future schema versions is forward-compatible —
///      records written by older builds simply round-trip the unknown raw
///      value through their stored String column without crashing.
///   2. The lightweight V7→V8 migration can default existing rows to
///      `"liveSLC"` via a String default; SwiftData can't apply defaults to
///      raw-value-backed enum columns the same way.
///   3. CloudKit serialization is identical to any other scalar String — no
///      custom transformers needed.
///
/// Live ingest preserves its acquisition source on raw pings. Import-only
/// behaviour remains confined to import paths, while derived records normalize
/// raw live sources through `derivedRecordSource`.
nonisolated enum DataSource: String, Codable, CaseIterable, Sendable {
    /// Recorded by `LocationService` from a Significant Location Change event,
    /// or derived from such records. The default for all rows that existed
    /// before V8.
    case liveSLC = "liveSLC"

    /// Recorded by the foreground continuous-location stream. Raw pings keep
    /// this channel token; derived Stays and Trips roll up to `.liveSLC`.
    case foregroundStream = "foregroundStream"

    /// Created by `PhotoImportService` from a GPS-tagged photo's metadata.
    case photoImport = "photoImport"

    /// A Stay (or Trip) whose constituents span more than one provenance.
    /// Set by the pre-attach merge step when an imported ping is folded into
    /// a live Stay, and by `Trip.recomputeSummary()` when a Trip's stays span
    /// sources. The common case is `.liveSLC` + `.photoImport`, but external
    /// Timeline/GPX data can legitimately produce the same mixed state.
    case merged = "merged"

    /// Created by `TripDataImporter` from a JSON export file (restore /
    /// migration path). Synthetic pings are always tagged with this case;
    /// imported stays/trips keep their original provenance when the file
    /// carries one (v2 exports) and fall back to this. Deliberately
    /// distinct from `.photoImport` so the photo-import discard flow and
    /// `PhotoImportPingDeduplicator` never touch JSON-imported rows
    /// (cross-device double-imports are prevented by `ImportFence`
    /// instead — see the deduplicator's header for why healing them
    /// post-hoc is not convergence-safe).
    case jsonImport = "jsonImport"

    /// Created by the Google Timeline import (Settings → Data): pings
    /// synthesized from a Timeline export's visits/paths, then run through the
    /// normal pipeline. Distinct from `.photoImport` so the photo-import
    /// discard flow never touches these rows. `PhotoImportPingDeduplicator`
    /// DOES cover this source: its predicate spans photo/timeline/gpx so a
    /// same-file two-device import converges instead of duplicating every ping.
    case timelineImport = "timelineImport"

    /// Created by the GPX track import (Settings → Data). Same discard
    /// isolation and same deduplicator coverage as `.timelineImport`.
    case gpxImport = "gpxImport"

    /// True only for raw observations produced by a live acquisition channel.
    var isLiveObservation: Bool {
        switch self {
        case .liveSLC, .foregroundStream:
            return true
        default:
            return false
        }
    }

    /// Provenance used by records derived from raw pings.
    var derivedRecordSource: DataSource {
        self == .foregroundStream ? .liveSLC : self
    }

    /// Forward-compatible decode. Used by the computed `source` getters on
    /// models so that an unknown raw value (from a future schema) doesn't
    /// crash the app — it just reads back as `.liveSLC`, the safe default.
    static func decode(_ raw: String) -> DataSource {
        DataSource(rawValue: raw) ?? .liveSLC
    }
}
