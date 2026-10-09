import Foundation
import ImageIO
import CryptoKit
import SwiftData
import UniformTypeIdentifiers
import PhotosUI
import SwiftUI
import os.log

// MARK: - Photo File Info

/// Metadata read from one image file, plus the data derived from it at import.
nonisolated struct PhotoFileInfo: Sendable {
    var fileSize: Int = 0
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    /// Wall-clock capture time from EXIF `DateTimeOriginal` (or `DateTimeDigitized`), whole
    /// seconds. The time-zone offset (`OffsetTimeOriginal`) is ignored, as MacDive does: the
    /// dive computer's start time is a wall-clock time too.
    var captureComponents: DateComponents?
    var keywords: [String]?
    var caption: String?
    var title: String?
    var thumbnail: Data?
    var contentHash = Data()
}

// MARK: - Photo Metadata Reader

/// Reads capture date and IPTC text from image bytes with ImageIO, and creates the thumbnail
/// and content hash. Never modifies the image.
nonisolated enum PhotoMetadataReader {

    /// Longest side of the stored thumbnail, in pixels.
    static let thumbnailMaxPixelSize = 512

    /// Reads `data`; nil when it is not an image ImageIO can open.
    static func read(_ data: Data) -> PhotoFileInfo? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        var info = PhotoFileInfo()
        info.fileSize = data.count
        info.contentHash = Data(SHA256.hash(data: data))

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any] ?? [:]
        info.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        info.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        // EXIF orientations 5–8 rotate the image by 90°: report the displayed size.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            swap(&info.pixelWidth, &info.pixelHeight)
        }

        info.captureComponents = captureComponents(from: properties)

        readIPTC(source: source, properties: properties, into: &info)

        info.thumbnail = thumbnailJPEG(of: source, maxPixelSize: thumbnailMaxPixelSize, quality: 0.8)
        return info
    }

    /// Capture time of an image from its properties: EXIF `DateTimeOriginal`, else
    /// `DateTimeDigitized`. Not TIFF `DateTime`: that is when the file was last changed (an
    /// edit or an export), not when the photo was taken. Shared with the batch import scan.
    static func captureComponents(from properties: [CFString: Any]) -> DateComponents? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        // A blank or unreadable DateTimeOriginal (some cameras write "    :  :     :  :  ")
        // falls back to DateTimeDigitized.
        return (exif[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(exifDateComponents)
            ?? (exif[kCGImagePropertyExifDateTimeDigitized] as? String).flatMap(exifDateComponents)
    }

    /// A JPEG thumbnail of the image, oriented as displayed (longest side ≤ `maxPixelSize`).
    /// `usingEmbeddedPreview`: use the small preview stored in the file when it has one,
    /// without decoding the whole image (a quick scan); otherwise the thumbnail is made from
    /// the full image (sharper, for the stored thumbnail).
    static func thumbnailJPEG(of source: CGImageSource, maxPixelSize: Int, quality: Double,
                              usingEmbeddedPreview: Bool = false) -> Data? {
        let fromImageKey = usingEmbeddedPreview ? kCGImageSourceCreateThumbnailFromImageIfAbsent
                                                : kCGImageSourceCreateThumbnailFromImageAlways
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            fromImageKey: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return jpegData(from: thumbnail, quality: quality)
    }

    /// Wall-clock components of an EXIF date string ("yyyy:MM:dd HH:mm:ss"); subseconds and
    /// any offset are not part of this field. Nil for the blank dates some cameras write.
    static func exifDateComponents(_ text: String) -> DateComponents? {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == ":" || $0 == " " || $0 == "-" || $0 == "T" })
            .map(String.init)
        guard parts.count >= 6,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let hour = Int(parts[3]), let minute = Int(parts[4]),
              let second = Int(parts[5].prefix(2)),
              year > 1900, (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second)
        else { return nil }
        return DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    /// IPTC Keywords, Caption/Abstract and Object Name. ImageIO exposes them in the IPTC-IIM
    /// dictionary for files that carry an IIM block, and as XMP (`dc:subject`,
    /// `dc:description`, `dc:title` — the IPTC Core mapping) for files written by current
    /// apps; both are read, IIM first.
    private static func readIPTC(source: CGImageSource, properties: [CFString: Any], into info: inout PhotoFileInfo) {
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        var keywords: [String] = []
        if let list = iptc[kCGImagePropertyIPTCKeywords] as? [String] {
            keywords = list
        } else if let single = iptc[kCGImagePropertyIPTCKeywords] as? String {
            keywords = [single]
        }
        var caption = iptc[kCGImagePropertyIPTCCaptionAbstract] as? String
        var title = iptc[kCGImagePropertyIPTCObjectName] as? String

        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            if keywords.isEmpty, let subject = xmpArray(metadata, "dc:subject") {
                keywords = subject
            }
            // A blank IIM field (spaces only) does not hide the XMP one.
            if caption?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                caption = xmpText(metadata, "dc:description")
            }
            if title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                title = xmpText(metadata, "dc:title")
            }
        }
        let trimmed = keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        info.keywords = trimmed.isEmpty ? nil : trimmed
        info.caption = caption?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        info.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    /// Values of an XMP array (bag/seq) such as `dc:subject`.
    private static func xmpArray(_ metadata: CGImageMetadata, _ path: String) -> [String]? {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString),
              let values = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] else { return nil }
        let strings = values.compactMap { CGImageMetadataTagCopyValue($0) as? String }
        return strings.isEmpty ? nil : strings
    }

    /// Text of an XMP property, taking the default entry of a language alternative
    /// (`dc:description`, `dc:title`).
    private static func xmpText(_ metadata: CGImageMetadata, _ path: String) -> String? {
        if let value = CGImageMetadataCopyStringValueWithPath(metadata, nil, "\(path)[x-default]" as CFString) {
            return value as String
        }
        if let value = CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString) {
            return value as String
        }
        return xmpArray(metadata, path)?.first
    }

    private static func jpegData(from image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

private extension String {
    nonisolated var nilIfBlank: String? { isEmpty ? nil : self }
}

// MARK: - Photo Timing

/// Places a photo on a dive's timeline. Both the photo's capture time and the dive's start
/// are wall-clock times, so the offset is their wall-clock difference (computed in UTC, so a
/// daylight-saving change in the device's zone cannot shift it) — the same rule as MacDive.
enum PhotoTiming {

    /// Seconds from the dive start to the capture time, or nil when the photo was not taken
    /// during the dive (`start ≤ capture ≤ start + duration`, strict).
    static func profileOffset(capture: DateComponents, clockAdjustment: Double = 0,
                              diveStart: Date, durationSeconds: Int) -> Double? {
        guard let captureUTC = WallClock.utcCalendar.date(from: capture),
              let startUTC = WallClock.utcCalendar.date(from: WallClock.components(ofStored: diveStart))
        else { return nil }
        let offset = captureUTC.timeIntervalSince(startUTC) + clockAdjustment
        guard offset >= 0, offset <= Double(durationSeconds) else { return nil }
        return offset
    }
}

// MARK: - Photo Import Activity

/// Dives an import or conversion is writing to, app-wide. Each run reads the dive's photos
/// (content hashes, the legacy array) when it starts, so two runs on one dive — a second dive
/// screen, or Settings → Convert next to a dive's Convert — would insert the same images
/// twice: a run waits until the dive is free. Observable, so a dive screen can disable the
/// removal of legacy photos while another screen converts them.
@MainActor @Observable
final class PhotoImportActivity {
    static let shared = PhotoImportActivity()
    fileprivate(set) var busyDiveIDs: Set<PersistentIdentifier> = []
}

// MARK: - Photo Importer

/// Adds image files to a dive as `DivePhoto` records, and converts the legacy
/// `Dive.photosData` array into records.
///
/// Reading, hashing and thumbnail creation run off the main thread, one file at a time, so
/// a large selection never holds every original in memory. Records are inserted in a
/// dedicated ModelContext (author "BlueDive.photoImport", CLAUDE.md) that is saved every few
/// photos and released at the end; the main context picks up the saved photos.
@MainActor
enum PhotoImporter {
    static let logger = Logger(subsystem: "com.bluedive.app", category: "Photos")

    /// Whether an import or conversion is writing to the dive (observable: a view reading it
    /// updates when the dive becomes busy or free).
    static func isBusy(_ diveID: PersistentIdentifier) -> Bool {
        PhotoImportActivity.shared.busyDiveIDs.contains(diveID)
    }

    /// Waits until no other run writes to the dive, then marks it busy. Returns false when the
    /// waiting task is cancelled (the dive is then not marked).
    private static func acquire(_ diveID: PersistentIdentifier) async -> Bool {
        let activity = PhotoImportActivity.shared
        while activity.busyDiveIDs.contains(diveID) {
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return false
            }
        }
        activity.busyDiveIDs.insert(diveID)
        return true
    }

    private static func release(_ diveID: PersistentIdentifier) {
        PhotoImportActivity.shared.busyDiveIDs.remove(diveID)
    }

    /// One image to import.
    enum Source {
        case data(Data, filename: String?)
        /// A file URL (security-scoped access is started while reading).
        case file(URL)
        /// An item picked in the Photos library, loaded only when its turn comes.
        case pickerItem(PhotosPickerItem)
    }

    struct Result: Equatable {
        var imported = 0
        /// Images already attached to the dive (same content), not added again.
        var duplicates = 0
        /// Files that could not be read as an image.
        var unreadable = 0
        /// Ids of the photos added.
        var importedPhotoIDs: [UUID] = []
        /// Photos discarded by a failed save (with the copies of them in the same selection).
        var failedToSave = 0
        /// A conversion stored the records but could not remove the converted images from the
        /// legacy array: they show twice until the dive is converted again (which finds them
        /// already attached and removes them).
        var legacyNotTrimmed = false
    }

    /// Imports `sources` into the dive with `diveID`, skipping images already attached to
    /// that dive (same content hash). `progress` receives (processed, total) after each file.
    /// - Parameter clockAdjustment: camera-clock correction (seconds) added to each capture
    ///   time to place the photo on the dive profile; recorded on the photo.
    static func importPhotos(_ sources: [Source], toDiveWith diveID: PersistentIdentifier,
                             container: ModelContainer,
                             clockAdjustment: Double = 0,
                             progress: (Int, Int) -> Void = { _, _ in }) async -> Result {
        guard await acquire(diveID) else { return Result() }
        defer { release(diveID) }
        let result = await insert(sources, intoDiveWith: diveID, container: container,
                                  clockAdjustment: clockAdjustment, progress: progress)
        logger.info("Photo import: \(result.imported) imported, \(result.duplicates) duplicates, \(result.unreadable) unreadable")
        return result
    }

    /// Converts the dive's legacy `photosData` images into `DivePhoto` records (original
    /// bytes unchanged). Each image stored as a record (converted, or already attached) is
    /// removed from the legacy array; the others (unreadable, or not saved) stay in it, so no
    /// photo is lost or shown twice. Returns nil if the dive is gone.
    @discardableResult
    static func convertLegacyPhotos(ofDiveWith diveID: PersistentIdentifier,
                                    container: ModelContainer) async -> Result? {
        guard await acquire(diveID) else { return nil }
        defer { release(diveID) }
        return await convertLegacy(ofDiveWith: diveID, container: container)?.result
    }

    struct ConversionSummary: Equatable {
        var dives = 0
        var photos = 0
        /// Dives that still have legacy photos afterwards (an image could not be read or saved).
        var divesKept = 0
    }

    /// Converts the legacy photos of every dive, one dive at a time (each in a fresh
    /// context, so only one dive's images are in memory). `progress` receives
    /// (dives processed, total dives).
    static func convertAllLegacyPhotos(container: ModelContainer,
                                       progress: (Int, Int) -> Void = { _, _ in }) async -> ConversionSummary {
        let idContext = makeContext(container)
        var descriptor = FetchDescriptor<Dive>()
        descriptor.propertiesToFetch = [\.id]
        let ids = ((try? idContext.fetch(descriptor)) ?? []).map(\.persistentModelID)
        var summary = ConversionSummary()
        for (index, id) in ids.enumerated() {
            if Task.isCancelled { break }
            guard await acquire(id) else { break }
            if let (result, kept) = await convertLegacy(ofDiveWith: id, container: container) {
                summary.dives += 1
                summary.photos += result.imported
                if kept { summary.divesKept += 1 }
            }
            release(id)
            progress(index + 1, ids.count)
            await Task.yield()
        }
        logger.info("Legacy photo conversion: \(summary.photos) photos in \(summary.dives) dives, \(summary.divesKept) dives kept")
        return summary
    }

    /// Converts one dive's legacy photos; nil when the dive is gone or has none. `kept`: the
    /// dive still has legacy photos afterwards.
    private static func convertLegacy(ofDiveWith diveID: PersistentIdentifier,
                                      container: ModelContainer) async -> (result: Result, kept: Bool)? {
        let legacy: [Data] = {
            let context = makeContext(container)
            return fetchDive(diveID, in: context)?.photosData ?? []
        }()
        guard !legacy.isEmpty else { return nil }
        var result = await insert(legacy.map { .data($0, filename: nil) }, intoDiveWith: diveID, container: container)
        // The legacy array as it is now (not the copy read at the start: another device may
        // have changed it meanwhile). An image leaves it only when a record with the same
        // content is attached to the dive now — so a converted copy the user removed during
        // the run, an unreadable image, or one whose save failed stays in the array.
        let context = makeContext(container)
        guard let dive = fetchDive(diveID, in: context) else { return (result, false) }
        let current = dive.photosData ?? []
        let attached = Set(existingHashes(forDive: dive.id, in: context))
        let hashes = await Task.detached(priority: .userInitiated) {
            current.map { Data(SHA256.hash(data: $0)) }
        }.value
        let remaining = current.indices.filter { !attached.contains(hashes[$0]) }.map { current[$0] }
        guard remaining.count < current.count else { return (result, !current.isEmpty) }
        dive.photosData = remaining.isEmpty ? nil : remaining
        let saved = save(context)
        result.legacyNotTrimmed = !saved
        return (result, !saved || !remaining.isEmpty)
    }

    /// Copies the metadata in `info` onto `photo` (the image and thumbnail records are set by
    /// the caller, once the photo is in its context).
    static func apply(_ info: PhotoFileInfo, filename: String?, to photo: DivePhoto) {
        photo.contentHash = info.contentHash
        photo.originalFilename = filename
        photo.fileSize = info.fileSize
        photo.pixelWidth = info.pixelWidth
        photo.pixelHeight = info.pixelHeight
        photo.captureDate = info.captureComponents.flatMap(WallClock.storedDate(from:))
        photo.iptcKeywords = info.keywords
        photo.iptcCaption = info.caption
        photo.iptcTitle = info.title
    }

    /// Content hashes of the photos already attached to the dive.
    static func existingHashes(forDive diveUUID: UUID, in context: ModelContext) -> [Data] {
        var descriptor = FetchDescriptor<DivePhoto>(predicate: #Predicate { $0.diveID == diveUUID })
        descriptor.propertiesToFetch = [\.contentHash]
        return ((try? context.fetch(descriptor)) ?? []).compactMap(\.contentHash)
    }

    // MARK: Core

    /// Bytes of one image, ready to cross to a background task.
    private enum RawSource: Sendable {
        case data(Data, filename: String?)
        case file(URL)
    }

    /// Every few photos are saved and their context released, so the originals already
    /// saved do not stay in memory while the rest of a large selection is imported.
    private static func insert(_ sources: [Source], intoDiveWith diveID: PersistentIdentifier,
                               container: ModelContainer,
                               clockAdjustment: Double = 0,
                               progress: (Int, Int) -> Void = { _, _ in }) async -> Result {
        var result = Result()
        var context = makeContext(container)
        guard var dive = fetchDive(diveID, in: context) else { return result }
        let diveStart = dive.timestamp
        let durationSeconds = dive.durationSeconds
        var knownHashes = Set(existingHashes(forDive: dive.id, in: context))
        // Photos inserted since the last save (counted as imported only once saved).
        var pendingIDs: [UUID] = []
        var pendingHashes: [Data] = []
        /// Copies (in this selection) of photos not saved yet: duplicates only once those are.
        var pendingDuplicates = 0

        func flush() {
            guard !pendingIDs.isEmpty else { return }
            if save(context) {
                result.imported += pendingIDs.count
                result.importedPhotoIDs += pendingIDs
                result.duplicates += pendingDuplicates
            } else {
                // The rollback discarded these photos (and so their copies were not stored
                // either): they may be imported again.
                result.failedToSave += pendingIDs.count + pendingDuplicates
                knownHashes.subtract(pendingHashes)
            }
            pendingIDs = []
            pendingHashes = []
            pendingDuplicates = 0
        }

        /// Saves, then continues in a fresh context; false when the dive is gone.
        func flushAndRenew() -> Bool {
            flush()
            context = makeContext(container)
            guard let fresh = fetchDive(diveID, in: context) else { return false }
            dive = fresh
            return true
        }

        for (index, source) in sources.enumerated() {
            if Task.isCancelled { break }
            defer { progress(index + 1, sources.count) }
            let raw: RawSource
            switch source {
            case .data(let data, let filename): raw = .data(data, filename: filename)
            case .file(let url): raw = .file(url)
            case .pickerItem(let item):
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    result.unreadable += 1
                    continue
                }
                raw = .data(data, filename: nil)
            }
            let loaded = await Task.detached(priority: .userInitiated) { () -> (Data, String?, PhotoFileInfo)? in
                guard let (data, filename) = load(raw),
                      let info = PhotoMetadataReader.read(data) else { return nil }
                return (data, filename, info)
            }.value
            // No thumbnail means ImageIO cannot draw the image: it would show as a placeholder
            // everywhere. Counted as unreadable (a legacy image then stays in the legacy array).
            guard let (data, filename, info) = loaded, info.thumbnail != nil else {
                result.unreadable += 1
                continue
            }
            if knownHashes.contains(info.contentHash) {
                if pendingHashes.contains(info.contentHash) {
                    pendingDuplicates += 1
                } else {
                    result.duplicates += 1
                }
                continue
            }
            knownHashes.insert(info.contentHash)

            let photo = DivePhoto()
            apply(info, filename: filename, to: photo)
            photo.clockAdjustmentSeconds = clockAdjustment
            if let capture = info.captureComponents {
                photo.profileOffsetSeconds = PhotoTiming.profileOffset(
                    capture: capture, clockAdjustment: clockAdjustment,
                    diveStart: diveStart, durationSeconds: durationSeconds)
            }
            context.insert(photo)
            photo.setOriginal(data)
            photo.setThumbnail(info.thumbnail)
            photo.attach(to: dive)
            pendingIDs.append(photo.id)
            pendingHashes.append(info.contentHash)
            if pendingIDs.count >= 5, !flushAndRenew() { break }
        }
        flush()
        return result
    }

    private static func makeContext(_ container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        context.author = "BlueDive.photoImport"
        context.autosaveEnabled = false
        return context
    }

    /// The dive with `id` as saved in the store; nil once it was deleted (a deleted model must
    /// not be read, e.g. by a list refresh after a long import).
    static func fetchDive(_ id: PersistentIdentifier, in context: ModelContext) -> Dive? {
        var descriptor = FetchDescriptor<Dive>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Saves; on failure rolls back this context's unsaved changes and returns false.
    @discardableResult
    private static func save(_ context: ModelContext) -> Bool {
        guard context.hasChanges else { return true }
        do {
            try context.save()
            return true
        } catch {
            logger.error("Photo import save failed: \(error.localizedDescription)")
            context.rollback()
            return false
        }
    }

    /// Reads the bytes of `source`, off the main thread.
    nonisolated private static func load(_ source: RawSource) -> (Data, String?)? {
        switch source {
        case .data(let data, let filename):
            return (data, filename)
        case .file(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (data, url.lastPathComponent)
        }
    }
}
