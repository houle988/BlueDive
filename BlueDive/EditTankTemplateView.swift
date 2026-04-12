import SwiftUI
import SwiftData

// MARK: - Edit Tank Template View

struct EditTankTemplateView: View {
    @Bindable var template: TankTemplate
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // MARK: - Form State

    @State private var name: String
    @State private var volumeText: String
    @State private var workingPressureText: String
    @State private var material: String
    @State private var format: String
    @State private var manufacturerText: String
    @State private var modelText: String

    // Validation
    @State private var showValidationError = false
    @State private var validationMessage = ""

    private let materialOptions = ["Steel", "Galvanized Steel", "Aluminium", "Carbon"]
    private let formatOptions   = ["Single tank", "Twinset", "Sidemount", "Pony", "Rebreather", "Other"]

    // MARK: - Init

    init(template: TankTemplate) {
        self.template = template

        _name = State(initialValue: template.name)
        _volumeText = State(initialValue: template.volume.map { String(format: "%.1f", $0) } ?? "")
        _workingPressureText = State(initialValue: template.workingPressure.map { String(format: "%.0f", $0) } ?? "")
        _material = State(initialValue: template.material ?? "")
        _format = State(initialValue: template.format ?? "")
        _manufacturerText = State(initialValue: template.manufacturer ?? "")
        _modelText = State(initialValue: template.model ?? "")
    }

    // MARK: - Computed Properties

    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        name.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 &&
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
                        tankPropertiesSection
                        identificationSection

                        if !isFormValid && (!name.isEmpty || !workingPressureText.isEmpty) {
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
                   minHeight: 400, idealHeight: 550, maxHeight: 700)
            .background(Color.platformBackground.ignoresSafeArea())
            .navigationTitle("Edit Tank Template")

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
                        tankPropertiesSection
                        identificationSection

                        if !isFormValid && (!name.isEmpty || !workingPressureText.isEmpty) {
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
            .navigationTitle("Edit Tank Template")
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
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "cylinder.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.blue)
            }
            Text("Edit Tank Template")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
            Text("Update template information")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
        .padding(.bottom, 4)
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
                Label("Volume (\(template.storedVolumeUnit.symbol))", systemImage: "drop.fill")
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack {
                    TextField(template.storedVolumeUnit == .liters ? "e.g. 12.0" : "e.g. 80", text: $volumeText)
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
                    Label("Working Pressure (\(template.storedPressureUnit.symbol))", systemImage: "gauge.with.needle.fill")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("*")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }

                HStack {
                    TextField(template.storedPressureUnit == .bar ? "e.g. 232" : "e.g. 3000", text: $workingPressureText)
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

            Text("Units (\(template.storedVolumeUnit.symbol), \(template.storedPressureUnit.symbol)) match the format stored in the database and cannot be changed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                if parsedWorkingPressure == nil {
                    Text("Working pressure is required")
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

    // MARK: - Save

    private func saveChanges() {
        guard isFormValid else {
            validationMessage = "Please enter a valid template name (at least 2 characters)."
            showValidationError = true
            return
        }

        template.name = trimmedName
        template.volume = Double(volumeText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        template.workingPressure = Double(workingPressureText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        template.material = material.isEmpty ? nil : material
        template.format = format.isEmpty ? nil : format
        template.manufacturer = manufacturerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : manufacturerText.trimmingCharacters(in: .whitespacesAndNewlines)
        template.model = modelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : modelText.trimmingCharacters(in: .whitespacesAndNewlines)

        try? modelContext.save()
        dismiss()
    }
}

// MARK: - Preview

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: TankTemplate.self, configurations: config)
    let sample = TankTemplate(
        name: "AL80",
        volume: 11.1,
        workingPressure: 207,
        material: "Aluminium",
        format: "Single tank",
        manufacturer: "Catalina",
        model: "S80"
    )
    container.mainContext.insert(sample)
    return EditTankTemplateView(template: sample)
        .modelContainer(container)
}
