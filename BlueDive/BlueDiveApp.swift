import SwiftUI
import SwiftData
import UserNotifications
import os.log
import LibDCSwift
import BackgroundTasks
#if canImport(UIKit)
import UIKit
#endif

// MARK: - App Language Bundle Lookup

extension Bundle {
    /// Returns the localization bundle matching the in-app language override,
    /// falling back to the main bundle when set to "System".
    /// Use this for `String` lookups outside SwiftUI views (e.g. enum properties
    /// interpolated into `%@` patterns) where `@Environment(\.locale)` is unavailable.
    static func forAppLanguage() -> Bundle {
        guard let locale = UserPreferences.shared.languageMode.locale else {
            return .main
        }
        let identifier = locale.identifier
        if let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        if let langCode = locale.language.languageCode?.identifier,
           let path = Bundle.main.path(forResource: langCode, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return .main
    }
}

// MARK: - Language Override Modifier

/// Applies a locale override when the user has selected a specific language,
/// or does nothing when set to "OS Language" (system default).
struct LanguageOverrideModifier: ViewModifier {
    let locale: Locale?

    func body(content: Content) -> some View {
        if let locale {
            content.environment(\.locale, locale)
        } else {
            content
        }
    }
}

#if os(macOS)
/// App delegate that ensures the app terminates when the last window is closed.
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable macOS window tabbing so "View > Show Tab Bar" doesn't
        // offer to open multiple window-tabs alongside the app's own TabView.
        NSWindow.allowsAutomaticWindowTabbing = true
    }
}
#endif

@main
struct BlueDiveApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    // Logger for debugging
    static let logger = Logger(subsystem: "com.bluedive.app", category: "SwiftData")

    // ✅ `nonisolated(unsafe)` is required here because ModelContainer is not Sendable,
    //    but this value is created once at launch and is never mutated.
    //    This is the recommended pattern by Apple for SwiftData apps (@main + App).
    //
    // ⚠️  DO NOT convert to computed `var`: SwiftUI calls `body` multiple times,
    //    which would recreate the container on every render and could corrupt or lose
    //    persisted data and iCloud connections.
    private static let sharedModelContainer: ModelContainer =
        createModelContainer()

    init() {
        // TEMPORARY DIAGNOSTIC: enable verbose libdivecomputer + BLE logging
        // so we can see [BLE IOCTL] GET_NAME, [DC_IO READ/WRITE] hex dumps
        // and SLIP framing during the i300C handshake.  Remove this line
        // once the i300C connection issue is resolved.
        // LibDCSwift.Logger.shared.enableDebugMode()

        UNUserNotificationCenter.current().delegate = NotificationManager.shared
        #if os(iOS)
        if !ProcessInfo.processInfo.isiOSAppOnMac {
            BackgroundSyncTask.register()
        }
        #endif
        #if DEBUG
        // listPendingNotifications()
        // scheduleDebugNotification()
        #endif
    }
    
    @Environment(\.scenePhase) private var scenePhase
    @State private var prefs = UserPreferences.shared
    @State private var syncMonitor = CloudKitSyncMonitor()
    @State private var importCoordinator = FileImportCoordinator()
    #if os(macOS)
    @State private var showingAbout = false
    #endif
    
    var body: some Scene {
        WindowGroup {
            RootLaunchContainer {
                MainTabView()
            }
            .preferredColorScheme(prefs.appearanceMode.colorScheme)
            .modifier(LanguageOverrideModifier(locale: prefs.languageMode.locale))
            .environment(syncMonitor)
            .environment(importCoordinator)
            .onChange(of: scenePhase) { _, newPhase in
                #if os(iOS)
                if newPhase == .background, !ProcessInfo.processInfo.isiOSAppOnMac {
                    BackgroundSyncTask.schedule()
                    if UserDefaults.standard.bool(forKey: BlueDiveApp.iCloudSyncEnabledKey) {
                        Self.beginSyncBackgroundTask()
                    }
                }
                #endif
            }
            .onOpenURL { url in
                // Widget deep-links: bluedive://add/manual | bluedive://add/bluetooth
                if let action = AddDiveDeepLink.action(for: url) {
                    switch action {
                    case .manual:
                        NotificationCenter.default.post(name: .addDiveManual, object: nil)
                    case .bluetooth:
                        NotificationCenter.default.post(name: .addDiveBluetooth, object: nil)
                    }
                    return
                }
                // File open: .fit and .uddf files from document associations, share
                // sheet, AirDrop, or Files app. ContentView observes importCoordinator
                // and calls handleExternalFileURL when this becomes non-nil.
                if url.isFileURL {
                    importCoordinator.pendingURL = url
                }
            }
            #if os(macOS)
            .sheet(isPresented: $showingAbout) {
                AboutView()
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            #endif
        }
        .modelContainer(Self.sharedModelContainer)
        #if os(macOS)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About BlueDive") {
                    showingAbout = true
                }
            }
        }
        #endif
    }
    
    // MARK: - Schema
    
    /// Single source of truth for the SwiftData schema.
    /// Used by the production container.
    static let appSchema = Schema([
        Dive.self,
        MarineSight.self,
        Gear.self,
        Certification.self,
        DivingInsurance.self,
        DeviceFingerprint.self,
        TankTemplate.self,
        GearGroup.self,
    ])
 
    #if DEBUG
    /// Fires a test notification 5 seconds after launch linked to a real gear or cert item.
    /// Steps: run the app → background it → banner appears → long-press to see actions.
    /// Toggle `testGearPath` to switch between gear (MARK_DONE) and cert (RENEW) paths.
    func scheduleDebugNotification() {
        let testGearPath = false   // false = cert path
        let context = Self.sharedModelContainer.mainContext
        Task { @MainActor in
            let content = UNMutableNotificationContent()
            content.sound = .default

            if testGearPath {
                let gear = try? context.fetch(FetchDescriptor<Gear>()).first
                guard let gear else {
                    print("⚠️ No gear found — add a piece of equipment first")
                    return
                }
                content.title = "🛠️ Service Required"
                content.body = "\(gear.name) requires servicing in 30 days."
                content.categoryIdentifier = "GEAR_MAINTENANCE"
                content.userInfo = [
                    "gearId": gear.id.uuidString,
                    "type": "maintenance",
                    "gearName": gear.name,
                    "dueDateTimestamp": (gear.nextServiceDue ?? Date().addingTimeInterval(30 * 86400)).timeIntervalSince1970
                ]
                print("🔔 Debug notification for gear: \(gear.name) (\(gear.id.uuidString))")
            } else {
                let cert = try? context.fetch(FetchDescriptor<Certification>()).first
                guard let cert else {
                    print("⚠️ No certification found — add a certification first")
                    return
                }
                content.title = "⚠️ Certification Expiring"
                content.body = "Your \(cert.name) certification expires in 30 days."
                content.categoryIdentifier = "CERTIFICATION_EXPIRATION"
                content.userInfo = [
                    "certId": cert.id.uuidString,
                    "type": "expiration",
                    "certName": cert.name,
                    "dueDateTimestamp": (cert.expirationDate ?? Date().addingTimeInterval(30 * 86400)).timeIntervalSince1970
                ]
                print("🔔 Debug notification for cert: \(cert.name) (\(cert.id.uuidString))")
            }

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
            let request = UNNotificationRequest(identifier: "debug-notification", content: content, trigger: trigger)
            try? await UNUserNotificationCenter.current().add(request)
            print("🔔 Background the app now — banner fires in 5 seconds")
        }
    }
    #endif

    //  Added by Steve to list pending notifications
    func listPendingNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests(completionHandler: { requests in
            print("Pending Notifications: \(requests.count)")
            for request in requests {
                print(request)
                print("Identifier: \(request.identifier)")
                print("Title: \(request.content.title)")
                print("Body: \(request.content.body)")
                // Add more details as needed
            }
        })
    }
    
    // MARK: - Background Task Helpers

#if os(iOS)
    /// Requests ~30 s of continued background execution so the in-flight
    /// CloudKit fetch batch can commit its change token before iOS suspends
    /// the process. Only called when a download is already active.
    @MainActor
    private static func beginSyncBackgroundTask() {
        final class TaskBox: @unchecked Sendable { var id = UIBackgroundTaskIdentifier.invalid }
        let box = TaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "CloudKit sync") {
            UIApplication.shared.endBackgroundTask(box.id)
            box.id = .invalid
        }
        guard box.id != .invalid else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(25))
            UIApplication.shared.endBackgroundTask(box.id)
            box.id = .invalid
        }
    }
#endif

    // MARK: - Model Container Setup

    /// UserDefaults key for iCloud sync preference.
    static let iCloudSyncEnabledKey = "iCloudSyncEnabled"

    private static func createModelContainer() -> ModelContainer {
        let schema = appSchema

        // 🔧 Delete old incompatible database on first launch after schema changes
        // TODO: Comment this out after successful first launch
        // deleteOldDatabase()

        // Default to iCloud enabled so new installs opt-in without blocking the main thread.
        // The Settings toggle (and its existing "no account" warning) handles the unavailable case.
        // Existing users who already have the key stored are unaffected — register(defaults:) is
        // a no-op when the key is already present.
        UserDefaults.standard.register(defaults: [iCloudSyncEnabledKey: true])

        // Read iCloud sync preference
        let iCloudEnabled = UserDefaults.standard.bool(forKey: iCloudSyncEnabledKey)
        let cloudKitDB: ModelConfiguration.CloudKitDatabase = iCloudEnabled
            ? .private(CloudKitSyncMonitor.cloudKitContainerID)
            : .none
        
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            cloudKitDatabase: cloudKitDB
        )
        
        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            
            // Main context configuration
            let context = container.mainContext
            context.autosaveEnabled = true
            
            let syncStatus = iCloudEnabled ? "iCloud sync ON" : "iCloud sync OFF (local only)"
            logger.info("✅ ModelContainer created successfully - \(syncStatus)")
            logger.debug("📂 Storage path: \(getStorePath())")
            
            return container
            
        } catch let error as NSError {
            logger.error("❌ Error creating ModelContainer: \(error.localizedDescription)")
            logger.debug("Error code: \(error.code), Domain: \(error.domain)")
            
            // Recovery attempt with memory mode
            return createFallbackContainer(schema: schema, error: error)
        }
    }
    
    /// Creates an in-memory container as fallback
    private static func createFallbackContainer(schema: Schema, error originalError: Error) -> ModelContainer {
        logger.warning("⚠️ Attempting to create an in-memory container (fallback)")
        
        let fallbackConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        
        do {
            let container = try ModelContainer(for: schema, configurations: [fallbackConfiguration])
            logger.warning("⚠️ Memory mode enabled - Data will NOT be saved")
            return container
        } catch let fallbackError {
            // Last resort: crash with detailed message
            logger.critical("💥 Unable to create ModelContainer")
            fatalError("""
                Unable to create SwiftData ModelContainer.
                Initial error: \(originalError.localizedDescription)
                Fallback error: \(fallbackError.localizedDescription)
                
                Check:
                - File system access permissions
                - Available disk space
                - Model compliance with @Model
                """)
        }
    }
    
    /// Gets the storage path for debugging
    private static func getStorePath() -> String {
        if let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            // SwiftData stores the database as default.store inside a subdirectory
            // named after the bundle identifier
            let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
            return url.appendingPathComponent(bundleID).appendingPathComponent("default.store").path
        }
        return "Unknown path"
    }
    
    /// Deletes the old database to fix schema migration issues
    private static func deleteOldDatabase() {
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            logger.warning("⚠️ Could not locate Application Support directory")
            return
        }
        
        let storeURL = appSupportURL.appendingPathComponent("default.store")
        let shmURL = appSupportURL.appendingPathComponent("default.store-shm")
        let walURL = appSupportURL.appendingPathComponent("default.store-wal")
        
        let fileManager = FileManager.default
        
        for url in [storeURL, shmURL, walURL] {
            if fileManager.fileExists(atPath: url.path) {
                do {
                    try fileManager.removeItem(at: url)
                    logger.info("🗑️ Deleted old database file: \(url.lastPathComponent)")
                } catch {
                    logger.error("❌ Failed to delete \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }
}


