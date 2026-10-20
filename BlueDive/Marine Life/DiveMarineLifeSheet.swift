import SwiftUI
import SwiftData

// MARK: - Dive Marine Life Sheet

/// The marine life of one dive, chosen from the species catalogue: the dive's sightings (with
/// their quantity, removable) and a searchable list of catalogue species — or a new one — each
/// added with one tap. The sheet stays open, so several critters are logged in one go; every
/// change applies at once. A new sighting is always a catalogue species (a new name creates
/// the species, details completed later from its page); a sighting not in the catalogue
/// (imported, or recorded before the catalogue) keeps its recorded name and can be linked to a
/// species (`LinkSightingSheet`).
struct DiveMarineLifeSheet: View {
    @Bindable var dive: Dive
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(DiveStore.self) private var store
    @Query(sort: \Species.commonName) private var catalogue: [Species]
    @State private var search = ""
    /// Built once when the catalogue changes, so typing never scans the whole catalogue.
    @State private var nameIndex = SpeciesNameIndex()
    /// Search results and whether the search matches a catalogue name, once per keystroke.
    @State private var candidates: [Species] = []
    @State private var searchMatchesCatalogue = false
    /// Species of the most recent dives, offered while the search is empty.
    @State private var recentlySeen: [Species] = []
    @State private var fishToDelete: MarineSight?
    @State private var showDeleteAlert = false
    @State private var fishToLink: MarineSight?

    /// Most recent dives whose species are offered, and how many species at most.
    private static let recentDiveCount = 10
    private static let recentSpeciesLimit = 8

    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var sightings: [MarineSight] { dive.seenFish ?? [] }

    /// The species a sighting is linked to, unless its species was deleted on another device
    /// and not merged yet (its attributes cannot be read).
    private func linkedSpecies(of fish: MarineSight) -> Species? {
        guard let species = fish.species, !species.isDeleted, species.modelContext != nil else { return nil }
        return species
    }

    /// The species already on the dive, left out of the search results and suggestions.
    private var speciesOnDive: Set<PersistentIdentifier> {
        Set(sightings.compactMap { linkedSpecies(of: $0)?.persistentModelID })
    }

    private var shownRecentlySeen: [Species] {
        let onDive = speciesOnDive
        return recentlySeen.filter { !onDive.contains($0.persistentModelID) }
    }

    private func updateCandidates() {
        guard !trimmedSearch.isEmpty else {
            candidates = []
            searchMatchesCatalogue = false
            return
        }
        candidates = nameIndex.species(containing: trimmedSearch, excluding: speciesOnDive)
        searchMatchesCatalogue = nameIndex.species(named: trimmedSearch) != nil
    }

    /// The catalogue species of the most recent dives (by date, this dive left out), most
    /// recent first. Reads the sightings of those few dives only, never the whole logbook.
    private func updateRecentlySeen() {
        let recentIDs = store.cachedSummaries
            .filter { $0.id != dive.id }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(Self.recentDiveCount)
            .map(\.id)
        var seen = Set<PersistentIdentifier>()
        var result: [Species] = []
        for id in recentIDs {
            guard let recentDive = store.diveByID[id], !recentDive.isDeleted, recentDive.modelContext != nil else { continue }
            for sight in recentDive.seenFish ?? [] {
                guard let species = linkedSpecies(of: sight), seen.insert(species.persistentModelID).inserted else { continue }
                result.append(species)
            }
        }
        recentlySeen = Array(result.prefix(Self.recentSpeciesLimit))
    }

    var body: some View {
        NavigationStack {
            groupedList {
                Section {
                    if sightings.isEmpty {
                        Text("No fish saved.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sightings) { fish in
                            sightingRow(fish)
                        }
                    }
                } header: {
                    Text("On This Dive")
                }

                Section {
                    SpeciesSearchField(text: $search)
                    if !trimmedSearch.isEmpty, !searchMatchesCatalogue {
                        Button {
                            createAndAdd(named: trimmedSearch)
                        } label: {
                            Label {
                                Text(verbatim: String(format: NSLocalizedString("Add “%@” to the catalogue", bundle: .forAppLanguage(), value: "Add “%@” to the catalogue", comment: "Creates a new catalogue species with the searched name and tags it on the photo"), trimmedSearch))
                            } icon: {
                                Image(systemName: "plus.circle")
                            }
                        }
                        .listRowButton()
                    }
                    ForEach(candidates) { species in
                        addRow(species)
                    }
                } header: {
                    Text("Add a Species")
                }

                if trimmedSearch.isEmpty, !shownRecentlySeen.isEmpty {
                    Section {
                        ForEach(shownRecentlySeen) { species in
                            addRow(species)
                        }
                    } header: {
                        Text("Recently Seen")
                    }
                }
            }
            .task(id: catalogue.count) {
                nameIndex = SpeciesNameIndex(catalogue: catalogue)
                updateCandidates()
            }
            .task { updateRecentlySeen() }
            .onChange(of: search) { updateCandidates() }
            .onChange(of: speciesOnDive) { updateCandidates() }
            .navigationTitle(Text("Marine Life Seen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Remove Marine Life", isPresented: $showDeleteAlert, presenting: fishToDelete) { fish in
                Button("Remove", role: .destructive) { remove(fish) }
                Button("Cancel", role: .cancel) { }
            } message: { fish in
                Text("Remove \(fish.displayName) from this dive?")
            }
            .sheet(item: $fishToLink) { fish in
                LinkSightingSheet(fish: fish)
                    .standardSheetPresentation()
            }
        }
    }

    /// A sighting of the dive: the species (or, not in the catalogue, its recorded name), which
    /// opens the link sheet — to change the species of a wrong pick, or to link the sighting —
    /// its quantity menu and its remove button.
    private func sightingRow(_ fish: MarineSight) -> some View {
        HStack(spacing: 12) {
            Button {
                fishToLink = fish
            } label: {
                Group {
                    if let species = linkedSpecies(of: fish) {
                        SpeciesRowLabel(species: species)
                    } else {
                        SpeciesRowLabel(recordedName: fish.name)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(linkedSpecies(of: fish) != nil ? Text("Change Species") : Text("Link to Species"))
            Spacer()
            SightingQuantityMenu(quantity: SightingQuantity.from(count: fish.count)) { quantity in
                setQuantity(quantity, of: fish)
            }
            .accessibilityLabel(Text("Quantity"))
            Button {
                fishToDelete = fish
                showDeleteAlert = true
            } label: {
                Image(systemName: "minus.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: String(format: NSLocalizedString("Remove %@", bundle: .forAppLanguage(), comment: "Accessibility label for a button that removes a filter chip, naming the specific value it removes"), fish.displayName)))
        }
    }

    /// A catalogue species that a tap adds to the dive.
    private func addRow(_ species: Species) -> some View {
        Button {
            add(species)
        } label: {
            HStack(spacing: 12) {
                SpeciesRowLabel(species: species)
                Spacer()
                Image(systemName: "plus.circle")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .listRowButton()
    }

    // MARK: Changes (saved at once)

    /// Adds a sighting of `species` (quantity Single), or links a sighting of the dive not in
    /// the catalogue that was recorded under one of its names (`recordSighting`).
    private func add(_ species: Species) {
        if SpeciesPhotoMatcher.recordSighting(of: species, on: dive, in: modelContext) {
            try? modelContext.save()
            store.commit(dive, affects: .rowBadges)
        }
        search = ""
    }

    /// Creates the species under the searched name (with the earlier sightings recorded under
    /// it) and adds it to the dive; looked up on iNaturalist when allowed.
    private func createAndAdd(named name: String) {
        let species = SpeciesCatalog.findOrCreateForSighting(named: name, in: modelContext)
        _ = SpeciesPhotoMatcher.recordSighting(of: species, on: dive, in: modelContext)
        try? modelContext.save()
        store.commit(dive, affects: .rowBadges)
        INaturalistUpdater.updateInBackground([species], in: modelContext)
        search = ""
    }

    private func setQuantity(_ quantity: SightingQuantity, of fish: MarineSight) {
        guard fish.setQuantity(quantity) else { return }
        try? modelContext.save()
        store.commit(dive, affects: .rowBadges)
    }

    private func remove(_ fish: MarineSight) {
        modelContext.delete(fish)
        try? modelContext.save()
        store.commit(dive, affects: .rowBadges)
    }
}

// MARK: - Link Sighting Sheet

/// Links a sighting to a catalogue species — or a new one — found by searching, the search
/// starting from the name it was recorded under; the sighting keeps that name, and its
/// quantity can be changed here.
///
/// A sighting not in the catalogue is linked together with the other sightings recorded under
/// the same name (`SpeciesCatalog.linkSightings`, as Marine Life's page of such sightings does),
/// after a confirmation when there are others; the species keeps that name as another name,
/// so later imports and photo keywords written that way find it. A linked sighting changes
/// species alone (a wrong pick corrected).
struct LinkSightingSheet: View {
    @Bindable var fish: MarineSight
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(DiveStore.self) private var store
    @Query(sort: \Species.commonName) private var catalogue: [Species]
    @State private var search: String
    /// Built once when the catalogue changes, so typing never scans the whole catalogue.
    @State private var nameIndex = SpeciesNameIndex()
    @State private var candidates: [Species] = []
    @State private var searchMatchesCatalogue = false

    /// What a pick links the sighting to: a catalogue species, or one created under a name.
    private enum Target {
        case existing(Species)
        case new(name: String)
    }
    /// A pick waiting for confirmation: other sightings share the recorded name.
    @State private var pendingTarget: Target?

    init(fish: MarineSight) {
        self.fish = fish
        _search = State(initialValue: fish.name)
    }

    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The species the sighting is linked to (changing species), unless it was deleted on
    /// another device and not merged yet; nil for a sighting not in the catalogue.
    private var currentSpecies: Species? {
        guard let species = fish.species, !species.isDeleted, species.modelContext != nil else { return nil }
        return species
    }

    private func updateCandidates() {
        guard !trimmedSearch.isEmpty else {
            candidates = []
            searchMatchesCatalogue = false
            return
        }
        candidates = nameIndex.species(containing: trimmedSearch,
                                       excluding: Set([currentSpecies?.persistentModelID].compactMap { $0 }))
        searchMatchesCatalogue = nameIndex.species(named: trimmedSearch) != nil
    }

    var body: some View {
        NavigationStack {
            groupedList {
                Section {
                    if let currentSpecies {
                        SpeciesRowLabel(species: currentSpecies)
                    } else {
                        SpeciesRowLabel(recordedName: fish.name)
                    }
                    HStack {
                        Text("Quantity")
                        Spacer()
                        SightingQuantityMenu(quantity: SightingQuantity.from(count: fish.count)) { quantity in
                            guard fish.setQuantity(quantity) else { return }
                            save()
                        }
                        .accessibilityLabel(Text("Quantity"))
                    }
                } header: {
                    if currentSpecies != nil {
                        Text("Current Species")
                    } else {
                        Text("Recorded As")
                    }
                } footer: {
                    Text("Linking keeps the name the sighting was recorded under.")
                }

                Section {
                    SpeciesSearchField(text: $search)
                    if !trimmedSearch.isEmpty, !searchMatchesCatalogue {
                        Button {
                            choose(.new(name: trimmedSearch))
                        } label: {
                            Label {
                                Text(verbatim: String(format: NSLocalizedString("Add “%@” to the catalogue", bundle: .forAppLanguage(), value: "Add “%@” to the catalogue", comment: "Creates a new catalogue species with the searched name and tags it on the photo"), trimmedSearch))
                            } icon: {
                                Image(systemName: "plus.circle")
                            }
                        }
                        .listRowButton()
                    }
                    ForEach(candidates) { species in
                        Button {
                            choose(.existing(species))
                        } label: {
                            HStack(spacing: 12) {
                                SpeciesRowLabel(species: species)
                                Spacer()
                                Image(systemName: "link")
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .listRowButton()
                    }
                } header: {
                    Text("Link to Species")
                }
            }
            .task(id: catalogue.count) {
                nameIndex = SpeciesNameIndex(catalogue: catalogue)
                updateCandidates()
            }
            .onChange(of: search) { updateCandidates() }
            .navigationTitle(currentSpecies != nil ? Text("Change Species") : Text("Link to Species"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { dismiss() }
                }
            }
            .alert("Link Sightings", isPresented: Binding(
                get: { pendingTarget != nil },
                set: { if !$0 { pendingTarget = nil } }
            ), presenting: pendingTarget) { target in
                Button("Link") { apply(target) }
                Button("Cancel", role: .cancel) { }
            } message: { target in
                Text(verbatim: String(format: NSLocalizedString("Link the sightings named “%@” to %@?", bundle: .forAppLanguage(), value: "Link the sightings named “%@” to %@?", comment: "Link sightings confirmation: recorded name, species name"), fish.name, targetName(target)))
            }
        }
    }

    private func targetName(_ target: Target) -> String {
        switch target {
        case .existing(let species): return species.displayName
        case .new(let name): return name
        }
    }

    private func save() {
        try? modelContext.save()
        if let dive = fish.dive {
            store.commit(dive, affects: .rowBadges)
        } else {
            // An orphaned sighting (should not happen): a full rebuild covers it.
            store.commitListRebuild()
        }
    }

    /// Links at once, or asks first when other sightings not in the catalogue share the name
    /// (they are linked too).
    private func choose(_ target: Target) {
        let others = currentSpecies == nil
            ? SpeciesCatalog.unlinkedSightingCount(named: fish.name, in: modelContext) - 1
            : 0
        if others > 0 {
            pendingTarget = target
        } else {
            apply(target)
        }
    }

    private func apply(_ target: Target) {
        let wasInCatalogue = currentSpecies != nil
        let species: Species
        var created = false
        switch target {
        case .existing(let existing):
            species = existing
        case .new(let name):
            // With the earlier sightings recorded under that name.
            species = SpeciesCatalog.findOrCreateForSighting(named: name, in: modelContext)
            created = true
        }
        fish.species = species
        if !wasInCatalogue {
            // The other sightings of the recorded name follow, and the species keeps the name.
            SpeciesCatalog.linkSightings(named: fish.name, to: species, in: modelContext)
        }
        save()
        // A new species is looked up on iNaturalist when allowed.
        if created { INaturalistUpdater.updateInBackground([species], in: modelContext) }
        dismiss()
    }
}
