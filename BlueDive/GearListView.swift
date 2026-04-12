import SwiftUI
import SwiftData

struct GearListView: View {
    @Query(sort: \Gear.name) private var allGear: [Gear]
    @Environment(\.modelContext) private var modelContext
    
    @State private var showAddGear = false
    @State private var selectedGear: Gear?
    @State private var searchText = ""
    @State private var filterCategory: GearCategory?
    @State private var showInactive = false
    @State private var collapsedSections: Set<String> = []

    // MARK: - Computed Properties
    
    /// Équipement filtré par recherche et catégorie
    private var filteredGear: [Gear] {
        var gear = allGear
        
        // Filtre par statut actif/inactif
        if !showInactive {
            gear = gear.filter { !$0.isInactive }
        }
        
        // Filtre par catégorie
        if let category = filterCategory {
            gear = gear.filter { $0.category == category.rawValue }
        }
        
        // Filtre par recherche
        if !searchText.isEmpty {
            gear = gear.filter { item in
                item.name.localizedCaseInsensitiveContains(searchText) ||
                item.category.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        return gear
    }
    
    /// Équipement groupé par catégorie
    private var groupedGear: [(key: String, value: [Gear])] {
        let grouped = Dictionary(grouping: filteredGear, by: { $0.category })
        return grouped.sorted { $0.key < $1.key }
    }
    
    /// Équipement nécessitant un entretien — service due within 30 days or already past
    private var gearNeedingService: [Gear] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let warningDate = calendar.date(byAdding: .day, value: 30, to: today) else {
            return []
        }
        return allGear.filter { gear in
            guard !gear.isInactive, let due = gear.nextServiceDue else { return false }
            let serviceDay = calendar.startOfDay(for: due)
            return serviceDay <= warningDate
        }
    }

    /// Équipement dont l'entretien est déjà dû ou dépassé
    private var gearOverdue: [Gear] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return allGear.filter { gear in
            guard !gear.isInactive, let due = gear.nextServiceDue else { return false }
            return calendar.startOfDay(for: due) <= today
        }
    }

    // MARK: - Body
    
    var body: some View {
        ZStack {
            Color.platformBackground.ignoresSafeArea()
            
            VStack(spacing: 0) {
                if !gearNeedingService.isEmpty {
                    serviceAlertBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                contentSection
            }
            .animation(.easeInOut(duration: 0.3), value: gearNeedingService.isEmpty)
        }
        .navigationTitle("My Equipment")
        .searchable(text: $searchText, prompt: "Search equipment...")
        .animation(.easeInOut(duration: 0.3), value: searchText)
        .animation(.easeInOut(duration: 0.3), value: filterCategory)
        .animation(.easeInOut(duration: 0.3), value: showInactive)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showAddGear) {
            AddGearView()
                #if os(iOS)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                #endif
        }
        .sheet(item: $selectedGear) { gear in
            GearServiceView(gear: gear)
                #if os(iOS)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                #elseif os(macOS)
                .frame(minWidth: 650, idealWidth: 800, maxWidth: 1000, minHeight: 600, idealHeight: 800, maxHeight: 900)
                #endif
        }

    }
    
    // MARK: - View Components
    
    @ViewBuilder
    private var contentSection: some View {
        if allGear.isEmpty {
            emptyStateView
                .transition(.opacity)
        } else if filteredGear.isEmpty {
            noResultsView
                .transition(.opacity)
        } else {
            gearList
                .transition(.opacity)
        }
    }
    
    private var emptyStateView: some View {
        ContentUnavailableView(
            "No Equipment",
            systemImage: "wrench.and.screwdriver.fill",
            description: Text("Add your tanks, suits, and regulators to track their usage and maintenance.")
        )
    }
    
    private var noResultsView: some View {
        ContentUnavailableView.search(text: searchText)
    }
    
    /// Banner colour: red when any gear is overdue, orange when only approaching.
    private var bannerColor: Color {
        gearOverdue.isEmpty ? .orange : .red
    }

    private var serviceAlertBanner: some View {
        HStack {
            Image(systemName: gearOverdue.isEmpty ? "exclamationmark.triangle.fill" : "xmark.shield.fill")
                .foregroundStyle(bannerColor)
            
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if gearOverdue.isEmpty {
                        Text("Service Upcoming")
                    } else {
                        Text("Service Required")
                    }
                }
                    .font(.subheadline)
                    .fontWeight(.bold)
                
                bannerSubtitle
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(bannerColor.opacity(0.15))
    }

    private var bannerSubtitle: Text {
        let overdueCount = gearOverdue.count
        let approachingCount = gearNeedingService.count - overdueCount
        if overdueCount > 0 && approachingCount > 0 {
            return Text("\(overdueCount) overdue") + Text(", ") + Text("\(approachingCount) due soon")
        } else if overdueCount > 0 {
            return Text("\(overdueCount) overdue")
        } else {
            return Text("\(approachingCount) due soon")
        }
    }
    
    private var gearList: some View {
        List {
            // Filtre par catégorie
            if searchText.isEmpty {
                categoryFilterSection
            }
            
            // Liste groupée
            ForEach(groupedGear, id: \.key) { category, items in
                Section(isExpanded: Binding(
                    get: { !collapsedSections.contains(category) },
                    set: { isExpanded in
                        if isExpanded {
                            collapsedSections.remove(category)
                        } else {
                            collapsedSections.insert(category)
                        }
                    }
                )) {
                    ForEach(items) { item in
                        Button {
                            selectedGear = item
                        } label: {
                            GearRow(gear: item)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { indexSet in
                        deleteGear(items: items, at: indexSet)
                    }
                } header: {
                    HStack {
                        if let gearCategory = GearCategory.allCases.first(where: { $0.rawValue == category }) {
                            Image(systemName: gearCategory.icon)
                            Text(gearCategory.localizedName)
                        } else {
                            Text(category)
                        }
                    }
                    .font(.headline)
                    .foregroundStyle(.cyan)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .refreshable {
            try? modelContext.save()
            NSUbiquitousKeyValueStore.default.synchronize()
            try? await Task.sleep(for: .seconds(1.5))
        }
    }
    
    private var categoryFilterSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    // Filter by category
                    CategoryFilterChip(
                        title: "All",
                        icon: "square.grid.2x2",
                        isSelected: filterCategory == nil
                    ) {
                        filterCategory = nil
                    }
                    
                    // Catégories
                    ForEach(GearCategory.allCases) { category in
                        let count = allGear.filter { $0.category == category.rawValue }.count
                        if count > 0 {
                            CategoryFilterChip(
                                title: "gear.category." + category.rawValue,
                                icon: category.icon,
                                count: count,
                                isSelected: filterCategory == category
                            ) {
                                filterCategory = category
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }
    
    /// Number of inactive gear items (shown as badge on the toggle)
    private var inactiveCount: Int {
        allGear.filter { $0.isInactive }.count
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if inactiveCount > 0 {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation {
                        showInactive.toggle()
                    }
                } label: {
                    Image(systemName: showInactive ? "eye.fill" : "eye.slash.fill")
                        .font(.title3)
                        .foregroundStyle(showInactive ? .cyan : .secondary)
                }
                .help(showInactive
                      ? NSLocalizedString("Hide Inactive Equipment", bundle: Bundle.forAppLanguage(), comment: "")
                      : NSLocalizedString("Show Inactive Equipment", bundle: Bundle.forAppLanguage(), comment: ""))
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showAddGear = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.cyan)
            }
        }
    }
    
    // MARK: - Actions
    
    private func deleteGear(items: [Gear], at offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                let itemToDelete = items[index]
                NotificationManager.shared.cancelNotification(identifier: "gear-\(itemToDelete.id.uuidString)")
                modelContext.delete(itemToDelete)
            }
            try? modelContext.save()
        }
    }
}

// MARK: - Gear Row

struct GearRow: View {
    let gear: Gear
    
    var body: some View {
        HStack(spacing: 15) {
            // Icône de catégorie
            categoryIcon
            
            // Informations
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(gear.isInactive ? .red : .green)
                        .frame(width: 8, height: 8)
                    
                    Text(gear.name)
                        .font(.headline)
                        .foregroundStyle(gear.isInactive ? .secondary : .primary)
                }
                
                gearDetails
            }
            
            Spacer()
            
            // Indicateur d'entretien — orange within 30 days, red when due/past
            if let indicatorColor = serviceIndicatorColor {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(indicatorColor)
                    .font(.title3)
            }
        }
        .padding(.vertical, 8)
    }
    
    private var categoryIcon: some View {
        ZStack {
            Circle()
                .fill(iconColor.opacity(0.15))
                .frame(width: 44, height: 44)
            
            Image(systemName: iconName)
                .font(.system(size: 18))
                .foregroundStyle(iconColor)
        }
    }
    
    @ViewBuilder
    private var gearDetails: some View {
        HStack(spacing: 8) {
            // Poids
            if gear.weightContribution > 0 {
                Text("• \(UserPreferences.shared.weightUnit.formatted(gear.weightContribution, from: WeightUnit.from(importFormat: gear.weightContributionUnit ?? UserPreferences.shared.weightUnit.symbol)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            // Nombre de plongées
            Label("\(gear.totalDivesCount)", systemImage: "water.waves")
                .font(.caption)
                .foregroundStyle(.cyan)
        }
    }
    
    /// Returns red if service is due/past, orange if within 30 days, nil otherwise.
    private var serviceIndicatorColor: Color? {
        guard let due = gear.nextServiceDue else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let serviceDay = calendar.startOfDay(for: due)
        if serviceDay <= today {
            return .red
        }
        guard let warningDate = calendar.date(byAdding: .day, value: 30, to: today) else {
            return nil
        }
        if serviceDay <= warningDate {
            return .orange
        }
        return nil
    }
    
    // Helpers
    private var iconName: String {
        gear.gearCategory?.icon ?? "wrench.and.screwdriver.fill"
    }
    
    private var iconColor: Color {
        guard let colorName = gear.gearCategory?.color else { return .cyan }
        
        switch colorName {
        case "purple": return .purple
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "gray": return .gray
        case "cyan": return .cyan
        case "pink": return .pink
        case "indigo": return .indigo
        default: return .brown
        }
    }
}

// MARK: - Category Filter Chip

struct CategoryFilterChip: View {
    let title: String
    let icon: String
    var count: Int?
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                action()
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                
                Text(LocalizedStringKey(title))
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                
                if let count = count {
                    Text("\(count)")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.cyan : Color.gray.opacity(0.3))
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? Color.cyan.opacity(0.2) : Color.gray.opacity(0.1))
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.cyan : Color.clear, lineWidth: 1)
            )
            .scaleEffect(isSelected ? 1.0 : 0.97)
            .animation(.easeInOut(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}
