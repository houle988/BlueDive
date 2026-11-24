import CoreData
import Foundation
import SQLite3
import SwiftData
import Testing
@testable import BlueDive

/// The clean store a restore swaps in (`DatabaseRestore.makeCleanStore`): every record and file of
/// the backup, none of its iCloud mirroring state. Data is built in code; the optional real-backup
/// test reads an unzipped backup from outside the repository and is skipped when it is absent.
@MainActor
struct DatabaseRestoreTests {

    /// A new empty folder in tmp.
    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueDiveRestoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Bytes that do not compress and exceed SwiftData's in-row limit, so they go to
    /// `.default_SUPPORT/_EXTERNAL_DATA`.
    private func largeBytes(_ count: Int, seed: UInt8) -> Data {
        var generator = SystemRandomNumberGenerator()
        var data = Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
        data[0] = seed
        return data
    }

    /// A store at `url` with dives, gear, a species with its image, a photo with its blobs and a
    /// fingerprint, written by SwiftData as the app does (no iCloud).
    private func makeSourceStore(at url: URL) throws {
        let container = try ModelContainer(for: Schema(BlueDiveApp.appModelTypes),
                                           configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let context = container.mainContext
        // Saved once, below: no autosave writing to the file while the test edits it.
        context.autosaveEnabled = false

        let gear = Gear(name: "Test regulator", category: "Regulator", serialNumber: "R-1")
        context.insert(gear)
        let group = GearGroup(name: "Test kit")
        context.insert(group)
        group.gear = [gear]

        let dive = Dive(diveNumber: 7, siteName: "Test Reef", maxDepth: 18.4, averageDepth: 11.2)
        dive.setDuration(seconds: 2_734)
        dive.notes = "Made-up dive for the restore test."
        context.insert(dive)
        dive.usedGear = [gear]
        let second = Dive(diveNumber: 8, siteName: "Second Site", maxDepth: 9.75)
        context.insert(second)

        let species = Species(commonName: "Test fish")
        context.insert(species)
        species.setFeaturedImage(largeBytes(300_000, seed: 1), thumbnail: Data([1, 2, 3]), attribution: "Test")

        let photo = DivePhoto()
        context.insert(photo)
        photo.attach(to: dive)
        photo.species = [species]
        photo.setOriginal(largeBytes(400_000, seed: 2))
        photo.setThumbnail(Data([4, 5, 6]))

        context.insert(TankTemplate(name: "Test 12 L"))
        context.insert(DeviceFingerprint(serial: "TEST-SERIAL", computerName: "Test computer",
                                         fingerprintData: Data([9, 8, 7])))
        try context.save()
    }

    /// Adds what NSPersistentCloudKitContainer leaves in a store: a mirroring table with a row
    /// and a metadata key (the real table and key names come from Core Data; these stand in).
    private func addMirroringResidue(to url: URL) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        // The SwiftData container that wrote the store may still hold its lock for a moment.
        sqlite3_busy_timeout(db, 10_000)
        let sql = "CREATE TABLE ANSCKRECORDMETADATA (Z_PK INTEGER PRIMARY KEY, ZCKRECORDNAME TEXT);"
            + "INSERT INTO ANSCKRECORDMETADATA (ZCKRECORDNAME) VALUES ('old-record');"
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        db = nil

        var metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url)
        metadata["NSPersistentCloudKitContainerTestMirroringState"] = "old-zone-token"
        try NSPersistentStoreCoordinator.setMetadata(metadata, type: .sqlite, at: url)
    }

    /// Every record of every entity as comparable values: its attributes, and for each
    /// relationship the `id`s (or `serial`) of the related records. Read with plain Core Data,
    /// so private attributes (e.g. `Dive.profileData`) are compared too.
    private func snapshot(of url: URL) throws -> [String: NSCountedSet] {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: BlueDiveApp.appModelTypes))
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(
            type: .sqlite, at: url, options: [NSReadOnlyPersistentStoreOption: true,
                                              NSPersistentHistoryTrackingKey: true])
        defer { try? coordinator.remove(store) }
        // A main-queue context, used directly: the test runs on the main actor.
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        var result: [String: NSCountedSet] = [:]
        for entity in model.entities {
            guard let name = entity.name else { continue }
            let objects = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: name))
            let set = NSCountedSet()
            for object in objects {
                var values = object.dictionaryWithValues(forKeys: Array(entity.attributesByName.keys))
                for (key, relationship) in entity.relationshipsByName {
                    let related: [NSManagedObject]
                    if relationship.isToMany {
                        related = (object.value(forKey: key) as? Set<NSManagedObject>).map(Array.init) ?? []
                    } else {
                        related = (object.value(forKey: key) as? NSManagedObject).map { [$0] } ?? []
                    }
                    values[key] = related.map { "\($0.value(forKey: "id") ?? $0.value(forKey: "serial") ?? "?")" }.sorted()
                }
                set.add(values as NSDictionary)
            }
            result[name] = set
        }
        return result
    }

    /// Files under the store's external-storage folder.
    private func externalFileCount(besides storeURL: URL) -> Int {
        let support = storeURL.deletingLastPathComponent().appendingPathComponent(".default_SUPPORT/_EXTERNAL_DATA")
        return (try? FileManager.default.contentsOfDirectory(atPath: support.path).count) ?? 0
    }

    // MARK: - Tests

    @Test func cleanStoreKeepsEveryRecordAndDropsTheMirroringState() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sourceFolder = folder.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let sourceURL = sourceFolder.appendingPathComponent("default.store")
        try makeSourceStore(at: sourceURL)
        try addMirroringResidue(to: sourceURL)
        #expect(DatabaseRestore.mirroringTableNames(at: sourceURL) == ["ANSCKRECORDMETADATA"])
        let sourceUUID = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite, at: sourceURL)[NSStoreUUIDKey] as? String
        let before = try snapshot(of: sourceURL)
        let sourceFiles = externalFileCount(besides: sourceURL)
        #expect(sourceFiles >= 2)

        let outFolder = folder.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)
        let outURL = outFolder.appendingPathComponent("default.store")
        let report = try DatabaseRestore.makeCleanStore(from: sourceURL, to: outURL,
                                                        modelTypes: BlueDiveApp.appModelTypes)

        // No mirroring table, no mirroring metadata, a new identity.
        #expect(DatabaseRestore.mirroringTableNames(at: outURL).isEmpty)
        #expect(report.removedMetadataKeys.contains("NSPersistentCloudKitContainerTestMirroringState"))
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: outURL)
        #expect(metadata["NSPersistentCloudKitContainerTestMirroringState"] == nil)
        #expect(metadata[NSStoreUUIDKey] as? String == report.storeUUID)
        #expect(report.storeUUID != sourceUUID)

        // Every record, value, link and external file is there.
        #expect(report.entityCounts["Dive"] == 2)
        #expect(report.entityCounts["DivePhotoOriginal"] == 1)
        #expect(try snapshot(of: outURL) == before)
        #expect(externalFileCount(besides: outURL) == sourceFiles)

        // SwiftData opens it as the app does, reads the blobs and can save.
        let container = try ModelContainer(for: Schema(BlueDiveApp.appModelTypes),
                                           configurations: ModelConfiguration(url: outURL, cloudKitDatabase: .none))
        let context = container.mainContext
        let dives = try context.fetch(FetchDescriptor<Dive>(sortBy: [SortDescriptor(\.diveNumber)]))
        #expect(dives.map(\.siteName) == ["Test Reef", "Second Site"])
        #expect(dives.first?.consistentDurationSeconds == 2_734)
        #expect(dives.first?.usedGear?.first?.serialNumber == "R-1")
        let photo = try #require(dives.first?.photos?.first)
        #expect(photo.original?.data?.count == 400_000)
        #expect(photo.species?.first?.image?.imageData?.count == 300_000)
        context.insert(Dive(diveNumber: 9, siteName: "Added after restore"))
        try context.save()
    }

    /// A backup made before a model change (here: before `Dive.tideHeight`) is brought to the
    /// current model on the way.
    @Test func cleanStoreMigratesAnOlderModel() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let current = try #require(NSManagedObjectModel.makeManagedObjectModel(for: BlueDiveApp.appModelTypes))
        let older = try #require(current.copy() as? NSManagedObjectModel)
        let diveEntity = try #require(older.entitiesByName["Dive"])
        diveEntity.properties = diveEntity.properties.filter { $0.name != "tideHeight" }

        let sourceURL = folder.appendingPathComponent("old.store")
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: older)
        let store = try coordinator.addPersistentStore(type: .sqlite, at: sourceURL,
                                                       options: [NSPersistentHistoryTrackingKey: true])
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let id = UUID()
        try context.performAndWait {
            let dive = NSEntityDescription.insertNewObject(forEntityName: "Dive", into: context)
            dive.setValue(id, forKey: "id")
            dive.setValue("Older backup", forKey: "siteName")
            try context.save()
        }
        try coordinator.remove(store)

        let outFolder = folder.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)
        let outURL = outFolder.appendingPathComponent("default.store")
        let report = try DatabaseRestore.makeCleanStore(from: sourceURL, to: outURL,
                                                        modelTypes: BlueDiveApp.appModelTypes)
        #expect(report.entityCounts["Dive"] == 1)

        let container = try ModelContainer(for: Schema(BlueDiveApp.appModelTypes),
                                           configurations: ModelConfiguration(url: outURL, cloudKitDatabase: .none))
        let dives = try container.mainContext.fetch(FetchDescriptor<Dive>())
        #expect(dives.map(\.id) == [id])
        #expect(dives.first?.siteName == "Older backup")
        #expect(dives.first?.tideHeight == nil)
    }

    // MARK: - Restore mode

    /// A backup laid out as an unzipped format 2 archive: `<parent>/BlueDive Backup/default.store`.
    private func makeBackupFolder(in folder: URL) throws -> URL {
        let parent = folder.appendingPathComponent("Unzipped", isDirectory: true)
        let root = parent.appendingPathComponent(BackupFormat.rootFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeSourceStore(at: root.appendingPathComponent("default.store"))
        try addMirroringResidue(to: root.appendingPathComponent("default.store"))
        return parent
    }

    /// Prepares a restore as the preparation sheet does: the candidate (one copy and clean copy),
    /// then the pending restore.
    @discardableResult
    private func prepare(_ source: RestoreSource, root: URL) throws -> DatabaseRestore.Candidate {
        let candidate = try DatabaseRestore.prepareCandidate(source, modelTypes: BlueDiveApp.appModelTypes, root: root)
        try DatabaseRestore.commitCandidate(candidate, source: source, root: root)
        return candidate
    }

    @Test func locateBackupFindsEachLayout() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let parent = try makeBackupFolder(in: folder)
        let root = parent.appendingPathComponent(BackupFormat.rootFolderName)
        // The folder the zip was unzipped into, and the backup folder itself.
        #expect(DatabaseRestore.locateBackup(in: parent)?.folder.lastPathComponent == BackupFormat.rootFolderName)
        #expect(DatabaseRestore.locateBackup(in: root)?.hasSupportFolder == true)
        // Format 1: `BlueDiveBackup-<UUID>/`.
        let formatOne = folder.appendingPathComponent("Old", isDirectory: true)
        let inner = formatOne.appendingPathComponent("BlueDiveBackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: formatOne, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root, to: inner)
        let located = try #require(DatabaseRestore.locateBackup(in: formatOne))
        #expect(located.folder.lastPathComponent == inner.lastPathComponent)
        #expect(located.manifest == nil)
        // Not a backup.
        #expect(DatabaseRestore.locateBackup(in: folder.appendingPathComponent("Old/missing")) == nil)
    }

    @Test func newerBuildIsRefused() throws {
        let manifest = BackupManifest(formatVersion: 2, createdAt: "", createdAtEpoch: 0,
                                      app: .init(version: "9.0", build: "900", bundleIdentifier: ""),
                                      platform: "", iCloudSyncEnabled: true,
                                      store: .init(fileName: "default.store", storeUUID: nil, storeBytes: 0,
                                                   supportFolder: "", externalFileCount: 0, externalBytes: 0,
                                                   missingExternalFiles: 0),
                                      entities: nil)
        #expect(DatabaseRestore.isFromNewerBuild(manifest, currentBuild: "899"))
        #expect(!DatabaseRestore.isFromNewerBuild(manifest, currentBuild: "900"))
        #expect(!DatabaseRestore.isFromNewerBuild(nil, currentBuild: "1"))
    }

    /// Stage, clean copy and swap over a live store, as restore mode runs them; then cancel
    /// during a swap puts the replaced logbook back.
    @Test func stageAndSwapReplaceTheLiveStore() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let restoreRoot = folder.appendingPathComponent("Restore", isDirectory: true)
        let liveFolder = folder.appendingPathComponent("Live", isDirectory: true)
        try FileManager.default.createDirectory(at: liveFolder, withIntermediateDirectories: true)
        let liveURL = liveFolder.appendingPathComponent("default.store")
        do {
            let live = try ModelContainer(for: Schema(BlueDiveApp.appModelTypes),
                                          configurations: ModelConfiguration(url: liveURL, cloudKitDatabase: .none))
            live.mainContext.insert(Dive(diveNumber: 1, siteName: "Current logbook"))
            try live.mainContext.save()
        }

        let source = try #require(DatabaseRestore.locateBackup(in: try makeBackupFolder(in: folder)))
        let expected = try snapshot(of: source.folder.appendingPathComponent("default.store"))
        try prepare(source, root: restoreRoot)
        #expect(DatabaseRestore.readPending(in: restoreRoot)?.phase == .staged)
        try DatabaseRestore.swap(liveStoreURL: liveURL, modelTypes: BlueDiveApp.appModelTypes, root: restoreRoot)
        #expect(DatabaseRestore.readPending(in: restoreRoot)?.phase == .swapping)

        // The live location holds the backup, clean, with its external files.
        #expect(DatabaseRestore.mirroringTableNames(at: liveURL).isEmpty)
        #expect(try snapshot(of: liveURL) == expected)
        #expect(externalFileCount(besides: liveURL) >= 2)
        // The replaced logbook is kept.
        let previous = DatabaseRestore.previousFolder(in: restoreRoot).appendingPathComponent("default.store")
        #expect(FileManager.default.fileExists(atPath: previous.path))

        // Cancelling now puts the replaced logbook back.
        try DatabaseRestore.cancel(liveStoreURL: liveURL, root: restoreRoot)
        #expect(DatabaseRestore.readPending(in: restoreRoot) == nil)
        let restored = try ModelContainer(for: Schema(BlueDiveApp.appModelTypes),
                                          configurations: ModelConfiguration(url: liveURL, cloudKitDatabase: .none))
        #expect(try restored.mainContext.fetch(FetchDescriptor<Dive>()).map(\.siteName) == ["Current logbook"])
    }

    /// A swap interrupted after the live store was moved runs again from the clean copy, and
    /// `finish` leaves only the replaced logbook.
    @Test func interruptedSwapRunsAgain() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let restoreRoot = folder.appendingPathComponent("Restore", isDirectory: true)
        let liveURL = folder.appendingPathComponent("Live/default.store")
        try FileManager.default.createDirectory(at: liveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = try #require(DatabaseRestore.locateBackup(in: try makeBackupFolder(in: folder)))
        let expected = try snapshot(of: source.folder.appendingPathComponent("default.store"))
        try prepare(source, root: restoreRoot)
        try DatabaseRestore.swap(liveStoreURL: liveURL, modelTypes: BlueDiveApp.appModelTypes, root: restoreRoot)
        // A partial store left at the live location by an interruption.
        try Data([0, 1, 2]).write(to: liveURL)
        try DatabaseRestore.ensureCleanCopy(modelTypes: BlueDiveApp.appModelTypes, root: restoreRoot)
        try DatabaseRestore.swap(liveStoreURL: liveURL, modelTypes: BlueDiveApp.appModelTypes, root: restoreRoot)
        #expect(try snapshot(of: liveURL) == expected)

        try DatabaseRestore.finish(root: restoreRoot)
        #expect(DatabaseRestore.readPending(in: restoreRoot) == nil)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: restoreRoot.path)
        #expect(remaining == ["previous"])
    }

    // MARK: - Interruptions and failures

    /// A live store with external files (as the app's), a staged backup and its clean copy.
    private func makeSwapScenario(in folder: URL) throws -> (restoreRoot: URL, liveURL: URL, live: [String: NSCountedSet], backup: [String: NSCountedSet]) {
        let restoreRoot = folder.appendingPathComponent("Restore", isDirectory: true)
        let liveFolder = folder.appendingPathComponent("Live", isDirectory: true)
        try FileManager.default.createDirectory(at: liveFolder, withIntermediateDirectories: true)
        let liveURL = liveFolder.appendingPathComponent("default.store")
        try makeSourceStore(at: liveURL)
        do {
            // A second dive makes the live logbook differ from the backup.
            let container = try ModelContainer(for: Schema(BlueDiveApp.appModelTypes),
                                               configurations: ModelConfiguration(url: liveURL, cloudKitDatabase: .none))
            container.mainContext.insert(Dive(diveNumber: 99, siteName: "Only in the live logbook"))
            try container.mainContext.save()
        }
        let live = try snapshot(of: liveURL)
        let source = try #require(DatabaseRestore.locateBackup(in: try makeBackupFolder(in: folder)))
        let backup = try snapshot(of: source.folder.appendingPathComponent("default.store"))
        try prepare(source, root: restoreRoot)
        return (restoreRoot, liveURL, live, backup)
    }

    /// The marker of a swap that stopped right after it was written (`phase: swapping`, the live
    /// items recorded), before anything was moved.
    private func markSwapStarted(restoreRoot: URL, liveURL: URL) throws {
        var pending = try #require(DatabaseRestore.readPending(in: restoreRoot))
        pending.phase = .swapping
        pending.originalLiveItems = ["default.store", "default.store-wal", "default.store-shm", ".default_SUPPORT"]
            .filter { FileManager.default.fileExists(atPath: liveURL.deletingLastPathComponent().appendingPathComponent($0).path) }
        try DatabaseRestore.writePending(pending, in: restoreRoot)
    }

    @Test func cancelAfterAnInterruptionBeforeAnyMoveKeepsTheLogbook() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scenario = try makeSwapScenario(in: folder)
        try markSwapStarted(restoreRoot: scenario.restoreRoot, liveURL: scenario.liveURL)

        try DatabaseRestore.cancel(liveStoreURL: scenario.liveURL, root: scenario.restoreRoot)
        #expect(DatabaseRestore.readPending(in: scenario.restoreRoot) == nil)
        #expect(try snapshot(of: scenario.liveURL) == scenario.live)
        #expect(externalFileCount(besides: scenario.liveURL) >= 2)
    }

    @Test func retryAfterAnInterruptionBeforeAnyMoveRestores() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scenario = try makeSwapScenario(in: folder)
        try markSwapStarted(restoreRoot: scenario.restoreRoot, liveURL: scenario.liveURL)

        try DatabaseRestore.swap(liveStoreURL: scenario.liveURL, modelTypes: BlueDiveApp.appModelTypes, root: scenario.restoreRoot)
        #expect(try snapshot(of: scenario.liveURL) == scenario.backup)
        // The whole replaced logbook is in `previous`.
        let previous = DatabaseRestore.previousFolder(in: scenario.restoreRoot).appendingPathComponent("default.store")
        #expect(try snapshot(of: previous) == scenario.live)
    }

    /// A swap that moved the store files but stopped before the external-file folder.
    private func moveStoreFilesOnly(restoreRoot: URL, liveURL: URL) throws {
        let fm = FileManager.default
        let previous = DatabaseRestore.previousFolder(in: restoreRoot)
        try fm.createDirectory(at: previous, withIntermediateDirectories: true)
        for name in ["default.store", "default.store-wal", "default.store-shm"] {
            let live = liveURL.deletingLastPathComponent().appendingPathComponent(name)
            if fm.fileExists(atPath: live.path) {
                try fm.moveItem(at: live, to: previous.appendingPathComponent(name))
            }
        }
    }

    @Test func cancelAfterAPartialMovePutsEverythingBack() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scenario = try makeSwapScenario(in: folder)
        let liveFiles = externalFileCount(besides: scenario.liveURL)
        try markSwapStarted(restoreRoot: scenario.restoreRoot, liveURL: scenario.liveURL)
        try moveStoreFilesOnly(restoreRoot: scenario.restoreRoot, liveURL: scenario.liveURL)

        try DatabaseRestore.cancel(liveStoreURL: scenario.liveURL, root: scenario.restoreRoot)
        #expect(try snapshot(of: scenario.liveURL) == scenario.live)
        #expect(externalFileCount(besides: scenario.liveURL) == liveFiles)
        // Everything was put back: no empty replaced logbook is left to show.
        #expect(!FileManager.default.fileExists(atPath: DatabaseRestore.previousFolder(in: scenario.restoreRoot).path))
    }

    @Test func retryAfterAPartialMoveKeepsTheExternalFiles() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scenario = try makeSwapScenario(in: folder)
        let liveFiles = externalFileCount(besides: scenario.liveURL)
        try markSwapStarted(restoreRoot: scenario.restoreRoot, liveURL: scenario.liveURL)
        try moveStoreFilesOnly(restoreRoot: scenario.restoreRoot, liveURL: scenario.liveURL)

        try DatabaseRestore.swap(liveStoreURL: scenario.liveURL, modelTypes: BlueDiveApp.appModelTypes, root: scenario.restoreRoot)
        #expect(try snapshot(of: scenario.liveURL) == scenario.backup)
        // The replaced logbook's external files were moved, not deleted.
        let previousStore = DatabaseRestore.previousFolder(in: scenario.restoreRoot).appendingPathComponent("default.store")
        #expect(externalFileCount(besides: previousStore) == liveFiles)
        #expect(try snapshot(of: previousStore) == scenario.live)
    }

    @Test func finishRemovesTheMarkerAndLeftoversAreCleaned() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scenario = try makeSwapScenario(in: folder)
        try DatabaseRestore.swap(liveStoreURL: scenario.liveURL, modelTypes: BlueDiveApp.appModelTypes, root: scenario.restoreRoot)
        try DatabaseRestore.finish(root: scenario.restoreRoot)
        #expect(DatabaseRestore.readPending(in: scenario.restoreRoot) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scenario.restoreRoot.path) == ["previous"])

        // Working folders left without a marker are removed at launch; a pending restore's are kept.
        let staged = scenario.restoreRoot.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        DatabaseRestore.removeLeftovers(before: .distantFuture, root: scenario.restoreRoot)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(FileManager.default.fileExists(atPath: DatabaseRestore.previousFolder(in: scenario.restoreRoot).path))
    }

    @Test func preparingKeepsTheLogbookAnEarlierRestoreReplaced() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let restoreRoot = folder.appendingPathComponent("Restore", isDirectory: true)
        let previous = DatabaseRestore.previousFolder(in: restoreRoot)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try Data([1]).write(to: previous.appendingPathComponent("default.store"))

        let source = try #require(DatabaseRestore.locateBackup(in: try makeBackupFolder(in: folder)))
        try prepare(source, root: restoreRoot)
        #expect(FileManager.default.fileExists(atPath: previous.appendingPathComponent("default.store").path))
        try DatabaseRestore.cancel(liveStoreURL: folder.appendingPathComponent("Live/default.store"), root: restoreRoot)
        #expect(FileManager.default.fileExists(atPath: previous.appendingPathComponent("default.store").path))
    }

    @Test func preparingRefusesADamagedBackupAndCountsAGoodOne() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let restoreRoot = folder.appendingPathComponent("Restore", isDirectory: true)
        let good = try #require(DatabaseRestore.locateBackup(in: try makeBackupFolder(in: folder)))
        let candidate = try DatabaseRestore.prepareCandidate(good, modelTypes: BlueDiveApp.appModelTypes, root: restoreRoot)
        #expect(candidate.report.entityCounts["Dive"] == 2)
        DatabaseRestore.discardCandidate(candidate.id, root: restoreRoot)

        let damagedFolder = folder.appendingPathComponent("Damaged", isDirectory: true)
        try FileManager.default.createDirectory(at: damagedFolder, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4096).write(to: damagedFolder.appendingPathComponent("default.store"))
        let damaged = try #require(DatabaseRestore.locateBackup(in: damagedFolder))
        #expect(throws: (any Error).self) {
            try DatabaseRestore.prepareCandidate(damaged, modelTypes: BlueDiveApp.appModelTypes, root: restoreRoot)
        }
        // A refused candidate leaves nothing behind, and nothing is pending.
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: restoreRoot.path)) ?? []).filter { $0.hasPrefix("candidate-") }.isEmpty)
        #expect(DatabaseRestore.readPending(in: restoreRoot) == nil)
    }

    /// A `previous` folder that cannot be removed stops the swap before anything is moved.
    @Test func swapStopsWhenTheEarlierReplacedLogbookCannotBeRemoved() throws {
        let folder = try makeFolder()
        let scenario = try makeSwapScenario(in: folder)
        let previous = DatabaseRestore.previousFolder(in: scenario.restoreRoot)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try Data([1]).write(to: previous.appendingPathComponent("default.store"))
        // A read-only folder: its file cannot be deleted.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: previous.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: previous.path)
            try? FileManager.default.removeItem(at: folder)
        }

        #expect(throws: (any Error).self) {
            try DatabaseRestore.swap(liveStoreURL: scenario.liveURL, modelTypes: BlueDiveApp.appModelTypes, root: scenario.restoreRoot)
        }
        // The live logbook is untouched and the restore is still only prepared.
        #expect(try snapshot(of: scenario.liveURL) == scenario.live)
        #expect(DatabaseRestore.readPending(in: scenario.restoreRoot)?.phase == .staged)
    }

    /// Preparing a second restore replaces the first only when it is committed; a candidate that
    /// is discarded (the sheet closed) leaves the first restore as it was.
    @Test func aSecondPreparationReplacesTheFirstOnlyWhenCommitted() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let restoreRoot = folder.appendingPathComponent("Restore", isDirectory: true)
        let first = try #require(DatabaseRestore.locateBackup(in: try makeBackupFolder(in: folder)))
        try prepare(first, root: restoreRoot)

        // A second backup with one more dive.
        let secondFolder = folder.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        try makeSourceStore(at: secondFolder.appendingPathComponent("default.store"))
        do {
            let container = try ModelContainer(for: Schema(BlueDiveApp.appModelTypes),
                                               configurations: ModelConfiguration(url: secondFolder.appendingPathComponent("default.store"), cloudKitDatabase: .none))
            container.mainContext.insert(Dive(diveNumber: 3, siteName: "Third"))
            try container.mainContext.save()
        }
        let second = try #require(DatabaseRestore.locateBackup(in: secondFolder))

        let abandoned = try DatabaseRestore.prepareCandidate(second, modelTypes: BlueDiveApp.appModelTypes, root: restoreRoot)
        DatabaseRestore.discardCandidate(abandoned.id, root: restoreRoot)
        #expect(DatabaseRestore.readPending(in: restoreRoot)?.entityCounts?["Dive"] == 2)
        try DatabaseRestore.ensureCleanCopy(modelTypes: BlueDiveApp.appModelTypes, root: restoreRoot)

        try prepare(second, root: restoreRoot)
        #expect(DatabaseRestore.readPending(in: restoreRoot)?.entityCounts?["Dive"] == 3)
    }

    /// Leftover folders are removed at launch only when they predate it: a preparation started
    /// right after launch is not touched.
    @Test func leftoversNewerThanTheLaunchAreKept() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let restoreRoot = folder.appendingPathComponent("Restore", isDirectory: true)
        let launch = Date().addingTimeInterval(-60)
        let candidate = restoreRoot.appendingPathComponent("candidate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)

        DatabaseRestore.removeLeftovers(before: launch, root: restoreRoot)
        #expect(FileManager.default.fileExists(atPath: candidate.path))
        DatabaseRestore.removeLeftovers(before: Date().addingTimeInterval(60), root: restoreRoot)
        #expect(!FileManager.default.fileExists(atPath: candidate.path))
    }

    @Test func theReplacedLogbookIsMeasuredAndDeletedOnlyWhenNothingIsPending() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scenario = try makeSwapScenario(in: folder)
        #expect(DatabaseRestore.replacedLogbookSize(root: scenario.restoreRoot) == nil)
        try DatabaseRestore.swap(liveStoreURL: scenario.liveURL, modelTypes: BlueDiveApp.appModelTypes, root: scenario.restoreRoot)

        // Pending (a swap in progress): kept, Cancel may need it.
        DatabaseRestore.deleteReplacedLogbook(root: scenario.restoreRoot)
        #expect((DatabaseRestore.replacedLogbookSize(root: scenario.restoreRoot) ?? 0) > 0)

        try DatabaseRestore.finish(root: scenario.restoreRoot)
        DatabaseRestore.deleteReplacedLogbook(root: scenario.restoreRoot)
        #expect(DatabaseRestore.replacedLogbookSize(root: scenario.restoreRoot) == nil)
        // The restored logbook is untouched.
        #expect(try snapshot(of: scenario.liveURL) == scenario.backup)
    }

    /// Two preparations at once (two windows) each keep their own candidate.
    @Test func twoCandidatesDoNotTouchEachOther() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let restoreRoot = folder.appendingPathComponent("Restore", isDirectory: true)
        let source = try #require(DatabaseRestore.locateBackup(in: try makeBackupFolder(in: folder)))
        let first = try DatabaseRestore.prepareCandidate(source, modelTypes: BlueDiveApp.appModelTypes, root: restoreRoot)
        let second = try DatabaseRestore.prepareCandidate(source, modelTypes: BlueDiveApp.appModelTypes, root: restoreRoot)
        #expect(first.id != second.id)
        DatabaseRestore.discardCandidate(first.id, root: restoreRoot)
        // The second is intact and can be committed.
        try DatabaseRestore.commitCandidate(second, source: source, root: restoreRoot)
        #expect(DatabaseRestore.readPending(in: restoreRoot)?.entityCounts?["Dive"] == 2)
        try DatabaseRestore.ensureCleanCopy(modelTypes: BlueDiveApp.appModelTypes, root: restoreRoot)
    }

    /// A backup whose manifest lists more external files than could be copied is refused.
    @Test func aBackupWithMissingExternalFilesIsRefused() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let restoreRoot = folder.appendingPathComponent("Restore", isDirectory: true)
        var source = try #require(DatabaseRestore.locateBackup(in: try makeBackupFolder(in: folder)))
        let files = try FileManager.default.subpathsOfDirectory(atPath: source.folder.appendingPathComponent(".default_SUPPORT").path)
            .filter { !$0.hasSuffix("_EXTERNAL_DATA") }.count
        source.manifest = BackupManifest(formatVersion: 2, createdAt: "", createdAtEpoch: 0,
                                         app: .init(version: "1", build: "1", bundleIdentifier: ""),
                                         platform: "", iCloudSyncEnabled: false,
                                         store: .init(fileName: "default.store", storeUUID: nil, storeBytes: 0,
                                                      supportFolder: ".default_SUPPORT", externalFileCount: files + 1,
                                                      externalBytes: 0, missingExternalFiles: 0),
                                         entities: nil)
        #expect(throws: DatabaseRestore.CandidateFailure.self) {
            try DatabaseRestore.prepareCandidate(source, modelTypes: BlueDiveApp.appModelTypes, root: restoreRoot)
        }
    }

    /// Erase all data removes a prepared restore and the replaced logbook.
    @Test func eraseAllRemovesThePreparedRestoreAndTheReplacedLogbook() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let scenario = try makeSwapScenario(in: folder)
        let previous = DatabaseRestore.previousFolder(in: scenario.restoreRoot)
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        try Data([1]).write(to: previous.appendingPathComponent("default.store"))
        #expect(DatabaseRestore.readPending(in: scenario.restoreRoot) != nil)
        // Pending: the replaced logbook is not offered for deletion with the temporary files.
        #expect(DatabaseRestore.deletableReplacedLogbookSize(root: scenario.restoreRoot) == nil)

        DatabaseRestore.eraseAll(root: scenario.restoreRoot)
        #expect(DatabaseRestore.readPending(in: scenario.restoreRoot) == nil)
        #expect(!FileManager.default.fileExists(atPath: scenario.restoreRoot.path))
    }

    /// A backup in iCloud Drive not downloaded yet lists its files as placeholders
    /// (`.<name>.icloud`): the backup is still found, and a file that cannot be downloaded is
    /// reported as missing instead of being copied under the placeholder's name.
    @Test func iCloudDrivePlaceholdersAreReadUnderTheirRealName() throws {
        #expect(DatabaseRestore.realName(ofPlaceholder: ".ABC.icloud") == "ABC")
        #expect(DatabaseRestore.realName(ofPlaceholder: ".icloud") == nil)
        #expect(DatabaseRestore.realName(ofPlaceholder: "ABC") == nil)

        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fm = FileManager.default
        // A store that is only a placeholder is still located.
        let pending = folder.appendingPathComponent("NotDownloaded", isDirectory: true)
        try fm.createDirectory(at: pending, withIntermediateDirectories: true)
        try Data().write(to: pending.appendingPathComponent(DatabaseRestore.placeholderName(for: "default.store")))
        #expect(DatabaseRestore.locateBackup(in: pending) != nil)

        // An external file that is only a placeholder (here it can never be downloaded).
        let restoreRoot = folder.appendingPathComponent("Restore", isDirectory: true)
        let source = try #require(DatabaseRestore.locateBackup(in: try makeBackupFolder(in: folder)))
        let external = source.folder.appendingPathComponent(".default_SUPPORT/_EXTERNAL_DATA", isDirectory: true)
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        try Data().write(to: external.appendingPathComponent(DatabaseRestore.placeholderName(for: "ABC")))
        #expect(throws: DatabaseRestore.CandidateFailure.self) {
            try DatabaseRestore.prepareCandidate(source, modelTypes: BlueDiveApp.appModelTypes, root: restoreRoot)
        }
        #expect(((try? fm.contentsOfDirectory(atPath: restoreRoot.path)) ?? []).filter { $0.hasPrefix("candidate-") }.isEmpty)
    }

    /// The size of a backup whose files are not downloaded yet comes from its manifest.
    @Test func backupSizeUsesTheManifestWhenLarger() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let parent = try makeBackupFolder(in: folder)
        let root = parent.appendingPathComponent(BackupFormat.rootFolderName)
        let onDisk = try #require(DatabaseRestore.locateBackup(in: parent)).totalBytes
        let manifest = BackupManifest(formatVersion: 2, createdAt: "", createdAtEpoch: 0,
                                      app: .init(version: "1", build: "1", bundleIdentifier: ""),
                                      platform: "", iCloudSyncEnabled: false,
                                      store: .init(fileName: "default.store", storeUUID: nil, storeBytes: 1_000_000_000,
                                                   supportFolder: ".default_SUPPORT", externalFileCount: 0,
                                                   externalBytes: 2_000_000_000, missingExternalFiles: 0),
                                      entities: nil)
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent(BackupFormat.manifestFileName))
        #expect(DatabaseRestore.locateBackup(in: parent)?.totalBytes == 3_000_000_000)
        #expect(onDisk < 3_000_000_000)
    }

    // MARK: - Real backup (optional)

    nonisolated static let testerHome = URL(fileURLWithPath:
        ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory())

    /// An unzipped backup (`BlueDive Backup/` folder) the tester placed outside the repository.
    nonisolated static let realBackup = testerHome.appendingPathComponent("BlueDive-Fixtures/restore/BlueDive Backup")

    /// A real backup taken from an iCloud-synced store carries Core Data's real mirroring tables:
    /// the clean store must have none of them and every record of the backup.
    @Test(.enabled(if: FileManager.default.fileExists(
        atPath: realBackup.appendingPathComponent("default.store").path)))
    func cleanStoreFromARealBackup() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.copyItem(at: Self.realBackup, to: copy)
        let sourceURL = copy.appendingPathComponent("default.store")
        let mirroring = DatabaseRestore.mirroringTableNames(at: sourceURL)
        print("Real backup mirroring tables: \(mirroring.sorted())")
        let sourceMetadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: sourceURL)
        print("Real backup metadata keys: \(sourceMetadata.keys.sorted())")

        let outFolder = folder.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)
        let outURL = outFolder.appendingPathComponent("default.store")
        let start = Date()
        let report = try DatabaseRestore.makeCleanStore(from: sourceURL, to: outURL,
                                                        modelTypes: BlueDiveApp.appModelTypes)
        print("Clean store in \(Date().timeIntervalSince(start)) s; removed metadata keys: \(report.removedMetadataKeys)")
        print("Counts: \(report.entityCounts.sorted { $0.key < $1.key })")

        #expect(DatabaseRestore.mirroringTableNames(at: outURL).isEmpty)
        #expect(try snapshot(of: outURL) == snapshot(of: sourceURL))
        _ = try ModelContainer(for: Schema(BlueDiveApp.appModelTypes),
                               configurations: ModelConfiguration(url: outURL, cloudKitDatabase: .none))
    }
}
