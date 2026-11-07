import Foundation
import Testing
import CLibDiveComputer
@testable import DiveComputerKit

/// A scripted link: queued reads, recorded writes, no radio.
final class FakeLink: SessionLink, @unchecked Sendable {
    private let lock = NSCondition()
    let advertisedName: String
    var openError: LinkOpenError?
    /// Reads return these in order, then `.timeout` (or block until cancelled when `blockReads`).
    private var reads: [LinkRead]
    var blockReads = false
    private(set) var writes: [Data] = []
    var writeResult: LinkWrite = .success
    var characteristics: [String: Data] = [:]
    private(set) var timeout: Int32 = -1
    private(set) var cancelled = false
    private(set) var resumedForClose = false
    /// Set by `prepareForClose()`: as in the real link, a cancel then no longer refuses writes.
    private(set) var closing = false
    /// Writes made after `prepareForClose()` released a cancel (the exit command).
    private(set) var closeWrites: [Data] = []
    private(set) var closed = false
    private(set) var opened = false

    init(name: String, reads: [LinkRead] = []) {
        self.advertisedName = name
        self.reads = reads
    }

    var isConnected: Bool { lock.withLock { opened && !closed } }
    var readTimeoutMilliseconds: Int32 { lock.withLock { timeout } }
    func setReadTimeout(milliseconds: Int32) { lock.withLock { timeout = milliseconds } }

    func read(maximum: Int) -> LinkRead {
        lock.lock(); defer { lock.unlock() }
        while true {
            if cancelled { return .cancelled }
            if resumedForClose { return .timeout }
            if !reads.isEmpty { return reads.removeFirst() }
            if !blockReads { return .timeout }
            lock.wait()
        }
    }

    func write(_ data: Data) -> LinkWrite {
        lock.withLock {
            writes.append(data)
            if resumedForClose { closeWrites.append(data) }
            return cancelled ? .cancelled : writeResult
        }
    }

    func readCharacteristic(uuid: String, timeout: TimeInterval) -> Data? { lock.withLock { characteristics[uuid] } }
    func sleep(milliseconds: UInt32) {}
    func open() throws(LinkOpenError) {
        if let openError { throw openError }
        lock.withLock { opened = true }
    }
    func cancel() { lock.withLock { if !closing { cancelled = true }; lock.broadcast() } }
    func prepareForClose() {
        lock.withLock {
            closing = true
            if cancelled { cancelled = false; resumedForClose = true }
            lock.broadcast()
        }
    }
    func close() { lock.withLock { closed = true } }
}

struct PacketQueueTests {
    @Test func boundariesAndPartialReads() {
        var queue = BLEPacketQueue()
        queue.append(Data([1, 2, 3]))
        queue.append(Data([4, 5]))
        #expect(queue.take(maximum: 10) == Data([1, 2, 3]))   // one notification per read
        queue.append(Data([6, 7, 8, 9]))
        #expect(queue.take(maximum: 10) == Data([4, 5]))
        #expect(queue.take(maximum: 2) == Data([6, 7]))       // split; rest kept
        #expect(queue.take(maximum: 10) == Data([8, 9]))
        #expect(queue.take(maximum: 10) == nil)
        #expect(queue.isEmpty)
    }
}

struct CharacteristicSelectionTests {
    typealias C = BLECharacteristicSelector.Characteristic

    @Test func vendorServiceBeatsNordicUART() {
        let cressi = ["6E400001-B5A3-F393-E0A9-E50E24DCCA9E", "6E400001-B5A3-F393-E0A9-E50E24DC10B8"]
        #expect(BLECharacteristicSelector.preferredService(among: cressi) == cressi[1])
        let reversed = Array(cressi.reversed())
        #expect(BLECharacteristicSelector.preferredService(among: reversed) == cressi[1])
    }

    @Test func firmwareAndUnknownServicesIgnored() {
        let services = ["00001530-1212-EFDE-1523-785FEABCD123", "180A", "FE25C237-0ECE-443C-B0AA-E02033E7029D"]
        #expect(BLECharacteristicSelector.preferredService(among: services) == services[2])
        #expect(BLECharacteristicSelector.preferredService(among: ["180A"]) == nil)
    }

    /// Aqualung i300C: a write + write-without-response data pair and an extra nonce
    /// notify characteristic; the first write-without-response and first notify win.
    @Test func twoPassSelection() {
        let chars = [
            C(uuid: "nonce", canWriteWithoutResponse: false, canWrite: false, canNotify: false, canIndicate: true),
            C(uuid: "write", canWriteWithoutResponse: false, canWrite: true, canNotify: false, canIndicate: false),
            C(uuid: "data", canWriteWithoutResponse: true, canWrite: true, canNotify: true, canIndicate: false),
            C(uuid: "auth", canWriteWithoutResponse: false, canWrite: false, canNotify: true, canIndicate: false)
        ]
        let selection = BLECharacteristicSelector.select(chars)
        #expect(selection.write == "data")
        #expect(selection.notify == "data")
        // Second pass only fills empty slots.
        let indicateOnly = [C(uuid: "w", canWriteWithoutResponse: false, canWrite: true, canNotify: false, canIndicate: false),
                            C(uuid: "i", canWriteWithoutResponse: false, canWrite: false, canNotify: false, canIndicate: true)]
        let fallback = BLECharacteristicSelector.select(indicateOnly)
        #expect(fallback.write == "w" && fallback.notify == "i")
    }
}


struct IOStreamTests {

    private func withStream(_ link: FakeLink, authorization: (any BLEAuthorizationProvider)? = nil,
                            _ body: (OpaquePointer) -> Void) {
        let stream = DCIOStream(link: link, authorization: authorization,
                                authorizationRequest: AuthorizationRequest(peripheralID: UUID(), advertisedName: link.advertisedName))
        #expect(stream.open(context: nil) == DC_STATUS_SUCCESS)
        body(stream.pointer!)
        stream.close()
    }

    @Test func readStatusMapping() {
        let link = FakeLink(name: "Perdix 2", reads: [.data(Data([0xAA, 0xBB])), .timeout, .failed, .cancelled])
        withStream(link) { stream in
            var buffer = [UInt8](repeating: 0, count: 16)
            var actual = 0
            #expect(dc_iostream_read(stream, &buffer, 16, &actual) == DC_STATUS_SUCCESS)
            #expect(actual == 2 && buffer[0] == 0xAA)
            #expect(dc_iostream_read(stream, &buffer, 16, &actual) == DC_STATUS_TIMEOUT)
            #expect(actual == 0)
            #expect(dc_iostream_read(stream, &buffer, 16, &actual) == DC_STATUS_IO)
            #expect(dc_iostream_read(stream, &buffer, 16, &actual) == DC_STATUS_CANCELLED)
        }
    }

    @Test func writeStatusMapping() {
        let link = FakeLink(name: "Perdix 2")
        withStream(link) { stream in
            let bytes: [UInt8] = [1, 2, 3]
            var actual = 0
            #expect(dc_iostream_write(stream, bytes, 3, &actual) == DC_STATUS_SUCCESS)
            #expect(actual == 3)
            link.writeResult = .timeout
            #expect(dc_iostream_write(stream, bytes, 3, &actual) == DC_STATUS_TIMEOUT)
            link.writeResult = .failed
            #expect(dc_iostream_write(stream, bytes, 3, &actual) == DC_STATUS_IO)
        }
        #expect(link.writes.count == 3)
    }

    @Test func timeoutIsForwarded() {
        let link = FakeLink(name: "x")
        withStream(link) { stream in
            #expect(dc_iostream_set_timeout(stream, 3000) == DC_STATUS_SUCCESS)
        }
        #expect(link.readTimeoutMilliseconds == 3000)
    }

    @Test func getNameIoctl() {
        withStream(FakeLink(name: "FH020399")) { stream in
            var buffer = [CChar](repeating: 0, count: 32)
            #expect(dc_iostream_ioctl(stream, DCIOControl.getName, &buffer, 32) == DC_STATUS_SUCCESS)
            #expect(String(decoding: buffer.prefix(8).map { UInt8($0) }, as: UTF8.self) == "FH020399" && buffer[8] == 0)
            var small = [CChar](repeating: 0, count: 4)
            #expect(dc_iostream_ioctl(stream, DCIOControl.getName, &small, 4) == DC_STATUS_NOMEMORY)
        }
        withStream(FakeLink(name: "")) { stream in
            var buffer = [CChar](repeating: 0, count: 32)
            #expect(dc_iostream_ioctl(stream, DCIOControl.getName, &buffer, 32) == DC_STATUS_UNSUPPORTED)
        }
    }

    @Test func characteristicReadIoctl() {
        let link = FakeLink(name: "6_1A2B")
        link.characteristics["6e400003-b5a3-f393-e0a9-e50e24dc10b8"] = Data([1, 2, 3, 4, 5])
        withStream(link) { stream in
            var request = [UInt8](repeating: 0, count: 16 + 5)
            #expect("6E400003-B5A3-F393-E0A9-E50E24DC10B8".withCString { dc_ble_str2uuid($0, &request) } != 0)
            #expect(dc_iostream_ioctl(stream, DCIOControl.characteristicRead, &request, request.count) == DC_STATUS_SUCCESS)
            #expect(Array(request[16...]) == [1, 2, 3, 4, 5])
            // Shorter than requested → IO.
            var longer = [UInt8](repeating: 0, count: 16 + 8)
            _ = "6E400003-B5A3-F393-E0A9-E50E24DC10B8".withCString { dc_ble_str2uuid($0, &longer) }
            #expect(dc_iostream_ioctl(stream, DCIOControl.characteristicRead, &longer, longer.count) == DC_STATUS_IO)
        }
    }

    struct Pairing: BLEAuthorizationProvider {
        let pin: String?
        let stored: Data?
        let saved = Box()
        final class Box: @unchecked Sendable { var code: Data? }
        func pinCode(for request: AuthorizationRequest) -> String? { pin }
        func accessCode(for request: AuthorizationRequest) -> Data? { stored }
        func storeAccessCode(_ code: Data, for request: AuthorizationRequest) { saved.code = code }
    }

    @Test func pelagicPairingIoctls() {
        let provider = Pairing(pin: "123456", stored: nil)
        withStream(FakeLink(name: "GD000001"), authorization: provider) { stream in
            var code = [UInt8](repeating: 0, count: 16)
            #expect(dc_iostream_ioctl(stream, DCIOControl.getAccessCode, &code, 16) == DC_STATUS_UNSUPPORTED)
            var pin = [CChar](repeating: 0, count: 7)
            #expect(dc_iostream_ioctl(stream, DCIOControl.getPincode, &pin, 7) == DC_STATUS_SUCCESS)
            #expect(String(decoding: pin.prefix(6).map { UInt8($0) }, as: UTF8.self) == "123456")
            var newCode = [UInt8](0..<16)
            #expect(dc_iostream_ioctl(stream, DCIOControl.setAccessCode, &newCode, 16) == DC_STATUS_SUCCESS)
        }
        #expect(provider.saved.code == Data(0..<16))
        // Without a provider: unsupported (parity with the former bridge).
        withStream(FakeLink(name: "GD000001")) { stream in
            var pin = [CChar](repeating: 0, count: 7)
            #expect(dc_iostream_ioctl(stream, DCIOControl.getPincode, &pin, 7) == DC_STATUS_UNSUPPORTED)
        }
        // A cancelled prompt cancels.
        withStream(FakeLink(name: "GD000001"), authorization: Pairing(pin: nil, stored: nil)) { stream in
            var pin = [CChar](repeating: 0, count: 7)
            #expect(dc_iostream_ioctl(stream, DCIOControl.getPincode, &pin, 7) == DC_STATUS_CANCELLED)
        }
    }
}

struct DownloadDecisionTests {
    typealias F = DownloadDecision.Facts
    let identity = DeviceIdentity(family: .shearwaterPetrel, descriptorModel: 11, hardwareModel: 11,
                                  firmware: 0, serial: "1a2b3c4d", libraryName: "Shearwater Perdix 2")
    let fp = Data([1, 2, 3, 4])

    func facts(_ status: DCStatus, new: Bool = false, matched: Bool = false, cutoff: Bool = false,
               use: Bool = true, stored: Bool = false) -> F {
        F(status: status, hasNewDives: new, fingerprintMatched: matched, cutoffReached: cutoff, useFingerprint: use,
          hadStoredFingerprint: stored, diveCount: new ? 3 : 0, newestFingerprint: new || cutoff ? fp : nil, identity: identity)
    }

    @Test func successRows() throws {
        let newDives = try DownloadDecision.decide(facts(.success, new: true, stored: true)).get()
        #expect(newDives.kind == .completed && newDives.newestFingerprint == fp)
        let none = try DownloadDecision.decide(facts(.success, matched: true, stored: true)).get()
        #expect(none.kind == .noNewDives && none.newestFingerprint == nil)
        let downloadAll = try DownloadDecision.decide(facts(.success, new: true, use: false)).get()
        #expect(downloadAll.newestFingerprint == fp)   // a full download also sets the watermark
        let cutoffNothingKept = try DownloadDecision.decide(facts(.success, cutoff: true)).get()
        #expect(cutoffNothingKept.stoppedAtCutoff && cutoffNothingKept.newestFingerprint == fp)
        let cutoffDownloadAll = try DownloadDecision.decide(facts(.success, cutoff: true, use: false)).get()
        #expect(cutoffDownloadAll.newestFingerprint == nil)
    }

    @Test func protocolErrorRows() throws {
        #expect(try DownloadDecision.decide(facts(.protocolError, cutoff: true, use: false)).get().stoppedAtCutoff)
        #expect(try DownloadDecision.decide(facts(.protocolError, matched: true)).get().kind == .noNewDives)
        let partial = try DownloadDecision.decide(facts(.protocolError, new: true)).get()
        #expect(partial.kind == .partial && partial.newestFingerprint == fp)
        #expect(try DownloadDecision.decide(facts(.protocolError, new: true, use: false)).get().newestFingerprint == nil)
        #expect(try DownloadDecision.decide(facts(.protocolError, stored: true)).get().kind == .noNewDives)
        #expect(throws: SessionError.downloadFailed(.protocolError)) { try DownloadDecision.decide(facts(.protocolError)).get() }
    }

    @Test func failures() {
        #expect(throws: SessionError.downloadFailed(.timeout)) { try DownloadDecision.decide(facts(.timeout, new: true)).get() }
        #expect(throws: SessionError.cancelled) { try DownloadDecision.decide(facts(.cancelled)).get() }
    }

    @Test func clockSyncRule() {
        #expect(DownloadDecision.shouldSyncClock(status: .success, fingerprintMatched: false, cutoffReached: false))
        #expect(DownloadDecision.shouldSyncClock(status: .protocolError, fingerprintMatched: true, cutoffReached: false))
        #expect(!DownloadDecision.shouldSyncClock(status: .protocolError, fingerprintMatched: false, cutoffReached: false))
        #expect(!DownloadDecision.shouldSyncClock(status: .timeout, fingerprintMatched: true, cutoffReached: true))
    }

    /// The time zone is in seconds east of UTC (minutes broke Ratio and Shearwater).
    @Test func clockSyncTimezoneInSeconds() throws {
        let zone = try #require(TimeZone(identifier: "America/Toronto"))
        let date = Date(timeIntervalSince1970: 1_780_000_000)   // 2026-05-28, EDT
        let value = try #require(ClockSync.datetime(for: date, in: zone))
        #expect(value.timezone == -4 * 3600)
        #expect(value.year == 2026 && value.month == 5 && value.day == 28)
    }
}

struct SessionTests {

    private func run(_ request: SessionRequest, link: FakeLink, cancelAfter: TimeInterval? = nil) async -> ([SessionEvent], Error?) {
        let (events, continuation) = AsyncThrowingStream<SessionEvent, any Error>.makeStream()
        let session = DeviceSession(request: request, link: link, continuation: continuation)
        session.start()
        if let cancelAfter {
            Task {
                try? await Task.sleep(for: .seconds(cancelAfter))
                await session.cancel()
            }
        }
        var received: [SessionEvent] = []
        do {
            for try await event in events { received.append(event) }
            return (received, nil)
        } catch {
            return (received, error)
        }
    }

    @Test func connectionFailureClosesLink() async {
        let link = FakeLink(name: "Perdix 2")
        link.openError = .connectionTimeout
        let (_, error) = await run(SessionRequest(peripheralID: UUID()), link: link)
        #expect(error as? SessionError == .connectionTimeout)
        #expect(link.closed)
    }

    @Test func unsupportedNameFails() async {
        let link = FakeLink(name: "iPhone")
        let (_, error) = await run(SessionRequest(peripheralID: UUID()), link: link)
        #expect(error as? SessionError == .unsupportedDevice("iPhone"))
        #expect(link.closed)
    }

    /// Real Shearwater backend over a silent link: it opens, then the first command's
    /// reply times out (Shearwater does not retry), and everything is torn down.
    @Test func silentDeviceTimesOut() async {
        let link = FakeLink(name: "Perdix 2")
        let (events, error) = await run(SessionRequest(peripheralID: UUID()), link: link)
        #expect(error as? SessionError == .downloadFailed(.timeout))
        #expect(events.contains { if case .connected(let model) = $0 { return model?.name == "Shearwater Perdix 2" }; return false })
        #expect(!link.writes.isEmpty)
        #expect(link.closed)
    }

    @Test func cancelDuringDownload() async {
        let link = FakeLink(name: "Perdix 2")
        link.blockReads = true
        let (_, error) = await run(SessionRequest(peripheralID: UUID()), link: link, cancelAfter: 0.2)
        #expect(error as? SessionError == .cancelled)
        // The Shearwater exit command (2E 90 20 00) still reaches the device after the cancel.
        #expect(link.resumedForClose)
        #expect(link.closeWrites.contains { $0.range(of: Data([0x2E, 0x90, 0x20, 0x00])) != nil })
        #expect(link.closed)
    }
}
