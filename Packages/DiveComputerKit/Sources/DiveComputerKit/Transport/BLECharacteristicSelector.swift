import Foundation

/// GATT service and characteristic selection rules (Docs/BEHAVIOURAL_SPEC.md §3.7),
/// on plain values so they can be tested without CoreBluetooth.
enum BLECharacteristicSelector {

    struct Characteristic: Equatable, Sendable {
        let uuid: String
        let canWriteWithoutResponse: Bool
        let canWrite: Bool
        let canNotify: Bool
        let canIndicate: Bool
    }

    /// The data service: the first known serial service, except that a vendor-specific
    /// known service replaces the generic Nordic UART one (Cressi advertises both, and
    /// libdivecomputer needs the vendor one). Firmware-update services are skipped.
    static func preferredService(among services: [String]) -> String? {
        var chosen: String?
        for uuid in services where !BLEServiceCatalog.isExcluded(uuid) && BLEServiceCatalog.isKnown(uuid) {
            if chosen == nil {
                chosen = uuid
            } else if let current = chosen, BLEServiceCatalog.isNordicUART(current), !BLEServiceCatalog.isNordicUART(uuid) {
                chosen = uuid
            }
        }
        return chosen
    }

    /// Two passes over the preferred service's characteristics: first the first
    /// write-without-response and the first notify; then, for any slot still empty, the
    /// first write (with response) and the first indicate. A single overwrite loop would
    /// pick Aqualung's authentication-nonce characteristic and miss every reply.
    static func select(_ characteristics: [Characteristic]) -> (write: String?, notify: String?) {
        var write = characteristics.first(where: \.canWriteWithoutResponse)?.uuid
        var notify = characteristics.first(where: \.canNotify)?.uuid
        if write == nil { write = characteristics.first(where: \.canWrite)?.uuid }
        if notify == nil { notify = characteristics.first(where: \.canIndicate)?.uuid }
        return (write, notify)
    }
}
