import SwiftUI
import SwiftData

// MARK: - macOS Delete Sheet

#if os(macOS)
struct MacOSDeleteDiveSheet: View {
    let dives: [Dive]
    let onDelete: (Dive) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hoveredDiveId: PersistentIdentifier?
    @State private var searchText = ""

    private var filteredDives: [Dive] {
        if searchText.isEmpty { return dives }
        let query = searchText.lowercased()
        return dives.filter {
            $0.siteName.lowercased().contains(query) ||
            $0.location.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(.red.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: "trash")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.red)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete a dive")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("\(dives.count) dives in logbook")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }

                // Search field
                if dives.count > 5 {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Search dives…", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.subheadline)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.06))
                    )
                }
            }
            .padding()
            .background(Color.primary.opacity(0.03))

            Divider()
                .overlay(Color.primary.opacity(0.08))

            if dives.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No dives to display")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if filteredDives.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No matching dives")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredDives) { dive in
                            let isHovered = hoveredDiveId == dive.persistentModelID
                            HStack(spacing: 12) {
                                // Dive icon
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(.blue.opacity(0.12))
                                        .frame(width: 42, height: 42)
                                    Image(systemName: "water.waves")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.blue)
                                }

                                // Dive info
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(dive.siteName)
                                        .font(.system(.body, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    HStack(spacing: 6) {
                                        if !dive.location.isEmpty && dive.location != "Inconnu" && dive.location != String(localized: "Unknown") {
                                            Label(dive.location, systemImage: "mappin")
                                                .lineLimit(1)
                                        }
                                        Text("•")
                                        Text(dive.timestamp.formatted(date: .abbreviated, time: .omitted))
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                }

                                Spacer()

                                // Delete button
                                Button(role: .destructive) {
                                    onDelete(dive)
                                    dismiss()
                                } label: {
                                    Image(systemName: "trash.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.red)
                                        .padding(8)
                                        .background(
                                            Circle()
                                                .fill(.red.opacity(isHovered ? 0.2 : 0.1))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
                            )
                            .onHover { hovering in
                                hoveredDiveId = hovering ? dive.persistentModelID : nil
                            }
                            .padding(.horizontal, 4)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(minWidth: 460, idealWidth: 550, maxWidth: 700, minHeight: 360, idealHeight: 500, maxHeight: 700)
        .background(Color(NSColor.windowBackgroundColor))

    }
}
#endif
