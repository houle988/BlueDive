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
    @Binding var sortOrder: ContentView.DiveSortOrder

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
                ForEach(ContentView.DiveSortOrder.allCases) { order in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            sortOrder = order
                        }
                    } label: {
                        HStack {
                            Image(systemName: order.icon)
                                .foregroundStyle(sortOrder == order ? .cyan : .secondary)
                                .frame(width: 24)
                            
                            Text(order.localizedTitle)
                                .fontWeight(sortOrder == order ? .semibold : .regular)
                                .foregroundStyle(sortOrder == order ? .primary : .secondary)
                            
                            Spacer()
                            
                            if sortOrder == order {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.cyan)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .padding()
                        .background(
                            sortOrder == order ?
                            Color.cyan.opacity(0.15) : Color.platformSecondaryBackground
                        )
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(sortOrder == order ? Color.cyan : Color.clear, lineWidth: 2)
                        )
                    }
                    .buttonStyle(.plain)
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
                        label: "All",
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
                        label: "All",
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
                        label: "All",
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
                        label: "All",
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
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
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
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
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
                        label: "All",
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
            return "\(Int(lo)) – \(Int(hi)) \(unit)"
        case (true, false):
            return "≥ \(Int(filterMinDepth)) \(unit)"
        case (false, true):
            return "≤ \(Int(filterMaxDepth)) \(unit)"
        default:
            return ""
        }
    }

    private func commitDepthFields() {
        let rawMin = minDepthText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        let rawMax = maxDepthText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        let parsedMin = Double(rawMin) ?? 0
        let parsedMax = Double(rawMax) ?? 0
        // If both are set and inverted, swap them so the range is always lo–hi
        if parsedMin > 0, parsedMax > 0, parsedMin > parsedMax {
            filterMinDepth = parsedMax
            filterMaxDepth = parsedMin
            minDepthText   = String(Int(parsedMax))
            maxDepthText   = String(Int(parsedMin))
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
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
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
                                let parsed = Double(
                                    minDepthText
                                        .replacingOccurrences(of: ",", with: ".")
                                        .trimmingCharacters(in: .whitespaces)
                                ) ?? 0
                                filterMinDepth = parsed
                            }
                            .onSubmit { commitDepthFields() }
                        if !minDepthText.isEmpty {
                            Button {
                                minDepthText   = ""
                                filterMinDepth = 0
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
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
                                let parsed = Double(
                                    maxDepthText
                                        .replacingOccurrences(of: ",", with: ".")
                                        .trimmingCharacters(in: .whitespaces)
                                ) ?? 0
                                filterMaxDepth = parsed
                            }
                            .onSubmit { commitDepthFields() }
                        if !maxDepthText.isEmpty {
                            Button {
                                maxDepthText   = ""
                                filterMaxDepth = 0
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
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
                minDepthText = filterMinDepth > 0 ? String(Int(filterMinDepth)) : ""
                maxDepthText = filterMaxDepth > 0 ? String(Int(filterMaxDepth)) : ""
            }
        }
        .filterCardStyle()
    }
    
    private var ratingFilterSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterSectionHeader(title: "Minimum rating", icon: "star.fill")
            
            HStack(spacing: 12) {
                ModernFilterChip(
                    label: "All",
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
    
    private var hasSortChange: Bool {
        showSort && sortOrder != .dateDesc
    }

    private var hasAnythingToReset: Bool {
        activeFilterCount > 0 || hasSortChange
    }

    private var resetButtonLabel: String {
        let hasFilters = activeFilterCount > 0
        if hasFilters && hasSortChange {
            return String(
                format: NSLocalizedString("Reset %lld filter(s) & sort", bundle: Bundle.forAppLanguage(), comment: "Reset button label when both filters and sort order are active"),
                activeFilterCount
            )
        } else if hasFilters {
            return String(
                format: NSLocalizedString("Reset %lld filter(s)", bundle: Bundle.forAppLanguage(), comment: "Reset button label showing the number of active filters"),
                activeFilterCount
            )
        } else {
            return NSLocalizedString("Reset sort", bundle: Bundle.forAppLanguage(), comment: "Reset button label when only the sort order is changed")
        }
    }

    private var resetSection: some View {
        Group {
            if hasAnythingToReset {
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
                        if showSort {
                            sortOrder        = .dateDesc
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .font(.title3)
                        Text(verbatim: resetButtonLabel)
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
        ToolbarItem(placement: .confirmationAction) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Close")
                }
                .fontWeight(.semibold)
            }
            #if os(iOS)
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            #else
            .foregroundStyle(.cyan)
            #endif
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

// MARK: - DiveSortOrder Extension

extension ContentView.DiveSortOrder {
    var icon: String {
        switch self {
        case .dateDesc:
            return "arrow.down"
        case .dateAsc:
            return "arrow.up"
        case .depthDesc:
            return "arrow.down.to.line"
        case .durationDesc:
            return "clock.arrow.2.circlepath"
        case .diveNumberDesc:
            return "number"
        }
    }
}
