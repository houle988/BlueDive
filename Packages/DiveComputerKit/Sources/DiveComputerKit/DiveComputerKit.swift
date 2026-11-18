// DiveComputerKit — BlueDive's dive computer transport and parser.
//
// Threading contract (Docs/ARCHITECTURE.md §4.4): libdivecomputer objects are used
// only on a session's dedicated thread; the BLE link only from that thread and the
// CoreBluetooth queue; DiveComputerManager only on the main actor.

import CLibDiveComputer

/// Information about the bundled libdivecomputer.
public enum DiveComputerKitInfo {
    /// Version string of the vendored libdivecomputer (`dc_version`), e.g. "0.10.0".
    public static var libdivecomputerVersion: String {
        String(cString: dc_version(nil))
    }
}
