import SwiftUI
import SwiftData
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
    /// Ceiling held from the nearest earlier real sample — never interpolated between
    /// two reported ceilings, so no value the dive computer did not report is shown.
    let ceilingDepth: Double?
    let ppo2: Double?
    let sensorPPO2: [Int: Double]?
    let events: [DiveProfileEvent]
    let currentGas: Int?
    /// CCR setpoint held from the nearest earlier real sample — never interpolated, and nil
    /// where that sample reported none (e.g. on open-circuit bailout).
    let setpoint: Double?
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

/// The chart's line selection, shared by every dive chart (dive detail, its Samples tab and,
/// on macOS, the dive list's profile preview): a chip toggled in one chart updates the others
/// at once. Loaded once from UserDefaults; each change is persisted with `save()`.
@Observable
final class SharedChartLineVisibility {
    static let shared = SharedChartLineVisibility()
    var value = ChartLineVisibility.restored()
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
/// median of physical O₂ cells → computed from gas mix + depth (Dalton's Law), the last only
/// for open-circuit samples: a sample with a CCR setpoint is on the loop, where the breathed
/// PPO₂ is not the diluent's, so it gets no PPO₂ unless the computer reported one.
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

/// Sorted O2 sensor indices that have per-sensor PPO2 data across all profile samples.
fileprivate func sensorPPO2Indices(for dive: Dive) -> [Int] {
    var indices = Set<Int>()
    for sample in dive.profileSamples {
        if let sp = sample.sensorPPO2 { indices.formUnion(sp.keys) }
    }
    return indices.sorted()
}

/// A dive's CCR setpoint data, shared by the change markers, the setpoint line, the PPO₂ scale
/// and the legend, so they always agree on where a setpoint is set and where its runs start and
/// end: the changes and the line come from one pass over the samples, the range from
/// `range(for:)`. Stored setpoints are always valid
/// (`DiveProfilePoint.validSetpoint(_:)`). Empty for dives without setpoint data.
fileprivate struct SetpointProfile {
    /// Samples where the setpoint is set: the first sample with a setpoint, every sample whose
    /// setpoint differs from the previous sample's, and the return to the loop after a gap with
    /// no setpoint (e.g. open-circuit bailout), even at the same value — where the setpoint line
    /// restarts and the UDDF export writes a new <setpo2>.
    let changes: [DiveProfilePoint]
    /// The setpoint as a dashed step line, one series per run of samples with a setpoint: the
    /// line breaks where the computer reported none instead of bridging the gap. Only each run's
    /// ends and the corners of each step are emitted (explicit corners keep the steps square
    /// without relying on an interpolation method). Each run is held to the next sample's time
    /// (the first sample without a setpoint), as the tooltip holds the setpoint until the next
    /// sample; the dive's last run ends at its last sample. A run that is still a single point
    /// (one sample at the very end of the dive) is drawn as a dot (`singlePointRuns`). Empty
    /// unless built with `includeLine` (the line is drawn only while PPO₂ is shown).
    let linePoints: [(run: Int, time: Double, setpoint: Double)]
    /// Lowest to highest setpoint; nil when the dive has none (`range(for:)`).
    let range: ClosedRange<Double>?

    init(dive: Dive, includeLine: Bool) {
        var changes: [DiveProfilePoint] = []
        var points: [(run: Int, time: Double, setpoint: Double)] = []
        var run = 0
        var previous: Double?
        var lastTime = 0.0
        /// Ends the current run at `nextTime` (the next sample's time), or at its last sample
        /// at the end of the dive.
        func closeRun(nextTime: Double?) {
            guard includeLine, let previous, let last = points.last, last.run == run else { return }
            let end = nextTime ?? lastTime
            if end > last.time {
                points.append((run: run, time: end, setpoint: previous))
            }
        }
        for sample in dive.profileSamples {
            guard let setpoint = sample.setpoint else {
                if previous != nil {
                    closeRun(nextTime: sample.time)
                    run += 1
                }
                previous = nil
                continue
            }
            if previous == nil {
                changes.append(sample)
                if includeLine {
                    points.append((run: run, time: sample.time, setpoint: setpoint))
                }
            } else if let previous, previous != setpoint {
                changes.append(sample)
                if includeLine {
                    points.append((run: run, time: sample.time, setpoint: previous))
                    points.append((run: run, time: sample.time, setpoint: setpoint))
                }
            }
            previous = setpoint
            lastTime = sample.time
        }
        closeRun(nextTime: nil)
        self.changes = changes
        self.linePoints = points
        self.range = Self.range(for: dive)
    }

    /// Lowest to highest setpoint of the dive, without building the markers and line; nil when
    /// the dive has none. The only place the range is computed.
    static func range(for dive: Dive) -> ClosedRange<Double>? {
        var low = Double.greatestFiniteMagnitude
        var high = -Double.greatestFiniteMagnitude
        for sample in dive.profileSamples {
            guard let setpoint = sample.setpoint else { continue }
            low = min(low, setpoint)
            high = max(high, setpoint)
        }
        return low <= high ? low...high : nil
    }
}

/// Runs (series) with a single point: Swift Charts draws no line for them, so the chart draws
/// each as a dot instead of dropping a value the dive computer reported.
fileprivate func singlePointRuns(_ runs: [Int]) -> Set<Int> {
    var counts: [Int: Int] = [:]
    for run in runs { counts[run, default: 0] += 1 }
    return Set(counts.compactMap { $0.value == 1 ? $0.key : nil })
}

/// The dive and a fingerprint of its samples (count, and the first and last sample ids), so a
/// view or cache depending on the profile is rebuilt when the profile is replaced while the
/// chart is shown (a dive merge, a Bluetooth re-download, an iCloud update): every import builds
/// new samples with new ids, so a replacement of the same length is detected too. Cheap to
/// compare: the legend checks it on every cursor move.
fileprivate struct ProfileCacheID: Equatable {
    let diveID: UUID
    let sampleCount: Int
    let firstSampleID: UUID?
    let lastSampleID: UUID?

    init(dive: Dive) {
        let samples = dive.profileSamples
        diveID = dive.id
        sampleCount = samples.count
        firstSampleID = samples.first?.id
        lastSampleID = samples.last?.id
    }
}

extension Color {
    /// Colour of the CCR setpoint: the chart's markers, line, legend entry and tooltip row, and
    /// the Samples table's SP column.
    static var ccrSetpoint: Color { .mint }
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

// MARK: - Deco obligation window

/// The chart time (minutes) after which the dive computer no longer reported any
/// decompression obligation, or `nil` when the dive never carried one.
///
/// A sample is treated as obligation-bearing when it carries the `.decoStop` event **or**
/// a ceiling greater than zero. The two signals are unioned, not intersected, because the
/// importers disagree about which one they populate: `GarminFITParser` appends `.decoStop`
/// with a nil ceiling when the watch stops reporting `nextStopDepth`, while
/// `BluetoothScannerView+ProfileProcessing` sets both together. Unioning yields the
/// *latest* possible cutoff, which makes every caller as conservative as possible — a
/// diamond wrongly hidden is far worse than one wrongly kept.
///
/// The `> 0` ceiling gate (rather than a plain non-nil check) matches every other site in
/// the app (see `hasCeilingData` below, and `ceilingLabel` in the tooltip): the importers
/// exclude a reported-but-zero ceiling at the source today, but dives imported before that
/// gate existed can still have a literal `0` persisted, and a non-nil zero must read as
/// "no real obligation" here.
///
/// The returned cutoff is the smallest sample time strictly greater than the last
/// obligation-bearing sample (falling back to that sample's own time when it is the final
/// sample). That one-interval grace is a real recorded timestamp, never an invented
/// constant, and it protects the legitimate case where the computer clears the obligation
/// at 3.4 m while the interpolated 3 m crossing lands a few seconds later inside that same
/// sample interval.
///
/// Both passes are order-independent operations over the whole array — never
/// `samples[i + 1]` — because importer sample order is not guaranteed.
///
/// `nil` means "filter nothing": callers must leave their results untouched.
func decoObligationEndTime(in samples: [DiveProfilePoint]) -> Double? {
    var last: Double? = nil
    for s in samples where s.events.contains(.decoStop) || (s.ceilingDepth ?? 0) > 0 {
        if last == nil || s.time > last! { last = s.time }
    }
    guard let last else { return nil }
    return samples.lazy.map(\.time).filter { $0 > last }.min() ?? last
}

/// Bouton de toggle personnalisé pour les contrôles du graphique
struct ToggleButton: View {
    @Binding var isOn: Bool
    let icon: String
    let label: LocalizedStringKey
    var shortLabel: LocalizedStringKey? = nil
    let color: Color
    /// Label colour when on; `color` if nil. A deeper shade keeps the label readable on the
    /// chip's light tint in light mode (see `Color.readableOnTint`).
    var textColor: Color? = nil
    var isAvailable: Bool = true
    /// False for an icon-only chip where the row has no room for the label; the caller then
    /// sets the accessibility label.
    var showsLabel: Bool = true

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
                if showsLabel {
                    labelText
                        .font(.caption2)
                }
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
            .foregroundStyle(isAvailable ? (isOn ? (textColor ?? color) : .secondary) : .gray)
            .opacity(isAvailable ? 1.0 : 0.5)
        }
        .disabled(!isAvailable)
        .buttonStyle(.plain)
    }
}

// MARK: - Secondary axis scale

/// Range and label spacing of the secondary (right-axis) metric, in its display unit.
/// `lower` and `upper` are the metric values at the two ends of the plot; both are
/// multiples of `step`, so every right-axis label shows a round value. The PDF logbook's
/// profile uses the same rounding for its depth and time labels.
struct SecondaryAxisScale {
    let lower: Double
    let upper: Double
    let step: Double

    var span: Double { upper - lower }

    /// Values that get a right-axis label, from `lower` to `upper` in `step` increments.
    var labelValues: [Double] {
        guard step > 0, span > 0, (span / step).isFinite else { return [lower] }
        let count = min(Int((span / step).rounded()), 50)
        return (0...count).map { lower + Double($0) * step }
    }

    /// Decimals needed to show every multiple of `step` exactly (0.25 → 2, 0.5 → 1, 50 → 0).
    var labelDecimals: Int {
        var decimals = 0
        var scaled = step
        while decimals < 3, abs(scaled - scaled.rounded()) > 1e-9 {
            scaled *= 10
            decimals += 1
        }
        return decimals
    }

    /// Scale covering `low...high`, with both ends rounded outward to a round step chosen
    /// to give about `targetIntervals` (by default five) intervals. `multipliers` are the allowed leading digits of the
    /// step (`[1, 2, 5]` keeps whole values, `[1, 2, 2.5, 5]` also allows 25 bar or
    /// 0.25 bar); `minimumStep` is the smallest step allowed (1 for whole degrees or
    /// minutes). A flat series still spans one step. `topHeadroom` adds a step when the
    /// highest value lands on the top of the scale (see below); pass false when `high`
    /// is already padded. `targetIntervals` sets how many intervals the step aims for.
    static func rounded(low: Double, high: Double,
                        multipliers: [Double] = [1, 2, 2.5, 5],
                        minimumStep: Double = 0,
                        topHeadroom: Bool = true,
                        targetIntervals: Double = 5) -> SecondaryAxisScale {
        // A flat series (e.g. a pressure that never changed) gets a step sized from its
        // value rather than from a zero span.
        let span = high > low ? high - low : max(abs(high) * 0.2, 1.0)
        let rawStep = max(span / max(targetIntervals, 1), minimumStep, 1e-6)
        let magnitude = pow(10.0, floor(log10(rawStep)))
        let normalised = rawStep / magnitude
        let multiplier = multipliers.first { $0 >= normalised - 1e-9 } ?? 10
        let step = max(multiplier * magnitude, minimumStep)
        let lower = (low / step).rounded(.down) * step
        var upper = (high / step).rounded(.up) * step
        // The top of the scale is the plot's clipped top edge for pressure, temperature
        // and NDL: when the highest value lands on (or just below) a round value, add one
        // step so the trace is not drawn along that edge.
        if topHeadroom, upper - high < step * 0.05 { upper += step }
        if upper <= lower { upper = lower + step }
        return SecondaryAxisScale(lower: lower, upper: upper, step: step)
    }
}

// MARK: - Time-axis label centring

/// Places its single subview so the subview's horizontal centre sits on this layout's
/// leading edge. Used inside an x-axis `AxisValueLabel`, whose leading edge Swift Charts
/// puts on the gridline, to centre the label under its line (the dive profile's time
/// axis and the Statistics trend chart's months).
struct CenteredOnAxisValue: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(.unspecified) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let size = subview.sizeThatFits(.unspecified)
        subview.place(at: CGPoint(x: bounds.minX - size.width / 2, y: bounds.minY), proposal: .unspecified)
    }
}

// MARK: - Static Chart Layer (never re-renders on cursor move)

/// Ce view contient uniquement les courbes — il est Equatable donc SwiftUI
/// ne le re-rend QUE si dive ou visibility changent, jamais quand le curseur bouge.
private struct StaticChartLayer: View, Equatable {
    let dive: Dive
    let visibility: ChartLineVisibility
    let xMax: Double
    /// Depth, in the display unit, that sets the bottom of the chart: the dive's max depth, or
    /// the deepest profile sample when that is deeper (a computer's recorded maximum can be a
    /// little shallower than a sample, e.g. through rounding). Only the axis range and the
    /// overlay scales use it; every sample still plots at its own recorded value.
    let depthBase: Double
    let prefs: UserPreferences
    /// Hash of tanks' O₂ fractions — changes when gas mix is edited, allowing the
    /// Equatable check to detect tank mutations even though dive.id is stable.
    let tanksO2Hash: Int
    /// Fingerprint of the display units (depth/temperature/pressure) — changes when
    /// the user switches units, so the Equatable check re-renders the axis labels and
    /// mark positions even though `dive.id` and `prefs` (a shared reference) are stable.
    let unitsHash: Int
    /// Passed in as a value rather than read from `prefs` inside the body so the Equatable
    /// contract below stays honest: `prefs` is the shared `UserPreferences` singleton, so a
    /// newly-flipped Bool on it could never make two `StaticChartLayer` values compare
    /// unequal on its own.
    let hideClearedDecoStops: Bool
    /// The profile's fingerprint, so the layer redraws when the samples are replaced (e.g. a
    /// re-download that adds setpoints) even though `dive.id` is stable.
    let profileID: ProfileCacheID
    #if os(macOS)
    /// How the plot height follows the window: the dive detail view's rule by default, a
    /// lower one for the dive list's profile preview.
    var heightRule: ChartHeightRule = .detail
    #endif

    static func == (lhs: StaticChartLayer, rhs: StaticChartLayer) -> Bool {
        #if os(macOS)
        guard lhs.heightRule == rhs.heightRule else { return false }
        #endif
        return lhs.dive.id == rhs.dive.id &&
        lhs.profileID == rhs.profileID &&
        lhs.tanksO2Hash == rhs.tanksO2Hash &&
        lhs.unitsHash == rhs.unitsHash &&
        lhs.hideClearedDecoStops == rhs.hideClearedDecoStops &&
        lhs.visibility.showDepth == rhs.visibility.showDepth &&
        lhs.visibility.showTemperature == rhs.visibility.showTemperature &&
        lhs.visibility.showPressure == rhs.visibility.showPressure &&
        lhs.visibility.showNDL == rhs.visibility.showNDL &&
        lhs.visibility.showPPO2 == rhs.visibility.showPPO2 &&
        lhs.visibility.showDeco == rhs.visibility.showDeco &&
        lhs.xMax == rhs.xMax &&
        lhs.depthBase == rhs.depthBase
    }

    // MARK: - Secondary axis scales

    // Each secondary metric's scale comes from the dive's own samples, in the display
    // unit, rounded outward to a round step (see `SecondaryAxisScale.rounded`). The right
    // axis labels those round values at their own heights, so a label always names the
    // trace value at its height. The scales only position marks and labels; no sample
    // value is altered.

    /// Pressure scale: the lowest to the highest reading across every tank the chart
    /// draws (the per-tank pressures when there are several tanks, the single tank
    /// pressure otherwise — the same samples `pressureMarks` plots), in the display unit.
    /// Falls back to 0–300 bar, in the display unit, when the dive has no pressure samples.
    /// The step is at least 10 bar (100 psi, 1 000 000 Pa), so a nearly flat trace — a short
    /// dive or a tank barely breathed from — is not labelled in fractions of a bar.
    /// `tankIndices` is computed once in `body` and shared with `pressureMarks`.
    private func pressureAxis(tankIndices: [Int]) -> SecondaryAxisScale {
        let minimumStep: Double
        switch prefs.pressureUnit {
        case .bar: minimumStep = 10
        case .psi: minimumStep = 100
        case .pa:  minimumStep = 1_000_000
        }
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        func include(_ raw: Double) {
            let value = dive.displayProfilePressure(raw)
            if value < lo { lo = value }
            if value > hi { hi = value }
        }
        for sample in dive.profileSamples {
            if tankIndices.count > 1 {
                guard let pressures = sample.tankPressures else { continue }
                for idx in tankIndices {
                    if let raw = pressures[idx] { include(raw) }
                }
            } else if let raw = sample.tankPressure {
                include(raw)
            }
        }
        guard lo <= hi else {
            return .rounded(low: 0, high: prefs.pressureUnit.convert(300, from: .bar), minimumStep: minimumStep)
        }
        return .rounded(low: lo, high: hi, minimumStep: minimumStep)
    }

    /// Temperature scale in whole degrees. Derived from the dive's own temperature samples
    /// with padding (10 % of the span, at least 2°) so the trace never touches the plot
    /// edges, then rounded outward to a step of 1, 2, 5 or 10 degrees. Falls back to a
    /// fixed range per unit when the dive has no temperature samples.
    private var temperatureAxis: SecondaryAxisScale {
        // Single allocation-free pass over the samples to find the display-unit
        // temperature extremes.
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for sample in dive.profileSamples {
            guard let raw = sample.temperature else { continue }
            let value = dive.displayProfileTemperature(raw)
            if value < lo { lo = value }
            if value > hi { hi = value }
        }
        guard lo <= hi else {
            switch prefs.temperatureUnit {
            case .celsius:    return .rounded(low: -10, high: 30, multipliers: [1, 2, 5], minimumStep: 1, topHeadroom: false)
            case .fahrenheit: return .rounded(low: 14, high: 86, multipliers: [1, 2, 5], minimumStep: 1, topHeadroom: false)
            case .kelvin:     return .rounded(low: 263, high: 303, multipliers: [1, 2, 5], minimumStep: 1, topHeadroom: false)
            }
        }
        let span = max(hi - lo, 1.0)
        let pad = max(span * 0.1, 2.0)
        return .rounded(low: lo - pad, high: hi + pad, multipliers: [1, 2, 5], minimumStep: 1, topHeadroom: false)
    }

    /// NDL scale in whole minutes: the lowest to the highest value `ndlMarks` plots
    /// (0 while a deco stop is owed; readings capped at 99 as in `ndlMarks`). Falls back
    /// to 0–100 min when the dive has no NDL samples.
    /// `series` (`ndlSeriesSamples`) is computed once in `body` and shared with `ndlMarks`.
    private func ndlAxis(series: [DiveProfilePoint]) -> SecondaryAxisScale {
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for sample in series {
            guard let ndl = ndlPlotValue(for: sample) else { continue }
            let value = min(ndl, ndlPlotCap)
            if value < lo { lo = value }
            if value > hi { hi = value }
        }
        guard lo <= hi else {
            return .rounded(low: 0, high: 100, multipliers: [1, 2, 5], minimumStep: 1)
        }
        let scale = SecondaryAxisScale.rounded(low: lo, high: hi, multipliers: [1, 2, 5], minimumStep: 1)
        // When the trace reaches the cap (99, readings above it included), the scale ends
        // at the cap rather than at the rounded 100, so the capped line and its top label
        // sit on the plot's top edge instead of just below it. The other labels keep their
        // round values.
        guard hi >= ndlPlotCap else { return scale }
        return SecondaryAxisScale(lower: scale.lower, upper: ndlPlotCap, step: scale.step)
    }

    /// PPO₂ scale: from 0 to the highest value `ppo2Marks` plots (every O₂ sensor when the
    /// dive has per-sensor readings, and the voted or computed PPO₂ in `data`), never below
    /// 1.6 bar so a low-PPO₂ dive is still drawn against the usual working limits.
    /// `sensorIndices` and `data` are computed once in `body` and shared with `ppo2Marks`;
    /// `setpointRange` comes from the body's `SetpointProfile`.
    private func ppo2Axis(sensorIndices: [Int], data: [(time: Double, ppo2: Double, run: Int, joinsPrevious: Bool)],
                          setpointRange: ClosedRange<Double>?) -> SecondaryAxisScale {
        var hi = 0.0
        if !sensorIndices.isEmpty {
            for sample in dive.profileSamples {
                guard let readings = sample.sensorPPO2 else { continue }
                for idx in sensorIndices {
                    if let ppo2 = readings[idx], ppo2 > hi { hi = ppo2 }
                }
            }
        }
        for point in data where point.ppo2 > hi { hi = point.ppo2 }
        // The setpoint line is drawn on the same scale.
        if let setpointRange, setpointRange.upperBound > hi { hi = setpointRange.upperBound }
        return .rounded(low: 0, high: max(hi, ppo2AxisMinimumMax))
    }

    /// Lowest top of the PPO₂ scale, in bar.
    private let ppo2AxisMinimumMax: Double = 1.6

    /// PPO₂ is drawn from 0 at the surface line growing downward; the other metrics put
    /// their highest value at the surface line.
    private var secondaryAxisIncreasesDownward: Bool { visibility.showPPO2 }

    /// Plot Y of a secondary-metric value: `scale.upper` at the surface line (y = 0) and
    /// `scale.lower` at the chart depth (y = -depthBase), or the reverse when
    /// `increasesDownward`. Values outside the scale are clamped to the plot.
    private func plotY(_ value: Double, on scale: SecondaryAxisScale, increasesDownward: Bool = false) -> Double {
        guard scale.span > 0 else { return 0 }
        let normalised = ((value - scale.lower) / scale.span).clamped(to: 0...1)
        return -depthBase * (increasesDownward ? normalised : 1.0 - normalised)
    }

    /// Inverse of `plotY`: the metric value at a right-axis mark, snapped to the scale's
    /// step so floating-point error never shows in a label.
    private func secondaryValue(atY y: Double, on scale: SecondaryAxisScale) -> Double {
        guard depthBase > 0 else { return scale.lower }
        let fraction = (-y) / depthBase
        let normalised = secondaryAxisIncreasesDownward ? fraction : 1.0 - fraction
        let value = scale.lower + normalised * scale.span
        var snapped = (value / scale.step).rounded() * scale.step
        // Normalise negative zero so a label never reads "-0".
        if snapped == 0 { snapped = 0 }
        return snapped
    }

    /// Plot Y positions of the right-axis labels.
    private func secondaryAxisMarks(_ scale: SecondaryAxisScale?) -> [Double] {
        // With no depth (every sample at 0 m) all values would map to the same height.
        guard let scale, depthBase > 0 else { return [] }
        var values = scale.labelValues
        if ndlIsRightAxisMetric, values.contains(where: { $0 >= ndlPlotCap }) {
            // NDL is plotted up to `ndlPlotCap` (99 min), so the top label of a scale
            // reaching it sits at the height of 99 and reads 99 (see `ndlTopLabel`). A label
            // within half a step below it (98 on a 2-minute step) would crowd it, so it is
            // left out.
            values = values.map { min($0, ndlPlotCap) }
            values.removeAll { $0 < ndlPlotCap && ndlPlotCap - $0 <= scale.step / 2 }
        }
        return values.map { plotY($0, on: scale, increasesDownward: secondaryAxisIncreasesDownward) }
    }

    /// True when NDL is the right axis's metric: shown, and not overridden by a metric
    /// that comes first in `secondaryAxisLabel`'s order (PPO₂, pressure, temperature).
    private var ndlIsRightAxisMetric: Bool {
        visibility.showNDL && !visibility.showPPO2 && !visibility.showPressure && !visibility.showTemperature
    }

    /// Highest NDL the chart plots, in minutes: readings above it are drawn at this value,
    /// as dive computers such as Shearwater display them.
    private let ndlPlotCap: Double = 99

    /// Text of the top NDL label when the scale reaches `ndlPlotCap` ("99min"), or nil
    /// for an ordinary label. The top label is recognised by its position (the height of
    /// the cap), not by its value: snapped to the step, 99 can round to 100 and the label
    /// below it to 98.
    private func ndlTopLabel(atY y: Double, scale: SecondaryAxisScale) -> String? {
        guard scale.upper >= ndlPlotCap else { return nil }
        let capY = plotY(ndlPlotCap, on: scale)
        guard abs(y - capY) < max(depthBase, 1) * 1e-6 else { return nil }
        return ndlPlotCap.localizedString(decimals: 0) + "min"
    }

    // MARK: - Right-axis label builders

    /// Right-axis label text for whichever secondary metric is active. The four metrics
    /// are mutually exclusive in the toggle UI, so only one branch is ever live — but this
    /// stays a plain value computation rather than branching inside the axis's ViewBuilder
    /// content, which is what keeps that content's view-tree shape stable across toggles.
    private func secondaryAxisLabel(for y: Double, scale: SecondaryAxisScale?) -> String {
        guard let scale else { return "" }
        let value = secondaryValue(atY: y, on: scale)
        let decimals = scale.labelDecimals
        if visibility.showPPO2 {
            return value.localizedString(decimals: decimals, minDecimals: decimals) + " bar"
        }
        if visibility.showPressure {
            return prefs.pressureUnit.formatted(value, from: prefs.pressureUnit, decimals: decimals)
        }
        if visibility.showTemperature {
            return value.localizedString(decimals: decimals, minDecimals: decimals) + prefs.temperatureUnit.symbol
        }
        if visibility.showNDL {
            // The top label names the plotted cap (99), not the rounded step above it.
            if let top = ndlTopLabel(atY: y, scale: scale) { return top }
            return value.localizedString(decimals: decimals) + "min"
        }
        return ""
    }

    private var secondaryAxisColor: Color {
        if visibility.showPPO2 { return .indigo }
        if visibility.showPressure { return .red }
        if visibility.showTemperature { return .green }
        if visibility.showNDL { return Color.ndlYellow }
        return .secondary
    }

    // The Y domain — depth values are negated so deeper = more negative = lower on chart.
    // Swift Charts naturally puts smaller values at the bottom, so negating gives us
    // surface (0) at top and max depth at bottom with no reversal tricks needed.
    // The 5% extra ensures the deepest line isn't clipped at the plot edge.
    private var yDomainMin: Double {
        let base = depthBase
        guard base > 0 else { return -1 }
        return -(base * 1.05)
    }

    var body: some View {
        // Compute each shown metric's scale once per render, then thread it into its marks
        // and every right-axis label so the sample scan runs a single time instead of once
        // per mark or axis label.
        // PPO₂ sources, shared by its scale and its marks: the per-sensor readings, and the
        // voted or computed series — for the whole dive when there are no sensor readings, for
        // the open-circuit bailout samples only when there are.
        let ppo2Sensors = visibility.showPPO2 ? chartSensorIndices : []
        let ppo2Data = visibility.showPPO2 ? (ppo2Sensors.isEmpty ? ppo2RenderData : ppo2BailoutRenderData) : []
        // Setpoint data, shared by the markers, the setpoint line and the PPO₂ scale.
        let setpoints = SetpointProfile(dive: dive, includeLine: visibility.showPPO2)
        let ppo2Scale = visibility.showPPO2 ? ppo2Axis(sensorIndices: ppo2Sensors, data: ppo2Data, setpointRange: setpoints.range) : nil
        // Pressure and NDL sources, likewise shared by each scale and its marks.
        let pressureTanks = visibility.showPressure ? chartTankIndices : []
        let ndlSeries = visibility.showNDL ? ndlSeriesSamples : []
        let pressureScale = visibility.showPressure ? pressureAxis(tankIndices: pressureTanks) : nil
        let temperatureScale = visibility.showTemperature ? temperatureAxis : nil
        let ndlScale = visibility.showNDL ? ndlAxis(series: ndlSeries) : nil
        // Same order as `secondaryAxisLabel` and `secondaryAxisColor`.
        let rightAxisScale = ppo2Scale ?? pressureScale ?? temperatureScale ?? ndlScale
        return Chart {
            legacyDecoBand
            depthMarks
            decoMarks
            gasChangeMarks
            setpointChangeMarks(setpoints.changes)
            if let temperatureScale { temperatureMarks(scale: temperatureScale) }
            if let pressureScale { pressureMarks(scale: pressureScale, tankIndices: pressureTanks) }
            if let ndlScale { ndlMarks(scale: ndlScale, series: ndlSeries) }
            if let ppo2Scale { ppo2Marks(scale: ppo2Scale, sensorIndices: ppo2Sensors, data: ppo2Data, setpointLine: setpoints.linePoints) }
        }
        // Explicit domain from yDomainMin (deepest, negative) to 0 (surface).
        // No automatic padding — the chart fills exactly to the data.
        .chartYScale(domain: yDomainMin...0)
        .chartXScale(domain: 0...xMax)
        .chartPlotStyle { plotArea in
            // Clip 1 pt outside the plot (half the 2 pt trace width), so a trace running
            // along an edge — NDL at its 99 cap, the depth line at the surface — is drawn
            // at full width instead of losing its outer half.
            plotArea.clipShape(Rectangle().inset(by: -1))
        }
        .chartXAxis {
            AxisMarks(values: .automatic) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    // Appearance-adaptive: primary is white in dark mode (unchanged
                    // look) and black in light mode, so the grid stays visible on
                    // both dark and light chart backgrounds.
                    .foregroundStyle(Color.primary.opacity(0.2))
                // Swift Charts starts each time label at its gridline (an `anchor: .top`
                // is rejected as unsupported), so the label sits right of the line.
                // With no extra spacing, `CenteredOnAxisValue` shifts it back by half its
                // width so it is centred under the line.
                AxisValueLabel(horizontalSpacing: 0) {
                    if let time = value.as(Double.self) {
                        CenteredOnAxisValue {
                            // "min" is the same in every app language (the "%lld min" key
                            // is not translated); the number follows the region's formatting.
                            Text(verbatim: time.localizedString(decimals: 0) + " min")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .chartYAxis {
            // ── Left axis: depth, shown as positive numbers increasing downward ──
            AxisMarks(position: .leading, values: .automatic) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    // Appearance-adaptive: primary is white in dark mode (unchanged
                    // look) and black in light mode, so the grid stays visible on
                    // both dark and light chart backgrounds.
                    .foregroundStyle(Color.primary.opacity(0.2))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        // v is negative (or -0.0 at the surface) — use abs() to show a
                        // positive depth and normalise negative zero, which would
                        // otherwise render as "-0m".
                        Text(verbatim: abs(v).localizedString(decimals: 0) + prefs.depthUnit.symbol)
                            .font(.caption2)
                            .foregroundStyle(.cyan)
                    }
                }
            }

            // ── Right axis: secondary metrics ──
            // The labels sit at the metric's own round values (`secondaryAxisMarks`), not
            // on the depth gridlines, and carry no tick or gridline: a short tick beside a
            // number reads as a minus sign. A small left-pointing triangle outline points each
            // label at the height it names instead.
            if let rightAxisScale {
                AxisMarks(position: .trailing, values: secondaryAxisMarks(rightAxisScale)) { value in
                    // A structurally-stable label, not a branching one: Swift Charts does not
                    // redraw AxisValueLabel content when the active branch of an if/switch
                    // inside it changes between updates (confirmed by direct testing), which
                    // left the axis blank when switching between secondary metrics until the
                    // whole AxisMarks was torn down and rebuilt. The triangle and text are always
                    // present, and the string/colour are computed as plain values, so the view
                    // tree shape stays constant across every toggle combination.
                    AxisValueLabel(anchor: .leading) {
                        if let depth = value.as(Double.self) {
                            HStack(spacing: 2) {
                                Image(systemName: "arrowtriangle.left")
                                    .imageScale(.small)
                                    .fontWeight(.bold)
                                    // Decorative: VoiceOver reads only the value.
                                    .accessibilityHidden(true)
                                Text(secondaryAxisLabel(for: depth, scale: rightAxisScale))
                            }
                            .font(.caption2)
                            .foregroundStyle(secondaryAxisColor)
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .macChartHeight(heightRule)
        #else
        .frame(height: 300)
        #endif
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

    // MARK: - Setpoint change markers

    /// A square on the depth curve wherever the CCR setpoint changes, labelled with the new
    /// setpoint below the curve (gas switch labels sit above it, so both stay readable when
    /// they happen at the same time).
    @ChartContentBuilder
    private func setpointChangeMarks(_ changes: [DiveProfilePoint]) -> some ChartContent {
        ForEach(changes) { sample in
            PointMark(
                x: .value("Setpoint Change", sample.time),
                y: .value("Depth", -dive.displayProfileDepth(sample.depth))
            )
            .symbol(.square)
            .symbolSize(70)
            .foregroundStyle(Color.ccrSetpoint)
            // Below the curve; moved back inside the plot when the change is at the deepest
            // point, where the plot (clipped at its edges) has no room below it.
            .annotation(position: .bottom, alignment: .center,
                        overflowResolution: .init(x: .fit(to: .plot), y: .fit(to: .plot))) {
                Text(verbatim: String(format: NSLocalizedString("SP %@", bundle: Bundle.forAppLanguage(), value: "SP %@", comment: "Dive chart chip at a CCR setpoint change; %@ is the new setpoint in bar, e.g. '1.30'"),
                                      (sample.setpoint ?? 0).localizedString(decimals: 2, minDecimals: 2)))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.ccrSetpoint)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.ccrSetpoint.opacity(0.15)))
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
                    y: .value("Depth", -dive.displayProfileDepth(sample.depth)),
                    series: .value("Sequence", "Depth")
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
    private func temperatureMarks(scale: SecondaryAxisScale) -> some ChartContent {
        let samplesWithTemp = dive.profileSamples.filter { $0.temperature != nil }
        ForEach(samplesWithTemp) { sample in
            if let temp = sample.temperature {
                // Top of the scale (warmest) at the surface line, bottom (coldest) at the
                // chart depth.
                let value = plotY(dive.displayProfileTemperature(temp), on: scale)
                LineMark(x: .value("Time", sample.time), y: .value("Temp.", value), series: .value("Sequence", "Temperature"))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Color.green)
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
    private func pressureMarks(scale: SecondaryAxisScale, tankIndices: [Int]) -> some ChartContent {

        if tankIndices.count > 1 {
            // Multi-tank: one line per tank index
            ForEach(tankIndices, id: \.self) { tankIdx in
                let samplesForTank = dive.profileSamples.filter { $0.tankPressures?[tankIdx] != nil }
                ForEach(samplesForTank) { sample in
                    if let pressure = sample.tankPressures?[tankIdx] {
                        let value = plotY(dive.displayProfilePressure(pressure), on: scale)
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
                    let value = plotY(dive.displayProfilePressure(pressure), on: scale)
                    LineMark(x: .value("Time", sample.time), y: .value("Press.", value), series: .value("Sequence", "Pressure"))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Color.red)
                }
            }
        }
    }

    /// NDL reading the dive computer actually reported at this sample, or `nil` when it
    /// reported none. A value at or above `ndlSentinel` is the "no limit required" marker
    /// rather than a reading, so it is excluded here exactly as it is from the samples
    /// table, `hasNDLData` and `ndlRange`.
    private func reportedNDL(_ sample: DiveProfilePoint) -> Double? {
        guard let ndl = sample.ndl, ndl < ndlSentinel else { return nil }
        return ndl
    }

    /// Profile samples that make up the NDL series, beginning at the first sample carrying
    /// a real non-zero reading.
    ///
    /// Leading zero NDL samples are skipped — dive computers emit 0 until they compute the
    /// first valid NDL value. When the computer only ever reported zeros the series starts
    /// at the first sample carrying any reading at all. Every sample from that point
    /// onward is kept, including samples with no reading, so `ndlPlotValue(for:)` can
    /// decide each one individually. Underlying data is unchanged.
    private var ndlSeriesSamples: [DiveProfilePoint] {
        let allSamples = dive.profileSamples
        let firstNonZeroIdx = allSamples.firstIndex { sample in
            guard let ndl = reportedNDL(sample) else { return false }
            return ndl != 0
        }
        let firstReportedIdx = allSamples.firstIndex { reportedNDL($0) != nil }
        guard let startIdx = firstNonZeroIdx ?? firstReportedIdx else { return [] }
        return Array(allSamples[startIdx...])
    }

    /// NDL value to plot for one sample, or `nil` when the sample must be left out of the
    /// series entirely.
    ///
    /// An absent NDL is not missing data while the dive computer reports a decompression
    /// obligation: libdc gates the per-sample NDL on the deco type (`DC_DECO_NDL` vs
    /// `DC_DECO_DECOSTOP`), so the NDL goes absent exactly while a mandatory stop is owed.
    /// Those samples plot as 0 — the bottom of the NDL band — the same nil-to-0 mapping
    /// `decoMarks` applies to `ceilingDepth`. Dropping them instead let `.catmullRom`
    /// bridge straight from the last pre-deco point to the first post-deco point, drawing
    /// the NDL as if it were gradually recovering across the whole obligation.
    ///
    /// An absent NDL with no deco obligation only means the source did not record a value
    /// on that sample (Garmin FIT, MacDive, UDDF and BlueDive XML imports all do this), so
    /// the sample is skipped rather than plotted as 0 — substituting 0 there would display
    /// an estimated value the dive computer never reported.
    private func ndlPlotValue(for sample: DiveProfilePoint) -> Double? {
        if let ndl = reportedNDL(sample) { return ndl }
        // A sentinel reading means unlimited NDL, never zero, so it is excluded rather
        // than dropped to the bottom of the band.
        guard sample.ndl == nil else { return nil }
        let isUnderDecoObligation = sample.events.contains(.decoStop) || (sample.ceilingDepth ?? 0) > 0
        return isUnderDecoObligation ? 0 : nil
    }

    @ChartContentBuilder
    private func ndlMarks(scale: SecondaryAxisScale, series: [DiveProfilePoint]) -> some ChartContent {
        ForEach(series) { sample in
            if let ndl = ndlPlotValue(for: sample) {
                // Readings above 99 min are drawn at 99. When the trace reaches it, `ndlAxis`
                // ends the scale there, so the capped line runs along the top edge (drawn at
                // full width thanks to the plot's 1 pt clip outset).
                // `ndlAxis` reads the same capped values.
                let value = plotY(min(ndl, ndlPlotCap), on: scale)
                LineMark(x: .value("Time", sample.time), y: .value("NDL", value), series: .value("Sequence", "NDL"))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Color.ndlYellow)
            }
        }
    }

    // MARK: - PPO₂ overlay (sensor values preferred per sample; computed as fallback)

    /// Produces (time, ppo2, run, joinsPrevious) for each profile sample using the shared
    /// `buildPPO2Map` helper. Per-sample: sensor value if available, else Dalton's-Law from gas
    /// mix + depth. The smoothed line starts a new run where the breathing mode changes (a
    /// setpoint starts or stops: loop ↔ open circuit), so its curve never bulges past the two
    /// values at the switch; `joinsPrevious` marks the first point after such a change when the
    /// sample just before it has a value too, and the two are joined by a straight segment, so
    /// the line stays continuous across a gas switch. It also starts a new run at a loop sample
    /// (with a setpoint) that has no reported PPO₂, so it never bridges a loop section with
    /// values nobody recorded.
    private var ppo2RenderData: [(time: Double, ppo2: Double, run: Int, joinsPrevious: Bool)] {
        guard visibility.showPPO2 else { return [] }
        let map = buildPPO2Map(for: dive)
        var data: [(time: Double, ppo2: Double, run: Int, joinsPrevious: Bool)] = []
        var run = 0
        var previousOnLoop: Bool?
        var previousHasValue = false
        for sample in dive.profileSamples {
            let onLoop = sample.setpoint != nil
            let modeChanged = previousOnLoop.map { $0 != onLoop } ?? false
            if modeChanged, data.last?.run == run {
                run += 1
            }
            previousOnLoop = onLoop
            if let ppo2 = map[sample.id] {
                data.append((time: sample.time, ppo2: ppo2, run: run,
                             joinsPrevious: modeChanged && previousHasValue))
                previousHasValue = true
            } else {
                previousHasValue = false
                if onLoop, data.last?.run == run {
                    run += 1
                }
            }
        }
        return data
    }

    /// On a dive with O₂-cell readings, the voted or computed PPO₂ of its open-circuit sections
    /// (bailout: no setpoint) in which no sample has cell readings — the bailout gas's PPO₂ — so
    /// such a section is not left without a PPO₂ trace. A section with any cell reading (a
    /// computer that keeps logging cells on open circuit) gets none, so calculated and measured
    /// values are never mixed in one section. A new run starts after each section, so it never
    /// bridges a loop section. Empty for dives without setpoint data.
    private var ppo2BailoutRenderData: [(time: Double, ppo2: Double, run: Int, joinsPrevious: Bool)] {
        let samples = dive.profileSamples
        guard visibility.showPPO2, samples.contains(where: { $0.setpoint != nil }) else { return [] }
        let map = buildPPO2Map(for: dive)
        var data: [(time: Double, ppo2: Double, run: Int, joinsPrevious: Bool)] = []
        var run = 0
        var start = 0
        while start < samples.count {
            guard samples[start].setpoint == nil else {
                start += 1
                continue
            }
            var end = start
            while end < samples.count, samples[end].setpoint == nil { end += 1 }
            let section = samples[start..<end]
            if !section.contains(where: { !($0.sensorPPO2?.isEmpty ?? true) }) {
                for sample in section {
                    if let ppo2 = map[sample.id] {
                        data.append((time: sample.time, ppo2: ppo2, run: run, joinsPrevious: false))
                    } else if data.last?.run == run {
                        run += 1
                    }
                }
            }
            if data.last?.run == run { run += 1 }
            start = end
        }
        return data
    }

    /// Run index of each sample, starting a new run at every loop ↔ open-circuit change (a
    /// setpoint starts or stops), so a per-cell PPO₂ line never bridges a bailout.
    private func breathingModeRuns(_ samples: [DiveProfilePoint]) -> [Int] {
        var runs: [Int] = []
        runs.reserveCapacity(samples.count)
        var run = 0
        var previousOnLoop: Bool?
        for sample in samples {
            let onLoop = sample.setpoint != nil
            if let previousOnLoop, previousOnLoop != onLoop { run += 1 }
            previousOnLoop = onLoop
            runs.append(run)
        }
        return runs
    }

    @ChartContentBuilder
    private func ppo2Marks(scale: SecondaryAxisScale, sensorIndices: [Int],
                           data: [(time: Double, ppo2: Double, run: Int, joinsPrevious: Bool)],
                           setpointLine: [(run: Int, time: Double, setpoint: Double)]) -> some ChartContent {
        let base = depthBase
        if base > 0 {
            if !sensorIndices.isEmpty {
                // One line per physical O2 cell, broken at each loop ↔ open-circuit change so it
                // never bridges a bailout (where the computer reports no cell readings).
                let samples = dive.profileSamples
                let modeRuns = breathingModeRuns(samples)
                ForEach(sensorIndices, id: \.self) { sensorIdx in
                    let points: [(time: Double, ppo2: Double, run: Int)] = samples.indices.compactMap { i in
                        samples[i].sensorPPO2?[sensorIdx].map { (time: samples[i].time, ppo2: $0, run: modeRuns[i]) }
                    }
                    let dash = ppo2Dash(forSensorAtPosition: sensorIndices.firstIndex(of: sensorIdx) ?? 0)
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("PPO₂", plotY(point.ppo2, on: scale, increasesDownward: true)),
                            series: .value("Sequence", "PPO2-S\(sensorIdx)-\(point.run)")
                        )
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: dash))
                        .foregroundStyle(ppo2SensorColor(for: sensorIdx))
                    }
                    // A one-point run (a single reading between two switches) is drawn as a dot.
                    let loneRuns = singlePointRuns(points.map(\.run))
                    ForEach(Array(points.enumerated().filter { loneRuns.contains($0.element.run) }), id: \.offset) { _, point in
                        PointMark(
                            x: .value("Time", point.time),
                            y: .value("PPO₂", plotY(point.ppo2, on: scale, increasesDownward: true))
                        )
                        .symbolSize(16)
                        .foregroundStyle(ppo2SensorColor(for: sensorIdx))
                    }
                }
            }
            // Voted or computed single-line PPO2: the whole dive without cell readings, the
            // bailout sections only with them (see the body). With cells it is the bailout gas's
            // calculated PPO₂, drawn thinner, dotted and lighter so it cannot be read as a cell's
            // measurement (cell S1 is solid indigo).
            let calculatedOnly = !sensorIndices.isEmpty
            let ppo2LineColor: Color = calculatedOnly ? Color.indigo.opacity(0.6) : Color.indigo
            let ppo2LineStyle = calculatedOnly
                ? StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [1, 3])
                : StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            if !data.isEmpty {
                ForEach(Array(data.enumerated()), id: \.offset) { _, point in
                    let y = plotY(point.ppo2, on: scale, increasesDownward: true)
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("PPO₂", y),
                        series: .value("Sequence", "PPO2-\(point.run)")
                    )
                    .interpolationMethod(.catmullRom)
                    .lineStyle(ppo2LineStyle)
                    .foregroundStyle(ppo2LineColor)
                }
                // Straight segment across each loop ↔ open-circuit switch (see ppo2RenderData).
                ForEach(Array(data.indices.filter { $0 > 0 && data[$0].joinsPrevious }), id: \.self) { index in
                    ForEach([index - 1, index], id: \.self) { pointIndex in
                        let point = data[pointIndex]
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("PPO₂", plotY(point.ppo2, on: scale, increasesDownward: true)),
                            series: .value("Sequence", "PPO2-switch-\(index)")
                        )
                        .interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Color.indigo)
                    }
                }
                // A one-point run not joined by a switch segment (a value between two loop
                // samples without PPO₂) is drawn as a dot; a point a switch segment already
                // reaches needs none.
                let lonePPO2Runs = singlePointRuns(data.map(\.run))
                let loneIndices = data.indices.filter { index in
                    lonePPO2Runs.contains(data[index].run)
                        && !data[index].joinsPrevious
                        && !(index + 1 < data.count && data[index + 1].joinsPrevious)
                }
                ForEach(loneIndices, id: \.self) { index in
                    let point = data[index]
                    PointMark(
                        x: .value("Time", point.time),
                        y: .value("PPO₂", plotY(point.ppo2, on: scale, increasesDownward: true))
                    )
                    .symbolSize(16)
                    .foregroundStyle(ppo2LineColor)
                }
            }
            ForEach(Array(setpointLine.enumerated()), id: \.offset) { _, point in
                LineMark(
                    x: .value("Time", point.time),
                    y: .value("PPO₂", plotY(point.setpoint, on: scale, increasesDownward: true)),
                    series: .value("Sequence", "Setpoint-\(point.run)")
                )
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [4, 3]))
                .foregroundStyle(Color.ccrSetpoint)
            }
            let loneSetpointRuns = singlePointRuns(setpointLine.map(\.run))
            ForEach(Array(setpointLine.enumerated().filter { loneSetpointRuns.contains($0.element.run) }), id: \.offset) { _, point in
                PointMark(
                    x: .value("Time", point.time),
                    y: .value("PPO₂", plotY(point.setpoint, on: scale, increasesDownward: true))
                )
                .symbolSize(12)
                .foregroundStyle(Color.ccrSetpoint)
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

        let allSamples = dive.profileSamples
        let decoSamples = allSamples
            .filter { $0.events.contains(.decoStop) }
            .sorted { $0.time < $1.time }
        guard !decoSamples.isEmpty else { return [] }

        // For accurate crossing detection, search from a 2-minute lookback before the first
        // deco sample (handles computers that emit .decoStop only after passing stop.depth)
        // through to the END OF THE DIVE. Extending past the obligation window lets stops
        // whose depth is only physically reached after the obligation clears — e.g. Bühlmann
        // GF computers that clear deco deep and let the diver drift up through the shallow
        // stops — resolve onto the real ascent line instead of collapsing onto the shallowest
        // in-window sample. The loop still takes the FIRST ascending crossing at/after
        // searchFloorTime, so dives that already cross within the obligation window are
        // unaffected.
        let decoWindowStart = (decoSamples.first?.time ?? 0) - 2.0
        let decoWindowEnd   = allSamples.map(\.time).max() ?? (decoSamples.last?.time ?? 0)
        let windowSamples = allSamples
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
        // Post-resolution filter only — never a `continue` inside the loop above: the
        // deepest-first walk advances searchFloorTime to each resolved crossing, so
        // skipping a stop mid-loop would shift every shallower stop's crossing time.
        // Mirrored in buildDecoStopCache() and PDFLogbook.mandatoryDecoStopPoints(for:);
        // all three must carry this filter or the tooltip, legend and PDF contradict
        // the diamonds drawn here.
        guard hideClearedDecoStops,
              let cutoff = decoObligationEndTime(in: allSamples) else { return result }
        return result.filter { $0.time <= cutoff }
    }

    /// True when at least one sample carries a dive-computer-reported decompression ceiling.
    /// Gated on > 0, not just non-nil: all three importers (Bluetooth/libdc, Subsurface,
    /// Garmin FIT) exclude a reported-but-zero ceiling at the source, but dives imported
    /// before that source-side gate existed may still have a literal-zero ceiling persisted
    /// in the database — a non-nil 0 must still read as "no real obligation" here or this
    /// flag would disable the legacy full-height fallback for a dive that ends up with no
    /// visible ceiling shading at all.
    private var hasCeilingData: Bool {
        dive.profileSamples.contains { ($0.ceilingDepth ?? 0) > 0 }
    }

    /// Contiguous runs of samples carrying a real (> 0) per-sample ceiling, each padded with
    /// the bracketing zero-ceiling sample immediately before/after (if any) so the entry/exit
    /// steps of the boundary line still draw. Used only by the ceiling LineMark — the
    /// AreaMark still iterates every sample directly, since a zero-height fill outside the
    /// obligation is invisible and needs no such splitting.
    private var ceilingLineRuns: [[DiveProfilePoint]] {
        // Importer order is not guaranteed sorted, and the run grouping below depends on
        // time order — an out-of-order sample would fracture one obligation window into
        // several runs (unlike the plain per-sample AreaMark above, which tolerates it).
        let samples = dive.profileSamples.sorted { $0.time < $1.time }
        var runs: [[DiveProfilePoint]] = []
        var i = 0
        while i < samples.count {
            guard (samples[i].ceilingDepth ?? 0) > 0 else { i += 1; continue }
            var j = i
            while j < samples.count, (samples[j].ceilingDepth ?? 0) > 0 { j += 1 }
            var run = Array(samples[i..<j])
            if i > 0 { run.insert(samples[i - 1], at: 0) }
            if j < samples.count { run.append(samples[j]) }
            runs.append(run)
            i = j
        }
        return runs
    }

    /// Legacy full-height deco band for dives with no per-sample ceiling data. Declared
    /// BEFORE depthMarks in the Chart builder (unlike decoMarks below) so this shading
    /// stays behind the depth curve and its translucent cyan fill, matching its original
    /// full-dive-height appearance.
    @ChartContentBuilder
    private var legacyDecoBand: some ChartContent {
        if visibility.showDeco && !hasCeilingData {
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
        }
    }

    /// Ceiling band, boundary line and mandatory-stop diamonds. Declared AFTER depthMarks in
    /// the Chart builder so these render on top of the translucent cyan depth fill instead of
    /// blending underneath it — the ceiling is always shallower than the diver's actual depth,
    /// so this content is a full subset of the cyan area and would otherwise always be washed
    /// toward green rather than reading as orange.
    @ChartContentBuilder
    private var decoMarks: some ChartContent {
        if visibility.showDeco {
            if hasCeilingData {
                // Continuous ceiling band from the surface down to the reported ceiling.
                // Samples with no obligation render at 0 (surface), so the band collapses
                // to nothing outside the obligation.
                let samples = dive.profileSamples
                ForEach(samples) { sample in
                    AreaMark(
                        x:      .value("Time",    sample.time),
                        yStart: .value("Surface", 0.0),
                        yEnd:   .value("Ceiling", -dive.displayProfileDepth(sample.ceilingDepth ?? 0)),
                        series: .value("Sequence", "Ceiling")
                    )
                    // Step interpolation only: a ceiling holds at the last value the dive
                    // computer reported until it reports a new one. Linear or curved
                    // interpolation would draw ceiling values that were never recorded.
                    .interpolationMethod(.stepEnd)
                    // Higher than the legacy band's 0.2: this fill sits entirely inside
                    // depthMarks' cyan area (the ceiling is always shallower than actual
                    // depth), so a lower alpha desaturates toward khaki instead of reading
                    // as orange, regardless of draw order.
                    .foregroundStyle(Color.orange.opacity(0.4))
                }
                // Stroked per contiguous obligation run (not per sample, unlike the area
                // above) so the boundary line never draws across the flat zero-ceiling
                // baseline between two obligation windows, or before/after the only one —
                // that baseline sits exactly on the plot's top edge (y=0), where a stroke
                // would otherwise show as a spurious solid line across the whole chart.
                ForEach(Array(ceilingLineRuns.enumerated()), id: \.offset) { index, run in
                    ForEach(run) { sample in
                        LineMark(
                            x: .value("Time",    sample.time),
                            y: .value("Ceiling", -dive.displayProfileDepth(sample.ceilingDepth ?? 0)),
                            series: .value("Sequence", "Ceiling-\(index)")
                        )
                        .interpolationMethod(.stepEnd)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Color.orange)
                    }
                }
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

// MARK: - Legend Row Types

/// Small colour-swatch-plus-label rows used by `legendView`. Each used to be a plain
/// function that inlined its HStack/Circle/Text tree at every call site; `legendView`
/// calls up to 11 of them statically in one property (plus `ChartTooltipView.body` calls
/// its own `TooltipRow` up to 13 times), the same class of bug that caused an
/// `EXC_BAD_ACCESS` crash in `DiveDetailView+MenuTab.swift` (many modifier/view-tree sites
/// combined in one `some View` property overflowed the stack during Swift's runtime
/// value-witness copy of the resulting deeply-nested type). Packaging these as nominal
/// structs — the same fix used there and for `ConditionRow` — stops each call's internal
/// complexity at its own `body`'s boundary instead of letting it inline into the
/// combined legend's compound type.
struct LegendDot: View {
    let color: Color
    let text: Text

    init(_ color: Color, _ text: LocalizedStringKey) {
        self.color = color
        self.text = Text(text)
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            text
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Rectangular swatch used for background-band legend entries (e.g. deco phase).
/// `alpha` must be passed the alpha of the band actually drawn for that case, so the
/// legend key isn't a different shade than what's on the chart.
struct LegendBand: View {
    let color: Color
    let text: LocalizedStringKey
    let alpha: Double

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(alpha))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(color.opacity(0.6), lineWidth: 0.5))
                .frame(width: 14, height: 8)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Point-marker swatch for legend entries: a circle for gas switches, a square for CCR
/// setpoint changes, matching the chart's symbols.
struct LegendGasChange: View {
    let color: Color
    let text: LocalizedStringKey
    var square: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if square {
                    Rectangle().fill(color)
                } else {
                    Circle().fill(color)
                }
            }
            .frame(width: 8, height: 8)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Diamond swatch used for point-marker legend entries (e.g. mandatory deco stops).
struct LegendDiamond: View {
    let color: Color
    let text: LocalizedStringKey

    var body: some View {
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
}

struct MetricLegendRow: View {
    let color: Color
    let label: Text
    let range: String

    init(color: Color, label: LocalizedStringKey, range: String) {
        self.init(color: color, label: Text(label), range: range)
    }

    /// For a label that needs a translator comment.
    init(color: Color, label: Text, range: String) {
        self.color = color
        self.label = label
        self.range = range
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            (label + Text(": \(range)"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

#if os(macOS)
// MARK: - Chart Height (macOS)

/// Mac windows are tall and resizable: the plot grows with the visible height of its container
/// (the enclosing scroll view, or the window), as a fraction of it clamped to a range.
struct ChartHeightRule: Equatable {
    let fraction: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat

    /// Dive detail view: 45 % of the visible height, never below the iOS height (300 pt)
    /// or above 600 pt.
    static let detail = ChartHeightRule(fraction: 0.45, minHeight: 300, maxHeight: 600)
    /// Profile preview above the dive list: lower, because the panel shares the window with
    /// the list and cannot scroll out of its way.
    static let listPreview = ChartHeightRule(fraction: 0.30, minHeight: 160, maxHeight: 400)

    func height(for containerHeight: CGFloat) -> CGFloat {
        min(max(containerHeight * fraction, minHeight), maxHeight)
    }
}

private extension View {
    func macChartHeight(_ rule: ChartHeightRule) -> some View {
        containerRelativeFrame(.vertical) { height, _ in
            rule.height(for: height)
        }
    }
}
#endif

// MARK: - Profile Photo Marker

/// A photo shown on the dive profile at its capture time.
private struct ProfilePhotoMarker: Identifiable {
    /// The photo's id.
    let id: UUID
    /// Elapsed dive time, in minutes (the chart's x unit).
    let minutes: Double
    /// Depth recorded at the sample nearest that time, in the display unit.
    let depth: Double
    let image: PlatformImage?
}

// MARK: - UnifiedDiveChartOptimized

/// Graphique unifié interactif pour le profil de plongée - VERSION OPTIMISÉE
struct UnifiedDiveChartOptimized: View {
    let dive: Dive
    #if os(macOS)
    /// How the plot height follows the window (`.listPreview` in the dive list's preview).
    var chartHeightRule: ChartHeightRule = .detail
    #endif
    @State private var sharedVisibility = SharedChartLineVisibility.shared
    /// The shared line selection (see `SharedChartLineVisibility`), so every chart on screen
    /// shows the same chips and lines.
    private var visibility: ChartLineVisibility {
        get { sharedVisibility.value }
        nonmutating set { sharedVisibility.value = newValue }
    }

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
    /// Lowest and highest reading of each O₂ sensor, for the legend (which is re-evaluated on
    /// every cursor move). Built with `cachedPPO2BySampleID`.
    @State private var cachedSensorPPO2Ranges: [Int: ClosedRange<Double>] = [:]
    /// Range of the voted or computed PPO₂ (dives without sensor readings), for the legend.
    @State private var cachedPPO2Range: ClosedRange<Double>? = nil
    /// The `chartCacheKey` the PPO₂ legend caches above were built for. Until they are built
    /// for the current key (the first frame, before `.task` runs, and after moving to another
    /// dive or editing a gas mix) the legend computes its ranges directly.
    @State private var ppo2LegendCacheKey: ChartCacheKey? = nil
    private var ppo2LegendCacheReady: Bool { ppo2LegendCacheKey == chartCacheKey }

    /// What the caches built in `.task` depend on: the dive, its samples (`ProfileCacheID`, so a
    /// profile replaced while the chart is shown — e.g. a re-download — rebuilds them), its gas
    /// mixes and the hide-cleared-deco-stops setting. A change rebuilds them. Compared field by
    /// field (no string building), as the legend checks it on every cursor move.
    private struct ChartCacheKey: Equatable {
        /// The dive (`ProfileCacheID.diveID`) and its samples.
        let profile: ProfileCacheID
        let tanksO2Hash: Int
        let hideClearedDecoStops: Bool
    }

    private var chartCacheKey: ChartCacheKey {
        ChartCacheKey(profile: profileCacheID, tanksO2Hash: tanksO2Hash,
                      hideClearedDecoStops: prefs.hideClearedDecoStops)
    }
    /// Sorted (time, pressure) readings for single-tank dives — enables interpolation across sparse AI transmitter gaps.
    @State private var cachedSinglePressureReadings: [(time: Double, pressure: Double)] = []
    /// Sorted per-tank pressure readings for multi-tank dives.
    @State private var cachedMultiPressureReadings: [Int: [(time: Double, pressure: Double)]] = [:]
    /// Entry time (diamond position) per mandatory deco stop for tooltip matching — built once per dive.
    @State private var cachedDecoStopEntries: [(stop: DecoStop, entryTime: Double)] = []
    /// Lowest to highest CCR setpoint of the dive, for the legend; nil when the dive has no
    /// setpoint data. Built in `.task`, with `cachedSensorIndices`, for `profileCacheID`.
    @State private var cachedSetpointRange: ClosedRange<Double>? = nil
    /// Sorted O₂ sensor indices with readings (legend), built with `cachedSetpointRange`.
    @State private var cachedSensorIndices: [Int] = []
    /// The `profileCacheID` the two caches above were built for; until then (first frame) the
    /// values are computed directly, so a setpoint dive never shows as having none.
    @State private var builtProfileCacheID: ProfileCacheID? = nil
    private var setpointCacheReady: Bool { builtProfileCacheID == profileCacheID }

    private var profileCacheID: ProfileCacheID { ProfileCacheID(dive: dive) }

    // MARK: - Photo Markers
    @Environment(\.modelContext) private var modelContext
    /// Optional so the chart previews run without a store; the app always provides one.
    @Environment(DiveStore.self) private var store: DiveStore?
    @State private var photoMarkers: [ProfilePhotoMarker] = []
    /// The photo a tapped marker opens (its id, not a position: the markers are rebuilt after
    /// a photo is removed, and positions shift meanwhile).
    @State private var markerPreview: MarkerPreviewTarget?

    private struct MarkerPreviewTarget: Identifiable {
        let id = UUID()
        let photoID: UUID
    }

    var body: some View {
        VStack(spacing: 16) {
            toggleControls
            chartView

            if !dive.profileSamples.isEmpty {
                legendView
            }
        }
        .task(id: chartCacheKey) {
            buildPressureCache()
            buildDecoStopCache()
            if visibility.showPPO2 { rebuildPPO2Cache() }
        }
        .task(id: profileCacheID) {
            cachedSetpointRange = SetpointProfile.range(for: dive)
            cachedSensorIndices = sensorPPO2Indices(for: dive)
            builtProfileCacheID = profileCacheID
        }
        .onChange(of: visibility.showPPO2) { _, newValue in
            if newValue {
                rebuildPPO2Cache()
            } else {
                cachedPPO2BySampleID = [:]
                cachedSensorPPO2Ranges = [:]
                cachedPPO2Range = nil
                ppo2LegendCacheKey = nil
            }
        }
        .task(id: photoMarkerKey) {
            await buildPhotoMarkers()
        }
        .sheet(item: $markerPreview) { item in
            let photos = markerPhotos
            PhotoPreviewSheet(
                photoIDs: photos.map(\.id.uuidString),
                photoData: { index in
                    guard photos.indices.contains(index) else { return Data() }
                    return photos[index].previewBytes ?? Data()
                },
                initialIndex: photos.firstIndex { $0.id == item.photoID } ?? 0,
                photoRecord: { index in photos.indices.contains(index) ? photos[index] : nil },
                hasOriginal: { index in photos.indices.contains(index) && photos[index].original != nil },
                onDelete: { photoID in deleteMarkerPhoto(id: photoID) }
            )
            .standardSheetPresentation()
        }
    }

    // MARK: - Photo Markers

    /// Photos placed on the profile, in time order.
    private var markerPhotos: [DivePhoto] {
        let ids = photoMarkers.map(\.id)
        let byID = Dictionary((dive.photos ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// Changes when a marker must be rebuilt: photos added, removed or moved (including by an
    /// edit of the dive's start time or profile), units, setting, or replaced by a newer
    /// version (a re-import changes the file's hash). Reads no image data.
    private var photoMarkerKey: Int {
        var hasher = Hasher()
        hasher.combine(dive.id)
        guard prefs.showPhotosOnProfile else { return hasher.finalize() }
        hasher.combine(unitsHash)
        hasher.combine(dive.profileSamples.count)
        for photo in dive.photos ?? [] {
            guard let offset = photo.profileOffset(in: dive) else { continue }
            hasher.combine(photo.id)
            hasher.combine(offset)
            // A thumbnail arriving from iCloud after its photo rebuilds the marker (reads the
            // link only, not the image).
            hasher.combine(photo.thumbnail != nil)
            hasher.combine(photo.contentHash)
        }
        return hasher.finalize()
    }

    private func buildPhotoMarkers() async {
        guard prefs.showPhotosOnProfile else { photoMarkers = []; return }
        let photos = (dive.photos ?? [])
            .compactMap { photo in photo.profileOffset(in: dive).map { (photo, $0) } }
            .sorted { $0.1 < $1.1 }
        let samples = dive.profileSamples.sorted { $0.time < $1.time }
        guard !photos.isEmpty, !samples.isEmpty else { photoMarkers = []; return }
        // Every value read from the models before the decode: a photo (or the dive) deleted
        // by an iCloud merge meanwhile is never read afterwards.
        let placed: [(id: UUID, minutes: Double, depth: Double, thumbnail: Data?)] = photos.compactMap { photo, offset in
            let minutes = offset / 60
            // The depth recorded at the sample nearest the photo's time (no interpolation).
            guard let sample = Self.nearestSample(to: minutes, in: samples) else { return nil }
            return (photo.id, minutes, dive.displayProfileDepth(sample.depth), photo.thumbnailBytes)
        }
        let thumbnails = placed.map { ($0.id, $0.thumbnail) }
        // At default QoS (ImageIO); nil: cancelled while waiting for its turn (nothing decoded).
        guard let images = await PhotoMetadataReader.onImageQueueUnlessCancelled({
            Dictionary(thumbnails.map { ($0.0, $0.1.flatMap { PlatformImage(data: $0) }) },
                       uniquingKeysWith: { first, _ in first })
        }), !Task.isCancelled else { return }
        photoMarkers = placed.map { item in
            ProfilePhotoMarker(id: item.id, minutes: item.minutes, depth: item.depth, image: images[item.id] ?? nil)
        }
    }

    /// The sample whose time is closest to `minutes` (`samples` sorted by time).
    private static func nearestSample(to minutes: Double, in samples: [DiveProfilePoint]) -> DiveProfilePoint? {
        guard !samples.isEmpty else { return nil }
        var low = 0, high = samples.count - 1
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].time < minutes { low = mid + 1 } else { high = mid }
        }
        if low > 0, abs(samples[low - 1].time - minutes) <= abs(samples[low].time - minutes) {
            return samples[low - 1]
        }
        return samples[low]
    }

    private func deleteMarkerPhoto(id: String) {
        guard let photo = (dive.photos ?? []).first(where: { $0.id.uuidString == id }) else { return }
        modelContext.delete(photo)
        try? modelContext.save()
        store?.commit(dive, affects: .rowBadges)
    }

    private struct MarkerPlacement {
        let marker: ProfilePhotoMarker
        let index: Int
        /// Position of the marker's dot in the plot area.
        let x: CGFloat
        let y: CGFloat
        /// Length of the stem between the dot and the thumbnail.
        let stem: CGFloat
        /// The thumbnail hangs below the dot instead of standing above it.
        let below: Bool
    }

    private static let markerThumbSize: CGFloat = 30
    private static let markerDotSize: CGFloat = 5

    /// Places each thumbnail so it stays inside the plot area and does not cover another one:
    /// just above its dot, else just below, then one level higher, one level lower, and so on.
    /// The dot always stays on the depth line at the photo's time.
    private func markerPlacements(proxy: ChartProxy, plotSize: CGSize) -> [MarkerPlacement] {
        let thumb = Self.markerThumbSize
        let halfDot = Self.markerDotSize / 2
        let gap: CGFloat = 4
        var placed: [CGRect] = []
        var placements: [MarkerPlacement] = []
        for (index, marker) in photoMarkers.enumerated() {
            guard let x = proxy.position(forX: marker.minutes),
                  let y = proxy.position(forY: -marker.depth) else { continue }
            func rect(stem: CGFloat, below: Bool) -> CGRect {
                let top = below ? y + halfDot + stem : y - halfDot - stem - thumb
                return CGRect(x: x - thumb / 2, y: top, width: thumb, height: thumb)
            }
            var chosen: (stem: CGFloat, below: Bool)?
            var fallback: (stem: CGFloat, below: Bool)?
            for level in 0..<12 {
                let stem = 6 + CGFloat(level) * (thumb + gap)
                for below in [false, true] {
                    let candidate = rect(stem: stem, below: below)
                    guard candidate.minY >= 0, candidate.maxY <= plotSize.height else { continue }
                    if fallback == nil { fallback = (stem, below) }
                    if !placed.contains(where: { $0.insetBy(dx: -1, dy: -1).intersects(candidate) }) {
                        chosen = (stem, below)
                        break
                    }
                }
                if chosen != nil { break }
            }
            let choice = chosen ?? fallback ?? (6, false)
            placed.append(rect(stem: choice.stem, below: choice.below))
            placements.append(MarkerPlacement(marker: marker, index: index, x: x, y: y,
                                              stem: choice.stem, below: choice.below))
        }
        return placements
    }

    private func photoMarkerView(_ marker: ProfilePhotoMarker, index: Int, stemHeight: CGFloat, below: Bool) -> some View {
        Button {
            markerPreview = MarkerPreviewTarget(photoID: marker.id)
        } label: {
            VStack(spacing: 0) {
                if below {
                    Circle()
                        .fill(Color.pink)
                        .frame(width: Self.markerDotSize, height: Self.markerDotSize)
                    Rectangle()
                        .fill(Color.pink)
                        .frame(width: 1.5, height: stemHeight)
                }
                Group {
                    if let image = marker.image {
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.pink)
                    }
                }
                .frame(width: Self.markerThumbSize, height: Self.markerThumbSize)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                if !below {
                    Rectangle()
                        .fill(Color.pink)
                        .frame(width: 1.5, height: stemHeight)
                    Circle()
                        .fill(Color.pink)
                        .frame(width: Self.markerDotSize, height: Self.markerDotSize)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: String(
            format: NSLocalizedString("Photo at %@, %@", bundle: .forAppLanguage(), value: "Photo at %@, %@", comment: "Accessibility label of a photo marker on the dive profile: elapsed dive time (e.g. 22:05) and depth (e.g. 18.2 m)"),
            Self.elapsedText(minutes: marker.minutes),
            "\(marker.depth.localizedString(decimals: 1)) \(prefs.depthUnit.symbol)"
        )))
    }

    /// Elapsed dive time as minutes:seconds, e.g. "22:05".
    private static func elapsedText(minutes: Double) -> String {
        let total = Int(exactly: (minutes * 60).rounded()) ?? 0
        return String(format: "%d:%02d", total / 60, total % 60)
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
    
    /// First group of chips: Depth, Temperature, NDL.
    @ViewBuilder
    private var primaryToggleChips: some View {
        // Depth button - always on, non-interactive (using a constant binding)
        ToggleButton(
            isOn: .constant(true),
            icon: "arrow.down.circle.fill",
            label: "Depth",
            shortLabel: "Prof.",
            color: .cyan,
            textColor: Color.readableCyan,
            isAvailable: true
        )

        ToggleButton(
            isOn: exclusiveBinding(for: \.showTemperature),
            icon: "thermometer",
            label: "Temperature",
            shortLabel: "Temp.",
            color: .green,
            textColor: Color.readableGreen,
            isAvailable: hasTemperatureData
        )

        ToggleButton(
            isOn: exclusiveBinding(for: \.showNDL),
            icon: "timer",
            label: "NDL",
            color: .ndlYellow,
            textColor: Color.readableAmber,
            isAvailable: hasNDLData
        )
    }

    /// Second group of chips: Pressure, PPO₂, Deco.
    @ViewBuilder
    private var secondaryToggleChips: some View {
        ToggleButton(
            isOn: exclusiveBinding(for: \.showPressure),
            icon: "gauge.with.needle.fill",
            label: "Pressure",
            shortLabel: "Press.",
            color: .red,
            textColor: Color.readableRed,
            isAvailable: hasPressureData
        )

        ToggleButton(
            isOn: exclusiveBinding(for: \.showPPO2),
            icon: "lungs.fill",
            label: "PPO₂",
            color: .indigo,
            textColor: Color.readableIndigo,
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
            textColor: Color.readableOrange,
            isAvailable: hasDecoData
        )
    }

    /// Whether the dive has a photo placed on the profile (the Photos chip is dimmed otherwise).
    private var hasProfilePhotos: Bool {
        (dive.photos ?? []).contains { $0.profileOffset(in: dive) != nil }
    }

    /// Shows or hides the photo markers. Bound to the same saved preference as Settings →
    /// Dive Profile → Show photos on the profile, so both always agree. Independent of the
    /// other chips, like Deco. Shown in the dive detail and in the dive list's preview alike.
    private func photosChip(showsLabel: Bool) -> some View {
        ToggleButton(
            isOn: $prefs.showPhotosOnProfile,
            icon: "camera.fill",
            label: "Photos",
            color: .pink,
            textColor: Color.readablePink,
            isAvailable: hasProfilePhotos,
            showsLabel: showsLabel
        )
        .accessibilityLabel(prefs.showPhotosOnProfile ? Text("Hide photos on the profile") : Text("Show photos on the profile"))
    }

    private var toggleControls: some View {
        VStack(spacing: 12) {
            #if os(macOS)
            // The Mac window is usually wide enough for all the chips on one row;
            // fall back to the two iOS rows when it is not. ViewThatFits measures
            // the chips at their full-label width, so the single row is only used
            // when no chip would have to switch to its short label.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    primaryToggleChips
                    secondaryToggleChips
                    photosChip(showsLabel: true)
                }
                VStack(spacing: 12) {
                    HStack(spacing: 12) { primaryToggleChips }
                    HStack(spacing: 12) {
                        secondaryToggleChips
                        photosChip(showsLabel: true)
                    }
                }
            }
            #else
            HStack(spacing: 12) { primaryToggleChips }

            // Labelled like the other chips when the row has room; icon only where a fourth
            // labelled chip would not fit (a small iPhone).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    secondaryToggleChips
                    photosChip(showsLabel: true)
                }
                HStack(spacing: 12) {
                    secondaryToggleChips
                    photosChip(showsLabel: false)
                }
            }
            #endif
            Text("Depth is always displayed on the chart")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Chart View

    private var chartView: some View {
        let lastSampleTime = dive.profileSamples.last?.time ?? 0
        // The stored dive time: the computer/file time, else the minutes (legacy seconds kept).
        let storedDurationMinutes = Double(dive.resolvedDurationSeconds) / 60.0
        let xMax = max(lastSampleTime, storedDurationMinutes)
        // The chart reaches the deeper of the stored max depth and the deepest sample, so no
        // part of the profile is clipped when the computer's recorded maximum is shallower.
        // The raw maximum is converted once; the conversion preserves order.
        let deepestSampleDepth = dive.displayProfileDepth(dive.profileSamples.lazy.map(\.depth).max() ?? 0)
        let depthBase = max(dive.displayMaxDepth, deepestSampleDepth)

        #if os(macOS)
        let layer = StaticChartLayer(dive: dive, visibility: visibility, xMax: xMax, depthBase: depthBase, prefs: prefs, tanksO2Hash: tanksO2Hash, unitsHash: unitsHash, hideClearedDecoStops: prefs.hideClearedDecoStops, profileID: profileCacheID, heightRule: chartHeightRule)
        #else
        let layer = StaticChartLayer(dive: dive, visibility: visibility, xMax: xMax, depthBase: depthBase, prefs: prefs, tanksO2Hash: tanksO2Hash, unitsHash: unitsHash, hideClearedDecoStops: prefs.hideClearedDecoStops, profileID: profileCacheID)
        #endif
        return layer
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

                        // ── Photo markers — above the touch zone so a tap opens the photo.
                        // The marker's dot sits on the curve: the view (30 pt thumbnail, stem,
                        // 5 pt dot) is centred half its height minus half the dot above the dot.
                        ZStack(alignment: .topLeading) {
                            ForEach(markerPlacements(proxy: proxy, plotSize: geo[frame].size), id: \.marker.id) { placement in
                                // The view is thumbnail + stem + dot; its centre sits half its
                                // height (less half the dot) above — or below — the dot's centre.
                                let offset = (Self.markerThumbSize + placement.stem + Self.markerDotSize) / 2
                                    - Self.markerDotSize / 2
                                photoMarkerView(placement.marker, index: placement.index,
                                                stemHeight: placement.stem, below: placement.below)
                                    .position(x: geo[frame].minX + placement.x,
                                              y: geo[frame].minY + placement.y + (placement.below ? offset : -offset))
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)

                        // ── Tooltip — last, so it is drawn over the photo markers while scrubbing.
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
        // Extend the crossing search to the end of the dive (see mandatoryDecoStopPoints):
        // stops physically reached only after the obligation clears resolve onto the real
        // ascent line. First-crossing-at/after-floor keeps in-window dives unchanged.
        let windowEnd   = samples.map(\.time).max() ?? (decoSamples.last?.time ?? 0)
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

        // Same post-resolution-only filter as StaticChartLayer.mandatoryDecoStopPoints and
        // PDFLogbook.mandatoryDecoStopPoints(for:) — applied after the loop because the
        // deepest-first searchFloorTime anchoring needs every stop resolved. Keeping this
        // cache in step with the diamonds is what keeps the tooltip's "Stop X" row honest.
        if prefs.hideClearedDecoStops, let cutoff = decoObligationEndTime(in: samples) {
            result = result.filter { $0.entryTime <= cutoff }
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

        // Across a change between the loop (setpoint) and open circuit, the next sample's PPO₂
        // values belong to the other breathing mode: hold the earlier sample's only, like the
        // setpoint row — never blend or borrow across the change.
        let breathingModeChanges = (prev.setpoint == nil) != (next.setpoint == nil)
        let ppo2: Double? = {
            let pp = cachedPPO2BySampleID[prev.id]
            let np = cachedPPO2BySampleID[next.id]
            if breathingModeChanges { return pp }
            if let a = pp, let b = np { return a + t * (b - a) }
            // A loop sample without a reported PPO₂ has none (the chart line breaks there):
            // never borrow the next sample's value for it.
            if prev.setpoint != nil { return pp }
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
            // Step-hold from the earlier real sample rather than interpolating — a ceiling
            // between two reports is not a value the dive computer ever gave.
            ceilingDepth: prev.ceilingDepth,
            ppo2: ppo2,
            // Held from the earlier sample across a loop ↔ open-circuit change and on the loop
            // (like the PPO₂ row, never borrowed from the next sample), nearest otherwise.
            sensorPPO2: breathingModeChanges || prev.setpoint != nil ? prev.sensorPPO2 : nearest.sensorPPO2,
            events: mergedEvents,
            currentGas: gasSource.currentGas,
            // Step-hold from the earlier real sample, like the ceiling.
            setpoint: prev.setpoint,
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
            ceilingDepth: sample.ceilingDepth,
            ppo2: cachedPPO2BySampleID[sample.id],
            sensorPPO2: sample.sensorPPO2,
            events: sample.events,
            currentGas: sample.currentGas,
            setpoint: sample.setpoint,
            ascentSpeed: ascentSpeed
        )
    }

    // MARK: - PPO2 Helpers

    /// Builds the PPO₂ caches — `cachedPPO2BySampleID` (tooltip, via `buildPPO2Map`) and the
    /// legend's `cachedSensorPPO2Ranges` and `cachedPPO2Range` — and records the
    /// `chartCacheKey` they were built for. Called once per toggle or `.task` key change.
    private func rebuildPPO2Cache() {
        let map = buildPPO2Map(for: dive)
        cachedPPO2BySampleID = map
        cachedSensorPPO2Ranges = sensorPPO2Ranges()
        cachedPPO2Range = ppo2Range(Array(map.values))
        ppo2LegendCacheKey = chartCacheKey
    }

    /// Lowest and highest reading of each O₂ sensor.
    private func sensorPPO2Ranges() -> [Int: ClosedRange<Double>] {
        var ranges: [Int: ClosedRange<Double>] = [:]
        for sample in dive.profileSamples {
            guard let readings = sample.sensorPPO2 else { continue }
            // A non-finite reading (e.g. "nan" in an imported file) is skipped: it cannot be
            // part of a range, and building one from it would trap.
            for (idx, value) in readings where value.isFinite {
                if let range = ranges[idx] {
                    ranges[idx] = min(range.lowerBound, value)...max(range.upperBound, value)
                } else {
                    ranges[idx] = value...value
                }
            }
        }
        return ranges
    }

    // MARK: - Legend View

    @ViewBuilder
    private var legendView: some View {
        #if os(macOS)
        // The Mac window is usually wide enough for the whole legend on one line.
        // When it is not (narrow window, or many tank-pressure / PPO₂-sensor entries),
        // split the shown groups evenly over two lines; the stacked iOS layout is the
        // last resort for very narrow windows.
        let groups = shownLegendGroups
        let firstLineCount = (groups.count + 1) / 2
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                legendTitle
                legendLine(groups)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                legendTitle
                VStack(alignment: .leading, spacing: 6) {
                    legendLine(Array(groups.prefix(firstLineCount)))
                    legendLine(Array(groups.dropFirst(firstLineCount)))
                }
            }
            stackedLegend
        }
        .padding(.horizontal)
        #else
        stackedLegend
            .padding(.horizontal)
        #endif
    }

    private var legendTitle: some View {
        Text("Legend")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }

    /// Title above the legend groups, one group per line.
    private var stackedLegend: some View {
        VStack(alignment: .leading, spacing: 8) {
            legendTitle

            VStack(alignment: .leading, spacing: 6) {
                if showsDepthLegend { depthLegendGroup }
                if showsTemperatureLegend { temperatureLegendGroup }
                if showsPressureLegend { pressureLegendGroup(wrapping: true) }
                if showsNDLLegend { ndlLegendGroup }
                if showsPPO2Legend { ppo2LegendGroup(wrapping: true) }
                if showsDecoLegend { decoLegendGroup }
                if hasGasChangeData { gasSwitchLegendGroup }
                if hasSetpointData { setpointLegendGroup(wrapping: true) }
            }
        }
    }

    #if os(macOS)
    /// Indices (0 = depth … 6 = gas switch, 7 = setpoint, the stacked legend's order) of the legend
    /// groups currently shown (macOS only).
    private var shownLegendGroups: [Int] {
        let shown = [showsDepthLegend, showsTemperatureLegend, showsPressureLegend,
                     showsNDLLegend, showsPPO2Legend, showsDecoLegend, hasGasChangeData,
                     hasSetpointData]
        return shown.indices.filter { shown[$0] }
    }

    /// The given legend groups side by side, separated by a vertical line (macOS only).
    private func legendLine(_ groups: [Int]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(groups.enumerated()), id: \.element) { position, group in
                if position > 0 { legendSeparator }
                legendGroup(group)
            }
        }
    }

    @ViewBuilder
    private func legendGroup(_ index: Int) -> some View {
        switch index {
        case 0: depthLegendGroup
        case 1: temperatureLegendGroup
        case 2: pressureLegendGroup(wrapping: false)
        case 3: ndlLegendGroup
        case 4: ppo2LegendGroup(wrapping: false)
        case 5: decoLegendGroup
        case 6: gasSwitchLegendGroup
        default: setpointLegendGroup(wrapping: false)
        }
    }

    private var legendSeparator: some View {
        // A plain Divider is too faint against the dark card; use a slightly
        // wider, taller line in the secondary colour so groups read as distinct.
        Capsule()
            .fill(Color.secondary.opacity(0.6))
            .frame(width: 1.5, height: 14)
            .padding(.horizontal, 4)
    }
    #endif

    // MARK: Legend Groups

    private var showsDepthLegend: Bool { visibility.showDepth }
    private var showsTemperatureLegend: Bool { visibility.showTemperature && hasTemperatureData }
    private var showsPressureLegend: Bool { visibility.showPressure && hasPressureData }
    private var showsNDLLegend: Bool { visibility.showNDL && hasNDLData }
    private var showsPPO2Legend: Bool { visibility.showPPO2 && ppo2Available && ppo2LegendHasRow }

    /// The voted or computed PPO₂ range the legend shows when there are no O₂ sensors. Cached
    /// once per dive while PPO₂ is shown, as the legend is re-evaluated on every cursor move;
    /// computed directly only on the first frame, before the cache is built.
    private var ppo2LegendRange: ClosedRange<Double>? {
        ppo2LegendCacheReady ? cachedPPO2Range : ppo2Range(Array(buildPPO2Map(for: dive).values))
    }

    /// False for a CCR dive with setpoints but no PPO₂: it draws no PPO₂ trace (only the
    /// setpoint line, in its own legend entry), so the PPO₂ group has no row — and, on macOS,
    /// no separator.
    private var ppo2LegendHasRow: Bool {
        !hasSetpointData || hasSensorPPO2Data || ppo2LegendRange != nil
    }
    private var showsDecoLegend: Bool { visibility.showDeco && hasDecoData }

    private var depthLegendGroup: some View {
        HStack(spacing: 8) {
            LegendDot(.cyan, "Normal")
            LegendDot(.orange, ascentRateLegendFast)
            LegendDot(.red, ascentRateLegendDangerous)
        }
    }

    private var temperatureLegendGroup: some View {
        MetricLegendRow(color: .green, label: "Temperature", range: temperatureRange)
    }

    /// One entry per tank on multi-tank dives. With `wrapping` (the stacked legend) the
    /// entries sit side by side and wrap onto further lines as needed; without it (the
    /// macOS single-line legend) they are laid out by the enclosing line.
    @ViewBuilder
    private func pressureLegendGroup(wrapping: Bool) -> some View {
        let tankIndices = chartTankIndicesForLegend
        if tankIndices.count > 1 {
            if wrapping {
                WrappingChipLayout(spacing: 8) { tankPressureLegendRows(tankIndices) }
            } else {
                tankPressureLegendRows(tankIndices)
            }
        } else {
            MetricLegendRow(color: .red, label: "Pressure", range: pressureRange)
        }
    }

    private func tankPressureLegendRows(_ tankIndices: [Int]) -> some View {
        ForEach(tankIndices, id: \.self) { idx in
            MetricLegendRow(color: .red, label: "T\(idx + 1) Pressure", range: pressureRangeForTank(idx))
        }
    }

    private var ndlLegendGroup: some View {
        MetricLegendRow(color: .ndlYellow, label: "NDL", range: ndlRange)
    }

    /// One entry per PPO₂ sensor when the dive has sensor readings, each with the range
    /// that sensor reported; otherwise one entry with the range of the voted or computed
    /// PPO₂ the chart draws. With `wrapping` (the stacked legend) the sensor entries sit
    /// side by side and wrap onto further lines as needed; without it (the macOS
    /// single-line legend) they are laid out by the enclosing line.
    @ViewBuilder
    private func ppo2LegendGroup(wrapping: Bool) -> some View {
        let sensorIndices = legendSensorIndices
        if sensorIndices.isEmpty {
            // The group is shown only when it has a row (`ppo2LegendHasRow`).
            MetricLegendRow(color: .indigo, label: "PPO₂", range: ppo2RangeText(ppo2LegendRange))
        } else if wrapping {
            WrappingChipLayout(spacing: 8) { sensorPPO2LegendRows(sensorIndices) }
        } else {
            sensorPPO2LegendRows(sensorIndices)
        }
    }

    private func sensorPPO2LegendRows(_ sensorIndices: [Int]) -> some View {
        // Cached once per dive; computed directly only on the first frame (see above).
        let ranges = ppo2LegendCacheReady ? cachedSensorPPO2Ranges : sensorPPO2Ranges()
        return ForEach(sensorIndices, id: \.self) { idx in
            MetricLegendRow(color: ppo2SensorColor(for: idx),
                            label: Text("S\(idx + 1) PPO₂", comment: "Chart legend: one O₂ sensor's PPO₂ range; the number is the sensor (1-based)"),
                            range: ppo2RangeText(ranges[idx]))
        }
    }

    /// Lowest to highest of the finite `values`, or nil when there are none. Non-finite
    /// readings are skipped: building a range from NaN would trap.
    private func ppo2Range(_ values: [Double]) -> ClosedRange<Double>? {
        let finite = values.filter(\.isFinite)
        guard let low = finite.min(), let high = finite.max() else { return nil }
        return low...high
    }

    /// "min-max bar" for a PPO₂ range, in the same form as the other legend ranges;
    /// two decimals, formatted for the region. "—" until the range is known.
    private func ppo2RangeText(_ range: ClosedRange<Double>?) -> String {
        guard let range else { return "—" }
        return range.lowerBound.localizedString(decimals: 2, minDecimals: 2) + "-"
            + range.upperBound.localizedString(decimals: 2, minDecimals: 2) + " bar"
    }

    private var decoLegendGroup: some View {
        HStack(spacing: 8) {
            if hasCeilingData {
                LegendBand(color: .orange, text: "Deco ceiling", alpha: 0.4)
            } else {
                LegendBand(color: .orange, text: "Deco obligation", alpha: 0.2)
            }
            // Only consult the async cache when the filter is active, so the
            // default (OFF) path stays synchronous and completely unchanged:
            // cachedDecoStopEntries is built in .task and is empty on frame one.
            if !prefs.hideClearedDecoStops || !cachedDecoStopEntries.isEmpty {
                LegendDiamond(color: .orange, text: "Mandatory stop")
            }
        }
    }

    private var gasSwitchLegendGroup: some View {
        LegendGasChange(color: .brown, text: "Gas switch")
    }

    /// The setpoint change markers, plus the setpoint line's range while PPO₂ is shown. With
    /// `wrapping` (the stacked legend) the two entries wrap onto a second line when they do not
    /// fit (long translations on iPhone); without it (the macOS single-line legend) they are laid
    /// out by the enclosing line.
    @ViewBuilder
    private func setpointLegendGroup(wrapping: Bool) -> some View {
        if wrapping {
            WrappingChipLayout(spacing: 8) { setpointLegendEntries }
        } else {
            HStack(spacing: 8) { setpointLegendEntries }
        }
    }

    @ViewBuilder
    private var setpointLegendEntries: some View {
        LegendGasChange(color: Color.ccrSetpoint, text: "Setpoint change", square: true)
        if visibility.showPPO2 {
            MetricLegendRow(color: Color.ccrSetpoint,
                            label: Text("Setpoint", comment: "Chart legend: range of the CCR setpoint line"),
                            range: ppo2RangeText(setpointRange))
        }
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
    
    // MARK: - Helper Properties
    
    /// Hash of tanks' O₂ fractions used to detect gas-mix edits without changing dive.id.
    /// Accessed during body so @Observable tracks tanksData as a dependency.
    private var tanksO2Hash: Int {
        dive.tanks.reduce(0) { ($0 &* 31) &+ Int($1.o2 * 1_000_000) }
    }

    /// Fingerprint of the display units that affect the chart (depth, temperature,
    /// pressure). Captured as a value so the Equatable `StaticChartLayer` re-renders
    /// when the user switches units, even though `prefs` is a shared reference whose
    /// two sides would otherwise compare equal. Read during body so @Observable
    /// tracks these unit properties as dependencies.
    private var unitsHash: Int {
        var hasher = Hasher()
        hasher.combine(prefs.depthUnit)
        hasher.combine(prefs.temperatureUnit)
        hasher.combine(prefs.pressureUnit)
        return hasher.finalize()
    }

    /// Also true for setpoint data alone: the setpoint line is drawn with the PPO₂ trace.
    private var ppo2Available: Bool {
        dive.tanks.contains { $0.o2 > 0 }
            || dive.profileSamples.contains { $0.ppo2 != nil }
            || dive.profileSamples.contains { $0.sensorPPO2?.isEmpty == false }
            || hasSetpointData
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

    // Gated on > 0, not just non-nil — see the matching hasCeilingData in StaticChartLayer.
    private var hasCeilingData: Bool {
        dive.profileSamples.contains { ($0.ceilingDepth ?? 0) > 0 }
    }

    private var hasGasChangeData: Bool {
        dive.profileSamples.contains { $0.events.contains(.gasChange) }
    }

    /// The dive's setpoint range: from the `.task` cache, as the legend is re-evaluated on every
    /// cursor move; computed directly only on the first frame, before the cache is built.
    private var setpointRange: ClosedRange<Double>? {
        setpointCacheReady ? cachedSetpointRange : SetpointProfile.range(for: dive)
    }

    private var hasSetpointData: Bool {
        setpointRange != nil
    }

    /// Sorted O₂ sensor indices with readings, for the legend; cached like `setpointRange`.
    private var legendSensorIndices: [Int] {
        setpointCacheReady ? cachedSensorIndices : sensorPPO2Indices(for: dive)
    }

    private var hasSensorPPO2Data: Bool {
        !legendSensorIndices.isEmpty
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

    /// Current decompression ceiling reported by the dive computer at this cursor position.
    /// `ceilingDepth` is stored in the dive's import distance unit, like `depth`.
    private var ceilingLabel: String? {
        // Gated on > 0, not just non-nil — see the matching hasCeilingData in StaticChartLayer.
        guard let ceiling = point.ceilingDepth, ceiling > 0 else { return nil }
        let converted = dive.displayProfileDepth(ceiling).localizedString(decimals: 1)
        return String(format: NSLocalizedString("Ceiling %1$@ %2$@", bundle: .forAppLanguage(), value: "Ceiling %1$@ %2$@", comment: "Tooltip row showing the current decompression ceiling in the dive chart; %1$@ is the depth value, %2$@ the depth unit symbol"), converted, prefs.depthUnit.symbol)
    }

    /// Depth + duration detail for the mandatory stop at this sample, shown as a sub-row.
    /// Returns nil when the sample does not coincide with a mandatory stop point.
    private var decoStopDetail: String? {
        guard let stop = matchingDecoStop else { return nil }
        // DecoStop.depth is always metres; convert to stored unit before displayProfileDepth.
        let stopInStoredUnit = dive.importDistanceUnit == "feet" ? stop.depth * 3.28084 : stop.depth
        let depth    = dive.displayProfileDepth(stopInStoredUnit).localizedString(decimals: 0) + prefs.depthUnit.symbol
        let duration = ceil(stop.time / 60).localizedString(decimals: 0) + "min"
        return String(format: NSLocalizedString("Stop %1$@ · %2$@", bundle: .forAppLanguage(), value: "Stop %1$@ · %2$@", comment: "Tooltip sub-row naming the next mandatory decompression stop in the dive chart; %1$@ is the stop depth with unit symbol, %2$@ is the stop duration e.g. '5min'"), depth, duration)
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
            TooltipRow(icon: "arrow.down.to.line", color: .cyan, label: depthLabel)

            // Ascent speed — always shown below depth
            if let speedLabel = ascentSpeedLabel {
                TooltipRow(icon: ascentSpeedIcon, color: ascentSpeedColor, label: speedLabel)
            }

            // Temperature — shown if enabled and data available
            if visibility.showTemperature, let tLabel = temperatureLabel {
                TooltipRow(icon: "thermometer.medium", color: .green, label: tLabel)
            }

            // Pressure — shown if enabled and data available
            if visibility.showPressure {
                if let perTank = perTankPressureLabels {
                    ForEach(perTank, id: \.index) { entry in
                        TooltipRow(icon: "gauge.with.needle.fill", color: .red, label: "T\(entry.index + 1): \(entry.label)")
                    }
                } else if let pLabel = pressureLabel {
                    TooltipRow(icon: "gauge.with.needle.fill", color: .red, label: pLabel)
                }
            }
            
            // NDL — shown if enabled and data available
            if visibility.showNDL, let nLabel = ndlLabel {
                TooltipRow(icon: "timer", color: .ndlYellow, label: nLabel)
            }

            // PPO2 — shown if enabled; voted row always shown, then per-sensor rows for CCR
            if visibility.showPPO2 {
                if let sensorData = point.sensorPPO2, !sensorData.isEmpty {
                    if let p = point.ppo2 {
                        let ppo2Color: Color = p < DiveProfileEvent.ppo2HypoxicThreshold ? .cyan
                            : p < DiveProfileEvent.ppo2WarnThreshold ? .green
                            : p < DiveProfileEvent.ppo2DangerThreshold ? .orange
                            : .red
                        TooltipRow(icon: "lungs.fill", color: ppo2Color, label: p.localizedString(decimals: 2, minDecimals: 2) + " bar")
                    }
                    ForEach(sensorData.keys.sorted(), id: \.self) { idx in
                        if let p = sensorData[idx] {
                            TooltipRow(icon: "lungs.fill", color: ppo2SensorColor(for: idx),
                                       label: String(format: NSLocalizedString("S%ld: ", bundle: Bundle.forAppLanguage(), comment: "Tooltip label prefix for per-O2-sensor PPO2 in the dive chart; %ld = sensor number (1-based)"), idx + 1) + p.localizedString(decimals: 2, minDecimals: 2) + " bar")
                        }
                    }
                } else if let p = point.ppo2 {
                    let ppo2Color: Color = p < DiveProfileEvent.ppo2HypoxicThreshold ? .cyan
                        : p < DiveProfileEvent.ppo2WarnThreshold ? .green
                        : p < DiveProfileEvent.ppo2DangerThreshold ? .orange
                        : .red
                    TooltipRow(icon: "lungs.fill", color: ppo2Color, label: p.localizedString(decimals: 2, minDecimals: 2) + " bar")
                }
            }

            // Deco event — shown if enabled and this sample carries a deco obligation.
            if visibility.showDeco && point.events.contains(.decoStop) {
                TooltipRow(icon: "exclamationmark.triangle.fill", color: .orange, label: decoDiveLabel)
                // When on a mandatory stop point, show depth + duration on a sub-row.
                if let detail = decoStopDetail {
                    TooltipRow(icon: "smallcircle.filled.circle", color: .orange.opacity(0.7), label: detail)
                }
            }

            // Deco ceiling — shown if enabled and the computer reported one at this point.
            if visibility.showDeco, let cLabel = ceilingLabel {
                TooltipRow(icon: "arrow.up.to.line", color: .orange, label: cLabel)
            }

            // Gas switch — always shown when present (gas change markers are always on).
            if let gasName = gasChangeName {
                TooltipRow(icon: "cylinder.fill", color: .brown, label: String(format: NSLocalizedString("→ %@", bundle: .forAppLanguage(), comment: "Gas switch tooltip row: arrow followed by gas mix name"), gasName))
            }

            // CCR setpoint in effect, held from the earlier sample (never interpolated); none
            // while no setpoint is in effect (e.g. on open-circuit bailout).
            if let setpoint = point.setpoint {
                TooltipRow(icon: "scope", color: Color.ccrSetpoint, label: String(format: NSLocalizedString("Setpoint %@", bundle: .forAppLanguage(), value: "Setpoint %@", comment: "Dive chart tooltip row: CCR setpoint in effect; %@ is the value with unit, e.g. '1.30 bar'"), setpoint.localizedString(decimals: 2, minDecimals: 2) + " bar"))
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

}

/// A labelled icon row inside `ChartTooltipView`. Used to be a plain function inlining
/// its HStack/Image/Text tree at every call site; `ChartTooltipView.body` calls it up to
/// 13 times statically (depth, ascent rate, temperature, per-tank/voted pressure, NDL,
/// PPO₂ (voted + per-sensor), deco event + detail, deco ceiling, gas switch) — see the
/// `LegendDot` doc comment above for why that risks the same stack-overflow crash class
/// this app has already hit once. Packaging it as a nominal struct bounds the complexity
/// at its own `body`.
struct TooltipRow: View {
    let icon: String
    let color: Color
    let label: String

    var body: some View {
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
