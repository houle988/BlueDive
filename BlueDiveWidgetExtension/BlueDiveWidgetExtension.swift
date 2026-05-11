import WidgetKit
import SwiftUI
import AppIntents

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
        case "en":    return Locale(identifier: "en")
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
                     diveCount: UserDefaults(suiteName: appGroupSuite)?.integer(forKey: "totalDiveCount") ?? 0,
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
        identifiers.map { DiverEntity(id: $0) }
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
        Timeline(entries: [makeEntry(for: configuration)], policy: .never)
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

private extension AddDiveEntry {
    func isDark(system: ColorScheme) -> Bool {
        switch colorScheme {
        case .dark:       return true
        case .light:      return false
        case nil:         return system == .dark
        @unknown default: return system == .dark
        }
    }
}

// MARK: - Shared background

private func widgetBackground(isDark: Bool) -> some View {
    Group {
        if isDark {
            LinearGradient(colors: [Color(red: 0.02, green: 0.10, blue: 0.20),
                                    Color(red: 0.05, green: 0.20, blue: 0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            LinearGradient(colors: [Color(red: 0.88, green: 0.95, blue: 1.00),
                                    Color(red: 0.72, green: 0.88, blue: 0.98)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
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
    private var labelColor: Color    { isDark ? .white : Color(red: 0.08, green: 0.15, blue: 0.28) }
    private var subtitleColor: Color { isDark ? .white.opacity(0.7) : Color(red: 0.08, green: 0.15, blue: 0.28).opacity(0.6) }
    private var headerColor: Color   { isDark ? .white.opacity(0.9) : Color(red: 0.08, green: 0.15, blue: 0.28).opacity(0.8) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "water.waves").foregroundStyle(.cyan).font(.caption2)
                Text("BlueDive").font(.caption2).bold().foregroundStyle(headerColor)
                Spacer()
            }
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(tint)
            Text(title).font(.subheadline).bold().foregroundStyle(labelColor)
            Text(subtitle).font(.caption2).foregroundStyle(subtitleColor).multilineTextAlignment(.center).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.locale, entry.locale)
        .widgetURL(url)
        .containerBackground(for: .widget) { widgetBackground(isDark: isDark) }
        .preferredColorScheme(entry.colorScheme)
    }
}

// MARK: - Dive Count Small View

struct DiveCountWidgetView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    var entry: AddDiveEntry

    private var isDark: Bool { entry.isDark(system: systemColorScheme) }
    private var labelColor: Color    { isDark ? .white : Color(red: 0.08, green: 0.15, blue: 0.28) }
    private var subtitleColor: Color { isDark ? .white.opacity(0.7) : Color(red: 0.08, green: 0.15, blue: 0.28).opacity(0.6) }
    private var headerColor: Color   { isDark ? .white.opacity(0.9) : Color(red: 0.08, green: 0.15, blue: 0.28).opacity(0.8) }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "water.waves").foregroundStyle(.cyan).font(.caption2)
                Text("BlueDive").font(.caption2).bold().foregroundStyle(headerColor)
                Spacer()
            }
            Spacer()
            Text("\(entry.diveCount)")
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .foregroundStyle(.cyan)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            if let label = entry.diverLabel {
                Text(verbatim: label)
                    .font(.caption2)
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("Total Dives")
                    .font(.caption2)
                    .foregroundStyle(subtitleColor)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.locale, entry.locale)
        .containerBackground(for: .widget) { widgetBackground(isDark: isDark) }
        .preferredColorScheme(entry.colorScheme)
    }
}

// MARK: - Widget definitions

struct ManualDiveWidget: Widget {
    let kind = "ManualDiveWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AddDiveProvider()) { entry in
            FocusedSmallWidgetView(entry: entry,
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
            FocusedSmallWidgetView(entry: entry,
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
