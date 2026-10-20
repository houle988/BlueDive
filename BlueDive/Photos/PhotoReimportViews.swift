import SwiftUI
import SwiftData

// MARK: - Re-import Decisions

/// The files an import could not decide on (`PhotoImporter.ReimportQuestion`), one row each:
/// the file, why BlueDive asks, and a choice — update a stored photo, keep both, or skip.
/// Each row starts on its question's default (Keep both, or Skip for a copy of a file already
/// in BlueDive), so nothing is replaced, moved or lost without a deliberate choice.
/// A Form section, shared by the batch import and a dive's photo import.
struct PhotoReimportSection: View {
    let questions: [PhotoImporter.ReimportQuestion]
    @Binding var answers: [UUID: PhotoImporter.ReimportChoice]
    @Environment(\.locale) private var locale

    var body: some View {
        Section {
            if questions.count > 1 {
                Menu {
                    Button("Keep both") { setAll(.keepBoth) }
                    Button("Skip") { setAll(.skip) }
                    if questions.contains(where: canUpdate) {
                        Button("Update") { setAllToUpdate() }
                    }
                } label: {
                    Text("Set all to…")
                }
            }
            ForEach(questions) { question in
                row(question)
            }
        } header: {
            Text(verbatim: String(format: NSLocalizedString("Already in BlueDive? (%@)", bundle: .forAppLanguage(), value: "Already in BlueDive? (%@)", comment: "Section header: imported files that may already be in BlueDive, waiting for the user's decision, with their count"), Double(questions.count).localizedString(decimals: 0)))
        } footer: {
            // A dive's own Add Photo has no clock correction to give (it never changes one).
            if questions.contains(where: { $0.clockAdjustment != nil }) {
                Text("These files look like photos already in BlueDive. Update replaces the stored copy with the file and keeps its species; the photo takes this import's dive and camera clock correction. Keep both adds the file as a new photo. The files themselves are not changed.")
            } else {
                Text("These files look like photos already in BlueDive. Update replaces the stored copy with the file and keeps its species; the photo is placed on this dive. Keep both adds the file as a new photo. The files themselves are not changed.")
            }
        }
    }

    private func row(_ question: PhotoImporter.ReimportQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Group {
                    if let data = question.preview, let image = PlatformImage(data: data) {
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    if let filename = question.filename {
                        Text(verbatim: filename)
                            .font(.subheadline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let capture = question.capture {
                        Text(capture, format: .dateTime.day().month().year().hour().minute().second().locale(locale))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: Self.reasonText(question.reason))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let effect = updateEffect(question) {
                        Text(verbatim: effect)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Picker(selection: binding(for: question)) {
                if question.candidateDetails.count == 1, let candidate = question.candidateDetails.first {
                    // The same word as "Set all to…"; the row's text says what it does.
                    Text("Update").tag(PhotoImporter.ReimportChoice.update(candidate.photoID))
                } else {
                    ForEach(question.candidateDetails, id: \.photoID) { candidate in
                        Text(verbatim: updateLabel(candidate)).tag(PhotoImporter.ReimportChoice.update(candidate.photoID))
                    }
                }
                if question.offersKeepBoth {
                    Text("Keep both").tag(PhotoImporter.ReimportChoice.keepBoth)
                }
                Text("Skip").tag(PhotoImporter.ReimportChoice.skip)
            } label: {
                Text("Choice")
            }
            .labelsHidden()
            // Names the file the choice is for: VoiceOver reads the pickers one after another.
            .accessibilityLabel(question.filename.map { Text(verbatim: $0) } ?? Text("Choice"))
        }
        .padding(.vertical, 2)
    }

    private func binding(for question: PhotoImporter.ReimportQuestion) -> Binding<PhotoImporter.ReimportChoice> {
        Binding(
            get: { answers[question.id] ?? question.defaultChoice },
            set: { answers[question.id] = $0 }
        )
    }

    /// "Update" applies to all only where it is unambiguous: one stored photo to replace.
    private func canUpdate(_ question: PhotoImporter.ReimportQuestion) -> Bool {
        question.candidates.count == 1
    }

    /// Rows that don't offer Keep both get their default (Skip) instead, so an earlier
    /// "Set all to… Update" is not left on them.
    private func setAll(_ choice: PhotoImporter.ReimportChoice) {
        for question in questions {
            answers[question.id] = choice == .keepBoth && !question.offersKeepBoth ? question.defaultChoice : choice
        }
    }

    private func setAllToUpdate() {
        for question in questions where canUpdate(question) {
            if let candidate = question.candidates.first { answers[question.id] = .update(candidate) }
        }
    }

    /// The choice when several stored photos match: "Update: PANA0202.jpg", with the dive when
    /// the photo is on another one or has no file name ("Update: #146 · Site · PANA0202.jpg").
    /// Read from the question: nothing is fetched while drawing.
    private func updateLabel(_ candidate: PhotoImporter.Candidate) -> String {
        var parts: [String] = []
        if candidate.onOtherDive || candidate.filename == nil {
            parts.append(Self.diveText(number: candidate.diveNumber, site: candidate.siteName))
        }
        if let filename = candidate.filename { parts.append(filename) }
        return String(format: NSLocalizedString("Update: %@", bundle: .forAppLanguage(), value: "Update: %@", comment: "Choice for a re-imported file: replace this stored photo (dive number, site and file name)"), parts.joined(separator: " · "))
    }

    /// What Update does beyond replacing the file, written out under the reason (the choice
    /// itself stays one short word): it moves the photo from its dive to the import's dive, or
    /// gives it the import's clock correction. Nil when Update only replaces the file.
    private func updateEffect(_ question: PhotoImporter.ReimportQuestion) -> String? {
        var lines: [String] = []
        if question.candidateDetails.count == 1, let candidate = question.candidateDetails.first, candidate.onOtherDive {
            lines.append(String(format: NSLocalizedString("On dive %@. Update moves it to dive %@.", bundle: .forAppLanguage(), value: "On dive %@. Update moves it to dive %@.", comment: "Re-import question: the stored photo's dive, then the dive Update moves it to (each: dive number · site)"),
                          Self.diveText(number: candidate.diveNumber, site: candidate.siteName),
                          Self.diveText(number: question.diveNumber, site: question.diveSiteName)))
        }
        // Any question whose stored photo has another correction (not only the correction
        // reasons): Update would otherwise move its marker on the profile without saying so.
        if let correction = question.clockAdjustment,
           question.candidateDetails.contains(where: { abs($0.clockAdjustment - correction) >= PhotoReimportResolver.sameCorrectionTolerance }) {
            lines.append(NSLocalizedString("Update applies this import's clock correction.", bundle: .forAppLanguage(), value: "Update applies this import's clock correction.", comment: "Re-import question: choosing Update gives the stored photo the camera-clock correction entered for this import"))
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// "#146 · Site", or what of it is known.
    private static func diveText(number: Int?, site: String?) -> String {
        var parts: [String] = []
        if let number { parts.append("#\(Double(number).localizedString(decimals: 0))") }
        if let site, !site.isEmpty { parts.append(site) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    static func reasonText(_ reason: PhotoReimportResolver.Reason) -> String {
        switch reason {
        case .sameFileOnOtherDive:
            return NSLocalizedString("The same file is already on another dive.", bundle: .forAppLanguage(), value: "The same file is already on another dive.", comment: "Re-import question: why BlueDive asks")
        case .otherDive:
            return NSLocalizedString("A photo taken at the same time is on another dive.", bundle: .forAppLanguage(), value: "A photo taken at the same time is on another dive.", comment: "Re-import question: why BlueDive asks")
        case .differentFilename:
            return NSLocalizedString("A photo taken at the same time has another file name.", bundle: .forAppLanguage(), value: "A photo taken at the same time has another file name.", comment: "Re-import question: why BlueDive asks (e.g. a Lightroom virtual copy, or a buddy's camera)")
        case .noFilename:
            return NSLocalizedString("A photo was taken at the same time, and this file has no name to compare.", bundle: .forAppLanguage(), value: "A photo was taken at the same time, and this file has no name to compare.", comment: "Re-import question: why BlueDive asks (a photo picked in the Photos library)")
        case .severalMatches:
            return NSLocalizedString("Several photos were taken at the same time.", bundle: .forAppLanguage(), value: "Several photos were taken at the same time.", comment: "Re-import question: why BlueDive asks")
        case .notComparable:
            return NSLocalizedString("The stored copy has not been downloaded from iCloud yet, so it cannot be compared.", bundle: .forAppLanguage(), value: "The stored copy has not been downloaded from iCloud yet, so it cannot be compared.", comment: "Re-import question: why BlueDive asks")
        case .alreadyUsed:
            return NSLocalizedString("An earlier file in this import already matched this photo.", bundle: .forAppLanguage(), value: "An earlier file in this import already matched this photo.", comment: "Re-import question: why BlueDive asks")
        case .smallerWithoutDate:
            return NSLocalizedString("This file is smaller than the stored copy and has no edit date.", bundle: .forAppLanguage(), value: "This file is smaller than the stored copy and has no edit date.", comment: "Re-import question: why BlueDive asks (e.g. an export for the web)")
        case .sameFileOtherCorrection:
            return NSLocalizedString("This photo is already on this dive with another camera clock correction.", bundle: .forAppLanguage(), value: "This photo is already on this dive with another camera clock correction.", comment: "Re-import question: why BlueDive asks (same file, imported again with another camera-clock correction)")
        case .otherCorrection:
            return NSLocalizedString("A photo taken at the same time is on this dive with another camera clock correction.", bundle: .forAppLanguage(), value: "A photo taken at the same time is on this dive with another camera clock correction.", comment: "Re-import question: why BlueDive asks (a newer or the same version, imported again with another camera-clock correction)")
        case .sameDateDifferentSize:
            return NSLocalizedString("Same edit date as the stored copy, but a different size.", bundle: .forAppLanguage(), value: "Same edit date as the stored copy, but a different size.", comment: "Re-import question: why BlueDive asks")
        }
    }
}

/// The re-import decisions of a dive's photo import, as a sheet. Continue carries out the
/// choices; the close button leaves every file out (nothing is changed).
struct PhotoReimportSheet: View {
    let questions: [PhotoImporter.ReimportQuestion]
    let onFinish: ([(question: PhotoImporter.ReimportQuestion, choice: PhotoImporter.ReimportChoice)]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var answers: [UUID: PhotoImporter.ReimportChoice] = [:]

    var body: some View {
        NavigationStack {
            Form {
                PhotoReimportSection(questions: questions, answers: $answers)
            }
            .groupedFormStyleOnMac()
            .navigationTitle(Text("Photos Already in BlueDive"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton {
                        onFinish(questions.map { ($0, .skip) })
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onFinish(questions.map { ($0, answers[$0.id] ?? $0.defaultChoice) })
                        dismiss()
                    } label: {
                        Text("Continue")
                            .confirmationActionForeground(.pink)
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}
