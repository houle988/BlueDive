import SwiftUI
import SwiftData
import UserNotifications
import CoreData
import Combine

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("gearReminders") private var gearReminders = true
    @AppStorage("certReminders") private var certReminders = true
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("lastAcceptedDisclaimerVersion") private var lastAcceptedDisclaimerVersion = ""

    private let currentVersion = appVersionBuild()

    /// Tracks the active tab so widget deep-links can switch to the Logbook
    /// (where `ContentView` presents the manual/Bluetooth sheets).
    @State private var selectedTab: Int = 0

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

                // --- TAB 4 : CERTIFICATIONS ---
                CertificationsView()
                    .tabItem {
                        Label("Certifications", systemImage: "graduationcap.fill")
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
        .task {
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
                .fullScreenCover(isPresented: Binding(
                    get: { lastAcceptedDisclaimerVersion != currentVersion },
                    set: { if !$0 { lastAcceptedDisclaimerVersion = currentVersion } }
                )) {
                    DisclaimerView()
                }
                .fullScreenCover(isPresented: Binding(
                    get: { lastAcceptedDisclaimerVersion == currentVersion && !hasCompletedOnboarding },
                    set: { if !$0 { hasCompletedOnboarding = true } }
                )) {
                    WelcomeWizardView()
                }
        }
        .applyIf(ProcessInfo.processInfo.isiOSAppOnMac) { view in
            view
                .sheet(isPresented: Binding(
                    get: { lastAcceptedDisclaimerVersion != currentVersion },
                    set: { if !$0 { lastAcceptedDisclaimerVersion = currentVersion } }
                )) {
                    DisclaimerView()
                        .presentationSizing(.page)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
                .sheet(isPresented: Binding(
                    get: { lastAcceptedDisclaimerVersion == currentVersion && !hasCompletedOnboarding },
                    set: { if !$0 { hasCompletedOnboarding = true } }
                )) {
                    WelcomeWizardView()
                        .presentationSizing(.page)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
        }
        #else
        .sheet(isPresented: Binding(
            get: { lastAcceptedDisclaimerVersion != currentVersion },
            set: { if !$0 { lastAcceptedDisclaimerVersion = currentVersion } }
        )) {
            DisclaimerView()
        }
        .sheet(isPresented: Binding(
            get: { lastAcceptedDisclaimerVersion == currentVersion && !hasCompletedOnboarding },
            set: { if !$0 { hasCompletedOnboarding = true } }
        )) {
            WelcomeWizardView()
        }
        #endif
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Clear badge and delivered notifications when the user opens the app
                NotificationManager.shared.clearBadge()
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            }
        }
    }
    
    // MARK: - Notification Scheduling at Launch
    
    private func scheduleNotificationsAtLaunch() async {
        guard notificationsEnabled else { return }
        
        let status = await NotificationManager.shared.checkAuthorizationStatus()
        guard status == .authorized || status == .provisional else { return }
        
        NotificationManager.shared.setupNotificationCategories()
        
        if gearReminders {
            let allGear = (try? modelContext.fetch(FetchDescriptor<Gear>())) ?? []
            NotificationManager.shared.scheduleGearMaintenanceReminders(for: allGear)
        }
        
        if certReminders {
            let allCerts = (try? modelContext.fetch(FetchDescriptor<Certification>())) ?? []
            NotificationManager.shared.scheduleCertificationReminders(for: allCerts)
        }
    }
    
}
