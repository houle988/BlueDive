import Foundation
import SwiftData

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

    /// When this record was last updated.
    var updatedAt: Date = Date()

    init(serial: String, computerName: String, fingerprintData: Data) {
        self.serial = serial
        self.computerName = computerName
        self.fingerprintData = fingerprintData
        self.updatedAt = Date()
    }
}
