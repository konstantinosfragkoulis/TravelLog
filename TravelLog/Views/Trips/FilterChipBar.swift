//
//  FilterChipBar.swift
//  TravelLog
//
//  Created by Konstantinos Fragkoulis on 22/5/26.
//

import SwiftUI

/// Horizontally-scrolling row of capsule chips that drives the Trips
/// tab's sort + filter UI. Rendered as the first List section of
/// `TripsListView` (`filterChipSection`), so it scrolls with the trips.
///
/// # Chip order (left → right)
///
/// 1. **Year**: neutral when empty, cobalt-filled when active. Tap opens
///    a sheet with quick-pick presets + a checklist.
/// 2. **Country**: same shape; sheet shows flag + name + trip count,
///    with a search field above 15 countries.
/// 3. **Duration**: three discrete buckets (Weekend / Week / Long).
/// 4. **Sort**: always a neutral chip with a chevron (sort is a
///    preference, not a filter); tap opens a `Menu` with the
///    `TripSortOrder` Picker. Single-select.
/// 5. **With Photos**: toggle pill, no sheet. Tap flips
///    `filters.requiresPhotos` immediately.
/// 6. **Clear filters** — only rendered when `filters.isActive`, on its OWN row
///    below the scroller: the reset affordance must be visible whatever
///    the horizontal scroll position. Tap clears every filter (NOT sort —
///    sort is a persistent preference, not a filter).
///
/// # Why no inline-X per chip
///
/// Apple's own apps (Maps, Photos, App Store) never put a tap target
/// inside a capsule chip — it fights iOS 26 Liquid Glass hit-testing
/// and the UX is fiddly. Instead: re-tap an active chip to modify;
/// long-press for a context menu that exposes "Clear" per chip; tap
/// the row-level "Clear filters" chip to reset everything at once.
struct FilterChipBar: View {

    @Binding var sortOrderRaw: String
    @Binding var filters: TripFilters

    /// Years that actually appear in the user's trips (newest first).
    /// Computed by the parent view from the `@Query` snapshot.
    let availableYears: [Int]

    /// Countries that appear in the user's trips, with frequency count
    /// (sorted by count desc, then alpha). Code → count map flattened
    /// so the picker can render rows in a predictable order without
    /// re-sorting.
    let availableCountries: [(code: String, count: Int)]

    /// Which sheet is currently presented. `nil` = no sheet. Single
    /// `@State` (rather than three `Bool`s) keeps the sheet-vs-sheet
    /// transitions sane and gives us free identity for `.sheet(item:)`.
    @State private var presentedSheet: FilterSheetKind?

    /// Identifier for the currently-presented sheet. `Identifiable`
    /// because `.sheet(item:)` requires it.
    private enum FilterSheetKind: String, Identifiable {
        case year, country, duration
        var id: String { rawValue }
    }

    /// Observes app-foreground transitions so we can snap the chip
    /// row's scroll position back to the leading edge on every
    /// .active transition (mirrors the .onAppear behaviour for the
    /// "user leaves/reenters Trips tab" case).
    @Environment(\.scenePhase) private var scenePhase

    /// Stable ID for the leftmost chip; used as the scrollTo anchor.
    private let leadingChipID = "chip-bar-leading-anchor"

    var body: some View {
        // No background or divider: the chip row sits on a clear List row
        // (`TripsListView.filterChipSection`).
        //
        // **ScrollViewReader wraps the ScrollView so we can
        // programmatically reset the horizontal scroll position to the
        // leading edge.** The reset fires on
        // .onAppear (TabView keeps child views alive across tab
        // switches but re-fires onAppear when the tab becomes
        // visible) and on scenePhase → .active (covers
        // background→foreground returns where onAppear wouldn't
        // re-fire). The filters themselves are unchanged — only the
        // scroll offset resets — so the user's persisted sort + chip
        // selections survive.
        VStack(spacing: 0) {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    yearChip
                        .id(leadingChipID)
                    countryChip
                    durationChip
                    sortChip
                    photosChip
                }
                // No `.padding(.horizontal, ...)` on the HStack. The chip
                // row's parent List row has `.listRowInsets(EdgeInsets())`
                // (full-width row), so the ScrollView spans the section's
                // content width. Letting chips sit flush against that
                // edge aligns the leftmost chip with the section-card
                // edge of the trip rows and the search-field capsule —
                // adding 16pt of HStack padding here pushed the chips 16pt
                // INSIDE the card edge, creating a visible inset
                // mismatch. Vertical padding remains for breathing room
                // around the capsules (each chip's 44 pt hit frame adds the rest).
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            .onAppear {
                // Snap to start when this view is mounted into the
                // hierarchy. In TabView this fires every time the user
                // navigates to the Trips tab from another tab (and
                // also on cold launch / first appear). No animation —
                // an instant snap is what "reset" feels like; an
                // animated scroll would be jarring on tab switch.
                proxy.scrollTo(leadingChipID, anchor: .leading)
            }
            .onChange(of: scenePhase) { _, newPhase in
                // Background → foreground: SwiftUI does NOT re-fire
                // .onAppear in this case (the view never left the
                // hierarchy), so we need an explicit observer.
                if newPhase == .active {
                    proxy.scrollTo(leadingChipID, anchor: .leading)
                }
            }
        }

        // Clear lives OUTSIDE the scroller so it can never be scrolled
        // out of view (doc comment #6 above).
        if filters.isActive {
            HStack {
                clearChip
                Spacer()
            }
            .padding(.bottom, 2)
        }
        }
        .sheet(item: $presentedSheet) { kind in
            switch kind {
            case .year:
                YearFilterPicker(filters: $filters, availableYears: availableYears)
            case .country:
                CountryFilterPicker(filters: $filters, availableCountries: availableCountries)
            case .duration:
                DurationFilterPicker(filters: $filters)
            }
        }
    }

    // MARK: - Sort

    /// The Sort chip is structurally a `Menu` (single-select dropdown),
    /// not a sheet — it matches Apple Files / Mail / Photos and gives
    /// the user a one-tap pick instead of an extra sheet dismissal.
    /// Neutral, with a chevron: sort always has a value (you can't
    /// "clear" sort — it falls back to `dateNewest`), so accent would
    /// read as a filter that is always on.
    private var sortChip: some View {
        Menu {
            Picker("Sort", selection: $sortOrderRaw) {
                ForEach(TripSortOrder.allCases) { order in
                    Label(order.label, systemImage: order.systemImage)
                        .tag(order.rawValue)
                }
            }
        } label: {
            // "Sort" alone on the default order; another order names itself.
            FilterChipLabel(
                label: currentSortOrder == .dateNewest ? Text("Sort") : Text("Sort: \(currentSortOrder.shortLabel)"),
                isSelected: false,
                showsChevron: true)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
    }

    private var currentSortOrder: TripSortOrder {
        TripSortOrder(rawValue: sortOrderRaw) ?? .dateNewest
    }

    // MARK: - Year

    private var yearChip: some View {
        chipButton(
            isActive: !filters.years.isEmpty,
            label: yearChipLabel,
            action: { presentedSheet = .year }
        )
        .contextMenu {
            if !filters.years.isEmpty {
                Button(role: .destructive) {
                    filters.years.removeAll()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
            }
        }
    }

    private var yearChipLabel: String {
        switch filters.years.count {
        case 0:
            String(localized: "trip-filter.chip.year", defaultValue: "Year", comment: "Inactive year filter chip label.")
        case 1:
            String(localized: "trip-filter.chip.year.value", defaultValue: "Year: \(filters.years.first!, format: .number.grouping(.never))", comment: "Year filter chip showing its one selected year.")
        default:
            String(localized: "trip-filter.chip.year.count", defaultValue: "Year: \(filters.years.count, format: .number.grouping(.never))", comment: "Year filter chip showing the number of selected years.")
        }
    }

    // MARK: - Country

    private var countryChip: some View {
        chipButton(
            isActive: !filters.countryCodes.isEmpty,
            label: countryChipLabel,
            action: { presentedSheet = .country }
        )
        .contextMenu {
            if !filters.countryCodes.isEmpty {
                Button(role: .destructive) {
                    filters.countryCodes.removeAll()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
            }
        }
    }

    private var countryChipLabel: String {
        switch filters.countryCodes.count {
        case 0:
            return String(localized: "trip-filter.chip.country", defaultValue: "Country", comment: "Inactive country filter chip label.")
        case 1:
            let code = filters.countryCodes.first!
            let name = AppLanguagePreference.currentLocale()
                .localizedString(forRegionCode: code) ?? code
            return String(localized: "trip-filter.chip.country.value", defaultValue: "Country: \(name)", comment: "Country filter chip showing its one selected country.")
        default:
            return String(localized: "trip-filter.chip.country.count", defaultValue: "Country: \(filters.countryCodes.count, format: .number.grouping(.never))", comment: "Country filter chip showing the number of selected countries.")
        }
    }

    // MARK: - Duration

    private var durationChip: some View {
        chipButton(
            isActive: !filters.durations.isEmpty,
            label: durationChipLabel,
            action: { presentedSheet = .duration }
        )
        .contextMenu {
            if !filters.durations.isEmpty {
                Button(role: .destructive) {
                    filters.durations.removeAll()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
            }
        }
    }

    private var durationChipLabel: String {
        switch filters.durations.count {
        case 0:
            String(localized: "trip-filter.chip.duration", defaultValue: "Duration", comment: "Inactive duration filter chip label.")
        case 1:
            String(localized: "trip-filter.chip.duration.value", defaultValue: "Duration: \(filters.durations.first!.shortLabel)", comment: "Duration filter chip showing its one selected duration bucket.")
        default:
            String(localized: "trip-filter.chip.duration.count", defaultValue: "Duration: \(filters.durations.count, format: .number.grouping(.never))", comment: "Duration filter chip showing the number of selected duration buckets.")
        }
    }

    // MARK: - With Photos

    /// The photos chip is a one-tap toggle (no sheet) — binary state
    /// doesn't justify a picker. Tap flips `filters.requiresPhotos`;
    /// long-press is the same context-menu "Clear" affordance for
    /// consistency.
    private var photosChip: some View {
        chipButton(
            isActive: filters.requiresPhotos,
            label: String(localized: "trip-filter.chip.with-photos", defaultValue: "With Photos", comment: "Trip filter chip that requires matching trips to have photos."),
            action: { filters.requiresPhotos.toggle() }
        )
        .contextMenu {
            if filters.requiresPhotos {
                Button(role: .destructive) {
                    filters.requiresPhotos = false
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
            }
        }
    }

    // MARK: - Clear (all)

    /// Resets every filter dimension to default. Does NOT touch
    /// `sortOrderRaw` — sort is a persistent preference, not a filter
    /// (clearing it would mean "reset to dateNewest", which is more
    /// surprising than helpful).
    private var clearChip: some View {
        Button(role: .destructive) {
            filters = TripFilters()
        } label: {
            AppChip(
                label: Text(String(localized: "trip-filter.chip.clear-filters", defaultValue: "Clear filters", comment: "Button that clears all trip filters while preserving search text and sort order.")),
                systemImage: "xmark")
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Reusable chip

    /// Neutral ↔ accent-filled chip depending on `isActive` (the
    /// `AppChip` vocabulary). Used by all filter chips (sort + clear
    /// handle their own semantics). Borderless, so the chip's own
    /// capsule is the only fill and each chip keeps its own tap target.
    private func chipButton(
        isActive: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            FilterChipLabel(
                label: Text(label),
                isSelected: isActive,
                showsChevron: !isActive)
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// The filter row's chip: a 32 pt capsule on the neutral fill with a small
/// trailing chevron for a chip that opens a picker; solid cobalt under
/// white text once it filters.
struct FilterChipLabel: View {
    let label: Text
    let isSelected: Bool
    let showsChevron: Bool

    var body: some View {
        HStack(spacing: 5) {
            label
                .font(.subheadline.weight(.medium))
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.secondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 11)
        .frame(minHeight: 32)
        // Plain colours, not hierarchical styles: a borderless button or a
        // menu label resolves `.primary` to the accent tint.
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(isSelected ? AnyShapeStyle(AppTheme.cobaltFill) : AnyShapeStyle(AppTheme.inset), in: .capsule)
        // A 44 pt tall hit area around the visible capsule.
        .frame(minHeight: 44)
        .contentShape(.rect)
    }
}

// MARK: - Year Picker Sheet

/// Year-filter sheet. Quick-pick presets (Last year / Last 3 / Last 5)
/// at the top, then a scrollable list of the years that actually appear
/// in the user's trips (newest first) with checkmark selection.
///
/// **No range slider** even though years are numeric — research showed
/// range sliders for discrete categorical data are an anti-pattern
/// (Letterboxd, Day One, Apple Photos all use discrete pickers).
struct YearFilterPicker: View {

    @Binding var filters: TripFilters
    let availableYears: [Int]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !availableYears.isEmpty {
                    presetSection
                    yearListSection
                } else {
                    Section {
                        Text("You don't have any trips yet to filter by year.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Filter by Year")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        filters.years.removeAll()
                    }
                    .disabled(filters.years.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var presetSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    presetChip(String(localized: "trip-filter.year-preset.last-year", defaultValue: "Last year", comment: "Year filter preset for the calendar year before the current year."), years: Self.presetYears(count: 1, now: .now, calendar: TripFilters.yearCalendar))
                    presetChip(String(localized: "trip-filter.year-preset.last-three-years", defaultValue: "Last 3 years", comment: "Year filter preset for the current calendar year and the two preceding years."), years: Self.presetYears(count: 3, now: .now, calendar: TripFilters.yearCalendar))
                    presetChip(String(localized: "trip-filter.year-preset.last-five-years", defaultValue: "Last 5 years", comment: "Year filter preset for the current calendar year and the four preceding years."), years: Self.presetYears(count: 5, now: .now, calendar: TripFilters.yearCalendar))
                }
                .padding(.vertical, 4)
            }
            .scrollClipDisabled()
            .listRowInsets(.init(top: 4, leading: 16, bottom: 4, trailing: 16))
        } header: {
            Text("Quick picks")
        }
    }

    @ViewBuilder
    private func presetChip(_ label: String, years: Set<Int>) -> some View {
        let isExactMatch = !years.isEmpty && filters.years == years
        Button {
            filters.years = years
        } label: {
            Text(label)
                .font(.subheadline.weight(.medium))
        }
        .buttonStyle(isExactMatch ? AnyChipStyle.prominent : AnyChipStyle.outlined)
    }

    private var yearListSection: some View {
        Section {
            ForEach(availableYears, id: \.self) { year in
                Button {
                    toggleYear(year)
                } label: {
                    HStack {
                        Text(year.formatted(.number.grouping(.never)))
                            .foregroundStyle(.primary)
                        Spacer()
                        if filters.years.contains(year) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
        } header: {
            Text(filters.years.count == 1
                 ? String(localized: "trip-filter.selection.one", defaultValue: "\(filters.years.count, format: .number.grouping(.never)) of \(availableYears.count, format: .number.grouping(.never)) selected", comment: "Filter picker header when one option is selected out of the available total.")
                 : String(localized: "trip-filter.selection.other", defaultValue: "\(filters.years.count, format: .number.grouping(.never)) of \(availableYears.count, format: .number.grouping(.never)) selected", comment: "Filter picker header when zero or multiple options are selected out of the available total."))
        } footer: {
            Text("Trips are matched against the year they started.")
        }
    }

    static func presetYears(count: Int, now: Date, calendar: Calendar) -> Set<Int> {
        let currentYear = calendar.component(.year, from: now)
        if count == 1 { return [currentYear - 1] }
        return Set((0..<count).map { currentYear - $0 })
    }

    private func toggleYear(_ year: Int) {
        if filters.years.contains(year) {
            filters.years.remove(year)
        } else {
            filters.years.insert(year)
        }
    }
}

// MARK: - Country Picker Sheet

/// Country-filter sheet. List of countries that appear in the user's
/// trips, sorted by frequency (most-visited first). Each row shows
/// flag emoji + localised country name + trip count + checkmark.
///
/// A `.searchable` field shows above the list only when there are
/// 15+ countries — below that, scanning is faster than searching.
struct CountryFilterPicker: View {

    @Binding var filters: TripFilters
    let availableCountries: [(code: String, count: Int)]

    @Environment(\.dismiss) private var dismiss
    @State private var searchQuery: String = ""
    @State private var indexMemo = SearchMemo<ListSearchKey<String>, ListSearchIndex<String>>()

    /// Same country search as Earlier Travels, one index per list.
    private var filteredCountries: [(code: String, count: Int)] {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return availableCountries }
        let codes = availableCountries.map(\.code)
        let languageTag = AppLanguagePreference.currentTag()
        let index = indexMemo.value(for: ListSearchKey(entries: codes, languageTag: languageTag)) {
            RememberedCountriesPicker.searchIndex(codes: codes, languageTag: languageTag)
        }
        let matches = Set(index.matching(searchQuery))
        return availableCountries.filter { matches.contains($0.code) }
    }

    var body: some View {
        NavigationStack {
            List {
                if availableCountries.isEmpty {
                    Section {
                        Text("You don't have any trips yet to filter by country.")
                            .foregroundStyle(.secondary)
                    }
                } else if filteredCountries.isEmpty {
                    Section {
                        Text("No countries match \"\(searchQuery)\".")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(filteredCountries, id: \.code) { entry in
                            row(for: entry)
                        }
                    } header: {
                        Text(filters.countryCodes.count == 1
                             ? String(localized: "trip-filter.selection.one", defaultValue: "\(filters.countryCodes.count, format: .number.grouping(.never)) of \(availableCountries.count, format: .number.grouping(.never)) selected", comment: "Filter picker header when one option is selected out of the available total.")
                             : String(localized: "trip-filter.selection.other", defaultValue: "\(filters.countryCodes.count, format: .number.grouping(.never)) of \(availableCountries.count, format: .number.grouping(.never)) selected", comment: "Filter picker header when zero or multiple options are selected out of the available total."))
                    } footer: {
                        Text("Trips are matched against any of their destination countries (transit excluded).")
                    }
                }
            }
            .navigationTitle("Filter by Country")
            .navigationBarTitleDisplayMode(.inline)
            .modifier(ConditionalSearchable(isPresent: availableCountries.count >= 15, text: $searchQuery))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        filters.countryCodes.removeAll()
                    }
                    .disabled(filters.countryCodes.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private func row(for entry: (code: String, count: Int)) -> some View {
        let isSelected = filters.countryCodes.contains(entry.code)
        Button {
            if isSelected {
                filters.countryCodes.remove(entry.code)
            } else {
                filters.countryCodes.insert(entry.code)
            }
        } label: {
            HStack {
                FlagView(iso: entry.code, size: .regular)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppLanguagePreference.currentLocale()
                        .localizedString(forRegionCode: entry.code) ?? entry.code)
                        .foregroundStyle(.primary)
                    Text(entry.count == 1
                         ? String(localized: "trip-filter.country.trip-count.one", defaultValue: "\(entry.count, format: .number.grouping(.never)) trip", comment: "Country filter row trip count for one trip.")
                         : String(localized: "trip-filter.country.trip-count.other", defaultValue: "\(entry.count, format: .number.grouping(.never)) trips", comment: "Country filter row trip count for multiple trips."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Duration Picker Sheet

/// Duration-filter sheet. Three discrete buckets — Weekend, Week, Long
/// — with descriptions. Multi-select; an empty selection = "any
/// duration".
struct DurationFilterPicker: View {

    @Binding var filters: TripFilters

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(DurationBucket.allCases) { bucket in
                        row(for: bucket)
                    }
                } footer: {
                    Text("Ongoing trips don't match any duration bucket. Clear the filter to see them.")
                }
            }
            .navigationTitle("Filter by Duration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        filters.durations.removeAll()
                    }
                    .disabled(filters.durations.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private func row(for bucket: DurationBucket) -> some View {
        let isSelected = filters.durations.contains(bucket)
        Button {
            if isSelected {
                filters.durations.remove(bucket)
            } else {
                filters.durations.insert(bucket)
            }
        } label: {
            HStack {
                Text(bucket.label)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Helpers

/// `.buttonStyle` can't be selected at runtime via `if/else` without
/// duplicating the `Button` view (which we do elsewhere). For the
/// preset chips in `YearFilterPicker`, we have a self-contained
/// "pick one of two styles" need; this tiny static enum keeps the
/// preset code compact. Marked as a non-generic enum so it doesn't
/// leak generic constraints into the call sites.
private enum AnyChipStyle {
    case prominent, outlined
}

private extension View {
    @ViewBuilder
    func buttonStyle(_ style: AnyChipStyle) -> some View {
        switch style {
        case .prominent:
            self.buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        case .outlined:
            self.buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        }
    }
}

/// Conditionally applies `.searchable`. SwiftUI's `.searchable` always
/// reserves space for the search field, so we only attach it when the
/// list is long enough to need search. Below 15 items, scanning is
/// faster than typing.
private struct ConditionalSearchable: ViewModifier {
    let isPresent: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if isPresent {
            content.searchable(text: $text, prompt: Text("Search countries"))
        } else {
            content
        }
    }
}
