import Foundation

/// Which libdivecomputer model to open the device with.
public enum ModelSelection: Sendable, Equatable {
    /// Chosen by the user in the model picker.
    case forced(DeviceFamily, UInt32)
    /// Remembered from a previous download of this peripheral.
    case stored(DeviceFamily, UInt32)
    /// From the advertised name (`DeviceCatalog.resolve`).
    case autoDetect
}

/// What to download.
public struct SessionRequest: Sendable {
    public var peripheralID: UUID
    /// The advertised name, when known from the scan.
    public var advertisedName: String?
    public var modelSelection: ModelSelection
    /// false = "Download all dives": no fingerprint is applied and none is returned.
    public var useFingerprint: Bool
    /// The newest downloaded dive's fingerprint per computer, keyed by the lowercased
    /// `%08x` serial (`DeviceFingerprint.fingerprintData`). Ignored when `useFingerprint`
    /// is false.
    public var fingerprintsBySerial: [String: Data]
    /// Stop at the first dive older than this date (dives are delivered newest first).
    public var stopBefore: Date?
    /// Set the computer's clock after the download.
    public var syncClock: Bool
    /// PIN / access code for devices that require pairing (Pelagic i330R, Apeks DSX).
    public var authorization: (any BLEAuthorizationProvider)?

    public init(peripheralID: UUID, advertisedName: String? = nil, modelSelection: ModelSelection = .autoDetect,
                useFingerprint: Bool = true, fingerprintsBySerial: [String: Data] = [:], stopBefore: Date? = nil,
                syncClock: Bool = false, authorization: (any BLEAuthorizationProvider)? = nil) {
        self.peripheralID = peripheralID
        self.advertisedName = advertisedName
        self.modelSelection = modelSelection
        self.useFingerprint = useFingerprint
        self.fingerprintsBySerial = fingerprintsBySerial
        self.stopBefore = stopBefore
        self.syncClock = syncClock
        self.authorization = authorization
    }
}

/// The device as identified by libdivecomputer (`DC_EVENT_DEVINFO`).
public struct DeviceIdentity: Sendable, Equatable {
    public let family: DeviceFamily
    /// Model number of the descriptor the device was opened with.
    public let descriptorModel: UInt32
    /// Model number the device reports (may differ from the descriptor's).
    public let hardwareModel: UInt32
    public let firmware: UInt32
    /// Lowercase `%08x` of the reported serial (persisted as `computerSerialNumber`).
    public let serial: String
    /// libdivecomputer's "Vendor Product" of the opened descriptor.
    public let libraryName: String
}

public enum ConnectStep: Sendable, Equatable {
    case connecting
    case openingDevice(attempt: Int)
}

public enum ClockSyncResult: Sendable, Equatable {
    case synced
    /// The computer does not support setting its clock over BLE (normal).
    case unsupported
    case failed(DCStatus)
}

public enum SessionEvent: Sendable {
    case connecting(ConnectStep)
    /// The BLE link and libdivecomputer device are open.
    case connected(ComputerModel?)
    /// `fingerprintApplied`: a stored fingerprint was found for this serial and accepted
    /// by libdivecomputer, so only newer dives are downloaded.
    case deviceIdentified(DeviceIdentity, fingerprintApplied: Bool)
    /// Transfer progress in bytes; `maximum` may be `UInt32.max` until known.
    case progress(current: UInt32, maximum: UInt32)
    /// One parsed dive, newest first; `number` counts from 1.
    case dive(DiveData)
    /// A dive slot whose bytes could not be parsed (skipped).
    case diveSkipped(ParseError)
    case clockSync(ClockSyncResult)
    /// Always the last event of a successful session.
    case finished(DownloadOutcome)
}

/// How a download ended (Docs/BEHAVIOURAL_SPEC.md §5.3).
public struct DownloadOutcome: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case completed
        /// The stored fingerprint matched before any new dive.
        case noNewDives
        /// A protocol error after some dives: those dives are kept; older ones stay
        /// unreachable until a full download (old Mares firmware with corrupt slots).
        case partial
    }

    public let kind: Kind
    public let status: DCStatus
    public let diveCount: Int
    /// The enumeration stopped at `stopBefore`.
    public let stoppedAtCutoff: Bool
    public let fingerprintMatched: Bool
    public let identity: DeviceIdentity?
    /// The fingerprint to store as the new watermark (the newest dive's), or nil when the
    /// watermark must not move (no new dives, or "Download all dives").
    public let newestFingerprint: Data?
}

public enum SessionError: Error, Sendable, Equatable {
    case bluetoothUnavailable(BluetoothState)
    case peripheralNotFound
    case connectionTimeout
    case connectionFailed(String?)
    /// The dive computer no longer has this device's pairing: it must be forgotten in the
    /// Bluetooth settings (and pairing restarted on the dive computer) before it connects.
    case pairingRemoved
    case serviceDiscoveryFailed
    case notificationEnableFailed
    case disconnected
    /// No supported model for this advertised name.
    case unsupportedDevice(String)
    case deviceOpenFailed(DCStatus)
    case downloadFailed(DCStatus)
    case cancelled
    /// A session is already running.
    case busy
}
