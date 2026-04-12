import Foundation

// MARK: - XML Parser
// Parses XML files produced by the DiveBlue app's own XMLExportTabView.
// The root element is <diveBlueExport> and each dive lives inside a <dive> element.
//
// Shared data structs (BlueDiveGlobalData, BlueDiveSiteData, BlueDiveGasData,
// BlueDiveGearData, BlueDiveSamplesData) are defined in MacDiveXMLParser.swift
// and reused here to avoid duplicate model properties.

final class BlueDiveXMLParser: NSObject, XMLParserDelegate {

    // MARK: - Public Result

    private(set) var dives: [BlueDiveGlobalData] = []

    // MARK: - Import Format Settings (injected before parsing)

    var distanceFormat: String = ""
    var temperatureFormat: String = ""
    var pressureFormat: String = ""
    var volumeFormat: String = ""
    var weightFormat: String = "kg"
    var importGear: Bool = true

    // MARK: - Current Dive State

    private var currentDate: Date?
    private var currentIdentifier: String?
    private var currentDiveNumber: Int?
    private var currentRating: Int?
    private var currentRepetitiveDive: Int?
    private var currentDiver: String?
    private var currentComputer: String?
    private var currentSerial: String?
    private var currentMaxDepth: Double = 0.0
    private var currentAverageDepth: Double?
    private var currentDuration: Int = 0
    private var currentInterval: Int?
    private var currentCNS: Double?
    private var currentDecoModel: String?
    private var currentDecompressionDive: Bool = false
    private var currentTempAir: Double?
    private var currentTempHigh: Double?
    private var currentTempLow: Double?
    private var currentVisibility: String?
    private var currentWeight: Double?
    private var currentWeather: String?
    private var currentCurrent: String?
    private var currentSurfaceConditions: String?
    private var currentEntryType: String?
    private var currentDiveMaster: String?
    private var currentDiveOperator: String?
    private var currentSkipper: String?
    private var currentBoat: String?
    private var currentSurfaceInterval: Int?
    private var currentNotes: String?
    private var currentTags: String?
    private var currentSourceImport: String?
    private var currentSite: BlueDiveSiteData?
    private var currentTypes: [String] = []
    private var currentBuddies: [String] = []
    private var currentGases: [BlueDiveGasData] = []
    private var currentTanks: [BlueDiveTankData] = []
    private var currentGear: [BlueDiveGearData] = []
    private var currentSamples: [BlueDiveSamplesData] = []
    private var currentMarineLife: [BlueDiveMarineLifeData] = []
    private var currentDecoStops: [DecoStop] = []

    // MARK: - Parser Context Flags

    private var currentElement = ""
    private var currentText = ""
    private var isInDive = false
    private var isInSite = false
    private var isInGas = false
    private var isInTanks = false
    private var isInTank = false
    private var isInGearItem = false
    private var isInProfileSamples = false
    private var isInTypes = false
    private var isInBuddies = false
    private var isInGear = false
    private var isInMetadata = false
    private var isInMarineLifeSeen = false
    private var isInMarineLife = false
    private var isInDecoStops = false

    // MARK: - Temporary Site State

    private var tempSiteName: String?
    private var tempSiteLocation: String?
    private var tempSiteCountry: String?
    private var tempSiteBodyOfWater: String?
    private var tempSiteWaterType: String?
    private var tempSiteDifficulty: String?
    private var tempSiteAltitude: Double?
    private var tempSiteLatitude: Double?
    private var tempSiteLongitude: Double?

    // MARK: - Temporary Gas State

    private var tempGasPressureStart: Double?
    private var tempGasPressureEnd: Double?
    private var tempGasOxygen: Int?
    private var tempGasHelium: Int?
    private var tempGasTankSize: Double?
    private var tempGasWorkingPressure: Double?
    private var tempGasSupplyType: String?
    private var tempGasDuration: Int?
    private var tempGasTankName: String?
    private var tempGasTankMaterial: String?
    private var tempGasTankType: String?

    // MARK: - Temporary Tank State

    private var tempTankID: String?
    private var tempTankOxygen: Int?
    private var tempTankHelium: Int?
    private var tempTankVolume: Double?
    private var tempTankStartPressure: Double?
    private var tempTankEndPressure: Double?
    private var tempTankWorkingPressure: Double?
    private var tempTankMaterial: String?
    private var tempTankType: String?

    // MARK: - Temporary Gear State

    private var tempGearType: String?
    private var tempGearManufacturer: String?
    private var tempGearModel: String?
    private var tempGearName: String?
    private var tempGearSerial: String?
    private var tempGearDatePurchased: Date?
    private var tempGearPurchasePrice: Double?
    private var tempGearCurrency: String?
    private var tempGearPurchasedFrom: String?
    private var tempGearWeightContribution: Double?
    private var tempGearWeightContributionUnit: String?
    private var tempGearNextServiceDue: Date?
    private var tempGearServiceHistory: String?
    private var tempGearNotes: String?
    private var tempGearIsInactive: Bool = false

    // MARK: - Temporary Marine Life State

    private var tempMarineLifeName: String?
    private var tempMarineLifeCount: Int?

    // MARK: - Date Formatter

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    // MARK: - Public API

    func parse(data: Data) -> [BlueDiveGlobalData]? {
        let parser = XMLParser(data: data)
        parser.delegate = self
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
        currentElement = elementName
        currentText = ""

        switch elementName {
        case "dive":
            isInDive = true
            resetCurrentDive()
        case "metadata":
            isInMetadata = true
        case "site":
            isInSite = true
            resetTempSite()
        case "gas":
            isInGas = true
            resetTempGas()
        case "tanks":
            isInTanks = true
        case "tank" where isInTanks:
            isInTank = true
            resetTempTank()
        case "gear":
            isInGear = true
        case "item":
            if importGear {
                isInGearItem = true
                resetTempGear()
            }
        case "profileSamples":
            isInProfileSamples = true
        case "sample" where isInProfileSamples:
            // DiveBlue exports samples as self-closing attribute tags:
            // <sample time="..." depth="..." temperature="..." tankPressure="..." ppo2="..." ndl="..."/>
            parseSampleAttributes(attributeDict)
        case "types":
            isInTypes = true
        case "buddies":
            isInBuddies = true
        case "marineLifeSeen", "fishSeen":
            isInMarineLifeSeen = true
        case "marineLife" where isInMarineLifeSeen,
             "fish" where isInMarineLifeSeen:
            isInMarineLife = true
            resetTempMarineLife()
        case "decoStops":
            isInDecoStops = true
        case "decoStop" where isInDecoStops:
            if let depthStr = attributeDict["depth"], let depth = Double(depthStr),
               let timeStr  = attributeDict["time"],  let time  = Double(timeStr),
               let typeStr  = attributeDict["type"],  let type  = Int(typeStr) {
                currentDecoStops.append(DecoStop(depth: depth, time: TimeInterval(time), type: type))
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

        // Metadata block — skip, not stored in dive model
        if isInMetadata {
            if elementName == "metadata" { isInMetadata = false }
            currentText = ""
            return
        }

        if isInSite {
            parseSiteElement(elementName, text: text)
        } else if isInGas {
            parseGasElement(elementName, text: text)
        } else if isInTank {
            parseTankElement(elementName, text: text)
        } else if isInTanks {
            if elementName == "tanks" { isInTanks = false }
        } else if isInGearItem {
            parseGearElement(elementName, text: text)
        } else if isInGear {
            if elementName == "gear" { isInGear = false }
        } else if isInProfileSamples {
            if elementName == "profileSamples" { isInProfileSamples = false }
        } else if isInTypes {
            parseTypesElement(elementName, text: text)
        } else if isInBuddies {
            parseBuddiesElement(elementName, text: text)
        } else if isInMarineLife {
            parseMarineLifeElement(elementName, text: text)
        } else if isInMarineLifeSeen {
            if elementName == "marineLifeSeen" || elementName == "fishSeen" { isInMarineLifeSeen = false }
        } else if isInDecoStops {
            if elementName == "decoStops" { isInDecoStops = false }
        } else if isInDive {
            parseDiveElement(elementName, text: text)
        }

        currentText = ""
    }

    // MARK: - Element Parsing Helpers

    private func parseSiteElement(_ elementName: String, text: String) {
        switch elementName {
        case "name":        tempSiteName = text.nilIfEmpty
        case "location":    tempSiteLocation = text.nilIfEmpty
        case "country":     tempSiteCountry = text.nilIfEmpty
        case "bodyOfWater": tempSiteBodyOfWater = text.nilIfEmpty
        case "waterType":   tempSiteWaterType = text.nilIfEmpty
        case "difficulty":  tempSiteDifficulty = text.nilIfEmpty
        case "altitude":    tempSiteAltitude = Double(text)
        case "lat":         tempSiteLatitude = Double(text)
        case "lon":         tempSiteLongitude = Double(text)
        case "site":
            currentSite = BlueDiveSiteData(
                name: tempSiteName ?? "",
                location: tempSiteLocation,
                country: tempSiteCountry,
                bodyOfWater: tempSiteBodyOfWater,
                waterType: tempSiteWaterType,
                difficulty: tempSiteDifficulty,
                altitude: tempSiteAltitude,
                latitude: tempSiteLatitude,
                longitude: tempSiteLongitude
            )
            isInSite = false
        default: break
        }
    }

    private func parseGasElement(_ elementName: String, text: String) {
        switch elementName {
        case "pressureStart":   tempGasPressureStart = Double(text)
        case "pressureEnd":     tempGasPressureEnd = Double(text)
        case "oxygen":          tempGasOxygen = Int(text)
        case "helium":          tempGasHelium = Int(text)
        case "tankSize":        tempGasTankSize = Double(text)
        case "workingPressure": tempGasWorkingPressure = Double(text)
        case "supplyType":      tempGasSupplyType = text.nilIfEmpty
        case "duration":        tempGasDuration = parseSeconds(text)
        case "tankName":        tempGasTankName = text.nilIfEmpty
        case "tankMaterial":    tempGasTankMaterial = text.nilIfEmpty
        case "tankType":        tempGasTankType = text.nilIfEmpty
        case "gas":
            let gasIsDouble = tempGasTankType?.lowercased().contains("twin") == true
            currentGases.append(BlueDiveGasData(
                pressureStart: tempGasPressureStart,
                pressureEnd: tempGasPressureEnd,
                oxygen: tempGasOxygen,
                helium: tempGasHelium,
                double: gasIsDouble,
                tankSize: tempGasTankSize,
                workingPressure: tempGasWorkingPressure,
                supplyType: tempGasSupplyType,
                duration: tempGasDuration,
                tankName: tempGasTankName,
                tankMaterial: tempGasTankMaterial,
                tankType: tempGasTankType
            ))
            isInGas = false
        default: break
        }
    }

    private func parseTankElement(_ elementName: String, text: String) {
        switch elementName {
        case "id":              tempTankID = text.nilIfEmpty
        case "oxygen":          tempTankOxygen = Int(text)
        case "helium":          tempTankHelium = Int(text)
        case "volume":          tempTankVolume = Double(text)
        case "startPressure":   tempTankStartPressure = Double(text)
        case "endPressure":     tempTankEndPressure = Double(text)
        case "workingPressure": tempTankWorkingPressure = Double(text)
        case "tankMaterial":    tempTankMaterial = text.nilIfEmpty
        case "tankType":        tempTankType = text.nilIfEmpty
        case "tank":
            let tankIsDouble = tempTankType?.lowercased().contains("twin") == true
            currentTanks.append(BlueDiveTankData(
                id: tempTankID,
                oxygen: tempTankOxygen,
                helium: tempTankHelium,
                double: tankIsDouble,
                volume: tempTankVolume,
                startPressure: tempTankStartPressure,
                endPressure: tempTankEndPressure,
                workingPressure: tempTankWorkingPressure,
                tankMaterial: tempTankMaterial,
                tankType: tempTankType
            ))
            isInTank = false
        default: break
        }
    }

    private func parseGearElement(_ elementName: String, text: String) {
        switch elementName {
        case "type":               tempGearType = text.nilIfEmpty
        case "manufacturer":       tempGearManufacturer = text.nilIfEmpty
        case "model":              tempGearModel = text.nilIfEmpty
        case "name":               tempGearName = text.nilIfEmpty
        case "serial":             tempGearSerial = text.nilIfEmpty
        case "datePurchased":      tempGearDatePurchased = dateFormatter.date(from: text)
        case "purchasePrice":      tempGearPurchasePrice = Double(text)
        case "currency":           tempGearCurrency = text.nilIfEmpty
        case "purchasedFrom":      tempGearPurchasedFrom = text.nilIfEmpty
        case "weightContribution":     tempGearWeightContribution = Double(text)
        case "weightContributionUnit": tempGearWeightContributionUnit = text.nilIfEmpty
        case "nextServiceDue":          tempGearNextServiceDue = dateFormatter.date(from: text)
        case "serviceHistory":     tempGearServiceHistory = text.nilIfEmpty
        case "gearNotes":          tempGearNotes = text.nilIfEmpty
        case "isInactive":         tempGearIsInactive = (text.lowercased() == "true")
        case "item":
            if let name = tempGearName {
                currentGear.append(BlueDiveGearData(
                    type: tempGearType,
                    manufacturer: tempGearManufacturer,
                    model: tempGearModel,
                    name: name,
                    serial: tempGearSerial,
                    datePurchased: tempGearDatePurchased,
                    purchasePrice: tempGearPurchasePrice,
                    currency: tempGearCurrency,
                    purchasedFrom: tempGearPurchasedFrom,
                    weightContribution: tempGearWeightContribution,
                    weightContributionUnit: tempGearWeightContributionUnit,
                    nextServiceDue: tempGearNextServiceDue,
                    serviceHistory: tempGearServiceHistory,
                    gearNotes: tempGearNotes,
                    isInactive: tempGearIsInactive
                ))
            }
            isInGearItem = false
        default: break
        }
    }

    /// Handles the self-closing <sample .../> attribute format used by DiveBlue exports.
    /// Attribute names: time, depth, temperature, tankPressure, ppo2, ndl, events
    /// Note: `time` is stored in minutes (fractional) in the export;
    ///       `BlueDiveSamplesData.time` expects seconds, so we convert here.
    private func parseSampleAttributes(_ attributes: [String: String]) {
        guard
            let timeStr = attributes["time"], let timeMinutes = Double(timeStr),
            let depthStr = attributes["depth"], let depth = Double(depthStr)
        else { return }

        let timeSeconds = timeMinutes
        let temperature = attributes["temperature"].flatMap(Double.init)
        // The export key is "tankPressure"; BlueDiveSamplesData maps it to `pressure`
        let pressure    = attributes["tankPressure"].flatMap(Double.init)
        let ppo2        = attributes["ppo2"].flatMap(Double.init)
        let ndt         = attributes["ndl"].flatMap(Double.init).map(Int.init)
        let events: [DiveProfileEvent]
        if let eventsStr = attributes["events"], !eventsStr.isEmpty {
            events = eventsStr.split(separator: ",").compactMap { parseEvent(String($0)) }
        } else {
            events = []
        }

        currentSamples.append(BlueDiveSamplesData(
            time: timeSeconds,
            depth: depth,
            pressure: pressure,
            temperature: temperature,
            ppo2: ppo2,
            ndt: ndt,
            events: events
        ))
    }

    private func parseEvent(_ raw: String) -> DiveProfileEvent? {
        switch raw {
        case "ascent":       return .ascent
        case "violation":    return .violation
        case "decoStop":     return .decoStop
        case "gasChange":    return .gasChange
        case "bookmark":     return .bookmark
        case "safetyStop:1": return .safetyStop(true)
        case "safetyStop:0": return .safetyStop(false)
        case "ceiling":      return .ceiling
        case "po2":          return .po2
        case "deepStop":     return .deepStop
        default:             return nil
        }
    }

    private func parseTypesElement(_ elementName: String, text: String) {
        switch elementName {
        case "type":
            if !text.isEmpty { currentTypes.append(text) }
        case "types":
            isInTypes = false
        default: break
        }
    }

    private func parseBuddiesElement(_ elementName: String, text: String) {
        switch elementName {
        case "buddy":
            if !text.isEmpty { currentBuddies.append(text) }
        case "buddies":
            isInBuddies = false
        default: break
        }
    }

    private func parseMarineLifeElement(_ elementName: String, text: String) {
        switch elementName {
        case "name":
            tempMarineLifeName = text.nilIfEmpty
        case "count":
            tempMarineLifeCount = Int(text)
        case "marineLife", "fish":
            if let name = tempMarineLifeName {
                currentMarineLife.append(BlueDiveMarineLifeData(
                    name: name,
                    count: tempMarineLifeCount ?? 1
                ))
            }
            isInMarineLife = false
        default: break
        }
    }

    private func parseDiveElement(_ elementName: String, text: String) {
        switch elementName {
        case "date":             currentDate = dateFormatter.date(from: text)
        case "identifier":       currentIdentifier = text.nilIfEmpty
        case "diveNumber":       currentDiveNumber = Int(text)
        case "rating":           currentRating = Int(text)
        case "repetitiveDive":   currentRepetitiveDive = Int(text)
        case "diver":            currentDiver = text.nilIfEmpty
        case "computer":         currentComputer = text.nilIfEmpty
        case "serial":           currentSerial = text.nilIfEmpty
        case "maxDepth":         currentMaxDepth = Double(text) ?? 0.0
        case "averageDepth":     currentAverageDepth = Double(text)
        case "duration":         currentDuration = parseSeconds(text) ?? 0
        case "surfaceInterval":  currentSurfaceInterval = parseSeconds(text) ?? 0
        case "cns":              currentCNS = Double(text)
        case "decoModel":        currentDecoModel = text.nilIfEmpty
        case "decompressionDive": currentDecompressionDive = (text == "1" || text.lowercased() == "true")
        case "tempAir":          currentTempAir = Double(text)
        case "tempHigh":         currentTempHigh = Double(text)
        case "tempLow":          currentTempLow = Double(text)
        case "visibility":       currentVisibility = text.nilIfEmpty
        case "weight":           currentWeight = Double(text)
        case "weather":          currentWeather = text.nilIfEmpty
        case "current":          currentCurrent = text.nilIfEmpty
        case "surfaceConditions": currentSurfaceConditions = text.nilIfEmpty
        case "entryType":        currentEntryType = text.nilIfEmpty
        case "diveMaster":       currentDiveMaster = text.nilIfEmpty
        case "diveOperator":     currentDiveOperator = text.nilIfEmpty
        case "skipper":          currentSkipper = text.nilIfEmpty
        case "boat":             currentBoat = text.nilIfEmpty
        case "notes":            currentNotes = text.nilIfEmpty
        case "tags":             currentTags = text.nilIfEmpty
        case "sourceImport":     currentSourceImport = text.nilIfEmpty
        // Unit format metadata (written by exporter, re-read for round-trip fidelity)
        case "distanceFormat":    distanceFormat    = text.nilIfEmpty ?? distanceFormat
        case "temperatureFormat": temperatureFormat = text.nilIfEmpty ?? temperatureFormat
        case "pressureFormat":    pressureFormat    = text.nilIfEmpty ?? pressureFormat
        case "volumeFormat":      volumeFormat      = text.nilIfEmpty ?? volumeFormat
        case "weightFormat":      weightFormat      = text.nilIfEmpty ?? weightFormat
        case "dive":
            dives.append(BlueDiveGlobalData(
                distanceFormat: distanceFormat,
                temperatureFormat: temperatureFormat,
                pressureFormat: pressureFormat,
                volumeFormat: volumeFormat,
                weightFormat: weightFormat,
                sourceImport: "BlueDive",
                date: currentDate,
                identifier: currentIdentifier,
                diveNumber: currentDiveNumber,
                rating: currentRating,
                repetitiveDive: currentRepetitiveDive,
                diver: currentDiver,
                computer: currentComputer,
                serial: currentSerial,
                maxDepth: currentMaxDepth,
                averageDepth: currentAverageDepth,
                duration: currentDuration,
                interval: currentInterval,
                cns: currentCNS,
                decoModel: currentDecoModel,
                isDecompressionDive: currentDecompressionDive,
                tempAir: currentTempAir,
                tempHigh: currentTempHigh,
                tempLow: currentTempLow,
                visibility: currentVisibility,
                weight: currentWeight,
                weather: currentWeather,
                current: currentCurrent,
                surfaceConditions: currentSurfaceConditions,
                entryType: currentEntryType,
                diveMaster: currentDiveMaster,
                diveOperator: currentDiveOperator,
                skipper: currentSkipper,
                boat: currentBoat,
                surfaceInterval: currentSurfaceInterval,
                notes: currentNotes,
                tags: currentTags,
                site: currentSite,
                types: currentTypes,
                buddies: currentBuddies,
                gases: currentGases,
                tanks: currentTanks,
                gear: currentGear,
                samples: currentSamples,
                marineLifeSeen: currentMarineLife,
                decoStops: currentDecoStops
            ))
            isInDive = false
        default: break
        }
    }

    // MARK: - Reset Helpers

    private func resetCurrentDive() {
        currentDate = nil
        currentIdentifier = nil
        currentDiveNumber = nil
        currentRating = nil
        currentRepetitiveDive = nil
        currentDiver = nil
        currentComputer = nil
        currentSerial = nil
        currentMaxDepth = 0.0
        currentAverageDepth = nil
        currentDuration = 0
        currentInterval = nil
        currentCNS = nil
        currentDecoModel = nil
        currentDecompressionDive = false
        currentTempAir = nil
        currentTempHigh = nil
        currentTempLow = nil
        currentVisibility = nil
        currentWeight = nil
        currentWeather = nil
        currentCurrent = nil
        currentSurfaceConditions = nil
        currentEntryType = nil
        currentDiveMaster = nil
        currentDiveOperator = nil
        currentSkipper = nil
        currentBoat = nil
        currentSurfaceInterval = nil
        currentNotes = nil
        currentTags = nil
        currentSourceImport = nil
        currentSite = nil
        currentTypes = []
        currentBuddies = []
        currentGases = []
        currentTanks = []
        currentGear = []
        currentSamples = []
        currentMarineLife = []
        currentDecoStops = []
    }

    private func resetTempSite() {
        tempSiteName = nil
        tempSiteLocation = nil
        tempSiteCountry = nil
        tempSiteBodyOfWater = nil
        tempSiteWaterType = nil
        tempSiteDifficulty = nil
        tempSiteAltitude = nil
        tempSiteLatitude = nil
        tempSiteLongitude = nil
    }

    private func resetTempGas() {
        tempGasPressureStart = nil
        tempGasPressureEnd = nil
        tempGasOxygen = nil
        tempGasHelium = nil
        tempGasTankSize = nil
        tempGasWorkingPressure = nil
        tempGasSupplyType = nil
        tempGasDuration = nil
        tempGasTankName = nil
        tempGasTankMaterial = nil
        tempGasTankType = nil
    }

    private func resetTempTank() {
        tempTankID = nil
        tempTankOxygen = nil
        tempTankHelium = nil
        tempTankVolume = nil
        tempTankStartPressure = nil
        tempTankEndPressure = nil
        tempTankWorkingPressure = nil
        tempTankMaterial = nil
        tempTankType = nil
    }

    private func resetTempGear() {
        tempGearType = nil
        tempGearManufacturer = nil
        tempGearModel = nil
        tempGearName = nil
        tempGearSerial = nil
        tempGearDatePurchased = nil
        tempGearPurchasePrice = nil
        tempGearCurrency = nil
        tempGearPurchasedFrom = nil
        tempGearWeightContribution = nil
        tempGearWeightContributionUnit = nil
        tempGearNextServiceDue = nil
        tempGearServiceHistory = nil
        tempGearNotes = nil
        tempGearIsInactive = false
    }

    private func resetTempMarineLife() {
        tempMarineLifeName = nil
        tempMarineLifeCount = nil
    }

    // MARK: - Parsing Utilities

    /// Robustly parses an integer number of seconds from a string.
    /// Handles both integer ("3600") and decimal ("3600.0") representations.
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
