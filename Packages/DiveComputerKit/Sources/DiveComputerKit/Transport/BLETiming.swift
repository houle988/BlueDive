import Foundation

/// Every timing constant of the BLE layer (Docs/BEHAVIOURAL_SPEC.md §3–5). Each value
/// works around a real device behaviour; change one only with a device test.
enum BLETiming {
    /// Waiting for a reused CBPeripheral to finish a previous disconnect (Oceanic/Aqualung
    /// connect-fail-reconnect cycles), polled every `disconnectedStatePoll`.
    static let disconnectedStateWait: TimeInterval = 5
    static let disconnectedStatePoll: TimeInterval = 0.1
    /// Waiting for `didConnect`: first-time pairing dialogs block it until the user taps Pair.
    static let connectWait: TimeInterval = 30
    /// Waiting for a write and a notify characteristic after `discoverServices`.
    static let discoveryWait: TimeInterval = 5
    /// Waiting for notifications to be enabled (Suunto EON Core passkey entry).
    static let notifyEnableWait: TimeInterval = 30
    /// Read timeout when libdivecomputer has not set one (-1).
    static let defaultReadTimeout: TimeInterval = 3
    /// Until a read of the connection first returns data, shorter read timeouts are raised to
    /// this (Aqualung i300C / Pelagic OEMs ignore the first query after a fresh link).
    /// Notifications a purge drops unread do not end it.
    static let firstReadFloor: TimeInterval = 5
    /// Waiting for `canSendWriteWithoutResponse`; the write is sent anyway afterwards
    /// (the flag can stay false after connection-parameter renegotiation).
    static let writeWithoutResponseBackpressure: TimeInterval = 0.5
    /// Waiting for each `didWriteValueFor` of a write with response (fresh per callback).
    static let writeConfirmation: TimeInterval = 5
    /// `DC_IOCTL_BLE_CHARACTERISTIC_READ` when libdivecomputer has set no timeout.
    static let characteristicReadDefault: TimeInterval = 5
    /// `dc_device_open` attempts on the same link, with a pause before attempts 2…5.
    static let openAttempts = 5
    static let openRetryDelay: TimeInterval = 3
    /// After `dc_device_close`, letting the protocol exit command reach the device before
    /// the link is cut (Shearwater otherwise stays on "Sending Dive").
    static let closeFlush: TimeInterval = 0.5
    /// Longest read while a cancelled session closes the device (a reply to the exit
    /// command, when the protocol expects one), so a cancel stays quick.
    static let closeAfterCancelReadLimit: TimeInterval = 1
    /// Before that close, how long the device must have sent nothing: a computer cancelled
    /// mid-answer (Aqualung i300C) keeps sending the rest of it, which would otherwise be
    /// read as the reply to the exit command. Waiting at most `closeQuietMaximum`.
    static let closeQuietPeriod: TimeInterval = 0.15
    static let closeQuietMaximum: TimeInterval = 1
    /// Before a purge (`dc_iostream_purge`), how long the device must have sent nothing,
    /// waiting at most `purgeQuietMaximum`; an idle link is not waited for. A late reply
    /// spanning several notifications (Oceanic atom2 big-page models: i770R, A300CS,
    /// ProPlus X, F11, ProPlus 3) would otherwise be cut by a retry's purge, and its tail
    /// read as the resent command's reply (oceanic_atom2.c `oceanic_atom2_ble_read`: header
    /// and sequence checks); atom2's read timeout is only 1 s and it sleeps 100 ms before
    /// the purge. Same values as the close's quiet wait (i300C trace).
    static let purgeQuietPeriod: TimeInterval = 0.15
    static let purgeQuietMaximum: TimeInterval = 1
    /// Waiting for `didDisconnectPeripheral` after cancelling the connection.
    static let disconnectWait: TimeInterval = 2
    /// Minimum interval between two progress events.
    static let progressInterval: TimeInterval = 0.1
}
