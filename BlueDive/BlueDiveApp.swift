import SwiftUI
import SwiftData
import CloudKit
import UserNotifications
import os.log

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
        UNUserNotificationCenter.current().delegate = NotificationManager.shared
        listPendingNotifications()
    }
    
    @State private var prefs = UserPreferences.shared
    #if os(macOS)
    @State private var showingAbout = false
    #endif
    
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .preferredColorScheme(prefs.appearanceMode.colorScheme)
                .modifier(LanguageOverrideModifier(locale: prefs.languageMode.locale))
            #if os(macOS)
                .sheet(isPresented: $showingAbout) {
                    AboutView()
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
    
    // MARK: - Model Container Setup
    
    /// UserDefaults key for iCloud sync preference.
    static let iCloudSyncEnabledKey = "iCloudSyncEnabled"
    
    /// Checks iCloud account status on first launch and sets the default sync preference.
    /// If the user has no iCloud account, sync defaults to disabled.
    private static func configureFirstLaunchiCloudDefault() {
        let defaults = UserDefaults.standard
        let hasLaunchedKey = "hasConfigurediCloudDefault"
        
        guard !defaults.bool(forKey: hasLaunchedKey) else { return }
        
        // First launch: check iCloud account status synchronously using a semaphore
        let semaphore = DispatchSemaphore(value: 0)
        var accountAvailable = false
        
        CKContainer(identifier: "iCloud.app.bluedive.universal").accountStatus { status, _ in
            accountAvailable = (status == .available)
            semaphore.signal()
        }
        semaphore.wait()
        
        defaults.set(accountAvailable, forKey: iCloudSyncEnabledKey)
        defaults.set(true, forKey: hasLaunchedKey)
        
        logger.info("First launch iCloud config: account available = \(accountAvailable), sync enabled = \(accountAvailable)")
    }
    
    private static func createModelContainer() -> ModelContainer {
        let schema = appSchema
        
        // 🔧 Delete old incompatible database on first launch after schema changes
        // TODO: Comment this out after successful first launch
        // deleteOldDatabase()
        
        // Configure iCloud default on first launch
        configureFirstLaunchiCloudDefault()
        
        // Read iCloud sync preference
        let iCloudEnabled = UserDefaults.standard.bool(forKey: iCloudSyncEnabledKey)
        let cloudKitDB: ModelConfiguration.CloudKitDatabase = iCloudEnabled
            ? .private("iCloud.app.bluedive.universal")
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


