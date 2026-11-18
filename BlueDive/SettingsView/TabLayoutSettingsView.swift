import SwiftUI

// MARK: - Tab Order

/// The order of a tab bar the user can rearrange: the dive detail tabs (Settings → Dive Profile →
/// Dive Detail Tabs) and the main tabs (Settings → Appearance & Language → Main Tabs).
enum TabLayout {
    /// `stored` (the user's order) with unknown and repeated identifiers dropped, any tab of
    /// `defaults` missing from it (a tab added by a later version) inserted after the tab that
    /// precedes it in `defaults`, and `locked` first.
    static func resolvedOrder(stored: [String], defaults: [String], locked: String) -> [String] {
        var order: [String] = []
        for id in stored where id != locked && defaults.contains(id) && !order.contains(id) {
            order.append(id)
        }
        for (index, id) in defaults.enumerated() where id != locked && !order.contains(id) {
            if let predecessor = defaults[..<index].last(where: { order.contains($0) }),
               let position = order.firstIndex(of: predecessor) {
                order.insert(id, at: position + 1)
            } else {
                order.insert(id, at: 0)
            }
        }
        return [locked] + order
    }

    /// `order` after a list move, with `locked` kept first.
    static func moved(_ order: [String], from source: IndexSet, to destination: Int,
                      locked: String) -> [String] {
        var order = order
        order.move(fromOffsets: source, toOffset: destination)
        return [locked] + order.filter { $0 != locked }
    }
}

extension UserPreferences {
    /// The dive detail tabs in the user's order, Overview first, hidden ones included.
    var orderedDiveTabs: [DiveTab] {
        TabLayout.resolvedOrder(stored: diveTabOrder,
                                defaults: DiveTab.visibleCases.map(\.rawValue),
                                locked: DiveTab.menu.rawValue)
            .compactMap { DiveTab(rawValue: $0) }
    }

    /// Whether the dive detail tab bar shows `tab`. Samples follows `showSamplesTab`.
    func isDiveTabShown(_ tab: DiveTab) -> Bool {
        switch tab {
        case .menu:                   return true
        case .samples:                return showSamplesTab
        case .xmlExport, .uddfExport: return false
        default:                      return !hiddenDiveTabs.contains(tab.rawValue)
        }
    }

    func setDiveTab(_ tab: DiveTab, shown: Bool) {
        switch tab {
        case .menu, .xmlExport, .uddfExport:
            return
        case .samples:
            showSamplesTab = shown
        default:
            // Built first and assigned once: a single UserDefaults write and redraw.
            var hidden = hiddenDiveTabs.filter { $0 != tab.rawValue }
            if !shown { hidden.append(tab.rawValue) }
            hiddenDiveTabs = hidden
        }
    }

    /// The tabs the dive detail tab bar shows, in order.
    var shownDiveTabs: [DiveTab] {
        orderedDiveTabs.filter(isDiveTabShown)
    }
}

// MARK: - Tab Layout Editor

/// A Settings page listing a tab bar's tabs, each with a switch to show it, in an order the user
/// can change; `locked` stays first and is always shown. Shared by Dive Detail Tabs and Main
/// Tabs. iOS reorders with the list's drag handles (always in edit mode); macOS, where a grouped
/// Form does not reorder its rows by dragging, with a position pop-up on each row.
struct TabLayoutEditor<Item: Identifiable & Hashable, RowLabel: View, Footer: View>: View {
    let navigationTitle: String
    let tabs: [Item]
    let locked: Item
    /// The tab's name, for the position pop-up's VoiceOver label.
    let name: (Item) -> Text
    @ViewBuilder let rowLabel: (Item) -> RowLabel
    let isShown: (Item) -> Bool
    let setShown: (Item, Bool) -> Void
    let move: (IndexSet, Int) -> Void
    let isDefaultLayout: Bool
    let restore: () -> Void
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        groupedList {
            Section {
                ForEach(tabs) { tab in
                    positionControl(row(tab), title: name(tab),
                                    index: tabs.firstIndex(of: tab) ?? 0, count: tabs.count)
                        .moveDisabled(tab == locked)
                }
                .onMove(perform: move)

                Button {
                    restore()
                } label: {
                    // Coloured on the label itself: in this Mac Form a colour set on the button
                    // is replaced by the primary colour (as `listRowMenu` notes). Cyan on both
                    // platforms, grey while disabled (an explicit colour is not dimmed on iOS).
                    Text("Restore Default Layout")
                        .foregroundStyle(isDefaultLayout ? AnyShapeStyle(.secondary) : AnyShapeStyle(.cyan))
                }
                .listRowButton()
                .disabled(isDefaultLayout)
            } footer: {
                footer()
            }
        }
        #if os(iOS)
        // Shows the drag handles; the switches still work in edit mode.
        .environment(\.editMode, .constant(.active))
        #endif
        .navigationTitle(Text(verbatim: navigationTitle))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A tab's row: the locked tab with a note that it is always shown, the others with a switch.
    @ViewBuilder
    private func row(_ tab: Item) -> some View {
        if tab == locked {
            HStack {
                rowLabel(tab)
                Spacer()
                Text("Always shown")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            Toggle(isOn: Binding(get: { isShown(tab) }, set: { setShown(tab, $0) })) {
                rowLabel(tab)
            }
            .fullWidthSwitch()
        }
    }

    /// `row` with a pop-up of its position on macOS: choosing a position moves the tab there.
    /// The locked tab (the first row) gets none, and its position cannot be chosen. On iOS,
    /// `row` unchanged (the list's drag handles reorder it).
    @ViewBuilder
    private func positionControl(_ row: some View, title: Text, index: Int, count: Int) -> some View {
        #if os(macOS)
        if index == 0 {
            row
        } else {
            HStack(spacing: 12) {
                row
                Picker(selection: Binding(
                    get: { index },
                    set: { newIndex in
                        // A list move inserts before `destination`: one further when moving down.
                        move(IndexSet(integer: index), newIndex > index ? newIndex + 1 : newIndex)
                    }
                )) {
                    ForEach(1..<count, id: \.self) { position in
                        // Positions count from 1, the locked tab's.
                        Text(verbatim: Double(position + 1).localizedString(decimals: 0))
                            .tag(position)
                    }
                } label: {
                    Text("Position")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel(Text("Position of \(title)", comment: "VoiceOver label of the pop-up that sets a tab's position (macOS), in Settings → Dive Profile → Dive Detail Tabs and Settings → Appearance & Language → Main Tabs; %@ is the tab's name (e.g. Gas, Equipment)"))
            }
        }
        #else
        row
        #endif
    }
}

// MARK: - Dive Detail Tabs Settings

/// Settings → Dive Profile → Dive Detail Tabs: the order of the dive detail tabs and which ones
/// are shown. Overview stays first and is always shown.
struct TabLayoutSettingsView: View {
    @State private var prefs = UserPreferences.shared

    var body: some View {
        TabLayoutEditor(
            navigationTitle: NSLocalizedString("Dive Detail Tabs", bundle: .forAppLanguage(), value: "Dive Detail Tabs", comment: "Title of the Settings page for the order and visibility of the dive detail tabs"),
            tabs: prefs.orderedDiveTabs,
            locked: DiveTab.menu,
            name: { Text($0.localizedName) },
            rowLabel: { tab in
                SettingsListRow(
                    title: tab.localizedName, icon: tab.icon, color: tab.color,
                    // What the Samples tab shows, and why it is off by default.
                    detail: tab == .samples
                        ? NSLocalizedString("When on, the dive details show a Samples tab with the raw data recorded by your dive computer at each sample point. Long dives can take a moment to display in full.", bundle: .forAppLanguage(), value: "When on, the dive details show a Samples tab with the raw data recorded by your dive computer at each sample point. Long dives can take a moment to display in full.", comment: "Caption under the Samples switch in Settings → Dive Profile → Dive Detail Tabs")
                        : nil
                )
            },
            isShown: { prefs.isDiveTabShown($0) },
            setShown: { prefs.setDiveTab($0, shown: $1) },
            move: { source, destination in
                prefs.diveTabOrder = TabLayout.moved(prefs.orderedDiveTabs.map(\.rawValue),
                                                     from: source, to: destination,
                                                     locked: DiveTab.menu.rawValue)
            },
            isDefaultLayout: prefs.orderedDiveTabs == DiveTab.visibleCases
                && !DiveTab.visibleCases.contains { $0 != .samples && !prefs.isDiveTabShown($0) }
                && !prefs.showSamplesTab,
            restore: {
                prefs.diveTabOrder = []
                prefs.hiddenDiveTabs = []
                prefs.showSamplesTab = false
            },
            footer: {
                #if os(macOS)
                Text("Choose a position to reorder the tabs and switch off the ones you do not use. Overview always comes first.")
                #else
                Text("Drag the tabs to reorder them and switch off the ones you do not use. Overview always comes first.")
                #endif
            }
        )
    }
}

// MARK: - Main Tabs Settings

/// Settings → Appearance & Language → Main Tabs: the order of the main window's tabs and which
/// ones are shown. Dives stays first and is always shown. A window applies the new layout when
/// its Settings closes (`MainTabView`).
struct MainTabLayoutSettingsView: View {
    @State private var prefs = UserPreferences.shared

    var body: some View {
        TabLayoutEditor(
            navigationTitle: NSLocalizedString("Main Tabs", bundle: .forAppLanguage(), value: "Main Tabs", comment: "Title of the Settings page for the order and visibility of the main window's tabs (Dives, Map, Equipment, Marine Life, Documents)"),
            tabs: prefs.orderedMainTabs,
            locked: MainTab.dives,
            name: { Text(verbatim: $0.title) },
            rowLabel: { tab in
                // The tab bar's own titles (`MainTab.title`, in the in-app language).
                SettingsListRow(title: Text(verbatim: tab.title), icon: tab.icon, color: tab.color)
            },
            isShown: { prefs.isMainTabShown($0) },
            setShown: { prefs.setMainTab($0, shown: $1) },
            move: { source, destination in
                prefs.mainTabOrder = TabLayout.moved(prefs.orderedMainTabs.map(\.rawValue),
                                                     from: source, to: destination,
                                                     locked: MainTab.dives.rawValue)
            },
            isDefaultLayout: prefs.orderedMainTabs == MainTab.allCases
                && !MainTab.allCases.contains { !prefs.isMainTabShown($0) },
            restore: {
                prefs.mainTabOrder = []
                prefs.hiddenMainTabs = []
            },
            footer: {
                #if os(macOS)
                Text("Choose a position to reorder the tabs and switch off the ones you do not use. Dives always comes first. The new layout applies when you close Settings.")
                #else
                Text("Drag the tabs to reorder them and switch off the ones you do not use. Dives always comes first. The new layout applies when you close Settings.")
                #endif
            }
        )
    }
}
