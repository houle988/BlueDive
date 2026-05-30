import SwiftUI
import SwiftData

struct MarineLifeView: View {
    @Query(sort: \Dive.timestamp, order: .reverse) private var allDives: [Dive]
    @Query(sort: \Gear.name) private var allGear: [Gear]
    @Query(sort: \Certification.issueDate, order: .reverse) private var allCertifications: [Certification]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""

    @State private var appeared = false
    @State private var statsReady = false

    // Cached aggregates
    @State private var cachedSpecies: [SpeciesAggregate] = []
    @State private var cachedTotalSpecies: Int = 0
    @State private var cachedTotalSightings: Int = 0
    @State private var cachedDivesWithLife: Int = 0

    @State private var searchText: String = ""
    @State private var selectedSpecies: SpeciesAggregate? = nil

    struct SpeciesAggregate: Identifiable, Hashable {
        let id: String           // canonical name (lowercased) used for grouping
        let name: String         // display name (most common casing seen)
        let totalCount: Int      // sum of MarineSight.count
        let diveCount: Int       // number of distinct dives where seen
        let lastSeen: Date?
        let diveIDs: Set<UUID>
    }

    private var uniqueDivers: [String] { DiverFilter.uniqueDivers(in: allDives, gear: allGear, certifications: allCertifications) }
    private var filteredDives: [Dive] { DiverFilter.apply(selectedDiver, to: allDives) }
    private var totalSightingsCount: Int {
        allDives.reduce(0) { partial, dive in
            partial + (dive.seenFish?.reduce(0) { $0 + max($1.count, 1) } ?? 0)
        }
    }

    private var filteredSpecies: [SpeciesAggregate] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return cachedSpecies }
        return cachedSpecies.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private func computeStats(_ dives: [Dive]) async {
        var byKey: [String: (name: String, total: Int, dives: Set<UUID>, last: Date?, casings: [String: Int])] = [:]
        var totalSightings = 0
        var divesWithLife = 0
        let yieldInterval = 100

        for (idx, dive) in dives.enumerated() {
            guard let fish = dive.seenFish, !fish.isEmpty else { continue }
            divesWithLife += 1
            for entry in fish {
                let trimmedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty else { continue }
                let key = trimmedName.lowercased()
                let count = max(entry.count, 1)
                totalSightings += count
                if var existing = byKey[key] {
                    existing.total += count
                    existing.dives.insert(dive.id)
                    if let prev = existing.last {
                        existing.last = max(prev, dive.timestamp)
                    } else {
                        existing.last = dive.timestamp
                    }
                    let newCount = existing.casings[trimmedName, default: 0] + 1
                    existing.casings[trimmedName] = newCount
                    // Keep most-frequent casing as display name
                    if newCount > (existing.casings[existing.name] ?? 0) {
                        existing.name = trimmedName
                    }
                    byKey[key] = existing
                } else {
                    byKey[key] = (
                        name: trimmedName,
                        total: count,
                        dives: [dive.id],
                        last: dive.timestamp,
                        casings: [trimmedName: 1]
                    )
                }
            }
            if idx % yieldInterval == yieldInterval - 1 {
                await Task.yield()
                if Task.isCancelled { return }
            }
        }

        let aggregates: [SpeciesAggregate] = byKey.map { key, value in
            SpeciesAggregate(
                id: key,
                name: value.name,
                totalCount: value.total,
                diveCount: value.dives.count,
                lastSeen: value.last,
                diveIDs: value.dives
            )
        }
        .sorted {
            if $0.diveCount != $1.diveCount { return $0.diveCount > $1.diveCount }
            if $0.totalCount != $1.totalCount { return $0.totalCount > $1.totalCount }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if Task.isCancelled { return }

        cachedSpecies = aggregates
        cachedTotalSpecies = aggregates.count
        cachedTotalSightings = totalSightings
        cachedDivesWithLife = divesWithLife
        statsReady = true
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if !allDives.isEmpty && !selectedDiver.isEmpty && filteredDives.isEmpty {
                    NoEntriesForDiverView(
                        title: "No Dives for Diver",
                        description: "No dives were found for the selected diver."
                    )
                } else if !statsReady {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            heroStatsRow
                                .opacity(appeared ? 1.0 : 0.0)
                                .offset(y: appeared ? 0 : 20)

                            speciesListSection
                                .opacity(appeared ? 1.0 : 0.0)
                                .offset(y: appeared ? 0 : 20)
                        }
                        .padding(.bottom, 30)
                    }
                }
            }
            .navigationTitle("Marine Life")
            #if os(macOS)
            .frame(minWidth: 600, idealWidth: 750, maxWidth: 1000, minHeight: 500, idealHeight: 700, maxHeight: 900)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.cyan)
                }
                DiverFilterToolbar(uniqueDivers: uniqueDivers, selectedDiver: $selectedDiver)
            }
            .background(Color.platformBackground.ignoresSafeArea())
            .task(id: "\(allDives.count):\(totalSightingsCount):\(selectedDiver)") {
                statsReady = false
                appeared = false
                await computeStats(filteredDives)
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.6)) {
                    appeared = true
                }
            }
            .diverFilterReset(uniqueDivers: uniqueDivers, selectedDiver: $selectedDiver)
            .sheet(item: $selectedSpecies) { species in
                SpeciesDivesSheet(
                    speciesName: species.name,
                    dives: filteredDives.filter { species.diveIDs.contains($0.id) }
                )
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Hero Stats Row

    private var heroStatsRow: some View {
        HStack(spacing: 12) {
            StatisticsHeroCard(
                value: "\(cachedTotalSpecies)",
                label: "Species",
                icon: "fish.fill",
                color: .orange
            )
            StatisticsHeroCard(
                value: "\(cachedTotalSightings)",
                label: "Sightings",
                icon: "eye.fill",
                color: .cyan
            )
            StatisticsHeroCard(
                value: "\(cachedDivesWithLife)",
                label: "Dives",
                icon: "figure.open.water.swim",
                color: .green
            )
        }
        .padding(.horizontal)
    }

    // MARK: - Species List

    private var speciesListSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "list.bullet")
                    .foregroundStyle(.cyan)
                Text("All Species")
                    .font(.headline)
                Spacer()
                if !cachedSpecies.isEmpty {
                    Text(verbatim: "\(filteredSpecies.count)/\(cachedSpecies.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)

            if cachedSpecies.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "fish")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No marine life recorded")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    TextField(
                        NSLocalizedString(
                            "Search marine life…",
                            bundle: Bundle.forAppLanguage(),
                            comment: "Placeholder for marine life search field"
                        ),
                        text: $searchText
                    )
                    .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            withAnimation { searchText = "" }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.platformBackground)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 1))

                if filteredSpecies.isEmpty {
                    Text("No matches")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(filteredSpecies.enumerated()), id: \.element.id) { index, species in
                            Button { selectedSpecies = species } label: {
                                speciesRow(index: index, species: species)
                            }
                            .buttonStyle(.plain)

                            if index < filteredSpecies.count - 1 {
                                Divider()
                                    .background(Color.primary.opacity(0.08))
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.platformSecondaryBackground)
        )
        .padding(.horizontal)
    }

    @ViewBuilder
    private func speciesRow(index: Int, species: SpeciesAggregate) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        index == 0
                            ? LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: [.white.opacity(0.15), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 32, height: 32)
                Image(systemName: "fish.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(index == 0 ? .primary : .secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(species.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(verbatim: species.diveCount == 1
                        ? NSLocalizedString("1 dive", bundle: .forAppLanguage(), comment: "Single dive count")
                        : String(format: NSLocalizedString("%lld dives", bundle: .forAppLanguage(), comment: "Multiple dives count"), species.diveCount))
                    if species.totalCount != species.diveCount {
                        Text(verbatim: "·")
                        Text(verbatim: String(format: NSLocalizedString("%lld seen", bundle: .forAppLanguage(), comment: "Total sightings of a species"), species.totalCount))
                    }
                    if let last = species.lastSeen {
                        Text(verbatim: "·")
                        Text(last, format: .dateTime.month(.abbreviated).year().locale(locale))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            Text(verbatim: "\(species.diveCount)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.orange.opacity(0.15)))

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Species Dives Sheet

struct SpeciesDivesSheet: View {
    let speciesName: String
    let dives: [Dive]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var prefs = UserPreferences.shared

    private var sortedDives: [Dive] { dives.sorted { $0.timestamp > $1.timestamp } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(sortedDives) { dive in
                        NavigationLink(destination: DiveDetailView(dive: dive, sortedDives: sortedDives)) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(dive.timestamp, format: .dateTime.day().month().year().hour().minute().locale(locale))
                                        .font(.subheadline.weight(.semibold))
                                    if !dive.siteName.isEmpty {
                                        Text(dive.siteName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(verbatim: "\(dive.displayMaxDepth.formatted(.number.precision(.fractionLength(1)).locale(locale))) \(prefs.depthUnit.symbol)")
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(.cyan)
                                    Text(dive.formattedDuration)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.platformSecondaryBackground.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle(speciesName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            .frame(minWidth: 450, idealWidth: 550, maxWidth: 750, minHeight: 400, idealHeight: 500, maxHeight: 700)
            #endif
            .background(Color.platformBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.cyan)
                }
            }
        }
    }
}

#Preview {
    MarineLifeView()
        .modelContainer(for: Dive.self, inMemory: true)
}
