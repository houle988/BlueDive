import Foundation

// MARK: - Shearwater PNF GPS Extraction

enum ShearwaterPNFGPS {

    /// Extracts entry-point GPS from Shearwater raw dive data (PNF format).
    /// Scans for opening record 9 (type 0x19) and reads lat/lon at offsets +21/+25
    /// as signed int32 big-endian ÷ 100000.
    static func extractEntryGPS(from rawData: Data) -> (latitude: Double, longitude: Double)? {
        extractGPS(from: rawData, recordType: 0x19)
    }

    /// Extracts exit-point GPS from Shearwater raw dive data (PNF format).
    /// Scans for closing record 9 (type 0x29) and reads lat/lon at offsets +21/+25
    /// as signed int32 big-endian ÷ 100000.
    static func extractExitGPS(from rawData: Data) -> (latitude: Double, longitude: Double)? {
        extractGPS(from: rawData, recordType: 0x29)
    }

    // MARK: - Private

    private static let recordSize = 0x20 // 32 bytes per PNF record

    private static func extractGPS(from rawData: Data, recordType: UInt8) -> (latitude: Double, longitude: Double)? {
        guard rawData.count >= recordSize,
              !(rawData[0] == 0xFF && rawData[1] == 0xFF) else { return nil }

        var offset = 0
        while offset + recordSize <= rawData.count {
            if rawData[offset] == recordType {
                guard offset + 29 <= rawData.count else { break }
                let latRaw = Int32(bigEndian: rawData.subdata(in: (offset + 21)..<(offset + 25)).withUnsafeBytes { $0.load(as: Int32.self) })
                let lonRaw = Int32(bigEndian: rawData.subdata(in: (offset + 25)..<(offset + 29)).withUnsafeBytes { $0.load(as: Int32.self) })

                if (latRaw == 0 && lonRaw == 0) || (latRaw == -1 && lonRaw == -1) {
                    offset += recordSize
                    continue
                }

                let lat = Double(latRaw) / 100000.0
                let lon = Double(lonRaw) / 100000.0

                guard (-90...90).contains(lat), (-180...180).contains(lon) else {
                    offset += recordSize
                    continue
                }

                return (lat, lon)
            }
            offset += recordSize
        }
        return nil
    }
}
