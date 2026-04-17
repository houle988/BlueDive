import SwiftUI

// MARK: - Samples Tab

extension DiveDetailView {

    var samplesTabContent: some View {
        VStack(spacing: 20) {
            if dive.profileSamples.isEmpty {
                emptySamplesView
            } else {
                samplesFormatInfoSection
                samplesTableSection
            }
        }
    }

    var emptySamplesView: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)
            Text("No samples available")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("Import a dive from your dive computer to see detailed data.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Samples Format Info

    var samplesFormatInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive.fill")
                    .foregroundStyle(.teal)
                Text("Imported Data Format")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                FormatInfoCell(
                    icon: "arrow.down.to.line",
                    label: "Distance",
                    value: dive.importDistanceUnit,
                    color: .cyan
                )
                FormatInfoCell(
                    icon: "thermometer.medium",
                    label: "Temperature",
                    value: dive.importTemperatureUnit,
                    color: .orange
                )
                FormatInfoCell(
                    icon: "gauge.with.needle.fill",
                    label: "Pressure",
                    value: dive.importPressureUnit,
                    color: .red
                )
                FormatInfoCell(
                    icon: "cylinder.fill",
                    label: "Volume",
                    value: dive.importVolumeUnit,
                    color: .green
                )
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal)
    }

    var samplesChartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(.teal)
                Text("Detailed Profile")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            UnifiedDiveChartOptimized(dive: dive)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal)
    }

    /// Sorted tank indices that have per-tank pressure data across the whole dive.
    private var sampleTankIndices: [Int] {
        var indices = Set<Int>()
        for sample in dive.profileSamples {
            if let tp = sample.tankPressures {
                indices.formUnion(tp.keys)
            }
        }
        return indices.sorted()
    }

    var samplesTableSection: some View {
        let tankIndices = sampleTankIndices
        let hasMultiTank = tankIndices.count > 1

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "tablecells.fill")
                    .foregroundStyle(.teal)
                Text("Raw Data (\(dive.profileSamples.count) points)")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Table header
                    HStack(spacing: 8) {
                        Text("Time").font(.caption2).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                        Text("Depth").font(.caption2).foregroundStyle(.secondary).frame(width: 45, alignment: .trailing)
                        Text("Temp.").font(.caption2).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
                        if hasMultiTank {
                            ForEach(tankIndices, id: \.self) { idx in
                                Text("T\(idx + 1)").font(.caption2).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
                            }
                        } else {
                            Text("Press.").font(.caption2).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
                        }
                        Text("PPO₂").font(.caption2).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
                        Text("NDL").font(.caption2).foregroundStyle(.secondary).frame(width: 45, alignment: .trailing)
                        Text("Events").font(.caption2).foregroundStyle(.secondary).frame(minWidth: 50, alignment: .leading)
                        Spacer()
                    }
                    .padding(.horizontal, 4)

                    Divider().background(.primary.opacity(0.15))

                    LazyVStack(spacing: 0) {
                        ForEach(Array(dive.profileSamples.enumerated()), id: \.offset) { i, sample in
                            HStack(spacing: 8) {
                                Text(String(format: "%.2f", sample.time * 60))
                                    .font(.caption).foregroundStyle(.primary)
                                    .frame(width: 50, alignment: .leading)
                                Text(String(format: "%.2f", sample.depth))
                                    .font(.caption).foregroundStyle(.cyan)
                                    .frame(width: 45, alignment: .trailing)
                                if let temp = sample.temperature {
                                    Text(UserPreferences.shared.temperatureUnit.formatted(temp, from: dive.storedTemperatureUnit))
                                        .font(.caption).foregroundStyle(.orange)
                                        .frame(width: 50, alignment: .trailing)
                                } else {
                                    Text("—").font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
                                }
                                if hasMultiTank {
                                    ForEach(tankIndices, id: \.self) { idx in
                                        if let press = sample.tankPressures?[idx] {
                                            Text(String(format: "%.0f", dive.displayProfilePressure(press)))
                                                .font(.caption).foregroundStyle(.red)
                                                .frame(width: 50, alignment: .trailing)
                                        } else {
                                            Text("—").font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
                                        }
                                    }
                                } else {
                                    if let press = sample.tankPressure {
                                        Text(String(format: "%.2f", dive.displayProfilePressure(press)))
                                            .font(.caption).foregroundStyle(.red)
                                            .frame(width: 50, alignment: .trailing)
                                    } else {
                                        Text("—").font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
                                    }
                                }
                                if let ppo2 = sample.ppo2 {
                                    Text(String(format: "%.2f", ppo2))
                                        .font(.caption).foregroundStyle(ppo2Color(for: ppo2))
                                        .frame(width: 50, alignment: .trailing)
                                } else {
                                    Text("—").font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
                                }
                                if let ndl = sample.ndl {
                                    Text(String(format: "%.0f", ndl))
                                        .font(.caption).foregroundStyle(.yellow)
                                        .frame(width: 45, alignment: .trailing)
                                } else {
                                    Text("—").font(.caption).foregroundStyle(.secondary).frame(width: 45, alignment: .trailing)
                                }
                                if sample.events.isEmpty {
                                    Text("—").font(.caption).foregroundStyle(.secondary).frame(minWidth: 50, alignment: .leading)
                                } else {
                                    Text(sample.events.map(\.label).joined(separator: ", "))
                                        .font(.caption).foregroundStyle(.mint)
                                        .frame(minWidth: 50, alignment: .leading)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 4)
                            .background(i % 2 == 0 ? Color.primary.opacity(0.03) : Color.clear)
                        }
                    }
                }
            }

        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal)
    }
}
