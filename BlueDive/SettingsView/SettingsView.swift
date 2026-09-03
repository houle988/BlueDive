import SwiftUI
import UniformTypeIdentifiers
import WidgetKit

// MARK: - Unit formatting helper

private func formatLocalizedUnit(_ value: Double, decimals: Int, symbol: String) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale.current
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = decimals
    formatter.numberStyle = .decimal
    return (formatter.string(from: NSNumber(value: value)) ?? String(value)) + " \(symbol)"
}

// MARK: - Depth Unit

enum DepthUnit: String, CaseIterable {
    case meters = "meters"
    case feet   = "feet"

    /// Canonical metres-to-feet conversion factor. Used in both main app and widget targets.
    static let metersToFeetFactor: Double = 3.28084

    var symbol: String {
        switch self {
        case .meters: return NSLocalizedString("unit.depth.symbol.meters", bundle: .forAppLanguage(), comment: "Depth unit symbol for metres")
        case .feet:   return NSLocalizedString("unit.depth.symbol.feet", bundle: .forAppLanguage(), comment: "Depth unit symbol for feet")
        }
    }

    /// Converts a value stored in metres to the display unit.
    func convert(_ meters: Double) -> Double {
        switch self {
        case .meters: return meters
        case .feet:   return meters * DepthUnit.metersToFeetFactor
        }
    }

    /// Formats a metre value with the correct unit symbol.
    func formatted(_ meters: Double, decimals: Int = 1) -> String {
        formatLocalizedUnit(convert(meters), decimals: decimals, symbol: symbol)
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
        case "bar":          return .bar
        case "psi":          return .psi
        case "pa", "pascal": return .pa
        default:             return .bar  // safe fallback
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
        formatLocalizedUnit(convert(value, from: storedUnit), decimals: decimals, symbol: symbol)
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
        return display.localizedString(decimals: 0) + symbol
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
        case .liters:    return NSLocalizedString("unit.volume.symbol.liters", bundle: .forAppLanguage(), comment: "Volume unit symbol for litres")
        case .cubicFeet: return NSLocalizedString("unit.volume.symbol.cubicFeet", bundle: .forAppLanguage(), comment: "Volume unit symbol for cubic feet")
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
        formatLocalizedUnit(convert(value, from: storedUnit), decimals: decimals, symbol: symbol)
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
    case german = "de"
    case dutch = "nl"

    /// Picker label. Language names are shown as endonyms (each in its own
    /// language) and are intentionally NOT localized — only "System" follows
    /// the in-app language. Rendered with `Text(verbatim:)` so the language
    /// names are never treated as localizable keys.
    var displayName: String {
        switch self {
        case .system:       return NSLocalizedString("System", bundle: .forAppLanguage(), value: "System", comment: "Language picker option that follows the device language")
        case .english:      return "English"
        case .frenchCanada: return "Français"
        case .german:       return "Deutsch"
        case .dutch:        return "Nederlands"
        }
    }

    var locale: Locale? {
        switch self {
        case .system: return nil
        case .english: return Locale(identifier: "en_CA")
        case .frenchCanada: return Locale(identifier: "fr-CA")
        case .german: return Locale(identifier: "de")
        case .dutch: return Locale(identifier: "nl")
        }
    }
}

// MARK: - User Preferences

@Observable
class UserPreferences {

    static let shared = UserPreferences()

    var depthUnit: DepthUnit {
        didSet {
            UserDefaults.standard.set(depthUnit.rawValue, forKey: "depthUnit")
            // Write the widget-facing key so the widget reflects the correct unit
            // even before ContentView.updateWidgetDiveData() runs.
            UserDefaults(suiteName: "group.app.bluedive.universal")?
                .set(depthUnit == .feet ? "feet" : "meters", forKey: "depthUnit")
            WidgetCenter.shared.reloadTimelines(ofKind: "DiverStatsWidget")
        }
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
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode")
            UserDefaults(suiteName: "group.app.bluedive.universal")?.set(appearanceMode.rawValue, forKey: "appearanceMode")
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    var languageMode: AppLanguage {
        didSet {
            UserDefaults.standard.set(languageMode.rawValue, forKey: "languageMode")
            UserDefaults(suiteName: "group.app.bluedive.universal")?.set(languageMode.rawValue, forKey: "languageMode")
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    init() {
        self.depthUnit        = DepthUnit(rawValue: UserDefaults.standard.string(forKey: "depthUnit") ?? "meters") ?? .meters
        self.pressureUnit     = PressureUnit(rawValue: UserDefaults.standard.string(forKey: "pressureUnit") ?? "bar") ?? .bar
        self.temperatureUnit  = TemperatureUnit(rawValue: UserDefaults.standard.string(forKey: "temperatureUnit") ?? "celsius") ?? .celsius
        self.volumeUnit       = VolumeUnit(rawValue: UserDefaults.standard.string(forKey: "volumeUnit") ?? "liters") ?? .liters
        self.weightUnit       = WeightUnit(rawValue: UserDefaults.standard.string(forKey: "weightUnit") ?? "kilograms") ?? .kilograms
        self.appearanceMode   = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearanceMode") ?? "system") ?? .system
        self.languageMode     = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "languageMode") ?? "system") ?? .system
        // Seed shared container after self is fully initialised (required by @Observable)
        let shared = UserDefaults(suiteName: "group.app.bluedive.universal")
        shared?.set(self.appearanceMode.rawValue, forKey: "appearanceMode")
        shared?.set(self.languageMode.rawValue, forKey: "languageMode")
        shared?.set(self.depthUnit == .feet ? "feet" : "meters", forKey: "depthUnit")
    }

    func resetToDefaults() {
        depthUnit       = .meters
        pressureUnit    = .bar
        temperatureUnit = .celsius
        volumeUnit      = .liters
        weightUnit      = .kilograms
        appearanceMode  = .system
        languageMode    = .system
        ChartLineVisibility().save()
        UserDefaults.standard.removeObject(forKey: DiverFilter.storageKey)
        UserDefaults.standard.set(false, forKey: "filterUnusedTanks")
        UserDefaults.standard.set(false, forKey: "autoSequenceEnabled")
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var prefs = UserPreferences.shared
    @State private var showingAboutSheet = false
    @State private var showWelcomeWizard = false
    @State private var showDisclaimer = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        AppearanceSettingsView(onNeedsRootDismiss: { dismiss() })
                    } label: {
                        SettingsListRow(title: "Appearance", icon: "paintbrush.fill", color: .pink)
                    }

                    NavigationLink {
                        UnitsSettingsView()
                    } label: {
                        SettingsListRow(
                            title: "Units of Measure",
                            icon: "ruler",
                            color: .orange,
                            detail: "\(prefs.depthUnit.symbol) · \(prefs.pressureUnit.symbol) · \(prefs.temperatureUnit.symbol)"
                        )
                    }

                    NavigationLink {
                        BluetoothSettingsView()
                    } label: {
                        SettingsListRow(title: "Bluetooth Import", icon: "antenna.radiowaves.left.and.right", color: .blue)
                    }

                    NavigationLink {
                        NotificationsSettingsView()
                    } label: {
                        SettingsListRow(title: "Notifications", icon: "bell.fill", color: .purple)
                    }

                    NavigationLink {
                        DiveSequenceSettingsView()
                    } label: {
                        SettingsListRow(title: "Dive Sequence", icon: "arrow.triangle.2.circlepath", color: .indigo)
                    }

                    NavigationLink {
                        ICloudSettingsView()
                    } label: {
                        SettingsListRow(title: "iCloud", icon: "icloud.fill", color: .cyan)
                    }

                    NavigationLink {
                        DataManagementSettingsView()
                    } label: {
                        SettingsListRow(title: "Data Management", icon: "externaldrive.fill", color: .red)
                    }
                }

                Section("About") {
                    Button { showingAboutSheet = true } label: {
                        SettingsListRow(title: "About BlueDive", icon: "water.waves", color: .cyan)
                    }
                    .foregroundStyle(.primary)

                    Button { showDisclaimer = true } label: {
                        SettingsListRow(title: "Disclaimer", icon: "exclamationmark.triangle.fill", color: .orange)
                    }
                    .foregroundStyle(.primary)

                    Button { showWelcomeWizard = true } label: {
                        SettingsListRow(title: "Welcome Tour", icon: "hand.wave.fill", color: .orange)
                    }
                    .foregroundStyle(.primary)

                    Button {
                        dismiss()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(400))
                            UserDefaults.standard.set(DiveIntroConfig.replayValue, forKey: DiveIntroConfig.versionStorageKey)
                        }
                    } label: {
                        SettingsListRow(title: "Intro Animation", icon: "play.circle.fill", color: .teal)
                    }
                    .foregroundStyle(.primary)
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            #if os(macOS)
            .frame(minWidth: 400, idealWidth: 480, maxWidth: 600, minHeight: 500, idealHeight: 580, maxHeight: 780)
            #endif
            .preferredColorScheme(prefs.appearanceMode.colorScheme)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.cyan)
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
            .sheet(isPresented: $showingAboutSheet) {
                AboutView()
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showDisclaimer) {
                DisclaimerView()
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showWelcomeWizard) {
                WelcomeWizardView()
            }
            #else
            .sheet(isPresented: $showWelcomeWizard) {
                WelcomeWizardView()
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            #endif
        }
    }
}

// MARK: - Settings List Row

struct SettingsListRow: View {
    let title: LocalizedStringKey
    let icon: String
    let color: Color
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.2))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
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
    static var writableContentTypes: [UTType] { [.zip, .data, .xml, .uddf, .pdf, .plainText, .blueDiveXML] }

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
