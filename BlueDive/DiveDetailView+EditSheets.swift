import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Edit Popup Views

/// Popup de modification pour l'onglet Menu (stats principales)
struct EditMenuStatsView: View {
    @Bindable var dive: Dive
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Dive.siteName) private var allDives: [Dive]

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
    @State private var workingDurationText: String
    @State private var workingComputerName: String
    @State private var workingSerialNumber: String

    init(dive: Dive) {
        self.dive = dive
        _workingMaxDepth  = State(initialValue: dive.maxDepth)
        _workingAvgDepth  = State(initialValue: dive.averageDepth)
        _workingDuration  = State(initialValue: dive.duration)
        _workingWeights   = State(initialValue: dive.weights)
        _workingWeightsText = State(initialValue: dive.weights.map { String($0) } ?? "")
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
        _workingMaxDepthText  = State(initialValue: dive.maxDepth > 0 ? String(dive.maxDepth) : "")
        _workingAvgDepthText  = State(initialValue: dive.averageDepth > 0 ? String(dive.averageDepth) : "")
        _workingDurationText  = State(initialValue: dive.duration > 0 ? String(dive.duration) : "")
        _workingComputerName  = State(initialValue: dive.computerName)
        _workingSerialNumber  = State(initialValue: dive.computerSerialNumber ?? "")
    }

    /// Parses a string to Double, accepting both '.' and ',' as decimal separators.
    static func parseFlexibleDouble(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
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
        return allDives.compactMap { d -> String? in
            guard let val = d[keyPath: keyPath]?.trimmingCharacters(in: .whitespaces),
                  !val.isEmpty else { return nil }
            let key = val.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return val
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func uniqueValues(for keyPath: KeyPath<Dive, String>) -> [String] {
        var seen = Set<String>()
        return allDives.compactMap { d -> String? in
            let val = d[keyPath: keyPath].trimmingCharacters(in: .whitespaces)
            guard !val.isEmpty else { return nil }
            let key = val.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return val
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var uniqueBuddyNames: [String] {
        var seen = Set<String>()
        return allDives.flatMap { d -> [String] in
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
        return allDives.flatMap { d -> [String] in
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
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
    }

    #if os(macOS)
    private var macOSBody: some View {
        VStack(spacing: 0) {
            // En-tête élégant
            HStack(spacing: 12) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.title2)
                    .foregroundStyle(.cyan)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Dive")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)
                    Text("Overview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("Save Changes") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(
                LinearGradient(
                    colors: [Color.cyan.opacity(0.1), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    macOSModernGroupBox("Diver", icon: "person.fill", color: .blue) {
                        macOSModernAutocompleteField("Diver", text: $workingDiverName, icon: "person.fill", suggestions: uniqueValues(for: \.diverName))
                        HStack(spacing: 12) {
                            Image(systemName: "number")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text("Dive #")
                                .foregroundStyle(.secondary)
                                .frame(width: 120, alignment: .leading)
                            TextField("", text: $workingDiveNumber)
                                .textFieldStyle(.roundedBorder)
                                .overlay(alignment: .trailing) {
                                    if !workingDiveNumber.isEmpty {
                                        Button {
                                            workingDiveNumber = ""
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.trailing, 6)
                                    }
                                }
                        }
                        .padding(.vertical, 4)
                    }

                    macOSModernGroupBox("Operator", icon: "building.2.fill", color: .teal) {
                        macOSModernAutocompleteField("Dive Center", text: $workingDiveCenter, icon: "building.2.fill", suggestions: uniqueOptionalValues(for: \.diveOperator))
                        macOSModernAutocompleteField("Guide/Instructor", text: $workingDiveMaster, icon: "person.badge.shield.checkmark.fill", suggestions: uniqueOptionalValues(for: \.diveMaster))
                        macOSModernAutocompleteField("Captain", text: $workingSkipper, icon: "person.fill.turn.right", suggestions: uniqueOptionalValues(for: \.skipper))
                        macOSModernAutocompleteField("Boat", text: $workingBoat, icon: "ferry.fill", suggestions: uniqueOptionalValues(for: \.boat))
                        macOSModernAutocompleteField("Entry Type", text: $workingEntryType, icon: "arrow.down.to.line.circle.fill", suggestions: uniqueOptionalValues(for: \.entryType))
                    }

                    macOSModernGroupBox("Buddy(ies)", icon: "person.2.fill", color: .green) {
                        VStack(alignment: .leading, spacing: 12) {
                            // Current buddies
                            if !buddiesArray.isEmpty {
                                FlowLayout(spacing: 8) {
                                    ForEach(buddiesArray, id: \.self) { buddy in
                                        HStack(spacing: 6) {
                                            Text(buddy)
                                                .font(.subheadline)
                                            Button {
                                                withAnimation {
                                                    removeBuddy(buddy)
                                                }
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.green.opacity(0.15))
                                        .foregroundStyle(.green)
                                        .cornerRadius(16)
                                    }
                                }
                                .padding(.bottom, 8)
                            }

                            // Add new buddy
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 8) {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(.green)
                                    TextField("Add a buddy", text: $newBuddy)
                                        .textFieldStyle(.roundedBorder)
                                        .overlay(alignment: .trailing) {
                                            if !newBuddy.isEmpty {
                                                Button {
                                                    newBuddy = ""
                                                } label: {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .foregroundStyle(.secondary)
                                                }
                                                .buttonStyle(.plain)
                                                .padding(.trailing, 6)
                                            }
                                        }
                                        .onSubmit {
                                            addBuddy(newBuddy)
                                            newBuddy = ""
                                        }
                                    Button("Add") {
                                        withAnimation {
                                            addBuddy(newBuddy)
                                            newBuddy = ""
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.green)
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
                                                    .padding(.vertical, 4)
                                                    .padding(.horizontal, 8)
                                            }
                                            .buttonStyle(.plain)
                                            .background(Color.primary.opacity(0.05))
                                            .cornerRadius(4)
                                        }
                                    }
                                    .padding(.leading, 28)
                                }
                            }
                        }
                    }

                    macOSModernGroupBox("Weight", icon: "scalemass.fill", color: .gray) {
                        HStack(spacing: 12) {
                            Image(systemName: "scalemass.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text("Weight (\(dive.storedWeightUnit.symbol))")
                                .foregroundStyle(.secondary)
                                .frame(width: 120, alignment: .leading)
                            TextField("Weight (\(dive.storedWeightUnit.symbol))", text: $workingWeightsText)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: workingWeightsText) {
                                    workingWeights = Self.parseFlexibleDouble(workingWeightsText)
                                }
                                .overlay(alignment: .trailing) {
                                    if workingWeights != nil {
                                        Button {
                                            workingWeights = nil
                                            workingWeightsText = ""
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.trailing, 6)
                                    }
                                }
                        }
                        .padding(.vertical, 4)
                        Text("Unit (\(dive.storedWeightUnit.symbol)) matches the original import format and cannot be changed.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if dive.sourceImport == "Manual" {
                        macOSModernGroupBox("Dive Stats", icon: "chart.bar.fill", color: .cyan) {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.down.to.line")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text("Max Depth (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit))")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 120, alignment: .leading)
                                TextField("Max Depth (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit))", text: $workingMaxDepthText)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: workingMaxDepthText) {
                                        workingMaxDepth = Self.parseFlexibleDouble(workingMaxDepthText) ?? 0
                                    }
                                    .overlay(alignment: .trailing) {
                                        if !workingMaxDepthText.isEmpty {
                                            Button {
                                                workingMaxDepthText = ""
                                                workingMaxDepth = 0
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .padding(.trailing, 6)
                                        }
                                    }
                            }
                            .padding(.vertical, 4)
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.left.and.right")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text("Avg Depth (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit))")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 120, alignment: .leading)
                                TextField("Avg Depth (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit))", text: $workingAvgDepthText)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: workingAvgDepthText) {
                                        workingAvgDepth = Self.parseFlexibleDouble(workingAvgDepthText) ?? 0
                                    }
                                    .overlay(alignment: .trailing) {
                                        if !workingAvgDepthText.isEmpty {
                                            Button {
                                                workingAvgDepthText = ""
                                                workingAvgDepth = 0
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .padding(.trailing, 6)
                                        }
                                    }
                            }
                            .padding(.vertical, 4)
                            HStack(spacing: 12) {
                                Image(systemName: "clock")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text("Duration (min)")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 120, alignment: .leading)
                                TextField("Duration (min)", text: $workingDurationText)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: workingDurationText) {
                                        workingDuration = Self.parseFlexibleDouble(workingDurationText).map(Int.init) ?? 0
                                    }
                                    .overlay(alignment: .trailing) {
                                        if !workingDurationText.isEmpty {
                                            Button {
                                                workingDurationText = ""
                                                workingDuration = 0
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .padding(.trailing, 6)
                                        }
                                    }
                            }
                            .padding(.vertical, 4)
                            Text("Unit (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit)) matches the original import format and cannot be changed.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        macOSModernGroupBox("Dive Computer", icon: "desktopcomputer", color: .purple) {
                            macOSModernAutocompleteField("Computer Name", text: $workingComputerName, icon: "desktopcomputer", suggestions: uniqueValues(for: \.computerName))
                            macOSModernAutocompleteField("Serial Number", text: $workingSerialNumber, icon: "number", suggestions: uniqueOptionalValues(for: \.computerSerialNumber))
                        }
                    }

                    macOSModernGroupBox("Type & Rating", icon: "star.fill", color: .yellow) {
                        VStack(spacing: 12) {
                            // Dive Types Section
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: "figure.open.water.swim")
                                        .foregroundStyle(.secondary)
                                    Text("Dive Types")
                                        .foregroundStyle(.secondary)
                                        .font(.subheadline)
                                }

                                // Current dive types
                                if !diveTypesArray.isEmpty {
                                    FlowLayout(spacing: 8) {
                                        ForEach(diveTypesArray, id: \.self) { type in
                                            HStack(spacing: 6) {
                                                Text(type)
                                                    .font(.subheadline)
                                                Button {
                                                    withAnimation {
                                                        removeDiveType(type)
                                                    }
                                                } label: {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Color.purple.opacity(0.15))
                                            .foregroundStyle(.purple)
                                            .cornerRadius(16)
                                        }
                                    }
                                    .padding(.bottom, 8)
                                }

                                // Add new dive type
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundStyle(.purple)
                                        TextField("Add a dive type", text: $newType)
                                            .textFieldStyle(.roundedBorder)
                                            .overlay(alignment: .trailing) {
                                                if !newType.isEmpty {
                                                    Button {
                                                        newType = ""
                                                    } label: {
                                                        Image(systemName: "xmark.circle.fill")
                                                            .foregroundStyle(.secondary)
                                                    }
                                                    .buttonStyle(.plain)
                                                    .padding(.trailing, 6)
                                                }
                                            }
                                            .onSubmit {
                                                addDiveType(newType)
                                                newType = ""
                                            }
                                        Button("Add") {
                                            withAnimation {
                                                addDiveType(newType)
                                                newType = ""
                                            }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(.purple)
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
                                                        .padding(.vertical, 4)
                                                        .padding(.horizontal, 8)
                                                }
                                                .buttonStyle(.plain)
                                                .background(Color.primary.opacity(0.05))
                                            }
                                        }
                                        .cornerRadius(4)
                                        .padding(.top, 4)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color.primary.opacity(0.03))
                            .cornerRadius(10)

                            Divider()
                                .padding(.vertical, 4)

                            HStack {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                Text("Rating")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                HStack(spacing: 6) {
                                    ForEach(1...5, id: \.self) { star in
                                        Image(systemName: star <= workingRating ? "star.fill" : "star")
                                            .font(.title3)
                                            .foregroundStyle(star <= workingRating ? .yellow : .secondary)
                                            .onTapGesture {
                                                withAnimation(.easeInOut(duration: 0.2)) {
                                                    workingRating = star == workingRating ? 0 : star
                                                }
                                            }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color.primary.opacity(0.03))
                            .cornerRadius(10)
                        }
                    }

                    macOSModernGroupBox("Tags", icon: "tag.fill", color: .pink) {
                        VStack(alignment: .leading, spacing: 12) {
                            // Current tags
                            if !tagsArray.isEmpty {
                                FlowLayout(spacing: 8) {
                                    ForEach(tagsArray, id: \.self) { tag in
                                        HStack(spacing: 6) {
                                            Text(tag)
                                                .font(.subheadline)
                                            Button {
                                                withAnimation {
                                                    removeTag(tag)
                                                }
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.cyan.opacity(0.15))
                                        .foregroundStyle(.cyan)
                                        .cornerRadius(16)
                                    }
                                }
                                .padding(.bottom, 8)
                            }

                            // Add new tag
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.cyan)
                                TextField("Add a tag", text: $newTag)
                                    .textFieldStyle(.roundedBorder)
                                    .overlay(alignment: .trailing) {
                                        if !newTag.isEmpty {
                                            Button {
                                                newTag = ""
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .padding(.trailing, 6)
                                        }
                                    }
                                    .onSubmit {
                                        addTag(newTag)
                                        newTag = ""
                                    }
                                Button("Add") {
                                    addTag(newTag)
                                    newTag = ""
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.cyan)
                                .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                    }

                    macOSModernGroupBox("Notes", icon: "note.text", color: .orange) {
                        TextEditor(text: $workingNotes)
                            .frame(minHeight: 100)
                            .scrollContentBackground(.hidden)
                            .background(Color.primary.opacity(0.03))
                            .cornerRadius(8)
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 650, height: 750)
        .background(Color.platformBackground)

    }

    // MARK: - macOS Modern Helpers

    private func macOSModernGroupBox(_ title: LocalizedStringKey, icon: String, color: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
            .padding(.bottom, 4)

            VStack(spacing: 0) {
                content()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
    }

    private func macOSModernField(_ label: LocalizedStringKey, text: Binding<String>, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .overlay(alignment: .trailing) {
                    if !text.wrappedValue.isEmpty {
                        Button {
                            text.wrappedValue = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 6)
                    }
                }
        }
        .padding(.vertical, 4)
    }

    private func macOSModernAutocompleteField(_ label: LocalizedStringKey, text: Binding<String>, icon: String, suggestions: [String]) -> some View {
        let filtered = text.wrappedValue.isEmpty ? [] : suggestions.filter {
            $0.localizedCaseInsensitiveContains(text.wrappedValue) && $0.lowercased() != text.wrappedValue.lowercased()
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .overlay(alignment: .trailing) {
                        if !text.wrappedValue.isEmpty {
                            Button {
                                text.wrappedValue = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 6)
                        }
                    }
            }
            .padding(.vertical, 4)

            if !filtered.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered.prefix(5), id: \.self) { suggestion in
                        Button {
                            text.wrappedValue = suggestion
                        } label: {
                            Text(suggestion)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                        }
                        .buttonStyle(.plain)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(4)
                    }
                }
                .padding(.leading, 152)
            }
        }
    }

    private func macOSModernNumberField(_ label: LocalizedStringKey, value: Binding<Double>, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            TextField("0.0", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .overlay(alignment: .trailing) {
                    if value.wrappedValue != 0 {
                        Button {
                            value.wrappedValue = 0
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 6)
                    }
                }
        }
        .padding(.vertical, 4)
    }

    private func macOSModernNumberField(_ label: LocalizedStringKey, value: Binding<Double?>, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .overlay(alignment: .trailing) {
                    if value.wrappedValue != nil {
                        Button {
                            value.wrappedValue = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 6)
                    }
                }
        }
        .padding(.vertical, 4)
    }

    private func macOSModernPicker(_ label: LocalizedStringKey, selection: Binding<String>, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Menu {
                Button("None")    { selection.wrappedValue = "None" }
                Button("Reef")    { selection.wrappedValue = "Reef" }
                Button("Wreck")   { selection.wrappedValue = "Wreck" }
                Button("Cave")    { selection.wrappedValue = "Cave" }
                Button("Night")   { selection.wrappedValue = "Night" }
                Button("Photo")   { selection.wrappedValue = "Photo" }
                Button("Deep")    { selection.wrappedValue = "Deep" }
                Button("Drift")   { selection.wrappedValue = "Drift" }
                Button("Training") { selection.wrappedValue = "Training" }
            } label: {
                HStack {
                    Text(selection.wrappedValue.isEmpty ? "Choose…" : selection.wrappedValue)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 4)
    }
    #endif

    @ViewBuilder
    private var iOSManualDiveSections: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.to.line")
                    .foregroundStyle(.cyan)
                    .frame(width: 24)
                Text("Max Depth (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit))")
                    .foregroundStyle(.primary)
                TextField("Max Depth (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit))", text: $workingMaxDepthText)
                    .platformKeyboardType(.decimalPad)
                    .foregroundStyle(.primary)
                    .onChange(of: workingMaxDepthText) {
                        workingMaxDepth = Self.parseFlexibleDouble(workingMaxDepthText) ?? 0
                    }
                if !workingMaxDepthText.isEmpty {
                    Button {
                        workingMaxDepthText = ""
                        workingMaxDepth = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
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
                TextField("Avg Depth (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit))", text: $workingAvgDepthText)
                    .platformKeyboardType(.decimalPad)
                    .foregroundStyle(.primary)
                    .onChange(of: workingAvgDepthText) {
                        workingAvgDepth = Self.parseFlexibleDouble(workingAvgDepthText) ?? 0
                    }
                if !workingAvgDepthText.isEmpty {
                    Button {
                        workingAvgDepthText = ""
                        workingAvgDepth = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
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
                TextField("Duration (min)", text: $workingDurationText)
                    .platformKeyboardType(.numberPad)
                    .foregroundStyle(.primary)
                    .onChange(of: workingDurationText) {
                        workingDuration = Self.parseFlexibleDouble(workingDurationText).map(Int.init) ?? 0
                    }
                if !workingDurationText.isEmpty {
                    Button {
                        workingDurationText = ""
                        workingDuration = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            MenuSectionHeader(title: "Dive Stats", icon: "chart.bar.fill", color: .cyan)
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
                Color.platformBackground.ignoresSafeArea()

                Form {
                    Section {
                        AutocompleteMenuTextField(label: "Diver", text: $workingDiverName, icon: "person.fill", color: .cyan, suggestions: uniqueValues(for: \.diverName))
                        HStack(spacing: 12) {
                            Image(systemName: "number")
                                .foregroundStyle(.orange)
                                .frame(width: 24)
                            Text("Dive #")
                                .foregroundStyle(.primary)
                            Spacer()
                            TextField("Dive #", text: $workingDiveNumber)
                                .platformKeyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                                .foregroundStyle(.cyan)
                            if !workingDiveNumber.isEmpty {
                                Button {
                                    workingDiveNumber = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        MenuSectionHeader(title: "Diver", icon: "person.fill", color: .blue)
                    }

                    Section {
                        AutocompleteMenuTextField(label: "Dive Center", text: $workingDiveCenter, icon: "building.2.fill", color: .blue, suggestions: uniqueOptionalValues(for: \.diveOperator))
                        AutocompleteMenuTextField(label: "Guide/Instructor", text: $workingDiveMaster, icon: "person.badge.shield.checkmark.fill", color: .teal, suggestions: uniqueOptionalValues(for: \.diveMaster))
                        AutocompleteMenuTextField(label: "Captain", text: $workingSkipper, icon: "person.fill.turn.right", color: .indigo, suggestions: uniqueOptionalValues(for: \.skipper))
                        AutocompleteMenuTextField(label: "Boat", text: $workingBoat, icon: "ferry.fill", color: .mint, suggestions: uniqueOptionalValues(for: \.boat))
                        AutocompleteMenuTextField(label: "Entry Type", text: $workingEntryType, icon: "arrow.down.to.line.circle.fill", color: .yellow, suggestions: uniqueOptionalValues(for: \.entryType))
                    } header: {
                        MenuSectionHeader(title: "Operator", icon: "building.2.fill", color: .teal)
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
                                                    Image(systemName: "xmark.circle.fill")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                                .buttonStyle(.plain)
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
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.green)
                                TextField("Add a buddy", text: $newBuddy)
                                    .autocorrectionDisabled()
                                    .foregroundStyle(.primary)
                                if !newBuddy.isEmpty {
                                    Button {
                                        newBuddy = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
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
                                .foregroundStyle(.green)
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
                        MenuSectionHeader(title: "Buddy(ies)", icon: "person.2.fill", color: .green)
                    }

                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "scalemass.fill")
                                .foregroundStyle(.gray)
                                .frame(width: 24)
                            Text("Weight (\(dive.storedWeightUnit.symbol))")
                                .foregroundStyle(.primary)
                            TextField("Weight (\(dive.storedWeightUnit.symbol))", text: $workingWeightsText)
                                .platformKeyboardType(.decimalPad)
                                .foregroundStyle(.primary)
                                .onChange(of: workingWeightsText) {
                                    workingWeights = Self.parseFlexibleDouble(workingWeightsText)
                                }
                            if workingWeights != nil {
                                Button {
                                    workingWeights = nil
                                    workingWeightsText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        MenuSectionHeader(title: "Weight", icon: "scalemass.fill", color: .gray)
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
                                                    Image(systemName: "xmark.circle.fill")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                                .buttonStyle(.plain)
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
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.purple)
                                TextField("Add a dive type", text: $newType)
                                    .autocorrectionDisabled()
                                    .foregroundStyle(.primary)
                                if !newType.isEmpty {
                                    Button {
                                        newType = ""
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
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
                                .foregroundStyle(.purple)
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
                            Image(systemName: "star.fill")
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
                                }
                            }
                        }
                    } header: {
                        MenuSectionHeader(title: "Type & Rating", icon: "star.fill", color: .yellow)
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
                                                    Image(systemName: "xmark.circle.fill")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                                .buttonStyle(.plain)
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
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.cyan)
                            TextField("Add a tag", text: $newTag)
                                .autocorrectionDisabled()
                                .foregroundStyle(.primary)
                            if !newTag.isEmpty {
                                Button {
                                    newTag = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
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
                            .tint(.cyan)
                            .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } header: {
                        MenuSectionHeader(title: "Tags", icon: "tag.fill", color: .pink)
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
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Edit Dive")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .bold()
                        .foregroundStyle(.cyan)
                }
            }
        }
    }

    private func save() {
        dive.maxDepth     = Self.parseFlexibleDouble(workingMaxDepthText) ?? workingMaxDepth
        dive.averageDepth = Self.parseFlexibleDouble(workingAvgDepthText) ?? workingAvgDepth
        dive.duration     = Self.parseFlexibleDouble(workingDurationText).map(Int.init) ?? workingDuration
        dive.weights      = workingWeights
        dive.diverName    = workingDiverName.trimmingCharacters(in: .whitespaces)
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
        dismiss()
    }
}

struct EditSiteDetailsView: View {
    @Bindable var dive: Dive
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Dive.siteName) private var allDives: [Dive]
    @Query(sort: \Dive.timestamp, order: .reverse) private var allDivesByDate: [Dive]

    @State private var selectedSiteName: String = ""
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
        return allDives.compactMap { d -> Dive? in
            guard d.id != dive.id,
                  !d.siteName.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let key = d.siteName.trimmingCharacters(in: .whitespaces).lowercased()
            guard seen.insert(key).inserted else { return nil }
            return d
        }
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

    /// All unique sites except the 3 most recent, sorted alphabetically by site name
    private var remainingSites: [Dive] {
        let recentKeys = Set(recentSites.map { $0.siteName.trimmingCharacters(in: .whitespaces).lowercased() })
        return uniqueSites.filter { !recentKeys.contains($0.siteName.trimmingCharacters(in: .whitespaces).lowercased()) }
    }

    private func uniqueValues(for keyPath: KeyPath<Dive, String>) -> [String] {
        var seen = Set<String>()
        return allDives.compactMap { d -> String? in
            let val = d[keyPath: keyPath].trimmingCharacters(in: .whitespaces)
            guard !val.isEmpty else { return nil }
            let key = val.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return val
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func uniqueOptionalValues(for keyPath: KeyPath<Dive, String?>) -> [String] {
        var seen = Set<String>()
        return allDives.compactMap { d -> String? in
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
            workingLatitude  = source.siteLatitude.map { String(format: "%.6f", $0) } ?? ""
            workingLongitude = source.siteLongitude.map { String(format: "%.6f", $0) } ?? ""
            workingAltitude  = source.siteAltitude.map { String(format: "%.0f", $0) } ?? ""
        }
    }

    init(dive: Dive) {
        self.dive = dive
        _workingCountry     = State(initialValue: dive.siteCountry ?? "")
        _workingLocation    = State(initialValue: dive.location)
        _workingSiteName    = State(initialValue: dive.siteName)
        _workingWaterType   = State(initialValue: dive.siteWaterType ?? "")
        _workingBodyOfWater = State(initialValue: dive.siteBodyOfWater ?? "")
        _workingLatitude    = State(initialValue: dive.siteLatitude.map { String(format: "%.6f", $0) } ?? "")
        _workingLongitude   = State(initialValue: dive.siteLongitude.map { String(format: "%.6f", $0) } ?? "")
        _workingAltitude    = State(initialValue: dive.siteAltitude.map { String(format: "%.0f", $0) } ?? "")
        _workingDifficulty  = State(initialValue: dive.siteDifficulty ?? "")
    }

    var body: some View {
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
    }

    #if os(macOS)
    private var macOSBody: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "mappin.and.ellipse.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Dive")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)
                    Text("Site Details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("Save Changes") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(
                LinearGradient(
                    colors: [Color.blue.opacity(0.1), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !uniqueSites.isEmpty {
                        siteDetailsMacOSGroupBox("Copy from Existing Site", icon: "doc.on.doc.fill", color: .orange) {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text("Site")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 120, alignment: .leading)
                                Menu {
                                    Button("Select a site…") { selectedSiteName = "" }
                                    if !recentSites.isEmpty {
                                        Section("Recent") {
                                            ForEach(recentSites, id: \.siteName) { site in
                                                Button(site.siteName + (site.location.isEmpty ? "" : " — \(site.location)")) {
                                                    selectedSiteName = site.siteName
                                                }
                                            }
                                        }
                                    }
                                    if !remainingSites.isEmpty {
                                        Section("All Sites") {
                                            ForEach(remainingSites, id: \.siteName) { site in
                                                Button(site.siteName + (site.location.isEmpty ? "" : " — \(site.location)")) {
                                                    selectedSiteName = site.siteName
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text(selectedSiteName.isEmpty ? "Select a site…" : selectedSiteName)
                                        Spacer()
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.caption)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .padding(.vertical, 4)

                            HStack(spacing: 8) {
                                Toggle(isOn: $copyGPSCoordinates) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "location.circle.fill")
                                            .foregroundStyle(.green)
                                        Text("Include GPS Coordinates")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .controlSize(.small)

                                Spacer()

                                Button("Copy Site Information") {
                                    if let source = uniqueSites.first(where: { $0.siteName == selectedSiteName }) {
                                        applySite(from: source)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                                .disabled(selectedSiteName.isEmpty)
                            }
                            .padding(.top, 8)
                        }
                    }

                    siteDetailsMacOSGroupBox("Location", icon: "mappin.and.ellipse", color: .blue) {
                        siteDetailsMacOSAutocompleteField("Site Name", text: $workingSiteName, icon: "location.fill", suggestions: uniqueValues(for: \.siteName))
                        siteDetailsMacOSAutocompleteField("Country", text: $workingCountry, icon: "flag.fill", suggestions: uniqueOptionalValues(for: \.siteCountry))
                        siteDetailsMacOSAutocompleteField("Location", text: $workingLocation, icon: "mappin.and.ellipse", suggestions: uniqueValues(for: \.location))
                        HStack(spacing: 12) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text("Difficulty")
                                .foregroundStyle(.secondary)
                                .frame(width: 120, alignment: .leading)
                            Menu {
                                Button("—") { workingDifficulty = "" }
                                ForEach(Self.difficultyScale, id: \.level) { item in
                                    Button { workingDifficulty = String(item.level) } label: {
                                        Text("\(item.level) — \(Text(LocalizedStringKey(item.label)))")
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(workingDifficulty.isEmpty ? "—" : {
                                        if let n = Int(workingDifficulty),
                                           let match = Self.difficultyScale.first(where: { $0.level == n }) {
                                            return "\(match.level) — \(match.label)"
                                        }
                                        return workingDifficulty
                                    }())
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }

                    siteDetailsMacOSGroupBox("Water", icon: "drop.fill", color: .teal) {
                        siteDetailsMacOSAutocompleteField("Water Type", text: $workingWaterType, icon: "drop.fill", suggestions: uniqueOptionalValues(for: \.siteWaterType))
                        siteDetailsMacOSAutocompleteField("Body of Water", text: $workingBodyOfWater, icon: "water.waves", suggestions: uniqueOptionalValues(for: \.siteBodyOfWater))
                    }

                    siteDetailsMacOSGroupBox("GPS Coordinates", icon: "location.circle.fill", color: .green) {
                        siteDetailsMacOSField("Latitude", text: $workingLatitude, icon: "arrow.up.arrow.down")
                        siteDetailsMacOSField("Longitude", text: $workingLongitude, icon: "arrow.left.arrow.right")
                        siteDetailsMacOSField(LocalizedStringKey("Altitude (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit))"), text: $workingAltitude, icon: "mountain.2.fill")
                        Text("Unit (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit)) matches the original import format and cannot be changed.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 650, height: 550)
        .background(Color.platformBackground)

    }

    private func siteDetailsMacOSGroupBox(_ title: LocalizedStringKey, icon: String, color: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
            .padding(.bottom, 4)

            VStack(spacing: 0) {
                content()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
    }

    private func siteDetailsMacOSField(_ label: LocalizedStringKey, text: Binding<String>, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .overlay(alignment: .trailing) {
                    if !text.wrappedValue.isEmpty {
                        Button {
                            text.wrappedValue = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 6)
                    }
                }
        }
        .padding(.vertical, 4)
    }

    private func siteDetailsMacOSPicker(_ label: LocalizedStringKey, selection: Binding<String>, options: [String], icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Menu {
                Button("—") { selection.wrappedValue = "" }
                ForEach(options, id: \.self) { opt in
                    Button { selection.wrappedValue = opt } label: { Text(LocalizedStringKey(opt)) }
                }
            } label: {
                HStack {
                    Text(LocalizedStringKey(selection.wrappedValue.isEmpty ? "—" : selection.wrappedValue))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    private func siteDetailsMacOSAutocompleteField(_ label: LocalizedStringKey, text: Binding<String>, icon: String, suggestions: [String]) -> some View {
        let filtered = text.wrappedValue.isEmpty ? [] : suggestions.filter {
            $0.localizedCaseInsensitiveContains(text.wrappedValue) && $0.lowercased() != text.wrappedValue.lowercased()
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .overlay(alignment: .trailing) {
                        if !text.wrappedValue.isEmpty {
                            Button {
                                text.wrappedValue = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 6)
                        }
                    }
            }
            .padding(.vertical, 4)

            if !filtered.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered.prefix(5), id: \.self) { suggestion in
                        Button {
                            text.wrappedValue = suggestion
                        } label: {
                            Text(suggestion)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                        }
                        .buttonStyle(.plain)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(4)
                    }
                }
                .padding(.leading, 152)
            }
        }
    }
    #endif

    @ViewBuilder
    private var copyFromSiteSection: some View {
        if !uniqueSites.isEmpty {
            Section {
                Picker("Site", selection: $selectedSiteName) {
                    Text("Select a site…").tag("")
                    if !recentSites.isEmpty {
                        Section("Recent") {
                            ForEach(recentSites, id: \.siteName) { site in
                                let label = site.siteName + (site.location.isEmpty ? "" : " — \(site.location)")
                                Text(label).tag(site.siteName)
                            }
                        }
                    }
                    if !remainingSites.isEmpty {
                        Section("All Sites") {
                            ForEach(remainingSites, id: \.siteName) { site in
                                let label = site.siteName + (site.location.isEmpty ? "" : " — \(site.location)")
                                Text(label).tag(site.siteName)
                            }
                        }
                    }
                }
                .tint(.orange)

                Toggle(isOn: $copyGPSCoordinates) {
                    HStack(spacing: 12) {
                        Image(systemName: "location.circle.fill")
                            .foregroundStyle(.green)
                            .frame(width: 24)
                        Text("Include GPS Coordinates")
                    }
                }
                .tint(.green)

                Button {
                    if let source = uniqueSites.first(where: { $0.siteName == selectedSiteName }) {
                        applySite(from: source)
                    }
                } label: {
                    HStack {
                        Image(systemName: "doc.on.doc.fill")
                        Text("Copy Site Information")
                    }
                }
                .disabled(selectedSiteName.isEmpty)
                .foregroundStyle(.orange)
            } header: {
                MenuSectionHeader(title: "Copy from Existing Site", icon: "doc.on.doc.fill", color: .orange)
            }
        }
    }

    private var iOSBody: some View {
        NavigationStack {
            ZStack {
                Color.platformBackground.ignoresSafeArea()

                Form {
                    copyFromSiteSection

                    Section {
                        AutocompleteMenuTextField(label: "Site Name", text: $workingSiteName, icon: "location.fill", color: .cyan, suggestions: uniqueValues(for: \.siteName))
                        AutocompleteMenuTextField(label: "Country", text: $workingCountry, icon: "flag.fill", color: .blue, suggestions: uniqueOptionalValues(for: \.siteCountry))
                        AutocompleteMenuTextField(label: "Location", text: $workingLocation, icon: "mappin.and.ellipse", color: .orange, suggestions: uniqueValues(for: \.location))
                        Picker(selection: $workingDifficulty) {
                            Text("—").tag("")
                            ForEach(Self.difficultyScale, id: \.level) { item in
                                Text("\(item.level) — \(Text(LocalizedStringKey(item.label)))").tag(String(item.level))
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "star.fill")
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
                        AutocompleteMenuTextField(label: "Water Type", text: $workingWaterType, icon: "drop.fill", color: .blue, suggestions: uniqueOptionalValues(for: \.siteWaterType))
                        AutocompleteMenuTextField(label: "Body of Water", text: $workingBodyOfWater, icon: "water.waves", color: .teal, suggestions: uniqueOptionalValues(for: \.siteBodyOfWater))
                    } header: {
                        MenuSectionHeader(title: "Water", icon: "drop.fill", color: .teal)
                    }

                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.up.arrow.down")
                                .foregroundStyle(.green)
                                .frame(width: 24)
                            Text("Latitude")
                                .foregroundStyle(.primary)
                            TextField("Latitude", text: $workingLatitude)
                                .platformKeyboardType(.decimalPad)
                                .foregroundStyle(.primary)
                            gpsSignToggleButton(for: $workingLatitude)
                            if !workingLatitude.isEmpty {
                                Button {
                                    workingLatitude = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
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
                            TextField("Longitude", text: $workingLongitude)
                                .platformKeyboardType(.decimalPad)
                                .foregroundStyle(.primary)
                            gpsSignToggleButton(for: $workingLongitude)
                            if !workingLongitude.isEmpty {
                                Button {
                                    workingLongitude = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "mountain.2.fill")
                                .foregroundStyle(.brown)
                                .frame(width: 24)
                            Text("Altitude (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit))")
                                .foregroundStyle(.primary)
                            TextField("Altitude (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit))", text: $workingAltitude)
                                .platformKeyboardType(.decimalPad)
                                .foregroundStyle(.primary)
                            if !workingAltitude.isEmpty {
                                Button {
                                    workingAltitude = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        MenuSectionHeader(title: "GPS Coordinates", icon: "location.circle.fill", color: .green)
                    } footer: {
                        Text("Unit (\(DepthUnit(rawValue: dive.importDistanceUnit)?.symbol ?? dive.importDistanceUnit)) matches the original import format and cannot be changed.")
                            .font(.caption2)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Edit Site Details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .bold()
                        .foregroundStyle(.blue)
                }
            }
        }
    }

    /// A "+/−" button that toggles the sign of a GPS coordinate string, keeping the decimal pad usable.
    @ViewBuilder
    private func gpsSignToggleButton(for value: Binding<String>) -> some View {
        #if os(iOS)
        Button {
            let trimmed = value.wrappedValue.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("-") {
                value.wrappedValue = String(trimmed.dropFirst())
            } else if !trimmed.isEmpty {
                value.wrappedValue = "-" + trimmed
            } else {
                value.wrappedValue = "-"
            }
        } label: {
            Text("+/−")
                .font(.system(.body, design: .rounded, weight: .medium))
                .foregroundStyle(.green)
        }
        .buttonStyle(.plain)
        #endif
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
        dive.siteLatitude   = Double(workingLatitude.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        dive.siteLongitude  = Double(workingLongitude.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        dive.siteAltitude   = Double(workingAltitude.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        let trimmedDifficulty  = workingDifficulty.trimmingCharacters(in: .whitespaces)
        dive.siteDifficulty = trimmedDifficulty.isEmpty ? nil : trimmedDifficulty
        dismiss()
    }
}

/// Popup de modification pour l'onglet Conditions
struct EditConditionsView: View {
    @Bindable var dive: Dive
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Dive.siteName) private var allDives: [Dive]

    @State private var workingWaterTemp: Double
    @State private var workingMinTemp: String
    @State private var workingAirTemp: String
    @State private var workingMaxTemp: String
    @State private var workingWeather: String
    @State private var workingSurface: String
    @State private var workingCurrent: String
    @State private var workingVisibility: String

    private let weatherOptions = ["Sunny", "Cloudy", "Overcast", "Rain", "Storm", "Variable"]
    private let surfaceOptions  = ["Calm", "Slightly choppy", "Choppy", "Heavy swell"]
    private let currentOptions  = ["None", "Weak", "Moderate", "Strong", "Very strong"]

    private var visibilitySuggestions: [String] {
        var seen = Set<String>()
        return allDives.compactMap { d -> String? in
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
        _workingMinTemp    = State(initialValue: dive.minTemperature != 0 ? String(format: "%.1f", dive.minTemperature) : "")
        _workingAirTemp    = State(initialValue: dive.airTemperature.map { String(format: "%.1f", $0) } ?? "")
        _workingMaxTemp    = State(initialValue: dive.maxTemperature.map { String(format: "%.1f", $0) } ?? "")
        _workingWeather    = State(initialValue: dive.weather ?? "")
        _workingSurface    = State(initialValue: dive.surfaceConditions ?? "")
        _workingCurrent    = State(initialValue: dive.current ?? "")
        _workingVisibility = State(initialValue: dive.visibility ?? "")
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            // En-tête élégant
            HStack(spacing: 12) {
                Image(systemName: "cloud.sun.fill")
                    .font(.title2)
                    .foregroundStyle(.yellow)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Dive")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)
                    Text("Conditions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Save Changes") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow)
                    .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(
                LinearGradient(
                    colors: [Color.yellow.opacity(0.1), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    conditionsMacOSGroup("Temperatures (\(dive.storedTemperatureUnit.symbol))", icon: "thermometer.medium", color: .orange) {
                        conditionsMacOSField("Surface Temp. (\(dive.storedTemperatureUnit.symbol))", text: $workingAirTemp, icon: "thermometer.medium")
                        conditionsMacOSField("Min Temp. (\(dive.storedTemperatureUnit.symbol))", text: $workingMinTemp, icon: "thermometer.low")
                        conditionsMacOSField("Max Temp. (\(dive.storedTemperatureUnit.symbol))", text: $workingMaxTemp, icon: "thermometer.high")
                        Text("Unit (\(dive.storedTemperatureUnit.symbol)) matches the original import format and cannot be changed.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    conditionsMacOSGroup("Weather & Sea", icon: "cloud.sun.fill", color: .blue) {
                        conditionsMacOSPicker("Weather", selection: $workingWeather, options: weatherOptions, icon: "cloud.sun.fill")
                        conditionsMacOSPicker("Surface", selection: $workingSurface, options: surfaceOptions, icon: "water.waves")
                        conditionsMacOSPicker("Current", selection: $workingCurrent, options: currentOptions, icon: "wind")
                    }

                    conditionsMacOSGroup("Visibility", icon: "eye.fill", color: .green) {
                        conditionsMacOSAutocompleteField("Visibility", text: $workingVisibility, icon: "eye.fill", suggestions: visibilitySuggestions)
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 550, height: 500)
        .background(Color.platformBackground)

        #else
        NavigationStack {
            ZStack {
                Color.platformBackground.ignoresSafeArea()

                Form {
                    Section {
                        ConditionsTemperatureField(label: "Surface Temp.", text: $workingAirTemp, icon: "thermometer.medium", unit: dive.storedTemperatureUnit.symbol)
                        ConditionsTemperatureField(label: "Min Temp.", text: $workingMinTemp, icon: "thermometer.low", unit: dive.storedTemperatureUnit.symbol)
                        ConditionsTemperatureField(label: "Max Temp.", text: $workingMaxTemp, icon: "thermometer.high", unit: dive.storedTemperatureUnit.symbol)
                    } header: {
                        ConditionsSectionHeader(title: "Temperatures (\(dive.storedTemperatureUnit.symbol))", icon: "thermometer.medium", color: .orange)
                    } footer: {
                        Text("Unit (\(dive.storedTemperatureUnit.symbol)) matches the original import format and cannot be changed.")
                            .font(.caption2)
                    }

                    Section {
                        ConditionsPickerRow(label: "Weather", selection: $workingWeather, options: weatherOptions, icon: "cloud.sun.fill")
                        ConditionsPickerRow(label: "Surface", selection: $workingSurface, options: surfaceOptions, icon: "water.waves")
                        ConditionsPickerRow(label: "Current", selection: $workingCurrent, options: currentOptions, icon: "wind")
                    } header: {
                        ConditionsSectionHeader(title: "Weather & Sea", icon: "cloud.sun.fill", color: .blue)
                    }

                    Section {
                        AutocompleteMenuTextField(label: "Visibility", text: $workingVisibility, icon: "eye.fill", color: .green, suggestions: visibilitySuggestions)
                    } header: {
                        ConditionsSectionHeader(title: "Visibility", icon: "eye.fill", color: .green)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Edit Conditions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .bold()
                        .foregroundStyle(.yellow)
                }
            }
        }
        #endif
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

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(.blue)
                    .frame(width: 24)
                Picker(label, selection: $selection) {
                    Text("—").tag("")
                    ForEach(options, id: \.self) { opt in Text(LocalizedStringKey(opt)).tag(opt) }
                }
            }
        }
    }

    #if os(macOS)
    private func conditionsMacOSGroup(_ title: LocalizedStringKey, icon: String, color: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
            .padding(.bottom, 4)

            VStack(spacing: 12) {
                content()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
    }

    private func conditionsMacOSField(_ label: LocalizedStringKey, text: Binding<String>, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .overlay(alignment: .trailing) {
                    if !text.wrappedValue.isEmpty {
                        Button {
                            text.wrappedValue = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 6)
                    }
                }
        }
    }



    private func conditionsMacOSAutocompleteField(_ label: LocalizedStringKey, text: Binding<String>, icon: String, suggestions: [String]) -> some View {
        let filtered = text.wrappedValue.isEmpty ? [] : suggestions.filter {
            $0.localizedCaseInsensitiveContains(text.wrappedValue) && $0.lowercased() != text.wrappedValue.lowercased()
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .overlay(alignment: .trailing) {
                        if !text.wrappedValue.isEmpty {
                            Button {
                                text.wrappedValue = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 6)
                        }
                    }
            }

            if !filtered.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered.prefix(5), id: \.self) { suggestion in
                        Button {
                            text.wrappedValue = suggestion
                        } label: {
                            Text(suggestion)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                        }
                        .buttonStyle(.plain)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(4)
                    }
                }
                .padding(.leading, 152)
            }
        }
    }

    private func conditionsMacOSPicker(_ label: LocalizedStringKey, selection: Binding<String>, options: [String], icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Menu {
                Button("—") { selection.wrappedValue = "" }
                ForEach(options, id: \.self) { opt in
                    Button(opt) { selection.wrappedValue = opt }
                }
            } label: {
                HStack {
                    Text(selection.wrappedValue.isEmpty ? "—" : selection.wrappedValue)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
    }
    #endif

    private func save() {
        dive.waterTemperature  = workingWaterTemp
        dive.minTemperature    = Double(workingMinTemp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) ?? 0.0
        dive.airTemperature    = Double(workingAirTemp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        dive.maxTemperature    = Double(workingMaxTemp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        let trimmedWeather     = workingWeather.trimmingCharacters(in: .whitespaces)
        dive.weather           = trimmedWeather.isEmpty    ? nil : trimmedWeather
        let trimmedSurface     = workingSurface.trimmingCharacters(in: .whitespaces)
        dive.surfaceConditions = trimmedSurface.isEmpty    ? nil : trimmedSurface
        let trimmedCurrent     = workingCurrent.trimmingCharacters(in: .whitespaces)
        dive.current           = trimmedCurrent.isEmpty    ? nil : trimmedCurrent
        let trimmedVisibility  = workingVisibility.trimmingCharacters(in: .whitespaces)
        dive.visibility        = trimmedVisibility.isEmpty ? nil : trimmedVisibility
        dismiss()
    }
}

/// Popup de modification pour l'onglet Gaz
struct EditGazView: View {
    @Bindable var dive: Dive
    let tankIndex: Int
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \TankTemplate.name) private var templates: [TankTemplate]
    @State private var selectedTemplateName: String = ""

    @State private var workingGasType: String
    @State private var workingO2: Int
    @State private var workingHe: Int
    @State private var workingCylinderSize: Double?
    @State private var cylinderSizeText: String
    @State private var workingCylinderMaterial: String
    @State private var workingCylinderType: String
    @State private var workingStartPressure: Int?
    @State private var workingEndPressure: Int?
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

    @State private var usageTimeUnit: UsageTimeUnit = .minutes

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

    /// Parses a string to Double, accepting both '.' and ',' as decimal separators.
    static func parseFlexibleDouble(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }

    /// Formats a Double? into a string suitable for text field display.
    private static func formatDouble(_ value: Double?) -> String {
        guard let value else { return "" }
        // Remove trailing .0 for whole numbers
        if value == value.rounded() && value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(value)
    }

    private let materialOptions = ["Steel", "Galvanized Steel", "Aluminium", "Carbon"]
    private let typeOptions     = ["Single tank", "Twinset", "Sidemount", "Pony", "Rebreather", "Other"]

    init(dive: Dive, tankIndex: Int = 0) {
        self.dive = dive
        self.tankIndex = tankIndex
        let tanks = dive.tanks
        let tank = tankIndex < tanks.count ? tanks[tankIndex] : nil
        _workingGasType          = State(initialValue: tank?.gasName ?? "Air")
        _workingO2               = State(initialValue: tank?.o2Percentage ?? 21)
        _workingHe               = State(initialValue: tank?.hePercentage ?? 0)
        _workingCylinderSize     = State(initialValue: tank?.volume)
        _cylinderSizeText        = State(initialValue: Self.formatDouble(tank?.volume))
        _workingCylinderMaterial = State(initialValue: tank?.tankMaterial ?? "")
        _workingCylinderType     = State(initialValue: tank?.tankType ?? "")
        _workingStartPressure    = State(initialValue: tank?.startPressure.map { Int($0.rounded()) })
        _workingEndPressure      = State(initialValue: tank?.endPressure.map { Int($0.rounded()) })
        _workingWorkingPressure  = State(initialValue: tank?.workingPressure)
        _workingPressureText     = State(initialValue: Self.formatDouble(tank?.workingPressure))
        _workingUsageStartTime   = State(initialValue: tank?.usageStartTime)
        _usageStartTimeText      = State(initialValue: Self.formatDouble(tank?.usageStartTime.map { $0 / 60.0 }))
        _workingUsageEndTime     = State(initialValue: tank?.usageEndTime)
        _usageEndTimeText        = State(initialValue: Self.formatDouble(tank?.usageEndTime.map { $0 / 60.0 }))
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
            workingPressureText = Self.formatDouble(converted)
        }

        if let vol = template.volume, let wp = template.workingPressure {
            if template.storedVolumeUnit == dive.storedVolumeUnit {
                // Same unit system — copy directly
                workingCylinderSize = vol
                cylinderSizeText = Self.formatDouble(vol)
            } else {
                // Cross-unit conversion using working pressure.
                // First get working pressure in bar for the formula.
                let wpBar = PressureUnit.bar.convert(wp, from: template.storedPressureUnit)

                if template.storedVolumeUnit == .liters && dive.storedVolumeUnit == .cubicFeet {
                    // L → cu ft:  cuft = (L × wp_bar) / 28.3168
                    let converted = (vol * wpBar) / 28.3168
                    workingCylinderSize = converted
                    cylinderSizeText = Self.formatDouble(converted)
                } else if template.storedVolumeUnit == .cubicFeet && dive.storedVolumeUnit == .liters {
                    // cu ft → L:  L = (cuft × 28.3168) / wp_bar
                    let converted = (vol * 28.3168) / wpBar
                    workingCylinderSize = converted
                    cylinderSizeText = Self.formatDouble(converted)
                }
            }
        }

        workingCylinderMaterial = template.material ?? ""
        workingCylinderType = template.format ?? ""
    }

    /// Détermine automatiquement le type de gaz selon O₂ et He
    private var autoGasLabel: String {
        if workingHe > 0 {
            return "Trimix"
        } else if workingO2 == 21 {
            return "Air"
        } else if workingO2 > 21 {
            return "Nitrox"
        } else {
            return "Hypoxic"
        }
    }

    /// O₂ max sans dépasser 100 % en tenant compte de He
    private var o2Max: Int { 100 - workingHe }
    /// He max sans dépasser 100 % en tenant compte de O₂
    private var heMax: Int { 100 - workingO2 }

    var body: some View {
#if os(macOS)
        VStack(spacing: 0) {
            // En-tête élégant
            HStack(spacing: 12) {
                Image(systemName: "bubbles.and.sparkles.fill")
                    .font(.title2)
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Dive")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)
                    Text("Gas & Tank")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Save Changes") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(
                LinearGradient(
                    colors: [Color.green.opacity(0.1), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Copy from Tank Template
                    if !templates.isEmpty {
                        gazMacOSGroup("Copy from Tank Template", icon: "doc.on.doc.fill", color: .orange) {
                            gazMacOSRow("Template") {
                                Menu {
                                    Button("Select a template...") { selectedTemplateName = "" }
                                    ForEach(templates) { template in
                                        Button(template.name) {
                                            selectedTemplateName = template.name
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text(selectedTemplateName.isEmpty ? "Select a template..." : selectedTemplateName)
                                            .foregroundStyle(selectedTemplateName.isEmpty ? .secondary : .primary)
                                        Spacer()
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .padding(.vertical, 4)

                            HStack {
                                Spacer()
                                Button("Copy Tank Information") {
                                    if let source = templates.first(where: { $0.name == selectedTemplateName }) {
                                        applyTemplate(from: source)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                                .disabled(selectedTemplateName.isEmpty)
                            }
                            .padding(.top, 4)
                        }
                    }

                    gazMacOSGroup("Gas Blend", icon: "bubbles.and.sparkles.fill", color: .green) {
                        gazMacOSRow("Gas Type") {
                            Text(LocalizedStringKey(autoGasLabel))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.green)
                        }
                        Divider()
                        gazMacOSRow("Oxygen (O₂)") {
                            Stepper(value: $workingO2, in: 21...o2Max) {
                                Text((Double(workingO2) / 100).formatted(.percent.precision(.fractionLength(0))))
                            }
                                .onChange(of: workingO2) { workingGasType = autoGasLabel }
                        }
                        Divider()
                        gazMacOSRow("Helium (He)") {
                            Stepper(value: $workingHe, in: 0...heMax) {
                                Text((Double(workingHe) / 100).formatted(.percent.precision(.fractionLength(0))))
                            }
                                .onChange(of: workingHe) { workingGasType = autoGasLabel }
                        }
                    }
                    gazMacOSGroup("Tank", icon: "cylinder.fill", color: .blue) {
                        HStack(spacing: 12) {
                            Image(systemName: "cylinder.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text("Volume (\(dive.storedVolumeUnit.symbol))")
                                .foregroundStyle(.secondary)
                                .frame(width: 140, alignment: .leading)
                            TextField("Volume (\(dive.storedVolumeUnit.symbol))", text: $cylinderSizeText)
                                .textFieldStyle(.roundedBorder)
                                .foregroundStyle(cylinderSizeIsValid ? Color.primary : Color.orange)
                                .onChange(of: cylinderSizeText) {
                                    workingCylinderSize = Self.parseFlexibleDouble(cylinderSizeText)
                                }
                                .overlay(alignment: .trailing) {
                                    if workingCylinderSize != nil {
                                        Button {
                                            workingCylinderSize = nil
                                            cylinderSizeText = ""
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.trailing, 6)
                                    }
                                }
                        }
                        .padding(.vertical, 4)
                        Divider()
                        // Working pressure — essential to convert gas-capacity (cu ft) → L
                        HStack(spacing: 12) {
                            Image(systemName: "gauge.badge.plus")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text("Service pressure (\(dive.storedPressureUnit.symbol))")
                                .foregroundStyle(.secondary)
                                .frame(width: 180, alignment: .leading)
                            TextField("Service pressure (\(dive.storedPressureUnit.symbol))", text: $workingPressureText)
                                .textFieldStyle(.roundedBorder)
                                .foregroundStyle(workingPressureIsValid ? Color.primary : Color.orange)
                                .onChange(of: workingPressureText) {
                                    workingWorkingPressure = Self.parseFlexibleDouble(workingPressureText)
                                }
                                .overlay(alignment: .trailing) {
                                    if workingWorkingPressure != nil {
                                        Button {
                                            workingWorkingPressure = nil
                                            workingPressureText = ""
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.trailing, 6)
                                    }
                                }
                        }
                        .padding(.vertical, 4)
                        Divider()
                        gazMacOSRow("Material") {
                            Menu {
                                Button("—") { DispatchQueue.main.async { workingCylinderMaterial = "" } }
                                ForEach(materialOptions, id: \.self) { opt in
                                    Button { DispatchQueue.main.async { workingCylinderMaterial = opt } } label: { Text(LocalizedStringKey(opt)) }
                                }
                            } label: {
                                Text(LocalizedStringKey(workingCylinderMaterial.isEmpty ? "—" : workingCylinderMaterial))
                            }
                        }
                        Divider()
                        gazMacOSRow("Format") {
                            Menu {
                                Button("—") { DispatchQueue.main.async { workingCylinderType = "" } }
                                ForEach(typeOptions, id: \.self) { opt in
                                    Button { DispatchQueue.main.async { workingCylinderType = opt } } label: { Text(LocalizedStringKey(opt)) }
                                }
                            } label: {
                                Text(LocalizedStringKey(workingCylinderType.isEmpty ? "—" : workingCylinderType))
                            }
                        }
                        Text("Volume unit (\(dive.storedVolumeUnit.symbol)) matches the original import format and cannot be changed.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    gazMacOSGroup("Pressure", icon: "gauge.with.needle.fill", color: .red) {
                        HStack(spacing: 12) {
                            Image(systemName: "gauge.with.needle.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text("Start pressure (\(dive.storedPressureUnit.symbol))")
                                .foregroundStyle(.secondary)
                                .frame(width: 180, alignment: .leading)
                            TextField("Start pressure (\(dive.storedPressureUnit.symbol))", value: $workingStartPressure, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .overlay(alignment: .trailing) {
                                    if workingStartPressure != nil {
                                        Button {
                                            workingStartPressure = nil
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.trailing, 6)
                                    }
                                }
                        }
                        .padding(.vertical, 4)
                        Divider()
                        HStack(spacing: 12) {
                            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text("End pressure (\(dive.storedPressureUnit.symbol))")
                                .foregroundStyle(.secondary)
                                .frame(width: 180, alignment: .leading)
                            TextField("End pressure (\(dive.storedPressureUnit.symbol))", value: $workingEndPressure, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .overlay(alignment: .trailing) {
                                    if workingEndPressure != nil {
                                        Button {
                                            workingEndPressure = nil
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.trailing, 6)
                                    }
                                }
                        }
                        .padding(.vertical, 4)
                        Text("Pressure unit (\(dive.storedPressureUnit.symbol)) matches the original import format and cannot be changed.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    gazMacOSGroup("Usage Time", icon: "clock.fill", color: .cyan) {
                        Picker("Unit", selection: $usageTimeUnit) {
                            ForEach(UsageTimeUnit.allCases, id: \.self) { unit in
                                Text(LocalizedStringKey(unit.rawValue)).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: usageTimeUnit) {
                            // Re-display existing values in new unit
                            usageStartTimeText = workingUsageStartTime.map {
                                Self.formatDouble(usageTimeUnit.fromSeconds($0))
                            } ?? ""
                            usageEndTimeText = workingUsageEndTime.map {
                                Self.formatDouble(usageTimeUnit.fromSeconds($0))
                            } ?? ""
                        }

                        HStack(spacing: 12) {
                            Image(systemName: "play.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(verbatim: NSLocalizedString("Usage Start", bundle: Bundle.forAppLanguage(), comment: "") + " (\(usageTimeUnit.symbol))")
                                .foregroundStyle(.secondary)
                                .frame(width: 180, alignment: .leading)
                            TextField("Usage Start", text: $usageStartTimeText)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: usageStartTimeText) {
                                    if let parsed = Self.parseFlexibleDouble(usageStartTimeText) {
                                        workingUsageStartTime = usageTimeUnit.toSeconds(parsed)
                                    } else {
                                        workingUsageStartTime = nil
                                    }
                                }
                                .overlay(alignment: .trailing) {
                                    if workingUsageStartTime != nil {
                                        Button {
                                            workingUsageStartTime = nil
                                            usageStartTimeText = ""
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.trailing, 6)
                                    }
                                }
                        }
                        .padding(.vertical, 4)
                        Divider()
                        HStack(spacing: 12) {
                            Image(systemName: "stop.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Text(verbatim: NSLocalizedString("Usage End", bundle: Bundle.forAppLanguage(), comment: "") + " (\(usageTimeUnit.symbol))")
                                .foregroundStyle(.secondary)
                                .frame(width: 180, alignment: .leading)
                            TextField("Usage End", text: $usageEndTimeText)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: usageEndTimeText) {
                                    if let parsed = Self.parseFlexibleDouble(usageEndTimeText) {
                                        workingUsageEndTime = usageTimeUnit.toSeconds(parsed)
                                    } else {
                                        workingUsageEndTime = nil
                                    }
                                }
                                .overlay(alignment: .trailing) {
                                    if workingUsageEndTime != nil {
                                        Button {
                                            workingUsageEndTime = nil
                                            usageEndTimeText = ""
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.trailing, 6)
                                    }
                                }
                        }
                        .padding(.vertical, 4)
                        Text("Optional. Specify when this tank was used during the dive for more accurate RMV/SAC calculation.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 600, height: 550)
        .background(Color.platformBackground)

#else
        NavigationStack {
            ZStack {
                Color.platformBackground.ignoresSafeArea()

                Form {
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
                                    Image(systemName: "doc.on.doc.fill")
                                    Text("Copy Tank Information")
                                }
                            }
                            .disabled(selectedTemplateName.isEmpty)
                            .foregroundStyle(.orange)
                        } header: {
                            Label("Copy from Tank Template", systemImage: "doc.on.doc.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .textCase(nil)
                        }
                    }

                    Section("Gas blend") {
                        // Auto-calculated type
                        HStack {
                            Label("Gas Type", systemImage: "bubbles.and.sparkles.fill")
                            Spacer()
                            Text(LocalizedStringKey(autoGasLabel))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.green)
                        }

                        // Oxygen
                        HStack {
                            Label("Oxygen (O₂)", systemImage: "o.circle.fill")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text((Double(workingO2) / 100).formatted(.percent.precision(.fractionLength(0))))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.green)
                                .frame(width: 48, alignment: .trailing)
                            Stepper("", value: $workingO2, in: 21...o2Max)
                                .labelsHidden()
                                .onChange(of: workingO2) {
                                    workingGasType = autoGasLabel
                                }
                        }

                        // Helium
                        HStack {
                            Label("Helium (He)", systemImage: "h.circle.fill")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text((Double(workingHe) / 100).formatted(.percent.precision(.fractionLength(0))))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.cyan)
                                .frame(width: 48, alignment: .trailing)
                            Stepper("", value: $workingHe, in: 0...heMax)
                                .labelsHidden()
                                .onChange(of: workingHe) {
                                    workingGasType = autoGasLabel
                                }
                        }
                    }
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "cylinder.fill")
                                .foregroundStyle(.blue)
                                .frame(width: 24)
                            Text("Volume (\(dive.storedVolumeUnit.symbol))")
                                .foregroundStyle(.primary)
                            TextField("Volume (\(dive.storedVolumeUnit.symbol))", text: $cylinderSizeText)
                                .platformKeyboardType(.decimalPad)
                                .foregroundStyle(cylinderSizeIsValid ? Color.primary : Color.orange)
                                .onChange(of: cylinderSizeText) {
                                    workingCylinderSize = Self.parseFlexibleDouble(cylinderSizeText)
                                }
                            if workingCylinderSize != nil {
                                Button {
                                    workingCylinderSize = nil
                                    cylinderSizeText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
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
                            TextField("Service pressure (\(dive.storedPressureUnit.symbol))", text: $workingPressureText)
                                .platformKeyboardType(.decimalPad)
                                .foregroundStyle(workingPressureIsValid ? Color.primary : Color.orange)
                                .onChange(of: workingPressureText) {
                                    workingWorkingPressure = Self.parseFlexibleDouble(workingPressureText)
                                }
                            if workingWorkingPressure != nil {
                                Button {
                                    workingWorkingPressure = nil
                                    workingPressureText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Picker("Material", selection: $workingCylinderMaterial) {
                            Text("—").tag("")
                            ForEach(materialOptions, id: \.self) { opt in Text(LocalizedStringKey(opt)).tag(opt) }
                        }
                        Picker("Format", selection: $workingCylinderType) {
                            Text("—").tag("")
                            ForEach(typeOptions, id: \.self) { opt in Text(LocalizedStringKey(opt)).tag(opt) }
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
                            Image(systemName: "gauge.with.needle.fill")
                                .foregroundStyle(.red)
                                .frame(width: 24)
                            Text("Start pressure (\(dive.storedPressureUnit.symbol))")
                                .foregroundStyle(.primary)
                                .fixedSize()
                            TextField("Start pressure (\(dive.storedPressureUnit.symbol))", value: $workingStartPressure, format: .number)
                                .platformKeyboardType(.numberPad)
                                .foregroundStyle(.primary)
                            if workingStartPressure != nil {
                                Button {
                                    workingStartPressure = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
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
                            TextField("End pressure (\(dive.storedPressureUnit.symbol))", value: $workingEndPressure, format: .number)
                                .platformKeyboardType(.numberPad)
                                .foregroundStyle(.primary)
                            if workingEndPressure != nil {
                                Button {
                                    workingEndPressure = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
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
                        .pickerStyle(.segmented)
                        .onChange(of: usageTimeUnit) {
                            usageStartTimeText = workingUsageStartTime.map {
                                Self.formatDouble(usageTimeUnit.fromSeconds($0))
                            } ?? ""
                            usageEndTimeText = workingUsageEndTime.map {
                                Self.formatDouble(usageTimeUnit.fromSeconds($0))
                            } ?? ""
                        }

                        HStack(spacing: 12) {
                            Image(systemName: "play.fill")
                                .foregroundStyle(.cyan)
                                .frame(width: 24)
                            Text(verbatim: NSLocalizedString("Usage Start", bundle: Bundle.forAppLanguage(), comment: "") + " (\(usageTimeUnit.symbol))")
                                .foregroundStyle(.primary)
                                .fixedSize()
                            TextField("Usage Start", text: $usageStartTimeText)
                                .platformKeyboardType(.decimalPad)
                                .onChange(of: usageStartTimeText) {
                                    if let parsed = Self.parseFlexibleDouble(usageStartTimeText) {
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
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "stop.fill")
                                .foregroundStyle(.cyan)
                                .frame(width: 24)
                            Text(verbatim: NSLocalizedString("Usage End", bundle: Bundle.forAppLanguage(), comment: "") + " (\(usageTimeUnit.symbol))")
                                .foregroundStyle(.primary)
                                .fixedSize()
                            TextField("Usage End", text: $usageEndTimeText)
                                .platformKeyboardType(.decimalPad)
                                .onChange(of: usageEndTimeText) {
                                    if let parsed = Self.parseFlexibleDouble(usageEndTimeText) {
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
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
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
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Edit Gas")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .bold()
                        .foregroundStyle(.green)
                }
            }
        }
#endif
    }

    #if os(macOS)
    private func gazMacOSGroup(_ title: LocalizedStringKey, icon: String, color: Color, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
            .padding(.bottom, 4)

            VStack(spacing: 12) {
                content()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
    }

    private func gazMacOSRow(_ label: LocalizedStringKey, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Spacer()
            trailing()
        }
    }
    #endif

    private func save() {
        let o2Fraction = Double(workingO2) / 100.0
        let heFraction = Double(workingHe) / 100.0
        let startP = workingStartPressure.map { Double($0) }
        let endP   = workingEndPressure.map { Double($0) }
        let trimmedMaterial = workingCylinderMaterial.trimmingCharacters(in: .whitespaces)
        let material = trimmedMaterial.isEmpty ? nil : trimmedMaterial
        let trimmedType = workingCylinderType.trimmingCharacters(in: .whitespaces)
        let type = trimmedType.isEmpty ? nil : trimmedType

        var tanks = dive.tanks

        if tankIndex < tanks.count {
            let existingTank = tanks[tankIndex]
            tanks[tankIndex] = TankData(
                id: existingTank.id,
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
            )
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
        dive.tanks = tanks

        dismiss()
    }
}
