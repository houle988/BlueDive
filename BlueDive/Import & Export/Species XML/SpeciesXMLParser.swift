import Foundation

// MARK: - SpeciesXMLParser

/// Parses XML files produced by `SpeciesXMLExporter`.
/// The root element is `<blueDiveSpeciesExport>` and each species lives inside a
/// `<species>` element of `<speciesList>`; the same species elements are read from the
/// `<speciesCatalogue>` block of a BlueDive dive file (`init(containerPath:stopElements:)`).
/// Values are read as written (not trimmed); an omitted optional element stays nil. An
/// element is read only at its place in that layout
/// (a species field as a direct child of `<species>`, `altName` in its `<altNames>`, the
/// image fields in its `<featuredImage>`), so an element this version does not know —
/// e.g. a block a later version adds inside `<species>` — is skipped with everything in it,
/// even when it contains elements named like species fields. Nonisolated: runs off the main
/// actor.
nonisolated final class SpeciesXMLParser: NSObject, XMLParserDelegate {

    // MARK: - Parsed Result

    nonisolated struct ParsedSpecies: Sendable {
        var id: UUID?
        var createdAt: Date?
        var commonName: String = ""
        var scientificName: String?
        var category: String?
        var averageSize: Double?
        var averageSizeUnit: String?
        var notes: String?
        var altNames: [String]?
        var inatTaxonID: Int?
        var inatCommonNamesData: Data?
        var taxonomyData: Data?
        var wikipediaSummary: String?
        var wikipediaURL: String?
        var inatFetchedAt: Date?
        var imageData: Data?
        var thumbnailData: Data?
        var imageAttribution: String?

        /// The names the species is known by in the file, for duplicate matching: its common,
        /// scientific and other names, and its iNaturalist common names (the catalogue's own
        /// iNaturalist names are matched too, see `SpeciesNameIndex`).
        var names: [String] {
            let inatNames = inatCommonNamesData
                .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }?
                .values.filter { !$0.isEmpty } ?? []
            return [commonName, scientificName ?? ""] + (altNames ?? []) + inatNames
        }
    }

    private(set) var species: [ParsedSpecies] = []

    // MARK: - Parser Context

    /// Where the `<species>` elements are: `<blueDiveSpeciesExport>` → `<speciesList>` in a
    /// species catalogue file, `<blueDiveExport>` → `<speciesCatalogue>` in a dive file.
    private let containerPath: [String]
    private let speciesPath: [String]
    /// Children of the root at which reading stops (a dive file's dives follow its species).
    private let stopElements: Set<String>
    private var stopped = false

    /// A species catalogue file (the default), or the species block of another BlueDive file:
    /// `containerPath` is the path of the element holding the `<species>` elements, from the
    /// root; reading ends at a root child named in `stopElements`.
    init(containerPath: [String] = ["blueDiveSpeciesExport", "speciesList"], stopElements: Set<String> = []) {
        self.containerPath = containerPath
        self.speciesPath = containerPath + ["species"]
        self.stopElements = stopElements
        super.init()
    }

    private var currentText = ""
    private var sawRoot = false
    /// The open elements, outermost first; the last one is the element being read.
    private var path: [String] = []
    private var current: ParsedSpecies?

    // MARK: - Date Formatter

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    // MARK: - Public API

    /// The species in `data`; nil when it is not a well-formed species export.
    func parse(data: Data) -> [ParsedSpecies]? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        // A stop is an abort, which `parse()` reports as a failure.
        guard parser.parse() || stopped, sawRoot else { return nil }
        return species
    }

    /// Base64 between the tags, line breaks and indentation ignored; nil when empty or not
    /// base64 (an empty element must not become an empty image).
    private static func decodedBase64(_ text: String) -> Data? {
        guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters), !data.isEmpty else { return nil }
        return data
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        // Reset on every element start, so a leaf's text is exactly its content (the
        // indentation between elements is never part of it).
        currentText = ""
        path.append(elementName)
        if path.count == 1 {
            sawRoot = path[0] == containerPath[0]
        } else if path.count == 2, stopElements.contains(elementName) {
            stopped = true
            parser.abortParsing()
        } else if path.elementsEqual(speciesPath) {
            current = ParsedSpecies()
        } else if path.elementsEqual(speciesPath + ["altNames"]) {
            current?.altNames = []
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer {
            currentText = ""
            if !path.isEmpty { path.removeLast() }
        }
        let text = currentText
        // `path` still ends with this element: its parent decides how it is read.
        let parentPath = path.dropLast()

        if parentPath.elementsEqual(speciesPath + ["altNames"]) {
            if elementName == "altName" { current?.altNames?.append(text) }
            return
        }
        if parentPath.elementsEqual(speciesPath + ["featuredImage"]) {
            switch elementName {
            case "imageData":     current?.imageData = Self.decodedBase64(text)
            case "thumbnailData": current?.thumbnailData = Self.decodedBase64(text)
            case "attribution":   current?.imageAttribution = text
            default:              break
            }
            return
        }
        if path.elementsEqual(speciesPath) {
            // A species needs a name to be shown and matched.
            if let parsed = current,
               !parsed.commonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                species.append(parsed)
            }
            current = nil
            return
        }
        // Everything else (metadata, unknown elements) is read only as a species field.
        guard parentPath.elementsEqual(speciesPath) else { return }

        switch elementName {
        case "id":               current?.id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines))
        case "createdAt":        current?.createdAt = dateFormatter.date(from: text)
        case "commonName":       current?.commonName = text
        case "scientificName":   current?.scientificName = text
        case "category":         current?.category = text
        case "averageSize":      current?.averageSize = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isFinite ? $0 : nil }
        case "averageSizeUnit":  current?.averageSizeUnit = text
        case "notes":            current?.notes = text
        case "inatTaxonID":      current?.inatTaxonID = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case "inatCommonNames":  current?.inatCommonNamesData = Data(text.utf8)
        case "taxonomy":         current?.taxonomyData = Data(text.utf8)
        case "wikipediaSummary": current?.wikipediaSummary = text
        case "wikipediaURL":     current?.wikipediaURL = text
        case "inatFetchedAt":    current?.inatFetchedAt = dateFormatter.date(from: text)
        default:
            break
        }
    }
}
