import SwiftUI
import SwiftData
import Charts
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct StatisticsView: View {
    @Environment(DiveStore.self) private var store
    @State private var prefs = UserPreferences.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
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
    /// The RMV and SAC tiles are computed after the rest of the page is shown (each dive's
    /// profile is decoded the first time — seconds for thousands of dives); they show a
    /// spinner until then.
    @State private var gasStatsReady = false
    /// The selection (dives and pressure unit) the RMV and SAC tiles show. A recompute for the
    /// same selection (a dive edited, an iCloud change) keeps them on screen until the new
    /// values arrive, instead of showing the spinner again.
    @State private var gasStatsSelectionKey: Int? = nil
    /// A `computeGasStats` run has been in progress for `gasSpinnerDelay`: a small spinner beside
    /// the kept values says they are being updated (none for a quick recompute, so it never flashes).
    @State private var gasStatsSpinnerVisible = false
    private static let gasSpinnerDelay: Duration = .milliseconds(300)
    /// The latest `computeGasStats` run, so a cancelled earlier run does not hide the spinner
    /// while a newer one is still computing.
    @State private var gasStatsRun = UUID()
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
    @State private var filterSortOrder: DiveSortOrder = .dateDesc
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
    /// Some RMV dive was not recorded in bar and litres: the values carry " *", explained by
    /// `rmvFootnote`.
    @State private var cachedRMVIsEstimated = false
    @State private var cachedBestRMVDive: Dive? = nil
    @State private var cachedWorstRMVDive: Dive? = nil
    @State private var cachedAvgSAC: String = "—"
    @State private var cachedBestSACDive: Dive? = nil
    @State private var cachedWorstSACDive: Dive? = nil
    @State private var statsVersion: Int = 0
    @State private var cachedDiveCount: Int = 0
    @State private var cachedTotalTimeFormatted: String = "—"
    @State private var cachedUniqueSites: Int = 0
    @State private var cachedLongestStreak: Int = 0
    @State private var cachedUniqueCountries: Int = 0
    @State private var cachedTotalAirConsumed: Double = 0

    // MARK: - CSV Export State
    @State private var csvExportTask: Task<Void, Never>? = nil
    /// Shown only once an export has run for `csvOverlayDelay`, so a small log saves without a flash.
    @State private var csvProgressVisible = false
    @State private var csvProgressCurrent: Int = 0
    @State private var csvProgressTotal: Int = 0
    @State private var csvExportFailed = false
    /// The dives the current stats were computed from (diver and filters applied), set once per
    /// `filterTaskId` change so the export button, the export and the trends chart do not
    /// re-filter the whole logbook on every redraw.
    @State private var cachedFilteredDives: [Dive] = []
    /// Bumped with each stats computation. The trends chart is rebuilt anyway while the stats
    /// recompute (hidden behind the progress view); this keeps it reloading should that change.
    @State private var trendRefreshID: Int = 0
    #if os(iOS)
    @State private var csvExportDocument: ExportableFileDocument? = nil
    @State private var showCSVExporter = false
    /// Set when the file is built, so the exporter's name is not recomputed on every redraw.
    @State private var csvExportFileName = ""
    #endif
    #if os(macOS)
    /// The open Save panel: it is a separate, non-modal window, so Export stays disabled while
    /// it is open, and closing Statistics closes it (nothing is saved).
    @State private var csvSavePanel: NSSavePanel? = nil
    #endif
    private static let csvOverlayDelay: Duration = .milliseconds(300)

    /// An export is running, or (macOS) its Save panel is open.
    private var isCSVExportBusy: Bool {
        #if os(macOS)
        return csvExportTask != nil || csvSavePanel != nil
        #else
        return csvExportTask != nil
        #endif
    }

    @Environment(\.locale) private var locale

    private var filteredDives: [Dive] {
        DiverFilter.applyDiveFilters(
            to: DiverFilter.apply(selectedDiver, to: store.dives),
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

    /// No dive matches the diver and filters. Once the stats are shown it reads the dives they
    /// were computed from, so a redraw (e.g. the CSV export's progress) does not re-filter the
    /// whole logbook; while they load, it filters live.
    private var hasNoFilteredDives: Bool {
        statsReady ? cachedFilteredDives.isEmpty : filteredDives.isEmpty
    }

    private var diverDives: [Dive] { DiverFilter.apply(selectedDiver, to: store.dives) }

    private var availableYears: [Int] {
        Array(Set(diverDives.compactMap { Calendar.current.dateComponents([.year], from: $0.timestamp).year })).sorted(by: >)
    }
    private var availableGasTypes: [String] { Array(Set(diverDives.flatMap { DiveSummary.gasNames(of: $0) })).sorted() }
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
        "\(store.dives.count):\(selectedDiver):\(filterYear ?? -1):\(filterYearNegate):\(filterGasType ?? ""):\(filterGasTypeNegate):\(filterMinDepth):\(filterMaxDepth):\(filterMinRating):\(filterCountry ?? ""):\(filterCountryNegate):\(filterDiveType ?? ""):\(filterDiveTypeNegate):\(filterTag ?? ""):\(filterMarineLife.joined(separator: ",")):\(filterMarineLifeMode):\(locale.identifier):\(statsVersion):\(store.dives.reduce(into: 0) { $0 += Int($1.timestamp.timeIntervalSinceReferenceDate) })"
    }

    private func computeStats(_ dives: [Dive], locale: Locale) async {
        // --- Lightweight scalars (always cheap) ---
        let totalMin = dives.reduce(0) { $0 + $1.duration }
        let totalTimeFormatted = formattedMinutes(totalMin, locale: locale)
        let maxDepthEver = dives.map(\.displayMaxDepth).max() ?? 0
        let depthDives = dives.filter { $0.averageDepth > 0 }
        let avgDepth = depthDives.isEmpty ? 0 : depthDives.map(\.displayAverageDepth).reduce(0, +) / Double(depthDives.count)
        let sortedDives = dives.sorted { $0.timestamp > $1.timestamp }

        // Same site rule as the Sites count: "Blue Hole" and "blue hole " are one site, and
        // dives without a site are not a Top Site.
        let grouped = Dictionary(grouping: dives) { siteNameKey($0.siteName) }.filter { !$0.key.isEmpty }
        // Ranked first, so the display spelling is worked out only for the five shown.
        let topSiteGroups = grouped.sorted { $0.value.count > $1.value.count }.prefix(5)
        let topSites: [(name: String, location: String, country: String, count: Int)] = topSiteGroups.map { (_, group) in
            let name = displaySiteName(group.map(\.siteName))
            // Location and country from a dive with the spelling shown, so a merged "blue hole"
            // logged elsewhere cannot lend its place to "Blue Hole".
            let sourceDive = group.first { $0.siteName.trimmingCharacters(in: .whitespacesAndNewlines) == name } ?? group.first
            return (name, sourceDive?.location ?? "", sourceDive?.siteCountry ?? "", group.count)
        }

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
        // The Top Sites groups are exactly the distinct sites (same `siteNameKey` rule).
        let uniqueSites = grouped.count
        let uniqueCountries = Set(dives.compactMap { $0.siteCountry?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }).count
        let divingDays = Set(dives.map { calendar.startOfDay(for: $0.timestamp) }).sorted()
        var longestStreak = divingDays.isEmpty ? 0 : 1
        var currentStreak = 1
        for i in divingDays.indices.dropFirst() {
            let diff = calendar.dateComponents([.day], from: divingDays[i - 1], to: divingDays[i]).day ?? 999
            currentStreak = diff == 1 ? currentStreak + 1 : 1
            longestStreak = max(longestStreak, currentStreak)
        }

        if Task.isCancelled { return }
        await Task.yield()
        if Task.isCancelled { return }

        // --- Potentially heavy: species set and air consumption across all dives ---
        // A linked sighting counts as its species, an unlinked one as its name ignoring case.
        var speciesKeys = Set<SightingSpeciesKey>()
        var totalAirConsumed = 0.0
        let yieldInterval = 100
        for (idx, dive) in dives.enumerated() {
            if let fish = dive.seenFish {
                for entry in fish {
                    if let key = SightingSpeciesKey(entry) { speciesKeys.insert(key) }
                }
            }
            totalAirConsumed += dive.totalAirConsumption
            if idx % yieldInterval == yieldInterval - 1 {
                await Task.yield()
                if Task.isCancelled { return }
            }
        }
        let totalSpeciesSeen = speciesKeys.count

        // --- Temperature extremes ---
        let tempSymbol = prefs.temperatureUnit.symbol
        let warmDives = dives.filter { $0.waterTemperature != nil }

        // Warmest/coldest consider both min and max temperature fields across all dives
        let allDiveDisplayTemps: (Dive) -> [Double] = { dive in
            [dive.displayMinTemperature, dive.displayMaxTemperature].compactMap { $0 }
        }
        let allTemps = dives.flatMap { allDiveDisplayTemps($0) }
        let maxTempStr: String
        if let maxTemp = allTemps.max() {
            maxTempStr = maxTemp.localizedString(decimals: 0) + tempSymbol
        } else {
            maxTempStr = "—"
        }
        let minTempStr: String
        if let minTemp = allTemps.min() {
            minTempStr = minTemp.localizedString(decimals: 0) + tempSymbol
        } else {
            minTempStr = "—"
        }
        let deepestDive = dives.max(by: { $0.displayMaxDepth < $1.displayMaxDepth })
        let warmestDive = dives
            .filter { !allDiveDisplayTemps($0).isEmpty }
            .max(by: { (allDiveDisplayTemps($0).max() ?? -.infinity) < (allDiveDisplayTemps($1).max() ?? -.infinity) })
        let coldestDive = dives
            .filter { !allDiveDisplayTemps($0).isEmpty }
            .min(by: { (allDiveDisplayTemps($0).min() ?? .infinity) < (allDiveDisplayTemps($1).min() ?? .infinity) })

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
        // Dutch "u" (uur) and Norwegian "t" (time), as in the dive list's surface interval and duration badges.
        let hourSuffix: String
        switch locale.language.languageCode?.identifier {
        case "nl": hourSuffix = "u"
        case "nb": hourSuffix = "t"
        default: hourSuffix = "h"
        }
        // Spanish "min" ("m" is metres), as in the dive list's surface interval and duration badges.
        let minuteSuffix = locale.language.languageCode?.identifier == "es" ? "min" : "m"
        func formatIntervalMinutes(_ minutes: Int) -> String {
            if minutes < 60 { return "\(minutes)\(minuteSuffix)" }
            if minutes < 1440 {
                let h = minutes / 60; let m = minutes % 60
                return m == 0 ? "\(h)\(hourSuffix)" : "\(h)\(hourSuffix) \(String(format: "%02d", m))\(minuteSuffix)"
            }
            let d = minutes / 1440; let rem = minutes % 1440
            let h = rem / 60; let m = rem % 60
            if h == 0 && m == 0 { return "\(d)\(daySuffix)" }
            if m == 0 { return "\(d)\(daySuffix) \(h)\(hourSuffix)" }
            return "\(d)\(daySuffix) \(h)\(hourSuffix) \(String(format: "%02d", m))\(minuteSuffix)"
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
        let warmTemps = warmDives.compactMap { $0.displayWaterTemperature }
        let avgTempValue = warmTemps.isEmpty ? 0.0 : warmTemps.reduce(0, +) / Double(warmTemps.count)
        let avgTempStr = warmDives.isEmpty ? "—" : avgTempValue.localizedString(decimals: 0) + tempSymbol

        // RMV and SAC: `computeGasStats`, once the page is shown.
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
        // A new selection clears the RMV and SAC tiles (never another selection's values)
        // until `computeGasStats` fills them; the same selection keeps them meanwhile.
        if gasStatsSelectionKey != gasSelectionKey(for: dives) {
            gasStatsReady = false
            cachedAvgRMV = "—"
            cachedRMVIsEstimated = false
            cachedBestRMVDive = nil
            cachedWorstRMVDive = nil
            cachedAvgSAC = "—"
            cachedBestSACDive = nil
            cachedWorstSACDive = nil
        }
        cachedDiveCount = dives.count
        cachedTotalTimeFormatted = totalTimeFormatted
        cachedUniqueSites = uniqueSites
        cachedLongestStreak = longestStreak
        cachedUniqueCountries = uniqueCountries
        cachedTotalAirConsumed = totalAirConsumed
        statsReady = true
    }

    /// The RMV and SAC tiles, computed once the rest of the page is shown: each dive's RMV and
    /// SAC are calculated once, off the main thread and in parallel (`DiveGasReader`), then
    /// aggregated here.
    /// RMV follows `rmvAggregate`'s rule (the trip details' and the dive's): dives with an RMV
    /// above 0, average of their values, " *" when one is not from bar and litres, best and worst
    /// by strict comparison (the first of equal values). SAC: dives with a SAC above 0, average
    /// in bar/min shown in the pressure unit, best and worst likewise.
    private func computeGasStats(_ dives: [Dive]) async {
        let run = UUID()
        gasStatsRun = run
        let spinnerDelay = Task {
            try? await Task.sleep(for: Self.gasSpinnerDelay)
            if !Task.isCancelled && gasStatsRun == run { gasStatsSpinnerVisible = true }
        }
        defer {
            spinnerDelay.cancel()
            if gasStatsRun == run { gasStatsSpinnerVisible = false }
        }
        var rmvSum = 0.0
        var rmvCount = 0
        var rmvIsEstimated = false
        var bestRMV: (dive: Dive, value: Double)?
        var worstRMV: (dive: Dive, value: Double)?
        var sacSum = 0.0
        var sacCount = 0
        var bestSAC: (dive: Dive, value: Double)?
        var worstSAC: (dive: Dive, value: Double)?

        // Each dive's RMV and SAC, computed off the main thread (`DiveGasReader`), which reads
        // the saved values: dives with unsaved changes (an edit waiting for autosave, a dive not
        // saved yet) are computed here instead, so the tiles match what the dive shows.
        let liveDives = dives.filter { !$0.isDeleted && $0.modelContext != nil }
        let unsaved = Set((modelContext.insertedModelsArray + modelContext.changedModelsArray)
            .compactMap { ($0 as? Dive)?.persistentModelID })
        let toRead = liveDives.map(\.persistentModelID).filter { !unsaved.contains($0) }
        guard let values = await DiveGasReader.read(container: modelContext.container, ids: toRead) else {
            return
        }
        if Task.isCancelled { return }

        // Aggregated in the dives' order, so ties keep the same dive as before.
        var computedHere = 0
        for dive in liveDives {
            // Re-checked after every await: iCloud can delete a dive meanwhile.
            guard !dive.isDeleted, dive.modelContext != nil else { continue }
            let value: DiveGasReader.Value
            if let read = values[dive.persistentModelID] {
                value = read
            } else {
                // Unsaved, or not read (a failed fetch): computed on the MainActor.
                let rmv = dive.calculatedRMV
                value = DiveGasReader.Value(rmv: rmv, sac: rmv > 0 ? dive.calculatedSAC : 0,
                                            rmvIsNative: dive.isRMVInNativeUnits)
                computedHere += 1
                if computedHere % 20 == 0 {
                    await Task.yield()
                    if Task.isCancelled { return }
                    guard !dive.isDeleted, dive.modelContext != nil else { continue }
                }
            }
            let rmv = value.rmv
            guard rmv > 0 else { continue }
            rmvSum += rmv
            rmvCount += 1
            if !value.rmvIsNative { rmvIsEstimated = true }
            if rmv < (bestRMV?.value ?? .infinity) { bestRMV = (dive, rmv) }
            if rmv > (worstRMV?.value ?? -.infinity) { worstRMV = (dive, rmv) }

            let sac = value.sac
            guard sac > 0 else { continue }
            sacSum += sac
            sacCount += 1
            if sac < (bestSAC?.value ?? .infinity) { bestSAC = (dive, sac) }
            if sac > (worstSAC?.value ?? -.infinity) { worstSAC = (dive, sac) }
        }
        if Task.isCancelled { return }

        let pressureUnit = prefs.pressureUnit
        cachedAvgRMV = rmvCount > 0
            ? formatRMV(rmvSum / Double(rmvCount), pressureUnit: pressureUnit, isEstimated: rmvIsEstimated)
            : "—"
        cachedRMVIsEstimated = rmvCount > 0 && rmvIsEstimated
        cachedBestRMVDive = bestRMV?.dive
        cachedWorstRMVDive = worstRMV?.dive
        cachedAvgSAC = sacCount > 0
            ? pressureUnit.convertFromBar(sacSum / Double(sacCount)).localizedString(decimals: 2, minDecimals: 2) + " \(pressureUnit.symbol)/min"
            : "—"
        cachedBestSACDive = bestSAC?.dive
        cachedWorstSACDive = worstSAC?.dive
        gasStatsSelectionKey = gasSelectionKey(for: dives)
        gasStatsReady = true
    }

    /// Identifies a selection for the RMV and SAC tiles: the dives (in order) and the pressure
    /// unit their values are shown in.
    private func gasSelectionKey(for dives: [Dive]) -> Int {
        var hasher = Hasher()
        hasher.combine(prefs.pressureUnit.rawValue)
        for dive in dives { hasher.combine(dive.persistentModelID) }
        return hasher.finalize()
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if store.dives.isEmpty {
                    NoEntriesForDiverView(
                        title: "No Dives Recorded",
                        description: "Add your first dive to see your statistics."
                    )
                } else if hasNoFilteredDives && !selectedDiver.isEmpty && activeFilterCount == 0 {
                    NoEntriesForDiverView(
                        title: DiverFilter.noDivesTitle(for: selectedDiver),
                        description: DiverFilter.noDivesDescription(for: selectedDiver)
                    )
                } else if hasNoFilteredDives {
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

                            // 12-month trends of the CSV export's metrics
                            StatisticsTrendChart(dives: cachedFilteredDives, year: filterYear, yearNegate: filterYearNegate, refreshID: trendRefreshID)
                                .opacity(appeared ? 1.0 : 0.0)
                                .offset(y: appeared ? 0 : 20)

                            #if os(macOS)
                            // The Mac sheet is wide enough for the six highlight tiles in two
                            // rows of three, in the same reading order as the iOS pairs; fixedSize
                            // gives the tiles of a row the height of the tallest one. A narrower
                            // sheet falls back to the iOS pairs.
                            WidthAdaptiveLayout(minWidth: 600) {
                                VStack(spacing: 24) {
                                    HStack(spacing: 12) {
                                        bottomTimeTile
                                        surfaceIntervalTile
                                        depthTile
                                    }
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal)

                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(spacing: 12) {
                                            temperatureTile
                                            rmvTile
                                            sacTile
                                        }
                                        .fixedSize(horizontal: false, vertical: true)
                                        rmvFootnote
                                    }
                                    .padding(.horizontal)
                                }
                            } narrow: {
                                VStack(spacing: 24) {
                                    timingSection
                                    depthTemperatureSection
                                    rmvSacSection
                                }
                            }
                            .opacity(appeared ? 1.0 : 0.0)
                            .offset(y: appeared ? 0 : 20)
                            #else
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
                            #endif

                            #if os(macOS)
                            // The Mac sheet is wide enough to show Favourite Sites (⅗) beside
                            // At a Glance (⅖, wide enough for long labels such as the German
                            // "Gesichtete Arten"); fixedSize gives both the height of the taller one.
                            // A narrower sheet falls back to the iOS order, one under the other.
                            WidthAdaptiveLayout(minWidth: 600) {
                                HStack(alignment: .top, spacing: 0) {
                                    topSitesSection
                                        .containerRelativeFrame(.horizontal, count: 5, span: 3, spacing: 0)
                                    moreStatsGrid
                                        .containerRelativeFrame(.horizontal, count: 5, span: 2, spacing: 0)
                                }
                                .fixedSize(horizontal: false, vertical: true)
                            } narrow: {
                                VStack(spacing: 24) {
                                    topSitesSection(sideBySide: false)
                                    moreStatsGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], sideBySide: false)
                                }
                            }
                            .opacity(appeared ? 1.0 : 0.0)
                            .offset(y: appeared ? 0 : 20)
                            #else
                            // Favourite sites
                            topSitesSection
                                .opacity(appeared ? 1.0 : 0.0)
                                .offset(y: appeared ? 0 : 20)

                            // Remaining stats
                            moreStatsGrid
                                .opacity(appeared ? 1.0 : 0.0)
                                .offset(y: appeared ? 0 : 20)
                            #endif
                        }
                        .padding(.bottom, 30)
                    }
                }
            }
            .exportProgressOverlay(isPresented: csvProgressVisible, current: csvProgressCurrent, total: csvProgressTotal) {
                csvExportTask?.cancel()
            }
            .navigationTitle("Statistics")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { dismiss() }
                }
                DiverFilterToolbar(uniqueDivers: store.cachedUniqueDivers, selectedDiver: $selectedDiver)
                ToolbarItem(placement: .sheetPrimaryAction) {
                    Button(action: exportStatisticsCSV) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.cyan)
                    }
                    .disabled(isCSVExportBusy || !statsReady || cachedFilteredDives.isEmpty)
                    .accessibilityLabel(Text("Export CSV"))
                }
                ToolbarItem(placement: .sheetPrimaryAction) {
                    Button(action: { showFilterSheet = true }) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "line.3.horizontal.decrease")
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
                    // The progress overlay does not cover the toolbar: no filter sheet during an
                    // export, which would keep the Files exporter from appearing when it ends.
                    .disabled(isCSVExportBusy)
                    .accessibilityLabel(activeFilterCount == 0
                        ? NSLocalizedString("Filter dives", bundle: Bundle.forAppLanguage(), comment: "Accessibility label for the filter button when no filters are active")
                        : String(format: NSLocalizedString("%d active filters", bundle: Bundle.forAppLanguage(), comment: "Accessibility label for the filter button showing the number of active filters"), activeFilterCount)
                    )
                }
            }
            .background(AppBackground().ignoresSafeArea())
            .task(id: filterTaskId) {
                statsReady = false
                appeared = false
                let dives = filteredDives
                cachedFilteredDives = dives
                trendRefreshID += 1
                await computeStats(dives, locale: locale)
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.6)) {
                    appeared = true
                }
                // The page is shown; the RMV and SAC tiles follow.
                await computeGasStats(dives)
            }
            .onChange(of: store.cachedSummaries) { _, _ in
                statsVersion += 1
            }
            .diverFilterReset(uniqueDivers: store.cachedUniqueDivers, selectedDiver: $selectedDiver)
            #if os(iOS)
            .fileExporter(
                isPresented: $showCSVExporter,
                document: csvExportDocument,
                contentType: .commaSeparatedText,
                defaultFilename: csvExportFileName
            ) { result in
                csvExportDocument = nil
                if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled {
                    csvExportFailed = true
                }
            }
            // Cancelling may not call the completion: release the file whenever the exporter closes.
            .onChange(of: showCSVExporter) { _, isShown in
                if !isShown { csvExportDocument = nil }
            }
            #endif
            .alert("Export Failed", isPresented: $csvExportFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The CSV file could not be saved.")
            }
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
                .standardSheetPresentation()
            }
            .sheet(isPresented: Binding(
                get: { selectedSiteName != nil },
                set: { if !$0 { selectedSiteName = nil } }
            )) {
                if let siteName = selectedSiteName {
                    // Matched by site name when shown (not by identifiers saved with the stats,
                    // which a dive saved since would no longer match).
                    let selectedKey = siteNameKey(siteName)
                    SiteDivesSheet(
                        siteName: siteName,
                        dives: filteredDives.filter { siteNameKey($0.siteName) == selectedKey }
                    )
                    .standardSheetPresentation()
                }
            }
            .navigationDestination(item: $selectedDive) { dive in
                DiveDetailView(dive: dive, sortedDives: cachedSortedDives,
                               diveNumber: dive.diveNumber ?? (cachedSortedDives.firstIndex(where: { $0.id == dive.id }).map { cachedSortedDives.count - $0 } ?? 0))
                    .closeSheetButtonOnMac { dismiss() }
            }
        }
        // Closing Statistics stops an export in progress (and closes its Save panel); nothing is saved.
        .onDisappear {
            csvExportTask?.cancel()
            #if os(macOS)
            csvSavePanel?.cancel(nil)
            #endif
        }
    }

    // MARK: - CSV Export

    /// Statistics → Export CSV: one row per dive Statistics shows (diver and filters applied),
    /// oldest first, values in the user's display units. On macOS the Save panel comes first
    /// and the file is written once built; on iOS the file is built, then the Files exporter opens.
    private func exportStatisticsCSV() {
        guard !isCSVExportBusy else { return }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = StatisticsCSVExport.fileName()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        csvSavePanel = panel
        panel.begin { response in
            csvSavePanel = nil
            guard response == .OK, let url = panel.url else { return }
            runCSVExport { data in
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    csvExportFailed = true
                }
            }
        }
        #else
        runCSVExport { data in
            csvExportFileName = StatisticsCSVExport.fileName()
            csvExportDocument = ExportableFileDocument(data: data)
            showCSVExporter = true
        }
        #endif
    }

    /// Reads the rows, builds the file off the MainActor and hands it to `deliver`, unless the
    /// export is cancelled (Cancel on the progress card, or Statistics closed).
    private func runCSVExport(deliver: @escaping (Data) -> Void) {
        guard csvExportTask == nil else { return }
        // Live dives only, checked before any attribute is read: iCloud can delete a dive meanwhile.
        let dives = cachedFilteredDives
            .filter { !$0.isDeleted && $0.modelContext != nil }
            .sorted { $0.timestamp < $1.timestamp }
        csvProgressCurrent = 0
        csvProgressTotal = dives.count
        csvExportTask = Task {
            let overlayDelay = Task {
                try? await Task.sleep(for: Self.csvOverlayDelay)
                if !Task.isCancelled { csvProgressVisible = true }
            }
            defer {
                overlayDelay.cancel()
                csvProgressVisible = false
                csvExportTask = nil
            }
            guard let data = await buildStatisticsCSV(dives), !Task.isCancelled else { return }
            deliver(data)
        }
    }

    /// Reads each dive's values in display units on the MainActor (yielding every 100 dives,
    /// which also updates the progress card), then builds the file in a detached task.
    /// Returns nil when cancelled.
    private func buildStatisticsCSV(_ dives: [Dive]) async -> Data? {
        let pressureUnit = prefs.pressureUnit
        let rmvInCubicFeet = pressureUnit == .psi
        let rmvUnit = rmvInCubicFeet
            ? NSLocalizedString("unit.volume.rmv.cu_ft_per_min", bundle: .forAppLanguage(), value: "cu ft/min", comment: "RMV unit: cubic feet per minute")
            : NSLocalizedString("unit.volume.rmv.l_per_min", bundle: .forAppLanguage(), value: "L/min", comment: "RMV unit: litres per minute")
        let depthSymbol = prefs.depthUnit.symbol
        let temperatureSymbol = prefs.temperatureUnit.symbol
        let bundle = Bundle.forAppLanguage()
        let labels = StatisticsCSVExport.Labels(
            headers: [
                NSLocalizedString("Date", bundle: bundle, value: "Date", comment: "Label for the date of a dive (also a column title of the Statistics CSV export)"),
                NSLocalizedString("Dive Number", bundle: bundle, value: "Dive Number", comment: "Statistics CSV export column: dive number in the logbook"),
                NSLocalizedString("Diver", bundle: bundle, value: "Diver", comment: "Label for the diver's name (also a column title of the Statistics CSV export)"),
                NSLocalizedString("Site", bundle: bundle, value: "Site", comment: "Label for the dive site name (also a column title of the Statistics CSV export)"),
                NSLocalizedString("Location", bundle: bundle, value: "Location", comment: "Label for the location of a dive (also a column title of the Statistics CSV export)"),
                NSLocalizedString("Country", bundle: bundle, value: "Country", comment: "Label for the dive site's country (also a column title of the Statistics CSV export)"),
                String(format: NSLocalizedString("Max Depth (%@)", bundle: bundle, value: "Max Depth (%@)", comment: "Maximum depth label; %@ is the depth unit (m or ft)"), depthSymbol),
                String(format: NSLocalizedString("Average Depth (%@)", bundle: bundle, value: "Average Depth (%@)", comment: "Statistics CSV export column: average depth; %@ is the depth unit (m or ft)"), depthSymbol),
                NSLocalizedString("Duration (min)", bundle: bundle, value: "Duration (min)", comment: "Label for the dive duration in minutes (dive editor field, Statistics CSV export column)"),
                String(format: NSLocalizedString("Water Temperature (%@)", bundle: bundle, value: "Water Temperature (%@)", comment: "Statistics CSV export column: water temperature; %@ is the temperature unit (°C or °F)"), temperatureSymbol),
                String(format: NSLocalizedString("RMV (%@)", bundle: bundle, value: "RMV (%@)", comment: "Statistics CSV export column: respiratory minute volume; %@ is the unit (L/min or cu ft/min)"), rmvUnit),
                String(format: NSLocalizedString("SAC (%@/min)", bundle: bundle, value: "SAC (%@/min)", comment: "Statistics CSV export column: surface air consumption; %@ is the pressure unit (bar or psi)"), pressureUnit.symbol),
                NSLocalizedString("RMV Estimated", bundle: bundle, value: "RMV Estimated", comment: "Statistics CSV export column: Yes when the RMV was calculated from units other than bar and litres")
            ],
            yes: NSLocalizedString("Yes", bundle: bundle, value: "Yes", comment: "Yes, as an answer or a value (e.g. a toggle label, the Statistics CSV export)"),
            no: NSLocalizedString("No", bundle: bundle, value: "No", comment: "No, as an answer or a value (e.g. the Statistics CSV export)"),
            rmvDecimals: rmvInCubicFeet ? 3 : 2
        )

        var rows: [StatisticsCSVRow] = []
        rows.reserveCapacity(dives.count)
        let yieldInterval = 100
        for (index, dive) in dives.enumerated() {
            if index % yieldInterval == 0 {
                csvProgressCurrent = index
                await Task.yield()
                if Task.isCancelled { return nil }
            }
            // Re-checked after every yield: iCloud can delete a dive meanwhile.
            guard !dive.isDeleted, dive.modelContext != nil else { continue }
            rows.append(StatisticsCSVRow.read(from: dive, pressureUnit: pressureUnit))
        }
        csvProgressCurrent = dives.count
        if Task.isCancelled { return nil }
        // The file is built with no progress steps (the card shows the last count meanwhile).
        let builtRows = rows
        return await Task.detached(priority: .userInitiated) {
            StatisticsCSVExport.build(rows: builtRows, labels: labels)
        }.value
    }

    // MARK: - Bottom Time & Surface Interval Section

    private var timingSection: some View {
        HStack(spacing: 12) {
            bottomTimeTile
            surfaceIntervalTile
        }
        .padding(.horizontal)
    }

    /// Bottom Time tile (paired with Surface Interval on iOS; one of three per row on macOS).
    @ViewBuilder
    private var bottomTimeTile: some View {
        let avgMin = cachedAvgDuration
        let avgFormatted = formattedMinutes(avgMin, locale: locale)
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "clock.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
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
                                    .accessibilityHidden(true)
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
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(cachedShortestDive == nil)
            }
        }
        // macOS: stretch to the tallest tile of its row of three; iOS: unchanged.
        .fillsAvailableHeightOnMac()
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
    }

    /// Surface Interval tile.
    private var surfaceIntervalTile: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "hourglass")
                    .font(.title3)
                    .foregroundStyle(.indigo)
                    .accessibilityHidden(true)
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
                                    .accessibilityHidden(true)
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
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(cachedShortestSIDive == nil)
            }
        }
        // macOS: stretch to the tallest tile of its row of three; iOS: unchanged.
        .fillsAvailableHeightOnMac()
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

    // MARK: - Career Overview

    private var careerOverviewSection: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(.cyan)
                    .accessibilityHidden(true)
                Text("Overview")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                LifetimeStat(
                    value: Double(cachedDiveCount).localizedString(decimals: 0),
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
                    value: Double(cachedUniqueSites).localizedString(decimals: 0),
                    label: "Sites",
                    icon: "mappin.circle.fill",
                    color: .orange
                )
                LifetimeStat(
                    value: Double(cachedLongestStreak).localizedString(decimals: 0),
                    label: "Consecutive Days",
                    icon: "flame.fill",
                    color: .red
                )
                LifetimeStat(
                    value: cachedUniqueCountries > 0 ? Double(cachedUniqueCountries).localizedString(decimals: 0) : "-",
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
                        return converted.localizedString(decimals: 0) + " \(prefs.volumeUnit.symbol)"
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
                    .accessibilityHidden(true)
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
                        Text(verbatim: Double(item.count).localizedString(decimals: 0))
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.cyan)
                    }
                }
                #if os(macOS)
                // The Mac sheet is tall: grow the chart with the sheet's visible height
                // (35 %), never below the iOS height or above 360 pt.
                .containerRelativeFrame(.vertical) { height, _ in
                    min(max(height * 0.35, 180), 360)
                }
                #else
                .frame(height: 180)
                #endif
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
            depthTile
            temperatureTile
        }
        .padding(.horizontal)
    }

    /// Depth tile (paired with Temperature on iOS; one of three per row on macOS).
    private var depthTile: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "arrow.down.to.line")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                Spacer()
                Text("Depth")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                Text(verbatim: cachedAvgDepth.localizedString(decimals: 1, minDecimals: 1) + " \(prefs.depthUnit.symbol)")
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
                        Text(verbatim: cachedMaxDepthEver.localizedString(decimals: 1) + " \(prefs.depthUnit.symbol)")
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
                                    .accessibilityHidden(true)
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
                        Text(verbatim: cachedMinDepth.localizedString(decimals: 1) + " \(prefs.depthUnit.symbol)")
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
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(cachedShallowestDive == nil)
            }
        }
        // macOS: stretch to the tallest tile of its row of three; iOS: unchanged.
        .fillsAvailableHeightOnMac()
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
    }

    /// Temperature tile.
    private var temperatureTile: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "thermometer.medium")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
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
                                    .accessibilityHidden(true)
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
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(cachedColdestDive == nil)
            }
        }
        // macOS: stretch to the tallest tile of its row of three; iOS: unchanged.
        .fillsAvailableHeightOnMac()
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

    // MARK: - RMV & SAC Section

    private var rmvSacSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                rmvTile
                sacTile
            }
            rmvFootnote
        }
        .padding(.horizontal)
    }

    /// Explains the " *" on the RMV values, as the trip details and a dive's Gas tab do; below
    /// the tiles rather than inside one, so the RMV tile keeps the height of its neighbours.
    @ViewBuilder
    private var rmvFootnote: some View {
        if cachedRMVIsEstimated {
            EstimatedRMVFootnote()
        }
    }

    /// RMV tile (paired with SAC on iOS; one of three per row on macOS).
    private var rmvTile: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "lungs.fill")
                    .font(.title3)
                    .foregroundStyle(.teal)
                    .accessibilityHidden(true)
                Spacer()
                Text("RMV")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                Group {
                    if gasStatsReady {
                        Text(verbatim: cachedAvgRMV)
                            // The values are being updated (same selection, recomputed): drawn
                            // just after the value, so its size and position never change.
                            .overlay(alignment: .trailing) {
                                if gasStatsSpinnerVisible {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .accessibilityLabel(Text("Calculating…"))
                                        .alignmentGuide(.trailing) { dimensions in dimensions[.leading] - 4 }
                                }
                            }
                    } else {
                        // The height of the value it stands for, so the tile does not resize.
                        ZStack {
                            Text(verbatim: "—")
                                .opacity(0)
                                .accessibilityHidden(true)
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel(Text("Calculating…"))
                        }
                    }
                }
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
                                    .accessibilityHidden(true)
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
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(cachedWorstRMVDive == nil)
            }
        }
        // macOS: stretch to the tallest tile of its row of three; iOS: unchanged.
        .fillsAvailableHeightOnMac()
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
    }

    /// SAC tile.
    private var sacTile: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.title3)
                    .foregroundStyle(.mint)
                    .accessibilityHidden(true)
                Spacer()
                Text("SAC")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                Group {
                    if gasStatsReady {
                        Text(verbatim: cachedAvgSAC)
                            // The values are being updated (same selection, recomputed): drawn
                            // just after the value, so its size and position never change.
                            .overlay(alignment: .trailing) {
                                if gasStatsSpinnerVisible {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .accessibilityLabel(Text("Calculating…"))
                                        .alignmentGuide(.trailing) { dimensions in dimensions[.leading] - 4 }
                                }
                            }
                    } else {
                        // The height of the value it stands for, so the tile does not resize.
                        ZStack {
                            Text(verbatim: "—")
                                .opacity(0)
                                .accessibilityHidden(true)
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel(Text("Calculating…"))
                        }
                    }
                }
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
                                    .accessibilityHidden(true)
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
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(cachedWorstSACDive == nil)
            }
        }
        // macOS: stretch to the tallest tile of its row of three; iOS: unchanged.
        .fillsAvailableHeightOnMac()
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

    // MARK: - Top Sites

    private var topSitesSection: some View {
        topSitesSection(sideBySide: true)
    }

    /// Favourite Sites; `sideBySide: false` gives the macOS narrow-sheet fallback the
    /// standard side padding of a full-width card.
    private func topSitesSection(sideBySide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(.cyan)
                    .accessibilityHidden(true)
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
                                Text(verbatim: Double(site.count).localizedString(decimals: 0))
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
                                    .accessibilityHidden(true)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 4)
                            // The whole row opens the site, including the empty space (a plain
                            // Button only responds where something is drawn).
                            .contentShape(Rectangle())
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
        .fillsAvailableHeightOnMac()
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.platformSecondaryBackground)
        )
        .sideBySideCardPadding(.leading, inner: 12, sideBySide: sideBySide)
    }

    // MARK: - More Stats Grid

    /// At a Glance grid: 2 columns, or 1 on macOS, where the card is the narrow
    /// right-hand column beside Favourite Sites.
    private var moreStatsColumns: [GridItem] {
        #if os(macOS)
        [GridItem(.flexible())]
        #else
        [GridItem(.flexible()), GridItem(.flexible())]
        #endif
    }

    private var moreStatsGrid: some View {
        moreStatsGrid(columns: moreStatsColumns, sideBySide: true)
    }

    /// At a Glance with explicit columns and padding: the macOS narrow-sheet fallback uses
    /// the iOS two columns and the standard side padding of a full-width card.
    private func moreStatsGrid(columns: [GridItem], sideBySide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(.cyan)
                    .accessibilityHidden(true)
                Text("At a Glance")
                    .font(.headline)
            }
            .padding(.horizontal, 4)

            LazyVGrid(columns: columns, spacing: 12) {
                StatisticsCard(
                    title: "Species Seen",
                    value: Double(cachedTotalSpeciesSeen).localizedString(decimals: 0),
                    icon: "fish.fill",
                    color: .orange
                )
            }
        }
        .fillsAvailableHeightOnMac()
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.platformSecondaryBackground)
        )
        .sideBySideCardPadding(.trailing, inner: 12, sideBySide: sideBySide)
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
                .accessibilityHidden(true)

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
                .accessibilityHidden(true)

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
                .accessibilityHidden(true)
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
    @Environment(DiveStore.self) private var store
    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""

    private var sortedDives: [Dive] { dives.sorted { $0.timestamp > $1.timestamp } }

    private var numberMap: [PersistentIdentifier: Int] {
        let numbering = selectedDiver.isEmpty
            ? store.dives
            : store.dives.filter { $0.diverName == selectedDiver }
        let total = numbering.count
        return Dictionary(uniqueKeysWithValues: numbering.enumerated().map {
            ($0.element.persistentModelID, total - $0.offset)
        })
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedDives) { dive in
                    NavigationLink(destination: DiveDetailView(dive: dive, sortedDives: sortedDives, diveNumber: numberMap[dive.persistentModelID] ?? 0).closeSheetButtonOnMac { dismiss() }) {
                        DiveRowView(
                            summary: DiveSummary(from: dive, hasFish: !(dive.seenFish?.isEmpty ?? true), hasPhotos: store.cachedDivesWithPhotos.contains(dive.id)),
                            diveNumber: numberMap[dive.persistentModelID] ?? 0
                        )
                    }
                    .listRowBackground(Color.primary.opacity(0.07))
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground().ignoresSafeArea())
            #if os(iOS)
            .listStyle(.plain)
            #endif
            .navigationTitle(siteName)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { dismiss() }
                }
            }
        }
    }
}

#Preview {
    StatisticsView()
        .modelContainer(for: Dive.self, inMemory: true)
}
