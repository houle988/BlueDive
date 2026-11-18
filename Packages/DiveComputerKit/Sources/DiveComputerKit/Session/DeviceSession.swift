import Foundation
import CLibDiveComputer

/// One connect-and-download, run on a dedicated thread (libdivecomputer blocks for
/// seconds at a time and is not thread-safe per context/device). Every libdivecomputer
/// object is created, used and freed on that thread; teardown always completes before
/// the event stream ends, so no C pointer outlives the session.
final class DeviceSession: @unchecked Sendable {

    let request: SessionRequest
    private let link: any SessionLink
    private let continuation: AsyncThrowingStream<SessionEvent, any Error>.Continuation

    private let stateLock = NSLock()
    private var cancelled = false
    private var finished = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    // Session-thread state
    private var device: OpaquePointer?
    private var openedPair: (family: DeviceFamily, model: UInt32)?
    private var libraryName = ""
    private var identity: DeviceIdentity?
    private var storedFingerprint: Data?
    private var lastProgress = Date.distantPast
    private var logCount = 1
    private var hasNewDives = false
    private var fingerprintMatched = false
    private var cutoffReached = false
    private var newestFingerprint: Data?

    init(request: SessionRequest, link: any SessionLink,
         continuation: AsyncThrowingStream<SessionEvent, any Error>.Continuation) {
        self.request = request
        self.link = link
        self.continuation = continuation
    }

    // MARK: - Control (any thread)

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "app.bluedive.divecomputer.session"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 1 << 20
        thread.start()
    }

    var isCancelled: Bool { stateLock.withLock { cancelled } }

    /// Torn down: every libdivecomputer object and the connection are released.
    var isFinished: Bool { stateLock.withLock { finished } }

    /// Cancels and returns once teardown is complete.
    func cancel() async {
        stateLock.withLock { cancelled = true }
        link.cancel()
        await waitUntilFinished()
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let done = stateLock.withLock { () -> Bool in
                if finished { return true }
                finishWaiters.append(waiter)
                return false
            }
            if done { waiter.resume() }
        }
    }

    // MARK: - Session thread

    private func run() {
        let result = Result { () throws(SessionError) -> DownloadOutcome in try download() }
        // Teardown is complete here: mark the session finished before its stream ends, so a
        // caller starting the next session as soon as it sees the end is not refused as busy.
        let waiters = stateLock.withLock { () -> [CheckedContinuation<Void, Never>] in
            finished = true
            defer { finishWaiters = [] }
            return finishWaiters
        }
        switch result {
        case .success(let outcome) where !isCancelled:
            continuation.yield(.finished(outcome))
            continuation.finish()
        case .success:
            // Cancelled after the dives were transferred (clock sync, close): nothing is
            // returned, as for any cancel (Docs/DECISIONS.md, O3).
            DiveComputerLog.shared.log("Session ended: cancelled", level: .info)
            continuation.finish(throwing: SessionError.cancelled)
        case .failure(let error):
            DiveComputerLog.shared.log("Session ended: \(error)", level: error == .cancelled ? .info : .warning)
            continuation.finish(throwing: error)
        }
        waiters.forEach { $0.resume() }
    }

    private func download() throws(SessionError) -> DownloadOutcome {
        continuation.yield(.connecting(.connecting))
        do {
            try link.open()
        } catch {
            link.close()
            throw Self.map(error)
        }

        var context: OpaquePointer?
        _ = dc_context_new(&context)
        dc_context_set_loglevel(context, DiveComputerLog.shared.libdcLevel)
        dc_context_set_logfunc(context, libdcLogFunction, nil)

        let stream = DCIOStream(link: link, authorization: request.authorization,
                                authorizationRequest: AuthorizationRequest(peripheralID: request.peripheralID,
                                                                           advertisedName: link.advertisedName))
        defer {
            // Teardown order matters: the device close sends the protocol's exit
            // command, which must reach the device before the link is cut.
            if let device {
                // libdivecomputer disables cancellation for the close, so the exit command
                // reaches the device after a cancel too, including one that arrives during
                // the close (the link would refuse it otherwise).
                link.prepareForClose()
                _ = dc_device_close(device)
                Thread.sleep(forTimeInterval: BLETiming.closeFlush)
                self.device = nil
            }
            stream.close()
            dc_context_free(context)
            link.close()
        }

        guard stream.open(context: context) == DC_STATUS_SUCCESS else { throw .deviceOpenFailed(.io) }
        try openDevice(context: context, stream: stream)
        guard let device else { throw .deviceOpenFailed(.io) }
        continuation.yield(.connected(openedPair.flatMap { DeviceCatalog.model(family: $0.family, modelID: $0.model) }))

        let unmanaged = Unmanaged.passUnretained(self).toOpaque()
        let events = DC_EVENT_DEVINFO.rawValue | DC_EVENT_PROGRESS.rawValue | DC_EVENT_CLOCK.rawValue
        dc_device_set_events(device, events, eventCallback, unmanaged)
        dc_device_set_cancel(device, cancelCallback, unmanaged)

        let status = DCStatus(dc_device_foreach(device, diveCallback, unmanaged))
        if status != .success {
            DiveComputerLog.shared.log("Download ended with \(status.name) after \(logCount - 1) dives " +
                                       "(fingerprint matched: \(fingerprintMatched), stored fingerprint: \(storedFingerprint != nil))",
                                       level: .warning)
        }
        if isCancelled { throw .cancelled }

        if request.syncClock,
           DownloadDecision.shouldSyncClock(status: status, fingerprintMatched: fingerprintMatched, cutoffReached: cutoffReached) {
            continuation.yield(.clockSync(syncClock(device)))
        }

        let facts = DownloadDecision.Facts(status: status, hasNewDives: hasNewDives, fingerprintMatched: fingerprintMatched,
                                           cutoffReached: cutoffReached, useFingerprint: request.useFingerprint,
                                           hadStoredFingerprint: storedFingerprint != nil, diveCount: logCount - 1,
                                           newestFingerprint: newestFingerprint, identity: identity)
        return try DownloadDecision.decide(facts).get()
    }

    /// Configuration priority: forced > stored > advertised name. When a forced or stored
    /// model fails to open, the advertised name's model is tried, unless it is the same
    /// protocol family (another model of the same family cannot help).
    private func openDevice(context: OpaquePointer?, stream: DCIOStream) throws(SessionError) {
        let name = link.advertisedName
        let detected = DeviceCatalog.resolve(advertisedName: name).map { (family: $0.family, model: $0.modelID) }
        var primary: (family: DeviceFamily, model: UInt32)?
        var isConfigured = true
        switch request.modelSelection {
        case .forced(let family, let model), .stored(let family, let model): primary = (family, model)
        case .autoDetect: primary = detected; isConfigured = false
        }
        guard let primary else { throw .unsupportedDevice(name) }

        var status = open(primary, context: context, stream: stream)
        if status != .success, isConfigured, !isCancelled, let detected, detected.family != primary.family {
            DiveComputerLog.shared.log("Opening as \(primary.family) failed; trying \(detected.family) from the name", level: .warning)
            status = open(detected, context: context, stream: stream)
        }
        if isCancelled { throw .cancelled }
        guard status == .success else { throw .deviceOpenFailed(status) }
    }

    /// `dc_device_open`, retried on the same link (Aqualung i300C / Pelagic OEMs ignore
    /// commands for a few seconds after the link comes up).
    private func open(_ pair: (family: DeviceFamily, model: UInt32), context: OpaquePointer?,
                      stream: DCIOStream) -> DCStatus {
        var last = DCStatus.unsupported
        for attempt in 1...BLETiming.openAttempts {
            if isCancelled { return .cancelled }
            if attempt > 1 { link.sleep(milliseconds: UInt32(BLETiming.openRetryDelay * 1000)) }
            continuation.yield(.connecting(.openingDevice(attempt: attempt)))
            var opened: OpaquePointer?
            var vendorProduct = ""
            let status = DescriptorLookup.withDescriptor(family: pair.family.dcFamily, model: pair.model) { descriptor in
                vendorProduct = "\(String(cString: dc_descriptor_get_vendor(descriptor))) \(String(cString: dc_descriptor_get_product(descriptor)))"
                return dc_device_open(&opened, context, descriptor, stream.pointer)
            }.map(DCStatus.init) ?? .unsupported
            if status == .success, let opened {
                device = opened
                openedPair = pair
                libraryName = vendorProduct
                return .success
            }
            last = status
            DiveComputerLog.shared.log("dc_device_open attempt \(attempt) failed: \(status.name)", level: .warning)
            if status == .unsupported || status == .cancelled { break }
        }
        return last
    }

    private func syncClock(_ device: OpaquePointer) -> ClockSyncResult {
        guard var now = ClockSync.datetime(for: Date()) else { return .failed(.invalidArgs) }
        let status = DCStatus(dc_device_timesync(device, &now))
        switch status {
        case .success: DiveComputerLog.shared.log("Clock synchronized", level: .info); return .synced
        case .unsupported: return .unsupported
        default: DiveComputerLog.shared.log("Clock sync failed: \(status.name)", level: .warning); return .failed(status)
        }
    }

    // MARK: - libdivecomputer callbacks (session thread)

    fileprivate func handleEvent(_ device: OpaquePointer?, _ type: dc_event_type_t, _ data: UnsafeRawPointer?) {
        guard let data else { return }
        switch type {
        case DC_EVENT_DEVINFO:
            let info = data.load(as: dc_event_devinfo_t.self)
            guard identity == nil, let pair = openedPair else { return }
            let serial = String(format: "%08x", info.serial)
            let identity = DeviceIdentity(family: pair.family, descriptorModel: pair.model, hardwareModel: info.model,
                                          firmware: info.firmware, serial: serial, libraryName: libraryName)
            self.identity = identity
            var applied = false
            if request.useFingerprint, let stored = request.fingerprintsBySerial[serial], !stored.isEmpty {
                storedFingerprint = stored
                let status = stored.withUnsafeBytes {
                    dc_device_set_fingerprint(device, $0.bindMemory(to: UInt8.self).baseAddress, UInt32(stored.count))
                }
                applied = status == DC_STATUS_SUCCESS
                DiveComputerLog.shared.log("Fingerprint \(stored.map { String(format: "%02x", $0) }.joined()) for \(serial): \(DCStatus(status).name)",
                                           level: applied ? .info : .warning)
            } else {
                DiveComputerLog.shared.log("No fingerprint for \(serial)", level: .info)
            }
            continuation.yield(.deviceIdentified(identity, fingerprintApplied: applied))

        case DC_EVENT_PROGRESS:
            let progress = data.load(as: dc_event_progress_t.self)
            let now = Date()
            if now.timeIntervalSince(lastProgress) >= BLETiming.progressInterval || progress.current == progress.maximum {
                lastProgress = now
                continuation.yield(.progress(current: progress.current, maximum: progress.maximum))
            }

        default:
            break
        }
    }

    /// 1 = continue, 0 = stop. Dives arrive newest first.
    fileprivate func handleDive(_ bytes: Data, fingerprint: Data) -> Int32 {
        if isCancelled { return 0 }
        if request.useFingerprint, let stored = storedFingerprint, stored == fingerprint {
            fingerprintMatched = true
            return 0
        }
        guard let pair = openedPair else { return 0 }

        let dive: DiveData
        do {
            dive = try parse(bytes, pair: pair)
        } catch {
            DiveComputerLog.shared.log("Dive skipped: \(error)", level: .warning)
            continuation.yield(.diveSkipped(error))
            return 1
        }

        if let stopBefore = request.stopBefore, dive.datetime < stopBefore {
            cutoffReached = true
            if logCount == 1 { newestFingerprint = fingerprint }
            return 0
        }

        var downloaded = dive
        downloaded.rawData = bytes
        downloaded.fingerprint = fingerprint
        if logCount == 1 { newestFingerprint = fingerprint }
        continuation.yield(.dive(downloaded))
        hasNewDives = true
        logCount += 1
        return 1
    }

    /// Parses with the model the device reports, falling back to the opened descriptor's
    /// model when libdivecomputer has no descriptor for the reported one.
    private func parse(_ bytes: Data, pair: (family: DeviceFamily, model: UInt32)) throws(ParseError) -> DiveData {
        if let identity, identity.hardwareModel != 0, identity.hardwareModel != pair.model {
            do {
                return try DiveParser.parse(family: pair.family, modelID: identity.hardwareModel, data: bytes, diveNumber: logCount)
            } catch .parserCreationFailed {
                // fall through to the opened model
            }
        }
        return try DiveParser.parse(family: pair.family, modelID: pair.model, data: bytes, diveNumber: logCount)
    }

    private static func map(_ error: LinkOpenError) -> SessionError {
        switch error {
        case .connectionTimeout: return .connectionTimeout
        case .connectionFailed(let reason): return .connectionFailed(reason)
        case .pairingRemoved: return .pairingRemoved
        case .serviceDiscoveryFailed: return .serviceDiscoveryFailed
        case .notificationEnableFailed: return .notificationEnableFailed
        case .disconnected: return .disconnected
        case .cancelled: return .cancelled
        }
    }

    fileprivate static func from(_ userdata: UnsafeMutableRawPointer?) -> DeviceSession? {
        userdata.map { Unmanaged<DeviceSession>.fromOpaque($0).takeUnretainedValue() }
    }
}

// MARK: - C callbacks

private let eventCallback: dc_event_callback_t = { device, type, data, userdata in
    DeviceSession.from(userdata)?.handleEvent(device, type, data)
}

private let cancelCallback: dc_cancel_callback_t = { userdata in
    (DeviceSession.from(userdata)?.isCancelled ?? true) ? 1 : 0
}

/// `data` and `fingerprint` belong to the backend and are reused: copied at once.
private let diveCallback: dc_dive_callback_t = { data, size, fingerprint, fsize, userdata in
    guard let session = DeviceSession.from(userdata), let data, let fingerprint else { return 0 }
    return session.handleDive(Data(bytes: data, count: Int(size)), fingerprint: Data(bytes: fingerprint, count: Int(fsize)))
}

private let libdcLogFunction: dc_logfunc_t = { _, level, file, line, function, message, _ in
    DiveComputerLog.shared.logLibrary(level: level, file: file.map { String(cString: $0) } ?? "",
                                      line: line, function: function.map { String(cString: $0) } ?? "",
                                      message: message.map { String(cString: $0) } ?? "")
}
