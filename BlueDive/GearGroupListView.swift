import SwiftUI
import SwiftData

// MARK: - Gear Group List View

struct GearGroupListView: View {
    @Query(sort: \GearGroup.name) private var gearGroups: [GearGroup]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var showAddGearGroup = false
    @State private var selectedGearGroup: GearGroup?
    @State private var showDeleteConfirmation = false
    @State private var gearGroupToDelete: IndexSet?

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.platformBackground.ignoresSafeArea()

                if gearGroups.isEmpty {
                    ContentUnavailableView(
                        "No Gear Groups",
                        systemImage: "tray.2.fill",
                        description: Text("Create groups of equipment for quick dive setup. Select a group to add all its gear to a dive at once.")
                    )
                } else {
                    gearGroupList
                }
            }
            .navigationTitle("Gear Groups")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar { toolbarContent }
            .alert("Delete gear group?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { gearGroupToDelete = nil }
                Button("Delete", role: .destructive) {
                    if let offsets = gearGroupToDelete { confirmDeleteGearGroups(offsets: offsets) }
                    gearGroupToDelete = nil
                }
            } message: {
                Text("This action is irreversible. The gear group and its configuration will be permanently deleted.")
            }
            .sheet(isPresented: $showAddGearGroup) {
                AddGearGroupView()
                    #if os(iOS)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    #endif
            }
            .sheet(item: $selectedGearGroup) { group in
                EditGearGroupView(gearGroup: group)
                    #if os(iOS)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    #elseif os(macOS)
                    .frame(minWidth: 500, idealWidth: 600, maxWidth: 750,
                           minHeight: 500, idealHeight: 700, maxHeight: 900)
                    #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 650, maxWidth: 800,
               minHeight: 400, idealHeight: 600, maxHeight: 800)
        #endif
    }

    // MARK: - List

    private var gearGroupList: some View {
        List {
            ForEach(gearGroups) { group in
                Button {
                    selectedGearGroup = group
                } label: {
                    GearGroupRow(gearGroup: group)
                }
                .buttonStyle(.plain)
            }
            .onDelete(perform: deleteGearGroups)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showAddGearGroup = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.cyan)
            }
        }
    }

    // MARK: - Delete

    private func deleteGearGroups(at offsets: IndexSet) {
        gearGroupToDelete = offsets
        showDeleteConfirmation = true
    }

    private func confirmDeleteGearGroups(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(gearGroups[index])
            }
            try? modelContext.save()
        }
    }
}

// MARK: - Gear Group Row

struct GearGroupRow: View {
    let gearGroup: GearGroup

    var body: some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 44, height: 44)

                Image(systemName: "tray.2.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
            }

            // Details
            VStack(alignment: .leading, spacing: 4) {
                Text(gearGroup.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    let items = (gearGroup.gear ?? []).sorted { $0.name < $1.name }.prefix(3)
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Text(",")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Circle()
                            .fill(item.isInactive ? .red : .green)
                            .frame(width: 6, height: 6)
                        Text(item.name)
                            .font(.caption)
                            .foregroundStyle(item.isInactive ? .secondary : .primary)
                    }
                    if (gearGroup.gear ?? []).count > 3 {
                        Text("+\((gearGroup.gear ?? []).count - 3)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)

                Text("\(gearGroup.gearCount) items")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Preview

#Preview {
    GearGroupListView()
        .modelContainer(for: [GearGroup.self, Gear.self], inMemory: true)
}
