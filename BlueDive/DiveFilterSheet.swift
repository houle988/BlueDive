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
            #if os(macOS)
            .frame(minWidth: 550, idealWidth: 600, maxWidth: 700, minHeight: 500, idealHeight: 650, maxHeight: 850)
            .background(Color(nsColor: .textBackgroundColor))
            #else
            .background(Color(.systemGroupedBackground))
            #endif
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
        #if os(macOS)
        .frame(minWidth: 550, idealWidth: 600, maxWidth: 750, minHeight: 500, idealHeight: 650, maxHeight: 900)
        #endif
    }
    
    // MARK: - Sections
    
    private var sortSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterSectionHeader(title: "Sort", icon: "arrow.up.arrow.down")

            VStack(spacing: 8) {
                ForEach(DiveSortField.allCases) { field in
                    SortFieldRow(field: field, sortOrder: $sortOrder)
                }
            }
        }
        .filterCardStyle()
    }

    @ViewBuilder
    private var filterSections: some View {
        yearFilterSection

        if !availableCountries.isEmpty {
            countryFilterSection
        }

        if !availableDiveTypes.isEmpty {
            diveTypeFilterSection
        }

        if !availableTags.isEmpty {
            tagsFilterSection
        }

        if !availableGasTypes.isEmpty {
            gasTypeFilterSection
        }

        if !availableMarineLife.isEmpty {
            marineLifeFilterSection
        }

        depthFilterSection
        ratingFilterSection
    }
    
    private var yearFilterSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.title3)
                    .foregroundStyle(.cyan)
                Text("Year")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                if filterYear != nil {
                    Picker("", selection: $filterYearNegate) {
                        Text(NSLocalizedString("Include", bundle: Bundle.forAppLanguage(), comment: "Filter mode: include dives matching the selected value")).tag(false)
                        Text(NSLocalizedString("Exclude", bundle: Bundle.forAppLanguage(), comment: "Filter mode: exclude dives matching the selected value")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 160)
                }
            }
            .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ModernFilterChip(
                        label: NSLocalizedString("All", bundle: Bundle.forAppLanguage(), comment: "Filter chip label for selecting all items"),
                        isSelected: filterYear == nil,
                        color: .cyan
                    ) {
                        withAnimation {
                            filterYear = nil
                            filterYearNegate = false
                        }
                    }

                    ForEach(availableYears, id: \.self) { year in
                        ModernFilterChip(
                            label: "\(year)",
                            isSelected: filterYear == year,
                            color: filterYearNegate ? .orange : .cyan
                        ) {
                            withAnimation { filterYear = year }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .chipRowFade()
        }
        .filterCardStyle()
    }
    
    private var countryFilterSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .font(.title3)
                    .foregroundStyle(.cyan)
                Text("Country")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                if let c = filterCountry, !c.isEmpty {
                    Picker("", selection: $filterCountryNegate) {
                        Text(NSLocalizedString("Include", bundle: Bundle.forAppLanguage(), comment: "Filter mode: include dives matching the selected value")).tag(false)
                        Text(NSLocalizedString("Exclude", bundle: Bundle.forAppLanguage(), comment: "Filter mode: exclude dives matching the selected value")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 160)
                }
            }
            .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ModernFilterChip(
                        label: NSLocalizedString("All", bundle: Bundle.forAppLanguage(), comment: "Filter chip label for selecting all items"),
                        isSelected: filterCountry == nil,
                        color: .blue
                    ) {
                        withAnimation {
                            filterCountry = nil
                            filterCountryNegate = false
                        }
                    }

                    ModernFilterChip(
                        label: NSLocalizedString("None", bundle: Bundle.forAppLanguage(), comment: "Filter option to show dives with no country set"),
                        isSelected: filterCountry == "",
                        color: .blue
                    ) {
                        withAnimation {
                            filterCountry = ""
                            filterCountryNegate = false
                        }
                    }

                    ForEach(availableCountries, id: \.self) { country in
                        ModernFilterChip(
                            label: country,
                            isSelected: filterCountry == country,
                            color: filterCountryNegate ? .orange : .blue
                        ) {
                            withAnimation { filterCountry = country }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .chipRowFade()
        }
        .filterCardStyle()
    }
    
    private var diveTypeFilterSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "figure.open.water.swim")
                    .font(.title3)
                    .foregroundStyle(.cyan)
                Text("Dive type")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                if let dt = filterDiveType, !dt.isEmpty {
                    Picker("", selection: $filterDiveTypeNegate) {
                        Text(NSLocalizedString("Include", bundle: Bundle.forAppLanguage(), comment: "Filter mode: include dives matching the selected value")).tag(false)
                        Text(NSLocalizedString("Exclude", bundle: Bundle.forAppLanguage(), comment: "Filter mode: exclude dives matching the selected value")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 160)
                }
            }
            .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ModernFilterChip(
                        label: NSLocalizedString("All", bundle: Bundle.forAppLanguage(), comment: "Filter chip label for selecting all items"),
                        isSelected: filterDiveType == nil,
                        color: .purple
                    ) {
                        withAnimation {
                            filterDiveType = nil
                            filterDiveTypeNegate = false
                        }
                    }

                    ModernFilterChip(
                        label: NSLocalizedString("None", bundle: Bundle.forAppLanguage(), comment: "Filter option to show dives with no dive type set"),
                        isSelected: filterDiveType == "",
                        color: .purple
                    ) {
                        withAnimation {
                            filterDiveType = ""
                            filterDiveTypeNegate = false
                        }
                    }

                    ForEach(availableDiveTypes, id: \.self) { diveType in
                        ModernFilterChip(
                            label: diveType,
                            isSelected: filterDiveType == diveType,
                            color: filterDiveTypeNegate ? .orange : .purple
                        ) {
                            withAnimation { filterDiveType = diveType }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .chipRowFade()
        }
        .filterCardStyle()
    }
    
    private var tagsFilterSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterSectionHeader(title: "Tags", icon: "tag.fill")
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ModernFilterChip(
                        label: NSLocalizedString("All", bundle: Bundle.forAppLanguage(), comment: "Filter chip label for selecting all items"),
                        isSelected: filterTag == nil,
                        color: .orange
                    ) {
                        withAnimation { filterTag = nil }
                    }

                    ModernFilterChip(
                        label: NSLocalizedString("None", bundle: Bundle.forAppLanguage(), comment: "Filter option to show dives with no tag set"),
                        isSelected: filterTag == "",
                        color: .orange
                    ) {
                        withAnimation { filterTag = "" }
                    }
                    
                    ForEach(availableTags, id: \.self) { tag in
                        ModernFilterChip(
                            label: tag,
                            isSelected: filterTag == tag,
                            color: .orange
                        ) {
                            withAnimation { filterTag = tag }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .chipRowFade()
        }
        .filterCardStyle()
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
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
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
                        .padding(.horizontal, 4)
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
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
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
                        .padding(.horizontal, 4)
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

    private var gasTypeFilterSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "bubbles.and.sparkles")
                    .font(.title3)
                    .foregroundStyle(.cyan)
                Text("Gas type")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                if let g = filterGasType, !g.isEmpty {
                    Picker("", selection: $filterGasTypeNegate) {
                        Text(NSLocalizedString("Include", bundle: Bundle.forAppLanguage(), comment: "Filter mode: include dives matching the selected value")).tag(false)
                        Text(NSLocalizedString("Exclude", bundle: Bundle.forAppLanguage(), comment: "Filter mode: exclude dives matching the selected value")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 160)
                }
            }
            .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ModernFilterChip(
                        label: NSLocalizedString("All", bundle: Bundle.forAppLanguage(), comment: "Filter chip label for selecting all items"),
                        isSelected: filterGasType == nil,
                        color: .green
                    ) {
                        withAnimation {
                            filterGasType = nil
                            filterGasTypeNegate = false
                        }
                    }

                    ModernFilterChip(
                        label: NSLocalizedString("None", bundle: Bundle.forAppLanguage(), comment: "Filter option to show dives with no gas type set"),
                        isSelected: filterGasType == "",
                        color: .green
                    ) {
                        withAnimation {
                            filterGasType = ""
                            filterGasTypeNegate = false
                        }
                    }

                    ForEach(availableGasTypes, id: \.self) { gas in
                        ModernFilterChip(
                            label: gas,
                            isSelected: filterGasType == gas,
                            color: filterGasTypeNegate ? .orange : .green
                        ) {
                            withAnimation { filterGasType = gas }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            .chipRowFade()
        }
        .filterCardStyle()
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
        .filterCardStyle()
    }
    
    private var ratingFilterSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterSectionHeader(title: "Minimum rating", icon: "star.fill")
            
            HStack(spacing: 12) {
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
        .filterCardStyle()
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
    let isSelected: Bool
    var color: Color = .cyan
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(label)
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
    }
}

// MARK: - Filter Card Style Extension

extension View {
    func filterCardStyle() -> some View {
        self
            .padding()
            .background(Color.platformTertiaryBackground)
            .cornerRadius(16)
            .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
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
