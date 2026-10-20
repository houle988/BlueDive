import Foundation

// MARK: - Photo Re-import Resolver

/// Decides what to do with an imported file that may already be in BlueDive — a photo
/// re-published from Lightroom after an edit (its bytes change every time, so the file hash
/// alone does not recognise it). Pure: the importer passes in the stored photos to compare
/// with, so the rules can be tested on their own.
///
/// A stored photo is replaced silently only when it is, without doubt, the same shot: same
/// capture time to the second (and sub-second when both files have one), on the dive the
/// file goes to, with the same file name, and the incoming file is the newer version. Every
/// other match is a question for the user (`Verdict.ask`), so no photo is ever replaced by a
/// different one.
nonisolated enum PhotoReimportResolver {

    /// A file being imported.
    struct Incoming: Sendable {
        var contentHash: Data
        /// Wall-clock capture time (whole seconds); nil when the file has none.
        var capture: DateComponents?
        var subsecond: String?
        var filename: String?
        /// Last edit or export time (`DivePhoto.metadataDate` convention); nil when unknown.
        var edited: Date?
        var pixelWidth: Int
        var pixelHeight: Int
        /// The dive the file is being imported into.
        var diveID: UUID
        /// Camera-clock correction (seconds) entered for this import; nil when the import has
        /// none to offer (a dive's own Add Photo), so a stored correction is never changed.
        var clockAdjustment: Double? = nil
    }

    /// A photo already in BlueDive.
    struct Stored: Sendable, Equatable {
        var id: UUID
        var diveID: UUID?
        var contentHash: Data?
        var capture: DateComponents?
        var subsecond: String?
        var filename: String?
        var edited: Date?
        var pixelWidth: Int
        var pixelHeight: Int
        /// False when its sub-second and edit time could not be read (an older photo whose
        /// original has not been downloaded from iCloud yet): it cannot be compared safely.
        var identityKnown: Bool
        /// Its camera-clock correction (seconds).
        var clockAdjustment: Double = 0
    }

    /// Why a file needs the user's decision.
    enum Reason: Sendable, Equatable {
        /// The identical file is already on another dive.
        case sameFileOnOtherDive
        /// A photo taken at the same time is on another dive.
        case otherDive
        /// A photo taken at the same time has another file name (e.g. a Lightroom virtual
        /// copy, or a buddy's camera).
        case differentFilename
        /// No file name to compare (a photo picked in the Photos library).
        case noFilename
        /// Several stored photos were taken at the same time.
        case severalMatches
        /// The stored photo's identity could not be read.
        case notComparable
        /// An earlier file of the same import already matched this stored photo.
        case alreadyUsed
        /// Neither file says when it was edited, and the incoming one is smaller (e.g. an
        /// export for the web): it must not replace a full-size original silently.
        case smallerWithoutDate
        /// Same edit time, but a different size: another export of the same version.
        case sameDateDifferentSize
        /// The identical file is on the dive with another camera-clock correction.
        case sameFileOtherCorrection
        /// The same shot (a newer or the same version) is on the dive with another
        /// camera-clock correction.
        case otherCorrection
    }

    enum Verdict: Sendable, Equatable {
        /// Not in BlueDive: import as a new photo.
        case new
        /// Already in BlueDive (same file, or the same version): skip.
        case already(UUID)
        /// The stored photo is a newer version: skip.
        case older(UUID)
        /// A newer version of this stored photo: replace it.
        case update(UUID)
        /// Ask the user; `candidates` are the stored photos it may replace.
        case ask(Reason, candidates: [UUID])
    }

    /// Edit times closer than this count as the same (TIFF `DateTime` has whole seconds).
    static let sameEditTolerance: TimeInterval = 1
    /// Clock corrections closer than this count as the same.
    static let sameCorrectionTolerance: TimeInterval = 1

    /// The import gives a clock correction other than the stored photo's. Changing it moves
    /// the photo on its profile (or to another dive), so it is never done without asking.
    static func correctionDiffers(_ incoming: Incoming, _ stored: Stored) -> Bool {
        guard let new = incoming.clockAdjustment else { return false }
        return abs(new - stored.clockAdjustment) >= sameCorrectionTolerance
    }

    /// - Parameters:
    ///   - sameFile: stored photos with the incoming file's hash, in any dive.
    ///   - sameTime: stored photos whose capture time is close to the incoming one (the caller
    ///     queries a window); filtered here to the same second.
    ///   - used: stored photos an earlier file of this import already matched.
    static func resolve(_ incoming: Incoming, sameFile: [Stored], sameTime: [Stored],
                        used: Set<UUID> = []) -> Verdict {
        // 0. The identical file.
        // Already there when any copy on the dive has the import's correction.
        let here = sameFile.filter { $0.diveID == incoming.diveID }
        if let match = here.first(where: { !correctionDiffers(incoming, $0) }) {
            return .already(match.id)
        }
        if !here.isEmpty {
            return .ask(.sameFileOtherCorrection, candidates: here.map(\.id))
        }
        if !sameFile.isEmpty {
            return .ask(.sameFileOnOtherDive, candidates: sameFile.map(\.id))
        }
        // 1. No capture time: nothing to recognise it by.
        guard let capture = incoming.capture else { return .new }
        // 2. Photos taken in the same second (and sub-second, when both have one).
        let matches = sameTime.filter { stored in
            guard let storedCapture = stored.capture, sameSecond(storedCapture, capture) else { return false }
            guard let a = normalisedSubsecond(incoming.subsecond),
                  let b = normalisedSubsecond(stored.subsecond) else { return true }
            return a == b
        }
        // 3. None: another photo.
        guard let candidate = matches.first else { return .new }
        // 4. Only one clear candidate may be replaced without asking.
        let ids = matches.map(\.id)
        guard matches.count == 1 else { return .ask(.severalMatches, candidates: ids) }
        if used.contains(candidate.id) { return .ask(.alreadyUsed, candidates: ids) }
        guard candidate.diveID == incoming.diveID else { return .ask(.otherDive, candidates: ids) }
        guard let incomingName = incoming.filename, let storedName = candidate.filename else {
            return .ask(.noFilename, candidates: ids)
        }
        guard incomingName.caseInsensitiveCompare(storedName) == .orderedSame else {
            return .ask(.differentFilename, candidates: ids)
        }
        guard candidate.identityKnown else { return .ask(.notComparable, candidates: ids) }
        // 5. The same shot: newer replaces, older or same is skipped. A newer or the same
        // version imported with another clock correction asks: replacing it would move it.
        let otherCorrection = correctionDiffers(incoming, candidate)
        let replace: Verdict = otherCorrection ? .ask(.otherCorrection, candidates: ids) : .update(candidate.id)
        let incomingPixels = incoming.pixelWidth * incoming.pixelHeight
        let storedPixels = candidate.pixelWidth * candidate.pixelHeight
        if let new = incoming.edited, let old = candidate.edited {
            let delta = new.timeIntervalSince(old)
            if abs(delta) < sameEditTolerance {
                guard incomingPixels == storedPixels else { return .ask(.sameDateDifferentSize, candidates: ids) }
                return otherCorrection ? .ask(.otherCorrection, candidates: ids) : .already(candidate.id)
            }
            return delta > 0 ? replace : .older(candidate.id)
        }
        // An edit time is unknown: replace only when nothing would shrink.
        return incomingPixels >= storedPixels ? replace : .ask(.smallerWithoutDate, candidates: ids)
    }

    /// Same wall-clock date and time to the second.
    static func sameSecond(_ a: DateComponents, _ b: DateComponents) -> Bool {
        a.year == b.year && a.month == b.month && a.day == b.day
            && a.hour == b.hour && a.minute == b.minute && a.second == b.second
    }

    /// Sub-seconds compared as a fraction: "37" and "370" are the same; nil when absent.
    static func normalisedSubsecond(_ text: String?) -> String? {
        guard let digits = text?.trimmingCharacters(in: .whitespaces), !digits.isEmpty,
              digits.allSatisfy(\.isNumber) else { return nil }
        let trimmed = String(digits.reversed().drop(while: { $0 == "0" }).reversed())
        return trimmed.isEmpty ? "0" : trimmed
    }
}
