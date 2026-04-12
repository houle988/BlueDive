import SwiftUI
import SwiftData

// MARK: - Records Wall View

struct RecordsWallView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Dive.timestamp, order: .reverse) private var allDives: [Dive]

    private let prefs = UserPreferences.shared
    @State private var recordsAppeared = false

    // Cached records — computed once in .task, not on every render
    @State private var cachedDeepestDive: Dive?
    @State private var cachedLongestDive: Dive?
    @State private var cachedColdestDive: Dive?
    @State private var cachedWarmestDive: Dive?
    @State private var cachedBestRMVDive: Dive?
    @State private var cachedBestRatedDive: Dive?
    @State private var cachedTotalTime: Int = 0
    @State private var cachedTotalDives: Int = 0
    @State private var cachedUniqueSites: Int = 0
    @State private var cachedUniqueCountries: Int = 0
    @State private var cachedLongestStreak: Int = 0
    @State private var cachedTotalAirConsumed: Double = 0
    @State private var recordsReady = false

    private func computeRecords() {
        guard !allDives.isEmpty else {
            recordsReady = true
            return
        }
        cachedDeepestDive = allDives.max(by: { $0.displayMaxDepth < $1.displayMaxDepth })
        cachedLongestDive = allDives.max(by: { $0.duration < $1.duration })
        cachedColdestDive = allDives.min(by: { $0.displayWaterTemperature < $1.displayWaterTemperature })
        cachedWarmestDive = allDives.max(by: { $0.displayWaterTemperature < $1.displayWaterTemperature })
        cachedBestRMVDive = allDives.filter { $0.calculatedRMV > 0 }.min(by: { $0.calculatedRMV < $1.calculatedRMV })
        cachedBestRatedDive = allDives.first(where: { $0.rating == 5 })
        cachedTotalTime = allDives.map(\.duration).reduce(0, +)
        cachedTotalDives = allDives.count
        cachedUniqueSites = Set(allDives.map { $0.siteName.lowercased() }).count
        cachedUniqueCountries = Set(allDives.compactMap { $0.siteCountry?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }).count
        cachedTotalAirConsumed = allDives.map(\.totalAirConsumption).reduce(0, +)

        let days = Set(allDives.map { Calendar.current.startOfDay(for: $0.timestamp) }).sorted()
        var best = days.isEmpty ? 0 : 1
        var current = 1
        for i in 1..<days.count {
            let diff = Calendar.current.dateComponents([.day], from: days[i - 1], to: days[i]).day ?? 999
            current = diff == 1 ? current + 1 : 1
            best = max(best, current)
        }
        cachedLongestStreak = best
        recordsReady = true
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if allDives.isEmpty {
                        ContentUnavailableView(
                            "No Records",
                            systemImage: "trophy",
                            description: Text("Record your dives to see your personal records here.")
                        )
                        .padding(.top, 60)
                    } else if recordsReady {
                        // Global lifetime stats banner
                        lifetimeBanner
                            .opacity(recordsAppeared ? 1.0 : 0.0)
                            .offset(y: recordsAppeared ? 0 : 20)

                        // Personal Records
                        Text("🏆 Personal Records")
                            .font(.title2.weight(.bold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .opacity(recordsAppeared ? 1.0 : 0.0)

                        // Records Grid
                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible())],
                            spacing: 14
                        ) {
                            if let dive = cachedDeepestDive {
                                RecordCard(
                                    emoji: "🌊",
                                    title: "Deepest",
                                    value: String(format: "%.1f %@", dive.displayMaxDepth, prefs.depthUnit.symbol),
                                    subtitle: dive.siteName,
                                    date: dive.timestamp,
                                    color: .indigo,
                                    dive: dive
                                )
                            }
                            if let dive = cachedLongestDive {
                                RecordCard(
                                    emoji: "⏱️",
                                    title: "Longest",
                                    value: dive.formattedDuration,
                                    subtitle: dive.siteName,
                                    date: dive.timestamp,
                                    color: .green,
                                    dive: dive
                                )
                            }
                            if let dive = cachedColdestDive {
                                RecordCard(
                                    emoji: "🧊",
                                    title: "Coldest Water",
                                    value: prefs.temperatureUnit.formatted(dive.waterTemperature, from: dive.storedTemperatureUnit),
                                    subtitle: dive.siteName,
                                    date: dive.timestamp,
                                    color: .cyan,
                                    dive: dive
                                )
                            }
                            if let dive = cachedWarmestDive {
                                RecordCard(
                                    emoji: "☀️",
                                    title: "Warmest Water",
                                    value: prefs.temperatureUnit.formatted(dive.waterTemperature, from: dive.storedTemperatureUnit),
                                    subtitle: dive.siteName,
                                    date: dive.timestamp,
                                    color: .orange,
                                    dive: dive
                                )
                            }
                            if let dive = cachedBestRMVDive {
                                RecordCard(
                                    emoji: "🧘",
                                    title: "Best RMV",
                                    value: String(format: "%.1f L/min", dive.calculatedRMV),
                                    subtitle: dive.siteName,
                                    date: dive.timestamp,
                                    color: .blue,
                                    dive: dive
                                )
                            }
                            if let dive = cachedBestRatedDive {
                                RecordCard(
                                    emoji: "⭐",
                                    title: "Perfect Dive",
                                    value: "5 stars",
                                    subtitle: dive.siteName,
                                    date: dive.timestamp,
                                    color: .yellow,
                                    dive: dive
                                )
                            }
                        }
                        .padding(.horizontal)
                        .opacity(recordsAppeared ? 1.0 : 0.0)
                        .offset(y: recordsAppeared ? 0 : 20)

                        Spacer(minLength: 30)
                    }
                }
                .padding(.vertical)
                .task(id: allDives.count) {
                    computeRecords()
                    withAnimation(.easeOut(duration: 0.5)) {
                        recordsAppeared = true
                    }
                }
            }
            .navigationTitle("🏅 Records Wall")
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
        }
    }

    // MARK: - Lifetime Banner

    private var lifetimeBanner: some View {
        VStack(spacing: 14) {
            Text("📖 Career Overview")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                LifetimeStat(value: "\(cachedTotalDives)", label: "Dives", icon: "bubbles.and.sparkles", color: .cyan)
                LifetimeStat(
                    value: cachedTotalTime >= 60 ? "\(cachedTotalTime / 60)h \(cachedTotalTime % 60)m" : "\(cachedTotalTime)m",
                    label: "Total Time",
                    icon: "clock.fill",
                    color: .green
                )
                LifetimeStat(value: "\(cachedUniqueSites)", label: "Sites", icon: "mappin.circle.fill", color: .orange)
                LifetimeStat(value: "\(cachedLongestStreak)", label: "Consecutive Days", icon: "flame.fill", color: .red)
                LifetimeStat(
                    value: cachedUniqueCountries > 0 ? "\(cachedUniqueCountries)" : "--",
                    label: "Countries",
                    icon: "globe",
                    color: .purple
                )
                LifetimeStat(
                    value: String(format: "%.0f L", cachedTotalAirConsumed),
                    label: "Air Consumed",
                    icon: "wind",
                    color: .blue
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

// MARK: - Record Card

struct RecordCard: View {
    let emoji: String
    let title: LocalizedStringKey
    let value: String
    let subtitle: String
    let date: Date
    let color: Color
    let dive: Dive

    @State private var showDetail = false
    @State private var cardAppeared = false

    var body: some View {
        Button { showDetail = true } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(emoji)
                        .font(.system(size: 32))
                        .shadow(color: color.opacity(0.6), radius: 8)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(value)
                    .font(.system(.title2, design: .rounded).weight(.black))
                    .foregroundStyle(color)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Divider().background(color.opacity(0.3))

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(date, format: .dateTime.day().month().year())
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.platformSecondaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [color.opacity(0.6), color.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    )
                    .shadow(color: color.opacity(0.15), radius: 6)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(cardAppeared ? 1.0 : 0.85)
        .opacity(cardAppeared ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                cardAppeared = true
            }
        }
        .sheet(isPresented: $showDetail) {
            RecordDetailSheet(emoji: emoji, title: title, value: value, dive: dive, color: color)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Record Detail Sheet

struct RecordDetailSheet: View {
    let emoji: String
    let title: LocalizedStringKey
    let value: String
    let dive: Dive
    let color: Color

    private let prefs = UserPreferences.shared
    @State private var appeared = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                    .padding(.top, 16)
                    .padding(.trailing, 20)
                }
                ZStack {
                    Circle()
                        .fill(RadialGradient(
                            colors: [color.opacity(0.3), color.opacity(0.0)],
                            center: .center, startRadius: 5, endRadius: 80
                        ))
                        .frame(width: 140, height: 140)
                        .scaleEffect(appeared ? 1.0 : 0.5)
                        .opacity(appeared ? 1.0 : 0.0)

                    Circle()
                        .strokeBorder(
                            LinearGradient(colors: [color, color.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 2.5
                        )
                        .frame(width: 140, height: 140)
                        .scaleEffect(appeared ? 1.0 : 0.5)
                        .opacity(appeared ? 1.0 : 0.0)

                    Text(emoji)
                        .font(.system(size: 60))
                        .scaleEffect(appeared ? 1.0 : 0.3)
                        .opacity(appeared ? 1.0 : 0.0)
                }
                .padding(.top, 10)

                VStack(spacing: 8) {
                    Text(value)
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .foregroundStyle(color)

                    Text(title)
                        .font(.title3.weight(.semibold))

                    Text(dive.siteName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(dive.timestamp, format: .dateTime.day().month().year())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color(.systemFill)))
                }

                // Quick stats — unit-aware
                HStack(spacing: 0) {
                    RecordStatCell(
                        value: String(format: "%.1f %@", dive.displayMaxDepth, prefs.depthUnit.symbol),
                        label: "Depth",
                        color: .indigo
                    )
                    Divider().frame(height: 36)
                    RecordStatCell(
                        value: dive.formattedDuration,
                        label: "Duration",
                        color: .green
                    )
                    Divider().frame(height: 36)
                    RecordStatCell(
                        value: prefs.temperatureUnit.formatted(dive.waterTemperature, from: dive.storedTemperatureUnit),
                        label: "Temperature",
                        color: .cyan
                    )
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.platformSecondaryBackground))
                .padding(.horizontal)

                Spacer(minLength: 30)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6).delay(0.1)) {
                appeared = true
            }
        }
    }
}

struct RecordStatCell: View {
    let value: String
    let label: LocalizedStringKey
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.subheadline.weight(.bold)).foregroundStyle(color).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Lifetime Stat Cell

struct LifetimeStat: View {
    let value: String
    let label: LocalizedStringKey
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.system(.body, design: .rounded).weight(.black))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.08))
        )
    }
}
