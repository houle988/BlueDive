import SwiftUI
import SwiftData

// MARK: - Tank Template List View

struct TankTemplateListView: View {
    @Query(sort: \TankTemplate.name) private var templates: [TankTemplate]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var showAddTemplate = false
    @State private var selectedTemplate: TankTemplate?
    @State private var showDeleteConfirmation = false
    @State private var templateToDelete: IndexSet?

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                Color.platformBackground.ignoresSafeArea()

                if templates.isEmpty {
                    ContentUnavailableView(
                        "No Tank Templates",
                        systemImage: "cylinder.fill",
                        description: Text("Create templates for your frequently used tanks to quickly fill in tank details when logging dives.")
                    )
                } else {
                    templateList
                }
            }
            .navigationTitle("Tank Templates")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar { toolbarContent }
            .alert("Delete tank template?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { templateToDelete = nil }
                Button("Delete", role: .destructive) {
                    if let offsets = templateToDelete { confirmDeleteTemplates(offsets: offsets) }
                    templateToDelete = nil
                }
            } message: {
                Text("This action is irreversible. The tank template will be permanently deleted.")
            }
            .sheet(isPresented: $showAddTemplate) {
                AddTankTemplateView()
                    #if os(iOS)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    #endif
            }
            .sheet(item: $selectedTemplate) { template in
                EditTankTemplateView(template: template)
                    #if os(iOS)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    #elseif os(macOS)
                    .frame(minWidth: 500, idealWidth: 600, maxWidth: 750,
                           minHeight: 400, idealHeight: 550, maxHeight: 700)
                    #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 650, maxWidth: 800,
               minHeight: 400, idealHeight: 600, maxHeight: 800)
        #endif
    }

    // MARK: - Template List

    private var templateList: some View {
        List {
            ForEach(templates) { template in
                Button {
                    selectedTemplate = template
                } label: {
                    TankTemplateRow(template: template)
                }
                .buttonStyle(.plain)
            }
            .onDelete(perform: deleteTemplates)
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
                showAddTemplate = true
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.cyan)
            }
        }
    }

    // MARK: - Delete

    private func deleteTemplates(at offsets: IndexSet) {
        templateToDelete = offsets
        showDeleteConfirmation = true
    }

    private func confirmDeleteTemplates(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(templates[index])
            }
            try? modelContext.save()
        }
    }
}

// MARK: - Tank Template Row

struct TankTemplateRow: View {
    let template: TankTemplate

    var body: some View {
        HStack(spacing: 14) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 44, height: 44)

                Image(systemName: "cylinder.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }

            // Details
            VStack(alignment: .leading, spacing: 4) {
                Text(template.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(LocalizedStringKey(template.summaryDescription))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let mfrModel = template.manufacturerAndModel {
                    Text(mfrModel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
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
    TankTemplateListView()
        .modelContainer(for: TankTemplate.self, inMemory: true)
}
