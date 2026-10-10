import SwiftUI

struct OnlineServicesSettingsView: View {
    // Bound to the shared UserPreferences (see DiveProfileSettingsView for why not @AppStorage).
    @State private var prefs = UserPreferences.shared
    /// Closes the whole Settings sheet, for the Mac close button of the page pushed from here
    /// (inside a pushed page, `dismiss` only pops it — see closeSheetButtonOnMac).
    var closeSettings: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $prefs.fetchWeatherOnline) {
                            Label {
                                Text("Fetch weather online")
                            } icon: {
                                Image(systemName: "cloud.sun")
                                    .foregroundStyle(.yellow)
                            }
                        }
                        .fullWidthSwitch()
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

                    (Text("BlueDive can fill in the weather, air temperature and wind for a dive from its GPS coordinates, using Open-Meteo.") + Text(verbatim: " ") + Text("The coordinates and date are sent only when you fetch the weather online."))
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

                updateAllWeatherCard

                taxonomyCard
            }
            .padding(.vertical)
        }
        .settingsGradientBackground()
        .navigationTitle(Text(verbatim: NSLocalizedString("Online Services", bundle: .forAppLanguage(), value: "Online Services", comment: "")))
    }

    /// A language for the common-names picker: its name in the app language, followed by its own
    /// name when they differ ("Norwegian (Norsk Bokmål)").
    private static func languageName(_ code: String) -> String {
        let appLocale = Locale(identifier: INaturalistService.appLanguageCode)
        let own = Locale(identifier: code).localizedString(forLanguageCode: code)?
            .capitalized(with: Locale(identifier: code)) ?? code
        guard let inAppLanguage = appLocale.localizedString(forLanguageCode: code)?.capitalized(with: appLocale),
              inAppLanguage != own else { return own }
        return "\(inAppLanguage) (\(own))"
    }

    /// iNaturalist species lookups: the opt-in toggle, attribution, and the page that looks up
    /// every species (greyed out while the service is off).
    private var taxonomyCard: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $prefs.fetchTaxonomyOnline) {
                    Label {
                        Text("Look up species on iNaturalist")
                    } icon: {
                        Image(systemName: "leaf")
                            .foregroundStyle(.green)
                    }
                }
                .fullWidthSwitch()
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

            HStack {
                Label {
                    Text("Common names language")
                } icon: {
                    Image(systemName: "character.bubble")
                        .foregroundStyle(.green)
                }
                Spacer()
                Picker("Common names language", selection: $prefs.taxonomyNameLanguage) {
                    Text("App language").tag("")
                    ForEach(INaturalistService.nameLanguageCodes, id: \.self) { code in
                        Text(verbatim: Self.languageName(code)).tag(code)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
            .disabled(!prefs.fetchTaxonomyOnline)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $prefs.useINaturalistCommonNames) {
                    Label {
                        Text("Use iNaturalist common names")
                    } icon: {
                        Image(systemName: "textformat")
                            .foregroundStyle(.green)
                    }
                }
                .fullWidthSwitch()
                Text("When a species is linked, iNaturalist's common name becomes its name and the name it had is kept in Other Names. When off, species keep the names they were given.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
            .disabled(!prefs.fetchTaxonomyOnline)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $prefs.useAlternativeINaturalistPhoto) {
                    Label {
                        Text("Use another Creative Commons photo")
                    } icon: {
                        Image(systemName: "photo")
                            .foregroundStyle(.green)
                    }
                }
                .fullWidthSwitch()
                Text("When a species' main iNaturalist photo can't be used (all rights reserved), its first Creative Commons photo is used instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
            .disabled(!prefs.fetchTaxonomyOnline)

            Text("BlueDive can fill in a species' classification (kingdom to species), common names, Wikipedia summary and a Creative Commons photo from iNaturalist. Only the species name is sent, when a species is created, edited or looked up.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Species data from [iNaturalist](https://www.inaturalist.org). Photos are shown with their author's credit and licence.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                NavigationLink {
                    UpdateAllTaxonomyView()
                        .closeSheetButtonOnMac { closeSettings() }
                } label: {
                    HStack {
                        Label {
                            Text("Update Species from iNaturalist")
                        } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .padding()
                    .contentShape(Rectangle())
                }
                .borderlessButton()
                .disabled(!prefs.fetchTaxonomyOnline)
            }
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

    /// Opens the page that fetches the weather for all dives with GPS coordinates. Greyed out
    /// while the service is off: nothing is sent to Open-Meteo without that consent.
    private var updateAllWeatherCard: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                NavigationLink {
                    UpdateAllWeatherView()
                        .closeSheetButtonOnMac { closeSettings() }
                } label: {
                    HStack {
                        Label {
                            Text("Update Weather for All Dives")
                        } icon: {
                            Image(systemName: "cloud.sun.rain")
                                .foregroundStyle(.yellow)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    // The padding sits inside the link so the whole card responds, not only the
                    // drawn label (a borderless button only responds where something is drawn).
                    .padding()
                    .contentShape(Rectangle())
                }
                .borderlessButton()
                .disabled(!prefs.fetchWeatherOnline)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))

            Group {
                if prefs.fetchWeatherOnline {
                    Text("Fetch the weather online for every dive with GPS coordinates, for example after importing your logbook.")
                } else {
                    // Shorter than the Bluetooth Import hint: this is already the Online Services page.
                    Text("Turn on Fetch weather online to use this option.")
                }
            }
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
}
