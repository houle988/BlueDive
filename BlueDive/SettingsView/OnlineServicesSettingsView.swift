import SwiftUI

struct OnlineServicesSettingsView: View {
    // Bound to the shared UserPreferences (see DiveProfileSettingsView for why not @AppStorage).
    @State private var prefs = UserPreferences.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $prefs.fetchWeatherOnline) {
                            Label {
                                Text("Fetch weather from Open-Meteo")
                            } icon: {
                                Image(systemName: "cloud.sun")
                                    .foregroundStyle(.yellow)
                            }
                        }
                        .fullWidthSwitch()
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    (Text("BlueDive can fill in the weather, air temperature and wind for a dive from its GPS coordinates, using Open-Meteo.") + Text(verbatim: " ") + Text("The coordinates and date are sent when you choose Fetch Weather, and for dives downloaded over Bluetooth that have GPS coordinates."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Weather data by [Open-Meteo.com](https://open-meteo.com/) ([CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)), converted to BlueDive's weather, wind and wind direction options.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
        .navigationTitle(Text(verbatim: NSLocalizedString("Online Services", bundle: .forAppLanguage(), value: "Online Services", comment: "")))
    }
}
