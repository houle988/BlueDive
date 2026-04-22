import SwiftUI
import SwiftData
import UniformTypeIdentifiers
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
        HStack(spacing: 8) {
            Text(fish.name)
                .font(.subheadline)
                .fontWeight(.bold)

            Text("x\(fish.count)")
                .font(.caption)
                .fontWeight(.bold)
                .padding(5)
                .background(Color.cyan.opacity(0.2))
                .clipShape(Circle())
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.primary.opacity(0.1)))
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
        self.value = String(format: specifier, value) + unit
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
    @State private var count = 1
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

                            // Amount stepper
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Amount")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    HStack(spacing: 16) {
                                        Button {
                                            if count > 1 { count -= 1 }
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .font(.title2)
                                                .foregroundStyle(count > 1 ? .cyan : .secondary.opacity(0.4))
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(count <= 1)

                                        Text("\(count)")
                                            .font(.title2)
                                            .fontWeight(.bold)
                                            .foregroundStyle(.primary)
                                            .frame(minWidth: 36)

                                        Button {
                                            if count < 100 { count += 1 }
                                        } label: {
                                            Image(systemName: "plus.circle.fill")
                                                .font(.title2)
                                                .foregroundStyle(count < 100 ? .cyan : .secondary.opacity(0.4))
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(count >= 100)
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 16)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color.primary.opacity(0.06))
                                    )
                                    Spacer()
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
                                    FishPreviewChip(name: fishName, count: count)
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
        let newFish = MarineSight(name: trimmedName, count: count)

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
    @State private var count: Int
    @State private var showSuggestions = false
    @FocusState private var isNameFocused: Bool

    @Query private var allFish: [MarineSight]

    init(fish: MarineSight) {
        self.fish = fish
        _fishName = State(initialValue: fish.name)
        _count = State(initialValue: fish.count)
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

                            // Amount stepper
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Amount")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    HStack(spacing: 16) {
                                        Button {
                                            if count > 1 { count -= 1 }
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .font(.title2)
                                                .foregroundStyle(count > 1 ? .cyan : .secondary.opacity(0.4))
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(count <= 1)

                                        Text("\(count)")
                                            .font(.title2)
                                            .fontWeight(.bold)
                                            .foregroundStyle(.primary)
                                            .frame(minWidth: 36)

                                        Button {
                                            if count < 100 { count += 1 }
                                        } label: {
                                            Image(systemName: "plus.circle.fill")
                                                .font(.title2)
                                                .foregroundStyle(count < 100 ? .cyan : .secondary.opacity(0.4))
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(count >= 100)
                                    }
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 16)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(Color.primary.opacity(0.06))
                                    )
                                    Spacer()
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
                                    FishPreviewChip(name: fishName, count: count)
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
        fish.count = count
        try? modelContext.save()
        dismiss()
    }
}

// MARK: - Fish Preview Chip

struct FishPreviewChip: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.subheadline)
                .fontWeight(.bold)

            Text("x\(count)")
                .font(.caption)
                .fontWeight(.bold)
                .padding(5)
                .background(Color.cyan.opacity(0.2))
                .clipShape(Circle())
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

                                        Label("\(gear.totalDivesCount)", systemImage: "water.waves")
                                            .font(.caption)
                                            .foregroundStyle(.cyan)
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

    private var contentType: UTType {
        if data.prefix(2) == Data([0xFF, 0xD8]) { return .jpeg }
        if data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) { return .png }
        return .jpeg
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.data }
        DataRepresentation(exportedContentType: .jpeg) { $0.data }
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
    let photoData: Data
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteAlert = false

    var body: some View {
        NavigationStack {
            Group {
                if let uiImage = PlatformImage(data: photoData) {
                    Image(platformImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.platformBackground.ignoresSafeArea())
                } else {
                    Color.platformBackground.ignoresSafeArea()
                }
            }
            .background(Color.platformBackground.ignoresSafeArea())

            .toolbar {
                #if os(iOS)
                ToolbarItemGroup(placement: .cancellationAction) {
                    ShareLink(
                        item: PhotoTransferable(data: photoData),
                        preview: SharePreview("Photo", image: Image(platformImage: PlatformImage(data: photoData)!))
                    ) {
                        Label("Save As", systemImage: "square.and.arrow.up")
                            .foregroundStyle(.primary)
                    }
                    Button(role: .destructive) {
                        showDeleteAlert = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                }
                #else
                ToolbarItem(placement: .cancellationAction) {
                    HStack(spacing: 8) {
                        Button {
                            savePhotoToDisk()
                        } label: {
                            Label("Save As", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            showDeleteAlert = true
                        } label: {
                            Text("Delete")
                                .foregroundStyle(.red)
                        }
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
                    onDelete()
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Remove this photo from the dive?")
            }
        }
    }

    #if os(macOS)
    private func savePhotoToDisk() {
        let isJPEG = photoData.prefix(2) == Data([0xFF, 0xD8])
        let ext = isJPEG ? "jpg" : "png"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Photo.\(ext)"
        panel.allowedContentTypes = isJPEG ? [.jpeg] : [.png]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? photoData.write(to: url)
        }
    }
    #endif
}
