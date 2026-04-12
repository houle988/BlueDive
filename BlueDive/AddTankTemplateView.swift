import SwiftUI
import SwiftData

struct AddTankTemplateView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private let prefs = UserPreferences.shared

    // MARK: - Form State

    @State private var name = ""
    @State private var volumeText = ""
    @State private var workingPressureText = ""
    @State private var material = ""
    @State private var format = ""
    @State private var manufacturerText = ""
    @State private var modelText = ""

    // Validation
    @State private var showValidationError = false
    @State private var validationMessage = ""

    private let materialOptions = ["Steel", "Galvanized Steel", "Aluminium", "Carbon"]
    private let formatOptions   = ["Single tank", "Twinset", "Sidemount", "Pony", "Rebreather", "Other"]

    // MARK: - Computed Properties

    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        name.count >= 2 &&
        parsedWorkingPressure != nil
    }

    /// Parsed working pressure value, nil if empty or not a valid number.
    private var parsedWorkingPressure: Double? {
        let cleaned = workingPressureText.replacingOccurrences(of: ",", with: ".")
        guard let val = Double(cleaned), val > 0 else { return nil }
        return val
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerSection
                    nameSection
                    tankPropertiesSection
                    identificationSection

                    if !isFormValid && (!name.isEmpty || !workingPressureText.isEmpty) {
                        validationSection
                    }
                }
                .padding()
            }
            #if os(macOS)
            .frame(minWidth: 500, idealWidth: 600, maxWidth: 750,
                   minHeight: 400, idealHeight: 550, maxHeight: 700)
            .background(Color(nsColor: .textBackgroundColor))
            #else
            .background(Color(.systemGroupedBackground))
            #endif
            .navigationTitle("New Template")
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
                    .fill(Color.blue.opacity(0.2))
                    .frame(width: 80, height: 80)

                Image(systemName: "cylinder.fill")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(.blue)
            }

            Text("Add a new tank template")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Save your tank specs for quick reuse when logging dives")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.vertical, 20)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "Template Name", icon: "tag")

            FormFieldView(
                label: "Name",
                icon: "tag.fill",
                placeholder: "e.g. AL80, Steel HP100",
                text: $name
            )
        }
        .cardStyle()
    }

    private var tankPropertiesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "Tank Properties", icon: "cylinder.fill")

            // Volume
            VStack(alignment: .leading, spacing: 8) {
                Label("Volume (\(prefs.volumeUnit.symbol))", systemImage: "drop.fill")
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack {
                    TextField(prefs.volumeUnit == .liters ? "e.g. 12.0" : "e.g. 80", text: $volumeText)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    if !volumeText.isEmpty {
                        Button {
                            volumeText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                .background(Color.platformSecondaryBackground)
                .cornerRadius(10)
            }

            // Working Pressure (required)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Label("Working Pressure (\(prefs.pressureUnit.symbol))", systemImage: "gauge.with.needle.fill")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("*")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }

                HStack {
                    TextField(prefs.pressureUnit == .bar ? "e.g. 232" : "e.g. 3000", text: $workingPressureText)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                    if !workingPressureText.isEmpty {
                        Button {
                            workingPressureText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                .background(Color.platformSecondaryBackground)
                .cornerRadius(10)
            }

            // Material
            VStack(alignment: .leading, spacing: 8) {
                Label("Material", systemImage: "shield.fill")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Menu {
                    Button("—") { material = "" }
                    ForEach(materialOptions, id: \.self) { opt in
                        Button { material = opt } label: { Text(LocalizedStringKey(opt)) }
                    }
                } label: {
                    HStack {
                        Text(LocalizedStringKey(material.isEmpty ? "Select material..." : material))
                            .foregroundStyle(material.isEmpty ? .secondary : .primary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color.platformSecondaryBackground)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }

            // Format
            VStack(alignment: .leading, spacing: 8) {
                Label("Format", systemImage: "rectangle.stack.fill")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Menu {
                    Button("—") { format = "" }
                    ForEach(formatOptions, id: \.self) { opt in
                        Button { format = opt } label: { Text(LocalizedStringKey(opt)) }
                    }
                } label: {
                    HStack {
                        Text(LocalizedStringKey(format.isEmpty ? "Select format..." : format))
                            .foregroundStyle(format.isEmpty ? .secondary : .primary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(Color.platformSecondaryBackground)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .cardStyle()
    }

    private var identificationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "Identification", icon: "building.2")

            FormFieldView(
                label: "Manufacturer",
                icon: "building.2.fill",
                placeholder: "e.g. Aqualung, Faber",
                text: $manufacturerText
            )

            FormFieldView(
                label: "Model",
                icon: "tag.fill",
                placeholder: "e.g. Calypso, FX Series",
                text: $modelText
            )
        }
        .cardStyle()
    }

    private var validationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if name.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 && !name.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Template name must be at least 2 characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !workingPressureText.isEmpty && parsedWorkingPressure == nil {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Working pressure must be a valid number")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if workingPressureText.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Working pressure is required")
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
            Button("Save") { saveTemplate() }
                .disabled(!isFormValid)
                #if os(iOS)
                .fontWeight(.semibold)
                #endif
        }
    }

    // MARK: - Save

    private func saveTemplate() {
        guard isFormValid else {
            validationMessage = "Please enter a valid template name (at least 2 characters)."
            showValidationError = true
            return
        }

        let template = TankTemplate(
            name: trimmedName,
            volume: Double(volumeText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
            workingPressure: Double(workingPressureText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
            volumeUnit: prefs.volumeUnit.rawValue,
            pressureUnit: prefs.pressureUnit.rawValue,
            material: material.isEmpty ? nil : material,
            format: format.isEmpty ? nil : format,
            manufacturer: manufacturerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : manufacturerText.trimmingCharacters(in: .whitespacesAndNewlines),
            model: modelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        withAnimation {
            modelContext.insert(template)
            try? modelContext.save()
        }
        dismiss()
    }
}

// MARK: - Preview

#Preview {
    AddTankTemplateView()
        .modelContainer(for: TankTemplate.self, inMemory: true)
}
