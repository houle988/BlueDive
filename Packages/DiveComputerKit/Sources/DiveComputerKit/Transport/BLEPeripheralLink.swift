import Foundation
@preconcurrency import CoreBluetooth

/// Why a connection could not be set up.
enum LinkOpenError: Error, Sendable, Equatable {
    case connectionTimeout
    case connectionFailed(String?)
    /// The dive computer no longer has the pairing this device offers
    /// (`CBError.peerRemovedPairingInformation`).
    case pairingRemoved
    case serviceDiscoveryFailed
    case notificationEnableFailed
    case disconnected
    case cancelled
}

/// One BLE connection to a dive computer, used as libdivecomputer's byte pipe.
///
/// The session thread calls the blocking methods (`open`, `read`, `write`, …); the
/// CoreBluetooth callbacks arrive on the central's queue. Shared state is guarded by a
/// single `NSCondition`; CoreBluetooth objects are only touched on the central's queue.
final class BLEPeripheralLink: NSObject, CBPeripheralDelegate, SessionLink, @unchecked Sendable {

    private unowned let central: BLECentral
    private let peripheral: CBPeripheral
    let advertisedName: String
    var peripheralID: UUID { peripheral.identifier }

    private let condition = NSCondition()
    // Guarded by `condition`:
    private var connected = false
    private var connectError: Error?
    private var didFail = false
    private var cancelled = false
    /// Set by `prepareForClose()`: the device is being closed; a cancel no longer refuses writes.
    private var closing = false
    /// The session was cancelled before or during the close: reads are kept short.
    private var closingAfterCancel = false
    /// Set when this link asks CoreBluetooth to connect. A disconnect or failure reported
    /// before that belongs to the peripheral's previous connection (a slow teardown) and
    /// must not fail this one.
    private var connectIssued = false
    /// The error of the last disconnect of this connection (after `didConnect`).
    private var lastDisconnectError: Error?
    private var preferredService: CBUUID?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var characteristicsByUUID: [String: CBCharacteristic] = [:]
    private var notifying = false
    private var packets = BLEPacketQueue()
    /// Set when a read first returns data (`takeQueued`): notifications dropped unread (a
    /// purge) do not end the first-read floor.
    private var readReturnedData = false
    /// When the last data notification arrived.
    private var lastPacketAt = Date.distantPast
    private var timeoutMilliseconds: Int32 = -1
    private var pendingWriteCallbacks = 0
    private var lastWriteError: Error?
    private var readyToWrite = false
    private var ioctlRoute: String?
    private var ioctlValue: Data?

    init(central: BLECentral, peripheral: CBPeripheral, advertisedName: String) {
        self.central = central
        self.peripheral = peripheral
        self.advertisedName = advertisedName
        super.init()
    }

    private var queue: DispatchQueue { central.queue }

    private func withLock<T>(_ body: () -> T) -> T {
        condition.lock(); defer { condition.unlock() }
        return body()
    }

    /// Waits (lock held) until `done` or the deadline; false on timeout.
    private func wait(until deadline: Date, while pending: () -> Bool) -> Bool {
        while pending() {
            if !condition.wait(until: deadline) { return !pending() }
        }
        return true
    }

    var isConnected: Bool { withLock { connected } }

    // MARK: - Open (session thread)

    func open() throws(LinkOpenError) {
        let id = peripheral.identifier.uuidString
        DiveComputerLog.shared.log("[BLE CONNECT] Opening \(advertisedName) \(id), state " +
                                   "\(BLECentral.describe(queue.sync { peripheral.state }))", level: .info)
        do {
            try openSteps()
        } catch {
            DiveComputerLog.shared.log("[BLE CONNECT] Open failed for \(id): \(error)", level: .warning)
            throw error
        }
    }

    private func openSteps() throws(LinkOpenError) {
        // A reused CBPeripheral may still be tearing down a previous connection.
        let start = Date()
        while queue.sync(execute: { peripheral.state }) != .disconnected {
            if Date().timeIntervalSince(start) >= BLETiming.disconnectedStateWait {
                DiveComputerLog.shared.log("[BLE CONNECT] Peripheral not disconnected after 5 s; connecting anyway", level: .warning)
                break
            }
            sleep(milliseconds: UInt32(BLETiming.disconnectedStatePoll * 1000))
            if withLock({ cancelled }) { throw .cancelled }
        }

        queue.async { [self] in
            // Bluetooth turned off before the connect: fail now (CoreBluetooth would never
            // answer a connect on a central that is not powered on).
            guard central.isPoweredOn else {
                withLock { connectIssued = true; didFail = true; connectError = nil; condition.broadcast() }
                return
            }
            // On the central's queue, so every callback of the previous connection already
            // delivered is ignored, and every later one is this connection's.
            withLock { didFail = false; connectError = nil; connectIssued = true }
            peripheral.delegate = self
            central.connect(peripheral)
        }
        DiveComputerLog.shared.log("[BLE CONNECT] Connect requested", level: .info)
        let connectedInTime = withLock {
            wait(until: Date(timeIntervalSinceNow: BLETiming.connectWait)) { !connected && !didFail && !cancelled }
        }
        let afterConnect = withLock { (cancelled, didFail, connectError) }
        if afterConnect.0 { throw .cancelled }
        if afterConnect.1 {
            if let error = afterConnect.2 as? CBError, error.code == .peerRemovedPairingInformation {
                throw .pairingRemoved
            }
            throw .connectionFailed(afterConnect.2?.localizedDescription)
        }
        if !connectedInTime { throw .connectionTimeout }

        queue.async { [self] in peripheral.discoverServices(nil) }
        let discovered = withLock {
            wait(until: Date(timeIntervalSinceNow: BLETiming.discoveryWait)) {
                (writeCharacteristic == nil || notifyCharacteristic == nil) && connected && !cancelled
            }
        }
        let afterDiscovery = withLock { (cancelled, connected, writeCharacteristic != nil, notifyCharacteristic) }
        if afterDiscovery.0 { throw .cancelled }
        if !afterDiscovery.1 { throw disconnectedError() }
        guard discovered, afterDiscovery.2, let notify = afterDiscovery.3 else { throw .serviceDiscoveryFailed }
        let chosen = withLock { (preferredService?.uuidString, writeCharacteristic?.uuid.uuidString) }
        DiveComputerLog.shared.log("[BLE CONNECT] Service \(chosen.0 ?? "none preferred"), write \(chosen.1 ?? "?"), " +
                                   "notify \(notify.uuid.uuidString)", level: .info)

        queue.async { [self] in peripheral.setNotifyValue(true, for: notify) }
        let enabled = withLock {
            wait(until: Date(timeIntervalSinceNow: BLETiming.notifyEnableWait)) { !notifying && connected && !cancelled }
        }
        let afterNotify = withLock { (cancelled, connected) }
        DiveComputerLog.shared.log("[BLE CONNECT] Notifications \(enabled ? "enabled" : "not enabled") after " +
                                   "\(String(format: "%.1f", Date().timeIntervalSince(start))) s from open", level: .info)
        if afterNotify.0 { throw .cancelled }
        if !afterNotify.1 { throw disconnectedError() }
        if !enabled { throw .notificationEnableFailed }
        DiveComputerLog.shared.log("[BLE CONNECT] Ready: \(advertisedName)", level: .info)
    }

    /// Why the link dropped while it was being set up: some dive computers accept the link
    /// and only refuse the encryption a step later (service discovery or notifications), with
    /// the same "pairing removed" error a failed connect reports.
    private func disconnectedError() -> LinkOpenError {
        let error = withLock { lastDisconnectError }
        if let error = error as? CBError, error.code == .peerRemovedPairingInformation { return .pairingRemoved }
        return .disconnected
    }

    // MARK: - DiveComputerLink (session thread)

    var readTimeoutMilliseconds: Int32 { withLock { timeoutMilliseconds } }

    func setReadTimeout(milliseconds: Int32) {
        let old = withLock { () -> Int32 in let old = timeoutMilliseconds; timeoutMilliseconds = milliseconds; return old }
        if old != milliseconds {
            DiveComputerLog.shared.log("[BLE TIMEOUT] \(old) → \(milliseconds) ms", level: .debug)
        }
    }

    func read(maximum: Int) -> LinkRead {
        condition.lock(); defer { condition.unlock() }
        let poll = timeoutMilliseconds == 0
        var timeout = timeoutMilliseconds < 0 ? BLETiming.defaultReadTimeout : TimeInterval(timeoutMilliseconds) / 1000
        if !poll && !readReturnedData { timeout = max(timeout, BLETiming.firstReadFloor) }
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        while true {
            if cancelled { return .cancelled }
            if let data = takeQueued(maximum: maximum) { return .data(data) }
            if !connected { return .failed }
            // A cancel during the close (closingAfterCancel) shortens a read already waiting.
            let limit = closingAfterCancel
                ? min(deadline, start.addingTimeInterval(BLETiming.closeAfterCancelReadLimit)) : deadline
            if poll || !condition.wait(until: limit) {
                if let data = takeQueued(maximum: maximum) { return .data(data) }
                if !connected { return .failed }
                DiveComputerLog.shared.log("[BLE READ] Timeout after \(limit.timeIntervalSince(start)) s (\(maximum) bytes requested)", level: .debug)
                return .timeout
            }
        }
    }

    /// The next queued bytes; the first data returned ends the first-read floor. Call with
    /// the lock held.
    private func takeQueued(maximum: Int) -> Data? {
        guard let data = packets.take(maximum: maximum) else { return nil }
        readReturnedData = true
        return data
    }

    func write(_ data: Data) -> LinkWrite {
        guard let characteristic = withLock({ writeCharacteristic }) else { return .failed }
        DiveComputerLog.shared.logPacket(.outbound, data: data, characteristicUUID: characteristic.uuid.uuidString)

        if characteristic.properties.contains(.writeWithoutResponse) {
            let canSend = queue.sync { peripheral.canSendWriteWithoutResponse }
            if !canSend {
                let ready = withLock {
                    readyToWrite = false
                    return wait(until: Date(timeIntervalSinceNow: BLETiming.writeWithoutResponseBackpressure)) {
                        !readyToWrite && connected && !cancelled
                    }
                }
                if !ready {
                    DiveComputerLog.shared.log("[BLE WRITE] Not ready after 500 ms; writing anyway", level: .warning)
                }
            }
            if withLock({ cancelled }) { return .cancelled }
            queue.async { [self] in peripheral.writeValue(data, for: characteristic, type: .withoutResponse) }
            return .success
        }

        condition.lock(); defer { condition.unlock() }
        lastWriteError = nil
        pendingWriteCallbacks += 1
        queue.async { [self] in peripheral.writeValue(data, for: characteristic, type: .withResponse) }
        // A fresh deadline per callback: stale callbacks from earlier timeouts drain first.
        while pendingWriteCallbacks > 0 {
            if cancelled { return .cancelled }
            if !connected { return .failed }
            let wait = closingAfterCancel ? BLETiming.closeAfterCancelReadLimit : BLETiming.writeConfirmation
            if !condition.wait(until: Date(timeIntervalSinceNow: wait)) {
                DiveComputerLog.shared.log("[BLE WRITE] Not confirmed within \(wait) s", level: .warning)
                return .timeout
            }
        }
        if !connected { return .failed }
        if let error = lastWriteError {
            DiveComputerLog.shared.log("[BLE WRITE] Error: \(error.localizedDescription)", level: .error)
            return .failed
        }
        return .success
    }

    func readCharacteristic(uuid: String, timeout: TimeInterval) -> Data? {
        let key = BLEServiceCatalog.normalized(uuid)
        guard let characteristic = withLock({ characteristicsByUUID[key] }),
              characteristic.properties.contains(.read) else { return nil }
        condition.lock(); defer { ioctlRoute = nil; condition.unlock() }
        ioctlRoute = key
        ioctlValue = nil
        queue.async { [self] in peripheral.readValue(for: characteristic) }
        _ = wait(until: Date(timeIntervalSinceNow: timeout)) { ioctlValue == nil && connected && !cancelled }
        return ioctlValue
    }

    func sleep(milliseconds: UInt32) {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: TimeInterval(milliseconds) / 1000)
        while !cancelled && condition.wait(until: deadline) {}
    }

    /// Drops the unread notifications, as a serial port's input purge (`tcflush` `TCIFLUSH`)
    /// does, once the device has been quiet (`BLETiming.purgeQuietPeriod`, at most
    /// `purgeQuietMaximum`): the backends sleep only 100 ms (Oceanic atom2, Seac) to 1 s (Mares
    /// Icon HD, Pelagic i330R) before a retry's purge, so a reply still arriving would
    /// otherwise be cut and its tail read as the resent command's reply (`Docs/DECISIONS.md`,
    /// L5). An idle link is not waited for. Only the data queue is touched, never the
    /// characteristic-read route or the write state.
    func purge(_ direction: LinkDirection) {
        guard direction.contains(.input) else { return }
        let start = Date()
        let dropped = withLock { () -> Int in
            waitUntilQuiet(period: BLETiming.purgeQuietPeriod, maximum: BLETiming.purgeQuietMaximum, from: start)
            return discardUnread()
        }
        // libdivecomputer logs every purge itself ("Purge: direction=…").
        if dropped > 0 {
            DiveComputerLog.shared.log("[BLE READ] Purge: \(dropped) unread bytes discarded after " +
                                       "\(Int(Date().timeIntervalSince(start) * 1000)) ms", level: .info)
        }
    }

    /// Waits until no notification has arrived for `period`, at most `maximum` after `start`;
    /// returns early when the link drops or the session is cancelled. Call with the lock held.
    private func waitUntilQuiet(period: TimeInterval, maximum: TimeInterval, from start: Date) {
        let deadline = start.addingTimeInterval(maximum)
        while connected && !cancelled {
            let quietAt = lastPacketAt.addingTimeInterval(period)
            let now = Date()
            if quietAt <= now || now >= deadline { break }
            _ = condition.wait(until: min(quietAt, deadline))
        }
    }

    /// Empties the data queue and returns how many bytes it held. Call with the lock held.
    private func discardUnread() -> Int {
        let bytes = packets.byteCount
        packets.removeAll()
        return bytes
    }

    // MARK: - Session control

    /// Makes every current and future wait return at once.
    func cancel() {
        withLock {
            // During the close the exit command must still go out: only keep reads short.
            if closing { closingAfterCancel = true } else { cancelled = true }
            condition.broadcast()
        }
    }

    func prepareForClose() {
        let start = Date()
        let discarded = withLock { () -> Int? in
            closing = true
            guard cancelled else { return nil }
            cancelled = false
            closingAfterCancel = true
            // A device cancelled mid-answer keeps sending the rest of it: wait until it has
            // been quiet, then drop everything left unread, so the exit command's reply is
            // the only thing read next.
            // (`cancelled` was just cleared, so only a disconnect ends the wait early, as before.)
            waitUntilQuiet(period: BLETiming.closeQuietPeriod, maximum: BLETiming.closeQuietMaximum, from: start)
            return discardUnread()
        }
        guard let discarded else { return }
        DiveComputerLog.shared.log("[BLE CONNECT] Cancelled — letting the device close (exit command) after " +
                                   "\(Int(Date().timeIntervalSince(start) * 1000)) ms, \(discarded) unread bytes discarded", level: .info)
    }

    /// Cancels the connection and waits (bounded) for the disconnect callback.
    func close() {
        let wasConnected = withLock { () -> Bool in
            packets.removeAll()
            writeCharacteristic = nil
            notifyCharacteristic = nil
            characteristicsByUUID = [:]
            return connected
        }
        DiveComputerLog.shared.log("[BLE CONNECT] Closing \(peripheral.identifier.uuidString) (connected: \(wasConnected))", level: .info)
        queue.async { [self] in central.cancelConnection(peripheral) }
        if wasConnected {
            withLock {
                _ = wait(until: Date(timeIntervalSinceNow: BLETiming.disconnectWait)) { connected }
            }
        }
        central.unregister(peripheral.identifier)
    }

    // MARK: - From BLECentral (on its queue)

    func handleConnected() {
        withLock { connected = true; condition.broadcast() }
    }

    func markDisconnected(error: Error?) {
        withLock {
            if !connected && connectIssued { didFail = true; connectError = error }
            if connected { lastDisconnectError = error }
            connected = false
            notifying = false
            condition.broadcast()
        }
    }

    // MARK: - CBPeripheralDelegate (on the central's queue)

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        DiveComputerLog.shared.log("[BLE DISCOVER] Services: " + (services.isEmpty ? "none" : services.map(\.uuid.uuidString).joined(separator: ", ")) +
                                   (error.map { " (\($0.localizedDescription))" } ?? ""), level: .info)
        let preferredUUID = BLECharacteristicSelector.preferredService(among: services.map { $0.uuid.uuidString })
        withLock {
            // Reset everything: a reconnect must not keep a previous connection's characteristics.
            preferredService = preferredUUID.map { CBUUID(string: $0) }
            writeCharacteristic = nil
            notifyCharacteristic = nil
            characteristicsByUUID = [:]
        }
        for service in services where !BLEServiceCatalog.isExcluded(service.uuid.uuidString) {
            peripheral.discoverCharacteristics(nil, for: service)
        }
        if services.isEmpty { withLock { condition.broadcast() } }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristics = service.characteristics ?? []
        if DiveComputerLog.shared.isDebugMode {
            for c in characteristics {
                DiveComputerLog.shared.log("[BLE DISCOVER] \(service.uuid.uuidString) / \(c.uuid.uuidString) properties 0x\(String(c.properties.rawValue, radix: 16))", level: .debug)
            }
        }
        withLock {
            // Only the preferred service: e.g. GATT's "Service Changed" indicate
            // characteristic must not be selected.
            if let preferred = preferredService, service.uuid != preferred { return }
            // Keyed in 128-bit form: CoreBluetooth reports Bluetooth-base UUIDs short ("2A26"),
            // libdivecomputer asks for them in full.
            for c in characteristics { characteristicsByUUID[BLEServiceCatalog.normalized(c.uuid.uuidString)] = c }
            let selection = BLECharacteristicSelector.select(characteristics.map {
                BLECharacteristicSelector.Characteristic(
                    uuid: $0.uuid.uuidString,
                    canWriteWithoutResponse: $0.properties.contains(.writeWithoutResponse),
                    canWrite: $0.properties.contains(.write),
                    canNotify: $0.properties.contains(.notify),
                    canIndicate: $0.properties.contains(.indicate))
            })
            let byUUID = Dictionary(characteristics.map { ($0.uuid.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
            if preferredService != nil {
                writeCharacteristic = selection.write.flatMap { byUUID[$0] }
                notifyCharacteristic = selection.notify.flatMap { byUUID[$0] }
            } else {
                if writeCharacteristic == nil { writeCharacteristic = selection.write.flatMap { byUUID[$0] } }
                if notifyCharacteristic == nil { notifyCharacteristic = selection.notify.flatMap { byUUID[$0] } }
            }
            condition.broadcast()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            DiveComputerLog.shared.log("[BLE NOTIFY] \(error.localizedDescription)", level: .warning)
        }
        withLock {
            if characteristic == notifyCharacteristic { notifying = characteristic.isNotifying }
            condition.broadcast()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            DiveComputerLog.shared.log("[BLE READ] \(error.localizedDescription)", level: .warning)
            return
        }
        guard let value = characteristic.value else { return }
        let uuid = characteristic.uuid.uuidString
        DiveComputerLog.shared.logPacket(.inbound, data: value, characteristicUUID: uuid)
        withLock {
            if let route = ioctlRoute, route == BLEServiceCatalog.normalized(uuid) {
                // Characteristic reads (Cressi version info) never enter the data queue.
                ioctlValue = value
            } else if characteristic != notifyCharacteristic {
                // A characteristic-read reply that arrived after its ioctl timed out: not data.
                DiveComputerLog.shared.log("[BLE READ] Ignored late value from \(uuid)", level: .debug)
            } else {
                packets.append(value)
                lastPacketAt = Date()
            }
            condition.broadcast()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        withLock {
            if let error { lastWriteError = error }
            pendingWriteCallbacks = max(0, pendingWriteCallbacks - 1)
            condition.broadcast()
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        withLock { readyToWrite = true; condition.broadcast() }
    }
}
