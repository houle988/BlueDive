import Foundation
import ImageIO

// MARK: - Scanned Photo

/// A file chosen for a batch photo import, scanned for its capture time before anything is
/// stored. Only the capture time and a small preview are read; the image itself is read
/// again (and copied unchanged) when the photo is imported.
nonisolated struct ScannedPhotoFile: Sendable {
    let url: URL
    let filename: String
    /// Wall-clock capture time from EXIF; nil when the file has none.
    let capture: DateComponents?
    /// Small JPEG preview for the review list.
    let preview: Data?
    /// False when the file is not an image ImageIO can open.
    let isImage: Bool

    /// Reads the capture time and a preview without loading the whole image.
    static func scan(_ url: URL) -> ScannedPhotoFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let filename = url.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            return ScannedPhotoFile(url: url, filename: filename, capture: nil, preview: nil, isImage: false)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any] ?? [:]
        // Same capture time and thumbnail rules as the import itself (PhotoMetadataReader).
        return ScannedPhotoFile(url: url, filename: filename,
                                capture: PhotoMetadataReader.captureComponents(from: properties),
                                preview: PhotoMetadataReader.thumbnailJPEG(of: source, maxPixelSize: 160, quality: 0.7,
                                                                            usingEmbeddedPreview: true),
                                isImage: true)
    }
}

// MARK: - Photo Dive Matcher

/// Finds the dive a photo was taken during: the dive whose start ≤ capture time ≤ end
/// (strict, both wall-clock times, as MacDive does). Works from the dive list's summaries;
/// the precise end of a candidate (profile length) is checked by the caller.
struct PhotoDiveMatcher {

    struct DiveWindow {
        let id: UUID
        /// Wall-clock start, as a date in UTC (so a daylight-saving change cannot shift it).
        let startUTC: Date
        /// Generous end used to find candidates before the precise check.
        let searchEnd: Date
        let diverName: String
    }

    /// Slack added to the summary's whole-minute duration when looking for candidates: the
    /// recorded profile can run past it. The strict end is checked with the precise duration.
    static let searchSlackSeconds = 600

    /// Sorted by start, so a capture time is matched with a binary search instead of a scan
    /// of every dive (the clock-correction stepper re-matches every photo on each tap).
    private let windows: [DiveWindow]
    /// The longest window (start to search end), bounding how far back a candidate can start.
    private let longestWindow: TimeInterval

    init(summaries: [DiveSummary]) {
        let built: [DiveWindow] = summaries.compactMap { summary in
            guard let start = WallClock.utcCalendar.date(from: WallClock.components(ofStored: summary.timestamp)) else { return nil }
            // Same rule as DiveSummary.shortFormattedDuration: ≥ 3600 is already seconds.
            let seconds = summary.duration >= 3600 ? summary.duration : summary.duration * 60
            return DiveWindow(id: summary.id, startUTC: start,
                              searchEnd: start.addingTimeInterval(Double(seconds + Self.searchSlackSeconds)),
                              diverName: summary.diverName)
        }
        windows = built.sorted { $0.startUTC < $1.startUTC }
        longestWindow = built.map { $0.searchEnd.timeIntervalSince($0.startUTC) }.max() ?? 0
    }

    /// Dives that may contain the capture time (before the precise end check).
    func candidates(for capture: DateComponents, clockAdjustment: Double) -> [DiveWindow] {
        guard let time = WallClock.utcCalendar.date(from: capture)?.addingTimeInterval(clockAdjustment) else { return [] }
        // First window that could still contain `time` (starting no earlier than `time` minus
        // the longest window), then forward while windows start before `time`.
        let earliestStart = time.addingTimeInterval(-longestWindow)
        var low = 0, high = windows.count
        while low < high {
            let mid = (low + high) / 2
            if windows[mid].startUTC < earliestStart { low = mid + 1 } else { high = mid }
        }
        var result: [DiveWindow] = []
        var index = low
        while index < windows.count, windows[index].startUTC <= time {
            if time <= windows[index].searchEnd { result.append(windows[index]) }
            index += 1
        }
        return result
    }
}
