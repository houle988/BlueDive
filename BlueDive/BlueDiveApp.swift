import SwiftUI
import SwiftData
import CoreData
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
/// App delegate that keeps the app running after its last window closes, turns off window
/// tabbing, removes obsolete saved window frames and brings the app to the front at launch.
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable macOS window tabbing so "View > Show Tab Bar" doesn't
        // offer to open multiple window-tabs alongside the app's own TabView.
        NSWindow.allowsAutomaticWindowTabbing = false
        removeObsoleteWindowFrames()
        // Bring the app to the front once it has launched. Launched from Spotlight or right
        // after download, it could otherwise stay behind other windows. Activation is
        // cooperative: macOS may decline the request, for example when another app is in use.
        NSApp.activate()
    }

    /// Version of the obsolete-window-frame cleanup already done, so it runs only once.
    private static let windowFrameCleanupVersionKey = "windowFrameCleanupVersion"

    /// Removes, once, window frames that are never read back. Before the main window group had
    /// a stable id, SwiftUI's frame autosave name embedded a memory address that changed on
    /// every launch, so each launch wrote a new "NSWindow Frame SwiftUI.WindowGroup<…>" key.
    /// "macMainWindowFrame" was saved by an earlier, custom frame autosave. It runs only once so
    /// it can never delete the saved frame of a window scene added later.
    private func removeObsoleteWindowFrames() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: Self.windowFrameCleanupVersionKey) < 1 else { return }
        let obsoleteKeys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("NSWindow Frame SwiftUI.WindowGroup<") || $0 == "macMainWindowFrame"
        }
        for key in obsoleteKeys {
            defaults.removeObject(forKey: key)
        }
        defaults.set(1, forKey: Self.windowFrameCleanupVersionKey)
    }
}

enum MainWindowPlacement {
    /// The id of the main window group (see mainWindowGroup).
    static let windowGroupID = "main"

    /// Prefix of the frame autosave names SwiftUI gives the main window group's windows
    /// ("main-AppWindow-1", "main-AppWindow-2", …). Observed, not documented by Apple.
    static let autosaveNamePrefix = "\(windowGroupID)-AppWindow-"

    /// The top-left corner, in the global screen coordinates `WindowPlacement` positions use,
    /// of the display SwiftUI reports as the default (focused) display. `DisplayProxy`
    /// rectangles are relative to their own display (their bounds start at the origin), so a
    /// rectangle from a display other than the primary one must be offset by this origin.
    /// The display is identified as NSScreen.main when its size matches `bounds`, otherwise as
    /// the only connected display of that size. Returns nil, meaning no offset, when neither
    /// applies or when `bounds` doesn't start at the origin (already global, so offsetting it
    /// again could place the window off-screen).
    static func globalOrigin(ofDisplayWithBounds bounds: CGRect) -> CGPoint? {
        guard bounds.origin == .zero else { return nil }
        let screen: NSScreen?
        if let main = NSScreen.main, main.frame.size == bounds.size {
            screen = main
        } else {
            let matches = NSScreen.screens.filter { $0.frame.size == bounds.size }
            screen = matches.count == 1 ? matches.first : nil
        }
        guard let screen, let primary = NSScreen.screens.first else { return nil }
        // NSScreen frames have a bottom-left origin at the primary display's corner;
        // WindowPlacement measures from its top-left corner, with y increasing downwards.
        return CGPoint(x: screen.frame.minX, y: primary.frame.maxY - screen.frame.maxY)
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
        BackgroundSyncTask.register()
        #endif
        #if DEBUG
        // listPendingNotifications()
        // scheduleDebugNotification()
        if let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
            let defaultsPath = libraryURL.appendingPathComponent("Preferences/\(bundleID).plist").path
            print("🗂️ UserDefaults plist path: \(defaultsPath)")
        }
        #endif
    }
    
    @Environment(\.scenePhase) private var scenePhase
    @State private var prefs = UserPreferences.shared
    @State private var syncMonitor = CloudKitSyncMonitor()
    @State private var importCoordinator = FileImportCoordinator()
    @State private var diveStore = DiveStore()
    #if os(macOS)
    @State private var showingAbout = false
    #endif
    
    /// The main window group. On macOS it has a stable id; SwiftUI then gives the window a
    /// stable frame autosave name ("main-AppWindow-1" — observed, not documented by Apple), so
    /// AppKit saves the window's size and position and restores them on relaunch and when the
    /// window is reopened from the Dock, even when "Close windows when quitting an application"
    /// is on (the macOS default). Without an id, the observed name is derived from the content's
    /// type and includes a memory address that changes on every launch, so the saved frame was
    /// never found. On iOS the window group is unchanged.
    private func mainWindowGroup<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some Scene {
        #if os(macOS)
        return WindowGroup(id: MainWindowPlacement.windowGroupID) { content() }
            // Toolbar controls are icon-only (no titles), so AppKit's "Icon and Text"
            // display mode would only add empty label space. A fixed style removes that
            // choice from the toolbar's context menu.
            .windowToolbarLabelStyle(fixed: .iconOnly)
        #else
        return WindowGroup { content() }
        #endif
    }

    var body: some Scene {
        mainWindowGroup {
            RootLaunchContainer {
                MainTabView()
            }
            .preferredColorScheme(prefs.appearanceMode.colorScheme)
            .tint(.cyan)
            #if os(macOS)
            // Keep the app background visible behind the window toolbar; otherwise macOS
            // reveals its own lighter toolbar background when the pointer hovers over it.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            // Sheets are sized to fit inside the window (.presentationSizing(.page)), so a
            // minimum window size keeps them from being squeezed below a usable height.
            // 600 pt still fits the smallest scaled display (13" "Larger Text", ~625 pt visible).
            .frame(minWidth: 900, minHeight: 600)
            #endif
            .modifier(LanguageOverrideModifier(locale: prefs.languageMode.locale))
            .environment(diveStore)
            .environment(syncMonitor)
            .environment(importCoordinator)
            .onChange(of: scenePhase) { _, newPhase in
                #if os(iOS)
                if newPhase == .background {
                    BackgroundSyncTask.schedule()
                    if UserDefaults.standard.bool(forKey: BlueDiveApp.iCloudSyncEnabledKey) {
                        Self.beginSyncBackgroundTask()
                    }
                }
                #endif
            }
            .onOpenURL { url in
                importCoordinator.noteExternalOpen()
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
                // File open: .fit, .uddf, .ssrf, and .bluedive files from document
                // associations, share sheet, AirDrop, or Files app. ContentView observes
                // importCoordinator and calls handleExternalFileURL when this becomes non-nil.
                if url.isFileURL {
                    importCoordinator.pendingURL = url
                }
            }
            #if os(macOS)
            .sheet(isPresented: $showingAbout) {
                AboutView()
                    .standardSheetPresentation()
            }
            #endif
        }
        .modelContainer(Self.sharedModelContainer)
        #if os(macOS)
        // On first launch, open the window maximized on the focused display: filling its
        // visible area (below the menu bar, beside the Dock), so the first-run disclaimer and
        // every sheet have room. Afterwards AppKit's frame autosave (see mainWindowGroup) moves
        // it to the size and position the user last left it at, before the window is shown.
        // AppKit restores that frame onto the focused display: when the window was last on
        // another display, it keeps its size but is moved onto the focused one.
        // A window opened with File → New Window while another one is open keeps the system
        // default placement instead of covering the whole screen.
        .defaultWindowPlacement { _, context in
            // The closure isn't documented to run on the main thread (AppKit creates windows
            // there in practice); off it, fall back to the default placement instead of trapping.
            guard Thread.isMainThread else { return WindowPlacement() }
            let display = context.defaultDisplay
            let (hasOpenWindow, displayOrigin) = MainActor.assumeIsolated {
                (NSApp.windows.contains {
                    $0.frameAutosaveName.hasPrefix(MainWindowPlacement.autosaveNamePrefix)
                        && ($0.isVisible || $0.isMiniaturized)
                }, MainWindowPlacement.globalOrigin(ofDisplayWithBounds: display.bounds))
            }
            guard !hasOpenWindow else { return WindowPlacement() }
            let visible = display.visibleRect.offsetBy(dx: displayOrigin?.x ?? 0, dy: displayOrigin?.y ?? 0)
            return WindowPlacement(visible.origin, size: visible.size)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About BlueDive") {
                    showingAbout = true
                }
            }
            // Settings is the same sheet as on iOS (presented by ContentView),
            // not a separate Settings scene; ⌘, opens it from the app menu.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    // Settings is itself a sheet: ignore ⌘, while another sheet is already
                    // shown (the key window is then that sheet, or has one attached), so the
                    // request is not left pending until that sheet closes.
                    if let window = NSApp.keyWindow, window.sheetParent != nil || window.attachedSheet != nil {
                        return
                    }
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .sidebar) {
                ProfilePreviewCommand()
            }
        }
        #endif
    }
    
    // MARK: - Schema
    
    /// Every SwiftData model type. Shared by `appSchema` and the CloudKit schema
    /// initialization (DEBUG), so the two can never list different models.
    static let appModelTypes: [any PersistentModel.Type] = [
        Dive.self,
        MarineSight.self,
        Gear.self,
        Certification.self,
        DivingInsurance.self,
        DeviceFingerprint.self,
        TankTemplate.self,
        GearGroup.self,
        DivePhoto.self,
        DivePhotoThumbnail.self,
        DivePhotoOriginal.self,
        Species.self,
        SpeciesImage.self,
    ]

    /// Single source of truth for the SwiftData schema.
    /// Used by the production container.
    static let appSchema = Schema(appModelTypes)
 
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

        #if DEBUG
        // Only on request, and only when iCloud sync is on.
        if iCloudEnabled, UserDefaults.standard.bool(forKey: initializeCloudKitSchemaKey) {
            initializeCloudKitSchema(storeURL: modelConfiguration.url)
        }
        #endif

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            
            // Main context configuration
            let context = container.mainContext
            context.autosaveEnabled = true
            // Tags this app's own saves in persistent history, so they can be told apart
            // from transactions imported from iCloud (another device's edits).
            context.author = "BlueDive.main"

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
    
    #if DEBUG
    /// Launch argument that creates the complete CloudKit development schema once:
    /// Xcode → Product → Scheme → Edit Scheme → Run → Arguments → `-initializeCloudKitSchema YES`.
    static let initializeCloudKitSchemaKey = "initializeCloudKitSchema"

    /// Uploads a representative record for every model, with a value for every field Core Data
    /// may write (including the `CD_<field>_ckAsset` fields of large values and fields the app
    /// never fills, such as `Species.sourceIdentifier`), then deletes those records. CloudKit
    /// creates a field only when a record carries a value for it, so data entered by hand
    /// cannot complete the schema. Apple's documented SwiftData approach: Core Data loads the
    /// same store, initializes the schema, and unloads the store before SwiftData opens it,
    /// so the two frameworks never sync at the same time. Development environment only
    /// (Debug builds); deploy the schema to production in the CloudKit Console afterwards.
    private static func initializeCloudKitSchema(storeURL: URL) {
        logger.info("☁️ Initializing the CloudKit development schema…")
        do {
            try autoreleasepool {
                let description = NSPersistentStoreDescription(url: storeURL)
                description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                    containerIdentifier: CloudKitSyncMonitor.cloudKitContainerID)
                // The store keeps the history tracking SwiftData uses with it.
                description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
                description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
                // Loaded synchronously, so the schema is initialized after the load finishes.
                description.shouldAddStoreAsynchronously = false
                guard let model = NSManagedObjectModel.makeManagedObjectModel(for: appModelTypes) else {
                    logger.error("❌ CloudKit schema: could not build the managed object model")
                    return
                }
                let container = NSPersistentCloudKitContainer(name: "BlueDive", managedObjectModel: model)
                container.persistentStoreDescriptions = [description]
                var loadError: Error?
                container.loadPersistentStores { _, error in loadError = error }
                if let loadError { throw loadError }
                try container.initializeCloudKitSchema()
                // Unloaded before SwiftData opens the store.
                if let store = container.persistentStoreCoordinator.persistentStores.first {
                    try container.persistentStoreCoordinator.remove(store)
                }
            }
            logger.info("✅ CloudKit development schema initialized — check the CloudKit Console")
        } catch {
            logger.error("❌ CloudKit schema initialization failed: \(error.localizedDescription)")
        }
    }
    #endif

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



#if os(macOS)
/// View → Show Profile Preview (⇧⌘P): shows or hides the profile chart above the main dive
/// list — the same preference as Settings → Dive Profile. A view, so the menu's checkmark
/// follows the preference when it is changed in Settings.
private struct ProfilePreviewCommand: View {
    @State private var prefs = UserPreferences.shared

    var body: some View {
        Toggle("Show Profile Preview", isOn: $prefs.showDiveListProfilePreview)
            .keyboardShortcut("p", modifiers: [.command, .shift])
    }
}
#endif
