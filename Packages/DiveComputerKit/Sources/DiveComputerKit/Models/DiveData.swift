import Foundation

/// One dive as parsed from the dive computer's raw bytes.
///
/// Units are libdivecomputer's: metres, °C, bar, litres, seconds. Values are never
/// converted or estimated (except where documented: `avgDepth` falls back to the
/// time-weighted profile average and `maxDepth` to the deepest sample when the
/// computer does not report them). Field names match the former LibDCSwift `DiveData`.
public struct DiveData: Identifiable, Sendable {
    public var id = UUID()

    /// Provisional dive number given by the caller (newest = 1 during a download).
    public var number: Int
    public var datetime: Date
    /// Metres.
    public var maxDepth: Double
    /// Metres.
    public var avgDepth: Double
    /// Seconds: the time of the last profile sample (not the computer's dive time).
    public var divetime: TimeInterval
    /// Seconds: the dive time reported by the computer (`DC_FIELD_DIVETIME`), nil when
    /// not reported, 0, or over 48 h.
    public var reportedDivetime: TimeInterval?
    /// °C: the minimum temperature; `+infinity` when the computer has no thermometer.
    public var temperature: Double
    public var profile: [ProfileSample]
    /// Bar: every tank pressure sample, all tanks, in order.
    public var tankPressure: [Double]
    /// Last gas mix index the computer switched to (`DC_SAMPLE_GASMIX`).
    public var gasMix: Int?
    public var gasMixCount: Int?
    public var gasMixes: [GasMix]?
    /// g/cm³ (e.g. 1.000 fresh, 1.025 salt).
    public var salinity: Double?
    /// Bar: surface pressure, nil unless reported within 0.4…1.2 bar.
    public var atmospheric: Double?
    /// °C: the computer's surface temperature, else the first sample's temperature.
    public var surfaceTemperature: Double?
    /// °C: only the computer's surface temperature (`DC_FIELD_TEMPERATURE_SURFACE`).
    public var measuredSurfaceTemperature: Double?
    public var minTemperature: Double?
    public var maxTemperature: Double?
    public var tankCount: Int?
    /// Every tank the computer reports; empty when it reports none.
    public var tanks: [Tank]?
    public var diveMode: DiveMode?
    public var decoModel: DecoModel?
    /// Entry position (first GPS fix).
    public var location: Location?
    /// Exit position (last GPS fix after the first).
    public var exitLocation: Location?
    /// Minutes (last reported).
    public var rbt: UInt32?
    public var heartbeat: UInt32?
    /// Degrees (last reported).
    public var bearing: UInt32?
    /// Bar (last reported).
    public var setpoint: Double?
    /// Physical oxygen sensor readings, in order.
    public var ppo2Readings: [PPO2Reading]
    /// Percent (last reported).
    public var cns: Double?
    /// The last deco sample, any type.
    public var decoStop: DecoStop?
    /// Raw dive bytes as downloaded (attached by the session, not the parser).
    public var rawData: Data?
    /// libdivecomputer fingerprint of this dive (attached by the session).
    public var fingerprint: Data?

    public init(
        number: Int,
        datetime: Date,
        maxDepth: Double,
        avgDepth: Double,
        divetime: TimeInterval,
        reportedDivetime: TimeInterval? = nil,
        temperature: Double,
        profile: [ProfileSample] = [],
        tankPressure: [Double] = [],
        gasMix: Int? = nil,
        gasMixCount: Int? = nil,
        gasMixes: [GasMix]? = nil,
        salinity: Double? = nil,
        atmospheric: Double? = nil,
        surfaceTemperature: Double? = nil,
        measuredSurfaceTemperature: Double? = nil,
        minTemperature: Double? = nil,
        maxTemperature: Double? = nil,
        tankCount: Int? = nil,
        tanks: [Tank]? = nil,
        diveMode: DiveMode? = nil,
        decoModel: DecoModel? = nil,
        location: Location? = nil,
        exitLocation: Location? = nil,
        rbt: UInt32? = nil,
        heartbeat: UInt32? = nil,
        bearing: UInt32? = nil,
        setpoint: Double? = nil,
        ppo2Readings: [PPO2Reading] = [],
        cns: Double? = nil,
        decoStop: DecoStop? = nil,
        rawData: Data? = nil,
        fingerprint: Data? = nil
    ) {
        self.number = number
        self.datetime = datetime
        self.maxDepth = maxDepth
        self.avgDepth = avgDepth
        self.divetime = divetime
        self.reportedDivetime = reportedDivetime
        self.temperature = temperature
        self.profile = profile
        self.tankPressure = tankPressure
        self.gasMix = gasMix
        self.gasMixCount = gasMixCount
        self.gasMixes = gasMixes
        self.salinity = salinity
        self.atmospheric = atmospheric
        self.surfaceTemperature = surfaceTemperature
        self.measuredSurfaceTemperature = measuredSurfaceTemperature
        self.minTemperature = minTemperature
        self.maxTemperature = maxTemperature
        self.tankCount = tankCount
        self.tanks = tanks
        self.diveMode = diveMode
        self.decoModel = decoModel
        self.location = location
        self.exitLocation = exitLocation
        self.rbt = rbt
        self.heartbeat = heartbeat
        self.bearing = bearing
        self.setpoint = setpoint
        self.ppo2Readings = ppo2Readings
        self.cns = cns
        self.decoStop = decoStop
        self.rawData = rawData
        self.fingerprint = fingerprint
    }
}

extension DiveData {

    /// A tank as reported by the computer (`DC_FIELD_TANK`). 0 means "not reported"
    /// for the volume and pressures.
    public struct Tank: Sendable, Hashable {
        /// Litres.
        public var volume: Double
        /// Bar.
        public var workingPressure: Double
        /// Bar.
        public var beginPressure: Double
        /// Bar.
        public var endPressure: Double
        /// Index into `gasMixes`, or 4294967295 (`DC_GASMIX_UNKNOWN`, e.g. Shearwater).
        public var gasMix: Int
        public var usage: GasUsage

        public init(volume: Double, workingPressure: Double, beginPressure: Double,
                    endPressure: Double, gasMix: Int, usage: GasUsage) {
            self.volume = volume
            self.workingPressure = workingPressure
            self.beginPressure = beginPressure
            self.endPressure = endPressure
            self.gasMix = gasMix
            self.usage = usage
        }
    }

    /// A deco sample: `type` is libdivecomputer's `dc_deco_type_t`
    /// (0 NDL, 1 safety stop, 2 deco stop, 3 deep stop).
    public struct DecoStop: Sendable, Hashable {
        /// Metres.
        public var depth: Double
        /// Seconds.
        public var time: TimeInterval
        public var type: Int

        public init(depth: Double, time: TimeInterval, type: Int) {
            self.depth = depth
            self.time = time
            self.type = type
        }
    }

    public struct Location: Sendable, Hashable {
        /// Decimal degrees.
        public var latitude: Double
        public var longitude: Double
        /// Metres.
        public var altitude: Double?

        public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
            self.latitude = latitude
            self.longitude = longitude
            self.altitude = altitude
        }
    }

    public enum DiveMode: Sendable, Hashable, CustomStringConvertible {
        case freedive, gauge, openCircuit, closedCircuit, semiClosedCircuit

        public var description: String {
            switch self {
            case .freedive: return "Freedive"
            case .gauge: return "Gauge"
            case .openCircuit: return "Open Circuit"
            case .closedCircuit: return "Closed Circuit"
            case .semiClosedCircuit: return "Semi-Closed Circuit"
            }
        }
    }

    /// The computer's decompression model (`DC_FIELD_DECOMODEL`).
    public struct DecoModel: Sendable, Hashable, CustomStringConvertible {
        public enum DecoType: Sendable, Hashable {
            case none, buhlmann, vpm, rgbm, dciem

            var name: String {
                switch self {
                case .none: return "None"
                case .buhlmann: return "Bühlmann"
                case .vpm: return "VPM"
                case .rgbm: return "RGBM"
                case .dciem: return "DCIEM"
                }
            }
        }

        public var type: DecoType
        public var conservatism: Int
        /// Gradient factors (percent), for Bühlmann; 0 for the other models.
        public var gfLow: UInt32?
        public var gfHigh: UInt32?

        public init(type: DecoType, conservatism: Int, gfLow: UInt32? = nil, gfHigh: UInt32? = nil) {
            self.type = type
            self.conservatism = conservatism
            self.gfLow = gfLow
            self.gfHigh = gfHigh
        }

        /// Persisted as `Dive.decompressionAlgorithm`: "Bühlmann GF 30/70", "Bühlmann",
        /// "None", "VPM (2)", "RGBM".
        public var description: String {
            switch type {
            case .none:
                return type.name
            case .buhlmann:
                if let low = gfLow, let high = gfHigh, low > 0 || high > 0 {
                    return "\(type.name) GF \(low)/\(high)"
                }
                return type.name
            case .vpm, .rgbm, .dciem:
                return conservatism != 0 ? "\(type.name) (\(conservatism))" : type.name
            }
        }
    }
}

/// A gas mix (`DC_FIELD_GASMIX`), fractions 0…1.
public struct GasMix: Sendable, Hashable {
    public var helium: Double
    public var oxygen: Double
    public var nitrogen: Double
    public var usage: GasUsage

    public init(helium: Double, oxygen: Double, nitrogen: Double, usage: GasUsage) {
        self.helium = helium
        self.oxygen = oxygen
        self.nitrogen = nitrogen
        self.usage = usage
    }
}

/// libdivecomputer's `dc_usage_t`.
public enum GasUsage: Sendable, Hashable {
    case none, oxygen, diluent, sidemount
}

/// One physical oxygen sensor reading (bar).
public struct PPO2Reading: Sendable, Hashable {
    public var sensor: UInt32
    public var value: Double

    public init(sensor: UInt32, value: Double) {
        self.sensor = sensor
        self.value = value
    }
}
