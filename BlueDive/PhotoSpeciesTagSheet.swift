import SwiftUI
import SwiftData

/// Tags species on one photo by hand: shows the species already linked to it (removable),
/// and adds catalogue species — or a new one — from a searchable list. Changes apply at once.
struct PhotoSpeciesTagSheet: View {
    @Bindable var photo: DivePhoto
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(DiveStore.self) private var store
    @Query(sort: \Species.commonName) private var catalogue: [Species]
    @State private var search = ""
    /// Also add a sighting of the species to the photo's dive (when it does not list it yet).
    @State private var addToDive = true
    /// Built once when the catalogue changes, so typing never scans the whole catalogue.
    @State private var nameIndex = SpeciesNameIndex()
    /// Search results and whether the search matches a catalogue name, once per keystroke.
    @State private var candidates: [Species] = []
    @State private var searchMatchesCatalogue = false

    private var tagged: [Species] {
        (photo.species ?? []).sorted { $0.commonName.localizedCaseInsensitiveCompare($1.commonName) == .orderedAscending }
    }

    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Catalogue species not on the photo yet, matching the search.
    private func updateCandidates() {
        candidates = nameIndex.species(containing: trimmedSearch,
                                       excluding: Set(tagged.map(\.persistentModelID)))
        searchMatchesCatalogue = nameIndex.species(named: trimmedSearch) != nil
    }

    var body: some View {
        NavigationStack {
            groupedList {
                Section {
                    if tagged.isEmpty {
                        Text("No species on this photo yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(tagged) { species in
                            HStack(spacing: 12) {
                                speciesLabel(species)
                                Spacer()
                                Button {
                                    untag(species)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .red)
                                        .font(.title3)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(verbatim: String(format: NSLocalizedString("Remove %@ from this photo", bundle: .forAppLanguage(), value: "Remove %@ from this photo", comment: "Accessibility label: removes a species tag from a photo; %@ is the species name"), species.displayName)))
                            }
                        }
                    }
                } header: {
                    Text("On This Photo")
                } footer: {
                    Text("Removing a species from the photo does not remove it from the dive's marine life.")
                }

                Section {
                    Toggle(isOn: $addToDive) {
                        Text("Also add the species to this photo’s dive")
                    }
                    .fullWidthSwitch()
                }

                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        formTextField("Search species", text: $search)
                            .autocorrectionDisabled()
                        if !search.isEmpty {
                            Button {
                                search = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .clearButtonTapTarget()
                                    .accessibilityLabel(Text("Clear"))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !trimmedSearch.isEmpty, !searchMatchesCatalogue {
                        Button {
                            createAndTag(named: trimmedSearch)
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
                            tag(species)
                        } label: {
                            HStack(spacing: 12) {
                                speciesLabel(species)
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .listRowButton()
                    }
                } header: {
                    Text("Add a Species")
                }
            }
            .task(id: catalogue.count) {
                nameIndex = SpeciesNameIndex(catalogue: catalogue)
                updateCandidates()
            }
            .onChange(of: search) { updateCandidates() }
            .onChange(of: photo.species?.count ?? 0) { updateCandidates() }
            .navigationTitle(Text("Species on This Photo"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func speciesLabel(_ species: Species) -> some View {
        HStack(spacing: 12) {
            SpeciesImageView(species: species, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: species.displayName)
                    .foregroundStyle(.primary)
                if let scientific = species.scientificName, !scientific.isEmpty {
                    Text(verbatim: scientific)
                        .font(.caption)
                        .italic()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func tag(_ species: Species) {
        var list = photo.species ?? []
        if !list.contains(where: { $0.persistentModelID == species.persistentModelID }) {
            list.append(species)
            photo.species = list
        }
        var changedDive: Dive?
        if addToDive, let dive = photo.dive,
           SpeciesPhotoMatcher.recordSighting(of: species, on: dive, in: modelContext) {
            changedDive = dive
        }
        try? modelContext.save()
        if let changedDive { store.commit(changedDive, affects: .rowBadges) }
        search = ""
    }

    private func createAndTag(named name: String) {
        // A new species also takes the earlier sightings recorded under that name.
        let species = SpeciesCatalog.findOrCreateForSighting(named: name, in: modelContext)
        tag(species)
    }

    private func untag(_ species: Species) {
        var list = photo.species ?? []
        list.removeAll { $0.persistentModelID == species.persistentModelID }
        photo.species = list
        try? modelContext.save()
    }
}
