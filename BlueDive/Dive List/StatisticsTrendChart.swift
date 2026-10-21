import SwiftUI
import SwiftData
import Charts

// MARK: - Trend Metric

/// A metric of the 12-Month Trends chart: the per-dive values of the Statistics CSV export
/// (`StatisticsCSVRow`), in the user's display units.
nonisolated enum TrendMetric: String, CaseIterable, Identifiable, Sendable {
    case rmv, sac, maxDepth, averageDepth, duration, waterTemperature

    var id: String { rawValue }

    var unit: TrendUnit {
        switch self {
        case .maxDepth, .averageDepth: return .depth
        case .duration:                return .time
        case .waterTemperature:        return .temperature
        case .rmv:                     return .rmv
        case .sac:                     return .sac
        }
    }

    var color: Color {
        switch self {
        case .rmv:              return .teal
        case .sac:              return .mint
        case .maxDepth:         return .blue
        case .averageDepth:     return .indigo
        case .duration:         return .green
        case .waterTemperature: return .orange
        }
    }

    var icon: String {
        switch self {
        case .rmv:              return "lungs.fill"
        case .sac:              return "gauge.with.dots.needle.bottom.50percent"
        case .maxDepth:         return "arrow.down.to.line"
        case .averageDepth:     return "arrow.down"
        case .duration:         return "clock.fill"
        case .waterTemperature: return "thermometer.medium"
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .rmv:              return "RMV"
        case .sac:              return "SAC"
        case .maxDepth:         return "Max Depth"
        case .averageDepth:     return "Average Depth"
        case .duration:         return "Duration"
        case .waterTemperature: return "Water Temperature"
        }
    }

    /// The chip label used when the row has no room for `label` (existing dive-chart keys).
    var shortLabel: LocalizedStringKey? {
        switch self {
        case .averageDepth:     return "Avg. Depth"
        case .waterTemperature: return "Temp."
        case .rmv, .sac, .maxDepth, .duration: return nil
        }
    }

    /// The dive's value for this metric in the chart, nil when the dive does not have one.
    /// A non-finite value (an imported "nan" or "inf") is left out too: it would make the
    /// month's average, and the axis, unusable. The CSV still writes the stored value.
    func value(in row: StatisticsCSVRow) -> Double? {
        let value: Double?
        switch self {
        case .rmv:              value = row.rmv
        case .sac:              value = row.sac
        // A max depth or duration of 0 is a dive without that value (as average depth, RMV and
        // SAC): left out of the chart's averages. The CSV still writes the stored 0.
        case .maxDepth:         value = row.maxDepth > 0 ? row.maxDepth : nil
        case .averageDepth:     value = row.averageDepth
        case .duration:         value = row.durationMinutes > 0 ? Double(row.durationMinutes) : nil
        case .waterTemperature: value = row.waterTemperature
        }
        guard let value, value.isFinite else { return nil }
        return value
    }
}

/// The unit a metric is shown in.
nonisolated enum TrendUnit: Sendable, Hashable {
    case depth, time, temperature, rmv, sac

    /// Every value of this unit is ≥ 0, so the axis never goes below 0.
    var isNonNegative: Bool { self != .temperature }

    /// The axis always starts at 0 (depth), so a point's height is proportional to its value:
    /// 100 m reads twice as deep as 50 m even when every month is a deep dive.
    var axisStartsAtZero: Bool { self == .depth }
}

// MARK: - Monthly Values

/// One metric's average over the dives of one month that have a value for it.
nonisolated struct TrendMonthValue: Sendable, Identifiable {
    let metric: TrendMetric
    /// Index of the month in the chart's 12 months.
    let monthIndex: Int
    /// First instant of the month.
    let month: Date
    let average: Double
    /// Number of dives averaged.
    let count: Int
    /// An RMV month that includes a dive whose RMV was not calculated from bar and litres.
    let includesEstimated: Bool

    var id: String { "\(metric.rawValue)-\(monthIndex)" }
}

nonisolated enum TrendBuilder {
    /// The monthly averages of every metric over `months` (month starts, consecutive), from
    /// rows already limited to those months. Months without a value for a metric have no entry.
    static func monthlyValues(rows: [StatisticsCSVRow], months: [Date], calendar: Calendar) -> [TrendMonthValue] {
        guard let firstMonth = months.first else { return [] }
        let metrics = TrendMetric.allCases
        var sums = [TrendMetric: [Double]]()
        var counts = [TrendMetric: [Int]]()
        var estimated = [Bool](repeating: false, count: months.count)
        for metric in metrics {
            sums[metric] = [Double](repeating: 0, count: months.count)
            counts[metric] = [Int](repeating: 0, count: months.count)
        }
        for row in rows {
            guard let index = calendar.dateComponents([.month], from: firstMonth, to: row.timestamp).month,
                  months.indices.contains(index) else { continue }
            for metric in metrics {
                guard let value = metric.value(in: row) else { continue }
                sums[metric]?[index] += value
                counts[metric]?[index] += 1
                if metric == .rmv && row.rmvIsEstimated { estimated[index] = true }
            }
        }

        var result: [TrendMonthValue] = []
        for metric in metrics {
            guard let metricSums = sums[metric], let metricCounts = counts[metric] else { continue }
            for index in months.indices {
                let count = metricCounts[index]
                guard count > 0 else { continue }
                // Finite values can still add up past Double's range (absurd stored values):
                // such a month gets no point rather than an infinite one.
                let average = metricSums[index] / Double(count)
                guard average.isFinite else { continue }
                result.append(TrendMonthValue(
                    metric: metric,
                    monthIndex: index,
                    month: months[index],
                    average: average,
                    count: count,
                    includesEstimated: metric == .rmv && estimated[index]
                ))
            }
        }
        return result
    }

    /// The 12 months up to the current one (month starts in `calendar`).
    static func lastTwelveMonths(now: Date, calendar: Calendar) -> [Date] {
        guard let currentMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
              let start = calendar.date(byAdding: .month, value: -11, to: currentMonth) else { return [] }
        return (0..<12).compactMap { calendar.date(byAdding: .month, value: $0, to: start) }
    }

    /// The months (month starts in `calendar`) that overlap `interval`: 12 for a Gregorian,
    /// Buddhist or Japanese year; 12 or 13 for a lunar or lunisolar year (Islamic, Hebrew…),
    /// whose year starts mid-month.
    static func months(covering interval: DateInterval, calendar: Calendar) -> [Date] {
        guard var month = calendar.date(from: calendar.dateComponents([.year, .month], from: interval.start)) else { return [] }
        var result: [Date] = []
        while month < interval.end && result.count < 14 {
            result.append(month)
            guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { break }
            month = next
        }
        return result
    }
}

// MARK: - Axis Scale

/// A y-axis range of equal, round steps (1, 2, 2.5 or 5 × a power of ten): 4 to 6 intervals,
/// whichever covers the values most tightly (3.8–40.5 m gives 0–50 in 5 steps of 10, not
/// 0–80 in 4 steps of 20).
nonisolated struct TrendAxisScale: Sendable {
    let lower: Double
    let step: Double
    let intervals: Int

    var upper: Double { lower + step * Double(intervals) }
    var span: Double { upper - lower }
    var ticks: [Double] { (0...intervals).map { lower + step * Double($0) } }

    /// Decimals needed to show every tick exactly.
    var decimals: Int { Self.decimalsNeeded(for: step) }

    private static func decimalsNeeded(for step: Double) -> Int {
        var decimals = 0
        while decimals < 6 {
            let scaled = step * pow(10, Double(decimals))
            if abs(scaled - scaled.rounded()) < 1e-6 { break }
            decimals += 1
        }
        return decimals
    }

    init(lower: Double, step: Double, intervals: Int) {
        self.lower = lower
        self.step = step
        self.intervals = intervals
    }

    /// - Parameter maxDecimals: the metric's precision; no step is finer than it, so ticks
    ///   never need more decimals than the values (27.9–28.0 °C gets steps of 0.1, not 0.025).
    init(values: [Double], nonNegative: Bool, startsAtZero: Bool = false, maxDecimals: Int = 4) {
        let values = values.filter(\.isFinite)
        var low = values.min() ?? 0
        var high = values.max() ?? 1
        // A range beyond Double's limits (absurd stored values): a plain 0–1 scale, never an
        // infinite or NaN one, which would make the chart's domain invalid.
        guard (high - low).isFinite, (abs(high) + abs(low)).isFinite else {
            self.init(lower: 0, step: 0.25, intervals: 4)
            return
        }
        if high - low < 1e-9 {
            let pad = max(abs(low) * 0.1, 1)
            low -= pad
            high += pad
        }
        // A 5 % margin, so the highest and lowest points never sit on the plot's edge.
        let margin = (high - low) * 0.05
        low -= margin
        high += margin
        if nonNegative { low = max(low, 0) }
        if startsAtZero { low = min(low, 0) }
        // The tightest of the 4-, 5- and 6-interval scales; on a tie, the fewer intervals.
        var best = Self.roundScale(low: low, high: high, intervals: 4, maxDecimals: maxDecimals)
        for intervals in 5...6 {
            let candidate = Self.roundScale(low: low, high: high, intervals: intervals, maxDecimals: maxDecimals)
            if candidate.span < best.span - 1e-9 { best = candidate }
        }
        self = best.lower.isFinite && best.upper.isFinite && best.upper > best.lower
            ? best
            : TrendAxisScale(lower: 0, step: 0.25, intervals: 4)
    }

    /// The smallest round step that covers `low…high` in `intervals` steps, starting at a
    /// multiple of the step, and needing at most `maxDecimals` decimals.
    private static func roundScale(low: Double, high: Double, intervals: Int, maxDecimals: Int) -> TrendAxisScale {
        let raw = (high - low) / Double(intervals)
        let magnitude = max(pow(10, floor(log10(raw))), pow(10, -Double(maxDecimals)))
        for shift in 0..<3 {
            for multiplier in [1.0, 2.0, 2.5, 5.0] {
                let step = multiplier * magnitude * pow(10, Double(shift))
                // 2.5 × 10ⁿ needs one decimal more than the others: skip it past the precision.
                guard decimalsNeeded(for: step) <= maxDecimals else { continue }
                let lower = floor(low / step) * step
                if lower + step * Double(intervals) >= high - 1e-9 {
                    return TrendAxisScale(lower: lower, step: step, intervals: intervals)
                }
            }
        }
        return TrendAxisScale(lower: low, step: raw, intervals: intervals)
    }
}

// MARK: - 12-Month Trends Chart

/// Statistics → 12-Month Trends: the monthly average of one CSV metric at a time over the
/// dives Statistics shows (diver and filters applied), for the selected year or the last
/// 12 months. The chips pick the metric.
struct StatisticsTrendChart: View {
    /// The dives Statistics shows (diver and filter sheet applied).
    let dives: [Dive]
    /// The year filter, nil when none is set.
    let year: Int?
    /// "Not this year": the chart then shows the last 12 months.
    let yearNegate: Bool
    /// Changes whenever Statistics recomputes (filters, edits, iCloud changes).
    let refreshID: Int

    @State private var prefs = UserPreferences.shared
    @Environment(\.locale) private var locale
    @AppStorage("statisticsTrendMetric") private var selectedMetricRaw: String = TrendMetric.rmv.rawValue

    @State private var months: [Date] = []
    @State private var values: [TrendMonthValue] = []
    @State private var hasLoaded = false
    @State private var selectedMonthIndex: Int? = nil

    // MARK: Metric selection

    private var selectedMetric: TrendMetric { TrendMetric(rawValue: selectedMetricRaw) ?? .rmv }

    private var availableMetrics: Set<TrendMetric> { Set(values.map(\.metric)) }

    /// The selected metric's monthly values.
    private var metricValues: [TrendMonthValue] { values.filter { $0.metric == selectedMetric } }

    /// One metric at a time: turning a chip on selects it; the selected chip stays on.
    private func binding(for metric: TrendMetric) -> Binding<Bool> {
        Binding(
            get: { selectedMetric == metric },
            set: { isOn in
                guard isOn else { return }
                selectedMetricRaw = metric.rawValue
                selectedMonthIndex = nil
            }
        )
    }

    // MARK: Calendar

    /// The calendar of the months: Gregorian in local time, as the monthly averages are
    /// bucketed (`TrendBuilder`), so points, cursor and labels use the same months whatever
    /// the system calendar (Hebrew, Islamic, Persian…).
    private static var chartCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar
    }

    /// Month names in the in-app language, for the chart's Gregorian months.
    private var monthStyle: Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: Self.chartCalendar, timeZone: TimeZone.current)
    }

    /// The middle of month `index`, where its point is drawn.
    private func monthCenter(_ index: Int) -> Date? {
        guard months.indices.contains(index),
              let next = Self.chartCalendar.date(byAdding: .month, value: 1, to: months[index]) else { return nil }
        return months[index].addingTimeInterval(next.timeIntervalSince(months[index]) / 2)
    }

    // MARK: Units & formatting

    private func unitSymbol(_ unit: TrendUnit) -> String {
        switch unit {
        case .depth:       return prefs.depthUnit.symbol
        case .time:
            return NSLocalizedString("unit.time.minutes", bundle: .forAppLanguage(), value: "min", comment: "Duration unit symbol: minutes (12-Month Trends chart)")
        case .temperature: return prefs.temperatureUnit.symbol
        case .rmv:
            return prefs.pressureUnit == .psi
                ? NSLocalizedString("unit.volume.rmv.cu_ft_per_min", bundle: .forAppLanguage(), value: "cu ft/min", comment: "RMV unit: cubic feet per minute")
                : NSLocalizedString("unit.volume.rmv.l_per_min", bundle: .forAppLanguage(), value: "L/min", comment: "RMV unit: litres per minute")
        case .sac:         return prefs.pressureUnit.symbol + "/min"
        }
    }

    private func decimals(_ unit: TrendUnit) -> Int {
        switch unit {
        case .depth, .temperature: return 1
        case .time:                return 0
        case .rmv:                 return prefs.pressureUnit == .psi ? 3 : 2
        case .sac:                 return 2
        }
    }

    /// `value` formatted with exactly `decimals` decimals; when the result has no non-zero
    /// digit (any digit system), 0 is formatted instead, so a label never reads "−0" or "−0,0"
    /// (a month averaging −0.03 °C) whatever the formatter's rounding. A value still negative
    /// once formatted (−1,9) keeps its sign.
    private func localizedNumber(_ value: Double, decimals: Int) -> String {
        let text = value.localizedString(decimals: decimals, minDecimals: decimals)
        guard !text.contains(where: { ($0.wholeNumberValue ?? 0) != 0 }) else { return text }
        return Double(0).localizedString(decimals: decimals, minDecimals: decimals)
    }

    private func formatted(_ value: Double, unit: TrendUnit) -> String {
        let number = localizedNumber(value, decimals: decimals(unit))
        return unit == .temperature ? number + unitSymbol(unit) : number + " " + unitSymbol(unit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if !hasLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
            } else if values.isEmpty {
                Text("No dives in this period.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
            } else {
                metricChips

                let metricValues = metricValues
                if metricValues.isEmpty {
                    Text("No values for this metric in this period.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                } else {
                    chart(metricValues, scale: TrendAxisScale(values: metricValues.map(\.average), nonNegative: selectedMetric.unit.isNonNegative, startsAtZero: selectedMetric.unit.axisStartsAtZero, maxDecimals: decimals(selectedMetric.unit)))

                    if selectedMetric == .rmv && metricValues.contains(where: \.includesEstimated) {
                        EstimatedRMVFootnote()
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.platformSecondaryBackground)
        )
        .padding(.horizontal)
        .task(id: taskKey) {
            await load()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "chart.xyaxis.line")
                    .foregroundStyle(.cyan)
                    .accessibilityHidden(true)
                Text("12-Month Trends")
                    .font(.headline)
                Spacer()
                if let first = months.first, let last = months.last {
                    HStack(spacing: 0) {
                        Text(first, format: monthStyle.month(.abbreviated).year())
                        Text(verbatim: " – ")
                        Text(last, format: monthStyle.month(.abbreviated).year())
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            // Every point is a monthly average of the dives that have the value (a Max Depth
            // point is the average of the dives' maximum depths, not the month's deepest dive).
            Text("Monthly average of each dive's value")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    /// Laid out as the chips above a dive's profile: two centred rows of three (gas, then
    /// depth and temperature); on macOS one row when the card is wide enough for every chip
    /// at its full label.
    private var metricChips: some View {
        VStack(spacing: 12) {
            #if os(macOS)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    chips(Self.firstChipRow)
                    chips(Self.secondChipRow)
                }
                VStack(spacing: 12) {
                    HStack(spacing: 12) { chips(Self.firstChipRow) }
                    HStack(spacing: 12) { chips(Self.secondChipRow) }
                }
            }
            #else
            HStack(spacing: 12) { chips(Self.firstChipRow) }
            HStack(spacing: 12) { chips(Self.secondChipRow) }
            #endif
        }
        .frame(maxWidth: .infinity)
    }

    private static let firstChipRow: [TrendMetric] = [.rmv, .sac, .duration]
    private static let secondChipRow: [TrendMetric] = [.maxDepth, .averageDepth, .waterTemperature]

    private func chips(_ metrics: [TrendMetric]) -> some View {
        let available = availableMetrics
        return ForEach(metrics) { metric in
            ToggleButton(
                isOn: binding(for: metric),
                icon: metric.icon,
                label: metric.label,
                shortLabel: metric.shortLabel,
                color: metric.color,
                textColor: textColor(for: metric),
                isAvailable: available.contains(metric)
            )
            .accessibilityAddTraits(selectedMetric == metric ? .isSelected : [])
        }
    }

    /// The chip label colour: the metric's colour in dark mode, a deeper shade in light mode
    /// so it stays readable on the chip's light tint (as the dive chart's chips).
    private func textColor(for metric: TrendMetric) -> Color {
        switch metric {
        case .rmv:              return Color.readableOnTint(darkMode: .teal, lightMode: (red: 0.0, green: 0.40, blue: 0.42))
        case .sac:              return Color.readableOnTint(darkMode: .mint, lightMode: (red: 0.0, green: 0.42, blue: 0.36))
        case .maxDepth:         return Color.readableOnTint(darkMode: .blue, lightMode: (red: 0.0, green: 0.30, blue: 0.70))
        case .averageDepth:     return Color.readableIndigo
        case .duration:         return Color.readableGreen
        case .waterTemperature: return Color.readableOrange
        }
    }

    private func chart(_ metricValues: [TrendMonthValue], scale: TrendAxisScale) -> some View {
        let metric = selectedMetric
        let monthEnd = months.last.flatMap { Self.chartCalendar.date(byAdding: .month, value: 1, to: $0) }
        let monthCenters = months.indices.compactMap { monthCenter($0) }

        return VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: unitSymbol(metric.unit))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(metric.color)

            Chart {
                ForEach(metricValues) { value in
                    // Points only: a month without data simply has no point. Placed at the
                    // month's centre (not `unit: .month`, which bins by the system calendar).
                    PointMark(
                        x: .value("Month", monthCenter(value.monthIndex) ?? value.month),
                        y: .value("Value", value.average)
                    )
                    .foregroundStyle(metric.color)
                    .symbolSize(60)
                    .accessibilityLabel(Text(value.month, format: monthStyle.month(.wide).year()))
                    .accessibilityValue(Text(verbatim: formatted(value.average, unit: metric.unit)))
                }
            }
            .chartYScale(domain: scale.lower...scale.upper)
            .chartXScale(domain: (months.first ?? Date())...(monthEnd ?? Date()))
            .chartYAxis {
                AxisMarks(position: .leading, values: scale.ticks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                        .foregroundStyle(Color.primary.opacity(0.1))
                    AxisValueLabel {
                        if let y = value.as(Double.self) {
                            Text(verbatim: localizedNumber(y, decimals: scale.decimals))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: monthCenters) { _ in
                    // Centred under the month's point (the ticks are at month centres).
                    AxisValueLabel(format: monthStyle.month(.abbreviated), anchor: .top)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .chartPlotStyle { plotArea in
                plotArea
                    .background(Color.primary.opacity(0.02))
                    .cornerRadius(8)
            }
            // As the dive profile: a cursor line and a dark tooltip card at the top of the plot,
            // following the finger (or the pointer on Mac) and snapped to the month under it.
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let plotAnchor = proxy.plotFrame {
                        let frame = geometry[plotAnchor]
                        ZStack(alignment: .topLeading) {
                            if let index = selectedMonthIndex, let x = monthCenterX(index, proxy: proxy) {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.5))
                                    .frame(width: 1.5, height: frame.height)
                                    .offset(x: frame.minX + x, y: frame.minY)
                            }

                            // Touch zone — the plot area only (local coordinates = plot coordinates).
                            Rectangle()
                                .fill(Color.clear)
                                .contentShape(Rectangle())
                                .frame(width: frame.width, height: frame.height)
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { drag in
                                            selectedMonthIndex = monthIndex(atPlotX: drag.location.x, plotWidth: frame.width, proxy: proxy)
                                        }
                                        .onEnded { _ in
                                            withAnimation(.easeOut(duration: 0.2)) {
                                                selectedMonthIndex = nil
                                            }
                                        }
                                )
                                #if os(macOS)
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        selectedMonthIndex = monthIndex(atPlotX: location.x, plotWidth: frame.width, proxy: proxy)
                                    case .ended:
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            selectedMonthIndex = nil
                                        }
                                    }
                                }
                                #endif
                                .offset(x: frame.minX, y: frame.minY)

                            if let index = selectedMonthIndex, let x = monthCenterX(index, proxy: proxy) {
                                tooltip(monthIndex: index, metricValues: metricValues)
                                    .offset(
                                        x: tooltipOffsetX(screenX: frame.minX + x, plotOriginX: frame.minX, plotWidth: frame.width),
                                        y: frame.minY + 8
                                    )
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
            }
            #if os(macOS)
            // The Mac sheet is tall: grow the chart with the sheet's visible height (35 %),
            // never below the iOS height or above 380 pt — as Recent Activity.
            .containerRelativeFrame(.vertical) { height, _ in
                min(max(height * 0.35, 220), 380)
            }
            #else
            .frame(height: 220)
            #endif
        }
    }

    /// The month under `x` (plot coordinates, clamped to the plot), nil when outside the months.
    private func monthIndex(atPlotX x: CGFloat, plotWidth: CGFloat, proxy: ChartProxy) -> Int? {
        let clampedX = min(max(x, 0), plotWidth)
        guard let date: Date = proxy.value(atX: clampedX), let firstMonth = months.first else { return nil }
        guard let index = Self.chartCalendar.dateComponents([.month], from: firstMonth, to: date).month else { return nil }
        return min(max(index, 0), months.count - 1)
    }

    /// The x of a month's centre (plot coordinates), where its point is drawn.
    private func monthCenterX(_ index: Int, proxy: ChartProxy) -> CGFloat? {
        monthCenter(index).flatMap { proxy.position(forX: $0) }
    }

    private static let tooltipWidth: CGFloat = 200

    /// Keeps the tooltip card within the plot area horizontally (as the dive profile).
    private func tooltipOffsetX(screenX: CGFloat, plotOriginX: CGFloat, plotWidth: CGFloat) -> CGFloat {
        let padding: CGFloat = 8
        let x = screenX - Self.tooltipWidth / 2
        let minX = plotOriginX + padding
        let maxX = max(minX, plotOriginX + plotWidth - Self.tooltipWidth - padding)
        return min(max(x, minX), maxX)
    }

    /// The dive profile's tooltip card: month header, then the value and the number of dives.
    private func tooltip(monthIndex: Int, metricValues: [TrendMonthValue]) -> some View {
        let metric = selectedMetric
        let entry = metricValues.first { $0.monthIndex == monthIndex }
        return VStack(alignment: .leading, spacing: 5) {
            Text(months[monthIndex], format: monthStyle.month(.wide).year())
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.bold)
                .foregroundStyle(.white.opacity(0.6))

            Divider().background(Color.white.opacity(0.25))

            if let entry {
                TooltipRow(
                    icon: metric.icon,
                    color: metric.color,
                    label: formatted(entry.average, unit: metric.unit) + (entry.includesEstimated ? " *" : "")
                )
                TooltipRow(
                    icon: "number",
                    color: .secondary,
                    label: String.localizedStringWithFormat(
                        NSLocalizedString("%lld dives", bundle: Bundle.forAppLanguage(), value: "%lld dives", comment: "Number of dives"),
                        entry.count
                    )
                )
            } else {
                Text("No dives in this month.")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: Self.tooltipWidth, alignment: .leading)
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

    // MARK: Loading

    private var taskKey: String {
        "\(refreshID)|\(year ?? -1)|\(yearNegate)|\(prefs.depthUnit.rawValue)|\(prefs.temperatureUnit.rawValue)|\(prefs.pressureUnit.rawValue)"
    }

    /// Reads the values of the dives in the 12 months on the MainActor (yielding every 100
    /// dives), then builds the monthly averages off it.
    private func load() async {
        let calendar = Self.chartCalendar
        let chartMonths: [Date]
        if year != nil && !yearNegate {
            // The year filter compares years in the system calendar (`DiverFilter`), which may
            // not be Gregorian (Buddhist 2569, Japanese Reiwa 8…): take that year's span from
            // the selected dives in the same calendar, then the Gregorian months it covers.
            let latest = dives.lazy
                .filter { !$0.isDeleted && $0.modelContext != nil }
                .map(\.timestamp)
                .max()
            guard let latest, let yearInterval = Calendar.current.dateInterval(of: .year, for: latest) else {
                months = []
                values = []
                hasLoaded = true
                return
            }
            chartMonths = TrendBuilder.months(covering: yearInterval, calendar: calendar)
        } else {
            chartMonths = TrendBuilder.lastTwelveMonths(now: Date(), calendar: calendar)
        }
        guard let start = chartMonths.first,
              let end = chartMonths.last.flatMap({ calendar.date(byAdding: .month, value: 1, to: $0) }) else {
            // No months (the calendar returned none): the empty state, never an endless spinner.
            months = []
            values = []
            hasLoaded = true
            return
        }
        let pressureUnit = prefs.pressureUnit
        let inPeriod = dives.filter { !$0.isDeleted && $0.modelContext != nil && $0.timestamp >= start && $0.timestamp < end }

        var rows: [StatisticsCSVRow] = []
        rows.reserveCapacity(inPeriod.count)
        for (index, dive) in inPeriod.enumerated() {
            if index % 100 == 99 {
                await Task.yield()
                if Task.isCancelled { return }
            }
            // Re-checked after every yield: iCloud can delete a dive meanwhile.
            guard !dive.isDeleted, dive.modelContext != nil else { continue }
            rows.append(StatisticsCSVRow.read(from: dive, pressureUnit: pressureUnit))
        }
        let builtRows = rows
        let built = await Task.detached(priority: .userInitiated) {
            TrendBuilder.monthlyValues(rows: builtRows, months: chartMonths, calendar: calendar)
        }.value
        if Task.isCancelled { return }
        months = chartMonths
        values = built
        selectedMonthIndex = nil
        hasLoaded = true
    }
}
