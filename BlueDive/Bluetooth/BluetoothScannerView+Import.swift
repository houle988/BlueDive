import SwiftUI
import SwiftData
import CoreBluetooth
import LibDCSwift
import os.log

// MARK: - Import & Fingerprint

extension BluetoothScannerView {

    // MARK: - Import Dives

    func importDownloadedDives() {
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

            // Resolve the diver name once for the entire batch — the same computer is used for all dives.
            let batchDiverName = resolveDiverName(forSerial: selectedDevice.flatMap { DeviceStorage.shared.getStoredDevice(uuid: $0.identifier.uuidString)?.serial })

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
                    let dive = convertToBlueDiveDive(diveData, diveNumber: nextDiveNumber, previousDiveEndTime: previousDiveEndTime, diverName: batchDiverName)
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

    // MARK: - Fingerprint Management

    /// Creates or updates the DeviceStorage (UserDefaults) entry for a peripheral from the
    /// persistent DeviceFingerprint record. Called before a sync so that family/model
    /// survive app reinstalls and UserDefaults resets. Also corrects a stale entry whose
    /// family/model disagrees with the DB (e.g. after a model override was saved).
    func seedDeviceStorageFromDatabase(for peripheral: CBPeripheral, fingerprint device: DeviceFingerprint) {
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
    func syncFingerprintFromDatabase(for peripheral: CBPeripheral) {
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
    func deleteKnownDevice(_ device: DeviceFingerprint) {
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

    // MARK: - Duplicate Check

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

    // MARK: - Merge

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

        // Build tanks with inline gas data from LibDCSwift.
        // Preserve user-set fields (volume, workingPressure, tankType, tankMaterial) that dive
        // computers typically do not provide. Usage times are derived from the fresh profile by
        // applyGasSwitchUsageTimes below and are intentionally not carried forward here.
        // Also build gasMixToTankIndex: maps gas-mix index (currentGas) to tank array position.
        let dcGasMixes = diveData.gasMixes ?? []
        let existingTanks = dive.tanks
        var mergeMixToTankIndex: [Int: Int] = [:]
        let profileGasMixOrder = Self.orderedGasMixIndices(from: diveData)

        if let dcTanks = diveData.tanks, !dcTanks.isEmpty {
            var tanks: [TankData] = []
            for (index, tank) in dcTanks.enumerated() {
                let (o2, he, resolvedMixIdx) = Self.resolveGasMix(
                    mixIndex: tank.gasMix,
                    tankIndex: index,
                    tankCount: dcTanks.count,
                    tankUsage: tank.usage,
                    dcGasMixes: dcGasMixes,
                    profileGasMixOrder: profileGasMixOrder,
                    deviceFamily: connectedDeviceFamily,
                    headerGasMix: diveData.gasMix
                )
                if let resolved = resolvedMixIdx, mergeMixToTankIndex[resolved] == nil { mergeMixToTankIndex[resolved] = index }
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
            mergeMixToTankIndex[0] = 0
        } else if !dcGasMixes.isEmpty {
            // No tank data but we have gas mixes — store them as tanks with gas only
            let needsFilter = filterUnusedTanks && (connectedDeviceFamily.map { Self.familiesNeedingSwiftTankFilter.contains($0) } ?? true)
            let usedMixes = needsFilter ? Self.usedGasMixIndices(from: diveData) : nil
            // existingIdx walks existingTanks in lockstep with the filtered output.
            // If filterUnusedTanks was toggled between imports, the shapes may differ and
            // user-set fields (volume, tankMaterial, etc.) could land on the wrong tank.
            var existingIdx = 0
            var tankIdx = 0
            dive.tanks = dcGasMixes.enumerated().compactMap { (index, mix) in
                if let used = usedMixes {
                    guard used.contains(index) else { return nil }
                }
                let existing = existingIdx < existingTanks.count ? existingTanks[existingIdx] : nil
                existingIdx += 1
                mergeMixToTankIndex[index] = tankIdx
                tankIdx += 1
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
            mergeMixToTankIndex[0] = 0
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
        // currentGas is remapped from gas-mix index to tank-array index before storage.
        dive.profileSamples = Self.remapProfileCurrentGas(
            Self.consolidateProfilePoints(diveData.profile),
            using: mergeMixToTankIndex)
        let mergeInitialGasMixIndex = profileGasMixOrder.first
        dive.tanks = Self.applyGasSwitchUsageTimes(
            to: dive.tanks,
            gasMixToTankIndex: mergeMixToTankIndex,
            initialGasMixIndex: mergeInitialGasMixIndex,
            profileSamples: dive.profileSamples
        )

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

        if let entryLoc = diveData.location,
           (-90...90).contains(entryLoc.latitude),
           (-180...180).contains(entryLoc.longitude),
           !(entryLoc.latitude == 0 && entryLoc.longitude == 0) {
            dive.siteLatitude = entryLoc.latitude
            dive.siteLongitude = entryLoc.longitude
        }
        if let exitLoc = diveData.exitLocation,
           (-90...90).contains(exitLoc.latitude),
           (-180...180).contains(exitLoc.longitude),
           !(exitLoc.latitude == 0 && exitLoc.longitude == 0) {
            dive.exitLatitude = exitLoc.latitude
            dive.exitLongitude = exitLoc.longitude
        }

        // Override source import to reflect the Bluetooth re-download
        dive.sourceImport = "Bluetooth"

        Self.logger.info("Dive from \(dive.timestamp) merged with computer data (matched by: \(matchReason))")
    }

    // MARK: - Diver Name

    /// Returns the diver name to stamp on a Bluetooth-downloaded dive.
    ///
    /// Looks for a gear item of category "Computer" whose serial number matches the connected device.
    /// Serial comparison is whitespace-trimmed and case-insensitive to handle firmware padding and
    /// user-entry differences. If multiple computers share the same serial but disagree on the diver
    /// name (ambiguous ownership), falls back to the profile name. Falls back to the profile name
    /// when no matching gear is found or the fetch fails.
    private func resolveDiverName(forSerial computerSerial: String?) -> String {
        let profileName = (UserDefaults.standard.string(forKey: "userName") ?? "").trimmingCharacters(in: .whitespaces)
        guard let rawSerial = computerSerial else { return profileName }
        let serial = rawSerial.trimmingCharacters(in: .whitespaces)
        guard !serial.isEmpty else { return profileName }

        let computerCategory = GearCategory.computer.rawValue
        // #Predicate cannot call instance methods, so fetch all computers and filter in-memory
        // to apply trimmed case-insensitive serial comparison.
        let predicate = #Predicate<Gear> { gear in
            gear.category == computerCategory && gear.serialNumber != nil
        }
        do {
            let computers = try modelContext.fetch(FetchDescriptor<Gear>(predicate: predicate))
            let matches = computers.filter {
                ($0.serialNumber ?? "").trimmingCharacters(in: .whitespaces)
                    .caseInsensitiveCompare(serial) == .orderedSame
                    && !$0.diverName.trimmingCharacters(in: .whitespaces).isEmpty
            }
            let distinctNames = Set(matches.map { $0.diverName.trimmingCharacters(in: .whitespaces) })
            if distinctNames.count == 1, let name = distinctNames.first {
                return name
            }
            if distinctNames.count > 1 {
                Self.logger.warning("Multiple gear computers match serial \(serial) with different diver names — falling back to profile name")
            }
        } catch {
            Self.logger.error("Failed to look up gear for computer serial \(serial): \(error.localizedDescription)")
        }
        return profileName
    }
}
