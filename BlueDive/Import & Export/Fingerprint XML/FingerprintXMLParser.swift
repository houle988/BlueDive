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
        case "device":
            let parsed = ParsedDevice(
                serial: tempSerial ?? "",
                computerName: tempComputerName ?? "",
                familyID: tempFamilyID ?? "",
                modelID: tempModelID ?? 0,
                fingerprintData: tempFingerprint ?? Data(),
                updatedAt: tempUpdatedAt
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
    }
}

// MARK: - Hex Helper

private extension Data {
    /// Decodes a hex string ("0a1b2c…", spaces allowed). An empty string is an empty fingerprint.
    init?(fingerprintHex hex: String) {
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
        // UInt8(_:radix:) accepts a leading "+"/"-", so require hex digits only.
        guard cleaned.count % 2 == 0, cleaned.allSatisfy(\.isHexDigit) else { return nil }
        var data = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
