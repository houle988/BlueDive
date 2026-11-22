import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import QuickLook
import QuickLookThumbnailing
import ImageIO
import CryptoKit

// MARK: - Picked File

/// A file picked for a new attachment, read and prepared before the attachment is saved.
struct PendingAttachmentFile: Identifiable, Sendable {
    let id = UUID()
    /// The file's bytes, unchanged.
    let data: Data
    let filename: String?
    let contentType: UTType?
    /// Thumbnail (longest side ≤ 512 px; PNG when the image has transparency, else JPEG); nil
    /// when none could be made.
    let thumbnail: Data?
    let contentHash: Data
}

// MARK: - Loader

enum GearAttachmentLoader {
    /// Largest file accepted. Attachments sync through the user's iCloud storage, and are saved
    /// from the main context: receipts, warranties, reports and phone photos stay far below it.
    /// `nonisolated`: read by the `@concurrent` loaders, off the main actor.
    nonisolated static let maxFileBytes = 25_000_000

    enum LoadResult: Sendable {
        case loaded(PendingAttachmentFile)
        /// Larger than `maxFileBytes`: a file from Files is refused before it is read.
        case tooLarge
        case unreadable
    }

    /// Types offered in Files: images and PDF documents.
    static let allowedContentTypes: [UTType] = [.image, .pdf]

    /// Reads a file picked in Files. `@concurrent`: the read and the hash of the whole file run
    /// off the main actor (the callers are views). A file over `maxFileBytes` is refused from
    /// its size, before it is read.
    @concurrent nonisolated static func load(url: URL) async -> LoadResult {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        if let size = values?.fileSize, size > maxFileBytes { return .tooLarge }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return .unreadable }
        // The size may be unknown before the read (e.g. a file provider that reports none).
        guard data.count <= maxFileBytes else { return .tooLarge }
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        var thumbnail: Data?
        if type?.conforms(to: .image) == true {
            thumbnail = await imageThumbnail(data)
        }
        if thumbnail == nil {
            // Quick Look draws a PDF's first page, and images ImageIO cannot read (e.g. SVG).
            thumbnail = await quickLookThumbnail(url)
        }
        return .loaded(PendingAttachmentFile(data: data, filename: url.lastPathComponent, contentType: type,
                                             thumbnail: thumbnail, contentHash: Data(SHA256.hash(data: data))))
    }

    /// Prepares an image picked in Photos (its bytes as stored, no file name), off the main actor.
    /// Photos gives no size before loading, so the limit is checked here, before the hash. The
    /// type is read from the bytes: the item's first offered type can differ from the rendition
    /// it delivers (a Live Photo, a HEIC delivered as JPEG); `contentType` is only used when
    /// ImageIO cannot tell.
    @concurrent nonisolated static func load(data: Data, contentType: UTType?) async -> LoadResult {
        guard !data.isEmpty else { return .unreadable }
        guard data.count <= maxFileBytes else { return .tooLarge }
        let detected = CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceGetType($0) }
            .flatMap { UTType($0 as String) }
        let thumbnail = await imageThumbnail(data)
        return .loaded(PendingAttachmentFile(data: data, filename: nil, contentType: detected ?? contentType,
                                             thumbnail: thumbnail, contentHash: Data(SHA256.hash(data: data))))
    }

    /// Thumbnail of an image (longest side ≤ 512 px, oriented as displayed), made through
    /// `PhotoMetadataReader.onImageQueue` (ImageIO at default QoS, as the photo import: a
    /// detached task awaited here would be raised to the caller's priority). The photo
    /// import's JPEG thumbnail, except for an image with transparent pixels, kept as PNG: JPEG
    /// has no transparency, so a logo or a cut-out product photo would show black. An image
    /// with an alpha channel but no transparent pixel (a screenshot, a scan) stays JPEG.
    private nonisolated static func imageThumbnail(_ data: Data) async -> Data? {
        await PhotoMetadataReader.onImageQueue {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0 else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            guard properties?[kCGImagePropertyHasAlpha] as? Bool == true else {
                return PhotoMetadataReader.thumbnailJPEG(of: source, maxPixelSize: PhotoMetadataReader.thumbnailMaxPixelSize, quality: 0.8)
            }
            guard let image = PhotoMetadataReader.thumbnailImage(of: source, maxPixelSize: PhotoMetadataReader.thumbnailMaxPixelSize) else { return nil }
            return PhotoMetadataReader.encode(image, as: hasTransparentPixel(image) ? .png : .jpeg, quality: 0.8)
        }
    }

    /// Whether any pixel of `image` is not fully opaque (the image is ≤ 512 px: a cheap scan).
    /// True when it cannot be told, so a transparent image never turns black.
    private nonisolated static func hasTransparentPixel(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return true }
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 255 }
    }

    /// Quick Look's thumbnail (a PDF's first page, an image ImageIO cannot read), drawn on white
    /// and kept as JPEG: Quick Look returns every thumbnail with an alpha channel, which would
    /// otherwise make each one a PNG several times larger.
    private nonisolated static func quickLookThumbnail(_ url: URL) async -> Data? {
        let side = CGFloat(PhotoMetadataReader.thumbnailMaxPixelSize)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: 1, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = representation.cgImage
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        guard let opaque = context.makeImage() else { return nil }
        return PhotoMetadataReader.encode(opaque, as: .jpeg, quality: 0.8)
    }

    /// The bytes of a stored attachment file, read in a context of its own so a large file is
    /// never loaded on the main thread. Nil while the file has not arrived from iCloud, or when
    /// the record is gone (fetched, not `model(for:)`, whose placeholder for a missing record
    /// traps when read).
    nonisolated static func readFile(_ fileID: PersistentIdentifier, container: ModelContainer) -> Data? {
        let context = ModelContext(container)
        context.author = "BlueDive.gearAttachment"
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<GearAttachmentFile>(predicate: #Predicate { $0.persistentModelID == fileID })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.data
    }
}

// MARK: - Quick Look Copies

extension GearAttachment {
    /// Prefix of this attachment's Quick Look copy keys, which `QuickLookCopies.remove(ownerID:)`
    /// matches when the attachment, or its gear, is deleted.
    var quickLookOwnerID: String { "gear-attachment-\(id.uuidString)" }
}

extension Gear {
    /// Removes the Quick Look copies of this gear's attachments. Call it from every path that
    /// deletes a gear: its attachments go with it (cascade), and their copies should too.
    @MainActor func removeAttachmentQuickLookCopies() {
        for attachment in attachments ?? [] {
            QuickLookCopies.remove(ownerID: attachment.quickLookOwnerID)
        }
    }
}

// MARK: - Attachments Section

/// The Attachments card of a gear's page: its photos and documents, opened in Quick Look.
struct GearAttachmentsSection: View {
    let gear: Gear
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale

    private enum EditorMode: Identifiable {
        case new(PendingAttachmentFile)
        /// The id is captured when the sheet opens: `.sheet(item:)` reads it on every redraw,
        /// and the attachment may be deleted on another device meanwhile (reading a deleted
        /// model crashes).
        case edit(GearAttachment, id: UUID)
        var id: UUID {
            switch self {
            case .new(let file): return file.id
            case .edit(_, let id): return id
            }
        }
    }

    @State private var showPhotosPicker = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var isLoading = false
    @State private var editorMode: EditorMode?
    /// The one information alert shown (title, message, OK); one at a time.
    private enum Notice: Identifiable {
        case tooLarge, loadFailed, alreadyAttached, notDownloaded, openFailed
        var id: Self { self }
    }
    @State private var notice: Notice?
    /// The last notice shown, kept while the alert is dismissed: its title is read from here,
    /// so it does not change to another one when `notice` is cleared. Set through `show(_:)`.
    @State private var shownNotice: Notice = .openFailed
    @State private var deleteTarget: GearAttachment?
    @State private var showDeleteConfirmation = false
    @State private var quickLookURL: URL?
    /// The attachment whose Quick Look copy is being written; other opens wait for it.
    @State private var openingID: UUID?

    /// The gear's attachments not deleted (here or merged from another device), unsorted: for
    /// membership checks.
    private var liveAttachments: [GearAttachment] {
        (gear.attachments ?? []).filter { !$0.isDeleted && $0.modelContext != nil }
    }

    /// `liveAttachments` in display order, newest document date first.
    private var attachments: [GearAttachment] {
        liveAttachments.sorted { ($0.date, $0.createdAt) > ($1.date, $1.createdAt) }
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            content
        }
        .photosPicker(isPresented: $showPhotosPicker, selection: $pickedPhoto, matching: .images, preferredItemEncoding: .current)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            isLoading = true
            Task {
                defer { isLoading = false; pickedPhoto = nil }
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    show(.loadFailed)
                    return
                }
                handle(await GearAttachmentLoader.load(data: data, contentType: item.supportedContentTypes.first))
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: GearAttachmentLoader.allowedContentTypes) { result in
            // Cancelling does not call this: a failure is a file the system could not deliver.
            guard case .success(let url) = result else {
                show(.loadFailed)
                return
            }
            isLoading = true
            Task {
                defer { isLoading = false }
                handle(await GearAttachmentLoader.load(url: url))
            }
        }
        .sheet(item: $editorMode) { mode in
            Group {
                switch mode {
                case .new(let file): GearAttachmentEditor(gear: gear, newFile: file)
                case .edit(let attachment, _): GearAttachmentEditor(attachment: attachment)
                }
            }
            .standardSheetPresentation()
        }
        .alert(noticeTitle, isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }), presenting: notice) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            noticeMessage(notice)
        }
        .alert("Delete this attachment?", isPresented: $showDeleteConfirmation, presenting: deleteTarget) { target in
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                delete(target)
                deleteTarget = nil
            }
        } message: { _ in
            Text("The file is removed from this equipment.")
        }
        .quickLookPreview($quickLookURL)
    }

    // MARK: Notices

    /// One literal key per case (CLAUDE.md: never pass a runtime variable as the key).
    private var noticeTitle: Text {
        switch shownNotice {
        case .tooLarge: Text("File Too Large")
        case .loadFailed: Text("Could Not Add File")
        case .alreadyAttached: Text("Already Attached")
        case .notDownloaded: Text("Not Downloaded Yet")
        case .openFailed: Text("Could Not Open File")
        }
    }

    private func show(_ newNotice: Notice) {
        shownNotice = newNotice
        notice = newNotice
    }

    private func noticeMessage(_ notice: Notice) -> Text {
        switch notice {
        case .tooLarge:
            Text(verbatim: String(format: NSLocalizedString("Attachments are limited to %@. Choose a smaller file, or export a smaller version of this one.", bundle: Bundle.forAppLanguage(), value: "Attachments are limited to %@. Choose a smaller file, or export a smaller version of this one.", comment: "Alert message when a picked gear attachment is too large; the argument is a file size such as 25 MB"),
                                 Int64(GearAttachmentLoader.maxFileBytes).localizedFileSize))
        case .loadFailed: Text("The file could not be read.")
        case .alreadyAttached: Text("This file is already attached to this equipment.")
        case .notDownloaded: Text("This file has not finished downloading from iCloud. Try again in a moment.")
        case .openFailed: Text("The file could not be opened.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Label("Attachments", systemImage: "paperclip")
                .font(.title3)
                .fontWeight(.bold)
            Spacer()
            Menu {
                Button {
                    showPhotosPicker = true
                } label: {
                    // The same labels as the dive photos and species image menus.
                    Label("Apple Photos", systemImage: "photo.on.rectangle")
                }
                Button {
                    showFileImporter = true
                } label: {
                    Label("Import from Files", systemImage: "folder")
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.cyan)
                    .font(.title3)
                    // As the Add Service Record button on this page: about 48 × 44 pt on iOS.
                    .tapTargetInsets(top: 12, leading: 12, bottom: 8, trailing: 12)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isLoading)
            .accessibilityLabel(Text("Add Attachment"))
        }
        .padding(.horizontal)
    }

    // MARK: Content

    private var content: some View {
        let items = attachments
        return VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty && !isLoading {
                Text("No attachments yet. Add photos, receipts, warranties or service reports for this equipment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            ForEach(items) { attachment in
                row(attachment)
                if attachment.id != items.last?.id || isLoading {
                    Divider()
                        .padding(.horizontal, 4)
                }
            }
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
        .padding(.horizontal)
    }

    private func row(_ attachment: GearAttachment) -> some View {
        HStack(spacing: 12) {
            Button {
                open(attachment)
            } label: {
                HStack(spacing: 12) {
                    GearAttachmentThumbnailView(attachment: attachment)
                        .overlay {
                            // Its Quick Look copy is being written (a large file takes a moment).
                            if openingID == attachment.id {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: displayTitle(attachment))
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(verbatim: details(attachment))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // While another attachment's copy is being written, this one cannot open (one at a
            // time): dimmed, so the tap is not mistaken for a broken one.
            .disabled(openingID != nil)
            .opacity(openingID != nil && openingID != attachment.id ? 0.5 : 1)

            Menu {
                Button {
                    open(attachment)
                } label: {
                    Label("Open", systemImage: "eye")
                }
                .disabled(openingID != nil)
                Button {
                    editorMode = .edit(attachment, id: attachment.id)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    deleteTarget = attachment
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Attachment Actions"))
        }
        .padding(.vertical, 6)
    }

    // MARK: Text

    private func displayTitle(_ attachment: GearAttachment) -> String {
        let title = attachment.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if let name = attachment.originalFilename, !name.isEmpty { return name }
        return attachment.attachmentCategory.localizedName
    }

    /// "Receipt · 12 Mar 2026 · 1.2 MB".
    private func details(_ attachment: GearAttachment) -> String {
        [attachment.attachmentCategory.localizedName,
         attachment.date.formatted(.dateTime.day().month().year().locale(locale)),
         Int64(attachment.byteCount).localizedFileSize]
            .joined(separator: " · ")
    }

    // MARK: Actions

    /// Opens the editor for a loaded file, unless it is already attached to this gear; reports
    /// a file too large or unreadable.
    private func handle(_ result: GearAttachmentLoader.LoadResult) {
        switch result {
        case .loaded(let file):
            if liveAttachments.contains(where: { $0.contentHash == file.contentHash }) {
                show(.alreadyAttached)
            } else {
                editorMode = .new(file)
            }
        case .tooLarge: show(.tooLarge)
        case .unreadable: show(.loadFailed)
        }
    }

    /// Opens the file in Quick Look. Quick Look reads only files, so the bytes are written
    /// unchanged to a temporary copy, once per file (see `QuickLookCopies`). The bytes are read
    /// off the main thread, and only when no copy exists yet.
    private func open(_ attachment: GearAttachment) {
        // One copy written at a time: a second tap meanwhile would replace the first copy
        // while Quick Look shows it, or the first write would replace what the second opened.
        // The rows show it: dimmed and disabled meanwhile (`row`).
        guard openingID == nil else { return }
        guard let fileID = attachment.file?.persistentModelID else {
            show(.notDownloaded)
            return
        }
        let name = Self.fileName(attachment, fallback: displayTitle(attachment))
        let key = Self.quickLookKey(attachment, name: name)
        // The key holds the content hash: the copy is checked against the size it was written
        // with, not the stored `byteCount`.
        if let url = QuickLookCopies.copy(for: key) {
            quickLookURL = url
            return
        }
        let attachmentID = attachment.id
        let container = modelContext.container
        openingID = attachmentID
        Task {
            let result = await QuickLookCopies.writeCopy(
                load: { GearAttachmentLoader.readFile(fileID, container: container) },
                name: { _ in name })
            openingID = nil
            let url: URL
            switch result {
            case .written(let written, let byteCount):
                // Deleted during the write: its copy is removed, never recorded or shown.
                guard liveAttachments.contains(where: { $0.id == attachmentID }) else {
                    try? FileManager.default.removeItem(at: written.deletingLastPathComponent())
                    return
                }
                url = written
                QuickLookCopies.record(url, for: key, byteCount: byteCount)
            case .noData:
                // The file has not finished downloading from iCloud.
                show(.notDownloaded)
                return
            case .failed:
                show(.openFailed)
                return
            }
            // Shown even when Quick Look already shows another file, as a copy that already exists
            // is: the macOS panel does not block the sheet.
            quickLookURL = url
        }
    }

    private func delete(_ attachment: GearAttachment) {
        guard !attachment.isDeleted, attachment.modelContext != nil else { return }
        QuickLookCopies.remove(ownerID: attachment.quickLookOwnerID)
        modelContext.delete(attachment)
        try? modelContext.save()
    }

    /// One copy per file version and name (`QuickLookCopies.remove(ownerID:)` matches the
    /// prefix): a copy named after the title is written again once the title (or, for the
    /// fallback name, the app language) changes, so Quick Look and Share show the current name.
    private static func quickLookKey(_ attachment: GearAttachment, name: String) -> String {
        "\(attachment.quickLookOwnerID)|\(attachment.contentHash?.base64EncodedString() ?? String(attachment.byteCount))|\(name)"
    }

    /// The copy's file name: the original name, else the title with the type's extension.
    /// The name without its extension is cut to 200 UTF-8 bytes (whole characters), so a long
    /// title, in any script, cannot pass the file system's 255-byte limit.
    static func fileName(_ attachment: GearAttachment, fallback: String) -> String {
        let stem: String
        let ext: String?
        if let original = attachment.originalFilename, !original.isEmpty {
            let url = URL(fileURLWithPath: original)
            stem = url.deletingPathExtension().lastPathComponent
            // A name without an extension takes the stored type's, so Quick Look recognizes it.
            ext = url.pathExtension.isEmpty
                ? attachment.contentType.flatMap { UTType($0)?.preferredFilenameExtension }
                : url.pathExtension
        } else {
            stem = fallback
            ext = attachment.contentType.flatMap { UTType($0)?.preferredFilenameExtension }
        }
        var cleaned = ""
        for character in stem.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") {
            guard cleaned.utf8.count + String(character).utf8.count <= 200 else { break }
            cleaned.append(character)
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            cleaned = NSLocalizedString("Attachment", bundle: Bundle.forAppLanguage(), value: "Attachment", comment: "File name of a gear attachment opened in Quick Look when it has no usable name")
        }
        return ext.map { "\(cleaned).\($0)" } ?? cleaned
    }
}

// MARK: - Thumbnail

/// An attachment's thumbnail, or a placeholder while it has none (never the file itself).
private struct GearAttachmentThumbnailView: View {
    let attachment: GearAttachment
    @State private var image: PlatformImage?

    private let size: CGFloat = 44

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.cyan.opacity(0.12)
                    Image(systemName: attachment.isPDF ? "doc.richtext" : attachment.attachmentCategory.icon)
                        .foregroundStyle(.cyan)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
        .task(id: attachment.thumbnail?.persistentModelID) {
            guard let data = attachment.thumbnailBytes else {
                image = nil
                return
            }
            // At default QoS through the image queue (as the photo tiles); nil: the row went away
            // while waiting for its turn (nothing decoded).
            guard let decoded = await PhotoMetadataReader.onImageQueueUnlessCancelled({ PlatformImage(data: data) }),
                  !Task.isCancelled else { return }
            image = decoded
        }
    }
}

// MARK: - Editor

/// Adds a picked file to a gear, or edits an attachment's title, category, date and note.
struct GearAttachmentEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    private let gear: Gear?
    private let newFile: PendingAttachmentFile?
    private let attachment: GearAttachment?
    /// Read once when the sheet opens: the body never reads the attachment, which another
    /// device may delete while the sheet is shown.
    private let fileName: String?
    private let byteCount: Int

    @State private var title: String
    @State private var note: String
    /// `GearAttachmentCategory` raw value; an unknown stored value (written by a newer version)
    /// is offered as its own choice, so choosing Other replaces it.
    @State private var category: String
    /// The stored category when it is not one this version knows.
    private let unknownCategory: String?
    @State private var date: Date

    init(gear: Gear, newFile: PendingAttachmentFile) {
        self.gear = gear
        self.newFile = newFile
        self.attachment = nil
        self.fileName = newFile.filename
        self.byteCount = newFile.data.count
        _title = State(initialValue: "")
        _note = State(initialValue: "")
        let isImage = newFile.contentType?.conforms(to: .image) == true
        _category = State(initialValue: (isImage ? GearAttachmentCategory.photo : .other).rawValue)
        self.unknownCategory = nil
        _date = State(initialValue: Date.now)
    }

    init(attachment: GearAttachment) {
        self.gear = nil
        self.newFile = nil
        self.attachment = attachment
        self.fileName = attachment.originalFilename
        self.byteCount = attachment.byteCount
        _title = State(initialValue: attachment.title)
        _note = State(initialValue: attachment.note ?? "")
        _category = State(initialValue: attachment.category)
        self.unknownCategory = GearAttachmentCategory(rawValue: attachment.category) == nil ? attachment.category : nil
        _date = State(initialValue: attachment.date)
    }

    private var isNew: Bool { newFile != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    formTextField("Title", text: $title)
                        .overlay(alignment: .trailing) {
                            if !title.isEmpty {
                                Button {
                                    title = ""
                                } label: {
                                    ClearButtonGlyph()
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 4)
                            }
                        }
                }

                Section {
                    Picker("Category", selection: $category) {
                        ForEach(GearAttachmentCategory.allCases) { option in
                            #if os(macOS)
                            // Text only: the macOS menu draws its icons in the root cyan tint,
                            // the colour of its selection, so the highlighted row's icon would
                            // vanish (no foreground style changes it).
                            Text(verbatim: option.localizedName)
                                .tag(option.rawValue)
                            #else
                            Label {
                                Text(verbatim: option.localizedName)
                            } icon: {
                                Image(systemName: option.icon)
                            }
                            .tag(option.rawValue)
                            #endif
                        }
                        if let unknownCategory {
                            Text(verbatim: unknownCategory)
                                .tag(unknownCategory)
                        }
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                        .adaptiveDatePickerStyle()
                }

                Section("Note") {
                    // A text editor, as the dive and certification notes: Return starts a
                    // new line on every platform and keyboard.
                    TextEditor(text: $note)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 100)
                        .accessibilityLabel(Text("Note"))
                        .overlay(alignment: .topTrailing) {
                            if !note.isEmpty {
                                Button {
                                    note = ""
                                } label: {
                                    ClearButtonGlyph()
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 8)
                                .padding(.trailing, 4)
                            }
                        }
                }

                Section("File") {
                    if let fileName, !fileName.isEmpty {
                        LabeledContent("Name") {
                            Text(verbatim: fileName)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    LabeledContent("Size") {
                        Text(verbatim: Int64(byteCount).localizedFileSize)
                    }
                }
            }
            .groupedFormStyleOnMac()
            .navigationTitle(isNew ? Text("Add Attachment") : Text("Edit Attachment"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Cancel")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    #if os(iOS)
                    .buttonStyle(.borderedProminent)
                    #endif
                }
            }
        }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let newFile, let gear {
            // The gear may have been deleted on another device while the sheet was open: an
            // attachment saved to it would have no owner and keep its file in iCloud forever.
            guard !gear.isDeleted, gear.modelContext != nil else {
                dismiss()
                return
            }
            let record = GearAttachment()
            modelContext.insert(record)
            record.gear = gear
            record.title = trimmedTitle
            record.note = trimmedNote.isEmpty ? nil : trimmedNote
            record.category = category
            record.date = date
            record.originalFilename = newFile.filename
            record.contentType = newFile.contentType?.identifier
            record.byteCount = newFile.data.count
            record.contentHash = newFile.contentHash
            record.setFile(newFile.data)
            record.setThumbnail(newFile.thumbnail)
        } else if let attachment, !attachment.isDeleted, attachment.modelContext != nil {
            if attachment.title != trimmedTitle { attachment.title = trimmedTitle }
            let storedNote = trimmedNote.isEmpty ? nil : trimmedNote
            if attachment.note != storedNote { attachment.note = storedNote }
            // An unknown stored category (written by a newer version) is kept unless changed.
            if category != attachment.category { attachment.category = category }
            if attachment.date != date { attachment.date = date }
        }
        try? modelContext.save()
        dismiss()
    }
}
