import SwiftUI

// MARK: - Conditions Tab

extension DiveDetailView {

    var conditionsTabContent: some View {
        VStack(spacing: 20) {
            conditionsInfoCard
        }
    }

    var conditionsInfoCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "cloud.sun.fill")
                    .font(.title3)
                    .foregroundStyle(.yellow)
                Text("Weather & Water Conditions")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                Spacer()
            }

            conditionRow(
                icon: "thermometer.medium",
                color: .orange,
                label: "Surface Temp.",
                value: dive.airTemperature.map {
                    UserPreferences.shared.temperatureUnit.formatted($0, from: dive.storedTemperatureUnit)
                } ?? "—"
            )
            conditionRow(
                icon: "thermometer.low",
                color: .blue,
                label: "Minimum Temperature",
                value: dive.minTemperature != 0 ? UserPreferences.shared.temperatureUnit.formatted(dive.minTemperature, from: dive.storedTemperatureUnit) : "—"
            )
            conditionRow(
                icon: "thermometer.high",
                color: .red,
                label: "Maximum Temp.",
                value: dive.maxTemperature.map {
                    UserPreferences.shared.temperatureUnit.formatted($0, from: dive.storedTemperatureUnit)
                } ?? "—"
            )

            // Always display Weather field
            conditionRow(icon: "cloud.sun.fill", color: .yellow, label: "Weather",
                        value: (dive.weather?.isEmpty == false ? dive.weather! : "—"))

            // Always display Surface conditions field
            conditionRow(icon: "water.waves", color: .cyan, label: "Surface",
                        value: (dive.surfaceConditions?.isEmpty == false ? dive.surfaceConditions! : "—"))

            // Always display Current field
            conditionRow(icon: "wind", color: .teal, label: "Current",
                        value: (dive.current?.isEmpty == false ? dive.current! : "—"))

            // Always display Visibility field
            let depthUnit = prefs.depthUnit == .feet ? "ft" : "m"
            if let visibility = dive.visibility {
                let visibilityDisplay: String = {
                    let trimmed = visibility.trimmingCharacters(in: .whitespaces)
                    return Double(trimmed) != nil ? "\(trimmed) \(depthUnit)" : trimmed
                }()
                conditionRow(
                    icon: "eye.fill",
                    color: .green,
                    label: "Visibility",
                    value: visibilityDisplay
                )
            } else {
                conditionRow(
                    icon: "eye.fill",
                    color: .green,
                    label: "Visibility",
                    value: "—"
                )
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal)
    }

    func conditionRow(icon: String, color: Color, label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.2))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(LocalizedStringKey(value))
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
            Spacer()
        }
    }
}
