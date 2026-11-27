import Foundation
import Testing
@testable import BlueDive

/// The preferences shown in Settings and in Getting Started: their defaults
/// (`UserPreferences.Defaults`, which the guide's "Default: …" captions show), Reset to Defaults,
/// and a change being saved and read back. Also the order of the Getting Started steps.
///
/// These tests write to the app's real `UserDefaults` (`UserPreferences` reads
/// `UserDefaults.standard`), so every test runs inside `withSavedPreferences`, which restores the
/// app's defaults domain, the widget's App Group keys and the shared chart setting afterwards.
@MainActor
@Suite(.serialized)
struct UserPreferencesDefaultsTests {

    /// Every `UserDefaults` key `UserPreferences` reads in `init`.
    private static let preferenceKeys = [
        "depthUnit", "pressureUnit", "temperatureUnit", "volumeUnit", "weightUnit",
        "appearanceMode", "languageMode", "hideClearedDecoStops", "showPhotosOnProfile",
        "searchDiveNotes", "formatNotesAsMarkdown", "wideSpeciesImages", "tripGapDays",
        "splitTripsOnCountryChange", "copySiteGPSMode", "copySiteGPSLastChoice",
        "replaceWeatherMode", "replaceWeatherLastChoice", "fetchWeatherOnline",
        "fetchTaxonomyOnline", "taxonomyNameLanguage", "useINaturalistCommonNames",
        "useAlternativeINaturalistPhoto", "showDiveListProfilePreview",
    ]

    private static let appGroup = "group.app.bluedive.universal"
    /// The keys `UserPreferences` writes to the App Group for the widget.
    private static let widgetKeys = ["depthUnit", "appearanceMode", "languageMode"]

    // MARK: - Helpers

    /// Runs `body`, then puts back everything a `UserPreferences` instance may have changed.
    private func withSavedPreferences(_ body: () throws -> Void) rethrows {
        let standard = UserDefaults.standard
        let domainName = Bundle.main.bundleIdentifier
        let savedDomain = domainName.flatMap { standard.persistentDomain(forName: $0) }
        let group = UserDefaults(suiteName: Self.appGroup)
        let savedWidgetValues = Self.widgetKeys.map { group?.object(forKey: $0) }
        let savedChartLines = SharedChartLineVisibility.shared.value

        defer {
            if let domainName {
                if let savedDomain {
                    standard.setPersistentDomain(savedDomain, forName: domainName)
                } else {
                    standard.removePersistentDomain(forName: domainName)
                }
            }
            for (key, value) in zip(Self.widgetKeys, savedWidgetValues) {
                if let value { group?.set(value, forKey: key) } else { group?.removeObject(forKey: key) }
            }
            SharedChartLineVisibility.shared.value = savedChartLines
        }
        try body()
    }

    /// Gives every preference a value other than its default.
    private func setNonDefaultValues(_ prefs: UserPreferences) {
        prefs.depthUnit = .feet
        prefs.pressureUnit = .psi
        prefs.temperatureUnit = .fahrenheit
        prefs.volumeUnit = .cubicFeet
        prefs.weightUnit = .pounds
        prefs.appearanceMode = .dark
        prefs.languageMode = .german
        prefs.hideClearedDecoStops = !UserPreferences.Defaults.hideClearedDecoStops
        prefs.showPhotosOnProfile = !UserPreferences.Defaults.showPhotosOnProfile
        prefs.searchDiveNotes = !UserPreferences.Defaults.searchDiveNotes
        prefs.formatNotesAsMarkdown = !UserPreferences.Defaults.formatNotesAsMarkdown
        prefs.wideSpeciesImages = !UserPreferences.Defaults.wideSpeciesImages
        prefs.tripGapDays = UserPreferences.defaultTripGapDays + 4
        prefs.splitTripsOnCountryChange = !UserPreferences.Defaults.splitTripsOnCountryChange
        prefs.copySiteGPSMode = .on
        prefs.replaceWeatherMode = .off
        prefs.fetchWeatherOnline = !UserPreferences.Defaults.fetchWeatherOnline
        prefs.fetchTaxonomyOnline = !UserPreferences.Defaults.fetchTaxonomyOnline
        prefs.taxonomyNameLanguage = "fr"
        prefs.useINaturalistCommonNames = !UserPreferences.Defaults.useINaturalistCommonNames
        prefs.useAlternativeINaturalistPhoto = !UserPreferences.Defaults.useAlternativeINaturalistPhoto
        prefs.showDiveListProfilePreview = !UserPreferences.defaultShowsDiveListProfilePreview
    }

    /// Checks that every preference holds its default value.
    private func expectDefaults(_ prefs: UserPreferences) {
        typealias D = UserPreferences.Defaults
        #expect(prefs.depthUnit == D.depthUnit)
        #expect(prefs.pressureUnit == D.pressureUnit)
        #expect(prefs.temperatureUnit == D.temperatureUnit)
        #expect(prefs.volumeUnit == D.volumeUnit)
        #expect(prefs.weightUnit == D.weightUnit)
        #expect(prefs.appearanceMode == D.appearanceMode)
        #expect(prefs.languageMode == D.languageMode)
        #expect(prefs.hideClearedDecoStops == D.hideClearedDecoStops)
        #expect(prefs.showPhotosOnProfile == D.showPhotosOnProfile)
        #expect(prefs.searchDiveNotes == D.searchDiveNotes)
        #expect(prefs.formatNotesAsMarkdown == D.formatNotesAsMarkdown)
        #expect(prefs.wideSpeciesImages == D.wideSpeciesImages)
        #expect(prefs.tripGapDays == UserPreferences.defaultTripGapDays)
        #expect(prefs.splitTripsOnCountryChange == D.splitTripsOnCountryChange)
        #expect(prefs.copySiteGPSMode == D.copySiteGPSMode)
        #expect(prefs.replaceWeatherMode == D.replaceWeatherMode)
        #expect(prefs.fetchWeatherOnline == D.fetchWeatherOnline)
        #expect(prefs.fetchTaxonomyOnline == D.fetchTaxonomyOnline)
        #expect(prefs.taxonomyNameLanguage == D.taxonomyNameLanguage)
        #expect(prefs.useINaturalistCommonNames == D.useINaturalistCommonNames)
        #expect(prefs.useAlternativeINaturalistPhoto == D.useAlternativeINaturalistPhoto)
        #expect(prefs.showDiveListProfilePreview == UserPreferences.defaultShowsDiveListProfilePreview)
    }

    // MARK: - Defaults

    @Test func noStoredValueGivesEveryDefault() {
        withSavedPreferences {
            for key in Self.preferenceKeys {
                UserDefaults.standard.removeObject(forKey: key)
            }
            expectDefaults(UserPreferences())
        }
    }

    @Test func anUnknownStoredValueGivesTheDefault() {
        withSavedPreferences {
            // e.g. a value written by a newer version of the app.
            for key in ["depthUnit", "pressureUnit", "temperatureUnit", "volumeUnit", "weightUnit",
                        "appearanceMode", "languageMode", "copySiteGPSMode", "replaceWeatherMode"] {
                UserDefaults.standard.set("unknown", forKey: key)
            }
            let prefs = UserPreferences()
            #expect(prefs.depthUnit == UserPreferences.Defaults.depthUnit)
            #expect(prefs.pressureUnit == UserPreferences.Defaults.pressureUnit)
            #expect(prefs.temperatureUnit == UserPreferences.Defaults.temperatureUnit)
            #expect(prefs.volumeUnit == UserPreferences.Defaults.volumeUnit)
            #expect(prefs.weightUnit == UserPreferences.Defaults.weightUnit)
            #expect(prefs.appearanceMode == UserPreferences.Defaults.appearanceMode)
            #expect(prefs.languageMode == UserPreferences.Defaults.languageMode)
            #expect(prefs.copySiteGPSMode == UserPreferences.Defaults.copySiteGPSMode)
            #expect(prefs.replaceWeatherMode == UserPreferences.Defaults.replaceWeatherMode)
        }
    }

    @Test func aTripGapOutsideItsRangeIsClamped() {
        withSavedPreferences {
            UserDefaults.standard.set(0, forKey: "tripGapDays")
            #expect(UserPreferences().tripGapDays == UserPreferences.tripGapDaysRange.lowerBound)
            UserDefaults.standard.set(999, forKey: "tripGapDays")
            #expect(UserPreferences().tripGapDays == UserPreferences.tripGapDaysRange.upperBound)
        }
    }

    // MARK: - Reset to Defaults

    @Test func resetToDefaultsRestoresEveryDefault() {
        withSavedPreferences {
            let prefs = UserPreferences()
            setNonDefaultValues(prefs)
            prefs.copySiteGPSLastChoice = true
            prefs.replaceWeatherLastChoice = true
            UserDefaults.standard.set(!UserPreferences.Defaults.filterUnusedTanks, forKey: "filterUnusedTanks")
            UserDefaults.standard.set(!UserPreferences.Defaults.autoSequenceEnabled, forKey: "autoSequenceEnabled")

            prefs.resetToDefaults()

            expectDefaults(prefs)
            #expect(prefs.copySiteGPSLastChoice == nil)
            #expect(prefs.replaceWeatherLastChoice == nil)
            #expect(UserDefaults.standard.bool(forKey: "filterUnusedTanks") == UserPreferences.Defaults.filterUnusedTanks)
            #expect(UserDefaults.standard.bool(forKey: "autoSequenceEnabled") == UserPreferences.Defaults.autoSequenceEnabled)
            // Saved too: the next launch also starts from the defaults.
            expectDefaults(UserPreferences())
        }
    }

    // MARK: - A change is saved and applied

    @Test func aChangedPreferenceIsSavedAndReadBack() {
        withSavedPreferences {
            setNonDefaultValues(UserPreferences())

            // What the app reads at its next launch (or a Settings page bound to the same key).
            let reloaded = UserPreferences()
            #expect(reloaded.depthUnit == .feet)
            #expect(reloaded.pressureUnit == .psi)
            #expect(reloaded.temperatureUnit == .fahrenheit)
            #expect(reloaded.volumeUnit == .cubicFeet)
            #expect(reloaded.weightUnit == .pounds)
            #expect(reloaded.appearanceMode == .dark)
            #expect(reloaded.languageMode == .german)
            #expect(reloaded.hideClearedDecoStops == !UserPreferences.Defaults.hideClearedDecoStops)
            #expect(reloaded.showPhotosOnProfile == !UserPreferences.Defaults.showPhotosOnProfile)
            #expect(reloaded.searchDiveNotes == !UserPreferences.Defaults.searchDiveNotes)
            #expect(reloaded.formatNotesAsMarkdown == !UserPreferences.Defaults.formatNotesAsMarkdown)
            #expect(reloaded.wideSpeciesImages == !UserPreferences.Defaults.wideSpeciesImages)
            #expect(reloaded.tripGapDays == UserPreferences.defaultTripGapDays + 4)
            #expect(reloaded.splitTripsOnCountryChange == !UserPreferences.Defaults.splitTripsOnCountryChange)
            #expect(reloaded.copySiteGPSMode == .on)
            #expect(reloaded.replaceWeatherMode == .off)
            #expect(reloaded.fetchWeatherOnline == !UserPreferences.Defaults.fetchWeatherOnline)
            #expect(reloaded.fetchTaxonomyOnline == !UserPreferences.Defaults.fetchTaxonomyOnline)
            #expect(reloaded.taxonomyNameLanguage == "fr")
            #expect(reloaded.useINaturalistCommonNames == !UserPreferences.Defaults.useINaturalistCommonNames)
            #expect(reloaded.useAlternativeINaturalistPhoto == !UserPreferences.Defaults.useAlternativeINaturalistPhoto)
            #expect(reloaded.showDiveListProfilePreview == !UserPreferences.defaultShowsDiveListProfilePreview)
        }
    }

    @Test func theWidgetReceivesDepthUnitThemeAndLanguage() throws {
        let group = try #require(UserDefaults(suiteName: Self.appGroup))
        withSavedPreferences {
            let prefs = UserPreferences()
            prefs.depthUnit = .feet
            prefs.appearanceMode = .dark
            prefs.languageMode = .frenchCanada
            #expect(group.string(forKey: "depthUnit") == "feet")
            #expect(group.string(forKey: "appearanceMode") == AppearanceMode.dark.rawValue)
            #expect(group.string(forKey: "languageMode") == AppLanguage.frenchCanada.rawValue)

            prefs.depthUnit = .meters
            #expect(group.string(forKey: "depthUnit") == "meters")
        }
    }

    // MARK: - Getting Started

    @Test func gettingStartedStepsAreInGuideOrder() {
        // The guide's own order, deliberately not the order of the Settings list.
        #expect(GettingStartedStep.allCases == [
            .welcome, .appearance, .units, .onlineServices, .iCloud, .notifications,
            .diveSequence, .diveProfile, .bluetooth, .moreInSettings,
        ])
        // The step is kept in @SceneStorage by its raw value: 0 must stay the first step.
        #expect(GettingStartedStep.allCases.map(\.rawValue) == Array(0..<GettingStartedStep.allCases.count))
        #expect(GettingStartedStep(rawValue: 0) == .welcome)
    }
}
