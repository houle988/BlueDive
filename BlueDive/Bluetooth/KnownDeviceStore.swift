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
///
/// Entries this build cannot decode (e.g. a `DeviceFamily` added by a newer build, read here
/// after a downgrade or by another build sharing the defaults) are kept: a read returns the
/// readable entries in order instead of failing as a whole, and every write puts the
/// unreadable ones back after the readable ones, so a newer build's devices survive an older
/// build's saves. An explicit write for the same `uuid` replaces an unreadable entry, and
/// `removeDevice(uuid:)` removes it. Only a JSON object with a string `uuid` is kept; other
/// malformed elements are dropped on the next write. Kept entries are preserved by value
/// (re-serialized), not byte for byte. Only whole entries survive: a field a newer build adds to
/// `StoredDevice` must be optional, and an older build's save drops it. Limitation: kept
/// entries' serials are not visible here, so the serial sweeps (`removingOtherIdentifiers`)
/// and the known-device list never see them. A blob whose top level is not a JSON array still
/// reads as nil, as before.
final class DeviceStorage {
    static let shared = DeviceStorage()

    static let storageKey = "com.libdc.storedDevices"
    private let defaults: UserDefaults
    /// The unreadable-entry count last logged, so a read logs only when it changes.
    private var loggedUnreadableCount = 0

    private convenience init() {
        self.init(defaults: .standard)
    }

    /// For tests: a store over another defaults suite.
    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Every stored device, or nil when none were ever stored (or they cannot be read).
    /// Entries that do not decode are skipped (see the type's comment).
    func getAllStoredDevices() -> [StoredDevice]? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        if let devices = try? JSONDecoder().decode([StoredDevice].self, from: data) {
            loggedUnreadableCount = 0
            return devices
        }
        guard let elements = Self.jsonElements(of: data) else { return nil }
        var devices: [StoredDevice] = []
        var unreadable = 0
        for element in elements {
            if let device = Self.decodeDevice(element) {
                devices.append(device)
            } else {
                unreadable += 1
            }
        }
        if unreadable != loggedUnreadableCount {
            loggedUnreadableCount = unreadable
            DiveComputerLog.shared.log("[DeviceStorage] Kept \(unreadable) unreadable entry/entries (written by another build)", level: .warning)
        }
        return devices
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

    /// Removes the entry for `uuid`, readable or not (an unreadable entry's access code,
    /// whose name is not read, is left in the Keychain).
    func removeDevice(uuid: String) {
        guard var devices = getAllStoredDevices() else { return }
        if let removed = devices.first(where: { $0.uuid == uuid }) {
            BLEAccessCodeKeychain.delete(forAdvertisedName: removed.name)
        }
        let readableCount = devices.count
        devices.removeAll { $0.uuid == uuid }
        let hasUnreadable = unreadableElements().contains { Self.uuid(of: $0) == uuid }
        guard devices.count < readableCount || hasUnreadable else { return }
        DiveComputerLog.shared.log("[DeviceStorage] Removed \(uuid)", level: .info)
        write(devices, droppingUnreadable: Set(devices.map(\.uuid)).union([uuid]))
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

    /// Replaces the stored list with `devices`, keeping the stored entries this build cannot
    /// read (after them) unless `devices` has an entry with the same `uuid`.
    func updateStoredDevices(_ devices: [StoredDevice]) {
        write(devices, droppingUnreadable: Set(devices.map(\.uuid)))
    }

    private func write(_ devices: [StoredDevice], droppingUnreadable uuids: Set<String>) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        let kept = unreadableElements().filter { element in
            Self.uuid(of: element).map { !uuids.contains($0) } ?? true
        }
        guard !kept.isEmpty else {
            defaults.set(data, forKey: Self.storageKey)
            return
        }
        guard let merged = Self.appending(kept, to: data) else { return }
        defaults.set(merged, forKey: Self.storageKey)
    }

    /// The stored array's elements that do not decode as `StoredDevice` but are JSON objects
    /// with a string `uuid` (other malformed elements are not kept); empty when the whole list
    /// decodes, nothing is stored or the top level is not an array.
    private func unreadableElements() -> [Any] {
        guard let data = defaults.data(forKey: Self.storageKey),
              (try? JSONDecoder().decode([StoredDevice].self, from: data)) == nil,
              let elements = Self.jsonElements(of: data) else { return [] }
        return elements.filter { Self.uuid(of: $0) != nil && Self.decodeDevice($0) == nil }
    }

    /// The top-level array's elements, or nil when `data` is not a JSON array.
    private static func jsonElements(of data: Data) -> [Any]? {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [Any]
    }

    private static func decodeDevice(_ element: Any) -> StoredDevice? {
        guard JSONSerialization.isValidJSONObject(element),
              let data = try? JSONSerialization.data(withJSONObject: element) else { return nil }
        return try? JSONDecoder().decode(StoredDevice.self, from: data)
    }

    private static func uuid(of element: Any) -> String? {
        (element as? [String: Any])?["uuid"] as? String
    }

    /// `encoded` (a JSON array from `JSONEncoder`) followed by `elements`, as one array. The
    /// readable entries keep the encoder's exact bytes.
    private static func appending(_ elements: [Any], to encoded: Data) -> Data? {
        guard let extra = try? JSONSerialization.data(withJSONObject: elements),
              encoded.first == UInt8(ascii: "["), encoded.last == UInt8(ascii: "]"),
              extra.first == UInt8(ascii: "["), extra.last == UInt8(ascii: "]") else { return nil }
        guard encoded.count > 2 else { return extra }
        var merged = Data(encoded.dropLast())
        merged.append(UInt8(ascii: ","))
        merged.append(contentsOf: extra.dropFirst())
        return merged
    }
}

extension DiscoveredDevice {
    /// Same spelling as `CBPeripheral.identifier`, which the scanner code used before.
    var identifier: UUID { id }
}
