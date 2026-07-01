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

// MARK: - Bluetooth Scanner View

struct BluetoothScannerView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) var modelContext

    // MARK: State

    @Query(sort: \DeviceFingerprint.updatedAt, order: .reverse) var knownDevices: [DeviceFingerprint]

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

    // Logger for debugging
    static let logger = Logger(subsystem: "com.bluedive.app", category: "Bluetooth")

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Status header
                syncStatusHeader

                Divider()

                // Main content
                mainContent
            }
            .navigationTitle("Sync")
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
                    syncState = .idle
                }
                Button("Import") {
                    importDownloadedDives()
                }
            } message: {
                Text("Do you want to import \(downloadedDives.count) dive(s) from your dive computer?")
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
                if let seed = pendingDeviceStorageSeed {
                    modelOverrides.removeValue(forKey: seed.uuid)
                    pendingDeviceStorageSeed = nil
                }
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
