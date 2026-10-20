import Foundation
import CoreData
import SwiftData
import os

// MARK: - Backup Format

/// Layout of a database backup (Settings → Data Management → Backup database).
///
/// Format 2 (this version): `BlueDive-Backup-yyyy-MM-dd-HHmm.zip` containing
/// ```
/// BlueDive Backup/
///   manifest.json          — `BackupManifest`
///   default.store          — consistent snapshot (`replacePersistentStore`), may have -wal/-shm
///   .default_SUPPORT/      — `@Attribute(.externalStorage)` files (photo originals, large images)
/// ```
/// Format 1 (before this version): `BlueDive-Backup-yyyy-MM-dd.zip` containing
/// `BlueDiveBackup-<UUID>/` with `default.store` and its `-wal`/`-shm`/`-journal` files copied
/// raw from the open store, and no manifest. Backups from the shipped v1.9.x releases have no
/// `.default_SUPPORT` folder; those from builds of commit 63f3f51 may have one under the same
/// root. A restore recognises format 2 by its manifest and looks for the support folder in both.
nonisolated enum BackupFormat {
    static let formatVersion = 2
    static let rootFolderName = "BlueDive Backup"
    static let manifestFileName = "manifest.json"
}

// MARK: - Manifest

/// Describes a backup, so a restore can check it before reading it.
nonisolated struct BackupManifest: Codable, Sendable {
    struct App: Codable, Sendable {
        var version: String
        var build: String
        var bundleIdentifier: String
    }
    struct Store: Codable, Sendable {
        var fileName: String
        var storeUUID: String?
        var storeBytes: Int64
        var supportFolder: String
        var externalFileCount: Int
        var externalBytes: Int64
        /// External files the snapshot may reference that disappeared from the live store during
        /// the copy (a photo deleted meanwhile, here or by iCloud): 0 in a complete backup.
        var missingExternalFiles: Int
    }

    var formatVersion: Int
    /// ISO 8601 with the device's UTC offset (self-describing, unlike the XML's local times).
    var createdAt: String
    var createdAtEpoch: Double
    var app: App
    var platform: String
    var iCloudSyncEnabled: Bool
    var store: Store
    /// Record count per entity, counted on the snapshot itself; nil when the snapshot could not
    /// be opened for counting (the backup itself is still complete).
    var entities: [String: Int]?
}

// MARK: - Backup Builder

/// Builds a database backup off the main thread.
///
/// The live store is never copied file by file (a save by another context during the copy —
/// an iCloud import, a photo import — would leave a torn database): the database is copied with
/// `replacePersistentStore`, Core Data's supported way to copy a store that is in use, then the
/// external-storage folder is copied. Core Data writes an external file before it commits the
/// row that references it, so every file the snapshot references already exists when the folder
/// is copied afterwards; files added later are unreferenced extras.
nonisolated enum DatabaseBackup {

    private static let logger = Logger(subsystem: "com.bluedive.app", category: "Backup")

    enum Failure: Error {
        case snapshotFailed, insufficientSpace(needed: Int64), copyFailed, manifestFailed, archiveFailed, cancelled
    }

    enum Phase: Sendable, Equatable {
        case preparing
        case copyingFiles(done: Int, total: Int)
        case compressing
        /// macOS: the archive is being moved or copied where the user chose (shown by the caller).
        case saving
    }

    /// Creates the zip in a temporary folder of its own and returns it with its file name.
    /// `modelTypes` is `BlueDiveApp.appModelTypes`, read on the main actor by the caller.
    static func build(liveStoreURL: URL,
                      modelTypes: [any PersistentModel.Type],
                      iCloudSyncEnabled: Bool,
                      progress: @Sendable (Phase) -> Void) -> Result<(url: URL, name: String), Failure> {
        let fm = FileManager.default
        let storeName = liveStoreURL.lastPathComponent
        let supportName = "." + liveStoreURL.deletingPathExtension().lastPathComponent + "_SUPPORT"
        let supportSource = liveStoreURL.deletingLastPathComponent().appendingPathComponent(supportName)

        // Free space: the staging copy and the zip exist at the same time (photos hardly compress).
        let storeBytes = ["", "-wal", "-shm"].reduce(Int64(0)) { sum, suffix in
            sum + fileSize(liveStoreURL.deletingLastPathComponent().appendingPathComponent(storeName + suffix))
        }
        let supportBytes = externalFiles(in: supportSource).reduce(Int64(0)) { $0 + $1.bytes }
        let needed = 2 * (storeBytes + supportBytes) + 100_000_000
        if let available = availableSpace(at: fm.temporaryDirectory), available < needed {
            return .failure(.insufficientSpace(needed: needed))
        }

        let staging = fm.temporaryDirectory.appendingPathComponent("BlueDiveBackup-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        let root = staging.appendingPathComponent(BackupFormat.rootFolderName)
        guard (try? fm.createDirectory(at: root, withIntermediateDirectories: true)) != nil,
              let model = NSManagedObjectModel.makeManagedObjectModel(for: modelTypes) else {
            return .failure(.snapshotFailed)
        }

        // 1. Consistent snapshot of the database (no CloudKit options: nothing mirrors).
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let snapshotURL = root.appendingPathComponent(storeName)
        do {
            try coordinator.replacePersistentStore(
                at: snapshotURL,
                destinationOptions: [NSSQLitePragmasOption: ["journal_mode": "DELETE"]],
                withPersistentStoreFrom: liveStoreURL,
                sourceOptions: [NSReadOnlyPersistentStoreOption: true,
                                NSPersistentHistoryTrackingKey: true],
                type: .sqlite)
        } catch {
            logger.error("Backup snapshot failed: \(error.localizedDescription, privacy: .public)")
            return .failure(.snapshotFailed)
        }
        if Task.isCancelled { return .failure(.cancelled) }

        // 2. External-storage files, listed after the snapshot (see the type's comment). A file
        // deleted from the live store meanwhile is skipped and counted: its record was deleted in
        // the live store, but the snapshot taken before still has it, so the backup lacks that
        // file (`missingExternalFiles`). `replacePersistentStore` may
        // already have copied the support folder with the snapshot: a file present there is kept
        // (it belongs to the snapshot) and only the missing ones are copied.
        let files = externalFiles(in: supportSource)
        var copiedCount = 0
        var missingCount = 0
        var copiedBytes: Int64 = 0
        progress(.copyingFiles(done: 0, total: files.count))
        for (index, file) in files.enumerated() {
            if Task.isCancelled { return .failure(.cancelled) }
            let destination = root.appendingPathComponent(supportName).appendingPathComponent(file.relativePath)
            if fm.fileExists(atPath: destination.path) {
                copiedCount += 1
                copiedBytes += fileSize(destination)
            } else {
                do {
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: file.url, to: destination)
                    copiedCount += 1
                    copiedBytes += file.bytes
                } catch {
                    guard !fm.fileExists(atPath: file.url.path) else {
                        logger.error("Backup could not copy \(file.relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        return .failure(.copyFailed)
                    }
                    missingCount += 1
                }
            }
            if (index + 1) % 25 == 0 || index + 1 == files.count {
                progress(.copyingFiles(done: index + 1, total: files.count))
            }
        }
        if Task.isCancelled { return .failure(.cancelled) }

        // 3. Manifest, with the record counts read from the snapshot (which also proves it opens
        // with the current model). Counting is informative only: if the snapshot cannot be opened
        // for it, the manifest is written without counts rather than failing a complete backup.
        let entities = entityCounts(coordinator: coordinator, storeURL: snapshotURL)
        if missingCount > 0 {
            logger.warning("Backup: \(missingCount) external files were deleted during the copy")
        }
        let storeUUID = (try? NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite, at: snapshotURL))?[NSStoreUUIDKey] as? String
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        let info = Bundle.main.infoDictionary
        let manifest = BackupManifest(
            formatVersion: BackupFormat.formatVersion,
            createdAt: iso.string(from: now),
            createdAtEpoch: now.timeIntervalSince1970,
            app: .init(version: info?["CFBundleShortVersionString"] as? String ?? "",
                       build: info?["CFBundleVersion"] as? String ?? "",
                       bundleIdentifier: Bundle.main.bundleIdentifier ?? ""),
            platform: platformDescription,
            iCloudSyncEnabled: iCloudSyncEnabled,
            store: .init(fileName: storeName, storeUUID: storeUUID, storeBytes: fileSize(snapshotURL),
                         supportFolder: supportName, externalFileCount: copiedCount, externalBytes: copiedBytes,
                         missingExternalFiles: missingCount),
            entities: entities)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: root.appendingPathComponent(BackupFormat.manifestFileName))
        } catch {
            logger.error("Backup manifest not written: \(error.localizedDescription, privacy: .public)")
            return .failure(.manifestFailed)
        }
        if Task.isCancelled { return .failure(.cancelled) }

        // 4. Zip the root folder (its name becomes the archive's top-level folder), in a folder
        // of its own so a backup never deletes or overwrites another one's zip.
        progress(.compressing)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = .current
        stamp.dateFormat = "yyyy-MM-dd-HHmm"
        let zipName = "BlueDive-Backup-\(stamp.string(from: now)).zip"
        let zipFolder = fm.temporaryDirectory.appendingPathComponent("BlueDiveBackupZip-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: zipFolder, withIntermediateDirectories: true)) != nil else {
            return .failure(.archiveFailed)
        }
        let zipURL = zipFolder.appendingPathComponent(zipName)
        var coordinationError: NSError?
        var created = false
        NSFileCoordinator().coordinate(readingItemAt: root, options: .forUploading, error: &coordinationError) { zipped in
            created = (try? fm.copyItem(at: zipped, to: zipURL)) != nil
        }
        if let coordinationError {
            logger.error("Backup archive failed: \(coordinationError.localizedDescription, privacy: .public)")
        }
        guard coordinationError == nil, created, !Task.isCancelled else {
            try? fm.removeItem(at: zipFolder)
            return .failure(Task.isCancelled ? .cancelled : .archiveFailed)
        }
        return .success((zipURL, zipName))
    }

    // MARK: Helpers

    private struct ExternalFile {
        let url: URL
        let relativePath: String
        let bytes: Int64
    }

    /// Every regular file under the support folder, with its path relative to it.
    private static func externalFiles(in folder: URL) -> [ExternalFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [] }
        let base = folder.standardizedFileURL.path
        var files: [ExternalFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            files.append(ExternalFile(url: url, relativePath: String(path.dropFirst(base.count + 1)),
                                      bytes: Int64(values.fileSize ?? 0)))
        }
        return files
    }

    /// Opens the snapshot read-only on `coordinator`, counts every entity, and removes it again.
    private static func entityCounts(coordinator: NSPersistentStoreCoordinator, storeURL: URL) -> [String: Int]? {
        guard let store = try? coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL,
            options: [NSReadOnlyPersistentStoreOption: true, NSPersistentHistoryTrackingKey: true]) else { return nil }
        defer { try? coordinator.remove(store) }
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        var counts: [String: Int]? = [:]
        context.performAndWait {
            for name in coordinator.managedObjectModel.entities.compactMap(\.name) {
                guard let count = try? context.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: name)) else {
                    counts = nil
                    return
                }
                counts?[name] = count
            }
        }
        return counts
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    private static func availableSpace(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    private static var platformDescription: String {
        #if os(macOS)
        let system = "macOS"
        #else
        let system = "iOS"
        #endif
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(system) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
