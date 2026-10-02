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
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale
    @Environment(FileImportCoordinator.self) private var importCoordinator
    @Environment(DiveStore.self) private var store
    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""

    @State private var showAddGear = false
    @State private var selectedGear: Gear?
    /// Gear opened in the edit sheet from a row's context menu.
    @State private var gearToEdit: Gear?
    /// Gear awaiting confirmation after Delete was chosen in a row's context menu.
    @State private var gearToDelete: Gear?
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

    // DiveStore's complete diver list (dives, gear, certifications, insurance), kept current
    // by DiverSourcesFeeder — no local recomputation over every dive on each body pass.
    private var uniqueDivers: [String] { store.cachedUniqueDivers }

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
                        ProgressView().scaleEffect(1.5)
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
                .standardSheetPresentation()
        }
        .sheet(item: $selectedGear) { gear in
            GearServiceView(gear: gear)
                .standardSheetPresentation()
        }
        .sheet(item: $gearToEdit) { gear in
            EditGearView(gear: gear)
                .standardSheetPresentation()
        }
        // Right-click / long-press Delete asks first: a menu item is easier to hit by
        // accident than a deliberate swipe (which deletes at once, as before).
        .alert(
            "Delete equipment?",
            isPresented: Binding(
                get: { gearToDelete != nil },
                set: { if !$0 { gearToDelete = nil } }
            ),
            presenting: gearToDelete
        ) { gear in
            Button("Cancel", role: .cancel) { gearToDelete = nil }
            Button("Delete", role: .destructive) {
                deleteGear(gear)
                gearToDelete = nil
            }
        } message: { gear in
            Text(verbatim: String(format: NSLocalizedString("Are you sure you want to delete \"%@\"? This action cannot be undone.", bundle: Bundle.forAppLanguage(), value: "Are you sure you want to delete \"%@\"? This action cannot be undone.", comment: "Delete confirmation alert message."), gear.name))
        }
        .sheet(isPresented: $showTankTemplates) {
            TankTemplateListView()
                .standardSheetPresentation()
        }
        .sheet(isPresented: $showGearGroups) {
            GearGroupListView()
                .standardSheetPresentation()
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
            .standardSheetPresentation()
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
            .standardSheetPresentation()
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
            systemImage: "wrench.and.screwdriver",
            description: Text("Add your tanks, suits, and regulators to track their usage and maintenance.")
        )
    }

    private var noResultsView: some View {
        ContentUnavailableView.search(text: searchText)
    }

    private var noGearForDiverView: some View {
        NoEntriesForDiverView(
            title: Text(verbatim: String(format: NSLocalizedString("No Equipment for %@", bundle: Bundle.forAppLanguage(), value: "No Equipment for %@", comment: "Empty-state title when the selected diver has no gear; %@ is the diver's name"), selectedDiver)),
            description: Text(verbatim: String(format: NSLocalizedString("No equipment was found for %@.", bundle: Bundle.forAppLanguage(), value: "No equipment was found for %@.", comment: "Empty-state description when the selected diver has no gear; %@ is the diver's name"), selectedDiver))
        )
    }
    
    /// Banner colour: red when any gear is overdue, orange when only approaching.
    private var bannerColor: Color {
        gearOverdue.isEmpty ? .orange : .red
    }

    private var serviceAlertBanner: some View {
        HStack {
            Image(systemName: gearOverdue.isEmpty ? "exclamationmark.triangle" : "xmark.shield")
                .foregroundStyle(bannerColor)
                .accessibilityHidden(true)

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
                        // Right-click (macOS) / long-press (iOS): the way to delete with a mouse
                        // that cannot swipe; also opens or edits the item.
                        .contextMenu {
                            Button { selectedGear = item } label: {
                                Label("View Details", systemImage: "eye")
                            }
                            Button { gearToEdit = item } label: {
                                Label("Edit Equipment", systemImage: "pencil")
                            }
                            Divider()
                            Button(role: .destructive) {
                                gearToDelete = item
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        #if os(macOS)
                        // macOS does not synthesize swipe-to-delete from .onDelete (iOS does): add it
                        // explicitly, routed through the same handler as .onDelete.
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                if let index = items.firstIndex(of: item) {
                                    deleteGear(items: items, at: IndexSet(integer: index))
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                        #endif
                    }
                    .onDelete { indexSet in
                        deleteGear(items: items, at: indexSet)
                    }
                } header: {
                    HStack {
                        if let gearCategory = GearCategory.allCases.first(where: { $0.rawValue == category }) {
                            Image(systemName: gearCategory.icon)
                                .accessibilityHidden(true)
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
    
    /// "All" plus one chip per category that has gear for the selected diver.
    @ViewBuilder
    private var categoryChips: some View {
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

    private var categoryChipScrollView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                categoryChips
            }
            .padding(.horizontal, 4)
        }
    }


    private var categoryFilterSection: some View {
        Section {
            // One sideways-scrolling row on both platforms (a wrapping layout would not get
            // its full height inside this List row).
            #if os(macOS)
            // A mouse without horizontal scrolling can't swipe the row: ‹ › buttons page
            // through it, shown only when the chips don't all fit.
            ChipRowScrollButtons(row: categoryChipScrollView)
            #else
            categoryChipScrollView
            #endif
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

        #if os(macOS)
        // One ToolbarItemGroup so macOS shares a single glass capsule, as the iOS
        // navigation bar does; separate items (especially menus) get separate capsules.
        ToolbarItemGroup(placement: .primaryAction) {
            if inactiveCount > 0 {
                inactiveToggleButton
            }
            addGearButton
            gearMoreMenu
                .toolbarMenuIndicatorHiddenOnMac()
        }
        #else
        if inactiveCount > 0 {
            ToolbarItem(placement: .primaryAction) {
                inactiveToggleButton
            }
        }
        ToolbarItem(placement: .primaryAction) {
            addGearButton
        }
        ToolbarItem(placement: .primaryAction) {
            gearMoreMenu
        }
        #endif
    }

    // Toolbar controls, shared by the iOS and macOS toolbar layouts above.

    private var inactiveToggleButton: some View {
        Button {
            withAnimation {
                showInactive.toggle()
            }
        } label: {
            Image(systemName: showInactive ? "eye" : "eye.slash")
                .font(.title3)
                .foregroundStyle(showInactive ? .cyan : .secondary)
        }
        .help(showInactive
              ? NSLocalizedString("Hide Inactive Equipment", bundle: Bundle.forAppLanguage(), comment: "")
              : NSLocalizedString("Show Inactive Equipment", bundle: Bundle.forAppLanguage(), comment: ""))
        .accessibilityLabel(showInactive ? Text("Hide Inactive Equipment") : Text("Show Inactive Equipment"))
    }

    private var addGearButton: some View {
        Button {
            showAddGear = true
        } label: {
            Image(systemName: "plus")
                .foregroundStyle(.cyan)
        }
        .accessibilityLabel(Text("Add Equipment"))
    }

    private var gearMoreMenu: some View {
        Menu {
            Button(action: { showTankTemplates = true }) {
                Label("Tank Templates", systemImage: "cylinder")
            }
            Button(action: { showGearGroups = true }) {
                Label("Gear Groups", systemImage: "tray.2")
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
            Image(systemName: "ellipsis")
                .foregroundStyle(.cyan)
        }
        .accessibilityLabel(Text("More"))
    }

    // MARK: - Actions
    
    /// Deletes one gear item (context-menu Delete, after confirmation), with the same steps
    /// as swipe-to-delete.
    private func deleteGear(_ gear: Gear) {
        deleteGear(items: [gear], at: IndexSet(integer: 0))
    }

    private func deleteGear(items: [Gear], at offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                let itemToDelete = items[index]
                NotificationManager.shared.cancelGearReminder(id: itemToDelete.id)
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
        #if os(macOS)
        // The Mac window is wide: one compact line (name, weight, dives, diver, service),
        // falling back to the stacked iOS row when the window is too narrow.
        ViewThatFits(in: .horizontal) {
            wideRow
            stackedRow
        }
        #else
        stackedRow
        #endif
    }

    /// Icon, then name / weight + dives / diver on three lines, service indicator trailing.
    private var stackedRow: some View {
        HStack(spacing: 15) {
            GearIconView(manufacturer: gear.manufacturer, category: gear.gearCategory)
            
            // Informations
            VStack(alignment: .leading, spacing: 4) {
                nameLine
                
                gearDetails

                if !gear.diverName.isEmpty {
                    diverText
                }
            }

            Spacer()

            serviceIndicator
        }
        .padding(.vertical, 8)
    }

    #if os(macOS)
    /// One line (macOS): icon, then name, weight, dives, diver and service indicator next to
    /// each other, left-aligned, so every detail stays close to the name it belongs to.
    private var wideRow: some View {
        HStack(spacing: 15) {
            GearIconView(manufacturer: gear.manufacturer, category: gear.gearCategory)

            HStack(spacing: 16) {
                nameLine
                weightText
                divesLabel
                if !gear.diverName.isEmpty {
                    diverText
                }
                serviceIndicator
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
    #endif

    /// Active/inactive dot and the gear name.
    private var nameLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(gear.isInactive ? .red : .green)
                .frame(width: 8, height: 8)
                .accessibilityLabel(gear.isInactive ? Text("Inactive") : Text("Active"))

            Text(gear.name)
                .font(.headline)
                .foregroundStyle(gear.isInactive ? .secondary : .primary)
        }
    }

    private var diverText: some View {
        Text(gear.diverName)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// Indicateur d'entretien — orange within 30 days, red when due/past
    @ViewBuilder
    private var serviceIndicator: some View {
        if let indicatorColor = serviceIndicatorColor {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(indicatorColor)
                .font(.title3)
                .accessibilityLabel(indicatorColor == .red ? Text("Service Overdue") : Text("Service Due Soon"))
        }
    }
    
    @ViewBuilder
    private var gearDetails: some View {
        HStack(spacing: 8) {
            weightText
            divesLabel
        }
    }

    // Poids
    @ViewBuilder
    private var weightText: some View {
        if gear.weightContribution > 0 {
            Text("• \(UserPreferences.shared.weightUnit.formatted(gear.weightContribution, from: WeightUnit.from(importFormat: gear.weightContributionUnit ?? UserPreferences.shared.weightUnit.symbol)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // Nombre de plongées
    private var divesLabel: some View {
        Label(Double(gear.totalDivesCount).localizedString(decimals: 0), systemImage: "water.waves")
            .font(.caption)
            .foregroundStyle(.cyan)
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
                    .accessibilityHidden(true)

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
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#if os(macOS)
/// ‹ › buttons around a horizontally scrolling chip row (macOS), shown only when the chips
/// don't all fit; each click scrolls most of the visible width. A separate view so the
/// per-frame scroll geometry it tracks redraws only this row, not the whole Equipment list.
private struct ChipRowScrollButtons<Row: View>: View {
    /// The row's horizontal ScrollView.
    let row: Row

    @State private var position = ScrollPosition()
    @State private var metrics = ChipScrollMetrics()

    var body: some View {
        HStack(spacing: 6) {
            if metrics.overflows {
                scrollButton(forward: false)
            }
            row
                .scrollPosition($position)
                .onScrollGeometryChange(for: ChipScrollMetrics.self) { geometry in
                    ChipScrollMetrics(
                        offset: geometry.contentOffset.x,
                        visibleWidth: geometry.containerSize.width,
                        contentWidth: geometry.contentSize.width
                    )
                } action: { _, newMetrics in
                    metrics = newMetrics
                }
            if metrics.overflows {
                scrollButton(forward: true)
            }
        }
    }

    /// ‹ or › button, disabled at the start / end of the row.
    private func scrollButton(forward: Bool) -> some View {
        Button {
            let step = metrics.visibleWidth * 0.8
            let maxOffset = max(0, metrics.contentWidth - metrics.visibleWidth)
            let target = forward
                ? min(maxOffset, metrics.offset + step)
                : max(0, metrics.offset - step)
            withAnimation(.easeInOut(duration: 0.25)) {
                position.scrollTo(x: target)
            }
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.body.weight(.semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .borderlessButton()
        .disabled(forward ? metrics.atEnd : metrics.atStart)
        .accessibilityLabel(forward ? Text("Scroll Right") : Text("Scroll Left"))
    }
}

/// Scroll geometry of a chip row (macOS ‹ › buttons).
private struct ChipScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var visibleWidth: CGFloat = 0
    var contentWidth: CGFloat = 0

    /// The chips are wider than the row, so the buttons are shown.
    var overflows: Bool { contentWidth > visibleWidth + 1 }
    var atStart: Bool { offset <= 1 }
    var atEnd: Bool { offset + visibleWidth >= contentWidth - 1 }
}
#endif
