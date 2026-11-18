import Foundation
import SwiftData
import DiveComputerKit

/// One record per physical dive computer, keyed by hardware serial number: the sync
/// watermark (the newest downloaded dive's libdivecomputer fingerprint) and the device's
/// identity. Survives app reinstalls and iCloud restores; it is the only source of the
/// fingerprint DiveComputerKit is given at the start of each download.
@Model
final class DeviceFingerprint {
    /// Hardware serial number from the dive computer (e.g. "0001a2b3").
    var serial: String = ""

    /// Human-readable device name (e.g. "Shearwater Perdix 2").
    var computerName: String = ""

    /// The latest fingerprint bytes received from this device.
    var fingerprintData: Data = Data()

    /// Device family identifier (e.g. "shearwaterPetrel"), matching
    /// `DeviceFamily.rawValue`. Persisted so
    /// DeviceStorage can be re-seeded after a reinstall.
    var familyID: String = ""

    /// libdivecomputer model identifier (e.g. 11 for Perdix 2).
    var modelID: UInt32 = 0

    /// When this record was last updated.
    var updatedAt: Date = Date()

    /// Convenience accessor for the typed DeviceFamily enum.
    var family: DeviceFamily? {
        get { DeviceFamily(rawValue: familyID) }
        set { familyID = newValue?.rawValue ?? "" }
    }

    init(serial: String, computerName: String, fingerprintData: Data,
         family: DeviceFamily? = nil, model: UInt32 = 0) {
        self.serial = serial
        self.computerName = computerName
        self.fingerprintData = fingerprintData
        self.familyID = family?.rawValue ?? ""
        self.modelID = model
        self.updatedAt = Date()
    }
}
