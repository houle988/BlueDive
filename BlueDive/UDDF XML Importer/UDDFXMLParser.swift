import Foundation

// MARK: - UDDF XML Parser
//
// Parses UDDF v3.2.x files and outputs [BlueDiveGlobalData] for import.
//
// UDDF uses SI units exclusively:
//   - Depth:       metres (m)
//   - Temperature: Kelvin (K)
//   - Pressure:    Pascal (Pa)
//   - Volume:      cubic metres (m³)
//   - Weight:      kilograms (kg)
//   - Time:        seconds (s)
//   - GPS:         decimal degrees
//
// The parser converts SI values to metric display units on output:
//   K  → °C,  Pa → bar,  m³ → litres.
// Depth (m), weight (kg), and time (s) need no conversion.

final class UDDFXMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {

    // MARK: - Public Result

    private(set) var dives: [BlueDiveGlobalData] = []

    // MARK: - Import Settings

    var importGear: Bool = true

    // MARK: - Global Lookup Dictionaries (populated before dives are parsed)

    /// Gas mixes keyed by mix id → (o2 fraction, he fraction)
    private var gasMixes: [String: (o2: Double, he: Double)] = [:]

    /// Dive sites keyed by site id
    private var sites: [String: BlueDiveSiteData] = [:]

    /// Buddy names keyed by buddy id
    private var buddyNames: [String: String] = [:]

    /// Owner diver name (firstname + lastname)
    private var ownerName: String?

    /// Owner dive computer info (first computer found)
    private var ownerComputer: String?
    private var ownerComputerSerial: String?

    /// Owner equipment (variouspieces)
    private var ownerGear: [BlueDiveGearData] = []

    /// Decompression model name
    private var decoModelName: String?

    /// Buehlmann model identifier (e.g., "zhl-16c" from <buehlmann id="zhl–16c">)
    private var decoBuehlmannId: String?

    /// Gradient factors (from buehlmann decomodel, stored as fractions 0.0–1.0)
    private var decoGFLow: Double?
    private var decoGFHigh: Double?

    /// Trip data: trippart id → (operator name, vessel name)
    private var tripParts: [String: (operatorName: String?, vesselName: String?)] = [:]

    /// Dive id → trippart id (built from relateddives links inside tripparts)
    private var diveToTripPart: [String: String] = [:]

    // MARK: - XML Parsing State

    private var elementStack: [String] = []
    private var currentText = ""

    // Temporary state for global sections
    private var tempMixId: String?
    private var tempMixO2: Double?
    private var tempMixHe: Double?

    private var tempSiteId: String?
    private var tempSiteName: String?
    private var tempSiteLocation: String?
    private var tempSiteCountry: String?
    private var tempSiteEnvironment: String?
    private var tempSiteDifficulty: String?
    private var tempSiteAltitude: Double?
    private var tempSiteLatitude: Double?
    private var tempSiteLongitude: Double?

    private var tempBuddyId: String?
    private var tempBuddyFirstname: String?
    private var tempBuddyLastname: String?

    private var tempOwnerFirstname: String?
    private var tempOwnerLastname: String?
    private var tempDiveComputerName: String?
    private var tempDiveComputerSerial: String?

    private var tempGearName: String?
    private var tempGearManufacturer: String?
    private var tempGearSerial: String?

    private var tempTripPartId: String?
    private var tempOperatorName: String?
    private var tempVesselName: String?
    private var tempRelatedDiveIds: [String] = []

    // Temporary state for current dive
    private var currentDiveId: String?
    private var currentDate: Date?
    private var currentDiveNumber: Int?
    private var currentRating: Int?
    private var currentRepetitiveDive: Int?
    private var currentMaxDepth: Double = 0.0
    private var currentAverageDepth: Double?
    private var currentDuration: Int = 0
    private var currentCNS: Double?
    private var currentTempAir: Double?
    private var currentTempLow: Double?
    private var currentVisibility: String?
    private var currentWeight: Double?
    private var currentCurrent: String?
    private var currentEntryType: String?
    private var currentPurpose: String?
    private var currentSurfaceInterval: Int?
    private var currentNotes: [String] = []
    private var currentSiteRef: String?
    private var currentBuddyRefs: [String] = []
    private var currentSamples: [BlueDiveSamplesData] = []

    // Tank data within a dive
    private var currentTanks: [BlueDiveTankData] = []
    private var tempTankId: String?
    private var tempTankMixRef: String?
    private var tempTankPressureBegin: Double?
    private var tempTankPressureEnd: Double?
    private var tempTankVolume: Double?

    // Waypoint temporaries
    private var tempWaypointTime: Double?
    private var tempWaypointDepth: Double?
    private var tempWaypointPressure: Double?
    private var tempWaypointTemperature: Double?
    private var tempWaypointPPO2: Double?
    private var tempWaypointNDT: Int?
    private var tempWaypointCNS: Double?

    // Context flags
    private var isInDive = false
    private var isInWaypoint = false
    private var isInTankData = false
    private var isInOwner = false
    private var isInBuddy = false
    private var isInMix = false
    private var isInSite = false
    private var isInDecoModel = false
    private var isInBuehlmann = false
    private var isInDiveComputer = false
    private var isInVariousPieces = false
    private var isInTripPart = false
    private var isInOperator = false
    private var isInVessel = false
    private var isInRelatedDives = false
    private var isInEquipmentUsed = false
    private var isInManufacturer = false
    private var isInInformationBeforeDive = false
    private var isInInformationAfterDive = false
    private var isInSamples = false
    private var isInSurfaceIntervalBeforeDive = false
    private var isInRating = false
    private var isInNotes = false
    private var isInGeography = false
    private var isInAddress = false
    private var isInSiteData = false
    private var isInPersonal = false

    // MARK: - Date Formatter

    private lazy var iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private lazy var iso8601FormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private lazy var dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    // MARK: - Public API

    func parse(data: Data) -> [BlueDiveGlobalData]? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        return parser.parse() ? dives : nil
    }

    // MARK: - XMLParserDelegate — Element Start

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        elementStack.append(elementName)
        currentText = ""

        switch elementName {

        // --- Global sections ---
        case "mix":
            isInMix = true
            tempMixId = attributeDict["id"]
            tempMixO2 = nil
            tempMixHe = nil

        case "site":
            isInSite = true
            tempSiteId = attributeDict["id"]
            resetTempSite()

        case "owner":
            isInOwner = true
            tempOwnerFirstname = nil
            tempOwnerLastname = nil

        case "buddy":
            if !isInDive {
                // Global buddy definition
                isInBuddy = true
                tempBuddyId = attributeDict["id"]
                tempBuddyFirstname = nil
                tempBuddyLastname = nil
            }

        case "personal":
            isInPersonal = true

        case "divecomputer":
            if isInOwner {
                isInDiveComputer = true
                tempDiveComputerName = nil
                tempDiveComputerSerial = nil
            }

        case "variouspieces":
            if isInOwner && importGear {
                isInVariousPieces = true
                tempGearName = nil
                tempGearManufacturer = nil
                tempGearSerial = nil
            }

        case "manufacturer":
            isInManufacturer = true

        case "decomodel":
            isInDecoModel = true

        case "buehlmann":
            if isInDecoModel {
                isInBuehlmann = true
                decoBuehlmannId = attributeDict["id"]
            }

        case "trippart":
            isInTripPart = true
            tempTripPartId = attributeDict["id"]
            tempOperatorName = nil
            tempVesselName = nil
            tempRelatedDiveIds = []

        case "operator":
            if isInTripPart { isInOperator = true }

        case "vessel":
            if isInTripPart { isInVessel = true }

        case "relateddives":
            if isInTripPart { isInRelatedDives = true }

        // --- Dive sections ---
        case "dive":
            isInDive = true
            currentDiveId = attributeDict["id"]
            resetCurrentDive()

        case "informationbeforedive":
            isInInformationBeforeDive = true

        case "informationafterdive":
            isInInformationAfterDive = true

        case "samples":
            if isInDive { isInSamples = true }

        case "waypoint":
            if isInSamples {
                isInWaypoint = true
                resetTempWaypoint()
            }

        case "tankdata":
            if isInDive {
                isInTankData = true
                tempTankId = attributeDict["id"]
                tempTankMixRef = nil
                tempTankPressureBegin = nil
                tempTankPressureEnd = nil
                tempTankVolume = nil
            }

        case "surfaceintervalbeforedive":
            isInSurfaceIntervalBeforeDive = true

        case "rating":
            if isInInformationAfterDive { isInRating = true }

        case "notes":
            if isInInformationAfterDive { isInNotes = true }

        case "equipmentused":
            if isInInformationAfterDive { isInEquipmentUsed = true }

        case "geography":
            if isInSite { isInGeography = true }

        case "address":
            if isInGeography { isInAddress = true }

        case "sitedata":
            if isInSite { isInSiteData = true }

        case "link":
            // Process link references immediately from attributes
            if let ref = attributeDict["ref"] {
                handleLink(ref: ref)
            }

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

        switch elementName {

        // --- Gas mix ---
        case "o2":
            if isInMix { tempMixO2 = Double(text) }
        case "he":
            if isInMix { tempMixHe = Double(text) }
        case "mix":
            if isInMix, let id = tempMixId {
                gasMixes[id] = (o2: tempMixO2 ?? 0.21, he: tempMixHe ?? 0.0)
            }
            isInMix = false

        // --- Site ---
        case "name":
            if isInOperator {
                tempOperatorName = text.nilIfEmpty
            } else if isInVessel {
                tempVesselName = text.nilIfEmpty
            } else if isInVariousPieces {
                tempGearName = text.nilIfEmpty
            } else if isInDiveComputer {
                tempDiveComputerName = text.nilIfEmpty
            } else if isInSite && !isInGeography && !isInSiteData {
                tempSiteName = text.nilIfEmpty
            }
        case "location":
            if isInGeography { tempSiteLocation = text.nilIfEmpty }
        case "country":
            if isInAddress { tempSiteCountry = text.nilIfEmpty }
        case "environment":
            if isInSite && !isInSiteData { tempSiteEnvironment = text.nilIfEmpty }
        case "altitude":
            if isInGeography { tempSiteAltitude = Double(text) }
        case "latitude":
            if isInGeography { tempSiteLatitude = Double(text) }
        case "longitude":
            if isInGeography { tempSiteLongitude = Double(text) }
        case "difficulty":
            if isInSiteData { tempSiteDifficulty = text.nilIfEmpty }
        case "address":
            isInAddress = false
        case "geography":
            isInGeography = false
        case "sitedata":
            isInSiteData = false
        case "site":
            if isInSite {
                if let id = tempSiteId, let name = tempSiteName {
                    sites[id] = BlueDiveSiteData(
                        name: name,
                        location: tempSiteLocation,
                        country: tempSiteCountry,
                        bodyOfWater: tempSiteEnvironment,
                        waterType: nil,
                        difficulty: tempSiteDifficulty,
                        altitude: tempSiteAltitude,
                        latitude: tempSiteLatitude,
                        longitude: tempSiteLongitude
                    )
                }
                isInSite = false
            }

        // --- Diver / Owner / Buddy ---
        case "firstname":
            if isInPersonal {
                if isInOwner && !isInBuddy {
                    tempOwnerFirstname = text.nilIfEmpty
                } else if isInBuddy {
                    tempBuddyFirstname = text.nilIfEmpty
                }
            }
        case "lastname":
            if isInPersonal {
                if isInOwner && !isInBuddy {
                    tempOwnerLastname = text.nilIfEmpty
                } else if isInBuddy {
                    tempBuddyLastname = text.nilIfEmpty
                }
            }
        case "personal":
            isInPersonal = false

        case "serialnumber":
            if isInDiveComputer {
                tempDiveComputerSerial = text.nilIfEmpty
            } else if isInVariousPieces {
                tempGearSerial = text.nilIfEmpty
            }

        case "divecomputer":
            if isInDiveComputer {
                // Store the first dive computer found
                if ownerComputer == nil {
                    ownerComputer = tempDiveComputerName
                    ownerComputerSerial = tempDiveComputerSerial
                }
                isInDiveComputer = false
            }

        case "variouspieces":
            if isInVariousPieces {
                if let name = tempGearName {
                    ownerGear.append(BlueDiveGearData(
                        type: name,
                        manufacturer: tempGearManufacturer,
                        model: nil,               // NOT imported from UDDF
                        name: name,
                        serial: tempGearSerial,
                        datePurchased: nil,
                        purchasePrice: nil,
                        currency: nil,
                        purchasedFrom: nil,
                        weightContribution: nil,
                        weightContributionUnit: nil,  // NOT imported from UDDF
                        nextServiceDue: nil,
                        serviceHistory: nil,
                        gearNotes: nil,
                        isInactive: false
                    ))
                }
                isInVariousPieces = false
            }

        case "owner":
            if isInOwner {
                let parts = [tempOwnerFirstname, tempOwnerLastname].compactMap { $0 }
                ownerName = parts.isEmpty ? nil : parts.joined(separator: " ")
                isInOwner = false
            }

        case "buddy":
            if isInBuddy && !isInDive {
                // Global buddy definition
                if let id = tempBuddyId {
                    let parts = [tempBuddyFirstname, tempBuddyLastname].compactMap { $0 }
                    buddyNames[id] = parts.isEmpty ? nil : parts.joined(separator: " ")
                }
                isInBuddy = false
            }

        // --- Manufacturer (inside variouspieces) ---
        case "manufacturer":
            if isInManufacturer && isInVariousPieces {
                // The name was handled in "name" case above
            }
            isInManufacturer = false

        // --- Decomodel ---
        case "gradientfactorlow":
            if isInBuehlmann { decoGFLow = Double(text) }
        case "gradientfactorhigh":
            if isInBuehlmann { decoGFHigh = Double(text) }
        case "buehlmann":
            if isInDecoModel {
                // Use the id attribute as the model name if available (e.g., "ZHL-16C"),
                // otherwise fall back to "Buehlmann"
                if let modelId = decoBuehlmannId, !modelId.isEmpty {
                    decoModelName = modelId.uppercased()
                } else {
                    decoModelName = "Buehlmann"
                }
                isInBuehlmann = false
            }
        case "rgbm":
            if isInDecoModel { decoModelName = "RGBM" }
        case "vpm":
            if isInDecoModel { decoModelName = "VPM" }
        case "decomodel":
            // Append GF values to the deco model name if present
            if let gfLow = decoGFLow, let gfHigh = decoGFHigh {
                let low = Int((gfLow * 100).rounded())
                let high = Int((gfHigh * 100).rounded())
                decoModelName = (decoModelName ?? "Buehlmann") + " GF \(low)/\(high)"
            }
            isInDecoModel = false

        // --- Trip ---
        case "operator":
            isInOperator = false
        case "vessel":
            isInVessel = false
        case "relateddives":
            isInRelatedDives = false
        case "trippart":
            if isInTripPart {
                let partId = tempTripPartId ?? UUID().uuidString
                tripParts[partId] = (operatorName: tempOperatorName, vesselName: tempVesselName)
                for diveId in tempRelatedDiveIds {
                    diveToTripPart[diveId] = partId
                }
                isInTripPart = false
            }

        // --- Dive: informationbeforedive fields ---
        case "datetime":
            if isInInformationBeforeDive {
                currentDate = parseUDDFDate(text)
            }
        case "divenumber":
            if isInInformationBeforeDive { currentDiveNumber = Int(text) }
        case "divenumberofday":
            if isInInformationBeforeDive { currentRepetitiveDive = Int(text) }
        case "airtemperature":
            if isInInformationBeforeDive {
                if let k = Double(text) { currentTempAir = kelvinToCelsius(k) }
            }
        case "platform":
            if isInInformationBeforeDive { currentEntryType = text.nilIfEmpty }
        case "purpose":
            if isInInformationBeforeDive { currentPurpose = text.nilIfEmpty }
        case "passedtime":
            if isInSurfaceIntervalBeforeDive {
                currentSurfaceInterval = parseSeconds(text)
            }
        case "surfaceintervalbeforedive":
            isInSurfaceIntervalBeforeDive = false
        case "informationbeforedive":
            isInInformationBeforeDive = false

        // --- Dive: informationafterdive fields ---
        case "greatestdepth":
            if isInInformationAfterDive { currentMaxDepth = Double(text) ?? 0.0 }
        case "averagedepth":
            if isInInformationAfterDive { currentAverageDepth = Double(text) }
        case "diveduration":
            if isInInformationAfterDive { currentDuration = parseSeconds(text) ?? 0 }
        case "lowesttemperature":
            if isInInformationAfterDive {
                if let k = Double(text) { currentTempLow = kelvinToCelsius(k) }
            }
        case "visibility":
            if isInInformationAfterDive {
                // UDDF visibility is in metres
                if let v = Double(text) {
                    currentVisibility = String(format: "%.1f", v)
                }
            }
        case "current":
            if isInInformationAfterDive { currentCurrent = text.nilIfEmpty }
        case "leadquantity":
            if isInEquipmentUsed {
                currentWeight = Double(text)
            }
        case "ratingvalue":
            if isInRating { currentRating = Int(text) }
        case "para":
            if isInNotes && !text.isEmpty {
                currentNotes.append(text)
            }
        case "rating":
            if isInRating { isInRating = false }
        case "notes":
            if isInNotes { isInNotes = false }
        case "equipmentused":
            isInEquipmentUsed = false
        case "informationafterdive":
            isInInformationAfterDive = false

        // --- Tank data ---
        case "tankpressurebegin":
            if isInTankData { tempTankPressureBegin = Double(text) }
        case "tankpressureend":
            if isInTankData { tempTankPressureEnd = Double(text) }
        case "tankvolume":
            if isInTankData { tempTankVolume = Double(text) }
        case "tankdata":
            if isInTankData {
                // Resolve gas mix from link reference
                let mix = tempTankMixRef.flatMap { gasMixes[$0] }
                let o2Percent = mix.map { Int(($0.o2 * 100).rounded()) }
                let hePercent = mix.map { Int(($0.he * 100).rounded()) }

                currentTanks.append(BlueDiveTankData(
                    id: nil,
                    oxygen: o2Percent,
                    helium: hePercent,
                    double: false,
                    volume: tempTankVolume.map { cubicMetresToLitres($0) },
                    startPressure: tempTankPressureBegin.map { pascalToBar($0) },
                    endPressure: tempTankPressureEnd.map { pascalToBar($0) },
                    workingPressure: nil,
                    tankMaterial: nil,
                    tankType: nil
                ))
                isInTankData = false
            }

        // --- Waypoint / Samples ---
        case "divetime":
            if isInWaypoint { tempWaypointTime = Double(text) }
        case "depth":
            if isInWaypoint { tempWaypointDepth = Double(text) }
        case "tankpressure":
            if isInWaypoint {
                if let pa = Double(text) { tempWaypointPressure = pascalToBar(pa) }
            }
        case "temperature":
            if isInWaypoint {
                if let k = Double(text) { tempWaypointTemperature = kelvinToCelsius(k) }
            }
        case "calculatedpo2":
            if isInWaypoint { tempWaypointPPO2 = Double(text) }
        case "nodecotime":
            // UDDF nodecotime is in seconds; convert to minutes for BlueDiveSamplesData.ndt
            if isInWaypoint, let seconds = parseSeconds(text), seconds > 0 {
                tempWaypointNDT = seconds / 60
            }
        case "cns":
            if isInWaypoint { tempWaypointCNS = Double(text) }

        case "waypoint":
            if isInWaypoint {
                if let time = tempWaypointTime, let depth = tempWaypointDepth {
                    currentSamples.append(BlueDiveSamplesData(
                        time: time,
                        depth: depth,
                        pressure: tempWaypointPressure,
                        temperature: tempWaypointTemperature,
                        ppo2: tempWaypointPPO2,
                        ndt: tempWaypointNDT
                    ))
                }
                // Track max CNS across all waypoints
                if let wCNS = tempWaypointCNS {
                    currentCNS = max(currentCNS ?? 0, wCNS)
                }
                isInWaypoint = false
            }

        case "samples":
            isInSamples = false

        // --- End of dive ---
        case "dive":
            if isInDive {
                finalizeDive()
                isInDive = false
            }

        default:
            break
        }

        currentText = ""
        if !elementStack.isEmpty { elementStack.removeLast() }
    }

    // MARK: - Link Handling

    private func handleLink(ref: String) {
        if isInRelatedDives {
            // Trip → dive association
            tempRelatedDiveIds.append(ref)
        } else if isInTankData {
            // Tank → gas mix reference
            tempTankMixRef = ref
        } else if isInInformationBeforeDive && !isInSurfaceIntervalBeforeDive {
            // Dive → site or buddy reference
            if sites.keys.contains(ref) || ref.lowercased().contains("site") {
                currentSiteRef = ref
            } else if buddyNames.keys.contains(ref) || ref.lowercased().contains("buddy") {
                currentBuddyRefs.append(ref)
            } else {
                // Try site first, then buddy (will be resolved at dive finalization)
                if currentSiteRef == nil {
                    // Could be a site ref — store tentatively
                    currentSiteRef = ref
                } else {
                    currentBuddyRefs.append(ref)
                }
            }
        } else if isInManufacturer && isInVariousPieces {
            // Manufacturer link — skip (we read inline name instead)
        }
    }

    // MARK: - Finalize Dive

    private func finalizeDive() {
        // Resolve site
        let site: BlueDiveSiteData?
        if let ref = currentSiteRef {
            site = sites[ref]
        } else {
            site = nil
        }

        // Resolve buddies
        var resolvedBuddies: [String] = []
        for ref in currentBuddyRefs {
            if let name = buddyNames[ref] {
                resolvedBuddies.append(name)
            }
        }

        // Resolve trip operator/vessel
        var diveOperator: String?
        var boat: String?
        if let diveId = currentDiveId, let partId = diveToTripPart[diveId] {
            let part = tripParts[partId]
            diveOperator = part?.operatorName
            boat = part?.vesselName
        }

        // Map purpose to dive types
        let types: [String]
        if let purpose = currentPurpose {
            types = [mapPurposeToType(purpose)]
        } else {
            types = []
        }

        // Determine if decompression dive (any waypoint with decostop would indicate,
        // but we don't track decostop — leave as false)
        let isDecompressionDive = false

        // Build notes from para elements
        let notes = currentNotes.isEmpty ? nil : currentNotes.joined(separator: "\n")

        // Surface interval: UDDF gives seconds, the app expects minutes for MacDive imports
        // but our insertDiveFromMacDive expects the surfaceInterval field in minutes
        // (MacDive exports surfaceInterval in minutes)
        let surfaceIntervalMinutes: Int?
        if let si = currentSurfaceInterval, si > 0 {
            surfaceIntervalMinutes = si / 60
        } else {
            surfaceIntervalMinutes = nil
        }

        dives.append(BlueDiveGlobalData(
            distanceFormat: "meters",
            temperatureFormat: "°c",
            pressureFormat: "bar",
            volumeFormat: "liters",
            weightFormat: "kg",
            sourceImport: "UDDF",
            date: currentDate,
            identifier: currentDiveId,
            diveNumber: currentDiveNumber,
            rating: currentRating,
            repetitiveDive: currentRepetitiveDive,
            diver: ownerName,
            computer: ownerComputer,
            serial: ownerComputerSerial,
            maxDepth: currentMaxDepth,
            averageDepth: currentAverageDepth,
            duration: currentDuration,
            interval: nil,
            cns: currentCNS,
            decoModel: decoModelName,
            isDecompressionDive: isDecompressionDive,
            tempAir: currentTempAir,
            tempHigh: nil,
            tempLow: currentTempLow,
            visibility: currentVisibility,
            weight: currentWeight,
            weather: nil,
            current: currentCurrent,
            surfaceConditions: nil,
            entryType: currentEntryType,
            diveMaster: nil,
            diveOperator: diveOperator,
            skipper: nil,
            boat: boat,
            surfaceInterval: surfaceIntervalMinutes,
            notes: notes,
            tags: nil,
            site: site,
            types: types,
            buddies: resolvedBuddies,
            gases: [],
            tanks: currentTanks,
            gear: ownerGear,
            samples: currentSamples,
            marineLifeSeen: [],
            decoStops: []
        ))
    }

    // MARK: - Unit Conversion Helpers

    /// Kelvin to Celsius
    private func kelvinToCelsius(_ k: Double) -> Double {
        k - 273.15
    }

    /// Pascal to bar
    private func pascalToBar(_ pa: Double) -> Double {
        pa / 100_000.0
    }

    /// Cubic metres to litres
    private func cubicMetresToLitres(_ m3: Double) -> Double {
        m3 * 1000.0
    }

    // MARK: - Date Parsing

    private func parseUDDFDate(_ text: String) -> Date? {
        // Try ISO 8601 with fractional seconds first
        if let date = iso8601Formatter.date(from: text) { return date }
        // Try ISO 8601 without fractional seconds
        if let date = iso8601FormatterNoFraction.date(from: text) { return date }
        // Try without timezone suffix (some exporters omit it)
        if let date = dateOnlyFormatter.date(from: text) { return date }
        return nil
    }

    // MARK: - Purpose Mapping

    private func mapPurposeToType(_ purpose: String) -> String {
        switch purpose.lowercased() {
        case "sightseeing":               return "Recreational"
        case "learning":                  return "Training"
        case "teaching":                  return "Training"
        case "research":                  return "Research"
        case "photography-videography":   return "Photography"
        case "spearfishing":              return "Spearfishing"
        case "proficiency":               return "Proficiency"
        case "work":                      return "Work"
        default:                          return purpose.capitalized
        }
    }

    // MARK: - Reset Helpers

    private func resetCurrentDive() {
        currentDiveId = nil
        currentDate = nil
        currentDiveNumber = nil
        currentRating = nil
        currentRepetitiveDive = nil
        currentMaxDepth = 0.0
        currentAverageDepth = nil
        currentDuration = 0
        currentCNS = nil
        currentTempAir = nil
        currentTempLow = nil
        currentVisibility = nil
        currentWeight = nil
        currentCurrent = nil
        currentEntryType = nil
        currentPurpose = nil
        currentSurfaceInterval = nil
        currentNotes = []
        currentSiteRef = nil
        currentBuddyRefs = []
        currentSamples = []
        currentTanks = []
        isInInformationBeforeDive = false
        isInInformationAfterDive = false
        isInSamples = false
        isInEquipmentUsed = false
    }

    private func resetTempSite() {
        tempSiteName = nil
        tempSiteLocation = nil
        tempSiteCountry = nil
        tempSiteEnvironment = nil
        tempSiteDifficulty = nil
        tempSiteAltitude = nil
        tempSiteLatitude = nil
        tempSiteLongitude = nil
    }

    private func resetTempWaypoint() {
        tempWaypointTime = nil
        tempWaypointDepth = nil
        tempWaypointPressure = nil
        tempWaypointTemperature = nil
        tempWaypointPPO2 = nil
        tempWaypointNDT = nil
        tempWaypointCNS = nil
    }

    // MARK: - Parsing Utilities

    private func parseSeconds(_ text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        if let intValue = Int(text) { return intValue }
        if let doubleValue = Double(text) { return Int(doubleValue) }
        return nil
    }
}

// MARK: - String Helper

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
