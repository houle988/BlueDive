import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

struct GearListView: View {
    @Query(sort: \Gear.name) private var allGear: [Gear]
    @Query(sort: \GearGroup.name) private var allGearGroups: [GearGroup]
    @Query(sort: \TankTemplate.name) private var allTankTemplates: [TankTemplate]
    @Query(sort: \Dive.timestamp, order: .reverse) private var allDivesForFilter: [Dive]
    @Query(sort: \Certification.issueDate, order: .reverse) private var allCertificationsForFilter: [Certification]
    @Environment(\.modelContext) private var modelContext
    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""

    @State private var showAddGear = false
    @State private var selectedGear: Gear?
    @State private var searchText = ""
    @State private var filterCategory: GearCategory?
    @State private var showInactive = false
    @State private var collapsedSections: Set<String> = []
    @State private var showTankTemplates = false
    @State private var showGearGroups = false
    @State private var showImportPicker = false
    @State private var importError: String?
    @State private var showImportError = false
    @State private var importedCount: Int = 0
    @State private var importedGroupCount: Int = 0
    @State private var importedTemplateCount: Int = 0
    @State private var importedGroupMissingMemberCount: Int = 0
    @State private var showImportSuccess = false
    #if os(iOS)
    @State private var showFileExporter = false
    @State private var exportDocument: ExportableFileDocument?
    @State private var exportFileName: String = ""
    #endif

    // MARK: - Computed Properties

    private var uniqueDivers: [String] {
        DiverFilter.uniqueDivers(in: allDivesForFilter, gear: allGear, certifications: allCertificationsForFilter)
    }

    /// Équipement filtré par recherche et catégorie
    private var filteredGear: [Gear] {
        var gear = allGear

        // Filtre par statut actif/inactif
        if !showInactive {
            gear = gear.filter { !$0.isInactive }
        }

        // Filtre par plongeur
        if !selectedDiver.isEmpty {
            gear = gear.filter { $0.diverName.trimmingCharacters(in: .whitespaces) == selectedDiver }
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
        .navigationTitle("")
        .searchable(text: $searchText, prompt: "Search equipment...")
        .animation(.easeInOut(duration: 0.3), value: searchText)
        .animation(.easeInOut(duration: 0.3), value: filterCategory)
        .animation(.easeInOut(duration: 0.3), value: showInactive)
        .toolbar { toolbarContent }
        .diverFilterReset(uniqueDivers: uniqueDivers, selectedDiver: $selectedDiver)
        .onChange(of: selectedDiver) {
            if let cat = filterCategory {
                let relevant = selectedDiver.isEmpty ? allGear : allGear.filter { $0.diverName == selectedDiver }
                if !relevant.contains(where: { $0.category == cat.rawValue }) {
                    filterCategory = nil
                }
            }
        }
        .sheet(isPresented: $showAddGear) {
            AddGearView()
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedGear) { gear in
            GearServiceView(gear: gear)
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showTankTemplates) {
            TankTemplateListView()
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showGearGroups) {
            GearGroupListView()
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.xml],
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        #if os(iOS)
        .fileExporter(
            isPresented: $showFileExporter,
            document: exportDocument,
            contentType: .xml,
            defaultFilename: exportFileName
        ) { _ in
            exportDocument = nil
        }
        #endif
        .alert("Import Successful", isPresented: $showImportSuccess) {
            Button("OK", role: .cancel) { }
        } message: {
            let base = String(
                format: NSLocalizedString("%1$lld gear item(s), %2$lld group(s), and %3$lld tank template(s) imported successfully.", bundle: Bundle.forAppLanguage(), comment: "Success message shown after importing gear items, gear groups, and tank templates from a gear XML file. Arguments: gear count, group count, template count."),
                importedCount,
                importedGroupCount,
                importedTemplateCount
            )
            if importedGroupMissingMemberCount > 0 {
                let warning = String(
                    format: NSLocalizedString("%lld group member(s) could not be matched and were skipped.", bundle: Bundle.forAppLanguage(), comment: "Warning appended to the import success message when some gear IDs referenced inside imported gear groups could not be matched to any existing or newly imported gear item."),
                    importedGroupMissingMemberCount
                )
                Text(verbatim: base + "\n" + warning)
            } else {
                Text(verbatim: base)
            }
        }
        .alert("Import error", isPresented: $showImportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(verbatim: importError ?? NSLocalizedString("An unknown error occurred.", bundle: Bundle.forAppLanguage(), comment: "Default error message shown in the import error alert when no specific error is available."))
        }

    }
    
    // MARK: - View Components
    
    @ViewBuilder
    private var contentSection: some View {
        if allGear.isEmpty {
            emptyStateView
                .transition(.opacity)
        } else if filteredGear.isEmpty && !selectedDiver.isEmpty && filterCategory == nil && searchText.isEmpty {
            noGearForDiverView
                .transition(.opacity)
        } else if filteredGear.isEmpty && filterCategory == nil {
            noResultsView
                .transition(.opacity)
        } else {
            // When filterCategory is active with no results, still show gearList so category chips remain accessible.
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

    private var noGearForDiverView: some View {
        ContentUnavailableView(
            "No Equipment for Diver",
            systemImage: "person.slash",
            description: Text("No equipment was found for the selected diver.")
        )
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
                    let diverBase = selectedDiver.isEmpty
                        ? allGear
                        : allGear.filter { $0.diverName.trimmingCharacters(in: .whitespaces) == selectedDiver }
                    ForEach(GearCategory.allCases) { category in
                        let count = diverBase.filter { $0.category == category.rawValue }.count
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
        DiverFilterToolbar(uniqueDivers: uniqueDivers, selectedDiver: $selectedDiver)

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
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button(action: { showTankTemplates = true }) {
                    Label("Tank Templates", systemImage: "cylinder.fill")
                }
                Button(action: { showGearGroups = true }) {
                    Label("Gear Groups", systemImage: "tray.2.fill")
                }
                Divider()
                Button {
                    exportGearToXML()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(allGear.isEmpty)
                Button {
                    showImportPicker = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
            } label: {
                Image(systemName: "ellipsis.circle.fill")
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

    @MainActor
    private func exportGearToXML() {
        let xml = GearXMLExporter.generateXML(for: allGear, groups: allGearGroups, tankTemplates: allTankTemplates)
        guard let data = xml.data(using: .utf8) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let datePart = formatter.string(from: Date())
        let fileName = "BlueDive_Gear_\(datePart).xml"

        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.xml]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
        #else
        exportDocument = ExportableFileDocument(data: data)
        exportFileName = fileName
        showFileExporter = true
        #endif
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            do {
                let data = try Data(contentsOf: url)
                let parser = GearXMLParser()
                guard let result = parser.parse(data: data), !result.isEmpty else {
                    importError = NSLocalizedString("No gear data found in the selected file.", bundle: Bundle.forAppLanguage(), comment: "Error message when the user imports a gear XML file that contains no gear items, groups, or tank templates.")
                    showImportError = true
                    return
                }

                // ── Gear Items ────────────────────────────────────────────────
                let existingGearIDs = Set(allGear.map(\.id))
                var gearByID: [UUID: Gear] = Dictionary(uniqueKeysWithValues: allGear.map { ($0.id, $0) })

                var count = 0
                for item in result.gearItems {
                    // Dedup by UUID; items from different devices with the same gear but different UUIDs
                    // will both be imported as separate entries.
                    guard !existingGearIDs.contains(item.id) else { continue }
                    let gear = Gear(
                        id: item.id,
                        name: item.name,
                        category: item.category,
                        manufacturer: item.manufacturer,
                        model: item.model,
                        serialNumber: item.serialNumber,
                        datePurchased: item.datePurchased,
                        purchasePrice: item.purchasePrice,
                        currency: item.currency,
                        purchasedFrom: item.purchasedFrom,
                        weightContribution: item.weightContribution,
                        weightContributionUnit: item.weightContributionUnit,
                        isInactive: item.isInactive,
                        diverName: item.diverName,
                        lastServiceDate: item.lastServiceDate,
                        nextServiceDue: item.nextServiceDue,
                        serviceHistory: item.serviceHistory,
                        gearNotes: item.gearNotes
                    )
                    modelContext.insert(gear)
                    gearByID[item.id] = gear
                    count += 1
                }

                // ── Gear Groups ───────────────────────────────────────────────
                let existingGroupIDs = Set(allGearGroups.map(\.id))
                var groupCount = 0
                var missingMemberCount = 0
                for parsedGroup in result.gearGroups {
                    guard !existingGroupIDs.contains(parsedGroup.id) else { continue }
                    let members = parsedGroup.gearIDs.compactMap { gearByID[$0] }
                    // Gear IDs that referenced items not in this import or existing store are dropped silently.
                    missingMemberCount += parsedGroup.gearIDs.count - members.count
                    let group = GearGroup(id: parsedGroup.id, name: parsedGroup.name, gear: members)
                    modelContext.insert(group)
                    groupCount += 1
                }

                // ── Tank Templates ────────────────────────────────────────────
                let existingTemplateIDs = Set(allTankTemplates.map(\.id))
                var templateCount = 0
                for parsedTemplate in result.tankTemplates {
                    guard !existingTemplateIDs.contains(parsedTemplate.id) else { continue }
                    let template = TankTemplate(
                        id: parsedTemplate.id,
                        name: parsedTemplate.name,
                        volume: parsedTemplate.volume,
                        workingPressure: parsedTemplate.workingPressure,
                        volumeUnit: parsedTemplate.volumeUnit,
                        pressureUnit: parsedTemplate.pressureUnit,
                        material: parsedTemplate.material,
                        format: parsedTemplate.format,
                        manufacturer: parsedTemplate.manufacturer,
                        model: parsedTemplate.model
                    )
                    modelContext.insert(template)
                    templateCount += 1
                }

                try? modelContext.save()
                importedCount = count
                importedGroupCount = groupCount
                importedTemplateCount = templateCount
                importedGroupMissingMemberCount = missingMemberCount
                showImportSuccess = true
            } catch {
                importError = error.localizedDescription
                showImportError = true
            }

        case .failure(let error):
            importError = error.localizedDescription
            showImportError = true
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

                if !gear.diverName.isEmpty {
                    Text(gear.diverName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
