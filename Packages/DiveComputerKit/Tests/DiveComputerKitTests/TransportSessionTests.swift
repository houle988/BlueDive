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
    /// Writes, read timeouts, sleeps and purges in the order the session made them (reads that
    /// return data, fail or are cancelled are not recorded).
    enum Step: Equatable { case write, readTimeout, sleep, purge(LinkDirection) }
    private(set) var steps: [Step] = []

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
            if resumedForClose { steps.append(.readTimeout); return .timeout }
            if !reads.isEmpty {
                let read = reads.removeFirst()
                if read == .timeout { steps.append(.readTimeout) }
                return read
            }
            if !blockReads { steps.append(.readTimeout); return .timeout }
            lock.wait()
        }
    }

    func write(_ data: Data) -> LinkWrite {
        lock.withLock {
            writes.append(data)
            steps.append(.write)
            if resumedForClose { closeWrites.append(data) }
            return cancelled ? .cancelled : writeResult
        }
    }

    func readCharacteristic(uuid: String, timeout: TimeInterval) -> Data? { lock.withLock { characteristics[uuid] } }
    func sleep(milliseconds: UInt32) { lock.withLock { steps.append(.sleep) } }
    func purge(_ direction: LinkDirection) { lock.withLock { steps.append(.purge(direction)) } }
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
    /// A purge drops the rest of a partly read notification too, not only whole ones.
    @Test func removeAllDropsPartialRest() {
        var queue = BLEPacketQueue()
        queue.append(Data([1, 2, 3, 4]))
        queue.append(Data([5, 6]))
        #expect(queue.take(maximum: 2) == Data([1, 2]))
        #expect(queue.byteCount == 4)
        queue.removeAll()
        #expect(queue.isEmpty && queue.byteCount == 0)
        #expect(queue.take(maximum: 10) == nil)
        queue.append(Data([7]))
        #expect(queue.take(maximum: 10) == Data([7]))
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

    @Test func purgeDirectionIsForwarded() {
        let link = FakeLink(name: "x")
        withStream(link) { stream in
            #expect(dc_iostream_purge(stream, DC_DIRECTION_INPUT) == DC_STATUS_SUCCESS)
            #expect(dc_iostream_purge(stream, DC_DIRECTION_OUTPUT) == DC_STATUS_SUCCESS)
            #expect(dc_iostream_purge(stream, DC_DIRECTION_ALL) == DC_STATUS_SUCCESS)
        }
        #expect(link.steps == [.purge(.input), .purge(.output), .purge(.all)])
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

    /// A backup computer downloads nothing and never moves the watermark, whatever the
    /// stopped download step returned; the clock result rides along.
    @Test func backupComputerOutcome() {
        let identity = DeviceIdentity(family: .shearwaterPetrel, descriptorModel: 11, hardwareModel: 11,
                                      firmware: 1, serial: "0000abcd", libraryName: "Shearwater Perdix 2")
        let synced = DownloadDecision.backupOutcome(identity: identity, status: .cancelled, clockSync: .synced)
        #expect(synced.kind == .backupComputer)
        #expect(synced.diveCount == 0)
        #expect(synced.newestFingerprint == nil)
        #expect(synced.identity == identity)
        #expect(synced.clockSync == .synced)
        #expect(synced.status == .cancelled)   // what the stopped download step returned, for traces
        #expect(DownloadDecision.backupOutcome(identity: identity, status: .cancelled, clockSync: nil).clockSync == nil)
    }

    /// A normal download carries the clock result in its outcome, nil when the clock was not set.
    @Test func outcomeCarriesTheClockResult() throws {
        let withClock = try DownloadDecision.decide(facts(.success, new: true, stored: true), clockSync: .synced).get()
        #expect(withClock.clockSync == .synced)
        #expect(withClock.kind == .completed)
        let unsupported = try DownloadDecision.decide(facts(.success, matched: true, stored: true), clockSync: .unsupported).get()
        #expect(unsupported.clockSync == .unsupported)
        #expect(try DownloadDecision.decide(facts(.success, new: true, stored: true)).get().clockSync == nil)
    }

    /// Serials compare as libdivecomputer reports them (lowercase `%08x`), whatever the case
    /// the app passed.
    @Test func backupSerialMatching() {
        #expect(DownloadDecision.isBackup(serial: "0000abcd", in: ["0000abcd"]))
        #expect(DownloadDecision.isBackup(serial: "0000ABCD", in: ["0000abcd"]))
        #expect(!DownloadDecision.isBackup(serial: "0000abce", in: ["0000abcd"]))
        #expect(!DownloadDecision.isBackup(serial: "0000abcd", in: []))
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

/// Serialized: some tests observe `DiveComputerLog.shared`, which every session writes to.
@Suite(.serialized)
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

    /// Real Oceanic atom2 backend over a silent link: every open attempt purges before its
    /// first write, then, after each timed-out command (2 retries), sleeps, purges unread
    /// input and sends the command again.
    @Test func retryPurgesBeforeResending() async {
        let link = FakeLink(name: "FH123456")
        let (_, error) = await run(SessionRequest(peripheralID: UUID()), link: link)
        #expect(error as? SessionError == .deviceOpenFailed(.timeout))
        let steps = link.steps
        let opens = steps.indices.filter { steps[$0] == .purge(.all) }
        #expect(opens.count == BLETiming.openAttempts)
        #expect(!steps[..<(opens.first ?? 0)].contains(.write))
        for index in opens {
            // Each attempt's purge comes before its first write.
            #expect(steps[(index + 1)...].first { $0 != .sleep } == .write)
        }
        let retries = steps.indices.filter { steps[$0] == .purge(.input) }
        // 2 = upstream's MAXRETRIES in oceanic_atom2.c: update after a libdivecomputer sync
        // that changes it.
        #expect(retries.count == 2 * BLETiming.openAttempts)
        for index in retries {
            #expect(index > 1 && steps[index - 1] == .sleep && steps[index - 2] == .readTimeout)
            // The next write follows, after any sleeps (atom2's inter-packet delay).
            let next = steps[(index + 1)...].first { $0 != .sleep }
            #expect(next == .write)
        }
    }

    /// A backup serial changes nothing for a device that never reports its serial: the
    /// session fails as any download would and tears everything down.
    @Test func backupRequestOnSilentDeviceTimesOut() async {
        let link = FakeLink(name: "Perdix 2")
        let request = SessionRequest(peripheralID: UUID(), syncClock: true, backupSerials: ["0000abcd"])
        let (events, error) = await run(request, link: link)
        #expect(error as? SessionError == .downloadFailed(.timeout))
        #expect(!events.contains { if case .clockSync = $0 { return true }; return false })
        #expect(link.closed)
    }

    /// One Shearwater BLE reply: the 2-byte BLE header, then the SLIP-framed V1 packet
    /// (`01 FF len+1 00 payload`, END-terminated).
    private func shearwaterReply(_ payload: [UInt8]) -> LinkRead {
        let packet: [UInt8] = [0x01, 0xFF, UInt8(payload.count + 1), 0x00] + payload
        var framed: [UInt8] = [0x01, 0x00]
        for byte in packet {
            switch byte {
            case 0xC0: framed += [0xDB, 0xDC]
            case 0xDB: framed += [0xDB, 0xDD]
            default: framed.append(byte)
            }
        }
        return .data(Data(framed + [0xC0]))
    }

    /// The replies a Perdix 2 sends before reporting its serial 0000abcd: serial (8 ASCII hex
    /// digits), firmware, model.
    private var shearwaterIdentityReplies: [LinkRead] {
        [shearwaterReply([0x62, 0x80, 0x10] + Array("0000ABCD".utf8)),
         shearwaterReply([0x62, 0x80, 0x11] + Array("V90".utf8)),
         shearwaterReply([0x62, 0x80, 0x60, 0x0B])]
    }

    private func wrote(_ link: FakeLink, _ command: [UInt8]) -> Bool {
        link.writes.contains { $0.range(of: Data(command)) != nil }
    }

    /// Real Shearwater backend: a backup serial stops the download step right after the serial
    /// (the logbook-format request and the manifest are never sent), then the clock is set
    /// (model read again, local time written) and the session ends with no dive.
    @Test func backupComputerSetsTheClockWithoutDownloading() async {
        let link = FakeLink(name: "Perdix 2", reads: shearwaterIdentityReplies + [
            shearwaterReply([0x62, 0x80, 0x60, 0x0B]),       // timesync: model (not a Teric)
            shearwaterReply([0x6E, 0x90, 0x30])               // timesync: local time written
        ])
        let request = SessionRequest(peripheralID: UUID(), syncClock: true, backupSerials: ["0000abcd"])
        let (events, error) = await run(request, link: link)
        #expect(error == nil)
        #expect(wrote(link, [0x22, 0x80, 0x10]))                    // serial read
        #expect(!wrote(link, [0x22, 0x80, 0x21]))                   // no logbook-format request
        #expect(wrote(link, [0x2E, 0x90, 0x30]))                    // local time written
        #expect(!events.contains { if case .dive = $0 { return true }; return false })
        #expect(events.contains { if case .clockSync(.synced) = $0 { return true }; return false })
        let outcome = events.compactMap { if case .finished(let outcome) = $0 { return outcome }; return nil }.first
        #expect(outcome?.kind == .backupComputer)
        #expect(outcome?.identity?.serial == "0000abcd")
        #expect(outcome?.newestFingerprint == nil)
        #expect(outcome?.clockSync == .synced)
        #expect(wrote(link, [0x2E, 0x90, 0x20, 0x00]))              // exit command at close
        #expect(link.closed)
    }

    /// The refused command's libdivecomputer error is logged as expected information, not as an
    /// error: a successful backup sync leaves no error line in the console or a trace.
    @Test func backupStopLogsNoLibraryError() async {
        let events = LogEventBox()
        // Info level for the run, so the downgraded line itself is visible (outside debug mode
        // the log keeps warnings and above only, so it is simply not shown).
        let minimum = DiveComputerLog.shared.minimumLevel
        DiveComputerLog.shared.minimumLevel = .info
        DiveComputerLog.shared.onLog = { events.append($0) }
        defer {
            DiveComputerLog.shared.onLog = nil
            DiveComputerLog.shared.minimumLevel = minimum
        }
        let link = FakeLink(name: "Perdix 2", reads: shearwaterIdentityReplies + [
            shearwaterReply([0x62, 0x80, 0x60, 0x0B]),
            shearwaterReply([0x6E, 0x90, 0x30])
        ])
        let request = SessionRequest(peripheralID: UUID(), syncClock: true, backupSerials: ["0000abcd"])
        let (_, error) = await run(request, link: link)
        #expect(error == nil)
        // Only this session's backend: other suites may log libdivecomputer lines meanwhile.
        let library = events.all.filter { $0.category == "libdivecomputer" && $0.message.contains("shearwater_petrel.c") }
        #expect(!library.contains { $0.level >= .warning })
        #expect(library.contains { $0.message.contains("expected: backup stop") && $0.message.contains("logbook type") })
    }

    /// A backup computer gets no fingerprint, even when one is stored for its serial.
    @Test func backupComputerAppliesNoFingerprint() async {
        let link = FakeLink(name: "Perdix 2", reads: shearwaterIdentityReplies)
        let request = SessionRequest(peripheralID: UUID(), useFingerprint: true,
                                     fingerprintsBySerial: ["0000abcd": Data([1, 2, 3, 4])],
                                     syncClock: false, backupSerials: ["0000abcd"])
        let (events, error) = await run(request, link: link)
        #expect(error == nil)
        #expect(events.contains { if case .deviceIdentified(_, let applied) = $0 { return !applied }; return false })
    }

    /// A user cancel during a backup session (here while the clock is being set) ends as a
    /// cancel: no outcome, the exit command is still sent, the link is closed.
    @Test func cancelDuringBackupSession() async {
        let link = FakeLink(name: "Perdix 2", reads: shearwaterIdentityReplies)
        link.blockReads = true
        let request = SessionRequest(peripheralID: UUID(), syncClock: true, backupSerials: ["0000abcd"])
        let (events, error) = await run(request, link: link, cancelAfter: 0.3)
        #expect(error as? SessionError == .cancelled)
        #expect(!events.contains { if case .finished = $0 { return true }; return false })
        #expect(link.closeWrites.contains { $0.range(of: Data([0x2E, 0x90, 0x20, 0x00])) != nil })
        #expect(link.closed)
    }

    /// With clock sync off, a backup computer is identified and closed: nothing is written.
    @Test func backupComputerWithoutClockSyncDoesNothing() async {
        let link = FakeLink(name: "Perdix 2", reads: shearwaterIdentityReplies)
        let request = SessionRequest(peripheralID: UUID(), syncClock: false, backupSerials: ["0000abcd"])
        let (events, error) = await run(request, link: link)
        #expect(error == nil)
        #expect(!wrote(link, [0x22, 0x80, 0x21]))
        #expect(!wrote(link, [0x2E, 0x90, 0x30]))
        #expect(!events.contains { if case .clockSync = $0 { return true }; return false })
        let outcome = events.compactMap { if case .finished(let outcome) = $0 { return outcome }; return nil }.first
        #expect(outcome?.kind == .backupComputer)
        #expect(outcome?.clockSync == nil)
        #expect(link.closed)
    }

    /// Another computer's serial is not stopped: the download step goes on to the
    /// logbook-format request (which times out here).
    @Test func otherSerialIsDownloadedAsUsual() async {
        let link = FakeLink(name: "Perdix 2", reads: shearwaterIdentityReplies)
        let request = SessionRequest(peripheralID: UUID(), syncClock: true, backupSerials: ["0000ffff"])
        let (_, error) = await run(request, link: link)
        #expect(wrote(link, [0x22, 0x80, 0x21]))
        #expect(error as? SessionError == .downloadFailed(.timeout))
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

/// Collects log events from the session thread.
final class LogEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [LogEvent] = []
    func append(_ event: LogEvent) { lock.withLock { events.append(event) } }
    var all: [LogEvent] { lock.withLock { events } }
}
