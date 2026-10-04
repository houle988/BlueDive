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
/// references, which must not be held in @State). One value so the two sets cannot drift apart.
struct PendingWeatherFetch: Equatable {
    var ids: [PersistentIdentifier]
    /// Of `ids`, the newly imported dives — the only ones Replace existing weather applies to.
    var newDiveIDs: Set<PersistentIdentifier>
    /// Of `newDiveIDs`, dives whose air temperature the dive computer measured: kept even with
    /// Replace on.
    var measuredAirTemperatureIDs: Set<PersistentIdentifier>
}

/// Progress of the Open-Meteo weather fetch the user starts after a Bluetooth import
/// (see PendingWeatherFetch). Kept apart from `BluetoothSyncState`: the import itself is
/// complete, so closing the sheet stays allowed while it runs.
enum BluetoothWeatherFetchStatus: Equatable {
    case running(done: Int, total: Int)
    /// `withData`: dives Open-Meteo returned values for; `filled`: dives whose values changed;
    /// `stillEmpty`: dives left with an empty field Open-Meteo had no value for.
    case finished(filled: Int, withData: Int, stillEmpty: Int, total: Int)
    /// Stopped at the first network failure (e.g. no connection on the boat). `filled`: dives
    /// already updated and saved before stopping.
    case stoppedOffline(filled: Int)
    /// Stopped because Open-Meteo answered with an error (e.g. rate limit).
    case stoppedUnavailable(filled: Int)
    /// Stopped because saving the fetched values failed (they were discarded).
    case saveFailed(filled: Int)
    /// Stopped because the app went to the background (iOS would suspend it mid-request).
    case interrupted(filled: Int)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
