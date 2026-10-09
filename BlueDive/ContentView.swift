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
    static let ssrf = UTType(importedAs: "org.subsurface-divelog.ssrf")
}

// Must match `appGroupSuite` in BlueDiveWidgetExtension.swift.
let widgetAppGroupSuite = "group.app.bluedive.universal"

struct ContentView: View {
    @Environment(\.modelContext) var modelContext
    @Query(sort: \Dive.timestamp, order: .reverse) var dives: [Dive]
    @Query(sort: \MarineSight.name) private var allMarineSights: [MarineSight]
    @State private var prefs = UserPreferences.shared
    @Environment(DiveStore.self) private var store

    @State var showScannerSheet = false
    /// Driven by BluetoothScannerView's sync state. True while a BLE connection is open and a
    /// retrieval may be in flight, where a swipe-dismiss would tear down and free the device
    /// pointer out from under the background read.
    @State private var isBluetoothSyncTeardownUnsafe = false
    @State var showFileImporter = false
    @State var importError: ImportError?
    @State var showErrorAlert = false
    @State private var showDeleteConfirmation = false
    @State private var diveToDelete: IndexSet?
    @State private var diveToDeleteDirectly: Dive?
    @State private var showDeleteSingleConfirmation = false
    @State private var diveToMove: Dive?
    @State var isImporting = false
    @State var importProgressFileName: String = ""
    @State var importProgressCurrent: Int = 0
    @State var importProgressTotal: Int = 0
    @State var isExporting = false
    @State var exportProgressCurrent: Int = 0
    @State var exportProgressTotal: Int = 0
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
    @State private var showPhotoBatchImport = false
    @State private var showDashboard = false
    @State private var showMinimumGasPlanning = false
    @State private var showGasDensityCalculator = false
    @State private var showBestMixCalculator = false
    @State private var isSyncing = false
    @State private var showManualDiveDatePicker = false
    @State private var manualDiveDate = Date.now
    @State private var manualDiveDiverName = ""

    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""
    @AppStorage("showCalculatorsMenu") private var showCalculatorsMenu = false
    @AppStorage("autoSequenceEnabled") private var autoSequenceEnabled = false
    @AppStorage(BlueDiveApp.iCloudSyncEnabledKey) private var iCloudSyncEnabled = true
    @Environment(CloudKitSyncMonitor.self) private var syncMonitor
    @Environment(FileImportCoordinator.self) var importCoordinator
    @State private var showSyncStatusPopover = false
    @State private var collapsedDiverSections: Set<String> = []
    #if os(macOS)
    /// Whether the dive rows show their one-line version (wide window), and their width, reported
    /// by the rows; the column header pinned above the list is shown only then, at that width.
    /// Starts one-line: the main window opens maximized.
    @State private var diveListLayout = OneLineRowsLayout()
    /// Selected dive (click or arrow keys); the profile preview above the list shows it.
    /// An observable object rather than a `UUID?` `@State` so a selection change redraws only
    /// the panel and the row highlights, not this body (the list reads it only in actions).
    @State private var listSelection = DiveListSelection()
    /// Dive opened by double-click or Return, pushed through `navigationDestination(item:)`.
    @State private var openedDiveTarget: DiveNavTarget?
    /// Keyboard focus of the dive list, for the arrow keys and Return.
    @FocusState private var isDiveListFocused: Bool
    #endif

    @ViewBuilder
    private func moveButton(for summaryID: UUID) -> some View {
        Button {
            diveToMove = store.diveByID[summaryID]
        } label: {
            Label("Move", systemImage: "person.fill")
        }
        .tint(.blue)
    }

    #if os(macOS)
    /// Trailing swipe-to-delete for a dive row. On iOS the List synthesizes this swipe from
    /// `.onDelete`; macOS does not, so it is added explicitly. Uses the same confirmation as
    /// the row's context-menu "Delete dive".
    private func deleteSwipeButton(for summaryID: UUID) -> some View {
        Button(role: .destructive) {
            if let dive = store.diveByID[summaryID] {
                diveToDeleteDirectly = dive
                showDeleteSingleConfirmation = true
            }
        } label: {
            Label("Delete dive", systemImage: "trash")
        }
        // Swipe actions are coloured by their tint; without this macOS uses the app's cyan
        // accent instead of the destructive red iOS applies automatically.
        .tint(.red)
    }

    /// Opens the dive detail view (double-click, or Return on the selected row).
    private func openDive(_ summaryID: UUID) {
        guard store.diveByID[summaryID] != nil else { return }
        openedDiveTarget = DiveNavTarget(summaryID: summaryID, isGrouped: store.cachedShowGrouped)
    }

    /// Dives in the order the list shows them (collapsed diver sections skipped), for the
    /// arrow-key navigation.
    private var visibleDiveIDs: [UUID] {
        if store.cachedShowGrouped {
            return store.cachedGroupedSummaries
                .filter { !collapsedDiverSections.contains($0.key) }
                .flatMap { $0.value.map(\.id) }
        }
        return store.cachedFilteredSummaries.map(\.id)
    }

    /// Moves the selection one row up (-1) or down (+1) and scrolls it into view. With no
    /// selection (or one no longer shown), selects the first row.
    private func moveSelection(by offset: Int, proxy: ScrollViewProxy) {
        let ids = visibleDiveIDs
        guard !ids.isEmpty else { return }
        let target: UUID
        if let current = listSelection.diveID, let index = ids.firstIndex(of: current) {
            target = ids[min(max(index + offset, 0), ids.count - 1)]
        } else {
            target = ids[0]
        }
        listSelection.diveID = target
        proxy.scrollTo(target)
    }
    #endif

    /// The dive list. On macOS a row is selected with a click or the arrow keys — the profile
    /// preview above the list shows it, highlighted in cyan — and opened with a double-click or
    /// Return, the standard Mac list behaviour. The selection is kept by the app rather than
    /// `List(selection:)`, whose highlight fills the row with the accent colour and washes out
    /// its coloured chips. With the preview turned off (Settings → Dive Profile, or View →
    /// Show Profile Preview) the list is plain and a click opens the dive, as on iOS.
    /// On iOS this is exactly `List { … }`; a tap opens the dive.
    @ViewBuilder
    private func diveListContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        #if os(macOS)
        let list = List(content: content)
        if !prefs.showDiveListProfilePreview {
            list
        } else {
            ScrollViewReader { proxy in
                list
                    .focusable()
                    .focusEffectDisabled()
                    .focused($isDiveListFocused)
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1, proxy: proxy)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1, proxy: proxy)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        guard let summaryID = listSelection.diveID else { return .ignored }
                        openDive(summaryID)
                        return .handled
                    }
            }
        }
        #else
        List(content: content)
        #endif
    }

    /// The dive rows of one list (or one diver section). Each `ForEach` row has a single shape,
    /// so `List` takes its fast path: it gets the row identities from the summaries' ids
    /// without evaluating every row. A row choosing between two shapes (link or selectable)
    /// would make it evaluate all rows — with their modifiers — on every list update, which
    /// macOS does each time the Dives tab is shown or hidden (about a second at 2 000 dives).
    /// So on macOS the profile-preview setting picks the row kind once for the whole list.
    /// On iOS this is the link-row `ForEach` alone.
    @ViewBuilder
    private func diveRows(
        _ summaries: [DiveSummary],
        isGrouped: Bool,
        onDelete: @escaping (IndexSet) -> Void
    ) -> some View {
        // Read once, not per row: `dives` is the @Query.
        let diveCount = dives.count
        #if os(macOS)
        if prefs.showDiveListProfilePreview {
            diveRowsForEach(summaries, onDelete: onDelete) { summary in
                selectableDiveRow(summary, rowNumber: diveCount - (store.diveIndexLookup[summary.id] ?? 0))
            }
        } else {
            diveRowsForEach(summaries, onDelete: onDelete) { summary in
                linkDiveRow(summary, rowNumber: diveCount - (store.diveIndexLookup[summary.id] ?? 0),
                            isGrouped: isGrouped)
            }
        }
        #else
        diveRowsForEach(summaries, onDelete: onDelete) { summary in
            linkDiveRow(summary, rowNumber: diveCount - (store.diveIndexLookup[summary.id] ?? 0),
                        isGrouped: isGrouped)
        }
        #endif
    }

    /// `ForEach` over dive rows with the row background, swipe actions, context menu and
    /// delete shared by every row kind. `row` must return one view of a single shape.
    private func diveRowsForEach<Row: View>(
        _ summaries: [DiveSummary],
        onDelete: @escaping (IndexSet) -> Void,
        @ViewBuilder row: @escaping (DiveSummary) -> Row
    ) -> some View {
        let lastID = summaries.last?.id
        return ForEach(summaries) { summary in
            row(summary)
            #if os(macOS)
            .listRowBackground(Color.primary.opacity(0.07)
                                   .overlay { DiveRowSelectionHighlight(selection: listSelection, summaryID: summary.id) },
                               macSeparator: summary.id != lastID)
            #else
            .listRowBackground(Color.primary.opacity(0.07),
                               macSeparator: summary.id != lastID)
            #endif
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                moveButton(for: summary.id)
            }
            #if os(macOS)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                deleteSwipeButton(for: summary.id)
            }
            #endif
            .contextMenu {
                Button(role: .destructive) {
                    if let dive = store.diveByID[summary.id] {
                        diveToDeleteDirectly = dive
                        showDeleteSingleConfirmation = true
                    }
                } label: {
                    Label("Delete dive", systemImage: "trash")
                }
            }
        }
        .onDelete(perform: onDelete)
    }

    /// A dive row that opens the dive when clicked or tapped.
    private func linkDiveRow(_ summary: DiveSummary, rowNumber: Int, isGrouped: Bool) -> some View {
        NavigationLink(value: DiveNavTarget(summaryID: summary.id, isGrouped: isGrouped)) {
            DiveRowView(summary: summary, diveNumber: rowNumber)
        }
    }

    #if os(macOS)
    /// A dive row with the profile preview on (macOS): a click selects it, a double-click
    /// opens it.
    private func selectableDiveRow(_ summary: DiveSummary, rowNumber: Int) -> some View {
        DiveRowView(summary: summary, diveNumber: rowNumber)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                openDive(summary.id)
            }
            // Simultaneous, so the selection follows the first click at once instead of
            // waiting for the double-click interval to expire.
            .simultaneousGesture(TapGesture().onEnded {
                listSelection.diveID = summary.id
                isDiveListFocused = true
            })
            // The row is no longer a link: expose it to VoiceOver as a button that opens
            // the dive, and mark the selected one.
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                openDive(summary.id)
            }
            .modifier(DiveRowSelectionAccessibility(selection: listSelection, summaryID: summary.id))
    }
    #endif

    /// Dive detail view for a list row.
    @ViewBuilder
    private func diveDetailDestination(_ target: DiveNavTarget) -> some View {
        if let dive = store.diveByID[target.summaryID] {
            let rowNumber = dives.count - (store.diveIndexLookup[target.summaryID] ?? 0)
            let sortedDives: [Dive] = target.isGrouped
                ? (store.cachedGroupedDives.first {
                       $0.key == dive.diverName.trimmingCharacters(in: .whitespaces)
                   }?.value ?? [])
                : store.cachedFilteredDives
            DiveDetailView(dive: dive, sortedDives: sortedDives, diveNumber: rowNumber)
        }
    }

    // MARK: - Body
    
    var body: some View {
        @Bindable var store = store
        NavigationStack {
            ZStack {
                AppBackground(opaque: false).ignoresSafeArea()

                VStack(spacing: 0) {
                    #if os(macOS)
                    if !dives.isEmpty && prefs.showDiveListProfilePreview {
                        DiveProfilePreviewPanel(selection: listSelection)
                    }
                    #endif
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
            #if os(iOS)
            // The macOS window toolbar is always visible; there is no navigation bar.
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
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
                .standardSheetPresentation()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .standardSheetPresentation()
            }
            .sheet(isPresented: $showMinimumGasPlanning) {
                MinimumGasCalculatorView()
                    .standardSheetPresentation()
            }
            .sheet(isPresented: $showGasDensityCalculator) {
                GasDensityCalculatorView()
                    .standardSheetPresentation()
            }
            .sheet(isPresented: $showBestMixCalculator) {
                BestMixCalculatorView()
                    .standardSheetPresentation()
            }
            .sheet(isPresented: $showFingerprintDebug) {
                FingerprintDebugView()
                    .standardSheetPresentation()
            }
            .sheet(isPresented: $showProfile) {
                DiverProfileView()
                    .standardSheetPresentation()
            }

            .sheet(isPresented: $showDiveTrips) {
                DiveTripsView()
                    .standardSheetPresentation()
            }
            .sheet(isPresented: $showCalendarHeatmap) {
                DiveCalendarHeatmapView()
                    .standardSheetPresentation()
            }
            .sheet(isPresented: $showMarineLife) {
                MarineLifeView()
                    .standardSheetPresentation()
            }
            .sheet(isPresented: $showPhotoBatchImport) {
                PhotoBatchImportSheet()
                    .standardSheetPresentation()
            }
            .sheet(isPresented: $showDashboard) {
                StatisticsView()
                    .standardSheetPresentation()
            }
            .sheet(isPresented: $showScannerSheet) {
                BluetoothScannerView(isTeardownUnsafe: $isBluetoothSyncTeardownUnsafe)
                    .standardSheetPresentation()
                    .interactiveDismissDisabled(isBluetoothSyncTeardownUnsafe)
            }
            // Widget deep-link hooks (bluedive://add/manual | bluedive://add/bluetooth)
            .onReceive(NotificationCenter.default.publisher(for: .addDiveManual)) { _ in
                addManualDive()
            }
            .onReceive(NotificationCenter.default.publisher(for: .addDiveBluetooth)) { _ in
                showScannerSheet = true
            }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
                showSettings = true
            }
            #endif
            .sheet(isPresented: $showMergeDivesSheet) {
                MergeDivesSheet(dives: store.cachedFilteredDives) { diveA, diveB in
                    mergeDives(diveA, with: diveB)
                }
                .standardSheetPresentation()
            }
            .sheet(item: $diveToMove) { dive in
                MoveDiverSheet(dive: dive)
                    .standardSheetPresentation()
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
                allowedContentTypes: [.xml, .uddf, .ssrf, .garminFIT, .blueDiveXML],
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
                .standardSheetPresentation()
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
                .standardSheetPresentation()
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
                NavigationStack {
                    Form {
                        DatePicker("Date & Time", selection: $manualDiveDate)
                            #if os(macOS)
                            // macOS renders .graphical as a small fixed-size calendar plus an
                            // analogue clock; the compact field opens a calendar popover instead.
                            .datePickerStyle(.compact)
                            #else
                            .datePickerStyle(.graphical)
                            #endif
                        AutocompleteMenuTextField(label: "Diver (optional)", text: $manualDiveDiverName, icon: "person.fill", color: .cyan, suggestions: store.cachedUniqueDivers)
                            .autocorrectionDisabled()
                    }
                    .groupedFormStyleOnMac()
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
                .standardSheetPresentation()
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
            .navigationDestination(for: DiveNavTarget.self) { target in
                diveDetailDestination(target)
            }
            #if os(macOS)
            .navigationDestination(item: $openedDiveTarget) { target in
                diveDetailDestination(target)
            }
            #endif
        }

        .overlay {
            if isImporting {
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 16) {
                        if importProgressTotal > 0 {
                            ProgressView(value: Double(importProgressCurrent), total: Double(importProgressTotal))
                                .progressViewStyle(.linear)
                                .frame(width: 220)
                            Text(String(format: NSLocalizedString("%@ of %@ dives imported", bundle: .forAppLanguage(), comment: "Progress label during dive import showing current and total count"), Double(importProgressCurrent).localizedString(decimals: 0), Double(importProgressTotal).localizedString(decimals: 0)))
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .monospacedDigit()
                                .transaction { $0.animation = nil }
                        } else {
                            ProgressView().scaleEffect(1.5)
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
                                .frame(width: 220)
                            Text(String(format: NSLocalizedString("%@ of %@ dives exported", bundle: .forAppLanguage(), comment: "Progress label during dive export showing current and total count"),
                                 Double(exportProgressCurrent).localizedString(decimals: 0),
                                 Double(exportProgressTotal).localizedString(decimals: 0)))
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .monospacedDigit()
                                .transaction { $0.animation = nil }
                        } else {
                            ProgressView().scaleEffect(1.5)
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
                .standardSheetPresentation()
        }
        .onAppear {
            if !store.hasCacheBuilt {
                // First mount: build caches immediately (cold launch or first appearance).
                store.rebuildDerivedDiveState(dives: dives, allMarineSights: allMarineSights, selectedDiver: selectedDiver)
            } else {
                // NavigationStack pop or scene re-activation: use the membership-guarded
                // debounced path so no-op pops (cancel, no changes) skip the full rebuild.
                store.scheduleRebuild(dives: dives, allMarineSights: allMarineSights, selectedDiver: selectedDiver)
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
        .onChange(of: dives) { _, _ in store.scheduleRebuild(dives: dives, allMarineSights: allMarineSights, selectedDiver: selectedDiver) }
        // Gear/certification/insurance diver names reach store.cachedUniqueDivers through
        // DiverSourcesFeeder (attached in MainTabView, mounted whatever tab is shown), not here.
        // Widget data is rewritten by DiveStore itself when its fingerprint changes (see
        // scheduleAggregation), so it stays current while another tab is shown.
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
    
    private struct DiveNavTarget: Hashable {
        let summaryID: UUID
        let isGrouped: Bool
    }

    /// True when the diver filter is the only active constraint on the dive list —
    /// no search text, no filter-sheet criterion. The generic search/filter empty state
    /// below has no affordance for selectedDiver (a separate AppStorage value
    /// store.activeFilterCount doesn't count), so this case gets its own escape hatch instead.
    private var diverFilterIsSoleCause: Bool {
        !selectedDiver.isEmpty && store.appliedSearchText.isEmpty && store.activeFilterCount == 0
    }

    private var noDivesForDiverView: some View {
        NoEntriesForDiverView(
            title: DiverFilter.noDivesTitle(for: selectedDiver),
            description: DiverFilter.noDivesDescription(for: selectedDiver)
        ) {
            Button {
                selectedDiver = ""
            } label: {
                Label("Show All Divers", systemImage: "person.2")
            }
            .borderlessButton()
        }
    }

    private var noResultsView: some View {
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
                    selectedDiver = ""
                } label: {
                    Group {
                        if !selectedDiver.isEmpty {
                            Label("Clear filters and diver", systemImage: "xmark.circle.fill")
                        } else {
                            Label("Clear filters", systemImage: "xmark.circle.fill")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.cyan)
                }
                .transition(.scale.combined(with: .opacity))
                .borderlessButton()
            }
            Spacer()
        }
    }

    private var diveList: some View {
        let displayedSummaries = store.cachedFilteredSummaries
        return Group {
            if displayedSummaries.isEmpty && store.hasCacheBuilt {
                if diverFilterIsSoleCause {
                    noDivesForDiverView
                        .transition(.opacity)
                } else {
                    noResultsView
                        .transition(.opacity)
                }
            } else {
                let showGrouped = store.cachedShowGrouped
                if showGrouped {
                    let grouped = store.cachedGroupedSummaries
                    diveListContainer {
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
                                diveRows(sectionSummaries, isGrouped: true) { offsets in
                                    if let index = offsets.first {
                                        let summary = sectionSummaries[index]
                                        if let dive = store.diveByID[summary.id] {
                                            diveToDeleteDirectly = dive
                                            showDeleteSingleConfirmation = true
                                        }
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
                    .contentMargins(.top, 0, for: .scrollContent)
                    #if os(macOS)
                    // Column labels pinned above the list, once for all diver sections.
                    .pinnedColumnHeader(diveListLayout) { DiveListColumnHeader() }
                    .environment(diveListLayout)
                    #endif
                } else {
                    diveListContainer {
                        diveRows(displayedSummaries, isGrouped: false, onDelete: deleteItems)
                    }
                    .scrollContentBackground(.hidden)
                    .refreshable {
                        await forceiCloudSync()
                    }
                    .listStyle(.plain)
                    .contentMargins(.top, 0, for: .scrollContent)
                    #if os(macOS)
                    // Column labels pinned above the list, so they stay visible while it scrolls.
                    .pinnedColumnHeader(diveListLayout) { DiveListColumnHeader() }
                    .environment(diveListLayout)
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
            .accessibilityLabel(Text("iCloud Sync Status"))
            // Set directly on the Button rather than on a descendant inside its label,
            // since it's undocumented whether SwiftUI promotes a descendant's
            // .accessibilityValue to the enclosing Button's own accessibility element.
            .accessibilityValue(cloudSyncAccessibilityValue)
    }

    private var cloudSyncAccessibilityValue: Text {
        if !iCloudSyncEnabled {
            return Text("iCloud sync is turned off")
        } else if syncMonitor.isSyncing {
            return Text("Syncing")
        } else if syncMonitor.hasError {
            return Text("Sync error")
        } else if let d = syncMonitor.lastSyncDate, Date().timeIntervalSince(d) < 300 {
            return Text("Recently synced")
        } else {
            return Text("Idle")
        }
    }

    @ViewBuilder
    private var cloudSyncIcon: some View {
        if !iCloudSyncEnabled {
            Image(systemName: "icloud.slash")
                .foregroundStyle(.secondary)
        } else if syncMonitor.isSyncing {
            // An animated symbol, not a ProgressView: macOS only shares a toolbar glass capsule
            // between items whose labels are plain images/text, so a ProgressView label would
            // split this button from the Settings/diver-filter group while syncing.
            Image(systemName: "arrow.clockwise.icloud")
                .foregroundStyle(.cyan)
                .symbolEffect(.pulse)
        } else if syncMonitor.hasError {
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(.orange)
        } else if let d = syncMonitor.lastSyncDate, Date().timeIntervalSince(d) < 300 {
            Image(systemName: "checkmark.icloud")
                .foregroundStyle(.cyan)
        } else {
            Image(systemName: "icloud")
                .foregroundStyle(.secondary)
        }
    }


    // Sort order is a persisted, durable preference (unlike filters, which are
    // scoped to a single browsing session) — see DiveStore.sortOrder. The filter
    // toolbar button doubles as the entry point to both filters and sort, so it
    // must visually flag a non-default sort even when no filter is active, or a
    // persisted custom sort looks indistinguishable from the default on every launch.
    private var filterToolbarIsActive: Bool {
        store.activeFilterCount > 0 || store.sortOrder != .dateDesc
    }

    private var filterToolbarAccessibilityLabel: Text {
        if store.activeFilterCount > 0 {
            return Text(verbatim: String(format: NSLocalizedString("%d active filters", bundle: .forAppLanguage(), comment: "Accessibility label for the filter button showing the number of active filters"), store.activeFilterCount))
        } else if store.sortOrder != .dateDesc {
            return Text(verbatim: NSLocalizedString("Custom sort applied", bundle: .forAppLanguage(), value: "Custom sort applied", comment: "Accessibility label for the filter button when no filters are active but the sort order differs from the default"))
        } else {
            return Text(verbatim: NSLocalizedString("Filter dives", bundle: .forAppLanguage(), comment: "Accessibility label for the filter button when no filters are active"))
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(macOS)
        // macOS joins toolbar controls into one Liquid Glass capsule per side only when they
        // share a ToolbarItemGroup; a Menu in its own ToolbarItem gets a separate capsule with
        // a ⌄ pull-down indicator. Grouping each side and hiding the indicators matches the
        // iOS navigation bar. Each control is still a separate view, so toolbar overflow can
        // manage them individually.
        ToolbarItemGroup(placement: .navigation) {
            DiverFilterToolbar(uniqueDivers: store.cachedUniqueDivers, selectedDiver: $selectedDiver).picker
                .toolbarMenuIndicatorHiddenOnMac()
            settingsButton
            cloudSyncToolbarItem
            if showCalculatorsMenu {
                calculatorsMenu
                    .toolbarMenuIndicatorHiddenOnMac()
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            addDiveMenu
                .toolbarMenuIndicatorHiddenOnMac()
            filterButton
            moreMenu
                .toolbarMenuIndicatorHiddenOnMac()
        }
        #else
        DiverFilterToolbar(uniqueDivers: store.cachedUniqueDivers, selectedDiver: $selectedDiver)

        // ── Left: Settings + Bluetooth + Tools Menu ──────────────────────
        // On iOS use `.topBarLeading` (not `.navigation`) so these items stay
        // pinned to the leading edge; `.navigation` is re-flowed to the trailing
        // side by SwiftUI when popping back from a pushed detail view, which
        // crams every leading button into the top-right. Matches DiverFilterToolbar.
        ToolbarItem(placement: .topBarLeading) {
            settingsButton
        }
        ToolbarItem(placement: .topBarLeading) {
            cloudSyncToolbarItem
        }
        if showCalculatorsMenu {
            ToolbarItem(placement: .topBarLeading) {
                calculatorsMenu
            }
        }
        // ── Right ───────────────────────────────────────────────────────────

        // + menu (Add/Import/Bluetooth) + Filter + overflow menu.
        // Each control is its own ToolbarItem (not a shared HStack) so the system's
        // toolbar-overflow layout can manage/overflow them independently instead of
        // clipping the whole group when space is constrained.
        ToolbarItem(placement: .primaryAction) {
            addDiveMenu
        }
        ToolbarItem(placement: .primaryAction) {
            filterButton
        }
        ToolbarItem(placement: .primaryAction) {
            moreMenu
        }
        #endif
    }

    // Main-window toolbar controls, shared by the iOS and macOS toolbar layouts above.

    private var settingsButton: some View {
        Button(action: { showSettings = true }) {
            Image(systemName: "gear")
                .foregroundStyle(.cyan)
        }
        .help("Settings")
        .accessibilityLabel(Text("Settings"))
    }

    private var addDiveMenu: some View {
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
            Image(systemName: "plus")
                .foregroundStyle(.cyan)
        }
        .accessibilityLabel(Text("Add Dive"))
    }

    private var filterButton: some View {
        Button(action: { store.showFilterSheet = true }) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(filterToolbarIsActive ? .orange : .cyan)
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
        .accessibilityLabel(filterToolbarAccessibilityLabel)
    }

    private var moreMenu: some View {
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
                Button(action: { showPhotoBatchImport = true }) {
                    Label("Import Photos", systemImage: "photo.badge.plus")
                }
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
            Image(systemName: "ellipsis")
                .foregroundStyle(.cyan)
        }
        .accessibilityLabel(Text("More"))
    }

    // Tools menu extracted to a property to avoid
    // @State capture issues in toolbar closures on macOS.
    private var calculatorsMenu: some View {
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
        .accessibilityLabel(Text("Calculators"))
    }

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
        // Capture affected diver names before deletion so we can re-sequence
        // the remaining dives in each group afterward.
        let affectedDivers = Set(
            offsets
                .filter { $0 < displayed.count }
                .map { displayed[$0].diverName }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        )
        #if os(macOS)
        // Drop the preview's selection before its dive is deleted: the store's dive map is only
        // rebuilt on the next @Query delivery, and reading a deleted Dive in between crashes.
        if let selectedID = listSelection.diveID,
           offsets.contains(where: { $0 < displayed.count && displayed[$0].id == selectedID }) {
            listSelection.diveID = nil
        }
        #endif
        withAnimation {
            for index in offsets where index < displayed.count {
                modelContext.delete(displayed[index])
            }
            try? modelContext.save()
        }
        // Deletion triggers @Query re-delivery, which rebuilds cachedSummaries.
        // Re-sequencing runs on a background context so it doesn't block the UI;
        // commitSurfaceIntervals/commitDiveNumbers patch the caches on the MainActor
        // after the background work completes.
        if autoSequenceEnabled {
            for diver in affectedDivers {
                store.recalcSequencesInBackground(
                    container: modelContext.container,
                    newDiverName: diver,
                    originalDiverName: diver
                )
            }
        }
    }

    private func confirmDeleteSingleDive(_ dive: Dive) {
        // Capture the diver name before deletion so the remaining dives in that
        // group can be re-sequenced afterward.
        let affectedDiver = dive.diverName
        #if os(macOS)
        // Drop the preview's selection before its dive is deleted (see confirmDeleteItems).
        if listSelection.diveID == dive.id {
            listSelection.diveID = nil
        }
        #endif
        withAnimation {
            modelContext.delete(dive)
            try? modelContext.save()
        }
        if !affectedDiver.trimmingCharacters(in: .whitespaces).isEmpty && autoSequenceEnabled {
            store.recalcSequencesInBackground(
                container: modelContext.container,
                newDiverName: affectedDiver,
                originalDiverName: affectedDiver
            )
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
        if autoSequenceEnabled {
            store.recalcSequencesInBackground(
                container: modelContext.container,
                newDiverName: diverName,
                originalDiverName: diverName
            )
        }
    }
}

#if os(macOS)
// MARK: - Dive Selection & Profile Preview (macOS)

/// Selected dive of the main dive list.
@MainActor @Observable
final class DiveListSelection {
    var diveID: UUID?
}

/// Profile chart of the selected dive, shown above the main dive list. Empty until a dive
/// is selected.
private struct DiveProfilePreviewPanel: View {
    let selection: DiveListSelection
    @Environment(DiveStore.self) private var store

    /// Space the placeholder reserves before the first selection: the plot (which follows the
    /// window height) plus roughly one row of chips and one legend line, so the list moves
    /// little when the first chart appears.
    private static let chipsAndLegendHeight: CGFloat = 100

    var body: some View {
        Group {
            // A dive deleted on another device stays in the store's map until the next @Query
            // delivery; reading it would crash, so it shows as "no selection" until then.
            if let id = selection.diveID, let dive = store.diveByID[id],
               !dive.isDeleted, dive.modelContext != nil {
                if dive.profileSamples.isEmpty {
                    Text("No profile data available")
                        .foregroundStyle(.secondary)
                        .containerRelativeFrame(.vertical) { height, _ in
                            ChartHeightRule.listPreview.height(for: height) + Self.chipsAndLegendHeight
                        }
                } else {
                    // Same chart as the dive detail view: chips, every line and the legend.
                    UnifiedDiveChartOptimized(dive: dive, chartHeightRule: .listPreview)
                }
            } else {
                Text("Select a dive to preview its profile")
                    .foregroundStyle(.secondary)
                    .containerRelativeFrame(.vertical) { height, _ in
                        ChartHeightRule.listPreview.height(for: height) + Self.chipsAndLegendHeight
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Adds the selected trait to the selected dive row for VoiceOver. A modifier reading the
/// selection itself, so only the rows (not the list body) update when it changes.
private struct DiveRowSelectionAccessibility: ViewModifier {
    let selection: DiveListSelection
    let summaryID: UUID

    func body(content: Content) -> some View {
        content.accessibilityAddTraits(selection.diveID == summaryID ? .isSelected : [])
    }
}

/// Light cyan fill behind the selected dive row (the one the profile preview shows), as Finder
/// marks a selection. A fill rather than an outline: macOS draws its own accent ring around a
/// right-clicked row, and an outline doubled it. Drawn in the row background so it spans the
/// whole row and the coloured chips stay readable; its own view so only the highlights redraw
/// when the selection changes.
private struct DiveRowSelectionHighlight: View {
    let selection: DiveListSelection
    let summaryID: UUID
    @State private var prefs = UserPreferences.shared

    var body: some View {
        if prefs.showDiveListProfilePreview && selection.diveID == summaryID {
            // Inset and radius match the ring macOS draws around a right-clicked row (measured
            // on screen: about 9 pt from the row's sides, 1 pt from its top and bottom, 8 pt
            // radius), so the ring sits exactly on the fill's edge.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.cyan.opacity(0.22))
                .padding(.horizontal, 9)
                .padding(.vertical, 1)
        }
    }
}
#endif
