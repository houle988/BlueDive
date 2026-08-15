import Foundation

// MARK: - InsuranceXMLExporter

/// Generates a BlueDive XML document for one or more insurance records.
/// Follows the same pattern as CertificationXMLExporter.
enum InsuranceXMLExporter {

    // MARK: - Public API

    /// Generates a complete BlueDive XML string containing all provided insurance records
    /// wrapped in a single `<blueDiveInsuranceExport>` root element.
    @MainActor
    static func generateXML(for insurances: [DivingInsurance]) -> String {
        var lines: [String] = []

        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append("<blueDiveInsuranceExport>")

        // ── Metadata ─────────────────────────────────────────────────────────
        let appName     = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "BlueDive"
        let appVersion  = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        lines.append("  <metadata>")
        lines.append(xmlTag("software",        appName,                          indent: 4))
        lines.append(xmlTag("version",         "\(appVersion) (\(buildNumber))", indent: 4))
        lines.append(xmlTag("exportedAt",      formatDate(Date()),               indent: 4))
        lines.append(xmlTag("insuranceCount",  String(insurances.count),         indent: 4))
        lines.append("  </metadata>")

        // ── Insurance Records ─────────────────────────────────────────────────
        lines.append("  <insurances>")
        for insurance in insurances {
            lines.append(contentsOf: insuranceLines(for: insurance))
        }
        lines.append("  </insurances>")

        lines.append("</blueDiveInsuranceExport>")
        return lines.joined(separator: "\n")
    }

    // MARK: - Single Insurance Block

    @MainActor
    private static func insuranceLines(for insurance: DivingInsurance) -> [String] {
        var lines: [String] = []

        lines.append("    <insurance>")
        lines.append(xmlTag("id",            insurance.id.uuidString,                          indent: 6))
        lines.append(xmlTag("insurerName",   insurance.insurerName,                            indent: 6))
        lines.append(xmlTag("diverName",     insurance.diverName,                              indent: 6))
        lines.append(xmlTag("policyNumber",  insurance.policyNumber,                           indent: 6))
        lines.append(xmlTag("coverageType",  insurance.coverageType,                           indent: 6))
        lines.append(xmlTag("startDate",     formatDate(insurance.startDate),                  indent: 6))
        lines.append(xmlTag("endDate",       formatDate(insurance.endDate),                    indent: 6))
        lines.append(xmlTag("contactPhone",  insurance.contactPhone ?? "",                     indent: 6))
        lines.append(xmlTag("contactEmail",  insurance.contactEmail ?? "",                     indent: 6))
        lines.append(xmlTag("notes",         insurance.notes ?? "",                            indent: 6))
        lines.append("    </insurance>")

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
