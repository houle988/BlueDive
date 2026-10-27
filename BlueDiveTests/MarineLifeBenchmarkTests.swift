import Foundation
import SwiftData
import Testing
@testable import BlueDive

/// Times the work one Marine Life statistics pass does (`MarineLifeView.computeStats` and the
/// catalogue caches) on a large logbook: 10 000 dives, 50 000 sightings, 1 200 species with
/// iNaturalist names and classifications. Prints the timings; asserts nothing about speed.
@MainActor
struct MarineLifeBenchmarkTests {

    private static let diveCount = 10_000
    private static let sightingsPerDive = 5
    private static let speciesCount = 1_200

    private func makeLogbook() throws -> ModelContainer {
        let container = try ModelContainer(for: Schema(BlueDiveApp.appModelTypes),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                                                              cloudKitDatabase: .none))
        let context = container.mainContext
        let ranks = ["kingdom", "phylum", "class", "order", "family", "genus", "species"]
        var catalogue: [Species] = []
        for index in 0..<Self.speciesCount {
            let species = Species(commonName: "Species \(index)")
            species.scientificName = "Genus\(index % 300) species\(index)"
            species.category = ["fish", "crustacean", "mollusc", "coral"][index % 4]
            species.altNames = ["Other name \(index)"]
            species.inatTaxonID = index
            species.inatCommonNamesData = try JSONEncoder().encode(
                ["en": "Species \(index)", "fr": "Espèce \(index)", "de": "Art \(index)", "nl": "Soort \(index)"])
            species.taxonomyData = try JSONEncoder().encode(ranks.enumerated().map { rankIndex, rank in
                INaturalistService.Rank(rank: rank, name: "\(rank.capitalized)\(index % (10 * (rankIndex + 1)))",
                                        id: rankIndex, commonName: "Group \(rankIndex)")
            })
            context.insert(species)
            catalogue.append(species)
        }
        let start = Date(timeIntervalSinceReferenceDate: 700_000_000)
        for diveIndex in 0..<Self.diveCount {
            let dive = Dive(timestamp: start.addingTimeInterval(Double(diveIndex) * 86_400))
            dive.setDuration(minutes: 50)
            context.insert(dive)
            for sightIndex in 0..<Self.sightingsPerDive {
                let speciesIndex = (diveIndex * 7 + sightIndex * 13) % Self.speciesCount
                let sight = MarineSight(name: "Species \(speciesIndex)", count: sightIndex + 1)
                context.insert(sight)
                sight.dive = dive
                // Four in five linked to the catalogue; the rest found by name.
                if sightIndex != 4 { sight.species = catalogue[speciesIndex] }
            }
        }
        try context.save()
        return container
    }

    private func measure(_ label: String, _ work: () -> Void) -> Duration {
        let elapsed = ContinuousClock().measure(work)
        print("⏱ MarineLife benchmark — \(label): \(elapsed.formatted(.units(allowed: [.milliseconds], width: .narrow)))")
        return elapsed
    }

    /// Off by default (about 8 s): remove `.disabled` to measure.
    @Test(.disabled("Benchmark: enable to measure Marine Life on a large logbook"))
    func statisticsPassOnALargeLogbook() throws {
        let container = try makeLogbook()
        let context = container.mainContext
        let catalogue = try context.fetch(FetchDescriptor<Species>(sortBy: [SortDescriptor(\.commonName)]))

        // The view body's catalogue fingerprint (computed on every redraw).
        _ = measure("catalogue fingerprint") {
            _ = catalogue.reduce(0) { h, species in
                (h &* 31) &+ species.id.hashValue &+ species.commonName.hashValue
                    &+ (species.scientificName?.hashValue ?? 0) &+ (species.category?.hashValue ?? 0)
                    &+ (species.altNames?.hashValue ?? 0)
                    &+ (species.inatFetchedAt?.hashValue ?? 0)
                    &+ (species.inatCommonNamesData?.count ?? 0) &* 7 &+ (species.taxonomyData?.count ?? 0)
            }
        }

        // rebuildCatalogueCaches: every species' classification decoded.
        _ = measure("catalogue caches (taxonomy decode)") {
            var names: [String: Set<String>] = [:]
            for species in catalogue {
                for rank in species.taxonomy where ["class", "order", "family", "genus"].contains(rank.rank) {
                    names[rank.rank, default: []].insert(rank.name)
                }
            }
            #expect(!names.isEmpty)
        }

        // computeStats, main-thread part: every sighting with its dive and species, copied out
        // (each step timed on its own, then the whole pass).
        var descriptor = FetchDescriptor<MarineSight>()
        descriptor.relationshipKeyPathsForPrefetching = [\.dive, \.species]
        var fetchedSights: [MarineSight] = []
        _ = measure("fetch sightings (with dive + species prefetch)") {
            fetchedSights = (try? context.fetch(descriptor)) ?? []
        }
        var index = SpeciesNameIndex()
        _ = measure("species name index") { index = SpeciesNameIndex(catalogue: catalogue) }
        _ = measure("read sighting fields") {
            for entry in fetchedSights { _ = (entry.isDeleted, entry.name, entry.count) }
        }
        _ = measure("read dive of each sighting") {
            for entry in fetchedSights { _ = entry.dive.map { ($0.isDeleted, $0.id, $0.timestamp, $0.persistentModelID) } }
        }
        _ = measure("read species link of each sighting") {
            for entry in fetchedSights { _ = entry.species?.persistentModelID }
        }
        _ = measure("name lookup of each sighting") {
            for entry in fetchedSights { _ = index.species(named: entry.name) }
        }
        fetchedSights = []

        // Candidate: no prefetch, only the sighting's own fields; dives looked up by identifier
        // in a map built from dives already in memory (DiveStore's list).
        let dives = try context.fetch(FetchDescriptor<Dive>())
        var light = FetchDescriptor<MarineSight>()
        light.propertiesToFetch = [\.name, \.count]
        var lightCount = 0
        _ = measure("candidate: light fetch + copy (dives from memory)") {
            let diveInfo = Dictionary(dives.map { ($0.persistentModelID, ($0.id, $0.timestamp)) },
                                      uniquingKeysWith: { first, _ in first })
            let sights = (try? context.fetch(light)) ?? []
            let nameIndex = SpeciesNameIndex(catalogue: catalogue)
            for entry in sights {
                guard let divePID = entry.dive?.persistentModelID, let info = diveInfo[divePID] else { continue }
                let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let speciesPID = entry.species?.persistentModelID ?? nameIndex.species(named: name)?.persistentModelID
                _ = (info.0, divePID, info.1, SightingQuantity.from(count: entry.count), speciesPID)
                lightCount += 1
            }
        }
        #expect(lightCount == Self.diveCount * Self.sightingsPerDive)

        // What Marine Life now runs: the reader off the main thread (its own context), then the
        // main thread only builds the name lookup it is given.
        var speciesByName: [String: PersistentIdentifier] = [:]
        _ = measure("now on the main thread: name lookup for the reader") {
            speciesByName = SpeciesNameIndex(catalogue: catalogue).speciesIDsByKey
        }
        var values: [SightingReader.Value] = []
        _ = measure("now off the main thread: SightingReader.read") {
            values = SightingReader.read(container: container, diverName: nil, speciesByName: speciesByName)
        }
        #expect(values.count == Self.diveCount * Self.sightingsPerDive)
        #expect(values.filter { $0.speciesPID != nil }.count == values.count)

        var copied = 0
        _ = measure("whole pass: fetch + copy \(Self.diveCount * Self.sightingsPerDive) sightings") {
            let sights = (try? context.fetch(descriptor)) ?? []
            let nameIndex = SpeciesNameIndex(catalogue: catalogue)
            for entry in sights {
                guard !entry.isDeleted, let dive = entry.dive, !dive.isDeleted else { continue }
                let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let species = entry.species.flatMap { $0.isDeleted ? nil : $0 } ?? nameIndex.species(named: name)
                _ = (dive.id, dive.persistentModelID, dive.timestamp, SightingQuantity.from(count: entry.count),
                     species?.persistentModelID)
                copied += 1
            }
        }
        #expect(copied == Self.diveCount * Self.sightingsPerDive)

        // computeStats: each catalogue species' display data (names decoded).
        _ = measure("catalogue display data") {
            for species in catalogue {
                _ = Set([species.commonName] + (species.altNames ?? []) + species.inatCommonNames.values.filter { !$0.isEmpty })
                _ = (species.id, species.displayName, species.scientificName, species.category)
            }
        }
    }
}
