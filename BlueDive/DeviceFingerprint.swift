import Foundation
import SwiftData
import LibDCSwift

/// Mirrors UserDefaults (DeviceFingerprintStorage) in SwiftData — one record per
/// physical dive computer, keyed by hardware serial number.
///
/// Always holds the latest fingerprint downloaded from that device.
/// Survives app reinstalls and iCloud restores. UserDefaults is the session-level
/// cache used by LibDCSwift during a download; this model is the persistent source
/// of truth that seeds UserDefaults at the start of each sync.
@Model
final class DeviceFingerprint {
    /// Hardware serial number from the dive computer (e.g. "0001a2b3").
    var serial: String = ""

    /// Human-readable device name (e.g. "Shearwater Perdix 2").
    var computerName: String = ""

    /// The latest fingerprint bytes received from this device.
    var fingerprintData: Data = Data()

    /// Device family identifier (e.g. "shearwaterPetrel"), matching
    /// `DeviceConfiguration.DeviceFamily.rawValue`. Persisted so
    /// DeviceStorage can be re-seeded after a reinstall.
    var familyID: String = ""

    /// libdivecomputer model identifier (e.g. 4 for Perdix 2).
    var modelID: UInt32 = 0

    /// When this record was last updated.
    var updatedAt: Date = Date()

    /// Convenience accessor for the typed DeviceFamily enum.
    var family: DeviceConfiguration.DeviceFamily? {
        get { DeviceConfiguration.DeviceFamily(rawValue: familyID) }
        set { familyID = newValue?.rawValue ?? "" }
    }

    init(serial: String, computerName: String, fingerprintData: Data,
         family: DeviceConfiguration.DeviceFamily? = nil, model: UInt32 = 0) {
        self.serial = serial
        self.computerName = computerName
        self.fingerprintData = fingerprintData
        self.familyID = family?.rawValue ?? ""
        self.modelID = model
        self.updatedAt = Date()
    }
}
