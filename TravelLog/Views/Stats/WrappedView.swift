//
//  WrappedView.swift
//  TravelLog
//

import SwiftUI
import SwiftData
import CoreTransferable
import UniformTypeIdentifiers

/// Value snapshot of a `YearWrapped` row, taken each time `RootView` builds
/// the view.
///
/// `WrappedView` renders from this snapshot instead of holding the live
/// `@Model` reference: `YearWrappedDeduplicator`
/// (launch + CloudKit remote-push call sites) can hard-delete the presented
/// row mid-display when a same-year duplicate syncs in, and a live reference
/// would mix stats decoded from the old row with card gating read off the
/// swapped survivor — or fault a deleted model outright. `RootView`
/// re-resolves by year on every body pass and re-keys the view via `.id`, so
/// a dedup swap rebuilds the whole view from the survivor.
///
/// A row's content can also change in place under the same id: dedup
/// absorption copies newer content onto the survivor, and the calendar
/// privacy scrub rewrites names and drops stored prose. Each rebuild takes a
/// fresh snapshot, and `WrappedView` derives everything from it, so an open
/// recap follows those rewrites instead of rendering or sharing old values.
struct WrappedViewData: Equatable {
    let id: UUID
    let year: Int
    let weatherCoverage: Double
    let yearNarrative: String?
    let statsData: Data?

    init(wrapped: YearWrapped) {
        id = wrapped.id
        year = wrapped.year
        weatherCoverage = wrapped.weatherCoverage
        yearNarrative = wrapped.yearNarrative
        statsData = wrapped.statsData
    }
}

/// Pure display policy for persisted Wrapped prose.
nonisolated enum WrappedDisplayResolver {
    /// The narrative is rendered live from the structured inputs in the
    /// viewer's language whenever the blob carries them. Stored prose is
    /// only shown for rows written before `narrativeInputs` existed; a
    /// stored model-written paragraph (rows from before 2026-09-04) is
    /// ignored the moment inputs are present, so no migration is needed to
    /// retire it.
    static func resolvedNarrative(
        storedProse: String?,
        stats: WrappedStats,
        locale: Locale
    ) -> String? {
        guard let inputs = stats.narrativeInputs else { return storedProse }
        return YearWrappedGenerator.deterministicNarrative(
            from: inputs,
            stats: stats,
            locale: locale
        )
    }

    static func resolvedMysteryFact(stats: WrappedStats, locale: Locale) -> String? {
        stats.mysteryFact?.render(locale: locale) ?? stats.mysteryFactText
    }
}

/// Annual recap (Wrapped) view. Vertical full-screen pager over poster
/// cards (`WrappedPosterCards.swift`), one idea per card, following the
/// system appearance.
///
/// Data source: a `YearWrapped` snapshot entity, captured as a
/// `WrappedViewData` value at init (see its doc for why no live model is
/// held), with its stats decoded in the same init. Only presentation state
/// (page, revealed cards) lives in `@State`. All stats are pre-computed at
/// generation time by `YearWrappedGenerator`. Historical counts and prose retain their saved
/// generation semantics; shared travel-day semantics apply to new snapshots.
///
/// Vertical paging on iOS uses `ScrollView` + `.scrollTargetBehavior(.paging)`
/// + `.containerRelativeFrame(.vertical)`. `TabView(.verticalPage)` is
/// watchOS-only.
struct WrappedView: View {

    let data: WrappedViewData
    let onDismiss: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme

    /// Decoded from `data` on every init, never cached in `@State`: a
    /// same-id content rewrite (privacy scrub, dedup absorption) must reach
    /// every card, the ledger footnote and a newly requested share. Internal as a
    /// test seam.
    let stats: WrappedStats

    /// Display values derived from `stats` in the app language, rebuilt on
    /// every init like `stats`.
    let content: WrappedPosterContent

    /// Index of the page the pager is resting on (`scrollPosition(id:)`).
    @State private var currentPage: Int? = 0

    /// Pages whose entrance animation has already played. Each card animates
    /// in exactly once per presentation: the first time the pager lands on
    /// it. Paging back to an earlier card finds it settled; only a fresh
    /// presentation (this view is rebuilt by `fullScreenCover`) plays the
    /// whole sequence again.
    @State private var revealedPages: Set<Int> = []

    /// Pause between the cover's presentation and the first card's
    /// entrance, so the two transitions do not fight for attention.
    private static let firstRevealDelay: Duration = .milliseconds(400)

    private var appLocale: Locale {
        AppLanguagePreference.currentLocale()
    }

    init(wrapped: YearWrapped, onDismiss: @escaping () -> Void) {
        let data = WrappedViewData(wrapped: wrapped)
        self.data = data
        self.onDismiss = onDismiss
        // Decode BEFORE first layout: card selection and the share render must
        // never see empty stats (a weather ⇄ top-destinations flip under the
        // pager, which keys on `\.offset`; a 0-country share image). The blob
        // is already in hand here (it comes off the row `data` was built
        // from), so the decode costs one JSON parse on the main actor at
        // construction. A row with no
        // readable blob renders empty stats rather than another row's.
        stats = data.statsData.flatMap(WrappedStats.decoded(from:)) ?? WrappedStats()
        content = WrappedPosterContent(year: data.year, stats: stats,
                                       weatherCoverage: data.weatherCoverage,
                                       locale: AppLanguagePreference.currentLocale())
    }

    /// The page to rest on after the card list changed under an open recap:
    /// the same index while it still exists, else the last card. `nil`
    /// (the pager between targets) is left alone. Pure test seam.
    static func clampedPage(_ page: Int?, cardCount: Int) -> Int? {
        guard let page, cardCount > 0 else { return page }
        return min(max(page, 0), cardCount - 1)
    }

    private var visibleCards: [WrappedCardKind] {
        Self.visibleCards(stats: stats,
                          weatherCoverage: data.weatherCoverage)
    }

    /// Minimum single-mode distance for a mode row on the distance card,
    /// and for the card itself when no total was measured.
    static let transitCardMinimumKm: Double = 50

    /// Whether the weather card can draw at least one row. Pure seam shared
    /// with `visibleCards` and with the weather card's own body, so the gate
    /// and the rendering can never disagree,
    /// the same "one rule, two consumers" shape as `HexVisibility`.
    static func weatherCardHasContent(stats: WrappedStats) -> Bool {
        (stats.hottestTempC != nil && stats.hottestLocality != nil)
            || (stats.coldestTempC != nil && stats.coldestLocality != nil)
            || (stats.rainiestTripName != nil && (stats.rainiestPrecipitationMm ?? 0) > 0)
    }

    /// Trips started in each calendar month of the recap's year, in the
    /// generator's UTC frame. Nil for blobs without `narrativeInputs` (rows
    /// written before the structured inputs existed), which therefore have
    /// no months card.
    static func tripsPerMonth(stats: WrappedStats) -> [Int]? {
        guard let inputs = stats.narrativeInputs else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var months = Array(repeating: 0, count: 12)
        for date in inputs.tripStartDates where utc.component(.year, from: date) == inputs.year {
            months[utc.component(.month, from: date) - 1] += 1
        }
        return months
    }

    /// Pure card-gating rule (test seam). Data-presence gates: a card with
    /// nothing to say is worse than no card. Title, places and closing
    /// always show; every other card needs its own data.
    static func visibleCards(
        stats: WrappedStats,
        weatherCoverage: Double
    ) -> [WrappedCardKind] {
        var cards: [WrappedCardKind] = [.title, .places]
        if stats.longestTripName != nil, stats.longestTripDays > 0 { cards.append(.longestTrip) }
        if stats.farthestDistanceKm > 0 { cards.append(.farthest) }
        // Two trips make a month comparison; one would be a lone column.
        if (tripsPerMonth(stats: stats)?.reduce(0, +) ?? 0) >= 2 { cards.append(.months) }
        // The total is geometric and covers imported data; mode splits only
        // count inference-attributed legs, so either can carry the card.
        if stats.totalGreatCircleKm > 0
            || max(stats.flightKm, stats.driveKm, stats.walkKm) >= Self.transitCardMinimumKm {
            cards.append(.distance)
        }
        if stats.daysAbroad + stats.daysAtHome > 0 { cards.append(.homeAway) }
        if !stats.newCountryCodes.isEmpty { cards.append(.firstVisits) }
        // Weather card gate: the extremes-safe verdict computed at
        // generation time ("no still-enrichable stay could plausibly beat
        // the measured records"); pre-feature artifacts (nil) keep the
        // >= 0.7 coverage rule. The verdict is about HONESTY, not about
        // whether anything is renderable, and every row needs a place
        // string as well as a number, so gate on renderable CONTENT too.
        if (stats.weatherExtremesSafe ?? (weatherCoverage >= 0.7)),
           Self.weatherCardHasContent(stats: stats) {
            cards.append(.weather)
        }
        cards.append(.closing)
        return cards
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visibleCards.enumerated()), id: \.offset) { index, kind in
                        cardView(for: kind, index: index, total: visibleCards.count)
                            .containerRelativeFrame(.vertical)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentPage)
            .scrollIndicators(.hidden)
            .ignoresSafeArea()

            closeButton
        }
        .background(WrappedPosterPalette(colorScheme).paper)
        .onChange(of: currentPage) { _, page in
            if let page { reveal(page) }
        }
        // Content rewritten in place keeps the reader on the current page;
        // if cards disappeared under it, rest on the last one instead of an
        // index the pager no longer has.
        .onChange(of: visibleCards.count) { _, count in
            let clamped = Self.clampedPage(currentPage, cardCount: count)
            if clamped != currentPage { currentPage = clamped }
        }
        .task(id: data.id) {
            // The opening card is already on screen, so no scroll-position
            // change will ever reveal it; kick it off here after the cover
            // has settled. If the user has paged on by then, `onChange`
            // already revealed whichever card they reached and this is a
            // no-op for that card.
            do { try await Task.sleep(for: Self.firstRevealDelay) }
            catch { return }
            guard !Task.isCancelled else { return }
            reveal(currentPage ?? 0)
        }
    }

    /// Mark a page as revealed. The insert itself is not animated: every
    /// card attaches its own `.animation(_:value:)` to the flag so each
    /// element picks its own curve and delay. The first reveal, from the
    /// opening delay or an early swipe, stamps the recap seen from here: a
    /// view task keyed on the reveal would never start if the cover were
    /// dismissed in the same update.
    private func reveal(_ page: Int) {
        guard !revealedPages.contains(page) else { return }
        if revealedPages.isEmpty {
            let year = data.year
            let container = modelContext.container
            Task { await Self.stampViewed(year: year, in: container) }
        }
        revealedPages.insert(page)
    }

    #if DEBUG
    @TaskLocal static var beforeViewedStampGateForTesting: (@Sendable () async -> Void)?
    #endif

    /// Stamp `viewedAt` by re-resolving the row(s) by year instead of
    /// writing through the captured reference — the presented row may have
    /// been hard-deleted by `YearWrappedDeduplicator` since construction.
    /// Only unseen same-year rows are stamped;
    /// existing first-view dates are preserved. Once content was revealed,
    /// dismissal cancellation deliberately does not skip this small write,
    /// even if it is still waiting for the gate.
    static func stampViewed(year: Int, in container: ModelContainer,
                            gate: PipelineGate = .shared) async {
        #if DEBUG
        if let beforeViewedStampGateForTesting { await beforeViewedStampGateForTesting() }
        #endif
        await gate.run(touching: [.yearWrapped]) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            do {
                let rows = try context.fetch(FetchDescriptor<YearWrapped>(
                    predicate: #Predicate { $0.year == year }))
                let now = Date.now
                for row in rows where row.viewedAt == nil { row.viewedAt = now }
                if context.hasChanges { try context.save() }
            } catch {
                context.rollback()
            }
        }
    }

    private func cardView(for kind: WrappedCardKind, index: Int, total: Int,
                          settled: Bool = false) -> some View {
        WrappedPosterCard(
            kind: kind,
            content: content,
            share: kind == .closing ? share : nil,
            index: index,
            total: total,
            revealed: settled || revealedPages.contains(index))
    }

    /// The closing card's share payload: values only, rendered when the
    /// share sheet asks for the PNG.
    private var share: WrappedShare {
        WrappedShare(year: data.year, stats: stats, appLocaleIdentifier: appLocale.identifier)
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(.regularMaterial, in: Circle())
        }
        .accessibilityLabel("Close")
        .padding(.top, 50)
        .padding(.trailing, 16)
    }
}

#if DEBUG
extension WrappedView {
    /// Design-review render seam: every visible card, already revealed, in
    /// pager order. Used only by the env-gated Wrapped render test.
    func settledCardsForRendering() -> [AnyView] {
        let cards = visibleCards
        return cards.enumerated().map { index, kind in
            AnyView(cardView(for: kind, index: index, total: cards.count, settled: true))
        }
    }
}
#endif

// MARK: - Card Kinds

enum WrappedCardKind: Equatable {
    case title
    case places
    case longestTrip
    case farthest
    case months
    case distance
    case homeAway
    case firstVisits
    case weather
    case closing
}

// MARK: - Motion
//
// Every card animates in once, the first time the pager lands on it. The
// parent flips a per-card `revealed` flag (see `WrappedView.reveal`) and
// each element attaches its own `.animation(_:value:)` to that flag, so a
// card built with `revealed == true` from the start (paging back to a
// card the lazy stack had dropped) renders settled with no motion at all.
// Text rises into place; bars, rings and the away band grow once to their
// value. Reduce Motion collapses every curve to an instant switch.

enum WrappedMotion {
    /// Text rises into place: fade + short upward drift.
    static let rise: Animation = .spring(duration: 0.65, bounce: 0.15)
    /// Bars, rings and the away band grow into their value.
    static let grow: Animation = .easeOut(duration: 1.1)
    /// Gap between successive elements of one card.
    static let stagger: Double = 0.12
}

/// Fade-and-rise entrance for text and panels.
private struct WrappedRiseModifier: ViewModifier {
    let revealed: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed || reduceMotion ? 0 : 16)
            .animation(reduceMotion ? nil : WrappedMotion.rise.delay(delay), value: revealed)
    }
}

/// Growth entrance for a mark: `progress` runs 0 to 1 on the shared grow
/// curve, or jumps straight to 1 under Reduce Motion.
struct WrappedGrowModifier: ViewModifier {
    let revealed: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .animation(reduceMotion ? nil : WrappedMotion.grow.delay(delay), value: revealed)
    }
}

extension View {
    func wrappedRise(_ revealed: Bool, delay: Double = 0) -> some View {
        modifier(WrappedRiseModifier(revealed: revealed, delay: delay))
    }

    /// Animates whatever this view derives from `revealed` on the grow curve.
    func wrappedGrow(_ revealed: Bool, delay: Double = 0) -> some View {
        modifier(WrappedGrowModifier(revealed: revealed, delay: delay))
    }
}

// MARK: - Share payload

/// Value-only, localized share input. Bitmap and PNG work starts only when
/// the share sheet requests it, on the renderer's detached task rather than
/// the main actor. Draws the poster: the year, up to four totals, and the
/// first-visit country codes.
nonisolated struct WrappedShare: Transferable {
    let year: Int
    let content: WrappedShareRenderer.Content

    @MainActor
    init(year: Int, stats: WrappedStats, appLocaleIdentifier: String) {
        self.year = year
        let locale = Locale(identifier: appLocaleIdentifier)
        let units = WrappedUnits(locale: locale, stats: stats)
        func row(_ value: Int, _ label: String) -> WrappedShareRenderer.Row {
            .init(value: value.formatted(.number.locale(locale)), label: label)
        }
        var rows: [WrappedShareRenderer.Row] = []
        if stats.tripsCompleted > 0 { rows.append(row(stats.tripsCompleted, units.trips(stats.tripsCompleted))) }
        rows.append(row(stats.countriesVisited, units.countries(stats.countriesVisited)))
        if stats.totalDaysAbroad > 0 { rows.append(row(stats.totalDaysAbroad, units.daysAway(stats.totalDaysAbroad))) }
        if stats.totalGreatCircleKm > 0 {
            let distance = WrappedUnits.distance(stats.totalGreatCircleKm, locale: locale)
            rows.append(.init(value: distance.value, label: distance.longUnit))
        }
        if rows.count < 4, stats.citiesVisited > 0 {
            rows.insert(row(stats.citiesVisited, units.cities(stats.citiesVisited)),
                        at: min(2, rows.count))
        }
        let codes = stats.newCountryCodes.prefix(6).joined(separator: " ")
        content = WrappedShareRenderer.Content(
            yearLines: WrappedUnits.yearLines(year),
            heading: String(localized: "wrapped.share.heading", defaultValue: "Travel", locale: locale,
                            comment: "Small heading above the year on the shared Wrapped poster image; shown in capitals.")
                .uppercased(with: locale),
            rows: Array(rows.prefix(4)),
            branding: "TravelLog",
            footnote: codes.isEmpty ? nil
                : String(localized: "wrapped.share.first-visits", defaultValue: "First visits: \(codes)", locale: locale,
                         comment: "Footer of the shared Wrapped poster: ISO country codes visited for the first time that year, separated by spaces."),
            language: locale.identifier)
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { payload in
            try await WrappedShareRenderer.pngData(for: payload.content)
        }
        .suggestedFileName { "TravelLog-Wrapped-\($0.year).png" }
    }
}

// MARK: - Share Pipeline

/// Renders any SwiftUI view as a `UIImage` for sharing.
/// Caller decides the canvas size (1080×1080 square or 1080×1920 story).
@MainActor
enum WrappedRenderer {

    static func renderImage<Content: View>(
        @ViewBuilder content: () -> Content,
        size: CGSize,
        scale: CGFloat,
        locale: Locale = AppLanguagePreference.currentLocale()
    ) -> UIImage? {
        let view = content()
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
            // ImageRenderer builds off-hierarchy, so inject the exact app
            // localization rather than the region-combined process locale.
            .environment(\.locale, locale)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.isOpaque = true
        return renderer.uiImage
    }
}
