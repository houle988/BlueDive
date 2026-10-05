import SwiftUI

/// Progress, then result, of a `WeatherBatchFetcher` run, shared by the Bluetooth sync results
/// and Settings → Online Services. Text is localized when drawn, so it follows an in-app
/// language change.
struct WeatherBatchFetchStatusView: View {
    let status: WeatherBatchFetchStatus
    /// Shown under every message of a run that stopped early: what to do for the rest.
    let laterHint: Text

    var body: some View {
        VStack(spacing: 6) {
            switch status {
            case .running(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(maxWidth: 240)
                Text(verbatim: String(format: NSLocalizedString("Fetching weather… %@ of %@", bundle: .forAppLanguage(), value: "Fetching weather… %@ of %@", comment: "Progress of a weather fetch over several dives. First %@ is the number of dives done, second the total, both locale-formatted."), Double(done).localizedString(decimals: 0), Double(total).localizedString(decimals: 0)))
            case .finished(let filled, let withData, let stillEmpty, let total):
                if withData == 0 {
                    Text("No weather data was available for these dives.", comment: "Result of a weather fetch over several dives when Open-Meteo had no data for any dive.")
                } else if filled == 0 && stillEmpty > 0 {
                    Text("Nothing was changed. Open-Meteo had no value for the empty fields.")
                } else if filled == 0 {
                    Text("The weather of these dives was already up to date.", comment: "Result of a weather fetch over several dives when Open-Meteo returned the values already stored.")
                } else if total == 1 {
                    Text("Weather added to 1 dive.", comment: "Result of a weather fetch when the only dive requested was updated.")
                } else {
                    Text(verbatim: String(format: NSLocalizedString("Weather added to %@ of %@ dives.", bundle: .forAppLanguage(), value: "Weather added to %@ of %@ dives.", comment: "Result of a weather fetch over several dives. First %@ is the number of dives updated, second the number of dives requested, both locale-formatted."), Double(filled).localizedString(decimals: 0), Double(total).localizedString(decimals: 0)))
                }
            case .stoppedOffline(let filled):
                // The same messages as Edit Conditions' error alert, plus the caller's hint.
                Text("Open-Meteo could not be reached. Check your internet connection or try again later.")
                    .foregroundStyle(.orange)
                laterHint
                addedBeforeStopping(filled)
            case .stoppedUnavailable(let filled):
                Text("Open-Meteo could not provide the weather right now. Try again later.")
                    .foregroundStyle(.orange)
                laterHint
                addedBeforeStopping(filled)
            case .interrupted(let filled):
                Text("Weather fetch stopped when BlueDive was moved to the background.", comment: "Result of a weather fetch over several dives when the app went to the background mid-run.")
                    .foregroundStyle(.orange)
                laterHint
                addedBeforeStopping(filled)
            case .stopped(let filled):
                Text("Weather fetch stopped.", comment: "Result of a weather fetch over several dives when the user chose Stop.")
                laterHint
                addedBeforeStopping(filled)
            case .saveFailed(let filled):
                Text("The fetched weather could not be saved.", comment: "Result of a weather fetch over several dives when saving the fetched values failed.")
                    .foregroundStyle(.orange)
                addedBeforeStopping(filled)
            }
            Text("Weather data by [Open-Meteo.com](https://open-meteo.com/) ([CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)), converted to BlueDive's weather, wind and wind direction options.")
                .font(.caption2)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    /// What a stopped run had already saved, so it is not mistaken for nothing at all.
    @ViewBuilder
    private func addedBeforeStopping(_ filled: Int) -> some View {
        if filled == 1 {
            Text("Weather added to 1 dive before stopping.", comment: "After a weather fetch stopped early: exactly one dive had already been updated.")
        } else if filled > 1 {
            Text(verbatim: String(format: NSLocalizedString("Weather added to %@ dives before stopping.", bundle: .forAppLanguage(), value: "Weather added to %@ dives before stopping.", comment: "After a weather fetch stopped early: number of dives already updated. %@ is the locale-formatted count."), Double(filled).localizedString(decimals: 0)))
        }
    }
}
