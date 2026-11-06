import CoreBluetooth

/// GATT services of BLE dive computers.
public enum BLEServiceCatalog {

    /// Serial services of supported dive computers (scan filter and service selection).
    /// Lowercased UUID strings.
    public static let knownServiceUUIDStrings: [String] = [
        "0000fefb-0000-1000-8000-00805f9b34fb", // Heinrichs Weikamp (Telit/Stollmann)
        "2456e1b9-26e2-8f83-e744-f34f01e9d701", // Heinrichs Weikamp (U-Blox)
        "544e326b-5b72-c6b0-1c46-41c1bc448118", // Mares BlueLink Pro
        "6e400001-b5a3-f393-e0a9-e50e24dcca9e", // Nordic Semiconductor UART (generic)
        "98ae7120-e62e-11e3-badd-0002a5d5c51b", // Suunto EON Steel / Core
        "cb3c4555-d670-4670-bc20-b61dbc851e9a", // Pelagic i770R / i200C
        "ca7b0001-f785-4c38-b599-c7c5fbadb034", // Pelagic i330R / DSX
        "fdcdeaaa-295d-470e-bf15-04217b7aa0a0", // Scubapro G2 / G3
        "fe25c237-0ece-443c-b0aa-e02033e7029d", // Shearwater (up to Perdix 2 / Peregrine)
        "1aa44039-1667-4b29-87cc-dfecaaf31d97", // Shearwater Perdix 3
        "0000fcef-0000-1000-8000-00805f9b34fb", // Divesoft Freedom
        "6e400001-b5a3-f393-e0a9-e50e24dc10b8", // Cressi (vendor variant of the Nordic UART)
        "00000001-8c3b-4f2c-a59e-8c08224f3253", // Halcyon Symbios
        "84968ffe-d26d-478a-b953-5010bcf58bca"  // Seac Screen
    ]

    /// Services never used for data: firmware update services.
    public static let excludedServiceUUIDStrings: [String] = [
        "00001530-1212-efde-1523-785feabcd123", // Nordic DFU
        "9e5d1e47-5c13-43a0-8635-82ad38a1386f", // Broadcom upgrade 1
        "a86abc2d-d44c-442e-99f7-80059a873e36"  // Broadcom upgrade 2
    ]

    /// The generic Nordic UART service; a vendor-specific known service is preferred
    /// over it when a device advertises both (Cressi).
    public static let nordicUARTServiceUUIDString = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"

    public static var knownServiceUUIDs: [CBUUID] {
        knownServiceUUIDStrings.map { CBUUID(string: $0) }
    }

    public static func isKnown(_ uuid: String) -> Bool {
        knownServiceUUIDStrings.contains(uuid.lowercased())
    }

    public static func isExcluded(_ uuid: String) -> Bool {
        excludedServiceUUIDStrings.contains(uuid.lowercased())
    }

    public static func isNordicUART(_ uuid: String) -> Bool {
        uuid.lowercased() == nordicUARTServiceUUIDString
    }
}
