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
    @Environment(\.locale) private var locale

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
    @State private var gearNotes: String
    @State private var diverName: String

    // Validation
    @State private var showValidationError = false
    @State private var validationMessage = ""

    @Query(sort: \Gear.name) private var allGearItems: [Gear]
    @Query(sort: \Dive.timestamp) private var allDives: [Dive]
    @Query(sort: \Certification.issueDate) private var allCertifications: [Certification]
    @Query private var allInsurances: [DivingInsurance]

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
        _weightContributionText = State(initialValue: gear.weightContribution == 0 ? "0" : gear.weightContribution.editableString(decimals: 2))
        _weightContributionUnit = State(initialValue: gear.weightContributionUnit ?? UserPreferences.shared.weightUnit.symbol)
        _datePurchased = State(initialValue: gear.datePurchased)
        _manufacturerText = State(initialValue: gear.manufacturer ?? "")
        _modelText = State(initialValue: gear.model ?? "")
        _serialNumber = State(initialValue: gear.serialNumber ?? "")
        _purchasePrice = State(initialValue: gear.purchasePrice.map { $0.editableString(decimals: 2) } ?? "")
        _currency = State(initialValue: gear.currency ?? "CAD")
        _purchasedFrom = State(initialValue: gear.purchasedFrom ?? "")
        _isInactive = State(initialValue: gear.isInactive)
        _nextServiceDue = State(initialValue: gear.nextServiceDue ?? Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date())
        _showNextServiceDue = State(initialValue: gear.nextServiceDue != nil)
        _gearNotes = State(initialValue: gear.gearNotes ?? "")
        _diverName = State(initialValue: gear.diverName)
    }

    // MARK: - Computed Properties

    private var diverNameSuggestions: [String] {
        DiverFilter.uniqueDivers(in: allDives, gear: allGearItems, certifications: allCertifications, insurances: allInsurances)
    }

    @State private var manufacturerSuggestions: [String] = []

    private var modelSuggestions: [String] {
        var seen = Set<String>()
        return allGearItems.compactMap(\.model)
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .sorted()
    }

    private var purchasedFromSuggestions: [String] {
        var seen = Set<String>()
        return allGearItems.compactMap(\.purchasedFrom)
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .sorted()
    }

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
            .toolbar { toolbarContent }
            .alert("Error", isPresented: $showValidationError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(LocalizedStringKey(validationMessage))
            }
        }
        #if os(macOS)
        .frame(minWidth: 600, idealWidth: 650, maxWidth: 750)
        #endif
        .task { manufacturerSuggestions = GearIconView.manufacturerSuggestions(from: allGearItems) }
        .onChange(of: allGearItems) { manufacturerSuggestions = GearIconView.manufacturerSuggestions(from: allGearItems) }
    }

    // MARK: - View Components

    private var headerSection: some View {
        VStack(spacing: 12) {
            GearIconView(manufacturer: manufacturerText.isEmpty ? nil : manufacturerText, category: selectedCategory, size: 80)

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
                ForEach(GearCategory.sorted(for: locale)) { category in
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

    private func categoryColor(for category: GearCategory) -> Color {
        category.swiftUIColor
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

                GearAutocompleteField(
                    label: "Diver Name",
                    icon: "person.fill",
                    placeholder: "Diver Name (optional)",
                    text: $diverName,
                    suggestions: diverNameSuggestions
                )
            }
        }
        .cardStyle()
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeaderView(title: "Technical Details", icon: "doc.text")

            VStack(spacing: 12) {
                GearAutocompleteField(label: "Manufacturer", icon: "building.2", placeholder: "Ex: Shearwater", text: $manufacturerText, suggestions: manufacturerSuggestions, suggestionIcon: "building.2", useManufacturerIcon: true)

                GearAutocompleteField(label: "Model", icon: "tag", placeholder: "Ex: Perdix 2", text: $modelText, suggestions: modelSuggestions, suggestionIcon: "tag")

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
                    .adaptiveDatePickerStyle()
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
                            TextField(0.0.editableString(decimals: 2), text: $purchasePrice)
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
                GearAutocompleteField(
                    label: "Purchased from",
                    icon: "storefront",
                    placeholder: "Store name",
                    text: $purchasedFrom,
                    suggestions: purchasedFromSuggestions,
                    suggestionIcon: "storefront.fill"
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
                        .adaptiveDatePickerStyle()
                        .labelsHidden()
                        .padding()
                        .background(Color.platformSecondaryBackground)
                        .cornerRadius(10)
                    }
                    .transition(.scale.combined(with: .opacity))
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
                                Text(verbatim: weightContribution.localizedString(decimals: 2) + " \(weightContributionUnit)")
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

                            TextField(0.0.editableString(decimals: 1), text: $weightContributionText)
                                .platformKeyboardType(.decimalPad)
                                .textFieldStyle(.plain)
                                .padding()
                                .background(Color.platformSecondaryBackground)
                                .cornerRadius(10)
                                .onChange(of: weightContributionText) {
                                    weightContribution = parseFlexibleDouble(weightContributionText) ?? 0.0
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

        let priceValue = parseFlexibleDouble(purchasePrice)

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
        gear.diverName = diverName.trimmingCharacters(in: .whitespaces)
        
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
