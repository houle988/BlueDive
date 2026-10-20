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
    case photos      = "Photos"
    case marineLife  = "Marine Life"
    case samples     = "Samples"
    case xmlExport   = "XML Export"
    case uddfExport  = "UDDF Export"

    var id: String { rawValue }

    var localizedName: LocalizedStringKey {
        switch self {
        case .menu:        return "Overview"
        case .siteDetails: return "Site Details"
        case .conditions:  return "Conditions"
        case .gaz:         return "Gas"
        case .marineLife:  return "Marine Life"
        case .photos:      return "Photos"
        case .samples:     return "Samples"
        case .xmlExport:   return "XML Export"
        case .uddfExport:  return "UDDF Export"
        }
    }

    /// Tabs visible in the tab bar (export tabs hidden)
    static var visibleCases: [DiveTab] {
        allCases.filter { $0 != .xmlExport && $0 != .uddfExport }
    }

    var icon: String {
        switch self {
        case .menu:        return "chart.xyaxis.line"
        case .siteDetails: return "mappin.and.ellipse.circle"
        case .conditions:  return "cloud.sun"
        case .gaz:         return "bubbles.and.sparkles"
        case .marineLife:  return "fish"
        case .photos:      return "photo.on.rectangle"
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
        case .marineLife:  return .orange
        case .photos:      return .pink
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
    @Environment(\.dismiss) private var dismiss
    @Environment(DiveStore.self) var store
    @Query(sort: \GearGroup.name) var gearGroups: [GearGroup]

    @State var showEditSheet = false
    @State var showAddFish = false
    @State var showAddGear = false
    @State var selectedPhotos: [PhotosPickerItem] = []
    @State var prefs = UserPreferences.shared
    @State var selectedTab: DiveTab = .menu
    /// Tab bar scroll state: whether tiles are hidden past each edge, and which tiles are
    /// fully on screen (the arrows scroll to the first hidden tile in their direction).
    @State private var tabBarHiddenLeading = false
    @State private var tabBarHiddenTrailing = false
    @State private var fullyVisibleTabs: Set<DiveTab> = []
    @State var isEditingEquipment = false
    @State var gearToDelete: Gear?
    @State var showDeleteGearAlert = false
    @State var selectedGearForDetail: Gear?
    @State var isEditingPhotos = false
    /// The photo (`DivePhotoEntry.id`) the Remove alert is about. An id, not a position: an
    /// import still running can add photos that sort ahead of it while the alert is open.
    @State var photoIDToDelete: String?
    @State var showDeletePhotoAlert = false
    @State var showPhotosPicker = false
    @State var showFileImporter = false
    @State var showFileImportError = false
    @State var photoImportResult: PhotoImporter.Result?
    /// A summary with problems (failed saves, unreadable files) waiting for the species review
    /// sheet to close: an alert cannot be shown while the sheet is presented.
    @State var pendingPhotoImportResult: PhotoImporter.Result?
    /// Dive whose photos are being imported (the import keeps running if the user moves to another dive).
    @State var importingPhotosDiveID: PersistentIdentifier?
    /// Another photo task holds the dive: the import waits for it.
    @State var photoImportWaiting = false
    /// Files the import could not decide on (they may already be in BlueDive), with the
    /// first pass's counts and the dive it imported into, waiting for the user's choices.
    @State var reimportQuestions: [PhotoImporter.ReimportQuestion] = []
    @State var reimportFirstPass: PhotoImporter.Result?
    @State var reimportDiveID: PersistentIdentifier?
    /// Held by a photo import's tasks, which may finish after this view is gone.
    @State var photoImportSession = PhotoImportSession()
    @State var showConvertLegacyPhotosAlert = false
    /// Species found in the IPTC text of photos just imported, waiting for confirmation.
    @State var speciesProposals: [SpeciesPhotoProposal] = []
    @State var isEditingMarineLife = false
    @State var fishToDelete: MarineSight?
    @State var showDeleteFishAlert = false
    @State var fishToEdit: MarineSight?
    /// Catalogue species opened from a sighting in the Marine Life grid, shown in a sheet.
    @State var shownSpecies: Species?
    @State var selectedPhotoForPreview: IdentifiablePhotoData?
    @State var selectedTankIndex: Int = 0
    @State var showFullScreenSiteMap = false
    @State private var dragOffset: CGFloat = 0
    @State private var pendingDive: Dive? = nil
    // Side the incoming preview enters from when navigateTo starts with dragOffset still 0
    // (previous/next buttons, VoiceOver actions). A swipe never needs it: the preview only
    // appears once dragOffset is already non-zero, and its sign gives the side.
    @State private var pendingEntersFromTrailing: Bool = false
    @State var viewWidth: CGFloat = 400
    @State private var scrollLocked: Bool = false
    @State private var unlockToken: UUID = UUID()
    @State private var isNavigating: Bool = false
    @State private var cachedDiveNumber: Int = 0
    @State private var cachedCurrentIndex: Int? = nil
    @State var profileSamplesLoaded = false
    /// When false, the Samples tab table shows only the first `samplesPreviewLimit` rows.
    @State var showAllSamples = false
    /// Natural widths of the Samples table header titles, measured in the current language.
    @State var sampleHeaderWidths: [SampleColumn: CGFloat] = [:]
    @Environment(\.layoutDirection) private var layoutDirection
    /// True when pushed inside a sheet on macOS (Statistics, Trips, Marine Life, Calendar).
    @Environment(\.isPushedInSheet) private var isPushedInSheet

    // Swipe navigation tuning
    private static let swipeCommitDuration: Double = 0.28
    private static let swipeSpringResponse: Double = 0.35
    private static let swipeSpringDamping: Double = 0.85
    private static let swipeEdgeThreshold: CGFloat = 20
    private static let swipeCommitDistanceRatio: CGFloat = 0.3     // Fraction of view width to trigger commit
    private static let swipeCommitPredictedRatio: CGFloat = 0.5    // Fraction for predicted-end commit
    private static let swipeRubberBandFactor: CGFloat = 0.15       // Resistance when no neighbour dive
    private static let swipeRejectionHapticThreshold: CGFloat = 8  // Minimum drag to play rejection haptic
    private static let swipeRejectionHapticIntensity: CGFloat = 0.35

    #if os(iOS)
    @State private var hapticGenerator: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.prepare()
        return g
    }()
    #endif

    init(dive: Dive, sortedDives: [Dive] = [], isSlidePreview: Bool = false, initialTab: DiveTab = .menu, diveNumber: Int = 0) {
        self._dive = State(initialValue: dive)
        self.sortedDives = sortedDives
        self.isSlidePreview = isSlidePreview
        self._selectedTab = State(initialValue: initialTab)
        self._cachedDiveNumber = State(initialValue: diveNumber)
    }

    // Export state
    #if os(iOS)
    @State var showFileExporter = false
    @State var exportDocument: ExportableFileDocument?
    @State var exportFileName: String = ""
    @State var exportContentType: UTType = .xml
    #endif

    // MARK: - Computed Properties

    private var previousDiveInList: Dive? {
        guard let idx = cachedCurrentIndex, idx > 0 else { return nil }
        return sortedDives[idx - 1]
    }

    private var nextDiveInList: Dive? {
        guard let idx = cachedCurrentIndex, idx + 1 < sortedDives.count else { return nil }
        return sortedDives[idx + 1]
    }

    var diveNumber: Int { cachedDiveNumber }

    private func pendingDiveNumber(for d: Dive) -> Int {
        // Relative position in the sorted list — used only as a fallback in the swipe preview title.
        let idx = sortedDives.firstIndex(of: d) ?? 0
        return sortedDives.count - idx
    }

    /// True when the detail view is configured to support swipe-based dive navigation.
    private var swipeNavigationEnabled: Bool {
        !isSlidePreview && !sortedDives.isEmpty
    }

    private func refreshCaches(for d: Dive) {
        cachedCurrentIndex = sortedDives.isEmpty ? nil : sortedDives.firstIndex(of: d)
    }

    @ViewBuilder
    private func diveTitleLabel(number: Int, siteName: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: "#\(number)")
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.cyan.opacity(0.2))
                .foregroundStyle(Color.readableCyan)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(siteName)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: String(format: NSLocalizedString("Dive %@, %@", bundle: Bundle.forAppLanguage(), comment: "VoiceOver label for a dive entry. First argument is the dive number (e.g. 1140), second is the site name."), "\(number)", siteName)))
    }

    var locationText: Text {
        if let country = dive.siteCountry, !country.isEmpty {
            // If both location and country exist, combine them
            if !dive.location.isEmpty && dive.location != "Inconnu" && dive.location != NSLocalizedString("Unknown", bundle: Bundle.forAppLanguage(), comment: "") {
                return Text(verbatim: "\(dive.location), \(country)")
            }
            // If only country exists
            return Text(verbatim: country)
        }
        // If only location exists
        if !dive.location.isEmpty && dive.location != "Inconnu" && dive.location != NSLocalizedString("Unknown", bundle: Bundle.forAppLanguage(), comment: "") {
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
                    DiveSlidingPreview(dive: pending, diveNumber: pending.diveNumber ?? pendingDiveNumber(for: pending), initialTab: selectedTab)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .offset(x: (dragOffset < 0 || (dragOffset == 0 && pendingEntersFromTrailing))
                            ? dragOffset + geo.size.width
                            : dragOffset - geo.size.width)
                }

                // Current dive content
                VStack(spacing: 0) {
                    // The photo import's dialogs hang on the tab bar, which is always shown, so
                    // an import finishing while another tab is open still presents them.
                    photoImportDialogs(diveTabBar)

                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 20) {
                                Color.clear.frame(height: 0).id("diveTop")
                                switch selectedTab {
                                case .menu:        menuTabContent
                                case .siteDetails: siteDetailsTabContent
                                case .conditions:  conditionsTabContent
                                case .gaz:         gazTabContent
                                case .marineLife:  marineSightingsSection
                                case .photos:      photosSection
                                case .samples:     samplesTabContent
                                case .xmlExport:   xmlExportTabContent
                                case .uddfExport:  uddfExportTabContent
                                }
                            }
                            .padding(.bottom, 30)
                            .animation(.easeInOut(duration: 0.25), value: selectedTab)
                        }
                        .scrollDisabled(scrollLocked)
                        .onChange(of: dive) { _, _ in
                            showAllSamples = false
                            proxy.scrollTo("diveTop", anchor: .top)
                        }
                        // Leave the Samples tab if it is hidden in Settings while it is shown.
                        .onChange(of: prefs.showSamplesTab) { _, isShown in
                            if !isShown && selectedTab == .samples { selectedTab = .menu }
                        }
                        // Leave photo and marine life edit mode with their tab.
                        .onChange(of: selectedTab) { _, _ in
                            isEditingPhotos = false
                            isEditingMarineLife = false
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .background(AppBackground())
                .offset(x: dragOffset)
            }
            .clipped()
            .onAppear {
                viewWidth = geo.size.width
                refreshCaches(for: dive)
            }
            .onChange(of: geo.size.width) { viewWidth = geo.size.width }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    guard !sortedDives.isEmpty, !isNavigating else { return }
                    // Only activate from screen edges to avoid conflicting with internal horizontal scrolling
                    let edgeThreshold = Self.swipeEdgeThreshold
                    guard dragOffset != 0 ||
                          value.startLocation.x < edgeThreshold ||
                          value.startLocation.x > viewWidth - edgeThreshold
                    else { return }
                    let h = value.translation.width
                    let v = value.translation.height
                    guard abs(h) > abs(v) || dragOffset != 0 else { return }
                    if !scrollLocked { scrollLocked = true }
                    // Treat a leftward visual drag as "next" regardless of layout direction.
                    let goingNext = layoutDirection == .rightToLeft ? (h > 0) : (h < 0)
                    let target = goingNext ? nextDiveInList : previousDiveInList
                    pendingDive = target
                    let rawOffset = target != nil ? h : h * Self.swipeRubberBandFactor
                    dragOffset = max(-viewWidth, min(viewWidth, rawOffset))
                }
                .onEnded { value in
                    guard !sortedDives.isEmpty, dragOffset != 0 else {
                        dragOffset = 0; pendingDive = nil; scrollLocked = false; return
                    }
                    let predicted = value.predictedEndTranslation.width
                    let threshold = viewWidth * Self.swipeCommitDistanceRatio
                    let predictedThreshold = viewWidth * Self.swipeCommitPredictedRatio
                    let visualNext = (dragOffset < -threshold || predicted < -predictedThreshold)
                    let visualPrev = (dragOffset > threshold || predicted > predictedThreshold)
                    let goNext = layoutDirection == .rightToLeft ? visualPrev : visualNext
                    let goPrev = layoutDirection == .rightToLeft ? visualNext : visualPrev
                    if goNext, let next = nextDiveInList {
                        navigateTo(next, forward: true)
                    } else if goPrev, let prev = previousDiveInList {
                        navigateTo(prev, forward: false)
                    } else {
                        #if os(iOS)
                        // Subtle feedback when the swipe doesn't commit.
                        if abs(dragOffset) > Self.swipeRejectionHapticThreshold {
                            let g = UIImpactFeedbackGenerator(style: .rigid)
                            g.impactOccurred(intensity: Self.swipeRejectionHapticIntensity)
                        }
                        #endif
                        withAnimation(.spring(response: Self.swipeSpringResponse, dampingFraction: Self.swipeSpringDamping)) {
                            dragOffset = 0
                            pendingDive = nil
                        }
                        // Keep scroll locked until the spring settles so the ScrollView
                        // doesn't apply any residual vertical movement on release.
                        let token = UUID()
                        unlockToken = token
                        DispatchQueue.main.asyncAfter(deadline: .now() + Self.swipeSpringResponse + 0.05) {
                            if unlockToken == token, dragOffset == 0, pendingDive == nil {
                                scrollLocked = false
                            }
                        }
                    }
                }
        )
        .modifier(NavTitleIfNotPreview(title: dive.siteName, isSlidePreview: isSlidePreview))
        .background(AppBackground().ignoresSafeArea())
        #if os(iOS)
        // Disable the system interactive back-swipe so our own edge swipe can
        // navigate to the previous dive instead of popping to the list.
        // Providing a custom leading back button keeps the standard back
        // affordance while SwiftUI suppresses the swipe gesture.
        .navigationBarBackButtonHidden(swipeNavigationEnabled)
        #endif

        .toolbar {
            if !isSlidePreview {
                #if os(iOS)
                if swipeNavigationEnabled {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.backward")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.cyan)
                                .padding(8)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(Text("Back"))
                    }
                }
                #endif
                #if os(macOS)
                // One ToolbarItemGroup per cluster so macOS shares a glass capsule, as the iOS
                // navigation bar does; separate items (especially menus) get separate capsules.
                // In a sheet, macOS draws a .primaryAction item as the sheet's accent-filled
                // default button at the bottom (cyan icons on a cyan fill), so a dive pushed
                // inside a sheet uses .sheetPrimaryAction for both groups instead.
                if !sortedDives.isEmpty {
                    ToolbarItemGroup(placement: isPushedInSheet ? .sheetPrimaryAction : .principalOutsideTabBar) {
                        previousDiveButton
                        nextDiveButton
                    }
                    // Both groups sit in the trailing area (.principalOutsideTabBar is
                    // .primaryAction on macOS), where macOS would merge them into one capsule;
                    // a fixed spacer keeps previous/next and Export/Edit as distinct groups.
                    // (Pre-26 toolbars have no Liquid Glass merging, so no spacer is needed there.)
                    if #available(iOS 26.0, macOS 26.0, *) {
                        ToolbarSpacer(.fixed, placement: isPushedInSheet ? .sheetPrimaryAction : .primaryAction)
                    }
                }
                ToolbarItemGroup(placement: isPushedInSheet ? .sheetPrimaryAction : .primaryAction) {
                    exportDiveMenu
                        .toolbarMenuIndicatorHiddenOnMac()
                    editDiveButton
                }
                #else
                ToolbarItem(placement: .principal) {
                    ZStack {
                        diveTitleLabel(number: dive.diveNumber ?? diveNumber,
                                       siteName: dive.siteName)
                            .offset(x: dragOffset)
                        if let pending = pendingDive {
                            diveTitleLabel(number: pending.diveNumber ?? pendingDiveNumber(for: pending),
                                           siteName: pending.siteName)
                                .offset(x: dragOffset < 0
                                        ? dragOffset + viewWidth
                                        : dragOffset - viewWidth)
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    exportDiveMenu
                }

                ToolbarItem(placement: .primaryAction) {
                    editDiveButton
                }
                #endif
            }
        }
        .sheet(isPresented: $showEditSheet) {
            editSheetForCurrentTab
                .standardSheetPresentation()
        }
        .sheet(isPresented: $showAddFish) {
            DiveMarineLifeSheet(dive: dive)
                .standardSheetPresentation()
        }
        // No marine life left (removed here or from the Marine Life sheet): edit mode ends, so
        // the next sightings do not appear with remove badges.
        .onChange(of: (dive.seenFish ?? []).isEmpty) { _, isEmpty in
            if isEmpty { isEditingMarineLife = false }
        }
        // A sighting not in the catalogue: linked to a species (catalogue sightings open
        // their species page and change their quantity from their tile).
        .sheet(item: $fishToEdit) { fish in
            LinkSightingSheet(fish: fish)
                .standardSheetPresentation()
        }
        .sheet(item: $shownSpecies) { species in
            SpeciesSheet(species: species, numberMap: speciesPageNumberMap, showDiveList: nil)
                .standardSheetPresentation()
        }
        .sheet(isPresented: $showAddGear) {
            AddGearToDiveView(dive: dive)
                .standardSheetPresentation()
        }
        .sheet(item: $selectedGearForDetail) { gear in
            GearServiceView(gear: gear)
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
        .onChange(of: dive) { oldValue, newValue in
            guard oldValue != newValue else { return }
            cachedDiveNumber = newValue.diveNumber ?? pendingDiveNumber(for: newValue)
            refreshCaches(for: newValue)
            // Reset per-dive UI state when navigating to a different dive
            selectedTankIndex = 0
            showEditSheet = false
            showAddFish = false
            showAddGear = false
            showFullScreenSiteMap = false
            selectedPhotos = []
            showPhotosPicker = false
            showFileImporter = false
            showFileImportError = false
            photoImportResult = nil
            pendingPhotoImportResult = nil
            showConvertLegacyPhotosAlert = false
            speciesProposals = []
            isEditingEquipment = false
            isEditingPhotos = false
            isEditingMarineLife = false
            selectedGearForDetail = nil
            // Also clear transient targets so they can't point to the previous dive's items.
            selectedPhotoForPreview = nil
            gearToDelete = nil
            photoIDToDelete = nil
            fishToDelete = nil
            fishToEdit = nil
            showDeleteGearAlert = false
            showDeletePhotoAlert = false
            showDeleteFishAlert = false
            #if os(iOS)
            showFileExporter = false
            // Announce the newly-focused dive for VoiceOver users.
            let number = newValue.diveNumber ?? cachedDiveNumber
            let announcement = String(format: NSLocalizedString("Dive %@, %@", bundle: Bundle.forAppLanguage(), comment: "VoiceOver screen-change announcement when navigating to a dive. First argument is the dive number (e.g. 1140), second is the site name."), "\(number)", newValue.siteName)
            UIAccessibility.post(notification: .screenChanged, argument: announcement)
            #endif
        }
        .onAppear { photoImportSession.isShown = true }
        .onDisappear {
            // Invalidate any pending async reset so it can't fire after the view leaves.
            unlockToken = UUID()
            photoImportSession.isShown = false
        }
        #if os(iOS)
        .accessibilityAction(named: Text("Previous dive")) {
            if let prev = previousDiveInList { navigateTo(prev, forward: false) }
        }
        .accessibilityAction(named: Text("Next dive")) {
            if let next = nextDiveInList { navigateTo(next, forward: true) }
        }
        #endif
    }

    // MARK: - Dive Navigation

    private func navigateTo(_ targetDive: Dive, forward: Bool) {
        // Prevent overlapping navigations from rapid chevron taps.
        guard !isNavigating else { return }
        isNavigating = true
        // Visual direction: "forward" means the incoming dive comes from the trailing edge.
        let rtl = layoutDirection == .rightToLeft
        let visualForward = rtl ? !forward : forward
        // Set before pendingDive so the preview is first placed on the correct side while
        // dragOffset is still 0; otherwise "next" starts on the left and slides across the
        // outgoing dive instead of in from the right.
        pendingEntersFromTrailing = visualForward
        pendingDive = targetDive
        let targetOffset: CGFloat = visualForward ? -viewWidth : viewWidth
        #if os(iOS)
        hapticGenerator.impactOccurred()
        hapticGenerator.prepare() // ready for the next commit
        #endif
        let token = UUID()
        unlockToken = token
        withAnimation(.easeOut(duration: Self.swipeCommitDuration)) {
            dragOffset = targetOffset
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.swipeCommitDuration) {
            guard unlockToken == token else { isNavigating = false; return }
            dive = targetDive
            dragOffset = 0
            pendingDive = nil
            scrollLocked = false
            isNavigating = false
        }
    }

    #if os(macOS)
    // Previous / next dive buttons (macOS replaces the iOS swipe-between-dives gesture).
    // Each is its own ToolbarItem so toolbar overflow can manage them independently.
    private var previousDiveButton: some View {
        Button {
            if let prev = previousDiveInList { navigateTo(prev, forward: false) }
        } label: {
            Image(systemName: "chevron.left")
                .foregroundStyle(previousDiveInList != nil ? Color.cyan : Color.secondary.opacity(0.3))
        }
        .disabled(previousDiveInList == nil)
        .help("Previous dive")
        .accessibilityLabel(Text("Previous dive"))
    }

    private var nextDiveButton: some View {
        Button {
            if let next = nextDiveInList { navigateTo(next, forward: true) }
        } label: {
            Image(systemName: "chevron.right")
                .foregroundStyle(nextDiveInList != nil ? Color.cyan : Color.secondary.opacity(0.3))
        }
        .disabled(nextDiveInList == nil)
        .help("Next dive")
        .accessibilityLabel(Text("Next dive"))
    }
    #endif

    // Export / Edit toolbar controls, shared by the iOS and macOS toolbar layouts.

    private var exportDiveMenu: some View {
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
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(.cyan)
        }
        .accessibilityLabel(Text("Export Dive"))
    }

    private var editDiveButton: some View {
        // Edit button
        Button {
            showEditSheet = true
        } label: {
            Image(systemName: "pencil")
                .foregroundStyle(.cyan)
        }
        .accessibilityLabel(Text("Edit Dive"))
    }

    // MARK: - Tab Bar

    private var diveTabBar: some View {
        // Scrollable tab bar, the selected tab marked in its colour.
        let tabs = DiveTab.visibleCases.filter { $0 != .samples || prefs.showSamplesTab }
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
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
                            .contentShape(Rectangle())
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
                        .id(tab)
                        .onScrollVisibilityChange(threshold: 0.95) { isVisible in
                            if isVisible {
                                fullyVisibleTabs.insert(tab)
                            } else {
                                fullyVisibleTabs.remove(tab)
                            }
                        }
                    }
                }
            }
            // Tiles hidden past an edge: the bar is wider than an iPhone screen.
            .onScrollGeometryChange(for: [Bool].self) { geometry in
                // The visible part of the content, in content coordinates (insets included).
                let visible = geometry.visibleRect
                return [visible.minX > 1, visible.maxX < geometry.contentSize.width - 1]
            } action: { _, hidden in
                withAnimation(.easeInOut(duration: 0.2)) {
                    tabBarHiddenLeading = hidden[0]
                    tabBarHiddenTrailing = hidden[1]
                }
            }
            // Fade the tiles under each arrow so the bar reads as continuing past the edge.
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: tabBarHiddenLeading ? 36 : 0)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: tabBarHiddenTrailing ? 36 : 0)
                }
            }
            .overlay(alignment: .leading) {
                if tabBarHiddenLeading {
                    tabBarScrollArrow(systemName: "chevron.left") {
                        // The last tile before the first fully visible one — or the first tile
                        // itself when only its edge is cut off (it still counts as visible).
                        guard let first = tabs.firstIndex(where: fullyVisibleTabs.contains) else { return }
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(tabs[max(first - 1, 0)], anchor: .center) }
                    }
                    .accessibilityLabel(Text("Scroll tabs left"))
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .trailing) {
                if tabBarHiddenTrailing {
                    tabBarScrollArrow(systemName: "chevron.right") {
                        // The first tile after the last fully visible one — or the last tile
                        // itself when only its edge is cut off (it still counts as visible).
                        guard let last = tabs.lastIndex(where: fullyVisibleTabs.contains) else { return }
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(tabs[min(last + 1, tabs.count - 1)], anchor: .center) }
                    }
                    .accessibilityLabel(Text("Scroll tabs right"))
                    .transition(.opacity)
                }
            }
            // Keep the selected tab in view: the bar is wider than an iPhone screen, and a dive
            // can open on a later tab (e.g. Marine Life, from a species).
            .onAppear { proxy.scrollTo(selectedTab, anchor: .center) }
            .onChange(of: selectedTab) { _, tab in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(tab, anchor: .center) }
            }
        }
        .background(Color.primary.opacity(0.05))
    }

    /// A translucent edge arrow shown when more tab tiles are hidden in its direction.
    private func tabBarScrollArrow(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                // A full-height translucent strip, the same height as the tab bar.
                .frame(width: 28)
                .frame(maxHeight: .infinity)
                .background(.ultraThinMaterial)
                .contentShape(Rectangle())
        }
        .borderlessButton()
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
            EditGazView(dive: dive, tankIndex: selectedTankIndex) { newIndex in
                selectedTankIndex = newIndex
            }
        case .marineLife:
            // Marine life is added and removed with its card's own buttons.
            noEditAvailableView(title: DiveTab.marineLife.localizedName,
                                message: "Add or remove marine life with the buttons on its card.")
        case .photos:
            // Photos are added and removed with their card's own buttons.
            noEditAvailableView(title: DiveTab.photos.localizedName,
                                message: "Add or remove photos with the buttons on their card.")
        case .samples:
            // Samples come from a dive computer — no manual editing
            noEditAvailableView(title: DiveTab.samples.localizedName,
                                message: "Samples come from your dive computer and cannot be manually edited.")
        case .xmlExport:
            noEditAvailableView(title: DiveTab.xmlExport.localizedName,
                                message: "The XML export is automatically generated from internal data and cannot be edited.")
        case .uddfExport:
            noEditAvailableView(title: DiveTab.uddfExport.localizedName,
                                message: "The UDDF export is automatically generated from internal data and cannot be edited.")
        }
    }

    @ViewBuilder
    private func noEditAvailableView(title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "lock.circle")
                    .font(.system(size: 50))
                    .foregroundStyle(.secondary)
                Text("Editing Not Available")
                    .font(.headline).foregroundStyle(.primary)
                Text(message)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppBackground().ignoresSafeArea())
            .navigationTitle(Text(title))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { showEditSheet = false }
                }
            }
        }
    }
}

// Applies navigationTitle + navigation-bar display mode only when the view is NOT
// rendered as a slide preview. This prevents the preview (nested DiveDetailView
// during swipe) from overriding the host's navigation title — which would make
// the title briefly disappear and shift the content vertically.
private struct NavTitleIfNotPreview: ViewModifier {
    let title: String
    let isSlidePreview: Bool

    func body(content: Content) -> some View {
        if isSlidePreview {
            content
        } else {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// State of a dive's photo import that must outlive `DiveDetailView`: the import's tasks hold
/// it, and can still tell after an `await` whether the screen is shown and whether the
/// re-import decision sheet has closed. Not observed by any view.
@MainActor
final class PhotoImportSession {
    /// The dive screen is on screen.
    var isShown = true
    /// The re-import decision sheet is presented (until its dismissal has finished).
    var decisionSheetOpen = false
    /// The finished import's summary, waiting for the decision sheet to close.
    var pendingSummary: (result: PhotoImporter.Result, diveID: PersistentIdentifier)?
}
