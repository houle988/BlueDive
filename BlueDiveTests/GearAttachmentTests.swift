import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers
@testable import BlueDive

/// Gear attachments (photos and documents on an equipment record) and the shared pieces they
/// use: the file size text, the Quick Look copies, the picked-file loader. Every file is built
/// in code (CLAUDE.md: no sample files in the test target).
@MainActor
struct GearAttachmentTests {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: Schema(BlueDiveApp.appModelTypes),
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    /// A 64 × 48 image encoded as `type`; `transparent` draws it half see-through.
    private func image(_ type: UTType, transparent: Bool = false) throws -> Data {
        let alpha: CGImageAlphaInfo = transparent ? .premultipliedLast : .noneSkipLast
        let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alpha.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: transparent ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let cgImage = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The file a load returned, or nil when it was refused.
    private func loaded(_ result: GearAttachmentLoader.LoadResult) -> PendingAttachmentFile? {
        if case .loaded(let file) = result { return file }
        return nil
    }

    /// A one-page PDF drawn in code, written to a temporary folder of its own.
    private func temporaryPDF() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Service report.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 40, y: 40, width: 220, height: 320))
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private func isPNG(_ data: Data?) -> Bool { data?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) }
    private func isJPEG(_ data: Data?) -> Bool { data?.prefix(2) == Data([0xFF, 0xD8]) }

    /// An attachment with its file and thumbnail records, on `gear`, saved.
    private func attach(_ data: Data, to gear: Gear, in context: ModelContext) throws -> GearAttachment {
        let attachment = GearAttachment()
        context.insert(attachment)
        attachment.gear = gear
        attachment.byteCount = data.count
        attachment.setFile(data)
        attachment.setThumbnail(Data([1, 2, 3]))
        try context.save()
        return attachment
    }

    // MARK: - File Size Text

    private func sizeText(_ key: String, _ number: Double, decimals: Int) -> String {
        let bundle = Bundle.forAppLanguage()
        let format: String
        switch key {
        case "KB": format = NSLocalizedString("%@ KB", bundle: bundle, value: "%@ KB", comment: "")
        case "MB": format = NSLocalizedString("%@ MB", bundle: bundle, value: "%@ MB", comment: "")
        default: format = NSLocalizedString("%@ GB", bundle: bundle, value: "%@ GB", comment: "")
        }
        return String(format: format, number.localizedString(decimals: decimals))
    }

    @Test func fileSizeRoundsBeforePickingTheUnit() {
        #expect(Int64(0).localizedFileSize == sizeText("KB", 0, decimals: 0))
        // A non-empty file never reads "0 KB".
        #expect(Int64(300).localizedFileSize == sizeText("KB", 1, decimals: 0))
        #expect(Int64(45_400).localizedFileSize == sizeText("KB", 45, decimals: 0))
        // 950–999 KB stay in KB.
        #expect(Int64(955_000).localizedFileSize == sizeText("KB", 955, decimals: 0))
        // Just under 1 MB: "1 MB", not "1,000 KB".
        #expect(Int64(999_600).localizedFileSize == sizeText("MB", 1, decimals: 1))
        #expect(Int64(32_450_000).localizedFileSize == sizeText("MB", 32.5, decimals: 1))
        #expect(Int64(2_500_000_000).localizedFileSize == sizeText("GB", 2.5, decimals: 1))
        // Just under 1 GB: "1 GB", not "1,000 MB".
        #expect(Int64(999_960_000).localizedFileSize == sizeText("GB", 1, decimals: 1))
    }

    // MARK: - Model

    @Test func deletingTheGearDeletesItsAttachmentsAndTheirFiles() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let gear = Gear(name: "Regulator", category: "First Stage")
        context.insert(gear)
        _ = try attach(Data(repeating: 7, count: 100), to: gear, in: context)
        _ = try attach(Data(repeating: 8, count: 200), to: gear, in: context)
        #expect(try context.fetchCount(FetchDescriptor<GearAttachment>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<GearAttachmentFile>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<GearAttachmentThumbnail>()) == 2)

        context.delete(gear)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<GearAttachment>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<GearAttachmentFile>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<GearAttachmentThumbnail>()) == 0)
    }

    @Test func fileAndThumbnailRecordsMirrorTheAttachmentID() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let gear = Gear(name: "Computer", category: "Computer")
        context.insert(gear)
        let attachment = try attach(Data(repeating: 1, count: 10), to: gear, in: context)
        #expect(attachment.file?.attachmentID == attachment.id)
        #expect(attachment.thumbnail?.attachmentID == attachment.id)
        // Clearing the thumbnail deletes its record.
        attachment.setThumbnail(nil)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<GearAttachmentThumbnail>()) == 0)
    }

    @Test func readFileReturnsTheBytesThenNilOnceDeleted() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let gear = Gear(name: "BCD", category: "BCD/Backplate")
        context.insert(gear)
        let bytes = Data((0..<255).map { UInt8($0) })
        let attachment = try attach(bytes, to: gear, in: context)
        let fileID = try #require(attachment.file?.persistentModelID)

        #expect(GearAttachmentLoader.readFile(fileID, container: container) == bytes)

        context.delete(attachment)
        try context.save()
        // A deleted record reads as nil, it does not trap.
        #expect(GearAttachmentLoader.readFile(fileID, container: container) == nil)
    }

    @Test func unknownCategoryShowsAsOtherAndIsKept() {
        let attachment = GearAttachment()
        attachment.category = "SomethingNewer"
        #expect(attachment.attachmentCategory == .other)
        #expect(attachment.category == "SomethingNewer")
    }

    @Test func pdfIsRecognizedByItsType() {
        let attachment = GearAttachment()
        attachment.contentType = UTType.pdf.identifier
        #expect(attachment.isPDF)
        attachment.contentType = UTType.jpeg.identifier
        #expect(!attachment.isPDF)
        attachment.contentType = nil
        #expect(!attachment.isPDF)
    }

    // MARK: - Loader

    @Test func photoTypeComesFromTheBytes() async throws {
        let png = try image(.png)
        // The picker offered JPEG, but the bytes are PNG.
        let file = try #require(loaded(await GearAttachmentLoader.load(data: png, contentType: .jpeg)))
        #expect(file.contentType == .png)
        #expect(file.data == png)
        #expect(file.filename == nil)
    }

    @Test func transparentImageGetsAPNGThumbnailOpaqueOneAJPEG() async throws {
        let transparentData = try image(.png, transparent: true)
        let opaqueData = try image(.jpeg)
        let transparent = try #require(loaded(await GearAttachmentLoader.load(data: transparentData, contentType: nil)))
        #expect(isPNG(transparent.thumbnail))
        let opaque = try #require(loaded(await GearAttachmentLoader.load(data: opaqueData, contentType: nil)))
        #expect(isJPEG(opaque.thumbnail))
    }

    @Test func opaqueImageWithAnAlphaChannelGetsAJPEGThumbnail() async throws {
        // An RGBA PNG whose every pixel is opaque (a screenshot, a scan).
        let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let cgImage = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        #expect(CGImageDestinationFinalize(destination))
        let file = try #require(loaded(await GearAttachmentLoader.load(data: data as Data, contentType: nil)))
        #expect(isJPEG(file.thumbnail))
    }

    @Test func opaquePNGGetsAJPEGThumbnail() async throws {
        let opaquePNG = try image(.png)
        let file = try #require(loaded(await GearAttachmentLoader.load(data: opaquePNG, contentType: nil)))
        #expect(isJPEG(file.thumbnail))
    }

    @Test func sameBytesGiveTheSameHash() async throws {
        let data = try image(.jpeg)
        let first = try #require(loaded(await GearAttachmentLoader.load(data: data, contentType: nil)))
        let second = try #require(loaded(await GearAttachmentLoader.load(data: data, contentType: nil)))
        let otherData = try image(.png)
        let other = try #require(loaded(await GearAttachmentLoader.load(data: otherData, contentType: nil)))
        #expect(first.contentHash == second.contentHash)
        #expect(first.contentHash != other.contentHash)
    }

    @Test func emptyDataIsRejected() async {
        guard case .unreadable = await GearAttachmentLoader.load(data: Data(), contentType: .jpeg) else {
            Issue.record("Expected unreadable")
            return
        }
    }

    @Test func photoOverTheLimitIsRefused() async {
        let data = Data(count: GearAttachmentLoader.maxFileBytes + 1)
        guard case .tooLarge = await GearAttachmentLoader.load(data: data, contentType: .jpeg) else {
            Issue.record("Expected tooLarge")
            return
        }
    }

    @Test func fileOverTheLimitIsRefusedBeforeItIsRead() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Manual.pdf")
        try Data(count: GearAttachmentLoader.maxFileBytes + 1).write(to: url)
        guard case .tooLarge = await GearAttachmentLoader.load(url: url) else {
            Issue.record("Expected tooLarge")
            return
        }
    }

    @Test func fileAtTheLimitIsAccepted() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Exactly.bin")
        try Data(count: GearAttachmentLoader.maxFileBytes).write(to: url)
        let file = try #require(loaded(await GearAttachmentLoader.load(url: url)))
        #expect(file.data.count == GearAttachmentLoader.maxFileBytes)
    }

    @Test func pdfFromFilesKeepsItsBytesNameAndTypeAndGetsAJPEGThumbnail() async throws {
        let url = try temporaryPDF()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let bytes = try Data(contentsOf: url)
        let file = try #require(loaded(await GearAttachmentLoader.load(url: url)))
        #expect(file.data == bytes)
        #expect(file.filename == "Service report.pdf")
        #expect(file.contentType == .pdf)
        // Quick Look's thumbnail, drawn on white: JPEG, never PNG.
        #expect(isJPEG(file.thumbnail))
    }

    // MARK: - Quick Look Copy Name

    @Test func copyNameKeepsTheOriginalNameElseUsesTheTitleAndType() {
        let attachment = GearAttachment()
        attachment.originalFilename = "Receipt 2026.pdf"
        #expect(GearAttachmentsSection.fileName(attachment, fallback: "Title") == "Receipt 2026.pdf")

        let photo = GearAttachment()
        photo.contentType = UTType.jpeg.identifier
        #expect(GearAttachmentsSection.fileName(photo, fallback: "Octopus: front/back") == "Octopus- front-back.jpeg")
    }

    @Test func originalNameWithoutExtensionTakesTheTypes() {
        let scan = GearAttachment()
        scan.originalFilename = "Scan"
        scan.contentType = UTType.pdf.identifier
        #expect(GearAttachmentsSection.fileName(scan, fallback: "Title") == "Scan.pdf")
    }

    @Test func copyNameStaysUnderTheFileSystemLimitInAnyScript() {
        let photo = GearAttachment()
        photo.contentType = UTType.jpeg.identifier
        // 150 three-byte characters (450 bytes) and 150 emoji (600 bytes).
        for title in [String(repeating: "潜", count: 150), String(repeating: "🤿", count: 150)] {
            let name = GearAttachmentsSection.fileName(photo, fallback: title)
            #expect(name.utf8.count <= 255)
            #expect(name.hasSuffix(".jpeg"))
        }
    }

    @Test func blankTitleGivesAUsableName() {
        let photo = GearAttachment()
        // In the app language (the fallback is localized).
        let expected = NSLocalizedString("Attachment", bundle: Bundle.forAppLanguage(), value: "Attachment", comment: "")
        #expect(GearAttachmentsSection.fileName(photo, fallback: "   ") == expected)
    }

    // MARK: - Quick Look Copies

    @Test func writeCopyWritesTheBytesUnchangedAndReadOnly() async throws {
        let bytes = Data((0..<200).map { UInt8($0) })
        let result = await QuickLookCopies.writeCopy(load: { bytes }, name: { _ in "copy.bin" })
        guard case .written(let url, let byteCount) = result else {
            Issue.record("Expected a written copy, got \(result)")
            return
        }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(url.lastPathComponent == "copy.bin")
        #expect(byteCount == bytes.count)
        #expect(try Data(contentsOf: url) == bytes)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o444)
    }

    @Test func writeCopyReportsMissingBytes() async {
        let result = await QuickLookCopies.writeCopy(load: { nil }, name: { _ in "missing.bin" })
        guard case .noData = result else {
            Issue.record("Expected noData, got \(result)")
            return
        }
    }

    @Test func writeCopyReportsAFailedWrite() async {
        // A name over the file system's 255-byte limit cannot be written.
        let tooLong = String(repeating: "a", count: 300)
        let result = await QuickLookCopies.writeCopy(load: { Data([1, 2, 3]) }, name: { _ in tooLong })
        guard case .failed = result else {
            Issue.record("Expected failed, got \(result)")
            return
        }
    }
}
