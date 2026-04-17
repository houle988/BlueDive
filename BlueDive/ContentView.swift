import SwiftUI
import SwiftData
import CoreBluetooth
import UniformTypeIdentifiers
import LibDCSwift
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension UTType {
    static let uddf = UTType(importedAs: "org.uddf.uddf")
}

struct ContentView: View {
    @Environment(\.modelContext) var modelContext
    @Query(sort: \Dive.timestamp, order: .reverse) var dives: [Dive]
    
    @State var showScannerSheet = false
    @State var showFileImporter = false
    @State var importError: ImportError?
    @State var showErrorAlert = false
    @State private var showDeleteConfirmation = false
    @State private var diveToDelete: IndexSet?
    @State private var diveToDeleteDirectly: Dive?
    @State private var showDeleteSingleConfirmation = false
    @State private var showDeleteSheet = false
    @State private var showToolsPopover = false
    @State var isImporting = false
    @State private var showExportMenu = false
    @State var exportDocument: ExportableFileDocument?
    @State var exportFileName: String = ""
    @State var showFileExporter = false
    @State var exportContentType: UTType = .xml
    @State private var showMergeDivesSheet = false
    @State private var showSettings = false
    @State private var showFingerprintDebug = false
    /// Bundles everything the import-format picker needs in a single optional.
    /// The sheet is driven by this value so SwiftUI always has the data ready
    /// at the moment it constructs the sheet body — avoiding the first-launch
    /// race where `pendingImportData` arrived after `showImportFormatPicker`
    /// was already set to `true`.
    struct PendingImport: Identifiable {
        let id = UUID()
        let url: URL
        let data: Data
        var formatOptions: ImportFormatOptions
        var fileType: ImportFileType = .macDive
    }
    @State var pendingImport: PendingImport?
    @State var importFormatOptions = ImportFormatOptions()
    @State private var showProfile = false

    @State private var showDiveTrips = false
    @State private var showRecordsWall = false
    @State private var showCalendarHeatmap = false
    @State private var showDashboard = false
    @State private var showTankTemplates = false
    @State private var showGearGroups = false
    @State private var isSyncing = false
    @State private var showManualDiveDatePicker = false
    @State private var manualDiveDate = Date.now

    // MARK: - Search & Filter State
    @State private var searchText = ""
    @State private var showFilterSheet = false
    @State private var filterYear: Int? = nil
    @State private var filterGasType: String? = nil
    @State private var filterMinDepth: Double = 0
    @State private var filterMinRating: Int = 0
    @State private var filterCountry: String? = nil
    @State private var filterDiveType: String? = nil
    @State private var filterTag: String? = nil
    @State private var filterDiverName: String? = nil
    @State private var filterMarineLife: String = ""
    @State private var sortOrder: DiveSortOrder = .dateDesc

    enum DiveSortOrder: String, CaseIterable, Identifiable {
        case dateDesc    = "dateDesc"
        case dateAsc     = "dateAsc"
        case depthDesc   = "depthDesc"
        case durationDesc = "durationDesc"
        case diveNumberDesc = "diveNumberDesc"
        var id: String { rawValue }
        var localizedTitle: LocalizedStringKey {
            switch self {
            case .dateDesc:       return "Date ↓"
            case .dateAsc:        return "Date ↑"
            case .depthDesc:      return "Depth ↓"
            case .durationDesc:   return "Duration ↓"
            case .diveNumberDesc: return "Dive # ↓"
            }
        }
    }
    
    // MARK: - Computed Properties

    private var availableYears: [Int] {
        let years = dives.compactMap { Calendar.current.dateComponents([.year], from: $0.timestamp).year }
        return Array(Set(years)).sorted(by: >)
    }

    private var availableGasTypes: [String] {
        let types = dives.map { $0.gasType }
        return Array(Set(types)).sorted()
    }

    private var availableCountries: [String] {
        let countries = dives.compactMap { $0.siteCountry }.filter { !$0.isEmpty }
        return Array(Set(countries)).sorted()
    }

    private var availableDiveTypes: [String] {
        var types = Set<String>()
        for dive in dives {
            dive.diveTypes?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .forEach { types.insert($0) }
        }
        return types.sorted()
    }

    private var availableTags: [String] {
        var tags = Set<String>()
        for dive in dives {
            dive.tags?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .forEach { tags.insert($0) }
        }
        return tags.sorted()
    }

    private var availableDiverNames: [String] {
        let names = dives.map { $0.diverName }.filter { !$0.isEmpty }
        return Array(Set(names)).sorted()
    }

    private var availableMarineLife: [String] {
        var species = Set<String>()
        for dive in dives {
            dive.seenFish?.forEach { sight in
                let name = sight.name.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { species.insert(name) }
            }
        }
        return species.sorted()
    }

    private var activeFilterCount: Int {
        var count = 0
        if filterYear != nil            { count += 1 }
        if filterGasType != nil         { count += 1 }
        if filterMinDepth > 0           { count += 1 }
        if filterMinRating > 0          { count += 1 }
        if filterCountry != nil         { count += 1 }
        if filterDiveType != nil        { count += 1 }
        if filterTag != nil             { count += 1 }
        if filterDiverName != nil       { count += 1 }
        if !filterMarineLife.isEmpty    { count += 1 }
        return count
    }

    private var filteredAndSortedDives: [Dive] {
        var result = dives.filter { dive in
            // Text search
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !query.isEmpty {
                let tagWords = dive.tags?
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? []
                let diveTypesWords = dive.diveTypes?
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? []
                let matches = dive.siteName.lowercased().contains(query)
                    || dive.location.lowercased().contains(query)
                    || dive.buddies.lowercased().contains(query)
                    || dive.diverName.lowercased().contains(query)
                    || (dive.siteCountry?.lowercased().contains(query) ?? false)
                    || diveTypesWords.contains(where: { $0.contains(query) })
                    || tagWords.contains(where: { $0.contains(query) })
                    || (dive.diveNumber.map { String($0) }?.contains(query) ?? false)
                if !matches { return false }
            }
            // Year filter
            if let year = filterYear {
                let diveYear = Calendar.current.component(.year, from: dive.timestamp)
                if diveYear != year { return false }
            }
            // Gas filter
            if let gas = filterGasType, dive.gasType != gas { return false }
            // Minimum depth filter — compare in display units
            if filterMinDepth > 0, dive.displayMaxDepth < filterMinDepth { return false }
            // Minimum rating filter
            if filterMinRating > 0, dive.rating < filterMinRating { return false }
            // Country filter
            if let country = filterCountry {
                guard let diveCountry = dive.siteCountry, diveCountry == country else { return false }
            }
            // Dive type filter
            if let diveType = filterDiveType {
                let allTypes = dive.diveTypes?
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
                if !allTypes.contains(diveType) { return false }
            }
            // Tag filter
            if let tag = filterTag {
                let diveTags = dive.tags?
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
                if !diveTags.contains(tag) { return false }
            }
            // Diver name filter
            if let name = filterDiverName, dive.diverName != name { return false }
            // Marine life filter
            if !filterMarineLife.isEmpty {
                let match = dive.seenFish?.contains { $0.name.localizedCaseInsensitiveContains(filterMarineLife) } ?? false
                if !match { return false }
            }
            return true
        }

        switch sortOrder {
        case .dateDesc:     result.sort { $0.timestamp > $1.timestamp }
        case .dateAsc:      result.sort { $0.timestamp < $1.timestamp }
        case .depthDesc:    result.sort { $0.displayMaxDepth > $1.displayMaxDepth }
        case .durationDesc: result.sort { $0.duration > $1.duration }
        case .diveNumberDesc: result.sort { ($0.diveNumber ?? 0) > ($1.diveNumber ?? 0) }
        }
        return result
    }

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [Color.blue.opacity(0.1), Color.platformBackground.opacity(0.8)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient.ignoresSafeArea()

                VStack(spacing: 0) {
                    contentSection
                }
            }

            #if os(iOS)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Site, location, buddy, country, type, tag, dive #…")
            #else
            .searchable(text: $searchText, prompt: "Site, location, buddy, country, type, tag, dive #…")
            #endif
            .animation(.easeInOut(duration: 0.3), value: searchText)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showFilterSheet) {
                DiveFilterSheet(
                    availableYears: availableYears,
                    availableGasTypes: availableGasTypes,
                    availableCountries: availableCountries,
                    availableDiveTypes: availableDiveTypes,
                    availableTags: availableTags,
                    availableDiverNames: availableDiverNames,
                    availableMarineLife: availableMarineLife,
                    filterYear: $filterYear,
                    filterGasType: $filterGasType,
                    filterMinDepth: $filterMinDepth,
                    filterMinRating: $filterMinRating,
                    filterCountry: $filterCountry,
                    filterDiveType: $filterDiveType,
                    filterTag: $filterTag,
                    filterDiverName: $filterDiverName,
                    filterMarineLife: $filterMarineLife,
                    sortOrder: $sortOrder
                )
                #if os(iOS)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                #endif
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showFingerprintDebug) { FingerprintDebugView() }
            .sheet(isPresented: $showProfile) { DiverProfileView() }

            .sheet(isPresented: $showDiveTrips) { DiveTripsView() }
            .sheet(isPresented: $showRecordsWall) { RecordsWallView() }
            .sheet(isPresented: $showCalendarHeatmap) { DiveCalendarHeatmapView() }
            .sheet(isPresented: $showDashboard) { DashboardView() }
            .sheet(isPresented: $showTankTemplates) {
                TankTemplateListView()
                    #if os(iOS)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    #endif
            }
            .sheet(isPresented: $showGearGroups) {
                GearGroupListView()
                    #if os(iOS)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    #endif
            }
            .sheet(isPresented: $showScannerSheet) { BluetoothScannerView() }
            #if os(macOS)
            .sheet(isPresented: $showDeleteSheet) {
                MacOSDeleteDiveSheet(
                    dives: filteredAndSortedDives,
                    onDelete: { dive in
                        diveToDeleteDirectly = dive
                        showDeleteSingleConfirmation = true
                    }
                )
            }
            #endif
            .sheet(isPresented: $showMergeDivesSheet) {
                MergeDivesSheet(dives: filteredAndSortedDives) { diveA, diveB in
                    mergeDives(diveA, with: diveB)
                }
            }
            #if os(iOS)
            .fileExporter(
                isPresented: $showFileExporter,
                document: exportDocument,
                contentType: exportContentType,
                defaultFilename: exportFileName
            ) { _ in
                exportDocument = nil
            }
            #endif
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.xml, .uddf],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result: result)
            }
            // Drive the sheet with the optional PendingImport so SwiftUI
            // constructs the sheet body only after all data is available.
            .sheet(item: $pendingImport) { pending in
                ImportFormatPickerView(
                    options: $importFormatOptions,
                    fileData: pending.data,
                    fileType: pending.fileType
                ) {
                    // Confirm: dismiss the picker then start the import.
                    let url = pending.url
                    let type = pending.fileType
                    pendingImport = nil
                    importDiveFile(from: url, formats: importFormatOptions, fileType: type)
                } onCancel: {
                    pendingImport = nil
                }
            }
            .alert("Import error", isPresented: $showErrorAlert, presenting: importError) { _ in
                Button("OK", role: .cancel) { }
            } message: { error in
                Text(error.localizedDescription)
            }
            .alert("Delete dive?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { diveToDelete = nil }
                Button("Delete", role: .destructive) {
                    if let offsets = diveToDelete { confirmDeleteItems(offsets: offsets) }
                    diveToDelete = nil
                }
            } message: {
                Text("This action is irreversible. All associated data (fish sightings, equipment) will also be deleted.")
            }
            .sheet(isPresented: $showManualDiveDatePicker) {
                #if os(iOS)
                NavigationStack {
                    Form {
                        DatePicker("Date & Time", selection: $manualDiveDate)
                            .datePickerStyle(.graphical)
                    }
                    .navigationTitle("New Dive Date")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showManualDiveDatePicker = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add") {
                                showManualDiveDatePicker = false
                                createManualDive(date: manualDiveDate)
                            }
                            .fontWeight(.semibold)
                        }
                    }
                }
                #else
                VStack(spacing: 0) {
                    HStack {
                        Button("Cancel") { showManualDiveDatePicker = false }
                            .keyboardShortcut(.cancelAction)
                        Spacer()
                        Text("New Dive Date")
                            .font(.headline)
                        Spacer()
                        Button("Add") {
                            showManualDiveDatePicker = false
                            createManualDive(date: manualDiveDate)
                        }
                        .keyboardShortcut(.defaultAction)
                        .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    DatePicker("Date", selection: $manualDiveDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .scaleEffect(1.5)
                        .frame(width: 380, height: 310)
                        .clipped()

                    Divider()

                    HStack {
                        Text("Time")
                            .foregroundStyle(.secondary)
                        Spacer()
                        DatePicker("", selection: $manualDiveDate, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.stepperField)
                            .labelsHidden()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(width: 390, height: 390)
                #endif
            }
            .alert("Delete dive?", isPresented: $showDeleteSingleConfirmation, presenting: diveToDeleteDirectly) { dive in
                Button("Cancel", role: .cancel) { diveToDeleteDirectly = nil }
                Button("Delete", role: .destructive) {
                    confirmDeleteSingleDive(dive)
                    diveToDeleteDirectly = nil
                }
            } message: { dive in
                Text("\"\(dive.siteName)\" will be permanently deleted. All associated data (fish sightings, equipment) will also be deleted.")
            }
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
                    }
                    .padding(32)
                    .background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isImporting)
    }
    
    // MARK: - View Components
    
    @ViewBuilder
    private var contentSection: some View {
        if dives.isEmpty {
            emptyStateView
                .transition(.opacity)
        } else {
            diveList
                .transition(.opacity)
        }
    }
    
    @State private var emptyStateAppeared = false

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "water.waves")
                .font(.system(size: 80))
                .foregroundStyle(.blue.opacity(0.5))
                .scaleEffect(emptyStateAppeared ? 1.0 : 0.5)
                .opacity(emptyStateAppeared ? 1.0 : 0.0)
            
            Text("Ready?")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
                .opacity(emptyStateAppeared ? 1.0 : 0.0)
                .offset(y: emptyStateAppeared ? 0 : 10)
            
            Text("Waiting for importing data...")
                .foregroundStyle(.gray)
                .opacity(emptyStateAppeared ? 1.0 : 0.0)
                .offset(y: emptyStateAppeared ? 0 : 10)
            
            Spacer()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                emptyStateAppeared = true
            }
        }
    }
    
    private var diveList: some View {
        let displayedDives = filteredAndSortedDives
        return Group {
            if displayedDives.isEmpty {
                // No results for search / filters
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 52))
                        .foregroundStyle(.secondary)
                    Text("No dives found")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Try other keywords or modify the filters.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    if activeFilterCount > 0 {
                        Button {
                            resetFilters()
                        } label: {
                            Label("Clear filters", systemImage: "xmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.cyan)
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                    Spacer()
                }
                .transition(.opacity)
            } else {
                List {
                    ForEach(displayedDives) { dive in
                        NavigationLink(destination: DiveDetailView(dive: dive)) {
                            DiveRowView(
                                dive: dive,
                                diveNumber: dives.count - (dives.firstIndex(of: dive) ?? 0)
                            )
                        }
                        .listRowBackground(Color.primary.opacity(0.07))
                        .contextMenu {
                            Button(role: .destructive) {
                                diveToDeleteDirectly = dive
                                showDeleteSingleConfirmation = true
                            } label: {
                                Label("Delete dive", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete(perform: deleteItems)
                }
                .scrollContentBackground(.hidden)
                .refreshable {
                    await forceiCloudSync()
                }
                #if os(iOS)
                .listStyle(.plain)
                .contentMargins(.top, 0, for: .scrollContent)
                #endif
            }
        }
    }
    
    // MARK: - Toolbar
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // ── Left: Settings + Bluetooth + Tools Menu ──────────────────────
        ToolbarItem(placement: .navigation) {
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.cyan)
            }
            .help("Settings")
        }

        ToolbarItem(placement: .navigation) {
            Button {
                Task { await forceiCloudSync() }
            } label: {
                if isSyncing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.cyan)
                } else {
                    Image(systemName: "icloud.fill")
                        .foregroundStyle(.cyan)
                }
            }
            .disabled(isSyncing)
            .help("Force sync with iCloud")
        }

        ToolbarItem(placement: .navigation) {
            toolsMenu
        }

        // ── Right ───────────────────────────────────────────────────────────

        #if os(macOS)
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: { showProfile = true }) {
                Image(systemName: "person.circle.fill")
                    .foregroundStyle(.cyan)
            }
            .help("Diver Profile")

            Button(action: { showFileImporter = true }) {
                Image(systemName: "doc.badge.plus")
                    .foregroundStyle(.cyan)
            }
            .help("Import Dives")

            Button(action: addManualDive) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.cyan)
            }
            .help("Add Dive Manually")

            Button(action: { showScannerSheet = true }) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.cyan)
            }
            .help("Sync Bluetooth Dive Computer")

            if !dives.isEmpty {
                exportMenuButton
                    .help("Export")
            }

            Button(action: { showMergeDivesSheet = true }) {
                Image(systemName: "arrow.triangle.merge")
                    .foregroundStyle(.cyan)
            }
            .help("Merge two dives")
            .disabled(dives.count < 2)

            Button(action: { showTankTemplates = true }) {
                Image(systemName: "cylinder.fill")
                    .foregroundStyle(.cyan)
            }
            .help("Tank Templates")

            Button(action: { showGearGroups = true }) {
                Image(systemName: "tray.2.fill")
                    .foregroundStyle(.cyan)
            }
            .help("Gear Groups")

            Button(action: { showFilterSheet = true }) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(activeFilterCount > 0 ? .orange : .cyan)
                    if activeFilterCount > 0 {
                        Text("\(activeFilterCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(3)
                            .background(Color.orange, in: Circle())
                            .offset(x: 6, y: -6)
                    }
                }
            }
            .help("Filter Dives")

            if !dives.isEmpty {
                Button(action: { showDeleteSheet = true }) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .help("Delete a dive")
            }
        }
        #else
        // iOS: + menu (Add/Import/Bluetooth) + Filter + overflow menu.
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 16) {
                Menu {
                    Button(action: addManualDive) {
                        Label("Add a dive (Manual)", systemImage: "plus.circle")
                    }
                    Button(action: { showScannerSheet = true }) {
                        Label("Add a dive (Bluetooth)", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    Button(action: { showFileImporter = true }) {
                        Label("Import", systemImage: "doc.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.cyan)
                }

                Button(action: { showFilterSheet = true }) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .foregroundStyle(activeFilterCount > 0 ? .orange : .cyan)
                        if activeFilterCount > 0 {
                            Text("\(activeFilterCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(3)
                                .background(Color.orange, in: Circle())
                                .offset(x: 6, y: -6)
                        }
                    }
                }

                Menu {
                    Button(action: { showProfile = true }) {
                        Label("Profile", systemImage: "person.circle.fill")
                    }
                    if !dives.isEmpty {
                        Divider()
                        Button(action: exportAllDivesToXML) {
                            Label("Export All Dives to XML", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                        Button(action: exportAllDivesToUDDF) {
                            Label("Export All Dives to UDDF", systemImage: "water.waves")
                        }
                    }
                    if dives.count >= 2 {
                        Button(action: { showMergeDivesSheet = true }) {
                            Label("Merge Dives", systemImage: "arrow.triangle.merge")
                        }
                    }
                    Divider()
                    Button(action: { showTankTemplates = true }) {
                        Label("Tank Templates", systemImage: "cylinder.fill")
                    }
                    Button(action: { showGearGroups = true }) {
                        Label("Gear Groups", systemImage: "tray.2.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .foregroundStyle(.cyan)
                }
            }
        }
        #endif
    }

    // Tools menu extracted to a property to avoid
    // @State capture issues in toolbar closures on macOS.
    private var toolsMenu: some View {
        #if os(macOS)
        Button(action: { showToolsPopover = true }) {
            Image(systemName: "square.grid.2x2.fill")
                .foregroundStyle(.cyan)
        }
        .help("Tools")
        .popover(isPresented: $showToolsPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                toolsPopoverButton("Stats", icon: "chart.bar.fill") {
                    showToolsPopover = false
                    showDashboard = true
                }
                Divider()
                toolsPopoverButton("My Trips", icon: "map.fill") {
                    showToolsPopover = false
                    showDiveTrips = true
                }
                Divider()
                toolsPopoverButton("Records Wall", icon: "medal.fill") {
                    showToolsPopover = false
                    showRecordsWall = true
                }
                Divider()
                toolsPopoverButton("Calendar", icon: "calendar") {
                    showToolsPopover = false
                    showCalendarHeatmap = true
                }
            }
            .frame(width: 220)
            .padding(.vertical, 4)
        }
        #else
        Menu {
            Button(action: { showDashboard = true }) {
                Label("Stats", systemImage: "chart.bar.fill")
            }
            Button(action: { showDiveTrips = true }) {
                Label("My Trips", systemImage: "map.fill")
            }
            Divider()
            Button(action: { showRecordsWall = true }) {
                Label("Records Wall", systemImage: "medal.fill")
            }
            Button(action: { showCalendarHeatmap = true }) {
                Label("Calendar", systemImage: "calendar")
            }
        } label: {
            Image(systemName: "square.grid.2x2.fill")
                .foregroundStyle(.cyan)
        }
        #endif
    }

    private var exportMenuButton: some View {
        #if os(macOS)
        Button(action: { showExportMenu = true }) {
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(.cyan)
        }
        .popover(isPresented: $showExportMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: {
                    showExportMenu = false
                    exportAllDivesToXML()
                }) {
                    Label("Export All Dives to XML", systemImage: "chevron.left.forwardslash.chevron.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
                Button(action: {
                    showExportMenu = false
                    exportAllDivesToUDDF()
                }) {
                    Label("Export All Dives to UDDF", systemImage: "water.waves")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(width: 240)
            .padding(.vertical, 4)
        }
        #else
        Menu {
            Button(action: exportAllDivesToXML) {
                Label("Export All Dives to XML", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Button(action: exportAllDivesToUDDF) {
                Label("Export All Dives to UDDF", systemImage: "water.waves")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(.cyan)
        }
        #endif
    }

    #if os(macOS)
    private func toolsPopoverButton(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #endif
    
    // MARK: - Actions

    private func forceiCloudSync() async {
        guard !isSyncing else { return }
        withAnimation { isSyncing = true }

        try? modelContext.save()
        NSUbiquitousKeyValueStore.default.synchronize()

        try? await Task.sleep(for: .seconds(1.5))
        withAnimation { isSyncing = false }
    }
    
    private func resetFilters() {
        filterYear       = nil
        filterGasType    = nil
        filterMinDepth   = 0
        filterMinRating  = 0
        filterCountry    = nil
        filterDiveType   = nil
        filterTag        = nil
        filterDiverName  = nil
        filterMarineLife = ""
        sortOrder        = .dateDesc
    }

    private func deleteItems(offsets: IndexSet) {
        diveToDelete = offsets
        showDeleteConfirmation = true
    }
    
    private func confirmDeleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(dives[index])
            }
        }
    }

    private func confirmDeleteSingleDive(_ dive: Dive) {
        withAnimation {
            modelContext.delete(dive)
            try? modelContext.save()
        }
    }

    private func addManualDive() {
        manualDiveDate = .now
        showManualDiveDatePicker = true
    }

    private func createManualDive(date: Date) {
        let nextNumber = (dives.compactMap(\.diveNumber).max() ?? 0) + 1

        // Find the most recent dive that ended before the selected date
        let surfaceInterval: String = {
            let previous = dives
                .filter { $0.timestamp < date }
                .sorted { $0.timestamp > $1.timestamp }
                .first
            guard let prev = previous else { return "0h 00m" }
            let durationSeconds = TimeInterval(prev.duration * 60)
            let prevEnd = prev.timestamp.addingTimeInterval(durationSeconds)
            let gap = date.timeIntervalSince(prevEnd)
            guard gap > 0 else { return "0h 00m" }
            let totalMinutes = Int(gap / 60)
            let days = totalMinutes / (24 * 60)
            let hours = (totalMinutes % (24 * 60)) / 60
            let minutes = totalMinutes % 60
            if days > 0 {
                return String(format: "%dd %dh %02dm", days, hours, minutes)
            }
            return String(format: "%dh %02dm", hours, minutes)
        }()

        let prefs = UserPreferences.shared
        let tempFormat: String = {
            switch prefs.temperatureUnit {
            case .celsius:    return "°c"
            case .fahrenheit: return "°f"
            case .kelvin:     return "°k"
            }
        }()
        let weightFormat: String = {
            switch prefs.weightUnit {
            case .kilograms: return "kg"
            case .pounds:    return "lb"
            }
        }()

        let dive = Dive(
            diveNumber: nextNumber,
            timestamp: date,
            location: "",
            siteName: "",
            computerName: "",
            surfaceInterval: surfaceInterval,
            diverName: UserDefaults.standard.string(forKey: "userName") ?? "",
            maxDepth: 0,
            averageDepth: 0,
            duration: 0,
            waterTemperature: 0,
            minTemperature: 0,
            importDistanceUnit: prefs.depthUnit.rawValue,
            importTemperatureUnit: tempFormat,
            importPressureUnit: prefs.pressureUnit.rawValue,
            importVolumeUnit: prefs.volumeUnit.rawValue,
            importWeightUnit: weightFormat,
            sourceImport: "Manual"
        )
        withAnimation {
            modelContext.insert(dive)
            try? modelContext.save()
        }
    }
}
