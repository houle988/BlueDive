import SwiftUI
import SwiftData
import CoreBluetooth
import UniformTypeIdentifiers
import WidgetKit
import LibDCSwift
import os.log
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension UTType {
    static let uddf = UTType(importedAs: "org.uddf.uddf")
    static let garminFIT = UTType(importedAs: "com.garmin.fit")
    static let blueDiveXML = UTType(exportedAs: "app.bluedive.xml")
}

// Must match `appGroupSuite` in BlueDiveWidgetExtension.swift.
let widgetAppGroupSuite = "group.app.bluedive.universal"

struct ContentView: View {
    @Environment(\.modelContext) var modelContext
    @Query(sort: \Dive.timestamp, order: .reverse) var dives: [Dive]
    @Query private var allInsurances: [DivingInsurance]
    @Query(sort: \MarineSight.name) private var allMarineSights: [MarineSight]
    @State private var prefs = UserPreferences.shared
    @Environment(DiveStore.self) private var store

    @State var showScannerSheet = false
    @State var showFileImporter = false
    @State var importError: ImportError?
    @State var showErrorAlert = false
    @State private var showDeleteConfirmation = false
    @State private var diveToDelete: IndexSet?
    @State private var diveToDeleteDirectly: Dive?
    @State private var showDeleteSingleConfirmation = false
    @State private var showDeleteSheet = false
    @State var isImporting = false
    @State var importProgressFileName: String = ""
    @State var importProgressCurrent: Int = 0
    @State var importProgressTotal: Int = 0
    @State var isExporting = false
    @State var exportProgressCurrent: Int = 0
    @State var exportProgressTotal: Int = 0
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

    struct PendingDuplicateImport: Identifiable {
        let id = UUID()
        let parsedDives: [BlueDiveGlobalData]
        let duplicates: [DuplicateImportMatch]
        let fileName: String
    }
    @State var pendingDuplicateImport: PendingDuplicateImport?

    @State private var showProfile = false

    @State private var showDiveTrips = false
    @State private var showCalendarHeatmap = false
    @State private var showMarineLife = false
    @State private var showDashboard = false
    @State private var showMinimumGasPlanning = false
    @State private var showGasDensityCalculator = false
    @State private var showBestMixCalculator = false
    @State private var showCalculatorsPopover = false
    @State private var isSyncing = false
    @State private var showManualDiveDatePicker = false
    @State private var manualDiveDate = Date.now
    @State private var manualDiveDiverName = ""

    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""
    @AppStorage("showCalculatorsMenu") private var showCalculatorsMenu = false
    @AppStorage(BlueDiveApp.iCloudSyncEnabledKey) private var iCloudSyncEnabled = true
    @Environment(CloudKitSyncMonitor.self) private var syncMonitor
    @Environment(FileImportCoordinator.self) var importCoordinator
    @State private var showSyncStatusPopover = false
    @State private var collapsedDiverSections: Set<String> = []

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [Color.blue.opacity(0.1), Color.platformBackground.opacity(0.8)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
    
    // MARK: - Body
    
    var body: some View {
        @Bindable var store = store
        NavigationStack {
            ZStack {
                backgroundGradient.ignoresSafeArea()

                VStack(spacing: 0) {
                    contentSection
                }
            }

            #if os(iOS)
            .searchable(text: $store.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Site, location, buddy, country, type, tag, dive #…")
            #else
            .searchable(text: $store.searchText, prompt: "Site, location, buddy, country, type, tag, dive #…")
            #endif
            .animation(.easeInOut(duration: 0.3), value: store.searchText)
            .toolbar { toolbarContent }
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(isPresented: $store.showFilterSheet) {
                DiveFilterSheet(
                    availableYears: store.cachedAvailableYears,
                    availableGasTypes: store.cachedAvailableGasTypes,
                    availableCountries: store.cachedAvailableCountries,
                    availableDiveTypes: store.cachedAvailableDiveTypes,
                    availableTags: store.cachedAvailableTags,
                    availableMarineLife: store.cachedAvailableMarineLife,
                    filterYear: $store.filterYear,
                    filterYearNegate: $store.filterYearNegate,
                    filterGasType: $store.filterGasType,
                    filterGasTypeNegate: $store.filterGasTypeNegate,
                    filterMinDepth: $store.filterMinDepth,
                    filterMaxDepth: $store.filterMaxDepth,
                    filterMinRating: $store.filterMinRating,
                    filterCountry: $store.filterCountry,
                    filterCountryNegate: $store.filterCountryNegate,
                    filterDiveType: $store.filterDiveType,
                    filterDiveTypeNegate: $store.filterDiveTypeNegate,
                    filterTag: $store.filterTag,
                    filterMarineLife: $store.filterMarineLife,
                    filterMarineLifeMode: $store.filterMarineLifeMode,
                    sortOrder: $store.sortOrder
                )
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showMinimumGasPlanning) {
                MinimumGasCalculatorView()
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showGasDensityCalculator) {
                GasDensityCalculatorView()
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showBestMixCalculator) {
                BestMixCalculatorView()
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showFingerprintDebug) {
                FingerprintDebugView()
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showProfile) {
                DiverProfileView()
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }

            .sheet(isPresented: $showDiveTrips) {
                DiveTripsView()
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showCalendarHeatmap) {
                DiveCalendarHeatmapView()
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showMarineLife) {
                MarineLifeView()
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showDashboard) {
                StatisticsView()
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showScannerSheet) {
                BluetoothScannerView()
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            // Widget deep-link hooks (bluedive://add/manual | bluedive://add/bluetooth)
            .onReceive(NotificationCenter.default.publisher(for: .addDiveManual)) { _ in
                addManualDive()
            }
            .onReceive(NotificationCenter.default.publisher(for: .addDiveBluetooth)) { _ in
                showScannerSheet = true
            }
            #if os(macOS)
            .sheet(isPresented: $showDeleteSheet) {
                MacOSDeleteDiveSheet(
                    dives: store.cachedFilteredDives,
                    onDelete: { dive in
                        diveToDeleteDirectly = dive
                        showDeleteSingleConfirmation = true
                    }
                )
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            #endif
            .sheet(isPresented: $showMergeDivesSheet) {
                MergeDivesSheet(dives: store.cachedFilteredDives) { diveA, diveB in
                    mergeDives(diveA, with: diveB)
                }
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
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
                allowedContentTypes: [.xml, .uddf, .garminFIT, .blueDiveXML],
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
                    fileType: pending.fileType,
                    fileName: pending.url.lastPathComponent
                ) {
                    let url = pending.url
                    let data = pending.data
                    let type = pending.fileType
                    importProgressFileName = pending.url.lastPathComponent
                    pendingImport = nil
                    importDiveFile(from: url, preloadedData: data, formats: importFormatOptions, fileType: type)
                } onCancel: {
                    pendingImport = nil
                    importProgressFileName = ""
                }
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $pendingDuplicateImport) { pending in
                DuplicateImportSheet(
                    totalCount: pending.parsedDives.count,
                    duplicates: pending.duplicates,
                    parsedDives: pending.parsedDives,
                    fileName: pending.fileName,
                    onSkipDuplicates: {
                        let duplicateIndices = Set(pending.duplicates.map(\.parsedIndex))
                        let indices = pending.parsedDives.indices.filter { !duplicateIndices.contains($0) }
                        let parsed = pending.parsedDives
                        let fileName = pending.fileName
                        pendingDuplicateImport = nil
                        commitParsedDives(parsed, indices: indices, fileName: fileName)
                    },
                    onImportAll: {
                        let parsed = pending.parsedDives
                        let indices = Array(pending.parsedDives.indices)
                        let fileName = pending.fileName
                        pendingDuplicateImport = nil
                        commitParsedDives(parsed, indices: indices, fileName: fileName)
                    },
                    onCancel: {
                        pendingDuplicateImport = nil
                    }
                )
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
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
                        AutocompleteMenuTextField(label: "Diver (optional)", text: $manualDiveDiverName, icon: "person.fill", color: .cyan, suggestions: store.cachedUniqueDivers)
                            .autocorrectionDisabled()
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
                                createManualDive(date: manualDiveDate, diverName: manualDiveDiverName)
                            }
                            .fontWeight(.semibold)
                        }
                    }
                }
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
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
                            createManualDive(date: manualDiveDate, diverName: manualDiveDiverName)
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

                    Divider()

                    AutocompleteMenuTextField(label: "Diver (optional)", text: $manualDiveDiverName, icon: "person.fill", color: .cyan, suggestions: store.cachedUniqueDivers)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .frame(width: 390, height: 440)
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
                        if importProgressTotal > 0 {
                            ProgressView(value: Double(importProgressCurrent), total: Double(importProgressTotal))
                                .progressViewStyle(.linear)
                                .tint(.cyan)
                                .frame(width: 220)
                            Text(String(format: NSLocalizedString("%@ of %@ dives imported", bundle: .forAppLanguage(), comment: "Progress label during dive import showing current and total count"), Double(importProgressCurrent).localizedString(decimals: 0), Double(importProgressTotal).localizedString(decimals: 0)))
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .monospacedDigit()
                                .transaction { $0.animation = nil }
                        } else {
                            ProgressView().tint(.cyan).scaleEffect(1.5)
                            Text("Importing...")
                                .font(.headline)
                                .foregroundStyle(.primary)
                        }
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
        .animation(.linear(duration: 0.15), value: importProgressCurrent)
        .overlay {
            if isExporting {
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 16) {
                        if exportProgressTotal > 0 {
                            ProgressView(value: Double(exportProgressCurrent), total: Double(exportProgressTotal))
                                .progressViewStyle(.linear)
                                .tint(.cyan)
                                .frame(width: 220)
                            Text(String(format: NSLocalizedString("%@ of %@ dives exported", bundle: .forAppLanguage(), comment: "Progress label during dive export showing current and total count"),
                                 Double(exportProgressCurrent).localizedString(decimals: 0),
                                 Double(exportProgressTotal).localizedString(decimals: 0)))
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .monospacedDigit()
                                .transaction { $0.animation = nil }
                        } else {
                            ProgressView().tint(.cyan).scaleEffect(1.5)
                            Text("Exporting...")
                                .font(.headline)
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(32)
                    .background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isExporting)
        .animation(.linear(duration: 0.15), value: exportProgressCurrent)
        .sheet(isPresented: $showSyncStatusPopover) {
            CloudKitSyncStatusView()
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            if !store.hasCacheBuilt {
                // First mount: build caches immediately (cold launch or first appearance).
                store.rebuildDerivedDiveState(dives: dives, allInsurances: allInsurances, allMarineSights: allMarineSights, selectedDiver: selectedDiver)
            } else {
                // NavigationStack pop or scene re-activation: use the membership-guarded
                // debounced path so no-op pops (cancel, no changes) skip the full rebuild.
                store.scheduleRebuild(dives: dives, allInsurances: allInsurances, allMarineSights: allMarineSights, selectedDiver: selectedDiver)
            }
            // Cold-launch: onOpenURL may fire before this view mounts, so check
            // for a pending file URL that was stashed in the coordinator at launch.
            if let url = importCoordinator.pendingURL {
                importCoordinator.pendingURL = nil
                handleExternalFileURL(url)
            }
        }
        .task {
            store.updateWidgetDiveData(dives: dives)
        }
        .onChange(of: dives) { _, _ in store.scheduleRebuild(dives: dives, allInsurances: allInsurances, allMarineSights: allMarineSights, selectedDiver: selectedDiver) }
        .onChange(of: allInsurances) { _, _ in store.scheduleRebuild(dives: dives, allInsurances: allInsurances, allMarineSights: allMarineSights, selectedDiver: selectedDiver, force: true) }
        .onChange(of: store.cachedWidgetFingerprint) { _, _ in store.updateWidgetDiveData(dives: dives) }
        .onChange(of: prefs.depthUnit) { _, _ in store.updateWidgetDiveData(dives: dives); store.rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver) }
        .diverFilterReset(uniqueDivers: store.cachedUniqueDivers, selectedDiver: $selectedDiver)
        .onChange(of: store.cachedUniqueDivers) { _, newDivers in
            collapsedDiverSections.formIntersection(newDivers)
        }
        .background(filterObservers)
        // Warm-launch: handle file URLs that arrive while the app is already running.
        .onChange(of: importCoordinator.pendingURL) { _, url in
            guard let url else { return }
            importCoordinator.pendingURL = nil
            handleExternalFileURL(url)
        }
    }


    // Extracted into a separate property to avoid Swift type-checker timeouts
    // caused by excessively long modifier chains in body.
    @ViewBuilder
    private var filterObserversA: some View {
        Color.clear
            .onChange(of: store.searchText) { _, _ in
                store.scheduleSearchRebuild(dives: dives, selectedDiver: selectedDiver)
            }
            .onChange(of: selectedDiver)              { _, _ in store.rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver) }
            .onChange(of: store.filterYear)           { _, _ in store.rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver) }
            .onChange(of: store.filterYearNegate)     { _, _ in store.rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver) }
            .onChange(of: store.filterGasType)        { _, _ in store.rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver) }
            .onChange(of: store.filterGasTypeNegate)  { _, _ in store.rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver) }
            .onChange(of: store.filterMinDepth)       { _, _ in store.rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver) }
            .onChange(of: store.filterMaxDepth)       { _, _ in store.rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver) }
            .onChange(of: store.filterMinRating)      { _, _ in store.rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver) }
    }

    @ViewBuilder
    private var filterObserversB: some View {
        Color.clear
            .onChange(of: store.filterCountry)        { _, _ in store.rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver) }
            .onChange(of: store.filterCountryNegate)  { _, _ in store.rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver) }
            .onChange(of: store.filterDiveType)       { _, _ in store.rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver) }
            .onChange(of: store.filterDiveTypeNegate) { _, _ in store.rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver) }
            .onChange(of: store.filterTag)            { _, _ in store.rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver) }
            .onChange(of: store.filterMarineLife)     { _, _ in store.rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver) }
            .onChange(of: store.filterMarineLifeMode) { _, _ in store.rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver) }
            .onChange(of: store.sortOrder)            { _, _ in store.rebuildFilteredDives(dives: dives, selectedDiver: selectedDiver) }
    }

    @ViewBuilder
    private var modelObservers: some View {
        Color.clear
            .onChange(of: store.showFilterSheet) { _, isShowing in
                if isShowing { store.rebuildFilterOptions() }
            }
    }

    @ViewBuilder
    private var filterObservers: some View {
        filterObserversA
        filterObserversB
        modelObservers
    }

    // MARK: - View Components
    
    @ViewBuilder
    private var contentSection: some View {
        if !dives.isEmpty {
            diveList
                .transition(.opacity)
        } else if !isImporting {
            emptyStateView
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
        let displayedSummaries = store.cachedFilteredSummaries
        return Group {
            if displayedSummaries.isEmpty && store.hasCacheBuilt {
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
                    if store.activeFilterCount > 0 {
                        Button {
                            store.resetFilters()
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
                let showGrouped = store.cachedShowGrouped
                if showGrouped {
                    let grouped = store.cachedGroupedSummaries
                    List {
                        ForEach(grouped, id: \.key) { group in
                            let diver = group.key
                            let sectionSummaries = group.value
                            Section(isExpanded: Binding(
                                get: { !collapsedDiverSections.contains(diver) },
                                set: { isExpanded in
                                    if isExpanded {
                                        collapsedDiverSections.remove(diver)
                                    } else {
                                        collapsedDiverSections.insert(diver)
                                    }
                                }
                            )) {
                                ForEach(sectionSummaries) { summary in
                                    let rowNumber = dives.count - (store.diveIndexLookup[summary.id] ?? 0)
                                    NavigationLink(destination: DiveDetailView(
                                        dive: store.diveByID[summary.id]!,
                                        sortedDives: sectionSummaries.compactMap { store.diveByID[$0.id] },
                                        diveNumber: rowNumber
                                    )) {
                                        DiveRowView(summary: summary, diveNumber: rowNumber)
                                    }
                                    .listRowBackground(Color.primary.opacity(0.07))
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            diveToDeleteDirectly = store.diveByID[summary.id]
                                            showDeleteSingleConfirmation = true
                                        } label: {
                                            Label("Delete dive", systemImage: "trash")
                                        }
                                    }
                                }
                                .onDelete { offsets in
                                    if let index = offsets.first {
                                        let summary = sectionSummaries[index]
                                        diveToDeleteDirectly = store.diveByID[summary.id]
                                        showDeleteSingleConfirmation = true
                                    }
                                }
                            } header: {
                                Text(verbatim: diver.isEmpty
                                     ? NSLocalizedString("Unknown Diver", bundle: Bundle.forAppLanguage(), comment: "Section header in the dive list for dives with no diver name assigned")
                                     : diver)
                                    .font(.headline)
                                    .foregroundStyle(.cyan)
                                    .textCase(nil)
                            }
                        }
                    }
                    // .sidebar is required for Section(isExpanded:) collapse/expand to function
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .refreshable {
                        await forceiCloudSync()
                    }
                    #if os(iOS)
                    .contentMargins(.top, 0, for: .scrollContent)
                    #endif
                } else {
                    List {
                        ForEach(displayedSummaries) { summary in
                            let rowNumber = dives.count - (store.diveIndexLookup[summary.id] ?? 0)
                            NavigationLink(destination: DiveDetailView(
                                dive: store.diveByID[summary.id]!,
                                sortedDives: store.cachedFilteredDives,
                                diveNumber: rowNumber
                            )) {
                                DiveRowView(summary: summary, diveNumber: rowNumber)
                            }
                            .listRowBackground(Color.primary.opacity(0.07))
                            .contextMenu {
                                Button(role: .destructive) {
                                    diveToDeleteDirectly = store.diveByID[summary.id]
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
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var cloudSyncToolbarItem: some View {
        Button { showSyncStatusPopover = true } label: { cloudSyncIcon }
            .help("iCloud Sync Status")
    }

    @ViewBuilder
    private var cloudSyncIcon: some View {
        if !iCloudSyncEnabled {
            Image(systemName: "icloud.slash.fill")
                .foregroundStyle(.secondary)
        } else if syncMonitor.isSyncing {
            ProgressView()
                .scaleEffect(0.75)
                .frame(width: 20, height: 20)
        } else if syncMonitor.hasError {
            Image(systemName: "exclamationmark.icloud.fill")
                .foregroundStyle(.orange)
        } else if let d = syncMonitor.lastSyncDate, Date().timeIntervalSince(d) < 300 {
            Image(systemName: "checkmark.icloud.fill")
                .foregroundStyle(.cyan)
        } else {
            Image(systemName: "icloud.fill")
                .foregroundStyle(.secondary)
        }
    }


    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        DiverFilterToolbar(uniqueDivers: store.cachedUniqueDivers, selectedDiver: $selectedDiver, hasUnnamedDives: store.cachedHasUnnamedDives)

        // ── Left: Settings + Bluetooth + Tools Menu ──────────────────────
        ToolbarItem(placement: .navigation) {
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.cyan)
            }
            .help("Settings")
        }
        ToolbarItem(placement: .navigation) {
            cloudSyncToolbarItem
        }
        if showCalculatorsMenu {
            ToolbarItem(placement: .navigation) {
                calculatorsMenu
            }
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

            Button(action: { showFilterSheet = true }) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundStyle(store.activeFilterCount > 0 ? .orange : .cyan)
                    if store.activeFilterCount > 0 {
                        Text("\(store.activeFilterCount)")
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
                        .font(.title3)
                        .foregroundStyle(.cyan)
                }

                Button(action: { store.showFilterSheet = true }) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                            .font(.title3)
                            .foregroundStyle(store.activeFilterCount > 0 ? .orange : .cyan)
                        if store.activeFilterCount > 0 {
                            Text("\(store.activeFilterCount)")
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
                    Divider()
                    Button(action: { showDashboard = true }) {
                        Label("Stats", systemImage: "chart.bar.fill")
                    }
                    Button(action: { showDiveTrips = true }) {
                        Label("My Trips", systemImage: "map.fill")
                    }
                    Button(action: { showCalendarHeatmap = true }) {
                        Label("Calendar", systemImage: "calendar")
                    }
                    Button(action: { showMarineLife = true }) {
                        Label("Marine Life", systemImage: "fish.fill")
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
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.cyan)
                }
            }
        }
        #endif
    }

    // Tools menu extracted to a property to avoid
    // @State capture issues in toolbar closures on macOS.
    private var calculatorsMenu: some View {
        #if os(macOS)
        Button(action: { showCalculatorsPopover = true }) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .foregroundStyle(.cyan)
        }
        .help("Calculators")
        .popover(isPresented: $showCalculatorsPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                toolsPopoverButton("Minimum Gas", icon: "wrench.and.screwdriver.fill") {
                    showCalculatorsPopover = false
                    showMinimumGasPlanning = true
                }
                Divider()
                toolsPopoverButton("Gas Density", icon: "atom") {
                    showCalculatorsPopover = false
                    showGasDensityCalculator = true
                }
                Divider()
                toolsPopoverButton("Best Mix", icon: "bubbles.and.sparkles") {
                    showCalculatorsPopover = false
                    showBestMixCalculator = true
                }
            }
            .frame(width: 220)
            .padding(.vertical, 4)
        }
        #else
        Menu {
            Button(action: { showMinimumGasPlanning = true }) {
                Label("Minimum Gas", systemImage: "wrench.and.screwdriver.fill")
            }
            Button(action: { showGasDensityCalculator = true }) {
                Label("Gas Density", systemImage: "atom")
            }
            Button(action: { showBestMixCalculator = true }) {
                Label("Best Mix", systemImage: "bubbles.and.sparkles")
            }
        } label: {
            Image(systemName: "wrench.and.screwdriver.fill")
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

        do {
            try modelContext.save()
        } catch {
            BlueDiveApp.logger.error("❌ iCloud sync save failed: \(error.localizedDescription)")
        }
        NSUbiquitousKeyValueStore.default.synchronize()

        try? await Task.sleep(for: .seconds(1.5))
        withAnimation { isSyncing = false }
    }
    
    private func deleteItems(offsets: IndexSet) {
        diveToDelete = offsets
        showDeleteConfirmation = true
    }
    
    private func confirmDeleteItems(offsets: IndexSet) {
        // Use store.cachedFilteredDives — IndexSet is relative to the displayed list, not the raw query.
        let displayed = store.cachedFilteredDives
        withAnimation {
            for index in offsets where index < displayed.count {
                modelContext.delete(displayed[index])
            }
            try? modelContext.save()
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
        manualDiveDiverName = ""
        showManualDiveDatePicker = true
    }

    private func createManualDive(date: Date, diverName: String) {
        let diverName = diverName.trimmingCharacters(in: .whitespaces)
        let targetDiverName = diverName
        var diverDescriptor = FetchDescriptor<Dive>(
            predicate: #Predicate<Dive> { dive in
                dive.diveNumber != nil && dive.diverName == targetDiverName
            },
            sortBy: [SortDescriptor(\Dive.diveNumber, order: .reverse)]
        )
        diverDescriptor.fetchLimit = 1
        let nextNumber = ((try? modelContext.fetch(diverDescriptor).first?.diveNumber) ?? 0) + 1

        // Find the most recent dive for the same diver that ended before the selected date
        let surfaceInterval: String = {
            let previous = dives.first(where: { $0.timestamp < date && $0.diverName == diverName })
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
            diverName: diverName,
            maxDepth: 0,
            averageDepth: 0,
            duration: 0,
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
        Dive.recalculateSurfaceIntervals(in: modelContext, diverName: diverName)
    }
}
