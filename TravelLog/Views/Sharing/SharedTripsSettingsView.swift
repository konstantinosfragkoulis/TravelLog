//
//  SharedTripsSettingsView.swift
//  TravelLog
//
//  Settings › Import & Export: open a Travel Log trip file, and the trips
//  others shared that this device added, each with Remove Shared Data.
//

import SwiftUI
import UniformTypeIdentifiers

/// The section Import & Export shows.
struct SharedTripsSettingsSection: View {
    @State private var showPicker = false
    @State private var records: [SharedTripLedger.Record] = []

    var body: some View {
        Section {
            Button {
                showPicker = true
            } label: {
                Text(String(localized: "settings.shared-trips.open", defaultValue: "Open a Shared Trip",
                            comment: "Settings button that picks a Travel Log trip file someone shared."))
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.travelLogTrip]) { result in
                if case .success(let url) = result { SharedTripInbox.shared.open(url) }
            }
            if !records.isEmpty {
                NavigationLink {
                    SharedTripsListView()
                } label: {
                    LabeledContent(
                        String(localized: "settings.shared-trips.title", defaultValue: "Shared Trips",
                               comment: "Settings row and screen listing the shared trips this device added."),
                        value: records.count.formatted(.number.grouping(.never)))
                }
            }
        } header: {
            Text(String(localized: "settings.shared-trips.header", defaultValue: "Shared Trips",
                        comment: "Header of the Settings section for trips other Travel Log users shared."))
                .settingsHeader()
        } footer: {
            Text(String(localized: "settings.shared-trips.footer",
                        defaultValue: "Add a trip someone shared with you as a Travel Log file. Your own locations always come first, and you can remove what a shared trip added at any time.",
                        comment: "Footer of the Settings shared trips section."))
        }
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: SharedTripLedger.didChangeNotification)) { _ in
            reload()
        }
    }

    private func reload() {
        records = (try? SharedTripLedger.load()) ?? []
    }
}

struct SharedTripsListView: View {
    @State private var records: [SharedTripLedger.Record] = []
    @State private var pendingRemoval: SharedTripLedger.Record?
    @State private var removing: UUID?
    @State private var failed = false

    var body: some View {
        List {
            Section {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(TripTitleStore.normalized(record.title) ?? String(
                            localized: "trip.display-name.fallback", defaultValue: "Trip",
                            comment: "Fallback display name for a trip with no usable title or destination."))
                            .font(.body)
                        Text(subtitle(record))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            pendingRemoval = record
                        } label: {
                            if removing == record.shareID {
                                ProgressView()
                            } else {
                                Text(String(localized: "settings.shared-trips.remove", defaultValue: "Remove Shared Data",
                                            comment: "Deletes exactly what one shared trip added to the user's history."))
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(removing != nil)
                        .padding(.top, 2)
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text(String(localized: "settings.shared-trips.list.footer",
                            defaultValue: "This list is kept on this device only.",
                            comment: "Footer of the shared trips list: the record is device-local."))
            }
        }
        .navigationTitle(String(localized: "settings.shared-trips.title", defaultValue: "Shared Trips",
                                comment: "Settings row and screen listing the shared trips this device added."))
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: SharedTripLedger.didChangeNotification)) { _ in
            reload()
        }
        .confirmationDialog(
            String(localized: "settings.shared-trips.remove.confirm.title", defaultValue: "Remove Shared Data?",
                   comment: "Confirmation title before removing what a shared trip added."),
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { record in
            Button(String(localized: "settings.shared-trips.remove", defaultValue: "Remove Shared Data",
                          comment: "Deletes exactly what one shared trip added to the user's history."),
                   role: .destructive) {
                Task { await remove(record) }
            }
        } message: { _ in
            Text(String(localized: "settings.shared-trips.remove.confirm.message",
                        defaultValue: "The places and times this shared trip added are deleted and your trips are rebuilt. Your own locations are not touched.",
                        comment: "Confirmation message before removing what a shared trip added."))
        }
        .alert(String(localized: "common.save-error.try-again", defaultValue: "Couldn't save. Try again",
                      comment: "Shared alert title after a user-authoritative save fails."),
               isPresented: $failed) {
            Button(String(localized: "common.ok", defaultValue: "OK", comment: "Generic OK button."), role: .cancel) {}
        }
    }

    private func subtitle(_ record: SharedTripLedger.Record) -> String {
        let date = record.lastImportedAt.formatted(date: .abbreviated, time: .omitted)
        if let sender = TripTitleStore.normalized(record.senderName) {
            return String(localized: "settings.shared-trips.row.sender",
                          defaultValue: "From \(sender), added \(date)",
                          comment: "Shared trip row subtitle: who sent it and when it was added.")
        }
        return String(localized: "settings.shared-trips.row.date", defaultValue: "Added \(date)",
                      comment: "Shared trip row subtitle when the sender gave no name: when it was added.")
    }

    private func reload() {
        records = (try? SharedTripLedger.load()) ?? []
    }

    private func remove(_ record: SharedTripLedger.Record) async {
        removing = record.shareID
        defer { removing = nil }
        do {
            try await SharedTripImporter.removeSharedData(shareID: record.shareID)
        } catch {
            failed = true
        }
        reload()
    }
}
