import SwiftUI
import SwiftData
import UserNotifications
import CoreData
import Combine

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("gearMaintenanceReminders") private var gearReminders = true
    @AppStorage("certificationReminders") private var certReminders = true
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("lastAcceptedDisclaimerVersion") private var lastAcceptedDisclaimerVersion = ""
    @Environment(\.introVisible) private var introVisible
    @Environment(FileImportCoordinator.self) private var importCoordinator

    private var shouldShowDisclaimer: Bool {
        !introVisible && lastAcceptedDisclaimerVersion != DiveIntroConfig.currentVersion
    }

    private var shouldShowWelcome: Bool {
        !introVisible && lastAcceptedDisclaimerVersion == DiveIntroConfig.currentVersion && !hasCompletedOnboarding
    }

    private var disclaimerBinding: Binding<Bool> {
        Binding(
            get: { shouldShowDisclaimer },
            set: { if !$0 { lastAcceptedDisclaimerVersion = DiveIntroConfig.currentVersion } }
        )
    }

    private var welcomeBinding: Binding<Bool> {
        Binding(
            get: { shouldShowWelcome },
            set: { if !$0 { hasCompletedOnboarding = true } }
        )
    }

    /// Tracks the active tab so widget deep-links can switch to the Logbook
    /// (where `ContentView` presents the manual/Bluetooth sheets).
    @State private var selectedTab: Int = 0
    @State private var gearToOpen: Gear? = nil
    @State private var certToRenew: Certification? = nil

    init() {
        // Force black background for all tabs on macOS
        #if os(macOS)
        // This ensures the TabView background is black
        #endif
    }
    
    var body: some View {
        ZStack {
            Color.platformBackground.ignoresSafeArea()
            
            TabView(selection: $selectedTab) {
                // --- TAB 1 : LOGBOOK ---
                ContentView()
                .tabItem {
                    Label("Dives", systemImage: "water.waves")
                }
                .tag(0)

                // --- TAB 2 : MAP ---
                DiveMapView()
                    .tabItem {
                        Label("Map", systemImage: "map.fill")
                    }
                    .tag(1)

                // --- TAB 3 : EQUIPMENT ---
                NavigationStack {
                    GearListView()
                }
                .tabItem {
                    Label("Equipment", systemImage: "wrench.and.screwdriver.fill")
                }
                .tag(2)

                // --- TAB 4 : DOCUMENTS ---
                DocumentsView()
                    .tabItem {
                        Label("Documents", systemImage: "person.text.rectangle.fill")
                    }
                    .tag(3)
            }
            .accentColor(.cyan)
        }
        .onReceive(NotificationCenter.default.publisher(for: .addDiveManual)) { _ in
            selectedTab = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .addDiveBluetooth)) { _ in
            selectedTab = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .openEquipmentForService)) { note in
            let gearId = note.object as? String
            Task { @MainActor in
                UserDefaults.standard.removeObject(forKey: "pendingGearDeepLink")
                UserDefaults.standard.removeObject(forKey: "pendingGearDeepLinkTime")
                selectedTab = 2
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
                selectedTab = 3
                if let certId {
                    certToRenew = fetchCertification(id: certId)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .importGearXML)) { _ in
            selectedTab = 2
        }
        .onReceive(NotificationCenter.default.publisher(for: .importCertificationXML)) { _ in
            selectedTab = 3
        }
        .onReceive(NotificationCenter.default.publisher(for: .importInsuranceXML)) { _ in
            selectedTab = 3
        }
        .task {
            // If the app launched via a file open (Files, AirDrop, Mail) and restored to
            // a non-zero tab, ContentView (tab 0) won't mount and its onAppear won't fire.
            // Switch to tab 0 so ContentView appears and picks up the pending URL.
            // Note: pendingURL must still be set here (not yet consumed by ContentView.onAppear)
            // because ContentView hasn't mounted yet — that's exactly the scenario this fixes.
            if importCoordinator.pendingURL != nil {
                selectedTab = 0
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
                    selectedTab = 2
                    gearToOpen = fetchGear(id: gearId)
                }
            }
            if let certId = UserDefaults.standard.string(forKey: "pendingCertDeepLink") {
                let written = UserDefaults.standard.double(forKey: "pendingCertDeepLinkTime")
                UserDefaults.standard.removeObject(forKey: "pendingCertDeepLink")
                UserDefaults.standard.removeObject(forKey: "pendingCertDeepLinkTime")
                if now - written < 300 {
                    selectedTab = 3
                    certToRenew = fetchCertification(id: certId)
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
        #if os(iOS)
        .applyIf(!ProcessInfo.processInfo.isiOSAppOnMac) { view in
            view
                .fullScreenCover(isPresented: disclaimerBinding) {
                    DisclaimerView()
                }
                .fullScreenCover(isPresented: welcomeBinding) {
                    WelcomeWizardView()
                }
        }
        .applyIf(ProcessInfo.processInfo.isiOSAppOnMac) { view in
            view
                .sheet(isPresented: disclaimerBinding) {
                    DisclaimerView()
                        .presentationSizing(.page)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
                .sheet(isPresented: welcomeBinding) {
                    WelcomeWizardView()
                        .presentationSizing(.page)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
        }
        #else
        .sheet(isPresented: disclaimerBinding) {
            DisclaimerView()
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: welcomeBinding) {
            WelcomeWizardView()
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        #endif
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Clear badge and delivered notifications when the user opens the app
                Task { await NotificationManager.shared.clearBadge() }
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            }
        }
        .sheet(item: $gearToOpen) { gear in
            GearServiceView(gear: gear)
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $certToRenew) { cert in
            AddCertificationView(certificationToEdit: cert)
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
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
        
        if gearReminders {
            let allGear = (try? modelContext.fetch(FetchDescriptor<Gear>())) ?? []
            NotificationManager.shared.scheduleGearMaintenanceReminders(for: allGear)
        } else {
            await NotificationManager.shared.cancelNotifications(withPrefix: "gear-")
        }

        if certReminders {
            let allCerts = (try? modelContext.fetch(FetchDescriptor<Certification>())) ?? []
            NotificationManager.shared.scheduleCertificationReminders(for: allCerts)
        } else {
            await NotificationManager.shared.cancelNotifications(withPrefix: "cert-")
        }
    }
    
}
