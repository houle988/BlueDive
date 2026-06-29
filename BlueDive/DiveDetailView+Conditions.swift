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
                        value: dive.weather.map { localizedWeather($0) } ?? "—")

            // Always display Surface conditions field
            conditionRow(icon: "water.waves", color: .cyan, label: "Surface",
                        value: dive.surfaceConditions.map { localizedSurface($0) } ?? "—")

            // Always display Current field
            conditionRow(icon: "wind", color: .teal, label: "Current",
                        value: dive.current.map { localizedCurrent($0) } ?? "—")

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

    private func localizedWeather(_ raw: String) -> String {
        switch raw {
        case "Sunny":    return NSLocalizedString("Sunny", bundle: .forAppLanguage(), comment: "")
        case "Cloudy":   return NSLocalizedString("Cloudy", bundle: .forAppLanguage(), comment: "")
        case "Overcast": return NSLocalizedString("Overcast", bundle: .forAppLanguage(), comment: "")
        case "Rain":     return NSLocalizedString("Rain", bundle: .forAppLanguage(), comment: "")
        case "Storm":    return NSLocalizedString("Storm", bundle: .forAppLanguage(), comment: "")
        case "Variable": return NSLocalizedString("Variable", bundle: .forAppLanguage(), comment: "")
        default:         return raw
        }
    }

    private func localizedSurface(_ raw: String) -> String {
        switch raw {
        case "Calm":            return NSLocalizedString("Calm", bundle: .forAppLanguage(), comment: "")
        case "Slightly choppy": return NSLocalizedString("Slightly choppy", bundle: .forAppLanguage(), comment: "")
        case "Choppy":          return NSLocalizedString("Choppy", bundle: .forAppLanguage(), comment: "")
        case "Heavy swell":     return NSLocalizedString("Heavy swell", bundle: .forAppLanguage(), comment: "")
        default:                return raw
        }
    }

    private func localizedCurrent(_ raw: String) -> String {
        switch raw {
        case "None":        return NSLocalizedString("None", bundle: .forAppLanguage(), comment: "")
        case "Weak":        return NSLocalizedString("Weak", bundle: .forAppLanguage(), comment: "")
        case "Moderate":    return NSLocalizedString("Moderate", bundle: .forAppLanguage(), comment: "")
        case "Strong":      return NSLocalizedString("Strong", bundle: .forAppLanguage(), comment: "")
        case "Very strong": return NSLocalizedString("Very strong", bundle: .forAppLanguage(), comment: "")
        default:            return raw
        }
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
                Text(verbatim: value)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
            }
            Spacer()
        }
    }
}
