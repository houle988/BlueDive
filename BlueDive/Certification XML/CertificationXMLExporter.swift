import Foundation

// MARK: - CertificationXMLExporter

/// Generates a BlueDive XML document for one or more certifications.
/// Follows the same pattern as BlueDiveXMLExporter for dive data.
enum CertificationXMLExporter {

    // MARK: - Public API

    /// Generates a complete BlueDive XML string containing all provided certifications
    /// wrapped in a single `<blueDiveCertificationExport>` root element.
    @MainActor
    static func generateXML(for certifications: [Certification]) -> String {
        var lines: [String] = []

        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append("<blueDiveCertificationExport>")

        // ── Metadata ─────────────────────────────────────────────────────────
        let appName     = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "BlueDive"
        let appVersion  = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        lines.append("  <metadata>")
        lines.append(xmlTag("software",           appName,                          indent: 4))
        lines.append(xmlTag("version",            "\(appVersion) (\(buildNumber))", indent: 4))
        lines.append(xmlTag("exportedAt",         formatDate(Date()),               indent: 4))
        lines.append(xmlTag("certificationCount", String(certifications.count),     indent: 4))
        lines.append("  </metadata>")

        // ── Certifications ───────────────────────────────────────────────────
        lines.append("  <certifications>")
        for cert in certifications {
            lines.append(contentsOf: certificationLines(for: cert))
        }
        lines.append("  </certifications>")

        lines.append("</blueDiveCertificationExport>")
        return lines.joined(separator: "\n")
    }

    // MARK: - Single Certification Block

    @MainActor
    private static func certificationLines(for cert: Certification) -> [String] {
        var lines: [String] = []

        lines.append("    <certification>")
        lines.append(xmlTag("id",                  cert.id.uuidString,                              indent: 6))
        lines.append(xmlTag("name",                cert.name,                                       indent: 6))
        lines.append(xmlTag("organization",        cert.organization,                               indent: 6))
        lines.append(xmlTag("level",               cert.level,                                      indent: 6))
        lines.append(xmlTag("certificationNumber", cert.certificationNumber,                        indent: 6))
        lines.append(xmlTag("issueDate",           formatDate(cert.issueDate),                      indent: 6))
        lines.append(xmlTag("expirationDate",      cert.expirationDate.map(formatDate) ?? "",       indent: 6))
        lines.append(xmlTag("instructorName",      cert.instructorName ?? "",                        indent: 6))
        lines.append(xmlTag("notes",               cert.notes ?? "",                                indent: 6))
        lines.append("    </certification>")

        return lines
    }

    // MARK: - XML Helpers

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

    static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
