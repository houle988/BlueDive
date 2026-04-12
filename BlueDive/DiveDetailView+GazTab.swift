import SwiftUI

// MARK: - Gaz Tab

extension DiveDetailView {

    var gazTabContent: some View {
        VStack(spacing: 20) {
            gazInfoCard
            pressureCard
            decompressionCard
        }
    }

    var gazInfoCard: some View {
        VStack(alignment: .leading, spacing: 16) {
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

            conditionRow(icon: "bubbles.and.sparkles.fill", color: .purple, label: "Gas Type", value: dive.formattedGasType)

            // Oxygen / Helium / Nitrogen percentages
            let heliumPct   = dive.heliumPercentage ?? 0
            let nitrogenPct = max(0, 100 - dive.oxygenPercentage - heliumPct)

            conditionRow(icon: "o.circle.fill", color: .green,  label: "Oxygen (O₂)", value: "\(dive.oxygenPercentage) %")
            conditionRow(icon: "h.circle.fill", color: .cyan,   label: "Helium (He)",   value: "\(heliumPct) %")
            conditionRow(icon: "n.circle.fill", color: .blue,   label: "Nitrogen (N₂)",    value: "\(nitrogenPct) %")

            conditionRow(icon: "cylinder.fill", color: .blue, label: "Tank Volume", value: dive.formattedCylinderSize ?? "—")

            conditionRow(icon: "cylinder.split.1x2.fill", color: .blue, label: "Double Tank", value: dive.isDoubleTank ? "Yes" : "No")

            // Working pressure — shown in the user's preferred pressure unit
            let wpDisplay: String = {
                if let wpRaw = dive.tanks.first?.workingPressure {
                    let converted = dive.displayPressure(wpRaw)
                    return String(format: "%.0f \(UserPreferences.shared.pressureUnit.symbol)", converted)
                }
                return "—"
            }()
            conditionRow(icon: "gauge.badge.plus", color: .teal, label: "Working Pressure", value: wpDisplay)

            // Always display Material field
            conditionRow(icon: "cube.fill", color: .gray, label: "Material",
                        value: (dive.tanks.first?.tankMaterial?.isEmpty == false ? dive.tanks.first!.tankMaterial! : "—"))

            // Always display Format field
            conditionRow(icon: "cylinder.split.1x2.fill", color: .indigo, label: "Format",
                        value: (dive.tanks.first?.tankType?.isEmpty == false ? dive.tanks.first!.tankType! : "—"))
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal)
    }

    var pressureCard: some View {
        let pressUnit   = prefs.pressureUnit
        let pressSymbol = pressUnit.symbol

        let startDisplay: String = {
            guard let sp = dive.displayStartPressure else { return "—" }
            return String(format: "%.0f \(pressSymbol)", sp)
        }()
        let endDisplay: String = {
            guard let ep = dive.displayEndPressure else { return "—" }
            return String(format: "%.0f \(pressSymbol)", ep)
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

            let rmvLabel: LocalizedStringKey = dive.isDoubleTank ? "RMV (double tank)" : "RMV"
            let sacLabel: LocalizedStringKey = dive.isDoubleTank ? "SAC (double tank)" : "SAC"

            // Always display RMV field
            conditionRow(icon: "lungs.fill", color: .pink, label: rmvLabel,
                        value: dive.formattedRMV)

            // Always display SAC field (unit follows user's pressure preference)
            conditionRow(icon: "gauge.with.dots.needle.bottom.50percent", color: .mint, label: sacLabel,
                        value: dive.formattedSAC)

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
                                    Text(decoStopDepthLabel(stop.depth, unit: dive.importDistanceUnit))
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
                                    Text(LocalizedStringKey(decoStopTypeLabel(stop.type)))
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

    // MARK: - Helper Functions for Decompression

    func decoStopDepthLabel(_ depth: Double, unit: String) -> String {
        unit == "feet" ? String(format: "%.0f ft", depth * 3.28084) : String(format: "%.0f m", depth)
    }

    func decoStopTimeLabel(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        if m > 0 { return s > 0 ? "\(m) min \(s) s" : "\(m) min" }
        return "\(s) s"
    }

    func decoStopTypeLabel(_ type: Int) -> String {
        switch type {
        case 1: return "Safety Stop"
        case 2: return "Deco Stop"
        case 3: return "Deep Stop"
        default: return "NDL"
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
