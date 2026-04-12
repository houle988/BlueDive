import SwiftUI
import SwiftData

// MARK: - Edit Gear View

/// Allows editing all properties of an existing `Gear` item.
/// Pre-fills every field from the provided `gear` object and writes
/// changes back to SwiftData on save.
struct EditGearView: View {
    @Bindable var gear: Gear
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // MARK: - Form State (mirrors AddGearView fields)

    @State private var name: String
    @State private var selectedCategory: GearCategory
    @State private var weightContribution: Double
    @State private var weightContributionText: String
    @State private var weightContributionUnit: String
    @State private var datePurchased: Date

    // Details
    @State private var manufacturerText: String
    @State private var modelText: String
    @State private var serialNumber: String
    @State private var purchasePrice: String
    @State private var currency: String
    @State private var purchasedFrom: String

    // Status
    @State private var isInactive: Bool

    // Service
    @State private var nextServiceDue: Date
    @State private var showNextServiceDue: Bool
    @State private var serviceHistory: String
    @State private var gearNotes: String

    // Validation
    @State private var showValidationError = false
    @State private var validationMessage = ""

    private let currencies = ["CAD", "USD", "EUR", "GBP", "CHF", "AUD", "JPY", "Other"]

    // MARK: - Init

    init(gear: Gear) {
        self.gear = gear

        // Seed all state from the existing Gear object
        _name = State(initialValue: gear.name)
        _selectedCategory = State(
            initialValue: GearCategory.allCases.first { $0.rawValue == gear.category } ?? .other
        )
        _weightContribution = State(initialValue: gear.weightContribution)
        _weightContributionText = State(initialValue: gear.weightContribution == 0 ? "0" : String(gear.weightContribution))
        _weightContributionUnit = State(initialValue: gear.weightContributionUnit ?? UserPreferences.shared.weightUnit.symbol)
        _datePurchased = State(initialValue: gear.datePurchased)
        _manufacturerText = State(initialValue: gear.manufacturer ?? "")
        _modelText = State(initialValue: gear.model ?? "")
        _serialNumber = State(initialValue: gear.serialNumber ?? "")
        _purchasePrice = State(initialValue: gear.purchasePrice.map {
            String(format: "%.2f", $0)
        } ?? "")
        _currency = State(initialValue: gear.currency ?? "CAD")
        _purchasedFrom = State(initialValue: gear.purchasedFrom ?? "")
        _isInactive = State(initialValue: gear.isInactive)
        _nextServiceDue = State(initialValue: gear.nextServiceDue ?? Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date())
        _showNextServiceDue = State(initialValue: gear.nextServiceDue != nil)
        _serviceHistory = State(initialValue: gear.serviceHistory ?? "")
        _gearNotes = State(initialValue: gear.gearNotes ?? "")
    }

    // MARK: - Computed Properties

    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        name.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
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
                    categorySelectionSection
                    basicInfoSection
                    detailsSection

                    purchaseSection
                    serviceSection
                    notesSection

                    if !isFormValid && !name.isEmpty {
                        validationSection
                    }
                }
                .padding()
            }
            #if os(macOS)
            .frame(minWidth: 600, idealWidth: 650, maxWidth: 750, minHeight: 500, idealHeight: 650, maxHeight: 900)
            .background(Color(nsColor: .textBackgroundColor))
            #else
            .background(Color(.systemGroupedBackground))
            #endif
            .navigationTitle("Edit Equipment")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar { toolbarContent }
            .alert("Error", isPresented: $showValidationError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(validationMessage)
            }
        }
        #if os(macOS)
        .frame(minWidth: 600, idealWidth: 650, maxWidth: 750)
        #endif
    }

    // MARK: - View Components

    private var headerSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(categoryColor(for: selectedCategory).opacity(0.2))
                    .frame(width: 80, height: 80)

                Image(systemName: selectedCategory.icon)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(categoryColor(for: selectedCategory))
            }

            Text("Edit Equipment")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Update the information for this equipment")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.vertical, 20)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                dismiss()
            } label: {
                Text("Cancel")
            }
        }

        ToolbarItem(placement: .confirmationAction) {
            Button {
                saveChanges()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Save")
                }
                .fontWeight(.semibold)
            }
            .disabled(!isFormValid)
            #if os(iOS)
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            #endif
        }
    }

    // MARK: - Sections

    private var categorySelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "Category", icon: "list.bullet")

            Menu {
                ForEach(GearCategory.allCases) { category in
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            selectedCategory = category
                        }
                    } label: {
                        Label(category.localizedName, systemImage: category.icon)
                    }
                }
            } label: {
                HStack {
                    Image(systemName: selectedCategory.icon)
                        .foregroundStyle(categoryColor(for: selectedCategory))
                        .font(.title3)

                    Text(selectedCategory.localizedName)
                        .fontWeight(.medium)

                    Spacer()

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color.platformSecondaryBackground)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
        }
        .cardStyle()
    }

    /// Helper to get color for a category
    private func categoryColor(for category: GearCategory) -> Color {
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

    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeaderView(title: "Main Information", icon: "info.circle")

            VStack(spacing: 12) {
                // Name
                VStack(alignment: .leading, spacing: 6) {
                    Text("Equipment name")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)

                    HStack {
                        Image(systemName: selectedCategory.icon)
                            .foregroundStyle(categoryColor(for: selectedCategory))
                            .font(.title3)
                            .frame(width: 30)

                        TextField("Ex: My 5mm wetsuit", text: $name)
                            .platformTextInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .textFieldStyle(.plain)

                        if !name.isEmpty {
                            Button {
                                withAnimation {
                                    name = ""
                                }
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

                if !name.isEmpty {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Overview: \(trimmedName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .cardStyle()
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeaderView(title: "Technical Details", icon: "doc.text")

            VStack(spacing: 12) {
                FormFieldView(label: "Manufacturer", icon: "building.2", placeholder: "Ex: Shearwater", text: $manufacturerText)

                FormFieldView(label: "Model", icon: "tag", placeholder: "Ex: Perdix 2", text: $modelText)

                FormFieldView(label: "Serial number", icon: "number", placeholder: "Ex: SN123456", text: $serialNumber)
                    .platformKeyboardType(.asciiCapable)
            }
        }
        .cardStyle()
    }

    private var purchaseSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeaderView(title: "Purchase Information", icon: "cart")

            VStack(spacing: 12) {
                // Purchase date
                VStack(alignment: .leading, spacing: 8) {
                    Label("Purchase date", systemImage: "calendar")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    DatePicker(
                        "",
                        selection: $datePurchased,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .padding()
                    .background(Color.platformSecondaryBackground)
                    .cornerRadius(10)
                }

                // Price and currency
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Price", systemImage: "dollarsign.circle")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        HStack {
                            TextField("0.00", text: $purchasePrice)
                                .platformKeyboardType(.decimalPad)
                                .textFieldStyle(.plain)
                            if !purchasePrice.isEmpty {
                                Button {
                                    purchasePrice = ""
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
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Currency")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Menu {
                            ForEach(currencies, id: \.self) { curr in
                                Button(curr) {
                                    currency = curr
                                }
                            }
                        } label: {
                            HStack {
                                Text(LocalizedStringKey(currency))
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                            .background(Color.platformSecondaryBackground)
                            .cornerRadius(10)
                            .frame(width: 100)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Store
                FormFieldView(
                    label: "Purchased from",
                    icon: "storefront",
                    placeholder: "Store name",
                    text: $purchasedFrom
                )
            }
        }
        .cardStyle()
    }

    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeaderView(title: "Maintenance", icon: "wrench.and.screwdriver")

            VStack(spacing: 12) {
                // Inactive toggle
                Toggle(isOn: $isInactive) {
                    HStack {
                        Image(systemName: "archivebox")
                            .foregroundStyle(.red)
                        Text("Inactive Equipment")
                            .fontWeight(.medium)
                    }
                }
                .toggleStyle(.switch)
                .padding()
                .background(Color.platformSecondaryBackground)
                .cornerRadius(10)

                // Toggle for next service
                Toggle(isOn: $showNextServiceDue) {
                    HStack {
                        Image(systemName: "calendar.badge.clock")
                            .foregroundStyle(.orange)
                        Text("Set a maintenance reminder")
                            .fontWeight(.medium)
                    }
                }
                .toggleStyle(.switch)
                .padding()
                .background(Color.platformSecondaryBackground)
                .cornerRadius(10)

                if showNextServiceDue {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Planned date", systemImage: "calendar")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        DatePicker(
                            "",
                            selection: $nextServiceDue,
                            displayedComponents: .date
                        )
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .padding()
                        .background(Color.platformSecondaryBackground)
                        .cornerRadius(10)
                    }
                    .transition(.scale.combined(with: .opacity))
                }

                // Service history
                VStack(alignment: .leading, spacing: 8) {
                    Label("Service history", systemImage: "list.bullet.clipboard")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    TextField("Service notes...", text: $serviceHistory, axis: .vertical)
                        .lineLimit(3...6)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .padding()
                        .background(Color.platformSecondaryBackground)
                        .cornerRadius(10)
                }
            }
        }
        .cardStyle()
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeaderView(title: "Notes & Weight", icon: "note.text")

            VStack(spacing: 12) {
                // Weight
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Associated weight", systemImage: "scalemass")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Group {
                            if weightContribution == 0 {
                                Text("None")
                            } else {
                                Text("\(weightContribution, specifier: "%.2f") \(weightContributionUnit)")
                            }
                        }
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(weightContribution > 0 ? .cyan : .secondary)
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Weight")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextField("0.0", text: $weightContributionText)
                                .platformKeyboardType(.decimalPad)
                                .textFieldStyle(.plain)
                                .padding()
                                .background(Color.platformSecondaryBackground)
                                .cornerRadius(10)
                                .onChange(of: weightContributionText) {
                                    let normalized = weightContributionText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                                    weightContribution = Double(normalized) ?? 0.0
                                }
                        }
                        .frame(maxWidth: .infinity)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Unit")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Menu {
                                Button("kg") { weightContributionUnit = "kg" }
                                Button("lb") { weightContributionUnit = "lb" }
                            } label: {
                                HStack {
                                    Text(weightContributionUnit)
                                        .font(.body)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.platformSecondaryBackground)
                                .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(width: 80)
                    }

                    if weightContribution > 0 {
                        Button {
                            withAnimation {
                                weightContribution = 0.0
                            }
                        } label: {
                            Label("Remove weight", systemImage: "xmark.circle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                .background(Color.platformSecondaryBackground)
                .cornerRadius(10)

                // Notes
                VStack(alignment: .leading, spacing: 8) {
                    Label("Personal notes", systemImage: "note.text")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    TextField("Add your notes about this equipment", text: $gearNotes, axis: .vertical)
                        .lineLimit(4...8)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .padding()
                        .background(Color.platformSecondaryBackground)
                        .cornerRadius(10)
                }
            }
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
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("The name must contain at least 2 characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    // MARK: - Save

    private func saveChanges() {
        guard isFormValid else {
            validationMessage = "Please fill in all required fields correctly."
            showValidationError = true
            return
        }

        let priceValue = Double(purchasePrice.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))

        gear.name = trimmedName
        gear.category = selectedCategory.rawValue
        gear.manufacturer = manufacturerText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : manufacturerText.trimmingCharacters(in: .whitespaces)
        gear.model = modelText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : modelText.trimmingCharacters(in: .whitespaces)
        gear.serialNumber = serialNumber.trimmingCharacters(in: .whitespaces).isEmpty ? nil : serialNumber.trimmingCharacters(in: .whitespaces)
        gear.datePurchased = datePurchased
        gear.purchasePrice = priceValue
        gear.currency = priceValue != nil ? currency : nil
        gear.purchasedFrom = purchasedFrom.trimmingCharacters(in: .whitespaces).isEmpty ? nil : purchasedFrom.trimmingCharacters(in: .whitespaces)
        gear.weightContribution = weightContribution
        gear.weightContributionUnit = weightContributionUnit
        gear.isInactive = isInactive
        
        // Mise à jour de la date d'entretien et programmation de notification
        let hadServiceDate = gear.nextServiceDue != nil
        gear.nextServiceDue = showNextServiceDue ? nextServiceDue : nil
        
        // Si l'utilisateur a défini une nouvelle date d'entretien, programmer la notification
        if showNextServiceDue && gear.nextServiceDue != nil {
            gear.scheduleMaintenanceReminder()
        } else if hadServiceDate && !showNextServiceDue {
            // Si l'utilisateur a supprimé la date d'entretien, annuler la notification
            NotificationManager.shared.cancelNotification(identifier: "gear-\(gear.id.uuidString)")
        }
        
        gear.serviceHistory = serviceHistory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : serviceHistory.trimmingCharacters(in: .whitespacesAndNewlines)
        gear.gearNotes = gearNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : gearNotes.trimmingCharacters(in: .whitespacesAndNewlines)

        try? modelContext.save()
        dismiss()
    }
}

// MARK: - Preview

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Gear.self, configurations: config)
    let sampleGear = Gear(
        name: "Bare Trilam Tech Dry",
        category: GearCategory.drysuit.rawValue,
        datePurchased: Calendar.current.date(byAdding: .month, value: -4, to: Date()) ?? Date(),
        weightContribution: 0.5,
        weightContributionUnit: "kg"
    )
    container.mainContext.insert(sampleGear)
    return EditGearView(gear: sampleGear)
        .modelContainer(container)
        .frame(minWidth: 560, minHeight: 600)
}
