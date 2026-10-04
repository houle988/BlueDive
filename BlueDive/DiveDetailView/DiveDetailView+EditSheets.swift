import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreLocation

// MARK: - Edit Popup Views

/// Popup de modification pour l'onglet Menu (stats principales)
struct EditMenuStatsView: View {
    @Bindable var dive: Dive
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(DiveStore.self) private var store
    @AppStorage("autoSequenceEnabled") private var autoSequenceEnabled = false

    @State private var workingMaxDepth: Double
    @State private var workingAvgDepth: Double
    @State private var workingDuration: Int
    @State private var workingWeights: Double?
    @State private var workingWeightsText: String
    @State private var workingDiverName: String
    @State private var workingBuddies: String
    @State private var workingTypes: String
    @State private var workingRating: Int
    @State private var workingNotes: String
    @State private var workingTags: String
    @State private var workingDiveNumber: String
    @State private var workingDiveMaster: String
    @State private var workingSkipper: String
    @State private var workingBoat: String
    @State private var workingDiveCenter: String
    @State private var workingEntryType: String
    @State private var newTag: String = ""
    @State private var newBuddy: String = ""
    @State private var newType: String = ""
    @State private var workingMaxDepthText: String
    @State private var workingAvgDepthText: String
    /// Stored depths behind the 2-decimal pre-fill text, so an untouched field saves the stored
    /// value unchanged (see PrefilledDouble). @State: captured once when the sheet opens, like
    /// the text, so a parent re-render (e.g. an iCloud sync) cannot unpair them.
    @State private var prefilledMaxDepth: PrefilledDouble
    @State private var prefilledAvgDepth: PrefilledDouble
    @State private var workingDurationText: String
    /// The duration's pre-fill text (empty when the stored duration is 0 or less), so an
    /// untouched field keeps the stored duration exactly.
    @State private var initialDurationText: String
    @State private var workingComputerName: String
    @State private var workingSerialNumber: String
    @State private var workingTimestamp: Date

    init(dive: Dive) {
        self.dive = dive
        _workingMaxDepth  = State(initialValue: dive.maxDepth)
        _workingAvgDepth  = State(initialValue: dive.averageDepth)
        _workingDuration  = State(initialValue: dive.duration)
        _workingWeights   = State(initialValue: dive.weights)
        _workingWeightsText = State(initialValue: dive.weights.map { $0.editableString(decimals: 2) } ?? "")
        _workingDiverName = State(initialValue: dive.diverName)
        _workingBuddies   = State(initialValue: dive.buddies)
        _workingTypes = State(initialValue: dive.diveTypes ?? "")
        _workingRating    = State(initialValue: dive.rating)
        _workingNotes     = State(initialValue: dive.notes)
        _workingTags      = State(initialValue: dive.tags ?? "")
        _workingDiveNumber = State(initialValue: dive.diveNumber.map { "\($0)" } ?? "")
        _workingDiveMaster = State(initialValue: dive.diveMaster ?? "")
        _workingSkipper    = State(initialValue: dive.skipper ?? "")
        _workingBoat       = State(initialValue: dive.boat ?? "")
        _workingDiveCenter = State(initialValue: dive.diveOperator ?? "")
        _workingEntryType  = State(initialValue: dive.entryType ?? "")
        // A depth of 0 means "not recorded" and is shown as an empty field.
        let maxDepth = PrefilledDouble(value: dive.maxDepth,
                                       text: dive.maxDepth > 0 ? dive.maxDepth.editableString(decimals: 2) : "")
        let avgDepth = PrefilledDouble(value: dive.averageDepth,
                                       text: dive.averageDepth > 0 ? dive.averageDepth.editableString(decimals: 2) : "")
        _prefilledMaxDepth    = State(initialValue: maxDepth)
        _prefilledAvgDepth    = State(initialValue: avgDepth)
        _workingMaxDepthText  = State(initialValue: maxDepth.text)
        _workingAvgDepthText  = State(initialValue: avgDepth.text)
        let durationText = dive.duration > 0 ? String(dive.duration) : ""
        _workingDurationText  = State(initialValue: durationText)
        _initialDurationText  = State(initialValue: durationText)
        _workingComputerName  = State(initialValue: dive.computerName)
        _workingSerialNumber  = State(initialValue: dive.computerSerialNumber ?? "")
        _workingTimestamp     = State(initialValue: dive.timestamp)
    }

    private var tagsArray: [String] {
        workingTags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var buddiesArray: [String] {
        workingBuddies
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var diveTypesArray: [String] {
        workingTypes
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "None" }
    }

    private func addTag(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        var tags = tagsArray
        if !tags.contains(trimmed) {
            tags.append(trimmed)
            workingTags = tags.joined(separator: ", ")
        }
    }

    private func removeTag(_ tag: String) {
        var tags = tagsArray
        tags.removeAll { $0 == tag }
        workingTags = tags.joined(separator: ", ")
    }

    private func addBuddy(_ buddy: String) {
        let trimmed = buddy.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        var buddies = buddiesArray
        if !buddies.contains(trimmed) {
            buddies.append(trimmed)
            workingBuddies = buddies.joined(separator: ", ")
        }
    }

    private func removeBuddy(_ buddy: String) {
        var buddies = buddiesArray
        buddies.removeAll { $0 == buddy }
        workingBuddies = buddies.joined(separator: ", ")
    }

    private func addDiveType(_ type: String) {
        let trimmed = type.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "None" else { return }

        var types = diveTypesArray
        if !types.contains(trimmed) {
            types.append(trimmed)
            workingTypes = types.joined(separator: ", ")
        }
    }

    private func removeDiveType(_ type: String) {
        var types = diveTypesArray
        types.removeAll { $0 == type }
        workingTypes = types.joined(separator: ", ")
    }

    private func uniqueOptionalValues(for keyPath: KeyPath<Dive, String?>) -> [String] {
        var seen = Set<String>()
        return store.dives.compactMap { d -> String? in
            guard let val = d[keyPath: keyPath]?.trimmingCharacters(in: .whitespaces),
                  !val.isEmpty else { return nil }
            let key = val.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return val
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func uniqueValues(for keyPath: KeyPath<Dive, String>) -> [String] {
        var seen = Set<String>()
        return store.dives.compactMap { d -> String? in
            let val = d[keyPath: keyPath].trimmingCharacters(in: .whitespaces)
            guard !val.isEmpty else { return nil }
            let key = val.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return val
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // DiveStore's complete diver list (dives, gear, certifications, insurance).
    private var uniqueDiverNames: [String] { store.cachedUniqueDivers }

    private var uniqueBuddyNames: [String] {
        var seen = Set<String>()
        return store.dives.flatMap { d -> [String] in
            d.buddies
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }.compactMap { name -> String? in
            let key = name.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return name
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var uniqueDiveTypeNames: [String] {
        var seen = Set<String>()
        return store.dives.flatMap { d -> [String] in
            (d.diveTypes ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }.compactMap { name -> String? in
            let key = name.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return name
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        iOSBody
    }


    @ViewBuilder
    private var iOSManualDiveSections: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.to.line")
                    .foregroundStyle(.cyan)
                    .frame(width: 24)
                Text("Max Depth (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit))")
                    .foregroundStyle(.primary)
                formTextField("Max Depth (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit))", text: $workingMaxDepthText)
                    .platformKeyboardType(.decimalPad)
                    .foregroundStyle(.primary)
                    .onChange(of: workingMaxDepthText) {
                        workingMaxDepth = parseFlexibleDouble(workingMaxDepthText) ?? 0
                    }
                if !workingMaxDepthText.isEmpty {
                    Button {
                        workingMaxDepthText = ""
                        workingMaxDepth = 0
                    } label: {
                        ClearButtonGlyph()
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 12) {
                Image(systemName: "arrow.left.and.right")
                    .foregroundStyle(.cyan)
                    .frame(width: 24)
                Text("Avg Depth (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit))")
                    .foregroundStyle(.primary)
                formTextField("Avg Depth (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit))", text: $workingAvgDepthText)
                    .platformKeyboardType(.decimalPad)
                    .foregroundStyle(.primary)
                    .onChange(of: workingAvgDepthText) {
                        workingAvgDepth = parseFlexibleDouble(workingAvgDepthText) ?? 0
                    }
                if !workingAvgDepthText.isEmpty {
                    Button {
                        workingAvgDepthText = ""
                        workingAvgDepth = 0
                    } label: {
                        ClearButtonGlyph()
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 12) {
                Image(systemName: "clock")
                    .foregroundStyle(.cyan)
                    .frame(width: 24)
                Text("Duration (min)")
                    .foregroundStyle(.primary)
                formTextField("Duration (min)", text: $workingDurationText)
                    .platformKeyboardType(.numberPad)
                    .foregroundStyle(.primary)
                    .onChange(of: workingDurationText) {
                        workingDuration = Self.durationMinutes(workingDurationText) ?? 0
                    }
                if !workingDurationText.isEmpty {
                    Button {
                        workingDurationText = ""
                        workingDuration = 0
                    } label: {
                        ClearButtonGlyph()
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            MenuSectionHeader(title: "Dive Stats", icon: "chart.bar", color: .cyan)
        } footer: {
            Text("Unit (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit)) matches the original import format and cannot be changed.")
                .font(.caption2)
        }
        Section {
            AutocompleteMenuTextField(label: "Computer Name", text: $workingComputerName, icon: "desktopcomputer", color: .purple, suggestions: uniqueValues(for: \.computerName))
            AutocompleteMenuTextField(label: "Serial Number", text: $workingSerialNumber, icon: "number", color: .purple, suggestions: uniqueOptionalValues(for: \.computerSerialNumber))
        } header: {
            MenuSectionHeader(title: "Dive Computer", icon: "desktopcomputer", color: .purple)
        }
    }

    private var iOSBody: some View {
        NavigationStack {
            ZStack {
                AppBackground().ignoresSafeArea()

                Form {
                    Section {
                        AutocompleteMenuTextField(label: "Diver", text: $workingDiverName, icon: "person", color: .cyan, suggestions: uniqueDiverNames)
                        HStack(spacing: 12) {
                            Image(systemName: "number")
                                .foregroundStyle(.orange)
                                .frame(width: 24)
                            Text("Dive #")
                                .foregroundStyle(.primary)
                            Spacer()
                            formTextField("Dive #", text: $workingDiveNumber)
                                .platformKeyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                                .foregroundStyle(.cyan)
                            if !workingDiveNumber.isEmpty {
                                Button {
                                    workingDiveNumber = ""
                                } label: {
                                    ClearButtonGlyph()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        MenuSectionHeader(title: "Diver", icon: "person", color: .blue)
                    }

                    Section {
                        DatePicker("Date & Time", selection: $workingTimestamp, displayedComponents: [.date, .hourAndMinute])
                            .adaptiveDatePickerStyle()
                    } header: {
                        MenuSectionHeader(title: "Date & Time", icon: "calendar", color: .indigo)
                    }

                    Section {
                        AutocompleteMenuTextField(label: "Dive Center", text: $workingDiveCenter, icon: "building.2", color: .blue, suggestions: uniqueOptionalValues(for: \.diveOperator))
                        AutocompleteMenuTextField(label: "Guide/Instructor", text: $workingDiveMaster, icon: "person.badge.shield.checkmark", color: .teal, suggestions: uniqueOptionalValues(for: \.diveMaster))
                        AutocompleteMenuTextField(label: "Captain", text: $workingSkipper, icon: "person.fill.turn.right", color: .indigo, suggestions: uniqueOptionalValues(for: \.skipper))
                        AutocompleteMenuTextField(label: "Boat", text: $workingBoat, icon: "ferry", color: .mint, suggestions: uniqueOptionalValues(for: \.boat))
                        AutocompleteMenuTextField(label: "Entry Type", text: $workingEntryType, icon: "arrow.down.to.line.circle", color: .yellow, suggestions: uniqueOptionalValues(for: \.entryType))
                    } header: {
                        MenuSectionHeader(title: "Operator", icon: "building.2", color: .teal)
                    }

                    Section {
                        // Current buddies
                        if !buddiesArray.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(buddiesArray.chunked(into: 3), id: \.self) { chunk in
                                    HStack(spacing: 8) {
                                        ForEach(chunk, id: \.self) { buddy in
                                            HStack(spacing: 6) {
                                                Text(buddy)
                                                    .font(.subheadline)
                                                Button {
                                                    withAnimation {
                                                        removeBuddy(buddy)
                                                    }
                                                } label: {
                                                    // Chip grid: 12 pt horizontal / 6 pt vertical
                                                    // chip padding, 8 pt between chips and 8 pt
                                                    // between rows. Grows only half of each 8 pt
                                                    // gap (4 pt) so neighbouring chips' targets
                                                    // touch without overlapping. 36 × 34 pt.
                                                    TapTargetInset(top: 10, leading: 6, bottom: 10, trailing: 16) {
                                                        Image(systemName: "xmark.circle")
                                                            .font(.caption)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                }
                                                .buttonStyle(.plain)
                                                .accessibilityLabel(Text(verbatim: String(format: NSLocalizedString("Remove %@", bundle: .forAppLanguage(), comment: "Accessibility label for a button that removes a filter chip, naming the specific value it removes"), buddy)))
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Color.green.opacity(0.15))
                                            .foregroundStyle(.green)
                                            .cornerRadius(16)
                                        }
                                    }
                                }
                            }
                        }

                        // Add new buddy
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.green)
                                formTextField("Add a buddy", text: $newBuddy)
                                    .autocorrectionDisabled()
                                    .foregroundStyle(.primary)
                                if !newBuddy.isEmpty {
                                    Button {
                                        newBuddy = ""
                                    } label: {
                                        ClearButtonGlyph()
                                    }
                                    .buttonStyle(.plain)
                                }
                                Button("Add") {
                                    withAnimation {
                                        addBuddy(newBuddy)
                                        newBuddy = ""
                                    }
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(newBuddy.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.green)
                                .disabled(newBuddy.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            let filteredBuddySuggestions = newBuddy.isEmpty ? [] : uniqueBuddyNames.filter {
                                $0.localizedCaseInsensitiveContains(newBuddy) && $0.lowercased() != newBuddy.lowercased() && !buddiesArray.contains($0)
                            }
                            if !filteredBuddySuggestions.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(filteredBuddySuggestions.prefix(5), id: \.self) { suggestion in
                                        Button {
                                            addBuddy(suggestion)
                                            newBuddy = ""
                                        } label: {
                                            Text(suggestion)
                                                .foregroundStyle(.primary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.vertical, 6)
                                                .padding(.horizontal, 8)
                                                // The whole suggestion responds, not only its text
                                                // (a plain Button only responds where something is drawn).
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .background(Color.primary.opacity(0.05))
                                        .cornerRadius(4)
                                    }
                                }
                                .padding(.leading, 28)
                                .padding(.top, 4)
                            }
                        }
                    } header: {
                        MenuSectionHeader(title: "Buddies", icon: "person.2", color: .green)
                    }

                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "scalemass")
                                .foregroundStyle(.gray)
                                .frame(width: 24)
                            Text("Weight (\(dive.storedWeightUnit.symbol))")
                                .foregroundStyle(.primary)
                            formTextField("Weight (\(dive.storedWeightUnit.symbol))", text: $workingWeightsText)
                                .platformKeyboardType(.decimalPad)
                                .foregroundStyle(.primary)
                                .onChange(of: workingWeightsText) {
                                    workingWeights = parseFlexibleDouble(workingWeightsText)
                                }
                            if workingWeights != nil {
                                Button {
                                    workingWeights = nil
                                    workingWeightsText = ""
                                } label: {
                                    ClearButtonGlyph()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        MenuSectionHeader(title: "Weight", icon: "scalemass", color: .gray)
                    } footer: {
                        Text("Unit (\(dive.storedWeightUnit.symbol)) matches the original import format and cannot be changed.")
                            .font(.caption2)
                    }

                    if dive.sourceImport == "Manual" {
                        iOSManualDiveSections
                    }

                    Section {
                        // Current dive types
                        if !diveTypesArray.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(diveTypesArray.chunked(into: 3), id: \.self) { chunk in
                                    HStack(spacing: 8) {
                                        ForEach(chunk, id: \.self) { type in
                                            HStack(spacing: 6) {
                                                Text(type)
                                                    .font(.subheadline)
                                                Button {
                                                    withAnimation {
                                                        removeDiveType(type)
                                                    }
                                                } label: {
                                                    // Same chip grid geometry as the buddy chips:
                                                    // grows 4 pt (half of the 8 pt gap) toward the
                                                    // next chip and the next row. 36 × 34 pt.
                                                    TapTargetInset(top: 10, leading: 6, bottom: 10, trailing: 16) {
                                                        Image(systemName: "xmark.circle")
                                                            .font(.caption)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                }
                                                .buttonStyle(.plain)
                                                .accessibilityLabel(Text(verbatim: String(format: NSLocalizedString("Remove %@", bundle: .forAppLanguage(), comment: "Accessibility label for a button that removes a filter chip, naming the specific value it removes"), type)))
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Color.purple.opacity(0.15))
                                            .foregroundStyle(.purple)
                                            .cornerRadius(16)
                                        }
                                    }
                                }
                            }
                        }

                        // Add new dive type
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.purple)
                                formTextField("Add a dive type", text: $newType)
                                    .autocorrectionDisabled()
                                    .foregroundStyle(.primary)
                                if !newType.isEmpty {
                                    Button {
                                        newType = ""
                                    } label: {
                                        ClearButtonGlyph()
                                    }
                                    .buttonStyle(.plain)
                                }
                                Button("Add") {
                                    withAnimation {
                                        addDiveType(newType)
                                        newType = ""
                                    }
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(newType.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.purple)
                                .disabled(newType.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            let filteredDiveTypeSuggestions = newType.isEmpty ? [] : uniqueDiveTypeNames.filter {
                                $0.localizedCaseInsensitiveContains(newType) && $0.lowercased() != newType.lowercased() && !diveTypesArray.contains($0)
                            }
                            if !filteredDiveTypeSuggestions.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(filteredDiveTypeSuggestions.prefix(5), id: \.self) { suggestion in
                                        Button {
                                            addDiveType(suggestion)
                                            newType = ""
                                        } label: {
                                            Text(suggestion)
                                                .foregroundStyle(.primary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.vertical, 6)
                                                .padding(.horizontal, 8)
                                                // The whole suggestion responds, not only its text
                                                // (a plain Button only responds where something is drawn).
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .background(Color.primary.opacity(0.05))
                                        .cornerRadius(4)
                                    }
                                }
                                .padding(.leading, 28)
                                .padding(.top, 4)
                            }
                        }

                        HStack {
                            Image(systemName: "star")
                                .foregroundStyle(.yellow)
                            Text("Rating")
                                .foregroundStyle(.primary)
                            Spacer()
                            HStack(spacing: 8) {
                                ForEach(1...5, id: \.self) { star in
                                    Image(systemName: star <= workingRating ? "star.fill" : "star")
                                        .font(.title3)
                                        .foregroundStyle(star <= workingRating ? .yellow : .secondary)
                                        .onTapGesture {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                workingRating = star == workingRating ? 0 : star
                                            }
                                        }
                                        .accessibilityElement()
                                        .accessibilityLabel(Text(verbatim: String(format: NSLocalizedString("%lld star", bundle: .forAppLanguage(), comment: "Star rating button label; tapping it sets the dive rating to this many stars"), star)))
                                        .accessibilityAddTraits(star <= workingRating ? [.isButton, .isSelected] : .isButton)
                                        // onTapGesture isn't reliably fired by VoiceOver's activate
                                        // gesture; this makes double-tap set the rating.
                                        .accessibilityAction {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                workingRating = star == workingRating ? 0 : star
                                            }
                                        }
                                }
                            }
                        }
                    } header: {
                        MenuSectionHeader(title: "Type & Rating", icon: "star", color: .yellow)
                    }

                    Section {
                        // Current tags
                        if !tagsArray.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(tagsArray.chunked(into: 3), id: \.self) { chunk in
                                    HStack(spacing: 8) {
                                        ForEach(chunk, id: \.self) { tag in
                                            HStack(spacing: 6) {
                                                Text(tag)
                                                    .font(.subheadline)
                                                Button {
                                                    withAnimation {
                                                        removeTag(tag)
                                                    }
                                                } label: {
                                                    // Same chip grid geometry as the buddy chips:
                                                    // grows 4 pt (half of the 8 pt gap) toward the
                                                    // next chip and the next row. 36 × 34 pt.
                                                    TapTargetInset(top: 10, leading: 6, bottom: 10, trailing: 16) {
                                                        Image(systemName: "xmark.circle")
                                                            .font(.caption)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                }
                                                .buttonStyle(.plain)
                                                .accessibilityLabel(Text(verbatim: String(format: NSLocalizedString("Remove %@", bundle: .forAppLanguage(), comment: "Accessibility label for a button that removes a filter chip, naming the specific value it removes"), tag)))
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Color.cyan.opacity(0.15))
                                            .foregroundStyle(.cyan)
                                            .cornerRadius(16)
                                        }
                                    }
                                }
                            }
                        }

                        // Add new tag
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(.cyan)
                            formTextField("Add a tag", text: $newTag)
                                .autocorrectionDisabled()
                                .foregroundStyle(.primary)
                            if !newTag.isEmpty {
                                Button {
                                    newTag = ""
                                } label: {
                                    ClearButtonGlyph()
                                }
                                .buttonStyle(.plain)
                            }
                            Button("Add") {
                                withAnimation {
                                    addTag(newTag)
                                    newTag = ""
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } header: {
                        MenuSectionHeader(title: "Tags", icon: "tag", color: .pink)
                    }

                    Section {
                        TextEditor(text: $workingNotes)
                            .frame(minHeight: 100)
                            .scrollContentBackground(.hidden)
                            .foregroundStyle(.primary)
                    } header: {
                        MenuSectionHeader(title: "Notes", icon: "note.text", color: .orange)
                    }
                }
                .groupedFormStyleOnMac()
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Edit Dive")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .bold()
                }
            }
        }
    }

    /// Accepted duration range in minutes (about 69 days). Rejecting values outside it keeps
    /// later Int arithmetic safe (e.g. `duration * 60` in DiveSummary and surface intervals).
    private static let durationMinutesRange = 0...100_000

    /// Whole minutes from the duration text, rounded to the nearest minute (45.9 → 46), or nil
    /// when empty, unreadable or outside durationMinutesRange (Int(exactly:) never traps).
    private static func durationMinutes(_ text: String) -> Int? {
        guard let minutes = parseFlexibleDouble(text).flatMap({ Int(exactly: $0.rounded()) }),
              durationMinutesRange.contains(minutes) else { return nil }
        return minutes
    }

    private func save() {
        // An untouched field keeps the stored value at full precision (the text is rounded).
        dive.maxDepth     = prefilledMaxDepth.resolve(workingMaxDepthText) ?? workingMaxDepth
        dive.averageDepth = prefilledAvgDepth.resolve(workingAvgDepthText) ?? workingAvgDepth
        // Duration is stored in whole minutes: a decimal entry is rounded to the nearest minute.
        // An untouched field keeps the stored duration exactly; an emptied one clears it (0, as
        // before); an entry that cannot be read, or is out of range, keeps the stored duration.
        let trimmedDuration = workingDurationText.trimmingCharacters(in: .whitespaces)
        if trimmedDuration != initialDurationText {
            dive.duration = trimmedDuration.isEmpty ? 0 : (Self.durationMinutes(trimmedDuration) ?? dive.duration)
        }
        dive.weights      = workingWeights
        let originalDiverName = dive.diverName
        dive.diverName    = workingDiverName.trimmingCharacters(in: .whitespaces)
        let diverNameDidChange = dive.diverName != originalDiverName
        dive.buddies      = workingBuddies.trimmingCharacters(in: .whitespaces)

        // Save dive types
        let types = diveTypesArray
        dive.diveTypes = types.isEmpty ? nil : types.joined(separator: ", ")

        dive.rating       = workingRating
        let trimmedNotes  = workingNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        dive.notes        = trimmedNotes
        dive.tags         = workingTags.isEmpty ? nil : workingTags
        dive.diveNumber   = Int(workingDiveNumber.trimmingCharacters(in: .whitespaces))
        let trimmedDiveMaster  = workingDiveMaster.trimmingCharacters(in: .whitespaces)
        dive.diveMaster   = trimmedDiveMaster.isEmpty ? nil : trimmedDiveMaster
        let trimmedSkipper     = workingSkipper.trimmingCharacters(in: .whitespaces)
        dive.skipper      = trimmedSkipper.isEmpty ? nil : trimmedSkipper
        let trimmedBoat        = workingBoat.trimmingCharacters(in: .whitespaces)
        dive.boat         = trimmedBoat.isEmpty ? nil : trimmedBoat
        let trimmedDiveCenter  = workingDiveCenter.trimmingCharacters(in: .whitespaces)
        dive.diveOperator = trimmedDiveCenter.isEmpty ? nil : trimmedDiveCenter
        let trimmedEntryType   = workingEntryType.trimmingCharacters(in: .whitespaces)
        dive.entryType    = trimmedEntryType.isEmpty ? nil : trimmedEntryType
        let trimmedComputerName = workingComputerName.trimmingCharacters(in: .whitespaces)
        dive.computerName = trimmedComputerName
        let trimmedSerial = workingSerialNumber.trimmingCharacters(in: .whitespaces)
        dive.computerSerialNumber = trimmedSerial.isEmpty ? nil : trimmedSerial
        // Seconds must always be written back exactly as they were recorded by the dive computer.
        // The picker never exposes seconds to the user, so discarding them would silently destroy
        // sub-minute precision that the dive computer captured (e.g. surface-interval calculations).
        var timestampDidChange = false
        // The picker offers .hourAndMinute only (seconds are unavailable on macOS) —
        // graft the original seconds back so they are never lost.
        let cal = Calendar.current
        var newComponents = cal.dateComponents([.year, .month, .day, .hour, .minute], from: workingTimestamp)
        newComponents.second = cal.component(.second, from: dive.timestamp)
        if let rebuilt = cal.date(from: newComponents) {
            let origFloor = floor(dive.timestamp.timeIntervalSinceReferenceDate)
            let newFloor = floor(rebuilt.timeIntervalSinceReferenceDate)
            if origFloor != newFloor {
                dive.timestamp = rebuilt
                timestampDidChange = true
            }
        }
        if timestampDidChange || diverNameDidChange {
            // Flush changes to the persistent store so the background context sees
            // the updated values when it fetches all dives for recalculation.
            try? modelContext.save()
            if autoSequenceEnabled {
                store.recalcSequencesInBackground(
                    container: modelContext.container,
                    newDiverName: dive.diverName,
                    originalDiverName: originalDiverName
                )
            }
        }
        // First commit triggers an immediate list rebuild; surface intervals update
        // via the second commit from the background task when applicable.
        store.commit(dive, affects: .list)
        dismiss()
    }
}

struct EditSiteDetailsView: View {
    @Bindable var dive: Dive
    @Environment(\.dismiss) private var dismiss
    @Environment(DiveStore.self) private var store
    // store.dives is sorted by timestamp desc (same order ContentView's @Query delivers)
    private var allDivesByDate: [Dive] { store.dives }

    @State private var selectedSite: Dive? = nil
    @State private var copyGPSCoordinates: Bool = true
    @State private var workingCountry: String
    @State private var workingLocation: String
    @State private var workingSiteName: String
    @State private var workingWaterType: String
    @State private var workingBodyOfWater: String
    @State private var workingLatitude: String
    @State private var workingLongitude: String
    @State private var workingAltitude: String
    @State private var workingDifficulty: String
    @State private var workingExitLatitude: String
    @State private var workingExitLongitude: String
    /// Stored values behind the rounded pre-fill text ("%.6f" coordinates, whole-metre
    /// altitude), so untouched fields save the stored value unchanged (see preservedDouble).
    /// Updated by applySite, so copying a site keeps the source's full precision.
    @State private var prefilledLatitude: PrefilledDouble
    @State private var prefilledLongitude: PrefilledDouble
    @State private var prefilledAltitude: PrefilledDouble
    @State private var prefilledExitLatitude: PrefilledDouble
    @State private var prefilledExitLongitude: PrefilledDouble

    @State private var showEntryCoordinatePicker = false
    @State private var showExitCoordinatePicker = false
    @State private var showSameAsEntryConfirm = false

    /// The entry coordinate currently in the form fields, or nil if unset/invalid — mirrors
    /// `Dive.hasGPSCoordinates`'s (0, 0)-sentinel handling.
    private var entryCoordinate: CLLocationCoordinate2D? {
        guard let lat = parseFlexibleDouble(workingLatitude),
              let lon = parseFlexibleDouble(workingLongitude),
              !(lat == 0 && lon == 0) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// The exit coordinate currently in the form fields, or nil if unset/invalid.
    private var exitCoordinate: CLLocationCoordinate2D? {
        guard let lat = parseFlexibleDouble(workingExitLatitude),
              let lon = parseFlexibleDouble(workingExitLongitude),
              !(lat == 0 && lon == 0) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func copyEntryToExit() {
        // Copy the entry's exact values, not just its rounded text, so an untouched entry and
        // its copy stay identical (the Site Details map shows one "Entry & exit" pin then).
        prefilledExitLatitude  = PrefilledDouble(value: prefilledLatitude.resolve(workingLatitude), text: workingLatitude)
        prefilledExitLongitude = PrefilledDouble(value: prefilledLongitude.resolve(workingLongitude), text: workingLongitude)
        workingExitLatitude = workingLatitude
        workingExitLongitude = workingLongitude
    }

    /// Small text-button style shared by the Reset / Pick on Map / Same as Entry actions
    /// in each GPS section header, matching the pre-existing "Reset" button's appearance.
    private func gpsHeaderActionButton(_ title: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(enabled ? .blue : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var canResetEntryGPS: Bool {
        guard let rawData = dive.rawDiveComputerData else { return false }
        return ShearwaterPNFGPS.extractEntryGPS(from: rawData) != nil
    }

    private var canResetExitGPS: Bool {
        guard let rawData = dive.rawDiveComputerData else { return false }
        return ShearwaterPNFGPS.extractExitGPS(from: rawData) != nil
    }

    static let difficultyScale: [(level: Int, label: String)] = [
        (1, "Very Easy"),
        (2, "Easy"),
        (3, "Easy-Moderate"),
        (4, "Moderate"),
        (5, "Moderate"),
        (6, "Moderate-Challenging"),
        (7, "Challenging"),
        (8, "Very Challenging"),
        (9, "Expert"),
        (10, "Extreme")
    ]

    private var workingDifficultyLevel: Int {
        // Try parsing as number first, then match by label
        if let n = Int(workingDifficulty), (1...10).contains(n) { return n }
        return Self.difficultyScale.first(where: { $0.label == workingDifficulty })?.level ?? 0
    }

    private var uniqueSites: [Dive] {
        var seen = Set<String>()
        return store.dives.compactMap { d -> Dive? in
            guard d.id != dive.id,
                  !d.siteName.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let key = d.siteName.trimmingCharacters(in: .whitespaces).lowercased()
            guard seen.insert(key).inserted else { return nil }
            return d
        }.sorted { $0.siteName.localizedCaseInsensitiveCompare($1.siteName) == .orderedAscending }
    }

    /// The 3 most recently dived sites (by date, unique by name)
    private var recentSites: [Dive] {
        var seen = Set<String>()
        var result: [Dive] = []
        for d in allDivesByDate {
            guard d.id != dive.id,
                  !d.siteName.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let key = d.siteName.trimmingCharacters(in: .whitespaces).lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(d)
            if result.count == 3 { break }
        }
        return result
    }

    private func uniqueValues(for keyPath: KeyPath<Dive, String>) -> [String] {
        var seen = Set<String>()
        return store.dives.compactMap { d -> String? in
            let val = d[keyPath: keyPath].trimmingCharacters(in: .whitespaces)
            guard !val.isEmpty else { return nil }
            let key = val.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return val
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func uniqueOptionalValues(for keyPath: KeyPath<Dive, String?>) -> [String] {
        var seen = Set<String>()
        return store.dives.compactMap { d -> String? in
            guard let val = d[keyPath: keyPath]?.trimmingCharacters(in: .whitespaces),
                  !val.isEmpty else { return nil }
            let key = val.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return val
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func applySite(from source: Dive) {
        workingCountry     = source.siteCountry ?? ""
        workingLocation    = source.location
        workingSiteName    = source.siteName
        workingWaterType   = source.siteWaterType ?? ""
        workingBodyOfWater = source.siteBodyOfWater ?? ""
        workingDifficulty  = source.siteDifficulty ?? ""
        if copyGPSCoordinates {
            prefilledLatitude      = .coordinate(source.siteLatitude)
            prefilledLongitude     = .coordinate(source.siteLongitude)
            prefilledAltitude      = .decimals(source.siteAltitude, 0)
            prefilledExitLatitude  = .coordinate(source.exitLatitude)
            prefilledExitLongitude = .coordinate(source.exitLongitude)
            workingLatitude      = prefilledLatitude.text
            workingLongitude     = prefilledLongitude.text
            workingAltitude      = prefilledAltitude.text
            workingExitLatitude  = prefilledExitLatitude.text
            workingExitLongitude = prefilledExitLongitude.text
        }
    }

    init(dive: Dive) {
        self.dive = dive
        _workingCountry     = State(initialValue: dive.siteCountry ?? "")
        _workingLocation    = State(initialValue: dive.location)
        _workingSiteName    = State(initialValue: dive.siteName)
        _workingWaterType   = State(initialValue: dive.siteWaterType ?? "")
        _workingBodyOfWater = State(initialValue: dive.siteBodyOfWater ?? "")
        let latitude      = PrefilledDouble.coordinate(dive.siteLatitude)
        let longitude     = PrefilledDouble.coordinate(dive.siteLongitude)
        let altitude      = PrefilledDouble.decimals(dive.siteAltitude, 0)
        let exitLatitude  = PrefilledDouble.coordinate(dive.exitLatitude)
        let exitLongitude = PrefilledDouble.coordinate(dive.exitLongitude)
        _prefilledLatitude      = State(initialValue: latitude)
        _prefilledLongitude     = State(initialValue: longitude)
        _prefilledAltitude      = State(initialValue: altitude)
        _prefilledExitLatitude  = State(initialValue: exitLatitude)
        _prefilledExitLongitude = State(initialValue: exitLongitude)
        _workingLatitude     = State(initialValue: latitude.text)
        _workingLongitude    = State(initialValue: longitude.text)
        _workingAltitude     = State(initialValue: altitude.text)
        _workingDifficulty   = State(initialValue: dive.siteDifficulty ?? "")
        _workingExitLatitude  = State(initialValue: exitLatitude.text)
        _workingExitLongitude = State(initialValue: exitLongitude.text)
    }

    var body: some View {
        Group {
            iOSBody
        }
        .sheet(isPresented: $showEntryCoordinatePicker) {
            CoordinatePickerView(
                navigationTitle: "Set Entry Coordinates",
                existingCoordinate: entryCoordinate,
                pinIcon: "arrow.down",
                pinColor: .green,
                secondaryCoordinate: exitCoordinate,
                secondaryIcon: "arrow.up",
                secondaryLabel: "Exit",
                secondaryColor: .orange
            ) { coordinate in
                workingLatitude  = String(format: "%.6f", coordinate.latitude)
                workingLongitude = String(format: "%.6f", coordinate.longitude)
            }
            .standardSheetPresentation()
        }
        .sheet(isPresented: $showExitCoordinatePicker) {
            CoordinatePickerView(
                navigationTitle: "Set Exit Coordinates",
                existingCoordinate: exitCoordinate,
                pinIcon: "arrow.up",
                pinColor: .orange,
                secondaryCoordinate: entryCoordinate,
                secondaryIcon: "arrow.down",
                secondaryLabel: "Entry",
                secondaryColor: .green
            ) { coordinate in
                workingExitLatitude  = String(format: "%.6f", coordinate.latitude)
                workingExitLongitude = String(format: "%.6f", coordinate.longitude)
            }
            .standardSheetPresentation()
        }
        .alert("Replace Exit Coordinates", isPresented: $showSameAsEntryConfirm) {
            Button("Replace", role: .destructive) { copyEntryToExit() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will replace the existing exit coordinates with the entry coordinates.")
        }
    }


    @ViewBuilder
    private var copyFromSiteSection: some View {
        if !uniqueSites.isEmpty {
            Section {
                SiteSearchField(selectedSite: $selectedSite, recents: recentSites, allSites: uniqueSites)

                Toggle(isOn: $copyGPSCoordinates) {
                    HStack(spacing: 12) {
                        Image(systemName: "location.circle")
                            .foregroundStyle(.green)
                            .frame(width: 24)
                        Text("Include GPS Coordinates (Entry & Exit)")
                    }
                }
                .tint(.green)
                .fullWidthSwitch()

                Button {
                    if let source = selectedSite {
                        applySite(from: source)
                    }
                } label: {
                    HStack {
                        Image(systemName: "doc.on.doc")
                        Text("Copy Site Information")
                    }
                }
                .disabled(selectedSite == nil)
                .foregroundStyle(.orange)
                .listRowButton()
            } header: {
                MenuSectionHeader(title: "Copy from Existing Site", icon: "doc.on.doc", color: .orange)
            }
        }
    }

    private var iOSBody: some View {
        NavigationStack {
            ZStack {
                AppBackground().ignoresSafeArea()

                Form {
                    copyFromSiteSection

                    Section {
                        AutocompleteMenuTextField(label: "Site Name", text: $workingSiteName, icon: "location", color: .cyan, suggestions: uniqueValues(for: \.siteName))
                        AutocompleteMenuTextField(label: "Country", text: $workingCountry, icon: "flag", color: .blue, suggestions: uniqueOptionalValues(for: \.siteCountry))
                        AutocompleteMenuTextField(label: "Location", text: $workingLocation, icon: "mappin.and.ellipse", color: .orange, suggestions: uniqueValues(for: \.location))
                        Picker(selection: $workingDifficulty) {
                            Text("—").tag("")
                            ForEach(Self.difficultyScale, id: \.level) { item in
                                Text("\(item.level) — \(Text(LocalizedStringKey(item.label)))").tag(String(item.level))
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "star")
                                    .foregroundStyle(.purple)
                                    .frame(width: 24)
                                Text("Difficulty")
                                    .foregroundStyle(.primary)
                            }
                        }
                        .tint(.purple)
                    } header: {
                        MenuSectionHeader(title: "Location", icon: "mappin.and.ellipse", color: .blue)
                    }

                    Section {
                        Picker(selection: $workingWaterType) {
                            Text("—").tag("")
                            Text("Freshwater").tag("Freshwater")
                            Text("Saltwater").tag("Saltwater")
                            Text("Brackish water (EN13319)").tag("EN13319")
                            if !["", "Freshwater", "Saltwater", "EN13319"].contains(workingWaterType) {
                                Text(workingWaterType).tag(workingWaterType)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "drop")
                                    .foregroundStyle(.blue)
                                    .frame(width: 24)
                                Text("Water Type")
                                    .foregroundStyle(.primary)
                            }
                        }
                        .tint(.blue)
                        AutocompleteMenuTextField(label: "Body of Water", text: $workingBodyOfWater, icon: "water.waves", color: .teal, suggestions: uniqueOptionalValues(for: \.siteBodyOfWater))
                    } header: {
                        MenuSectionHeader(title: "Water", icon: "drop", color: .teal)
                    }

                    Section {
                        gpsActionRow("Pick on Map", icon: "mappin.and.ellipse") { showEntryCoordinatePicker = true }
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.up.arrow.down")
                                .foregroundStyle(.green)
                                .frame(width: 24)
                            Text("Latitude")
                                .foregroundStyle(.primary)
                            formTextField("Latitude", text: $workingLatitude)
                                .platformKeyboardType(.decimalPad)
                                .foregroundStyle(.primary)
                            gpsSignToggleButton(for: $workingLatitude, prefilled: $prefilledLatitude)
                            if !workingLatitude.isEmpty {
                                Button {
                                    workingLatitude = ""
                                } label: {
                                    ClearButtonGlyph()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.left.arrow.right")
                                .foregroundStyle(.green)
                                .frame(width: 24)
                            Text("Longitude")
                                .foregroundStyle(.primary)
                            formTextField("Longitude", text: $workingLongitude)
                                .platformKeyboardType(.decimalPad)
                                .foregroundStyle(.primary)
                            gpsSignToggleButton(for: $workingLongitude, prefilled: $prefilledLongitude)
                            if !workingLongitude.isEmpty {
                                Button {
                                    workingLongitude = ""
                                } label: {
                                    ClearButtonGlyph()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "mountain.2")
                                .foregroundStyle(.brown)
                                .frame(width: 24)
                            Text("Altitude (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit))")
                                .foregroundStyle(.primary)
                            formTextField("Altitude (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit))", text: $workingAltitude)
                                .platformKeyboardType(.decimalPad)
                                .foregroundStyle(.primary)
                            if !workingAltitude.isEmpty {
                                Button {
                                    workingAltitude = ""
                                } label: {
                                    ClearButtonGlyph()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        HStack {
                            MenuSectionHeader(title: "GPS Coordinates (Entry)", icon: "location.circle", color: .green)
                            if dive.rawDiveComputerData != nil {
                                Spacer()
                                Button { resetEntryGPS() } label: {
                                    Text("Reset")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundStyle(canResetEntryGPS ? .blue : .secondary)
                                }
                                .disabled(!canResetEntryGPS)
                                .borderlessButton()
                            }
                        }
                    } footer: {
                        Text("Unit (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit)) matches the original import format and cannot be changed.")
                            .font(.caption2)
                    }

                    Section {
                        gpsActionRow("Pick on Map", icon: "mappin.and.ellipse") { showExitCoordinatePicker = true }
                        gpsActionRow("Same as Entry", icon: "arrow.turn.right.up", enabled: entryCoordinate != nil) {
                            if exitCoordinate != nil {
                                showSameAsEntryConfirm = true
                            } else {
                                copyEntryToExit()
                            }
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.up.arrow.down")
                                .foregroundStyle(.green)
                                .frame(width: 24)
                            Text("Latitude")
                                .foregroundStyle(.primary)
                            formTextField("Latitude", text: $workingExitLatitude)
                                .platformKeyboardType(.decimalPad)
                                .foregroundStyle(.primary)
                            gpsSignToggleButton(for: $workingExitLatitude, prefilled: $prefilledExitLatitude)
                            if !workingExitLatitude.isEmpty {
                                Button {
                                    workingExitLatitude = ""
                                } label: {
                                    ClearButtonGlyph()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.left.arrow.right")
                                .foregroundStyle(.green)
                                .frame(width: 24)
                            Text("Longitude")
                                .foregroundStyle(.primary)
                            formTextField("Longitude", text: $workingExitLongitude)
                                .platformKeyboardType(.decimalPad)
                                .foregroundStyle(.primary)
                            gpsSignToggleButton(for: $workingExitLongitude, prefilled: $prefilledExitLongitude)
                            if !workingExitLongitude.isEmpty {
                                Button {
                                    workingExitLongitude = ""
                                } label: {
                                    ClearButtonGlyph()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        HStack {
                            MenuSectionHeader(title: "GPS Coordinates (Exit)", icon: "location.circle", color: .green)
                            if dive.rawDiveComputerData != nil {
                                Spacer()
                                Button { resetExitGPS() } label: {
                                    Text("Reset")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundStyle(canResetExitGPS ? .blue : .secondary)
                                }
                                .disabled(!canResetExitGPS)
                                .borderlessButton()
                            }
                        }
                    }
                }
                .groupedFormStyleOnMac()
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Edit Site Details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .bold()
                        .confirmationActionForeground(.blue)
                }
            }
        }
    }

    /// A "+/−" button that toggles the sign of a GPS coordinate string, keeping the decimal pad usable.
    /// It also negates the exact value behind the text, so flipping an untouched coordinate keeps
    /// its full precision instead of saving the 6-decimal text.
    @ViewBuilder
    private func gpsSignToggleButton(for value: Binding<String>, prefilled: Binding<PrefilledDouble>) -> some View {
        #if os(iOS)
        Button {
            let trimmed = value.wrappedValue.trimmingCharacters(in: .whitespaces)
            let exact = prefilled.wrappedValue.resolve(trimmed)
            let newText: String
            if trimmed.hasPrefix("-") {
                newText = String(trimmed.dropFirst())
            } else if !trimmed.isEmpty {
                newText = "-" + trimmed
            } else {
                newText = "-"
            }
            prefilled.wrappedValue = PrefilledDouble(value: exact.map { -$0 }, text: newText)
            value.wrappedValue = newText
        } label: {
            Text("+/−")
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(.green)
        }
        .buttonStyle(.plain)
        #endif
    }

    /// A full-width tappable row for GPS actions (Pick on Map, Same as Entry) inside a Form
    /// section — a larger, more discoverable target than a small header text link.
    private func gpsActionRow(_ title: LocalizedStringKey, icon: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(enabled ? .blue : .secondary)
                    .frame(width: 24)
                Text(title)
                    .foregroundStyle(enabled ? .blue : .secondary)
                Spacer()
                if enabled {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // The whole row responds, including the space before the chevron (a plain Button
            // only responds where something is drawn).
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func resetEntryGPS() {
        guard let rawData = dive.rawDiveComputerData,
              let gps = ShearwaterPNFGPS.extractEntryGPS(from: rawData) else { return }
        // Restore the dive computer's exact values, not just their "%.6f" text.
        prefilledLatitude  = .coordinate(gps.latitude)
        prefilledLongitude = .coordinate(gps.longitude)
        workingLatitude  = prefilledLatitude.text
        workingLongitude = prefilledLongitude.text
    }

    private func resetExitGPS() {
        guard let rawData = dive.rawDiveComputerData,
              let gps = ShearwaterPNFGPS.extractExitGPS(from: rawData) else { return }
        prefilledExitLatitude  = .coordinate(gps.latitude)
        prefilledExitLongitude = .coordinate(gps.longitude)
        workingExitLatitude  = prefilledExitLatitude.text
        workingExitLongitude = prefilledExitLongitude.text
    }

    private func save() {
        let trimmedCountry     = workingCountry.trimmingCharacters(in: .whitespaces)
        dive.siteCountry    = trimmedCountry.isEmpty ? nil : trimmedCountry
        dive.location       = workingLocation.trimmingCharacters(in: .whitespaces)
        dive.siteName       = workingSiteName.trimmingCharacters(in: .whitespaces)
        let trimmedWaterType   = workingWaterType.trimmingCharacters(in: .whitespaces)
        dive.siteWaterType  = trimmedWaterType.isEmpty ? nil : trimmedWaterType
        let trimmedBodyOfWater = workingBodyOfWater.trimmingCharacters(in: .whitespaces)
        dive.siteBodyOfWater = trimmedBodyOfWater.isEmpty ? nil : trimmedBodyOfWater
        // Untouched fields keep the stored (or copied) value at full precision.
        dive.siteLatitude   = prefilledLatitude.resolve(workingLatitude)
        dive.siteLongitude  = prefilledLongitude.resolve(workingLongitude)
        dive.siteAltitude   = prefilledAltitude.resolve(workingAltitude)
        let trimmedDifficulty  = workingDifficulty.trimmingCharacters(in: .whitespaces)
        dive.siteDifficulty = trimmedDifficulty.isEmpty ? nil : trimmedDifficulty
        dive.exitLatitude   = prefilledExitLatitude.resolve(workingExitLatitude)
        dive.exitLongitude  = prefilledExitLongitude.resolve(workingExitLongitude)
        // Site fields do not affect sort order, list grouping, or widget fingerprint.
        // cachedAvailableCountries refreshes lazily when the filter sheet opens.
        store.commit(dive, affects: .rowFields)
        dismiss()
    }
}

/// Popup de modification pour l'onglet Conditions
struct EditConditionsView: View {
    @Bindable var dive: Dive
    @Environment(\.dismiss) private var dismiss
    @Environment(DiveStore.self) private var store

    @State private var workingWaterTemp: Double?
    @State private var workingMinTemp: String
    @State private var workingAirTemp: String
    @State private var workingMaxTemp: String
    /// Stored temperatures behind the 1-decimal pre-fill text (see PrefilledDouble); @State so
    /// they stay paired with the text across parent re-renders.
    @State private var prefilledMinTemp: PrefilledDouble
    @State private var prefilledAirTemp: PrefilledDouble
    @State private var prefilledMaxTemp: PrefilledDouble
    @State private var workingWeather: String
    @State private var workingSurface: String
    @State private var workingCurrent: String
    @State private var workingWind: String
    @State private var workingWindDirection: String
    @State private var workingVisibility: String
    @State private var prefs = UserPreferences.shared
    @State private var isFetchingWeather = false
    /// Outcome of the last Fetch Weather, shown under the button. Kept as a case, not as
    /// text, so it is localized when drawn and follows an in-app language change.
    @State private var weatherFetchResult: WeatherFetchResult?
    /// Set when a fetch fails; presents the error alert.
    @State private var weatherFetchFailure: WeatherFetchFailure?
    /// When on, Fetch Weather replaces values already in the fields; when off, it fills only
    /// empty ones. Per sheet, on by default (like Site Details' "Include GPS Coordinates").
    @State private var replaceExistingWeather = true
    /// The running fetch, cancelled when the sheet closes.
    @State private var weatherFetchTask: Task<Void, Never>?


    private var visibilitySuggestions: [String] {
        var seen = Set<String>()
        return store.dives.compactMap { d -> String? in
            guard let val = d.visibility?.trimmingCharacters(in: .whitespaces),
                  !val.isEmpty else { return nil }
            let key = val.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return val
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    init(dive: Dive) {
        self.dive = dive
        _workingWaterTemp  = State(initialValue: dive.waterTemperature)
        let minTemp = PrefilledDouble.decimals(dive.minTemperature, 1)
        let airTemp = PrefilledDouble.decimals(dive.airTemperature, 1)
        let maxTemp = PrefilledDouble.decimals(dive.maxTemperature, 1)
        _prefilledMinTemp  = State(initialValue: minTemp)
        _prefilledAirTemp  = State(initialValue: airTemp)
        _prefilledMaxTemp  = State(initialValue: maxTemp)
        _workingMinTemp    = State(initialValue: minTemp.text)
        _workingAirTemp    = State(initialValue: airTemp.text)
        _workingMaxTemp    = State(initialValue: maxTemp.text)
        _workingWeather    = State(initialValue: dive.weather ?? "")
        _workingSurface    = State(initialValue: dive.surfaceConditions ?? "")
        _workingCurrent    = State(initialValue: dive.current ?? "")
        _workingWind       = State(initialValue: dive.wind ?? "")
        _workingWindDirection = State(initialValue: dive.windDirection ?? "")
        _workingVisibility = State(initialValue: dive.visibility ?? "")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground().ignoresSafeArea()

                Form {
                    if prefs.fetchWeatherOnline {
                        // Read the dive's coordinates once for the button and the footer.
                        let hasCoordinate = OpenMeteoWeatherService.coordinate(for: dive) != nil
                        let canFetchWeather = hasCoordinate && !isFetchingWeather
                        Section {
                            Button {
                                fetchWeather()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "cloud.sun.rain")
                                        .frame(width: 24)
                                    Text("Fetch Weather")
                                    Spacer()
                                    if isFetchingWeather {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                }
                                // On the label, not the Button: macOS's list-row button style
                                // redraws the label and would otherwise show it in the default
                                // text colour. An explicit colour also overrides iOS's disabled
                                // dimming, so the disabled state is shown here.
                                .foregroundStyle(canFetchWeather ? Color.orange : Color.secondary)
                            }
                            .listRowButton()
                            .disabled(!canFetchWeather)

                            Toggle(isOn: $replaceExistingWeather) {
                                HStack(spacing: 12) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .foregroundStyle(.orange)
                                        .frame(width: 24)
                                    Text("Replace Existing Values")
                                }
                            }
                            .tint(.orange)
                            .fullWidthSwitch()
                            // Read when the response arrives, so locked like the fields it governs.
                            .disabled(isFetchingWeather)
                            // The last result described the previous mode; let the footer
                            // explain what the next fetch will do instead.
                            .onChange(of: replaceExistingWeather) { weatherFetchResult = nil }
                        } header: {
                            ConditionsSectionHeader(title: "Fetch from Open-Meteo", icon: "cloud.sun", color: .orange)
                        } footer: {
                            VStack(alignment: .leading, spacing: 4) {
                                if !hasCoordinate {
                                    Text("Add the dive site's GPS coordinates in Site Details to fetch the weather.")
                                } else if let weatherFetchResult {
                                    weatherFetchResultText(weatherFetchResult)
                                } else if replaceExistingWeather {
                                    Text("Fills the fields with the weather at the dive site at the time the dive started, replacing existing values, including the air temperature.")
                                } else {
                                    Text("Fills only empty fields with the weather at the dive site at the time the dive started.")
                                }
                                Text("Weather data by [Open-Meteo.com](https://open-meteo.com/) ([CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)), converted to BlueDive's weather, wind and wind direction options.")
                            }
                            .font(.caption2)
                        }
                    }

                    Section {
                        ConditionsTemperatureField(label: "Air Temp.", text: $workingAirTemp, icon: "thermometer.medium", unit: dive.storedTemperatureUnit.symbol)
                            // The fields a fetch fills are locked while it runs, so its result
                            // cannot overwrite a choice made in the meantime.
                            .disabled(isFetchingWeather)
                        ConditionsTemperatureField(label: "Min Temp.", text: $workingMinTemp, icon: "thermometer.low", unit: dive.storedTemperatureUnit.symbol)
                        ConditionsTemperatureField(label: "Max Temp.", text: $workingMaxTemp, icon: "thermometer.high", unit: dive.storedTemperatureUnit.symbol)
                    } header: {
                        ConditionsSectionHeader(title: "Temperatures (\(dive.storedTemperatureUnit.symbol))", icon: "thermometer.medium", color: .orange)
                    } footer: {
                        Text("Unit (\(dive.storedTemperatureUnit.symbol)) matches the original import format and cannot be changed.")
                            .font(.caption2)
                    }

                    Section {
                        ConditionsPickerRow(label: "Weather", selection: $workingWeather, options: DiveConditionOptions.weather, icon: "cloud.sun", optionLabel: { DiveConditionOptions.localizedWeather($0) })
                            .disabled(isFetchingWeather)
                        ConditionsPickerRow(label: "Wind", selection: $workingWind, options: DiveConditionOptions.wind, icon: "wind", optionLabel: { DiveConditionOptions.localizedWind($0) })
                            .disabled(isFetchingWeather)
                        ConditionsPickerRow(label: "Wind Direction", selection: $workingWindDirection, options: DiveConditionOptions.windDirection, icon: "location.north", optionLabel: { DiveConditionOptions.localizedWindDirection($0) })
                            .disabled(isFetchingWeather)
                        ConditionsPickerRow(label: "Surface", selection: $workingSurface, options: DiveConditionOptions.surface, icon: "water.waves", optionLabel: { DiveConditionOptions.localizedSurface($0) })
                        ConditionsPickerRow(label: "Current", selection: $workingCurrent, options: DiveConditionOptions.current, icon: "arrow.right.arrow.left", optionLabel: { DiveConditionOptions.localizedCurrent($0) })
                    } header: {
                        ConditionsSectionHeader(title: "Weather & Sea", icon: "cloud.sun", color: .blue)
                    }

                    Section {
                        AutocompleteMenuTextField(label: "Visibility", text: $workingVisibility, icon: "eye", color: .green, suggestions: visibilitySuggestions)
                    } header: {
                        ConditionsSectionHeader(title: "Visibility", icon: "eye", color: .green)
                    }
                }
                .groupedFormStyleOnMac()
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Edit Conditions")
            .onDisappear { weatherFetchTask?.cancel() }
            // `presenting:` keeps the failure for the alert's content while it animates out,
            // after the binding has cleared `weatherFetchFailure`.
            .alert("Weather could not be fetched", isPresented: Binding(
                get: { weatherFetchFailure != nil },
                set: { if !$0 { weatherFetchFailure = nil } }
            ), presenting: weatherFetchFailure) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                switch failure {
                case .serviceUnavailable:
                    Text("Open-Meteo could not provide the weather right now. Try again later.")
                case .unreachable:
                    Text("Open-Meteo could not be reached. Check your internet connection or try again later.")
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .bold()
                        // Saving mid-fetch would close the sheet and drop the fetched values.
                        .disabled(isFetchingWeather)
                }
            }
        }
    }

    // iOS Helpers - Renamed to avoid conflicts
    private struct ConditionsSectionHeader: View {
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

    private struct ConditionsTemperatureField: View {
        let label: LocalizedStringKey
        @Binding var text: String
        let icon: String
        let unit: String

        init(label: LocalizedStringKey, text: Binding<String>, icon: String, unit: String) {
            self.label = label
            self._text = text
            self.icon = icon
            self.unit = unit
        }


        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(.orange)
                    .frame(width: 24)
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
                TextField("", text: $text)
                    .platformKeyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .foregroundStyle(.cyan)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private struct ConditionsPickerRow: View {
        let label: LocalizedStringKey
        @Binding var selection: String
        let options: [String]
        let icon: String
        /// Localized label for a stored option value (a `DiveConditionOptions` localizer). The
        /// bare value cannot be the key: some English words are also other keys (e.g. "Light").
        let optionLabel: @MainActor (String) -> String

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(.blue)
                    .frame(width: 24)
                Picker(label, selection: $selection) {
                    Text("—").tag("")
                    ForEach(options, id: \.self) { opt in
                        Text(verbatim: optionLabel(opt)).tag(opt)
                    }
                }
            }
        }
    }

    private enum WeatherFetchResult {
        case filled, allFieldsSet, noValueForEmptyFields, noData
    }

    private enum WeatherFetchFailure {
        case unreachable, serviceUnavailable
    }

    /// Literal keys, resolved through the sheet's locale when drawn.
    private func weatherFetchResultText(_ result: WeatherFetchResult) -> Text {
        switch result {
        case .filled:                return Text("The weather fields were filled. Review them before saving.")
        case .allFieldsSet:          return Text("Every weather field already has a value. Nothing was changed.")
        case .noValueForEmptyFields: return Text("Nothing was changed. Open-Meteo had no value for the empty fields.")
        case .noData:                return Text("No weather data is available for this dive's date and place.")
        }
    }

    private func fetchWeather() {
        isFetchingWeather = true
        weatherFetchResult = nil
        weatherFetchTask = Task {
            defer { isFetchingWeather = false }
            do {
                let fetched = try await OpenMeteoWeatherService.fetch(for: dive)
                guard !Task.isCancelled else { return }
                applyFetchedWeather(fetched)
            } catch is CancellationError {
                // The sheet was closed mid-fetch; nothing to report.
            } catch OpenMeteoWeatherError.noData {
                weatherFetchResult = .noData
            } catch OpenMeteoWeatherError.serviceUnavailable {
                weatherFetchFailure = .serviceUnavailable
            } catch {
                weatherFetchFailure = .unreachable
            }
        }
    }

    /// Fills the working fields from a fetch. With Replace Existing Values on, every field
    /// Open-Meteo returned a value for is replaced; with it off, only empty fields are filled.
    /// A field Open-Meteo returned nothing for (e.g. the direction of a calm wind) is never
    /// touched. Nothing is stored until Save.
    private func applyFetchedWeather(_ fetched: FetchedWeather) {
        let replace = replaceExistingWeather
        var filled = false
        // `filled` counts only fields whose value actually changes, so a repeat fetch with
        // Replace on reports "Nothing was changed" rather than "filled".
        if replace || workingWeather.isEmpty, let weather = fetched.weather, weather != workingWeather {
            workingWeather = weather
            filled = true
        }
        if replace || workingAirTemp.trimmingCharacters(in: .whitespaces).isEmpty, let temperature = fetched.airTemperature,
           prefilledAirTemp.resolve(workingAirTemp) != temperature {
            // Replace the whole PrefilledDouble so an untouched field saves the fetched value
            // at full precision, not its 1-decimal text.
            prefilledAirTemp = .decimals(temperature, 1)
            workingAirTemp = prefilledAirTemp.text
            filled = true
        }
        if replace || workingWind.isEmpty, let wind = fetched.wind, wind != workingWind {
            workingWind = wind
            filled = true
        }
        if replace || workingWindDirection.isEmpty, let direction = fetched.windDirection, direction != workingWindDirection {
            workingWindDirection = direction
            filled = true
        }
        if filled {
            weatherFetchResult = .filled
        } else if workingWeather.isEmpty || workingAirTemp.trimmingCharacters(in: .whitespaces).isEmpty
                    || workingWind.isEmpty || workingWindDirection.isEmpty {
            // Some field is still empty: Open-Meteo had nothing for it (e.g. no direction for
            // a calm wind), so "every field already has a value" would be wrong.
            weatherFetchResult = .noValueForEmptyFields
        } else {
            weatherFetchResult = .allFieldsSet
        }
    }


    private func save() {
        dive.waterTemperature  = workingWaterTemp
        // Untouched fields keep the stored temperature at full precision.
        dive.minTemperature    = prefilledMinTemp.resolve(workingMinTemp)
        dive.airTemperature    = prefilledAirTemp.resolve(workingAirTemp)
        dive.maxTemperature    = prefilledMaxTemp.resolve(workingMaxTemp)
        let trimmedWeather     = workingWeather.trimmingCharacters(in: .whitespaces)
        dive.weather           = trimmedWeather.isEmpty    ? nil : trimmedWeather
        let trimmedSurface     = workingSurface.trimmingCharacters(in: .whitespaces)
        dive.surfaceConditions = trimmedSurface.isEmpty    ? nil : trimmedSurface
        let trimmedCurrent     = workingCurrent.trimmingCharacters(in: .whitespaces)
        dive.current           = trimmedCurrent.isEmpty    ? nil : trimmedCurrent
        dive.wind              = workingWind.isEmpty       ? nil : workingWind
        dive.windDirection     = workingWindDirection.isEmpty ? nil : workingWindDirection
        let trimmedVisibility  = workingVisibility.trimmingCharacters(in: .whitespaces)
        dive.visibility        = trimmedVisibility.isEmpty ? nil : trimmedVisibility
        // Conditions fields do not affect sort order, list grouping, or widget fingerprint.
        // @Observable handles row display updates automatically.
        store.commit(dive, affects: .rowFields)
        dismiss()
    }
}

/// Popup de modification pour l'onglet Gaz
struct EditGazView: View {
    @Bindable var dive: Dive
    let tankIndex: Int
    var onSlotChanged: ((Int) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(DiveStore.self) private var store
    @Query(sort: \TankTemplate.name) private var templates: [TankTemplate]
    @State private var selectedTemplateName: String = ""

    /// Original gas percentages as loaded — used in save() to avoid silently mutating
    /// imported fractions that the user never touched.
    private let originalO2: Int
    private let originalHe: Int

    @State private var workingO2: Int
    @State private var workingHe: Int
    @State private var workingCylinderSize: Double?
    @State private var cylinderSizeText: String
    @State private var workingCylinderMaterial: String
    @State private var workingCylinderType: String
    @State private var workingStartPressureText: String
    @State private var workingEndPressureText: String
    /// Stored pressures behind the 1-decimal pre-fill text, so an untouched field saves the
    /// stored value unchanged (e.g. 206.84 bar stays 206.84, not 206.8); see PrefilledDouble.
    @State private var prefilledStartPressure: PrefilledDouble
    @State private var prefilledEndPressure: PrefilledDouble
    /// Text the code itself just wrote from an exact value (template apply, usage-time unit
    /// switch). Its onChange must not re-parse it, which would round the value to its text; any
    /// other change — every user keystroke — is parsed. See skipsProgrammaticText.
    @State private var programmaticCylinderSizeText: String?
    @State private var programmaticWorkingPressureText: String?
    @State private var programmaticUsageStartText: String?
    @State private var programmaticUsageEndText: String?
    /// Working pressure of the tank, in the import unit (`storedPressureUnit`).
    /// Used for conversion from gas-capacity → water volume (cu ft → L) in RMV/SAC calculation.
    /// `nil` = not provided (calculation falls back to 3000 PSI default).
    @State private var workingWorkingPressure: Double?
    @State private var workingPressureText: String
    @State private var workingUsageStartTime: Double?  // always in seconds
    @State private var usageStartTimeText: String
    @State private var workingUsageEndTime: Double?    // always in seconds
    @State private var usageEndTimeText: String

    enum UsageTimeUnit: String, CaseIterable {
        case minutes = "Minutes"
        case seconds = "Seconds"

        var symbol: String {
            switch self {
            case .minutes: return "min"
            case .seconds: return "sec"
            }
        }

        func toSeconds(_ value: Double) -> Double {
            switch self {
            case .minutes: return value * 60.0
            case .seconds: return value
            }
        }

        func fromSeconds(_ value: Double) -> Double {
            switch self {
            case .minutes: return value / 60.0
            case .seconds: return value
            }
        }
    }

    @State private var usageTimeUnit: UsageTimeUnit = .seconds
    @State private var workingSlot: Int = 1
    @State private var rewriteSamples: Bool = true

    /// Validation: si le volume saisi semble hors limites selon l'unité stockée.
    private var cylinderSizeIsValid: Bool {
        guard let size = workingCylinderSize else { return true } // empty is valid
        switch dive.storedVolumeUnit {
        case .liters:
            // Standard tanks: 0.5 L (pony) to 30 L (double manifold)
            return size >= 0.5 && size <= 30
        case .cubicFeet:
            // Gas capacity US : 6 cu ft (pony) à 400 cu ft (configuration double)
            return size >= 6 && size <= 400
        }
    }

    /// Validation: working pressure consistent with stored pressure unit.
    private var workingPressureIsValid: Bool {
        guard let wp = workingWorkingPressure else { return true } // optionnel
        switch dive.storedPressureUnit {
        case .bar:  return wp >= 150 && wp <= 350
        case .psi:  return wp >= 2000 && wp <= 5000
        case .pa:   return wp >= 15_000_000 && wp <= 35_000_000
        }
    }

    /// A usage time (stored in seconds) as text in the selected unit.
    private func usageTimeText(_ seconds: Double?) -> String {
        seconds.map { Self.formatDouble(usageTimeUnit.fromSeconds($0)) } ?? ""
    }

    /// Writes text computed from an exact value, marking it so the field's onChange does not
    /// re-parse it (see skipsProgrammaticText). Unchanged text fires no onChange: no marker then.
    private func setProgrammaticText(_ text: String, into field: inout String, marker: inout String?) {
        guard field != text else { return }
        marker = text
        field = text
    }

    /// True when `text` is the programmatic text just written (the marker is then consumed).
    /// Any other change clears the marker and must be parsed, so what the field shows is always
    /// what is saved.
    private static func skipsProgrammaticText(_ text: String, marker: inout String?) -> Bool {
        // Callers check `marker != nil` first: an inout @State argument is written back even
        // when unchanged, which would cost a state write (and re-render) per keystroke.
        guard let programmatic = marker else { return false }
        marker = nil
        return text == programmatic
    }

    /// Formats a Double? into an editable string for TextField pre-fill (no grouping separators).
    private static func formatDouble(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.editableString(decimals: 4)
    }

    private let materialOptions = ["Steel", "Galvanized Steel", "Aluminium", "Carbon"]
    private let typeOptions     = ["Single tank", "Twinset", "Sidemount", "Pony", "Rebreather", "Other"]

    init(dive: Dive, tankIndex: Int = 0, onSlotChanged: ((Int) -> Void)? = nil) {
        self.dive = dive
        self.tankIndex = tankIndex
        self.onSlotChanged = onSlotChanged
        let tanks = dive.tanks
        let tank = tankIndex < tanks.count ? tanks[tankIndex] : nil
        let rawO2 = max(1, tank?.o2Percentage ?? 21)
        let rawHe = min(tank?.hePercentage ?? 0, 100 - rawO2)
        originalO2 = rawO2
        originalHe = rawHe
        _workingO2               = State(initialValue: rawO2)
        _workingHe               = State(initialValue: rawHe)
        _workingCylinderSize     = State(initialValue: tank?.volume)
        _cylinderSizeText        = State(initialValue: Self.formatDouble(tank?.volume))
        _workingCylinderMaterial = State(initialValue: tank?.tankMaterial ?? "")
        _workingCylinderType     = State(initialValue: tank?.tankType ?? "")
        // Shown with up to 1 decimal (whole values stay whole), so a decimal pressure the user
        // entered is shown again; editableString never traps, unlike Int(_:) on a huge value.
        let startPressure = PrefilledDouble.decimals(tank?.startPressure, 1)
        let endPressure   = PrefilledDouble.decimals(tank?.endPressure, 1)
        _prefilledStartPressure   = State(initialValue: startPressure)
        _prefilledEndPressure     = State(initialValue: endPressure)
        _workingStartPressureText = State(initialValue: startPressure.text)
        _workingEndPressureText   = State(initialValue: endPressure.text)
        _workingWorkingPressure  = State(initialValue: tank?.workingPressure)
        _workingPressureText     = State(initialValue: Self.formatDouble(tank?.workingPressure))
        _workingUsageStartTime   = State(initialValue: tank?.usageStartTime)
        _usageStartTimeText      = State(initialValue: Self.formatDouble(tank?.usageStartTime))
        _workingUsageEndTime     = State(initialValue: tank?.usageEndTime)
        _usageEndTimeText        = State(initialValue: Self.formatDouble(tank?.usageEndTime))
        _workingSlot             = State(initialValue: tankIndex < tanks.count ? tankIndex + 1 : tanks.count + 1)
    }

    /// Copy physical tank properties from a template into the working state variables.
    /// Volume conversion between litres (water capacity) and cubic feet (gas capacity)
    /// uses the working pressure: cuft = (L × wp_bar) / 28.3168, L = (cuft × 28.3168) / wp_bar.
    /// Pressure is converted between units (bar ↔ psi is a direct conversion).
    /// Does NOT modify gas mix (O2/He) or start/end pressure (those are dive-specific).
    private func applyTemplate(from template: TankTemplate) {
        // Convert working pressure first (always valid: bar ↔ psi is linear)
        if let wp = template.workingPressure {
            let converted = dive.storedPressureUnit.convert(wp, from: template.storedPressureUnit)
            workingWorkingPressure = converted
            setProgrammaticText(Self.formatDouble(converted), into: &workingPressureText,
                                marker: &programmaticWorkingPressureText)
        }

        if let vol = template.volume, let wp = template.workingPressure {
            if template.storedVolumeUnit == dive.storedVolumeUnit {
                // Same unit system — copy directly
                workingCylinderSize = vol
                setProgrammaticText(Self.formatDouble(vol), into: &cylinderSizeText,
                                    marker: &programmaticCylinderSizeText)
            } else {
                // Cross-unit conversion using working pressure.
                // First get working pressure in bar for the formula.
                let wpBar = PressureUnit.bar.convert(wp, from: template.storedPressureUnit)

                if template.storedVolumeUnit == .liters && dive.storedVolumeUnit == .cubicFeet {
                    // L → cu ft:  cuft = (L × wp_bar) / 28.3168
                    let converted = (vol * wpBar) / 28.3168
                    workingCylinderSize = converted
                    setProgrammaticText(Self.formatDouble(converted), into: &cylinderSizeText,
                                        marker: &programmaticCylinderSizeText)
                } else if template.storedVolumeUnit == .cubicFeet && dive.storedVolumeUnit == .liters {
                    // cu ft → L:  L = (cuft × 28.3168) / wp_bar
                    let converted = (vol * 28.3168) / wpBar
                    workingCylinderSize = converted
                    setProgrammaticText(Self.formatDouble(converted), into: &cylinderSizeText,
                                        marker: &programmaticCylinderSizeText)
                }
            }
        }

        workingCylinderMaterial = template.material ?? ""
        workingCylinderType = template.format ?? ""
    }

    /// Détermine automatiquement le type de gaz selon O₂ et He
    private var autoGasLabel: String {
        if workingHe > 0 {
            if 100 - workingO2 - workingHe <= 0 {
                return NSLocalizedString("Heliox", bundle: .forAppLanguage(), comment: "Gas type label: oxygen and helium only, no nitrogen")
            }
            return NSLocalizedString("Trimix", bundle: .forAppLanguage(), comment: "Gas type label: helium present")
        } else if workingO2 == 21 {
            return NSLocalizedString("Air", bundle: .forAppLanguage(), comment: "Gas type label: 21% oxygen")
        } else if workingO2 > 21 {
            return NSLocalizedString("Nitrox", bundle: .forAppLanguage(), comment: "Gas type label: oxygen above 21%")
        } else {
            return NSLocalizedString("Hypoxic", bundle: .forAppLanguage(), comment: "Gas type label: oxygen below 21%")
        }
    }

    /// Minimum O₂ % — 1% supports hypoxic diluents used in CCR diving
    private let o2Min: Int = 1
    /// O₂ max sans dépasser 100 % en tenant compte de He
    private var o2Max: Int { 100 - workingHe }
    /// He max sans dépasser 100 % en tenant compte de O₂
    private var heMax: Int { 100 - workingO2 }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground().ignoresSafeArea()

                Form {
                    // Tank Slot — reorder tanks when multiple tanks exist
                    if dive.tanks.count > 1 && tankIndex < dive.tanks.count {
                        Section {
                            Picker("Tank Number", selection: $workingSlot) {
                                ForEach(1...dive.tanks.count, id: \.self) { slot in
                                    Text(verbatim: "\(slot)").tag(slot)
                                }
                            }
                            Toggle("Update Samples", isOn: $rewriteSamples)
                                .fullWidthSwitch()
                        } header: {
                            Label("Tank Slot", systemImage: "number.circle")
                                .foregroundStyle(.orange)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .textCase(nil)
                        } footer: {
                            Text("Update Samples remaps tank pressures and the active-gas assignment in the dive profile to match the new slot order.")
                                .font(.caption2)
                        }
                    }

                    // Copy from Tank Template
                    if !templates.isEmpty {
                        Section {
                            Picker("Template", selection: $selectedTemplateName) {
                                Text("Select a template...").tag("")
                                ForEach(templates) { template in
                                    Text(template.name).tag(template.name)
                                }
                            }
                            .tint(.orange)

                            Button {
                                if let source = templates.first(where: { $0.name == selectedTemplateName }) {
                                    applyTemplate(from: source)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "doc.on.doc")
                                    Text("Copy Tank Information")
                                }
                            }
                            .disabled(selectedTemplateName.isEmpty)
                            .foregroundStyle(.orange)
                            .listRowButton()
                        } header: {
                            Label("Copy from Tank Template", systemImage: "doc.on.doc")
                                .foregroundStyle(.orange)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .textCase(nil)
                        }
                    }

                    Section("Gas blend") {
                        // Auto-calculated type
                        HStack {
                            Label {
                                Text("Gas Type")
                                    .foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "bubbles.and.sparkles")
                                    .foregroundStyle(.purple)
                            }
                            Spacer()
                            Text(verbatim: autoGasLabel)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.green)
                        }

                        // Oxygen
                        HStack {
                            Label {
                                Text("Oxygen (O₂)")
                                    .foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "o.circle")
                                    .foregroundStyle(.green)
                            }
                            Spacer()
                            Text((Double(workingO2) / 100).formatted(.percent.precision(.fractionLength(0))))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.green)
                                .frame(width: 48, alignment: .trailing)
                            Stepper("", value: $workingO2, in: o2Min...o2Max)
                                .labelsHidden()
                        }

                        // Helium
                        HStack {
                            Label {
                                Text("Helium (He)")
                                    .foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: "h.circle")
                                    .foregroundStyle(.cyan)
                            }
                            Spacer()
                            Text((Double(workingHe) / 100).formatted(.percent.precision(.fractionLength(0))))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.cyan)
                                .frame(width: 48, alignment: .trailing)
                            Stepper("", value: $workingHe, in: 0...heMax)
                                .labelsHidden()
                        }
                    }
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "cylinder")
                                .foregroundStyle(.blue)
                                .frame(width: 24)
                            Text("Volume (\(dive.storedVolumeUnit.symbol))")
                                .foregroundStyle(.primary)
                            formTextField("Volume (\(dive.storedVolumeUnit.symbol))", text: $cylinderSizeText)
                                .platformKeyboardType(.decimalPad)
                                .foregroundStyle(cylinderSizeIsValid ? Color.primary : Color.orange)
                                .onChange(of: cylinderSizeText) {
                                    if programmaticCylinderSizeText != nil, Self.skipsProgrammaticText(cylinderSizeText, marker: &programmaticCylinderSizeText) { return }
                                    workingCylinderSize = parseFlexibleDouble(cylinderSizeText)
                                }
                            if workingCylinderSize != nil {
                                Button {
                                    workingCylinderSize = nil
                                    cylinderSizeText = ""
                                } label: {
                                    ClearButtonGlyph()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        // Working pressure — essential for gas-capacity (cu ft) → L conversion
                        // and therefore for accurate RMV/SAC calculation in PSI/cu ft system
                        HStack(spacing: 12) {
                            Image(systemName: "gauge.badge.plus")
                                .foregroundStyle(.blue)
                                .frame(width: 24)
                            Text("Service pressure (\(dive.storedPressureUnit.symbol))")
                                .foregroundStyle(.primary)
                                .fixedSize()
                            formTextField("Service pressure (\(dive.storedPressureUnit.symbol))", text: $workingPressureText)
                                .platformKeyboardType(.decimalPad)
                                .foregroundStyle(workingPressureIsValid ? Color.primary : Color.orange)
                                .onChange(of: workingPressureText) {
                                    if programmaticWorkingPressureText != nil, Self.skipsProgrammaticText(workingPressureText, marker: &programmaticWorkingPressureText) { return }
                                    workingWorkingPressure = parseFlexibleDouble(workingPressureText)
                                }
                            if workingWorkingPressure != nil {
                                Button {
                                    workingWorkingPressure = nil
                                    workingPressureText = ""
                                } label: {
                                    ClearButtonGlyph()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Picker("Material", selection: $workingCylinderMaterial) {
                            Text("—").tag("")
                            ForEach(materialOptions, id: \.self) { opt in Text(verbatim: localizedTankMaterial(opt)).tag(opt) }
                        }
                        Picker("Format", selection: $workingCylinderType) {
                            Text("—").tag("")
                            ForEach(typeOptions, id: \.self) { opt in Text(verbatim: localizedTankFormat(opt)).tag(opt) }
                        }
                    } header: {
                        Text("Tank")
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            if dive.storedVolumeUnit == .cubicFeet {
                                Text("The service pressure is used to convert the gas capacity (ft³) into actual water volume (L) for RMV and SAC calculations. Typical value: 3000 PSI.")
                                    .font(.caption2)
                            } else {
                                Text("Service pressure is optional in metric (L). It is only required for tanks imported in ft³.")
                                    .font(.caption2)
                            }
                            Text("Volume unit (\(dive.storedVolumeUnit.symbol)) and pressure unit (\(dive.storedPressureUnit.symbol)) match the original import format and cannot be changed.")
                                .font(.caption2)
                        }
                    }
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "gauge.with.needle")
                                .foregroundStyle(.red)
                                .frame(width: 24)
                            Text("Start pressure (\(dive.storedPressureUnit.symbol))")
                                .foregroundStyle(.primary)
                                .fixedSize()
                            // Decimal input: an edited pressure keeps its decimals ('.' or ',').
                            formTextField("Start pressure (\(dive.storedPressureUnit.symbol))", text: $workingStartPressureText)
                                .platformKeyboardType(.decimalPad)
                                .foregroundStyle(.primary)
                            if !workingStartPressureText.isEmpty {
                                Button {
                                    workingStartPressureText = ""
                                } label: {
                                    ClearButtonGlyph()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                                .foregroundStyle(.orange)
                                .frame(width: 24)
                            Text("End pressure (\(dive.storedPressureUnit.symbol))")
                                .foregroundStyle(.primary)
                                .fixedSize()
                            formTextField("End pressure (\(dive.storedPressureUnit.symbol))", text: $workingEndPressureText)
                                .platformKeyboardType(.decimalPad)
                                .foregroundStyle(.primary)
                            if !workingEndPressureText.isEmpty {
                                Button {
                                    workingEndPressureText = ""
                                } label: {
                                    ClearButtonGlyph()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        Text("Pressure")
                    } footer: {
                        Text("Pressure unit (\(dive.storedPressureUnit.symbol)) matches the original import format and cannot be changed.")
                            .font(.caption2)
                    }
                    Section {
                        Picker("Unit", selection: $usageTimeUnit) {
                            ForEach(UsageTimeUnit.allCases, id: \.self) { unit in
                                Text(LocalizedStringKey(unit.rawValue)).tag(unit)
                            }
                        }
                        .fullWidthSegmentedPicker()
                        .onChange(of: usageTimeUnit) {
                            // Rewritten from the exact seconds: marked so it is not re-parsed.
                            setProgrammaticText(usageTimeText(workingUsageStartTime), into: &usageStartTimeText,
                                                marker: &programmaticUsageStartText)
                            setProgrammaticText(usageTimeText(workingUsageEndTime), into: &usageEndTimeText,
                                                marker: &programmaticUsageEndText)
                        }

                        HStack(spacing: 12) {
                            Image(systemName: "play")
                                .foregroundStyle(.cyan)
                                .frame(width: 24)
                            Text(verbatim: NSLocalizedString("Usage Start", bundle: Bundle.forAppLanguage(), comment: "") + " (\(usageTimeUnit.symbol))")
                                .foregroundStyle(.primary)
                                .fixedSize()
                            formTextField("Usage Start", text: $usageStartTimeText)
                                .platformKeyboardType(.decimalPad)
                                .onChange(of: usageStartTimeText) {
                                    if programmaticUsageStartText != nil, Self.skipsProgrammaticText(usageStartTimeText, marker: &programmaticUsageStartText) { return }
                                    if let parsed = parseFlexibleDouble(usageStartTimeText) {
                                        workingUsageStartTime = usageTimeUnit.toSeconds(parsed)
                                    } else {
                                        workingUsageStartTime = nil
                                    }
                                }
                            if workingUsageStartTime != nil {
                                Button {
                                    workingUsageStartTime = nil
                                    usageStartTimeText = ""
                                } label: {
                                    ClearButtonGlyph()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "stop")
                                .foregroundStyle(.cyan)
                                .frame(width: 24)
                            Text(verbatim: NSLocalizedString("Usage End", bundle: Bundle.forAppLanguage(), comment: "") + " (\(usageTimeUnit.symbol))")
                                .foregroundStyle(.primary)
                                .fixedSize()
                            formTextField("Usage End", text: $usageEndTimeText)
                                .platformKeyboardType(.decimalPad)
                                .onChange(of: usageEndTimeText) {
                                    if programmaticUsageEndText != nil, Self.skipsProgrammaticText(usageEndTimeText, marker: &programmaticUsageEndText) { return }
                                    if let parsed = parseFlexibleDouble(usageEndTimeText) {
                                        workingUsageEndTime = usageTimeUnit.toSeconds(parsed)
                                    } else {
                                        workingUsageEndTime = nil
                                    }
                                }
                            if workingUsageEndTime != nil {
                                Button {
                                    workingUsageEndTime = nil
                                    usageEndTimeText = ""
                                } label: {
                                    ClearButtonGlyph()
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        Text("Usage Time")
                    } footer: {
                        Text("Optional. Specify when this tank was used during the dive for more accurate RMV/SAC calculation.")
                            .font(.caption2)
                    }
                }
                .groupedFormStyleOnMac()
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Edit Gas")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .bold()
                        .confirmationActionForeground(.green)
                }
            }
        }
    }


    // MARK: - Sample remapping helpers

    /// Returns the new index for an element that was at `old` after moving the
    /// element at `from` to `to` via remove-then-insert (no swap).
    private func remappedIndex(_ old: Int, from: Int, to: Int) -> Int {
        if old == from { return to }
        if from < to {
            // Moving forward: elements in (from, to] shift one position earlier.
            if old > from && old <= to { return old - 1 }
        } else {
            // Moving backward: elements in [to, from) shift one position later.
            if old >= to && old < from { return old + 1 }
        }
        return old
    }

    /// Rebuilds profile points so that `tankPressures` keys and `currentGas`
    /// values reflect the new tank order after moving the element at `from` to `to`.
    private func remapSamples(_ points: [DiveProfilePoint], from: Int, to: Int) -> [DiveProfilePoint] {
        points.map { point in
            let newCurrentGas = point.currentGas.map { remappedIndex($0, from: from, to: to) }
            let newTankPressures = point.tankPressures.map { dict in
                Dictionary(uniqueKeysWithValues: dict.map { (remappedIndex($0.key, from: from, to: to), $0.value) })
            }
            let newTankPressure = newTankPressures.flatMap { $0[0] ?? $0.min(by: { $0.key < $1.key })?.value } ?? point.tankPressure
            return DiveProfilePoint(
                id: point.id,
                time: point.time,
                depth: point.depth,
                temperature: point.temperature,
                tankPressure: newTankPressure,
                tankPressures: newTankPressures,
                ndl: point.ndl,
                ceilingDepth: point.ceilingDepth,
                ceilingTime: point.ceilingTime,
                cns: point.cns,
                ppo2: point.ppo2,
                sensorPPO2: point.sensorPPO2,
                events: point.events,
                currentGas: newCurrentGas
            )
        }
    }

    private func save() {
        let o2Fraction = Double(workingO2) / 100.0
        let heFraction = Double(workingHe) / 100.0
        // Untouched pressure fields keep the stored value at full precision; edited ones are
        // parsed as entered ('.' or ',' decimals), an emptied one is cleared.
        let startP = prefilledStartPressure.resolve(workingStartPressureText)
        let endP   = prefilledEndPressure.resolve(workingEndPressureText)
        let trimmedMaterial = workingCylinderMaterial.trimmingCharacters(in: .whitespaces)
        let material = trimmedMaterial.isEmpty ? nil : trimmedMaterial
        let trimmedType = workingCylinderType.trimmingCharacters(in: .whitespaces)
        let type = trimmedType.isEmpty ? nil : trimmedType

        var tanks = dive.tanks
        var targetIndex = tankIndex  // updated below if a slot move is requested

        if tankIndex < tanks.count {
            let existingTank = tanks[tankIndex]
            // Preserve the original stored fraction if the user did not change the percentage,
            // to avoid silently mutating imported fractions that round to the same integer.
            let savedO2 = workingO2 == originalO2 ? existingTank.o2 : o2Fraction
            let savedHe = min(workingHe == originalHe ? existingTank.he : heFraction, 1.0 - savedO2)
            tanks[tankIndex] = TankData(
                id: existingTank.id,
                o2: savedO2,
                he: savedHe,
                volume: workingCylinderSize,
                startPressure: startP,
                endPressure: endP,
                workingPressure: workingWorkingPressure,
                tankMaterial: material,
                tankType: type,
                usageStartTime: workingUsageStartTime,
                usageEndTime: workingUsageEndTime
            )
            targetIndex = min(max(workingSlot - 1, 0), tanks.count - 1)
            if targetIndex != tankIndex {
                let moved = tanks.remove(at: tankIndex)
                tanks.insert(moved, at: targetIndex)
            }
        } else {
            tanks.append(TankData(
                o2: o2Fraction,
                he: heFraction,
                volume: workingCylinderSize,
                startPressure: startP,
                endPressure: endP,
                workingPressure: workingWorkingPressure,
                tankMaterial: material,
                tankType: type,
                usageStartTime: workingUsageStartTime,
                usageEndTime: workingUsageEndTime
            ))
        }

        // Write all dive mutations before notifying the parent so selectedTankIndex
        // always refers to the already-reordered array.
        dive.tanks = tanks
        if targetIndex != tankIndex {
            if rewriteSamples {
                dive.profileSamples = remapSamples(dive.profileSamples, from: tankIndex, to: targetIndex)
            }
            onSlotChanged?(targetIndex)
        }

        // Gas/tank fields do not affect sort order, list grouping, or widget fingerprint.
        // cachedAvailableGasTypes refreshes lazily when the filter sheet opens.
        // If filterGasType is active, rebuildFilteredDives() reads gasType live and
        // correctly includes/excludes this dive without a full rebuild.
        store.commit(dive, affects: .rowFields)
        dismiss()
    }
}
