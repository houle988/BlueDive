import SwiftUI

// MARK: - Dive Filter Sheet

struct DiveFilterSheet: View {
    let availableYears: [Int]
    let availableGasTypes: [String]
    let availableCountries: [String]
    let availableDiveTypes: [String]
    let availableTags: [String]
    let availableDiverNames: [String]
    let availableMarineLife: [String]
    var showSort: Bool = true

    @Binding var filterYear: Int?
    @Binding var filterGasType: String?
    @Binding var filterMinDepth: Double
    @Binding var filterMinRating: Int
    @Binding var filterCountry: String?
    @Binding var filterDiveType: String?
    @Binding var filterTag: String?
    @Binding var filterDiverName: String?
    @Binding var filterMarineLife: String
    @Binding var sortOrder: ContentView.DiveSortOrder

    @Environment(\.dismiss) private var dismiss
    private let prefs = UserPreferences.shared
    
    private var activeFilterCount: Int {
        var count = 0
        if filterYear != nil { count += 1 }
        if filterGasType != nil { count += 1 }
        if filterMinDepth > 0 { count += 1 }
        if filterMinRating > 0 { count += 1 }
        if filterCountry != nil { count += 1 }
        if filterDiveType != nil { count += 1 }
        if filterTag != nil { count += 1 }
        if filterDiverName != nil { count += 1 }
        if !filterMarineLife.isEmpty { count += 1 }
        return count
    }

    private var marineLifeSuggestions: [String] {
        guard !filterMarineLife.isEmpty else { return [] }
        return availableMarineLife.filter {
            $0.localizedCaseInsensitiveContains(filterMarineLife) && $0.lowercased() != filterMarineLife.lowercased()
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

        if !availableDiverNames.isEmpty {
            diverNameFilterSection
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
            FilterSectionHeader(title: "Year", icon: "calendar")
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ModernFilterChip(
                        label: "All",
                        isSelected: filterYear == nil,
                        color: .cyan
                    ) {
                        withAnimation { filterYear = nil }
                    }
                    
                    ForEach(availableYears, id: \.self) { year in
                        ModernFilterChip(
                            label: "\(year)",
                            isSelected: filterYear == year,
                            color: .cyan
                        ) {
                            withAnimation { filterYear = year }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .filterCardStyle()
    }
    
    private var countryFilterSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterSectionHeader(title: "Country", icon: "globe")
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ModernFilterChip(
                        label: "All",
                        isSelected: filterCountry == nil,
                        color: .blue
                    ) {
                        withAnimation { filterCountry = nil }
                    }

                    ModernFilterChip(
                        label: NSLocalizedString("None", bundle: Bundle.forAppLanguage(), comment: "Filter option to show dives with no country set"),
                        isSelected: filterCountry == "",
                        color: .blue
                    ) {
                        withAnimation { filterCountry = "" }
                    }
                    
                    ForEach(availableCountries, id: \.self) { country in
                        ModernFilterChip(
                            label: country,
                            isSelected: filterCountry == country,
                            color: .blue
                        ) {
                            withAnimation { filterCountry = country }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .filterCardStyle()
    }
    
    private var diveTypeFilterSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterSectionHeader(title: "Dive type", icon: "figure.open.water.swim")
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ModernFilterChip(
                        label: "All",
                        isSelected: filterDiveType == nil,
                        color: .purple
                    ) {
                        withAnimation { filterDiveType = nil }
                    }

                    ModernFilterChip(
                        label: NSLocalizedString("None", bundle: Bundle.forAppLanguage(), comment: "Filter option to show dives with no dive type set"),
                        isSelected: filterDiveType == "",
                        color: .purple
                    ) {
                        withAnimation { filterDiveType = "" }
                    }
                    
                    ForEach(availableDiveTypes, id: \.self) { diveType in
                        ModernFilterChip(
                            label: diveType,
                            isSelected: filterDiveType == diveType,
                            color: .purple
                        ) {
                            withAnimation { filterDiveType = diveType }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
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
        }
        .filterCardStyle()
    }
    
    private var diverNameFilterSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterSectionHeader(title: "Diver", icon: "person.fill")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ModernFilterChip(
                        label: "All",
                        isSelected: filterDiverName == nil,
                        color: .indigo
                    ) {
                        withAnimation { filterDiverName = nil }
                    }

                    ModernFilterChip(
                        label: NSLocalizedString("None", bundle: Bundle.forAppLanguage(), comment: "Filter option to show dives with no diver set"),
                        isSelected: filterDiverName == "",
                        color: .indigo
                    ) {
                        withAnimation { filterDiverName = "" }
                    }

                    ForEach(availableDiverNames, id: \.self) { name in
                        ModernFilterChip(
                            label: name,
                            isSelected: filterDiverName == name,
                            color: .indigo
                        ) {
                            withAnimation { filterDiverName = name }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .filterCardStyle()
    }

    private var marineLifeFilterSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterSectionHeader(title: "Marine life", icon: "fish.fill")

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    TextField("Marine life", text: $filterMarineLife)
                        .textFieldStyle(.plain)
                    if !filterMarineLife.isEmpty {
                        Button {
                            withAnimation { filterMarineLife = "" }
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
                                    withAnimation { filterMarineLife = suggestion }
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
                }
            }
        }
        .filterCardStyle()
    }

    private var gasTypeFilterSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterSectionHeader(title: "Gas type", icon: "bubbles.and.sparkles")
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ModernFilterChip(
                        label: "All",
                        isSelected: filterGasType == nil,
                        color: .green
                    ) {
                        withAnimation { filterGasType = nil }
                    }

                    ModernFilterChip(
                        label: NSLocalizedString("None", bundle: Bundle.forAppLanguage(), comment: "Filter option to show dives with no gas type set"),
                        isSelected: filterGasType == "",
                        color: .green
                    ) {
                        withAnimation { filterGasType = "" }
                    }
                    
                    ForEach(availableGasTypes, id: \.self) { gas in
                        ModernFilterChip(
                            label: gas,
                            isSelected: filterGasType == gas,
                            color: .green
                        ) {
                            withAnimation { filterGasType = gas }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .filterCardStyle()
    }
    
    private var depthFilterSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterSectionHeader(title: "Minimum depth", icon: "arrow.down.to.line")
            
            VStack(spacing: 12) {
                HStack {
                    if filterMinDepth > 0 {
                        Text("≥ \(Int(filterMinDepth)) \(prefs.depthUnit.symbol)")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.cyan)
                    } else {
                        Text("All depths")
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    
                    if filterMinDepth > 0 {
                        Button {
                            withAnimation {
                                filterMinDepth = 0
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                Slider(
                    value: $filterMinDepth,
                    in: 0...(prefs.depthUnit == .feet ? 200 : 60),
                    step: prefs.depthUnit == .feet ? 10 : 5
                )
                .tint(.cyan)
                
                HStack {
                    Text("0 \(prefs.depthUnit.symbol)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(prefs.depthUnit == .feet ? 200 : 60) \(prefs.depthUnit.symbol)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(Color.platformSecondaryBackground)
            .cornerRadius(12)
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
        }
        .filterCardStyle()
    }
    
    private var resetSection: some View {
        VStack(spacing: 12) {
            Button(role: .destructive) {
                withAnimation {
                    filterYear       = nil
                    filterGasType    = nil
                    filterMinDepth   = 0
                    filterMinRating  = 0
                    filterCountry    = nil
                    filterDiveType   = nil
                    filterTag        = nil
                    filterDiverName  = nil
                    filterMarineLife = ""
                    if showSort {
                        sortOrder    = .dateDesc
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.title3)
                    Text("Reset all filters")
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
            .disabled(activeFilterCount == 0 && (showSort ? sortOrder == .dateDesc : true))
            .opacity(activeFilterCount == 0 && (showSort ? sortOrder == .dateDesc : true) ? 0.5 : 1.0)
        }
        .padding(.top, 8)
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
