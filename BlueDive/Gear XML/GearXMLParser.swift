import Foundation

// MARK: - GearXMLParser

/// Parses XML files produced by GearXMLExporter.
/// The root element is `<blueDiveGearExport>` and each gear item
/// lives inside a `<gear>` element.
final class GearXMLParser: NSObject, XMLParserDelegate {

    // MARK: - Parsed Result

    struct ParsedGear {
        var id: UUID
        var name: String
        var category: String
        var manufacturer: String?
        var model: String?
        var serialNumber: String?
        var datePurchased: Date
        var purchasePrice: Double?
        var currency: String?
        var purchasedFrom: String?
        var lastServiceDate: Date?
        var nextServiceDue: Date?
        var serviceHistory: String?
        var gearNotes: String?
        var weightContribution: Double
        var weightContributionUnit: String?
        var isInactive: Bool
        var diverName: String
    }

    private(set) var gearItems: [ParsedGear] = []

    // MARK: - Parser Context

    private var currentText = ""
    private var isValidDocument = false
    private var isInGear = false
    private var isInMetadata = false

    // MARK: - Temporary State

    private var tempID: String?
    private var tempName: String?
    private var tempCategory: String?
    private var tempManufacturer: String?
    private var tempModel: String?
    private var tempSerialNumber: String?
    private var tempDatePurchased: Date?
    private var tempPurchasePrice: String?
    private var tempCurrency: String?
    private var tempPurchasedFrom: String?
    private var tempLastServiceDate: Date?
    private var tempNextServiceDue: Date?
    private var tempServiceHistory: String?
    private var tempGearNotes: String?
    private var tempWeightContribution: String?
    private var tempWeightContributionUnit: String?
    private var tempIsInactive: String?
    private var tempDiverName: String?

    // MARK: - Date Formatter

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    // MARK: - Public API

    func parse(data: Data) -> [ParsedGear]? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(), isValidDocument else { return nil }
        return gearItems
    }

    // MARK: - XMLParserDelegate — Element Start

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentText = ""

        switch elementName {
        case "blueDiveGearExport":
            isValidDocument = true
        case "gear":
            isInGear = true
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

        if isInGear {
            parseGearElement(elementName, text: text)
        }

        currentText = ""
    }

    // MARK: - Element Parsing

    private func parseGearElement(_ elementName: String, text: String) {
        switch elementName {
        case "id":                   tempID = text.nilIfEmpty
        case "name":                 tempName = text.nilIfEmpty
        case "category":             tempCategory = text.nilIfEmpty
        case "manufacturer":         tempManufacturer = text.nilIfEmpty
        case "model":                tempModel = text.nilIfEmpty
        case "serialNumber":         tempSerialNumber = text.nilIfEmpty
        case "datePurchased":        tempDatePurchased = dateFormatter.date(from: text)
        case "purchasePrice":        tempPurchasePrice = text.nilIfEmpty
        case "currency":             tempCurrency = text.nilIfEmpty
        case "purchasedFrom":        tempPurchasedFrom = text.nilIfEmpty
        case "lastServiceDate":      tempLastServiceDate = dateFormatter.date(from: text)
        case "nextServiceDue":       tempNextServiceDue = dateFormatter.date(from: text)
        case "serviceHistory":       tempServiceHistory = text.nilIfEmpty
        case "gearNotes":            tempGearNotes = text.nilIfEmpty
        case "weightContribution":   tempWeightContribution = text.nilIfEmpty
        case "weightContributionUnit": tempWeightContributionUnit = text.nilIfEmpty
        case "isInactive":           tempIsInactive = text.nilIfEmpty
        case "diverName":            tempDiverName = text.nilIfEmpty
        case "gear":
            // Resolve category: prefer exportKey lookup, fall back to stored string
            let rawCategory = tempCategory ?? ""
            let resolvedCategory = GearCategory(exportKeyOrRawValue: rawCategory)?.rawValue ?? rawCategory

            let parsed = ParsedGear(
                // Missing/invalid <id> gets a new UUID — dedup by UUID won't match
                // items from other devices that exported the same gear independently.
                id: UUID(uuidString: tempID ?? "") ?? UUID(),
                name: tempName ?? "",
                category: resolvedCategory,
                manufacturer: tempManufacturer,
                model: tempModel,
                serialNumber: tempSerialNumber,
                datePurchased: tempDatePurchased ?? Date(),
                purchasePrice: tempPurchasePrice.flatMap(Double.init),
                currency: tempCurrency,
                purchasedFrom: tempPurchasedFrom,
                lastServiceDate: tempLastServiceDate,
                nextServiceDue: tempNextServiceDue,
                serviceHistory: tempServiceHistory,
                gearNotes: tempGearNotes,
                // 0.0 matches the model's documented default for missing weight data
                weightContribution: tempWeightContribution.flatMap(Double.init) ?? 0.0,
                weightContributionUnit: tempWeightContributionUnit,
                isInactive: tempIsInactive == "true",
                diverName: tempDiverName ?? ""
            )
            gearItems.append(parsed)
            isInGear = false
        default:
            break
        }
    }

    // MARK: - Reset

    private func resetTemp() {
        tempID = nil
        tempName = nil
        tempCategory = nil
        tempManufacturer = nil
        tempModel = nil
        tempSerialNumber = nil
        tempDatePurchased = nil
        tempPurchasePrice = nil
        tempCurrency = nil
        tempPurchasedFrom = nil
        tempLastServiceDate = nil
        tempNextServiceDue = nil
        tempServiceHistory = nil
        tempGearNotes = nil
        tempWeightContribution = nil
        tempWeightContributionUnit = nil
        tempIsInactive = nil
        tempDiverName = nil
    }
}

// MARK: - String Helper

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
