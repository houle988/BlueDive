import Foundation

// MARK: - Data Models

/// Global dive data parsed from a MacDive XML export
struct BlueDiveGlobalData: Sendable {
    // MARK: Units (set during import)
    let distanceFormat: String      // meters or feet - To request at import
    let temperatureFormat: String   // °C or °F or °K - To request at import
    let pressureFormat: String      // bar or PSI or Pa - To request at import
    let volumeFormat: String        // liters or Cubic Feet - To request at import
    let weightFormat: String        // kg or lb - To request at import

    // MARK: Import Source
    let sourceImport: String?         // "Bluetooth", "MacDive", or "BlueDive"

    // MARK: Basic Info
    let date: Date?
    let identifier: String?
    let diveNumber: Int?
    let rating: Int?
    let repetitiveDive: Int?
    let diver: String?
    let computer: String?
    let serial: String?

    // MARK: Dive Stats
    let maxDepth: Double           // meters or feet
    let averageDepth: Double?      // meters or feet
    let duration: Int              // seconds
    let interval: Int?

    // MARK: Decompression
    let cns: Double?
    let decoModel: String?
    let isDecompressionDive: Bool

    // MARK: Temperatures
    let tempAir: Double?           // °C or °F or °K
    let tempHigh: Double?          // °C or °F or °K
    let tempLow: Double?           // °C or °F or °K

    // MARK: Conditions
    let visibility: String?
    let weight: Double?
    let weather: String?
    let current: String?
    let surfaceConditions: String?
    let entryType: String?

    // MARK: Operator
    let diveMaster: String?
    let diveOperator: String?
    let skipper: String?
    let boat: String?

    // MARK: Surface Interval
    let surfaceInterval: Int?      // seconds

    // MARK: Notes & Tags
    let notes: String?
    let tags: String?

    // MARK: Related Data
    let site: BlueDiveSiteData?
    let types: [String]
    let buddies: [String]
    let gases: [BlueDiveGasData]
    let tanks: [BlueDiveTankData]      // New: multi-tank support
    let gear: [BlueDiveGearData]
    let samples: [BlueDiveSamplesData]
    let marineLifeSeen: [BlueDiveMarineLifeData]
    let decoStops: [DecoStop]
}

/// Dive site data
struct BlueDiveSiteData: Sendable {
    let name: String               // mandatory
    let location: String?
    let country: String?
    let bodyOfWater: String?
    let waterType: String?
    let difficulty: String?
    let altitude: Double?          // meters or feet
    let latitude: Double?          // degrees GPS
    let longitude: Double?         // degrees GPS
}

/// Gas / tank data (legacy single-tank format for backward compatibility)
struct BlueDiveGasData: Sendable {
    let pressureStart: Double?     // bar or PSI or Pa
    let pressureEnd: Double?       // bar or PSI or Pa
    let oxygen: Int?               // %
    let helium: Int?               // %
    let double: Bool               // mandatory, default false
    let tankSize: Double?          // liters or Cubic Feet
    let workingPressure: Double?   // bar or PSI or Pa
    let supplyType: String?
    let duration: Int?             // seconds
    let tankName: String?
    let tankMaterial: String?      // Material (Steel, Aluminum, etc.)
    let tankType: String?          // Type/Format (Mono, Double, Sidemount, etc.)
}

/// Tank data (new multi-tank format)
struct BlueDiveTankData: Sendable {
    let id: String?                // UUID string
    let oxygen: Int?               // O₂ percentage
    let helium: Int?               // He percentage
    let double: Bool               // Double tank configuration
    let volume: Double?            // Tank volume in liters or cubic feet
    let startPressure: Double?     // Starting pressure in bar/PSI/Pa
    let endPressure: Double?       // Ending pressure in bar/PSI/Pa
    let workingPressure: Double?   // Working pressure in bar/PSI/Pa
    let tankMaterial: String?      // Material (Steel, Aluminum, etc.)
    let tankType: String?          // Type/Format (Single, Double, Sidemount, etc.)
    let usageStartTime: Double?    // Seconds into dive when tank usage started
    let usageEndTime: Double?      // Seconds into dive when tank usage ended

    init(id: String? = nil, oxygen: Int? = nil, helium: Int? = nil, double: Bool = false,
         volume: Double? = nil, startPressure: Double? = nil, endPressure: Double? = nil,
         workingPressure: Double? = nil, tankMaterial: String? = nil, tankType: String? = nil,
         usageStartTime: Double? = nil, usageEndTime: Double? = nil) {
        self.id = id
        self.oxygen = oxygen
        self.helium = helium
        self.double = double
        self.volume = volume
        self.startPressure = startPressure
        self.endPressure = endPressure
        self.workingPressure = workingPressure
        self.tankMaterial = tankMaterial
        self.tankType = tankType
        self.usageStartTime = usageStartTime
        self.usageEndTime = usageEndTime
    }
}

/// Gear / equipment item
struct BlueDiveGearData: Sendable {
    let type: String?
    let manufacturer: String?
    let model: String?
    let name: String               // mandatory
    let serial: String?
    let datePurchased: Date?
    let purchasePrice: Double?
    let currency: String?
    let purchasedFrom: String?
    let weightContribution: Double?
    let weightContributionUnit: String?
    let nextServiceDue: Date?
    let serviceHistory: String?
    let gearNotes: String?
    let isInactive: Bool
}

/// Profile sample data
struct BlueDiveSamplesData: Sendable {
    let time: Double               // seconds (mandatory)
    let depth: Double              // meters or feet (mandatory)
    let pressure: Double?          // bar or PSI or Pa
    let tankPressures: [Int: Double]? // Per-tank pressure readings {tankIndex: bar}
    let temperature: Double?       // °C or °F or °K
    let ppo2: Double?
    let ndt: Int?
    let events: [DiveProfileEvent]

    init(time: Double, depth: Double, pressure: Double? = nil, tankPressures: [Int: Double]? = nil, temperature: Double? = nil, ppo2: Double? = nil, ndt: Int? = nil, events: [DiveProfileEvent] = []) {
        self.time = time
        self.depth = depth
        self.pressure = pressure
        self.tankPressures = tankPressures
        self.temperature = temperature
        self.ppo2 = ppo2
        self.ndt = ndt
        self.events = events
    }
}

/// Marine life sighting data
struct BlueDiveMarineLifeData: Sendable {
    let name: String               // mandatory
    let count: Int                 // mandatory
}

// MARK: - XML Parser

final class MacDiveXMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {

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
    private var currentSite: BlueDiveSiteData?
    private var currentTypes: [String] = []
    private var currentBuddies: [String] = []
    private var currentGases: [BlueDiveGasData] = []
    private var currentGear: [BlueDiveGearData] = []
    private var currentSamples: [BlueDiveSamplesData] = []
    // Marine life data is NOT imported from MacDive XML (per CSV mapping)
    // private var currentMarineLifeSeen: [BlueDiveMarineLifeData] = []

    // MARK: - Parser Context Flags

    private var currentElement = ""
    private var currentText = ""
    private var isInDive = false
    private var isInSite = false
    private var isInGas = false
    private var isInGearItem = false
    private var isInSample = false
    private var isInTypes = false
    private var isInBuddies = false
    // Fish parsing is NOT imported from MacDive XML (per CSV mapping)
    // private var isInFish = false

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
    private var tempGasDouble: Bool = false
    private var tempGasTankSize: Double?
    private var tempGasWorkingPressure: Double?
    private var tempGasSupplyType: String?
    private var tempGasDuration: Int?
    private var tempGasTankName: String?
    // tankMaterial and tankType NOT imported from MacDive XML (per CSV mapping)
    // private var tempGasTankMaterial: String?
    // private var tempGasTankType: String?

    // MARK: - Temporary Gear State

    private var tempGearType: String?
    private var tempGearManufacturer: String?
    private var tempGearName: String?
    private var tempGearSerial: String?

    // MARK: - Temporary Sample State

    private var tempSampleTime: Double?
    private var tempSampleDepth: Double?
    private var tempSamplePressure: Double?
    private var tempSampleTemperature: Double?
    private var tempSamplePPO2: Double?
    private var tempSampleNDT: Int?

    // Fish parsing is NOT imported from MacDive XML (per CSV mapping)
    // MARK: - Temporary Fish State (NOT USED)
    // private var tempFishName: String?
    // private var tempFishCount: Int?

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
        case "site":
            isInSite = true
            resetTempSite()
        case "gas":
            isInGas = true
            resetTempGas()
        case "item":
            if importGear {
                isInGearItem = true
                resetTempGear()
            }
        case "sample":
            isInSample = true
            resetTempSample()
        case "types":
            isInTypes = true
        case "buddies":
            isInBuddies = true
        // Fish parsing is NOT imported from MacDive XML (per CSV mapping)
        // case "fish":
        //     isInFish = true
        //     resetTempFish()
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

        if isInSite {
            parseSiteElement(elementName, text: text)
        } else if isInGas {
            parseGasElement(elementName, text: text)
        } else if isInGearItem {
            parseGearElement(elementName, text: text)
        } else if isInSample {
            parseSampleElement(elementName, text: text)
        // Fish parsing is NOT imported from MacDive XML (per CSV mapping)
        // } else if isInFish {
        //     parseFishElement(elementName, text: text)
        } else if isInTypes {
            parseTypesElement(elementName, text: text)
        } else if isInBuddies {
            parseBuddiesElement(elementName, text: text)
        } else if isInDive {
            parseDiveElement(elementName, text: text)
        }

        currentText = ""
    }

    // MARK: - Element Parsing Helpers

    private func parseSiteElement(_ elementName: String, text: String) {
        switch elementName {
        case "name":       tempSiteName = text
        case "location":   tempSiteLocation = text.nilIfEmpty
        case "country":    tempSiteCountry = text.nilIfEmpty
        case "bodyOfWater": tempSiteBodyOfWater = text.nilIfEmpty
        case "waterType":  tempSiteWaterType = text.nilIfEmpty
        case "difficulty": tempSiteDifficulty = text.nilIfEmpty
        case "altitude":   tempSiteAltitude = Double(text)
        case "lat":        tempSiteLatitude = Double(text)
        case "lon":        tempSiteLongitude = Double(text)
        case "site":
            if let name = tempSiteName {
                currentSite = BlueDiveSiteData(
                    name: name,
                    location: tempSiteLocation,
                    country: tempSiteCountry,
                    bodyOfWater: tempSiteBodyOfWater,
                    waterType: tempSiteWaterType,
                    difficulty: tempSiteDifficulty,
                    altitude: tempSiteAltitude,
                    latitude: tempSiteLatitude,
                    longitude: tempSiteLongitude
                )
            }
            isInSite = false
        default: break
        }
    }

    private func parseGasElement(_ elementName: String, text: String) {
        switch elementName {
        case "pressureStart":    tempGasPressureStart = Double(text)
        case "pressureEnd":      tempGasPressureEnd = Double(text)
        case "oxygen":           tempGasOxygen = Int(text)
        case "helium":           tempGasHelium = Int(text)
        case "double":           tempGasDouble = (text == "1" || text.lowercased() == "true")
        case "tankSize":         tempGasTankSize = Double(text)
        case "workingPressure":  tempGasWorkingPressure = Double(text)
        case "supplyType":       tempGasSupplyType = text.nilIfEmpty
        case "duration":         tempGasDuration = Int(text)
        case "tankName":         tempGasTankName = text.nilIfEmpty
        // tankMaterial and tankType are NOT imported from MacDive XML (per CSV mapping)
        // case "tankMaterial":     tempGasTankMaterial = text.nilIfEmpty
        // case "tankType":         tempGasTankType = text.nilIfEmpty
        case "gas":
            currentGases.append(BlueDiveGasData(
                pressureStart: tempGasPressureStart,
                pressureEnd: tempGasPressureEnd,
                oxygen: tempGasOxygen,
                helium: tempGasHelium,
                double: tempGasDouble,
                tankSize: tempGasTankSize,
                workingPressure: tempGasWorkingPressure,
                supplyType: tempGasSupplyType,
                duration: tempGasDuration,
                tankName: tempGasTankName,
                tankMaterial: nil,  // NOT imported from MacDive
                tankType: nil       // NOT imported from MacDive
            ))
            isInGas = false
        default: break
        }
    }

    private func parseGearElement(_ elementName: String, text: String) {
        switch elementName {
        case "type":         tempGearType = text.nilIfEmpty
        case "manufacturer": tempGearManufacturer = text.nilIfEmpty
        case "name":         tempGearName = text
        case "serial":       tempGearSerial = text.nilIfEmpty
        // The following fields are NOT imported from MacDive XML (per CSV mapping):
        // datePurchased, purchasePrice, currency, purchaseFrom, weightContribution,
        // nextServiceDue, serviceHistory, gearNotes
        case "item":
            if let name = tempGearName {
                currentGear.append(BlueDiveGearData(
                    type: tempGearType,
                    manufacturer: tempGearManufacturer,
                    model: nil,                   // NOT imported from MacDive
                    name: name,
                    serial: tempGearSerial,
                    datePurchased: nil,           // NOT imported from MacDive
                    purchasePrice: nil,           // NOT imported from MacDive
                    currency: nil,                // NOT imported from MacDive
                    purchasedFrom: nil,           // NOT imported from MacDive
                    weightContribution: nil,      // NOT imported from MacDive
                    weightContributionUnit: nil,  // NOT imported from MacDive
                    nextServiceDue: nil,          // NOT imported from MacDive
                    serviceHistory: nil,          // NOT imported from MacDive
                    gearNotes: nil,               // NOT imported from MacDive
                    isInactive: false             // NOT imported from MacDive
                ))
            }
            isInGearItem = false
        default: break
        }
    }

    private func parseSampleElement(_ elementName: String, text: String) {
        switch elementName {
        case "time":        tempSampleTime = Double(text)
        case "depth":       tempSampleDepth = Double(text)
        case "pressure":    tempSamplePressure = Double(text)
        case "temperature": tempSampleTemperature = Double(text)
        case "ppo2":        tempSamplePPO2 = Double(text)
        case "ndt":         tempSampleNDT = Int(text)
        case "sample":
            if let time = tempSampleTime, let depth = tempSampleDepth {
                currentSamples.append(BlueDiveSamplesData(
                    time: time,
                    depth: depth,
                    pressure: tempSamplePressure,
                    temperature: tempSampleTemperature,
                    ppo2: tempSamplePPO2,
                    ndt: tempSampleNDT
                ))
            }
            isInSample = false
        default: break
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

    // Fish data is NOT imported from MacDive XML (per CSV mapping)
    // private func parseFishElement(_ elementName: String, text: String) {
    //     switch elementName {
    //     case "name":
    //         tempFishName = text
    //     case "count":
    //         tempMarineLifeCount = Int(text)
    //     case "marineLife":
    //         if let name = tempMarineLifeName, let count = tempMarineLifeCount {
    //             currentMarineLifeSeen.append(BlueDiveMarineLifeData(name: name, count: count))
    //         }
    //         isInMarineLife = false
    //     default: break
    //     }
    // }

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
        case "surfaceInterval",
             "surfaceinterval",
             "surface_interval",
             "SurfaceInterval":   currentSurfaceInterval = parseSeconds(text)
        case "sampleInterval",
             "sampleinterval":    currentInterval = parseSeconds(text)
        case "cns":              currentCNS = Double(text)
        case "decoModel":        currentDecoModel = text.nilIfEmpty
        case "tempAir":          currentTempAir = Double(text)
        case "tempHigh":         currentTempHigh = Double(text)
        case "tempLow":          currentTempLow = Double(text)
        case "visibility":       currentVisibility = text.nilIfEmpty
        case "weight":
            // Extract numeric value from text that may contain units (e.g. "5kg", "5,5 kilo")
            let numericString = text.filter { $0.isNumber || $0 == "." || $0 == "," }
                .replacingOccurrences(of: ",", with: ".")
            if let value = Double(numericString) {
                currentWeight = (value * 100).rounded() / 100
            }
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
        case "dive":
            dives.append(BlueDiveGlobalData(
                distanceFormat: distanceFormat,
                temperatureFormat: temperatureFormat,
                pressureFormat: pressureFormat,
                volumeFormat: volumeFormat,
                weightFormat: weightFormat,
                sourceImport: "MacDive",
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
                isDecompressionDive: false,
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
                tanks: [],  // MacDive XML doesn't export tank array (uses single gas section)
                gear: currentGear,
                samples: currentSamples,
                marineLifeSeen: [],  // Marine life data NOT imported from MacDive XML (per CSV mapping)
                decoStops: []
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
        currentSite = nil
        currentTypes = []
        currentBuddies = []
        currentGases = []
        currentGear = []
        currentSamples = []
        // Fish data NOT imported from MacDive XML
        // currentFishSeen = []
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
        tempGasDouble = false
        tempGasTankSize = nil
        tempGasWorkingPressure = nil
        tempGasSupplyType = nil
        tempGasDuration = nil
        tempGasTankName = nil
        // tankMaterial and tankType NOT imported from MacDive XML
        // tempGasTankMaterial = nil
        // tempGasTankType = nil
    }

    private func resetTempGear() {
        tempGearType = nil
        tempGearManufacturer = nil
        tempGearName = nil
        tempGearSerial = nil
    }

    private func resetTempSample() {
        tempSampleTime = nil
        tempSampleDepth = nil
        tempSamplePressure = nil
        tempSampleTemperature = nil
        tempSamplePPO2 = nil
        tempSampleNDT = nil
    }

    // Fish data is NOT imported from MacDive XML (per CSV mapping)
    // private func resetTempFish() {
    //     tempFishName = nil
    //     tempFishCount = nil
    // }

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
    /// Returns `nil` if the string is empty, otherwise returns `self`.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
