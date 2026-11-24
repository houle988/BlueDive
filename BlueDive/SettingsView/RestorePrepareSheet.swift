import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

/// Prepares a restore from an unzipped backup folder (Settings → Data Management → Restore
/// backup): copies the backup once and makes its clean copy (`DatabaseRestore.prepareCandidate`,
/// which also checks it opens and migrates), shows what it holds, asks the user to confirm the
/// other devices and iCloud are ready, then makes it the pending restore (`commitCandidate`). The restore itself runs at the next launch, in restore mode
/// (`RestoreModeView`), while the database is closed.
struct RestorePrepareSheet: View {
    let folderURL: URL
    /// Called once the restore is staged.
    var onStaged: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    private enum Phase {
        case loading
        /// The backup is copied and migrated to the current model (its clean copy is made).
        case checking
        case notABackup
        /// The backup does not open or migrate (damaged, or a model this version cannot read).
        case unreadable
        /// Some of the backup's photos and files could not be copied (e.g. not downloaded).
        case missingFiles
        case newerVersion
        case notEnoughSpace(needed: Int64)
        case ready(RestoreSource, DatabaseRestore.Candidate)
        case staging
        case staged
        case failed
    }

    @State private var phase: Phase = .loading
    @State private var otherDevicesReady = false
    @State private var iCloudDataDeleted = false
    @State private var isAccessingFolder = false
    @State private var showOtherDevicesHelp = false
    /// The candidate was made the pending restore: it must not be discarded when the sheet closes.
    @State private var committed = false

    private var iCloudSyncEnabled: Bool { BlueDiveApp.isICloudSyncEnabled }

    var body: some View {
        NavigationStack {
            Form {
                content
            }
            .groupedFormStyleOnMac()
            .navigationTitle("Restore Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { dismiss() }
                        .disabled(isStaging)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if case .staged = phase {
                        Button("Done") { dismiss() }
                    } else {
                        Button("Prepare Restore") { stage() }
                            .disabled(!canStage)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isStaging)
        .sheet(isPresented: $showOtherDevicesHelp) {
            RestoreOtherDevicesHelpView()
                .standardSheetPresentation()
        }
        // Closing the sheet cancels this task, which stops the copy between files; the candidate
        // is then discarded (`load`), or here once it is complete but not committed.
        .task { await load() }
        .onDisappear {
            if !committed, case .ready(_, let candidate) = phase {
                Task.detached(priority: .utility) { DatabaseRestore.discardCandidate(candidate.id) }
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Reading the backup…")
                }
            }
        case .checking:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Checking the backup…")
                }
            }
        case .unreadable:
            problem(Text("The backup could not be read. Your logbook was not changed."))
        case .missingFiles:
            problem(Text("Some of the backup's photos and files could not be read. If the backup is in iCloud Drive, make sure it is fully downloaded (in Files or the Finder), then try again. Your logbook was not changed."))
        case .notABackup:
            problem(Text("This folder is not a BlueDive backup. Unzip the backup first, then choose the “BlueDive Backup” folder."))
        case .newerVersion:
            problem(Text("This backup was made with a newer version of BlueDive. Update BlueDive, then try again."))
        case .notEnoughSpace(let needed):
            problem(Text(verbatim: String(format: NSLocalizedString("Not enough free space to restore this backup. About %@ is needed.", bundle: .forAppLanguage(), value: "Not enough free space to restore this backup. About %@ is needed.", comment: "Restore backup error; %@ is a size such as 2.1 GB"), needed.localizedFileSize)))
        case .failed:
            problem(Text("The backup could not be copied. Your logbook was not changed."))
        case .ready(let source, let candidate):
            backupSection(source, counts: candidate.report.entityCounts)
            checklistSection
        case .staging:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Copying the backup…")
                }
            }
        case .staged:
            stagedSection
        }
    }

    private func problem(_ text: Text) -> some View {
        Section {
            Label {
                text
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func backupSection(_ source: RestoreSource, counts: [String: Int]?) -> some View {
        Section {
            RestoreBackupSummaryRows(createdAt: source.manifest?.createdAt, appVersion: source.manifest?.app.version,
                                     entityCounts: counts, totalBytes: source.totalBytes)
        } header: {
            Text("Backup")
        } footer: {
            if source.manifest == nil {
                Text("A backup made with an earlier version of BlueDive: its date and version are not recorded.")
            }
        }
    }

    private var checklistSection: some View {
        Section {
            Toggle("BlueDive and its data are deleted from my other devices.",
                   isOn: $otherDevicesReady)
                .fullWidthSwitch()
            Button("How to delete it on your other devices") { showOtherDevicesHelp = true }
                .listRowButton()
            if iCloudSyncEnabled {
                Toggle("I will delete BlueDive's data from iCloud before opening BlueDive again.",
                       isOn: $iCloudDataDeleted)
                    .fullWidthSwitch()
            }
        } header: {
            Text("Before You Start")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("A device that keeps its old logbook can send it back to iCloud and mix it with the restored one.")
                Text("The logbook on this device is replaced by the backup at the next launch. BlueDive keeps the replaced logbook on this device.")
                RestoreICloudFooterText(iCloudSyncEnabled: iCloudSyncEnabled)
            }
        }
    }

    @ViewBuilder
    private var stagedSection: some View {
        Section {
            Label {
                Text("The restore is ready.")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                #if os(macOS)
                Text("Quit BlueDive (BlueDive → Quit BlueDive).")
                #else
                Text("Close BlueDive: swipe it away in the app switcher.")
                #endif
                if iCloudSyncEnabled {
                    Text("Delete BlueDive's data from iCloud.")
                }
                Text("Open BlueDive again: it restores the backup.")
                Text("Changes made in BlueDive until then are not kept.")
            }
        }
        #if os(macOS)
        Section {
            Button("Quit BlueDive") {
                // A sheet still attached to the window keeps the app from quitting: close it,
                // then quit once it is gone.
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    NSApp.terminate(nil)
                }
            }
            .listRowButton()
        }
        #endif
    }

    // MARK: Actions

    private var isStaging: Bool {
        if case .staging = phase { return true }
        return false
    }

    private var canStage: Bool {
        guard case .ready = phase else { return false }
        return otherDevicesReady && (iCloudDataDeleted || !iCloudSyncEnabled)
    }

    private func load() async {
        guard case .loading = phase else { return }
        isAccessingFolder = folderURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessingFolder {
                folderURL.stopAccessingSecurityScopedResource()
                isAccessingFolder = false
            }
        }
        let folder = folderURL
        let modelTypes = BlueDiveApp.appModelTypes
        let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let located: (Phase, RestoreSource?) = await Task.detached(priority: .userInitiated) {
            guard let source = DatabaseRestore.locateBackup(in: folder) else { return (Phase.notABackup, nil) }
            if DatabaseRestore.isFromNewerBuild(source.manifest, currentBuild: currentBuild) { return (.newerVersion, nil) }
            let needed = DatabaseRestore.spaceNeeded(for: source)
            if let available = DatabaseRestore.availableSpace(), available < needed {
                return (.notEnoughSpace(needed: needed), nil)
            }
            return (.checking, source)
        }.value
        guard let source = located.1 else {
            phase = located.0
            return
        }
        // Closed while the backup was being located: nothing has been copied yet.
        guard !Task.isCancelled else { return }
        phase = .checking
        // The one copy and migration of the backup: a backup that does not open or migrate is
        // refused now, before the user deletes anything on the other devices or in iCloud. Its
        // record counts are the ones the restore puts back. The detached work is cancelled with
        // this task (the sheet closed) and stops between files.
        let work = Task.detached(priority: .userInitiated) {
            try DatabaseRestore.prepareCandidate(source, modelTypes: modelTypes)
        }
        let result = await withTaskCancellationHandler {
            await work.result
        } onCancel: {
            work.cancel()
        }
        switch result {
        case .success(let candidate):
            if Task.isCancelled {
                // Completed just as the sheet closed: not kept.
                await Task.detached(priority: .utility) { DatabaseRestore.discardCandidate(candidate.id) }.value
            } else {
                phase = .ready(source, candidate)
            }
        case .failure(DatabaseRestore.CandidateFailure.missingExternalFiles):
            phase = .missingFiles
        case .failure:
            // A failed or cancelled preparation leaves nothing behind (`prepareCandidate`).
            if !Task.isCancelled { phase = .unreadable }
        }
    }

    private func stage() {
        guard canStage, case .ready(let source, let candidate) = phase else { return }
        phase = .staging
        Task {
            let staged = await Task.detached(priority: .userInitiated) {
                (try? DatabaseRestore.commitCandidate(candidate, source: source)) != nil
            }.value
            committed = staged
            phase = staged ? .staged : .failed
            if staged { onStaged() }
        }
    }
}
