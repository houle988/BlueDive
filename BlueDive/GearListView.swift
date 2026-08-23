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
    @Query private var allInsurances: [DivingInsurance]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale
    @Environment(FileImportCoordinator.self) private var importCoordinator
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
    @State private var importedGearOnly = false
    @State private var showImportSuccess = false
    @State private var showNothingToImport = false
    @State private var importedServiceDataOnly = false
    @State private var pendingGearCSVData: Data?
    @State private var pendingGearCSVFileName: String = ""
    @State private var csvFormatOptions = ImportFormatOptions()
    @State private var showGearCSVFormatPicker = false
    @State private var isImporting = false
    @State private var importProgressFileName: String = ""
    // Gear import preview state (shared by XML and CSV paths)
    @State private var showGearImportPreview = false
    @State private var pendingGearXMLResult: GearXMLParser.GearParseResult?
    @State private var pendingGearCSVItems: [GearXMLParser.ParsedGear]?
    @State private var gearImportPreviewNew: [ImportPreviewItem] = []
    @State private var gearImportPreviewDuplicates: [ImportPreviewItem] = []
    @State private var gearPreviewFileName: String = ""
    #if os(iOS)
    @State private var showFileExporter = false
    @State private var exportDocument: ExportableFileDocument?
    @State private var exportFileName: String = ""
    #endif

    // MARK: - Computed Properties

    private var uniqueDivers: [String] {
        DiverFilter.uniqueDivers(in: allDivesForFilter, gear: allGear, certifications: allCertificationsForFilter, insurances: allInsurances)
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
        let bundle = Bundle.forAppLanguage()
        // Resolve each localized sort key once (O(n)) rather than per comparison (O(n log n)).
        var sortKeys = [String: String](minimumCapacity: grouped.count)
        for key in grouped.keys {
            sortKeys[key] = GearCategory(exportKeyOrRawValue: key).map {
                NSLocalizedString("gear.category." + $0.rawValue, bundle: bundle, comment: "")
            } ?? key
        }
        return grouped.sorted {
            (sortKeys[$0.key] ?? $0.key).compare(sortKeys[$1.key] ?? $1.key, locale: locale) == .orderedAscending
        }
    }

    private var sortedCategories: [GearCategory] {
        GearCategory.sorted(for: locale)
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

    private var xmlImportBaseMessage: String {
        let gearPhrase: String
        if importedCount == 0 {
            gearPhrase = NSLocalizedString("0 gear items", bundle: Bundle.forAppLanguage(), comment: "Noun phrase for zero gear items in the XML import success message.")
        } else if importedCount == 1 {
            gearPhrase = NSLocalizedString("1 gear item", bundle: Bundle.forAppLanguage(), comment: "Noun phrase for one gear item in the XML import success message.")
        } else {
            gearPhrase = String(format: NSLocalizedString("%lld gear items", bundle: Bundle.forAppLanguage(), comment: "Noun phrase for multiple gear items in the XML import success message."), importedCount)
        }
        let groupPhrase: String
        if importedGroupCount == 0 {
            groupPhrase = NSLocalizedString("0 groups", bundle: Bundle.forAppLanguage(), comment: "Noun phrase for zero groups in the XML import success message.")
        } else if importedGroupCount == 1 {
            groupPhrase = NSLocalizedString("1 group", bundle: Bundle.forAppLanguage(), comment: "Noun phrase for one group in the XML import success message.")
        } else {
            groupPhrase = String(format: NSLocalizedString("%lld groups", bundle: Bundle.forAppLanguage(), comment: "Noun phrase for multiple groups in the XML import success message."), importedGroupCount)
        }
        let templatePhrase: String
        if importedTemplateCount == 0 {
            templatePhrase = NSLocalizedString("0 tank templates", bundle: Bundle.forAppLanguage(), comment: "Noun phrase for zero tank templates in the XML import success message.")
        } else if importedTemplateCount == 1 {
            templatePhrase = NSLocalizedString("1 tank template", bundle: Bundle.forAppLanguage(), comment: "Noun phrase for one tank template in the XML import success message.")
        } else {
            templatePhrase = String(format: NSLocalizedString("%lld tank templates", bundle: Bundle.forAppLanguage(), comment: "Noun phrase for multiple tank templates in the XML import success message."), importedTemplateCount)
        }
        return String(
            format: NSLocalizedString("%1$@, %2$@, and %3$@ imported successfully.", bundle: Bundle.forAppLanguage(), comment: "Sentence frame for the XML gear import success message. Arguments: gear noun phrase, group noun phrase, tank template noun phrase."),
            gearPhrase, groupPhrase, templatePhrase
        )
    }

    private var xmlImportWarning: String? {
        guard importedGroupMissingMemberCount > 0 else { return nil }
        return importedGroupMissingMemberCount == 1
            ? NSLocalizedString("1 group member could not be matched and was skipped.", bundle: Bundle.forAppLanguage(), comment: "Warning when exactly one gear group member could not be matched and was skipped during import.")
            : String(format: NSLocalizedString("%lld group members could not be matched and were skipped.", bundle: Bundle.forAppLanguage(), comment: "Warning when multiple gear group members could not be matched and were skipped during import."), importedGroupMissingMemberCount)
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
        .overlay {
            if isImporting {
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView().tint(.cyan).scaleEffect(1.5)
                        Text("Importing...")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if !importProgressFileName.isEmpty {
                            Text(verbatim: importProgressFileName)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(32)
                    .background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isImporting)
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
        .sheet(isPresented: $showGearCSVFormatPicker) {
            ImportFormatPickerView(
                options: $csvFormatOptions,
                fileType: .gearCSV,
                fileName: pendingGearCSVFileName,
                onConfirm: {
                    showGearCSVFormatPicker = false
                    importProgressFileName = pendingGearCSVFileName
                    isImporting = true
                    commitGearCSVImport()
                },
                onCancel: {
                    showGearCSVFormatPicker = false
                    pendingGearCSVData = nil
                    pendingGearCSVFileName = ""
                    importProgressFileName = ""
                }
            )
            .presentationSizing(.page)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showGearImportPreview) {
            ImportPreviewSheet(
                icon: "compass.drawing",
                iconColor: .cyan,
                newItems: gearImportPreviewNew,
                duplicateItems: gearImportPreviewDuplicates,
                fileName: gearPreviewFileName,
                onImport: {
                    if pendingGearXMLResult != nil {
                        commitGearXMLImport()
                    } else {
                        commitGearCSVActualImport()
                    }
                },
                onCancel: {
                    showGearImportPreview = false
                    pendingGearXMLResult = nil
                    pendingGearCSVItems = nil
                    gearImportPreviewNew = []
                    gearImportPreviewDuplicates = []
                }
            )
            .presentationSizing(.page)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: showGearImportPreview) { _, isShown in
            if !isShown {
                pendingGearXMLResult = nil
                pendingGearCSVItems = nil
                gearImportPreviewNew = []
                gearImportPreviewDuplicates = []
                gearPreviewFileName = ""
            }
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.xml, .commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        #if os(iOS)
        .fileExporter(
            isPresented: $showFileExporter,
            document: exportDocument,
            contentType: .blueDiveXML,
            defaultFilename: exportFileName
        ) { _ in
            exportDocument = nil
        }
        #endif
        .alert("Import Successful", isPresented: $showImportSuccess) {
            Button("OK", role: .cancel) { }
        } message: {
            // importedServiceDataOnly must be checked before importedGearOnly: on the CSV path
            // both flags are true simultaneously when the only change was a service data sync.
            if importedServiceDataOnly {
                Text("Service records updated for existing gear.")
            } else if importedGearOnly {
                Text(verbatim: importedCount == 0
                    ? NSLocalizedString("0 gear items imported successfully.", bundle: Bundle.forAppLanguage(), comment: "Success message shown when a gear CSV import completes but all items already existed.")
                    : importedCount == 1
                    ? NSLocalizedString("1 gear item imported successfully.", bundle: Bundle.forAppLanguage(), comment: "Success message shown after importing exactly one gear item.")
                    : String(format: NSLocalizedString("%lld gear items imported successfully.", bundle: Bundle.forAppLanguage(), comment: "Success message shown after importing gear items from a MacDive CSV file."), importedCount))
            } else if let warning = xmlImportWarning {
                Text(verbatim: xmlImportBaseMessage + "\n" + warning)
            } else {
                Text(verbatim: xmlImportBaseMessage)
            }
        }
        .alert("Nothing to Import", isPresented: $showNothingToImport) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("All gear, groups, and tank templates in the file already exist.")
        }
        .alert("Import error", isPresented: $showImportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(verbatim: importError ?? NSLocalizedString("An unknown error occurred.", bundle: Bundle.forAppLanguage(), comment: "Default error message shown in the import error alert when no specific error is available."))
        }
        .onAppear {
            if let pending = importCoordinator.pendingGearXML {
                importCoordinator.pendingGearXML = nil
                handleGearXMLData(pending.data, fileName: pending.fileName)
            }
        }
        .onChange(of: importCoordinator.pendingGearXML) { _, newValue in
            guard let pending = newValue else { return }
            importCoordinator.pendingGearXML = nil
            handleGearXMLData(pending.data, fileName: pending.fileName)
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
        // .sidebar is required for Section(isExpanded:) collapse/expand to function
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
                    ForEach(sortedCategories) { category in
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
        let fileName = "BlueDive_Gear_\(datePart).bluedive"

        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.blueDiveXML]
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
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                if accessing { url.stopAccessingSecurityScopedResource() }
                importError = error.localizedDescription
                showImportError = true
                return
            }
            if accessing { url.stopAccessingSecurityScopedResource() }

            // ── CSV path: show weight-unit picker before importing ─────────────
            if url.pathExtension.lowercased() == "csv" {
                pendingGearCSVData = data
                pendingGearCSVFileName = url.lastPathComponent
                csvFormatOptions = ImportFormatOptions()
                showGearCSVFormatPicker = true
                return
            }

            // ── XML path: parse on background thread, then show preview ───────
            let fileName = url.lastPathComponent
            importProgressFileName = fileName
            isImporting = true

            Task {
                do {
                    let parsed: GearXMLParser.GearParseResult = try await withCheckedThrowingContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            let parser = GearXMLParser()
                            guard let result = parser.parse(data: data), !result.isEmpty else {
                                continuation.resume(throwing: ImportError.parsingFailed)
                                return
                            }
                            continuation.resume(returning: result)
                        }
                    }

                    await MainActor.run {
                        isImporting = false
                        importProgressFileName = ""
                        let (newGear, dupGear) = classifyGearItems(parsed.gearItems)

                        let existingGroupIDs = Set(allGearGroups.map(\.id))
                        let newGroups = parsed.gearGroups.filter { !existingGroupIDs.contains($0.id) }
                        let dupGroups = parsed.gearGroups.filter { existingGroupIDs.contains($0.id) }

                        let existingTemplateIDs = Set(allTankTemplates.map(\.id))
                        let newTemplates = parsed.tankTemplates.filter { !existingTemplateIDs.contains($0.id) }
                        let dupTemplates = parsed.tankTemplates.filter { existingTemplateIDs.contains($0.id) }

                        // Nothing genuinely new: bypass the preview so service-data updates
                        // on duplicate gear items are still committed.
                        if newGear.isEmpty && newGroups.isEmpty && newTemplates.isEmpty {
                            pendingGearXMLResult = parsed
                            commitGearXMLImport()
                            return
                        }

                        let bundle = Bundle.forAppLanguage()
                        let groupLabel = NSLocalizedString("Gear Group", bundle: bundle, comment: "Type label for a gear group in the import preview detail")
                        let templateLabel = NSLocalizedString("Tank Template", bundle: bundle, comment: "Type label for a tank template in the import preview detail")
                        gearImportPreviewNew = makeGearPreviewItems(newGear)
                            + newGroups.map { ImportPreviewItem(name: $0.name, detail: groupLabel) }
                            + newTemplates.map { ImportPreviewItem(name: $0.name, detail: templateLabel) }
                        gearImportPreviewDuplicates = makeGearPreviewItems(dupGear)
                            + dupGroups.map { ImportPreviewItem(name: $0.name, detail: groupLabel) }
                            + dupTemplates.map { ImportPreviewItem(name: $0.name, detail: templateLabel) }
                        pendingGearXMLResult = parsed
                        gearPreviewFileName = fileName
                        showGearImportPreview = true
                    }
                } catch {
                    await MainActor.run {
                        isImporting = false
                        importProgressFileName = ""
                        importError = NSLocalizedString("No gear data found in the selected file.", bundle: Bundle.forAppLanguage(), comment: "Error message when the user imports a gear XML file that contains no gear items, groups, or tank templates.")
                        showImportError = true
                    }
                }
            }

        case .failure(let error):
            importError = error.localizedDescription
            showImportError = true
        }
    }

    /// Processes a Gear XML payload delivered via file association (coordinator path).
    /// Mirrors the XML branch of handleImportResult but accepts pre-loaded Data.
    func handleGearXMLData(_ data: Data, fileName: String) {
        guard !showGearImportPreview, !isImporting else { return }
        importProgressFileName = fileName
        isImporting = true

        Task {
            do {
                let parsed: GearXMLParser.GearParseResult = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let parser = GearXMLParser()
                        guard let result = parser.parse(data: data), !result.isEmpty else {
                            continuation.resume(throwing: ImportError.parsingFailed)
                            return
                        }
                        continuation.resume(returning: result)
                    }
                }

                await MainActor.run {
                    isImporting = false
                    importProgressFileName = ""
                    let (newGear, dupGear) = classifyGearItems(parsed.gearItems)

                    let existingGroupIDs = Set(allGearGroups.map(\.id))
                    let newGroups = parsed.gearGroups.filter { !existingGroupIDs.contains($0.id) }
                    let dupGroups = parsed.gearGroups.filter { existingGroupIDs.contains($0.id) }

                    let existingTemplateIDs = Set(allTankTemplates.map(\.id))
                    let newTemplates = parsed.tankTemplates.filter { !existingTemplateIDs.contains($0.id) }
                    let dupTemplates = parsed.tankTemplates.filter { existingTemplateIDs.contains($0.id) }

                    if newGear.isEmpty && newGroups.isEmpty && newTemplates.isEmpty {
                        pendingGearXMLResult = parsed
                        commitGearXMLImport()
                        return
                    }

                    let bundle = Bundle.forAppLanguage()
                    let groupLabel = NSLocalizedString("Gear Group", bundle: bundle, comment: "Type label for a gear group in the import preview detail")
                    let templateLabel = NSLocalizedString("Tank Template", bundle: bundle, comment: "Type label for a tank template in the import preview detail")
                    gearImportPreviewNew = makeGearPreviewItems(newGear)
                        + newGroups.map { ImportPreviewItem(name: $0.name, detail: groupLabel) }
                        + newTemplates.map { ImportPreviewItem(name: $0.name, detail: templateLabel) }
                    gearImportPreviewDuplicates = makeGearPreviewItems(dupGear)
                        + dupGroups.map { ImportPreviewItem(name: $0.name, detail: groupLabel) }
                        + dupTemplates.map { ImportPreviewItem(name: $0.name, detail: templateLabel) }
                    pendingGearXMLResult = parsed
                    gearPreviewFileName = fileName
                    showGearImportPreview = true
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    importProgressFileName = ""
                    importError = NSLocalizedString("No gear data found in the selected file.", bundle: Bundle.forAppLanguage(), comment: "Error message when the user imports a gear XML file that contains no gear items, groups, or tank templates.")
                    showImportError = true
                }
            }
        }
    }

    private func commitGearCSVImport() {
        guard let data = pendingGearCSVData else { return }
        pendingGearCSVData = nil
        let fileName = pendingGearCSVFileName
        pendingGearCSVFileName = ""
        let diverName = ""
        let weightFormat = csvFormatOptions.weightFormat

        Task {
            let items: [GearXMLParser.ParsedGear]? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let csvParser = GearCSVParser()
                    continuation.resume(returning: csvParser.parse(data: data, diverName: diverName, weightUnit: weightFormat))
                }
            }

            await MainActor.run {
                importProgressFileName = ""
                isImporting = false

                guard let items else {
                    importError = NSLocalizedString("No gear data found in the selected file.", bundle: Bundle.forAppLanguage(), comment: "Error message when the user imports a gear XML file that contains no gear items, groups, or tank templates.")
                    showImportError = true
                    return
                }
                guard !items.isEmpty else {
                    showNothingToImport = true
                    return
                }

                let (newGear, dupGear) = classifyGearItems(items)
                // No new gear items: bypass the preview so service-data updates
                // on duplicates still get committed.
                if newGear.isEmpty {
                    pendingGearCSVItems = items
                    commitGearCSVActualImport()
                    return
                }
                gearImportPreviewNew = makeGearPreviewItems(newGear)
                gearImportPreviewDuplicates = makeGearPreviewItems(dupGear)
                pendingGearCSVItems = items
                gearPreviewFileName = fileName
                showGearImportPreview = true
            }
        }
    }

    /// Commits the pending gear CSV import after the user confirms the preview.
    @MainActor
    private func commitGearCSVActualImport() {
        guard let items = pendingGearCSVItems else { return }
        pendingGearCSVItems = nil
        showGearImportPreview = false
        gearImportPreviewNew = []
        gearImportPreviewDuplicates = []

        var gearByID: [UUID: Gear] = Dictionary(uniqueKeysWithValues: allGear.map { ($0.id, $0) })
        let (count, anyGearUpdated) = insertGearItems(items, into: &gearByID)
        try? modelContext.save()
        importedCount = count
        importedGroupCount = 0
        importedTemplateCount = 0
        importedGroupMissingMemberCount = 0
        importedGearOnly = true
        importedServiceDataOnly = count == 0 && anyGearUpdated
        if count > 0 || anyGearUpdated {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                showImportSuccess = true
            }
        } else {
            showNothingToImport = true
        }
    }

    // MARK: - Gear Import Helpers

    private func makeGearPreviewItems(_ items: [GearXMLParser.ParsedGear]) -> [ImportPreviewItem] {
        let bundle = Bundle.forAppLanguage()
        return items.map { item in
            let category = GearCategory(exportKeyOrRawValue: item.category)
                .map { NSLocalizedString("gear.category." + $0.rawValue, bundle: bundle, comment: "") }
                ?? item.category
            let detail = item.diverName.isEmpty ? category : "\(category) • \(item.diverName)"
            return ImportPreviewItem(name: item.name, detail: detail)
        }
    }

    /// Classifies gear items as new vs duplicate without inserting anything.
    private func classifyGearItems(_ items: [GearXMLParser.ParsedGear]) -> (new: [GearXMLParser.ParsedGear], duplicates: [GearXMLParser.ParsedGear]) {
        var gearByID = Dictionary(uniqueKeysWithValues: allGear.map { ($0.id, $0) })
        var new: [GearXMLParser.ParsedGear] = []
        var duplicates: [GearXMLParser.ParsedGear] = []
        for item in items {
            if gearByID[item.id] != nil ||
                gearByID.values.contains(where: { $0.matches(name: item.name, category: item.category, diverName: item.diverName, serial: item.serialNumber) }) {
                duplicates.append(item)
            } else {
                // Mirror insertGearItems: track accepted items so intra-file duplicates
                // (same gear listed twice) are classified consistently with what commit will do.
                let placeholder = Gear(
                    id: item.id, name: item.name, category: item.category,
                    manufacturer: item.manufacturer, model: item.model,
                    serialNumber: item.serialNumber, datePurchased: item.datePurchased,
                    purchasePrice: item.purchasePrice, currency: item.currency,
                    purchasedFrom: item.purchasedFrom,
                    weightContribution: item.weightContribution,
                    weightContributionUnit: item.weightContributionUnit,
                    isInactive: item.isInactive, diverName: item.diverName,
                    lastServiceDate: item.lastServiceDate, nextServiceDue: item.nextServiceDue,
                    serviceHistory: item.serviceHistory, gearNotes: item.gearNotes
                )
                gearByID[item.id] = placeholder
                new.append(item)
            }
        }
        return (new, duplicates)
    }

    /// Commits the pending gear XML import after the user confirms the preview.
    @MainActor
    private func commitGearXMLImport() {
        guard let parsed = pendingGearXMLResult else { return }
        pendingGearXMLResult = nil
        showGearImportPreview = false
        gearImportPreviewNew = []
        gearImportPreviewDuplicates = []

        var gearByID: [UUID: Gear] = Dictionary(uniqueKeysWithValues: allGear.map { ($0.id, $0) })
        let (count, anyGearUpdated) = insertGearItems(parsed.gearItems, into: &gearByID)

        // ── Gear Groups ───────────────────────────────────────────────────────
        let existingGroupIDs = Set(allGearGroups.map(\.id))
        var groupCount = 0
        var missingMemberCount = 0
        for parsedGroup in parsed.gearGroups {
            guard !existingGroupIDs.contains(parsedGroup.id) else { continue }
            let members = parsedGroup.gearIDs.compactMap { gearByID[$0] }
            missingMemberCount += parsedGroup.gearIDs.count - members.count
            let group = GearGroup(id: parsedGroup.id, name: parsedGroup.name, gear: members)
            modelContext.insert(group)
            groupCount += 1
        }

        // ── Tank Templates ────────────────────────────────────────────────────
        let existingTemplateIDs = Set(allTankTemplates.map(\.id))
        var templateCount = 0
        for parsedTemplate in parsed.tankTemplates {
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
        importedGearOnly = false
        importedServiceDataOnly = count == 0 && groupCount == 0 && templateCount == 0 && anyGearUpdated
        if count == 0 && groupCount == 0 && templateCount == 0 && !anyGearUpdated {
            showNothingToImport = true
        } else {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                showImportSuccess = true
            }
        }
    }

    /// Inserts gear items not already present, updating `gearByID` after each insert
    /// so subsequent lookups (e.g. group membership) see newly added items.
    /// Returns the count of newly inserted items and whether any existing item had service data updated.
    private func insertGearItems(_ items: [GearXMLParser.ParsedGear], into gearByID: inout [UUID: Gear]) -> (inserted: Int, anyUpdated: Bool) {
        var count = 0
        var anyUpdated = false
        for item in items {
            // Primary dedup: by UUID (same source device, same export).
            if let existing = gearByID[item.id] {
                if existing.syncServiceData(importedDate: item.lastServiceDate, importedHistory: item.serviceHistory) {
                    anyUpdated = true
                }
                continue
            }
            // Secondary dedup: by name + category + diverName + serial — catches gear previously
            // imported via a dive XML, which assigned a fresh UUID instead of the canonical one,
            // and also handles CSV imports that always assign a fresh UUID.
            if let existing = gearByID.values.first(where: {
                $0.matches(name: item.name, category: item.category, diverName: item.diverName, serial: item.serialNumber)
            }) {
                if existing.syncServiceData(importedDate: item.lastServiceDate, importedHistory: item.serviceHistory) {
                    anyUpdated = true
                }
                gearByID[item.id] = existing
                continue
            }
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
        return (inserted: count, anyUpdated: anyUpdated)
    }
}

// MARK: - Gear Row

struct GearRow: View {
    let gear: Gear
    
    var body: some View {
        HStack(spacing: 15) {
            GearIconView(manufacturer: gear.manufacturer, category: gear.gearCategory)
            
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
            Label(Double(gear.totalDivesCount).localizedString(decimals: 0), systemImage: "water.waves")
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
                    Text(verbatim: Double(count).localizedString(decimals: 0))
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
