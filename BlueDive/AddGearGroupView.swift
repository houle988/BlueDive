import SwiftUI
import SwiftData

struct AddGearGroupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Gear.name) private var allGear: [Gear]

    // MARK: - Form State

    @State private var name = ""
    @State private var selectedGearIds: Set<UUID> = []

    // Validation
    @State private var showValidationError = false
    @State private var validationMessage = ""

    // MARK: - Computed Properties

    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        name.count >= 2 &&
        !selectedGearIds.isEmpty
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Gear items grouped by category for the selection list.
    private var groupedGear: [(key: String, items: [Gear])] {
        let activeGear = allGear.filter { !$0.isInactive }
        let grouped = Dictionary(grouping: activeGear) { gear in
            GearCategory(rawValue: gear.category)?.rawValue ?? gear.category
        }
        return grouped.sorted { $0.key < $1.key }.map { (key: $0.key, items: $0.value) }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerSection
                    nameSection
                    gearSelectionSection

                    if !isFormValid && (!name.isEmpty || !selectedGearIds.isEmpty) {
                        validationSection
                    }
                }
                .padding()
            }
            #if os(macOS)
            .frame(minWidth: 500, idealWidth: 600, maxWidth: 750,
                   minHeight: 500, idealHeight: 700, maxHeight: 900)
            .background(Color(nsColor: .textBackgroundColor))
            #else
            .background(Color(.systemGroupedBackground))
            #endif
            .navigationTitle("New Group")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar { toolbarContent }
            .alert("Error", isPresented: $showValidationError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(LocalizedStringKey(validationMessage))
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 600, maxWidth: 750)
        #endif
    }

    // MARK: - View Components

    private var headerSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.2))
                    .frame(width: 80, height: 80)

                Image(systemName: "tray.2.fill")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(.orange)
            }

            Text("Create a gear group")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Select equipment items to group together for quick dive setup")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.vertical, 20)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "Group Name", icon: "tag")

            FormFieldView(
                label: "Name",
                icon: "tag.fill",
                placeholder: "e.g. Warm Water Kit, Tech Setup",
                text: $name
            )
        }
        .cardStyle()
    }

    private var gearSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeaderView(title: "Equipment", icon: "wrench.and.screwdriver.fill")
                Spacer()
                if !selectedGearIds.isEmpty {
                    Text("\(selectedGearIds.count) selected")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fontWeight(.semibold)
                }
            }

            if allGear.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No equipment in your inventory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Add equipment from the Equipment section first")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ForEach(groupedGear, id: \.key) { category, items in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(GearCategory(rawValue: category)?.localizedName ?? LocalizedStringKey(category))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)

                        ForEach(items) { gear in
                            gearSelectionRow(gear)
                        }
                    }
                }
            }
        }
        .cardStyle()
    }

    private func gearSelectionRow(_ gear: Gear) -> some View {
        let isSelected = selectedGearIds.contains(gear.id)
        let gearCategory = GearCategory(rawValue: gear.category)

        return Button {
            toggleGearSelection(gear)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(categoryColor(for: gearCategory).opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: gearCategory?.icon ?? "wrench.fill")
                        .font(.caption)
                        .foregroundStyle(categoryColor(for: gearCategory))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(gear.isInactive ? .red : .green)
                            .frame(width: 6, height: 6)
                        Text(gear.name)
                            .font(.subheadline)
                            .foregroundStyle(gear.isInactive ? .secondary : .primary)
                    }
                    HStack(spacing: 8) {
                        if let mfr = gear.manufacturer, !mfr.isEmpty {
                            Text(mfr)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Label("\(gear.totalDivesCount)", systemImage: "water.waves")
                            .font(.caption2)
                            .foregroundStyle(.cyan)
                    }
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .orange : .secondary)
                    .font(.title3)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private var validationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if name.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 && !name.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Group name must be at least 2 characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if selectedGearIds.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Select at least one equipment item")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(10)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") { saveGroup() }
                .disabled(!isFormValid)
                #if os(iOS)
                .fontWeight(.semibold)
                #endif
        }
    }

    // MARK: - Actions

    private func toggleGearSelection(_ gear: Gear) {
        if selectedGearIds.contains(gear.id) {
            selectedGearIds.remove(gear.id)
        } else {
            selectedGearIds.insert(gear.id)
        }
    }

    private func saveGroup() {
        guard isFormValid else {
            validationMessage = "Please enter a valid group name and select at least one equipment item."
            showValidationError = true
            return
        }

        let selectedGear = allGear.filter { selectedGearIds.contains($0.id) }
        let group = GearGroup(name: trimmedName, gear: selectedGear)

        withAnimation {
            modelContext.insert(group)
            try? modelContext.save()
        }
        dismiss()
    }

    // MARK: - Helpers

    private func categoryColor(for category: GearCategory?) -> Color {
        guard let category else { return .cyan }
        switch category.color {
        case "purple": return .purple
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "gray": return .gray
        case "cyan": return .cyan
        case "pink": return .pink
        case "indigo": return .indigo
        case "teal": return .teal
        case "mint": return .mint
        case "yellow": return .yellow
        case "red": return .red
        case "brown": return .brown
        default: return .cyan
        }
    }
}

// MARK: - Preview

#Preview {
    AddGearGroupView()
        .modelContainer(for: [Gear.self, GearGroup.self], inMemory: true)
}
