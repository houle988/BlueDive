import OSLog
import SwiftData
import SwiftUI

// MARK: - Diver Filter

/// Shared utilities for the per-view diver filter.
/// Centralizes the AppStorage key, the picker, and the "stale selection" reset
/// so every consumer view stays consistent.
enum DiverFilter {
    /// Single source of truth for the AppStorage key.
    static let storageKey = "selectedDiverFilter"

    /// Sorted, deduplicated list of non-empty diver names across dives, gear, certifications, and insurances.
    /// All parameters are optional so callers can pass only the sources they have.
    static func uniqueDivers(
        in dives: [Dive] = [],
        gear: [Gear] = [],
        certifications: [Certification] = [],
        insurances: [DivingInsurance] = []
    ) -> [String] {
        let names = dives.map { $0.diverName.trimmingCharacters(in: .whitespaces) }
            + gear.map { $0.diverName.trimmingCharacters(in: .whitespaces) }
            + certifications.map { $0.diverName.trimmingCharacters(in: .whitespaces) }
            + insurances.map { $0.diverName.trimmingCharacters(in: .whitespaces) }
        return Array(Set(names.filter { !$0.isEmpty })).sorted()
    }

    /// Shared "No Dives for <name>" empty-state title, used identically by every screen
    /// whose dive list is empty solely because of the diver filter (ContentView,
    /// DiveCalendarHeatmapView, MarineLifeView, StatisticsView). Centralized so the 4
    /// screens' wording can never drift out of sync with each other.
    static func noDivesTitle(for diverName: String) -> Text {
        Text(verbatim: String(
            format: NSLocalizedString("No Dives for %@", bundle: Bundle.forAppLanguage(), value: "No Dives for %@", comment: "Empty-state title when the selected diver has no dives; %@ is the diver's name"),
            diverName
        ))
    }

    /// Shared "No dives were found for <name>." empty-state description — see `noDivesTitle`.
    static func noDivesDescription(for diverName: String) -> Text {
        Text(verbatim: String(
            format: NSLocalizedString("No dives were found for %@.", bundle: Bundle.forAppLanguage(), value: "No dives were found for %@.", comment: "Empty-state description when the selected diver has no dives; %@ is the diver's name"),
            diverName
        ))
    }

    /// First letters of up to two words in a name, uppercased (e.g. "Steve Houle" → "SH").
    /// Returns "?" when the name contains no letters or digits. Shared by the toolbar
    /// chip and the map pins so initials render identically everywhere.
    static func initials(for name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }
        return letters.isEmpty ? "?" : letters.joined()
    }

    /// Returns `dives` filtered to a single diver, or unchanged when no diver is selected.
    /// Trims stored names before comparison so they match the trimmed picker values.
    static func apply(_ selected: String, to dives: [Dive]) -> [Dive] {
        selected.isEmpty ? dives : dives.filter { $0.diverName.trimmingCharacters(in: .whitespaces) == selected }
    }

    /// Returns `certifications` filtered to a single diver, or unchanged when no diver is selected.
    static func apply(_ selected: String, to certifications: [Certification]) -> [Certification] {
        selected.isEmpty ? certifications : certifications.filter { $0.diverName.trimmingCharacters(in: .whitespaces) == selected }
    }

    /// Returns `insurances` filtered to a single diver, or unchanged when no diver is selected.
    static func apply(_ selected: String, to insurances: [DivingInsurance]) -> [DivingInsurance] {
        selected.isEmpty ? insurances : insurances.filter { $0.diverName.trimmingCharacters(in: .whitespaces) == selected }
    }

    /// The buddy names of a dive's comma-separated `buddies` text, trimmed, empty ones dropped
    /// (as the XML and UDDF exporters split it). Shared by the buddy filter and its menu.
    nonisolated static func buddyNames(_ buddies: String) -> [String] {
        buddies.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Gas filter rule shared by the Dives list, Map and Statistics: "None" (empty `gas`) keeps
    /// dives with no tanks; otherwise a dive matches when any of its tanks uses `gas`, and
    /// `negate` keeps the dives where none does.
    nonisolated static func matchesGas(_ gasNames: [String], gas: String, negate: Bool) -> Bool {
        if gas.isEmpty { return gasNames.isEmpty }
        return gasNames.contains(gas) != negate
    }

    /// Applies the 15-parameter dive filter shared by the Map and Statistics views.
    static func applyDiveFilters(
        to dives: [Dive],
        year: Int?, yearNegate: Bool,
        gasType: String?, gasTypeNegate: Bool,
        minDepth: Double, maxDepth: Double,
        minRating: Int,
        country: String?, countryNegate: Bool,
        diveType: String?, diveTypeNegate: Bool,
        tag: String?, tagNegate: Bool,
        buddy: String?, buddyNegate: Bool,
        marineLife: [String], marineLifeMode: FilterMarineLifeMode
    ) -> [Dive] {
        dives.filter { dive in
            if let year = year {
                let diveYear = Calendar.current.component(.year, from: dive.timestamp)
                if yearNegate { if diveYear == year { return false } }
                else { if diveYear != year { return false } }
            }
            if let gas = gasType,
               !matchesGas(DiveSummary.gasNames(of: dive), gas: gas, negate: gasTypeNegate) {
                return false
            }
            if minDepth > 0 || maxDepth > 0 {
                let depth = dive.displayMaxDepth
                if minDepth > 0, maxDepth > 0 {
                    let lo = Swift.min(minDepth, maxDepth)
                    let hi = Swift.max(minDepth, maxDepth)
                    if depth < lo || depth > hi { return false }
                } else if minDepth > 0 { if depth < minDepth { return false } }
                else if maxDepth > 0 { if depth > maxDepth { return false } }
            }
            if minRating > 0, dive.rating < minRating { return false }
            if let country = country {
                if country.isEmpty { guard dive.siteCountry == nil || dive.siteCountry!.isEmpty else { return false } }
                else if countryNegate { if let dc = dive.siteCountry, dc == country { return false } }
                else { guard let dc = dive.siteCountry, dc == country else { return false } }
            }
            if let diveType = diveType {
                if diveType.isEmpty {
                    let trimmed = dive.diveTypes?.trimmingCharacters(in: .whitespaces) ?? ""
                    if !trimmed.isEmpty { return false }
                } else {
                    let allTypes = dive.diveTypes?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
                    if diveTypeNegate { if allTypes.contains(diveType) { return false } }
                    else { if !allTypes.contains(diveType) { return false } }
                }
            }
            if let tag = tag {
                if tag.isEmpty {
                    let trimmed = dive.tags?.trimmingCharacters(in: .whitespaces) ?? ""
                    if !trimmed.isEmpty { return false }
                } else {
                    let diveTags = dive.tags?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
                    if tagNegate { if diveTags.contains(tag) { return false } }
                    else { if !diveTags.contains(tag) { return false } }
                }
            }
            if let buddy = buddy {
                let names = buddyNames(dive.buddies)
                if buddy.isEmpty { if !names.isEmpty { return false } }
                else if buddyNegate { if names.contains(buddy) { return false } }
                else { if !names.contains(buddy) { return false } }
            }
            if !diveMatchesMarineLifeFilter(dive, species: marineLife, mode: marineLifeMode) { return false }
            return true
        }
    }
}

// MARK: - Gear Diver Resolution

private let gearDiverResolverLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BlueDive", category: "GearDiverResolver")

/// Returns the diver name associated with the gear computer whose serial matches `computerSerial`.
///
/// Looks up gear items of category "Computer" in `context`. Serial comparison is whitespace-trimmed
/// and case-insensitive to handle firmware padding and user-entry differences. If multiple computers
/// share the same serial but disagree on the diver name (ambiguous ownership), falls back to empty
/// string (unnamed bucket). Also returns empty string when no serial is provided, no match is found,
/// or the fetch fails.
func resolveGearDiverName(forSerial computerSerial: String?, in context: ModelContext) -> String {
    guard let rawSerial = computerSerial else { return "" }
    let serial = rawSerial.trimmingCharacters(in: .whitespaces)
    guard !serial.isEmpty else { return "" }

    let computerCategory = GearCategory.computer.rawValue
    // #Predicate cannot call instance methods, so fetch all computers and filter in-memory
    // to apply trimmed case-insensitive serial comparison.
    let predicate = #Predicate<Gear> { gear in
        gear.category == computerCategory && gear.serialNumber != nil
    }
    do {
        let computers = try context.fetch(FetchDescriptor<Gear>(predicate: predicate))
        let matches = computers.filter {
            ($0.serialNumber ?? "").trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(serial) == .orderedSame
                && !$0.diverName.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let distinctNames = Set(matches.map { $0.diverName.trimmingCharacters(in: .whitespaces) })
        if distinctNames.count == 1, let name = distinctNames.first {
            return name
        }
        if distinctNames.count > 1 {
            gearDiverResolverLogger.warning("Multiple gear computers match serial \(serial) with different diver names — falling back to unnamed")
        }
    } catch {
        gearDiverResolverLogger.error("Failed to look up gear for computer serial \(serial): \(error.localizedDescription)")
    }
    return ""
}

// MARK: - Diver Sources Feeder

/// Feeds DiveStore's diver-name list (`store.cachedUniqueDivers`) from gear,
/// certifications and insurance. Renders nothing.
///
/// Attached once, behind MainTabView's TabView, so it stays mounted and updating whatever
/// tab is selected — including while the user adds gear or documents on the Equipment or
/// Documents tab, or iCloud delivers them from another device. DiveDataFeeder (next to it)
/// owns the only Dive @Query and feeds the dive half of the list; this view owns the
/// only Gear/Certification/DivingInsurance queries used for diver names, so no screen needs
/// its own queries just to build a diver list.
struct DiverSourcesFeeder: View {
    @Environment(DiveStore.self) private var store
    @Query private var allGear: [Gear]
    @Query private var allCertifications: [Certification]
    @Query private var allInsurances: [DivingInsurance]

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onAppear(perform: sync)
            // Keyed on the diver-name arrays, not the model arrays: SwiftData models compare by
            // persistentModelID, so observing them directly misses an in-place diverName rename.
            .onChange(of: allGear.map(\.diverName)) { _, _ in sync() }
            .onChange(of: allCertifications.map(\.diverName)) { _, _ in sync() }
            .onChange(of: allInsurances.map(\.diverName)) { _, _ in sync() }
    }

    /// Gear/certification/insurance edits change only the diver-name list — never dive
    /// order, row fields or badges — so they take DiveStore's narrow path, not the full
    /// summary rebuild.
    private func sync() {
        store.updateDiverSources(gear: allGear, certifications: allCertifications, insurances: allInsurances)
    }
}

// MARK: - Toolbar Picker

/// Drop-in toolbar item that exposes the diver filter on iOS and macOS.
/// Always visible, on every screen, at any diver count — the menu always offers
/// "All Divers", so the control is never in a state with nothing to show.
struct DiverFilterToolbar: ToolbarContent {
    let uniqueDivers: [String]
    @Binding var selectedDiver: String
    /// The picker sits with a sheet's utility items: on macOS its label gets their common frame.
    var inSheet = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            picker
                .toolbarMenuIndicatorHiddenOnMac()
        }
    }

    /// The diver filter for a sheet whose only utility item it is (Trips, Calendar, Diver Profile).
    /// macOS draws no `.navigation` item (`.topBarLeading`) in a sheet's toolbar, so there it sits
    /// with the sheet's utility items (`.sheetPrimaryAction`); on iOS it is exactly `DiverFilterToolbar`.
    /// A sheet with other utility items puts `picker` (with `inSheet: true` and
    /// `sheetToolbarControlOnMac()`) first in their macOS group instead (Statistics, Documents).
    @ToolbarContentBuilder
    static func sheetItem(uniqueDivers: [String], selectedDiver: Binding<String>) -> some ToolbarContent {
        #if os(macOS)
        ToolbarItemGroup(placement: .sheetPrimaryAction) {
            DiverFilterToolbar(uniqueDivers: uniqueDivers, selectedDiver: selectedDiver, inSheet: true).picker
                .sheetToolbarControlOnMac()
        }
        #else
        DiverFilterToolbar(uniqueDivers: uniqueDivers, selectedDiver: selectedDiver)
        #endif
    }

    private var isActive: Bool { !selectedDiver.isEmpty }

    /// The control's accessibility label; also its title in `MainWindowToolbar`'s large content viewer.
    static func accessibilityTitle(selectedDiver: String) -> Text {
        selectedDiver.isEmpty
            ? Text("Filter by diver")
            : Text(NSLocalizedString("Filter by diver: ", bundle: Bundle.forAppLanguage(), value: "Filter by diver: ", comment: "") + selectedDiver)
    }

    // Internal (not private) so `MainWindowToolbar` can place the menu with Settings and iCloud
    // in one ToolbarItemGroup (macOS) or in its side-strip row (iOS).
    var picker: some View {
        Menu {
            Button {
                selectedDiver = ""
            } label: {
                if selectedDiver.isEmpty {
                    Label("All Divers", systemImage: "checkmark")
                } else {
                    Text("All Divers")
                }
            }
            if !uniqueDivers.isEmpty {
                Divider()
                ForEach(uniqueDivers, id: \.self) { diver in
                    Button {
                        selectedDiver = diver
                    } label: {
                        if selectedDiver == diver {
                            Label(diver, systemImage: "checkmark")
                        } else {
                            Text(diver)
                        }
                    }
                }
            }
        } label: {
            if isActive {
                ZStack {
                    Circle()
                        .fill(Color.cyan)
                        .frame(width: 24, height: 24)
                    Text(DiverFilter.initials(for: selectedDiver))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.black)
                }
                .accessibilityHidden(true)
                .sheetToolbarIconOnMac(inSheet)
            } else {
                Image(systemName: "person.2")
                    .foregroundStyle(Color.cyan)
                    .sheetToolbarIconOnMac(inSheet)
            }
        }
        .accessibilityLabel(Self.accessibilityTitle(selectedDiver: selectedDiver))
        .help(isActive
            ? NSLocalizedString("Diver: ", bundle: Bundle.forAppLanguage(), comment: "") + selectedDiver
            : NSLocalizedString("Filter by diver", bundle: Bundle.forAppLanguage(), comment: ""))
    }
}

// MARK: - Main-Window Toolbar

/// Presents one of the app-wide sheets `MainTabView` owns (Settings, iCloud sync status).
/// Equatable and always equal: `MainTabView` creates a new one on every body pass, and its
/// closure always does the same thing, so readers need not redraw for it.
struct ShowSheetAction: Equatable {
    let action: () -> Void
    func callAsFunction() { action() }
    static func == (lhs: ShowSheetAction, rhs: ShowSheetAction) -> Bool { true }
}

extension EnvironmentValues {
    /// Presents Settings; set by `MainTabView` on its tabs.
    @Entry var showSettingsSheet: ShowSheetAction? = nil
    /// Presents the iCloud sync status; set by `MainTabView` on its tabs.
    @Entry var showSyncStatusSheet: ShowSheetAction? = nil
}

/// The toolbar of every tab root in the main window: the diver filter, Settings, iCloud sync
/// status and `leading` on the leading edge, the tab's own controls (`trailing`) on the trailing
/// edge. Each tab lists its controls once; the layout is chosen here:
/// - macOS: one ToolbarItemGroup per side, so each side shares one glass capsule as in the iOS
///   navigation bar, with no ⌄ indicator on the menus.
/// - iOS: the diver filter, Settings and iCloud as separate `.topBarLeading` items (not
///   `.navigation`, which SwiftUI re-flows to the trailing side when popping back from a pushed
///   view); `leading` in a `.topBarLeading` group and `trailing` in a `.primaryAction` group,
///   where each view is still its own bar item.
/// - iOS, toolbar in a side strip (`\.toolbarInSideStrip`, iPhone Duo): there iOS moves each
///   plain-icon item into the strip, which holds about four, and puts the rest in a system
///   overflow menu that drops image-only buttons. A single principal item stays in the top bar
///   (observed on the iPhone Duo simulator, iOS 27.1; not documented), so the same controls
///   share one row there, in two Liquid Glass capsules (`SideStripToolbarRow`). This is the
///   one exception to "one control per ToolbarItem": nothing overflows from this row.
struct MainWindowToolbar<Leading: View, Trailing: View>: ToolbarContent {
    let uniqueDivers: [String]
    @Binding var selectedDiver: String
    #if os(iOS)
    @Environment(\.toolbarInSideStrip) private var inSideStrip
    #endif
    private let leading: Leading
    private let trailing: Trailing

    init(uniqueDivers: [String], selectedDiver: Binding<String>,
         @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.uniqueDivers = uniqueDivers
        self._selectedDiver = selectedDiver
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some ToolbarContent {
        #if os(macOS)
        ToolbarItemGroup(placement: .navigation) {
            DiverFilterToolbar(uniqueDivers: uniqueDivers, selectedDiver: $selectedDiver).picker
                .toolbarMenuIndicatorHiddenOnMac()
            SettingsToolbarButton()
            CloudSyncToolbarButton()
            leading
                .toolbarMenuIndicatorHiddenOnMac()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            trailing
                .toolbarMenuIndicatorHiddenOnMac()
        }
        #else
        if inSideStrip {
            ToolbarItem(placement: .principalOutsideTabBar) {
                // As in the system toolbar, a long press shows each control enlarged, since the
                // row's icons keep their size at the accessibility text sizes.
                SideStripToolbarRow {
                    DiverFilterToolbar(uniqueDivers: uniqueDivers, selectedDiver: $selectedDiver).picker
                        // Its initials badge is hidden from accessibility: name the content.
                        .accessibilityShowsLargeContentViewer {
                            Label {
                                DiverFilterToolbar.accessibilityTitle(selectedDiver: selectedDiver)
                            } icon: {
                                Image(systemName: "person.2")
                            }
                        }
                    SettingsToolbarButton()
                        .accessibilityShowsLargeContentViewer()
                    CloudSyncToolbarButton()
                        .accessibilityShowsLargeContentViewer()
                    leading
                        .accessibilityShowsLargeContentViewer()
                } trailing: {
                    trailing
                        .accessibilityShowsLargeContentViewer()
                }
            }
        } else {
            DiverFilterToolbar(uniqueDivers: uniqueDivers, selectedDiver: $selectedDiver)
            ToolbarItem(placement: .topBarLeading) {
                SettingsToolbarButton()
            }
            ToolbarItem(placement: .topBarLeading) {
                CloudSyncToolbarButton()
            }
            // A group, not a shared HStack: each view stays its own bar item, so the toolbar
            // overflow can manage them one by one.
            ToolbarItemGroup(placement: .topBarLeading) {
                leading
            }
            ToolbarItemGroup(placement: .primaryAction) {
                trailing
            }
        }
        #endif
    }
}

extension MainWindowToolbar where Leading == EmptyView {
    init(uniqueDivers: [String], selectedDiver: Binding<String>, @ViewBuilder trailing: () -> Trailing) {
        self.init(uniqueDivers: uniqueDivers, selectedDiver: selectedDiver, leading: { EmptyView() }, trailing: trailing)
    }
}

#if os(iOS)
/// The side-strip row of `MainWindowToolbar`: two capsules, as wide as the search field
/// (`\.toolbarSideStripWidth`), pushed to its edges as in a navigation bar.
private struct SideStripToolbarRow<Leading: View, Trailing: View>: View {
    @Environment(\.toolbarSideStripWidth) private var width
    private let leading: Leading
    private let trailing: Trailing

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        let row = HStack {
            capsule(leading)
            Spacer(minLength: 12)
            capsule(trailing)
        }
        .frame(width: width > 0 ? width : nil)

        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer { row }
        } else {
            row
        }
    }

    private func capsule(_ content: some View) -> some View {
        HStack(spacing: 20) { content }
        // Toolbar icons do not grow with Dynamic Type; the row must fit the bar.
        .font(.system(size: 17))
        .padding(.horizontal, 14)
        .frame(height: 44)
        .sideStripCapsuleBackground()
    }
}

private extension View {
    /// Liquid Glass, as the system toolbar's capsules (iOS 26+; the strip is iOS 27).
    @ViewBuilder func sideStripCapsuleBackground() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(.regular.interactive())
        } else {
            background(.bar, in: Capsule())
        }
    }
}
#endif

/// Toolbar button that presents Settings (`\.showSettingsSheet`).
struct SettingsToolbarButton: View {
    @Environment(\.showSettingsSheet) private var showSettingsSheet

    var body: some View {
        Button { showSettingsSheet?() } label: {
            Image(systemName: "gear")
                .foregroundStyle(.cyan)
        }
        .help("Settings")
        .accessibilityLabel(Text("Settings"))
    }
}

/// Toolbar button showing the iCloud sync state; presents the sync status
/// (`\.showSyncStatusSheet`).
struct CloudSyncToolbarButton: View {
    @Environment(\.showSyncStatusSheet) private var showSyncStatusSheet
    @Environment(CloudKitSyncMonitor.self) private var syncMonitor
    @AppStorage(BlueDiveApp.iCloudSyncEnabledKey) private var iCloudSyncEnabled = true

    var body: some View {
        Button { showSyncStatusSheet?() } label: { icon }
            .help("iCloud Sync Status")
            .accessibilityLabel(Text("iCloud Sync Status"))
            // Set directly on the Button rather than on a descendant inside its label,
            // since it's undocumented whether SwiftUI promotes a descendant's
            // .accessibilityValue to the enclosing Button's own accessibility element.
            .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: Text {
        if !iCloudSyncEnabled {
            return Text("iCloud sync is turned off")
        } else if syncMonitor.isSyncing {
            return Text("Syncing")
        } else if syncMonitor.hasError {
            return Text("Sync error")
        } else if let d = syncMonitor.lastSyncDate, Date().timeIntervalSince(d) < 300 {
            return Text("Recently synced")
        } else {
            return Text("Idle")
        }
    }

    @ViewBuilder
    private var icon: some View {
        if !iCloudSyncEnabled {
            Image(systemName: "icloud.slash")
                .foregroundStyle(.secondary)
        } else if syncMonitor.isSyncing {
            // An animated symbol, not a ProgressView: macOS only shares a toolbar glass capsule
            // between items whose labels are plain images/text, so a ProgressView label would
            // split this button from the Settings/diver-filter group while syncing.
            Image(systemName: "arrow.clockwise.icloud")
                .foregroundStyle(.cyan)
                .symbolEffect(.pulse)
        } else if syncMonitor.hasError {
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(.orange)
        } else if let d = syncMonitor.lastSyncDate, Date().timeIntervalSince(d) < 300 {
            Image(systemName: "checkmark.icloud")
                .foregroundStyle(.cyan)
        } else {
            Image(systemName: "icloud")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Stale-Selection Reset

extension View {
    /// Clears `selectedDiver` when the persisted value no longer matches any
    /// available diver (e.g. after a delete, rename, or import).
    func diverFilterReset(uniqueDivers: [String], selectedDiver: Binding<String>) -> some View {
        // task(id:) fires asynchronously after SwiftUI's first render pass, ensuring all @Query
        // properties have populated before the stale-selection check runs.
        // The empty-list guard preserves a valid selection during CloudKit's initial sync
        // delay — the task fires again once data arrives and the check runs with real data.
        task(id: uniqueDivers) {
            guard !uniqueDivers.isEmpty else { return }
            if !selectedDiver.wrappedValue.isEmpty
                && !uniqueDivers.contains(selectedDiver.wrappedValue) {
                selectedDiver.wrappedValue = ""
            }
        }
    }
}

// MARK: - Autocomplete Field

/// Shared text field with inline autocomplete suggestions.
/// Used in add/edit forms wherever a diver name (or similar value) can be
/// populated from existing records. Pass `suggestionColor` to match the
/// surrounding card's accent colour (`.cyan` for certifications, `.blue` for insurance).
struct DiverAutocompleteField: View {
    let label: LocalizedStringKey
    var placeholder: LocalizedStringKey? = nil
    @Binding var text: String
    let suggestions: [String]
    var suggestionColor: Color = .cyan

    @State private var showSuggestions = false
    @State private var cachedFiltered: [String] = []
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            HStack {
                TextField(placeholder ?? label, text: $text)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onChange(of: text) {
                        cachedFiltered = text.isEmpty ? [] : suggestions.filter {
                            $0.localizedCaseInsensitiveContains(text) && $0.lowercased() != text.lowercased()
                        }
                        showSuggestions = isFocused && !cachedFiltered.isEmpty
                    }
                    .onChange(of: suggestions) {
                        cachedFiltered = text.isEmpty ? [] : suggestions.filter {
                            $0.localizedCaseInsensitiveContains(text) && $0.lowercased() != text.lowercased()
                        }
                        showSuggestions = isFocused && !cachedFiltered.isEmpty
                    }
                    .onChange(of: isFocused) {
                        if isFocused {
                            showSuggestions = !cachedFiltered.isEmpty
                        } else {
                            Task {
                                try? await Task.sleep(for: .seconds(0.2))
                                showSuggestions = false
                            }
                        }
                    }
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .clearButtonTapTarget()
                            .accessibilityLabel(Text("Clear"))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.06))
            )
            if showSuggestions && !cachedFiltered.isEmpty {
                ForEach(cachedFiltered.prefix(4), id: \.self) { suggestion in
                    Button {
                        text = suggestion
                        showSuggestions = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(suggestion)
                                .foregroundStyle(suggestionColor)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                        .padding(.leading, 8)
                        // The whole suggestion responds, not only its text (a plain Button only
                        // responds where something is drawn).
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Empty State

/// Consistent empty state shown when a filter excludes every record in a view.
/// `title`/`description` are stored as `Text` so a caller can interpolate a diver's name via
/// `Text(verbatim: String(format: NSLocalizedString(...), name))`. `Text` is not
/// `ExpressibleByStringLiteral`, so a second `LocalizedStringKey` initializer keeps plain
/// string-literal call sites (e.g. `title: "No Dives Recorded"`) compiling unchanged and still
/// localized. `actions` defaults to none, so every existing call site needs no changes.
struct NoEntriesForDiverView<Actions: View>: View {
    let title: Text
    let description: Text
    let actions: () -> Actions

    init(
        title: Text,
        description: Text,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.description = description
        self.actions = actions
    }

    /// Convenience overload for static, non-interpolated titles/descriptions. The
    /// `LocalizedStringKey` literals stay visible to Xcode's string-catalog extractor.
    init(
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.title = Text(title)
        self.description = Text(description)
        self.actions = actions
    }

    var body: some View {
        ContentUnavailableView {
            Label { title } icon: { Image(systemName: "person.slash") }
        } description: {
            description
        } actions: {
            actions()
        }
        #if os(macOS)
        // macOS sizes ContentUnavailableView to its content: fill the container so a sheet
        // keeps its page size and the screen's AppBackground covers it, as on iOS.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}
