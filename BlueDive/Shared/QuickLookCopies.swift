import Foundation

// MARK: - Quick Look Copies

/// The temporary copies dive photos and gear attachments are opened from in Quick Look, on
/// both platforms. They are not removed when Quick Look or the viewer closes: Quick Look can
/// hand the file to another app ("Open with Preview" on macOS, share extensions), which reads
/// it after Quick Look has closed. One copy per file version, under a key the caller builds
/// (a photo: the viewer's page identity — photo, original present, content hash; an
/// attachment: its `quickLookOwnerID` and content hash), reused when the file is opened again.
/// The latest copies are kept, up to `maxCopies` and `maxBytes` (the newest always); the
/// others are removed as new ones are written, a removed photo's or attachment's copies at
/// once, all of them on Erase all data, and whatever a previous launch left at the next launch.
@MainActor
enum QuickLookCopies {
    /// Name prefix of the launch folders, which identifies them in the launch sweep.
    nonisolated static let folderPrefix = "BlueDive-QuickLook-"

    /// This launch's folder, holding each copy in a subfolder of its own (under the export
    /// file name, which several copies can share).
    nonisolated static let launchFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(folderPrefix)\(UUID().uuidString)", isDirectory: true)

    /// How many copies a launch keeps (a few MB each, up to tens for large originals).
    private static let maxCopies = 20
    /// How much space they may use together (ProRAW or DNG originals can be 50–100 MB each).
    private static let maxBytes = 500_000_000

    /// This launch's copies by file version, least recently opened first.
    private static var copies: [(key: String, url: URL, bytes: Int)] = []

    /// A new subfolder of this launch's folder, for one copy.
    private nonisolated static func newCopyFolder() -> URL {
        launchFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Writes a new copy off the main thread: the bytes `load` returns, unchanged, under the
    /// name `name` gives for them, in a folder of its own. The file is read-only, so an app it
    /// is handed to (Preview) offers to duplicate it rather than save edits into a file
    /// BlueDive removes later. The caller records the copy (`record`) once it decides to show it.
    static func writeCopy(load: @escaping @Sendable () -> Data?,
                          name: @escaping @Sendable (Data) -> String) async -> WriteResult {
        let folder = newCopyFolder()
        return await Task.detached(priority: .userInitiated) { () -> WriteResult in
            guard let data = load(), !data.isEmpty else { return .noData }
            let url = folder.appendingPathComponent(name(data))
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
                return .written(url, byteCount: data.count)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                return .failed
            }
        }.value
    }

    enum WriteResult: Sendable {
        /// The copy and the number of bytes written (record it with that size).
        case written(URL, byteCount: Int)
        /// `load` returned no bytes (e.g. a file still downloading from iCloud).
        case noData
        /// The copy could not be written.
        case failed
    }

    /// The copy already written for a file version, if it is still there with the file's
    /// size (else it is forgotten and written again). `byteCount` nil: the size it was recorded
    /// with, for a key that always identifies the content (a gear attachment's content hash).
    /// A photo passes its current size: its key holds no hash for a legacy photo (`photosData`),
    /// so the size is what tells a replaced photo's outdated copy.
    static func copy(for key: String, byteCount: Int? = nil) -> URL? {
        guard let index = copies.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = copies.remove(at: index)
        let size = (try? FileManager.default.attributesOfItem(atPath: entry.url.path))?[.size] as? Int
        guard size == (byteCount ?? entry.bytes) else {
            removeFolder(of: entry.url)
            return nil
        }
        copies.append(entry)
        return entry.url
    }

    static func record(_ url: URL, for key: String, byteCount: Int) {
        if let index = copies.firstIndex(where: { $0.key == key }) {
            removeFolder(of: copies.remove(at: index).url)
        }
        copies.append((key, url, byteCount))
        // The oldest copies were opened files ago: whatever they were handed to has long read
        // them. The newest one is always kept, even alone above the byte budget.
        while copies.count > maxCopies
                || (copies.count > 1 && copies.reduce(0, { $0 + $1.bytes }) > maxBytes) {
            removeFolder(of: copies.removeFirst().url)
        }
    }

    /// Removes the copies of a photo or file the user removed (keys start with its id).
    static func remove(ownerID: String) {
        let prefix = "\(ownerID)|"
        for entry in copies where entry.key.hasPrefix(prefix) {
            removeFolder(of: entry.url)
        }
        copies.removeAll { $0.key.hasPrefix(prefix) }
    }

    /// Removes every copy of this launch (Erase all data).
    static func removeAll() {
        try? FileManager.default.removeItem(at: launchFolder)
        copies.removeAll()
    }

    private static func removeFolder(of url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Removes the copies previous launches left: every Quick Look folder but this launch's.
    /// Run once at launch. Touches only the Quick Look folders, nothing else in `tmp`.
    nonisolated static func removeLeftovers() {
        let fileManager = FileManager.default
        let tmp = fileManager.temporaryDirectory
        let current = launchFolder.lastPathComponent
        guard let names = try? fileManager.contentsOfDirectory(atPath: tmp.path) else { return }
        // Only folders this code names: the prefix followed by a launch UUID.
        for name in names where name.hasPrefix(folderPrefix) && name != current
            && UUID(uuidString: String(name.dropFirst(folderPrefix.count))) != nil {
            try? fileManager.removeItem(at: tmp.appendingPathComponent(name, isDirectory: true))
        }
    }
}
