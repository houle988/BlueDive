import Foundation
@preconcurrency import CoreBluetooth

/// Bluetooth availability.
public enum BluetoothState: Sendable, Equatable {
    case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn

    init(_ state: CBManagerState) {
        switch state {
        case .resetting: self = .resetting
        case .unsupported: self = .unsupported
        case .unauthorized: self = .unauthorized
        case .poweredOff: self = .poweredOff
        case .poweredOn: self = .poweredOn
        default: self = .unknown
        }
    }
}

/// A dive computer seen while scanning (a Sendable snapshot; `CBPeripheral` never
/// leaves the transport layer).
public struct DiscoveredDevice: Identifiable, Hashable, Sendable {
    /// CoreBluetooth peripheral identifier (stable per device and phone/Mac).
    public let id: UUID
    /// The advertised name; nil for a known peripheral whose name CoreBluetooth has not cached.
    public let name: String?
    public let lastSeen: Date
}

/// Owns the `CBCentralManager`. Every CoreBluetooth call and delegate callback runs on
/// `queue` (never the main queue), so the blocking session thread can wait for
/// callbacks without risking a deadlock.
final class BLECentral: NSObject, CBCentralManagerDelegate, @unchecked Sendable {

    let queue = DispatchQueue(label: "app.bluedive.ble", qos: .userInitiated)
    private var central: CBCentralManager!

    // State below is only touched on `queue`.
    private var state: CBManagerState = .unknown
    private var wantsScan: Bool?                 // pending scan (onlyKnownServices) until powered on
    private var discovered: [UUID: (peripheral: CBPeripheral, device: DiscoveredDevice)] = [:]
    private var links: [UUID: BLEPeripheralLink] = [:]

    /// Decides which named peripherals are listed (set by the manager; called on `queue`).
    /// Only touched on `queue` (set through `setDiscoveryFilter`).
    private var discoveryFilter: @Sendable (UUID, String) -> Bool = { _, name in
        DeviceCatalog.resolve(advertisedName: name) != nil
    }
    var onStateChange: (@Sendable (BluetoothState) -> Void)?
    var onDiscoveredChange: (@Sendable ([DiscoveredDevice]) -> Void)?
    var onScanningChange: (@Sendable (Bool) -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    func setDiscoveryFilter(_ filter: @escaping @Sendable (UUID, String) -> Bool) {
        queue.async { [self] in discoveryFilter = filter }
    }

    // MARK: - Scanning

    func startScanning(onlyKnownServices: Bool) {
        queue.async { [self] in
            guard state == .poweredOn else { wantsScan = onlyKnownServices; return }
            scan(onlyKnownServices: onlyKnownServices)
        }
    }

    func stopScanning() {
        queue.async { [self] in
            wantsScan = nil
            if central.isScanning { central.stopScan() }
            onScanningChange?(false)
        }
    }

    func clearDiscovered() {
        queue.async { [self] in
            discovered.removeAll()
            onDiscoveredChange?([])
        }
    }

    private func scan(onlyKnownServices: Bool) {
        central.scanForPeripherals(withServices: onlyKnownServices ? BLEServiceCatalog.knownServiceUUIDs : nil,
                                   options: nil)
        onScanningChange?(true)
    }

    // MARK: - Peripherals

    /// A discovered peripheral, else one CoreBluetooth already knows (connected or paired
    /// before), as a snapshot.
    func knownDevice(id: UUID) -> DiscoveredDevice? {
        queue.sync {
            if let entry = discovered[id] {
                DiveComputerLog.shared.log("[BLE CONNECT] \(id.uuidString) found in this scan", level: .info)
                return entry.device
            }
            guard let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first else {
                DiveComputerLog.shared.log("[BLE CONNECT] \(id.uuidString) not known to the system", level: .info)
                return nil
            }
            DiveComputerLog.shared.log("[BLE CONNECT] \(id.uuidString) retrieved from the system: " +
                                       "\(peripheral.name ?? "no name"), state \(Self.describe(peripheral.state))", level: .info)
            return DiscoveredDevice(id: id, name: peripheral.name, lastSeen: Date())
        }
    }

    /// A new link for this peripheral, registered for connection callbacks.
    func makeLink(id: UUID, advertisedName: String?) -> BLEPeripheralLink? {
        queue.sync {
            guard let peripheral = discovered[id]?.peripheral
                    ?? central.retrievePeripherals(withIdentifiers: [id]).first else { return nil }
            let name = advertisedName ?? discovered[id]?.device.name ?? peripheral.name ?? ""
            let link = BLEPeripheralLink(central: self, peripheral: peripheral, advertisedName: name)
            links[id] = link
            return link
        }
    }

    var bluetoothState: BluetoothState { queue.sync { BluetoothState(state) } }

    // Called on `queue` by the link.
    func connect(_ peripheral: CBPeripheral) { central.connect(peripheral, options: nil) }
    /// Whether Bluetooth is on (call on `queue`).
    var isPoweredOn: Bool { state == .poweredOn }
    func cancelConnection(_ peripheral: CBPeripheral) { central.cancelPeripheralConnection(peripheral) }
    func unregister(_ id: UUID) { queue.async { [self] in links[id] = nil } }

    static func describe(_ state: CBPeripheralState) -> String {
        switch state {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown (\(state.rawValue))"
        }
    }

    // MARK: - CBCentralManagerDelegate (on `queue`)

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        DiveComputerLog.shared.log("Bluetooth state: \(BluetoothState(central.state))", level: .info)
        onStateChange?(BluetoothState(central.state))
        if central.state == .poweredOn, let onlyKnown = wantsScan {
            wantsScan = nil
            scan(onlyKnownServices: onlyKnown)
        } else if central.state != .poweredOn {
            onScanningChange?(false)
            for link in links.values { link.markDisconnected(error: nil) }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name = peripheral.name ?? advertised, !name.isEmpty else { return }
        let id = peripheral.identifier
        let isNew = discovered[id] == nil
        guard isNew ? discoveryFilter(id, name) : true else { return }
        discovered[id] = (peripheral, DiscoveredDevice(id: id, name: name, lastSeen: Date()))
        if isNew {
            onDiscoveredChange?(discovered.values.map(\.device).sorted { ($0.name ?? "") < ($1.name ?? "") })
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DiveComputerLog.shared.log("[BLE CONNECT] Connected: \(peripheral.identifier.uuidString)", level: .info)
        links[peripheral.identifier]?.handleConnected()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        DiveComputerLog.shared.log("[BLE CONNECT] Failed: \(peripheral.identifier.uuidString): " +
                                   "\(error?.localizedDescription ?? "unknown")", level: .warning)
        links[peripheral.identifier]?.markDisconnected(error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        DiveComputerLog.shared.log("[DISCONNECT] \(peripheral.name ?? "no name") \(peripheral.identifier.uuidString)" +
                                   (error.map { ": \($0.localizedDescription)" } ?? ""), level: .info)
        links[peripheral.identifier]?.markDisconnected(error: error)
    }
}
