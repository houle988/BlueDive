import SwiftUI
import Charts

// MARK: - Comparable clamping helper

private extension Comparable {
    /// Clamps the value to the given closed range.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Configuration de visibilité des lignes du graphique
struct ChartLineVisibility {
    var showDepth: Bool = true
    var showTemperature: Bool = false
    var showPressure: Bool = false
    var showNDL: Bool = false

    private static let defaultsKey = "chartSecondaryMetric"

    /// Loads the last-used secondary metric from UserDefaults.
    static func restored() -> ChartLineVisibility {
        var v = ChartLineVisibility()
        switch UserDefaults.standard.string(forKey: defaultsKey) {
        case "temperature": v.showTemperature = true
        case "pressure":    v.showPressure = true
        case "ndl":         v.showNDL = true
        default:            break
        }
        return v
    }

    /// Persists the currently active secondary metric to UserDefaults.
    func save() {
        let value: String
        if showTemperature      { value = "temperature" }
        else if showPressure    { value = "pressure" }
        else if showNDL         { value = "ndl" }
        else                    { value = "none" }
        UserDefaults.standard.set(value, forKey: Self.defaultsKey)
    }
}

/// Bouton de toggle personnalisé pour les contrôles du graphique
struct ToggleButton: View {
    @Binding var isOn: Bool
    let icon: String
    let label: LocalizedStringKey
    let color: Color
    var isAvailable: Bool = true
    
    var body: some View {
        Button {
            if isAvailable {
                isOn.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
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

    static func == (lhs: StaticChartLayer, rhs: StaticChartLayer) -> Bool {
        lhs.dive.id == rhs.dive.id &&
        lhs.visibility.showDepth == rhs.visibility.showDepth &&
        lhs.visibility.showTemperature == rhs.visibility.showTemperature &&
        lhs.visibility.showPressure == rhs.visibility.showPressure &&
        lhs.visibility.showNDL == rhs.visibility.showNDL &&
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
            depthMarks
            temperatureMarks
            pressureMarks
            ndlMarks
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
                        Text(String(format: "%.0f\(prefs.depthUnit.symbol)", -v))
                            .font(.caption2)
                            .foregroundStyle(.cyan)
                    }
                }
            }

            // ── Right axis: secondary metrics ──
            if visibility.showPressure || visibility.showTemperature || visibility.showNDL {
                AxisMarks(position: .trailing, values: rightAxisTicks) { value in
                    AxisGridLine().foregroundStyle(Color.clear)
                    AxisValueLabel(anchor: .leading) {
                        if let depth = value.as(Double.self) {
                            HStack(spacing: 3) {
                                if visibility.showPressure {
                                    Text(pressureLabel(for: depth))
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                                if visibility.showTemperature {
                                    if visibility.showPressure {
                                        Text("|").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Text(temperatureLabel(for: depth))
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                                if visibility.showNDL {
                                    if visibility.showPressure || visibility.showTemperature {
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

    // MARK: - Ascent rates

    private var cachedAscentRates: [Double] {
        let samples = dive.profileSamples
        guard samples.count >= 2 else { return [] }
        return (1..<samples.count).map { i in
            let previous = samples[i - 1]
            let current = samples[i]
            let timeDiff = current.time - previous.time
            let depthDiff = previous.depth - current.depth
            return timeDiff > 0 ? (depthDiff / timeDiff) : 0
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
            let allWithNDL = dive.profileSamples.filter { $0.ndl != nil }
            let firstNonZeroIdx = allWithNDL.firstIndex { ($0.ndl ?? 0) != 0 } ?? allWithNDL.startIndex
            let samplesWithNDL = Array(allWithNDL[firstNonZeroIdx...])
            ForEach(samplesWithNDL) { sample in
                if let ndl = sample.ndl {
                    // NDL 100 → y = 0 (top), NDL 0 → y = -displayMaxDepth (bottom)
                    let value = -dive.displayMaxDepth * (1.0 - (min(ndl, 100.0) / 100.0))
                    LineMark(x: .value("Time", sample.time), y: .value("NDL", value), series: .value("Sequence", "NDL"))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Color.ndlYellow)
                }
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
    @State private var cachedNearestSample: DiveProfilePoint? = nil
    
    var body: some View {
        VStack(spacing: 16) {
            toggleControls
            chartView
            
            if !dive.profileSamples.isEmpty {
                legendView
            }
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
                    color: .cyan,
                    isAvailable: true
                )
                
                ToggleButton(
                    isOn: exclusiveBinding(for: \.showTemperature),
                    icon: "thermometer",
                    label: "Temperature",
                    color: .green,
                    isAvailable: hasTemperatureData
                )
            }
            
            HStack(spacing: 12) {
                ToggleButton(
                    isOn: exclusiveBinding(for: \.showPressure),
                    icon: "gauge.with.needle.fill",
                    label: "Pressure",
                    color: .red,
                    isAvailable: hasPressureData
                )
                
                ToggleButton(
                    isOn: exclusiveBinding(for: \.showNDL),
                    icon: "timer",
                    label: "NDL",
                    color: .ndlYellow,
                    isAvailable: hasNDLData
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

        return StaticChartLayer(dive: dive, visibility: visibility, xMax: xMax, prefs: prefs)
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
                        if cursorX != nil, let sample = cachedNearestSample {
                            ChartTooltipView(
                                sample: sample,
                                visibility: visibility,
                                dive: dive,
                                tempMin: tempRange.min,
                                tempMax: tempRange.max,
                                pressMin: pressRange.min,
                                pressMax: pressRange.max,
                                ascentSpeed: ascentSpeed(for: sample)
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
                                            cachedNearestSample = nearestSample(at: fraction * xMax)
                                        }
                                    }
                                    .onEnded { _ in
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            cursorX = nil
                                            cachedNearestSample = nil
                                        }
                                    }
                            )
                    }
                }
            }
    }

    // MARK: - Tooltip Helpers

    /// Returns the sample whose time is closest to `time`.
    private func nearestSample(at time: Double) -> DiveProfilePoint? {
        dive.profileSamples.min(by: { abs($0.time - time) < abs($1.time - time) })
    }

    /// Returns the ascent/descent speed in m/min at the given sample.
    /// Positive = ascending, negative = descending. Uses adjacent samples for calculation.
    private func ascentSpeed(for sample: DiveProfilePoint) -> Double? {
        let samples = dive.profileSamples
        guard samples.count >= 2 else { return nil }
        guard let idx = samples.firstIndex(where: { $0.id == sample.id }) else { return nil }

        let prev: DiveProfilePoint
        let next: DiveProfilePoint
        if idx > 0 && idx < samples.count - 1 {
            // Middle sample: average over both neighbours for a smoother value
            prev = samples[idx - 1]
            next = samples[idx + 1]
        } else if idx > 0 {
            // Last sample
            prev = samples[idx - 1]
            next = sample
        } else {
            // First sample
            prev = sample
            next = samples[idx + 1]
        }

        let timeDiff = next.time - prev.time
        guard timeDiff > 0 else { return nil }
        let depthDiff = prev.depth - next.depth  // positive = ascending
        return depthDiff / timeDiff
    }

    /// Keeps the tooltip card within the plot area horizontally.
    /// `screenX` is already in the overlay's coordinate space (origin-offset included).
    private func tooltipOffsetX(screenX: CGFloat, plotOriginX: CGFloat, plotWidth: CGFloat) -> CGFloat {
        let tooltipWidth: CGFloat = 150
        let padding: CGFloat = 8
        let x = screenX - tooltipWidth / 2
        let minX = plotOriginX + padding
        let maxX = plotOriginX + plotWidth - tooltipWidth - padding
        return x.clamped(to: minX...maxX)
    }

    /// Pre-computed temperature range across all samples (used by tooltip for display).
    private var tempRange: (min: Double?, max: Double?) {
        let temps = dive.profileSamples.compactMap { $0.temperature }
        return (temps.min(), temps.max())
    }

    /// Pre-computed pressure range across all samples (used by tooltip for display).
    private var pressRange: (min: Double?, max: Double?) {
        let pressures = dive.profileSamples.compactMap { $0.tankPressure.map { dive.displayProfilePressure($0) } }
        return (pressures.min(), pressures.max())
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
    
    private func metricLegendRow(color: Color, label: LocalizedStringKey, range: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            (Text(label) + Text(": \(range)"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
    
    // MARK: - Helper Properties
    
    private var hasTemperatureData: Bool {
        dive.profileSamples.contains { $0.temperature != nil }
    }
    
    private var hasPressureData: Bool {
        dive.profileSamples.contains { $0.tankPressure != nil }
    }
    
    private var hasNDLData: Bool {
        dive.profileSamples.contains { $0.ndl != nil }
    }
    
    private var hasVisibleSecondaryMetrics: Bool {
        (visibility.showTemperature && hasTemperatureData) ||
        (visibility.showPressure && hasPressureData) ||
        (visibility.showNDL && hasNDLData)
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
        return "\(Int(minDisplay))-\(Int(maxDisplay)) \(symbol)"
    }

    private func pressureRangeForTank(_ tankIdx: Int) -> String {
        let pressures = dive.profileSamples.compactMap { $0.tankPressures?[tankIdx] }
        guard !pressures.isEmpty, let minP = pressures.min(), let maxP = pressures.max() else { return "—" }
        let minDisplay = dive.displayProfilePressure(minP)
        let maxDisplay = dive.displayProfilePressure(maxP)
        let symbol = prefs.pressureUnit.symbol
        return "\(Int(minDisplay))-\(Int(maxDisplay)) \(symbol)"
    }
    
    private var ndlRange: String {
        let ndls = dive.profileSamples.compactMap { $0.ndl }
        guard !ndls.isEmpty, let min = ndls.min(), let max = ndls.max() else { return "—" }
        return String(format: "%.0f-%.0f min", min, max)
    }
    
}

// MARK: - Chart Tooltip

/// Popup card that appears above the drag cursor showing depth, temperature, pressure and NDL
/// for the nearest profile sample.
struct ChartTooltipView: View {
    let sample: DiveProfilePoint
    let visibility: ChartLineVisibility
    let dive: Dive

    // Pre-computed ranges passed in to avoid recomputing inside the view
    let tempMin: Double?
    let tempMax: Double?
    let pressMin: Double?
    let pressMax: Double?

    /// Ascent/descent speed in m/min at this sample (positive = ascending, negative = descending)
    let ascentSpeed: Double?

    @State private var prefs = UserPreferences.shared

    // MARK: Formatted values

    private var timeLabel: String {
        let totalSec = Int(sample.time * 60)
        let m = totalSec / 60
        let s = totalSec % 60
        return String(format: "%d:%02d", m, s)
    }

    private var depthLabel: String {
        let converted = dive.displayProfileDepth(sample.depth)
        let symbol = UserPreferences.shared.depthUnit.symbol
        return String(format: "%.1f \(symbol)", converted)
    }

    private var temperatureLabel: String? {
        guard let t = sample.temperature else { return nil }
        // Route through the dive's import metadata so the stored unit is respected.
        return prefs.temperatureUnit.formatted(t, from: dive.storedTemperatureUnit)
    }

    private var pressureLabel: String? {
        guard let p = sample.tankPressure else { return nil }
        // Use the dive's unit-aware conversion — never apply heuristics directly.
        return dive.formattedPressure(p)
    }

    /// Per-tank pressure labels for multi-tank tooltip.
    private var perTankPressureLabels: [(index: Int, label: String)]? {
        guard let tp = sample.tankPressures, tp.count > 1 else { return nil }
        return tp.sorted(by: { $0.key < $1.key }).map { (index: $0.key, label: dive.formattedPressure($0.value)) }
    }
    
    private var ndlLabel: String? {
        guard let ndl = sample.ndl else { return nil }
        return String(format: "%.0f min", ndl)
    }

    private var ascentSpeedLabel: String? {
        guard let speed = ascentSpeed else { return nil }
        let displaySpeed = prefs.depthUnit.convert(abs(speed))
        let symbol = prefs.depthUnit.symbol
        return String(format: "%.1f %@/min", displaySpeed, symbol)
    }

    /// Colour for ascent speed: cyan for descent, orange for fast ascent, red for dangerous ascent
    private var ascentSpeedColor: Color {
        guard let speed = ascentSpeed else { return .secondary }
        if speed <= 0 { return .cyan }       // descending or level
        if speed >= 18 { return .red }       // dangerous (≥18 m/min)
        if speed >= 10 { return .orange }    // fast (10-18 m/min)
        return .cyan                          // normal ascent
    }

    /// Arrow icon indicating ascent or descent direction
    private var ascentSpeedIcon: String {
        guard let speed = ascentSpeed else { return "arrow.up.arrow.down" }
        if abs(speed) < 0.5 { return "equal" }  // essentially level
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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 150, alignment: .leading)
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

#Preview {
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

