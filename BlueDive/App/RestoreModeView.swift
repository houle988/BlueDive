import SwiftUI
import SwiftData
import CloudKit
import os
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Restore Mode

/// Restore mode: the launch after a restore was prepared in Settings → Data Management. The app
/// shows only `RestoreModeView` and never opens the database (`BlueDiveApp` creates its model
/// container only for the normal interface), so the backup can replace it. Every window shares
/// this one object, so a second macOS window shows the same restore.
@MainActor @Observable
final class RestoreMode {
    static let shared = RestoreMode()
    private static let logger = Logger(subsystem: "com.bluedive.app", category: "Restore")

    enum Step: Equatable {
        case preparing, checkingICloud, replacing
    }

    enum Problem: Equatable {
        case cleanCopyFailed, iCloudNotEmpty, iCloudUnavailable, noICloudAccount, replaceFailed, cancelFailed
    }

    enum Status: Equatable {
        case ready
        case working(Step)
        case failed(Problem)
        case done
    }

    /// True while a restore is pending: the window shows the restore screen.
    private(set) var isActive: Bool
    private(set) var status: Status = .ready
    let pending: PendingRestore?

    private init() {
        pending = DatabaseRestore.readPending()
        isActive = pending != nil
    }

    var isWorking: Bool {
        if case .working = status { return true }
        return false
    }

    /// iCloud sync as the model container will open it (`BlueDiveApp.isICloudSyncEnabled`).
    var iCloudSyncEnabled: Bool { BlueDiveApp.isICloudSyncEnabled }

    /// Checks the clean copy made while preparing, checks that iCloud holds no BlueDive data (when iCloud sync is on),
    /// then replaces the database. Nothing is replaced before both checks pass.
    func start() async {
        guard !isWorking else { return }
        let modelTypes = BlueDiveApp.appModelTypes
        let liveStoreURL = BlueDiveApp.liveStoreURL
        let checksICloud = iCloudSyncEnabled
        let containerID = CloudKitSyncMonitor.cloudKitContainerID
        #if os(iOS)
        // The restore holds the database files: keep the screen awake and ask for time to finish
        // the current step if the app is sent to the background. When that time runs out the task
        // is ended, so iOS suspends the app (the step resumes when it returns) instead of
        // terminating it; a restore stopped anyway resumes safely at the next launch.
        UIApplication.shared.isIdleTimerDisabled = true
        final class TaskBox: @unchecked Sendable { var id = UIBackgroundTaskIdentifier.invalid }
        let box = TaskBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "Restore backup") {
            UIApplication.shared.endBackgroundTask(box.id)
            box.id = .invalid
        }
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            if box.id != .invalid { UIApplication.shared.endBackgroundTask(box.id) }
        }
        #endif

        status = .working(.preparing)
        let cleaned = await Task.detached(priority: .userInitiated) {
            (try? DatabaseRestore.ensureCleanCopy(modelTypes: modelTypes)) != nil
        }.value
        guard cleaned else {
            status = .failed(.cleanCopyFailed)
            return
        }

        if checksICloud {
            status = .working(.checkingICloud)
            do {
                if try await DatabaseRestore.iCloudHasData(containerIdentifier: containerID) {
                    status = .failed(.iCloudNotEmpty)
                    return
                }
            } catch let error as CKError where error.code == .notAuthenticated {
                status = .failed(.noICloudAccount)
                return
            } catch {
                Self.logger.error("Restore: iCloud check failed: \(error.localizedDescription, privacy: .public)")
                status = .failed(.iCloudUnavailable)
                return
            }
        }

        #if os(iOS)
        // The swap moves the database files: it starts only while the app is in front, never in
        // the little background time left after the user switched away.
        while UIApplication.shared.applicationState == .background {
            try? await Task.sleep(for: .milliseconds(500))
        }
        #endif
        status = .working(.replacing)
        let replaced = await Task.detached(priority: .userInitiated) {
            (try? DatabaseRestore.swap(liveStoreURL: liveStoreURL, modelTypes: modelTypes)) != nil
        }.value
        guard replaced else {
            status = .failed(.replaceFailed)
            return
        }
        // The swap is done but the marker stayed: Try Again runs the swap again (safe), so the
        // next launch is never in restore mode without its clean copy.
        let finished = await Task.detached(priority: .userInitiated) {
            (try? DatabaseRestore.finish()) != nil
        }.value
        guard finished else {
            status = .failed(.replaceFailed)
            return
        }
        status = .done
    }

    /// Cancels the restore and opens the app with the logbook it had.
    func cancel() async {
        guard !isWorking else { return }
        let liveStoreURL = BlueDiveApp.liveStoreURL
        let cancelled = await Task.detached(priority: .userInitiated) {
            (try? DatabaseRestore.cancel(liveStoreURL: liveStoreURL)) != nil
        }.value
        guard cancelled else {
            status = .failed(.cancelFailed)
            return
        }
        isActive = false
    }

    /// Leaves restore mode once the restore is done: the normal interface opens the database.
    func continueToApp() {
        guard status == .done else { return }
        isActive = false
    }
}

// MARK: - Restore Mode View

/// The only screen of restore mode (see `RestoreMode`).
struct RestoreModeView: View {
    @State private var mode = RestoreMode.shared
    @State private var showCancelConfirmation = false
    @State private var showOtherDevicesHelp = false
    /// macOS: the height of the form's content, so the card fits it (`restoreCardOnMac`).
    @State private var formContentHeight: CGFloat?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text("BlueDive is ready to restore a backup. The logbook on this device will be replaced by the backup.")
                    } icon: {
                        Image(systemName: "externaldrive.badge.timemachine")
                            .foregroundStyle(.cyan)
                    }
                }

                backupSection

                if mode.status != .done {
                    checklistSection
                }

                statusSection

                actionsSection
            }
            .groupedFormStyleOnMac()
            .measuresContentHeightOnMac($formContentHeight)
            .navigationTitle("Restore Backup")
            .navigationBarTitleDisplayMode(.inline)
        }
        .restoreCardOnMac(contentHeight: formContentHeight)
        .sheet(isPresented: $showOtherDevicesHelp) {
            RestoreOtherDevicesHelpView()
                .standardSheetPresentation()
        }
        .alert("Cancel the restore?", isPresented: $showCancelConfirmation) {
            Button("Keep Restore", role: .cancel) { }
            Button("Cancel Restore", role: .destructive) {
                Task { await mode.cancel() }
            }
        } message: {
            Text("BlueDive opens with the logbook this device had. The prepared backup is deleted.")
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var backupSection: some View {
        if let pending = mode.pending {
            Section("Backup") {
                RestoreBackupSummaryRows(createdAt: pending.backupCreatedAt, appVersion: pending.backupAppVersion,
                                         entityCounts: pending.entityCounts)
            }
        }
    }

    private var checklistSection: some View {
        Section {
            Label("BlueDive and its data are deleted from your other devices.",
                  systemImage: "iphone.slash")
            Button {
                showOtherDevicesHelp = true
            } label: {
                Text("How to delete it on your other devices")
                    .accentLabelOnMac()
            }
            .listRowButton()
            .disabled(mode.isWorking)
            if mode.iCloudSyncEnabled {
                Label("BlueDive's data is deleted from iCloud.", systemImage: "icloud.slash")
            }
        } header: {
            Text("Before You Start")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("A device that keeps its old logbook can send it back to iCloud and mix it with the restored one.")
                RestoreICloudFooterText(iCloudSyncEnabled: mode.iCloudSyncEnabled)
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch mode.status {
        case .ready:
            EmptyView()
        case .working(let step):
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    switch step {
                    case .preparing: Text("Preparing the backup…")
                    case .checkingICloud: Text("Checking iCloud…")
                    case .replacing: Text("Replacing the logbook…")
                    }
                }
            } footer: {
                Text("Keep BlueDive open until the restore is complete.")
            }
        case .failed(let problem):
            Section {
                Label {
                    switch problem {
                    case .cleanCopyFailed:
                        Text("The backup could not be read. Your logbook was not changed.")
                    case .iCloudNotEmpty:
                        Text("BlueDive's data is still in iCloud. Delete it (see above), wait a moment, then try again. Your logbook was not changed.")
                    case .iCloudUnavailable:
                        Text("iCloud could not be reached. Check that you are signed in to iCloud and connected to the internet, then try again. Your logbook was not changed.")
                    case .noICloudAccount:
                        Text("iCloud sync is on in BlueDive, but no iCloud account is signed in on this device. Sign in to iCloud and try again, or cancel the restore, turn iCloud sync off in BlueDive's Settings → iCloud, and prepare the restore again. Your logbook was not changed.")
                    case .replaceFailed:
                        Text("The logbook could not be replaced. Try again, or cancel the restore to put back the logbook this device had.")
                    case .cancelFailed:
                        Text("The restore could not be cancelled. Try again.")
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        case .done:
            Section {
                Label {
                    Text("The backup is restored.")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } footer: {
                if mode.iCloudSyncEnabled {
                    Text("BlueDive now uploads the restored logbook to iCloud. Keep it open until the upload is complete, then install BlueDive again on your other devices: they download the restored logbook.")
                }
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            if mode.status == .done {
                Button {
                    mode.continueToApp()
                } label: {
                    Text("Continue")
                        .accentLabelOnMac()
                }
                .listRowButton()
            } else {
                Button {
                    // After a failed cancel, Try Again retries the cancel, never the restore.
                    if mode.status == .failed(.cancelFailed) {
                        Task { await mode.cancel() }
                    } else {
                        Task { await mode.start() }
                    }
                } label: {
                    Group {
                        if case .failed = mode.status {
                            Text("Try Again")
                        } else {
                            Text("Restore Now")
                        }
                    }
                    .accentLabelOnMac()
                }
                .listRowButton()
                .disabled(mode.isWorking)
                Button("Cancel Restore", role: .destructive) {
                    showCancelConfirmation = true
                }
                .listRowButton()
                .disabled(mode.isWorking)
            }
        }
    }
}

private extension View {
    /// macOS: the row button's label in the accent colour. Restore mode's window does not pass
    /// the app's tint to `listRowButton()` there (observed: the labels were drawn white), so the
    /// colour goes on the label, as `listRowButton()` documents. On iOS the view is unchanged.
    func accentLabelOnMac() -> some View {
        #if os(macOS)
        self.foregroundStyle(Color.accentColor)
        #else
        self
        #endif
    }

    /// macOS: records the height of a scrollable view's content in `height`. On iOS the view is
    /// returned unchanged.
    func measuresContentHeightOnMac(_ height: Binding<CGFloat?>) -> some View {
        #if os(macOS)
        self.onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
        } action: { _, newHeight in
            height.wrappedValue = newHeight
        }
        #else
        self
        #endif
    }

    /// macOS: the restore screen fills the main window, which opens maximized; there it is shown
    /// as a card of a readable size centred on the app background, instead of a short form at
    /// the top of an empty window. The card is as tall as the form's content (`contentHeight`,
    /// measured by `measuresContentHeightOnMac`), never taller than the window allows, so a
    /// state with more rows (an error) grows it and one with fewer (done) shrinks it. On iOS the
    /// view is returned unchanged.
    func restoreCardOnMac(contentHeight: CGFloat?) -> some View {
        #if os(macOS)
        self
            .frame(maxWidth: 720, maxHeight: contentHeight ?? 760)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppBackground())
        #else
        self
        #endif
    }
}
