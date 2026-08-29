import SwiftUI
import Charts

// MARK: - Comparable clamping helper

private extension Comparable {
    /// Clamps the value to the given closed range.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Interpolated cursor point (display only — never stored)

/// Synthetic point at an arbitrary cursor position, computed by linearly interpolating
/// between the two bracketing profile samples. Values are chart-display only and never
/// written to the data model.
struct ChartInterpolatedPoint {
    let time: Double
    let depth: Double
    let temperature: Double?
    let tankPressure: Double?
    let tankPressures: [Int: Double]?
    let ndl: Double?
    let ppo2: Double?
    let sensorPPO2: [Int: Double]?
    let events: [DiveProfileEvent]
    let currentGas: Int?
    let ascentSpeed: Double?
}

/// Configuration de visibilité des lignes du graphique
struct ChartLineVisibility {
    var showDepth: Bool = true
    var showTemperature: Bool = false
    var showPressure: Bool = false
    var showNDL: Bool = false
    var showPPO2: Bool = false
    /// Independent of the exclusive secondary metrics — deco event bands can be shown
    /// alongside any other overlay because they are background shading, not axis-mapped lines.
    var showDeco: Bool = false

    private static let defaultsKey = "chartSecondaryMetric"
    private static let decoKey = "chartShowDecoEvents"

    /// Loads the last-used secondary metric from UserDefaults.
    static func restored() -> ChartLineVisibility {
        var v = ChartLineVisibility()
        switch UserDefaults.standard.string(forKey: defaultsKey) {
        case "temperature": v.showTemperature = true
        case "pressure":    v.showPressure = true
        case "ndl":         v.showNDL = true
        case "ppo2":        v.showPPO2 = true
        default:            break
        }
        v.showDeco = UserDefaults.standard.bool(forKey: decoKey)
        return v
    }

    /// Persists the currently active secondary metric to UserDefaults.
    func save() {
        let value: String
        if showPPO2             { value = "ppo2" }
        else if showTemperature { value = "temperature" }
        else if showPressure    { value = "pressure" }
        else if showNDL         { value = "ndl" }
        else                    { value = "none" }
        UserDefaults.standard.set(value, forKey: Self.defaultsKey)
        UserDefaults.standard.set(showDeco, forKey: Self.decoKey)
    }
}

// MARK: - PPO₂ computation helpers (shared by chart layer and tooltip cache)

/// Per-dive constants used for Dalton's-Law PPO₂ computation.
/// Build once per dive; call ppo2(o2Fraction:rawDepth:) per sample.
fileprivate struct PPO2Setup {
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
/// median of physical O₂ cells → computed from gas mix + depth (Dalton's Law).
fileprivate func buildPPO2Map(for dive: Dive) -> [UUID: Double] {
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
            // Median is robust to a single degraded/outlier cell without a tuning threshold.
            let sorted = sensors.values.sorted()
            let mid = sorted.count / 2
            result[sample.id] = sorted.count.isMultiple(of: 2)
                ? (sorted[mid - 1] + sorted[mid]) / 2.0
                : sorted[mid]
        } else if let s = setup {
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

/// Sorted O2 sensor indices that have per-sensor PPO2 data across all profile samples.
fileprivate func sensorPPO2Indices(for dive: Dive) -> [Int] {
    var indices = Set<Int>()
    for sample in dive.profileSamples {
        if let sp = sample.sensorPPO2 { indices.formUnion(sp.keys) }
    }
    return indices.sorted()
}

/// Line colour per physical O2 sensor index — cycles for N > 5.
fileprivate func ppo2SensorColor(for sensorIdx: Int) -> Color {
    let palette: [Color] = [
        .indigo,
        .purple,
        Color(red: 0.45, green: 0.2, blue: 0.85), // violet
        .teal,
        .pink,
    ]
    return palette[sensorIdx % palette.count]
}

/// Dash pattern per sensor line position (sorted index in the sensor set) — cycles for N > 5.
fileprivate func ppo2Dash(forSensorAtPosition position: Int) -> [CGFloat] {
    let dashes: [[CGFloat]] = [
        [],               // solid
        [6, 3],           // long dash
        [2, 3],           // short dash
        [8, 2, 2, 2],     // long dash-dot
        [4, 4],           // medium dash
    ]
    return dashes[position % dashes.count]
}

/// Bouton de toggle personnalisé pour les contrôles du graphique
struct ToggleButton: View {
    @Binding var isOn: Bool
    let icon: String
    let label: LocalizedStringKey
    var shortLabel: LocalizedStringKey? = nil
    let color: Color
    var isAvailable: Bool = true

    @ViewBuilder
    private var labelText: some View {
        if let shortLabel {
            ViewThatFits(in: .horizontal) {
                Text(label).lineLimit(1)
                Text(shortLabel).lineLimit(1).minimumScaleFactor(0.7)
            }
        } else {
            Text(label)
        }
    }

    var body: some View {
        Button {
            if isAvailable {
                isOn.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                labelText
                    .font(.caption2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isOn && isAvailable ? color.opacity(0.3) : Color.secondary.opacity(0.2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isOn && isAvailable ? color : Color.secondary.opacity(0.5), lineWidth: 1.5)
            )
            .foregroundStyle(isAvailable ? (isOn ? color : .secondary) : .gray)
            .opacity(isAvailable ? 1.0 : 0.5)
        }
        .disabled(!isAvailable)
        .buttonStyle(.plain)
    }
}

// MARK: - Static Chart Layer (never re-renders on cursor move)

/// Ce view contient uniquement les courbes — il est Equatable donc SwiftUI
/// ne le re-rend QUE si dive ou visibility changent, jamais quand le curseur bouge.
private struct StaticChartLayer: View, Equatable {
    let dive: Dive
    let visibility: ChartLineVisibility
    let xMax: Double
    let prefs: UserPreferences
    /// Hash of tanks' O₂ fractions — changes when gas mix is edited, allowing the
    /// Equatable check to detect tank mutations even though dive.id is stable.
    let tanksO2Hash: Int

    static func == (lhs: StaticChartLayer, rhs: StaticChartLayer) -> Bool {
        lhs.dive.id == rhs.dive.id &&
        lhs.tanksO2Hash == rhs.tanksO2Hash &&
        lhs.visibility.showDepth == rhs.visibility.showDepth &&
        lhs.visibility.showTemperature == rhs.visibility.showTemperature &&
        lhs.visibility.showPressure == rhs.visibility.showPressure &&
        lhs.visibility.showNDL == rhs.visibility.showNDL &&
        lhs.visibility.showPPO2 == rhs.visibility.showPPO2 &&
        lhs.visibility.showDeco == rhs.visibility.showDeco &&
        lhs.xMax == rhs.xMax
    }

    // MARK: - Right-axis tick positions

    /// Mirrors the left depth axis tick positions so every right-axis label
    /// lands on a gridline that already has a corresponding left depth label.
    /// Produces ~5 evenly-spaced negative values from 0 down to `yDomainMin`.
    private var depthAxisTicks: [Double] {
        let base = dive.displayMaxDepth
        guard base > 0 else { return [0] }
        // Choose a round step size that gives roughly 4-6 ticks.
        let rawStep = base / 5.0
        let magnitude = pow(10.0, floor(log10(rawStep)))
        let normalised = rawStep / magnitude
        let niceNormalised: Double
        if      normalised < 1.5 { niceNormalised = 1.0 }
        else if normalised < 3.5 { niceNormalised = 2.0 }
        else if normalised < 7.5 { niceNormalised = 5.0 }
        else                     { niceNormalised = 10.0 }
        let step = niceNormalised * magnitude

        var ticks: [Double] = []
        var tick = 0.0
        while tick <= base * 1.05 {
            ticks.append(-tick)
            tick += step
        }
        return ticks
    }

    /// The right axis reuses the exact same tick positions as the left depth axis so
    /// every right-axis label sits on a gridline that already has a left depth label.
    private var rightAxisTicks: [Double] { depthAxisTicks }

    /// Fraction [0…1] for a given negated Y tick value, used by right-axis label builders.
    /// fraction=0 at surface (y=0), fraction=1 at max depth (y=-displayMaxDepth).
    private func fraction(for y: Double) -> Double {
        let base = dive.displayMaxDepth
        guard base > 0 else { return 0 }
        return (-y) / base
    }

    // MARK: - Right-axis label builders

    /// Pressure label for a tick.  300 bar at surface (y=0), 0 bar at deepest (y=yDomainMin).
    private func pressureLabel(for y: Double) -> String {
        let maxDisplay = dive.displayPressure(300)
        // fraction=0 at surface → full pressure; fraction=1 at depth → 0 pressure
        let value = (1.0 - fraction(for: y)) * maxDisplay
        return prefs.pressureUnit.formatted(value, from: prefs.pressureUnit)
    }

    /// Temperature label for a tick.  Matches the encoding used in `temperatureMarks`.
    private func temperatureLabel(for y: Double) -> String {
        let (axisMin, axisRange): (Double, Double) = {
            switch prefs.temperatureUnit {
            case .celsius:    return (-10.0, 40.0)
            case .fahrenheit: return (14.0,  72.0)
            case .kelvin:     return (263.15, 40.0)
            }
        }()
        // Mirrors the mark formula: normalised = 1 - fraction → temp = axisMin + normalised * axisRange
        // fraction=0 (y=0, top) → normalised=1 → warmest; fraction=1 (y=-base, bottom) → normalised=0 → coldest
        let normalised = 1.0 - fraction(for: y)
        let value = axisMin + normalised * axisRange
        return "\(Int(value.rounded()))\(prefs.temperatureUnit.symbol)"
    }

    /// NDL label for a tick.  100 min at surface (y=0), 0 min at deepest (y=yDomainMin).
    private func ndlLabel(for y: Double) -> String {
        let value = (1.0 - fraction(for: y)) * 100.0
        return "\(Int(value.rounded()))min"
    }

    private let ppo2AxisMax: Double = 2.0

    /// PPO₂ label for a tick. 0 bar at surface (y=0), 2.0 bar at deepest (y=yDomainMin).
    private func ppo2Label(for y: Double) -> String {
        let value = ppo2AxisMax * fraction(for: y)
        return value.localizedString(decimals: 1, minDecimals: 1) + " bar"
    }

    // The Y domain — depth values are negated so deeper = more negative = lower on chart.
    // Swift Charts naturally puts smaller values at the bottom, so negating gives us
    // surface (0) at top and max depth at bottom with no reversal tricks needed.
    // The 5% extra ensures the deepest line isn't clipped at the plot edge.
    private var yDomainMin: Double {
        let base = dive.displayMaxDepth
        guard base > 0 else { return -1 }
        return -(base * 1.05)
    }

    var body: some View {
        Chart {
            decoMarks
            depthMarks
            gasChangeMarks
            temperatureMarks
            pressureMarks
            ndlMarks
            ppo2Marks
        }
        // Explicit domain from yDomainMin (deepest, negative) to 0 (surface).
        // No automatic padding — the chart fills exactly to the data.
        .chartYScale(domain: yDomainMin...0)
        .chartXScale(domain: 0...xMax)
        .chartPlotStyle { plotArea in
            plotArea.clipShape(Rectangle())
        }
        .chartXAxis {
            AxisMarks(values: .automatic) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.white.opacity(0.2))
                AxisValueLabel {
                    if let time = value.as(Double.self) {
                        Text("\(Int(time)) min")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            // ── Left axis: depth, shown as positive numbers increasing downward ──
            AxisMarks(position: .leading, values: .automatic) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.white.opacity(0.2))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        // v is negative — negate to show a positive depth label
                        Text(verbatim: (-v).localizedString(decimals: 0) + prefs.depthUnit.symbol)
                            .font(.caption2)
                            .foregroundStyle(.cyan)
                    }
                }
            }

            // ── Right axis: secondary metrics ──
            if visibility.showPressure || visibility.showTemperature || visibility.showNDL || visibility.showPPO2 {
                AxisMarks(position: .trailing, values: rightAxisTicks) { value in
                    AxisGridLine().foregroundStyle(Color.clear)
                    AxisValueLabel(anchor: .leading) {
                        if let depth = value.as(Double.self) {
                            HStack(spacing: 3) {
                                if visibility.showPPO2 {
                                    Text(ppo2Label(for: depth))
                                        .font(.caption2)
                                        .foregroundStyle(.indigo)
                                }
                                if visibility.showPressure {
                                    if visibility.showPPO2 {
                                        Text("|").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Text(pressureLabel(for: depth))
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                                if visibility.showTemperature {
                                    if visibility.showPressure || visibility.showPPO2 {
                                        Text("|").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Text(temperatureLabel(for: depth))
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                                if visibility.showNDL {
                                    if visibility.showPressure || visibility.showTemperature || visibility.showPPO2 {
                                        Text("|").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Text(ndlLabel(for: depth))
                                        .font(.caption2)
                                        .foregroundStyle(Color.ndlYellow)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 300)
    }

    // MARK: - Gas change markers

    @ChartContentBuilder
    private var gasChangeMarks: some ChartContent {
        let switches = dive.profileSamples
            .filter { $0.events.contains(.gasChange) }
            .sorted { $0.time < $1.time }
        ForEach(Array(switches.enumerated()), id: \.element.id) { index, sample in
            PointMark(
                x: .value("Gas Switch", sample.time),
                y: .value("Depth", -dive.displayProfileDepth(sample.depth))
            )
            .symbol(.circle)
            .symbolSize(100)
            .foregroundStyle(Color.brown)
            .annotation(position: .top, alignment: .center) {
                Text(verbatim: "G\(index + 1)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.brown)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.brown.opacity(0.15)))
            }
        }
    }

    // MARK: - Ascent rates

    private var cachedAscentRates: [Double] {
        let samples = dive.profileSamples
        guard samples.count >= 2 else { return [] }
        let toMetres = dive.importDistanceUnit == "feet" ? 1.0 / 3.28084 : 1.0
        return (1..<samples.count).map { i in
            let previous = samples[i - 1]
            let current = samples[i]
            let timeDiff = current.time - previous.time
            let depthDiffMetres = (previous.depth - current.depth) * toMetres
            return timeDiff > 0 ? (depthDiffMetres / timeDiff) : 0
        }
    }

    @ChartContentBuilder
    private var depthMarks: some ChartContent {
        if visibility.showDepth {
            let samples = dive.profileSamples
            let rates = cachedAscentRates
            ForEach(samples) { sample in
                AreaMark(
                    x: .value("Time", sample.time),
                    y: .value("Depth", -dive.displayProfileDepth(sample.depth))
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.cyan.opacity(0.25), Color.cyan.opacity(0.04)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
            ForEach(Array(samples.enumerated()), id: \.element.id) { index, sample in
                if index < samples.count - 1 {
                    let nextSample = samples[index + 1]
                    let rate = index < rates.count ? rates[index] : 0.0
                    let segColor: Color = rate >= 18 ? .red : rate >= 10 ? .orange : .cyan
                    LineMark(x: .value("Time", sample.time), y: .value("Depth", -dive.displayProfileDepth(sample.depth)), series: .value("Segment", "Seg-\(index)"))
                        .foregroundStyle(segColor).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    LineMark(x: .value("Time", nextSample.time), y: .value("Depth", -dive.displayProfileDepth(nextSample.depth)), series: .value("Segment", "Seg-\(index)"))
                        .foregroundStyle(segColor).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    @ChartContentBuilder
    private var temperatureMarks: some ChartContent {
        if visibility.showTemperature {
            let samplesWithTemp = dive.profileSamples.filter { $0.temperature != nil }
            ForEach(samplesWithTemp) { sample in
                if let temp = sample.temperature {
                    let displayTemp = dive.displayProfileTemperature(temp)
                    let (axisMin, axisRange): (Double, Double) = {
                        switch prefs.temperatureUnit {
                        case .celsius:    return (-10.0, 40.0)
                        case .fahrenheit: return (14.0,  72.0)
                        case .kelvin:     return (263.15, 40.0)
                        }
                    }()
                    // Map temperature onto the negated depth axis:
                    // warmest temp → y = 0 (top), coldest temp → y = -displayMaxDepth (bottom)
                    // (1 - normalised) flips the direction so high temp sits near the surface.
                    let normalised = ((displayTemp - axisMin) / axisRange).clamped(to: 0...1)
                    let value = -dive.displayMaxDepth * (1.0 - normalised)
                    LineMark(x: .value("Time", sample.time), y: .value("Temp.", value), series: .value("Sequence", "Temperature"))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Color.green)
                }
            }
        }
    }

    /// Sorted tank indices that appear in per-tank pressure data across all samples.
    private var chartTankIndices: [Int] {
        var indices = Set<Int>()
        for sample in dive.profileSamples {
            if let tp = sample.tankPressures {
                indices.formUnion(tp.keys)
            }
        }
        return indices.sorted()
    }

    /// Sorted O2 sensor indices appearing in per-sensor PPO2 data across all samples.
    private var chartSensorIndices: [Int] { sensorPPO2Indices(for: dive) }

    /// Dash pattern per tank index for visual distinction (all lines stay red).
    private func pressureDash(forTankAt position: Int) -> [CGFloat] {
        switch position {
        case 0:  return []             // solid for primary tank
        case 1:  return [6, 3]         // short dash
        case 2:  return [10, 4]        // medium dash
        case 3:  return [2, 3]         // dotted
        default: return [8, 3, 2, 3]   // dash-dot
        }
    }

    @ChartContentBuilder
    private var pressureMarks: some ChartContent {
        if visibility.showPressure {
            let tankIndices = chartTankIndices
            let maxDisplayPressure = dive.displayPressure(300)

            if tankIndices.count > 1 {
                // Multi-tank: one line per tank index
                ForEach(tankIndices, id: \.self) { tankIdx in
                    let samplesForTank = dive.profileSamples.filter { $0.tankPressures?[tankIdx] != nil }
                    ForEach(samplesForTank) { sample in
                        if let pressure = sample.tankPressures?[tankIdx] {
                            let displayPressure = dive.displayProfilePressure(pressure)
                            let value = -dive.displayMaxDepth * (1.0 - (displayPressure / maxDisplayPressure).clamped(to: 0...1))
                            LineMark(
                                x: .value("Time", sample.time),
                                y: .value("Press.", value),
                                series: .value("Sequence", "Pressure-T\(tankIdx)")
                            )
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(
                                lineWidth: 2,
                                lineCap: .round,
                                lineJoin: .round,
                                dash: pressureDash(forTankAt: tankIndices.firstIndex(of: tankIdx) ?? 0)
                            ))
                            .foregroundStyle(Color.red)
                        }
                    }
                }
            } else {
                // Single tank or old dive: use tankPressure
                let samplesWithPressure = dive.profileSamples.filter { $0.tankPressure != nil }
                ForEach(samplesWithPressure) { sample in
                    if let pressure = sample.tankPressure {
                        let displayPressure = dive.displayProfilePressure(pressure)
                        let value = -dive.displayMaxDepth * (1.0 - (displayPressure / maxDisplayPressure).clamped(to: 0...1))
                        LineMark(x: .value("Time", sample.time), y: .value("Press.", value), series: .value("Sequence", "Pressure"))
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(Color.red)
                    }
                }
            }
        }
    }

    @ChartContentBuilder
    private var ndlMarks: some ChartContent {
        if visibility.showNDL {
            // Skip leading zero NDL samples — dive computers emit 0 until they compute
            // the first valid NDL value. Find the index of the first non-zero sample
            // and only plot from that point onward. Underlying data is unchanged.
            let allWithNDL = dive.profileSamples.filter { $0.ndl != nil && ($0.ndl ?? 0) < ndlSentinel }
            let firstNonZeroIdx = allWithNDL.firstIndex { ($0.ndl ?? 0) != 0 } ?? allWithNDL.startIndex
            let samplesWithNDL = Array(allWithNDL[firstNonZeroIdx...])
            ForEach(samplesWithNDL) { sample in
                if let ndl = sample.ndl {
                    // NDL ≥ 100 min is capped at 99 so the line stays just below y=0
                    // (the top edge). Without this, min(ndl, 100)/100 = 1 → value = 0
                    // (surface line) and the yellow line is invisible. NDL 99 → near top,
                    // NDL 0 → y = -displayMaxDepth (bottom).
                    let value = -dive.displayMaxDepth * (1.0 - (min(ndl, 99.0) / 100.0))
                    LineMark(x: .value("Time", sample.time), y: .value("NDL", value), series: .value("Sequence", "NDL"))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Color.ndlYellow)
                }
            }
        }
    }

    // MARK: - PPO₂ overlay (sensor values preferred per sample; computed as fallback)

    /// Produces (time, ppo2) pairs for each profile sample using the shared `buildPPO2Map` helper.
    /// Per-sample: sensor value if available, else Dalton's-Law from gas mix + depth.
    private var ppo2RenderData: [(time: Double, ppo2: Double)] {
        guard visibility.showPPO2 else { return [] }
        let map = buildPPO2Map(for: dive)
        return dive.profileSamples.compactMap { s in map[s.id].map { (time: s.time, ppo2: $0) } }
    }

    @ChartContentBuilder
    private var ppo2Marks: some ChartContent {
        let base = dive.displayMaxDepth
        let sensorIndices = chartSensorIndices
        if visibility.showPPO2 && base > 0 {
            if !sensorIndices.isEmpty {
                // One line per physical O2 cell
                ForEach(sensorIndices, id: \.self) { sensorIdx in
                    let samplesWithSensor = dive.profileSamples.filter { $0.sensorPPO2?[sensorIdx] != nil }
                    ForEach(samplesWithSensor) { sample in
                        if let ppo2 = sample.sensorPPO2?[sensorIdx] {
                            let y = -(base * (ppo2 / ppo2AxisMax).clamped(to: 0...1))
                            LineMark(
                                x: .value("Time", sample.time),
                                y: .value("PPO₂", y),
                                series: .value("Sequence", "PPO2-S\(sensorIdx)")
                            )
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(
                                lineWidth: 2,
                                lineCap: .round,
                                lineJoin: .round,
                                dash: ppo2Dash(forSensorAtPosition: sensorIndices.firstIndex(of: sensorIdx) ?? 0)
                            ))
                            .foregroundStyle(ppo2SensorColor(for: sensorIdx))
                        }
                    }
                }
            } else {
                // Fallback: voted or computed single-line PPO2
                let data = ppo2RenderData
                if !data.isEmpty {
                    ForEach(Array(data.enumerated()), id: \.offset) { _, point in
                        let y = -(base * (point.ppo2 / ppo2AxisMax).clamped(to: 0...1))
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("PPO₂", y),
                            series: .value("Sequence", "PPO2")
                        )
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Color.indigo)
                    }
                }
            }
        }
    }

    // MARK: - Deco event blocks

    /// Contiguous time ranges during which the dive computer reported a deco obligation.
    /// Two consecutive deco samples are merged into the same block when their time gap
    /// is ≤ 3 minutes (well above any normal sample interval).
    private var decoBlocks: [(start: Double, end: Double)] {
        let times = dive.profileSamples
            .filter { $0.events.contains(.decoStop) }
            .map { $0.time }
            .sorted()
        guard !times.isEmpty else { return [] }

        var blocks: [(start: Double, end: Double)] = []
        var blockStart = times[0]
        var blockEnd   = times[0]

        for i in 1..<times.count {
            if times[i] - blockEnd <= 3.0 {
                blockEnd = times[i]
            } else {
                blocks.append((start: blockStart, end: blockEnd))
                blockStart = times[i]
                blockEnd   = times[i]
            }
        }
        blocks.append((start: blockStart, end: blockEnd))
        return blocks
    }

    // MARK: - Mandatory deco stop points

    /// For each mandatory deco stop (type == 2) in `dive.decoStops`, interpolates the
    /// exact time at which the depth profile crosses `stop.depth` during the deco phase.
    /// This places the diamond exactly on the profile line at the planned stop depth.
    /// Falls back to the deco sample whose depth is closest to `stop.depth` when the
    /// profile does not cross it between consecutive samples.
    /// Returns tuples of (chart X time, display depth).
    ///
    /// Algorithm is intentionally identical to buildDecoStopCache (deepest-first,
    /// searchFloorTime anchoring, correct unit conversion) so diamond positions and
    /// tooltip entry times always agree.
    private var mandatoryDecoStopPoints: [(time: Double, displayDepth: Double)] {
        // Process deepest-first, matching buildDecoStopCache's iteration order.
        let stops = dive.decoStops
            .filter { $0.type == 2 }
            .sorted { $0.depth > $1.depth }
        guard !stops.isEmpty else { return [] }

        let decoSamples = dive.profileSamples
            .filter { $0.events.contains(.decoStop) }
            .sorted { $0.time < $1.time }
        guard !decoSamples.isEmpty else { return [] }

        // For accurate crossing detection, search ALL profile samples within the deco
        // window (plus a 2-minute lookback). This handles dive computers that only start
        // emitting .decoStop events after the profile has already passed stop.depth.
        let decoWindowStart = (decoSamples.first?.time ?? 0) - 2.0
        let decoWindowEnd   = decoSamples.last?.time ?? 0
        let windowSamples = dive.profileSamples
            .filter { $0.time >= decoWindowStart && $0.time <= decoWindowEnd }
            .sorted { $0.time < $1.time }

        // DecoStop.depth is always metres; sample.depth is in the stored unit.
        let isFeet = dive.importDistanceUnit == "feet"
        var result: [(time: Double, displayDepth: Double)] = []
        var searchFloorTime = -Double.greatestFiniteMagnitude

        for stop in stops {
            // Convert stop depth to the same unit as sample.depth for valid comparison.
            let stopInStoredUnit = isFeet ? stop.depth * 3.28084 : stop.depth
            var crossTime: Double? = nil
            if windowSamples.count >= 2 {
                for i in 0..<(windowSamples.count - 1) {
                    let a = windowSamples[i], b = windowSamples[i + 1]
                    guard a.time >= searchFloorTime else { continue }
                    guard a.depth > stopInStoredUnit && b.depth <= stopInStoredUnit else { continue }
                    let denom = b.depth - a.depth
                    guard denom != 0 else { continue }
                    crossTime = a.time + ((stopInStoredUnit - a.depth) / denom) * (b.time - a.time)
                    break
                }
            }
            // Fall back: deco-event sample whose depth is closest to stop depth
            if crossTime == nil {
                crossTime = decoSamples
                    .filter { $0.time >= searchFloorTime }
                    .min(by: { abs($0.depth - stopInStoredUnit) < abs($1.depth - stopInStoredUnit) })?.time
            }
            guard let time = crossTime else { continue }
            searchFloorTime = time
            result.append((
                time:         time,
                displayDepth: dive.displayProfileDepth(stopInStoredUnit)
            ))
        }
        return result
    }

    @ChartContentBuilder
    private var decoMarks: some ChartContent {
        if visibility.showDeco {
            let blocks = decoBlocks
            let yMin   = yDomainMin
            // Draw a semi-transparent orange band for each contiguous deco period so the
            // shading sits behind all other chart lines.
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                RectangleMark(
                    xStart: .value("Deco Start", block.start),
                    xEnd:   .value("Deco End",   block.end),
                    yStart: .value("Bottom",      yMin),
                    yEnd:   .value("Top",         0.0)
                )
                .foregroundStyle(Color.orange.opacity(0.2))
            }

            // One labelled point per mandatory deco stop — diamond symbol so it stands
            // out clearly against the depth profile line.
            let stopPoints = mandatoryDecoStopPoints
            ForEach(Array(stopPoints.enumerated()), id: \.offset) { _, point in
                PointMark(
                    x: .value("Time", point.time),
                    y: .value("Deco Stop", -point.displayDepth)
                )
                .symbol(.diamond)
                .symbolSize(120)
                .foregroundStyle(Color.orange)
            }
        }
    }
}

// MARK: - UnifiedDiveChartOptimized

/// Graphique unifié interactif pour le profil de plongée - VERSION OPTIMISÉE
struct UnifiedDiveChartOptimized: View {
    let dive: Dive
    @State private var visibility = ChartLineVisibility.restored()

    // MARK: - User Preferences (Observable)
    @State private var prefs = UserPreferences.shared

    // MARK: - Cursor / Tooltip State
    @State private var cursorX: Double? = nil
    @State private var cursorScreenX: CGFloat = 0   // absolute X in overlay coords
    @State private var plotOriginX: CGFloat = 0     // leading edge of the plot area
    @State private var plotWidth: CGFloat = 1       // width of the plot area only
    @State private var lastTooltipUpdate: Date = .distantPast
    @State private var cachedInterpolatedPoint: ChartInterpolatedPoint? = nil
    /// Pre-built per-sample PPO₂ map (UUID → value). Rebuilt once on toggle or dive change.
    @State private var cachedPPO2BySampleID: [UUID: Double] = [:]
    /// Sorted (time, pressure) readings for single-tank dives — enables interpolation across sparse AI transmitter gaps.
    @State private var cachedSinglePressureReadings: [(time: Double, pressure: Double)] = []
    /// Sorted per-tank pressure readings for multi-tank dives.
    @State private var cachedMultiPressureReadings: [Int: [(time: Double, pressure: Double)]] = [:]
    /// Entry time (diamond position) per mandatory deco stop for tooltip matching — built once per dive.
    @State private var cachedDecoStopEntries: [(stop: DecoStop, entryTime: Double)] = []

    var body: some View {
        VStack(spacing: 16) {
            toggleControls
            chartView

            if !dive.profileSamples.isEmpty {
                legendView
            }
        }
        .task(id: "\(dive.id)\(tanksO2Hash)") {
            buildPressureCache()
            buildDecoStopCache()
            if visibility.showPPO2 { rebuildPPO2Cache() }
        }
        .onChange(of: visibility.showPPO2) { _, newValue in
            if newValue { rebuildPPO2Cache() } else { cachedPPO2BySampleID = [:] }
        }
    }
    
    // MARK: - Toggle Controls
    
    // MARK: - Exclusive Secondary Toggle Bindings
    
    /// Creates a binding that ensures only one secondary metric is active at a time.
    /// Toggling a new one off just turns it off; toggling a new one on turns off whichever was previously active.
    private func exclusiveBinding(for keyPath: WritableKeyPath<ChartLineVisibility, Bool>) -> Binding<Bool> {
        Binding<Bool>(
            get: { visibility[keyPath: keyPath] },
            set: { newValue in
                if newValue {
                    // Turn off all other secondary metrics first
                    visibility.showTemperature = false
                    visibility.showPressure = false
                    visibility.showNDL = false
                    visibility.showPPO2 = false
                }
                visibility[keyPath: keyPath] = newValue
                visibility.save()
            }
        )
    }
    
    private var toggleControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Depth button - always on, non-interactive (using a constant binding)
                ToggleButton(
                    isOn: .constant(true),
                    icon: "arrow.down.circle.fill",
                    label: "Depth",
                    shortLabel: "Prof.",
                    color: .cyan,
                    isAvailable: true
                )
                
                ToggleButton(
                    isOn: exclusiveBinding(for: \.showTemperature),
                    icon: "thermometer",
                    label: "Temperature",
                    shortLabel: "Temp.",
                    color: .green,
                    isAvailable: hasTemperatureData
                )

                ToggleButton(
                    isOn: exclusiveBinding(for: \.showNDL),
                    icon: "timer",
                    label: "NDL",
                    color: .ndlYellow,
                    isAvailable: hasNDLData
                )
            }
            
            HStack(spacing: 12) {
                ToggleButton(
                    isOn: exclusiveBinding(for: \.showPressure),
                    icon: "gauge.with.needle.fill",
                    label: "Pressure",
                    shortLabel: "Press.",
                    color: .red,
                    isAvailable: hasPressureData
                )

                ToggleButton(
                    isOn: exclusiveBinding(for: \.showPPO2),
                    icon: "lungs.fill",
                    label: "PPO₂",
                    color: .indigo,
                    isAvailable: ppo2Available
                )

                // Deco is independent — it overlays background shading and can be shown
                // alongside any of the axis-mapped secondary metrics above.
                ToggleButton(
                    isOn: Binding(
                        get: { visibility.showDeco },
                        set: { visibility.showDeco = $0; visibility.save() }
                    ),
                    icon: "exclamationmark.triangle.fill",
                    label: "Deco",
                    color: .orange,
                    isAvailable: hasDecoData
                )
            }
            Text("Depth is always displayed on the chart")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Chart View

    private var chartView: some View {
        let lastSampleTime = dive.profileSamples.last?.time ?? 0
        let storedDurationMinutes: Double = dive.duration >= 3600
            ? Double(dive.duration) / 60.0
            : Double(dive.duration)
        let xMax = max(lastSampleTime, storedDurationMinutes)

        return StaticChartLayer(dive: dive, visibility: visibility, xMax: xMax, prefs: prefs, tanksO2Hash: tanksO2Hash)
            .equatable()
            // chartOverlay gives us a ChartProxy so we can read the exact plot-area
            // frame — the rectangle inside both Y-axis label gutters.  Everything
            // (cursor line, tooltip, touch zone) is sized and positioned relative to
            // that rectangle, not the full view width.
            .chartOverlay { proxy in
                GeometryReader { geo in
                    // plotFrame is in the GeometryReader's local coordinate space.
                    let frame  = proxy.plotFrame!
                    let origin = geo[frame].minX          // left edge of the plot area
                    let width  = geo[frame].width         // plot area width only
                    let height = geo[frame].height

                    ZStack(alignment: .topLeading) {
                        // ── Cursor line ──
                        if let cx = cursorX {
                            let fraction = xMax > 0 ? CGFloat(cx / xMax) : 0
                            Rectangle()
                                .fill(Color.primary.opacity(0.5))
                                .frame(width: 1.5, height: height)
                                .offset(x: origin + fraction * width)
                        }

                        // ── Tooltip ──
                        if cursorX != nil, let point = cachedInterpolatedPoint {
                            ChartTooltipView(
                                point: point,
                                visibility: visibility,
                                dive: dive,
                                decoStopEntries: cachedDecoStopEntries
                            )
                            .offset(x: tooltipOffsetX(
                                screenX: cursorScreenX,
                                plotOriginX: origin,
                                plotWidth: width
                            ))
                            .offset(y: 8)
                            .allowsHitTesting(false)
                        }

                        // ── Touch capture zone — sized to the plot area only ──
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .frame(width: width, height: height)
                            .offset(x: origin)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        // Clamp within the plot area, convert to data time.
                                        let localX = (value.location.x - origin)
                                            .clamped(to: 0...width)
                                        let fraction = localX / width
                                        cursorX       = fraction * xMax
                                        cursorScreenX = origin + localX
                                        plotOriginX   = origin
                                        plotWidth     = width

                                        let now = Date()
                                        if now.timeIntervalSince(lastTooltipUpdate) > 0.033 {
                                            lastTooltipUpdate = now
                                            cachedInterpolatedPoint = interpolatedPoint(at: fraction * xMax)
                                        }
                                    }
                                    .onEnded { _ in
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            cursorX = nil
                                            cachedInterpolatedPoint = nil
                                        }
                                    }
                            )
                    }
                }
            }
    }

    // MARK: - Tooltip Helpers

    /// Keeps the tooltip card within the plot area horizontally.
    private func tooltipOffsetX(screenX: CGFloat, plotOriginX: CGFloat, plotWidth: CGFloat) -> CGFloat {
        let tooltipWidth: CGFloat = 200
        let padding: CGFloat = 8
        let x = screenX - tooltipWidth / 2
        let minX = plotOriginX + padding
        let maxX = plotOriginX + plotWidth - tooltipWidth - padding
        return x.clamped(to: minX...maxX)
    }

    // MARK: - Pressure Cache

    /// Builds sorted arrays of (time, pressure) readings from all samples — called once per dive.
    /// Enables O(log n) interpolation across sparse AI transmitter gaps.
    private func buildPressureCache() {
        var single: [(time: Double, pressure: Double)] = []
        var multi: [Int: [(time: Double, pressure: Double)]] = [:]
        for sample in dive.profileSamples {
            if let p = sample.tankPressure {
                single.append((sample.time, p))
            }
            if let tp = sample.tankPressures {
                for (idx, p) in tp {
                    multi[idx, default: []].append((sample.time, p))
                }
            }
        }
        cachedSinglePressureReadings = single.sorted { $0.time < $1.time }
        for key in multi.keys { multi[key]!.sort { $0.time < $1.time } }
        cachedMultiPressureReadings = multi
    }

    /// Builds entry times for each mandatory deco stop using ascending depth crossings.
    /// Stops are processed deepest-first so each shallower stop's crossing is anchored
    /// after the deeper stop's entry, preventing oscillation from stealing an earlier crossing.
    private func buildDecoStopCache() {
        let stops = dive.decoStops
            .filter { $0.type == 2 }
            .sorted { $0.depth > $1.depth }     // deepest first
        guard !stops.isEmpty else { cachedDecoStopEntries = []; return }

        let samples = dive.profileSamples       // single decode, reused below
        let decoSamples = samples
            .filter { $0.events.contains(.decoStop) }
            .sorted { $0.time < $1.time }
        guard !decoSamples.isEmpty else { cachedDecoStopEntries = []; return }

        let windowStart = (decoSamples.first?.time ?? 0) - 2.0
        let windowEnd   = decoSamples.last?.time ?? 0
        let windowSamples = samples
            .filter { $0.time >= windowStart && $0.time <= windowEnd }
            .sorted { $0.time < $1.time }

        // DecoStop.depth is always metres; sample.depth is in the stored unit.
        let isFeet = dive.importDistanceUnit == "feet"

        var result: [(stop: DecoStop, entryTime: Double)] = []
        var searchFloorTime = -Double.greatestFiniteMagnitude  // each stop entered after the prior

        for stop in stops {
            let stopInStoredUnit = isFeet ? stop.depth * 3.28084 : stop.depth
            var entryTime: Double? = nil

            if windowSamples.count >= 2 {
                for i in 0..<(windowSamples.count - 1) {
                    let a = windowSamples[i], b = windowSamples[i + 1]
                    guard a.time >= searchFloorTime else { continue }
                    guard a.depth > stopInStoredUnit && b.depth <= stopInStoredUnit else { continue }
                    let denom = b.depth - a.depth
                    guard denom != 0 else { continue }
                    entryTime = a.time + ((stopInStoredUnit - a.depth) / denom) * (b.time - a.time)
                    break
                }
            }

            if entryTime == nil {
                entryTime = decoSamples
                    .filter { $0.time >= searchFloorTime }
                    .min(by: { abs($0.depth - stopInStoredUnit) < abs($1.depth - stopInStoredUnit) })?
                    .time
            }

            if let t = entryTime {
                result.append((stop: stop, entryTime: t))
                searchFloorTime = t
            }
        }

        cachedDecoStopEntries = result.sorted { $0.entryTime < $1.entryTime }
    }

    /// Linearly interpolates a pressure value at time `t` from a sorted (time, pressure) array.
    private func interpolatePressure(at t: Double, in readings: [(time: Double, pressure: Double)]) -> Double? {
        guard !readings.isEmpty else { return nil }
        if t <= readings.first!.time { return readings.first!.pressure }
        if t >= readings.last!.time  { return nil }  // no reading after this point — show nothing rather than stale data
        var lo = 0, hi = readings.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if readings[mid].time <= t { lo = mid + 1 } else { hi = mid }
        }
        let next = readings[lo], prev = readings[lo - 1]
        let dt = next.time - prev.time
        let frac = dt > 0 ? (t - prev.time) / dt : 0.0
        return prev.pressure + frac * (next.pressure - prev.pressure)
    }

    /// Interpolates pressures for all tanks at `cursorTime` from the pre-built multi-tank cache.
    private func interpolateMultiPressures(at cursorTime: Double) -> [Int: Double]? {
        guard !cachedMultiPressureReadings.isEmpty else { return nil }
        var result: [Int: Double] = [:]
        for (tankIdx, readings) in cachedMultiPressureReadings {
            if let p = interpolatePressure(at: cursorTime, in: readings) { result[tankIdx] = p }
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Interpolated Point

    /// Returns a synthetic point at `cursorTime` by linearly interpolating between the two
    /// bracketing profile samples. Pressure is interpolated across the sparse AI transmitter
    /// reading windows rather than just from the nearest sample.
    private func interpolatedPoint(at cursorTime: Double) -> ChartInterpolatedPoint? {
        let samples = dive.profileSamples
        guard !samples.isEmpty else { return nil }

        // Binary search: first index where sample.time > cursorTime (samples are time-sorted).
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].time <= cursorTime { lo = mid + 1 } else { hi = mid }
        }
        let nextIdx = lo

        guard nextIdx > 0 else {
            return makeEdgePoint(cursorTime: cursorTime, from: samples[0], ascentSpeed: nil)
        }
        guard nextIdx < samples.count else {
            return makeEdgePoint(cursorTime: cursorTime, from: samples.last!, ascentSpeed: nil)
        }

        let prev = samples[nextIdx - 1]
        let next = samples[nextIdx]
        let dt = next.time - prev.time
        let t = dt > 0 ? (cursorTime - prev.time) / dt : 0.0

        let depth = prev.depth + t * (next.depth - prev.depth)

        let temperature: Double? = {
            if let pt = prev.temperature, let nt = next.temperature { return pt + t * (nt - pt) }
            return prev.temperature ?? next.temperature
        }()

        let ndl: Double? = {
            let pn: Double? = { guard let n = prev.ndl, n < ndlSentinel else { return nil }; return n }()
            let nn: Double? = { guard let n = next.ndl, n < ndlSentinel else { return nil }; return n }()
            if let a = pn, let b = nn { return a + t * (b - a) }
            return pn ?? nn
        }()

        let ppo2: Double? = {
            let pp = cachedPPO2BySampleID[prev.id]
            let np = cachedPPO2BySampleID[next.id]
            if let a = pp, let b = np { return a + t * (b - a) }
            return pp ?? np
        }()

        let tankPressure = interpolatePressure(at: cursorTime, in: cachedSinglePressureReadings)
        let ascentSpeed: Double? = dt > 0 ? (prev.depth - next.depth) / dt : nil
        let nearest = t < 0.5 ? prev : next

        // Union events from both neighbours so continuous-state events (.decoStop) and
        // point-in-time events (.gasChange) are never dropped due to the 50% split.
        let mergedEvents = prev.events + next.events.filter { !prev.events.contains($0) }
        // For gas display, prefer the sample carrying the switch so the correct new gas is shown.
        let gasSource = prev.events.contains(.gasChange) ? prev
            : next.events.contains(.gasChange) ? next
            : nearest

        return ChartInterpolatedPoint(
            time: cursorTime,
            depth: depth,
            temperature: temperature,
            tankPressure: tankPressure,
            tankPressures: interpolateMultiPressures(at: cursorTime),
            ndl: ndl,
            ppo2: ppo2,
            sensorPPO2: nearest.sensorPPO2,
            events: mergedEvents,
            currentGas: gasSource.currentGas,
            ascentSpeed: ascentSpeed
        )
    }

    /// Builds a clamped `ChartInterpolatedPoint` from a single sample (used at the edges).
    private func makeEdgePoint(cursorTime: Double, from sample: DiveProfilePoint, ascentSpeed: Double?) -> ChartInterpolatedPoint {
        ChartInterpolatedPoint(
            time: cursorTime,
            depth: sample.depth,
            temperature: sample.temperature,
            tankPressure: interpolatePressure(at: cursorTime, in: cachedSinglePressureReadings),
            tankPressures: interpolateMultiPressures(at: cursorTime),
            ndl: sample.ndl.flatMap { $0 < ndlSentinel ? $0 : nil },
            ppo2: cachedPPO2BySampleID[sample.id],
            sensorPPO2: sample.sensorPPO2,
            events: sample.events,
            currentGas: sample.currentGas,
            ascentSpeed: ascentSpeed
        )
    }

    // MARK: - PPO2 Helpers

    /// Builds `cachedPPO2BySampleID` using `buildPPO2Map` — called once per toggle or dive change.
    private func rebuildPPO2Cache() {
        cachedPPO2BySampleID = buildPPO2Map(for: dive)
    }

    // MARK: - Legend View

    private var legendView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Legend")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 6) {
                if visibility.showDepth {
                    HStack(spacing: 8) {
                        legendDot(.cyan, "Normal")
                        legendDot(.orange, ascentRateLegendFast)
                        legendDot(.red, ascentRateLegendDangerous)
                    }
                }
                
                if visibility.showTemperature && hasTemperatureData {
                    metricLegendRow(color: .green, label: "Temperature", range: temperatureRange)
                }
                
                if visibility.showPressure && hasPressureData {
                    let tankIndices = chartTankIndicesForLegend
                    if tankIndices.count > 1 {
                        ForEach(tankIndices, id: \.self) { idx in
                            metricLegendRow(color: .red, label: "T\(idx + 1) Pressure", range: pressureRangeForTank(idx))
                        }
                    } else {
                        metricLegendRow(color: .red, label: "Pressure", range: pressureRange)
                    }
                }
                
                if visibility.showNDL && hasNDLData {
                    metricLegendRow(color: .ndlYellow, label: "NDL", range: ndlRange)
                }

                if visibility.showPPO2 && ppo2Available {
                    let sensorIndices = sensorPPO2Indices(for: dive)
                    if sensorIndices.isEmpty {
                        legendDot(.indigo, "PPO₂ (bar, 0–2 scale)")
                    } else {
                        ForEach(sensorIndices, id: \.self) { idx in
                            legendDot(ppo2SensorColor(for: idx), verbatim: String(format: NSLocalizedString("S%ld PPO₂ (0–2 bar)", bundle: Bundle.forAppLanguage(), comment: "Chart legend label for a per-sensor PPO2 overlay line; %ld = sensor number (1-based)"), idx + 1))
                        }
                    }
                }

                if visibility.showDeco && hasDecoData {
                    HStack(spacing: 8) {
                        legendBand(.orange, "Deco obligation")
                        legendDiamond(.orange, "Mandatory stop")
                    }
                }

                if hasGasChangeData {
                    legendGasChange(.brown, "Gas switch")
                }
            }
        }
        .padding(.horizontal)
    }
    
    private var ascentRateLegendFast: LocalizedStringKey {
        if prefs.depthUnit == .feet {
            return "Fast (33-59 ft/min)"
        } else {
            return "Fast (10-18 m/min)"
        }
    }
    
    private var ascentRateLegendDangerous: LocalizedStringKey {
        if prefs.depthUnit == .feet {
            return "Dangerous (≥59 ft/min)"
        } else {
            return "Dangerous (≥18 m/min)"
        }
    }
    
    private func legendDot(_ color: Color, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func legendDot(_ color: Color, verbatim text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(verbatim: text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Rectangular swatch used for background-band legend entries (e.g. deco phase).
    private func legendBand(_ color: Color, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(0.25))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(color.opacity(0.6), lineWidth: 0.5))
                .frame(width: 14, height: 8)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Circle swatch for gas switch legend entries.
    private func legendGasChange(_ color: Color, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Diamond swatch used for point-marker legend entries (e.g. mandatory deco stops).
    private func legendDiamond(_ color: Color, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(color)
                .frame(width: 7, height: 7)
                .rotationEffect(.degrees(45))
                .frame(width: 10, height: 10)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
    
    private func metricLegendRow(color: Color, label: LocalizedStringKey, range: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            (Text(label) + Text(": \(range)"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
    
    // MARK: - Helper Properties
    
    /// Hash of tanks' O₂ fractions used to detect gas-mix edits without changing dive.id.
    /// Accessed during body so @Observable tracks tanksData as a dependency.
    private var tanksO2Hash: Int {
        dive.tanks.reduce(0) { ($0 &* 31) &+ Int($1.o2 * 1_000_000) }
    }

    private var ppo2Available: Bool {
        dive.tanks.contains { $0.o2 > 0 }
            || dive.profileSamples.contains { $0.ppo2 != nil }
            || dive.profileSamples.contains { $0.sensorPPO2?.isEmpty == false }
    }

    private var hasTemperatureData: Bool {
        dive.profileSamples.contains { $0.temperature != nil }
    }
    
    private var hasPressureData: Bool {
        dive.profileSamples.contains { $0.tankPressure != nil }
    }
    
    private var hasNDLData: Bool {
        dive.profileSamples.contains { $0.ndl != nil && ($0.ndl ?? 0) < ndlSentinel }
    }

    private var hasDecoData: Bool {
        dive.profileSamples.contains { $0.events.contains(.decoStop) }
    }

    private var hasGasChangeData: Bool {
        dive.profileSamples.contains { $0.events.contains(.gasChange) }
    }
    
    
    private var temperatureRange: String {
        let temps = dive.profileSamples.compactMap { $0.temperature }
        guard !temps.isEmpty, let rawMin = temps.min(), let rawMax = temps.max() else { return "—" }
        // Convert raw stored values through the dive's import metadata before formatting.
        let displayMin = prefs.temperatureUnit.formatted(rawMin, from: dive.storedTemperatureUnit)
        let displayMax = prefs.temperatureUnit.formatted(rawMax, from: dive.storedTemperatureUnit)
        return "\(displayMin)-\(displayMax)"
    }
    
    /// Tank indices for legend (computed at the outer view level).
    private var chartTankIndicesForLegend: [Int] {
        var indices = Set<Int>()
        for sample in dive.profileSamples {
            if let tp = sample.tankPressures {
                indices.formUnion(tp.keys)
            }
        }
        return indices.sorted()
    }

    private var pressureRange: String {
        let pressures = dive.profileSamples.compactMap { $0.tankPressure }
        guard !pressures.isEmpty, let minP = pressures.min(), let maxP = pressures.max() else { return "—" }
        // Use the dive's unit-aware conversion — never apply heuristics directly.
        let minDisplay = dive.displayProfilePressure(minP)
        let maxDisplay = dive.displayProfilePressure(maxP)
        let symbol = prefs.pressureUnit.symbol
        return "\(minDisplay.localizedString(decimals: 0))-\(maxDisplay.localizedString(decimals: 0)) \(symbol)"
    }

    private func pressureRangeForTank(_ tankIdx: Int) -> String {
        let pressures = dive.profileSamples.compactMap { $0.tankPressures?[tankIdx] }
        guard !pressures.isEmpty, let minP = pressures.min(), let maxP = pressures.max() else { return "—" }
        let minDisplay = dive.displayProfilePressure(minP)
        let maxDisplay = dive.displayProfilePressure(maxP)
        let symbol = prefs.pressureUnit.symbol
        return "\(minDisplay.localizedString(decimals: 0))-\(maxDisplay.localizedString(decimals: 0)) \(symbol)"
    }
    
    private var ndlRange: String {
        let ndls = dive.profileSamples.compactMap { $0.ndl }.filter { $0 < ndlSentinel }
        guard !ndls.isEmpty, let min = ndls.min(), let max = ndls.max() else { return "—" }
        return "\(min.localizedString(decimals: 0))-\(max.localizedString(decimals: 0)) min"
    }
    
}

// MARK: - Chart Tooltip

/// Popup card that appears above the drag cursor showing depth, temperature, pressure and NDL
/// for the nearest profile sample.
struct ChartTooltipView: View {
    let point: ChartInterpolatedPoint
    let visibility: ChartLineVisibility
    let dive: Dive
    let decoStopEntries: [(stop: DecoStop, entryTime: Double)]

    @State private var prefs = UserPreferences.shared

    // MARK: Formatted values

    private var timeLabel: String {
        let totalSec = Int(point.time * 60)
        let m = totalSec / 60
        let s = totalSec % 60
        return String(format: "%d:%02d", m, s)
    }

    private var depthLabel: String {
        let converted = dive.displayProfileDepth(point.depth)
        let symbol = UserPreferences.shared.depthUnit.symbol
        return converted.localizedString(decimals: 1) + " \(symbol)"
    }

    private var temperatureLabel: String? {
        guard let t = point.temperature else { return nil }
        return prefs.temperatureUnit.formatted(t, from: dive.storedTemperatureUnit)
    }

    private var pressureLabel: String? {
        guard let p = point.tankPressure else { return nil }
        return dive.formattedPressure(p)
    }

    /// Per-tank pressure labels for multi-tank tooltip.
    private var perTankPressureLabels: [(index: Int, label: String)]? {
        guard let tp = point.tankPressures, tp.count > 1 else { return nil }
        return tp.sorted(by: { $0.key < $1.key }).map { (index: $0.key, label: dive.formattedPressure($0.value)) }
    }

    private var ndlLabel: String? {
        guard let ndl = point.ndl else { return nil }
        return ndl.localizedString(decimals: 0) + " min"
    }

    private var matchingDecoStop: DecoStop? {
        guard point.events.contains(.decoStop) else { return nil }

        // Each diamond on the chart marks the entry time of a mandatory stop (ascending crossing).
        // Count how many diamonds the cursor has passed.
        let passedCount = decoStopEntries.filter { $0.entryTime <= point.time }.count

        if passedCount == 0 {
            // Before the first diamond — show the first upcoming stop.
            return decoStopEntries.first?.stop
        }

        // After diamond N, show stop N+1 (next upcoming). After the last diamond, show nothing.
        let nextIndex = passedCount
        guard nextIndex < decoStopEntries.count else { return nil }
        return decoStopEntries[nextIndex].stop
    }

    /// Header label for the deco row.
    private var decoDiveLabel: String {
        NSLocalizedString("Deco Dive", bundle: .forAppLanguage(), comment: "Tooltip label indicating the dive is under decompression")
    }

    /// Depth + duration detail for the mandatory stop at this sample, shown as a sub-row.
    /// Returns nil when the sample does not coincide with a mandatory stop point.
    private var decoStopDetail: String? {
        guard let stop = matchingDecoStop else { return nil }
        // DecoStop.depth is always metres; convert to stored unit before displayProfileDepth.
        let stopInStoredUnit = dive.importDistanceUnit == "feet" ? stop.depth * 3.28084 : stop.depth
        let depth    = dive.displayProfileDepth(stopInStoredUnit).localizedString(decimals: 0) + prefs.depthUnit.symbol
        let duration = ceil(stop.time / 60).localizedString(decimals: 0) + "min"
        return "\(depth) · \(duration)"
    }

    /// Gas name for a gas switch event at this sample.
    /// Uses the sample's recorded `currentGas` index directly (set by the dive computer parser),
    /// which correctly reflects switch-backs to a previously-used tank.
    private var gasChangeName: String? {
        guard point.events.contains(.gasChange),
              let gasIdx = point.currentGas,
              gasIdx >= 0,
              gasIdx < dive.tanks.count else { return nil }
        return dive.tanks[gasIdx].gasDisplayName()
    }

    // ascentSpeed is stored-unit/min; normalise to m/min before display so
    // depthUnit.convert() (which assumes metres) and the m/min thresholds are correct.
    private var ascentSpeedMetresPerMin: Double? {
        guard let speed = point.ascentSpeed else { return nil }
        return dive.importDistanceUnit == "feet" ? speed / 3.28084 : speed
    }

    private var ascentSpeedLabel: String? {
        guard let speedMPM = ascentSpeedMetresPerMin else { return nil }
        let displaySpeed = prefs.depthUnit.convert(abs(speedMPM))
        let symbol = prefs.depthUnit.symbol
        return displaySpeed.localizedString(decimals: 1) + " \(symbol)/min"
    }

    private var ascentSpeedColor: Color {
        guard let speedMPM = ascentSpeedMetresPerMin else { return .secondary }
        if speedMPM <= 0 { return .cyan }
        if speedMPM >= 18 { return .red }
        if speedMPM >= 10 { return .orange }
        return .cyan
    }

    private var ascentSpeedIcon: String {
        guard let speed = point.ascentSpeed else { return "arrow.up.arrow.down" }
        if abs(speed) < 0.5 { return "equal" }
        return speed > 0 ? "arrow.up" : "arrow.down"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Time header
            Text(timeLabel)
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(.white.opacity(0.6))

            Divider().background(Color.white.opacity(0.25))

            // Depth — always shown
            tooltipRow(icon: "arrow.down.to.line", color: .cyan, label: depthLabel)

            // Ascent speed — always shown below depth
            if let speedLabel = ascentSpeedLabel {
                tooltipRow(icon: ascentSpeedIcon, color: ascentSpeedColor, label: speedLabel)
            }

            // Temperature — shown if enabled and data available
            if visibility.showTemperature, let tLabel = temperatureLabel {
                tooltipRow(icon: "thermometer.medium", color: .green, label: tLabel)
            }

            // Pressure — shown if enabled and data available
            if visibility.showPressure {
                if let perTank = perTankPressureLabels {
                    ForEach(perTank, id: \.index) { entry in
                        tooltipRow(icon: "gauge.with.needle.fill", color: .red, label: "T\(entry.index + 1): \(entry.label)")
                    }
                } else if let pLabel = pressureLabel {
                    tooltipRow(icon: "gauge.with.needle.fill", color: .red, label: pLabel)
                }
            }
            
            // NDL — shown if enabled and data available
            if visibility.showNDL, let nLabel = ndlLabel {
                tooltipRow(icon: "timer", color: .ndlYellow, label: nLabel)
            }

            // PPO2 — shown if enabled; voted row always shown, then per-sensor rows for CCR
            if visibility.showPPO2 {
                if let sensorData = point.sensorPPO2, !sensorData.isEmpty {
                    if let p = point.ppo2 {
                        let ppo2Color: Color = p < DiveProfileEvent.ppo2HypoxicThreshold ? .cyan
                            : p < DiveProfileEvent.ppo2WarnThreshold ? .green
                            : p < DiveProfileEvent.ppo2DangerThreshold ? .orange
                            : .red
                        tooltipRow(icon: "lungs.fill", color: ppo2Color, label: p.localizedString(decimals: 2, minDecimals: 2) + " bar")
                    }
                    ForEach(sensorData.keys.sorted(), id: \.self) { idx in
                        if let p = sensorData[idx] {
                            tooltipRow(icon: "lungs.fill", color: ppo2SensorColor(for: idx),
                                       label: String(format: NSLocalizedString("S%ld: ", bundle: Bundle.forAppLanguage(), comment: "Tooltip label prefix for per-O2-sensor PPO2 in the dive chart; %ld = sensor number (1-based)"), idx + 1) + p.localizedString(decimals: 2, minDecimals: 2) + " bar")
                        }
                    }
                } else if let p = point.ppo2 {
                    let ppo2Color: Color = p < DiveProfileEvent.ppo2HypoxicThreshold ? .cyan
                        : p < DiveProfileEvent.ppo2WarnThreshold ? .green
                        : p < DiveProfileEvent.ppo2DangerThreshold ? .orange
                        : .red
                    tooltipRow(icon: "lungs.fill", color: ppo2Color, label: p.localizedString(decimals: 2, minDecimals: 2) + " bar")
                }
            }

            // Deco event — shown if enabled and this sample carries a deco obligation.
            if visibility.showDeco && point.events.contains(.decoStop) {
                tooltipRow(icon: "exclamationmark.triangle.fill", color: .orange, label: decoDiveLabel)
                // When on a mandatory stop point, show depth + duration on a sub-row.
                if let detail = decoStopDetail {
                    tooltipRow(icon: "smallcircle.filled.circle", color: .orange.opacity(0.7), label: detail)
                }
            }

            // Gas switch — always shown when present (gas change markers are always on).
            if let gasName = gasChangeName {
                tooltipRow(icon: "cylinder.fill", color: .brown, label: String(format: NSLocalizedString("→ %@", bundle: .forAppLanguage(), comment: "Gas switch tooltip row: arrow followed by gas mix name"), gasName))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 200, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.75))
                .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        )
    }

    private func tooltipRow(icon: String, color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 16)
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Preview

#Preview("No Deco") {
    let samplePoints = [
        DiveProfilePoint(time: 0, depth: 0, temperature: 24.0, tankPressure: 200, ndl: 100),
        DiveProfilePoint(time: 5, depth: 10, temperature: 23.5, tankPressure: 180, ndl: 85),
        DiveProfilePoint(time: 10, depth: 18, temperature: 22.8, tankPressure: 160, ndl: 60),
        DiveProfilePoint(time: 15, depth: 25, temperature: 21.5, tankPressure: 140, ndl: 35),
        DiveProfilePoint(time: 20, depth: 28, temperature: 20.8, tankPressure: 120, ndl: 25),
        DiveProfilePoint(time: 25, depth: 26, temperature: 21.0, tankPressure: 100, ndl: 30),
        DiveProfilePoint(time: 30, depth: 15, temperature: 22.5, tankPressure: 80, ndl: 60),
        DiveProfilePoint(time: 35, depth: 5, temperature: 23.8, tankPressure: 65, ndl: 95),
        DiveProfilePoint(time: 40, depth: 3, temperature: 24.0, tankPressure: 55, ndl: 100),
        DiveProfilePoint(time: 42, depth: 0, temperature: 24.2, tankPressure: 50, ndl: 100)
    ]

    let dive = Dive(
        timestamp: Date(),
        location: "Test",
        siteName: "Test Site",
        maxDepth: 28.0,
        averageDepth: 18.0,
        duration: 42,
        waterTemperature: 22.0,
        minTemperature: 20.0,
        profileSamples: samplePoints
    )

    return VStack {
        UnifiedDiveChartOptimized(dive: dive)
            .padding()
    }
    .background(Color.platformBackground)
}

#Preview("Deco Dive") {
    // Realistic deco dive: 40 m bottom, three mandatory deco stops at 18 m / 9 m / 5 m
    let samplePoints: [DiveProfilePoint] = [
        // Descent
        DiveProfilePoint(time: 0,  depth: 0,  temperature: 24.0, tankPressure: 220, ndl: 99),
        DiveProfilePoint(time: 2,  depth: 15, temperature: 22.5, tankPressure: 210, ndl: 60),
        DiveProfilePoint(time: 4,  depth: 30, temperature: 19.0, tankPressure: 200, ndl: 20),
        DiveProfilePoint(time: 5,  depth: 40, temperature: 17.5, tankPressure: 190, ndl: 5),
        // Bottom
        DiveProfilePoint(time: 10, depth: 40, temperature: 17.0, tankPressure: 165, ndl: 0),
        DiveProfilePoint(time: 15, depth: 39, temperature: 17.0, tankPressure: 140, ndl: 0),
        DiveProfilePoint(time: 18, depth: 38, temperature: 17.2, tankPressure: 120, ndl: 0),
        // Ascent begins
        DiveProfilePoint(time: 20, depth: 30, temperature: 18.5, tankPressure: 110, ndl: 0),
        DiveProfilePoint(time: 22, depth: 21, temperature: 20.0, tankPressure: 100, ndl: 0),
        // Deco stop at 18 m (4 min)
        DiveProfilePoint(time: 23, depth: 18, temperature: 21.0, tankPressure: 95, ndl: 0, events: [.decoStop]),
        DiveProfilePoint(time: 24, depth: 18, temperature: 21.0, tankPressure: 90, ndl: 0, events: [.decoStop]),
        DiveProfilePoint(time: 25, depth: 18, temperature: 21.0, tankPressure: 85, ndl: 0, events: [.decoStop]),
        DiveProfilePoint(time: 26, depth: 18, temperature: 21.0, tankPressure: 81, ndl: 0, events: [.decoStop]),
        // Continue ascent
        DiveProfilePoint(time: 28, depth: 12, temperature: 22.0, tankPressure: 76, ndl: 0),
        // Deco stop at 9 m (5 min)
        DiveProfilePoint(time: 29, depth: 9,  temperature: 22.8, tankPressure: 72, ndl: 0, events: [.decoStop]),
        DiveProfilePoint(time: 30, depth: 9,  temperature: 22.8, tankPressure: 68, ndl: 0, events: [.decoStop]),
        DiveProfilePoint(time: 31, depth: 9,  temperature: 22.8, tankPressure: 65, ndl: 0, events: [.decoStop]),
        DiveProfilePoint(time: 32, depth: 9,  temperature: 23.0, tankPressure: 62, ndl: 0, events: [.decoStop]),
        DiveProfilePoint(time: 33, depth: 9,  temperature: 23.0, tankPressure: 59, ndl: 0, events: [.decoStop]),
        // Continue ascent
        DiveProfilePoint(time: 34, depth: 6,  temperature: 23.5, tankPressure: 56, ndl: 0),
        // Deco stop at 5 m (7 min)
        DiveProfilePoint(time: 35, depth: 5,  temperature: 23.8, tankPressure: 53, ndl: 0, events: [.decoStop]),
        DiveProfilePoint(time: 36, depth: 5,  temperature: 23.8, tankPressure: 50, ndl: 0, events: [.decoStop]),
        DiveProfilePoint(time: 37, depth: 5,  temperature: 23.8, tankPressure: 47, ndl: 0, events: [.decoStop]),
        DiveProfilePoint(time: 38, depth: 5,  temperature: 24.0, tankPressure: 44, ndl: 0, events: [.decoStop]),
        DiveProfilePoint(time: 39, depth: 5,  temperature: 24.0, tankPressure: 41, ndl: 0, events: [.decoStop]),
        DiveProfilePoint(time: 40, depth: 5,  temperature: 24.0, tankPressure: 38, ndl: 0, events: [.decoStop]),
        DiveProfilePoint(time: 41, depth: 5,  temperature: 24.0, tankPressure: 35, ndl: 0, events: [.decoStop]),
        // Surface
        DiveProfilePoint(time: 42, depth: 2,  temperature: 24.2, tankPressure: 33, ndl: 5),
        DiveProfilePoint(time: 43, depth: 0,  temperature: 24.5, tankPressure: 30, ndl: 20),
    ]

    let decoStops: [DecoStop] = [
        DecoStop(depth: 18, time: 4 * 60, type: 2), // 4 min at 18 m
        DecoStop(depth: 9,  time: 5 * 60, type: 2), // 5 min at 9 m
        DecoStop(depth: 5,  time: 7 * 60, type: 2), // 7 min at 5 m
    ]

    let dive = Dive(
        timestamp: Date(),
        location: "Test",
        siteName: "Deco Test Site",
        maxDepth: 40.0,
        averageDepth: 22.0,
        duration: 43,
        waterTemperature: 17.0,
        minTemperature: 17.0,
        profileSamples: samplePoints,
        decoStops: decoStops
    )

    return VStack {
        UnifiedDiveChartOptimized(dive: dive)
            .padding()
    }
    .background(Color.platformBackground)
}
