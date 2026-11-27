import Foundation
import CLibDiveComputer

/// The end-of-download rules (Docs/BEHAVIOURAL_SPEC.md §5.3), as a pure function.
enum DownloadDecision {

    struct Facts: Equatable {
        var status: DCStatus
        var hasNewDives: Bool
        var fingerprintMatched: Bool
        var cutoffReached: Bool
        var useFingerprint: Bool
        var hadStoredFingerprint: Bool
        var diveCount: Int
        var newestFingerprint: Data?
        var identity: DeviceIdentity?
    }

    /// The outcome, or the error to report. A protocol error is a success when it
    /// happened after the cutoff, the fingerprint match or some dives (partial sync).
    /// `clockSync` is carried into the outcome unchanged (nil when the clock was not set).
    static func decide(_ f: Facts, clockSync: ClockSyncResult? = nil) -> Result<DownloadOutcome, SessionError> {
        var partial = false
        let save: Bool
        switch f.status {
        case .success:
            save = f.hasNewDives || (f.cutoffReached && f.useFingerprint)
        case .protocolError where f.cutoffReached:
            save = f.hasNewDives || f.useFingerprint
        case .protocolError where f.fingerprintMatched:
            save = false
        case .protocolError where f.hasNewDives:
            partial = true
            save = f.useFingerprint   // never write a watermark the user opted out of
        case .protocolError where f.hadStoredFingerprint:
            save = false
        case .cancelled:
            return .failure(.cancelled)
        default:
            return .failure(.downloadFailed(f.status))
        }

        // The watermark needs the newest dive's fingerprint and the device's serial.
        let watermark = save && f.identity != nil ? f.newestFingerprint : nil
        let kind: DownloadOutcome.Kind
        if partial {
            kind = .partial
        } else if watermark == nil && (f.fingerprintMatched || (f.hadStoredFingerprint && !f.hasNewDives)) {
            kind = .noNewDives
        } else {
            kind = .completed
        }
        return .success(DownloadOutcome(kind: kind, status: f.status, diveCount: f.diveCount,
                                        stoppedAtCutoff: f.cutoffReached, fingerprintMatched: f.fingerprintMatched,
                                        identity: f.identity, newestFingerprint: watermark, clockSync: clockSync))
    }

    /// A backup computer's outcome: no dive, no watermark, whatever the stopped download step
    /// returned (it was stopped on purpose right after the serial; `status` is what it returned,
    /// normally `.cancelled`, kept for traces).
    static func backupOutcome(identity: DeviceIdentity, status: DCStatus, clockSync: ClockSyncResult?) -> DownloadOutcome {
        DownloadOutcome(kind: .backupComputer, status: status, diveCount: 0, stoppedAtCutoff: false,
                        fingerprintMatched: false, identity: identity, newestFingerprint: nil, clockSync: clockSync)
    }

    /// Whether the reported serial belongs to a backup computer.
    static func isBackup(serial: String, in backupSerials: Set<String>) -> Bool {
        backupSerials.contains(serial.lowercased())
    }

    /// Clock sync runs after a clean download, or a protocol error that came after the
    /// fingerprint match or the cutoff.
    static func shouldSyncClock(status: DCStatus, fingerprintMatched: Bool, cutoffReached: Bool) -> Bool {
        status == .success || (status == .protocolError && (fingerprintMatched || cutoffReached))
    }
}

enum ClockSync {
    /// The current local time; `timezone` is in seconds east of UTC (some computers,
    /// e.g. Ratio, reject other units).
    static func datetime(for date: Date, in zone: TimeZone = .current) -> dc_datetime_t? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = c.year, let month = c.month, let day = c.day,
              let hour = c.hour, let minute = c.minute, let second = c.second else { return nil }
        return dc_datetime_t(year: Int32(year), month: Int32(month), day: Int32(day), hour: Int32(hour),
                             minute: Int32(minute), second: Int32(second),
                             timezone: Int32(zone.secondsFromGMT(for: date)))
    }
}
