import Foundation
import SwiftData

// MARK: - Dive Gas Reader

/// Reads the RMV and SAC of many dives off the MainActor, for the Statistics RMV and SAC tiles.
/// Computing them decodes each dive's profile the first time (measured: about 8.7 s for 2,880
/// dives on the main thread); this reader splits the dives across worker tasks, each with its own
/// `ModelContext` (author `"BlueDive.statistics"`), so the work runs in parallel and the profiles
/// this reader decodes are released with its contexts instead of staying on the main context's
/// dives.
/// The values are the same `Dive.calculatedRMV` / `calculatedSAC` the rest of the app shows,
/// read from the store (saved values): the caller computes on the MainActor the dives with
/// unsaved changes and any dive this reader could not read.
/// It has a single, cancellable caller (the Statistics tiles), so it is called directly rather
/// than through `DiveStore` (CLAUDE.md, "Store-backed readers"). No `propertiesToFetch`: it
/// fetches whole dives because the calculation reads many of the dive's attributes, including its
/// tank and profile data.
nonisolated enum DiveGasReader {
    static let author = "BlueDive.statistics"

    struct Value: Sendable {
        /// L/min at the surface; 0 when the dive has no RMV.
        let rmv: Double
        /// bar/min; 0 when the dive has no SAC.
        let sac: Double
        /// The RMV was calculated from bar and litres (`Dive.isRMVInNativeUnits`).
        let rmvIsNative: Bool
    }

    /// The values of the dives `ids` the reader could read, or nil when cancelled. A dive left
    /// out (a failed fetch, a dive not in the store) is for the caller to compute.
    static func read(container: ModelContainer, ids: [PersistentIdentifier]) async -> [PersistentIdentifier: Value]? {
        guard !ids.isEmpty else { return [:] }
        // One core left for the interface (and the main context's own reads), at most 8 workers.
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount - 1, 8))
        let chunkSize = max(100, (ids.count + workers - 1) / workers)
        let chunks = stride(from: 0, to: ids.count, by: chunkSize).map {
            Array(ids[$0..<min($0 + chunkSize, ids.count)])
        }
        return await withTaskGroup(of: [PersistentIdentifier: Value]?.self) { group in
            for chunk in chunks {
                group.addTask(priority: .userInitiated) {
                    readChunk(container: container, ids: chunk)
                }
            }
            var result: [PersistentIdentifier: Value] = [:]
            result.reserveCapacity(ids.count)
            for await part in group {
                guard let part else {
                    group.cancelAll()
                    return nil
                }
                result.merge(part) { first, _ in first }
            }
            return Task.isCancelled ? nil : result
        }
    }

    /// One worker: the dives fetched 200 at a time by identifier, each batch in a fresh context
    /// so its decoded profiles are released as soon as the batch is done.
    private static func readChunk(container: ModelContainer, ids: [PersistentIdentifier]) -> [PersistentIdentifier: Value]? {
        var result: [PersistentIdentifier: Value] = [:]
        result.reserveCapacity(ids.count)
        for start in stride(from: 0, to: ids.count, by: 200) {
            if Task.isCancelled { return nil }
            let batch = Array(ids[start..<min(start + 200, ids.count)])
            // The pool frees the batch's temporary objects (fetch, decoded profiles) as soon as
            // the batch is done, not when the worker's whole share is.
            let part: [PersistentIdentifier: Value]? = autoreleasepool {
                let context = ModelContext(container)
                context.author = author
                let descriptor = FetchDescriptor<Dive>(predicate: #Predicate { batch.contains($0.persistentModelID) })
                // A failed fetch leaves the batch out: the caller computes those dives itself
                // rather than averaging without them.
                guard let dives = try? context.fetch(descriptor) else { return nil }
                var values: [PersistentIdentifier: Value] = [:]
                for dive in dives {
                    let rmv = dive.calculatedRMV
                    // No RMV means no SAC (`combinedSAC` returns 0 then): skip its calculation.
                    let sac = rmv > 0 ? dive.calculatedSAC : 0
                    values[dive.persistentModelID] = Value(rmv: rmv, sac: sac, rmvIsNative: dive.isRMVInNativeUnits)
                }
                return values
            }
            if let part { result.merge(part) { first, _ in first } }
        }
        return result
    }
}
