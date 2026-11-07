import SwiftUI
import SwiftData
import DiveComputerKit
import os.log

// MARK: - BLE Connection

extension BluetoothScannerView {

    func startScanning() {
        beginDiagnosticTraceIfEnabled()
        syncState = .scanning
        // Listed: peripherals this app connected to before, and names the catalog resolves.
        let knownIDs = Set((DeviceStorage.shared.getAllStoredDevices() ?? []).compactMap { UUID(uuidString: $0.uuid) })
        bleManager.setDiscoveryFilter { id, name in
            knownIDs.contains(id) || DeviceCatalog.resolve(advertisedName: name) != nil
        }
        bleManager.startScanning(onlyKnownServices: false)
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
        cutoffStopDate = nil
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
        BLEDiagnosticSession.shared.stop()
        isSearching = false
        cachedTargetFingerprint = nil
        discardPendingSeed()
        downloadAllDives = false
        disarmImportCutoff()
        syncState = .idle
    }

    /// Starts the BLE diagnostic trace (Settings → Bluetooth Import) unless one is already
    /// recording, so a scan, a connection and its fallback all land in the same file.
    func beginDiagnosticTraceIfEnabled() {
        guard BLEDiagnosticSession.resolveLoggingEnabled(), !BLEDiagnosticSession.shared.isRunning else { return }
        BLEDiagnosticSession.shared.start()
    }

    /// Connects directly to a known device using its stored BLE UUID (no scanning required).
    func connectToKnownDevice(_ device: DeviceFingerprint) {
        beginDiagnosticTraceIfEnabled()
        // Now that the device is known, anchor the cutoff on the newest dive belonging to *its*
        // diver instead of the newest dive in the logbook. diverNameBySerial is already computed
        // for the known-device list (and keyed on the trimmed, lowercased serial), so this costs
        // no extra fetch beyond the scoped newest-dive lookup itself. Runs before both the direct
        // connect and the scan fallback, since either can end in a full-history download.
        let serialKey = DeviceStorage.normalizedSerial(device.serial)
        prepareImportCutoffDefault(forDiver: diverNameBySerial[serialKey])

        let record = CachedDeviceFingerprint(
            serial: device.serial,
            computerName: device.computerName,
            family: device.family,
            modelID: device.modelID
        )

        // Look up the StoredDevice by serial to find the BLE UUID; the most recently stored
        // one when older entries for the same serial survive from before the one-identifier
        // rule. If DeviceStorage was wiped (reinstall / UserDefaults reset) but the
        // DeviceFingerprint record has family+model, we cannot recover the BLE UUID from the
        // DB alone — fall back to scanning where checkForTargetDevice will re-create the
        // entry once the peripheral is discovered.
        let matches = (DeviceStorage.shared.getAllStoredDevices() ?? [])
            .filter { $0.serial.map(DeviceStorage.normalizedSerial) == serialKey }
        DiveComputerLog.shared.log("[Known device] \(device.computerName) serial \(serialKey): " +
                                   (matches.isEmpty ? "no stored identifier"
                                    : matches.map { "\($0.uuid) (\($0.lastConnected))" }.joined(separator: ", ")), level: .info)
        guard let storedDevice = matches.max(by: { $0.lastConnected < $1.lastConnected }),
              let uuid = UUID(uuidString: storedDevice.uuid),
              let peripheral = bleManager.knownPeripheral(id: uuid) else {
            DiveComputerLog.shared.log("[Known device] Could not retrieve the peripheral for \(device.computerName) — scanning", level: .warning)
            scanForKnownDevice(record)
            return
        }

        // Ensure DeviceStorage has the latest family/model from the DB
        seedDeviceStorageFromDatabase(for: peripheral, fingerprint: device)

        DiveComputerLog.shared.log("[Known device] Connecting to \(device.computerName) by its stored identifier \(uuid.uuidString)", level: .info)
        isSearching = true
        // The display name comes from the fingerprint record: the raw BLE advertisement name
        // may resolve to another model (e.g. "Oceanic Pro Plus X" instead of "Aqualung i300C").
        // A peripheral the system has forgotten (removed in the OS Bluetooth settings) does
        // not connect and the attempt ends with "Unable to connect"; the user then uses
        // Search for Devices, where the reassociation prompt maps it to its new identifier.
        if !connectToDevice(peripheral, displayName: device.computerName) {
            isSearching = false
        }
    }

    /// Scans for a known device; checkForTargetDevice connects to it once it is seen, under
    /// its stored identifier or a new one. The record is cached so checkForTargetDevice
    /// does not fetch it on every advertisement packet.
    private func scanForKnownDevice(_ record: CachedDeviceFingerprint) {
        cachedTargetFingerprint = record
        isSearching = true
        bleManager.clearDiscoveredDevices()
        startScanning()
    }

    /// Checks newly discovered peripherals for the target device and auto-connects (fallback path).
    func checkForTargetDevice() {
        guard let serial = cachedTargetFingerprint?.serial,
              case .scanning = syncState else { return }

        // Two passes: an identifier stored for this serial wins over a name match, so another
        // unit of the same model that is also on is never picked while the right one is seen.
        for peripheral in bleManager.discoveredDevices {
            let uuid = peripheral.identifier.uuidString
            if let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: uuid),
               storedDevice.serial?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                DiveComputerLog.shared.log("[Known device] Found \(peripheral.name ?? "Unknown") \(uuid) under its stored identifier, serial \(serial)", level: .info)
                let savedName = cachedTargetFingerprint?.computerName
                cachedTargetFingerprint = nil
                // The name from the fingerprint record, not the advertised one.
                connectToDevice(peripheral, displayName: savedName)
                return
            }
        }

        for peripheral in bleManager.discoveredDevices {
            let uuid = peripheral.identifier.uuidString
            // DeviceStorage may be empty (reinstall). Use the fingerprint that was
            // cached when connectToKnownDevice fell back to scanning — avoids a
            // per-advertisement-packet DB fetch.
            if DeviceStorage.shared.getStoredDevice(uuid: uuid) == nil,
               let record = cachedTargetFingerprint,
               let family = record.family,
               record.modelID != 0 {
                // We can't verify serial over BLE before connecting, but the
                // advertisement name should match the stored computerName.
                let bleName = DeviceCatalog.displayName(forAdvertisedName: peripheral.name ?? "")
                let dbName = record.computerName
                let nameMatch = bleName == dbName || (peripheral.name ?? "").localizedCaseInsensitiveContains(dbName)
                let familyModelMatch: Bool
                if !nameMatch {
                    // Resolves the peripheral's model by its advertised name, then checks
                    // whether that model shares the same family+modelID as the stored fingerprint.
                    // Only fires for models present in supportedModels; unknown-model peripherals
                    // are handled by the immediate-seed path below (lines 116-121).
                    let pm = DeviceCatalog.supportedModels.first(where: { $0.name == bleName })
                    familyModelMatch = pm.map { $0.family == family && $0.modelID == record.modelID } ?? false
                } else {
                    familyModelMatch = false
                }
                guard nameMatch || familyModelMatch else { continue }
                // Defer DeviceStorage seeding until a successful download confirms we connected
                // to the right peripheral — two computers of the same model share identical BLE
                // names, so name matching alone cannot prove we have the right unit.
                // Use pendingDeviceStorageSeed + a temporary model override so the session opens
                // with the correct family/model without writing to DeviceStorage yet.
                // If the model is not in supportedModels (e.g. removed in a library update),
                // fall back to immediate seeding so the session can at least use DeviceStorage.
                if let model = DeviceCatalog.supportedModels.first(where: { $0.family == family && $0.modelID == record.modelID }) {
                    pendingDeviceStorageSeed = (uuid: peripheral.identifier.uuidString, name: record.computerName, family: family, modelID: record.modelID, serial: record.serial)
                    modelOverrides[peripheral.identifier.uuidString] = model
                } else {
                    // Model absent from supportedModels — seed DeviceStorage immediately so the session
                    // can use it, but also track via pendingDeviceStorageSeed so failure paths can clean up.
                    DeviceStorage.shared.storeDevice(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? record.computerName, family: family, model: record.modelID, serial: record.serial)
                    pendingDeviceStorageSeed = (uuid: peripheral.identifier.uuidString, name: record.computerName, family: family, modelID: record.modelID, serial: record.serial)
                }
                DiveComputerLog.shared.log("[Known device] Found \(peripheral.name ?? "Unknown") under a new identifier \(uuid) — connecting, stored after a successful download", level: .info)
                cachedTargetFingerprint = nil
                // Matched by name only: another unit of the same model would match too, so the
                // session stops before any dive if the device reports another serial.
                connectToDevice(peripheral, displayName: record.computerName, expectedSerial: record.serial)
                return
            }
        }
    }

    /// Starts a download session. `displayName` replaces the name resolved from the
    /// advertisement (a known device's stored name). `expectedSerial` is the serial of the
    /// computer this peripheral was only guessed to be (matched by name): if the device
    /// reports another serial, the session stops before any dive and nothing is stored.
    /// Returns false when a sync is already running and nothing was started.
    @discardableResult
    func connectToDevice(_ peripheral: DiscoveredDevice, displayName: String? = nil,
                         expectedSerial: String? = nil) -> Bool {
        guard !syncState.isActive || syncState == .scanning else {
            DiveComputerLog.shared.log("Connect to \(peripheral.identifier.uuidString) ignored — sync already active (\(String(describing: syncState)))", level: .warning)
            return false
        }

        clearCutoffResults()

        let deviceName = peripheral.name ?? "Unknown Device"
        let deviceAddress = peripheral.identifier.uuidString
        selectedDevice = peripheral
        // Use the model override name if set, then check DeviceStorage for a
        // previously saved correct model, otherwise resolve from the BLE name
        if let displayName {
            connectedDeviceName = displayName
        } else if let override = modelOverrides[deviceAddress] {
            connectedDeviceName = override.name
        } else if let stored = DeviceStorage.shared.getStoredDevice(uuid: deviceAddress),
                  let modelInfo = DeviceCatalog.supportedModels.first(where: { $0.modelID == stored.model && $0.family == stored.family }) {
            connectedDeviceName = modelInfo.name
        } else {
            connectedDeviceName = DeviceCatalog.displayName(forAdvertisedName: deviceName)
        }
        syncState = .connecting(deviceName: connectedDeviceName ?? deviceName)

        Self.logger.info("Attempting to connect to \(deviceName)")
        Self.logger.info("peripheral: \(String(describing: peripheral))")

        // BLE Diagnostic Logging
        // Toggle ON  → BLEDiagnosticSession.start(): writes the full trace (log lines +
        //              packet hex dumps) to a log file in Documents; packet dumps also
        //              echo to the Xcode console in DEBUG builds.
        //              (Settings → Bluetooth Import → BLE Diagnostic Logging)
        //              Log file: BlueDive_BLE_<timestamp>.log — saved via error screen or Settings
        // Toggle OFF → silent; uncomment the #if DEBUG block below for quick console-only debugging
        if BLEDiagnosticSession.resolveLoggingEnabled() {
            beginDiagnosticTraceIfEnabled()
        } else {
            #if DEBUG
            // DiveComputerLog.shared.enableDebugMode()
            // DiveComputerLog.shared.onPacket = { event in
            //     print("[\(event.direction.rawValue.uppercased())] \(event.characteristicUUID) (\(event.data.count) bytes)\n\(event.hexDump)")
            // }
            #endif
        }

        // Stop scanning
        stopScanning()

        // Model to open with: the user's override, else the stored model, else the name.
        let modelSelection: ModelSelection
        if let override = modelOverrides[deviceAddress] {
            modelSelection = .forced(override.family, override.modelID)
            Self.logger.info("Using user-selected model override: \(override.name)")
        } else if let stored = DeviceStorage.shared.getStoredDevice(uuid: deviceAddress) {
            modelSelection = .stored(stored.family, stored.model)
        } else {
            modelSelection = .autoDetect
        }

        // The watermark: SwiftData's DeviceFingerprint is the only source. With "Download all
        // dives" none is applied, so the whole history is transferred.
        let watermarkRestored: Bool
        let fingerprints: [String: Data]
        if downloadAllDives {
            Self.logger.info("'Download all dives' mode enabled — no fingerprint applied")
            watermarkRestored = false
            fingerprints = [:]
        } else {
            let resolved = fingerprintFromDatabase(for: peripheral)
            watermarkRestored = resolved.result == .restored
            // With the serial unknown before connecting, the session could still apply the
            // reported serial's watermark. Not when a cutoff is armed: the download is then a
            // full-history one (as the screen says), and a cutoff on an incremental download
            // would drop new dives older than it, then move the watermark past them.
            fingerprints = (!watermarkRestored && importCutoffEnabled) ? [:] : resolved.table
        }

        // A cutoff is meaningful for a full-history download only: an incremental sync is
        // already limited to dives recorded since the last one, so discarding older dives
        // there would drop dives the user expects to keep.
        let isFullHistoryDownload = downloadAllDives || !watermarkRestored
        let effectiveCutoff: Date? = (isFullHistoryDownload && importCutoffEnabled)
            ? Calendar.current.startOfDay(for: importCutoffDate)
            : nil

        let request = SessionRequest(
            peripheralID: peripheral.identifier,
            advertisedName: peripheral.name,
            modelSelection: modelSelection,
            useFingerprint: !downloadAllDives,
            fingerprintsBySerial: fingerprints,
            // DiveComputerKit stops at the first dive recorded before the cutoff, so older
            // dives are never transferred over BLE.
            stopBefore: effectiveCutoff,
            syncClock: syncDeviceClock,
            authorization: BLEPairingProvider(deviceName: connectedDeviceName ?? deviceName,
                                              generation: pairingPrompt.generation)
        )
        DiveComputerLog.shared.log("Session for \(connectedDeviceName ?? deviceName) \(deviceAddress): model \(String(describing: modelSelection))", level: .info)
        diveCountDuringDownload = 0
        sessionWatermark = nil
        let wasStored = DeviceStorage.shared.getStoredDevice(uuid: deviceAddress) != nil
        let handle = bleManager.startSession(request)
        sessionHandle = handle
        Task {
            await runSession(handle, peripheral: peripheral, deviceName: deviceName,
                             modelSelection: modelSelection, cutoff: effectiveCutoff,
                             expectedSerial: expectedSerial, wasStored: wasStored)
        }
        return true
    }

    /// Cancels the running download, if any. Nothing it downloaded is imported and no
    /// watermark is stored.
    func cancelDownload() {
        guard let handle = sessionHandle else { return }
        // The download thread may be waiting for a PIN: release it (or the cancel would wait
        // for an answer that never comes), and refuse this download's request still on its way.
        pairingPrompt.cancelPending()
        pairingPIN = ""
        Task { await handle.cancel() }
    }

    /// Follows one download session to its end.
    private func runSession(_ handle: DeviceSessionHandle, peripheral: DiscoveredDevice, deviceName: String,
                            modelSelection: ModelSelection, cutoff: Date?,
                            expectedSerial: String?, wasStored: Bool) async {
        let deviceAddress = peripheral.identifier.uuidString
        let verifiesSerial = expectedSerial.map(Self.isVerifiableSerial) ?? false
        var downloaded: [DiveData] = []
        var connected = false
        /// The serial reported by a device that is not the expected unit.
        var wrongSerial: String?
        var failure: Error?
        do {
            for try await event in handle.events {
                // The session is being cancelled for the wrong unit: ignore what is still queued.
                if wrongSerial != nil { continue }
                switch event {
                case .connecting:
                    break
                case .connected:
                    connected = true
                    Self.logger.info("Connection established with \(deviceName)")
                    recordOpenedDevice(uuid: deviceAddress, advertisedName: peripheral.name ?? deviceName,
                                       selection: modelSelection)
                    // The connection is confirmed viable, so the new UUID mapping legitimately
                    // supersedes the pruned one: drop the restore without applying it. When the
                    // unit is only guessed, that waits for its serial.
                    if !verifiesSerial { pendingReassociationPruneRestore = nil }
                    syncState = .downloading(current: 0, total: 0)
                case .deviceIdentified(let identity, let fingerprintApplied):
                    Self.logger.info("Device identified: serial \(identity.serial), model \(identity.hardwareModel), fingerprint applied: \(fingerprintApplied)")
                    if verifiesSerial, let expected = expectedSerial {
                        // Reported before any dive is transferred. Checked before anything is
                        // recorded, so the other unit's serial never reaches DeviceStorage.
                        guard Self.isVerifiableSerial(identity.serial),
                              DeviceStorage.normalizedSerial(identity.serial) != DeviceStorage.normalizedSerial(expected) else {
                            DiveComputerLog.shared.log("[Serial check] \(deviceAddress) reported serial \(identity.serial), as expected", level: .info)
                            pendingReassociationPruneRestore = nil
                            recordIdentity(identity, uuid: deviceAddress)
                            break
                        }
                        DiveComputerLog.shared.log("[Serial check] \(deviceAddress) reported serial \(identity.serial), expected \(expected) — another unit; stopping before any dive", level: .warning)
                        wrongSerial = identity.serial
                        Task { await handle.cancel() }
                        break
                    }
                    recordIdentity(identity, uuid: deviceAddress)
                case .progress(let current, let maximum):
                    // Transfer bytes, for the progress bar. The guard keeps a late event from
                    // overwriting a finished state.
                    guard case .downloading = syncState, maximum > 0 else { break }
                    syncState = .downloading(current: Int(current), total: Int(maximum))
                case .dive(let dive):
                    downloaded.append(dive)
                    diveCountDuringDownload = downloaded.count
                case .diveSkipped(let error):
                    Self.logger.warning("A dive could not be read and was skipped: \(String(describing: error))")
                case .clockSync(let result):
                    Self.logger.info("Clock sync: \(String(describing: result))")
                case .finished(let outcome):
                    finishDownload(outcome, downloaded: downloaded, cutoff: cutoff)
                }
            }
        } catch {
            failure = error
        }
        if wrongSerial != nil {
            rejectWrongUnit(deviceAddress: deviceAddress, wasStored: wasStored)
        } else if let failure {
            failDownload(failure as? SessionError ?? .downloadFailed(.io), connected: connected, wasStored: wasStored,
                         deviceName: deviceName, deviceAddress: deviceAddress)
        }
        if sessionHandle === handle { sessionHandle = nil }
    }

    /// A serial that identifies one unit: not empty and not a placeholder some computers
    /// report ("0", "unknown", …).
    nonisolated static func isVerifiableSerial(_ serial: String) -> Bool {
        let key = DeviceStorage.normalizedSerial(serial)
        return !key.isEmpty && !knownSentinelSerials.contains(key)
    }

    /// Ends a session whose device reported another serial than the unit it was taken for
    /// (another computer of the same model was on). Nothing was downloaded or recorded: the
    /// guessed mapping is dropped and the entries pruned for it are put back.
    private func rejectWrongUnit(deviceAddress: String, wasStored: Bool) {
        BLEDiagnosticSession.shared.stop()
        selectedDevice = nil
        let storedThisSession = !wasStored || pendingDeviceStorageSeed?.uuid == deviceAddress
        let expectedName = connectedDeviceName ?? NSLocalizedString("the selected dive computer", bundle: Bundle.forAppLanguage(), value: "the selected dive computer", comment: "Stands for a dive computer's name in 'The connected dive computer is not %@' when the name is unknown.")
        discardPendingSeed()
        // The session's own writes for this identifier (the model it opened with, or an
        // immediate seed); an entry stored before the session is kept.
        if storedThisSession, let all = DeviceStorage.shared.getAllStoredDevices(), all.contains(where: { $0.uuid == deviceAddress }) {
            DeviceStorage.shared.updateStoredDevices(all.filter { $0.uuid != deviceAddress })
            DiveComputerLog.shared.log("[Serial check] Removed the entry stored for \(deviceAddress) during this session", level: .info)
        }
        restorePendingReassociationPrune()
        syncState = .error(message: String(format: NSLocalizedString("The connected dive computer is not %@: it reported another serial number. Nothing was downloaded. Turn off the other dive computer, then try again.", bundle: Bundle.forAppLanguage(), value: "The connected dive computer is not %@: it reported another serial number. Nothing was downloaded. Turn off the other dive computer, then try again.", comment: "Error shown when the app connected to another unit of the same dive computer model than the one expected (e.g. two divers with the same model). %@ is the expected dive computer's name."), expectedName))
    }

    /// Stores the configuration the device opened with, as the former library did: a user
    /// override always; an auto-detected model only for a peripheral not stored yet.
    private func recordOpenedDevice(uuid: String, advertisedName: String, selection: ModelSelection) {
        DiveComputerLog.shared.log("[DeviceStorage] Opened \(uuid) as \(String(describing: selection))", level: .info)
        switch selection {
        case .forced(let family, let model):
            DeviceStorage.shared.storeDevice(uuid: uuid, name: advertisedName, family: family, model: model)
        case .stored:
            break
        case .autoDetect:
            guard DeviceStorage.shared.getStoredDevice(uuid: uuid) == nil,
                  let detected = DeviceCatalog.resolve(advertisedName: advertisedName) else { return }
            DeviceStorage.shared.storeDevice(uuid: uuid, name: advertisedName, family: detected.family, model: detected.modelID)
        }
    }

    /// Records the hardware serial the device reported, and the model it reports when that
    /// is a known model of the same family (e.g. a sibling sharing the advertised name).
    private func recordIdentity(_ identity: DeviceIdentity, uuid: String) {
        DeviceStorage.shared.updateDeviceSerial(uuid: uuid, serial: identity.serial)
        guard let stored = DeviceStorage.shared.getStoredDevice(uuid: uuid),
              identity.hardwareModel != 0, stored.model != identity.hardwareModel,
              DeviceCatalog.model(family: stored.family, modelID: identity.hardwareModel) != nil else { return }
        DeviceStorage.shared.storeDevice(uuid: uuid, name: stored.name, family: stored.family,
                                         model: identity.hardwareModel, serial: identity.serial)
    }

    private func finishDownload(_ outcome: DownloadOutcome, downloaded: [DiveData], cutoff: Date?) {
        Self.logger.info("Retrieval successful: \(downloaded.count) dives (\(String(describing: outcome.kind)))")
        sessionWatermark = outcome.newestFingerprint
        cutoffStopDate = outcome.stoppedAtCutoff ? cutoff : nil

        // The download already stopped at the first dive before the cutoff, so this filter is
        // only a safety net: it drops an older-dated dive that arrived before the stop (e.g. one
        // recorded after a dive-computer clock reset).
        let kept: [DiveData]
        if let cutoff {
            kept = downloaded.filter { $0.datetime >= cutoff }
            cutoffFilteredCount = downloaded.count - kept.count
            cutoffAppliedDate = cutoffFilteredCount > 0 ? cutoff : nil
            Self.logger.info("Import cutoff \(cutoff): kept \(kept.count) of \(downloaded.count) downloaded dive(s), discarded \(downloaded.count - kept.count)")
        } else {
            kept = downloaded
            cutoffFilteredCount = 0
            cutoffAppliedDate = nil
        }

        commitPendingSeed(reportedSerial: outcome.identity?.serial)
        // A device that reported no serial could not be verified; its download succeeded,
        // so the new mapping stands.
        pendingReassociationPruneRestore = nil
        if kept.isEmpty {
            // When nothing was downloaded the device had nothing new to send, and a partial-sync
            // flag carries no meaning; when dives were downloaded but all fell before the cutoff,
            // the partial-sync signal is about real dives that could not be read.
            isPartialSync = downloaded.isEmpty ? false : outcome.kind == .partial
            // No import will run, so store the new watermark now (dives downloaded but all
            // before the cutoff, or a cutoff stop at the newest dive); otherwise the next sync
            // would download the same dives again.
            if !downloaded.isEmpty || cutoff != nil {
                persistFingerprintRecord(for: selectedDevice)
            }
            selectedDevice = nil
            syncState = .completed(imported: 0, merged: 0, skipped: 0)
        } else {
            downloadedDives = kept
            isPartialSync = outcome.kind == .partial
            showingImportConfirmation = true
        }
        // Stopped last, so the trace also records the identifier and watermark written above.
        BLEDiagnosticSession.shared.stop()
    }

    private func failDownload(_ reportedError: SessionError, connected: Bool, wasStored: Bool,
                              deviceName: String, deviceAddress: String) {
        BLEDiagnosticSession.shared.stop()
        selectedDevice = nil
        // A PIN prompt answered with Cancel ends the device open with DC_STATUS_CANCELLED.
        let error: SessionError = reportedError == .deviceOpenFailed(.cancelled) ? .cancelled : reportedError
        if error == .cancelled {
            Self.logger.info("Download cancelled")
            // A reassociation cancelled before the device confirmed its serial: drop the
            // identifier this session stored, and put back the entries removed for it (the
            // restore stays armed only until the serial is confirmed).
            if connected, pendingReassociationPruneRestore != nil,
               !wasStored || pendingDeviceStorageSeed?.uuid == deviceAddress,
               let all = DeviceStorage.shared.getAllStoredDevices(), all.contains(where: { $0.uuid == deviceAddress }) {
                DeviceStorage.shared.updateStoredDevices(all.filter { $0.uuid != deviceAddress })
                DiveComputerLog.shared.log("[Reassociation] Cancelled before the serial check — removed \(deviceAddress)", level: .info)
            }
            discardPendingSeed(matchingUUID: deviceAddress)
            restorePendingReassociationPrune()
            // Back to the known-devices screen, with the full-history options disarmed as
            // when a scan is abandoned (the next tap must not silently re-run them).
            abandonScanSession()
            return
        }
        if !connected {
            Self.logger.error("Failed to connect to \(deviceName): \(String(describing: error))")
            syncState = .error(message: Self.connectionErrorMessage(error, deviceName: deviceName))
            discardPendingSeed(matchingUUID: deviceAddress)
            restorePendingReassociationPrune()
            return
        }
        Self.logger.error("Failed to retrieve dives: \(String(describing: error))")
        syncState = .error(message: String(format: NSLocalizedString("Download failed: %@", bundle: Bundle.forAppLanguage(), value: "Download failed: %@", comment: "Error message shown when downloading dives from the dive computer fails. %@ is the underlying error description."), Self.downloadErrorReason(error)))
        let failedSeedUUID = pendingDeviceStorageSeed?.uuid
        discardPendingSeed()
        // Still armed only when the unit's serial was not verified yet.
        restorePendingReassociationPrune()
        if let failedUUID = failedSeedUUID,
           let allDevices = DeviceStorage.shared.getAllStoredDevices() {
            let filtered = allDevices.filter { $0.uuid != failedUUID }
            if filtered.count < allDevices.count {
                DeviceStorage.shared.updateStoredDevices(filtered)
                Self.logger.info("[BLE] Removed DeviceStorage entry for failed reassociation \(failedUUID.prefix(8))…")
            }
        }
    }

    /// The message for a session that ended before the dive computer was ready.
    static func connectionErrorMessage(_ error: SessionError, deviceName: String) -> String {
        switch error {
        case .bluetoothUnavailable:
            return NSLocalizedString("Bluetooth is off or not available. Turn it on and try again.", bundle: Bundle.forAppLanguage(), value: "Bluetooth is off or not available. Turn it on and try again.", comment: "Error message shown when a dive computer download starts while Bluetooth is off or unavailable.")
        case .busy:
            return NSLocalizedString("Another download is already in progress.", bundle: Bundle.forAppLanguage(), value: "Another download is already in progress.", comment: "Error message shown when a dive computer download is started while another one is running.")
        case .pairingRemoved:
            return String(format: NSLocalizedString("%@ no longer recognizes this device. Forget it in this device's Bluetooth settings, turn Bluetooth on the dive computer off and on, then try again.", bundle: Bundle.forAppLanguage(), value: "%@ no longer recognizes this device. Forget it in this device's Bluetooth settings, turn Bluetooth on the dive computer off and on, then try again.", comment: "Error shown when a dive computer refuses the connection because it no longer has this iPhone's or Mac's Bluetooth pairing (e.g. after pairing with another device). %@ is the dive computer name."), deviceName)
        case .deviceOpenFailed(.noAccess):
            return NSLocalizedString("The dive computer refused the connection. Check the PIN code and try again.", bundle: Bundle.forAppLanguage(), value: "The dive computer refused the connection. Check the PIN code and try again.", comment: "Error message shown when a dive computer that requires a PIN code (e.g. Aqualung i330R) denies access.")
        default:
            return String(format: NSLocalizedString("Unable to connect to %@", bundle: Bundle.forAppLanguage(), value: "Unable to connect to %@", comment: "Error message shown when a Bluetooth connection to a dive computer fails. %@ is the device name."), deviceName)
        }
    }

    /// Why a download failed, completing "Download failed: %@".
    static func downloadErrorReason(_ error: SessionError) -> String {
        let status: DCStatus
        switch error {
        case .downloadFailed(let s), .deviceOpenFailed(let s): status = s
        case .disconnected: status = .io
        default: status = .io
        }
        switch status {
        case .timeout:
            return NSLocalizedString("The dive computer took too long to respond. Try again.", bundle: Bundle.forAppLanguage(), value: "The dive computer took too long to respond. Try again.", comment: "Reason appended to 'Download failed:' when the dive computer stopped answering.")
        case .protocolError:
            return NSLocalizedString("Communication error with the dive computer. Turn it off and on, then try again.", bundle: Bundle.forAppLanguage(), value: "Communication error with the dive computer. Turn it off and on, then try again.", comment: "Reason appended to 'Download failed:' when the dive computer sent unexpected data.")
        case .dataFormat:
            return NSLocalizedString("The dive computer sent data that could not be read.", bundle: Bundle.forAppLanguage(), value: "The dive computer sent data that could not be read.", comment: "Reason appended to 'Download failed:' when the downloaded data is invalid.")
        case .noAccess:
            return NSLocalizedString("The dive computer denied access.", bundle: Bundle.forAppLanguage(), value: "The dive computer denied access.", comment: "Reason appended to 'Download failed:' when the dive computer refuses access.")
        case .unsupported:
            return NSLocalizedString("This operation is not supported by the dive computer.", bundle: Bundle.forAppLanguage(), value: "This operation is not supported by the dive computer.", comment: "Reason appended to 'Download failed:' when the dive computer does not support the operation.")
        case .io, .noDevice:
            return NSLocalizedString("The connection was lost. Keep the dive computer close, turned on and charged.", bundle: Bundle.forAppLanguage(), value: "The connection was lost. Keep the dive computer close, turned on and charged.", comment: "Reason appended to 'Download failed:' when the Bluetooth connection dropped.")
        default:
            return String(format: NSLocalizedString("Unknown error (code %lld).", bundle: Bundle.forAppLanguage(), value: "Unknown error (code %lld).", comment: "Reason appended to 'Download failed:' for an unexpected libdivecomputer status. %lld is the status code."), Int(status.rawValue))
        }
    }

    // MARK: - Seed Lifecycle

    nonisolated static let knownSentinelSerials: Set<String> = ["0", "00000000", "unknown", "n/a"]

    /// - Parameter reportedSerial: the serial the device reported in this session; else the
    ///   one recorded for the seed's identifier is used.
    func commitPendingSeed(reportedSerial sessionSerial: String? = nil) {
        guard let seed = pendingDeviceStorageSeed else { return }
        DiveComputerLog.shared.log("[DeviceStorage] Committing seed \(seed.uuid) for serial \(seed.serial)", level: .info)
        // Verify the hardware serial the device reported matches the fingerprint record.
        // The reported serial was written from the device's own report (recordIdentity stores
        // the DC_EVENT_DEVINFO serial of this connection), so it is ground truth about which physical unit is on the
        // other end of this connection — not our own guess. A mismatch therefore means the
        // reassociation candidate we guessed at was wrong, and the entry already on file is
        // the correct one. Discard our seed and leave DeviceStorage untouched: overwriting or
        // deleting that entry would destroy a correct mapping and break dedup, diver
        // resolution, and watermark persistence for a device that was identified correctly.
        if let reportedSerial = sessionSerial ?? DeviceStorage.shared.getStoredDevice(uuid: seed.uuid)?.serial,
           !reportedSerial.isEmpty,
           reportedSerial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != seed.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            Self.logger.error("[BLE] Serial mismatch at commit — seed=\(seed.serial) reported=\(reportedSerial). Reported serial is ground truth; discarding our seed and keeping the existing DeviceStorage entry unchanged.")
            discardPendingSeed()
            return
        }
        // The advertised name stored when the session opened, when there is one (it keys the
        // Pelagic access code in the Keychain).
        let storedName = DeviceStorage.shared.getStoredDevice(uuid: seed.uuid)?.name ?? seed.name
        DeviceStorage.shared.storeDevice(uuid: seed.uuid, name: storedName, family: seed.family, model: seed.modelID, serial: seed.serial)
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
    func handleDeviceTap(_ peripheral: DiscoveredDevice) {
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
        let bleName = DeviceCatalog.displayName(forAdvertisedName: peripheral.name ?? "")
        Self.logger.info("[Reassociation] UUID \(uuid.prefix(8))… not in DeviceStorage — scanning \(knownDevices.count) fingerprint(s) for '\(bleName)'")
        let diverNames = diverNameBySerial
        // Prefer the user's explicit model override when resolving the peripheral's model.
        // This handles the case where the BLE display name (e.g. "Shearwater Peregrine TX")
        // doesn't match the fingerprint's stored computerName (e.g. "Shearwater Peregrine")
        // but the user has already identified the correct model via the model picker.
        // Falls back to BLE-name resolution for the secondary family+modelID match.
        let resolvedModel = modelOverrides[uuid] ?? DeviceCatalog.supportedModels.first(where: { $0.name == bleName })
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
    func confirmReassociation(_ peripheral: DiscoveredDevice, candidate: ReassociationCandidate) {
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
        // Prune stale DeviceStorage entries for this serial immediately: the old UUID (e.g.
        // left over after an OS Bluetooth deletion + re-pair) must not keep mapping to this
        // serial while the new connection runs. commitPendingSeed would also prune it, but
        // only after a successful download.
        // Runs before the legacy no-family early return below so that path — which also
        // ends in a plain connect — is protected from the same race.
        if !candidate.serial.isEmpty && !Self.knownSentinelSerials.contains(candidate.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
           let allDevices = DeviceStorage.shared.getAllStoredDevices() {
            let filtered = allDevices.filter { !($0.serial?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == candidate.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() && $0.uuid != newUUID) }
            if filtered.count < allDevices.count {
                // Arm the restore before the write, so a failed connection or a device reporting
                // another serial can put these back.
                pendingReassociationPruneRestore = allDevices.filter {
                    $0.serial?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == candidate.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() && $0.uuid != newUUID
                }
                DeviceStorage.shared.updateStoredDevices(filtered)
                DiveComputerLog.shared.log("[Reassociation] Pruned \(allDevices.count - filtered.count) stale DeviceStorage entry/entries for serial \(candidate.serial) before connect", level: .info)
            }
        }

        guard let family = candidate.family else {
            Self.logger.warning("[Reassociation] '\(candidate.computerName)' (serial \(candidate.serial)) has no family/modelID — legacy record, falling back to plain connect")
            connectToDevice(peripheral, displayName: candidate.computerName, expectedSerial: candidate.serial)
            return
        }
        DiveComputerLog.shared.log("[Reassociation] Confirming reassociation: '\(candidate.computerName)' serial=\(candidate.serial) newUUID=\(newUUID.prefix(8))…")
        pendingDeviceStorageSeed = (uuid: newUUID, name: candidate.computerName,
                                    family: family, modelID: candidate.modelID,
                                    serial: candidate.serial)
        if let model = DeviceCatalog.supportedModels.first(where: {
            $0.family == family && $0.modelID == candidate.modelID
        }) {
            Self.logger.info("[Reassociation] Model found in library: '\(model.name)' — modelOverride + forcedModel will be used")
            modelOverrides[newUUID] = model
        } else {
            Self.logger.warning("[Reassociation] Model (family=\(String(describing: family)) modelID=\(candidate.modelID)) not in supportedModels — seed set, no forcedModel hint")
        }
        // Matched by name or model only: the session stops before any dive if the device
        // reports another serial than the candidate's.
        connectToDevice(peripheral, displayName: candidate.computerName, expectedSerial: candidate.serial)
    }

    func clearReassociationState() {
        peripheralPendingReassociation = nil
        peripheralForReassociationPicker = nil
        reassociationCandidates = []
        showingReassociationAlert = false
    }
}
