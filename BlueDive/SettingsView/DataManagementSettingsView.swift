import SwiftUI
import SwiftData
import WidgetKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct DataManagementSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var showingResetAlert = false
    @State private var showingEraseAllDataAlert = false
    @State private var isErasingData = false
    private enum ErasePhase {
        case erasing
        case done(errorCount: Int)
    }
    @State private var erasePhase: ErasePhase?
    @State private var backupError: String?
    #if os(iOS)
    @State private var showBackupExporter = false
    @State private var backupDocument: ExportableFileDocument?
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
                        }
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    Text("Export a compressed backup of your database.")
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
                        }
                        .foregroundStyle(.red)
                    }
                    .padding()
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
                                if isErasingData {
                                    ProgressView().scaleEffect(0.8)
                                }
                            }
                        }
                        .foregroundStyle(.red)
                        .disabled(isErasingData || erasePhase != nil)

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
                        }
                    }
                    .padding()
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
        .alert("Reset preferences?", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                withAnimation { UserPreferences.shared.resetToDefaults() }
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
            backupDocument = nil
        }
        #endif
    }

    // MARK: - Backup

    private func backupDatabase() {
        try? modelContext.save()

        guard let storeURL = modelContext.container.configurations.first?.url else {
            backupError = NSLocalizedString("Backup failed: could not locate the database.", bundle: .forAppLanguage(), comment: "")
            return
        }
        let storeDir = storeURL.deletingLastPathComponent()
        let storeBaseName = storeURL.lastPathComponent

        Task {
            let result: Result<(URL, String), BackupFailure> = await Task.detached(priority: .userInitiated) {
                Self.buildBackupZip(storeDir: storeDir, storeBaseName: storeBaseName)
            }.value

            switch result {
            case .failure(.directoryUnreadable):
                backupError = NSLocalizedString("Backup failed: could not read the database directory.", bundle: .forAppLanguage(), comment: "")
            case .failure(.noFilesFound):
                backupError = NSLocalizedString("Backup failed: no database files found.", bundle: .forAppLanguage(), comment: "")
            case .failure(.copyFailed):
                backupError = NSLocalizedString("Backup failed: could not copy database files.", bundle: .forAppLanguage(), comment: "")
            case .failure(.archiveFailed):
                backupError = NSLocalizedString("Backup failed: could not create the archive.", bundle: .forAppLanguage(), comment: "")
            case .success(let (finalZipURL, zipName)):
                #if os(macOS)
                let savePanel = NSSavePanel()
                savePanel.title = NSLocalizedString("Save Backup", bundle: .forAppLanguage(), comment: "")
                savePanel.nameFieldStringValue = zipName
                savePanel.allowedContentTypes = [.zip]
                savePanel.canCreateDirectories = true
                if savePanel.runModal() == .OK, let destination = savePanel.url {
                    let fm = FileManager.default
                    try? fm.removeItem(at: destination)
                    try? fm.copyItem(at: finalZipURL, to: destination)
                }
                try? FileManager.default.removeItem(at: finalZipURL)
                #else
                if let data = try? Data(contentsOf: finalZipURL) {
                    backupDocument = ExportableFileDocument(data: data)
                    backupFileName = zipName
                    showBackupExporter = true
                } else {
                    backupError = NSLocalizedString("Backup failed: could not prepare the archive.", bundle: .forAppLanguage(), comment: "")
                }
                try? FileManager.default.removeItem(at: finalZipURL)
                #endif
            }
        }
    }

    private enum BackupFailure: Error {
        case directoryUnreadable, noFilesFound, copyFailed, archiveFailed
    }

    private nonisolated static func buildBackupZip(storeDir: URL, storeBaseName: String) -> Result<(URL, String), BackupFailure> {
        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: storeDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        } catch {
            return .failure(.directoryUnreadable)
        }

        let sqliteSuffixes: Set<String> = ["", "-shm", "-wal", "-journal"]
        let filesToBackup = contents.filter { url in
            let name = url.lastPathComponent
            if name.hasPrefix("." + storeBaseName) { return true }
            guard name.hasPrefix(storeBaseName) else { return false }
            return sqliteSuffixes.contains(String(name.dropFirst(storeBaseName.count)))
        }

        guard !filesToBackup.isEmpty else { return .failure(.noFilesFound) }

        let tempDir = fm.temporaryDirectory.appendingPathComponent("BlueDiveBackup-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tempDir) }

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            for file in filesToBackup {
                try fm.copyItem(at: file, to: tempDir.appendingPathComponent(file.lastPathComponent))
            }
        } catch {
            return .failure(.copyFailed)
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let zipName = "BlueDive-Backup-\(dateFormatter.string(from: Date())).zip"
        let zipURL = fm.temporaryDirectory.appendingPathComponent(zipName)
        try? fm.removeItem(at: zipURL)

        var coordError: NSError?
        var createdZipURL: URL?
        NSFileCoordinator().coordinate(readingItemAt: tempDir, options: .forUploading, error: &coordError) { zippedURL in
            do {
                try fm.copyItem(at: zippedURL, to: zipURL)
                createdZipURL = zipURL
            } catch {}
        }

        guard coordError == nil, createdZipURL != nil else { return .failure(.archiveFailed) }
        return .success((zipURL, zipName))
    }

    // MARK: - Erase All Data

    private func eraseAllData() {
        guard !isErasingData, erasePhase == nil else { return }
        isErasingData = true
        erasePhase = .erasing

        Task {
            var errors: [String] = []

            await MainActor.run {
                do { try modelContext.delete(model: Dive.self) } catch {
                    do { try modelContext.fetch(FetchDescriptor<Dive>()).forEach { modelContext.delete($0) }
                    } catch let e { errors.append("Dive: \(e.localizedDescription)") }
                }
                do { try modelContext.delete(model: MarineSight.self) } catch {
                    do { try modelContext.fetch(FetchDescriptor<MarineSight>()).forEach { modelContext.delete($0) }
                    } catch let e { errors.append("MarineSight: \(e.localizedDescription)") }
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
            }

            NotificationManager.shared.cancelAllNotifications()
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
                isErasingData = false
                erasePhase = .done(errorCount: errors.count)
            }
        }
    }
}
