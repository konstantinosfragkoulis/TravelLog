//
//  StaysListView.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 26/3/26.
//


import SwiftUI
import SwiftData

/// Displays all clustered stays in reverse chronological order.
///
/// A diagnostics screen (Settings ▸ Diagnostics). Each stay shows its
/// locality, duration, distance from home, and classification status.
///
/// Clustering is triggered automatically when this view appears.
struct StaysListView: View {

    // Bounded, manually loaded: `@Query` has no fetch-limit parameter, and an
    // unbounded list would materialise EVERY `Stay` row on the main actor
    // (thousands on a photo-imported library). The count is queried
    // separately so the summary stays truthful and the footer can say
    // plainly when the list is truncated.
    @Environment(\.modelContext) private var modelContext

    /// Newest-first window actually rendered.
    private static let displayLimit = 500

    @State private var stays: [Stay] = []
    /// The loaded stays a temporary home owns. Physical rows, so UUID twins
    /// are told apart.
    @State private var temporaryHomeStays: Set<PersistentIdentifier> = []
    @State private var totalStayCount = 0
    @State private var isClustering = false

    var body: some View {
        List {
            summarySection
            staysSection
        }
        .navigationTitle("Stays")
        .task {
            // Show what's already stored immediately; the clustering pass
            // below reloads when it finishes. Without this the list would be
            // empty until clustering completed, which `@Query` never was.
            loadStays()
            await runClustering()
        }
        .refreshable {
            await runClustering()
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private var summarySection: some View {
        Section {
            if isClustering {
                HStack {
                    ProgressView()
                        .padding(.trailing, 8)
                    Text("Clustering pings into stays…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text("Total Stays")
                    Spacer()
                    Text("\(totalStayCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Stays List

    @ViewBuilder
    private var staysSection: some View {
        if stays.isEmpty && !isClustering {
            Section {
                Text("No stays yet. As pings accumulate from your movements, they'll be grouped into stays here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                ForEach(stays, id: \.persistentModelID) { stay in
                    StayRow(
                        stay: stay,
                        isTemporaryHome: temporaryHomeStays.contains(stay.persistentModelID))
                }
            } header: {
                Text("All Stays")
            } footer: {
                if totalStayCount > stays.count {
                    Text(totalStayCount == 1
                         ? String(localized: "stays-list.truncated.one", defaultValue: "Showing the \(stays.count, format: .number.grouping(.never)) most recent of \(totalStayCount, format: .number.grouping(.never)) stay. Pull to refresh and cluster new pings. Stays are grouped from consecutive location pings within 3km and 4 hours of each other.", comment: "All Stays footer for a truncated list whose total is one stay.")
                         : String(localized: "stays-list.truncated.other", defaultValue: "Showing the \(stays.count, format: .number.grouping(.never)) most recent of \(totalStayCount, format: .number.grouping(.never)) stays. Pull to refresh and cluster new pings. Stays are grouped from consecutive location pings within 3km and 4 hours of each other.", comment: "All Stays footer for a truncated list whose total is multiple stays."))
                } else {
                    Text("Pull to refresh and cluster new pings. Stays are grouped from consecutive location pings within 3km and 4 hours of each other.")
                }
            }
        }
    }

    // MARK: - Actions

    /// Load the bounded window plus the true total. Called on appear and
    /// after clustering — the manual fetch replaces `@Query`'s live updates,
    /// and those are the only two moments this diagnostics list changes while
    /// on screen.
    private func loadStays() {
        totalStayCount = (try? modelContext.fetchCount(FetchDescriptor<Stay>())) ?? 0
        var descriptor = FetchDescriptor<Stay>(sortBy: [SortDescriptor(\.startTime, order: .reverse)])
        descriptor.fetchLimit = Self.displayLimit
        stays = (try? modelContext.fetch(descriptor)) ?? []

        // Badge owners, resolved once per load. With no temporary home
        // nothing more is computed.
        let anchors = (try? HomeAnchors.temporaryHomes(in: modelContext)) ?? []
        temporaryHomeStays = anchors.isEmpty ? [] : Set(
            stays.filter { Self.temporaryHomeOwner(of: $0, anchors: anchors) != nil }
                .map(\.persistentModelID))
    }

    /// The temporary home that recorded `stay` (`HomeAnchors.recordedOwner`,
    /// never the nearest centre), for the badge. Nil for a stay the real
    /// Home made home, a stay whose owner is removed or not synced (no live
    /// anchor among `anchors`), and any stay that is not home-category.
    static func temporaryHomeOwner(of stay: Stay, anchors: [HomeAnchor]) -> HomeAnchor? {
        guard stay.category == .home, let id = stay.temporaryHomeID else { return nil }
        return anchors.first { $0.isTemporary && $0.id == id }
    }

    private func runClustering() async {
        isClustering = true

        // Serialized via PipelineGate to avoid concurrent cross-context writes
        // with other pipeline triggers.
        let clustering = await PipelineGate.shared.runReturning(touching: [.stay, .trip, .locationPing, .visit]) {
            // Layer 2: Cluster pings into stays
            await AppDelegate.stayClusterer.clusterUnprocessedPingsReportingChanges()
        }
        await AppDelegate.stayClusterer.enrichPendingLocalities(clustering.pendingLocalities)
        _ = await AppDelegate.tripClassifier.classifyAndAssembleTripsWithGates()
        _ = await AppDelegate.tripClassifier.generateTitlesStage(
            maxTripsPerCall: 5)
        _ = await AppDelegate.tripTitleLocalizationService
            .generateLocalizedTitlesStage(maxTripsPerCall: 5)

        isClustering = false
        loadStays()
    }
}

// MARK: - Stay Row

private struct StayRow: View {
    let stay: Stay
    /// A home stay at a temporary home; resolved by the list, not per render.
    let isTemporaryHome: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(stay.locality ?? String(localized: "stays-list.place.unknown", defaultValue: "Unknown", comment: "Fallback locality name in the All Stays list."))
                    .font(.subheadline.bold())

                if let country = localizedCountryName(
                    iso: stay.isoCountryCode,
                    fallback: stay.country
                ) {
                    Text("· \(country)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                categoryBadge
            }

            HStack(spacing: 16) {
                Label(stay.formattedDuration, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label(formattedDistance, systemImage: "location")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label(stay.pingCount == 1
                      ? String(localized: "stays-list.ping-count.one", defaultValue: "\(stay.pingCount, format: .number.grouping(.never)) ping", comment: "All Stays row count for one location ping.")
                      : String(localized: "stays-list.ping-count.other", defaultValue: "\(stay.pingCount, format: .number.grouping(.never)) pings", comment: "All Stays row count for multiple location pings."), systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Text(formattedTimeRange)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Formatting

    @ViewBuilder
    private var categoryBadge: some View {
        let category = stay.category

        if category != .unclassified {
            Text(isTemporaryHome
                 ? String(localized: "stay.badge.temporary-home", defaultValue: "Temporary Home", comment: "All Stays badge for a home stay at the user's temporary home.")
                 : category.displayName)
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(categoryColor, in: .capsule)
        } else {
            Text("Unclassified")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.gray.opacity(0.2), in: .capsule)
        }
    }

    private var categoryColor: Color {
        switch stay.category {
        case .home: isTemporaryHome ? Color.teal : Color.blue
        case .routine: .purple
        case .destination: .green
        case .transit: .orange
        case .unclassified: .gray
        }
    }

    private var formattedDistance: String {
        let km = stay.distanceFromHomeKm
        if km == Double.greatestFiniteMagnitude || km.isNaN {
            return "—"
        }
        return UnitsFormatter.formatDistance(kilometers: km)
    }

    private var formattedTimeRange: String {
        (stay.startTime..<stay.endTime).formatted(
            Date.IntervalFormatStyle(date: .abbreviated, time: .shortened)
        )
    }
}
