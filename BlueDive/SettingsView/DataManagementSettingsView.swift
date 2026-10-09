import SwiftUI
import SwiftData
import WidgetKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct DataManagementSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(DiveStore.self) private var store
    @State private var showingResetAlert = false
    @State private var showingEraseAllDataAlert = false
    private enum ErasePhase {
        case erasing
        case done(errorCount: Int)
    }
    @State private var erasePhase: ErasePhase?
    @State private var backupError: String?
    /// The backup being built (copying and zipping the store can take a while with photos).
    /// While it runs the Backup button is disabled; cancelled when the screen closes.
    @State private var backupTask: Task<Void, Never>?
    @State private var backupProgress = BackupProgress()
    @State private var showConvertPhotosAlert = false
    @State private var photoConversionSummary: PhotoImporter.ConversionSummary?
    #if os(iOS)
    @State private var showBackupExporter = false
    @State private var backupDocument: BackupArchiveDocument?
    @State private var backupFileName: String = ""
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            backupDatabase()
                        } label: {
                            HStack {
                                Label("Backup database", systemImage: "externaldrive.fill.badge.timemachine")
                                Spacer()
                            }
                            // The padding sits inside the button so the whole card responds, not only the
                            // drawn label (a borderless Button only responds where something is drawn).
                            .padding()
                            .contentShape(Rectangle())
                        }
                        .borderlessButton()
                        .disabled(isDataOperationRunning)
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    if let phase = backupProgress.phase {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text(verbatim: backupPhaseText(phase))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    } else {
                        Text("Export a compressed backup of your database.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
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

                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            showConvertPhotosAlert = true
                        } label: {
                            HStack {
                                Label("Convert photos", systemImage: "photo.stack")
                                Spacer()
                                if let (done, total) = activity.photoConversionProgress {
                                    Text(verbatim: "\(Double(done).localizedString(decimals: 0)) / \(Double(total).localizedString(decimals: 0))")
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                    ProgressView().scaleEffect(0.8)
                                }
                            }
                            // The padding sits inside the button so the whole card responds, not only the
                            // drawn label (a borderless Button only responds where something is drawn).
                            .padding()
                            .contentShape(Rectangle())
                        }
                        .disabled(isDataOperationRunning)
                        .borderlessButton()
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    Text("Convert photos added with earlier versions of BlueDive: each photo gets its own record with a thumbnail and its capture time, and photos taken during a dive appear on its profile. The images are not changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
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

                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button(role: .destructive) {
                            showingResetAlert = true
                        } label: {
                            HStack {
                                Label("Reset preferences", systemImage: "arrow.counterclockwise")
                                Spacer()
                            }
                            // The padding sits inside the button so the whole card responds, not only the
                            // drawn label (a borderless Button only responds where something is drawn).
                            .padding()
                            .contentShape(Rectangle())
                        }
                        .foregroundStyle(.red)
                        .borderlessButton()
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    Text("Return all preferences to their default values.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
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

                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Button(role: .destructive) {
                            showingEraseAllDataAlert = true
                        } label: {
                            HStack {
                                Label("Erase all data", systemImage: "trash.fill")
                                Spacer()
                                if activity.isErasing {
                                    ProgressView().scaleEffect(0.8)
                                }
                            }
                            // The padding sits inside the button so the whole card responds. While the
                            // status text is shown, it carries the bottom padding instead.
                            .padding(erasePhase == nil ? .all : [.horizontal, .top])
                            .contentShape(Rectangle())
                        }
                        // An explicit colour is not dimmed by `.disabled`: it greys out itself, like
                        // the other buttons while a backup or a conversion runs.
                        .foregroundStyle(isEraseDisabled ? Color.secondary : Color.red)
                        .disabled(isEraseDisabled)
                        .borderlessButton()

                        if let erasePhase {
                            Group {
                                switch erasePhase {
                                case .erasing:
                                    Text("Erasing all data…")
                                case .done(let errorCount) where errorCount == 0:
                                    Text(verbatim: NSLocalizedString("All data erased. Wait for iCloud sync to finish uploading before closing the app. Monitor the cloud icon on the main screen.", bundle: Bundle.forAppLanguage(), comment: "Status message shown after all local and iCloud data has been erased."))
                                case .done(let errorCount):
                                    Text(verbatim: errorCount == 1
                                        ? NSLocalizedString("Completed with 1 error. Wait for iCloud sync to finish uploading before closing the app. Monitor the cloud icon on the main screen.", bundle: Bundle.forAppLanguage(), comment: "Status message when exactly one error occurs during erase.")
                                        : String(format: NSLocalizedString("Completed with %lld errors. Wait for iCloud sync to finish uploading before closing the app. Monitor the cloud icon on the main screen.", bundle: Bundle.forAppLanguage(), comment: "Status message when multiple errors occur during erase. %lld is the error count."), errorCount))
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding([.horizontal, .bottom])
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    Text("Permanently deletes all data from this device and iCloud. This action cannot be undone. Wait for iCloud sync to finish uploading before closing the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
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
            .padding(.vertical)
        }
        .settingsGradientBackground()
        .navigationTitle(Text(verbatim: NSLocalizedString("Data Management", bundle: .forAppLanguage(), value: "Data Management", comment: "")))
        .alert("Convert photos?", isPresented: $showConvertPhotosAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Convert") {
                convertAllLegacyPhotos()
            }
        } message: {
            Text("All dives are checked; this can take a while with many photos. Keep BlueDive open until it finishes.")
        }
        .alert("Photos Converted", isPresented: Binding(
            get: { photoConversionSummary != nil },
            set: { if !$0 { photoConversionSummary = nil } }
        ), presenting: photoConversionSummary) { _ in
            Button("OK", role: .cancel) { }
        } message: { summary in
            Text(verbatim: [
                String(format: NSLocalizedString("Photos converted: %@", bundle: .forAppLanguage(), value: "Photos converted: %@", comment: "Legacy photo conversion summary line: photos converted"), Double(summary.photos).localizedString(decimals: 0)),
                String(format: NSLocalizedString("Dives: %@", bundle: .forAppLanguage(), value: "Dives: %@", comment: "Legacy photo conversion summary line: dives whose photos were converted"), Double(summary.dives).localizedString(decimals: 0)),
                String(format: NSLocalizedString("Dives with photos left in the previous format (a photo could not be read or saved): %@", bundle: .forAppLanguage(), value: "Dives with photos left in the previous format (a photo could not be read or saved): %@", comment: "Legacy photo conversion summary line: dives that still have photos in the old format"), Double(summary.divesKept).localizedString(decimals: 0))
            ].joined(separator: "\n"))
        }
        .alert("Reset preferences?", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                withAnimation {
                    UserPreferences.shared.resetToDefaults()
                    // resetToDefaults() already clears the persisted sort order (via
                    // DiveSortOrder.resetPersisted()), but UserPreferences has no handle
                    // to the live DiveStore — this line updates the in-memory value (and
                    // re-persists it) so the toolbar icon and list order change immediately.
                    store.sortOrder = .dateDesc
                }
            }
        } message: {
            Text("All preferences will return to their default values.")
        }
        .alert("Erase all local and remote data?", isPresented: $showingEraseAllDataAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Erase All Data", role: .destructive) {
                eraseAllData()
            }
        } message: {
            Text("This will permanently delete all your data from this device and iCloud. This action cannot be undone. Wait for the iCloud sync to finish uploading before closing the app.")
        }
        .alert(
            "Backup Failed",
            isPresented: Binding(get: { backupError != nil }, set: { if !$0 { backupError = nil } })
        ) {
            Button("OK", role: .cancel) { backupError = nil }
        } message: {
            Text(backupError ?? "")
        }
        #if os(iOS)
        .fileExporter(
            isPresented: $showBackupExporter,
            document: backupDocument,
            contentType: .zip,
            defaultFilename: backupFileName
        ) { _ in
            removeBackupArchive()
        }
        // Cancelling the exporter may not call its completion: the temporary zip (it can be
        // several GB) is deleted whenever the exporter closes.
        .onChange(of: showBackupExporter) { _, isShown in
            if !isShown { removeBackupArchive() }
        }
        #endif
        // A backup still being built when the screen closes is not presented: its zip is
        // deleted once it is done (`backupDatabase`).
        .onDisappear { backupTask?.cancel() }
    }

    // MARK: - Backup

    #if os(iOS)
    private func removeBackupArchive() {
        if let url = backupDocument?.url { Self.removeBackupArchive(at: url) }
        backupDocument = nil
    }
    #endif

    /// Deletes a backup zip with the folder of its own it was built in (`DatabaseBackup.build`).
    private nonisolated static func removeBackupArchive(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// The operations running on this screen, kept outside the view (`DataOperationActivity`).
    private var activity: DataOperationActivity { .shared }

    /// A backup, a photo conversion or an erase is running. They exclude each other: an erase or
    /// a conversion removes files a backup is still copying, and a backup of a log being erased
    /// or converted would be incomplete.
    private var isDataOperationRunning: Bool {
        activity.isBackingUp || activity.photoConversionProgress != nil || activity.isErasing
    }

    private var isEraseDisabled: Bool { isDataOperationRunning || erasePhase != nil }

    private func backupDatabase() {
        guard !isDataOperationRunning else { return }
        try? modelContext.save()

        guard let storeURL = modelContext.container.configurations.first?.url else {
            backupError = NSLocalizedString("Backup failed: could not locate the database.", bundle: .forAppLanguage(), comment: "")
            return
        }
        let modelTypes = BlueDiveApp.appModelTypes
        let iCloudOn = UserDefaults.standard.bool(forKey: BlueDiveApp.iCloudSyncEnabledKey)
        let progress = backupProgress
        progress.phase = .preparing
        let activity = activity
        activity.isBackingUp = true

        backupTask = Task {
            defer {
                backupTask = nil
                progress.phase = nil
                activity.isBackingUp = false
            }
            // The copy runs detached; cancelling this task (the screen closing) cancels it too.
            let build = Task.detached(priority: .userInitiated) {
                DatabaseBackup.build(liveStoreURL: storeURL, modelTypes: modelTypes, iCloudSyncEnabled: iCloudOn) { phase in
                    Task { @MainActor in progress.update(phase) }
                }
            }
            let result = await withTaskCancellationHandler {
                await build.value
            } onCancel: {
                build.cancel()
            }
            if Task.isCancelled {
                if case .success(let backup) = result { Self.removeBackupArchive(at: backup.url) }
                return
            }

            switch result {
            case .failure(.snapshotFailed):
                backupError = NSLocalizedString("Backup failed: could not take a snapshot of the database.", bundle: .forAppLanguage(), value: "Backup failed: could not take a snapshot of the database.", comment: "Database backup error")
            case .failure(.insufficientSpace(let needed)):
                let size = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
                backupError = String(format: NSLocalizedString("Backup failed: not enough free space. About %@ is needed.", bundle: .forAppLanguage(), value: "Backup failed: not enough free space. About %@ is needed.", comment: "Database backup error; %@ is a size such as 2.1 GB"), size)
            case .failure(.copyFailed):
                backupError = NSLocalizedString("Backup failed: could not copy database files.", bundle: .forAppLanguage(), comment: "")
            case .failure(.manifestFailed):
                backupError = NSLocalizedString("Backup failed: could not write the backup description.", bundle: .forAppLanguage(), value: "Backup failed: could not write the backup description.", comment: "Database backup error")
            case .failure(.archiveFailed):
                backupError = NSLocalizedString("Backup failed: could not create the archive.", bundle: .forAppLanguage(), comment: "")
            case .failure(.cancelled):
                break
            case .success(let backup):
                #if os(macOS)
                // No caption while the save panel is open; "Saving" while the archive is moved
                // (instant on the same volume) or copied (a full copy to another drive).
                progress.phase = nil
                let savePanel = NSSavePanel()
                savePanel.title = NSLocalizedString("Save Backup", bundle: .forAppLanguage(), comment: "")
                savePanel.nameFieldStringValue = backup.name
                savePanel.allowedContentTypes = [.zip]
                savePanel.canCreateDirectories = true
                if savePanel.runModal() == .OK, let destination = savePanel.url {
                    progress.phase = .saving
                    // Moved, else copied, off the main thread.
                    let saved = await Task.detached(priority: .userInitiated) {
                        let fm = FileManager.default
                        try? fm.removeItem(at: destination)
                        return (try? fm.moveItem(at: backup.url, to: destination)) != nil
                            || (try? fm.copyItem(at: backup.url, to: destination)) != nil
                    }.value
                    if !saved {
                        backupError = NSLocalizedString("Backup failed: could not save the backup file.", bundle: .forAppLanguage(), value: "Backup failed: could not save the backup file.", comment: "Database backup error: the archive could not be written where the user chose")
                    }
                }
                Self.removeBackupArchive(at: backup.url)
                #else
                // The archive is handed over by its file (it holds every photo original and can
                // be several GB); it is deleted once the exporter has finished.
                backupDocument = BackupArchiveDocument(url: backup.url)
                backupFileName = backup.name
                showBackupExporter = true
                #endif
            }
        }
    }

    /// The caption shown under the Backup button while a backup is being built.
    private func backupPhaseText(_ phase: DatabaseBackup.Phase) -> String {
        switch phase {
        case .preparing:
            return NSLocalizedString("Preparing backup…", bundle: .forAppLanguage(), value: "Preparing backup…", comment: "Database backup progress")
        case .copyingFiles(let done, let total):
            return String(format: NSLocalizedString("Copying photos… %@ / %@", bundle: .forAppLanguage(), value: "Copying photos… %@ / %@", comment: "Database backup progress: files copied / total"),
                          Double(done).localizedString(decimals: 0), Double(total).localizedString(decimals: 0))
        case .compressing:
            return NSLocalizedString("Compressing backup…", bundle: .forAppLanguage(), value: "Compressing backup…", comment: "Database backup progress")
        case .saving:
            return NSLocalizedString("Saving backup…", bundle: .forAppLanguage(), value: "Saving backup…", comment: "Database backup progress (macOS): the archive is written where the user chose")
        }
    }

    // MARK: - Convert Legacy Photos

    private func convertAllLegacyPhotos() {
        guard !isDataOperationRunning else { return }
        let activity = activity
        activity.photoConversionProgress = (0, 0)
        Task {
            let summary = await PhotoImporter.convertAllLegacyPhotos(container: modelContext.container) { done, total in
                activity.photoConversionProgress = (done, total)
            }
            activity.photoConversionProgress = nil
            // No list refresh: a dive's photos only change format, so its photo badge is the same.
            photoConversionSummary = summary
        }
    }

    // MARK: - Erase All Data

    /// Whether no record of a model with external storage is left (after the erase).
    private static func hasNoExternalStorageRecords(in context: ModelContext) -> Bool {
        ((try? context.fetchCount(FetchDescriptor<Dive>())) ?? 1) == 0
            && ((try? context.fetchCount(FetchDescriptor<DivePhotoOriginal>())) ?? 1) == 0
            && ((try? context.fetchCount(FetchDescriptor<DivePhotoThumbnail>())) ?? 1) == 0
            && ((try? context.fetchCount(FetchDescriptor<SpeciesImage>())) ?? 1) == 0
    }

    /// Deletes the external-storage files left by the erase. Only files last modified before the
    /// erase began are removed: a file written meanwhile (a record arriving from iCloud during
    /// the erase) is kept.
    private nonisolated static func removeExternalFiles(in folder: URL, olderThan date: Date) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return }
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified < date else { continue }
            try? fm.removeItem(at: file)
        }
    }

    private func eraseAllData() {
        guard !isDataOperationRunning, erasePhase == nil else { return }
        let activity = activity
        activity.isErasing = true
        erasePhase = .erasing

        let eraseStarted = Date()
        Task {
            var errors: [String] = []
            var externalDataFolder: URL?

            await MainActor.run {
                do { try modelContext.delete(model: Dive.self) } catch {
                    do { try modelContext.fetch(FetchDescriptor<Dive>()).forEach { modelContext.delete($0) }
                    } catch let e { errors.append("Dive: \(e.localizedDescription)") }
                }
                do { try modelContext.delete(model: MarineSight.self) } catch {
                    do { try modelContext.fetch(FetchDescriptor<MarineSight>()).forEach { modelContext.delete($0) }
                    } catch let e { errors.append("MarineSight: \(e.localizedDescription)") }
                }
                do { try modelContext.delete(model: DivePhoto.self) } catch {
                    do { try modelContext.fetch(FetchDescriptor<DivePhoto>()).forEach { modelContext.delete($0) }
                    } catch let e { errors.append("DivePhoto: \(e.localizedDescription)") }
                }
                do { try modelContext.delete(model: Species.self) } catch {
                    do { try modelContext.fetch(FetchDescriptor<Species>()).forEach { modelContext.delete($0) }
                    } catch let e { errors.append("Species: \(e.localizedDescription)") }
                }
                // A batch delete skips delete rules: the image records are deleted explicitly.
                do { try modelContext.delete(model: DivePhotoThumbnail.self) } catch {
                    do { try modelContext.fetch(FetchDescriptor<DivePhotoThumbnail>()).forEach { modelContext.delete($0) }
                    } catch let e { errors.append("DivePhotoThumbnail: \(e.localizedDescription)") }
                }
                do { try modelContext.delete(model: DivePhotoOriginal.self) } catch {
                    do { try modelContext.fetch(FetchDescriptor<DivePhotoOriginal>()).forEach { modelContext.delete($0) }
                    } catch let e { errors.append("DivePhotoOriginal: \(e.localizedDescription)") }
                }
                do { try modelContext.delete(model: SpeciesImage.self) } catch {
                    do { try modelContext.fetch(FetchDescriptor<SpeciesImage>()).forEach { modelContext.delete($0) }
                    } catch let e { errors.append("SpeciesImage: \(e.localizedDescription)") }
                }
                do { try modelContext.delete(model: Gear.self) } catch {
                    do { try modelContext.fetch(FetchDescriptor<Gear>()).forEach { modelContext.delete($0) }
                    } catch let e { errors.append("Gear: \(e.localizedDescription)") }
                }
                do { try modelContext.delete(model: Certification.self) } catch {
                    do { try modelContext.fetch(FetchDescriptor<Certification>()).forEach { modelContext.delete($0) }
                    } catch let e { errors.append("Certification: \(e.localizedDescription)") }
                }
                do { try modelContext.delete(model: DivingInsurance.self) } catch {
                    do { try modelContext.fetch(FetchDescriptor<DivingInsurance>()).forEach { modelContext.delete($0) }
                    } catch let e { errors.append("DivingInsurance: \(e.localizedDescription)") }
                }
                do { try modelContext.delete(model: TankTemplate.self) } catch {
                    do { try modelContext.fetch(FetchDescriptor<TankTemplate>()).forEach { modelContext.delete($0) }
                    } catch let e { errors.append("TankTemplate: \(e.localizedDescription)") }
                }
                do { try modelContext.delete(model: GearGroup.self) } catch {
                    do { try modelContext.fetch(FetchDescriptor<GearGroup>()).forEach { modelContext.delete($0) }
                    } catch let e { errors.append("GearGroup: \(e.localizedDescription)") }
                }
                do { try modelContext.delete(model: DeviceFingerprint.self) } catch {
                    do { try modelContext.fetch(FetchDescriptor<DeviceFingerprint>()).forEach { modelContext.delete($0) }
                    } catch let e { errors.append("DeviceFingerprint: \(e.localizedDescription)") }
                }
                do {
                    try modelContext.save()
                } catch {
                    errors.append("Save: \(error.localizedDescription)")
                }
                // A batch delete removes rows without their external-storage files (photo
                // originals, large images, legacy photo arrays). Once nothing that stores such
                // files is left, the files are unreferenced and are removed below.
                if errors.isEmpty, Self.hasNoExternalStorageRecords(in: modelContext),
                   let storeURL = modelContext.container.configurations.first?.url {
                    externalDataFolder = storeURL.deletingLastPathComponent()
                        .appendingPathComponent("." + storeURL.deletingPathExtension().lastPathComponent + "_SUPPORT")
                        .appendingPathComponent("_EXTERNAL_DATA")
                }
            }
            if let externalDataFolder {
                await Task.detached(priority: .utility) {
                    Self.removeExternalFiles(in: externalDataFolder, olderThan: eraseStarted)
                }.value
            }

            NotificationManager.shared.cancelAllNotifications()
            NotificationManager.shared.clearAllCatchUpMarkers()
            await NotificationManager.shared.clearBadge()
            UserDefaults.standard.removeObject(forKey: DiverFilter.storageKey)
            UserDefaults.standard.removeObject(forKey: "lastMilestoneNotified")

            let shared = UserDefaults(suiteName: "group.app.bluedive.universal")
            shared?.set(0, forKey: "totalDiveCount")
            shared?.set(0, forKey: "totalMinutesUnderwater")
            shared?.set(0.0, forKey: "maxDepthMeters")
            shared?.set(0, forKey: "longestDiveMinutes")
            shared?.removeObject(forKey: "mostRecentDiveDate")
            shared?.removeObject(forKey: "diverNames")
            shared?.removeObject(forKey: "diveCountByDiver")
            shared?.removeObject(forKey: "totalMinutesByDiver")
            shared?.removeObject(forKey: "maxDepthMetersByDiver")
            shared?.removeObject(forKey: "longestDiveMinutesByDiver")
            shared?.removeObject(forKey: "mostRecentDiveDateByDiver")
            WidgetCenter.shared.reloadTimelines(ofKind: "DiveCountWidget")
            WidgetCenter.shared.reloadTimelines(ofKind: "DiverStatsWidget")

            await MainActor.run {
                activity.isErasing = false
                erasePhase = .done(errorCount: errors.count)
            }
        }
    }
}

#if os(iOS)
/// The backup zip, written by the exporter straight from its temporary file instead of
/// being read into memory first.
private struct BackupArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }

    let url: URL

    init(url: URL) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Without `.immediate`, the contents are read only as they are written out.
        try FileWrapper(url: url, options: [])
    }
}
#endif

/// The phase of the backup being built, updated from the background copy.
@MainActor @Observable
private final class BackupProgress {
    var phase: DatabaseBackup.Phase?

    /// Applies an update from the copy. Updates hop to the main actor in separate tasks, so they
    /// can arrive out of order: the phase never goes back (preparing → copying → compressing),
    /// an older file count never replaces a newer one, and nothing arrives after the backup has
    /// ended or reached the save panel (`phase` nil).
    func update(_ new: DatabaseBackup.Phase) {
        guard let current = phase else { return }
        if new == .preparing, current != .preparing { return }
        if case .copyingFiles(let done, _) = new, case .copyingFiles(let shown, _) = current, done < shown { return }
        if case .copyingFiles = new, case .compressing = current { return }
        phase = new
    }
}

/// The backup, photo conversion and erase in progress, shared by every instance of the Data
/// Management screen: a conversion and an erase keep running when the screen is closed (only a
/// backup is cancelled), so a reopened screen must still see them and keep the other actions off.
@MainActor @Observable
private final class DataOperationActivity {
    static let shared = DataOperationActivity()

    var isBackingUp = false
    /// (dives processed, total) while converting legacy photos.
    var photoConversionProgress: (Int, Int)?
    var isErasing = false
}
