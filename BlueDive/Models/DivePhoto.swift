import Foundation
import SwiftData

/// One photo attached to a dive.
///
/// The original file bytes are stored unchanged in `original`, the thumbnail in `thumbnail`
/// — records of their own (see DivePhotoBlobs.swift), so fetching photos never loads image
/// data. Everything else is read from the file at import (capture date, IPTC text, pixel
/// size) or derived from it (content hash). Each photo is its own record, so adding or
/// removing one photo syncs only that photo instead of re-uploading every photo of the dive
/// (as the legacy `Dive.photosData` array does).
@Model
final class DivePhoto {
    var id: UUID = UUID()
    /// When the photo was added to BlueDive; orders photos that have no capture date.
    var createdAt: Date = Date.now

    /// Original file bytes, never re-encoded. Set with `setOriginal(_:)`.
    @Relationship(deleteRule: .cascade, inverse: \DivePhotoOriginal.photo)
    var original: DivePhotoOriginal?
    /// JPEG thumbnail (longest side ≤ 512 px) for grids and profile markers. Set with
    /// `setThumbnail(_:)`.
    @Relationship(deleteRule: .cascade, inverse: \DivePhotoThumbnail.photo)
    var thumbnail: DivePhotoThumbnail?
    /// SHA-256 of the original bytes, used to detect a photo imported twice (any dive).
    var contentHash: Data?
    var originalFilename: String?
    /// Displayed pixel size of the original, read at import (compared when a re-imported file
    /// may replace it).
    var pixelWidth: Int = 0
    var pixelHeight: Int = 0

    /// EXIF `DateTimeOriginal` (or `DateTimeDigitized`) read as wall-clock time and stored with
    /// the same convention as `Dive.timestamp` (`WallClock.storedDate`). Raw: never adjusted.
    var captureDate: Date?
    /// EXIF `SubSecTimeOriginal` (or `SubSecTimeDigitized`), as written ("37"). Tells two shots
    /// taken in the same second apart when a re-imported file is matched to a stored photo.
    var captureSubsecond: String?
    /// When the file was last edited or exported: the latest of XMP `MetadataDate`, XMP
    /// `ModifyDate` and TIFF `DateTime`, read as wall-clock time (`WallClock.storedDate`, as
    /// `captureDate`). Decides whether a re-imported version is newer than the stored one.
    var metadataDate: Date?
    /// 0 = `captureSubsecond` and `metadataDate` not read yet (a photo imported before they
    /// existed; read from its original when a re-import needs them); 1 = read.
    var identityVersion: Int = 0
    /// Camera-clock correction (seconds) the user applied at import to match the dive computer.
    var clockAdjustmentSeconds: Double = 0

    /// IPTC Keywords (XMP `dc:subject`).
    var iptcKeywords: [String]?
    /// IPTC Caption/Abstract (XMP `dc:description`).
    var iptcCaption: String?
    /// IPTC Object Name (XMP `dc:title`).
    var iptcTitle: String?

    /// Mirror of `dive?.id`, so the dive list can find which dives have photos with a
    /// scalar-only fetch (no relationship or blob faults). Set only through `attach(to:)`.
    var diveID: UUID?
    var dive: Dive?

    @Relationship(deleteRule: .nullify, inverse: \Species.photos)
    var species: [Species]? = []

    /// Lookups of the import: photos of a dive (`existingHashes`), the same file in any dive
    /// (`contentHash`), photos taken at the same time (`captureDate`). Local indexes only.
    #Index<DivePhoto>([\.diveID], [\.contentHash], [\.captureDate])

    init() {}

    /// Attaches the photo to `dive`, keeping `diveID` in step with the relationship.
    func attach(to dive: Dive?) {
        self.dive = dive
        self.diveID = dive?.id
    }
}

extension DivePhoto {
    /// Thumbnail bytes for a grid, strip or marker; nil while the thumbnail record has not
    /// arrived from iCloud yet — show a placeholder then, never the original (CLAUDE.md).
    var thumbnailBytes: Data? { thumbnail?.data }

    /// Bytes for the full-size viewer: the original, or the thumbnail while the original is
    /// still downloading from iCloud.
    var previewBytes: Data? { original?.data ?? thumbnail?.data }

    /// Stores the thumbnail in its own record, in the photo's own context (the photo must
    /// already be inserted, so the two records can never be linked across contexts).
    func setThumbnail(_ data: Data?) {
        guard let context = modelContext else { return }
        guard let data else {
            if let thumbnail { context.delete(thumbnail) }
            thumbnail = nil
            return
        }
        let record = thumbnail ?? {
            let new = DivePhotoThumbnail()
            context.insert(new)
            return new
        }()
        record.data = data
        record.photoID = id
        thumbnail = record
    }

    /// Stores the original bytes in their own record, in the photo's own context (the photo
    /// must already be inserted).
    func setOriginal(_ data: Data) {
        guard let context = modelContext else { return }
        let record = original ?? {
            let new = DivePhotoOriginal()
            context.insert(new)
            return new
        }()
        record.data = data
        record.photoID = id
        original = record
    }

    /// Position on `dive`'s profile, in seconds from the dive start; nil = not on the profile.
    /// Calculated from the capture time, the clock correction and the dive's current start
    /// time and duration, so it follows later edits of the dive (a corrected start time, a
    /// downloaded profile). A photo without a capture time is not on the profile.
    func profileOffset(in dive: Dive) -> Double? {
        guard let captureDate else { return nil }
        return PhotoTiming.profileOffset(capture: WallClock.components(ofStored: captureDate),
                                         clockAdjustment: clockAdjustmentSeconds,
                                         diveStart: dive.timestamp,
                                         durationSeconds: dive.profileDurationSeconds)
    }
}
