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
        bleManager.startScanning(omitUnsupportedPeripherals: false)
        Self.logger.info("Starting Bluetooth scan")
    }

    func stopScanning() {
        bleManager.stopScanning()
        Self.logger.info("Stopping Bluetooth scan")
    }

    // MARK: - Import Cutoff Session State

    /// Disarms the cutoff toggle so it cannot silently apply to whatever sync happens next.
    func disarmImportCutoff() {
        importCutoffEnabled = false
    }

    /// Clears the previous sync's cutoff-filtering results so a stale count or date can never
    /// survive onto a later screen.
    func clearCutoffResults() {
        cutoffFilteredCount = 0
        cutoffAppliedDate = nil
    }

    /// Fully exits the search flow and disarms both halves of the full-history configuration —
    /// Download All Dives and the date cutoff — so none of it survives into whatever the user
    /// does next. They have to be reset together: clearing only the cutoff would leave the
    /// expensive half armed and turn the user's next device tap into an unprotected full-history
    /// re-download. Used by both the scanning toolbar's Cancel button and the error screen's
    /// Retry button — the two places a user backs out of an in-flight or failed scan without
    /// completing a sync.
    func abandonScanSession() {
        stopScanning()
        isSearching = false
        cachedTargetFingerprint = nil
        discardPendingSeed()
        downloadAllDives = false
        disarmImportCutoff()
        syncState = .idle
    }

    /// Connects directly to a known device using its stored BLE UUID (no scanning required).
    func connectToKnownDevice(_ device: DeviceFingerprint) {
        // Now that the device is known, anchor the cutoff on the newest dive belonging to *its*
        // diver instead of the newest dive in the logbook. diverNameBySerial is already computed
        // for the known-device list (and keyed on the trimmed, lowercased serial), so this costs
        // no extra fetch beyond the scoped newest-dive lookup itself. Runs before both the direct
        // connect and the scan fallback, since either can end in a full-history download.
        prepareImportCutoffDefault(forDiver: diverNameBySerial[device.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()])

        // Look up the StoredDevice by serial to find the BLE UUID.
        // If DeviceStorage was wiped (reinstall / UserDefaults reset) but
        // the DeviceFingerprint record has family+model, we cannot recover
        // the BLE UUID from the DB alone — fall back to scanning where
        // seedDeviceStorageFromDatabase will re-create the entry once the
        // peripheral is discovered.
        guard let allDevices = DeviceStorage.shared.getAllStoredDevices(),
              let storedDevice = allDevices.first(where: { $0.serial?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == device.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }),
              let uuid = UUID(uuidString: storedDevice.uuid),
              let peripheral = bleManager.centralManager.retrievePeripherals(withIdentifiers: [uuid]).first else {
            Self.logger.warning("Could not retrieve peripheral for \(device.computerName) — falling back to scan")
            // Fall back to scanning; checkForTargetDevice will auto-connect.
            // Cache the DB record so checkForTargetDevice can use it without
            // fetching on every advertisement packet.
            cachedTargetFingerprint = CachedDeviceFingerprint(
                serial: device.serial,
                computerName: device.computerName,
                family: device.family,
                modelID: device.modelID
            )
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
        guard let serial = cachedTargetFingerprint?.serial,
              case .scanning = syncState else { return }

        for peripheral in bleManager.discoveredPeripherals {
            let uuid = peripheral.identifier.uuidString
            if let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: uuid),
               storedDevice.serial?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                Self.logger.info("Found target device: \(peripheral.name ?? "Unknown") matching serial \(serial)")
                let savedName = cachedTargetFingerprint?.computerName
                cachedTargetFingerprint = nil
                connectToDevice(peripheral)
                // Override name with the correct one from the fingerprint record
                if let name = savedName {
                    connectedDeviceName = name
                    syncState = .connecting(deviceName: name)
                }
                return
            }

            // DeviceStorage may be empty (reinstall). Use the fingerprint that was
            // cached when connectToKnownDevice fell back to scanning — avoids a
            // per-advertisement-packet DB fetch.
            if DeviceStorage.shared.getStoredDevice(uuid: uuid) == nil,
               let record = cachedTargetFingerprint,
               let family = record.family,
               record.modelID != 0 {
                // We can't verify serial over BLE before connecting, but the
                // advertisement name should match the stored computerName.
                let bleName = DeviceConfiguration.getDeviceDisplayName(from: peripheral.name ?? "")
                let dbName = record.computerName
                let nameMatch = bleName == dbName || (peripheral.name ?? "").localizedCaseInsensitiveContains(dbName)
                let familyModelMatch: Bool
                if !nameMatch {
                    // Resolves the peripheral's model by its advertised name, then checks
                    // whether that model shares the same family+modelID as the stored fingerprint.
                    // Only fires for models present in supportedModels; unknown-model peripherals
                    // are handled by the immediate-seed path below (lines 116-121).
                    let pm = DeviceConfiguration.supportedModels.first(where: { $0.name == bleName })
                    familyModelMatch = pm.map { $0.family == family && $0.modelID == record.modelID } ?? false
                } else {
                    familyModelMatch = false
                }
                guard nameMatch || familyModelMatch else { continue }
                // Defer DeviceStorage seeding until a successful download confirms we connected
                // to the right peripheral — two computers of the same model share identical BLE
                // names, so name matching alone cannot prove we have the right unit.
                // Use pendingDeviceStorageSeed + a temporary model override so openBLEDevice
                // gets the correct family/model without writing to DeviceStorage yet.
                // If the model is not in supportedModels (e.g. removed in a library update),
                // fall back to immediate seeding so openBLEDevice can at least use DeviceStorage.
                if let model = DeviceConfiguration.supportedModels.first(where: { $0.family == family && $0.modelID == record.modelID }) {
                    pendingDeviceStorageSeed = (uuid: peripheral.identifier.uuidString, name: record.computerName, family: family, modelID: record.modelID, serial: record.serial)
                    modelOverrides[peripheral.identifier.uuidString] = model
                } else {
                    // Model absent from supportedModels — seed DeviceStorage immediately so openBLEDevice
                    // can use it, but also track via pendingDeviceStorageSeed so failure paths can clean up.
                    DeviceStorage.shared.storeDevice(uuid: peripheral.identifier.uuidString, name: record.computerName, family: family, model: record.modelID, serial: record.serial)
                    pendingDeviceStorageSeed = (uuid: peripheral.identifier.uuidString, name: record.computerName, family: family, modelID: record.modelID, serial: record.serial)
                }
                Self.logger.info("Deferred DeviceStorage seed for scanned peripheral \(peripheral.name ?? "Unknown") — connecting")
                let savedName = record.computerName
                cachedTargetFingerprint = nil
                connectToDevice(peripheral)
                connectedDeviceName = savedName
                syncState = .connecting(deviceName: savedName)
                return
            }
        }
    }

    func connectToDevice(_ peripheral: CBPeripheral) {
        guard !syncState.isActive || syncState == .scanning else { return }

        clearCutoffResults()

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

        // BLE Diagnostic Logging
        // Toggle ON  → BLEDiagnosticSession.start(): writes the full trace (log lines +
        //              packet hex dumps) to a log file in Documents; packet dumps also
        //              echo to the Xcode console in DEBUG builds.
        //              (Settings → Bluetooth Import → BLE Diagnostic Logging)
        //              Log file: BlueDive_BLE_<timestamp>.log — saved via error screen or Settings
        // Toggle OFF → silent; uncomment the #if DEBUG block below for quick console-only debugging
        if BLEDiagnosticSession.resolveLoggingEnabled() {
            BLEDiagnosticSession.shared.start()
        } else {
            #if DEBUG
            // Logger.shared.enableDebugMode()
            // Logger.shared.onPacket = { event in
            //     print("[\(event.direction.rawValue.uppercased())] \(event.characteristicUUID) (\(event.data.count) bytes)\n\(event.hexDump)")
            // }
            #endif
        }

        // Stop scanning
        stopScanning()

        // IMPORTANT: openBLEDevice is a blocking call that waits for CoreBluetooth
        // callbacks (e.g. didConnect). These callbacks are delivered on the main queue.
        // If we call openBLEDevice from the main queue, the callbacks can never be
        // processed and the connection times out.
        // We dispatch on a background thread to free the main RunLoop.
        //
        // Set isConnecting synchronously before the dispatch. openBLEDevice sets it
        // via DispatchQueue.main.async — which can arrive AFTER didDisconnectPeripheral
        // fires, leaving the guard window open and triggering a spurious auto-reconnect
        // that races with the real connection and causes a double-free of device_data_t.
        bleManager.isConnecting = true
        let forcedModel: (family: DeviceConfiguration.DeviceFamily, model: UInt32)?
        if let override = modelOverrides[deviceAddress] {
            forcedModel = (family: override.family, model: override.modelID)
            Self.logger.info("Using user-selected model override: \(override.name)")
        } else {
            forcedModel = nil
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let connected = DeviceConfiguration.openBLEDevice(
                name: deviceName,
                deviceAddress: deviceAddress,
                forcedModel: forcedModel
            )

            guard connected else {
                DispatchQueue.main.async {
                    Self.logger.error("Failed to connect to \(deviceName)")
                    BLEDiagnosticSession.shared.stop()
                    self.syncState = .error(message: String(format: NSLocalizedString("Unable to connect to %@", bundle: Bundle.forAppLanguage(), comment: "Error message shown when a Bluetooth connection to a dive computer fails. %@ is the device name."), deviceName))
                    self.selectedDevice = nil
                    self.discardPendingSeed(matchingUUID: deviceAddress)
                    self.restorePendingReassociationPrune()
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
                    BLEDiagnosticSession.shared.stop()
                    self.bleManager.close(clearDevicePtr: true)
                    self.bleManager.clearRetrievalState()
                    self.discardPendingSeed(matchingUUID: deviceAddress)
                    // openBLEDevice wrote a nil-serial entry to DeviceStorage on success.
                    // Remove unconditionally — keyed by captured deviceAddress, serial==nil guard is surgical.
                    if let allDevices = DeviceStorage.shared.getAllStoredDevices() {
                        let filtered = allDevices.filter { !($0.uuid == deviceAddress && $0.serial == nil) }
                        if filtered.count < allDevices.count {
                            DeviceStorage.shared.updateStoredDevices(filtered)
                            Self.logger.info("[BLE] Removed nil-serial orphan DeviceStorage entry for \(deviceAddress.prefix(8))… after pointer timeout")
                        }
                    }
                    self.restorePendingReassociationPrune()
                    return
                }
                // Past this point the connection is confirmed viable, so the double-free race
                // window the prune protects against has closed and the new UUID mapping
                // legitimately supersedes the old one. Drop the restore without applying it.
                self.pendingReassociationPruneRestore = nil
                self.retrieveDiveLogs(from: peripheral)
            }
        }
    }


    private func retrieveDiveLogs(from peripheral: CBPeripheral) {
        guard let devicePtr = bleManager.openedDeviceDataPtr else {
            Self.logger.error("Device pointer not available")
            syncState = .error(message: NSLocalizedString("Device not available", bundle: Bundle.forAppLanguage(), comment: "Error message shown when the dive computer device pointer is unavailable at the start of a download."))
            BLEDiagnosticSession.shared.stop()
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
        let watermarkRestored: Bool
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
            // A single-key clear (rather than the serial-wide sweep used elsewhere) is sufficient
            // here: this whole download runs with useFingerprint: false (set below when calling
            // DiveLogRetriever.retrieveDiveLogs), so none of the library's fingerprint-lookup paths
            // consult the UserDefaults cache at all. A stale entry surviving under a different
            // deviceType key cannot affect this sync — the clear just tidies the most likely key.
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
            // The cache entry for this device was just cleared and useFingerprint is false
            // below, so the library has nothing to compare against: always full history.
            watermarkRestored = false
        } else {
            // Always sync fingerprint from SwiftData before downloading.
            // UserDefaults is used as a session-level cache by the library; SwiftData is the
            // source of truth. This covers reinstalls, iCloud restores, and deleted dives.
            watermarkRestored = (syncFingerprintFromDatabase(for: peripheral) == .restored)
        }

        // Whether this download covers the whole device history is only knowable here, once the
        // watermark has been resolved — every earlier UI event can merely guess at it. A cutoff
        // is meaningful for a full-history download only: an incremental sync is already limited
        // to dives recorded since the last one, so discarding older dives there would drop dives
        // the user expects to keep.
        let isFullHistoryDownload = downloadAllDives || !watermarkRestored
        let effectiveCutoff: Date? = (isFullHistoryDownload && importCutoffEnabled)
            ? Calendar.current.startOfDay(for: importCutoffDate)
            : nil

        bleManager.isRetrievingLogs = true
        bleManager.currentRetrievalDevice = peripheral

        // Observe the number of downloaded dives via the viewModel
        // (onProgress reports transfer bytes, not dives)

        DiveLogRetriever.retrieveDiveLogs(
            from: devicePtr,
            device: peripheral,
            viewModel: viewModel,
            bluetoothManager: bleManager,
            syncClock: syncDeviceClock,
            useFingerprint: !downloadAllDives,
            onProgress: { current, total in
                DispatchQueue.main.async {
                    // current/total are libdivecomputer transfer bytes — used for the progress bar.
                    // Guard prevents a late progress event (fired after completion) from
                    // overwriting .completed or .error back to .downloading.
                    guard case .downloading = self.syncState, total > 0 else { return }
                    self.syncState = .downloading(current: current, total: total)
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

                        // Filtering happens AFTER download — every dive still transfers over
                        // BLE, this only keeps the logbook clean.
                        let cutoff = effectiveCutoff

                        let downloaded = viewModel.dives
                        let kept: [DiveData]
                        if let cutoff {
                            kept = downloaded.filter { $0.datetime >= cutoff }
                            self.cutoffFilteredCount = downloaded.count - kept.count
                            self.cutoffAppliedDate = self.cutoffFilteredCount > 0 ? cutoff : nil
                            Self.logger.info("Import cutoff \(cutoff): kept \(kept.count) of \(downloaded.count) downloaded dive(s), discarded \(downloaded.count - kept.count)")
                        } else {
                            kept = downloaded
                            self.cutoffFilteredCount = 0
                            self.cutoffAppliedDate = nil
                        }

                        if kept.isEmpty {
                            // No dives to import, close the connection
                            self.downloadProgressCancellable = nil
                            self.commitPendingSeed()
                            BLEDiagnosticSession.shared.stop()
                            self.bleManager.close(clearDevicePtr: true)
                            self.bleManager.clearRetrievalState()
                            // Two very different situations land in this branch. When nothing was
                            // downloaded at all the device simply had nothing new to send, and a
                            // partial-sync flag carries no meaning there — it stays false, as it
                            // always has. When dives were downloaded but every one of them fell
                            // before the cutoff, the library's partial-sync signal is about real
                            // dives it could not read, so it must be preserved for the warning
                            // completedView shows on this path.
                            self.isPartialSync = downloaded.isEmpty ? false : viewModel.isPartialSync
                            // Dives WERE downloaded but all fell before the cutoff. In the normal
                            // incremental-fingerprint case the library already advanced its
                            // UserDefaults watermark (DiveLogRetriever saveFingerprint), so copy it
                            // into SwiftData here — importDownloadedDives never runs on this path.
                            // Without this, syncFingerprintFromDatabase would find no DB record on
                            // the next sync, clear UserDefaults, and re-download the entire history.
                            //
                            // Caveat: that "library already advanced its watermark" premise only
                            // holds when fingerprinting is on. With downloadAllDives the enclosing
                            // DiveLogRetriever.retrieveDiveLogs call passes useFingerprint: false,
                            // so the library's shouldSaveFingerprint logic never writes a watermark
                            // in the first place — there is nothing to mirror. The call still runs
                            // here, but persistFingerprintRecord's own guard (no cached fingerprint
                            // under the library's key) makes it a harmless no-op rather than
                            // persisting anything incorrect.
                            if !downloaded.isEmpty {
                                self.persistFingerprintRecord(for: self.selectedDevice)
                            }
                            self.selectedDevice = nil
                            self.syncState = .completed(imported: 0, merged: 0, skipped: 0)
                        } else {
                            self.downloadProgressCancellable = nil
                            self.commitPendingSeed()
                            self.downloadedDives = kept
                            self.isPartialSync = viewModel.isPartialSync
                            BLEDiagnosticSession.shared.stop()
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
                        self.downloadProgressCancellable = nil
                        let failedSeedUUID = self.pendingDeviceStorageSeed?.uuid
                        self.discardPendingSeed()
                        if let failedUUID = failedSeedUUID,
                           let allDevices = DeviceStorage.shared.getAllStoredDevices() {
                            let filtered = allDevices.filter { $0.uuid != failedUUID }
                            if filtered.count < allDevices.count {
                                DeviceStorage.shared.updateStoredDevices(filtered)
                                Self.logger.info("[BLE] Removed DeviceStorage entry for failed reassociation \(failedUUID.prefix(8))…")
                            }
                        }
                        BLEDiagnosticSession.shared.stop()
                        self.bleManager.close(clearDevicePtr: true)
                        self.bleManager.clearRetrievalState()
                        self.selectedDevice = nil
                    }
                }
            }
        )
    }

    // MARK: - Seed Lifecycle

    static let knownSentinelSerials: Set<String> = ["0", "00000000", "unknown", "n/a"]

    func commitPendingSeed() {
        guard let seed = pendingDeviceStorageSeed else { return }
        // Verify the hardware serial the library reported matches the fingerprint record.
        // The reported serial was written by the library itself (DiveLogRetriever calls
        // DeviceStorage.updateDeviceSerial with the hardware-reported serial during serial/
        // fingerprint detection), so it is ground truth about which physical unit is on the
        // other end of this connection — not our own guess. A mismatch therefore means the
        // reassociation candidate we guessed at was wrong, and the entry already on file is
        // the correct one. Discard our seed and leave DeviceStorage untouched: overwriting or
        // deleting that entry would destroy a correct mapping and break dedup, diver
        // resolution, and watermark persistence for a device that was identified correctly.
        if let reportedSerial = DeviceStorage.shared.getStoredDevice(uuid: seed.uuid)?.serial,
           !reportedSerial.isEmpty,
           reportedSerial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != seed.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            Self.logger.error("[BLE] Serial mismatch at commit — seed=\(seed.serial) reported=\(reportedSerial). Reported serial is ground truth; discarding our seed and keeping the existing DeviceStorage entry unchanged.")
            discardPendingSeed()
            return
        }
        DeviceStorage.shared.storeDevice(uuid: seed.uuid, name: seed.name, family: seed.family, model: seed.modelID, serial: seed.serial)
        if !seed.serial.isEmpty && !Self.knownSentinelSerials.contains(seed.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
           let allDevices = DeviceStorage.shared.getAllStoredDevices() {
            let filtered = allDevices.filter { !($0.serial?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == seed.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() && $0.uuid != seed.uuid) }
            if filtered.count < allDevices.count {
                DeviceStorage.shared.updateStoredDevices(filtered)
                Self.logger.info("Removed stale DeviceStorage UUID for \(seed.name) (serial: \(seed.serial))")
            }
        }
        modelOverrides.removeValue(forKey: seed.uuid)
        pendingDeviceStorageSeed = nil
    }

    func discardPendingSeed() {
        guard let seed = pendingDeviceStorageSeed else { return }
        modelOverrides.removeValue(forKey: seed.uuid)
        pendingDeviceStorageSeed = nil
    }

    func discardPendingSeed(matchingUUID uuid: String) {
        guard pendingDeviceStorageSeed?.uuid == uuid else { return }
        discardPendingSeed()
    }

    /// Puts back the DeviceStorage entries removed by a legacy reassociation prune whose
    /// connection attempt then failed. Without this the device becomes unreachable via
    /// `connectToKnownDevice`/`checkForTargetDevice` (both look it up in DeviceStorage by
    /// serial) until the user manually redoes reassociation — the legacy path sets no
    /// `pendingDeviceStorageSeed`, so nothing else can recommit the mapping.
    /// No-op when nothing is armed. Must be called on the main actor.
    func restorePendingReassociationPrune() {
        guard let pruned = pendingReassociationPruneRestore, !pruned.isEmpty else {
            pendingReassociationPruneRestore = nil
            return
        }
        pendingReassociationPruneRestore = nil
        var merged = DeviceStorage.shared.getAllStoredDevices() ?? []
        var existingUUIDs = Set(merged.map { $0.uuid })
        var restoredCount = 0
        for entry in pruned where !existingUUIDs.contains(entry.uuid) {
            merged.append(entry)
            existingUUIDs.insert(entry.uuid)
            restoredCount += 1
        }
        guard restoredCount > 0 else { return }
        DeviceStorage.shared.updateStoredDevices(merged)
        Self.logger.info("[Reassociation] Connection failed — restored \(restoredCount) pruned DeviceStorage entry/entries")
    }

    // MARK: - Reassociation

    /// Intercepts a manual tap on a discovered peripheral. Shows a reassociation prompt
    /// if the peripheral's display name matches exactly one known DeviceFingerprint with
    /// a different BLE UUID, a disambiguation picker for multiple matches, or connects
    /// directly when no match is found.
    func handleDeviceTap(_ peripheral: CBPeripheral) {
        let uuid = peripheral.identifier.uuidString
        // An identity mapping already exists for this exact BLE UUID, so there is no ambiguity
        // to resolve and reassociation matching is skipped entirely. This deliberately stays a
        // pure DeviceStorage question: an earlier version of this code also required a
        // DeviceFingerprint record here, which let an unfinished-import peripheral (DeviceStorage
        // entry present, no DeviceFingerprint yet) fall through into name-based candidate
        // matching, where it can spuriously match a *different*, unrelated known device sharing
        // the same model name — and if accepted, corrupt that other device's DeviceStorage
        // mapping via the pruning step in confirmReassociation below.
        let existingStoredDevice = DeviceStorage.shared.getStoredDevice(uuid: uuid)
        guard existingStoredDevice == nil else {
            Self.logger.info("[Reassociation] UUID \(uuid.prefix(8))… already in DeviceStorage — direct connect")
            // Same reasoning as connectToKnownDevice: this peripheral's identity is already known,
            // so the cutoff can be anchored on the newest dive belonging to *its* diver rather than
            // on the whole logbook. Keyed exactly like the candidate-matching path below (trimmed,
            // lowercased serial). An unresolvable serial falls through to the generic seed.
            if let serial = existingStoredDevice?.serial {
                prepareImportCutoffDefault(forDiver: diverNameBySerial[serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()])
            }
            connectToDevice(peripheral)
            return
        }
        let bleName = DeviceConfiguration.getDeviceDisplayName(from: peripheral.name ?? "")
        Self.logger.info("[Reassociation] UUID \(uuid.prefix(8))… not in DeviceStorage — scanning \(knownDevices.count) fingerprint(s) for '\(bleName)'")
        let diverNames = diverNameBySerial
        // Prefer the user's explicit model override when resolving the peripheral's model.
        // This handles the case where the BLE display name (e.g. "Shearwater Peregrine TX")
        // doesn't match the fingerprint's stored computerName (e.g. "Shearwater Peregrine")
        // but the user has already identified the correct model via the model picker.
        // Falls back to BLE-name resolution for the secondary family+modelID match.
        let resolvedModel = modelOverrides[uuid] ?? DeviceConfiguration.supportedModels.first(where: { $0.name == bleName })
        let candidates: [ReassociationCandidate] = dedupedKnownDevices.compactMap { fp in
            let nameMatch = bleName == fp.computerName
            let modelMatch: Bool
            if !nameMatch, let fpFamily = fp.family, let rm = resolvedModel {
                modelMatch = rm.family == fpFamily && rm.modelID == fp.modelID
            } else {
                modelMatch = false
            }
            guard nameMatch || modelMatch else { return nil }
            let trimmedSerial = fp.serial.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.logger.debug("[Reassociation] Candidate: '\(fp.computerName)' serial=\(trimmedSerial) via \(nameMatch ? "name" : "family+modelID")")
            // The id must stay unique even when two candidates share a sentinel serial (e.g. "0"),
            // which dedupedKnownDevices deliberately does not collapse — a duplicate Identifiable
            // id in the picker's ForEach is undefined list diffing. `serial` stays the plain
            // trimmed serial; only the identity is qualified.
            return ReassociationCandidate(
                id: "\(trimmedSerial)#\(fp.persistentModelID)",
                serial: trimmedSerial,
                computerName: fp.computerName,
                family: fp.family,
                modelID: fp.modelID,
                lastSynced: fp.updatedAt,
                diverName: diverNames[trimmedSerial.lowercased()]
            )
        }
        switch candidates.count {
        case 0:
            Self.logger.info("[Reassociation] No matching fingerprints — treating '\(bleName)' as new device")
            connectToDevice(peripheral)
        case 1:
            let c = candidates[0]
            Self.logger.info("[Reassociation] 1 match for '\(bleName)': '\(c.computerName)' serial=\(c.serial)\(c.diverName.map { " diver=\($0)" } ?? "") — showing alert")
            peripheralPendingReassociation = peripheral
            reassociationCandidates = candidates
            showingReassociationAlert = true
        default:
            Self.logger.info("[Reassociation] \(candidates.count) matches for '\(bleName)': \(candidates.map { $0.serial }.joined(separator: ", ")) — showing picker")
            peripheralForReassociationPicker = peripheral
            reassociationCandidates = candidates
        }
    }

    /// Removes stale DeviceStorage entries for the candidate's serial, sets up a
    /// deferred seed with the new UUID, and connects. The model override ensures
    /// connectToDevice resolves the correct display name without a full download.
    func confirmReassociation(_ peripheral: CBPeripheral, candidate: ReassociationCandidate) {
        // Runs before the prune below: when this guard fails the function returns without ever
        // calling connectToDevice, so there is no connection attempt for a prune to protect —
        // pruning first would destroy the old-UUID mapping for zero benefit.
        guard !syncState.isActive || syncState == .scanning else {
            Self.logger.warning("[Reassociation] Confirmation aborted — sync already active (\(String(describing: syncState)))")
            return
        }

        // Same reasoning as connectToKnownDevice: the candidate identifies the computer, so
        // anchor the cutoff on the newest dive belonging to *its* diver rather than on the
        // whole logbook. Runs first so it also covers the legacy no-family fallback below,
        // which still ends in a plain connect and therefore a full-history download.
        prepareImportCutoffDefault(forDiver: candidate.diverName)

        let newUUID = peripheral.identifier.uuidString
        // A legacy fingerprint record carries no family/modelID, so the guard below returns early
        // and pendingDeviceStorageSeed is never set — that path has no way to recommit the pruned
        // mapping if the connect fails. Capture the removed entries for it instead.
        let isLegacyRecord = candidate.family == nil
        // Prune stale DeviceStorage entries for this serial immediately.
        // The old UUID (e.g. left over after an OS Bluetooth deletion + re-pair)
        // would cause didDisconnectPeripheral to trigger auto-reconnect during
        // the openBLEDevice window, racing with this connection and causing a
        // double-free of device_data_t. commitPendingSeed would prune it on
        // success, but that's too late to prevent the crash.
        // Runs before the legacy no-family early return below so that path — which also
        // ends in a plain connect — is protected from the same race.
        if !candidate.serial.isEmpty && !Self.knownSentinelSerials.contains(candidate.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
           let allDevices = DeviceStorage.shared.getAllStoredDevices() {
            let filtered = allDevices.filter { !($0.serial?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == candidate.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() && $0.uuid != newUUID) }
            if filtered.count < allDevices.count {
                if isLegacyRecord {
                    // Arm the restore before the write, so connectToDevice's failure branches can
                    // put these back. The prune still happens before connectToDevice — the
                    // double-free race window is unchanged.
                    pendingReassociationPruneRestore = allDevices.filter {
                        $0.serial?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == candidate.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() && $0.uuid != newUUID
                    }
                }
                DeviceStorage.shared.updateStoredDevices(filtered)
                Self.logger.info("[Reassociation] Pruned \(allDevices.count - filtered.count) stale DeviceStorage entry/entries for serial \(candidate.serial) before connect")
            }
        }

        guard let family = candidate.family else {
            Self.logger.warning("[Reassociation] '\(candidate.computerName)' (serial \(candidate.serial)) has no family/modelID — legacy record, falling back to plain connect")
            connectToDevice(peripheral)
            return
        }
        Self.logger.info("[Reassociation] Confirming reassociation: '\(candidate.computerName)' serial=\(candidate.serial) newUUID=\(newUUID.prefix(8))…")
        pendingDeviceStorageSeed = (uuid: newUUID, name: candidate.computerName,
                                    family: family, modelID: candidate.modelID,
                                    serial: candidate.serial)
        if let model = DeviceConfiguration.supportedModels.first(where: {
            $0.family == family && $0.modelID == candidate.modelID
        }) {
            Self.logger.info("[Reassociation] Model found in library: '\(model.name)' — modelOverride + forcedModel will be used")
            modelOverrides[newUUID] = model
        } else {
            Self.logger.warning("[Reassociation] Model (family=\(String(describing: family)) modelID=\(candidate.modelID)) not in supportedModels — seed set, no forcedModel hint")
        }
        connectToDevice(peripheral)
        connectedDeviceName = candidate.computerName
        syncState = .connecting(deviceName: candidate.computerName)
    }

    func clearReassociationState() {
        peripheralPendingReassociation = nil
        peripheralForReassociationPicker = nil
        reassociationCandidates = []
        showingReassociationAlert = false
    }
}
