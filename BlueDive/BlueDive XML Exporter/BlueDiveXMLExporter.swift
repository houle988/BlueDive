import Foundation

// MARK: - BlueDiveXMLExporter

/// Generates a BlueDive XML document for one or more dives.
/// This is the canonical XML generation logic — XMLExportTabView delegates
/// single-dive preview to this type as well.
enum BlueDiveXMLExporter {

    // MARK: - Public API

    /// Generates a complete BlueDive XML string containing all provided dives
    /// wrapped in a single `<blueDiveExport>` root element.
    @MainActor
    static func generateXML(for dives: [Dive]) -> String {
        var lines: [String] = []

        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append("<blueDiveExport>")

        // ── Metadata ─────────────────────────────────────────────────────────
        let appName     = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "BlueDive"
        let appVersion  = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        lines.append("  <metadata>")
        lines.append(xmlTag("software",   appName,                          indent: 4))
        lines.append(xmlTag("version",    "\(appVersion) (\(buildNumber))", indent: 4))
        lines.append(xmlTag("exportedAt", formatDate(Date()),               indent: 4))
        lines.append(xmlTag("diveCount",  String(dives.count),              indent: 4))
        lines.append("  </metadata>")

        // ── Dives ─────────────────────────────────────────────────────────────
        lines.append("  <dives>")
        for dive in dives {
            lines.append(contentsOf: diveLines(for: dive))
        }
        lines.append("  </dives>")

        lines.append("</blueDiveExport>")
        return lines.joined(separator: "\n")
    }

    // MARK: - Single-dive XML (used by XMLExportTabView for preview)

    /// Generates a standalone BlueDive XML string for a single dive.
    @MainActor
    static func generateXML(for dive: Dive) -> String {
        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append("<blueDiveExport>")

        let appName     = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "BlueDive"
        let appVersion  = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        lines.append("  <metadata>")
        lines.append(xmlTag("software",   appName,                          indent: 4))
        lines.append(xmlTag("version",    "\(appVersion) (\(buildNumber))", indent: 4))
        lines.append(xmlTag("exportedAt", formatDate(Date()),               indent: 4))
        lines.append("  </metadata>")

        lines.append(contentsOf: diveLines(for: dive))
        lines.append("</blueDiveExport>")
        return lines.joined(separator: "\n")
    }

    // MARK: - Private: Single-dive block

    @MainActor
    private static func diveLines(for dive: Dive) -> [String] {
        var lines: [String] = []

        lines.append("  <dive>")

        // Units
        lines.append("    <!-- BlueDiveGlobalData: Units -->")
        lines.append(xmlTag("distanceFormat",    dive.importDistanceUnit,    indent: 4))
        lines.append(xmlTag("temperatureFormat", dive.importTemperatureUnit, indent: 4))
        lines.append(xmlTag("pressureFormat",    dive.importPressureUnit,    indent: 4))
        lines.append(xmlTag("volumeFormat",      dive.importVolumeUnit,      indent: 4))
        lines.append(xmlTag("weightFormat",      dive.importWeightUnit,      indent: 4))

        // Import Source
        lines.append(xmlTag("sourceImport",   dive.sourceImport ?? "",                        indent: 4))

        // Basic Info
        lines.append("    <!-- BlueDiveGlobalData: Basic Info -->")
        lines.append(xmlTag("date",           formatDate(dive.timestamp),                    indent: 4))
        lines.append(xmlTag("identifier",     dive.identifier ?? "",                         indent: 4))
        lines.append(xmlTag("diveNumber",     dive.diveNumber.map(String.init) ?? "",        indent: 4))
        lines.append(xmlTag("rating",         String(dive.rating),                           indent: 4))
        lines.append(xmlTag("repetitiveDive", dive.isRepetitiveDive ? "1" : "0",             indent: 4))
        lines.append(xmlTag("diver",          dive.diverName,                                indent: 4))
        lines.append(xmlTag("computer",       dive.computerName,                             indent: 4))
        lines.append(xmlTag("serial",         dive.computerSerialNumber ?? "",               indent: 4))

        // Dive Stats
        lines.append("    <!-- BlueDiveGlobalData: Dive Stats -->")
        lines.append(xmlTag("maxDepth",        formatDouble(dive.maxDepth),                                                indent: 4))
        lines.append(xmlTag("averageDepth",    dive.averageDepth > 0 ? formatDouble(dive.averageDepth) : "",              indent: 4))
        lines.append(xmlTag("duration",        String(dive.duration * 60),                                                indent: 4))
        lines.append(xmlTag("surfaceInterval", surfaceIntervalMinutes(from: dive.surfaceInterval).map(String.init) ?? "", indent: 4))

        // Decompression
        lines.append("    <!-- BlueDiveGlobalData: Decompression -->")
        lines.append(xmlTag("cns",               dive.cnsPercentage.map(formatDouble) ?? "", indent: 4))
        lines.append(xmlTag("decoModel",         dive.decompressionAlgorithm ?? "",          indent: 4))
        lines.append(xmlTag("decompressionDive", dive.isDecompressionDive ? "1" : "0",       indent: 4))

        // Deco stops
        if !dive.decoStops.isEmpty {
            lines.append("    <decoStops>")
            for stop in dive.decoStops {
                lines.append("      <decoStop depth=\"\(formatDouble(stop.depth))\" time=\"\(Int(stop.time))\" type=\"\(stop.type)\"/>")
            }
            lines.append("    </decoStops>")
        }

        // Temperatures
        lines.append("    <!-- BlueDiveGlobalData: Temperatures (stored as-imported) -->")
        lines.append(xmlTag("tempAir",  dive.airTemperature.map(formatDouble) ?? "", indent: 4))
        lines.append(xmlTag("tempHigh", dive.maxTemperature.map(formatDouble) ?? "", indent: 4))
        lines.append(xmlTag("tempLow",  formatDouble(dive.minTemperature),           indent: 4))

        // Conditions
        lines.append("    <!-- BlueDiveGlobalData: Conditions -->")
        lines.append(xmlTag("visibility",        dive.visibility ?? "",          indent: 4))
        lines.append(xmlTag("weight",            dive.weights.map(formatDouble) ?? "", indent: 4))
        lines.append(xmlTag("weather",           dive.weather ?? "",             indent: 4))
        lines.append(xmlTag("current",           dive.current ?? "",             indent: 4))
        lines.append(xmlTag("surfaceConditions", dive.surfaceConditions ?? "",   indent: 4))
        lines.append(xmlTag("entryType",         dive.entryType ?? "",           indent: 4))

        // Operator
        lines.append("    <!-- BlueDiveGlobalData: Operator -->")
        lines.append(xmlTag("diveMaster",   dive.diveMaster   ?? "", indent: 4))
        lines.append(xmlTag("diveOperator", dive.diveOperator ?? "", indent: 4))
        lines.append(xmlTag("skipper",      dive.skipper      ?? "", indent: 4))
        lines.append(xmlTag("boat",         dive.boat         ?? "", indent: 4))

        // Notes & Tags
        lines.append("    <!-- BlueDiveGlobalData: Notes & Tags -->")
        lines.append(xmlTag("notes", dive.notes,       indent: 4))
        lines.append(xmlTag("tags",  dive.tags ?? "",  indent: 4))

        // Types
        let allTypes = dive.diveTypes?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        lines.append("    <types>")
        for t in allTypes { lines.append(xmlTag("type", t, indent: 6)) }
        lines.append("    </types>")

        // Buddies
        let buddyList = dive.buddies
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        lines.append("    <buddies>")
        for b in buddyList { lines.append(xmlTag("buddy", b, indent: 6)) }
        lines.append("    </buddies>")

        // ── BlueDiveSiteData ─────────────────────────────────────────────────
        lines.append("    <!-- BlueDiveSiteData -->")
        lines.append("    <site>")
        lines.append(xmlTag("name",        dive.siteName.isEmpty ? dive.location : dive.siteName, indent: 6))
        lines.append(xmlTag("location",    dive.location,                             indent: 6))
        lines.append(xmlTag("country",     dive.siteCountry ?? "",                    indent: 6))
        lines.append(xmlTag("bodyOfWater", dive.siteBodyOfWater ?? "",                indent: 6))
        lines.append(xmlTag("waterType",   dive.siteWaterType ?? "",                  indent: 6))
        lines.append(xmlTag("difficulty",  dive.siteDifficulty ?? "",                 indent: 6))
        lines.append(xmlTag("altitude",    dive.siteAltitude.map(formatDouble) ?? "", indent: 6))
        lines.append(xmlTag("lat",         dive.siteLatitude.map(formatCoord) ?? "",  indent: 6))
        lines.append(xmlTag("lon",         dive.siteLongitude.map(formatCoord) ?? "", indent: 6))
        lines.append("    </site>")

        // ── BlueDiveTankData ─────────────────────────────────────────────────
        lines.append("    <!-- BlueDiveTankData -->")
        if !dive.tanks.isEmpty {
            lines.append("    <tanks>")
            for tank in dive.tanks {
                let oxygenPercent = tank.o2Percentage
                let heliumPercent = tank.hePercentage
                let tankMaterialVal = tank.tankMaterial ?? ""
                let tankTypeValue   = tank.tankType ?? ""

                lines.append("      <tank>")
                lines.append(xmlTag("id",              tank.id.uuidString,                     indent: 8))
                lines.append(xmlTag("oxygen",          String(oxygenPercent),                  indent: 8))
                lines.append(xmlTag("helium",          String(heliumPercent),                  indent: 8))
                lines.append(xmlTag("volume",          tank.volume.map(formatDouble) ?? "",    indent: 8))
                lines.append(xmlTag("startPressure",   tank.startPressure.map(formatDouble) ?? "", indent: 8))
                lines.append(xmlTag("endPressure",     tank.endPressure.map(formatDouble) ?? "",   indent: 8))
                lines.append(xmlTag("workingPressure", tank.workingPressure.map(formatDouble) ?? "", indent: 8))
                lines.append(xmlTag("tankMaterial",    tankMaterialVal,                        indent: 8))
                lines.append(xmlTag("tankType",        tankTypeValue,                          indent: 8))
                lines.append(xmlTag("usageStartTime",  tank.usageStartTime.map(formatDouble) ?? "", indent: 8))
                lines.append(xmlTag("usageEndTime",    tank.usageEndTime.map(formatDouble) ?? "",   indent: 8))
                lines.append("      </tank>")
            }
            lines.append("    </tanks>")
        }

        // ── Marine Life Seen ─────────────────────────────────────────────────
        lines.append("    <!-- Marine Life Seen -->")
        if !(dive.seenFish ?? []).isEmpty {
            lines.append("    <marineLifeSeen>")
            for marineLife in dive.seenFish ?? [] {
                lines.append("      <marineLife>")
                lines.append(xmlTag("name",  marineLife.name,         indent: 8))
                lines.append(xmlTag("count", String(marineLife.count), indent: 8))
                lines.append("      </marineLife>")
            }
            lines.append("    </marineLifeSeen>")
        }

        // ── BlueDiveGearData ─────────────────────────────────────────────────
        lines.append("    <!-- BlueDiveGearData -->")
        if !(dive.usedGear ?? []).isEmpty {
            lines.append("    <gear>")
            for item in dive.usedGear ?? [] {
                lines.append("      <item>")
                lines.append(xmlTag("type",         item.gearCategory?.exportKey ?? item.category, indent: 8))
                lines.append(xmlTag("manufacturer", item.manufacturer ?? "", indent: 8))
                lines.append(xmlTag("model",        item.model ?? "",    indent: 8))
                lines.append(xmlTag("name",         item.name,           indent: 8))
                lines.append(xmlTag("serial",       item.serialNumber ?? "", indent: 8))
                lines.append(xmlTag("datePurchased",      formatDate(item.datePurchased),                              indent: 8))
                lines.append(xmlTag("purchasePrice",      item.purchasePrice.map { formatDouble($0) } ?? "",           indent: 8))
                lines.append(xmlTag("currency",           item.currency ?? "",                                         indent: 8))
                lines.append(xmlTag("purchasedFrom",      item.purchasedFrom ?? "",                                    indent: 8))
                lines.append(xmlTag("weightContribution",     formatDouble(item.weightContribution),                       indent: 8))
                lines.append(xmlTag("weightContributionUnit", item.weightContributionUnit ?? "",                             indent: 8))
                lines.append(xmlTag("nextServiceDue",         item.nextServiceDue.map { formatDate($0) } ?? "",            indent: 8))
                lines.append(xmlTag("serviceHistory",     item.serviceHistory ?? "",                                   indent: 8))
                lines.append(xmlTag("gearNotes",          item.gearNotes ?? "",                                        indent: 8))
                lines.append(xmlTag("isInactive",         item.isInactive ? "true" : "false",                          indent: 8))
                lines.append("      </item>")
            }
            lines.append("    </gear>")
        }

        // ── BlueDiveSamplesData ──────────────────────────────────────────────
        lines.append("    <!-- BlueDiveSamplesData -->")
        let samples = dive.profileSamples
        if !samples.isEmpty {
            lines.append("    <profileSamples count=\"\(samples.count)\">")
            for sample in samples {
                var attrs: [(String, String)] = [
                    ("time",  formatDouble(sample.time * 60)),
                    ("depth", formatDouble(sample.depth))
                ]
                if let temp     = sample.temperature  { attrs.append(("temperature", formatDouble(temp))) }
                if let pressure = sample.tankPressure  { attrs.append(("tankPressure", formatDouble(pressure))) }
                if let tp = sample.tankPressures, !tp.isEmpty {
                    let serialized = tp.sorted(by: { $0.key < $1.key })
                        .map { "\($0.key):\(formatDouble($0.value))" }
                        .joined(separator: ",")
                    attrs.append(("tankPressures", serialized))
                }
                if let ppo2     = sample.ppo2           { attrs.append(("ppo2", formatDouble(ppo2))) }
                if let ndl      = sample.ndl            { attrs.append(("ndl", formatDouble(ndl))) }
                let eventsStr = sample.events.map { serializeEvent($0) }.joined(separator: ",")
                attrs.append(("events", eventsStr))
                let attrString = attrs.map { "\($0.0)=\"\($0.1)\"" }.joined(separator: " ")
                lines.append("      <sample \(attrString)/>")
            }
            lines.append("    </profileSamples>")
        }

        lines.append("  </dive>")
        return lines
    }

    // MARK: - Event Serialization

    private static func serializeEvent(_ event: DiveProfileEvent) -> String {
        switch event {
        case .ascent:                    return "ascent"
        case .violation:                 return "violation"
        case .decoStop:                  return "decoStop"
        case .gasChange:                 return "gasChange"
        case .bookmark:                  return "bookmark"
        case .safetyStop(let mandatory): return mandatory ? "safetyStop:1" : "safetyStop:0"
        case .ceiling:                   return "ceiling"
        case .po2:                       return "po2"
        case .deepStop:                  return "deepStop"
        }
    }

    // MARK: - XML Helpers

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
    }

    static func formatDouble(_ value: Double) -> String {
        let formatted = String(format: "%.4f", value)
        return formatted.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    private static func formatCoord(_ value: Double) -> String {
        String(format: "%.7f", value)
    }

    static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    /// Converts a display-formatted surface interval string (e.g. "1h 36m", "5d 21h 29m")
    /// back to a total number of minutes for XML export. Returns nil for empty / zero values.
    private static func surfaceIntervalMinutes(from string: String) -> Int? {
        guard !string.isEmpty, string != "0h 00m" else { return nil }
        let patternWithDays = #/(\d+)d\s*(\d+)h\s*(\d+)m/#
        if let match = string.firstMatch(of: patternWithDays) {
            let days    = Int(match.output.1) ?? 0
            let hours   = Int(match.output.2) ?? 0
            let minutes = Int(match.output.3) ?? 0
            let total = (days * 1440) + (hours * 60) + minutes
            return total > 0 ? total : nil
        }
        let pattern = #/(\d+)h\s*(\d+)m/#
        guard let match = string.firstMatch(of: pattern) else { return nil }
        let hours   = Int(match.output.1) ?? 0
        let minutes = Int(match.output.2) ?? 0
        let total = hours * 60 + minutes
        return total > 0 ? total : nil
    }
}
