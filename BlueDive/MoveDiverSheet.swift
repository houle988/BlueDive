import SwiftUI
import SwiftData

struct MoveDiverSheet: View {
    let dive: Dive
    @Environment(DiveStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @State private var targetName: String
    @AppStorage("autoSequenceEnabled") private var autoSequenceEnabled = false
    let originalTrimmedName: String

    init(dive: Dive) {
        self.dive = dive
        let trimmed = dive.diverName.trimmingCharacters(in: .whitespaces)
        originalTrimmedName = trimmed
        _targetName = State(initialValue: trimmed)
    }

    private var resolvedName: String {
        targetName.trimmingCharacters(in: .whitespaces)
    }

    private var isUnchanged: Bool {
        resolvedName == originalTrimmedName
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground().ignoresSafeArea()

                Form {
                    diveSummarySection
                    selectDiverSection
                    newDiverSection
                }
                .groupedFormStyleOnMac()
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Move dive")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") { save() }
                        .bold()
                        .disabled(isUnchanged)
                }
            }
        }
    }

    // MARK: - Sections

    /// Identifies the dive being moved and the diver it currently belongs to.
    private var diveSummarySection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "location")
                    .foregroundStyle(.cyan)
                    .frame(width: 24)
                if dive.siteName.isEmpty {
                    Text("Unknown site")
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: dive.siteName)
                        .foregroundStyle(.primary)
                }
            }

            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .foregroundStyle(.indigo)
                    .frame(width: 24)
                Text(dive.timestamp, format: .dateTime.day().month().year().hour().minute().locale(locale))
                    .foregroundStyle(.primary)
            }

            HStack(spacing: 12) {
                Image(systemName: "person")
                    .foregroundStyle(.blue)
                    .frame(width: 24)
                Text("Current diver")
                    .foregroundStyle(.primary)
                Spacer()
                if originalTrimmedName.isEmpty {
                    Text("No diver")
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: originalTrimmedName)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            MenuSectionHeader(title: "Dive to move", icon: "water.waves", color: .blue)
        }
    }

    private var selectDiverSection: some View {
        Section {
            diverRow(icon: "person.slash", iconColor: .secondary, isSelected: resolvedName.isEmpty) {
                targetName = ""
            } title: {
                Text("No diver")
            }

            ForEach(store.cachedUniqueDivers, id: \.self) { name in
                diverRow(icon: "person", iconColor: .cyan, isSelected: resolvedName == name) {
                    targetName = name
                } title: {
                    Text(verbatim: name)
                }
            }
        } header: {
            MenuSectionHeader(title: "Select diver", icon: "person.2", color: .cyan)
        }
    }

    private var newDiverSection: some View {
        Section {
            MenuTextField(label: "Diver name", text: $targetName, icon: "person.badge.plus", color: .green)
                .autocorrectionDisabled()
                .platformTextInputAutocapitalization(.capitalizeWords)
        } header: {
            MenuSectionHeader(title: "Add new diver", icon: "person.badge.plus", color: .green)
        }
    }

    /// Selectable diver row laid out like the edit sheets' icon rows: a fixed-width
    /// coloured icon, the name, and a checkmark on the selected diver.
    private func diverRow<Title: View>(
        icon: String,
        iconColor: Color,
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder title: () -> Title
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .frame(width: 24)
                title()
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.cyan)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func save() {
        let originalDiverName = dive.diverName
        let newDiverName = resolvedName
        dive.diverName = newDiverName
        try? modelContext.save()
        if autoSequenceEnabled {
            store.recalcSequencesInBackground(
                container: modelContext.container,
                newDiverName: newDiverName,
                originalDiverName: originalDiverName
            )
        }
        store.commit(dive, affects: .list)
        dismiss()
    }
}
