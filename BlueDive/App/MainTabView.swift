import SwiftUI
import SwiftData
import UserNotifications
import CoreData
import Combine

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("notificationsEnabled") private var notificationsEnabled = UserPreferences.Defaults.notificationsEnabled
    @AppStorage("gearMaintenanceReminders") private var gearReminders = UserPreferences.Defaults.gearMaintenanceReminders
    @AppStorage("certificationReminders") private var certReminders = UserPreferences.Defaults.certificationReminders
    @AppStorage("insuranceReminders") private var insuranceReminders = UserPreferences.Defaults.insuranceReminders
    /// Written by `UserPreferences.languageMode`; observed to re-localize scheduled reminders.
    @AppStorage("languageMode") private var languageMode = UserPreferences.Defaults.languageMode.rawValue
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("lastAcceptedDisclaimerVersion") private var lastAcceptedDisclaimerVersion = ""
    /// Set once the one-time Online Services question has been answered (per device, like
    /// the setting it controls).
    @AppStorage("onlineServicesPromptShown") private var onlineServicesPromptShown = false
    @State private var showOnlineServicesPrompt = false
    /// Set once the one-time iNaturalist question has been answered (per device).
    @AppStorage("taxonomyPromptShown") private var taxonomyPromptShown = false
    @State private var showTaxonomyPrompt = false
    /// Getting Started, shown in this window: after "Set Up BlueDive" at the end of the Welcome
    /// Tour on first launch (in the same presentation), or from Settings → About. Scene storage,
    /// with its step, because a language change from or to System rebuilds the whole window
    /// (`LanguageOverrideModifier`): the guide then reopens on the same step instead of
    /// disappearing.
    @SceneStorage("showGettingStarted") private var showGettingStarted = false
    @SceneStorage("gettingStartedStep") private var gettingStartedStep = 0
    /// True from "Set Up BlueDive" until the guide closes. `guideBinding` reads it so the
    /// presentation stays up while the tour hands over to Getting Started: the @AppStorage and
    /// @SceneStorage writes of `setUpAfterWelcome` are not seen in the same update, and for that
    /// moment neither of them alone kept the cover shown (it closed and opened again).
    @State private var isSettingUpAfterWelcome = false
    /// Whether the presentation that is closing showed Getting Started: `guideBinding`'s setter
    /// clears the flags above as the close starts, and without this `guideContent` would show
    /// the Welcome Tour while the cover slides away. Cleared once it has closed.
    @State private var closingGuideShowedSetup = false
    /// Set by Settings → About → Getting Started, which closes Settings: the guide opens once
    /// the Settings sheet is gone (a presentation cannot start while another is closing).
    @State private var openGettingStartedAfterSettings = false
    @Environment(\.introVisible) private var introVisible
    /// The main window's scheme: the system's when the theme is System (`guideColorScheme`).
    @Environment(\.colorScheme) private var colorScheme
    @Environment(FileImportCoordinator.self) private var importCoordinator

    private var shouldShowDisclaimer: Bool {
        !introVisible && !isCurrentAppVersion(lastAcceptedDisclaimerVersion)
    }

    private var shouldShowWelcome: Bool {
        !introVisible && isCurrentAppVersion(lastAcceptedDisclaimerVersion) && !hasCompletedOnboarding
    }

    /// Asked once, after the intro, the disclaimer and the Welcome Wizard — so new users see it
    /// after the tour, and existing users on the first launch after updating. Never asked when
    /// the service is already on.
    private var shouldAskOnlineServices: Bool {
        // Answered first: once it is, nothing else is read, so MainTabView stops observing
        // the setting and the import coordinator for this.
        !onlineServicesPromptShown
            && !UserPreferences.shared.fetchWeatherOnline
            && canAskLaunchQuestion
    }

    /// The iNaturalist question, asked once under the same conditions, only after the weather
    /// question is answered (or the weather is already on) so the two never appear together:
    /// new users get it right after the weather question, existing users on the first launch
    /// after updating. Never asked when iNaturalist lookups are already on.
    private var shouldAskTaxonomy: Bool {
        !taxonomyPromptShown
            && !UserPreferences.shared.fetchTaxonomyOnline
            && (onlineServicesPromptShown || UserPreferences.shared.fetchWeatherOnline)
            && !showOnlineServicesPrompt
            && canAskLaunchQuestion
    }

    /// After the intro, the disclaimer and the Welcome Wizard, and not while a sheet is up or
    /// in a session opened with a file or a widget link.
    private var canAskLaunchQuestion: Bool {
        !introVisible && isCurrentAppVersion(lastAcceptedDisclaimerVersion)
            && hasCompletedOnboarding
            // An alert cannot appear over another sheet on iOS and would be lost: wait for a
            // reminder deep-link sheet to close, and skip a session opened with a file or a
            // widget link.
            && gearToOpen == nil && certToRenew == nil && insuranceToRenew == nil
            && !importCoordinator.receivedExternalOpen
            // Getting Started asks the same questions on its Online Services step.
            && !showGettingStarted
    }

    // MARK: - Launch Questions

    /// The one-time Online Services questions (Open-Meteo weather, then iNaturalist), in their
    /// own modifier so `body` stays small enough for the type checker.
    private var launchQuestions: LaunchQuestions {
        LaunchQuestions(
            askWeather: shouldAskOnlineServices,
            askTaxonomy: shouldAskTaxonomy,
            showWeather: $showOnlineServicesPrompt,
            showTaxonomy: $showTaxonomyPrompt,
            weatherAnswered: { onlineServicesPromptShown = true },
            taxonomyAnswered: { taxonomyPromptShown = true }
        )
    }


    private var disclaimerBinding: Binding<Bool> {
        Binding(
            get: { shouldShowDisclaimer },
            set: { if !$0 { lastAcceptedDisclaimerVersion = DiveIntroConfig.currentVersion } }
        )
    }

    /// The first-launch Welcome Tour and Getting Started share one presentation, so "Set Up
    /// BlueDive" continues in place instead of one cover closing and another opening.
    private var guideBinding: Binding<Bool> {
        Binding(
            // Never over the intro or before the disclaimer is accepted, as the tour: a guide
            // restored from scene storage at launch waits for both.
            get: {
                !introVisible && isCurrentAppVersion(lastAcceptedDisclaimerVersion)
                    && (shouldShowWelcome || showGettingStarted || isSettingUpAfterWelcome)
            },
            set: {
                if !$0 {
                    closingGuideShowedSetup = showGettingStarted || isSettingUpAfterWelcome
                    hasCompletedOnboarding = true
                    showGettingStarted = false
                    isSettingUpAfterWelcome = false
                }
            }
        )
    }

    /// The tour on first launch, then Getting Started once the user chose to set up BlueDive
    /// (or Getting Started alone, from Settings → About).
    @ViewBuilder
    private var guideContent: some View {
        if showGettingStarted || isSettingUpAfterWelcome || closingGuideShowedSetup {
            GettingStartedView(step: $gettingStartedStep)
        } else {
            WelcomeWizardView(onSetUp: setUpAfterWelcome)
        }
    }

    /// The guide's colour scheme: the chosen theme, or for System the main window's (which
    /// follows the system). Never nil: a presentation whose preferred scheme changes back to nil
    /// keeps the previous one, so a Dark → System change in the guide left it dark while the
    /// main window turned light.
    private var guideColorScheme: ColorScheme {
        UserPreferences.shared.appearanceMode.colorScheme ?? colorScheme
    }

    /// "Set Up BlueDive" on the tour's last page: the same presentation shows Getting Started.
    private func setUpAfterWelcome() {
        isSettingUpAfterWelcome = true
        gettingStartedStep = 0
        showGettingStarted = true
        hasCompletedOnboarding = true
    }

    /// Tracks the active tab so widget deep-links can switch to the Logbook
    /// (where `ContentView` presents the manual/Bluetooth sheets).
    @State private var selectedTab: MainTab = .dives
    /// The tabs this window shows, in order (Settings → Appearance & Language → Main Tabs). Read
    /// when the window is created and changed only when its own Settings closes
    /// (`applyMainTabLayout`), never by a deep link or another window.
    @State private var layout: [MainTab] = MainTab.savedLayoutUnobserved
    @State private var gearToOpen: Gear? = nil
    @State private var certToRenew: Certification? = nil
    @State private var insuranceToRenew: DivingInsurance? = nil
    /// App-wide sheets opened from every tab's toolbar (`MainWindowToolbar`).
    @State private var showSettings = false
    #if os(macOS)
    /// About BlueDive and Help → BlueDive Help (menu bar), for this window only.
    @State private var showAbout = false
    #endif
    @State private var showSyncStatus = false
    #if os(iOS)
    /// How many tabs, from the end, the iPad tab bar shows as pinned icons (`TabBarFit`).
    @State private var pinnedTabCount = 0
    #endif

    /// The placement of `tab`: pinned (an icon at the trailing end of the iPad tab bar) while
    /// `pinnedTabCount` reaches its position from the end of the shown tabs (the last one 1).
    /// The first tab (Dives) always keeps its name.
    private func placement(of tab: MainTab) -> TabPlacement {
        #if os(iOS)
        guard let index = layout.firstIndex(of: tab), index > 0 else { return .automatic }
        return pinnedTabCount >= layout.count - index ? .pinned : .automatic
        #else
        .automatic
        #endif
    }

    /// The tabs, in this window's layout. Hidden tabs are left out (macOS ignores
    /// `.hidden(_:)`). Rebuilt (`.id`) when the layout changes: a tab bar whose tabs are moved or
    /// hidden in place draws them wrongly (observed: iOS 27 can keep another tab's icon until
    /// the next launch; the macOS toolbar sizes the tabs to their titles until another tab is
    /// selected). The feeders are attached outside it, in `body`, so they keep running.
    private var tabView: some View {
        TabView(selection: $selectedTab) {
            ForEach(layout) { tab in
                Tab(value: tab) {
                    tabContent(tab)
                } label: {
                    Label { Text(verbatim: tab.title) } icon: { Image(systemName: tab.icon) }
                }
                .tabPlacement(placement(of: tab))
            }
        }
        .id(layout)
        // The rebuilt tab bar fades in over the old one (`applyMainTabLayout`) instead of the
        // window showing only its background for a frame.
        .transition(.opacity)
        .environment(\.shownMainTabs, layout)
        // A file opened while the app runs (Files, AirDrop, Mail) is handled by ContentView,
        // which presents its import sheet or error alert: show Dives so they are seen. An XML
        // file for another shown tab then moves on to that tab (the `.importGearXML`… receivers
        // in `body`). Also required by the Main Tabs rebuild (`.id`): after a rebuild started on
        // another tab, ContentView is not mounted, so nothing else would handle the file.
        .onChange(of: importCoordinator.pendingURL) { _, url in
            if url != nil { selectedTab = .dives }
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: MainTab) -> some View {
        switch tab {
        case .dives:
            ContentView()
        case .map:
            DiveMapView()
        case .equipment:
            NavigationStack {
                GearListView()
            }
        case .marineLife:
            MarineLifeView()
                // "View dives" there (and on its species pages) shows the Dives tab.
                .environment(\.showDiveList, ShowDiveListAction { selectedTab = .dives })
        case .documents:
            DocumentsView()
        }
    }

    /// Applies the layout saved in Settings → Main Tabs to this window, when its Settings sheet
    /// closes and only if it changed: the TabView is then rebuilt once. The selection leaves a
    /// tab the layout hides before the rebuild.
    private func applyMainTabLayout() {
        let shown = MainTab.savedLayoutUnobserved
        guard shown != layout else { return }
        if !shown.contains(selectedTab) { selectedTab = .dives }
        withAnimation(.easeInOut(duration: 0.5)) {
            layout = shown
        }
    }

    /// After the Settings sheet closes: applies a new tab layout, and opens Getting Started when
    /// it was asked for from Settings → About.
    private func settingsDismissed() {
        applyMainTabLayout()
        if openGettingStartedAfterSettings {
            openGettingStartedAfterSettings = false
            gettingStartedStep = 0
            showGettingStarted = true
        }
    }

    /// Selects `tab` for a reminder or an XML import, unless this window hides it: a reminder's
    /// sheet is presented here, over whatever tab is shown, and an XML file meant for a hidden
    /// tab is refused before it is routed (`ContentView.handleExternalFileURL`).
    private func select(_ tab: MainTab) {
        if layout.contains(tab) { selectedTab = tab }
    }

    var body: some View {
        ZStack {
            Color.platformBackground.ignoresSafeArea()
            
            tabView
            .accentColor(.cyan)
            // Every tab's Settings and iCloud toolbar buttons open the sheets presented here.
            .environment(\.showSettingsSheet, ShowSheetAction { showSettings = true })
            .environment(\.showSyncStatusSheet, ShowSheetAction { showSyncStatus = true })
        }
        // The feeders and the sweep are attached here, beside the TabView rather than on it: a
        // Main Tabs change rebuilds the TabView (`.id` in `tabView`), which must not restart them.
        // The only @Query Dive owner: keeps DiveStore's caches current whatever tab is
        // shown (see DiveDataFeeder).
        .background(DiveDataFeeder())
        // Keeps store.cachedUniqueDivers fed from gear/certifications/insurance whatever
        // tab is selected. A background view (not @Query on MainTabView itself) so a gear
        // or document change doesn't re-evaluate MainTabView's body and all the tabs.
        .background(DiverSourcesFeeder())
        // Applies other devices' edits to existing dives (iCloud) to DiveStore's caches,
        // whatever tab is selected. See RemoteChangeFeeder.
        .background(RemoteChangeFeeder())
        // Image records that lost an iCloud conflict (DivePhotoBlobs.swift), a minute after the
        // window opens (a second window sweeps again and finds nothing).
        .task { await PhotoBlobSweeper.sweepLater(container: modelContext.container) }
        // Tells the tab roots when iOS draws their toolbar in a side strip (iPhone Duo).
        .detectsToolbarSideStrip()
        #if os(iOS)
        .modifier(TabBarFitTracker(pinnedTabCount: $pinnedTabCount, languageMode: languageMode,
                                   tabs: layout))
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .addDiveManual)) { _ in
            selectedTab = .dives
        }
        .onReceive(NotificationCenter.default.publisher(for: .addDiveBluetooth)) { _ in
            selectedTab = .dives
        }
        #if os(macOS)
        .modifier(MainWindowMenuSheets(showAbout: $showAbout, showSettings: $showSettings))
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .openEquipmentForService)) { note in
            let gearId = note.object as? String
            Task { @MainActor in
                UserDefaults.standard.removeObject(forKey: "pendingGearDeepLink")
                UserDefaults.standard.removeObject(forKey: "pendingGearDeepLinkTime")
                select(.equipment)
                if let gearId {
                    gearToOpen = fetchGear(id: gearId)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCertificationsForRenewal)) { note in
            let certId = note.object as? String
            Task { @MainActor in
                UserDefaults.standard.removeObject(forKey: "pendingCertDeepLink")
                UserDefaults.standard.removeObject(forKey: "pendingCertDeepLinkTime")
                select(.documents)
                if let certId {
                    certToRenew = fetchCertification(id: certId)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openInsuranceForRenewal)) { note in
            let insuranceId = note.object as? String
            Task { @MainActor in
                UserDefaults.standard.removeObject(forKey: "pendingInsuranceDeepLink")
                UserDefaults.standard.removeObject(forKey: "pendingInsuranceDeepLinkTime")
                select(.documents)
                if let insuranceId {
                    insuranceToRenew = fetchInsurance(id: insuranceId)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .importGearXML)) { _ in
            select(.equipment)
        }
        .onReceive(NotificationCenter.default.publisher(for: .importCertificationXML)) { _ in
            select(.documents)
        }
        .onReceive(NotificationCenter.default.publisher(for: .importInsuranceXML)) { _ in
            select(.documents)
        }
        .onReceive(NotificationCenter.default.publisher(for: .importSpeciesXML)) { _ in
            select(.marineLife)
        }
        .task {
            // If the app launched via a file open (Files, AirDrop, Mail) and restored to
            // a non-zero tab, ContentView (tab 0) won't mount and its onAppear won't fire.
            // Switch to tab 0 so ContentView appears and picks up the pending URL.
            // Note: pendingURL must still be set here (not yet consumed by ContentView.onAppear)
            // because ContentView hasn't mounted yet — that's exactly the scenario this fixes.
            if importCoordinator.pendingURL != nil {
                selectedTab = .dives
            }

            // Cold-launch fallback: NotificationCenter posts are dropped before onReceive
            // attaches. didReceive writes the UUID + a timestamp to UserDefaults so .task
            // can recover it. The 5-minute window prevents a stale key (written during an
            // aborted launch) from spuriously opening a sheet on a later normal launch.
            let now = Date().timeIntervalSince1970
            if let gearId = UserDefaults.standard.string(forKey: "pendingGearDeepLink") {
                let written = UserDefaults.standard.double(forKey: "pendingGearDeepLinkTime")
                UserDefaults.standard.removeObject(forKey: "pendingGearDeepLink")
                UserDefaults.standard.removeObject(forKey: "pendingGearDeepLinkTime")
                if now - written < 300 {
                    select(.equipment)
                    gearToOpen = fetchGear(id: gearId)
                }
            }
            if let certId = UserDefaults.standard.string(forKey: "pendingCertDeepLink") {
                let written = UserDefaults.standard.double(forKey: "pendingCertDeepLinkTime")
                UserDefaults.standard.removeObject(forKey: "pendingCertDeepLink")
                UserDefaults.standard.removeObject(forKey: "pendingCertDeepLinkTime")
                if now - written < 300 {
                    select(.documents)
                    certToRenew = fetchCertification(id: certId)
                }
            }
            if let insuranceId = UserDefaults.standard.string(forKey: "pendingInsuranceDeepLink") {
                let written = UserDefaults.standard.double(forKey: "pendingInsuranceDeepLinkTime")
                UserDefaults.standard.removeObject(forKey: "pendingInsuranceDeepLink")
                UserDefaults.standard.removeObject(forKey: "pendingInsuranceDeepLinkTime")
                if now - written < 300 {
                    select(.documents)
                    insuranceToRenew = fetchInsurance(id: insuranceId)
                }
            }
            await scheduleNotificationsAtLaunch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)) { _ in
                // Reschedule notifications when iCloud sync delivers changes from another device.
                // All reminders now use calendar triggers, so re-scheduling is safe.
                Task { await scheduleNotificationsAtLaunch() }
        }
        .onChange(of: languageMode) {
            // Reminder text and action buttons are localized when scheduled/registered, so
            // re-register and reschedule them in the new in-app language.
            Task { await scheduleNotificationsAtLaunch() }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: disclaimerBinding) {
            DisclaimerView()
        }
        .fullScreenCover(isPresented: guideBinding, onDismiss: { closingGuideShowedSetup = false }) {
            guideContent
                .preferredColorScheme(guideColorScheme)
        }
        #else
        // fullScreenCover is unavailable on macOS; present as sheets instead.
        .sheet(isPresented: disclaimerBinding) {
            DisclaimerView()
                .standardSheetPresentation()
        }
        .sheet(isPresented: guideBinding, onDismiss: { closingGuideShowedSetup = false }) {
            guideContent
                .preferredColorScheme(guideColorScheme)
                .standardSheetPresentation()
        }
        #endif
        .modifier(launchQuestions)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Clear badge and delivered notifications when the user opens the app
                Task { await NotificationManager.shared.clearBadge() }
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            }
        }
        .sheet(item: $gearToOpen) { gear in
            GearServiceView(gear: gear)
                .standardSheetPresentation()
        }
        .sheet(item: $certToRenew) { cert in
            AddCertificationView(certificationToEdit: cert)
                .standardSheetPresentation()
        }
        .sheet(item: $insuranceToRenew) { insurance in
            AddInsuranceView(insuranceToEdit: insurance)
                .standardSheetPresentation()
        }
        // Any dismissal (Close, swipe, Escape, the language page's own dismiss) applies a new
        // tab layout to this window.
        .sheet(isPresented: $showSettings, onDismiss: settingsDismissed) {
            SettingsView()
                .environment(\.showGettingStarted, ShowSheetAction { openGettingStartedAfterSettings = true })
                .standardSheetPresentation()
        }
        .sheet(isPresented: $showSyncStatus) {
            CloudKitSyncStatusView()
                .standardSheetPresentation()
        }
    }

    // MARK: - Notification Action Handlers

    @MainActor
    private func fetchGear(id: String) -> Gear? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return try? modelContext.fetch(
            FetchDescriptor<Gear>(predicate: #Predicate { $0.id == uuid })
        ).first
    }

    @MainActor
    private func fetchCertification(id: String) -> Certification? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return try? modelContext.fetch(
            FetchDescriptor<Certification>(predicate: #Predicate { $0.id == uuid })
        ).first
    }

    @MainActor
    private func fetchInsurance(id: String) -> DivingInsurance? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return try? modelContext.fetch(
            FetchDescriptor<DivingInsurance>(predicate: #Predicate { $0.id == uuid })
        ).first
    }

    // MARK: - Notification Scheduling at Launch
    
    private func scheduleNotificationsAtLaunch() async {
        guard notificationsEnabled else {
            // Cancel any pending notifications left over if the flag was turned off
            // while the app was backgrounded (onChange wouldn't have fired in that case).
            NotificationManager.shared.cancelAllNotifications()
            return
        }
        
        let status = await NotificationManager.shared.checkAuthorizationStatus()
        guard status == .authorized || status == .provisional else { return }
        
        NotificationManager.shared.setupNotificationCategories()

        // Fetch each record set once — reused for scheduling and for the orphan reconcile below.
        let allGear = (try? modelContext.fetch(FetchDescriptor<Gear>())) ?? []
        let allCerts = (try? modelContext.fetch(FetchDescriptor<Certification>())) ?? []
        let allInsurances = (try? modelContext.fetch(FetchDescriptor<DivingInsurance>())) ?? []

        if gearReminders {
            NotificationManager.shared.scheduleGearMaintenanceReminders(for: allGear)
        } else {
            await NotificationManager.shared.cancelNotifications(withPrefix: "gear-")
        }

        if certReminders {
            NotificationManager.shared.scheduleCertificationReminders(for: allCerts)
        } else {
            await NotificationManager.shared.cancelNotifications(withPrefix: "cert-")
        }

        if insuranceReminders {
            NotificationManager.shared.scheduleInsuranceReminders(for: allInsurances)
        } else {
            await NotificationManager.shared.cancelNotifications(withPrefix: "insurance-")
        }

        // Reconcile: drop any pending reminder whose record no longer exists (e.g. deleted
        // on another device and removed locally via CloudKit sync, where no in-app delete
        // handler ran). Also clears that record's stale catch-up marker.
        await NotificationManager.shared.reconcilePendingReminders(
            gearIDs: Set(allGear.map(\.id)),
            certIDs: Set(allCerts.map(\.id)),
            insuranceIDs: Set(allInsurances.map(\.id))
        )
    }
    
}

// MARK: - Launch Questions

/// The one-time Online Services questions asked at launch: the Open-Meteo weather, then
/// iNaturalist (see `MainTabView.shouldAskOnlineServices` / `shouldAskTaxonomy`).
private struct LaunchQuestions: ViewModifier {
    let askWeather: Bool
    let askTaxonomy: Bool
    @Binding var showWeather: Bool
    @Binding var showTaxonomy: Bool
    let weatherAnswered: () -> Void
    let taxonomyAnswered: () -> Void

    func body(content: Content) -> some View {
        content
            .task(id: askWeather) {
                guard askWeather else { return }
                // Let the wizard's cover or sheet finish closing; an alert presented during that
                // transition can be dropped.
                // A change of the conditions cancels this task, and a cancelled sleep throws.
                guard (try? await Task.sleep(for: .milliseconds(600))) != nil else { return }
                showWeather = true
            }
            // Close the alert when asking is no longer right: answered in another window (iPad
            // scenes, Mac windows), or a file, widget link or reminder arrived while it is up —
            // left unanswered then, so it is asked again later — so their sheets can appear.
            .onChange(of: askWeather) { _, canAsk in
                if !canAsk { showWeather = false }
            }
            .alert("Fetch the weather online for your dives?", isPresented: $showWeather) {
                Button("Turn On") {
                    // Also records the answer (UserPreferences.fetchWeatherOnline's didSet).
                    UserPreferences.shared.fetchWeatherOnline = true
                }
                Button("Not Now", role: .cancel) {
                    weatherAnswered()
                }
            } message: {
                // Built from sentences shared with Online Services and the Welcome Tour, so each is
                // translated once.
                Text("BlueDive can fill in the weather, air temperature and wind for a dive from its GPS coordinates, using Open-Meteo.") + Text(verbatim: " ") + Text("The coordinates and date are sent only when you fetch the weather online.") + Text(verbatim: " ") + Text("You can change this anytime in Settings → Online Services.")
            }
            .task(id: askTaxonomy) {
                guard askTaxonomy else { return }
                // Let the weather alert (or the wizard) finish closing first.
                guard (try? await Task.sleep(for: .milliseconds(600))) != nil else { return }
                showTaxonomy = true
            }
            .onChange(of: askTaxonomy) { _, canAsk in
                if !canAsk { showTaxonomy = false }
            }
            .alert("Look up species on iNaturalist?", isPresented: $showTaxonomy) {
                Button("Turn On") {
                    // Also records the answer (UserPreferences.fetchTaxonomyOnline's didSet).
                    UserPreferences.shared.fetchTaxonomyOnline = true
                }
                Button("Not Now", role: .cancel) {
                    taxonomyAnswered()
                }
            } message: {
                // Sentences shared with Online Services and the Welcome Tour, translated once.
                Text("BlueDive can fill in a species' classification (kingdom to species), common names, Wikipedia summary and a Creative Commons photo from iNaturalist. Only the species name is sent, when a species is created, edited or looked up.") + Text(verbatim: " ") + Text("You can change this anytime in Settings → Online Services.")
            }
    }
}

#if os(iOS)
/// How many tabs the iPad tab bar must pin so that it fits between the main-window toolbar's
/// leading and trailing buttons.
///
/// On an iPad the tab bar sits in the navigation bar, centred in the window. Five named tabs can
/// be too wide for the space between the diver filter / Settings / iCloud buttons and the + /
/// Filter / "…" buttons; iOS then drops the leading buttons altogether. A pinned tab
/// (`.tabPlacement(.pinned)`) shows only its icon, at the trailing end of the tab bar. iPadOS
/// reports none of these widths, so they are calibrated (11-inch iPad, iPadOS 27): a named tab
/// is its title in SF 17 pt medium plus 32.4 pt, a pinned tab about 54 pt; the leading buttons
/// end 183.5 pt (243 with the calculators menu) from the window's edge and the trailing ones
/// begin 162 pt from the other, and iOS needs about 21 pt between the tab bar and the buttons.
/// Tabs are pinned from the end of the shown tabs (Settings → Main Tabs); the first (Dives) always
/// keeps its name. Only for a top tab bar: regular width and height, at least 700 pt, no side
/// strip (iPhone Duo). `showsCalculatorsMenu` counts the Dives tab's extra leading button on
/// every tab: the tab bar is shared, so its pinning does not change from tab to tab.
enum TabBarFit {
    nonisolated struct Geometry: Equatable, Sendable {
        var width: CGFloat = 0
        var isSideStrip = false
    }

    /// `hasTopTabBar`: regular width and height, as on an iPad; an iPhone in landscape is regular
    /// width but compact height, with its tab bar at the bottom.
    /// `titleWidths`: `namedTabWidths(_:isBoldText:)`, which depends only on the shown tabs, the
    /// language and Bold Text, so a live resize does not measure the titles again.
    static func pinnedTabCount(geometry: Geometry, hasTopTabBar: Bool, titleWidths: [CGFloat],
                               showsCalculatorsMenu: Bool) -> Int {
        guard hasTopTabBar, geometry.width >= 700, !geometry.isSideStrip, !titleWidths.isEmpty else { return 0 }

        let leadingEnd: CGFloat = showsCalculatorsMenu ? 243 : 183.5
        // Measured: iOS keeps the leading buttons with a 22.3 pt gap, drops them at 19.7 pt.
        let gap: CGFloat = 21
        // Centred tab bar: it may span twice its distance to the nearer side's buttons.
        let halfWidth = min(geometry.width / 2 - leadingEnd, geometry.width / 2 - 162) - gap
        let available = 2 * halfWidth

        let pinnedWidth: CGFloat = 54  // measured 52 to 56
        for pinned in 0...(titleWidths.count - 1) {
            let named = titleWidths.dropLast(pinned).reduce(0, +)
            if named + CGFloat(pinned) * pinnedWidth <= available { return pinned }
        }
        return titleWidths.count - 1
    }

    /// The width of each of `tabs` with its title, in tab bar order (pinned from the end), in the
    /// app's language. `isBoldText`: the Bold Text setting, which draws the titles heavier.
    static func namedTabWidths(_ tabs: [MainTab], isBoldText: Bool) -> [CGFloat] {
        let font = UIFont.systemFont(ofSize: 17, weight: isBoldText ? .bold : .medium)
        return tabs.map { ($0.title as NSString).size(withAttributes: [.font: font]).width + 32.4 }
    }
}

/// Keeps `pinnedTabCount` current: on a change of the window's width or side insets (the keyboard
/// changes neither, so typing never re-pins), of the size class, of the calculators menu and of
/// the language (the tab names' widths). Writes the count only when it changes, so a resize
/// redraws `MainTabView` only then. Also on a change of Bold Text and of the vertical size class.
private struct TabBarFitTracker: ViewModifier {
    @Binding var pinnedTabCount: Int
    /// `MainTabView`'s language setting: the tab titles' widths change with it.
    let languageMode: String
    /// The tabs the window shows, in order (Settings → Main Tabs).
    let tabs: [MainTab]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.legibilityWeight) private var legibilityWeight
    @AppStorage("showCalculatorsMenu") private var showCalculatorsMenu = false
    @State private var geometry = TabBarFit.Geometry()
    /// `TabBarFit.namedTabWidths`, measured again only on a change of the tabs, the language or
    /// Bold Text.
    @State private var titleWidths: [CGFloat] = []

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: TabBarFit.Geometry.self) { proxy in
                TabBarFit.Geometry(
                    width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                    isSideStrip: proxy.safeAreaInsets.isToolbarSideStrip)
            } action: { newGeometry in
                geometry = newGeometry
                update()
            }
            .onChange(of: horizontalSizeClass) { update() }
            .onChange(of: verticalSizeClass) { update() }
            .onChange(of: legibilityWeight) { measureTitles() }
            .onChange(of: showCalculatorsMenu) { update() }
            .onChange(of: languageMode) { measureTitles() }
            .onChange(of: tabs) { measureTitles() }
    }

    private func measureTitles() {
        titleWidths = TabBarFit.namedTabWidths(tabs, isBoldText: legibilityWeight == .bold)
        update()
    }

    private func update() {
        if titleWidths.isEmpty {
            titleWidths = TabBarFit.namedTabWidths(tabs, isBoldText: legibilityWeight == .bold)
        }
        let count = TabBarFit.pinnedTabCount(
            geometry: geometry,
            hasTopTabBar: horizontalSizeClass == .regular && verticalSizeClass == .regular,
            titleWidths: titleWidths,
            showsCalculatorsMenu: showCalculatorsMenu)
        if count != pinnedTabCount { pinnedTabCount = count }
    }
}
#endif

#if os(macOS)
/// The sheets a main window presents from the menu bar (About BlueDive, Help → BlueDive Help,
/// Settings…). Each window publishes its own with `focusedSceneValue`, so a command opens the
/// sheet in the window in front only, not in every open window.
///
/// Equal only for the same window (`windowID`): SwiftUI compares the published value to decide
/// whether the menu commands must update, so two windows' actions must never compare equal.
/// `ShowSheetAction` is not used here for that reason: its `==` is always true (it keeps
/// environment readers from redrawing), which left the commands calling the first window's
/// actions after another window came to the front.
struct MainWindowActions: Equatable {
    let windowID: UUID
    let showAbout: () -> Void
    let showSettings: () -> Void

    static func == (lhs: MainWindowActions, rhs: MainWindowActions) -> Bool {
        lhs.windowID == rhs.windowID
    }
}

extension FocusedValues {
    @Entry var mainWindowActions: MainWindowActions?
}

/// Publishes this window's `MainWindowActions` for the menu bar's About, Help and Settings
/// commands, which act on the window in front only (`MainWindowCommand` in `BlueDiveApp`
/// reads them through `@FocusedValue`), and presents this window's About sheet. Settings is
/// presented by `MainTabView` itself, like its toolbar button. A modifier keeps
/// `MainTabView.body` small enough to type-check.
private struct MainWindowMenuSheets: ViewModifier {
    @Binding var showAbout: Bool
    @Binding var showSettings: Bool
    /// Identifies this window's actions (see `MainWindowActions`).
    @State private var windowID = UUID()

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.mainWindowActions, MainWindowActions(
                windowID: windowID,
                showAbout: { showAbout = true },
                showSettings: { showSettings = true }
            ))
            .sheet(isPresented: $showAbout) {
                AboutView()
                    .standardSheetPresentation()
            }
    }
}
#endif
