import Foundation
import SwiftData

// MARK: - Species Category

/// Species categories. The default set is stored as stable keys (`"bd.category.fish"`) and
/// displayed in the app language; a category the user types (or an imported one, e.g.
/// MacDive's "Crustacé") is stored and displayed verbatim.
enum SpeciesCategory: String, CaseIterable, Identifiable {
    case fish, sharkRay, crustacean, mollusc, cnidarian, echinoderm
    case reptile, mammal, plantAlgae, sponge, worm, other

    var id: String { rawValue }

    /// Prefix that marks a default category in `Species.category`; never typed by a user.
    static let keyPrefix = "bd.category."

    var storedValue: String { Self.keyPrefix + rawValue }

    init?(storedValue: String) {
        guard storedValue.hasPrefix(Self.keyPrefix) else { return nil }
        self.init(rawValue: String(storedValue.dropFirst(Self.keyPrefix.count)))
    }

    var localizedName: String {
        let bundle = Bundle.forAppLanguage()
        switch self {
        case .fish:       return NSLocalizedString("Fish", bundle: bundle, value: "Fish", comment: "Species category")
        case .sharkRay:   return NSLocalizedString("Shark & Ray", bundle: bundle, value: "Shark & Ray", comment: "Species category")
        case .crustacean: return NSLocalizedString("Crustacean", bundle: bundle, value: "Crustacean", comment: "Species category")
        case .mollusc:    return NSLocalizedString("Mollusc", bundle: bundle, value: "Mollusc", comment: "Species category (snails, nudibranchs, octopus, etc.)")
        case .cnidarian:  return NSLocalizedString("Cnidarian (Coral, Anemone, Jellyfish)", bundle: bundle, value: "Cnidarian (Coral, Anemone, Jellyfish)", comment: "Species category")
        case .echinoderm: return NSLocalizedString("Echinoderm", bundle: bundle, value: "Echinoderm", comment: "Species category (sea stars, urchins, sea cucumbers)")
        case .reptile:    return NSLocalizedString("Reptile", bundle: bundle, value: "Reptile", comment: "Species category (sea turtles, sea snakes)")
        case .mammal:     return NSLocalizedString("Marine Mammal", bundle: bundle, value: "Marine Mammal", comment: "Species category")
        case .plantAlgae: return NSLocalizedString("Plant & Algae", bundle: bundle, value: "Plant & Algae", comment: "Species category")
        case .sponge:     return NSLocalizedString("Sponge", bundle: bundle, value: "Sponge", comment: "Species category")
        case .worm:       return NSLocalizedString("Worm", bundle: bundle, value: "Worm", comment: "Species category")
        case .other:      return NSLocalizedString("Other", bundle: bundle, value: "Other", comment: "Species category")
        }
    }

    /// Display name of a stored category: translated for a default key, verbatim otherwise.
    static func displayName(_ stored: String?) -> String? {
        guard let stored, !stored.isEmpty else { return nil }
        return SpeciesCategory(storedValue: stored)?.localizedName ?? stored
    }

    /// Custom (non-default) categories used in the catalogue, sorted.
    static func customCategories(in catalogue: [Species]) -> [String] {
        let custom = catalogue.compactMap(\.category).filter { !$0.isEmpty && SpeciesCategory(storedValue: $0) == nil }
        return Array(Set(custom)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

// MARK: - Species Size

extension Species {
    /// Unit a new size starts in: the profile's (imperial → in, metric → cm), as for dives.
    @MainActor static var defaultSizeUnit: String {
        UserPreferences.shared.depthUnit == .feet ? "in" : "cm"
    }

    /// A stored size in the display unit (`displayInInches`: in, else cm), converted from the
    /// unit it was entered in; the stored value itself is never changed. A size of unknown
    /// unit (nil) is returned as stored, with no unit.
    static func displaySize(_ size: Double, storedUnit: String?, displayInInches: Bool) -> (value: Double, unit: String?) {
        switch (storedUnit, displayInInches) {
        case ("cm", true): return (size / 2.54, "in")
        case ("in", false): return (size * 2.54, "cm")
        case ("cm", false), ("in", true): return (size, storedUnit)
        default: return (size, nil)
        }
    }
}

// MARK: - Species Metrics

/// Statistics of a species over the dives it was seen on, calculated when displayed.
struct SpeciesMetrics {
    /// Number of dives logging the species.
    var sightings = 0
    /// Mean of the dives' average depth, in the display unit; nil when no dive has one.
    var averageDepth: Double?
    /// Mean of the dives' water temperature, in the display unit; nil when no dive has one.
    var averageTemperature: Double?
    var lastSeen: Date?

    /// `dives`: the distinct dives the species was seen on. Each value is converted from
    /// its dive's stored unit (Dive display helpers). A dive without an average depth
    /// (stored 0) or a water temperature is left out of that mean, never estimated.
    @MainActor
    init(dives: [Dive]) {
        sightings = dives.count
        let depths = dives.filter { $0.averageDepth > 0 }.map(\.displayAverageDepth)
        averageDepth = depths.isEmpty ? nil : depths.reduce(0, +) / Double(depths.count)
        let temperatures = dives.compactMap(\.displayWaterTemperature)
        averageTemperature = temperatures.isEmpty ? nil : temperatures.reduce(0, +) / Double(temperatures.count)
        lastSeen = dives.map(\.timestamp).max()
    }

    init() {}
}

// MARK: - Name Index

/// Every name a catalogue species is known by, normalised once: its common name, scientific
/// name, other names (including former common names kept after a rename or merge), and its
/// iNaturalist common names in every language fetched — the name shown in the app language
/// (`displayName`) is one of them. The one lookup for names everywhere (sighting entry,
/// photo tagging, pickers, photo proposals, Marine Life grouping), so a name the app shows is
/// always recognised. Name lookups while typing are a dictionary lookup, not a scan.
@MainActor
struct SpeciesNameIndex {
    private var byKey: [String: Species] = [:]
    /// Every species known by each normalised name (several species can share one).
    private var allByKey: [String: [Species]] = [:]
    /// Each species with its normalised names, for "contains" searches, in catalogue order.
    private var entries: [(species: Species, names: [String])] = []

    init(catalogue: [Species] = []) {
        // Lowest priority first, so a common name wins over a scientific, other or
        // iNaturalist name.
        var altNamesByID: [PersistentIdentifier: [String]] = [:]
        for species in catalogue {
            // Read once: both lists are decoded on every access.
            let inatNames = species.inatCommonNames.values.filter { !$0.isEmpty }
            let altNames = (species.altNames ?? []) + inatNames
            altNamesByID[species.persistentModelID] = altNames
            for name in inatNames { byKey[SpeciesCatalog.key(name)] = species }
        }
        for species in catalogue {
            for name in species.altNames ?? [] { byKey[SpeciesCatalog.key(name)] = species }
        }
        for species in catalogue {
            if let scientific = species.scientificName { byKey[SpeciesCatalog.key(scientific)] = species }
        }
        for species in catalogue {
            byKey[SpeciesCatalog.key(species.commonName)] = species
            let names = [species.commonName, species.scientificName].compactMap { $0 }
                + (altNamesByID[species.persistentModelID] ?? [])
            for key in Set(names.map(SpeciesCatalog.key)) where !key.isEmpty {
                allByKey[key, default: []].append(species)
            }
            entries.append((species, names.map { $0.lowercased() }))
        }
        byKey[""] = nil
    }

    /// The species known by `name`, ignoring case.
    func species(named name: String) -> Species? {
        byKey[SpeciesCatalog.key(name)]
    }

    /// A species other than `excluding` known by `name` (common, scientific or other name).
    func otherSpecies(named name: String, excluding: Species?) -> Species? {
        (allByKey[SpeciesCatalog.key(name)] ?? []).first { $0.persistentModelID != excluding?.persistentModelID }
    }

    /// Species with a name containing `text` (ignoring case), up to `limit`.
    func species(containing text: String, excluding: Species?, limit: Int) -> [Species] {
        species(containing: text, excluding: Set([excluding?.persistentModelID].compactMap { $0 }), limit: limit)
    }

    /// Species not in `excluding` with a name containing `text` (ignoring case), in catalogue
    /// order; every such species when `text` is empty.
    func species(containing text: String, excluding: Set<PersistentIdentifier>, limit: Int = .max) -> [Species] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result: [Species] = []
        for entry in entries where !excluding.contains(entry.species.persistentModelID) {
            if needle.isEmpty || entry.names.contains(where: { $0.contains(needle) }) {
                result.append(entry.species)
                if result.count == limit { break }
            }
        }
        return result
    }
}

// MARK: - Species Catalog

/// Catalogue operations. A sighting's `name` is never rewritten: linking only sets
/// `MarineSight.species`. Dive list badges show sighting names, so none of these changes
/// needs a DiveStore commit.
@MainActor
enum SpeciesCatalog {

    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The species known by `name` (any of its names, see `SpeciesNameIndex`), ignoring case.
    /// Builds an index of `catalogue`: for a single lookup; code that looks up many names
    /// builds one `SpeciesNameIndex` and reuses it.
    static func find(named name: String, in catalogue: [Species]) -> Species? {
        SpeciesNameIndex(catalogue: catalogue).species(named: name)
    }

    /// The catalogue species for `name`, created (and inserted) when there is none.
    static func findOrCreate(named name: String, in context: ModelContext) -> Species {
        let catalogue = (try? context.fetch(FetchDescriptor<Species>())) ?? []
        if let existing = find(named: name, in: catalogue) { return existing }
        let species = Species(commonName: name.trimmingCharacters(in: .whitespacesAndNewlines))
        context.insert(species)
        return species
    }

    /// The catalogue species for a sighting typed as `name`. When the name is new, the species
    /// is created and the unlinked sightings already recorded under that name (ignoring case)
    /// are linked to it as well, so the name never shows both as a species and as "not in the
    /// catalogue". The sightings keep their names. Not saved.
    static func findOrCreateForSighting(named name: String, in context: ModelContext) -> Species {
        let catalogue = (try? context.fetch(FetchDescriptor<Species>())) ?? []
        if let existing = SpeciesNameIndex(catalogue: catalogue).species(named: name) { return existing }
        let species = Species(commonName: name.trimmingCharacters(in: .whitespacesAndNewlines))
        context.insert(species)
        linkUnlinkedSightings(named: [name], to: species, in: context)
        return species
    }

    /// Links the sightings not yet in the catalogue that were recorded under any of `names`
    /// (ignoring case) to `species`, for a species just created under those names. The
    /// sightings keep their names. Not saved.
    static func linkUnlinkedSightings(named names: [String], to species: Species, in context: ModelContext) {
        var seen = Set<String>()
        for name in names where seen.insert(key(name)).inserted {
            for sight in unlinkedSightings(named: name, in: context) { sight.species = species }
        }
    }

    /// The sightings not linked to any species that were recorded under one of `species`'
    /// names (common, scientific, other or iNaturalist names): Marine Life counts them with
    /// the species, so its page lists their dives too.
    static func unlinkedSightings(of species: Species, in context: ModelContext) -> [MarineSight] {
        let names = [species.commonName, species.scientificName ?? ""] + (species.altNames ?? [])
            + species.inatCommonNames.values
        var seen = Set<String>()
        return names.filter { seen.insert(key($0)).inserted }.flatMap { unlinkedSightings(named: $0, in: context) }
    }

    /// The sighting names that find `species`' dives in the dive list's marine life filter:
    /// the names of its sightings, of the unlinked sightings recorded under one of its names
    /// (counted on its page), and its common name. The filter compares names ignoring case
    /// only, so sighting names are passed as recorded.
    static func diveFilterNames(for species: [Species], in context: ModelContext) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for item in species {
            let sightingNames = (item.sightings ?? []).map(\.name) + unlinkedSightings(of: item, in: context).map(\.name)
            for name in sightingNames + [item.commonName.trimmingCharacters(in: .whitespacesAndNewlines)]
            where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert(name.lowercased()).inserted {
                names.append(name)
            }
        }
        return names
    }

    /// The unlinked sightings recorded under `name`, ignoring case and surrounding spaces.
    /// The store returns only the rows containing the name, so a large log is not read whole.
    private static func unlinkedSightings(named name: String, in context: ModelContext) -> [MarineSight] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let target = key(trimmed)
        let descriptor = FetchDescriptor<MarineSight>(predicate: #Predicate {
            $0.species == nil && $0.name.localizedStandardContains(trimmed)
        })
        return ((try? context.fetch(descriptor)) ?? []).filter { key($0.name) == target }
    }

    // MARK: Build from sightings

    struct BuildPlan {
        /// Names that will become new species (most frequent spelling of each).
        var newSpeciesNames: [String] = []
        /// Sightings that will be linked (to new or existing species).
        var sightingsToLink = 0
    }

    /// What `buildFromSightings` would do, without changing anything.
    static func planBuild(in context: ModelContext) -> BuildPlan {
        let groups = unlinkedSightingGroups(in: context)
        let index = SpeciesNameIndex(catalogue: (try? context.fetch(FetchDescriptor<Species>())) ?? [])
        var plan = BuildPlan()
        for group in groups {
            plan.sightingsToLink += group.sights.count
            if index.species(named: group.name) == nil { plan.newSpeciesNames.append(group.name) }
        }
        plan.newSpeciesNames.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return plan
    }

    /// Links every sighting not yet in the catalogue to the species of the same name,
    /// creating the species that do not exist (common name = the most frequent spelling).
    /// Returns (species created, sightings linked).
    @discardableResult
    static func buildFromSightings(in context: ModelContext) -> (created: Int, linked: Int) {
        let groups = unlinkedSightingGroups(in: context)
        // Each group has its own name (groups are keyed by name), so a species created here
        // never matches another group: the index of the existing catalogue is enough.
        let index = SpeciesNameIndex(catalogue: (try? context.fetch(FetchDescriptor<Species>())) ?? [])
        var created = 0, linked = 0
        for group in groups {
            let species: Species
            if let existing = index.species(named: group.name) {
                species = existing
            } else {
                species = Species(commonName: group.name)
                context.insert(species)
                created += 1
            }
            for sight in group.sights {
                sight.species = species
                linked += 1
            }
        }
        try? context.save()
        return (created, linked)
    }

    /// Links the unlinked sightings named `name` (ignoring case) to `species`. The sightings
    /// keep their name; when it is not already one of the species' names, the species keeps
    /// it as another name, so future sightings typed the same way are recognised.
    static func linkSightings(named name: String, to species: Species, in context: ModelContext) {
        for sight in unlinkedSightings(named: name, in: context) { sight.species = species }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, find(named: trimmed, in: [species]) == nil {
            species.altNames = (species.altNames ?? []) + [trimmed]
        }
        try? context.save()
    }

    private struct SightingGroup {
        var name: String
        var sights: [MarineSight]
    }

    /// Unlinked sightings grouped by name (ignoring case); each group is named by its most
    /// frequent spelling.
    private static func unlinkedSightingGroups(in context: ModelContext) -> [SightingGroup] {
        let descriptor = FetchDescriptor<MarineSight>(predicate: #Predicate { $0.species == nil })
        let sights = (try? context.fetch(descriptor)) ?? []
        var byKey: [String: (sights: [MarineSight], spellings: [String: Int])] = [:]
        for sight in sights {
            let trimmed = sight.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            byKey[key(trimmed), default: ([], [:])].sights.append(sight)
            byKey[key(trimmed), default: ([], [:])].spellings[trimmed, default: 0] += 1
        }
        return byKey.values.map { value in
            let name = value.spellings.max { a, b in
                a.value == b.value ? a.key > b.key : a.value < b.value
            }?.key ?? ""
            return SightingGroup(name: name, sights: value.sights)
        }
    }

    // MARK: Merge and delete

    /// Moves `source`'s sightings and photos to `target`, keeps `source`'s names as other
    /// names of `target`, fills `target`'s empty fields from `source`, then deletes `source`.
    static func merge(_ source: Species, into target: Species, in context: ModelContext) {
        guard source.persistentModelID != target.persistentModelID else { return }
        for sight in source.sightings ?? [] { sight.species = target }
        for photo in source.photos ?? [] {
            var species = photo.species ?? []
            species.removeAll { $0.persistentModelID == source.persistentModelID }
            if !species.contains(where: { $0.persistentModelID == target.persistentModelID }) { species.append(target) }
            photo.species = species
        }
        // `target` takes `source`'s iNaturalist data (taxon, classification, names in other
        // languages, Wikipedia) when it has no taxon of its own and no other scientific name.
        let targetScientific = target.scientificName ?? ""
        let takesINaturalistData = target.inatTaxonID == nil && source.inatTaxonID != nil
            && (targetScientific.isEmpty || key(targetScientific) == key(source.scientificName ?? ""))
        // Every name `source` was known by stays recognised: its common name, other names,
        // iNaturalist names (unless they move with its iNaturalist data), and its scientific
        // name when `target` has another one (an empty one is filled below instead).
        let sourceScientific = (source.scientificName ?? "").isEmpty || targetScientific.isEmpty
            ? [] : [source.scientificName ?? ""]
        var names = target.altNames ?? []
        let sourceINaturalistNames = takesINaturalistData ? [] : source.inatCommonNames.values.filter { !$0.isEmpty }
        let sourceNames = [source.commonName] + (source.altNames ?? []) + sourceScientific
            + sourceINaturalistNames
        for name in sourceNames where !name.isEmpty {
            if key(name) != key(target.commonName), key(name) != key(targetScientific),
               !names.contains(where: { key($0) == key(name) }) {
                names.append(name)
            }
        }
        target.altNames = names.isEmpty ? nil : names
        if target.scientificName?.isEmpty ?? true { target.scientificName = source.scientificName }
        if target.category?.isEmpty ?? true { target.category = source.category }
        if target.averageSize == nil {
            target.averageSize = source.averageSize
            target.averageSizeUnit = source.averageSizeUnit
        }
        if target.notes?.isEmpty ?? true { target.notes = source.notes }
        if takesINaturalistData {
            target.inatTaxonID = source.inatTaxonID
            target.inatCommonNamesData = source.inatCommonNamesData
            target.taxonomyData = source.taxonomyData
            target.wikipediaSummary = source.wikipediaSummary
            target.wikipediaURL = source.wikipediaURL
            target.inatFetchedAt = source.inatFetchedAt
        }
        // The image record moves to the kept species before `source` is deleted (its delete
        // would take the record with it).
        if target.image == nil, let image = source.image {
            source.image = nil
            target.image = image
            image.speciesID = target.id
        }
        context.delete(source)
        try? context.save()
    }

    /// Deletes the species. Its sightings keep their names and stay on their dives; its
    /// photos stay on their dives.
    static func delete(_ species: Species, in context: ModelContext) {
        context.delete(species)
        try? context.save()
    }
}
