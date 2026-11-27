import SwiftUI

/// Getting Started: a guide through the preferences in Settings, one topic per step, with the
/// same controls as the Settings pages (their shared cards, e.g. `UnitsSettingsCards`) plus a
/// "Default: …" caption under each (`isInGettingStarted`). A change made here is the same
/// change as in Settings.
///
/// Presented by `MainTabView` (after "Set Up BlueDive" at the end of the Welcome Tour on first
/// launch, in the same presentation, or from Settings → About), which keeps `step` in
/// `@SceneStorage`: a language change from or to System rebuilds the whole
/// window (`LanguageOverrideModifier`), and the guide then reopens on the same step.
struct GettingStartedView: View {
    @Binding var step: Int

    @Environment(\.dismiss) private var dismiss
    /// The one-time weather and iNaturalist launch questions (`MainTabView.launchQuestions`):
    /// answered here once the Online Services step is shown.
    @AppStorage("onlineServicesPromptShown") private var onlineServicesPromptShown = false
    @AppStorage("taxonomyPromptShown") private var taxonomyPromptShown = false

    private var currentStep: GettingStartedStep {
        GettingStartedStep(rawValue: step) ?? .welcome
    }

    var body: some View {
        GuidePager(
            pageCount: GettingStartedStep.allCases.count,
            current: $step,
            lastPagePrimary: Text("Done"),
            onLastPagePrimary: finish,
            onSkip: finish
        ) { index in
            pageView(GettingStartedStep(rawValue: index) ?? .welcome)
        }
        .environment(\.isInGettingStarted, true)
        // Its colour scheme is set by MainTabView (`guideColorScheme`), never nil: a presentation
        // whose preferred scheme goes back to nil stays in the old one (Dark → System).
        .onChange(of: step, initial: true) {
            if currentStep == .onlineServices {
                onlineServicesPromptShown = true
                taxonomyPromptShown = true
            }
        }
    }

    /// Done or Skip. The step is not reset here (the page would jump to the first one while the
    /// guide closes): `MainTabView` starts it at the first step each time it opens it.
    private func finish() {
        dismiss()
    }

    // MARK: - Pages

    private func pageView(_ page: GettingStartedStep) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                header(page)
                content(page)
            }
            .padding(.vertical)
            // Keeps the cards readable in a wide window (iPad, Mac).
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
    }

    private func header(_ page: GettingStartedStep) -> some View {
        GuidePageHeader(icon: page.icon, color: page.color, title: page.title, subtitle: page.intro)
            .padding(.horizontal, 24)
            // Same position as the Welcome Tour's header.
            .padding(.top, 28)
    }

    @ViewBuilder
    private func content(_ page: GettingStartedStep) -> some View {
        switch page {
        case .welcome:
            EmptyView()
        case .appearance:
            AppearanceSettingsCards()
        case .units:
            UnitsSettingsCards()
        case .onlineServices:
            VStack(spacing: 20) {
                OnlineWeatherSettingsCards()
                INaturalistSettingsCard()
            }
        case .iCloud:
            VStack(spacing: 20) {
                ICloudSettingsCards()
                ICloudAccountWarningCard()
            }
        case .notifications:
            NotificationsSettingsCards()
        case .diveSequence:
            DiveSequenceSettingsCards()
        case .diveProfile:
            DiveProfileSettingsCards()
        case .bluetooth:
            BluetoothImportSettingsCards()
        case .moreInSettings:
            moreInSettings
        }
    }

    /// Where the one-off tools and the advanced options are in Settings (read only).
    private var moreInSettings: some View {
        VStack(spacing: 14) {
            GuideFeatureRow(icon: "externaldrive", color: .red,
                            title: Text("Backup & Restore"),
                            detail: Text("Settings → Data Management: back up your logbook, or restore a backup."))
            GuideFeatureRow(icon: "number.circle", color: .indigo,
                            title: Text("Dive Numbers"),
                            detail: Text("Settings → Dive Sequence: recalculate surface intervals or renumber your dives."))
            GuideFeatureRow(icon: "cloud.sun.rain", color: .yellow,
                            title: Text("Weather & Species"),
                            detail: Text("Settings → Online Services: fetch the weather for all your dives, or update all species from iNaturalist."))
            GuideFeatureRow(icon: "dock.rectangle", color: .teal,
                            title: Text("Tab Layout"),
                            detail: Text("Settings → Appearance & Language → Main Tabs, and Settings → Dive Profile → Dive Detail Tabs: reorder or hide tabs."))
            GuideFeatureRow(icon: "antenna.radiowaves.left.and.right", color: .blue,
                            title: Text("Dive Computers"),
                            detail: Text("Settings → Bluetooth Import: sync fingerprints, and a diagnostic log to send when a download fails."))
            // The icon and colour of the Settings → About → Getting Started row.
            GuideFeatureRow(icon: "slider.horizontal.3", color: .cyan,
                            title: Text("Getting Started"),
                            detail: Text("Settings → About → Getting Started opens this guide again."))
        }
        .padding(.horizontal)
    }
}

// MARK: - Steps

/// The steps of Getting Started, in order. The raw value is the step kept in `@SceneStorage`.
enum GettingStartedStep: Int, CaseIterable, Identifiable {
    case welcome
    case appearance
    case units
    case onlineServices
    case iCloud
    case notifications
    case diveSequence
    case diveProfile
    case bluetooth
    case moreInSettings

    var id: Int { rawValue }

    var icon: String {
        switch self {
        case .welcome:        "slider.horizontal.3"
        case .appearance:     "paintbrush"
        case .units:          "ruler"
        case .onlineServices: "globe"
        case .iCloud:         "icloud"
        case .notifications:  "bell"
        case .diveSequence:   "arrow.triangle.2.circlepath"
        case .diveProfile:    "chart.xyaxis.line"
        case .bluetooth:      "antenna.radiowaves.left.and.right"
        case .moreInSettings: "gear"
        }
    }

    /// The colour of the matching row in Settings.
    var color: Color {
        switch self {
        case .welcome:        .cyan
        case .appearance:     .pink
        case .units:          .orange
        case .onlineServices: .mint
        case .iCloud:         .cyan
        case .notifications:  .purple
        case .diveSequence:   .indigo
        case .diveProfile:    .green
        case .bluetooth:      .blue
        case .moreInSettings: .gray
        }
    }

    var title: Text {
        switch self {
        case .welcome:        Text("Getting Started")
        case .appearance:     Text("Appearance & Language")
        case .units:          Text("Units of Measure")
        case .onlineServices: Text("Online Services")
        case .iCloud:         Text("iCloud")
        case .notifications:  Text("Notifications")
        case .diveSequence:   Text("Dive Numbers & Trips")
        case .diveProfile:    Text("Dive Profile & Notes")
        case .bluetooth:      Text("Bluetooth Import")
        case .moreInSettings: Text("More in Settings")
        }
    }

    var intro: Text {
        switch self {
        case .welcome:
            Text("Set up BlueDive in a few steps. Each step shows the options of a Settings page, what they do and their default value. You can change them anytime in Settings.")
        case .appearance:
            Text("Choose the language and the theme of BlueDive.")
        case .units:
            Text("Choose the units BlueDive shows. Your dives keep the values and units they were recorded in; only the display changes.")
        case .onlineServices:
            Text("BlueDive can fill in the weather of a dive and information about the species you saw. Both are off until you turn them on.")
        case .iCloud:
            Text("Keep your logbook in sync on your Apple devices signed in to the same Apple Account.")
        case .notifications:
            Text("Get reminders for equipment service and for certification and insurance expiry, and a notification for dive milestones.")
        case .diveSequence:
            Text("Choose how dive numbers and surface intervals are kept up to date, and how dives are grouped into trips.")
        case .diveProfile:
            Text("Choose what the dive profile shows, how notes are searched and shown, and what copying a site includes.")
        case .bluetooth:
            Text("An option for the dives you download from your dive computer over Bluetooth.")
        case .moreInSettings:
            Text("These tools and options are in Settings whenever you need them.")
        }
    }
}
