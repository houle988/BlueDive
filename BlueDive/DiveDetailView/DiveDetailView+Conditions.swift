import SwiftUI

// MARK: - Condition Row

/// A labelled icon/value row used across the Conditions, Gas, and Site Details tabs.
///
/// This used to be a plain function (`conditionRow(icon:color:label:value:)`) that inlined
/// its HStack/ZStack/VStack tree at every call site. `gazTabContent` alone calls it 15+
/// times across four sibling card properties combined in one VStack — the same class of
/// bug that caused an `EXC_BAD_ACCESS` crash in `DiveDetailView+MenuTab.swift` (10 chained
/// `.tapTargetInsets(...)` modifier sites overflowed the stack during Swift's runtime
/// value-witness copy of the resulting deeply-nested anonymous type). Packaging this as a
/// nominal struct — the same fix used there — stops each call's internal complexity at its
/// own `body`'s boundary instead of letting it inline into the combined tab's compound type.
struct ConditionRow: View {
    let icon: String
    let color: Color
    let label: LocalizedStringKey
    let value: String

    var body: some View {
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
                Image(systemName: "cloud.sun")
                    .font(.title3)
                    .foregroundStyle(.yellow)
                Text("Weather & Water Conditions")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                Spacer()
            }

            ConditionRow(
                icon: "thermometer.medium",
                color: .orange,
                label: "Surface Temp.",
                value: dive.airTemperature.map {
                    UserPreferences.shared.temperatureUnit.formatted($0, from: dive.storedTemperatureUnit)
                } ?? "—"
            )
            ConditionRow(
                icon: "thermometer.low",
                color: .blue,
                label: "Minimum Temperature",
                value: dive.minTemperature.map { UserPreferences.shared.temperatureUnit.formatted($0, from: dive.storedTemperatureUnit) } ?? "—"
            )
            ConditionRow(
                icon: "thermometer.high",
                color: .red,
                label: "Maximum Temp.",
                value: dive.maxTemperature.map {
                    UserPreferences.shared.temperatureUnit.formatted($0, from: dive.storedTemperatureUnit)
                } ?? "—"
            )

            // Always display Weather field
            ConditionRow(icon: "cloud.sun", color: .yellow, label: "Weather",
                        value: dive.weather.map { localizedWeather($0) } ?? "—")

            // Always display Surface conditions field
            ConditionRow(icon: "water.waves", color: .cyan, label: "Surface",
                        value: dive.surfaceConditions.map { localizedSurface($0) } ?? "—")

            // Always display Current field
            ConditionRow(icon: "wind", color: .teal, label: "Current",
                        value: dive.current.map { localizedCurrent($0) } ?? "—")

            // Always display Visibility field
            let depthUnit = prefs.depthUnit.symbol
            if let visibility = dive.visibility {
                let visibilityDisplay: String = {
                    let trimmed = visibility.trimmingCharacters(in: .whitespaces)
                    return Double(trimmed) != nil ? "\(trimmed) \(depthUnit)" : trimmed
                }()
                ConditionRow(
                    icon: "eye",
                    color: .green,
                    label: "Visibility",
                    value: visibilityDisplay
                )
            } else {
                ConditionRow(
                    icon: "eye",
                    color: .green,
                    label: "Visibility",
                    value: "—"
                )
            }
        }
        .padding()
        .detailCardBackground()
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

}
