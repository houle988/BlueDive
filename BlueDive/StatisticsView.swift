import SwiftUI
import SwiftData
import Charts

struct StatisticsView: View {
    @Query(sort: \Dive.timestamp, order: .reverse) private var dives: [Dive]
    @State private var prefs = UserPreferences.shared
    @Environment(\.dismiss) private var dismiss
    @State private var appeared = false

    // Cached statistics — computed once in .task, not on every render
    @State private var cachedTotalDives: Int = 0
    @State private var cachedFormattedTotalTime: String = "0h 0m"
    @State private var cachedMaxDepthEver: Double = 0
    @State private var cachedAvgDepth: Double = 0
    @State private var cachedTopSites: [(name: String, location: String, country: String, count: Int)] = []
    @State private var cachedDivesPerMonth: [(month: String, count: Int)] = []
    @State private var cachedTotalSpeciesSeen: Int = 0
    @State private var cachedCountries: Int = 0
    @State private var cachedMaxTemp: String = "—"
    @State private var cachedMinTemp: String = "—"
    @State private var statsReady = false

    private func computeStats() {
        cachedTotalDives = dives.count
        let totalMin = dives.reduce(0) { $0 + $1.duration }
        cachedFormattedTotalTime = "\(totalMin / 60)h \(totalMin % 60)m"
        cachedMaxDepthEver = dives.map(\.maxDepth).max() ?? 0
        cachedAvgDepth = dives.isEmpty ? 0 : dives.map(\.averageDepth).reduce(0, +) / Double(dives.count)
        cachedCountries = Set(dives.compactMap { $0.siteCountry }.filter { !$0.isEmpty }).count

        let grouped = Dictionary(grouping: dives) { $0.siteName }
        cachedTopSites = grouped.map { (name, dives) -> (name: String, location: String, country: String, count: Int) in
            let firstDive = dives.first(where: { $0.siteName == name })
            return (name, firstDive?.location ?? "", firstDive?.siteCountry ?? "", dives.count)
        }
        .sorted { $0.count > $1.count }
        .prefix(5)
        .map { $0 }

        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        let monthGrouped = Dictionary(grouping: dives) { dive -> DateComponents in
            calendar.dateComponents([.year, .month], from: dive.timestamp)
        }
        cachedDivesPerMonth = monthGrouped.map { (components, dives) -> (date: Date, month: String, count: Int) in
            let date = calendar.date(from: components) ?? Date()
            return (date, formatter.string(from: date), dives.count)
        }
        .sorted { $0.date < $1.date }
        .suffix(6)
        .map { (month: $0.month, count: $0.count) }

        cachedTotalSpeciesSeen = Set(dives.flatMap { ($0.seenFish ?? []).map { $0.name } }).count

        let tempSymbol = UserPreferences.shared.temperatureUnit.symbol
        let warmDives = dives.filter { $0.waterTemperature != 0 }
        if let maxTemp = warmDives.map({ $0.displayWaterTemperature }).max() {
            cachedMaxTemp = "\(Int(maxTemp.rounded()))\(tempSymbol)"
        }
        let coldDives = dives.filter { $0.minTemperature != 0 }
        if let minTemp = coldDives.map({ $0.displayMinTemperature }).min() {
            cachedMinTemp = "\(Int(minTemp.rounded()))\(tempSymbol)"
        }

        statsReady = true
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if !statsReady {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            // Hero stats row
                            heroStatsRow
                                .opacity(appeared ? 1.0 : 0.0)
                                .offset(y: appeared ? 0 : 20)

                            // Activity chart
                            divesChartSection
                                .opacity(appeared ? 1.0 : 0.0)
                                .offset(y: appeared ? 0 : 20)

                            // Depth & temperature highlights
                            depthTemperatureSection
                                .opacity(appeared ? 1.0 : 0.0)
                                .offset(y: appeared ? 0 : 20)

                            // Favourite sites
                            topSitesSection
                                .opacity(appeared ? 1.0 : 0.0)
                                .offset(y: appeared ? 0 : 20)

                            // Remaining stats
                            moreStatsGrid
                                .opacity(appeared ? 1.0 : 0.0)
                                .offset(y: appeared ? 0 : 20)
                        }
                        .padding(.bottom, 30)
                    }
                }
            }
            .navigationTitle("Statistics")
            #if os(macOS)
            .frame(minWidth: 600, idealWidth: 750, maxWidth: 1000, minHeight: 500, idealHeight: 700, maxHeight: 900)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.cyan)
                }
            }
            .background(Color.platformBackground.ignoresSafeArea())
            .task(id: dives.count) {
                computeStats()
                withAnimation(.easeOut(duration: 0.6)) {
                    appeared = true
                }
            }
        }
    }

    // MARK: - Hero Stats Row

    private var heroStatsRow: some View {
        HStack(spacing: 12) {
            StatisticsHeroCard(
                value: "\(cachedTotalDives)",
                label: "Dives",
                icon: "figure.open.water.swim",
                color: .cyan
            )
            StatisticsHeroCard(
                value: cachedFormattedTotalTime,
                label: "Bottom Time",
                icon: "clock.fill",
                color: .green
            )
            StatisticsHeroCard(
                value: "\(cachedCountries)",
                label: "Countries",
                icon: "globe",
                color: .purple
            )
        }
        .padding(.horizontal)
    }

    // MARK: - Activity Chart

    private var divesChartSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(.cyan)
                Text("Recent Activity")
                    .font(.headline)
            }
            .padding(.horizontal, 4)

            if !cachedDivesPerMonth.isEmpty {
                Chart(cachedDivesPerMonth, id: \.month) { item in
                    BarMark(
                        x: .value("Month", item.month),
                        y: .value("Dives", item.count)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan, .cyan.opacity(0.4)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .cornerRadius(6)
                    .annotation(position: .top, spacing: 4) {
                        Text("\(item.count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.cyan)
                    }
                }
                .frame(height: 180)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                            .foregroundStyle(Color.primary.opacity(0.1))
                        AxisValueLabel()
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let month = value.as(String.self) {
                                Text(month)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .chartPlotStyle { plotArea in
                    plotArea
                        .background(Color.primary.opacity(0.02))
                        .cornerRadius(8)
                }
            } else {
                Text("No dive data to display")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.platformSecondaryBackground)
        )
        .padding(.horizontal)
    }

    // MARK: - Depth & Temperature Section

    private var depthTemperatureSection: some View {
        HStack(spacing: 12) {
            // Depth card
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "arrow.down.to.line")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    Spacer()
                    Text("Depth")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 6) {
                    Text(prefs.depthUnit.formatted(cachedMaxDepthEver))
                        .font(.system(.title, design: .rounded))
                        .fontWeight(.black)
                        .foregroundStyle(.primary)
                    Text("Max")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.blue.opacity(0.8))

                    Divider()
                        .background(Color.blue.opacity(0.3))
                        .padding(.horizontal, 8)

                    Text(prefs.depthUnit.formatted(cachedAvgDepth))
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                    Text("Average")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.blue.opacity(0.6))
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.platformSecondaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.blue.opacity(0.5), .blue.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
            )

            // Temperature card
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "thermometer.medium")
                        .font(.title3)
                        .foregroundStyle(.orange)
                    Spacer()
                    Text("Temperature")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 6) {
                    Text(cachedMaxTemp)
                    .font(.system(.title, design: .rounded))
                    .fontWeight(.black)
                    .foregroundStyle(.primary)
                    Text("Warmest")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange.opacity(0.8))

                    Divider()
                        .background(Color.orange.opacity(0.3))
                        .padding(.horizontal, 8)

                    Text(cachedMinTemp)
                    .font(.system(.title3, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)
                    Text("Coldest")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.cyan.opacity(0.8))
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.platformSecondaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.orange.opacity(0.5), .orange.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
            )
        }
        .padding(.horizontal)
    }

    // MARK: - Top Sites

    private var topSitesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(.cyan)
                Text("Favourite Sites")
                    .font(.headline)
            }
            .padding(.horizontal, 4)

            if cachedTopSites.isEmpty {
                Text("No sites recorded")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(cachedTopSites.enumerated()), id: \.offset) { index, site in
                        HStack(spacing: 14) {
                            // Rank badge
                            ZStack {
                                Circle()
                                    .fill(
                                        index == 0
                                            ? LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                                            : LinearGradient(colors: [.white.opacity(0.15), .white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                    )
                                    .frame(width: 32, height: 32)
                                Text("\(index + 1)")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(index == 0 ? .primary : .secondary)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(site.name)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                HStack(spacing: 4) {
                                    if !site.location.isEmpty && site.location != "Inconnu" && site.location != String(localized: "Unknown site") {
                                        Text(site.location)
                                    }
                                    if !site.country.isEmpty {
                                        if !site.location.isEmpty && site.location != "Inconnu" && site.location != String(localized: "Unknown site") {
                                            Text("·")
                                        }
                                        Text(site.country)
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            }

                            Spacer()

                            // Dive count pill
                            Text("\(site.count)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.cyan)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(.cyan.opacity(0.15))
                                )
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 4)

                        if index < cachedTopSites.count - 1 {
                            Divider()
                                .background(Color.primary.opacity(0.08))
                        }
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.platformSecondaryBackground)
        )
        .padding(.horizontal)
    }

    // MARK: - More Stats Grid

    private var moreStatsGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(.cyan)
                Text("At a Glance")
                    .font(.headline)
            }
            .padding(.horizontal, 4)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                StatisticsCard(
                    title: "Species Seen",
                    value: "\(cachedTotalSpeciesSeen)",
                    icon: "fish.fill",
                    color: .orange
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.platformSecondaryBackground)
        )
        .padding(.horizontal)
    }
}

// MARK: - Hero Card

struct StatisticsHeroCard: View {
    let value: String
    let label: LocalizedStringKey
    let icon: String
    let color: Color

    @State private var cardAppeared = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(color.opacity(0.15))
                )
                .scaleEffect(cardAppeared ? 1.0 : 0.5)

            Text(value)
                .font(.system(.title2, design: .rounded))
                .fontWeight(.black)
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.platformSecondaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(
                            LinearGradient(
                                colors: [color.opacity(0.4), color.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
        )
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                cardAppeared = true
            }
        }
    }
}

// MARK: - Stat Card

struct StatisticsCard: View {
    let title: LocalizedStringKey
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

#Preview {
    StatisticsView()
        .modelContainer(for: Dive.self, inMemory: true)
}
