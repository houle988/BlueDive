import Foundation

// MARK: - FingerprintXMLParser

/// Parses XML files produced by FingerprintXMLExporter.
/// The root element is `<blueDiveFingerprintExport>` and each dive computer
/// lives inside a `<device>` element.
final class FingerprintXMLParser: NSObject, XMLParserDelegate {

    // MARK: - Parsed Result

    struct ParsedDevice {
        var serial: String
        var computerName: String
        var familyID: String
        var modelID: UInt32
        var fingerprintData: Data
        var updatedAt: Date?
        /// `<isBackupComputer>`; false when the element is absent (older exports).
        var isBackupComputer: Bool = false
    }

    enum ParseError: Error {
        /// The file is not well-formed XML or is not a BlueDive fingerprint export.
        case invalidFile
        /// A `<fingerprint>` or `<modelID>` value could not be read; nothing is imported.
        case invalidValue
    }

    private(set) var devices: [ParsedDevice] = []

    // MARK: - Parser Context

    private var currentText = ""
    private var isRootValid = false
    private var isInDevice = false
    private var isInMetadata = false
    private var hasInvalidValue = false

    // MARK: - Temporary State

    private var tempSerial: String?
    private var tempComputerName: String?
    private var tempFamilyID: String?
    private var tempModelID: UInt32?
    private var tempFingerprint: Data?
    private var tempUpdatedAt: Date?
    private var tempIsBackup: Bool?

    // MARK: - Date Formatter

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    // MARK: - Public API

    func parse(data: Data) -> Result<[ParsedDevice], ParseError> {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse(), isRootValid else { return .failure(.invalidFile) }
        guard !hasInvalidValue else { return .failure(.invalidValue) }
        return .success(devices)
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
        case "blueDiveFingerprintExport":
            isRootValid = true
        case "device":
            isInDevice = true
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

        if isInDevice {
            parseDeviceElement(elementName, text: text)
        }

        currentText = ""
    }

    // MARK: - Element Parsing

    private func parseDeviceElement(_ elementName: String, text: String) {
        switch elementName {
        case "serial":       tempSerial = text
        case "computerName": tempComputerName = text
        case "familyID":     tempFamilyID = text
        case "modelID":
            if text.isEmpty {
                tempModelID = 0
            } else if let value = UInt32(text) {
                tempModelID = value
            } else {
                hasInvalidValue = true
            }
        case "fingerprint":
            if let data = Data(fingerprintHex: text) {
                tempFingerprint = data
            } else {
                hasInvalidValue = true
            }
        case "updatedAt":    tempUpdatedAt = dateFormatter.date(from: text)
        case "isBackupComputer":
            // Anything but true/1 reads as a main dive computer: the flag only ever stops a
            // download, so an unreadable value must not refuse the whole file.
            tempIsBackup = ["true", "1"].contains(text.lowercased())
        case "device":
            let parsed = ParsedDevice(
                serial: tempSerial ?? "",
                computerName: tempComputerName ?? "",
                familyID: tempFamilyID ?? "",
                modelID: tempModelID ?? 0,
                fingerprintData: tempFingerprint ?? Data(),
                updatedAt: tempUpdatedAt,
                isBackupComputer: tempIsBackup ?? false
            )
            devices.append(parsed)
            isInDevice = false
        default:
            break
        }
    }

    // MARK: - Reset

    private func resetTemp() {
        tempSerial = nil
        tempComputerName = nil
        tempFamilyID = nil
        tempModelID = nil
        tempFingerprint = nil
        tempUpdatedAt = nil
        tempIsBackup = nil
    }
}
