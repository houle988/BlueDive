import Foundation
import ImageIO
import SwiftData

// MARK: - SpeciesXMLImport

/// Adds the species of a parsed `SpeciesXMLParser` file to the catalogue. A species already in
/// the catalogue — same id, or one of its names (common, scientific, other or iNaturalist)
/// known to the catalogue, ignoring case — is skipped and never overwritten. Within the file,
/// every entry with an id is its own species, even when it shares a name with another (a
/// catalogue can hold such species, e.g. created on two devices before they synced): a later
/// entry is skipped only for the id of an earlier one, or, without an id, for one of its names.
@MainActor
enum SpeciesXMLImport {

    typealias ParsedSpecies = SpeciesXMLParser.ParsedSpecies

    struct Plan {
        var new: [ParsedSpecies] = []
        var duplicates: [ParsedSpecies] = []
    }

    /// Splits `parsed` into the species to add and the duplicates, against the catalogue as
    /// saved in `context` now.
    static func plan(_ parsed: [ParsedSpecies], in context: ModelContext) -> Plan {
        let catalogue = (try? context.fetch(FetchDescriptor<Species>())) ?? []
        let index = SpeciesNameIndex(catalogue: catalogue)
        var knownIDs = Set(catalogue.map(\.id))
        var fileKeys = Set<String>()
        var plan = Plan()
        for item in parsed {
            let keys = Set(item.names.map(SpeciesCatalog.key)).subtracting([""])
            let inCatalogue = item.names.contains { index.otherSpecies(named: $0, excluding: nil) != nil }
            let earlierInFile = item.id.map { knownIDs.contains($0) } ?? keys.contains { fileKeys.contains($0) }
            let isDuplicate = inCatalogue || earlierInFile
            if isDuplicate {
                plan.duplicates.append(item)
            } else {
                plan.new.append(item)
                if let id = item.id { knownIDs.insert(id) }
                fileKeys.formUnion(keys)
            }
        }
        return plan
    }

    /// Inserts the species of `parsed` that are not duplicates (decided again now: the
    /// catalogue may have changed since the preview, e.g. through iCloud), with their values as
    /// in the file, and links to each the sightings not yet in the catalogue recorded under one
    /// of its names (the sightings keep their names). Images larger than a thumbnail and without
    /// one get one (`addMissingThumbnails`). Saved; when the save fails, every change is rolled
    /// back and the error is thrown.
    /// Returns the species created and the number of sightings linked.
    static func commit(_ parsed: [ParsedSpecies], in context: ModelContext) async throws -> (created: [Species], linked: Int) {
        let created = plan(parsed, in: context).new.map { (species: makeSpecies(from: $0, in: context), names: $0.names) }
        await addMissingThumbnails(to: created.map(\.species))
        // Last before the save, with no suspension after its final fetch: the sightings are
        // linked as the main context has them then (one deleted meanwhile is not linked).
        let linked = await linkUnlinkedSightings(to: created, in: context)
        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return (created.map(\.species), linked)
    }

    /// A new species with the values of `item` as in the file (its id and creation date
    /// included), inserted in `context`. Not saved.
    static func makeSpecies(from item: ParsedSpecies, in context: ModelContext) -> Species {
        let species = Species(commonName: item.commonName)
        if let id = item.id { species.id = id }
        if let createdAt = item.createdAt { species.createdAt = createdAt }
        species.scientificName = item.scientificName
        species.category = item.category
        species.averageSize = item.averageSize
        species.averageSizeUnit = item.averageSizeUnit
        species.notes = item.notes
        species.altNames = item.altNames
        species.inatTaxonID = item.inatTaxonID
        species.inatCommonNamesData = item.inatCommonNamesData
        species.taxonomyData = item.taxonomyData
        species.wikipediaSummary = item.wikipediaSummary
        species.wikipediaURL = item.wikipediaURL
        species.inatFetchedAt = item.inatFetchedAt
        context.insert(species)
        if let imageData = item.imageData {
            species.setFeaturedImage(imageData, thumbnail: item.thumbnailData, attribution: item.imageAttribution)
        }
        return species
    }

    /// Gives the featured image of each of `species` that has none (an imported image: MacDive
    /// critters have no thumbnail, and a BlueDive file has one only when it was smaller than its
    /// image) the thumbnail a picked image gets in the species form — 512 pixels on the longest
    /// side, kept only when smaller than the image. An image already no larger than that gets
    /// none (it would only be re-encoded; the image is shown instead). Made off the main actor
    /// (about 7–20 ms per image); the image itself is never changed. Not saved.
    static func addMissingThumbnails(to species: [Species]) async {
        let jobs: [(index: Int, data: Data)] = species.enumerated().compactMap { index, item in
            guard let image = item.image, image.thumbnailData == nil, let data = image.imageData else { return nil }
            return (index, data)
        }
        guard !jobs.isEmpty else { return }
        let thumbnails = await Task.detached(priority: .userInitiated) {
            jobs.compactMap { job -> (index: Int, data: Data)? in
                guard let source = CGImageSourceCreateWithData(job.data as CFData, nil),
                      longestSide(of: source).map({ $0 > PhotoMetadataReader.thumbnailMaxPixelSize }) ?? true,
                      let thumbnail = PhotoMetadataReader.thumbnailJPEG(
                          of: source, maxPixelSize: PhotoMetadataReader.thumbnailMaxPixelSize, quality: 0.8),
                      thumbnail.count < job.data.count else { return nil }
                return (job.index, thumbnail)
            }
        }.value
        for thumbnail in thumbnails {
            // The species and its image record were created by this import, before the wait.
            guard let image = species[thumbnail.index].image, image.thumbnailData == nil else { continue }
            image.thumbnailData = thumbnail.data
        }
    }

    /// The longest side of the image in pixels, read from its properties (not decoded); nil
    /// when unknown.
    private nonisolated static func longestSide(of source: CGImageSource) -> Int? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
            as? [CFString: Any] ?? [:]
        let side = max(properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
        return side > 0 ? side : nil
    }

    /// Links the sightings not in the catalogue to the species just created that have their
    /// name (ignoring case), in order: a name taken by an earlier species is not linked again,
    /// as `SpeciesCatalog.unlinkedSightings(of:)` would find it. The sightings keep their names.
    ///
    /// Scales with the matches, not the logbook: the unlinked sightings' names are read off the
    /// main actor, from the store (`UnlinkedSightingReader`); the main actor then fetches only
    /// the unlinked sightings recorded under a matching name, one query per 200 names (measured:
    /// 50,000 unlinked, 5,000 matching — 95 ms on the main actor, against 233 ms for one fetch of
    /// them all, and 1 s fetching the matches by identifier). A sighting not saved yet is not
    /// seen by the reader — callers link after the sightings they import are saved (dive import)
    /// or when the sightings are all saved (catalogue import).
    /// Not saved. Returns the number of sightings linked.
    static func linkUnlinkedSightings(to created: [(species: Species, names: [String])], in context: ModelContext) async -> Int {
        guard !created.isEmpty else { return 0 }
        var indexByKey: [String: Int] = [:]
        for (index, entry) in created.enumerated() {
            for key in Set(entry.names.map(SpeciesCatalog.key)) where !key.isEmpty && indexByKey[key] == nil {
                indexByKey[key] = index
            }
        }
        let container = context.container
        let keys = Set(indexByKey.keys)
        let names = await Task.detached(priority: .userInitiated) {
            UnlinkedSightingReader.matchingNames(in: container, keys: keys)
        }.value
        guard !names.isEmpty else { return 0 }
        var linked = 0
        for start in stride(from: 0, to: names.count, by: 200) {
            // Between queries only, so the last fetch is followed by no suspension.
            if start > 0 { await Task.yield() }
            let chunk = Array(names[start..<min(start + 200, names.count)])
            let sights = (try? context.fetch(FetchDescriptor<MarineSight>(
                predicate: #Predicate { $0.species == nil && chunk.contains($0.name) }))) ?? []
            for sight in sights where sight.species == nil {
                guard let index = indexByKey[SpeciesCatalog.key(sight.name)] else { continue }
                let species = created[index].species
                guard !species.isDeleted else { continue }
                sight.species = species
                linked += 1
            }
        }
        return linked
    }
}

// MARK: - Unlinked sighting reader

/// Reads the sightings not in the catalogue off the main actor, through its own context, names
/// only — a store-backed reader (see `SightingReader`): a whole-logbook scan never runs on the
/// main actor or over main-context objects.
nonisolated enum UnlinkedSightingReader {
    static let author = "BlueDive.sightingLink"

    /// The distinct names, as recorded (case and spaces kept, for an exact query), of the
    /// unlinked sightings whose name ignoring case (`SpeciesCatalog.key`) is in `keys`.
    static func matchingNames(in container: ModelContainer, keys: Set<String>) -> [String] {
        let context = ModelContext(container)
        context.author = author
        var query = FetchDescriptor<MarineSight>(predicate: #Predicate { $0.species == nil })
        query.propertiesToFetch = [\.name]
        let sights = (try? context.fetch(query)) ?? []
        return Array(Set(sights.map(\.name).filter { keys.contains(SpeciesCatalog.key($0)) }))
    }
}

// MARK: - Species carried by a dive file

/// Resolves the species a BlueDive dive file carries for its sightings (`<speciesCatalogue>`)
/// during a dive import, with the catalogue import's rules: the species with the same id, else
/// the one known by one of its names (common, scientific, other or iNaturalist), else a new
/// species created once from the file's values (BlueDive's own complete records) — unless
/// creation is off (Import Species turned off), when the sighting stays out of the catalogue.
/// An existing species is never changed. Other formats carry no species: their sightings are
/// linked by name to existing species only (`existingSpecies(named:)`).
@MainActor
final class SpeciesImportResolver {
    private let context: ModelContext
    private let allowsCreation: Bool
    private let index: SpeciesNameIndex
    private var byID: [UUID: Species]
    /// Species created without an id in the file (hand-made files), by common name.
    private var createdByKey: [String: Species] = [:]
    /// The result for each file species already resolved, by its id: a species carried by many
    /// sightings is resolved once (its names, iNaturalist names included, are not decoded and
    /// looked up again for each sighting). `unresolvedIDs`: no species (creation off).
    private var resolvedByFileID: [UUID: Species] = [:]
    private var unresolvedIDs: Set<UUID> = []
    /// The species created by this import, with their names in the file.
    private(set) var created: [(species: Species, names: [String])] = []

    /// Indexes the catalogue as saved in `context` now. With `allowsCreation` off, a species the
    /// catalogue does not have is not created.
    init(context: ModelContext, allowsCreation: Bool = true) {
        self.context = context
        self.allowsCreation = allowsCreation
        let catalogue = (try? context.fetch(FetchDescriptor<Species>())) ?? []
        index = SpeciesNameIndex(catalogue: catalogue)
        byID = Dictionary(catalogue.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The catalogue species for a sighting carrying `item` (created when the catalogue has
    /// none and creation is on; nil otherwise). Not saved.
    func species(for item: SpeciesXMLImport.ParsedSpecies) -> Species? {
        if let id = item.id {
            if unresolvedIDs.contains(id) { return nil }
            // Re-checked: deleted on another device since it was resolved, it is resolved again.
            if let known = resolvedByFileID[id], isAlive(known) { return known }
        }
        let result = resolve(item)
        if let id = item.id {
            if let result { resolvedByFileID[id] = result } else { unresolvedIDs.insert(id) }
        }
        return result
    }

    private func resolve(_ item: SpeciesXMLImport.ParsedSpecies) -> Species? {
        if let id = item.id, let existing = byID[id], isAlive(existing) { return existing }
        for name in item.names {
            if let existing = index.otherSpecies(named: name, excluding: nil), isAlive(existing) { return existing }
        }
        guard allowsCreation else { return nil }
        let key = SpeciesCatalog.key(item.commonName)
        if item.id == nil, let existing = createdByKey[key] { return existing }
        let species = SpeciesXMLImport.makeSpecies(from: item, in: context)
        if let id = item.id { byID[id] = species } else { createdByKey[key] = species }
        created.append((species, item.names))
        return species
    }

    /// The existing species known by `name`, ignoring case (a sighting without species data).
    func existingSpecies(named name: String) -> Species? {
        index.species(named: name).flatMap { isAlive($0) ? $0 : nil }
    }

    /// Links the sightings not in the catalogue to the species this import created that have
    /// their name (store read off the main actor; call after the import is saved). Not saved.
    /// Returns the number of sightings linked.
    func linkUnlinkedSightings() async -> Int {
        await SpeciesXMLImport.linkUnlinkedSightings(to: created, in: context)
    }

    /// Not deleted, here or on another device, since the catalogue was indexed.
    private func isAlive(_ species: Species) -> Bool {
        !species.isDeleted && species.modelContext != nil
    }
}
