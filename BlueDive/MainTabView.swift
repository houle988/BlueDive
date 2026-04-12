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
    
    init() {
        // Force black background for all tabs on macOS
        #if os(macOS)
        // This ensures the TabView background is black
        #endif
    }
    
    var body: some View {
        ZStack {
            Color.platformBackground.ignoresSafeArea()
            
            TabView {
                // --- TAB 1 : LOGBOOK ---
                ContentView()
                .tabItem {
                    Label("Dives", systemImage: "water.waves")
                }
                
                // --- TAB 2 : MAP ---
                DiveMapView()
                    .tabItem {
                        Label("Map", systemImage: "map.fill")
                    }
                
                // --- TAB 3 : EQUIPMENT ---
                NavigationStack {
                    GearListView()
                }
                .tabItem {
                    Label("Equipment", systemImage: "wrench.and.screwdriver.fill")
                }
                
                // --- TAB 4 : CERTIFICATIONS ---
                CertificationsView()
                    .tabItem {
                        Label("Certifications", systemImage: "graduationcap.fill")
                    }
            }
            .accentColor(.cyan)
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
        .fullScreenCover(isPresented: Binding(
            get: { !hasCompletedOnboarding },
            set: { if !$0 { hasCompletedOnboarding = true } }
        )) {
            WelcomeWizardView()
        }
        #else
        .sheet(isPresented: Binding(
            get: { !hasCompletedOnboarding },
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
