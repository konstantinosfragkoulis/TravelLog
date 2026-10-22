//
//  TripShareSheet.swift
//  TravelLog
//
//  One export flow for one or several trips: the overview image as it will
//  be sent at the top, then any of that image, the Travel Log file and the
//  GPX route (five trips or more choose one summary image or one per trip),
//  and one share sheet carries every chosen item. Share reads the trips and
//  home areas again once the items are written: if anything changed since
//  the preview, the items are thrown away, the preview is rebuilt and the
//  user is asked to look again. Opened from a trip's context menu and a
//  trip's page.
//

import SwiftUI
import UIKit

/// The trips a share sheet is for.
struct TripShareRequest: Identifiable {
    let id = UUID()
    let tripIDs: [UUID]
}

struct TripShareSheet: View {
    let request: TripShareRequest

    @Environment(\.dismiss) private var dismiss
    @AppStorage("tripShareIncludeImage_v1") private var includeImage = true
    @AppStorage("tripShareIncludeFile_v1") private var includeFile = true
    @AppStorage("tripShareIncludeGPX_v1") private var includeGPX = false
    /// Device-local: the name the recipient sees, if the user gives one.
    @AppStorage("tripShareSenderName_v1") private var senderName = ""

    @State private var isPreparing = false
    @State private var staged: TripShareStaging.Staged?
    @State private var failure: TripShareStaging.StagingError?
    /// The filtered trips, read when the sheet opens; nil until then or
    /// when they could not be read (Share then reports why).
    @State private var prepared: TripShareStaging.Prepared?
    @State private var isLoadingPreview = true
    /// Trip cards built for the preview, reused by Share.
    @State private var cards: [UUID: TripShareCardContent] = [:]
    /// Moves whenever `prepared` is replaced, so cards built for an older
    /// read are neither kept nor stored.
    @State private var previewGeneration = 0
    /// The user's pick between one summary and one image per trip.
    @State private var chosenImages: TripShareImages?
    /// Ends on Cancel or when the sheet goes, so a late staging is removed.
    @State private var lifetime = TripShareStaging.Lifetime()

    private var tripCount: Int { prepared?.file.trips.count ?? request.tripIDs.count }

    private var images: TripShareImages {
        guard TripShareImages.offersChoice(tripCount: tripCount) else { return .perTrip }
        return chosenImages ?? TripShareImages.defaultChoice(tripCount: tripCount)
    }

    private var options: TripShareStaging.Options {
        TripShareStaging.Options(overviewImage: includeImage, travelLogFile: includeFile, gpxRoute: includeGPX,
                                 images: images)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let note = itemsNote, isLoadingPreview || prepared != nil {
                    Section {
                        VStack(spacing: 10) {
                            if includeImage { preview }
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                }

                Section {
                    Toggle(isOn: $includeImage) {
                        SettingsTileLabel(
                            String(localized: "trip-share.option.image.title", defaultValue: "Overview Image",
                                   comment: "Share sheet toggle: include a picture of each trip's route, dates and places."),
                            systemImage: "photo", meaning: includeImage ? .record : .housekeeping)
                    }
                    if includeImage && TripShareImages.offersChoice(tripCount: tripCount) {
                        // Under the titles, as the rows' separators run.
                        let inset = SettingsIconTile.side + 12
                        Picker(String(localized: "trip-share.option.images.label", defaultValue: "Images",
                                      comment: "Accessibility name of the share sheet's choice between one summary image and one image per trip."),
                               selection: Binding(get: { images }, set: { chosenImages = $0 })) {
                            Text(String(localized: "trip-share.option.images.summary", defaultValue: "One Summary",
                                        comment: "Share sheet segment: one image summing up every chosen trip."))
                                .tag(TripShareImages.summary)
                            Text(String(localized: "trip-share.option.images.per-trip", defaultValue: "One per Trip",
                                        comment: "Share sheet segment: one image for each chosen trip."))
                                .tag(TripShareImages.perTrip)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.leading, inset)
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + inset }
                    }
                    Toggle(isOn: $includeFile) {
                        SettingsTileLabel(
                            String(localized: "trip-share.option.file.title", defaultValue: "Travel Log File",
                                   comment: "Share sheet toggle: include a file another Travel Log user can add to their history."),
                            systemImage: "doc", meaning: includeFile ? .record : .housekeeping)
                    }
                    Toggle(isOn: $includeGPX) {
                        SettingsTileLabel(
                            String(localized: "trip-share.option.gpx.title", defaultValue: "GPX Route",
                                   comment: "Share sheet toggle: include the route as a GPX file for maps and fitness apps."),
                            systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                            meaning: includeGPX ? .record : .housekeeping)
                    }
                } footer: {
                    Text(String(localized: "trip-share.options.footer",
                                defaultValue: "The image is for anyone. A Travel Log file lets someone who was there add the trip to their own history. A GPX route opens in maps and fitness apps.",
                                comment: "Footer under the share format toggles, explaining each format."))
                }

                if includeFile {
                    Section {
                        TextField(String(localized: "trip-share.sender-name.placeholder", defaultValue: "Your Name (Optional)",
                                         comment: "Placeholder of the optional name a shared Travel Log file shows its recipient."),
                                  text: $senderName)
                            .textContentType(.name)
                    } footer: {
                        Text(String(localized: "trip-share.sender-name.footer",
                                    defaultValue: "Shown to the person who opens the Travel Log file.",
                                    comment: "Footer under the optional sender name of a shared trip file."))
                    }
                }

                Section {
                } footer: {
                    Text(String(localized: "trip-share.privacy.footer",
                                defaultValue: "Shared items never include your homes, your time near them or your photos.",
                                comment: "Privacy note on the trip share sheet: what is always left out."))
                }
            }
            .settingsList()
            .task { await loadPreview() }
            .onDisappear { lifetime.end() }
            .navigationTitle(request.tripIDs.count == 1
                ? String(localized: "trip-share.title.one", defaultValue: "Share Trip",
                         comment: "Title of the sheet that shares one trip.")
                : String(localized: "trip-share.title.other", defaultValue: "Share \(request.tripIDs.count, format: .number.grouping(.never)) Trips",
                         comment: "Title of the sheet that shares several trips; the placeholder is how many."))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel", defaultValue: "Cancel",
                                  comment: "Generic cancel button.")) {
                        lifetime.end()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isPreparing {
                        ProgressView()
                    } else {
                        Button(String(localized: "trip-share.action.share", defaultValue: "Share",
                                      comment: "Confirms the trip share sheet and opens the system share sheet.")) {
                            Task { await prepare() }
                        }
                        .disabled(options.isEmpty || request.tripIDs.isEmpty)
                    }
                }
            }
            .sheet(item: Binding(get: { staged.map(StagedItems.init) }, set: { if $0 == nil { finish() } })) { items in
                ShareItemsActivityView(items: items.staged.items) { finish() }
                    .ignoresSafeArea()
            }
            .alert(String(localized: "trip-share.error.title", defaultValue: "Couldn't Share",
                          comment: "Alert title when the share items could not be prepared."),
                   isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button(String(localized: "common.ok", defaultValue: "OK", comment: "Generic OK button."), role: .cancel) {}
            } message: {
                Text(failure.map(Self.message) ?? "")
            }
        }
    }

    private struct StagedItems: Identifiable {
        let staged: TripShareStaging.Staged
        var id: URL { staged.directory }
    }

    private func prepare() async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        do throws(TripShareStaging.StagingError) {
            let ready: TripShareStaging.Prepared
            if let prepared {
                ready = prepared
            } else {
                ready = try await TripShareStaging.prepare(tripIDs: request.tripIDs)
                replacePreview(with: ready)
            }
            let generation = previewGeneration
            let tripIDs = request.tripIDs
            let outcome: (staged: TripShareStaging.Staged?, current: TripShareStaging.Prepared)
            do throws(TripShareStaging.StagingError) {
                outcome = try await TripShareStaging.stageIfCurrent(
                    ready, options: options, senderName: includeFile ? senderName : nil, cards: cards,
                    reread: { () async throws(TripShareStaging.StagingError) in
                        try await TripShareStaging.prepare(tripIDs: tripIDs)
                    })
            } catch {
                switch error {
                case .tooLarge, .writeFailed: break
                // The second read failed: what the preview shows is unknown.
                default: replacePreview(with: nil)
                }
                throw error
            }
            guard let written = outcome.staged, generation == previewGeneration else {
                if let unsent = outcome.staged { TripShareStaging.discard(unsent) }
                replacePreview(with: outcome.current)
                throw TripShareStaging.StagingError.changed
            }
            // Cancelled or closed while it was written: nothing presents it.
            guard let adopted = lifetime.adopt(written) else { return }
            staged = adopted
        } catch {
            failure = error
        }
    }

    /// Reads the trips for the preview; a failure waits for Share to report it.
    private func loadPreview() async {
        defer { isLoadingPreview = false }
        let read = try? await TripShareStaging.prepare(tripIDs: request.tripIDs)
        // Share may have read them first.
        if prepared == nil { replacePreview(with: read) }
    }

    /// Shows `read` from now on; the cards of the old read go with it.
    private func replacePreview(with read: TripShareStaging.Prepared?) {
        prepared = read
        cards = [:]
        previewGeneration += 1
    }

    // MARK: Preview

    /// The images as they will be sent, at about half size: the one card,
    /// the summary, or one card per trip side by side.
    @ViewBuilder
    private var preview: some View {
        if let trips = prepared?.file.trips {
            if images == .summary && trips.count > 1 {
                TripShareCardPreview(content: .summary(trips))
                    .frame(maxWidth: .infinity)
            } else if trips.count == 1, let trip = trips.first {
                card(for: trip)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 12) {
                        ForEach(trips) { trip in
                            card(for: trip)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
                .contentMargins(.horizontal, 20, for: .scrollContent)
                .scrollClipDisabled()
            }
        } else {
            TripShareCardPreview(content: nil)
                .frame(maxWidth: .infinity)
        }
    }

    private struct CardKey: Hashable {
        let trip: UUID
        let generation: Int
    }

    private func card(for trip: SharedTrip) -> some View {
        TripShareCardPreview(content: cards[trip.id])
            .task(id: CardKey(trip: trip.id, generation: previewGeneration)) {
                guard cards[trip.id] == nil, let exclusions = prepared?.exclusions else { return }
                let generation = previewGeneration
                let content = await TripShareCardRenderer.content(for: trip, exclusions: exclusions)
                guard generation == previewGeneration else { return }
                cards[trip.id] = content
            }
    }

    /// "1 image and 1 Travel Log file": what Share will hand over.
    private var itemsNote: String? {
        var parts: [String] = []
        if includeImage {
            let count = images == .summary ? 1 : tripCount
            parts.append(count == 1
                ? String(localized: "trip-share.note.images.one", defaultValue: "\(count, format: .number.grouping(.never)) image",
                         comment: "Share sheet note under the preview: how many images will be shared, for one.")
                : String(localized: "trip-share.note.images.other", defaultValue: "\(count, format: .number.grouping(.never)) images",
                         comment: "Share sheet note under the preview: how many images will be shared, for several."))
        }
        if includeFile {
            let count = tripCount
            parts.append(count == 1
                ? String(localized: "trip-share.note.file", defaultValue: "1 Travel Log file",
                         comment: "Share sheet note under the preview: one Travel Log file will be shared.")
                : String(localized: "trip-share.note.file.trips", defaultValue: "1 Travel Log file with \(count, format: .number.grouping(.never)) trips",
                         comment: "Share sheet note under the preview: one Travel Log file holding several trips will be shared; the placeholder is how many (always 2 or more)."))
        }
        if includeGPX {
            parts.append(String(localized: "trip-share.note.gpx", defaultValue: "1 GPX route",
                                comment: "Share sheet note under the preview: one GPX route file will be shared."))
        }
        guard !parts.isEmpty else { return nil }
        return parts.formatted(.list(type: .and).locale(AppLanguagePreference.currentLocale()))
    }

    /// The share sheet closed: its copies go, and so does this sheet.
    private func finish() {
        guard let current = staged else { return }
        try? FileManager.default.removeItem(at: current.directory)
        staged = nil
        dismiss()
    }

    static func message(_ error: TripShareStaging.StagingError) -> String {
        switch error {
        case .homesUnreadable, .tripsUnreadable:
            String(localized: "trip-share.error.unreadable",
                   defaultValue: "Your trips couldn't be read just now. Try again in a moment.",
                   comment: "Share error when the trips or home areas could not be read.")
        case .tripsMissing:
            String(localized: "trip-share.error.missing",
                   defaultValue: "These trips are no longer in Travel Log.",
                   comment: "Share error when every chosen trip was deleted, on this or another device, while the share sheet was open.")
        case .nothingToShare:
            String(localized: "trip-share.error.nothing",
                   defaultValue: "Everything in this selection is inside your home areas, so there is nothing to share.",
                   comment: "Share error when every stop of the chosen trips is inside the user's home areas.")
        case .changed:
            String(localized: "trip-share.error.changed",
                   defaultValue: "Your trips or homes changed while this was open. Check the updated preview, then share again.",
                   comment: "Share error when the chosen trips, the user's homes or their dates changed while the share sheet was open; nothing was shared and the preview now shows the current trips.")
        case .tooLarge:
            String(localized: "trip-share.error.too-large",
                   defaultValue: "These trips are too large for one Travel Log file. Choose fewer trips and try again.",
                   comment: "Share error when the Travel Log file for the chosen trips would be larger than the app can open.")
        case .writeFailed:
            String(localized: "trip-share.error.write",
                   defaultValue: "The files couldn't be prepared. Check your free space and try again.",
                   comment: "Share error when the share files could not be written.")
        }
    }
}

/// A card at the sheet's preview size, dark whatever the appearance; a
/// placeholder while its map is drawn.
private struct TripShareCardPreview: View {
    let content: TripShareCardContent?

    static let scale: CGFloat = 0.54

    var body: some View {
        let size = TripShareCardContent.size
        ZStack(alignment: .topLeading) {
            if let content {
                TripShareCardView(content: content)
                    .scaleEffect(Self.scale, anchor: .topLeading)
            } else {
                TripShareCardView.background
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: size.width * Self.scale, height: size.height * Self.scale, alignment: .topLeading)
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 15, y: 10)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "trip-share.preview.accessibility", defaultValue: "Preview of the overview image",
                                   comment: "Accessibility label of the share sheet's preview of the image that will be shared."))
        .accessibilityValue(content?.title ?? "")
    }
}

/// The system share sheet over files, calling back once when it closes.
struct ShareItemsActivityView: UIViewControllerRepresentable {
    let items: [URL]
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
