import Foundation

/// One libdivecomputer sample (`dc_sample_type_t` + `dc_sample_value_t`), as plain Swift.
enum SampleInput: Sendable, Equatable {
    case time(milliseconds: UInt32)
    case depth(Double)
    case pressure(tank: UInt32, bar: Double)
    case temperature(Double)
    /// A `DC_SAMPLE_EVENT`, already mapped; nil for event types BlueDive does not show.
    case event(SampleEvent?)
    case rbt(UInt32)
    case heartbeat(UInt32)
    case bearing(UInt32)
    case setpoint(Double)
    case ppo2(sensor: UInt32, bar: Double)
    /// Fraction (1.0 = 100 %).
    case cns(Double)
    case deco(type: UInt32, time: UInt32, depth: Double, tts: UInt32)
    case gasmix(UInt32)
    case location(latitude: Double, longitude: Double, altitude: Double)
    /// Vendor samples and future types: ignored.
    case ignored
}

/// Builds the profile from libdivecomputer's sample stream (Docs/BEHAVIOURAL_SPEC.md §6.1).
///
/// libdivecomputer sends a `time` sample, then the samples of that interval. A profile
/// point is written when the *next* `time` arrives (and once more by `finish()`), so
/// each point carries its own interval's values. Values carry forward between intervals,
/// except the per-interval ones (`pressures`, voted and per-sensor PPO₂, `reportedRBT`, and
/// the setpoint for computers that report it every sample).
final class SampleAccumulator {

    /// `DC_SENSOR_NONE` / `DC_GASMIX_UNKNOWN`.
    static let unknownIndex: UInt32 = 0xFFFF_FFFF

    /// The computer reports the setpoint on every sample (Shearwater, Ratio, McLean);
    /// otherwise only on changes, and it is held until the next change or a bailout.
    let setpointPerSample: Bool
    /// Gas mixes flagged diluent / oxygen; empty unless the computer flags at least one
    /// diluent (without diluent flags a bailout cannot be detected).
    let diluentIndices: Set<UInt32>
    let oxygenIndices: Set<UInt32>

    private(set) var profile: [ProfileSample] = []

    // Interval state
    private var hasSeenTime = false
    private var time: TimeInterval = 0
    private var depth: Double = 0
    private var temperature: Double?
    private var lastPressure: Double?
    private var currentPressures: [Int: Double] = [:]
    private var currentVotedPPO2: Double?
    private var currentPPO2: [Int: Double] = [:]
    private var currentSetpoint: Double?
    private var currentRBT: UInt32?
    private var onOpenCircuit = false
    private var currentGas: Int?
    private var lastRealGas: UInt32?
    private var deco: (type: UInt32, time: UInt32, depth: Double, tts: UInt32)?

    // Dive-level results
    private(set) var maxDepth: Double = 0
    private(set) var maxTime: TimeInterval = 0
    private(set) var pressureValues: [Double] = []
    private(set) var ppo2Readings: [PPO2Reading] = []
    private(set) var setpoint: Double?
    private(set) var cns: Double?
    private(set) var rbt: UInt32?
    private(set) var heartbeat: UInt32?
    private(set) var bearing: UInt32?
    private(set) var location: DiveData.Location?
    private(set) var exitLocation: DiveData.Location?
    /// Infinity sentinels: 0 °C is a valid water temperature, so 0 never means "unset".
    var tempMinimum: Double = .infinity
    var tempMaximum: Double = -.infinity
    var tempSurface: Double = .infinity
    private(set) var lastTemperature: Double?
    private(set) var lastDeco: (type: UInt32, time: UInt32, depth: Double, tts: UInt32)?

    /// The last real gas mix index the computer switched to.
    var lastGasMix: Int? { lastRealGas.map { Int($0) } }

    init(setpointPerSample: Bool, diluentIndices: Set<UInt32> = [], oxygenIndices: Set<UInt32> = []) {
        self.setpointPerSample = setpointPerSample
        self.diluentIndices = diluentIndices
        self.oxygenIndices = oxygenIndices
    }

    func add(_ sample: SampleInput) {
        switch sample {
        case .time(let milliseconds):
            if hasSeenTime { flush() }
            hasSeenTime = true
            time = TimeInterval(milliseconds) / 1000

        case .depth(let value):
            depth = value
            maxDepth = max(maxDepth, value)

        case .pressure(let tank, let bar):
            pressureValues.append(bar)
            lastPressure = bar
            currentPressures[Int(tank)] = bar

        case .temperature(let value):
            temperature = value

        case .event(let event):
            // Always a point of its own at the current time, even for unmapped types.
            profile.append(makePoint(events: event.map { [$0] } ?? []))

        case .rbt(let value):
            rbt = value
            currentRBT = value

        case .heartbeat(let value):
            heartbeat = value

        case .bearing(let value):
            bearing = value

        case .setpoint(let value):
            setpoint = value
            if !onOpenCircuit { currentSetpoint = value }

        case .ppo2(let sensor, let bar):
            if sensor == Self.unknownIndex {
                currentVotedPPO2 = bar
            } else {
                currentPPO2[Int(sensor)] = bar
                ppo2Readings.append(PPO2Reading(sensor: sensor, value: bar))
            }

        case .cns(let fraction):
            cns = fraction * 100

        case .deco(let type, let time, let depth, let tts):
            deco = (type, time, depth, tts)
            lastDeco = deco

        case .gasmix(let index):
            gasSwitch(to: index)

        case .location(let latitude, let longitude, let altitude):
            let fix = DiveData.Location(latitude: latitude, longitude: longitude, altitude: altitude)
            if location == nil { location = fix } else { exitLocation = fix }

        case .ignored:
            break
        }
    }

    /// Writes the last interval. Call once after the sample stream ends.
    func finish() {
        if hasSeenTime { flush() }
    }

    // MARK: - Private

    private func gasSwitch(to index: UInt32) {
        let isReal = index != Self.unknownIndex
        // Bailout detection for change-only setpoint computers with diluent flags.
        if !diluentIndices.isEmpty && isReal {
            if diluentIndices.contains(index) {
                onOpenCircuit = false
                currentSetpoint = setpoint
            } else if !oxygenIndices.contains(index) {
                onOpenCircuit = true
                currentSetpoint = nil
            }
        }
        // DC_GASMIX_UNKNOWN (Shearwater, for tanks without an AI transmitter) leaves the
        // last real gas in place: points never carry an unknown index.
        if isReal { currentGas = Int(index) }
        if isReal, let previous = lastRealGas, previous != index {
            let alreadyMarked = profile.last.map { $0.time == time && $0.events.contains(.gasChange) } ?? false
            if !alreadyMarked {
                profile.append(makePoint(events: [.gasChange]))
            }
        }
        if isReal { lastRealGas = index }
    }

    private func flush() {
        profile.append(makePoint(events: []))
        currentPressures = [:]
        currentPPO2 = [:]
        currentVotedPPO2 = nil
        currentRBT = nil
        if setpointPerSample { currentSetpoint = nil }
        maxTime = max(maxTime, time)
        if let temperature {
            tempMinimum = min(tempMinimum, temperature)
            tempMaximum = max(tempMaximum, temperature)
            lastTemperature = temperature
            if tempSurface == .infinity { tempSurface = temperature }
        }
    }

    /// deco types: 0 NDL, 2 deco stop (`dc_deco_type_t`).
    private func makePoint(events: [SampleEvent]) -> ProfileSample {
        ProfileSample(
            time: time,
            depth: depth,
            temperature: temperature,
            pressure: lastPressure,
            pressures: currentPressures,
            po2: currentVotedPPO2,
            sensorPPO2: currentPPO2,
            events: events,
            ndl: deco?.type == 0 ? deco?.time : nil,
            decoStop: deco?.type == 2 ? deco?.depth : nil,
            decoTime: deco?.type == 2 ? deco?.time : nil,
            tts: deco?.tts,
            currentGas: currentGas,
            cns: cns,
            rbt: rbt,
            reportedRBT: currentRBT,
            heartbeat: heartbeat,
            bearing: bearing,
            setpoint: currentSetpoint
        )
    }
}
