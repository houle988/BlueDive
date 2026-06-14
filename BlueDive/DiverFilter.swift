import SwiftUI

// MARK: - Diver Filter

/// Shared utilities for the per-view diver filter.
/// Centralizes the AppStorage key, the picker, and the "stale selection" reset
/// so every consumer view stays consistent.
enum DiverFilter {
    /// Single source of truth for the AppStorage key.
    static let storageKey = "selectedDiverFilter"

    /// Sorted, deduplicated list of non-empty diver names across dives, gear, and certifications.
    /// All parameters are optional so callers can pass only the sources they have.
    static func uniqueDivers(
        in dives: [Dive] = [],
        gear: [Gear] = [],
        certifications: [Certification] = []
    ) -> [String] {
        let names = dives.map { $0.diverName.trimmingCharacters(in: .whitespaces) }
            + gear.map { $0.diverName.trimmingCharacters(in: .whitespaces) }
            + certifications.map { $0.diverName.trimmingCharacters(in: .whitespaces) }
        return Array(Set(names.filter { !$0.isEmpty })).sorted()
    }

    /// Returns `dives` filtered to a single diver, or unchanged when no diver is selected.
    /// Trims stored names before comparison so they match the trimmed picker values.
    static func apply(_ selected: String, to dives: [Dive]) -> [Dive] {
        selected.isEmpty ? dives : dives.filter { $0.diverName.trimmingCharacters(in: .whitespaces) == selected }
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
        tag: String?,
        marineLife: [String], marineLifeMode: FilterMarineLifeMode
    ) -> [Dive] {
        dives.filter { dive in
            if let year = year {
                let diveYear = Calendar.current.component(.year, from: dive.timestamp)
                if yearNegate { if diveYear == year { return false } }
                else { if diveYear != year { return false } }
            }
            if let gas = gasType {
                if gas.isEmpty { if !dive.gasType.isEmpty { return false } }
                else if gasTypeNegate { if dive.gasType == gas { return false } }
                else { if dive.gasType != gas { return false } }
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
                    if !diveTags.contains(tag) { return false }
                }
            }
            if !diveMatchesMarineLifeFilter(dive, species: marineLife, mode: marineLifeMode) { return false }
            return true
        }
    }
}

// MARK: - Toolbar Picker

/// Drop-in toolbar item that exposes the diver filter on iOS and macOS.
/// Renders nothing when there are fewer than two divers (no choice to make).
struct DiverFilterToolbar: ToolbarContent {
    let uniqueDivers: [String]
    @Binding var selectedDiver: String

    var body: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) {
            if uniqueDivers.count > 1 { picker }
        }
        #else
        ToolbarItem(placement: .navigation) {
            if uniqueDivers.count > 1 { picker }
        }
        #endif
    }

    private var isActive: Bool { !selectedDiver.isEmpty }

    private var picker: some View {
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
        } label: {
            Image(systemName: isActive ? "person.fill.checkmark" : "person.2")
                .foregroundStyle(isActive ? Color.cyan : Color.secondary)
        }
        .accessibilityLabel(isActive
            ? Text("Filter by diver: \(selectedDiver)")
            : Text("Filter by diver"))
        .help(isActive
            ? NSLocalizedString("Diver: ", bundle: Bundle.forAppLanguage(), comment: "") + selectedDiver
            : NSLocalizedString("Filter by diver", bundle: Bundle.forAppLanguage(), comment: ""))
    }
}

// MARK: - Stale-Selection Reset

extension View {
    /// Clears `selectedDiver` when the persisted value no longer matches any
    /// available diver (e.g. after a delete, rename, or import).
    func diverFilterReset(uniqueDivers: [String], selectedDiver: Binding<String>) -> some View {
        onChange(of: uniqueDivers) {
            if !selectedDiver.wrappedValue.isEmpty
                && !uniqueDivers.contains(selectedDiver.wrappedValue) {
                selectedDiver.wrappedValue = ""
            }
        }
    }
}

// MARK: - Empty State

/// Consistent empty state shown when a filter excludes every record in a view.
struct NoEntriesForDiverView: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: "person.slash",
            description: Text(description)
        )
    }
}
