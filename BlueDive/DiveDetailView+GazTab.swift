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
            gazInfoCard
            pressureCard
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
                Image(systemName: "cylinder.fill")
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
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)

                // Remove selected tank button (only if more than one tank)
                if dive.tanks.count > 1 {
                    Button {
                        removeSelectedTank()
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            if dive.tanks.count > 1 {
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
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal)
    }

    var gazInfoCard: some View {
        let tank = selectedTank

        let o2Pct = tank?.o2Percentage ?? 21
        let hePct = tank?.hePercentage ?? 0
        let n2Pct = max(0, 100 - o2Pct - hePct)
        let gasName = tank?.gasName ?? "Air"

        let gasTypeDisplay: String = {
            if hePct > 0 { return "Trimix \(o2Pct)/\(hePct)" }
            if o2Pct > 21 { return "Nitrox \(o2Pct)%" }
            return gasName
        }()

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
                return String(format: "%.0f \(UserPreferences.shared.pressureUnit.symbol)", converted)
            }
            return "—"
        }()

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "bubbles.and.sparkles.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                Text("Tank and Gas Blend")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                Spacer()
            }

            conditionRow(icon: "bubbles.and.sparkles.fill", color: .purple, label: "Gas Type", value: gasTypeDisplay)

            conditionRow(icon: "o.circle.fill", color: .green,  label: "Oxygen (O₂)", value: "\(o2Pct) %")
            conditionRow(icon: "h.circle.fill", color: .cyan,   label: "Helium (He)",   value: "\(hePct) %")
            conditionRow(icon: "n.circle.fill", color: .blue,   label: "Nitrogen (N₂)",    value: "\(n2Pct) %")

            conditionRow(icon: "cylinder.fill", color: .blue, label: "Tank Volume", value: volumeDisplay)

            conditionRow(icon: "cylinder.split.1x2.fill", color: .blue, label: "Double Tank", value: isDouble ? "Yes" : "No")

            conditionRow(icon: "gauge.badge.plus", color: .teal, label: "Working Pressure", value: wpDisplay)

            conditionRow(icon: "cube.fill", color: .gray, label: "Material",
                        value: (tank?.tankMaterial?.isEmpty == false ? tank!.tankMaterial! : "—"))

            conditionRow(icon: "cylinder.split.1x2.fill", color: .indigo, label: "Format",
                        value: (tank?.tankType?.isEmpty == false ? tank!.tankType! : "—"))
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal)
    }

    var pressureCard: some View {
        let tank = selectedTank
        let pressSymbol = prefs.pressureUnit.symbol

        let startDisplay: String = {
            guard let sp = tank?.startPressure else { return "—" }
            return String(format: "%.0f \(pressSymbol)", dive.displayPressure(sp))
        }()
        let endDisplay: String = {
            guard let ep = tank?.endPressure else { return "—" }
            return String(format: "%.0f \(pressSymbol)", dive.displayPressure(ep))
        }()

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.needle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
                Text("Pressure & Consumption")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                Spacer()
            }

            conditionRow(icon: "gauge.with.needle.fill", color: .red, label: "Start Pressure", value: startDisplay)
            conditionRow(icon: "gauge.with.dots.needle.bottom.50percent", color: .orange, label: "End Pressure", value: endDisplay)

            if tank?.usageStartTime != nil || tank?.usageEndTime != nil {
                let startSec = tank?.usageStartTime ?? 0
                let endSec = tank?.usageEndTime
                let startLabel = formatUsageTime(startSec)
                let endLabel = endSec.map { formatUsageTime($0) } ?? "—"
                conditionRow(icon: "play.fill", color: .cyan, label: "Usage Start", value: startLabel)
                conditionRow(icon: "stop.fill", color: .cyan, label: "Usage End", value: endLabel)
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
                conditionRow(icon: "lungs.fill", color: .pink, label: rmvLabel, value: "—")
                conditionRow(icon: "gauge.with.dots.needle.bottom.50percent", color: .mint, label: sacLabel, value: "—")
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
                conditionRow(icon: "lungs.fill", color: .pink, label: rmvLabel,
                            value: dive.formattedRMV(forTankAt: tankIdx))
                conditionRow(icon: "gauge.with.dots.needle.bottom.50percent", color: .mint, label: sacLabel,
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
        .padding()
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal)
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

            // Decompression Algorithm with GF values - always display
            VStack(alignment: .leading, spacing: 8) {
                let decoAlgo = dive.decompressionAlgorithm ?? ""
                conditionRow(icon: "function", color: .cyan, label: "Algorithm",
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
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(cnsColor(for: cns))
                            .font(.system(size: 18))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("CNS O₂ Toxicity")
                            .font(.caption)
                            .foregroundStyle(.gray)
                        HStack(spacing: 8) {
                            Text(String(format: "%.1f%%", cns))
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
                conditionRow(icon: "exclamationmark.triangle.fill", color: .yellow, label: "CNS O₂ Toxicity", value: "—")
            }

            Divider()
                .background(.primary.opacity(0.2))

            // Decompression dive indicator - always display
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill((dive.isDecompressionDive ? Color.orange : Color.green).opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: dive.isDecompressionDive ? "arrow.up.arrow.down" : "checkmark.circle.fill")
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

            if dive.isDecompressionDive && !dive.decoStops.isEmpty {
                Divider()
                    .background(.primary.opacity(0.2))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Deco Stops")
                        .font(.caption)
                        .foregroundStyle(.gray)

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
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal)
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
        selectedTankIndex = max(0, indexToRemove - 1)
    }

    // MARK: - Tank Picker Helper

    func tankPickerLabel(index: Int, tank: TankData) -> String {
        let bundle = Bundle.forAppLanguage()
        let tankLabel = NSLocalizedString("Tank", bundle: bundle, comment: "")
        let number = "\(tankLabel) \(index + 1)"
        let gas = tank.gasName
        let o2 = "\(tank.o2Percentage)%"
        return "\(number) — \(gas) \(o2)"
    }

    // MARK: - Helper Functions for Decompression

    func decoStopDepthLabel(_ depth: Double) -> String {
        let converted = dive.displayDepth(depth)
        return String(format: "%.0f %@", converted, UserPreferences.shared.depthUnit.symbol)
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
        case 0..<0.18:
            return .cyan // Hypoxic
        case 0.18..<1.4:
            return .green // Safe
        case 1.4..<1.6:
            return .orange // Caution
        default:
            return .red // Dangerous (hyperoxic)
        }
    }
}
