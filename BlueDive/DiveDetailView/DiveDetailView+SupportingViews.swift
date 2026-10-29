import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import ImageIO
import QuickLook
#if os(macOS)
import AppKit
#endif

// MARK: - Supporting Views

// MARK: - Dive Sliding Preview (used during swipe-between-dives transition)

struct DiveSlidingPreview: View {
    let dive: Dive
    let diveNumber: Int
    let initialTab: DiveTab

    var body: some View {
        DiveDetailView(dive: dive, sortedDives: [], isSlidePreview: true, initialTab: initialTab, diveNumber: diveNumber)
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

/// A sighting in the dive's Marine Life grid, laid out as a photo tile (`PhotoGridTile`): the
/// linked species' image — a fish symbol for a sighting not in the catalogue or a species
/// without an image — with the quantity as a bar at its bottom-leading corner, and the name
/// shown for the sighting below. A tap calls `onOpen` (the dive decides: species page, or the
/// sighting's editor); a long press toggles edit mode, where the remove badge appears.
/// Outside edit mode the quantity is a menu that changes it in place (`onSetQuantity`).
struct SightingGridTile: View {
    let fish: MarineSight
    /// The linked species, if its page can be opened (resolved by the dive, as for the tap).
    let species: Species?
    let isEditing: Bool
    let onOpen: () -> Void
    let onToggleEditing: () -> Void
    let onRemove: () -> Void
    let onSetQuantity: (SightingQuantity) -> Void

    private var quantity: SightingQuantity { SightingQuantity.from(count: fish.count) }

    /// The quantity over the image, 6 pt from its corner: at least half the image's width,
    /// growing with its text up to the image's width less the margins: a menu outside edit
    /// mode (where only the remove badge acts).
    @ViewBuilder
    private func quantityControl(imageWidth: CGFloat) -> some View {
        let minWidth = imageWidth / 2
        let maxWidth = max(minWidth, imageWidth - 12)
        if isEditing {
            // Sized to its content, as the menu sizes it outside edit mode (same bar in both).
            SightingQuantityCapsule(quantity: quantity, minWidth: minWidth, maxWidth: maxWidth, isTall: true)
                .fixedSize()
                .padding(6)
        } else {
            // The 6 pt around the bar, inside the image, is part of the tap target.
            SightingQuantityMenu(quantity: quantity, padding: 6, minWidth: minWidth, maxWidth: maxWidth,
                                 isTall: true, onSet: onSetQuantity)
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 4) {
                Color.clear
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay { SpeciesImageView(species: species, size: nil) }
                    .overlay {
                        // A bar half the image's width (wider when its text needs it), at the
                        // bottom-leading corner.
                        GeometryReader { proxy in
                            quantityControl(imageWidth: proxy.size.width)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(fish.displayName)
                    .font(.subheadline)
                    .fontWeight(.bold)
                    // Two lines reserved, so every tile in a grid row has the same height.
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen() }
            .onLongPressGesture { onToggleEditing() }
            // One VoiceOver element: the name, then the quantity and its range.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: fish.displayName))
            .accessibilityValue(Text(verbatim: "\(quantity.label), \(quantity.rangeDescription)"))
            .accessibilityHint(species != nil && !isEditing ? Text("Opens species details") : Text(verbatim: ""))
            // In edit mode a linked sighting's tile does nothing (only its remove badge acts).
            .accessibilityAddTraits(isEditing && species != nil ? [] : .isButton)
            .accessibilityAction { onOpen() }
            // Swipe up or down to change the quantity, as the menu does.
            .accessibilityAdjustableAction { direction in
                guard !isEditing else { return }
                let options = SightingQuantity.allCases
                guard let index = options.firstIndex(of: quantity) else { return }
                switch direction {
                case .increment where index < options.count - 1: onSetQuantity(options[index + 1])
                case .decrement where index > 0: onSetQuantity(options[index - 1])
                default: break
                }
            }

            if isEditing {
                Button(action: onRemove) {
                    // Same geometry as the photo badge: 6 pt trailing (half of the 12 pt gap
                    // to the next tile), inward over the tile, and nothing upward. 40 × 34 pt.
                    TapTargetInset(top: 0, leading: 16, bottom: 16, trailing: 6) {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 18))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                    }
                }
                #if os(macOS)
                .buttonStyle(.plain)
                #endif
                .accessibilityLabel(Text(verbatim: String(format: NSLocalizedString("Remove %@", bundle: .forAppLanguage(), comment: "Accessibility label for a button that removes a filter chip, naming the specific value it removes"), fish.displayName)))
                .offset(x: 6, y: -6)
                .transition(.scale.combined(with: .opacity))
            }
        }
    }
}

/// A sighting's quantity as a solid capsule ("Few"), readable over an image: compact,
/// sized to its text (list rows), or — a dive's tile — `isTall` (1.5 times the compact height)
/// and at least `minWidth` wide, the text centred. With `maxWidth`, the capsule grows with its
/// text up to that width, then the text shrinks (to 80 %) rather than run past it — the
/// largest accessibility text sizes on a narrow tile.
struct SightingQuantityCapsule: View {
    let quantity: SightingQuantity
    var minWidth: CGFloat?
    var maxWidth: CGFloat?
    var isTall = false
    @Environment(\.colorScheme) private var colorScheme

    // A solid fill that follows the appearance: white with dark text in light mode, near-black
    // with white text in dark mode. Opaque, so every box looks the same whatever image is
    // behind it (a translucent glass took on each photo's colour); a hairline edge keeps it
    // apart from a background of the same tone.
    private var isDark: Bool { colorScheme == .dark }
    private var textColor: Color { isDark ? .white : .black }
    private var fill: Color { isDark ? Color(white: 0.12) : .white }
    private var edge: Color { isDark ? Color.white.opacity(0.2) : Color.black.opacity(0.12) }
    /// Compact: 3 pt above and below the text (about 22 pt high); tall: about 33 pt.
    private var verticalPadding: CGFloat { isTall ? 8.5 : 3 }

    var body: some View {
        Text(quantity.label)
            .font(.caption)
            .fontWeight(.bold)
            .lineLimit(1)
            .minimumScaleFactor(maxWidth == nil ? 1 : 0.8)
            .padding(.horizontal, 7)
            .padding(.vertical, verticalPadding)
            .frame(minWidth: minWidth, maxWidth: maxWidth)
            .foregroundStyle(textColor)
            .background {
                Capsule()
                    .fill(fill)
                    .overlay(Capsule().strokeBorder(edge, lineWidth: 1))
            }
    }
}

/// A sighting's quantity capsule that opens a menu of the four ranges, each with its range on
/// the same line ("Few · 2 to 10", as the ranges read in the sighting editor; one line reads
/// the same on every platform). `padding` around the capsule is part of the tap target.
struct SightingQuantityMenu: View {
    let quantity: SightingQuantity
    var padding: CGFloat = 0
    /// The tile's bar (`SightingQuantityCapsule.minWidth`, `maxWidth`, `isTall`).
    var minWidth: CGFloat?
    var maxWidth: CGFloat?
    var isTall = false
    let onSet: (SightingQuantity) -> Void

    var body: some View {
        Menu {
            Picker("Quantity", selection: Binding(get: { quantity }, set: { onSet($0) })) {
                ForEach(SightingQuantity.allCases, id: \.self) { option in
                    Text(verbatim: "\(option.label) · \(option.rangeDescription)").tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            SightingQuantityCapsule(quantity: quantity, minWidth: minWidth, maxWidth: maxWidth, isTall: isTall)
                .padding(padding)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        // The current quantity and its range (a label set by the row replaces the capsule's text).
        .accessibilityValue(Text(verbatim: "\(quantity.label), \(quantity.rangeDescription)"))
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

// MARK: - Gear Chip View

struct GearChipView: View {
    let gear: Gear

    private var categoryColor: Color {
        GearCategory(exportKeyOrRawValue: gear.category)?.swiftUIColor ?? .secondary
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
                    .accessibilityLabel(gear.isInactive ? Text("Inactive") : Text("Active"))

                Image(systemName: categoryIcon)
                    .font(.caption)
                    .foregroundStyle(categoryColor)
                    .accessibilityHidden(true)

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
    // By record, not by `Gear.id`: a gear item sharing an id with one already on the dive
    // (e.g. imported on two devices before they synced) stays available.
    private var usedGearIds: Set<PersistentIdentifier> {
        Set((dive.usedGear ?? []).map { $0.persistentModelID })
    }

    // Équipements disponibles (non encore ajoutés)
    private var availableGear: [Gear] {
        allGear.filter { !usedGearIds.contains($0.persistentModelID) && !$0.isInactive }
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
                AppBackground().ignoresSafeArea()

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
                    .confirmationActionForeground(.orange)
                }
            }
        }
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
        groupedList {
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
                        .listRowButton()
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
        GearCategory(exportKeyOrRawValue: category)?.swiftUIColor ?? .secondary
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
            formTextField(label, text: $text)
                .foregroundStyle(.primary)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .clearButtonTapTarget()
                        .accessibilityLabel(Text("Clear"))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Autocomplete suggestions for the text fields of an edit sheet, built in one pass over the
/// logbook when the sheet opens rather than on every redraw (every keystroke redraws the whole
/// sheet, which would read each field of every dive again). Values are trimmed, de-duplicated
/// regardless of case (the first spelling found is kept) and sorted. A value saved on another
/// device while the sheet is open is suggested from the sheet's next opening.
struct DiveFieldSuggestions {
    private var values: [AnyKeyPath: [String]] = [:]

    init() {}

    /// Skips dives deleted on another device, which `DiveStore.dives` may still briefly hold
    /// (reading their attributes would crash).
    @MainActor
    init(dives: [Dive], fields: [KeyPath<Dive, String>] = [], optionalFields: [KeyPath<Dive, String?>] = []) {
        var seen: [AnyKeyPath: Set<String>] = [:]
        var found: [AnyKeyPath: [String]] = [:]
        func add(_ raw: String?, for field: AnyKeyPath) {
            guard let value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
                  seen[field, default: []].insert(value.lowercased()).inserted else { return }
            found[field, default: []].append(value)
        }
        for dive in dives where !dive.isDeleted && dive.modelContext != nil {
            for field in fields { add(dive[keyPath: field], for: field) }
            for field in optionalFields { add(dive[keyPath: field], for: field) }
        }
        values = found.mapValues { $0.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }
    }

    /// The suggestions for one field (empty before the sheet appears or when no dive has a value).
    subscript(_ field: AnyKeyPath) -> [String] { values[field] ?? [] }
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
                formTextField(label, text: $text)
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
                            .clearButtonTapTarget()
                            .accessibilityLabel(Text("Clear"))
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
                        // The whole suggestion responds, not only its text (a plain Button only responds
                        // where something is drawn).
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Site Search Field (for Copy from Existing Site)
// Note: shares the same focus/dismiss/clear-button pattern as AutocompleteMenuTextField (below),
// DiverAutocompleteField (DiverFilter.swift), and GearAutocompleteField (AddGearView.swift).
// Any fix to that shared skeleton needs to be applied in all four places.

struct SiteSearchField: View {
    @Binding var selectedSite: Dive?
    let recents: [Dive]
    let allSites: [Dive]

    @State private var searchText: String = ""
    @State private var showSuggestions: Bool = false
    @FocusState private var isFocused: Bool

    private var selectedDisplayText: String {
        // The selection is kept across redraws; a dive deleted on another device is not read.
        guard let site = selectedSite, !site.isDeleted, site.modelContext != nil else { return "" }
        return site.siteName + (site.location.isEmpty ? "" : " — \(site.location)")
    }

    private var filtered: [Dive] {
        if selectedSite != nil { return [] }
        guard !searchText.isEmpty else { return [] }
        return allSites.filter { site in
            let haystack = [site.siteName, site.location, site.siteCountry ?? ""].joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: selectedSite == nil ? "magnifyingglass" : "checkmark.circle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 24)
                formTextField("Search sites…", text: $searchText)
                    .foregroundStyle(.primary)
                    .autocorrectionDisabled()
                    .focused($isFocused)
                    .onChange(of: searchText) {
                        if selectedSite != nil && searchText != selectedDisplayText {
                            selectedSite = nil
                            searchText = ""
                        }
                        showSuggestions = isFocused
                    }
                    .onChange(of: isFocused) {
                        if isFocused {
                            showSuggestions = true
                        } else {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                if !isFocused { showSuggestions = false }
                            }
                        }
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        selectedSite = nil
                        showSuggestions = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .clearButtonTapTarget()
                            .accessibilityLabel(Text("Clear"))
                    }
                    .buttonStyle(.plain)
                }
            }

            if showSuggestions {
                if searchText.isEmpty {
                    if !recents.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Recent")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 6)
                                .padding(.bottom, 2)
                            ForEach(recents, id: \.id) { site in
                                siteRow(site: site, icon: "clock", iconColor: .orange)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                        .padding(.top, 4)
                    }
                } else if !filtered.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(filtered, id: \.id) { site in
                                siteRow(site: site, icon: "magnifyingglass", iconColor: .secondary)
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                    .padding(.top, 4)
                }
            }
        }
    }

    private func siteRow(site: Dive, icon: String, iconColor: Color) -> some View {
        Button {
            let label = site.siteName + (site.location.isEmpty ? "" : " — \(site.location)")
            searchText = label
            selectedSite = site
            showSuggestions = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(iconColor)
                Text(site.siteName + (site.location.isEmpty ? "" : " — \(site.location)"))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            // The whole suggestion responds, not only its text (a plain Button only responds
            // where something is drawn).
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}



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
    /// Index of the photo to open; the preview loads its bytes itself.
    let index: Int
}

/// One photo in a dive's photo grid: a `DivePhoto` record, or an image still stored in the
/// legacy `Dive.photosData` array (until the user converts it).
struct DivePhotoEntry: Identifiable {
    enum Source {
        case photo(DivePhoto)
        case legacy(Int)
    }
    let id: String
    let source: Source

    var isLegacy: Bool {
        if case .legacy = source { return true }
        return false
    }
}

// MARK: - Photo Preview Sheet

struct PhotoPreviewSheet: View {
    /// One identifier per photo, in display order (the count of photos).
    let photoIDs: [String]
    /// Loads the bytes of the photo at an index. Called only for the photo being shown (and
    /// when it is shared or saved), so a dive with many photos never loads them all at once.
    let photoData: (Int) -> Data
    let initialIndex: Int
    /// A line shown under the photo at an index (e.g. why it is not on the dive profile).
    let photoNote: (Int) -> String?
    /// The photo record at an index, when it can be tagged with species (nil for a legacy
    /// photo, or where tagging is not offered).
    let photoRecord: (Int) -> DivePhoto?
    /// Removes the photo with an id (from `photoIDs`); nil hides the Remove button (e.g. a
    /// species gallery). An id, not an index: an import still running can add photos that
    /// sort ahead of the shown one while the confirmation is open.
    let onDelete: ((String) -> Void)?
    /// Whether the photo at an index can be removed now (the Remove button is disabled otherwise).
    let canDelete: (Int) -> Bool
    /// Whether the photo's original is here. While it is still downloading from iCloud the
    /// viewer shows the thumbnail and Share / Save As are disabled — the thumbnail is never
    /// handed out as the photo — and the page reloads when the original arrives.
    let hasOriginal: (Int) -> Bool
    /// A species whose name under the photo does not open its page: the viewer was opened
    /// from that species' own page, which is then one step back.
    let speciesPageShown: PersistentIdentifier?
    @Environment(\.dismiss) private var dismiss
    @Environment(DiveStore.self) private var store
    @State private var currentIndex: Int
    /// The species whose page is pushed from the names under the photo.
    @State private var shownSpecies: Species?
    @State private var showDeleteAlert = false
    /// The photo the Remove confirmation is about, taken when the button is tapped.
    @State private var deleteTargetID: String?
    @State private var taggingPhoto: DivePhoto?
    @State private var shareThumbnail: PlatformImage?
    @State private var cachedExportName: String
    @State private var cachedShareItem: PhotoTransferable?
    @State private var sessionTempFileURLs: Set<URL> = []
    @State private var isPreparingShare = false
    /// The photo shown in Quick Look (full screen and zoomable on iOS, a resizable, zoomable
    /// window on macOS): a temporary copy of the original, kept until the next launch (see
    /// `QuickLookCopies`).
    @State private var quickLookURL: URL?
    /// A copy is being written: further taps are ignored until it opens.
    @State private var isOpeningQuickLook = false
    /// The page identity of the photo shown now. Kept in state so a copy finishing its write
    /// is checked against the current photos, not those captured when it was tapped.
    @State private var shownPageID: String?

    init(photoIDs: [String], photoData: @escaping (Int) -> Data, initialIndex: Int,
         photoNote: @escaping (Int) -> String? = { _ in nil },
         photoRecord: @escaping (Int) -> DivePhoto? = { _ in nil },
         canDelete: @escaping (Int) -> Bool = { _ in true },
         hasOriginal: @escaping (Int) -> Bool = { _ in true },
         speciesPageShown: PersistentIdentifier? = nil,
         onDelete: ((String) -> Void)?) {
        self.speciesPageShown = speciesPageShown
        self.canDelete = canDelete
        self.hasOriginal = hasOriginal
        self.photoIDs = photoIDs
        self.photoData = photoData
        self.photoNote = photoNote
        self.photoRecord = photoRecord
        self.initialIndex = initialIndex
        self.onDelete = onDelete
        self._currentIndex = State(initialValue: initialIndex)
        // Seed the export name at construction time so the first body render
        // already has a valid filename — avoids an empty-name SharePreview.
        let exportPrefix = NSLocalizedString("BlueDive Photo", bundle: Bundle.forAppLanguage(), comment: "Prefix for exported photo filenames shown in share sheet and save dialog")
        self._cachedExportName = State(initialValue: "\(exportPrefix) \(PhotoPreviewSheet.exportDateFormatter.string(from: Date()))")
    }

    /// The species on the photo, each opening its page (pushed in this viewer, Back returns
    /// to the photo); the species whose page opened the viewer is shown as plain text.
    @ViewBuilder
    private func speciesLinks(_ species: [Species]) -> some View {
        ForEach(species) { item in
            let label = Label {
                Text(verbatim: item.displayName)
            } icon: {
                Image(systemName: "fish.fill")
                    .foregroundStyle(.orange)
            }
            .font(.caption.weight(.semibold))
            if item.persistentModelID == speciesPageShown {
                label
            } else {
                Button {
                    shownSpecies = item
                } label: {
                    HStack(spacing: 4) {
                        label
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    // A comfortable tap target around the small caption text.
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .borderlessButton()
                .foregroundStyle(.primary)
                .accessibilityHint(Text("Opens species details"))
            }
        }
    }

    /// Dive numbers for the pages pushed from a species page (as Marine Life builds them).
    /// Read only while a species page is shown (when the viewer redraws then).
    private var diveNumberMap: [PersistentIdentifier: Int] {
        let total = store.dives.count
        return Dictionary(store.dives.enumerated().map { ($0.element.persistentModelID, total - $0.offset) },
                          uniquingKeysWith: { first, _ in first })
    }

    // Returns nil when photos is empty so callers never subscript into an empty array,
    // and while the original is still downloading (only the original is exported).
    private var currentPhoto: Data? {
        guard !photoIDs.isEmpty else { return nil }
        let index = min(currentIndex, photoIDs.count - 1)
        guard hasOriginal(index) else { return nil }
        return photoData(index)
    }

    /// Page identity: the photo, whether its original is here, so the page reloads (from the
    /// thumbnail to the original) when the original arrives from iCloud, and the file's hash,
    /// so a photo replaced by a newer version (a re-import) reloads too.
    private func pageID(_ index: Int) -> String {
        "\(photoIDs[index])|\(hasOriginal(index))|\(photoRecord(index)?.contentHash?.hashValue ?? 0)"
    }

    var body: some View {
        NavigationStack {
            Group {
                if photoIDs.isEmpty {
                    AppBackground().ignoresSafeArea()
                } else {
                    // A paging scroll view, on every platform: it opens directly on the tapped
                    // photo (a paging TabView opened between two pages and had to be nudged
                    // into place, which showed as a short slide). Swipe on a touch screen or
                    // trackpad, or use the Previous / Next buttons.
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(photoIDs.indices, id: \.self) { index in
                                PhotoPageView(photoID: pageID(index), load: { photoData(index) }, index: index, total: photoIDs.count,
                                              isCurrent: index == currentIndex,
                                              canOpenQuickLook: hasOriginal(index),
                                              openQuickLook: { openInQuickLook(index) })
                                    .containerRelativeFrame([.horizontal, .vertical])
                                    .id(index)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollIndicators(.hidden)
                    // Centre anchor: the current photo changes once the next page fills most
                    // of the screen, not as soon as it peeks in during a swipe that may be
                    // cancelled.
                    .scrollPosition(id: Binding(
                        get: { currentIndex },
                        set: { if let index = $0 { currentIndex = index } }
                    ), anchor: .center)
                }
            }
            .background(AppBackground().ignoresSafeArea())
            .overlay(alignment: .bottom) {
                if !photoIDs.isEmpty {
                    let index = min(currentIndex, photoIDs.count - 1)
                    let species = (photoRecord(index)?.species ?? []).sorted { $0.displayName < $1.displayName }
                    let note = photoNote(index)
                    if !species.isEmpty || note != nil {
                        VStack(spacing: 4) {
                            if !species.isEmpty {
                                // Side by side when they fit, else one per line.
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 16) { speciesLinks(species) }
                                    VStack(spacing: 6) { speciesLinks(species) }
                                }
                            }
                            if let note {
                                Text(verbatim: note)
                                    .font(.caption)
                            }
                        }
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding()
                    }
                }
            }
            .quickLookPreview($quickLookURL)
            .onChange(of: thumbnailTaskID, initial: true) { _, _ in
                shownPageID = photoIDs.isEmpty ? nil : pageID(min(currentIndex, photoIDs.count - 1))
                #if os(macOS)
                // The shown photo changed (paged, removed, replaced) while the macOS Quick Look
                // panel, which does not block the viewer, was open: close it rather than keep
                // showing the previous photo. (On iOS Quick Look covers the viewer, which cannot
                // be paged meanwhile; a sync must not close the photo being looked at.)
                quickLookURL = nil
                #endif
            }
            .sheet(item: $taggingPhoto) { photo in
                PhotoSpeciesTagSheet(photo: photo)
                    .standardSheetPresentation()
            }
            .navigationDestination(item: $shownSpecies) { species in
                SpeciesDetailView(species: species, numberMap: diveNumberMap)
                    .closeSheetButtonOnMac { dismiss() }
                    // No "View Dives with This Critter" here (inherited from the Marine Life tab;
                    // on macOS the sheet root already clears it, on iOS this does).
                    .environment(\.showDiveList, nil)
            }
            .toolbar {
                if photoIDs.count > 1 {
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            // Animated here only: a swipe sets the index itself, mid-swipe.
                            withAnimation { currentIndex -= 1 }
                        } label: {
                            Label("Previous Photo", systemImage: "chevron.left")
                        }
                        .disabled(currentIndex == 0)
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Text(verbatim: "\(Double(currentIndex + 1).localizedString(decimals: 0)) / \(Double(photoIDs.count).localizedString(decimals: 0))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            withAnimation { currentIndex += 1 }
                        } label: {
                            Label("Next Photo", systemImage: "chevron.right")
                        }
                        .disabled(currentIndex == photoIDs.count - 1)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { dismiss() }
                }
                if !photoIDs.isEmpty, let record = photoRecord(min(currentIndex, photoIDs.count - 1)) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            taggingPhoto = record
                        } label: {
                            Image(systemName: "fish")
                        }
                        .accessibilityLabel(Text("Species on This Photo"))
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    #if os(macOS)
                    // macOS saves the photo straight to disk through a save panel.
                    Button {
                        savePhotoToDisk()
                    } label: {
                        Label("Save As", systemImage: "square.and.arrow.down")
                    }
                    // `hasOriginal` reads the link only; `currentPhoto` would load the original.
                    .disabled(photoIDs.isEmpty || !hasOriginal(min(currentIndex, photoIDs.count - 1)))
                    #else
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
                    #endif
                }
                if onDelete != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(role: .destructive) {
                            guard !photoIDs.isEmpty else { return }
                            deleteTargetID = photoIDs[min(currentIndex, photoIDs.count - 1)]
                            showDeleteAlert = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .disabled(photoIDs.isEmpty || !canDelete(min(currentIndex, photoIDs.count - 1)))
                        .accessibilityLabel(Text("Remove Photo"))
                    }
                }
            }
            .alert("Remove Photo", isPresented: $showDeleteAlert) {
                Button("Remove", role: .destructive) {
                    if let deleteTargetID {
                        onDelete?(deleteTargetID)
                        QuickLookCopies.remove(photoID: deleteTargetID)
                    }
                    deleteTargetID = nil
                    // onChange(of: photoIDs.count) handles both index clamping and dismissal
                    // when count reaches zero (covers in-app delete AND external iCloud sync).
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Remove this photo from the dive?")
            }
            .task(id: thumbnailTaskID) {
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
                guard let data = currentPhoto else {
                    // Nothing to share yet (the original is downloading): no share item, so
                    // the button is the disabled placeholder, never the previous photo.
                    cachedShareItem = nil
                    isPreparingShare = false
                    return
                }
                // Build the share item and thumbnail in one detached pass — the same
                // CGImageSource is reused for type detection and thumbnail decode,
                // so HEIC photos are parsed only once, fully off the main thread (at default
                // QoS through onImageQueue: ImageIO waits on its own default-QoS threads).
                let (thumbnail, shareItem): (PlatformImage?, PhotoTransferable) = await PhotoMetadataReader.onImageQueue {
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
                }
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
            .onChange(of: photoIDs.count) { _, newCount in
                if newCount == 0 {
                    // Covers both in-app delete-of-last and external iCloud sync emptying the array.
                    dismiss()
                } else {
                    currentIndex = min(currentIndex, newCount - 1)
                }
            }
            .onDisappear {
                #if os(macOS)
                // The macOS Quick Look panel does not block the viewer: close it with the viewer,
                // so it does not stay over the main window. (Not on iOS, where Quick Look's own
                // full-screen presentation may hide the viewer.)
                quickLookURL = nil
                #endif
                // Remove only the temp files this session predicted (one per photo navigated to).
                // SentTransferredFile(allowAccessingOriginalFile: false) (the default) causes the
                // system to copy the file before returning control, so deleting these paths is safe.
                // A prefix-based sweep is intentionally avoided: it would also remove files written
                // by other concurrently open photo sheets on iPad/Mac multi-window.
                // (Quick Look copies are not listed here: they are kept until the next launch.)
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
        guard !photoIDs.isEmpty else { return 0 }
        return pageID(min(currentIndex, photoIDs.count - 1)).hashValue
    }

    private var exportFileName: String {
        let prefix = NSLocalizedString("BlueDive Photo", bundle: Bundle.forAppLanguage(), comment: "Prefix for exported photo filenames shown in share sheet and save dialog")
        return "\(prefix) \(PhotoPreviewSheet.exportDateFormatter.string(from: Date()))"
    }

    /// Opens the photo at an index in Quick Look. Quick Look reads only files, so the original's
    /// bytes are written unchanged to a folder of their own in the temporary directory, once
    /// per photo version (see `QuickLookCopies`). Only the original is shown, never
    /// the thumbnail while it downloads.
    private func openInQuickLook(_ index: Int) {
        // Only the current photo (not a neighbouring page peeking in during a swipe).
        guard !isOpeningQuickLook, quickLookURL == nil, index == currentIndex,
              photoIDs.indices.contains(index), hasOriginal(index) else { return }
        let data = photoData(index)
        guard !data.isEmpty else { return }
        let pageAtTap = pageID(index)
        if let url = QuickLookCopies.copy(for: pageAtTap, byteCount: data.count) {
            quickLookURL = url
            return
        }
        let name = exportFileName
        isOpeningQuickLook = true
        Task {
            let folder = QuickLookCopies.newCopyFolder()
            let url: URL? = await Task.detached {
                // The same type detection and extension as Share and Save As.
                let url = folder.appendingPathComponent("\(name).\(PhotoTransferable(data: data, suggestedName: name).fileExtension)")
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    // Read-only: an app it is handed to (Preview) offers to duplicate it rather
                    // than save edits into a file BlueDive removes later.
                    try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
                    return url
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    return nil
                }
            }.value
            isOpeningQuickLook = false
            guard let url else { return }
            QuickLookCopies.record(url, for: pageAtTap, byteCount: data.count)
            // Not opened if the photo was paged away from, removed or replaced during the write
            // (Quick Look would show another photo than the viewer); the copy is still reused
            // if that photo is opened again. Read from state: this task's `photoIDs` and page
            // closures are those of the tap.
            guard shownPageID == pageAtTap else { return }
            quickLookURL = url
        }
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

// MARK: - Quick Look Copies

/// The temporary copies photos are opened from in Quick Look, on both platforms. They are not
/// removed when Quick Look or the viewer closes: Quick Look can hand the file to another app
/// ("Open with Preview" on macOS, share extensions), which reads it after Quick Look has
/// closed. One copy per photo version (the viewer's page identity: photo, original present,
/// content hash), reused when the photo is opened again. The latest copies are kept, up to
/// `maxCopies` and `maxBytes` (the newest always); the others are removed as new ones are
/// written, a removed photo's copies at once, all of them
/// on Erase all data, and whatever a previous launch left at the next launch.
@MainActor
enum QuickLookCopies {
    /// Name prefix of the launch folders, which identifies them in the launch sweep.
    nonisolated static let folderPrefix = "BlueDive-QuickLook-"

    /// This launch's folder, holding each copy in a subfolder of its own (under the export
    /// file name, which several copies can share).
    nonisolated static let launchFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(folderPrefix)\(UUID().uuidString)", isDirectory: true)

    /// How many copies a launch keeps (a few MB each, up to tens for large originals).
    private static let maxCopies = 20
    /// How much space they may use together (ProRAW or DNG originals can be 50–100 MB each).
    private static let maxBytes = 500_000_000

    /// This launch's copies by photo version, least recently opened first.
    private static var copies: [(key: String, url: URL, bytes: Int)] = []

    /// A new subfolder of this launch's folder, for one copy.
    nonisolated static func newCopyFolder() -> URL {
        launchFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// The copy already written for a photo version, if it is still there with the photo's
    /// size (else it is forgotten and written again).
    static func copy(for key: String, byteCount: Int) -> URL? {
        guard let index = copies.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = copies.remove(at: index)
        let size = (try? FileManager.default.attributesOfItem(atPath: entry.url.path))?[.size] as? Int
        guard size == byteCount else {
            removeFolder(of: entry.url)
            return nil
        }
        copies.append(entry)
        return entry.url
    }

    static func record(_ url: URL, for key: String, byteCount: Int) {
        if let index = copies.firstIndex(where: { $0.key == key }) {
            removeFolder(of: copies.remove(at: index).url)
        }
        copies.append((key, url, byteCount))
        // The oldest copies were opened photos ago: whatever they were handed to has long read
        // them. The newest one is always kept, even alone above the byte budget.
        while copies.count > maxCopies
                || (copies.count > 1 && copies.reduce(0, { $0 + $1.bytes }) > maxBytes) {
            removeFolder(of: copies.removeFirst().url)
        }
    }

    /// Removes the copies of a photo the user removed (keys start with its viewer id).
    static func remove(photoID: String) {
        let prefix = "\(photoID)|"
        for entry in copies where entry.key.hasPrefix(prefix) {
            removeFolder(of: entry.url)
        }
        copies.removeAll { $0.key.hasPrefix(prefix) }
    }

    /// Removes every copy of this launch (Erase all data).
    static func removeAll() {
        try? FileManager.default.removeItem(at: launchFolder)
        copies.removeAll()
    }

    private static func removeFolder(of url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Removes the copies previous launches left: every Quick Look folder but this launch's.
    /// Run once at launch. Touches only the Quick Look folders, nothing else in `tmp`.
    nonisolated static func removeLeftovers() {
        let fileManager = FileManager.default
        let tmp = fileManager.temporaryDirectory
        let current = launchFolder.lastPathComponent
        guard let names = try? fileManager.contentsOfDirectory(atPath: tmp.path) else { return }
        // Only folders this code names: the prefix followed by a launch UUID.
        for name in names where name.hasPrefix(folderPrefix) && name != current
            && UUID(uuidString: String(name.dropFirst(folderPrefix.count))) != nil {
            try? fileManager.removeItem(at: tmp.appendingPathComponent(name, isDirectory: true))
        }
    }
}

// MARK: - Photo Page View

private struct PhotoPageView: View {
    let photoID: String
    /// Reads the photo's bytes when the page appears (not when it is created).
    let load: () -> Data
    let index: Int
    let total: Int
    /// The photo the viewer shows. Its image is kept when it disappears behind a pushed page
    /// (a species page), so Back shows it at once instead of a spinner (it is still read and
    /// decoded again, when the page reappears).
    let isCurrent: Bool
    /// Whether a tap opens the photo in Quick Look (its original is here).
    let canOpenQuickLook: Bool
    let openQuickLook: () -> Void
    @State private var image: PlatformImage?

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    // Tap or click the photo itself (not the margin around it) to open it in
                    // Quick Look; a swipe still pages through the photos.
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                    .onTapGesture { openQuickLook() }
                    .allowsHitTesting(canOpenQuickLook)
                    .accessibilityAddTraits(canOpenQuickLook ? .isButton : [])
                    .accessibilityHint(canOpenQuickLook ? Text("Opens the photo in Quick Look") : Text(verbatim: ""))
                    // VoiceOver and Full Keyboard Access activate this, not the tap gesture.
                    .accessibilityAction {
                        if canOpenQuickLook { openQuickLook() }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(Text(verbatim: String(format: NSLocalizedString("Photo %@ of %@", bundle: .forAppLanguage(), value: "Photo %@ of %@", comment: "Announces the current photo's position while paging through photos (locale-formatted numbers)"), Double(index + 1).localizedString(decimals: 0), Double(total).localizedString(decimals: 0))))
            } else {
                ZStack {
                    AppBackground().ignoresSafeArea()
                    ProgressView()
                }
            }
        }
        .task(id: photoID) {
            let d = load()
            // At default QoS (ImageIO, often a HEIC original); nil: the page scrolled away
            // while waiting for its turn (nothing decoded).
            guard let decoded = await PhotoMetadataReader.onImageQueueUnlessCancelled({
                PlatformImage(data: d)
            }), !Task.isCancelled else { return }
            image = decoded
        }
        // A page scrolled away keeps its state in the viewer's lazy stack: release its
        // full-size image (the task decodes it again when the page comes back). By then the
        // current photo has moved on, so the shown photo is never released this way.
        .onDisappear {
            if !isCurrent { image = nil }
        }
    }
}
