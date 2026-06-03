import Foundation

// MARK: - GearXMLParser

/// Parses XML files produced by GearXMLExporter.
/// The root element is `<blueDiveGearExport>` and contains
/// `<gears>`, `<gearGroups>`, and `<tankTemplates>` sections.
final class GearXMLParser: NSObject, XMLParserDelegate {

    // MARK: - Parsed Result Types

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

    struct ParsedGearGroup {
        var id: UUID
        var name: String
        var gearIDs: [UUID]
    }

    struct ParsedTankTemplate {
        var id: UUID
        var name: String
        var volume: Double?
        var workingPressure: Double?
        var volumeUnit: String
        var pressureUnit: String
        var material: String?
        var format: String?
        var manufacturer: String?
        var model: String?
    }

    struct GearParseResult {
        let gearItems: [ParsedGear]
        let gearGroups: [ParsedGearGroup]
        let tankTemplates: [ParsedTankTemplate]

        var isEmpty: Bool { gearItems.isEmpty && gearGroups.isEmpty && tankTemplates.isEmpty }
    }

    private(set) var gearItems: [ParsedGear] = []
    private(set) var gearGroups: [ParsedGearGroup] = []
    private(set) var tankTemplates: [ParsedTankTemplate] = []

    // MARK: - Parser Context

    private var currentText = ""
    private var isValidDocument = false
    private var isInGear = false
    private var isInGearGroup = false
    private var isInGearIDs = false
    private var isInTankTemplate = false
    private var isInMetadata = false

    // MARK: - Temporary State — Gear

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

    // MARK: - Temporary State — Gear Group

    private var tempGroupID: String?
    private var tempGroupName: String?
    private var tempGroupGearIDs: [UUID] = []

    // MARK: - Temporary State — Tank Template

    private var tempTemplateID: String?
    private var tempTemplateName: String?
    private var tempTemplateVolume: String?
    private var tempTemplateWorkingPressure: String?
    private var tempTemplateVolumeUnit: String?
    private var tempTemplatePressureUnit: String?
    private var tempTemplateMaterial: String?
    private var tempTemplateFormat: String?
    private var tempTemplateManufacturer: String?
    private var tempTemplateModel: String?

    // MARK: - Date Formatter

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    // MARK: - Public API

    func parse(data: Data) -> GearParseResult? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(), isValidDocument else { return nil }
        return GearParseResult(gearItems: gearItems, gearGroups: gearGroups, tankTemplates: tankTemplates)
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
            resetGearTemp()
        case "gearGroup":
            isInGearGroup = true
            resetGroupTemp()
        case "gearIDs":
            isInGearIDs = true
        case "tankTemplate":
            isInTankTemplate = true
            resetTemplateTemp()
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

        if isInMetadata {
            if elementName == "metadata" { isInMetadata = false }
            currentText = ""
            return
        }

        if isInGear {
            parseGearElement(elementName, text: text)
        } else if isInGearGroup {
            parseGearGroupElement(elementName, text: text)
        } else if isInTankTemplate {
            parseTankTemplateElement(elementName, text: text)
        }

        currentText = ""
    }

    // MARK: - Gear Element Parsing

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
            let rawCategory = tempCategory ?? ""
            // Prefer exportKey lookup so renamed display strings don't break import; fall back to the stored string.
            let resolvedCategory = GearCategory(exportKeyOrRawValue: rawCategory)?.rawValue ?? rawCategory
            let parsed = ParsedGear(
                // Missing/invalid <id> gets a new UUID — dedup by UUID won't match items from other devices
                // that exported the same gear independently with a different UUID.
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
                // 0.0 matches the model's documented default; a missing <weightContribution> tag means no weight data.
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

    // MARK: - Gear Group Element Parsing

    private func parseGearGroupElement(_ elementName: String, text: String) {
        switch elementName {
        case "id":
            if !isInGearIDs { tempGroupID = text.nilIfEmpty }
        case "name":
            tempGroupName = text.nilIfEmpty
        case "gearIDs":
            isInGearIDs = false
        case "gearID":
            if let uuid = UUID(uuidString: text) {
                tempGroupGearIDs.append(uuid)
            }
        case "gearGroup":
            let parsed = ParsedGearGroup(
                // Missing/invalid <id> gets a new UUID — dedup by UUID won't match groups from other devices
                // that exported independently with a different UUID.
                id: UUID(uuidString: tempGroupID ?? "") ?? UUID(),
                name: tempGroupName ?? "",
                gearIDs: tempGroupGearIDs
            )
            gearGroups.append(parsed)
            isInGearGroup = false
        default:
            break
        }
    }

    // MARK: - Tank Template Element Parsing

    private func parseTankTemplateElement(_ elementName: String, text: String) {
        switch elementName {
        case "id":              tempTemplateID = text.nilIfEmpty
        case "name":            tempTemplateName = text.nilIfEmpty
        case "volume":          tempTemplateVolume = text.nilIfEmpty
        case "workingPressure": tempTemplateWorkingPressure = text.nilIfEmpty
        case "volumeUnit":      tempTemplateVolumeUnit = text.nilIfEmpty
        case "pressureUnit":    tempTemplatePressureUnit = text.nilIfEmpty
        case "material":        tempTemplateMaterial = text.nilIfEmpty
        case "format":          tempTemplateFormat = text.nilIfEmpty
        case "manufacturer":    tempTemplateManufacturer = text.nilIfEmpty
        case "model":           tempTemplateModel = text.nilIfEmpty
        case "tankTemplate":
            let parsed = ParsedTankTemplate(
                // Missing/invalid <id> gets a new UUID — dedup by UUID won't match templates from other devices
                // that exported independently with a different UUID.
                id: UUID(uuidString: tempTemplateID ?? "") ?? UUID(),
                name: tempTemplateName ?? "",
                volume: tempTemplateVolume.flatMap(Double.init),
                workingPressure: tempTemplateWorkingPressure.flatMap(Double.init),
                volumeUnit: tempTemplateVolumeUnit ?? "liters",
                pressureUnit: tempTemplatePressureUnit ?? "bar",
                material: tempTemplateMaterial,
                format: tempTemplateFormat,
                manufacturer: tempTemplateManufacturer,
                model: tempTemplateModel
            )
            tankTemplates.append(parsed)
            isInTankTemplate = false
        default:
            break
        }
    }

    // MARK: - Reset

    private func resetGearTemp() {
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

    private func resetGroupTemp() {
        tempGroupID = nil
        tempGroupName = nil
        tempGroupGearIDs = []
        isInGearIDs = false
    }

    private func resetTemplateTemp() {
        tempTemplateID = nil
        tempTemplateName = nil
        tempTemplateVolume = nil
        tempTemplateWorkingPressure = nil
        tempTemplateVolumeUnit = nil
        tempTemplatePressureUnit = nil
        tempTemplateMaterial = nil
        tempTemplateFormat = nil
        tempTemplateManufacturer = nil
        tempTemplateModel = nil
    }
}

// MARK: - String Helper

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
