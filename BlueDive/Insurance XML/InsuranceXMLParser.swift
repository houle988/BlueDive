import Foundation

// MARK: - InsuranceXMLParser

/// Parses XML files produced by InsuranceXMLExporter.
/// The root element is `<blueDiveInsuranceExport>` and each record
/// lives inside an `<insurance>` element.
final class InsuranceXMLParser: NSObject, XMLParserDelegate {

    // MARK: - Parsed Result

    struct ParsedInsurance {
        var id: UUID
        var insurerName: String
        var diverName: String
        var policyNumber: String
        var coverageType: String
        var startDate: Date
        var endDate: Date
        var contactPhone: String?
        var contactEmail: String?
        var notes: String?
    }

    private(set) var insurances: [ParsedInsurance] = []

    // MARK: - Parser Context

    private var currentElement = ""
    private var currentText = ""
    private var isInInsurance = false
    private var isInMetadata = false

    // MARK: - Temporary State

    private var tempID: String?
    private var tempInsurerName: String?
    private var tempDiverName: String?
    private var tempPolicyNumber: String?
    private var tempCoverageType: String?
    private var tempStartDate: Date?
    private var tempEndDate: Date?
    private var tempContactPhone: String?
    private var tempContactEmail: String?
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

    func parse(data: Data) -> [ParsedInsurance]? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse() ? insurances : nil
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
        case "insurance":
            isInInsurance = true
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

        if isInInsurance {
            parseInsuranceElement(elementName, text: text)
        }

        currentText = ""
    }

    // MARK: - Element Parsing

    private func parseInsuranceElement(_ elementName: String, text: String) {
        switch elementName {
        case "id":           tempID = text.nilIfEmpty
        case "insurerName":  tempInsurerName = text.nilIfEmpty
        case "diverName":    tempDiverName = text.nilIfEmpty
        case "policyNumber": tempPolicyNumber = text.nilIfEmpty
        case "coverageType": tempCoverageType = text.nilIfEmpty
        case "startDate":    tempStartDate = dateFormatter.date(from: text)
        case "endDate":      tempEndDate = dateFormatter.date(from: text)
        case "contactPhone": tempContactPhone = text.nilIfEmpty
        case "contactEmail": tempContactEmail = text.nilIfEmpty
        case "notes":        tempNotes = text.nilIfEmpty
        case "insurance":
            // Skip records with a missing or unreadable date to avoid storing estimated data.
            guard let resolvedStart = tempStartDate,
                  let resolvedEnd = tempEndDate else {
                isInInsurance = false
                break
            }
            let parsed = ParsedInsurance(
                id: UUID(uuidString: tempID ?? "") ?? UUID(),
                insurerName: tempInsurerName ?? "",
                diverName: tempDiverName ?? "",
                policyNumber: tempPolicyNumber ?? "",
                coverageType: tempCoverageType ?? "",
                startDate: resolvedStart,
                endDate: resolvedEnd,
                contactPhone: tempContactPhone,
                contactEmail: tempContactEmail,
                notes: tempNotes
            )
            insurances.append(parsed)
            isInInsurance = false
        default:
            break
        }
    }

    // MARK: - Reset

    private func resetTemp() {
        tempID = nil
        tempInsurerName = nil
        tempDiverName = nil
        tempPolicyNumber = nil
        tempCoverageType = nil
        tempStartDate = nil
        tempEndDate = nil
        tempContactPhone = nil
        tempContactEmail = nil
        tempNotes = nil
    }
}

// MARK: - String Helper

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
