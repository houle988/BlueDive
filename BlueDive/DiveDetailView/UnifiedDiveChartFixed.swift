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
    /// Time to surface and remaining bottom time (minutes) held from the nearest earlier
    /// real sample — never interpolated; nil where that sample reported none.
    let tts: Double?
    let rbt: Double?
    let ascentSpeed: Double?
    /// GF99 and Surface GF calculated by BlueDive's ZHL-16C tissue model at the cursor time
    /// (`BuhlmannProfile`); nil when the dive's gases do not allow the calculation.
    let gradientFactors: BuhlmannZHL16C.Values?
}

/// Configuration de visibilité des lignes du graphique
struct ChartLineVisibility {
    var showDepth: Bool = true
    var showTemperature: Bool = false
    var showPressure: Bool = false
    var showNDL: Bool = false
    var showPPO2: Bool = false
    /// GF99 and Surface GF calculated by BlueDive (`BuhlmannProfile`).
    var showGF: Bool = false
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
        case "gf":          v.showGF = true
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
        else if showGF          { value = "gf" }
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

/// A gradient factor as a whole percentage in the OS region's format ("78 %" or "78%"), or
/// "≤ 0 %" at or below 0, while the tissues are not supersaturated (tooltip and legend).
fileprivate func gradientFactorText(_ value: Double) -> String {
    let percent = FloatingPointFormatStyle<Double>.Percent.percent.precision(.fractionLength(0)).locale(.current)
    guard value.isFinite, value > 0 else { return "≤ " + 0.0.formatted(percent) }
    return (value / 100).formatted(percent)
}

extension Color {
    /// Colour of the CCR setpoint: the chart's markers, line, legend entry and tooltip row, and
    /// the Samples table's SP column.
    static var ccrSetpoint: Color { .mint }

    /// Colour of GF99 and Surface GF: the chip, lines, legend entries and tooltip rows.
    static var gfMagenta: Color { Color(red: 0.80, green: 0.20, blue: 0.70) }
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
/// `DiveImportMapper` (Bluetooth) sets both together. Unioning yields the
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
    /// True to show `shortLabel` (when there is one) without first trying `label`, for a row
    /// laid out in its compact form.
    var usesShortLabel: Bool = false

    @ViewBuilder
    private var labelText: some View {
        if usesShortLabel, let shortLabel {
            Text(shortLabel).lineLimit(1).minimumScaleFactor(0.7)
        } else if let shortLabel {
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

// MARK: - Round axis scale (PDF logbook)

/// Round range and label spacing of a value, in its display unit: `lower` and `upper`
/// are multiples of `step`, so every label shows a round value. Used by the PDF logbook's
/// profile for its depth and time labels; the dive chart's right axis uses
/// `GridAlignedScale` instead (its labels sit on the depth gridlines).
struct SecondaryAxisScale {
    let lower: Double
    let upper: Double
    let step: Double

    var span: Double { upper - lower }

    /// Values that get a label, from `lower` to `upper` in `step` increments.
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
    /// step (`[1, 2, 5]` keeps whole values, `[1, 2, 2.5, 5]` also allows 25 or 0.25);
    /// `minimumStep` is the smallest step allowed (1 for whole values). A flat series still spans one step. `topHeadroom` adds a step when the
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
        // When the highest value lands on (or just below) a round value, add one step so
        // it is not drawn along the top edge of the scale.
        if topHeadroom, upper - high < step * 0.05 { upper += step }
        if upper <= lower { upper = lower + step }
        return SecondaryAxisScale(lower: lower, upper: upper, step: step)
    }
}

// MARK: - Grid-aligned right-axis scale

/// Scale of the dive profile chart's right-hand metric, aligned with the depth gridlines:
/// the metric changes by one round `step` per depth gridline (`depthStep` apart, in the
/// depth display unit), starting from `surfaceValue` on the surface line. Every right-axis
/// label therefore sits on a depth gridline and shows a round value. PPO₂ increases
/// downward (0 on the surface line); the other metrics have their highest value there.
private struct GridAlignedScale {
    let surfaceValue: Double
    let step: Double
    let depthStep: Double
    let increasesDownward: Bool

    /// The metric value on depth gridline `index` (0 = the surface line), computed from the
    /// index so a label never shows floating-point error.
    func value(atGridline index: Int) -> Double {
        let value = surfaceValue + Double(index) * step * (increasesDownward ? 1 : -1)
        // Normalise negative zero so a label never reads "-0".
        return value == 0 ? 0 : value
    }

    /// Depth (display unit, positive downward) at which `value` is drawn.
    func depth(of value: Double) -> Double {
        let steps = increasesDownward ? (value - surfaceValue) / step : (surfaceValue - value) / step
        return steps * depthStep
    }

    /// Decimals needed to show every multiple of `step` exactly (0.2 → 1, 20 → 0).
    var labelDecimals: Int {
        var decimals = 0
        var scaled = step
        while decimals < 3, abs(scaled - scaled.rounded()) > 1e-9 {
            scaled *= 10
            decimals += 1
        }
        return decimals
    }

    /// Steps `multipliers × 10ⁿ` from `minimumStep` upward, ascending (1, 2, 5, 10, 20, 50…).
    static func candidateSteps(minimumStep: Double, multipliers: [Double] = [1, 2, 5]) -> [Double] {
        // A step must be positive and finite, or no candidate would ever be added.
        guard minimumStep > 0, minimumStep.isFinite, multipliers.contains(where: { $0 > 0 }) else { return [1] }
        var steps: [Double] = []
        var magnitude = pow(10.0, (log10(minimumStep)).rounded(.down))
        while steps.count < 60 {
            for multiplier in multipliers where multiplier * magnitude >= minimumStep * (1 - 1e-9) {
                steps.append(multiplier * magnitude)
            }
            magnitude *= 10
        }
        return steps
    }

    /// The scale with the finest of `candidates` (ascending) for which the readings
    /// `low...high` fit between the surface line and `chartDepth` (a whole number of
    /// `depthStep` intervals), with a value on every gridline: the surface value is the
    /// highest reading rounded up to the step (the lowest, rounded down, when the metric
    /// increases downward), raised when needed so the bottom gridline's value is not below
    /// `minimumValue`; a step whose surface value would exceed `maximumSurfaceValue` (NDL
    /// cannot read above 100) is skipped. Steps more than ten times the readings' size are
    /// not tried: their rounding tolerance could pass a meaningless scale (e.g. a 1 m dive
    /// from −1.5 to 28.3 °C, which no round step fits on one interval, read as 2 000 000 000 → 0).
    /// Nil when no candidate fits.
    static func fitted(low: Double, high: Double, candidates: [Double], depthStep: Double,
                       chartDepth: Double, increasesDownward: Bool = false,
                       minimumValue: Double? = nil, maximumSurfaceValue: Double? = nil) -> GridAlignedScale? {
        let intervals = max((chartDepth / depthStep).rounded(), 1)
        let largestStep = max(abs(low), abs(high), 1) * 10
        for step in candidates where step > 0 {
            if step > largestStep { break }
            let tolerance = step * 1e-9
            if increasesDownward {
                var surface = (low / step).rounded(.down) * step
                if let minimumValue { surface = max(surface, (minimumValue / step - 1e-9).rounded(.up) * step) }
                guard surface + intervals * step >= high - tolerance else { continue }
                return GridAlignedScale(surfaceValue: surface, step: step, depthStep: depthStep, increasesDownward: true)
            } else {
                var surface = (high / step - 1e-9).rounded(.up) * step
                if let minimumValue {
                    // Raise the surface value so the bottom gridline's value is not below the minimum.
                    surface = max(surface, ((minimumValue + intervals * step) / step - 1e-9).rounded(.up) * step)
                }
                if let maximumSurfaceValue, surface > maximumSurfaceValue + tolerance { continue }
                guard surface - intervals * step <= low + tolerance else { continue }
                return GridAlignedScale(surfaceValue: surface, step: step, depthStep: depthStep, increasesDownward: false)
            }
        }
        return nil
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
    /// GF99 / Surface GF along the profile (built by the chart in `.task`, with the loading
    /// carried over from earlier dives), drawn by the GF lines.
    let tissueProfile: BuhlmannProfile?
    /// Changes each time `tissueProfile` is rebuilt, so the Equatable check redraws the lines.
    let tissueProfileVersion: Int
    /// How the plot height is set: the dive detail view's rule by default, the dive list's
    /// profile preview filling its pane.
    var heightRule: ChartHeightRule = .detail
    /// Told the plot's height when it fills its pane (`heightRule.fills`), so the dive list's
    /// preview can keep room for the chips and legend around it. Not compared by `==`.
    var onPlotHeightChange: ((CGFloat) -> Void)? = nil

    static func == (lhs: StaticChartLayer, rhs: StaticChartLayer) -> Bool {
        guard lhs.heightRule == rhs.heightRule else { return false }
        return lhs.dive.id == rhs.dive.id &&
        lhs.profileID == rhs.profileID &&
        lhs.tissueProfileVersion == rhs.tissueProfileVersion &&
        lhs.tanksO2Hash == rhs.tanksO2Hash &&
        lhs.unitsHash == rhs.unitsHash &&
        lhs.hideClearedDecoStops == rhs.hideClearedDecoStops &&
        lhs.visibility.showDepth == rhs.visibility.showDepth &&
        lhs.visibility.showTemperature == rhs.visibility.showTemperature &&
        lhs.visibility.showPressure == rhs.visibility.showPressure &&
        lhs.visibility.showNDL == rhs.visibility.showNDL &&
        lhs.visibility.showGF == rhs.visibility.showGF &&
        lhs.visibility.showPPO2 == rhs.visibility.showPPO2 &&
        lhs.visibility.showDeco == rhs.visibility.showDeco &&
        lhs.xMax == rhs.xMax &&
        lhs.depthBase == rhs.depthBase
    }

    // MARK: - Secondary axis scales

    // Each secondary metric's scale comes from the dive's own samples, in the display unit,
    // and is aligned with the depth gridlines (see `GridAlignedScale`): the finest round
    // step for which the dive's readings fit between the surface line and the chart depth,
    // one step per depth gridline. The right-axis labels sit on the depth gridlines, each
    // naming the trace value at its height. The scales only position marks and labels; no
    // sample value is altered.

    /// Pressure scale: the lowest to the highest reading across every tank the chart
    /// draws (the per-tank pressures when there are several tanks, the single tank
    /// pressure otherwise — the same samples `pressureMarks` plots), in the display unit.
    /// Falls back to 0–300 bar, in the display unit, when the dive has no pressure samples or
    /// a pressure that never changes.
    /// The step is at least 10 bar (100 psi, 1 000 000 Pa), so a nearly flat trace — a short
    /// dive or a tank barely breathed from — is not labelled in fractions of a bar.
    /// `tankIndices` is computed once in `body` and shared with `pressureMarks`.
    private func pressureAxis(tankIndices: [Int]) -> GridAlignedScale {
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
            // A corrupt non-finite reading would make the scale unusable.
            guard value.isFinite else { return }
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
        // 25 bar (250 psi) steps too, so a grid that cannot fit 20 bar steps gets 25 rather than 50.
        let candidates = GridAlignedScale.candidateSteps(minimumStep: minimumStep, multipliers: [1, 2, 2.5, 5])
        // No samples, or a pressure that never changes (e.g. always 0 with no transmitter):
        // the standard 0–300 bar scale rather than a scale fitted to a single value.
        guard lo < hi else {
            return fittedScale(low: 0, high: prefs.pressureUnit.convert(300, from: .bar), candidates: candidates,
                               minimumValue: 0)
        }
        return fittedScale(low: lo, high: hi, candidates: candidates, minimumValue: 0)
    }

    /// Temperature scale in whole degrees (steps of 1, 2, 5 or 10…), fitted to the dive's
    /// own lowest-to-highest temperature with no padding, so the step follows the data. A
    /// trace touching the top or bottom stays fully drawn (the plot's 1 pt clip outset).
    /// Falls back to a fixed range per unit when the dive has no temperature samples.
    private var temperatureAxis: GridAlignedScale {
        // Single allocation-free pass over the samples to find the display-unit
        // temperature extremes.
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for sample in dive.profileSamples {
            guard let raw = sample.temperature else { continue }
            let value = dive.displayProfileTemperature(raw)
            guard value.isFinite else { continue }
            if value < lo { lo = value }
            if value > hi { hi = value }
        }
        let candidates = GridAlignedScale.candidateSteps(minimumStep: 1)
        guard lo <= hi else {
            switch prefs.temperatureUnit {
            case .celsius:    return fittedScale(low: -10, high: 30, candidates: candidates)
            case .fahrenheit: return fittedScale(low: 14, high: 86, candidates: candidates)
            case .kelvin:     return fittedScale(low: 263, high: 303, candidates: candidates)
            }
        }
        return fittedScale(low: lo, high: hi, candidates: candidates)
    }

    /// NDL scale in whole minutes (steps of 1, 2, 5, 10, 20, 25, 50…), fitted to the lowest
    /// to the highest value `ndlMarks` plots (0 while a deco stop is owed; readings capped at
    /// 99). When the trace reaches the cap, the surface value is 100, labelled "99min",
    /// and capped readings are drawn on the surface line. Falls back to 0–100 min when the
    /// dive has no NDL samples or an NDL that never changes.
    /// `series` (`ndlSeriesSamples`) is computed once in `body` and shared with `ndlMarks`.
    private func ndlAxis(series: [DiveProfilePoint]) -> GridAlignedScale {
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for sample in series {
            guard let ndl = ndlPlotValue(for: sample) else { continue }
            let value = min(ndl, ndlPlotCap)
            if value < lo { lo = value }
            if value > hi { hi = value }
        }
        let candidates: [Double] = [1, 2, 5, 10, 20, 25, 50, 100, 200, 500, 1000]
        // No samples, or an NDL that never changes (e.g. 0 for the whole dive when the computer
        // recorded none): the standard 0–100 min scale rather than one fitted to a single value.
        guard lo < hi else {
            return fittedScale(low: 0, high: 100, candidates: candidates, minimumValue: 0, maximumSurfaceValue: 100)
        }
        return fittedScale(low: lo, high: hi, candidates: candidates, minimumValue: 0, maximumSurfaceValue: 100)
    }

    /// PPO₂ scale: from 0 to the highest value `ppo2Marks` plots (every O₂ sensor when the
    /// dive has per-sensor readings, the voted or computed PPO₂ in `data`, and the setpoint),
    /// in quarter-bar steps (0.25, 0.5, 1…), fitted to the dive's own values: e.g. a peak of
    /// 0.91 bar on a 9 m dive gives 0 / 0.25 … 1.25. 1.5 bar only when the dive has no PPO₂.
    /// `sensorIndices` and `data` are computed once in `body` and shared with `ppo2Marks`;
    /// `setpointRange` comes from the body's `SetpointProfile`.
    private func ppo2Axis(sensorIndices: [Int], data: [(time: Double, ppo2: Double, run: Int, joinsPrevious: Bool)],
                          setpointRange: ClosedRange<Double>?) -> GridAlignedScale {
        var hi = 0.0
        if !sensorIndices.isEmpty {
            for sample in dive.profileSamples {
                guard let readings = sample.sensorPPO2 else { continue }
                for idx in sensorIndices {
                    if let ppo2 = readings[idx], ppo2.isFinite, ppo2 > hi { hi = ppo2 }
                }
            }
        }
        // Non-finite (corrupt) readings are left out, so they cannot make the scale unusable.
        for point in data where point.ppo2.isFinite && point.ppo2 > hi { hi = point.ppo2 }
        // The setpoint line is drawn on the same scale.
        if let setpointRange, setpointRange.upperBound.isFinite, setpointRange.upperBound > hi { hi = setpointRange.upperBound }
        return fittedScale(low: 0, high: hi > 0 ? hi : ppo2AxisFallbackMax,
                           candidates: GridAlignedScale.candidateSteps(minimumStep: 0.25, multipliers: [1, 2, 2.5, 5]),
                           increasesDownward: true, minimumValue: 0)
    }

    /// Top of the PPO₂ scale, in bar, for a dive with no PPO₂ value to fit.
    private let ppo2AxisFallbackMax: Double = 1.5

    // MARK: - Depth grid

    /// Most depth intervals the chart shows, so its gridlines (and the right-axis labels
    /// on them) stay readable: 10 on the dive detail chart (about 28 pt apart at its
    /// 300 pt minimum height), 5 on the dive-list preview (macOS, wide iPad) (its plot can be as low as
    /// 120 pt).
    private var maxDepthIntervals: Double {
        heightRule == .listPreview ? 5 : 10
    }

    /// Depth below the surface line that the plot shows on a grid `step` apart (display
    /// unit): the chart depth rounded up to the next gridline, so the plot ends on a
    /// labelled line and every reading, down to the deepest, lies on or above it.
    private func plotDepth(step: Double) -> Double {
        guard depthBase > 0, depthBase.isFinite, step > 0, step.isFinite else { return 1 }
        return max((depthBase / step - 1e-9).rounded(.up), 1) * step
    }

    /// Depth steps the grid may use, finest first: `multipliers × 10ⁿ` (display unit;
    /// 1, 2, 5, 10, 20, 50… by default) giving between `minimumIntervals` and
    /// `maxDepthIntervals` intervals over the chart depth. A chart too shallow for the
    /// minimum gets the finest step within the maximum.
    private func depthGridCandidates(multipliers: [Double] = [1, 2, 5], minimumIntervals: Double = 3) -> [Double] {
        guard depthBase > 0, depthBase.isFinite else { return [1] }
        // Whole steps only (a 1.5 multiplier gives 15 and 150, never 1.5).
        let steps = GridAlignedScale.candidateSteps(minimumStep: 1, multipliers: multipliers)
            .filter { $0 == $0.rounded() }
        guard let finest = steps.first(where: { depthBase / $0 <= maxDepthIntervals }) else { return [depthBase] }
        let usable = steps.filter { $0 >= finest && depthBase / $0 >= minimumIntervals }
        return usable.isEmpty ? [finest] : usable
    }

    /// Depth grids tried in turn by `fittedScale`, until one labels every line: the round
    /// 1-2-5 steps; then also 3, 4, 6, 8 and 15 (e.g. NDL 99 → 0 needs 4, 5 or 10 intervals, which
    /// a 26 m dive gets with lines every 6 m); then, last, as few as 2 intervals (a 6 m dive:
    /// lines every 3 m, NDL 99 / 50 / 0).
    private var depthGridTiers: [[Double]] {
        [depthGridCandidates(),
         depthGridCandidates(multipliers: Self.extraDepthGridMultipliers),
         // A step up to two-thirds of the dive depth: the plot, which ends on the next
         // gridline, then has at least 2 intervals (a 5.6 m dive, lines every 3 m: 0 / 3 / 6).
         depthGridCandidates(multipliers: Self.extraDepthGridMultipliers, minimumIntervals: 1.5)]
    }

    /// Depth steps beyond the round 1-2-5 ones: 3, 4, 6, 8 and 15 (× 10ⁿ; 15 gives a dive
    /// just over 50 m lines every 15 m, so NDL 99 → 0 reads 99 / 75 / 50 / 25 / 0 rather than needing
    /// lines every 30 m).
    private static let extraDepthGridMultipliers: [Double] = [1, 1.5, 2, 3, 4, 5, 6, 8]

    /// The depth grid with no right-axis metric: the finest allowed step.
    private var defaultDepthGridStep: Double { depthGridCandidates().first ?? 1 }

    /// Plot Y (negated depth) of every depth gridline `step` apart, from the surface to
    /// the bottom of the plot (itself a gridline).
    private func depthGridValues(step: Double) -> [Double] {
        guard depthBase > 0, depthBase.isFinite, step > 0 else { return [0] }
        let count = min(Int(exactly: (plotDepth(step: step) / step + 1e-9).rounded(.down)) ?? 0, 100)
        return (0...max(count, 0)).map { -Double($0) * step }
    }

    /// The scale for `low...high` on the depth grid whose labels the readings fill best.
    /// Each allowed grid is tried (finest first) with the finest round step that fits the
    /// readings and leaves a value on every gridline (none below `minimumValue`, e.g. 0 for
    /// a pressure; a surface value not above `maximumSurfaceValue`, 100 for NDL). A coarser
    /// grid is kept only when the readings span clearly more of its scale (at least 15 % of
    /// it more). Constraints alone can decide, e.g. NDL 0–99 on a 39 m dive: every 10 m
    /// (99 / 75 / 50 / 25 / 0), since every 5 m (8 intervals) has no round step from at most
    /// 100 down to 0. When no grid of a tier (`depthGridTiers`) labels every line, the next
    /// tier is tried. When the round grids leave more than half of the scale empty, the
    /// extra grids (3, 4, 6, 8, 15…) are tried as well and kept when clearly fuller, e.g.
    /// PPO₂ peaking at 0.74 bar on a 14.8 m dive: lines every 3 m, 0 … 1.25, rather than every
    /// 2 m, 0 … 2. The depth axis then uses the chosen grid too (`body`).
    private func fittedScale(low: Double, high: Double, candidates: [Double], increasesDownward: Bool = false,
                             minimumValue: Double? = nil, maximumSurfaceValue: Double? = nil) -> GridAlignedScale {
        let tiers = depthGridTiers
        for (index, tier) in tiers.enumerated() {
            guard let fit = bestFittedScale(low: low, high: high, candidates: candidates, depthSteps: tier,
                                            increasesDownward: increasesDownward, minimumValue: minimumValue,
                                            maximumSurfaceValue: maximumSurfaceValue) else { continue }
            if index == 0, fit.fill < 0.5, tiers.count > 1,
               let fuller = bestFittedScale(low: low, high: high, candidates: candidates, depthSteps: tiers[1],
                                            increasesDownward: increasesDownward, minimumValue: minimumValue,
                                            maximumSurfaceValue: maximumSurfaceValue),
               fuller.fill > fit.fill + 0.15 {
                return fuller.scale
            }
            return fit.scale
        }
        // No grid can label every line: drop the bounds rather than show no scale. Rare,
        // e.g. NDL on a dive just over 2 m and under 3 m deep, whose only grid (every 1 m,
        // 3 intervals) cannot hold a 0–100 scale in round steps: 99 / 50 / 0, the lowest
        // line blank.
        let depthStep = defaultDepthGridStep
        return GridAlignedScale.fitted(low: low, high: high, candidates: candidates, depthStep: depthStep,
                                       chartDepth: plotDepth(step: depthStep), increasesDownward: increasesDownward)
            ?? GridAlignedScale(surfaceValue: increasesDownward ? low : high, step: max(high - low, 1),
                                depthStep: depthStep, increasesDownward: increasesDownward)
    }

    /// The best of `depthSteps` for `fittedScale`, with the share of its scale the readings
    /// span, or nil when none labels every line.
    private func bestFittedScale(low: Double, high: Double, candidates: [Double], depthSteps: [Double],
                                 increasesDownward: Bool, minimumValue: Double?,
                                 maximumSurfaceValue: Double?) -> (scale: GridAlignedScale, fill: Double)? {
        var best: (scale: GridAlignedScale, fill: Double)?
        for depthStep in depthSteps {
            let chartDepth = plotDepth(step: depthStep)
            guard let scale = GridAlignedScale.fitted(low: low, high: high, candidates: candidates,
                                                      depthStep: depthStep, chartDepth: chartDepth,
                                                      increasesDownward: increasesDownward, minimumValue: minimumValue,
                                                      maximumSurfaceValue: maximumSurfaceValue) else { continue }
            // Share of the scale (surface line to bottom gridline) the readings span.
            let fill = min(max((high - low) / (scale.step * (chartDepth / depthStep).rounded()), 0), 1)
            if best == nil || fill > (best?.fill ?? 0) + 0.15 {
                best = (scale, fill)
            }
        }
        return best
    }

    /// Plot Y of a secondary-metric value on its grid-aligned scale. Values outside the
    /// plot are clamped to it.
    private func plotY(_ value: Double, on scale: GridAlignedScale) -> Double {
        guard depthBase > 0 else { return 0 }
        return -scale.depth(of: value).clamped(to: 0...plotDepth(step: scale.depthStep))
    }

    /// Index of the depth gridline at plot Y `y` (0 = the surface line) on `scale`'s grid.
    private func gridlineIndex(atY y: Double, on scale: GridAlignedScale) -> Int {
        Int(exactly: ((-y) / scale.depthStep).rounded()) ?? 0
    }

    /// Whether the right axis's metric can be negative: only temperature (shown, and not
    /// overridden by PPO₂ or pressure, which come first in `secondaryAxisLabel`'s order).
    private var rightAxisAllowsNegative: Bool {
        visibility.showTemperature && !visibility.showPPO2 && !visibility.showPressure
    }

    /// Plot Y positions of the right-axis labels: the depth gridlines, except those whose
    /// value would be below 0 for a metric that cannot be negative.
    private func secondaryAxisMarks(_ scale: GridAlignedScale?) -> [Double] {
        // With no depth (every sample at 0 m) there is no grid to label.
        guard let scale, depthBase > 0 else { return [] }
        return depthGridValues(step: scale.depthStep).filter { y in
            rightAxisAllowsNegative || scale.value(atGridline: gridlineIndex(atY: y, on: scale)) >= -1e-9
        }
    }

    /// Highest NDL the chart plots, in minutes, as dive computers such as Shearwater display
    /// it: readings at or above it are drawn on the scale's surface line (100, labelled 99).
    private let ndlPlotCap: Double = 99

    // MARK: - Right-axis label builders

    /// Right-axis label text for whichever secondary metric is active. The four metrics
    /// are mutually exclusive in the toggle UI, so only one branch is ever live — but this
    /// stays a plain value computation rather than branching inside the axis's ViewBuilder
    /// content, which is what keeps that content's view-tree shape stable across toggles.
    private func secondaryAxisLabel(for y: Double, scale: GridAlignedScale?) -> String {
        guard let scale else { return "" }
        let value = scale.value(atGridline: gridlineIndex(atY: y, on: scale))
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
            // The surface line is labelled at most 99 (the plotted cap, where readings of 99
            // or more are drawn), even when its round value is 100.
            let shown = min(value, ndlPlotCap)
            return shown.localizedString(decimals: decimals) + "min"
        }
        if visibility.showGF {
            return (value / 100).formatted(.percent.precision(.fractionLength(decimals)).locale(.current))
        }
        return ""
    }

    private var secondaryAxisColor: Color {
        if visibility.showPPO2 { return .indigo }
        if visibility.showPressure { return .red }
        if visibility.showTemperature { return .green }
        if visibility.showNDL { return Color.ndlYellow }
        if visibility.showGF { return Color.gfMagenta }
        return .secondary
    }

    // The Y domain — depth values are negated so deeper = more negative = lower on chart.
    // Swift Charts naturally puts smaller values at the bottom, so negating gives us
    // surface (0) at top and max depth at bottom with no reversal tricks needed. The
    // bottom is the gridline at or below the chart depth (`plotDepth(step:)`) on the depth
    // grid in use, so the plot ends on a labelled line.

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
        let gfSeries = visibility.showGF ? gfRenderData : []
        // No % axis without a GF line (calculation pending, or a dive that cannot be calculated).
        let gfScale = visibility.showGF && !gfSeries.isEmpty ? gfAxis(series: gfSeries) : nil
        // Same order as `secondaryAxisLabel` and `secondaryAxisColor`.
        let rightAxisScale = ppo2Scale ?? pressureScale ?? temperatureScale ?? ndlScale ?? gfScale
        // The depth grid of the right-axis metric (its labels sit on these lines), else the finest.
        let depthGridStepShown = rightAxisScale?.depthStep ?? defaultDepthGridStep
        return Chart {
            legacyDecoBand(bottom: -plotDepth(step: depthGridStepShown))
            depthMarks
            decoMarks
            gasChangeMarks
            setpointChangeMarks(setpoints.changes)
            if let temperatureScale { temperatureMarks(scale: temperatureScale) }
            if let pressureScale { pressureMarks(scale: pressureScale, tankIndices: pressureTanks) }
            if let ndlScale { ndlMarks(scale: ndlScale, series: ndlSeries) }
            if let gfScale { gfMarks(scale: gfScale, series: gfSeries) }
            if let ppo2Scale { ppo2Marks(scale: ppo2Scale, sensorIndices: ppo2Sensors, data: ppo2Data, setpointLine: setpoints.linePoints) }
        }
        // Explicit domain from the bottom gridline (deepest, negative) to 0 (surface).
        // No automatic padding — the chart fills exactly to that line.
        .chartYScale(domain: -plotDepth(step: depthGridStepShown)...0)
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
            // Explicit round depths on the right-axis metric's grid (`fittedScale`), so its
            // labels sit on these lines; the finest grid when no metric is shown.
            AxisMarks(position: .leading, values: depthGridValues(step: depthGridStepShown)) { value in
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
            // The labels sit on the depth gridlines (`secondaryAxisMarks`), each showing the
            // metric's round value at that height, and carry no tick of their own: a short
            // tick beside a number reads as a minus sign. A small left-pointing triangle
            // outline points each label at its gridline instead.
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
        .chartHeight(heightRule, onPlotHeightChange: onPlotHeightChange)
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
    private func temperatureMarks(scale: GridAlignedScale) -> some ChartContent {
        let samplesWithTemp = dive.profileSamples.filter { $0.temperature != nil }
        ForEach(samplesWithTemp) { sample in
            if let temp = sample.temperature {
                // Each reading at its value's height on the scale: warmer higher, one round
                // step per depth gridline.
                let value = plotY(dive.displayProfileTemperature(temp), on: scale)
                LineMark(x: .value("Time", sample.time), y: .value("Temp.", value), series: .value("Sequence", "Temperature"))
                    .interpolationMethod(.monotone)
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
    private func pressureMarks(scale: GridAlignedScale, tankIndices: [Int]) -> some ChartContent {

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
                        .interpolationMethod(.monotone)
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
                        .interpolationMethod(.monotone)
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
    /// `decoMarks` applies to `ceilingDepth`. Dropping them instead let the line
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
    private func ndlMarks(scale: GridAlignedScale, series: [DiveProfilePoint]) -> some ChartContent {
        ForEach(series) { sample in
            if let ndl = ndlPlotValue(for: sample) {
                // Readings of 99 min or more are drawn on the surface line, which the scale
                // labels "99min" when the trace reaches the cap (see `ndlAxis`); the capped
                // line runs along the top edge at full width (the plot's 1 pt clip outset).
                // `.monotone` (as the pressure, temperature and PPO₂ traces): the curve never overshoots its
                // samples, so a jump from 99 to 0 at the plot's edges stays inside the plot
                // instead of bulging past the edge and being clipped (`.catmullRom` did).
                let value = plotY(ndl >= ndlPlotCap ? scale.surfaceValue : ndl, on: scale)
                LineMark(x: .value("Time", sample.time), y: .value("NDL", value), series: .value("Sequence", "NDL"))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Color.ndlYellow)
            }
        }
    }

    // MARK: - GF overlay (calculated by BlueDive's ZHL-16C tissue model)

    /// GF99 and Surface GF at each profile sample (`BuhlmannProfile`), for the GF lines and
    /// their scale. A value at or below 0 (the tissues are not supersaturated) is drawn at 0,
    /// the bottom of the plot, so both lines run through the whole dive; the tooltip shows it as
    /// "≤ 0 %". A line is broken only where the value cannot be calculated (each line starts a
    /// new run there), never bridged across samples with no value.
    private var gfRenderData: [(time: Double, value: Double, run: Int, surface: Bool)] {
        guard let profile = tissueProfile else { return [] }
        let inputs = profile.inputs
        var data: [(time: Double, value: Double, run: Int, surface: Bool)] = []
        var gf99Run = 0, surfaceRun = 0
        var gf99Drawn = false, surfaceDrawn = false
        for index in inputs.times.indices {
            let values = profile.values(atSample: index)
            let time = inputs.times[index]
            if let gf99 = values?.gf99, gf99.isFinite {
                data.append((time: time, value: max(0, gf99), run: gf99Run, surface: false))
                gf99Drawn = true
            } else if gf99Drawn {
                gf99Run += 1
                gf99Drawn = false
            }
            if let surfaceGF = values?.surfaceGF, surfaceGF.isFinite {
                data.append((time: time, value: max(0, surfaceGF), run: surfaceRun, surface: true))
                surfaceDrawn = true
            } else if surfaceDrawn {
                surfaceRun += 1
                surfaceDrawn = false
            }
        }
        return data
    }

    /// GF scale in whole percent: from 0 to the highest GF99 or Surface GF the chart draws,
    /// never below 100 % so the raw Bühlmann limit (the 100 % line) is always on the plot.
    private func gfAxis(series: [(time: Double, value: Double, run: Int, surface: Bool)]) -> GridAlignedScale {
        let hi = series.map(\.value).max() ?? 0
        // 25 % steps too, so a grid that cannot fit 20 % steps gets 25 rather than 50.
        return fittedScale(low: 0, high: max(hi, 100),
                           candidates: GridAlignedScale.candidateSteps(minimumStep: 10, multipliers: [1, 2, 2.5, 5]), minimumValue: 0)
    }

    /// GF99 as a solid line and Surface GF as a dashed one, in magenta, with a thin dotted
    /// line at 100 %, the raw Bühlmann M-value.
    @ChartContentBuilder
    private func gfMarks(scale: GridAlignedScale,
                         series: [(time: Double, value: Double, run: Int, surface: Bool)]) -> some ChartContent {
        if !series.isEmpty {
            // The percentage is formatted in code (region-dependent spacing before %).
            RuleMark(y: .value(Text(verbatim: String(format: NSLocalizedString("GF %@", bundle: .forAppLanguage(), value: "GF %@", comment: "Dive chart: accessibility label of the dotted line at 100 % of the GF, the raw Bühlmann M-value; %@ is the percentage (e.g. '100 %')"), gradientFactorText(100))), plotY(100, on: scale)))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .foregroundStyle(Color.gfMagenta.opacity(0.7))
        }
        ForEach(Array(series.enumerated()), id: \.offset) { _, point in
            LineMark(
                x: .value("Time", point.time),
                y: .value("GF", plotY(point.value, on: scale)),
                series: .value("Sequence", point.surface ? "SurfaceGF-\(point.run)" : "GF99-\(point.run)")
            )
            .interpolationMethod(.linear)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round,
                                   dash: point.surface ? [6, 3] : []))
            .foregroundStyle(Color.gfMagenta)
        }
    }

    // MARK: - PPO₂ overlay (sensor values preferred per sample; computed as fallback)

    /// Produces (time, ppo2, run, joinsPrevious) for each profile sample using the shared
    /// `buildPPO2Map` helper. Per-sample: sensor value if available, else Dalton's-Law from gas
    /// mix + depth. The smoothed line starts a new run where the breathing mode changes (a
    /// setpoint starts or stops: loop ↔ open circuit), so the two sections are not smoothed
    /// into one curve; `joinsPrevious` marks the first point after such a change when the
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
    private func ppo2Marks(scale: GridAlignedScale, sensorIndices: [Int],
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
                            y: .value("PPO₂", plotY(point.ppo2, on: scale)),
                            series: .value("Sequence", "PPO2-S\(sensorIdx)-\(point.run)")
                        )
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: dash))
                        .foregroundStyle(ppo2SensorColor(for: sensorIdx))
                    }
                    // A one-point run (a single reading between two switches) is drawn as a dot.
                    let loneRuns = singlePointRuns(points.map(\.run))
                    ForEach(Array(points.enumerated().filter { loneRuns.contains($0.element.run) }), id: \.offset) { _, point in
                        PointMark(
                            x: .value("Time", point.time),
                            y: .value("PPO₂", plotY(point.ppo2, on: scale))
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
                    let y = plotY(point.ppo2, on: scale)
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("PPO₂", y),
                        series: .value("Sequence", "PPO2-\(point.run)")
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(ppo2LineStyle)
                    .foregroundStyle(ppo2LineColor)
                }
                // Straight segment across each loop ↔ open-circuit switch (see ppo2RenderData).
                ForEach(Array(data.indices.filter { $0 > 0 && data[$0].joinsPrevious }), id: \.self) { index in
                    ForEach([index - 1, index], id: \.self) { pointIndex in
                        let point = data[pointIndex]
                        LineMark(
                            x: .value("Time", point.time),
                            y: .value("PPO₂", plotY(point.ppo2, on: scale)),
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
                        y: .value("PPO₂", plotY(point.ppo2, on: scale))
                    )
                    .symbolSize(16)
                    .foregroundStyle(ppo2LineColor)
                }
            }
            ForEach(Array(setpointLine.enumerated()), id: \.offset) { _, point in
                LineMark(
                    x: .value("Time", point.time),
                    y: .value("PPO₂", plotY(point.setpoint, on: scale)),
                    series: .value("Sequence", "Setpoint-\(point.run)")
                )
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [4, 3]))
                .foregroundStyle(Color.ccrSetpoint)
            }
            let loneSetpointRuns = singlePointRuns(setpointLine.map(\.run))
            ForEach(Array(setpointLine.enumerated().filter { loneSetpointRuns.contains($0.element.run) }), id: \.offset) { _, point in
                PointMark(
                    x: .value("Time", point.time),
                    y: .value("PPO₂", plotY(point.setpoint, on: scale))
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
    private func legacyDecoBand(bottom yMin: Double) -> some ChartContent {
        if visibility.showDeco && !hasCeilingData {
            let blocks = decoBlocks
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

/// Short line swatch (solid or dashed) with a label and value, for line legend entries (GF).
struct LegendLine: View {
    let color: Color
    let dashed: Bool
    let text: Text
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 1))
                path.addLine(to: CGPoint(x: 14, y: 1))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [4, 2] : []))
            .frame(width: 14, height: 2)
            (text + Text(": \(value)"))
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

// MARK: - Chart Height

/// How the plot height is set. On macOS, whose windows are tall and resizable, the dive detail
/// chart grows with the visible height of its container (the enclosing scroll view, or the
/// window), as a fraction of it clamped to a range; on iOS it keeps its 300 pt. The dive list's
/// profile preview (macOS, and iPad in a wide window) fills its pane on both.
struct ChartHeightRule: Equatable {
    let fraction: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    /// The plot takes all the height its parent leaves it (at least `minHeight`)
    /// instead of a fraction of its container.
    var fills = false

    /// Dive detail view: 45 % of the visible height, never below the iOS height (300 pt)
    /// or above 600 pt.
    static let detail = ChartHeightRule(fraction: 0.45, minHeight: 300, maxHeight: 600)
    /// Profile preview above the dive list, whose height the user sets with the divider below
    /// it: the plot fills what the chips and legend leave of the pane, so the gap above the
    /// divider stays the same wherever it is.
    static let listPreview = ChartHeightRule(fraction: 1, minHeight: 120, maxHeight: .infinity, fills: true)

    func height(for containerHeight: CGFloat) -> CGFloat {
        min(max(containerHeight * fraction, minHeight), maxHeight)
    }
}

private extension View {
    @ViewBuilder
    func chartHeight(_ rule: ChartHeightRule, onPlotHeightChange: ((CGFloat) -> Void)? = nil) -> some View {
        if rule.fills {
            frame(minHeight: rule.minHeight, maxHeight: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onPlotHeightChange?($0) }
        } else {
            #if os(macOS)
            containerRelativeFrame(.vertical) { height, _ in
                rule.height(for: height)
            }
            #else
            // The iOS plot height (the rule's minimum, 300 pt for the dive detail chart).
            frame(height: rule.minHeight)
            #endif
        }
    }
}

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
    /// How the plot height is set: the dive detail chart's (`.detail`), or the pane above the
    /// dive list (`.listPreview`, sized by its divider).
    var chartHeightRule: ChartHeightRule = .detail
    /// Told the plot's height when it fills its pane (see `StaticChartLayer.onPlotHeightChange`).
    var onPlotHeightChange: ((CGFloat) -> Void)? = nil
    /// Wide-window layouts (macOS; iPad at regular width): see `WideWindowLayout`.
    private var wideWindow = WideWindowLayout()
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
        /// Helium, altitude, surface pressure, water type and depth unit, so the PPO₂ caches (which
        /// read them through `PPO2Setup`) are rebuilt when one changes. (GF has its own key, in
        /// `GFTissueFeeder`.)
        let tissueInputsHash: Int
    }

    private var chartCacheKey: ChartCacheKey {
        ChartCacheKey(profile: profileCacheID, tanksO2Hash: tanksO2Hash,
                      hideClearedDecoStops: prefs.hideClearedDecoStops,
                      tissueInputsHash: tissueInputsHash)
    }

    /// Fingerprint of the tanks' He fractions, the site altitude, the recorded surface pressure,
    /// the water type and the depth unit, for `ChartCacheKey`. Read during body so @Observable tracks these as dependencies.
    private var tissueInputsHash: Int {
        var hasher = Hasher()
        for tank in dive.tanks { hasher.combine(tank.he) }
        hasher.combine(dive.siteAltitude)
        hasher.combine(dive.surfacePressure)
        hasher.combine(dive.siteWaterType)
        hasher.combine(dive.importDistanceUnit)
        return hasher.finalize()
    }

    /// GF99 / Surface GF results, written by `GFTissueFeeder` (which owns the calculation and its
    /// triggers, so cursor moves never re-evaluate them) and read through the accessors below.
    @State private var gfCache = GFTissueCache()

    /// The tissue profile when it was built for the dive shown, else nil: the same chart can
    /// show another dive (the macOS dive-list preview, previous/next dive).
    private var tissueProfile: BuhlmannProfile? {
        gfCache.diveID == dive.id ? gfCache.profile : nil
    }

    /// The GF maxima when they were built for the dive shown, else nil.
    private var gfMaxima: BuhlmannZHL16C.Values? {
        gfCache.diveID == dive.id ? gfCache.maxima : nil
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
        .background(GFTissueFeeder(dive: dive, showGF: visibility.showGF && hasGFData, cache: gfCache))
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
                    visibility.showGF = false
                }
                visibility[keyPath: keyPath] = newValue
                visibility.save()
            }
        )
    }
    
    /// First group of chips: Temperature, NDL, GF. Depth has no chip: it is always drawn, as the
    /// note under the chips says. `shortLabels` shows Temperature by its short label;
    /// `gfShowsLabel` false makes the GF chip icon only, for a row that has no room for a third
    /// labelled chip even then.
    @ViewBuilder
    private func primaryToggleChips(shortLabels: Bool = false, gfShowsLabel: Bool = true) -> some View {
        ToggleButton(
            isOn: exclusiveBinding(for: \.showTemperature),
            icon: "thermometer",
            label: "Temperature",
            shortLabel: "Temp.",
            color: .green,
            textColor: Color.readableGreen,
            isAvailable: hasTemperatureData,
            usesShortLabel: shortLabels
        )

        ToggleButton(
            isOn: exclusiveBinding(for: \.showNDL),
            icon: "timer",
            label: "NDL",
            color: .ndlYellow,
            textColor: Color.readableAmber,
            isAvailable: hasNDLData
        )

        ToggleButton(
            isOn: exclusiveBinding(for: \.showGF),
            icon: "gauge.with.dots.needle.67percent",
            label: "GF",
            color: .gfMagenta,
            textColor: Color.readableMagenta,
            isAvailable: hasGFData,
            showsLabel: gfShowsLabel
        )
        .accessibilityLabel(Text("GF"))
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
            if usesWideChartLayout {
                // A wide window (macOS, iPad at regular width) is usually wide enough for all
                // the chips on one row; else two rows with their full labels; the compact rows
                // (short labels) are the last resort. ViewThatFits measures the chips at their
                // full-label width, so the single row is only used when no chip would have to
                // switch to its short label.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        primaryToggleChips()
                        secondaryToggleChips
                        photosChip(showsLabel: true)
                    }
                    VStack(spacing: 12) {
                        HStack(spacing: 12) { primaryToggleChips() }
                        HStack(spacing: 12) {
                            secondaryToggleChips
                            photosChip(showsLabel: true)
                        }
                    }
                    compactToggleRows
                }
            } else {
                compactToggleRows
            }
            // Preceded by a swatch of the depth line (same colour and width as `depthMarks`),
            // drawn like the legend's line swatches; decorative, the text already says it.
            HStack(spacing: 6) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 1))
                    path.addLine(to: CGPoint(x: 14, y: 1))
                }
                .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 14, height: 2)
                .accessibilityHidden(true)
                Text("Depth is always displayed on the chart")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    /// The chips in two rows (iPhone, iPad in a narrow window): full labels when the row has
    /// room; else Temperature by its short label with GF still labelled; GF icon only where even
    /// that does not fit (a small iPhone, a long language, large text). The second row's chips are
    /// labelled like the others when it has room, icon only where a fourth labelled chip would
    /// not fit.
    private var compactToggleRows: some View {
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { primaryToggleChips() }
                HStack(spacing: 12) { primaryToggleChips(shortLabels: true) }
                HStack(spacing: 12) { primaryToggleChips(shortLabels: true, gfShowsLabel: false) }
            }
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
        }
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

        let layer = StaticChartLayer(dive: dive, visibility: visibility, xMax: xMax, depthBase: depthBase, prefs: prefs, tanksO2Hash: tanksO2Hash, unitsHash: unitsHash, hideClearedDecoStops: prefs.hideClearedDecoStops, profileID: profileCacheID, tissueProfile: tissueProfile, tissueProfileVersion: gfCache.version, heightRule: chartHeightRule, onPlotHeightChange: onPlotHeightChange)
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
            tts: prev.tts,
            rbt: prev.rbt,
            ascentSpeed: ascentSpeed,
            gradientFactors: tissueProfile?.values(atMinutes: cursorTime)
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
            tts: sample.tts,
            rbt: sample.rbt,
            ascentSpeed: ascentSpeed,
            gradientFactors: tissueProfile?.values(atMinutes: cursorTime)
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

    /// Whether the chips and the legend use the wide-window layout (one row or line, with
    /// fallbacks): on macOS, and on iPad in a wide window (regular width). iPhone, and iPad in a
    /// narrow window, keep the two chip rows and the stacked legend.
    private var usesWideChartLayout: Bool {
        wideWindow.isActive
    }

    @ViewBuilder
    private var legendView: some View {
        if usesWideChartLayout {
            // A wide window is usually wide enough for the whole legend on one line.
            // When it is not (narrower window, or many tank-pressure / PPO₂-sensor entries),
            // split the shown groups evenly over two lines; the stacked layout is the
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
                    // The shorter line centred under the longer one, as the stacked legend's.
                    VStack(alignment: .center, spacing: 6) {
                        legendLine(Array(groups.prefix(firstLineCount)))
                        legendLine(Array(groups.dropFirst(firstLineCount)))
                    }
                }
                stackedLegend
            }
            .padding(.horizontal)
        } else {
            stackedLegend
                .padding(.horizontal)
        }
    }

    private var legendTitle: some View {
        Text("Legend")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }

    /// Whether the stacked legend's lines are each centred, like the legend's other layouts
    /// (macOS, iPad), rather than spanning the full width from the leading edge (iPhone).
    private var centersStackedLegend: Bool {
        WideWindowLayout.isSupportedOnDevice
    }

    /// Title above the legend groups, one group per line.
    private var stackedLegend: some View {
        // Each line centred on macOS and iPad, at the leading edge on iPhone.
        let alignment: HorizontalAlignment = centersStackedLegend ? .center : .leading
        return VStack(alignment: alignment, spacing: 8) {
            legendTitle

            VStack(alignment: alignment, spacing: 6) {
                if showsDepthLegend { depthLegendGroup }
                if showsTemperatureLegend { temperatureLegendGroup }
                if showsPressureLegend { pressureLegendGroup(wrapping: true) }
                if showsNDLLegend { ndlLegendGroup }
                if showsGFLegend { gfLegendGroup(wrapping: true) }
                if showsPPO2Legend { ppo2LegendGroup(wrapping: true) }
                if showsDecoLegend { decoLegendGroup }
                if hasGasChangeData { gasSwitchLegendGroup }
                if hasSetpointData { setpointLegendGroup(wrapping: true) }
            }
        }
    }

    /// Indices (0 = depth … 7 = gas switch, 8 = setpoint, the stacked legend's order) of the legend
    /// groups currently shown (the wide legend's lines).
    private var shownLegendGroups: [Int] {
        let shown = [showsDepthLegend, showsTemperatureLegend, showsPressureLegend,
                     showsNDLLegend, showsGFLegend, showsPPO2Legend, showsDecoLegend, hasGasChangeData,
                     hasSetpointData]
        return shown.indices.filter { shown[$0] }
    }

    /// The given legend groups side by side, separated by a vertical line (wide legend).
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
        case 4: gfLegendGroup(wrapping: false)
        case 5: ppo2LegendGroup(wrapping: false)
        case 6: decoLegendGroup
        case 7: gasSwitchLegendGroup
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

    // MARK: Legend Groups

    private var showsDepthLegend: Bool { visibility.showDepth }
    private var showsTemperatureLegend: Bool { visibility.showTemperature && hasTemperatureData }
    private var showsPressureLegend: Bool { visibility.showPressure && hasPressureData }
    private var showsNDLLegend: Bool { visibility.showNDL && hasNDLData }
    private var showsGFLegend: Bool { visibility.showGF && hasGFData }
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
                WrappingChipLayout(spacing: 8, fillsProposedWidth: !centersStackedLegend, centersLines: centersStackedLegend) { tankPressureLegendRows(tankIndices) }
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

    /// GF99 (solid) and Surface GF (dashed) with the highest value of each, and a note that
    /// BlueDive calculated them. With `wrapping` (the stacked legend) the entries wrap onto
    /// further lines as needed, like the PPO₂ sensor entries.
    @ViewBuilder
    private func gfLegendGroup(wrapping: Bool) -> some View {
        if wrapping {
            WrappingChipLayout(spacing: 8, fillsProposedWidth: !centersStackedLegend, centersLines: centersStackedLegend) { gfLegendEntries }
        } else {
            HStack(spacing: 8) { gfLegendEntries }
        }
    }

    /// The entries, with "max —" and no notes until something was calculated for the dive.
    @ViewBuilder
    private var gfLegendEntries: some View {
        let maxima = gfMaxima
        LegendLine(color: .gfMagenta, dashed: false, text: Text("GF99"),
                   value: gfMaximumText(maxima?.gf99))
        LegendLine(color: .gfMagenta, dashed: true, text: Text("Surface GF"),
                   value: gfMaximumText(maxima?.surfaceGF))
        if maxima != nil {
            Text("Calculated by BlueDive (Bühlmann ZHL-16C)", comment: "Dive chart legend note: GF99 and Surface GF are calculated by BlueDive with the Bühlmann ZHL-16C model, not reported by the dive computer")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        if maxima != nil, let residual = tissueProfile?.residual {
            if residual.missingDive {
                Text("An earlier dive in the repetitive series could not be included: clean tissues at the start", comment: "Dive chart legend note: one of the same diver's earlier dives (each less than 48 hours before the next) has no profile or known gas, so GF99 and Surface GF start with clean tissues instead of including the earlier dives' nitrogen loading")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if residual.includedDives > 0 {
                Text(verbatim: String(format: NSLocalizedString("Earlier dives included: %@", bundle: .forAppLanguage(), value: "Earlier dives included: %@", comment: "Dive chart legend note: number of the same diver's earlier dives (less than 48 hours apart) whose nitrogen loading GF99 and Surface GF include; %@ is the number"),
                                          Double(residual.includedDives).localizedString(decimals: 0)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        if maxima == nil, gfCache.diveID == dive.id, gfCache.notCalculable {
            Text("GF could not be calculated for this dive", comment: "Dive chart legend note: the dive's gas is unknown from its first stretch (e.g. a tank with no O₂ recorded, or on the CCR loop with no gas that holds inert gas), so no GF99 or Surface GF could be calculated")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        if maxima != nil, tissueProfile?.inputs.usesSetpointAsPPO2 == true
            || tissueProfile?.residual.usesSetpointAsPPO2 == true {
            Text("Setpoint used where no PPO₂ was recorded", comment: "Dive chart legend note: on a CCR dive, GF99 and Surface GF use the setpoint as the breathed oxygen partial pressure where the dive computer recorded no PPO₂ (no voted value, no O₂ cell)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// "max 78 %" for the GF legend, "max ≤ 0 %" when the value never rises above 0, "max —"
    /// while nothing is calculated or when nothing can be (never a value that was not calculated).
    private func gfMaximumText(_ value: Double?) -> String {
        String(format: NSLocalizedString("max %@", bundle: .forAppLanguage(), value: "max %@", comment: "Dive chart legend: highest GF99 or Surface GF of the dive; %@ is a percentage (e.g. '78 %'), '≤ 0 %', or '—' while nothing is calculated"),
               value.map(gradientFactorText) ?? "—")
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
            WrappingChipLayout(spacing: 8, fillsProposedWidth: !centersStackedLegend, centersLines: centersStackedLegend) { sensorPPO2LegendRows(sensorIndices) }
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
            WrappingChipLayout(spacing: 8, fillsProposedWidth: !centersStackedLegend, centersLines: centersStackedLegend) { setpointLegendEntries }
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
    
    /// Whether the dive has what GF99 and Surface GF need: a known gas (a tank with O₂) and a
    /// profile of at least two samples (see `buhlmannInputs`). A cheap check, so the chip's state
    /// is known before any tissue calculation, which runs only while the chip is on.
    private var hasGFData: Bool {
        dive.tanks.contains { $0.o2 > 0 } && dive.profileSamples.count > 1
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

            // GF99 and Surface GF, calculated by BlueDive (ZHL-16C) — shown if enabled.
            if visibility.showGF, let gf = point.gradientFactors {
                TooltipRow(icon: "gauge.with.dots.needle.67percent", color: .gfMagenta,
                           label: String(format: NSLocalizedString("GF99 %@", bundle: .forAppLanguage(), value: "GF99 %@", comment: "Dive chart tooltip row: GF99 calculated by BlueDive (Bühlmann ZHL-16C), the current supersaturation as a percentage of the M-value gradient; %@ is the percentage (e.g. '78 %') or '≤ 0 %' when the tissues are not supersaturated"), gradientFactorText(gf.gf99)))
                TooltipRow(icon: "arrow.up.to.line", color: .gfMagenta,
                           label: String(format: NSLocalizedString("Surface GF %@", bundle: .forAppLanguage(), value: "Surface GF %@", comment: "Dive chart tooltip row: Surface GF calculated by BlueDive (Bühlmann ZHL-16C), the supersaturation the diver would have on surfacing now, as a percentage of the M-value gradient; %@ is the percentage (e.g. '85 %') or '≤ 0 %' when the tissues would not be supersaturated"), gradientFactorText(gf.surfaceGF)))
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

            // Time to surface — always shown when the dive computer reported it (no chart chip).
            // Remaining bottom time is computed from the gas consumption and the tank pressure
            // (air integration), so it goes with the pressure: shown only when Pressure is on.
            // In their own view to keep this body's type small.
            let rbt = visibility.showPressure ? point.rbt : nil
            if point.tts != nil || rbt != nil {
                TooltipTimeRows(tts: point.tts, rbt: rbt)
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
/// PPO₂ (voted + per-sensor), deco event + detail, deco ceiling, gas switch), plus the GF,
/// setpoint and `TooltipTimeRows` (TTS, RBT) rows — see the
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

/// The time to surface and remaining bottom time rows of `ChartTooltipView`, as reported by
/// the dive computer (minutes). A nominal view of its own, like `TooltipRow`, so the tooltip
/// body gains one call rather than two (see the `LegendDot` doc comment).
struct TooltipTimeRows: View {
    let tts: Double?
    let rbt: Double?

    var body: some View {
        if let tts {
            TooltipRow(icon: "clock.arrow.circlepath", color: .pink, label: String(format: NSLocalizedString("TTS %@ min", bundle: .forAppLanguage(), value: "TTS %@ min", comment: "Dive chart tooltip row: time to surface reported by the dive computer; %@ is the number of minutes"), DiveProfilePoint.displayedMinutes(tts).localizedString(decimals: 0)))
        }
        if let rbt {
            TooltipRow(icon: "hourglass.bottomhalf.filled", color: .green, label: String(format: NSLocalizedString("RBT %@ min", bundle: .forAppLanguage(), value: "RBT %@ min", comment: "Dive chart tooltip row: remaining bottom time reported by the dive computer; %@ is the number of minutes"), DiveProfilePoint.displayedMinutes(rbt).localizedString(decimals: 0)))
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

// MARK: - GF tissue calculation (GF99 and Surface GF)

/// GF99 / Surface GF results for one chart, shared between the chart (which reads them) and
/// `GFTissueFeeder` (which writes them).
@Observable
final class GFTissueCache {
    /// Tissue states along the profile, nil while the GF chip is off or when the dive cannot be
    /// calculated.
    var profile: BuhlmannProfile?
    /// Highest GF99 and Surface GF at the calculated samples; nil when no more than the first
    /// sample could be calculated.
    var maxima: BuhlmannZHL16C.Values?
    /// True when the dive was calculated but no more than its starting point is known (e.g. an
    /// unknown mix or an unknown diluent from the first stretch): no line is drawn, and the
    /// legend says so.
    var notCalculable = false
    /// The dive `profile` and `maxima` were built for.
    var diveID: UUID?
    /// Bumped when `profile` changes (the static chart layer's redraw signal).
    var version = 0
}

/// Calculates the tissue profile for the chart's dive while the GF chip is on, starting from
/// the loading left by the same diver's earlier dives, and recalculates it only when what it
/// reads changes. A separate view, attached in the background, so the chart's cursor moves
/// (which re-evaluate the chart's body) never re-evaluate the triggers below: its body reads
/// only the dive, the chip and the candidate earlier dives, and so is re-evaluated only when
/// one of them changes.
private struct GFTissueFeeder: View {
    let dive: Dive
    let showGF: Bool
    let cache: GFTissueCache

    /// Optional so the chart previews run without a store; the app always provides one.
    @Environment(DiveStore.self) private var store: DiveStore?
    @Environment(\.modelContext) private var modelContext

    /// The same diver's dives the calculation may carry loading from
    /// (`buhlmannPriorCandidateIDs`), looked up while the chip is on, and the dive they were
    /// looked up for: no calculation runs until they belong to the dive shown.
    @State private var candidateIDs: [UUID] = []
    @State private var candidatesDiveID: UUID?
    /// Bumped when the store's dive summaries change while the chip is on, so the candidates
    /// are looked up again.
    @State private var summariesVersion = 0

    /// What the candidates depend on: the dive, its start and diver, the logbook's dives and
    /// the chip.
    private struct CandidateKey: Equatable {
        let diveID: UUID
        let start: Date
        let diver: String
        let summariesVersion: Int
        let showGF: Bool
    }

    /// What the calculation reads: the dive's samples (`ProfileCacheID`), start, gases, altitude,
    /// water type and depth unit, the candidates (`buhlmannPriorFingerprint`, so an edit to an
    /// unrelated dive recalculates nothing) and the chip.
    private struct TissueKey: Equatable {
        let diveID: UUID
        let profile: ProfileCacheID
        let start: Date
        let inputsHash: Int
        let candidatesReady: Bool
        let priorsFingerprint: Int
        let showGF: Bool
    }

    private var tissueKey: TissueKey {
        var hasher = Hasher()
        for tank in dive.tanks {
            hasher.combine(tank.o2)
            hasher.combine(tank.he)
        }
        hasher.combine(dive.siteAltitude)
        hasher.combine(dive.surfacePressure)
        hasher.combine(dive.siteWaterType)
        hasher.combine(dive.importDistanceUnit)
        let ready = candidatesDiveID == dive.id
        let fingerprint = showGF && ready ? store.map { buhlmannPriorFingerprint(candidateIDs, in: $0) } ?? 0 : 0
        return TissueKey(diveID: dive.id, profile: ProfileCacheID(dive: dive), start: dive.timestamp,
                         inputsHash: hasher.finalize(), candidatesReady: ready,
                         priorsFingerprint: fingerprint, showGF: showGF)
    }

    var body: some View {
        Color.clear
            .task(id: CandidateKey(diveID: dive.id, start: dive.timestamp, diver: dive.diverName,
                                   summariesVersion: summariesVersion, showGF: showGF)) {
                let ids = showGF ? (store.map { buhlmannPriorCandidateIDs(for: dive, in: $0) } ?? []) : []
                if ids != candidateIDs { candidateIDs = ids }
                // Ready only once looked up with the chip on, so turning it on calculates once.
                candidatesDiveID = showGF ? dive.id : nil
            }
            .task(id: tissueKey) {
                await rebuild()
            }
            // Only while the chip is on: with it off, logbook changes concern no chart.
            .onChange(of: showGF ? store?.cachedSummaries : nil) { _, _ in
                summariesVersion &+= 1
            }
    }

    /// Builds the tissue profile while the chip is on, once the candidates belong to the dive;
    /// clears it while the chip is off. The inputs are read here, on the main actor; the tissue
    /// states are calculated off it, and that work stops when this task is cancelled (the
    /// dive, its data or the chip changed meanwhile).
    private func rebuild() async {
        let diveID = dive.id
        guard showGF, let inputs = buhlmannInputs(for: dive) else {
            cache.diveID = diveID
            cache.notCalculable = false
            guard cache.profile != nil || cache.maxima != nil else { return }
            cache.profile = nil
            cache.maxima = nil
            cache.version &+= 1
            return
        }
        // Wait for this dive's candidates (the candidate task runs next and changes the key).
        guard candidatesDiveID == diveID else { return }
        // Read before any await. The task is cancelled when the dive, its data or the chip change,
        // so after an await only cancellation is checked (no attribute of `dive` is read again).
        let diveStart = dive.timestamp
        guard let priors = await priorDives(), !Task.isCancelled else { return }
        let work = Task.detached(priority: .userInitiated) { () -> (BuhlmannProfile, BuhlmannZHL16C.Values?)? in
            let residual = BuhlmannZHL16C.residual(priorDives: priors, diveStart: diveStart,
                                                   surfacePressure: inputs.surfacePressure)
            guard !Task.isCancelled else { return nil }
            let profile = BuhlmannProfile(inputs: inputs, residual: residual)
            guard !Task.isCancelled else { return nil }
            var gf99 = -Double.greatestFiniteMagnitude, surface = -Double.greatestFiniteMagnitude
            var calculated = 0
            for index in profile.states.indices {
                guard let values = profile.values(atSample: index) else { continue }
                calculated += 1
                gf99 = max(gf99, values.gf99)
                surface = max(surface, values.surfaceGF)
            }
            // The first sample alone is the starting state, not a calculation of the dive.
            let maxima = calculated > 1 ? BuhlmannZHL16C.Values(gf99: gf99, surfaceGF: surface) : nil
            return (profile, maxima)
        }
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard let result, !Task.isCancelled else { return }
        // Only the starting point known: nothing of the dive was calculated, so nothing is drawn.
        let profile = result.1 != nil ? result.0 : nil
        if profile != cache.profile || cache.diveID != diveID {
            cache.profile = profile
            cache.version &+= 1
        }
        cache.maxima = result.1
        cache.notCalculable = result.1 == nil
        cache.diveID = diveID
    }

    /// The candidate earlier dives as `PriorDive`s, or nil when cancelled. The saved ones are read
    /// off the main thread (`BuhlmannPriorReader`); a dive with unsaved changes (an edit waiting
    /// for autosave), or one the reader could not read, is built here so its current values count.
    private func priorDives() async -> [BuhlmannZHL16C.PriorDive]? {
        guard let store else { return [] }
        let candidates = candidateIDs.compactMap { store.liveDive(id: $0) }
        guard !candidates.isEmpty else { return [] }
        // Their identifiers, so no attribute of a candidate is read after the await (iCloud can
        // delete one meanwhile; `liveDive(id:)` then re-checks each by identifier).
        let ids = candidates.map(\.id)
        let unsaved = Set((modelContext.insertedModelsArray + modelContext.changedModelsArray)
            .compactMap { ($0 as? Dive)?.persistentModelID })
        let toRead = candidates.map(\.persistentModelID).filter { !unsaved.contains($0) }
        let container = modelContext.container
        let reader = Task.detached(priority: .userInitiated) {
            BuhlmannPriorReader.read(container: container, ids: toRead)
        }
        let read = await withTaskCancellationHandler {
            await reader.value
        } onCancel: {
            reader.cancel()
        }
        guard let read, !Task.isCancelled else { return nil }
        var priors: [BuhlmannZHL16C.PriorDive] = []
        for id in ids {
            // Re-checked after the await: iCloud can delete a dive meanwhile.
            guard let dive = store.liveDive(id: id) else { continue }
            priors.append(read[dive.persistentModelID] ?? buhlmannPriorDive(for: dive))
        }
        return priors
    }
}
