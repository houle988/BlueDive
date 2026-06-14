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
}

// Must match `appGroupSuite` in BlueDiveWidgetExtension.swift.
private let widgetAppGroupSuite = "group.app.bluedive.universal"


struct ContentView: View {
    @Environment(\.modelContext) var modelContext
    @Query(sort: \Dive.timestamp, order: .reverse) var dives: [Dive]
    @State private var prefs = UserPreferences.shared

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

    // MARK: - Search & Filter State
    @State private var searchText = ""
    @State private var showFilterSheet = false
    @State private var filterYear: Int? = nil
    @State private var filterYearNegate: Bool = false
    @State private var filterGasType: String? = nil
    @State private var filterGasTypeNegate: Bool = false
    @State private var filterMinDepth: Double = 0
    @State private var filterMaxDepth: Double = 0
    @State private var filterMinRating: Int = 0
    @State private var filterCountry: String? = nil
    @State private var filterCountryNegate: Bool = false
    @State private var filterDiveType: String? = nil
    @State private var filterDiveTypeNegate: Bool = false
    @State private var filterTag: String? = nil
    @State private var filterMarineLife: [String] = []
    @State private var filterMarineLifeMode: FilterMarineLifeMode = .any
    @State private var sortOrder: DiveSortOrder = .dateDesc
    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""
    @AppStorage("showCalculatorsMenu") private var showCalculatorsMenu = false
    @State private var collapsedDiverSections: Set<String> = []

    enum DiveSortOrder: String, CaseIterable, Identifiable {
        case dateDesc       = "dateDesc"
        case dateAsc        = "dateAsc"
        case depthDesc      = "depthDesc"
        case durationDesc   = "durationDesc"
        case diveNumberDesc = "diveNumberDesc"
        case diveNumberAsc  = "diveNumberAsc"
        var id: String { rawValue }
        var localizedTitle: LocalizedStringKey {
            switch self {
            case .dateDesc:       return "Date ↓"
            case .dateAsc:        return "Date ↑"
            case .depthDesc:      return "Depth ↓"
            case .durationDesc:   return "Duration ↓"
            case .diveNumberDesc: return "Dive # ↓"
            case .diveNumberAsc:  return "Dive # ↑"
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

    private var uniqueDivers: [String] {
        DiverFilter.uniqueDivers(in: dives)
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
        if filterMinDepth > 0 || filterMaxDepth > 0 { count += 1 }
        if filterMinRating > 0          { count += 1 }
        if filterCountry != nil         { count += 1 }
        if filterDiveType != nil        { count += 1 }
        if filterTag != nil             { count += 1 }
        if !filterMarineLife.isEmpty    { count += 1 }
        return count
    }

    /// Cheap fingerprint of the fields that `updateWidgetDiveData()` depends on.
    /// Avoids allocating an O(N) String array on every render (the previous approach).
    private var widgetDataFingerprint: Int {
        var hasher = Hasher()
        for dive in dives {
            hasher.combine(dive.diverName)
            hasher.combine(dive.maxDepth.bitPattern)
            hasher.combine(dive.duration)
            hasher.combine(dive.importDistanceUnit)
            hasher.combine(dive.timestamp.timeIntervalSince1970.bitPattern)
        }
        return hasher.finalize()
    }

    private var filteredAndSortedDives: [Dive] {
        var result = DiverFilter.apply(selectedDiver, to: dives).filter { dive in
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
                if filterYearNegate {
                    if diveYear == year { return false }
                } else {
                    if diveYear != year { return false }
                }
            }
            // Gas filter
            if let gas = filterGasType {
                if gas.isEmpty {
                    if !dive.gasType.isEmpty { return false }
                } else if filterGasTypeNegate {
                    if dive.gasType == gas { return false }
                } else {
                    if dive.gasType != gas { return false }
                }
            }
            // Depth range filter — compare in display units
            if filterMinDepth > 0 || filterMaxDepth > 0 {
                let depth = dive.displayMaxDepth
                if filterMinDepth > 0, filterMaxDepth > 0 {
                    let lo = Swift.min(filterMinDepth, filterMaxDepth)
                    let hi = Swift.max(filterMinDepth, filterMaxDepth)
                    if depth < lo || depth > hi { return false }
                } else if filterMinDepth > 0 {
                    if depth < filterMinDepth { return false }
                } else if filterMaxDepth > 0 {
                    if depth > filterMaxDepth { return false }
                }
            }
            // Minimum rating filter
            if filterMinRating > 0, dive.rating < filterMinRating { return false }
            // Country filter
            if let country = filterCountry {
                if country.isEmpty {
                    guard dive.siteCountry == nil || dive.siteCountry!.isEmpty else { return false }
                } else if filterCountryNegate {
                    if let diveCountry = dive.siteCountry, diveCountry == country { return false }
                } else {
                    guard let diveCountry = dive.siteCountry, diveCountry == country else { return false }
                }
            }
            // Dive type filter
            if let diveType = filterDiveType {
                if diveType.isEmpty {
                    let trimmed = dive.diveTypes?.trimmingCharacters(in: .whitespaces) ?? ""
                    if !trimmed.isEmpty { return false }
                } else {
                    let allTypes = dive.diveTypes?
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
                    if filterDiveTypeNegate {
                        if allTypes.contains(diveType) { return false }
                    } else {
                        if !allTypes.contains(diveType) { return false }
                    }
                }
            }
            // Tag filter
            if let tag = filterTag {
                if tag.isEmpty {
                    let trimmed = dive.tags?.trimmingCharacters(in: .whitespaces) ?? ""
                    if !trimmed.isEmpty { return false }
                } else {
                    let diveTags = dive.tags?
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
                    if !diveTags.contains(tag) { return false }
                }
            }
            // Marine life filter
            if !diveMatchesMarineLifeFilter(dive, species: filterMarineLife, mode: filterMarineLifeMode) { return false }
            return true
        }

        switch sortOrder {
        case .dateDesc:     result.sort { $0.timestamp > $1.timestamp }
        case .dateAsc:      result.sort { $0.timestamp < $1.timestamp }
        case .depthDesc:    result.sort { $0.displayMaxDepth > $1.displayMaxDepth }
        case .durationDesc: result.sort { $0.duration > $1.duration }
        case .diveNumberDesc: result.sort { ($0.diveNumber ?? 0) > ($1.diveNumber ?? 0) }
        case .diveNumberAsc:
            result.sort {
                switch ($0.diveNumber, $1.diveNumber) {
                case let (a?, b?): return a < b
                case (_?, nil):    return true
                case (nil, _?):    return false
                case (nil, nil):   return false
                }
            }
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
                    availableMarineLife: availableMarineLife,
                    filterYear: $filterYear,
                    filterYearNegate: $filterYearNegate,
                    filterGasType: $filterGasType,
                    filterGasTypeNegate: $filterGasTypeNegate,
                    filterMinDepth: $filterMinDepth,
                    filterMaxDepth: $filterMaxDepth,
                    filterMinRating: $filterMinRating,
                    filterCountry: $filterCountry,
                    filterCountryNegate: $filterCountryNegate,
                    filterDiveType: $filterDiveType,
                    filterDiveTypeNegate: $filterDiveTypeNegate,
                    filterTag: $filterTag,
                    filterMarineLife: $filterMarineLife,
                    filterMarineLifeMode: $filterMarineLifeMode,
                    sortOrder: $sortOrder
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
            .sheet(isPresented: $showFingerprintDebug) { FingerprintDebugView() }
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
        .onAppear { updateWidgetDiveData() }
        .onChange(of: widgetDataFingerprint) { _, _ in updateWidgetDiveData() }
        .onChange(of: prefs.depthUnit) { _, _ in updateWidgetDiveData() }
        .diverFilterReset(uniqueDivers: uniqueDivers, selectedDiver: $selectedDiver)
        .onChange(of: uniqueDivers) { _, newDivers in
            collapsedDiverSections.formIntersection(newDivers)
        }
    }

    private func updateWidgetDiveData() {
        struct DiveSnapshot {
            let diverName: String
            let duration: Int
            let maxDepth: Double
            let importDistanceUnit: String
            let timestamp: TimeInterval
        }
        // Capture value types on the main thread; computation runs on a background task.
        let snapshot = dives.map {
            DiveSnapshot(diverName: $0.diverName, duration: $0.duration,
                         maxDepth: $0.maxDepth, importDistanceUnit: $0.importDistanceUnit,
                         timestamp: $0.timestamp.timeIntervalSince1970)
        }
        let suiteName = widgetAppGroupSuite
        let depthUnitStr = prefs.depthUnit == .feet ? "feet" : "meters"
        let feetToMeters = 1.0 / DepthUnit.metersToFeetFactor  // captured on main actor; used in detached task

        // Write picker-critical keys synchronously so WidgetKit's suggestedEntities()
        // always sees the current diver list when the user opens the widget edit UI.
        // These are fast O(N) operations and safe to run on the main thread.
        let shared = UserDefaults(suiteName: suiteName)
        // totalDiveCount counts ALL dives including those with no diver name.
        // Per-diver buckets below exclude empty names, so the per-diver sum
        // may be less than totalDiveCount — this is intentional.
        shared?.set(snapshot.count, forKey: "totalDiveCount")

        var countByDiver: [String: Int] = [:]
        for dive in snapshot {
            let name = dive.diverName.trimmingCharacters(in: .whitespaces)
            // "__all__" is the sentinel ID used by DiverEntity for the "All Divers" option;
            // exclude it here so it never appears as a real diver name in any stored dict.
            guard !name.isEmpty, name != "__all__" else { continue }
            countByDiver[name, default: 0] += 1
        }
        let diverNames = countByDiver.keys.sorted()
        if let countData = try? JSONEncoder().encode(countByDiver) {
            shared?.set(countData, forKey: "diveCountByDiver")
        }
        // DiveCountWidget only needs totalDiveCount and diveCountByDiver to render;
        // diverNames is written in the detached task below, alongside the per-diver stat
        // dicts, so the picker never sees a diver whose stats haven't been written yet.
        WidgetCenter.shared.reloadTimelines(ofKind: "DiveCountWidget")

        // Heavy stats aggregation runs in the background; DiverStatsWidget reloads after.
        Task.detached(priority: .utility) {
            let shared = UserDefaults(suiteName: suiteName)

            // Depth aggregates are normalised to metres so dives imported in feet and
            // dives imported in metres can be combined without converting stored values.
            var totalMinutes: Int = 0
            var maxDepthMeters: Double = 0
            var longestDiveMinutes: Int = 0
            var mostRecent: TimeInterval = 0

            var totalMinutesByDiver: [String: Int] = [:]
            var maxDepthByDiver: [String: Double] = [:]
            var longestDiveByDiver: [String: Int] = [:]
            var mostRecentByDiver: [String: Double] = [:]

            for dive in snapshot {
                totalMinutes += dive.duration
                let factor = dive.importDistanceUnit == "feet" ? feetToMeters : 1.0
                let depthM = dive.maxDepth * factor
                if depthM > maxDepthMeters { maxDepthMeters = depthM }
                if dive.duration > longestDiveMinutes { longestDiveMinutes = dive.duration }
                if dive.timestamp > mostRecent { mostRecent = dive.timestamp }

                let name = dive.diverName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, name != "__all__" else { continue }
                totalMinutesByDiver[name, default: 0] += dive.duration
                if depthM > (maxDepthByDiver[name] ?? 0) { maxDepthByDiver[name] = depthM }
                if dive.duration > (longestDiveByDiver[name] ?? 0) { longestDiveByDiver[name] = dive.duration }
                if dive.timestamp > (mostRecentByDiver[name] ?? 0) { mostRecentByDiver[name] = dive.timestamp }
            }

            shared?.set(totalMinutes, forKey: "totalMinutesUnderwater")
            shared?.set(maxDepthMeters, forKey: "maxDepthMeters")
            shared?.set(longestDiveMinutes, forKey: "longestDiveMinutes")
            shared?.set(depthUnitStr, forKey: "depthUnit")
            if mostRecent > 0 {
                shared?.set(mostRecent, forKey: "mostRecentDiveDate")
            } else {
                shared?.removeObject(forKey: "mostRecentDiveDate")
            }

            if let data = try? JSONEncoder().encode(totalMinutesByDiver) {
                shared?.set(data, forKey: "totalMinutesByDiver")
            }
            if let data = try? JSONEncoder().encode(maxDepthByDiver) {
                shared?.set(data, forKey: "maxDepthMetersByDiver")
            }
            if let data = try? JSONEncoder().encode(longestDiveByDiver) {
                shared?.set(data, forKey: "longestDiveMinutesByDiver")
            }
            if let data = try? JSONEncoder().encode(mostRecentByDiver) {
                shared?.set(data, forKey: "mostRecentDiveDateByDiver")
            }
            // Write diverNames here, after all per-diver stat dicts, so the widget
            // picker never shows a diver whose stats haven't been written yet.
            if let namesData = try? JSONEncoder().encode(diverNames) {
                shared?.set(namesData, forKey: "diverNames")
            }

            WidgetCenter.shared.reloadTimelines(ofKind: "DiverStatsWidget")
        }
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
                let indexLookup = Dictionary(dives.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
                let filteredDiverCount = Set(displayedDives.map { $0.diverName.trimmingCharacters(in: .whitespaces) }).count
                let showGrouped = selectedDiver.isEmpty && uniqueDivers.count > 1 && filteredDiverCount > 1
                if showGrouped {
                    let grouped = groupedDives(from: displayedDives)
                    List {
                        ForEach(grouped, id: \.key) { group in
                            let diver = group.key
                            let sectionDives = group.value
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
                                ForEach(sectionDives) { dive in
                                    NavigationLink(destination: DiveDetailView(dive: dive, sortedDives: filteredAndSortedDives)) {
                                        DiveRowView(
                                            dive: dive,
                                            diveNumber: dives.count - (indexLookup[dive.id] ?? 0)
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
                                .onDelete { offsets in
                                    if let index = offsets.first {
                                        diveToDeleteDirectly = sectionDives[index]
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
                        ForEach(displayedDives) { dive in
                            NavigationLink(destination: DiveDetailView(dive: dive, sortedDives: filteredAndSortedDives)) {
                                DiveRowView(
                                    dive: dive,
                                    diveNumber: dives.count - (indexLookup[dive.id] ?? 0)
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
    }

    private func groupedDives(from sortedDives: [Dive]) -> [(key: String, value: [Dive])] {
        var order: [String] = []
        var dict: [String: [Dive]] = [:]
        for dive in sortedDives {
            let key = dive.diverName.trimmingCharacters(in: .whitespaces)
            if dict[key] == nil {
                order.append(key)
                dict[key] = []
            }
            dict[key]!.append(dive)
        }
        return order.map { (key: $0, value: dict[$0]!) }
    }
    
    // MARK: - Toolbar
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        DiverFilterToolbar(uniqueDivers: uniqueDivers, selectedDiver: $selectedDiver)

        // ── Left: Settings + Bluetooth + Tools Menu ──────────────────────
        ToolbarItem(placement: .navigation) {
            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(.cyan)
            }
            .help("Settings")
        }
        if showCalculatorsMenu {
            ToolbarItem(placement: .navigation) {
                calculatorsMenu
            }
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
                toolsPopoverButton("Calendar", icon: "calendar") {
                    showToolsPopover = false
                    showCalendarHeatmap = true
                }
                Divider()
                toolsPopoverButton("Marine Life", icon: "fish.fill") {
                    showToolsPopover = false
                    showMarineLife = true
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
            Button(action: { showCalendarHeatmap = true }) {
                Label("Calendar", systemImage: "calendar")
            }
            Divider()
            Button(action: { showMarineLife = true }) {
                Label("Marine Life", systemImage: "fish.fill")
            }
        } label: {
            Image(systemName: "square.grid.2x2.fill")
                .foregroundStyle(.cyan)
        }
        #endif
    }

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
    
    private func resetFilters() {
        filterYear           = nil
        filterYearNegate     = false
        filterGasType        = nil
        filterGasTypeNegate  = false
        filterMinDepth       = 0
        filterMaxDepth       = 0
        filterMinRating      = 0
        filterCountry        = nil
        filterCountryNegate  = false
        filterDiveType       = nil
        filterDiveTypeNegate = false
        filterTag            = nil
        filterMarineLife     = []
        filterMarineLifeMode = .any
        sortOrder            = .dateDesc
    }

    private func deleteItems(offsets: IndexSet) {
        diveToDelete = offsets
        showDeleteConfirmation = true
    }
    
    private func confirmDeleteItems(offsets: IndexSet) {
        // Use filteredAndSortedDives — IndexSet is relative to the displayed list, not the raw query.
        let displayed = filteredAndSortedDives
        withAnimation {
            for index in offsets {
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
