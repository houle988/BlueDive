import SwiftUI

// MARK: - Diver Filter

/// Shared utilities for the per-view diver filter.
/// Centralizes the AppStorage key, the picker, and the "stale selection" reset
/// so every consumer view stays consistent.
enum DiverFilter {
    /// Single source of truth for the AppStorage key.
    static let storageKey = "selectedDiverFilter"

    /// Sorted, deduplicated list of non-empty diver names from a dive collection.
    static func uniqueDivers(in dives: [Dive]) -> [String] {
        Array(Set(dives.map(\.diverName).filter { !$0.isEmpty })).sorted()
    }

    /// Returns `dives` filtered to a single diver, or unchanged when no diver is selected.
    static func apply(_ selected: String, to dives: [Dive]) -> [Dive] {
        selected.isEmpty ? dives : dives.filter { $0.diverName == selected }
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
        Picker(selection: $selectedDiver) {
            Text("All Divers").tag("")
            ForEach(uniqueDivers, id: \.self) { diver in
                Text(diver).tag(diver)
            }
        } label: {
            Label(
                isActive ? selectedDiver : String(localized: "All Divers"),
                systemImage: isActive ? "person.fill.checkmark" : "person.2"
            )
            .foregroundStyle(isActive ? Color.cyan : Color.secondary)
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel(Text("Filter by diver"))
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
