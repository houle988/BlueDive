import SwiftUI
import SwiftData
import CoreBluetooth
import LibDCSwift
import Combine
import os.log

// MARK: - Sync State

/// Possible Bluetooth sync states
enum BluetoothSyncState: Equatable {
    case idle
    case scanning
    case connecting(deviceName: String)
    case downloading(current: Int, total: Int)
    case importing(count: Int)
    case completed(imported: Int, merged: Int, skipped: Int)
    case error(message: String)
    
    var isActive: Bool {
        switch self {
        case .idle, .completed, .error:
            return false
        default:
            return true
        }
    }
}

// MARK: - Bluetooth Scanner View

struct BluetoothScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    
    // MARK: State
    
    @ObservedObject private var bleManager = CoreBluetoothManager.sharedManager
    @State private var syncState: BluetoothSyncState = .idle
    @State private var selectedDevice: CBPeripheral?
    @State private var downloadedDives: [DiveData] = []
    @State private var importProgress: Double = 0
    @State private var showingImportConfirmation = false
    @State private var connectedDeviceName: String?
    @State private var downloadAllDives: Bool = false
    @AppStorage("filterUnusedTanks") private var filterUnusedTanks: Bool = false
    @AppStorage("syncDeviceClock") private var syncDeviceClock: Bool = true
    @State private var diveCountDuringDownload: Int = 0
    @State private var downloadProgressCancellable: AnyCancellable?
    @State private var isSearching: Bool = false
    @State private var targetDeviceSerial: String?
    @State private var targetDeviceName: String?
    @State private var deviceToDelete: DeviceFingerprint?
    @State private var showingDeleteConfirmation = false
    @State private var modelOverrides: [String: DeviceConfiguration.ComputerModel] = [:]
    @State private var peripheralForModelPicker: CBPeripheral?
    
    // Logger for debugging
    private static let logger = Logger(subsystem: "com.bluedive.app", category: "Bluetooth")
    
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
                isSearching = false
                targetDeviceSerial = nil
                targetDeviceName = nil
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
    
    // MARK: - Sync Status Header
    
    @ViewBuilder
    private var syncStatusHeader: some View {
        VStack(spacing: 12) {
            // Status icon
            ZStack {
                Circle()
                    .fill(syncStateColor.opacity(0.15))
                    .frame(width: 80, height: 80)
                
                Group {
                    switch syncState {
                    case .scanning:
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 32))
                            .foregroundStyle(syncStateColor)
                            .symbolEffect(.variableColor.iterative.reversing)
                    case .connecting:
                        Image(systemName: "link")
                            .font(.system(size: 32))
                            .foregroundStyle(syncStateColor)
                            .symbolEffect(.pulse)
                    case .downloading:
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 32))
                            .foregroundStyle(syncStateColor)
                            .symbolEffect(.bounce.byLayer)
                    case .importing:
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 32))
                            .foregroundStyle(syncStateColor)
                            .symbolEffect(.bounce)
                    case .completed:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.green)
                    case .error:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.red)
                    case .idle:
                        Image(systemName: "antenna.radiowaves.left.and.right.circle")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // Status text
            VStack(spacing: 4) {
                Text(syncStateTitle)
                    .font(.headline)
                
                Text(syncStateSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            // Progress bar
            if case .downloading(let current, let total) = syncState {
                VStack(spacing: 4) {
                    if total > 0 {
                        ProgressView(value: Double(current), total: Double(total))
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 200)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    
                    if diveCountDuringDownload > 1 {
                        Text(verbatim: String(format: NSLocalizedString("%lld dive(s) downloaded", bundle: Bundle.forAppLanguage(), comment: "A text label displaying the number of dives that have been successfully downloaded. The argument is the number of dives that have been downloaded."), diveCountDuringDownload - 1))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: NSLocalizedString("Downloading...", bundle: Bundle.forAppLanguage(), comment: "A placeholder text displayed when downloading dives."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if case .importing = syncState {
                ProgressView(value: importProgress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 200)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }
    
    // MARK: - Main Content
    
    @ViewBuilder
    private var mainContent: some View {
        switch syncState {
        case .completed(let imported, let merged, let skipped):
            completedView(imported: imported, merged: merged, skipped: skipped)
        case .error(let message):
            errorView(message: message)
        case .idle where !isSearching:
            knownDevicesView
        case .scanning, .idle:
            deviceListView
        default:
            // .connecting, .downloading, .importing — header shows status
            Spacer()
        }
    }
    
    // MARK: - Known Devices View
    
    /// Fetches DeviceFingerprint records from the database to display known dive computers.
    private var knownDevices: [DeviceFingerprint] {
        let descriptor = FetchDescriptor<DeviceFingerprint>(
            sortBy: [SortDescriptor(\DeviceFingerprint.updatedAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }
    
    @ViewBuilder
    private var knownDevicesView: some View {
        let devices = knownDevices
        Form {
            if !devices.isEmpty {
                Section {
                    ForEach(devices, id: \.serial) { device in
                        KnownDeviceRow(
                            computerName: device.computerName,
                            serial: device.serial,
                            lastSynced: device.updatedAt,
                            onTap: { connectToKnownDevice(device) }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                deviceToDelete = device
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                deviceToDelete = device
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Known Dive Computers")
                } footer: {
                    Text("Tap a device to scan and connect automatically.")
                }
            }
            
            Section {
                Toggle("Download all dives", isOn: $downloadAllDives)
            } footer: {
                Text("Enable this option to ignore the fingerprint and re-download all dives from the computer. Duplicates will be automatically skipped during import.")
            }

            Section {
                Toggle("Sync device clock", isOn: $syncDeviceClock)
            } footer: {
                Text("Automatically set the dive computer's clock to your device's current time and time zone after each sync.")
            }

            Section {
                Button {
                    isSearching = true
                    startScanning()
                } label: {
                    Label(
                        "Search for Devices",
                        systemImage: "antenna.radiowaves.left.and.right"
                    )
                }
            } footer: {
                if devices.isEmpty {
                    Text("No previously synced dive computers found. Tap to search for nearby Bluetooth devices.")
                } else {
                    Text("Search for new or previously unpaired dive computers.")
                }
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - Device List View
    
    @ViewBuilder
    private var deviceListView: some View {
        if bleManager.discoveredPeripherals.isEmpty {
            ContentUnavailableView {
                Label("Searching...", systemImage: "antenna.radiowaves.left.and.right")
            } description: {
                Text("Make sure your dive computer is turned on and in Bluetooth transfer mode.")
            }
        } else {
            Form {
                Section {
                    ForEach(bleManager.discoveredPeripherals, id: \.identifier) { peripheral in
                        DeviceRow(
                            peripheral: peripheral,
                            isSelected: selectedDevice?.identifier == peripheral.identifier,
                            isConnecting: isConnecting(to: peripheral),
                            modelOverride: modelOverrides[peripheral.identifier.uuidString],
                            onTap: { connectToDevice(peripheral) },
                            onChangeModel: {
                                peripheralForModelPicker = peripheral
                            }
                        )
                        .disabled(syncState.isActive && syncState != .scanning)
                    }
                } header: {
                    HStack {
                        Text("Available Devices")
                        Spacer()
                        Text("\(bleManager.discoveredPeripherals.count)")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Select your dive computer to download new dives. Tap the info button to change the detected model if incorrect.")
                }
                
                Section {
                    Toggle("Download all dives", isOn: $downloadAllDives)
                        .disabled(syncState.isActive && syncState != .scanning)
                } footer: {
                    Text("Enable this option to ignore the fingerprint and re-download all dives from the computer. Duplicates will be automatically skipped during import.")
                }

                Section {
                    Toggle("Sync device clock", isOn: $syncDeviceClock)
                        .disabled(syncState.isActive && syncState != .scanning)
                } footer: {
                    Text("Automatically set the dive computer's clock to your device's current time and time zone after each sync.")
                }
            }
            .formStyle(.grouped)
            .sheet(isPresented: Binding(
                get: { peripheralForModelPicker != nil },
                set: { if !$0 { peripheralForModelPicker = nil } }
            )) {
                if let peripheral = peripheralForModelPicker {
                    ModelPickerSheet(
                        detectedName: DeviceConfiguration.getDeviceDisplayName(from: peripheral.name ?? "Unknown"),
                        currentOverride: modelOverrides[peripheral.identifier.uuidString],
                        onSelect: { model in
                            if let model = model {
                                modelOverrides[peripheral.identifier.uuidString] = model
                            } else {
                                modelOverrides.removeValue(forKey: peripheral.identifier.uuidString)
                            }
                        }
                    )
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                }
            }
        }
    }
    
    // MARK: - Completed View
    
    @ViewBuilder
    private func completedView(imported: Int, merged: Int, skipped: Int) -> some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            
            VStack(spacing: 8) {
                Text("Sync Complete")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                if imported > 0 {
                    Text("\(imported) dive(s) imported")
                        .foregroundStyle(.secondary)
                }
                
                if merged > 0 {
                    Text("\(merged) dive(s) updated")
                        .foregroundStyle(.secondary)
                }
                
                if skipped > 0 {
                    Text("\(skipped) dive(s) already in logbook")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Button("Close") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            
            Spacer()
        }
        .padding()
    }
    
    // MARK: - Error View
    
    @ViewBuilder
    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.red)
            
            VStack(spacing: 8) {
                Text("Sync Error")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            HStack(spacing: 12) {
                Button("Retry") {
                    isSearching = false
                    targetDeviceSerial = nil
                    targetDeviceName = nil
                    syncState = .idle
                }
                .buttonStyle(.bordered)
                
                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            
            Spacer()
        }
        .padding()
    }
    
    // MARK: - Toolbar
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close") {
                stopScanning()
                bleManager.close(clearDevicePtr: true)
                dismiss()
            }
            .disabled(syncState.isActive && syncState != .scanning)
        }
        
        ToolbarItem(placement: .primaryAction) {
            if syncState == .scanning {
                HStack(spacing: 12) {
                    Button {
                        stopScanning()
                        isSearching = false
                        targetDeviceSerial = nil
                        targetDeviceName = nil
                        syncState = .idle
                    } label: {
                        Text("Cancel")
                    }
                    
                    Button {
                        stopScanning()
                        startScanning()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var syncStateColor: Color {
        switch syncState {
        case .idle: return .secondary
        case .scanning: return .cyan
        case .connecting: return .orange
        case .downloading: return .blue
        case .importing: return .purple
        case .completed: return .green
        case .error: return .red
        }
    }
    
    private var syncStateTitle: String {
        let bundle = Bundle.forAppLanguage()
        switch syncState {
        case .idle:
            return isSearching
                ? NSLocalizedString("Ready", bundle: bundle, comment: "Title shown in the Bluetooth scanner when ready to connect to a device")
                : NSLocalizedString("Sync", bundle: bundle, comment: "The title of the screen where users can sync their dives with their dive computer.")
        case .scanning:
            return NSLocalizedString("Searching...", bundle: bundle, comment: "A label with an image that indicates a search is in progress.")
        case .connecting(let name):
            return String(format: NSLocalizedString("Connecting to %@", bundle: bundle, comment: "Title shown while connecting to a Bluetooth dive computer. %@ is the device name."), name)
        case .downloading:
            return NSLocalizedString("Downloading...", bundle: bundle, comment: "A placeholder text displayed when downloading dives.")
        case .importing(let count):
            return String(format: NSLocalizedString("Importing %lld dives...", bundle: bundle, comment: "Title shown while importing dives from a dive computer. %lld is the number of dives."), count)
        case .completed(let imported, let merged, _):
            return (imported + merged) > 0
                ? NSLocalizedString("Sync Complete", bundle: bundle, comment: "A title and some body text displayed after a successful Bluetooth sync.")
                : NSLocalizedString("No New Dives", bundle: bundle, comment: "Title shown when there are no new dives to import from the dive computer")
        case .error:
            return NSLocalizedString("Error", bundle: bundle, comment: "The title of an alert that appears when there is a validation error.")
        }
    }
    
    private var syncStateSubtitle: String {
        let bundle = Bundle.forAppLanguage()
        switch syncState {
        case .idle:
            return isSearching
                ? NSLocalizedString("Select a device to begin", bundle: bundle, comment: "Subtitle shown in the Bluetooth scanner when ready to select a device")
                : NSLocalizedString("Select a dive computer to sync", bundle: bundle, comment: "Subtitle shown in the Bluetooth scanner idle state")
        case .scanning:
            return targetDeviceSerial != nil
                ? NSLocalizedString("Looking for your dive computer...", bundle: bundle, comment: "Subtitle shown while scanning for a specific known dive computer")
                : NSLocalizedString("Searching for Bluetooth dive computers...", bundle: bundle, comment: "Subtitle shown while scanning for Bluetooth dive computers")
        case .connecting:
            return NSLocalizedString("Establishing connection...", bundle: bundle, comment: "Subtitle shown while connecting to a Bluetooth dive computer")
        case .downloading:
            if diveCountDuringDownload > 0 {
                return String(format: NSLocalizedString("Downloading dive %lld...", bundle: bundle, comment: "Subtitle showing the current dive being downloaded. %lld is the dive number."), diveCountDuringDownload)
            }
            return NSLocalizedString("Reading dive computer...", bundle: bundle, comment: "Subtitle shown while reading data from a dive computer")
        case .importing:
            return NSLocalizedString("Saving to logbook...", bundle: bundle, comment: "Subtitle shown while saving downloaded dives to the logbook")
        case .completed(let imported, let merged, let skipped):
            if imported == 0 && merged == 0 && skipped == 0 {
                return NSLocalizedString("Your logbook is up to date", bundle: bundle, comment: "Subtitle shown when the logbook is already up to date after sync")
            } else if merged > 0 && imported == 0 {
                return String(format: NSLocalizedString("%lld dive(s) updated", bundle: bundle, comment: "A label indicating that a number of dives have been updated (merged) with existing dives in the logbook. The argument is the number of dives that have been updated."), merged)
            } else if skipped > 0 {
                return String(format: NSLocalizedString("%lld dive(s) already present", bundle: bundle, comment: "Subtitle showing the number of dives already present in the logbook"), skipped)
            }
            return NSLocalizedString("All dives have been imported", bundle: bundle, comment: "Subtitle shown when all dives have been successfully imported")
        case .error(let message):
            return message
        }
    }
    
    private func isConnecting(to peripheral: CBPeripheral) -> Bool {
        // Match the connecting device by its unique identifier rather than its (non-unique) name
        guard case .connecting = syncState,
              let selectedDevice = selectedDevice else {
            return false
        }

        return peripheral.identifier == selectedDevice.identifier
    }
    
    // MARK: - Actions
    
    private func startScanning() {
        syncState = .scanning
        bleManager.startScanning(omitUnsupportedPeripherals: true)
        Self.logger.info("Starting Bluetooth scan")
    }
    
    private func stopScanning() {
        bleManager.stopScanning()
        Self.logger.info("Stopping Bluetooth scan")
    }
    
    /// Connects directly to a known device using its stored BLE UUID (no scanning required).
    private func connectToKnownDevice(_ device: DeviceFingerprint) {
        // Look up the StoredDevice by serial to find the BLE UUID.
        // If DeviceStorage was wiped (reinstall / UserDefaults reset) but
        // the DeviceFingerprint record has family+model, we cannot recover
        // the BLE UUID from the DB alone — fall back to scanning where
        // seedDeviceStorageFromDatabase will re-create the entry once the
        // peripheral is discovered.
        guard let allDevices = DeviceStorage.shared.getAllStoredDevices(),
              let storedDevice = allDevices.first(where: { $0.serial == device.serial }),
              let uuid = UUID(uuidString: storedDevice.uuid),
              let peripheral = bleManager.centralManager.retrievePeripherals(withIdentifiers: [uuid]).first else {
            Self.logger.warning("Could not retrieve peripheral for \(device.computerName) — falling back to scan")
            // Fall back to scanning; checkForTargetDevice will auto-connect
            targetDeviceSerial = device.serial
            targetDeviceName = device.computerName
            isSearching = true
            bleManager.clearDiscoveredPeripherals()
            startScanning()
            return
        }
        
        // Ensure DeviceStorage has the latest family/model from the DB
        seedDeviceStorageFromDatabase(for: peripheral, fingerprint: device)

        Self.logger.info("Directly connecting to known device: \(device.computerName) (serial: \(device.serial))")
        isSearching = true
        connectToDevice(peripheral)

        // Override the display name with the correct name from the fingerprint record.
        // connectToDevice re-resolves from the raw BLE advertisement name which may be
        // incorrect (e.g. "Oceanic Pro Plus X" instead of "Aqualung i300C").
        connectedDeviceName = device.computerName
        syncState = .connecting(deviceName: device.computerName)
    }
    
    /// Checks newly discovered peripherals for the target device and auto-connects (fallback path).
    private func checkForTargetDevice() {
        guard let serial = targetDeviceSerial,
              case .scanning = syncState else { return }
        
        for peripheral in bleManager.discoveredPeripherals {
            let uuid = peripheral.identifier.uuidString
            if let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: uuid),
               storedDevice.serial == serial {
                Self.logger.info("Found target device: \(peripheral.name ?? "Unknown") matching serial \(serial)")
                let savedName = targetDeviceName
                targetDeviceSerial = nil
                targetDeviceName = nil
                connectToDevice(peripheral)
                // Override name with the correct one from the fingerprint record
                if let name = savedName {
                    connectedDeviceName = name
                    syncState = .connecting(deviceName: name)
                }
                return
            }
            
            // DeviceStorage may be empty (reinstall). Try to match by BLE
            // advertisement name and seed DeviceStorage from the DB record
            // so that openBLEDevice gets the correct family/model.
            if DeviceStorage.shared.getStoredDevice(uuid: uuid) == nil {
                let predicate = #Predicate<DeviceFingerprint> { $0.serial == serial }
                if let record = try? modelContext.fetch(FetchDescriptor(predicate: predicate)).first,
                   record.family != nil, record.modelID != 0 {
                    // We can't verify serial over BLE before connecting, but the
                    // advertisement name should match the stored computerName.
                    let bleName = DeviceConfiguration.getDeviceDisplayName(from: peripheral.name ?? "")
                    let dbName = record.computerName
                    guard bleName == dbName || (peripheral.name ?? "").localizedCaseInsensitiveContains(dbName) else {
                        continue
                    }
                    seedDeviceStorageFromDatabase(for: peripheral, fingerprint: record)
                    Self.logger.info("Seeded DeviceStorage for scanned peripheral \(peripheral.name ?? "Unknown") from DB — connecting")
                    let savedName = targetDeviceName
                    targetDeviceSerial = nil
                    targetDeviceName = nil
                    connectToDevice(peripheral)
                    if let name = savedName {
                        connectedDeviceName = name
                        syncState = .connecting(deviceName: name)
                    }
                    return
                }
            }
        }
    }
    
    private func connectToDevice(_ peripheral: CBPeripheral) {
        guard !syncState.isActive || syncState == .scanning else { return }
        
        let deviceName = peripheral.name ?? "Unknown Device"
        let deviceAddress = peripheral.identifier.uuidString
        selectedDevice = peripheral
        // Use the model override name if set, then check DeviceStorage for a
        // previously saved correct model, otherwise resolve from the BLE name
        if let override = modelOverrides[deviceAddress] {
            connectedDeviceName = override.name
        } else if let stored = DeviceStorage.shared.getStoredDevice(uuid: deviceAddress),
                  let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.modelID == stored.model && $0.family == stored.family }) {
            connectedDeviceName = modelInfo.name
        } else {
            connectedDeviceName = DeviceConfiguration.getDeviceDisplayName(from: deviceName)
        }
        syncState = .connecting(deviceName: connectedDeviceName ?? deviceName)
        
        Self.logger.info("Attempting to connect to \(deviceName)")
        Self.logger.info("peripheral: \(peripheral)")
        
        #if DEBUG
        Logger.shared.shouldShowRawData = true
        #endif
        
        // Stop scanning
        stopScanning()
        
        // IMPORTANT: openBLEDevice is a blocking call that waits for CoreBluetooth
        // callbacks (e.g. didConnect). These callbacks are delivered on the main queue.
        // If we call openBLEDevice from the main queue, the callbacks can never be
        // processed and the connection times out.
        // We dispatch on a background thread to free the main RunLoop.
        DispatchQueue.global(qos: .userInitiated).async {
            let forcedModel: (family: DeviceConfiguration.DeviceFamily, model: UInt32)?
            if let override = self.modelOverrides[deviceAddress] {
                forcedModel = (family: override.family, model: override.modelID)
                Self.logger.info("Using user-selected model override: \(override.name)")
            } else {
                forcedModel = nil
            }
            
            let connected = DeviceConfiguration.openBLEDevice(
                name: deviceName,
                deviceAddress: deviceAddress,
                forcedModel: forcedModel
            )
            
            guard connected else {
                DispatchQueue.main.async {
                    Self.logger.error("Failed to connect to \(deviceName)")
                    self.syncState = .error(message: String(format: NSLocalizedString("Unable to connect to %@", bundle: Bundle.forAppLanguage(), comment: "Error message shown when a Bluetooth connection to a dive computer fails. %@ is the device name."), deviceName))
                    self.selectedDevice = nil
                }
                return
            }
            
            Self.logger.info("Connection established with \(deviceName)")
            
            // Set retrieving flag early to prevent auto-reconnect during the
            // handoff window between openBLEDevice returning and retrieveDiveLogs
            // actually starting. Without this, a disconnect during the polling
            // loop below would trigger auto-reconnect and create parallel connections.
            DispatchQueue.main.async {
                self.bleManager.isRetrievingLogs = true
                self.bleManager.currentRetrievalDevice = peripheral
            }
            
            // openBLEDevice assigns openedDeviceDataPtr via DispatchQueue.main.async
            // after returning true. We wait for the pointer to become available
            // rather than using a fixed delay.
            let timeoutSeconds = 5.0
            let pollInterval: TimeInterval = 0.05
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            
            while self.bleManager.openedDeviceDataPtr == nil && Date() < deadline {
                Thread.sleep(forTimeInterval: pollInterval)
            }
            
            DispatchQueue.main.async {
                guard self.bleManager.openedDeviceDataPtr != nil else {
                    Self.logger.error("Timeout: device pointer not available after \(timeoutSeconds)s")
                    self.syncState = .error(message: NSLocalizedString("Connection established but device not ready", bundle: Bundle.forAppLanguage(), comment: "Error message shown when the Bluetooth connection succeeded but the device pointer was not available in time."))
                    self.selectedDevice = nil
                    self.bleManager.close(clearDevicePtr: true)
                    return
                }
                self.retrieveDiveLogs(from: peripheral)
            }
        }
    }
    

    private func retrieveDiveLogs(from peripheral: CBPeripheral) {
        guard let devicePtr = bleManager.openedDeviceDataPtr else {
            Self.logger.error("Device pointer not available")
            syncState = .error(message: NSLocalizedString("Device not available", bundle: Bundle.forAppLanguage(), comment: "Error message shown when the dive computer device pointer is unavailable at the start of a download."))
            bleManager.close(clearDevicePtr: true)
            selectedDevice = nil
            return
        }
        
        syncState = .downloading(current: 0, total: 0)
        diveCountDuringDownload = 0
        
        let viewModel = DiveDataViewModel()

        // Subscribe to dive count updates — fired on every parsed dive regardless of
        // whether the device reports byte-level transfer progress.
        downloadProgressCancellable = viewModel.$progress
            .receive(on: DispatchQueue.main)
            .sink { progress in
                if case .inProgress(let count) = progress {
                    self.diveCountDuringDownload = count
                }
            }
        
        // If the user wants to re-download all dives, clear only the fingerprints for this device
        if downloadAllDives {
            Self.logger.info("'Download all dives' mode enabled — clearing fingerprints for current device")
            let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString)
            
            // Determine the device type the same way as DiveLogRetriever
            let deviceType: String
            if let stored = storedDevice,
               let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.modelID == stored.model && $0.family == stored.family }) {
                deviceType = modelInfo.name
            } else {
                deviceType = DeviceConfiguration.getDeviceDisplayName(from: peripheral.name ?? "Unknown")
            }
            
            // Use the hardware serial number (not the Bluetooth UUID)
            if let serial = storedDevice?.serial {
                Self.logger.info("Clearing fingerprint for \(deviceType) (serial: \(serial))")
                DeviceFingerprintStorage.shared.clearFingerprint(forDeviceType: deviceType, serial: serial)
            } else {
                // No hardware serial number stored — clear all fingerprints for this device type
                Self.logger.warning("No hardware serial number stored — clearing all fingerprints for \(deviceType)")
                DeviceFingerprintStorage.shared.clearFingerprintsForDeviceType(deviceType)
            }
        }
        
        bleManager.isRetrievingLogs = true
        bleManager.currentRetrievalDevice = peripheral

        // Always sync fingerprint from SwiftData before downloading.
        // UserDefaults is used as a session-level cache by the library; SwiftData is the
        // source of truth. This covers reinstalls, iCloud restores, and deleted dives.
        if !downloadAllDives {
            syncFingerprintFromDatabase(for: peripheral)
        }

        // Observe the number of downloaded dives via the viewModel
        // (onProgress reports transfer bytes, not dives)
        
        DiveLogRetriever.retrieveDiveLogs(
            from: devicePtr,
            device: peripheral,
            viewModel: viewModel,
            bluetoothManager: bleManager,
            syncClock: syncDeviceClock,
            onProgress: { current, total in
                DispatchQueue.main.async {
                    // current/total are libdivecomputer transfer bytes — used for the progress bar.
                    if total > 0 {
                        self.syncState = .downloading(current: current, total: total)
                    }
                }
            },
            completion: { success in
                // Note: completion is already called on the main thread by the library.
                // However, appendDives() in DiveDataViewModel uses a double
                // DispatchQueue.main.async, so viewModel.dives is not yet populated
                // at this point. We re-dispatch on the main thread to let the pending
                // blocks (append + finalizeDiveNumbering) execute before reading the dives.
                //
                // IMPORTANT: clearRetrievalState() must run AFTER close() — not before.
                // Clearing isRetrievingLogs before the BLE peripheral is disconnected
                // opens a window where the auto-reconnect logic fires on a transient
                // BLE disconnect event, re-opening the connection. close() then tears
                // down the old session while the new connection keeps the dive computer
                // stuck in "Sending Dive" mode.
                
                if success {
                    DispatchQueue.main.async {
                        Self.logger.info("Retrieval successful: \(viewModel.dives.count) dives")
                        
                        if viewModel.dives.isEmpty {
                            // No new dives, close the connection
                            self.bleManager.close(clearDevicePtr: true)
                            self.bleManager.clearRetrievalState()
                            self.selectedDevice = nil
                            self.syncState = .completed(imported: 0, merged: 0, skipped: 0)
                        } else {
                            self.downloadedDives = viewModel.dives
                            self.bleManager.close(clearDevicePtr: true)
                            self.bleManager.clearRetrievalState()
                            self.showingImportConfirmation = true
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        Self.logger.error("Failed to retrieve dives")
                        if case .failed(let msg) = viewModel.progress {
                            self.syncState = .error(message: String(format: NSLocalizedString("Download failed: %@", bundle: Bundle.forAppLanguage(), comment: "Error message shown when downloading dives from the dive computer fails. %@ is the underlying error description."), msg))
                        } else {
                            self.syncState = .error(message: NSLocalizedString("Failed to download dives", bundle: Bundle.forAppLanguage(), comment: "Error message shown when downloading dives from the dive computer fails with no specific reason."))
                        }
                        // Close the connection on failure
                        self.bleManager.close(clearDevicePtr: true)
                        self.bleManager.clearRetrievalState()
                        self.selectedDevice = nil
                    }
                }
            }
        )
    }
    
    // MARK: - Import Dives
    
    private func importDownloadedDives() {
        guard !downloadedDives.isEmpty else {
            syncState = .completed(imported: 0, merged: 0, skipped: 0)
            return
        }
        
        let total = downloadedDives.count
        syncState = .importing(count: total)
        
        Task { @MainActor in
            var importedCount = 0
            var mergedCount = 0
            var skippedCount = 0
            
            // Sort dives chronologically so we can calculate surface intervals
            let sortedDives = downloadedDives.sorted { $0.datetime < $1.datetime }
            
            // Find the highest dive number in the logbook so new dives continue the sequence
            let hasNumberPredicate = #Predicate<Dive> { dive in
                dive.diveNumber != nil
            }
            var maxNumberDescriptor = FetchDescriptor<Dive>(
                predicate: hasNumberPredicate,
                sortBy: [SortDescriptor(\Dive.diveNumber, order: .reverse)]
            )
            maxNumberDescriptor.fetchLimit = 1
            let highestDiveNumber = (try? modelContext.fetch(maxNumberDescriptor).first?.diveNumber) ?? 0
            var nextDiveNumber = highestDiveNumber + 1
            
            // Find the most recent existing dive before the first downloaded dive
            // to calculate the first dive's surface interval
            var previousDiveEndTime: Date? = nil
            if let firstDive = sortedDives.first {
                let beforeFirst = firstDive.datetime
                let predicate = #Predicate<Dive> { dive in
                    dive.timestamp < beforeFirst
                }
                var descriptor = FetchDescriptor<Dive>(
                    predicate: predicate,
                    sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
                )
                descriptor.fetchLimit = 1
                if let previousDive = try? modelContext.fetch(descriptor).first {
                    // End time = start time + duration (duration is in minutes)
                    previousDiveEndTime = previousDive.timestamp.addingTimeInterval(Double(previousDive.duration) * 60)
                }
            }
            
            for (index, diveData) in sortedDives.enumerated() {
                // Check if the dive already exists (by date and depth)
                let existingMatch = checkExistingDive(diveData)

                if let (existingDive, matchReason) = existingMatch {
                    if downloadAllDives {
                        // Re-download mode: merge data from the computer
                        mergeComputerData(from: diveData, into: existingDive, matchReason: matchReason)
                        mergedCount += 1
                    } else {
                        Self.logger.info("Dive from \(diveData.datetime) skipped — already in logbook (matched by: \(matchReason))")
                        skippedCount += 1
                    }
                } else {
                    let dive = convertToBlueDiveDive(diveData, diveNumber: nextDiveNumber, previousDiveEndTime: previousDiveEndTime)
                    modelContext.insert(dive)
                    nextDiveNumber += 1
                    importedCount += 1
                }

                // Update previous dive end time for the next iteration
                // divetime is in seconds
                previousDiveEndTime = diveData.datetime.addingTimeInterval(diveData.divetime)
                
                importProgress = Double(index + 1) / Double(total)
            }
            
            // Save the context
            do {
                try modelContext.save()
                Self.logger.info("Import complete: \(importedCount) imported, \(mergedCount) merged, \(skippedCount) skipped")
                persistFingerprintRecord(for: selectedDevice)
            } catch {
                Self.logger.error("Save error: \(error.localizedDescription)")
                downloadedDives = []
                selectedDevice = nil
                connectedDeviceName = nil
                syncState = .error(message: String(format: NSLocalizedString("Error saving: %@", bundle: Bundle.forAppLanguage(), comment: "Error message shown when saving dives to the logbook fails. %@ is the system error description."), error.localizedDescription))
                return
            }
            
            downloadedDives = []
            selectedDevice = nil
            connectedDeviceName = nil
            syncState = .completed(imported: importedCount, merged: mergedCount, skipped: skippedCount)
        }
    }
    
    /// Creates or updates the DeviceStorage (UserDefaults) entry for a peripheral from the
    /// persistent DeviceFingerprint record. Called before a sync so that family/model
    /// survive app reinstalls and UserDefaults resets. Also corrects a stale entry whose
    /// family/model disagrees with the DB (e.g. after a model override was saved).
    private func seedDeviceStorageFromDatabase(for peripheral: CBPeripheral, fingerprint device: DeviceFingerprint) {
        let uuid = peripheral.identifier.uuidString
        guard let family = device.family, device.modelID != 0 else { return }

        if let existing = DeviceStorage.shared.getStoredDevice(uuid: uuid) {
            guard existing.family != family || existing.model != device.modelID else { return }
            DeviceStorage.shared.storeDevice(
                uuid: uuid,
                name: device.computerName,
                family: family,
                model: device.modelID,
                serial: device.serial
            )
            Self.logger.info("Updated DeviceStorage from DB for \(device.computerName) (serial: \(device.serial)) — family/model corrected")
            return
        }

        DeviceStorage.shared.storeDevice(
            uuid: uuid,
            name: device.computerName,
            family: family,
            model: device.modelID,
            serial: device.serial
        )
        Self.logger.info("Seeded DeviceStorage from DB for \(device.computerName) (serial: \(device.serial))")
    }

    /// Seeds UserDefaults from the DeviceFingerprint record before downloading.
    /// UserDefaults is a session-level cache for LibDCSwift; DeviceFingerprint is the
    /// persistent source of truth (syncs via iCloud, survives reinstalls).
    private func syncFingerprintFromDatabase(for peripheral: CBPeripheral) {
        guard let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString),
              let serial = storedDevice.serial else { return }

        let deviceType: String
        if let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.modelID == storedDevice.model && $0.family == storedDevice.family }) {
            deviceType = modelInfo.name
        } else {
            deviceType = DeviceConfiguration.getDeviceDisplayName(from: peripheral.name ?? "Unknown")
        }

        let predicate = #Predicate<DeviceFingerprint> { record in record.serial == serial }
        let descriptor = FetchDescriptor<DeviceFingerprint>(predicate: predicate)

        if let record = try? modelContext.fetch(descriptor).first {
            DeviceFingerprintStorage.shared.saveFingerprint(record.fingerprintData, deviceType: deviceType, serial: serial)
            Self.logger.debug("Overwriting UserDefaults fingerprint for \(deviceType) (\(serial)) — DB has \(record.fingerprintData.count) bytes")
        } else {
            DeviceFingerprintStorage.shared.clearFingerprint(forDeviceType: deviceType, serial: serial)
            Self.logger.debug("No DB fingerprint for \(deviceType) (\(serial)) — clearing UserDefaults")
        }
    }

    /// Creates or updates the single DeviceFingerprint record for the connected device
    /// after a successful import.
    ///
    /// Identity update rules for existing records:
    /// - User override active this session → always write override name/family/model.
    /// - No override, record already has identity → preserve it (protects prior overrides
    ///   from being silently overwritten by auto-detection on reconnect).
    /// - No override, record has no identity yet → seed from auto-detected DeviceStorage.
    /// The fingerprint bytes are always updated.
    private func persistFingerprintRecord(for peripheral: CBPeripheral?) {
        guard let peripheral,
              let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString),
              let serial = storedDevice.serial else { return }

        // The fingerprint is always keyed by the library's auto-detected device type.
        let libraryDeviceType: String
        if let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.modelID == storedDevice.model && $0.family == storedDevice.family }) {
            libraryDeviceType = modelInfo.name
        } else {
            libraryDeviceType = DeviceConfiguration.getDeviceDisplayName(from: peripheral.name ?? "Unknown")
        }

        guard let fp = DeviceFingerprintStorage.shared.getFingerprint(forDeviceType: libraryDeviceType, serial: serial)?.fingerprint else { return }

        let predicate = #Predicate<DeviceFingerprint> { record in record.serial == serial }
        let descriptor = FetchDescriptor<DeviceFingerprint>(predicate: predicate)

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.fingerprintData = fp
            if let override = modelOverrides[peripheral.identifier.uuidString] {
                // Explicit user override this session — always apply it.
                existing.computerName = override.name
                existing.family = override.family
                existing.modelID = override.modelID
                Self.logger.info("Applied model override to DeviceFingerprint: \(override.name) (model \(override.modelID))")
            } else if existing.familyID.isEmpty || existing.modelID == 0 {
                // No prior identity — seed from auto-detection.
                existing.computerName = libraryDeviceType
                existing.family = storedDevice.family
                existing.modelID = storedDevice.model
            }
            // Otherwise: record already has an identity (possibly a prior override) — preserve it.
            existing.updatedAt = Date()
        } else {
            // Brand-new record — use override if active, otherwise auto-detected values.
            let dbName: String
            let dbFamily: DeviceConfiguration.DeviceFamily
            let dbModel: UInt32
            if let override = modelOverrides[peripheral.identifier.uuidString] {
                dbName = override.name
                dbFamily = override.family
                dbModel = override.modelID
                Self.logger.info("Applied model override to new DeviceFingerprint: \(override.name) (model \(override.modelID))")
            } else {
                dbName = libraryDeviceType
                dbFamily = storedDevice.family
                dbModel = storedDevice.model
            }
            modelContext.insert(DeviceFingerprint(
                serial: serial, computerName: dbName, fingerprintData: fp,
                family: dbFamily, model: dbModel
            ))
        }
        try? modelContext.save()
        Self.logger.info("Persisted DeviceFingerprint for \(serial)")
    }

    /// Deletes a known device: removes the DeviceFingerprint from SwiftData,
    /// clears the corresponding UserDefaults fingerprint cache, and removes the
    /// StoredDevice entry from DeviceStorage.
    private func deleteKnownDevice(_ device: DeviceFingerprint) {
        let serial = device.serial
        // Clear UserDefaults fingerprint cache (computerName matches the key used by DeviceFingerprintStorage)
        DeviceFingerprintStorage.shared.clearFingerprint(forDeviceType: device.computerName, serial: serial)
        // Remove the StoredDevice entry from DeviceStorage (keyed by BLE UUID)
        if let allDevices = DeviceStorage.shared.getAllStoredDevices(),
           let storedDevice = allDevices.first(where: { $0.serial == serial }) {
            DeviceStorage.shared.removeDevice(uuid: storedDevice.uuid)
            Self.logger.info("Removed DeviceStorage entry for \(device.computerName) (uuid: \(storedDevice.uuid))")
        }
        // Delete the SwiftData record
        clearAllDeviceFingerprintRecords(serial: serial)
        try? modelContext.save()
        Self.logger.info("Deleted known device: \(device.computerName) (\(serial))")
    }

    /// Deletes the DeviceFingerprint record for a serial (used by "Download all dives").
    private func clearAllDeviceFingerprintRecords(serial: String) {
        let predicate = #Predicate<DeviceFingerprint> { record in record.serial == serial }
        let descriptor = FetchDescriptor<DeviceFingerprint>(predicate: predicate)
        guard let records = try? modelContext.fetch(descriptor) else { return }
        records.forEach { modelContext.delete($0) }
        Self.logger.info("Cleared DeviceFingerprint record for serial \(serial)")
    }

    /// Checks if a dive already exists in the logbook.
    /// Matches by timestamp (±1 minute), max depth (±0.5), and fingerprint data record.
    /// Returns the matched dive and a human-readable reason for the match, or nil if no match.
    private func checkExistingDive(_ diveData: DiveData) -> (dive: Dive, reason: String)? {
        let timestamp = diveData.datetime
        let maxDepth = diveData.maxDepth

        // Get the current device's serial number
        let deviceSerial = selectedDevice.flatMap { peripheral in
            DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString)?.serial
        }

        // Look for a dive with the same date (within 1 minute) and similar depth
        let calendar = Calendar.current
        let startOfMinute = calendar.date(byAdding: .minute, value: -1, to: timestamp) ?? timestamp
        let endOfMinute = calendar.date(byAdding: .minute, value: 1, to: timestamp) ?? timestamp
        let depthLow = maxDepth - 0.5
        let depthHigh = maxDepth + 0.5

        let predicate = #Predicate<Dive> { dive in
            dive.timestamp >= startOfMinute &&
            dive.timestamp <= endOfMinute &&
            dive.maxDepth >= depthLow &&
            dive.maxDepth <= depthHigh
        }

        let descriptor = FetchDescriptor<Dive>(predicate: predicate)

        do {
            let results = try modelContext.fetch(descriptor)

            for existingDive in results {
                let fingerprintMatches = existingDive.fingerprintData != nil &&
                                         diveData.fingerprint != nil &&
                                         existingDive.fingerprintData == diveData.fingerprint
                let serialMatches = deviceSerial != nil &&
                                    existingDive.computerSerialNumber == deviceSerial
                // Dives with no device identity (e.g. file imports without serial/fingerprint)
                // are matched on timestamp+depth alone — it's the only signal available.
                // This prevents false duplicates when syncing dives previously imported via XML.
                // The two-diver protection still applies: a Bluetooth-imported dive always has
                // a serial, so noDeviceIdentity is false for it and the strict check applies.
                let noDeviceIdentity = existingDive.fingerprintData == nil &&
                                       (existingDive.computerSerialNumber == nil ||
                                        existingDive.computerSerialNumber?.isEmpty == true)

                if fingerprintMatches {
                    return (existingDive, "fingerprint")
                } else if serialMatches {
                    return (existingDive, "serial number")
                } else if noDeviceIdentity {
                    return (existingDive, "timestamp+depth (no device identity on existing dive)")
                }
            }

            if !results.isEmpty {
                Self.logger.debug("checkExistingDive: \(results.count) timestamp/depth match(es) rejected by identity check — inserting as new dive")
            }

            return nil
        } catch {
            Self.logger.error("Error searching for existing dive: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Merges dive computer data into an existing dive.
    /// Only fields originating from the computer are updated.
    /// User-modified fields (notes, rating, buddies, etc.) are preserved.
    private func mergeComputerData(from diveData: DiveData, into dive: Dive, matchReason: String) {
        // Dive statistics
        dive.maxDepth = diveData.maxDepth
        dive.averageDepth = diveData.avgDepth
        dive.duration = Int(diveData.divetime / 60)
        
        // Temperatures
        let profileTemperatures = diveData.profile.compactMap { $0.temperature }
        dive.waterTemperature = diveData.temperature
        dive.minTemperature = diveData.minTemperature ?? profileTemperatures.min() ?? diveData.temperature
        dive.maxTemperature = diveData.maxTemperature ?? profileTemperatures.max()
        if let surfaceTemp = diveData.surfaceTemperature {
            dive.airTemperature = surfaceTemp
        }
        
        // Build tanks with inline gas data from LibDCSwift
        // Preserve user-set fields (volume, workingPressure, tankType, tankMaterial)
        // that dive computers typically do not provide
        let dcGasMixes = diveData.gasMixes ?? []
        let existingTanks = dive.tanks
        
        if let dcTanks = diveData.tanks, !dcTanks.isEmpty {
            var tanks: [TankData] = []
            for (index, tank) in dcTanks.enumerated() {
                let mixIndex = tank.gasMix
                let o2: Double
                let he: Double
                if mixIndex >= 0 && mixIndex < dcGasMixes.count {
                    o2 = dcGasMixes[mixIndex].oxygen
                    he = dcGasMixes[mixIndex].helium
                } else if let firstMix = dcGasMixes.first {
                    o2 = firstMix.oxygen
                    he = firstMix.helium
                } else {
                    o2 = Double(diveData.gasMix ?? 21) / 100.0
                    he = 0.0
                }
                // Preserve user-set fields from existing tank at the same index
                let existing = index < existingTanks.count ? existingTanks[index] : nil
                // When the dive computer header reports no begin/end pressure (pressure pod scenario),
                // derive start and end pressure from the first/last non-zero profile sample.
                let profilePressures = (tank.beginPressure <= 0 || tank.endPressure <= 0)
                    ? Self.pressureRangeFromProfile(diveData.profile, tankIndex: index)
                    : (start: nil, end: nil)
                let startPressure = Self.resolvedPressure(header: tank.beginPressure, fallback: profilePressures.start)
                let endPressure   = Self.resolvedPressure(header: tank.endPressure,   fallback: profilePressures.end)
                tanks.append(TankData(
                    o2: o2, he: he,
                    volume: tank.volume > 0 ? tank.volume : existing?.volume,
                    startPressure: startPressure,
                    endPressure: endPressure,
                    workingPressure: tank.workingPressure > 0 ? tank.workingPressure : existing?.workingPressure,
                    tankMaterial: existing?.tankMaterial,
                    tankType: existing?.tankType
                ))
            }
            dive.tanks = tanks
        } else if !diveData.tankPressure.isEmpty {
            // Fallback: create a TankData from tank pressure samples
            let o2Fraction = Double(diveData.gasMix ?? 21) / 100.0
            let startP = diveData.tankPressure.first(where: { $0 > 0 })
            let endP   = diveData.tankPressure.last(where:  { $0 > 0 })
            let existing = existingTanks.first
            dive.tanks = [TankData(o2: o2Fraction, he: 0.0,
                                   volume: existing?.volume,
                                   startPressure: startP, endPressure: endP,
                                   workingPressure: existing?.workingPressure,
                                   tankMaterial: existing?.tankMaterial, tankType: existing?.tankType)]
        } else if !dcGasMixes.isEmpty {
            // No tank data but we have gas mixes — store them as tanks with gas only
            let needsFilter = filterUnusedTanks && (connectedDeviceFamily.map { Self.familiesNeedingSwiftTankFilter.contains($0) } ?? true)
            let usedMixes = needsFilter ? Self.usedGasMixIndices(from: diveData) : nil
            var existingIdx = 0
            dive.tanks = dcGasMixes.enumerated().compactMap { (index, mix) in
                if let used = usedMixes {
                    guard used.contains(index) else { return nil }
                }
                let existing = existingIdx < existingTanks.count ? existingTanks[existingIdx] : nil
                existingIdx += 1
                return TankData(o2: mix.oxygen, he: mix.helium,
                                volume: existing?.volume, workingPressure: existing?.workingPressure,
                                tankMaterial: existing?.tankMaterial, tankType: existing?.tankType)
            }
        } else if let gasMix = diveData.gasMix, gasMix != 21 {
            // Single non-Air gas from dive computer
            let existing = existingTanks.first
            dive.tanks = [TankData(o2: Double(gasMix) / 100.0, he: 0.0,
                                   volume: existing?.volume, workingPressure: existing?.workingPressure,
                                   tankMaterial: existing?.tankMaterial, tankType: existing?.tankType)]
        }
        
        // Decompression
        if let decoModel = diveData.decoModel {
            dive.decompressionAlgorithm = decoModel.description
        }
        dive.cnsPercentage = diveData.cns ?? diveData.profile.last(where: { $0.cns != nil })?.cns
        // DC_DECO_DECOSTOP = 2: only mandatory decompression stops count
        let hadDecoObligation = (diveData.decoStop?.type == 2)
            || diveData.profile.contains { $0.decoStop != nil }
            || diveData.profile.contains { $0.events.contains(.decoStop) }
        dive.isDecompressionDive = hadDecoObligation
        
        // Dive profile (always update with fresh data, merge event-only points)
        dive.profileSamples = Self.consolidateProfilePoints(diveData.profile)
        
        // Computer name — prefer full brand+model name from supportedModels lookup
        if let peripheral = selectedDevice,
           let stored = DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString),
           let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.modelID == stored.model && $0.family == stored.family }) {
            dive.computerName = modelInfo.name
        } else if let name = connectedDeviceName {
            dive.computerName = name
        }

        // Raw dive computer data
        dive.rawDiveComputerData = diveData.rawData
        dive.fingerprintData = diveData.fingerprint

        // Water type from salinity (g/cm³): ~1.0 = Fresh, ~1.025 = Salt
        if let sal = diveData.salinity {
            if sal < 1.01 {
                dive.siteWaterType = "Freshwater"
            } else if sal == 1.02 {
                dive.siteWaterType = "EN13319"
            } else {
                dive.siteWaterType = "Saltwater"
            }

}
        
        // Decompression stops
        dive.decoStops = diveData.decoStop.map { stop in
            [DecoStop(depth: stop.depth, time: stop.time, type: stop.type)]
        } ?? []

        // Extract exit GPS from Shearwater raw data (PNF closing record 9)
        if let rawData = diveData.rawData,
           let exitGPS = ShearwaterPNFGPS.extractExitGPS(from: rawData) {
            dive.exitLatitude = exitGPS.latitude
            dive.exitLongitude = exitGPS.longitude
        }

        // Override source import to reflect the Bluetooth re-download
        dive.sourceImport = "Bluetooth"

        Self.logger.info("Dive from \(dive.timestamp) merged with computer data (matched by: \(matchReason))")
    }
    
    /// Determines gas type name from oxygen and helium percentages, matching
    /// the logic used by the XML import path in ContentView.
    private func determineGasName(oxygen: Int, helium: Int) -> String {
        if helium > 0 {
            return "Trimix"
        } else if oxygen > 21 {
            return "Nitrox"
        } else {
            return "Air"
        }
    }
    
    // MARK: - Unused Tank Filtering
    //
    // PURPOSE
    // -------
    // Some dive computer families report ALL configured gas mix slots as tanks,
    // even when only one gas was actually breathed during the dive.  For example
    // the Aqualung i300C always reports 3 gas slots regardless of usage, creating
    // 2 phantom "tanks" with no pressure data.  This filter removes those phantom
    // entries so only tanks that were actually used appear in the dive log.
    //
    // AFFECTED BRANDS (no C-level filtering in libdivecomputer)
    // ---------------------------------------------------------
    // - Oceanic Atom2:  Aqualung i300C, i200C, i770R, i550C, Oceanic Geo/Veo,
    //                   Sherwood Sage/Wisdom — reports 3–6 configured gas slots
    // - Pelagic I330R:  Aqualung i330R, Apeks DSX — same Oceanic-derived protocol
    // - HW OSTC3:       Heinrichs Weikamp OSTC 2/3/4/Sport — reports 3–5 mixes
    // - Cressi Goa:     Cressi Goa, Cartesio, Leonardo 2.0, Donatello
    // - DeepSix:        DeepSix Excursion
    // - Deepblu:        Deepblu Cosmiq+
    // - Oceans:         Oceans S1
    // - McLean:         McLean Extreme
    //
    // NOT AFFECTED (C-level parser already filters unused tanks)
    // ----------------------------------------------------------
    // Shearwater, Suunto, Scubapro/Uwatec, Mares, Divesoft, DiveSystem/Ratio
    // — these parsers only report tanks that are active/enabled with pressure
    //   data.  No Swift-side filtering is applied; data passes through as-is.
    //
    // LOGIC
    // -----
    // 1. Only runs when the "Filter unused tanks" toggle is ON (default: false)
    //    AND the connected device family is in familiesNeedingSwiftTankFilter.
    // 2. Determines which gas mix indices were actually used during the dive by:
    //    a) Scanning profile samples for DC_SAMPLE_GASMIX events (gas switches)
    //    b) Checking the header-level gasMix field (last-used gas index)
    //    c) Falling back to {0} (primary gas) if no evidence is found
    // 3. In the gas-mixes-only tank-building path (Path 3), only gas mixes whose
    //    index is in the used set are converted to TankData objects.
    // 4. The toggle is only visible in the UI when the connected (or previously
    //    paired) device belongs to an affected family.
    //
    // USER OVERRIDE
    // -------------
    // A diver carrying a configured-but-unused tank (e.g. pony bottle, bailout)
    // can turn off the toggle to import all configured gas slots as tanks.
    // The setting persists via @AppStorage("filterUnusedTanks").

    /// Families whose libdivecomputer parser does NOT filter unused tanks/gas mixes
    /// at the C level.  Only these need the Swift-side usedGasMixIndices filter.
    private static let familiesNeedingSwiftTankFilter: Set<DeviceConfiguration.DeviceFamily> = [
        .oceanicAtom2,   // Reports all configured gas slots (3–6)
        .pelagicI330R,   // Same Oceanic-derived protocol
        .hwOstc3,        // Reports all 3–5 configured mixes, no DC_FIELD_TANK
        .cressiGoa,      // No DC_FIELD_TANK
        .deepsixExcursion,
        .deepbluCosmiq,
        .oceansS1,
        .mcleanExtreme,
    ]

    /// Returns the DeviceFamily of the currently connected device, if known.
    private var connectedDeviceFamily: DeviceConfiguration.DeviceFamily? {
        guard let peripheral = selectedDevice,
              let stored = DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString) else {
            return nil
        }
        return stored.family
    }

    /// Returns the set of gas mix indices that were actually used during the dive.
    /// Checks profile gas-switch samples and the header-level gas mix.
    /// Falls back to {0} when no usage evidence is found (single-gas dive).
    private static func usedGasMixIndices(from diveData: DiveData) -> Set<Int> {
        var indices = Set(diveData.profile.compactMap { $0.currentGas })
        // Include the header-level gas mix (last-used gas) when available
        if let headerGas = diveData.gasMix { indices.insert(headerGas) }
        // If no evidence found, assume the primary gas (index 0) was used
        if indices.isEmpty { indices.insert(0) }
        return indices
    }

    /// Scans profile samples for the first and last non-zero pressure reading for a given tank index.
    /// Used when the dive computer header reports no begin/end pressure (e.g. pressure pod scenario).
    private static func pressureRangeFromProfile(
        _ profile: [LibDCSwift.DiveProfilePoint],
        tankIndex: Int
    ) -> (start: Double?, end: Double?) {
        let readings = profile.compactMap { point -> Double? in
            let p = point.pressures[tankIndex] ?? (tankIndex == 0 ? point.pressure : nil)
            return (p ?? 0) > 0 ? p : nil
        }
        return (readings.first, readings.last)
    }

    /// Returns the header pressure when reported (> 0), otherwise falls back to a profile-derived value.
    private static func resolvedPressure(header: Double, fallback: Double?) -> Double? {
        header > 0 ? header : fallback
    }

    /// Converts a LibDCSwift DiveEvent to a BlueDive DiveProfileEvent
    private static func convertDiveEvent(_ event: LibDCSwift.DiveEvent) -> DiveProfileEvent {
        switch event {
        case .ascent:
            return .ascent
        case .violation:
            return .violation
        case .decoStop:
            return .decoStop
        case .gasChange:
            return .gasChange
        case .bookmark:
            return .bookmark
        case .safetyStop(let mandatory):
            return .safetyStop(mandatory)
        case .ceiling:
            return .ceiling
        case .po2:
            return .po2
        case .deepStop:
            return .deepStop
        }
    }
    
    /// Consolidates LibDCSwift profile points by merging event-only points into their
    /// corresponding time-based points, and synthesising events from DC_SAMPLE_DECO data.
    ///
    /// Events are only added when the dive computer explicitly reports them via DC_SAMPLE_EVENT
    /// or when a mandatory deco obligation is present (decoStop depth set for DC_DECO_DECOSTOP).
    /// NDL=0 alone does not generate a synthetic event.
    private static func consolidateProfilePoints(
        _ profile: [LibDCSwift.DiveProfilePoint]
    ) -> [DiveProfilePoint] {
        // Group all points by their timestamp (seconds)
        var pointsByTime: [(time: TimeInterval, points: [LibDCSwift.DiveProfilePoint])] = []
        var lastTime: TimeInterval?
        
        for point in profile {
            if point.time == lastTime, !pointsByTime.isEmpty {
                pointsByTime[pointsByTime.count - 1].points.append(point)
            } else {
                pointsByTime.append((time: point.time, points: [point]))
                lastTime = point.time
            }
        }
        
        var result: [DiveProfilePoint] = []
        
        for group in pointsByTime {
            // Use the first point as the base (the DC_SAMPLE_TIME point)
            let base = group.points[0]
            // Collect explicit events from all points at this timestamp
            var allEvents: [DiveProfileEvent] = group.points.flatMap { $0.events }.map { convertDiveEvent($0) }
            
            // Synthesize a decoStop event from DC_SAMPLE_DECO data when the dive computer
            // reports a mandatory deco obligation (decoStop depth is only set for DC_DECO_DECOSTOP).
            // NDL=0 alone does not imply a deco obligation and must not generate a synthetic event.
            if base.decoStop != nil {
                // Mandatory deco stop (decoStop depth is only set for DC_DECO_DECOSTOP)
                if !allEvents.contains(.decoStop) {
                    allEvents.append(.decoStop)
                }
            }
            
            let perTank: [Int: Double]? = base.pressures.isEmpty ? nil : base.pressures
            // Derive tankPressure from per-tank dict when available:
            // prefer tank 0 (primary), then lowest-index tank, then legacy single value
            let primaryPressure: Double? = perTank.flatMap { dict in
                dict[0] ?? dict.min(by: { $0.key < $1.key })?.value
            } ?? base.pressure

            result.append(DiveProfilePoint(
                time: base.time / 60.0, // LibDCSwift uses seconds, BlueDive uses minutes
                depth: base.depth,
                temperature: base.temperature,
                tankPressure: primaryPressure,
                tankPressures: perTank,
                ndl: base.ndl.map { Double($0) / 60.0 }, // Seconds to minutes
                ppo2: base.po2,
                events: allEvents
            ))
        }
        
        return result
    }
    
    /// Converts a LibDCSwift DiveData to a BlueDive Dive
    private func convertToBlueDiveDive(_ diveData: DiveData, diveNumber: Int, previousDiveEndTime: Date?) -> Dive {
        // Convert the dive profile, merging event-only points into time-based points
        let profileSamples = Self.consolidateProfilePoints(diveData.profile)
        
        // Calculate average depth from profile (time-weighted average)
        let averageDepth: Double = diveData.avgDepth
        
        // Extract min/max temperatures from the profile
        let profileTemperatures = diveData.profile.compactMap { $0.temperature }
        let minTemperature: Double = diveData.minTemperature ?? profileTemperatures.min() ?? diveData.temperature
        let maxTemperature: Double? = diveData.maxTemperature ?? profileTemperatures.max()
        
        // Build tanks with inline gas data from LibDCSwift
        let dcGasMixes = diveData.gasMixes ?? []
        var linkedTanks: [TankData] = []
        
        if let dcTanks = diveData.tanks, !dcTanks.isEmpty {
            for (index, tank) in dcTanks.enumerated() {
                let mixIndex = tank.gasMix
                let o2: Double
                let he: Double
                if mixIndex >= 0 && mixIndex < dcGasMixes.count {
                    o2 = dcGasMixes[mixIndex].oxygen
                    he = dcGasMixes[mixIndex].helium
                } else if let firstMix = dcGasMixes.first {
                    o2 = firstMix.oxygen
                    he = firstMix.helium
                } else {
                    o2 = Double(diveData.gasMix ?? 21) / 100.0
                    he = 0.0
                }
                // When the dive computer header reports no begin/end pressure (pressure pod scenario),
                // derive start and end pressure from the first/last non-zero profile sample.
                let profilePressures = (tank.beginPressure <= 0 || tank.endPressure <= 0)
                    ? Self.pressureRangeFromProfile(diveData.profile, tankIndex: index)
                    : (start: nil, end: nil)
                let startPressure = Self.resolvedPressure(header: tank.beginPressure, fallback: profilePressures.start)
                let endPressure   = Self.resolvedPressure(header: tank.endPressure,   fallback: profilePressures.end)
                linkedTanks.append(TankData(
                    o2: o2, he: he,
                    volume: tank.volume > 0 ? tank.volume : nil,
                    startPressure: startPressure,
                    endPressure: endPressure,
                    workingPressure: tank.workingPressure > 0 ? tank.workingPressure : nil
                ))
            }
        } else if !diveData.tankPressure.isEmpty {
            let o2Fraction = Double(diveData.gasMix ?? 21) / 100.0
            let startP = diveData.tankPressure.first(where: { $0 > 0 })
            let endP   = diveData.tankPressure.last(where:  { $0 > 0 })
            linkedTanks.append(TankData(o2: o2Fraction, he: 0.0, startPressure: startP, endPressure: endP))
        } else if !dcGasMixes.isEmpty {
            let needsFilter = filterUnusedTanks && (connectedDeviceFamily.map { Self.familiesNeedingSwiftTankFilter.contains($0) } ?? true)
            let usedMixes = needsFilter ? Self.usedGasMixIndices(from: diveData) : nil
            linkedTanks = dcGasMixes.enumerated().compactMap { (index, mix) in
                if let used = usedMixes {
                    guard used.contains(index) else { return nil }
                }
                return TankData(o2: mix.oxygen, he: mix.helium)
            }
        } else {
            let o2Fraction = Double(diveData.gasMix ?? 21) / 100.0
            linkedTanks.append(TankData(o2: o2Fraction, he: 0.0))
        }
        
        // Dive mode
        let diveType: String
        if let diveMode = diveData.diveMode {
            switch diveMode {
            case .freedive:
                diveType = "Freediving"
            case .gauge:
                diveType = "Gauge"
            case .openCircuit:
                diveType = "Open Circuit"
            case .closedCircuit:
                diveType = "Rebreather"
            case .semiClosedCircuit:
                diveType = "Semi-Rebreather"
            }
        } else {
            diveType = "Reef"
        }
        
        // Decompression model
        let decompressionAlgorithm: String?
        if let decoModel = diveData.decoModel {
            decompressionAlgorithm = decoModel.description
        } else {
            decompressionAlgorithm = nil
        }
        
        // Mandatory decompression dive?
        // DC_DECO_DECOSTOP = 2: only mandatory decompression stops count
        // diveData.decoStop is always non-nil when the computer reports deco samples,
        // even for NDL dives (type 0), so we must check the type field.
        let isDecompressionDive = (diveData.decoStop?.type == 2)
            || diveData.profile.contains { $0.decoStop != nil }
            || diveData.profile.contains { $0.events.contains(.decoStop) }
        
        // Water type from salinity (g/cm³): ~1.0 = Fresh, ~1.025 = Salt
        let waterType: String? = diveData.salinity.map { sal in
            if sal < 1.01 { "Freshwater" }
            else if sal == 1.02 { "EN13319" }
            else { "Saltwater" }
        }
        
        // Location GPS
        let latitude: Double?
        let longitude: Double?
        let altitude: Double?
        if let location = diveData.location {
            latitude = location.latitude
            longitude = location.longitude
            altitude = location.altitude
        } else {
            latitude = nil
            longitude = nil
            altitude = nil
        }
        
        // CNS: use top-level value, or last profile sample with CNS data
        let cnsValue: Double? = diveData.cns ?? diveData.profile.last(where: { $0.cns != nil })?.cns
        
        // Calculate surface interval from previous dive end time
        let surfaceIntervalString: String
        var isRepetitiveDive = false
        if let previousEnd = previousDiveEndTime {
            let intervalSeconds = diveData.datetime.timeIntervalSince(previousEnd)
            if intervalSeconds > 0 {
                let totalMinutes = Int(intervalSeconds / 60)
                let days    = totalMinutes / 1440
                let hours   = (totalMinutes % 1440) / 60
                let minutes = totalMinutes % 60
                
                if days > 0 {
                    surfaceIntervalString = "\(days)d \(hours)h \(String(format: "%02d", minutes))m"
                } else {
                    surfaceIntervalString = "\(hours)h \(String(format: "%02d", minutes))m"
                }
                
                // A dive is repetitive if the surface interval is less than 24 hours (1440 minutes)
                isRepetitiveDive = totalMinutes < 1440
            } else {
                surfaceIntervalString = "0h 00m"
            }
        } else {
            surfaceIntervalString = "0h 00m"
        }
        
        // Create the dive
        let dive = Dive(
            diveNumber: diveNumber,
            timestamp: diveData.datetime,
            location: "",
            siteName: "",
            diveTypes: diveType,
            computerName: selectedDevice.flatMap { DeviceStorage.shared.getStoredDevice(uuid: $0.identifier.uuidString) }.flatMap { stored in DeviceConfiguration.supportedModels.first(where: { $0.modelID == stored.model && $0.family == stored.family })?.name } ?? connectedDeviceName ?? NSLocalizedString("dive.computer.default_ble_name",
                                                                    comment: "Fallback name for an unknown Bluetooth dive computer"),
            computerSerialNumber: selectedDevice.flatMap { DeviceStorage.shared.getStoredDevice(uuid: $0.identifier.uuidString)?.serial },
            surfaceInterval: surfaceIntervalString,
            diverName: UserDefaults.standard.string(forKey: "userName") ?? "",
            buddies: "",
            rating: 0,
            isRepetitiveDive: isRepetitiveDive,
            maxDepth: diveData.maxDepth,
            averageDepth: averageDepth,
            duration: Int(diveData.divetime / 60), // LibDCSwift uses seconds
            waterTemperature: diveData.temperature,
            minTemperature: minTemperature,
            airTemperature: diveData.surfaceTemperature,
            maxTemperature: maxTemperature,
            decompressionAlgorithm: decompressionAlgorithm,
            cnsPercentage: cnsValue,
            isDecompressionDive: isDecompressionDive,
            notes: "",
            importDistanceUnit: "meters",
            importTemperatureUnit: "°c",
            importPressureUnit: "bar",
            importVolumeUnit: "liters",
            importWeightUnit: (WeightUnit(rawValue: UserDefaults.standard.string(forKey: "weightUnit") ?? "kilograms") ?? .kilograms).symbol,
            sourceImport: "Bluetooth",
            siteWaterType: waterType,
            siteAltitude: altitude,
            siteLatitude: latitude,
            siteLongitude: longitude,
            profileSamples: profileSamples
        )
        
        dive.tanks = linkedTanks
        dive.rawDiveComputerData = diveData.rawData
        dive.fingerprintData = diveData.fingerprint
        dive.decoStops = diveData.decoStop.map { stop in
            [DecoStop(depth: stop.depth, time: stop.time, type: stop.type)]
        } ?? []

        // Extract exit GPS from Shearwater raw data (PNF closing record 9)
        if let rawData = diveData.rawData,
           let exitGPS = ShearwaterPNFGPS.extractExitGPS(from: rawData) {
            dive.exitLatitude = exitGPS.latitude
            dive.exitLongitude = exitGPS.longitude
        }

        return dive
    }
}

// MARK: - Device Row

private struct DeviceRow: View {
    let peripheral: CBPeripheral
    let isSelected: Bool
    let isConnecting: Bool
    let modelOverride: DeviceConfiguration.ComputerModel?
    let onTap: () -> Void
    let onChangeModel: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Device icon
            ZStack {
                Circle()
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                    .frame(width: 44, height: 44)
                
                Image(systemName: deviceIcon)
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            
            // Device information
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(deviceDisplayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    if modelOverride != nil {
                        Text(autoDetectedName)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    
                    if let serial = DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString)?.serial {
                        Text(verbatim: String(format: NSLocalizedString("Serial: %@", bundle: Bundle.forAppLanguage(), comment: "A subheading displaying the serial number of a device. The argument is the serial number of the device."), serial.uppercased()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(peripheral.identifier.uuidString.prefix(8) + "...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            // Change model button
            Button(action: onChangeModel) {
                Image(systemName: modelOverride != nil ? "pencil.circle.fill" : "info.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(modelOverride != nil ? Color.orange : Color.secondary)
            }
            .buttonStyle(.plain)
            
            // Connection indicator
            if isConnecting {
                ProgressView()
                    .controlSize(.small)
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contextMenu {
            Button {
                onChangeModel()
            } label: {
                Label("Change Model", systemImage: "pencil")
            }
        }
    }
    
    private var deviceDisplayName: String {
        if let override = modelOverride {
            return override.name
        }
        // Check DeviceStorage for a previously saved correct model
        if let stored = DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString),
           let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.modelID == stored.model && $0.family == stored.family }) {
            return modelInfo.name
        }
        guard let name = peripheral.name else {
            return "Unknown Device"
        }
        return DeviceConfiguration.getDeviceDisplayName(from: name)
    }
    
    private var autoDetectedName: String {
        let detected = DeviceConfiguration.getDeviceDisplayName(from: peripheral.name ?? "Unknown")
        return "Detected: \(detected)"
    }
    
    private var deviceIcon: String {
        guard let name = peripheral.name?.lowercased() else {
            return "gauge.with.dots.needle.bottom.50percent"
        }
        
        // Custom icons by manufacturer
        if name.contains("shearwater") {
            return "gauge.with.dots.needle.bottom.50percent.badge.plus"
        } else if name.contains("suunto") {
            return "dial.medium"
        } else if name.contains("garmin") {
            return "applewatch.watchface"
        } else if name.contains("mares") {
            return "gauge.with.needle"
        } else if name.contains("scubapro") {
            return "gauge.with.dots.needle.33percent"
        } else if name.contains("oceanic") || name.contains("pelagic") {
            return "water.waves"
        } else {
            return "gauge.with.dots.needle.bottom.50percent"
        }
    }
}

// MARK: - Known Device Row

private struct KnownDeviceRow: View {
    let computerName: String
    let serial: String
    let lastSynced: Date
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: deviceIcon)
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(computerName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    Text(verbatim: String(format: NSLocalizedString("Serial: %@", bundle: Bundle.forAppLanguage(), comment: "A subheading displaying the serial number of a device. The argument is the serial number of the device."), serial.uppercased()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text("Last synced \(lastSynced, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private var deviceIcon: String {
        let name = computerName.lowercased()
        if name.contains("shearwater") {
            return "gauge.with.dots.needle.bottom.50percent.badge.plus"
        } else if name.contains("suunto") {
            return "dial.medium"
        } else if name.contains("garmin") {
            return "applewatch.watchface"
        } else if name.contains("mares") {
            return "gauge.with.needle"
        } else if name.contains("scubapro") {
            return "gauge.with.dots.needle.33percent"
        } else if name.contains("oceanic") || name.contains("pelagic") {
            return "water.waves"
        } else {
            return "gauge.with.dots.needle.bottom.50percent"
        }
    }
}

// MARK: - Model Picker Sheet

private struct ModelPickerSheet: View {
    let detectedName: String
    let currentOverride: DeviceConfiguration.ComputerModel?
    let onSelect: (DeviceConfiguration.ComputerModel?) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    
    private var groupedModels: [(brand: String, models: [DeviceConfiguration.ComputerModel])] {
        let models = DeviceConfiguration.supportedModels.filter { model in
            searchText.isEmpty || model.name.localizedCaseInsensitiveContains(searchText)
        }
        
        let grouped = Dictionary(grouping: models) { model -> String in
            // Extract brand from model name (first word, or first two for "Deep Six", "Heinrichs Weikamp")
            let parts = model.name.split(separator: " ")
            if parts.count >= 2 {
                let twoWord = "\(parts[0]) \(parts[1])"
                if ["Deep Six", "Heinrichs Weikamp"].contains(twoWord) {
                    return twoWord
                }
            }
            return String(parts.first ?? "Other")
        }
        
        return grouped
            .sorted { $0.key < $1.key }
            .map { (brand: $0.key, models: $0.value.sorted { $0.name < $1.name }) }
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onSelect(nil)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto-detect")
                                    .foregroundStyle(.primary)
                                Text(detectedName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if currentOverride == nil {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                } header: {
                    Text("Detected Model")
                } footer: {
                    Text("If the detected model is incorrect, select the correct one below.")
                }
                
                ForEach(groupedModels, id: \.brand) { group in
                    Section(group.brand) {
                        ForEach(group.models) { model in
                            Button {
                                onSelect(model)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(model.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if currentOverride == model {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search models")
            .navigationTitle("Select Model")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    BluetoothScannerView()
        .modelContainer(for: Dive.self, inMemory: true)
}
