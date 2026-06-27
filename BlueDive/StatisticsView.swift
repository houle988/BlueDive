import SwiftUI
import SwiftData
import Charts

struct StatisticsView: View {
    @Query(sort: \Dive.timestamp, order: .reverse) private var allDives: [Dive]
    @Query(sort: \Gear.name) private var allGear: [Gear]
    @Query(sort: \Certification.issueDate, order: .reverse) private var allCertifications: [Certification]
    @State private var prefs = UserPreferences.shared
    @Environment(\.dismiss) private var dismiss
    @State private var appeared = false

    // Cached statistics — computed once in .task, not on every render
    @State private var cachedMaxDepthEver: Double = 0
    @State private var cachedAvgDepth: Double = 0
    @State private var cachedTopSites: [(name: String, location: String, country: String, count: Int)] = []
    @State private var cachedDivesPerMonth: [(month: String, count: Int)] = []
    @State private var cachedTotalSpeciesSeen: Int = 0
    @State private var cachedMaxTemp: String = "—"
    @State private var cachedMinTemp: String = "—"
    @State private var statsReady = false
    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""
    @State private var selectedSiteName: String? = nil

    // MARK: - Filter State
    @State private var showFilterSheet = false
    @State private var filterYear: Int? = nil
    @State private var filterYearNegate: Bool = false
    @State private var filterGasType: String? = nil
    @State private var filterGasTypeNegate: Bool = false
    @State private var filterMinDepth: Double = 0
    @State private var filterMaxDepth: Double = 0
    @State private var filterMinRating: Int = 0
    @State private var filterCountry: String? = nil
    @State private var filterCountryNegate: Bool = false
    @State private var filterDiveType: String? = nil
    @State private var filterDiveTypeNegate: Bool = false
    @State private var filterTag: String? = nil
    @State private var filterMarineLife: [String] = []
    @State private var filterMarineLifeMode: FilterMarineLifeMode = .any
    @State private var filterSortOrder: ContentView.DiveSortOrder = .dateDesc
    @State private var cachedDeepestDive: Dive? = nil
    @State private var cachedWarmestDive: Dive? = nil
    @State private var cachedColdestDive: Dive? = nil
    @State private var cachedSortedDives: [Dive] = []
    @State private var selectedDive: Dive? = nil
    @State private var cachedAvgDuration: Int = 0
    @State private var cachedLongestDive: Dive? = nil
    @State private var cachedShortestDive: Dive? = nil
    @State private var cachedAvgSurfaceInterval: String = "—"
    @State private var cachedLongestSIDive: Dive? = nil
    @State private var cachedLongestSIFormatted: String = "—"
    @State private var cachedShortestSIDive: Dive? = nil
    @State private var cachedShortestSIFormatted: String = "—"
    @State private var cachedMinDepth: Double = 0
    @State private var cachedShallowestDive: Dive? = nil
    @State private var cachedAvgTemp: String = "—"
    @State private var cachedAvgRMV: String = "—"
    @State private var cachedBestRMVDive: Dive? = nil
    @State private var cachedWorstRMVDive: Dive? = nil
    @State private var cachedAvgSAC: String = "—"
    @State private var cachedBestSACDive: Dive? = nil
    @State private var cachedWorstSACDive: Dive? = nil
    @State private var cachedDiveCount: Int = 0
    @State private var cachedTotalTimeFormatted: String = "—"
    @State private var cachedUniqueSites: Int = 0
    @State private var cachedLongestStreak: Int = 0
    @State private var cachedUniqueCountries: Int = 0
    @State private var cachedTotalAirConsumed: Double = 0

    @Environment(\.locale) private var locale

    private var uniqueDivers: [String] { DiverFilter.uniqueDivers(in: allDives, gear: allGear, certifications: allCertifications) }

    private var filteredDives: [Dive] {
        DiverFilter.applyDiveFilters(
            to: DiverFilter.apply(selectedDiver, to: allDives),
            year: filterYear, yearNegate: filterYearNegate,
            gasType: filterGasType, gasTypeNegate: filterGasTypeNegate,
            minDepth: filterMinDepth, maxDepth: filterMaxDepth,
            minRating: filterMinRating,
            country: filterCountry, countryNegate: filterCountryNegate,
            diveType: filterDiveType, diveTypeNegate: filterDiveTypeNegate,
            tag: filterTag,
            marineLife: filterMarineLife, marineLifeMode: filterMarineLifeMode
        )
    }

    private var diverDives: [Dive] { DiverFilter.apply(selectedDiver, to: allDives) }

    private var availableYears: [Int] {
        Array(Set(diverDives.compactMap { Calendar.current.dateComponents([.year], from: $0.timestamp).year })).sorted(by: >)
    }
    private var availableGasTypes: [String] { Array(Set(diverDives.map { $0.gasType })).sorted() }
    private var availableCountries: [String] { Array(Set(diverDives.compactMap { $0.siteCountry }.filter { !$0.isEmpty })).sorted() }
    private var availableDiveTypes: [String] {
        var types = Set<String>()
        for dive in diverDives {
            dive.diveTypes?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.forEach { types.insert($0) }
        }
        return types.sorted()
    }
    private var availableTags: [String] {
        var tags = Set<String>()
        for dive in diverDives {
            dive.tags?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.forEach { tags.insert($0) }
        }
        return tags.sorted()
    }
    private var availableMarineLife: [String] {
        var species = Set<String>()
        for dive in diverDives { dive.seenFish?.forEach { s in let n = s.name.trimmingCharacters(in: .whitespaces); if !n.isEmpty { species.insert(n) } } }
        return species.sorted()
    }

    private var activeFilterCount: Int {
        var count = 0
        if filterYear != nil            { count += 1 }
        if filterGasType != nil         { count += 1 }
        if filterMinDepth > 0 || filterMaxDepth > 0 { count += 1 }
        if filterMinRating > 0          { count += 1 }
        if filterCountry != nil         { count += 1 }
        if filterDiveType != nil        { count += 1 }
        if filterTag != nil             { count += 1 }
        if !filterMarineLife.isEmpty    { count += 1 }
        if filterMarineLifeMode != .any { count += 1 }
        return count
    }

    private var filterTaskId: String {
        "\(allDives.count):\(selectedDiver):\(filterYear ?? -1):\(filterYearNegate):\(filterGasType ?? ""):\(filterGasTypeNegate):\(filterMinDepth):\(filterMaxDepth):\(filterMinRating):\(filterCountry ?? ""):\(filterCountryNegate):\(filterDiveType ?? ""):\(filterDiveTypeNegate):\(filterTag ?? ""):\(filterMarineLife.joined(separator: ",")):\(filterMarineLifeMode):\(locale.identifier)"
    }

    private func computeStats(_ dives: [Dive], locale: Locale) async {
        // --- Lightweight scalars (always cheap) ---
        let totalMin = dives.reduce(0) { $0 + $1.duration }
        let timeFormatter = DateComponentsFormatter()
        timeFormatter.allowedUnits = totalMin >= 60 ? [.hour, .minute] : [.minute]
        timeFormatter.unitsStyle = .abbreviated
        var timeFormatterCal = Calendar(identifier: .gregorian)
        timeFormatterCal.locale = locale
        timeFormatter.calendar = timeFormatterCal
        let totalTimeFormatted = timeFormatter.string(from: TimeInterval(totalMin * 60)) ?? "\(totalMin)m"
        let maxDepthEver = dives.map(\.displayMaxDepth).max() ?? 0
        let avgDepth = dives.isEmpty ? 0 : dives.map(\.displayAverageDepth).reduce(0, +) / Double(dives.count)
        let sortedDives = dives.sorted { $0.timestamp > $1.timestamp }

        let grouped = Dictionary(grouping: dives) { $0.siteName }
        let topSites: [(name: String, location: String, country: String, count: Int)] = grouped.map { (name, group) in
            let firstDive = group.first
            return (name, firstDive?.location ?? "", firstDive?.siteCountry ?? "", group.count)
        }
        .sorted { $0.count > $1.count }
        .prefix(5)
        .map { $0 }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = TimeZone.current
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "MMMyyyy", options: 0, locale: locale) ?? "MMM yyyy"
        let monthGrouped = Dictionary(grouping: dives) { dive -> DateComponents in
            calendar.dateComponents([.year, .month], from: dive.timestamp)
        }
        let divesPerMonth: [(month: String, count: Int)] = monthGrouped.map { (components, group) -> (date: Date, month: String, count: Int) in
            let date = calendar.date(from: components) ?? Date()
            return (date, formatter.string(from: date), group.count)
        }
        .sorted { $0.date < $1.date }
        .suffix(6)
        .map { (month: $0.month, count: $0.count) }

        // --- Career overview scalars ---
        let uniqueSites = Set(dives.map { $0.siteName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }).count
        let uniqueCountries = Set(dives.compactMap { $0.siteCountry?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }).count
        let divingDays = Set(dives.map { calendar.startOfDay(for: $0.timestamp) }).sorted()
        var longestStreak = divingDays.isEmpty ? 0 : 1
        var currentStreak = 1
        for i in 1..<divingDays.count {
            let diff = calendar.dateComponents([.day], from: divingDays[i - 1], to: divingDays[i]).day ?? 999
            currentStreak = diff == 1 ? currentStreak + 1 : 1
            longestStreak = max(longestStreak, currentStreak)
        }

        if Task.isCancelled { return }
        await Task.yield()
        if Task.isCancelled { return }

        // --- Potentially heavy: species set and air consumption across all dives ---
        var speciesNames = Set<String>()
        var totalAirConsumed = 0.0
        let yieldInterval = 100
        for (idx, dive) in dives.enumerated() {
            if let fish = dive.seenFish {
                for entry in fish { speciesNames.insert(entry.name) }
            }
            totalAirConsumed += dive.totalAirConsumption
            if idx % yieldInterval == yieldInterval - 1 {
                await Task.yield()
                if Task.isCancelled { return }
            }
        }
        let totalSpeciesSeen = speciesNames.count

        // --- Temperature extremes ---
        let tempSymbol = prefs.temperatureUnit.symbol
        let warmDives = dives.filter { $0.waterTemperature != 0 }
        let maxTempStr: String
        if let maxTemp = warmDives.map({ $0.displayWaterTemperature }).max() {
            maxTempStr = "\(Int(maxTemp.rounded()))\(tempSymbol)"
        } else {
            maxTempStr = "—"
        }
        let coldDives = dives.filter { $0.minTemperature != 0 }
        let minTempStr: String
        if let minTemp = coldDives.map({ $0.displayMinTemperature }).min() {
            minTempStr = "\(Int(minTemp.rounded()))\(tempSymbol)"
        } else {
            minTempStr = "—"
        }
        let deepestDive = dives.max(by: { $0.displayMaxDepth < $1.displayMaxDepth })
        let warmestDive = warmDives.max(by: { $0.displayWaterTemperature < $1.displayWaterTemperature })
        let coldestDive = coldDives.min(by: { $0.displayMinTemperature < $1.displayMinTemperature })

        // --- Average / longest / shortest duration ---
        let avgDuration = dives.isEmpty ? 0 : totalMin / dives.count
        let longestDive = dives.max(by: { $0.duration < $1.duration })
        let shortestDive = dives.filter { $0.duration > 0 }.min(by: { $0.duration < $1.duration })

        // --- Surface interval stats ---
        func parseIntervalMinutes(_ s: String) -> Int {
            var total = 0
            for part in s.components(separatedBy: " ") {
                if part.hasSuffix("d"), let d = Int(part.dropLast()) { total += d * 1440 }
                else if part.hasSuffix("h"), let h = Int(part.dropLast()) { total += h * 60 }
                else if part.hasSuffix("m"), let m = Int(part.dropLast()) { total += m }
            }
            return total
        }
        let isFrench = locale.language.languageCode?.identifier == "fr"
        let daySuffix = isFrench ? "j" : "d"
        func formatIntervalMinutes(_ minutes: Int) -> String {
            if minutes < 60 { return "\(minutes)m" }
            if minutes < 1440 {
                let h = minutes / 60; let m = minutes % 60
                return m == 0 ? "\(h)h" : "\(h)h \(String(format: "%02d", m))m"
            }
            let d = minutes / 1440; let rem = minutes % 1440
            let h = rem / 60; let m = rem % 60
            if h == 0 && m == 0 { return "\(d)\(daySuffix)" }
            if m == 0 { return "\(d)\(daySuffix) \(h)h" }
            return "\(d)\(daySuffix) \(h)h \(String(format: "%02d", m))m"
        }
        let siDives = dives.filter { parseIntervalMinutes($0.surfaceInterval) > 0 }
        let avgSIStr: String
        let longestSIDive: Dive?
        let longestSIFormatted: String
        let shortestSIDive: Dive?
        let shortestSIFormatted: String
        if siDives.isEmpty {
            avgSIStr = "—"
            longestSIDive = nil; longestSIFormatted = "—"
            shortestSIDive = nil; shortestSIFormatted = "—"
        } else {
            let siValues = siDives.map { parseIntervalMinutes($0.surfaceInterval) }
            let avgSIMinutes = siValues.reduce(0, +) / siValues.count
            avgSIStr = formatIntervalMinutes(avgSIMinutes)
            longestSIDive = siDives.max(by: { parseIntervalMinutes($0.surfaceInterval) < parseIntervalMinutes($1.surfaceInterval) })
            longestSIFormatted = longestSIDive.map { formatIntervalMinutes(parseIntervalMinutes($0.surfaceInterval)) } ?? "—"
            shortestSIDive = siDives.min(by: { parseIntervalMinutes($0.surfaceInterval) < parseIntervalMinutes($1.surfaceInterval) })
            shortestSIFormatted = shortestSIDive.map { formatIntervalMinutes(parseIntervalMinutes($0.surfaceInterval)) } ?? "—"
        }

        // --- Min depth / shallowest dive ---
        let minDepthEver = dives.map(\.displayMaxDepth).min() ?? 0
        let shallowestDive = dives.min(by: { $0.displayMaxDepth < $1.displayMaxDepth })

        // --- Average temperature ---
        let avgTempValue = warmDives.isEmpty ? 0.0 : warmDives.map { $0.displayWaterTemperature }.reduce(0, +) / Double(warmDives.count)
        let avgTempStr = warmDives.isEmpty ? "—" : "\(Int(avgTempValue.rounded()))\(tempSymbol)"

        // --- RMV stats ---
        let rmvDives = dives.filter { $0.calculatedRMV > 0 }
        let avgRMVStr: String
        let bestRMVDive: Dive?
        let worstRMVDive: Dive?
        if rmvDives.isEmpty {
            avgRMVStr = "—"
            bestRMVDive = nil; worstRMVDive = nil
        } else {
            let rmvValues = rmvDives.map { $0.calculatedRMV }
            let avgRMVL = rmvValues.reduce(0, +) / Double(rmvValues.count)
            let isMetricRMV = prefs.pressureUnit != .psi
            let avgRMVFormatted = isMetricRMV
                ? String(format: "%.2f L/min", avgRMVL)
                : String(format: "%.3f cu ft/min", avgRMVL / 28.3168)
            let hasNonNative = rmvDives.contains { !$0.isRMVInNativeUnits }
            avgRMVStr = hasNonNative ? avgRMVFormatted + " *" : avgRMVFormatted
            bestRMVDive = rmvDives.min(by: { $0.calculatedRMV < $1.calculatedRMV })
            worstRMVDive = rmvDives.max(by: { $0.calculatedRMV < $1.calculatedRMV })
        }

        // --- SAC stats ---
        let sacDives = dives.filter { $0.calculatedSAC > 0 }
        let avgSACStr: String
        let bestSACDive: Dive?
        let worstSACDive: Dive?
        if sacDives.isEmpty {
            avgSACStr = "—"
            bestSACDive = nil; worstSACDive = nil
        } else {
            let sacUnit = prefs.pressureUnit.symbol
            let sacValues = sacDives.map { $0.calculatedSAC }
            let avgSACBar = sacValues.reduce(0, +) / Double(sacValues.count)
            avgSACStr = String(format: "%.2f %@/min", prefs.pressureUnit.convertFromBar(avgSACBar), sacUnit)
            bestSACDive = sacDives.min(by: { $0.calculatedSAC < $1.calculatedSAC })
            worstSACDive = sacDives.max(by: { $0.calculatedSAC < $1.calculatedSAC })
        }

        if Task.isCancelled { return }

        // --- Commit all results atomically ---
        cachedMaxDepthEver = maxDepthEver
        cachedAvgDepth = avgDepth
        cachedTopSites = topSites
        cachedDivesPerMonth = divesPerMonth
        cachedTotalSpeciesSeen = totalSpeciesSeen
        cachedMaxTemp = maxTempStr
        cachedMinTemp = minTempStr
        cachedDeepestDive = deepestDive
        cachedWarmestDive = warmestDive
        cachedColdestDive = coldestDive
        cachedSortedDives = sortedDives
        cachedAvgDuration = avgDuration
        cachedLongestDive = longestDive
        cachedShortestDive = shortestDive
        cachedAvgSurfaceInterval = avgSIStr
        cachedLongestSIDive = longestSIDive
        cachedLongestSIFormatted = longestSIFormatted
        cachedShortestSIDive = shortestSIDive
        cachedShortestSIFormatted = shortestSIFormatted
        cachedMinDepth = minDepthEver
        cachedShallowestDive = shallowestDive
        cachedAvgTemp = avgTempStr
        cachedAvgRMV = avgRMVStr
        cachedBestRMVDive = bestRMVDive
        cachedWorstRMVDive = worstRMVDive
        cachedAvgSAC = avgSACStr
        cachedBestSACDive = bestSACDive
        cachedWorstSACDive = worstSACDive
        cachedDiveCount = dives.count
        cachedTotalTimeFormatted = totalTimeFormatted
        cachedUniqueSites = uniqueSites
        cachedLongestStreak = longestStreak
        cachedUniqueCountries = uniqueCountries
        cachedTotalAirConsumed = totalAirConsumed
        statsReady = true
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if !allDives.isEmpty && filteredDives.isEmpty {
                    NoEntriesForDiverView(
                        title: "No Dives Match Filters",
                        description: "No dives were found matching the current filters."
                    )
                } else if !statsReady {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            // Career overview
                            careerOverviewSection
                                .opacity(appeared ? 1.0 : 0.0)
                                .offset(y: appeared ? 0 : 20)

                            // Activity chart
                            divesChartSection
                                .opacity(appeared ? 1.0 : 0.0)
                                .offset(y: appeared ? 0 : 20)

                            // Bottom time & surface interval
                            timingSection
                                .opacity(appeared ? 1.0 : 0.0)
                                .offset(y: appeared ? 0 : 20)

                            // Depth & temperature highlights
                            depthTemperatureSection
                                .opacity(appeared ? 1.0 : 0.0)
                                .offset(y: appeared ? 0 : 20)

                            // RMV & SAC
                            rmvSacSection
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
                DiverFilterToolbar(uniqueDivers: uniqueDivers, selectedDiver: $selectedDiver)
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showFilterSheet = true }) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                                .foregroundStyle(activeFilterCount > 0 ? .orange : .cyan)
                            if activeFilterCount > 0 {
                                Text("\(activeFilterCount)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.black)
                                    .padding(3)
                                    .background(Color.orange, in: Circle())
                                    .offset(x: 6, y: -6)
                            }
                        }
                    }
                    .accessibilityLabel(activeFilterCount == 0
                        ? NSLocalizedString("Filter dives", bundle: Bundle.forAppLanguage(), comment: "Accessibility label for the filter button when no filters are active")
                        : String(format: NSLocalizedString("%d active filters", bundle: Bundle.forAppLanguage(), comment: "Accessibility label for the filter button showing the number of active filters"), activeFilterCount)
                    )
                }
            }
            .background(Color.platformBackground.ignoresSafeArea())
            .task(id: filterTaskId) {
                statsReady = false
                appeared = false
                await computeStats(filteredDives, locale: locale)
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.6)) {
                    appeared = true
                }
            }
            .diverFilterReset(uniqueDivers: uniqueDivers, selectedDiver: $selectedDiver)
            .sheet(isPresented: $showFilterSheet) {
                DiveFilterSheet(
                    availableYears: availableYears,
                    availableGasTypes: availableGasTypes,
                    availableCountries: availableCountries,
                    availableDiveTypes: availableDiveTypes,
                    availableTags: availableTags,
                    availableMarineLife: availableMarineLife,
                    showSort: false,
                    filterYear: $filterYear,
                    filterYearNegate: $filterYearNegate,
                    filterGasType: $filterGasType,
                    filterGasTypeNegate: $filterGasTypeNegate,
                    filterMinDepth: $filterMinDepth,
                    filterMaxDepth: $filterMaxDepth,
                    filterMinRating: $filterMinRating,
                    filterCountry: $filterCountry,
                    filterCountryNegate: $filterCountryNegate,
                    filterDiveType: $filterDiveType,
                    filterDiveTypeNegate: $filterDiveTypeNegate,
                    filterTag: $filterTag,
                    filterMarineLife: $filterMarineLife,
                    filterMarineLifeMode: $filterMarineLifeMode,
                    sortOrder: $filterSortOrder
                )
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: Binding(
                get: { selectedSiteName != nil },
                set: { if !$0 { selectedSiteName = nil } }
            )) {
                if let siteName = selectedSiteName {
                    SiteDivesSheet(
                        siteName: siteName,
                        dives: filteredDives.filter { $0.siteName == siteName }
                    )
                    .presentationSizing(.page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                }
            }
            .sheet(item: $selectedDive) { dive in
                NavigationStack {
                    DiveDetailView(dive: dive, sortedDives: cachedSortedDives)
                }
                .presentationSizing(.page)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Bottom Time & Surface Interval Section

    private var timingSection: some View {
        let avgMin = cachedAvgDuration
        let avgFormatted = avgMin >= 60 ? "\(avgMin / 60)h \(avgMin % 60)m" : "\(avgMin) min"
        return HStack(spacing: 12) {
            // Bottom Time tile
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "clock.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                    Spacer()
                    Text("Bottom Time")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 4) {
                    Text(verbatim: avgFormatted)
                        .font(.system(.title, design: .rounded))
                        .fontWeight(.black)
                        .foregroundStyle(.primary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text("Average")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green.opacity(0.7))
                }

                Divider()
                    .background(Color.green.opacity(0.3))
                    .padding(.horizontal, 8)

                HStack {
                    Button { selectedDive = cachedLongestDive } label: {
                        VStack(spacing: 2) {
                            Text(verbatim: cachedLongestDive?.formattedDuration ?? "—")
                                .font(.system(.title3, design: .rounded))
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                            HStack(spacing: 3) {
                                Text("Longest")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.green.opacity(0.8))
                                if cachedLongestDive != nil {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.green.opacity(0.6))
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(cachedLongestDive == nil)

                    Spacer()

                    Button { selectedDive = cachedShortestDive } label: {
                        VStack(spacing: 2) {
                            Text(verbatim: cachedShortestDive?.formattedDuration ?? "—")
                                .font(.system(.title3, design: .rounded))
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                            HStack(spacing: 3) {
                                Text("Shortest")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.green.opacity(0.8))
                                if cachedShortestDive != nil {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.green.opacity(0.6))
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(cachedShortestDive == nil)
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
                                    colors: [.green.opacity(0.5), .green.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
            )

            // Surface Interval tile
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "hourglass")
                        .font(.title3)
                        .foregroundStyle(.indigo)
                    Spacer()
                    Text("Surface Interval")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 4) {
                    Text(verbatim: cachedAvgSurfaceInterval)
                        .font(.system(.title, design: .rounded))
                        .fontWeight(.black)
                        .foregroundStyle(.primary)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text("Average")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.indigo.opacity(0.7))
                }

                Divider()
                    .background(Color.indigo.opacity(0.3))
                    .padding(.horizontal, 8)

                HStack {
                    Button { selectedDive = cachedLongestSIDive } label: {
                        VStack(spacing: 2) {
                            Text(verbatim: cachedLongestSIFormatted)
                                .font(.system(.title3, design: .rounded))
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                            HStack(spacing: 3) {
                                Text("Longest")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.indigo.opacity(0.8))
                                if cachedLongestSIDive != nil {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.indigo.opacity(0.6))
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(cachedLongestSIDive == nil)

                    Spacer()

                    Button { selectedDive = cachedShortestSIDive } label: {
                        VStack(spacing: 2) {
                            Text(verbatim: cachedShortestSIFormatted)
                                .font(.system(.title3, design: .rounded))
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                            HStack(spacing: 3) {
                                Text("Shortest")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.indigo.opacity(0.8))
                                if cachedShortestSIDive != nil {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.indigo.opacity(0.6))
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(cachedShortestSIDive == nil)
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
                                    colors: [.indigo.opacity(0.5), .indigo.opacity(0.1)],
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

    // MARK: - Career Overview

    private var careerOverviewSection: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(.cyan)
                Text("Overview")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                LifetimeStat(
                    value: "\(cachedDiveCount)",
                    label: "Dives",
                    icon: "bubbles.and.sparkles",
                    color: .cyan
                )
                LifetimeStat(
                    value: cachedTotalTimeFormatted,
                    label: "Total Time",
                    icon: "clock.fill",
                    color: .green
                )
                LifetimeStat(
                    value: "\(cachedUniqueSites)",
                    label: "Sites",
                    icon: "mappin.circle.fill",
                    color: .orange
                )
                LifetimeStat(
                    value: "\(cachedLongestStreak)",
                    label: "Consecutive Days",
                    icon: "flame.fill",
                    color: .red
                )
                LifetimeStat(
                    value: cachedUniqueCountries > 0 ? "\(cachedUniqueCountries)" : "-",
                    label: "Countries",
                    icon: "globe",
                    color: .purple
                )
                LifetimeStat(
                    value: {
                        // totalAirConsumption is in litres (surface-equivalent); 1 L = 0.0353147 ft³
                        let converted = prefs.volumeUnit == .cubicFeet
                            ? cachedTotalAirConsumed * 0.0353147
                            : cachedTotalAirConsumed
                        return String(format: "%.0f %@", converted, prefs.volumeUnit.symbol)
                    }(),
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
            VStack(spacing: 12) {
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

                VStack(spacing: 4) {
                    Text(verbatim: String(format: "%.1f %@", cachedAvgDepth, prefs.depthUnit.symbol))
                        .font(.system(.title, design: .rounded))
                        .fontWeight(.black)
                        .foregroundStyle(.primary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text("Average")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.blue.opacity(0.7))
                }

                Divider()
                    .background(Color.blue.opacity(0.3))
                    .padding(.horizontal, 8)

                HStack {
                    Button { selectedDive = cachedDeepestDive } label: {
                        VStack(spacing: 2) {
                            Text(verbatim: String(format: "%.1f %@", cachedMaxDepthEver, prefs.depthUnit.symbol))
                                .font(.system(.title3, design: .rounded))
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                            HStack(spacing: 3) {
                                Text("Max")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.blue.opacity(0.8))
                                if cachedDeepestDive != nil {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.blue.opacity(0.6))
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(cachedDeepestDive == nil)

                    Spacer()

                    Button { selectedDive = cachedShallowestDive } label: {
                        VStack(spacing: 2) {
                            Text(verbatim: String(format: "%.1f %@", cachedMinDepth, prefs.depthUnit.symbol))
                                .font(.system(.title3, design: .rounded))
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                            HStack(spacing: 3) {
                                Text("Min")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.blue.opacity(0.8))
                                if cachedShallowestDive != nil {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.blue.opacity(0.6))
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(cachedShallowestDive == nil)
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
            VStack(spacing: 12) {
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

                VStack(spacing: 4) {
                    Text(verbatim: cachedAvgTemp)
                        .font(.system(.title, design: .rounded))
                        .fontWeight(.black)
                        .foregroundStyle(.primary)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text("Average")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange.opacity(0.7))
                }

                Divider()
                    .background(Color.orange.opacity(0.3))
                    .padding(.horizontal, 8)

                HStack {
                    Button { selectedDive = cachedWarmestDive } label: {
                        VStack(spacing: 2) {
                            Text(verbatim: cachedMaxTemp)
                                .font(.system(.title3, design: .rounded))
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                            HStack(spacing: 3) {
                                Text("Warmest")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.orange.opacity(0.8))
                                if cachedWarmestDive != nil {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.orange.opacity(0.6))
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(cachedWarmestDive == nil)

                    Spacer()

                    Button { selectedDive = cachedColdestDive } label: {
                        VStack(spacing: 2) {
                            Text(verbatim: cachedMinTemp)
                                .font(.system(.title3, design: .rounded))
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                            HStack(spacing: 3) {
                                Text("Coldest")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.cyan.opacity(0.8))
                                if cachedColdestDive != nil {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.cyan.opacity(0.6))
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(cachedColdestDive == nil)
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

    // MARK: - RMV & SAC Section

    private var rmvSacSection: some View {
        HStack(spacing: 12) {
            // RMV card
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "lungs.fill")
                        .font(.title3)
                        .foregroundStyle(.teal)
                    Spacer()
                    Text("RMV")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 4) {
                    Text(verbatim: cachedAvgRMV)
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.black)
                        .foregroundStyle(.primary)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text("Average")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.teal.opacity(0.7))
                }

                Divider()
                    .background(Color.teal.opacity(0.3))
                    .padding(.horizontal, 8)

                HStack {
                    Button { selectedDive = cachedBestRMVDive } label: {
                        VStack(spacing: 2) {
                            Text(verbatim: cachedBestRMVDive?.formattedRMV ?? "—")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .minimumScaleFactor(0.5)
                                .lineLimit(1)
                            HStack(spacing: 3) {
                                Text("Best")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.teal.opacity(0.8))
                                if cachedBestRMVDive != nil {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.teal.opacity(0.6))
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(cachedBestRMVDive == nil)

                    Spacer()

                    Button { selectedDive = cachedWorstRMVDive } label: {
                        VStack(spacing: 2) {
                            Text(verbatim: cachedWorstRMVDive?.formattedRMV ?? "—")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .minimumScaleFactor(0.5)
                                .lineLimit(1)
                            HStack(spacing: 3) {
                                Text("Worst")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.teal.opacity(0.8))
                                if cachedWorstRMVDive != nil {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.teal.opacity(0.6))
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(cachedWorstRMVDive == nil)
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
                                    colors: [.teal.opacity(0.5), .teal.opacity(0.1)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
            )

            // SAC card
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                        .font(.title3)
                        .foregroundStyle(.mint)
                    Spacer()
                    Text("SAC")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 4) {
                    Text(verbatim: cachedAvgSAC)
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.black)
                        .foregroundStyle(.primary)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text("Average")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.mint.opacity(0.7))
                }

                Divider()
                    .background(Color.mint.opacity(0.3))
                    .padding(.horizontal, 8)

                HStack {
                    Button { selectedDive = cachedBestSACDive } label: {
                        VStack(spacing: 2) {
                            Text(verbatim: cachedBestSACDive?.formattedSAC ?? "—")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .minimumScaleFactor(0.5)
                                .lineLimit(1)
                            HStack(spacing: 3) {
                                Text("Best")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.mint.opacity(0.8))
                                if cachedBestSACDive != nil {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.mint.opacity(0.6))
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(cachedBestSACDive == nil)

                    Spacer()

                    Button { selectedDive = cachedWorstSACDive } label: {
                        VStack(spacing: 2) {
                            Text(verbatim: cachedWorstSACDive?.formattedSAC ?? "—")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .minimumScaleFactor(0.5)
                                .lineLimit(1)
                            HStack(spacing: 3) {
                                Text("Worst")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.mint.opacity(0.8))
                                if cachedWorstSACDive != nil {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.mint.opacity(0.6))
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(cachedWorstSACDive == nil)
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
                                    colors: [.mint.opacity(0.5), .mint.opacity(0.1)],
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
                        Button { selectedSiteName = site.name } label: {
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
                                    Text(verbatim: site.name)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    HStack(spacing: 4) {
                                        if !site.location.isEmpty && site.location != "Inconnu" && site.location != NSLocalizedString("Unknown", bundle: Bundle.forAppLanguage(), comment: "") {
                                            Text(verbatim: site.location)
                                        }
                                        if !site.country.isEmpty {
                                            if !site.location.isEmpty && site.location != "Inconnu" && site.location != NSLocalizedString("Unknown", bundle: Bundle.forAppLanguage(), comment: "") {
                                                Text("·")
                                            }
                                            Text(verbatim: site.country)
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

                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 4)
                        }
                        .buttonStyle(.plain)

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
            Text(verbatim: value)
                .font(.system(.body, design: .rounded).weight(.black))
                .foregroundStyle(.primary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.caption2)
                .minimumScaleFactor(0.7)
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

// MARK: - Site Dives Sheet

struct SiteDivesSheet: View {
    let siteName: String
    let dives: [Dive]
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Dive.timestamp, order: .reverse) private var allDives: [Dive]
    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""

    private var sortedDives: [Dive] { dives.sorted { $0.timestamp > $1.timestamp } }

    private var numberMap: [PersistentIdentifier: Int] {
        let numbering = selectedDiver.isEmpty
            ? allDives
            : allDives.filter { $0.diverName == selectedDiver }
        let total = numbering.count
        return Dictionary(uniqueKeysWithValues: numbering.enumerated().map {
            ($0.element.persistentModelID, total - $0.offset)
        })
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedDives) { dive in
                    NavigationLink(destination: DiveDetailView(dive: dive, sortedDives: sortedDives)) {
                        DiveRowView(
                            dive: dive,
                            diveNumber: numberMap[dive.persistentModelID] ?? 0
                        )
                    }
                    .listRowBackground(Color.primary.opacity(0.07))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.platformBackground.ignoresSafeArea())
            #if os(iOS)
            .listStyle(.plain)
            #endif
            .navigationTitle(siteName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.cyan)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 650, minHeight: 400, idealHeight: 600)
        #endif
    }
}

#Preview {
    StatisticsView()
        .modelContainer(for: Dive.self, inMemory: true)
}
