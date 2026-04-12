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
    @State private var diveCountDuringDownload: Int = 0
    @State private var downloadProgressCancellable: AnyCancellable?
    @State private var isSearching: Bool = false
    @State private var targetDeviceSerial: String?
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
                        Text("\(diveCountDuringDownload - 1) dive(s) downloaded")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Downloading...")
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
        default:
            deviceListView
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
        switch syncState {
        case .idle: return isSearching ? "Ready" : "Sync"
        case .scanning: return targetDeviceSerial != nil ? "Searching..." : "Searching..."
        case .connecting(let name): return "Connecting to \(name)"
        case .downloading: return "Downloading..."
        case .importing(let count): return "Importing \(count) dives..."
        case .completed(let imported, let merged, _):
            return (imported + merged) > 0 ? "Sync Complete" : "No New Dives"
        case .error: return "Error"
        }
    }
    
    private var syncStateSubtitle: LocalizedStringKey {
        switch syncState {
        case .idle:
            return isSearching ? "Select a device to begin" : "Select a dive computer to sync"
        case .scanning:
            return targetDeviceSerial != nil ? "Looking for your dive computer..." : "Searching for Bluetooth dive computers..."
        case .connecting:
            return "Establishing connection..."
        case .downloading:
            if diveCountDuringDownload > 0 {
                return "Downloading dive \(diveCountDuringDownload)..."
            }
            return "Reading dive computer..."
        case .importing:
            return "Saving to logbook..."
        case .completed(let imported, let merged, let skipped):
            if imported == 0 && merged == 0 && skipped == 0 {
                return "Your logbook is up to date"
            } else if merged > 0 && imported == 0 {
                return "\(merged) dive(s) updated"
            } else if skipped > 0 {
                return "\(skipped) dive(s) already present"
            }
            return "All dives have been imported"
        case .error(let message):
            return "\(message)"
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
        // Look up the StoredDevice by serial to find the BLE UUID
        guard let allDevices = DeviceStorage.shared.getAllStoredDevices(),
              let storedDevice = allDevices.first(where: { $0.serial == device.serial }),
              let uuid = UUID(uuidString: storedDevice.uuid),
              let peripheral = bleManager.centralManager.retrievePeripherals(withIdentifiers: [uuid]).first else {
            Self.logger.warning("Could not retrieve peripheral for \(device.computerName) — falling back to scan")
            // Fall back to scanning if direct retrieval fails
            targetDeviceSerial = device.serial
            isSearching = true
            bleManager.clearDiscoveredPeripherals()
            startScanning()
            return
        }
        
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
            if let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString),
               storedDevice.serial == serial {
                Self.logger.info("Found target device: \(peripheral.name ?? "Unknown") matching serial \(serial)")
                targetDeviceSerial = nil
                connectToDevice(peripheral)
                return
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
                    self.syncState = .error(message: "Unable to connect to \(deviceName)")
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
                    self.syncState = .error(message: "Connection established but device not ready")
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
            syncState = .error(message: "Device not available")
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
                clearAllDeviceFingerprintRecords(serial: serial)
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
                self.bleManager.clearRetrievalState()
                
                if success {
                    DispatchQueue.main.async {
                        Self.logger.info("Retrieval successful: \(viewModel.dives.count) dives")
                        
                        if viewModel.dives.isEmpty {
                            // No new dives, close the connection
                            self.bleManager.close(clearDevicePtr: true)
                            self.selectedDevice = nil
                            self.syncState = .completed(imported: 0, merged: 0, skipped: 0)
                        } else {
                            self.downloadedDives = viewModel.dives
                            // Don't close the connection until the import is complete
                            self.bleManager.close(clearDevicePtr: true)
                            self.showingImportConfirmation = true
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        Self.logger.error("Failed to retrieve dives")
                        if case .failed(let msg) = viewModel.progress {
                            self.syncState = .error(message: "Download failed: \(msg)")
                        } else {
                            self.syncState = .error(message: "Failed to download dives")
                        }
                        // Close the connection on failure
                        self.bleManager.close(clearDevicePtr: true)
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
                let existingDive = checkExistingDive(diveData)
                
                if let existingDive = existingDive {
                    if downloadAllDives {
                        // Re-download mode: merge data from the computer
                        mergeComputerData(from: diveData, into: existingDive)
                        mergedCount += 1
                    } else {
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
                syncState = .error(message: "Error saving: \(error.localizedDescription)")
                return
            }
            
            downloadedDives = []
            selectedDevice = nil
            connectedDeviceName = nil
            syncState = .completed(imported: importedCount, merged: mergedCount, skipped: skippedCount)
        }
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
            Self.logger.info("Synced fingerprint from DeviceFingerprint for \(deviceType) (\(serial))")
        } else {
            DeviceFingerprintStorage.shared.clearFingerprint(forDeviceType: deviceType, serial: serial)
            Self.logger.info("No DeviceFingerprint for \(deviceType) (\(serial)) — cleared UserDefaults")
        }
    }

    /// Creates or updates the single DeviceFingerprint record for the connected device
    /// after a successful import, mirroring whatever UserDefaults now holds.
    private func persistFingerprintRecord(for peripheral: CBPeripheral?) {
        guard let peripheral,
              let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString),
              let serial = storedDevice.serial else { return }

        let deviceType: String
        if let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.modelID == storedDevice.model && $0.family == storedDevice.family }) {
            deviceType = modelInfo.name
        } else {
            deviceType = DeviceConfiguration.getDeviceDisplayName(from: peripheral.name ?? "Unknown")
        }

        guard let fp = DeviceFingerprintStorage.shared.getFingerprint(forDeviceType: deviceType, serial: serial)?.fingerprint else { return }

        let predicate = #Predicate<DeviceFingerprint> { record in record.serial == serial }
        let descriptor = FetchDescriptor<DeviceFingerprint>(predicate: predicate)

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.fingerprintData = fp
            existing.computerName = deviceType
            existing.updatedAt = Date()
        } else {
            modelContext.insert(DeviceFingerprint(serial: serial, computerName: deviceType, fingerprintData: fp))
        }
        try? modelContext.save()
        Self.logger.info("Persisted DeviceFingerprint for \(deviceType) (\(serial))")
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

    /// Checks if a dive already exists in the logbook
    private func checkExistingDive(_ diveData: DiveData) -> Dive? {
        let timestamp = diveData.datetime
        let maxDepth = diveData.maxDepth
        
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
            return results.first
        } catch {
            Self.logger.error("Error searching for existing dive: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Merges dive computer data into an existing dive.
    /// Only fields originating from the computer are updated.
    /// User-modified fields (notes, rating, buddies, etc.) are preserved.
    private func mergeComputerData(from diveData: DiveData, into dive: Dive) {
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
                tanks.append(TankData(
                    o2: o2, he: he,
                    volume: tank.volume > 0 ? tank.volume : existing?.volume,
                    startPressure: tank.beginPressure > 0 ? tank.beginPressure : nil,
                    endPressure: tank.endPressure > 0 ? tank.endPressure : nil,
                    workingPressure: tank.workingPressure > 0 ? tank.workingPressure : existing?.workingPressure,
                    tankMaterial: existing?.tankMaterial,
                    tankType: existing?.tankType
                ))
            }
            dive.tanks = tanks
        } else if !diveData.tankPressure.isEmpty {
            // Fallback: create a TankData from tank pressure samples
            let o2Fraction = Double(diveData.gasMix ?? 21) / 100.0
            let startP = diveData.tankPressure.first.flatMap { $0 > 0 ? $0 : nil }
            let endP = diveData.tankPressure.last.flatMap { $0 > 0 ? $0 : nil }
            let existing = existingTanks.first
            dive.tanks = [TankData(o2: o2Fraction, he: 0.0,
                                   volume: existing?.volume,
                                   startPressure: startP, endPressure: endP,
                                   workingPressure: existing?.workingPressure,
                                   tankMaterial: existing?.tankMaterial, tankType: existing?.tankType)]
        } else if !dcGasMixes.isEmpty {
            // No tank data but we have gas mixes — store them as tanks with gas only
            dive.tanks = dcGasMixes.enumerated().map { (index, mix) in
                let existing = index < existingTanks.count ? existingTanks[index] : nil
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
        dive.profileSamples = Self.consolidateProfilePoints(diveData.profile, topLevelDecoType: diveData.decoStop?.type)
        
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

        Self.logger.info("Dive from \(dive.timestamp) merged with computer data")
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
    /// - Parameters:
    ///   - profile: Raw profile points from LibDCSwift (may contain duplicate-timestamp event points)
    ///   - topLevelDecoType: The `diveData.decoStop?.type` value from the top-level dive data
    ///     (DC_DECO_NDL=0, SAFETYSTOP=1, DECOSTOP=2, DEEPSTOP=3). Used to synthesise the
    ///     correct event type when per-sample deco fields indicate an obligation.
    private static func consolidateProfilePoints(
        _ profile: [LibDCSwift.DiveProfilePoint],
        topLevelDecoType: Int?
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
            
            // Synthesize events from DC_SAMPLE_DECO data.
            // Most dive computers report deco status only via DC_SAMPLE_DECO, not DC_SAMPLE_EVENT.
            // The library exposes decoStop (depth, only for DECOSTOP type) and ndl (only for NDL type).
            // When decoStop is non-nil, the diver has a mandatory deco obligation at that sample.
            // When ndl == 0 and decoStop is nil, the diver may be in a safety/deep stop.
            // We use the top-level decoStop type to determine which event to synthesise.
            if base.decoStop != nil {
                // Mandatory deco stop (decoStop depth is only set for DC_DECO_DECOSTOP)
                if !allEvents.contains(.decoStop) {
                    allEvents.append(.decoStop)
                }
            } else if base.ndl == 0 {
                // NDL is zero but no decoStop depth — this is a safety stop or deep stop
                // determined by the top-level deco type from the dive computer
                switch topLevelDecoType {
                case 1: // DC_DECO_SAFETYSTOP
                    if !allEvents.contains(where: { if case .safetyStop = $0 { return true }; return false }) {
                        allEvents.append(.safetyStop(false))
                    }
                case 3: // DC_DECO_DEEPSTOP
                    if !allEvents.contains(.deepStop) {
                        allEvents.append(.deepStop)
                    }
                default:
                    // Could be transitioning to deco — synthesise decoStop as safest guess
                    if !allEvents.contains(.decoStop) {
                        allEvents.append(.decoStop)
                    }
                }
            }
            
            result.append(DiveProfilePoint(
                time: base.time / 60.0, // LibDCSwift uses seconds, BlueDive uses minutes
                depth: base.depth,
                temperature: base.temperature,
                tankPressure: base.pressure,
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
        let profileSamples = Self.consolidateProfilePoints(diveData.profile, topLevelDecoType: diveData.decoStop?.type)
        
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
            for tank in dcTanks {
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
                linkedTanks.append(TankData(
                    o2: o2, he: he,
                    volume: tank.volume > 0 ? tank.volume : nil,
                    startPressure: tank.beginPressure > 0 ? tank.beginPressure : nil,
                    endPressure: tank.endPressure > 0 ? tank.endPressure : nil,
                    workingPressure: tank.workingPressure > 0 ? tank.workingPressure : nil
                ))
            }
        } else if !diveData.tankPressure.isEmpty {
            let o2Fraction = Double(diveData.gasMix ?? 21) / 100.0
            let startP = diveData.tankPressure.first.flatMap { $0 > 0 ? $0 : nil }
            let endP = diveData.tankPressure.last.flatMap { $0 > 0 ? $0 : nil }
            linkedTanks.append(TankData(o2: o2Fraction, he: 0.0, startPressure: startP, endPressure: endP))
        } else if !dcGasMixes.isEmpty {
            linkedTanks = dcGasMixes.map { mix in
                TankData(o2: mix.oxygen, he: mix.helium)
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
                    
                    Text(peripheral.identifier.uuidString.prefix(8) + "...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
