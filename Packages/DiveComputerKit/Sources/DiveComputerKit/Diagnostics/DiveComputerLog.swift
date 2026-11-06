import Foundation
import os
import CLibDiveComputer

public enum LogLevel: Int, Sendable, Comparable {
    case debug = 0, info, warning, error

    /// Same prefixes as the former LibDCSwift logger (BLE diagnostic trace files).
    public var prefix: String {
        switch self {
        case .debug: return "🔍 DEBUG"
        case .info: return "ℹ️ INFO"
        case .warning: return "⚠️ WARN"
        case .error: return "❌ ERROR"
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct LogEvent: Sendable {
    public let level: LogLevel
    public let message: String
    /// Source file name (without extension), or "libdivecomputer".
    public let category: String
    public let function: String
    public let timestamp: Date
}

public enum PacketDirection: String, Sendable {
    case inbound, outbound
}

public struct PacketEvent: Sendable {
    public let direction: PacketDirection
    public let data: Data
    public let characteristicUUID: String
    public let timestamp: Date

    /// Uppercase hex, space-separated, 16 bytes per line.
    public var hexDump: String {
        stride(from: 0, to: data.count, by: 16).map { start in
            data[data.startIndex + start ..< data.startIndex + min(start + 16, data.count)]
                .map { String(format: "%02X", $0) }.joined(separator: " ")
        }.joined(separator: "\n")
    }
}

/// DiveComputerKit's log, shared by the BLE layer, the session and libdivecomputer.
///
/// Thread-safe: called from the CoreBluetooth queue and the session threads. `onLog`
/// and `onPacket` are invoked on the calling thread.
public final class DiveComputerLog: @unchecked Sendable {
    public static let shared = DiveComputerLog()

    private let lock = NSLock()
    private var _onLog: (@Sendable (LogEvent) -> Void)?
    private var _onPacket: (@Sendable (PacketEvent) -> Void)?
    private var _minimumLevel: LogLevel = .warning
    private var _showRawData = false
    private var _libdcLevel: dc_loglevel_t = DC_LOGLEVEL_WARNING
    private let osLog = Logger(subsystem: "app.bluedive.DiveComputerKit", category: "DiveComputer")

    private init() {}

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    public var onLog: (@Sendable (LogEvent) -> Void)? {
        get { locked { _onLog } }
        set { locked { _onLog = newValue } }
    }

    /// Called for every BLE packet while debug mode is on.
    public var onPacket: (@Sendable (PacketEvent) -> Void)? {
        get { locked { _onPacket } }
        set { locked { _onPacket = newValue } }
    }

    public var minimumLevel: LogLevel {
        get { locked { _minimumLevel } }
        set { locked { _minimumLevel = newValue } }
    }

    /// Debug mode is on when libdivecomputer logs everything.
    public var isDebugMode: Bool { locked { _libdcLevel == DC_LOGLEVEL_ALL } }

    /// Applies to sessions started afterwards: enable before connecting.
    public func enableDebugMode() {
        locked {
            _minimumLevel = .debug
            _showRawData = true
            _libdcLevel = DC_LOGLEVEL_ALL
        }
        log("Debug mode enabled", level: .info)
    }

    public func disableDebugMode() {
        locked {
            _minimumLevel = .warning
            _showRawData = false
            _libdcLevel = DC_LOGLEVEL_WARNING
        }
    }

    /// The level new libdivecomputer contexts are created with.
    var libdcLevel: dc_loglevel_t { locked { _libdcLevel } }

    public func log(_ message: @autoclosure () -> String, level: LogLevel = .info,
                    file: String = #fileID, function: String = #function) {
        let (minimum, handler) = locked { (_minimumLevel, _onLog) }
        guard level >= minimum else { return }
        let text = message()
        let category = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        emit(LogEvent(level: level, message: text, category: category, function: function, timestamp: Date()),
             handler: handler)
    }

    func logLibrary(level: dc_loglevel_t, file: String, line: UInt32, function: String, message: String) {
        let mapped: LogLevel
        let name: String
        switch level {
        case DC_LOGLEVEL_ERROR: mapped = .error; name = "ERROR"
        case DC_LOGLEVEL_WARNING: mapped = .warning; name = "WARNING"
        case DC_LOGLEVEL_INFO: mapped = .info; name = "INFO"
        case DC_LOGLEVEL_DEBUG: mapped = .debug; name = "DEBUG"
        default: mapped = .debug; name = "TRACE"
        }
        let (minimum, handler) = locked { (_minimumLevel, _onLog) }
        guard mapped >= minimum else { return }
        let text = "[libdc \(name)] \((file as NSString).lastPathComponent):\(line) (\(function)): \(message)"
        emit(LogEvent(level: mapped, message: text, category: "libdivecomputer", function: function, timestamp: Date()),
             handler: handler)
    }

    func logPacket(_ direction: PacketDirection, data: Data, characteristicUUID: String) {
        let (show, handler) = locked { (_showRawData, _onPacket) }
        guard show, let handler else { return }
        handler(PacketEvent(direction: direction, data: data, characteristicUUID: characteristicUUID, timestamp: Date()))
    }

    private func emit(_ event: LogEvent, handler: (@Sendable (LogEvent) -> Void)?) {
        switch event.level {
        case .debug: osLog.debug("\(event.message, privacy: .public)")
        case .info: osLog.info("\(event.message, privacy: .public)")
        case .warning: osLog.warning("\(event.message, privacy: .public)")
        case .error: osLog.error("\(event.message, privacy: .public)")
        }
        handler?(event)
    }
}

/// Hex dump for log lines: at most 64 bytes, then "… (N more)".
func shortHex(_ data: Data) -> String {
    let shown = data.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " ")
    return data.count > 64 ? "\(shown) … (\(data.count - 64) more)" : shown
}
