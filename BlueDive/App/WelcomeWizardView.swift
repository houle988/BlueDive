import SwiftUI

struct WelcomeWizardView: View {
    /// On first launch: the last page offers "Set Up BlueDive", which continues with Getting
    /// Started in the same presentation (`MainTabView`), beside "Start Using BlueDive". Nil when
    /// the tour is opened again from Settings: its last page then only closes it.
    var onSetUp: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var currentPage = 0

    private let pages: [WelcomePage] = [
        // Page 1: Getting dives in
        WelcomePage(
            icon: "water.waves",
            iconColor: .cyan,
            title: "Welcome to BlueDive",
            subtitle: "Your modern personal dive logbook",
            features: [
                Feature(icon: "doc.badge.plus", color: .blue, title: "Import Formats", description: "Import from BlueDive XML, MacDive XML, UDDF, Subsurface, or Garmin FIT files — all major dive log formats supported."),
                Feature(icon: "antenna.radiowaves.left.and.right", color: .cyan, title: "Bluetooth Sync", description: "Connect directly to your dive computer via Bluetooth to download dives wirelessly."),
                Feature(icon: "plus.circle", color: .green, title: "Manual Entry", description: "Log dives manually with full control over date, depth, duration, and all details."),
            ]
        ),
        // Page 2: Exploring & analyzing
        WelcomePage(
            icon: "chart.bar",
            iconColor: .orange,
            title: "Explore Your Data",
            subtitle: "Powerful tools to analyze your dives",
            features: [
                Feature(icon: "chart.bar", color: .orange, title: "Dashboard", description: "View statistics, charts, and trends across all your dives."),
                Feature(icon: "chart.bar.xaxis", color: .yellow, title: "Statistics", description: "Track lifetime totals, personal bests, and dive trends — depth, time, gas consumption, and more."),
                Feature(icon: "map", color: .green, title: "Dive Map", description: "See all your dive sites plotted on an interactive world map."),
                Feature(icon: "calendar", color: .purple, title: "Calendar Heatmap", description: "Visualize your diving activity over time."),
                Feature(icon: "map", color: .teal, title: "Dive Trips", description: "Group your dives into trips and relive your dive travel adventures."),
            ]
        ),
        // Page 3: Search, organize, manage
        WelcomePage(
            icon: "magnifyingglass",
            iconColor: .blue,
            title: "Search & Organize",
            subtitle: "Find any dive in seconds",
            features: [
                Feature(icon: "line.3.horizontal.decrease.circle", color: .orange, title: "Search & Filters", description: "Search by site, buddy, country, or tag. Filter by year, depth, gas type, rating, and more."),
                Feature(icon: "arrow.triangle.merge", color: .indigo, title: "Merge Dives", description: "Combine duplicate dive entries into a single, complete record."),
                Feature(icon: "fish", color: .teal, title: "Marine Sightings", description: "Log fish and marine life spotted during each dive."),
                Feature(icon: "cloud.sun", color: .yellow, title: "Online Weather", description: "BlueDive can fill in the weather, air temperature and wind for a dive from its GPS coordinates, using Open-Meteo.", descriptionSuffix: "You can change this anytime in Settings → Online Services."),
                Feature(icon: "leaf", color: .green, title: "Species Catalogue", description: "BlueDive can fill in a species' classification (kingdom to species), common names, Wikipedia summary and a Creative Commons photo from iNaturalist. Only the species name is sent, when a species is created, edited or looked up.", descriptionSuffix: "You can change this anytime in Settings → Online Services."),
            ]
        ),
        // Page 4: Gear & certifications
        WelcomePage(
            icon: "wrench.and.screwdriver",
            iconColor: .gray,
            title: "Track Your Gear",
            subtitle: "Equipment, tanks & certifications",
            features: [
                Feature(icon: "wrench.and.screwdriver", color: .gray, title: "Equipment", description: "Track your gear with service dates and get automatic maintenance reminders."),
                Feature(icon: "tray.2", color: .brown, title: "Gear Groups", description: "Organize equipment into groups — e.g. tropical kit, cold water setup."),
                Feature(icon: "cylinder", color: .mint, title: "Tank Templates", description: "Save your favourite tank configurations for quick reuse."),
                Feature(icon: "graduationcap", color: .blue, title: "Certifications", description: "Store diving certifications and get expiry alerts."),
                Feature(icon: "shield", color: .green, title: "Diving Insurance", description: "Store your dive insurance policies and keep renewal dates at hand."),
            ]
        ),
        // Page 5: Dive tools (Hidden – uncomment to re-enable calculators page)
//        WelcomePage(
//            icon: "checklist",
//            iconColor: .red,
//            title: "Dive Tools",
//            subtitle: "Safety tools for every dive",
//            features: [
//                Feature(icon: "lungs.fill", color: .red, title: "Minimum Gas Calculator", description: "Calculate the minimum breathing gas needed to safely bring you and your buddy to the surface if either of you runs out of air at depth."),
//                Feature(icon: "atom", color: .teal, title: "Gas Density Calculator", description: "Calculate the density of your breathing gas at depth. Colour-coded thresholds warn you when gas density may impair breathing and increase CO₂ retention risk."),
//            ]
//        ),
        // Page 6: Sync, export, profile, settings
        WelcomePage(
            icon: "gear",
            iconColor: .cyan,
            title: "Your Data, Your Way",
            subtitle: "Sync, export & personalize",
            features: [
                Feature(icon: "icloud", color: .cyan, title: "iCloud Sync", description: "Your dives sync automatically across all your Apple devices."),
                Feature(icon: "square.and.arrow.up", color: .indigo, title: "Export Anytime", description: "Export your logbook to XML, UDDF or PDF format whenever you need."),
                Feature(icon: "rectangle.3.group", color: .blue, title: "Widgets", description: "Add BlueDive widgets to your Home Screen or desktop to start a new dive in one tap and see your dive count and diver stats."),
                Feature(icon: "person.circle", color: .pink, title: "Diver Profile", description: "Keep your diver info, emergency contacts, and insurance details handy."),
                Feature(icon: "gear", color: .gray, title: "Settings", description: "Choose your units (metric/imperial), appearance, language, and notification preferences."),
                Feature(icon: "book", color: .blue, title: "Documentation", description: "Guides, tips, and reference material to help you get the most out of BlueDive.", url: wikiDocumentationURL),
            ]
        ),
    ]

    var body: some View {
        // From Settings (no onSetUp) the last page only closes the tour.
        GuidePager(
            pageCount: pages.count,
            current: $currentPage,
            lastPagePrimary: onSetUp == nil ? Text("Get Started") : Text("Set Up BlueDive"),
            onLastPagePrimary: onSetUp ?? finish,
            lastPageSecondary: onSetUp == nil ? nil : Text("Start Using BlueDive"),
            onLastPageSecondary: finish,
            onSkip: finish
        ) { index in
            pageView(pages[index])
        }
    }

    private func finish() {
        hasCompletedOnboarding = true
        dismiss()
    }

    // MARK: - Page View

    private func pageView(_ page: WelcomePage) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 20)

                GuidePageHeader(icon: page.icon, color: page.iconColor,
                                title: Text(page.title), subtitle: Text(page.subtitle))

                // Feature rows
                VStack(spacing: 14) {
                    ForEach(page.features) { feature in
                        GuideFeatureRow(
                            icon: feature.icon,
                            color: feature.color,
                            title: Text(feature.title),
                            // A suffix is a separate, shared sentence (translated once), joined here.
                            detail: feature.descriptionSuffix.map { Text(feature.description) + Text(verbatim: " ") + Text($0) }
                                ?? Text(feature.description),
                            link: feature.url
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                Spacer()
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Data Models

private struct WelcomePage {
    let icon: String
    let iconColor: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let features: [Feature]
}

private struct Feature: Identifiable {
    let id = UUID()
    let icon: String
    let color: Color
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    var descriptionSuffix: LocalizedStringKey? = nil
    var url: URL? = nil
}
