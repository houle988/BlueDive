import SwiftUI
import SwiftData
import CoreBluetooth
import LibDCSwift
import os.log

/// Whether syncFingerprintFromDatabase found and restored an existing sync watermark for the
/// connected device. `.restored` means the resulting download will be fingerprint-limited
/// (incremental); `.notFound` means it will be a full-history download regardless of the
/// `useFingerprint` flag, since there is nothing for the library to compare against.
///
/// The negative case is deliberately *not* spelled `none`: a case of that name shadows
/// `Optional.none` at every `.none` use site involving this type, so a future
/// `FingerprintRestoreResult?` would compile with a silently different meaning.
///
/// Known limitation (narrowed): `.notFound` from the "serial unresolvable" case (no DeviceStorage
/// entry, no pending seed) can't target a UserDefaults sweep by this connection's own serial,
/// because the (deviceType, serial) key isn't known yet — the library only learns the device's
/// real serial mid-download. Instead, before returning, this case sweeps every UserDefaults entry
/// whose serial has no live DeviceFingerprint record backing it at all — which reliably clears an
/// orphan left behind by a prior delete (`deleteKnownDevice` removes the DB record, so the orphan
/// is unbacked by definition) without touching any other live device's entry, even one cached
/// under a deviceType key that diverges from this app's own resolution. The residual gap is that
/// the sweep only clears *unbacked* entries: any watermark still backed by a live DeviceFingerprint
/// record looks legitimate and survives, yet the library's own lazy lookup can still find and apply
/// it mid-download — turning an intended full-history download incremental. This is not limited to
/// sentinel serials like "0"/"00000000" (see `knownSentinelSerials`), where an unrelated device's
/// entry can genuinely be the one that survives. It applies whenever a peripheral reaches this
/// "serial unresolvable" branch while a *different*, real hardware serial's watermark for the same
/// physical device is still live in the cache — notably `confirmReassociation`'s legacy
/// (no-`family`) path, and "Connect as New Device" on a peripheral whose DeviceStorage entry exists
/// but has `serial == nil` (written by `openBLEDevice` before the hardware serial is known). In
/// those cases the real serial's watermark is correctly left alone by the sweep (a live
/// DeviceFingerprint record still backs it), so the gap is independent of sentinel serials.
/// Accepting it matches the caution already applied everywhere else in this file and in
/// `deleteKnownDevice`, rather than widening the sweep in a way that could touch another device's
/// mapping; closing it properly needs the same `fingerprintMatched` signal described below, and
/// remains out of scope.
///
/// Known limitation (mirror image of the above): `.restored` only means "a non-empty fingerprint
/// was successfully copied out of SwiftData into the cache" — it does *not* guarantee the resulting
/// download will actually be incremental. If the stored fingerprint bytes no longer match anything
/// currently in the device's memory (the fingerprinted dive was deleted from the computer, its log
/// wrapped around, or the user overrode the fingerprint by hand in Settings → Bluetooth Import →
/// Sync Fingerprints), the library finds no match and enumerates the whole history anyway — yet
/// `effectiveCutoff` is still `nil`, because `watermarkRestored` was decided from this DB
/// round-trip alone. An armed cutoff is therefore silently discarded on a download that is in fact
/// full-history: the opposite failure to the case above, and the more benign one (extra dives kept
/// rather than wanted dives dropped). The fix is the same `fingerprintMatched` signal, and remains
/// out of scope.
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
                    // End time = start time + duration (duration is in minutes)
                    previousDiveEndTime = previousDive.timestamp.addingTimeInterval(Double(previousDive.duration) * 60)
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
                    } else {
                        Self.logger.info("Dive from \(diveData.datetime) skipped — already in logbook (matched by: fingerprint + serial)")
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
            // ContentView's @Query re-delivery short-circuits in scheduleRebuild's dive-membership check —
            // the list, map, trips and widget would keep the pre-merge values. New inserts do change
            // the ID set, so they need no explicit signal here.
            if mergedCount > 0 {
                store.commitListRebuild()
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
    ///
    /// Returns `.restored` only when a watermark was actually written to the cache from a
    /// DeviceFingerprint record — the single point at which the upcoming download is known to
    /// be incremental rather than full-history. Every other outcome (no DB record, a DB record
    /// whose fingerprint bytes are empty, or no resolvable serial for this BLE UUID) returns
    /// `.notFound`.
    ///
    /// The empty-bytes case matters because `DeviceFingerprint.fingerprintData` defaults to
    /// `Data()`, and LibDCSwift's own `DeviceFingerprintStorage.getFingerprint` discards empty
    /// fingerprints. Reporting such a record as `.restored` would tell the caller the download
    /// is incremental while the library still sends the entire history — and the cutoff, armed
    /// only for full-history downloads, would silently never apply.
    ///
    /// Why the UserDefaults side-effects sweep by serial instead of touching a single
    /// `(deviceType, serial)` key: the cache is keyed by a *string* device type, and the string
    /// this app computes for a given physical computer is not stable across sessions. It can be
    /// the `supportedModels` display name, `getDeviceDisplayName(from: peripheral.name)`, the
    /// useless `"Unknown"` fallback when `peripheral.name` is still nil pre-connect, or a name
    /// left behind by an earlier user model override / hardware correction. A watermark written
    /// under any one of those remains reachable by the library's own lazy lookup once it resolves
    /// the serial mid-download, so clearing or overwriting just one key can leave a stale
    /// fingerprint live — turning a download this function reported as `.notFound` (and for which
    /// the caller therefore armed the import-date cutoff) into a silently incremental one. Both
    /// branches below are guarded by `normalizedComputerSerial()`: a sentinel or empty serial is
    /// not a device identity, so sweeping on it could conflate two different physical computers,
    /// and those cases fall back to the original single-key behaviour.
    ///
    /// Defense-in-depth only — the "serial unresolvable" early return above still cannot clear
    /// anything, so this does not cover that case. It covers the sessions where the serial *does*
    /// resolve and a diverging-key entry survives from an earlier one.
    func syncFingerprintFromDatabase(for peripheral: CBPeripheral) -> FingerprintRestoreResult {
        let uuid = peripheral.identifier.uuidString

        // Resolve serial and device type. During reassociation the new UUID is not yet in DeviceStorage
        // (written only after a successful download), so fall back to pendingDeviceStorageSeed.
        let serial: String
        let deviceType: String

        if let storedDevice = DeviceStorage.shared.getStoredDevice(uuid: uuid),
           let storedSerial = storedDevice.serial {
            serial = storedSerial
            if let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.modelID == storedDevice.model && $0.family == storedDevice.family }) {
                deviceType = modelInfo.name
            } else {
                deviceType = DeviceConfiguration.getDeviceDisplayName(from: peripheral.name ?? "Unknown")
            }
        } else if let seed = pendingDeviceStorageSeed, seed.uuid == uuid, !seed.serial.isEmpty {
            serial = seed.serial
            if let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.family == seed.family && $0.modelID == seed.modelID }) {
                deviceType = modelInfo.name
            } else {
                deviceType = DeviceConfiguration.getDeviceDisplayName(from: peripheral.name ?? "Unknown")
            }
            Self.logger.info("[Reassociation] syncFingerprintFromDatabase: resolving via seed for serial \(serial)")
        } else {
            // Serial unresolvable pre-connection — this device is either genuinely new, or a
            // stale DeviceStorage/pendingDeviceStorageSeed entry from before a delete. The
            // upcoming download is full-history regardless (isFullHistoryDownload at the call
            // site), so there's no watermark to protect for THIS device. But a stale UserDefaults
            // entry for this exact physical computer's real serial can still survive from before
            // a delete, under some other deviceType key — and be found by the library's own lazy
            // lookup mid-download, silently turning this into an incremental sync. Sweep every
            // UserDefaults entry whose serial has no live record backing it, rather than wiping
            // the whole cache: a live device's entry must survive even under a key that diverges
            // from our own resolution, or that device loses its multi-key mirror and re-downloads
            // its full history on every future sync — see the mirror rationale below.
            //
            // "Backed" means backed by EITHER a DeviceFingerprint record OR a DeviceStorage entry.
            // A device whose (family, modelID) is absent from DeviceConfiguration.supportedModels
            // never gets a DeviceFingerprint record written (persistFingerprintRecord returns
            // silently when getFingerprint can't resolve the library's cached bytes under the
            // app's resolved key), yet its watermark is real and live — backed only by
            // DeviceStorage. Checking the DB alone would delete that device's live watermark.
            //
            // A failed fetch is NOT "no records": treating a thrown error as an empty set would
            // make the sweep below wipe every device's entry, so bail out without touching
            // UserDefaults in that case.
            let dbFingerprintRecords: [DeviceFingerprint]
            do {
                dbFingerprintRecords = try modelContext.fetch(FetchDescriptor<DeviceFingerprint>())
            } catch {
                Self.logger.warning("Serial unresolvable for peripheral \(uuid.prefix(8))… — DeviceFingerprint fetch failed (\(error.localizedDescription)); skipping orphaned UserDefaults fingerprint sweep")
                return .notFound
            }
            var backedSerials = Set(
                dbFingerprintRecords.map { $0.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            )
            for stored in DeviceStorage.shared.getAllStoredDevices() ?? [] {
                if let storedSerial = stored.serial {
                    backedSerials.insert(storedSerial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                }
            }
            var allFingerprints = DeviceFingerprintStorage.shared.loadFingerprints()
            let countBefore = allFingerprints.count
            allFingerprints.removeAll { !backedSerials.contains($0.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
            if allFingerprints.count < countBefore {
                DeviceFingerprintStorage.shared.saveFingerprints(allFingerprints)
                Self.logger.debug("Serial unresolvable for peripheral \(uuid.prefix(8))… — cleared \(countBefore - allFingerprints.count) orphaned UserDefaults fingerprint entry/entries not backed by any DeviceFingerprint record or DeviceStorage entry")
            }
            return .notFound
        }

        let predicate = #Predicate<DeviceFingerprint> { record in record.serial == serial }
        var descriptor = FetchDescriptor<DeviceFingerprint>(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\.updatedAt, order: .reverse)]

        // A record with empty fingerprintData is not a usable watermark — see the note above.
        // It is treated exactly like a missing record so the caller learns the truth.
        let record = try? modelContext.fetch(descriptor).first
        if let record, !record.fingerprintData.isEmpty {
            if let normalizedSerial = serial.normalizedComputerSerial() {
                // Mirror rather than collapse: replace the bytes under EVERY deviceType key this
                // serial is currently cached under, plus our own `deviceType`. Collapsing to the
                // single local `deviceType` would delete a valid, library-reachable entry under a
                // correct key and replace it with a copy under a possibly useless one (`deviceType`
                // is `"Unknown"` whenever `peripheral.name` is nil pre-connect). Every previously
                // reachable lookup path therefore keeps working and now resolves to the DB's bytes.
                var allFingerprints = DeviceFingerprintStorage.shared.loadFingerprints()
                let removedDeviceTypes = allFingerprints
                    .filter { $0.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedSerial }
                    .map { $0.deviceType }
                if !removedDeviceTypes.isEmpty {
                    allFingerprints.removeAll { $0.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedSerial }
                    DeviceFingerprintStorage.shared.saveFingerprints(allFingerprints)
                }
                // A key that was both removed and re-added collapses to one final write.
                var keysToWrite = Set(removedDeviceTypes)
                keysToWrite.insert(deviceType)
                for key in keysToWrite {
                    DeviceFingerprintStorage.shared.saveFingerprint(record.fingerprintData, deviceType: key, serial: serial)
                }
                Self.logger.debug("Overwriting UserDefaults fingerprint under \(keysToWrite.count) deviceType key(s) for \(deviceType) (\(serial)) — DB has \(record.fingerprintData.count) bytes")
            } else {
                // Sentinel or empty serial — not a device identity. Keep the single-key behaviour.
                DeviceFingerprintStorage.shared.saveFingerprint(record.fingerprintData, deviceType: deviceType, serial: serial)
                Self.logger.debug("Overwriting UserDefaults fingerprint for \(deviceType) (\(serial)) — DB has \(record.fingerprintData.count) bytes (sentinel serial — single key only)")
            }
            return .restored
        } else {
            // Pure removal, so no mirroring concern: drop every entry for this serial whatever
            // deviceType key it sits under, so no stale watermark can make the upcoming
            // full-history download silently incremental.
            if let normalizedSerial = serial.normalizedComputerSerial() {
                var allFingerprints = DeviceFingerprintStorage.shared.loadFingerprints()
                let beforeCount = allFingerprints.count
                allFingerprints.removeAll { $0.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedSerial }
                if allFingerprints.count < beforeCount {
                    DeviceFingerprintStorage.shared.saveFingerprints(allFingerprints)
                    Self.logger.debug("Cleared \(beforeCount - allFingerprints.count) UserDefaults fingerprint entry/entries for serial \(serial) (serial-only sweep, any deviceType key)")
                }
            } else {
                // Sentinel or empty serial — not a device identity. Keep the single-key behaviour.
                DeviceFingerprintStorage.shared.clearFingerprint(forDeviceType: deviceType, serial: serial)
            }
            if record != nil {
                Self.logger.debug("DB fingerprint record for \(deviceType) (\(serial)) has no bytes — clearing UserDefaults")
            } else {
                Self.logger.debug("No DB fingerprint for \(deviceType) (\(serial)) — clearing UserDefaults")
            }
            return .notFound
        }
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
    func persistFingerprintRecord(for peripheral: CBPeripheral?) {
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

        // The fingerprint is always keyed by the library's auto-detected device type.
        let libraryDeviceType: String
        if let modelInfo = DeviceConfiguration.supportedModels.first(where: { $0.modelID == storedDevice.model && $0.family == storedDevice.family }) {
            libraryDeviceType = modelInfo.name
        } else {
            libraryDeviceType = DeviceConfiguration.getDeviceDisplayName(from: peripheral.name ?? "Unknown")
        }

        guard let fp = DeviceFingerprintStorage.shared.getFingerprint(forDeviceType: libraryDeviceType, serial: serial)?.fingerprint else {
            // The library writes its watermark to the UserDefaults cache as it downloads; nothing
            // there means there are no fingerprint bytes to copy into SwiftData, so no record is
            // created or updated and the next sync re-downloads the full history.
            Self.logger.warning("Skipped DeviceFingerprint persist — no cached fingerprint for \(libraryDeviceType) (serial: \(serial))")
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
        // UserDefaults watermark removal happens *only* on the non-sentinel path below, and is
        // deliberately not done before this branch. A single-key clear keyed by
        // (device.computerName, serial) looks harmless, but `computerName` is a shared
        // model-display name (e.g. "Aqualung i300C"), not a per-unit nickname: two different
        // physical computers of the same model that both report a sentinel serial (e.g. "0") share
        // one identical (deviceType, serial) key, so clearing it while deleting one would wipe the
        // survivor's watermark too — exactly the cross-device damage the sentinel branch below
        // exists to avoid. On the non-sentinel path the single-key clear is kept purely for its
        // log breadcrumb; the serial-only sweep immediately after it removes a strict superset of
        // what it removes.
        // That sweep is needed because a single deviceType key is never sufficient: the same serial
        // can also be cached under a different deviceType string (libdivecomputer's raw descriptor
        // name, a user override, or a stale pre-correction name) — see the note on
        // syncFingerprintFromDatabase above. Sweeping by serial alone ensures no watermark survives
        // the delete under any key — but only when the serial is a genuine device identity. A
        // sentinel serial (e.g. "0"/"00000000", reported by hardware that doesn't expose a real
        // one) is shared by otherwise-unrelated physical computers, so widening the sweep to "any
        // entry with this serial" would take another device's watermark and DeviceStorage mapping
        // with it. On a sentinel, fall back to the narrow, single-entry DeviceStorage removal this
        // function used before the sweep existed, and leave UserDefaults untouched.
        if let normalizedSerial = serial.normalizedComputerSerial() {
            // Clear UserDefaults fingerprint cache (computerName matches the key used by DeviceFingerprintStorage)
            DeviceFingerprintStorage.shared.clearFingerprint(forDeviceType: device.computerName, serial: serial)
            var allFingerprints = DeviceFingerprintStorage.shared.loadFingerprints()
            let fingerprintCountBefore = allFingerprints.count
            allFingerprints.removeAll { $0.serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedSerial }
            if allFingerprints.count < fingerprintCountBefore {
                DeviceFingerprintStorage.shared.saveFingerprints(allFingerprints)
                Self.logger.info("Cleared \(fingerprintCountBefore - allFingerprints.count) UserDefaults fingerprint entry/entries for serial \(serial) (serial-only sweep, any deviceType key)")
            }
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
    /// `syncFingerprintFromDatabase` sort by `updatedAt` and resolve in Swift. The table holds one
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
        dive.duration = Int(diveData.divetime / 60)

        // Temperatures
        let profileTemperatures = diveData.profile.compactMap { $0.temperature }
        dive.waterTemperature = diveData.temperature.isFinite ? diveData.temperature : nil
        dive.minTemperature = diveData.minTemperature.flatMap { $0.isFinite ? $0 : nil } ?? profileTemperatures.min() ?? (diveData.temperature.isFinite ? diveData.temperature : nil)
        dive.maxTemperature = diveData.maxTemperature.flatMap { $0.isFinite ? $0 : nil } ?? profileTemperatures.max()
        if let surfaceTemp = diveData.surfaceTemperature, surfaceTemp.isFinite {
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
            dive.siteWaterType = waterType(forSalinity: sal)
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
