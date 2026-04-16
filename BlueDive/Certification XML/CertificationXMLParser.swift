import Foundation

// MARK: - CertificationXMLParser

/// Parses XML files produced by CertificationXMLExporter.
/// The root element is `<blueDiveCertificationExport>` and each certification
/// lives inside a `<certification>` element.
final class CertificationXMLParser: NSObject, XMLParserDelegate {

    // MARK: - Parsed Result

    struct ParsedCertification {
        var id: UUID
        var name: String
        var organization: String
        var level: String
        var certificationNumber: String
        var issueDate: Date
        var expirationDate: Date?
        var instructorName: String?
        var notes: String?
    }

    private(set) var certifications: [ParsedCertification] = []

    // MARK: - Parser Context

    private var currentElement = ""
    private var currentText = ""
    private var isInCertification = false
    private var isInMetadata = false

    // MARK: - Temporary State

    private var tempID: String?
    private var tempName: String?
    private var tempOrganization: String?
    private var tempLevel: String?
    private var tempCertificationNumber: String?
    private var tempIssueDate: Date?
    private var tempExpirationDate: Date?
    private var tempInstructorName: String?
    private var tempNotes: String?

    // MARK: - Date Formatter

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    // MARK: - Public API

    func parse(data: Data) -> [ParsedCertification]? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse() ? certifications : nil
    }

    // MARK: - XMLParserDelegate — Element Start

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        currentText = ""

        switch elementName {
        case "certification":
            isInCertification = true
            resetTemp()
        case "metadata":
            isInMetadata = true
        default:
            break
        }
    }

    // MARK: - XMLParserDelegate — Characters

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    // MARK: - XMLParserDelegate — Element End

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Skip metadata block
        if isInMetadata {
            if elementName == "metadata" { isInMetadata = false }
            currentText = ""
            return
        }

        if isInCertification {
            parseCertificationElement(elementName, text: text)
        }

        currentText = ""
    }

    // MARK: - Element Parsing

    private func parseCertificationElement(_ elementName: String, text: String) {
        switch elementName {
        case "id":                  tempID = text.nilIfEmpty
        case "name":                tempName = text.nilIfEmpty
        case "organization":        tempOrganization = text.nilIfEmpty
        case "level":               tempLevel = text.nilIfEmpty
        case "certificationNumber": tempCertificationNumber = text.nilIfEmpty
        case "issueDate":           tempIssueDate = dateFormatter.date(from: text)
        case "expirationDate":      tempExpirationDate = dateFormatter.date(from: text)
        case "instructorName":      tempInstructorName = text.nilIfEmpty
        case "notes":               tempNotes = text.nilIfEmpty
        case "certification":
            let parsed = ParsedCertification(
                id: UUID(uuidString: tempID ?? "") ?? UUID(),
                name: tempName ?? "",
                organization: tempOrganization ?? "",
                level: tempLevel ?? "",
                certificationNumber: tempCertificationNumber ?? "",
                issueDate: tempIssueDate ?? Date(),
                expirationDate: tempExpirationDate,
                instructorName: tempInstructorName,
                notes: tempNotes
            )
            certifications.append(parsed)
            isInCertification = false
        default:
            break
        }
    }

    // MARK: - Reset

    private func resetTemp() {
        tempID = nil
        tempName = nil
        tempOrganization = nil
        tempLevel = nil
        tempCertificationNumber = nil
        tempIssueDate = nil
        tempExpirationDate = nil
        tempInstructorName = nil
        tempNotes = nil
    }
}

// MARK: - String Helper

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
