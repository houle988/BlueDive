import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ImageIO
#if os(macOS)
import AppKit
#endif

// MARK: - Supporting Views

// MARK: - Dive Sliding Preview (used during swipe-between-dives transition)

struct DiveSlidingPreview: View {
    let dive: Dive
    let initialTab: DiveTab

    var body: some View {
        DiveDetailView(dive: dive, sortedDives: [], isSlidePreview: true, initialTab: initialTab)
            .allowsHitTesting(false)
    }
}

struct RatingStarsView: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: index < rating ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
        }
    }
}

struct FishChipView: View {
    let fish: MarineSight

    var body: some View {
        VStack(spacing: 4) {
            Text(fish.name)
                .font(.subheadline)
                .fontWeight(.bold)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            Text(SightingQuantity.from(count: fish.count).label)
                .font(.caption)
                .fontWeight(.bold)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.cyan.opacity(0.2))
                .clipShape(Capsule())
        }
        .frame(maxWidth: 140)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.1)))
    }
}

// MARK: - Detail Card

struct DetailCard: View {
    let title: LocalizedStringKey
    let value: String
    let localizedValue: LocalizedStringKey?
    let subtitle: String?
    let icon: String
    let color: Color

    // Initializer pour String
    init(title: LocalizedStringKey, value: String, subtitle: String? = nil, icon: String, color: Color) {
        self.title = title
        self.value = value
        self.localizedValue = nil
        self.subtitle = subtitle
        self.icon = icon
        self.color = color
    }

    // Initializer pour LocalizedStringKey (respects in-app language override)
    init(title: LocalizedStringKey, localizedValue: LocalizedStringKey, icon: String, color: Color) {
        self.title = title
        self.value = ""
        self.localizedValue = localizedValue
        self.subtitle = nil
        self.icon = icon
        self.color = color
    }

    // Initializer pour Double avec format
    init(title: LocalizedStringKey, value: Double, specifier: String, unit: String, icon: String, color: Color) {
        self.title = title
        // Parse decimal places from specifier (e.g. "%.1f" → 1) for locale-aware formatting
        let decimals: Int
        if let dotIndex = specifier.firstIndex(of: "."),
           let fIndex = specifier.lastIndex(of: "f"),
           dotIndex < fIndex,
           let d = Int(specifier[specifier.index(after: dotIndex)..<fIndex]) {
            decimals = d
        } else {
            decimals = 1
        }
        self.value = value.localizedString(decimals: decimals) + unit
        self.localizedValue = nil
        self.subtitle = nil
        self.icon = icon
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading) {
            Label(title, systemImage: icon)
                .font(.system(size: 10))
                .fontWeight(.bold)
                .foregroundStyle(color)
            if let localizedValue {
                Text(localizedValue)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else {
                Text(value)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 15))
    }
}

// MARK: - Add Fish View

struct AddFishView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var dive: Dive

    @State private var fishName = ""
    @State private var quantity = SightingQuantity.single
    @State private var showSuggestions = false
    @FocusState private var isNameFocused: Bool

    @Query private var allFish: [MarineSight]

    private var nameSuggestions: [String] {
        let unique = Set(allFish.map { $0.name }).sorted()
        guard !fishName.isEmpty else { return [] }
        return unique.filter {
            $0.localizedCaseInsensitiveContains(fishName) && $0.lowercased() != fishName.lowercased()
        }
    }

    private var isValidFish: Bool {
        !fishName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        // Icon header
                        VStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(.cyan.opacity(0.12))
                                    .frame(width: 64, height: 64)
                                Image(systemName: "fish.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.cyan)
                            }
                            Text("Marine Life Information")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 20)

                        // Form fields
                        VStack(spacing: 16) {
                            // Marine Life name field
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Marine Life name")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                ZStack(alignment: .trailing) {
                                    TextField("Marine Life name", text: $fishName)
                                        .autocorrectionDisabled()
                                        .platformTextInputAutocapitalization(.words)
                                        .textFieldStyle(.plain)
                                        .padding(10)
                                        .padding(.trailing, fishName.isEmpty ? 10 : 32)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(Color.primary.opacity(0.06))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(Color.cyan.opacity(fishName.isEmpty ? 0 : 0.4), lineWidth: 1)
                                        )
                                        .focused($isNameFocused)
                                        .onChange(of: fishName) {
                                            showSuggestions = isNameFocused && !nameSuggestions.isEmpty
                                        }
                                        .onChange(of: isNameFocused) {
                                            if isNameFocused {
                                                showSuggestions = !nameSuggestions.isEmpty
                                            } else {
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                                    showSuggestions = false
                                                }
                                            }
                                        }
                                    if !fishName.isEmpty {
                                        Button {
                                            fishName = ""
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.trailing, 8)
                                    }
                                }
                                if showSuggestions && !nameSuggestions.isEmpty {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(nameSuggestions.prefix(4), id: \.self) { suggestion in
                                            Button {
                                                fishName = suggestion
                                                showSuggestions = false
                                            } label: {
                                                HStack(spacing: 8) {
                                                    Image(systemName: "magnifyingglass")
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                    Text(suggestion)
                                                        .foregroundStyle(.cyan)
                                                        .lineLimit(1)
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.vertical, 6)
                                                .padding(.horizontal, 10)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.primary.opacity(0.06))
                                    )
                                }
                            }

                            // Quantity picker
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Quantity")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                    ForEach(SightingQuantity.allCases, id: \.self) { q in
                                        Button {
                                            quantity = q
                                        } label: {
                                            VStack(spacing: 3) {
                                                Text(q.label)
                                                    .font(.subheadline)
                                                    .fontWeight(.semibold)
                                                Text(q.rangeDescription)
                                                    .font(.caption2)
                                                    .foregroundStyle(quantity == q ? .cyan.opacity(0.8) : .secondary)
                                            }
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(quantity == q ? Color.cyan.opacity(0.18) : Color.primary.opacity(0.06))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(quantity == q ? Color.cyan : Color.clear, lineWidth: 1.5)
                                            )
                                            .foregroundStyle(quantity == q ? .cyan : .primary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)

                        // Live preview
                        if !fishName.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Overview")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal)

                                HStack {
                                    Spacer()
                                    FishPreviewChip(name: fishName, quantity: quantity)
                                        .scaleEffect(1.1)
                                    Spacer()
                                }
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.primary.opacity(0.04))
                                )
                                .padding(.horizontal)
                            }
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                }

                Divider()
                    .overlay(Color.primary.opacity(0.08))

                // Bottom buttons
                HStack {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])

                    Spacer()

                    Button {
                        addFish()
                    } label: {
                        Text("Add")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(isValidFish ? .cyan : .cyan.opacity(0.3))
                            )
                            .foregroundStyle(isValidFish ? .black : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isValidFish)
                }
                .padding()
            }
            .background(Color.platformBackground.ignoresSafeArea())
            .navigationTitle("New Marine Life")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif

        }
        #if os(macOS)
        .frame(width: 380, height: 400)
        #endif
    }

    @MainActor
    private func addFish() {
        let trimmedName = fishName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newFish = MarineSight(name: trimmedName, count: quantity.rawValue)

        // Établir la relation bidirectionnelle
        newFish.dive = dive

        // Insérer dans le contexte SwiftData
        modelContext.insert(newFish)

        // Sauvegarder les changements
        try? modelContext.save()

        dismiss()
    }
}

// MARK: - Edit Fish View

struct EditFishView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var fish: MarineSight

    @State private var fishName: String
    @State private var quantity: SightingQuantity
    @State private var showSuggestions = false
    @FocusState private var isNameFocused: Bool

    @Query private var allFish: [MarineSight]

    init(fish: MarineSight) {
        self.fish = fish
        _fishName = State(initialValue: fish.name)
        _quantity = State(initialValue: SightingQuantity.from(count: fish.count))
    }

    private var nameSuggestions: [String] {
        let unique = Set(allFish.map { $0.name }).sorted()
        guard !fishName.isEmpty else { return [] }
        return unique.filter {
            $0.localizedCaseInsensitiveContains(fishName) && $0.lowercased() != fishName.lowercased()
        }
    }

    private var isValidFish: Bool {
        !fishName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        // Icon header
                        VStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(.cyan.opacity(0.12))
                                    .frame(width: 64, height: 64)
                                Image(systemName: "fish.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.cyan)
                            }
                            Text("Marine Life Information")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 20)

                        // Form fields
                        VStack(spacing: 16) {
                            // Marine Life name field
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Marine Life name")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                ZStack(alignment: .trailing) {
                                    TextField("Marine Life name", text: $fishName)
                                        .autocorrectionDisabled()
                                        .platformTextInputAutocapitalization(.words)
                                        .textFieldStyle(.plain)
                                        .padding(10)
                                        .padding(.trailing, fishName.isEmpty ? 10 : 32)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(Color.primary.opacity(0.06))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(Color.cyan.opacity(fishName.isEmpty ? 0 : 0.4), lineWidth: 1)
                                        )
                                        .focused($isNameFocused)
                                        .onChange(of: fishName) {
                                            showSuggestions = isNameFocused && !nameSuggestions.isEmpty
                                        }
                                        .onChange(of: isNameFocused) {
                                            if isNameFocused {
                                                showSuggestions = !nameSuggestions.isEmpty
                                            } else {
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                                    showSuggestions = false
                                                }
                                            }
                                        }
                                    if !fishName.isEmpty {
                                        Button {
                                            fishName = ""
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.trailing, 8)
                                    }
                                }
                                if showSuggestions && !nameSuggestions.isEmpty {
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(nameSuggestions.prefix(4), id: \.self) { suggestion in
                                            Button {
                                                fishName = suggestion
                                                showSuggestions = false
                                            } label: {
                                                HStack(spacing: 8) {
                                                    Image(systemName: "magnifyingglass")
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                    Text(suggestion)
                                                        .foregroundStyle(.cyan)
                                                        .lineLimit(1)
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.vertical, 6)
                                                .padding(.horizontal, 10)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color.primary.opacity(0.06))
                                    )
                                }
                            }

                            // Quantity picker
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Quantity")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                                    ForEach(SightingQuantity.allCases, id: \.self) { q in
                                        Button {
                                            quantity = q
                                        } label: {
                                            VStack(spacing: 3) {
                                                Text(q.label)
                                                    .font(.subheadline)
                                                    .fontWeight(.semibold)
                                                Text(q.rangeDescription)
                                                    .font(.caption2)
                                                    .foregroundStyle(quantity == q ? .cyan.opacity(0.8) : .secondary)
                                            }
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(quantity == q ? Color.cyan.opacity(0.18) : Color.primary.opacity(0.06))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(quantity == q ? Color.cyan : Color.clear, lineWidth: 1.5)
                                            )
                                            .foregroundStyle(quantity == q ? .cyan : .primary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)

                        // Live preview
                        if !fishName.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Overview")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal)

                                HStack {
                                    Spacer()
                                    FishPreviewChip(name: fishName, quantity: quantity)
                                        .scaleEffect(1.1)
                                    Spacer()
                                }
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.primary.opacity(0.04))
                                )
                                .padding(.horizontal)
                            }
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                }

                Divider()
                    .overlay(Color.primary.opacity(0.08))

                // Bottom buttons
                HStack {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])

                    Spacer()

                    Button {
                        saveFish()
                    } label: {
                        Text("Save")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(isValidFish ? .cyan : .cyan.opacity(0.3))
                            )
                            .foregroundStyle(isValidFish ? .black : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isValidFish)
                }
                .padding()
            }
            .background(Color.platformBackground.ignoresSafeArea())
            .navigationTitle("Edit Marine Life")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #if os(macOS)
        .frame(width: 380, height: 400)
        #endif
    }

    @MainActor
    private func saveFish() {
        fish.name = fishName.trimmingCharacters(in: .whitespacesAndNewlines)
        fish.count = quantity.rawValue
        try? modelContext.save()
        dismiss()
    }
}

// MARK: - Fish Preview Chip

struct FishPreviewChip: View {
    let name: String
    let quantity: SightingQuantity

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.subheadline)
                .fontWeight(.bold)

            Text(quantity.label)
                .font(.caption)
                .fontWeight(.bold)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.cyan.opacity(0.2))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.cyan.opacity(0.2)))
    }
}

// MARK: - Gear Chip View

struct GearChipView: View {
    let gear: Gear

    private var categoryColor: Color {
        switch gear.category {
        case "Wetsuit": return .purple
        case "Tank": return .blue
        case "Regulator": return .green
        case "BCD": return .orange
        case "Computer": return .cyan
        case "Fins": return .pink
        case "Mask": return .indigo
        case "Weights": return .gray
        default: return .secondary
        }
    }

    private var categoryIcon: String {
        GearCategory(exportKeyOrRawValue: gear.category)?.icon ?? "wrench.and.screwdriver.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(gear.isInactive ? .red : .green)
                    .frame(width: 6, height: 6)

                Image(systemName: categoryIcon)
                    .font(.caption)
                    .foregroundStyle(categoryColor)

                Text(gear.gearCategory?.localizedName ?? LocalizedStringKey(gear.category))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(gear.name)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 140, height: 90, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(categoryColor.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(categoryColor.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Equipment Info Card

struct EquipmentInfoCard: View {
    let icon: String
    let title: LocalizedStringKey
    let value: String
    let subtitle: LocalizedStringKey
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)

                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(2)

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Add Gear To Dive View

struct AddGearToDiveView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var dive: Dive

    @Query private var allGear: [Gear]

    // Équipements déjà utilisés dans cette plongée
    private var usedGearIds: Set<UUID> {
        Set((dive.usedGear ?? []).map { $0.id })
    }

    // Équipements disponibles (non encore ajoutés)
    private var availableGear: [Gear] {
        allGear.filter { !usedGearIds.contains($0.id) && !$0.isInactive }
    }

    /// Gear items grouped by category, sorted A-Z within each group.
    private var groupedAvailableGear: [(key: String, items: [Gear])] {
        let grouped = Dictionary(grouping: availableGear) { gear in
            GearCategory(rawValue: gear.category)?.rawValue ?? gear.category
        }
        return grouped.sorted { $0.key < $1.key }.map { (key: $0.key, items: $0.value.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.platformBackground.ignoresSafeArea()

                if availableGear.isEmpty {
                    emptyStateView
                } else {
                    gearList
                }
            }
            .navigationTitle("Add Equipment")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(.orange)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 350)
        #endif
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "tray")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("No Equipment Available")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("All your equipment is already added to this dive or you haven't created any equipment yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var gearList: some View {
        List {
            ForEach(groupedAvailableGear, id: \.key) { category, items in
                Section {
                    ForEach(items) { gear in
                        Button(action: {
                            withAnimation {
                                addGear(gear)
                            }
                        }) {
                            HStack(spacing: 12) {
                                // Icône de catégorie
                                ZStack {
                                    Circle()
                                        .fill(categoryColor(for: gear.category).opacity(0.2))
                                        .frame(width: 40, height: 40)

                                    Image(systemName: categoryIcon(for: gear.category))
                                        .foregroundStyle(categoryColor(for: gear.category))
                                }

                                // Info de l'équipement
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(gear.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)

                                    HStack(spacing: 8) {
                                        Text(gear.gearCategory?.localizedName ?? LocalizedStringKey(gear.category))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                        if gear.weightContribution > 0 {
                                            Text("• \(UserPreferences.shared.weightUnit.formatted(gear.weightContribution, from: WeightUnit.from(importFormat: gear.weightContributionUnit ?? UserPreferences.shared.weightUnit.symbol)))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        Label(Double(gear.totalDivesCount).localizedString(decimals: 0), systemImage: "water.waves")
                                            .font(.caption)
                                            .foregroundStyle(.cyan)
                                    }

                                    if !gear.diverName.isEmpty {
                                        Text(gear.diverName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                // Bouton ajouter
                                Image(systemName: "plus.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .listRowBackground(Color.primary.opacity(0.05))
                    }
                } header: {
                    Text(GearCategory(rawValue: category)?.localizedName ?? LocalizedStringKey(category))
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    @MainActor
    private func addGear(_ gear: Gear) {
        if dive.usedGear == nil { dive.usedGear = [] }
        dive.usedGear!.append(gear)
        try? modelContext.save()
    }

    private func categoryColor(for category: String) -> Color {
        switch category {
        case "Wetsuit": return .purple
        case "Tank": return .blue
        case "Regulator": return .green
        case "BCD": return .orange
        case "Computer": return .cyan
        case "Fins": return .pink
        case "Mask": return .indigo
        case "Weights": return .gray
        default: return .secondary
        }
    }

    private func categoryIcon(for category: String) -> String {
        GearCategory(exportKeyOrRawValue: category)?.icon ?? "wrench.and.screwdriver.fill"
    }
}

// MARK: - Format Info Cell

struct FormatInfoCell: View {
    let icon: String
    let label: LocalizedStringKey
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value.uppercased())
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
    }
}

// MARK: - Modern Form Components (for EditMenuStatsView)

struct MenuSectionHeader: View {
    let title: LocalizedStringKey
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(title)
                .foregroundStyle(color)
        }
        .font(.subheadline)
        .fontWeight(.semibold)
        .textCase(.uppercase)
    }
}

struct MenuTextField: View {
    let label: LocalizedStringKey
    @Binding var text: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
            TextField(label, text: $text)
                .foregroundStyle(.primary)
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
    }
}

struct AutocompleteMenuTextField: View {
    let label: LocalizedStringKey
    @Binding var text: String
    let icon: String
    let color: Color
    let suggestions: [String]

    @State private var showSuggestions = false
    @FocusState private var isFocused: Bool

    private var filtered: [String] {
        guard !text.isEmpty else { return [] }
        return suggestions.filter {
            $0.localizedCaseInsensitiveContains(text) && $0.lowercased() != text.lowercased()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 24)
                TextField(label, text: $text)
                    .foregroundStyle(.primary)
                    .focused($isFocused)
                    .onChange(of: text) {
                        showSuggestions = isFocused && !filtered.isEmpty
                    }
                    .onChange(of: isFocused) {
                        if isFocused {
                            showSuggestions = !filtered.isEmpty
                        } else {
                            // Delay hiding so button tap can register
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                showSuggestions = false
                            }
                        }
                    }
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
            if showSuggestions && !filtered.isEmpty {
                ForEach(filtered.prefix(4), id: \.self) { suggestion in
                    Button {
                        text = suggestion
                        showSuggestions = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(suggestion)
                                .foregroundStyle(.cyan)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                        .padding(.leading, 36)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct MenuPicker: View {
    let label: LocalizedStringKey
    @Binding var selection: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
            Picker(label, selection: $selection) {
                Label("None",   systemImage: "minus.circle").tag("None")
                Label("Reef",   systemImage: "fish.fill").tag("Reef")
                Label("Wreck",  systemImage: "anchor").tag("Wreck")
                Label("Cave",   systemImage: "mountain.2.fill").tag("Cave")
                Label("Night",  systemImage: "moon.stars.fill").tag("Night")
                Label("Photo",  systemImage: "camera.fill").tag("Photo")
                Label("Deep",   systemImage: "arrow.down.circle.fill").tag("Deep")
                Label("Drift",  systemImage: "wind").tag("Drift")
                Label("Training", systemImage: "graduationcap.fill").tag("Training")
            }
            .pickerStyle(.menu)
        }
    }
}

// MARK: - FlowLayout for macOS

#if os(macOS)
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        for size in sizes {
            if lineWidth + size.width > proposal.width ?? 0 {
                totalHeight += lineHeight + spacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth += size.width + spacing
                lineHeight = max(lineHeight, size.height)
            }
            totalWidth = max(totalWidth, lineWidth)
        }
        totalHeight += lineHeight

        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var point = bounds.origin
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if point.x + size.width > bounds.maxX {
                point.x = bounds.origin.x
                point.y += lineHeight + spacing
                lineHeight = 0
            }

            subview.place(at: point, proposal: .unspecified)
            point.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
#endif

// MARK: - Array Extension

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Photo Transferable (for ShareLink export)

struct PhotoTransferable: Transferable {
    let data: Data
    let suggestedName: String
    // Parsed once at init so the three FileRepresentation closures never repeat the CGImageSource lookup.
    let detectedUTType: UTType

    init(data: Data, suggestedName: String) {
        self.data = data
        self.suggestedName = suggestedName
        self.detectedUTType = PhotoTransferable.utType(for: data)
    }

    // Used by the thumbnail task when a CGImageSource is already open,
    // so type detection and thumbnail decode share the same allocation.
    init(data: Data, suggestedName: String, detectedType: UTType) {
        self.data = data
        self.suggestedName = suggestedName
        self.detectedUTType = detectedType
    }

    // Shared helper so savePhotoToDisk() can resolve the UTType without instantiating a full PhotoTransferable.
    // Fast magic-byte check avoids CGImageSource allocation for the two most common formats,
    // falling back to ImageIO only for HEIC, TIFF, GIF, etc.
    static func utType(for data: Data) -> UTType {
        if data.prefix(2) == Data([0xFF, 0xD8]) { return .jpeg }
        if data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) { return .png }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeID = CGImageSourceGetType(source) as String?,
              let utType = UTType(typeID) else { return .jpeg }
        return utType
    }

    // Resolves UTType from an already-open CGImageSource so callers can
    // share one source allocation between type detection and thumbnail decode.
    static func utType(fromSource source: CGImageSource) -> UTType {
        guard let typeID = CGImageSourceGetType(source) as String?,
              let utType = UTType(typeID) else { return .jpeg }
        return utType
    }

    var fileExtension: String {
        detectedUTType.preferredFilenameExtension ?? "jpg"
    }

    fileprivate func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suggestedName).\(fileExtension)")
    }

    private func writeToTempFile() throws -> SentTransferredFile {
        let url = tempFileURL()
        try data.write(to: url, options: .atomic)
        return SentTransferredFile(url)
    }

    static var transferRepresentation: some TransferRepresentation {
        // FileRepresentation preserves the suggested filename regardless of the requested content type.
        // .image is the catch-all. .jpeg and .png are included so receivers that request a
        // concrete subtype still get a named file (DataRepresentation does not carry a filename).
        // All three write the original bytes unchanged — no transcoding is performed, so the
        // file content always matches detectedUTType regardless of which representation was
        // requested. Writes use .atomic so concurrent representation negotiation never produces
        // a partially-written file.
        FileRepresentation(exportedContentType: .image) { try $0.writeToTempFile() }
        FileRepresentation(exportedContentType: .jpeg) { try $0.writeToTempFile() }
        FileRepresentation(exportedContentType: .png)  { try $0.writeToTempFile() }
    }
}

// MARK: - Identifiable Photo Wrapper

struct IdentifiablePhotoData: Identifiable {
    let id = UUID()
    let data: Data
    let index: Int
}

// MARK: - Photo Preview Sheet

struct PhotoPreviewSheet: View {
    @Binding var photos: [Data]
    let initialIndex: Int
    let onDelete: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var showDeleteAlert = false
    @State private var shareThumbnail: PlatformImage?
    @State private var isPageSeeded: Bool
    @State private var cachedExportName: String
    @State private var cachedShareItem: PhotoTransferable?
    @State private var sessionTempFileURLs: Set<URL> = []
    @State private var isPreparingShare = false

    init(photos: Binding<[Data]>, initialIndex: Int, onDelete: @escaping (Int) -> Void) {
        self._photos = photos
        self.initialIndex = initialIndex
        self.onDelete = onDelete
        self._currentIndex = State(initialValue: initialIndex)
        // No seeding needed when starting at page 0; UIPageViewController
        // naturally initialises at its own page 0.
        self._isPageSeeded = State(initialValue: initialIndex == 0)
        // Seed the export name at construction time so the first body render
        // already has a valid filename — avoids an empty-name SharePreview.
        let exportPrefix = NSLocalizedString("BlueDive Photo", bundle: Bundle.forAppLanguage(), comment: "Prefix for exported photo filenames shown in share sheet and save dialog")
        self._cachedExportName = State(initialValue: "\(exportPrefix) \(PhotoPreviewSheet.exportDateFormatter.string(from: Date()))")
    }

    // Returns nil when photos is empty so callers never subscript into an empty array.
    private var currentPhoto: Data? {
        guard !photos.isEmpty else { return nil }
        return photos[min(currentIndex, photos.count - 1)]
    }

    var body: some View {
        NavigationStack {
            Group {
                if photos.isEmpty {
                    Color.platformBackground.ignoresSafeArea()
                } else {
                    TabView(selection: $currentIndex) {
                        ForEach(photos.indices, id: \.self) { index in
                            PhotoPageView(data: photos[index])
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .opacity(isPageSeeded ? 1 : 0)
                    .animation(.easeIn(duration: 0.15), value: isPageSeeded)
                }
            }
            .background(Color.platformBackground.ignoresSafeArea())
            .toolbar {
                if photos.count > 1 {
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            currentIndex -= 1
                        } label: {
                            Label("Previous Photo", systemImage: "chevron.left")
                        }
                        .disabled(currentIndex == 0)
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Text(verbatim: "\(currentIndex + 1) / \(photos.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            currentIndex += 1
                        } label: {
                            Label("Next Photo", systemImage: "chevron.right")
                        }
                        .disabled(currentIndex == photos.count - 1)
                    }
                }
            }
            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .cancellationAction) {
                    if let shareItem = cachedShareItem {
                        let name = cachedExportName
                        if let thumbnail = shareThumbnail {
                            ShareLink(
                                item: shareItem,
                                preview: SharePreview(name, image: Image(platformImage: thumbnail))
                            ) { shareButtonLabel }
                            .disabled(isPreparingShare)
                        } else {
                            ShareLink(
                                item: shareItem,
                                preview: SharePreview(name)
                            ) { shareButtonLabel }
                            .disabled(isPreparingShare)
                        }
                    } else {
                        // First load: no share item yet — show a disabled placeholder so
                        // the toolbar layout is stable from the first render onward.
                        // Must be a Button (not a bare Label) so SwiftUI applies the
                        // standard dimmed-disabled visual treatment.
                        Button(action: {}) { shareButtonLabel }.disabled(true)
                    }
                    Button(role: .destructive) {
                        showDeleteAlert = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .disabled(photos.isEmpty)
                }
                #else
                ToolbarItem(placement: .cancellationAction) {
                    HStack(spacing: 8) {
                        Button {
                            savePhotoToDisk()
                        } label: {
                            Label("Save As", systemImage: "square.and.arrow.down")
                        }
                        .disabled(photos.isEmpty)
                        Button {
                            showDeleteAlert = true
                        } label: {
                            Text("Delete")
                                .foregroundStyle(.red)
                        }
                        .disabled(photos.isEmpty)
                    }
                }
                #endif
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.primary)
                }
            }
            .alert("Remove Photo", isPresented: $showDeleteAlert) {
                Button("Remove", role: .destructive) {
                    onDelete(currentIndex)
                    // onChange(of: photos.count) handles both index clamping and dismissal
                    // when count reaches zero (covers in-app delete AND external iCloud sync).
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Remove this photo from the dive?")
            }
            .task(id: thumbnailTaskID) {
                // The id-level sentinel (thumbnailTaskID returns 0 while !isPageSeeded)
                // suppresses index-change re-fires during the seed dance, but .task(id:)
                // always fires once on first appear regardless of id value. This guard
                // makes that initial fire a no-op so the decode runs exactly once —
                // after isPageSeeded becomes true and the id flips to the real photoTaskID.
                guard isPageSeeded else { return }
                // Snapshot the export filename once per photo change so the ShareLink
                // item name is stable across body re-renders within the same photo.
                let name = exportFileName
                cachedExportName = name
                // Mark loading so the share button stays visible but disabled while the
                // new photo's share item resolves — avoids the button flashing away on
                // every navigation. The old cachedShareItem is intentionally kept so the
                // toolbar always has something to anchor the button's layout to.
                // shareThumbnail IS cleared so the SharePreview image updates correctly.
                isPreparingShare = true
                shareThumbnail = nil
                guard let data = currentPhoto else { isPreparingShare = false; return }
                // Build the share item and thumbnail in one detached pass — the same
                // CGImageSource is reused for type detection and thumbnail decode,
                // so HEIC photos are parsed only once, fully off the main thread.
                let (thumbnail, shareItem): (PlatformImage?, PhotoTransferable) = await Task.detached(priority: .userInitiated) {
                    let cfData = data as CFData
                    guard let source = CGImageSourceCreateWithData(cfData, nil) else {
                        // Source creation failed — fall back to magic-byte type detection, no thumbnail.
                        let utType = PhotoTransferable.utType(for: data)
                        return (nil, PhotoTransferable(data: data, suggestedName: name, detectedType: utType))
                    }
                    let detectedType = PhotoTransferable.utType(fromSource: source)
                    let item = PhotoTransferable(data: data, suggestedName: name, detectedType: detectedType)
                    let opts: [CFString: Any] = [
                        kCGImageSourceThumbnailMaxPixelSize: 256,
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true
                    ]
                    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return (nil, item) }
                    #if os(iOS)
                    return (UIImage(cgImage: cgImage), item)
                    #else
                    return (NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)), item)
                    #endif
                }.value
                guard !Task.isCancelled else { return }
                cachedShareItem = shareItem
                shareThumbnail = thumbnail
                isPreparingShare = false
                // Record the temp path this share item will write to so onDisappear can
                // clean up only this session's files, not files from concurrent sheets.
                // Uses the same tempFileURL() the FileRepresentation closures use so the
                // two path-construction sites cannot silently diverge.
                sessionTempFileURLs.insert(shareItem.tempFileURL())
            }
            .onChange(of: photos.count) { _, newCount in
                if newCount == 0 {
                    // Covers both in-app delete-of-last and external iCloud sync emptying the array.
                    dismiss()
                } else {
                    currentIndex = min(currentIndex, newCount - 1)
                }
            }
            .task {
                guard !isPageSeeded else { return }
                // A single photo has no neighbour to visit; no offset mis-alignment occurs.
                guard photos.count > 1 else { isPageSeeded = true; return }
                let target = currentIndex   // always > 0 here (isPageSeeded == false iff initialIndex > 0)
                // Safety net: if the invariant above ever weakens, avoid setting index to -1.
                guard target > 0 else { isPageSeeded = true; return }
                #if os(iOS)
                // UIPageViewController's scroll view is initialised at an incorrect offset
                // when the selection is non-zero, placing it visually between two pages.
                // Seeding with one instant step to a neighbour and back forces it to
                // re-commit to the correct offset.
                // defer ensures setAnimationsEnabled(true) is restored even when this task
                // is cancelled mid-sleep. try? converts CancellationError to nil so execution
                // continues normally; defer fires on the closure's normal return.
                defer { UIView.setAnimationsEnabled(true) }
                UIView.setAnimationsEnabled(false)
                currentIndex = target - 1
                // Task.sleep reliably waits past a full display-link cycle (~16 ms at 60 fps),
                // unlike Task.yield() which only reschedules without guaranteeing a UIKit layout commit.
                try? await Task.sleep(nanoseconds: 33_000_000)
                // Re-clamp in case photos shrank while sleeping (e.g., concurrent iCloud sync).
                currentIndex = photos.isEmpty ? 0 : min(target, photos.count - 1)
                try? await Task.sleep(nanoseconds: 33_000_000)
                #endif
                isPageSeeded = true
            }
            .onDisappear {
                // Remove only the temp files this session predicted (one per photo navigated to).
                // SentTransferredFile(allowAccessingOriginalFile: false) (the default) causes the
                // system to copy the file before returning control, so deleting these paths is safe.
                // A prefix-based sweep is intentionally avoided: it would also remove files written
                // by other concurrently open photo sheets on iPad/Mac multi-window.
                for url in sessionTempFileURLs {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    private static let exportDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private var thumbnailTaskID: Int {
        // Return a stable sentinel while the seed dance is in progress so that the
        // two currentIndex writes (target-1 then target) don't each fire the thumbnail
        // task and launch redundant Task.detached decodes for the neighbour photo.
        // The decode runs exactly once when isPageSeeded becomes true — the .task(id:)
        // mechanism fires twice (id=0 on first appear, real id after seeding), but the
        // body guard at the top of the task neutralizes the id=0 fire as a no-op.
        guard isPageSeeded else { return 0 }
        return currentPhoto?.photoTaskID ?? 0
    }

    private var exportFileName: String {
        let prefix = NSLocalizedString("BlueDive Photo", bundle: Bundle.forAppLanguage(), comment: "Prefix for exported photo filenames shown in share sheet and save dialog")
        return "\(prefix) \(PhotoPreviewSheet.exportDateFormatter.string(from: Date()))"
    }

    @ViewBuilder private var shareButtonLabel: some View {
        Label("Save As", systemImage: "square.and.arrow.up")
            .foregroundStyle(.primary)
    }

    #if os(macOS)
    private func savePhotoToDisk() {
        guard let photo = currentPhoto else { return }
        let utType = PhotoTransferable.utType(for: photo)
        let ext = utType.preferredFilenameExtension ?? "jpg"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(exportFileName).\(ext)"
        panel.allowedContentTypes = [utType]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? photo.write(to: url)
        }
    }
    #endif
}

// MARK: - Photo Page View

private struct PhotoPageView: View {
    let data: Data
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack {
                    Color.platformBackground.ignoresSafeArea()
                    ProgressView()
                }
            }
        }
        .task(id: data.photoTaskID) {
            let d = data
            let decoded = await Task.detached(priority: .userInitiated) {
                PlatformImage(data: d)
            }.value
            guard !Task.isCancelled else { return }
            image = decoded
        }
    }
}
