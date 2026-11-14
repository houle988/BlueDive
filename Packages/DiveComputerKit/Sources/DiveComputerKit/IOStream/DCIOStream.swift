import Foundation
import CLibDiveComputer

/// A libdivecomputer custom iostream (`dc_custom_open`, custom.h) over a `DiveComputerLink`.
///
/// Only the callbacks BLE needs are set; libdivecomputer treats the others (break,
/// DTR/RTS, lines, available, configure, poll, flush) as successful no-ops, as the former
/// bridge did. `purge`, a no-op in the former bridge, discards unread input
/// (`Docs/DECISIONS.md`, L5). The stream object must outlive `close()`, which owns the C side.
final class DCIOStream {
    let link: DiveComputerLink
    let authorization: (any BLEAuthorizationProvider)?
    let authorizationRequest: AuthorizationRequest?
    private(set) var pointer: OpaquePointer?

    init(link: DiveComputerLink, authorization: (any BLEAuthorizationProvider)?,
         authorizationRequest: AuthorizationRequest?) {
        self.link = link
        self.authorization = authorization
        self.authorizationRequest = authorizationRequest
    }

    /// Creates the C iostream. `self` is the callbacks' userdata (unretained: the
    /// session keeps this object alive until `close()`).
    func open(context: OpaquePointer?) -> dc_status_t {
        var callbacks = dc_custom_cbs_t()
        callbacks.set_timeout = ioSetTimeout
        callbacks.read = ioRead
        callbacks.write = ioWrite
        callbacks.ioctl = ioIoctl
        callbacks.sleep = ioSleep
        callbacks.purge = ioPurge
        callbacks.close = ioClose
        var stream: OpaquePointer?
        let status = dc_custom_open(&stream, context, DC_TRANSPORT_BLE, &callbacks,
                                    Unmanaged.passUnretained(self).toOpaque())
        if status == DC_STATUS_SUCCESS { pointer = stream }
        return status
    }

    /// Closes and frees the C iostream (calls the `close` callback first).
    func close() {
        guard let stream = pointer else { return }
        pointer = nil
        _ = dc_iostream_close(stream)
    }

    fileprivate static func from(_ userdata: UnsafeMutableRawPointer?) -> DCIOStream? {
        userdata.map { Unmanaged<DCIOStream>.fromOpaque($0).takeUnretainedValue() }
    }
}

// MARK: - Callbacks (C convention: no captures; state comes from userdata)

private let ioSetTimeout: @convention(c) (UnsafeMutableRawPointer?, Int32) -> dc_status_t = { userdata, timeout in
    guard let stream = DCIOStream.from(userdata) else { return DC_STATUS_INVALIDARGS }
    stream.link.setReadTimeout(milliseconds: timeout)
    return DC_STATUS_SUCCESS
}

private let ioRead: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int,
                                    UnsafeMutablePointer<Int>?) -> dc_status_t = { userdata, data, size, actual in
    guard let stream = DCIOStream.from(userdata), let data, size > 0 else { return DC_STATUS_INVALIDARGS }
    actual?.pointee = 0
    switch stream.link.read(maximum: size) {
    case .data(let bytes):
        bytes.copyBytes(to: data.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        actual?.pointee = bytes.count
        if DiveComputerLog.shared.isDebugMode {
            DiveComputerLog.shared.log("[DC_IO READ] \(bytes.count) bytes: \(shortHex(bytes))", level: .debug)
        }
        return DC_STATUS_SUCCESS
    case .timeout:
        DiveComputerLog.shared.log("[DC_IO READ] Timeout (\(size) bytes requested)", level: .warning)
        return DC_STATUS_TIMEOUT
    case .failed:
        DiveComputerLog.shared.log("[DC_IO READ] Link down", level: .error)
        return DC_STATUS_IO
    case .cancelled:
        return DC_STATUS_CANCELLED
    }
}

private let ioWrite: @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int,
                                     UnsafeMutablePointer<Int>?) -> dc_status_t = { userdata, data, size, actual in
    guard let stream = DCIOStream.from(userdata), let data else { return DC_STATUS_INVALIDARGS }
    actual?.pointee = 0
    let bytes = Data(bytes: data, count: size)
    if DiveComputerLog.shared.isDebugMode {
        DiveComputerLog.shared.log("[DC_IO WRITE] \(size) bytes: \(shortHex(bytes))", level: .debug)
    }
    switch stream.link.write(bytes) {
    case .success:
        actual?.pointee = size
        return DC_STATUS_SUCCESS
    case .timeout:
        DiveComputerLog.shared.log("[DC_IO WRITE] Not confirmed in time", level: .warning)
        return DC_STATUS_TIMEOUT
    case .failed:
        DiveComputerLog.shared.log("[DC_IO WRITE] Failed", level: .error)
        return DC_STATUS_IO
    case .cancelled:
        return DC_STATUS_CANCELLED
    }
}

private let ioIoctl: @convention(c) (UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?, Int) -> dc_status_t = {
    userdata, request, data, size in
    guard let stream = DCIOStream.from(userdata) else { return DC_STATUS_INVALIDARGS }
    return DCIOControl.handle(request: request, data: data, size: size, stream: stream)
}

private let ioSleep: @convention(c) (UnsafeMutableRawPointer?, UInt32) -> dc_status_t = { userdata, milliseconds in
    guard let stream = DCIOStream.from(userdata) else { return DC_STATUS_INVALIDARGS }
    stream.link.sleep(milliseconds: milliseconds)
    return DC_STATUS_SUCCESS
}

/// SUCCESS for any direction; nothing can be withdrawn from CoreBluetooth's write queue, so
/// the link ignores an output-only purge.
private let ioPurge: @convention(c) (UnsafeMutableRawPointer?, dc_direction_t) -> dc_status_t = { userdata, direction in
    guard let stream = DCIOStream.from(userdata) else { return DC_STATUS_INVALIDARGS }
    var directions: LinkDirection = []
    if direction.rawValue & DC_DIRECTION_INPUT.rawValue != 0 { directions.insert(.input) }
    if direction.rawValue & DC_DIRECTION_OUTPUT.rawValue != 0 { directions.insert(.output) }
    stream.link.purge(directions)
    return DC_STATUS_SUCCESS
}

/// Never frees anything: `dc_iostream_close` frees the stream itself after this call.
private let ioClose: @convention(c) (UnsafeMutableRawPointer?) -> dc_status_t = { _ in
    DC_STATUS_SUCCESS
}
