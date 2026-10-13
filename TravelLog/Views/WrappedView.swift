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

/// Annual recap (Wrapped) view. Vertical full-screen pager over 10 cards.
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

    /// Decoded from `data` on every init, never cached in `@State`: a
    /// same-id content rewrite (privacy scrub, dedup absorption) must reach
    /// every card, the narrative and a newly requested share. Internal as a
    /// test seam.
    let stats: WrappedStats

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

    /// Minimum single-mode distance for the transit card (see the gate
    /// below).
    static let transitCardMinimumKm: Double = 50

    /// Whether the weather card can draw at least one row. Pure seam shared
    /// with `visibleCards` and with `WeatherCard`'s own body, so the gate and
    /// the rendering can never disagree —
    /// the same "one rule, two consumers" shape as `HexVisibility`.
    static func weatherCardHasContent(stats: WrappedStats) -> Bool {
        (stats.hottestTempC != nil && stats.hottestLocality != nil)
            || (stats.coldestTempC != nil && stats.coldestLocality != nil)
            || (stats.rainiestTripName != nil && (stats.rainiestPrecipitationMm ?? 0) > 0)
    }

    /// Pure card-gating rule (test seam). Data-presence gates: a card with
    /// nothing to say ("—") is worse than no card.
    static func visibleCards(
        stats: WrappedStats,
        weatherCoverage: Double
    ) -> [WrappedCardKind] {
        var cards: [WrappedCardKind] = [.coldOpen, .globe]
        if stats.longestTripName != nil { cards.append(.longestTrip) }
        if stats.farthestDistanceKm > 0 { cards.append(.farthest) }
        // Weather card gate: the extremes-safe verdict computed at
        // generation time ("no still-enrichable stay could plausibly beat
        // the measured records") replaces
        // the blunt coverage threshold, which prevented a BLANK card but not
        // a WRONG one. Pre-feature artifacts (nil) keep the ≥ 0.7 rule.
        //
        // The verdict is about HONESTY ("could a still-unmeasured stay beat
        // these records?"), not about whether anything is renderable, and
        // every row of the card needs a place string as well as a number, so
        // gate on renderable CONTENT too: otherwise a place-less extreme
        // drops its row and, in the limit, the card renders as an empty panel
        // with the Top-Destinations fallback suppressed behind it.
        if (stats.weatherExtremesSafe ?? (weatherCoverage >= 0.7)),
           Self.weatherCardHasContent(stats: stats) {
            cards.append(.weather)
        } else {
            cards.append(.topDestinations)
        }
        // Transit card gate: TransitInferer writes only `.flight`/`.unknown`,
        // so a coverage fraction of known modes could never be met. Gate on
        // renderable CONTENT instead: the card draws one bar per non-zero
        // mode and degrades gracefully, so it earns its slot when any mode
        // logged meaningful distance (legacy drive/walk data included).
        // `transitCardMinimumKm` keeps a lone 2 km walk bar from carrying a
        // whole card.
        if max(stats.flightKm, stats.driveKm, stats.walkKm) >= Self.transitCardMinimumKm {
            cards.append(.transit)
        } else {
            cards.append(.totalDistance)
        }
        cards.append(.newCountries)
        cards.append(.timeBalance)
        if stats.mysteryFact != nil || stats.mysteryFactText != nil {
            cards.append(.mystery)
        }
        cards.append(.yearNarrative)
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
        .background(Color.black)
        .preferredColorScheme(.dark)
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

    @ViewBuilder
    private func cardView(for kind: WrappedCardKind, index: Int, total: Int) -> some View {
        let revealed = revealedPages.contains(index)
        switch kind {
        case .coldOpen:
            ColdOpenCard(year: data.year, stats: stats, index: index, total: total, revealed: revealed)
        case .globe:
            GlobeCard(stats: stats, index: index, total: total, revealed: revealed)
        case .longestTrip:
            LongestTripCard(stats: stats, index: index, total: total, revealed: revealed)
        case .farthest:
            FarthestCard(stats: stats, index: index, total: total, revealed: revealed)
        case .weather:
            WeatherCard(stats: stats, index: index, total: total, revealed: revealed)
        case .topDestinations:
            TopDestinationsCard(stats: stats, index: index, total: total, revealed: revealed)
        case .transit:
            TransitCard(stats: stats, index: index, total: total, revealed: revealed)
        case .totalDistance:
            TotalDistanceCard(stats: stats, index: index, total: total, revealed: revealed)
        case .newCountries:
            NewCountriesCard(stats: stats, index: index, total: total, revealed: revealed)
        case .timeBalance:
            TimeBalanceCard(stats: stats, index: index, total: total, revealed: revealed)
        case .mystery:
            MysteryCard(stats: stats, index: index, total: total, revealed: revealed)
        case .yearNarrative:
            YearNarrativeCard(
                year: data.year,
                resolvedNarrative: WrappedDisplayResolver.resolvedNarrative(
                    storedProse: data.yearNarrative,
                    stats: stats,
                    locale: appLocale
                ),
                stats: stats,
                appLocale: appLocale,
                index: index,
                total: total,
                revealed: revealed
            )
        }
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(.top, 50)
        .padding(.trailing, 16)
    }
}

// MARK: - Card Kinds

enum WrappedCardKind {
    case coldOpen
    case globe
    case longestTrip
    case farthest
    case weather
    case topDestinations          // weather fallback
    case transit
    case totalDistance            // transit fallback
    case newCountries
    case timeBalance
    case mystery
    case yearNarrative
}

// MARK: - Design System
//
// "Pages of one travel document" (June-2026 redesign). The previous
// Wrapped gave every card the same centered-text skeleton on a different
// loud two-tone gradient — template confetti with no family resemblance.
// Now every card shares the Passport's deep-navy base; per-card identity
// comes from three controlled knobs instead of a new gradient: an accent
// color (radial glow + kicker + progress dot), a giant faded SF-symbol
// motif, and the content composition itself. Numbers are grouped
// (`.formatted()`), copy is left-aligned and editorial, and cards with
// nothing to say are gated out by `visibleCards`.

private enum WrappedDesign {
    static let baseTop = Color(red: 0.10, green: 0.15, blue: 0.34)
    static let baseBottom = Color(red: 0.04, green: 0.07, blue: 0.18)
    static let gold = Color(red: 0.85, green: 0.72, blue: 0.42)
}

// MARK: - Motion
//
// Every card animates in once, the first time the pager lands on it. The
// parent flips a per-card `revealed` flag (see `WrappedView.reveal`) and
// each element attaches its own `.animation(_:value:)` to that flag, so a
// card built with `revealed == true` from the start (paging back to a
// card the lazy stack had dropped) renders settled with no motion at all.
// Reduce Motion collapses every curve to an instant switch.

private enum WrappedMotion {
    /// Text rises into place: fade + short upward drift.
    static let rise: Animation = .spring(duration: 0.65, bounce: 0.15)
    /// Bars, rings and counters grow into their value.
    static let grow: Animation = .easeOut(duration: 1.1)
    /// A passport stamp slams down: overshoots then settles.
    static let stamp: Animation = .spring(duration: 0.45, bounce: 0.45)
    /// Small chip / button pop.
    static let pop: Animation = .spring(duration: 0.5, bounce: 0.35)
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
            .offset(y: revealed ? 0 : 16)
            .animation(reduceMotion ? nil : WrappedMotion.rise.delay(delay), value: revealed)
    }
}

/// Scale-in entrance for chips and buttons.
private struct WrappedPopModifier: ViewModifier {
    let revealed: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .scaleEffect(revealed ? 1 : 0.7)
            .animation(reduceMotion ? nil : WrappedMotion.pop.delay(delay), value: revealed)
    }
}

/// Passport-stamp entrance: starts large, over-rotated and transparent,
/// then slams down onto its resting lean.
private struct WrappedStampModifier: ViewModifier {
    let revealed: Bool
    let lean: Double
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .scaleEffect(revealed ? 1 : 1.7)
            .rotationEffect(.degrees(revealed ? lean : lean * 4))
            .animation(reduceMotion ? nil : WrappedMotion.stamp.delay(delay), value: revealed)
    }
}

private extension View {
    func wrappedRise(_ revealed: Bool, delay: Double = 0) -> some View {
        modifier(WrappedRiseModifier(revealed: revealed, delay: delay))
    }

    func wrappedPop(_ revealed: Bool, delay: Double = 0) -> some View {
        modifier(WrappedPopModifier(revealed: revealed, delay: delay))
    }

    func wrappedStamp(_ revealed: Bool, lean: Double, delay: Double = 0) -> some View {
        modifier(WrappedStampModifier(revealed: revealed, lean: lean, delay: delay))
    }
}

/// A number that counts from zero to `value` when `revealed` flips.
/// `Animatable` conformance lets SwiftUI interpolate `value`; `format`
/// turns each intermediate into display text (grouping, units, locale).
private struct WrappedCounter: View, Animatable {
    var value: Double
    let format: (Double) -> String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(format(value))
    }
}

/// Counter wrapper that owns the reveal wiring: zero until revealed, then
/// grows to `target` on the shared `grow` curve.
private struct WrappedCountUp: View {
    let target: Double
    let revealed: Bool
    var delay: Double = 0
    let format: (Double) -> String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WrappedCounter(value: revealed ? target : 0, format: format)
            .animation(reduceMotion ? nil : WrappedMotion.grow.delay(delay), value: revealed)
    }
}

/// Shared page scaffold: navy base, accent glow (top trailing), faded
/// motif symbol, kicker line, content slot, progress dots + watermark.
private struct WrappedPage<Content: View>: View {
    let kicker: String
    let accent: Color
    let motif: String
    let index: Int
    let total: Int
    let revealed: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [WrappedDesign.baseTop, WrappedDesign.baseBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [accent.opacity(0.32), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 460
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Image(systemName: motif)
                        .font(.system(size: 220, weight: .bold))
                        .foregroundStyle(accent.opacity(0.10))
                        .rotationEffect(.degrees(-12))
                        .offset(x: 48, y: -8)
                }
                Spacer()
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(kicker.uppercased(with: AppLanguagePreference.currentLocale()))
                    .font(.caption.weight(.semibold))
                    .tracking(4)
                    .foregroundStyle(accent)
                    .padding(.top, 84)
                    .wrappedRise(revealed)

                Spacer()
                content()
                Spacer()

                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)

            pageIndicator
        }
    }

    /// Vertical page indicator on the trailing edge, one dot per card with
    /// the current one stretched along the scroll axis. The pager scrolls
    /// vertically, so the indicator runs vertically too: the previous row of
    /// dots under the content would read as "swipe sideways".
    /// Drawn per page rather than as one overlay on the pager so it takes
    /// the page's accent and needs no scroll-position plumbing; every page
    /// draws it at the same place, so paging leaves it visually still.
    private var pageIndicator: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                ForEach(0..<total, id: \.self) { dot in
                    Capsule()
                        .fill(dot == index ? accent : Color.white.opacity(0.25))
                        .frame(width: 5, height: dot == index ? 18 : 5)
                }
            }
            .padding(.trailing, 12)
        }
        .accessibilityHidden(true)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "airplane")
                    .font(.caption2)
                Text("TravelLog")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 28)
    }
}

// MARK: - Shared atoms

/// Hero numeral + unit, the page's focal point. Left-aligned (editorial),
/// grouped digits, scales down rather than wrapping. The numeral counts up
/// from zero on reveal; `format` renders each intermediate value.
private struct WrappedHero: View {
    let value: Double
    let unit: String
    let revealed: Bool
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            WrappedCountUp(target: value, revealed: revealed, delay: WrappedMotion.stagger, format: format)
                .font(.system(size: 92, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .wrappedRise(revealed, delay: WrappedMotion.stagger)
            Text(unit)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
                .wrappedRise(revealed, delay: WrappedMotion.stagger * 2)
        }
    }
}

/// Soft inset panel for secondary content (quotes, rows).
private struct WrappedPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.white.opacity(0.07), in: .rect(cornerRadius: 18))
    }
}

// MARK: - Card 1: Cold Open

private struct ColdOpenCard: View {
    let year: Int
    let stats: WrappedStats
    let index: Int
    let total: Int
    let revealed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WrappedPage(kicker: String(localized: "wrapped.kicker.year-in-motion", defaultValue: "Your year in motion", comment: "Wrapped opening-card kicker."), accent: WrappedDesign.gold,
                    motif: "airplane", index: index, total: total, revealed: revealed) {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: String(year))
                        .font(.system(size: 110, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .wrappedRise(revealed, delay: WrappedMotion.stagger)
                    Rectangle()
                        .fill(WrappedDesign.gold)
                        .frame(width: revealed ? 56 : 0, height: 3)
                        .frame(width: 56, alignment: .leading)
                        .animation(reduceMotion ? nil : WrappedMotion.grow.delay(WrappedMotion.stagger * 2), value: revealed)
                }

                VStack(alignment: .leading, spacing: 16) {
                    if stats.countriesVisited > 0 {
                        openerLine(value: stats.countriesVisited,
                                   unit: stats.countriesVisited == 1
                                        ? String(localized: "wrapped.opening.country.one", defaultValue: "country", comment: "Wrapped opening statistic unit for one country.")
                                        : String(localized: "wrapped.opening.country.other", defaultValue: "countries", comment: "Wrapped opening statistic unit for multiple countries."),
                                   order: 0)
                    }
                    if stats.citiesVisited > 0 {
                        openerLine(value: stats.citiesVisited,
                                   unit: stats.citiesVisited == 1
                                        ? String(localized: "wrapped.opening.city.one", defaultValue: "city", comment: "Wrapped opening statistic unit for one city.")
                                        : String(localized: "wrapped.opening.city.other", defaultValue: "cities", comment: "Wrapped opening statistic unit for multiple cities."),
                                   order: 1)
                    }
                    if stats.totalDaysAbroad > 0 {
                        openerLine(value: stats.totalDaysAbroad, unit: String(localized: "wrapped.opening.days-away", defaultValue: "days away", comment: "Wrapped opening statistic unit for days spent away."),
                                   order: 2)
                    }
                }
            }
        }
    }

    /// `order` staggers the three lines after the year and rule.
    private func openerLine(value: Int, unit: String, order: Int) -> some View {
        let delay = WrappedMotion.stagger * Double(3 + order)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            WrappedCountUp(target: Double(value), revealed: revealed, delay: delay) { Int($0.rounded()).formatted() }
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(unit.uppercased(with: AppLanguagePreference.currentLocale()))
                .font(.caption.weight(.semibold))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .wrappedRise(revealed, delay: delay)
    }
}

// MARK: - Card 2: Places Explored

private struct GlobeCard: View {
    let stats: WrappedStats
    let index: Int
    let total: Int
    let revealed: Bool

    var body: some View {
        WrappedPage(kicker: String(localized: "wrapped.kicker.where-you-went", defaultValue: "Where you went", comment: "Wrapped places card kicker."), accent: .teal,
                    motif: "globe.europe.africa.fill", index: index, total: total, revealed: revealed) {
            VStack(alignment: .leading, spacing: 20) {
                WrappedHero(
                    value: Double(stats.totalHexesVisited),
                    unit: stats.totalHexesVisited == 1
                        ? String(localized: "wrapped.places-explored.one", defaultValue: "place explored", comment: "Wrapped explored-place unit for one place.")
                        : String(localized: "wrapped.places-explored.other", defaultValue: "places explored", comment: "Wrapped explored-place unit for multiple places."),
                    revealed: revealed
                ) { Int($0.rounded()).formatted() }
                if stats.totalHexesVisited > 0 {
                    Text("≈ \(Int((Double(stats.totalHexesVisited) * 36.13).rounded()).formatted()) km² of the world, on foot and in motion.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.65))
                        .wrappedRise(revealed, delay: WrappedMotion.stagger * 3)
                }
            }
        }
    }
}

// MARK: - Card 3: Longest Trip

private struct LongestTripCard: View {
    let stats: WrappedStats
    let index: Int
    let total: Int
    let revealed: Bool

    var body: some View {
        WrappedPage(kicker: String(localized: "wrapped.kicker.longest-trip", defaultValue: "The long one", comment: "Wrapped longest-trip card kicker."), accent: .orange,
                    motif: "calendar", index: index, total: total, revealed: revealed) {
            VStack(alignment: .leading, spacing: 20) {
                Text(stats.longestTripName ?? "")
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(3)
                    .wrappedRise(revealed, delay: WrappedMotion.stagger)

                if stats.longestTripDays > 0 {
                    Text(stats.longestTripDays == 1
                         ? String(localized: "wrapped.longest-trip-days.one", defaultValue: "\(stats.longestTripDays, format: .number.grouping(.never)) DAY", comment: "Wrapped longest-trip duration badge for one day.")
                         : String(localized: "wrapped.longest-trip-days.other", defaultValue: "\(stats.longestTripDays, format: .number.grouping(.never)) DAYS", comment: "Wrapped longest-trip duration badge for multiple days."))
                        .font(.subheadline.weight(.bold))
                        .tracking(3)
                        .foregroundStyle(WrappedDesign.baseBottom)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.orange, in: .capsule)
                        .wrappedPop(revealed, delay: WrappedMotion.stagger * 3)
                }

                // The card is the trip's name and its length.
            }
        }
    }
}

// MARK: - Card 4: Farthest Point

private struct FarthestCard: View {
    let stats: WrappedStats
    let index: Int
    let total: Int
    let revealed: Bool

    var body: some View {
        WrappedPage(kicker: String(localized: "wrapped.kicker.farthest-from-home", defaultValue: "Farthest from home", comment: "Wrapped farthest-place card kicker."), accent: .cyan,
                    motif: "paperplane.fill", index: index, total: total, revealed: revealed) {
            VStack(alignment: .leading, spacing: 20) {
                // Distances render through UnitsFormatter like every other
                // surface.
                WrappedHero(
                    value: stats.farthestDistanceKm,
                    unit: String(localized: "wrapped.farthest.from-home", defaultValue: "from home", comment: "Wrapped farthest-distance helper unit."),
                    revealed: revealed
                ) { UnitsFormatter.formatDistance(kilometers: $0) }
                if let place = stats.farthestPlaceName {
                    HStack(spacing: 8) {
                        Image(systemName: "location.north.line.fill")
                            .rotationEffect(.degrees(45))
                            .foregroundStyle(.cyan)
                        Text(place)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .wrappedRise(revealed, delay: WrappedMotion.stagger * 3)
                }
            }
        }
    }
}

// MARK: - Card 5: Weather Superlatives (extremes-safe; legacy artifacts: weatherCoverage >= 0.7)

private struct WeatherCard: View {
    let stats: WrappedStats
    let index: Int
    let total: Int
    let revealed: Bool

    private static let accent = Color(red: 1.0, green: 0.58, blue: 0.38)

    var body: some View {
        WrappedPage(kicker: String(localized: "wrapped.kicker.weather", defaultValue: "Your weather", comment: "Wrapped weather card kicker."), accent: Self.accent,
                    motif: "sun.max.fill", index: index, total: total, revealed: revealed) {
            VStack(alignment: .leading, spacing: 14) {
                // Temperatures render through UnitsFormatter like every other
                // surface.
                if let hot = stats.hottestTempC, let hotPlace = stats.hottestLocality {
                    superlative(icon: "thermometer.sun.fill", tint: Self.accent,
                                title: String(localized: "wrapped.weather.hottest", defaultValue: "Hottest", comment: "Wrapped weather superlative label for the hottest stay."),
                                value: UnitsFormatter.formatTemperature(hot), place: hotPlace, order: 0)
                }
                if let cold = stats.coldestTempC, let coldPlace = stats.coldestLocality {
                    superlative(icon: "thermometer.snowflake", tint: .cyan,
                                title: String(localized: "wrapped.weather.coldest", defaultValue: "Coldest", comment: "Wrapped weather superlative label for the coldest stay."),
                                value: UnitsFormatter.formatTemperature(cold), place: coldPlace, order: 1)
                }
                if let rainyTrip = stats.rainiestTripName,
                   let mm = stats.rainiestPrecipitationMm, mm > 0 {
                    superlative(icon: "cloud.heavyrain.fill", tint: .blue,
                                title: String(localized: "wrapped.weather.rainiest", defaultValue: "Rainiest", comment: "Wrapped weather superlative label for the rainiest trip."),
                                value: String(localized: "wrapped.weather.precipitation", defaultValue: "\(Int(mm), format: .number.grouping(.never)) mm", comment: "Wrapped precipitation value in millimetres."), place: rainyTrip, order: 2)
                }

                // Apple Weather attribution, gated like TripDetailView's.
                // The page is always navy, so force the dark-scheme mark
                // regardless of the system appearance.
                if hasAnySuperlative {
                    WeatherAttributionFootnote()
                        .environment(\.colorScheme, .dark)
                        .wrappedRise(revealed, delay: WrappedMotion.stagger * 5)
                }
            }
        }
    }

    private var hasAnySuperlative: Bool { WrappedView.weatherCardHasContent(stats: stats) }

    private func superlative(icon: String, tint: Color, title: String, value: String, place: String, order: Int) -> some View {
        WrappedPanel {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundStyle(tint)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased(with: AppLanguagePreference.currentLocale()))
                        .font(.caption2.weight(.semibold))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.55))
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(value)
                            .font(.system(.title, design: .rounded).weight(.heavy))
                            .foregroundStyle(.white)
                        Text(place)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }
            }
        }
        .wrappedRise(revealed, delay: WrappedMotion.stagger * Double(1 + order))
    }
}

// MARK: - Card 5 fallback: Cities (extremes not safe / low legacy coverage)

private struct TopDestinationsCard: View {
    let stats: WrappedStats
    let index: Int
    let total: Int
    let revealed: Bool

    var body: some View {
        WrappedPage(kicker: String(localized: "wrapped.kicker.cities", defaultValue: "Your cities", comment: "Wrapped cities card kicker."), accent: .mint,
                    motif: "building.2.fill", index: index, total: total, revealed: revealed) {
            WrappedHero(
                value: Double(stats.citiesVisited),
                unit: stats.citiesVisited == 1
                    ? String(localized: "wrapped.distinct-cities.one", defaultValue: "distinct city", comment: "Wrapped city-count unit for one distinct city.")
                    : String(localized: "wrapped.distinct-cities.other", defaultValue: "distinct cities", comment: "Wrapped city-count unit for multiple distinct cities."),
                revealed: revealed
            ) { Int($0.rounded()).formatted() }
        }
    }
}

// MARK: - Card 6: Transit Breakdown (any mode ≥ transitCardMinimumKm)

private struct TransitCard: View {
    let stats: WrappedStats
    let index: Int
    let total: Int
    let revealed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let accent = Color(red: 0.45, green: 0.72, blue: 1.0)

    private var maxKm: Double {
        max(stats.flightKm, stats.driveKm, stats.walkKm, 1)
    }

    var body: some View {
        WrappedPage(kicker: String(localized: "wrapped.kicker.how-you-moved", defaultValue: "How you moved", comment: "Wrapped transport card kicker."), accent: Self.accent,
                    motif: "airplane.departure", index: index, total: total, revealed: revealed) {
            let modes = visibleModes
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(modes.enumerated()), id: \.offset) { order, mode in
                    modeBar(icon: mode.icon, label: mode.label, km: mode.km, order: order)
                }

                if stats.totalGreatCircleKm > 0 {
                    let delay = WrappedMotion.stagger * Double(1 + modes.count)
                    VStack(alignment: .leading, spacing: 2) {
                        WrappedCountUp(target: stats.totalGreatCircleKm, revealed: revealed, delay: delay) {
                            UnitsFormatter.formatDistance(kilometers: $0)
                        }
                            .font(.system(size: 56, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        Text("IN TOTAL")
                            .font(.caption.weight(.semibold))
                            .tracking(3)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.top, 10)
                    .wrappedRise(revealed, delay: delay)
                }
            }
        }
    }

    private struct Mode {
        let icon: String
        let label: String
        let km: Double
    }

    private var visibleModes: [Mode] {
        var modes: [Mode] = []
        if stats.flightKm > 0 {
            modes.append(Mode(icon: "airplane", label: String(localized: "wrapped.transport.flown", defaultValue: "Flown", comment: "Wrapped transport label for distance flown."), km: stats.flightKm))
        }
        if stats.driveKm > 0 {
            modes.append(Mode(icon: "car.fill", label: String(localized: "wrapped.transport.driven", defaultValue: "Driven", comment: "Wrapped transport label for distance driven."), km: stats.driveKm))
        }
        if stats.walkKm > 0 {
            modes.append(Mode(icon: "figure.walk", label: String(localized: "wrapped.transport.walked", defaultValue: "Walked", comment: "Wrapped transport label for distance walked."), km: stats.walkKm))
        }
        return modes
    }

    /// Proportional bar — the eye compares lengths instantly. On reveal the
    /// fill grows from the leading edge while the figure counts up alongside
    /// it.
    private func modeBar(icon: String, label: String, km: Double, order: Int) -> some View {
        let delay = WrappedMotion.stagger * Double(1 + order)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(label, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                WrappedCountUp(target: km, revealed: revealed, delay: delay) {
                    UnitsFormatter.formatDistance(kilometers: $0)
                }
                    .font(.subheadline.weight(.heavy))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule()
                        .fill(Self.accent)
                        .frame(width: revealed ? max(geo.size.width * (km / maxKm), 8) : 0)
                        .animation(reduceMotion ? nil : WrappedMotion.grow.delay(delay), value: revealed)
                }
            }
            .frame(height: 8)
        }
        .wrappedRise(revealed, delay: delay)
    }
}

// MARK: - Card 6 fallback: Total Distance

private struct TotalDistanceCard: View {
    let stats: WrappedStats
    let index: Int
    let total: Int
    let revealed: Bool

    var body: some View {
        WrappedPage(kicker: String(localized: "wrapped.kicker.distance", defaultValue: "The distance", comment: "Wrapped total-distance card kicker."), accent: .indigo,
                    motif: "map.fill", index: index, total: total, revealed: revealed) {
            WrappedHero(
                value: stats.totalGreatCircleKm,
                unit: String(localized: "wrapped.distance.traveled", defaultValue: "traveled", comment: "Wrapped total-distance helper unit."),
                revealed: revealed
            ) { UnitsFormatter.formatDistance(kilometers: $0) }
        }
    }
}

// MARK: - Card 7: New Countries ("stamps")

private struct NewCountriesCard: View {
    let stats: WrappedStats
    let index: Int
    let total: Int
    let revealed: Bool

    private static let accent = Color(red: 1.0, green: 0.5, blue: 0.62)

    var body: some View {
        WrappedPage(kicker: String(localized: "wrapped.kicker.new-stamps", defaultValue: "New stamps", comment: "Wrapped new-countries card kicker."), accent: Self.accent,
                    motif: "seal.fill", index: index, total: total, revealed: revealed) {
            if stats.newCountryCodes.isEmpty {
                fallbackMostVisited
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    Text(stats.newCountryCodes.count == 1
                         ? String(localized: "wrapped.new-countries.one", defaultValue: "One new country\nin your passport", comment: "Wrapped new-country headline for one newly visited country.")
                         : String(localized: "wrapped.new-countries.other", defaultValue: "\(stats.newCountryCodes.count, format: .number.grouping(.never)) new countries\nin your passport", comment: "Wrapped new-country headline for multiple newly visited countries."))
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .wrappedRise(revealed, delay: WrappedMotion.stagger)

                    // Loose "passport stamp" grid: each flag in a tilted
                    // dashed seal, alternating lean. Stamps land one after
                    // another once the headline has settled.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 18) {
                        ForEach(Array(stats.newCountryCodes.prefix(9).enumerated()), id: \.offset) { position, code in
                            stamp(code: code, lean: position.isMultiple(of: 2) ? -5 : 4, order: position)
                        }
                    }
                }
            }
        }
    }

    private func stamp(code: String, lean: Double, order: Int) -> some View {
        VStack(spacing: 6) {
            Text(flagEmoji(for: code) ?? "🏳️")
                .font(.system(size: 44))
            Text(code)
                .font(.caption2.weight(.bold))
                .tracking(2)
                .foregroundStyle(Self.accent)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Self.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        )
        .wrappedStamp(revealed, lean: lean, delay: WrappedMotion.stagger * 3 + Double(order) * 0.16)
    }

    @ViewBuilder
    private var fallbackMostVisited: some View {
        if let code = stats.mostVisitedCountryCode {
            VStack(alignment: .leading, spacing: 16) {
                Text("No new stamps,\nbut one clear favorite")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .wrappedRise(revealed, delay: WrappedMotion.stagger)
                HStack(spacing: 14) {
                    Text(flagEmoji(for: code) ?? "🌍")
                        .font(.system(size: 64))
                        .wrappedStamp(revealed, lean: 0, delay: WrappedMotion.stagger * 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(localizedCountryName(iso: code, fallback: code) ?? code)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                        if stats.mostVisitedCountryTripCount > 0 {
                            Text(stats.mostVisitedCountryTripCount == 1
                                 ? String(localized: "wrapped.most-visited-country-trips.one", defaultValue: "\(stats.mostVisitedCountryTripCount, format: .number.grouping(.never)) trip this year", comment: "Wrapped most-visited-country count for one trip this year.")
                                 : String(localized: "wrapped.most-visited-country-trips.other", defaultValue: "\(stats.mostVisitedCountryTripCount, format: .number.grouping(.never)) trips this year", comment: "Wrapped most-visited-country count for multiple trips this year."))
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .wrappedRise(revealed, delay: WrappedMotion.stagger * 4)
                }
            }
        } else {
            Text("Every journey stayed\nclose to home this year")
                .font(.system(size: 32, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .wrappedRise(revealed, delay: WrappedMotion.stagger)
        }
    }
}

// MARK: - Card 8: Time Balance

private struct TimeBalanceCard: View {
    let stats: WrappedStats
    let index: Int
    let total: Int
    let revealed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let accent = Color(red: 0.4, green: 0.85, blue: 0.6)

    var body: some View {
        WrappedPage(kicker: String(localized: "wrapped.kicker.home-away", defaultValue: "Home & away", comment: "Wrapped home-and-away card kicker."), accent: Self.accent,
                    motif: "house.fill", index: index, total: total, revealed: revealed) {
            VStack(alignment: .leading, spacing: 28) {
                // Ring and counter share one curve and one delay so the
                // arc's tip and the number arrive together.
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.14), lineWidth: 18)
                    Circle()
                        .trim(from: 0, to: revealed ? abroadFraction : 0)
                        .stroke(Self.accent, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : WrappedMotion.grow.delay(WrappedMotion.stagger), value: revealed)
                    VStack(spacing: 2) {
                        WrappedCountUp(target: Double(stats.daysAbroad), revealed: revealed, delay: WrappedMotion.stagger) {
                            "\(Int($0.rounded()))"
                        }
                            .font(.system(size: 52, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                        Text("DAYS AWAY")
                            .font(.caption2.weight(.semibold))
                            .tracking(2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .frame(width: 210, height: 210)
                .frame(maxWidth: .infinity)
                .wrappedPop(revealed, delay: WrappedMotion.stagger)

                HStack(spacing: 28) {
                    legend(color: Self.accent, label: String(localized: "wrapped.balance.away", defaultValue: "Away", comment: "Wrapped time-balance legend label for days away."), days: stats.daysAbroad, order: 0)
                    legend(color: .white.opacity(0.35), label: String(localized: "wrapped.balance.home", defaultValue: "Home", comment: "Wrapped time-balance legend label for days at home."), days: stats.daysAtHome, order: 1)
                    Spacer()
                }
            }
        }
    }

    private var abroadFraction: Double {
        let total = stats.daysAbroad + stats.daysAtHome
        guard total > 0 else { return 0 }
        return Double(stats.daysAbroad) / Double(total)
    }

    private func legend(color: Color, label: String, days: Int, order: Int) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 0) {
                Text(label.uppercased(with: AppLanguagePreference.currentLocale()))
                    .font(.caption2.weight(.semibold))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.55))
                Text(days == 1
                     ? String(localized: "wrapped.balance.days.one", defaultValue: "\(days, format: .number.grouping(.never)) day", comment: "Wrapped time-balance legend value for one day.")
                     : String(localized: "wrapped.balance.days.other", defaultValue: "\(days, format: .number.grouping(.never)) days", comment: "Wrapped time-balance legend value for multiple days."))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
        }
        .wrappedRise(revealed, delay: WrappedMotion.stagger * Double(3 + order))
    }
}

// MARK: - Card 9: Mystery Fact

private struct MysteryCard: View {
    let stats: WrappedStats
    let index: Int
    let total: Int
    let revealed: Bool

    private static let accent = Color(red: 0.75, green: 0.6, blue: 1.0)

    var body: some View {
        WrappedPage(kicker: String(localized: "wrapped.kicker.one-last-thing", defaultValue: "One last thing", comment: "Wrapped mystery-fact card kicker."), accent: Self.accent,
                    motif: "sparkles", index: index, total: total, revealed: revealed) {
            Text(WrappedDisplayResolver.resolvedMysteryFact(
                stats: stats,
                locale: AppLanguagePreference.currentLocale()) ?? "")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .lineSpacing(4)
                .minimumScaleFactor(0.6)
                .wrappedRise(revealed, delay: WrappedMotion.stagger * 2)
        }
    }
}

// MARK: - Card 10: Year Narrative + Share

private struct YearNarrativeCard: View {
    let year: Int
    let resolvedNarrative: String?
    let stats: WrappedStats
    let appLocale: Locale
    let index: Int
    let total: Int
    let revealed: Bool

    var body: some View {
        WrappedPage(kicker: String(localized: "wrapped.kicker.year-in-words", defaultValue: "Your year, in words", comment: "Wrapped narrative card kicker."), accent: WrappedDesign.gold,
                    motif: "quote.opening", index: index, total: total, revealed: revealed) {
            VStack(alignment: .leading, spacing: 24) {
                Text(verbatim: String(year))
                    .font(.system(size: 64, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .wrappedRise(revealed, delay: WrappedMotion.stagger)

                Group {
                    if let narrative = resolvedNarrative, !narrative.isEmpty {
                        Text(narrative)
                            .font(.system(.body, design: .serif))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineSpacing(6)
                    } else {
                        Text("Your year in motion.")
                            .font(.system(.title2, design: .serif))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                }
                .wrappedRise(revealed, delay: WrappedMotion.stagger * 2)

                // The item carries only VALUE inputs; the 1080×1920 render
                // happens inside the payload's transfer representation when
                // the share sheet actually requests the PNG — paging through
                // Wrapped never pays it.
                ShareLink(
                    item: WrappedNarrativeShare(
                        year: year,
                        narrative: resolvedNarrative,
                        stats: stats,
                        appLocaleIdentifier: appLocale.identifier
                    ),
                    preview: SharePreview(String(localized: "wrapped.share-preview", defaultValue: "TravelLog \(year, format: .number.grouping(.never)) Wrapped", comment: "Share preview title for a Wrapped year; keep TravelLog verbatim."))
                ) {
                    shareButtonLabel
                }
                .wrappedPop(revealed, delay: WrappedMotion.stagger * 4)
            }
        }
    }

    private var shareButtonLabel: some View {
        Label("Share Your Year", systemImage: "square.and.arrow.up")
            .font(.headline.weight(.semibold))
            .foregroundStyle(WrappedDesign.baseBottom)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(WrappedDesign.gold, in: Capsule())
    }
}

/// Value-only, localized share input. Bitmap and PNG work starts only when the share
/// sheet requests it, on the renderer's detached task rather than the main actor.
nonisolated struct WrappedNarrativeShare: Transferable {
    let year: Int
    let content: WrappedShareRenderer.Content

    @MainActor
    init(year: Int, narrative: String?, stats: WrappedStats, appLocaleIdentifier: String) {
        self.year = year
        let locale = Locale(identifier: appLocaleIdentifier)
        let countryLabel = stats.countriesVisited == 1
            ? String(localized: "wrapped.share.country.one", defaultValue: "COUNTRY", locale: locale)
            : String(localized: "wrapped.share.country.other", defaultValue: "COUNTRIES", locale: locale)
        let cityLabel = stats.citiesVisited == 1
            ? String(localized: "wrapped.share.city.one", defaultValue: "CITY", locale: locale)
            : String(localized: "wrapped.share.city.other", defaultValue: "CITIES", locale: locale)
        let distanceLabel = stats.totalGreatCircleKm > 0
            ? String(localized: "wrapped.share.km", defaultValue: "KM", locale: locale)
            : String(localized: "wrapped.share.places", defaultValue: "PLACES", locale: locale)
        let distance = stats.totalGreatCircleKm > 0
            ? Int(stats.totalGreatCircleKm) : stats.totalHexesVisited
        func tile(_ value: Int, _ label: String) -> WrappedShareRenderer.Tile {
            .init(value: value.formatted(.number.locale(locale)),
                  label: label.uppercased(with: locale))
        }
        content = WrappedShareRenderer.Content(
            year: String(year),
            heading: String(localized: "WRAPPED", locale: locale),
            tiles: [
                tile(stats.countriesVisited, countryLabel),
                tile(stats.citiesVisited, cityLabel),
                tile(stats.totalDaysAbroad, String(localized: "wrapped.share.days-away", defaultValue: "DAYS AWAY", locale: locale)),
                tile(distance, distanceLabel),
            ],
            narrative: narrative.flatMap { $0.isEmpty ? nil : $0 }
                ?? String(localized: "Your year in motion.", locale: locale),
            branding: "TravelLog",
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
