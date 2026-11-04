import Foundation

// MARK: - Statistics CSV Export

/// One dive of the Statistics CSV export: plain values, already converted to the user's
/// display units on the MainActor, so the file can be built off it. A nil value is a value
/// the dive does not have (written as an empty cell, never estimated).
nonisolated struct StatisticsCSVRow: Sendable {
    let timestamp: Date
    let diveNumber: Int?
    let diver: String
    let site: String
    let location: String
    let country: String
    let maxDepth: Double
    let averageDepth: Double?
    let durationMinutes: Int
    /// The computer's or file's dive time (`Dive.consistentDurationSeconds`); nil when the dive
    /// has none (never derived from the minutes).
    let durationSeconds: Int?
    let waterTemperature: Double?
    let rmv: Double?
    let sac: Double?
    /// The RMV was not calculated from bar and litres (`Dive.isRMVInNativeUnits` false).
    /// Only meaningful when `rmv` is set.
    let rmvIsEstimated: Bool
}

extension StatisticsCSVRow {
    /// A dive's values in the user's display units — the single reading rule of the Statistics
    /// CSV export and the 12-Month Trends chart, so both always show the same numbers.
    /// RMV is in L/min, or cu ft/min when `pressureUnit` is psi (as `formatRMV`); SAC is
    /// converted from bar to `pressureUnit`. A value the dive does not have is nil: average
    /// depth 0, no water temperature, RMV or SAC 0 (not calculable).
    @MainActor
    static func read(from dive: Dive, pressureUnit: PressureUnit) -> StatisticsCSVRow {
        let rmv = dive.calculatedRMV
        let sac = dive.calculatedSAC
        return StatisticsCSVRow(
            timestamp: dive.timestamp,
            diveNumber: dive.diveNumber,
            diver: dive.diverName,
            site: dive.siteName,
            location: dive.location,
            country: dive.siteCountry ?? "",
            maxDepth: dive.displayMaxDepth,
            averageDepth: dive.averageDepth > 0 ? dive.displayAverageDepth : nil,
            durationMinutes: dive.duration,
            durationSeconds: dive.consistentDurationSeconds,
            waterTemperature: dive.displayWaterTemperature,
            rmv: rmv > 0 ? (pressureUnit == .psi ? rmv / 28.3168 : rmv) : nil,
            sac: sac > 0 ? pressureUnit.convertFromBar(sac) : nil,
            rmvIsEstimated: !dive.isRMVInNativeUnits
        )
    }
}

/// Builds the Statistics CSV file (Statistics → Export CSV) from rows read on the MainActor.
/// The format is fixed for spreadsheets, whatever the region: RFC 4180 (comma-separated,
/// quoted fields, CRLF line endings), UTF-8 with a byte-order mark so Excel reads accents,
/// `.` as the decimal separator with no grouping, dates as `yyyy-MM-dd HH:mm` in local time.
nonisolated enum StatisticsCSVExport {
    /// The localized column titles, units included. Read on the MainActor (in-app language
    /// and unit preferences) and passed to `build`.
    struct Labels: Sendable {
        let headers: [String]
        let yes: String
        let no: String
        /// Decimals of the RMV column: 3 in cu ft/min, 2 in L/min (as `formatRMV`).
        let rmvDecimals: Int
    }

    /// `BlueDive-Statistics-yyyy-MM-dd.csv`, dated today.
    static func fileName(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return "BlueDive-Statistics-\(formatter.string(from: date)).csv"
    }

    static func build(rows: [StatisticsCSVRow], labels: Labels) -> Data {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.timeZone = TimeZone.current
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        var text = "\u{FEFF}"
        text += labels.headers.map(field).joined(separator: ",") + "\r\n"
        for row in rows {
            let cells: [String] = [
                dateFormatter.string(from: row.timestamp),
                row.diveNumber.map { String($0) } ?? "",
                field(neutralized(row.diver)),
                field(neutralized(row.site)),
                field(neutralized(row.location)),
                field(neutralized(row.country)),
                number(row.maxDepth, decimals: 1),
                row.averageDepth.map { number($0, decimals: 1) } ?? "",
                String(row.durationMinutes),
                row.durationSeconds.map { String($0) } ?? "",
                row.waterTemperature.map { number($0, decimals: 1) } ?? "",
                row.rmv.map { number($0, decimals: labels.rmvDecimals) } ?? "",
                row.sac.map { number($0, decimals: 2) } ?? "",
                row.rmv == nil ? "" : field(row.rmvIsEstimated ? labels.yes : labels.no)
            ]
            text += cells.joined(separator: ",") + "\r\n"
        }
        return Data(text.utf8)
    }

    /// A fixed-format number (`.` decimal separator, no grouping) for interoperability.
    /// A value that rounds to zero is written `0.0`, not `-0.0` (e.g. −0.04 °C); any value
    /// that is still negative once rounded (−1.9 °C) keeps its sign.
    private static func number(_ value: Double, decimals: Int) -> String {
        let text = String(format: "%.\(decimals)f", value)
        if text.hasPrefix("-"), Double(text) == 0 { return String(text.dropFirst()) }
        return text
    }

    /// Free text the user typed (diver, site, location, country) that a spreadsheet would run as
    /// a formula — starting with `=`, `+`, `-`, `@`, a tab or a carriage return — gets a leading
    /// `'`, the usual CSV-injection guard (Excel shows the cell as text and hides the mark).
    /// Only the exported copy changes; the stored dive is untouched.
    private static func neutralized(_ value: String) -> String {
        guard let first = value.unicodeScalars.first,
              ["=", "+", "-", "@", "\t", "\r"].contains(first) else { return value }
        return "'" + value
    }

    /// A text cell, quoted when it holds a comma, a quote or a line break (RFC 4180).
    private static func field(_ value: String) -> String {
        // Unicode scalars, not Characters: "\r\n" is a single Character equal to neither "\r" nor "\n".
        guard value.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
