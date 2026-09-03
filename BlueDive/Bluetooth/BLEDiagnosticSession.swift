import Foundation
import LibDCSwift

/// Manages a BLE diagnostic log session. When started, every raw BLE packet and
/// LibDCSwift log message is written to a timestamped file in the app's Documents
/// directory. Controlled by the "BLE Diagnostic Logging" toggle in Settings.
final class BLEDiagnosticSession {
    static let shared = BLEDiagnosticSession()
    private init() {}

    // MARK: - Toggle with Auto-Off

    /// UserDefaults key for the user-facing "BLE Diagnostic Logging" toggle.
    static let enabledKey = "bleDiagnosticLoggingEnabled"
    /// UserDefaults key for the auto-off deadline (timeIntervalSinceReferenceDate; 0 == unset).
    static let expiryKey = "bleDiagnosticLoggingExpiry"
    /// How long the toggle stays on after being enabled before it self-disables.
    /// Keep in sync with the "Turns off automatically 24 hours after you enable it."
    /// caption in `BluetoothSettingsView` if this value changes.
    static let autoOffInterval: TimeInterval = 24 * 60 * 60

    /// Returns the effective enabled state, honouring the auto-off deadline, and
    /// **mutates persisted state** as a side effect:
    /// - Clears the flag once the deadline passes.
    /// - Self-heals a flag that was enabled without a deadline (legacy state) by
    ///   arming the window now.
    /// Because it writes to UserDefaults, call it only from non-render contexts
    /// (e.g. onAppear, connect) — never from within a SwiftUI `body`.
    static func resolveLoggingEnabled() -> Bool {
        let d = UserDefaults.standard
        guard d.bool(forKey: enabledKey) else { return false }
        let expiry = d.double(forKey: expiryKey)
        if expiry <= 0 {
            // Enabled but no deadline recorded — arm the auto-off window now.
            d.set(Date().timeIntervalSinceReferenceDate + autoOffInterval, forKey: expiryKey)
            return true
        }
        if Date().timeIntervalSinceReferenceDate >= expiry {
            d.set(false, forKey: enabledKey)
            d.removeObject(forKey: expiryKey)
            return false
        }
        return true
    }

    /// Turns diagnostic logging on (arming the auto-off window) or off (clearing it).
    static func setLoggingEnabled(_ on: Bool) {
        let d = UserDefaults.standard
        d.set(on, forKey: enabledKey)
        if on {
            d.set(Date().timeIntervalSinceReferenceDate + autoOffInterval, forKey: expiryKey)
        } else {
            d.removeObject(forKey: expiryKey)
        }
    }

    private let queue = DispatchQueue(label: "com.bluedive.BLEDiagnosticSession", qos: .utility)
    private var _fileHandle: FileHandle?
    private var _logURL: URL?
    // Tracks an active capture session independently of the file handle: a session
    // still counts as active (debug mode on, sinks set) even if the log file could
    // not be opened, so stop() correctly tears the Logger state back down.
    private var _active = false

    var isRunning: Bool { queue.sync { _active } }

    /// URL of the log file from the current or most recently completed session.
    /// Non-nil as soon as `start()` succeeds, and persists after `stop()` so the
    /// error screen can offer the file for sharing.
    var currentLogURL: URL? { queue.sync { _logURL } }

    // MARK: - Log File Management

    /// All BlueDive_BLE_*.log files in Documents, sorted newest first.
    private var allLogFiles: [URL] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: docs,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("BlueDive_BLE_") && $0.pathExtension == "log" }
            .sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return d1 > d2
            }
    }

    /// URL of the most recent BlueDive_BLE_*.log file in Documents.
    /// Falls back to a directory scan when no session has run in this app launch.
    var mostRecentLogURL: URL? { currentLogURL ?? allLogFiles.first }

    /// Number of BLE log files currently in Documents.
    var logFileCount: Int { allLogFiles.count }

    /// Reads a log file for export via the app's standard save flow.
    /// Returns the file's contents plus a suggested filename — the log name with its
    /// `.log` extension stripped, since the `.plainText` exporter appends `.txt`.
    /// Returns nil if the file cannot be read.
    func exportPayload(for url: URL) -> (data: Data, filename: String)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (data, url.deletingPathExtension().lastPathComponent)
    }

    /// Deletes all BlueDive_BLE_*.log files from Documents. Returns the number deleted.
    /// Stops any active session first so the FileHandle is closed before files are unlinked.
    @discardableResult
    func clearAllLogs() -> Int {
        // Close the active FileHandle and remove Logger callbacks before unlinking files
        // on disk; otherwise writes continue to a deleted inode and isRunning stays true.
        if isRunning { stop() }
        let files = allLogFiles
        var deleted = 0
        for file in files {
            if (try? FileManager.default.removeItem(at: file)) != nil { deleted += 1 }
        }
        // Nil the cached URL unconditionally — all files have been removed.
        queue.sync { _logURL = nil }
        return deleted
    }

    /// Keeps only the N most recent log files, deleting older ones. Called on every start().
    private func pruneOldLogs(keepLatest count: Int) {
        let all = allLogFiles
        guard all.count > count else { return }
        for file in all.dropFirst(count) { try? FileManager.default.removeItem(at: file) }
    }

    /// Opens a new log file and starts capturing BLE packets and log messages.
    /// If a session is already running, it is closed first (file rotated).
    /// Must be called BEFORE opening a BLE connection.
    ///
    /// Regardless of build configuration the full trace (log lines + packet hex
    /// dumps) is written to the file so it can be shared from device/TestFlight.
    /// Packet hex dumps are additionally echoed to the Xcode console in DEBUG
    /// builds; plain log lines already reach the console via LibDCSwift itself.
    func start() {
        // Drain any in-flight writes and close the previous file before rotating.
        queue.sync { _close() }

        var didOpenFile = false
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let url = docs.appendingPathComponent("BlueDive_BLE_\(formatter.string(from: Date())).log")
        pruneOldLogs(keepLatest: 5)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        if let fh = try? FileHandle(forWritingTo: url) {
            queue.sync {
                _fileHandle = fh
                _logURL = url
            }
            didOpenFile = true
        } else {
            // File creation failed; still capture to the console (DEBUG) rather than aborting.
            try? FileManager.default.removeItem(at: url)
        }

        // Assign sinks BEFORE enabling debug mode so no packet is dropped.
        // write() no-ops when no file handle is open (file-creation failure).
        Logger.shared.onLog = { [weak self] event in
            let ts = String(format: "%.3f", event.timestamp.timeIntervalSince1970)
            self?.write("[\(ts)] [\(event.level.prefix)] [\(event.category)] \(event.message)")
        }
        Logger.shared.onPacket = { [weak self] event in
            let ts = String(format: "%.3f", event.timestamp.timeIntervalSince1970)
            let dir = event.direction.rawValue.uppercased()
            let line = "[\(ts)] [\(dir)] \(event.characteristicUUID) (\(event.data.count) bytes)\n\(event.hexDump)"
            // libdc-swift does not print packets itself; echo them to the Xcode console in DEBUG only.
            #if DEBUG
            print(line)
            #endif
            self?.write(line)
        }

        // Write the header before enabling debug mode so it lands first in the file.
        // enableDebugMode() synchronously fires onLog("Debug mode enabled…") → write() → queue.async,
        // which would otherwise be enqueued before the header's queue.async.
        if didOpenFile {
            write("BlueDive BLE Diagnostic Log\nStarted: \(Date())\n" + String(repeating: "-", count: 60))
        }
        queue.sync { _active = true }
        Logger.shared.enableDebugMode()
    }

    /// Flushes and closes the log file, then disables debug mode and clears callbacks.
    /// Safe to call multiple times (idempotent if already stopped). No-ops when the
    /// toggle was off and start() was never called.
    func stop() {
        // Wait for all pending writes to flush before closing.
        var wasActive = false
        queue.sync {
            wasActive = _active
            _active = false
            _close()
        }
        // Only touch Logger state when we actually started a session; avoids
        // unconditionally clobbering Logger callbacks when the toggle was off.
        guard wasActive else { return }
        // disableDebugMode() stops packet capture and verbose libdivecomputer logging,
        // but it also lowers minimumLogLevel to .warning. Restore it to .debug so the
        // regular LibDCSwift log lines remain visible in the Xcode console after a session.
        Logger.shared.disableDebugMode()
        Logger.shared.minimumLogLevel = .debug
        Logger.shared.onLog = nil
        Logger.shared.onPacket = nil
    }

    // MARK: - Private

    private func _close() {
        guard _fileHandle != nil else { return }
        _fileHandle?.closeFile()
        _fileHandle = nil
        // _logURL is intentionally kept so currentLogURL remains valid after stop().
    }

    private func write(_ text: String) {
        queue.async { [weak self] in
            guard let fh = self?._fileHandle else { return }
            if let data = (text + "\n").data(using: .utf8) {
                // Use the throwing API: the legacy FileHandle.write(_:) raises an
                // uncatchable ObjC exception on failure (e.g. disk full), which would
                // crash mid-sync. Silently drop the line instead — a diagnostic log
                // must never take down the app it is diagnosing.
                try? fh.write(contentsOf: data)
            }
        }
    }
}
