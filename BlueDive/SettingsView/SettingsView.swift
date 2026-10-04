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

    /// Same text as `label`, as a `String` for places that build text, such as the
    /// Settings row detail.
    var displayName: String {
        switch self {
        case .system: return NSLocalizedString("System", bundle: .forAppLanguage(), value: "System", comment: "Theme option that follows the device appearance")
        case .light:  return NSLocalizedString("Light", bundle: .forAppLanguage(), value: "Light", comment: "Theme option: always light")
        case .dark:   return NSLocalizedString("Dark", bundle: .forAppLanguage(), value: "Dark", comment: "Theme option: always dark")
        }
    }

    /// The theme actually shown: for System, Light or Dark according to `colorScheme`,
    /// the scheme currently in effect (pass the view's `@Environment(\.colorScheme)`).
    func effective(in colorScheme: ColorScheme) -> AppearanceMode {
        guard self == .system else { return self }
        return colorScheme == .dark ? .dark : .light
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

    /// The language the app actually shows: for System, the localization the system chose
    /// from the device's languages (or BlueDive's per-app language setting); English when
    /// none of them is available in BlueDive. Matches by language code only, which assumes
    /// one case per language; compare full identifiers if a second regional variant is added.
    var effective: AppLanguage {
        guard self == .system else { return self }
        let resolved = Bundle.main.preferredLocalizations.first.map { Locale(identifier: $0).language.languageCode }
        return AppLanguage.allCases.first { language in
            language != .system && Locale(identifier: language.rawValue).language.languageCode == resolved
        } ?? .english
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
            // even before DiveStore.updateWidgetDiveData(dives:) runs.
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
    /// When true, the dive profile chart and the PDF logbook omit mandatory-deco-stop
    /// markers whose obligation had already cleared before the diver reached that depth.
    /// Deliberately no App Group write and no widget reload: the shared container carries
    /// only depthUnit/appearanceMode/languageMode, and the widget renders no chart.
    var hideClearedDecoStops: Bool {
        didSet { UserDefaults.standard.set(hideClearedDecoStops, forKey: "hideClearedDecoStops") }
    }
    /// When true, the dive detail view shows the Samples tab (raw dive computer data).
    /// Off by default: the tab is a diagnostic view and a long table is slow to render.
    /// No App Group write: the widget does not show dive detail tabs.
    var showSamplesTab: Bool {
        didSet { UserDefaults.standard.set(showSamplesTab, forKey: "showSamplesTab") }
    }
    /// When true, Edit Conditions offers a Fetch Weather button, and the automatic fetch after
    /// a Bluetooth download (`fetchWeatherOnBluetoothImport`) may run; both send the dive's GPS
    /// coordinates and date to Open-Meteo. Off by default: nothing leaves the device unless
    /// the user opts in. No App Group write: the widget shows no weather.
    var fetchWeatherOnline: Bool {
        didSet {
            UserDefaults.standard.set(fetchWeatherOnline, forKey: "fetchWeatherOnline")
            // Turning it on anywhere answers the one-time launch question, so turning it off
            // later (or Reset to Defaults) does not bring that question back.
            if fetchWeatherOnline { UserDefaults.standard.set(true, forKey: "onlineServicesPromptShown") }
        }
    }
    /// Bluetooth import: fetch the weather for downloaded dives that have GPS coordinates.
    /// Effective only while `fetchWeatherOnline` is on. On by default.
    var fetchWeatherOnBluetoothImport: Bool {
        didSet { UserDefaults.standard.set(fetchWeatherOnBluetoothImport, forKey: "fetchWeatherOnBluetoothImport") }
    }
    /// Bluetooth import: for newly downloaded dives, fetched values replace existing ones (on)
    /// or fill only empty fields (off). Dives downloaded again (merged into the logbook) are
    /// always fill-only, whatever this is. On by default.
    var replaceWeatherOnBluetoothImport: Bool {
        didSet { UserDefaults.standard.set(replaceWeatherOnBluetoothImport, forKey: "replaceWeatherOnBluetoothImport") }
    }
    #if os(macOS)
    /// When true, the main dive list shows the profile chart of the selected dive above the
    /// list; a click selects a dive and a double-click (or Return) opens it. When false, the
    /// list has no chart and a click opens the dive. On by default.
    /// No App Group write: the widget does not show the dive list.
    var showDiveListProfilePreview: Bool {
        didSet { UserDefaults.standard.set(showDiveListProfilePreview, forKey: "showDiveListProfilePreview") }
    }
    #endif

    init() {
        self.depthUnit        = DepthUnit(rawValue: UserDefaults.standard.string(forKey: "depthUnit") ?? "meters") ?? .meters
        self.pressureUnit     = PressureUnit(rawValue: UserDefaults.standard.string(forKey: "pressureUnit") ?? "bar") ?? .bar
        self.temperatureUnit  = TemperatureUnit(rawValue: UserDefaults.standard.string(forKey: "temperatureUnit") ?? "celsius") ?? .celsius
        self.volumeUnit       = VolumeUnit(rawValue: UserDefaults.standard.string(forKey: "volumeUnit") ?? "liters") ?? .liters
        self.weightUnit       = WeightUnit(rawValue: UserDefaults.standard.string(forKey: "weightUnit") ?? "kilograms") ?? .kilograms
        self.appearanceMode   = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearanceMode") ?? "system") ?? .system
        self.languageMode     = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "languageMode") ?? "system") ?? .system
        // bool(forKey:) returns false when the key is absent, which is exactly the required
        // OFF default — no registerDefaults entry needed.
        self.hideClearedDecoStops = UserDefaults.standard.bool(forKey: "hideClearedDecoStops")
        self.showSamplesTab = UserDefaults.standard.bool(forKey: "showSamplesTab")
        self.fetchWeatherOnline = UserDefaults.standard.bool(forKey: "fetchWeatherOnline")
        // On by default: an absent key reads as true.
        self.fetchWeatherOnBluetoothImport = UserDefaults.standard.object(forKey: "fetchWeatherOnBluetoothImport") as? Bool ?? true
        self.replaceWeatherOnBluetoothImport = UserDefaults.standard.object(forKey: "replaceWeatherOnBluetoothImport") as? Bool ?? true
        #if os(macOS)
        // On by default: an absent key reads as true.
        self.showDiveListProfilePreview = UserDefaults.standard.object(forKey: "showDiveListProfilePreview") as? Bool ?? true
        #endif
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
        hideClearedDecoStops = false
        showSamplesTab = false
        fetchWeatherOnline = false
        fetchWeatherOnBluetoothImport = true
        replaceWeatherOnBluetoothImport = true
        #if os(macOS)
        showDiveListProfilePreview = true
        #endif
        SharedChartLineVisibility.shared.value = ChartLineVisibility()
        ChartLineVisibility().save()
        UserDefaults.standard.removeObject(forKey: DiverFilter.storageKey)
        UserDefaults.standard.set(false, forKey: "filterUnusedTanks")
        UserDefaults.standard.set(false, forKey: "autoSequenceEnabled")
        DiveSortOrder.resetPersisted()
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var prefs = UserPreferences.shared
    @State private var showingAboutSheet = false
    @State private var showWelcomeWizard = false
    @State private var showDisclaimer = false

    var body: some View {
        NavigationStack {
            groupedList {
                Section {
                    NavigationLink {
                        AppearanceSettingsView(onNeedsRootDismiss: { dismiss() })
                            .closeSheetButtonOnMac { dismiss() }
                    } label: {
                        // The detail shows the language in use, written in its own language
                        // (e.g. "Deutsch"), so the row is recognisable to someone who does not
                        // read the app's current language, followed by the theme in use. For
                        // System, both show what the device resolves to rather than "System".
                        SettingsListRow(
                            title: "Appearance & Language",
                            icon: "paintbrush",
                            color: .pink,
                            detail: "\(prefs.languageMode.effective.displayName) · \(prefs.appearanceMode.effective(in: colorScheme).displayName)"
                        )
                    }

                    NavigationLink {
                        UnitsSettingsView()
                            .closeSheetButtonOnMac { dismiss() }
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
                            .closeSheetButtonOnMac { dismiss() }
                    } label: {
                        SettingsListRow(title: "Bluetooth Import", icon: "antenna.radiowaves.left.and.right", color: .blue)
                    }

                    NavigationLink {
                        NotificationsSettingsView()
                            .closeSheetButtonOnMac { dismiss() }
                    } label: {
                        SettingsListRow(title: "Notifications", icon: "bell", color: .purple)
                    }

                    NavigationLink {
                        DiveSequenceSettingsView()
                            .closeSheetButtonOnMac { dismiss() }
                    } label: {
                        SettingsListRow(title: "Dive Sequence", icon: "arrow.triangle.2.circlepath", color: .indigo)
                    }

                    NavigationLink {
                        DiveProfileSettingsView()
                            .closeSheetButtonOnMac { dismiss() }
                    } label: {
                        SettingsListRow(title: "Dive Profile", icon: "chart.xyaxis.line", color: .green)
                    }

                    NavigationLink {
                        ICloudSettingsView()
                            .closeSheetButtonOnMac { dismiss() }
                    } label: {
                        SettingsListRow(title: "iCloud", icon: "icloud", color: .cyan)
                    }

                    NavigationLink {
                        OnlineServicesSettingsView()
                            .closeSheetButtonOnMac { dismiss() }
                    } label: {
                        SettingsListRow(title: "Online Services", icon: "globe", color: .mint)
                    }

                    NavigationLink {
                        DataManagementSettingsView()
                            .closeSheetButtonOnMac { dismiss() }
                    } label: {
                        SettingsListRow(title: "Data Management", icon: "externaldrive", color: .red)
                    }
                }

                Section("About") {
                    Button { showingAboutSheet = true } label: {
                        SettingsListRow(title: "About BlueDive", icon: "water.waves", color: .cyan)
                    }
                    .foregroundStyle(.primary)
                    .listRowButton()

                    Button { showDisclaimer = true } label: {
                        SettingsListRow(title: "Disclaimer", icon: "exclamationmark.triangle", color: .orange)
                    }
                    .foregroundStyle(.primary)
                    .listRowButton()

                    Button { showWelcomeWizard = true } label: {
                        SettingsListRow(title: "Welcome Tour", icon: "hand.wave", color: .orange)
                    }
                    .foregroundStyle(.primary)
                    .listRowButton()

                    Button {
                        dismiss()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(400))
                            UserDefaults.standard.set(DiveIntroConfig.replayValue, forKey: DiveIntroConfig.versionStorageKey)
                        }
                    } label: {
                        SettingsListRow(title: "Intro Animation", icon: "play.circle", color: .teal)
                    }
                    .foregroundStyle(.primary)
                    .listRowButton()
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .preferredColorScheme(prefs.appearanceMode.colorScheme)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
            .sheet(isPresented: $showingAboutSheet) {
                AboutView()
                    .standardSheetPresentation()
            }
            .sheet(isPresented: $showDisclaimer) {
                DisclaimerView(isReview: true)
                    .standardSheetPresentation()
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showWelcomeWizard) {
                WelcomeWizardView()
            }
            #else
            .sheet(isPresented: $showWelcomeWizard) {
                WelcomeWizardView()
                    .standardSheetPresentation()
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
                    .accessibilityHidden(true)
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
                    .accessibilityHidden(true)
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
                    .accessibilityHidden(true)
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

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .fullWidthSwitch()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.03))
        )
    }
}

/// The vertical blue gradient background shared across the Settings sub-views,
/// matching the Sync Fingerprints screen. The `platformBackground` endpoints keep
/// it seamless in both light and dark mode. The middle tint uses a stronger blue
/// in light mode (where 5% over white is nearly invisible) and the original subtle
/// value in dark mode.
private struct SettingsGradientBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background(
            LinearGradient(
                colors: [
                    Color.platformBackground,
                    Color.blue.opacity(colorScheme == .dark ? 0.05 : 0.10),
                    Color.platformBackground
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }
}

extension View {
    /// Applies the subtle vertical blue gradient background used across the
    /// Settings sub-views, matching the Sync Fingerprints screen.
    func settingsGradientBackground() -> some View {
        modifier(SettingsGradientBackground())
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
        .environment(DiveStore())
}
