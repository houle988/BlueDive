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
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0
    /// Wall-clock capture time from EXIF `DateTimeOriginal` (or `DateTimeDigitized`), whole
    /// seconds. The time-zone offset (`OffsetTimeOriginal`) is ignored, as MacDive does: the
    /// dive computer's start time is a wall-clock time too.
    var captureComponents: DateComponents?
    /// EXIF sub-seconds of the capture time, as written ("37"); nil when absent.
    var captureSubsecond: String?
    /// Wall-clock time of the last edit or export: the latest of XMP `MetadataDate`, XMP
    /// `ModifyDate` and TIFF `DateTime` (offsets ignored, like the capture time).
    var metadataComponents: DateComponents?
    var keywords: [String]?
    var caption: String?
    var title: String?
    var thumbnail: Data?
    var contentHash = Data()
}

// MARK: - Photo Metadata Reader

/// Reads capture date and IPTC text from image bytes with ImageIO, and creates the thumbnail
/// and content hash. Never modifies the image.
/// Limits how many `PhotoMetadataReader.onImageQueue` jobs run at once. A job over the limit
/// waits suspended (no thread held), in arrival order.
private actor ImageWorkGate {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func enter() async {
        guard running >= limit else { running += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the place to the next waiting job, if any (`running` then stays the same).
    func leave() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }
}

nonisolated enum PhotoMetadataReader {

    /// Longest side of the stored thumbnail, in pixels.
    static let thumbnailMaxPixelSize = 512

    /// Reads `data`; nil when it is not an image ImageIO can open.
    static func read(_ data: Data) -> PhotoFileInfo? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        var info = PhotoFileInfo()
        info.contentHash = Data(SHA256.hash(data: data))

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any] ?? [:]
        info.pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        info.pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        // EXIF orientations 5–8 rotate the image by 90°: report the displayed size.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            swap(&info.pixelWidth, &info.pixelHeight)
        }

        info.captureComponents = captureComponents(from: properties)
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        (info.captureSubsecond, info.metadataComponents) = identity(from: properties, metadata: metadata)

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

    /// Sub-seconds of the capture time and the last edit or export time, which tell a
    /// re-imported version of a stored photo apart from another shot (`PhotoReimportResolver`).
    /// The sub-seconds go with the field the capture time came from (`DateTimeOriginal`, else
    /// `DateTimeDigitized`). Lightroom changes `MetadataDate` only when metadata is edited and
    /// `ModifyDate` / TIFF `DateTime` on every export, so the latest of the three is kept.
    static func identity(from properties: [CFString: Any],
                         metadata: CGImageMetadata?) -> (subsecond: String?, edited: DateComponents?) {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let fromOriginal = (exif[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(exifDateComponents) != nil
        let subsecondKey = fromOriginal ? kCGImagePropertyExifSubsecTimeOriginal : kCGImagePropertyExifSubsecTimeDigitized
        let subsecond = (exif[subsecondKey] as? String)?.trimmingCharacters(in: .whitespaces).nilIfBlank

        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let texts: [String?] = [
            metadata.flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, "xmp:MetadataDate" as CFString) as String? },
            metadata.flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, "xmp:ModifyDate" as CFString) as String? },
            tiff[kCGImagePropertyTIFFDateTime] as? String
        ]
        let edited = texts.compactMap { $0.flatMap(exifDateComponents) }
            .max { (utcCalendar.date(from: $0) ?? .distantPast) < (utcCalendar.date(from: $1) ?? .distantPast) }
        return (subsecond, edited)
    }

    /// Gregorian calendar in UTC, to order wall-clock components (`WallClock` is main-actor).
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    /// The identity fields of stored image bytes (no thumbnail): for a photo imported before
    /// they were recorded, read from its original when a re-import is compared with it.
    static func readIdentity(_ data: Data) -> (subsecond: String?, edited: DateComponents?)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any] ?? [:]
        return identity(from: properties, metadata: CGImageSourceCopyMetadataAtIndex(source, 0, nil))
    }

    /// Runs ImageIO work (thumbnails, `read`) at default QoS and awaits it without blocking a
    /// thread. ImageIO waits on its own default-QoS threads (HEIC decoding); Xcode reports that
    /// wait as a priority inversion when the work runs higher. A detached task is raised to the
    /// priority of the `.task` or button action awaiting it, whatever priority it was given, and
    /// a dispatched block inherits its submitter's QoS unless `.enforceQoS` is set: so the work
    /// is dispatched with `.enforceQoS` and awaited through a continuation, which raises nothing.
    /// At most one job per core runs at a time (`ImageWorkGate`, awaited, not blocking), as on
    /// Swift's thread pool: a global queue would start a thread for each job blocked in ImageIO
    /// (a fast scroll through a photo grid), each decoding an image.
    static func onImageQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await imageWorkGate.enter()
        let result = await runOnImageQueue(work)
        await imageWorkGate.leave()
        return result
    }

    /// `onImageQueue` for work only its caller wants (a tile's image): nil, without running
    /// it, when the calling task was cancelled while waiting for its turn (the tile scrolled
    /// away), so a fast scroll does not leave the visible tiles behind a backlog of others.
    static func onImageQueueUnlessCancelled<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T? {
        await imageWorkGate.enter()
        guard !Task.isCancelled else {
            await imageWorkGate.leave()
            return nil
        }
        let result = await runOnImageQueue(work)
        await imageWorkGate.leave()
        return result
    }

    private static func runOnImageQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            imageWorkQueue.async(qos: .default, flags: .enforceQoS) { continuation.resume(returning: work()) }
        }
    }

    private static let imageWorkQueue = DispatchQueue(label: "BlueDive.imageWork", qos: .default,
                                                      attributes: .concurrent)
    private static let imageWorkGate = ImageWorkGate(limit: max(2, ProcessInfo.processInfo.activeProcessorCount))

    /// A JPEG thumbnail of the image, oriented as displayed (longest side ≤ `maxPixelSize`).
    /// `usingEmbeddedPreview`: use the small preview stored in the file when it has one,
    /// without decoding the whole image (a quick scan); otherwise the thumbnail is made from
    /// the full image (sharper, for the stored thumbnail).
    /// Call it (and `read`, which uses it) through `onImageQueue`, or from a task below default
    /// priority (e.g. `.utility`, as the iNaturalist download does), never from a detached task
    /// at default priority or above.
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

    /// Wall-clock components of an EXIF date string ("yyyy:MM:dd HH:mm:ss") or an XMP one
    /// ("2026-08-22T11:22:41.37+02:00"); subseconds and any offset are ignored. Nil for the
    /// blank dates some cameras write, and for a date without seconds.
    static func exifDateComponents(_ text: String) -> DateComponents? {
        var text = text.trimmingCharacters(in: .whitespaces)
        // An XMP time-zone offset ("+02:00", "-05:00", "Z") is cut off first, so a date
        // without seconds cannot take the offset's hours as its seconds.
        if let timeStart = text.firstIndex(of: "T"),
           let offset = text[timeStart...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            text = String(text[..<offset])
        }
        let parts = text
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
    /// waiting task is cancelled (the dive is then not marked). `onWaiting(true)` is called
    /// when the dive is busy, so the caller can say what it is waiting for, and
    /// `onWaiting(false)` once it is free again.
    private static func acquire(_ diveID: PersistentIdentifier, onWaiting: (Bool) -> Void = { _ in }) async -> Bool {
        let activity = PhotoImportActivity.shared
        let waited = activity.busyDiveIDs.contains(diveID)
        if waited { onWaiting(true) }
        defer { if waited { onWaiting(false) } }
        while activity.busyDiveIDs.contains(diveID) {
            if Task.isCancelled { return false }
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
    enum Source: Equatable {
        case data(Data, filename: String?)
        /// A file URL (security-scoped access is started while reading).
        case file(URL)
        /// An item picked in the Photos library, loaded only when its turn comes.
        case pickerItem(PhotosPickerItem)
    }

    /// The user's answer for a file that may already be in BlueDive.
    enum ReimportChoice: Hashable {
        /// Replace this stored photo with the file, and give it this import's placement: the
        /// import's dive (it moves there when it is on another one) and clock correction.
        case update(UUID)
        /// Add the file as a new photo.
        case keepBoth
        /// Leave the file out.
        case skip
    }

    /// A file the import could not decide on (`PhotoReimportResolver.Verdict.ask`): answered by
    /// the user, then passed to `answer(_:container:onWaiting:)`.
    struct ReimportQuestion: Identifiable, Equatable {
        let id = UUID()
        let source: Source
        let filename: String?
        /// Capture time (stored convention), for display.
        let capture: Date?
        /// The file's thumbnail.
        let preview: Data?
        let reason: PhotoReimportResolver.Reason
        /// Stored photos it may replace.
        let candidates: [UUID]
        /// What the choices show about each candidate, read once when the question is made
        /// (not in the view's body, where it would be fetched again on every redraw).
        let candidateDetails: [Candidate]
        /// The dive the file was being imported into.
        let diveID: PersistentIdentifier
        /// The clock correction entered for the import; nil when it had none to offer.
        let clockAdjustment: Double?
        /// Number and site of the dive the file was being imported into, to say where Update
        /// moves a photo from another dive.
        let diveNumber: Int?
        let diveSiteName: String

        /// The answer preselected (and given when nobody answers). Nothing is replaced or
        /// moved without a choice; a copy of the identical file is rarely wanted, so those
        /// rows start on Skip, the others on Keep both.
        var defaultChoice: ReimportChoice {
            switch reason {
            case .sameFileOnOtherDive, .sameFileOtherCorrection: return .skip
            default: return .keepBoth
            }
        }

        /// Keep both would add the identical file to a dive that already has it (the import
        /// skips it): not offered then.
        var offersKeepBoth: Bool { reason != .sameFileOtherCorrection }
    }

    /// A stored photo a question may replace, as shown in its "Update" choice.
    struct Candidate: Equatable {
        let photoID: UUID
        let filename: String?
        /// The candidate is on another dive than the file's: its number and site are shown,
        /// and Update moves it to the file's dive.
        let onOtherDive: Bool
        let diveNumber: Int?
        let siteName: String?
        /// Its clock correction (seconds), to tell whether Update changes it.
        let clockAdjustment: Double
    }

    struct Result: Equatable {
        var imported = 0
        /// Files already in BlueDive (the same file on the dive, or the same version of a
        /// stored photo), not added again.
        var duplicates = 0
        /// Stored photos replaced by a newer version of the same shot, or given a new clock
        /// correction, on their dive (a moved photo is counted in `moved` only).
        var updated = 0
        /// The photos replaced or moved (both counts), for the species proposals.
        var updatedPhotoIDs: [UUID] = []
        /// Stored photos moved to the import's dive by an Update (the file replaced too when it
        /// was newer). Each photo is counted once: here or in `updated`.
        var moved = 0
        /// The dives those photos left: their photo badges must be refreshed too.
        var movedFromDiveIDs: [PersistentIdentifier] = []
        /// Files older than the stored version of the same shot, not imported.
        var olderSkipped = 0
        /// Files the user chose to skip.
        var skippedByUser = 0
        /// Files waiting for the user's decision.
        var questions: [ReimportQuestion] = []
        /// Files whose dive was deleted before they could be added.
        var diveDeleted = 0
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

        /// Adds another run's counts (the questions are not merged: each run's are answered).
        mutating func add(_ other: Result) {
            imported += other.imported
            duplicates += other.duplicates
            updated += other.updated
            updatedPhotoIDs += other.updatedPhotoIDs
            moved += other.moved
            movedFromDiveIDs += other.movedFromDiveIDs
            olderSkipped += other.olderSkipped
            skippedByUser += other.skippedByUser
            diveDeleted += other.diveDeleted
            unreadable += other.unreadable
            importedPhotoIDs += other.importedPhotoIDs
            failedToSave += other.failedToSave
            legacyNotTrimmed = legacyNotTrimmed || other.legacyNotTrimmed
        }
    }

    /// Imports `sources` into the dive with `diveID`. A file already in BlueDive is skipped, a
    /// newer version of a stored photo replaces it, and a file BlueDive cannot decide on is
    /// returned in `questions` (`PhotoReimportResolver`). `progress` receives (processed,
    /// total) after each file; `onWaiting` is called when another photo task holds the dive.
    /// - Parameter clockAdjustment: camera-clock correction (seconds) added to each capture
    ///   time to place the photo on the dive profile; recorded on the photo. Nil when the
    ///   import has no correction to offer (a dive's Add Photo): new photos get none, and a
    ///   stored photo's correction is never changed.
    static func importPhotos(_ sources: [Source], toDiveWith diveID: PersistentIdentifier,
                             container: ModelContainer,
                             clockAdjustment: Double? = nil,
                             onWaiting: (Bool) -> Void = { _ in },
                             progress: (Int, Int) -> Void = { _, _ in }) async -> Result {
        guard await acquire(diveID, onWaiting: onWaiting) else { return Result() }
        defer { release(diveID) }
        let result = await insert(sources, intoDiveWith: diveID, container: container, mode: .importing,
                                  clockAdjustment: clockAdjustment, progress: progress)
        logger.info("Photo import: \(result.imported) imported, \(result.updated) updated, \(result.duplicates) duplicates, \(result.questions.count) to decide, \(result.unreadable) unreadable")
        return result
    }

    /// Carries out the user's answers to an import's questions: "Keep both" files are added
    /// to the dive they were imported into, "Update" replaces the chosen stored photo and
    /// gives it the import's placement (moved to the import's dive, with its clock correction
    /// when it has one), "Skip" leaves the file out. Each answer uses the clock correction its
    /// question was made with.
    /// `progress` receives (answers carried out, total) as it goes.
    static func answer(_ answers: [(question: ReimportQuestion, choice: ReimportChoice)],
                       container: ModelContainer,
                       onWaiting: (Bool) -> Void = { _ in },
                       progress: (Int, Int) -> Void = { _, _ in }) async -> Result {
        var result = Result()
        let total = answers.count
        /// Keep both files, by the dive and the clock correction they were imported with.
        struct KeepGroup: Hashable {
            let diveID: PersistentIdentifier
            let clockAdjustment: Double?
        }
        var keepByDive: [KeepGroup: [Source]] = [:]
        var updates: [(UUID, ReimportQuestion)] = []
        let lookup = makeContext(container)
        for (question, choice) in answers {
            switch choice {
            case .skip: result.skippedByUser += 1
            case .keepBoth:
                keepByDive[KeepGroup(diveID: question.diveID, clockAdjustment: question.clockAdjustment), default: []]
                    .append(question.source)
            case .update(let photoID):
                if fetchPhoto(photoID, in: lookup)?.dive != nil {
                    updates.append((photoID, question))
                } else {
                    // The stored photo (or its dive) was deleted since the question, e.g. on
                    // another device: the file is added as a new photo, so it is not lost.
                    keepByDive[KeepGroup(diveID: question.diveID, clockAdjustment: question.clockAdjustment), default: []]
                        .append(question.source)
                }
            }
        }
        var done = result.skippedByUser
        progress(done, total)
        for (group, sources) in keepByDive {
            if Task.isCancelled { break }
            let diveID = group.diveID
            guard fetchDive(diveID, in: makeContext(container)) != nil else {
                result.diveDeleted += sources.count
                done += sources.count
                progress(done, total)
                continue
            }
            guard await acquire(diveID, onWaiting: onWaiting) else { break }
            let base = done
            result.add(await insert(sources, intoDiveWith: diveID, container: container, mode: .keepAsNew,
                                    clockAdjustment: group.clockAdjustment,
                                    progress: { processed, _ in progress(base + processed, total) }))
            release(diveID)
            done += sources.count
        }
        for (photoID, question) in updates {
            if Task.isCancelled { break }
            result.add(await updateExisting(photoID, with: question.source, placingOn: question.diveID,
                                            clockAdjustment: question.clockAdjustment, container: container,
                                            onWaiting: onWaiting))
            done += 1
            progress(done, total)
        }
        return result
    }

    /// Replaces the stored photo `photoID` with `source` and gives it the import's placement:
    /// it moves to `targetDiveID` when it is on another dive, and takes `clockAdjustment` when
    /// one is given (its profile position follows). The file is replaced only when it differs.
    /// Both dives are reserved, always in the same order, so two runs never wait on each
    /// other. Unreadable or lost photo → counted, nothing changed.
    private static func updateExisting(_ photoID: UUID, with source: Source,
                                       placingOn targetDiveID: PersistentIdentifier,
                                       clockAdjustment: Double?, container: ModelContainer,
                                       onWaiting: (Bool) -> Void) async -> Result {
        var result = Result()
        let lookup = makeContext(container)
        guard let sourceDiveID = fetchPhoto(photoID, in: lookup)?.dive?.persistentModelID else {
            result.failedToSave += 1
            return result
        }
        let reserved = Set([sourceDiveID, targetDiveID]).sorted()
        var held: [PersistentIdentifier] = []
        defer { held.forEach(release) }
        for diveID in reserved {
            guard await acquire(diveID, onWaiting: onWaiting) else { return result }
            held.append(diveID)
        }
        guard let (data, filename, info) = await loadAndRead(source), info.thumbnail != nil else {
            result.unreadable += 1
            return result
        }
        let context = makeContext(container)
        // The photo was deleted, or moved by another task while this one waited: its dive is
        // then not one of those reserved.
        guard let photo = fetchPhoto(photoID, in: context), let currentDive = photo.dive,
              currentDive.persistentModelID == sourceDiveID else {
            result.failedToSave += 1
            return result
        }
        guard let targetDive = fetchDive(targetDiveID, in: context) else {
            // The import's dive was deleted meanwhile: counted like Keep both's files.
            result.diveDeleted += 1
            return result
        }
        let fileChanges = photo.contentHash != info.contentHash
        let moves = currentDive.persistentModelID != targetDiveID
        // Another photo of the target dive already has this file (e.g. another file of this
        // import, under another name, was kept or has just updated it): replacing or moving
        // this one would put the file on the dive twice. A correction-only change on the same
        // dive adds no copy, so it is not checked (the dive may already hold several).
        if fileChanges || moves,
           storedPhotos(withHash: info.contentHash, in: context).contains(where: { $0.diveID == targetDive.id && $0.id != photoID }) {
            result.duplicates += 1
            return result
        }
        let correctionChanges = clockAdjustment.map { abs($0 - photo.clockAdjustmentSeconds) >= PhotoReimportResolver.sameCorrectionTolerance } ?? false
        guard fileChanges || moves || correctionChanges else {
            result.duplicates += 1
            return result
        }
        if fileChanges {
            guard update(photoID, with: data, info: info, filename: filename, in: context) != nil else {
                result.failedToSave += 1
                return result
            }
        }
        if let clockAdjustment, correctionChanges { photo.clockAdjustmentSeconds = clockAdjustment }
        if moves { photo.attach(to: targetDive) }
        if save(context) {
            result.updatedPhotoIDs.append(photoID)
            if moves {
                result.moved += 1
                result.movedFromDiveIDs.append(currentDive.persistentModelID)
            } else {
                result.updated += 1
            }
        } else {
            result.failedToSave += 1
        }
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
        var result = await insert(legacy.map { .data($0, filename: nil) }, intoDiveWith: diveID, container: container,
                                  mode: .convertLegacy)
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
        photo.pixelWidth = info.pixelWidth
        photo.pixelHeight = info.pixelHeight
        photo.captureDate = info.captureComponents.flatMap(WallClock.storedDate(from:))
        photo.captureSubsecond = info.captureSubsecond
        photo.metadataDate = info.metadataComponents.flatMap(WallClock.storedDate(from:))
        photo.identityVersion = 1
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

    /// Hashes of the dive's photos whose clock correction differs from `correction`.
    static func hashesWithOtherCorrection(forDive diveUUID: UUID, than correction: Double,
                                          in context: ModelContext) -> Set<Data> {
        var descriptor = FetchDescriptor<DivePhoto>(predicate: #Predicate { $0.diveID == diveUUID })
        descriptor.propertiesToFetch = [\.contentHash, \.clockAdjustmentSeconds]
        return Set(((try? context.fetch(descriptor)) ?? []).compactMap { photo in
            abs(photo.clockAdjustmentSeconds - correction) >= PhotoReimportResolver.sameCorrectionTolerance
                ? photo.contentHash : nil
        })
    }

    // MARK: Core

    /// Bytes of one image, ready to cross to a background task.
    private enum RawSource: Sendable {
        case data(Data, filename: String?)
        case file(URL)
    }

    /// How `insert` treats a file that may already be in BlueDive.
    enum InsertMode {
        /// An import: the same file on the dive is skipped, and every other match is resolved
        /// (`PhotoReimportResolver`): updated, skipped, or returned as a question.
        case importing
        /// The user chose "Keep both": added unless the identical file is on the dive.
        case keepAsNew
        /// The legacy array of the dive: only the same file on the dive is skipped (there is
        /// no one to ask, and these are the dive's own photos).
        case convertLegacy
    }

    /// Every few photos are saved and their context released, so the originals already
    /// saved do not stay in memory while the rest of a large selection is imported.
    private static func insert(_ sources: [Source], intoDiveWith diveID: PersistentIdentifier,
                               container: ModelContainer,
                               mode: InsertMode,
                               clockAdjustment: Double? = nil,
                               progress: (Int, Int) -> Void = { _, _ in }) async -> Result {
        var result = Result()
        var context = makeContext(container)
        guard var dive = fetchDive(diveID, in: context) else { return result }
        let diveUUID = dive.id
        var knownHashes = Set(existingHashes(forDive: dive.id, in: context))
        /// Files on the dive stored with another clock correction than this import's.
        let otherCorrectionHashes = mode == .importing
            ? clockAdjustment.map { hashesWithOtherCorrection(forDive: dive.id, than: $0, in: context) } ?? []
            : []
        // Photos inserted since the last save (counted as imported only once saved).
        var pendingIDs: [UUID] = []
        var pendingHashes: [Data] = []
        /// Copies (in this selection) of photos not saved yet: duplicates only once those are.
        var pendingDuplicates = 0
        /// Stored photos replaced since the last save.
        var pendingUpdatedIDs: [UUID] = []
        /// Stored photos an earlier file of this import inserted or replaced: a second file of
        /// the same shot asks instead of replacing it again.
        var used = Set<UUID>()
        /// Identity fields read from stored photos' originals, to be saved with the next batch.
        var identityRead = false
        /// Files this import added or wrote: a second copy in the selection is a duplicate.
        var importHashes = Set<Data>()

        func flush() {
            guard !pendingIDs.isEmpty || !pendingUpdatedIDs.isEmpty || identityRead else { return }
            identityRead = false
            if save(context) {
                result.imported += pendingIDs.count
                result.importedPhotoIDs += pendingIDs
                result.duplicates += pendingDuplicates
                result.updated += pendingUpdatedIDs.count
                result.updatedPhotoIDs += pendingUpdatedIDs
            } else {
                // The rollback discarded these photos (and so their copies were not stored
                // either) and the replacements: they may be imported again.
                result.failedToSave += pendingIDs.count + pendingDuplicates + pendingUpdatedIDs.count
                knownHashes.subtract(pendingHashes)
            }
            pendingIDs = []
            pendingHashes = []
            pendingDuplicates = 0
            pendingUpdatedIDs = []
        }

        /// Saves, then continues in a fresh context; false when the dive is gone.
        func flushAndRenew() -> Bool {
            flush()
            context = makeContext(container)
            guard let fresh = fetchDive(diveID, in: context) else { return false }
            dive = fresh
            return true
        }

        files: for (index, source) in sources.enumerated() {
            if Task.isCancelled { break }
            defer { progress(index + 1, sources.count) }
            // No thumbnail means ImageIO cannot draw the image: it would show as a placeholder
            // everywhere. Counted as unreadable (a legacy image then stays in the legacy array).
            guard let (data, filename, info) = await loadAndRead(source), info.thumbnail != nil else {
                result.unreadable += 1
                continue
            }
            // The identical file is already on the dive. Stored before this import with
            // another clock correction, it goes to the resolver, which asks.
            let compareCorrection = otherCorrectionHashes.contains(info.contentHash)
                && !importHashes.contains(info.contentHash)
            if knownHashes.contains(info.contentHash), !compareCorrection {
                if pendingHashes.contains(info.contentHash) {
                    pendingDuplicates += 1
                } else {
                    result.duplicates += 1
                }
                continue
            }

            if mode == .importing {
                let incoming = PhotoReimportResolver.Incoming(
                    contentHash: info.contentHash, capture: info.captureComponents,
                    subsecond: info.captureSubsecond, filename: filename,
                    edited: info.metadataComponents.flatMap(WallClock.storedDate(from:)),
                    pixelWidth: info.pixelWidth, pixelHeight: info.pixelHeight, diveID: diveUUID,
                    clockAdjustment: clockAdjustment)
                let sameFile = storedPhotos(withHash: info.contentHash, in: context)
                let (sameTime, read) = await storedPhotos(takenAt: info.captureComponents, reservedDive: diveUUID, in: context)
                identityRead = identityRead || read
                switch PhotoReimportResolver.resolve(incoming, sameFile: sameFile, sameTime: sameTime, used: used) {
                case .new:
                    break
                case .already:
                    result.duplicates += 1
                    continue
                case .older:
                    result.olderSkipped += 1
                    continue
                case .update(let photoID):
                    if let replaced = update(photoID, with: data, info: info, filename: filename, in: context) {
                        // The replaced version is no longer in BlueDive.
                        if let old = replaced { knownHashes.remove(old) }
                        pendingUpdatedIDs.append(photoID)
                        pendingHashes.append(info.contentHash)
                        knownHashes.insert(info.contentHash)
                        importHashes.insert(info.contentHash)
                        used.insert(photoID)
                    } else {
                        result.failedToSave += 1
                    }
                    if pendingIDs.count + pendingUpdatedIDs.count >= 5, !flushAndRenew() { break files }
                    continue
                case .ask(let reason, let candidates):
                    // A later copy of the identical file in this selection is a duplicate,
                    // not a second question (the file is already on the dive).
                    if reason == .sameFileOtherCorrection { importHashes.insert(info.contentHash) }
                    result.questions.append(ReimportQuestion(
                        source: source, filename: filename,
                        capture: info.captureComponents.flatMap(WallClock.storedDate(from:)),
                        preview: info.thumbnail, reason: reason, candidates: candidates,
                        candidateDetails: candidateDetails(candidates, among: sameFile + sameTime,
                                                           fileDive: diveUUID, in: context),
                        diveID: diveID, clockAdjustment: clockAdjustment,
                        diveNumber: dive.diveNumber, diveSiteName: dive.siteName))
                    continue
                }
            }
            knownHashes.insert(info.contentHash)
            importHashes.insert(info.contentHash)

            let photo = DivePhoto()
            apply(info, filename: filename, to: photo)
            photo.clockAdjustmentSeconds = clockAdjustment ?? 0
            context.insert(photo)
            photo.setOriginal(data)
            photo.setThumbnail(info.thumbnail)
            photo.attach(to: dive)
            pendingIDs.append(photo.id)
            pendingHashes.append(info.contentHash)
            used.insert(photo.id)
            if pendingIDs.count + pendingUpdatedIDs.count >= 5, !flushAndRenew() { break files }
        }
        flush()
        return result
    }

    /// Reads one source off the main thread: its bytes, file name and metadata; nil when it
    /// cannot be loaded or is not an image.
    private static func loadAndRead(_ source: Source) async -> (Data, String?, PhotoFileInfo)? {
        let raw: RawSource
        switch source {
        case .data(let data, let filename): raw = .data(data, filename: filename)
        case .file(let url): raw = .file(url)
        case .pickerItem(let item):
            guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
            raw = .data(data, filename: nil)
        }
        return await PhotoMetadataReader.onImageQueue { () -> (Data, String?, PhotoFileInfo)? in
            guard let (data, filename) = load(raw),
                  let info = PhotoMetadataReader.read(data) else { return nil }
            return (data, filename, info)
        }
    }

    /// Replaces the stored photo `photoID` (in `context`) with a newer version of the same
    /// shot: the file, its thumbnail and everything read from it. Kept: the record, its dive,
    /// species links and clock correction (the profile position follows the new capture
    /// time). Not saved. Returns the replaced file's hash (nil inside: it had none); nil when
    /// the photo or its dive is gone.
    private static func update(_ photoID: UUID, with data: Data, info: PhotoFileInfo,
                               filename: String?, in context: ModelContext) -> Data?? {
        guard let photo = fetchPhoto(photoID, in: context), photo.dive != nil else { return nil }
        let replacedHash = photo.contentHash
        apply(info, filename: filename ?? photo.originalFilename, to: photo)
        photo.setOriginal(data)
        photo.setThumbnail(info.thumbnail)
        return .some(replacedHash)
    }

    static func fetchPhoto(_ id: UUID, in context: ModelContext) -> DivePhoto? {
        var descriptor = FetchDescriptor<DivePhoto>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Stored photos (any dive) whose file has this hash.
    private static func storedPhotos(withHash hash: Data, in context: ModelContext) -> [PhotoReimportResolver.Stored] {
        let wanted: Data? = hash
        let descriptor = FetchDescriptor<DivePhoto>(predicate: #Predicate { $0.contentHash == wanted })
        return ((try? context.fetch(descriptor)) ?? []).map { stored($0, identityKnown: true) }
    }

    /// Stored photos taken in the same wall-clock second as `capture`. The query uses a
    /// ±26 h window (`captureDate` is stored through the device's time zone, which may have
    /// changed since), and the second is compared on wall-clock components. A photo whose
    /// sub-second and edit time were never read has them read from its original now (only the
    /// same-second candidates, so rarely more than one original is loaded). The fields are
    /// saved only on photos of `reservedDive`, the dive this import holds (`identityRead` is
    /// then true, for the caller to save); a photo of another dive is compared with them but
    /// not written to. Without its original the photo is returned as not comparable.
    private static func storedPhotos(takenAt capture: DateComponents?, reservedDive: UUID,
                                     in context: ModelContext) async -> (photos: [PhotoReimportResolver.Stored], identityRead: Bool) {
        guard let capture, let center = WallClock.storedDate(from: capture) else { return ([], false) }
        let low = center.addingTimeInterval(-26 * 3600)
        let high = center.addingTimeInterval(26 * 3600)
        let past = Date.distantPast
        let descriptor = FetchDescriptor<DivePhoto>(predicate: #Predicate {
            ($0.captureDate ?? past) >= low && ($0.captureDate ?? past) <= high
        })
        let photos = ((try? context.fetch(descriptor)) ?? []).filter { photo in
            photo.captureDate.map { PhotoReimportResolver.sameSecond(WallClock.components(ofStored: $0), capture) } ?? false
        }
        var result: [PhotoReimportResolver.Stored] = []
        var identityRead = false
        for photo in photos {
            var entry = stored(photo, identityKnown: photo.identityVersion >= 1)
            if !entry.identityKnown, let original = photo.original?.data,
               let identity = await Task.detached(priority: .userInitiated, operation: {
                   PhotoMetadataReader.readIdentity(original)
               }).value {
                let edited = identity.edited.flatMap(WallClock.storedDate(from:))
                entry.subsecond = identity.subsecond
                entry.edited = edited
                entry.identityKnown = true
                if photo.diveID == reservedDive {
                    photo.captureSubsecond = identity.subsecond
                    photo.metadataDate = edited
                    photo.identityVersion = 1
                    identityRead = true
                }
            }
            result.append(entry)
        }
        return (result, identityRead)
    }

    /// The candidates of a question as its choices show them: file name, and the dive's number
    /// and site when it is not the file's dive.
    private static func candidateDetails(_ ids: [UUID], among stored: [PhotoReimportResolver.Stored],
                                         fileDive: UUID, in context: ModelContext) -> [Candidate] {
        ids.compactMap { id in
            guard let photo = stored.first(where: { $0.id == id }) else { return nil }
            let onOtherDive = photo.diveID != fileDive
            var number: Int?
            var site: String?
            if let diveUUID = photo.diveID, onOtherDive || photo.filename == nil {
                var descriptor = FetchDescriptor<Dive>(predicate: #Predicate { $0.id == diveUUID })
                descriptor.fetchLimit = 1
                if let dive = (try? context.fetch(descriptor))?.first {
                    number = dive.diveNumber
                    site = dive.siteName
                }
            }
            return Candidate(photoID: id, filename: photo.filename, onOtherDive: onOtherDive,
                             diveNumber: number, siteName: site, clockAdjustment: photo.clockAdjustment)
        }
    }

    private static func stored(_ photo: DivePhoto, identityKnown: Bool) -> PhotoReimportResolver.Stored {
        PhotoReimportResolver.Stored(
            id: photo.id, diveID: photo.diveID, contentHash: photo.contentHash,
            capture: photo.captureDate.map(WallClock.components(ofStored:)),
            subsecond: photo.captureSubsecond, filename: photo.originalFilename,
            edited: photo.metadataDate, pixelWidth: photo.pixelWidth, pixelHeight: photo.pixelHeight,
            identityKnown: identityKnown, clockAdjustment: photo.clockAdjustmentSeconds)
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
