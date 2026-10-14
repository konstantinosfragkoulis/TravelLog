//
//  DebugDiagnosticsViews.swift
//  TravelLog
//
//  DEBUG-build-only diagnostics screens: the phone itself answers "did
//  Foundation Models run?", "why did/didn't that group become a trip?" and
//  "what does the home area actually contain?" without a Mac attached.
//
//  Entire file is `#if DEBUG`: none of these views (or the Settings row
//  that reaches them) exist in Release builds.
//

#if DEBUG

import SwiftUI
import SwiftData
import WidgetKit

// MARK: - Root

struct DebugDiagnosticsView: View {

    @State private var fmSnapshot: DebugFMStatus.Snapshot?
    @State private var fmCapability: String = ""
    @State private var fmBecameAvailableAt: Date?

    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var exportError: String?

    @State private var schemaSeed: (id: UUID, createdAt: Date)?
    @State private var schemaSeedWorking = false

    @State private var repairReport: DebugStayReferenceRepair.Report?
    @State private var repairSummary: String?
    @State private var repairWorking = false
    @State private var confirmRepair = false

    var body: some View {
        List {
            fmSection

            Section {
                NavigationLink {
                    HomeAreaDiagnosticsView()
                } label: {
                    Label("Home Area", systemImage: "house.and.flag")
                }
                NavigationLink {
                    GateAuditView()
                } label: {
                    Label("Confidence Gate", systemImage: "chart.line.text.clipboard")
                }
                NavigationLink {
                    DebugVisitListView()
                } label: {
                    Label("Visit Monitoring", systemImage: "location.magnifyingglass")
                }
            } header: {
                Text("Core Algorithms")
            }

            schemaSeedSection

            repairSection

            exportSection
        }
        .navigationTitle("Debug Diagnostics")
        .onAppear { refreshFM() }
        .task { schemaSeed = await AppDelegate.tripClassifier.debugSchemaSeedRow() }
    }

    // MARK: CloudKit schema seed

    /// Shown only while a row from the retired schema-seed button remains, so it can be removed.
    @ViewBuilder
    private var schemaSeedSection: some View {
        if let schemaSeed {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Seed row present")
                    Text("Created \(schemaSeed.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    Task { await removeSchemaSeed() }
                } label: {
                    if schemaSeedWorking {
                        HStack { ProgressView(); Text("Working…").padding(.leading, 6) }
                    } else {
                        Label("Delete Schema Seed Row", systemImage: "trash")
                    }
                }
                .disabled(schemaSeedWorking)
            } header: {
                Text("CloudKit Schema")
            } footer: {
                Text("An inert 50 m exclude disc at 0°,0° left by the retired schema seed. The -initializeCloudKitSchema launch argument now sets up the CloudKit schema, so this row can go.")
            }
        }
    }

    private func removeSchemaSeed() async {
        guard let seed = schemaSeed else { return }
        schemaSeedWorking = true
        // Through `removeOverride`, not a raw delete — the tested removal
        // path (re-prime + shrink pass; both no-ops at 0°,0°).
        await PipelineGate.shared.run(touching: [.homeAreaOverride, .stay]) {
            _ = await AppDelegate.tripClassifier.removeOverride(id: seed.id)
        }
        StoreChangeTracker.shared.bump([.homeAreaOverride, .stay])
        await HomeAreaHealing.healIfNeeded()
        schemaSeed = await AppDelegate.tripClassifier.debugSchemaSeedRow()
        schemaSeedWorking = false
    }

    // MARK: Dangling ping-reference repair

    @ViewBuilder
    private var repairSection: some View {
        Section {
            Button {
                Task { await scanDanglingReferences() }
            } label: {
                if repairWorking && repairReport == nil {
                    HStack { ProgressView(); Text("Scanning…").padding(.leading, 6) }
                } else {
                    Label("Scan for Dangling Ping References", systemImage: "stethoscope")
                }
            }
            .disabled(repairWorking)

            if let report = repairReport {
                if let error = report.errorDescription {
                    Text("Scan failed: \(error)").font(.caption).foregroundStyle(.red)
                } else if report.staysWithDanglingReferences == 0 {
                    Text("No dangling references — all \(report.scannedStays) ping-backed stays are consistent.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(report.staysWithDanglingReferences) stays reference \(report.danglingReferences) missing pings")
                        Text("Repairable from surviving pings: \(report.repairedStays)"
                             + (report.skippedNoSurvivingPings > 0
                                ? " · no survivors (left untouched): \(report.skippedNoSurvivingPings)" : "")
                             + (report.skippedInconsistent > 0
                                ? " · inconsistent (left untouched): \(report.skippedInconsistent)" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if report.repairedStays > 0 {
                        Button(role: .destructive) {
                            confirmRepair = true
                        } label: {
                            if repairWorking {
                                HStack { ProgressView(); Text("Repairing…").padding(.leading, 6) }
                            } else {
                                Label("Repair \(report.repairedStays) Stays", systemImage: "bandage")
                            }
                        }
                        .disabled(repairWorking)
                    }
                }
            }
            if let repairSummary {
                Text(repairSummary).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Data Repair")
        } footer: {
            Text("Damage class: discards run on builds before 2026-07-25 left host stays referencing photo pings the discard deleted. Today's fail-closed discard refuses to run while such a reference shares a stay with a new photo import. Repair strips the unresolvable references and rebuilds each stay's time bounds, centroid, hex, airport flag, and provenance from its surviving pings (same math as the discard repair). ONLY run when iCloud sync is complete — a ping that simply hasn't synced yet would be treated as damage.")
        }
        .confirmationDialog(
            "Repair \(repairReport?.repairedStays ?? 0) stays?",
            isPresented: $confirmRepair,
            titleVisibility: .visible
        ) {
            Button("Strip Missing References and Rebuild", role: .destructive) {
                Task { await applyRepair() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Make sure iCloud sync has finished on this device first: a reference to a not-yet-synced ping will be treated as damage and removed.")
        }
    }

    private func scanDanglingReferences() async {
        repairWorking = true
        repairSummary = nil
        repairReport = await DebugStayReferenceRepair(
            modelContainer: AppDelegate.modelContainer
        ).scan()
        repairWorking = false
    }

    private func applyRepair() async {
        repairWorking = true
        // Same gate pattern as the schema seed: one store-mutating unit; the
        // gate's tracker bump refreshes the in-app pages, the explicit widget
        // reload covers the out-of-process tiles (dates/geometry changed).
        let report = await PipelineGate.shared.runReturning(touching: [.stay, .trip]) {
            await DebugStayReferenceRepair(
                modelContainer: AppDelegate.modelContainer
            ).repair()
        }
        StoreChangeTracker.shared.bump([.stay, .trip])
        WidgetCenter.shared.reloadAllTimelines()
        if let error = report.errorDescription {
            repairSummary = "Repair failed (nothing saved): \(error)"
        } else {
            repairSummary = "Repaired \(report.repairedStays) stays, updated \(report.updatedTrips) trips."
        }
        // Re-scan so the section shows the post-repair truth (any skipped
        // rows remain visible rather than silently disappearing).
        repairReport = await DebugStayReferenceRepair(
            modelContainer: AppDelegate.modelContainer
        ).scan()
        repairWorking = false
    }

    // MARK: Apple Intelligence

    @ViewBuilder
    private var fmSection: some View {
        Section {
            LabeledContent("Availability", value: fmCapability)
            if let at = fmBecameAvailableAt {
                LabeledContent("First became available",
                               value: at.formatted(date: .abbreviated, time: .shortened))
            }
            if let snapshot = fmSnapshot {
                if let feature = snapshot.lastSuccessFeature, let at = snapshot.lastSuccessAt {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last success: \(feature)")
                        if let detail = snapshot.lastSuccessDetail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(at.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No recorded success yet.")
                        .foregroundStyle(.secondary)
                }
                if let feature = snapshot.lastErrorFeature, let at = snapshot.lastErrorAt {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last error: \(feature)").foregroundStyle(.red)
                        if let message = snapshot.lastErrorMessage {
                            // Verbatim on purpose — the error case IS the
                            // diagnosis (unsupportedLanguageOrLocale et al.).
                            Text(message)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Text(at.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No recorded error.").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Apple Intelligence")
        } footer: {
            Text("Success/error records cover stay classification and trip titles. DEBUG builds only.")
        }
    }

    private func refreshFM() {
        fmCapability = FMCapability.current.rawValue
        fmBecameAvailableAt = FMCapability.becameAvailableAt()
        fmSnapshot = DebugFMStatus.snapshot()
    }

    // MARK: Export

    @ViewBuilder
    private var exportSection: some View {
        Section {
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Share Diagnostics JSON", systemImage: "square.and.arrow.up")
                }
            }
            Button {
                Task { await export() }
            } label: {
                if exporting {
                    HStack {
                        ProgressView()
                        Text("Preparing…").padding(.leading, 6)
                    }
                } else {
                    Label(exportURL == nil ? "Prepare Diagnostics Export"
                                           : "Refresh Diagnostics Export",
                          systemImage: "doc.badge.gearshape")
                }
            }
            .disabled(exporting)
            if let exportError {
                Text(exportError).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Export")
        } footer: {
            Text("One JSON bundle: home-area snapshot, gate passes, healing log, dissolve queue, Apple Intelligence status. Contains precise coordinates — share deliberately.")
        }
    }

    private func export() async {
        exporting = true
        exportError = nil
        defer { exporting = false }

        let bundle = DebugDiagnosticsBundle(
            generatedAt: .now,
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion") as? String,
            fmCapability: FMCapability.current.rawValue,
            fmBecameAvailableAt: FMCapability.becameAvailableAt(),
            fmStatus: DebugFMStatus.snapshot(),
            homeArea: await AppDelegate.tripClassifier.debugHomeAreaSnapshot(),
            storedHealingFingerprint: UserDefaults.standard.string(
                forKey: HomeAreaHealing.fingerprintKey),
            coverageSnapshot: Self.storedCoverage(),
            coverageStampedAt: UserDefaults.standard.object(
                forKey: HomeAreaHealing.coverageStampedAtKey) as? Date,
            dissolveQueue: DissolvedTripQueue.load(),
            healLog: DebugHealLog.load(),
            gatePasses: DebugGateAudit.load())

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(bundle)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(TripDataExporter.diagnosticsExportFileName)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            exportURL = url
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
        }
    }

    static func storedCoverage() -> [TripClassifier.CoverageDisc] {
        (UserDefaults.standard.data(forKey: HomeAreaHealing.coverageKey))
            .flatMap { try? JSONDecoder().decode(
                [TripClassifier.CoverageDisc].self, from: $0) } ?? []
    }
}

/// The everything-bundle the export button shares.
nonisolated struct DebugDiagnosticsBundle: Codable {
    let generatedAt: Date
    let appVersion: String?
    let build: String?
    let fmCapability: String
    let fmBecameAvailableAt: Date?
    let fmStatus: DebugFMStatus.Snapshot
    let homeArea: DebugHomeAreaSnapshot
    let storedHealingFingerprint: String?
    let coverageSnapshot: [TripClassifier.CoverageDisc]
    let coverageStampedAt: Date?
    let dissolveQueue: [DissolvedTripRecord]
    let healLog: [DebugHealLog.Entry]
    let gatePasses: [DebugGateAudit.Pass]
}

// MARK: - Visit monitoring

struct DebugVisitListView: View {

    @Query(sort: \Visit.arrivalDate, order: .reverse)
    private var visits: [Visit]

    var body: some View {
        List {
            if visits.isEmpty {
                Section {
                    Text("No visits recorded.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(visits) { visit in
                    Section {
                        LabeledContent("ID", value: visit.id.uuidString)
                        LabeledContent("Arrival", value: dateText(visit.arrivalDate))
                        LabeledContent(
                            "Departure",
                            value: visit.departureDate.map(dateText) ?? "Open")
                        LabeledContent("Received", value: dateText(visit.receivedAt))
                        LabeledContent(
                            "Coordinate",
                            value: String(
                                format: "%.7f, %.7f",
                                visit.latitude, visit.longitude))
                        LabeledContent(
                            "Accuracy",
                            value: String(format: "%.1f m", visit.horizontalAccuracy))
                        LabeledContent(
                            "Stay",
                            value: visit.stayID?.uuidString ?? "Unattached")
                        LabeledContent(
                            "Processed",
                            value: visit.isProcessed ? "Processed" : "Pending")
                    }
                    .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Visit Monitoring")
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(date: .numeric, time: .standard)
    }
}

// MARK: - Home area

struct HomeAreaDiagnosticsView: View {

    @State private var snapshot: DebugHomeAreaSnapshot?
    @State private var storedFingerprint: String?
    @State private var coverageCount = 0
    @State private var coverageStampedAt: Date?
    @State private var queue: [DissolvedTripRecord] = []
    @State private var healLog: [DebugHealLog.Entry] = []

    var body: some View {
        List {
            if let snapshot {
                ForEach(snapshot.homes) { home in
                    homeSection(home)
                }
                overridesSection(snapshot)
                healingSection(snapshot)
                queueSection
            } else {
                Section {
                    HStack {
                        ProgressView()
                        Text("Deriving the live home-area state…")
                            .padding(.leading, 6)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Home Area")
        .task { await load() }
    }

    private func load() async {
        snapshot = await AppDelegate.tripClassifier.debugHomeAreaSnapshot()
        storedFingerprint = UserDefaults.standard.string(
            forKey: HomeAreaHealing.fingerprintKey)
        coverageCount = DebugDiagnosticsView.storedCoverage().count
        coverageStampedAt = UserDefaults.standard.object(
            forKey: HomeAreaHealing.coverageStampedAtKey) as? Date
        healLog = DebugHealLog.load()
        queue = await Task.detached(priority: .utility) {
            DissolvedTripQueue.load()
        }.value
    }

    @ViewBuilder
    private func homeSection(_ home: DebugHomeAreaSnapshot.HomeInfo) -> some View {
        Section {
            LabeledContent("Coordinate", value: String(
                format: "%.5f, %.5f", home.latitude, home.longitude))
            LabeledContent("Era") {
                Text(eraText(start: home.startedAt, end: home.endedAt))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Seed: \(seedText(home))")
                if let area = home.areaKm2, let dStar = home.dStarKm {
                    Text(String(format: "%.0f km² · D* %.2f km", area, dStar))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if home.discs.isEmpty {
                Text("No learned discs — the orbit admits nothing for this home.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(home.discs.enumerated()), id: \.offset) { _, disc in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "Disc %.5f, %.5f · r %.2f km",
                                    disc.centerLatitude, disc.centerLongitude,
                                    disc.radiusKm))
                        Text("\(disc.returnTimes.count) qualifying returns")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(disc.validity.enumerated()), id: \.offset) { _, window in
                            Text("Valid \(window.start.formatted(date: .abbreviated, time: .omitted)) – \(window.end.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text(verbatim: home.label.isEmpty ? "Home" : home.label)
        }
    }

    private func seedText(_ home: DebugHomeAreaSnapshot.HomeInfo) -> String {
        switch home.seedKind {
        case "urbanCentre":
            let id = home.seedID.map { " #\($0)" } ?? ""
            return "urban centre \(home.seedName ?? "(unnamed)")\(id)"
        case "fallbackDisc":
            return "1 km fallback disc (no urban centre here)"
        default:
            return "unprimed (resolver never ran)"
        }
    }

    private func eraText(start: Date, end: Date?) -> String {
        let from = start.formatted(date: .abbreviated, time: .omitted)
        guard let end else { return "\(from) – current" }
        return "\(from) – \(end.formatted(date: .abbreviated, time: .omitted))"
    }

    @ViewBuilder
    private func overridesSection(_ snapshot: DebugHomeAreaSnapshot) -> some View {
        Section {
            if snapshot.overrides.isEmpty {
                Text("None — the user has taught no corrections.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.overrides) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%@ · %.5f, %.5f · r %.2f km",
                                    row.kind, row.centerLatitude,
                                    row.centerLongitude, row.radiusKm))
                        if let source = row.sourceTripName {
                            Text("From “\(source)”")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Created \(row.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Overrides (\(snapshot.overrides.count))")
        }
    }

    @ViewBuilder
    private func healingSection(_ snapshot: DebugHomeAreaSnapshot) -> some View {
        Section {
            LabeledContent("Fingerprint") {
                Text(storedFingerprint == snapshot.fingerprint
                     ? "In sync — no heal pending"
                     : (storedFingerprint == nil
                        ? "Never stamped — heal pending"
                        : "MOVED — heal pending"))
                .foregroundStyle(storedFingerprint == snapshot.fingerprint
                                 ? Color.secondary : Color.orange)
            }
            LabeledContent("Coverage snapshot") {
                VStack(alignment: .trailing) {
                    Text("\(coverageCount) disc(s)")
                    if let at = coverageStampedAt {
                        Text("stamped \(at.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("never stamped")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if healLog.isEmpty {
                Text("No heal or rescue has run past the fingerprint guard yet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(healLog.prefix(10)) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.kind == "heal"
                             ? "Heal: \(entry.tripsDissolved) dissolved, \(entry.recordsParked) parked"
                             : "Rescue: \(entry.tripsRestored) restored")
                        Text(entry.at.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Healing")
        }
    }

    @ViewBuilder
    private var queueSection: some View {
        Section {
            if queue.isEmpty {
                Text("Empty.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(queue) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.displayName(
                            languageTag: AppLanguagePreference.currentTag()))
                        Text("\(record.stays.count) stay(s) · dissolved \(record.dissolvedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Dissolve Queue (\(queue.count))")
        } footer: {
            Text("Trips healing removed, held for review or auto-rescue. The user-facing list is Settings › Homes › Near-Home Activity › Removed Trips.")
        }
    }
}

// MARK: - Confidence gate

struct GateAuditView: View {

    @State private var passes: [DebugGateAudit.Pass] = []
    @State private var hasLoaded = false

    var body: some View {
        List {
            if passes.isEmpty && hasLoaded {
                Section {
                    Text("No assembly pass with candidate groups has run on this build yet. Open the app after new stays arrive (or run Reclassify All) and check back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(passes.enumerated()), id: \.offset) { _, pass in
                Section {
                    ForEach(pass.groups) { group in
                        groupRow(group, threshold: pass.threshold)
                    }
                } header: {
                    Text("\(pass.at.formatted(date: .abbreviated, time: .shortened)) · θ = \(pass.threshold.formatted())")
                }
            }
        }
        .navigationTitle("Confidence Gate")
        .task {
            passes = await Task.detached(priority: .utility) {
                DebugGateAudit.load()
            }.value
            hasLoaded = true
        }
    }

    @ViewBuilder
    private func groupRow(_ group: DebugGateAudit.GroupRecord, threshold: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(group.placeName ?? "Unknown place")
                Spacer()
                if let score = group.score {
                    Text(String(format: "%.2f", score))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(group.cleared ? Color.green : Color.orange)
                } else {
                    Text(group.cleared ? "exempt" : "—")
                        .foregroundStyle(.secondary)
                }
            }
            Text("\(group.stayCount) stay(s) · \(group.start.formatted(date: .abbreviated, time: .shortened)) – \(group.end.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            if let exemption = group.exemption {
                Text("Bypassed scoring: \(exemption)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(group.cleared ? "CLEARED → trip" : "SUPPRESSED → stays tripless")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(group.cleared ? Color.green : Color.orange)
        }
    }
}

#endif
