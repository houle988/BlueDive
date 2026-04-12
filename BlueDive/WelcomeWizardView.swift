import SwiftUI

struct WelcomeWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var currentPage = 0
    @State private var appeared = false

    private let pages: [WelcomePage] = [
        // Page 1: Getting dives in
        WelcomePage(
            icon: "water.waves",
            iconColor: .cyan,
            title: "Welcome to BlueDive",
            subtitle: "Your modern personal dive logbook",
            features: [
                Feature(icon: "doc.badge.plus", color: .blue, title: "Import Formats", description: "Import from BlueDive XML, MacDive XML, or UDDF files — all major dive log formats supported."),
                Feature(icon: "antenna.radiowaves.left.and.right", color: .cyan, title: "Bluetooth Sync", description: "Connect directly to your dive computer via Bluetooth to download dives wirelessly."),
                Feature(icon: "plus.circle", color: .green, title: "Manual Entry", description: "Log dives manually with full control over date, depth, duration, and all details."),
            ]
        ),
        // Page 2: Exploring & analyzing
        WelcomePage(
            icon: "chart.bar.fill",
            iconColor: .orange,
            title: "Explore Your Data",
            subtitle: "Powerful tools to analyze your dives",
            features: [
                Feature(icon: "chart.bar.fill", color: .orange, title: "Dashboard", description: "View statistics, charts, and trends across all your dives."),
                Feature(icon: "map.fill", color: .green, title: "Dive Map", description: "See all your dive sites plotted on an interactive world map."),
                Feature(icon: "calendar", color: .purple, title: "Calendar Heatmap", description: "Visualize your diving activity over time."),
                Feature(icon: "map.fill", color: .teal, title: "Dive Trips", description: "Group your dives into trips and relive your dive travel adventures."),
            ]
        ),
        // Page 3: Search, organize, manage
        WelcomePage(
            icon: "magnifyingglass",
            iconColor: .blue,
            title: "Search & Organize",
            subtitle: "Find any dive in seconds",
            features: [
                Feature(icon: "line.3.horizontal.decrease.circle.fill", color: .orange, title: "Search & Filters", description: "Search by site, buddy, country, or tag. Filter by year, depth, gas type, rating, and more."),
                Feature(icon: "arrow.triangle.merge", color: .indigo, title: "Merge Dives", description: "Combine duplicate dive entries into a single, complete record."),
                Feature(icon: "fish.fill", color: .teal, title: "Marine Sightings", description: "Log fish and marine life spotted during each dive."),
            ]
        ),
        // Page 4: Gear & certifications
        WelcomePage(
            icon: "wrench.and.screwdriver.fill",
            iconColor: .gray,
            title: "Track Your Gear",
            subtitle: "Equipment, tanks & certifications",
            features: [
                Feature(icon: "wrench.and.screwdriver.fill", color: .gray, title: "Equipment", description: "Track your gear with service dates and get automatic maintenance reminders."),
                Feature(icon: "tray.2.fill", color: .brown, title: "Gear Groups", description: "Organize equipment into groups — e.g. tropical kit, cold water setup."),
                Feature(icon: "cylinder.fill", color: .mint, title: "Tank Templates", description: "Save your favorite tank configurations for quick reuse."),
                Feature(icon: "graduationcap.fill", color: .blue, title: "Certifications", description: "Store diving certifications and get expiry alerts."),
                Feature(icon: "medal.fill", color: .yellow, title: "Records Wall", description: "See your personal bests — deepest dive, longest bottom time, and more."),
            ]
        ),
        // Page 5: Sync, export, profile, settings
        WelcomePage(
            icon: "gearshape.fill",
            iconColor: .cyan,
            title: "Your Data, Your Way",
            subtitle: "Sync, export & personalize",
            features: [
                Feature(icon: "icloud.fill", color: .cyan, title: "iCloud Sync", description: "Your dives sync automatically across all your Apple devices."),
                Feature(icon: "square.and.arrow.up", color: .indigo, title: "Export Anytime", description: "Export your logbook to XML, UDDF or PDF format whenever you need."),
                Feature(icon: "person.circle.fill", color: .pink, title: "Diver Profile", description: "Keep your diver info, emergency contacts, and insurance details handy."),
                Feature(icon: "gearshape.fill", color: .gray, title: "Settings", description: "Choose your units (metric/imperial), appearance, language, and notification preferences."),
            ]
        ),
    ]

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [Color.platformBackground, Color.cyan.opacity(0.06), Color.platformBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Page content
                #if os(iOS)
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        pageView(page)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.3), value: currentPage)
                #else
                pageView(pages[currentPage])
                    .id(currentPage)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: currentPage)
                #endif

                // Bottom controls
                VStack(spacing: 20) {
                    Divider().opacity(0.3).padding(.horizontal, 24)
                    // Page indicators
                    HStack(spacing: 8) {
                        ForEach(0..<pages.count, id: \.self) { index in
                            Capsule()
                                .fill(index == currentPage ? Color.cyan : Color.primary.opacity(0.2))
                                .frame(width: index == currentPage ? 24 : 8, height: 8)
                                .animation(.spring(response: 0.3), value: currentPage)
                        }
                    }

                    // Buttons
                    HStack {
                        if currentPage > 0 {
                            Button {
                                withAnimation { currentPage -= 1 }
                            } label: {
                                Text("Back")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 12)
                            }
                            .transition(.opacity)
                        }

                        Spacer()

                        Button {
                            if currentPage < pages.count - 1 {
                                withAnimation { currentPage += 1 }
                            } else {
                                hasCompletedOnboarding = true
                                dismiss()
                            }
                        } label: {
                            Text(currentPage < pages.count - 1 ? "Next" : "Get Started")
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 12)
                                .background(
                                    Capsule().fill(Color.cyan)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)

                    // Skip
                    if currentPage < pages.count - 1 {
                        Button {
                            hasCompletedOnboarding = true
                            dismiss()
                        } label: {
                            Text("Skip")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 40)
                .padding(.horizontal, 8)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 20)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                appeared = true
            }
        }
        #if os(macOS)
        .frame(minWidth: 650, idealWidth: 750, maxWidth: 900, minHeight: 700, idealHeight: 800, maxHeight: 950)
        #endif
    }

    // MARK: - Page View

    private func pageView(_ page: WelcomePage) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 20)

                // Icon
                ZStack {
                    Circle()
                        .fill(page.iconColor.opacity(0.12))
                        .frame(width: 90, height: 90)

                    Image(systemName: page.icon)
                        .font(.system(size: 40))
                        .foregroundStyle(page.iconColor)
                }

                // Title & subtitle
                VStack(spacing: 6) {
                    Text(page.title)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)

                    Text(page.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Feature rows
                VStack(spacing: 14) {
                    ForEach(page.features) { feature in
                        featureRow(feature)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                Spacer()
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Feature Row

    private func featureRow(_ feature: Feature) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(feature.color.opacity(0.12))
                    .frame(width: 42, height: 42)

                Image(systemName: feature.icon)
                    .font(.body)
                    .foregroundStyle(feature.color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)

                Text(feature.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
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
}
