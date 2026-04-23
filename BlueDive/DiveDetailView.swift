import SwiftUI
import Charts
import SwiftData
import PhotosUI
import MapKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

// MARK: - Dive Tab Categories

enum DiveTab: String, CaseIterable, Identifiable {
    case menu        = "Overview"
    case siteDetails = "Site Details"
    case conditions  = "Conditions"
    case gaz         = "Gas"
    case samples     = "Samples"
    case xmlExport   = "XML Export"
    case uddfExport  = "UDDF Export"

    var id: String { rawValue }

    var localizedName: LocalizedStringKey { LocalizedStringKey(rawValue) }

    /// Tabs visible in the tab bar (export tabs hidden)
    static var visibleCases: [DiveTab] {
        allCases.filter { $0 != .xmlExport && $0 != .uddfExport }
    }

    var icon: String {
        switch self {
        case .menu:        return "chart.xyaxis.line"
        case .siteDetails: return "mappin.and.ellipse.circle.fill"
        case .conditions:  return "cloud.sun.fill"
        case .gaz:         return "bubbles.and.sparkles.fill"
        case .samples:     return "waveform.path.ecg"
        case .xmlExport:   return "doc.text.magnifyingglass"
        case .uddfExport:  return "doc.badge.gearshape.fill"
        }
    }

    var color: Color {
        switch self {
        case .menu:        return .cyan
        case .siteDetails: return .blue
        case .conditions:  return .yellow
        case .gaz:         return .green
        case .samples:     return .teal
        case .xmlExport:   return .indigo
        case .uddfExport:  return .teal
        }
    }
}

// MARK: - DiveDetailView

struct DiveDetailView: View {
    @State var dive: Dive
    let sortedDives: [Dive]
    let isSlidePreview: Bool
    @Environment(\.modelContext) var modelContext
    @Environment(\.locale) var locale
    @Query(sort: \Dive.timestamp, order: .reverse) var allDives: [Dive]
    @Query(sort: \GearGroup.name) var gearGroups: [GearGroup]

    @State var showEditSheet = false
    @State var showAddFish = false
    @State var showAddGear = false
    @State var selectedPhotos: [PhotosPickerItem] = []
    @State var prefs = UserPreferences.shared
    @State var selectedTab: DiveTab = .menu
    @State var isEditingEquipment = false
    @State var gearToDelete: Gear?
    @State var showDeleteGearAlert = false
    @State var isEditingPhotos = false
    @State var photoIndexToDelete: Int?
    @State var showDeletePhotoAlert = false
    @State var isEditingMarineLife = false
    @State var fishToDelete: MarineSight?
    @State var showDeleteFishAlert = false
    @State var fishToEdit: MarineSight?
    @State var selectedPhotoForPreview: IdentifiablePhotoData?
    @State var selectedTankIndex: Int = 0
    @State private var dragOffset: CGFloat = 0
    @State private var pendingDive: Dive? = nil
    @State private var viewWidth: CGFloat = 400

    init(dive: Dive, sortedDives: [Dive] = [], isSlidePreview: Bool = false, initialTab: DiveTab = .menu) {
        self._dive = State(initialValue: dive)
        self.sortedDives = sortedDives
        self.isSlidePreview = isSlidePreview
        self._selectedTab = State(initialValue: initialTab)
    }

    // Export state
    #if os(iOS)
    @State var showFileExporter = false
    @State var exportDocument: ExportableFileDocument?
    @State var exportFileName: String = ""
    @State var exportContentType: UTType = .xml
    #endif

    // MARK: - Computed Properties

    private var currentIndexInSorted: Int? {
        guard !sortedDives.isEmpty else { return nil }
        return sortedDives.firstIndex(of: dive)
    }

    private var previousDiveInList: Dive? {
        guard let idx = currentIndexInSorted, idx > 0 else { return nil }
        return sortedDives[idx - 1]
    }

    private var nextDiveInList: Dive? {
        guard let idx = currentIndexInSorted, idx + 1 < sortedDives.count else { return nil }
        return sortedDives[idx + 1]
    }

    var diveNumber: Int {
        allDives.count - (allDives.firstIndex(of: dive) ?? 0)
    }

    var locationText: Text {
        if let country = dive.siteCountry, !country.isEmpty {
            // If both location and country exist, combine them
            if !dive.location.isEmpty && dive.location != "Inconnu" && dive.location != String(localized: "Unknown") {
                return Text(verbatim: "\(dive.location), \(country)")
            }
            // If only country exists
            return Text(verbatim: country)
        }
        // If only location exists
        if !dive.location.isEmpty && dive.location != "Inconnu" && dive.location != String(localized: "Unknown") {
            return Text(verbatim: dive.location)
        }
        // Fallback
        return Text("Unknown location")
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // Incoming dive preview — slides in from the side during navigation
                if let pending = pendingDive {
                    DiveSlidingPreview(dive: pending, initialTab: selectedTab)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .offset(x: dragOffset < 0
                            ? dragOffset + geo.size.width
                            : dragOffset - geo.size.width)
                }

                // Current dive content
                VStack(spacing: 0) {
                    diveTabBar

                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 20) {
                                Color.clear.frame(height: 0).id("diveTop")
                                switch selectedTab {
                                case .menu:        menuTabContent
                                case .siteDetails: siteDetailsTabContent
                                case .conditions:  conditionsTabContent
                                case .gaz:         gazTabContent
                                case .samples:     samplesTabContent
                                case .xmlExport:   xmlExportTabContent
                                case .uddfExport:  uddfExportTabContent
                                }
                            }
                            .padding(.bottom, 30)
                            .animation(.easeInOut(duration: 0.25), value: selectedTab)
                        }
                        .onChange(of: dive) {
                            proxy.scrollTo("diveTop", anchor: .top)
                        }
                    }
                }
                .frame(width: geo.size.width)
                .background(Color.platformBackground)
                .offset(x: dragOffset)
            }
            .clipped()
            .onAppear { viewWidth = geo.size.width }
            .onChange(of: geo.size.width) { viewWidth = geo.size.width }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    guard !sortedDives.isEmpty else { return }
                    // Only activate from screen edges to avoid conflicting with internal horizontal scrolling
                    let edgeThreshold: CGFloat = 20
                    guard dragOffset != 0 ||
                          value.startLocation.x < edgeThreshold ||
                          value.startLocation.x > viewWidth - edgeThreshold
                    else { return }
                    let h = value.translation.width
                    let v = value.translation.height
                    guard abs(h) > abs(v) || dragOffset != 0 else { return }
                    if h < 0 {
                        let target = nextDiveInList
                        pendingDive = target
                        dragOffset = target != nil ? h : h * 0.15
                    } else {
                        let target = previousDiveInList
                        pendingDive = target
                        dragOffset = target != nil ? h : h * 0.15
                    }
                }
                .onEnded { value in
                    guard !sortedDives.isEmpty, dragOffset != 0 else {
                        dragOffset = 0; pendingDive = nil; return
                    }
                    let predicted = value.predictedEndTranslation.width
                    let threshold = viewWidth * 0.3
                    if (dragOffset < -threshold || predicted < -(viewWidth * 0.5)),
                       let next = nextDiveInList {
                        navigateTo(next, forward: true)
                    } else if (dragOffset > threshold || predicted > viewWidth * 0.5),
                              let prev = previousDiveInList {
                        navigateTo(prev, forward: false)
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            dragOffset = 0
                            pendingDive = nil
                        }
                    }
                }
        )
        .navigationTitle(isSlidePreview ? "" : dive.siteName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .background(Color.platformBackground.ignoresSafeArea())

        .toolbar {
            if !isSlidePreview {
                #if os(macOS)
                if !sortedDives.isEmpty {
                    ToolbarItem(placement: .principal) {
                        diveNavigationButtons
                    }
                }
                #endif
                ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    // Export menu
                    Menu {
                        Button {
                            exportToXML()
                        } label: {
                            Label("Export Dive to XML", systemImage: "doc.text")
                        }
                        Button {
                            exportToUDDF()
                        } label: {
                            Label("Export Dive to UDDF", systemImage: "doc.badge.gearshape")
                        }
                        Button {
                            exportToPDF()
                        } label: {
                            Label("Export Dive to PDF", systemImage: "doc.richtext")
                        }
                    } label: {
                        #if os(macOS)
                        Label("Export", systemImage: "square.and.arrow.up.circle.fill")
                            .foregroundStyle(.cyan)
                        #else
                        Image(systemName: "square.and.arrow.up.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.cyan)
                        #endif
                    }

                    // Edit button
                    Button {
                        showEditSheet = true
                    } label: {
                        #if os(macOS)
                        Label("Edit", systemImage: "pencil.circle.fill")
                            .foregroundStyle(.cyan)
                        #else
                        Image(systemName: "pencil.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.cyan)
                        #endif
                    }
                }
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            editSheetForCurrentTab
                #if os(iOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                #endif
        }
        .sheet(isPresented: $showAddFish) {
            AddFishView(dive: dive)
        }
        .sheet(item: $fishToEdit) { fish in
            EditFishView(fish: fish)
        }
        .sheet(isPresented: $showAddGear) {
            AddGearToDiveView(dive: dive)
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
        .onChange(of: dive) {
            // Reset per-dive UI state when navigating to a different dive
            selectedTankIndex = 0
            showEditSheet = false
            showAddFish = false
            showAddGear = false
            selectedPhotos = []
            isEditingEquipment = false
            isEditingPhotos = false
            isEditingMarineLife = false
        }
    }

    // MARK: - Dive Navigation

    private func navigateTo(_ targetDive: Dive, forward: Bool) {
        pendingDive = targetDive
        let targetOffset: CGFloat = forward ? -viewWidth : viewWidth
        withAnimation(.easeOut(duration: 0.28)) {
            dragOffset = targetOffset
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            dive = targetDive
            dragOffset = 0
            pendingDive = nil
        }
    }

    private var diveNavigationButtons: some View {
        HStack(spacing: 4) {
            Button {
                if let prev = previousDiveInList { navigateTo(prev, forward: false) }
            } label: {
                Image(systemName: "chevron.left.circle.fill")
                    .font(.title3)
                    .foregroundStyle(previousDiveInList != nil ? Color.cyan : Color.secondary.opacity(0.3))
            }
            .disabled(previousDiveInList == nil)
            .help("Previous dive")

            Button {
                if let next = nextDiveInList { navigateTo(next, forward: true) }
            } label: {
                Image(systemName: "chevron.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(nextDiveInList != nil ? Color.cyan : Color.secondary.opacity(0.3))
            }
            .disabled(nextDiveInList == nil)
            .help("Next dive")
        }
    }

    // MARK: - Tab Bar

    private var diveTabBar: some View {
        #if os(macOS)
        // macOS : segmented control natif
        Picker("", selection: $selectedTab) {
            ForEach(DiveTab.visibleCases) { tab in
                Label(tab.localizedName, systemImage: tab.icon).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05))
        .animation(.easeInOut(duration: 0.2), value: selectedTab)
        #else
        // iOS : tab bar scrollable avec indicateur coloré
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(DiveTab.visibleCases) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTab = tab
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 18))
                                .foregroundStyle(selectedTab == tab ? tab.color : .secondary)
                            Text(tab.localizedName)
                                .font(.caption2)
                                .fontWeight(selectedTab == tab ? .semibold : .regular)
                                .foregroundStyle(selectedTab == tab ? tab.color : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 20)
                        .background(
                            selectedTab == tab
                                ? tab.color.opacity(0.12)
                                : Color.clear
                        )
                        .animation(.easeInOut(duration: 0.2), value: selectedTab)
                        .overlay(
                            Rectangle()
                                .fill(selectedTab == tab ? tab.color : Color.clear)
                                .frame(height: 2),
                            alignment: .bottom
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Color.primary.opacity(0.05))
        #endif
    }

    // MARK: - Edit Sheet Router

    @ViewBuilder
    private var editSheetForCurrentTab: some View {
        switch selectedTab {
        case .menu:
            EditMenuStatsView(dive: dive)
        case .siteDetails:
            EditSiteDetailsView(dive: dive)
        case .conditions:
            EditConditionsView(dive: dive)
        case .gaz:
            EditGazView(dive: dive, tankIndex: selectedTankIndex)
        case .samples:
            // Samples come from a dive computer — no manual editing
            noEditAvailableView(message: "Samples come from your dive computer and cannot be manually edited.")
        case .xmlExport:
            noEditAvailableView(message: "The XML export is automatically generated from internal data and cannot be edited.")
        case .uddfExport:
            noEditAvailableView(message: "The UDDF export is automatically generated from internal data and cannot be edited.")
        }
    }

    @ViewBuilder
    private func noEditAvailableView(message: LocalizedStringKey) -> some View {
        #if os(macOS)
        VStack(spacing: 20) {
            HStack {
                Spacer()
                Button("Close") { showEditSheet = false }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
            Spacer()
            Image(systemName: "lock.circle.fill")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)
            Text("Editing Not Available")
                .font(.headline).foregroundStyle(.primary)
            Text(message)
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 30)
            Spacer()
        }
        .frame(width: 400, height: 280)
        .background(Color(NSColor.windowBackgroundColor))
        #else
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "lock.circle.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.secondary)
                Text("Editing Not Available")
                    .font(.headline).foregroundStyle(.primary)
                Text(message)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.platformBackground.ignoresSafeArea())
            .navigationTitle("Samples")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { showEditSheet = false }.foregroundStyle(.cyan)
                }
            }
        }
        #endif
    }
}
