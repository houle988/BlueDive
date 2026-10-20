import SwiftData

// MARK: - Sync State

/// Possible Bluetooth sync states
enum BluetoothSyncState: Equatable {
    case idle
    case scanning
    case connecting(deviceName: String)
    case downloading(current: Int, total: Int)
    case importing(count: Int)
    case completed(imported: Int, merged: Int, skipped: Int)
    case error(message: String)
    
    var isActive: Bool {
        switch self {
        case .idle, .completed, .error:
            return false
        default:
            return true
        }
    }
}

// MARK: - Weather Fetch After Import

/// Dives awaiting the weather question after a download, by persistent ID (not @Model
/// references, which must not be held in @State).
struct PendingWeatherFetch: Equatable {
    var ids: [PersistentIdentifier]
}
