import SwiftUI
import SwiftData
import CoreBluetooth
import LibDCSwift
import Combine
import os.log

/// Value-type snapshot of the DeviceFingerprint fields read during a BLE scan.
/// Replaces a live @Model reference in @State so that iCloud/SwiftData mutations
/// to the source record mid-scan do not affect the cached values.
struct CachedDeviceFingerprint {
    let serial: String
    let computerName: String
    let family: DeviceConfiguration.DeviceFamily?
    let modelID: UInt32
}

/// Value-type snapshot of a DeviceFingerprint used for the reassociation prompt.
/// Keeps display data stable while the SwiftData record may update mid-scan.
struct ReassociationCandidate: Identifiable {
    let id: String
    let serial: String
    let computerName: String
    let family: DeviceConfiguration.DeviceFamily?
    let modelID: UInt32
    let lastSynced: Date
    let diverName: String?
}

// MARK: - Bluetooth Scanner View

struct BluetoothScannerView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) var modelContext
    @Environment(\.locale) var locale
    /// Not `private`: the import path that calls `commitListRebuild()` lives in an extension in
    /// another file (BluetoothScannerView+Import.swift), which `private` would not reach.
    @Environment(DiveStore.self) var store

    // MARK: State

    @Query(sort: \DeviceFingerprint.updatedAt, order: .reverse) var knownDevices: [DeviceFingerprint]
    @Query(filter: #Predicate<Gear> { $0.category == "Computer" }) var gearComputers: [Gear]

    @ObservedObject var bleManager = CoreBluetoothManager.sharedManager
    @State var syncState: BluetoothSyncState = .idle
    /// Mirrors `Self.isTeardownUnsafe(syncState)` out to the presenting view so it can
    /// block swipe-to-dismiss with `.interactiveDismissDisabled(...)`. Kept in sync by the
    /// `.onChange(of: syncState, initial: true)` below — never assigned anywhere else, and only
    /// when the computed value actually changes (see the guard there).
    @Binding var isTeardownUnsafe: Bool
    @State var selectedDevice: CBPeripheral?
    @State var downloadedDives: [DiveData] = []
    @State var importProgress: Double = 0
    @State var showingImportConfirmation = false
    @State var importSaveErrorMessage: String? = nil
    @State var connectedDeviceName: String?
    @State var downloadAllDives: Bool = false
    @AppStorage("filterUnusedTanks") var filterUnusedTanks: Bool = false
    @AppStorage("syncDeviceClock") var syncDeviceClock: Bool = true
    /// The app-wide diver filter. Read only as a fallback hint when seeding the import cutoff
    /// for a device whose owning diver cannot be resolved; nothing here writes to it.
    @AppStorage(DiverFilter.storageKey) var selectedDiver: String = ""
    #if os(iOS)
    @State var showLogExporter = false
    @State var logExportDocument: ExportableFileDocument?
    @State var logExportFileName: String = ""
    #endif
    @State var diveCountDuringDownload: Int = 0
    @State var downloadProgressCancellable: AnyCancellable?
    @State var isSearching: Bool = false
    @State var cachedTargetFingerprint: CachedDeviceFingerprint?
    @State var pendingDeviceStorageSeed: (uuid: String, name: String, family: DeviceConfiguration.DeviceFamily, modelID: UInt32, serial: String)?
    /// The exact `StoredDevice` entries removed by a reassociation prune whose corresponding
    /// connection attempt has not yet been confirmed successful. Only armed on the legacy
    /// (no family/modelID) reassociation path, which cannot set `pendingDeviceStorageSeed` and so
    /// has no other way to recover the pruned mapping if the connect fails. Restored by
    /// `connectToDevice`'s failure branches and cleared (without restoring) once the connection
    /// is confirmed viable.
    @State var pendingReassociationPruneRestore: [StoredDevice]? = nil
    @State var deviceToDelete: DeviceFingerprint?
    @State var showingDeleteConfirmation = false
    @State var modelOverrides: [String: DeviceConfiguration.ComputerModel] = [:]
    @State var peripheralForModelPicker: CBPeripheral?
    @State var showInfo = false
    @State var peripheralPendingReassociation: CBPeripheral?
    @State var peripheralForReassociationPicker: CBPeripheral?
    @State var reassociationCandidates: [ReassociationCandidate] = []
    @State var showingReassociationAlert = false
    @State var isPartialSync: Bool = false

    // MARK: Import date cutoff

    /// User opted in to an import cutoff for this sync. Per-session only — never persisted.
    /// After the first import the fingerprint watermark handles incremental sync, so a
    /// remembered cutoff would silently drop dives on later syncs.
    @State var importCutoffEnabled: Bool = false
    /// DatePicker binding (non-optional). Seeded by prepareImportCutoffDefault().
    @State var importCutoffDate: Date = Date()
    /// One-shot guard so the newest-dive fetch runs once per sheet session.
    @State var importCutoffDateInitialized: Bool = false
    /// True once the user has picked a cutoff date by hand. The seeding helpers assign
    /// `importCutoffDate` directly, so only the DatePicker's binding below can set this —
    /// which is what lets a re-seed know it would be discarding a deliberate choice.
    @State var importCutoffDateUserEdited: Bool = false
    /// Downloaded dives discarded by the cutoff, for the results UI.
    @State var cutoffFilteredCount: Int = 0
    /// The cutoff actually applied; nil when none was.
    @State var cutoffAppliedDate: Date?

    /// DatePicker binding for the import cutoff. Routing user interaction through this setter
    /// (rather than `$importCutoffDate`) is what distinguishes a hand-picked date from a
    /// programmatic seed, since only interaction goes through a binding.
    var importCutoffDateBinding: Binding<Date> {
        Binding(
            get: { importCutoffDate },
            set: { newValue in
                importCutoffDateUserEdited = true
                importCutoffDate = newValue
            }
        )
    }

    // Logger for debugging
    static let logger = Logger(subsystem: "com.bluedive.app", category: "Bluetooth")

    /// True while a BLE device connection is open and a retrieval may still be in flight.
    /// Dismissing the sheet in any of these states runs `onDisappear`, which calls
    /// `bleManager.close(clearDevicePtr: true)` → `free_device_data(devicePtr)` — that free is
    /// unconditional, and `dc_device_foreach` may still be dereferencing the same pointer on a
    /// background queue (EXC_BAD_ACCESS / double free).
    ///
    /// Both dismissal routes must be blocked, and both read this one helper so they cannot
    /// drift: the toolbar Close button's `.disabled(...)` (BluetoothScannerView+Views.swift)
    /// and the `isTeardownUnsafe` binding that drives the presenting view's
    /// `.interactiveDismissDisabled(...)`. The switch is exhaustive on purpose — a new
    /// `BluetoothSyncState` case will not compile until it is classified here.
    static func isTeardownUnsafe(_ state: BluetoothSyncState) -> Bool {
        switch state {
        case .connecting, .downloading, .importing:
            return true
        case .idle, .scanning, .completed, .error:
            return false
        }
    }

    /// De-duplicated by serial, keeping the most recently updated record per serial (the query
    /// above is already sorted updatedAt descending, so the first occurrence for each serial is
    /// that one — the same "most recent wins" rule persistFingerprintRecord and
    /// syncFingerprintFromDatabase use). Duplicate serials can occur after an iCloud merge;
    /// without this, the known-devices ForEach and the reassociation candidate list would both
    /// produce duplicate Identifiable IDs for one physical device.
    ///
    /// Sentinel and empty serials are exempt and always kept, matching `deleteKnownDevice`,
    /// `syncFingerprintFromDatabase` and `confirmReassociation`: a value like "0"/"00000000" is
    /// reported by hardware that doesn't expose a real serial, so two *different* physical
    /// computers can share it and must not collapse into one row.
    var dedupedKnownDevices: [DeviceFingerprint] {
        var seen = Set<String>()
        return knownDevices.filter { device in
            guard let key = device.serial.normalizedComputerSerial() else { return true }
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    // Keys are lowercased for case-insensitive lookup (some devices report mixed-case serials).
    var diverNameBySerial: [String: String] {
        var map: [String: String] = [:]
        var ambiguous = Set<String>()
        for gear in gearComputers {
            guard let rawSerial = gear.serialNumber else { continue }
            let serial = rawSerial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let name = gear.diverName.trimmingCharacters(in: .whitespaces)
            guard !serial.isEmpty, !name.isEmpty else { continue }
            if ambiguous.contains(serial) { continue }
            if let existing = map[serial], existing != name {
                ambiguous.insert(serial)
                map.removeValue(forKey: serial)
            } else {
                map[serial] = name
            }
        }
        return map
    }

    /// Note appended to the import confirmation alert when the cutoff discarded some of the
    /// downloaded dives. Written as a plain function (not inline in the alert's `message:`
    /// closure) because that closure is `@ViewBuilder`-typed — a top-level if/else *statement*
    /// there is parsed as conditional view content, not plain code, and fails to type-check.
    private func cutoffAlertNote() -> String {
        guard cutoffFilteredCount > 0, let cutoffAppliedDate else { return "" }
        let countText = Double(cutoffFilteredCount).localizedString(decimals: 0)
        let dateText = cutoffAppliedDate.formatted(.dateTime.locale(locale).day().month(.wide).year())
        return "\n\n" + (cutoffFilteredCount == 1
            ? String(format: NSLocalizedString("1 more dive was downloaded but will not be imported — it was recorded before %@.", bundle: .forAppLanguage(), value: "1 more dive was downloaded but will not be imported — it was recorded before %@.", comment: "Note appended to the Bluetooth import confirmation alert when exactly one downloaded dive falls before the user's import cutoff date. %@ is the cutoff date."), dateText)
            : String(format: NSLocalizedString("%1$@ more dives were downloaded but will not be imported — they were recorded before %2$@.", bundle: .forAppLanguage(), value: "%1$@ more dives were downloaded but will not be imported — they were recorded before %2$@.", comment: "Note appended to the Bluetooth import confirmation alert when several downloaded dives fall before the user's import cutoff date. %1$@ is the locale-formatted dive count, %2$@ is the cutoff date."), countText, dateText))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Status header
                syncStatusHeader

                Divider()

                // Main content
                mainContent
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                toolbarContent
            }
            .alert("Import Dives", isPresented: $showingImportConfirmation) {
                Button("Cancel", role: .cancel) {
                    downloadedDives = []
                    selectedDevice = nil
                    connectedDeviceName = nil
                    isPartialSync = false
                    importSaveErrorMessage = nil
                    clearCutoffResults()
                    syncState = .idle
                }
                Button("Import") {
                    importDownloadedDives()
                }
            } message: {
                let base = downloadedDives.count == 1
                    ? NSLocalizedString("Do you want to import 1 dive from your dive computer?", bundle: .forAppLanguage(), comment: "An alert message asking the user to confirm importing exactly one dive from their dive computer.")
                    : String(format: NSLocalizedString("Do you want to import %lld dives from your dive computer?", bundle: .forAppLanguage(), comment: "An alert message asking the user to confirm importing multiple dives from their dive computer."), downloadedDives.count)
                let cutoffNote = cutoffAlertNote()
                let partial = isPartialSync
                    ? "\n\n" + NSLocalizedString("Sync was incomplete — one or more older dives on the device could not be read.", bundle: .forAppLanguage(), value: "Sync was incomplete — one or more older dives on the device could not be read.", comment: "Note appended to the import confirmation alert when a BLE sync completed only partially due to a protocol error on the dive computer (e.g. a corrupt dive slot).")
                    : ""
                let saveError = importSaveErrorMessage.map {
                    "\n\n" + String(format: NSLocalizedString("Previous save failed:\n%@", bundle: .forAppLanguage(), value: "Previous save failed:\n%@", comment: "Note appended to the import confirmation alert when re-presented after a save failure. %@ is the system error description explaining why the previous import save did not complete."), $0)
                } ?? ""
                Text(verbatim: base + cutoffNote + partial + saveError)
            }
            .onAppear {
                // Don't auto-scan; show known devices first
            }
            .onReceive(bleManager.$discoveredPeripherals) { _ in
                checkForTargetDevice()
            }
            .onDisappear {
                stopScanning()
                BLEDiagnosticSession.shared.stop()
                bleManager.close(clearDevicePtr: true)
                downloadProgressCancellable = nil
                isSearching = false
                cachedTargetFingerprint = nil
                clearCutoffResults()
                // Kept alongside clearCutoffResults() for internal consistency — @State already resets fresh on each sheet presentation, so this has no observable effect today, but the two should travel together.
                disarmImportCutoff()
                discardPendingSeed()
                // SwiftUI dismisses the retry alert on disappear but leaves syncState .importing; clear all session state so orphaned dives cannot be silently overwritten.
                if case .importing = syncState {
                    syncState = .idle
                    downloadedDives = []
                    importSaveErrorMessage = nil
                    showingImportConfirmation = false
                    isPartialSync = false
                }
                #if os(iOS)
                UIApplication.shared.isIdleTimerDisabled = false
                Self.logger.debug("Screen lock re-enabled (onDisappear)")
                #endif
            }
            #if os(iOS)
            .onChange(of: syncState) { _, newState in
                let shouldPreventLock = newState.isActive
                // syncState is reassigned on every download-progress tick, so only write and log on a real change.
                guard UIApplication.shared.isIdleTimerDisabled != shouldPreventLock else { return }
                UIApplication.shared.isIdleTimerDisabled = shouldPreventLock
                Self.logger.debug("Screen lock \(shouldPreventLock ? "disabled" : "re-enabled") (syncState: \(String(describing: newState)))")
            }
            #endif
            // Not inside the #if os(iOS) gate above: dismiss-safety applies on every platform
            // this view ships on, unlike the idle-timer handling.
            // Write-guarded: `.downloading(current:total:)` is reassigned on every
            // libdivecomputer progress callback (many times per second), and every one of those
            // maps to the same Bool. Writing the binding unconditionally would invalidate the
            // presenting ContentView — the app's single `@Query Dive` owner — on a hot path.
            .onChange(of: syncState, initial: true) { _, newState in
                let newValue = Self.isTeardownUnsafe(newState)
                if isTeardownUnsafe != newValue {
                    isTeardownUnsafe = newValue
                }
            }
            .alert("Delete Dive Computer", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    deviceToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    if let device = deviceToDelete {
                        deleteKnownDevice(device)
                    }
                    deviceToDelete = nil
                }
            } message: {
                if let device = deviceToDelete {
                    Text("Remove \(device.computerName) (\(device.serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())) from known devices? The next sync will re-download all dives from this computer.")
                }
            }
            .alert("Update Bluetooth Pairing?", isPresented: $showingReassociationAlert) {
                Button("Connect") {
                    if let peripheral = peripheralPendingReassociation,
                       let candidate = reassociationCandidates.first {
                        confirmReassociation(peripheral, candidate: candidate)
                    }
                    clearReassociationState()
                }
                Button("Connect as New Device") {
                    if let peripheral = peripheralPendingReassociation {
                        // Pairing as a new device still means a full-history download, and the
                        // matched candidate is the best available clue to who owns the hardware,
                        // so anchor the cutoff on that diver. Read from the same
                        // `reassociationCandidates.first` the alert's message and Connect button
                        // use; must run before clearReassociationState() empties the array.
                        prepareImportCutoffDefault(forDiver: reassociationCandidates.first?.diverName)
                        connectToDevice(peripheral)
                    }
                    clearReassociationState()
                }
                Button("Cancel", role: .cancel) {
                    clearReassociationState()
                }
            } message: {
                if let candidate = reassociationCandidates.first {
                    if let diverName = candidate.diverName {
                        Text(verbatim: String(format: NSLocalizedString(
                            "This looks like %1$@\u{2019}s %2$@, last synced %3$@. Connect and update the Bluetooth pairing?",
                            bundle: Bundle.forAppLanguage(),
                            comment: "Reassociation alert message when a scanned device matches a known dive computer with a diver name. %1$@ = diver name, %2$@ = computer name, %3$@ = last sync date."),
                            diverName, candidate.computerName,
                            candidate.lastSynced.formatted(.dateTime.locale(locale).day().month(.wide).year())))
                    } else {
                        Text(verbatim: String(format: NSLocalizedString(
                            "This looks like your %1$@ (serial \u{2026}%2$@), last synced %3$@. Connect and update the Bluetooth pairing?",
                            bundle: Bundle.forAppLanguage(),
                            comment: "Reassociation alert message when a scanned device matches a known dive computer without a diver name. %1$@ = computer name, %2$@ = last 4 chars of serial, %3$@ = last sync date."),
                            candidate.computerName,
                            String(candidate.serial.suffix(4)).uppercased(),
                            candidate.lastSynced.formatted(.dateTime.locale(locale).day().month(.wide).year())))
                    }
                }
            }
            .sheet(item: $peripheralForReassociationPicker, onDismiss: clearReassociationState) { peripheral in
                DeviceReassociationPickerSheet(
                    candidates: reassociationCandidates,
                    onSelect: { selected in
                        if let candidate = selected {
                            confirmReassociation(peripheral, candidate: candidate)
                        } else {
                            // Multiple candidates matched this peripheral by name/model, so there's no
                            // single owning device to anchor to the way confirmReassociation does — but
                            // if every candidate happens to share the same diver, that's still a safe,
                            // better-than-generic anchor. If they disagree (or none have a diver), fall
                            // through to the generic seed via nil.
                            let candidateDiverNames = Set(reassociationCandidates.compactMap { $0.diverName })
                            prepareImportCutoffDefault(forDiver: candidateDiverNames.count == 1 ? candidateDiverNames.first : nil)
                            connectToDevice(peripheral)
                        }
                    }
                )
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showInfo) {
                infoSheet
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        // ⚠️ Temporary — remove after testing delete feature - Add Dummy Dive computer to database
        // #if DEBUG
        // .onAppear {
        //     let testDevices: [(String, String)] = [
        //         ("TEST-001", "Shearwater Perdix 2"),
        //         ("TEST-002", "Suunto D5"),
        //         ("TEST-003", "Garmin Descent Mk3i")
        //     ]
        //     for (serial, name) in testDevices {
        //         let s = serial
        //         let predicate = #Predicate<DeviceFingerprint> { $0.serial == s }
        //         let existing = (try? modelContext.fetch(FetchDescriptor(predicate: predicate))) ?? []
        //         if existing.isEmpty {
        //             modelContext.insert(DeviceFingerprint(serial: serial, computerName: name, fingerprintData: Data()))
        //         }
        //     }
        //     try? modelContext.save()
        // }
        // #endif
        #if os(macOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}

// MARK: - Preview

#Preview {
    BluetoothScannerView(isTeardownUnsafe: .constant(false))
        .modelContainer(for: Dive.self, inMemory: true)
        .environment(DiveStore())
}
