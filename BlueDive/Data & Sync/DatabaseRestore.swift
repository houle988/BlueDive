import Foundation
import CoreData
import SwiftData
import SQLite3
import CloudKit
import os

// MARK: - Clean Store

/// Restores a database backup by swapping in a clean copy of its store.
///
/// A backup's `default.store` still holds the iCloud mirroring state it had when it was taken:
/// Core Data's CloudKit tables (`ANSCK…`) and its persistent history. Swapping that file in as
/// it is would make the mirroring believe its records are already in iCloud. `makeCleanStore`
/// therefore writes a new store through a coordinator built from the app's own model only:
/// `migratePersistentStore` copies the app's entities, their relationships and their
/// external-storage files, and none of the mirroring tables, which are not part of that model.
/// The store metadata is then reduced to the keys of a plain store of the same model, with a new
/// store UUID, so the result is a store the mirroring has never seen. Every value is copied by
/// Core Data unchanged.
nonisolated enum DatabaseRestore {

    private static let logger = Logger(subsystem: "com.bluedive.app", category: "Restore")

    enum Failure: Error {
        case modelUnavailable
        case sourceUnreadable(Error)
        case migrationFailed(Error)
        case metadataFailed(Error)
    }

    struct CleanStoreReport: Sendable {
        /// Record count per entity in the new store.
        var entityCounts: [String: Int]
        /// Metadata keys of the backup that a plain store does not have (mirroring state).
        var removedMetadataKeys: [String]
        /// The new store's UUID (never the backup's).
        var storeUUID: String
    }

    /// Writes a clean copy of the store at `sourceURL` to `destinationURL` (which must not exist).
    ///
    /// The source is opened writable, with lightweight migration, so a backup made with an older
    /// model is brought to the current one: pass a copy, never the user's only file. Name the
    /// destination `default.store` so its external-storage folder is `.default_SUPPORT`, as the
    /// live store's. `modelTypes` is `BlueDiveApp.appModelTypes`, read on the main actor.
    static func makeCleanStore(from sourceURL: URL,
                               to destinationURL: URL,
                               modelTypes: [any PersistentModel.Type]) throws(Failure) -> CleanStoreReport {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: modelTypes) else {
            throw .modelUnavailable
        }

        // 1. Copy the app's entities into a new store.
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let source: NSPersistentStore
        do {
            source = try coordinator.addPersistentStore(
                type: .sqlite, at: sourceURL,
                options: [NSPersistentHistoryTrackingKey: true,
                          NSMigratePersistentStoresAutomaticallyOption: true,
                          NSInferMappingModelAutomaticallyOption: true])
        } catch {
            logger.error("Restore: backup store not opened: \(error.localizedDescription, privacy: .public)")
            throw .sourceUnreadable(error)
        }
        let counts: [String: Int]
        do {
            let destination = try coordinator.migratePersistentStore(
                source, to: destinationURL,
                options: [NSPersistentHistoryTrackingKey: true], type: .sqlite)
            // The migrated store replaced the source on the coordinator: it is the only one.
            counts = entityCounts(coordinator: coordinator)
            try coordinator.remove(destination)
        } catch {
            logger.error("Restore: clean copy failed: \(error.localizedDescription, privacy: .public)")
            throw .migrationFailed(error)
        }

        // 2. Keep only the metadata keys a plain store of this model has, with a new store UUID.
        let removed: [String]
        let uuid = UUID().uuidString
        do {
            let plainKeys = try plainStoreMetadataKeys(model: model)
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                type: .sqlite, at: destinationURL)
            var kept = metadata.filter { plainKeys.contains($0.key) }
            removed = metadata.keys.filter { !plainKeys.contains($0) }.sorted()
            kept[NSStoreUUIDKey] = uuid
            try NSPersistentStoreCoordinator.setMetadata(kept, type: .sqlite, at: destinationURL)
        } catch {
            logger.error("Restore: metadata not reset: \(error.localizedDescription, privacy: .public)")
            throw .metadataFailed(error)
        }
        if !removed.isEmpty {
            logger.info("Restore: removed metadata keys \(removed.joined(separator: ", "), privacy: .public)")
        }
        return CleanStoreReport(entityCounts: counts, removedMetadataKeys: removed, storeUUID: uuid)
    }

    /// Names of the tables in the SQLite file at `url`, read without Core Data (read-only).
    /// Used to check that a clean store has no mirroring (`ANSCK…`) table.
    static func tableNames(at url: URL) -> Set<String> {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &statement, nil) == SQLITE_OK
        else { return [] }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { names.insert(String(cString: text)) }
        }
        return names
    }

    /// Mirroring tables of NSPersistentCloudKitContainer found in the store at `url`.
    static func mirroringTableNames(at url: URL) -> Set<String> {
        tableNames(at: url).filter { $0.hasPrefix("ANSCK") }
    }

    // MARK: Helpers

    /// The metadata keys Core Data writes for a new, empty store of `model` with history tracking.
    private static func plainStoreMetadataKeys(model: NSManagedObjectModel) throws -> Set<String> {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlueDiveRestorePlain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("default.store")
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(
            type: .sqlite, at: url, options: [NSPersistentHistoryTrackingKey: true])
        let keys = Set(coordinator.metadata(for: store).keys)
        try coordinator.remove(store)
        return keys
    }

    private static func entityCounts(coordinator: NSPersistentStoreCoordinator) -> [String: Int] {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context.performAndWait {
            var counts: [String: Int] = [:]
            for name in coordinator.managedObjectModel.entities.compactMap(\.name) {
                let request = NSFetchRequest<NSFetchRequestResult>(entityName: name)
                counts[name] = (try? context.count(for: request)) ?? 0
            }
            return counts
        }
    }
}

// MARK: - Backup Folder

/// An unzipped backup the user picked: the folder holding its `default.store`.
nonisolated struct RestoreSource: Sendable {
    /// The folder holding the store, its `-wal`/`-shm` files and `.default_SUPPORT`.
    var folder: URL
    /// Format 2 backups only (format 1 has no manifest).
    var manifest: BackupManifest?
    var hasSupportFolder: Bool
    /// Store files and external files, in bytes.
    var totalBytes: Int64
}

/// A restore prepared in the app and run at the next launch (restore mode). Written next to the
/// staged backup; its presence is what starts restore mode.
nonisolated struct PendingRestore: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        /// The backup is staged; the live store is untouched.
        case staged
        /// The live store is being replaced (moved to `previous`, then the clean copy put in place).
        case swapping
    }
    var preparedAt: Date
    var backupCreatedAt: String?
    var backupAppVersion: String?
    var entityCounts: [String: Int]?
    var phase: Phase
    /// The live store items (store files, external-file folder) that existed when the swap
    /// began, recorded before any of them is moved. An item listed here is the user's logbook
    /// until it is in `previous`; an item not listed here is new (written by the swap). Retry and
    /// cancel rely on it so they never delete an item that was not moved.
    var originalLiveItems: [String]?
}

nonisolated extension DatabaseRestore {

    static let storeFileName = "default.store"
    static let supportFolderName = ".default_SUPPORT"

    /// The backup's store inside the folder the user picked: the `BlueDive Backup` folder itself,
    /// the folder the zip was unzipped into, or a format 1 `BlueDiveBackup-<UUID>` folder.
    static func locateBackup(in picked: URL) -> RestoreSource? {
        let fm = FileManager.default
        var candidates = [picked, picked.appendingPathComponent(BackupFormat.rootFolderName, isDirectory: true)]
        if let names = try? fm.contentsOfDirectory(atPath: picked.path) {
            candidates += names.filter { $0.hasPrefix("BlueDiveBackup-") }.sorted()
                .map { picked.appendingPathComponent($0, isDirectory: true) }
        }
        // The store may still be in iCloud Drive only, listed as its download placeholder.
        guard let folder = candidates.first(where: {
            fm.fileExists(atPath: $0.appendingPathComponent(storeFileName).path)
                || fm.fileExists(atPath: $0.appendingPathComponent(placeholderName(for: storeFileName)).path)
        }) else { return nil }
        let manifest = (try? Data(contentsOf: folder.appendingPathComponent(BackupFormat.manifestFileName)))
            .flatMap { try? JSONDecoder().decode(BackupManifest.self, from: $0) }
        let support = folder.appendingPathComponent(supportFolderName, isDirectory: true)
        // Files still in iCloud Drive only take almost no space on disk: the manifest's sizes
        // (format 2) keep the size shown and the free-space check from coming out too small.
        let manifestBytes = manifest.map { $0.store.storeBytes + $0.store.externalBytes } ?? 0
        return RestoreSource(folder: folder, manifest: manifest,
                             hasSupportFolder: fm.fileExists(atPath: support.path),
                             totalBytes: max(byteCount(of: folder), manifestBytes))
    }

    /// True when the backup was made by a newer build than this one: its model may have
    /// attributes this version does not know, so it is not restored.
    static func isFromNewerBuild(_ manifest: BackupManifest?, currentBuild: String) -> Bool {
        guard let backup = manifest.flatMap({ Int($0.app.build) }), let current = Int(currentBuild) else { return false }
        return backup > current
    }

    // MARK: Staging

    /// `Application Support/BlueDive Restore`: the staged backup, the marker, the clean copy and
    /// the logbook the restore replaced (`previous`). Excluded from device backups.
    static var defaultRestoreFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BlueDive Restore", isDirectory: true)
    }

    private static func markerURL(in root: URL) -> URL { root.appendingPathComponent("pending.json") }
    private static func stagedFolder(in root: URL) -> URL { root.appendingPathComponent("staged", isDirectory: true) }
    private static func cleanFolder(in root: URL) -> URL { root.appendingPathComponent("clean", isDirectory: true) }
    /// The logbook this device had before the restore (its store files and external files).
    static func previousFolder(in root: URL = defaultRestoreFolder) -> URL {
        root.appendingPathComponent("previous", isDirectory: true)
    }

    static func readPending(in root: URL = defaultRestoreFolder) -> PendingRestore? {
        guard let data = try? Data(contentsOf: markerURL(in: root)) else { return nil }
        return try? JSONDecoder().decode(PendingRestore.self, from: data)
    }

    /// Internal, not private: the tests write a marker to simulate an interrupted swap.
    static func writePending(_ pending: PendingRestore, in root: URL) throws {
        try JSONEncoder().encode(pending).write(to: markerURL(in: root), options: .atomic)
    }

    /// Free space needed to stage `source` and restore it: the staged copy, the clean copy and
    /// the restored store exist at the same time (the replaced logbook is moved, not copied).
    static func spaceNeeded(for source: RestoreSource) -> Int64 {
        3 * source.totalBytes + 100_000_000
    }

    static func availableSpace(at url: URL = defaultRestoreFolder) -> Int64? {
        let existing = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        return (try? existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// The candidate of a restore being prepared: the backup copied once and migrated once into
    /// its clean copy, before the user confirms anything. Each preparation has its own folder
    /// (`candidate-<UUID>`), private to its sheet until `commitCandidate` makes it the pending
    /// restore, so two preparations (two Mac windows, a sheet closed while another opens) never
    /// touch each other's files.
    private static let candidatePrefix = "candidate-"
    private static func candidateFolder(_ id: UUID, in root: URL) -> URL {
        root.appendingPathComponent(candidatePrefix + id.uuidString, isDirectory: true)
    }

    /// A prepared candidate: its folder's id and its clean copy's record counts.
    struct Candidate: Sendable {
        let id: UUID
        let report: CleanStoreReport
    }

    enum CandidateFailure: Error {
        /// Fewer external files (photos, images, attachment files) could be copied than the backup
        /// lists: some were missing (e.g. not downloaded from iCloud Drive).
        case missingExternalFiles(copied: Int, expected: Int)
    }

    /// Copies the backup into a new candidate folder (each file through its own coordinated read)
    /// and makes its clean copy there (`makeCleanStore`), deleting the copied backup afterwards.
    /// Throws, leaving nothing behind, when the backup does not open or migrate to the current
    /// model, or when fewer external files could be copied than its manifest lists — before the
    /// user deletes anything on the other devices or in iCloud. A restore already prepared is not
    /// touched. Stops between files when the calling task is cancelled (the sheet was closed).
    /// The caller holds the security scope of `source.folder`.
    static func prepareCandidate(_ source: RestoreSource, modelTypes: [any PersistentModel.Type],
                                 root: URL = defaultRestoreFolder) throws -> Candidate {
        let fm = FileManager.default
        let id = UUID()
        let candidate = candidateFolder(id, in: root)
        let backup = candidate.appendingPathComponent("backup", isDirectory: true)
        let clean = candidate.appendingPathComponent("clean", isDirectory: true)
        do {
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            try fm.createDirectory(at: clean, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var rootURL = root
            try? rootURL.setResourceValues(values)
            try copyBackupFiles(from: source.folder, to: backup)
            if let expected = source.manifest?.store.externalFileCount {
                let copied = regularFileCount(in: backup.appendingPathComponent(supportFolderName, isDirectory: true))
                guard copied >= expected else {
                    throw CandidateFailure.missingExternalFiles(copied: copied, expected: expected)
                }
            }
            try Task.checkCancellation()
            // The copy is migrated in place: it is only the source of the clean copy.
            let report = try makeCleanStore(from: backup.appendingPathComponent(storeFileName),
                                            to: clean.appendingPathComponent(storeFileName), modelTypes: modelTypes)
            guard mirroringTableNames(at: clean.appendingPathComponent(storeFileName)).isEmpty else {
                throw Failure.migrationFailed(CocoaError(.fileWriteUnknown))
            }
            try? fm.removeItem(at: backup)
            return Candidate(id: id, report: report)
        } catch {
            try? fm.removeItem(at: candidate)
            throw error
        }
    }

    /// Makes a candidate the pending restore: the next launch starts in restore mode. A restore
    /// prepared earlier is replaced in a safe order: its marker goes first, so an interruption
    /// never leaves a marker over a half-replaced clean copy. The replaced logbook of an earlier
    /// restore (`previous`) is kept until the next swap.
    static func commitCandidate(_ candidate: Candidate, source: RestoreSource,
                                root: URL = defaultRestoreFolder) throws {
        let fm = FileManager.default
        let folder = candidateFolder(candidate.id, in: root)
        let candidateClean = folder.appendingPathComponent("clean", isDirectory: true)
        guard fm.fileExists(atPath: candidateClean.appendingPathComponent(storeFileName).path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        if fm.fileExists(atPath: markerURL(in: root).path) {
            try fm.removeItem(at: markerURL(in: root))
        }
        for old in [stagedFolder(in: root), cleanFolder(in: root)] where fm.fileExists(atPath: old.path) {
            try fm.removeItem(at: old)
        }
        try fm.moveItem(at: candidateClean, to: cleanFolder(in: root))
        try? fm.removeItem(at: folder)
        let pending = PendingRestore(preparedAt: Date(), backupCreatedAt: source.manifest?.createdAt,
                                     backupAppVersion: source.manifest?.app.version,
                                     entityCounts: candidate.report.entityCounts, phase: .staged)
        try writePending(pending, in: root)
    }

    /// Deletes a candidate the user did not commit (the preparation sheet was closed).
    static func discardCandidate(_ id: UUID, root: URL = defaultRestoreFolder) {
        try? FileManager.default.removeItem(at: candidateFolder(id, in: root))
    }

    // MARK: Restore Mode

    /// Makes sure the clean copy the swap puts in place is there: the one made while preparing
    /// (checked: no mirroring table), else, for a restore prepared by an earlier build (a staged
    /// backup without a clean copy), it is made now.
    static func ensureCleanCopy(modelTypes: [any PersistentModel.Type],
                                root: URL = defaultRestoreFolder) throws(Failure) {
        let cleanStore = cleanFolder(in: root).appendingPathComponent(storeFileName)
        if FileManager.default.fileExists(atPath: cleanStore.path) {
            guard mirroringTableNames(at: cleanStore).isEmpty else {
                throw .migrationFailed(CocoaError(.fileReadCorruptFile))
            }
            return
        }
        guard FileManager.default.fileExists(atPath: stagedFolder(in: root).appendingPathComponent(storeFileName).path) else {
            throw .sourceUnreadable(CocoaError(.fileReadNoSuchFile))
        }
        _ = try makeCleanCopyOfStagedBackup(modelTypes: modelTypes, root: root)
    }

    /// Writes the clean copy of the staged backup (`makeCleanStore`), replacing an earlier one.
    /// Used for restores prepared by an earlier build, and by the tests.
    static func makeCleanCopyOfStagedBackup(modelTypes: [any PersistentModel.Type],
                                            root: URL = defaultRestoreFolder) throws(Failure) -> CleanStoreReport {
        let clean = cleanFolder(in: root)
        try? FileManager.default.removeItem(at: clean)
        do {
            try FileManager.default.createDirectory(at: clean, withIntermediateDirectories: true)
        } catch {
            throw .migrationFailed(error)
        }
        // The clean copy is made from a scratch copy of the staged store: migrating opens its
        // source writable, and the staged copy must stay as it was if the restore is run again.
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try FileManager.default.copyItem(at: stagedFolder(in: root), to: scratch)
        } catch {
            throw .sourceUnreadable(error)
        }
        let report = try makeCleanStore(from: scratch.appendingPathComponent(storeFileName),
                                        to: clean.appendingPathComponent(storeFileName),
                                        modelTypes: modelTypes)
        guard mirroringTableNames(at: clean.appendingPathComponent(storeFileName)).isEmpty else {
            throw .migrationFailed(CocoaError(.fileWriteUnknown))
        }
        return report
    }

    /// True when the app's private iCloud database still holds a zone other than the default one
    /// (the zone Core Data syncs into). Throws when iCloud cannot be reached.
    static func iCloudHasData(containerIdentifier: String) async throws -> Bool {
        let container = CKContainer(identifier: containerIdentifier)
        switch try await container.accountStatus() {
        case .available:
            break
        case .noAccount:
            throw CKError(.notAuthenticated)
        default:
            // Restricted, temporarily unavailable or undetermined: signed in, but not usable now.
            throw CKError(.accountTemporarilyUnavailable)
        }
        let zones = try await container.privateCloudDatabase.allRecordZones()
        // Zone names only (e.g. Core Data's zone), never records: shows what the check saw.
        let names = zones.map(\.zoneID.zoneName).sorted().joined(separator: ", ")
        logger.info("Restore: iCloud zones: \(names, privacy: .public)")
        return zones.contains { $0.zoneID.zoneName != CKRecordZone.ID.defaultZoneName }
    }

    /// Replaces the live store with the clean copy. The live store (closed: restore mode never
    /// opens it) is moved with its external files to `previous`, then the clean copy is put in
    /// its place with `replacePersistentStore`.
    ///
    /// The live items that exist are recorded in the marker before any is moved
    /// (`originalLiveItems`). Run again after an interruption or a failure, it moves the original
    /// items not moved yet, deletes only items that are new (in `previous` already, or not
    /// original), and puts the clean copy in place again: an item of the user's logbook is never
    /// deleted, only moved.
    static func swap(liveStoreURL: URL, modelTypes: [any PersistentModel.Type],
                     root: URL = defaultRestoreFolder) throws {
        let fm = FileManager.default
        guard var pending = readPending(in: root),
              let model = NSManagedObjectModel.makeManagedObjectModel(for: modelTypes) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let liveFolder = liveStoreURL.deletingLastPathComponent()
        let liveItems = liveItemNames(for: liveStoreURL)
        let previous = previousFolder(in: root)

        if pending.phase == .staged {
            // The logbook an earlier restore replaced makes way for this one's. Its removal must
            // succeed: a leftover item there would be taken for one this swap already moved.
            if fm.fileExists(atPath: previous.path) {
                try fm.removeItem(at: previous)
            }
            guard !fm.fileExists(atPath: previous.path) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            pending.originalLiveItems = liveItems.filter { fm.fileExists(atPath: liveFolder.appendingPathComponent($0).path) }
            pending.phase = .swapping
            try writePending(pending, in: root)
        }
        // A marker without the list (an earlier build) treats every live item as the user's.
        let original = Set(pending.originalLiveItems ?? liveItems)
        try fm.createDirectory(at: previous, withIntermediateDirectories: true)
        for name in liveItems {
            let live = liveFolder.appendingPathComponent(name)
            let kept = previous.appendingPathComponent(name)
            guard fm.fileExists(atPath: live.path) else { continue }
            if original.contains(name) && !fm.fileExists(atPath: kept.path) {
                // Part of the user's logbook, not moved yet.
                try fm.moveItem(at: live, to: kept)
            } else {
                // Written by an earlier attempt of this swap.
                try fm.removeItem(at: live)
            }
        }

        try fm.createDirectory(at: liveFolder, withIntermediateDirectories: true)
        let clean = cleanFolder(in: root)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.replacePersistentStore(
            at: liveStoreURL, destinationOptions: [NSPersistentHistoryTrackingKey: true],
            withPersistentStoreFrom: clean.appendingPathComponent(storeFileName),
            sourceOptions: [NSPersistentHistoryTrackingKey: true], type: .sqlite)
        // The external files, unless `replacePersistentStore` already brought them.
        let cleanSupport = clean.appendingPathComponent(supportFolderName)
        let destinationSupport = liveFolder.appendingPathComponent(supportFolderName(forStoreAt: liveStoreURL))
        if fm.fileExists(atPath: cleanSupport.path) {
            try copyMissingItems(from: cleanSupport, to: destinationSupport)
        }
    }

    /// Ends restore mode once the swap is done. The marker goes first: an interruption after it
    /// leaves only working folders, which the next launch removes (`removeLeftovers`), never a
    /// marker without its staged backup. The replaced logbook (`previous`) is kept. Throws, and
    /// keeps the clean copy, when the marker cannot be removed: the next launch would otherwise
    /// be in restore mode with nothing to restore (running the swap again is safe).
    static func finish(root: URL = defaultRestoreFolder) throws {
        let fm = FileManager.default
        let marker = markerURL(in: root)
        if fm.fileExists(atPath: marker.path) {
            try fm.removeItem(at: marker)
        }
        removeWorkingItems(in: root)
    }

    /// Cancels a pending restore. A swap already started is undone: every original item moved to
    /// `previous` is put back, an original item not moved yet stays where it is, and an item the
    /// swap wrote is deleted. The marker is removed last, so a failed cancel can run again.
    static func cancel(liveStoreURL: URL, root: URL = defaultRestoreFolder) throws {
        let fm = FileManager.default
        if let pending = readPending(in: root), pending.phase == .swapping {
            let liveFolder = liveStoreURL.deletingLastPathComponent()
            let previous = previousFolder(in: root)
            let liveItems = liveItemNames(for: liveStoreURL)
            // A marker without the list (an earlier build) treats every live item as the user's.
            let original = Set(pending.originalLiveItems ?? liveItems)
            for name in liveItems {
                let live = liveFolder.appendingPathComponent(name)
                let kept = previous.appendingPathComponent(name)
                if fm.fileExists(atPath: kept.path) {
                    try? fm.removeItem(at: live)
                    try fm.moveItem(at: kept, to: live)
                } else if !original.contains(name) {
                    try? fm.removeItem(at: live)
                }
            }
            // Everything was put back: an empty `previous` would show as a replaced logbook.
            if (try? fm.contentsOfDirectory(atPath: previous.path))?.isEmpty == true {
                try? fm.removeItem(at: previous)
            }
        }
        try? fm.removeItem(at: markerURL(in: root))
        removeWorkingItems(in: root)
    }

    /// Removes the working folders a restore left (the app was stopped while preparing, or after
    /// `finish` removed the marker). Run at launch, off the main thread: only folders last
    /// changed before `launchDate` are removed, so a preparation started right after launch is
    /// never touched. A pending restore's staged backup and clean copy are kept.
    static func removeLeftovers(before launchDate: Date, root: URL = defaultRestoreFolder) {
        let pending = readPending(in: root) != nil
        for folder in workingFolders(in: root) {
            if pending && (folder == stagedFolder(in: root) || folder == cleanFolder(in: root)) { continue }
            guard let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified < launchDate else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Replaced Logbook

    /// The size of the logbook a restore replaced (`previous`), in bytes; nil when there is none.
    static func replacedLogbookSize(root: URL = defaultRestoreFolder) -> Int64? {
        let previous = previousFolder(in: root)
        guard FileManager.default.fileExists(atPath: previous.path) else { return nil }
        return byteCount(of: previous)
    }

    /// The replaced logbook's size when it can be deleted (no restore pending); nil otherwise.
    static func deletableReplacedLogbookSize(root: URL = defaultRestoreFolder) -> Int64? {
        readPending(in: root) == nil ? replacedLogbookSize(root: root) : nil
    }

    /// Removes everything the restore feature keeps on the device: a prepared restore (staged or
    /// clean copy and its marker), candidates and the replaced logbook. For Erase all data, which
    /// runs only in the normal interface (no swap in progress).
    static func eraseAll(root: URL = defaultRestoreFolder) {
        try? FileManager.default.removeItem(at: root)
    }

    /// Deletes the logbook a restore replaced. Never while a restore is pending: a swap may
    /// still need it (Cancel puts it back).
    static func deleteReplacedLogbook(root: URL = defaultRestoreFolder) {
        guard readPending(in: root) == nil else { return }
        try? FileManager.default.removeItem(at: previousFolder(in: root))
    }

    // MARK: File Helpers

    /// The external-storage folder Core Data keeps beside a store: `.<store name>_SUPPORT`.
    static func supportFolderName(forStoreAt storeURL: URL) -> String {
        "." + storeURL.deletingPathExtension().lastPathComponent + "_SUPPORT"
    }

    /// The live store's items: the store, its `-wal`/`-shm` files and its external-file folder.
    private static func liveItemNames(for liveStoreURL: URL) -> [String] {
        let name = liveStoreURL.lastPathComponent
        return [name, name + "-wal", name + "-shm", supportFolderName(forStoreAt: liveStoreURL)]
    }

    /// The restore's working folders: the staged backup, the clean copy, the scratch copy and
    /// the candidate. Not the replaced logbook (`previous`) or the marker.
    private static func workingFolders(in root: URL) -> [URL] {
        let candidates = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix(candidatePrefix) }
            .map { root.appendingPathComponent($0, isDirectory: true) }
        return [stagedFolder(in: root), cleanFolder(in: root), root.appendingPathComponent("scratch", isDirectory: true)]
            + candidates
    }

    private static func removeWorkingItems(in root: URL) {
        for folder in workingFolders(in: root) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Copies a backup's store files and external files from `folder` to `destination`, each
    /// file through a coordinated read, which makes a file kept in iCloud Drive available before
    /// it is copied (a coordinated read of the folder alone does not download its contents).
    /// A file not downloaded yet may be listed as its placeholder (`.<name>.icloud`): it is read,
    /// and copied, under its real name. Throws `CandidateFailure.missingExternalFiles` when such
    /// a file cannot be read (not downloaded).
    private static func copyBackupFiles(from folder: URL, to destination: URL) throws {
        let fm = FileManager.default
        var files: [(source: URL, relative: String, isPlaceholder: Bool)] = []
        for name in [storeFileName, storeFileName + "-wal", storeFileName + "-shm"] {
            if fm.fileExists(atPath: folder.appendingPathComponent(name).path) {
                files.append((folder.appendingPathComponent(name), name, false))
            } else if fm.fileExists(atPath: folder.appendingPathComponent(placeholderName(for: name)).path) {
                files.append((folder.appendingPathComponent(name), name, true))
            }
        }
        let support = folder.appendingPathComponent(supportFolderName, isDirectory: true)
        let base = support.standardizedFileURL.path
        if let enumerator = fm.enumerator(at: support, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator
            where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
                if let realName = realName(ofPlaceholder: url.lastPathComponent) {
                    let realURL = url.deletingLastPathComponent().appendingPathComponent(realName)
                    // Listed once even if both the file and its placeholder are seen.
                    guard !fm.fileExists(atPath: realURL.path) else { continue }
                    let realRelative = (relative as NSString).deletingLastPathComponent
                    files.append((realURL, supportFolderName + "/" + (realRelative.isEmpty ? realName : realRelative + "/" + realName), true))
                } else {
                    files.append((url, supportFolderName + "/" + relative, false))
                }
            }
        }
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let target = destination.appendingPathComponent(file.relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: file.source, options: [], error: &coordinationError) { readable in
                do { try fm.copyItem(at: readable, to: target) } catch { copyError = error }
            }
            if let error = coordinationError ?? copyError {
                // A placeholder whose file could not be downloaded: the backup is incomplete here.
                if file.isPlaceholder {
                    logger.error("Restore: a file of the backup is not downloaded: \(error.localizedDescription, privacy: .public)")
                    throw CandidateFailure.missingExternalFiles(copied: index, expected: files.count)
                }
                throw error
            }
        }
    }

    /// The name iCloud Drive lists a file under while it is not downloaded: `.<name>.icloud`.
    static func placeholderName(for name: String) -> String { "." + name + ".icloud" }

    /// The real name of an iCloud Drive placeholder (`.<name>.icloud`), nil for any other name.
    static func realName(ofPlaceholder name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".".count + ".icloud".count else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    /// Copies every file under `source` that `destination` does not have yet.
    private static func copyMissingItems(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        let base = source.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            let target = destination.appendingPathComponent(relative)
            guard !fm.fileExists(atPath: target.path) else { continue }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: target)
        }
    }

    private static func regularFileCount(in folder: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var count = 0
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            count += 1
        }
        return count
    }

    private static func byteCount(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
