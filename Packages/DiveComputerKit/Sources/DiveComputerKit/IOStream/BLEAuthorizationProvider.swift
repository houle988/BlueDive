import Foundation

/// Identifies the device asking for authorization. Pelagic devices (Aqualung i330R,
/// Apeks DSX) ask while the connection opens, before their serial number is known, so
/// the advertised name (model code + serial digits, stable across app reinstalls)
/// identifies them.
public struct AuthorizationRequest: Sendable, Hashable {
    public let peripheralID: UUID
    public let advertisedName: String
}

/// Supplies the PIN code and the stored access code of devices that require pairing
/// (`DC_IOCTL_BLE_GET_PINCODE`, `GET_ACCESSCODE`, `SET_ACCESSCODE`).
///
/// Called on the session thread, which waits for the answer: an implementation that
/// asks the user must present its prompt on the main actor and block until it closes.
public protocol BLEAuthorizationProvider: Sendable {
    /// The PIN code shown on the device (6 digits), or nil if the user cancelled.
    func pinCode(for request: AuthorizationRequest) -> String?
    /// The access code stored after a previous pairing (16 bytes), or nil.
    func accessCode(for request: AuthorizationRequest) -> Data?
    /// Stores the access code the device issued after a successful PIN entry.
    func storeAccessCode(_ code: Data, for request: AuthorizationRequest)
}
