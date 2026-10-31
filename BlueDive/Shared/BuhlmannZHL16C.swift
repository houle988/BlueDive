import Foundation
import SwiftData

// MARK: - PPO₂ computation helpers (shared by the dive chart and the tissue model)

/// Per-dive constants used for Dalton's-Law PPO₂ computation.
/// Build once per dive; call ppo2(o2Fraction:rawDepth:) per sample.
nonisolated struct PPO2Setup {
    let depthToMetres: Double
    let surfacePressure: Double
    let waterDivisor: Double

    init(dive: Dive) {
        let isFeet = dive.importDistanceUnit == "feet"
        depthToMetres = isFeet ? 0.3048 : 1.0
        let altMeters = isFeet ? (dive.siteAltitude ?? 0) * 0.3048 : (dive.siteAltitude ?? 0)
        surfacePressure = atmosphericPressure(forAltitudeMeters: altMeters)
        waterDivisor = waterPressureDivisor(forWaterTypeString: dive.siteWaterType)
    }

    func ppo2(o2Fraction: Double, rawDepth: Double) -> Double {
        o2Fraction * (rawDepth * depthToMetres / waterDivisor + surfacePressure)
    }
}

/// Builds a per-sample representative PPO₂ map for all profile samples in `dive`.
/// Priority per sample: device voted/controller PPO₂ (DC_SENSOR_NONE) →
/// median of physical O₂ cells → computed from gas mix + depth (Dalton's Law), the last only
/// for open-circuit samples: a sample with a CCR setpoint is on the loop, where the breathed
/// PPO₂ is not the diluent's, so it gets no PPO₂ unless the computer reported one.
func buildPPO2Map(for dive: Dive) -> [UUID: Double] {
    let tanks = dive.tanks
    let setup = tanks.isEmpty ? nil : PPO2Setup(dive: dive)
    var lastKnownGasIdx: Int? = tanks.count > 1 ? 0 : nil
    var result: [UUID: Double] = [:]
    for sample in dive.profileSamples {
        if let g = sample.currentGas, g >= 0, g < tanks.count { lastKnownGasIdx = g }
        if let voted = sample.ppo2 {
            // Device-provided voted/controller value (DC_SENSOR_NONE) — Shearwater, Divesoft, Oceanic, etc.
            result[sample.id] = voted
        } else if let sensors = sample.sensorPPO2, !sensors.isEmpty {
            // Physical sensors only (OSTC, Halcyon Symbios, etc.): compute median on the fly.
            result[sample.id] = medianPPO2(sensors)
        } else if let s = setup, sample.setpoint == nil {
            // OC fallback: no sensor data — compute from gas mix + depth (Dalton's Law).
            let gasIdx: Int?
            if let idx = sample.currentGas, idx >= 0, idx < tanks.count { gasIdx = idx }
            else if tanks.count == 1 { gasIdx = 0 }
            else { gasIdx = lastKnownGasIdx }
            if let idx = gasIdx, tanks[idx].o2 > 0 {
                result[sample.id] = s.ppo2(o2Fraction: tanks[idx].o2, rawDepth: sample.depth)
            }
        }
    }
    return result
}


/// Median of the O₂ sensor readings, robust to a single degraded or outlying cell without a
/// tuning threshold. Nil when there is no reading.
nonisolated func medianPPO2(_ sensors: [Int: Double]) -> Double? {
    guard !sensors.isEmpty else { return nil }
    let sorted = sensors.values.sorted()
    let mid = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
        ? (sorted[mid - 1] + sorted[mid]) / 2.0
        : sorted[mid]
}

// MARK: - Bühlmann ZHL-16C tissue model (GF99 and Surface GF)

/// BlueDive's own implementation of the Bühlmann ZHL-16C tissue model, written from the
/// published sources, used to show GF99 and Surface GF along a recorded profile:
/// - Half-times and a/b coefficients: A. A. Bühlmann, *Tauchmedizin* (Springer, 4th ed. 1995)
///   — ZHL-16C, with compartment 1b (5 min N₂) as in most dive computers and planners.
/// - M-value line `M = a + Pamb / b` and the Schreiner equation for a linear pressure change:
///   E. C. Baker, *Understanding M-values* (1998).
/// - Gradient factor as the percentage of the M-value gradient: E. C. Baker, *Clearing Up the
///   Confusion About "Deep Stops"* (1998). GF99 is that percentage at the ambient pressure
///   and Surface GF at the surface pressure, as defined in Shearwater's computer manuals.
///
/// Neither value depends on a GF low/high setting. Nothing here is stored: the values are
/// calculated from the dive's profile, gases, altitude and water type each time they are shown.
nonisolated enum BuhlmannZHL16C {
    static let compartmentCount = 16
    /// Alveolar water vapour pressure, in bar (respiratory quotient 1, as in Bühlmann).
    static let waterVapourPressure = 0.0627
    /// N₂ fraction of air, for the tissues saturated at the surface before the dive.
    static let nitrogenInAir = 0.79

    /// N₂ half-times, in minutes.
    static let n2HalfTimes: [Double] = [5.0, 8.0, 12.5, 18.5, 27.0, 38.3, 54.3, 77.0,
                                        109.0, 146.0, 187.0, 239.0, 305.0, 390.0, 498.0, 635.0]
    /// N₂ a coefficients, in bar.
    static let n2A: [Double] = [1.1696, 1.0000, 0.8618, 0.7562, 0.6200, 0.5043, 0.4410, 0.4000,
                                0.3750, 0.3500, 0.3295, 0.3065, 0.2835, 0.2610, 0.2480, 0.2327]
    /// N₂ b coefficients.
    static let n2B: [Double] = [0.5578, 0.6514, 0.7222, 0.7825, 0.8126, 0.8434, 0.8693, 0.8910,
                                0.9092, 0.9222, 0.9319, 0.9403, 0.9477, 0.9544, 0.9602, 0.9653]
    /// He half-times, in minutes.
    static let heHalfTimes: [Double] = [1.88, 3.02, 4.72, 6.99, 10.21, 14.48, 20.53, 29.11,
                                        41.20, 55.19, 70.69, 90.34, 115.29, 147.42, 188.24, 240.03]
    /// He a coefficients, in bar.
    static let heA: [Double] = [1.6189, 1.3830, 1.1919, 1.0458, 0.9220, 0.8205, 0.7305, 0.6502,
                                0.5950, 0.5545, 0.5333, 0.5189, 0.5181, 0.5176, 0.5172, 0.5119]
    /// He b coefficients.
    static let heB: [Double] = [0.4770, 0.5747, 0.6527, 0.7223, 0.7582, 0.7957, 0.8279, 0.8553,
                                0.8757, 0.8903, 0.8997, 0.9073, 0.9122, 0.9171, 0.9217, 0.9267]

    /// Inert gas pressure of each compartment, in bar.
    struct TissueState: Sendable, Equatable {
        var n2: [Double]
        var he: [Double]
    }

    /// Inspired inert gas pressures at the start and end of the stretch between two samples,
    /// in bar. The pressures change linearly in between (the depth is linear between samples).
    struct Segment: Sendable, Equatable {
        let n2Start: Double
        let n2End: Double
        let heStart: Double
        let heEnd: Double
    }

    /// Everything the model needs, as plain values, so it can run off the main thread.
    struct Inputs: Sendable, Equatable {
        /// Sample times, in minutes.
        let times: [Double]
        /// Ambient pressure at each sample, in bar.
        let ambient: [Double]
        /// Breathed gas from each sample to the next (`times.count - 1` entries); nil where it
        /// cannot be known (on the loop with no inert gas in the gas in use, or no ppO₂).
        let segments: [Segment?]
        /// Surface pressure at the dive site, in bar.
        let surfacePressure: Double
        /// True when a calculated loop stretch (before any stretch whose gas is unknown) used the
        /// CCR setpoint as the breathed ppO₂ because the computer recorded no ppO₂ there (no
        /// voted value, no O₂ cell); the chart says so.
        var usesSetpointAsPPO2: Bool = false
    }

    /// GF99 and Surface GF, in percent of the M-value gradient (0 at ambient, 100 at the
    /// raw Bühlmann limit). Negative while the leading compartment is not supersaturated.
    struct Values: Sendable, Equatable {
        let gf99: Double
        let surfaceGF: Double
    }

    /// Tissues saturated with air at the dive site's surface pressure.
    static func surfaceState(surfacePressure: Double) -> TissueState {
        let n2 = max(0, surfacePressure - waterVapourPressure) * nitrogenInAir
        return TissueState(n2: Array(repeating: n2, count: compartmentCount),
                           he: Array(repeating: 0, count: compartmentCount))
    }

    /// Inspired inert pressures for one breathing state at `ambient` bar, or nil when they
    /// cannot be known. Open circuit: the gas's N₂ and He fractions of the inspired pressure.
    /// On the loop: the inspired pressure less the ppO₂ (never below 0), split by the gas in
    /// use's N₂:He ratio.
    static func inspired(ambient: Double, n2Fraction: Double, heFraction: Double,
                         loopPPO2: Double?, onLoop: Bool) -> (n2: Double, he: Double)? {
        let inspired = max(0, ambient - waterVapourPressure)
        guard onLoop else { return (inspired * n2Fraction, inspired * heFraction) }
        let inertFraction = n2Fraction + heFraction
        guard let ppo2 = loopPPO2, ppo2.isFinite, inertFraction > 0 else { return nil }
        let inert = max(0, inspired - ppo2)
        return (inert * n2Fraction / inertFraction, inert * heFraction / inertFraction)
    }

    /// Advances `state` by `elapsed` minutes into `segment`, which lasts `segmentMinutes`.
    /// Schreiner equation, exact for a linearly changing inspired pressure:
    /// P(t) = Pi + R (t − 1/k) − (Pi − P0 − R/k) e^(−kt), with k = ln 2 / half-time.
    static func advance(_ state: TissueState, through segment: Segment,
                        segmentMinutes: Double, elapsed: Double) -> TissueState {
        guard segmentMinutes > 0, elapsed > 0 else { return state }
        let rateN2 = (segment.n2End - segment.n2Start) / segmentMinutes
        let rateHe = (segment.heEnd - segment.heStart) / segmentMinutes
        var next = state
        for i in 0..<compartmentCount {
            next.n2[i] = schreiner(start: state.n2[i], inspired: segment.n2Start, rate: rateN2,
                                   halfTime: n2HalfTimes[i], time: elapsed)
            next.he[i] = schreiner(start: state.he[i], inspired: segment.heStart, rate: rateHe,
                                   halfTime: heHalfTimes[i], time: elapsed)
        }
        return next
    }

    private static func schreiner(start: Double, inspired: Double, rate: Double,
                                  halfTime: Double, time: Double) -> Double {
        let k = M_LN2 / halfTime
        return inspired + rate * (time - 1 / k) - (inspired - start - rate / k) * exp(-k * time)
    }

    /// GF99 at `ambient` and Surface GF at `surface`: the highest value across the 16
    /// compartments of (P − p) / (M(p) − p) × 100, with a and b weighted by the compartment's
    /// N₂ and He pressures.
    static func gradientFactors(_ state: TissueState, ambient: Double, surface: Double) -> Values {
        var gf99 = -Double.greatestFiniteMagnitude
        var surfaceGF = -Double.greatestFiniteMagnitude
        for i in 0..<compartmentCount {
            let n2 = state.n2[i], he = state.he[i]
            let total = n2 + he
            guard total > 0 else { continue }
            let a = (n2A[i] * n2 + heA[i] * he) / total
            let b = (n2B[i] * n2 + heB[i] * he) / total
            gf99 = max(gf99, (total - ambient) / (a + ambient / b - ambient) * 100)
            surfaceGF = max(surfaceGF, (total - surface) / (a + surface / b - surface) * 100)
        }
        return Values(gf99: gf99, surfaceGF: surfaceGF)
    }

    /// `state` after `minutes` at the surface breathing air at `surfacePressure` bar.
    static func surfaceInterval(_ state: TissueState, minutes: Double, surfacePressure: Double) -> TissueState {
        let n2 = max(0, surfacePressure - waterVapourPressure) * nitrogenInAir
        let air = Segment(n2Start: n2, n2End: n2, heStart: 0, heEnd: 0)
        return advance(state, through: air, segmentMinutes: minutes, elapsed: minutes)
    }

    /// Tissue state at each sample, from `start` at the first sample (tissues saturated at the
    /// surface when nil). From the first stretch whose breathed gas cannot be known, the states
    /// are nil: the tissue history is unknown from there on. A stretch with no duration (two
    /// samples at the same time, or out of order) leaves the state unchanged.
    static func states(for inputs: Inputs, start: TissueState? = nil) -> [TissueState?] {
        guard !inputs.times.isEmpty else { return [] }
        var result: [TissueState?] = [start ?? surfaceState(surfacePressure: inputs.surfacePressure)]
        result.reserveCapacity(inputs.times.count)
        for i in 0..<(inputs.times.count - 1) {
            guard let state = result[i], let segment = inputs.segments[i] else {
                result.append(nil)
                continue
            }
            let dt = inputs.times[i + 1] - inputs.times[i]
            guard dt.isFinite, dt > 0 else {
                result.append(state)
                continue
            }
            result.append(advance(state, through: segment, segmentMinutes: dt, elapsed: dt))
        }
        return result
    }
}

// MARK: - Residual loading from earlier dives

nonisolated extension BuhlmannZHL16C {
    /// Earlier dives whose loading can still be in the tissues are those less than this long
    /// before the next dive (end to start), chained back dive by dive. The Bühlmann model
    /// itself sets no limit (tissues never fully clear); after 48 h the slowest N₂ compartment
    /// (635 min) keeps about 4 % of its excess, and a longer window would not change GF99 or
    /// Surface GF, which the faster compartments set.
    static let residualWindow: TimeInterval = 48 * 3600

    /// Earlier dives are looked up at most this far back from the dive's start (and at most
    /// `residualMaximumDives` of them), so a long run of daily diving never decodes months of
    /// profiles. Loading left from dives that started more than 5 days earlier does not change
    /// GF99 or Surface GF at the precision shown (the fast compartments, long cleared, set them).
    static let residualSpan: TimeInterval = 5 * 86400
    static let residualMaximumDives = 50

    /// An earlier dive of the same diver: its start, the end of its recorded profile, and its
    /// tissue-model inputs (nil when it has no profile or no tank).
    struct PriorDive: Sendable {
        let start: Date
        let end: Date
        let inputs: Inputs?

        /// Whether the whole dive can be calculated: it has inputs and every stretch's gas is
        /// known (a dive with an unknown mix, or an unknown diluent on the loop, cannot).
        var isCalculable: Bool {
            inputs?.segments.allSatisfy { $0 != nil } ?? false
        }
    }

    /// Tissue state a dive starts with after `priorDives`.
    struct Residual: Sendable, Equatable {
        /// The starting state, or nil to start with tissues saturated at the surface (no
        /// earlier dive in the window, or one of them could not be calculated).
        let state: TissueState?
        /// Number of earlier dives whose loading is included.
        let includedDives: Int
        /// True when an earlier dive in the window could not be calculated (no profile, no
        /// tank, or an unknown gas on the loop), so the dive starts clean instead.
        let missingDive: Bool
        /// True when an included earlier dive used a CCR setpoint as its ppO₂ somewhere
        /// (`Inputs.usesSetpointAsPPO2`).
        var usesSetpointAsPPO2: Bool = false

        static let clean = Residual(state: nil, includedDives: 0, missingDive: false)
    }

    /// The tissue state at the start of a dive beginning at `diveStart`, at a site with
    /// `surfacePressure` bar, after `priorDives` (its earlier dives, in any order). The chain
    /// is built back from the dive: an earlier dive is included while it ended less than
    /// `residualWindow` before the next one started. The first dive of the chain starts with
    /// tissues saturated at its own surface pressure; each surface interval is breathed at
    /// the next dive's surface pressure. An earlier dive that ends after the next one started
    /// overlaps it: it is the same dive recorded by another computer (kept as its own dive),
    /// not a previous dive, so only one of the copies is chained (the one that can be
    /// calculated, when only one can) rather than loading the tissues twice; a copy of the dive
    /// itself is skipped. If any dive of the chain cannot be calculated, nothing is carried
    /// over (`missingDive`): no loading is guessed for it.
    static func residual(priorDives: [PriorDive], diveStart: Date, surfacePressure: Double) -> Residual {
        var chain: [PriorDive] = []
        var nextStart = diveStart
        for prior in priorDives.filter({ $0.start < diveStart }).sorted(by: { $0.start > $1.start }) {
            if prior.end > nextStart {
                // A copy of the dive chained last: keep the copy that can be calculated.
                if let kept = chain.first, !kept.isCalculable, prior.isCalculable {
                    chain[0] = prior
                    nextStart = prior.start
                }
                continue
            }
            guard nextStart.timeIntervalSince(prior.end) < residualWindow else { break }
            chain.insert(prior, at: 0)
            nextStart = prior.start
        }
        guard !chain.isEmpty else { return .clean }
        guard chain.allSatisfy({ $0.inputs != nil }) else {
            return Residual(state: nil, includedDives: 0, missingDive: true)
        }
        var state: TissueState? = nil
        for (index, prior) in chain.enumerated() {
            guard let inputs = prior.inputs,
                  let end = BuhlmannZHL16C.states(for: inputs, start: state).last ?? nil else {
                return Residual(state: nil, includedDives: 0, missingDive: true)
            }
            let isLast = index == chain.count - 1
            let followingStart = isLast ? diveStart : chain[index + 1].start
            let followingSurface = isLast ? surfacePressure : (chain[index + 1].inputs?.surfacePressure ?? surfacePressure)
            let minutes = max(0, followingStart.timeIntervalSince(prior.end)) / 60
            state = surfaceInterval(end, minutes: minutes, surfacePressure: followingSurface)
        }
        return Residual(state: state, includedDives: chain.count, missingDive: false,
                        usesSetpointAsPPO2: chain.contains { $0.inputs?.usesSetpointAsPPO2 == true })
    }
}

/// The tissue states along one dive's profile, and GF99 / Surface GF at any time of it.
/// Display only: built when the chart shows the dive, never stored.
nonisolated struct BuhlmannProfile: Sendable, Equatable {
    let inputs: BuhlmannZHL16C.Inputs
    let states: [BuhlmannZHL16C.TissueState?]
    /// The loading carried over from earlier dives (`BuhlmannZHL16C.residual`).
    let residual: BuhlmannZHL16C.Residual

    init(inputs: BuhlmannZHL16C.Inputs, residual: BuhlmannZHL16C.Residual = .clean) {
        self.inputs = inputs
        self.residual = residual
        self.states = BuhlmannZHL16C.states(for: inputs, start: residual.state)
    }

    /// GF99 and Surface GF at `time` minutes: exact at that moment (the state is advanced from
    /// the previous sample), the sample's own values before the first and after the last
    /// sample, nil where the tissue history is unknown.
    func values(atMinutes time: Double) -> BuhlmannZHL16C.Values? {
        let times = inputs.times
        guard let first = times.first, let last = times.last else { return nil }
        if time <= first { return values(atSample: 0) }
        if time >= last { return values(atSample: times.count - 1) }
        // Last sample at or before `time` (samples are time-sorted).
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] <= time { lo = mid + 1 } else { hi = mid }
        }
        let i = lo - 1
        guard i >= 0, i < times.count - 1 else { return values(atSample: max(0, min(i, times.count - 1))) }
        // At a sample's own time its value is known, even where the next stretch is not.
        if times[i] == time { return values(atSample: i) }
        // Between two samples whose gas is unknown, nothing is known: no value is held over.
        guard let segment = inputs.segments[i] else { return nil }
        let dt = times[i + 1] - times[i]
        guard dt > 0, let state = states[i] else { return values(atSample: i) }
        let elapsed = time - times[i]
        let advanced = BuhlmannZHL16C.advance(state, through: segment, segmentMinutes: dt, elapsed: elapsed)
        let ambient = inputs.ambient[i] + (inputs.ambient[i + 1] - inputs.ambient[i]) * elapsed / dt
        return BuhlmannZHL16C.gradientFactors(advanced, ambient: ambient, surface: inputs.surfacePressure)
    }

    /// GF99 and Surface GF at sample `index`, nil where the tissue history is unknown.
    func values(atSample index: Int) -> BuhlmannZHL16C.Values? {
        guard states.indices.contains(index), let state = states[index] else { return nil }
        return BuhlmannZHL16C.gradientFactors(state, ambient: inputs.ambient[index],
                                               surface: inputs.surfacePressure)
    }
}

/// The tissue model's inputs for `samples` breathed from `tanks`, or nil when the dive has no
/// profile or no tank (no gas is assumed). Depth is converted to metres with `depthToMetres`,
/// then to pressure with the water type's `waterDivisor` (m/bar) above `surfacePressure` bar.
/// The gas in use is the sample's `currentGas`, carried forward from the last sample that gave
/// one (the first tank before any), as for the chart's PPO₂. A tank with no O₂ (or fractions
/// over 100 %) is an unknown mix, not pure inert gas: its stretches cannot be calculated, as
/// the chart's PPO₂ leaves them out. A sample with a CCR setpoint is on
/// the loop, breathing the computer's ppO₂ (voted value, else the median O₂ cell, else the
/// setpoint, which `usesSetpointAsPPO2` records so the chart can say so); a stretch takes the
/// gas and breathing mode of the sample that starts it.
nonisolated func buhlmannInputs(samples: [DiveProfilePoint], tanks: [TankData],
                    depthToMetres: Double, surfacePressure: Double,
                    waterDivisor: Double) -> BuhlmannZHL16C.Inputs? {
    guard !samples.isEmpty, !tanks.isEmpty, waterDivisor > 0 else { return nil }
    var times: [Double] = []
    var ambient: [Double] = []
    var gasIndex: [Int] = []
    times.reserveCapacity(samples.count)
    ambient.reserveCapacity(samples.count)
    gasIndex.reserveCapacity(samples.count)
    var lastKnownGas = 0
    for sample in samples {
        if let g = sample.currentGas, g >= 0, g < tanks.count { lastKnownGas = g }
        times.append(sample.time)
        ambient.append(max(0, sample.depth) * depthToMetres / waterDivisor + surfacePressure)
        gasIndex.append(lastKnownGas)
    }
    /// The breathed ppO₂ on the loop, and whether it is the setpoint (nothing recorded).
    func loopPPO2(_ sample: DiveProfilePoint) -> (value: Double, isSetpoint: Bool)? {
        if let voted = sample.ppo2, voted.isFinite { return (voted, false) }
        if let sensors = sample.sensorPPO2, let median = medianPPO2(sensors), median.isFinite { return (median, false) }
        return sample.setpoint.map { ($0, true) }
    }
    // Whether each stretch used a setpoint as its ppO₂ (only stretches that are calculated).
    var setpointStretches: [Bool] = []
    setpointStretches.reserveCapacity(max(0, samples.count - 1))
    var segments: [BuhlmannZHL16C.Segment?] = []
    segments.reserveCapacity(max(0, samples.count - 1))
    for i in 0..<(samples.count - 1) {
        let tank = tanks[gasIndex[i]]
        // The N₂ fraction, as `TankData.n2` gives it (computed here, off the main actor).
        let n2Fraction = max(0, 1.0 - tank.o2 - tank.he)
        guard tank.o2 > 0, tank.o2 + tank.he <= 1.0001 else {
            segments.append(nil)
            setpointStretches.append(false)
            continue
        }
        let start = samples[i], end = samples[i + 1]
        let onLoop = start.setpoint != nil
        let startPPO2 = onLoop ? loopPPO2(start) : nil
        let endPPO2 = onLoop ? ((end.setpoint != nil ? loopPPO2(end) : nil) ?? startPPO2) : nil
        guard
            let a = BuhlmannZHL16C.inspired(ambient: ambient[i], n2Fraction: n2Fraction, heFraction: tank.he,
                                            loopPPO2: startPPO2?.value, onLoop: onLoop),
            let b = BuhlmannZHL16C.inspired(ambient: ambient[i + 1], n2Fraction: n2Fraction, heFraction: tank.he,
                                            loopPPO2: endPPO2?.value, onLoop: onLoop)
        else {
            segments.append(nil)
            setpointStretches.append(false)
            continue
        }
        segments.append(BuhlmannZHL16C.Segment(n2Start: a.n2, n2End: b.n2, heStart: a.he, heEnd: b.he))
        setpointStretches.append(startPPO2?.isSetpoint == true || endPPO2?.isSetpoint == true)
    }
    // Only stretches before the first unknown one are calculated (the history is unknown after).
    let calculated = segments.firstIndex(where: { $0 == nil }) ?? segments.count
    let usesSetpoint = setpointStretches[..<calculated].contains(true)
    return BuhlmannZHL16C.Inputs(times: times, ambient: ambient, segments: segments,
                                 surfacePressure: surfacePressure, usesSetpointAsPPO2: usesSetpoint)
}

/// The tissue model's inputs for `dive`, with the same depth, altitude and water-type
/// conversion as the chart's PPO₂ (`PPO2Setup`).
nonisolated func buhlmannInputs(for dive: Dive) -> BuhlmannZHL16C.Inputs? {
    let setup = PPO2Setup(dive: dive)
    return buhlmannInputs(samples: dive.profileSamples, tanks: dive.tanks,
                          depthToMetres: setup.depthToMetres,
                          surfacePressure: setup.surfacePressure,
                          waterDivisor: setup.waterDivisor)
}

/// `dive` as an earlier dive for the tissue model: its start, the end of its recorded profile
/// (its start plus the profile's length, else plus its stored dive time) and its inputs. Decodes
/// the dive's profile; called off the main thread by `BuhlmannPriorReader`, and on the main actor
/// only for a dive with unsaved changes.
nonisolated func buhlmannPriorDive(for dive: Dive) -> BuhlmannZHL16C.PriorDive {
    let lengthSeconds = (dive.profileSamples.last?.time).map { $0 * 60 } ?? Double(dive.resolvedDurationSeconds)
    return BuhlmannZHL16C.PriorDive(start: dive.timestamp,
                                    end: dive.timestamp.addingTimeInterval(max(0, lengthSeconds)),
                                    inputs: buhlmannInputs(for: dive))
}

/// Reads the candidate earlier dives off the main actor, for the GF tissue model's carry-over:
/// their profiles are decoded in a fresh `ModelContext` (author `"BlueDive.tissues"`) and released
/// with it, instead of being decoded on the main thread and kept on the main context's dives.
/// It reads the store (saved values): the caller builds on the main actor the dives with unsaved
/// changes and any dive the reader left out (a failed fetch). It has a single, cancellable caller
/// (the dive chart's `GFTissueFeeder`), so it is called directly rather than through `DiveStore`
/// (CLAUDE.md, "Store-backed readers"). Whole dives are fetched: the model reads their profile,
/// tanks, start, dive time, altitude, water type and depth unit. At most `residualMaximumDives`.
nonisolated enum BuhlmannPriorReader {
    static let author = "BlueDive.tissues"

    /// The dives `ids` that could be read, or nil when cancelled.
    static func read(container: ModelContainer,
                     ids: [PersistentIdentifier]) -> [PersistentIdentifier: BuhlmannZHL16C.PriorDive]? {
        guard !ids.isEmpty else { return [:] }
        return autoreleasepool {
            let context = ModelContext(container)
            context.author = author
            let descriptor = FetchDescriptor<Dive>(predicate: #Predicate { ids.contains($0.persistentModelID) })
            guard let dives = try? context.fetch(descriptor) else { return [:] }
            var result: [PersistentIdentifier: BuhlmannZHL16C.PriorDive] = [:]
            for dive in dives {
                if Task.isCancelled { return nil }
                result[dive.persistentModelID] = buhlmannPriorDive(for: dive)
            }
            return result
        }
    }
}

/// The same diver's listed dives that started before `dive`, within `residualSpan` of its
/// start, newest first, at most `residualMaximumDives`: the dives `buhlmannPriorDives` may read.
/// Reads only `DiveStore`'s summaries.
func buhlmannPriorCandidateIDs(for dive: Dive, in store: DiveStore) -> [UUID] {
    // Trimmed like `DiveSummary.diverName`, which it is compared with.
    let diver = dive.diverName.trimmingCharacters(in: .whitespaces)
    let start = dive.timestamp
    return Array(store.cachedSummaries
        .filter {
            $0.id != dive.id && $0.diverName == diver && $0.timestamp < start
                && start.timeIntervalSince($0.timestamp) <= BuhlmannZHL16C.residualSpan
        }
        .sorted { $0.timestamp > $1.timestamp }
        .prefix(BuhlmannZHL16C.residualMaximumDives)
        .map(\.id))
}

/// Fingerprint of the dives `ids` for the tissue model's recalculation trigger: their start,
/// dive time, maximum depth, gases, altitude, water type and depth unit, so a calculation is
/// redone when one of them is edited, and only then. No profile is read here (that is
/// `BuhlmannPriorReader`'s work, off the main thread): only stored scalars and the small tanks
/// list. A replaced profile counts through the dive time and maximum depth that come with it; a
/// profile edit that changes neither is taken into account when the chart is next shown.
/// Reading the attributes in a view body also makes the view observe them.
func buhlmannPriorFingerprint(_ ids: [UUID], in store: DiveStore) -> Int {
    var hasher = Hasher()
    for id in ids {
        hasher.combine(id)
        guard let dive = store.liveDive(id: id) else {
            hasher.combine(0)
            continue
        }
        hasher.combine(dive.timestamp)
        hasher.combine(dive.resolvedDurationSeconds)
        hasher.combine(dive.siteAltitude)
        hasher.combine(dive.siteWaterType)
        hasher.combine(dive.importDistanceUnit)
        for tank in dive.tanks {
            hasher.combine(tank.o2)
            hasher.combine(tank.he)
        }
        hasher.combine(dive.maxDepth)
    }
    return hasher.finalize()
}
