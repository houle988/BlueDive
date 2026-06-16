import SwiftUI

// MARK: - Duplicate Import Models

struct DuplicateImportMatch: Identifiable {
    let id = UUID()
    let parsedIndex: Int
    let incomingDate: Date?
    let incomingSiteName: String
    let incomingMaxDepth: Double
    let incomingDuration: Int        // minutes
    let incomingDistanceUnit: String // "meters" or "feet"
    let existing: Dive
    let reason: DuplicateMatchReason
}

enum DuplicateMatchReason: Sendable {
    case sameIdentifier
    case sameDateAndProfile

    var label: String {
        let bundle = Bundle.forAppLanguage()
        switch self {
        case .sameIdentifier:
            return NSLocalizedString("Same dive computer ID", bundle: bundle, comment: "Duplicate match reason: same dive computer identifier")
        case .sameDateAndProfile:
            return NSLocalizedString("Same date, depth and duration", bundle: bundle, comment: "Duplicate match reason: heuristic match on date, depth and duration")
        }
    }

    var icon: String {
        switch self {
        case .sameIdentifier:     return "barcode.viewfinder"
        case .sameDateAndProfile: return "calendar.badge.clock"
        }
    }
}

// MARK: - Duplicate Import Sheet

struct DuplicateImportSheet: View {

    let totalCount: Int
    let duplicates: [DuplicateImportMatch]
    let fileName: String

    var onSkipDuplicates: () -> Void
    var onImportAll: () -> Void
    var onCancel: () -> Void

    @Environment(\.locale) private var locale
    @State private var showAllDuplicates = false

    private let collapsedRowLimit = 5

    private var uniqueCount: Int { totalCount - duplicates.count }

    private var visibleDuplicates: [DuplicateImportMatch] {
        if showAllDuplicates || duplicates.count <= collapsedRowLimit {
            return duplicates
        }
        return Array(duplicates.prefix(collapsedRowLimit))
    }

    private var hiddenDuplicateCount: Int {
        max(0, duplicates.count - collapsedRowLimit)
    }

    var body: some View {
        ZStack {
            Color.platformBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    headerCard
                    summaryCard
                    duplicatesList
                    actionButtons
                }
                .padding(.horizontal)
                .padding(.vertical, 24)
            }
        }
        #if os(macOS)
        .frame(
            minWidth: 540, idealWidth: 620, maxWidth: 800,
            minHeight: 520, idealHeight: 640, maxHeight: 900
        )
        #endif
    }

    // MARK: - Header

    private var headerCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.18))
                    .frame(width: 48, height: 48)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: NSLocalizedString("Duplicates Detected", bundle: .forAppLanguage(), comment: "Header title for the duplicate import sheet"))
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                Text(verbatim: NSLocalizedString("Some dives in this file are already in your logbook.", bundle: .forAppLanguage(), comment: "Subtitle explaining that duplicate dives were found in the imported file"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(0.05)))
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                summaryStat(
                    icon: "doc.fill",
                    color: .cyan,
                    value: "\(totalCount)",
                    label: NSLocalizedString("In file", bundle: .forAppLanguage(), comment: "Stat tile: total dives in the imported file")
                )
                summaryStat(
                    icon: "exclamationmark.triangle.fill",
                    color: .orange,
                    value: "\(duplicates.count)",
                    label: NSLocalizedString("Duplicates", bundle: .forAppLanguage(), comment: "Stat tile: number of duplicate dives detected")
                )
                summaryStat(
                    icon: "sparkles",
                    color: .green,
                    value: "\(uniqueCount)",
                    label: NSLocalizedString("New", bundle: .forAppLanguage(), comment: "Stat tile: number of new dives that are not duplicates")
                )
            }
            if !fileName.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        )
    }

    private func summaryStat(icon: String, color: Color, value: String, label: String) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                Text(verbatim: value)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
            }
            Text(verbatim: label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.10))
        )
    }

    // MARK: - Duplicates List

    private var duplicatesList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                Text(verbatim: NSLocalizedString("Already in your logbook", bundle: .forAppLanguage(), comment: "Section header for the list of duplicate dives"))
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Spacer()
                Text(verbatim: "\(duplicates.count)")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.18)))
            }
            .padding(.horizontal, 4)

            LazyVStack(spacing: 8) {
                ForEach(visibleDuplicates) { match in
                    duplicateRow(match: match)
                }
            }

            if duplicates.count > collapsedRowLimit {
                expandCollapseButton
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        )
    }

    @ViewBuilder
    private var expandCollapseButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                showAllDuplicates.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showAllDuplicates ? "chevron.up" : "chevron.down")
                    .font(.caption.bold())
                if showAllDuplicates {
                    Text(verbatim: NSLocalizedString("Show Less", bundle: .forAppLanguage(), comment: "Button to collapse the expanded duplicate list"))
                } else {
                    Text(verbatim: String(
                        format: NSLocalizedString(
                            "See All (%lld more)",
                            bundle: .forAppLanguage(),
                            comment: "Button to expand the duplicate list, with the count of additional hidden duplicates."
                        ),
                        hiddenDuplicateCount
                    ))
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.orange.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.3), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private func duplicateRow(match: DuplicateImportMatch) -> some View {
        let existing = match.existing
        let depthUnit = match.incomingDistanceUnit == "feet" ? "ft" : "m"
        let depthString = String(format: "%.1f %@", match.incomingMaxDepth, depthUnit)
        let durationString: String = {
            let fmt = NSLocalizedString("%lld min", bundle: .forAppLanguage(), comment: "Duration in minutes")
            return String(format: fmt, match.incomingDuration)
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: match.reason.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.incomingSiteName.isEmpty
                         ? existing.siteName
                         : match.incomingSiteName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(match.incomingDate ?? existing.timestamp,
                             format: .dateTime.day().month().year().hour().minute().locale(locale))
                        Text(verbatim: "•")
                        Text(verbatim: depthString)
                        Text(verbatim: "•")
                        Text(verbatim: durationString)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer()
                if let diveNumber = existing.diveNumber {
                    Text(verbatim: "#\(diveNumber)")
                        .font(.system(.caption, design: .monospaced).bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.cyan.opacity(0.18))
                        .foregroundStyle(.cyan)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(verbatim: match.reason.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 30)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.25), lineWidth: 1))
        )
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button(action: onSkipDuplicates) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                    Text(verbatim: uniqueCount > 0
                         ? NSLocalizedString("Skip Duplicates and Import the Rest", bundle: .forAppLanguage(), comment: "Button: skip duplicate dives and import only new ones")
                         : NSLocalizedString("Skip — Nothing New to Import", bundle: .forAppLanguage(), comment: "Button: skip when all dives in the file are duplicates"))
                        .fontWeight(.bold)
                }
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.green))
            }
            .buttonStyle(.plain)
            .disabled(uniqueCount == 0)
            .opacity(uniqueCount == 0 ? 0.55 : 1)

            Button(action: onImportAll) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.on.square.fill")
                    Text(verbatim: NSLocalizedString("Import All Anyway", bundle: .forAppLanguage(), comment: "Button: import all dives including duplicates")).fontWeight(.bold)
                }
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange))
            }
            .buttonStyle(.plain)

            Button(action: onCancel) {
                Text(verbatim: NSLocalizedString("Cancel", bundle: .forAppLanguage(), comment: "Button to cancel the duplicate import review"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.primary.opacity(0.07))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }
}
