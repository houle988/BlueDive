import SwiftUI
import SwiftData
import DiveComputerKit
import os.log

/// Whether `fingerprintFromDatabase` found a sync watermark for the device about to be
/// downloaded. `.restored` means the download will be fingerprint-limited (incremental);
/// `.notFound` means it will be a full-history download.
///
/// The negative case is deliberately *not* spelled `none`: a case of that name shadows
/// `Optional.none` at every `.none` use site involving this type, so a future
/// `FingerprintRestoreResult?` would compile with a silently different meaning.
///
/// Known limitation: `.restored` only means a non-empty fingerprint exists in SwiftData for
/// this serial — not that the device still holds that dive. If the fingerprinted dive was
/// deleted from the computer, its log wrapped around, or the fingerprint was overridden by
/// hand (Settings → Bluetooth Import → Sync Fingerprints), the whole history is downloaded
/// anyway while an armed cutoff is not applied (extra dives kept rather than wanted dives
/// dropped).
enum FingerprintRestoreResult {
    case restored
    case notFound
}

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
        importSaveErrorMessage = nil

        Task { @MainActor in
            var importedCount = 0
            var mergedCount = 0
            var skippedCount = 0
            // New and re-downloaded dives, for the weather fetch offered after the save.
            var weatherCandidates: [(dive: Dive, isNew: Bool)] = []

            // Sort dives chronologically so we can calculate surface intervals
            let sortedDives = downloadedDives.sorted { $0.datetime < $1.datetime }

            // Resolve the diver name once for the entire batch — the same computer is used for all dives.
            let batchDiverName = resolveGearDiverName(forSerial: selectedDevice.flatMap { DeviceStorage.shared.getStoredDevice(uuid: $0.identifier.uuidString)?.serial }, in: modelContext)

            // Find the highest dive number for this diver's bucket so new dives continue their own
            // sequence independently of other divers. Stored diverName values are always trimmed,
            // so pre-trimming the target lets us use a DB-level predicate — no in-memory scan needed.
            let targetDiverName = batchDiverName.trimmingCharacters(in: .whitespaces)
            var diverNumberDescriptor = FetchDescriptor<Dive>(
                predicate: #Predicate<Dive> { dive in
                    dive.diveNumber != nil && dive.diverName == targetDiverName
                },
                sortBy: [SortDescriptor(\Dive.diveNumber, order: .reverse)]
            )
            diverNumberDescriptor.fetchLimit = 1
            let highestDiveNumber = (try? modelContext.fetch(diverNumberDescriptor).first?.diveNumber) ?? 0
            var nextDiveNumber = highestDiveNumber + 1

            // Find the most recent existing dive before the first downloaded dive
            // to calculate the first dive's surface interval
            var previousDiveEndTime: Date? = nil
            if let firstDive = sortedDives.first {
                let beforeFirst = firstDive.datetime
                // Scoped to the same diver as the dive-numbering fetch above: in a shared logbook
                // an unscoped lookup would compute this dive's surface interval against another
                // diver's unrelated dive.
                //
                // But only when a diver is actually resolvable. resolveGearDiverName returns ""
                // for any computer without a matching Gear record — the common case. Scoping on
                // "" would match only dives whose diverName is also "", silently dropping the
                // surface interval for logbooks whose dives carry a real diver name. Fall back to
                // the unscoped lookup there.
                let predicate: Predicate<Dive> = targetDiverName.isEmpty
                    ? #Predicate<Dive> { dive in dive.timestamp < beforeFirst }
                    : #Predicate<Dive> { dive in
                        dive.timestamp < beforeFirst && dive.diverName == targetDiverName
                    }
                var descriptor = FetchDescriptor<Dive>(
                    predicate: predicate,
                    sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
                )
                descriptor.fetchLimit = 1
                if let previousDive = try? modelContext.fetch(descriptor).first {
                    // End time = start time + its computer/file time, else its minutes
                    previousDiveEndTime = previousDive.timestamp.addingTimeInterval(
                        Double(previousDive.consistentDurationSeconds ?? previousDive.duration * 60))
                }
            }

            // Build a fingerprint → Dive index once for the whole batch.
            // Serial is constant across all dives in this sync (same device), so one fetch covers all.
            // #Predicate can't do case-insensitive comparison, so fetch dives with a serial+fingerprint
            // and filter in memory — same pattern as resolveDiverName and the XML import path.
            // The fetch is bounded by the oldest/newest incoming dive ±deduplicationHighConfidenceWindow:
            // any DB dive outside that range cannot match (the dedup window is 24h), so it is safe to
            // exclude. This keeps the fetch small even for logbooks with thousands of dives.
            let normalizedSerial: String? = selectedDevice
                .flatMap { DeviceStorage.shared.getStoredDevice(uuid: $0.identifier.uuidString)?.serial }
                .flatMap { $0.normalizedComputerSerial() }
            let existingDivesByFingerprint: [Data: Dive]
            if let normalizedSerial {
                let lowerBound = sortedDives.first.map { $0.datetime.addingTimeInterval(-deduplicationHighConfidenceWindow) }
                let upperBound = sortedDives.last.map { $0.datetime.addingTimeInterval(deduplicationHighConfidenceWindow) }
                let predicate: Predicate<Dive>
                if let lower = lowerBound, let upper = upperBound {
                    predicate = #Predicate<Dive> {
                        $0.computerSerialNumber != nil &&
                        $0.fingerprintData != nil &&
                        $0.timestamp >= lower &&
                        $0.timestamp <= upper
                    }
                } else {
                    predicate = #Predicate<Dive> {
                        $0.computerSerialNumber != nil &&
                        $0.fingerprintData != nil
                    }
                }
                let candidates = (try? modelContext.fetch(FetchDescriptor<Dive>(predicate: predicate))) ?? []
                existingDivesByFingerprint = Dictionary(
                    candidates.compactMap { d -> (Data, Dive)? in
                        guard d.computerSerialNumber?.normalizedComputerSerial() == normalizedSerial,
                              let fp = d.fingerprintData, !fp.isEmpty else { return nil }
                        return (fp, d)
                    },
                    uniquingKeysWith: { first, _ in first }
                )
            } else {
                existingDivesByFingerprint = [:]
            }

            for (index, diveData) in sortedDives.enumerated() {
                let existingDive: Dive? = diveData.fingerprint.flatMap { fp in
                    fp.isEmpty ? nil : existingDivesByFingerprint[fp]
                }

                if let existingDive {
                    if downloadAllDives {
                        // Re-download mode: merge data from the computer
                        mergeComputerData(from: diveData, into: existingDive, matchReason: "fingerprint + serial")
                        mergedCount += 1
                        weatherCandidates.append((existingDive, false))
                    } else {
                        Self.logger.info("Dive from \(diveData.datetime) skipped — already in logbook (matched by: fingerprint + serial)")
                        skippedCount += 1
                    }
                } else {
                    let dive = convertToBlueDiveDive(diveData, diveNumber: nextDiveNumber, previousDiveEndTime: previousDiveEndTime, diverName: batchDiverName)
                    modelContext.insert(dive)
                    nextDiveNumber += 1
                    importedCount += 1
                    weatherCandidates.append((dive, true))
                }

                // Update previous dive end time for the next iteration
                // End of the dive: the computer's dive time when it reports one, else the last sample (seconds)
                previousDiveEndTime = diveData.datetime.addingTimeInterval(diveData.reportedDivetime ?? diveData.divetime)

                importProgress = Double(index + 1) / Double(total)
            }

            // Save the context
            do {
                try modelContext.save()
                Self.logger.info("Import complete: \(importedCount) imported, \(mergedCount) merged, \(skippedCount) skipped")
                persistFingerprintRecord(for: selectedDevice)
                if UserDefaults.standard.bool(forKey: "notificationsEnabled"),
                   UserDefaults.standard.object(forKey: "milestoneNotifications") as? Bool ?? false {
                    let totalDives = (try? modelContext.fetchCount(FetchDescriptor<Dive>())) ?? 0
                    NotificationManager.shared.notifyMilestoneAchieved(totalDives: totalDives)
                }
            } catch {
                Self.logger.error("Save error: \(error.localizedDescription)")
                // Discard the failed batch's pending inserts — save() does NOT roll them back.
                // downloadedDives and selectedDevice are preserved for an in-session retry.
                modelContext.rollback()
                importProgress = 0
                let reason = String(format: NSLocalizedString("Error saving: %@", bundle: Bundle.forAppLanguage(), value: "Error saving: %@", comment: "Error message shown when saving dives to the logbook fails. %@ is the system error description."), error.localizedDescription)
                importSaveErrorMessage = reason
                showingImportConfirmation = true
                return
            }

            // A merge mutates existing Dive objects in place, so the Dive ID set is unchanged and
            // the @Query re-delivery (DiveDataFeeder) short-circuits in scheduleRebuild's dive-membership check —
            // the list, map, trips and widget would keep the pre-merge values. New inserts do change
            // the ID set, so they need no explicit signal here.
            if mergedCount > 0 {
                store.commitListRebuild()
            }

            downloadedDives = []
            selectedDevice = nil
            connectedDeviceName = nil
            syncState = .completed(imported: importedCount, merged: mergedCount, skipped: skippedCount)
            // After the save, so the dives have their permanent persistent IDs.
            offerWeatherFetch(for: weatherCandidates)
        }
    }

    // MARK: - Weather Fetch After Import

    /// Offers, on the completed screen, to fetch the weather for the just-imported dives that
    /// have GPS coordinates and an empty weather field, when Settings → Online Services allows
    /// it. Nothing is sent until the user chooses Fetch Weather (see pendingWeatherFetch).
    ///
    /// Only empty fields are ever filled. A new dive has no weather yet: its air temperature is
    /// set only from a surface temperature the computer reports
    /// (`DiveData.measuredSurfaceTemperature`), and that reading is kept. A dive downloaded
    /// again is already in the logbook and may hold weather the user entered — as
    /// mergeComputerData preserves user-modified fields (CLAUDE.md: preserve values the user
    /// did not change through the app).
    func offerWeatherFetch(for candidates: [(dive: Dive, isNew: Bool)]) {
        guard UserPreferences.shared.fetchWeatherOnline else {
            Self.logger.info("Weather fetch not offered — Fetch weather online is off (\(candidates.count) dives)")
            return
        }
        // One debug line per dive with the reason (Xcode console only; no coordinates or values).
        var eligible: [(dive: Dive, isNew: Bool)] = []
        var noGPSCount = 0
        var completeCount = 0
        for candidate in candidates {
            let emptyFields = candidate.dive.emptyWeatherFieldNames
            let reason: String
            if OpenMeteoWeatherService.coordinate(for: candidate.dive) == nil {
                noGPSCount += 1
                reason = "not offered — no GPS coordinates"
            } else if !emptyFields.isEmpty {
                eligible.append(candidate)
                reason = "offered (\(candidate.isNew ? "new" : "re-downloaded") dive, empty: \(emptyFields.joined(separator: ", ")))"
            } else {
                completeCount += 1
                reason = "not offered — weather complete"
            }
            Self.logger.info("Dive from \(candidate.dive.timestamp) weather: \(reason, privacy: .public)")
        }
        guard !eligible.isEmpty else {
            Self.logger.info("Weather fetch not offered — no eligible dive (no GPS \(noGPSCount), complete \(completeCount))")
            return
        }
        let newCount = eligible.filter(\.isNew).count
        Self.logger.info("Weather fetch offered for \(eligible.count) of \(candidates.count) dives (new \(newCount), re-downloaded \(eligible.count - newCount); no GPS \(noGPSCount), complete \(completeCount))")
        pendingWeatherFetch = PendingWeatherFetch(ids: eligible.map(\.dive.persistentModelID))
    }

    /// Fetches the weather for the chosen dives, filling empty fields only (see
    /// WeatherBatchFetcher). Closing the sheet cancels the run and keeps what was saved.
    func runWeatherFetch(for ids: [PersistentIdentifier]) {
        let container = modelContext.container
        weatherFetchTask?.cancel()
        weatherFetchStatus = .running(done: 0, total: ids.count)
        weatherFetchTask = Task { @MainActor in
            let result = await WeatherBatchFetcher.run(ids: ids, replaceExistingIDs: [], container: container) {
                weatherFetchStatus = $0
            }
            weatherFetchStatus = result
        }
    }

    // MARK: - Fingerprint Management

    /// Creates or updates the DeviceStorage (UserDefaults) entry for a peripheral from the
    /// persistent DeviceFingerprint record. Called before a sync so that family/model
    /// survive app reinstalls and UserDefaults resets. Also corrects a stale entry whose
    /// family/model disagrees with the DB (e.g. after a model override was saved).
    func seedDeviceStorageFromDatabase(for peripheral: DiscoveredDevice, fingerprint device: DeviceFingerprint) {
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

    /// The stored watermark for the peripheral about to be downloaded, from its
    /// DeviceFingerprint record (SwiftData is the only source; iCloud syncs it).
    ///
    /// The serial comes from DeviceStorage, else from the pending reassociation seed (the new
    /// UUID is written to DeviceStorage only after a successful download). The table passed to
    /// DiveComputerKit holds only that serial's fingerprint, so a download is incremental
    /// exactly when this returns `.restored`: a peripheral whose serial is unknown gets a full
    /// download (its duplicates are skipped at import by fingerprint + serial).
    ///
    /// A record with empty fingerprint bytes (`DeviceFingerprint.fingerprintData` defaults to
    /// `Data()`) is not a watermark and counts as not found.
    func fingerprintFromDatabase(for peripheral: DiscoveredDevice) -> (result: FingerprintRestoreResult, table: [String: Data]) {
        let uuid = peripheral.identifier.uuidString
        let serial: String
        if let storedSerial = DeviceStorage.shared.getStoredDevice(uuid: uuid)?.serial {
            serial = storedSerial
        } else if let seed = pendingDeviceStorageSeed, seed.uuid == uuid, !seed.serial.isEmpty {
            serial = seed.serial
            Self.logger.info("[Reassociation] fingerprintFromDatabase: resolving via seed for serial \(serial)")
        } else {
            Self.logger.debug("Serial unresolvable for peripheral \(uuid.prefix(8))… — full download")
            return (.notFound, [:])
        }

        // Case- and whitespace-insensitive, newest record first (an iCloud merge can leave
        // duplicates under differently-cased serials). The table holds one record per computer.
        let key = serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let records = (try? modelContext.fetch(FetchDescriptor<DeviceFingerprint>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        guard let record = records.first(where: {
            $0.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
        }), !record.fingerprintData.isEmpty else {
            Self.logger.debug("No DB fingerprint for serial \(serial) — full download")
            return (.notFound, [:])
        }
        Self.logger.debug("Using DB fingerprint for serial \(serial) (\(record.fingerprintData.count) bytes)")
        return (.restored, [key: record.fingerprintData])
    }

    // MARK: - Import Date Cutoff

    /// Timestamp of the newest logged dive, restricted to one diver when `diverName` is given.
    /// `nil` when nothing matches. Stored `diverName` values are always trimmed, so the caller's
    /// trimmed value can be compared at the DB level without an in-memory scan.
    private func newestLoggedDiveTimestamp(forDiver diverName: String?) -> Date? {
        var descriptor: FetchDescriptor<Dive>
        if let diverName, !diverName.isEmpty {
            descriptor = FetchDescriptor<Dive>(
                predicate: #Predicate<Dive> { $0.diverName == diverName },
                sortBy: [SortDescriptor(\Dive.timestamp, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<Dive>(
                sortBy: [SortDescriptor(\Dive.timestamp, order: .reverse)]
            )
        }
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.timestamp
    }

    /// Seeds the import-cutoff DatePicker with the timestamp of the newest dive already in
    /// the logbook — the point past which everything on a dive computer is genuinely new —
    /// falling back to one year ago when the logbook is empty. The DatePicker needs a
    /// non-optional Date, so the value is always concrete. Clamped to now because the
    /// picker's range is `...Date()` and a future-dated logged dive would be out of range.
    /// Runs once per sheet session.
    ///
    /// This is the generic seed, used when the dive computer's owner is not knowable: a
    /// never-synced computer has no Gear record to resolve a diver from. The app-wide diver
    /// filter is the closest stand-in available — if the user is working inside one diver's
    /// logbook, that diver's newest dive is a better anchor than whoever happens to have dived
    /// most recently. A filtered diver with zero dives (e.g. a Gear-only diver who hasn't logged
    /// one yet) does NOT fall through to the whole logbook's newest dive — that could belong to
    /// a different diver and be far more recent than anything the filtered diver's own computer
    /// has contributed, silently discarding history on their first sync. It falls to one year
    /// ago instead, the same safe direction `prepareImportCutoffDefault(forDiver:)` below uses
    /// for the identical condition.
    func prepareImportCutoffDefault() {
        guard !importCutoffDateInitialized else { return }
        importCutoffDateInitialized = true

        let now = Date()
        let activeDiverFilter = selectedDiver.trimmingCharacters(in: .whitespaces)
        let newest = activeDiverFilter.isEmpty
            ? newestLoggedDiveTimestamp(forDiver: nil)
            : newestLoggedDiveTimestamp(forDiver: activeDiverFilter)

        if let newest {
            importCutoffDate = min(newest, now)
        } else {
            importCutoffDate = Calendar.current.date(byAdding: .year, value: -1, to: now) ?? now
        }
        Self.logger.debug("Import cutoff default seeded to \(self.importCutoffDate)")
    }

    /// Re-seeds the import cutoff for a known dive computer, scoping the newest-dive lookup to
    /// the diver that computer belongs to. In a shared logbook the generic seed above is simply
    /// wrong: a second diver's more recent dives would push the default past everything this
    /// computer has yet to contribute, silently discarding dives the user wanted.
    ///
    /// Deliberately not gated by `importCutoffDateInitialized` — that one-shot guard exists to
    /// stop the generic seed re-running on every `.onAppear`, whereas this runs at tap time,
    /// knows which device is coming, and is therefore strictly the better guess. The only value
    /// it refuses to overwrite is a date the user picked by hand this session.
    ///
    /// Invariant: once a cutoff has been seeded this session, this re-seed can only move it
    /// EARLIER, never later. A date already rendered in the DatePicker is a commitment even when
    /// the user never touched it — they read it, accepted it, and tapped the device row on that
    /// basis. Moving it later would discard more history than they were shown, which is exactly
    /// the "never alter data behind the user's back" rule. Moving it earlier is always safe: it
    /// only ever keeps more dives. On the first seed of the session there is nothing to clamp
    /// against (`importCutoffDate` still holds its uninitialized `Date()` default, which would
    /// wrongly pin every diver-scoped seed to "now"), so the diver-scoped value is taken as-is.
    func prepareImportCutoffDefault(forDiver diverName: String?) {
        guard !importCutoffDateUserEdited else { return }

        let targetDiverName = diverName?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !targetDiverName.isEmpty else {
            // No diver resolvable for this computer — keep whatever the generic seed produced.
            prepareImportCutoffDefault()
            return
        }

        let alreadySeeded = importCutoffDateInitialized
        importCutoffDateInitialized = true
        let now = Date()
        let candidate: Date
        if let newest = newestLoggedDiveTimestamp(forDiver: targetDiverName) {
            candidate = min(newest, now)
        } else {
            candidate = Calendar.current.date(byAdding: .year, value: -1, to: now) ?? now
        }
        // Clamp against the value already on screen so the re-seed can only ever keep more
        // dives, never fewer — see the invariant above. Skipped on the first seed, where
        // importCutoffDate is still the uninitialized `Date()` (i.e. "now").
        importCutoffDate = alreadySeeded ? min(importCutoffDate, candidate) : candidate
        Self.logger.debug("Import cutoff default seeded to \(self.importCutoffDate) for diver \(targetDiverName)")
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
    func persistFingerprintRecord(for peripheral: DiscoveredDevice?) {
        guard let peripheral,
              let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString),
              let serial = storedDevice.serial else {
            // Leaving here means no DeviceFingerprint record is created or updated, so the next
            // sync finds no watermark in SwiftData and re-downloads the full history. Name the
            // exact missing piece so a diagnostic log can tell the three causes apart.
            if let peripheral {
                let uuidPrefix = peripheral.identifier.uuidString.prefix(8)
                if DeviceStorage.shared.getStoredDevice(uuid: peripheral.identifier.uuidString) == nil {
                    Self.logger.warning("Skipped DeviceFingerprint persist for \(uuidPrefix)… — no DeviceStorage entry for this BLE UUID")
                } else {
                    Self.logger.warning("Skipped DeviceFingerprint persist for \(uuidPrefix)… — DeviceStorage entry has no hardware serial")
                }
            } else {
                Self.logger.warning("Skipped DeviceFingerprint persist — no connected peripheral")
            }
            return
        }

        // The name recorded for a computer seen for the first time: the catalog name of its
        // stored model, else the display name of its advertised name.
        let libraryDeviceType: String
        if let modelInfo = DeviceCatalog.supportedModels.first(where: { $0.modelID == storedDevice.model && $0.family == storedDevice.family }) {
            libraryDeviceType = modelInfo.name
        } else {
            libraryDeviceType = DeviceCatalog.displayName(forAdvertisedName: peripheral.name ?? "Unknown")
        }

        guard let fp = sessionWatermark, !fp.isEmpty else {
            // The download returned no new watermark (no new dives, a partial download with
            // "Download all dives", or no dive at all): the stored one stays as it is.
            Self.logger.warning("Skipped DeviceFingerprint persist — no new watermark for \(libraryDeviceType) (serial: \(serial))")
            return
        }

        let predicate = #Predicate<DeviceFingerprint> { record in record.serial == serial }
        var descriptor = FetchDescriptor<DeviceFingerprint>(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\.updatedAt, order: .reverse)]

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
            let dbFamily: DeviceFamily
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

    /// Deletes a known device: removes the DeviceFingerprint from SwiftData and the
    /// StoredDevice entries (with their Pelagic access codes) from DeviceStorage.
    func deleteKnownDevice(_ device: DeviceFingerprint) {
        let serial = device.serial
        // A sentinel serial (e.g. "0"/"00000000", reported by hardware that doesn't expose a real
        // one) is shared by otherwise-unrelated physical computers, so only a genuine serial is
        // swept; a sentinel removes the single targeted entry.
        if let normalizedSerial = serial.normalizedComputerSerial() {
            // Remove every StoredDevice entry for this serial from DeviceStorage. Duplicate entries
            // under different BLE UUIDs (and differently-cased serials) can exist after past
            // reassociation / deferred-seed activity, so removing only the first match would leave
            // the device silently direct-connectable after the user deleted it.
            if let allDevices = DeviceStorage.shared.getAllStoredDevices() {
                let matching = allDevices.filter { $0.serial?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedSerial }
                if !matching.isEmpty {
                    let matchingUUIDs = Set(matching.map { $0.uuid })
                    let remaining = allDevices.filter { !matchingUUIDs.contains($0.uuid) }
                    DeviceStorage.shared.updateStoredDevices(remaining)
                    matching.forEach { BLEAccessCodeKeychain.delete(forAdvertisedName: $0.name) }
                    Self.logger.info("Removed \(matching.count) DeviceStorage entry/entries for \(device.computerName) (serial: \(serial))")
                }
            }
        } else if let allDevices = DeviceStorage.shared.getAllStoredDevices(),
                  let stored = allDevices.first(where: {
                      $0.serial?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ==
                          serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                  }) {
            // Sentinel/empty serial — remove only the exact single entry this delete targeted,
            // never a fuzzy sweep that could take an unrelated device's mapping with it. The
            // comparison is trimmed/lowercased to match the sibling branch above (StoredDevice
            // serials come from libdivecomputer / hardware and can differ in case or padding from
            // the DeviceFingerprint's copy; an exact `==` would silently find nothing and leave
            // the device direct-connectable after the user deleted it). `normalizedComputerSerial()`
            // is deliberately *not* used here: it returns nil for a sentinel, and this branch runs
            // precisely because the serial *is* a sentinel.
            // Known, accepted residual limitation: when several StoredDevice entries share the same
            // sentinel serial, `first(where:)` cannot guarantee it picks the one actually belonging
            // to *this* DeviceFingerprint — DeviceFingerprint carries no BLE UUID to disambiguate
            // with. This fix only makes the comparison itself correct and stops the UserDefaults
            // side effect from running for sentinels; it does not claim to resolve that ambiguity.
            DeviceStorage.shared.removeDevice(uuid: stored.uuid)
            Self.logger.info("Removed DeviceStorage entry for \(device.computerName) (uuid: \(stored.uuid), sentinel serial — single entry only)")
        }
        // Delete the SwiftData record
        clearAllDeviceFingerprintRecords(for: device)
        try? modelContext.save()
        Self.logger.info("Deleted known device: \(device.computerName) (\(serial))")
    }

    /// Deletes every DeviceFingerprint record for a device's serial (called from `deleteKnownDevice`).
    ///
    /// Fetches the whole table with no predicate and filters in memory: `#Predicate` cannot call
    /// `trimmingCharacters`/`lowercased`, so a DB-level `record.serial == serial` is case- and
    /// whitespace-sensitive and would silently leave an iCloud-merged duplicate record behind
    /// under a differently-cased serial. Same reason `persistFingerprintRecord` and
    /// `fingerprintFromDatabase` sort by `updatedAt` and resolve in Swift. The table holds one
    /// record per physical dive computer, so an unfiltered fetch is cheap (the `knownDevices`
    /// `@Query` in BluetoothScannerView already loads it whole). When the serial is a sentinel
    /// value the serial sweep is skipped entirely and only the single targeted record is deleted.
    private func clearAllDeviceFingerprintRecords(for device: DeviceFingerprint) {
        let serial = device.serial
        if let normalizedSerial = serial.normalizedComputerSerial() {
            let descriptor = FetchDescriptor<DeviceFingerprint>()
            guard let allRecords = try? modelContext.fetch(descriptor) else { return }
            let matching = allRecords.filter { $0.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedSerial }
            matching.forEach { modelContext.delete($0) }
            Self.logger.info("Cleared \(matching.count) DeviceFingerprint record(s) for serial \(serial)")
        } else {
            // Sentinel/empty serial — delete only the exact record the user targeted, never a
            // fuzzy serial sweep that could take an unrelated device's DB record with it. Two
            // different physical computers can both report a sentinel serial like "0" — this
            // mirrors the same narrow-fallback pattern the UserDefaults and DeviceStorage sweeps
            // above already use for this exact reason.
            modelContext.delete(device)
            Self.logger.info("Deleted DeviceFingerprint record for \(device.computerName) (sentinel serial \(serial) — single record only)")
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
        Self.applyDuration(from: diveData, to: dive)

        // Temperatures
        let profileTemperatures = diveData.profile.compactMap { $0.temperature }
        dive.waterTemperature = diveData.temperature.isFinite ? diveData.temperature : nil
        dive.minTemperature = diveData.minTemperature.flatMap { $0.isFinite ? $0 : nil } ?? profileTemperatures.min() ?? (diveData.temperature.isFinite ? diveData.temperature : nil)
        dive.maxTemperature = diveData.maxTemperature.flatMap { $0.isFinite ? $0 : nil } ?? profileTemperatures.max()
        // Only a surface temperature the computer reports (not LibDC-Swift's first-sample
        // fallback), and only into an empty field: it must not overwrite a value fetched from
        // Open-Meteo or entered by the user on an earlier import or edit.
        // LibDC-Swift sets measuredSurfaceTemperature only to a finite value.
        if dive.airTemperature == nil, let surfaceTemp = diveData.measuredSurfaceTemperature {
            dive.airTemperature = surfaceTemp
        }

        // Build tanks with inline gas data from the dive computer.
        // Preserve user-set fields (volume, workingPressure, tankType, tankMaterial) that dive
        // computers typically do not provide. Usage times are derived from the fresh profile by
        // applyGasSwitchUsageTimes below and are intentionally not carried forward here.
        // Also build gasMixToTankIndex: maps gas-mix index (currentGas) to tank array position.
        let dcGasMixes = diveData.gasMixes ?? []
        let existingTanks = dive.tanks
        var mergeMixToTankIndex: [Int: Int] = [:]
        let profileGasMixOrder = Self.orderedGasMixIndices(from: diveData)

        if let dcTanks = diveData.tanks, !dcTanks.isEmpty {
            // Same gas-to-tank assignment as the first download (Shearwater pressure inference
            // included), so a re-download keeps each gas on its transmitter.
            let built = Self.buildTanksFromComputerTanks(
                dcTanks,
                diveData: diveData,
                deviceFamily: connectedDeviceFamily,
                filterUnusedTanks: filterUnusedTanks
            )
            mergeMixToTankIndex = built.gasMixToTankIndex
            // Preserve the identity and user-set fields of the existing tank at the same index
            // (the transmitter slot, then the gas-only tanks in gas-mix order).
            dive.tanks = built.tanks.enumerated().map { (index, tank) in
                let existing = index < existingTanks.count ? existingTanks[index] : nil
                return TankData(
                    id: existing?.id ?? tank.id,
                    o2: tank.o2, he: tank.he,
                    volume: tank.volume ?? existing?.volume,
                    startPressure: tank.startPressure,
                    endPressure: tank.endPressure,
                    workingPressure: tank.workingPressure ?? existing?.workingPressure,
                    tankMaterial: existing?.tankMaterial,
                    tankType: existing?.tankType
                )
            }
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
           let modelInfo = DeviceCatalog.supportedModels.first(where: { $0.modelID == stored.model && $0.family == stored.family }) {
            dive.computerName = modelInfo.name
        } else if let name = connectedDeviceName {
            dive.computerName = name
        }

        // Raw dive computer data
        dive.rawDiveComputerData = diveData.rawData
        dive.fingerprintData = diveData.fingerprint

        // Water type from salinity (g/cm³): ~1.0 = Fresh, ~1.025 = Salt
        if let sal = diveData.salinity {
            dive.siteWaterType = waterType(forSalinity: sal)
        }

        // Surface pressure, only when the computer reports one: a value from an earlier import
        // is kept when this computer records none.
        if let pressure = Dive.validatedSurfacePressure(diveData.atmospheric) {
            dive.surfacePressure = pressure
        }

        // Decompression stops
        dive.decoStops = Self.extractDecoStops(from: diveData)

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

}
