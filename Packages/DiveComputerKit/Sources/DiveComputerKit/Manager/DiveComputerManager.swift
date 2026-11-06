import Foundation
import Observation

/// A running download. Iterate `events`; the stream ends after `.finished(_)` or throws a
/// `SessionError`.
public final class DeviceSessionHandle: Sendable {
    public let peripheralID: UUID
    public let events: AsyncThrowingStream<SessionEvent, any Error>
    private let session: DeviceSession?

    init(peripheralID: UUID, events: AsyncThrowingStream<SessionEvent, any Error>, session: DeviceSession?) {
        self.peripheralID = peripheralID
        self.events = events
        self.session = session
    }

    /// Cancels the download (nothing is returned for it) and waits until the connection
    /// and every libdivecomputer object are released. Safe at any time, more than once.
    public func cancel() async {
        await session?.cancel()
    }

    /// Waits until the session has fully torn down.
    public func waitUntilFinished() async {
        await session?.waitUntilFinished()
    }
}

/// Scanning and downloads, for the app's views. One session at a time.
@MainActor @Observable
public final class DiveComputerManager {
    public static let shared = DiveComputerManager()

    public private(set) var bluetoothState: BluetoothState = .unknown
    public private(set) var isScanning = false
    /// Named peripherals accepted by `discoveryFilter`, sorted by name.
    public private(set) var discoveredDevices: [DiscoveredDevice] = []
    public private(set) var activeSession: DeviceSessionHandle?

    @ObservationIgnored private let central = BLECentral()

    private init() {
        central.onStateChange = { state in
            Task { @MainActor in DiveComputerManager.shared.bluetoothState = state }
        }
        central.onDiscoveredChange = { devices in
            Task { @MainActor in DiveComputerManager.shared.discoveredDevices = devices }
        }
        central.onScanningChange = { scanning in
            Task { @MainActor in DiveComputerManager.shared.isScanning = scanning }
        }
    }

    /// Which named peripherals are listed while scanning, e.g. "known device, or the
    /// catalog resolves its name". Called on the Bluetooth queue.
    public func setDiscoveryFilter(_ filter: @escaping @Sendable (_ id: UUID, _ name: String) -> Bool) {
        central.discoveryFilter = filter
    }

    /// - Parameter onlyKnownServices: scan only for the dive computer services of
    ///   `BLEServiceCatalog` (some devices do not advertise them; BlueDive scans for all).
    public func startScanning(onlyKnownServices: Bool = false) {
        central.startScanning(onlyKnownServices: onlyKnownServices)
    }

    public func stopScanning() {
        central.stopScanning()
    }

    public func clearDiscoveredDevices() {
        discoveredDevices = []
        central.clearDiscovered()
    }

    /// A peripheral seen in this scan or known to the system (connected or paired before).
    public func knownPeripheral(id: UUID) -> DiscoveredDevice? {
        central.knownDevice(id: id)
    }

    /// Starts connecting and downloading. If a session is running, Bluetooth is off or the
    /// peripheral is unknown, the returned stream throws at once.
    public func startSession(_ request: SessionRequest) -> DeviceSessionHandle {
        let (events, continuation) = AsyncThrowingStream<SessionEvent, any Error>.makeStream()
        func failed(_ error: SessionError) -> DeviceSessionHandle {
            continuation.finish(throwing: error)
            return DeviceSessionHandle(peripheralID: request.peripheralID, events: events, session: nil)
        }
        guard activeSession == nil else { return failed(.busy) }
        let state = central.bluetoothState
        guard state == .poweredOn else { return failed(.bluetoothUnavailable(state)) }
        guard let link = central.makeLink(id: request.peripheralID, advertisedName: request.advertisedName) else {
            return failed(.peripheralNotFound)
        }

        let session = DeviceSession(request: request, link: link, continuation: continuation)
        let handle = DeviceSessionHandle(peripheralID: request.peripheralID, events: events, session: session)
        activeSession = handle
        session.start()
        Task { @MainActor [weak self] in
            await session.waitUntilFinished()
            if self?.activeSession === handle { self?.activeSession = nil }
        }
        return handle
    }
}
