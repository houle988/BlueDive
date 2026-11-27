import SwiftData
import DiveComputerKit

// MARK: - Sync State

/// Possible Bluetooth sync states
enum BluetoothSyncState: Equatable {
    case idle
    case scanning
    case connecting(deviceName: String)
    case downloading(current: Int, total: Int)
    case importing(count: Int)
    case completed(imported: Int, merged: Int, skipped: Int)
    /// A backup dive computer: nothing was downloaded; `clock` says whether its clock was set.
    case backupComputer(name: String, clock: BackupClockResult)
    case error(message: String)
    
    var isActive: Bool {
        switch self {
        case .idle, .completed, .backupComputer, .error:
            return false
        default:
            return true
        }
    }
}

/// What a session with a backup dive computer did with its clock.
enum BackupClockResult: Equatable {
    case synced
    /// The computer cannot set its clock over Bluetooth.
    case unsupported
    case failed
    /// Sync device clock is off: nothing was done.
    case notRequested

    init(_ result: ClockSyncResult?) {
        switch result {
        case .synced: self = .synced
        case .unsupported: self = .unsupported
        case .failed: self = .failed
        case nil: self = .notRequested
        }
    }
}

// MARK: - Weather Fetch After Import

/// Dives awaiting the weather question after a download, by persistent ID (not @Model
/// references, which must not be held in @State).
struct PendingWeatherFetch: Equatable {
    var ids: [PersistentIdentifier]
}

// MARK: - Synced Dives

/// A dive the last import added or updated, listed on the completed screen. By persistent ID,
/// like PendingWeatherFetch: @Model references must not be held in @State.
struct SyncedDive: Equatable, Identifiable {
    let id: PersistentIdentifier
    let isNew: Bool
}
