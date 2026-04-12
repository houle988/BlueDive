import SwiftUI
import SwiftData

// MARK: - Merge Dives Sheet

struct MergeDivesSheet: View {
    let dives: [Dive]
    let onMerge: (Dive, Dive) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDiveA: Dive?
    @State private var selectedDiveB: Dive?
    @State private var showConfirmation = false
    @State private var searchText = ""

    private var filteredDives: [Dive] {
        if searchText.isEmpty { return dives }
        let query = searchText.lowercased()
        return dives.filter {
            $0.siteName.lowercased().contains(query) ||
            $0.location.lowercased().contains(query) ||
            ($0.diveNumber.map { "\($0)".contains(query) } ?? false)
        }
    }

    /// Quick summary for the confirmation dialog
    private var mergeSummary: String {
        guard let a = selectedDiveA, let b = selectedDiveB else { return "" }
        let earlier = a.timestamp <= b.timestamp ? a : b
        let later   = a.timestamp <= b.timestamp ? b : a
        return String(
            localized: "Keep \"\(earlier.siteName)\" (\(earlier.timestamp.formatted(date: .abbreviated, time: .shortened))) and append samples from \"\(later.siteName)\" (\(later.timestamp.formatted(date: .abbreviated, time: .shortened))). The second dive will be deleted."
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    mergeHeaderSection
                    mergeSelectionSection
                    mergeDiveListSection
                }
                .padding()
            }
            #if os(macOS)
            .frame(minWidth: 550, idealWidth: 620, maxWidth: 750, minHeight: 500, idealHeight: 650, maxHeight: 850)
            .background(Color(nsColor: .textBackgroundColor))
            #else
            .background(Color(.systemGroupedBackground))
            #endif
            .navigationTitle("Merge Dives")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar { mergeToolbarContent }
        }
        #if os(macOS)
        .frame(minWidth: 550, idealWidth: 620, maxWidth: 750, minHeight: 500, idealHeight: 650, maxHeight: 900)
        #endif

        .alert("Merge dives?", isPresented: $showConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Merge", role: .destructive) {
                if let a = selectedDiveA, let b = selectedDiveB {
                    onMerge(a, b)
                    dismiss()
                }
            }
        } message: {
            Text(mergeSummary)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var mergeToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                dismiss()
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                showConfirmation = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.merge")
                    Text("Merge")
                }
                .fontWeight(.semibold)
            }
            #if os(iOS)
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            #else
            .foregroundStyle(.cyan)
            #endif
            .disabled(selectedDiveA == nil || selectedDiveB == nil)
        }
    }

    // MARK: - Header

    private var mergeHeaderSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.cyan.opacity(0.2))
                    .frame(width: 70, height: 70)
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 32))
                    .foregroundStyle(.cyan)
            }

            Text("Merge Dives")
                .font(.title2)
                .fontWeight(.bold)

            Text("Select exactly two dives to combine. The earlier dive is kept and samples from the later dive are appended.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical)
    }

    // MARK: - Selection Section

    private var mergeSelectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.title3)
                    .foregroundStyle(.cyan)
                Text("Selection")
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 4)

            HStack(spacing: 12) {
                mergeSlotCard(number: "1", dive: selectedDiveA, placeholder: "First dive")
                mergeSlotCard(number: "2", dive: selectedDiveB, placeholder: "Second dive")
            }
        }
        .padding()
        .background(Color.platformTertiaryBackground)
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    // MARK: - Dive List Section

    private var mergeDiveListSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .foregroundStyle(.cyan)
                Text("Dives")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(filteredDives.count) dive(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            mergeSearchField

            mergeDiveRows
        }
        .padding()
        .background(Color.platformTertiaryBackground)
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    // MARK: - Search Field

    @ViewBuilder
    private var mergeSearchField: some View {
        if dives.count > 5 {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search dives…", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.platformSecondaryBackground)
            )
        }
    }

    // MARK: - Dive Rows

    @ViewBuilder
    private var mergeDiveRows: some View {
        if filteredDives.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("No matching dives")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        } else {
            LazyVStack(spacing: 6) {
                ForEach(filteredDives) { dive in
                    mergeDiveRow(dive: dive)
                }
            }
        }
    }

    private func mergeDiveRow(dive: Dive) -> some View {
        let isSelectedA = selectedDiveA?.id == dive.id
        let isSelectedB = selectedDiveB?.id == dive.id
        let isSelected = isSelectedA || isSelectedB

        let resolved = CountryLookup.resolve(dive.siteCountry)

        return HStack(spacing: 12) {
            // Country flag / selection indicator
            ZStack {
                Circle()
                    .fill(isSelected ? Color.cyan.opacity(0.15) : resolved.color.opacity(0.15))
                    .frame(width: 44, height: 44)
                if isSelectedA {
                    Text("1")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.cyan)
                } else if isSelectedB {
                    Text("2")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.cyan)
                } else {
                    Text(resolved.flag)
                        .font(.system(size: 24))
                }
            }

            // Dive info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let num = dive.diveNumber {
                        Text("#\(num)")
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.bold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.cyan.opacity(0.2))
                            .foregroundStyle(.cyan)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .layoutPriority(1)
                    }

                    Text(dive.siteName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? .cyan : .primary)
                        .lineLimit(1)
                }

                HStack(spacing: 5) {
                    if !dive.location.isEmpty && dive.location != "Inconnu" && dive.location != String(localized: "Unknown") {
                        if let country = dive.siteCountry, !country.isEmpty {
                            Text("\(dive.location), \(country)")
                                .lineLimit(1)
                        } else {
                            Text(dive.location)
                                .lineLimit(1)
                        }
                    } else if let country = dive.siteCountry, !country.isEmpty {
                        Text(country)
                            .lineLimit(1)
                    }
                    Text("•")
                    Text(dive.timestamp.formatted(date: .abbreviated, time: .shortened))
                    Text("•")
                    Text("\(dive.duration) min")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            // Selection checkmark
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.cyan)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(12)
        .background(
            isSelected
                ? Color.cyan.opacity(0.15)
                : Color.platformSecondaryBackground
        )
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.cyan : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                toggleSelection(dive)
            }
        }
    }

    // MARK: - Merge Slot Card

    private func mergeSlotCard(number: String, dive: Dive?, placeholder: LocalizedStringKey) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(dive != nil ? Color.cyan.opacity(0.15) : Color.secondary.opacity(0.1))
                    .frame(width: 36, height: 36)
                if dive != nil {
                    Text(number)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.cyan)
                } else {
                    Text(number)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            if let dive = dive {
                Text(dive.siteName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(dive.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(placeholder)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(
            dive != nil
                ? Color.cyan.opacity(0.15)
                : Color.platformSecondaryBackground
        )
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(dive != nil ? Color.cyan : Color.clear, lineWidth: 2)
        )
    }

    private func toggleSelection(_ dive: Dive) {
        if selectedDiveA?.id == dive.id {
            selectedDiveA = nil
        } else if selectedDiveB?.id == dive.id {
            selectedDiveB = nil
        } else if selectedDiveA == nil {
            selectedDiveA = dive
        } else if selectedDiveB == nil {
            selectedDiveB = dive
        } else {
            // Both slots full — replace the second selection
            selectedDiveB = dive
        }
    }
}
