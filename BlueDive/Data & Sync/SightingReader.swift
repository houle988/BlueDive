import Foundation
import SwiftData

// MARK: - Sighting Reader

/// Reads every sighting (`MarineSight`) as plain values, off the main thread, through its own
/// read-only context. A store-backed reader: it reads the store, not DiveStore's caches or any
/// main-context object, so a sighting or dive deleted by an iCloud merge meanwhile is never
/// touched, and what another device saved is seen as soon as it is committed. Only the
/// sightings' own fields and links are fetched; the dives' identity, date and diver come from
/// one light query (a dive row carries its profile). Run through `DiveStore.sightingValues`,
/// which shares one read between callers and cancels a superseded one.
nonisolated enum SightingReader {
    struct Value: Sendable {
        let diveID: UUID
        let divePID: PersistentIdentifier
        let timestamp: Date
        let name: String
        let count: Int
        /// The catalogue species: linked, or known by the sighting's name (a sighting that
        /// arrived unlinked — an XML import, an older app version — under a species' name is
        /// counted with that species, not listed apart as "not in the catalogue").
        let speciesPID: PersistentIdentifier?
    }

    static let author = "BlueDive.sightings"

    /// - Parameters:
    ///   - diverName: only this diver's dives (as `DiverFilter.apply` compares); nil for every diver.
    ///   - speciesByName: catalogue species by normalised name (`SpeciesNameIndex`).
    /// - Returns: the sightings, or an empty array when the task was cancelled (the caller
    ///   discards it).
    static func read(container: ModelContainer, diverName: String?,
                     speciesByName: [String: PersistentIdentifier]) -> [Value] {
        let context = ModelContext(container)
        context.author = author
        var diveQuery = FetchDescriptor<Dive>()
        diveQuery.propertiesToFetch = [\.id, \.timestamp, \.diverName]
        let dives = ((try? context.fetch(diveQuery)) ?? []).filter {
            diverName == nil || $0.diverName.trimmingCharacters(in: .whitespaces) == diverName
        }
        let diveInfo = Dictionary(dives.map { ($0.persistentModelID, ($0.id, $0.timestamp)) },
                                  uniquingKeysWith: { first, _ in first })
        if Task.isCancelled { return [] }
        var sightQuery = FetchDescriptor<MarineSight>()
        // The to-one links too, so reading their identifiers fires no fault.
        sightQuery.propertiesToFetch = [\.name, \.count, \.dive, \.species]
        let sights = (try? context.fetch(sightQuery)) ?? []
        var values: [Value] = []
        values.reserveCapacity(sights.count)
        for (index, entry) in sights.enumerated() {
            if index % 5_000 == 4_999, Task.isCancelled { return [] }
            // A sighting of a dive not in `diveInfo` (another diver's) is left out.
            guard let divePID = entry.dive?.persistentModelID, let (diveID, timestamp) = diveInfo[divePID] else { continue }
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            values.append(Value(diveID: diveID, divePID: divePID, timestamp: timestamp, name: name, count: entry.count,
                                speciesPID: entry.species?.persistentModelID ?? speciesByName[SpeciesCatalog.key(name)]))
        }
        return values
    }
}
