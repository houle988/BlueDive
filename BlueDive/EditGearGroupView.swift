import SwiftUI
import SwiftData

// MARK: - Edit Gear Group View

struct EditGearGroupView: View {
    @Bindable var gearGroup: GearGroup
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Gear.name) private var allGear: [Gear]

    // MARK: - Form State

    @State private var name: String
    @State private var selectedGearIds: Set<UUID>

    // Validation
    @State private var showValidationError = false
    @State private var validationMessage = ""

    // MARK: - Init

    init(gearGroup: GearGroup) {
        self.gearGroup = gearGroup
        _name = State(initialValue: gearGroup.name)
        _selectedGearIds = State(initialValue: Set((gearGroup.gear ?? []).map { $0.id }))
    }

    // MARK: - Computed Properties

    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        name.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 &&
        !selectedGearIds.isEmpty
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Gear items grouped by category for the selection list.
    /// Shows active gear + any inactive gear already in the group.
    private var groupedGear: [(key: String, items: [Gear])] {
        let visibleGear = allGear.filter { !$0.isInactive || selectedGearIds.contains($0.id) }
        let grouped = Dictionary(grouping: visibleGear) { gear in
            GearCategory(rawValue: gear.category)?.rawValue ?? gear.category
        }
        return grouped.sorted { $0.key < $1.key }.map { (key: $0.key, items: $0.value) }
    }

    // MARK: - Body

    var body: some View {
        #if os(macOS)
        macOSLayout
        #else
        iOSLayout
        #endif
    }

    // MARK: - Platform Layouts

    #if os(macOS)
    private var macOSLayout: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 20) {
                        headerSection
                        nameSection
                        gearSelectionSection

                        if !isFormValid && (!name.isEmpty || !selectedGearIds.isEmpty) {
                            validationSection
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 16)
                }

                Divider().overlay(Color.primary.opacity(0.08))

                // Bottom bar
                HStack {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.escape)
                    Spacer()
                    Button {
                        saveChanges()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Save")
                        }
                        .fontWeight(.semibold)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(isFormValid ? .cyan : .cyan.opacity(0.3))
                        )
                        .foregroundStyle(isFormValid ? .black : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isFormValid)
                    .keyboardShortcut(.return)
                }
                .padding()
            }
            .frame(minWidth: 500, idealWidth: 600, maxWidth: 750,
                   minHeight: 500, idealHeight: 700, maxHeight: 900)
            .background(Color.platformBackground.ignoresSafeArea())
            .navigationTitle("Edit Gear Group")

            .alert("Error", isPresented: $showValidationError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(LocalizedStringKey(validationMessage))
            }
        }
    }
    #endif

    #if os(iOS)
    private var iOSLayout: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 20) {
                        headerSection
                        nameSection
                        gearSelectionSection

                        if !isFormValid && (!name.isEmpty || !selectedGearIds.isEmpty) {
                            validationSection
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 16)
                }

                // Bottom bar
                HStack {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.primary)
                    Spacer()
                    Button {
                        saveChanges()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Save")
                        }
                        .fontWeight(.semibold)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(isFormValid ? .cyan : .cyan.opacity(0.3))
                        )
                        .foregroundStyle(isFormValid ? .black : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isFormValid)
                }
                .padding()
                .background(Color.platformSecondaryBackground)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Edit Gear Group")
            .navigationBarTitleDisplayMode(.inline)

            .alert("Error", isPresented: $showValidationError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(LocalizedStringKey(validationMessage))
            }
        }
    }
    #endif

    // MARK: - View Components

    private var headerSection: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "tray.2.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
            }
            Text("Edit Gear Group")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
            Text("Update group information")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
        .padding(.bottom, 4)
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
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Validation required")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                if name.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                    Text("The name must contain at least 2 characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if selectedGearIds.isEmpty {
                    Text("Select at least one equipment item")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Actions

    private func toggleGearSelection(_ gear: Gear) {
        if selectedGearIds.contains(gear.id) {
            selectedGearIds.remove(gear.id)
        } else {
            selectedGearIds.insert(gear.id)
        }
    }

    // MARK: - Save

    private func saveChanges() {
        guard isFormValid else {
            validationMessage = "Please enter a valid group name and select at least one equipment item."
            showValidationError = true
            return
        }

        gearGroup.name = trimmedName
        gearGroup.gear = allGear.filter { selectedGearIds.contains($0.id) }

        try? modelContext.save()
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
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: GearGroup.self, Gear.self, configurations: config)
    let sample = GearGroup(name: "Warm Water Kit")
    container.mainContext.insert(sample)
    return EditGearGroupView(gearGroup: sample)
        .modelContainer(container)
}
