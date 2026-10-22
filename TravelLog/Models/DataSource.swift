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

    /// The provenance of rows restored by `TripDataImporter` from a backup
    /// written before v15, which carried none of its own. A v15 backup
    /// restores every row with its stored provenance, so this case only
    /// survives on rows already in a store. Deliberately
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

    /// Evidence another Travel Log user shared in a trip file (`TripShareFile`):
    /// their pings, inserted under their own UUIDs only where this device holds
    /// no evidence of its own, then clustered and classified by the normal
    /// pipeline. Never a qualifying home boundary. Outside the photo-import
    /// discard and `PhotoImportPingDeduplicator`; "Remove Shared Data" deletes
    /// exactly the rows its device-local `SharedTripLedger` recorded. An older
    /// build decodes the raw value as `.liveSLC` (see `decode`).
    case sharedImport = "sharedImport"

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

    /// Whether a flight inference must allow for photo-style timestamp
    /// uncertainty. Keep this separate from the provenance displayed to the
    /// user: a mixed or shared stay is not necessarily a photo stay.
    ///
    /// A merged row cannot recover which constituent supplied an endpoint's
    /// time. Legacy backups and future source tokens likewise must not gain
    /// live-observation confidence through `decode`'s compatibility fallback.
    static func needsPhotoTimeCaution(rawValue: String) -> Bool {
        guard let source = Self(rawValue: rawValue) else { return true }
        switch source {
        case .liveSLC, .foregroundStream, .timelineImport, .gpxImport:
            return false
        case .photoImport, .merged, .jsonImport, .sharedImport:
            return true
        }
    }

    /// Sources that actually contributed to a stay, including retained raw
    /// pings. Older import attachment code could leave a Timeline/GPX tag on
    /// a stay after adding photos. Keep the stored tag and every retained raw
    /// value: neither an unknown future token nor a same-UUID ping twin may
    /// disappear behind the model accessor's compatibility fallback.
    ///
    /// This is evidence for inference and presentation, not a replacement
    /// persisted source. In particular it grants no deletion or home-boundary
    /// authority to imported evidence.
    static func sourceRawsForEvidence(storedRaw: String, retainedRaws: [String]) -> [String] {
        Set([storedRaw] + retainedRaws).sorted()
    }

    /// A stored track tag alone cannot establish pure track provenance:
    /// historical photo absorption did not always change that tag. A
    /// successful member read must cover every referenced ping before the
    /// imported row can take the non-photo timing lane. Missing members can
    /// still be arriving through sync; they are uncertainty, never absence.
    static func needsPhotoTimeCaution(
        storedRaw: String, retainedRaws: [String], memberEvidenceComplete: Bool
    ) -> Bool {
        if !memberEvidenceComplete,
           storedRaw == Self.timelineImport.rawValue || storedRaw == Self.gpxImport.rawValue {
            return true
        }
        return sourceRawsForEvidence(storedRaw: storedRaw, retainedRaws: retainedRaws)
            .contains { needsPhotoTimeCaution(rawValue: $0) }
    }

    /// Source of a derived row without decoding unrecognized persisted
    /// values into live observations. The two measured live channels share
    /// one derived lane; every other raw value survives verbatim.
    static func derivedRecordSourceRaw(_ raw: String) -> String {
        Self(rawValue: raw)?.derivedRecordSource.rawValue ?? raw
    }

    /// Provenance transition when a retained imported ping joins an existing
    /// stay. Shared-host tags retain their ownership/home-boundary meaning;
    /// unknown host tags also survive, with the extra evidence available to
    /// the conservative flight projection instead of being relabeled live.
    static func sourceRawAfterImportAttachment(hostRaw: String, incomingRaw: String) -> String {
        guard let host = Self(rawValue: hostRaw) else { return hostRaw }
        guard host != .sharedImport, host != .merged else { return hostRaw }
        let hostLane = derivedRecordSourceRaw(hostRaw)
        return hostLane == derivedRecordSourceRaw(incomingRaw) ? hostLane : Self.merged.rawValue
    }

    /// Forward-compatible decode. Used by the computed `source` getters on
    /// models so that an unknown raw value (from a future schema) doesn't
    /// crash the app. This compatibility fallback does not establish live
    /// acquisition provenance; evidence checks must inspect the raw value.
    static func decode(_ raw: String) -> DataSource {
        DataSource(rawValue: raw) ?? .liveSLC
    }
}
