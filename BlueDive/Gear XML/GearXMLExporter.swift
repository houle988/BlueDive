import Foundation

// MARK: - GearXMLExporter

/// Generates a BlueDive XML document for one or more gear items.
/// Follows the same pattern as CertificationXMLExporter.
enum GearXMLExporter {

    // MARK: - Public API

    /// Generates a complete BlueDive XML string containing all provided gear items
    /// wrapped in a single `<blueDiveGearExport>` root element.
    @MainActor
    static func generateXML(for gearItems: [Gear]) -> String {
        var lines: [String] = []

        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append("<blueDiveGearExport>")

        // ── Metadata ─────────────────────────────────────────────────────────
        let appName     = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "BlueDive"
        let appVersion  = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        lines.append("  <metadata>")
        lines.append(xmlTag("software",   appName,                          indent: 4))
        lines.append(xmlTag("version",    "\(appVersion) (\(buildNumber))", indent: 4))
        lines.append(xmlTag("exportedAt", formatDate(Date()),               indent: 4))
        lines.append(xmlTag("gearCount",  String(gearItems.count),          indent: 4))
        lines.append("  </metadata>")

        // ── Gear Items ───────────────────────────────────────────────────────
        lines.append("  <gears>")
        for gear in gearItems {
            lines.append(contentsOf: gearLines(for: gear))
        }
        lines.append("  </gears>")

        lines.append("</blueDiveGearExport>")
        return lines.joined(separator: "\n")
    }

    // MARK: - Single Gear Block

    @MainActor
    private static func gearLines(for gear: Gear) -> [String] {
        var lines: [String] = []

        // Normalise category to the stable export key so round-trips work
        // regardless of how the rawValue may evolve.
        let categoryKey = GearCategory(exportKeyOrRawValue: gear.category)?.exportKey ?? gear.category

        lines.append("    <gear>")
        lines.append(xmlTag("id",                   gear.id.uuidString,                        indent: 6))
        lines.append(xmlTag("name",                 gear.name,                                 indent: 6))
        lines.append(xmlTag("category",             categoryKey,                               indent: 6))
        lines.append(xmlTag("manufacturer",         gear.manufacturer ?? "",                   indent: 6))
        lines.append(xmlTag("model",                gear.model ?? "",                          indent: 6))
        lines.append(xmlTag("serialNumber",         gear.serialNumber ?? "",                   indent: 6))
        lines.append(xmlTag("datePurchased",        formatDate(gear.datePurchased),            indent: 6))
        lines.append(xmlTag("purchasePrice",        gear.purchasePrice.map { String($0) } ?? "", indent: 6))
        lines.append(xmlTag("currency",             gear.currency ?? "",                       indent: 6))
        lines.append(xmlTag("purchasedFrom",        gear.purchasedFrom ?? "",                  indent: 6))
        lines.append(xmlTag("lastServiceDate",      gear.lastServiceDate.map(formatDate) ?? "", indent: 6))
        lines.append(xmlTag("nextServiceDue",       gear.nextServiceDue.map(formatDate) ?? "", indent: 6))
        lines.append(xmlTag("serviceHistory",       gear.serviceHistory ?? "",                 indent: 6))
        lines.append(xmlTag("gearNotes",            gear.gearNotes ?? "",                      indent: 6))
        lines.append(xmlTag("weightContribution",   String(gear.weightContribution),           indent: 6))
        lines.append(xmlTag("weightContributionUnit", gear.weightContributionUnit ?? "",       indent: 6))
        lines.append(xmlTag("isInactive",           gear.isInactive ? "true" : "false",        indent: 6))
        lines.append(xmlTag("diverName",            gear.diverName,                            indent: 6))
        lines.append("    </gear>")

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
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
