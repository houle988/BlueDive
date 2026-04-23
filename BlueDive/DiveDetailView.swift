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
    @State private var scrollLocked: Bool = false
    @State private var unlockToken: UUID = UUID()
    @State private var isNavigating: Bool = false
    @State private var cachedDiveNumber: Int = 0
    @State private var cachedCurrentIndex: Int? = nil
    @Environment(\.layoutDirection) private var layoutDirection

    // Swipe navigation tuning
    private static let swipeCommitDuration: Double = 0.28
    private static let swipeSpringResponse: Double = 0.35
    private static let swipeSpringDamping: Double = 0.85
    private static let swipeEdgeThreshold: CGFloat = 40
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
        // Only evaluated for the transient preview during a swipe.
        allDives.count - (allDives.firstIndex(of: d) ?? 0)
    }

    private func refreshCaches(for d: Dive) {
        cachedDiveNumber = allDives.count - (allDives.firstIndex(of: d) ?? 0)
        cachedCurrentIndex = sortedDives.isEmpty ? nil : sortedDives.firstIndex(of: d)
    }

    @ViewBuilder
    private func diveTitleLabel(number: Int, siteName: String) -> some View {
        HStack(spacing: 6) {
            Text("#\(number)")
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.cyan.opacity(0.2))
                .foregroundStyle(.cyan)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(siteName)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Dive \(number), \(siteName)"))
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
                        .scrollDisabled(scrollLocked)
                        .onChange(of: dive) { _, _ in
                            proxy.scrollTo("diveTop", anchor: .top)
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .background(Color.platformBackground)
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
        .background(Color.platformBackground.ignoresSafeArea())
        #if os(iOS)
        .background(
            // Disable the system back-swipe while on a dive detail so our
            // swipe-right gesture can navigate to the previous dive.
            Group {
                if !isSlidePreview && !sortedDives.isEmpty {
                    DisableInteractivePop().frame(width: 0, height: 0)
                }
            }
        )
        #endif

        .toolbar {
            if !isSlidePreview {
                #if os(macOS)
                if !sortedDives.isEmpty {
                    ToolbarItem(placement: .principal) {
                        diveNavigationButtons
                    }
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
        .onChange(of: dive) { oldValue, newValue in
            guard oldValue != newValue else { return }
            refreshCaches(for: newValue)
            // Reset per-dive UI state when navigating to a different dive
            selectedTankIndex = 0
            showEditSheet = false
            showAddFish = false
            showAddGear = false
            selectedPhotos = []
            isEditingEquipment = false
            isEditingPhotos = false
            isEditingMarineLife = false
            // Also clear transient targets so they can't point to the previous dive's items.
            selectedPhotoForPreview = nil
            gearToDelete = nil
            photoIndexToDelete = nil
            fishToDelete = nil
            fishToEdit = nil
            showDeleteGearAlert = false
            showDeletePhotoAlert = false
            showDeleteFishAlert = false
            #if os(iOS)
            showFileExporter = false
            // Announce the newly-focused dive for VoiceOver users.
            let number = newValue.diveNumber ?? cachedDiveNumber
            let announcement = String(localized: "Dive \(number), \(newValue.siteName)")
            UIAccessibility.post(notification: .screenChanged, argument: announcement)
            #endif
        }
        .onChange(of: allDives.count) { _, _ in
            // Keep the cached dive number correct if dives are added/removed elsewhere.
            refreshCaches(for: dive)
        }
        .onDisappear {
            // Invalidate any pending async reset so it can't fire after the view leaves.
            unlockToken = UUID()
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
        pendingDive = targetDive
        // Visual direction: "forward" means the incoming dive comes from the trailing edge.
        let rtl = layoutDirection == .rightToLeft
        let visualForward = rtl ? !forward : forward
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

#if os(iOS)
// Disables the UINavigationController interactive pop gesture while this view is
// in the hierarchy. Needed so a right-swipe starting at the left screen edge
// navigates to the previous dive instead of popping back to the list.
private struct DisableInteractivePop: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { Controller() }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Controller: UIViewController {
        private weak var nav: UINavigationController?
        private var wasEnabled: Bool = true

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            DispatchQueue.main.async { [weak self] in self?.disable() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            nav?.interactivePopGestureRecognizer?.isEnabled = wasEnabled
        }

        private func disable() {
            guard let nav = navigationController ?? findNav() else { return }
            self.nav = nav
            if let gr = nav.interactivePopGestureRecognizer {
                wasEnabled = gr.isEnabled
                gr.isEnabled = false
            }
        }

        private func findNav() -> UINavigationController? {
            var current: UIViewController? = parent
            while let c = current {
                if let nav = c as? UINavigationController { return nav }
                if let nav = c.navigationController { return nav }
                current = c.parent
            }
            return nil
        }
    }
}
#endif

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
            #if os(iOS)
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
            #else
            content
                .navigationTitle(title)
            #endif
        }
    }
}
