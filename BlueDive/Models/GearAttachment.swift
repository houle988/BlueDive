import Foundation
import SwiftData
import UniformTypeIdentifiers

// MARK: - Gear Attachment

/// A photo or document attached to a piece of gear: a picture of the gear, a purchase receipt,
/// a warranty card, a service or inspection report, the record of a modification.
///
/// Built like `DivePhoto`: the file's bytes are stored unchanged in `file`, a generated
/// thumbnail in `thumbnail` — records of their own (see DivePhotoBlobs.swift), so listing a
/// gear's attachments never loads file data (read a file with `GearAttachmentLoader.readFile`,
/// off the main thread). An attachment belongs to one piece of gear and is deleted with it.
@Model
final class GearAttachment {
    var id: UUID = UUID()
    /// When the attachment was added to BlueDive; orders attachments that share a date.
    var createdAt: Date = Date.now
    var title: String = ""
    var note: String?
    /// `GearAttachmentCategory` raw value; an unknown value (written by a newer version) is
    /// shown as Other and kept unchanged.
    var category: String = GearAttachmentCategory.other.rawValue
    /// The document's date as the user sets it (e.g. the receipt's or the report's date).
    var date: Date = Date.now

    /// The file's name when it was added (shown, and used when it is opened or shared).
    var originalFilename: String?
    /// Uniform type identifier of the file (e.g. "com.adobe.pdf", "public.jpeg").
    var contentType: String?
    /// Size of the original file, in bytes.
    var byteCount: Int = 0
    /// SHA-256 of the original bytes, to tell the same file attached twice.
    var contentHash: Data?

    /// Original file bytes, never re-encoded. Set with `setFile(_:)`.
    @Relationship(deleteRule: .cascade, inverse: \GearAttachmentFile.attachment)
    var file: GearAttachmentFile?
    /// Thumbnail (longest side ≤ 512 px; PNG when the image has transparency, else JPEG). Set
    /// with `setThumbnail(_:)`.
    @Relationship(deleteRule: .cascade, inverse: \GearAttachmentThumbnail.attachment)
    var thumbnail: GearAttachmentThumbnail?

    var gear: Gear?

    init() {}
}

/// The original file bytes of a `GearAttachment`, stored unchanged.
@Model
final class GearAttachmentFile {
    var id: UUID = UUID()
    /// Mirror of `attachment?.id`, set with the relationship (`GearAttachment.setFile`).
    var attachmentID: UUID?
    @Attribute(.externalStorage) var data: Data?
    var attachment: GearAttachment?

    init() {}
}

/// The ≤ 512 px thumbnail of a `GearAttachment` (PNG when the image has transparency, else JPEG).
@Model
final class GearAttachmentThumbnail {
    var id: UUID = UUID()
    /// Mirror of `attachment?.id`, set with the relationship (`GearAttachment.setThumbnail`).
    var attachmentID: UUID?
    @Attribute(.externalStorage) var data: Data?
    var attachment: GearAttachment?

    init() {}
}

extension GearAttachment {
    /// Thumbnail bytes for the list; nil while the thumbnail record has not arrived from
    /// iCloud yet, or for a file with no thumbnail — show a placeholder then, never the file.
    var thumbnailBytes: Data? { thumbnail?.data }

    var attachmentCategory: GearAttachmentCategory {
        GearAttachmentCategory(rawValue: category) ?? .other
    }

    var isPDF: Bool { contentType.flatMap { UTType($0) }?.conforms(to: .pdf) == true }

    /// Stores the original bytes in their own record, in the attachment's own context (the
    /// attachment must already be inserted, so the two records are never linked across contexts).
    func setFile(_ data: Data) {
        guard let context = modelContext else { return }
        let record = file ?? {
            let new = GearAttachmentFile()
            context.insert(new)
            return new
        }()
        record.data = data
        record.attachmentID = id
        file = record
    }

    /// Stores the thumbnail in its own record, in the attachment's own context (the
    /// attachment must already be inserted).
    func setThumbnail(_ data: Data?) {
        guard let context = modelContext else { return }
        guard let data else {
            if let thumbnail { context.delete(thumbnail) }
            thumbnail = nil
            return
        }
        let record = thumbnail ?? {
            let new = GearAttachmentThumbnail()
            context.insert(new)
            return new
        }()
        record.data = data
        record.attachmentID = id
        thumbnail = record
    }
}

// MARK: - Category

enum GearAttachmentCategory: String, CaseIterable, Identifiable {
    case photo = "Photo"
    case receipt = "Receipt"
    case warranty = "Warranty"
    case serviceReport = "ServiceReport"
    case modification = "Modification"
    case other = "Other"

    var id: String { rawValue }

    /// Display name in the app language. One literal key per case so Xcode's string catalog
    /// detects every key (CLAUDE.md: never pass a runtime variable as the key).
    var localizedName: String {
        let bundle = Bundle.forAppLanguage()
        switch self {
        case .photo: return NSLocalizedString("attachment.category.Photo", bundle: bundle, value: "Photo", comment: "Gear attachment category")
        case .receipt: return NSLocalizedString("attachment.category.Receipt", bundle: bundle, value: "Receipt", comment: "Gear attachment category")
        case .warranty: return NSLocalizedString("attachment.category.Warranty", bundle: bundle, value: "Warranty", comment: "Gear attachment category")
        case .serviceReport: return NSLocalizedString("attachment.category.ServiceReport", bundle: bundle, value: "Service / Inspection Report", comment: "Gear attachment category")
        case .modification: return NSLocalizedString("attachment.category.Modification", bundle: bundle, value: "Modification", comment: "Gear attachment category")
        case .other: return NSLocalizedString("attachment.category.Other", bundle: bundle, value: "Other", comment: "Gear attachment category")
        }
    }

    var icon: String {
        switch self {
        case .photo: return "photo"
        case .receipt: return "receipt"
        case .warranty: return "checkmark.seal"
        case .serviceReport: return "wrench.and.screwdriver"
        case .modification: return "hammer"
        case .other: return "doc"
        }
    }
}
