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
    @Environment(\.locale) private var locale

    // MARK: State

    @Query(sort: \DeviceFingerprint.updatedAt, order: .reverse) var knownDevices: [DeviceFingerprint]
    @Query(filter: #Predicate<Gear> { $0.category == "Computer" }) var gearComputers: [Gear]

    @ObservedObject var bleManager = CoreBluetoothManager.sharedManager
    @State var syncState: BluetoothSyncState = .idle
    @State var selectedDevice: CBPeripheral?
    @State var downloadedDives: [DiveData] = []
    @State var importProgress: Double = 0
    @State var showingImportConfirmation = false
    @State var connectedDeviceName: String?
    @State var downloadAllDives: Bool = false
    @AppStorage("filterUnusedTanks") var filterUnusedTanks: Bool = false
    @AppStorage("syncDeviceClock") var syncDeviceClock: Bool = true
    @State var diveCountDuringDownload: Int = 0
    @State var downloadProgressCancellable: AnyCancellable?
    @State var isSearching: Bool = false
    @State var cachedTargetFingerprint: CachedDeviceFingerprint?
    @State var pendingDeviceStorageSeed: (uuid: String, name: String, family: DeviceConfiguration.DeviceFamily, modelID: UInt32, serial: String)?
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

    // Logger for debugging
    static let logger = Logger(subsystem: "com.bluedive.app", category: "Bluetooth")

    // Keys are lowercased for case-insensitive lookup (some devices report mixed-case serials).
    var diverNameBySerial: [String: String] {
        var map: [String: String] = [:]
        var ambiguous = Set<String>()
        for gear in gearComputers {
            guard let rawSerial = gear.serialNumber else { continue }
            let serial = rawSerial.trimmingCharacters(in: .whitespaces).lowercased()
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
                    syncState = .idle
                }
                Button("Import") {
                    importDownloadedDives()
                }
            } message: {
                let base = downloadedDives.count == 1
                    ? NSLocalizedString("Do you want to import 1 dive from your dive computer?", bundle: .forAppLanguage(), comment: "An alert message asking the user to confirm importing exactly one dive from their dive computer.")
                    : String(format: NSLocalizedString("Do you want to import %lld dives from your dive computer?", bundle: .forAppLanguage(), comment: "An alert message asking the user to confirm importing multiple dives from their dive computer."), downloadedDives.count)
                let partial = isPartialSync
                    ? "\n\n" + NSLocalizedString("Sync was incomplete — one or more older dives on the device could not be read.", bundle: .forAppLanguage(), value: "Sync was incomplete — one or more older dives on the device could not be read.", comment: "Note appended to the import confirmation alert when a BLE sync completed only partially due to a protocol error on the dive computer (e.g. a corrupt dive slot).")
                    : ""
                Text(verbatim: base + partial)
            }
            .onAppear {
                // Don't auto-scan; show known devices first
            }
            .onReceive(bleManager.$discoveredPeripherals) { _ in
                checkForTargetDevice()
            }
            .onDisappear {
                stopScanning()
                bleManager.close(clearDevicePtr: true)
                downloadProgressCancellable = nil
                isSearching = false
                cachedTargetFingerprint = nil
                discardPendingSeed()
                #if os(iOS)
                UIApplication.shared.isIdleTimerDisabled = false
                Self.logger.debug("Screen lock re-enabled (onDisappear)")
                #endif
            }
            #if os(iOS)
            .onChange(of: syncState) { _, newState in
                let shouldPreventLock = newState.isActive
                UIApplication.shared.isIdleTimerDisabled = shouldPreventLock
                Self.logger.debug("Screen lock \(shouldPreventLock ? "disabled" : "re-enabled") (syncState: \(String(describing: newState)))")
            }
            #endif
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
                    Text("Remove \(device.computerName) (\(device.serial)) from known devices? The next sync will re-download all dives from this computer.")
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
    BluetoothScannerView()
        .modelContainer(for: Dive.self, inMemory: true)
}
