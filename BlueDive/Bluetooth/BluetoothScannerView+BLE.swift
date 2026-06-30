import SwiftUI
import SwiftData
import CoreBluetooth
import LibDCSwift
import Combine
import os.log

// MARK: - BLE Connection

extension BluetoothScannerView {

    func startScanning() {
        syncState = .scanning
        bleManager.startScanning(omitUnsupportedPeripherals: true)
        Self.logger.info("Starting Bluetooth scan")
    }

    func stopScanning() {
        bleManager.stopScanning()
        Self.logger.info("Stopping Bluetooth scan")
    }

    /// Connects directly to a known device using its stored BLE UUID (no scanning required).
    func connectToKnownDevice(_ device: DeviceFingerprint) {
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
    func checkForTargetDevice() {
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

    func connectToDevice(_ peripheral: CBPeripheral) {
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
            } // else {
                // No hardware serial number stored — clearing all fingerprints for this device type
                // is intentionally disabled: without a serial we have no cached fingerprint to clear anyway,
                // and wiping all entries for the model would affect other computers of the same model.
                // Self.logger.warning("No hardware serial number stored — clearing all fingerprints for \(deviceType)")
                // DeviceFingerprintStorage.shared.clearFingerprintsForDeviceType(deviceType)
            // }
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
}
