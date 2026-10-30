//
//  StatusDashboardView.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//


import SwiftUI
import SwiftData

/// Dashboard showing the current state of background location tracking:
///
/// - Tracking status indicator (green/yellow/red)
/// - Any issues preventing full operation
/// - Key statistics (total pings, hexes, last ping time)
/// - A list of recent pings for debugging/verification
struct StatusDashboardView: View {

    @State private var trackingStatus = TrackingStatus()
    @Environment(\.modelContext) private var modelContext

    /// Only the most recent 50 pings - loaded via manual fetch to avoid
    /// pulling thousands of pings into memory via @Query.
    @State private var recentPings: [LocationPing] = []

    /// Render-time deleted-row filter: a dedup/remote delete
    /// while this screen stays mounted leaves deleted models in the cached
    /// array, and any property read on one traps (`isDeleted` is the one
    /// safe read — same contract as TripsListView's `filteringDeleted`).
    private var livePings: [LocationPing] {
        recentPings.filter { !$0.isDeleted }
    }

    @State private var totalPings = 0
    @State private var totalHexes = 0
    @State private var totalStays = 0

    var body: some View {
        List {
            statusSection
            statsSection
            recentPingsSection
        }
        .navigationTitle("Travel Log")
        .task {
            await runClusteringAndRefreshStats()
        }
        .refreshable {
            // Retry first so the title stages refill what it invalidates
            // and the row fetch sees the fresh geocodes.
            await retryGeocoding()
            await runClusteringAndRefreshStats()
        }
    }

    // MARK: - Status Section

    @ViewBuilder
    private var statusSection: some View {
        Section {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                Text(statusText)
                    .font(.headline)
                Spacer()
                if trackingStatus.isMonitoring {
                    StatusPill(label: Text("Active"))
                }
            }

            if !trackingStatus.issues.isEmpty {
                ForEach(trackingStatus.issues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.bold())
                            .foregroundStyle(AppTheme.attention)
                        Text(issue.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if issue.canRequestPermission {
                            Button("Continue") {
                                LocationService.shared.requestWhenInUseAuthorization()
                            }
                            .font(.caption.bold())
                        } else if issue.canOpenSettings {
                            Button("Open Settings") {
                                openAppSettings()
                            }
                            .font(.caption.bold())
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("Tracking Status")
                .settingsHeader()
        }
    }

    private var statusColor: Color {
        if trackingStatus.isFullyOperational { return .green }
        if trackingStatus.hasAnyPermission { return AppTheme.attention }
        return AppTheme.failure
    }

    private var statusText: String {
        if trackingStatus.isFullyOperational {
            return String(localized: "status-dashboard.tracking.fully-operational", defaultValue: "Fully Operational", comment: "Status Dashboard tracking state when all tracking requirements are met.")
        }
        if trackingStatus.hasAnyPermission {
            return String(localized: "status-dashboard.tracking.degraded", defaultValue: "Degraded", comment: "Status Dashboard tracking state when tracking is only partly operational.")
        }
        return String(localized: "status-dashboard.tracking.not-tracking", defaultValue: "Not Tracking", comment: "Status Dashboard tracking state when location tracking is unavailable.")
    }

    // MARK: - Stats Section

    @ViewBuilder
    private var statsSection: some View {
        Section {
            StatRow(label: String(localized: "status-dashboard.stat.total-pings", defaultValue: "Total Pings", comment: "Status Dashboard statistic label for total location pings."), value: "\(totalPings)")
            StatRow(label: String(localized: "status-dashboard.stat.stays-clustered", defaultValue: "Stays Clustered", comment: "Status Dashboard statistic label for clustered stays."), value: "\(totalStays)")
            StatRow(label: String(localized: "status-dashboard.stat.hexes-explored", defaultValue: "Hexes Explored", comment: "Status Dashboard statistic label for explored map hexes."), value: "\(totalHexes)")

            if let lastTime = livePings.first?.timestamp {
                StatRow(label: String(localized: "status-dashboard.stat.last-ping", defaultValue: "Last Ping", comment: "Status Dashboard statistic label for the most recent location ping."), value: lastTime.formatted(.relative(presentation: .named)))
            } else {
                StatRow(
                    label: String(localized: "status-dashboard.stat.last-ping", defaultValue: "Last Ping", comment: "Status Dashboard statistic label for the most recent location ping."),
                    value: String(localized: "status-dashboard.stat.last-ping.none", defaultValue: "None yet", comment: "Status Dashboard value when no location ping has been recorded yet.")
                )
            }
        } header: {
            Text("Statistics")
                .settingsHeader()
        }
    }

    // MARK: - Recent Pings Section

    @ViewBuilder
    private var recentPingsSection: some View {
        Section {
            if livePings.isEmpty {
                Text("No pings recorded yet. Move around and pings will appear here as your phone detects cell tower changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(livePings.prefix(50)) { ping in
                    PingRow(ping: ping)
                }
            }
        } header: {
            Text("Recent Pings")
                .settingsHeader()
        } footer: {
            if !livePings.isEmpty {
                let count = min(livePings.count, 50)
                if count == 1 {
                    Text(String(
                        localized: "status-dashboard.recent-pings.footer.one",
                        defaultValue: "Showing the \(count, format: .number.grouping(.never)) most recent pings. Pull to refresh and retry failed geocoding.",
                        comment: "Status Dashboard footer when one recent location ping is shown."
                    ))
                } else {
                    Text(String(
                        localized: "status-dashboard.recent-pings.footer.other",
                        defaultValue: "Showing the \(count, format: .number.grouping(.never)) most recent pings. Pull to refresh and retry failed geocoding.",
                        comment: "Status Dashboard footer when multiple recent location pings are shown."
                    ))
                }
            }
        }
    }

    // MARK: - Actions

    private func runClusteringAndRefreshStats() async {
        // Show the stored counts right away; the gated pipeline below can
        // wait behind other units.
        await refreshStats()

        // Run the full pipeline: cluster → classify → assemble trips.
        // Serialized via PipelineGate to avoid concurrent cross-context writes
        // with other pipeline triggers.
        let clustering = await PipelineGate.shared.runReturning(touching: [.stay, .trip, .locationPing, .visit]) {
            await AppDelegate.stayClusterer.clusterUnprocessedPingsReportingChanges()
        }
        await AppDelegate.stayClusterer.enrichPendingLocalities(clustering.pendingLocalities)
        _ = await AppDelegate.tripClassifier.classifyAndAssembleTripsWithGates()
        _ = await AppDelegate.tripClassifier.generateTitlesStage(
            maxTripsPerCall: 5)
        _ = await AppDelegate.tripTitleLocalizationService
            .generateLocalizedTitlesStage(maxTripsPerCall: 5)

        await refreshStats()
    }

    private func refreshStats() async {
        let recorder = AppDelegate.pingRecorder
        totalPings = await recorder.totalPingCount()
        totalHexes = await recorder.totalHexCount()
        totalStays = await AppDelegate.stayClusterer.totalStayCount()

        // Fetch only the 50 most recent pings (not all thousands)
        var pingDescriptor = FetchDescriptor<LocationPing>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        pingDescriptor.fetchLimit = 50
        recentPings = (try? modelContext.fetch(pingDescriptor)) ?? []
    }

    private func retryGeocoding() async {
        // Serialize with the pipeline so this manual retry can't race a
        // concurrent cluster/classify pass or another view's gated pipeline
        // on the shared store. Mirrors the gated retry sites in RootView /
        // Settings.
        await PipelineGate.shared.run(touching: [.stay, .locationPing, .trip]) {
            await AppDelegate.pingRecorder.retryFailedGeocoding()
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - StatRow

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - PingRow

private struct PingRow: View {
    let ping: LocationPing

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let locality = ping.locality {
                    Text(locality)
                        .font(.subheadline.bold())
                    if let country = localizedCountryName(
                        iso: ping.isoCountryCode,
                        fallback: ping.country
                    ) {
                        Text("· \(country)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Awaiting geocoding…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .italic()
                }
                Spacer()
            }

            HStack(spacing: 12) {
                Text(ping.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("hex: \(ping.h3IndexRes6.prefix(8))…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
