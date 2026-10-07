import SwiftUI

// MARK: - Gaz Tab

extension DiveDetailView {

    /// The currently selected tank, safely clamped to the valid range.
    private var selectedTank: TankData? {
        let tanks = dive.tanks
        guard !tanks.isEmpty else { return nil }
        let index = min(selectedTankIndex, tanks.count - 1)
        return tanks[index]
    }

    var gazTabContent: some View {
        VStack(spacing: 20) {
            tankSelectorCard
            #if os(macOS)
            // The Mac window is wide enough to show the tank and the pressure cards side
            // by side; fixedSize gives both the height of the taller one.
            HStack(alignment: .top, spacing: 0) {
                gazInfoCard
                    .frame(maxWidth: .infinity)
                pressureCard
                    .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            #else
            gazInfoCard
            pressureCard
            #endif
            decompressionCard
        }
        .onChange(of: dive.tanks.count) {
            // Reset selection if tanks changed and index is out of bounds
            if selectedTankIndex >= dive.tanks.count {
                selectedTankIndex = max(0, dive.tanks.count - 1)
            }
        }
    }

    var tankSelectorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "cylinder")
                    .font(.title3)
                    .foregroundStyle(.blue)
                Text("Tanks")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                Spacer()

                if dive.tanks.count > 1 {
                    Text(verbatim: "\(min(selectedTankIndex, dive.tanks.count - 1) + 1) / \(dive.tanks.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Add tank button
                Button {
                    addNewTank()
                } label: {
                    // Header HStack spacing is 8 pt, so this grows only 4 pt (half the gap)
                    // toward the adjacent Remove button and 12 pt leading into the empty
                    // Spacer/counter area. Vertically: 16 pt of card padding above, 12 pt
                    // to the tank Picker below. 40 × 44 pt.
                    TapTargetInset(top: 10, leading: 12, bottom: 10, trailing: 4) {
                        Image(systemName: "plus.circle")
                            .font(.title3)
                            .foregroundStyle(.green)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Add Tank"))

                // Remove selected tank button (only if more than one tank)
                if dive.tanks.count > 1 {
                    Button {
                        removeSelectedTank()
                    } label: {
                        // Mirror of the Add button: 4 pt toward it (half the 8 pt gap),
                        // 12 pt trailing into the card's 16 pt padding. 40 × 44 pt.
                        TapTargetInset(top: 10, leading: 4, bottom: 10, trailing: 12) {
                            Image(systemName: "minus.circle")
                                .font(.title3)
                                .foregroundStyle(.red)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Remove Tank"))
                }
            }

            Picker(selection: $selectedTankIndex) {
                ForEach(Array(dive.tanks.enumerated()), id: \.element.id) { index, tank in
                    Text(verbatim: tankPickerLabel(index: index, tank: tank))
                        .tag(index)
                }
            } label: {
                Text("Tank")
            }
            .pickerStyle(.menu)
        }
        .padding()
        .detailCardBackground()
        .padding(.horizontal)
    }

    var gazInfoCard: some View {
        let tank = selectedTank

        let o2Pct = tank?.o2Percentage ?? 21
        let hePct = tank?.hePercentage ?? 0
        let n2Pct = max(0, 100 - o2Pct - hePct)

        let gasTypeDisplay: String = tank?.gasDisplayName() ?? NSLocalizedString("Air", bundle: .forAppLanguage(), comment: "Air gas type label")

        let volumeDisplay: String = {
            guard let vol = tank?.volume else { return "—" }
            return dive.formattedVolume(vol, workingPressureRaw: tank?.workingPressure)
        }()

        let isDouble: Bool = {
            guard let tt = tank?.tankType?.lowercased() else { return false }
            return tt.contains("double") || tt.contains("twin")
        }()

        let wpDisplay: String = {
            if let wpRaw = tank?.workingPressure {
                let converted = dive.displayPressure(wpRaw)
                return converted.localizedString(decimals: 0) + " \(UserPreferences.shared.pressureUnit.symbol)"
            }
            return "—"
        }()

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "bubbles.and.sparkles")
                    .font(.title3)
                    .foregroundStyle(.green)
                Text("Tank and Gas Blend")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                Spacer()
            }

            ConditionRow(icon: "bubbles.and.sparkles", color: .purple, label: "Gas Type", value: gasTypeDisplay)

            ConditionRow(icon: "o.circle", color: .green,  label: "Oxygen (O₂)", value: "\(o2Pct) %")
            ConditionRow(icon: "h.circle", color: .cyan,   label: "Helium (He)",   value: "\(hePct) %")
            ConditionRow(icon: "n.circle", color: .blue,   label: "Nitrogen (N₂)",    value: "\(n2Pct) %")

            ConditionRow(icon: "cylinder", color: .blue, label: "Tank Volume", value: volumeDisplay)

            ConditionRow(icon: "cylinder.split.1x2", color: .blue, label: "Double Tank",
                        value: isDouble
                            ? NSLocalizedString("Yes", bundle: .forAppLanguage(), comment: "")
                            : NSLocalizedString("No", bundle: .forAppLanguage(), comment: ""))

            ConditionRow(icon: "gauge.badge.plus", color: .teal, label: "Working Pressure", value: wpDisplay)

            ConditionRow(icon: "cube", color: .gray, label: "Material",
                        value: tank?.tankMaterial.flatMap { $0.isEmpty ? nil : localizedTankMaterial($0) } ?? "—")

            ConditionRow(icon: "cylinder.split.1x2", color: .indigo, label: "Format",
                        value: tank?.tankType.flatMap { $0.isEmpty ? nil : localizedTankFormat($0) } ?? "—")
        }
        .fillsAvailableHeightOnMac()
        .padding()
        .detailCardBackground()
        .sideBySideCardPadding(.leading)
    }

    var pressureCard: some View {
        let tank = selectedTank
        let pressSymbol = prefs.pressureUnit.symbol

        let startDisplay: String = {
            guard let sp = tank?.startPressure else { return "—" }
            return dive.displayPressure(sp).localizedString(decimals: 0) + " \(pressSymbol)"
        }()
        let endDisplay: String = {
            guard let ep = tank?.endPressure else { return "—" }
            return dive.displayPressure(ep).localizedString(decimals: 0) + " \(pressSymbol)"
        }()

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.needle")
                    .font(.title3)
                    .foregroundStyle(.red)
                Text("Pressure & Consumption")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                Spacer()
            }

            ConditionRow(icon: "gauge.with.needle", color: .red, label: "Start Pressure", value: startDisplay)
            ConditionRow(icon: "gauge.with.dots.needle.bottom.50percent", color: .orange, label: "End Pressure", value: endDisplay)

            if tank?.usageStartTime != nil || tank?.usageEndTime != nil {
                let startSec = tank?.usageStartTime ?? 0
                let endSec = tank?.usageEndTime
                let startLabel = formatUsageTime(startSec)
                let endLabel = endSec.map { formatUsageTime($0) } ?? "—"
                ConditionRow(icon: "play", color: .cyan, label: "Usage Start", value: startLabel)
                ConditionRow(icon: "stop", color: .cyan, label: "Usage End", value: endLabel)
            }

            let tankIdx = dive.tanks.isEmpty ? -1 : min(selectedTankIndex, dive.tanks.count - 1)
            let selectedTankTypeLC = tank?.tankType?.lowercased() ?? ""
            let selectedTankIsDouble = selectedTankTypeLC.contains("twin") || selectedTankTypeLC.contains("double")
            let rmvLabel: LocalizedStringKey = selectedTankIsDouble ? "RMV (double tank)" : "RMV"
            let sacLabel: LocalizedStringKey = selectedTankIsDouble ? "SAC (double tank)" : "SAC"

            let isSidemount = selectedTankTypeLC.contains("sidemount")
            let validTankCount = dive.tanks.filter { ($0.volume ?? 0) > 0 && $0.startPressure != nil && $0.endPressure != nil }.count
            let multiTankMissingUsageTime = validTankCount > 1 && (tank?.usageStartTime == nil || tank?.usageEndTime == nil) && !isSidemount
            let multiTankNoSamples = dive.profileSamples.count < 2 && validTankCount > 1

            if multiTankNoSamples || multiTankMissingUsageTime {
                ConditionRow(icon: "lungs", color: .pink, label: rmvLabel, value: "—")
                ConditionRow(icon: "gauge.with.dots.needle.bottom.50percent", color: .mint, label: sacLabel, value: "—")
                if multiTankNoSamples {
                    Text("Multi-tank RMV/SAC requires dive computer data")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                } else {
                    Text("Usage time required for per-tank RMV/SAC")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            } else {
                ConditionRow(icon: "lungs", color: .pink, label: rmvLabel,
                            value: dive.formattedRMV(forTankAt: tankIdx))
                ConditionRow(icon: "gauge.with.dots.needle.bottom.50percent", color: .mint, label: sacLabel,
                            value: dive.formattedSAC(forTankAt: tankIdx))
            }

            // Footnote when RMV was computed from non-metric units
            if let note = dive.rmvFootnote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .fillsAvailableHeightOnMac()
        .padding()
        .detailCardBackground()
        .sideBySideCardPadding(.trailing)
    }

    var decompressionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.title3)
                    .foregroundStyle(.cyan)
                Text("Decompression & Algorithm")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                Spacer()
            }

            #if os(macOS)
            // The Mac window is wide enough to put the deco stops in their own column
            // beside the algorithm, CNS and dive type; without stops the card keeps a
            // single full-width column.
            if showsDecoStops {
                HStack(alignment: .top, spacing: 48) {
                    VStack(alignment: .leading, spacing: 16) {
                        decoSummaryRows
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    decoStopsList
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay {
                    Rectangle()
                        .fill(Color.primary.opacity(0.2))
                        .frame(width: 1)
                }
            } else {
                decoSummaryRows
            }
            #else
            decoSummaryRows

            if showsDecoStops {
                Divider()
                    .background(.primary.opacity(0.2))

                decoStopsList
            }
            #endif
        }
        .padding()
        .detailCardBackground()
        .padding(.horizontal)
    }

    /// Deco stops are listed only for a deco dive that has stops recorded.
    private var showsDecoStops: Bool {
        dive.isDecompressionDive && !dive.decoStops.isEmpty
    }

    /// Algorithm (with GF values), CNS O₂ toxicity and dive type, separated by dividers.
    @ViewBuilder
    private var decoSummaryRows: some View {
        // Decompression Algorithm with GF values - always display
        VStack(alignment: .leading, spacing: 8) {
            let decoAlgo = dive.decompressionAlgorithm ?? ""
            ConditionRow(icon: "function", color: .cyan, label: "Algorithm",
                        value: !decoAlgo.isEmpty ? decoAlgo : "—")

            // Try to extract GF Low/High from algorithm string
            if let gfValues = extractGFValues(from: decoAlgo) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GF Low")
                            .font(.caption)
                            .foregroundStyle(.gray)
                        Text((Double(gfValues.low) / 100).formatted(.percent.precision(.fractionLength(0))))
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(.cyan)
                    }

                    Divider()
                        .frame(height: 30)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("GF High")
                            .font(.caption)
                            .foregroundStyle(.gray)
                        Text((Double(gfValues.high) / 100).formatted(.percent.precision(.fractionLength(0))))
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(0.05))
                )
            }
        }

        Divider()
            .background(.primary.opacity(0.2))

        // CNS % - always display
        if let cns = dive.cnsPercentage {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(cnsColor(for: cns).opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(cnsColor(for: cns))
                        .font(.system(size: 18))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("CNS O₂ Toxicity")
                        .font(.caption)
                        .foregroundStyle(.gray)
                    HStack(spacing: 8) {
                        Text(verbatim: cns.localizedString(decimals: 1) + "%")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundStyle(cnsColor(for: cns))

                        // Status indicator
                        Text(cnsStatus(for: cns))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(cnsColor(for: cns).opacity(0.3))
                            )
                    }

                    // Progress bar — clamped to 0–100 %
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.1))
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(cnsColor(for: cns))
                                .frame(
                                    width: geo.size.width * min(cns / 100.0, 1.0),
                                    height: 6
                                )
                        }
                    }
                    .frame(height: 6)
                }

                Spacer()
            }
        } else {
            ConditionRow(icon: "exclamationmark.triangle", color: .yellow, label: "CNS O₂ Toxicity", value: "—")
        }

        Divider()
            .background(.primary.opacity(0.2))

        // Decompression dive indicator - always display
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill((dive.isDecompressionDive ? Color.orange : Color.green).opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: dive.isDecompressionDive ? "arrow.up.arrow.down" : "checkmark.circle")
                    .foregroundStyle(dive.isDecompressionDive ? .orange : .green)
                    .font(.system(size: 18))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Dive Type")
                    .font(.caption)
                    .foregroundStyle(.gray)
                Text(dive.isDecompressionDive ? "With mandatory deco stops" : "No-deco (NDL)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(dive.isDecompressionDive ? .orange : .green)
            }

            Spacer()
        }
    }

    private var decoStopsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Deco Stops")
                .font(.caption)
                .foregroundStyle(.gray)

            // A table writes the Depth / Duration / Type headers once instead of on every
            // stop. When it does not fit on one line per stop (narrow iPhone with a large
            // Dynamic Type size), fall back to one labelled row per stop.
            ViewThatFits(in: .horizontal) {
                decoStopsTable
                decoStopsRows
            }
        }
    }

    /// Deco stops as a table: icon, Depth, Duration and Type columns under one header row.
    private var decoStopsTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                Color.clear
                    .gridCellUnsizedAxes([.horizontal, .vertical])
                Text("Depth")
                Text("Duration")
                Text("Type")
            }
            .font(.caption2)
            .foregroundStyle(.gray)
            // Each stop below is read as one labelled element, so the headers are skipped.
            .accessibilityHidden(true)

            Divider()
                .background(.primary.opacity(0.2))

            ForEach(dive.decoStops) { stop in
                GridRow {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: "arrow.down.to.line")
                            .foregroundStyle(.orange)
                            .font(.system(size: 15))
                    }
                    // A GridRow cannot combine its cells into one accessibility element,
                    // so the icon cell carries the whole stop ("Depth 6 m, duration
                    // 3m 00s, Mandatory") and the value cells are hidden from VoiceOver.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: String(
                        format: NSLocalizedString("Depth %1$@, duration %2$@, %3$@", bundle: Bundle.forAppLanguage(), value: "Depth %1$@, duration %2$@, %3$@", comment: "VoiceOver label for one deco stop in the deco stops table: %1$@ = depth with unit, %2$@ = stop duration, %3$@ = stop type (e.g. Mandatory)"),
                        decoStopDepthLabel(stop.depth), decoStopTimeLabel(stop.time), decoStopTypeLabel(stop.type)
                    )))

                    Text(decoStopDepthLabel(stop.depth))
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                    Text(decoStopTimeLabel(stop.time))
                        .foregroundStyle(.primary)
                        .accessibilityHidden(true)
                    Text(verbatim: decoStopTypeLabel(stop.type))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                .font(.subheadline)
                .fontWeight(.semibold)
            }
        }
    }

    /// Deco stops as one labelled row per stop — the fallback when the table does not fit.
    private var decoStopsRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(dive.decoStops) { stop in
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: "arrow.down.to.line")
                            .foregroundStyle(.orange)
                            .font(.system(size: 15))
                    }

                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Depth")
                                .font(.caption2)
                                .foregroundStyle(.gray)
                            Text(decoStopDepthLabel(stop.depth))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                        }

                        Divider().frame(height: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Duration")
                                .font(.caption2)
                                .foregroundStyle(.gray)
                            Text(decoStopTimeLabel(stop.time))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                        }

                        Divider().frame(height: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Type")
                                .font(.caption2)
                                .foregroundStyle(.gray)
                            Text(verbatim: decoStopTypeLabel(stop.type))
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.orange)
                        }
                    }

                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Usage Time Formatting

    /// Formats seconds into a readable string (e.g. "5m 30s" or "0m 00s").
    private func formatUsageTime(_ seconds: Double) -> String {
        let totalSec = Int(seconds.rounded())
        let m = totalSec / 60
        let s = totalSec % 60
        let bundle = Bundle.forAppLanguage()
        let mAbbr = NSLocalizedString("usage_time_minutes_abbrev", bundle: bundle, comment: "Abbreviation for minutes in usage time display (e.g. '5m')")
        let sAbbr = NSLocalizedString("usage_time_seconds_abbrev", bundle: bundle, comment: "Abbreviation for seconds in usage time display (e.g. '30s')")
        return "\(m)\(mAbbr) \(String(format: "%02d", s))\(sAbbr)"
    }

    // MARK: - Tank Management

    func addNewTank() {
        var tanks = dive.tanks
        tanks.append(TankData())
        dive.tanks = tanks
        // Gas column of the dive list (kept even if the tank editor is then cancelled).
        store.commit(dive, affects: .rowFields)
        selectedTankIndex = tanks.count - 1
        // Open edit sheet for the new tank
        showEditSheet = true
    }

    func removeSelectedTank() {
        var tanks = dive.tanks
        guard tanks.count > 1 else { return }
        let indexToRemove = min(selectedTankIndex, tanks.count - 1)
        tanks.remove(at: indexToRemove)
        dive.tanks = tanks
        store.commit(dive, affects: .rowFields)
        selectedTankIndex = max(0, indexToRemove - 1)
    }

    // MARK: - Tank Picker Helper

    func tankPickerLabel(index: Int, tank: TankData) -> String {
        let tankLabel = NSLocalizedString("Tank", bundle: Bundle.forAppLanguage(), comment: "")
        return "\(tankLabel) \(index + 1) — \(tank.gasDisplayName())"
    }

    // MARK: - Helper Functions for Decompression

    func decoStopDepthLabel(_ depth: Double) -> String {
        // DecoStop.depth is always metres (see Dive.swift), whatever the dive's
        // importDistanceUnit — the chart and PDF read it the same way.
        let converted = UserPreferences.shared.depthUnit.convert(depth)
        return converted.localizedString(decimals: 0) + " \(UserPreferences.shared.depthUnit.symbol)"
    }

    func decoStopTimeLabel(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        if m > 0 { return s > 0 ? "\(m) min \(s) s" : "\(m) min" }
        return "\(s) s"
    }

    func decoStopTypeLabel(_ type: Int) -> String {
        let bundle = Bundle.forAppLanguage()
        switch type {
        case 1: return NSLocalizedString("Safety Stop", bundle: bundle, comment: "Deco stop type: safety stop")
        case 2: return NSLocalizedString("Deco Stop", bundle: bundle, comment: "Deco stop type: mandatory decompression stop")
        case 3: return NSLocalizedString("Deep Stop", bundle: bundle, comment: "Deco stop type: deep stop")
        default: return NSLocalizedString("NDL", bundle: bundle, comment: "Deco stop type: no-decompression limit")
        }
    }

    func extractGFValues(from algorithm: String) -> (low: Int, high: Int)? {
        // Try to extract GF values from strings like "ZHL-16C GF 40/85" or "GF 30/70"
        let pattern = #"GF\s*(\d+)/(\d+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let nsString = algorithm as NSString
            let results = regex.matches(in: algorithm, range: NSRange(location: 0, length: nsString.length))

            if let match = results.first, match.numberOfRanges == 3 {
                let lowString = nsString.substring(with: match.range(at: 1))
                let highString = nsString.substring(with: match.range(at: 2))
                if let low = Int(lowString), let high = Int(highString) {
                    return (low, high)
                }
            }
        }
        return nil
    }

    func cnsColor(for cns: Double) -> Color {
        switch cns {
        case 0..<50:
            return .green
        case 50..<75:
            return .yellow
        case 75..<100:
            return .orange
        default:
            return .red
        }
    }

    func cnsStatus(for cns: Double) -> LocalizedStringKey {
        switch cns {
        case 0..<50:
            return "Safe"
        case 50..<75:
            return "Moderate"
        case 75..<100:
            return "High"
        default:
            return "Critical"
        }
    }

    /// Color code for PPO2 values based on safety ranges
    func ppo2Color(for ppo2: Double) -> Color {
        switch ppo2 {
        case 0..<DiveProfileEvent.ppo2HypoxicThreshold:
            return .cyan // Hypoxic
        case DiveProfileEvent.ppo2HypoxicThreshold..<DiveProfileEvent.ppo2WarnThreshold:
            return .green // Safe
        case DiveProfileEvent.ppo2WarnThreshold..<DiveProfileEvent.ppo2DangerThreshold:
            return .orange // Caution
        default:
            return .red // Dangerous (hyperoxic)
        }
    }
}
