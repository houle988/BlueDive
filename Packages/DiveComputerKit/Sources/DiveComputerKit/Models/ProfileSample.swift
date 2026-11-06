import Foundation

/// One point of the dive profile, in libdivecomputer units (seconds, metres, °C, bar).
///
/// A point is emitted per sample interval, plus a separate point at the same time for
/// each event and each synthesized gas change. Values carry forward between intervals
/// except `pressures`, `po2` and `sensorPPO2` (this interval only) and, for computers
/// that report the setpoint on every sample, `setpoint`.
public struct ProfileSample: Sendable, Hashable {
    /// Seconds from the start of the dive.
    public var time: TimeInterval
    /// Metres.
    public var depth: Double
    public var temperature: Double?
    /// Bar: the last pressure reported for any tank (carried forward).
    public var pressure: Double?
    /// Bar, per tank index, reported in this interval.
    public var pressures: [Int: Double]
    /// Bar: the computer's voted / computed PPO₂ (`DC_SENSOR_NONE`).
    public var po2: Double?
    /// Bar, per oxygen sensor, reported in this interval.
    public var sensorPPO2: [Int: Double]
    public var pn2: Double?
    public var phe: Double?
    public var events: [SampleEvent]
    /// Seconds of no-decompression time (deco sample of type NDL).
    public var ndl: UInt32?
    /// Metres: ceiling / stop depth (deco sample of type deco stop).
    public var decoStop: Double?
    /// Seconds at the stop (deco sample of type deco stop).
    public var decoTime: UInt32?
    /// Seconds: time to surface (any deco sample).
    public var tts: UInt32?
    /// Gas mix index.
    public var currentGas: Int?
    /// Percent.
    public var cns: Double?
    /// Minutes.
    public var rbt: UInt32?
    public var heartbeat: UInt32?
    /// Degrees.
    public var bearing: UInt32?
    /// Bar: the CCR setpoint in effect at this point (nil on open circuit / bailout).
    public var setpoint: Double?

    public init(
        time: TimeInterval,
        depth: Double,
        temperature: Double? = nil,
        pressure: Double? = nil,
        pressures: [Int: Double] = [:],
        po2: Double? = nil,
        sensorPPO2: [Int: Double] = [:],
        pn2: Double? = nil,
        phe: Double? = nil,
        events: [SampleEvent] = [],
        ndl: UInt32? = nil,
        decoStop: Double? = nil,
        decoTime: UInt32? = nil,
        tts: UInt32? = nil,
        currentGas: Int? = nil,
        cns: Double? = nil,
        rbt: UInt32? = nil,
        heartbeat: UInt32? = nil,
        bearing: UInt32? = nil,
        setpoint: Double? = nil
    ) {
        self.time = time
        self.depth = depth
        self.temperature = temperature
        self.pressure = pressure
        self.pressures = pressures
        self.po2 = po2
        self.sensorPPO2 = sensorPPO2
        self.pn2 = pn2
        self.phe = phe
        self.events = events
        self.ndl = ndl
        self.decoStop = decoStop
        self.decoTime = decoTime
        self.tts = tts
        self.currentGas = currentGas
        self.cns = cns
        self.rbt = rbt
        self.heartbeat = heartbeat
        self.bearing = bearing
        self.setpoint = setpoint
    }
}

/// A profile event (`DC_SAMPLE_EVENT` types BlueDive shows, plus synthesized gas changes).
public enum SampleEvent: Sendable, Hashable {
    case ascent
    case violation
    case decoStop
    case gasChange
    case bookmark
    case safetyStop(mandatory: Bool)
    case ceiling
    case po2
    case deepStop
}
