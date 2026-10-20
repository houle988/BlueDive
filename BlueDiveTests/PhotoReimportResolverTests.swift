import Foundation
import Testing
@testable import BlueDive

/// The re-import rules (`PhotoReimportResolver`): a stored photo is replaced only by a newer
/// version of the same shot; every uncertain match asks.
struct PhotoReimportResolverTests {

    private let dive = UUID()
    private let otherDive = UUID()
    private let capture = DateComponents(year: 2026, month: 8, day: 22, hour: 11, minute: 22, second: 41)
    private let earlier = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var later: Date { earlier.addingTimeInterval(3600) }

    private func incoming(hash: UInt8 = 1, capture: DateComponents?? = nil, subsecond: String? = nil,
                          filename: String? = "PANA0202.jpg", edited: Date? = nil,
                          size: (Int, Int) = (4000, 3000), correction: Double? = nil) -> PhotoReimportResolver.Incoming {
        PhotoReimportResolver.Incoming(contentHash: Data([hash]), capture: capture ?? self.capture,
                                       subsecond: subsecond, filename: filename, edited: edited,
                                       pixelWidth: size.0, pixelHeight: size.1, diveID: dive,
                                       clockAdjustment: correction)
    }

    private func stored(id: UUID = UUID(), dive: UUID? = nil, hash: UInt8 = 9, capture: DateComponents? = nil,
                        subsecond: String? = nil, filename: String? = "PANA0202.jpg", edited: Date? = nil,
                        size: (Int, Int) = (4000, 3000), known: Bool = true,
                        correction: Double = 0) -> PhotoReimportResolver.Stored {
        PhotoReimportResolver.Stored(id: id, diveID: dive ?? self.dive, contentHash: Data([hash]),
                                     capture: capture ?? self.capture, subsecond: subsecond, filename: filename,
                                     edited: edited, pixelWidth: size.0, pixelHeight: size.1, identityKnown: known,
                                     clockAdjustment: correction)
    }

    // MARK: Rule 0 — the identical file

    @Test func sameFileOnSameDiveIsAlready() {
        let photo = stored(hash: 1)
        #expect(PhotoReimportResolver.resolve(incoming(), sameFile: [photo], sameTime: []) == .already(photo.id))
    }

    @Test func sameFileOnOtherDiveAsks() {
        let photo = stored(dive: otherDive, hash: 1)
        #expect(PhotoReimportResolver.resolve(incoming(), sameFile: [photo], sameTime: [])
                == .ask(.sameFileOnOtherDive, candidates: [photo.id]))
    }

    // MARK: Rules 1–3 — finding the same shot

    @Test func noCaptureTimeIsNew() {
        #expect(PhotoReimportResolver.resolve(incoming(capture: .some(nil)), sameFile: [], sameTime: [stored()]) == .new)
    }

    @Test func noCandidateIsNew() {
        #expect(PhotoReimportResolver.resolve(incoming(), sameFile: [], sameTime: []) == .new)
    }

    @Test func oneSecondApartIsNew() {
        var next = capture
        next.second = 42
        #expect(PhotoReimportResolver.resolve(incoming(), sameFile: [], sameTime: [stored(capture: next)]) == .new)
    }

    @Test func sameClockTimeOtherDayIsNew() {
        var nextDay = capture
        nextDay.day = 23
        #expect(PhotoReimportResolver.resolve(incoming(), sameFile: [], sameTime: [stored(capture: nextDay)]) == .new)
    }

    @Test func differentSubsecondsAreAnotherShot() {
        #expect(PhotoReimportResolver.resolve(incoming(subsecond: "37"), sameFile: [],
                                              sameTime: [stored(subsecond: "38")]) == .new)
    }

    @Test func subsecondsCompareAsFractions() {
        let photo = stored(subsecond: "370", edited: earlier)
        #expect(PhotoReimportResolver.resolve(incoming(subsecond: "37", edited: later), sameFile: [],
                                              sameTime: [photo]) == .update(photo.id))
    }

    @Test func subsecondOnOneSideOnlyStillMatches() {
        let photo = stored(subsecond: nil, edited: earlier)
        #expect(PhotoReimportResolver.resolve(incoming(subsecond: "37", edited: later), sameFile: [],
                                              sameTime: [photo]) == .update(photo.id))
    }

    // MARK: Rule 4 — only one clear candidate is replaced without asking

    @Test func severalMatchesAsk() {
        let a = stored(), b = stored(filename: "PANA0202-2.jpg")
        #expect(PhotoReimportResolver.resolve(incoming(edited: later), sameFile: [], sameTime: [a, b])
                == .ask(.severalMatches, candidates: [a.id, b.id]))
    }

    @Test func otherDiveAsks() {
        let photo = stored(dive: otherDive, edited: earlier)
        #expect(PhotoReimportResolver.resolve(incoming(edited: later), sameFile: [], sameTime: [photo])
                == .ask(.otherDive, candidates: [photo.id]))
    }

    @Test func differentFilenameAsks() {
        let photo = stored(filename: "PANA0202-2.jpg", edited: earlier)
        #expect(PhotoReimportResolver.resolve(incoming(edited: later), sameFile: [], sameTime: [photo])
                == .ask(.differentFilename, candidates: [photo.id]))
    }

    @Test func filenameComparisonIgnoresCase() {
        let photo = stored(filename: "pana0202.JPG", edited: earlier)
        #expect(PhotoReimportResolver.resolve(incoming(edited: later), sameFile: [], sameTime: [photo]) == .update(photo.id))
    }

    @Test func noFilenameAsks() {
        let photo = stored(edited: earlier)
        #expect(PhotoReimportResolver.resolve(incoming(filename: nil, edited: later), sameFile: [], sameTime: [photo])
                == .ask(.noFilename, candidates: [photo.id]))
    }

    @Test func unreadableStoredIdentityAsks() {
        let photo = stored(known: false)
        #expect(PhotoReimportResolver.resolve(incoming(edited: later), sameFile: [], sameTime: [photo])
                == .ask(.notComparable, candidates: [photo.id]))
    }

    @Test func candidateUsedEarlierInImportAsks() {
        let photo = stored(edited: earlier)
        #expect(PhotoReimportResolver.resolve(incoming(edited: later), sameFile: [], sameTime: [photo], used: [photo.id])
                == .ask(.alreadyUsed, candidates: [photo.id]))
    }

    // MARK: Rule 5 — newer replaces, older or the same version is skipped

    @Test func newerVersionUpdates() {
        let photo = stored(edited: earlier)
        #expect(PhotoReimportResolver.resolve(incoming(edited: later), sameFile: [], sameTime: [photo]) == .update(photo.id))
    }

    @Test func croppedNewerVersionUpdates() {
        let photo = stored(edited: earlier)
        #expect(PhotoReimportResolver.resolve(incoming(edited: later, size: (3000, 2000)), sameFile: [],
                                              sameTime: [photo]) == .update(photo.id))
    }

    @Test func olderVersionIsSkipped() {
        let photo = stored(edited: later)
        #expect(PhotoReimportResolver.resolve(incoming(edited: earlier), sameFile: [], sameTime: [photo]) == .older(photo.id))
    }

    @Test func sameVersionIsAlready() {
        let photo = stored(edited: earlier)
        #expect(PhotoReimportResolver.resolve(incoming(edited: earlier.addingTimeInterval(0.4)), sameFile: [],
                                              sameTime: [photo]) == .already(photo.id))
    }

    @Test func sameVersionOtherSizeAsks() {
        let photo = stored(edited: earlier)
        #expect(PhotoReimportResolver.resolve(incoming(edited: earlier, size: (1600, 1200)), sameFile: [], sameTime: [photo])
                == .ask(.sameDateDifferentSize, candidates: [photo.id]))
    }

    @Test func unknownDateSameSizeUpdates() {
        let photo = stored(edited: nil)
        #expect(PhotoReimportResolver.resolve(incoming(edited: nil), sameFile: [], sameTime: [photo]) == .update(photo.id))
    }

    @Test func unknownDateSmallerFileAsks() {
        let photo = stored(edited: earlier)
        #expect(PhotoReimportResolver.resolve(incoming(edited: nil, size: (1600, 1200)), sameFile: [], sameTime: [photo])
                == .ask(.smallerWithoutDate, candidates: [photo.id]))
    }

    // MARK: Another camera-clock correction — moving or re-timing a photo always asks

    @Test func sameFileWithAnotherCorrectionAsks() {
        let photo = stored(hash: 1, correction: 0)
        #expect(PhotoReimportResolver.resolve(incoming(correction: 3600), sameFile: [photo], sameTime: [])
                == .ask(.sameFileOtherCorrection, candidates: [photo.id]))
    }

    @Test func sameFileWithTheCorrectionOnAnyCopyIsAlready() {
        let other = stored(hash: 1, correction: 0)
        let match = stored(hash: 1, correction: 3600)
        for copies in [[other, match], [match, other]] {
            #expect(PhotoReimportResolver.resolve(incoming(correction: 3600), sameFile: copies, sameTime: []) == .already(match.id))
        }
    }

    @Test func sameFileWithinOneSecondOfTheCorrectionIsAlready() {
        let photo = stored(hash: 1, correction: 3600)
        #expect(PhotoReimportResolver.resolve(incoming(correction: 3600.4), sameFile: [photo], sameTime: []) == .already(photo.id))
    }

    @Test func noCorrectionGivenNeverAsksAboutIt() {
        let photo = stored(hash: 1, correction: 3600)
        #expect(PhotoReimportResolver.resolve(incoming(correction: nil), sameFile: [photo], sameTime: []) == .already(photo.id))
    }

    @Test func newerVersionWithAnotherCorrectionAsks() {
        let photo = stored(edited: earlier, correction: 0)
        #expect(PhotoReimportResolver.resolve(incoming(edited: later, correction: 600), sameFile: [], sameTime: [photo])
                == .ask(.otherCorrection, candidates: [photo.id]))
    }

    @Test func sameVersionWithAnotherCorrectionAsks() {
        let photo = stored(edited: earlier, correction: 0)
        #expect(PhotoReimportResolver.resolve(incoming(edited: earlier, correction: 600), sameFile: [], sameTime: [photo])
                == .ask(.otherCorrection, candidates: [photo.id]))
    }

    @Test func olderVersionWithAnotherCorrectionIsSkipped() {
        let photo = stored(edited: later, correction: 0)
        #expect(PhotoReimportResolver.resolve(incoming(edited: earlier, correction: 600), sameFile: [], sameTime: [photo])
                == .older(photo.id))
    }

    @Test func newerVersionWithTheSameCorrectionUpdates() {
        let photo = stored(edited: earlier, correction: 600)
        #expect(PhotoReimportResolver.resolve(incoming(edited: later, correction: 600), sameFile: [], sameTime: [photo])
                == .update(photo.id))
    }

    // MARK: Dates read from files

    @Test(arguments: ["2026:08:22 11:22:41", "2026-08-22T11:22:41.37+02:00", "2026-08-22T11:22:41-05:00",
                      "2026-08-22T11:22:41Z"])
    func exifAndXMPDatesParseToWallClock(_ text: String) {
        let parsed = PhotoMetadataReader.exifDateComponents(text)
        #expect(parsed.map { PhotoReimportResolver.sameSecond($0, capture) } == true)
    }

    @Test(arguments: ["2026-08-22T11:22Z", "2026-08-22T11:22-05:00", "2026-08-22T11:22+02:00"])
    func dateWithoutSecondsIsRejected(_ text: String) {
        #expect(PhotoMetadataReader.exifDateComponents(text) == nil)
    }
}
