import Foundation

// MARK: - Subsurface XML Parser

/// Parses Subsurface native XML exports (.ssrf / .xml).
///
/// Supported version: divelog version='3' (introduced in Subsurface 4.6).
/// Version 2 files are rejected with a nil return from parse(data:).
///
/// All values are stored in their native metric units (Subsurface always exports metric):
///   depth → meters, temperature → °C, pressure → bar, volume → liters, weight → kg.
/// These unit strings are hardcoded in every BlueDiveGlobalData produced by this parser.
final class SubsurfaceXMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {

    // MARK: - Public Result

    private(set) var dives: [BlueDiveGlobalData] = []
    var importGear: Bool = true
    private(set) var rejectedUnsupportedVersion = false

    // Dive computers from <settings><divecomputerid> — file-global, populated before any dive
    private var parsedDiveComputers: [BlueDiveGearData] = []
    // Secondary index keyed by deviceid for O(1) lookup (the canonical join key Subsurface uses)
    private var parsedComputersByDeviceID: [String: BlueDiveGearData] = [:]

    func parse(data: Data) -> [BlueDiveGlobalData]? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { return nil }
        return dives
    }

    // MARK: - Global Dive Sites (resolved by divesiteid on each dive)

    private var diveSites: [String: BlueDiveSiteData] = [:]

    // MARK: - Context Flags

    private var isInSettings    = false
    private var isInDiveSites  = false
    private var isInTrip       = false
    private var isInDive       = false
    private var isInDiveComputer = false
    private var isFirstDiveComputerForDive = false

    // Notes context: only one of these is true at any time
    private var isInNotesDive  = false
    private var isInNotesTrip  = false
    private var isInNotesSite  = false

    private var isInDivemaster = false
    private var isInBuddy      = false
    private var isInSuit       = false

    // MARK: - Text Accumulator

    private var currentText = ""

    // MARK: - Temp Site State (cleared on each <site>)

    private var tempSiteUUID        = ""
    private var tempSiteName        = ""
    private var tempSiteGPS: String? = nil
    private var tempSiteCountry: String?    = nil
    private var tempSiteBodyOfWater: String? = nil

    // MARK: - Temp Trip State

    private var tempTripLocation: String? = nil

    // MARK: - Temp Dive State (cleared on each <dive>)

    private var tempDiveNumber:   Int?    = nil
    private var tempDate:         Date?   = nil
    private var tempDuration:     Int     = 0     // seconds
    private var tempRating:       Int?    = nil
    private var tempVisibility:   String? = nil
    private var tempTags:         String? = nil
    private var tempDiveSiteID:   String? = nil
    private var tempCNS:          Double? = nil
    // Max per-sample CNS %, used as the dive CNS when the dive-level cns attribute is
    // absent (Subsurface's dive-level cns is the maximum reached during the dive).
    private var tempMaxSampleCNS: Double? = nil
    private var tempNotes:        String? = nil
    private var tempDivemaster:   String? = nil
    // One entry per <buddy> element; each entry may itself be a comma-separated list.
    private var tempBuddyNames:   [String] = []
    // Exposure suit text from <suit>; imported as a Gear item when gear import is on.
    private var tempSuit:         String? = nil

    // Temperatures — user-entered (<divetemperature>) take precedence over DC values
    private var tempAirTemp:    Double? = nil
    private var tempWaterTemp:  Double? = nil
    private var tempDCAirTemp:  Double? = nil
    private var tempDCWaterTemp: Double? = nil

    // Dive stats from first <divecomputer><depth>
    private var tempMaxDepth:  Double? = nil
    private var tempMeanDepth: Double? = nil

    // Computer identity from first <divecomputer>
    private var tempComputerName: String? = nil
    private var tempDiveID:       String? = nil  // stable libdivecomputer hash → identifier
    private var tempDeviceID:     String? = nil  // from <divecomputer deviceid='...'>
    private var tempSerial:       String? = nil
    private var tempDCType:       String? = nil  // nil = OC (default, not written to file)
    private var tempDecoModel:    String? = nil  // from <extradata key='Deco model'>, e.g. "GF 50/70"

    // Tanks (one per <cylinder>)
    private var tempTanks: [BlueDiveTankData] = []

    // Accumulated weight from all <weightsystem> elements
    private var tempWeightKg: Double = 0.0

    // Profile samples (from first divecomputer only)
    private var tempSamples: [BlueDiveSamplesData] = []

    // Raw profile events (name + time + optional cylinder) for the first divecomputer.
    // Resolved against the full sample array in resolveSampleEventsAndGas() once the
    // block is fully parsed, so association is independent of the document order in
    // which Subsurface writes <event> vs <sample> elements at the same timestamp.
    private var tempRawEvents: [(time: Int, name: String, cylinder: Int?)] = []

    // MARK: - Date Formatter

    private lazy var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    // MARK: - XMLParserDelegate: Start Element

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentText = ""

        switch elementName {

        case "divelog":
            let version = attributeDict["version"].flatMap { Int($0) } ?? 3
            if version < 3 {
                // Version 2 (pre-4.6) places samples directly under <dive> and uses
                // <location> instead of <divesiteid>. Reject with a clear failure rather
                // than silently importing dives with empty profiles and no site data.
                rejectedUnsupportedVersion = true
                parser.abortParsing()
            }

        // MARK: Settings (dive computer registry)

        case "settings":
            isInSettings = true

        case "divecomputerid" where isInSettings:
            let model    = attributeDict["model"].flatMap    { $0.trimmingCharacters(in: .whitespaces).nilIfEmpty }
            let nickname = attributeDict["nickname"].flatMap { $0.trimmingCharacters(in: .whitespaces).nilIfEmpty }
            let serial   = attributeDict["serial"].flatMap   { $0.trimmingCharacters(in: .whitespaces).nilIfEmpty }
            let deviceID = attributeDict["deviceid"].flatMap { $0.trimmingCharacters(in: .whitespaces).nilIfEmpty }
            guard let name = nickname ?? model else { break }
            let computerGear = BlueDiveGearData(
                id: nil,
                type: GearCategory.computer.exportKey,
                manufacturer: nil,
                model: model,
                name: name,
                serial: serial,
                datePurchased: nil,
                purchasePrice: nil,
                currency: nil,
                purchasedFrom: nil,
                weightContribution: nil,
                weightContributionUnit: nil,
                lastServiceDate: nil,
                nextServiceDue: nil,
                serviceHistory: nil,
                gearNotes: nil,
                isInactive: false,
                diverName: ""
            )
            parsedDiveComputers.append(computerGear)
            if let did = deviceID { parsedComputersByDeviceID[did] = computerGear }

        // MARK: Dive Sites

        case "divesites":
            isInDiveSites = true

        case "site" where isInDiveSites:
            tempSiteUUID        = attributeDict["uuid"] ?? ""
            tempSiteName        = attributeDict["name"] ?? ""
            tempSiteGPS         = attributeDict["gps"]
            tempSiteCountry     = nil
            tempSiteBodyOfWater = nil

        case "geo" where isInDiveSites:
            // Subsurface taxonomy categories: 1=ocean, 2=country
            if let cat = attributeDict["cat"], let value = attributeDict["value"] {
                switch cat {
                case "1": tempSiteBodyOfWater = value.nilIfEmpty
                case "2": tempSiteCountry     = value.nilIfEmpty
                default:  break
                }
            }

        // MARK: Trip

        case "trip":
            isInTrip = true
            tempTripLocation = attributeDict["location"]?.nilIfEmpty

        // MARK: Dive

        case "dive":
            isInDive = true
            isFirstDiveComputerForDive = true
            resetTempDive()
            parseDiveAttributes(attributeDict)

        // MARK: Dive Computer (only first block is captured)

        case "divecomputer" where isInDive && isFirstDiveComputerForDive:
            isInDiveComputer = true
            isFirstDiveComputerForDive = false
            tempComputerName = attributeDict["model"]?.nilIfEmpty
            tempDiveID       = attributeDict["diveid"]?.nilIfEmpty
            tempDeviceID     = attributeDict["deviceid"]?.nilIfEmpty
            tempDCType       = attributeDict["dctype"]?.nilIfEmpty // absent for OC

        // MARK: DC child elements (first DC only)

        case "depth" where isInDiveComputer && tempMaxDepth == nil:
            tempMaxDepth  = attributeDict["max"].flatMap { parseSubsurfaceValue($0) }
            tempMeanDepth = attributeDict["mean"].flatMap { parseSubsurfaceValue($0) }

        case "temperature" where isInDiveComputer && tempDCAirTemp == nil:
            tempDCAirTemp   = attributeDict["air"].flatMap   { parseSubsurfaceValue($0) }
            tempDCWaterTemp = attributeDict["water"].flatMap { parseSubsurfaceValue($0) }

        case "extradata" where isInDiveComputer:
            // Subsurface stores DC extras as free-text key/value pairs. Capture the
            // serial (for duplicate detection) and the deco model / gradient factors
            // (e.g. "GF 50/70" or "Bühlmann ZHL-16C GF 30/85"), stored verbatim — the
            // GF Low/High are extracted from this string by the display layer.
            switch attributeDict["key"]?.lowercased() {
            case "serial":
                if let val = attributeDict["value"]?.nilIfEmpty { tempSerial = val }
            case "deco model":
                if let val = attributeDict["value"]?.nilIfEmpty { tempDecoModel = val }
            default:
                break
            }

        case "sample" where isInDiveComputer:
            parseSample(attributeDict)

        case "event" where isInDiveComputer:
            parseEvent(attributeDict)

        // MARK: Dive-level elements

        case "divetemperature" where isInDive:
            // User-entered temperatures — preferred over DC readings
            tempAirTemp   = attributeDict["air"].flatMap   { parseSubsurfaceValue($0) }
            tempWaterTemp = attributeDict["water"].flatMap { parseSubsurfaceValue($0) }

        case "cylinder" where isInDive:
            parseCylinder(attributeDict)

        case "weightsystem" where isInDive:
            if let w = attributeDict["weight"].flatMap({ parseSubsurfaceValue($0) }) {
                tempWeightKg += w
            }

        // MARK: Notes (context-sensitive)

        case "notes" where isInDive:
            isInNotesDive = true
        case "notes" where isInTrip:
            isInNotesTrip = true
        case "notes" where isInDiveSites:
            isInNotesSite = true

        // MARK: Divemaster / Buddy

        case "divemaster" where isInDive:
            isInDivemaster = true
        case "buddy" where isInDive:
            isInBuddy = true
        case "suit" where isInDive:
            isInSuit = true

        default:
            break
        }
    }

    // MARK: - XMLParserDelegate: Characters

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    // MARK: - XMLParserDelegate: End Element

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {

        // MARK: Dive Sites

        case "settings":
            isInSettings = false

        case "divesites":
            isInDiveSites = false

        case "site" where isInDiveSites:
            let (lat, lon) = parseGPS(tempSiteGPS)
            let site = BlueDiveSiteData(
                name: tempSiteName,
                location: nil,
                country: tempSiteCountry,
                bodyOfWater: tempSiteBodyOfWater,
                waterType: nil,
                difficulty: nil,
                altitude: nil,
                latitude: lat,
                longitude: lon,
                exitLatitude: nil,
                exitLongitude: nil
            )
            if !tempSiteUUID.isEmpty {
                diveSites[tempSiteUUID] = site
            }

        // MARK: Trip

        case "trip":
            isInTrip = false
            tempTripLocation = nil

        // MARK: Dive Computer

        case "divecomputer" where isInDive && isInDiveComputer:
            isInDiveComputer = false

        // MARK: Dive

        case "dive":
            finalizeDive()
            isInDive = false

        // MARK: Notes

        case "notes" where isInNotesDive:
            isInNotesDive = false
            tempNotes = text.nilIfEmpty

        case "notes" where isInNotesTrip:
            isInNotesTrip = false
            // Trip notes have no destination field — dropped intentionally

        case "notes" where isInNotesSite:
            isInNotesSite = false
            // Site notes have no destination field — dropped intentionally

        // MARK: Divemaster / Buddy

        case "divemaster" where isInDivemaster:
            isInDivemaster = false
            tempDivemaster = text.nilIfEmpty

        case "buddy" where isInBuddy:
            isInBuddy = false
            if let b = text.nilIfEmpty { tempBuddyNames.append(b) }

        case "suit" where isInSuit:
            isInSuit = false
            tempSuit = text.nilIfEmpty

        default:
            break
        }

        currentText = ""
    }

    // MARK: - Attribute Parsing Helpers

    private func parseDiveAttributes(_ attrs: [String: String]) {
        if let n = attrs["number"].flatMap({ Int($0) }) { tempDiveNumber = n }

        if let r = attrs["rating"].flatMap({ Int($0) }), r > 0 { tempRating = r }

        // Visibility: Subsurface stores 0–5 stars; 0 means unrated.
        // Store as "N/5 ★" so the display layer can render it as text
        // rather than appending a depth unit symbol to a numeric value.
        if let v = attrs["visibility"].flatMap({ Int($0) }), v > 0 {
            tempVisibility = "\(v)/5 \u{2605}"
        }

        tempTags = attrs["tags"]?.nilIfEmpty
        tempDiveSiteID = attrs["divesiteid"]?.nilIfEmpty

        // CNS percentage (strip trailing %)
        if let cnsStr = attrs["cns"] {
            let stripped = cnsStr.replacingOccurrences(of: "%", with: "")
                                 .trimmingCharacters(in: .whitespaces)
            tempCNS = Double(stripped)
        }

        // Date + time → Date object. Time defaults to midnight when absent (manual entries).
        if let dateStr = attrs["date"] {
            let timeStr = attrs["time"] ?? "00:00:00"
            tempDate = dateFormatter.date(from: "\(dateStr) \(timeStr)")
        }

        // Duration: "77:54 min" → seconds
        if let durStr = attrs["duration"] {
            tempDuration = parseSubsurfaceTime(durStr) ?? 0
        }
    }

    private func parseCylinder(_ attrs: [String: String]) {
        let volume       = attrs["size"].flatMap         { parseSubsurfaceValue($0) }
        let workPressure = attrs["workpressure"].flatMap { parseSubsurfaceValue($0) }
        let startPres    = attrs["start"].flatMap        { parseSubsurfaceValue($0) }
        let endPres      = attrs["end"].flatMap          { parseSubsurfaceValue($0) }

        // O2 and He are written as "21.0%" — strip % and round to Int
        let o2 = attrs["o2"].flatMap { s -> Int? in
            let clean = s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
            return Double(clean).map { Int($0.rounded()) }
        }
        let he = attrs["he"].flatMap { s -> Int? in
            let clean = s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
            return Double(clean).map { Int($0.rounded()) }
        }

        // Subsurface omits the o2 (and he) attributes for plain air; a cylinder with
        // neither is air (21% O₂). Record 21 rather than an unknown mix, matching how
        // Subsurface itself interprets the absent attribute. If o2 is present but
        // unparseable, or he is present (trimix), leave o2 as parsed.
        let resolvedO2 = o2 ?? ((attrs["o2"] == nil && attrs["he"] == nil) ? 21 : nil)

        tempTanks.append(BlueDiveTankData(
            oxygen: resolvedO2,
            helium: he,
            volume: volume,
            startPressure: startPres,
            endPressure: endPres,
            workingPressure: workPressure
        ))
    }

    private func parseSample(_ attrs: [String: String]) {
        guard
            let timeStr = attrs["time"],
            let timeSec = parseSubsurfaceTime(timeStr),
            let depthStr = attrs["depth"],
            let depth = parseSubsurfaceValue(depthStr)
        else { return }

        let temp     = attrs["temp"].flatMap    { parseSubsurfaceValue($0) }
        // For OC dives this attribute is absent; for CCR dives it is the setpoint (in bar).
        let ppo2     = attrs["po2"].flatMap { parseSubsurfaceValue($0) }

        // Track the max per-sample CNS (written as "N%"), used as the dive CNS when the
        // dive-level cns attribute is absent.
        if let sampleCNS = attrs["cns"].flatMap({ Double($0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }) {
            tempMaxSampleCNS = max(tempMaxSampleCNS ?? 0, sampleCNS)
        }

        // NDL: "240:00 min" → seconds → minutes (stored in ndt as minutes)
        let ndtMinutes = attrs["ndl"].flatMap { parseSubsurfaceTime($0) }.map { $0 / 60 }

        // Tank pressure: modern Subsurface writes one attribute per sensor —
        // pressure0=, pressure1=, … (the N is the sensor id) — while older/third-party
        // files use a bare pressure= or cylpress=. Capture every sensor, keyed by index.
        // CCR O₂-cell readings are written as sensor1=, sensor2=, … (ppO₂ in bar).
        var tankPressures: [Int: Double] = [:]
        var sensorPPO2: [Int: Double] = [:]
        for (key, value) in attrs {
            if key == "pressure" || key == "cylpress" {
                if let p = parseSubsurfaceValue(value) { tankPressures[0] = p }  // legacy single-sensor form
            } else if key.hasPrefix("pressure"), let n = Int(key.dropFirst(8)) {
                if let p = parseSubsurfaceValue(value) { tankPressures[n] = p }
            } else if key.hasPrefix("sensor"), let n = Int(key.dropFirst(6)) {
                if let pp = parseSubsurfaceValue(value) { sensorPPO2[n] = pp }
            }
        }

        // Events, gas index, per-sample tank pressure/sensor ppO₂ and forward-filled
        // fields are resolved after the whole divecomputer block is parsed
        // (resolveSampleEventsAndGas), so pressure/currentGas are placeholders here.
        tempSamples.append(BlueDiveSamplesData(
            time: Double(timeSec),
            depth: depth,
            tankPressures: tankPressures.isEmpty ? nil : tankPressures,
            temperature: temp,
            ppo2: ppo2,
            sensorPPO2: sensorPPO2.isEmpty ? nil : sensorPPO2,
            ndt: ndtMinutes,
            currentGas: 0
        ))
    }

    private func parseEvent(_ attrs: [String: String]) {
        guard
            let name    = attrs["name"],
            let timeStr = attrs["time"],
            let timeSec = parseSubsurfaceTime(timeStr)
        else { return }

        // Buffer only events we know how to map; gas index and marker placement are
        // resolved once the whole divecomputer block is parsed (resolveSampleEventsAndGas),
        // so we do not depend on the document order of <event> vs <sample>.
        guard mapEvent(name: name) != nil else { return }
        let cylinder = attrs["cylinder"].flatMap { Int($0) }
        tempRawEvents.append((time: timeSec, name: name, cylinder: cylinder))
    }

    /// Maps a Subsurface event name to a DiveProfileEvent, or nil if unsupported.
    private func mapEvent(name: String) -> DiveProfileEvent? {
        switch name.lowercased() {
        case "gaschange":                                    return .gasChange
        case "ascent":                                       return .ascent
        case "violation":                                    return .violation
        case "deco", "decostop", "deco stop":                return .decoStop
        case "safety stop", "safetystop":                    return .safetyStop(false)
        case "mandatory safety stop", "mandatorysafetystop": return .safetyStop(true)
        case "ceiling":                                      return .ceiling
        case "po2":                                          return .po2
        case "deep stop", "deepstop":                        return .deepStop
        default:                                             return nil
        }
    }

    /// Resolves buffered events against the full sample array, independent of the
    /// document order in which Subsurface writes <event> vs <sample> at the same time.
    /// - Delta decode: Subsurface omits an optional sample field (temp, pressureN,
    ///   sensorN ppO₂, ndl, po2) when it is unchanged from the previous sample, holding
    ///   the last value. We forward-fill so profiles are continuous rather than sparse.
    /// - Gas index: each sample's currentGas is the cylinder of the last gaschange at or
    ///   before the sample's time (0 when none precedes it).
    /// - Markers: each event attaches to the first sample at or after its time, or the
    ///   last sample when the event is past the final sample.
    private func resolveSampleEventsAndGas() {
        guard !tempSamples.isEmpty else { return }

        let gasChanges = tempRawEvents
            .filter { $0.name.lowercased() == "gaschange" }
            .sorted { $0.time < $1.time }

        var lastTemp: Double? = nil
        var lastNdt: Int? = nil
        var lastPpo2: Double? = nil
        var runningTankPressures: [Int: Double] = [:]
        var runningSensorPPO2: [Int: Double] = [:]

        var rebuilt: [BlueDiveSamplesData] = tempSamples.map { s in
            // Forward-fill the delta-encoded fields from the last sample that carried them.
            if let t = s.temperature { lastTemp = t }
            if let n = s.ndt { lastNdt = n }
            if let pp = s.ppo2 { lastPpo2 = pp }
            if let tp = s.tankPressures { for (k, v) in tp { runningTankPressures[k] = v } }
            if let sp = s.sensorPPO2 { for (k, v) in sp { runningSensorPPO2[k] = v } }

            let filledTankPressures = runningTankPressures.isEmpty ? nil : runningTankPressures
            let filledSensorPPO2 = runningSensorPPO2.isEmpty ? nil : runningSensorPPO2
            // Primary pressure = the lowest-indexed sensor (sensor 0 when present).
            let primaryPressure = runningTankPressures.min { $0.key < $1.key }?.value

            var gas = 0
            for gc in gasChanges {
                if Double(gc.time) <= s.time { gas = gc.cylinder ?? 0 } else { break }
            }
            return BlueDiveSamplesData(
                time: s.time, depth: s.depth, pressure: primaryPressure,
                tankPressures: filledTankPressures, temperature: lastTemp,
                ppo2: lastPpo2, sensorPPO2: filledSensorPPO2, ndt: lastNdt,
                events: s.events, currentGas: gas
            )
        }

        // Dive-start reference: a gaschange at or before the first sample establishes the
        // starting gas rather than a mid-dive switch, so its marker is suppressed (the gas
        // index is still applied above via the gas timeline). This mirrors the Garmin FIT
        // importer, which draws no gas-switch marker for the initial/seeded t=0 gas.
        // Use the earliest sample time (not document order) so out-of-order samples are safe.
        let startTime = rebuilt.map(\.time).min() ?? 0

        // Drop byte-identical duplicate <event> lines (some exports contain them) by
        // keying on the raw (time, name, cylinder) tuple. This is more precise than a
        // per-sample event-type check: two genuinely distinct gaschanges to different
        // cylinders are preserved, while exact duplicates collapse to a single marker.
        var seenRawEvents = Set<String>()
        for raw in tempRawEvents {
            let dedupeKey = "\(raw.time)|\(raw.name.lowercased())|\(raw.cylinder.map(String.init) ?? "")"
            guard seenRawEvents.insert(dedupeKey).inserted else { continue }
            guard let ev = mapEvent(name: raw.name) else { continue }
            // Suppress the initial gas-selection marker (matches Garmin FIT behaviour).
            if raw.name.lowercased() == "gaschange", Double(raw.time) <= startTime { continue }
            let t = Double(raw.time)
            let idx = rebuilt.firstIndex(where: { $0.time >= t }) ?? (rebuilt.count - 1)
            let s = rebuilt[idx]
            rebuilt[idx] = BlueDiveSamplesData(
                time: s.time, depth: s.depth, pressure: s.pressure,
                tankPressures: s.tankPressures, temperature: s.temperature,
                ppo2: s.ppo2, sensorPPO2: s.sensorPPO2, ndt: s.ndt,
                events: s.events + [ev], currentGas: s.currentGas
            )
        }

        tempSamples = rebuilt
    }

    // MARK: - Finalize Dive

    private func finalizeDive() {
        // Resolve profile event markers and per-sample gas index across the full
        // sample array (order-independent) before assembling the dive.
        resolveSampleEventsAndGas()

        // Resolve dive site: prefer divesiteid lookup, fall back to trip location
        let site: BlueDiveSiteData?
        if let siteID = tempDiveSiteID, let resolved = diveSites[siteID] {
            site = resolved
        } else if let tripLoc = tempTripLocation {
            site = BlueDiveSiteData(
                name: tripLoc,
                location: nil, country: nil, bodyOfWater: nil,
                waterType: nil, difficulty: nil, altitude: nil,
                latitude: nil, longitude: nil,
                exitLatitude: nil, exitLongitude: nil
            )
        } else {
            site = nil
        }

        // Temperature: user-entered <divetemperature> wins over DC <temperature>
        let airTemp   = tempAirTemp   ?? tempDCAirTemp
        let waterTemp = tempWaterTemp ?? tempDCWaterTemp

        // Buddy: Subsurface may write several <buddy> elements and/or a comma-separated
        // list within one. Accumulate all elements, then split each on commas.
        let buddies: [String] = tempBuddyNames.flatMap { raw in
            raw.split(separator: ",")
               .map { $0.trimmingCharacters(in: .whitespaces) }
               .filter { !$0.isEmpty }
        }

        // Dive type: Subsurface omits dctype for OC (the default), only writes it for CCR/PSCR/Freedive
        let diveTypes: [String] = tempDCType.map { [$0] } ?? []

        // Match the settings registry to this dive's computer using a three-tier cascade:
        //   1. deviceid — the canonical join key Subsurface uses (O(1) dict lookup)
        //   2. serial   — definitive when present on both sides (case-insensitive)
        //   3. model    — trimmed, case-insensitive fallback
        let diveComputerGear: [BlueDiveGearData]
        if importGear {
            if let did = tempDeviceID, !did.isEmpty, let byDevice = parsedComputersByDeviceID[did] {
                diveComputerGear = [byDevice]
            } else {
                diveComputerGear = parsedDiveComputers.filter { computer in
                    if let cs = computer.serial?.lowercased(), !cs.isEmpty,
                       let ds = tempSerial?.lowercased(), !ds.isEmpty {
                        return cs == ds
                    }
                    if let cm = computer.model?.trimmingCharacters(in: .whitespaces).lowercased(),
                       let dm = tempComputerName?.trimmingCharacters(in: .whitespaces).lowercased(),
                       !cm.isEmpty, !dm.isEmpty {
                        return cm == dm
                    }
                    return false
                }
            }
        } else {
            diveComputerGear = []
        }

        // Assemble the dive's gear: dive computer(s) plus the exposure suit (if any).
        // The suit's category is inferred from its own text — "dry" → drysuit, else
        // wetsuit — and its name is preserved verbatim. Gated on importGear like the DC.
        var gearItems = diveComputerGear
        if importGear, let suit = tempSuit {
            let category: GearCategory = suit.lowercased().contains("dry") ? .drysuit : .suit
            gearItems.append(BlueDiveGearData(
                id: nil,
                type: category.exportKey,
                manufacturer: nil,
                model: nil,
                name: suit,
                serial: nil,
                datePurchased: nil,
                purchasePrice: nil,
                currency: nil,
                purchasedFrom: nil,
                weightContribution: nil,
                weightContributionUnit: nil,
                lastServiceDate: nil,
                nextServiceDue: nil,
                serviceHistory: nil,
                gearNotes: nil,
                isInactive: false,
                diverName: ""
            ))
        }

        dives.append(BlueDiveGlobalData(
            distanceFormat:    "meters",
            temperatureFormat: "°c",
            pressureFormat:    "bar",
            volumeFormat:      "liters",
            weightFormat:      "kg",
            sourceImport:      "Subsurface",
            isBlueDiveXMLImport: false,
            date:              tempDate,
            identifier:        tempDiveID,
            recordID:          nil,
            diveNumber:        tempDiveNumber,
            rating:            tempRating,
            repetitiveDive:    nil,
            diver:             nil,
            computer:          tempComputerName,
            serial:            tempSerial,
            maxDepth:          tempMaxDepth ?? 0.0,
            averageDepth:      tempMeanDepth,
            duration:          tempDuration,
            interval:          nil,
            cns:               tempCNS ?? tempMaxSampleCNS,
            decoModel:         tempDecoModel,
            isDecompressionDive: false,
            tempAir:           airTemp,
            tempHigh:          nil,
            tempLow:           waterTemp,
            visibility:        tempVisibility,
            weight:            tempWeightKg > 0 ? tempWeightKg : nil,
            weather:           nil,
            current:           nil,
            surfaceConditions: nil,
            entryType:         nil,
            diveMaster:        tempDivemaster,
            diveOperator:      nil,
            skipper:           nil,
            boat:              nil,
            surfaceInterval:   nil,
            notes:             tempNotes,
            tags:              tempTags,
            site:              site,
            types:             diveTypes,
            buddies:           buddies,
            gases:             [],
            tanks:             tempTanks,
            gear:              gearItems,
            samples:           tempSamples,
            marineLifeSeen:    [],
            decoStops:         [],
            rawDiveComputerData: nil,
            fingerprintData:   nil
        ))
    }

    // MARK: - Reset Temp Dive

    private func resetTempDive() {
        tempDiveNumber   = nil
        tempDate         = nil
        tempDuration     = 0
        tempRating       = nil
        tempVisibility   = nil
        tempTags         = nil
        tempDiveSiteID   = nil
        tempCNS          = nil
        tempMaxSampleCNS = nil
        tempNotes        = nil
        tempDivemaster   = nil
        tempBuddyNames   = []
        tempSuit         = nil
        tempAirTemp      = nil
        tempWaterTemp    = nil
        tempDCAirTemp    = nil
        tempDCWaterTemp  = nil
        tempMaxDepth     = nil
        tempMeanDepth    = nil
        tempComputerName = nil
        tempDiveID       = nil
        tempDeviceID     = nil
        tempSerial       = nil
        tempDCType       = nil
        tempDecoModel    = nil
        tempTanks        = []
        tempWeightKg     = 0.0
        tempSamples      = []
        tempRawEvents    = []
        isFirstDiveComputerForDive = true
    }

    // MARK: - Parsing Helpers

    /// Parses "MM:SS min", "MM:SS", or "H:MM:SS" into seconds.
    /// Minutes are unbounded (e.g. "240:00 min" for a 4-hour NDL value).
    private func parseSubsurfaceTime(_ str: String) -> Int? {
        var s = str
        if let r = s.range(of: " min") { s = String(s[s.startIndex..<r.lowerBound]) }
        s = s.trimmingCharacters(in: .whitespaces)
        let parts = s.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }

    /// Strips a trailing unit suffix (space + unit, or "%") and parses the numeric part.
    /// Examples: "38.99 m" → 38.99,  "200.0 bar" → 200.0,  "10.0 C" → 10.0,  "21.0%" → 21.0.
    private func parseSubsurfaceValue(_ str: String) -> Double? {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        if let spaceIdx = trimmed.firstIndex(of: " ") {
            return Double(trimmed[..<spaceIdx])
        }
        // No space — strip any non-numeric trailing characters (e.g. "%")
        let numericPart = trimmed.trimmingCharacters(
            in: CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ".-")).inverted
        )
        return Double(numericPart)
    }

    /// Parses a "lat lon" GPS string into (latitude, longitude).
    private func parseGPS(_ str: String?) -> (Double?, Double?) {
        guard let s = str else { return (nil, nil) }
        let parts = s.split(separator: " ").compactMap { Double($0) }
        guard parts.count >= 2 else { return (nil, nil) }
        return (parts[0], parts[1])
    }
}

// MARK: - String Helper

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
