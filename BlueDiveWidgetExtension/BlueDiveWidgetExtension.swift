import WidgetKit
import SwiftUI
import AppIntents
import os

// MARK: - Deep-link URLs

/// URL scheme + hosts must match the handler in `BlueDiveApp` / `MainTabView`.
/// Keep these in sync with `Info.plist` (CFBundleURLSchemes = "bluedive").
private enum AddDiveDeepLink {
    static let manual    = URL(string: "bluedive://add/manual")!
    static let bluetooth = URL(string: "bluedive://add/bluetooth")!
}

// MARK: - Shared App Group key

private let appGroupSuite = "group.app.bluedive.universal"

// MARK: - Timeline Entry

// Shared by ManualDive, BluetoothDive (action widgets) and DiveCount.
// diveCount / diverLabel are unused by the action widgets but kept here to
// avoid a separate entry type for a small difference.
struct AddDiveEntry: TimelineEntry {
    let date: Date
    let locale: Locale
    let colorScheme: ColorScheme?   // nil = follow system
    let diveCount: Int
    let diverLabel: String?         // nil = total (all divers)
}

// MARK: - Static Timeline Provider (action widgets + default count)

struct AddDiveProvider: TimelineProvider {

    static func currentLocale() -> Locale {
        let raw = UserDefaults(suiteName: appGroupSuite)?.string(forKey: "languageMode") ?? "system"
        switch raw {
        case "en":    return Locale(identifier: "en_CA")
        case "fr-CA": return Locale(identifier: "fr-CA")
        default:      return .autoupdatingCurrent
        }
    }

    static func currentColorScheme() -> ColorScheme? {
        let raw = UserDefaults(suiteName: appGroupSuite)?.string(forKey: "appearanceMode") ?? "system"
        switch raw {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    static func makeEntry() -> AddDiveEntry {
        AddDiveEntry(date: .now,
                     locale: currentLocale(),
                     colorScheme: currentColorScheme(),
                     diveCount: 0,
                     diverLabel: nil)
    }

    func placeholder(in context: Context) -> AddDiveEntry { Self.makeEntry() }
    func getSnapshot(in context: Context, completion: @escaping (AddDiveEntry) -> Void) { completion(Self.makeEntry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<AddDiveEntry>) -> Void) {
        completion(Timeline(entries: [Self.makeEntry()], policy: .never))
    }
}

// MARK: - Diver App Entity (for widget configuration)

/// Sentinel ID used for the "All Divers" option in the picker.
private let allDiversID = "__all__"

struct DiverEntity: AppEntity {
    var id: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Diver"
    var displayRepresentation: DisplayRepresentation {
        id == allDiversID
            ? DisplayRepresentation(title: "All Divers")
            : DisplayRepresentation(title: "\(id)")
    }
    static var defaultQuery = DiverEntityQuery()
}

struct DiverEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [DiverEntity] {
        // Only return entities that currently exist in the app group.
        // Returning nil for a missing identifier signals WidgetKit that the
        // configuration is stale; it falls back to defaultResult() (All Divers).
        let knownNames: Set<String>
        if let data = UserDefaults(suiteName: appGroupSuite)?.data(forKey: "diverNames"),
           let names = try? JSONDecoder().decode([String].self, from: data) {
            knownNames = Set(names)
        } else {
            knownNames = []
        }
        return identifiers.compactMap { id in
            guard id == allDiversID || knownNames.contains(id) else { return nil }
            return DiverEntity(id: id)
        }
    }

    func defaultResult() async -> DiverEntity? {
        DiverEntity(id: allDiversID)
    }

    func suggestedEntities() async throws -> [DiverEntity] {
        var entities: [DiverEntity] = [DiverEntity(id: allDiversID)]
        if let data = UserDefaults(suiteName: appGroupSuite)?.data(forKey: "diverNames"),
           let names = try? JSONDecoder().decode([String].self, from: data) {
            entities += names.map { DiverEntity(id: $0) }
        }
        return entities
    }
}

// MARK: - Widget Configuration Intent

struct DiveCountWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Dive Count"
    static var description = IntentDescription("Filter by diver name.")

    @Parameter(title: "Diver")
    var diver: DiverEntity?
}

// MARK: - AppIntent Timeline Provider (configurable count widget)

struct DiveCountProvider: AppIntentTimelineProvider {
    typealias Intent = DiveCountWidgetIntent
    typealias Entry  = AddDiveEntry

    func placeholder(in context: Context) -> AddDiveEntry {
        AddDiveEntry(date: .now,
                     locale: AddDiveProvider.currentLocale(),
                     colorScheme: AddDiveProvider.currentColorScheme(),
                     diveCount: 0,
                     diverLabel: nil)
    }

    func snapshot(for configuration: DiveCountWidgetIntent, in context: Context) async -> AddDiveEntry {
        makeEntry(for: configuration)
    }

    func timeline(for configuration: DiveCountWidgetIntent, in context: Context) async -> Timeline<AddDiveEntry> {
        let entry = makeEntry(for: configuration)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let nextMidnight = cal.nextDate(after: entry.date,
                                        matching: DateComponents(hour: 0, minute: 0, second: 0),
                                        matchingPolicy: .nextTime)
            ?? cal.date(byAdding: .day, value: 1, to: entry.date)
            ?? entry.date.addingTimeInterval(86400)
        return Timeline(entries: [entry], policy: .after(nextMidnight))
    }

    private func makeEntry(for configuration: DiveCountWidgetIntent) -> AddDiveEntry {
        let shared = UserDefaults(suiteName: appGroupSuite)
        let count: Int
        let diverLabel: String?

        if let diver = configuration.diver, diver.id != allDiversID {
            diverLabel = diver.id
            if let data = shared?.data(forKey: "diveCountByDiver"),
               let counts = try? JSONDecoder().decode([String: Int].self, from: data) {
                count = counts[diver.id] ?? 0
            } else {
                count = 0
            }
        } else {
            count = shared?.integer(forKey: "totalDiveCount") ?? 0
            diverLabel = nil
        }

        return AddDiveEntry(date: .now,
                            locale: AddDiveProvider.currentLocale(),
                            colorScheme: AddDiveProvider.currentColorScheme(),
                            diveCount: count,
                            diverLabel: diverLabel)
    }
}

// MARK: - Shared appearance helpers

private protocol WidgetColorSchemeEntry {
    var colorScheme: ColorScheme? { get }
}

private extension WidgetColorSchemeEntry {
    func isDark(system: ColorScheme) -> Bool {
        switch colorScheme {
        case .dark:       return true
        case .light:      return false
        case nil:         return system == .dark
        @unknown default: return system == .dark
        }
    }
}

extension AddDiveEntry: WidgetColorSchemeEntry {}
extension DiverStatsEntry: WidgetColorSchemeEntry {}

// MARK: - Shared background

private struct BlueDiveWidgetBackground: View {
    let isDark: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: isDark
                    ? [Color(red: 0.01, green: 0.06, blue: 0.14),
                       Color(red: 0.03, green: 0.14, blue: 0.28),
                       Color(red: 0.05, green: 0.22, blue: 0.40)]
                    : [Color(red: 0.78, green: 0.92, blue: 1.00),
                       Color(red: 0.55, green: 0.80, blue: 0.96),
                       Color(red: 0.32, green: 0.65, blue: 0.88)],
                startPoint: .top,
                endPoint: .bottom
            )

            GeometryReader { geo in
                ZStack {
                    LinearGradient(
                        colors: [Color.white.opacity(isDark ? 0.06 : 0.20), .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                    .blur(radius: 12)
                    .frame(height: geo.size.height * 0.55)
                    .position(x: geo.size.width * 0.18, y: geo.size.height * 0.28)

                    Circle()
                        .stroke(Color.white.opacity(isDark ? 0.22 : 0.55), lineWidth: 1.2)
                        .frame(width: 6, height: 6)
                        .position(x: geo.size.width * 0.88, y: geo.size.height * 0.22)
                    Circle()
                        .stroke(Color.white.opacity(isDark ? 0.18 : 0.50), lineWidth: 1)
                        .frame(width: 4, height: 4)
                        .position(x: geo.size.width * 0.92, y: geo.size.height * 0.40)
                    Circle()
                        .stroke(Color.white.opacity(isDark ? 0.20 : 0.55), lineWidth: 1)
                        .frame(width: 8, height: 8)
                        .position(x: geo.size.width * 0.82, y: geo.size.height * 0.58)
                    Circle()
                        .stroke(Color.white.opacity(isDark ? 0.15 : 0.45), lineWidth: 1)
                        .frame(width: 5, height: 5)
                        .position(x: geo.size.width * 0.95, y: geo.size.height * 0.72)
                    Circle()
                        .stroke(Color.white.opacity(isDark ? 0.18 : 0.50), lineWidth: 1)
                        .frame(width: 3, height: 3)
                        .position(x: geo.size.width * 0.86, y: geo.size.height * 0.84)
                }
            }
        }
    }
}

// MARK: - Locale bundle lookup

private extension Bundle {
    /// Returns the lproj bundle for `locale`, falling back to `.main`.
    /// When `languageMode` is "system" this returns `.main` directly so that
    /// NSLocalizedString's standard preferred-language algorithm is used —
    /// mirroring the `Bundle.forAppLanguage()` pattern in the app target.
    static func forWidgetLocale(_ locale: Locale) -> Bundle {
        let raw = UserDefaults(suiteName: appGroupSuite)?.string(forKey: "languageMode") ?? "system"
        guard raw != "system" else { return .main }
        let identifier = locale.identifier
        // Try both the underscore form ("en_CA") and the hyphenated BCP-47 form
        // ("en-CA") because Xcode emits .lproj folders with hyphens but
        // Locale.identifier uses underscores.
        let hyphenated = identifier.replacingOccurrences(of: "_", with: "-")
        for name in [identifier, hyphenated] {
            if let path = Bundle.main.path(forResource: name, ofType: "lproj"),
               let bundle = Bundle(path: path) { return bundle }
        }
        if let code = locale.language.languageCode?.identifier,
           let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) { return bundle }
        // Base.lproj holds the source-language (English) strings. Use it when
        // the user selected English but no en.lproj was generated by Xcode.
        if let path = Bundle.main.path(forResource: "Base", ofType: "lproj"),
           let bundle = Bundle(path: path) { return bundle }
        return .main
    }
}

// MARK: - Shared colour palette

private struct WidgetPalette {
    let isDark: Bool
    var accent: Color    { isDark ? Color(red: 0.55, green: 0.88, blue: 1.0) : Color(red: 0.0, green: 0.42, blue: 0.72) }
    var primary: Color   { isDark ? .white : Color(red: 0.04, green: 0.12, blue: 0.24) }
    var secondary: Color { isDark ? .white.opacity(0.70) : Color(red: 0.04, green: 0.12, blue: 0.24).opacity(0.62) }
    var header: Color    { isDark ? .white.opacity(0.92) : Color(red: 0.04, green: 0.12, blue: 0.24).opacity(0.85) }
    var divider: Color   { isDark ? .white.opacity(0.22) : Color(red: 0.04, green: 0.12, blue: 0.24).opacity(0.18) }
    var pillBg: Color    { isDark ? Color.white.opacity(0.08) : Color.white.opacity(0.45) }
    var pillBorder: Color { isDark ? Color.white.opacity(0.12) : Color.white.opacity(0.65) }
}

// MARK: - Shared widget header

private struct BlueDiveWidgetHeader: View {
    let palette: WidgetPalette

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(palette.accent.opacity(palette.isDark ? 0.22 : 0.18))
                    .frame(width: 22, height: 22)
                Image(systemName: "water.waves")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(palette.accent)
            }
            Text("BlueDive")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.header)
                .tracking(0.4)
            Spacer()
        }
    }
}

// MARK: - Focused Small View (action widgets)

struct FocusedSmallWidgetView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    var entry: AddDiveEntry
    let systemImage: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let tint: Color
    let url: URL

    private var isDark: Bool { entry.isDark(system: systemColorScheme) }
    private var palette: WidgetPalette { WidgetPalette(isDark: isDark) }

    var body: some View {
        VStack(spacing: 6) {
            BlueDiveWidgetHeader(palette: palette)
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(tint)
            Text(title).font(.subheadline).bold().foregroundStyle(palette.primary)
            Text(subtitle).font(.caption2).foregroundStyle(palette.secondary).multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.locale, entry.locale)
        .widgetURL(url)
        .containerBackground(for: .widget) { BlueDiveWidgetBackground(isDark: isDark) }
        .preferredColorScheme(entry.colorScheme)
    }
}

// MARK: - Dive Count Small View

struct DiveCountWidgetView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    var entry: AddDiveEntry

    private var isDark: Bool { entry.isDark(system: systemColorScheme) }
    private var palette: WidgetPalette { WidgetPalette(isDark: isDark) }

    private var formattedDiveCount: String {
        let nf = NumberFormatter()
        nf.locale = entry.locale
        nf.numberStyle = .decimal
        let count = max(0, entry.diveCount)
        return nf.string(from: NSNumber(value: count)) ?? "\(count)"
    }

    var body: some View {
        VStack(spacing: 4) {
            BlueDiveWidgetHeader(palette: palette)
            Spacer()
            Text(verbatim: formattedDiveCount)
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .foregroundStyle(palette.accent)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            if let label = entry.diverLabel {
                Text(verbatim: label)
                    .font(.caption2)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("Total Dives")
                    .font(.caption2)
                    .foregroundStyle(palette.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.locale, entry.locale)
        .containerBackground(for: .widget) { BlueDiveWidgetBackground(isDark: isDark) }
        .preferredColorScheme(entry.colorScheme)
    }
}

// MARK: - Widget definitions

struct ManualDiveWidget: Widget {
    let kind = "ManualDiveWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AddDiveProvider()) { entry in
            FocusedSmallWidgetView(
                entry: entry,
                systemImage: "plus.circle.fill",
                title: "Manual",
                subtitle: "Log by hand",
                tint: .cyan,
                url: AddDiveDeepLink.manual)
        }
        .configurationDisplayName("Manual Dive")
        .description("Quickly log a new dive by hand.")
        .supportedFamilies([.systemSmall])
    }
}

struct BluetoothDiveWidget: Widget {
    let kind = "BluetoothDiveWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AddDiveProvider()) { entry in
            FocusedSmallWidgetView(
                entry: entry,
                systemImage: "antenna.radiowaves.left.and.right",
                title: "Bluetooth",
                subtitle: "From dive computer",
                tint: .blue,
                url: AddDiveDeepLink.bluetooth)
        }
        .configurationDisplayName("Bluetooth Dive")
        .description("Import a dive from your dive computer via Bluetooth.")
        .supportedFamilies([.systemSmall])
    }
}

struct DiveCountWidget: Widget {
    let kind = "DiveCountWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: DiveCountWidgetIntent.self, provider: DiveCountProvider()) { entry in
            DiveCountWidgetView(entry: entry)
        }
        .configurationDisplayName("Dive Count")
        .description("See your total number of logged dives at a glance.")
        .supportedFamilies([.systemSmall])
    }
}

// Mirrors DepthUnit.metersToFeetFactor in the main app target (widget can't import main target).
private let metersToFeet: Double = 3.28084

// MARK: - Diver Stats Timeline Entry

struct DiverStatsEntry: TimelineEntry {
    let date: Date
    let locale: Locale
    let colorScheme: ColorScheme?
    let diverName: String
    let isAllDivers: Bool
    let diveCount: Int
    let totalMinutes: Int
    let maxDepthMeters: Double
    let longestDiveMinutes: Int
    let mostRecentDiveDate: Date?
    let depthUnit: String
}

private extension DiverStatsEntry {
    var depthSymbol: String { depthUnit == "feet" ? "ft" : "m" }

    func convertDepth(_ meters: Double) -> Double {
        depthUnit == "feet" ? meters * metersToFeet : meters
    }
}

// MARK: - Diver Stats Configuration Intent

struct DiverStatsWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Diver Stats"
    static var description = IntentDescription("Choose which diver's stats to display.")

    @Parameter(title: "Diver")
    var diver: DiverEntity?
}

// MARK: - Diver Stats Provider

struct DiverStatsProvider: AppIntentTimelineProvider {
    typealias Intent = DiverStatsWidgetIntent
    typealias Entry = DiverStatsEntry

    private static let logger = Logger(subsystem: "app.bluedive.widget", category: "WidgetData")

    private static func decodeDict<T: Decodable>(_ shared: UserDefaults?, forKey key: String, type: T.Type) -> [String: T] {
        guard let data = shared?.data(forKey: key) else { return [:] }
        if let dict = try? JSONDecoder().decode([String: T].self, from: data) {
            return dict
        }
        logger.error("BlueDiveWidget: failed to decode [\(String(describing: T.self))] for key '\(key)'")
        return [:]
    }

    static func makeEntry(for configuration: DiverStatsWidgetIntent?) -> DiverStatsEntry {
        let shared = UserDefaults(suiteName: appGroupSuite)
        let depthUnit = shared?.string(forKey: "depthUnit") ?? "meters"
        let locale = AddDiveProvider.currentLocale()
        let colorScheme = AddDiveProvider.currentColorScheme()

        if let diver = configuration?.diver, diver.id != allDiversID {
            let name = diver.id
            // If the diver no longer exists (e.g. after erasing all data), fall through to
            // All Divers so the widget resets cleanly instead of showing a named diver with
            // all "—" stats.
            let knownNames: [String]
            if let data = shared?.data(forKey: "diverNames"),
               let names = try? JSONDecoder().decode([String].self, from: data) {
                knownNames = names
            } else {
                knownNames = []
            }
            if knownNames.contains(name) {
                let counts = decodeDict(shared, forKey: "diveCountByDiver", type: Int.self)
                let minutes = decodeDict(shared, forKey: "totalMinutesByDiver", type: Int.self)
                let maxDepths = decodeDict(shared, forKey: "maxDepthMetersByDiver", type: Double.self)
                let longest = decodeDict(shared, forKey: "longestDiveMinutesByDiver", type: Int.self)
                let recents = decodeDict(shared, forKey: "mostRecentDiveDateByDiver", type: Double.self)
                let recentTS = recents[name] ?? 0
                return DiverStatsEntry(
                    date: .now,
                    locale: locale,
                    colorScheme: colorScheme,
                    diverName: name,
                    isAllDivers: false,
                    diveCount: counts[name] ?? 0,
                    totalMinutes: minutes[name] ?? 0,
                    maxDepthMeters: maxDepths[name] ?? 0,
                    longestDiveMinutes: longest[name] ?? 0,
                    mostRecentDiveDate: recentTS > 0 ? Date(timeIntervalSince1970: recentTS) : nil,
                    depthUnit: depthUnit
                )
            }
        }

        let recent = shared?.double(forKey: "mostRecentDiveDate") ?? 0
        return DiverStatsEntry(
            date: .now,
            locale: locale,
            colorScheme: colorScheme,
            diverName: "",
            isAllDivers: true,
            diveCount: shared?.integer(forKey: "totalDiveCount") ?? 0,
            totalMinutes: shared?.integer(forKey: "totalMinutesUnderwater") ?? 0,
            maxDepthMeters: shared?.double(forKey: "maxDepthMeters") ?? 0,
            longestDiveMinutes: shared?.integer(forKey: "longestDiveMinutes") ?? 0,
            mostRecentDiveDate: recent > 0 ? Date(timeIntervalSince1970: recent) : nil,
            depthUnit: depthUnit
        )
    }

    func placeholder(in context: Context) -> DiverStatsEntry {
        Self.makeEntry(for: nil)
    }

    func snapshot(for configuration: DiverStatsWidgetIntent, in context: Context) async -> DiverStatsEntry {
        Self.makeEntry(for: configuration)
    }

    func timeline(for configuration: DiverStatsWidgetIntent, in context: Context) async -> Timeline<DiverStatsEntry> {
        let entry = Self.makeEntry(for: configuration)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let nextMidnight = cal.nextDate(after: entry.date,
                                        matching: DateComponents(hour: 0, minute: 0, second: 0),
                                        matchingPolicy: .nextTime)
            ?? cal.date(byAdding: .day, value: 1, to: entry.date)
            ?? entry.date.addingTimeInterval(86400)
        return Timeline(entries: [entry], policy: .after(nextMidnight))
    }
}

// MARK: - Diver Stats Medium View

struct DiverStatsWidgetView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    var entry: DiverStatsEntry

    private var isDark: Bool { entry.isDark(system: systemColorScheme) }
    private var palette: WidgetPalette { WidgetPalette(isDark: isDark) }

    private var formattedDiveCount: String {
        guard entry.diveCount > 0 else { return "—" }
        let nf = NumberFormatter()
        nf.locale = entry.locale
        nf.numberStyle = .decimal
        return nf.string(from: NSNumber(value: entry.diveCount)) ?? "\(entry.diveCount)"
    }

    private func formatMinutes(_ minutes: Int) -> String {
        let bundle = Bundle.forWidgetLocale(entry.locale)
        let nf = NumberFormatter()
        nf.locale = entry.locale
        nf.numberStyle = .decimal
        func fmt(_ n: Int) -> String { nf.string(from: NSNumber(value: n)) ?? "\(n)" }
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            if m == 0 {
                return String(format: NSLocalizedString("%@ h", bundle: bundle,
                    comment: "Widget time: hours only (e.g. '2 h')"), fmt(h))
            }
            return String(format: NSLocalizedString("%@ h %@ min", bundle: bundle,
                comment: "Widget time: hours and minutes (e.g. '1 h 30 min')"), fmt(h), fmt(m))
        }
        return String(format: NSLocalizedString("%@ min", bundle: bundle,
            comment: "Widget time: minutes only (e.g. '45 min')"), fmt(minutes))
    }

    private var formattedTotalTime: String {
        guard entry.diveCount > 0 else { return "—" }
        return formatMinutes(entry.totalMinutes)
    }
    private var formattedLongestDive: String {
        guard entry.diveCount > 0 else { return "—" }
        return formatMinutes(entry.longestDiveMinutes)
    }

    private var formattedMaxDepth: String {
        guard entry.maxDepthMeters > 0 else { return "—" }
        let value = entry.convertDepth(entry.maxDepthMeters)
        let nf = NumberFormatter()
        nf.locale = entry.locale
        nf.numberStyle = .decimal
        let decimals = entry.depthUnit == "feet" ? 0 : 1
        nf.minimumFractionDigits = decimals
        nf.maximumFractionDigits = decimals
        let str = nf.string(from: NSNumber(value: value)) ?? String(format: decimals == 0 ? "%.0f" : "%.1f", value)
        return "\(str) \(entry.depthSymbol)"
    }

    private var formattedDaysSinceLastDive: String {
        guard entry.diveCount > 0, let date = entry.mostRecentDiveDate else { return "—" }
        var cal = Calendar(identifier: .gregorian)
        cal.locale = entry.locale
        cal.timeZone = .current
        let from = cal.startOfDay(for: date)
        let to = cal.startOfDay(for: entry.date)
        let days = max(0, cal.dateComponents([.day], from: from, to: to).day ?? 0)
        let nf = NumberFormatter()
        nf.locale = entry.locale
        nf.numberStyle = .decimal
        return nf.string(from: NSNumber(value: days)) ?? "\(days)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 10)

            HStack(alignment: .top, spacing: 14) {
                leftColumn
                Rectangle()
                    .fill(palette.divider)
                    .frame(width: 1)
                    .padding(.vertical, 2)
                rightColumn
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.locale, entry.locale)
        .containerBackground(for: .widget) { BlueDiveWidgetBackground(isDark: isDark) }
        .preferredColorScheme(entry.colorScheme)
    }

    private var header: some View {
        BlueDiveWidgetHeader(palette: palette)
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "person.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.accent)
                Group {
                    if entry.isAllDivers {
                        Text("All Divers")
                    } else if entry.diverName.isEmpty {
                        Text("Diver")
                    } else {
                        Text(verbatim: entry.diverName)
                    }
                }
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(palette.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 8)

            heroStat(value: formattedDiveCount, label: "Total Dives")

            Spacer(minLength: 8)

            heroStat(value: formattedTotalTime, label: "Total Time")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            statPill(icon: "stopwatch", value: formattedLongestDive, label: "Longest")
            statPill(icon: "arrow.down.to.line", value: formattedMaxDepth, label: "Deepest")
            statPill(icon: "hourglass", value: formattedDaysSinceLastDive, label: "Days Since")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func heroStat(value: String, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: value)
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: isDark
                            ? [Color.white, palette.accent]
                            : [palette.accent, Color(red: 0.0, green: 0.30, blue: 0.55)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(palette.secondary)
                .tracking(0.4)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .allowsTightening(true)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func statPill(icon: String, value: String, label: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(palette.accent.opacity(isDark ? 0.22 : 0.16))
                    .frame(width: 22, height: 22)
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(palette.accent)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: value)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.secondary)
                    .tracking(0.3)
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .allowsTightening(true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.pillBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.pillBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Diver Stats Widget

struct DiverStatsWidget: Widget {
    let kind = "DiverStatsWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: DiverStatsWidgetIntent.self, provider: DiverStatsProvider()) { entry in
            DiverStatsWidgetView(entry: entry)
        }
        .configurationDisplayName("Diver Stats")
        .description("See your key diver stats at a glance.")
        .supportedFamilies([.systemMedium])
    }
}

// MARK: - Previews

#Preview("Manual Small", as: .systemSmall) {
    ManualDiveWidget()
} timeline: {
    AddDiveEntry(date: .now, locale: .current, colorScheme: nil, diveCount: 0, diverLabel: nil)
}

#Preview("Bluetooth Small", as: .systemSmall) {
    BluetoothDiveWidget()
} timeline: {
    AddDiveEntry(date: .now, locale: .current, colorScheme: nil, diveCount: 0, diverLabel: nil)
}

#Preview("Dive Count — All", as: .systemSmall) {
    DiveCountWidget()
} timeline: {
    AddDiveEntry(date: .now, locale: .current, colorScheme: nil, diveCount: 42, diverLabel: nil)
}

#Preview("Dive Count — Filtered", as: .systemSmall) {
    DiveCountWidget()
} timeline: {
    AddDiveEntry(date: .now, locale: .current, colorScheme: nil, diveCount: 15, diverLabel: "Steve")
}

#Preview("Diver Stats — Medium", as: .systemMedium) {
    DiverStatsWidget()
} timeline: {
    DiverStatsEntry(date: .now,
                    locale: .current,
                    colorScheme: nil,
                    diverName: "Steve",
                    isAllDivers: false,
                    diveCount: 127,
                    totalMinutes: 5340,
                    maxDepthMeters: 42.8,
                    longestDiveMinutes: 78,
                    mostRecentDiveDate: Date().addingTimeInterval(-3 * 86400),
                    depthUnit: "meters")
}

#Preview("Diver Stats — All Divers", as: .systemMedium) {
    DiverStatsWidget()
} timeline: {
    DiverStatsEntry(date: .now,
                    locale: .current,
                    colorScheme: nil,
                    diverName: "",
                    isAllDivers: true,
                    diveCount: 312,
                    totalMinutes: 14820,
                    maxDepthMeters: 55.0,
                    longestDiveMinutes: 95,
                    mostRecentDiveDate: Date().addingTimeInterval(-1 * 86400),
                    depthUnit: "meters")
}

#Preview("Diver Stats — Empty", as: .systemMedium) {
    DiverStatsWidget()
} timeline: {
    DiverStatsEntry(date: .now,
                    locale: .current,
                    colorScheme: nil,
                    diverName: "",
                    isAllDivers: false,
                    diveCount: 0,
                    totalMinutes: 0,
                    maxDepthMeters: 0,
                    longestDiveMinutes: 0,
                    mostRecentDiveDate: nil,
                    depthUnit: "meters")
}
