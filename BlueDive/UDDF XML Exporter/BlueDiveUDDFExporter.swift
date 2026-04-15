import Foundation

// MARK: - BlueDiveUDDFExporter
//
// Generates a UDDF v3.2.3 compliant XML document from one or more Dive objects.
//
// UDDF uses SI units exclusively:
//   - Depth:       metres (m)          — stored as-is (app uses metres internally)
//   - Temperature: Kelvin (K)          — convert from °C: K = °C + 273.15
//   - Pressure:    Pascal (Pa)         — convert from bar: Pa = bar × 100,000
//   - Volume:      cubic metres (m³)   — convert from litres: m³ = L / 1000
//   - Weight:      kilograms (kg)      — stored as-is
//   - Time:        seconds (s)         — convert from minutes where needed
//   - GPS:         decimal degrees     — stored as-is

enum BlueDiveUDDFExporter {

    // MARK: - Public API

    /// Generates a complete UDDF XML string for a single dive.
    @MainActor
    static func generateUDDF(for dive: Dive) -> String {
        generateUDDF(for: [dive])
    }

    /// Generates a complete UDDF XML string containing all provided dives.
    @MainActor
    static func generateUDDF(for dives: [Dive]) -> String {
        var lines: [String] = []

        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append(#"<uddf version="3.2.3" xmlns="http://www.streit.cc/uddf/3.2/">"#)

        // ── Generator ───────────────────────────────────────────────────────
        lines.append(contentsOf: generatorSection())

        // ── Gas definitions ─────────────────────────────────────────────────
        let allMixes = collectGasMixes(from: dives)
        lines.append(contentsOf: gasDefinitionsSection(mixes: allMixes))

        // ── Diver ───────────────────────────────────────────────────────────
        let allBuddies = collectBuddies(from: dives)
        let ownerName = dives.first?.diverName ?? ""
        let computerName = dives.first?.computerName
        let computerSerial = dives.first?.computerSerialNumber
        let allGear = collectGear(from: dives)
        lines.append(contentsOf: diverSection(
            ownerName: ownerName,
            computerName: computerName,
            computerSerial: computerSerial,
            gear: allGear,
            buddies: allBuddies
        ))

        // ── Dive sites ──────────────────────────────────────────────────────
        let siteMap = collectSites(from: dives)
        lines.append(contentsOf: diveSiteSection(sites: siteMap))

        // ── Decompression model ─────────────────────────────────────────────
        let decoAlgorithm = dives.compactMap(\.decompressionAlgorithm).first(where: { !$0.isEmpty })
        if let algo = decoAlgorithm {
            lines.append(contentsOf: decoModelSection(algorithm: algo))
        }

        // ── Profile data ────────────────────────────────────────────────────
        lines.append(contentsOf: profileDataSection(dives: dives, mixes: allMixes, siteMap: siteMap, buddies: allBuddies))

        lines.append("</uddf>")
        return lines.joined(separator: "\n")
    }

    // MARK: - Generator

    private static func generatorSection() -> [String] {
        let appName    = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "BlueDive"
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"

        return [
            "  <generator>",
            "    <name>\(xmlEscape(appName))</name>",
            "    <version>\(xmlEscape(appVersion))</version>",
            "    <datetime>\(formatISO8601(Date()))</datetime>",
            "  </generator>"
        ]
    }

    // MARK: - Gas Definitions

    /// Returns a dictionary of composition-based key → (o2 fraction, he fraction, name)
    @MainActor
    private static func collectGasMixes(from dives: [Dive]) -> [String: (o2: Double, he: Double, name: String)] {
        var mixes: [String: (o2: Double, he: Double, name: String)] = [:]
        for dive in dives {
            for tank in dive.tanks {
                let key = "mix_o2\(tank.o2Percentage)_he\(tank.hePercentage)"
                if mixes[key] == nil {
                    mixes[key] = (o2: tank.o2, he: tank.he, name: tank.gasName)
                }
            }
        }
        if mixes.isEmpty {
            mixes["mix_air"] = (o2: 0.21, he: 0.0, name: "Air")
        }
        return mixes
    }

    private static func gasDefinitionsSection(mixes: [String: (o2: Double, he: Double, name: String)]) -> [String] {
        var lines: [String] = []
        lines.append("  <gasdefinitions>")
        for (id, mix) in mixes.sorted(by: { $0.key < $1.key }) {
            lines.append("    <mix id=\"\(xmlEscape(id))\">")
            lines.append("      <name>\(xmlEscape(mix.name))</name>")
            lines.append("      <o2>\(formatFraction(mix.o2))</o2>")
            lines.append("      <he>\(formatFraction(mix.he))</he>")
            lines.append("    </mix>")
        }
        lines.append("  </gasdefinitions>")
        return lines
    }

    // MARK: - Diver

    @MainActor
    private static func collectBuddies(from dives: [Dive]) -> [String: String] {
        // buddy id → buddy name
        var buddies: [String: String] = [:]
        for dive in dives {
            let buddyList = dive.buddies
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for name in buddyList {
                let id = "buddy_\(name.lowercased().replacingOccurrences(of: " ", with: "_"))"
                buddies[id] = name
            }
        }
        return buddies
    }

    @MainActor
    private static func collectGear(from dives: [Dive]) -> [(id: String, name: String, manufacturer: String?, serial: String?)] {
        var seen = Set<String>()
        var gear: [(id: String, name: String, manufacturer: String?, serial: String?)] = []
        for dive in dives {
            for item in dive.usedGear ?? [] {
                let key = item.name + (item.serialNumber ?? "")
                if !seen.contains(key) {
                    seen.insert(key)
                    let id = "gear_\(item.id.uuidString.prefix(8))"
                    gear.append((id: id, name: item.name, manufacturer: item.manufacturer, serial: item.serialNumber))
                }
            }
        }
        return gear
    }

    private static func diverSection(
        ownerName: String,
        computerName: String?,
        computerSerial: String?,
        gear: [(id: String, name: String, manufacturer: String?, serial: String?)],
        buddies: [String: String]
    ) -> [String] {
        var lines: [String] = []
        lines.append("  <diver>")

        // Owner
        lines.append("    <owner id=\"owner\">")
        lines.append("      <personal>")
        let parts = ownerName.split(separator: " ", maxSplits: 1)
        let first = parts.first.map(String.init) ?? ownerName
        let last = parts.count > 1 ? String(parts[1]) : ""
        lines.append("        <firstname>\(xmlEscape(first))</firstname>")
        if !last.isEmpty {
            lines.append("        <lastname>\(xmlEscape(last))</lastname>")
        }
        lines.append("      </personal>")

        // Equipment
        if computerName != nil || !gear.isEmpty {
            lines.append("      <equipment>")
            if let name = computerName {
                lines.append("        <divecomputer id=\"dc1\">")
                lines.append("          <name>\(xmlEscape(name))</name>")
                if let serial = computerSerial, !serial.isEmpty {
                    lines.append("          <serialnumber>\(xmlEscape(serial))</serialnumber>")
                }
                lines.append("        </divecomputer>")
            }
            for item in gear {
                lines.append("        <variouspieces id=\"\(xmlEscape(item.id))\">")
                lines.append("          <name>\(xmlEscape(item.name))</name>")
                if let serial = item.serial, !serial.isEmpty {
                    lines.append("          <serialnumber>\(xmlEscape(serial))</serialnumber>")
                }
                lines.append("        </variouspieces>")
            }
            lines.append("      </equipment>")
        }

        lines.append("    </owner>")

        // Buddies
        for (id, name) in buddies.sorted(by: { $0.key < $1.key }) {
            lines.append("    <buddy id=\"\(xmlEscape(id))\">")
            lines.append("      <personal>")
            lines.append("        <firstname>\(xmlEscape(name))</firstname>")
            lines.append("      </personal>")
            lines.append("    </buddy>")
        }

        lines.append("  </diver>")
        return lines
    }

    // MARK: - Dive Sites

    @MainActor
    private static func collectSites(from dives: [Dive]) -> [String: Dive] {
        // site id → dive (for site data extraction)
        var siteMap: [String: Dive] = [:]
        for dive in dives {
            let siteName = dive.siteName.isEmpty ? dive.location : dive.siteName
            let siteId = "site_\(siteName.lowercased().replacingOccurrences(of: " ", with: "_").prefix(40))_\(dive.id.uuidString.prefix(8))"
            siteMap[siteId] = dive
        }
        return siteMap
    }

    @MainActor
    private static func diveSiteSection(sites: [String: Dive]) -> [String] {
        var lines: [String] = []
        lines.append("  <divesite>")
        for (id, dive) in sites.sorted(by: { $0.key < $1.key }) {
            let siteName = dive.siteName.isEmpty ? dive.location : dive.siteName
            lines.append("    <site id=\"\(xmlEscape(id))\">")
            lines.append("      <name>\(xmlEscape(siteName))</name>")

            // Geography
            let hasGeo = dive.siteLatitude != nil || dive.siteLongitude != nil
                      || dive.siteAltitude != nil || !dive.location.isEmpty
                      || dive.siteCountry != nil
            if hasGeo {
                lines.append("      <geography>")
                if !dive.location.isEmpty {
                    lines.append("        <location>\(xmlEscape(dive.location))</location>")
                }
                if let country = dive.siteCountry, !country.isEmpty {
                    lines.append("        <address>")
                    lines.append("          <country>\(xmlEscape(country))</country>")
                    lines.append("        </address>")
                }
                if let lat = dive.siteLatitude {
                    lines.append("        <latitude>\(formatCoord(lat))</latitude>")
                }
                if let lon = dive.siteLongitude {
                    lines.append("        <longitude>\(formatCoord(lon))</longitude>")
                }
                if let alt = dive.siteAltitude {
                    lines.append("        <altitude>\(formatDouble(alt))</altitude>")
                }
                lines.append("      </geography>")
            }

            // Environment
            if let body = dive.siteBodyOfWater, !body.isEmpty {
                lines.append("      <environment>\(xmlEscape(body))</environment>")
            }

            // Sitedata / difficulty
            if let difficulty = dive.siteDifficulty, !difficulty.isEmpty {
                lines.append("      <sitedata>")
                lines.append("        <difficulty>\(xmlEscape(difficulty))</difficulty>")
                lines.append("      </sitedata>")
            }

            lines.append("    </site>")
        }
        lines.append("  </divesite>")
        return lines
    }

    // MARK: - Decompression Model

    private static func decoModelSection(algorithm: String) -> [String] {
        var lines: [String] = []
        lines.append("  <decomodel>")
        let lower = algorithm.lowercased()
        if lower.contains("buehlmann") || lower.contains("bühlmann") || lower.contains("zhl") || lower.contains("zh-l") {
            // Extract the Bühlmann model identifier (e.g., "ZHL-16C" from "ZHL-16C GF 40/85")
            let modelId = parseBuehlmannModelId(from: algorithm)
            let idAttr = modelId.map { " id=\"\(xmlEscape($0.lowercased()))\"" } ?? ""

            // Extract gradient factors from the algorithm string (e.g., "ZHL-16C GF 40/85")
            let gf = parseGradientFactors(from: algorithm)
            if let gfLow = gf?.low, let gfHigh = gf?.high {
                lines.append("    <buehlmann\(idAttr)>")
                lines.append("      <gradientfactorlow>\(formatFraction(gfLow))</gradientfactorlow>")
                lines.append("      <gradientfactorhigh>\(formatFraction(gfHigh))</gradientfactorhigh>")
                lines.append("    </buehlmann>")
            } else {
                lines.append("    <buehlmann\(idAttr)/>")
            }
        } else if lower.contains("vpm") {
            lines.append("    <vpm/>")
        } else if lower.contains("rgbm") {
            lines.append("    <rgbm/>")
        } else {
            // Default to buehlmann as the most common algorithm
            lines.append("    <buehlmann/>")
        }
        lines.append("  </decomodel>")
        return lines
    }

    /// Extracts GF Low/High from an algorithm string like "ZHL-16C GF 40/85" or "Buehlmann GF 30/70".
    /// Returns fractions (0.0–1.0) suitable for UDDF export.
    private static func parseGradientFactors(from algorithm: String) -> (low: Double, high: Double)? {
        // Match patterns like "GF 40/85", "GF40/85", "gf 30/70"
        let pattern = #/[Gg][Ff]\s*(\d+)\s*/\s*(\d+)/#
        guard let match = algorithm.firstMatch(of: pattern) else { return nil }
        guard let low = Int(match.output.1), let high = Int(match.output.2) else { return nil }
        guard low > 0, low <= 100, high > 0, high <= 100 else { return nil }
        return (low: Double(low) / 100.0, high: Double(high) / 100.0)
    }

    /// Extracts the Bühlmann model identifier from an algorithm string.
    /// E.g., "ZHL-16C GF 40/85" → "ZHL-16C", "Bühlmann ZH-L16C" → "ZH-L16C".
    private static func parseBuehlmannModelId(from algorithm: String) -> String? {
        // Match ZHL/ZH-L followed by model number and optional variant letter
        let pattern = #/(?i)(ZH-?L-?\d+\w*)/#
        guard let match = algorithm.firstMatch(of: pattern) else { return nil }
        return String(match.output.1)
    }

    // MARK: - Profile Data

    @MainActor
    private static func profileDataSection(
        dives: [Dive],
        mixes: [String: (o2: Double, he: Double, name: String)],
        siteMap: [String: Dive],
        buddies: [String: String]
    ) -> [String] {
        var lines: [String] = []
        lines.append("  <profiledata>")
        lines.append("    <repetitiongroup id=\"rg1\">")

        for dive in dives {
            let diveId = dive.identifier ?? dive.id.uuidString
            lines.append("      <dive id=\"\(xmlEscape(diveId))\">")

            // ── informationbeforedive ────────────────────────────────────────
            lines.append("        <informationbeforedive>")
            lines.append("          <datetime>\(formatISO8601(dive.timestamp))</datetime>")
            if let num = dive.diveNumber {
                lines.append("          <divenumber>\(num)</divenumber>")
            }
            if dive.isRepetitiveDive {
                lines.append("          <divenumberofday>2</divenumberofday>")
            }
            if let airTemp = dive.airTemperature {
                lines.append("          <airtemperature>\(formatDouble(celsiusToKelvin(airTemp)))</airtemperature>")
            }
            if let entry = dive.entryType, !entry.isEmpty {
                lines.append("          <platform>\(xmlEscape(entry))</platform>")
            }
            // Purpose from dive types
            if let types = dive.diveTypes, let firstType = types.split(separator: ",").first.map({ $0.trimmingCharacters(in: .whitespaces) }), !firstType.isEmpty {
                lines.append("          <purpose>\(xmlEscape(mapTypeToPurpose(firstType)))</purpose>")
            }
            // Surface interval
            let siMinutes = parseSurfaceIntervalMinutes(from: dive.surfaceInterval)
            if let si = siMinutes, si > 0 {
                lines.append("          <surfaceintervalbeforedive>")
                lines.append("            <passedtime>\(si * 60)</passedtime>")
                lines.append("          </surfaceintervalbeforedive>")
            }
            // Site link
            if let siteId = siteMap.first(where: { $0.value.id == dive.id })?.key {
                lines.append("          <link ref=\"\(xmlEscape(siteId))\"/>")
            }
            // Buddy links
            let buddyList = dive.buddies
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for name in buddyList {
                let buddyId = "buddy_\(name.lowercased().replacingOccurrences(of: " ", with: "_"))"
                if buddies.keys.contains(buddyId) {
                    lines.append("          <link ref=\"\(xmlEscape(buddyId))\"/>")
                }
            }
            lines.append("        </informationbeforedive>")

            // ── tankdata ────────────────────────────────────────────────────
            // Exported before <samples> so parsers can build a ref→index map
            // before encountering <tankpressure ref="..."> in waypoints.
            if !dive.tanks.isEmpty {
                for (index, tank) in dive.tanks.enumerated() {
                    lines.append("        <tankdata id=\"tank\(index + 1)\">")
                    // Link to gas mix by composition key
                    let mixKey = "mix_o2\(tank.o2Percentage)_he\(tank.hePercentage)"
                    if mixes.keys.contains(mixKey) {
                        lines.append("          <link ref=\"\(xmlEscape(mixKey))\"/>")
                    }
                    if let vol = tank.volume {
                        lines.append("          <tankvolume>\(formatDouble(litresToCubicMetres(vol)))</tankvolume>")
                    }
                    if let sp = tank.startPressure {
                        lines.append("          <tankpressurebegin>\(formatDouble(barToPascal(sp)))</tankpressurebegin>")
                    }
                    if let ep = tank.endPressure {
                        lines.append("          <tankpressureend>\(formatDouble(barToPascal(ep)))</tankpressureend>")
                    }
                    lines.append("        </tankdata>")
                }
            }

            // ── samples ─────────────────────────────────────────────────────
            let samples = dive.profileSamples
            // CNS: dive-level percentage (0–100) exported as fraction (0–1) on last waypoint
            let diveCNS = dive.cnsPercentage
            if !samples.isEmpty {
                lines.append("        <samples>")
                let lastIndex = samples.count - 1
                for (index, sample) in samples.enumerated() {
                    lines.append("          <waypoint>")
                    // Time: profile stores minutes, UDDF needs seconds
                    lines.append("            <divetime>\(formatDouble(sample.time * 60))</divetime>")
                    lines.append("            <depth>\(formatDouble(sample.depth))</depth>")
                    if let temp = sample.temperature {
                        lines.append("            <temperature>\(formatDouble(celsiusToKelvin(temp)))</temperature>")
                    }
                    if let tp = sample.tankPressures, !tp.isEmpty {
                        // Multi-tank: one <tankpressure> per tank, linked by ref
                        for (tankIdx, pressure) in tp.sorted(by: { $0.key < $1.key }) {
                            lines.append("            <tankpressure ref=\"tank\(tankIdx + 1)\">\(formatDouble(barToPascal(pressure)))</tankpressure>")
                        }
                    } else if let pressure = sample.tankPressure {
                        lines.append("            <tankpressure>\(formatDouble(barToPascal(pressure)))</tankpressure>")
                    }
                    if let ppo2 = sample.ppo2 {
                        lines.append("            <calculatedpo2>\(formatDouble(ppo2))</calculatedpo2>")
                    }
                    if let ndl = sample.ndl {
                        // NDL: profile stores minutes, UDDF needs seconds
                        lines.append("            <nodecotime>\(formatDouble(ndl * 60))</nodecotime>")
                    }
                    // Export dive-level CNS on the last waypoint (accumulated value)
                    if index == lastIndex, let cns = diveCNS, cns > 0 {
                        lines.append("            <cns>\(formatDouble(cns))</cns>")
                    }
                    lines.append("          </waypoint>")
                }
                lines.append("        </samples>")
            }

            // ── informationafterdive ─────────────────────────────────────────
            lines.append("        <informationafterdive>")
            lines.append("          <greatestdepth>\(formatDouble(dive.maxDepth))</greatestdepth>")
            if dive.averageDepth > 0 {
                lines.append("          <averagedepth>\(formatDouble(dive.averageDepth))</averagedepth>")
            }
            // Duration: stored in minutes, UDDF needs seconds
            lines.append("          <diveduration>\(dive.duration * 60)</diveduration>")

            if let lowTemp = dive.minTemperature as Double?, lowTemp != 0 {
                lines.append("          <lowesttemperature>\(formatDouble(celsiusToKelvin(lowTemp)))</lowesttemperature>")
            }

            if let vis = dive.visibility, let visVal = Double(vis) {
                lines.append("          <visibility>\(formatDouble(visVal))</visibility>")
            }

            if dive.rating > 0 {
                lines.append("          <rating><ratingvalue>\(dive.rating)</ratingvalue></rating>")
            }

            if let w = dive.weights, w > 0 {
                lines.append("          <equipmentused>")
                lines.append("            <leadquantity>\(formatDouble(w))</leadquantity>")
                lines.append("          </equipmentused>")
            }

            // Notes
            if !dive.notes.isEmpty {
                lines.append("          <notes>")
                // Split on newlines to create separate <para> elements
                for paragraph in dive.notes.components(separatedBy: "\n").filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    lines.append("            <para>\(xmlEscape(paragraph))</para>")
                }
                lines.append("          </notes>")
            }

            lines.append("        </informationafterdive>")
            lines.append("      </dive>")
        }

        lines.append("    </repetitiongroup>")
        lines.append("  </profiledata>")
        return lines
    }

    // MARK: - Unit Conversion (to SI)

    private static func celsiusToKelvin(_ c: Double) -> Double {
        c + 273.15
    }

    private static func barToPascal(_ bar: Double) -> Double {
        bar * 100_000.0
    }

    private static func litresToCubicMetres(_ l: Double) -> Double {
        l / 1000.0
    }

    // MARK: - Purpose Mapping (reverse of parser)

    private static func mapTypeToPurpose(_ type: String) -> String {
        switch type.lowercased() {
        case "recreational", "reef":    return "sightseeing"
        case "training":                return "learning"
        case "research":                return "research"
        case "photography":             return "photography-videography"
        case "spearfishing":            return "spearfishing"
        case "proficiency":             return "proficiency"
        case "work":                    return "work"
        default:                        return "other"
        }
    }

    // MARK: - XML Helpers

    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&",  with: "&amp;")
            .replacingOccurrences(of: "<",  with: "&lt;")
            .replacingOccurrences(of: ">",  with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'",  with: "&apos;")
    }

    private static func formatDouble(_ value: Double) -> String {
        let formatted = String(format: "%.4f", value)
        return formatted.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    private static func formatFraction(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private static func formatCoord(_ value: Double) -> String {
        String(format: "%.7f", value)
    }

    private static func formatISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Parses a surface interval display string like "1h 36m" or "2d 1h 30m" into total minutes.
    private static func parseSurfaceIntervalMinutes(from string: String) -> Int? {
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
