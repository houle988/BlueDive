import SwiftUI
import SwiftData

struct MoveDiverSheet: View {
    let dive: Dive
    @Environment(DiveStore.self) private var store
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var allGear: [Gear]
    @Query private var allCertifications: [Certification]
    @Query private var allInsurances: [DivingInsurance]

    @State private var targetName: String
    @State private var diverNames: [String] = []
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
            List {
                Section {
                    Button {
                        targetName = ""
                    } label: {
                        HStack {
                            Label {
                                Text("No diver")
                            } icon: {
                                Image(systemName: "person.slash")
                            }
                            .foregroundStyle(.primary)
                            Spacer()
                            if resolvedName.isEmpty {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.cyan)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    ForEach(diverNames, id: \.self) { name in
                        Button {
                            targetName = name
                        } label: {
                            HStack {
                                Label {
                                    Text(verbatim: name)
                                } icon: {
                                    Image(systemName: "person.fill")
                                }
                                .foregroundStyle(.primary)
                                Spacer()
                                if resolvedName == name {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.cyan)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Select diver")
                }

                Section {
                    TextField("Diver name", text: $targetName)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                        .padding(.trailing, targetName.isEmpty ? 0 : 24)
                        .overlay(alignment: .trailing) {
                            if !targetName.isEmpty {
                                Button {
                                    targetName = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                } header: {
                    Text("Add new diver")
                }
            }
            .navigationTitle("Move dive")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .onAppear {
                diverNames = DiverFilter.uniqueDivers(
                    in: store.dives,
                    gear: allGear,
                    certifications: allCertifications,
                    insurances: allInsurances
                )
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.cyan)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") { save() }
                        .foregroundStyle(.cyan)
                        .disabled(isUnchanged)
                }
            }
        }
    }

    private func save() {
        let originalDiverName = dive.diverName
        let newDiverName = resolvedName
        dive.diverName = newDiverName
        try? modelContext.save()
        store.recalcSurfaceIntervalsInBackground(
            container: modelContext.container,
            newDiverName: newDiverName,
            originalDiverName: originalDiverName
        )
        store.commit(dive, affects: .list)
        dismiss()
    }
}
