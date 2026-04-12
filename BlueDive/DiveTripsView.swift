import SwiftUI
import SwiftData

// MARK: - Dive Trip Model

/// A trip is a lightweight value type derived from dives — no extra SwiftData model needed.
struct DiveTrip: Identifiable {
    let id: UUID = UUID()
    let name: String
    let location: String
    let dives: [Dive]

    var startDate: Date { dives.map(\.timestamp).min() ?? .now }
    var endDate: Date   { dives.map(\.timestamp).max() ?? .now }

    var totalDives: Int        { dives.count }
    var totalMinutes: Int      { dives.map(\.duration).reduce(0, +) }
    var deepestDive: Dive?     { dives.max(by: { $0.maxDepth < $1.maxDepth }) }
    var longestDive: Dive?     { dives.max(by: { $0.duration < $1.duration }) }
    var bestRatedDive: Dive?   { dives.max(by: { $0.rating < $1.rating }) }
    var averageRating: Double  {
        let rated = dives.filter { $0.rating > 0 }
        guard !rated.isEmpty else { return 0 }
        return Double(rated.map(\.rating).reduce(0, +)) / Double(rated.count)
    }
    var averageMaxDepth: Double {
        guard !dives.isEmpty else { return 0 }
        return dives.map(\.maxDepth).reduce(0, +) / Double(dives.count)
    }
    var averageRMV: Double {
        let valid = dives.filter { $0.calculatedRMV > 0 }
        guard !valid.isEmpty else { return 0 }
        return valid.map(\.calculatedRMV).reduce(0, +) / Double(valid.count)
    }
    var formattedTotalTime: String {
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
    var durationDays: Int {
        Calendar.current.dateComponents([.day], from: startDate, to: endDate).day.map { $0 + 1 } ?? 1
    }
    var uniqueSites: Int {
        Set(dives.map { $0.siteName.lowercased() }).count
    }
    var photos: [Data] {
        dives.flatMap { $0.photosData ?? [] }
    }
}

// MARK: - Trip Builder

struct TripBuilder {
    /// Groups dives into trips: dives within 7 days of each other at the same location
    /// are considered one trip.
    static func buildTrips(from dives: [Dive]) -> [DiveTrip] {
        guard !dives.isEmpty else { return [] }

        let sorted = dives.sorted { $0.timestamp < $1.timestamp }
        var trips: [DiveTrip] = []
        var currentGroup: [Dive] = []

        for dive in sorted {
            if currentGroup.isEmpty {
                currentGroup.append(dive)
            } else {
                let lastDive = currentGroup.last!
                let daysBetween = Calendar.current.dateComponents(
                    [.day],
                    from: lastDive.timestamp,
                    to: dive.timestamp
                ).day ?? 999

                if daysBetween <= 7 {
                    currentGroup.append(dive)
                } else {
                    trips.append(makeTrip(from: currentGroup))
                    currentGroup = [dive]
                }
            }
        }
        if !currentGroup.isEmpty {
            trips.append(makeTrip(from: currentGroup))
        }

        return trips.sorted { $0.startDate > $1.startDate } // most recent first
    }

    private static func makeTrip(from dives: [Dive]) -> DiveTrip {
        // Use the most common location as trip name
        let locationCounts = Dictionary(grouping: dives, by: \.location)
            .mapValues(\.count)
        let topLocation = locationCounts.max(by: { $0.value < $1.value })?.key ?? dives.first?.location ?? "Unknown"
        let siteCounts = Dictionary(grouping: dives, by: \.siteName)
            .mapValues(\.count)
        let topSite = siteCounts.max(by: { $0.value < $1.value })?.key ?? topLocation

        let name: String
        if let year = Calendar.current.dateComponents([.year], from: dives.first!.timestamp).year {
            name = "\(topLocation) \(year)"
        } else {
            name = topLocation
        }

        return DiveTrip(name: name, location: topSite, dives: dives)
    }
}

// MARK: - Dive Trips View

struct DiveTripsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Dive.timestamp, order: .reverse) private var allDives: [Dive]
    @State private var selectedTrip: DiveTrip? = nil
    @State private var prefs = UserPreferences.shared
    @State private var tripsAppeared = false

    private var trips: [DiveTrip] {
        TripBuilder.buildTrips(from: Array(allDives))
    }

    var body: some View {
        NavigationStack {
            Group {
                if trips.isEmpty {
                    ContentUnavailableView(
                        "No Trips",
                        systemImage: "airplane.departure",
                        description: Text("Your dives will automatically organize into trips here.")
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            // Summary banner
                            TripsSummaryBanner(trips: trips, dives: allDives)
                                .padding(.horizontal)
                                .opacity(tripsAppeared ? 1.0 : 0.0)
                                .offset(y: tripsAppeared ? 0 : 20)

                            ForEach(Array(trips.enumerated()), id: \.element.id) { index, trip in
                                TripCard(trip: trip, prefs: prefs)
                                    .padding(.horizontal)
                                    .onTapGesture { selectedTrip = trip }
                                    .opacity(tripsAppeared ? 1.0 : 0.0)
                                    .offset(y: tripsAppeared ? 0 : 20)
                            }

                            Spacer(minLength: 30)
                        }
                        .padding(.vertical)
                        .onAppear {
                            withAnimation(.easeOut(duration: 0.5)) {
                                tripsAppeared = true
                            }
                        }
                    }
                }
            }
            .navigationTitle("✈️ My Trips")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            #if os(macOS)
            .frame(minWidth: 600, idealWidth: 750, maxWidth: 1000, minHeight: 500, idealHeight: 700, maxHeight: 900)
            #endif
            .background(Color.platformBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.cyan)
                }
            }
            .sheet(item: $selectedTrip) { trip in
                TripDetailSheet(trip: trip, prefs: prefs)
            }
        }
    }
}

// MARK: - Trips Summary Banner

struct TripsSummaryBanner: View {
    let trips: [DiveTrip]
    let dives: [Dive]

    private var totalCountries: Int {
        Set(dives.compactMap { $0.siteCountry }).count
    }
    private var totalLocations: Int {
        Set(dives.map { $0.location.lowercased() }).count
    }

    var body: some View {
        HStack(spacing: 0) {
            TripSummaryStat(value: "\(trips.count)", label: "Trips", icon: "airplane", color: .cyan)
            Divider().frame(height: 40).background(Color.primary.opacity(0.15))
            TripSummaryStat(value: "\(totalLocations)", label: "Destinations", icon: "mappin.circle.fill", color: .orange)
            Divider().frame(height: 40).background(Color.primary.opacity(0.15))
            TripSummaryStat(value: "\(dives.count)", label: "Dives", icon: "bubbles.and.sparkles", color: .blue)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.platformSecondaryBackground)
        )
    }
}

struct TripSummaryStat: View {
    let value: String
    let label: LocalizedStringKey
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            Text(value).font(.title2.weight(.black)).foregroundStyle(.primary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Trip Card

struct TripCard: View {
    let trip: DiveTrip
    let prefs: UserPreferences

    private var coverPhoto: PlatformImage? {
        guard let data = trip.photos.first else { return nil }
        return PlatformImage(data: data)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Cover photo or gradient header
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let img = coverPhoto {
                        Image(platformImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LinearGradient(
                            colors: tripGradient(for: trip.location),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
                .frame(height: 140)
                .clipped()

                // Overlay gradient for text readability
                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(trip.name)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)

                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .font(.caption)
                        Text(tripDateRange(trip))
                            .font(.caption)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                }
                .padding(12)
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))

            // Stats row
            HStack(spacing: 0) {
                TripStatMini(icon: "bubbles.and.sparkles", value: "\(trip.totalDives)", label: "Dives")
                Divider().frame(height: 30)
                TripStatMini(icon: "timer", value: trip.formattedTotalTime, label: "Total")
                Divider().frame(height: 30)
                TripStatMini(icon: "arrow.down", value: prefs.depthUnit.formatted(trip.deepestDive?.maxDepth ?? 0, decimals: 0), label: "Max")
                Divider().frame(height: 30)
                TripStatMini(icon: "mappin", value: "\(trip.uniqueSites)", label: "Sites")
            }
            .padding(.vertical, 10)
            .background(Color.platformSecondaryBackground)

            // Star rating row
            if trip.averageRating > 0 {
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: Double(star) <= trip.averageRating ? "star.fill" : "star")
                            .font(.caption)
                            .foregroundStyle(Double(star) <= trip.averageRating ? .yellow : .secondary)
                    }
                    Text(String(format: "%.1f / 5", trip.averageRating))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.platformSecondaryBackground)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
            } else {
                Color.platformSecondaryBackground
                    .frame(height: 2)
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }

    private func tripGradient(for location: String) -> [Color] {
        let gradients: [[Color]] = [
            [.blue, .cyan],
            [.indigo, .blue],
            [.teal, .green],
            [.purple, .indigo],
            [.cyan, .teal],
        ]
        let index = abs(location.hashValue) % gradients.count
        return gradients[index]
    }

    private func tripDateRange(_ trip: DiveTrip) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        if Calendar.current.isDate(trip.startDate, equalTo: trip.endDate, toGranularity: .day) {
            formatter.dateFormat = "d MMM yyyy"
            return formatter.string(from: trip.startDate)
        }
        let start = formatter.string(from: trip.startDate)
        formatter.dateFormat = "d MMM yyyy"
        let end = formatter.string(from: trip.endDate)
        return "\(start) – \(end)"
    }
}

struct TripStatMini: View {
    let icon: String
    let value: String
    let label: LocalizedStringKey

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.bold)).monospacedDigit()
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Trip Detail Sheet

struct TripDetailSheet: View {
    let trip: DiveTrip
    let prefs: UserPreferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Hero stats
                    heroSection

                    // Highlights
                    if trip.deepestDive != nil || trip.longestDive != nil || trip.bestRatedDive != nil {
                        highlightsSection
                    }

                    // All dives list
                    divesListSection
                }
                .padding()
            }
            .navigationTitle(trip.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            .frame(minWidth: 550, idealWidth: 650, maxWidth: 850, minHeight: 500, idealHeight: 650, maxHeight: 900)
            #endif
            .background(Color.platformBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.cyan)
                }
            }
        }

    }

    private var heroSection: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            TripHeroStat(value: "\(trip.totalDives)", label: "Dives", icon: "bubbles.and.sparkles.fill", color: .cyan)
            TripHeroStat(value: trip.formattedTotalTime, label: "Underwater", icon: "timer", color: .green)
            TripHeroStat(value: "\(trip.durationDays)d", label: "Trip Duration", icon: "calendar", color: .orange)
            TripHeroStat(value: prefs.depthUnit.formatted(trip.averageMaxDepth), label: "Avg. Depth", icon: "arrow.down.circle", color: .blue)
            TripHeroStat(value: "\(trip.uniqueSites)", label: "Sites", icon: "mappin.and.ellipse", color: .purple)
            if trip.averageRMV > 0 {
                TripHeroStat(value: String(format: "%.1f L/m", trip.averageRMV), label: "Avg. RMV", icon: "wind", color: .teal)
            } else {
                TripHeroStat(value: String(format: "%.1f★", trip.averageRating), label: "Avg. Rating", icon: "star.fill", color: .yellow)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.platformSecondaryBackground))
    }

    private var highlightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("🏆 Highlights")
                .font(.headline)

            VStack(spacing: 10) {
                if let d = trip.deepestDive {
                    HighlightRow(icon: "arrow.down.circle.fill", color: .indigo,
                                 title: "Deepest Dive",
                                 subtitle: "\(d.siteName) — \(prefs.depthUnit.formatted(d.maxDepth))")
                }
                if let d = trip.longestDive {
                    HighlightRow(icon: "timer", color: .green,
                                 title: "Longest Dive",
                                 subtitle: "\(d.siteName) — \(d.formattedDuration)")
                }
                if let d = trip.bestRatedDive, d.rating > 0 {
                    HighlightRow(icon: "star.fill", color: .yellow,
                                 title: "Best Dive",
                                 subtitle: "\(d.siteName) — \(d.rating)★")
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.platformSecondaryBackground))
    }

    private var divesListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("🤿 All Dives (\(trip.totalDives))")
                .font(.headline)

            ForEach(trip.dives.sorted { $0.timestamp < $1.timestamp }) { dive in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(dive.siteName)
                            .font(.subheadline.weight(.semibold))
                        Text(dive.timestamp, format: .dateTime.day().month().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(prefs.depthUnit.formatted(dive.maxDepth))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.cyan)
                        Text(dive.formattedDuration)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if dive.rating > 0 {
                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { star in
                                Image(systemName: star <= dive.rating ? "star.fill" : "star")
                                    .font(.system(size: 8))
                                    .foregroundStyle(star <= dive.rating ? .yellow : .secondary)
                            }
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.platformSecondaryBackground.opacity(0.6)))
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.platformSecondaryBackground))
    }
}

// MARK: - Supporting Views

struct TripHeroStat: View {
    let value: String
    let label: LocalizedStringKey
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(color)
            Text(value).font(.title3.weight(.black)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.08)))
    }
}

struct HighlightRow: View {
    let icon: String
    let color: Color
    let title: LocalizedStringKey
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.15)).frame(width: 36, height: 36)
                Image(systemName: icon).foregroundStyle(color).font(.system(size: 15))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.platformTertiaryBackground))
    }
}
