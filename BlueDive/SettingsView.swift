import SwiftUI
import SwiftData
import CloudKit
import UserNotifications
import UniformTypeIdentifiers
import LibDCSwift
#if os(macOS)
import AppKit
#endif

// MARK: - Depth Unit

enum DepthUnit: String, CaseIterable {
    case meters = "meters"
    case feet   = "feet"

    var symbol: String {
        switch self {
        case .meters: return "m"
        case .feet:   return "ft"
        }
    }

    /// Converts a value stored in metres to the display unit.
    func convert(_ meters: Double) -> Double {
        switch self {
        case .meters: return meters
        case .feet:   return meters * 3.28084
        }
    }

    /// Formats a metre value with the correct unit symbol.
    func formatted(_ meters: Double, decimals: Int = 1) -> String {
        let value = convert(meters)
        return String(format: "%.\(decimals)f \(symbol)", value)
    }
}

// MARK: - Pressure Unit

enum PressureUnit: String, CaseIterable {
    case bar = "bar"
    case psi = "psi"
    case pa  = "pa"

    var symbol: String {
        switch self {
        case .bar: return "bar"
        case .psi: return "psi"
        case .pa:  return "Pa"
        }
    }

    // MARK: Internal canonical representation

    /// Normalises an import-time `pressureFormat` string (as stored in
    /// `importPressureUnit`) to a `PressureUnit` case.
    /// Accepted values: `"bar"`, `"psi"`, `"pa"` (case-insensitive).
    static func from(importFormat: String) -> PressureUnit {
        switch importFormat.lowercased() {
        case "bar":        return .bar
        case "psi":        return .psi
        case "pa", "pascal": return .pa
        default:           return .bar  // safe fallback
        }
    }

    // MARK: Conversion helpers

    /// Converts a raw value **stored in `storedUnit`** to a value expressed in
    /// the receiver unit.  This is the single read-time conversion point for all
    /// pressure fields (`startPressure`, `endPressure`, `TankData.startPressure`,
    /// `TankData.endPressure`, `TankData.workingPressure`, sample `tankPressure`).
    ///
    /// **Rule:** never call this at import time and never use the result to
    /// mutate the database.  It is a read-time display helper only.
    func convert(_ value: Double, from storedUnit: PressureUnit) -> Double {
        // Step 1 — normalise stored value to bar
        let bar: Double
        switch storedUnit {
        case .bar: bar = value
        case .psi: bar = value / 14.5038
        case .pa:  bar = value / 100_000.0
        }
        // Step 2 — convert bar to the target (display) unit
        switch self {
        case .bar: return bar
        case .psi: return bar * 14.5038
        case .pa:  return bar * 100_000.0
        }
    }

    /// Formats a stored pressure value using the correct source unit and this
    /// display unit, appending the unit symbol.
    ///
    /// - Parameters:
    ///   - value: The value **exactly as stored in the database**.
    ///   - storedUnit: The unit the value was originally imported in.
    ///   - decimals: Number of decimal places (default 0).
    func formatted(_ value: Double, from storedUnit: PressureUnit, decimals: Int = 0) -> String {
        let display = convert(value, from: storedUnit)
        return String(format: "%.\(decimals)f \(symbol)", display)
    }

    /// Convenience: converts a value already known to be in bar to the display
    /// unit.  Use this **only** when the source is guaranteed to be bar
    /// (e.g. UDDF parser always normalises to bar internally).
    func convertFromBar(_ bar: Double) -> Double {
        convert(bar, from: .bar)
    }

    /// Formats a bar value with the correct unit symbol.
    /// Legacy convenience for callers that already hold a bar value.
    func formatted(_ bar: Double, decimals: Int = 0) -> String {
        formatted(bar, from: .bar, decimals: decimals)
    }
}

// MARK: - Temperature Unit

enum TemperatureUnit: String, CaseIterable {
    case celsius    = "celsius"
    case fahrenheit = "fahrenheit"
    case kelvin     = "kelvin"

    var symbol: String {
        switch self {
        case .celsius:    return "°C"
        case .fahrenheit: return "°F"
        case .kelvin:     return "K"
        }
    }

    // MARK: Internal canonical representation

    /// Normalises an import-time `temperatureFormat` string (as stored in
    /// `importTemperatureUnit`) to a `TemperatureUnit` case.
    /// Accepted values: `"°c"`, `"°f"`, `"°k"` (case-insensitive),
    /// plus the `rawValue` spellings (`"celsius"`, `"fahrenheit"`, `"kelvin"`).
    static func from(importFormat: String) -> TemperatureUnit {
        switch importFormat.lowercased() {
        case "°c", "celsius":    return .celsius
        case "°f", "fahrenheit": return .fahrenheit
        case "°k", "kelvin":     return .kelvin
        default:                 return .celsius   // safe fallback
        }
    }

    // MARK: Conversion helpers

    /// Converts a raw value **stored in `storedUnit`** to a value expressed in
    /// the receiver unit.  This is the canonical, single conversion point.
    ///
    /// **Rule:** never call this at import time and never use the result to
    /// mutate the database.  It is a read-time display helper only.
    func convert(_ value: Double, from storedUnit: TemperatureUnit) -> Double {
        // Step 1 — normalise stored value to Celsius
        let celsius: Double
        switch storedUnit {
        case .celsius:    celsius = value
        case .fahrenheit: celsius = (value - 32) * 5 / 9
        case .kelvin:     celsius = value - 273.15
        }
        // Step 2 — convert Celsius to the target (display) unit
        switch self {
        case .celsius:    return celsius
        case .fahrenheit: return celsius * 9 / 5 + 32
        case .kelvin:     return celsius + 273.15
        }
    }

    // MARK: Formatting

    /// Formats a raw stored value using the correct source unit and this display unit.
    ///
    /// - Parameters:
    ///   - value: The value **exactly as stored in the database** (no pre-conversion).
    ///   - storedUnit: The unit the value was originally imported in.
    func formatted(_ value: Double, from storedUnit: TemperatureUnit) -> String {
        let display = convert(value, from: storedUnit)
        return "\(Int(display.rounded()))\(symbol)"
    }

    /// Convenience overload for legacy callers that provide a value already in
    /// Celsius (UDDF import path, manual entry, etc.).
    /// All call sites in views/charts should migrate to `formatted(_:from:)`.
    func formatted(_ celsius: Double) -> String {
        formatted(celsius, from: .celsius)
    }
}

// MARK: - Volume Unit

enum VolumeUnit: String, CaseIterable {
    case liters     = "liters"
    case cubicFeet  = "cubic feet"

    var symbol: String {
        switch self {
        case .liters:    return "L"
        case .cubicFeet: return "ft³"
        }
    }

    // MARK: Internal canonical representation

    /// Normalises an import-time `volumeFormat` string (as stored in
    /// `importVolumeUnit`) to a `VolumeUnit` case.
    /// Accepted values: `"liters"`, `"cubic feet"` (case-insensitive).
    static func from(importFormat: String) -> VolumeUnit {
        switch importFormat.lowercased() {
        case "liters", "litres", "l": return .liters
        case "cubic feet", "cuft", "ft³", "ft3": return .cubicFeet
        default: return .liters  // safe fallback
        }
    }

}

// MARK: - Weight Unit

enum WeightUnit: String, CaseIterable {
    case kilograms = "kilograms"
    case pounds    = "pounds"

    var symbol: String {
        switch self {
        case .kilograms: return "kg"
        case .pounds:    return "lb"
        }
    }

    // MARK: Internal canonical representation

    /// Normalises an import-time `weightFormat` string (as stored in
    /// `importWeightUnit`) to a `WeightUnit` case.
    /// Accepted values: `"kg"`, `"lb"`, `"kilograms"`, `"pounds"` (case-insensitive).
    static func from(importFormat: String) -> WeightUnit {
        switch importFormat.lowercased() {
        case "kg", "kilograms", "kilogram": return .kilograms
        case "lb", "lbs", "pounds", "pound": return .pounds
        default: return .kilograms  // safe fallback
        }
    }

    // MARK: Conversion helpers

    /// Converts a raw value **stored in `storedUnit`** to a value expressed in
    /// the receiver unit.  This is the single read-time conversion point for all
    /// weight fields (diver weight, equipment weight, weight systems).
    ///
    /// **Rule:** never call this at import time and never use the result to
    /// mutate the database.  It is a read-time display helper only.
    func convert(_ value: Double, from storedUnit: WeightUnit) -> Double {
        // Step 1 — normalise stored value to kilograms
        let kilograms: Double
        switch storedUnit {
        case .kilograms: kilograms = value
        case .pounds:    kilograms = value / 2.20462
        }
        // Step 2 — convert kilograms to the target (display) unit
        switch self {
        case .kilograms: return kilograms
        case .pounds:    return kilograms * 2.20462
        }
    }

    /// Formats a stored weight value using the correct source unit and this
    /// display unit, appending the unit symbol.
    ///
    /// - Parameters:
    ///   - value: The value **exactly as stored in the database**.
    ///   - storedUnit: The unit the value was originally imported in.
    ///   - decimals: Number of decimal places (default 1).
    func formatted(_ value: Double, from storedUnit: WeightUnit, decimals: Int = 2) -> String {
        let display = convert(value, from: storedUnit)
        return String(format: "%.\(decimals)f \(symbol)", display)
    }

    /// Formats a kilograms value with the correct unit symbol.
    func formatted(_ kilograms: Double, decimals: Int = 2) -> String {
        formatted(kilograms, from: .kilograms, decimals: decimals)
    }
}

// MARK: - Appearance Mode

enum AppearanceMode: String, CaseIterable {
    case system = "system"
    case light  = "light"
    case dark   = "dark"

    var label: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - App Language

enum AppLanguage: String, CaseIterable {
    case system = "system"
    case english = "en"
    case frenchCanada = "fr-CA"

    var label: LocalizedStringKey {
        switch self {
        case .system:       "System"
        case .english:      "English"
        case .frenchCanada: "Français"
        }
    }

    var locale: Locale? {
        switch self {
        case .system: return nil
        case .english: return Locale(identifier: "en")
        case .frenchCanada: return Locale(identifier: "fr-CA")
        }
    }
}

// MARK: - User Preferences

@Observable
class UserPreferences {

    static let shared = UserPreferences()

    var depthUnit: DepthUnit {
        didSet { UserDefaults.standard.set(depthUnit.rawValue, forKey: "depthUnit") }
    }
    var pressureUnit: PressureUnit {
        didSet { UserDefaults.standard.set(pressureUnit.rawValue, forKey: "pressureUnit") }
    }
    var temperatureUnit: TemperatureUnit {
        didSet { UserDefaults.standard.set(temperatureUnit.rawValue, forKey: "temperatureUnit") }
    }
    var volumeUnit: VolumeUnit {
        didSet { UserDefaults.standard.set(volumeUnit.rawValue, forKey: "volumeUnit") }
    }
    var weightUnit: WeightUnit {
        didSet { UserDefaults.standard.set(weightUnit.rawValue, forKey: "weightUnit") }
    }
    var appearanceMode: AppearanceMode {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode") }
    }
    var languageMode: AppLanguage {
        didSet { UserDefaults.standard.set(languageMode.rawValue, forKey: "languageMode") }
    }

    init() {
        self.depthUnit        = DepthUnit(rawValue: UserDefaults.standard.string(forKey: "depthUnit") ?? "meters") ?? .meters
        self.pressureUnit     = PressureUnit(rawValue: UserDefaults.standard.string(forKey: "pressureUnit") ?? "bar") ?? .bar
        self.temperatureUnit  = TemperatureUnit(rawValue: UserDefaults.standard.string(forKey: "temperatureUnit") ?? "celsius") ?? .celsius
        self.volumeUnit       = VolumeUnit(rawValue: UserDefaults.standard.string(forKey: "volumeUnit") ?? "liters") ?? .liters
        self.weightUnit       = WeightUnit(rawValue: UserDefaults.standard.string(forKey: "weightUnit") ?? "kilograms") ?? .kilograms
        self.appearanceMode   = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearanceMode") ?? "system") ?? .system
        self.languageMode     = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "languageMode") ?? "system") ?? .system
    }

    func resetToDefaults() {
        depthUnit                 = .meters
        pressureUnit              = .bar
        temperatureUnit           = .celsius
        volumeUnit                = .liters
        weightUnit                = .kilograms
        appearanceMode            = .system
        languageMode              = .system
        ChartLineVisibility().save()
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage("notificationsEnabled")     private var notificationsEnabled = false
    @AppStorage("gearMaintenanceReminders") private var gearReminders  = true
    @AppStorage("certificationReminders")   private var certReminders  = true
    @AppStorage("milestoneNotifications")   private var milestoneNotifs = true

    // @State on an @Observable singleton: correct pattern for SwiftUI + Observation.
    // Using @State ensures SwiftUI tracks mutations and re-renders the view.
    @State private var prefs = UserPreferences.shared

    @State private var previousAppearance: AppearanceMode = UserPreferences.shared.appearanceMode
    @State private var previousLanguage: AppLanguage = UserPreferences.shared.languageMode
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showingResetAlert = false
    @State private var showingEraseAllDataAlert = false
    @State private var isErasingData = false
    private enum ErasePhase {
        case erasing
        case done(errorCount: Int, countdown: Int)
    }
    @State private var erasePhase: ErasePhase?
    @State private var isDebugMode = LibDCSwift.Logger.shared.isDebugMode
    @State private var showDiagnosticExporter = false
    @State private var diagnosticLogDocument: ExportableFileDocument?
    @State private var settingsAppeared = false
    @State private var showingAboutSheet = false
    @State private var showWelcomeWizard = false
    @State private var showDisclaimer = false
    @State private var iCloudSyncEnabled = UserDefaults.standard.bool(forKey: BlueDiveApp.iCloudSyncEnabledKey)
    @State private var iCloudAccountStatus: CKAccountStatus = .couldNotDetermine
    @State private var iCloudStatusChecked = false
    #if os(iOS)
    @State private var showBackupExporter = false
    @State private var backupDocument: ExportableFileDocument?
    @State private var backupFileName: String = ""
    #endif
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Hero Header
                    settingsHeroHeader
                        .opacity(settingsAppeared ? 1.0 : 0.0)
                        .scaleEffect(settingsAppeared ? 1.0 : 0.95)
                    
                    // Content sections
                    VStack(spacing: 20) {
                        appearanceSection
                        unitsSection
                        notificationsSection
                        dataManagementSection
                        iCloudSection
                        diagnosticsSection
                        dangerZoneSection
                        aboutSection
                    }
                    .opacity(settingsAppeared ? 1.0 : 0.0)
                    .offset(y: settingsAppeared ? 0 : 15)
                    .padding(.bottom, 40)
                }
            }
            .onAppear {
                withAnimation(.easeOut(duration: 0.4)) {
                    settingsAppeared = true
                }
            }
            .background(
                LinearGradient(
                    colors: [
                        Color.platformBackground,
                        Color.cyan.opacity(0.05),
                        Color.platformBackground
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            .frame(minWidth: 520, idealWidth: 600, maxWidth: 800, minHeight: 600, idealHeight: 700, maxHeight: 900)
            #endif
            .preferredColorScheme(prefs.appearanceMode.colorScheme)
            .onChange(of: prefs.appearanceMode) {
                if previousAppearance == .system || prefs.appearanceMode == .system {
                    dismiss()
                }
                previousAppearance = prefs.appearanceMode
            }
            .onChange(of: prefs.languageMode) {
                if previousLanguage == .system || prefs.languageMode == .system {
                    dismiss()
                }
                previousLanguage = prefs.languageMode
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.cyan)
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
            .task {
                await checkNotificationStatus()
                if notificationsEnabled {
                    #if canImport(UserNotifications)
                    NotificationManager.shared.setupNotificationCategories()
                    await rescheduleAllNotifications()
                    #endif
                }
                await checkiCloudAccountStatus()
            }
            .alert("Reset preferences?", isPresented: $showingResetAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) {
                    withAnimation { UserPreferences.shared.resetToDefaults() }
                }
            } message: {
                Text("All preferences will return to their default values.")
            }
            .alert("Erase all local data?", isPresented: $showingEraseAllDataAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Erase Local Data", role: .destructive) {
                    eraseAllData()
                }
            } message: {
                Text("This will delete all local data and close the app after 30 seconds. Your iCloud data will be preserved and will sync back down when you relaunch the app.")
            }
            #if os(iOS)
            .fileExporter(
                isPresented: $showBackupExporter,
                document: backupDocument,
                contentType: .zip,
                defaultFilename: backupFileName
            ) { result in
                backupDocument = nil
            }
            .fileExporter(
                isPresented: $showDiagnosticExporter,
                document: diagnosticLogDocument,
                contentType: .plainText,
                defaultFilename: "BlueDive-diagnostic-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")).txt"
            ) { result in
                diagnosticLogDocument = nil
            }
            #endif
        }
    }
    
    // MARK: - View Components
    
    private var settingsHeroHeader: some View {
        VStack(spacing: 0) {
            // Grande icône avec gradient background
            ZStack {
                // Cercle avec gradient
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.3), Color.blue.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 140, height: 140)
                    .blur(radius: 20)
                
                Circle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 120, height: 120)
                
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .padding(.top, 20)
            
            // Title
            VStack(spacing: 6) {
                Text("Settings")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                
                Text("Customize your experience")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.cyan)
            }
            .padding(.top, 16)
        }
        .padding(.bottom, 30)
    }
    
    private var appearanceSection: some View {
        VStack(spacing: 16) {
            SectionHeaderModern(title: "Appearance", icon: "paintbrush.fill", color: .pink)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Theme", systemImage: "circle.lefthalf.filled")
                        .font(.subheadline)
                        .foregroundStyle(.cyan)
                    Picker("Theme", selection: $prefs.appearanceMode) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.03))
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose System to follow your device's appearance, or override with Light or Dark.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Switching from or to System will close this window to apply the new setting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)

                Divider().padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    Label("Language", systemImage: "globe")
                        .font(.subheadline)
                        .foregroundStyle(.cyan)
                    Picker("Language", selection: $prefs.languageMode) {
                        ForEach(AppLanguage.allCases, id: \.self) { lang in
                            Text(lang.label).tag(lang)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.03))
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose System to follow your device's language, or override with English or Français.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Switching from or to System will close this window to apply the new setting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
            )
            .padding(.horizontal)
        }
    }

    private var unitsSection: some View {
        VStack(spacing: 16) {
            SectionHeaderModern(title: "Units of Measure", icon: "ruler", color: .orange)

            
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Depth", systemImage: "arrow.down.to.line")
                        .font(.subheadline)
                        .foregroundStyle(.cyan)
                    Picker("Depth", selection: $prefs.depthUnit) {
                        ForEach(DepthUnit.allCases, id: \.self) { unit in
                            Text(unit.symbol.uppercased()).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.03))
                )
                
                VStack(alignment: .leading, spacing: 8) {
                    Label("Tank pressure", systemImage: "gauge.with.dots.needle.bottom.50percent")
                        .font(.subheadline)
                        .foregroundStyle(.cyan)
                    Picker("Pressure", selection: $prefs.pressureUnit) {
                        ForEach(PressureUnit.allCases, id: \.self) { unit in
                            Text(unit.symbol).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.03))
                )
                
                VStack(alignment: .leading, spacing: 8) {
                    Label("Temperature", systemImage: "thermometer.medium")
                        .font(.subheadline)
                        .foregroundStyle(.cyan)
                    Picker("Temperature", selection: $prefs.temperatureUnit) {
                        // Kelvin is a valid user preference (scientific divers)
                        ForEach(TemperatureUnit.allCases, id: \.self) { unit in
                            Text(unit.symbol).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.03))
                )
                
                VStack(alignment: .leading, spacing: 8) {
                    Label("Tank volume", systemImage: "cylinder.fill")
                        .font(.subheadline)
                        .foregroundStyle(.cyan)
                    Picker("Volume", selection: $prefs.volumeUnit) {
                        ForEach(VolumeUnit.allCases, id: \.self) { unit in
                            Text(unit.symbol).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.03))
                )
                
                VStack(alignment: .leading, spacing: 8) {
                    Label("Weight", systemImage: "scalemass.fill")
                        .font(.subheadline)
                        .foregroundStyle(.cyan)
                    Picker("Weight", selection: $prefs.weightUnit) {
                        ForEach(WeightUnit.allCases, id: \.self) { unit in
                            Text(unit.symbol).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.03))
                )
                
                Text("Depth in \(prefs.depthUnit.symbol) · Pressure in \(prefs.pressureUnit.symbol) · Temperature in \(prefs.temperatureUnit.symbol) · Volume in \(prefs.volumeUnit.symbol) · Weight in \(prefs.weightUnit.symbol)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
            )
            .padding(.horizontal)
        }
    }
    
    
    private var notificationsSection: some View {
        VStack(spacing: 16) {
            SectionHeaderModern(title: "Notifications", icon: "bell.fill", color: .purple)

            
            VStack(spacing: 12) {
                ModernToggleRow(
                    isOn: $notificationsEnabled,
                    icon: "bell.fill",
                    iconColor: .purple,
                    title: "Notifications",
                    subtitle: "Enable reminders and notifications"
                )
                .onChange(of: notificationsEnabled) {
                    if notificationsEnabled {
                        Task { await requestNotificationPermission() }
                    } else {
                        #if canImport(UserNotifications)
                        NotificationManager.shared.cancelAllNotifications()
                        #endif
                    }
                }
                
                if notificationsEnabled {
                    Divider()
                        .padding(.vertical, 4)
                    
                    ModernToggleRow(
                        isOn: $gearReminders,
                        icon: "wrench.fill",
                        iconColor: .cyan,
                        title: "Equipment maintenance",
                        subtitle: "Maintenance reminders"
                    )
                    .onChange(of: gearReminders) {
                        Task { await rescheduleGearNotifications() }
                    }
                    
                    ModernToggleRow(
                        isOn: $certReminders,
                        icon: "rosette",
                        iconColor: .orange,
                        title: "Certification expiration",
                        subtitle: "Renewal reminders"
                    )
                    .onChange(of: certReminders) {
                        Task { await rescheduleCertNotifications() }
                    }
                    
                    ModernToggleRow(
                        isOn: $milestoneNotifs,
                        icon: "star.fill",
                        iconColor: .yellow,
                        title: "Milestones reached",
                        subtitle: "Celebrate your achievements"
                    )
                    
                    #if os(macOS)
                    // On macOS, offer to open system preferences
                    if notificationStatus == .denied {
                        Button {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "gear")
                                    .foregroundStyle(.orange)
                                Text("Open System Preferences")
                                    .font(.subheadline)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.orange.opacity(0.1))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    #endif
                }
                
                // Footer message
                Group {
                    #if os(iOS)
                    if notificationStatus == .denied {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Notifications are disabled in iOS. Enable them in Settings → BlueDive → Notifications.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.orange.opacity(0.1))
                        )
                    } else if notificationsEnabled {
                        Text("Reminders are automatically updated when your data changes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    #elseif os(macOS)
                    if notificationStatus == .denied {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Notifications are disabled. Enable them in System Preferences → Notifications → BlueDive.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.orange.opacity(0.1))
                        )
                    } else if notificationsEnabled {
                        Text("Reminders are automatically updated when your data changes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    #endif
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
            )
            .padding(.horizontal)
        }
    }
    
    
    private var dataManagementSection: some View {
        VStack(spacing: 16) {
            SectionHeaderModern(title: "Data", icon: "folder.fill", color: .indigo)
            
            VStack(spacing: 12) {
                Button {
                    backupDatabase()
                } label: {
                    HStack {
                        ZStack {
                            Circle()
                                .fill(Color.indigo.opacity(0.15))
                                .frame(width: 40, height: 40)
                            
                            Image(systemName: "externaldrive.fill.badge.timemachine")
                                .font(.body)
                                .foregroundStyle(.indigo)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Backup database")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)
                            
                            Text("Export a compressed backup of your database")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(0.03))
                    )
                }
                .buttonStyle(.plain)
                
                #if os(macOS)
                Button {
                    showDatabaseInFinder()
                } label: {
                    HStack {
                        ZStack {
                            Circle()
                                .fill(Color.indigo.opacity(0.15))
                                .frame(width: 40, height: 40)
                            
                            Image(systemName: "folder.fill")
                                .font(.body)
                                .foregroundStyle(.indigo)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Show database in Finder")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)
                            
                            Text("Open the folder containing your database files")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(0.03))
                    )
                }
                .buttonStyle(.plain)
                #endif
            }
            .padding(.horizontal)
            .padding(.vertical)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
            )
            .padding(.horizontal)
        }
    }
    
    // MARK: - iCloud
    
    private var iCloudSection: some View {
        VStack(spacing: 16) {
            SectionHeaderModern(title: "iCloud", icon: "icloud.fill", color: .cyan)
            
            VStack(spacing: 12) {
                // iCloud account status
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(iCloudStatusColor.opacity(0.15))
                            .frame(width: 40, height: 40)
                        
                        Image(systemName: iCloudStatusIcon)
                            .font(.body)
                            .foregroundStyle(iCloudStatusColor)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("iCloud account")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                        
                        Text(iCloudStatusMessage)
                            .font(.caption)
                            .foregroundStyle(iCloudStatusColor)
                    }
                    
                    Spacer()
                    
                    if !iCloudStatusChecked {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.03))
                )
                
                // Sync toggle
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.cyan.opacity(0.15))
                            .frame(width: 40, height: 40)
                        
                        Image(systemName: "arrow.triangle.2.circlepath.icloud.fill")
                            .font(.body)
                            .foregroundStyle(.cyan)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("iCloud sync")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                        
                        Text("Sync dive data across your devices")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $iCloudSyncEnabled)
                        .labelsHidden()
                        .tint(.cyan)
                        .onChange(of: iCloudSyncEnabled) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: BlueDiveApp.iCloudSyncEnabledKey)
                        }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.03))
                )
                
                // Restart notice
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.cyan.opacity(0.7))
                    Text("Changes to iCloud sync take effect after restarting the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                
                // Warning when no account but sync enabled
                if iCloudStatusChecked && iCloudAccountStatus != .available && iCloudSyncEnabled {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("iCloud sync is enabled but no iCloud account is available. Data will be stored locally until you sign in.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.orange.opacity(0.1))
                    )
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
            )
            .padding(.horizontal)
        }
    }
    
    private var iCloudStatusMessage: LocalizedStringKey {
        guard iCloudStatusChecked else { return "Checking..." }
        switch iCloudAccountStatus {
        case .available:            return "Signed in"
        case .noAccount:            return "No account"
        case .restricted:           return "Restricted"
        case .couldNotDetermine:    return "Could not determine"
        case .temporarilyUnavailable: return "Temporarily unavailable"
        @unknown default:           return "Unknown"
        }
    }
    
    private var iCloudStatusIcon: String {
        guard iCloudStatusChecked else { return "icloud" }
        switch iCloudAccountStatus {
        case .available:            return "checkmark.icloud.fill"
        case .noAccount:            return "xmark.icloud.fill"
        case .restricted:           return "lock.icloud.fill"
        case .temporarilyUnavailable: return "exclamationmark.icloud.fill"
        default:                    return "questionmark.icloud.fill"
        }
    }
    
    private var iCloudStatusColor: Color {
        guard iCloudStatusChecked else { return .secondary }
        switch iCloudAccountStatus {
        case .available:            return .green
        case .noAccount:            return .orange
        case .restricted:           return .red
        case .temporarilyUnavailable: return .yellow
        default:                    return .secondary
        }
    }
    
    private func checkiCloudAccountStatus() async {
        do {
            let status = try await CKContainer(identifier: "iCloud.app.bluedive.universal").accountStatus()
            await MainActor.run {
                iCloudAccountStatus = status
                iCloudStatusChecked = true
            }
        } catch {
            await MainActor.run {
                iCloudAccountStatus = .couldNotDetermine
                iCloudStatusChecked = true
            }
        }
    }
    
    // MARK: - Diagnostics
    
    private var diagnosticsSection: some View {
        VStack(spacing: 16) {
            SectionHeaderModern(title: "Diagnostics", icon: "stethoscope", color: .purple)

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.purple.opacity(0.15))
                            .frame(width: 40, height: 40)

                        Image(systemName: "ant.fill")
                            .font(.body)
                            .foregroundStyle(.purple)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Debug mode")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)

                        Text("Verbose BLE and protocol logging for troubleshooting dive computer connection issues")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $isDebugMode)
                        .labelsHidden()
                        .tint(.purple)
                        .onChange(of: isDebugMode) { _, newValue in
                            if newValue {
                                LibDCSwift.Logger.shared.enableDebugMode()
                            } else {
                                LibDCSwift.Logger.shared.disableDebugMode()
                            }
                        }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.03))
                )

                if isDebugMode {
                    Text("Enable this before connecting to a dive computer to capture full protocol traces. Use the export button below to share the log.")
                        .font(.caption)
                        .foregroundStyle(.purple.opacity(0.8))
                        .padding(.horizontal)
                }
                
                // Export diagnostic log button
                Button {
                    let logText = LibDCSwift.Logger.shared.generateDiagnosticLog()
                    if let data = logText.data(using: .utf8) {
                        diagnosticLogDocument = ExportableFileDocument(data: data)
                        showDiagnosticExporter = true
                    }
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.purple.opacity(0.15))
                                .frame(width: 40, height: 40)

                            Image(systemName: "square.and.arrow.up")
                                .font(.body)
                                .foregroundStyle(.purple)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Export Diagnostic Log")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)

                            Text("Share BLE connection log with developer for troubleshooting")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.03))
                )
                
                // Clear log button
                Button {
                    LibDCSwift.Logger.shared.clearLogBuffer()
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.purple.opacity(0.15))
                                .frame(width: 40, height: 40)

                            Image(systemName: "trash")
                                .font(.body)
                                .foregroundStyle(.purple)
                        }

                        Text("Clear Log Buffer")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)

                        Spacer()
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.03))
                )
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                    )
            )
            .padding(.horizontal)
        }
    }
    
    private var dangerZoneSection: some View {
        VStack(spacing: 16) {
            SectionHeaderModern(title: "Data Management", icon: "externaldrive.fill", color: .red)
            
            VStack(spacing: 12) {
                Button(role: .destructive) {
                    showingResetAlert = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.title3)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reset preferences")
                                .font(.subheadline)
                                .fontWeight(.bold)
                            Text("Return to default values")
                                .font(.caption2)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .fontWeight(.bold)
                    }
                    .foregroundStyle(.orange)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.orange.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                
                // Erase All Data button
                Button(role: .destructive) {
                    showingEraseAllDataAlert = true
                } label: {
                    HStack {
                        Image(systemName: "trash.fill")
                            .font(.title3)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Erase all local data")
                                .font(.subheadline)
                                .fontWeight(.bold)
                            Text("Delete local data and resync from iCloud")
                                .font(.caption2)
                        }
                        
                        Spacer()
                        
                        if isErasingData {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .fontWeight(.bold)
                        }
                    }
                    .foregroundStyle(.red)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.red.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.red.opacity(0.3), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(isErasingData)
                
                if let erasePhase {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.red.opacity(0.7))
                        Group {
                            switch erasePhase {
                            case .erasing:
                                Text("Erasing local data…")
                            case .done(let errorCount, let countdown) where errorCount == 0:
                                Text("Local data erased. App will close in \(countdown)s to trigger iCloud sync on relaunch.")
                            case .done(let errorCount, let countdown):
                                Text("Completed with \(errorCount) error(s). App will close in \(countdown)s.")
                            }
                        }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.red.opacity(0.2), lineWidth: 1)
                    )
            )
            .padding(.horizontal)
        }
    }
    
    // MARK: - About Section
    
    private var aboutSection: some View {
        VStack(spacing: 16) {
            SectionHeaderModern(title: "About", icon: "info.circle.fill", color: .cyan)
            
            Button {
                showingAboutSheet = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "water.waves")
                        .font(.title3)
                        .foregroundStyle(.cyan)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("About BlueDive")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundStyle(.primary)
                        Text("Version, contributors & acknowledgements")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)

            Button {
                showDisclaimer = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Disclaimer")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundStyle(.primary)
                        Text("Review the safety disclaimer")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)

            Button {
                showWelcomeWizard = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "hand.wave.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Welcome Tour")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundStyle(.primary)
                        Text("Review the feature walkthrough")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
        .padding(.horizontal)
        .sheet(isPresented: $showingAboutSheet) {
            AboutView()
        }
        .sheet(isPresented: $showDisclaimer) {
            DisclaimerView()
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showWelcomeWizard) {
            WelcomeWizardView()
        }
        #else
        .sheet(isPresented: $showWelcomeWizard) {
            WelcomeWizardView()
        }
        #endif
    }
    
    // MARK: - Notification helpers

    private func requestNotificationPermission() async {
        #if canImport(UserNotifications)
        // Vérifie le statut actuel d'abord
        let currentStatus = await NotificationManager.shared.checkAuthorizationStatus()

        if currentStatus == .authorized || currentStatus == .provisional {
            // Déjà autorisé — configurer sans redemander
            await MainActor.run { NotificationManager.shared.setupNotificationCategories() }
            await checkNotificationStatus()
            await rescheduleAllNotifications()
            return
        }

        if currentStatus == .denied {
            // L'utilisateur a explicitement refusé dans les préférences système
            await MainActor.run { notificationsEnabled = false }
            return
        }

        // .notDetermined → afficher la fenêtre de permission système
        let granted = await NotificationManager.shared.requestAuthorization()

        // Reverify le vrai statut après la demande (plus fiable sur macOS)
        let finalStatus = await NotificationManager.shared.checkAuthorizationStatus()

        await MainActor.run {
            notificationStatus = finalStatus
            if finalStatus == .authorized || finalStatus == .provisional || granted {
                NotificationManager.shared.setupNotificationCategories()
                // On garde notificationsEnabled = true
            } else if finalStatus == .denied {
                notificationsEnabled = false
            }
            // Si toujours .notDetermined, on ne force pas à false — l'utilisateur
            // peut avoir fermé la fenêtre sans choisir, on garde l'intention.
        }

        if finalStatus == .authorized || finalStatus == .provisional || granted {
            await rescheduleAllNotifications()
        }
        #else
        await MainActor.run { notificationsEnabled = false }
        #endif
    }

    @MainActor
    private func checkNotificationStatus() async {
        #if canImport(UserNotifications)
        notificationStatus = await NotificationManager.shared.checkAuthorizationStatus()
        #endif
    }

    @MainActor
    private func rescheduleGearNotifications() async {
        #if canImport(UserNotifications)
        guard gearReminders else { return }
        let allGear = (try? modelContext.fetch(FetchDescriptor<Gear>())) ?? []
        NotificationManager.shared.scheduleGearMaintenanceReminders(for: allGear)
        #endif
    }

    @MainActor
    private func rescheduleCertNotifications() async {
        #if canImport(UserNotifications)
        guard certReminders else { return }
        let allCerts = (try? modelContext.fetch(FetchDescriptor<Certification>())) ?? []
        NotificationManager.shared.scheduleCertificationReminders(for: allCerts)
        #endif
    }

    @MainActor
    private func rescheduleAllNotifications() async {
        await rescheduleGearNotifications()
        await rescheduleCertNotifications()
    }

    // MARK: - iCloud sync



    private func backupDatabase() {
        let fm = FileManager.default

        // Locate the SwiftData store files in Application Support
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }

        let storeURL = appSupport.appendingPathComponent("default.store")
        let shmURL   = appSupport.appendingPathComponent("default.store-shm")
        let walURL   = appSupport.appendingPathComponent("default.store-wal")

        // Collect only existing files
        let filesToBackup = [storeURL, shmURL, walURL].filter { fm.fileExists(atPath: $0.path) }
        guard !filesToBackup.isEmpty else { return }

        // Create a temporary directory and copy the database files into it
        let tempDir = fm.temporaryDirectory.appendingPathComponent("BlueDiveBackup-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            for file in filesToBackup {
                try fm.copyItem(at: file, to: tempDir.appendingPathComponent(file.lastPathComponent))
            }
        } catch {
            return
        }

        // Create a zip archive from the temporary directory
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateSuffix = dateFormatter.string(from: Date())
        let zipName = "BlueDive-Backup-\(dateSuffix).zip"
        let zipURL = fm.temporaryDirectory.appendingPathComponent(zipName)

        // Remove any previous zip with the same name
        try? fm.removeItem(at: zipURL)

        // Use NSFileCoordinator to create a zip via the system
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        var createdZipURL: URL?

        coordinator.coordinate(readingItemAt: tempDir, options: .forUploading, error: &coordError) { zippedURL in
            do {
                try fm.copyItem(at: zippedURL, to: zipURL)
                createdZipURL = zipURL
            } catch {
                // Failed to copy zip
            }
        }

        // Clean up temp directory
        try? fm.removeItem(at: tempDir)

        guard let finalZipURL = createdZipURL else { return }

        // Present Save As panel
        #if os(macOS)
        let savePanel = NSSavePanel()
        savePanel.title = "Save Backup"
        savePanel.nameFieldStringValue = zipName
        savePanel.allowedContentTypes = [.zip]
        savePanel.canCreateDirectories = true

        if savePanel.runModal() == .OK, let destination = savePanel.url {
            try? fm.removeItem(at: destination)
            try? fm.copyItem(at: finalZipURL, to: destination)
        }
        // Clean up temp zip
        try? fm.removeItem(at: finalZipURL)
        #else
        // On iOS, use .fileExporter to present the native save-to-files dialog
        if let data = try? Data(contentsOf: finalZipURL) {
            backupDocument = ExportableFileDocument(data: data)
            backupFileName = zipName
            showBackupExporter = true
        }
        try? fm.removeItem(at: finalZipURL)
        #endif
    }
    
    // MARK: - Erase All Data
    
    private func eraseAllData() {
        guard !isErasingData else { return }
        isErasingData = true
        erasePhase = .erasing
        
        Task {
            var errors: [String] = []
            
            // Step 1: Delete all local SwiftData objects.
            // iCloud data is intentionally preserved so the cloud can
            // replicate everything back down on the next launch.
            await MainActor.run {
                do {
                    try modelContext.delete(model: Dive.self)
                    try modelContext.delete(model: MarineSight.self)
                    try modelContext.delete(model: Gear.self)
                    try modelContext.delete(model: Certification.self)
                    try modelContext.delete(model: DivingInsurance.self)
                    try modelContext.delete(model: TankTemplate.self)
                    try modelContext.delete(model: GearGroup.self)
                    try modelContext.delete(model: DeviceFingerprint.self)
                    try modelContext.save()
                } catch {
                    errors.append("Local data: \(error.localizedDescription)")
                }
            }
            
            // Step 2: Remove all pending and delivered notifications.
            NotificationManager.shared.cancelAllNotifications()
            NotificationManager.shared.clearBadge()
            
            // Step 3: Start a 30-second countdown, then close the app.
            // This gives CloudKit enough time to process the local deletions
            // before the app terminates. On relaunch, the cloud data will
            // replicate back down automatically.
            await MainActor.run {
                erasePhase = .done(errorCount: errors.count, countdown: 30)
            }
            
            // Countdown from 30 to 0
            for remaining in stride(from: 29, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                await MainActor.run {
                    erasePhase = .done(errorCount: errors.count, countdown: remaining)
                }
            }
            
            // Close the app
            await MainActor.run {
                isErasingData = false
                #if os(macOS)
                NSApplication.shared.terminate(nil)
                #else
                exit(0)
                #endif
            }
        }
    }
    
    #if os(macOS)
    private func showDatabaseInFinder() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: appSupport.path)
    }
    #endif
}

// MARK: - Supporting Views

struct SectionHeaderModern: View {
    let title: LocalizedStringKey
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 36, height: 36)
                
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(color)
            }
            
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
            
            Spacer()
        }
        .padding(.horizontal)
    }
}

struct ModernToggleRow: View {
    @Binding var isOn: Bool
    let icon: String
    let iconColor: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(iconColor)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.cyan)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.03))
        )
    }
}

// Extension pour le text field autocapitalization multiplatform
extension View {
    @ViewBuilder
    func platformTextInputAutocapitalization(_ style: PlatformTextInputAutocapitalizationType) -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(style.toSwiftUI)
        #else
        self
        #endif
    }
}

enum PlatformTextInputAutocapitalizationType {
    case capitalizeWords
    case capitalizeSentences
    case never
    
    #if os(iOS)
    var toSwiftUI: TextInputAutocapitalization {
        switch self {
        case .capitalizeWords: return .words
        case .capitalizeSentences: return .sentences
        case .never: return .never
        }
    }
    #endif
}

/// A lightweight FileDocument wrapper for exporting raw data via .fileExporter.
/// Works on both iOS and macOS. The content type is specified at the call site.
struct ExportableFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.zip, .data, .xml, .uddf, .pdf, .plainText] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}


#Preview {
    SettingsView()
}
