import SwiftUI

/// The rows describing a backup, shown in the preparation sheet (`RestorePrepareSheet`) and on
/// the restore screen (`RestoreModeView`): its date and BlueDive version (format 2 backups),
/// the dives and photos it holds, and, while preparing, its size.
struct RestoreBackupSummaryRows: View {
    /// The manifest's ISO 8601 date (`BackupManifest.createdAt`).
    let createdAt: String?
    let appVersion: String?
    let entityCounts: [String: Int]?
    var totalBytes: Int64? = nil

    @Environment(\.locale) private var locale

    var body: some View {
        if let date = createdAt.flatMap({ ISO8601DateFormatter().date(from: $0) }) {
            LabeledContent("Date") {
                Text(date, format: .dateTime.day().month().year().hour().minute().locale(locale))
            }
        }
        if let appVersion, !appVersion.isEmpty {
            LabeledContent("BlueDive version") {
                Text(verbatim: appVersion)
            }
        }
        if let dives = entityCounts?["Dive"] {
            LabeledContent("Dives") {
                Text(verbatim: Double(dives).localizedString(decimals: 0))
            }
        }
        if let photos = entityCounts?["DivePhoto"] {
            LabeledContent("Photos") {
                Text(verbatim: Double(photos).localizedString(decimals: 0))
            }
        }
        if let totalBytes {
            LabeledContent("Size") {
                Text(verbatim: totalBytes.localizedFileSize)
            }
        }
    }
}

/// How to delete BlueDive's data from iCloud before a restore, or, with iCloud sync off, why it
/// should be: shared by the preparation sheet and the restore screen.
struct RestoreICloudFooterText: View {
    let iCloudSyncEnabled: Bool

    var body: some View {
        if iCloudSyncEnabled {
            // Paths and button names as in Apple's "Manage your iCloud storage" (108922) and
            // "Manage iCloud storage on Mac" (macOS User Guide).
            Text("To delete BlueDive's data from iCloud: on iPhone or iPad, Settings → your name → iCloud → Storage (or Manage Account Storage) → BlueDive → Delete Data from iCloud; on a Mac, System Settings → your name → iCloud → Manage → BlueDive → Delete from iCloud → Remove from iCloud. BlueDive checks that iCloud is empty before restoring, then uploads the restored logbook.")
        } else {
            Text("iCloud sync is off in BlueDive. If BlueDive's data is still in iCloud, it will be merged with the restored logbook when you turn iCloud sync on: delete it from iCloud first.")
        }
    }
}
