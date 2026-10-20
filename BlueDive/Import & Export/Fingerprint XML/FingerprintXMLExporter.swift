import Foundation

// MARK: - FingerprintXMLExporter

/// Generates a BlueDive XML document for the dive computer sync fingerprints
/// (`DeviceFingerprint` records). Follows the same pattern as CertificationXMLExporter.
enum FingerprintXMLExporter {

    // MARK: - Public API

    /// Generates a complete BlueDive XML string containing all provided device fingerprints
    /// wrapped in a single `<blueDiveFingerprintExport>` root element.
    @MainActor
    static func generateXML(for devices: [DeviceFingerprint]) -> String {
        var lines: [String] = []

        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append("<blueDiveFingerprintExport>")

        // ── Metadata ─────────────────────────────────────────────────────────
        let appName     = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "BlueDive"
        let appVersion  = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        lines.append("  <metadata>")
        lines.append(xmlTag("software",    appName,                          indent: 4))
        lines.append(xmlTag("version",     "\(appVersion) (\(buildNumber))", indent: 4))
        lines.append(xmlTag("exportedAt",  formatDate(Date()),               indent: 4))
        lines.append(xmlTag("deviceCount", String(devices.count),            indent: 4))
        lines.append("  </metadata>")

        // ── Devices ──────────────────────────────────────────────────────────
        lines.append("  <devices>")
        for device in devices {
            lines.append(contentsOf: deviceLines(for: device))
        }
        lines.append("  </devices>")

        lines.append("</blueDiveFingerprintExport>")
        return lines.joined(separator: "\n")
    }

    // MARK: - Single Device Block

    @MainActor
    private static func deviceLines(for device: DeviceFingerprint) -> [String] {
        var lines: [String] = []

        lines.append("    <device>")
        lines.append(xmlTag("serial",       device.serial,                    indent: 6))
        lines.append(xmlTag("computerName", device.computerName,              indent: 6))
        lines.append(xmlTag("familyID",     device.familyID,                  indent: 6))
        lines.append(xmlTag("modelID",      String(device.modelID),           indent: 6))
        // Lowercase hex, the same notation the Sync Fingerprints editor shows and accepts.
        lines.append(xmlTag("fingerprint",  hexString(device.fingerprintData), indent: 6))
        lines.append(xmlTag("updatedAt",    formatDate(device.updatedAt),     indent: 6))
        lines.append("    </device>")

        return lines
    }

    // MARK: - XML Helpers

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func xmlTag(_ name: String, _ value: String, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        return "\(pad)<\(name)>\(xmlEscape(value))</\(name)>"
    }

    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&",  with: "&amp;")
            .replacingOccurrences(of: "<",  with: "&lt;")
            .replacingOccurrences(of: ">",  with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'",  with: "&apos;")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
