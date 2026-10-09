import Foundation
import SwiftData

// Image bytes live in their own records, never next to fields that are queried. SwiftData
// keeps a small `.externalStorage` blob (under about 128 KB) inside the row, so a 512 px
// thumbnail stored on `DivePhoto` or `Species` would be loaded by every fetch of those rows —
// measured: scanning 20 000 photos took 6.3 s and 2.7 GB with the thumbnail in the row,
// 0.33 s and 85 MB without. A blob record is read only when its image is shown. Keeping the
// original apart also means a metadata edit (a caption, a species tag) never touches it.

/// The ≤ 512 px JPEG thumbnail of a `DivePhoto`, for grids, strips and profile markers.
@Model
final class DivePhotoThumbnail {
    var id: UUID = UUID()
    /// Mirror of `photo?.id`, set with the relationship (`DivePhoto.setThumbnail`).
    var photoID: UUID?
    @Attribute(.externalStorage) var data: Data?
    var photo: DivePhoto?

    init() {}
}

/// The original file bytes of a `DivePhoto`, stored unchanged.
@Model
final class DivePhotoOriginal {
    var id: UUID = UUID()
    /// Mirror of `photo?.id`, set with the relationship (`DivePhoto.setOriginal`).
    var photoID: UUID?
    @Attribute(.externalStorage) var data: Data?
    var photo: DivePhoto?

    init() {}
}

/// The featured image of a `Species`: the image, its thumbnail when smaller, and the credit
/// of an image that is not the user's own (e.g. an iNaturalist photo under a Creative
/// Commons licence).
@Model
final class SpeciesImage {
    var id: UUID = UUID()
    /// Mirror of `species?.id`, set with the relationship (`Species.setFeaturedImage`).
    var speciesID: UUID?
    @Attribute(.externalStorage) var imageData: Data?
    @Attribute(.externalStorage) var thumbnailData: Data?
    var attribution: String?
    var species: Species?

    init() {}
}

// MARK: - Orphan Sweep

/// Deletes image records that lost an iCloud conflict: two devices gave the same photo (or
/// species) a new image record before syncing; the owner keeps one, and the other — still
/// carrying its image bytes, in the store and in iCloud — is linked to nothing. A record is
/// deleted only when its owner (found by the mirror id) exists and links another record — not
/// when the owner links none — so a record still waiting for its owner, or its link, to arrive
/// from iCloud is never touched. A deleted owner takes its records with it (cascade), so no
/// other orphans arise.
///
/// Unlinked records are listed by identifier only, then read 50 at a time in a fresh context
/// with their owners looked up per group, yielding between groups: during a first iCloud sync
/// thousands of records can be waiting for their owner, and reading them (a small blob is
/// stored in the row) all at once would hold the main thread and their bytes in memory.
@MainActor
enum PhotoBlobSweeper {

    /// Runs once a minute after the main window opens, when the first iCloud import has
    /// usually settled.
    static func sweepLater(container: ModelContainer) async {
        guard (try? await Task.sleep(for: .seconds(60))) != nil else { return }
        await sweep(container: container)
    }

    static func sweep(container: ModelContainer) async {
        let listing = makeContext(container)
        let thumbnails = (try? listing.fetchIdentifiers(FetchDescriptor<DivePhotoThumbnail>(predicate: #Predicate { $0.photo == nil }))) ?? []
        let originals = (try? listing.fetchIdentifiers(FetchDescriptor<DivePhotoOriginal>(predicate: #Predicate { $0.photo == nil }))) ?? []
        let images = (try? listing.fetchIdentifiers(FetchDescriptor<SpeciesImage>(predicate: #Predicate { $0.species == nil }))) ?? []

        await sweep(thumbnails, container: container, ownerID: { (record: DivePhotoThumbnail) in record.photoID }) { ids, context in
            let owners = (try? context.fetch(FetchDescriptor<DivePhoto>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
            return Dictionary(owners.map { ($0.id, $0.thumbnail?.persistentModelID) }, uniquingKeysWith: { first, _ in first })
        }
        await sweep(originals, container: container, ownerID: { (record: DivePhotoOriginal) in record.photoID }) { ids, context in
            let owners = (try? context.fetch(FetchDescriptor<DivePhoto>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
            return Dictionary(owners.map { ($0.id, $0.original?.persistentModelID) }, uniquingKeysWith: { first, _ in first })
        }
        await sweep(images, container: container, ownerID: { (record: SpeciesImage) in record.speciesID }) { ids, context in
            let owners = (try? context.fetch(FetchDescriptor<Species>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
            return Dictionary(owners.map { ($0.id, $0.image?.persistentModelID) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Deletes the records in `orphans` whose owner exists and links another record.
    /// `linkedRecords` maps each existing owner id to the record it links (nil = none).
    private static func sweep<Record: PersistentModel>(
        _ orphans: [PersistentIdentifier],
        container: ModelContainer,
        ownerID: (Record) -> UUID?,
        linkedRecords: ([UUID], ModelContext) -> [UUID: PersistentIdentifier?]
    ) async {
        for start in stride(from: 0, to: orphans.count, by: 50) {
            guard !Task.isCancelled else { return }
            let chunk = Array(orphans[start..<min(start + 50, orphans.count)])
            let context = makeContext(container)
            let records = (try? context.fetch(FetchDescriptor<Record>(predicate: #Predicate { chunk.contains($0.persistentModelID) }))) ?? []
            let owners = linkedRecords(Array(Set(records.compactMap(ownerID))), context)
            var deleted = false
            for record in records {
                guard let id = ownerID(record), let linked = owners[id], let kept = linked,
                      kept != record.persistentModelID else { continue }
                context.delete(record)
                deleted = true
            }
            if deleted { try? context.save() }
            // Let input events run between groups.
            await Task.yield()
        }
    }

    private static func makeContext(_ container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.author = "BlueDive.photoBlobSweep"
        context.autosaveEnabled = false
        return context
    }
}
