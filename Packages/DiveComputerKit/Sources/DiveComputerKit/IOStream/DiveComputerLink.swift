import Foundation

/// Result of a link read.
enum LinkRead: Equatable, Sendable {
    /// At least one byte.
    case data(Data)
    /// Nothing arrived within the timeout while the link is still connected
    /// (libdivecomputer's retrying backends try again).
    case timeout
    /// The link is down.
    case failed
    case cancelled
}

/// Result of a link write.
enum LinkWrite: Equatable, Sendable {
    case success
    /// A write with response was not confirmed in time (transient).
    case timeout
    /// No connection or characteristic, or the device reported an error.
    case failed
    case cancelled
}

/// The byte pipe libdivecomputer talks to through the custom iostream. All methods are
/// called on the session thread and may block.
protocol DiveComputerLink: AnyObject, Sendable {
    /// The name the device advertises (`DC_IOCTL_BLE_GET_NAME`).
    var advertisedName: String { get }
    var isConnected: Bool { get }
    /// libdivecomputer's read timeout: < 0 default, 0 poll, > 0 milliseconds.
    func setReadTimeout(milliseconds: Int32)
    func read(maximum: Int) -> LinkRead
    func write(_ data: Data) -> LinkWrite
    /// Reads a characteristic by UUID (`DC_IOCTL_BLE_CHARACTERISTIC_READ`); nil on failure.
    func readCharacteristic(uuid: String, timeout: TimeInterval) -> Data?
    /// The read timeout libdivecomputer set, in milliseconds (-1 when unset).
    var readTimeoutMilliseconds: Int32 { get }
    /// Blocks the calling thread; returns early when the session is cancelled.
    func sleep(milliseconds: UInt32)
}

/// A link a session can open and close (the BLE link, or a scripted link in tests).
protocol SessionLink: DiveComputerLink {
    /// Connects and prepares the link; blocks.
    func open() throws(LinkOpenError)
    /// Makes every current and future wait return at once.
    func cancel()
    /// Called before `dc_device_close`, cancelled or not: libdivecomputer's close sends the
    /// protocol's exit command (e.g. Shearwater's shutdown request), which a cancelled link
    /// would refuse. From then on a cancel no longer refuses writes; after a cancel, reads
    /// during the close are kept short.
    func prepareForClose()
    /// Disconnects; blocks briefly.
    func close()
}
