import SwiftUI
import SwiftData

struct MarineLifeView: View {
    @Environment(DiveStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""
    @Query(sort: \Species.commonName) private var catalogue: [Species]

    @State private var appeared = false
    @State private var statsReady = false

    // Cached aggregates
    @State private var cachedSpecies: [SpeciesAggregate] = []
    @State private var cachedTotalSpecies: Int = 0
    @State private var cachedTotalSightings: Int = 0
    @State private var cachedDivesWithLife: Int = 0

    @State private var searchText: String = ""
    /// Stored category value to show only ("" = all categories).
    @State private var categoryFilter: String = ""
    /// Shows only the catalogue species not linked to iNaturalist yet.
    @State private var notLinkedFilter = false
    /// iNaturalist taxon to show only, as "rank|name" ("" = all), e.g. "family|Nephropidae".
    @State private var taxonFilter: String = ""
    @State private var showAddSpecies = false
    @State private var buildPlan: SpeciesCatalog.BuildPlan?
    @State private var buildResult: (created: Int, linked: Int)?
    @State private var speciesProposals: [SpeciesPhotoProposal] = []
    @State private var showNoSpeciesInPhotos = false

    /// Bumped after a catalogue action here; with `store.marineLifeVersion` (sightings saved,
    /// full rebuilds) it makes the statistics recompute only when something changed.
    @State private var contentVersion = 0
    /// The statistics' inputs: marineLifeVersion (any sighting saved — a quantity or
    /// species-link edit leaves the dive summaries unchanged — or a full rebuild),
    /// contentVersion (catalogue actions here), the catalogue, the diver, the language.
    private var statsKey: String {
        "\(store.marineLifeVersion):\(contentVersion):\(catalogueHash):\(selectedDiver):\(UserPreferences.shared.languageMode.rawValue):\(UserPreferences.shared.taxonomyNameLanguage)"
    }
    /// The inputs the shown statistics were computed for.
    @State private var computedStatsKey = ""
    /// Built once per statistics pass, not on every redraw.
    @State private var cachedNumberMap: [PersistentIdentifier: Int] = [:]
    @State private var cachedSpeciesByID: [PersistentIdentifier: Species] = [:]
    /// Group names per rank and the categories in use, rebuilt when the catalogue changes
    /// (reading a classification decodes JSON, too costly to repeat on every redraw).
    @State private var cachedTaxonNames: [String: [String]] = [:]
    /// Common name of each group ("Actinopterygii" → "Ray-finned Fishes"), when known.
    @State private var cachedGroupCommonNames: [String: String] = [:]
    @State private var cachedUsedCategories: [String] = []
    /// Catalogue species in the selected taxon (empty when no taxon is selected).
    @State private var cachedTaxonSpeciesIDs: Set<PersistentIdentifier> = []

    struct SpeciesAggregate: Identifiable, Hashable {
        /// "s:<species id>" for a catalogue species, "n:<lowercased name>" for sightings not
        /// yet in the catalogue.
        let id: String
        let name: String         // common name, or the most common spelling of the sightings
        let scientificName: String?
        let category: String?
        let speciesID: PersistentIdentifier?
        let entryCount: Int      // total number of sighting records
        let diveCount: Int       // number of distinct dives where seen
        let lastSeen: Date?
        let diveIDs: Set<UUID>
        let quantityCounts: [SightingQuantity: Int]  // times each range was recorded
        /// The species' other names (other, iNaturalist and stored common names) and the names
        /// its sightings were recorded with, for the search.
        let otherNames: [String]
        /// A catalogue species linked to an iNaturalist taxon.
        let isLinked: Bool
    }

    private var filteredDives: [Dive] { DiverFilter.apply(selectedDiver, to: store.dives) }

    /// Changes when a catalogue species is added, removed or renamed, gets other names (its
    /// save links the sightings that use them), or gets iNaturalist
    /// data (a lookup sets `inatFetchedAt`; fetching names in another language changes the
    /// size of the stored names and classification).
    private var catalogueHash: Int {
        catalogue.reduce(0) { h, species in
            (h &* 31) &+ species.id.hashValue &+ species.commonName.hashValue
                &+ (species.scientificName?.hashValue ?? 0) &+ (species.category?.hashValue ?? 0)
                &+ (species.altNames?.hashValue ?? 0)
                &+ (species.inatFetchedAt?.hashValue ?? 0)
                &+ (species.inatCommonNamesData?.count ?? 0) &* 7 &+ (species.taxonomyData?.count ?? 0)
        }
    }

    /// Ranks offered in the taxonomy filter.
    private static let filterRanks = ["class", "order", "family", "genus"]

    private var taxonFilterParts: (rank: String, name: String)? {
        let parts = taxonFilter.split(separator: "|", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    /// Catalogue species in the selected taxon.
    private var speciesInTaxon: [Species] {
        cachedTaxonSpeciesIDs.compactMap { liveSpecies($0) }
    }

    /// The cached species with `id`, unless it was deleted since the cache was built (here,
    /// in its page, or on another device): reading a deleted SwiftData object is unsafe, and
    /// the caches are rebuilt only when the statistics task runs again.
    private func liveSpecies(_ id: PersistentIdentifier) -> Species? {
        guard let species = cachedSpeciesByID[id], !species.isDeleted, species.modelContext != nil else { return nil }
        return species
    }

    /// Names at `rank` used by the catalogue's iNaturalist classifications.
    private func taxonNames(rank: String) -> [String] {
        cachedTaxonNames[rank] ?? []
    }

    /// Rebuilds the taxonomy and category caches from the catalogue.
    private func rebuildCatalogueCaches() {
        var names: [String: Set<String>] = [:]
        var commonNames: [String: String] = [:]
        var byID: [PersistentIdentifier: Species] = [:]
        for species in catalogue {
            byID[species.persistentModelID] = species
            for rank in species.taxonomy where Self.filterRanks.contains(rank.rank) {
                names[rank.rank, default: []].insert(rank.name)
                if commonNames[rank.name] == nil, let common = rank.commonName, !common.isEmpty {
                    commonNames[rank.name] = common
                }
            }
        }
        cachedSpeciesByID = byID
        cachedTaxonNames = names.mapValues { $0.sorted() }
        cachedGroupCommonNames = commonNames
        let used = Set(catalogue.compactMap(\.category).filter { !$0.isEmpty })
        cachedUsedCategories = SpeciesCategory.allCases.map(\.storedValue).filter { used.contains($0) }
            + SpeciesCategory.customCategories(in: catalogue)
        rebuildTaxonSelection()
    }

    private func pruneDeletedSpecies() {
        let live = Set(catalogue.map(\.persistentModelID))
        cachedSpeciesByID = cachedSpeciesByID.filter { live.contains($0.key) }
        cachedTaxonSpeciesIDs.formIntersection(live)
        cachedSpecies.removeAll { aggregate in aggregate.speciesID.map { !live.contains($0) } ?? false }
    }

    private func rebuildTaxonSelection() {
        guard let (rank, name) = taxonFilterParts else { cachedTaxonSpeciesIDs = []; return }
        cachedTaxonSpeciesIDs = Set(catalogue.filter { $0.taxonName(rank: rank) == name }.map(\.persistentModelID))
    }

    /// The "not linked" filter applies only while iNaturalist lookups are on (its menu item is
    /// hidden otherwise).
    private var notLinkedFilterActive: Bool { notLinkedFilter && UserPreferences.shared.fetchTaxonomyOnline }

    /// Read once per body pass (`speciesListSection`): it searches every name of every row.
    private var filteredSpecies: [SpeciesAggregate] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        let taxonIDs = taxonFilterParts == nil ? nil : cachedTaxonSpeciesIDs
        // Categories whose localized name matches, looked up once per category, not per row.
        // (Every category of the rows, custom ones included.)
        let matchingCategories = trimmed.isEmpty ? [] : Set(cachedSpecies.compactMap(\.category)).filter {
            SpeciesCategory.displayName($0)?.localizedCaseInsensitiveContains(trimmed) ?? false
        }
        return cachedSpecies.filter { aggregate in
            if !categoryFilter.isEmpty, aggregate.category != categoryFilter { return false }
            if notLinkedFilterActive, aggregate.speciesID == nil || aggregate.isLinked { return false }
            if let taxonIDs {
                guard let id = aggregate.speciesID, taxonIDs.contains(id) else { return false }
            }
            guard !trimmed.isEmpty else { return true }
            return aggregate.name.localizedCaseInsensitiveContains(trimmed)
                || (aggregate.scientificName?.localizedCaseInsensitiveContains(trimmed) ?? false)
                || aggregate.otherNames.contains { $0.localizedCaseInsensitiveContains(trimmed) }
                || aggregate.category.map { matchingCategories.contains($0) } ?? false
        }
    }

    /// Categories used in the catalogue, for the filter menu.
    private var usedCategories: [String] { cachedUsedCategories }

    /// One sighting, copied out of SwiftData before any suspension: a sighting or dive deleted
    /// by an iCloud merge during a yield is never read afterwards.
    private struct SightingValue {
        let diveID: UUID
        let divePID: PersistentIdentifier
        let timestamp: Date
        let name: String
        let quantity: SightingQuantity
        /// The catalogue species: linked, or known by the sighting's name (a sighting that
        /// arrived unlinked — an XML import, an older app version — under a species' name is
        /// counted with that species, not listed apart as "not in the catalogue").
        let speciesPID: PersistentIdentifier?
    }

    private func computeStats(_ dives: [Dive]) async {
        typealias Accumulator = (name: String, scientific: String?, category: String?, speciesID: PersistentIdentifier?,
                                 entryCount: Int, dives: Set<UUID>, last: Date?, casings: [String: Int],
                                 qtyCounts: [SightingQuantity: Int], otherNames: Set<String>)

        // Dive numbers for the pages pushed from here, once per pass.
        let total = store.dives.count
        cachedNumberMap = Dictionary(store.dives.enumerated().map { ($0.element.persistentModelID, total - $0.offset) },
                                     uniquingKeysWith: { first, _ in first })

        // Every sighting in one query, with its dive and species fetched along, read into
        // values in one pass (no suspension while SwiftData objects are read).
        var descriptor = FetchDescriptor<MarineSight>()
        descriptor.relationshipKeyPathsForPrefetching = [\.dive, \.species]
        let sights = (try? modelContext.fetch(descriptor)) ?? []
        let allowed: Set<PersistentIdentifier>? = selectedDiver.isEmpty ? nil : Set(dives.map(\.persistentModelID))
        let nameIndex = SpeciesNameIndex(catalogue: catalogue)
        var values: [SightingValue] = []
        values.reserveCapacity(sights.count)
        for entry in sights {
            guard !entry.isDeleted, let dive = entry.dive, !dive.isDeleted else { continue }
            if let allowed, !allowed.contains(dive.persistentModelID) { continue }
            let trimmedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { continue }
            let species = entry.species.flatMap { $0.isDeleted ? nil : $0 } ?? nameIndex.species(named: trimmedName)
            values.append(SightingValue(diveID: dive.id, divePID: dive.persistentModelID, timestamp: dive.timestamp,
                                        name: trimmedName, quantity: SightingQuantity.from(count: entry.count),
                                        speciesPID: species?.persistentModelID))
        }
        // Display data of each catalogue species, read once (live query results).
        var speciesInfo: [PersistentIdentifier: (id: UUID, name: String, scientific: String?, category: String?,
                                                 otherNames: Set<String>)] = [:]
        var linkedSpecies = Set<PersistentIdentifier>()
        for species in catalogue {
            if species.inatTaxonID != nil { linkedSpecies.insert(species.persistentModelID) }
            let names = Set([species.commonName] + (species.altNames ?? []) + species.inatCommonNames.values.filter { !$0.isEmpty })
            speciesInfo[species.persistentModelID] = (species.id, species.displayName, species.scientificName,
                                                      species.category, names)
        }

        var byKey: [String: Accumulator] = [:]
        var divesWithSightings = Set<PersistentIdentifier>()
        let yieldInterval = 500
        for (idx, value) in values.enumerated() {
            if idx % yieldInterval == yieldInterval - 1 {
                await Task.yield()
                if Task.isCancelled { return }
            }
            if let pid = value.speciesPID, let info = speciesInfo[pid] {
                let key = "s:\(info.id.uuidString)"
                var existing = byKey[key] ?? (info.name, info.scientific, info.category, pid, 0, [], nil, [:], [:], info.otherNames)
                existing.otherNames.insert(value.name)
                existing.entryCount += 1
                existing.qtyCounts[value.quantity, default: 0] += 1
                existing.dives.insert(value.diveID)
                existing.last = max(existing.last ?? value.timestamp, value.timestamp)
                byKey[key] = existing
            } else {
                let key = "n:\(value.name.lowercased())"
                var existing = byKey[key] ?? (value.name, nil, nil, nil, 0, [], nil, [:], [:], [])
                existing.entryCount += 1
                existing.qtyCounts[value.quantity, default: 0] += 1
                existing.dives.insert(value.diveID)
                existing.last = max(existing.last ?? value.timestamp, value.timestamp)
                let newCount = existing.casings[value.name, default: 0] + 1
                existing.casings[value.name] = newCount
                // Keep most-frequent casing as display name
                if newCount > (existing.casings[existing.name] ?? 0) {
                    existing.name = value.name
                }
                byKey[key] = existing
            }
            divesWithSightings.insert(value.divePID)
        }

        // Catalogue species not seen on any dive yet (shown when no diver is selected).
        if selectedDiver.isEmpty {
            for (pid, info) in speciesInfo where byKey["s:\(info.id.uuidString)"] == nil {
                byKey["s:\(info.id.uuidString)"] = (info.name, info.scientific, info.category, pid, 0, [], nil, [:], [:], info.otherNames)
            }
        }

        let aggregates: [SpeciesAggregate] = byKey.map { key, value in
            SpeciesAggregate(
                id: key,
                name: value.name,
                scientificName: value.scientific,
                category: value.category,
                speciesID: value.speciesID,
                entryCount: value.entryCount,
                diveCount: value.dives.count,
                lastSeen: value.last,
                diveIDs: value.dives,
                quantityCounts: value.qtyCounts,
                otherNames: value.otherNames.sorted(),
                isLinked: value.speciesID.map { linkedSpecies.contains($0) } ?? false
            )
        }
        .sorted {
            if $0.diveCount != $1.diveCount { return $0.diveCount > $1.diveCount }
            if $0.entryCount != $1.entryCount { return $0.entryCount > $1.entryCount }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if Task.isCancelled { return }

        cachedSpecies = aggregates
        // Species actually seen: catalogue species never recorded on a dive are listed, not counted.
        cachedTotalSpecies = aggregates.filter { $0.entryCount > 0 }.count
        cachedTotalSightings = values.count
        cachedDivesWithLife = divesWithSightings.count
        statsReady = true
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if !store.dives.isEmpty && !selectedDiver.isEmpty && filteredDives.isEmpty {
                    NoEntriesForDiverView(
                        title: DiverFilter.noDivesTitle(for: selectedDiver),
                        description: DiverFilter.noDivesDescription(for: selectedDiver)
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { dismiss() }
                }
                DiverFilterToolbar(uniqueDivers: store.cachedUniqueDivers, selectedDiver: $selectedDiver)
                ToolbarItem(placement: .sheetPrimaryAction) {
                    Button {
                        showAddSpecies = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Text("Add Species"))
                }
                ToolbarItem(placement: .sheetPrimaryAction) {
                    catalogueMenu
                }
            }
            .background(AppBackground().ignoresSafeArea())
            .onChange(of: taxonFilter) { _, _ in rebuildTaxonSelection() }
            // Species deleted or merged (here or on another device): dropped from the caches
            // at once, before the statistics are recomputed.
            .onChange(of: catalogue.count) { _, _ in pruneDeletedSpecies() }
            .task(id: statsKey) {
                // Back from a pushed page re-runs the task: nothing to do when nothing changed.
                guard statsKey != computedStatsKey else { return }
                let firstPass = !statsReady
                rebuildCatalogueCaches()
                // The list stays on screen (and keeps its scroll position) while it refreshes;
                // only the first pass shows a spinner and fades the list in.
                await computeStats(filteredDives)
                if Task.isCancelled { return }
                computedStatsKey = statsKey
                if firstPass {
                    withAnimation(.easeOut(duration: 0.6)) {
                        appeared = true
                    }
                }
            }
            .diverFilterReset(uniqueDivers: store.cachedUniqueDivers, selectedDiver: $selectedDiver)
            // The row's own data: a page stays filled when the statistics are recomputed while
            // it is open (e.g. its sightings are linked to a new species from a pushed dive).
            .navigationDestination(for: SpeciesAggregate.self) { aggregate in
                destination(for: aggregate)
            }
            .sheet(isPresented: $showAddSpecies) {
                EditSpeciesView(species: nil)
                    .standardSheetPresentation()
            }
            .sheet(isPresented: Binding(
                get: { !speciesProposals.isEmpty },
                set: { if !$0 { speciesProposals = [] } }
            )) {
                SpeciesPhotoReviewSheet(proposals: speciesProposals)
                    .standardSheetPresentation()
            }
            .alert("No New Species Found", isPresented: $showNoSpeciesInPhotos) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("No photo caption or keyword names a species that is not already linked to the photo.")
            }
            .alert("Build Catalogue from Sightings", isPresented: Binding(
                get: { buildPlan != nil },
                set: { if !$0 { buildPlan = nil } }
            ), presenting: buildPlan) { plan in
                if plan.sightingsToLink > 0 {
                    Button("Build") {
                        let result = SpeciesCatalog.buildFromSightings(in: modelContext)
                        buildResult = (result.created, result.linked)
                        contentVersion += 1
                        // Species created under a scientific name are linked to iNaturalist
                        // in the background when lookups are on (one request per second).
                        INaturalistUpdater.updateInBackground(result.newSpecies, in: modelContext)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: { plan in
                if plan.sightingsToLink == 0 {
                    Text("Every sighting is already in the catalogue.")
                } else {
                    Text(verbatim: String(format: NSLocalizedString("%@ sightings will be linked to catalogue species, and %@ new species will be created from their names. Sighting names are not changed.", bundle: .forAppLanguage(), value: "%@ sightings will be linked to catalogue species, and %@ new species will be created from their names. Sighting names are not changed.", comment: "Build catalogue confirmation: sightings to link, species to create (locale-formatted numbers)"), Double(plan.sightingsToLink).localizedString(decimals: 0), Double(plan.newSpeciesNames.count).localizedString(decimals: 0)))
                }
            }
            .alert("Catalogue Built", isPresented: Binding(
                get: { buildResult != nil },
                set: { if !$0 { buildResult = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(verbatim: String(format: NSLocalizedString("Species created: %@. Sightings linked: %@.", bundle: .forAppLanguage(), value: "Species created: %@. Sightings linked: %@.", comment: "Build catalogue result (locale-formatted numbers)"), Double(buildResult?.created ?? 0).localizedString(decimals: 0), Double(buildResult?.linked ?? 0).localizedString(decimals: 0)))
            }
        }
    }

    private var catalogueMenu: some View {
        Menu {
            Button {
                buildPlan = SpeciesCatalog.planBuild(in: modelContext)
            } label: {
                Label("Build Catalogue from Sightings", systemImage: "books.vertical")
            }
            Button {
                let proposals = SpeciesPhotoMatcher.proposals(
                    for: SpeciesPhotoMatcher.photosWithIPTC(in: modelContext), catalogue: catalogue)
                if proposals.isEmpty { showNoSpeciesInPhotos = true } else { speciesProposals = proposals }
            } label: {
                Label("Find Species in Photos", systemImage: "text.viewfinder")
            }
            if Self.filterRanks.contains(where: { !taxonNames(rank: $0).isEmpty }) || !usedCategories.isEmpty
                || UserPreferences.shared.fetchTaxonomyOnline {
                Divider()
            }
            if UserPreferences.shared.fetchTaxonomyOnline {
                Button {
                    notLinkedFilter.toggle()
                } label: {
                    if notLinkedFilter {
                        Label("Not Linked to iNaturalist", systemImage: "checkmark")
                    } else {
                        Text("Not Linked to iNaturalist")
                    }
                }
            }
            if Self.filterRanks.contains(where: { !taxonNames(rank: $0).isEmpty }) {
                // Filter by Group › All Groups / Class › / Order › / Family › / Genus ›
                Menu {
                    Button {
                        taxonFilter = ""
                    } label: {
                        if taxonFilter.isEmpty {
                            Label("All Groups", systemImage: "checkmark")
                        } else {
                            Text("All Groups")
                        }
                    }
                    ForEach(Self.filterRanks, id: \.self) { rank in
                        let names = taxonNames(rank: rank)
                        if !names.isEmpty {
                            Picker(selection: $taxonFilter) {
                                ForEach(names, id: \.self) { name in
                                    Text(verbatim: Species.groupLabel(name: name, commonName: cachedGroupCommonNames[name]))
                                        .tag("\(rank)|\(name)")
                                }
                            } label: {
                                Text(verbatim: INaturalistUpdater.localizedRank(rank))
                            }
                            .pickerStyle(.menu)
                        }
                    }
                } label: {
                    Label("Filter by Group", systemImage: "leaf")
                }
            }
            if !usedCategories.isEmpty {
                Menu {
                    Picker(selection: $categoryFilter) {
                        Text("All Categories").tag("")
                        ForEach(usedCategories, id: \.self) { category in
                            Text(verbatim: SpeciesCategory.displayName(category) ?? category).tag(category)
                        }
                    } label: {
                        Text("Category")
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Filter by Category", systemImage: "square.grid.2x2")
                }
            }
        } label: {
            // Orange while a filter is active, like the app's other filter buttons.
            if categoryFilter.isEmpty && taxonFilter.isEmpty && !notLinkedFilterActive {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.cyan)
            } else {
                Image(systemName: "line.3.horizontal.decrease")
                    .foregroundStyle(.orange)
            }
        }
        .toolbarMenuIndicatorHiddenOnMac()
        .accessibilityLabel(Text("More"))
    }

    // MARK: - Hero Stats Row

    private var heroStatsRow: some View {
        HStack(spacing: 12) {
            StatisticsHeroCard(
                value: Double(cachedTotalSpecies).localizedString(decimals: 0),
                label: "Species",
                icon: "fish.fill",
                color: .orange
            )
            StatisticsHeroCard(
                value: Double(cachedTotalSightings).localizedString(decimals: 0),
                label: "Sightings",
                icon: "eye.fill",
                color: .cyan
            )
            StatisticsHeroCard(
                value: Double(cachedDivesWithLife).localizedString(decimals: 0),
                label: "Dives",
                icon: "figure.open.water.swim",
                color: .green
            )
        }
        .padding(.horizontal)
    }

    // MARK: - Species List

    private var speciesListSection: some View {
        let filteredSpecies = filteredSpecies
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "list.bullet")
                    .foregroundStyle(.cyan)
                    .accessibilityHidden(true)
                Text("All Species")
                    .font(.headline)
                Spacer()
                if !cachedSpecies.isEmpty {
                    Text(verbatim: "\(Double(filteredSpecies.count).localizedString(decimals: 0))/\(Double(cachedSpecies.count).localizedString(decimals: 0))")
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
                        .accessibilityHidden(true)
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
                        .accessibilityHidden(true)
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
                                .clearButtonTapTarget()
                                .accessibilityLabel(Text("Clear"))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.platformBackground)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 1))

                if let (rank, name) = taxonFilterParts {
                    taxonFilterBanner(rank: rank, name: name)
                }

                if filteredSpecies.isEmpty {
                    Text("No matches")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    let rows = filteredSpecies
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, species in
                            // The page is built only when the row is opened.
                            NavigationLink(value: species) {
                                speciesRow(index: index, species: species)
                            }
                            .buttonStyle(.plain)

                            if index < rows.count - 1 {
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

    /// The active taxonomy filter, with the action that filters the dive log to it.
    private func taxonFilterBanner(rank: String, name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "leaf.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(verbatim: String(format: NSLocalizedString("%@: %@", bundle: .forAppLanguage(), value: "%@: %@", comment: "A taxonomic rank and its name, e.g. Family: Nephropidae"), INaturalistUpdater.localizedRank(rank), Species.groupLabel(name: name, commonName: cachedGroupCommonNames[name])))
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button("View Dives") {
                viewDivesInTaxon()
            }
            .font(.caption.weight(.semibold))
            .borderlessButton()
            Button {
                taxonFilter = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .borderlessButton()
            .accessibilityLabel(Text("Clear"))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.1)))
    }

    /// Filters the dive list to dives where a species of the selected taxon was recorded (by
    /// the names its sightings were recorded with, including unlinked ones under its names)
    /// and closes the sheet.
    private func viewDivesInTaxon() {
        let names = SpeciesCatalog.diveFilterNames(for: speciesInTaxon, in: modelContext)
        guard !names.isEmpty else { return }
        store.filterMarineLifeMode = .any
        store.filterMarineLife = names
        dismiss()
    }

    @ViewBuilder
    private func destination(for aggregate: SpeciesAggregate) -> some View {
        if let id = aggregate.speciesID {
            if let species = liveSpecies(id) {
                SpeciesDetailView(species: species, numberMap: cachedNumberMap, closeSheet: { dismiss() })
                    .closeSheetButtonOnMac { dismiss() }
            }
        } else {
            UnlinkedSightingsView(
                name: aggregate.name,
                dives: filteredDives.filter { aggregate.diveIDs.contains($0.id) },
                numberMap: cachedNumberMap,
                closeSheet: { dismiss() },
                onLinked: { contentVersion += 1 }
            )
            .closeSheetButtonOnMac { dismiss() }
        }
    }

    // Builds "3× Abundant · 1× Few" with locale-formatted numbers, highest range first.
    private func quantitySummary(for species: SpeciesAggregate) -> String {
        SightingQuantity.allCases.reversed()
            .compactMap { q -> String? in
                guard let n = species.quantityCounts[q], n > 0 else { return nil }
                return "\(Double(n).localizedString(decimals: 0))× \(q.label)"
            }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private func speciesRow(index: Int, species: SpeciesAggregate) -> some View {
        HStack(spacing: 14) {
            if let id = species.speciesID, let catalogued = liveSpecies(id),
               catalogued.hasFeaturedImage {
                SpeciesImageView(species: catalogued, size: 32)
            } else {
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
                        .accessibilityHidden(true)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: species.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let scientific = species.scientificName, !scientific.isEmpty {
                    Text(verbatim: scientific)
                        .font(.caption2)
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if species.speciesID == nil {
                    Text("Not in the catalogue")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(verbatim: species.diveCount == 1
                        ? NSLocalizedString("1 dive", bundle: .forAppLanguage(), value: "1 dive", comment: "Single dive count")
                        : String(format: NSLocalizedString("%@ dives", bundle: .forAppLanguage(), value: "%@ dives", comment: "Plural dive count goal label"), Double(species.diveCount).localizedString(decimals: 0)))
                    if let last = species.lastSeen {
                        Text(verbatim: "·")
                        Text(last, format: .dateTime.month(.abbreviated).year().locale(locale))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                let summary = quantitySummary(for: species)
                if !summary.isEmpty {
                    Text(verbatim: summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(verbatim: Double(species.diveCount).localizedString(decimals: 0))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.orange.opacity(0.15)))

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Unlinked Sightings

/// Sightings of a name not yet in the catalogue: the dives they were recorded on, and the
/// action to add the name to the catalogue (which links these sightings without renaming them).
struct UnlinkedSightingsView: View {
    let name: String
    let dives: [Dive]
    let numberMap: [PersistentIdentifier: Int]
    let closeSheet: () -> Void
    /// Called after the sightings were linked to a species (the list must refresh).
    var onLinked: () -> Void = {}
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var prefs = UserPreferences.shared
    @State private var showLinkSheet = false

    private var sortedDives: [Dive] { dives.sorted { $0.timestamp > $1.timestamp } }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("These sightings are not in the species catalogue yet. Add the name to the catalogue to give it a profile, photos and statistics; the sightings keep the name they were recorded with.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    let species = SpeciesCatalog.findOrCreate(named: name, in: modelContext)
                    SpeciesCatalog.linkSightings(named: name, to: species, in: modelContext)
                    onLinked()
                    dismiss()
                } label: {
                    Label("Add to Catalogue", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button {
                    showLinkSheet = true
                } label: {
                    Label("Link to an Existing Species…", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                ForEach(sortedDives) { dive in
                    NavigationLink {
                        DiveDetailView(dive: dive, sortedDives: sortedDives, diveNumber: numberMap[dive.persistentModelID] ?? 0)
                            .closeSheetButtonOnMac { closeSheet() }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(dive.timestamp, format: .dateTime.day().month().year().hour().minute().locale(locale))
                                    .font(.subheadline.weight(.semibold))
                                if !dive.siteName.isEmpty {
                                    Text(verbatim: dive.siteName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(verbatim: "\(dive.displayMaxDepth.localizedString(decimals: 1, minDecimals: 1)) \(prefs.depthUnit.symbol)")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.cyan)
                                Text(dive.formattedDuration)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.platformSecondaryBackground.opacity(0.6)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(AppBackground().ignoresSafeArea())
        .navigationTitle(Text(verbatim: name))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLinkSheet) {
            LinkSightingsToSpeciesSheet(name: name) {
                onLinked()
                dismiss()
            }
            .standardSheetPresentation()
        }
    }
}

#Preview {
    MarineLifeView()
        .modelContainer(for: Dive.self, inMemory: true)
}
