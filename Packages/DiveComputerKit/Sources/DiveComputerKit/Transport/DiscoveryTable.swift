import Foundation

/// The peripherals a scan has listed, keyed by identifier, with the rule for adding one.
/// `Entry` is the transport's handle (`CBPeripheral` in `BLECentral`); the table itself
/// touches no CoreBluetooth, so its rule is tested without a radio.
///
/// Used for both sources of the list: advertisements (`didDiscover`) and peripherals
/// already connected to the system, which do not advertise (`retrieveConnectedPeripherals`).
struct DiscoveryTable<Entry> {

    private var entries: [UUID: (entry: Entry, device: DiscoveredDevice)] = [:]

    /// Records a peripheral seen by the scan. A nil or empty name is skipped (it cannot be
    /// resolved). `accepts` (the discovery filter) is asked only for a new identifier; a
    /// peripheral already listed is refreshed (handle, name, `lastSeen`) without asking again.
    /// Returns true when the peripheral is new, i.e. when the list must be published: a
    /// refresh is not published, so the app's observers do not run again for every
    /// advertisement of a device already shown.
    mutating func register(id: UUID, name: String?, entry: Entry, now: Date = Date(),
                           accepts: (UUID, String) -> Bool) -> Bool {
        guard let name, !name.isEmpty else { return false }
        let isNew = entries[id] == nil
        if isNew && !accepts(id, name) { return false }
        entries[id] = (entry, DiscoveredDevice(id: id, name: name, lastSeen: now))
        return isNew
    }

    func entry(for id: UUID) -> Entry? { entries[id]?.entry }

    func device(for id: UUID) -> DiscoveredDevice? { entries[id]?.device }

    /// The listed devices, sorted by name (the order the scanner shows).
    var sortedDevices: [DiscoveredDevice] {
        entries.values.map(\.device).sorted { ($0.name ?? "") < ($1.name ?? "") }
    }

    mutating func removeAll() { entries.removeAll() }
}
