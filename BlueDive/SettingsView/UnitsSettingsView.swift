import SwiftUI

struct UnitsSettingsView: View {
    @State private var prefs = UserPreferences.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Depth", systemImage: "arrow.down.to.line")
                            .font(.subheadline)
                            .foregroundStyle(.cyan)
                        Picker("Depth", selection: $prefs.depthUnit) {
                            ForEach(DepthUnit.allCases, id: \.self) { unit in
                                Text(unit.symbol.uppercased()).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Tank pressure", systemImage: "gauge")
                            .font(.subheadline)
                            .foregroundStyle(.cyan)
                        Picker("Tank pressure", selection: $prefs.pressureUnit) {
                            ForEach(PressureUnit.allCases, id: \.self) { unit in
                                Text(unit.symbol).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Temperature", systemImage: "thermometer.medium")
                            .font(.subheadline)
                            .foregroundStyle(.cyan)
                        Picker("Temperature", selection: $prefs.temperatureUnit) {
                            ForEach(TemperatureUnit.allCases, id: \.self) { unit in
                                Text(unit.symbol).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Tank volume", systemImage: "cylinder")
                            .font(.subheadline)
                            .foregroundStyle(.cyan)
                        Picker("Tank volume", selection: $prefs.volumeUnit) {
                            ForEach(VolumeUnit.allCases, id: \.self) { unit in
                                Text(unit.symbol).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Weight", systemImage: "scalemass")
                            .font(.subheadline)
                            .foregroundStyle(.cyan)
                        Picker("Weight", selection: $prefs.weightUnit) {
                            ForEach(WeightUnit.allCases, id: \.self) { unit in
                                Text(unit.symbol).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                )
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .settingsGradientBackground()
        .navigationTitle(Text(verbatim: NSLocalizedString("Units of Measure", bundle: .forAppLanguage(), value: "Units of Measure", comment: "")))
    }
}
