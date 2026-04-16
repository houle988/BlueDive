import Foundation
import SwiftData

// MARK: - Profile Event

/// Events that can occur at a dive profile point, as reported by the dive computer
enum DiveProfileEvent: Codable, Hashable, Sendable {
    case ascent              // Ascent rate warning
    case violation           // Deco violation
    case decoStop            // Deco stop required
    case gasChange           // Gas change
    case bookmark            // User bookmark/marker
    case safetyStop(Bool)    // Safety stop (mandatory?)
    case ceiling             // Ceiling violation
    case po2                 // PPO2 warning
    case deepStop            // Deep stop
    
    /// Short label for display in the samples table (not localized — raw dive computer data)
    var label: String {
        switch self {
        case .ascent: "Ascent"
        case .violation: "Violation"
        case .decoStop: "Deco"
        case .gasChange: "Gas Chg"
        case .bookmark: "Bookmark"
        case .safetyStop(let mandatory):
            mandatory ? "Safety (M)" : "Safety"
        case .ceiling: "Ceiling"
        case .po2: "PPO₂"
        case .deepStop: "Deep Stop"
        }
    }
}

// MARK: - Profile Point

/// Structure to store dive profile points (Depth/Time)
/// Conforms to Codable for serialization and Hashable for comparisons
struct DiveProfilePoint: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let time: Double  // Time in minutes
    let depth: Double // Depth in meters
    let temperature: Double? // Temperature in Celsius
    let tankPressure: Double? // Tank pressure in bar (single / primary tank)
    let tankPressures: [Int: Double]? // Per-tank pressure readings {tankIndex: bar}
    let ndl: Double? // No Decompression Limit in minutes
    let ppo2: Double? // Oxygen partial pressure in bar
    let events: [DiveProfileEvent] // Events at this profile point
    
    init(id: UUID = UUID(), time: Double, depth: Double, temperature: Double? = nil, tankPressure: Double? = nil, tankPressures: [Int: Double]? = nil, ndl: Double? = nil, ppo2: Double? = nil, events: [DiveProfileEvent] = []) {
        self.id = id
        self.time = time
        self.depth = depth
        self.temperature = temperature
        self.tankPressure = tankPressure
        self.tankPressures = tankPressures
        self.ndl = ndl
        self.ppo2 = ppo2
        self.events = events
    }
    
    // Custom decoder so that profiles serialized before the events field was added
    // can still be read — events defaults to [] when the key is absent.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        time = try container.decode(Double.self, forKey: .time)
        depth = try container.decode(Double.self, forKey: .depth)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        let storedPressure = try container.decodeIfPresent(Double.self, forKey: .tankPressure)
        let perTank = try container.decodeIfPresent([Int: Double].self, forKey: .tankPressures)
        tankPressures = perTank
        // Derive tankPressure from per-tank dict (tank 0 / lowest index) when available
        tankPressure = perTank.flatMap { $0[0] ?? $0.min(by: { $0.key < $1.key })?.value } ?? storedPressure
        ndl = try container.decodeIfPresent(Double.self, forKey: .ndl)
        ppo2 = try container.decodeIfPresent(Double.self, forKey: .ppo2)
        events = (try? container.decode([DiveProfileEvent].self, forKey: .events)) ?? []
    }
}

// MARK: - Tank Data

/// Represents a gas tank with its gas mix
struct TankData: Identifiable, Sendable {
    let id: UUID
    let o2: Double               // O₂ fraction (0.0–1.0), default 0.21 (Air)
    let he: Double               // He fraction (0.0–1.0), default 0.0
    let volume: Double?          // Volume in litres
    let startPressure: Double?   // Starting pressure in bar
    let endPressure: Double?     // Ending pressure in bar
    let workingPressure: Double? // Working pressure in bar (optional)
    let tankMaterial: String?    // Tank material (Steel, Aluminum, etc.)
    let tankType: String?        // Configuration type (Single, Double, Sidemount)
    let usageStartTime: Double?  // Seconds into the dive when this tank started being used
    let usageEndTime: Double?    // Seconds into the dive when this tank stopped being used

    // Computed gas properties
    var n2: Double { max(0, 1.0 - o2 - he) }
    var o2Percentage: Int { Int((o2 * 100).rounded()) }
    var hePercentage: Int { Int((he * 100).rounded()) }

    var gasName: String {
        if hePercentage > 0 { return "Trimix" }
        if o2Percentage > 21 { return "Nitrox" }
        return "Air"
    }

    init(id: UUID = UUID(), o2: Double = 0.21, he: Double = 0.0,
         volume: Double? = nil, startPressure: Double? = nil, endPressure: Double? = nil,
         workingPressure: Double? = nil, tankMaterial: String? = nil, tankType: String? = nil,
         usageStartTime: Double? = nil, usageEndTime: Double? = nil) {
        self.id = id
        self.o2 = o2
        self.he = he
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

// MARK: - TankData Codable

extension TankData: Codable {
    enum CodingKeys: String, CodingKey {
        case id, o2, he, volume, startPressure, endPressure
        case workingPressure, tankMaterial, tankType
        case usageStartTime, usageEndTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        o2 = try container.decodeIfPresent(Double.self, forKey: .o2) ?? 0.21
        he = try container.decodeIfPresent(Double.self, forKey: .he) ?? 0.0
        volume = try container.decodeIfPresent(Double.self, forKey: .volume)
        startPressure = try container.decodeIfPresent(Double.self, forKey: .startPressure)
        endPressure = try container.decodeIfPresent(Double.self, forKey: .endPressure)
        workingPressure = try container.decodeIfPresent(Double.self, forKey: .workingPressure)
        tankMaterial = try container.decodeIfPresent(String.self, forKey: .tankMaterial)
        tankType = try container.decodeIfPresent(String.self, forKey: .tankType)
        usageStartTime = try container.decodeIfPresent(Double.self, forKey: .usageStartTime)
        usageEndTime = try container.decodeIfPresent(Double.self, forKey: .usageEndTime)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(o2, forKey: .o2)
        try container.encode(he, forKey: .he)
        try container.encodeIfPresent(volume, forKey: .volume)
        try container.encodeIfPresent(startPressure, forKey: .startPressure)
        try container.encodeIfPresent(endPressure, forKey: .endPressure)
        try container.encodeIfPresent(workingPressure, forKey: .workingPressure)
        try container.encodeIfPresent(tankMaterial, forKey: .tankMaterial)
        try container.encodeIfPresent(tankType, forKey: .tankType)
        try container.encodeIfPresent(usageStartTime, forKey: .usageStartTime)
        try container.encodeIfPresent(usageEndTime, forKey: .usageEndTime)
    }
}

// MARK: - Dive Sample

/// Represents a measurement point during a dive
struct DiveSample: Identifiable, Sendable {
    let id = UUID()
    let time: Double // in minutes
    let depth: Double // in meters
    let temperature: Double? // in Celsius
    let tankPressure: Double? // in bar
    let ndl: Double? // No Decompression Limit in minutes
    let ppo2: Double? // O₂ partial pressure in bar (calculated)
}

// MARK: - Deco Stop

/// A decompression stop planned/required by the dive computer
struct DecoStop: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let depth: Double      // depth in meters
    let time: TimeInterval // duration in seconds
    let type: Int          // DC_DECO_NDL=0, SAFETYSTOP=1, DECOSTOP=2, DEEPSTOP=3

    init(id: UUID = UUID(), depth: Double, time: TimeInterval, type: Int) {
        self.id = id
        self.depth = depth
        self.time = time
        self.type = type
    }
}

// MARK: - Marine Sight

@Model
final class MarineSight {
    var id: UUID = UUID()
    var name: String = ""
    var count: Int = 1
    
    // Inverse relationship to Dive
    var dive: Dive?
    
    init(id: UUID = UUID(), name: String, count: Int = 1) {
        self.id = id
        self.name = name
        self.count = count
    }
}

// MARK: - Dive Model

@Model
final class Dive {
    // MARK: Identifiers
    
    var id: UUID = UUID()
    var diveNumber: Int? // Dive number in logbook
    var identifier: String? // Unique computer identifier (e.g., "20251004185216-ABC976F1")
    
    // MARK: Metadata
    
    var timestamp: Date = Date.now
    var location: String = ""
    var siteName: String = ""
    var diveTypes: String? // Multiple types comma-separated (Night, Wreck, etc.)
    
    /// The primary dive type, falling back to "Reef" when no types are set.
    var primaryDiveType: String {
        diveTypes?
            .split(separator: ",")
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces) ?? "Reef"
    }
    var tags: String? // Tags separated by commas
    
    // MARK: Equipment & Computer
    
    var computerName: String = ""
    var computerSerialNumber: String? // Computer serial number
    var surfaceInterval: String = "0h 00m"
    var diverName: String = "" // Primary diver name
    var buddies: String = ""   // Buddy names (comma-separated)
    var rating: Int = 0
    
    // MARK: Dive Logistics
    
    var isRepetitiveDive: Bool = false // Repetitive dive
    var weights: Double? // Weight (in kg)
    
    // MARK: Conditions
    
    var weather: String? // Weather conditions (Sunny, Cloudy, Rainy, etc.)
    var surfaceConditions: String? // Surface state (Calm, Choppy, Waves, etc.)
    var current: String? // Current (None, Weak, Moderate, Strong)
    var visibility: String? // Visibility (free text or numerical value in meters)
    var entryType: String? // Entry type (Shore, Boat, Zodiac, etc.)
    
    // MARK: Operator
    
    var diveOperator: String? // Dive center name
    var diveMaster: String? // Guide/instructor name
    var skipper: String? // Boat captain
    var boat: String? // Boat name
    
    // MARK: Dive Statistics
    
    var maxDepth: Double = 0.0
    var averageDepth: Double = 0.0
    var duration: Int = 0 // in minutes
    
    // MARK: Temperatures
    
    var waterTemperature: Double = 0.0
    var minTemperature: Double = 0.0
    var airTemperature: Double? // Air temperature
    var maxTemperature: Double? // Maximum water temperature
    
    // MARK: Gas & Cylinder — stored in TankData array
    
    // MARK: Advanced Gas & Decompression
    
    var decompressionAlgorithm: String? // Decompression algorithm (e.g., "Bühlmann ZH-L16C", "VPM-B")
    var cnsPercentage: Double? // CNS percentage (Central Nervous System Oxygen Toxicity)
    var isDecompressionDive: Bool = false // Dive with mandatory decompression stops
    
    // MARK: Import Unit Metadata

    /// The distance unit in which `maxDepth`, `averageDepth`, `siteAltitude`, and
    /// profile sample depths were originally stored at import time.
    /// Valid values: `"meters"` (default) or `"feet"`.
    /// **Never change this after import; never use it to mutate stored values.**
    var importDistanceUnit: String = "meters"

    /// The temperature unit in which `waterTemperature`, `minTemperature`,
    /// `airTemperature`, `maxTemperature`, and profile sample temperatures were
    /// originally stored at import time.
    /// Valid values: `"°c"` (default), `"°f"`, `"°k"` — mirrors the
    /// `ImportFormatOptions.temperatureFormat` strings.
    /// **Never change this after import; never use it to mutate stored values.**
    var importTemperatureUnit: String = "°c"

    /// The pressure unit in which `TankData.startPressure`, `TankData.endPressure`,
    /// `TankData.workingPressure`, and profile sample `tankPressure` values were
    /// originally stored at import time.
    /// Valid values: `"bar"` (default), `"psi"`, `"pa"` — mirrors the
    /// `ImportFormatOptions.pressureFormat` strings.
    /// **Never change this after import; never use it to mutate stored values.**
    var importPressureUnit: String = "bar"

    /// The volume unit in which `TankData.volume` was
    /// originally stored at import time.
    /// Valid values: `"liters"` (default), `"cubic feet"` — mirrors the
    /// `ImportFormatOptions.volumeFormat` strings.
    /// **Never change this after import; never use it to mutate stored values.**
    var importVolumeUnit: String = "liters"

    /// The weight unit in which `weights` was originally stored at import time.
    /// Valid values: `"kg"` (default), `"lb"` — mirrors the
    /// `ImportFormatOptions.weightFormat` strings.
    /// **Never change this after import; never use it to mutate stored values.**
    var importWeightUnit: String = "kg"

    // MARK: Import Source
    
    /// Identifies which import source created this dive.
    /// Valid values: "Bluetooth", "MacDive", "BlueDive", or nil for manually created dives.
    var sourceImport: String?
    
    // MARK: Additional Data
    
    var notes: String = ""
    
    // MARK: Site Details
    
    var siteCountry: String?         // Country (e.g., "Canada")
    var siteBodyOfWater: String?     // Body of water type (e.g., "River", "Ocean", "Lake")
    var siteDifficulty: String?      // Difficulty (Beginner, Intermediate, Advanced, Expert)
    var siteWaterType: String?       // Water type (Fresh, Salt, Brackish)
    var siteAltitude: Double?        // Altitude in meters
    var siteLatitude: Double?        // GPS latitude
    var siteLongitude: Double?       // GPS longitude
    
    /// Photos de la plongée (stockées comme Data)
    @Attribute(.externalStorage)
    var photosData: [Data]?
    
    /// Profil de plongée (points de temps/profondeur)
    /// Stocké comme Data encodé pour éviter les problèmes de persistance avec les arrays de structs
    @Attribute(.externalStorage)
    private var profileData: Data?
    
    /// Bouteilles (tankdata UDDF)
    @Attribute(.externalStorage)
    private var tanksData: Data?
    
    /// Decompression stops from the dive computer (JSON-encoded [DecoStop])
    var decoStopsData: Data?

    /// Raw binary dive data from the dive computer
    @Attribute(.externalStorage)
    var rawDiveComputerData: Data?

    /// Fingerprint bytes identifying this dive on the computer.
    /// Stored here so the fingerprint syncs via iCloud and survives app reinstalls,
    /// replacing reliance on UserDefaults as the sole persistent store.
    /// Only the most-recent dive for a given device serial carries a non-nil value.
    var fingerprintData: Data?
    
    // MARK: Relationships
    
    @Relationship(deleteRule: .cascade, inverse: \MarineSight.dive)
    var seenFish: [MarineSight]? = []
    
    @Relationship(deleteRule: .nullify)
    var usedGear: [Gear]? = []
    

    
    // MARK: Computed Properties
    
    /// Accès au profil de plongée
    var profileSamples: [DiveProfilePoint] {
        get {
            guard let data = profileData else { return [] }
            return (try? JSONDecoder().decode([DiveProfilePoint].self, from: data)) ?? []
        }
        set {
            profileData = try? JSONEncoder().encode(newValue)
        }
    }
    
    /// Accès aux bouteilles
    var tanks: [TankData] {
        get {
            guard let data = tanksData else { return [] }
            return (try? JSONDecoder().decode([TankData].self, from: data)) ?? []
        }
        set {
            tanksData = try? JSONEncoder().encode(newValue)
        }
    }

    /// Arrêts de décompression
    var decoStops: [DecoStop] {
        get {
            guard let data = decoStopsData else { return [] }
            return (try? JSONDecoder().decode([DecoStop].self, from: data)) ?? []
        }
        set {
            decoStopsData = try? JSONEncoder().encode(newValue)
        }
    }
    
    // MARK: - Computed Gas & Cylinder Properties (from TankData)
    
    /// Gas type derived from the primary tank's gas mix.
    var gasType: String {
        tanks.first?.gasName ?? "Air"
    }
    
    /// Oxygen percentage from the primary tank's gas mix.
    var oxygenPercentage: Int {
        tanks.first?.o2Percentage ?? 21
    }
    
    /// Helium percentage from the primary tank's gas mix.
    var heliumPercentage: Int? {
        guard let tank = tanks.first else { return nil }
        return tank.hePercentage > 0 ? tank.hePercentage : nil
    }
    
    /// Whether the primary tank is a double/twin configuration.
    var isDoubleTank: Bool {
        guard let tt = tanks.first?.tankType?.lowercased() else { return false }
        return tt.contains("double") || tt.contains("twin")
    }
    
    // MARK: - Unit-Aware Display Helpers

    /// Converts a raw depth/altitude value that was stored in `importDistanceUnit`
    /// to the unit currently preferred by the user (`UserPreferences.shared.depthUnit`).
    ///
    /// **Rule:** All values in the database are stored as-imported (metres or feet).
    /// This method is the single place that performs the read-time conversion;
    /// nothing else should multiply by 3.28084 directly.
    ///
    /// - Parameter rawValue: A depth or altitude value as stored in the database.
    /// - Returns: The value expressed in the user's current display unit.
    func displayDepth(_ rawValue: Double) -> Double {
        let storedInFeet = importDistanceUnit == "feet"
        let displayInFeet = UserPreferences.shared.depthUnit == .feet

        switch (storedInFeet, displayInFeet) {
        case (false, false): return rawValue                  // m  → m
        case (false, true):  return rawValue * 3.28084        // m  → ft
        case (true,  true):  return rawValue                  // ft → ft
        case (true,  false): return rawValue / 3.28084        // ft → m
        }
    }

    /// The display-ready maximum depth, respecting both the stored unit and the user preference.
    var displayMaxDepth: Double { displayDepth(maxDepth) }

    /// The display-ready average depth, respecting both the stored unit and the user preference.
    var displayAverageDepth: Double { displayDepth(averageDepth) }

    /// The display-ready site altitude, respecting both the stored unit and the user preference.
    var displaySiteAltitude: Double? {
        guard let alt = siteAltitude else { return nil }
        return displayDepth(alt)
    }

    // MARK: - Temperature Display Helpers

    /// The `TemperatureUnit` in which temperature values were stored at import time.
    /// Derived from `importTemperatureUnit`; falls back to `.celsius` for manually
    /// entered dives (the default for all pre-existing records).
    var storedTemperatureUnit: TemperatureUnit {
        TemperatureUnit.from(importFormat: importTemperatureUnit)
    }

    /// Converts a raw temperature value **as stored in the database** to the value
    /// expressed in the user's currently preferred display unit.
    ///
    /// **Rule:** This is the single read-time conversion point for all temperature
    /// fields (`waterTemperature`, `minTemperature`, `airTemperature`,
    /// `maxTemperature`, and profile sample temperatures).
    /// **Never** pre-convert at import time; **never** store the result back.
    ///
    /// - Parameter rawValue: A temperature value exactly as stored in the database.
    /// - Returns: The value in `UserPreferences.shared.temperatureUnit`.
    func displayTemperature(_ rawValue: Double) -> Double {
        UserPreferences.shared.temperatureUnit.convert(rawValue, from: storedTemperatureUnit)
    }


    // MARK: Convenience display properties for common temperature fields

    /// Surface / water temperature converted to the user's display unit.
    var displayWaterTemperature: Double     { displayTemperature(waterTemperature) }

    /// Minimum (bottom) temperature converted to the user's display unit.
    var displayMinTemperature: Double       { displayTemperature(minTemperature) }

    /// Air temperature converted to the user's display unit (nil if not recorded).
    var displayAirTemperature: Double?      { airTemperature.map { displayTemperature($0) } }

    /// Maximum water temperature converted to the user's display unit (nil if not recorded).
    var displayMaxTemperature: Double?      { maxTemperature.map { displayTemperature($0) } }

    /// Converts a raw profile-sample temperature to the user's display unit.
    /// Profile samples are stored in the same unit as `importTemperatureUnit`.
    func displayProfileTemperature(_ rawTemp: Double) -> Double {
        displayTemperature(rawTemp)
    }

    // MARK: - Pressure Display Helpers

    /// The `PressureUnit` in which all pressure values were stored at import time.
    /// Derived from `importPressureUnit`; falls back to `.bar` for manually
    /// entered dives (the default for all pre-existing records).
    var storedPressureUnit: PressureUnit {
        PressureUnit.from(importFormat: importPressureUnit)
    }

    /// Converts a raw pressure value **as stored in the database** to the value
    /// expressed in the user's currently preferred display unit.
    ///
    /// **Rule:** This is the single read-time conversion point for all pressure
    /// fields (`TankData.startPressure`, `TankData.endPressure`,
    /// `TankData.workingPressure`, and profile sample `tankPressure` values).
    /// **Never** pre-convert at import time; **never** store the result back.
    ///
    /// - Parameter rawValue: A pressure value exactly as stored in the database.
    /// - Returns: The value in `UserPreferences.shared.pressureUnit`.
    func displayPressure(_ rawValue: Double) -> Double {
        UserPreferences.shared.pressureUnit.convert(rawValue, from: storedPressureUnit)
    }

    /// Formats a raw stored pressure for display, appending the correct symbol.
    ///
    /// - Parameters:
    ///   - rawValue: The value **exactly as stored in the database** (no pre-conversion).
    ///   - decimals: Number of decimal places (default 0).
    func formattedPressure(_ rawValue: Double, decimals: Int = 0) -> String {
        UserPreferences.shared.pressureUnit.formatted(rawValue, from: storedPressureUnit, decimals: decimals)
    }

    // MARK: Convenience display properties for common pressure fields

    /// Start / fill pressure converted to the user's display unit.
    var displayStartPressure: Double? { tanks.first?.startPressure.map { displayPressure($0) } }

    /// End pressure converted to the user's display unit.
    var displayEndPressure: Double?   { tanks.first?.endPressure.map { displayPressure($0) } }

    /// Converts a raw profile-sample tank pressure to the user's display unit.
    /// Profile samples are stored in the same unit as `importPressureUnit`.
    func displayProfilePressure(_ rawPressure: Double) -> Double {
        displayPressure(rawPressure)
    }

    // MARK: - Volume Display Helpers

    /// The `VolumeUnit` in which `cylinderSize` and `TankData.volume` were stored
    /// at import time.  Derived from `importVolumeUnit`; falls back to `.liters`
    /// for manually entered dives (the default for all pre-existing records).
    var storedVolumeUnit: VolumeUnit {
        VolumeUnit.from(importFormat: importVolumeUnit)
    }

    /// The weight unit in which `weights` was originally stored
    /// at import time.  Derived from `importWeightUnit`; falls back to `.kilograms`
    /// for manually entered dives (the default for all pre-existing records).
    var storedWeightUnit: WeightUnit {
        WeightUnit.from(importFormat: importWeightUnit)
    }

    /// Returns the **water volume in litres** for a given raw stored volume value.
    ///
    /// In US/imperial files (`importVolumeUnit == "cubic feet"`), MacDive exports
    /// `tankSize` as the **gas capacity at working pressure** (e.g. a "100 cu ft"
    /// tank), NOT the geometric water volume.  Converting that directly to litres
    /// via `1 ft³ = 28.3168 L` gives the wrong result (~2831 L instead of ~13 L).
    ///
    /// The correct water volume in litres is:
    ///   `waterVol_L = tankSize_cuft × 28.3168 / workingPressure_bar`
    ///
    /// When `workingPressure` is unavailable we fall back to a reasonable default
    /// (3000 PSI = 206.84 bar) so the formula remains usable.
    ///
    /// When the stored unit is litres the value is already the water volume.
    ///
    /// - Parameters:
    ///   - rawVolume: The volume exactly as stored in the database.
    ///   - workingPressureRaw: The working pressure exactly as stored (same
    ///     `importPressureUnit`), if available.  Used only when
    ///     `storedVolumeUnit == .cubicFeet`.
    func waterVolumeLiters(rawVolume: Double, workingPressureRaw: Double?) -> Double {
        switch storedVolumeUnit {
        case .liters:
            return rawVolume
        case .cubicFeet:
            // Convert the gas-capacity (cu ft) to water volume (litres).
            // Formula: waterVol_L = gasCap_cuft × 28.3168 / WP_bar
            let wpBar: Double
            if let wpRaw = workingPressureRaw, wpRaw > 0 {
                wpBar = PressureUnit.bar.convert(wpRaw, from: storedPressureUnit)
            } else {
                // Fallback: 3000 PSI is the most common US tank working pressure.
                wpBar = PressureUnit.bar.convert(3000, from: .psi)
            }
            guard wpBar > 0 else { return rawVolume * 28.3168 }
            return (rawVolume * 28.3168) / wpBar
        }
    }

    /// Converts a raw volume value **as stored in the database** to the value
    /// expressed in the user's currently preferred display unit.
    ///
    /// For cubic-feet imports the stored value is a gas capacity; this method
    /// converts it to water-volume litres first (using `workingPressureRaw`),
    /// then to the user's display unit.
    ///
    /// **Rule:** This is the single read-time conversion point for all volume
    /// fields (`TankData.volume`).
    /// **Never** pre-convert at import time; **never** store the result back.
    ///
    /// - Parameters:
    ///   - rawValue: A volume value exactly as stored in the database.
    ///   - workingPressureRaw: The working pressure exactly as stored, if available.
    func displayVolume(_ rawValue: Double, workingPressureRaw: Double? = nil) -> Double {
        switch UserPreferences.shared.volumeUnit {
        case .liters:
            // Need true water volume in litres.
            return waterVolumeLiters(rawVolume: rawValue, workingPressureRaw: workingPressureRaw)
        case .cubicFeet:
            // For cu ft display: if stored in cu ft, show as-is (gas capacity).
            // If stored in litres, convert to gas capacity in cu ft using working pressure.
            // Formula: gasCap_cuft = waterVol_L × WP_bar / 28.3168
            // (inverse of waterVolumeLiters)
            switch storedVolumeUnit {
            case .cubicFeet: return rawValue
            case .liters:
                let wpBar: Double
                if let wpRaw = workingPressureRaw, wpRaw > 0 {
                    wpBar = PressureUnit.bar.convert(wpRaw, from: storedPressureUnit)
                } else {
                    wpBar = PressureUnit.bar.convert(3000, from: .psi)
                }
                guard wpBar > 0 else { return rawValue / 28.3168 }
                return (rawValue * wpBar) / 28.3168
            }
        }
    }

    /// Formats a raw stored volume for display, appending the correct symbol.
    ///
    /// - Parameters:
    ///   - rawValue: The value **exactly as stored in the database** (no pre-conversion).
    ///   - workingPressureRaw: The working pressure as stored, if available.
    ///   - decimals: Number of decimal places (default 1).
    func formattedVolume(_ rawValue: Double, workingPressureRaw: Double? = nil, decimals: Int = 1) -> String {
        let display = displayVolume(rawValue, workingPressureRaw: workingPressureRaw)
        let symbol  = UserPreferences.shared.volumeUnit.symbol
        return String(format: "%.\(decimals)f \(symbol)", display)
    }


    /// The cylinder size as a formatted string in the user's display unit.
    var formattedCylinderSize: String? {
        guard let size = tanks.first?.volume else { return nil }
        let wp = tanks.first?.workingPressure
        return formattedVolume(size, workingPressureRaw: wp)
    }

    // MARK: - Profile Helpers

    /// Converts a profile sample depth to the user's current display unit,
    /// using this dive's `importDistanceUnit` as the source.
    func displayProfileDepth(_ rawDepth: Double) -> Double {
        displayDepth(rawDepth)
    }

    /// Profondeur moyenne pondérée par le temps (règle des trapèzes),
    /// calculée depuis les échantillons du profil UDDF quand ils sont disponibles.
    /// Chaque segment [i-1 → i] contribue proportionnellement à son intervalle de temps réel,
    /// ce qui correspond à la méthode utilisée par MacDive et les logiciels de plongée professionnels.
    /// Revient à `averageDepth` (moyenne arithmétique du parser) si le profil est absent.
    var timeWeightedAverageDepth: Double {
        let samples = profileSamples
        guard samples.count >= 2 else { return averageDepth }

        var weightedSum = 0.0
        var totalTime = 0.0

        for i in 1..<samples.count {
            let dt = samples[i].time - samples[i - 1].time
            guard dt > 0 else { continue }
            let midDepth = (samples[i].depth + samples[i - 1].depth) / 2.0
            weightedSum += midDepth * dt
            totalTime += dt
        }

        guard totalTime > 0 else { return averageDepth }
        return weightedSum / totalTime
    }

    /// Time-weighted average depth for a specific time window (in minutes).
    /// Falls back to `timeWeightedAverageDepth` when the window covers the full dive.
    func timeWeightedAverageDepth(from startMin: Double, to endMin: Double) -> Double {
        let samples = profileSamples
        guard samples.count >= 2 else { return averageDepth }

        var weightedSum = 0.0
        var totalTime = 0.0

        for i in 1..<samples.count {
            let t0 = samples[i - 1].time
            let t1 = samples[i].time
            // Clip segment to the requested window
            let segStart = max(t0, startMin)
            let segEnd = min(t1, endMin)
            let dt = segEnd - segStart
            guard dt > 0 else { continue }

            // Interpolate depths at segment boundaries
            let segDuration = t1 - t0
            guard segDuration > 0 else { continue }
            let d0 = samples[i - 1].depth
            let d1 = samples[i].depth
            let depthAtSegStart = d0 + (d1 - d0) * ((segStart - t0) / segDuration)
            let depthAtSegEnd = d0 + (d1 - d0) * ((segEnd - t0) / segDuration)
            let midDepth = (depthAtSegStart + depthAtSegEnd) / 2.0
            weightedSum += midDepth * dt
            totalTime += dt
        }

        guard totalTime > 0 else { return averageDepth }
        return weightedSum / totalTime
    }

    /// Combined RMV across all tanks (L/min at the surface).
    /// Delegates to `combinedRMV` which uses per-tank `tankType` multipliers.
    var calculatedRMV: Double { combinedRMV }

    /// Combined SAC across all tanks (bar/min).
    /// Delegates to `combinedSAC` which uses per-tank `tankType` multipliers.
    var calculatedSAC: Double { combinedSAC }

    // MARK: - Per-tank RMV / SAC

    /// RMV for a specific tank (L/min at the surface).
    /// Uses the tank's usage time window when available for accurate per-tank calculation.
    func calculatedRMV(forTankAt index: Int) -> Double {
        guard duration > 0, index >= 0, index < tanks.count else { return 0.0 }
        let tank = tanks[index]

        let samples = profileSamples
        let hasSamples = (samples.last?.time ?? 0) > 0

        // Manual dive (no samples): only supported for single tank
        if !hasSamples && tanks.count > 1 { return 0.0 }

        let hasUsageTimes = tank.usageStartTime != nil || tank.usageEndTime != nil

        let divisor: Double
        let effectiveAvgDepth: Double

        if hasUsageTimes, hasSamples {
            let lastTimeMin = samples.last!.time              // minutes
            let usageStartMin = (tank.usageStartTime ?? 0) / 60.0 // seconds → minutes
            let usageEndMin = tank.usageEndTime.map { $0 / 60.0 } ?? lastTimeMin
            let durationMin = usageEndMin - usageStartMin
            guard durationMin > 0 else { return 0.0 }
            divisor = durationMin
            effectiveAvgDepth = timeWeightedAverageDepth(from: usageStartMin, to: usageEndMin)
        } else if hasSamples {
            // Match combined calculatedRMV: divide by lastTime (minutes)
            divisor = samples.last!.time
            effectiveAvgDepth = timeWeightedAverageDepth
        } else {
            // Manual single-tank dive: use stored duration (minutes)
            divisor = Double(duration)
            effectiveAvgDepth = timeWeightedAverageDepth
        }
        guard divisor > 0, effectiveAvgDepth > 0 else { return 0.0 }

        let effectiveAvgDepthMeters = importDistanceUnit == "feet"
            ? effectiveAvgDepth / 3.28084
            : effectiveAvgDepth
        let avgAtmosphere = (effectiveAvgDepthMeters / 10.0) + 1.0
        let tankTypeLC = tank.tankType?.lowercased() ?? ""
        let tankMultiplier: Double = (tankTypeLC.contains("twin") || tankTypeLC.contains("double")) ? 2.0 : 1.0

        guard let volume = tank.volume,
              let pStart = tank.startPressure,
              let pEnd = tank.endPressure,
              volume > 0, pStart > pEnd else { return 0.0 }

        let pStartBar = PressureUnit.bar.convert(pStart, from: storedPressureUnit)
        let pEndBar   = PressureUnit.bar.convert(pEnd,   from: storedPressureUnit)
        let consumedBar = pStartBar - pEndBar
        let volumeLiters = waterVolumeLiters(rawVolume: volume, workingPressureRaw: tank.workingPressure)
        let totalLiters = consumedBar * volumeLiters * tankMultiplier
        let rmv = totalLiters / divisor / avgAtmosphere
        return rmv > 0 && rmv < 100 ? rmv : 0.0
    }

    /// SAC for a specific tank (bar/min).
    func calculatedSAC(forTankAt index: Int) -> Double {
        let rmv = calculatedRMV(forTankAt: index)
        guard rmv > 0, index >= 0, index < tanks.count else { return 0.0 }
        let tank = tanks[index]
        guard let volume = tank.volume, volume > 0 else { return 0.0 }
        let volumeLiters = waterVolumeLiters(rawVolume: volume, workingPressureRaw: tank.workingPressure)
        let sac = rmv / volumeLiters
        return sac > 0 && sac < 20 ? sac : 0.0
    }

    /// Formatted RMV for a specific tank.
    func formattedRMV(forTankAt index: Int) -> String {
        let rmvLiters = calculatedRMV(forTankAt: index)
        guard rmvLiters > 0 else { return "—" }
        let displayPreference = UserPreferences.shared.pressureUnit
        let valueString: String
        if displayPreference == .psi {
            let rmvCuFt = rmvLiters / 28.3168
            valueString = String(format: "%.3f cu ft/min", rmvCuFt)
        } else {
            valueString = String(format: "%.2f L/min", rmvLiters)
        }
        return isRMVInNativeUnits ? valueString : valueString + " *"
    }

    /// Formatted SAC for a specific tank.
    func formattedSAC(forTankAt index: Int) -> String {
        let sac = calculatedSAC(forTankAt: index)
        guard sac > 0 else { return "—" }
        let displaySac = UserPreferences.shared.pressureUnit.convertFromBar(sac)
        let unit = UserPreferences.shared.pressureUnit.symbol
        return String(format: "%.2f \(unit)/min", displaySac)
    }

    /// Combined RMV across all tanks.
    ///
    /// Formula: Σ(consumedGas_i / avgAtm_i) / actualDiveTime
    ///
    /// Dividing by actual dive time (not the sum of tank usage durations) correctly handles
    /// all configurations:
    /// - Sidemount (simultaneous): both tanks contribute additively → sum of per-tank RMVs.
    /// - Sequential: each tank contributes proportionally to its usage fraction → weighted rate.
    /// - Mixed (sidemount + stage): sidemount tanks add fully, stage contributes proportionally.
    ///
    /// Multi-tank non-sidemount dives without usage times are suppressed via combinedRMVNeedsUsageTime.
    var combinedRMV: Double {
        guard duration > 0 else { return 0.0 }

        let samples = profileSamples
        let hasSamples = (samples.last?.time ?? 0) > 0

        // Manual dive (no samples): only supported for single tank
        if !hasSamples && tanks.count > 1 { return 0.0 }

        let durationMinutes: Double = {
            if let lastTime = samples.last?.time, lastTime > 0 { return lastTime }
            return Double(duration)
        }()

        // Non-sidemount multi-tank without usage times: cannot determine when each tank
        // was in use, so combined RMV cannot be computed accurately.
        if combinedRMVNeedsUsageTime { return 0.0 }

        // Check if any tank has explicit usage times
        let anyUsageTimes = tanks.contains { $0.usageStartTime != nil || $0.usageEndTime != nil }

        if anyUsageTimes {
            // Accumulate Σ(consumedGas_i / avgAtm_i) — the surface-equivalent litres contributed
            // by each tank over its usage period. Dividing by actualDiveTime (not totalUsageMinutes)
            // ensures simultaneous tanks (sidemount) add rather than average.
            var surfaceGasSum = 0.0
            var anyContribution = false

            for tank in tanks {
                guard let volume = tank.volume,
                      let pStart = tank.startPressure,
                      let pEnd = tank.endPressure,
                      volume > 0, pStart > pEnd else { continue }

                let usageStartMin = (tank.usageStartTime ?? 0) / 60.0         // seconds → minutes
                let usageEndMin = tank.usageEndTime.map { $0 / 60.0 } ?? durationMinutes
                let durationMin = usageEndMin - usageStartMin
                guard durationMin > 0 else { continue }

                let effectiveAvgDepth: Double
                if tank.usageStartTime != nil || tank.usageEndTime != nil {
                    effectiveAvgDepth = timeWeightedAverageDepth(from: usageStartMin, to: usageEndMin)
                } else {
                    effectiveAvgDepth = timeWeightedAverageDepth
                }
                guard effectiveAvgDepth > 0 else { continue }

                let effectiveAvgDepthMeters = importDistanceUnit == "feet"
                    ? effectiveAvgDepth / 3.28084
                    : effectiveAvgDepth
                let avgAtmosphere = (effectiveAvgDepthMeters / 10.0) + 1.0

                let pStartBar = PressureUnit.bar.convert(pStart, from: storedPressureUnit)
                let pEndBar   = PressureUnit.bar.convert(pEnd,   from: storedPressureUnit)
                let consumedBar = pStartBar - pEndBar
                let volumeLiters = waterVolumeLiters(rawVolume: volume, workingPressureRaw: tank.workingPressure)
                let tankTypeLC = tank.tankType?.lowercased() ?? ""
                let tankMultiplier: Double = (tankTypeLC.contains("twin") || tankTypeLC.contains("double")) ? 2.0 : 1.0
                let tankSurfaceGas = consumedBar * volumeLiters * tankMultiplier / avgAtmosphere

                surfaceGasSum += tankSurfaceGas
                anyContribution = true
            }

            guard anyContribution else { return 0.0 }
            let rmv = surfaceGasSum / durationMinutes
            return rmv > 0 && rmv < 100 ? rmv : 0.0
        } else {
            // Original behaviour: total gas / full dive duration (minutes)
            let effectiveAvgDepth = timeWeightedAverageDepth
            guard effectiveAvgDepth > 0 else { return 0.0 }

            let effectiveAvgDepthMeters = importDistanceUnit == "feet"
                ? effectiveAvgDepth / 3.28084
                : effectiveAvgDepth
            let avgAtmosphere = (effectiveAvgDepthMeters / 10.0) + 1.0

            var totalLiters = 0.0
            for tank in tanks {
                guard let volume = tank.volume,
                      let pStart = tank.startPressure,
                      let pEnd = tank.endPressure,
                      volume > 0, pStart > pEnd else { continue }

                let pStartBar = PressureUnit.bar.convert(pStart, from: storedPressureUnit)
                let pEndBar   = PressureUnit.bar.convert(pEnd,   from: storedPressureUnit)
                let consumedBar = pStartBar - pEndBar
                let volumeLiters = waterVolumeLiters(rawVolume: volume, workingPressureRaw: tank.workingPressure)
                let tankTypeLC = tank.tankType?.lowercased() ?? ""
                let tankMultiplier: Double = (tankTypeLC.contains("twin") || tankTypeLC.contains("double")) ? 2.0 : 1.0
                totalLiters += consumedBar * volumeLiters * tankMultiplier
            }

            guard totalLiters > 0 else { return 0.0 }
            let rmv = totalLiters / durationMinutes / avgAtmosphere
            return rmv > 0 && rmv < 100 ? rmv : 0.0
        }
    }

    /// Formatted combined RMV across all tanks.
    var formattedCombinedRMV: String {
        let rmvLiters = combinedRMV
        guard rmvLiters > 0 else { return "—" }
        let displayPreference = UserPreferences.shared.pressureUnit
        let valueString: String
        if displayPreference == .psi {
            let rmvCuFt = rmvLiters / 28.3168
            valueString = String(format: "%.3f cu ft/min", rmvCuFt)
        } else {
            valueString = String(format: "%.2f L/min", rmvLiters)
        }
        return isRMVInNativeUnits ? valueString : valueString + " *"
    }

    /// True when combined RMV cannot be computed accurately because there are multiple
    /// non-sidemount tanks and at least one is missing full usage time data.
    /// Sidemount tanks are exempt — they are breathed simultaneously and do not require usage times.
    var combinedRMVNeedsUsageTime: Bool {
        let validTanks = tanks.filter { ($0.volume ?? 0) > 0 && $0.startPressure != nil && $0.endPressure != nil }
        guard validTanks.count > 1 else { return false }
        if validTanks.allSatisfy({ $0.tankType?.lowercased().contains("sidemount") == true }) { return false }
        return validTanks.contains { $0.usageStartTime == nil || $0.usageEndTime == nil }
    }

    /// True when there are multiple tanks with volume but at least one is missing full usage time data,
    /// making an accurate combined SAC impossible to compute.
    /// Sidemount-only tanks are exempt — they are breathed simultaneously for the full dive.
    var combinedSACNeedsUsageTime: Bool {
        let validTanks = tanks.filter { ($0.volume ?? 0) > 0 && $0.startPressure != nil && $0.endPressure != nil }
        guard validTanks.count > 1 else { return false }
        if validTanks.allSatisfy({ $0.tankType?.lowercased().contains("sidemount") == true }) { return false }
        return validTanks.contains { $0.usageStartTime == nil || $0.usageEndTime == nil }
    }

    /// Combined SAC: combinedRMV divided by the usage-time-weighted average tank volume.
    /// For a single tank, usage time is not required.
    /// For multiple tanks, all tanks must have usage time recorded — returns 0 otherwise.
    var combinedSAC: Double {
        let rmv = combinedRMV
        guard rmv > 0 else { return 0.0 }
        let validTanks = tanks.filter { ($0.volume ?? 0) > 0 }
        guard !validTanks.isEmpty else { return 0.0 }

        let tanksWithTime = validTanks.filter { $0.usageStartTime != nil && $0.usageEndTime != nil }
        let avgVolumeLiters: Double

        if tanksWithTime.count == validTanks.count {
            // All tanks have usage times: use time-weighted average volume.
            let totalWeight = tanksWithTime.reduce(0.0) { $0 + ($1.usageEndTime! - $1.usageStartTime!) }
            if totalWeight > 0 {
                avgVolumeLiters = tanksWithTime.reduce(0.0) { sum, tank in
                    let duration = tank.usageEndTime! - tank.usageStartTime!
                    let vol = waterVolumeLiters(rawVolume: tank.volume!, workingPressureRaw: tank.workingPressure)
                    return sum + vol * (duration / totalWeight)
                }
            } else {
                // All usage durations are zero — use simple average as last resort.
                let total = validTanks.reduce(0.0) { $0 + waterVolumeLiters(rawVolume: $1.volume!, workingPressureRaw: $1.workingPressure) }
                avgVolumeLiters = total / Double(validTanks.count)
            }
        } else if validTanks.count == 1 {
            // Single tank: usage time not needed.
            avgVolumeLiters = waterVolumeLiters(rawVolume: validTanks[0].volume!, workingPressureRaw: validTanks[0].workingPressure)
        } else if validTanks.allSatisfy({ $0.tankType?.lowercased().contains("sidemount") == true }) {
            // All-sidemount without usage times: assume full dive usage → simple average volume.
            let total = validTanks.reduce(0.0) { $0 + waterVolumeLiters(rawVolume: $1.volume!, workingPressureRaw: $1.workingPressure) }
            avgVolumeLiters = total / Double(validTanks.count)
        } else {
            // Multiple tanks with incomplete usage times: cannot compute an accurate SAC.
            return 0.0
        }

        let sac = rmv / avgVolumeLiters
        return sac > 0 && sac < 20 ? sac : 0.0
    }

    /// Formatted combined SAC across all tanks.
    var formattedCombinedSAC: String {
        let sac = combinedSAC
        guard sac > 0 else { return "—" }
        let displaySac = UserPreferences.shared.pressureUnit.convertFromBar(sac)
        let unit = UserPreferences.shared.pressureUnit.symbol
        return String(format: "%.2f \(unit)/min", displaySac)
    }

    /// SAC expressed in the user's preferred pressure unit per minute.
    ///
    /// `calculatedSAC` always returns bar/min (the canonical internal unit).
    /// This property converts that to the user's display pressure unit before
    /// formatting, so the result reads as `psi/min` when the user prefers PSI.
    ///
    /// Returns `nil` when SAC cannot be computed.
    var displaySAC: Double? {
        let sac = calculatedSAC
        guard sac > 0 else { return nil }
        // SAC is bar/min internally; convert bar → display pressure unit.
        return UserPreferences.shared.pressureUnit.convertFromBar(sac)
    }

    /// Formatted SAC string with the correct pressure-per-minute unit label,
    /// respecting the user's display pressure preference (bar/min or psi/min).
    ///
    /// Returns `"—"` when SAC cannot be computed.
    var formattedSAC: String {
        guard let sac = displaySAC else { return "—" }
        let unit = UserPreferences.shared.pressureUnit.symbol
        return String(format: "%.2f \(unit)/min", sac)
    }

    /// `true` when both pressure and volume are stored in units that allow a
    /// direct bar × litre RMV calculation without needing working-pressure
    /// inference (i.e. the import was fully metric: bar + litres).
    var isRMVInNativeUnits: Bool {
        storedPressureUnit == .bar && storedVolumeUnit == .liters
    }

    /// Formatted RMV string.
    ///
    /// When the user's preferred pressure unit is PSI, RMV is expressed in
    /// **cu ft/min** (cubic feet per minute at the surface), since that is the
    /// natural companion to PSI-based diving.  The working pressure is already
    /// factored into `calculatedRMV` via `waterVolumeLiters`, so no additional
    /// conversion is needed — only the final display unit changes.
    ///
    /// In all other cases (bar / Pa) the value is shown in **L/min**.
    ///
    /// When the import was not in bar + litres, a `*` suffix is appended to
    /// indicate that working-pressure inference was required.
    ///
    /// Returns `"—"` when RMV cannot be computed.
    var formattedRMV: String {
        let rmvLiters = calculatedRMV
        guard rmvLiters > 0 else { return "—" }

        let displayPreference = UserPreferences.shared.pressureUnit

        let valueString: String
        if displayPreference == .psi {
            // Convert L/min → cu ft/min (1 cu ft = 28.3168 L)
            let rmvCuFt = rmvLiters / 28.3168
            valueString = String(format: "%.3f cu ft/min", rmvCuFt)
        } else {
            valueString = String(format: "%.2f L/min", rmvLiters)
        }

        return isRMVInNativeUnits ? valueString : valueString + " *"
    }

    /// Footnote explaining the `*` suffix on `formattedRMV`.
    /// `nil` when no footnote is needed (import was already bar + litres).
    var rmvFootnote: String? {
        guard !isRMVInNativeUnits else { return nil }
        let bundle = Bundle.forAppLanguage()
        let displayPreference = UserPreferences.shared.pressureUnit
        if displayPreference == .psi {
            let fmt = NSLocalizedString("* RMV derived from %@ + %@ using stored working pressure for cu ft → L conversion", bundle: bundle, comment: "")
            return String(format: fmt, storedPressureUnit.symbol, storedVolumeUnit.symbol)
        }
        let fmt = NSLocalizedString("* RMV calculated from %@ + %@ — only natively available in bar/L", bundle: bundle, comment: "")
        return String(format: fmt, storedPressureUnit.symbol, storedVolumeUnit.symbol)
    }
    
    /// Localized surface interval for display.
    /// The database stores English abbreviations (e.g. "1d 2h 30m").
    /// This property replaces the day abbreviation for the current app language
    /// (e.g. "d" → "j" in French). Hours and minutes abbreviations are unchanged.
    var displaySurfaceInterval: String {
        let locale = UserPreferences.shared.languageMode.locale ?? Locale.current
        guard locale.language.languageCode?.identifier == "fr" else {
            return surfaceInterval
        }
        return surfaceInterval.replacingOccurrences(
            of: #"(\d+)d "#,
            with: "$1j ",
            options: .regularExpression
        )
    }

    // MARK: Initialization
    
    init(
        id: UUID = UUID(),
        diveNumber: Int? = nil,
        identifier: String? = nil,
        timestamp: Date = .now,
        location: String = String(localized: "Unknown"),
        siteName: String = String(localized: "Dive site"),
        diveTypes: String? = nil,
        tags: String? = nil,
        computerName: String = "Shearwater Perdix 2",
        computerSerialNumber: String? = nil,
        surfaceInterval: String = "0h 00m",
        diverName: String = String(localized: "Diver"),
        buddies: String = "",
        rating: Int = 0,
        isRepetitiveDive: Bool = false,
        weights: Double? = nil,
        weather: String? = nil,
        surfaceConditions: String? = nil,
        current: String? = nil,
        visibility: String? = nil,
        entryType: String? = nil,
        diveOperator: String? = nil,
        diveMaster: String? = nil,
        skipper: String? = nil,
        boat: String? = nil,
        maxDepth: Double = 0.0,
        averageDepth: Double = 0.0,
        duration: Int = 0,
        waterTemperature: Double = 20.0,
        minTemperature: Double = 18.0,
        airTemperature: Double? = nil,
        maxTemperature: Double? = nil,
        decompressionAlgorithm: String? = nil,
        cnsPercentage: Double? = nil,
        isDecompressionDive: Bool = false,
        notes: String = "",
        importDistanceUnit: String = "meters",
        importTemperatureUnit: String = "°c",
        importPressureUnit: String = "bar",
        importVolumeUnit: String = "liters",
        importWeightUnit: String = "kg",
        sourceImport: String? = nil,
        siteCountry: String? = nil,
        siteBodyOfWater: String? = nil,
        siteDifficulty: String? = nil,
        siteWaterType: String? = nil,
        siteAltitude: Double? = nil,
        siteLatitude: Double? = nil,
        siteLongitude: Double? = nil,
        profileSamples: [DiveProfilePoint] = [],
        decoStops: [DecoStop] = []
    ) {
        self.id = id
        self.diveNumber = diveNumber
        self.identifier = identifier
        self.timestamp = timestamp
        self.location = location
        self.siteName = siteName
        self.diveTypes = diveTypes
        self.tags = tags
        self.computerName = computerName
        self.computerSerialNumber = computerSerialNumber
        self.surfaceInterval = surfaceInterval
        self.diverName = diverName
        self.buddies = buddies
        self.rating = rating
        self.isRepetitiveDive = isRepetitiveDive
        self.weights = weights
        self.weather = weather
        self.surfaceConditions = surfaceConditions
        self.current = current
        self.visibility = visibility
        self.entryType = entryType
        self.diveOperator = diveOperator
        self.diveMaster = diveMaster
        self.skipper = skipper
        self.boat = boat
        self.maxDepth = maxDepth
        self.averageDepth = averageDepth
        self.duration = duration
        self.waterTemperature = waterTemperature
        self.minTemperature = minTemperature
        self.airTemperature = airTemperature
        self.maxTemperature = maxTemperature
        self.decompressionAlgorithm = decompressionAlgorithm
        self.cnsPercentage = cnsPercentage
        self.isDecompressionDive = isDecompressionDive
        self.notes = notes
        self.importDistanceUnit = importDistanceUnit
        self.importTemperatureUnit = importTemperatureUnit
        self.importPressureUnit = importPressureUnit
        self.importVolumeUnit = importVolumeUnit
        self.importWeightUnit = importWeightUnit
        self.sourceImport = sourceImport
        self.siteCountry = siteCountry
        self.siteBodyOfWater = siteBodyOfWater
        self.siteDifficulty = siteDifficulty
        self.siteWaterType = siteWaterType
        self.siteAltitude = siteAltitude
        self.siteLatitude = siteLatitude
        self.siteLongitude = siteLongitude
        self.photosData = []
        self.seenFish = []
        self.usedGear = []
        
        // Encoder le profil
        self.profileData = try? JSONEncoder().encode(profileSamples)
        self.decoStopsData = try? JSONEncoder().encode(decoStops)
    }
}

// MARK: - Extensions

extension Dive {
    /// Durée formatée en heures, minutes et secondes, préférant les secondes depuis le profil ou heuristique
    var formattedDuration: String {
        // Prefer precise seconds from profile if available
        let samples = profileSamples
        let secondsFromProfile: Int? = {
            if let last = samples.last?.time, last > 0 { // time is stored in minutes with fractional part
                return Int(round(last * 60))
            }
            return nil
        }()
        
        // Fallback to seconds from MacDive duration if `duration` appears to be seconds (heuristic)
        // If duration value is large (>= 3600), consider it as seconds already
        let secondsHeuristic: Int? = (duration >= 3600) ? duration : nil
        
        // Final fallback: treat stored `duration` as minutes
        let secondsFromMinutes = duration * 60
        
        let totalSeconds = secondsFromProfile ?? secondsHeuristic ?? secondsFromMinutes
        
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        
        if h > 0 {
            return String(format: "%dh %02dm %02ds", h, m, s)
        } else if m > 0 {
            return String(format: "%dm %02ds", m, s)
        } else {
            return String(format: "%ds", s)
        }
    }

    /// Durée compacte pour les vignettes et listes — ex: "1h 36m 12s" ou "42m 30s"
    var shortFormattedDuration: String {
        let samples = profileSamples
        let secondsFromProfile: Int? = {
            if let last = samples.last?.time, last > 0 {
                return Int(round(last * 60))
            }
            return nil
        }()
        let secondsHeuristic: Int? = (duration >= 3600) ? duration : nil
        let totalSeconds = secondsFromProfile ?? secondsHeuristic ?? (duration * 60)

        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "%dh %02dm %02ds", h, m, s)
        } else {
            return String(format: "%dm %02ds", m, s)
        }
    }

    /// Display label derived from tanks[0] O2/He values.
    var formattedGasType: String {
        switch gasType {
        case "Trimix":
            return "Trimix \(oxygenPercentage)/\(heliumPercentage ?? 0)"
        case "Nitrox":
            return "Nitrox \(oxygenPercentage)%"
        default:
            return gasType
        }
    }
    
    /// Consommation d'air totale en litres
    var totalAirConsumption: Double {
        var totalLiters = 0.0
        for tank in tanks {
            guard let sp = tank.startPressure,
                  let ep = tank.endPressure,
                  let volume = tank.volume,
                  volume > 0, sp > ep else { continue }
            let startBar     = PressureUnit.bar.convert(sp, from: storedPressureUnit)
            let endBar       = PressureUnit.bar.convert(ep, from: storedPressureUnit)
            let consumedBar  = startBar - endBar
            let volumeLiters = waterVolumeLiters(rawVolume: volume, workingPressureRaw: tank.workingPressure)
            let tankTypeLC   = tank.tankType?.lowercased() ?? ""
            let tankMultiplier: Double = (tankTypeLC.contains("twin") || tankTypeLC.contains("double")) ? 2.0 : 1.0
            totalLiters += consumedBar * volumeLiters * tankMultiplier
        }
        return totalLiters
    }
}
