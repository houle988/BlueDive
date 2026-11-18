import Foundation
import CLibDiveComputer

/// The BLE ioctls of ble.h. Unknown requests are `DC_STATUS_UNSUPPORTED`, which
/// libdivecomputer backends tolerate.
enum DCIOControl {

    static let getName = dc_shim_ioctl_ble_get_name()
    static let getPincode = dc_shim_ioctl_ble_get_pincode()
    static let getAccessCode = dc_shim_ioctl_ble_get_accesscode()
    static let setAccessCode = dc_shim_ioctl_ble_set_accesscode()
    static let characteristicRead = dc_shim_ioctl_ble_characteristic_read()
    static let uuidSize = dc_shim_sizeof_ble_uuid()

    static func handle(request: UInt32, data: UnsafeMutableRawPointer?, size: Int, stream: DCIOStream) -> dc_status_t {
        switch request {
        case getName:
            // Oceanic / Aqualung: the handshake embeds the advertised name ("FH020399").
            return copyString(stream.link.advertisedName, into: data, size: size)

        case characteristicRead:
            return readCharacteristic(data: data, size: size, link: stream.link)

        case getPincode:
            // Pelagic: the 6-digit PIN shown on the device. A cancelled prompt cancels.
            guard let provider = stream.authorization, let request = stream.authorizationRequest else {
                return DC_STATUS_UNSUPPORTED
            }
            DiveComputerLog.shared.log("[BLE IOCTL] PIN code requested", level: .info)
            guard let pin = provider.pinCode(for: request) else { return DC_STATUS_CANCELLED }
            return copyString(pin, into: data, size: size)

        case getAccessCode:
            guard let provider = stream.authorization, let request = stream.authorizationRequest,
                  let code = provider.accessCode(for: request) else { return DC_STATUS_UNSUPPORTED }
            guard let data, code.count == size else { return DC_STATUS_UNSUPPORTED }
            code.copyBytes(to: data.assumingMemoryBound(to: UInt8.self), count: size)
            return DC_STATUS_SUCCESS

        case setAccessCode:
            guard let provider = stream.authorization, let request = stream.authorizationRequest else {
                return DC_STATUS_UNSUPPORTED
            }
            guard let data, size > 0 else { return DC_STATUS_INVALIDARGS }
            provider.storeAccessCode(Data(bytes: data, count: size), for: request)
            DiveComputerLog.shared.log("[BLE IOCTL] Access code stored", level: .info)
            return DC_STATUS_SUCCESS

        default:
            DiveComputerLog.shared.log("[BLE IOCTL] Unsupported request 0x\(String(request, radix: 16))", level: .debug)
            return DC_STATUS_UNSUPPORTED
        }
    }

    /// NUL-terminated UTF-8; empty → UNSUPPORTED; too long → NOMEMORY.
    static func copyString(_ string: String, into data: UnsafeMutableRawPointer?, size: Int) -> dc_status_t {
        guard let data, size > 0 else { return DC_STATUS_INVALIDARGS }
        guard !string.isEmpty else { return DC_STATUS_UNSUPPORTED }
        let bytes = Array(string.utf8) + [0]
        guard bytes.count <= size else { return DC_STATUS_NOMEMORY }
        bytes.withUnsafeBytes { data.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        return DC_STATUS_SUCCESS
    }

    /// `data` = 16-byte UUID followed by the space for the value (Cressi version reads).
    static func readCharacteristic(data: UnsafeMutableRawPointer?, size: Int, link: DiveComputerLink) -> dc_status_t {
        guard let data, size >= uuidSize else { return DC_STATUS_INVALIDARGS }
        var text = [CChar](repeating: 0, count: 37)
        let converted = text.withUnsafeMutableBufferPointer { buffer in
            dc_ble_uuid2str(data.assumingMemoryBound(to: UInt8.self), buffer.baseAddress, buffer.count)
        }
        guard converted != nil else { return DC_STATUS_INVALIDARGS }
        let uuid = String(decoding: text.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased()
        let wanted = size - uuidSize
        let timeoutMs = link.readTimeoutMilliseconds
        let timeout = timeoutMs > 0 ? TimeInterval(timeoutMs) / 1000 : BLETiming.characteristicReadDefault
        guard let value = link.readCharacteristic(uuid: uuid, timeout: timeout), value.count >= wanted else {
            DiveComputerLog.shared.log("[BLE IOCTL] Characteristic \(uuid) read failed (need \(wanted) bytes)", level: .error)
            return DC_STATUS_IO
        }
        value.prefix(wanted).copyBytes(to: (data + uuidSize).assumingMemoryBound(to: UInt8.self), count: wanted)
        return DC_STATUS_SUCCESS
    }
}
