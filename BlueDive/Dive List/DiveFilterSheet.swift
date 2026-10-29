import SwiftUI

// MARK: - Marine Life Filter Mode

enum FilterMarineLifeMode: String, CaseIterable {
    case any = "any"
    case all = "all"
}

// MARK: - Marine Life Filter Helper

/// Returns true if `dive` satisfies the given marine life filter.
/// Extracted here so ContentView and DiveMapView share a single implementation.
func diveMatchesMarineLifeFilter(_ dive: Dive, species: [String], mode: FilterMarineLifeMode) -> Bool {
    guard !species.isEmpty else { return true }
    let fishNames = (dive.seenFish ?? []).map { $0.name }
    switch mode {
    case .any:
        return species.contains { s in fishNames.contains { $0.lowercased() == s.lowercased() } }
    case .all:
        return species.allSatisfy { s in fishNames.contains { $0.lowercased() == s.lowercased() } }
    }
}

// MARK: - Dive Filter Sheet

struct DiveFilterSheet: View {
    let availableYears: [Int]
    let availableGasTypes: [String]
    let availableCountries: [String]
    let availableDiveTypes: [String]
    let availableTags: [String]
    let availableMarineLife: [String]
    var showSort: Bool = true

    @Binding var filterYear: Int?
    @Binding var filterYearNegate: Bool
    @Binding var filterGasType: String?
    @Binding var filterGasTypeNegate: Bool
    @Binding var filterMinDepth: Double
    @Binding var filterMaxDepth: Double
    @Binding var filterMinRating: Int
    @Binding var filterCountry: String?
    @Binding var filterCountryNegate: Bool
    @Binding var filterDiveType: String?
    @Binding var filterDiveTypeNegate: Bool
    @Binding var filterTag: String?
    @Binding var filterTagNegate: Bool
    @Binding var filterMarineLife: [String]
    @Binding var filterMarineLifeMode: FilterMarineLifeMode
    @Binding var sortOrder: DiveSortOrder

    @Environment(\.dismiss) private var dismiss
    private let prefs = UserPreferences.shared

    @State private var marineLifeInput: String = ""
    @State private var minDepthText: String = ""
    @State private var maxDepthText: String = ""

    private var activeFilterCount: Int {
        var count = 0
        if filterYear != nil { count += 1 }
        if filterGasType != nil { count += 1 }
        if filterMinDepth > 0 || filterMaxDepth > 0 { count += 1 }
        if filterMinRating > 0 { count += 1 }
        if filterCountry != nil { count += 1 }
        if filterDiveType != nil { count += 1 }
        if filterTag != nil { count += 1 }
        if !filterMarineLife.isEmpty { count += 1 }
        return count
    }

    private var marineLifeSuggestions: [String] {
        guard !marineLifeInput.isEmpty else { return [] }
        let selected = Set(filterMarineLife.map { $0.lowercased() })
        return availableMarineLife.filter {
            $0.localizedCaseInsensitiveContains(marineLifeInput) &&
            !selected.contains($0.lowercased())
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    resetSection
                    if showSort {
                        sortSection
                    }
                    filterSections
                }
                .padding()
            }
            .background(AppBackground().ignoresSafeArea())
            .navigationTitle(showSort ? NSLocalizedString("Filters & Sort", bundle: Bundle.forAppLanguage(), comment: "Title of the filter and sort sheet") : NSLocalizedString("Filters", bundle: Bundle.forAppLanguage(), comment: "Title of the filter sheet without sort"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar { toolbarContent }
            .onChange(of: filterMarineLife) { _, newValue in
                if newValue.count <= 1 {
                    filterMarineLifeMode = .any
                }
            }
        }
    }
    
    // MARK: - Chip Rows

    /// A row of chips (the marine life selection and suggestions). iOS: one line that
    /// scrolls sideways. macOS: the chips wrap onto as many lines as needed — scrolling a
    /// row sideways needs a trackpad swipe or Shift-scroll with a mouse.
    @ViewBuilder
    private func chipRow<Content: View>(spacing: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        #if os(macOS)
        WrappingChipLayout(spacing: spacing) {
            content()
        }
        .padding(.horizontal, 4)
        #else
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                content()
            }
            .padding(.horizontal, 4)
        }
        #endif
    }

    // MARK: - Choice Filters

    /// Year, Country, Dive type, Tags and Gas type: single-choice filters shown as the rows
    /// of one card, like a Settings list — icon and name leading, the current value trailing
    /// as a menu, with its Include/Exclude control underneath once a value is set. Each row
    /// stays short however many values the logbook holds, and every current choice is
    /// visible at a glance.
    private var choiceFiltersCard: some View {
        VStack(spacing: 0) {
            FilterChoiceRow(
                Text("Year"),
                icon: "calendar",
                value: filterYear.map { "\($0)" },
                color: .cyan,
                selection: Binding(
                    get: { filterYear },
                    set: { newValue in
                        withAnimation {
                            filterYear = newValue
                            if newValue == nil { filterYearNegate = false }
                        }
                    }
                ),
                negate: $filterYearNegate,
                hasValue: filterYear != nil
            ) {
                Text(NSLocalizedString("All", bundle: Bundle.forAppLanguage(), comment: "Filter menu option for selecting all items"))
                    .tag(Int?.none)
                ForEach(availableYears, id: \.self) { year in
                    Text(verbatim: "\(year)").tag(Int?.some(year))
                }
            }

            if !availableCountries.isEmpty {
                Divider()
                FilterChoiceRow(
                    Text("Country"),
                    icon: "globe",
                    value: choiceLabel(filterCountry, none: NSLocalizedString("None", bundle: Bundle.forAppLanguage(), comment: "Filter option to show dives with no country set")),
                    color: .blue,
                    selection: choiceSelection($filterCountry, negate: $filterCountryNegate),
                    negate: $filterCountryNegate,
                    hasValue: filterCountry?.isEmpty == false
                ) {
                    Text(NSLocalizedString("All", bundle: Bundle.forAppLanguage(), comment: "Filter menu option for selecting all items"))
                        .tag(String?.none)
                    Text(NSLocalizedString("None", bundle: Bundle.forAppLanguage(), comment: "Filter option to show dives with no country set"))
                        .tag(String?.some(""))
                    ForEach(availableCountries, id: \.self) { country in
                        Text(verbatim: country).tag(String?.some(country))
                    }
                }
            }

            if !availableDiveTypes.isEmpty {
                Divider()
                FilterChoiceRow(
                    Text("Dive type"),
                    icon: "figure.open.water.swim",
                    value: choiceLabel(filterDiveType, none: NSLocalizedString("None", bundle: Bundle.forAppLanguage(), comment: "Filter option to show dives with no dive type set")),
                    color: .purple,
                    selection: choiceSelection($filterDiveType, negate: $filterDiveTypeNegate),
                    negate: $filterDiveTypeNegate,
                    hasValue: filterDiveType?.isEmpty == false
                ) {
                    Text(NSLocalizedString("All", bundle: Bundle.forAppLanguage(), comment: "Filter menu option for selecting all items"))
                        .tag(String?.none)
                    Text(NSLocalizedString("None", bundle: Bundle.forAppLanguage(), comment: "Filter option to show dives with no dive type set"))
                        .tag(String?.some(""))
                    ForEach(availableDiveTypes, id: \.self) { diveType in
                        Text(verbatim: diveType).tag(String?.some(diveType))
                    }
                }
            }

            if !availableTags.isEmpty {
                Divider()
                FilterChoiceRow(
                    Text("Tags"),
                    icon: "tag.fill",
                    value: choiceLabel(filterTag, none: NSLocalizedString("None", bundle: Bundle.forAppLanguage(), comment: "Filter option to show dives with no tag set")),
                    color: .pink,
                    selection: choiceSelection($filterTag, negate: $filterTagNegate),
                    negate: $filterTagNegate,
                    hasValue: filterTag?.isEmpty == false
                ) {
                    Text(NSLocalizedString("All", bundle: Bundle.forAppLanguage(), comment: "Filter menu option for selecting all items"))
                        .tag(String?.none)
                    Text(NSLocalizedString("None", bundle: Bundle.forAppLanguage(), comment: "Filter option to show dives with no tag set"))
                        .tag(String?.some(""))
                    ForEach(availableTags, id: \.self) { tag in
                        Text(verbatim: tag).tag(String?.some(tag))
                    }
                }
            }

            if !availableGasTypes.isEmpty {
                Divider()
                FilterChoiceRow(
                    Text("Gas type"),
                    icon: "bubbles.and.sparkles",
                    value: choiceLabel(filterGasType.map { $0.isEmpty ? $0 : DiveSummary.localizedGasName($0) }, none: NSLocalizedString("None", bundle: Bundle.forAppLanguage(), comment: "Filter option to show dives with no gas type set")),
                    color: .green,
                    selection: choiceSelection($filterGasType, negate: $filterGasTypeNegate),
                    negate: $filterGasTypeNegate,
                    hasValue: filterGasType?.isEmpty == false
                ) {
                    Text(NSLocalizedString("All", bundle: Bundle.forAppLanguage(), comment: "Filter menu option for selecting all items"))
                        .tag(String?.none)
                    Text(NSLocalizedString("None", bundle: Bundle.forAppLanguage(), comment: "Filter option to show dives with no gas type set"))
                        .tag(String?.some(""))
                    ForEach(availableGasTypes, id: \.self) { gas in
                        Text(verbatim: DiveSummary.localizedGasName(gas)).tag(String?.some(gas))
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .filterCardBackground()
    }

    /// Label of a String filter's value: nil for "All", `none` for "None" (""), else the value.
    private func choiceLabel(_ value: String?, none: String) -> String? {
        guard let value else { return nil }
        return value.isEmpty ? none : value
    }

    /// Selection for a single-choice filter with an Include/Exclude mode: choosing "All"
    /// (nil) or "None" ("") also returns the mode to Include, as the chips did.
    private func choiceSelection(_ value: Binding<String?>, negate: Binding<Bool>) -> Binding<String?> {
        Binding(
            get: { value.wrappedValue },
            set: { newValue in
                withAnimation {
                    value.wrappedValue = newValue
                    if newValue == nil || newValue == "" {
                        negate.wrappedValue = false
                    }
                }
            }
        )
    }

    // MARK: - Sections
    
    private var sortSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterSectionHeader(title: "Sort", icon: "arrow.up.arrow.down")

            #if os(macOS)
            // The Mac sheet is wide: the four sort rows in two columns
            // (Date | Depth, Duration | Dive #), same spacing as the iOS list.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(DiveSortField.allCases) { field in
                    SortFieldRow(field: field, sortOrder: $sortOrder)
                }
            }
            #else
            VStack(spacing: 8) {
                ForEach(DiveSortField.allCases) { field in
                    SortFieldRow(field: field, sortOrder: $sortOrder)
                }
            }
            #endif
        }
        .filterCardStyle()
    }

    @ViewBuilder
    private var filterSections: some View {
        choiceFiltersCard

        if !availableMarineLife.isEmpty {
            marineLifeFilterSection
        }

        #if os(macOS)
        // The Mac sheet is wide enough to pair the two short cards; fixedSize gives
        // both the height of the taller one.
        HStack(alignment: .top, spacing: 20) {
            depthFilterSection
                .frame(maxWidth: .infinity)
            ratingFilterSection
                .frame(maxWidth: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
        #else
        depthFilterSection
        ratingFilterSection
        #endif
    }
    
    private var marineLifeFilterSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "fish.fill")
                    .font(.title3)
                    .foregroundStyle(.cyan)
                Text(NSLocalizedString("Marine life", bundle: Bundle.forAppLanguage(), comment: "Filter section header for marine life search in the filter sheet"))
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                if filterMarineLife.count > 1 {
                    Picker("", selection: $filterMarineLifeMode) {
                        Text(NSLocalizedString("OR", bundle: Bundle.forAppLanguage(), comment: "Marine life filter mode: match any selected species")).tag(FilterMarineLifeMode.any)
                        Text(NSLocalizedString("AND", bundle: Bundle.forAppLanguage(), comment: "Marine life filter mode: match all selected species")).tag(FilterMarineLifeMode.all)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 110)
                }
            }
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 8) {
                if !filterMarineLife.isEmpty {
                    chipRow(spacing: 8) {
                        ForEach(filterMarineLife, id: \.self) { species in
                            HStack(spacing: 4) {
                                Text(species)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Button {
                                    withAnimation {
                                        filterMarineLife.removeAll { $0 == species }
                                    }
                                } label: {
                                    // Chip: 10 pt horizontal / 6 pt vertical padding, 8 pt
                                    // between chips. Grows 4 pt into the inter-chip gap
                                    // (half of 8) and 8 pt above/below the chip, which stays
                                    // clear of the 16 pt gap to the header picker and the
                                    // 8 pt gap to the search field. 34 × 42 pt.
                                    // No .foregroundStyle: inherits the chip's own tint.
                                    TapTargetInset(top: 14, leading: 6, bottom: 14, trailing: 14) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(verbatim: String(format: NSLocalizedString("Remove %@", bundle: .forAppLanguage(), comment: "Accessibility label for a button that removes a filter chip, naming the specific value it removes"), species)))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.teal.opacity(0.2)))
                            .overlay(Capsule().stroke(Color.teal, lineWidth: 1.5))
                            .foregroundStyle(.teal)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    TextField(NSLocalizedString("Add marine life…", bundle: Bundle.forAppLanguage(), comment: "Placeholder for marine life filter input"), text: $marineLifeInput)
                        .textFieldStyle(.plain)
                        .onSubmit { addMarineLifeFromInput() }
                    if !marineLifeInput.isEmpty {
                        Button {
                            withAnimation { marineLifeInput = "" }
                        } label: {
                            ClearButtonGlyph()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                .background(Color.platformSecondaryBackground)
                .cornerRadius(12)

                if !marineLifeSuggestions.isEmpty {
                    chipRow(spacing: 8) {
                        ForEach(marineLifeSuggestions.prefix(8), id: \.self) { suggestion in
                            Button {
                                withAnimation {
                                    if !filterMarineLife.contains(where: { $0.lowercased() == suggestion.lowercased() }) {
                                        filterMarineLife.append(suggestion)
                                    }
                                    marineLifeInput = ""
                                }
                            } label: {
                                Text(suggestion)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(Color.teal.opacity(0.15)))
                                    .foregroundStyle(.teal)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if marineLifeSuggestions.count > 8 {
                        Text(String(format: NSLocalizedString("and %lld more…", bundle: Bundle.forAppLanguage(), comment: "Hint shown below marine life suggestions when more than 8 results match"), marineLifeSuggestions.count - 8))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                }
            }
        }
        .filterCardStyle()
    }

    private func addMarineLifeFromInput() {
        let trimmed = marineLifeInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Only add if it exactly matches (case-insensitive) a known species,
        // using the canonical casing from the list so filter matching stays exact.
        if let canonical = availableMarineLife.first(where: { $0.lowercased() == trimmed.lowercased() }) {
            if !filterMarineLife.contains(where: { $0.lowercased() == canonical.lowercased() }) {
                filterMarineLife.append(canonical)
            }
        }
        marineLifeInput = ""
    }

    private var isDepthRangeInverted: Bool {
        filterMinDepth > 0 && filterMaxDepth > 0 && filterMinDepth > filterMaxDepth
    }

    private var depthStatusText: String {
        let unit = prefs.depthUnit.symbol
        let hasMin = filterMinDepth > 0
        let hasMax = filterMaxDepth > 0
        switch (hasMin, hasMax) {
        case (true, true):
            let lo = Swift.min(filterMinDepth, filterMaxDepth)
            let hi = Swift.max(filterMinDepth, filterMaxDepth)
            return "\(lo.localizedString(decimals: 1)) – \(hi.localizedString(decimals: 1)) \(unit)"
        case (true, false):
            return "≥ \(filterMinDepth.localizedString(decimals: 1)) \(unit)"
        case (false, true):
            return "≤ \(filterMaxDepth.localizedString(decimals: 1)) \(unit)"
        default:
            return ""
        }
    }

    private func commitDepthFields() {
        let parsedMin = parseFlexibleDouble(minDepthText) ?? 0
        let parsedMax = parseFlexibleDouble(maxDepthText) ?? 0
        // If both are set and inverted, swap them so the range is always lo–hi
        if parsedMin > 0, parsedMax > 0, parsedMin > parsedMax {
            filterMinDepth = parsedMax
            filterMaxDepth = parsedMin
            minDepthText   = parsedMax.editableString(decimals: 1)
            maxDepthText   = parsedMin.editableString(decimals: 1)
        } else {
            filterMinDepth = parsedMin
            filterMaxDepth = parsedMax
        }
    }

    private var depthFilterSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterSectionHeader(title: "Depth range", icon: "arrow.down.to.line")

            VStack(spacing: 12) {
                // Status / clear row
                HStack {
                    if (filterMinDepth > 0 || filterMaxDepth > 0) && !isDepthRangeInverted {
                        Text(verbatim: depthStatusText)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.cyan)
                    } else {
                        Text("All depths")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if filterMinDepth > 0 || filterMaxDepth > 0 {
                        Button {
                            withAnimation {
                                filterMinDepth = 0
                                filterMaxDepth = 0
                                minDepthText   = ""
                                maxDepthText   = ""
                            }
                        } label: {
                            // Sits after a Spacer in the status row: 16 pt of card padding
                            // trailing, empty Spacer leading, 12 pt to the section header above
                            // and to the min/max row below (whose fields add 8 pt of their own
                            // padding). 44 × 44 pt.
                            TapTargetInset(top: 12, leading: 12, bottom: 12, trailing: 12) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Clear"))
                    }
                }

                // Inverted range warning
                if isDepthRangeInverted {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Min. must be less than Max.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Text("Values will be swapped automatically on confirm.")
                                .font(.caption2)
                                .foregroundStyle(.orange.opacity(0.75))
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .leading)))
                }

                // Min / Max input row
                HStack(spacing: 12) {
                    // Min field
                    HStack(spacing: 6) {
                        Text("Min.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        TextField("–", text: $minDepthText)
                            .textFieldStyle(.plain)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                            .onChange(of: minDepthText) {
                                filterMinDepth = parseFlexibleDouble(minDepthText) ?? 0
                            }
                            .onSubmit { commitDepthFields() }
                        if !minDepthText.isEmpty {
                            Button {
                                minDepthText   = ""
                                filterMinDepth = 0
                            } label: {
                                // Same geometry as clearButtonTapTarget() (12 pt vertical +
                                // trailing), spelled out so the caption-sized glyph is preserved
                                // — ClearButtonGlyph() is body-sized and would enlarge it.
                                TapTargetInset(top: 12, bottom: 12, trailing: 12) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Clear"))
                        }
                        Text(verbatim: prefs.depthUnit.symbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25), lineWidth: 1))

                    Image(systemName: "arrow.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Max field
                    HStack(spacing: 6) {
                        Text("Max.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                        TextField("–", text: $maxDepthText)
                            .textFieldStyle(.plain)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                            .onChange(of: maxDepthText) {
                                filterMaxDepth = parseFlexibleDouble(maxDepthText) ?? 0
                            }
                            .onSubmit { commitDepthFields() }
                        if !maxDepthText.isEmpty {
                            Button {
                                maxDepthText   = ""
                                filterMaxDepth = 0
                            } label: {
                                // Same geometry as clearButtonTapTarget() (12 pt vertical +
                                // trailing), spelled out so the caption-sized glyph is preserved
                                // — ClearButtonGlyph() is body-sized and would enlarge it.
                                TapTargetInset(top: 12, bottom: 12, trailing: 12) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Clear"))
                        }
                        Text(verbatim: prefs.depthUnit.symbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isDepthRangeInverted)
            .padding()
            .background(Color.platformSecondaryBackground)
            .cornerRadius(12)
            .onAppear {
                minDepthText = filterMinDepth > 0 ? filterMinDepth.editableString(decimals: 1) : ""
                maxDepthText = filterMaxDepth > 0 ? filterMaxDepth.editableString(decimals: 1) : ""
            }
        }
        .fillsAvailableHeightOnMac()
        .filterCardStyle()
    }
    
    private var ratingFilterSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterSectionHeader(title: "Minimum rating", icon: "star.fill")
            
            ratingChipsLayout {
                ModernFilterChip(
                    label: NSLocalizedString("All", bundle: Bundle.forAppLanguage(), comment: "Filter chip label for selecting all items"),
                    isSelected: filterMinRating == 0,
                    color: .yellow
                ) {
                    withAnimation { filterMinRating = 0 }
                }
                
                ForEach(1...5, id: \.self) { stars in
                    ModernFilterChip(
                        label: String(repeating: "★", count: stars),
                        isSelected: filterMinRating == stars,
                        color: .yellow
                    ) {
                        withAnimation { filterMinRating = stars }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fillsAvailableHeightOnMac()
        .filterCardStyle()
    }

    /// Rating chips: one row (iOS), or wrapping lines on macOS, where the card is half
    /// the sheet's width beside Depth range.
    @ViewBuilder
    private func ratingChipsLayout<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        #if os(macOS)
        WrappingChipLayout(spacing: 12) {
            content()
        }
        #else
        HStack(spacing: 12) {
            content()
        }
        #endif
    }
    
    private var filterResetButtonLabel: String {
        activeFilterCount == 1
            ? NSLocalizedString("Reset 1 filter", bundle: Bundle.forAppLanguage(), comment: "Reset button label when exactly one filter is active.")
            : String(format: NSLocalizedString("Reset %lld filters", bundle: Bundle.forAppLanguage(), comment: "Reset button label showing the number of active filters (plural)."), activeFilterCount)
    }

    // Sort order is intentionally not reset here — it is a durable preference persisted
    // across launches, unlike filters, which are scoped to a single browsing session.
    private var resetSection: some View {
        Group {
            if activeFilterCount > 0 {
                Button(role: .destructive) {
                    withAnimation {
                        filterYear           = nil
                        filterYearNegate     = false
                        filterGasType        = nil
                        filterGasTypeNegate  = false
                        filterMinDepth       = 0
                        filterMaxDepth       = 0
                        minDepthText         = ""
                        maxDepthText         = ""
                        filterMinRating      = 0
                        filterCountry        = nil
                        filterCountryNegate  = false
                        filterDiveType       = nil
                        filterDiveTypeNegate = false
                        filterTag            = nil
                        filterTagNegate      = false
                        filterMarineLife     = []
                        filterMarineLifeMode = .any
                        marineLifeInput      = ""
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .font(.title3)
                        Text(verbatim: filterResetButtonLabel)
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.15))
                    .foregroundStyle(.red)
                    .cornerRadius(14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.red.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
    }
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            closeToolbarButton {
                dismiss()
            }
        }
    }
}

// MARK: - Sort Field Row

/// One row in the Sort card. Tapping an unselected field selects it (descending by
/// default); tapping the already-selected field reverses its direction. A brief
/// pulse on the direction arrow, replayed every time a field becomes selected
/// (including on first appearance for whichever field starts selected), hints that
/// it can be tapped again to reverse — a plain arrow glyph doesn't convey that on
/// its own. Extracted to its own view (rather than a helper method on
/// `DiveFilterSheet`) specifically so the pulse can own `@State` local to its row.
struct SortFieldRow: View {
    let field: DiveSortField
    @Binding var sortOrder: DiveSortOrder

    @State private var isPulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSelected: Bool { sortOrder.field == field }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isSelected {
                    // Tapping the active field reverses it rather than being a no-op.
                    sortOrder.direction.toggle()
                } else {
                    sortOrder = DiveSortOrder(field: field, direction: field.defaultDirection)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: field.icon)
                    .foregroundStyle(isSelected ? .cyan : .secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                Text(field.localizedTitle)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)

                if isSelected {
                    // Direction as a symbol, not a text suffix: adds no translatable
                    // *visible* string (direction is announced via the accessibility
                    // value below) and keeps the four field labels reusing existing
                    // keys. The square-arrow glyph gives the direction a standing
                    // "tappable" look that survives after the pulse (below) finishes.
                    // Cyan matches the row's own selection border.
                    Image(systemName: sortOrder.direction.symbolName)
                        .font(.title.weight(.light))
                        .foregroundStyle(.cyan)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.pulse, options: .repeat(2), isActive: isPulsing)
                        .accessibilityHidden(true)
                        .transition(.scale.combined(with: .opacity))
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.cyan)
                        .accessibilityHidden(true)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding()
            .background(
                isSelected ? Color.cyan.opacity(0.15) : Color.platformSecondaryBackground
            )
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.cyan : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(field.localizedTitle))
        .accessibilityValue(accessibilityValueText)
        .accessibilityHint(
            isSelected
                ? Text("Reverses the sort direction")
                : Text("Sorts dives by this field")
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .onChange(of: isSelected, initial: true) { _, newValue in
            guard newValue else { return }
            // Reset unconditionally (even under Reduce Motion) so a stale `true`
            // from an earlier selection can never re-arm the pulse later.
            isPulsing = false
            guard !reduceMotion else { return }
            // Force a false→true edge so the pulse replays every time this row
            // becomes selected, not just the first time — including right now via
            // `initial: true`, for whichever field starts out selected.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                isPulsing = true
            }
        }
    }

    /// Two literal `Text` branches — never a ternary over `LocalizedStringKey` —
    /// so Xcode's extractor sees both keys.
    private var accessibilityValueText: Text {
        guard isSelected else { return Text(verbatim: "") }
        if sortOrder.direction == .ascending {
            return Text("Ascending", comment: "Accessibility value: the dive list's sort direction is ascending (low to high) — not a diver ascending in the water column.")
        } else {
            return Text("Descending", comment: "Accessibility value: the dive list's sort direction is descending (high to low) — not a diver descending in the water column.")
        }
    }
}

// MARK: - Filter Choice Row

/// A single-choice filter row, shared by the Dives and Marine Life filter sheets: icon and
/// name leading, the current value trailing as a menu of the options. `value` is the selected
/// value's label (nil while "All" is selected). A filter with an Include/Exclude mode passes
/// `negate`, and `hasValue` once a value other than "All" or "None" is chosen, which shows
/// the Include/Exclude control under the row. The value shows grey while "All" is selected,
/// in the row's colour once set, and as "Not …" in orange when excluded.
struct FilterChoiceRow<Value: Hashable, Options: View>: View {
    private let title: Text
    private let icon: String
    private let value: String?
    private let color: Color
    private let selection: Binding<Value>
    private let negate: Binding<Bool>?
    private let hasValue: Bool
    private let options: Options

    init(
        _ title: Text,
        icon: String,
        value: String?,
        color: Color,
        selection: Binding<Value>,
        negate: Binding<Bool>? = nil,
        hasValue: Bool = false,
        @ViewBuilder options: () -> Options
    ) {
        self.title = title
        self.icon = icon
        self.value = value
        self.color = color
        self.selection = selection
        self.negate = negate
        self.hasValue = hasValue
        self.options = options()
    }

    private var excludes: Bool { hasValue && negate?.wrappedValue == true }

    private var label: String {
        guard let value else {
            return NSLocalizedString("All", bundle: Bundle.forAppLanguage(), comment: "Filter menu option for selecting all items")
        }
        guard excludes else { return value }
        return String(format: NSLocalizedString("Not %@", bundle: Bundle.forAppLanguage(), value: "Not %@", comment: "Filter value shown when the filter excludes the selected value, e.g. “Not Egypt”"), value)
    }

    private var labelColor: Color { value == nil ? .secondary : (excludes ? .orange : color) }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                // Visual only: VoiceOver reads the name with the value on the menu below.
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.cyan)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                title
                    .font(.headline)
                    .fontWeight(.semibold)
                    .accessibilityHidden(true)
                Spacer(minLength: 12)
                Menu {
                    Picker(selection: selection) { options } label: { EmptyView() }
                        .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: label)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.body.weight(.medium))
                    .foregroundStyle(labelColor)
                    .contentShape(Rectangle())
                }
                .filterMenuStyleOnMac()
                .accessibilityLabel(title)
                .accessibilityValue(Text(verbatim: label))
            }

            // Include/Exclude under its row, aligned with the filter name, once a value is set.
            if hasValue, let negate {
                Picker(selection: negate.animation()) {
                    Text(NSLocalizedString("Include", bundle: Bundle.forAppLanguage(), comment: "Filter mode: include dives matching the selected value")).tag(false)
                    Text(NSLocalizedString("Exclude", bundle: Bundle.forAppLanguage(), comment: "Filter mode: exclude dives matching the selected value")).tag(true)
                } label: { Text("Include or exclude") }
                .fullWidthSegmentedPicker()
                .padding(.leading, 38)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Filter Section Header

struct FilterSectionHeader: View {
    let title: LocalizedStringKey
    let icon: String
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.cyan)
            
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Modern Filter Chip

struct ModernFilterChip: View {
    let label: String
    /// A localized key shown instead of `label` (e.g. a gear category's "gear.category.X").
    private var labelKey: LocalizedStringKey?
    let isSelected: Bool
    var color: Color = .cyan
    let action: () -> Void

    init(label: String, isSelected: Bool, color: Color = .cyan, action: @escaping () -> Void) {
        self.label = label
        self.isSelected = isSelected
        self.color = color
        self.action = action
    }

    init(_ labelKey: LocalizedStringKey, isSelected: Bool, color: Color = .cyan, action: @escaping () -> Void) {
        self.label = ""
        self.labelKey = labelKey
        self.isSelected = isSelected
        self.color = color
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            (labelKey.map { Text($0) } ?? Text(label))
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .medium)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(isSelected ? color.opacity(0.2) : Color.platformSecondaryBackground)
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? color : Color.clear, lineWidth: 2)
                )
                .foregroundStyle(isSelected ? color : .secondary)
        }
        .buttonStyle(.plain)
        // VoiceOver says which chip is the selected filter.
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Filter Card Style Extension

extension View {
    func filterCardStyle() -> some View {
        self
            .padding()
            .filterCardBackground()
    }

    /// The filter card's background, corners and shadow, for a card that sets its own padding.
    func filterCardBackground() -> some View {
        self
            .background(Color.platformTertiaryBackground)
            .cornerRadius(16)
            .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    /// The choice filters' value menu: on macOS a `Menu` is otherwise a bordered pull-down
    /// button that ignores its label's colour (as in `listRowMenu`); on iOS it is unchanged.
    @ViewBuilder
    func filterMenuStyleOnMac() -> some View {
        #if os(macOS)
        self
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        #else
        self
        #endif
    }

    /// Masks the trailing edge with a fade gradient to hint that more chips are scrollable.
    func chipRowFade() -> some View {
        self.mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.88),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }
}

// MARK: - Dive Sort Icons

extension DiveSortField {
    /// Identifies the *field*, not the sort direction (direction is shown
    /// separately by `DiveSortDirection.symbolName` in the same row). `.depth` is
    /// the one exception that looks like a directional arrow: it reuses the
    /// app-wide depth glyph (see `FilterSectionHeader(title: "Depth range", icon:
    /// "arrow.down.to.line")` above) rather than introducing a second depth icon,
    /// so Depth + ascending can render alongside an up-pointing direction arrow.
    var icon: String {
        switch self {
        case .date:       return "calendar"
        case .depth:      return "arrow.down.to.line"
        case .duration:   return "clock"
        case .diveNumber: return "number"
        }
    }
}

extension DiveSortDirection {
    var symbolName: String {
        switch self {
        case .ascending:  return "arrow.up.square"
        case .descending: return "arrow.down.square"
        }
    }
}
