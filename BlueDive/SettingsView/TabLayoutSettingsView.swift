import SwiftUI

// MARK: - Tab Order

/// The order of the dive detail tabs the user can rearrange (Settings → Dive Profile →
/// Dive Detail Tabs).
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

// MARK: - Dive Detail Tabs Settings

/// Settings → Dive Profile → Dive Detail Tabs: the order of the dive detail tabs and which ones
/// are shown.
/// Overview stays first and is always shown.
struct TabLayoutSettingsView: View {
    @State private var prefs = UserPreferences.shared

    var body: some View {
        groupedList {
            Section {
                let tabs = prefs.orderedDiveTabs
                let isDefaultLayout = tabs == DiveTab.visibleCases
                    && !DiveTab.visibleCases.contains { $0 != .samples && !prefs.isDiveTabShown($0) }
                    && !prefs.showSamplesTab
                ForEach(tabs) { tab in
                    positionControl(row(tab), title: Text(tab.localizedName),
                                    index: tabs.firstIndex(of: tab) ?? 0, count: tabs.count)
                        .moveDisabled(tab == .menu)
                }
                .onMove(perform: move)

                Button {
                    prefs.diveTabOrder = []
                    prefs.hiddenDiveTabs = []
                    prefs.showSamplesTab = false
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
                #if os(macOS)
                Text("Choose a position to reorder the tabs and switch off the ones you do not use. Overview always comes first.")
                #else
                Text("Drag the tabs to reorder them and switch off the ones you do not use. Overview always comes first.")
                #endif
            }
        }
        #if os(iOS)
        // Shows the drag handles; the switches still work in edit mode.
        .environment(\.editMode, .constant(.active))
        #endif
        .navigationTitle(Text(verbatim: NSLocalizedString("Dive Detail Tabs", bundle: .forAppLanguage(), value: "Dive Detail Tabs", comment: "Title of the Settings page for the order and visibility of the dive detail tabs")))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func move(from source: IndexSet, to destination: Int) {
        prefs.diveTabOrder = TabLayout.moved(prefs.orderedDiveTabs.map(\.rawValue),
                                             from: source, to: destination,
                                             locked: DiveTab.menu.rawValue)
    }

    /// A tab's row: Overview with a note that it is always shown, the others with a switch.
    @ViewBuilder
    private func row(_ tab: DiveTab) -> some View {
        let label = SettingsListRow(
            title: tab.localizedName, icon: tab.icon, color: tab.color,
            // What the Samples tab shows, and why it is off by default.
            detail: tab == .samples
                ? NSLocalizedString("When on, the dive details show a Samples tab with the raw data recorded by your dive computer at each sample point. Long dives can take a moment to display in full.", bundle: .forAppLanguage(), value: "When on, the dive details show a Samples tab with the raw data recorded by your dive computer at each sample point. Long dives can take a moment to display in full.", comment: "Caption under the Samples switch in Settings → Dive Profile → Dive Detail Tabs")
                : nil
        )
        if tab == .menu {
            HStack {
                label
                Spacer()
                Text("Always shown")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            Toggle(isOn: Binding(get: { prefs.isDiveTabShown(tab) },
                                 set: { prefs.setDiveTab(tab, shown: $0) })) {
                label
            }
            .fullWidthSwitch()
        }
    }

    /// `row` with a pop-up of its position on macOS, where a grouped Form does not reorder its
    /// rows by dragging: choosing a position moves the tab there. Overview (the first row) gets
    /// none, and its position cannot be chosen. On iOS, `row` unchanged (the list's drag handles
    /// reorder it).
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
                        move(from: IndexSet(integer: index), to: newIndex > index ? newIndex + 1 : newIndex)
                    }
                )) {
                    ForEach(1..<count, id: \.self) { position in
                        // Positions count from 1, Overview's.
                        Text(verbatim: Double(position + 1).localizedString(decimals: 0))
                            .tag(position)
                    }
                } label: {
                    Text("Position")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel(Text("Position of \(title)", comment: "VoiceOver label of the pop-up that sets a tab's position in Settings → Dive Profile → Dive Detail Tabs; %@ is the tab's name"))
            }
        }
        #else
        row
        #endif
    }
}
