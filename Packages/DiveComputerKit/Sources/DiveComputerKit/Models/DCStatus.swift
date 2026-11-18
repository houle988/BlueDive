import CLibDiveComputer

/// A libdivecomputer status code (`dc_status_t`, common.h).
public struct DCStatus: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
    init(_ status: dc_status_t) { self.rawValue = status.rawValue }

    public static let success = DCStatus(rawValue: 0)
    public static let done = DCStatus(rawValue: 1)
    public static let unsupported = DCStatus(rawValue: -1)
    public static let invalidArgs = DCStatus(rawValue: -2)
    public static let noMemory = DCStatus(rawValue: -3)
    public static let noDevice = DCStatus(rawValue: -4)
    public static let noAccess = DCStatus(rawValue: -5)
    public static let io = DCStatus(rawValue: -6)
    public static let timeout = DCStatus(rawValue: -7)
    public static let protocolError = DCStatus(rawValue: -8)
    public static let dataFormat = DCStatus(rawValue: -9)
    public static let cancelled = DCStatus(rawValue: -10)

    /// libdivecomputer's constant name, for logs (never shown to the user).
    public var name: String {
        switch rawValue {
        case 0: return "DC_STATUS_SUCCESS"
        case 1: return "DC_STATUS_DONE"
        case -1: return "DC_STATUS_UNSUPPORTED"
        case -2: return "DC_STATUS_INVALIDARGS"
        case -3: return "DC_STATUS_NOMEMORY"
        case -4: return "DC_STATUS_NODEVICE"
        case -5: return "DC_STATUS_NOACCESS"
        case -6: return "DC_STATUS_IO"
        case -7: return "DC_STATUS_TIMEOUT"
        case -8: return "DC_STATUS_PROTOCOL"
        case -9: return "DC_STATUS_DATAFORMAT"
        case -10: return "DC_STATUS_CANCELLED"
        default: return "DC_STATUS(\(rawValue))"
        }
    }

    public var description: String { name }
}
