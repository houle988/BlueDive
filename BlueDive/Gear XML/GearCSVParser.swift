import Foundation

// MARK: - GearCSVParser

/// Parses the gear CSV file exported by MacDive.
/// Expected columns: Manufacturer, Name, Type, Serial, Weight, Purchase Date, Purchase Price, Shop, Warranty, Last Service
final class GearCSVParser {

    // MARK: - Date Formatter

    private lazy var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: - Public API

    /// Parses gear from CSV data and returns parsed items, or nil when parsing yields nothing.
    /// - Parameters:
    ///   - data: Raw file data (UTF-8 or ISO Latin-1 encoded).
    ///   - diverName: Applied to every imported item; CSV has no diver column.
    func parse(data: Data, diverName: String, weightUnit: String) -> [GearXMLParser.ParsedGear]? {
        // Decode UTF-8; fall back to ISO Latin-1 for accented shop/brand names (e.g. "Plongée Nautilus").
        guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }

        // Normalise CRLF and CR-only line endings before splitting.
        let text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // Require at least a header row plus one data row.
        guard lines.count > 1 else { return nil }
        lines.removeFirst() // skip the column-header row

        var result: [GearXMLParser.ParsedGear] = []

        for line in lines {
            let fields = parseCSVLine(line)
            guard fields.count == 10 else { continue }

            let manufacturer    = trimmedNil(fields[0])
            let modelName       = fields[1].trimmingCharacters(in: .whitespaces)
            let rawType         = fields[2].trimmingCharacters(in: .whitespaces)
            let serial          = trimmedNil(fields[3])
            let weightStr       = fields[4]
            let purchaseDateStr = fields[5].trimmingCharacters(in: .whitespaces)
            let priceStr        = fields[6]
            let shop            = trimmedNil(fields[7])
            let warranty        = trimmedNil(fields[8])
            let lastServiceStr  = trimmedNil(fields[9])

            // Combined name follows the same convention as MacDive dive-XML imports:
            // "Manufacturer Model" when a manufacturer is present, otherwise just the model.
            let name: String
            if let mfr = manufacturer {
                name = "\(mfr) \(modelName)".trimmingCharacters(in: .whitespaces)
            } else {
                name = modelName
            }
            guard !name.isEmpty else { continue }

            let category = (GearCategory(exportKeyOrRawValue: rawType) ?? .other).rawValue

            // Accept both '.' and ',' as decimal separator (normalised within an already-split field).
            let weight = parseDouble(weightStr)
            let price  = parseDouble(priceStr)

            let datePurchased = dateFormatter.date(from: purchaseDateStr) ?? Date()
            let lastService   = lastServiceStr.flatMap { dateFormatter.date(from: $0) }

            let parsed = GearXMLParser.ParsedGear(
                // Fresh UUID — CSV carries no UUID; dedup falls back to name + category + diverName + serial.
                id: UUID(),
                name: name,
                category: category,
                manufacturer: manufacturer,
                model: modelName.isEmpty ? nil : modelName,
                serialNumber: serial,
                datePurchased: datePurchased,
                purchasePrice: price,
                currency: nil,       // Not exported by MacDive CSV.
                purchasedFrom: shop,
                lastServiceDate: lastService,
                nextServiceDue: nil,
                serviceHistory: nil,
                gearNotes: warranty, // No dedicated warranty field in the model; stored in notes.
                weightContribution: weight ?? 0.0,
                weightContributionUnit: weightUnit,
                isInactive: false,
                diverName: diverName
            )
            result.append(parsed)
        }

        return result.isEmpty ? nil : result
    }

    // MARK: - CSV Line Parsing

    /// RFC 4180-compliant field splitter: handles quoted fields and escaped double-quotes ("").
    private func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var idx = line.startIndex

        while idx < line.endIndex {
            let ch = line[idx]
            if inQuotes {
                if ch == "\"" {
                    let next = line.index(after: idx)
                    if next < line.endIndex && line[next] == "\"" {
                        // Escaped double-quote inside a quoted field.
                        current.append("\"")
                        idx = line.index(after: next)
                        continue
                    }
                    inQuotes = false
                } else {
                    current.append(ch)
                }
            } else {
                switch ch {
                case "\"":
                    inQuotes = true
                case ",":
                    fields.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                default:
                    current.append(ch)
                }
            }
            idx = line.index(after: idx)
        }
        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }

    // MARK: - Helpers

    private func trimmedNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private func parseDouble(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return s.isEmpty ? nil : Double(s)
    }
}
