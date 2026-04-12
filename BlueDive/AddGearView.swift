import SwiftUI
import SwiftData

struct AddGearView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    // MARK: - Form State
    
    @State private var name = ""
    @State private var selectedCategory: GearCategory = .suit
    @State private var weightContribution: Double = 0.0
    @State private var weightContributionText: String = "0"
    @State private var weightContributionUnit: String = UserPreferences.shared.weightUnit.symbol
    @State private var datePurchased = Date()
    
    // New fields
    @State private var manufacturerText = ""
    @State private var modelText = ""
    @State private var serialNumber = ""
    @State private var purchasePrice = ""
    @State private var currency = "CAD"
    @State private var purchasedFrom = ""
    @State private var nextServiceDue: Date = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
    @State private var showNextServiceDue = false
    @State private var serviceHistory = ""
    @State private var gearNotes = ""
    
    // Validation state
    @State private var showValidationError = false
    @State private var validationMessage = ""
    
    // Available currencies
    private let currencies = ["CAD", "USD", "EUR", "GBP", "CHF", "AUD", "JPY", "Other"]
    
    // MARK: - Computed Properties
    
    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        name.count >= 2
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
            .navigationTitle("New Equipment")
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
            
            Text("Add new equipment")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Fill in the information to add this equipment to your inventory")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.vertical, 20)
    }
    
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
    
    private var weightAndPurchaseSection: some View {
        Section {
            // Weight
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Associated weight", systemImage: "scalemass")
                    Spacer()
                    Group {
                        if weightContribution == 0 {
                            Text("None")
                        } else {
                            Text("\(weightContribution, specifier: "%.2f") kg")
                        }
                    }
                        .foregroundStyle(.cyan)
                        .fontWeight(.semibold)
                }
                
                if weightContribution > 0 {
                    Slider(value: $weightContribution, in: 0...15, step: 0.5) {
                        Text("Weight")
                    } minimumValueLabel: {
                        Text("0")
                            .font(.caption2)
                    } maximumValueLabel: {
                        Text("15")
                            .font(.caption2)
                    }
                    .tint(.cyan)
                } else {
                    Button {
                        withAnimation {
                            weightContribution = 2.0
                        }
                    } label: {
                        Text("Add weight")
                            .font(.caption)
                            .foregroundStyle(.cyan)
                    }
                }
            }
            .padding(.vertical, 4)
            
            // Purchase date
            DatePicker(
                selection: $datePurchased,
                in: ...Date(),
                displayedComponents: .date
            ) {
                Label("Purchase date", systemImage: "calendar")
            }
        } header: {
            Text("Configuration")
        } footer: {
            if weightContribution > 0 {
                Text("This will be used to calculate your optimal weight.")
                    .font(.caption)
            }
        }
    }
    
    private var serviceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeaderView(title: "Maintenance", icon: "wrench.and.screwdriver")
            
            VStack(spacing: 12) {
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
                saveGear()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Add")
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
    
    // MARK: - Actions
    
    private func saveGear() {
        guard isFormValid else {
            validationMessage = "Please fill in all required fields correctly."
            showValidationError = true
            return
        }
        
        let priceValue = Double(purchasePrice.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        
        let newGear = Gear(
            name: trimmedName,
            category: selectedCategory.rawValue,
            manufacturer: manufacturerText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : manufacturerText.trimmingCharacters(in: .whitespaces),
            model: modelText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : modelText.trimmingCharacters(in: .whitespaces),
            serialNumber: serialNumber.trimmingCharacters(in: .whitespaces).isEmpty ? nil : serialNumber.trimmingCharacters(in: .whitespaces),
            datePurchased: datePurchased,
            purchasePrice: priceValue,
            currency: priceValue != nil ? currency : nil,
            purchasedFrom: purchasedFrom.trimmingCharacters(in: .whitespaces).isEmpty ? nil : purchasedFrom.trimmingCharacters(in: .whitespaces),
            weightContribution: weightContribution,
            weightContributionUnit: weightContributionUnit,
            nextServiceDue: showNextServiceDue ? nextServiceDue : nil,
            serviceHistory: serviceHistory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : serviceHistory.trimmingCharacters(in: .whitespacesAndNewlines),
            gearNotes: gearNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : gearNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        
        withAnimation {
            modelContext.insert(newGear)
            try? modelContext.save()
        }
        
        // Programmer une notification si une date d'entretien a été définie
        if showNextServiceDue && newGear.nextServiceDue != nil {
            newGear.scheduleMaintenanceReminder()
        }
        
        dismiss()
    }
}

// MARK: - Category Button

struct CategoryButton: View {
    let category: GearCategory
    let isSelected: Bool
    let action: () -> Void
    
    private var backgroundColor: Color {
        let colorName = category.color
        
        let baseColor: Color = {
            switch colorName {
            case "purple": return .purple
            case "blue": return .blue
            case "green": return .green
            case "orange": return .orange
            case "gray": return .gray
            case "cyan": return .cyan
            case "pink": return .pink
            case "indigo": return .indigo
            default: return .brown
            }
        }()
        
        return baseColor.opacity(isSelected ? 0.25 : 0.08)
    }
    
    private var borderColor: Color {
        let colorName = category.color
        
        let baseColor: Color = {
            switch colorName {
            case "purple": return .purple
            case "blue": return .blue
            case "green": return .green
            case "orange": return .orange
            case "gray": return .gray
            case "cyan": return .cyan
            case "pink": return .pink
            case "indigo": return .indigo
            default: return .brown
            }
        }()
        
        return isSelected ? baseColor : .clear
    }
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: category.icon)
                    .font(.title2)
                    .foregroundStyle(isSelected ? borderColor : .secondary)
                
                Text(category.localizedName)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
            .background(backgroundColor)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(borderColor, lineWidth: isSelected ? 2 : 0)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    AddGearView()
        .modelContainer(for: Gear.self, inMemory: true)
}

// MARK: - Helper Views

struct SectionHeaderView: View {
    let title: LocalizedStringKey
    let icon: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.cyan)
            
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 4)
    }
}

struct FormFieldView: View {
    let label: LocalizedStringKey
    let icon: String
    let placeholder: LocalizedStringKey
    @Binding var text: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: icon)
                .font(.subheadline)
                .fontWeight(.medium)
            
            HStack {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                if !text.isEmpty {
                    Button {
                        text = ""
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
    }
}

// MARK: - View Extension for Card Style

extension View {
    func cardStyle() -> some View {
        self
            .padding()
            .background(Color.platformTertiaryBackground)
            .cornerRadius(16)
            .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
    }
}
