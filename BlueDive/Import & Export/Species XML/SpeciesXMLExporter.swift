import Foundation

// MARK: - SpeciesXMLExporter

/// Generates a BlueDive XML document for the marine-life catalogue.
/// Follows the same pattern as GearXMLExporter; read back by `SpeciesXMLParser`.
///
/// Every value is written as stored: an optional field that is nil is omitted (so an empty
/// string and no value stay distinct), the category is written as its stored key or custom
/// name, and the iNaturalist JSON fields are written as their JSON text. Sightings and
/// photos are not exported (statistics are calculated from the dives).
enum SpeciesXMLExporter {

    // MARK: - Public API

    /// Generates a complete BlueDive XML string containing `species`, wrapped in a single
    /// `<blueDiveSpeciesExport>` root element. With `includeImages`, each species' featured
    /// image (and its thumbnail and attribution) is embedded as base64.
    @MainActor
    static func generateXML(for species: [Species], includeImages: Bool) -> String {
        var lines: [String] = []

        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append("<blueDiveSpeciesExport>")

        // ── Metadata ─────────────────────────────────────────────────────────
        let appName     = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "BlueDive"
        let appVersion  = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        lines.append("  <metadata>")
        lines.append(xmlTag("software",      appName,                          indent: 4))
        lines.append(xmlTag("version",       "\(appVersion) (\(buildNumber))", indent: 4))
        lines.append(xmlTag("exportedAt",    formatDate(Date()),               indent: 4))
        lines.append(xmlTag("speciesCount",  String(species.count),            indent: 4))
        lines.append(xmlTag("includesImages", includeImages ? "true" : "false", indent: 4))
        lines.append("  </metadata>")

        // ── Species ──────────────────────────────────────────────────────────
        lines.append("  <speciesList>")
        for item in species {
            lines.append(contentsOf: speciesLines(for: item, includeImages: includeImages))
        }
        lines.append("  </speciesList>")

        lines.append("</blueDiveSpeciesExport>")
        return lines.joined(separator: "\n")
    }

    // MARK: - Single Species Block

    /// One `<species>` element at `indent` (its fields two spaces deeper). Also written by
    /// `BlueDiveXMLExporter` for the species a dive export links to, so both files share one
    /// species format.
    @MainActor
    static func speciesLines(for species: Species, includeImages: Bool, indent: Int = 4) -> [String] {
        let pad = String(repeating: " ", count: indent)
        let field = indent + 2
        var lines: [String] = []
        lines.append("\(pad)<species>")
        lines.append(xmlTag("id",        species.id.uuidString,         indent: field))
        lines.append(xmlTag("createdAt", formatDate(species.createdAt), indent: field))
        lines.append(xmlTag("commonName", species.commonName,           indent: field))
        appendOptional("scientificName",  species.scientificName,                    indent: field, to: &lines)
        appendOptional("category",        species.category,                          indent: field, to: &lines)
        appendOptional("averageSize",     species.averageSize.map { String($0) },    indent: field, to: &lines)
        appendOptional("averageSizeUnit", species.averageSizeUnit,                   indent: field, to: &lines)
        appendOptional("notes",           species.notes,                             indent: field, to: &lines)
        if let altNames = species.altNames {
            lines.append("\(pad)  <altNames>")
            for name in altNames {
                lines.append(xmlTag("altName", name, indent: field + 2))
            }
            lines.append("\(pad)  </altNames>")
        }
        appendOptional("inatTaxonID",      species.inatTaxonID.map { String($0) },   indent: field, to: &lines)
        appendOptional("inatCommonNames",  species.inatCommonNamesData.map(jsonText), indent: field, to: &lines)
        appendOptional("taxonomy",         species.taxonomyData.map(jsonText),        indent: field, to: &lines)
        appendOptional("wikipediaSummary", species.wikipediaSummary,                 indent: field, to: &lines)
        appendOptional("wikipediaURL",     species.wikipediaURL,                     indent: field, to: &lines)
        appendOptional("inatFetchedAt",    species.inatFetchedAt.map(formatDate),    indent: field, to: &lines)

        if includeImages, let image = species.image, let imageData = image.imageData {
            lines.append("\(pad)  <featuredImage>")
            appendBase64("imageData", imageData, indent: field + 2, to: &lines)
            if let thumbnail = image.thumbnailData {
                appendBase64("thumbnailData", thumbnail, indent: field + 2, to: &lines)
            }
            if let attribution = image.attribution {
                lines.append(xmlTag("attribution", attribution, indent: field + 2))
            }
            lines.append("\(pad)  </featuredImage>")
        }

        lines.append("\(pad)</species>")
        return lines
    }

    // MARK: - XML Helpers

    private static func appendOptional(_ name: String, _ value: String?, indent: Int, to lines: inout [String]) {
        guard let value else { return }
        lines.append(xmlTag(name, value, indent: indent))
    }

    /// Base64 in 76-character lines between the tags, as `BlueDiveXMLExporter` writes its own
    /// binary data: an image on a single line of hundreds of kilobytes would be shown whole by
    /// the dive XML preview (`XMLExportTabView` limits lines, not characters). The parser
    /// ignores the line breaks and indentation (`.ignoreUnknownCharacters`).
    private static func appendBase64(_ name: String, _ data: Data, indent: Int, to lines: inout [String]) {
        let pad = String(repeating: " ", count: indent)
        lines.append("\(pad)<\(name)>")
        let base64 = data.base64EncodedString(options: .lineLength76Characters)
        for chunk in base64.components(separatedBy: CharacterSet.newlines) where !chunk.isEmpty {
            lines.append("\(pad)  \(chunk)")
        }
        lines.append("\(pad)</\(name)>")
    }

    /// The stored JSON as text (JSON is UTF-8), read back byte for byte by the parser.
    private static func jsonText(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
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
            // A carriage return would be read back as a line feed (XML end-of-line handling).
            .replacingOccurrences(of: "\r", with: "&#13;")
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    private static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}
