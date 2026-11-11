import SwiftUI

// MARK: - Main Tabs

/// The main window's tabs, in their default order. The raw values are the identifiers stored by
/// Settings → Appearance & Language → Main Tabs (`UserPreferences.mainTabOrder` /
/// `hiddenMainTabs`): never change or localize them. Nonisolated: the project's default
/// isolation is the MainActor, and the values are also used as the tab selection.
nonisolated enum MainTab: String, CaseIterable, Identifiable, Sendable {
    case dives      = "Dives"
    case map        = "Map"
    case equipment  = "Equipment"
    case marineLife = "Marine Life"
    case documents  = "Documents"

    var id: Self { self }

    var icon: String {
        switch self {
        case .dives:      return "water.waves"
        case .map:        return "map"
        case .equipment:  return "wrench.and.screwdriver"
        case .marineLife: return "fish"
        case .documents:  return "person.text.rectangle"
        }
    }

    /// The tile colour of the tab's row in Settings → Main Tabs.
    var color: Color {
        switch self {
        case .dives:      return .cyan
        case .map:        return .green
        case .equipment:  return .purple
        case .marineLife: return .orange
        case .documents:  return .blue
        }
    }
}

extension MainTab {
    /// The tab's name in the in-app language, as the tab bar shows it (the tab bar, `TabBarFit`,
    /// Settings → Main Tabs, alerts). Equipment and Marine Life have their own short keys: five
    /// tabs share an iPhone's width (e.g. nl "Uitrusting" here, "Duikuitrusting" elsewhere).
    @MainActor var title: String {
        switch self {
        case .dives:
            return NSLocalizedString("Dives", bundle: .forAppLanguage(), value: "Dives", comment: "Tab bar label for the dive list; the same key is used elsewhere, e.g. the dive count in the stats grid")
        case .map:
            return NSLocalizedString("Map", bundle: .forAppLanguage(), value: "Map", comment: "Tab bar label for the dive map")
        case .equipment:
            return NSLocalizedString("Equipment (tab)", bundle: .forAppLanguage(), value: "Equipment", comment: "Tab bar label for Equipment; keep it short (five tabs share an iPhone's width)")
        case .marineLife:
            return NSLocalizedString("Marine Life (tab)", bundle: .forAppLanguage(), value: "Marine Life", comment: "Tab bar label for Marine Life; keep it short (five tabs share an iPhone's width)")
        case .documents:
            return NSLocalizedString("Documents", bundle: .forAppLanguage(), value: "Documents", comment: "Tab bar label for Documents; also the Documents screen's navigation title")
        }
    }
}

extension MainTab {
    /// Every tab in a saved `order` (`UserPreferences.mainTabOrder`), Dives first, hidden ones
    /// included.
    @MainActor static func ordered(_ order: [String]) -> [MainTab] {
        TabLayout.resolvedOrder(stored: order, defaults: allCases.map(\.rawValue),
                                locked: dives.rawValue)
            .compactMap { MainTab(rawValue: $0) }
    }

    /// Whether a layout with these `hidden` tabs (`UserPreferences.hiddenMainTabs`) shows `tab`.
    /// Dives is always shown.
    static func isShown(_ tab: MainTab, hidden: [String]) -> Bool {
        tab == .dives || !hidden.contains(tab.rawValue)
    }

    /// The tabs a saved layout shows, in order.
    @MainActor static func shown(order: [String], hidden: [String]) -> [MainTab] {
        ordered(order).filter { isShown($0, hidden: hidden) }
    }

    /// The saved layout read straight from UserDefaults: the only way a window reads it (when it
    /// is created and when its Settings closes, `MainTabView`). Reading `UserPreferences` there
    /// would make the window observe the layout and redraw at every change made in Settings →
    /// Main Tabs.
    @MainActor static var savedLayoutUnobserved: [MainTab] {
        let defaults = UserDefaults.standard
        return shown(order: defaults.stringArray(forKey: UserPreferences.mainTabOrderKey) ?? [],
                     hidden: defaults.stringArray(forKey: UserPreferences.hiddenMainTabsKey) ?? [])
    }
}

extension EnvironmentValues {
    /// The main tabs the window shows, set by `MainTabView`: an XML file meant for a tab the
    /// window does not show is not imported (`ContentView.handleExternalFileURL`).
    @Entry var shownMainTabs: [MainTab] = MainTab.allCases
}

extension UserPreferences {
    /// The main tabs in the user's order, Dives first, hidden ones included.
    var orderedMainTabs: [MainTab] {
        MainTab.ordered(mainTabOrder)
    }

    /// Whether the tab bar shows `tab`. Dives is always shown.
    func isMainTabShown(_ tab: MainTab) -> Bool {
        MainTab.isShown(tab, hidden: hiddenMainTabs)
    }

    func setMainTab(_ tab: MainTab, shown: Bool) {
        guard tab != .dives else { return }
        // Built first and assigned once: a single UserDefaults write and redraw.
        var hidden = hiddenMainTabs.filter { $0 != tab.rawValue }
        if !shown { hidden.append(tab.rawValue) }
        hiddenMainTabs = hidden
    }
}
