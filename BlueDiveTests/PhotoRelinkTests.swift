import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import BlueDive

/// Photos that lost their dive link (`dive` nil, `diveID` kept), as found in a user's store:
/// the main context autosaved an unsaved dive edit just after a photo import, with the photo
/// list it read before it. Covers the main-context save when a photo context is created and
/// Settings → Data Management → Repair photos (`PhotoImporter.repairUnlinkedPhotos`).
@MainActor
struct PhotoRelinkTests {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Schema(BlueDiveApp.appModelTypes),
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    /// A small JPEG, different for each `seed`.
    private func jpeg(seed: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: CGFloat(seed % 7) / 7, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func insertDive(id: UUID = UUID(), in context: ModelContext) throws -> Dive {
        let dive = Dive(id: id, timestamp: Date(timeIntervalSince1970: 1_790_000_000))
        dive.setDuration(minutes: 45)
        context.insert(dive)
        try context.save()
        return dive
    }

    /// Imports one image into `dive` and returns its photo, as the main context sees it.
    private func importPhoto(_ data: Data, into dive: Dive, container: ModelContainer) async throws -> DivePhoto {
        let result = await PhotoImporter.importPhotos([.data(data, filename: "map.jpg")],
                                                      toDiveWith: dive.persistentModelID, container: container)
        #expect(result.imported == 1)
        let photoID = try #require(result.importedPhotoIDs.first)
        return try #require(PhotoImporter.fetchPhoto(photoID, in: container.mainContext))
    }

    /// Clears the dive link as the faulty save did, keeping `diveID`.
    private func unlink(_ photo: DivePhoto, in context: ModelContext) throws {
        let diveID = photo.diveID
        photo.dive = nil
        photo.diveID = diveID
        try context.save()
    }

    @Test func importKeepsAnUnsavedDiveEditAndItsPhoto() async throws {
        let container = try makeContainer()
        let main = container.mainContext
        let dive = try insertDive(in: main)
        // An unsaved edit, as the tank editor leaves it for autosave.
        dive.tanks = [TankData()]

        _ = try await importPhoto(try jpeg(seed: 1), into: dive, container: container)

        #expect(!main.hasChanges)
        // Read back from the store: both the edit and the photo's link are saved.
        let stored = try #require(PhotoImporter.fetchDive(dive.persistentModelID, in: ModelContext(container)))
        #expect(stored.tanks.count == 1)
        #expect((stored.photos ?? []).count == 1)
    }

    @Test func editDuringAMultiBatchImportUnlinksNothing() async throws {
        let container = try makeContainer()
        let main = container.mainContext
        let dive = try insertDive(in: main)
        let sources: [PhotoImporter.Source] = try (20..<26).map { .data(try jpeg(seed: $0), filename: "p\($0).jpg") }

        // 6 files: saved in two batches (5 + 1). The tanks are edited once the first batch is
        // saved, and left unsaved as the tank editor does.
        let result = await PhotoImporter.importPhotos(sources, toDiveWith: dive.persistentModelID,
                                                      container: container,
                                                      progress: { processed, _ in
                                                          if processed == 5 { dive.tanks = [TankData()] }
                                                      })

        #expect(result.imported == 6)
        let check = ModelContext(container)
        #expect(try check.fetchCount(FetchDescriptor<DivePhoto>(predicate: #Predicate { $0.dive == nil })) == 0)
        let stored = try #require(PhotoImporter.fetchDive(dive.persistentModelID, in: check))
        #expect((stored.photos ?? []).count == 6)
    }

    @Test func unlinkedPhotoIsPutBackWithItsImages() async throws {
        let container = try makeContainer()
        let main = container.mainContext
        let dive = try insertDive(in: main)
        let photo = try await importPhoto(try jpeg(seed: 2), into: dive, container: container)
        let originalBytes = photo.original?.data
        try unlink(photo, in: main)

        let summary = await PhotoImporter.repairUnlinkedPhotos(container: container)

        #expect(summary.relinked == 1 && summary.leftIDs.isEmpty)
        #expect(summary.relinkedDiveIDs == [dive.id])
        let stored = try #require(try ModelContext(container).fetch(FetchDescriptor<DivePhoto>()).first)
        #expect(stored.dive?.id == dive.id)
        #expect(stored.original?.data == originalBytes)
        #expect(stored.thumbnail?.data != nil)

        // Nothing left: the next run finds nothing.
        #expect(await PhotoImporter.repairUnlinkedPhotos(container: container).foundNothing)
    }

    @Test func photoOfAMissingDiveIsListedThenDeletedWithItsImages() async throws {
        let container = try makeContainer()
        let main = container.mainContext
        let dive = try insertDive(in: main)
        let photo = try await importPhoto(try jpeg(seed: 3), into: dive, container: container)
        photo.dive = nil
        photo.diveID = UUID()
        try main.save()

        let summary = await PhotoImporter.repairUnlinkedPhotos(container: container)

        // Listed and kept: deleting is the user's choice.
        #expect(summary.relinked == 0 && summary.leftIDs == [photo.persistentModelID])
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<DivePhoto>()) == 1)

        let result = await PhotoImporter.deleteUnlinkedPhotos(summary.leftIDs, container: container)
        #expect(result.deleted == 1 && result.relinkedDiveIDs.isEmpty)
        let check = ModelContext(container)
        #expect(try check.fetchCount(FetchDescriptor<DivePhoto>()) == 0)
        #expect(try check.fetchCount(FetchDescriptor<DivePhotoOriginal>()) == 0)
        #expect(try check.fetchCount(FetchDescriptor<DivePhotoThumbnail>()) == 0)
    }

    @Test func photoWhoseDiveArrivesBeforeTheDeletionIsPutBack() async throws {
        let container = try makeContainer()
        let main = container.mainContext
        let dive = try insertDive(in: main)
        let photo = try await importPhoto(try jpeg(seed: 4), into: dive, container: container)
        let lateDiveID = UUID()
        photo.dive = nil
        photo.diveID = lateDiveID
        try main.save()
        let summary = await PhotoImporter.repairUnlinkedPhotos(container: container)
        #expect(summary.leftIDs == [photo.persistentModelID])

        // Its dive arrives (e.g. from iCloud) before the user confirms.
        let lateDive = try insertDive(id: lateDiveID, in: main)
        let result = await PhotoImporter.deleteUnlinkedPhotos(summary.leftIDs, container: container)

        // Not deleted: put back on the dive that arrived.
        #expect(result.deleted == 0 && result.relinkedDiveIDs == [lateDiveID])
        let stored = try #require(PhotoImporter.fetchDive(lateDive.persistentModelID, in: ModelContext(container)))
        #expect((stored.photos ?? []).map(\.id) == [photo.id])
    }

    @Test func hiddenCopyOfAPhotoTheDiveShowsIsListedThenDeleted() async throws {
        let container = try makeContainer()
        let main = container.mainContext
        let dive = try insertDive(in: main)
        let shown = try await importPhoto(try jpeg(seed: 6), into: dive, container: container)
        // A hidden record of the same file with the dive's id (as a re-import before the repair
        // could leave).
        let hidden = DivePhoto()
        hidden.contentHash = shown.contentHash
        main.insert(hidden)
        hidden.setOriginal(try #require(shown.original?.data))
        hidden.diveID = dive.id
        try main.save()

        let summary = await PhotoImporter.repairUnlinkedPhotos(container: container)

        // Not put back: the dive would show the photo twice.
        #expect(summary.relinked == 0 && summary.leftIDs == [hidden.persistentModelID])

        let result = await PhotoImporter.deleteUnlinkedPhotos(summary.leftIDs, container: container)
        #expect(result.deleted == 1)
        let check = ModelContext(container)
        let photos = try check.fetch(FetchDescriptor<DivePhoto>())
        #expect(photos.map(\.id) == [shown.id])
        #expect(photos.first?.dive?.id == dive.id)
    }

    @Test func photoOfDivesSharingAnIdIsNotPutBack() async throws {
        let container = try makeContainer()
        let main = container.mainContext
        let shared = UUID()
        let dive = try insertDive(id: shared, in: main)
        _ = try insertDive(id: shared, in: main)
        let photo = try await importPhoto(try jpeg(seed: 5), into: dive, container: container)
        try unlink(photo, in: main)

        let summary = await PhotoImporter.repairUnlinkedPhotos(container: container)

        #expect(summary.relinked == 0 && summary.leftIDs == [photo.persistentModelID])
        #expect(photo.dive == nil)

        // Its dive exists (which one is unknown): never deleted.
        let result = await PhotoImporter.deleteUnlinkedPhotos(summary.leftIDs, container: container)
        #expect(result.deleted == 0)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<DivePhoto>()) == 1)
    }
}
