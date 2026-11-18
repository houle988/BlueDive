import Foundation
import DiveComputerKit

/// A dive computer this device has connected to: BLE peripheral identifier → hardware
/// serial and libdivecomputer family/model.
///
/// Stored as JSON under the UserDefaults key `com.libdc.storedDevices`, in the format the
/// former LibDCSwift `DeviceStorage` used (same keys, default `JSONEncoder` dates), so the
/// devices known before the switch to DiveComputerKit keep working. The persistent identity
/// lives in SwiftData (`DeviceFingerprint`); this is the per-installation BLE mapping, which
/// iCloud cannot sync because peripheral identifiers differ per phone/Mac.
struct StoredDevice: Codable, Equatable {
    /// `CBPeripheral.identifier.uuidString`.
    let uuid: String
    /// The advertised BLE name.
    let name: String
    let family: DeviceFamily
    /// libdivecomputer model number.
    let model: UInt32
    let lastConnected: Date
    /// Lowercase `%08x` hardware serial, once a download has reported it.
    let serial: String?
}

/// The app-owned store of `StoredDevice` entries (formerly provided by LibDCSwift).
final class DeviceStorage {
    static let shared = DeviceStorage()

    static let storageKey = "com.libdc.storedDevices"
    private let defaults = UserDefaults.standard

    private init() {}

    /// Every stored device, or nil when none were ever stored (or they cannot be read).
    func getAllStoredDevices() -> [StoredDevice]? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        return try? JSONDecoder().decode([StoredDevice].self, from: data)
    }

    func getStoredDevice(uuid: String) -> StoredDevice? {
        getAllStoredDevices()?.first { $0.uuid == uuid }
    }

    /// Adds or replaces the entry for `uuid`, keeping its serial when none is given.
    func storeDevice(uuid: String, name: String, family: DeviceFamily, model: UInt32, serial: String? = nil) {
        var devices = getAllStoredDevices() ?? []
        let previousSerial = devices.first { $0.uuid == uuid }?.serial
        devices.removeAll { $0.uuid == uuid }
        devices.append(StoredDevice(uuid: uuid, name: name, family: family, model: model,
                                    lastConnected: Date(), serial: serial ?? previousSerial))
        DiveComputerLog.shared.log("[DeviceStorage] Stored \(uuid): \(name), \(family) model \(model), serial \(serial ?? previousSerial ?? "none")", level: .info)
        updateStoredDevices(devices)
    }

    /// Records the hardware serial reported during a download. The device has just reported
    /// it over this identifier, so any other identifier stored for the same serial is stale
    /// (e.g. left by an iOS Bluetooth "Forget This Device") and is removed: one identifier
    /// per serial, so a known-device tap never picks the stale one.
    func updateDeviceSerial(uuid: String, serial: String) {
        guard var devices = getAllStoredDevices(), let index = devices.firstIndex(where: { $0.uuid == uuid }) else { return }
        let old = devices[index]
        if old.serial != serial {
            devices[index] = StoredDevice(uuid: old.uuid, name: old.name, family: old.family, model: old.model,
                                          lastConnected: old.lastConnected, serial: serial)
            DiveComputerLog.shared.log("[DeviceStorage] \(uuid) serial \(old.serial ?? "none") → \(serial)", level: .info)
        }
        let kept = Self.removingOtherIdentifiers(of: serial, keeping: uuid, from: devices)
        guard old.serial != serial || kept.count < devices.count else { return }
        updateStoredDevices(kept)
    }

    /// `devices` without the entries of `serial` under another identifier than `uuid`.
    /// Placeholder serials some computers report ("0", "unknown", …) are shared by
    /// different units, so they never remove anything.
    static func removingOtherIdentifiers(of serial: String, keeping uuid: String, from devices: [StoredDevice]) -> [StoredDevice] {
        let key = normalizedSerial(serial)
        guard !key.isEmpty, !BluetoothScannerView.knownSentinelSerials.contains(key) else { return devices }
        let kept = devices.filter { $0.uuid == uuid || $0.serial.map(normalizedSerial) != key }
        for removed in devices where !kept.contains(where: { $0.uuid == removed.uuid }) {
            DiveComputerLog.shared.log("[DeviceStorage] Removed stale identifier \(removed.uuid) for serial \(key)", level: .info)
        }
        return kept
    }

    nonisolated static func normalizedSerial(_ serial: String) -> String {
        serial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func removeDevice(uuid: String) {
        guard var devices = getAllStoredDevices() else { return }
        if let removed = devices.first(where: { $0.uuid == uuid }) {
            BLEAccessCodeKeychain.delete(forAdvertisedName: removed.name)
        }
        devices.removeAll { $0.uuid == uuid }
        DiveComputerLog.shared.log("[DeviceStorage] Removed \(uuid)", level: .info)
        updateStoredDevices(devices)
    }

    /// Version of the former-library key cleanup already done, so it runs only once.
    private static let formerLibraryKeysCleanupVersionKey = "formerLibraryKeysCleanupVersion"

    /// Removes, once, the fingerprint store the former LibDCSwift library kept in UserDefaults
    /// ("BlueDive", earlier "DeviceFingerprints"), which nothing reads any more: watermarks come
    /// from SwiftData's `DeviceFingerprint`. `storageKey` is kept — it is still the known-device
    /// list. It runs only once so it can never delete a key of the same name added later.
    static func removeFormerLibraryKeys() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: formerLibraryKeysCleanupVersionKey) < 1 else { return }
        for key in ["BlueDive", "DeviceFingerprints"] {
            defaults.removeObject(forKey: key)
        }
        defaults.set(1, forKey: formerLibraryKeysCleanupVersionKey)
    }

    func updateStoredDevices(_ devices: [StoredDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

extension DiscoveredDevice {
    /// Same spelling as `CBPeripheral.identifier`, which the scanner code used before.
    var identifier: UUID { id }
}
